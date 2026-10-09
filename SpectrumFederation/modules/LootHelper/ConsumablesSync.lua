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
S.MAX_EVENT_QUANTITY = 100000

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
    if op.name == "add_item" or op.name == "remove_item" or op.name == "set_goal"
        or op.name == "set_guild" or op.name == "set_bank_tab" or op.name == "clear"
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

local coordinatorWatermark = setmetatable({}, { __mode = "k" })

function S.ClearCoordinatorWatermarks()
    local stale = {}
    for profile in pairs(coordinatorWatermark) do
        stale[#stale + 1] = profile
    end
    for i = 1, #stale do
        coordinatorWatermark[stale[i]] = nil
    end
end

function S.CoordinatorWatermark(profile)
    return coordinatorWatermark[profile]
end

function S.NoteCoordinatorWatermark(profile, generation, configSeq, epoch)
    if type(profile) ~= "table" then return end
    coordinatorWatermark[profile] = {
        generation = tonumber(generation) or 1,
        configSeq = tonumber(configSeq) or 0,
        epoch = tonumber(epoch) or 0,
    }
end

local function WatermarkIsNewer(remoteGen, remoteSeq, noted, epoch)
    if not noted then return true end
    local notedEpoch = tonumber(noted.epoch) or 0
    local incomingEpoch = tonumber(epoch) or 0
    if incomingEpoch ~= notedEpoch then
        return incomingEpoch > notedEpoch
    end
    if remoteGen > noted.generation then return true end
    if remoteGen == noted.generation and remoteSeq > noted.configSeq then return true end
    return false
end

function S.WatermarkAdmits(profile, remoteGen, remoteSeq, epoch)
    local noted = coordinatorWatermark[profile]
    if not noted then return true end
    local notedEpoch = tonumber(noted.epoch) or 0
    local incomingEpoch = tonumber(epoch) or 0
    if incomingEpoch ~= notedEpoch then
        return incomingEpoch > notedEpoch
    end
    if remoteGen > noted.generation then return true end
    if remoteGen == noted.generation and remoteSeq >= noted.configSeq then return true end
    return false
end

function S.ApplyRemoteConfig(profile, payload, sender, opts)
    if type(payload) ~= "table" then
        return false, "invalid"
    end
    if not C.IsCanonicalAdmin(profile, sender) then
        return false, "unauthorized"
    end
    opts = type(opts) == "table" and opts or {}
    local localDesc = C.Descriptor(profile)
    local remoteGen = C.ValidGeneration(payload.generation)
    if payload.generation == nil then
        remoteGen = 1
    elseif not remoteGen then
        return false, "invalid"
    end
    local remoteSeq = C.ValidConfigSeq(payload.configSeq)
    if payload.configSeq == nil then
        remoteSeq = 0
    elseif not remoteSeq then
        return false, "invalid"
    end
    local epoch = opts.coordEpoch
    if opts.coordinatorAuthoritative then
        if not WatermarkIsNewer(remoteGen, remoteSeq, coordinatorWatermark[profile], epoch) then
            return true, "stale"
        end
        local replaced, replaceErr = C.ReplaceConfig(profile, payload)
        if not replaced then
            return false, replaceErr or "invalid"
        end
        S.NoteCoordinatorWatermark(profile, remoteGen, remoteSeq, epoch)
        return true, "applied"
    end
    if remoteGen < localDesc.generation then
        return true, "stale"
    end
    if remoteGen == localDesc.generation and remoteSeq <= localDesc.configSeq then
        return true, "stale"
    end
    if remoteGen > localDesc.generation + 1 or remoteSeq > localDesc.configSeq + 1 then
        return false, "gap"
    end
    local replaced, replaceErr = C.ReplaceConfig(profile, payload)
    if not replaced then
        return false, replaceErr or "invalid"
    end
    S.NoteCoordinatorWatermark(profile, remoteGen, remoteSeq, epoch)
    return true, "applied"
end

function S.CoordinatorConfigDiffers(localDesc, remote)
    remote = remote or {}
    localDesc = localDesc or {}
    local remoteGen = tonumber(remote.generation)
    local remoteSeq = tonumber(remote.configSeq)
    if remoteGen and remoteGen ~= (localDesc.generation or 1) then return true end
    if remoteSeq and remoteSeq ~= (localDesc.configSeq or 0) then return true end
    local remoteRej = tonumber(remote.rejectionSeq)
    local localRej = tonumber(localDesc.rejectionSeq)
    if remoteRej and localRej and remoteRej ~= localRej then return true end
    local remoteAlloc = tonumber(remote.txnAllocSeq)
    local localAlloc = tonumber(localDesc.txnAllocSeq)
    if remoteAlloc and localAlloc and remoteAlloc ~= localAlloc then return true end
    local remoteFp = tonumber(remote.configFingerprint)
    local localFp = tonumber(localDesc.configFingerprint)
    if remoteFp and localFp and remoteFp ~= localFp then return true end
    return false
end

function S.CatchUpKind(localDesc, remote)
    if not S.NeedsCatchUp(localDesc, remote) then return "none" end
    remote = remote or {}
    localDesc = localDesc or {}
    local ahead = (tonumber(remote.generation) or 0) > (localDesc.generation or 1)
        or (tonumber(remote.configSeq) or 0) > (localDesc.configSeq or 0)
        or (tonumber(remote.eventCount) or 0) > (localDesc.eventCount or 0)
        or (tonumber(remote.txnAllocSeq) or 0) > (localDesc.txnAllocSeq or 0)
    if ahead then return "ahead" end
    return "fingerprint"
end

local function PositiveQuantity(event)
    local qty = tonumber(event.quantity)
    local itemId = tonumber(event.itemId)
    if not itemId or itemId <= 0 or itemId ~= math.floor(itemId) then return false end
    if not qty or qty ~= qty or qty < 1 or qty > S.MAX_EVENT_QUANTITY or qty ~= math.floor(qty) then
        return false
    end
    if type(event.generation) ~= "number" then return false end
    return true
end

-- Semantic body checks for coordinator snapshot rows (no sender binding).
function S.AuthoritativeEventBodyOk(event)
    if type(event) ~= "table" or type(event.id) ~= "string" or event.id == "" then
        return false
    end
    if type(event.type) ~= "string" then return false end
    if event.type == C.EVENT.DONATION then
        if event.source ~= "guildbank" then return false end
        if type(event.actor) ~= "string" or event.actor == "" then return false end
        if not PositiveQuantity(event) then return false end
        -- Post-migration: reject legacy donation rows that lack verified provenance.
        if not (C.ValidTxnId and C.ValidTxnId(event.txnId)) then return false end
        return true
    end
    if event.type == C.EVENT.RESET then
        return type(event.actor) == "string" and event.actor ~= ""
    end
    return false
end

function S.RelayWriter(event)
    if type(event) ~= "table" then return nil end
    if type(event.writer) == "string" and event.writer ~= "" and S.RemoteEventIdOk(event.id, event.writer) then
        return event.writer
    end
    return nil
end

function S.RemoteEventAdmission(isCoordinator, fromCoordinator, event)
    if type(event) ~= "table" then return false, false end
    if isCoordinator == true then
        event.order = nil
        event.writer = nil
        return true, false
    end
    local order = C.ValidOrder and C.ValidOrder(event.order) or nil
    if fromCoordinator == true and order then
        return true, true
    end
    return false, false
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
    if event.type == C.EVENT.RESET then
        if not (event.actor and Same(event.actor, writer) and C.IsCanonicalAdmin(profile, writer)) then
            return false, "unauthorized"
        end
    elseif event.type == C.EVENT.DONATION then
        -- Verified Guild Bank provenance: donor (actor) may differ from writer.
        if event.source ~= "guildbank" then
            return false, "unauthorized"
        end
        if not (event.actor and PositiveQuantity(event)) then
            return false, "unauthorized"
        end
        local txnId = C.ValidTxnId and C.ValidTxnId(event.txnId)
        if not txnId then
            return false, "unauthorized"
        end
        if opts.coordinatorRelay then
            -- Coordinator already validated; writer must own the event id.
            if not writer then
                return false, "unauthorized"
            end
        else
            -- Non-admins cannot insert canonical contributions over the wire.
            if not C.IsCanonicalAdmin(profile, writer) then
                return false, "unauthorized"
            end
        end
    else
        -- Receipt/custody/trade events are no longer accepted.
        return false, "invalid"
    end
    event.writer = writer
    local ok, status = C.AppendEvent(profile, event, {
        replaceOrder = opts.coordinatorRelay == true,
        silent = opts.silent == true,
    })
    return ok, status
end

function S.NeedsCatchUp(localDesc, remote)
    remote = remote or {}
    localDesc = localDesc or {}
    local remoteGen = tonumber(remote.generation)
    local remoteSeq = tonumber(remote.configSeq)
    local remoteEvents = tonumber(remote.eventCount)
    local remoteArchiveCount = tonumber(remote.archiveCount)
    local remoteArchiveFingerprint = tonumber(remote.archiveFingerprint)
    if not remoteGen and not remoteSeq and not remoteEvents
        and not remoteArchiveCount and not remoteArchiveFingerprint then
        return false
    end
    if remoteGen and remoteGen > (localDesc.generation or 1) then return true end
    if remoteSeq and remoteSeq > (localDesc.configSeq or 0) then return true end
    if remoteEvents and remoteEvents > (localDesc.eventCount or 0) then return true end
    local remoteAlloc = tonumber(remote.txnAllocSeq)
    if remoteAlloc and remoteAlloc > (localDesc.txnAllocSeq or 0) then return true end
    local remoteFingerprint = tonumber(remote.eventFingerprint)
    local localFingerprint = tonumber(localDesc.eventFingerprint)
    if remoteFingerprint and localFingerprint and remoteFingerprint ~= localFingerprint then
        return true
    end
    if remoteArchiveCount and remoteArchiveCount ~= (tonumber(localDesc.archiveCount) or 0) then
        return true
    end
    local localArchiveFingerprint = tonumber(localDesc.archiveFingerprint)
    if remoteArchiveFingerprint and localArchiveFingerprint and remoteArchiveFingerprint ~= localArchiveFingerprint then
        return true
    end
    return false
end
