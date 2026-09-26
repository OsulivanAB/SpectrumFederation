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

local MAX_CAPABLE_PEERS = 40
local MAX_EVENT_FLUSH = 8
local MAX_EVENT_SCAN = 64

function Sync:_ClearConsumablesCapability()
    local S = Rules()
    if S and S.ClearCapabilityFlags then
        S.ClearCapabilityFlags(self.state and self.state.peers)
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
    if payload.consumablesCapable == true and type(sender) == "string" and sender ~= "" then
        self:TouchPeer(sender, { consumablesCapable = true })
    end
    local peers = payload.consumablesCapablePeers
    if type(peers) ~= "table" then return end
    local limit = #peers
    if limit > MAX_CAPABLE_PEERS then limit = MAX_CAPABLE_PEERS end
    for i = 1, limit do
        local name = peers[i]
        if type(name) == "string" and name ~= "" then
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
    local desc = C.Descriptor(profile)
    payload.consumablesGeneration = desc.generation
    payload.consumablesConfigSeq = desc.configSeq
    payload.consumablesEventCount = desc.eventCount
    payload.consumablesEventFingerprint = desc.eventFingerprint
    self:_FlushUnsentConsumablesEvents(profile)
end

function Sync:_ConsiderConsumablesCatchUp(payload)
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
        if self.RequestProfileSnapshot then
            self:RequestProfileSnapshot("consumables-missing-profile")
        end
        return
    end
    local remote = {
        generation = payload.consumablesGeneration,
        configSeq = payload.consumablesConfigSeq,
        eventCount = payload.consumablesEventCount,
        eventFingerprint = payload.consumablesEventFingerprint,
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
    self:_FlushUnsentConsumablesEvents(profile)
    if not S.NeedsCatchUp(localDesc, remote) then
        return
    end
    local key = table.concat({
        tostring(payload.sessionId),
        tostring(payload.consumablesGeneration),
        tostring(payload.consumablesConfigSeq),
        tostring(payload.consumablesEventCount),
        tostring(payload.consumablesEventFingerprint),
    }, ":")
    if self._consumablesCatchUpKey == key then
        return
    end
    self._consumablesCatchUpKey = key
    if self.RequestProfileSnapshot then
        self:RequestProfileSnapshot("consumables-catchup")
    end
end

local function SessionPayloadOk(payload, sender)
    local S = Rules()
    if not S or not S.SessionEnvelopeOk(Sync.state, payload) then return false end
    if type(sender) ~= "string" or sender == "" then return false end
    if not (Sync.IsRequesterInGroup and Sync:IsRequesterInGroup(sender)) then return false end
    return true
end

function Sync:_QueueUnsentConsumablesEvent(profile, eventId)
    if type(profile) ~= "table" or type(eventId) ~= "string" or eventId == "" then return end
    local queue = profile._consumablesUnsent
    if type(queue) ~= "table" then
        queue = {}
        profile._consumablesUnsent = queue
    end
    for i = 1, #queue do
        if queue[i] == eventId then return end
    end
    queue[#queue + 1] = eventId
end

function Sync:_QueueUnsequencedConsumablesEvents(profile)
    local events = profile and profile._consumableEvents
    if type(events) ~= "table" or profile._consumablesResendCursor == nil then return end
    local index = profile._consumablesResendCursor
    if type(index) ~= "number" or index < 1 then index = 1 end
    local queued = 0
    local scanned = 0
    while index <= #events and queued < MAX_EVENT_FLUSH and scanned < MAX_EVENT_SCAN do
        local event = events[index]
        if type(event) == "table" and type(event.id) == "string" and tonumber(event.order) == nil then
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
    self._consumablesFlushing = true
    local sent = 0
    while sent < MAX_EVENT_FLUSH and #queue > 0 do
        local eventId = table.remove(queue, 1)
        sent = sent + 1
        local stored = profile._consumableEventIds and profile._consumableEventIds[eventId]
        if type(stored) == "table" then
            self:BroadcastConsumablesEvent(profile, stored)
        end
    end
    self._consumablesFlushing = false
end

local function EventIdSet(profile)
    local seen = {}
    local events = profile and profile._consumableEvents
    if type(events) ~= "table" then return seen end
    for i = 1, #events do
        local id = events[i] and events[i].id
        if type(id) == "string" then
            seen[id] = true
        end
    end
    return seen
end

function Sync:_BroadcastNewConsumablesEvents(profile, seenBefore)
    local events = profile and profile._consumableEvents
    if type(events) ~= "table" then return end
    seenBefore = seenBefore or {}
    for i = 1, #events do
        local event = events[i]
        if type(event) == "table" and type(event.id) == "string" and not seenBefore[event.id] then
            self:BroadcastConsumablesEvent(profile, event)
        end
    end
end

function Sync:CommitConsumablesOp(profile, op, actor, opts)
    local C = Consumables()
    if not C then
        return false, "Raid Consumables is unavailable."
    end
    opts = opts or {}
    local inSession = SessionFor(profile)
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
    SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_OP, {
        sessionId = self.state.sessionId,
        profileId = ProfileIdOf(profile),
        actor = actor,
        op = op,
    }, "WHISPER", coordinator, "BULK")
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
    self:_BroadcastNewConsumablesEvents(profile, seen)
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
        if self.RequestProfileSnapshot then
            self:RequestProfileSnapshot("consumables-gap")
        end
        return
    end
    local ok, status = S.ApplyRemoteConfig(profile, payload, sender)
    if (not ok) and status == "gap" then
        if self.RequestProfileSnapshot then
            self:RequestProfileSnapshot("consumables-gap")
        end
        return
    end
    if not ok then
        Debug("Verbose", "Ignored consumables config from %s (%s)", tostring(sender), tostring(status))
    end
end

function Sync:BroadcastConsumablesEvent(profile, event)
    if type(event) ~= "table" or type(event.id) ~= "string" then return end
    if not (self.state and self.state.active and SF.LootHelperComm and self.MSG) then
        self:_QueueUnsentConsumablesEvent(profile, event.id)
        return
    end
    if not SessionFor(profile) then return end
    if self.IsSafeModeEnabled and self:IsSafeModeEnabled() then
        self:_QueueUnsentConsumablesEvent(profile, event.id)
        return
    end
    local payload = {
        sessionId = self.state.sessionId,
        profileId = ProfileIdOf(profile),
        event = event,
    }
    if not (self.state and self.state.isCoordinator) then
        local coordinator = self.state and self.state.coordinator
        if type(coordinator) ~= "string" or coordinator == "" then
            self:_QueueUnsentConsumablesEvent(profile, event.id)
            return
        end
        SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_EVENT, payload, "WHISPER", coordinator, "NORMAL")
        return
    end
    local C = Consumables()
    if C and C.StampOrder then
        C.StampOrder(profile, event)
    end
    local dist = self._EnforceGroupedSessionActive and self:_EnforceGroupedSessionActive("BroadcastConsumablesEvent")
    if not dist then
        self:_QueueUnsentConsumablesEvent(profile, event.id)
        return
    end
    SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_EVENT, payload, dist, nil, "NORMAL")
end

function Sync:CommitConsumablesEvents(profile, token, events)
    local C = Consumables()
    if not C then return false, "Raid Consumables is unavailable." end
    local seen = EventIdSet(profile)
    local ok, err = C.CommitEvents(profile, token, events)
    if not ok then return false, err end
    if SessionFor(profile) then
        self:_BroadcastNewConsumablesEvents(profile, seen)
    end
    return true
end

function Sync:PublishConsumablesResolve(profile, actor, holder, itemId, reason, opts)
    local C = Consumables()
    if not C then return false, "Raid Consumables is unavailable." end
    local seen = EventIdSet(profile)
    local ok, err = C.ResolveCustody(profile, actor, holder, itemId, reason, opts)
    if not ok then return false, err end
    if SessionFor(profile) then
        self:_BroadcastNewConsumablesEvents(profile, seen)
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
    local relay = tonumber(event.order) ~= nil and type(coordinator) == "string"
        and self:_SamePlayer(sender, coordinator)
    if not relay and S.AllowRemoteOp then
        self._consumablesEventLimits = self._consumablesEventLimits or {}
        local now = (C and C.Now and C.Now()) or 0
        if not S.AllowRemoteOp(self._consumablesEventLimits, sender, now) then
            return
        end
    end
    local needsOrder = self.state and self.state.isCoordinator and tonumber(event.order) == nil
    local stored = profile._consumableEventIds and event.id and profile._consumableEventIds[event.id]
    local hadOrder = type(stored) == "table" and tonumber(stored.order) ~= nil
    local ok, status = S.ApplyRemoteEvent(profile, event, sender, relay and { coordinatorRelay = true } or nil)
    if needsOrder and ok and not hadOrder and C.StampOrder then
        C.StampOrder(profile, event)
        self:BroadcastConsumablesEvent(profile, event)
        return
    end
    if not ok and status ~= "duplicate" then
        Debug("Verbose", "Ignored consumables event from %s (%s)", tostring(sender), tostring(status))
    end
end
