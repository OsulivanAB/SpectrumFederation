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
assertTrue(listHas(catchUpRoutes, KINO), "unknown successor coordinator remains a catch-up route")
assertEq(Sync:RequestProfileSnapshot("catch-up"), true, "profile request can target the unknown coordinator")
local catchUpReq = nil
for _, req in pairs(Sync.state.requests) do
    if req.kind == "NEED_PROFILE" then
        catchUpReq = req
    end
end
assertTrue(catchUpReq ~= nil, "catch-up profile request is outstanding")
assertEq(Sync:_ClassifyPrivilegedResponse(KINO, PROFILE, catchUpReq, {
    expectedKinds = { NEED_PROFILE = true },
}), "accept", "in-flight catch-up snapshot is accepted")
assertEq(Sync:_ClassifyPrivilegedResponse(KINO, PROFILE, nil, {
    expectedKinds = { NEED_PROFILE = true },
}), "unauthorized", "unsolicited catch-up snapshot is rejected")

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

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
