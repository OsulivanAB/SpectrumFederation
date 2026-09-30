-- Pure carried-bag classification, guild-bank access, and reminder rules.
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

function R.IsCarriedBag(bagId)
    bagId = tonumber(bagId)
    return bagId ~= nil and bagId >= 0 and bagId <= 5
end

function R.GuildBankAccess(opts)
    opts = opts or {}
    if not opts.configured or not opts.sameGuild then
        return { visible = false, enabled = false, reason = "wrong_guild" }
    end
    if opts.bankOpen then
        if opts.wrongTab then
            return { visible = true, enabled = false, action = "deposit", reason = "wrong_tab" }
        end
        if not opts.canDeposit then
            return { visible = true, enabled = false, action = "deposit", reason = "no_permission" }
        end
        if (tonumber(opts.freeSlots) or 0) <= 0 and not opts.mergeRoom then
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
    if not opts.remindersEnabled then return false end
    if not opts.windowAllowed then return false end
    if opts.dismissed then return false end
    if not opts.carriesRequested then return false end
    if not opts.hasActionablePath then return false end
    return true
end

function R.HasActionablePath(guildBankUsable)
    return guildBankUsable and true or false
end
