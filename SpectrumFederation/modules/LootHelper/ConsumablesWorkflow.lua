-- Pure trade and guild-bank accounting. These functions do not touch WoW APIs.
local _, SF = ...

SF.ConsumablesWorkflow = SF.ConsumablesWorkflow or {}
local W = SF.ConsumablesWorkflow
local C = SF.Consumables

local function FloorQty(qty)
    qty = tonumber(qty) or 0
    if qty < 0 then return 0 end
    return math.floor(qty)
end

local function ItemInfo(frozen, itemId)
    if type(frozen) ~= "table" or type(frozen.items) ~= "table" then return nil end
    return frozen.items[itemId] or frozen.items[tostring(itemId)]
end

function W.PlanTradeSlots(lines, maxSlots)
    maxSlots = tonumber(maxSlots) or 6
    if maxSlots < 0 then maxSlots = 0 end
    local placements = {}
    local remainder = {}
    local used = 0
    for i = 1, #(lines or {}) do
        local line = lines[i]
        local left = FloorQty(line.quantity)
        local stacks = line.stacks
        if type(stacks) ~= "table" then
            stacks = {
                { bag = line.bag, slot = line.slot, count = left },
            }
        end
        for s = 1, #stacks do
            if left <= 0 then break end
            local stack = stacks[s]
            local available = FloorQty(stack.count)
            local take = math.min(left, available)
            if take > 0 then
                if used >= maxSlots then
                    left = left
                else
                    used = used + 1
                    placements[#placements + 1] = {
                        bag = stack.bag,
                        slot = stack.slot,
                        tradeSlot = used,
                        quantity = take,
                        split = take < available,
                        itemId = line.itemId,
                    }
                    left = left - take
                end
            end
        end
        if left > 0 then
            remainder[#remainder + 1] = { itemId = line.itemId, quantity = left }
        end
    end
    return { placements = placements, remainder = remainder, accept = false }
end

function W.TradeEvents(frozen, actual, completed)
    if not completed or type(frozen) ~= "table" then
        return {}
    end
    local events = {}
    for key, rawQty in pairs(actual or {}) do
        local itemId = tonumber(key)
        local qty = FloorQty(rawQty)
        local info = ItemInfo(frozen, itemId)
        if itemId and qty > 0 and info and info.assignedToReceiver then
            local fromCustody = math.min(FloorQty(info.custodyQty), qty)
            local fresh = qty - fromCustody
            if fromCustody > 0 then
                events[#events + 1] = {
                    type = C.EVENT.CUSTODY,
                    action = C.ACTION.DELIVER,
                    generation = frozen.generation,
                    itemId = itemId,
                    quantity = fromCustody,
                    holder = frozen.donor,
                    fromHolder = frozen.donor,
                    crafter = frozen.receiver,
                    toHolder = frozen.receiver,
                    actor = frozen.receiver,
                    timestamp = frozen.timestamp,
                }
            end
            events[#events + 1] = {
                type = C.EVENT.RECEIPT,
                generation = frozen.generation,
                epoch = info.epoch,
                itemId = itemId,
                quantity = qty,
                crafter = frozen.receiver,
                actor = frozen.receiver,
                source = "trade",
                timestamp = frozen.timestamp,
            }
            if fresh > 0 and not info.donorAssigned then
                events[#events + 1] = {
                    type = C.EVENT.DONATION,
                    generation = frozen.generation,
                    itemId = itemId,
                    quantity = fresh,
                    actor = frozen.donor,
                    crafter = frozen.receiver,
                    source = "trade",
                    timestamp = frozen.timestamp,
                }
            end
        elseif itemId and qty > 0 and info and FloorQty(info.custodyQty) > 0 and frozen.donorIsAdmin and frozen.receiverIsAdmin and not info.assignedToReceiver then
            local moved = math.min(FloorQty(info.custodyQty), qty)
            events[#events + 1] = {
                type = C.EVENT.CUSTODY,
                action = C.ACTION.TRANSFER,
                generation = frozen.generation,
                itemId = itemId,
                quantity = moved,
                fromHolder = frozen.donor,
                toHolder = frozen.receiver,
                actor = frozen.receiver,
                timestamp = frozen.timestamp,
            }
        end
    end
    return events
end

function W.DepositEvents(frozen, actualQty)
    if type(frozen) ~= "table" then return {} end
    local qty = FloorQty(actualQty)
    if qty <= 0 then return {} end
    local fromCustody = math.min(FloorQty(frozen.custodyQty), qty)
    local fresh = qty - fromCustody
    local events = {}
    if fromCustody > 0 then
        events[#events + 1] = {
            type = C.EVENT.CUSTODY,
            action = C.ACTION.RETURN,
            generation = frozen.generation,
            itemId = frozen.itemId,
            quantity = fromCustody,
            holder = frozen.donor,
            fromHolder = frozen.donor,
            actor = frozen.donor,
            timestamp = frozen.timestamp,
        }
    end
    if fresh > 0 and frozen.requested and not frozen.donorAssigned then
        events[#events + 1] = {
            type = C.EVENT.DONATION,
            generation = frozen.generation,
            itemId = frozen.itemId,
            quantity = fresh,
            actor = frozen.donor,
            source = "guildbank",
            timestamp = frozen.timestamp,
        }
    end
    return events
end

function W.WithdrawEvents(ctx, itemId, qty)
    ctx = ctx or {}
    qty = FloorQty(qty)
    itemId = tonumber(itemId)
    if not ctx.requested or not itemId or qty <= 0 then
        return {}
    end
    if ctx.withdrawerIsAssignedCrafter then
        return {
            {
                type = C.EVENT.RECEIPT,
                generation = ctx.generation,
                epoch = ctx.epoch,
                itemId = itemId,
                quantity = qty,
                crafter = ctx.withdrawer,
                actor = ctx.withdrawer,
                source = "guildbank",
                timestamp = ctx.timestamp,
            },
        }
    end
    if ctx.withdrawerIsAdmin then
        return {
            {
                type = C.EVENT.CUSTODY,
                action = C.ACTION.WITHDRAW,
                generation = ctx.generation,
                itemId = itemId,
                quantity = qty,
                holder = ctx.withdrawer,
                actor = ctx.withdrawer,
                timestamp = ctx.timestamp,
            },
        }
    end
    return {}
end

function W.InterpretDeposit(intent)
    intent = intent or {}
    if not intent.guildOk then
        return 0, "wrong_guild"
    end
    if tonumber(intent.observedTab) ~= tonumber(intent.configuredTab) then
        return 0, "wrong_tab"
    end
    local appeared = math.max(0, FloorQty(intent.afterTab) - FloorQty(intent.beforeTab))
    local left = math.max(0, FloorQty(intent.beforeBags) - FloorQty(intent.afterBags))
    local actual = math.min(FloorQty(intent.intendedQty), appeared, left)
    return actual, nil
end

function W.InterpretWithdraw(intent)
    intent = intent or {}
    if intent.localPickup ~= true then
        return 0
    end
    if tonumber(intent.observedTab) ~= tonumber(intent.configuredTab) then
        return 0
    end
    local tabLoss = math.max(0, FloorQty(intent.beforeTab) - FloorQty(intent.afterTab))
    local bagGain = math.max(0, FloorQty(intent.afterBags) - FloorQty(intent.beforeBags))
    local qty = math.min(tabLoss, bagGain)
    if intent.intendedQty ~= nil then
        qty = math.min(qty, FloorQty(intent.intendedQty))
    end
    return qty
end

function W.EventsFromUnsupportedInventoryDecrease()
    return {}
end

function W.ClampDonationQuantity(requested, carried)
    carried = FloorQty(carried)
    requested = FloorQty(requested)
    if carried <= 0 then return 0 end
    if requested < 1 then requested = 1 end
    if requested > carried then requested = carried end
    return requested
end
