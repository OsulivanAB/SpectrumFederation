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

function Sync:_AttachConsumablesDescriptor(payload, profileId)
    local C = Consumables()
    if not C or type(payload) ~= "table" then return end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(profileId) or nil
    if not profile then return end
    local desc = C.Descriptor(profile)
    payload.consumablesGeneration = desc.generation
    payload.consumablesConfigSeq = desc.configSeq
    payload.consumablesEventCount = desc.eventCount
end

function Sync:_ConsiderConsumablesCatchUp(payload)
    local C = Consumables()
    local S = Rules()
    if not C or not S or type(payload) ~= "table" then return end
    if not (self.state and self.state.active) then return end
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
    if not S.NeedsCatchUp(C.Descriptor(profile), {
        generation = payload.consumablesGeneration,
        configSeq = payload.consumablesConfigSeq,
        eventCount = payload.consumablesEventCount,
    }) then
        return
    end
    local key = table.concat({
        tostring(payload.sessionId),
        tostring(payload.consumablesGeneration),
        tostring(payload.consumablesConfigSeq),
        tostring(payload.consumablesEventCount),
    }, ":")
    if self._consumablesCatchUpKey == key then
        return
    end
    self._consumablesCatchUpKey = key
    if self.RequestProfileSnapshot then
        self:RequestProfileSnapshot("consumables-catchup")
    end
end

local function SessionPayloadOk(payload)
    if type(payload) ~= "table" then return false end
    if not (Sync.state and Sync.state.active) then return false end
    if payload.profileId ~= Sync.state.profileId then return false end
    if payload.sessionId and Sync.state.sessionId and payload.sessionId ~= Sync.state.sessionId then
        return false
    end
    return true
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
    if not SessionPayloadOk(payload) then return end
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
    local snap = C.ExportSnapshot(profile)
    snap.events = nil
    snap.profileId = ProfileIdOf(profile)
    snap.sessionId = self.state.sessionId
    SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_CONFIG, snap, dist, nil, "BULK")
end

function Sync:HandleConsumablesConfig(sender, payload)
    if not SessionPayloadOk(payload) then return end
    local C = Consumables()
    local S = Rules()
    if not C or not S then return end
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
    if type(event) ~= "table" then return end
    if not (self.state and self.state.active and SF.LootHelperComm and self.MSG) then return end
    if self.IsSafeModeEnabled and self:IsSafeModeEnabled() then return end
    if not SessionFor(profile) then return end
    local dist = self._EnforceGroupedSessionActive and self:_EnforceGroupedSessionActive("BroadcastConsumablesEvent")
    if not dist then return end
    SF.LootHelperComm:Send("BULK", self.MSG.CONSUMABLES_EVENT, {
        sessionId = self.state.sessionId,
        profileId = ProfileIdOf(profile),
        event = event,
    }, dist, nil, "NORMAL")
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
    if not SessionPayloadOk(payload) then return end
    local S = Rules()
    if not S or type(payload.event) ~= "table" then return end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(payload.profileId) or nil
    if not profile then return end
    local ok, status = S.ApplyRemoteEvent(profile, payload.event, sender)
    if not ok and status ~= "duplicate" then
        Debug("Verbose", "Ignored consumables event from %s (%s)", tostring(sender), tostring(status))
    end
end
