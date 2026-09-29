-- Pure guild-bank deposit accounting. These functions do not touch WoW APIs.
local _, SF = ...

SF.ConsumablesWorkflow = SF.ConsumablesWorkflow or {}
local W = SF.ConsumablesWorkflow
local C = SF.Consumables

local function FloorQty(qty)
    qty = tonumber(qty) or 0
    if qty < 0 then return 0 end
    return math.floor(qty)
end

function W.DepositEvents(frozen, actualQty)
    if type(frozen) ~= "table" then return {} end
    local qty = FloorQty(actualQty)
    if qty <= 0 then return {} end
    if not frozen.requested then return {} end
    return {
        {
            type = C.EVENT.DONATION,
            generation = frozen.generation,
            itemId = frozen.itemId,
            quantity = qty,
            actor = frozen.donor,
            source = "guildbank",
            timestamp = frozen.timestamp,
        },
    }
end

function W.InterpretDeposit(intent)
    intent = intent or {}
    if not intent.guildOk then
        return 0, "wrong_guild"
    end
    if tonumber(intent.observedTab) ~= tonumber(intent.configuredTab) then
        return 0, "wrong_tab"
    end
    local appeared
    if intent.placedSlots ~= nil then
        appeared = 0
        if type(intent.placedSlots) == "table" then
            for i = 1, #intent.placedSlots do
                local row = intent.placedSlots[i]
                if type(row) == "table" then
                    local gain = FloorQty(row.after) - FloorQty(row.before)
                    if gain > 0 then appeared = appeared + gain end
                end
            end
        end
    else
        appeared = math.max(0, FloorQty(intent.afterTab) - FloorQty(intent.beforeTab))
    end
    local left = math.max(0, FloorQty(intent.beforeBags) - FloorQty(intent.afterBags))
    local actual = math.min(FloorQty(intent.intendedQty), appeared, left)
    return actual, nil
end

function W.DepositDisposition(actual, intended, fromTimer)
    actual = FloorQty(actual)
    intended = FloorQty(intended)
    if intended > 0 and actual >= intended then
        return "commit"
    end
    if fromTimer then
        if actual > 0 then return "commit" end
        return "drop"
    end
    return "wait"
end

function W.ClampDonationQuantity(requested, carried)
    carried = FloorQty(carried)
    requested = FloorQty(requested)
    if carried <= 0 then return 0 end
    if requested < 1 then requested = 1 end
    if requested > carried then requested = carried end
    return requested
end
