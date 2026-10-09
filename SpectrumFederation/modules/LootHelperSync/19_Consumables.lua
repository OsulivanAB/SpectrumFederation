-- Raid Consumables session transport.
-- Config edits in a live session are authorized by the coordinator, then broadcast.
-- Accounting events are written by the client that observed the transfer.
local _, SF = ...

SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

local function Consumables()
    return SF.Consumables
end

local function Rules()
    return SF.ConsumablesSync
end

local function Debug(level, fmt, ...)
    if not SF.Debug then return end
    local fn = SF.Debug[level]
    if fn then
        fn(SF.Debug, "CONSUMABLES", fmt, ...)
    end
end

local function ProfileIdOf(profile)
    if type(profile) ~= "table" then return nil end
    if profile.GetProfileId then
        return profile:GetProfileId()
    end
    return profile._profileId
end

local function SessionFor(profile)
    if not (Sync.state and Sync.state.active) then return false end
    return ProfileIdOf(profile) == Sync.state.profileId
end

local CONFIG_CATCHUP_GRACE = 15

local function LedgerMatches(localDesc, remote)
    localDesc = localDesc or {}
    remote = remote or {}
    local remoteEvents = tonumber(remote.eventCount)
    if remoteEvents and remoteEvents ~= (tonumber(localDesc.eventCount) or 0) then
        return false
    end
    local remoteFingerprint = tonumber(remote.eventFingerprint)
    local localFingerprint = tonumber(localDesc.eventFingerprint)
    if remoteFingerprint and localFingerprint and remoteFingerprint ~= localFingerprint then
        return false
    end
    local remoteArchive = tonumber(remote.archiveCount)
    if remoteArchive and remoteArchive ~= (tonumber(localDesc.archiveCount) or 0) then
        return false
    end
    local remoteArchiveFingerprint = tonumber(remote.archiveFingerprint)
    local localArchiveFingerprint = tonumber(localDesc.archiveFingerprint)
    if remoteArchiveFingerprint and localArchiveFingerprint
        and remoteArchiveFingerprint ~= localArchiveFingerprint then
        return false
    end
    return true
end

function Sync:_ConsumablesCoordinatorAccepts()
    if not (self.state and self.state.active) then return true end
    if self.state.isCoordinator then return true end
    local coordinator = self.state.coordinator
    if type(coordinator) ~= "string" or coordinator == "" then return false end
    -- An unproven catch-up coordinator has no stored grant. Do not ask them to
    -- stamp events until local history can authenticate them.
    if self._UnprovenCatchUpKeepalive and self:_UnprovenCatchUpKeepalive(coordinator) then
        return false
    end
    local peers = self.state.peers
    local peer = type(peers) == "table" and peers[coordinator] or nil
    return type(peer) == "table" and peer.consumablesCapable == true
end

local MAX_CAPABLE_PEERS = 40
local MAX_EVENT_FLUSH = 8
local MAX_EVENT_SCAN = 64

function Sync:_ClearConsumablesCapability()
    local S = Rules()
    if S and S.ClearCapabilityFlags then
        S.ClearCapabilityFlags(self.state and self.state.peers)
    end
    if S and S.ClearCoordinatorWatermarks then
        S.ClearCoordinatorWatermarks()
    end
end

function Sync:_ConsumablesCapablePeers()
    local names = {}
    local seen = {}
    local function add(name)
        if type(name) ~= "string" or name == "" or seen[name] or #names >= MAX_CAPABLE_PEERS then
            return
        end
        seen[name] = true
        names[#names + 1] = name
    end
    if self._SelfId then
        add(self:_SelfId())
    end
    local peers = self.state and self.state.peers
    if type(peers) == "table" then
        for name, peer in pairs(peers) do
            if type(peer) == "table" and peer.consumablesCapable == true and peer.inGroup == true then
                add(name)
            end
        end
    end
    return names
end

function Sync:_NoteConsumablesCapability(sender, payload)
    if type(payload) ~= "table" or not self.TouchPeer then return end
    local function inGroup(name)
        return self.IsRequesterInGroup and self:IsRequesterInGroup(name) and true or false
    end
    if payload.consumablesCapable == true and type(sender) == "string" and sender ~= "" and inGroup(sender) then
        self:TouchPeer(sender, { consumablesCapable = true })
    end
    local coordinator = self.state and self.state.coordinator
    if not (type(coordinator) == "string" and self._SamePlayer and self:_SamePlayer(sender, coordinator)) then
        return
    end
    local peers = payload.consumablesCapablePeers
    if type(peers) ~= "table" then return end
    local limit = #peers
    if limit > MAX_CAPABLE_PEERS then limit = MAX_CAPABLE_PEERS end
    for i = 1, limit do
        local name = peers[i]
        if type(name) == "string" and name ~= "" and inGroup(name) then
            self:TouchPeer(name, { consumablesCapable = true })
        end
    end
end

function Sync:_AttachConsumablesDescriptor(payload, profileId)
    local C = Consumables()
    if not C or type(payload) ~= "table" then return end
    payload.consumablesCapable = true
    payload.consumablesCapablePeers = self:_ConsumablesCapablePeers()
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(profileId) or nil
    if not profile then return end
    -- Flush before Descriptor so heartbeats advertise the stamped ledger fingerprint,
    -- not a stale pre-flush watermark that forces follower snapshot storms.
    if not (self.state and self.state.isCoordinator and self.state._sessionAnnounced ~= self.state.sessionId) then
        self:_FlushUnsentConsumablesEvents(profile)
    end
    local desc = C.Descriptor(profile)
    payload.consumablesGeneration = desc.generation
    payload.consumablesConfigSeq = desc.configSeq
    payload.consumablesRejectionSeq = desc.rejectionSeq
    payload.consumablesTxnAllocSeq = desc.txnAllocSeq
    payload.consumablesConfigFingerprint = desc.configFingerprint
    payload.consumablesEventCount = desc.eventCount
    payload.consumablesEventFingerprint = desc.eventFingerprint
    payload.consumablesArchiveCount = desc.archiveCount
    payload.consumablesArchiveFingerprint = desc.archiveFingerprint
end

function Sync:_RefreshConsumablesHistoryGate(profile)
    if type(profile) ~= "table" then return end
    local C = Consumables()
    local S = Rules()
    if not C or not S or not S.NeedsCatchUp then return end
    local remote = profile._consumablesCatchUpRemote
    if type(remote) ~= "table" then
        profile._consumablesPeerHistoryAhead = nil
        return
    end
    if not S.NeedsCatchUp(C.Descriptor(profile), remote) then
        profile._consumablesCatchUpRemote = nil
        profile._consumablesPeerHistoryAhead = nil
    end
end

function Sync:_NotePeerConsumablesHistory(sender, payload)
    local C = Consumables()
    local S = Rules()
    if not C or not S or type(payload) ~= "table" then return end
    if not (self.state and self.state.active and self.state.isCoordinator) then return end
    if payload.profileId ~= self.state.profileId then return end
    if payload.sessionId and self.state.sessionId and payload.sessionId ~= self.state.sessionId then
        return
    end
    -- Ignore self-advertisements; peer recovery is for other authorized members.
    local selfId = nil
    if type(self._SelfId) == "function" then
        selfId = self:_SelfId()
    end
    if type(sender) == "string" and type(selfId) == "string" and self._SamePlayer
        and self:_SamePlayer(sender, selfId) then
        return
    end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(payload.profileId) or nil
    if not profile then return end
    local peerDesc = {
        generation = payload.consumablesGeneration,
        configSeq = payload.consumablesConfigSeq,
        rejectionSeq = payload.consumablesRejectionSeq,
        txnAllocSeq = payload.consumablesTxnAllocSeq,
        configFingerprint = payload.consumablesConfigFingerprint,
        eventCount = payload.consumablesEventCount,
        eventFingerprint = payload.consumablesEventFingerprint,
        archiveCount = payload.consumablesArchiveCount,
        archiveFingerprint = payload.consumablesArchiveFingerprint,
    }
    local localDesc = C.Descriptor(profile)
    if not (S.PeerHistoryAhead and S.PeerHistoryAhead(localDesc, peerDesc)) then
        self:_RefreshConsumablesHistoryGate(profile)
        return
    end
    profile._consumablesCatchUpRemote = (S.MergeHistoryWatermark and S.MergeHistoryWatermark(
        profile._consumablesCatchUpRemote, peerDesc)) or peerDesc
    profile._consumablesPeerHistoryAhead = true
    Debug("Info", "coordinator holding consumables credits until peer history converges from %s",
        tostring(sender))
end

function Sync:_ConsumablesHistoryReady(profile)
    if type(profile) ~= "table" then return true end
    local C = Consumables()
    local S = Rules()
    if not C or not S or not S.NeedsCatchUp then return true end
    self:_RefreshConsumablesHistoryGate(profile)
    local remote = profile._consumablesCatchUpRemote
    if type(remote) ~= "table" then return true end
    return not S.NeedsCatchUp(C.Descriptor(profile), remote)
end

function Sync:_ConsiderConsumablesCatchUp(payload, opts)
    local C = Consumables()
    local S = Rules()
    if not C or not S or type(payload) ~= "table" then return end
    if not (self.state and self.state.active) then return end
    self:_NoteConsumablesCapability(payload.coordinator, payload)
    if payload.profileId ~= self.state.profileId then return end
    if payload.sessionId and self.state.sessionId and payload.sessionId ~= self.state.sessionId then
        return
    end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(payload.profileId) or nil
    if not profile then
        return
    end
    local remote = {
        generation = payload.consumablesGeneration,
        configSeq = payload.consumablesConfigSeq,
        rejectionSeq = payload.consumablesRejectionSeq,
        txnAllocSeq = payload.consumablesTxnAllocSeq,
        configFingerprint = payload.consumablesConfigFingerprint,
        eventCount = payload.consumablesEventCount,
        eventFingerprint = payload.consumablesEventFingerprint,
        archiveCount = payload.consumablesArchiveCount,
        archiveFingerprint = payload.consumablesArchiveFingerprint,
    }
    local localDesc = C.Descriptor(profile)
    local fingerprintsDiffer = tonumber(remote.eventFingerprint) and tonumber(localDesc.eventFingerprint)
        and tonumber(remote.eventFingerprint) ~= tonumber(localDesc.eventFingerprint)
    if fingerprintsDiffer then
        local key = tostring(localDesc.eventFingerprint) .. ":" .. tostring(remote.eventFingerprint)
        if profile._consumablesResendKey ~= key then
            profile._consumablesResendKey = key
            profile._consumablesResendCursor = 1
        end
        self:_QueueUnsequencedConsumablesEvents(profile)
    end
    self:_QueueAuthoredOrderedConsumablesEvents(profile, remote.eventCount, fingerprintsDiffer)
    local remoteArchiveCount = tonumber(remote.archiveCount)
    local remoteArchiveFingerprint = tonumber(remote.archiveFingerprint)
    local localArchiveFingerprint = tonumber(localDesc.archiveFingerprint)
    local archiveDiffers = (remoteArchiveCount and remoteArchiveCount ~= (tonumber(localDesc.archiveCount) or 0))
        or (remoteArchiveFingerprint and localArchiveFingerprint and remoteArchiveFingerprint ~= localArchiveFingerprint)
    local archiveDescriptor = tostring(remoteArchiveCount) .. ":" .. tostring(remoteArchiveFingerprint)
    self:_QueueAuthoredArchivedConsumablesEvents(profile, archiveDiffers and true or false, archiveDescriptor)
    -- Finish ordered/unsequenced resend scans in this pass so catch-up is not
    -- deferred across heartbeats. Queue before the final flush; do not enqueue
    -- more IDs after that flush before requesting the snapshot.
    do
        local events = profile._consumableEvents
        local orderedKey = tostring(self.state.sessionId) .. ":" .. tostring(self.state.coordinator)
        local maxDrain = math.floor(((C.MAX_LEDGER_EVENTS or 4096) / MAX_EVENT_SCAN) + 4)
        for _ = 1, maxDrain do
            local pending = false
            if profile._consumablesOrderedResendKey == orderedKey then
                local cursor = tonumber(profile._consumablesOrderedResendCursor)
                if type(events) == "table" and cursor and cursor <= #events then
                    pending = true
                    self:_QueueAuthoredOrderedConsumablesEvents(profile, remote.eventCount, fingerprintsDiffer)
                end
            end
            if type(profile._consumablesResendCursor) == "number" and type(events) == "table"
                and profile._consumablesResendCursor <= #events then
                pending = true
                self:_QueueUnsequencedConsumablesEvents(profile)
            end
            if not pending then break end
        end
    end
    self:_FlushUnsentConsumablesEvents(profile)
    local authority = table.concat({
        tostring(self.state.sessionId),
        tostring(self.state.coordEpoch),
        tostring(self.state.coordinator),
    }, ":")
    local configDiffers = S.CoordinatorConfigDiffers and S.CoordinatorConfigDiffers(localDesc, remote)
    local nowCfg = self._Now and self:_Now() or 0
    if not configDiffers then
        profile._consumablesConfigCatchUpAt = nil
        profile._consumablesConfigDiffSince = nil
        profile._consumablesConfigDiffAuthority = nil
    elseif profile._consumablesConfigDiffAuthority ~= authority or not tonumber(profile._consumablesConfigDiffSince) then
        profile._consumablesConfigDiffAuthority = authority
        profile._consumablesConfigDiffSince = nowCfg
    end
    local diffSince = tonumber(profile._consumablesConfigDiffSince)
    local graceOver = diffSince and (nowCfg - diffSince) >= CONFIG_CATCHUP_GRACE
    local catchUpAt = tonumber(profile._consumablesConfigCatchUpAt)
    local configRetryDue = (not catchUpAt) or catchUpAt > nowCfg or (nowCfg - catchUpAt) >= 120
    if configDiffers and graceOver and (profile._consumablesConfigCatchUpSession ~= authority or configRetryDue) then
        local requested = false
        if self.RequestProfileSnapshot then
            requested = self:RequestProfileSnapshot("consumables-config", { coordinatorOnly = true }) and true or false
        end
        if requested then
            profile._consumablesConfigCatchUpSession = authority
            profile._consumablesConfigCatchUpAt = nowCfg
            profile._consumablesAdoptNextSnapshot = self.state.sessionId
        end
    end
    -- SES_START / SES_REANNOUNCE advertise before the NORMAL event flush. Record
    -- capability and config above; leave ledger catch-up to the heartbeat.
    if type(opts) == "table" and opts.deferLedgerCatchUp then
        return
    end
    if not S.NeedsCatchUp(localDesc, remote) then
        return
    end
    if configDiffers and LedgerMatches(localDesc, remote) and not graceOver then
        return
    end
    -- Resend cursors were drained above before the flush. Keep a safety gate if
    -- a drain bound left work unfinished; otherwise proceed to snapshot.
    local events = profile._consumableEvents
    local orderedKey = tostring(self.state.sessionId) .. ":" .. tostring(self.state.coordinator)
    if profile._consumablesOrderedResendKey == orderedKey then
        local cursor = tonumber(profile._consumablesOrderedResendCursor)
        if type(events) == "table" and cursor and cursor <= #events then
            return
        end
    end
    if type(profile._consumablesResendCursor) == "number" and type(events) == "table"
        and profile._consumablesResendCursor <= #events then
        return
    end
    local fingerprintOnly = S.CatchUpKind and S.CatchUpKind(localDesc, remote) == "fingerprint"
    local nowFp = nil
    if fingerprintOnly then
        nowFp = self._Now and self:_Now() or 0
        if self._consumablesFpSnapshotSession ~= self.state.sessionId then
            self._consumablesFpSnapshotSession = self.state.sessionId
            self._consumablesFpSnapshotAt = nil
        end
        if self._consumablesFpSnapshotAt and nowFp - self._consumablesFpSnapshotAt < 120 then
            return
        end
    end
    local key = table.concat({
        tostring(payload.sessionId),
        tostring(payload.consumablesGeneration),
        tostring(payload.consumablesConfigSeq),
        tostring(payload.consumablesEventCount),
        tostring(payload.consumablesEventFingerprint),
        tostring(payload.consumablesArchiveCount),
        tostring(payload.consumablesArchiveFingerprint),
    }, ":")
    if self._consumablesCatchUpKey == key then
        return
    end
    local requested = false
    if self.RequestProfileSnapshot then
        local snapOpts = nil
        if profile._consumablesCatchUpWantCoordinator then
            snapOpts = { coordinatorOnly = true }
        end
        requested = self:RequestProfileSnapshot("consumables-catchup", snapOpts) and true or false
    end
    if not requested then
        return
    end
    -- Start the fingerprint retry window only after a real request so a busy
    -- route or in-flight profile request does not suppress later heartbeats.
    if fingerprintOnly then
        self._consumablesFpSnapshotAt = nowFp or (self._Now and self:_Now() or 0)
    end
    self._consumablesCatchUpKey = key
    profile._consumablesCatchUpRemote = remote
end

function Sync:_NoteConsumablesSnapshot(profile, fromCoordinator)
    local C = Consumables()
    local S = Rules()
    if not C or not S or type(profile) ~= "table" then return end
    if not (self.state and self.state.active) then return end
    if ProfileIdOf(profile) ~= self.state.profileId then return end
    local remote = profile._consumablesCatchUpRemote
    if type(remote) ~= "table" then return end
    if not S.NeedsCatchUp(C.Descriptor(profile), remote) then
        self._consumablesCatchUpKey = nil
        profile._consumablesCatchUpRemote = nil
        profile._consumablesCatchUpWantCoordinator = nil
        return
    end
    if fromCoordinator or profile._consumablesCatchUpWantCoordinator then
        return
    end
    self._consumablesCatchUpKey = nil
    profile._consumablesCatchUpWantCoordinator = true
end

function Sync:_ClearConsumablesCatchUpDedupe()
    self._consumablesCatchUpKey = nil
end

local function SessionPayloadOk(payload, sender)
    local S = Rules()
    if not S or not S.SessionEnvelopeOk(Sync.state, payload) then return false end
    if type(sender) ~= "string" or sender == "" then return false end
    if not (Sync.IsRequesterInGroup and Sync:IsRequesterInGroup(sender)) then return false end
    return true
end

function Sync:_PruneUnsentConsumablesEvents(profile)
    if type(profile) ~= "table" or type(profile._consumablesUnsent) ~= "table" then return end
    local C = Consumables()
    local cap = 8192
    if C and C.MAX_LEDGER_EVENTS and C.MAX_ARCHIVED_EVENTS then
        cap = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
    end
    local queue = profile._consumablesUnsent
    if #queue > cap then
        local tail = {}
        local startAt = #queue - cap + 1
        for i = startAt, #queue do
            tail[#tail + 1] = queue[i]
        end
        queue = tail
        profile._consumablesUnsent = queue
    end
    local index = C and C.EventIndex and C.EventIndex(profile)
    if type(index) ~= "table" then return end
    local kept = {}
    for i = 1, #queue do
        local id = queue[i]
        if type(id) == "string" and index[id] then
            kept[#kept + 1] = id
        end
    end
    profile._consumablesUnsent = kept
end

function Sync:_QueueUnsentConsumablesEvent(profile, eventId)
    if type(profile) ~= "table" or type(eventId) ~= "string" or eventId == "" then return end
    local queue = profile._consumablesUnsent
    if type(queue) ~= "table" then
        queue = {}
        profile._consumablesUnsent = queue
    end
    local C = Consumables()
    local cap = C and C.MAX_LEDGER_EVENTS and C.MAX_ARCHIVED_EVENTS and (C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS) or 8192
    if #queue >= cap then
        self:_PruneUnsentConsumablesEvents(profile)
        queue = profile._consumablesUnsent
        if type(queue) ~= "table" then return end
        if #queue >= cap then return end
    end
    for i = 1, #queue do
        if queue[i] == eventId then return end
    end
    queue[#queue + 1] = eventId
end

function Sync:_QueueAuthoredOrderedConsumablesEvents(profile, remoteEventCount, fingerprintsDiffer)
    if self.state and self.state.isCoordinator then return end
    local events = profile and profile._consumableEvents
    if type(events) ~= "table" then return end
    if #events <= (tonumber(remoteEventCount) or 0) and not fingerprintsDiffer then return end
    local C = Consumables()
    local S = Rules()
    local who = self._SelfId and self:_SelfId() or nil
    if not C or not S or type(who) ~= "string" or who == "" then return end
    local key = tostring(self.state and self.state.sessionId) .. ":" .. tostring(self.state and self.state.coordinator)
    if profile._consumablesOrderedResendKey ~= key then
        profile._consumablesOrderedResendKey = key
        profile._consumablesOrderedResendCursor = 1
    end
    local index = profile._consumablesOrderedResendCursor
    if type(index) ~= "number" or index < 1 then index = 1 end
    if index > #events then return end
    local queued = 0
    local scanned = 0
    while index <= #events and queued < MAX_EVENT_FLUSH and scanned < MAX_EVENT_SCAN do
        local event = events[index]
        if type(event) == "table" and type(event.id) == "string"
            and C.ValidOrder(event.order) and S.RemoteEventIdOk(event.id, who) then
            self:_QueueUnsentConsumablesEvent(profile, event.id)
            queued = queued + 1
        end
        index = index + 1
        scanned = scanned + 1
    end
    profile._consumablesOrderedResendCursor = index
end

function Sync:_QueueAuthoredArchivedConsumablesEvents(profile, archiveDiffers, archiveDescriptor)
    if not archiveDiffers then return end
    if self.state and self.state.isCoordinator then return end
    local archive = profile and profile._consumableEventArchive
    if type(archive) ~= "table" then return end
    local S = Rules()
    local who = self._SelfId and self:_SelfId() or nil
    if not S or type(who) ~= "string" or who == "" then return end
    local key = tostring(self.state and self.state.sessionId) .. ":" .. tostring(self.state and self.state.coordinator) .. ":" .. tostring(archiveDescriptor)
    if profile._consumablesArchiveResendKey == key then return end
    profile._consumablesArchiveResendKey = key
    local C = Consumables()
    local cap = C and C.MAX_EVENTS_PER_ACTOR or 512
    local maxScan = (C and C.MAX_LEDGER_EVENTS or 4096) + (C and C.MAX_ARCHIVED_EVENTS or 4096)
    local limit = #archive
    if limit > maxScan then limit = maxScan end
    local queued = 0
    for i = 1, limit do
        if queued >= cap then break end
        local event = archive[i]
        if type(event) == "table" and type(event.id) == "string"
            and C.ValidOrder(event.order) and S.RemoteEventIdOk(event.id, who) then
            self:_QueueUnsentConsumablesEvent(profile, event.id)
            queued = queued + 1
        end
    end
end

function Sync:_QueueUnsequencedConsumablesEvents(profile)
    local events = profile and profile._consumableEvents
    if type(events) ~= "table" or profile._consumablesResendCursor == nil then return end
    local S = Rules()
    local who = self._SelfId and self:_SelfId() or nil
    if not S or type(who) ~= "string" or who == "" then return end
    local index = profile._consumablesResendCursor
    if type(index) ~= "number" or index < 1 then index = 1 end
    local queued = 0
    local scanned = 0
    while index <= #events and queued < MAX_EVENT_FLUSH and scanned < MAX_EVENT_SCAN do
        local event = events[index]
        if type(event) == "table" and type(event.id) == "string" and tonumber(event.order) == nil
            and S.RemoteEventIdOk(event.id, who) then
            self:_QueueUnsentConsumablesEvent(profile, event.id)
            queued = queued + 1
        end
        index = index + 1
        scanned = scanned + 1
    end
    if index > #events then
        profile._consumablesResendCursor = nil
    else
        profile._consumablesResendCursor = index
    end
end

function Sync:_FlushUnsentConsumablesEvents(profile)
    if self._consumablesFlushing then return end
    if self.IsSafeModeEnabled and self:IsSafeModeEnabled() then return end
    local queue = profile and profile._consumablesUnsent
    if type(queue) ~= "table" or #queue == 0 then return end
    local C = Consumables()
    local cap = C and C.MAX_LEDGER_EVENTS and C.MAX_ARCHIVED_EVENTS and (C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS) or 8192
    if #queue > cap then
        self:_PruneUnsentConsumablesEvents(profile)
        queue = profile._consumablesUnsent
        if type(queue) ~= "table" or #queue == 0 then
            return
        end
    end
    self._consumablesFlushing = true
    local sent = 0
    local ids = C and C.EventIndex and C.EventIndex(profile)
    local limit = math.min(MAX_EVENT_FLUSH, #queue)
    while sent < limit and #queue > 0 do
        local eventId = queue[1]
        local stored = ids and ids[eventId]
        if type(stored) ~= "table" then
            table.remove(queue, 1)
        else
            local delivered = self:BroadcastConsumablesEvent(profile, stored)
            if delivered == false then
                break
            end
            table.remove(queue, 1)
            if not (self.state and self.state.isCoordinator) then
                -- Accepted into BULK is not accepted by the coordinator. Rotate
                -- pending IDs so later batches progress without losing protection.
                queue[#queue + 1] = eventId
            end
        end
        sent = sent + 1
    end
    self._consumablesFlushing = false
end

local function EventIdSet(profile)
    local seen = {}
    local function mark(list)
        if type(list) ~= "table" then return end
        for i = 1, #list do
            local id = list[i] and list[i].id
            if type(id) == "string" then
                seen[id] = true
            end
        end
    end
    if type(profile) ~= "table" then return seen end
    mark(profile._consumableEventArchive)
    mark(profile._consumableEvents)
    return seen
end

function Sync:_BroadcastNewConsumablesEvents(profile, seenBefore, writer)
    if type(profile) ~= "table" then return end
    seenBefore = seenBefore or {}
    local S = Rules()
    local C = Consumables()
    local function sendNew(list)
        if type(list) ~= "table" then return end
        for i = 1, #list do
            local event = list[i]
            if type(event) == "table" and type(event.id) == "string" and not seenBefore[event.id] then
                if type(writer) == "string" and type(event.writer) ~= "string"
                    and S and S.RemoteEventIdOk and S.RemoteEventIdOk(event.id, writer) then
                    if C and C.NoteStoredWriter then
                        C.NoteStoredWriter(profile, event, writer)
                    else
                        event.writer = writer
                    end
                end
                self:BroadcastConsumablesEvent(profile, event)
            end
        end
    end
    sendNew(profile._consumableEventArchive)
    sendNew(profile._consumableEvents)
end

function Sync:CommitConsumablesOp(profile, op, actor, opts)
    local C = Consumables()
    if not C then
        return false, "Raid Consumables is unavailable."
    end
    opts = opts or {}
    local inSession = SessionFor(profile)
    if inSession and self.IsSafeModeEnabled and self:IsSafeModeEnabled() then
        return false, "Raid supplies changes wait until safe mode ends."
    end
    if not inSession or (self.state and self.state.isCoordinator) then
        local seen = EventIdSet(profile)
        local ok, err = C.ApplyOp(profile, op, actor, opts)
        if ok and inSession and self.state.isCoordinator then
            self:_BroadcastNewConsumablesEvents(profile, seen)
            self:BroadcastConsumablesConfig(profile)
        end
        return ok, err
    end
    if not SF.LootHelperComm or not self.MSG then
        return false, "Sync is unavailable."
    end
    local coordinator = self.state.coordinator
    if type(coordinator) ~= "string" or coordinator == "" then
        return false, "No session coordinator."
    end
    if not self:_ConsumablesCoordinatorAccepts() then
        return false, "The session coordinator does not support raid supplies yet."
    end
    -- Preview as Non-Admin must block local user-triggered config sends. The
    -- coordinator authorizes the canonical sender, so the follower has to enforce
    -- the effective-admin overlay before whispering the op.
    if opts.asAdmin == false then
        return false, "Raid Consumables settings are in Preview as Non-Admin mode."
    end
    local sent = SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_OP, {
        sessionId = self.state.sessionId,
        profileId = ProfileIdOf(profile),
        actor = actor,
        op = op,
    }, "WHISPER", coordinator, "BULK")
    if sent == false then
        return false, "Raid supplies sync is busy. Try again."
    end
    return true, "pending"
end

function Sync:HandleConsumablesOp(sender, payload)
    if not SessionPayloadOk(payload, sender) then return end
    if not (self.state and self.state.isCoordinator) then return end
    local C = Consumables()
    local S = Rules()
    if not C or not S or type(payload.op) ~= "table" then return end
    if not (self._SamePlayer and self:_SamePlayer(sender, payload.actor)) then
        Debug("Warn", "Rejected consumables op from %s for actor %s", tostring(sender), tostring(payload.actor))
        return
    end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(payload.profileId) or nil
    if not profile then return end
    if not S.AuthorizeOp(profile, payload.op, sender) then
        Debug("Warn", "Unauthorized consumables op %s from %s", tostring(payload.op.name), tostring(sender))
        return
    end
    self._consumablesOpWindow = self._consumablesOpWindow or {}
    local now = self._Now and self:_Now() or 0
    if not S.AllowRemoteOp(self._consumablesOpWindow, sender, now) then
        Debug("Verbose", "Throttled consumables op %s from %s", tostring(payload.op.name), tostring(sender))
        return
    end
    local seen = EventIdSet(profile)
    local ok, err = C.ApplyOp(profile, payload.op, sender, {
        asAdmin = C.IsCanonicalAdmin(profile, sender),
    })
    if not ok then
        Debug("Warn", "Consumables op failed: %s", tostring(err))
        return
    end
    self:_BroadcastNewConsumablesEvents(profile, seen, sender)
    self:BroadcastConsumablesConfig(profile)
end

function Sync:BroadcastConsumablesConfig(profile)
    local C = Consumables()
    if not C or not (self.state and self.state.active and self.state.isCoordinator) then return end
    if not SF.LootHelperComm or not self.MSG then return end
    if not SessionFor(profile) then return end
    local dist = self._EnforceGroupedSessionActive and self:_EnforceGroupedSessionActive("BroadcastConsumablesConfig")
    if not dist then return end
    local snap = C.ExportSnapshot(profile, { omitEvents = true })
    snap.profileId = ProfileIdOf(profile)
    snap.sessionId = self.state.sessionId
    SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_CONFIG, snap, dist, nil, "BULK")
end

function Sync:HandleConsumablesConfig(sender, payload)
    if not SessionPayloadOk(payload, sender) then return end
    local C = Consumables()
    local S = Rules()
    if not C or not S then return end
    if not S.RemoteConfigSenderOk(self.state and self.state.coordinator, sender) then
        Debug("Verbose", "Ignored consumables config from non-coordinator %s", tostring(sender))
        return
    end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(payload.profileId) or nil
    if not profile then
        -- Profile bootstrap is owned by SendJoinStatus and the cooldown-gated heartbeat.
        return
    end
    local ok, status = S.ApplyRemoteConfig(profile, payload, sender, {
        coordinatorAuthoritative = true,
        coordEpoch = self.state and self.state.coordEpoch,
    })
    if not ok then
        Debug("Verbose", "Ignored consumables config from %s (%s)", tostring(sender), tostring(status))
    end
end

function Sync:BroadcastConsumablesEvent(profile, event)
    if type(event) ~= "table" or type(event.id) ~= "string" then return false end
    if not (self.state and self.state.active and SF.LootHelperComm and self.MSG) then
        self:_QueueUnsentConsumablesEvent(profile, event.id)
        return false
    end
    if not SessionFor(profile) then return false end
    if self.IsSafeModeEnabled and self:IsSafeModeEnabled() then
        self:_QueueUnsentConsumablesEvent(profile, event.id)
        return false
    end
    local payload = {
        sessionId = self.state.sessionId,
        profileId = ProfileIdOf(profile),
        event = event,
    }
    local sent
    if not (self.state and self.state.isCoordinator) then
        local coordinator = self.state and self.state.coordinator
        if type(coordinator) ~= "string" or coordinator == "" then
            self:_QueueUnsentConsumablesEvent(profile, event.id)
            return false
        end
        if not self:_ConsumablesCoordinatorAccepts() then
            self:_QueueUnsentConsumablesEvent(profile, event.id)
            return false
        end
        -- Protect even a successful initial send until a stamped relay or
        -- authoritative snapshot confirms coordinator acceptance.
        self:_QueueUnsentConsumablesEvent(profile, event.id)
        sent = SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_EVENT, payload, "WHISPER", coordinator, "NORMAL")
    else
        local C = Consumables()
        local S = Rules()
        if C and C.StampOrder then
            if not C.StampOrder(profile, event) then return false end
        end
        if S and type(event.writer) ~= "string" then
            local who = self._SelfId and self:_SelfId() or nil
            if type(who) == "string" and S.RemoteEventIdOk(event.id, who) then
                if C and C.NoteStoredWriter then
                    C.NoteStoredWriter(profile, event, who)
                else
                    event.writer = who
                end
            end
        end
        local dist = self._EnforceGroupedSessionActive and self:_EnforceGroupedSessionActive("BroadcastConsumablesEvent")
        if not dist then
            self:_QueueUnsentConsumablesEvent(profile, event.id)
            return false
        end
        sent = SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_EVENT, payload, dist, nil, "NORMAL")
    end
    if sent == false then
        self:_QueueUnsentConsumablesEvent(profile, event.id)
        return false
    end
    return true
end

function Sync:CommitConsumablesEvents(profile, token, events)
    local C = Consumables()
    if not C then return false, "Raid Consumables is unavailable." end
    local seen = EventIdSet(profile)
    local writer = self._SelfId and self:_SelfId() or nil
    local ok, err = C.CommitEvents(profile, token, events, { writer = writer })
    if not ok then return false, err end
    if SessionFor(profile) then
        self:_BroadcastNewConsumablesEvents(profile, seen)
    else
        local function queueNew(list)
            if type(list) ~= "table" then return end
            for i = 1, #list do
                local event = list[i]
                if type(event) == "table" and type(event.id) == "string" and not seen[event.id] then
                    self:_QueueUnsentConsumablesEvent(profile, event.id)
                end
            end
        end
        queueNew(profile._consumableEventArchive)
        queueNew(profile._consumableEvents)
    end
    return true
end

function Sync:HandleConsumablesEvent(sender, payload)
    if not SessionPayloadOk(payload, sender) then return end
    local C = Consumables()
    local S = Rules()
    if not S or not C or type(payload.event) ~= "table" then return end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(payload.profileId) or nil
    if not profile then return end
    local event = payload.event
    local coordinator = self.state and self.state.coordinator
    local isCoordinator = self.state and self.state.isCoordinator == true
    local fromCoordinator = false
    if type(coordinator) == "string" and type(self._SamePlayer) == "function" then
        fromCoordinator = self:_SamePlayer(sender, coordinator) and true or false
    end
    -- Relays from an unproven catch-up coordinator skip the member rate limit
    -- and trust attacker-chosen writer fields. Quarantine until that sender is
    -- canonical or their catch-up grant is stored locally.
    if fromCoordinator and self._UnprovenCatchUpKeepalive and self:_UnprovenCatchUpKeepalive(sender) then
        Debug("Verbose", "Ignored consumables event from unproven coordinator %s", tostring(sender))
        return
    end
    -- Explicit admin revocation clears catch-up, so the unproven guard above is
    -- false. Still reject relays from a revoked coordinator route.
    if fromCoordinator and self._RouteWasRevoked and self:_RouteWasRevoked(sender) then
        Debug("Verbose", "Ignored consumables event from revoked coordinator %s", tostring(sender))
        return
    end
    local accept, relay = S.RemoteEventAdmission(isCoordinator, fromCoordinator, event)
    if not accept then return end
    if not relay and S.AllowRemoteOp then
        self._consumablesEventLimits = self._consumablesEventLimits or {}
        local now = (C and C.Now and C.Now()) or 0
        if not S.AllowRemoteOp(self._consumablesEventLimits, sender, now) then
            return
        end
    end
    local ids = C.EventIndex and C.EventIndex(profile)
    local stored = ids and event.id and ids[event.id]
    local hadOrder = type(stored) == "table" and C.ValidOrder(stored.order) ~= nil
    local ok, status = S.ApplyRemoteEvent(profile, event, sender, relay and { coordinatorRelay = true } or nil)
    if ok and relay then
        local queue = profile._consumablesUnsent
        if type(queue) == "table" then
            for i = #queue, 1, -1 do
                if queue[i] == event.id then table.remove(queue, i) end
            end
        end
    end
    if isCoordinator and ok and not hadOrder and C.StampOrder then
        if not C.StampOrder(profile, event) then return end
        if self._RefreshConsumablesHistoryGate then
            self:_RefreshConsumablesHistoryGate(profile)
        end
        self:BroadcastConsumablesEvent(profile, event)
        return
    end
    if isCoordinator and ok and hadOrder and status == "duplicate" and not fromCoordinator
        and S.RemoteEventIdOk and S.RemoteEventIdOk(event.id, sender) then
        local stamped = type(stored) == "table" and stored or nil
        if type(stamped) == "table" and C.ValidOrder(stamped.order) ~= nil then
            if self._RefreshConsumablesHistoryGate then
                self:_RefreshConsumablesHistoryGate(profile)
            end
            self:BroadcastConsumablesEvent(profile, stamped)
        end
        return
    end
    if isCoordinator and ok and self._RefreshConsumablesHistoryGate then
        self:_RefreshConsumablesHistoryGate(profile)
    end
    if not ok and status ~= "duplicate" then
        Debug("Verbose", "Ignored consumables event from %s (%s)", tostring(sender), tostring(status))
    end
end

-- ---------------------------------------------------------------------------
-- Guild Bank observation reports, admin review, and decisions (Issue #366 PR2)
-- ---------------------------------------------------------------------------

local function ObservationDB()
    local db = SF.lootHelperDB
    if type(db) ~= "table" then
        db = {}
        SF.lootHelperDB = db
    end
    return db
end

local function ObservationScopeFor(profile)
    local C = Consumables()
    local O = SF.ConsumablesObservation
    if not C or not O or type(profile) ~= "table" then return nil, nil, nil end
    local cfg = C.Ensure(profile)
    if type(cfg.guild) ~= "table" or type(cfg.guild.guid) ~= "string" then return nil, nil, nil end
    local tab = tonumber(cfg.bankTab)
    if not tab then return nil, nil, nil end
    local profileId = ProfileIdOf(profile)
    local store = O.EnsureProfileStore(ObservationDB(), profileId)
    if not store then return nil, nil, nil end
    local scope = O.EnsureScope(store, cfg.guild.guid, tab)
    return store, scope, { guildGuid = cfg.guild.guid, bankTab = tab, profileId = profileId }
end

function Sync:_FlushPendingConsumableObservations(profile)
    if not SessionFor(profile) then return end
    if not (self.state and self.state.active and SF.LootHelperComm and self.MSG) then return end
    if self.IsSafeModeEnabled and self:IsSafeModeEnabled() then return end
    local V = SF.ConsumablesVerification
    local O = SF.ConsumablesObservation
    if not V or not O then return end
    local store, scope, meta = ObservationScopeFor(profile)
    if not store or not meta then return end
    local batch, hasMore, remaining = V.CollectUnresolvedForSubmit(store, meta.guildGuid, meta.bankTab, {
        profileId = meta.profileId,
    })
    if #batch == 0 then
        return
    end
    local payload = {
        sessionId = self.state.sessionId,
        profileId = meta.profileId,
        observations = batch,
    }
    local accepted = false
    if self.state.isCoordinator then
        accepted = self:HandleConsumablesObsReport(self._SelfId and self:_SelfId() or "", payload) == true
    else
        local coordinator = self.state.coordinator
        if type(coordinator) ~= "string" or coordinator == "" then return end
        if not self:_ConsumablesCoordinatorAccepts() then return end
        accepted = SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_OBS_REPORT, payload, "WHISPER", coordinator, "NORMAL") ~= false
    end
    -- Do not retire submitted keys after a rejected/dropped page (limiter/backpressure).
    if not accepted then
        Debug("Verbose", "consumable observation page not accepted; submitted keys retained")
        return
    end
    if V.MarkObservationsSubmitted then
        V.MarkObservationsSubmitted(store, batch, meta.profileId)
    end
    Debug("Info", "submitted %s unresolved consumable observations (remaining=%s)",
        tostring(#batch), tostring(remaining - #batch))
    -- Continue draining later batches without flooding the coordinator.
    if hasMore then
        if not self._consumablesObsFlushScheduled then
            self._consumablesObsFlushScheduled = true
            local function continueFlush()
                self._consumablesObsFlushScheduled = false
                if self._FlushPendingConsumableObservations then
                    self:_FlushPendingConsumableObservations(profile)
                end
            end
            if C_Timer and C_Timer.After then
                C_Timer.After(0.35, continueFlush)
            else
                continueFlush()
            end
        end
    end
end

local function BroadcastObsDecision(self, profileId, decision)
    if not (self.state and self.state.active and SF.LootHelperComm and self.MSG) then return end
    local notice = {
        sessionId = self.state.sessionId,
        profileId = profileId,
        decision = decision,
    }
    local dist = self._EnforceGroupedSessionActive and self:_EnforceGroupedSessionActive("ConsumablesObsDecision")
    if dist then
        SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_OBS_DECISION, notice, dist, nil, "NORMAL")
    end
end

function Sync:HandleConsumablesObsReport(sender, payload)
    if not SessionPayloadOk(payload, sender) then return false end
    if not (self.state and self.state.isCoordinator) then return false end
    local C = Consumables()
    local V = SF.ConsumablesVerification
    if not C or not V or type(payload.observations) ~= "table" then return false end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(payload.profileId) or nil
    if not profile then return false end
    self._consumablesObsLimits = self._consumablesObsLimits or {}
    local now = (C.Now and C.Now()) or 0
    local S = Rules()
    local selfId = self._SelfId and self:_SelfId() or ""
    local isSelf = type(selfId) == "string" and selfId ~= ""
        and self._SamePlayer and self:_SamePlayer(sender, selfId)
    -- One remote-op credit per report message. Charging per observation made a
    -- full MAX_OBS_BATCH page exceed the window and drop valid pages.
    if not isSelf and S and S.AllowRemoteOp then
        if not S.AllowRemoteOp(self._consumablesObsLimits, sender, now) then
            return false
        end
    end
    local store, scope, meta = ObservationScopeFor(profile)
    if not meta then return false end
    local isAdmin = C.IsCanonicalAdmin(profile, sender)
    local historyReady = true
    if self._ConsumablesHistoryReady then
        historyReady = self:_ConsumablesHistoryReady(profile) ~= false
    end
    local stats = V.IngestReport(profile, meta.profileId, sender, payload.observations, {
        isAdmin = isAdmin,
        scope = scope,
        obsStore = store,
        guildGuid = meta.guildGuid,
        bankTab = meta.bankTab,
        eligibility = C.EligibilitySnapshot and C.EligibilitySnapshot(profile) or nil,
        durableRejections = C.DurableRejections and C.DurableRejections(profile) or nil,
        historyComplete = historyReady,
        isRequested = function(itemId)
            return C.IsRequested(profile, itemId)
        end,
        recordPendingWitness = function(evidence, submittedBy, witnessMap)
            if C.UpsertPendingWitness then
                C.UpsertPendingWitness(profile, evidence, submittedBy, witnessMap)
            end
        end,
        clearPendingWitness = function(evidence)
            if C.ClearPendingWitness then
                C.ClearPendingWitness(profile, evidence)
            end
        end,
    })
    Debug("Info", "obs report from %s accepted=%s verified=%s skipped=%s historyReady=%s",
        tostring(sender), tostring(stats.accepted), tostring(stats.verified),
        tostring(stats.skipped), tostring(historyReady))
    if ((stats.witnessChanged or 0) > 0 or (stats.verified or 0) > 0)
        and self.BroadcastConsumablesConfig then
        self:BroadcastConsumablesConfig(profile)
    end
    local verified = V.ListVerifiedClusters(meta.profileId)
    for i = 1, #verified do
        local cluster = verified[i]
        if cluster and not cluster._committed then
            local writer = cluster.decidedBy or (self._SelfId and self:_SelfId()) or sender
            local ok, commitStatus = V.CommitVerifiedCluster(profile, cluster, writer)
            if ok then
                cluster._committed = true
                if scope and cluster.txnId then
                    scope.verifiedTxnIds = scope.verifiedTxnIds or {}
                    scope.verifiedTxnIds[cluster.txnId] = true
                end
                local decision = {
                    action = "verified",
                    txnId = cluster.txnId,
                    verification = cluster.verification,
                    evidence = cluster.evidence and V.SerializeObservation(cluster.evidence) or cluster.evidence,
                    decidedBy = writer,
                    clusterId = cluster.clusterId,
                    profileId = meta.profileId,
                }
                if store and meta then
                    V.ApplyRemoteDecisionToLocal(store, meta.guildGuid, meta.bankTab, decision)
                end
                -- Followers must learn automatic verification or they keep re-reporting.
                BroadcastObsDecision(self, meta.profileId, decision)
            elseif commitStatus ~= "duplicate" then
                Debug("Warn", "verified cluster commit failed txn=%s status=%s",
                    tostring(cluster.txnId), tostring(commitStatus))
            end
        end
    end
    self:_FlushUnsentConsumablesEvents(profile)
    return true
end

function Sync:RequestConsumablesReviewSummary(profile)
    if not SessionFor(profile) then return false end
    local C = Consumables()
    if not C then return false end
    local who = self._SelfId and self:_SelfId() or nil
    if not C.IsCanonicalAdmin(profile, who) then return false end
    local payload = {
        sessionId = self.state.sessionId,
        profileId = ProfileIdOf(profile),
    }
    if self.state.isCoordinator then
        self:HandleConsumablesReviewReq(who, payload)
        return true
    end
    local coordinator = self.state.coordinator
    if type(coordinator) ~= "string" or coordinator == "" then return false end
    return SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_REVIEW_REQ, payload, "WHISPER", coordinator, "NORMAL") ~= false
end

function Sync:HandleConsumablesReviewReq(sender, payload)
    if not SessionPayloadOk(payload, sender) then return end
    if not (self.state and self.state.isCoordinator) then return end
    local C = Consumables()
    local V = SF.ConsumablesVerification
    if not C or not V then return end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(payload.profileId) or nil
    if not profile or not C.IsCanonicalAdmin(profile, sender) then return end
    local summary = V.ReviewSummary(payload.profileId, { profile = profile })
    local response = {
        sessionId = self.state.sessionId,
        profileId = payload.profileId,
        pending = summary,
    }
    SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_REVIEW_SUMMARY, response, "WHISPER", sender, "NORMAL")
    Debug("Info", "sent review summary (%s) to %s", tostring(#summary), tostring(sender))
end

function Sync:HandleConsumablesReviewSummary(sender, payload)
    if not SessionPayloadOk(payload, sender) then return end
    local coordinator = self.state and self.state.coordinator
    if not (type(coordinator) == "string" and self._SamePlayer and self:_SamePlayer(sender, coordinator)) then
        return
    end
    if self._UnprovenCatchUpKeepalive and self:_UnprovenCatchUpKeepalive(sender) then
        Debug("Verbose", "Ignored review summary from unproven coordinator %s", tostring(sender))
        return
    end
    if self._RouteWasRevoked and self:_RouteWasRevoked(sender) then
        Debug("Verbose", "Ignored review summary from revoked coordinator %s", tostring(sender))
        return
    end
    self._consumablesReviewSummary = type(payload.pending) == "table" and payload.pending or {}
    self._consumablesReviewSummaryAt = (Consumables() and Consumables().Now and Consumables().Now()) or time()
    local C = Consumables()
    if C and C.NotifyUI then
        C.NotifyUI()
    end
    Debug("Info", "received review summary rows=%s", tostring(#self._consumablesReviewSummary))
end

function Sync:SubmitConsumablesObsDecision(profile, decision)
    if not SessionFor(profile) or type(decision) ~= "table" then return false end
    local C = Consumables()
    if not C then return false end
    local who = self._SelfId and self:_SelfId() or nil
    if not C.IsCanonicalAdmin(profile, who) then return false end
    local payload = {
        sessionId = self.state.sessionId,
        profileId = ProfileIdOf(profile),
        decision = decision,
    }
    if self.state.isCoordinator then
        self:HandleConsumablesObsDecision(who, payload)
        return true
    end
    local coordinator = self.state.coordinator
    if type(coordinator) ~= "string" or coordinator == "" then return false end
    return SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_OBS_DECISION, payload, "WHISPER", coordinator, "NORMAL") ~= false
end

function Sync:HandleConsumablesObsDecision(sender, payload)
    if not SessionPayloadOk(payload, sender) then return end
    local C = Consumables()
    local V = SF.ConsumablesVerification
    if not C or not V or type(payload.decision) ~= "table" then return end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(payload.profileId) or nil
    if not profile then return end

    -- Followers only apply coordinator-distributed decision notices.
    if not (self.state and self.state.isCoordinator) then
        local coordinator = self.state and self.state.coordinator
        if not (type(coordinator) == "string" and self._SamePlayer and self:_SamePlayer(sender, coordinator)) then
            return
        end
        if self._UnprovenCatchUpKeepalive and self:_UnprovenCatchUpKeepalive(sender) then
            Debug("Verbose", "Ignored obs decision from unproven coordinator %s", tostring(sender))
            return
        end
        if self._RouteWasRevoked and self:_RouteWasRevoked(sender) then
            Debug("Verbose", "Ignored obs decision from revoked coordinator %s", tostring(sender))
            return
        end
        local store, _, meta = ObservationScopeFor(profile)
        local decision = payload.decision
        if store and meta then
            V.ApplyRemoteDecisionToLocal(store, meta.guildGuid, meta.bankTab, decision)
        end
        -- Keep durable rejection state aligned with coordinator notices without
        -- bumping rejectionSeq (config snapshots remain the authority clock).
        local evidence = decision and (decision.evidence or decision) or nil
        if evidence then
            if decision.action == "reject" and C.RecordDurableRejection then
                C.RecordDurableRejection(profile, evidence, decision.decidedBy, decision.reason, {
                    bumpSeq = false,
                })
            elseif decision.action == "correct" and C.ClearDurableRejection then
                C.ClearDurableRejection(profile, evidence, { bumpSeq = false })
            end
        end
        if C.NotifyUI then C.NotifyUI() end
        return
    end

    -- Coordinator: authenticated admin decisions only (never trust client isAdmin).
    if not C.IsCanonicalAdmin(profile, sender) then return end
    local store, scope, meta = ObservationScopeFor(profile)
    local ok, status, cluster = V.ApplyDecision(profile, payload.profileId, sender, payload.decision, {
        isAdmin = true,
        scope = scope,
        obsStore = store,
        recordDurableRejection = function(evidence, decidedBy, reason)
            if C.RecordDurableRejection then
                C.RecordDurableRejection(profile, evidence, decidedBy, reason)
            end
        end,
        clearDurableRejection = function(evidence)
            if C.ClearDurableRejection then
                C.ClearDurableRejection(profile, evidence)
            end
        end,
        clearPendingWitness = function(evidence)
            if C.ClearPendingWitness then
                C.ClearPendingWitness(profile, evidence)
            end
        end,
    })
    if not ok then
        Debug("Verbose", "ignored obs decision from %s (%s)", tostring(sender), tostring(status))
        return
    end
    local decisionNotice = {
        action = payload.decision.action,
        clusterId = cluster and cluster.clusterId or payload.decision.clusterId,
        txnId = cluster and cluster.txnId or nil,
        verification = cluster and cluster.verification or nil,
        decidedBy = sender,
        evidence = cluster and V.SerializeObservation(cluster.evidence) or payload.decision.evidence,
        reason = payload.decision.reason,
        profileId = payload.profileId,
    }
    if status == "verified" and cluster then
        local commitOk, commitStatus = V.CommitVerifiedCluster(profile, cluster, sender)
        if not commitOk and commitStatus ~= "duplicate" then
            -- Keep the row reviewable; do not announce a credit that never landed.
            cluster.status = "pending"
            cluster.verification = nil
            cluster._committed = false
            Debug("Warn", "approval commit failed; not broadcasting txn=%s status=%s",
                tostring(cluster.txnId), tostring(commitStatus))
            return
        end
        cluster._committed = true
        decisionNotice.action = payload.decision.action == "correct" and "correct" or "approve"
        decisionNotice.txnId = cluster.txnId
        decisionNotice.verification = cluster.verification
        self:_FlushUnsentConsumablesEvents(profile)
    elseif status == "rejected" then
        decisionNotice.action = "reject"
    end
    BroadcastObsDecision(self, payload.profileId, decisionNotice)
    if store and meta then
        V.ApplyRemoteDecisionToLocal(store, meta.guildGuid, meta.bankTab, decisionNotice)
    end
    -- Push rejectionSeq-backed durable state so followers/promotions converge.
    if (status == "rejected" or payload.decision.action == "correct")
        and self.BroadcastConsumablesConfig then
        self:BroadcastConsumablesConfig(profile)
    end
    if C.NotifyUI then C.NotifyUI() end
end
