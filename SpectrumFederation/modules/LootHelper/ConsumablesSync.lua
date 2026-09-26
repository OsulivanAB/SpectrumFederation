-- Permission and convergence rules for Consumables sync payloads.
local _, SF = ...

SF.ConsumablesSync = SF.ConsumablesSync or {}
local S = SF.ConsumablesSync
local C = SF.Consumables

local function Same(a, b)
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b) and true or false
    end
    return a ~= nil and a == b
end

function S.AuthorizeOp(profile, op, sender)
    if type(op) ~= "table" then return false end
    if op.name == "add_assignment" or op.name == "remove_assignment" then
        return C.CanEditAssignment(profile, sender, op.crafter, {
            asAdmin = C.IsCanonicalAdmin(profile, sender),
        })
    end
    if op.name == "add_crafter" or op.name == "remove_crafter" or op.name == "set_guild"
        or op.name == "set_bank_tab" or op.name == "clear"
    then
        return C.IsCanonicalAdmin(profile, sender)
    end
    return false
end

function S.SessionEnvelopeOk(state, payload)
    state = state or {}
    if state.active ~= true then return false end
    if type(payload) ~= "table" then return false end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return false end
    if payload.sessionId ~= state.sessionId then return false end
    if type(payload.profileId) ~= "string" or payload.profileId == "" then return false end
    if payload.profileId ~= state.profileId then return false end
    return true
end

function S.RemoteConfigSenderOk(coordinator, sender)
    return Same(coordinator, sender)
end

function S.ApplyRemoteConfig(profile, payload, sender)
    if type(payload) ~= "table" then
        return false, "invalid"
    end
    if not C.IsCanonicalAdmin(profile, sender) then
        return false, "unauthorized"
    end
    local localDesc = C.Descriptor(profile)
    local remoteGen = tonumber(payload.generation) or 1
    local remoteSeq = tonumber(payload.configSeq) or 0
    if remoteGen < localDesc.generation then
        return true, "stale"
    end
    if remoteGen == localDesc.generation and remoteSeq <= localDesc.configSeq then
        return true, "stale"
    end
    if remoteGen > localDesc.generation + 1 or remoteSeq > localDesc.configSeq + 1 then
        return false, "gap"
    end
    C.ReplaceConfig(profile, payload)
    return true, "applied"
end

local function TradeWriter(event, sender)
    return event.source == "trade" and event.crafter and Same(event.crafter, sender)
end

local function PositiveQuantity(event)
    local qty = tonumber(event.quantity) or 0
    local itemId = tonumber(event.itemId)
    if not itemId or itemId <= 0 or itemId ~= math.floor(itemId) then return false end
    if qty <= 0 then return false end
    if type(event.generation) ~= "number" then return false end
    return true
end

local function CustodyWriterOk(profile, event, sender)
    if not PositiveQuantity(event) then return false end
    local action = event.action
    if action == C.ACTION.WITHDRAW or action == C.ACTION.RETURN then
        return event.holder and Same(event.actor, sender) and Same(event.holder, sender)
            and C.IsCanonicalAdmin(profile, sender)
    end
    if action == C.ACTION.TRANSFER then
        return event.toHolder and event.fromHolder
            and Same(event.actor, sender) and Same(event.toHolder, sender)
            and C.IsCanonicalAdmin(profile, event.fromHolder)
            and C.IsCanonicalAdmin(profile, event.toHolder)
    end
    if action == C.ACTION.DELIVER then
        local crafter = event.toHolder or event.crafter
        return crafter and event.fromHolder
            and Same(event.actor, sender) and Same(crafter, sender)
            and C.CrafterHasItem(profile, sender, tonumber(event.itemId))
    end
    return false
end

function S.ApplyRemoteEvent(profile, event, sender)
    if type(event) ~= "table" or type(event.id) ~= "string" or type(event.type) ~= "string" then
        return false, "invalid"
    end
    if event.type == C.EVENT.RESET or event.type == C.EVENT.RESOLVE then
        if not (event.actor and Same(event.actor, sender) and C.IsCanonicalAdmin(profile, sender)) then
            return false, "unauthorized"
        end
    elseif event.type == C.EVENT.DONATION then
        local allowed = (event.actor and Same(event.actor, sender)) or TradeWriter(event, sender)
        if not allowed then
            return false, "unauthorized"
        end
    elseif event.type == C.EVENT.RECEIPT then
        if not (event.actor and Same(event.actor, sender)) then
            return false, "unauthorized"
        end
    elseif event.type == C.EVENT.CUSTODY then
        if not CustodyWriterOk(profile, event, sender) then
            return false, "unauthorized"
        end
    else
        return false, "invalid"
    end
    return C.AppendEvent(profile, event)
end

function S.NeedsCatchUp(localDesc, remote)
    remote = remote or {}
    local remoteGen = tonumber(remote.generation)
    local remoteSeq = tonumber(remote.configSeq)
    local remoteEvents = tonumber(remote.eventCount)
    if not remoteGen and not remoteSeq and not remoteEvents then
        return false
    end
    if remoteGen and remoteGen > (localDesc.generation or 1) then return true end
    if remoteSeq and remoteSeq > (localDesc.configSeq or 0) then return true end
    if remoteEvents and remoteEvents > (localDesc.eventCount or 0) then return true end
    local remoteFingerprint = tonumber(remote.eventFingerprint)
    local localFingerprint = tonumber(localDesc.eventFingerprint)
    if remoteFingerprint and localFingerprint and remoteFingerprint ~= localFingerprint then
        return true
    end
    return false
end
