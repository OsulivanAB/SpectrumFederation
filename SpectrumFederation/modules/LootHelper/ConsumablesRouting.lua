-- Pure routing, carried-bag classification, and reminder rules.
local _, SF = ...

SF.ConsumablesRouting = SF.ConsumablesRouting or {}
local R = SF.ConsumablesRouting

function R.TransferableBindType(bindType)
    bindType = tonumber(bindType)
    if bindType == nil then return nil end
    -- 1 On Acquire, 4 Quest, 7 Account, 8 Battle.net account, 9 Warbound until equipped.
    if bindType == 1 or bindType == 4 or bindType == 7 or bindType == 8 or bindType == 9 then
        return false
    end
    return true
end

function R.PeerCompatible(peer, isSelf)
    if isSelf then return true end
    return type(peer) == "table" and peer.consumablesCapable == true
end

function R.IsCarriedBag(bagId)
    bagId = tonumber(bagId)
    return bagId ~= nil and bagId >= 0 and bagId <= 5
end

function R.Choose(candidates, totals)
    totals = totals or {}
    local bestName = nil
    local bestTotal = nil
    for i = 1, #(candidates or {}) do
        local candidate = candidates[i]
        if type(candidate) == "table" and candidate.inGroup and candidate.compatible and type(candidate.name) == "string" then
            local total = tonumber(totals[candidate.name]) or 0
            if not bestName or total < bestTotal or (total == bestTotal and candidate.name < bestName) then
                bestName = candidate.name
                bestTotal = total
            end
        end
    end
    return bestName
end

function R.RouteItem(crafters, totals, inGroup, compatible)
    local candidates = {}
    for i = 1, #(crafters or {}) do
        local name = crafters[i]
        candidates[#candidates + 1] = {
            name = name,
            inGroup = inGroup and inGroup[name] and true or false,
            compatible = compatible and compatible[name] and true or false,
        }
    end
    return R.Choose(candidates, totals)
end

function R.TradeAction(recipient, inRange)
    if type(recipient) ~= "string" or recipient == "" then
        return { visible = false, enabled = false, recipient = nil }
    end
    return {
        visible = true,
        enabled = inRange and true or false,
        recipient = recipient,
    }
end

function R.GuildBankAccess(opts)
    opts = opts or {}
    if not opts.configured or not opts.sameGuild then
        return { visible = false, enabled = false, reason = "wrong_guild" }
    end
    if opts.bankOpen then
        if not opts.canDeposit then
            return { visible = true, enabled = false, action = "deposit", reason = "no_permission" }
        end
        if (tonumber(opts.freeSlots) or 0) <= 0 then
            return { visible = true, enabled = false, action = "deposit", reason = "tab_full" }
        end
        return { visible = true, enabled = true, action = "deposit" }
    end
    if opts.mobileKnown and not opts.mobileCooldown then
        return { visible = true, enabled = true, action = "mobile" }
    end
    if opts.mobileKnown and opts.mobileCooldown then
        return { visible = true, enabled = false, action = "cooldown", reason = "cooldown" }
    end
    return { visible = true, enabled = false, action = "unavailable", reason = "bank_closed" }
end

function R.GuildBankUsable(access)
    return access and access.enabled and (access.action == "deposit" or access.action == "mobile") and true or false
end

function R.ReminderVisible(opts)
    opts = opts or {}
    if opts.isCrafter then return false end
    if not opts.remindersEnabled then return false end
    if not opts.windowAllowed then return false end
    if opts.dismissed then return false end
    if not opts.carriesRequested then return false end
    if not opts.hasActionablePath then return false end
    return true
end

function R.ShouldPollRange(opts)
    opts = opts or {}
    if type(opts.selectedRecipient) ~= "string" or opts.selectedRecipient == "" then
        return false
    end
    if opts.inRange ~= false then
        return false
    end
    return (opts.reminderVisible or opts.reviewVisible) and true or false
end

function R.SyncRangeTicker(want, ticker)
    ticker = ticker or { active = false, starts = 0, stops = 0 }
    if want and not ticker.active then
        ticker.active = true
        ticker.starts = (ticker.starts or 0) + 1
    elseif (not want) and ticker.active then
        ticker.active = false
        ticker.stops = (ticker.stops or 0) + 1
    end
    return ticker
end

function R.HasActionablePath(lines, guildBankUsable)
    if guildBankUsable then return true end
    for i = 1, #(lines or {}) do
        if lines[i].recipient then return true end
    end
    return false
end
