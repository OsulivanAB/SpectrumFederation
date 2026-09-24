-- Production-Lua tests for Loot Helper sync authorization and request routing.
-- Run from the repository root: lua5.1 tests/lua/loot_helper_sync_authorization_tests.lua

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. message .. "\n")
end

local function assertTrue(cond, message)
    if cond then
        pass(message)
    else
        fail(message)
    end
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local function assertNil(actual, message)
    if actual == nil then
        pass(message)
    else
        fail(string.format("%s (expected nil, got %s)", message, tostring(actual)))
    end
end

function GetServerTime()
    return 1700000000
end

function GetTime()
    return 0
end

function time()
    return 1700000000
end

function GetRealmName()
    return "Realm"
end

function UnitFullName()
    return "Coord", "Realm"
end

function IsInRaid()
    return true
end

function IsInGroup()
    return true
end

function GetNumGroupMembers()
    return 0
end

function strsplit(delim, text)
    local left, right = string.match(text, "^(.-)" .. delim .. "(.*)$")
    return left, right
end

local timers = {}
C_Timer = {
    NewTimer = function(_, fn)
        local handle = { cancelled = false, fn = fn }
        function handle:Cancel()
            self.cancelled = true
        end
        timers[#timers + 1] = handle
        return handle
    end,
    NewTicker = function()
        local handle = { cancelled = false }
        function handle:Cancel()
            self.cancelled = true
        end
        return handle
    end,
}

local SF = {}
local warnings = {}
local infos = {}
local sends = {}
local currentSelf = "Member-Realm"

function SF:PrintWarning(message)
    warnings[#warnings + 1] = tostring(message)
end

function SF:PrintInfo(message)
    infos[#infos + 1] = tostring(message)
end

function SF:PrintError(message)
    warnings[#warnings + 1] = tostring(message)
end

SF.Debug = setmetatable({}, {
    __index = function()
        return function() end
    end,
})

SF.NameUtil = {
    GetSelfId = function()
        return currentSelf
    end,
}

SF.LootHelperComm = {
    Send = function(_, _, msgType, payload, dist, target)
        sends[#sends + 1] = {
            msgType = msgType,
            payload = payload,
            dist = dist,
            target = target,
        }
        return true
    end,
}

local function loadModule(path)
    local chunk, err = loadfile(path)
    if not chunk then
        error(err)
    end
    chunk("SpectrumFederation", SF)
end

loadModule("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/01_Constants.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/02_State.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/03_Metrics.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/04_SafeMode.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/05_Scheduling.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/06_Peers.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/07_Validation.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/08_Requests.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/09_AdminConvergence.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/10_Handshake.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/11_Heartbeat.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/12_LiveUpdates.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/13_Routing.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/14_HandlersControl.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/15_HandlersBulk.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/16_ProfileIntegration.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/18_PublicAPI.lua")

local Sync = SF.LootHelperSync
local PROFILE = "profile-1"
local SESSION = "session-1"
local COORD = "Coord-Realm"
local SUSPENDERS = "Suspenders-Realm"
local KINO = "Kino-Realm"
local OWNER = "Owner-Realm"
local MEMBER = "Member-Realm"
local STRANGER = "Stranger-Realm"

local admins = {}

local function listHas(list, name)
    if type(list) ~= "table" then
        return false
    end
    for _, existing in ipairs(list) do
        if existing == name then
            return true
        end
    end
    return false
end

local function warningCount(fragment)
    local n = 0
    for _, message in ipairs(warnings) do
        if string.find(message, fragment, 1, true) then
            n = n + 1
        end
    end
    return n
end

local function sendCount(msgType, target)
    local n = 0
    for _, sent in ipairs(sends) do
        if sent.msgType == msgType and (target == nil or sent.target == target) then
            n = n + 1
        end
    end
    return n
end

local profile

local function setAdmins(list)
    admins = {}
    for _, name in ipairs(list) do
        admins[#admins + 1] = name
    end
    profile._adminUsers = admins
end

local function reset(selfName)
    currentSelf = selfName or MEMBER
    warnings = {}
    infos = {}
    sends = {}
    for i = #timers, 1, -1 do
        timers[i] = nil
    end
    admins = { COORD, SUSPENDERS, KINO, OWNER }
    profile = {
        _profileId = PROFILE,
        _lootLogs = {},
        _members = {},
        _adminUsers = admins,
        GetProfileId = function(self)
            return self._profileId
        end,
        GetAdminUsers = function()
            return admins
        end,
        GetLootLogs = function(self)
            return self._lootLogs
        end,
        AddLootLog = function()
            return false
        end,
    }
    SF.lootHelperDB = { profiles = { [PROFILE] = profile } }
    Sync.state.active = true
    Sync.state.sessionId = SESSION
    Sync.state.profileId = PROFILE
    Sync.state.coordinator = COORD
    Sync.state.coordEpoch = 10
    Sync.state.isCoordinator = currentSelf == COORD
    Sync.state.helpers = { SUSPENDERS, KINO }
    Sync.state.authorMax = {}
    Sync.state.authorWindowSummary = {}
    Sync.state.requests = {}
    Sync.state.peers = {
        [COORD] = { inGroup = true, online = true },
        [SUSPENDERS] = { inGroup = true, online = true },
        [KINO] = { inGroup = true, online = true },
        [OWNER] = { inGroup = true, online = true },
        [MEMBER] = { inGroup = true, online = true },
    }
    Sync.state.heartbeat = {}
    Sync.state._unauthorizedCoordTakeoverFor = nil
    Sync.state._reconcilingSessionAuthorization = nil
    Sync.state._relinquishingCoordination = nil
    Sync.state._profileReqInFlight = nil
    Sync.state._noProfileTargetWarnedFor = nil
    Sync.state._noLogTargetWarnedFor = nil
    Sync.state._coordinatorCatchUp = nil
    Sync.state.revokedRoutes = nil
    Sync.state._adminGrantServe = nil
    Sync.state._newLogUnauthorizedWarned = nil
    Sync.state._sentJoinStatusForSessionId = nil
    Sync.state._sessionAnnounced = SESSION
    Sync._reconcilingSessionAuthorization = nil
    Sync._relinquishingCoordination = nil
end

Sync._EnforceGroupedSessionActive = function()
    return "RAID"
end
Sync.UpdatePeersFromRoster = function() end
local originalBeginAdminConvergence = Sync.BeginAdminConvergence
Sync.BeginAdminConvergence = function()
    return true
end
Sync.IsRequesterInGroup = function()
    return true
end
Sync.EnsureRepairConvergence = function()
    return false
end
Sync.SendJoinStatus = function() end
local productionQueueRepairRanges = Sync.QueueRepairRanges
Sync.QueueRepairRanges = function()
    return false
end
Sync.ComputeContigAuthorMax = function()
    return {}
end
Sync.ComputeAuthorMax = function()
    return {}
end
Sync.ComputeMissingLogRequests = function()
    return {}
end
Sync.ComputeWindowMismatchRequests = function()
    return {}
end
Sync._ComputeContigCounter = function()
    return 99
end
Sync.MergeLogs = function()
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end

local function seedRequest(id, kind, targets, lastTarget)
    local req = {
        id = id,
        kind = kind,
        attempt = lastTarget and 1 or 0,
        maxRetries = 2,
        timeoutSec = 5,
        createdAt = Sync:_Now(),
        lastSentAt = lastTarget and Sync:_Now() or nil,
        lastTarget = lastTarget,
        targets = targets,
        targetIdx = lastTarget and 1 or 0,
        meta = {
            sessionId = SESSION,
            profileId = PROFILE,
            author = "Author-Realm",
            fromCounter = 1,
            toCounter = 2,
        },
        timer = nil,
    }
    if lastTarget then
        Sync:_RememberInflightResponder(req, lastTarget)
    end
    Sync.state.requests[id] = req
    return req
end

local function authPayload(requestId, sender)
    return {
        sessionId = SESSION,
        profileId = PROFILE,
        requestId = requestId,
        author = "Author-Realm",
        fromCounter = 1,
        toCounter = 2,
        logs = {},
    }, sender
end

reset(MEMBER)

-- 1. Remove an active helper from canonical admins.
setAdmins({ COORD, KINO, OWNER })
Sync.state.helpers = { SUSPENDERS, KINO }
seedRequest("need-1", "NEED_LOGS", { SUSPENDERS, COORD }, SUSPENDERS)
Sync:ReconcileSessionAuthorization(PROFILE, "remove-helper")
assertTrue(not listHas(Sync.state.helpers, SUSPENDERS), "removed helper leaves the helper list")
assertTrue(listHas(Sync.state.helpers, KINO), "unrelated helper stays in the helper list")
local need = Sync.state.requests["need-1"]
assertTrue(need ~= nil, "outstanding need-logs request remains")
assertTrue(not listHas(need.targets, SUSPENDERS), "future targets drop the removed helper")
assertTrue(Sync:_ResponderMapHas(need.revokedResponders, SUSPENDERS), "removed helper is marked revoked for the request")

currentSelf = SUSPENDERS
Sync.state.isCoordinator = false
Sync.state.helpers = { SUSPENDERS }
local beforeSends = #sends
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "serve-1",
    missing = {
        { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
    },
})
assertEq(sendCount(Sync.MSG.AUTH_LOGS, MEMBER), 0, "removed helper does not serve NEED_LOGS")
assertEq(#sends, beforeSends, "removed helper sends no privileged sync traffic")
Sync:HandleLogRequest(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "logreq-1",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
})
assertEq(sendCount(Sync.MSG.AUTH_LOGS), 0, "removed admin does not serve LOG_REQ")
Sync.state.isCoordinator = true
Sync.state.active = true
local adminSend = Sync:_SendAdminLogReq({
    id = "admin-req",
    meta = { sessionId = SESSION, profileId = PROFILE, author = "Author-Realm", fromCounter = 1, toCounter = 2 },
}, COORD)
assertEq(adminSend, false, "removed coordinator cannot send ADMIN LOG_REQ")

-- 2. Outstanding request stops retrying the revoked admin.
reset(MEMBER)
setAdmins({ COORD, KINO, OWNER })
seedRequest("need-2", "NEED_LOGS", { SUSPENDERS }, SUSPENDERS)
Sync:ReconcileSessionAuthorization(PROFILE, "revoke-outstanding")
need = Sync.state.requests["need-2"]
assertTrue(not listHas(need.targets, SUSPENDERS), "revoked admin is not a retry target")
local warnBefore = #warnings
Sync:OnRequestTimeout("need-2")
assertEq(sendCount(Sync.MSG.NEED_LOGS, SUSPENDERS), 0, "timeout does not retry the revoked admin")
assertEq(warningCount("not a trusted sender"), 0, "retarget does not warn about trust")
assertEq(#warnings, warnBefore, "retarget does not add a user warning")

-- 3. Helper rotation while the admin is still valid.
reset(MEMBER)
seedRequest("need-3", "NEED_LOGS", { KINO, COORD }, KINO)
Sync:ApplyAdvertisedHelpers({ OWNER }, "rotation")
need = Sync.state.requests["need-3"]
assertTrue(not listHas(need.targets, KINO), "rotated helper is not a future target")
assertTrue(Sync:_ResponderMapHas(need.inflightResponders, KINO), "in-flight responder grant remains")
assertTrue(not Sync:_ResponderMapHas(need.revokedResponders, KINO), "still-authorized helper is not revoked")
local payload, sender = authPayload("need-3", KINO)
Sync:HandleAuthLogs(sender, payload)
assertEq(warningCount("not a trusted sender"), 0, "in-flight authorized response is not a trust warning")
assertEq(warningCount("not an admin"), 0, "in-flight authorized response is not an admin warning")
assertNil(Sync.state.requests["need-3"], "in-flight authorized response completes the request")

-- 4. Removing a non-helper admin leaves helper routing alone.
reset(MEMBER)
local beforeHelpers = { SUSPENDERS, KINO }
Sync.state.helpers = { SUSPENDERS, KINO }
setAdmins({ COORD, SUSPENDERS, KINO })
Sync:ReconcileSessionAuthorization(PROFILE, "remove-non-helper")
assertTrue(Sync:_SamePlayerList(Sync.state.helpers, beforeHelpers), "non-helper admin removal keeps helpers")

-- 5. Remove then re-add does not revive stale request authority.
reset(MEMBER)
seedRequest("need-5", "NEED_LOGS", { SUSPENDERS, COORD }, SUSPENDERS)
setAdmins({ COORD, KINO, OWNER })
Sync:ReconcileSessionAuthorization(PROFILE, "remove-for-readd")
setAdmins({ COORD, SUSPENDERS, KINO, OWNER })
Sync.state.helpers = { KINO }
Sync:ReconcileSessionAuthorization(PROFILE, "readd")
need = Sync.state.requests["need-5"]
assertTrue(need ~= nil, "request survives re-add")
assertTrue(not listHas(need.targets, SUSPENDERS), "re-add does not restore a stale target")
payload, sender = authPayload("need-5", SUSPENDERS)
Sync:HandleAuthLogs(sender, payload)
assertEq(warningCount("not a trusted sender"), 0, "re-added stale responder does not warn")
assertEq(warningCount("not an admin"), 0, "re-added stale responder is not treated as a new admin failure")
assertTrue(Sync.state.requests["need-5"] ~= nil, "stale response after re-add does not regain authority")

-- 6. Removing the active coordinator.
reset(COORD)
Sync.state.isCoordinator = true
setAdmins({ KINO, OWNER })
Sync.state.helpers = { KINO }
seedRequest("admin-6", "ADMIN_LOG_REQ", { KINO }, nil)
Sync:ReconcileSessionAuthorization(PROFILE, "coordinator-removed")
assertEq(Sync.state.isCoordinator, false, "removed coordinator stops acting as coordinator")
assertEq(Sync.state.active, true, "session stays up for an eligible successor")
assertEq(sendCount(Sync.MSG.SES_END), 0, "eligible successor path does not end the session")
assertEq(sendCount(Sync.MSG.SES_HEARTBEAT), 0, "removed coordinator does not keep heartbeating")
assertNil(Sync.state.requests["admin-6"], "admin log requests stop after coordinator revocation")

currentSelf = KINO
Sync.state.isCoordinator = false
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
Sync.state.active = true
Sync.state.sessionId = SESSION
Sync.state.profileId = PROFILE
setAdmins({ KINO, OWNER })
Sync:_MaybeAssumeCoordinationAfterAdminChange("coordinator-removed")
assertEq(Sync.state.isCoordinator, true, "eligible admin takes over")
assertEq(Sync.state.coordinator, KINO, "takeover coordinator is the eligible admin")
assertEq(sendCount(Sync.MSG.COORD_TAKEOVER), 1, "takeover reuses COORD_TAKEOVER")

reset(COORD)
Sync.state.isCoordinator = true
setAdmins({})
Sync.state.peers[KINO].inGroup = false
Sync.state.peers[OWNER].inGroup = false
Sync.state.peers[SUSPENDERS].inGroup = false
Sync.state.peers[COORD].inGroup = true
Sync:ReconcileSessionAuthorization(PROFILE, "coordinator-removed-no-successor")
assertEq(Sync.state.active, false, "session ends when no eligible admin remains")
assertEq(sendCount(Sync.MSG.SES_END), 1, "coordinator broadcasts session end")

-- 7. Outstanding request across coordinator takeover.
reset(MEMBER)
setAdmins({ COORD, KINO, OWNER })
seedRequest("need-7", "NEED_LOGS", { COORD }, COORD)
Sync.state.coordinator = KINO
Sync.state.coordEpoch = 11
Sync.state.helpers = { OWNER }
Sync:_RefreshOutstandingRequestTargets()
need = Sync.state.requests["need-7"]
assertTrue(not listHas(need.targets, COORD), "old coordinator is not a future target after takeover")
assertTrue(listHas(need.targets, KINO), "new coordinator is a request target")
payload, sender = authPayload("need-7", COORD)
Sync:HandleAuthLogs(sender, payload)
assertEq(warningCount("not a trusted sender"), 0, "old coordinator in-flight response is not a trust warning")
assertNil(Sync.state.requests["need-7"], "still-authorized previous coordinator response can complete")

reset(MEMBER)
seedRequest("need-7b", "NEED_LOGS", { KINO }, nil)
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync:_RefreshOutstandingRequestTargets()
payload, sender = authPayload("need-7b", KINO)
Sync:HandleAuthLogs(sender, payload)
assertEq(warningCount("not a trusted sender"), 0, "new coordinator response is accepted")
assertEq(warningCount("not an admin"), 0, "new coordinator response is authorized")

-- 8. Valid admin left on an older target list.
reset(MEMBER)
seedRequest("need-8", "NEED_LOGS", { KINO, COORD }, KINO)
Sync:ApplyAdvertisedHelpers({ OWNER }, "stale-valid-admin")
assertTrue(not listHas(Sync.state.requests["need-8"].targets, KINO), "stale valid admin is not asked again")
payload, sender = authPayload("need-8", KINO)
Sync:HandleAuthLogs(sender, payload)
assertEq(warningCount("not a trusted sender"), 0, "valid admin answering the original request is not rejected")

-- 9. Unauthorized unsolicited traffic is still rejected.
reset(MEMBER)
seedRequest("need-9", "NEED_LOGS", { COORD }, COORD)
payload, sender = authPayload("need-9", STRANGER)
Sync:HandleAuthLogs(sender, payload)
assertEq(warningCount("not an admin of profile"), 1, "stranger AUTH_LOGS is rejected")
assertTrue(Sync.state.requests["need-9"] ~= nil, "unsolicited response does not complete the request")

Sync:HandleProfileSnapshot(STRANGER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-9",
    snapshot = {},
})
assertEq(warningCount("PROFILE_SNAPSHOT"), 1, "stranger snapshot is rejected")

Sync:HandleNewLog(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    log = { _eventType = "POINT_CHANGE", _data = { member = MEMBER } },
})
-- COORD is still an admin in this reset, so swap to a revoked coordinator sender.
setAdmins({ KINO, OWNER })
Sync.state.coordinator = SUSPENDERS
Sync:HandleNewLog(SUSPENDERS, {
    sessionId = SESSION,
    profileId = PROFILE,
    log = { _eventType = "POINT_CHANGE", _data = { member = MEMBER } },
})
assertTrue(warningCount("not an admin") >= 1, "revoked coordinator NEW_LOG is rejected")

-- 10. Repeated reconcile, heartbeat, and stale responses do not regenerate warnings.
reset(MEMBER)
setAdmins({ COORD, KINO, OWNER })
Sync.state.helpers = { SUSPENDERS, KINO }
seedRequest("need-10", "NEED_LOGS", { SUSPENDERS, COORD }, SUSPENDERS)
Sync:ReconcileSessionAuthorization(PROFILE, "spam-setup")
local baseline = #warnings
for _ = 1, 20 do
    Sync:ReconcileSessionAuthorization(PROFILE, "spam-reconcile")
    Sync:ApplyAdvertisedHelpers({ KINO }, "spam-heartbeat")
end
payload, sender = authPayload("need-10", SUSPENDERS)
for _ = 1, 8 do
    Sync:HandleAuthLogs(sender, payload)
end
assertEq(#warnings, baseline, "repeated stale authorization traffic does not warn")
assertEq(sendCount(Sync.MSG.NEED_LOGS, SUSPENDERS), 0, "repeated refresh does not retry the revoked admin")

-- Heartbeat helper-only change retargets without a coordinator/epoch change.
reset(MEMBER)
seedRequest("need-hb", "NEED_LOGS", { SUSPENDERS, COORD }, SUSPENDERS)
local epoch = Sync.state.coordEpoch
local coord = Sync.state.coordinator
Sync:HandleSessionHeartbeat(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = epoch,
    helpers = { KINO },
    authorMax = {},
    sentAt = 50,
})
assertEq(Sync.state.coordinator, coord, "helper heartbeat keeps the coordinator")
assertEq(Sync.state.coordEpoch, epoch, "helper heartbeat keeps the epoch")
assertTrue(not listHas(Sync.state.helpers, SUSPENDERS), "heartbeat helper list drops the old helper")
assertTrue(not listHas(Sync.state.requests["need-hb"].targets, SUSPENDERS), "heartbeat retargets outstanding requests")

-- ChooseHelpers will not select a revoked admin.
reset(COORD)
Sync.state.isCoordinator = true
setAdmins({ COORD, KINO })
Sync:UpdatePeersFromRoster()
Sync.state.peers[SUSPENDERS] = { inGroup = true, online = true }
Sync.state.peers[KINO] = { inGroup = true, online = true }
local chosen = Sync:ChooseHelpers({
    [SUSPENDERS] = { hasProfile = true, hasGaps = false },
    [KINO] = { hasProfile = true, hasGaps = false },
})
assertTrue(not listHas(chosen, SUSPENDERS), "ChooseHelpers skips a revoked admin")
assertTrue(listHas(chosen, KINO), "ChooseHelpers keeps an authorized admin")

-- A still-valid admin who is only an old preferred target is not a new route.
reset(MEMBER)
Sync.state.helpers = { SUSPENDERS }
local preferredTargets = Sync:_CurrentAuthorizedRoutingTargets({ preferredTarget = KINO })
assertTrue(not listHas(preferredTargets, KINO), "former helper preferred target is not a new route")
assertTrue(listHas(preferredTargets, SUSPENDERS), "current helper remains a route")
assertTrue(listHas(preferredTargets, COORD), "current coordinator remains a route")

-- Authorized coordinator NEW_LOG is not rejected as unauthorized.
reset(MEMBER)
local before = warningCount("not an admin")
Sync:HandleNewLog(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    log = {
        _eventType = "POINT_CHANGE",
        _author = COORD,
        _counter = 1,
        _data = { member = MEMBER },
    },
})
assertEq(warningCount("not an admin"), before, "authorized coordinator NEW_LOG is allowed")

-- Trusted PROFILE_SNAPSHOT can bootstrap a profile that does not exist locally yet.
reset(MEMBER)
SF.lootHelperDB.profiles = {}
SF.lootHelperDB.activeProfileId = nil
local bootReq = seedRequest("need-boot", "NEED_PROFILE", { COORD }, COORD)
local bootDisposition = Sync:_ClassifyPrivilegedResponse(COORD, PROFILE, bootReq)
assertEq(bootDisposition, "accept", "trusted snapshot is accepted before the local profile exists")
local strangerDisposition = Sync:_ClassifyPrivilegedResponse(STRANGER, PROFILE, bootReq)
assertEq(strangerDisposition, "untrusted", "unknown profile does not make a stranger trusted")
Sync:HandleProfileSnapshot(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-boot",
    snapshot = {},
})
assertEq(warningCount("PROFILE_SNAPSHOT"), 0, "bootstrap snapshot does not warn")
Sync:HandleProfileSnapshot(STRANGER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-boot",
    snapshot = {},
})
assertEq(warningCount("not a trusted sender"), 1, "untrusted bootstrap snapshot still warns")

-- In-flight trust from a log request does not authorize a profile snapshot.
reset(MEMBER)
setAdmins({ COORD, KINO, OWNER })
Sync.state.isCoordinator = false
Sync.state.coordinator = COORD
Sync.state.helpers = { COORD }
local logReq = seedRequest("log-snap", "LOG_REQ", { KINO }, KINO)
local snapDisposition = Sync:_ClassifyPrivilegedResponse(KINO, PROFILE, logReq, {
    coordinatorAcceptsAdmins = false,
    expectedKinds = { NEED_PROFILE = true },
})
assertEq(snapDisposition, "mismatch", "snapshot citing a log request is a kind mismatch")
Sync.state.helpers = { KINO }
snapDisposition = Sync:_ClassifyPrivilegedResponse(KINO, PROFILE, logReq, {
    coordinatorAcceptsAdmins = false,
    expectedKinds = { NEED_PROFILE = true },
})
assertEq(snapDisposition, "mismatch", "helper trust does not accept a snapshot for a log request")
Sync:HandleProfileSnapshot(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "log-snap",
    snapshot = { meta = { _profileId = PROFILE } },
})
assertEq(warningCount("not a trusted sender"), 0, "kind mismatch is not reported as untrusted")
assertEq(warningCount("does not match the request"), 1, "mismatched snapshot warns once")
assertTrue(Sync.state.requests["log-snap"] ~= nil, "mismatched snapshot does not complete the log request")
Sync:HandleProfileSnapshot(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "log-snap",
    snapshot = { meta = { _profileId = PROFILE } },
})
assertEq(warningCount("does not match the request"), 1, "repeat mismatched snapshot does not warn again")
local profileReq = seedRequest("need-kind", "NEED_PROFILE", { COORD }, COORD)
Sync.state._profileReqInFlight = SESSION
local logsDisposition = Sync:_ClassifyPrivilegedResponse(COORD, PROFILE, profileReq, {
    coordinatorAcceptsAdmins = true,
    expectedKinds = {
        NEED_LOGS = true,
        LOG_REQ = true,
        ADMIN_LOG_REQ = true,
    },
})
assertEq(logsDisposition, "mismatch", "AUTH_LOGS citing NEED_PROFILE is a kind mismatch")
Sync:HandleAuthLogs(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-kind",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
    logs = { { _author = "Author-Realm", _counter = 1 } },
})
assertTrue(Sync.state.requests["need-kind"] ~= nil, "mismatched AUTH_LOGS does not complete NEED_PROFILE")
assertEq(Sync.state._profileReqInFlight, SESSION, "mismatched AUTH_LOGS leaves the profile request marker")
local mismatchWarnings = warningCount("AUTH_LOGS")
Sync:HandleAuthLogs(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-kind",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
    logs = { { _author = "Author-Realm", _counter = 1 } },
})
assertEq(warningCount("AUTH_LOGS"), mismatchWarnings, "repeat mismatched AUTH_LOGS does not warn again")
local profileReq = seedRequest("need-snap", "NEED_PROFILE", { KINO }, KINO)
snapDisposition = Sync:_ClassifyPrivilegedResponse(KINO, PROFILE, profileReq, {
    coordinatorAcceptsAdmins = false,
    expectedKinds = { NEED_PROFILE = true },
})
assertEq(snapDisposition, "accept", "in-flight NEED_PROFILE response stays accepted")

-- A helper inserted ahead of the previous target must be attempted next.
reset(MEMBER)
Sync.state.helpers = {}
seedRequest("need-insert", "NEED_LOGS", { COORD }, COORD)
Sync:ApplyAdvertisedHelpers({ KINO }, "heartbeat-added-helper")
need = Sync.state.requests["need-insert"]
assertEq(need.targets[1], KINO, "inserted helper precedes the previous target")
assertEq(need.targets[2], COORD, "previous coordinator target stays on the list")
assertEq(need.targetIdx, 0, "inserted helper is not treated as already attempted")
Sync:OnRequestTimeout("need-insert")
assertEq(sendCount(Sync.MSG.NEED_LOGS, KINO), 1, "timeout retries the newly inserted helper")
assertTrue(Sync.state.requests["need-insert"] ~= nil, "request does not fail before the new helper is tried")

-- Revoked admins cannot keep contributing convergence evidence.
reset(COORD)
Sync.state.isCoordinator = true
Sync.state.helpers = { KINO }
Sync.state.adminStatuses = {
    [SUSPENDERS] = { authorMax = { [MEMBER] = 9 } },
    [KINO] = { authorMax = { [MEMBER] = 9 } },
}
setAdmins({ COORD, KINO, OWNER })
Sync:ReconcileSessionAuthorization(PROFILE, "status-purge")
assertNil(Sync.state.adminStatuses[SUSPENDERS], "revoked admin status is removed")
assertTrue(type(Sync.state.adminStatuses[KINO]) == "table", "remaining admin status is kept")
local providers = Sync:_ProvidersAdvertisingAuthorMax(MEMBER, 1, 9)
assertTrue(not listHas(providers, SUSPENDERS), "revoked admin is not selected as a provider")
assertTrue(listHas(providers, KINO), "remaining admin can still be selected")

reset(COORD)
Sync.state.isCoordinator = true
Sync.state.helpers = { KINO }
Sync.state.adminStatuses = {
    [SUSPENDERS] = { authorMax = { [MEMBER] = 9 } },
}
setAdmins({ COORD, KINO, OWNER })
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:auth_logs")
assertTrue(type(Sync.state.adminStatuses[SUSPENDERS]) == "table",
    "log rebuild keeps advertiser status for identity reconcile")
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:live_update")
assertTrue(type(Sync.state.adminStatuses[SUSPENDERS]) == "table",
    "ordinary live rebuild keeps advertiser status")
Sync.state.adminStatuses[KINO] = { authorMax = { [MEMBER] = 4 } }
setAdmins({ COORD, KINO, OWNER, SUSPENDERS })
Sync:_DropLiveRemovedAdminStatus(PROFILE, SUSPENDERS)
assertTrue(type(Sync.state.adminStatuses[SUSPENDERS]) == "table",
    "live ADMIN_REMOVED keeps status when the player is still an admin")
setAdmins({ COORD, KINO, OWNER })
Sync:_DropLiveRemovedAdminStatus(PROFILE, SUSPENDERS)
assertNil(Sync.state.adminStatuses[SUSPENDERS], "live ADMIN_REMOVED drops only a player who lost admin")
assertTrue(type(Sync.state.adminStatuses[KINO]) == "table", "other advertiser status survives a live removal")

-- A live ROLE_CHANGE to member is the same named revocation. A promotion is not.
reset(MEMBER)
setAdmins({ COORD, SUSPENDERS, KINO, OWNER })
Sync.state.helpers = { SUSPENDERS, KINO }
Sync.state.adminStatuses = {
    [SUSPENDERS] = { authorMax = { [MEMBER] = 3 } },
    [KINO] = { authorMax = { [MEMBER] = 3 } },
}
seedRequest("need-demote", "NEED_LOGS", { SUSPENDERS, KINO, COORD }, SUSPENDERS)
profile.AddLootLog = function()
    return true
end
Sync.RebuildProfile = function(self, profileId, reason)
    setAdmins({ COORD, KINO, OWNER })
    self:ReconcileSessionAuthorization(profileId, "rebuild:" .. reason)
    return true
end
Sync:HandleNewLog(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    log = {
        _eventType = "ROLE_CHANGE",
        _author = COORD,
        _counter = 1,
        _data = { member = SUSPENDERS, newRole = "MEMBER" },
    },
})
assertTrue(not listHas(Sync.state.helpers, SUSPENDERS), "live member demotion drops that helper")
assertTrue(listHas(Sync.state.helpers, KINO), "live member demotion keeps other helpers")
assertTrue(not listHas(Sync.state.requests["need-demote"].targets, SUSPENDERS),
    "live member demotion drops that request target")
assertNil(Sync.state.adminStatuses[SUSPENDERS], "live member demotion drops that advertiser status")
assertTrue(type(Sync.state.adminStatuses[KINO]) == "table", "live member demotion keeps other advertiser status")

reset(MEMBER)
setAdmins({ COORD, SUSPENDERS, KINO, OWNER })
Sync.state.helpers = { SUSPENDERS }
Sync.state.adminStatuses = {
    [SUSPENDERS] = { authorMax = { [MEMBER] = 3 } },
}
seedRequest("need-promote", "NEED_LOGS", { SUSPENDERS, COORD }, SUSPENDERS)
profile.AddLootLog = function()
    return true
end
Sync.RebuildProfile = function(self, profileId, reason)
    self:ReconcileSessionAuthorization(profileId, "rebuild:" .. reason)
    return true
end
Sync:HandleNewLog(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    log = {
        _eventType = "ROLE_CHANGE",
        _author = COORD,
        _counter = 2,
        _data = { member = SUSPENDERS, newRole = "ADMIN" },
    },
})
assertTrue(listHas(Sync.state.helpers, SUSPENDERS), "live admin promotion does not drop that helper")
assertTrue(type(Sync.state.adminStatuses[SUSPENDERS]) == "table", "live admin promotion keeps advertiser status")

reset(MEMBER)
setAdmins({ COORD, SUSPENDERS, OWNER })
Sync.state.helpers = { SUSPENDERS }
seedRequest("need-owner-demote", "NEED_LOGS", { SUSPENDERS, COORD }, SUSPENDERS)
profile.AddLootLog = function()
    return true
end
Sync.RebuildProfile = function(self, profileId, reason)
    self:ReconcileSessionAuthorization(profileId, "rebuild:" .. reason)
    return true
end
Sync:HandleNewLog(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    log = {
        _eventType = "ROLE_CHANGE",
        _author = COORD,
        _counter = 3,
        _data = { member = SUSPENDERS, newRole = "MEMBER" },
    },
})
assertTrue(listHas(Sync.state.helpers, SUSPENDERS), "live demotion keeps a player the rebuild still lists as admin")

-- Reload must not resume coordination from a stale persisted coordinator.
reset(COORD)
Sync.state.isCoordinator = true
Sync.state.coordinator = COORD
Sync.state.helpers = { KINO }
setAdmins({ KINO, OWNER })
Sync:_PersistSessionState("before-reload")
Sync.state.active = false
Sync.state.isCoordinator = false
local restored = Sync:TryRestorePersistedSession("reload")
assertEq(restored, true, "revoked coordinator still restores the session")
assertEq(Sync.state.active, true, "restored session stays active for a successor")
assertEq(Sync.state.isCoordinator, false, "reload does not resume a revoked coordinator")
assertEq(Sync.state._restoredSessionNeedsReannounce, false, "revoked coordinator does not schedule reannounce")
Sync:_ReannounceRestoredSessionIfNeeded()
assertEq(sendCount(Sync.MSG.SES_REANNOUNCE), 0, "revoked coordinator does not reannounce after reload")

reset(COORD)
Sync.state.isCoordinator = true
Sync.state.coordinator = COORD
Sync.state.helpers = { KINO }
setAdmins({ COORD, KINO, OWNER })
Sync:_PersistSessionState("before-authorized-reload")
Sync.state.active = false
Sync.state.isCoordinator = false
restored = Sync:TryRestorePersistedSession("reload-authorized")
assertEq(restored, true, "authorized coordinator session restores")
assertEq(Sync.state.isCoordinator, true, "authorized coordinator resumes after reload")
assertEq(Sync.state._restoredSessionNeedsReannounce, true, "authorized coordinator schedules one reannounce")

reset(KINO)
setAdmins({ KINO, OWNER })
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_REMOVED",
        _data = { member = COORD },
    },
}
Sync.state.isCoordinator = false
Sync.state.coordinator = COORD
Sync.state.helpers = {}
Sync:_PersistSessionState("before-successor-reload")
Sync.state.active = false
Sync.state.isCoordinator = false
restored = Sync:TryRestorePersistedSession("reload-successor")
assertEq(restored, true, "successor restores the revoked coordinator session")
assertEq(Sync.state.isCoordinator, true, "first eligible successor takes over during restore")
assertEq(Sync.state._restoredSessionNeedsReannounce, false,
    "restore takeover waits for convergence before reannounce")
Sync:_ReannounceRestoredSessionIfNeeded()
assertEq(sendCount(Sync.MSG.SES_REANNOUNCE), 0, "restore takeover does not reannounce immediately")

-- Exact repairs keep the advertiser ahead of the default helper route.
reset(MEMBER)
Sync.state.helpers = { OWNER, KINO }
local preferredReq = seedRequest("need-pref", "NEED_LOGS", { COORD }, nil)
preferredReq.meta.exactAuthor = true
preferredReq.meta.integrityRepair = true
preferredReq.meta.preferredTarget = KINO
Sync:_RefreshOutstandingRequestTargets()
preferredReq = Sync.state.requests["need-pref"]
assertEq(preferredReq.targets[1], KINO, "exact repair keeps the preferred advertiser first")
assertEq(preferredReq.targets[2], COORD, "exact repair still falls back to the coordinator")
assertTrue(listHas(preferredReq.targets, OWNER), "exact repair keeps other helpers as later fallbacks")

-- Empty routes wait for a successor instead of failing the request.
reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync.state.helpers = {}
Sync.state.isCoordinator = false
local waiting = seedRequest("need-wait", "NEED_LOGS", { COORD }, COORD)
Sync:_RefreshOutstandingRequestTargets()
waiting = Sync.state.requests["need-wait"]
assertTrue(waiting ~= nil, "request survives refresh with no current route")
assertTrue(listHas(waiting.targets, COORD), "request holds its targets until a successor is stored")
Sync:OnRequestTimeout("need-wait")
assertTrue(Sync.state.requests["need-wait"] ~= nil, "timeout waits instead of failing with no route")
assertEq(sendCount(Sync.MSG.NEED_LOGS, COORD), 0, "timeout does not send to the revoked coordinator")
Sync:HandleCoordinatorTakeover(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
})
waiting = Sync.state.requests["need-wait"]
assertTrue(waiting ~= nil, "request survives coordinator takeover")
assertTrue(listHas(waiting.targets, KINO), "takeover retargets the request to the new coordinator")
assertTrue(not listHas(waiting.targets, COORD), "takeover drops the revoked coordinator target")

-- The client that assumes coordination refreshes the same empty route.
reset(KINO)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync.state.isCoordinator = false
Sync.state.helpers = {}
seedRequest("need-takeover", "NEED_LOGS", { COORD }, COORD)
Sync:_RefreshOutstandingRequestTargets()
local took = Sync:TakeoverSession(SESSION, PROFILE, "coordinator-removed", { rerunAdminConvergence = false })
assertEq(took, true, "eligible admin takeover succeeds")
assertEq(Sync.state.coordinator, KINO, "takeover stores the successor before routing")
assertTrue(Sync.state.requests["need-takeover"] ~= nil, "takeover does not drop the outstanding request")
for _ = 1, 8 do
    if not Sync.state.requests["need-takeover"] then break end
    Sync:OnRequestTimeout("need-takeover")
end
assertTrue(Sync.state.requests["need-takeover"] ~= nil, "missing helper route does not fail the request immediately")
Sync:OnRequestTimeout("need-takeover")
assertNil(Sync.state.requests["need-takeover"], "route wait stays capped")

-- A route discovered after the attempt budget is spent still gets one send.
reset(MEMBER)
local spent = seedRequest("need-spent", "NEED_LOGS", { COORD }, COORD)
spent.maxRetries = 0
spent.attempt = 1
Sync:OnRequestTimeout("need-spent")
assertNil(Sync.state.requests["need-spent"], "exhausted request fails when no new route exists")

reset(MEMBER)
setAdmins({ COORD, KINO, OWNER })
Sync.state.helpers = {}
local late = seedRequest("need-late", "NEED_LOGS", { COORD }, COORD)
late.maxRetries = 0
late.attempt = 1
Sync:ApplyAdvertisedHelpers({ KINO }, "inserted-after-exhausted")
Sync:OnRequestTimeout("need-late")
assertEq(sendCount(Sync.MSG.NEED_LOGS, KINO), 1, "new helper receives an attempt after the old budget is spent")
assertTrue(Sync.state.requests["need-late"] ~= nil, "request stays open after contacting the new helper")
Sync:OnRequestTimeout("need-late")
assertEq(sendCount(Sync.MSG.NEED_LOGS, COORD), 0, "already contacted coordinator is not retried after the budget")
assertNil(Sync.state.requests["need-late"], "budget stays closed after the new route is contacted")

-- Takeover convergence installs helpers and retargets a held request.
reset(KINO)
setAdmins({ KINO, OWNER })
Sync.state.isCoordinator = true
Sync.state.coordinator = KINO
Sync.state.helpers = {}
profile.ComputeAuthorMax = function()
    return {}
end
local held = seedRequest("need-conv", "NEED_LOGS", { COORD }, COORD)
Sync:_RememberRevokedResponder(held, COORD)
Sync:_RefreshOutstandingRequestTargets()
held = Sync.state.requests["need-conv"]
assertTrue(held ~= nil, "request survives refresh before a helper exists")
assertTrue(not listHas(held.targets, OWNER), "helper is not a target before convergence")
Sync.state.adminStatuses = {
    [OWNER] = { hasProfile = true, hasGaps = false, authorMax = {} },
}
Sync.state._adminConvergence = {
    pendingCount = 0,
    pendingReq = {},
    expected = {},
    onComplete = function() end,
}
Sync:FinalizeAdminConvergence()
held = Sync.state.requests["need-conv"]
assertTrue(held ~= nil, "convergence does not drop the held request")
assertTrue(listHas(held.targets, OWNER), "convergence helper becomes a request target")
assertTrue(not listHas(held.targets, COORD), "revoked coordinator is dropped once a helper exists")
Sync:OnRequestTimeout("need-conv")
assertEq(sendCount(Sync.MSG.NEED_LOGS, OWNER), 1, "timeout contacts the helper chosen by convergence")

-- An exhausted request still waits when the coordinator is revoked and no helper remains.
reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync.state.helpers = {}
Sync.state.isCoordinator = false
local spentWait = seedRequest("need-spent-wait", "NEED_LOGS", { COORD }, COORD)
spentWait.maxRetries = 0
spentWait.attempt = 1
Sync:_RememberRevokedResponder(spentWait, COORD)
Sync:_RefreshOutstandingRequestTargets()
Sync:OnRequestTimeout("need-spent-wait")
assertTrue(Sync.state.requests["need-spent-wait"] ~= nil, "exhausted request waits for a successor")
assertEq(sendCount(Sync.MSG.NEED_LOGS, COORD), 0, "exhausted wait does not send to the revoked coordinator")

-- Empty route warnings are once per session, then allowed again after a route exists.
reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync.state.helpers = {}
Sync.state.isCoordinator = false
assertEq(Sync:RequestProfileSnapshot("no-route"), false, "profile request fails with no route")
assertEq(Sync:RequestProfileSnapshot("no-route-again"), false, "profile request stays failed with no route")
assertEq(warningCount("Cannot request profile"), 1, "empty profile route warns once")
local missing = {
    { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
}
Sync:RequestMissingLogs(missing, "no-route")
Sync:RequestMissingLogs(missing, "no-route-again")
assertEq(warningCount("Cannot request missing logs"), 1, "empty log route warns once")
setAdmins({ COORD, KINO, OWNER })
Sync.state.helpers = { KINO }
assertEq(Sync:RequestProfileSnapshot("route-back"), true, "profile request proceeds when a route returns")
assertEq(warningCount("Cannot request profile"), 1, "restored profile route does not warn")
Sync:RequestMissingLogs(missing, "route-back")
assertEq(warningCount("Cannot request missing logs"), 1, "restored log route does not warn")

-- A successor the local profile has not yet recorded stays routable until their response arrives.
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.helpers = {}
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
Sync:HandleCoordinatorTakeover(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
})
local catchUpRoutes = Sync:_CurrentAuthorizedRoutingTargets()
assertTrue(not listHas(catchUpRoutes, KINO), "missing coordinator grant is not requested from the successor")
assertTrue(listHas(catchUpRoutes, OWNER), "missing coordinator grant is requested from a trusted admin")
assertEq(Sync:RequestProfileSnapshot("catch-up"), true, "profile request targets a trusted admin")
local catchUpReq = nil
for _, req in pairs(Sync.state.requests) do
    if req.kind == "NEED_PROFILE" then
        catchUpReq = req
    end
end
assertTrue(catchUpReq ~= nil, "catch-up profile request is outstanding")
assertTrue(listHas(catchUpReq.targets, OWNER), "catch-up profile request asks the trusted admin")
assertTrue(not listHas(catchUpReq.targets, KINO), "catch-up profile request does not ask the successor")
assertEq(Sync:_ClassifyPrivilegedResponse(KINO, PROFILE, catchUpReq, {
    expectedKinds = { NEED_PROFILE = true },
    catchUpProven = true,
}), "unauthorized", "successor snapshot is not accepted before the grant is stored")
assertEq(Sync:_ClassifyPrivilegedResponse(KINO, PROFILE, nil, {
    expectedKinds = { NEED_PROFILE = true },
}), "unauthorized", "unsolicited catch-up snapshot is rejected")
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 3,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
local storedRoutes = Sync:_CurrentAuthorizedRoutingTargets()
assertTrue(listHas(storedRoutes, KINO), "stored grant keeps the successor routable for confirmation")

-- A coordinator this client already revoked does not become a catch-up route.
reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync.state.helpers = {}
Sync:ReconcileSessionAuthorization(PROFILE, "remove-coordinator")
Sync:_NoteAdvertisedCoordinator(COORD)
assertNil(Sync.state._coordinatorCatchUp, "revoked coordinator is not marked for catch-up")
assertTrue(not listHas(Sync:_CurrentAuthorizedRoutingTargets(), COORD), "revoked coordinator is not routed")

-- Repeated NEW_LOG from a revoked coordinator warns once.
reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync:HandleNewLog(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    log = {
        _eventType = "POINT_CHANGE",
        _author = COORD,
        _counter = 1,
        _data = { member = MEMBER },
    },
})
Sync:HandleNewLog(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    log = {
        _eventType = "POINT_CHANGE",
        _author = COORD,
        _counter = 2,
        _data = { member = MEMBER },
    },
})
assertEq(warningCount("not an admin"), 1, "revoked coordinator NEW_LOG warns once")

-- Heartbeats from an explicitly revoked coordinator must not refresh takeover.
reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
Sync.state.helpers = { KINO }
Sync:_RememberRevokedRoute(COORD)
Sync.state.heartbeat.lastHeartbeatAt = 40
Sync.state.heartbeat.lastCoordMessageAt = 40
local originalNow = Sync._Now
Sync._Now = function()
    return 500
end
Sync:OnControlMessage(COORD, Sync.MSG.SES_HEARTBEAT, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 11,
    helpers = {},
    sentAt = 500,
}, "RAID")
assertEq(Sync.state.coordEpoch, 10, "revoked coordinator heartbeat does not advance the epoch")
assertTrue(listHas(Sync.state.helpers, KINO), "revoked coordinator heartbeat does not clear helpers")
assertEq(Sync.state.heartbeat.lastHeartbeatAt, 40, "revoked coordinator heartbeat does not refresh lastHeartbeatAt")
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 40, "revoked coordinator heartbeat does not refresh lastCoordMessageAt")
setAdmins({ COORD, KINO, OWNER })
Sync:HandleSessionHeartbeat(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 11,
    helpers = { KINO },
    sentAt = 500,
})
assertEq(Sync.state.coordEpoch, 11, "reauthorized coordinator heartbeat is accepted")
assertEq(Sync.state.heartbeat.lastHeartbeatAt, 500, "reauthorized coordinator heartbeat refreshes lastHeartbeatAt")
Sync._Now = originalNow

-- Catch-up replies must prove the sender's grant before any merge.
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.helpers = {}
Sync.state.coordinator = KINO
Sync.state._coordinatorCatchUp = KINO
local catchLogs = seedRequest("need-catch-logs", "NEED_LOGS", { KINO }, KINO)
catchLogs.meta.integrityRepair = true
local mergeOpts = nil
local mergeCalls = 0
Sync.MergeLogs = function(_, _, _, opts)
    mergeCalls = mergeCalls + 1
    mergeOpts = opts
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end
local function catchLogsPayload(logs)
    return {
        sessionId = SESSION,
        profileId = PROFILE,
        requestId = "need-catch-logs",
        author = "Author-Realm",
        fromCounter = 1,
        toCounter = 2,
        logs = logs,
    }
end
Sync:HandleAuthLogs(KINO, catchLogsPayload({
    { _author = "Author-Realm", _counter = 1, _eventType = "POINT_CHANGE", _data = { member = MEMBER } },
}))
assertEq(mergeCalls, 0, "catch-up AUTH_LOGS without a grant is not merged")
assertTrue(Sync.state.requests["need-catch-logs"] ~= nil, "unproven catch-up leaves the log request open")
assertEq(warningCount("coordinator authority is not established yet"), 1, "unproven catch-up warns once")
Sync:HandleAuthLogs(KINO, catchLogsPayload({
    { _author = "Author-Realm", _counter = 1, _eventType = "POINT_CHANGE", _data = { member = MEMBER } },
}))
assertEq(warningCount("coordinator authority is not established yet"), 1, "repeat unproven catch-up does not warn again")
Sync:HandleAuthLogs(KINO, catchLogsPayload({
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
    {
        _author = "Author-Realm",
        _counter = 2,
        _eventType = "ADMIN_REMOVED",
        _data = { member = KINO },
    },
}))
assertEq(mergeCalls, 0, "catch-up AUTH_LOGS that ends in removal is not merged")
Sync:HandleAuthLogs(KINO, catchLogsPayload({
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}))
assertEq(mergeCalls, 0, "catch-up AUTH_LOGS does not trust a grant from an unauthorized author")
Sync:HandleAuthLogs(KINO, catchLogsPayload({
    {
        _author = KINO,
        _counter = 2,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}))
assertEq(mergeCalls, 0, "catch-up AUTH_LOGS does not trust a grant the sender wrote")
Sync:HandleAuthLogs(KINO, catchLogsPayload({
    {
        _author = OWNER,
        _counter = 8,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}))
assertEq(mergeCalls, 0, "catch-up AUTH_LOGS ignores a trusted author grant that is not already local")
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 9,
        _eventType = "ADMIN_ADDED",
        _data = { member = MEMBER },
    },
}
Sync:HandleAuthLogs(KINO, catchLogsPayload({
    {
        _author = OWNER,
        _counter = 9,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}))
assertEq(mergeCalls, 0, "catch-up AUTH_LOGS rejects a grant that rewrites a local row")
mergeCalls = 0
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 9,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
local originalRebuild = Sync.RebuildProfile
Sync.RebuildProfile = function()
    return true
end
Sync:HandleAuthLogs(KINO, catchLogsPayload({
    {
        _author = OWNER,
        _counter = 9,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}))
assertEq(mergeCalls, 1, "a local trusted grant does not reject the catch-up reply")
assertTrue(Sync.state.requests["need-catch-logs"] ~= nil, "unapplied gap rows leave the catch-up request open")
local phases = {}
Sync.MergeLogs = function(_, _, logs, opts)
    phases[#phases + 1] = {
        event = logs[1] and logs[1]._eventType or nil,
        replace = opts and opts.allowReplaceExisting,
    }
    if logs[1] and logs[1]._eventType == "ADMIN_ADDED" then
        setAdmins({ OWNER, KINO })
    end
    return true, { inserted = #logs, replaced = 0, mismatchCount = 0 }
end
Sync:HandleAuthLogs(KINO, catchLogsPayload({
    {
        _author = OWNER,
        _counter = 9,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}))
assertEq(phases[1] and phases[1].event, "ADMIN_ADDED", "catch-up merges the stored grant before the requested rows")
assertEq(phases[1] and phases[1].replace, false, "grant merge does not replace existing rows")
assertEq(phases[2] and phases[2].event, "POINT_CHANGE", "requested rows merge after the grant is local")
assertEq(phases[2] and phases[2].replace, true, "canonical coordinator can replace rows after the grant sticks")
Sync.RebuildProfile = originalRebuild
Sync.MergeLogs = function()
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end
setAdmins({ OWNER })
profile._lootLogs = {}
Sync.state._coordinatorCatchUp = KINO
profile.ImportSnapshot = function(_, _, opts)
    mergeOpts = opts
    return false, 0, "stop-before-rebuild"
end
local catchSnap = seedRequest("need-catch-snap", "NEED_PROFILE", { KINO }, KINO)
local function catchSnapPayload(admins, logs)
    return {
        sessionId = SESSION,
        profileId = PROFILE,
        requestId = "need-catch-snap",
        snapshot = {
            meta = { _profileId = PROFILE },
            adminUsers = admins,
            lootLogs = logs,
        },
    }
end
mergeOpts = nil
Sync:HandleProfileSnapshot(KINO, catchSnapPayload({ OWNER }, nil))
assertNil(mergeOpts, "catch-up snapshot without the sender in adminUsers is not imported")
assertTrue(Sync.state.requests["need-catch-snap"] ~= nil, "unproven snapshot leaves the profile request open")
Sync:HandleProfileSnapshot(KINO, catchSnapPayload({ KINO, OWNER }, {
    {
        _eventType = "ADMIN_REMOVED",
        _author = KINO,
        _counter = 1,
        _data = { member = KINO },
    },
}))
assertNil(mergeOpts, "catch-up snapshot whose logs revoke the sender is not imported")
Sync:HandleProfileSnapshot(KINO, catchSnapPayload({ KINO, OWNER }, nil))
assertNil(mergeOpts, "catch-up snapshot with empty history is not imported")
assertTrue(Sync.state.requests["need-catch-snap"] ~= nil, "empty catch-up snapshot leaves the profile request open")
Sync:HandleProfileSnapshot(KINO, catchSnapPayload({ KINO, OWNER }, {
    {
        _eventType = "ADMIN_ADDED",
        _author = KINO,
        _counter = 2,
        _data = { member = KINO },
    },
}))
assertNil(mergeOpts, "catch-up snapshot cannot prove a grant the sender wrote")
Sync:HandleProfileSnapshot(KINO, catchSnapPayload({ KINO, OWNER }, {
    {
        _eventType = "ADMIN_ADDED",
        _author = OWNER,
        _counter = 3,
        _data = { member = KINO },
    },
}))
assertNil(mergeOpts, "catch-up snapshot cannot prove a grant that is not already local")
profile._lootLogs = {
    {
        _eventType = "ADMIN_ADDED",
        _author = OWNER,
        _counter = 3,
        _data = { member = KINO },
    },
}
Sync:HandleProfileSnapshot(KINO, catchSnapPayload({ KINO, OWNER }, {
    {
        _eventType = "ADMIN_ADDED",
        _author = OWNER,
        _counter = 3,
        _data = { member = KINO },
    },
}))
assertEq(mergeOpts and mergeOpts.allowReplaceExisting, false, "catch-up snapshot imports a grant already in local history")
assertTrue(Sync.state.requests["need-catch-snap"] ~= nil, "failed catch-up import leaves the profile request open")
mergeOpts = nil
profile._lootLogs[#profile._lootLogs + 1] = {
    _eventType = "ADMIN_REMOVED",
    _author = OWNER,
    _counter = 4,
    _data = { member = KINO },
}
Sync.state._coordinatorCatchUp = KINO
Sync:HandleProfileSnapshot(KINO, catchSnapPayload({ KINO, OWNER }, {
    {
        _eventType = "ADMIN_ADDED",
        _author = OWNER,
        _counter = 3,
        _data = { member = KINO },
    },
}))
assertNil(mergeOpts, "catch-up snapshot ignores a grant that local history later revoked")
Sync.MergeLogs = function()
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end

-- A gapped rebuild must not relinquish, take over, or drop helper routes.
reset(KINO)
setAdmins({ KINO })
Sync.state.isCoordinator = false
Sync.state.coordinator = COORD
Sync.state.helpers = { OWNER }
local gapReq = seedRequest("need-gap", "NEED_LOGS", { OWNER, COORD }, nil)
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:live_update")
assertEq(Sync.state.isCoordinator, false, "gapped rebuild does not take over coordination")
assertEq(Sync.state.coordinator, COORD, "gapped rebuild keeps the advertised coordinator")
assertTrue(listHas(Sync.state.helpers, OWNER), "gapped rebuild keeps helper routes")
gapReq = Sync.state.requests["need-gap"]
assertTrue(listHas(gapReq.targets, OWNER), "gapped rebuild keeps the helper request target")
assertTrue(listHas(gapReq.targets, COORD), "gapped rebuild keeps the coordinator request target")
Sync:ReconcileSessionAuthorization(PROFILE, "admin-list-complete")
assertEq(Sync.state.isCoordinator, true, "non-rebuild reconcile still lets the remaining admin take over")

reset(COORD)
Sync.state.isCoordinator = true
setAdmins({ KINO, OWNER })
Sync.state.helpers = { KINO }
local announced = false
Sync.state._adminConvergence = {
    pendingCount = 0,
    pendingReq = {},
    expected = {},
    finished = false,
    onComplete = function()
        announced = true
    end,
}
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:live_update")
assertEq(Sync.state.isCoordinator, true, "gapped rebuild does not relinquish the coordinator")
assertEq(announced, false, "gapped rebuild does not finish admin convergence")
assertTrue(type(Sync.state._adminConvergence) == "table", "gapped rebuild keeps convergence state")
assertTrue(listHas(Sync.state.helpers, KINO), "gapped rebuild keeps the helper list")

reset(MEMBER)
setAdmins({ COORD })
Sync.state.helpers = { SUSPENDERS, KINO }
Sync:_RememberRevokedRoute(SUSPENDERS)
local explicitReq = seedRequest("need-explicit", "NEED_LOGS", { SUSPENDERS, KINO, COORD }, SUSPENDERS)
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:live_update")
assertTrue(not listHas(Sync.state.helpers, SUSPENDERS), "explicit revocation drops that helper during rebuild")
assertTrue(listHas(Sync.state.helpers, KINO), "gapped helper stays when only someone else was revoked")
explicitReq = Sync.state.requests["need-explicit"]
assertTrue(not listHas(explicitReq.targets, SUSPENDERS), "explicit revocation drops that request target")
assertTrue(listHas(explicitReq.targets, KINO), "gapped request target stays during rebuild")

-- Losing admin must not finish convergence and announce before relinquish.
reset(COORD)
Sync.state.isCoordinator = true
setAdmins({ KINO, OWNER })
Sync.state.helpers = { KINO }
announced = false
local convReq = seedRequest("admin-conv", "ADMIN_LOG_REQ", { KINO }, nil)
Sync.state._adminConvergence = {
    pendingCount = 1,
    pendingReq = { ["admin-conv"] = true },
    expected = {},
    finished = false,
    onComplete = function()
        announced = true
    end,
}
Sync:ReconcileSessionAuthorization(PROFILE, "coordinator-removed")
assertEq(announced, false, "revocation does not run the convergence completion hook")
assertNil(Sync.state._adminConvergence, "revocation abandons admin convergence")
assertNil(Sync.state.requests["admin-conv"], "revocation fails the admin log request")
assertEq(Sync.state.isCoordinator, false, "revocation stops coordination")
assertEq(sendCount(Sync.MSG.SES_START), 0, "revocation does not broadcast session start")
assertEq(sendCount(Sync.MSG.SES_REANNOUNCE), 0, "revocation does not reannounce")
assertTrue(convReq ~= nil, "admin request object was created")

-- Queued integrity repairs drop a revoked preferred target.
reset(MEMBER)
setAdmins({ COORD, KINO, OWNER })
Sync.state.helpers = { KINO }
Sync.state.repairQueue = {
    order = { "repair-1" },
    items = {
        ["repair-1"] = {
            key = "repair-1",
            profileId = PROFILE,
            author = "Author-Realm",
            fromCounter = 1,
            toCounter = 2,
            mode = "integrity",
            exactAuthor = true,
            preferredTarget = SUSPENDERS,
        },
    },
}
Sync:ReconcileSessionAuthorization(PROFILE, "drop-repair-target")
assertNil(Sync.state.repairQueue.items["repair-1"].preferredTarget, "reconcile clears a revoked repair target")
local dispatchedOk = Sync:_DispatchQueuedRepair(Sync.state.repairQueue.items["repair-1"])
assertEq(dispatchedOk, true, "repair dispatch falls back after the preferred target is cleared")
local dispatched = nil
for _, req in pairs(Sync.state.requests) do
    dispatched = req
end
assertTrue(dispatched ~= nil, "fallback repair request is registered")
assertTrue(not listHas(dispatched.targets, SUSPENDERS), "dispatch does not target the revoked player")
assertEq(dispatched.targets[1], COORD, "dispatch falls back to the coordinator")
reset(COORD)
Sync.state.isCoordinator = true
setAdmins({ COORD, KINO, OWNER })
Sync.state.helpers = { KINO }
Sync.state.repairQueue = {
    order = { "repair-coord" },
    items = {
        ["repair-coord"] = {
            key = "repair-coord",
            profileId = PROFILE,
            author = "Author-Realm",
            fromCounter = 1,
            toCounter = 2,
            mode = "integrity",
            exactAuthor = true,
            preferredTarget = SUSPENDERS,
        },
    },
}
Sync:ReconcileSessionAuthorization(PROFILE, "drop-coordinator-repair-target")
assertNil(Sync.state.repairQueue.items["repair-coord"].preferredTarget, "coordinator reconcile clears a revoked repair target")
local coordDispatch = Sync:_DispatchQueuedRepair(Sync.state.repairQueue.items["repair-coord"])
assertEq(coordDispatch, true, "coordinator repair dispatch falls back to a helper")
local coordReq = nil
for _, req in pairs(Sync.state.requests) do
    coordReq = req
end
assertTrue(coordReq ~= nil, "coordinator fallback repair request is registered")
assertTrue(not listHas(coordReq.targets, SUSPENDERS), "coordinator fallback does not target the revoked player")
assertEq(coordReq.targets[1], KINO, "coordinator fallback targets the remaining helper")
assertEq(coordReq.kind, "LOG_REQ", "coordinator fallback uses an admin log request")
local queuedPreferred = "unset"
Sync.QueueRepairRanges = function(_, _, _, opts)
    queuedPreferred = opts and opts.preferredTarget or nil
    return true
end
local requeueReq = seedRequest("need-requeue", "NEED_LOGS", { SUSPENDERS }, SUSPENDERS)
requeueReq.meta.backgroundRepair = true
requeueReq.meta.integrityRepair = true
requeueReq.meta.exactAuthor = true
requeueReq.meta.preferredTarget = SUSPENDERS
Sync:_FailRequest(requeueReq, "revoked-target")
assertNil(queuedPreferred, "failed repair does not requeue the revoked preferred target")
Sync.QueueRepairRanges = function()
    return false
end

-- Re-granting an admin clears the request tombstone once they are a target again.
reset(MEMBER)
setAdmins({ COORD, KINO, OWNER })
Sync.state.helpers = { KINO }
local regrant = seedRequest("need-regrant", "NEED_LOGS", { SUSPENDERS, COORD }, SUSPENDERS)
Sync:ReconcileSessionAuthorization(PROFILE, "revoke-for-regrant")
regrant = Sync.state.requests["need-regrant"]
assertTrue(Sync:_ResponderMapHas(regrant.revokedResponders, SUSPENDERS), "removed admin is tombstoned")
setAdmins({ COORD, SUSPENDERS, KINO, OWNER })
Sync.state.helpers = { SUSPENDERS, KINO }
Sync:ReconcileSessionAuthorization(PROFILE, "regrant-admin")
regrant = Sync.state.requests["need-regrant"]
assertTrue(listHas(regrant.targets, SUSPENDERS), "re-granted admin is a target again")
assertTrue(not Sync:_ResponderMapHas(regrant.revokedResponders, SUSPENDERS), "re-grant clears the responder tombstone")
assertEq(Sync:_ClassifyPrivilegedResponse(SUSPENDERS, PROFILE, regrant, {
    expectedKinds = { NEED_LOGS = true, LOG_REQ = true, ADMIN_LOG_REQ = true },
}), "accept", "re-granted admin response is accepted")

-- Repaired history updates routes. A live gap does not.
reset(MEMBER)
setAdmins({ COORD, OWNER })
Sync.state.helpers = { KINO }
Sync.state.adminStatuses = {
    [KINO] = { authorMax = { [MEMBER] = 3 } },
}
local repaired = seedRequest("need-repaired", "NEED_LOGS", { KINO, COORD }, nil)
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:auth_logs")
assertTrue(not listHas(Sync.state.helpers, KINO), "auth_logs rebuild drops a helper removed by repaired history")
repaired = Sync.state.requests["need-repaired"]
assertTrue(not listHas(repaired.targets, KINO), "auth_logs rebuild drops that helper from outstanding requests")
assertTrue(type(Sync.state.adminStatuses[KINO]) == "table", "auth_logs rebuild keeps advertiser status")
reset(MEMBER)
setAdmins({ COORD, OWNER })
Sync.state.helpers = { KINO }
seedRequest("need-live-gap", "NEED_LOGS", { KINO, COORD }, nil)
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:live_update")
assertTrue(listHas(Sync.state.helpers, KINO), "live rebuild keeps a helper missing from a gapped admin list")
assertTrue(listHas(Sync.state.requests["need-live-gap"].targets, KINO),
    "live rebuild keeps that helper on the outstanding request")

-- A served log window can carry the sender's latest admin grant.
reset(KINO)
profile._lootLogs = {
    {
        _author = "Other-Realm",
        _counter = 4,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}
local served = {
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}
Sync:_AppendSelfAdminGrantEvidence(served, profile)
assertEq(#served, 2, "served logs include one admin-grant row")
assertEq(served[2]._eventType, "ADMIN_ADDED", "served grant is the latest ADMIN_ADDED for the sender")
assertEq(served[2]._author, "Other-Realm", "served grant keeps the author outside the requested window")
profile._lootLogs[#profile._lootLogs + 1] = {
    _author = "Other-Realm",
    _counter = 5,
    _eventType = "ADMIN_REMOVED",
    _data = { member = KINO },
}
local revokedServe = {}
Sync:_AppendSelfAdminGrantEvidence(revokedServe, profile)
assertEq(#revokedServe, 0, "a later removal does not attach a stale grant")

-- Ordinary repairs keep the requested window. Only catch-up asks for the grant.
reset(KINO)
profile._lootLogs = {
    {
        _author = "Other-Realm",
        _counter = 4,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}
local function lastAuthLogs()
    local found = nil
    for _, sent in ipairs(sends) do
        if sent.msgType == Sync.MSG.AUTH_LOGS then
            found = sent
        end
    end
    return found
end
local function authLogHasGrant(sent)
    local logs = sent and sent.payload and sent.payload.logs or {}
    for _, logTable in ipairs(logs) do
        if logTable._eventType == "ADMIN_ADDED" then
            return true
        end
    end
    return false
end
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "window-only",
    missing = {
        { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
    },
})
local windowOnly = lastAuthLogs()
assertTrue(windowOnly ~= nil, "ordinary NEED_LOGS still serves the requested window")
assertTrue(not authLogHasGrant(windowOnly), "ordinary NEED_LOGS does not attach an out-of-range grant")
sends = {}
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "catch-up-serve",
    needsAdminGrant = true,
    missing = {
        { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
    },
})
local catchUpServe = lastAuthLogs()
assertTrue(authLogHasGrant(catchUpServe), "catch-up NEED_LOGS attaches the sender admin grant")
sends = {}
Sync:HandleLogRequest(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "logreq-window",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
})
assertTrue(not authLogHasGrant(lastAuthLogs()), "ordinary LOG_REQ does not attach an out-of-range grant")
sends = {}
Sync:HandleLogRequest(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "logreq-catch",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
    needsAdminGrant = true,
})
assertTrue(authLogHasGrant(lastAuthLogs()), "catch-up LOG_REQ attaches the sender admin grant")
reset(MEMBER)
setAdmins({ OWNER })
local plainNeed = Sync:_SendNeedLogsReq({
    id = "plain-need",
    meta = {
        sessionId = SESSION,
        profileId = PROFILE,
        author = "Author-Realm",
        fromCounter = 1,
        toCounter = 2,
    },
}, KINO)
assertEq(plainNeed, true, "ordinary NEED_LOGS send succeeds")
assertNil(sends[#sends].payload.needsAdminGrant, "ordinary NEED_LOGS does not ask for an admin grant")
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state._coordinatorCatchUp = KINO
local trustedNeed = Sync:_SendNeedLogsReq({
    id = "trusted-need",
    meta = {
        sessionId = SESSION,
        profileId = PROFILE,
        author = "Author-Realm",
        fromCounter = 1,
        toCounter = 2,
    },
}, OWNER)
assertEq(trustedNeed, true, "missing-grant NEED_LOGS send succeeds")
assertEq(sends[#sends].payload.adminGrantMember, KINO, "missing grant is requested from a trusted admin")
assertNil(sends[#sends].payload.needsAdminGrant, "trusted admin is not asked for their own grant")
local successorNeed = Sync:_SendNeedLogsReq({
    id = "successor-need",
    meta = {
        sessionId = SESSION,
        profileId = PROFILE,
        author = "Author-Realm",
        fromCounter = 1,
        toCounter = 2,
    },
}, KINO)
assertEq(successorNeed, true, "successor NEED_LOGS send succeeds")
assertNil(sends[#sends].payload.needsAdminGrant, "missing grant is not requested from the successor")
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 3,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
local storedNeed = Sync:_SendNeedLogsReq({
    id = "stored-need",
    meta = {
        sessionId = SESSION,
        profileId = PROFILE,
        author = "Author-Realm",
        fromCounter = 1,
        toCounter = 2,
    },
}, KINO)
assertEq(storedNeed, true, "stored-grant NEED_LOGS send succeeds")
assertEq(sends[#sends].payload.needsAdminGrant, true, "stored grant asks the successor to attach that row")
reset(KINO)
setAdmins({ KINO, OWNER })
Sync.state.isCoordinator = false
local plainLog = Sync:_SendLogReq({
    id = "plain-log",
    meta = {
        sessionId = SESSION,
        profileId = PROFILE,
        author = "Author-Realm",
        fromCounter = 1,
        toCounter = 2,
    },
}, COORD)
assertEq(plainLog, true, "ordinary LOG_REQ send succeeds")
assertNil(sends[#sends].payload.needsAdminGrant, "ordinary LOG_REQ does not ask for an admin grant")
Sync.state.coordinator = COORD
Sync.state._coordinatorCatchUp = COORD
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 2,
        _eventType = "ADMIN_ADDED",
        _data = { member = COORD },
    },
}
local catchLog = Sync:_SendLogReq({
    id = "catch-log",
    meta = {
        sessionId = SESSION,
        profileId = PROFILE,
        author = "Author-Realm",
        fromCounter = 1,
        toCounter = 2,
    },
}, COORD)
assertEq(catchLog, true, "catch-up LOG_REQ send succeeds")
assertEq(sends[#sends].payload.needsAdminGrant, true, "stored grant asks the successor to attach that row")

-- A trusted admin who is not a Helper can serve the missed coordinator grant.
reset(OWNER)
setAdmins({ OWNER })
Sync.state.isCoordinator = false
Sync.state.helpers = {}
Sync.state.coordinator = KINO
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 4,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}
sends = {}
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "grant-from-admin",
    adminGrantMember = KINO,
    missing = {
        { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
    },
})
local servedGrant = lastAuthLogs()
assertTrue(servedGrant ~= nil, "trusted admin serves the missed coordinator grant")
local servedMember = nil
for _, logTable in ipairs(servedGrant and servedGrant.payload.logs or {}) do
    if logTable._eventType == "ADMIN_ADDED" then
        servedMember = logTable._data and logTable._data.member or nil
    end
end
assertEq(servedMember, KINO, "served grant names the catch-up coordinator")
assertEq(#(servedGrant.payload.logs or {}), 1, "non-helper grant reply does not include the requested window")
assertEq(servedGrant.payload.author, "Author-Realm", "grant-only reply keeps the requested author")
assertEq(servedGrant.payload.fromCounter, 1, "grant-only reply keeps the requested start")
assertEq(servedGrant.payload.toCounter, 2, "grant-only reply keeps the requested end")
local echoedGrant = servedGrant.payload
local grantSends = sendCount(Sync.MSG.AUTH_LOGS)
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "grant-from-admin-repeat",
    adminGrantMember = KINO,
    missing = {
        { author = "Author-Realm", fromCounter = 1, toCounter = 99 },
    },
})
assertEq(sendCount(Sync.MSG.AUTH_LOGS), grantSends, "repeat grant request does not scan or send again")
Sync.state._adminGrantServe = nil
sends = {}
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "grant-for-stranger",
    adminGrantMember = "Other-Realm",
    missing = {
        { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
    },
})
assertEq(sendCount(Sync.MSG.AUTH_LOGS), 0, "arbitrary adminGrantMember does not serve logs")
Sync.BuildProfileSnapshot = function()
    return { meta = { _profileId = PROFILE }, lootLogs = profile._lootLogs }
end
Sync:HandleNeedProfile(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "grant-profile",
    adminGrantMember = KINO,
})
assertEq(sendCount(Sync.MSG.PROFILE_SNAPSHOT), 0, "non-helper grant request does not export the profile")

reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state._coordinatorCatchUp = KINO
seedRequest("need-trusted-grant", "NEED_LOGS", { OWNER }, OWNER)
local trustedMerges = 0
Sync.MergeLogs = function(_, _, logs)
    trustedMerges = trustedMerges + 1
    return true, { inserted = #logs, replaced = 0, mismatchCount = 0 }
end
Sync.RebuildProfile = function()
    return true
end
Sync:HandleAuthLogs(OWNER, {
    sessionId = echoedGrant.sessionId,
    profileId = echoedGrant.profileId,
    requestId = "need-trusted-grant",
    author = echoedGrant.author,
    fromCounter = echoedGrant.fromCounter,
    toCounter = echoedGrant.toCounter,
    logs = echoedGrant.logs,
})
assertEq(trustedMerges, 1, "trusted admin can insert the coordinator grant the member missed")
assertTrue(Sync.state.requests["need-trusted-grant"] == nil, "trusted grant response completes the request")
local successorReq = seedRequest("need-successor-grant", "NEED_LOGS", { KINO }, KINO)
successorReq.meta.integrityRepair = true
local successorMerges = 0
Sync.MergeLogs = function()
    successorMerges = successorMerges + 1
    return true, { inserted = 1, replaced = 0, mismatchCount = 0 }
end
Sync:HandleAuthLogs(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-successor-grant",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
    logs = {
        {
            _author = OWNER,
            _counter = 4,
            _eventType = "ADMIN_ADDED",
            _data = { member = KINO },
        },
    },
})
assertEq(successorMerges, 0, "successor still cannot supply a grant that is not already stored")
assertTrue(Sync.state.requests["need-successor-grant"] ~= nil, "unproven successor grant leaves the request open")
Sync.MergeLogs = function()
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end

-- A revoked coordinator cannot end the session or persist configuration.
reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync:_RememberRevokedRoute(COORD)
local rcApplied = false
local ilvlApplied = false
profile.ApplyRCLootCouncilIntegrationConfig = function()
    rcApplied = true
    return true
end
profile.GetRCLootCouncilIntegrationConfig = function()
    return nil
end
profile.ApplyRaidCheckItemLevelPolicy = function()
    ilvlApplied = true
    return true
end
Sync:OnControlMessage(COORD, Sync.MSG.SES_END, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 10,
    reason = "revoked",
}, "RAID")
assertEq(Sync.state.active, true, "revoked coordinator cannot end the session")
Sync:OnControlMessage(COORD, Sync.MSG.SAFE_MODE_SET, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 10,
    safeMode = { enabled = true, rev = 1, setBy = COORD, reason = "revoked" },
}, "RAID")
assertEq(Sync:IsSafeModeEnabled(), false, "revoked coordinator cannot enable safe mode")
Sync:OnControlMessage(COORD, Sync.MSG.RC_CONFIG_SET, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 10,
    seq = 1,
    rcLootCouncilIntegration = { recordAwards = true },
}, "RAID")
assertEq(rcApplied, false, "revoked coordinator cannot persist RC config")
Sync:OnControlMessage(COORD, Sync.MSG.RAID_CHECK_ILVL_SET, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 10,
    seq = 1,
    requireMinimumItemLevel = true,
    minimumItemLevel = 600,
}, "RAID")
assertEq(ilvlApplied, false, "revoked coordinator cannot persist item level policy")
setAdmins({ COORD, KINO, OWNER })
Sync:OnControlMessage(COORD, Sync.MSG.SES_END, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 10,
    reason = "reauthorized",
}, "RAID")
assertEq(Sync.state.active, false, "reauthorized coordinator can end the session")

-- Revocation belongs to the current session. A newer session from that player is accepted.
reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
Sync:_RememberRevokedRoute(COORD)
local scopedRebuild = Sync.RebuildProfile
Sync.RebuildProfile = function()
    return true
end
Sync:HandleSessionStart(COORD, {
    sessionId = "session-2",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 11,
    helpers = { KINO },
})
assertEq(Sync.state.sessionId, "session-2", "newer session from a revoked coordinator is accepted")
assertEq(Sync:_RouteWasRevoked(COORD), false, "session change clears the old revocation")
Sync:_RememberRevokedRoute(COORD)
Sync.state.coordEpoch = 11
Sync:HandleSessionStart(COORD, {
    sessionId = "session-2",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 12,
    helpers = { OWNER },
})
assertEq(Sync.state.coordEpoch, 11, "same-session start from a revoked coordinator is ignored")
assertTrue(not listHas(Sync.state.helpers, OWNER), "same-session revoked start does not apply helpers")
Sync.RebuildProfile = scopedRebuild

-- Reload after a successor takeover must not record missing authority as a revocation.
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.isCoordinator = false
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state.coordEpoch = 4
Sync:_PersistSessionState("before-catchup-reload")
Sync.state.active = false
local restoredCatch = Sync:TryRestorePersistedSession("reload-catchup")
assertEq(restoredCatch, true, "member restores a successor session before the grant arrives")
assertEq(Sync.state._coordinatorCatchUp, KINO, "restore keeps the missing successor on catch-up")
assertEq(Sync:_RouteWasRevoked(KINO), false, "missing authority is not an explicit revocation")
Sync:HandleSessionHeartbeat(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 4,
    sentAt = 9,
})
assertEq(Sync.state.coordinator, KINO, "catch-up successor heartbeat is accepted after restore")
assertEq(Sync.state.sessionId, SESSION, "catch-up successor heartbeat stays on the restored session")

reset(MEMBER)
setAdmins({ OWNER })
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_REMOVED",
        _data = { member = KINO },
    },
}
Sync.state.isCoordinator = false
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync:_PersistSessionState("before-revoked-successor-reload")
Sync.state.active = false
local restoredRevoke = Sync:TryRestorePersistedSession("reload-explicit-revoke")
assertEq(restoredRevoke, true, "member restores a session whose coordinator was removed")
assertEq(Sync:_RouteWasRevoked(KINO), true, "restore still revokes a coordinator the local history removed")
assertNil(Sync.state._coordinatorCatchUp, "explicit revocation is not catch-up")
local epochBefore = Sync.state.coordEpoch
Sync:HandleSessionHeartbeat(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = (epochBefore or 10) + 1,
    sentAt = 12,
})
assertEq(Sync.state.coordEpoch, epochBefore, "explicitly revoked successor heartbeat is ignored after restore")

-- A superseded local grant is not catch-up proof, even when the response omits the removal.
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state._coordinatorCatchUp = KINO
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 3,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
    {
        _author = OWNER,
        _counter = 4,
        _eventType = "ADMIN_REMOVED",
        _data = { member = KINO },
    },
}
local superseded = seedRequest("need-superseded", "NEED_LOGS", { KINO }, KINO)
superseded.meta.integrityRepair = true
local supersededMerges = 0
Sync.MergeLogs = function()
    supersededMerges = supersededMerges + 1
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end
Sync:HandleAuthLogs(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-superseded",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
    logs = {
        {
            _author = OWNER,
            _counter = 3,
            _eventType = "ADMIN_ADDED",
            _data = { member = KINO },
        },
    },
})
assertEq(supersededMerges, 0, "catch-up AUTH_LOGS ignores a grant that local history later revoked")
Sync.MergeLogs = function()
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end

-- An extra grant beside the locally proven row is not merged.
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state._coordinatorCatchUp = KINO
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 3,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
local extraGrant = seedRequest("need-extra-grant", "NEED_LOGS", { KINO }, KINO)
extraGrant.meta.integrityRepair = true
local extraMerges = 0
Sync.MergeLogs = function()
    extraMerges = extraMerges + 1
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end
Sync:HandleAuthLogs(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-extra-grant",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
    logs = {
        {
            _author = OWNER,
            _counter = 99,
            _eventType = "ADMIN_ADDED",
            _data = { member = KINO },
        },
        {
            _author = OWNER,
            _counter = 3,
            _eventType = "ADMIN_ADDED",
            _data = { member = KINO },
        },
    },
})
assertEq(extraMerges, 0, "catch-up AUTH_LOGS does not merge a forged grant beside the proven row")
assertTrue(Sync.state.requests["need-extra-grant"] ~= nil, "extra grant leaves the catch-up request open")
Sync.MergeLogs = function()
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end

-- Reusing a local row id does not prove a rewritten ADMIN_ADDED.
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state._coordinatorCatchUp = KINO
profile._lootLogs = {
    {
        _id = "Owner-Realm:4",
        _author = OWNER,
        _counter = 4,
        _timestamp = 10,
        _eventType = "POINT_CHANGE",
        _fingerprint = 111,
        _data = { member = KINO, amount = 1 },
    },
}
local forgedId = seedRequest("need-forged-id", "NEED_LOGS", { KINO }, KINO)
forgedId.meta.integrityRepair = true
local forgedMerges = 0
Sync.MergeLogs = function()
    forgedMerges = forgedMerges + 1
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end
Sync:HandleAuthLogs(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-forged-id",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
    logs = {
        {
            _id = "Owner-Realm:4",
            _author = OWNER,
            _counter = 4,
            _timestamp = 11,
            _eventType = "ADMIN_ADDED",
            _fingerprint = 222,
            _data = { member = KINO },
        },
    },
})
assertEq(forgedMerges, 0, "catch-up AUTH_LOGS rejects an ADMIN_ADDED that reuses a local row id")
assertTrue(Sync.state.requests["need-forged-id"] ~= nil, "rewritten grant id leaves the catch-up request open")
local forgedImported = false
profile.ImportSnapshot = function()
    forgedImported = true
    return true, 1
end
local forgedSnap = seedRequest("need-forged-snap", "NEED_PROFILE", { KINO }, KINO)
Sync:HandleProfileSnapshot(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = forgedSnap.id,
    snapshot = {
        meta = { _profileId = PROFILE },
        adminUsers = { KINO, OWNER },
        lootLogs = {
            {
                _id = "Owner-Realm:4",
                _author = OWNER,
                _counter = 4,
                _timestamp = 11,
                _eventType = "ADMIN_ADDED",
                _fingerprint = 222,
                _data = { member = KINO },
            },
        },
    },
})
assertEq(forgedImported, false, "catch-up snapshot rejects an ADMIN_ADDED that reuses a local row id")
Sync.MergeLogs = function()
    return false, { inserted = 0, replaced = 0, mismatchCount = 0 }
end

-- Session start must not revoke a coordinator whose grant is only missing locally.
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = OWNER
Sync.state.helpers = {}
Sync.state.coordEpoch = 3
profile._lootLogs = {}
Sync.RebuildProfile = function(self, profileId, reason)
    self:ReconcileSessionAuthorization(profileId, "rebuild:" .. reason)
    return true
end
Sync:HandleSessionStart(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 4,
    helpers = {},
})
assertEq(Sync.state._coordinatorCatchUp, KINO, "session start keeps a missing coordinator on catch-up")
assertEq(Sync:_RouteWasRevoked(KINO), false, "session start does not revoke a coordinator local history still grants")
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 2,
        _eventType = "ADMIN_REMOVED",
        _data = { member = KINO },
    },
}
Sync:HandleSessionStart(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 5,
    helpers = {},
})
assertEq(Sync.state._coordinatorCatchUp, nil, "session start clears catch-up when local history revoked the coordinator")
assertEq(Sync:_RouteWasRevoked(KINO), true, "session start revokes a coordinator local history removed")

-- An admin receiver must not take over from a successor whose grant is only missing.
reset(OWNER)
setAdmins({ OWNER })
Sync.state.isCoordinator = false
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state.coordEpoch = 4
profile._lootLogs = {}
Sync:_PersistSessionState("before-admin-catchup-reload")
Sync.state.active = false
local restoredAdminCatch = Sync:TryRestorePersistedSession("reload-admin-catchup")
assertEq(restoredAdminCatch, true, "admin restores a successor session before the grant arrives")
assertEq(Sync.state._coordinatorCatchUp, KINO, "admin restore keeps the missing successor on catch-up")
assertEq(Sync.state.coordinator, KINO, "admin restore does not take over from a catch-up coordinator")
assertEq(Sync.state.isCoordinator, false, "admin restore stays a member while the grant is missing")
assertEq(sendCount(Sync.MSG.COORD_TAKEOVER), 0, "admin restore does not broadcast takeover during catch-up")

local catchUpTakeovers = 0
local originalCatchTakeover = Sync.TakeoverSession
Sync.TakeoverSession = function()
    catchUpTakeovers = catchUpTakeovers + 1
    return true
end
local originalCatchRebuild = Sync.RebuildProfile
Sync.RebuildProfile = function(self, profileId, reason)
    self:ReconcileSessionAuthorization(profileId, "rebuild:" .. reason)
    return true
end
Sync:HandleSessionStart(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 5,
    helpers = {},
})
assertEq(catchUpTakeovers, 0, "admin session start does not take over from a catch-up coordinator")
assertEq(Sync.state.coordinator, KINO, "admin session start keeps the catch-up coordinator")
assertEq(Sync.state._coordinatorCatchUp, KINO, "admin session start keeps catch-up")
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 2,
        _eventType = "ADMIN_REMOVED",
        _data = { member = KINO },
    },
}
Sync:ReconcileSessionAuthorization(PROFILE, "coordinator-removed")
assertEq(catchUpTakeovers, 1, "explicit coordinator removal still lets an eligible admin take over")
Sync.TakeoverSession = originalCatchTakeover
Sync.RebuildProfile = originalCatchRebuild

-- A revoked coordinator cannot leave the session by changing only the profile id.
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = COORD
Sync.state.helpers = { KINO }
Sync.state.coordEpoch = 10
Sync.state.heartbeat.lastHeartbeatAt = 40
Sync.state.heartbeat.lastCoordMessageAt = 40
Sync:_RememberRevokedRoute(COORD)
local otherProfile = "profile-other"
Sync:HandleSessionHeartbeat(COORD, {
    sessionId = SESSION,
    profileId = otherProfile,
    coordinator = COORD,
    coordEpoch = 11,
    sentAt = 50,
})
assertEq(Sync.state.profileId, PROFILE, "revoked heartbeat cannot retarget the session profile")
assertEq(Sync.state.coordEpoch, 10, "revoked same-session profile change does not advance the epoch")
assertEq(Sync:_RouteWasRevoked(COORD), true, "revoked heartbeat keeps the revocation")
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 40, "revoked profile-change heartbeat does not refresh the coordinator timer")
Sync:HandleSessionReannounce(COORD, {
    sessionId = SESSION,
    profileId = otherProfile,
    coordinator = COORD,
    coordEpoch = 11,
    helpers = { OWNER },
})
assertEq(Sync.state.profileId, PROFILE, "revoked reannounce cannot retarget the session profile")
assertTrue(not listHas(Sync.state.helpers, OWNER), "revoked reannounce does not apply helpers")
assertEq(Sync:_RouteWasRevoked(COORD), true, "revoked reannounce keeps the revocation")
Sync:HandleCoordinatorTakeover(COORD, {
    sessionId = SESSION,
    profileId = otherProfile,
    coordinator = COORD,
    coordEpoch = 11,
})
assertEq(Sync.state.profileId, PROFILE, "revoked takeover cannot retarget the session profile")
assertEq(Sync.state.coordinator, COORD, "revoked takeover does not replace the coordinator")
assertEq(Sync:_RouteWasRevoked(COORD), true, "revoked takeover keeps the revocation")
Sync:HandleSessionStart(COORD, {
    sessionId = "session-2",
    profileId = otherProfile,
    coordinator = COORD,
    coordEpoch = 12,
    helpers = { KINO },
})
assertEq(Sync.state.sessionId, "session-2", "a newer session still escapes the old revocation")
assertEq(Sync:_RouteWasRevoked(COORD), false, "a newer session clears the old revocation")

-- An authorized admin who is not a Helper can still be the integrity provider.
reset(COORD)
Sync.state.isCoordinator = true
Sync.state.helpers = { KINO }
setAdmins({ COORD, KINO, OWNER })
assertEq(Sync:_PreferredRepairTargetRoutable(OWNER), true, "authorized non-helper stays a repair target")
assertEq(Sync:_PreferredRepairTargetRoutable(SUSPENDERS), false, "unauthorized preferred provider is not a repair target")
Sync:_RememberRevokedRoute(OWNER)
setAdmins({ COORD, KINO })
assertEq(Sync:_PreferredRepairTargetRoutable(OWNER), false, "revoked preferred provider is not a repair target")
setAdmins({ COORD, KINO, OWNER })
local queued = productionQueueRepairRanges(Sync, PROFILE, {
    {
        author = OWNER,
        fromCounter = 1,
        toCounter = 2,
        mode = "integrity",
    },
}, {
    mode = "integrity",
    preferredTarget = OWNER,
    reason = "peer-mutation",
})
assertEq(queued, true, "integrity repair from an authorized non-helper is queued")
local repairItem = nil
for _, item in pairs(Sync.state.repairQueue.items) do
    if item.author == OWNER then
        repairItem = item
    end
end
assertEq(repairItem and repairItem.preferredTarget, OWNER, "integrity queue keeps the advertising admin")

-- Abandoned convergence timers must not finalize a replacement round.
reset(COORD)
setAdmins({ COORD, KINO, OWNER })
Sync.state.isCoordinator = true
local convergenceFinishes = 0
local originalBroadcast = Sync.BroadcastSessionStart
Sync.BroadcastSessionStart = function()
    convergenceFinishes = convergenceFinishes + 1
end
local timerCount = #timers
originalBeginAdminConvergence(Sync, SESSION, PROFILE, {
    onComplete = function()
        convergenceFinishes = convergenceFinishes + 1
    end,
})
assertTrue(#timers > timerCount, "admin convergence schedules a collection timer")
local firstCollect = timers[#timers]
local firstSyncId = Sync.state._adminConvergence and Sync.state._adminConvergence.adminSyncId
assertTrue(type(firstSyncId) == "string", "admin convergence records an id")
Sync:_AbandonAdminConvergence("lost-admin")
assertEq(firstCollect.cancelled, true, "abandon cancels the collection timer")
assertNil(Sync.state._adminConvergence, "abandon clears convergence state")
originalBeginAdminConvergence(Sync, SESSION, PROFILE, {
    onComplete = function()
        convergenceFinishes = convergenceFinishes + 1
    end,
})
local secondSyncId = Sync.state._adminConvergence and Sync.state._adminConvergence.adminSyncId
assertTrue(secondSyncId ~= firstSyncId, "replacement convergence uses a new id")
firstCollect.fn()
assertEq(Sync.state._adminConvergence.adminSyncId, secondSyncId, "old collection timer leaves the replacement in place")
assertTrue(Sync.state._adminConvergence.finalizeStarted ~= true, "old collection timer does not finalize the replacement")
assertEq(convergenceFinishes, 0, "old collection timer does not announce")

profile.ComputeAuthorMax = function()
    return {}
end
Sync.state.adminStatuses = {
    [KINO] = { hasProfile = true, authorMax = { ["Author-Realm"] = 2 } },
}
local originalMissing = Sync.ComputeMissingLogRequests
local originalRegister = Sync.RegisterRequest
Sync.ComputeMissingLogRequests = function()
    return {
        { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
    }
end
Sync.RegisterRequest = function()
    return true
end
timerCount = #timers
Sync:FinalizeAdminConvergence()
assertTrue(#timers > timerCount, "log sync schedules a timeout")
local logTimer = timers[#timers]
local logSyncId = Sync.state._adminConvergence and Sync.state._adminConvergence.adminSyncId
Sync:_AbandonAdminConvergence("lost-admin-during-logs")
assertEq(logTimer.cancelled, true, "abandon cancels the log sync timer")
originalBeginAdminConvergence(Sync, SESSION, PROFILE, {
    onComplete = function()
        convergenceFinishes = convergenceFinishes + 1
    end,
})
local replacementId = Sync.state._adminConvergence.adminSyncId
logTimer.fn()
assertEq(Sync.state._adminConvergence.adminSyncId, replacementId, "old log timer does not finish the replacement")
assertEq(convergenceFinishes, 0, "old log timer does not run the replacement hook")
Sync.ComputeMissingLogRequests = originalMissing
Sync.RegisterRequest = originalRegister
Sync.BroadcastSessionStart = originalBroadcast

-- A local role demotion updates routes on the writer. Its own NEW_LOG is not required.
loadModule("SpectrumFederation/modules/LootHelper/Members.lua")
SF.LootLogEventTypes = SF.LootLogEventTypes or {}
SF.LootLogEventTypes.ROLE_CHANGE = "ROLE_CHANGE"
SF.LootLog = {
    GetEventDataTemplate = function()
        return {}
    end,
    new = function()
        return {}
    end,
}
reset(KINO)
setAdmins({ COORD, KINO, OWNER })
Sync.state.isCoordinator = false
Sync.state.coordinator = COORD
Sync.state.helpers = { COORD }
seedRequest("need-local-coord", "NEED_LOGS", { COORD }, COORD)
profile.IsCurrentUserAdmin = function()
    return true
end
local roleLogs = 0
profile.AddLootLog = function()
    roleLogs = roleLogs + 1
    return true
end
local originalTakeover = Sync.TakeoverSession
Sync.TakeoverSession = function()
    return true
end
local demotedCoordinator = SF.Member.new(COORD, SF.MemberRoles.ADMIN)
assertEq(demotedCoordinator:SetRole(SF.MemberRoles.MEMBER, { profile = profile }), true,
    "local coordinator demotion commits")
assertEq(roleLogs, 1, "local coordinator demotion records a role log")
assertTrue(not listHas(profile._adminUsers, COORD), "local coordinator demotion updates the canonical admin list")
assertEq(Sync:_RouteWasRevoked(COORD), true, "local coordinator demotion records the revocation")
assertTrue(not listHas(Sync.state.helpers, COORD), "local coordinator demotion drops that helper")
assertTrue(Sync:_ResponderMapHas(Sync.state.requests["need-local-coord"].revokedResponders, COORD),
    "local coordinator demotion tombstones that responder")
assertTrue(listHas(Sync.state.requests["need-local-coord"].targets, COORD),
    "outstanding request stays held until a successor is stored")
local demotedEpoch = Sync.state.coordEpoch
Sync:HandleSessionHeartbeat(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = demotedEpoch + 1,
    sentAt = 20,
})
assertEq(Sync.state.coordEpoch, demotedEpoch, "locally demoted coordinator heartbeat does not advance the epoch")
Sync.TakeoverSession = originalTakeover

reset(COORD)
setAdmins({ COORD, KINO, OWNER })
Sync.state.isCoordinator = true
Sync.state.coordinator = COORD
Sync.state.helpers = { KINO }
seedRequest("need-local-helper", "NEED_LOGS", { KINO, COORD }, KINO)
profile.IsCurrentUserAdmin = function()
    return true
end
profile.AddLootLog = function()
    return true
end
local demotedHelper = SF.Member.new(KINO, SF.MemberRoles.ADMIN)
assertEq(demotedHelper:SetRole(SF.MemberRoles.MEMBER, { profile = profile }), true,
    "local helper demotion commits")
assertTrue(not listHas(profile._adminUsers, KINO), "local helper demotion updates the canonical admin list")
assertTrue(listHas(profile._adminUsers, COORD), "local helper demotion keeps the coordinator admin")
assertTrue(not listHas(Sync.state.helpers, KINO), "local helper demotion drops that helper")
assertTrue(not listHas(Sync.state.requests["need-local-helper"].targets, KINO),
    "local helper demotion drops that request target")
assertEq(Sync.state.coordinator, COORD, "local helper demotion keeps the authorized coordinator")

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
