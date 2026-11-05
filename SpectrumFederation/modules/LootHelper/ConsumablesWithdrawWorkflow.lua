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
            local nextAmounts = {}
            for key, qty in pairs(amounts) do
                local have = FloorQty(qty)
                local k = tostring(key)
                local need = remainingNeed[k] or 0
                if need > 0 and have > 0 then
                    local take = math.min(have, need)
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
                out[#out + 1] = {
                    id = batch.id,
                    completedAt = batch.completedAt,
                    expiresAt = batch.expiresAt,
                    amounts = nextAmounts,
                }
            end
        end
    end
    return out, consumed
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
