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

SF._testDebugLogs = {}

function recordDebug(level, message, ...)
    local formatted = tostring(message)
    if select("#", ...) > 0 then
        local ok, result = pcall(string.format, tostring(message), ...)
        formatted = ok and result or tostring(message)
    end
    SF._testDebugLogs[#SF._testDebugLogs + 1] = { level = level, message = formatted }
end

SF.Debug = setmetatable({
    Verbose = function(_, _, message, ...)
        recordDebug("VERBOSE", message, ...)
    end,
    Info = function(_, _, message, ...)
        recordDebug("INFO", message, ...)
    end,
    Warn = function(_, _, message, ...)
        recordDebug("WARN", message, ...)
    end,
    Error = function(_, _, message, ...)
        recordDebug("ERROR", message, ...)
    end,
    Log = function(_, level, _, message, ...)
        recordDebug(level or "INFO", message, ...)
    end,
}, {
    __call = function() end,
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

function debugCount(fragment)
    local n = 0
    for _, entry in ipairs(SF._testDebugLogs) do
        if (entry.level == "WARN" or entry.level == "ERROR")
            and string.find(entry.message, fragment, 1, true)
        then
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
    SF._testDebugLogs = {}
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
    Sync.state._noIntegrityTargetWarnedFor = nil
    Sync.state.pendingProfileSnapshot = nil
    Sync.state._userSyncFailureNoted = nil
    Sync.state._userInitiatedSync = nil
    Sync.state._userSyncGeneration = nil
    Sync.state._userSyncRegisteredCount = nil
    Sync.state._userSyncRegisterRejected = nil
    Sync.state._hadAuthorizedRoute = nil
    Sync.state._diagOnce = nil
    Sync.state.repairQueue = { order = {}, items = {} }
    Sync.state._coordinatorCatchUp = nil
    Sync.state.revokedRoutes = nil
    Sync.state._adminGrantServe = nil
    Sync.state._newLogUnauthorizedWarned = nil
    Sync.state._unprovenCatchUpWarned = nil
    Sync.state._sameProfileRevokeScan = nil
    Sync.state._catchUpGrantScan = nil
    Sync.state._catchUpGrantScanOther = nil
    Sync.state._catchUpProofScan = nil
    Sync.state._failedCatchUp = nil
    Sync.state._failedCatchUpOverflow = nil
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
productionSendJoinStatus = Sync.SendJoinStatus
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
assertEq(debugCount("not an admin of profile"), 1, "stranger AUTH_LOGS is rejected in debug")
assertEq(warningCount("not an admin of profile"), 0, "stranger AUTH_LOGS stays out of chat")
assertTrue(Sync.state.requests["need-9"] ~= nil, "unsolicited response does not complete the request")

Sync:HandleProfileSnapshot(STRANGER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-9",
    snapshot = {},
})
assertEq(debugCount("PROFILE_SNAPSHOT"), 1, "stranger snapshot is rejected in debug")
assertEq(warningCount("PROFILE_SNAPSHOT"), 0, "stranger snapshot stays out of chat")

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
assertTrue(debugCount("not an admin") >= 1, "revoked coordinator NEW_LOG is rejected in debug")
assertEq(warningCount("not an admin"), 0, "revoked coordinator NEW_LOG stays out of chat")

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
assertEq(debugCount("not a trusted sender"), 1, "untrusted bootstrap snapshot is recorded in debug")
assertEq(warningCount("not a trusted sender"), 0, "untrusted bootstrap snapshot stays out of chat")

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
assertEq(debugCount("does not match the request"), 1, "mismatched snapshot is recorded once in debug")
assertEq(warningCount("does not match the request"), 0, "mismatched snapshot stays out of chat")
assertTrue(Sync.state.requests["log-snap"] ~= nil, "mismatched snapshot does not complete the log request")
Sync:HandleProfileSnapshot(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "log-snap",
    snapshot = { meta = { _profileId = PROFILE } },
})
assertEq(debugCount("does not match the request"), 1, "repeat mismatched snapshot does not log again")
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
local mismatchWarnings = debugCount("AUTH_LOGS")
assertEq(mismatchWarnings, 1, "mismatched AUTH_LOGS is recorded once in debug")
assertEq(warningCount("AUTH_LOGS"), 0, "mismatched AUTH_LOGS stays out of chat")
Sync:HandleAuthLogs(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-kind",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
    logs = { { _author = "Author-Realm", _counter = 1 } },
})
assertEq(debugCount("AUTH_LOGS"), mismatchWarnings, "repeat mismatched AUTH_LOGS does not log again")
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

-- A successor takeover during restore must not leave the BiS hold set.
-- Convergence is already running, and only its completion drains the backfill.
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
Sync:_PersistSessionState("before-successor-bis-reload")
Sync.state.active = false
Sync.state.isCoordinator = false
local bisWrites = 0
local originalBisBackfill = Sync.BackfillAutomaticBisOnPromotion
Sync.BackfillAutomaticBisOnPromotion = function()
    bisWrites = bisWrites + 1
    return 1
end
local restoreBegin = Sync.BeginAdminConvergence
Sync.BeginAdminConvergence = originalBeginAdminConvergence
restored = Sync:TryRestorePersistedSession("reload-successor-bis")
assertEq(restored, true, "successor BiS restore still restores the session")
assertEq(Sync.state.isCoordinator, true, "successor BiS restore takes over")
assertEq(Sync.state._bisRestoreBackfillHold, nil, "successor takeover does not restore the BiS hold")
assertTrue(type(Sync.state._adminConvergence) == "table", "successor takeover leaves convergence running")
assertEq(Sync.state._adminConvergence.finished, false, "successor takeover convergence is not already finished")
assertTrue(type(Sync.state._bisBackfillPendingReason) == "string", "successor takeover keeps a BiS backfill pending")
assertEq(bisWrites, 0, "successor takeover does not write BiS outcomes before convergence finishes")
Sync:_FinishAdminConvergence("test-complete")
assertEq(bisWrites, 1, "convergence completion drains the restore BiS backfill")
assertEq(Sync.state._bisRestoreBackfillHold, nil, "BiS hold stays clear after the drain")
Sync.BackfillAutomaticBisOnPromotion = originalBisBackfill
Sync.BeginAdminConvergence = restoreBegin

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

-- Empty routes stay out of chat, keep the work, and resume when a route returns.
;(function()
reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync.state.helpers = {}
Sync.state.isCoordinator = false
assertEq(Sync:RequestProfileSnapshot("no-route"), false, "profile request fails with no route")
assertEq(Sync:RequestProfileSnapshot("no-route-again"), false, "profile request stays failed with no route")
assertEq(warningCount("Cannot request profile"), 0, "empty profile route stays out of chat")
assertEq(debugCount("Cannot request profile: no targets available"), 1, "empty profile route is recorded once in debug")
local missing = {
    { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
}
local savedQueueRepair = Sync.QueueRepairRanges
Sync.QueueRepairRanges = productionQueueRepairRanges
Sync:RequestMissingLogs(missing, "no-route")
Sync:RequestMissingLogs(missing, "no-route-again")
assertEq(warningCount("Cannot request missing logs"), 0, "empty log route stays out of chat")
assertEq(debugCount("Cannot request missing logs: no targets available"), 1, "empty log route is recorded once in debug")
local queuedLogs = Sync.state.repairQueue and Sync.state.repairQueue.order and #Sync.state.repairQueue.order or 0
assertEq(queuedLogs, 1, "missing log work is queued once")
local clock = 1700000000
local originalRouteNow = Sync._Now
Sync._Now = function()
    return clock
end
local attemptsBefore = 0
for _ = 1, 6 do
    clock = clock + 120
    Sync:_ProcessRepairConvergenceTick("test-no-route")
    local entry = Sync.state.repairQueue.items[Sync.state.repairQueue.order[1]]
    attemptsBefore = entry and entry.queueAttempts or attemptsBefore
end
assertEq(#Sync.state.repairQueue.order, 1, "no-route retries do not grow the repair queue")
assertTrue(attemptsBefore >= 1 and attemptsBefore <= 6, "no-route log retries stay bounded")
assertEq(warningCount("Cannot request"), 0, "background retries do not print chat warnings")
setAdmins({ COORD, KINO, OWNER })
Sync:ApplyAdvertisedHelpers({ KINO }, "route-restored")
clock = clock + 1
Sync:_ProcessRepairConvergenceTick("test-route-back")
assertEq(warningCount("Cannot request missing logs"), 0, "restored log route does not chat")
assertEq(warningCount("recovered"), 0, "route recovery does not announce itself in chat")
local logRequest = nil
for _, req in pairs(Sync.state.requests) do
    if req.kind == "NEED_LOGS" or req.kind == "LOG_REQ" then
        logRequest = req
    end
end
assertTrue(logRequest ~= nil, "queued logs are requested after the route returns")
Sync.QueueRepairRanges = savedQueueRepair
Sync._Now = originalRouteNow
end)()

-- A missing profile with nobody to ask is retained and resumes without chat.
;(function()
reset(MEMBER)
Sync.state.coordinator = MEMBER
Sync.state.helpers = {}
Sync.state.isCoordinator = false
SF.lootHelperDB.profiles = {}
assertEq(Sync:RequestProfileSnapshot("missing-profile"), false, "missing profile has no route when the only name is self")
assertEq(warningCount("Cannot request profile"), 0, "missing profile route stays out of chat")
assertEq(debugCount("Cannot request profile: no targets available"), 1, "missing profile route is recorded in debug")
assertTrue(type(Sync.state.pendingProfileSnapshot) == "table", "missing profile work is retained")
local clock = 1700000000
local originalProfileNow = Sync._Now
Sync._Now = function()
    return clock
end
for _ = 1, 4 do
    clock = clock + 120
    Sync:_ProcessRepairConvergenceTick("test-missing-profile")
end
assertTrue(type(Sync.state.pendingProfileSnapshot) == "table", "missing profile stays pending with no route")
assertTrue((Sync.state.pendingProfileSnapshot.queueAttempts or 0) <= 4, "missing profile retries stay bounded")
assertEq(warningCount("Cannot request profile"), 0, "missing profile retries stay out of chat")
Sync.state.coordinator = COORD
clock = clock + 1
Sync:_ExpediteNoRouteSynchronization("profile-route")
Sync:_ProcessRepairConvergenceTick("profile-route")
assertTrue(Sync.state.pendingProfileSnapshot == nil, "profile recovery clears after a route returns")
local profileRequest = nil
for _, req in pairs(Sync.state.requests) do
    if req.kind == "NEED_PROFILE" then
        profileRequest = req
    end
end
assertTrue(profileRequest ~= nil, "missing profile is requested when a route returns")
assertEq(warningCount("Cannot request profile"), 0, "profile recovery does not chat")
Sync._Now = originalProfileNow
end)()

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
assertEq(debugCount("not an admin"), 1, "revoked coordinator NEW_LOG is recorded once in debug")
assertEq(warningCount("not an admin"), 0, "revoked coordinator NEW_LOG stays out of chat")

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
assertEq(debugCount("coordinator authority is not established yet"), 1, "unproven catch-up is recorded once in debug")
assertEq(warningCount("coordinator authority is not established yet"), 0, "unproven catch-up stays out of chat")
Sync:HandleAuthLogs(KINO, catchLogsPayload({
    { _author = "Author-Realm", _counter = 1, _eventType = "POINT_CHANGE", _data = { member = MEMBER } },
}))
assertEq(debugCount("coordinator authority is not established yet"), 1, "repeat unproven catch-up does not log again")
local replacementCatch = seedRequest("need-catch-logs-2", "NEED_LOGS", { KINO }, KINO)
replacementCatch.meta.integrityRepair = true
Sync:HandleAuthLogs(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-catch-logs-2",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
    logs = {
        { _author = "Author-Realm", _counter = 1, _eventType = "POINT_CHANGE", _data = { member = MEMBER } },
    },
})
assertEq(debugCount("coordinator authority is not established yet"), 1, "replacement unproven catch-up request does not log again")
setAdmins({ KINO, OWNER })
assertEq(Sync:_CoordinatorNeedsCatchUp(KINO), false, "authorization clears catch-up for the warned sender")
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state._coordinatorCatchUp = KINO
local warnedAgain = seedRequest("need-catch-logs-3", "NEED_LOGS", { KINO }, KINO)
warnedAgain.meta.integrityRepair = true
Sync:HandleAuthLogs(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-catch-logs-3",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 2,
    logs = {
        { _author = "Author-Realm", _counter = 1, _eventType = "POINT_CHANGE", _data = { member = MEMBER } },
    },
})
assertEq(debugCount("coordinator authority is not established yet"), 2, "unproven catch-up is recorded again after authorization changes")
assertEq(warningCount("coordinator authority is not established yet"), 0, "unproven catch-up stays out of chat after authorization changes")
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
assertTrue(listHas(dispatched.targets, COORD), "dispatch keeps the authorized coordinator")
assertTrue(listHas(dispatched.targets, KINO), "dispatch keeps the authorized helper")
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
reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync.state.helpers = { KINO }
Sync.state.coordinator = COORD
Sync:_RememberRevokedRoute(COORD)
local revokedCoordOk = Sync:RequestIntegrityRepairRanges(PROFILE, {
    { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
}, "revoked-coordinator-fallback", COORD)
assertEq(revokedCoordOk, true, "revoked coordinator integrity repair uses an authorized route")
local revokedCoordReq = nil
for _, req in pairs(Sync.state.requests) do
    revokedCoordReq = req
end
assertTrue(revokedCoordReq ~= nil, "revoked coordinator integrity repair is registered")
assertTrue(not listHas(revokedCoordReq.targets, COORD), "revoked coordinator is not the integrity fallback")
assertEq(revokedCoordReq.targets[1], KINO, "revoked coordinator integrity repair asks the helper")
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.helpers = {}
Sync.state.coordinator = KINO
Sync.state._coordinatorCatchUp = KINO
assertEq(Sync:_PreferredRepairTargetRoutable(KINO), false, "unproven catch-up coordinator is not an integrity target")
reset(MEMBER)
setAdmins({ OWNER })
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
Sync.state.coordinator = KINO
Sync.state._coordinatorCatchUp = KINO
Sync.state.helpers = {}
local grantStateCalls = 0
local originalGrantState = Sync._LogAdminGrantState
Sync._LogAdminGrantState = function(self, logTable, who)
    grantStateCalls = grantStateCalls + 1
    return originalGrantState(self, logTable, who)
end
assertEq(Sync:_LocalCatchUpGrantStored(KINO), true, "stored catch-up grant is found")
local grantStateAfterFirst = grantStateCalls
for _ = 1, 4 do
    assertEq(Sync:_LocalCatchUpGrantStored(KINO), true, "repeat catch-up grant check stays stored")
end
assertEq(grantStateCalls, grantStateAfterFirst, "repeat catch-up grant checks do not rescan history")
table.insert(profile._lootLogs, {
    _author = OWNER,
    _counter = 2,
    _eventType = "ADMIN_REMOVED",
    _data = { member = KINO },
})
assertEq(Sync:_LocalCatchUpGrantStored(KINO), false, "a later removal clears the cached catch-up grant")
assertTrue(grantStateCalls > grantStateAfterFirst, "a history change scans the catch-up grant again")
Sync._LogAdminGrantState = originalGrantState
local catchUpRepairOk = Sync:RequestIntegrityRepairRanges(PROFILE, {
    { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
}, "catch-up-integrity", KINO)
assertEq(catchUpRepairOk, true, "missing grant integrity repair is requested from a trusted admin")
local catchUpRepair = nil
for _, req in pairs(Sync.state.requests) do
    catchUpRepair = req
end
assertTrue(catchUpRepair ~= nil, "missing grant integrity repair is registered")
assertEq(catchUpRepair.targets[1], OWNER, "missing grant integrity repair asks a trusted admin")
assertTrue(not listHas(catchUpRepair.targets, KINO), "missing grant integrity repair does not ask the successor")
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
Sync.state.coordinator = KINO
Sync.state.isCoordinator = true
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

reset(OWNER)
setAdmins({ OWNER })
Sync.state.isCoordinator = false
Sync.state.helpers = {}
Sync.state.coordinator = KINO
profile._lootLogs = {
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}
sends = {}
local grantScans = 0
local originalAppendGrant = Sync._AppendAdminGrantEvidence
Sync._AppendAdminGrantEvidence = function(self, out, grantProfile, member)
    grantScans = grantScans + 1
    return originalAppendGrant(self, out, grantProfile, member)
end
local grantNow = 1000
local originalGrantNow = Sync._Now
Sync._Now = function()
    return grantNow
end
local function requestMissingGrant(requestId)
    Sync:HandleNeedLogs(MEMBER, {
        sessionId = SESSION,
        profileId = PROFILE,
        requestId = requestId,
        adminGrantMember = KINO,
        missing = {
            { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
        },
    })
end
for i = 1, 4 do
    requestMissingGrant("grant-missing-" .. tostring(i))
end
assertEq(sendCount(Sync.MSG.AUTH_LOGS), 0, "missing grant does not consume a grant reply")
assertEq(grantScans, 1, "repeat missing-grant requests do not rescan inside the timeout")
local missRecord = Sync.state._adminGrantServe and Sync.state._adminGrantServe[MEMBER]
assertEq(missRecord and missRecord.count or 0, 0, "missing grant does not consume the sent-reply cap")
for i = 1, 6 do
    grantNow = grantNow + 5
    requestMissingGrant("grant-missing-later-" .. tostring(i))
end
assertEq(sendCount(Sync.MSG.AUTH_LOGS), 0, "later missing-grant scans still send nothing")
missRecord = Sync.state._adminGrantServe and Sync.state._adminGrantServe[MEMBER]
assertEq(missRecord and missRecord.count or 0, 0, "repeated misses stay off the sent-reply cap")
grantNow = grantNow + 5
profile._lootLogs[#profile._lootLogs + 1] = {
    _author = OWNER,
    _counter = 4,
    _eventType = "ADMIN_ADDED",
    _data = { member = KINO },
}
requestMissingGrant("grant-arrived")
assertEq(sendCount(Sync.MSG.AUTH_LOGS), 1, "grant reply is sent after the row arrives")
Sync._Now = originalGrantNow
Sync._AppendAdminGrantEvidence = originalAppendGrant

-- A bulk helper serves ranges without walking history for an arbitrary grant
-- name. A correlated coordinator grant is scanned once for every range, and a
-- repeat inside the request timeout does not scan again.
;(function()
reset(KINO)
setAdmins({ KINO, OWNER, COORD })
Sync.state.isCoordinator = false
Sync.state.helpers = { KINO }
Sync.state.coordinator = COORD
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 4,
        _eventType = "ADMIN_ADDED",
        _data = { member = COORD },
    },
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}
local bulkScans = 0
local originalBulkAppend = Sync._AppendAdminGrantEvidence
Sync._AppendAdminGrantEvidence = function(self, out, grantProfile, member)
    bulkScans = bulkScans + 1
    return originalBulkAppend(self, out, grantProfile, member)
end
local function flushSyncTimers()
    local pending = {}
    for i = 1, #timers do
        pending[i] = timers[i]
        timers[i] = nil
    end
    for _, handle in ipairs(pending) do
        if handle and not handle.cancelled and type(handle.fn) == "function" then
            handle.fn()
        end
    end
end
local missingRanges = {}
for i = 1, 8 do
    missingRanges[i] = { author = "Author-Realm", fromCounter = i, toCounter = i }
end
local function countGrantPackets()
    local n = 0
    for _, sent in ipairs(sends) do
        if sent.msgType == Sync.MSG.AUTH_LOGS and authLogHasGrant(sent) then
            n = n + 1
        end
    end
    return n
end
sends = {}
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "bulk-stranger-grant",
    adminGrantMember = "Other-Realm",
    missing = missingRanges,
})
flushSyncTimers()
assertEq(bulkScans, 0, "arbitrary adminGrantMember does not scan history on a bulk serve")
assertEq(sendCount(Sync.MSG.AUTH_LOGS), 8, "bulk ranges are still served without a grant scan")
assertEq(countGrantPackets(), 0, "arbitrary adminGrantMember is not attached to bulk replies")
sends = {}
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "bulk-helper-self-flag",
    needsAdminGrant = true,
    missing = {
        { author = "Author-Realm", fromCounter = 1, toCounter = 1 },
    },
})
assertEq(bulkScans, 0, "needsAdminGrant does not scan when this client is not the coordinator")
sends = {}
bulkScans = 0
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "bulk-coordinator-grant",
    adminGrantMember = COORD,
    missing = missingRanges,
})
flushSyncTimers()
assertEq(bulkScans, 1, "a coordinator grant on eight ranges scans history once")
assertEq(sendCount(Sync.MSG.AUTH_LOGS), 8, "each requested bulk range is still served")
assertEq(countGrantPackets(), 8, "each bulk range reply carries the one scanned grant")
sends = {}
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "bulk-coordinator-grant-repeat",
    adminGrantMember = COORD,
    missing = missingRanges,
})
flushSyncTimers()
assertEq(bulkScans, 1, "a repeat bulk grant request does not scan again inside the timeout")
assertEq(countGrantPackets(), 0, "a repeat inside the timeout does not attach the grant again")
sends = {}
Sync:HandleLogRequest(OWNER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "logreq-stranger-grant",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 1,
    adminGrantMember = "Other-Realm",
})
assertEq(bulkScans, 1, "LOG_REQ with an arbitrary adminGrantMember does not scan history")
assertTrue(not authLogHasGrant(lastAuthLogs()), "LOG_REQ does not attach an arbitrary grant")
reset(COORD)
setAdmins({ COORD, OWNER })
Sync.state.isCoordinator = true
Sync.state.coordinator = COORD
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 4,
        _eventType = "ADMIN_ADDED",
        _data = { member = COORD },
    },
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}
bulkScans = 0
sends = {}
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "bulk-self-grant",
    needsAdminGrant = true,
    missing = missingRanges,
})
flushSyncTimers()
assertEq(bulkScans, 1, "coordinator needsAdminGrant scans the stored self grant once for eight ranges")
assertEq(countGrantPackets(), 8, "coordinator needsAdminGrant is attached to each range reply")
sends = {}
Sync:HandleNeedLogs(MEMBER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "bulk-self-grant-repeat",
    needsAdminGrant = true,
    missing = {
        { author = "Author-Realm", fromCounter = 1, toCounter = 1 },
    },
})
assertEq(bulkScans, 1, "a repeat coordinator needsAdminGrant does not scan again inside the timeout")
Sync:HandleLogRequest(OWNER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "logreq-self-grant",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 1,
    needsAdminGrant = true,
})
assertEq(bulkScans, 2, "LOG_REQ needsAdminGrant scans once for a different admin sender")
assertTrue(authLogHasGrant(lastAuthLogs()), "coordinator LOG_REQ needsAdminGrant attaches the stored self grant")
Sync:HandleLogRequest(OWNER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "logreq-self-grant-repeat",
    author = "Author-Realm",
    fromCounter = 1,
    toCounter = 1,
    needsAdminGrant = true,
})
assertEq(bulkScans, 2, "a repeat LOG_REQ needsAdminGrant does not scan again inside the timeout")
Sync._AppendAdminGrantEvidence = originalBulkAppend
end)()

reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state._coordinatorCatchUp = KINO
seedRequest("need-trusted-grant", "NEED_LOGS", { OWNER }, OWNER)
local trustedMerges = 0
local trustedRebuilds = 0
Sync.MergeLogs = function(_, _, logs)
    trustedMerges = trustedMerges + 1
    return true, { inserted = #logs, replaced = 0, mismatchCount = 0 }
end
Sync.RebuildProfile = function()
    trustedRebuilds = trustedRebuilds + 1
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
assertEq(trustedRebuilds, 1, "trusted grant rebuilds the profile once")
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
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = COORD
Sync.state.helpers = { KINO }
Sync.state.coordEpoch = 10
Sync.state.heartbeat.lastHeartbeatAt = 40
Sync.state.heartbeat.lastCoordMessageAt = 40
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_REMOVED",
        _data = { member = COORD },
    },
}
Sync:_RememberRevokedRoute(COORD)
Sync:HandleSessionHeartbeat(COORD, {
    sessionId = "session-same-profile",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 12,
    sentAt = 80,
})
assertEq(Sync.state.sessionId, SESSION, "same-profile heartbeat does not adopt a locally revoked coordinator")
assertEq(Sync.state.coordEpoch, 10, "same-profile revoked heartbeat does not advance the epoch")
assertEq(Sync:_RouteWasRevoked(COORD), true, "same-profile revoked heartbeat keeps the revocation")
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 40, "same-profile revoked heartbeat does not refresh the coordinator timer")
Sync:HandleSessionReannounce(COORD, {
    sessionId = "session-same-profile",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 12,
    helpers = { OWNER },
})
assertEq(Sync.state.sessionId, SESSION, "same-profile reannounce does not adopt a locally revoked coordinator")
assertTrue(not listHas(Sync.state.helpers, OWNER), "same-profile revoked reannounce does not apply helpers")
Sync:HandleCoordinatorTakeover(COORD, {
    sessionId = "session-same-profile",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 12,
})
assertEq(Sync.state.sessionId, SESSION, "same-profile takeover does not adopt a locally revoked coordinator")
assertEq(Sync.state.coordinator, COORD, "same-profile revoked takeover keeps the coordinator")

-- A fresh session id must not reset a same-profile removal before reconcile.
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = COORD
Sync.state.helpers = { KINO }
Sync.state.coordEpoch = 10
Sync.state.heartbeat.lastHeartbeatAt = 40
Sync.state.heartbeat.lastCoordMessageAt = 40
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_REMOVED",
        _data = { member = COORD },
    },
}
Sync:_RememberRevokedRoute(COORD)
local startRebuilds = 0
local originalStartRebuild = Sync.RebuildProfile
Sync.RebuildProfile = function()
    startRebuilds = startRebuilds + 1
    return true
end
local startRcApplied = false
local originalStartRc = Sync._ApplyAdvertisedRCConfig
Sync._ApplyAdvertisedRCConfig = function()
    startRcApplied = true
end
local startSafeApplied = false
local originalStartSafe = Sync._ApplySessionSafeModeFromPayload
Sync._ApplySessionSafeModeFromPayload = function()
    startSafeApplied = true
end
local startScans = 0
local originalStartHistory = Sync._LocalHistoryRevokesAdmin
Sync._LocalHistoryRevokesAdmin = function(self, name)
    startScans = startScans + 1
    return originalStartHistory(self, name)
end
local startNow = 12000
local originalStartNow = Sync._Now
Sync._Now = function()
    return startNow
end
Sync:HandleSessionStart(COORD, {
    sessionId = "session-restart",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 12,
    helpers = { OWNER },
    safeMode = { enabled = true, rev = 1, setBy = COORD, reason = "revoked" },
    rcLootCouncilIntegration = { recordAwards = true },
})
assertEq(Sync.state.sessionId, SESSION, "same-profile session start does not adopt a locally revoked coordinator")
assertEq(Sync.state.coordEpoch, 10, "same-profile revoked session start does not advance the epoch")
assertEq(Sync:_RouteWasRevoked(COORD), true, "same-profile revoked session start keeps the revocation")
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 40, "same-profile revoked session start does not refresh the coordinator timer")
assertTrue(not listHas(Sync.state.helpers, OWNER), "same-profile revoked session start does not apply helpers")
assertEq(startRebuilds, 0, "rejected session start does not rebuild the profile")
assertEq(startRcApplied, false, "rejected session start does not persist RC config")
assertEq(startSafeApplied, false, "rejected session start does not apply safe mode")
assertEq(startScans, 1, "the first rejected session start scans history once")
Sync:HandleSessionStart(COORD, {
    sessionId = "session-restart-2",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 13,
    helpers = { OWNER },
})
assertEq(startScans, 1, "repeat rejected session starts do not rescan history inside the timeout")
assertEq(startRebuilds, 0, "repeat rejected session starts do not rebuild the profile")
assertEq(Sync.state.sessionId, SESSION, "a second new session id stays rejected")
Sync:HandleSessionStart(COORD, {
    sessionId = "session-restart-old",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 1,
})
assertEq(startScans, 1, "an older session start does not scan revocation history")
Sync.RebuildProfile = originalStartRebuild
Sync._ApplyAdvertisedRCConfig = originalStartRc
Sync._ApplySessionSafeModeFromPayload = originalStartSafe
Sync._LocalHistoryRevokesAdmin = originalStartHistory
Sync._Now = originalStartNow

reset(MEMBER)
setAdmins({ OWNER, KINO })
profile._owner = OWNER
profile.GetOwnerId = function()
    return OWNER
end
profile._lootLogs = {
    {
        _author = KINO,
        _counter = 4,
        _eventType = "ROLE_CHANGE",
        _data = { member = OWNER, newRole = "MEMBER" },
    },
}
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
Sync.RebuildProfile = function()
    return true
end
Sync:HandleSessionStart(OWNER, {
    sessionId = "session-owner-start",
    profileId = PROFILE,
    coordinator = OWNER,
    coordEpoch = 12,
    helpers = { KINO },
})
assertEq(Sync.state.sessionId, "session-owner-start",
    "still-authorized owner session start adopts the new session")
assertEq(Sync.state.coordEpoch, 12, "still-authorized owner session start advances the epoch")
assertEq(Sync.state.coordinator, OWNER, "still-authorized owner session start keeps that coordinator")
Sync.RebuildProfile = originalStartRebuild
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_REMOVED",
        _data = { member = COORD },
    },
}
local historyScans = 0
local originalHistoryRevoke = Sync._LocalHistoryRevokesAdmin
Sync._LocalHistoryRevokesAdmin = function(self, name)
    historyScans = historyScans + 1
    return originalHistoryRevoke(self, name)
end
local historyNow = 8000
local originalHistoryNow = Sync._Now
Sync._Now = function()
    return historyNow
end
for i = 1, 4 do
    Sync:HandleSessionHeartbeat(COORD, {
        sessionId = "session-scan-" .. tostring(i),
        profileId = PROFILE,
        coordinator = COORD,
        coordEpoch = 12 + i,
        sentAt = 90 + i,
    })
end
assertEq(historyScans, 1, "repeat new-session heartbeats do not rescan history inside the timeout")
assertEq(Sync.state.sessionId, SESSION, "cached revocation still rejects the new session")
Sync:HandleSessionHeartbeat(COORD, {
    sessionId = "session-old-epoch",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 1,
    sentAt = 1,
})
assertEq(historyScans, 1, "an older epoch does not scan revocation history")
historyNow = historyNow + 5
Sync:HandleSessionHeartbeat(COORD, {
    sessionId = "session-scan-later",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 20,
    sentAt = 200,
})
assertEq(historyScans, 2, "revocation history is scanned again after the timeout")
Sync._LocalHistoryRevokesAdmin = originalHistoryRevoke
Sync._Now = originalHistoryNow

-- The profile owner stays a canonical admin after a role change to member.
-- That log is still a historical revoke, and it must not hide a newer session.
reset(MEMBER)
setAdmins({ OWNER, KINO })
profile._owner = OWNER
profile.GetOwnerId = function()
    return OWNER
end
profile._lootLogs = {
    {
        _author = KINO,
        _counter = 4,
        _eventType = "ROLE_CHANGE",
        _data = { member = OWNER, newRole = "MEMBER" },
    },
}
assertEq(Sync:_LocalHistoryRevokesAdmin(OWNER), true,
    "owner role change to member is still a historical revoke")
assertEq(Sync:IsSenderAuthorized(PROFILE, OWNER), true,
    "owner remains a canonical admin after that role change")
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
Sync.state.heartbeat.lastHeartbeatAt = 40
Sync.state.heartbeat.lastCoordMessageAt = 40
Sync:HandleSessionHeartbeat(OWNER, {
    sessionId = "session-owner-still-admin",
    profileId = PROFILE,
    coordinator = OWNER,
    coordEpoch = 12,
    sentAt = 80,
})
assertEq(Sync.state.sessionId, "session-owner-still-admin",
    "still-authorized owner heartbeat adopts the new session")
assertEq(Sync.state.coordEpoch, 12, "still-authorized owner heartbeat advances the epoch")
assertEq(Sync.state.coordinator, OWNER, "still-authorized owner heartbeat keeps that coordinator")
reset(MEMBER)
setAdmins({ OWNER, KINO })
profile._owner = OWNER
profile._lootLogs = {
    {
        _author = KINO,
        _counter = 4,
        _eventType = "ROLE_CHANGE",
        _data = { member = OWNER, newRole = "MEMBER" },
    },
}
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
Sync:HandleSessionReannounce(OWNER, {
    sessionId = "session-owner-reannounce",
    profileId = PROFILE,
    coordinator = OWNER,
    coordEpoch = 12,
    helpers = { KINO },
})
assertEq(Sync.state.sessionId, "session-owner-reannounce",
    "still-authorized owner reannounce adopts the new session")
assertTrue(listHas(Sync.state.helpers, KINO), "still-authorized owner reannounce applies helpers")
reset(MEMBER)
setAdmins({ OWNER, KINO })
profile._owner = OWNER
profile._lootLogs = {
    {
        _author = KINO,
        _counter = 4,
        _eventType = "ROLE_CHANGE",
        _data = { member = OWNER, newRole = "MEMBER" },
    },
}
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
Sync:HandleCoordinatorTakeover(OWNER, {
    sessionId = "session-owner-takeover",
    profileId = PROFILE,
    coordinator = OWNER,
    coordEpoch = 12,
})
assertEq(Sync.state.sessionId, "session-owner-takeover",
    "still-authorized owner takeover adopts the new session")
assertEq(Sync.state.coordinator, OWNER, "still-authorized owner takeover replaces the coordinator")

-- A cached historical revoke must not outlive a re-grant inside the scan timeout.
reset(MEMBER)
setAdmins({ KINO })
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_REMOVED",
        _data = { member = COORD },
    },
}
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
local regrantNow = 9000
local originalRegrantNow = Sync._Now
Sync._Now = function()
    return regrantNow
end
Sync:HandleSessionHeartbeat(COORD, {
    sessionId = "session-cached-revoke",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 12,
    sentAt = 90,
})
assertEq(Sync.state.sessionId, SESSION, "historical removal still rejects a new session")
assertEq(Sync.state._sameProfileRevokeScan and Sync.state._sameProfileRevokeScan.revoked, true,
    "revocation scan is cached")
setAdmins({ KINO, COORD })
Sync:HandleSessionHeartbeat(COORD, {
    sessionId = "session-regranted",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 13,
    sentAt = 91,
})
assertEq(Sync.state.sessionId, "session-regranted",
    "current admin status adopts a new session inside the scan cooldown")
assertEq(Sync.state.coordEpoch, 13, "regranted coordinator heartbeat advances the epoch")
Sync._Now = originalRegrantNow

-- A negative same-profile scan must not survive a later removal.
reset(MEMBER)
setAdmins({ OWNER })
profile._lootLogs = {}
Sync.state.coordinator = COORD
Sync.state.coordEpoch = 10
local negativeNow = 11000
local originalNegativeNow = Sync._Now
Sync._Now = function()
    return negativeNow
end
Sync:HandleCoordinatorTakeover(COORD, {
    sessionId = "session-negative-cache",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 12,
})
assertEq(Sync.state.sessionId, "session-negative-cache", "history that does not revoke still adopts the new session")
assertEq(Sync.state._sameProfileRevokeScan and Sync.state._sameProfileRevokeScan.revoked, false,
    "a negative revocation scan is cached")
table.insert(profile._lootLogs, {
    _author = OWNER,
    _counter = 1,
    _eventType = "ADMIN_REMOVED",
    _data = { member = COORD },
})
Sync:HandleCoordinatorTakeover(COORD, {
    sessionId = "session-after-removal",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 13,
})
assertEq(Sync.state.sessionId, "session-negative-cache",
    "a log removal invalidates the negative scan and keeps the old session")
assertEq(Sync.state._sameProfileRevokeScan and Sync.state._sameProfileRevokeScan.revoked, true,
    "the removal is cached as revoked")
Sync.state._sameProfileRevokeScan.revoked = false
Sync:_RememberRevokedRoute(COORD)
assertEq(Sync.state._sameProfileRevokeScan, nil, "an explicit revocation drops the negative scan")
Sync:HandleCoordinatorTakeover(COORD, {
    sessionId = "session-after-remember",
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 14,
})
assertEq(Sync.state.sessionId, "session-negative-cache",
    "the remembered removal still rejects the next new session")
assertEq(Sync:_RouteWasRevoked(COORD), true, "rejecting that session keeps the revocation")
Sync._Now = originalNegativeNow

-- An authorized admin who is not a Helper can still be the integrity provider.
reset(COORD)
Sync.state.isCoordinator = true
Sync.state.helpers = { KINO }
setAdmins({ COORD, KINO, OWNER })
assertEq(Sync:_PreferredRepairTargetRoutable(OWNER), true, "authorized non-helper stays a repair target")
Sync.state.peers[OWNER].inGroup = false
assertEq(Sync:_PreferredRepairTargetRoutable(OWNER), false, "out-of-group admin is not an integrity target")
local outsideOk = Sync:RequestIntegrityRepairRanges(PROFILE, {
    { author = "Author-Realm", fromCounter = 1, toCounter = 2 },
}, "outside-admin", OWNER)
assertEq(outsideOk, true, "out-of-group preferred admin falls back to an in-group route")
local outsideReq = nil
for _, req in pairs(Sync.state.requests) do
    if req.meta and req.meta.integrityRepair then
        outsideReq = req
    end
end
assertTrue(outsideReq ~= nil, "out-of-group fallback repair is registered")
assertTrue(not listHas(outsideReq.targets, OWNER), "out-of-group admin is not the repair target")
assertTrue(listHas(outsideReq.targets, KINO), "out-of-group fallback asks the in-group helper")
Sync.state.peers[OWNER].inGroup = true
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

-- A same-second grant that sorts after the demotion remains the last effect.
reset(KINO)
setAdmins({ COORD, KINO, OWNER })
profile._owner = OWNER
profile.GetOwnerId = function()
    return OWNER
end
profile.IsCurrentUserAdmin = function()
    return true
end
profile._lootLogs = {
    {
        _timestamp = 50,
        _author = "Zulu-Realm",
        _counter = 2,
        _id = "grant-after",
        _eventType = "ADMIN_ADDED",
        _data = { member = COORD },
    },
}
SF.LootLogEventTypes.ADMIN_ADDED = "ADMIN_ADDED"
SF.LootLog.new = function()
    return {
        _timestamp = 50,
        _author = "Alpha-Realm",
        _counter = 1,
        _id = "local-demote",
        _eventType = "ROLE_CHANGE",
        _data = { member = COORD, newRole = SF.MemberRoles.MEMBER },
    }
end
profile.AddLootLog = function()
    return true
end
local sortedTakeovers = 0
Sync.TakeoverSession = function()
    sortedTakeovers = sortedTakeovers + 1
    return true
end
local sortedDemotion = SF.Member.new(COORD, SF.MemberRoles.ADMIN)
assertEq(sortedDemotion:SetRole(SF.MemberRoles.MEMBER, { profile = profile }), true,
    "same-second demotion still commits the role log")
assertTrue(listHas(profile._adminUsers, COORD),
    "a later same-second grant keeps the demoted member authorized")
assertEq(Sync:_RouteWasRevoked(COORD), false, "sorted history does not revoke that coordinator")
assertEq(sortedTakeovers, 0, "sorted history does not take over from that coordinator")
Sync.TakeoverSession = originalTakeover

-- A promotion that sorts before a same-second removal is not an admin role.
reset(OWNER)
setAdmins({ COORD, KINO, OWNER })
Sync.state.isCoordinator = false
Sync.state.coordinator = COORD
Sync.state.helpers = { COORD }
profile.IsCurrentUserAdmin = function()
    return true
end
profile._lootLogs = {
    {
        _timestamp = 50,
        _author = "Zulu-Realm",
        _counter = 2,
        _id = "remove-after-promote",
        _eventType = "ADMIN_REMOVED",
        _data = { member = KINO },
    },
}
SF.LootLogEventTypes.ADMIN_REMOVED = "ADMIN_REMOVED"
SF.LootLog.new = function()
    return {
        _timestamp = 50,
        _author = "Alpha-Realm",
        _counter = 1,
        _id = "local-promote",
        _eventType = "ROLE_CHANGE",
        _data = { member = KINO, newRole = SF.MemberRoles.ADMIN },
    }
end
profile.AddLootLog = function()
    return true
end
local rejectedPromotion = SF.Member.new(KINO, SF.MemberRoles.MEMBER)
assertEq(rejectedPromotion:SetRole(SF.MemberRoles.ADMIN, { profile = profile }), true,
    "local promotion still commits the role log")
assertEq(rejectedPromotion.role, SF.MemberRoles.MEMBER,
    "a later same-second removal keeps the member role")
assertEq(rejectedPromotion:IsAdmin(), false, "a rejected promotion does not report admin")
assertTrue(not listHas(profile._adminUsers, KINO),
    "a later same-second removal leaves the member unauthorized")

-- Identity projection ignores a sourced grant. The role scan must not undo it.
SF.LootHelperIdentity = {
    ApplyCanonicalAdmins = function()
        return true
    end,
}
reset(KINO)
setAdmins({ COORD, KINO, OWNER })
profile._owner = OWNER
profile.GetOwnerId = function()
    return OWNER
end
profile.IsCurrentUserAdmin = function()
    return true
end
Sync.state.isCoordinator = false
Sync.state.coordinator = COORD
Sync.state.helpers = { COORD }
profile._lootLogs = {
    {
        _timestamp = 50,
        _author = "Zulu-Realm",
        _counter = 2,
        _id = "sourced-grant",
        _eventType = "ADMIN_ADDED",
        _data = { member = COORD, sourceLogId = "missing-link" },
    },
}
SF.LootLog.new = function()
    return {
        _timestamp = 50,
        _author = "Alpha-Realm",
        _counter = 1,
        _id = "local-demote-sourced",
        _eventType = "ROLE_CHANGE",
        _data = { member = COORD, newRole = SF.MemberRoles.MEMBER },
    }
end
profile.AddLootLog = function()
    setAdmins({ KINO, OWNER })
    return true
end
Sync.TakeoverSession = function()
    return true
end
local sourcedDemotion = SF.Member.new(COORD, SF.MemberRoles.ADMIN)
assertEq(sourcedDemotion:SetRole(SF.MemberRoles.MEMBER, { profile = profile }), true,
    "sourced-grant demotion still commits the role log")
assertTrue(not listHas(profile._adminUsers, COORD),
    "a missing relationship source does not restore the demoted member")
assertEq(sourcedDemotion.role, SF.MemberRoles.MEMBER,
    "a rejected sourced grant keeps the member role")
assertEq(sourcedDemotion:IsAdmin(), false, "a rejected sourced grant does not report admin")
assertEq(Sync:_RouteWasRevoked(COORD), true,
    "a rejected sourced grant still revokes the coordinator route")
SF.LootHelperIdentity = nil
Sync.TakeoverSession = originalTakeover

-- A sourced ADMIN_ADDED is authority only when identity applied that relationship.
reset(MEMBER)
setAdmins({ OWNER })
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_REMOVED",
        _data = { member = KINO },
    },
    {
        _author = OWNER,
        _counter = 2,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO, sourceLogId = "missing-link" },
    },
}
assertEq(Sync:_LocalHistoryRevokesAdmin(KINO), true,
    "a missing relationship source does not cancel a removal")
assertEq(Sync:_LocalCatchUpGrantStored(KINO), false,
    "a missing relationship source is not a stored grant")
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 10
Sync:HandleSessionStart(KINO, {
    sessionId = "session-sourced",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
})
assertEq(Sync.state.sessionId, SESSION, "an invalid sourced grant does not adopt a new session")
profile._identityProjection = {
    appliedRelationshipIds = { ["link-1"] = true },
}
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_REMOVED",
        _data = { member = KINO },
    },
    {
        _author = OWNER,
        _counter = 2,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO, sourceLogId = "link-1" },
    },
}
assertEq(Sync:_LocalHistoryRevokesAdmin(KINO), false,
    "an applied relationship source restores the grant")
assertEq(Sync:_LocalCatchUpGrantStored(KINO), true,
    "an applied relationship source is a stored grant")

-- Unproven catch-up may be adopted once. Later keepalives must not extend the clock.
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 10
Sync.state.heartbeat.lastCoordMessageAt = 40
local catchNow = 5000
local originalCatchNow = Sync._Now
Sync._Now = function()
    return catchNow
end
Sync:HandleSessionHeartbeat(KINO, {
    sessionId = "session-unproven",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
    sentAt = 1,
})
assertEq(Sync.state.sessionId, "session-unproven", "the first unproven descriptor is adopted")
assertEq(Sync.state._coordinatorCatchUp, KINO, "a missing coordinator stays on catch-up")
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 5000, "the adopting heartbeat baselines the coordinator timer")
catchNow = 8000
Sync:HandleSessionHeartbeat(KINO, {
    sessionId = "session-unproven",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 12,
    sentAt = 2,
})
assertEq(Sync.state.coordEpoch, 12, "a same-session unproven heartbeat still applies a newer epoch")
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 5000,
    "an unproven heartbeat does not refresh the coordinator timer")
catchNow = 8500
Sync:OnControlMessage(KINO, "NOT_A_MESSAGE", {})
Sync:OnBulkMessage(KINO, "NOT_A_BULK", {})
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 5000,
    "unproven coordinator transport does not refresh the takeover clock")
Sync:HandleSessionStart(KINO, {
    sessionId = "session-unproven-2",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 13,
})
assertEq(Sync.state.sessionId, "session-unproven", "a new session id does not reset an unproven catch-up")
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 5000,
    "a rejected session id does not refresh the coordinator timer")
setAdmins({ OWNER, KINO })
catchNow = 9000
Sync:HandleSessionHeartbeat(KINO, {
    sessionId = "session-unproven",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 12,
    sentAt = 3,
})
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 9000,
    "a coordinator who is an admin refreshes the timer")
catchNow = 9500
Sync:OnControlMessage(KINO, "NOT_A_MESSAGE", {})
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 9500,
    "proven coordinator transport still refreshes the takeover clock")
Sync._Now = originalCatchNow

-- Ending the session for a pending BiS frontier must not re-enter relinquish.
reset(COORD)
setAdmins({})
Sync.state.isCoordinator = true
Sync.state.coordinator = COORD
profile._autoBisFrontierPending = true
local originalComm = SF.LootHelperComm
SF.LootHelperComm = {
    Send = function()
        return true
    end,
}
local endCalls = 0
local originalEnd = Sync.EndSession
Sync.EndSession = function(self, reason, broadcast)
    endCalls = endCalls + 1
    if endCalls > 2 then
        return false
    end
    return originalEnd(self, reason, broadcast)
end
Sync:RelinquishUnauthorizedCoordination("frontier-recursion")
assertEq(endCalls, 1, "relinquish ends the session once when a BiS frontier is pending")
assertEq(Sync.state.active, false, "relinquish with no successor ends the session")
assertEq(profile._autoBisFrontierPending, nil, "the pending frontier is cleared while ending")
SF.LootHelperComm = originalComm
Sync.EndSession = originalEnd

-- Startup rebuild can remove the coordinator before the session is announced.
reset(COORD)
setAdmins({ COORD })
local startConvergence = 0
local originalBegin = Sync.BeginAdminConvergence
Sync.BeginAdminConvergence = function()
    startConvergence = startConvergence + 1
    return true
end
local originalStartRebuild = Sync.RebuildProfile
Sync.RebuildProfile = function(self, profileId, reason)
    setAdmins({})
    self:RelinquishUnauthorizedCoordination("rebuild:" .. tostring(reason))
    return true
end
local started = Sync:StartSession(PROFILE)
assertNil(started, "start aborts when rebuild removes this coordinator")
assertEq(Sync.state.active, false, "an aborted start does not leave the session active")
assertEq(startConvergence, 0, "an aborted start does not begin admin convergence")
Sync.BeginAdminConvergence = originalBegin
Sync.RebuildProfile = originalStartRebuild

-- A same-session successor whose grant is missing gets one catch-up window.
-- After a proven admin takes over, that unproven identity cannot reclaim the
-- session until the grant is stored.
;(function()
reset(OWNER)
setAdmins({ OWNER })
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 10
Sync.state.isCoordinator = true
Sync.state.heartbeat.lastCoordMessageAt = 1000
local successorNow = 5000
local originalSuccessorNow = Sync._Now
Sync._Now = function()
    return successorNow
end
Sync:HandleCoordinatorTakeover(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
})
assertEq(Sync.state.coordinator, KINO, "same-session successor takeover is adopted")
assertEq(Sync.state._coordinatorCatchUp, KINO, "a successor without a grant stays on catch-up")
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 5000,
    "same-session successor catch-up baselines the takeover clock")
successorNow = 8000
Sync:HandleCoordinatorTakeover(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 12,
})
assertEq(Sync.state.coordEpoch, 12, "a later same-session unproven takeover still applies")
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 5000,
    "a later same-session unproven takeover does not refresh the clock")
successorNow = 9000
local tookOver = Sync:TakeoverSession(SESSION, PROFILE, "heartbeat-timeout")
assertEq(tookOver, true, "a proven admin takes over from the unproven coordinator")
assertEq(Sync.state.coordinator, OWNER, "takeover stores the proven admin")
local reclaimEpoch = (tonumber(Sync.state.coordEpoch) or 0) + 1
Sync:HandleCoordinatorTakeover(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = reclaimEpoch,
})
assertEq(Sync.state.coordinator, OWNER, "a failed catch-up coordinator cannot take the same session back")
Sync:HandleSessionStart(KINO, {
    sessionId = "session-reclaim",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = reclaimEpoch + 1,
})
assertEq(Sync.state.sessionId, SESSION, "a failed catch-up coordinator cannot reclaim with a new session")
assertEq(Sync.state.coordinator, OWNER, "a failed catch-up reclaim leaves the proven admin in place")
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
successorNow = 10000
Sync:HandleSessionStart(KINO, {
    sessionId = "session-proven",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = reclaimEpoch + 2,
})
assertEq(Sync.state.sessionId, "session-proven", "a stored grant lets that coordinator adopt a new session")
Sync._Now = originalSuccessorNow
end)()

-- A failed catch-up on one profile does not block that player on another profile.
-- A repeated mismatched catch-up reply does not walk local history again.
;(function()
reset(OWNER)
setAdmins({ OWNER })
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 10
Sync.state.isCoordinator = true
Sync.state.heartbeat.lastCoordMessageAt = 1000
local otherNow = 5000
local originalOtherNow = Sync._Now
Sync._Now = function()
    return otherNow
end
Sync:HandleCoordinatorTakeover(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
})
otherNow = 9000
Sync:TakeoverSession(SESSION, PROFILE, "heartbeat-timeout")
local blockedEpoch = (tonumber(Sync.state.coordEpoch) or 0) + 1
Sync:HandleSessionStart(KINO, {
    sessionId = "session-other-profile",
    profileId = "profile-2",
    coordinator = KINO,
    coordEpoch = blockedEpoch,
})
assertEq(Sync.state.profileId, "profile-2", "a failed catch-up on another profile does not block this profile")
assertEq(Sync.state.coordinator, KINO, "that player can coordinate a profile they have not failed")
assertEq(Sync.state.sessionId, "session-other-profile", "the other profile's session is adopted")
Sync._Now = originalOtherNow

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
local mismatched = seedRequest("need-mismatched-grant", "NEED_LOGS", { KINO }, KINO)
mismatched.meta.integrityRepair = true
local proofScans = 0
local originalProofHistory = Sync._LocalHistoryRevokesAdmin
Sync._LocalHistoryRevokesAdmin = function(self, name)
    proofScans = proofScans + 1
    return originalProofHistory(self, name)
end
local function sendMismatched(counter, requestId)
    Sync:HandleAuthLogs(KINO, {
        sessionId = SESSION,
        profileId = PROFILE,
        requestId = requestId or "need-mismatched-grant",
        author = "Author-Realm",
        fromCounter = 1,
        toCounter = 2,
        logs = {
            {
                _author = OWNER,
                _counter = counter,
                _eventType = "ADMIN_ADDED",
                _data = { member = KINO },
            },
        },
    })
end
sendMismatched(99)
sendMismatched(99)
assertEq(proofScans, 1, "a repeated mismatched catch-up grant does not scan history again")
assertTrue(Sync.state.requests["need-mismatched-grant"] ~= nil, "the mismatched grant leaves the request open")
sendMismatched(100)
assertEq(proofScans, 2, "a different mismatched grant scans history once")
Sync._LocalHistoryRevokesAdmin = originalProofHistory
end)()

-- An ordinary AUTH_LOGS rebuild keeps a catch-up coordinator whose history
-- does not revoke them. A cross-session takeover records that failure before
-- the old scope is cleared. A later grant on the blocked profile is visible
-- while another profile is active. Departed snapshot senders do not scan proof.
;(function()
reset(OWNER)
setAdmins({ OWNER })
Sync.state.isCoordinator = false
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state._coordinatorCatchUp = KINO
profile._lootLogs = {}
assertEq(Sync:_CatchUpRequestGrantFields(OWNER).adminGrantMember, KINO,
    "a missing catch-up grant is requested from a trusted admin")
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:auth_logs")
assertEq(Sync.state._coordinatorCatchUp, KINO, "auth_logs rebuild keeps an unrevoked catch-up coordinator")
assertEq(Sync:_RouteWasRevoked(KINO), false, "auth_logs rebuild does not revoke a missing grant")
assertEq(Sync.state.coordinator, KINO, "auth_logs rebuild does not take over from catch-up")
assertEq(Sync.state.isCoordinator, false, "the admin receiver stays a member during catch-up")
assertEq(Sync:_CatchUpRequestGrantFields(OWNER).adminGrantMember, KINO,
    "the grant request still names the catch-up coordinator after auth_logs")
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_REMOVED",
        _data = { member = KINO },
    },
}
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:auth_logs")
assertEq(Sync:_RouteWasRevoked(KINO), true, "auth_logs rebuild still revokes a coordinator history removed")
assertNil(Sync.state._coordinatorCatchUp, "a history removal clears catch-up on auth_logs rebuild")

reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 10
Sync.state.isCoordinator = false
local crossNow = 5000
local originalCrossNow = Sync._Now
Sync._Now = function()
    return crossNow
end
Sync:HandleCoordinatorTakeover(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
})
assertEq(Sync.state._coordinatorCatchUp, KINO, "the unproven coordinator is on catch-up before the new session")
Sync:HandleCoordinatorTakeover(OWNER, {
    sessionId = "session-legit",
    profileId = PROFILE,
    coordinator = OWNER,
    coordEpoch = 12,
})
assertEq(Sync.state.sessionId, "session-legit", "a different admin can take a new session")
assertEq(Sync.state.coordinator, OWNER, "the new session stores the authorized coordinator")
assertTrue(Sync:_FailedCatchUpBlocks(KINO, PROFILE),
    "cross-session takeover records the unproven coordinator before catch-up is cleared")
Sync:HandleSessionStart(KINO, {
    sessionId = "session-again",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 13,
})
assertEq(Sync.state.sessionId, "session-legit", "the recorded failure rejects a later higher-epoch session")
assertEq(Sync.state.coordinator, OWNER, "the recorded failure leaves the authorized coordinator in place")
Sync._Now = originalCrossNow

reset(OWNER)
setAdmins({ OWNER })
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 10
Sync.state.isCoordinator = true
local otherProfileNow = 5000
local originalOtherProfileNow = Sync._Now
Sync._Now = function()
    return otherProfileNow
end
Sync:HandleCoordinatorTakeover(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
})
otherProfileNow = 9000
assertEq(Sync:TakeoverSession(SESSION, PROFILE, "heartbeat-timeout"), true,
    "a proven admin takes the failed catch-up session back")
local profile2Admins = { OWNER }
local profile2 = {
    _profileId = "profile-2",
    _lootLogs = {
        {
            _author = OWNER,
            _counter = 1,
            _eventType = "POINT_CHANGE",
            _data = { member = MEMBER },
        },
    },
    _adminUsers = profile2Admins,
    GetProfileId = function(self)
        return self._profileId
    end,
    GetAdminUsers = function()
        return profile2Admins
    end,
    GetLootLogs = function(self)
        return self._lootLogs
    end,
}
SF.lootHelperDB.profiles["profile-2"] = profile2
Sync.state.profileId = "profile-2"
Sync.state.sessionId = "session-other"
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 20
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}
local grantScans = 0
local originalGrantState = Sync._LogAdminGrantState
Sync._LogAdminGrantState = function(self, logTable, who)
    grantScans = grantScans + 1
    return originalGrantState(self, logTable, who)
end
assertEq(Sync:_LocalCatchUpGrantStored(OWNER), false, "the active profile has no catch-up grant")
Sync:HandleSessionStart(KINO, {
    sessionId = "session-profile-1-blocked",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 21,
})
assertEq(Sync.state.sessionId, "session-other", "the failed profile stays blocked before its grant arrives")
assertEq(Sync.state.profileId, "profile-2", "the blocked descriptor does not switch profiles")
assertEq(Sync.state._catchUpGrantScan.profileId, "profile-2",
    "checking another profile does not replace the active grant cache")
local afterForeignScan = grantScans
Sync:_LocalCatchUpGrantStored(OWNER)
assertEq(grantScans, afterForeignScan, "the active profile grant cache is reused after the other profile is checked")
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 2,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
local beforeGrantScan = grantScans
assertEq(Sync:_LocalCatchUpGrantStored(KINO, PROFILE), true, "the inactive profile stores the coordinator grant")
local grantedScans = grantScans
assertTrue(grantedScans > beforeGrantScan, "the inactive profile grant is scanned once")
assertEq(Sync:_LocalCatchUpGrantStored(KINO, PROFILE), true, "the inactive profile grant stays stored")
assertEq(grantScans, grantedScans, "a repeated inactive-profile grant check does not walk history again")
otherProfileNow = 9500
Sync:HandleSessionStart(KINO, {
    sessionId = "session-profile-1-granted",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 22,
})
assertEq(Sync.state.sessionId, "session-profile-1-granted",
    "a grant stored on the incoming profile clears that profile's failed catch-up")
assertEq(Sync.state.profileId, PROFILE, "the granted profile becomes the active session")
assertEq(Sync.state.coordinator, KINO, "that coordinator is adopted for the profile that stores the grant")
Sync._LogAdminGrantState = originalGrantState
Sync._Now = originalOtherProfileNow

reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state._coordinatorCatchUp = KINO
local proofCalls = 0
local originalSnapshotProof = Sync._CatchUpSnapshotProvesGrant
Sync._CatchUpSnapshotProvesGrant = function(self, sender, snapshot)
    proofCalls = proofCalls + 1
    return originalSnapshotProof(self, sender, snapshot)
end
local originalGroup = Sync.IsRequesterInGroup
Sync.IsRequesterInGroup = function(_, sender)
    return sender ~= KINO
end
local departed = seedRequest("need-left-group", "NEED_PROFILE", { KINO }, KINO)
local departedPayload = {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = departed.id,
    snapshot = {
        meta = { _profileId = PROFILE },
        adminUsers = { KINO, OWNER },
        lootLogs = {
            {
                _author = OWNER,
                _counter = 4,
                _eventType = "ADMIN_ADDED",
                _data = { member = KINO },
            },
        },
    },
}
Sync:HandleProfileSnapshot(KINO, departedPayload)
Sync:HandleProfileSnapshot(KINO, departedPayload)
assertEq(proofCalls, 0, "repeated out-of-group snapshots do not scan catch-up proof")
assertTrue(debugCount("not in group") >= 1, "an out-of-group snapshot is rejected in debug")
assertEq(warningCount("not in group"), 0, "an out-of-group snapshot stays out of chat")
Sync._CatchUpSnapshotProvesGrant = originalSnapshotProof
Sync.IsRequesterInGroup = originalGroup
end)()

-- Advertised helpers are deduplicated and capped before routing. A longer
-- copy of the same list must not retarget, and request sorting must not see
-- the inbound array.
;(function()
reset(MEMBER)
setAdmins({ COORD, KINO, OWNER, SUSPENDERS })
local refreshes = 0
local originalRefresh = Sync._RefreshOutstandingRequestTargets
Sync._RefreshOutstandingRequestTargets = function(self, opts)
    refreshes = refreshes + 1
    return originalRefresh(self, opts)
end
local huge = {}
for i = 1, 200 do
    huge[i] = KINO
end
assertEq(Sync:ApplyAdvertisedHelpers(huge, "duplicate-helpers"), true,
    "the first capped helper list is installed")
assertEq(#Sync.state.helpers, 1, "duplicate advertised helpers collapse to one")
assertEq(Sync.state.helpers[1], KINO, "the authorized helper is kept")
local installedRefreshes = refreshes
huge[201] = KINO
assertEq(Sync:ApplyAdvertisedHelpers(huge, "duplicate-helpers-again"), false,
    "a longer duplicate helper list does not change routing")
assertEq(#Sync.state.helpers, 1, "the stored helper list stays capped")
assertEq(refreshes, installedRefreshes, "duplicate helper advertisements do not retarget requests")
local padded = { STRANGER, STRANGER }
for i = 1, 80 do
    padded[#padded + 1] = STRANGER
end
padded[#padded + 1] = KINO
assertEq(#Sync:_FilterHelpersToAuthorized(padded), 0,
    "helpers past the scan cap are not read")
Sync:ApplyAdvertisedHelpers({ STRANGER, KINO, OWNER, SUSPENDERS }, "mixed-helpers")
assertEq(#Sync.state.helpers, 2, "advertised helpers are capped at maxHelpers")
assertEq(Sync.state.helpers[1], KINO, "unauthorized names do not consume the helper cap")
assertEq(Sync.state.helpers[2], OWNER, "the cap keeps the second authorized helper")
local sortSizes = {}
local originalSort = table.sort
table.sort = function(list, comp)
    sortSizes[#sortSizes + 1] = #list
    return originalSort(list, comp)
end
local targets = Sync:GetRequestTargets(huge, COORD)
table.sort = originalSort
local largestSort = 0
for _, size in ipairs(sortSizes) do
    if size > largestSort then
        largestSort = size
    end
end
assertTrue(largestSort <= 2, "request target sorting stays within maxHelpers")
assertTrue(#targets <= 3, "capped helpers do not expand the target list")
Sync._RefreshOutstandingRequestTargets = originalRefresh
end)()

-- Case variants share one failed-catch-up block. An oversized catch-up snapshot
-- scans local history once. An ownerless revoked coordinator can still end the
-- session; a revoked coordinator with a successor cannot.
;(function()
reset(OWNER)
setAdmins({ OWNER })
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 10
Sync.state.isCoordinator = true
local caseNow = 5000
local originalCaseNow = Sync._Now
Sync._Now = function()
    return caseNow
end
Sync:HandleCoordinatorTakeover(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
})
caseNow = 9000
assertEq(Sync:TakeoverSession(SESSION, PROFILE, "heartbeat-timeout"), true,
    "a proven admin records the unproven catch-up failure")
assertEq(Sync:_FailedCatchUpKey(PROFILE, KINO), Sync:_FailedCatchUpKey(PROFILE, "kIno-Realm"),
    "failed catch-up keys ignore coordinator capitalization")
assertTrue(Sync:_FailedCatchUpBlocks("kIno-Realm", PROFILE),
    "a case variant is blocked by the recorded catch-up failure")
local book = Sync.state._failedCatchUp
local stored = 0
for _ in pairs(book) do
    stored = stored + 1
end
for i = stored + 1, 32 do
    book[PROFILE .. "\0other-" .. i] = true
end
Sync:HandleSessionStart("kIno-Realm", {
    sessionId = "session-case",
    profileId = PROFILE,
    coordinator = "kIno-Realm",
    coordEpoch = (tonumber(Sync.state.coordEpoch) or 0) + 1,
})
assertEq(Sync.state.sessionId, SESSION, "a full book still rejects a case variant of the failed coordinator")
assertEq(Sync.state.coordinator, OWNER, "the case variant does not replace the proven coordinator")
Sync._Now = originalCaseNow

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
local wideReq = seedRequest("need-wide-snap", "NEED_PROFILE", { KINO }, KINO)
wideReq.inflightResponders = { [KINO] = KINO }
local wideScans = 0
local originalWideHistory = Sync._LocalHistoryRevokesAdmin
Sync._LocalHistoryRevokesAdmin = function(self, name)
    wideScans = wideScans + 1
    return originalWideHistory(self, name)
end
local function wideSnapshot(counterOffset)
    local logs = {}
    for i = 1, 18 do
        logs[i] = {
            _author = "Author-Realm",
            _counter = i + counterOffset,
            _eventType = "POINT_CHANGE",
            _data = { member = MEMBER },
        }
    end
    logs[19] = {
        _author = OWNER,
        _counter = 99,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    }
    return {
        sessionId = SESSION,
        profileId = PROFILE,
        requestId = "need-wide-snap",
        snapshot = {
            meta = { _profileId = PROFILE },
            adminUsers = { KINO, OWNER },
            lootLogs = logs,
        },
    }
end
Sync:HandleProfileSnapshot(KINO, wideSnapshot(0))
Sync:HandleProfileSnapshot(KINO, wideSnapshot(0))
assertEq(wideScans, 1, "a repeated oversized catch-up snapshot does not scan local history again")
Sync:HandleProfileSnapshot(KINO, wideSnapshot(50))
assertEq(wideScans, 2, "a different oversized catch-up snapshot scans local history once")
Sync._LocalHistoryRevokesAdmin = originalWideHistory

reset(MEMBER)
setAdmins({})
Sync.state.coordinator = COORD
Sync:_RememberRevokedRoute(COORD)
Sync:HandleSessionEnd(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 10,
    reason = "coordinator_lost_admin",
})
assertEq(Sync.state.active, false, "an ownerless revoked coordinator can end the session")

reset(MEMBER)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync:_RememberRevokedRoute(COORD)
Sync:HandleSessionEnd(COORD, {
    sessionId = SESSION,
    profileId = PROFILE,
    coordinator = COORD,
    coordEpoch = 10,
    reason = "revoked",
})
assertEq(Sync.state.active, true, "a revoked coordinator with a successor still cannot end the session")
end)()

-- Case-folded helper slots, grant cache keys, and sourced grants on the
-- profile being scanned.
;(function()
local originalSame = Sync._SamePlayer
Sync._SamePlayer = function(self, a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    return a:lower() == b:lower()
end

reset(MEMBER)
setAdmins({ KINO, OWNER })
assertEq(Sync:ApplyAdvertisedHelpers({ "kIno-Realm", KINO, OWNER }, "case-helpers"), true,
    "case-variant helpers install the capped list")
assertEq(#Sync.state.helpers, 2, "two spellings of one helper consume one slot")
assertEq(Sync.state.helpers[1], "kIno-Realm", "the first spelling of a helper is kept")
assertEq(Sync.state.helpers[2], OWNER, "the next distinct helper is kept")
local targets = Sync:GetRequestTargets({ "kIno-Realm", KINO, OWNER }, COORD)
local kinoSpellings = 0
local hasOwner = false
for _, name in ipairs(targets) do
    if type(name) == "string" and name:lower() == KINO:lower() then
        kinoSpellings = kinoSpellings + 1
    end
    if name == OWNER then
        hasOwner = true
    end
end
assertEq(kinoSpellings, 1, "request targets keep one spelling of a helper")
assertTrue(hasOwner, "request targets keep the next helper")

reset(MEMBER)
setAdmins({ OWNER })
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
local grantScans = 0
local originalGrantState = Sync._LogAdminGrantState
Sync._LogAdminGrantState = function(self, logTable, who, scannedProfile)
    grantScans = grantScans + 1
    return originalGrantState(self, logTable, who, scannedProfile)
end
assertEq(Sync:_LocalCatchUpGrantStored(KINO), true, "the canonical spelling stores the catch-up grant")
local afterFirst = grantScans
assertEq(Sync:_LocalCatchUpGrantStored("kIno-Realm"), true,
    "a capitalization variant reuses the stored catch-up grant")
assertEq(grantScans, afterFirst, "a capitalization variant does not walk history again")
local function caseVariant(n)
    local src = KINO
    local out = {}
    local bit = n
    for i = 1, #src do
        local ch = src:sub(i, i)
        if string.match(ch, "%a") then
            if math.fmod(bit, 2) == 1 then
                ch = string.lower(ch)
            else
                ch = string.upper(ch)
            end
            bit = math.floor(bit / 2)
        end
        out[#out + 1] = ch
    end
    return table.concat(out)
end
local allCached = true
for n = 0, 39 do
    if Sync:_LocalCatchUpGrantStored(caseVariant(n)) ~= true then
        allCached = false
    end
end
assertTrue(allCached, "forty capitalization variants reuse the stored catch-up grant")
assertEq(grantScans, afterFirst, "forty capitalization variants share one grant scan")
local storedNames = 0
for _ in pairs(Sync.state._catchUpGrantScan.byName) do
    storedNames = storedNames + 1
end
assertEq(storedNames, 1, "capitalization variants share one catch-up grant cache key")
Sync._LogAdminGrantState = originalGrantState
Sync._SamePlayer = originalSame

reset(MEMBER)
setAdmins({ OWNER })
profile._identityProjection = {
    appliedRelationshipIds = { ["rel-1"] = true },
}
local profile2Admins = { OWNER }
local profile2 = {
    _profileId = "profile-2",
    _lootLogs = {
        {
            _author = OWNER,
            _counter = 1,
            _eventType = "ADMIN_ADDED",
            _data = { member = KINO, sourceLogId = "rel-1" },
        },
    },
    _adminUsers = profile2Admins,
    _identityProjection = {
        appliedRelationshipIds = {},
    },
    GetProfileId = function(self)
        return self._profileId
    end,
    GetAdminUsers = function()
        return profile2Admins
    end,
    GetLootLogs = function(self)
        return self._lootLogs
    end,
}
SF.lootHelperDB.profiles["profile-2"] = profile2
local blockedKey = Sync:_FailedCatchUpKey("profile-2", KINO)
Sync.state._failedCatchUp = { [blockedKey] = true }
assertEq(Sync.state.profileId, PROFILE, "the active profile stays profile-1")
assertTrue(Sync:_FailedCatchUpBlocks(KINO, "profile-2"),
    "an applied relationship on the active profile does not clear another profile")
profile2._identityProjection = {
    appliedRelationshipIds = { ["rel-1"] = true },
}
profile._identityProjection = {
    appliedRelationshipIds = {},
}
assertEq(Sync:_FailedCatchUpBlocks(KINO, "profile-2"), false,
    "a grant applied on the incoming profile clears its failed catch-up")
assertEq(Sync:_LocalCatchUpGrantStored(KINO, "profile-2"), true,
    "the incoming profile stores the sourced grant")
assertEq(Sync.state.profileId, PROFILE, "the grant lookup does not switch the active profile")
profile2._identityProjection = {
    appliedRelationshipIds = {},
}
profile._identityProjection = {
    appliedRelationshipIds = { ["rel-1"] = true },
}
local served = {}
Sync:_AppendAdminGrantEvidence(served, profile2, KINO)
assertEq(#served, 0, "a served grant uses the scanned profile's applied relationship")
profile2._identityProjection = {
    appliedRelationshipIds = { ["rel-1"] = true },
}
profile._identityProjection = {
    appliedRelationshipIds = {},
}
served = {}
Sync:_AppendAdminGrantEvidence(served, profile2, KINO)
assertEq(#served, 1, "a sourced grant is served when the scanned profile applied it")
assertEq(Sync.state.profileId, PROFILE, "serving the grant does not switch the active profile")
end)()

-- The first profile snapshot is the local history. A helper copy that omits
-- the coordinator grant must not revoke that coordinator or start a takeover.
;(function()
reset(OWNER)
setAdmins({ OWNER })
Sync.state.isCoordinator = false
Sync.state.coordinator = KINO
Sync.state.helpers = { OWNER }
Sync.state.coordEpoch = 4
profile._lootLogs = {}
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:profile_snapshot_new")
assertEq(Sync.state._coordinatorCatchUp, KINO, "a bootstrap snapshot keeps a missing coordinator on catch-up")
assertEq(Sync:_RouteWasRevoked(KINO), false, "a bootstrap snapshot does not revoke a coordinator history did not remove")
assertEq(Sync.state.coordinator, KINO, "an admin does not take over after a bootstrap snapshot with no removal")
assertEq(Sync.state.isCoordinator, false, "the admin receiver stays a member during bootstrap catch-up")

reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state.helpers = {}
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_REMOVED",
        _data = { member = KINO },
    },
}
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:profile_snapshot_new")
assertEq(Sync:_RouteWasRevoked(KINO), true, "a bootstrap snapshot still revokes a coordinator history removed")
assertNil(Sync.state._coordinatorCatchUp, "a bootstrap removal does not stay on catch-up")

reset(OWNER)
setAdmins({ OWNER })
Sync.state.isCoordinator = false
Sync.state.coordinator = KINO
Sync.state.helpers = {}
profile._lootLogs = {}
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:profile_snapshot")
assertEq(Sync:_RouteWasRevoked(KINO), true, "a later snapshot still revokes a coordinator who is not on catch-up")
assertNil(Sync.state._coordinatorCatchUp, "a later snapshot does not invent catch-up")

reset(MEMBER)
SF.lootHelperDB.profiles = {}
Sync.state.coordinator = KINO
Sync.state.helpers = { OWNER }
local bootReason = nil
local originalCreate = Sync.CreateProfileFromMeta
local originalRebuild = Sync.RebuildProfile
Sync.CreateProfileFromMeta = function()
    return {
        _rcConfigSeq = 0,
        GetProfileName = function()
            return "Imported"
        end,
        ImportSnapshot = function()
            return true, 0
        end,
    }
end
Sync.RebuildProfile = function(_, _, reason)
    bootReason = reason
    return true
end
local bootReq = seedRequest("need-boot-new", "NEED_PROFILE", { OWNER }, OWNER)
Sync:HandleProfileSnapshot(OWNER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = bootReq.id,
    snapshot = {
        meta = { _profileId = PROFILE },
    },
})
assertEq(bootReason, "profile_snapshot_new", "the first snapshot rebuild is the bootstrap reason")
Sync.CreateProfileFromMeta = originalCreate
Sync.RebuildProfile = originalRebuild

reset(MEMBER)
setAdmins({ OWNER, KINO })
Sync.state.coordinator = KINO
Sync.state.helpers = { OWNER }
local updateReason = nil
profile.ImportSnapshot = function()
    return true, 0
end
profile.GetProfileName = function()
    return "Existing"
end
Sync.RebuildProfile = function(_, _, reason)
    updateReason = reason
    return true
end
local updateReq = seedRequest("need-boot-existing", "NEED_PROFILE", { OWNER }, OWNER)
Sync:HandleProfileSnapshot(OWNER, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = updateReq.id,
    snapshot = {
        meta = { _profileId = PROFILE },
    },
})
assertEq(updateReason, "profile_snapshot", "an existing profile keeps the ordinary snapshot rebuild")
Sync.RebuildProfile = originalRebuild
end)()

-- A full failed-catch-up book still blocks a coordinator who was never recorded.
-- Proof and grant caches drop the oldest entry instead of forgetting every result.
;(function()
reset(OWNER)
setAdmins({ OWNER })
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 10
Sync.state.isCoordinator = true
Sync.state._failedCatchUp = {}
for i = 1, 32 do
    Sync.state._failedCatchUp[PROFILE .. "\0other-" .. i] = true
end
assertTrue(Sync:_FailedCatchUpBlocks(KINO, PROFILE),
    "a full book blocks an unrecorded unproven coordinator")
Sync:HandleSessionStart(KINO, {
    sessionId = "session-overflow",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
})
assertEq(Sync.state.sessionId, SESSION, "a full book rejects a new unproven coordinator")
assertEq(Sync.state.coordinator, OWNER, "the unrecorded coordinator does not take the session")
setAdmins({ OWNER, KINO })
assertEq(Sync:_FailedCatchUpBlocks(KINO, PROFILE), false,
    "a canonical admin is not blocked by a full catch-up book")
Sync:HandleSessionStart(KINO, {
    sessionId = "session-admin",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 12,
})
assertEq(Sync.state.coordinator, KINO, "a canonical admin can still start a session when the book is full")

reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = OWNER
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 1,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
Sync.state._failedCatchUp = {}
for i = 1, 32 do
    Sync.state._failedCatchUp[PROFILE .. "\0filled-" .. i] = true
end
assertEq(Sync:_FailedCatchUpBlocks(KINO, PROFILE), false,
    "a stored grant is not blocked by a full catch-up book")

reset(MEMBER)
setAdmins({ OWNER })
profile._lootLogs = {
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}
local grantWalks = 0
local originalGrantState = Sync._LogAdminGrantState
Sync._LogAdminGrantState = function(self, logTable, who, scannedProfile)
    grantWalks = grantWalks + 1
    return originalGrantState(self, logTable, who, scannedProfile)
end
local grantFilled = true
for n = 1, 32 do
    if Sync:_LocalCatchUpGrantStored("Player" .. n .. "-Realm") ~= false then
        grantFilled = false
    end
end
assertTrue(grantFilled, "the grant cache stores each of the first 32 misses")
local afterGrantFill = grantWalks
assertEq(Sync:_LocalCatchUpGrantStored("Player2-Realm"), false,
    "an older grant-cache entry is still a hit")
assertEq(grantWalks, afterGrantFill, "filling the grant cache does not drop the older names")
assertEq(Sync:_LocalCatchUpGrantStored("Player33-Realm"), false,
    "the grant cache accepts one more name by dropping the oldest")
assertTrue(grantWalks > afterGrantFill, "the new grant-cache name walks history once")
local afterGrantEvict = grantWalks
assertEq(Sync:_LocalCatchUpGrantStored("Player2-Realm"), false,
    "the retained grant-cache name stays cached")
assertEq(grantWalks, afterGrantEvict, "evicting the oldest grant-cache name keeps the rest")
assertEq(Sync:_LocalCatchUpGrantStored("Player1-Realm"), false,
    "the evicted grant-cache name is scanned again")
assertTrue(grantWalks > afterGrantEvict, "the evicted grant-cache name walks history once")
Sync._LogAdminGrantState = originalGrantState

reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state._coordinatorCatchUp = KINO
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 3,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
local proofScans = 0
local originalHistory = Sync._LocalHistoryRevokesAdmin
Sync._LocalHistoryRevokesAdmin = function(self, name)
    proofScans = proofScans + 1
    return originalHistory(self, name)
end
local function rejectedProof(n)
    return {
        {
            _author = OWNER,
            _counter = 100 + n,
            _eventType = "ADMIN_ADDED",
            _data = { member = KINO },
        },
    }
end
local proofsRejected = true
for n = 1, 32 do
    if Sync:_CatchUpProvenGrantLog(KINO, rejectedProof(n)) ~= nil then
        proofsRejected = false
    end
end
assertTrue(proofsRejected, "the first 32 unmatched catch-up proofs are rejected")
local afterProofFill = proofScans
assertNil(Sync:_CatchUpProvenGrantLog(KINO, rejectedProof(2)),
    "a cached rejection is reused")
assertEq(proofScans, afterProofFill, "a cached rejection does not walk local history again")
assertNil(Sync:_CatchUpProvenGrantLog(KINO, rejectedProof(33)),
    "a full proof cache rejects a new payload without evicting")
assertEq(proofScans, afterProofFill, "a full proof cache does not walk history for a new payload")
assertNil(Sync:_CatchUpProvenGrantLog(KINO, rejectedProof(1)),
    "a cached rejection stays cached when the book is full")
assertEq(proofScans, afterProofFill, "a full proof cache does not rescan a cached rejection")
assertNil(Sync:_CatchUpProvenGrantLog(KINO, rejectedProof(33)),
    "repeating an uncached proof still does not walk history")
assertEq(proofScans, afterProofFill, "cycling proofs does not rescan local history")
Sync._LocalHistoryRevokesAdmin = originalHistory
end)()

-- A reset clears the active profile id and keeps that profile's removal history.
-- A new session for the removed coordinator is still rejected. A different
-- active profile is not this check. A full book of another profile does not
-- fail-close this one. Takeover replays history before it broadcasts.
;(function()
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
Sync:_ResetSessionState("inactive-profile")
assertNil(Sync.state.profileId, "reset clears the active profile id")
assertEq(SF.lootHelperDB.profiles[PROFILE], profile, "reset keeps the stored profile")
Sync:HandleSessionStart(KINO, {
    sessionId = "session-after-reset",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
    helpers = { OWNER },
})
assertEq(Sync.state.active, false, "a removed coordinator does not start a session with no active profile id")
assertNil(Sync.state.sessionId, "the removed coordinator does not adopt a session id")
assertTrue(not listHas(Sync.state.helpers, OWNER), "the removed coordinator does not apply advertised helpers")
Sync:HandleSessionHeartbeat(KINO, {
    sessionId = "session-after-reset",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
    sentAt = 80,
})
assertEq(Sync.state.active, false, "a removed coordinator heartbeat does not activate a reset session")
Sync:HandleSessionReannounce(KINO, {
    sessionId = "session-after-reset",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
    helpers = { OWNER },
})
assertEq(Sync.state.active, false, "a removed coordinator reannounce does not activate a reset session")

setAdmins({ OWNER, KINO })
Sync:HandleSessionStart(KINO, {
    sessionId = "session-still-admin",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 12,
})
assertEq(Sync.state.sessionId, "session-still-admin",
    "a current admin is accepted after reset even when history removed them")
assertEq(Sync.state.coordinator, KINO, "the current admin becomes coordinator after reset")

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
local otherProfileId = "profile-other"
local otherAdmins = { KINO }
local otherProfile = {
    _profileId = otherProfileId,
    _lootLogs = {},
    _adminUsers = otherAdmins,
    GetProfileId = function(self)
        return self._profileId
    end,
    GetAdminUsers = function()
        return otherAdmins
    end,
    GetLootLogs = function(self)
        return self._lootLogs
    end,
}
SF.lootHelperDB.profiles[otherProfileId] = otherProfile
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 10
Sync:HandleSessionStart(KINO, {
    sessionId = "session-other-profile",
    profileId = otherProfileId,
    coordinator = KINO,
    coordEpoch = 12,
})
assertEq(Sync.state.sessionId, "session-other-profile",
    "an active session does not apply another profile's removal to a new profile")
assertEq(Sync.state.profileId, otherProfileId, "the new profile is adopted")

reset(MEMBER)
setAdmins({ OWNER })
Sync.state._failedCatchUp = {}
for i = 1, 32 do
    Sync.state._failedCatchUp["profile-other\0filled-" .. i] = true
end
assertEq(Sync:_FailedCatchUpBlocks(KINO, PROFILE), false,
    "another profile's full book does not block this profile")
Sync:HandleSessionStart(KINO, {
    sessionId = "session-other-book",
    profileId = PROFILE,
    coordinator = KINO,
    coordEpoch = 11,
})
assertEq(Sync.state.coordinator, KINO, "another profile's full book still allows this profile's catch-up")
assertEq(Sync.state.sessionId, "session-other-book", "that catch-up adopts the new session")
Sync.state._failedCatchUp = {}
for i = 1, 16 do
    Sync.state._failedCatchUp["profile-other\0partial-" .. i] = true
end
assertEq(Sync:_FailedCatchUpBlocks(KINO, PROFILE), false,
    "a partial book on another profile does not block this profile")
Sync.state._failedCatchUp = {}
for i = 1, 32 do
    Sync.state._failedCatchUp[PROFILE .. "\0filled-" .. i] = true
end
assertTrue(Sync:_FailedCatchUpBlocks(KINO, PROFILE),
    "a full book of this profile still blocks an unmarked coordinator")

reset(KINO)
setAdmins({ KINO })
Sync.state.coordinator = COORD
Sync.state.isCoordinator = false
Sync.state.coordEpoch = 10
local takeoverSends = sendCount(Sync.MSG.COORD_TAKEOVER)
local originalTakeoverRebuild = Sync.RebuildProfile
local rebuildCoordinator = nil
local rebuildReason = nil
Sync.RebuildProfile = function(self, profileId, reason)
    rebuildCoordinator = self.state.coordinator
    rebuildReason = reason
    setAdmins({})
    return true
end
local denied = Sync:TakeoverSession(SESSION, PROFILE, "heartbeat-timeout", { rerunAdminConvergence = false })
assertEq(denied, false, "takeover aborts when replay removes self")
assertEq(rebuildReason, "takeover", "takeover replays the profile before committing")
assertEq(rebuildCoordinator, COORD, "replay runs before this client becomes coordinator")
assertEq(Sync.state.coordinator, COORD, "an aborted takeover leaves the previous coordinator")
assertEq(Sync.state.isCoordinator, false, "an aborted takeover does not mark this client coordinator")
assertEq(sendCount(Sync.MSG.COORD_TAKEOVER), takeoverSends, "an aborted takeover does not broadcast")
Sync.RebuildProfile = originalTakeoverRebuild

reset(KINO)
setAdmins({ KINO, OWNER })
Sync.state.coordinator = COORD
Sync.state.isCoordinator = false
local allowedSends = sendCount(Sync.MSG.COORD_TAKEOVER)
local rebuilds = 0
local nested = nil
Sync.RebuildProfile = function(self, profileId, reason)
    rebuilds = rebuilds + 1
    assertEq(self.state.coordinator, COORD, "a successful takeover also replays before commit")
    assertEq(reason, "takeover", "the successful takeover uses the takeover rebuild reason")
    nested = self:TakeoverSession(self.state.sessionId, profileId, "rebuild-nested", { rerunAdminConvergence = false })
    return true
end
local allowed = Sync:TakeoverSession(SESSION, PROFILE, "heartbeat-timeout", { rerunAdminConvergence = false })
assertEq(nested, false, "replay does not commit a nested takeover")
assertEq(allowed, true, "takeover still commits when replay leaves self authorized")
assertEq(rebuilds, 1, "takeover replays the profile once")
assertEq(Sync.state.coordinator, KINO, "the authorized client becomes coordinator")
assertEq(sendCount(Sync.MSG.COORD_TAKEOVER), allowedSends + 1, "the authorized takeover broadcasts once")
Sync.RebuildProfile = originalTakeoverRebuild
end)()

-- A helper rotated off the session cannot bootstrap a missing profile from the
-- request they already received. Once the profile exists, that same in-flight
-- admin can still answer.
;(function()
reset(MEMBER)
SF.lootHelperDB.profiles = {}
SF.lootHelperDB.activeProfileId = nil
local bootReq = seedRequest("need-rotated", "NEED_PROFILE", { KINO }, KINO)
Sync.state.helpers = { OWNER }
Sync.state.coordinator = COORD
local rotated = Sync:_ClassifyPrivilegedResponse(KINO, PROFILE, bootReq, {
    coordinatorAcceptsAdmins = false,
    expectedKinds = { NEED_PROFILE = true },
})
assertEq(rotated, "untrusted", "a rotated helper cannot bootstrap from an old in-flight request")
Sync:HandleProfileSnapshot(KINO, {
    sessionId = SESSION,
    profileId = PROFILE,
    requestId = "need-rotated",
    snapshot = {
        meta = { _profileId = PROFILE },
        adminUsers = { KINO },
    },
})
assertNil(SF.lootHelperDB.profiles[PROFILE], "a rotated helper snapshot does not create a profile")
assertTrue(Sync.state.requests["need-rotated"] ~= nil, "the rejected bootstrap leaves the profile request open")
local trusted = Sync:_ClassifyPrivilegedResponse(COORD, PROFILE, bootReq, {
    coordinatorAcceptsAdmins = false,
    expectedKinds = { NEED_PROFILE = true },
})
assertEq(trusted, "accept", "the current coordinator can still bootstrap before the profile exists")

reset(MEMBER)
setAdmins({ COORD, KINO, OWNER })
Sync.state.helpers = { OWNER }
Sync.state.coordinator = COORD
local knownReq = seedRequest("need-known", "NEED_PROFILE", { KINO }, KINO)
local known = Sync:_ClassifyPrivilegedResponse(KINO, PROFILE, knownReq, {
    coordinatorAcceptsAdmins = false,
    expectedKinds = { NEED_PROFILE = true },
})
assertEq(known, "accept", "an in-flight admin can still answer once the profile exists")
end)()

-- A full book split across profiles keeps every stored failure. The next
-- unmarked coordinator is fail-closed without deleting an earlier marker.
;(function()
reset(OWNER)
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state._coordinatorCatchUp = KINO
Sync.state._failedCatchUp = {}
for i = 1, 16 do
    Sync.state._failedCatchUp[PROFILE .. "\0a-" .. i] = true
    Sync.state._failedCatchUp["profile-b\0b-" .. i] = true
end
local kept = Sync.state._failedCatchUp["profile-b\0b-1"]
local originalKeepalive = Sync._UnprovenCatchUpKeepalive
Sync._UnprovenCatchUpKeepalive = function()
    return true
end
Sync:_RememberUnprovenCatchUpRelease(KINO, OWNER)
Sync._UnprovenCatchUpKeepalive = originalKeepalive
assertEq(Sync.state._failedCatchUp["profile-b\0b-1"], kept,
    "a full mixed book does not drop an earlier failure")
assertEq(Sync:_FailedCatchUpCount(Sync.state._failedCatchUp), 32,
    "a full mixed book does not grow past 32")
assertEq(Sync.state._failedCatchUpOverflow[PROFILE], true,
    "a full mixed book marks this profile instead of dropping a marker")
assertTrue(Sync:_FailedCatchUpBlocks(KINO, PROFILE),
    "this profile fail-closes after a failure cannot be stored")
assertTrue(Sync:_FailedCatchUpBlocks("b-1", "profile-b"),
    "the earlier failure stays blocked")
assertEq(Sync:_FailedCatchUpBlocks("c-1", "profile-c"), false,
    "a profile that has not overflowed stays open")
end)()

-- Uncorrelated catch-up snapshots are classified without proof work.
-- Oversized proof input fails closed before local history is scanned.
;(function()
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
local proofCalls = 0
local originalSnapshotProof = Sync._CatchUpSnapshotProvesGrant
Sync._CatchUpSnapshotProvesGrant = function(self, sender, snapshot)
    proofCalls = proofCalls + 1
    return originalSnapshotProof(self, sender, snapshot)
end
local historyScans = 0
local originalHistory = Sync._LocalHistoryRevokesAdmin
Sync._LocalHistoryRevokesAdmin = function(self, name, profileId)
    historyScans = historyScans + 1
    return originalHistory(self, name, profileId)
end
local function snap(requestId, logs, admins)
    return {
        sessionId = SESSION,
        profileId = PROFILE,
        requestId = requestId,
        snapshot = {
            meta = { _profileId = PROFILE },
            adminUsers = admins or { KINO, OWNER },
            lootLogs = logs,
        },
    }
end
local grantLog = {
    _author = OWNER,
    _counter = 3,
    _eventType = "ADMIN_ADDED",
    _data = { member = KINO },
}
Sync:HandleProfileSnapshot(KINO, snap(nil, { grantLog }))
assertEq(proofCalls, 0, "a snapshot with no request does not run catch-up proof")
local other = seedRequest("need-other-kind", "NEED_LOGS", { KINO }, KINO)
Sync:HandleProfileSnapshot(KINO, snap(other.id, { grantLog }))
assertEq(proofCalls, 0, "a snapshot citing another request kind does not run catch-up proof")
local idle = seedRequest("need-idle", "NEED_PROFILE", { OWNER }, OWNER)
Sync:HandleProfileSnapshot(KINO, snap(idle.id, { grantLog }))
assertEq(proofCalls, 0, "a snapshot from a sender who was not targeted does not run catch-up proof")
local correlated = seedRequest("need-correlated", "NEED_PROFILE", { KINO }, KINO)
profile.ImportSnapshot = function()
    return false, 0, "stop-before-import"
end
Sync:HandleProfileSnapshot(KINO, snap(correlated.id, { grantLog }))
assertEq(proofCalls, 1, "an in-flight profile snapshot still runs catch-up proof")
local longId = {
    _id = string.rep("x", 241),
    _author = OWNER,
    _counter = 3,
    _eventType = "ADMIN_ADDED",
    _data = { member = KINO },
}
local beforeLong = historyScans
assertEq(Sync:_CatchUpProofPayloadBounded({ longId }), false,
    "a proof field longer than 240 bytes is over the budget")
assertNil(Sync:_CatchUpProvenGrantLog(KINO, { longId }),
    "an overlong proof field is not a grant")
assertEq(historyScans, beforeLong, "an overlong proof field does not scan local history")
local tooMany = { grantLog }
tooMany[8193] = { _eventType = "POINT_CHANGE", _author = OWNER, _counter = 1, _data = { member = MEMBER } }
assertEq(Sync:_CatchUpProofPayloadBounded(tooMany), false,
    "a proof list past 8192 rows is over the budget")
assertNil(Sync:_CatchUpProvenGrantLog(KINO, tooMany),
    "a proof list past 8192 rows is not a grant")
assertEq(historyScans, beforeLong, "a proof list past the row cap does not scan local history")
local wideAdmins = {}
for i = 1, 129 do
    wideAdmins[i] = "Admin" .. i .. "-Realm"
end
wideAdmins[1] = KINO
local logCalls = 0
local originalLogsProve = Sync._CatchUpLogsProveGrant
Sync._CatchUpLogsProveGrant = function()
    logCalls = logCalls + 1
    return true
end
assertEq(Sync:_CatchUpSnapshotProvesGrant(KINO, {
    adminUsers = wideAdmins,
    lootLogs = { grantLog },
}), false, "an admin list past 128 names does not prove catch-up")
assertEq(logCalls, 0, "an oversized admin list does not read snapshot logs")
Sync._CatchUpLogsProveGrant = originalLogsProve
Sync._CatchUpSnapshotProvesGrant = originalSnapshotProof
Sync._LocalHistoryRevokesAdmin = originalHistory
end)()

-- Extra grant-data keys are rejected before the deep compare.
;(function()
reset(MEMBER)
local compared = 0
local originalSame = Sync._SamePlainValue
Sync._SamePlainValue = function(self, a, b, depth)
    compared = compared + 1
    return originalSame(self, a, b, depth)
end
local function row(data)
    return {
        _author = OWNER,
        _counter = 3,
        _eventType = "ADMIN_ADDED",
        _data = data,
    }
end
local stored = row({ member = KINO, sourceLogId = "log-1" })
assertEq(Sync:_GrantRowsMatch(stored, row({ member = KINO, sourceLogId = "log-1" })), true,
    "a short admin grant still matches")
assertTrue(compared > 0, "a short admin grant is compared")
local bulky = { member = KINO }
for i = 1, 8 do
    bulky["extra" .. i] = "v"
end
local beforeBulky = compared
assertEq(Sync:_GrantRowsMatch(stored, row(bulky)), false, "grant data past 8 keys is not proof")
assertEq(compared, beforeBulky, "grant data past 8 keys is not deeply compared")
local beforeLong = compared
assertEq(Sync:_GrantRowsMatch(stored, row({ member = string.rep("m", 241) })), false,
    "an overlong grant field is not proof")
assertEq(compared, beforeLong, "an overlong grant field is not deeply compared")
Sync._SamePlainValue = originalSame
end)()

-- A re-grant clears the NEW_LOG warning without a packet from that player.
;(function()
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = COORD
local function newLog(counter)
    Sync:HandleNewLog(COORD, {
        sessionId = SESSION,
        profileId = PROFILE,
        log = {
            _eventType = "POINT_CHANGE",
            _author = COORD,
            _counter = counter,
            _data = { member = MEMBER },
        },
    })
end
newLog(1)
newLog(2)
assertEq(debugCount("not an admin"), 1, "the first revocation is recorded once in debug")
assertEq(warningCount("not an admin"), 0, "the first revocation stays out of chat")
setAdmins({ OWNER, COORD })
Sync:ReconcileSessionAuthorization(PROFILE, "rebuild:live_update")
setAdmins({ OWNER })
local beforeSecond = debugCount("not an admin")
newLog(3)
assertEq(debugCount("not an admin"), beforeSecond + 1,
    "a later removal is recorded again after the re-grant")
assertEq(warningCount("not an admin"), 0, "a later removal stays out of chat")
end)()

-- The packet that proves a catch-up coordinator refreshes the takeover clock.
-- An unproven reply does not.
;(function()
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = KINO
Sync.state.helpers = {}
Sync.state._coordinatorCatchUp = KINO
Sync.state.heartbeat.lastCoordMessageAt = 40
profile._lootLogs = {
    {
        _author = OWNER,
        _counter = 9,
        _eventType = "ADMIN_ADDED",
        _data = { member = KINO },
    },
}
local req = seedRequest("need-proof-clock", "NEED_LOGS", { KINO }, KINO)
local originalNow = Sync._Now
Sync._Now = function()
    return 9000
end
local originalRebuild = Sync.RebuildProfile
Sync.RebuildProfile = function()
    setAdmins({ OWNER, KINO })
    return true
end
local function logsPayload(logs)
    return {
        sessionId = SESSION,
        profileId = PROFILE,
        requestId = req.id,
        author = "Author-Realm",
        fromCounter = 1,
        toCounter = 2,
        logs = logs,
    }
end
Sync:HandleAuthLogs(KINO, logsPayload({
    {
        _author = "Author-Realm",
        _counter = 1,
        _eventType = "POINT_CHANGE",
        _data = { member = MEMBER },
    },
}))
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 40,
    "an unproven catch-up reply does not refresh the coordinator timer")
Sync:HandleAuthLogs(KINO, logsPayload({
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
assertEq(Sync.state.heartbeat.lastCoordMessageAt, 9000,
    "the packet that proves the coordinator refreshes the timer")
Sync.RebuildProfile = originalRebuild
Sync._Now = originalNow
end)()

-- Initial join-status keeps missing logs queued without chat, then resumes on a route.
;(function()
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.coordinator = COORD
Sync.state.helpers = {}
Sync.state.isCoordinator = false
profile.ComputeAuthorMax = function()
    return {}
end
local savedMissing = Sync.ComputeMissingLogRequests
local savedSend = Sync.SendJoinStatus
local savedQueue = Sync.QueueRepairRanges
Sync.ComputeMissingLogRequests = function()
    return {
        { author = "Author-Realm", fromCounter = 3, toCounter = 4 },
    }
end
Sync.QueueRepairRanges = productionQueueRepairRanges
Sync.SendJoinStatus = productionSendJoinStatus
productionSendJoinStatus(Sync)
assertEq(warningCount("Cannot request missing logs"), 0, "join-status with no route stays out of chat")
assertTrue(#(Sync.state.repairQueue.order or {}) >= 1, "join-status queues missing logs without another event")
setAdmins({ COORD, OWNER })
Sync:ApplyAdvertisedHelpers({ COORD }, "join-route")
Sync:_ProcessRepairConvergenceTick("join-route")
local joined = false
for _, req in pairs(Sync.state.requests) do
    if req.kind == "NEED_LOGS" or req.kind == "LOG_REQ" then
        joined = true
    end
end
assertTrue(joined, "join-status logs are requested when a route returns")
assertEq(warningCount("Cannot request missing logs"), 0, "join-status recovery stays out of chat")
Sync.ComputeMissingLogRequests = savedMissing
Sync.SendJoinStatus = savedSend
Sync.QueueRepairRanges = savedQueue
end)()

-- A user-started sync still explains the consequence. Automatic failures do not.
;(function()
reset(MEMBER)
setAdmins({ COORD, OWNER })
Sync.state.helpers = { COORD }
SF.lootHelperDB.profiles = {}
Sync.state._userInitiatedSync = true
assertEq(Sync:RequestProfileSnapshot("manual"), true, "manual profile request registers")
Sync.state._userInitiatedSync = nil
local manualReq = nil
for _, req in pairs(Sync.state.requests) do
    if req.kind == "NEED_PROFILE" then
        manualReq = req
    end
end
assertTrue(manualReq ~= nil, "manual profile request is outstanding")
Sync:_FailRequest(manualReq, "timeout")
assertEq(warningCount("Profile sync did not finish"), 1, "a user-started profile sync reports the consequence")
assertTrue(string.find(warnings[#warnings], "timeout", 1, true) == nil, "chat omits the timeout reason")
local sawTimeout = false
for _, entry in ipairs(SF._testDebugLogs) do
    if string.find(entry.message, "reason=timeout", 1, true) then
        sawTimeout = true
    end
end
assertTrue(sawTimeout, "the timeout reason is recorded in debug")
local before = warningCount("Profile sync did not finish")
Sync.state._userInitiatedSync = false
local again = {
    id = "auto-fail",
    kind = "NEED_PROFILE",
    meta = { userInitiated = false, backgroundRepair = false },
}
Sync:_FailRequest(again, "timeout")
assertEq(warningCount("Profile sync did not finish"), before, "an automatic profile failure stays out of chat")
end)()

reset(MEMBER)
setAdmins({ OWNER })
Sync:StartSession(PROFILE)
assertEq(warningCount("Cannot start session: You are not an admin for the selected profile"), 1,
    "starting a session without permission stays user-facing")
assertEq(warningCount("%s"), 0, "session start does not show a format placeholder")

reset(COORD)
assertEq(Sync:EndSession("manual", false), true, "coordinator can end the session")
assertTrue(infos[#infos] ~= nil and string.find(infos[#infos], "Loot Helper session ended (manual).", 1, true) ~= nil,
    "session end formats the reason")

;(function()
reset(MEMBER)
setAdmins({ COORD, OWNER })
Sync.state.helpers = { COORD }
Sync.state.isCoordinator = false
profile.ComputeAuthorMax = function()
    return {}
end
local savedMissing = Sync.ComputeMissingLogRequests
local savedMismatch = Sync.ComputeWindowMismatchRequests
local savedSend = Sync.SendJoinStatus
Sync.SendJoinStatus = productionSendJoinStatus
Sync.ComputeMissingLogRequests = function()
    return {}
end
Sync.ComputeWindowMismatchRequests = function()
    return {
        { author = "Author-Realm", fromCounter = 8, toCounter = 9 },
    }
end
local ok, status = Sync:RequestManualSync("integrity")
assertEq(ok, true, "an integrity mismatch can start a manual sync")
assertEq(status, "log_sync_requested", "an integrity mismatch is not reported as already synced")
local generation = Sync.state._userSyncGeneration
local integrityReq = nil
for _, req in pairs(Sync.state.requests) do
    if req.meta and req.meta.integrityRepair == true then
        integrityReq = req
    end
end
assertTrue(integrityReq ~= nil, "manual sync registers the integrity request")
assertEq(integrityReq and integrityReq.meta.userInitiated, true, "the integrity request keeps manual intent")
assertEq(integrityReq and integrityReq.meta.userSyncGeneration, generation, "the integrity request keeps this sync generation")
Sync:_FailRequest(integrityReq, "timeout")
assertEq(warningCount("Log sync did not finish"), 1, "a failed manual integrity request warns once")
Sync.state._userInitiatedSync = true
Sync.state._userSyncGeneration = generation
assertTrue(Sync:RequestIntegrityRepairRanges(PROFILE, {
    { author = "Author-Realm", fromCounter = 2, toCounter = 2 },
}, "join-status"), "a sibling integrity request registers")
local sibling = nil
for _, req in pairs(Sync.state.requests) do
    if req.meta and req.meta.fromCounter == 2 then
        sibling = req
    end
end
Sync:_FailRequest(sibling, "timeout")
assertEq(warningCount("Log sync did not finish"), 1, "retries of the same manual sync do not warn again")
local againOk, againStatus = Sync:RequestManualSync("integrity-again")
assertEq(againOk, true, "a later manual sync can start")
assertEq(againStatus, "log_sync_requested", "a later integrity mismatch is still a sync request")
local later = nil
for _, req in pairs(Sync.state.requests) do
    if req.meta and req.meta.userSyncGeneration == Sync.state._userSyncGeneration and req.meta.integrityRepair == true then
        later = req
    end
end
Sync:_FailRequest(later, "timeout")
assertEq(warningCount("Log sync did not finish"), 2, "a new manual sync warns when it fails")
Sync.ComputeMissingLogRequests = savedMissing
Sync.ComputeWindowMismatchRequests = savedMismatch
Sync.SendJoinStatus = savedSend
end)()

;(function()
reset(OWNER)
setAdmins({ COORD, OWNER })
Sync.state.helpers = { COORD }
Sync.state.isCoordinator = false
Sync.state.coordinator = COORD
profile.ComputeAuthorMax = function()
    return {}
end
local savedMissing = Sync.ComputeMissingLogRequests
local savedMismatch = Sync.ComputeWindowMismatchRequests
local savedSend = Sync.SendJoinStatus
Sync.SendJoinStatus = productionSendJoinStatus
Sync.ComputeMissingLogRequests = function()
    return {
        { author = "Author-Realm", fromCounter = 3, toCounter = 4 },
    }
end
Sync.ComputeWindowMismatchRequests = function()
    return {
        { author = "Author-Realm", fromCounter = 8, toCounter = 9 },
    }
end
local ok, status = Sync:RequestManualSync("mixed-log")
assertEq(ok, true, "a mixed log sync can start")
assertEq(status, "log_sync_requested", "a mixed log sync is one user action")
local needLogs = nil
local logReq = nil
for _, req in pairs(Sync.state.requests) do
    if req.kind == "NEED_LOGS" and req.meta and req.meta.integrityRepair ~= true then
        needLogs = req
    elseif req.kind == "LOG_REQ" and req.meta and req.meta.integrityRepair == true then
        logReq = req
    end
end
assertTrue(needLogs ~= nil, "ordinary missing logs stay NEED_LOGS")
assertTrue(logReq ~= nil, "an admin integrity repair uses LOG_REQ")
Sync:_FailRequest(needLogs, "timeout")
Sync:_FailRequest(logReq, "timeout")
assertEq(warningCount("Log sync did not finish"), 1, "mixed log kinds share one manual warning")
assertEq(warningCount("Synchronization did not finish"), 0, "an integrity failure uses the log-sync guidance")
Sync.ComputeMissingLogRequests = savedMissing
Sync.ComputeWindowMismatchRequests = savedMismatch
Sync.SendJoinStatus = savedSend
end)()

;(function()
reset(MEMBER)
setAdmins({ COORD, OWNER })
Sync.state.helpers = { COORD }
Sync.state.isCoordinator = false
SF.lootHelperDB.profiles = {}
local savedSend = Sync.SendJoinStatus
Sync.SendJoinStatus = productionSendJoinStatus
local previousMax = Sync.cfg.maxOutstandingRequests
Sync.cfg.maxOutstandingRequests = 0
local ok, status = Sync:RequestManualSync("cap")
assertEq(ok, false, "a full request table does not report manual sync success")
assertEq(status, "sync_busy", "a full request table reports sync_busy")
assertEq(warningCount("Synchronization did not start"), 1, "a full request table warns the manual caller")
assertEq(warningCount("Profile sync did not finish"), 0, "a rejected manual sync has no request to fail later")
Sync.cfg.maxOutstandingRequests = previousMax
Sync.SendJoinStatus = savedSend
end)()

;(function()
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.helpers = {}
Sync.state.coordinator = COORD
Sync.state.isCoordinator = false
profile.ComputeAuthorMax = function()
    return {}
end
local savedMissing = Sync.ComputeMissingLogRequests
local savedMismatch = Sync.ComputeWindowMismatchRequests
local savedSend = Sync.SendJoinStatus
local savedQueue = Sync.QueueRepairRanges
Sync.SendJoinStatus = productionSendJoinStatus
Sync.QueueRepairRanges = productionQueueRepairRanges
Sync.ComputeMissingLogRequests = function()
    return {
        { author = "Author-Realm", fromCounter = 3, toCounter = 4 },
    }
end
Sync.ComputeWindowMismatchRequests = function()
    return {}
end
Sync.cfg.maxQueuedRepairRanges = 1
Sync.state.repairQueue = {
    order = { "held" },
    items = {
        held = {
            key = "held",
            profileId = PROFILE,
            author = "Other-Realm",
            fromCounter = 1,
            toCounter = 1,
            mode = "missing",
        },
    },
}
local ok, status = Sync:RequestManualSync("queue-full")
assertEq(ok, false, "a full repair queue does not report manual sync success")
assertEq(status, "sync_busy", "a full repair queue reports sync_busy")
assertEq(warningCount("Synchronization did not start"), 1, "a full repair queue warns the manual caller")
assertEq(#(Sync.state.repairQueue.order or {}), 1, "a full repair queue does not keep the new range")
Sync.cfg.maxQueuedRepairRanges = nil
Sync.ComputeMissingLogRequests = savedMissing
Sync.ComputeWindowMismatchRequests = savedMismatch
Sync.SendJoinStatus = savedSend
Sync.QueueRepairRanges = savedQueue
end)()

;(function()
reset(MEMBER)
setAdmins({ OWNER })
Sync.state.helpers = {}
Sync.state.coordinator = COORD
Sync.state.isCoordinator = false
Sync:ApplyAdvertisedHelpers({}, "no-route")
assertEq(Sync.state._hadAuthorizedRoute, false, "a coordinator who is not an admin is not a route")
local now = Sync:_Now()
Sync.state.repairQueue = {
    order = { "pending" },
    items = {
        pending = {
            lastQueueFailure = "no_targets",
            nextAttemptAt = now + 500,
        },
    },
}
setAdmins({ COORD, OWNER })
local changed = Sync:ApplyAdvertisedHelpers({}, "grant-without-helper-change")
assertEq(changed, false, "restoring the coordinator does not change the helper list")
local entry = Sync.state.repairQueue.items.pending
assertTrue(type(entry) == "table" and entry.nextAttemptAt <= now,
    "a restored coordinator route makes no-target work due")
end)()

;(function()
reset(COORD)
local originalSend = SF.LootHelperComm.Send
SF.LootHelperComm.Send = function()
    return false
end
local broadcastOk, broadcastErr = Sync:BroadcastNewLog(PROFILE, {
    _eventType = "POINT_CHANGE",
    _data = {},
})
assertEq(broadcastOk, false, "a dropped NEW_LOG send fails the broadcast")
assertEq(broadcastErr, "comm send dropped", "a dropped NEW_LOG send keeps the reason")
SF.LootHelperComm.Send = function()
    return true
end
local sentOk = Sync:BroadcastNewLog(PROFILE, {
    _eventType = "POINT_CHANGE",
    _data = {},
})
assertEq(sentOk, true, "an accepted NEW_LOG send still broadcasts")
SF.LootHelperComm.Send = originalSend
end)()

;(function()
local function scanFile(path)
    local handle = io.open(path, "r")
    if not handle then
        return "unreadable " .. path
    end
    local src = handle:read("*a")
    handle:close()
    local i = 1
    while true do
        local startAt, parenAt, name = string.find(src, "SF:Print(%a+)%s*%(", i)
        if not startAt then
            return nil
        end
        local depth = 0
        local j = parenAt
        local finish = nil
        while j <= #src do
            local ch = src:sub(j, j)
            if ch == "(" then
                depth = depth + 1
            elseif ch == ")" then
                depth = depth - 1
                if depth == 0 then
                    finish = j
                    break
                end
            elseif ch == '"' or ch == "'" then
                local quote = ch
                j = j + 1
                while j <= #src and src:sub(j, j) ~= quote do
                    if src:sub(j, j) == "\\" then
                        j = j + 1
                    end
                    j = j + 1
                end
            elseif ch == "-" and src:sub(j, j + 1) == "--" then
                local newline = string.find(src, "\n", j, true)
                j = newline or #src
            end
            j = j + 1
        end
        if not finish then
            return path .. ": unterminated " .. tostring(name)
        end
        local inner = src:sub(parenAt + 1, finish - 1)
        local trimmed = inner:match("^%s*(.*)$") or ""
        local quote = trimmed:sub(1, 1)
        if quote == '"' or quote == "'" then
            local k = 2
            while k <= #trimmed do
                if trimmed:sub(k, k) == "\\" then
                    k = k + 1
                elseif trimmed:sub(k, k) == quote then
                    break
                end
                k = k + 1
            end
            local literal = trimmed:sub(2, k - 1)
            local rest = trimmed:sub(k + 1):match("^%s*(.*)$") or ""
            if rest:sub(1, 1) == "," and string.find(literal, "%%", 1, true) then
                return path .. ": SF:Print" .. tostring(name) .. " passes extra arguments to " .. literal
            end
        end
        i = finish + 1
    end
end

local scan = io.popen("find SpectrumFederation SpectrumFederation_RCLootCouncilIntegration SpectrumFederation_CursedSurgeTracker -name '*.lua' -not -path '*/Libs/*'")
assertTrue(scan ~= nil, "message scan can list addon sources")
if scan then
    local misuse = nil
    for path in scan:lines() do
        misuse = scanFile(path)
        if misuse then
            break
        end
    end
    scan:close()
    assertTrue(misuse == nil, misuse or "print helpers are not called with printf arguments")
end
end)()

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
