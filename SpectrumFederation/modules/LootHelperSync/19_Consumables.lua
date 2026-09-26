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
local MAX_FREEZE_FLUSH = 4
local pendingFreezes = setmetatable({}, { __mode = "k" })

function Sync:_ClearPendingTradeFreezes()
    local stale = {}
    for profile in pairs(pendingFreezes) do
        stale[#stale + 1] = profile
    end
    for i = 1, #stale do
        pendingFreezes[stale[i]] = nil
    end
end

local function PendingFreezeCap()
    local S = Rules()
    local cap = S and tonumber(S.MAX_TRADE_GRANTS) or 32
    if not cap or cap < 1 then cap = 32 end
    return cap
end

local function FreezeList(profile)
    local stored = pendingFreezes[profile]
    if type(stored) ~= "table" then
        stored = {}
        pendingFreezes[profile] = stored
        return stored
    end
    if type(stored.token) == "string" then
        stored = { stored }
        pendingFreezes[profile] = stored
    end
    return stored
end

local function PendingFreezeFor(profile, token)
    if type(token) ~= "string" then return nil end
    local stored = pendingFreezes[profile]
    if type(stored) ~= "table" then return nil end
    if type(stored.token) == "string" then
        if stored.token == token then return stored end
        return nil
    end
    for i = 1, #stored do
        local grant = stored[i]
        if type(grant) == "table" and grant.token == token then
            return grant
        end
    end
    return nil
end

local function RememberTradeFreeze(profile, grant, sent)
    if type(grant) ~= "table" or type(grant.token) ~= "string" then
        return sent ~= false
    end
    local list = FreezeList(profile)
    local index = nil
    for i = 1, #list do
        if type(list[i]) == "table" and list[i].token == grant.token then
            index = i
            break
        end
    end
    if sent == false then
        if index then
            list[index] = grant
        else
            list[#list + 1] = grant
            local cap = PendingFreezeCap()
            while #list > cap do
                table.remove(list, 1)
            end
        end
        return false
    end
    if index then
        table.remove(list, index)
    end
    if #list == 0 then
        pendingFreezes[profile] = nil
    end
    return true
end

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
    local desc = C.Descriptor(profile)
    payload.consumablesGeneration = desc.generation
    payload.consumablesConfigSeq = desc.configSeq
    payload.consumablesConfigFingerprint = desc.configFingerprint
    payload.consumablesEventCount = desc.eventCount
    payload.consumablesEventFingerprint = desc.eventFingerprint
    payload.consumablesArchiveCount = desc.archiveCount
    payload.consumablesArchiveFingerprint = desc.archiveFingerprint
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
        return
    end
    local remote = {
        generation = payload.consumablesGeneration,
        configSeq = payload.consumablesConfigSeq,
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
    self:_FlushUnsentConsumablesEvents(profile)
    local authority = table.concat({
        tostring(self.state.sessionId),
        tostring(self.state.coordEpoch),
        tostring(self.state.coordinator),
    }, ":")
    if S.CoordinatorConfigDiffers and S.CoordinatorConfigDiffers(localDesc, remote)
        and profile._consumablesConfigCatchUpSession ~= authority then
        local requested = false
        if self.RequestProfileSnapshot then
            requested = self:RequestProfileSnapshot("consumables-config", { coordinatorOnly = true }) and true or false
        end
        if requested then
            profile._consumablesConfigCatchUpSession = authority
            profile._consumablesAdoptNextSnapshot = self.state.sessionId
        end
    end
    if not S.NeedsCatchUp(localDesc, remote) then
        return
    end
    local fingerprintOnly = S.CatchUpKind and S.CatchUpKind(localDesc, remote) == "fingerprint"
    if fingerprintOnly then
        local now = self._Now and self:_Now() or 0
        if self._consumablesFpSnapshotSession ~= self.state.sessionId then
            self._consumablesFpSnapshotSession = self.state.sessionId
            self._consumablesFpSnapshotAt = nil
        end
        if self._consumablesFpSnapshotAt and now - self._consumablesFpSnapshotAt < 120 then
            return
        end
        self._consumablesFpSnapshotAt = now
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
        local opts = nil
        if profile._consumablesCatchUpWantCoordinator then
            opts = { coordinatorOnly = true }
        end
        requested = self:RequestProfileSnapshot("consumables-catchup", opts) and true or false
    end
    if not requested then
        return
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

function Sync:_QueueAuthoredOrderedConsumablesEvents(profile, remoteEventCount, fingerprintsDiffer)
    if self.state and self.state.isCoordinator then return end
    local events = profile and profile._consumableEvents
    if type(events) ~= "table" then return end
    if #events <= (tonumber(remoteEventCount) or 0) and not fingerprintsDiffer then return end
    local S = Rules()
    local who = self._SelfId and self:_SelfId() or nil
    if not S or type(who) ~= "string" or who == "" then return end
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
            and tonumber(event.order) and S.RemoteEventIdOk(event.id, who) then
            self:_QueueUnsentConsumablesEvent(profile, event.id)
            queued = queued + 1
        end
        index = index + 1
        scanned = scanned + 1
    end
    profile._consumablesOrderedResendCursor = index
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

local function FreezeWirePayload(profile, grant)
    local payload = {
        sessionId = Sync.state and Sync.state.sessionId or nil,
        profileId = ProfileIdOf(profile),
        token = grant.token,
        receiver = grant.receiver,
        generation = grant.generation,
    }
    if grant.kind == "withdraw" then
        payload.kind = "withdraw"
        payload.itemId = grant.itemId
        payload.epoch = grant.epoch
    else
        payload.donor = grant.donor
        payload.items = grant.items
    end
    return payload
end

function Sync:_FlushPendingTradeFreeze(profile)
    local list = pendingFreezes[profile]
    if type(list) ~= "table" then return end
    if type(list.token) == "string" then
        pendingFreezes[profile] = { list }
        list = pendingFreezes[profile]
    end
    if #list == 0 then return end
    if not (self.state and self.state.active) or not SessionFor(profile) then return end
    local flushed = 0
    while flushed < MAX_FREEZE_FLUSH and type(list[1]) == "table" do
        local grant = list[1]
        flushed = flushed + 1
        if self.state.isCoordinator then
            local S = Rules()
            local now = 0
            local C = Consumables()
            if C and C.Now then now = C.Now() end
            local registered = false
            if grant.kind == "withdraw" then
                registered = S and S.RegisterWithdrawGrant and S.RegisterWithdrawGrant(profile, grant, now)
            else
                registered = S and S.RegisterTradeGrant and S.RegisterTradeGrant(profile, grant, now)
            end
            if not registered then
                table.remove(list, 1)
            elseif self:BroadcastTradeFreeze(profile, grant) == false then
                break
            end
        else
            if not SF.LootHelperComm or not self.MSG then return end
            local coordinator = self.state.coordinator
            if type(coordinator) ~= "string" or coordinator == "" then return end
            local sent = SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_TRADE_FREEZE, FreezeWirePayload(profile, grant), "WHISPER", coordinator, "NORMAL")
            if sent == false then
                return
            end
            RememberTradeFreeze(profile, grant, true)
        end
    end
    if type(pendingFreezes[profile]) == "table" and #pendingFreezes[profile] == 0 then
        pendingFreezes[profile] = nil
    end
end

function Sync:_FlushUnsentConsumablesEvents(profile)
    if self._consumablesFlushing then return end
    if self.IsSafeModeEnabled and self:IsSafeModeEnabled() then return end
    self:_FlushPendingTradeFreeze(profile)
    local queue = profile and profile._consumablesUnsent
    if type(queue) ~= "table" or #queue == 0 then return end
    self._consumablesFlushing = true
    local sent = 0
    local C = Consumables()
    local ids = C and C.EventIndex and C.EventIndex(profile)
    while sent < MAX_EVENT_FLUSH and #queue > 0 do
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
    local function sendNew(list)
        if type(list) ~= "table" then return end
        for i = 1, #list do
            local event = list[i]
            if type(event) == "table" and type(event.id) == "string" and not seenBefore[event.id] then
                if type(writer) == "string" and type(event.writer) ~= "string"
                    and S and S.RemoteEventIdOk and S.RemoteEventIdOk(event.id, writer) then
                    event.writer = writer
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
        if self.RequestProfileSnapshot then
            self:RequestProfileSnapshot("consumables-gap")
        end
        return
    end
    local ok, status = S.ApplyRemoteConfig(profile, payload, sender, {
        coordinatorAuthoritative = true,
        coordEpoch = self.state and self.state.coordEpoch,
    })
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
    if type(event) ~= "table" or type(event.id) ~= "string" then return false end
    local waitToken = nil
    if type(event.tradeToken) == "string" then
        waitToken = event.tradeToken
    elseif type(event.withdrawToken) == "string" then
        waitToken = event.withdrawToken
    end
    if waitToken and PendingFreezeFor(profile, waitToken) then
        self:_FlushPendingTradeFreeze(profile)
        if PendingFreezeFor(profile, waitToken) then
            self:_QueueUnsentConsumablesEvent(profile, event.id)
            return false
        end
    end
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
        sent = SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_EVENT, payload, "WHISPER", coordinator, "NORMAL")
    else
        local C = Consumables()
        local S = Rules()
        if C and C.StampOrder then
            C.StampOrder(profile, event)
        end
        if S and type(event.writer) ~= "string" then
            local who = self._SelfId and self:_SelfId() or nil
            if type(who) == "string" and S.RemoteEventIdOk(event.id, who) then
                event.writer = who
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
    local isCoordinator = self.state and self.state.isCoordinator == true
    local fromCoordinator = false
    if type(coordinator) == "string" and type(self._SamePlayer) == "function" then
        fromCoordinator = self:_SamePlayer(sender, coordinator) and true or false
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
    local hadOrder = type(stored) == "table" and tonumber(stored.order) ~= nil
    local ok, status = S.ApplyRemoteEvent(profile, event, sender, relay and { coordinatorRelay = true } or nil)
    if isCoordinator and ok and not hadOrder and C.StampOrder then
        C.StampOrder(profile, event)
        self:BroadcastConsumablesEvent(profile, event)
        return
    end
    if isCoordinator and ok and hadOrder and status == "duplicate" and not fromCoordinator
        and S.RemoteEventIdOk and S.RemoteEventIdOk(event.id, sender) then
        local stamped = type(stored) == "table" and stored or nil
        if type(stamped) == "table" and tonumber(stamped.order) ~= nil then
            self:BroadcastConsumablesEvent(profile, stamped)
        end
        return
    end
    if not ok and status ~= "duplicate" then
        Debug("Verbose", "Ignored consumables event from %s (%s)", tostring(sender), tostring(status))
    end
end

function Sync:BroadcastTradeFreeze(profile, grant)
    if type(grant) ~= "table" or not (self.state and self.state.active and self.state.isCoordinator) then
        return false
    end
    if not SF.LootHelperComm or not self.MSG or not SessionFor(profile) then
        return RememberTradeFreeze(profile, grant, false)
    end
    local dist = self._EnforceGroupedSessionActive and self:_EnforceGroupedSessionActive("BroadcastTradeFreeze")
    if not dist then
        return RememberTradeFreeze(profile, grant, false)
    end
    local sent = SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_TRADE_FREEZE, FreezeWirePayload(profile, grant), dist, nil, "NORMAL")
    return RememberTradeFreeze(profile, grant, sent)
end

function Sync:PublishTradeFreeze(profile, frozen)
    local C = Consumables()
    local S = Rules()
    if not C or not S or type(frozen) ~= "table" then return false end
    local grant = S.TradeFreezePayload(frozen)
    if not grant then return false end
    local now = C.Now and C.Now() or 0
    if not (self.state and self.state.active) then
        return S.RegisterTradeGrant(profile, grant, now)
    end
    if not SessionFor(profile) then return false end
    if self.state.isCoordinator then
        if not S.RegisterTradeGrant(profile, grant, now) then return false end
        return self:BroadcastTradeFreeze(profile, grant)
    end
    if not SF.LootHelperComm or not self.MSG then
        return RememberTradeFreeze(profile, grant, false)
    end
    local coordinator = self.state.coordinator
    if type(coordinator) ~= "string" or coordinator == "" then
        return RememberTradeFreeze(profile, grant, false)
    end
    local sent = SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_TRADE_FREEZE, FreezeWirePayload(profile, grant), "WHISPER", coordinator, "NORMAL")
    return RememberTradeFreeze(profile, grant, sent)
end

function Sync:PublishWithdrawGrant(profile, grant)
    local C = Consumables()
    local S = Rules()
    if not C or not S or type(grant) ~= "table" then return false end
    grant.kind = "withdraw"
    local now = C.Now and C.Now() or 0
    if not (self.state and self.state.active) then
        return S.RegisterWithdrawGrant(profile, grant, now)
    end
    if not SessionFor(profile) then return false end
    if self.state.isCoordinator then
        if not S.RegisterWithdrawGrant(profile, grant, now) then return false end
        return self:BroadcastTradeFreeze(profile, grant)
    end
    if not SF.LootHelperComm or not self.MSG then
        return RememberTradeFreeze(profile, grant, false)
    end
    local coordinator = self.state.coordinator
    if type(coordinator) ~= "string" or coordinator == "" then
        return RememberTradeFreeze(profile, grant, false)
    end
    local sent = SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_TRADE_FREEZE, FreezeWirePayload(profile, grant), "WHISPER", coordinator, "NORMAL")
    return RememberTradeFreeze(profile, grant, sent)
end

function Sync:HandleConsumablesTradeFreeze(sender, payload)
    if not SessionPayloadOk(payload, sender) then return end
    local C = Consumables()
    local S = Rules()
    if not C or not S or type(payload.token) ~= "string" then return end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(payload.profileId) or nil
    if not profile then return end
    local coordinator = self.state and self.state.coordinator
    local isCoordinator = self.state and self.state.isCoordinator == true
    local fromCoordinator = false
    if type(coordinator) == "string" and type(self._SamePlayer) == "function" then
        fromCoordinator = self:_SamePlayer(sender, coordinator) and true or false
    end
    local now = C.Now and C.Now() or 0
    if isCoordinator and not fromCoordinator then
        if not (self._SamePlayer and self:_SamePlayer(sender, payload.receiver)) then
            Debug("Warn", "Rejected trade freeze from %s for %s", tostring(sender), tostring(payload.receiver))
            return
        end
        self._consumablesFreezeLimits = self._consumablesFreezeLimits or {}
        if S.AllowRemoteOp and not S.AllowRemoteOp(self._consumablesFreezeLimits, sender, now) then
            return
        end
        local accepted
        if payload.kind == "withdraw" then
            accepted = S.RegisterWithdrawGrant and S.RegisterWithdrawGrant(profile, payload, now)
        else
            accepted = S.RegisterTradeGrant(profile, payload, now)
        end
        if not accepted then
            Debug("Verbose", "Rejected trade freeze from %s", tostring(sender))
            return
        end
        self:BroadcastTradeFreeze(profile, payload)
        return
    end
    if fromCoordinator and not isCoordinator then
        if payload.kind == "withdraw" then
            if S.AcceptCoordinatorWithdrawGrant then
                S.AcceptCoordinatorWithdrawGrant(profile, payload, now)
            end
        else
            S.AcceptCoordinatorTradeGrant(profile, payload, now)
        end
    end
end
