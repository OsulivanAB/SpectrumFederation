-- Pure Quick Withdraw planning / confirmation accounting (#457).
-- No WoW API calls — production Lua tests exercise these decisions directly.
local _, SF = ...

SF.ConsumablesWithdrawWorkflow = SF.ConsumablesWithdrawWorkflow or {}
local W = SF.ConsumablesWithdrawWorkflow

local function FloorQty(qty)
    qty = tonumber(qty) or 0
    if qty ~= qty or qty == math.huge or qty == -math.huge then
        return 0
    end
    if qty < 0 then return 0 end
    return math.floor(qty)
end

--- Aggregate craft selections into reagent quantities.
-- Existing bag quantities do NOT reduce the request.
function W.AggregateCrafts(selections, recipes)
    local GS = SF.GuildSupplies
    if GS and GS.AggregateRecipeWithdrawal then
        return GS.AggregateRecipeWithdrawal(selections, recipes)
    end
    return nil, "unavailable"
end

--- Compare requested vs available stock. Shortages list short reagents only.
-- @return plan { requested, available, take, shortages, fullySatisfiable }
function W.BuildStockPlan(requested, available)
    requested = type(requested) == "table" and requested or {}
    available = type(available) == "table" and available or {}
    local take = {}
    local shortages = {}
    local fully = true
    local keys = {}
    for k in pairs(requested) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    for i = 1, #keys do
        local key = keys[i]
        local want = FloorQty(requested[key] or requested[tonumber(key)])
        if want > 0 then
            local have = FloorQty(available[key] or available[tonumber(key)])
            local get = want
            if have < want then
                fully = false
                get = have
                shortages[#shortages + 1] = {
                    itemId = tonumber(key) or key,
                    requested = want,
                    available = have,
                    missing = want - have,
                }
            end
            if get > 0 then
                take[key] = get
            end
        end
    end
    return {
        requested = requested,
        available = available,
        take = take,
        shortages = shortages,
        fullySatisfiable = fully,
    }
end

--- Authorize a partial plan after "Withdraw anyway".
function W.AuthorizePartialPlan(stockPlan)
    if type(stockPlan) ~= "table" then
        return nil, "invalid_plan"
    end
    local take = stockPlan.take or {}
    local any = false
    for _, qty in pairs(take) do
        if FloorQty(qty) > 0 then
            any = true
            break
        end
    end
    if not any then
        return nil, "nothing_available"
    end
    return {
        take = take,
        partial = not stockPlan.fullySatisfiable,
        shortages = stockPlan.shortages,
    }
end

--- Select source stacks for exact withdrawal. Prefer full stacks that fit;
-- otherwise split. Deterministic: lowest slot first.
-- @param stacks { {slot, count, locked?}... } for one itemId
-- @param need number
-- @return moves { {slot, count, split?}... }, remainingUnfilled
function W.PlanSourceMoves(stacks, need)
    need = FloorQty(need)
    if need < 1 then
        return {}, 0
    end
    if type(stacks) ~= "table" then
        return {}, need
    end
    local ordered = {}
    for i = 1, #stacks do
        local s = stacks[i]
        if type(s) == "table" and not s.locked then
            local count = FloorQty(s.count)
            if count > 0 then
                ordered[#ordered + 1] = {
                    slot = s.slot,
                    count = count,
                    index = i,
                }
            end
        end
    end
    table.sort(ordered, function(a, b)
        local sa, sb = tonumber(a.slot) or 0, tonumber(b.slot) or 0
        if sa ~= sb then return sa < sb end
        return a.index < b.index
    end)
    local moves = {}
    local remaining = need
    for i = 1, #ordered do
        if remaining < 1 then break end
        local s = ordered[i]
        if s.count <= remaining then
            moves[#moves + 1] = { slot = s.slot, count = s.count, split = false }
            remaining = remaining - s.count
        else
            moves[#moves + 1] = { slot = s.slot, count = remaining, split = true }
            remaining = 0
        end
    end
    return moves, remaining
end

--- Interpret confirmed bag gains vs bank losses for one item movement.
-- API invocation / cursor pickup alone is not success — both sides must move.
function W.InterpretWithdrawal(intent)
    intent = intent or {}
    if not intent.guildOk then
        return 0, "wrong_guild"
    end
    if tonumber(intent.observedTab) ~= tonumber(intent.configuredTab) then
        return 0, "wrong_tab"
    end
    local bankLoss
    if intent.placedSlots ~= nil then
        bankLoss = 0
        if type(intent.placedSlots) == "table" then
            for i = 1, #intent.placedSlots do
                local row = intent.placedSlots[i]
                if type(row) == "table" then
                    local loss = FloorQty(row.before) - FloorQty(row.after)
                    if loss > 0 then bankLoss = bankLoss + loss end
                end
            end
        end
    else
        bankLoss = math.max(0, FloorQty(intent.beforeTab) - FloorQty(intent.afterTab))
    end
    local bagGain = math.max(0, FloorQty(intent.afterBags) - FloorQty(intent.beforeBags))
    local actual = math.min(FloorQty(intent.intendedQty), bankLoss, bagGain)
    return actual, nil
end

function W.WithdrawalDisposition(actual, intended, fromTimer, uncertain)
    actual = FloorQty(actual)
    intended = FloorQty(intended)
    if uncertain then
        return "unresolved"
    end
    if intended > 0 and actual >= intended then
        return "commit"
    end
    if fromTimer then
        if actual > 0 then return "commit" end
        return "drop"
    end
    return "wait"
end

--- Stack allowance: Blizzard measures withdrawals in stacks, not reagent units.
-- @param remainingAllowance number|nil nil = unlimited
-- @param plannedStacks number of stack withdrawals the plan needs
function W.AllowanceBlocksPlan(remainingAllowance, plannedStacks)
    if remainingAllowance == nil then
        return false
    end
    local left = FloorQty(remainingAllowance)
    local need = FloorQty(plannedStacks)
    return need > left
end

--- Bag capacity: block before first move when known free slots cannot fit plan.
-- @param freeCompatibleSlots number
-- @param requiredNewStacks number of destination stacks that need empty slots
--   (after accounting for partial-stack merge room already reserved)
function W.CapacityBlocksPlan(freeCompatibleSlots, requiredNewStacks)
    local free = FloorQty(freeCompatibleSlots)
    local need = FloorQty(requiredNewStacks)
    return need > free
end

--- True when source stack planning could not satisfy authorized take.
function W.SourcePlanIncomplete(remainingUnfilled)
    return FloorQty(remainingUnfilled) > 0
end

--- Blizzard bag/item family compatibility (bit flags). Nil/0 = unrestricted.
local function BandFlags(a, b)
    a = tonumber(a) or 0
    b = tonumber(b) or 0
    if bit and bit.band then
        return bit.band(a, b)
    end
    local result = 0
    local bitval = 1
    while a > 0 or b > 0 do
        if a % 2 == 1 and b % 2 == 1 then
            result = result + bitval
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bitval = bitval * 2
    end
    return result
end

function W.SlotAcceptsItemFamily(slotFamily, itemFamily)
    slotFamily = tonumber(slotFamily) or 0
    itemFamily = tonumber(itemFamily) or 0
    if itemFamily == 0 then return true end
    if slotFamily == 0 then return true end
    return BandFlags(slotFamily, itemFamily) ~= 0
end

--- Live or snapshot slot still matches a planned destination row.
-- @param slotState { empty?, itemId?, count?, locked?, family? }
-- @param dest { count, merge }
function W.DestinationStillValid(slotState, dest, itemId, stackLimit)
    if type(dest) ~= "table" or type(slotState) ~= "table" then
        return false, "invalid"
    end
    itemId = tonumber(itemId)
    if not itemId then return false, "invalid" end
    local need = FloorQty(dest.count)
    if need < 1 then return false, "invalid" end
    local itemFamily = tonumber(dest.itemFamily) or tonumber(slotState.expectedItemFamily) or 0
    local slotFamily = tonumber(slotState.family) or 0
    if not W.SlotAcceptsItemFamily(slotFamily, itemFamily) then
        return false, "family"
    end
    if slotState.empty then
        if dest.merge then return false, "not_merge" end
        return true
    end
    if slotState.locked then return false, "locked" end
    if tonumber(slotState.itemId) ~= itemId then return false, "occupied" end
    if not dest.merge then return false, "not_empty" end
    local maxStack = FloorQty(stackLimit)
    if maxStack < 1 then maxStack = 1 end
    local room = maxStack - FloorQty(slotState.count)
    if room < need then return false, "no_room" end
    return true
end

--- @param carriedBags { { bag=number, slots={ {slot, empty?, itemId?, count?, locked?, family?}... } }... }
-- @param take {[itemKey]=qty}
-- @param stackLimitForItem fun(itemId:number):number
-- @param itemFamilyForItem fun(itemId:number):number|nil optional family resolver
-- @return ok, err, plan { destinations, freeCompatibleSlots, requiredNewStacks }
function W.PlanMultiItemBagDestinations(carriedBags, take, stackLimitForItem, itemFamilyForItem)
    take = type(take) == "table" and take or {}
    carriedBags = type(carriedBags) == "table" and carriedBags or {}
    local grid = {}
    for i = 1, #carriedBags do
        local bagRow = carriedBags[i]
        local bagId = tonumber(bagRow and bagRow.bag)
        if bagId ~= nil then
            local slots = type(bagRow.slots) == "table" and bagRow.slots or {}
            local copySlots = {}
            for s = 1, #slots do
                local row = slots[s]
                if type(row) == "table" then
                    if row.empty then
                        copySlots[s] = {
                            slot = row.slot or s,
                            empty = true,
                            family = tonumber(row.family) or 0,
                        }
                    else
                        copySlots[s] = {
                            slot = row.slot or s,
                            itemId = tonumber(row.itemId),
                            count = FloorQty(row.count),
                            locked = row.locked and true or false,
                            family = tonumber(row.family) or 0,
                        }
                    end
                end
            end
            grid[#grid + 1] = { bag = bagId, slots = copySlots }
        end
    end
    table.sort(grid, function(a, b)
        return (tonumber(a.bag) or 0) < (tonumber(b.bag) or 0)
    end)

    local keys = {}
    for k in pairs(take) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)

    local destinations = {}
    local requiredNewStacks = 0

    local function itemFamily(itemId)
        if type(itemFamilyForItem) == "function" then
            return tonumber(itemFamilyForItem(itemId)) or 0
        end
        return 0
    end

    local function findFirstEmpty(family)
        for gi = 1, #grid do
            local bagId = grid[gi].bag
            local slots = grid[gi].slots
            for si = 1, #slots do
                local slot = slots[si]
                if slot.empty and W.SlotAcceptsItemFamily(slot.family, family) then
                    return gi, si, bagId, slot.slot or si
                end
            end
        end
        return nil
    end

    for ki = 1, #keys do
        local key = keys[ki]
        local itemId = tonumber(key)
        local qty = FloorQty(take[key] or take[itemId])
        if itemId and qty > 0 then
            local maxStack = 1000
            if type(stackLimitForItem) == "function" then
                maxStack = FloorQty(stackLimitForItem(itemId))
                if maxStack < 1 then maxStack = 1 end
            end
            local family = itemFamily(itemId)
            local remaining = qty
            for gi = 1, #grid do
                if remaining < 1 then break end
                local bagId = grid[gi].bag
                local slots = grid[gi].slots
                for si = 1, #slots do
                    if remaining < 1 then break end
                    local slot = slots[si]
                    if not slot.empty and not slot.locked and slot.itemId == itemId then
                        local room = maxStack - FloorQty(slot.count)
                        if room > 0 then
                            local put = math.min(remaining, room)
                            destinations[#destinations + 1] = {
                                itemId = itemId,
                                bag = bagId,
                                slot = slot.slot or si,
                                count = put,
                                merge = true,
                                itemFamily = family,
                            }
                            slot.count = FloorQty(slot.count) + put
                            remaining = remaining - put
                        end
                    end
                end
            end
            while remaining > 0 do
                local gi, si, bagId, slotNum = findFirstEmpty(family)
                if not gi then
                    return false, "bag_capacity", {
                        destinations = destinations,
                        freeCompatibleSlots = 0,
                        requiredNewStacks = requiredNewStacks,
                    }
                end
                local slot = grid[gi].slots[si]
                local put = math.min(remaining, maxStack)
                destinations[#destinations + 1] = {
                    itemId = itemId,
                    bag = bagId,
                    slot = slotNum,
                    count = put,
                    merge = false,
                    itemFamily = family,
                }
                slot.empty = nil
                slot.itemId = itemId
                slot.count = put
                slot.locked = false
                requiredNewStacks = requiredNewStacks + 1
                remaining = remaining - put
            end
        end
    end
    local freeCompatibleSlots = 0
    for gi = 1, #grid do
        local slots = grid[gi].slots
        for si = 1, #slots do
            if slots[si].empty then
                freeCompatibleSlots = freeCompatibleSlots + 1
            end
        end
    end
    return true, nil, {
        destinations = destinations,
        freeCompatibleSlots = freeCompatibleSlots,
        requiredNewStacks = requiredNewStacks,
    }
end

--- Consume destination rows for one bank move of `need` units (mutates destRows list).
-- @return dest { bag, slot, count, merge }|nil
function W.TakeDestinationForMove(destRows, itemId, need)
    need = FloorQty(need)
    itemId = tonumber(itemId)
    if need < 1 or not itemId or type(destRows) ~= "table" then
        return nil
    end
    for i = 1, #destRows do
        local row = destRows[i]
        if type(row) == "table" and tonumber(row.itemId) == itemId then
            local have = FloorQty(row.count)
            if have < 1 then
                table.remove(destRows, i)
                return W.TakeDestinationForMove(destRows, itemId, need)
            end
            if have <= need then
                table.remove(destRows, i)
                return row
            end
            row.count = have - need
            return {
                itemId = itemId,
                bag = row.bag,
                slot = row.slot,
                count = need,
                merge = row.merge,
            }
        end
    end
    return nil
end

--- Oldest-batch-first consumption for trade handoff (#457 D3).
-- @param batches { {id, expiresAt, amounts={[itemId]=qty}}... } oldest first
-- @param delivered {[itemId]=qty}
-- @return remainingBatches, consumed {[itemId]=qty}
function W.ConsumeTradeBatches(batches, delivered, now)
    batches = type(batches) == "table" and batches or {}
    delivered = type(delivered) == "table" and delivered or {}
    now = tonumber(now) or 0
    local remainingNeed = {}
    for k, v in pairs(delivered) do
        local qty = FloorQty(v)
        if qty > 0 then
            remainingNeed[tostring(k)] = qty
        end
    end
    local out = {}
    local consumed = {}
    for i = 1, #batches do
        local batch = batches[i]
        if type(batch) ~= "table" then
            -- skip
        elseif tonumber(batch.expiresAt) and now >= tonumber(batch.expiresAt) then
            -- expired: drop
        else
            local amounts = type(batch.amounts) == "table" and batch.amounts or {}
            local amb = type(batch.ambiguous) == "table" and batch.ambiguous or {}
            local nextAmounts = {}
            for key, qty in pairs(amounts) do
                local have = FloorQty(qty)
                local k = tostring(key)
                local paused = FloorQty(amb[k] or amb[tonumber(key)])
                local eligible = have - paused
                if eligible < 0 then eligible = 0 end
                local need = remainingNeed[k] or 0
                if need > 0 and eligible > 0 then
                    local take = math.min(eligible, need)
                    consumed[k] = (consumed[k] or 0) + take
                    remainingNeed[k] = need - take
                    have = have - take
                end
                if have > 0 then
                    nextAmounts[k] = have
                end
            end
            local any = false
            for _ in pairs(nextAmounts) do
                any = true
                break
            end
            if any then
                local row = {
                    id = batch.id,
                    completedAt = batch.completedAt,
                    expiresAt = batch.expiresAt,
                    amounts = nextAmounts,
                }
                if type(batch.ambiguous) == "table" then
                    local ambCopy = {}
                    for ak, av in pairs(batch.ambiguous) do
                        if FloorQty(av) > 0 then
                            ambCopy[tostring(ak)] = FloorQty(av)
                        end
                    end
                    if next(ambCopy) then
                        row.ambiguous = ambCopy
                    end
                end
                out[#out + 1] = row
            end
        end
    end
    return out, consumed
end

-- #457 trade handoff repair: pure delivery / ambiguity decisions (no WoW API).
--- @return delivered, ambiguousAmounts, outcome ("completed"|"ambiguous"|"cancelled"), hadOffers
function W.ResolveTradeDelivery(offered, bagBefore, bagAfterFn, bothAccepted)
    offered = type(offered) == "table" and offered or {}
    bagBefore = type(bagBefore) == "table" and bagBefore or {}
    bagAfterFn = type(bagAfterFn) == "function" and bagAfterFn or function() return 0 end
    local delivered = {}
    local ambiguous = {}
    local hadOffers = false
    if not bothAccepted then
        return delivered, ambiguous, "cancelled", next(offered) ~= nil
    end
    for k, offQty in pairs(offered) do
        offQty = FloorQty(offQty)
        if offQty > 0 then
            hadOffers = true
            local key = tostring(k)
            local before = FloorQty(bagBefore[key] or bagBefore[tonumber(key)])
            local after = FloorQty(bagAfterFn(key))
            local lost = before - after
            if lost < 0 then lost = 0 end
            local proven = math.min(offQty, lost)
            if proven > 0 then
                delivered[key] = proven
            end
            local unverified = offQty - proven
            if unverified > 0 then
                ambiguous[key] = unverified
            end
        end
    end
    if not hadOffers then
        return delivered, ambiguous, "cancelled", false
    end
    if next(ambiguous) then
        return delivered, ambiguous, "ambiguous", true
    end
    if next(delivered) then
        return delivered, ambiguous, "completed", true
    end
    for k, offQty in pairs(offered) do
        offQty = FloorQty(offQty)
        if offQty > 0 then
            ambiguous[tostring(k)] = offQty
        end
    end
    return delivered, ambiguous, "ambiguous", true
end

--- Bind unresolved trade quantities to oldest batches (per-batch ambiguous map).
function W.BindTradeAmbiguity(batches, ambiguousAmounts, now)
    batches = type(batches) == "table" and batches or {}
    ambiguousAmounts = type(ambiguousAmounts) == "table" and ambiguousAmounts or {}
    now = tonumber(now) or 0
    local need = {}
    for k, v in pairs(ambiguousAmounts) do
        local qty = FloorQty(v)
        if qty > 0 then
            need[tostring(k)] = qty
        end
    end
    if not next(need) then
        return batches
    end
    local out = {}
    for i = 1, #batches do
        local batch = batches[i]
        if type(batch) ~= "table" then
            -- skip
        elseif tonumber(batch.expiresAt) and now >= tonumber(batch.expiresAt) then
            -- expired batch drops its ambiguity with it
        else
            local amounts = type(batch.amounts) == "table" and batch.amounts or {}
            local amb = {}
            if type(batch.ambiguous) == "table" then
                for ak, av in pairs(batch.ambiguous) do
                    amb[tostring(ak)] = FloorQty(av)
                end
            end
            for key, qty in pairs(amounts) do
                local k = tostring(key)
                local bind = need[k] or 0
                if bind > 0 then
                    local offerable = FloorQty(qty) - FloorQty(amb[k])
                    local take = math.min(bind, offerable)
                    if take > 0 then
                        amb[k] = (amb[k] or 0) + take
                        need[k] = bind - take
                    end
                end
            end
            local row = {
                id = batch.id,
                completedAt = batch.completedAt,
                expiresAt = batch.expiresAt,
                amounts = amounts,
            }
            if next(amb) then
                row.ambiguous = amb
            end
            out[#out + 1] = row
        end
    end
    return out
end

--- #457 trade handoff repair: plan stack-level trade offers (one slot per placement).
-- @param stacksByItem {[itemKey]={ {bag, slot, count}, ... }...}
-- @return moves { {itemKey, qty, bag, slot}, ... }, deferred {[itemKey]=qty}
function W.PlanTradePrefillMoves(pending, alreadyOffered, stacksByItem, freeSlots, maxSlots)
    pending = type(pending) == "table" and pending or {}
    alreadyOffered = type(alreadyOffered) == "table" and alreadyOffered or {}
    stacksByItem = type(stacksByItem) == "table" and stacksByItem or {}
    freeSlots = FloorQty(freeSlots)
    maxSlots = FloorQty(maxSlots)
    if maxSlots > 0 and freeSlots > maxSlots then
        freeSlots = maxSlots
    end
    local moves = {}
    local deferred = {}
    local slotsLeft = freeSlots
    local keys = {}
    for k in pairs(pending) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    for i = 1, #keys do
        local key = keys[i]
        local want = FloorQty(pending[key] or pending[tonumber(key)])
        local offered = FloorQty(alreadyOffered[key] or alreadyOffered[tonumber(key)])
        local need = math.max(0, want - offered)
        if need > 0 then
            local stacks = stacksByItem[key] or stacksByItem[tonumber(key)] or {}
            local remainingNeed = need
            for s = 1, #stacks do
                if remainingNeed < 1 then break end
                if slotsLeft < 1 then
                    deferred[key] = (deferred[key] or 0) + remainingNeed
                    remainingNeed = 0
                    break
                end
                local st = stacks[s]
                if type(st) == "table" and not st.locked then
                    local have = FloorQty(st.count)
                    if have > 0 then
                        local take = math.min(have, remainingNeed)
                        moves[#moves + 1] = {
                            itemKey = key,
                            qty = take,
                            bag = st.bag,
                            slot = st.slot,
                        }
                        remainingNeed = remainingNeed - take
                        slotsLeft = slotsLeft - 1
                    end
                end
            end
            if remainingNeed > 0 then
                deferred[key] = (deferred[key] or 0) + remainingNeed
            end
        end
    end
    return moves, deferred
end

--- Independent expiry: do not extend older batches when adding a new one.
function W.AppendTradeBatch(batches, newBatch, maxBatches)
    batches = type(batches) == "table" and batches or {}
    maxBatches = tonumber(maxBatches) or 32
    if type(newBatch) ~= "table" or type(newBatch.amounts) ~= "table" then
        return nil, "invalid_batch"
    end
    local any = false
    for _, qty in pairs(newBatch.amounts) do
        if FloorQty(qty) > 0 then
            any = true
            break
        end
    end
    if not any then
        return nil, "empty_batch"
    end
    if #batches >= maxBatches then
        return nil, "full"
    end
    local out = {}
    for i = 1, #batches do
        out[i] = batches[i]
    end
    out[#out + 1] = {
        id = newBatch.id,
        completedAt = newBatch.completedAt,
        expiresAt = newBatch.expiresAt,
        amounts = newBatch.amounts,
    }
    return out
end

--- Prefill offer: account for items already in trade slots; do not exceed pending.
-- @param pending {[itemId]=qty}
-- @param alreadyOffered {[itemId]=qty}
-- @param carried {[itemId]=qty}
-- @param freeSlots number
-- @return toOffer {[itemId]=qty}, deferred {[itemId]=qty}
function W.PlanTradePrefill(pending, alreadyOffered, carried, freeSlots, maxSlots)
    pending = type(pending) == "table" and pending or {}
    alreadyOffered = type(alreadyOffered) == "table" and alreadyOffered or {}
    carried = type(carried) == "table" and carried or {}
    freeSlots = FloorQty(freeSlots)
    maxSlots = FloorQty(maxSlots)
    if maxSlots > 0 and freeSlots > maxSlots then
        freeSlots = maxSlots
    end
    local toOffer = {}
    local deferred = {}
    local slotsUsed = 0
    local keys = {}
    for k in pairs(pending) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    for i = 1, #keys do
        local key = keys[i]
        local want = FloorQty(pending[key] or pending[tonumber(key)])
        local offered = FloorQty(alreadyOffered[key] or alreadyOffered[tonumber(key)])
        local need = math.max(0, want - offered)
        local have = FloorQty(carried[key] or carried[tonumber(key)])
        local give = math.min(need, have)
        if give > 0 then
            if slotsUsed >= freeSlots then
                deferred[key] = (deferred[key] or 0) + give
            else
                -- Conservative: each item ID consumes at least one slot.
                toOffer[key] = give
                slotsUsed = slotsUsed + 1
            end
        elseif need > 0 then
            deferred[key] = (deferred[key] or 0) + need
        end
    end
    return toOffer, deferred
end
