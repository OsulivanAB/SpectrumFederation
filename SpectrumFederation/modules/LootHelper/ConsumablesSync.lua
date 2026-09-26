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

S.MAX_REMOTE_OPS = 20
S.REMOTE_OP_WINDOW = 10

function S.AllowRemoteOp(bucket, sender, now)
    if type(bucket) ~= "table" or type(sender) ~= "string" or sender == "" then
        return false
    end
    now = tonumber(now) or 0
    local row = bucket[sender]
    if type(row) ~= "table" or now - (tonumber(row.start) or 0) >= S.REMOTE_OP_WINDOW then
        bucket[sender] = { start = now, count = 1 }
        return true
    end
    if (tonumber(row.count) or 0) >= S.MAX_REMOTE_OPS then
        return false
    end
    row.count = row.count + 1
    return true
end

function S.RemoteEventIdOk(eventId, sender)
    if type(eventId) ~= "string" or type(sender) ~= "string" or sender == "" then
        return false
    end
    if eventId:find(":" .. sender .. ":", 1, true) then return true end
    if eventId:find("-" .. sender .. "-", 1, true) then return true end
    return false
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

function S.RelayWriter(event)
    if type(event) ~= "table" then return nil end
    local names = { event.actor, event.crafter, event.holder, event.toHolder }
    for i = 1, #names do
        if type(names[i]) == "string" and S.RemoteEventIdOk(event.id, names[i]) then
            return names[i]
        end
    end
    return nil
end

function S.ClearCapabilityFlags(peers)
    if type(peers) ~= "table" then return end
    for _, peer in pairs(peers) do
        if type(peer) == "table" then
            peer.consumablesCapable = nil
        end
    end
end

function S.ApplyRemoteEvent(profile, event, sender, opts)
    if type(event) ~= "table" or type(event.id) ~= "string" or type(event.type) ~= "string" then
        return false, "invalid"
    end
    opts = type(opts) == "table" and opts or {}
    local writer = sender
    if opts.coordinatorRelay then
        writer = S.RelayWriter(event)
        if not writer then
            return false, "unauthorized"
        end
    elseif not S.RemoteEventIdOk(event.id, sender) then
        return false, "unauthorized"
    end
    if event.type == C.EVENT.RESET or event.type == C.EVENT.RESOLVE then
        if not (event.actor and Same(event.actor, writer) and C.IsCanonicalAdmin(profile, writer)) then
            return false, "unauthorized"
        end
    elseif event.type == C.EVENT.DONATION then
        local allowed = (event.actor and Same(event.actor, writer)) or TradeWriter(event, writer)
        if not allowed then
            return false, "unauthorized"
        end
    elseif event.type == C.EVENT.RECEIPT then
        if not (event.actor and Same(event.actor, writer) and event.crafter and Same(event.crafter, writer)
            and PositiveQuantity(event) and C.CrafterHasItem(profile, writer, tonumber(event.itemId))) then
            return false, "unauthorized"
        end
    elseif event.type == C.EVENT.CUSTODY then
        if not CustodyWriterOk(profile, event, writer) then
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
