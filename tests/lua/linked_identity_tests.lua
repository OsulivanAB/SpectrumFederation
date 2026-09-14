-- Production-Lua tests for linked character identities (#276).
-- Run from the repository root: lua5.1 tests/lua/linked_identity_tests.lua

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

local function assertFalse(cond, message)
    assertTrue(not cond, message)
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local PLAYER = "Owner-Garona"
local OWNER = "Owner-Garona"
local ALT_A = "Alpha-Garona"
local ALT_B = "Bravo-Garona"
local ALT_C = "Charlie-Garona"
local ALT_D = "Delta-Garona"
local ALT_E = "Echo-Garona"
local OTHER = "Other-Garona"

function strtrim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

function string.trim(s)
    return strtrim(s)
end

function GetRealmName()
    return "Garona"
end

function UnitName(unit)
    if unit == "player" then
        return PLAYER:match("^([^%-]+)")
    end
    return "Unknown"
end

function UnitFullName(unit)
    if unit == "player" then
        return PLAYER:match("^([^%-]+)"), "Garona"
    end
    return "Unknown", "Garona"
end

function UnitClass()
    return "Warrior", "WARRIOR"
end

local NOW = 1700001000

function GetServerTime()
    NOW = NOW + 1
    return NOW
end

function GetTime()
    return 0
end

SpectrumFederationDB = { lootHelper = { profiles = {}, syncSession = {}, window = {} } }
SpectrumFederationDebugDB = { enabled = false, logs = {} }

local SF = {}
local printed = {}

local function loadModule(relative)
    local chunk = assert(loadfile(relative))
    chunk("SpectrumFederation", SF)
end

loadModule("SpectrumFederation/modules/NameUtil.lua")
loadModule("SpectrumFederation/modules/core.lua")
loadModule("SpectrumFederation/modules/LootHelper/Members.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootLogValidators.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootLogs.lua")
loadModule("SpectrumFederation/modules/LootHelper/Identity.lua")
loadModule("SpectrumFederation/modules/LootHelper/SpecWeapons.lua")
loadModule("SpectrumFederation/modules/LootHelper/Bis.lua")
loadModule("SpectrumFederation/modules/LootHelper/Profiles.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootHelper.lua")
loadModule("SpectrumFederation/modules/LootHelper/SyncProtocol.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/01_Constants.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/02_State.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/05_Scheduling.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/16_ProfileIntegration.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/07_Validation.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/08_Requests.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/12_LiveUpdates.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/09_AdminConvergence.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/10_Handshake.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/11_Heartbeat.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/14_HandlersControl.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/15_HandlersBulk.lua")

function SF:GetPlayerFullIdentifier()
    return PLAYER
end

function SF:GetPlayerClass()
    return "WARRIOR"
end

function SF:PrintError(message)
    printed[#printed + 1] = { "error", tostring(message) }
end

function SF:PrintWarning(message)
    printed[#printed + 1] = { "warn", tostring(message) }
end

function SF:PrintInfo(message)
    printed[#printed + 1] = { "info", tostring(message) }
end

SF.Debug = {
    Info = function() end,
    Warn = function() end,
    Error = function() end,
    Verbose = function() end,
}

local Sync = SF.LootHelperSync
local ProductionSync = {
    BroadcastSessionHeartbeat = Sync.BroadcastSessionHeartbeat,
    QueueRepairRanges = Sync.QueueRepairRanges,
    GetRequestTargets = Sync.GetRequestTargets,
    SendJoinStatus = Sync.SendJoinStatus,
    ProcessRepairConvergenceTick = Sync._ProcessRepairConvergenceTick,
}
local deferredAfter = {}
function Sync:FindLocalProfileById(profileId)
    return SF.lootHelperDB and SF.lootHelperDB.profiles and SF.lootHelperDB.profiles[profileId]
end
function Sync:RunAfter(delaySec, fn)
    delaySec = tonumber(delaySec) or 0
    if delaySec <= 0 then
        fn()
        return
    end
    deferredAfter[#deferredAfter + 1] = fn
end
function runDeferred()
    local queued = deferredAfter
    deferredAfter = {}
    for i = 1, #queued do
        queued[i]()
    end
end
function Sync:IsBulkTransferAllowed()
    return true
end
function Sync:_EnforceGroupedSessionActive()
    return "RAID"
end
function Sync:RequestGapRepair()
end
function Sync:RequestProfileSnapshot()
end
function Sync:_SelfId()
    return PLAYER
end
function Sync:QueueRepairRanges()
    return true
end
function Sync:_PersistSessionState()
end
function Sync:_GetSessionSafeModePayload()
    return {}
end
function Sync:_ApplySessionSafeModeFromPayload()
end
function Sync:EnsureHeartbeatMonitor()
end
function Sync:EnsureRepairConvergence()
end
function Sync:_KickRepairConvergence()
end
function Sync:_GetAddonVersion()
    return "1.5.0-beta.2"
end
function Sync:TouchPeer()
end
function Sync:IsSafeModeEnabled()
    return false
end
function Sync:_Now()
    return 0
end
function Sync:_NextNonce(tag)
    return tostring(tag or "N") .. "1"
end
function Sync:BroadcastSessionStart()
end
function Sync:UpdatePeersFromRoster()
end
function Sync:GetPeer()
    return { inGroup = true }
end
function Sync:_MInc()
end
function Sync:_MObserve()
end
function Sync:_MetricsUpdateRequestQueueGauges()
end
function Sync:SetPeerSyncState()
end
function Sync:BroadcastSessionHeartbeat()
end

local capturedComm = {}
SF.LootHelperComm = {
    Send = function(_, prefix, msgType, payload, dist, target)
        capturedComm[#capturedComm + 1] = {
            prefix = prefix,
            msgType = msgType,
            payload = payload,
            target = target,
        }
    end,
}

local function resetEnv()
    printed = {}
    deferredAfter = {}
    capturedComm = {}
    PLAYER = "Owner-Garona"
    NOW = 1700001000
    SF.lootHelperDB = {
        enabled = true,
        profiles = {},
        activeProfileId = nil,
        activeProfile = nil,
        window = {},
        syncSession = {},
    }
    SpectrumFederationDB.lootHelper = SF.lootHelperDB
    Sync.state = {
        active = false,
        sessionId = "SES1",
        profileId = nil,
        coordinator = PLAYER,
        isCoordinator = true,
        requests = {},
        helpers = {},
        authorMax = {},
        repairQueue = { order = {}, items = {} },
        convergence = {},
        _adminConvergence = nil,
    }
    Sync._identityAdminReconcileNeeded = {}
    Sync._identityAdminReconcilePending = {}
    Sync._pendingLiveRelationship = {}
    Sync._consideringIdentitySideEffects = nil
    Sync._flushingLiveRelationship = nil
    Sync._liveRelationshipInFlight = nil
end

local function makeProfile(name)
    local profile = SF.LootProfile.new(name)
    assert(profile, "failed to create profile " .. tostring(name))
    SF.lootHelperDB.profiles[profile:GetProfileId()] = profile
    return profile
end

local function addMember(profile, memberId, role)
    local member = SF.Member.new(memberId, role or "member", "WARRIOR")
    assert(member, "failed to create member " .. tostring(memberId))
    assert(profile:AddMember(member), "failed to add member " .. tostring(memberId))
    return member
end

local function setActive(profile)
    SF.lootHelperDB.activeProfileId = profile:GetProfileId()
    SF.lootHelperDB.activeProfile = profile
end

local function addLog(profile, eventType, data, extra)
    extra = extra or {}
    local opts = {
        profile = profile,
        skipPermission = true,
        author = extra.author or PLAYER,
        timestamp = extra.timestamp,
        counter = extra.counter,
    }
    if opts.counter == nil then
        opts.counter = profile:AllocateNextCounter(opts.author)
    end
    local log = SF.LootLog.new(eventType, data, opts)
    assert(log, "failed to create " .. tostring(eventType))
    assert(profile:AddLootLog(log, { skipPermission = true, skipBroadcast = true }), "failed to insert " .. tostring(eventType))
    return log
end

local function asPlayer(memberId, fn)
    local previous = PLAYER
    PLAYER = memberId
    local a, b, c = fn()
    PLAYER = previous
    return a, b, c
end

local function overflowWarningCount()
    local count = 0
    for i = 1, #printed do
        local item = printed[i]
        if item[1] == "warn" and tostring(item[2]):find("overlapping slot usage", 1, true) then
            count = count + 1
        end
    end
    return count
end

local function activateSession(profile)
    Sync.state.active = true
    Sync.state.sessionId = "SES1"
    Sync.state.profileId = profile:GetProfileId()
    Sync.state.coordinator = OWNER
    Sync.state.isCoordinator = true
    Sync.state.authorMax = Sync:ComputeAuthorMax(profile:GetProfileId()) or {}
    Sync.state.requests = {}
    Sync.state.repairQueue = { order = {}, items = {} }
    Sync.state.convergence = {}
end

local function memberOf(profile, id)
    return profile:getMemberByID(id)
end

local function armorOf(profile, id, slot)
    local member = memberOf(profile, id)
    return member and member.armor and member.armor[slot]
end

local function slotOverflow(profile, id, key)
    local counts = SF.LootHelperIdentity.ComponentConflictCounts(profile._identityProjection, id)
    return (counts and counts[key]) or 0
end

local function makeTable(eventType, data, extra)
    extra = extra or {}
    local t = {
        _timestamp = extra.timestamp or 1700000100,
        _author = extra.author or PLAYER,
        _counter = extra.counter or 2,
        _eventType = eventType,
        _data = data,
    }
    t._id = string.format("%s:%d", t._author, t._counter)
    t.version = 2
    t._fingerprint = SF.LootLog.ComputeFingerprintFromTable(t)
    return t
end

local function liveTable(profile, eventType, data, sender, timestamp)
    sender = sender or OWNER
    local counter = profile:AllocateNextCounter(sender)
    return makeTable(eventType, data, {
        author = sender,
        counter = counter,
        timestamp = timestamp or GetServerTime(),
    })
end

local function livePayload(profile, logTable)
    return {
        sessionId = Sync.state.sessionId,
        profileId = profile:GetProfileId(),
        log = logTable,
    }
end

local function pendingList(profile)
    local pending = Sync._pendingLiveRelationship and Sync._pendingLiveRelationship[profile:GetProfileId()]
    if type(pending) ~= "table" then
        return {}
    end
    return pending
end

local function copyLogTables(profile)
    local tables = {}
    for _, log in ipairs(profile:GetLootLogs()) do
        tables[#tables + 1] = log:ToTable()
    end
    return tables
end

local function rebuildFrom(profile, name)
    local replica = makeProfile(name)
    replica:MergeLogTables(copyLogTables(profile))
    replica:ApplyIdentityProjection()
    return replica
end

-- ---------------------------------------------------------------------------
-- Identity: link, transitive, unlink, split, relink, ordering
-- ---------------------------------------------------------------------------
resetEnv()
local profile = makeProfile("Identity")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
setActive(profile)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link A+B")
assertTrue(SF.LootHelperIdentity.SameIdentity(profile:GetLootLogs(), ALT_A, ALT_B), "A and B share identity")
assertFalse(SF.LootHelperIdentity.SameIdentity(profile:GetLootLogs(), ALT_A, ALT_C), "C is not yet linked")
assertTrue(profile:LinkCharacters(ALT_B, ALT_C), "transitive link B+C")
assertTrue(SF.LootHelperIdentity.SameIdentity(profile:GetLootLogs(), ALT_A, ALT_C), "A and C share identity after transitive link")
local groups = SF.LootHelperIdentity.LinkedGroups(profile:GetLootLogs())
assertEq(#groups, 1, "one linked group")
assertEq(#groups[1], 3, "group has three members")
assertEq(groups[1][1], ALT_A, "deterministic first member")
assertEq(groups[1][2], ALT_B, "deterministic second member")
assertEq(groups[1][3], ALT_C, "deterministic third member")
assertTrue(profile:UnlinkCharacter(ALT_B), "unlink B from three-character identity")
assertFalse(SF.LootHelperIdentity.SameIdentity(profile:GetLootLogs(), ALT_A, ALT_B), "B split from A")
assertFalse(SF.LootHelperIdentity.SameIdentity(profile:GetLootLogs(), ALT_B, ALT_C), "B split from C")
assertTrue(SF.LootHelperIdentity.SameIdentity(profile:GetLootLogs(), ALT_A, ALT_C), "A and C remain linked after B split")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "relink B")
assertTrue(SF.LootHelperIdentity.SameIdentity(profile:GetLootLogs(), ALT_B, ALT_C), "relink restores three-character identity")

-- Late historical relationship delivery: network order must not decide identity.
resetEnv()
profile = makeProfile("LateLink")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 2,
}, { timestamp = 1700000500 })
addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_B,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 3,
}, { timestamp = 1700000600 })
assertEq(memberOf(profile, ALT_A):GetPointBalance(), 2, "A has its own points before late LINK")
assertEq(memberOf(profile, ALT_B):GetPointBalance(), 3, "B has its own points before late LINK")
local lateLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { PLAYER },
}, { timestamp = 1700000100, counter = 40 })
local inserted = profile:MergeLogTables({ lateLink })
assertTrue(inserted > 0, "late CHARACTER_LINK is accepted")
assertEq(memberOf(profile, ALT_A):GetPointBalance(), 5, "late LINK still shares identity-wide points")
assertEq(memberOf(profile, ALT_B):GetPointBalance(), 5, "both rows show the same identity total")

-- ---------------------------------------------------------------------------
-- Admin semantics
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("AdminEager")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
profile:AddAdminMemberId(ALT_A)
assertTrue(profile:IsAdminMemberId(ALT_A), "A is canonical admin")
assertFalse(profile:IsAdminMemberId(ALT_B), "B is not yet admin")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link admin A with member B")
assertTrue(profile:IsAdminMemberId(ALT_B), "eager live propagation grants B")

resetEnv()
profile = makeProfile("AdminConcurrent")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
profile:AddAdminMemberId(ALT_A)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B")
assertTrue(profile:LinkCharacters(ALT_B, ALT_C), "B+C concurrent join")
assertTrue(profile:IsAdminMemberId(ALT_C), "C receives propagation through B")

resetEnv()
profile = makeProfile("AdminRemoval")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
profile:AddAdminMemberId(ALT_A)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "propagate to B")
assertTrue(profile:RemoveAdminMemberId(ALT_B), "explicit removal after propagation")
assertFalse(profile:IsAdminMemberId(ALT_B), "B is no longer admin")
local added = profile:ReconcileIdentityAdmins({ skipBroadcast = true })
assertEq(added, 0, "stale LINK evidence does not re-grant after explicit removal")
assertFalse(profile:IsAdminMemberId(ALT_B), "B stays removed")

addMember(profile, ALT_C)
profile:AddAdminMemberId(ALT_C)
assertTrue(profile:LinkCharacters(ALT_B, ALT_C), "later qualifying LINK after removal")
assertTrue(profile:IsAdminMemberId(ALT_B), "later qualifying LINK propagates again")

resetEnv()
profile = makeProfile("UnrelatedAdmin")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
profile:AddAdminMemberId(ALT_C)
assertTrue(profile:LinkCharacters(ALT_C, ALT_D), "unrelated admin identity C+D")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "later unrelated LINK A+B")
assertFalse(profile:IsAdminMemberId(ALT_A), "legacy/unlogged admin on another identity does not travel")
assertFalse(profile:IsAdminMemberId(ALT_B), "A+B remain non-admin")

resetEnv()
profile = makeProfile("NoBackwardGrant")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link before later grant")
assertFalse(profile:IsAdminMemberId(ALT_B), "B is not admin from a member+member LINK")
profile:AddAdminMemberId(ALT_A)
assertTrue(profile:IsAdminMemberId(ALT_A), "later explicit grant on A")
profile:ApplyIdentityProjection()
assertFalse(profile:IsAdminMemberId(ALT_B), "later explicit grant does not travel backward through an earlier LINK")
assertEq(profile:ReconcileIdentityAdmins({ skipBroadcast = true }), 0, "reconcile does not invent a backward grant")

resetEnv()
profile = makeProfile("OutOfComponent")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
profile:AddAdminMemberId(ALT_C)
local malformed = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_C },
}, { timestamp = 1700002000, counter = 30 })
assertTrue(profile:MergeLogTables({ malformed }) > 0, "malformed LINK with out-of-component admin is stored")
assertTrue(SF.LootHelperIdentity.SameIdentity(profile:GetLootLogs(), ALT_A, ALT_B), "A+B are linked")
assertFalse(profile:IsAdminMemberId(ALT_A), "out-of-component evidence does not grant A")
assertFalse(profile:IsAdminMemberId(ALT_B), "out-of-component evidence does not grant B")
assertTrue(profile:IsAdminMemberId(ALT_C), "unrelated admin identity is unchanged")
assertEq(profile:ReconcileIdentityAdmins({ skipBroadcast = true }), 0, "reconcile ignores out-of-component evidence")

resetEnv()
profile = makeProfile("MainSwapNoGrant")
addMember(profile, ALT_A)
addLog(profile, SF.LootLogEventTypes.MAIN_SWAP, {
    member = ALT_A,
    sourceMember = ALT_B,
}, { timestamp = 1700000100 })
profile:ApplyIdentityProjection()
assertTrue(memberOf(profile, ALT_B) ~= nil, "missing MAIN_SWAP source is restored")
assertFalse(profile:IsAdminMemberId(ALT_B), "MAIN_SWAP-only restored source receives no grant")
assertEq(profile:ReconcileIdentityAdmins({ skipBroadcast = true }), 0, "reconcile does not grant restored MAIN_SWAP source")

resetEnv()
profile = makeProfile("ReconcileIdempotent")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
profile:AddAdminMemberId(ALT_A)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link for reconcile")
local first = profile:ReconcileIdentityAdmins({ skipBroadcast = true })
local second = profile:ReconcileIdentityAdmins({ skipBroadcast = true })
assertTrue(first == 0 or first >= 0, "first reconcile is non-negative")
assertEq(second, 0, "second reconcile is a no-op")

resetEnv()
profile = makeProfile("CoordinatorFailover")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
profile:AddAdminMemberId(ALT_A)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B, { skipBroadcast = true }), "link on coordinator profile")
Sync.state.active = true
Sync.state.profileId = profile:GetProfileId()
Sync.state.isCoordinator = true
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
assertTrue(profile:IsAdminMemberId(ALT_B), "coordinator reconcile grants missing admin")
Sync.state.isCoordinator = false
local before = profile:IsAdminMemberId(ALT_B)
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
assertEq(profile:IsAdminMemberId(ALT_B), before, "non-coordinator failover does not mutate grants")

-- ---------------------------------------------------------------------------
-- Profile isolation and fail-closed mutators
-- ---------------------------------------------------------------------------
resetEnv()
local p1 = makeProfile("IsoOne")
addMember(p1, ALT_A)
assertTrue(p1:LinkCharacters(PLAYER, ALT_A), "profile one links owner+A")
addLog(p1, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 4,
})
local p2 = makeProfile("IsoTwo")
addMember(p2, ALT_A)
addLog(p2, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
})
assertEq(memberOf(p1, ALT_A):GetPointBalance(), memberOf(p1, PLAYER):GetPointBalance(), "p1 identity totals match")
assertEq(memberOf(p1, ALT_A):GetPointBalance(), 4, "p1 A has p1 history")
assertEq(memberOf(p2, ALT_A):GetPointBalance(), 1, "same Name-Realm in p2 has a different total")
assertFalse(SF.LootHelperIdentity.SameIdentity(p2:GetLootLogs(), PLAYER, ALT_A), "p2 does not inherit p1 identity")

setActive(p2)
local owner1 = memberOf(p1, PLAYER)
assertFalse(owner1:IncrementPoints({ amount = 1 }), "mutator without owning profile fails closed")
assertTrue(owner1:IncrementPoints({ amount = 1, profile = p1 }), "mutator with explicit p1 succeeds while UI active profile is p2")
assertEq(memberOf(p1, ALT_A):GetPointBalance(), 5, "p1 identity total changed")
assertEq(memberOf(p2, ALT_A):GetPointBalance(), 1, "active p2 is unchanged")

-- ---------------------------------------------------------------------------
-- Points and Attendance
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("Points")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 2,
})
addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_B,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 3,
})
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link for shared points")
assertEq(memberOf(profile, ALT_A):GetPointBalance(), 5, "shared identity points")
assertEq(memberOf(profile, ALT_B):GetPointBalance(), 5, "both rows display the same total")
local attributedA = 0
local attributedB = 0
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.POINT_CHANGE then
        local data = log:GetEventData()
        if data.member == ALT_A then
            attributedA = attributedA + 1
        elseif data.member == ALT_B then
            attributedB = attributedB + 1
        end
    end
end
assertTrue(attributedA >= 1 and attributedB >= 1, "character attribution is preserved on logs")
assertTrue(profile:UnlinkCharacter(ALT_B), "unlink splits retained histories")
assertEq(memberOf(profile, ALT_A):GetPointBalance(), 2, "A keeps A history after unlink")
assertEq(memberOf(profile, ALT_B):GetPointBalance(), 3, "B keeps B history after unlink")

resetEnv()
profile = makeProfile("Attendance")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
    reason = "RAID_CHECK",
})
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_B,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
    reason = "MANUAL",
})
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link attendance")
assertEq(memberOf(profile, ALT_A):GetAttendanceBalance(), 2, "every ATTENDANCE_CHANGE counts")
assertEq(memberOf(profile, ALT_B):GetAttendanceBalance(), 2, "identity-wide attendance")
assertTrue(memberOf(profile, ALT_A):DecrementAttendance({
    amount = 5,
    reason = "MANUAL",
    profile = profile,
}), "manual attendance decrement uses identity-wide clamp")
assertEq(memberOf(profile, ALT_A):GetAttendanceBalance(), 0, "attendance clamps at zero identity-wide")
assertEq(memberOf(profile, ALT_B):GetAttendanceBalance(), 0, "linked row shows the clamped total")
assertFalse(memberOf(profile, ALT_A):DecrementAttendance({
    amount = 1,
    reason = "MANUAL",
    profile = profile,
}), "cannot decrement below identity-wide zero")

-- ---------------------------------------------------------------------------
-- Equipment
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("EquipLegacy")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Head",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000200 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Head",
    action = SF.LootLogArmorActions.AVAILABLE,
}, { timestamp = 1700000300 })
assertTrue(armorOf(profile, ALT_A, "Head"), "legacy Head USED is character-local before link")
assertFalse(armorOf(profile, ALT_B, "Head"), "historical AVAILABLE on B does not clear A")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link after legacy equipment")
assertTrue(armorOf(profile, ALT_A, "Head"), "legacy Head remains occupied after link")
assertTrue(armorOf(profile, ALT_B, "Head"), "projected Head is identity-wide from A's local USED")

resetEnv()
profile = makeProfile("Rings")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000400 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000300 })
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link for chronological rings")
assertTrue(armorOf(profile, ALT_A, "Ring1"), "earliest ring usage projects to Ring1")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "second ring usage projects to Ring2")
assertEq(armorOf(profile, ALT_A, "Ring1"), armorOf(profile, ALT_B, "Ring1"), "linked rows share projected rings")

addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000500 })
local replay = SF.LootHelperIdentity.Replay(profile:GetLootLogs(), { owner = PLAYER })
local root = replay.identityOf[ALT_A][1]
assertTrue(replay.overflowByIdentity[root], "third ring usage is overflow")

resetEnv()
profile = makeProfile("PreserveRingSlots")
addMember(profile, ALT_A)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000300 })
profile:ApplyIdentityProjection()
assertFalse(armorOf(profile, ALT_A, "Ring1"), "lone Ring2 usage does not remap onto Ring1")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "lone Ring2 usage stays on Ring2")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring2", { profile = profile }), "clearing displayed Ring2")
assertFalse(armorOf(profile, ALT_A, "Ring2"), "original Ring2 usage can be cleared")
assertFalse(armorOf(profile, ALT_A, "Ring1"), "clearing Ring2 does not occupy Ring1")

resetEnv()
profile = makeProfile("PreserveTrinketSlots")
addMember(profile, ALT_A)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Trinket2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000310 })
profile:ApplyIdentityProjection()
assertFalse(armorOf(profile, ALT_A, "Trinket1"), "lone Trinket2 usage does not remap onto Trinket1")
assertTrue(armorOf(profile, ALT_A, "Trinket2"), "lone Trinket2 usage stays on Trinket2")

resetEnv()
profile = makeProfile("DistinctRingSlots")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000200 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000300 })
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link distinct ring slots")
assertTrue(armorOf(profile, ALT_A, "Ring1"), "earlier local Ring2 projects to linked opportunity 1")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "later local Ring1 projects to linked opportunity 2")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile }), "identity-scoped Ring1 clears projected opportunity 1")
assertFalse(armorOf(profile, ALT_A, "Ring1"), "projected Ring1 is cleared")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "projected Ring2 remains")
assertTrue(profile:UnlinkCharacter(ALT_A), "unlink restores character-local ring slots")
assertFalse(armorOf(profile, ALT_A, "Ring1"), "A has no local Ring1 after unlink")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "A's underlying local Ring2 reappears after unlink")
assertTrue(armorOf(profile, ALT_B, "Ring1"), "B keeps local Ring1 after unlink")
assertFalse(armorOf(profile, ALT_B, "Ring2"), "B has no local Ring2")

resetEnv()
profile = makeProfile("ReverseRingChronology")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000100 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000400 })
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link reversed ring chronology")
assertTrue(armorOf(profile, ALT_A, "Ring1"), "earlier B Ring1 projects to opportunity 1")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "later A Ring2 projects to opportunity 2")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring2", { profile = profile }), "manual linked Ring2 targets projected Ring2")
assertTrue(armorOf(profile, ALT_A, "Ring1"), "clearing projected Ring2 leaves opportunity 1")
assertFalse(armorOf(profile, ALT_A, "Ring2"), "projected Ring2 is cleared")

resetEnv()
profile = makeProfile("ManualSlots")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link for manual targeting")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring2", { profile = profile }), "manual Ring2 click")
assertFalse(armorOf(profile, ALT_A, "Ring1"), "Ring2 click does not fill empty Ring1")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "Ring2 is occupied")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Trinket2", { profile = profile }), "manual Trinket2 click")
assertFalse(armorOf(profile, ALT_A, "Trinket1"), "Trinket2 click does not fill empty Trinket1")
assertTrue(armorOf(profile, ALT_A, "Trinket2"), "Trinket2 is occupied")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile }), "manual Ring1 click")
assertTrue(armorOf(profile, ALT_A, "Ring1"), "explicit Ring1 targeting works")

resetEnv()
profile = makeProfile("IdentityMembers")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "original A+B identity")
assertEq(armorOf(profile, ALT_A, "Chest"), false, "unused ordinary slots stay false after projection")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "identity-wide Chest correction")
local correction = nil
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.ARMOR_CHANGE then
        local data = log:GetEventData()
        if data.scope == "identity" and data.slot == "Chest" then
            correction = data
        end
    end
end
assertTrue(correction ~= nil, "new shared correction stores identity scope")
if correction then
    assertEq(#correction.identityMembers, 2, "identityMembers records original membership")
end
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "unrelated C joins")
assertTrue(armorOf(profile, ALT_A, "Chest"), "adding C does not invalidate A+B correction")
assertTrue(armorOf(profile, ALT_C, "Chest"), "C sees the still-valid A+B correction")
assertTrue(profile:UnlinkCharacter(ALT_C), "removing later-added C")
assertTrue(armorOf(profile, ALT_A, "Chest"), "removing C does not invalidate A+B correction")
assertTrue(profile:UnlinkCharacter(ALT_B), "split original members")
assertFalse(armorOf(profile, ALT_A, "Chest"), "splitting original members invalidates the shared correction")
assertFalse(armorOf(profile, ALT_B, "Chest"), "B also loses the shared correction while split")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "re-link original membership")
assertFalse(armorOf(profile, ALT_A, "Chest"), "re-link does not resurrect a correction after an original-scope split")
assertFalse(armorOf(profile, ALT_B, "Chest"), "both original members stay without the expired correction")

resetEnv()
profile = makeProfile("IdentityMembersABC")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B before ABC correction")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "A+B+C identity")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A+B+C Chest correction")
assertTrue(armorOf(profile, ALT_A, "Chest"), "ABC Chest USED")
assertTrue(profile:UnlinkCharacter(ALT_C), "C leaves the original ABC scope")
assertFalse(armorOf(profile, ALT_A, "Chest"), "splitting any original ABC member expires the correction")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "later C relink")
assertFalse(armorOf(profile, ALT_A, "Chest"), "relinking C does not resurrect the expired ABC correction")
assertFalse(armorOf(profile, ALT_C, "Chest"), "C also does not see the expired ABC correction")

resetEnv()
profile = makeProfile("NoBackfill")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link for backfill guard")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile }), "fill Ring1")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring2", { profile = profile }), "fill Ring2")
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
    scope = "identity",
    identityMembers = { ALT_A, ALT_B },
}, { timestamp = 1700000900 })
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile }), "clear projected Ring1")
assertFalse(armorOf(profile, ALT_A, "Ring1"), "Ring1 is empty")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "overflow does not backfill Ring1")

local liveArmor = armorOf(profile, ALT_A, "Ring2")
profile:ApplyIdentityProjection()
assertEq(armorOf(profile, ALT_A, "Ring2"), liveArmor, "rebuild equals live ring state")

-- ---------------------------------------------------------------------------
-- MAIN_SWAP migration
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("SwapSimple")
addMember(profile, ALT_A)
addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 2,
})
addLog(profile, SF.LootLogEventTypes.MAIN_SWAP, {
    member = ALT_A,
    sourceMember = ALT_B,
})
profile:ApplyIdentityProjection()
assertTrue(memberOf(profile, ALT_B) ~= nil, "simple MAIN_SWAP restores source")
assertTrue(SF.LootHelperIdentity.SameIdentity(profile:GetLootLogs(), ALT_A, ALT_B), "MAIN_SWAP reconstructs lineage")
assertEq(memberOf(profile, ALT_A):GetPointBalance(), 2, "no duplicate MAIN_SWAP progression")
assertEq(memberOf(profile, ALT_B):GetPointBalance(), 2, "restored source shares derived total")
assertEq(memberOf(profile, ALT_B).class, nil, "unknown restored character fields remain unknown")
profile:ApplyIdentityProjection()
assertEq(memberOf(profile, ALT_A):GetPointBalance(), 2, "repeated migration is idempotent")

resetEnv()
profile = makeProfile("SwapChain")
addMember(profile, ALT_C)
addLog(profile, SF.LootLogEventTypes.MAIN_SWAP, {
    member = ALT_B,
    sourceMember = ALT_A,
})
addLog(profile, SF.LootLogEventTypes.MAIN_SWAP, {
    member = ALT_C,
    sourceMember = ALT_B,
})
profile:ApplyIdentityProjection()
assertTrue(SF.LootHelperIdentity.SameIdentity(profile:GetLootLogs(), ALT_A, ALT_C), "chained MAIN_SWAP reconstructs A+B+C")

-- ---------------------------------------------------------------------------
-- Fingerprints
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("Fingerprints")
local swapLog = makeTable(SF.LootLogEventTypes.MAIN_SWAP, {
    member = ALT_A,
    sourceMember = ALT_B,
}, { timestamp = 1700000100, counter = 2 })
local rewritten = {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}
local staleBase = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_B,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { timestamp = 1700000200, counter = 3 })
local stale = makeTable(SF.LootLogEventTypes.POINT_CHANGE, rewritten, { timestamp = 1700000200, counter = 3 })
stale._fingerprint = staleBase._fingerprint
assertTrue(stale._fingerprint ~= SF.LootLog.ComputeFingerprintFromTable(stale), "stale MAIN_SWAP fingerprint mismatches rewritten member")
local ok, err = SF.LootLog.ValidateTable(stale)
assertFalse(ok, "single NEW_LOG mismatch is rejected")
assertTrue(type(err) == "string" and err:find("fingerprint", 1, true) ~= nil, "strict incoming validation names the mismatch")
assertTrue(profile:MergeLogTables({ swapLog, stale }, { allowMainSwapFingerprintNormalize = true }) > 0, "known stale MAIN_SWAP fingerprint is repaired in batch import")
local repaired = nil
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.POINT_CHANGE then
        repaired = log
    end
end
assertTrue(repaired ~= nil, "rewritten point log imported")
assertEq(repaired:GetFingerprint(), SF.LootLog.ComputeFingerprintFromTable(repaired:ToTable()), "repaired fingerprint matches rewritten member")
local secondInserted = profile:MergeLogTables({ stale })
assertEq(secondInserted, 0, "second normalize pass is a no-op duplicate")

local chainedSwap1 = makeTable(SF.LootLogEventTypes.MAIN_SWAP, {
    member = ALT_B,
    sourceMember = ALT_C,
}, { timestamp = 1700000001, counter = 10 })
local chainedSwap2 = makeTable(SF.LootLogEventTypes.MAIN_SWAP, {
    member = ALT_A,
    sourceMember = ALT_B,
}, { timestamp = 1700000002, counter = 11 })
local ancestorBase = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_C,
    change = SF.LootLogPointChangeTypes.DECREMENT,
    amount = 1,
}, { timestamp = 1700000003, counter = 12 })
local chained = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.DECREMENT,
    amount = 1,
}, { timestamp = 1700000003, counter = 12 })
chained._fingerprint = ancestorBase._fingerprint
local chainProfile = makeProfile("ChainFp")
assertTrue(chainProfile:MergeLogTables({ chainedSwap1, chainedSwap2, chained }, { allowMainSwapFingerprintNormalize = true }) > 0, "chained ancestor fingerprint repair")

local unrelated = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { timestamp = 1700000700, counter = 20 })
unrelated._fingerprint = unrelated._fingerprint + 1
local badOk = SF.LootLog.ValidateTable(unrelated, {
    allowMainSwapFingerprintNormalize = true,
    mainSwapLineage = SF.LootHelperIdentity.BuildMainSwapLineage({ swapLog }),
})
assertFalse(badOk, "unrelated mismatch is not blessed")

local rcTable = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
}, { timestamp = 1700000800, counter = 21 })
rcTable._externalId = "rc-external"
rcTable._eventType = SF.LootLogEventTypes.RC_LOOT_COUNCIL
rcTable._data = {
    member = ALT_A,
    itemLink = "|cffa335ee|Hitem:1::::::::80:259:::::::::|h[X]|h|r",
    response = "Need",
    rcAwardId = "1",
    awardKey = "rc-external",
}
rcTable._id = "rc-external"
rcTable._fingerprint = 12345
assertFalse(SF.LootLog.TryNormalizeMainSwapStaleFingerprintTable(rcTable, {
    { source = ALT_B, target = ALT_A },
}), "external RC logs are not fingerprint-normalized")

local snapshot = profile:ExportSnapshot()
assertTrue(select(1, profile:ImportSnapshot(snapshot)), "snapshot round trip")
local roundTrip = makeProfile("Snapshot")
assertTrue(roundTrip:MergeLogTables(snapshot.lootLogs, { allowMainSwapFingerprintNormalize = true }) >= 0, "snapshot logs merge into another profile")
assertTrue(SF.LootHelperIdentity.SameIdentity(roundTrip:GetLootLogs(), ALT_A, ALT_B), "snapshot logs preserve MAIN_SWAP lineage")

-- Live NEW_LOG must not use batch fingerprint normalization.
resetEnv()
profile = makeProfile("LiveFp")
addMember(profile, ALT_A)
addLog(profile, SF.LootLogEventTypes.MAIN_SWAP, {
    member = ALT_A,
    sourceMember = ALT_B,
}, { timestamp = 1700000100 })
local liveStaleBase = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_B,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { timestamp = 1700000200, counter = 8 })
local liveStale = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { timestamp = 1700000200, counter = 8 })
liveStale._fingerprint = liveStaleBase._fingerprint
activateSession(profile)
local logsBefore = #(profile:GetLootLogs())
Sync:HandleNewLog(PLAYER, livePayload(profile, liveStale))
assertEq(#(profile:GetLootLogs()), logsBefore, "live NEW_LOG stale fingerprint is not inserted")
assertEq(profile:MergeLogTables({ liveStale }), 0, "live merge path does not normalize a lone stale fingerprint")
assertTrue(profile:MergeLogTables({ liveStale }, { allowMainSwapFingerprintNormalize = true }) > 0, "AUTH_LOGS/snapshot batch still normalizes known MAIN_SWAP fingerprints")
assertEq(profile:MergeLogTables({ liveStale }, { allowMainSwapFingerprintNormalize = true }), 0, "second batch normalization is idempotent")

-- ---------------------------------------------------------------------------
-- Unlink permissions, hyphenated realms, overflow warnings, eager grants
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("NonOwnerAdminLink")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
assertTrue(asPlayer(OTHER, function()
    return profile:LinkCharacters(ALT_A, ALT_B)
end), "non-owner admin can link a non-owner identity")
assertTrue(asPlayer(OTHER, function()
    return profile:UnlinkCharacter(ALT_B)
end), "non-owner admin can unlink a non-owner identity")
assertFalse(asPlayer(OTHER, function()
    return profile:LinkCharacters(OWNER, ALT_C)
end), "non-owner admin cannot link into the owner's identity")
assertTrue(profile:LinkCharacters(OWNER, ALT_C), "effective owner can link the owner identity")
assertFalse(asPlayer(OTHER, function()
    return profile:UnlinkCharacter(ALT_C)
end), "non-owner admin cannot unlink a member from the owner's identity")
assertTrue(profile:UnlinkCharacter(ALT_C), "effective owner can unlink from the owner identity")
assertFalse(asPlayer(ALT_A, function()
    return profile:LinkCharacters(ALT_A, ALT_B)
end), "ordinary non-admin cannot link")
assertFalse(asPlayer(ALT_A, function()
    return profile:UnlinkCharacter(ALT_B)
end), "ordinary non-admin cannot unlink")

resetEnv()
profile = makeProfile("HyphenRealm")
local hyphen = "Thrall-Azjol-Nerub"
addMember(profile, hyphen)
addMember(profile, ALT_A)
assertTrue(SF.LootLogValidators.ValidateCharacterLinkData({
    memberA = hyphen,
    memberB = ALT_A,
    adminMembersAtLink = { PLAYER },
}), "hyphenated realm identifiers are valid")
assertFalse(SF.LootLogValidators.ValidateCharacterLinkData({
    memberA = "Alpha-Garona",
    memberB = "alpha-Garona",
    adminMembersAtLink = {},
}), "SamePlayer duplicates are rejected")
assertFalse(SF.LootLogValidators.ValidateCharacterLinkData({
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ignored = PLAYER },
}), "keyed maps are not accepted as adminMembersAtLink arrays")
assertTrue(profile:LinkCharacters(hyphen, ALT_A), "live link accepts hyphenated realm names")

resetEnv()
profile = makeProfile("HyphenAdmin")
local hyphen = "Thrall-Azjol-Nerub"
addMember(profile, hyphen)
addMember(profile, ALT_A)
assertTrue(profile:AddAdminMemberId(ALT_A), "seed admin for hyphen propagation")
assertTrue(SF.LootLogValidators.ValidateAdminAddedData({ member = hyphen }), "ADMIN_ADDED accepts hyphenated realms")
assertTrue(profile:LinkCharacters(ALT_A, hyphen), "linking an admin identity to a hyphenated realm")
assertTrue(profile:IsAdminMemberId(hyphen), "hyphenated member is a canonical admin after live LINK")
local sawAdminAdded = false
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.ADMIN_ADDED then
        local data = log:GetEventData()
        if SF.NameUtil.SamePlayer(data.member, hyphen) then
            sawAdminAdded = true
        end
    end
end
assertTrue(sawAdminAdded, "propagation wrote a real ADMIN_ADDED log")
local rebuild = makeProfile("HyphenAdminRebuild")
local tables = {}
for _, log in ipairs(profile:GetLootLogs()) do
    tables[#tables + 1] = log:ToTable()
end
assertTrue(rebuild:MergeLogTables(tables) > 0, "peer/rebuild imports hyphen admin history")
rebuild._adminUsers = { rebuild:GetOwnerId() }
rebuild:ApplyIdentityProjection()
Sync:RebuildProfile(rebuild:GetProfileId(), "hyphen-rebuild")
assertTrue(rebuild:IsAdminMemberId(hyphen), "rebuild from logs reproduces the hyphenated grant")
assertTrue(profile:RemoveAdminMemberId(hyphen), "removing the hyphenated admin")
local sawAdminRemoved = false
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.ADMIN_REMOVED then
        local data = log:GetEventData()
        if SF.NameUtil.SamePlayer(data.member, hyphen) then
            sawAdminRemoved = true
        end
    end
end
assertTrue(sawAdminRemoved, "removal wrote ADMIN_REMOVED")
local afterRemove = makeProfile("HyphenAdminRemoved")
tables = {}
for _, log in ipairs(profile:GetLootLogs()) do
    tables[#tables + 1] = log:ToTable()
end
afterRemove:MergeLogTables(tables)
afterRemove._adminUsers = { afterRemove:GetOwnerId(), hyphen }
Sync:RebuildProfile(afterRemove:GetProfileId(), "hyphen-removed")
assertFalse(afterRemove:IsAdminMemberId(hyphen), "rebuild after ADMIN_REMOVED does not keep the grant")

resetEnv()
profile = makeProfile("AdminFailClosed")
addMember(profile, ALT_A)
local originalNew = SF.LootLog.new
SF.LootLog.new = function(eventType, ...)
    if eventType == SF.LootLogEventTypes.ADMIN_ADDED or eventType == SF.LootLogEventTypes.ADMIN_REMOVED then
        return nil
    end
    return originalNew(eventType, ...)
end
assertFalse(profile:AddAdminMemberId(ALT_A), "failed ADMIN_ADDED construction reports failure")
assertFalse(profile:IsAdminMemberId(ALT_A), "failed admin log write does not mutate _adminUsers")
SF.LootLog.new = originalNew
assertTrue(profile:AddAdminMemberId(ALT_A), "admin add succeeds after constructor is restored")
SF.LootLog.new = function(eventType, ...)
    if eventType == SF.LootLogEventTypes.ADMIN_REMOVED then
        return nil
    end
    return originalNew(eventType, ...)
end
assertFalse(profile:RemoveAdminMemberId(ALT_A), "failed ADMIN_REMOVED construction reports failure")
assertTrue(profile:IsAdminMemberId(ALT_A), "failed admin removal does not mutate _adminUsers")
SF.LootLog.new = originalNew
addMember(profile, ALT_B)
local originalAdd = profile.AddLootLog
profile.AddLootLog = function()
    return false
end
assertFalse(profile:AddAdminMemberId(ALT_B), "failed ADMIN_ADDED insert reports failure")
assertFalse(profile:IsAdminMemberId(ALT_B), "failed admin add insert does not mutate _adminUsers")
assertFalse(profile:RemoveAdminMemberId(ALT_A), "failed ADMIN_REMOVED insert reports failure")
assertTrue(profile:IsAdminMemberId(ALT_A), "failed admin removal insert does not mutate _adminUsers")
profile.AddLootLog = originalAdd

resetEnv()
profile = makeProfile("OverflowWarn")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000100 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000110 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000120 })
printed = {}
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "harmless link onto an already overflowing component")
assertEq(overflowWarningCount(), 0, "existing overflow does not warn again")

resetEnv()
profile = makeProfile("OverflowCountRing")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000100 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000110 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000120 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000130 })
printed = {}
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "existing ring overflow 1 plus another ring usage")
assertEq(overflowWarningCount(), 1, "ring overflow 1 -> 2 warns once")

resetEnv()
profile = makeProfile("OverflowCountChest")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Chest",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000100 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Chest",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000110 })
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "seed Chest overflow 1")
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_C,
    slot = "Chest",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000120 })
printed = {}
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "existing Chest overflow 1 plus another Chest usage")
assertEq(overflowWarningCount(), 1, "Chest overflow 1 -> 2 warns once")

resetEnv()
profile = makeProfile("OverflowNewChest")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000100 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000110 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000120 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Chest",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000130 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Chest",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000140 })
printed = {}
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "pre-existing ring overflow plus a new Chest conflict")
assertEq(overflowWarningCount(), 1, "new Chest conflict warns once even when a ring overflow already existed")

resetEnv()
profile = makeProfile("OverflowNewRing")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Head",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000100 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Head",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000110 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000120 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000130 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000140 })
printed = {}
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "pre-existing Head conflict plus a new ring overflow")
assertEq(overflowWarningCount(), 1, "new ring overflow warns once even when a Head conflict already existed")
printed = {}
local mixedLogs = {}
for _, log in ipairs(profile:GetLootLogs()) do
    mixedLogs[#mixedLogs + 1] = log:ToTable()
end
makeProfile("OverflowMixedRebuild"):MergeLogTables(mixedLogs)
assertEq(overflowWarningCount(), 0, "replay of mixed conflict history is silent")

resetEnv()
profile = makeProfile("OverflowNew")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000100 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Ring2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000110 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Ring1",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000120 })
addLog(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Ring2",
    action = SF.LootLogArmorActions.USED,
}, { timestamp = 1700000130 })
printed = {}
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "two full ring sets merge into overflow")
assertEq(overflowWarningCount(), 1, "new merge conflict warns the initiator once")
local overflowLogs = {}
for _, log in ipairs(profile:GetLootLogs()) do
    overflowLogs[#overflowLogs + 1] = log:ToTable()
end
printed = {}
local rebuildProfile = makeProfile("OverflowRebuild")
rebuildProfile:MergeLogTables(overflowLogs)
assertEq(overflowWarningCount(), 0, "rebuild of the same history is silent")

resetEnv()
profile = makeProfile("EagerScope")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
profile:AddAdminMemberId(ALT_A)
local impliedY = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_A },
}, { timestamp = 1700000400, counter = 20 })
assertTrue(profile:MergeLogTables({ impliedY }) > 0, "identity Y link arrives without eager grants")
assertFalse(profile:IsAdminMemberId(ALT_B), "Y's implied admin is not yet canonical")
assertTrue(profile:LinkCharacters(ALT_C, ALT_D), "live LINK only in unrelated identity X")
assertFalse(profile:IsAdminMemberId(ALT_B), "LINK in X does not eagerly grant Y")
assertTrue(profile:ReconcileIdentityAdmins({ skipBroadcast = true }) >= 1, "coordinator reconcile later grants Y when safe")
assertTrue(profile:IsAdminMemberId(ALT_B), "Y grant is persisted by reconcile")

-- ---------------------------------------------------------------------------
-- Live NEW_LOG owner-identity and loot-mode authorization
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("LiveLinkAuth")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
activateSession(profile)
local liveNonOwnerLink = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, liveNonOwnerLink))
assertTrue(profile:AreSameIdentity(ALT_A, ALT_B), "normal admin live LINK in a non-owner identity is accepted")

local liveOwnerLink = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_A,
    adminMembersAtLink = { OWNER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, liveOwnerLink))
assertFalse(profile:AreSameIdentity(OWNER, ALT_A), "normal admin live LINK into owner identity is not applied")

assertTrue(profile:LinkCharacters(OWNER, ALT_C), "owner links an alt")
local liveOwnerUnlink = liveTable(profile, SF.LootLogEventTypes.CHARACTER_UNLINK, {
    member = ALT_C,
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, liveOwnerUnlink))
assertTrue(profile:AreSameIdentity(OWNER, ALT_C), "normal admin live UNLINK from owner identity is rejected")

local ownerLiveUnlink = liveTable(profile, SF.LootLogEventTypes.CHARACTER_UNLINK, {
    member = ALT_C,
}, OWNER)
Sync:HandleNewLog(OWNER, livePayload(profile, ownerLiveUnlink))
assertFalse(profile:AreSameIdentity(OWNER, ALT_C), "effective owner live UNLINK is accepted")

local bulkOwnerLink = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_A,
    adminMembersAtLink = { OWNER },
}, OWNER, 1700000100)
assertTrue(profile:MergeLogTables({ bulkOwnerLink }) > 0, "bulk repair of already-authoritative owner LINK is accepted")
assertTrue(profile:AreSameIdentity(OWNER, ALT_A), "repair/bulk history is not owner-gated like live NEW_LOG")

resetEnv()
profile = makeProfile("OwnerAltLootMode")
addMember(profile, ALT_A)
addLog(profile, SF.LootLogEventTypes.MAIN_SWAP, {
    member = PLAYER,
    sourceMember = ALT_A,
})
profile:ApplyIdentityProjection()
assertTrue(profile:IsEffectiveOwner(ALT_A), "MAIN_SWAP-linked alt is effective owner")
assertFalse(profile:IsAdminMemberId(ALT_A), "MAIN_SWAP does not grant canonical admin")
assertTrue(asPlayer(ALT_A, function()
    return profile:SetLootMode("reward_pot")
end), "effective owner alt can create loot-mode change")
assertFalse(asPlayer(ALT_A, function()
    return memberOf(profile, ALT_A):IncrementPoints({ amount = 1, profile = profile })
end), "effective owner is not a general admin")
activateSession(profile)
local liveLoot = liveTable(profile, SF.LootLogEventTypes.LOOT_MODE_CHANGE, {
    oldMode = "reward_pot",
    newMode = "point_based",
}, ALT_A)
Sync:HandleNewLog(ALT_A, livePayload(profile, liveLoot))
assertEq(profile:GetLootMode(), "point_based", "effective owner live loot-mode change is accepted")
local strangerLoot = liveTable(profile, SF.LootLogEventTypes.LOOT_MODE_CHANGE, {
    oldMode = "point_based",
    newMode = "reward_pot",
}, ALT_B)
Sync:HandleNewLog(ALT_B, livePayload(profile, strangerLoot))
assertEq(profile:GetLootMode(), "point_based", "non-owner/non-admin cannot send loot-mode change")
addMember(profile, ALT_B)
assertFalse(asPlayer(ALT_A, function()
    return profile:LinkCharacters(ALT_A, ALT_B)
end), "effective owner without canonical admin cannot LINK")
assertFalse(asPlayer(ALT_A, function()
    return profile:LinkCharacters(OWNER, ALT_B)
end), "effective owner without canonical admin cannot LINK the owner identity")
local seedOwnerLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_B,
    adminMembersAtLink = { OWNER },
}, { timestamp = 1700000800, counter = 30 })
assertTrue(profile:MergeLogTables({ seedOwnerLink }) > 0, "bulk owner LINK does not eagerly grant")
assertFalse(profile:IsAdminMemberId(ALT_A), "MAIN_SWAP alt is still not a canonical admin")
assertFalse(asPlayer(ALT_A, function()
    return profile:UnlinkCharacter(ALT_B)
end), "effective owner without canonical admin cannot UNLINK")
local ownerLinkData = SF.LootLog.GetEventDataTemplate(SF.LootLogEventTypes.CHARACTER_LINK)
ownerLinkData.memberA = OWNER
ownerLinkData.memberB = ALT_B
ownerLinkData.adminMembersAtLink = { ALT_A }
assertFalse(asPlayer(ALT_A, function()
    return SF.LootLog.new(SF.LootLogEventTypes.CHARACTER_LINK, ownerLinkData, { profile = profile })
end), "LootLog.new rejects LINK from effective owner without canonical admin")
local ownerUnlinkData = SF.LootLog.GetEventDataTemplate(SF.LootLogEventTypes.CHARACTER_UNLINK)
ownerUnlinkData.member = ALT_B
assertFalse(asPlayer(ALT_A, function()
    return SF.LootLog.new(SF.LootLogEventTypes.CHARACTER_UNLINK, ownerUnlinkData, { profile = profile })
end), "LootLog.new rejects UNLINK from effective owner without canonical admin")

-- ---------------------------------------------------------------------------
-- Coordinator reconcile completeness gate
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("ReconcileGap")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.ADMIN_ADDED, {
    member = ALT_A,
}, { timestamp = 1700000200, counter = 2 })
-- Intentionally skip counter 3.
local gapLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_A },
}, { timestamp = 1700000500, counter = 5 })
assertTrue(profile:MergeLogTables({ gapLink }) > 0, "LINK arrives while older counters are missing")
activateSession(profile)
Sync.state.authorMax = { [OWNER] = 5 }
assertFalse(Sync:IsIdentityAdminReconcileReady(profile:GetProfileId()), "older sequential gap blocks reconcile")
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
assertFalse(profile:IsAdminMemberId(ALT_B), "LINK with a gap does not persist implied admin")
addLog(profile, SF.LootLogEventTypes.ADMIN_REMOVED, {
    member = ALT_A,
}, { timestamp = 1700000300, counter = 3 })
addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { timestamp = 1700000400, counter = 4 })
Sync:RebuildProfile(profile:GetProfileId(), "repair")
Sync.state.authorMax = Sync:ComputeAuthorMax(profile:GetProfileId())
assertTrue(Sync:IsIdentityAdminReconcileReady(profile:GetProfileId()), "history is complete after missing events arrive")
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
assertFalse(profile:IsAdminMemberId(ALT_B), "replay with ADMIN_REMOVED does not persist an erroneous grant")
assertFalse(profile:IsAdminMemberId(ALT_A), "explicit removal remains in force")

resetEnv()
profile = makeProfile("ReconcileRepair")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
profile:AddAdminMemberId(ALT_A)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B, { skipBroadcast = true }), "link while repair is pending")
activateSession(profile)
Sync.state.repairQueue = {
    order = { "pending" },
    items = {
        pending = { profileId = profile:GetProfileId(), author = PLAYER, fromCounter = 2, toCounter = 3 },
    },
}
assertFalse(Sync:IsIdentityAdminReconcileReady(profile:GetProfileId()), "queued integrity repair blocks reconcile")
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
Sync.state.isCoordinator = false
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
assertTrue(profile:IsAdminMemberId(ALT_B), "eager grant from the live LINK remains; failover does not add another")
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state.isCoordinator = true
local beforeReconcileLogs = #(profile:GetLootLogs())
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
assertEq(#(profile:GetLootLogs()), beforeReconcileLogs, "eager grant plus later reconcile does not duplicate ADMIN_ADDED")
assertEq(profile:ReconcileIdentityAdmins({ skipBroadcast = true }), 0, "second reconcile remains idempotent")

resetEnv()
profile = makeProfile("ReconcileAdminConv")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
profile:AddAdminMemberId(ALT_A)
local impliedLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_A },
}, { timestamp = 1700000400, counter = (profile._authorCounters[OWNER] or 0) + 1 })
assertTrue(profile:MergeLogTables({ impliedLink }) > 0, "implied LINK without eager grant")
activateSession(profile)
Sync:BeginAdminConvergence(Sync.state.sessionId, profile:GetProfileId(), {
    onComplete = function() end,
})
assertTrue(type(Sync.state._adminConvergence) == "table", "real _adminConvergence lifecycle is active")
assertFalse(Sync:IsIdentityAdminReconcileReady(profile:GetProfileId()), "active _adminConvergence blocks identity-admin persistence")
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
assertFalse(profile:IsAdminMemberId(ALT_B), "blocked reconcile does not persist yet")
Sync:_FinishAdminConvergence("complete")
assertTrue(profile:IsAdminMemberId(ALT_B), "reconcile applies automatically when admin convergence finishes")
local afterWakeLogs = #(profile:GetLootLogs())
assertEq(profile:ReconcileIdentityAdmins({ skipBroadcast = true }), 0, "wake-up grant is not duplicated")
assertEq(#(profile:GetLootLogs()), afterWakeLogs, "no duplicate canonical ADMIN_ADDED writes")

resetEnv()
profile = makeProfile("ReconcileAdminLogReq")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
profile:AddAdminMemberId(ALT_A)
impliedLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_A },
}, { timestamp = 1700000400, counter = (profile._authorCounters[OWNER] or 0) + 1 })
assertTrue(profile:MergeLogTables({ impliedLink }) > 0, "implied LINK waiting on ADMIN_LOG_REQ")
activateSession(profile)
local reqId = "admin-log-req-1"
Sync.state.requests[reqId] = {
    id = reqId,
    kind = "ADMIN_LOG_REQ",
    meta = { profileId = profile:GetProfileId() },
    attempt = 1,
}
assertFalse(Sync:IsIdentityAdminReconcileReady(profile:GetProfileId()), "pending ADMIN_LOG_REQ blocks persistence")
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
assertFalse(profile:IsAdminMemberId(ALT_B), "ADMIN_LOG_REQ block does not persist yet")
Sync:CompleteRequest(reqId)
assertTrue(profile:IsAdminMemberId(ALT_B), "request completion wakes deferred reconcile")
Sync.state.isCoordinator = false
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
assertTrue(profile:IsAdminMemberId(ALT_B), "coordinator failover abandons pending reconcile without a second grant")

-- ---------------------------------------------------------------------------
-- Projection cache / helper performance
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("ProjectionCache")
addMember(profile, ALT_A)
assertTrue(profile:LinkCharacters(PLAYER, ALT_A), "link for cache helpers")
SF.LootHelperIdentity.replayCount = 0
assertEq(#profile:GetIdentityMembers(ALT_A), 2, "identity members helper returns the linked group")
assertTrue(profile:AreSameIdentity(PLAYER, ALT_A), "cached same-identity helper")
assertEq(profile:GetIdentityPoints(ALT_A), profile:GetIdentityPoints(PLAYER), "cached identity points")
assertEq(SF.LootHelperIdentity.replayCount, 0, "repeated helper reads do not replay history")
local beforeUnrelated = SF.LootHelperIdentity.replayCount
addLog(profile, SF.LootLogEventTypes.PROFILE_NAME_CHANGE, {
    oldName = profile:GetProfileName(),
    newName = "ProjectionCache2",
})
assertEq(SF.LootHelperIdentity.replayCount, beforeUnrelated, "unrelated log does not replay identity")
local beforePoints = SF.LootHelperIdentity.replayCount
addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 2,
})
assertEq(SF.LootHelperIdentity.replayCount, beforePoints, "live point change fans out without a full replay")
assertEq(profile:GetIdentityPoints(PLAYER), profile:GetIdentityPoints(ALT_A), "fan-out keeps identity totals aligned")

-- Out-of-order Attendance must replay. A live decrement that already hit the
-- zero floor plus a later-inserted earlier increment would otherwise stay at 1.
resetEnv()
profile = makeProfile("OutOfOrderAttendance")
addMember(profile, ALT_A)
assertTrue(profile:LinkCharacters(PLAYER, ALT_A), "link for out-of-order attendance")
local laterTs = GetServerTime() + 10000
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.DECREMENT,
    amount = 1,
}, { timestamp = laterTs })
assertEq(profile:GetIdentityAttendance(ALT_A), 0, "live decrement floors at zero")
SF.LootHelperIdentity.replayCount = 0
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { timestamp = laterTs - 50 })
assertTrue(SF.LootHelperIdentity.replayCount > 0, "out-of-order attendance forces a full replay")
assertEq(profile:GetIdentityAttendance(ALT_A), 0, "replay applies earlier increment before later decrement")
assertEq(profile:GetIdentityAttendance(PLAYER), 0, "linked identity attendance stays aligned after replay")
local beforeInOrderAttendance = SF.LootHelperIdentity.replayCount
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 2,
}, { timestamp = laterTs + 50 })
assertEq(SF.LootHelperIdentity.replayCount, beforeInOrderAttendance, "in-order attendance still fans out")
assertEq(profile:GetIdentityAttendance(ALT_A), 2, "in-order attendance fan-out updates the cached total")

-- ---------------------------------------------------------------------------
-- Permission matrix
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("PermMatrix")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
addMember(profile, OTHER)
addLog(profile, SF.LootLogEventTypes.MAIN_SWAP, {
    member = OWNER,
    sourceMember = ALT_A,
})
profile:ApplyIdentityProjection()
profile:AddAdminMemberId(OTHER)
profile:AddAdminMemberId(ALT_C)
assertTrue(profile:LinkCharacters(ALT_C, ALT_D, { skipPermission = true, skipBroadcast = true }), "seed another linked identity")
activateSession(profile)

assertTrue(asPlayer(OWNER, function()
    return profile:SetLootMode("reward_pot")
end), "canonical owner can change loot mode")
assertTrue(asPlayer(ALT_A, function()
    return profile:SetLootMode("point_based")
end), "linked effective-owner alt can change loot mode")
assertFalse(asPlayer(OTHER, function()
    return profile:SetLootMode("reward_pot")
end), "canonical non-owner admin cannot change loot mode")
assertFalse(asPlayer(ALT_C, function()
    return profile:SetLootMode("reward_pot")
end), "admin in another identity cannot change loot mode")
assertFalse(asPlayer(ALT_B, function()
    return profile:SetLootMode("reward_pot")
end), "ordinary non-admin cannot change loot mode")
assertTrue(asPlayer(OWNER, function()
    return memberOf(profile, ALT_B):IncrementPoints({ amount = 1, profile = profile })
end), "canonical owner can change points")
assertFalse(asPlayer(ALT_A, function()
    return memberOf(profile, ALT_B):IncrementPoints({ amount = 1, profile = profile })
end), "effective owner alt cannot perform unrelated admin point actions")
assertTrue(asPlayer(OTHER, function()
    return memberOf(profile, ALT_B):IncrementPoints({ amount = 1, profile = profile })
end), "canonical non-owner admin can change points")
assertTrue(asPlayer(ALT_C, function()
    return memberOf(profile, ALT_B):IncrementPoints({ amount = 1, profile = profile })
end), "admin in another identity can still perform admin point actions")
assertFalse(asPlayer(ALT_B, function()
    return memberOf(profile, ALT_B):IncrementPoints({ amount = 1, profile = profile })
end), "ordinary non-admin cannot change points")
assertFalse(asPlayer(ALT_B, function()
    return profile:LinkCharacters(ALT_B, ALT_C)
end), "ordinary non-admin cannot LINK")
assertFalse(asPlayer(ALT_A, function()
    return profile:LinkCharacters(ALT_B, ALT_C)
end), "effective owner cannot manage an unrelated identity without admin")
assertTrue(asPlayer(OTHER, function()
    return profile:LinkCharacters(ALT_B, ALT_C)
end), "canonical non-owner admin can LINK a non-owner identity")
assertTrue(profile:AreSameIdentity(ALT_B, ALT_C), "B joined C's identity")
assertTrue(asPlayer(ALT_C, function()
    return profile:UnlinkCharacter(ALT_B)
end), "admin in that linked identity can UNLINK it")
assertFalse(profile:AreSameIdentity(ALT_B, ALT_C), "B is split from C after unlink")
assertTrue(asPlayer(OWNER, function()
    return profile:LinkCharacters(OWNER, ALT_B)
end), "canonical owner can LINK into owner identity")
assertTrue(profile:AreSameIdentity(OWNER, ALT_B), "B joined the owner identity")
assertFalse(profile:AreSameIdentity(OWNER, ALT_C), "linking B does not pull C into the owner identity")
assertFalse(asPlayer(OTHER, function()
    return profile:UnlinkCharacter(ALT_B)
end), "canonical non-owner admin cannot UNLINK owner identity")
assertFalse(asPlayer(ALT_C, function()
    return profile:UnlinkCharacter(ALT_B)
end), "admin in another identity cannot UNLINK owner identity")
assertFalse(asPlayer(ALT_D, function()
    return profile:UnlinkCharacter(ALT_B)
end), "ordinary member of another identity cannot UNLINK owner identity")
assertTrue(asPlayer(ALT_A, function()
    return profile:UnlinkCharacter(ALT_B)
end), "effective-owner alt with canonical admin can UNLINK owner identity")

local liveLinkOther = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_B,
    memberB = ALT_C,
    adminMembersAtLink = { OTHER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, liveLinkOther))
assertTrue(profile:AreSameIdentity(ALT_B, ALT_C), "non-owner admin live LINK of a non-owner identity is accepted")
local liveOwnerByC = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_C },
}, ALT_C)
Sync:HandleNewLog(ALT_C, livePayload(profile, liveOwnerByC))
assertFalse(profile:AreSameIdentity(OWNER, ALT_B), "admin in another identity cannot live-LINK the owner identity")

resetEnv()
local ownerThenA = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_A,
    adminMembersAtLink = { OWNER },
}, { author = OWNER, counter = 2, timestamp = 1700002000 })
local adminThenB = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, { author = OTHER, counter = 1, timestamp = 1700002010 })

local peerFirst = makeProfile("ReorderFirst")
addMember(peerFirst, ALT_A)
addMember(peerFirst, ALT_B)
addMember(peerFirst, OTHER)
peerFirst._adminUsers = { OWNER, OTHER }
activateSession(peerFirst)
Sync.state.authorMax[OWNER] = ownerThenA._counter
Sync:HandleNewLog(OWNER, livePayload(peerFirst, ownerThenA))
Sync:HandleNewLog(OTHER, livePayload(peerFirst, adminThenB))
assertTrue(peerFirst:AreSameIdentity(OWNER, ALT_A), "owner LINK is kept")
assertFalse(peerFirst:AreSameIdentity(ALT_A, ALT_B), "later admin LINK into owner identity is rejected")

local peerSecond = makeProfile("ReorderSecond")
addMember(peerSecond, ALT_A)
addMember(peerSecond, ALT_B)
addMember(peerSecond, OTHER)
peerSecond._adminUsers = { OWNER, OTHER }
activateSession(peerSecond)
Sync.state.authorMax[OWNER] = ownerThenA._counter
Sync:HandleNewLog(OTHER, livePayload(peerSecond, adminThenB))
assertFalse(peerSecond:AreSameIdentity(ALT_A, ALT_B), "admin LINK is deferred while owner predecessor is missing")
Sync:HandleNewLog(OWNER, livePayload(peerSecond, ownerThenA))
assertTrue(peerSecond:AreSameIdentity(OWNER, ALT_A), "owner predecessor is accepted")
assertFalse(peerSecond:AreSameIdentity(ALT_A, ALT_B), "flushed admin LINK still cannot join the owner identity")
local rebuildLogs = {}
for _, log in ipairs(peerFirst:GetLootLogs()) do
    rebuildLogs[#rebuildLogs + 1] = log:ToTable()
end
local rebuilt = makeProfile("ReorderRebuild")
rebuilt:MergeLogTables(rebuildLogs)
assertTrue(rebuilt:AreSameIdentity(OWNER, ALT_A), "rebuild matches live accepted owner LINK")
assertFalse(rebuilt:AreSameIdentity(ALT_A, ALT_B), "rebuild matches live rejected owner-identity LINK")

resetEnv()
local peerMember = makeProfile("ReorderMember")
addMember(peerMember, ALT_A)
addMember(peerMember, ALT_B)
addMember(peerMember, OTHER)
peerMember._adminUsers = { OWNER, OTHER }
activateSession(peerMember)
Sync.state.isCoordinator = false
Sync.state.authorMax[OWNER] = ownerThenA._counter
Sync:HandleNewLog(OTHER, livePayload(peerMember, adminThenB))
assertFalse(peerMember:AreSameIdentity(ALT_A, ALT_B), "non-coordinator defers admin LINK while owner predecessor is missing")
Sync:HandleNewLog(OWNER, livePayload(peerMember, ownerThenA))
assertTrue(peerMember:AreSameIdentity(OWNER, ALT_A), "non-coordinator applies owner predecessor without coordinator reconcile")
assertFalse(peerMember:AreSameIdentity(ALT_A, ALT_B), "non-coordinator flush still rejects owner-identity LINK")

resetEnv()
local peerKnown = makeProfile("ReorderKnownMax")
addMember(peerKnown, ALT_A)
addMember(peerKnown, ALT_B)
addMember(peerKnown, OTHER)
peerKnown._adminUsers = { OWNER, OTHER }
activateSession(peerKnown)
Sync.state.authorMax[OWNER] = ownerThenA._counter
Sync.state.authorMax[OTHER] = adminThenB._counter
local queuedRepairs = 0
local originalQueueRepair = Sync.QueueRepairRanges
function Sync:QueueRepairRanges(...)
    queuedRepairs = queuedRepairs + 1
    return true
end
Sync:HandleNewLog(OTHER, livePayload(peerKnown, adminThenB))
assertTrue(queuedRepairs > 0, "missing predecessor logs trigger catch-up rather than a permanent decision")
assertFalse(peerKnown:AreSameIdentity(ALT_A, ALT_B), "known authorMax for both authors still defers the later admin LINK")
Sync:HandleNewLog(OWNER, livePayload(peerKnown, ownerThenA))
assertTrue(peerKnown:AreSameIdentity(OWNER, ALT_A), "owner LINK applies when both author maxima were already advertised")
assertFalse(peerKnown:AreSameIdentity(ALT_A, ALT_B), "pending fill does not deadlock or accept the owner-identity LINK")
Sync.QueueRepairRanges = originalQueueRepair

resetEnv()
profile = makeProfile("LootLogNewOwnerGate")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
local nonOwnerData = SF.LootLog.GetEventDataTemplate(SF.LootLogEventTypes.CHARACTER_LINK)
nonOwnerData.memberA = ALT_A
nonOwnerData.memberB = ALT_B
nonOwnerData.adminMembersAtLink = { OTHER }
assertTrue(asPlayer(OTHER, function()
    return SF.LootLog.new(SF.LootLogEventTypes.CHARACTER_LINK, nonOwnerData, { profile = profile })
end), "LootLog.new allows a non-owner admin to LINK a non-owner identity")
local ownerIdentityData = SF.LootLog.GetEventDataTemplate(SF.LootLogEventTypes.CHARACTER_LINK)
ownerIdentityData.memberA = OWNER
ownerIdentityData.memberB = ALT_A
ownerIdentityData.adminMembersAtLink = { OTHER }
assertFalse(asPlayer(OTHER, function()
    return SF.LootLog.new(SF.LootLogEventTypes.CHARACTER_LINK, ownerIdentityData, { profile = profile })
end), "LootLog.new rejects a non-owner admin LINK into the owner identity")
assertTrue(profile:LinkCharacters(OWNER, ALT_A, { skipBroadcast = true }), "owner seeds an identity for UNLINK gate")
local unlinkOwnerData = SF.LootLog.GetEventDataTemplate(SF.LootLogEventTypes.CHARACTER_UNLINK)
unlinkOwnerData.member = ALT_A
assertFalse(asPlayer(OTHER, function()
    return SF.LootLog.new(SF.LootLogEventTypes.CHARACTER_UNLINK, unlinkOwnerData, { profile = profile })
end), "LootLog.new rejects a non-owner admin UNLINK from the owner identity")

resetEnv()
profile = makeProfile("MalformedLive")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile._adminUsers = { OWNER, OTHER }
activateSession(profile)
local malformedSame = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_A,
    adminMembersAtLink = { OTHER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, malformedSame))
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "malformed same-character live LINK is rejected")
local malformedMap = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ignored = OTHER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, malformedMap))
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "malformed adminMembersAtLink live LINK is rejected")
local missingMember = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = "Ghost-Garona",
    adminMembersAtLink = { OTHER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, missingMember))
assertFalse(profile:getMemberByID("Ghost-Garona"), "live LINK cannot introduce a missing profile member")
local malformedUnlink = liveTable(profile, SF.LootLogEventTypes.CHARACTER_UNLINK, {
    member = ALT_A,
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, malformedUnlink))
assertEq(#profile:GetIdentityMembers(ALT_A), 1, "live UNLINK of a singleton is rejected")

resetEnv()
profile = makeProfile("RemoteFanOut")
addMember(profile, ALT_A)
assertTrue(profile:LinkCharacters(OWNER, ALT_A), "link for remote fan-out")
activateSession(profile)
SF.LootHelperIdentity.replayCount = 0
local rebuilds = 0
local originalRebuild = Sync.RebuildProfile
function Sync:RebuildProfile(...)
    rebuilds = rebuilds + 1
    return originalRebuild(self, ...)
end
for i = 1, 3 do
    local livePoint = liveTable(profile, SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 1,
    }, OWNER)
    Sync:HandleNewLog(OWNER, livePayload(profile, livePoint))
end
assertEq(SF.LootHelperIdentity.replayCount, 0, "in-order remote point NEW_LOGs do not replay identity history")
assertEq(rebuilds, 0, "in-order remote point NEW_LOGs do not rebuild the profile once per award")
assertEq(profile:GetIdentityPoints(OWNER), profile:GetIdentityPoints(ALT_A), "remote fan-out keeps identity points aligned")
local lateAttendance = liveTable(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, OWNER, 1700000001)
Sync:HandleNewLog(OWNER, livePayload(profile, lateAttendance))
assertTrue(SF.LootHelperIdentity.replayCount > 0, "out-of-order remote Attendance still replays")
Sync.RebuildProfile = originalRebuild

local function seedRacePeer(name)
    local peer = makeProfile(name)
    addMember(peer, ALT_A)
    addMember(peer, ALT_B)
    addMember(peer, OTHER)
    peer:AddAdminMemberId(OTHER)
    activateSession(peer)
    Sync.state.isCoordinator = false
    Sync.state.authorMax = { [OWNER] = peer._authorCounters[OWNER] or 1 }
    return peer
end

local function assertOwnerIdentityOnly(peer, label)
    assertTrue(peer:AreSameIdentity(OWNER, ALT_A), label .. ": owner LINK is applied")
    assertFalse(peer:AreSameIdentity(ALT_A, ALT_B), label .. ": non-owner LINK into the owner identity is not applied")
    assertFalse(peer:IsAdminMemberId(ALT_B), label .. ": skipped A+B does not persist implied admin on B")
end

resetEnv()
local raceOwnerLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_A,
    adminMembersAtLink = { OWNER },
}, { author = OWNER, counter = 3, timestamp = 1700002000 })
local raceAdminLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, { author = OTHER, counter = 1, timestamp = 1700002010 })
local raceAB = seedRacePeer("RaceAB")
Sync:HandleNewLog(OTHER, livePayload(raceAB, raceAdminLink))
assertEq(#pendingList(raceAB), 0, "unadvertised owner predecessor does not defer A+B")
assertTrue(raceAB:AreSameIdentity(ALT_A, ALT_B), "A+B may apply until the owner predecessor arrives")
Sync:HandleNewLog(OWNER, livePayload(raceAB, raceOwnerLink))
assertOwnerIdentityOnly(raceAB, "AB then OA")

resetEnv()
local raceOA = seedRacePeer("RaceOA")
Sync:HandleNewLog(OWNER, livePayload(raceOA, raceOwnerLink))
Sync:HandleNewLog(OTHER, livePayload(raceOA, raceAdminLink))
assertOwnerIdentityOnly(raceOA, "OA then AB")

local replayAB = SF.LootHelperIdentity.Replay(raceAB:GetLootLogs(), { owner = OWNER })
local replayOA = SF.LootHelperIdentity.Replay(raceOA:GetLootLogs(), { owner = OWNER })
assertTrue(SF.LootHelperIdentity.SameIdentity(raceAB:GetLootLogs(), OWNER, ALT_A, replayAB), "Replay AB-first keeps owner identity")
assertFalse(SF.LootHelperIdentity.SameIdentity(raceAB:GetLootLogs(), ALT_A, ALT_B, replayAB), "Replay AB-first skips unauthorized A+B")
assertTrue(SF.LootHelperIdentity.SameIdentity(raceOA:GetLootLogs(), OWNER, ALT_A, replayOA), "Replay OA-first keeps owner identity")
assertFalse(SF.LootHelperIdentity.SameIdentity(raceOA:GetLootLogs(), ALT_A, ALT_B, replayOA), "Replay OA-first skips unauthorized A+B")

local bulkReplica = makeProfile("RaceBulk")
assertTrue(bulkReplica:MergeLogTables(copyLogTables(raceAB)) > 0, "bulk/AUTH_LOGS reconstructs the same relationship logs")
assertOwnerIdentityOnly(bulkReplica, "bulk")
local reloadReplica = rebuildFrom(raceOA, "RaceReload")
assertOwnerIdentityOnly(reloadReplica, "reload")

local function seedRaceCoordinator(name)
    local peer = seedRacePeer(name)
    Sync.state.isCoordinator = true
    return peer
end

resetEnv()
local raceCoordAB = seedRaceCoordinator("RaceCoordAB")
Sync:HandleNewLog(OTHER, livePayload(raceCoordAB, raceAdminLink))
assertTrue(raceCoordAB:AreSameIdentity(ALT_A, ALT_B), "coordinator may apply A+B until owner predecessor arrives")
assertFalse(raceCoordAB:IsAdminMemberId(ALT_B), "live_update does not persist implied admin from unadvertised-predecessor A+B")
Sync:HandleNewLog(OWNER, livePayload(raceCoordAB, raceOwnerLink))
assertOwnerIdentityOnly(raceCoordAB, "coordinator AB then OA")
Sync:ScheduleIdentityAdminReconcile(raceCoordAB:GetProfileId())
assertOwnerIdentityOnly(raceCoordAB, "coordinator reconcile after complete AB-first history")

resetEnv()
local raceCoordOA = seedRaceCoordinator("RaceCoordOA")
Sync:HandleNewLog(OWNER, livePayload(raceCoordOA, raceOwnerLink))
Sync:HandleNewLog(OTHER, livePayload(raceCoordOA, raceAdminLink))
assertOwnerIdentityOnly(raceCoordOA, "coordinator OA then AB")
Sync:ScheduleIdentityAdminReconcile(raceCoordOA:GetProfileId())
assertOwnerIdentityOnly(raceCoordOA, "coordinator reconcile after complete OA-first history")
assertEq(raceCoordAB:IsAdminMemberId(ALT_B), raceCoordOA:IsAdminMemberId(ALT_B), "both coordinator arrival orders agree on B admin")
assertFalse(raceCoordAB:AreSameIdentity(ALT_A, ALT_B), "both coordinator arrival orders skip unauthorized A+B")
assertFalse(raceCoordOA:AreSameIdentity(ALT_A, ALT_B), "OA-first coordinator also skips unauthorized A+B")

resetEnv()
profile = makeProfile("RaceUnlinkSeed")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
assertTrue(profile:LinkCharacters(OWNER, ALT_A, { skipBroadcast = true }), "seed owner identity for concurrent UNLINK")
local unlinkSeedLogs = copyLogTables(profile)
local ownerUnlinkA = makeTable(SF.LootLogEventTypes.CHARACTER_UNLINK, {
    member = ALT_A,
    preOpAuthorMax = SF.LootHelperIdentity.SnapshotPreOpAuthorMax(profile),
}, {
    author = OWNER,
    counter = (profile._authorCounters[OWNER] or 0) + 1,
    timestamp = 1700003100,
})
local adminUnlinkA = makeTable(SF.LootLogEventTypes.CHARACTER_UNLINK, {
    member = ALT_A,
    preOpAuthorMax = {},
}, {
    author = OTHER,
    counter = (profile._authorCounters[OTHER] or 0) + 1,
    timestamp = 1700003110,
})

local function seedUnlinkPeer(name)
    local peer = makeProfile(name)
    addMember(peer, ALT_A)
    addMember(peer, ALT_B)
    addMember(peer, OTHER)
    peer:MergeLogTables(unlinkSeedLogs)
    activateSession(peer)
    Sync.state.isCoordinator = false
    return peer
end

resetEnv()
local unlinkAdminFirst = seedUnlinkPeer("UnlinkAdminFirst")
Sync:HandleNewLog(OTHER, livePayload(unlinkAdminFirst, adminUnlinkA))
Sync:HandleNewLog(OWNER, livePayload(unlinkAdminFirst, ownerUnlinkA))
assertFalse(unlinkAdminFirst:AreSameIdentity(OWNER, ALT_A), "admin UNLINK first still ends unlinked after owner UNLINK")

resetEnv()
local unlinkOwnerFirst = seedUnlinkPeer("UnlinkOwnerFirst")
Sync:HandleNewLog(OWNER, livePayload(unlinkOwnerFirst, ownerUnlinkA))
Sync:HandleNewLog(OTHER, livePayload(unlinkOwnerFirst, adminUnlinkA))
assertFalse(unlinkOwnerFirst:AreSameIdentity(OWNER, ALT_A), "owner UNLINK first still ends unlinked")
local unlinkReload = rebuildFrom(unlinkAdminFirst, "UnlinkReload")
assertFalse(unlinkReload:AreSameIdentity(OWNER, ALT_A), "reload matches concurrent UNLINK result")

resetEnv()
profile = makeProfile("PendingSession")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile._adminUsers = { OWNER, OTHER }
activateSession(profile)
Sync.state.authorMax[OWNER] = 2
local deferredLink = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, deferredLink))
assertEq(#pendingList(profile), 1, "advertised missing predecessor defers LINK in session A")
assertEq(pendingList(profile)[1].sessionId, "SES1", "pending LINK stores the originating sessionId")
local pendingFromA = pendingList(profile)[1]
Sync:_ClearIdentitySessionBookkeeping("EndSession")
assertEq(#pendingList(profile), 0, "session reset discards deferred relationship work")
Sync.state.active = true
Sync.state.sessionId = "SES2"
Sync.state.profileId = profile:GetProfileId()
Sync.state.authorMax = { [OWNER] = 1, [OTHER] = 1 }
Sync:FlushPendingLiveRelationshipLogs(profile:GetProfileId())
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "session A pending LINK cannot execute in session B")

Sync._pendingLiveRelationship[profile:GetProfileId()] = { pendingFromA }
Sync.state.sessionId = "SES2"
Sync:FlushPendingLiveRelationshipLogs(profile:GetProfileId())
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "Flush refuses to rewrap session A work as session B")

resetEnv()
profile = makeProfile("PendingFailover")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile._adminUsers = { OWNER, OTHER }
activateSession(profile)
Sync.state.authorMax[OWNER] = 2
local failoverLink = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, failoverLink))
assertEq(#pendingList(profile), 1, "defer LINK before same-session takeover")
Sync.state.isCoordinator = false
Sync.state.coordinator = OTHER
assertEq(#pendingList(profile), 1, "same-session coordinator failover preserves pending work")
assertEq(pendingList(profile)[1].sessionId, "SES1", "failover pending still belongs to the same session")

resetEnv()
profile = makeProfile("PendingRestore")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile._adminUsers = { OWNER, OTHER }
activateSession(profile)
Sync.state.authorMax[OWNER] = 2
local restoreLink = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, restoreLink))
assertEq(#pendingList(profile), 1, "pending exists before persisted restore")
Sync:_ClearIdentitySessionBookkeeping("RestorePersistedSession")
assertEq(#pendingList(profile), 0, "persisted-session restore discards in-memory pending relationship work")

resetEnv()
profile = makeProfile("RejectBeforePending")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, OTHER)
profile._adminUsers = { OWNER }
activateSession(profile)
local repairCalls = 0
function Sync:QueueRepairRanges(...)
    repairCalls = repairCalls + 1
    return true
end
local nonAdminHigh = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_C },
}, { author = ALT_C, counter = 50, timestamp = 1700004000 })
Sync:HandleNewLog(ALT_C, livePayload(profile, nonAdminHigh))
assertEq(#pendingList(profile), 0, "non-admin high-counter LINK never enters pending")
assertEq(repairCalls, 0, "non-admin high-counter LINK does not request repair")

local nonAdminMissing = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_C },
}, { author = ALT_C, counter = 1, timestamp = 1700004010 })
Sync.state.authorMax[OWNER] = 9
Sync:HandleNewLog(ALT_C, livePayload(profile, nonAdminMissing))
assertEq(#pendingList(profile), 0, "non-admin LINK with missing predecessors never enters pending")
assertEq(repairCalls, 0, "non-admin missing-predecessor LINK does not request repair")

profile:AddAdminMemberId(OTHER)
local badFp = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, { author = OTHER, counter = 1, timestamp = 1700004020 })
badFp._fingerprint = (badFp._fingerprint or 1) + 1
Sync:HandleNewLog(OTHER, livePayload(profile, badFp))
assertEq(#pendingList(profile), 0, "admin LINK with bad fingerprint never enters pending")
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "bad fingerprint LINK is not applied")

local malformed = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, { author = OTHER, counter = 2, timestamp = 1700004030 })
malformed._data = "not-a-table"
Sync:HandleNewLog(OTHER, livePayload(profile, malformed))
assertEq(#pendingList(profile), 0, "malformed serialized LINK never enters pending")

local legit = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_C,
    adminMembersAtLink = { OTHER },
}, OTHER)
Sync.state.authorMax = Sync:ComputeAuthorMax(profile:GetProfileId()) or {}
Sync:HandleNewLog(OTHER, livePayload(profile, legit))
assertTrue(profile:AreSameIdentity(ALT_A, ALT_C), "later legitimate LINK is not skipped because of rejected junk")
assertEq(#pendingList(profile), 0, "legitimate LINK was not blocked by rejected pending contiguity")
Sync.QueueRepairRanges = function() return true end

resetEnv()
profile = makeProfile("TargetMaxTimeout")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile:AddAdminMemberId(ALT_A)
local impliedByA = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_A },
}, { author = ALT_A, timestamp = 1700000400, counter = 1 })
assertTrue(profile:MergeLogTables({ impliedByA }) > 0, "LINK waits on advertised ADMIN_REMOVED")
activateSession(profile)
Sync:BeginAdminConvergence(Sync.state.sessionId, profile:GetProfileId(), {
    onComplete = function() end,
})
Sync.state.adminStatuses = {
    [OTHER] = { authorMax = { [OTHER] = 1, [OWNER] = profile._authorCounters[OWNER] or 1, [ALT_A] = 1 } },
}
local removed = makeTable(SF.LootLogEventTypes.ADMIN_REMOVED, {
    member = ALT_A,
}, { author = OTHER, timestamp = 1700000300, counter = 1 })
Sync:FinalizeAdminConvergence()
assertTrue((Sync.state.authorMax[OTHER] or 0) >= 1, "convergence retains advertised OTHER maximum")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
assertFalse(Sync:IsIdentityAdminReconcileReady(profile:GetProfileId()), "advertised ADMIN_REMOVED keeps reconcile blocked")
Sync:_FinishAdminConvergence("timeout")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
assertFalse(Sync:IsIdentityAdminReconcileReady(profile:GetProfileId()), "timeout does not forget advertised predecessor history")
assertFalse(profile:IsAdminMemberId(ALT_B), "blocked reconcile does not persist implied admin")
assertTrue(profile:MergeLogTables({ removed }) > 0, "later repair delivers the advertised ADMIN_REMOVED")
Sync.state.authorMax = Sync:ComputeAuthorMax(profile:GetProfileId()) or Sync.state.authorMax
Sync:_MergeAuthorMaxFrontier({ [OTHER] = 1 })
assertTrue(Sync:IsIdentityAdminReconcileReady(profile:GetProfileId()), "reconcile may run after advertised history arrives")
Sync:ScheduleIdentityAdminReconcile(profile:GetProfileId())
assertFalse(profile:IsAdminMemberId(ALT_B), "result reflects ADMIN_REMOVED before the LINK")
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "unauthorized LINK after ADMIN_REMOVED is not applied")

resetEnv()
profile = makeProfile("TargetMaxRegisterFail")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile:AddAdminMemberId(ALT_A)
impliedByA = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_A },
}, { author = ALT_A, timestamp = 1700000400, counter = 1 })
assertTrue(profile:MergeLogTables({ impliedByA }) > 0, "LINK for register-failure frontier")
activateSession(profile)
Sync:BeginAdminConvergence(Sync.state.sessionId, profile:GetProfileId(), {
    onComplete = function() end,
})
Sync.state.adminStatuses = {
    [OTHER] = { authorMax = { [OTHER] = 1, [ALT_A] = 1 } },
}
local originalRegister = Sync.RegisterRequest
function Sync:RegisterRequest()
    return false
end
Sync:FinalizeAdminConvergence()
Sync.RegisterRequest = originalRegister
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
assertTrue((Sync.state.authorMax[OTHER] or 0) >= 1, "RegisterRequest failure still retains advertised targetMax")
assertFalse(Sync:IsIdentityAdminReconcileReady(profile:GetProfileId()), "register failure does not treat missing history as absent")

resetEnv()
profile = makeProfile("NoRetroGrant")
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addLog(profile, SF.LootLogEventTypes.MAIN_SWAP, {
    member = OWNER,
    sourceMember = ALT_B,
})
profile:ApplyIdentityProjection()
assertTrue(profile:IsEffectiveOwner(ALT_B), "MAIN_SWAP restored source is effective owner")
assertFalse(profile:IsAdminMemberId(ALT_B), "MAIN_SWAP restored source is not a canonical admin")
assertTrue(profile:LinkCharacters(OWNER, ALT_C), "later live LINK onto the migrated identity")
assertTrue(profile:IsAdminMemberId(ALT_C), "newly linked C receives canonical admin")
assertFalse(profile:IsAdminMemberId(ALT_B), "later LINK does not retro-grant the restored source")
local migratedReload = rebuildFrom(profile, "NoRetroGrantReload")
local migratedReplay = SF.LootHelperIdentity.Replay(migratedReload:GetLootLogs(), { owner = OWNER })
assertTrue(migratedReplay.simulatedAdmins[ALT_C] == true, "reload still grants C")
assertFalse(migratedReplay.simulatedAdmins[ALT_B] == true, "reload still leaves restored source non-admin")

resetEnv()
profile = makeProfile("NoRetroGrantMulti")
addMember(profile, ALT_B)
addMember(profile, ALT_D)
addMember(profile, ALT_E)
addLog(profile, SF.LootLogEventTypes.MAIN_SWAP, {
    member = OWNER,
    sourceMember = ALT_B,
})
profile:ApplyIdentityProjection()
assertTrue(profile:LinkCharacters(ALT_D, ALT_E, { skipBroadcast = true }), "non-admin opposite component")
assertTrue(profile:LinkCharacters(OWNER, ALT_D), "link admin side to multi-character opposite side")
assertTrue(profile:IsAdminMemberId(ALT_D), "joining opposite member D is granted")
assertTrue(profile:IsAdminMemberId(ALT_E), "joining opposite member E is granted")
assertFalse(profile:IsAdminMemberId(ALT_B), "restored source on the admin side remains non-admin")

resetEnv()
profile = makeProfile("ArmorChronology")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link for identity Chest")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "identity Chest USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "identity Chest AVAILABLE")
assertFalse(armorOf(profile, ALT_A, "Chest"), "shared Chest is available")
assertTrue(profile:UnlinkCharacter(ALT_A), "unlink before later local USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "later singleton Chest USED")
assertTrue(armorOf(profile, ALT_A, "Chest"), "singleton USED after unlink")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "relink after later local USED")
assertTrue(armorOf(profile, ALT_A, "Chest"), "older identity AVAILABLE does not erase later local USED")
assertTrue(armorOf(profile, ALT_B, "Chest"), "relinked partner sees the later USED")
local armorReload = rebuildFrom(profile, "ArmorChronologyReload")
assertTrue(armorOf(armorReload, ALT_A, "Chest"), "reload matches live later USED")
assertTrue(armorOf(armorReload, ALT_B, "Chest"), "reload partner matches live later USED")

resetEnv()
profile = makeProfile("ArmorChronologyReverse")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "link for reverse Chest")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "identity Chest USED")
assertTrue(armorOf(profile, ALT_A, "Chest"), "shared Chest is used")
assertTrue(profile:UnlinkCharacter(ALT_A), "unlink before later local AVAILABLE")
assertFalse(armorOf(profile, ALT_A, "Chest"), "identity USED is inactive while members are split")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "later singleton Chest USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "later singleton Chest AVAILABLE")
assertFalse(armorOf(profile, ALT_A, "Chest"), "singleton AVAILABLE after local USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "relink after later local AVAILABLE")
assertFalse(armorOf(profile, ALT_A, "Chest"), "older identity USED does not erase later local AVAILABLE")
assertFalse(armorOf(profile, ALT_B, "Chest"), "relinked partner sees the later AVAILABLE")
local armorReverseReload = rebuildFrom(profile, "ArmorChronologyReverseReload")
assertFalse(armorOf(armorReverseReload, ALT_A, "Chest"), "reload matches live later AVAILABLE")

local function runAuthorizationHardeningTests()

-- ---------------------------------------------------------------------------
-- Live NEW_LOG sender must equal relationship author
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("SenderAuthor")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
activateSession(profile)

local spoofOwner = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_B,
    adminMembersAtLink = { OWNER },
}, { author = OWNER, counter = 40, timestamp = 1700005000 })
Sync:HandleNewLog(OTHER, livePayload(profile, spoofOwner))
assertFalse(profile:AreSameIdentity(OWNER, ALT_B), "non-owner admin cannot spoof owner as relationship author")
assertEq(#pendingList(profile), 0, "spoofed owner author never enters pending")

local spoofAdmin = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, { author = ALT_A, counter = 1, timestamp = 1700005010 })
Sync:HandleNewLog(OTHER, livePayload(profile, spoofAdmin))
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "non-owner admin cannot spoof another admin as relationship author")

local ownerMismatch = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, { author = OTHER, counter = 2, timestamp = 1700005020 })
Sync:HandleNewLog(OWNER, livePayload(profile, ownerMismatch))
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "owner sender with mismatched author is rejected")

local matching = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, matching))
assertTrue(profile:AreSameIdentity(ALT_A, ALT_B), "matching sender/author valid non-owner LINK is accepted")

resetEnv()
profile = makeProfile("SenderAuthorPending")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
activateSession(profile)
Sync.state.authorMax[OWNER] = 9
local deferredMatch = liveTable(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, OTHER)
Sync:HandleNewLog(OTHER, livePayload(profile, deferredMatch))
assertEq(#pendingList(profile), 1, "matching sender/author LINK can still defer")
assertEq(pendingList(profile)[1].sender, OTHER, "pending preserves original sender")
local spoofWhilePending = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_A,
    adminMembersAtLink = { OWNER },
}, { author = OWNER, counter = 50, timestamp = 1700005100 })
Sync:HandleNewLog(OTHER, livePayload(profile, spoofWhilePending))
assertEq(#pendingList(profile), 1, "mismatched sender/author does not join pending")
Sync.state.authorMax = Sync:ComputeAuthorMax(profile:GetProfileId()) or {}
Sync:FlushPendingLiveRelationshipLogs(profile:GetProfileId())
assertTrue(profile:AreSameIdentity(ALT_A, ALT_B), "flush still enforces sender/author and applies the original matching LINK")
assertFalse(profile:AreSameIdentity(OWNER, ALT_A), "spoofed owner LINK remains rejected after flush")

resetEnv()
profile = makeProfile("SenderAuthorBulk")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
local bulkOwnerLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
}, { author = OTHER, counter = 3, timestamp = 1700005200 })
assertTrue(profile:MergeLogTables({ bulkOwnerLink }) > 0, "AUTH_LOGS/snapshot relay of another author's LINK is accepted")
assertTrue(profile:AreSameIdentity(ALT_A, ALT_B), "historical relay is not sender-bound")

-- ---------------------------------------------------------------------------
-- Writer-side eager ADMIN_ADDED is bound to the source LINK
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("WriterEagerGrant")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
profile:AddAdminMemberId(ALT_A)
assertTrue(asPlayer(OTHER, function()
    return profile:LinkCharacters(ALT_A, ALT_B, { skipBroadcast = true })
end), "writer X locally LINKs A+B before seeing O+A")
assertTrue(profile:AreSameIdentity(ALT_A, ALT_B), "incomplete local history applies A+B")
local sawSourcedGrant = false
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.ADMIN_ADDED then
        local data = log:GetEventData()
        if data.member == ALT_B and type(data.sourceLogId) == "string" and data.sourceLogId ~= "" then
            sawSourcedGrant = true
        end
    end
end
assertTrue(sawSourcedGrant, "eager grant records sourceLogId")
local hiddenOwnerLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_A,
    adminMembersAtLink = { OWNER },
}, { author = OWNER, counter = (profile._authorCounters[OWNER] or 1) + 1, timestamp = 1700000400 })
assertTrue(profile:MergeLogTables({ hiddenOwnerLink }) > 0, "earlier owner O+A arrives after writer LINK")
profile:ApplyIdentityProjection({ force = true })
assertTrue(profile:AreSameIdentity(OWNER, ALT_A), "complete history keeps owner LINK")
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "complete history skips writer A+B")
assertFalse(profile:IsAdminMemberId(ALT_B), "sourced ADMIN_ADDED does not survive a skipped LINK")
local writerReload = rebuildFrom(profile, "WriterEagerReload")
assertFalse(writerReload:IsAdminMemberId(ALT_B), "reload also drops the skipped LINK's auto-admin")
assertFalse(writerReload:AreSameIdentity(ALT_A, ALT_B), "reload topology matches")

resetEnv()
profile = makeProfile("UnlinkKeepsValidGrant")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
profile:AddAdminMemberId(ALT_A)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "valid LINK grants B")
assertTrue(profile:IsAdminMemberId(ALT_B), "B is canonical after valid LINK")
assertTrue(profile:UnlinkCharacter(ALT_B), "unlink after valid grant")
assertTrue(profile:IsAdminMemberId(ALT_B), "unlink does not revoke a previously valid grant")

-- ---------------------------------------------------------------------------
-- Legacy canonical admins without ADMIN_ADDED
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("LegacyAdmin")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile._adminUsers = { OWNER, OTHER }
profile:ApplyIdentityProjection({ force = true })
assertEq(SF.LootHelperIdentity.EnsureLegacyCanonicalAdmins(profile)[1], OTHER, "OTHER is frozen as a legacy canonical admin")
assertTrue(asPlayer(OTHER, function()
    return profile:LinkCharacters(ALT_A, ALT_B, { skipBroadcast = true })
end), "legacy MAIN_SWAP-style admin can create a non-owner LINK")
assertTrue(profile:AreSameIdentity(ALT_A, ALT_B), "live state keeps the legacy-admin LINK")
local legacyReload = rebuildFrom(profile, "LegacyAdminReload")
legacyReload._legacyCanonicalAdmins = { OTHER }
legacyReload._adminUsers = { OWNER, OTHER }
legacyReload:ApplyIdentityProjection({ force = true })
assertTrue(legacyReload:AreSameIdentity(ALT_A, ALT_B), "full rebuild keeps the legacy-admin LINK")
local snap = profile:ExportSnapshot()
local legacySnap = makeProfile("LegacyAdminSnap")
legacySnap._profileId = snap.meta._profileId
assertTrue(select(1, legacySnap:ImportSnapshot(snap)), "snapshot replica imports legacyCanonicalAdmins")
legacySnap:ApplyIdentityProjection({ force = true })
assertTrue(legacySnap:AreSameIdentity(ALT_A, ALT_B), "snapshot replica keeps the legacy-admin LINK")
assertEq((legacySnap._legacyCanonicalAdmins or {})[1], OTHER, "imported freeze list retains the legacy admin")
assertTrue(legacySnap:MergeLogTables(copyLogTables(profile)) >= 0, "AUTH_LOGS into snapshot replica")
assertTrue(legacySnap:AreSameIdentity(ALT_A, ALT_B), "AUTH_LOGS keeps the legacy-admin LINK")
assertTrue(profile:RemoveAdminMemberId(OTHER), "later explicit ADMIN_REMOVED works")
assertFalse(profile:IsAdminMemberId(OTHER), "legacy admin can be removed")

resetEnv()
profile = makeProfile("LegacyAdminOmittedFreeze")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile._adminUsers = { OWNER, OTHER }
local omittedSnap = profile:ExportSnapshot()
omittedSnap.legacyCanonicalAdmins = nil
omittedSnap.adminUsers = { OWNER, OTHER }
local omittedReplica = makeProfile("LegacyAdminOmittedFreezeSnap")
omittedReplica._profileId = omittedSnap.meta._profileId
assertTrue(select(1, omittedReplica:ImportSnapshot(omittedSnap)), "snapshot without freeze field still imports")
assertTrue(asPlayer(OTHER, function()
    return omittedReplica:LinkCharacters(ALT_A, ALT_B, { skipBroadcast = true })
end), "omitted freeze field still recovers legacy admin from adminUsers")
assertTrue(omittedReplica:AreSameIdentity(ALT_A, ALT_B), "recovered legacy admin LINK survives")

resetEnv()
profile = makeProfile("NoRetroAdmin")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
local earlyLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_C },
}, { author = ALT_C, counter = 1, timestamp = 1700000300 })
assertTrue(profile:MergeLogTables({ earlyLink }) > 0, "LINK predates ALT_C's grant")
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "later newly-added admin does not retroactively authorize an older LINK")
profile:AddAdminMemberId(ALT_C)
profile:ApplyIdentityProjection({ force = true })
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "adding ALT_C later still does not apply the older LINK")

-- ---------------------------------------------------------------------------
-- Causal Replay via preOpAuthorMax
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("CausalAdmin")
addMember(profile, ALT_A)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
local grant = addLog(profile, SF.LootLogEventTypes.ADMIN_ADDED, {
    member = ALT_A,
}, { timestamp = 1700007000, counter = 2 })
local causalLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_C,
    memberB = ALT_D,
    adminMembersAtLink = { ALT_A },
    preOpAuthorMax = {
        { author = OWNER, counter = grant:GetCounter() },
    },
}, { author = ALT_A, counter = 1, timestamp = 1700007000 })
assertTrue(profile:MergeLogTables({ causalLink }) > 0, "same-timestamp LINK after observed ADMIN_ADDED")
assertTrue(profile:AreSameIdentity(ALT_C, ALT_D), "causal order applies the LINK that observed ADMIN_ADDED")
local causalReload = rebuildFrom(profile, "CausalAdminReload")
assertTrue(causalReload:AreSameIdentity(ALT_C, ALT_D), "reload keeps causal ADMIN_ADDED -> LINK")

resetEnv()
profile = makeProfile("CausalAutoAdmin")
addMember(profile, ALT_A)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
assertTrue(profile:LinkCharacters(OWNER, ALT_A), "owner LINK implies auto-admin for A")
assertTrue(profile:IsAdminMemberId(ALT_A), "A received a sourced auto-admin grant")
local autoGrant
local ownerLinkId
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.ADMIN_ADDED then
        local data = log:GetEventData()
        if data.member == ALT_A and type(data.sourceLogId) == "string" and data.sourceLogId ~= "" then
            autoGrant = log
            ownerLinkId = data.sourceLogId
        end
    end
end
assertTrue(autoGrant ~= nil, "owner LINK wrote a sourced ADMIN_ADDED")
assertTrue(type(ownerLinkId) == "string" and ownerLinkId ~= "", "auto-admin sourceLogId points at the LINK")
local autoLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_C,
    memberB = ALT_D,
    adminMembersAtLink = { ALT_A },
    preOpAuthorMax = {
        { author = OWNER, counter = autoGrant:GetCounter() },
    },
}, { author = ALT_A, counter = 1, timestamp = autoGrant:GetTimestamp() })
assertTrue(profile:MergeLogTables({ autoLink }) > 0, "same-timestamp LINK after observed auto-admin grant")
assertTrue(profile:AreSameIdentity(ALT_C, ALT_D), "newly linked auto-admin can act once the grant is in the prefix")
assertTrue(rebuildFrom(profile, "CausalAutoAdminReload"):AreSameIdentity(ALT_C, ALT_D), "reload keeps auto-admin causal LINK")

resetEnv()
profile = makeProfile("CausalOwnerPred")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
local ownerPred = addLog(profile, SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_A,
    adminMembersAtLink = { OWNER },
    preOpAuthorMax = {},
}, { timestamp = 1700007100, counter = 4 })
local skippedIntoOwner = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OTHER },
    preOpAuthorMax = {
        { author = OWNER, counter = ownerPred:GetCounter() },
    },
}, { author = OTHER, counter = 3, timestamp = 1700007100 })
assertTrue(profile:MergeLogTables({ skippedIntoOwner }) > 0, "same-timestamp A+B that observed O+A is stored")
assertTrue(profile:AreSameIdentity(OWNER, ALT_A), "owner predecessor LINK remains")
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "Replay skips A+B because the writer had already observed O+A")
assertFalse(rebuildFrom(profile, "CausalOwnerPredReload"):AreSameIdentity(ALT_A, ALT_B), "reload also skips A+B after owner predecessor")

resetEnv()
local causalFirst = makeProfile("CausalArrive1")
addMember(causalFirst, ALT_A)
addMember(causalFirst, ALT_C)
addMember(causalFirst, ALT_D)
addMember(causalFirst, OTHER)
profile = causalFirst
local grant2 = addLog(profile, SF.LootLogEventTypes.ADMIN_ADDED, {
    member = ALT_A,
}, { timestamp = 1700007000, counter = 2 })
activateSession(profile)
local causalLive = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_C,
    memberB = ALT_D,
    adminMembersAtLink = { ALT_A },
    preOpAuthorMax = {
        { author = OWNER, counter = grant2:GetCounter() },
    },
}, { author = ALT_A, counter = 1, timestamp = 1700007000 })
Sync:HandleNewLog(ALT_A, livePayload(profile, causalLive))
assertTrue(profile:AreSameIdentity(ALT_C, ALT_D), "live receipt uses the same causal semantics")

resetEnv()
profile = makeProfile("CausalConcurrent")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
local linkAB = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OWNER },
    preOpAuthorMax = {},
}, { author = OWNER, counter = 8, timestamp = 1700008000 })
local linkCD = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_C,
    memberB = ALT_D,
    adminMembersAtLink = { OTHER },
    preOpAuthorMax = {},
}, { author = OTHER, counter = 2, timestamp = 1700008000 })
local concA = makeProfile("CausalConcA")
addMember(concA, ALT_A)
addMember(concA, ALT_B)
addMember(concA, ALT_C)
addMember(concA, ALT_D)
addMember(concA, OTHER)
concA:AddAdminMemberId(OTHER)
concA:MergeLogTables({ linkAB, linkCD })
local concB = makeProfile("CausalConcB")
addMember(concB, ALT_A)
addMember(concB, ALT_B)
addMember(concB, ALT_C)
addMember(concB, ALT_D)
addMember(concB, OTHER)
concB:AddAdminMemberId(OTHER)
concB:MergeLogTables({ linkCD, linkAB })
assertTrue(concA:AreSameIdentity(ALT_A, ALT_B), "concurrent independent LINK AB applies")
assertTrue(concA:AreSameIdentity(ALT_C, ALT_D), "concurrent independent LINK CD applies")
assertTrue(concB:AreSameIdentity(ALT_A, ALT_B), "opposite merge order keeps AB")
assertTrue(concB:AreSameIdentity(ALT_C, ALT_D), "opposite merge order keeps CD")

-- ---------------------------------------------------------------------------
-- Equipment corrections do not reach later joiners
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("ArmorFutureA")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Chest", { profile = profile }), "C independent Chest USED")
assertTrue(armorOf(profile, ALT_C, "Chest"), "C Chest USED before A+B correction")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B linked")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "A+B identity Chest USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "A+B identity Chest AVAILABLE")
assertFalse(armorOf(profile, ALT_A, "Chest"), "A+B Chest is available")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "C joins A+B")
assertTrue(armorOf(profile, ALT_C, "Chest"), "C's historical Chest USED is not erased by older A+B AVAILABLE")
assertTrue(armorOf(profile, ALT_A, "Chest"), "combined identity keeps C's USED")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_C), "Case A does not stack skipped AVAILABLE's earlier USED as overflow")
local futureAReload = rebuildFrom(profile, "ArmorFutureAReload")
assertTrue(armorOf(futureAReload, ALT_C, "Chest"), "reload Case A matches live")
local futureASnapExport = profile:ExportSnapshot()
local futureASnap = makeProfile("ArmorFutureASnap")
futureASnap._profileId = futureASnapExport.meta._profileId
assertTrue(select(1, futureASnap:ImportSnapshot(futureASnapExport)), "snapshot Case A")
futureASnap:ApplyIdentityProjection({ force = true })
assertTrue(armorOf(futureASnap, ALT_C, "Chest"), "snapshot Case A matches live")
assertTrue(futureASnap:MergeLogTables(copyLogTables(profile)) >= 0, "AUTH_LOGS Case A")
assertTrue(armorOf(futureASnap, ALT_C, "Chest"), "AUTH_LOGS Case A matches live")

resetEnv()
profile = makeProfile("ArmorFutureB")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B linked first")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "A+B identity Chest USED")
assertTrue(armorOf(profile, ALT_A, "Chest"), "A+B Chest USED")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Chest", { profile = profile }), "C independent Chest USED")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Chest", { profile = profile }), "C independent Chest AVAILABLE")
assertFalse(armorOf(profile, ALT_C, "Chest"), "C Chest AVAILABLE")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "C joins A+B after AVAILABLE")
assertTrue(armorOf(profile, ALT_A, "Chest"), "C's unrelated AVAILABLE does not suppress A+B USED")
assertTrue(armorOf(profile, ALT_C, "Chest"), "joiner sees the active shared USED")
local futureBReload = rebuildFrom(profile, "ArmorFutureBReload")
assertTrue(armorOf(futureBReload, ALT_A, "Chest"), "reload Case B matches live")
local futureBSnapExport = profile:ExportSnapshot()
local futureBSnap = makeProfile("ArmorFutureBSnap")
futureBSnap._profileId = futureBSnapExport.meta._profileId
assertTrue(select(1, futureBSnap:ImportSnapshot(futureBSnapExport)), "snapshot Case B")
futureBSnap:ApplyIdentityProjection({ force = true })
assertTrue(armorOf(futureBSnap, ALT_A, "Chest"), "snapshot Case B matches live")
assertTrue(futureBSnap:MergeLogTables(copyLogTables(profile)) >= 0, "AUTH_LOGS Case B")
assertTrue(armorOf(futureBSnap, ALT_A, "Chest"), "AUTH_LOGS Case B matches live")

resetEnv()
profile = makeProfile("ArmorFutureRing")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Ring1", { profile = profile }), "C independent Ring1 USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B for ring case")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile, scope = "identity" }), "A+B identity Ring1 USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile, scope = "identity" }), "A+B identity Ring1 AVAILABLE")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "C joins ring identity")
assertTrue(armorOf(profile, ALT_C, "Ring1") or armorOf(profile, ALT_C, "Ring2"), "C's ring usage remains after older A+B AVAILABLE")

resetEnv()
profile = makeProfile("ArmorFutureTrinket")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B for trinket case")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Trinket1", { profile = profile, scope = "identity" }), "A+B identity Trinket1 USED")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Trinket1", { profile = profile }), "C independent Trinket1 USED")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Trinket1", { profile = profile }), "C independent Trinket1 AVAILABLE")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "C joins trinket identity")
assertTrue(armorOf(profile, ALT_A, "Trinket1") or armorOf(profile, ALT_A, "Trinket2"), "C AVAILABLE does not suppress A+B trinket USED")

-- ---------------------------------------------------------------------------
-- Main Swap with failed MAIN_SWAP lineage log
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("OrphanSwap")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_B,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 3,
}, { timestamp = 1700000100 })
local hyphen = "Thrall-Azjol-Nerub"
assertTrue(SF.LootLogValidators.ValidateMainSwapData({
    member = ALT_A,
    sourceMember = hyphen,
}), "MAIN_SWAP validation accepts hyphenated realms")
for _, log in ipairs(profile:GetLootLogs()) do
    local data = log:GetEventData()
    if log:GetEventType() == SF.LootLogEventTypes.POINT_CHANGE and data.member == ALT_B then
        data.member = ALT_A
    end
end
assertTrue(profile:RemoveMemberById(ALT_B), "old TransferMemberHistory removed the source")
local rcAward = makeTable(SF.LootLogEventTypes.RC_LOOT_COUNCIL, {
    member = ALT_B,
    itemLink = "|cffa335ee|Hitem:1::::::::80:259:::::::::|h[X]|h|r",
    response = "Need",
    rcAwardId = "orphan-1",
    awardKey = "orphan-1",
}, { timestamp = 1700000200, counter = 0, author = "RCLootCouncil" })
rcAward._externalId = "orphan-1"
rcAward._id = "orphan-1"
rcAward._fingerprint = SF.LootLog.ComputeFingerprintFromTable(rcAward)
assertTrue(profile:MergeLogTables({ rcAward }, { allowUnknownEventType = true }) >= 0, "RC award still names the missing source")
profile:ApplyIdentityProjection({ force = true })
assertTrue(memberOf(profile, ALT_B) ~= nil, "missing source is restored as a shell")
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "no MAIN_SWAP lineage is not invented")
local sawRestoreWarn = false
for i = 1, #printed do
    if printed[i][1] == "warn" and tostring(printed[i][2]):find("no Main Swap lineage", 1, true) then
        sawRestoreWarn = true
    end
end
assertTrue(sawRestoreWarn, "admin warning is emitted for unrostered historical attribution")
end
runAuthorizationHardeningTests()

local function runCorrectnessHardeningTests()
-- ---------------------------------------------------------------------------
-- Redundant concurrent LINK is not an admin-propagation boundary
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("RedundantLink")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, OTHER)
profile:AddAdminMemberId(ALT_A)
profile:AddAdminMemberId(OTHER)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B linked with A admin")
assertTrue(profile:RemoveAdminMemberId(ALT_B), "B explicitly removed after the original LINK")
assertFalse(profile:IsAdminMemberId(ALT_B), "B remains non-admin after ADMIN_REMOVED")
local linkAC1 = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_C,
    adminMembersAtLink = { ALT_A },
    preOpAuthorMax = {},
}, { author = OTHER, counter = 4, timestamp = 1700009000 })
local linkAC2 = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_C,
    adminMembersAtLink = { ALT_A },
    preOpAuthorMax = {},
}, { author = ALT_A, counter = 8, timestamp = 1700009000 })
local redA = makeProfile("RedundantArriveA")
addMember(redA, ALT_A)
addMember(redA, ALT_B)
addMember(redA, ALT_C)
addMember(redA, OTHER)
redA:AddAdminMemberId(ALT_A)
redA:AddAdminMemberId(OTHER)
redA:LinkCharacters(ALT_A, ALT_B)
redA:RemoveAdminMemberId(ALT_B)
redA:MergeLogTables({ linkAC1, linkAC2 })
local redB = makeProfile("RedundantArriveB")
addMember(redB, ALT_A)
addMember(redB, ALT_B)
addMember(redB, ALT_C)
addMember(redB, OTHER)
redB:AddAdminMemberId(ALT_A)
redB:AddAdminMemberId(OTHER)
redB:LinkCharacters(ALT_A, ALT_B)
redB:RemoveAdminMemberId(ALT_B)
redB:MergeLogTables({ linkAC2, linkAC1 })
assertTrue(redA:AreSameIdentity(ALT_A, ALT_C), "first concurrent A+C applies")
assertTrue(redB:AreSameIdentity(ALT_A, ALT_C), "opposite arrival still unifies A+C")
assertFalse(redA:IsAdminMemberId(ALT_B), "redundant LINK does not re-grant explicitly removed B")
assertFalse(redB:IsAdminMemberId(ALT_B), "opposite order still leaves B non-admin")
local replayA = SF.LootHelperIdentity.Replay(redA:GetLootLogs(), { owner = OWNER })
assertTrue(replayA.simulatedAdmins[ALT_C], "C is implied by the topology-changing LINK")
assertFalse(replayA.simulatedAdmins[ALT_B], "B is not implied across the already-unified component")
assertTrue(redA:ReconcileIdentityAdmins({ skipBroadcast = true }) >= 1, "coordinator persists C from the qualifying LINK")
assertTrue(redA:IsAdminMemberId(ALT_C), "C crossing a real boundary is granted")
assertFalse(redA:IsAdminMemberId(ALT_B), "reconcile still leaves B non-admin")
local cGrantSource
for _, log in ipairs(redA:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.ADMIN_ADDED then
        local data = log:GetEventData()
        if data.member == ALT_C and type(data.sourceLogId) == "string" then
            cGrantSource = data.sourceLogId
        end
    end
end
assertTrue(cGrantSource == linkAC1._id or cGrantSource == linkAC2._id, "C's grant is sourced from one of the concurrent A+C LINKs")
assertTrue(replayA.impliedAdminSource[ALT_C] == cGrantSource, "reconcile uses the topology-changing LINK, not a same-component implication")
assertEq(redA:ReconcileIdentityAdmins({ skipBroadcast = true }), 0, "coordinator reconcile does not synthesize a grant from the redundant LINK")
redB:ReconcileIdentityAdmins({ skipBroadcast = true })
assertTrue(redB:IsAdminMemberId(ALT_C), "opposite order still grants C")
assertFalse(redB:IsAdminMemberId(ALT_B), "opposite order reconcile still leaves B non-admin")
assertFalse(rebuildFrom(redA, "RedundantReload"):IsAdminMemberId(ALT_B), "reload leaves B non-admin")
local redSnapExport = redA:ExportSnapshot()
local redSnap = makeProfile("RedundantSnap")
redSnap._profileId = redSnapExport.meta._profileId
assertTrue(select(1, redSnap:ImportSnapshot(redSnapExport)), "snapshot redundant LINK")
redSnap:ApplyIdentityProjection({ force = true })
assertFalse(redSnap:IsAdminMemberId(ALT_B), "snapshot leaves B non-admin")
assertTrue(redSnap:IsAdminMemberId(ALT_C), "snapshot still grants C")
assertTrue(redSnap:MergeLogTables(copyLogTables(redA)) >= 0, "AUTH_LOGS redundant LINK")
assertFalse(redSnap:IsAdminMemberId(ALT_B), "AUTH_LOGS leaves B non-admin")

resetEnv()
profile = makeProfile("RedundantTransitive")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
profile:AddAdminMemberId(ALT_A)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B")
assertTrue(profile:RemoveAdminMemberId(ALT_B), "B removed before transitive close")
assertTrue(profile:LinkCharacters(ALT_B, ALT_C), "B+C")
local closeAC = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_C,
    adminMembersAtLink = { ALT_A },
    preOpAuthorMax = {},
}, { author = OWNER, counter = 12, timestamp = 1700009100 })
assertTrue(profile:MergeLogTables({ closeAC }) > 0, "redundant A+C after transitive A+B / B+C")
assertTrue(profile:AreSameIdentity(ALT_A, ALT_C), "A+C already unified")
assertFalse(profile:IsAdminMemberId(ALT_B), "transitive redundant A+C does not grant B")

resetEnv()
profile = makeProfile("RedundantMainSwap")
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
addLog(profile, SF.LootLogEventTypes.MAIN_SWAP, {
    member = OWNER,
    sourceMember = ALT_B,
})
profile:ApplyIdentityProjection()
assertFalse(profile:IsAdminMemberId(ALT_B), "MAIN_SWAP-restored B is not admin")
assertTrue(profile:LinkCharacters(OWNER, ALT_C), "owner links C onto migrated identity")
local dupOwnerC = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = OWNER,
    memberB = ALT_C,
    adminMembersAtLink = { OWNER },
    preOpAuthorMax = {},
}, { author = OWNER, counter = 20, timestamp = 1700009200 })
assertTrue(profile:MergeLogTables({ dupOwnerC }) > 0, "duplicate owner+C LINK stored")
assertTrue(profile:IsAdminMemberId(ALT_C), "C is granted by the qualifying LINK")
assertFalse(profile:IsAdminMemberId(ALT_B), "MAIN_SWAP-restored B stays non-admin after redundant LINK")

resetEnv()
profile = makeProfile("RedundantWriterGrant")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, OTHER)
profile:AddAdminMemberId(ALT_A)
profile:AddAdminMemberId(OTHER)
assertTrue(asPlayer(OTHER, function()
    return profile:LinkCharacters(ALT_A, ALT_C, { skipBroadcast = true })
end), "writer OTHER LINKs A+C and eager-grants C")
assertTrue(profile:IsAdminMemberId(ALT_C), "writer grant made C canonical")
local writerGrantId
local writerLinkId
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.ADMIN_ADDED then
        local data = log:GetEventData()
        if data.member == ALT_C and type(data.sourceLogId) == "string" then
            writerGrantId = log:GetID()
            writerLinkId = data.sourceLogId
        end
    end
end
assertTrue(writerGrantId ~= nil, "writer emitted sourced ADMIN_ADDED for C")
local peerLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_C,
    adminMembersAtLink = { ALT_A },
    preOpAuthorMax = {},
}, { author = ALT_A, counter = 9, timestamp = 1700008900 })
assertTrue(profile:MergeLogTables({ peerLink }) > 0, "earlier concurrent A+C from A arrives")
profile:ApplyIdentityProjection({ force = true })
assertTrue(profile:AreSameIdentity(ALT_A, ALT_C), "both LINKs unify A+C")
assertTrue(profile:IsAdminMemberId(ALT_C), "writer-emitted sourced grant survives the redundant peer LINK")
local grantStillSourced = false
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetID() == writerGrantId then
        grantStillSourced = log:GetEventData().sourceLogId == writerLinkId
    end
end
assertTrue(grantStillSourced, "sourced ADMIN_ADDED is not discarded")

-- ---------------------------------------------------------------------------
-- Orphan MAIN_SWAP-less rewrite survives snapshot / AUTH_LOGS
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("OrphanFp")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
local rewrittenPoint = addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_B,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 3,
}, { timestamp = 1700000100 })
local rewrittenAttendance = addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_B,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 2,
}, { timestamp = 1700000101 })
assertTrue(memberOf(profile, ALT_B):ToggleEquipment("Chest", { profile = profile }), "source Chest USED before rewrite")
local rewrittenArmor
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.ARMOR_CHANGE then
        local data = log:GetEventData()
        if data.member == ALT_B and data.slot == "Chest" then
            rewrittenArmor = log
        end
    end
end
assertTrue(rewrittenArmor ~= nil, "captured character-local Chest log")
local originalFp = rewrittenPoint:GetFingerprint()
local originalAttFp = rewrittenAttendance:GetFingerprint()
local originalArmorFp = rewrittenArmor:GetFingerprint()
rewrittenPoint._data.member = ALT_A
rewrittenAttendance._data.member = ALT_A
rewrittenArmor._data.member = ALT_A
assertTrue(originalFp ~= SF.LootLog.ComputeFingerprintFromTable(rewrittenPoint:ToTable()), "cached fingerprint is stale after in-place rewrite")
assertTrue(originalAttFp == rewrittenAttendance:GetFingerprint(), "attendance fingerprint cache is left stale")
assertTrue(originalArmorFp == rewrittenArmor:GetFingerprint(), "armor fingerprint cache is left stale")
assertTrue(profile:RemoveMemberById(ALT_B), "source removed")
local orphanRc = makeTable(SF.LootLogEventTypes.RC_LOOT_COUNCIL, {
    member = ALT_B,
    itemLink = "|cffa335ee|Hitem:1::::::::80:259:::::::::|h[X]|h|r",
    response = "Need",
    rcAwardId = "orphan-fp-1",
    awardKey = "orphan-fp-1",
}, { timestamp = 1700000200, counter = 0, author = "RCLootCouncil" })
orphanRc._externalId = "orphan-fp-1"
orphanRc._id = "orphan-fp-1"
orphanRc._fingerprint = SF.LootLog.ComputeFingerprintFromTable(orphanRc)
assertTrue(profile:MergeLogTables({ orphanRc }, { allowUnknownEventType = true }) >= 0, "RC still names the missing source")
profile:ApplyIdentityProjection({ force = true })
assertTrue(memberOf(profile, ALT_B) ~= nil, "local migration restores the unrostered source shell")
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "no link is invented")
assertEq(memberOf(profile, ALT_A):GetPointBalance(), 3, "rewritten points remain on the target")
assertEq(memberOf(profile, ALT_A):GetAttendanceBalance(), 2, "rewritten Attendance remains on the target")
assertTrue(armorOf(profile, ALT_A, "Chest"), "rewritten Chest remains on the target")
local function hasEverySourceLog(src, dst)
    local present = {}
    for _, log in ipairs(dst:GetLootLogs()) do
        present[log:GetID()] = true
    end
    for _, log in ipairs(src:GetLootLogs()) do
        if not present[log:GetID()] then
            return false
        end
    end
    return true
end
local orphanExport = profile:ExportSnapshot()
local orphanSnap = makeProfile("OrphanFpSnap")
orphanSnap._profileId = orphanExport.meta._profileId
assertTrue(select(1, orphanSnap:ImportSnapshot(orphanExport)), "snapshot import retains rewritten sequential events")
orphanSnap:ApplyIdentityProjection({ force = true })
assertTrue(hasEverySourceLog(profile, orphanSnap), "snapshot keeps every sequential event")
assertEq(memberOf(orphanSnap, ALT_A):GetPointBalance(), 3, "snapshot points match")
assertEq(memberOf(orphanSnap, ALT_A):GetAttendanceBalance(), 2, "snapshot Attendance match")
assertTrue(armorOf(orphanSnap, ALT_A, "Chest"), "snapshot equipment matches")
assertFalse(orphanSnap:AreSameIdentity(ALT_A, ALT_B), "snapshot does not invent a link")
local authPeer = makeProfile("OrphanFpAuth")
assertTrue(authPeer:MergeLogTables(copyLogTables(profile), { allowMainSwapFingerprintNormalize = true }) > 0, "AUTH_LOGS/integrity-repair converges")
authPeer:ApplyIdentityProjection({ force = true })
assertTrue(hasEverySourceLog(profile, authPeer), "AUTH_LOGS keeps every sequential event")
assertEq(memberOf(authPeer, ALT_A) and memberOf(authPeer, ALT_A):GetPointBalance(), 3, "AUTH_LOGS points match")
assertEq(memberOf(authPeer, ALT_A) and memberOf(authPeer, ALT_A):GetAttendanceBalance(), 2, "AUTH_LOGS Attendance match")
assertTrue(armorOf(authPeer, ALT_A, "Chest"), "AUTH_LOGS equipment matches")
assertTrue(select(1, orphanSnap:ImportSnapshot(orphanExport)), "repeated snapshot import is idempotent")
profile:RebuildLogIndex()
assertEq(rewrittenPoint:GetFingerprint(), SF.LootLog.ComputeFingerprintFromTable(rewrittenPoint:ToTable()), "repeated repair recomputes the rewritten fingerprint")
local corrupt = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { timestamp = 1700000300, counter = 99 })
corrupt._fingerprint = 123456789
assertEq(profile:MergeLogTables({ corrupt }, { allowMainSwapFingerprintNormalize = true }), 0, "unrelated fingerprint corruption is still rejected")
local ambiguous = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 7,
}, { timestamp = 1700000310, counter = 100 })
local baseB = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_B,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 7,
}, { timestamp = 1700000310, counter = 100 })
ambiguous._fingerprint = baseB._fingerprint
assertFalse(SF.LootLog.TryNormalizeOrphanRewriteStaleFingerprintTable(ambiguous, {}), "no candidates does not guess")
assertFalse(SF.LootLog.TryNormalizeOrphanRewriteStaleFingerprintTable(ambiguous, { ALT_C, ALT_D }), "wrong candidates are not guessed")
assertTrue(SF.LootLog.TryNormalizeOrphanRewriteStaleFingerprintTable(ambiguous, { ALT_B, ALT_C, ALT_D }), "unique matching candidate proves the rewrite")

-- ---------------------------------------------------------------------------
-- Equipment corrections operate on recorded-scope contributions
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("ArmorScopeA")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A local legacy Chest USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "shared Chest AVAILABLE")
assertFalse(armorOf(profile, ALT_A, "Chest"), "A+B Chest is cleared")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Chest", { profile = profile }), "C independent Chest USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "C joins A+B")
assertTrue(armorOf(profile, ALT_C, "Chest"), "C local Chest contribution remains active")
assertTrue(armorOf(profile, ALT_A, "Chest"), "projected Chest is USED")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "A's suppressed Chest does not overflow with C")
local scopeAReload = rebuildFrom(profile, "ArmorScopeAReload")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(scopeAReload._identityProjection, ALT_A), "reload Case A overflow is still 0")
assertTrue(armorOf(scopeAReload, ALT_A, "Chest"), "reload projected Chest USED")
local scopeAExport = profile:ExportSnapshot()
local scopeASnap = makeProfile("ArmorScopeASnap")
scopeASnap._profileId = scopeAExport.meta._profileId
assertTrue(select(1, scopeASnap:ImportSnapshot(scopeAExport)), "snapshot scope A")
scopeASnap:ApplyIdentityProjection({ force = true })
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(scopeASnap._identityProjection, ALT_A), "snapshot overflow is 0")
assertTrue(scopeASnap:MergeLogTables(copyLogTables(profile)) >= 0, "AUTH_LOGS scope A")
assertTrue(armorOf(scopeASnap, ALT_A, "Chest"), "AUTH_LOGS projected Chest USED")

resetEnv()
profile = makeProfile("ArmorScopeOverflow")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A local Chest USED")
assertTrue(memberOf(profile, ALT_B):ToggleEquipment("Chest", { profile = profile }), "B local Chest USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B with two Chest uses")
assertTrue(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "two local Chests overflow before the clear")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "identity Chest AVAILABLE")
assertFalse(armorOf(profile, ALT_A, "Chest"), "cleared Chest stays empty despite leftover packed overflow")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "AVAILABLE suppresses that scope's overflow uses")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Chest", { profile = profile }), "C independent Chest USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "C joins after two-insider clear")
assertTrue(armorOf(profile, ALT_A, "Chest"), "C's Chest remains USED")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "suppressed A/B overflow does not resurrect with C")
local overflowReload = rebuildFrom(profile, "ArmorScopeOverflowReload")
assertTrue(armorOf(overflowReload, ALT_A, "Chest"), "reload projected Chest USED")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(overflowReload._identityProjection, ALT_A), "reload overflow stays 0")

resetEnv()
profile = makeProfile("ArmorScopeHead")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Head", { profile = profile }), "A local Head USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B head")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Head", { profile = profile, scope = "identity" }), "shared Head AVAILABLE")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Head", { profile = profile }), "C Head USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "C joins head identity")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "Head has no false overflow")

resetEnv()
profile = makeProfile("ArmorScopeRing")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile }), "A local Ring1 USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B ring")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile, scope = "identity" }), "shared Ring1 AVAILABLE")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Ring1", { profile = profile }), "C Ring1 USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "C joins ring identity")
assertTrue(armorOf(profile, ALT_C, "Ring1") or armorOf(profile, ALT_C, "Ring2"), "C ring opportunity remains")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "A's cleared ring does not overflow with C")

resetEnv()
profile = makeProfile("ArmorScopeMerge")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "A+B Chest USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "A+B Chest AVAILABLE")
assertTrue(profile:LinkCharacters(ALT_C, ALT_D), "C+D")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "C+D Chest USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "merge A+B with C+D")
assertTrue(armorOf(profile, ALT_C, "Chest"), "C+D scoped USED survives the merge")
assertTrue(armorOf(profile, ALT_A, "Chest"), "A sees C+D's scoped USED")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "A+B AVAILABLE still suppresses A/B without overflow")
local mergeReload = rebuildFrom(profile, "ArmorScopeMergeReload")
assertTrue(armorOf(mergeReload, ALT_C, "Chest"), "reload merge keeps C+D USED")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(mergeReload._identityProjection, ALT_A), "reload merge overflow is 0")
local mergeExport = profile:ExportSnapshot()
local mergeSnap = makeProfile("ArmorScopeMergeSnap")
mergeSnap._profileId = mergeExport.meta._profileId
assertTrue(select(1, mergeSnap:ImportSnapshot(mergeExport)), "snapshot merge")
mergeSnap:ApplyIdentityProjection({ force = true })
assertTrue(armorOf(mergeSnap, ALT_A, "Chest"), "snapshot merge keeps USED")
assertTrue(mergeSnap:MergeLogTables(copyLogTables(profile)) >= 0, "AUTH_LOGS merge")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(mergeSnap._identityProjection, ALT_A), "AUTH_LOGS merge overflow is 0")

-- ---------------------------------------------------------------------------
-- sourceLogId is a causal predecessor of sourced ADMIN_ADDED
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("SourceEdge")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
local linkL = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_A },
    preOpAuthorMax = {},
}, { author = OTHER, counter = 1, timestamp = 1700010000 })
assertTrue(profile:MergeLogTables({ linkL }) > 0, "X authors LINK L")
local sourcedGrant = makeTable(SF.LootLogEventTypes.ADMIN_ADDED, {
    member = ALT_B,
    sourceLogId = linkL._id,
}, { author = ALT_A, counter = 2, timestamp = 1700010000 })
assertTrue(profile:MergeLogTables({ sourcedGrant }) > 0, "coordinator writes sourced ADMIN_ADDED at the same timestamp")
local laterByB = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_C,
    memberB = ALT_D,
    adminMembersAtLink = { ALT_B },
    preOpAuthorMax = {
        { author = ALT_A, counter = 2 },
        { author = OTHER, counter = 1 },
    },
}, { author = ALT_B, counter = 1, timestamp = 1700010000 })
assertTrue(profile:MergeLogTables({ laterByB }) > 0, "B authors a later LINK after observing the grant")
assertTrue(profile:AreSameIdentity(ALT_A, ALT_B), "source LINK applies")
assertTrue(profile:IsAdminMemberId(ALT_B), "sourced grant becomes canonical")
assertTrue(profile:AreSameIdentity(ALT_C, ALT_D), "B's later valid LINK is authorized")
local edgeReload = rebuildFrom(profile, "SourceEdgeReload")
assertTrue(edgeReload:AreSameIdentity(ALT_C, ALT_D), "reload keeps B's later LINK")
local edgeExport = profile:ExportSnapshot()
local edgeSnap = makeProfile("SourceEdgeSnap")
edgeSnap._profileId = edgeExport.meta._profileId
assertTrue(select(1, edgeSnap:ImportSnapshot(edgeExport)), "snapshot source edge")
edgeSnap:ApplyIdentityProjection({ force = true })
assertTrue(edgeSnap:AreSameIdentity(ALT_C, ALT_D), "snapshot keeps B's later LINK")
assertTrue(edgeSnap:MergeLogTables(copyLogTables(profile)) >= 0, "AUTH_LOGS source edge")
assertTrue(edgeSnap:AreSameIdentity(ALT_C, ALT_D), "AUTH_LOGS keeps B's later LINK")
local reverse = makeProfile("SourceEdgeRev")
addMember(reverse, ALT_A)
addMember(reverse, ALT_B)
addMember(reverse, ALT_C)
addMember(reverse, ALT_D)
addMember(reverse, OTHER)
reverse:AddAdminMemberId(OTHER)
reverse:MergeLogTables({ laterByB, sourcedGrant, linkL })
assertTrue(reverse:AreSameIdentity(ALT_C, ALT_D), "opposite arrival still authorizes B's LINK")
resetEnv()
profile = makeProfile("SourceEdgeSkip")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
local skippedLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_A },
    preOpAuthorMax = {},
}, { author = ALT_C, counter = 1, timestamp = 1700010100 })
assertTrue(profile:MergeLogTables({ skippedLink }) > 0, "unauthorized LINK is stored")
local skippedGrant = makeTable(SF.LootLogEventTypes.ADMIN_ADDED, {
    member = ALT_B,
    sourceLogId = skippedLink._id,
}, { author = OWNER, counter = 8, timestamp = 1700010100 })
assertTrue(profile:MergeLogTables({ skippedGrant }) > 0, "sourced grant for skipped LINK is stored")
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "skipped source LINK remains unapplied")
assertFalse(profile:IsAdminMemberId(ALT_B), "sourced grant is invalid while the source LINK is skipped")

-- ---------------------------------------------------------------------------
-- OrderLogs is heap-based and deterministic
-- ---------------------------------------------------------------------------
resetEnv()
local scaleLogs = {}
local scaleCounters = {}
local scaleAuthors = { OWNER, ALT_A, OTHER, ALT_C }
for i = 1, 1000 do
    local author = scaleAuthors[(i % #scaleAuthors) + 1]
    scaleCounters[author] = (scaleCounters[author] or 0) + 1
    scaleLogs[i] = {
        _timestamp = 1700020000 + math.floor(i / 4),
        _author = author,
        _counter = scaleCounters[author],
        _eventType = SF.LootLogEventTypes.POINT_CHANGE,
        _data = {
            member = ALT_B,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 1,
        },
        _id = string.format("%s:%d", author, scaleCounters[author]),
    }
end
scaleLogs[#scaleLogs + 1] = {
    _timestamp = 1700020000,
    _author = OWNER,
    _counter = (scaleCounters[OWNER] or 0) + 1,
    _eventType = SF.LootLogEventTypes.CHARACTER_LINK,
    _data = {
        memberA = ALT_A,
        memberB = OTHER,
        adminMembersAtLink = { OWNER },
        preOpAuthorMax = { { author = ALT_A, counter = scaleCounters[ALT_A] or 1 } },
        sourceLogId = nil,
    },
    _id = string.format("%s:%d", OWNER, (scaleCounters[OWNER] or 0) + 1),
}
local ordered1 = SF.LootHelperIdentity.OrderLogs(scaleLogs)
local stats1 = SF.LootHelperIdentity.lastOrderStats
assertEq(stats1.n, #scaleLogs, "order stats record n")
assertTrue(stats1.heapOps < stats1.n * stats1.n / 8, "1000-log heap work is far below n^2")
assertTrue((stats1.edgeCalls or 0) >= (stats1.edgeInserts or 0), "edge inserts never exceed edge attempts")
assertTrue((stats1.edgeCalls or 0) < stats1.n * 8, "edge construction stays linear in n")
assertTrue(not stats1.cacheHit, "OrderLogs does not reuse a stale table-identity cache")
local orderedAgain = SF.LootHelperIdentity.OrderLogs(scaleLogs)
assertEq(#orderedAgain, #ordered1, "second order has the same length")
assertTrue(not SF.LootHelperIdentity.lastOrderStats.cacheHit, "in-place log replacement cannot be hidden by an OrderLogs cache")
local shuffled = {}
for i = 1, #scaleLogs do
    shuffled[i] = scaleLogs[i]
end
for i = #shuffled, 2, -1 do
    local j = (i % (i - 1)) + 1
    shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
end
local ordered2 = SF.LootHelperIdentity.OrderLogs(shuffled)
assertEq(#ordered2, #ordered1, "shuffled input yields the same length")
for i = 1, #ordered1 do
    assertEq(ordered1[i]._id, ordered2[i]._id, "order is independent of input permutation at " .. tostring(i))
end
local bigLogs = {}
local bigCounters = {}
for i = 1, 3000 do
    local author = scaleAuthors[(i % #scaleAuthors) + 1]
    bigCounters[author] = (bigCounters[author] or 0) + 1
    bigLogs[i] = {
        _timestamp = 1700030000 + math.floor(i / 5),
        _author = author,
        _counter = bigCounters[author],
        _eventType = SF.LootLogEventTypes.ATTENDANCE_CHANGE,
        _data = {
            member = ALT_D,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 1,
        },
        _id = string.format("%s:%d", author, bigCounters[author]),
    }
end
SF.LootHelperIdentity.OrderLogs(bigLogs)
local statsBig = SF.LootHelperIdentity.lastOrderStats
assertTrue(statsBig.heapOps < statsBig.n * statsBig.n / 10, "3000-log heap work is far below n^2")

-- ---------------------------------------------------------------------------
-- preOpAuthorMax canonicalizes SamePlayer author aliases
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("PreOpAlias")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
profile._authorCounters["Owner-Garona"] = 4
profile._authorCounters["owner-Garona"] = 6
profile._authorCounters["OWNER-Garona"] = 2
local frontier = SF.LootHelperIdentity.SnapshotPreOpAuthorMax(profile)
assertEq(#frontier, 1, "SamePlayer author aliases collapse to one frontier entry")
assertEq(frontier[1].counter, 6, "highest observed alias counter is retained")
assertTrue(SF.LootLogValidators.ValidateCharacterLinkData({
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OWNER },
    preOpAuthorMax = frontier,
}), "SnapshotPreOpAuthorMax is accepted by ValidatePreOpAuthorMax")
local aliasEarly = {
    _timestamp = 1700040000,
    _author = "owner-Garona",
    _counter = 6,
    _eventType = SF.LootLogEventTypes.ADMIN_ADDED,
    _data = { member = ALT_A },
    _id = "owner-Garona:6",
}
local aliasLink = {
    _timestamp = 1700040000,
    _author = OTHER,
    _counter = 1,
    _eventType = SF.LootLogEventTypes.CHARACTER_LINK,
    _data = {
        memberA = ALT_C,
        memberB = ALT_D,
        adminMembersAtLink = { ALT_A },
        preOpAuthorMax = { { author = "OWNER-Garona", counter = 6 } },
    },
    _id = OTHER .. ":1",
}
addMember(profile, ALT_C)
addMember(profile, ALT_D)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
assertTrue(profile:MergeLogTables({
    {
        version = 2,
        _timestamp = aliasEarly._timestamp,
        _author = aliasEarly._author,
        _counter = aliasEarly._counter,
        _eventType = aliasEarly._eventType,
        _data = aliasEarly._data,
        _id = aliasEarly._id,
        _fingerprint = SF.LootLog.ComputeFingerprintFromTable(aliasEarly),
    },
    {
        version = 2,
        _timestamp = aliasLink._timestamp,
        _author = aliasLink._author,
        _counter = aliasLink._counter,
        _eventType = aliasLink._eventType,
        _data = aliasLink._data,
        _id = aliasLink._id,
        _fingerprint = SF.LootLog.ComputeFingerprintFromTable(aliasLink),
    },
}) > 0, "alias authors share one causal stream")
assertTrue(profile:AreSameIdentity(ALT_C, ALT_D), "canonical author keys keep one causal stream")
end
runCorrectnessHardeningTests()

local function runStateMachinePassTests()
local ALT_F = "Foxtrot-Garona"

local function checkSurfaces(profile, name, check)
    check(profile, "live")
    local reload = rebuildFrom(profile, name .. "Reload")
    check(reload, "reload")
    local export = profile:ExportSnapshot()
    local snap = makeProfile(name .. "Snap")
    snap._profileId = export.meta._profileId
    assertTrue(select(1, snap:ImportSnapshot(export)), name .. " snapshot import")
    snap:ApplyIdentityProjection({ force = true })
    check(snap, "snapshot")
    assertTrue(snap:MergeLogTables(copyLogTables(profile)) >= 0, name .. " AUTH_LOGS merge")
    check(snap, "AUTH_LOGS")
end

local function assertAdminState(p, label)
    assertTrue(p:AreSameIdentity(OWNER, ALT_A), label .. ": O+A linked")
    assertTrue(p:AreSameIdentity(ALT_B, ALT_C), label .. ": B+C linked")
    assertFalse(p:AreSameIdentity(OWNER, ALT_B), label .. ": B is not in owner identity")
    assertFalse(p:IsAdminMemberId(ALT_B), label .. ": B is not admin")
    assertFalse(p:IsAdminMemberId(ALT_C), label .. ": C is not admin")
end

local function seedRejectedGrantHistory(target)
    addMember(target, ALT_A)
    addMember(target, ALT_B)
    addMember(target, ALT_C)
    addMember(target, OTHER)
    target:AddAdminMemberId(OTHER)
    local linkOA = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
        memberA = OWNER,
        memberB = ALT_A,
        adminMembersAtLink = { OWNER },
        preOpAuthorMax = {},
    }, { author = OWNER, counter = 3, timestamp = 1700002000 })
    local linkL1 = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
        memberA = ALT_A,
        memberB = ALT_B,
        adminMembersAtLink = { OTHER },
        preOpAuthorMax = {},
    }, { author = OTHER, counter = 1, timestamp = 1700002100 })
    local grantG1 = makeTable(SF.LootLogEventTypes.ADMIN_ADDED, {
        member = ALT_B,
        sourceLogId = linkL1._id,
    }, { author = OTHER, counter = 2, timestamp = 1700002110 })
    local linkL2 = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
        memberA = ALT_B,
        memberB = ALT_C,
        adminMembersAtLink = { ALT_B },
        preOpAuthorMax = { { author = OTHER, counter = 2 } },
    }, { author = OTHER, counter = 3, timestamp = 1700002120 })
    return linkOA, linkL1, grantG1, linkL2
end

resetEnv()
profile = makeProfile("RejectedGrantResurrect")
local linkOA, linkL1, grantG1, linkL2 = seedRejectedGrantHistory(profile)
assertTrue(profile:MergeLogTables({ linkOA, linkL1, grantG1, linkL2 }) > 0, "complete history with hidden O+A")
checkSurfaces(profile, "RejectedGrantResurrect", assertAdminState)
resetEnv()
profile = makeProfile("RejectedGrantResurrectRev")
linkOA, linkL1, grantG1, linkL2 = seedRejectedGrantHistory(profile)
assertTrue(profile:MergeLogTables({ linkL2, grantG1, linkL1, linkOA }) > 0, "opposite arrival of hidden O+A")
assertAdminState(profile, "opposite-arrival")
local laterGrant = makeTable(SF.LootLogEventTypes.ADMIN_ADDED, {
    member = ALT_B,
}, { author = OWNER, counter = 4, timestamp = 1700003000 })
assertTrue(profile:MergeLogTables({ laterGrant }) > 0, "later explicit ADMIN_ADDED is stored")
assertTrue(profile:IsAdminMemberId(ALT_B), "later explicit ADMIN_ADDED still grants B")
assertFalse(profile:IsAdminMemberId(ALT_C), "explicit B grant does not make C admin")

resetEnv()
profile = makeProfile("ExpireAvailable")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A local Chest USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B after local USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A+B Chest AVAILABLE")
assertFalse(armorOf(profile, ALT_A, "Chest"), "shared Chest AVAILABLE")
assertTrue(profile:UnlinkCharacter(ALT_A), "UNLINK A splits original scope")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "relink A+B with no local equipment action")
assertTrue(armorOf(profile, ALT_A, "Chest"), "expired AVAILABLE does not suppress A's local USED")
assertTrue(armorOf(profile, ALT_B, "Chest"), "relinked partner sees packed local USED")
checkSurfaces(profile, "ExpireAvailable", function(p, label)
    assertTrue(armorOf(p, ALT_A, "Chest"), label .. ": Chest USED after expired AVAILABLE")
end)

resetEnv()
profile = makeProfile("ExpireUsed")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B before identity USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A+B Chest USED")
assertTrue(armorOf(profile, ALT_A, "Chest"), "shared Chest USED")
assertTrue(profile:UnlinkCharacter(ALT_A), "UNLINK A expires the USED correction")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "relink A+B with no underlying local Chest use")
assertFalse(armorOf(profile, ALT_A, "Chest"), "expired USED does not resurrect")
assertFalse(armorOf(profile, ALT_B, "Chest"), "partner Chest stays AVAILABLE")
checkSurfaces(profile, "ExpireUsed", function(p, label)
    assertFalse(armorOf(p, ALT_A, "Chest"), label .. ": Chest AVAILABLE after expired USED")
end)

resetEnv()
profile = makeProfile("ExpireRing")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B before ring correction")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile }), "A+B Ring1 USED")
assertTrue(profile:UnlinkCharacter(ALT_A), "split expires ring correction")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "relink after ring split")
assertFalse(armorOf(profile, ALT_A, "Ring1"), "expired Ring1 USED does not resurrect")
assertFalse(armorOf(profile, ALT_A, "Ring2"), "expired ring does not occupy Ring2")

resetEnv()
profile = makeProfile("NestedSuperset")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A+B Chest USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "C joins current identity")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "current identity Chest AVAILABLE")
assertFalse(armorOf(profile, ALT_A, "Chest"), "superset AVAILABLE supersedes subset USED")
assertFalse(armorOf(profile, ALT_C, "Chest"), "expanded identity sees AVAILABLE")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "nested AVAILABLE does not OR leftover USED")
checkSurfaces(profile, "NestedSuperset", function(p, label)
    assertFalse(armorOf(p, ALT_A, "Chest"), label .. ": Chest AVAILABLE")
    assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(p._identityProjection, ALT_A), label .. ": no overflow")
end)

resetEnv()
profile = makeProfile("NestedSupersetUsed")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B for inverse")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A+B Chest USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A+B Chest AVAILABLE")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "C joins after AVAILABLE")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "current identity Chest USED")
assertTrue(armorOf(profile, ALT_A, "Chest"), "superset USED supersedes subset AVAILABLE")
assertTrue(armorOf(profile, ALT_C, "Chest"), "expanded identity sees USED")

resetEnv()
profile = makeProfile("DisjointChestPlusHead")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B for disjoint Chest")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "A+B Chest USED")
assertTrue(profile:LinkCharacters(ALT_C, ALT_D), "C+D for disjoint Chest")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "C+D Chest USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "merge disjoint Chest identities")
assertTrue(armorOf(profile, ALT_A, "Chest"), "merged Chest stays USED")
assertTrue(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "two disjoint Chest USEDs overflow")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Head", { profile = profile, scope = "identity" }), "current identity Head AVAILABLE/USED toggle")
-- Toggle from empty Head writes USED; toggle again for AVAILABLE if first fill is USED.
if armorOf(profile, ALT_A, "Head") then
    assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Head", { profile = profile, scope = "identity" }), "current identity Head AVAILABLE")
end
assertFalse(armorOf(profile, ALT_A, "Head"), "combined Head AVAILABLE")
assertTrue(armorOf(profile, ALT_A, "Chest"), "later Head correction does not drop disjoint Chest uses")
assertTrue(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "Chest overflow survives a later Head correction")
checkSurfaces(profile, "DisjointChestPlusHead", function(p, label)
    assertTrue(armorOf(p, ALT_A, "Chest"), label .. ": Chest USED")
    assertFalse(armorOf(p, ALT_A, "Head"), label .. ": Head AVAILABLE")
    assertTrue(SF.LootHelperIdentity.ComponentHasOverflow(p._identityProjection, ALT_A), label .. ": Chest overflow remains")
end)

resetEnv()
profile = makeProfile("OverlapChestNoErase")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B overlapping Chest")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile, scope = "identity" }), "A+B Chest USED")
assertTrue(profile:LinkCharacters(ALT_B, ALT_C), "B+C join")
local subsetAvail = liveTable(profile, SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_B,
    slot = "Chest",
    action = SF.LootLogArmorActions.AVAILABLE,
    scope = "identity",
    identityMembers = { ALT_B, ALT_C },
}, OWNER)
assertTrue(profile:MergeLogTables({ subsetAvail }) > 0, "subset B+C Chest AVAILABLE is stored")
assertTrue(armorOf(profile, ALT_A, "Chest"), "B+C AVAILABLE does not erase A+B Chest USED")

resetEnv()
profile = makeProfile("RingPackMerge")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B identity")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile, scope = "identity" }), "A+B Ring1 USED")
assertTrue(profile:LinkCharacters(ALT_C, ALT_D), "C+D identity")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Ring1", { profile = profile, scope = "identity" }), "C+D Ring1 USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "merge A+B with C+D")
assertTrue(armorOf(profile, ALT_A, "Ring1"), "merged Ring1 occupied")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "second scoped Ring1 packs into Ring2")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "two scoped Ring1 usages do not overflow")
checkSurfaces(profile, "RingPackMerge", function(p, label)
    assertTrue(armorOf(p, ALT_A, "Ring1"), label .. ": Ring1 USED")
    assertTrue(armorOf(p, ALT_A, "Ring2"), label .. ": Ring2 USED")
    assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(p._identityProjection, ALT_A), label .. ": overflow 0")
end)
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring2", { profile = profile, scope = "identity" }), "current identity clears displayed Ring2")
assertTrue(armorOf(profile, ALT_A, "Ring1"), "clearing Ring2 keeps packed Ring1")
assertFalse(armorOf(profile, ALT_A, "Ring2"), "combined Ring2 AVAILABLE clears opportunity 2")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "Ring2 clear does not drop the remaining Ring1 use into overflow")
checkSurfaces(profile, "RingPackThenRing2", function(p, label)
    assertTrue(armorOf(p, ALT_A, "Ring1"), label .. ": Ring1 USED")
    assertFalse(armorOf(p, ALT_A, "Ring2"), label .. ": Ring2 AVAILABLE")
end)

resetEnv()
profile = makeProfile("RingPackThenHead")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B ring pair")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile, scope = "identity" }), "A+B Ring1")
assertTrue(profile:LinkCharacters(ALT_C, ALT_D), "C+D ring pair")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Ring1", { profile = profile, scope = "identity" }), "C+D Ring1")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "merge ring pairs")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Head", { profile = profile, scope = "identity" }), "combined Head USED")
if armorOf(profile, ALT_A, "Head") then
    assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Head", { profile = profile, scope = "identity" }), "combined Head AVAILABLE")
end
assertTrue(armorOf(profile, ALT_A, "Ring1"), "later Head correction keeps packed Ring1")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "later Head correction keeps packed Ring2")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "Head correction does not create ring overflow")

resetEnv()
profile = makeProfile("RingPackThree")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
addMember(profile, ALT_E)
addMember(profile, ALT_F)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "pair AB")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile, scope = "identity" }), "AB Ring1")
assertTrue(profile:LinkCharacters(ALT_C, ALT_D), "pair CD")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Ring1", { profile = profile, scope = "identity" }), "CD Ring1")
assertTrue(profile:LinkCharacters(ALT_E, ALT_F), "pair EF")
assertTrue(memberOf(profile, ALT_E):ToggleEquipment("Ring1", { profile = profile, scope = "identity" }), "EF Ring1")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "merge AB+CD")
assertTrue(profile:LinkCharacters(ALT_A, ALT_E), "merge in EF")
assertTrue(armorOf(profile, ALT_A, "Ring1"), "three ring usages still occupy Ring1")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "three ring usages still occupy Ring2")
assertTrue(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "third independent ring usage overflows")
local ringCounts = profile._identityProjection.overflowCountsByIdentity
local ringRoot = profile._identityProjection.identityOf[ALT_A][1]
assertEq(ringCounts[ringRoot].ring, 1, "exactly one ring overflow")

resetEnv()
profile = makeProfile("TrinketPackMerge")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, ALT_D)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B trinket identity")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Trinket1", { profile = profile, scope = "identity" }), "A+B Trinket1 USED")
assertTrue(profile:LinkCharacters(ALT_C, ALT_D), "C+D trinket identity")
assertTrue(memberOf(profile, ALT_C):ToggleEquipment("Trinket1", { profile = profile, scope = "identity" }), "C+D Trinket1 USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_C), "merge trinket identities")
assertTrue(armorOf(profile, ALT_A, "Trinket1"), "merged Trinket1 occupied")
assertTrue(armorOf(profile, ALT_A, "Trinket2"), "second scoped Trinket1 packs into Trinket2")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "two scoped Trinket1 usages do not overflow")

resetEnv()
profile = makeProfile("CausalRankEquip")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, OTHER)
profile:AddAdminMemberId(OTHER)
local causalLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OWNER },
    preOpAuthorMax = {},
}, { author = OWNER, counter = 3, timestamp = 1700004000 })
local usedLaterByTie = makeTable(SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Chest",
    action = SF.LootLogArmorActions.USED,
    scope = "identity",
    identityMembers = { ALT_A, ALT_B },
}, { author = OWNER, counter = 4, timestamp = 1700004100 })
local availEarlierByTie = makeTable(SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Chest",
    action = SF.LootLogArmorActions.AVAILABLE,
    scope = "identity",
    identityMembers = { ALT_A, ALT_B },
    preOpAuthorMax = { { author = OWNER, counter = 4 } },
}, { author = OTHER, counter = 1, timestamp = 1700004100 })
assertTrue(SF.LootHelperIdentity.CompareLogs(availEarlierByTie, usedLaterByTie), "CompareLogs tie-break puts OTHER before OWNER")
assertTrue(profile:MergeLogTables({ causalLink, usedLaterByTie, availEarlierByTie }) > 0, "same-timestamp cross-author equipment")
assertFalse(armorOf(profile, ALT_A, "Chest"), "causal later AVAILABLE wins over tie-break-later USED")
checkSurfaces(profile, "CausalRankEquip", function(p, label)
    assertFalse(armorOf(p, ALT_A, "Chest"), label .. ": causal AVAILABLE")
end)

resetEnv()
profile = makeProfile("ReplaceMiddleLog")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "original middle LINK A+B")
addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
})
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_C,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
})
local linkLog = nil
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.CHARACTER_LINK then
        linkLog = log
        break
    end
end
assertTrue(linkLog ~= nil, "captured non-final LINK")
local lastBefore = profile._lootLogs[#profile._lootLogs]
local nBefore = #profile._lootLogs
SF.LootHelperIdentity.OrderLogs(profile:GetLootLogs())
local replacement = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_C,
    adminMembersAtLink = { OWNER },
    preOpAuthorMax = {},
}, {
    author = linkLog:GetAuthor(),
    counter = linkLog:GetCounter(),
    timestamp = linkLog:GetTimestamp(),
})
replacement._id = linkLog:GetID()
replacement._fingerprint = SF.LootLog.ComputeFingerprintFromTable(replacement)
assertTrue(profile:MergeLogTables({ replacement }, { allowReplaceExisting = true }) >= 0, "integrity replace of non-last LINK")
assertEq(#profile._lootLogs, nBefore, "replace keeps log table length")
assertTrue(profile._lootLogs[#profile._lootLogs] == lastBefore, "replace keeps the last log object")
assertTrue(profile:AreSameIdentity(ALT_A, ALT_C), "replaced LINK is visible immediately")
assertFalse(profile:AreSameIdentity(ALT_A, ALT_B), "old LINK topology is gone without a later write")
assertEq(profile:GetIdentityPoints(ALT_A), profile:GetIdentityPoints(ALT_C), "points follow replaced topology")

resetEnv()
profile = makeProfile("AuthorStream")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
for i = 2, 6 do
    addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 1,
    }, { author = "owner-Garona", counter = i, timestamp = 1700005000 + i })
end
assertEq(profile:_LogicalAuthorCounterMax(OWNER), 6, "logical max includes owner-Garona:6")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "relationship uses the continued counter")
local wroteSeven = false
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.CHARACTER_LINK and log:GetCounter() == 7 then
        wroteSeven = true
    end
end
assertTrue(wroteSeven, "Owner-Garona counter 7 continues the alias stream")
SF.LootHelperIdentity.OrderLogs(profile:GetLootLogs())
assertEq(SF.LootHelperIdentity.lastOrderStats.leftover or 0, 0, "alias continuation does not form a causal cycle")
local missing = Sync:ComputeMissingLogRequests({ ["owner-Garona"] = 6 }, { [OWNER] = 7 })
assertEq(#missing, 1, "alias catch-up requests one range")
assertEq(missing[1].fromCounter, 7, "does not request an impossible 1-6 gap")
assertEq(missing[1].toCounter, 7, "requests only the new counter")
assertFalse(Sync:DetectGap(profile:GetProfileId(), { _author = OWNER, _counter = 7 }), "counter 7 is contiguous with alias 1-6")
assertTrue(Sync:_LogAuthorMatches("owner-Garona", OWNER), "LOG_REQ author match is alias-safe")
local contig = Sync:ComputeContigAuthorMax(profile:GetProfileId())
assertEq(contig[OWNER], 7, "contig under current author includes alias history")
assertEq(contig["owner-Garona"], 7, "contig under historical author includes new writes")
local streamReload = rebuildFrom(profile, "AuthorStreamReload")
assertTrue(streamReload:AreSameIdentity(ALT_A, ALT_B), "reload preserves alias-continued relationship")
assertEq(streamReload:AllocateNextCounter(OWNER), 8, "reload continues the same logical stream")

resetEnv()
local depLogs = {
    {
        _timestamp = 1700060000,
        _author = OWNER,
        _counter = 1,
        _eventType = SF.LootLogEventTypes.POINT_CHANGE,
        _data = {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 1,
        },
        _id = OWNER .. ":1",
    },
}
for i = 1, 200 do
    depLogs[#depLogs + 1] = {
        _timestamp = 1700060001,
        _author = OTHER,
        _counter = i,
        _eventType = SF.LootLogEventTypes.CHARACTER_LINK,
        _data = {
            memberA = ALT_A,
            memberB = ALT_B,
            adminMembersAtLink = { OWNER },
            preOpAuthorMax = {
                { author = OWNER, counter = 1 },
                { author = OWNER, counter = 1 },
            },
        },
        _id = string.format("%s:%d", OTHER, i),
    }
end
SF.LootHelperIdentity.OrderLogs(depLogs)
local depStats = SF.LootHelperIdentity.lastOrderStats
assertEq(depStats.n, 201, "dependency-heavy history n")
assertTrue((depStats.edgeCalls or 0) > (depStats.edgeInserts or 0), "duplicate predecessor edges are detected")
assertTrue((depStats.edgeCalls or 0) < depStats.n * 8, "shared predecessor heads stay linear in edge work")
assertTrue((depStats.heapOps or 0) < depStats.n * depStats.n / 8, "heap work stays far below n^2")

resetEnv()
profile = makeProfile("ReuseDisplayedChest")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A local Chest USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B projects Chest USED")
assertTrue(armorOf(profile, ALT_A, "Chest"), "Chest projected USED after LINK")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "identity Chest AVAILABLE")
assertFalse(armorOf(profile, ALT_A, "Chest"), "displayed Chest AVAILABLE")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "identity Chest USED re-use")
assertTrue(armorOf(profile, ALT_A, "Chest"), "re-used displayed Chest is USED")
assertEq(slotOverflow(profile, ALT_A, "Chest"), 0, "AVAILABLE then USED does not phantom-overflow Chest")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "Chest re-use overflow is 0")
checkSurfaces(profile, "ReuseDisplayedChest", function(p, label)
    assertTrue(armorOf(p, ALT_A, "Chest"), label .. ": Chest USED")
    assertEq(slotOverflow(p, ALT_A, "Chest"), 0, label .. ": Chest overflow 0")
end)

resetEnv()
profile = makeProfile("ReuseDisplayedChestTwice")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "A local Chest USED")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "AVAILABLE")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "AVAILABLE again")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile }), "USED again")
assertTrue(armorOf(profile, ALT_A, "Chest"), "second re-use is USED")
assertEq(slotOverflow(profile, ALT_A, "Chest"), 0, "AVAILABLE/USED/AVAILABLE/USED overflow stays 0")
checkSurfaces(profile, "ReuseDisplayedChestTwice", function(p, label)
    assertTrue(armorOf(p, ALT_A, "Chest"), label .. ": Chest USED")
    assertEq(slotOverflow(p, ALT_A, "Chest"), 0, label .. ": Chest overflow 0")
end)

resetEnv()
profile = makeProfile("ReuseDisplayedRing2")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B before ring projection")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring1", { profile = profile }), "projected Ring1 USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring2", { profile = profile }), "historical projected Ring2 USED")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "Ring2 occupied")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring2", { profile = profile }), "manual Ring2 AVAILABLE")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Ring2", { profile = profile }), "manual Ring2 USED re-use")
assertTrue(armorOf(profile, ALT_A, "Ring2"), "re-used Ring2 is USED")
assertEq(slotOverflow(profile, ALT_A, "ring"), 0, "Ring2 re-use does not phantom-overflow")
checkSurfaces(profile, "ReuseDisplayedRing2", function(p, label)
    assertTrue(armorOf(p, ALT_A, "Ring2"), label .. ": Ring2 USED")
    assertEq(slotOverflow(p, ALT_A, "ring"), 0, label .. ": ring overflow 0")
end)

resetEnv()
profile = makeProfile("ReuseDisplayedTrinket2")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "LINK A+B before trinket projection")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Trinket1", { profile = profile }), "projected Trinket1 USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Trinket2", { profile = profile }), "historical projected Trinket2 USED")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Trinket2", { profile = profile }), "manual Trinket2 AVAILABLE")
assertTrue(memberOf(profile, ALT_A):ToggleEquipment("Trinket2", { profile = profile }), "manual Trinket2 USED re-use")
assertTrue(armorOf(profile, ALT_A, "Trinket2"), "re-used Trinket2 is USED")
assertEq(slotOverflow(profile, ALT_A, "trinket"), 0, "Trinket2 re-use does not phantom-overflow")
checkSurfaces(profile, "ReuseDisplayedTrinket2", function(p, label)
    assertTrue(armorOf(p, ALT_A, "Trinket2"), label .. ": Trinket2 USED")
    assertEq(slotOverflow(p, ALT_A, "trinket"), 0, label .. ": trinket overflow 0")
end)

resetEnv()
profile = makeProfile("InOrderAttendanceClamp")
addMember(profile, ALT_A)
assertTrue(profile:LinkCharacters(OWNER, ALT_A), "link for in-order attendance")
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
})
SF.LootHelperIdentity.replayCount = 0
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.DECREMENT,
    amount = 1,
})
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.DECREMENT,
    amount = 1,
})
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
})
assertEq(SF.LootHelperIdentity.replayCount, 0, "in-order concurrent attendance uses the fast path")
assertEq(profile:GetIdentityAttendance(ALT_A), 0, "1-1-1+1 live attendance is 0")
profile:ApplyIdentityProjection({ force = true })
assertEq(profile:GetIdentityAttendance(ALT_A), 0, "force Replay attendance is 0")
checkSurfaces(profile, "InOrderAttendanceClamp", function(p, label)
    assertEq(p:GetIdentityAttendance(ALT_A), 0, label .. ": attendance 0")
    assertEq(p:GetIdentityAttendance(OWNER), 0, label .. ": linked attendance 0")
end)

resetEnv()
profile = makeProfile("ReplayThenFanOutAttendance")
addMember(profile, ALT_A)
assertTrue(profile:LinkCharacters(OWNER, ALT_A), "link for replay-then-fan-out attendance")
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
})
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.DECREMENT,
    amount = 1,
})
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.DECREMENT,
    amount = 1,
})
assertEq(profile:GetIdentityAttendance(ALT_A), 0, "displayed attendance floors at zero after 1-1-1")
profile:ApplyIdentityProjection({ force = true })
assertEq(profile:GetIdentityAttendance(ALT_A), 0, "force Replay still displays 0")
SF.LootHelperIdentity.replayCount = 0
addLog(profile, SF.LootLogEventTypes.ATTENDANCE_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
})
assertEq(SF.LootHelperIdentity.replayCount, 0, "later in-order +1 still fans out")
assertEq(profile:GetIdentityAttendance(ALT_A), 0, "force Replay baseline keeps raw 1-1-1 so +1 is 0")
checkSurfaces(profile, "ReplayThenFanOutAttendance", function(p, label)
    assertEq(p:GetIdentityAttendance(ALT_A), 0, label .. ": attendance 0")
end)

resetEnv()
profile = makeProfile("ProductionArmorPreOp")
local ADMIN_Z = "Zulu-Garona"
local ADMIN_A_WRITER = "AlphaAdmin-Garona"
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ADMIN_Z)
addMember(profile, ADMIN_A_WRITER)
profile:AddAdminMemberId(ADMIN_Z)
profile:AddAdminMemberId(ADMIN_A_WRITER)
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "A+B linked before same-timestamp armor")
local frozenTs = 1700007777
local realGetServerTime = GetServerTime
function GetServerTime()
    return frozenTs
end
assertTrue(asPlayer(ADMIN_Z, function()
    return memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile })
end), "Admin Z identity Chest USED")
assertTrue(asPlayer(ADMIN_A_WRITER, function()
    return memberOf(profile, ALT_A):ToggleEquipment("Chest", { profile = profile })
end), "Admin A identity Chest AVAILABLE via ToggleEquipment")
GetServerTime = realGetServerTime
local usedArmor, availArmor
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.ARMOR_CHANGE then
        local data = log:GetEventData()
        if data.scope == "identity" and data.slot == "Chest" and data.action == SF.LootLogArmorActions.USED then
            usedArmor = log
        elseif data.scope == "identity" and data.slot == "Chest" and data.action == SF.LootLogArmorActions.AVAILABLE then
            availArmor = log
        end
    end
end
assertTrue(usedArmor ~= nil, "captured production USED")
assertTrue(availArmor ~= nil, "captured production AVAILABLE")
assertEq(usedArmor:GetTimestamp(), availArmor:GetTimestamp(), "USED and AVAILABLE share timestamp T")
assertTrue(SF.LootHelperIdentity.CompareLogs(availArmor, usedArmor), "CompareLogs alone would put A before Z")
local preOp = availArmor:GetEventData().preOpAuthorMax
assertTrue(type(preOp) == "table" and #preOp > 0, "production identity ARMOR_CHANGE snapshots preOpAuthorMax")
local sawZ = false
for i = 1, #preOp do
    if SF.LootHelperIdentity.SameAuthor(preOp[i].author, ADMIN_Z) then
        sawZ = true
    end
end
assertTrue(sawZ, "AVAILABLE observed Z's USED as a causal predecessor")
assertFalse(armorOf(profile, ALT_A, "Chest"), "observed later AVAILABLE wins over CompareLogs order")
checkSurfaces(profile, "ProductionArmorPreOp", function(p, label)
    assertFalse(armorOf(p, ALT_A, "Chest"), label .. ": Chest AVAILABLE")
end)

resetEnv()
profile = makeProfile("InvalidViewArmor")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
local bogusIdentityUsed = makeTable(SF.LootLogEventTypes.ARMOR_CHANGE, {
    member = ALT_A,
    slot = "Chest",
    action = SF.LootLogArmorActions.USED,
    scope = "identity",
    identityMembers = { ALT_A, ALT_B },
}, { author = OWNER, counter = 3, timestamp = 1700002000 })
assertTrue(profile:MergeLogTables({ bogusIdentityUsed }) > 0, "stored incomplete-view identity USED")
assertFalse(armorOf(profile, ALT_A, "Chest"), "identity USED is inactive while A and B are unlinked")
assertTrue(profile:LinkCharacters(ALT_A, ALT_B), "later legitimate LINK A+B")
assertFalse(armorOf(profile, ALT_A, "Chest"), "later legitimate LINK does not activate the incomplete-view correction")
assertFalse(SF.LootHelperIdentity.ComponentHasOverflow(profile._identityProjection, ALT_A), "resurrected view does not overflow")
checkSurfaces(profile, "InvalidViewArmor", function(p, label)
    assertFalse(armorOf(p, ALT_A, "Chest"), label .. ": Chest stays AVAILABLE")
end)
end
runStateMachinePassTests()

local function findCaptured(msgType)
    for i = 1, #capturedComm do
        if capturedComm[i].msgType == msgType then
            return capturedComm[i]
        end
    end
    return nil
end

local function logIdOf(logTable)
    return (logTable and (logTable._id or logTable.id)) or nil
end

local function payloadHasAuthor(payload, author)
    for _, logTable in ipairs((payload and payload.logs) or {}) do
        local a = logTable._author or logTable.author
        if a == author then
            return true
        end
    end
    return false
end

local function destFromSource(src, name)
    local dest = makeProfile(name)
    addMember(dest, ALT_A)
    dest._profileId = src:GetProfileId()
    SF.lootHelperDB.profiles[src:GetProfileId()] = dest
    return dest
end

-- ---------------------------------------------------------------------------
-- Real LOG_REQ / NEED_LOGS / AUTH_LOGS handlers with historical aliases
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("AliasLogReq")
addMember(profile, ALT_A)
setActive(profile)
local aliasPoint = addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 4,
}, { author = "owner-Garona" })
assertEq(aliasPoint:GetAuthor(), "owner-Garona", "historical row keeps owner-Garona")
activateSession(profile)
capturedComm = {}
Sync:HandleLogRequest(OWNER, {
    sessionId = "SES1",
    requestId = "REQ-ALIAS",
    profileId = profile:GetProfileId(),
    author = OWNER,
    fromCounter = aliasPoint:GetCounter(),
    toCounter = aliasPoint:GetCounter(),
})
local servedReq = findCaptured(Sync.MSG.AUTH_LOGS)
assertTrue(servedReq ~= nil, "LOG_REQ produced AUTH_LOGS")
assertTrue(payloadHasAuthor(servedReq.payload, "owner-Garona"), "LOG_REQ serves historical owner-Garona for Owner-Garona")
local dest = destFromSource(profile, "AliasLogReqDest")
activateSession(dest)
Sync.state.requests["REQ-ALIAS"] = {
    kind = "LOG_REQ",
    meta = {
        profileId = dest:GetProfileId(),
        author = OWNER,
        fromCounter = aliasPoint:GetCounter(),
        toCounter = aliasPoint:GetCounter(),
    },
}
servedReq.payload.sessionId = "SES1"
servedReq.payload.profileId = dest:GetProfileId()
servedReq.payload.requestId = "REQ-ALIAS"
Sync:HandleAuthLogs(OWNER, servedReq.payload)
assertTrue(dest:GetLogById(aliasPoint:GetID()) ~= nil, "AUTH_LOGS accepts SamePlayer historical alias row")
assertEq(dest:GetLogById(aliasPoint:GetID()):GetAuthor(), "owner-Garona", "accepted row keeps historical author")

resetEnv()
profile = makeProfile("AliasNeedLogs")
addMember(profile, ALT_A)
setActive(profile)
local needAlias = addLog(profile, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 5,
}, { author = "owner-Garona" })
activateSession(profile)
capturedComm = {}
Sync:HandleNeedLogs(OWNER, {
    sessionId = "SES1",
    profileId = profile:GetProfileId(),
    requestId = "REQ-NEED",
    missing = {
        {
            author = OWNER,
            fromCounter = needAlias:GetCounter(),
            toCounter = needAlias:GetCounter(),
        },
    },
})
local servedNeed = findCaptured(Sync.MSG.AUTH_LOGS)
assertTrue(servedNeed ~= nil, "NEED_LOGS produced AUTH_LOGS")
assertTrue(payloadHasAuthor(servedNeed.payload, "owner-Garona"), "NEED_LOGS serves historical owner-Garona for Owner-Garona")
dest = destFromSource(profile, "AliasNeedLogsDest")
activateSession(dest)
Sync.state.requests["REQ-NEED"] = {
    kind = "NEED_LOGS",
    meta = {
        profileId = dest:GetProfileId(),
        author = OWNER,
        fromCounter = needAlias:GetCounter(),
        toCounter = needAlias:GetCounter(),
    },
}
servedNeed.payload.sessionId = "SES1"
servedNeed.payload.profileId = dest:GetProfileId()
servedNeed.payload.requestId = "REQ-NEED"
Sync:HandleAuthLogs(OWNER, servedNeed.payload)
assertTrue(dest:GetLogById(needAlias:GetID()) ~= nil, "NEED_LOGS AUTH_LOGS accepts historical alias row")

resetEnv()
profile = makeProfile("OverlappingAliasCounters")
addMember(profile, ALT_A)
setActive(profile)
local otherTitle = "Other-Garona"
local otherAlias = "other-Garona"
local eventX = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { author = otherTitle, counter = 1, timestamp = 1700008001 })
local eventY = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 7,
}, { author = otherAlias, counter = 1, timestamp = 1700008002 })
assertTrue(profile:MergeLogTables({ eventX, eventY }) > 0, "pre-alias-safe overlapping :1 counters exist")
assertTrue(profile:GetLogById(otherTitle .. ":1") ~= nil, "Other-Garona:1 remains")
assertTrue(profile:GetLogById(otherAlias .. ":1") ~= nil, "other-Garona:1 remains")
activateSession(profile)
capturedComm = {}
Sync:HandleLogRequest(OWNER, {
    sessionId = "SES1",
    requestId = "REQ-OVERLAP",
    profileId = profile:GetProfileId(),
    author = otherTitle,
    fromCounter = 1,
    toCounter = 1,
})
local servedOverlap = findCaptured(Sync.MSG.AUTH_LOGS)
assertTrue(servedOverlap ~= nil, "overlapping counters LOG_REQ produced AUTH_LOGS")
assertTrue(payloadHasAuthor(servedOverlap.payload, otherTitle), "overlapping serve includes Other-Garona:1")
assertTrue(payloadHasAuthor(servedOverlap.payload, otherAlias), "overlapping serve includes other-Garona:1")
dest = destFromSource(profile, "OverlappingAliasDest")
activateSession(dest)
Sync.state.requests["REQ-OVERLAP"] = {
    kind = "LOG_REQ",
    meta = {
        profileId = dest:GetProfileId(),
        author = otherTitle,
        fromCounter = 1,
        toCounter = 1,
    },
}
servedOverlap.payload.sessionId = "SES1"
servedOverlap.payload.profileId = dest:GetProfileId()
servedOverlap.payload.requestId = "REQ-OVERLAP"
Sync:HandleAuthLogs(OWNER, servedOverlap.payload)
assertTrue(dest:GetLogById(otherTitle .. ":1") ~= nil, "Other-Garona:1 is repairable")
assertTrue(dest:GetLogById(otherAlias .. ":1") ~= nil, "other-Garona:1 is independently repairable")
assertEq(dest:GetLogById(otherTitle .. ":1"):GetAuthor(), otherTitle, "does not rewrite Other-Garona author")
assertEq(dest:GetLogById(otherAlias .. ":1"):GetAuthor(), otherAlias, "does not rewrite other-Garona author")

local function runHistoricalAliasConvergenceTests()
local function registerProfile(profile)
    SF.lootHelperDB.profiles[profile:GetProfileId()] = profile
    SF.lootHelperDB.activeProfile = profile
    SF.lootHelperDB.activeProfileId = profile:GetProfileId()
end

local function rangeForAuthor(ranges, author)
    for i = 1, #(ranges or {}) do
        if ranges[i].author == author then
            return ranges[i]
        end
    end
    return nil
end

local function unionRanges(a, b)
    local out = {}
    local seen = {}
    local function add(list)
        for i = 1, #(list or {}) do
            local r = list[i]
            local key = string.format("%s:%s:%s", tostring(r.author), tostring(r.fromCounter), tostring(r.toCounter))
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = r
            end
        end
    end
    add(a)
    add(b)
    return out
end

local function discoverFrom(dst, src)
    registerProfile(dst)
    local contig = Sync:ComputeContigAuthorMax(dst:GetProfileId())
    local remoteMax = src:ComputeAuthorMax()
    local missing = Sync:ComputeMissingLogRequests(contig, remoteMax, dst:ComputeAuthorMax())
    local remoteWindows = src:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
    local integrity = Sync:ComputeWindowMismatchRequests(dst:GetProfileId(), remoteWindows, contig)
    return missing, integrity, contig
end

local function applyDiscoveredRange(src, dst, req, requestId)
    registerProfile(src)
    Sync.state.active = true
    Sync.state.sessionId = "SES1"
    Sync.state.profileId = src:GetProfileId()
    Sync.state.isCoordinator = true
    Sync.state.coordinator = OWNER
    if src.ComputeAuthorWindowSummary then
        Sync:_AttachExactWindowEvidence({ req }, src:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize()) or {})
    end
    capturedComm = {}
    Sync:HandleLogRequest(OWNER, {
        sessionId = "SES1",
        requestId = requestId,
        profileId = src:GetProfileId(),
        author = req.author,
        fromCounter = req.fromCounter,
        toCounter = req.toCounter,
        exactAuthor = req.exactAuthor == true or nil,
        integrityRepair = req.integrityRepair == true or req.mode == "integrity" or nil,
    })
    local served = findCaptured(Sync.MSG.AUTH_LOGS)
    assertTrue(served ~= nil, "discovered range produced AUTH_LOGS for " .. tostring(req.author))
    registerProfile(dst)
    Sync.state.profileId = dst:GetProfileId()
    Sync.state.requests = Sync.state.requests or {}
    local meta = {
        profileId = dst:GetProfileId(),
        author = req.author,
        fromCounter = req.fromCounter,
        toCounter = req.toCounter,
        exactAuthor = req.exactAuthor == true or nil,
        integrityRepair = req.integrityRepair == true or req.mode == "integrity" or nil,
    }
    Sync:_CopyExpectedWindowEvidence(req, meta)
    Sync.state.requests[requestId] = {
        kind = "LOG_REQ",
        meta = meta,
    }
    served.payload.sessionId = "SES1"
    served.payload.profileId = dst:GetProfileId()
    served.payload.requestId = requestId
    Sync:HandleAuthLogs(OWNER, served.payload)
    dst:ApplyIdentityProjection({ force = true })
    src:ApplyIdentityProjection({ force = true })
    return served
end

local function hasLogId(profile, id)
    if profile.GetLogById and profile:GetLogById(id) then
        return true
    end
    for _, log in ipairs(profile:GetLootLogs() or {}) do
        local lid = (log.GetID and log:GetID()) or log._id
        if lid == id then
            return true
        end
    end
    return false
end

local function cloneWithout(src, name, dropId)
    local dest = makeProfile(name)
    if dest.RebuildLogIndex then
        dest:RebuildLogIndex()
    end
    dest._profileId = src:GetProfileId()
    for _, member in ipairs(src:GetMemberList() or src._members or {}) do
        local id = (member.GetFullIdentifier and member:GetFullIdentifier())
            or member.identifier
            or (member.GetID and member:GetID())
            or member._id
        if id and not dest:getMemberByID(id) then
            addMember(dest, id)
        end
    end
    local tables = {}
    for _, log in ipairs(src:GetLootLogs()) do
        if log:GetID() ~= dropId then
            tables[#tables + 1] = log:ToTable()
        end
    end
    dest:MergeLogTables(tables, { allowReplaceExisting = true })
    if dest.RebuildLogIndex then
        dest:RebuildLogIndex()
    end
    dest:ApplyIdentityProjection({ force = true })
    return dest
end

local function orderedIds(logs)
    local ordered = SF.LootHelperIdentity.OrderLogs(logs)
    local ids = {}
    for i = 1, #ordered do
        ids[i] = ordered[i]._id or (ordered[i].GetID and ordered[i]:GetID())
    end
    return ids, SF.LootHelperIdentity.lastOrderStats, ordered
end

local function indexOfId(ids, id)
    for i = 1, #ids do
        if ids[i] == id then
            return i
        end
    end
    return nil
end

-- Direct missing-range: overlapping historical aliases vs logical catch-up
resetEnv()
local overlapMissing = Sync:ComputeMissingLogRequests(
    { [OWNER] = 1 },
    { [OWNER] = 1, ["owner-Garona"] = 1 }
)
assertTrue(rangeForAuthor(overlapMissing, "owner-Garona") ~= nil, "missing-range discovers owner-Garona when logical max already matches")
assertEq(rangeForAuthor(overlapMissing, "owner-Garona").fromCounter, 1, "alias completeness requests 1..remoteMax")
assertEq(rangeForAuthor(overlapMissing, "owner-Garona").toCounter, 1, "alias completeness stops at remote max")
assertTrue(rangeForAuthor(overlapMissing, "owner-Garona").exactAuthor == true, "alias completeness is exact raw-author repair")
local catchUp = Sync:ComputeMissingLogRequests({ ["owner-Garona"] = 6 }, { [OWNER] = 7 })
assertEq(#catchUp, 1, "logical catch-up still requests one range")
assertEq(catchUp[1].fromCounter, 7, "logical catch-up still starts at 7")
assertEq(catchUp[1].toCounter, 7, "logical catch-up still ends at 7")
assertTrue(catchUp[1].exactAuthor ~= true, "logical catch-up is not exact-author repair")
assertTrue(rangeForAuthor(catchUp, "owner-Garona") == nil, "logical catch-up does not request a 1-6 alias gap")
local behindMissing = Sync:ComputeMissingLogRequests(
    { [OWNER] = 3, ["owner-Garona"] = 3, ["owner-garona"] = 3 },
    { [OWNER] = 3, ["owner-Garona"] = 3 },
    { [OWNER] = 3, ["owner-Garona"] = 1 }
)
assertTrue(rangeForAuthor(behindMissing, "owner-Garona") ~= nil, "behind-but-present alias is not treated as complete")
assertEq(rangeForAuthor(behindMissing, "owner-Garona").fromCounter, 1, "behind alias requests from 1")
assertEq(rangeForAuthor(behindMissing, "owner-Garona").toCounter, 3, "behind alias requests through remote max")
assertTrue(rangeForAuthor(behindMissing, "owner-Garona").exactAuthor == true, "behind alias completeness is exact-author repair")
local mixedLogical = Sync:ComputeMissingLogRequests(
    { ["owner-Garona"] = 5, [OWNER] = 7 },
    { ["owner-Garona"] = 6, [OWNER] = 7 }
)
assertTrue(rangeForAuthor(mixedLogical, "owner-Garona") ~= nil, "real missing owner-Garona:6 is discovered beside Owner-Garona:7")
assertEq(rangeForAuthor(mixedLogical, "owner-Garona").fromCounter, 1, "behind owner-Garona:6 requests from 1")
assertEq(rangeForAuthor(mixedLogical, "owner-Garona").toCounter, 6, "behind owner-Garona:6 requests through remote max")
assertTrue(rangeForAuthor(mixedLogical, "owner-Garona").exactAuthor == true, "owner-Garona:6 completeness is exact when logical head is already 7")
local sequentialSix = Sync:ComputeMissingLogRequests(
    { ["owner-Garona"] = 5 },
    { ["owner-Garona"] = 6 }
)
assertEq(#sequentialSix, 1, "sequential owner-Garona:6 is one logical range")
assertEq(sequentialSix[1].fromCounter, 6, "sequential owner-Garona:6 starts at 6")
assertEq(sequentialSix[1].toCounter, 6, "sequential owner-Garona:6 ends at 6")
assertTrue(sequentialSix[1].exactAuthor ~= true, "sequential owner-Garona:6 catch-up stays logical SameAuthor repair")

-- Automatic discovery of overlapping Owner-Garona:1 / owner-Garona:1
resetEnv()
profile = makeProfile("AliasDiscoverA")
addMember(profile, ALT_A)
setActive(profile)
local eventY = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 7,
}, { author = "owner-Garona", counter = 1, timestamp = 1700008102 })
assertTrue(profile:MergeLogTables({ eventY }) > 0, "authoritative peer stores owner-Garona:1")
if profile.RebuildLogIndex then
    profile:RebuildLogIndex()
end
assertTrue(hasLogId(profile, OWNER .. ":1"), "Owner-Garona:1 remains")
assertTrue(hasLogId(profile, "owner-Garona:1"), "owner-Garona:1 remains")
local yFp = profile:GetLogById("owner-Garona:1"):GetFingerprint()
local destB = cloneWithout(profile, "AliasDiscoverB", "owner-Garona:1")
assertTrue(hasLogId(destB, OWNER .. ":1"), "incomplete peer keeps Owner-Garona:1")
assertFalse(hasLogId(destB, "owner-Garona:1"), "incomplete peer lacks owner-Garona:1")

local missing, integrity = discoverFrom(destB, profile)
assertTrue(rangeForAuthor(missing, "owner-Garona") ~= nil, "heartbeat missing-range discovers owner-Garona without a seeded LOG_REQ")
assertEq(rangeForAuthor(missing, "owner-Garona").fromCounter, 1, "discovered alias range starts at 1")
assertEq(rangeForAuthor(missing, "owner-Garona").toCounter, 1, "discovered alias range ends at 1")
assertTrue(rangeForAuthor(integrity, "owner-Garona") ~= nil, "partial-window integrity also discovers unseen owner-Garona")
assertEq(rangeForAuthor(integrity, "owner-Garona").toCounter, 1, "partial integrity requests filled maxCounter, not 25")

applyDiscoveredRange(profile, destB, rangeForAuthor(missing, "owner-Garona"), "REQ-DISCOVER-Y")
assertTrue(hasLogId(destB, "owner-Garona:1"), "Y transferred by discovered repair")
assertEq(destB:GetLogById("owner-Garona:1"):GetAuthor(), "owner-Garona", "transferred row keeps owner-Garona spelling")
assertEq(destB:GetLogById("owner-Garona:1"):GetFingerprint(), yFp, "transferred fingerprint is unchanged")
assertEq(destB:GetLogById(OWNER .. ":1"):GetAuthor(), OWNER, "Owner-Garona spelling is unchanged")
assertEq(destB:GetIdentityPoints(ALT_A), profile:GetIdentityPoints(ALT_A), "derived points converge after alias repair")

local missing2, integrity2 = discoverFrom(destB, profile)
assertEq(#missing2, 0, "second missing-range pass is idle")
assertEq(#integrity2, 0, "second integrity pass is idle")

-- Unknown local alias spelling still uses logical contig
resetEnv()
profile = makeProfile("AliasUnknownSpelling")
addMember(profile, ALT_A)
assertTrue(profile:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 3,
}, { author = "owner-Garona", counter = 1, timestamp = 1700008201 }) }) > 0, "remote-only alias row")
local destSpell = cloneWithout(profile, "AliasUnknownSpellingB", "owner-Garona:1")
registerProfile(destSpell)
local spellContig = Sync:ComputeContigAuthorMax(destSpell:GetProfileId())
assertEq(spellContig["owner-Garona"], nil, "exact owner-Garona spelling is absent locally")
assertTrue((spellContig[OWNER] or 0) >= 1, "title-case contig is present")
local remoteWindows = profile:ComputeAuthorWindowSummary(25)
local spellMismatch = Sync:ComputeWindowMismatchRequests(destSpell:GetProfileId(), remoteWindows, spellContig)
assertTrue(rangeForAuthor(spellMismatch, "owner-Garona") ~= nil, "unseen remote spelling is not skipped as contig 0")

resetEnv()
profile = makeProfile("AliasBehindA")
addMember(profile, ALT_A)
for i = 2, 3 do
    assertTrue(profile:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = i,
    }, { author = OWNER, counter = i, timestamp = 1700008290 + i }) }) > 0, "shared Owner-Garona:" .. tostring(i))
end
for i = 1, 3 do
    assertTrue(profile:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = i,
    }, { author = "owner-Garona", counter = i, timestamp = 1700008300 + i }) }) > 0, "authoritative owner-Garona:" .. tostring(i))
end
if profile.RebuildLogIndex then
    profile:RebuildLogIndex()
end
local destBehind = makeProfile("AliasBehindB")
if destBehind.RebuildLogIndex then
    destBehind:RebuildLogIndex()
end
destBehind._profileId = profile:GetProfileId()
addMember(destBehind, ALT_A)
local behindKeep = {}
for _, log in ipairs(profile:GetLootLogs()) do
    local id = log:GetID()
    if id ~= "owner-Garona:2" and id ~= "owner-Garona:3" then
        behindKeep[#behindKeep + 1] = log:ToTable()
    end
end
destBehind:MergeLogTables(behindKeep, { allowReplaceExisting = true })
if destBehind.RebuildLogIndex then
    destBehind:RebuildLogIndex()
end
destBehind:ApplyIdentityProjection({ force = true })
assertTrue(hasLogId(destBehind, "owner-Garona:1"), "behind peer keeps owner-Garona:1")
assertFalse(hasLogId(destBehind, "owner-Garona:2"), "behind peer lacks owner-Garona:2")
local behindMissing, behindIntegrity = discoverFrom(destBehind, profile)
assertTrue(rangeForAuthor(behindMissing, "owner-Garona") ~= nil, "production missing-range discovers behind alias spelling")
assertTrue(rangeForAuthor(behindIntegrity, "owner-Garona") ~= nil, "integrity also discovers behind alias spelling")

resetEnv()
profile = makeProfile("LivePredBehind")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
for i = 2, 3 do
    assertTrue(profile:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = i,
    }, { author = OWNER, counter = i, timestamp = 1700008290 + i }) }) > 0, "live-pred Owner-Garona:" .. tostring(i))
end
assertTrue(profile:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { author = "owner-Garona", counter = 1, timestamp = 1700008301 }) }) > 0, "live-pred owner-Garona:1")
if profile.RebuildLogIndex then
    profile:RebuildLogIndex()
end
setActive(profile)
activateSession(profile)
local liveContig = Sync:ComputeContigAuthorMax(profile:GetProfileId())
assertEq(liveContig["owner-Garona"], 3, "live contig stamps the behind alias")
assertEq(profile:ComputeAuthorMax()["owner-Garona"], 1, "live raw max for the behind alias is 1")
Sync.state.authorMax = { [OWNER] = 3, ["owner-Garona"] = 3 }
local livePredLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OWNER },
    preOpAuthorMax = { { author = "owner-Garona", counter = 3 } },
}, { author = OWNER, counter = 4, timestamp = 1700008400 })
local liveReady, liveMissing = Sync:_LiveRelationshipPredecessorState(profile:GetProfileId(), livePredLink)
assertFalse(liveReady, "live predecessor waits for behind raw alias rows")
assertTrue(rangeForAuthor(liveMissing, "owner-Garona") ~= nil, "live predecessor requests the behind alias spelling")

-- OrderLogs retains both rows at one logical counter
resetEnv()
local pointX = {
    _timestamp = 1700009000,
    _author = "X-Garona",
    _counter = 1,
    _eventType = SF.LootLogEventTypes.POINT_CHANGE,
    _data = {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 1,
    },
    _id = "X-Garona:1",
}
local adminY = {
    _timestamp = 1700009000,
    _author = "x-Garona",
    _counter = 1,
    _eventType = SF.LootLogEventTypes.ADMIN_ADDED,
    _data = { member = ALT_B },
    _id = "x-Garona:1",
}
local linkB = {
    _timestamp = 1700009000,
    _author = ALT_B,
    _counter = 1,
    _eventType = SF.LootLogEventTypes.CHARACTER_LINK,
    _data = {
        memberA = ALT_A,
        memberB = ALT_C,
        adminMembersAtLink = { OWNER },
        preOpAuthorMax = { { author = "X-Garona", counter = 1 } },
    },
    _id = ALT_B .. ":1",
}
assertTrue(SF.LootHelperIdentity.CompareLogs(linkB, adminY), "without a causal edge Bravo sorts before x-Garona")
local idsForward, statsForward = orderedIds({ pointX, adminY, linkB })
local idsReverse, statsReverse = orderedIds({ linkB, adminY, pointX })
assertEq(statsForward.leftover or 0, 0, "duplicate logical-counter rows do not cycle")
assertEq(statsReverse.leftover or 0, 0, "reversed duplicate logical-counter rows do not cycle")
assertTrue(indexOfId(idsForward, "X-Garona:1") ~= nil, "X-Garona:1 is retained")
assertTrue(indexOfId(idsForward, "x-Garona:1") ~= nil, "x-Garona:1 is retained")
assertTrue(indexOfId(idsForward, "X-Garona:1") < indexOfId(idsForward, ALT_B .. ":1"), "point at frontier 1 precedes dependent LINK")
assertTrue(indexOfId(idsForward, "x-Garona:1") < indexOfId(idsForward, ALT_B .. ":1"), "ADMIN_ADDED at frontier 1 precedes dependent LINK")
for i = 1, #idsForward do
    assertEq(idsForward[i], idsReverse[i], "OrderLogs is independent of input order at " .. tostring(i))
end

local nextCounter = {
    _timestamp = 1700009000,
    _author = "X-Garona",
    _counter = 2,
    _eventType = SF.LootLogEventTypes.POINT_CHANGE,
    _data = {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 1,
    },
    _id = "X-Garona:2",
}
local idsNext, statsNext = orderedIds({ nextCounter, adminY, pointX })
assertEq(statsNext.leftover or 0, 0, "logical N+1 with duplicate N does not cycle")
assertTrue(indexOfId(idsNext, "X-Garona:1") < indexOfId(idsNext, "X-Garona:2"), "logical 2 is after X-Garona:1")
assertTrue(indexOfId(idsNext, "x-Garona:1") < indexOfId(idsNext, "X-Garona:2"), "logical 2 is after x-Garona:1")

-- Authorization-sensitive Replay + arrival permutations
resetEnv()
local causalRows = {
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 1,
    }, { author = "X-Garona", counter = 1, timestamp = 1700009000 }),
    makeTable(SF.LootLogEventTypes.ADMIN_ADDED, {
        member = ALT_B,
    }, { author = "x-Garona", counter = 1, timestamp = 1700009000 }),
    makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
        memberA = ALT_A,
        memberB = ALT_C,
        adminMembersAtLink = { OWNER },
        preOpAuthorMax = { { author = "X-Garona", counter = 1 } },
    }, { author = ALT_B, counter = 1, timestamp = 1700009000 }),
}
local permutations = {
    { 1, 2, 3 },
    { 3, 2, 1 },
    { 2, 3, 1 },
    { 3, 1, 2 },
    { 2, 1, 3 },
    { 1, 3, 2 },
}
local firstReplay = nil
for p = 1, #permutations do
    local order = permutations[p]
    local replica = makeProfile("AliasCausalAuth" .. tostring(p))
    addMember(replica, ALT_A)
    addMember(replica, ALT_B)
    addMember(replica, ALT_C)
    addMember(replica, "X-Garona")
    local batch = { causalRows[order[1]], causalRows[order[2]], causalRows[order[3]] }
    assertTrue(replica:MergeLogTables(batch) > 0, "perm " .. tostring(p) .. " merges")
    replica:ApplyIdentityProjection({ force = true })
    SF.LootHelperIdentity.OrderLogs(replica:GetLootLogs())
    assertEq(SF.LootHelperIdentity.lastOrderStats.leftover or 0, 0, "perm " .. tostring(p) .. " has no causal fallback")
    assertTrue(replica:AreSameIdentity(ALT_A, ALT_C), "perm " .. tostring(p) .. " applies LINK after ADMIN_ADDED")
    assertTrue(replica:IsAdminMemberId(ALT_B), "perm " .. tostring(p) .. " grants B")
    local replay = SF.LootHelperIdentity.Replay(replica:GetLootLogs(), { owner = OWNER })
    if not firstReplay then
        firstReplay = replay
    else
        assertEq(replay.points[ALT_A], firstReplay.points[ALT_A], "perm " .. tostring(p) .. " points match")
        assertEq(replay.attendance[ALT_A] or 0, firstReplay.attendance[ALT_A] or 0, "perm " .. tostring(p) .. " attendance match")
    end
end

exportCausal = makeProfile("AliasCausalExport")
addMember(exportCausal, ALT_A)
addMember(exportCausal, ALT_B)
addMember(exportCausal, ALT_C)
addMember(exportCausal, "X-Garona")
assertTrue(exportCausal:MergeLogTables(causalRows) > 0, "snapshot source merges both alias rows")
exportCausal:ApplyIdentityProjection({ force = true })
local snapExport = exportCausal:ExportSnapshot()
local snapDest = makeProfile("AliasCausalSnap")
snapDest._profileId = snapExport.meta._profileId
assertTrue(select(1, snapDest:ImportSnapshot(snapExport)), "snapshot import keeps overlapping alias rows")
assertTrue(snapDest:GetLogById("X-Garona:1") ~= nil, "snapshot retains X-Garona:1")
assertTrue(snapDest:GetLogById("x-Garona:1") ~= nil, "snapshot retains x-Garona:1")
snapDest:ApplyIdentityProjection({ force = true })
assertTrue(snapDest:AreSameIdentity(ALT_A, ALT_C), "snapshot Replay matches complete peer identity")
assertTrue(snapDest:IsAdminMemberId(ALT_B), "snapshot Replay matches complete peer admins")

-- End-to-end: discovery + causal Replay + idle second pass
resetEnv()
profile = makeProfile("AliasE2E")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addMember(profile, ALT_C)
addMember(profile, "X-Garona")
assertTrue(profile:MergeLogTables(causalRows) > 0, "complete peer has both counter-1 alias rows and dependent LINK")
profile:ApplyIdentityProjection({ force = true })
assertTrue(profile:AreSameIdentity(ALT_A, ALT_C), "complete peer linked A+C")
local incomplete = cloneWithout(profile, "AliasE2EB", "x-Garona:1")
assertTrue(incomplete:GetLogById("X-Garona:1") ~= nil, "incomplete peer has X-Garona:1")
assertTrue(incomplete:GetLogById("x-Garona:1") == nil, "incomplete peer lacks ADMIN_ADDED alias row")
assertTrue(incomplete:GetLogById(ALT_B .. ":1") ~= nil, "incomplete peer already has the dependent LINK")
assertFalse(incomplete:AreSameIdentity(ALT_A, ALT_C), "without ADMIN_ADDED the LINK does not authorize")

local e2eMissing, e2eIntegrity = discoverFrom(incomplete, profile)
local e2eRanges = unionRanges(e2eMissing, e2eIntegrity)
assertTrue(rangeForAuthor(e2eRanges, "x-Garona") ~= nil, "e2e discovery finds x-Garona without a seeded request")
applyDiscoveredRange(profile, incomplete, rangeForAuthor(e2eRanges, "x-Garona"), "REQ-E2E-ALIAS")
assertTrue(incomplete:GetLogById("x-Garona:1") ~= nil, "e2e AUTH_LOGS transferred ADMIN_ADDED")
assertEq(incomplete:GetLogById("x-Garona:1"):GetAuthor(), "x-Garona", "e2e does not rewrite alias author")
assertTrue(incomplete:AreSameIdentity(ALT_A, ALT_C), "e2e Replay applies LINK after transferred ADMIN_ADDED")
assertTrue(incomplete:IsAdminMemberId(ALT_B), "e2e Replay grants B")
assertEq(incomplete:GetIdentityPoints(ALT_A), profile:GetIdentityPoints(ALT_A), "e2e derived points match")
local e2eMissing2, e2eIntegrity2 = discoverFrom(incomplete, profile)
assertEq(#e2eMissing2, 0, "e2e second missing-range pass is idle")
assertEq(#e2eIntegrity2, 0, "e2e second integrity pass is idle")

-- Raw advertised authorMax must not copy logical maxima onto historical aliases
local function addAliasContinuation(dst, ownerAliasThrough)
    ownerAliasThrough = ownerAliasThrough or 6
    for i = 1, ownerAliasThrough do
        assertTrue(dst:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = i,
        }, { author = "owner-Garona", counter = i, timestamp = 1700010000 + i }) }) > 0,
            "continuation owner-Garona:" .. tostring(i))
    end
    assertTrue(dst:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 7,
    }, { author = OWNER, counter = 7, timestamp = 1700010007 }) }) > 0, "continuation Owner-Garona:7")
    if dst.RebuildLogIndex then
        dst:RebuildLogIndex()
    end
end

local function repairQueueIdle()
    local queue = Sync.state.repairQueue
    if type(queue) ~= "table" then
        return true
    end
    if type(queue.order) == "table" and #queue.order > 0 then
        return false
    end
    if type(queue.items) == "table" then
        for _ in pairs(queue.items) do
            return false
        end
    end
    return true
end

local function rangeCoversCounter(ranges, author, counter)
    for i = 1, #(ranges or {}) do
        local r = ranges[i]
        if type(r) == "table"
            and type(r.fromCounter) == "number"
            and type(r.toCounter) == "number"
            and r.fromCounter <= counter
            and r.toCounter >= counter
        then
            if r.author == author or (SF.LootHelperIdentity and SF.LootHelperIdentity.SameAuthor and SF.LootHelperIdentity.SameAuthor(r.author, author)) then
                return r
            end
        end
    end
    return nil
end

resetEnv()
profile = makeProfile("RawFrontierStamp")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addAliasContinuation(profile, 6)
local rawMax = profile:ComputeAuthorMax()
assertEq(rawMax["owner-Garona"], 6, "raw ComputeAuthorMax keeps owner-Garona at 6")
assertEq(rawMax[OWNER], 7, "raw ComputeAuthorMax keeps Owner-Garona at 7")
activateSession(profile)
Sync.state.authorMax = {}
Sync.state.coordEpoch = 1
local advertised = Sync:_RefreshAdvertisedAuthorMax(profile:GetProfileId())
assertEq(advertised["owner-Garona"], 6, "refresh does not advertise phantom owner-Garona:7")
assertEq(advertised[OWNER], 7, "refresh keeps raw Owner-Garona at 7")
Sync:_MergeAuthorMaxFrontier({ [OWNER] = 7 })
assertEq(Sync.state.authorMax["owner-Garona"], 6, "later Owner-Garona merge does not raise owner-Garona")
Sync:_MergeAuthorMaxFrontier({ ["owner-Garona"] = 6 })
assertEq(Sync.state.authorMax[OWNER], 7, "later owner-Garona merge does not lower Owner-Garona")
assertEq(Sync.state.authorMax["owner-Garona"], 6, "raw owner-Garona spelling is retained independently")

resetEnv()
profile = makeProfile("HasGapsAliasContinuation")
addMember(profile, ALT_A)
addAliasContinuation(profile, 6)
setActive(profile)
local statusComplete = Sync:BuildAdminStatus(profile:GetProfileId())
assertFalse(statusComplete.hasGaps, "alias continuation 1..6 + :7 is not a sequential gap")

resetEnv()
profile = makeProfile("HasGapsAliasHole")
addMember(profile, ALT_A)
addAliasContinuation(profile, 5)
setActive(profile)
local statusGappy = Sync:BuildAdminStatus(profile:GetProfileId())
assertTrue(statusGappy.hasGaps, "missing owner-Garona:6 is a logical sequential gap")

resetEnv()
profile = makeProfile("HasGapsDuplicateCounter")
addMember(profile, ALT_A)
assertTrue(profile:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { author = "owner-Garona", counter = 1, timestamp = 1700011001 }) }) > 0, "duplicate logical-counter alias row")
setActive(profile)
local statusDup = Sync:BuildAdminStatus(profile:GetProfileId())
assertFalse(statusDup.hasGaps, "duplicate Owner-Garona:1 / owner-Garona:1 is not a sequential gap")

local function installHeartbeatCatchup(queued)
    Sync.BroadcastSessionHeartbeat = ProductionSync.BroadcastSessionHeartbeat
    Sync.QueueRepairRanges = function(self, profileId, ranges, opts)
        opts = type(opts) == "table" and opts or {}
        self.state.repairQueue = self.state.repairQueue or { order = {}, items = {} }
        local queue = self.state.repairQueue
        queue.order = queue.order or {}
        queue.items = queue.items or {}
        local added = 0
        for _, range in ipairs(ranges or {}) do
            if type(range) == "table" and type(range.author) == "string" then
                queued[#queued + 1] = {
                    author = range.author,
                    fromCounter = range.fromCounter,
                    toCounter = range.toCounter,
                    mode = range.mode or opts.mode,
                    reason = opts.reason,
                }
                local key = table.concat({
                    tostring(profileId or ""),
                    tostring(range.author or ""),
                    tostring(tonumber(range.fromCounter) or 0),
                    tostring(tonumber(range.toCounter) or 0),
                    tostring(range.mode or opts.mode or "missing"),
                }, "|")
                if not queue.items[key] then
                    queue.items[key] = {
                        key = key,
                        profileId = profileId,
                        author = range.author,
                        fromCounter = range.fromCounter,
                        toCounter = range.toCounter,
                        mode = range.mode or opts.mode or "missing",
                        reason = opts.reason,
                    }
                    queue.order[#queue.order + 1] = key
                    added = added + 1
                end
            end
        end
        return added > 0
    end
end

local function restoreHeartbeatCatchup()
    Sync.BroadcastSessionHeartbeat = function() end
    Sync.QueueRepairRanges = function()
        return true
    end
    PLAYER = OWNER
end

local function runHeartbeatCatchup(coordProfile, memberProfile, queued)
    local pid = coordProfile:GetProfileId()
    PLAYER = OWNER
    registerProfile(coordProfile)
    Sync.state.active = true
    Sync.state.sessionId = "SES1"
    Sync.state.profileId = pid
    Sync.state.coordinator = OWNER
    Sync.state.coordEpoch = 1
    Sync.state.isCoordinator = true
    Sync.state.helpers = {}
    Sync.state.authorWindowSummary = {}
    capturedComm = {}
    assertTrue(Sync:BroadcastSessionHeartbeat() == true, "coordinator BroadcastSessionHeartbeat sent")
    local hb = findCaptured(Sync.MSG.SES_HEARTBEAT)
    assertTrue(hb ~= nil and type(hb.payload) == "table", "SES_HEARTBEAT payload captured")
    local advertisedMax = hb.payload.authorMax or {}
    PLAYER = OTHER
    registerProfile(memberProfile)
    Sync.state.active = true
    Sync.state.sessionId = "SES1"
    Sync.state.profileId = pid
    Sync.state.coordinator = OWNER
    Sync.state.coordEpoch = 1
    Sync.state.isCoordinator = false
    Sync.state.heartbeat = Sync.state.heartbeat or {}
    Sync.state.heartbeat.lastCatchupAt = nil
    local prevCooldown = Sync.cfg.catchupOnHeartbeatCooldownSec
    Sync.cfg.catchupOnHeartbeatCooldownSec = 0
    Sync:HandleSessionHeartbeat(OWNER, hb.payload)
    Sync.cfg.catchupOnHeartbeatCooldownSec = prevCooldown
    PLAYER = OWNER
    return advertisedMax
end

resetEnv()
profile = makeProfile("HeartbeatRawFrontierA")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addAliasContinuation(profile, 6)
local memberComplete = cloneWithout(profile, "HeartbeatRawFrontierB", "__none__")
assertTrue(hasLogId(memberComplete, "owner-Garona:6"), "complete member has owner-Garona:6")
assertTrue(hasLogId(memberComplete, OWNER .. ":7"), "complete member has Owner-Garona:7")
local queuedHb = {}
installHeartbeatCatchup(queuedHb)
local advertisedHb
for cycle = 1, 3 do
    advertisedHb = runHeartbeatCatchup(profile, memberComplete, queuedHb)
    assertEq(advertisedHb["owner-Garona"], 6, "heartbeat cycle " .. tostring(cycle) .. " advertises raw owner-Garona=6")
    assertEq(advertisedHb[OWNER], 7, "heartbeat cycle " .. tostring(cycle) .. " advertises raw Owner-Garona=7")
    assertEq(#queuedHb, 0, "complete member queues no repair after heartbeat " .. tostring(cycle))
    assertTrue(repairQueueIdle(), "complete member repair queue stays idle after heartbeat " .. tostring(cycle))
end
registerProfile(profile)
Sync.state.active = true
Sync.state.isCoordinator = true
Sync.state.profileId = profile:GetProfileId()
Sync.state.authorMax = advertisedHb
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state._adminConvergence = nil
assertTrue(Sync:IsIdentityAdminReconcileReady(profile:GetProfileId()), "complete alias continuation is identity-admin ready")
local liveFrontier = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { OWNER },
    preOpAuthorMax = {
        { author = OWNER, counter = 7 },
        { author = "owner-Garona", counter = 6 },
    },
}, { author = OWNER, counter = 8, timestamp = 1700010108 })
registerProfile(memberComplete)
Sync.state.authorMax = advertisedHb
local liveReady, liveMissing = Sync:_LiveRelationshipPredecessorState(memberComplete:GetProfileId(), liveFrontier)
assertTrue(liveReady, "live relationship at logical frontier 7 is ready")
assertTrue(liveMissing == nil or #liveMissing == 0, "live predecessor does not request phantom owner-Garona:7")
restoreHeartbeatCatchup()

resetEnv()
profile = makeProfile("HeartbeatRawFrontierMissingA")
addMember(profile, ALT_A)
addMember(profile, ALT_B)
addAliasContinuation(profile, 6)
local memberBehind = cloneWithout(profile, "HeartbeatRawFrontierMissingB", "owner-Garona:6")
assertTrue(hasLogId(memberBehind, "owner-Garona:5"), "incomplete member keeps owner-Garona:5")
assertFalse(hasLogId(memberBehind, "owner-Garona:6"), "incomplete member lacks owner-Garona:6")
assertTrue(hasLogId(memberBehind, OWNER .. ":7"), "incomplete member already has Owner-Garona:7")
queuedHb = {}
installHeartbeatCatchup(queuedHb)
advertisedHb = runHeartbeatCatchup(profile, memberBehind, queuedHb)
assertEq(advertisedHb["owner-Garona"], 6, "incomplete-path heartbeat still advertises raw owner-Garona=6")
assertEq(advertisedHb[OWNER], 7, "incomplete-path heartbeat still advertises raw Owner-Garona=7")
local phantomRange = rangeForAuthor(queuedHb, "owner-Garona")
if phantomRange then
    assertFalse(phantomRange.fromCounter == 1 and phantomRange.toCounter == 7, "must not request fabricated owner-Garona:1..7")
end
assertTrue(rangeCoversCounter(queuedHb, "owner-Garona", 6) ~= nil, "production catch-up still discovers missing owner-Garona:6")
local discovered = rangeForAuthor(queuedHb, "owner-Garona") or rangeCoversCounter(queuedHb, "owner-Garona", 6)
applyDiscoveredRange(profile, memberBehind, {
    author = discovered.author,
    fromCounter = discovered.fromCounter,
    toCounter = discovered.toCounter,
}, "REQ-HB-OWNER-6")
assertTrue(hasLogId(memberBehind, "owner-Garona:6"), "AUTH_LOGS transferred the real missing owner-Garona:6")
assertEq(memberBehind:GetLogById("owner-Garona:6"):GetAuthor(), "owner-Garona", "transferred missing row keeps owner-Garona")
restoreHeartbeatCatchup()

local function runExactAuthorRepairRoutingTests()
-- Exact vs logical outstanding coverage
resetEnv()
profile = makeProfile("ExactCoverage")
addMember(profile, ALT_A)
activateSession(profile)
local pidCover = profile:GetProfileId()
Sync.state.requests["REQ-LOGICAL"] = {
    kind = "NEED_LOGS",
    meta = {
        profileId = pidCover,
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 1,
    },
}
assertTrue(Sync:_HasOutstandingLogRangeRequest(pidCover, "owner-Garona", 1, 1, false), "logical outstanding covers logical overlap")
assertFalse(Sync:_HasOutstandingLogRangeRequest(pidCover, "owner-Garona", 1, 1, true), "logical outstanding does not cover exact raw-author repair")
Sync.state.requests["REQ-EXACT"] = {
    kind = "NEED_LOGS",
    meta = {
        profileId = pidCover,
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 1,
        exactAuthor = true,
    },
}
assertTrue(Sync:_HasOutstandingLogRangeRequest(pidCover, "owner-Garona", 1, 1, true), "exact outstanding covers exact overlap")
assertTrue(Sync:_HasOutstandingLogRangeRequest(pidCover, "owner-Garona", 1, 1, false), "exact outstanding can cover logical overlap")
assertFalse(Sync:_HasOutstandingLogRangeRequest(pidCover, "owner-Garona", 1, 1, true, true), "exact missing does not cover exact integrity")
Sync.state.requests["REQ-INTEGRITY"] = {
    kind = "NEED_LOGS",
    meta = {
        profileId = pidCover,
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 1,
        exactAuthor = true,
        integrityRepair = true,
    },
}
assertTrue(Sync:_HasOutstandingLogRangeRequest(pidCover, "owner-Garona", 1, 1, true, true), "exact integrity covers exact integrity")
assertTrue(Sync:_HasOutstandingLogRangeRequest(pidCover, "owner-Garona", 1, 1, true, false), "exact integrity covers exact missing")
assertTrue(Sync:_HasOutstandingLogRangeRequest(pidCover, "owner-Garona", 1, 1, false), "exact integrity covers logical missing")

-- Three-peer production routing: helper cannot satisfy exact owner-Garona:1
local MEMBER = "Member-Garona"
local function outstandingCount()
    local n = 0
    for _ in pairs(Sync.state.requests or {}) do
        n = n + 1
    end
    return n
end
local function installUniqueNonces()
    local nonce = 0
    function Sync:_NextNonce(tag)
        nonce = nonce + 1
        return tostring(tag or "N") .. tostring(nonce)
    end
end
local function restoreUniqueNonces()
    function Sync:_NextNonce(tag)
        return tostring(tag or "N") .. "1"
    end
end

resetEnv()
installUniqueNonces()
profile = makeProfile("ExactHelperStarvationA")
addMember(profile, ALT_A)
addMember(profile, OTHER)
addMember(profile, MEMBER)
assertTrue(profile:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 7,
}, { author = "owner-Garona", counter = 1, timestamp = 1700020002 }) }) > 0, "coordinator stores owner-Garona:1")
if profile.RebuildLogIndex then
    profile:RebuildLogIndex()
end
profile._adminUsers = { OWNER, OTHER }
assertTrue(hasLogId(profile, OWNER .. ":1"), "coordinator has Owner-Garona:1")
assertTrue(hasLogId(profile, "owner-Garona:1"), "coordinator has owner-Garona:1")
local yFpExact = profile:GetLogById("owner-Garona:1"):GetFingerprint()
local helperOnly = cloneWithout(profile, "ExactHelperStarvationHelper", "owner-Garona:1")
local memberOnly = cloneWithout(profile, "ExactHelperStarvationMember", "owner-Garona:1")
helperOnly._adminUsers = { OWNER, OTHER }
memberOnly._adminUsers = { OWNER, OTHER }
assertTrue(hasLogId(helperOnly, OWNER .. ":1"), "helper keeps Owner-Garona:1")
assertFalse(hasLogId(helperOnly, "owner-Garona:1"), "helper lacks owner-Garona:1")
assertTrue(hasLogId(memberOnly, OWNER .. ":1"), "member keeps Owner-Garona:1")
assertFalse(hasLogId(memberOnly, "owner-Garona:1"), "member lacks owner-Garona:1")

local pidExact = profile:GetProfileId()
local peers = {
    [OWNER] = { profile = profile, isCoordinator = true },
    [OTHER] = { profile = helperOnly, isCoordinator = false },
    [MEMBER] = { profile = memberOnly, isCoordinator = false },
}
local function become(id)
    PLAYER = id
    local peer = peers[id]
    registerProfile(peer.profile)
    Sync.state.active = true
    Sync.state.sessionId = "SES1"
    Sync.state.profileId = pidExact
    Sync.state.coordinator = OWNER
    Sync.state.coordEpoch = 1
    Sync.state.isCoordinator = peer.isCoordinator
    Sync.state.helpers = { OTHER }
end

become(OTHER)
activateSession(helperOnly)
Sync.state.isCoordinator = false
Sync.state.coordinator = OWNER
Sync.state.helpers = { OTHER }
PLAYER = OTHER
capturedComm = {}
Sync:HandleNeedLogs(MEMBER, {
    sessionId = "SES1",
    profileId = pidExact,
    requestId = "REQ-EXACT-HELPER",
    exactAuthor = true,
    missing = {
        {
            author = "owner-Garona",
            fromCounter = 1,
            toCounter = 1,
            exactAuthor = true,
        },
    },
})
local helperServed = findCaptured(Sync.MSG.AUTH_LOGS)
assertTrue(helperServed ~= nil, "exact NEED_LOGS to helper produced AUTH_LOGS")
assertFalse(payloadHasAuthor(helperServed.payload, "owner-Garona"), "helper does not substitute Owner-Garona for exact owner-Garona")
assertFalse(payloadHasAuthor(helperServed.payload, OWNER), "exact serve does not return sibling Owner-Garona")
become(MEMBER)
Sync.state.requests["REQ-EXACT-HELPER"] = {
    kind = "NEED_LOGS",
    meta = {
        profileId = pidExact,
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 1,
        exactAuthor = true,
    },
}
helperServed.payload.sessionId = "SES1"
helperServed.payload.profileId = pidExact
helperServed.payload.requestId = "REQ-EXACT-HELPER"
Sync:HandleAuthLogs(OTHER, helperServed.payload)
assertFalse(hasLogId(memberOnly, "owner-Garona:1"), "sibling/empty helper AUTH_LOGS does not insert owner-Garona:1")
assertTrue(Sync.state.requests["REQ-EXACT-HELPER"] ~= nil, "exact request stays pending after helper sibling/empty response")
assertFalse(Sync:_ExactAuthorRangeSatisfied(pidExact, "owner-Garona", 1, 1), "exact satisfaction fails without owner-Garona:1")

-- Production heartbeat routing outside helperWarmupSec
local originalSend = SF.LootHelperComm.Send
local originalQueue = Sync.QueueRepairRanges
Sync.QueueRepairRanges = ProductionSync.QueueRepairRanges
local function routeSend(_, prefix, msgType, payload, dist, target)
    capturedComm[#capturedComm + 1] = {
        prefix = prefix,
        msgType = msgType,
        payload = payload,
        target = target,
    }
    if payload and payload.statusOnly == true then
        return true
    end
    if msgType == Sync.MSG.NEED_LOGS and type(target) == "string" then
        local requester = PLAYER
        become(target)
        Sync:HandleNeedLogs(requester, payload)
        become(requester)
    elseif msgType == Sync.MSG.LOG_REQ and type(target) == "string" then
        local requester = PLAYER
        become(target)
        Sync:HandleLogRequest(requester, payload)
        become(requester)
    elseif msgType == Sync.MSG.AUTH_LOGS and type(target) == "string" then
        local sender = PLAYER
        become(target)
        Sync:HandleAuthLogs(sender, payload)
        become(sender)
    end
    return true
end
SF.LootHelperComm.Send = routeSend

become(MEMBER)
Sync.state._sessionDescriptorAt = -100
local ordinaryTargets = ProductionSync.GetRequestTargets(Sync, { OTHER }, OWNER)
assertEq(ordinaryTargets[1], OTHER, "ordinary missing-log traffic prefers helper outside warmup")
assertEq(ordinaryTargets[2], OWNER, "ordinary missing-log traffic falls back to coordinator")
local exactTargets = ProductionSync.GetRequestTargets(Sync, { OTHER }, OWNER, {
    preferCoordinatorFirst = true,
    preferredTarget = OWNER,
})
assertEq(exactTargets[1], OWNER, "exact raw-author repair prefers the advertising coordinator")
assertTrue(exactTargets[2] == OTHER, "exact repair still lists helper as fallback")

become(OWNER)
Sync.state.authorWindowSummary = {}
Sync.state.heartbeat = {}
capturedComm = {}
assertTrue(ProductionSync.BroadcastSessionHeartbeat(Sync) == true, "coordinator heartbeat sent for exact-repair e2e")
local hbExact = findCaptured(Sync.MSG.SES_HEARTBEAT)
assertTrue(hbExact ~= nil, "exact-repair e2e captured SES_HEARTBEAT")
assertEq((hbExact.payload.authorMax or {})["owner-Garona"], 1, "coordinator heartbeat advertises raw owner-Garona=1")
assertEq((hbExact.payload.authorMax or {})[OWNER], 1, "coordinator heartbeat advertises raw Owner-Garona=1")
assertTrue(#(hbExact.payload.helpers or {}) >= 1, "heartbeat advertises the preferred helper")

become(MEMBER)
Sync.state.heartbeat = {}
Sync.state.heartbeat.lastCatchupAt = nil
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state.requests = {}
Sync.state._sessionDescriptorAt = -100
local prevCooldown = Sync.cfg.catchupOnHeartbeatCooldownSec
Sync.cfg.catchupOnHeartbeatCooldownSec = 0
Sync:HandleSessionHeartbeat(OWNER, hbExact.payload)
Sync.state._sessionDescriptorAt = -100
local missingAfterHb, integrityAfterHb = discoverFrom(memberOnly, profile)
assertTrue(rangeForAuthor(missingAfterHb, "owner-Garona") ~= nil, "member initially detects missing owner-Garona:1")
assertTrue(rangeForAuthor(integrityAfterHb, "owner-Garona") ~= nil, "member also sees exact-window integrity mismatch")
assertTrue(rangeForAuthor(missingAfterHb, "owner-Garona").exactAuthor == true, "heartbeat missing owner-Garona is exact-author repair")
ProductionSync.ProcessRepairConvergenceTick(Sync, "exact-e2e")
assertTrue(hasLogId(memberOnly, "owner-Garona:1"), "fallback/preferred exact provider supplied owner-Garona:1")
assertEq(memberOnly:GetLogById("owner-Garona:1"):GetAuthor(), "owner-Garona", "exact repair does not rewrite _author")
assertEq(memberOnly:GetLogById("owner-Garona:1"):GetFingerprint(), yFpExact, "exact repair does not rewrite fingerprint")
assertEq(memberOnly:GetLogById(OWNER .. ":1"):GetAuthor(), OWNER, "Owner-Garona spelling is unchanged")
assertEq(outstandingCount(), 0, "exact repair request completed after coordinator AUTH_LOGS")
assertTrue(repairQueueIdle(), "repair queue drains after exact row arrives")

for cycle = 1, 3 do
    become(OWNER)
    capturedComm = {}
    assertTrue(ProductionSync.BroadcastSessionHeartbeat(Sync) == true, "idle heartbeat cycle " .. tostring(cycle))
    local hbIdle = findCaptured(Sync.MSG.SES_HEARTBEAT)
    become(MEMBER)
    Sync.state.heartbeat.lastCatchupAt = nil
    Sync:HandleSessionHeartbeat(OWNER, hbIdle.payload)
    Sync.state._sessionDescriptorAt = -100
    ProductionSync.ProcessRepairConvergenceTick(Sync, "idle-" .. tostring(cycle))
    local idleMissing, idleIntegrity = discoverFrom(memberOnly, profile)
    assertEq(#idleMissing, 0, "idle heartbeat " .. tostring(cycle) .. " has no missing ranges")
    assertEq(#idleIntegrity, 0, "idle heartbeat " .. tostring(cycle) .. " has no integrity ranges")
    assertTrue(repairQueueIdle(), "idle heartbeat " .. tostring(cycle) .. " queues no repairs")
    assertEq(outstandingCount(), 0, "idle heartbeat " .. tostring(cycle) .. " has no outstanding requests")
end
Sync.cfg.catchupOnHeartbeatCooldownSec = prevCooldown

-- Join-status path: missing exact range must not starve behind helper SameAuthor
resetEnv()
installUniqueNonces()
profile = makeProfile("ExactJoinStatusA")
addMember(profile, ALT_A)
addMember(profile, OTHER)
addMember(profile, MEMBER)
assertTrue(profile:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 9,
}, { author = "owner-Garona", counter = 1, timestamp = 1700020102 }) }) > 0, "join coordinator stores owner-Garona:1")
if profile.RebuildLogIndex then
    profile:RebuildLogIndex()
end
profile._adminUsers = { OWNER, OTHER }
helperOnly = cloneWithout(profile, "ExactJoinStatusHelper", "owner-Garona:1")
memberOnly = cloneWithout(profile, "ExactJoinStatusMember", "owner-Garona:1")
helperOnly._adminUsers = { OWNER, OTHER }
memberOnly._adminUsers = { OWNER, OTHER }
pidExact = profile:GetProfileId()
peers = {
    [OWNER] = { profile = profile, isCoordinator = true },
    [OTHER] = { profile = helperOnly, isCoordinator = false },
    [MEMBER] = { profile = memberOnly, isCoordinator = false },
}
Sync.QueueRepairRanges = ProductionSync.QueueRepairRanges
SF.LootHelperComm.Send = routeSend
become(MEMBER)
Sync.state.authorMax = profile:ComputeAuthorMax()
Sync.state.authorWindowSummary = profile:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.helpers = { OTHER }
Sync.state._sessionDescriptorAt = -100
Sync.state._sentJoinStatusForSessionId = nil
Sync.state._sentJoinStatusType = nil
assertFalse(hasLogId(memberOnly, "owner-Garona:1"), "join member starts without owner-Garona:1")
ProductionSync.SendJoinStatus(Sync)
assertTrue(hasLogId(memberOnly, "owner-Garona:1"), "join-status exact repair obtained owner-Garona:1")
assertEq(memberOnly:GetLogById("owner-Garona:1"):GetAuthor(), "owner-Garona", "join-status does not rewrite owner-Garona")
assertEq(outstandingCount(), 0, "join-status exact request completed")
Sync.state._sentJoinStatusForSessionId = nil
Sync.state._sentJoinStatusType = nil
capturedComm = {}
ProductionSync.SendJoinStatus(Sync)
local joinHave = findCaptured(Sync.MSG.HAVE_PROFILE)
assertTrue(joinHave ~= nil, "subsequent join-status sends HAVE_PROFILE")
assertEq(outstandingCount(), 0, "synced join-status has no outstanding requests")
assertTrue(repairQueueIdle(), "synced join-status queues no repairs")

SF.LootHelperComm.Send = originalSend
Sync.QueueRepairRanges = originalQueue
PLAYER = OWNER
restoreUniqueNonces()

-- Admin convergence already selects providers by exact authorMax[author]
resetEnv()
installUniqueNonces()
profile = makeProfile("ExactAdminProvider")
addMember(profile, ALT_A)
addMember(profile, OTHER)
addMember(profile, ALT_C)
assertTrue(profile:MergeLogTables({ makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 1,
}, { author = OWNER, counter = 1, timestamp = 1700020201 }) }) > 0, "admin coordinator already has Owner-Garona:1")
activateSession(profile)
profile._adminUsers = { OWNER, OTHER, ALT_C }
Sync.state.isCoordinator = true
Sync.state.coordEpoch = 1
Sync.state._adminConvergence = {
    adminSyncId = "ADM1",
    pendingReq = {},
    pendingCount = 0,
    finished = false,
    finalizeStarted = false,
}
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = { [OWNER] = 1 },
    },
    [ALT_C] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = { [OWNER] = 1, ["owner-Garona"] = 1 },
    },
}
capturedComm = {}
Sync:FinalizeAdminConvergence()
local adminExactReq = nil
for _, req in pairs(Sync.state.requests or {}) do
    if type(req) == "table" and req.meta and req.meta.author == "owner-Garona" then
        adminExactReq = req
        break
    end
end
assertTrue(adminExactReq ~= nil, "admin convergence requests exact owner-Garona history")
assertTrue(adminExactReq.meta.exactAuthor == true, "admin exact missing range keeps exactAuthor")
assertEq(adminExactReq.lastTarget, ALT_C, "admin provider is the status whose exact authorMax has owner-Garona")
assertTrue(adminExactReq.lastTarget ~= OTHER, "admin does not pick a sibling-only helper by logical stream")

-- Sparse exact history: 1..authorMax is a fetch window, not a dense counter list
resetEnv()
installUniqueNonces()
profile = makeProfile("SparseExactA")
addMember(profile, ALT_A)
assertTrue(profile:MergeLogTables({
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 2,
    }, { author = OWNER, counter = 2, timestamp = 1700020302 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 3,
    }, { author = OWNER, counter = 3, timestamp = 1700020303 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 11,
    }, { author = "owner-Garona", counter = 1, timestamp = 1700020311 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 13,
    }, { author = "owner-Garona", counter = 3, timestamp = 1700020313 }),
}) > 0, "sparse coordinator has owner-Garona:1 and :3, no :2")
if profile.RebuildLogIndex then
    profile:RebuildLogIndex()
end
assertTrue(hasLogId(profile, "owner-Garona:1"), "sparse source keeps owner-Garona:1")
assertTrue(hasLogId(profile, "owner-Garona:3"), "sparse source has owner-Garona:3")
assertFalse(hasLogId(profile, "owner-Garona:2"), "owner-Garona:2 never existed")
local sparseDest = cloneWithout(profile, "SparseExactB", "owner-Garona:3")
assertTrue(hasLogId(sparseDest, "owner-Garona:1"), "sparse dest keeps owner-Garona:1")
assertFalse(hasLogId(sparseDest, "owner-Garona:3"), "sparse dest lacks owner-Garona:3")
local sparseReq = { author = "owner-Garona", fromCounter = 1, toCounter = 3, exactAuthor = true }
applyDiscoveredRange(profile, sparseDest, sparseReq, "REQ-SPARSE-EXACT")
assertTrue(hasLogId(sparseDest, "owner-Garona:3"), "sparse exact repair obtained owner-Garona:3")
assertTrue(hasLogId(sparseDest, "owner-Garona:1"), "sparse exact repair kept owner-Garona:1")
assertFalse(hasLogId(sparseDest, "owner-Garona:2"), "sparse exact repair does not invent owner-Garona:2")
assertTrue(Sync:_ExactAuthorRangeSatisfied(sparseDest:GetProfileId(), "owner-Garona", 1, 3, {
    expectedCount = 2,
    expectedMaxCounter = 3,
}), "exact advertised count/max satisfies 1..3 without a dense :2")
assertTrue(Sync:_ExactAuthorRangeSatisfied(sparseDest:GetProfileId(), "owner-Garona", 1, 3, {
    integrityRepair = true,
    expectedCount = 2,
    expectedMaxCounter = 3,
}), "sparse exact 1+3 satisfies integrity when expectedCount=2 and expectedMax=3")
assertFalse(Sync:_ExactAuthorRangeSatisfied(sparseDest:GetProfileId(), "owner-Garona", 1, 3, {
    integrityRepair = true,
    expectedCount = 2,
    expectedMaxCounter = 3,
    expectedChecksum = 1,
}), "sparse integrity still requires matching checksum when advertised")
assertTrue(Sync.state.requests["REQ-SPARSE-EXACT"] == nil, "sparse exact AUTH_LOGS completed the request")

-- Later retained exact rows must not complete an earlier window.
resetEnv()
installUniqueNonces()
profile = makeProfile("LaterExactWindowA")
addMember(profile, ALT_A)
assertTrue(profile:MergeLogTables({
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 30,
    }, { author = "owner-Garona", counter = 30, timestamp = 1700020330 }),
}) > 0, "later-window source stores owner-Garona:30")
if profile.RebuildLogIndex then
    profile:RebuildLogIndex()
end
pidExact = profile:GetProfileId()
assertTrue(hasLogId(profile, "owner-Garona:30"), "later-window profile kept owner-Garona:30")
assertFalse(Sync:_ExactAuthorRangeSatisfied(pidExact, "owner-Garona", 1, 25),
    "later exact row 30 does not satisfy completeness window 1-25")
assertFalse(Sync:_ExactAuthorRangeSatisfied(pidExact, "owner-Garona", 1, 25, {
    integrityRepair = true,
    expectedCount = 3,
    expectedMaxCounter = 25,
}), "later exact row 30 does not satisfy integrity window 1-25")

-- Integrity discovery stamps advertised window evidence, and a non-empty
-- helper subset must not complete when expectedCount is higher.
resetEnv()
installUniqueNonces()
profile = makeProfile("SubsetIntegrityA")
addMember(profile, ALT_A)
assertTrue(profile:MergeLogTables({
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 21,
    }, { author = OWNER, counter = 1, timestamp = 1700020341 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 22,
    }, { author = OWNER, counter = 2, timestamp = 1700020342 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 23,
    }, { author = OWNER, counter = 3, timestamp = 1700020343 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 11,
    }, { author = "owner-Garona", counter = 1, timestamp = 1700020351 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 12,
    }, { author = "owner-Garona", counter = 2, timestamp = 1700020352 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 13,
    }, { author = "owner-Garona", counter = 3, timestamp = 1700020353 }),
}) > 0, "subset source has Owner-Garona:1..3 and owner-Garona:1..3")
if profile.RebuildLogIndex then
    profile:RebuildLogIndex()
end
memberOnly = cloneWithout(profile, "SubsetIntegrityMid", "owner-Garona:2")
memberOnly = cloneWithout(memberOnly, "SubsetIntegrityB", "owner-Garona:3")
assertTrue(hasLogId(memberOnly, "owner-Garona:1"), "subset dest keeps owner-Garona:1")
assertFalse(hasLogId(memberOnly, "owner-Garona:2"), "subset dest lacks owner-Garona:2")
assertFalse(hasLogId(memberOnly, "owner-Garona:3"), "subset dest lacks owner-Garona:3")
registerProfile(memberOnly)
sparseReq = rangeForAuthor((select(2, discoverFrom(memberOnly, profile))), "owner-Garona")
assertTrue(sparseReq ~= nil, "integrity discovers owner-Garona window against sibling contig")
assertEq(sparseReq.expectedCount, 3, "integrity stamps remote window count")
assertEq(sparseReq.expectedMaxCounter, 3, "integrity stamps remote filled frontier")
assertTrue(type(sparseReq.expectedChecksum) == "number", "integrity stamps remote window checksum")
assertFalse(Sync:_ExactAuthorRangeSatisfied(memberOnly:GetProfileId(), "owner-Garona", 1, 3, {
    integrityRepair = true,
    expectedCount = 3,
    expectedMaxCounter = 3,
    expectedChecksum = sparseReq.expectedChecksum,
}), "one exact row does not satisfy integrity expectedCount=3")

activateSession(memberOnly)
pidExact = memberOnly:GetProfileId()
helperServed = nil
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetAuthor() == "owner-Garona" and log:GetCounter() == 1 then
        helperServed = log:ToTable()
        break
    end
end
assertTrue(helperServed ~= nil, "subset payload uses the exact owner-Garona:1 table")
Sync.state.requests["REQ-SUBSET"] = {
    kind = "LOG_REQ",
    meta = {
        profileId = pidExact,
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 3,
        exactAuthor = true,
        integrityRepair = true,
        expectedCount = 3,
        expectedMaxCounter = 3,
        expectedChecksum = sparseReq.expectedChecksum,
    },
}
Sync:HandleAuthLogs(OWNER, {
    sessionId = "SES1",
    profileId = pidExact,
    requestId = "REQ-SUBSET",
    author = "owner-Garona",
    fromCounter = 1,
    toCounter = 3,
    logs = { helperServed },
})
assertTrue(Sync.state.requests["REQ-SUBSET"] ~= nil, "incomplete integrity AUTH_LOGS stays pending")
assertTrue(hasLogId(memberOnly, "owner-Garona:1"), "helper subset still stores the exact row it did send")
assertFalse(hasLogId(memberOnly, "owner-Garona:2"), "helper subset does not complete owner-Garona:2")
assertFalse(hasLogId(memberOnly, "owner-Garona:3"), "helper subset does not complete owner-Garona:3")

activateSession(profile)
ProductionSync.QueueRepairRanges(Sync, profile:GetProfileId(), {
    {
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 25,
        mode = "integrity",
        exactAuthor = true,
        expectedCount = 4,
        expectedChecksum = 123,
        expectedMaxCounter = 20,
    },
}, { mode = "integrity", reason = "test-expected-evidence" })
helperServed = nil
for _, entry in pairs(Sync.state.repairQueue.items or {}) do
    helperServed = entry
    break
end
assertTrue(helperServed ~= nil, "integrity evidence range was queued")
assertEq(helperServed.expectedCount, 4, "queue copies expectedCount")
assertEq(helperServed.expectedChecksum, 123, "queue copies expectedChecksum")
assertEq(helperServed.expectedMaxCounter, 20, "queue copies expectedMaxCounter")
restoreUniqueNonces()
end
runExactAuthorRepairRoutingTests()

local function runExactAuthorProofTests()
local function outstandingCount()
    local n = 0
    for _ in pairs(Sync.state.requests or {}) do
        n = n + 1
    end
    return n
end
local function adminAddedCount(p)
    local n = 0
    for _, log in ipairs(p:GetLootLogs() or {}) do
        if log:GetEventType() == SF.LootLogEventTypes.ADMIN_ADDED then
            n = n + 1
        end
    end
    return n
end
local function seedSparseExact(name)
    local p = makeProfile(name)
    addMember(p, ALT_A)
    assertTrue(p:MergeLogTables({
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 1,
        }, { author = OWNER, counter = 1, timestamp = 1700020401 }),
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 2,
        }, { author = OWNER, counter = 2, timestamp = 1700020402 }),
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 3,
        }, { author = OWNER, counter = 3, timestamp = 1700020403 }),
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 11,
        }, { author = "owner-Garona", counter = 1, timestamp = 1700020411 }),
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 13,
        }, { author = "owner-Garona", counter = 3, timestamp = 1700020413 }),
    }) > 0, "sparse exact source stores owner-Garona:1 and :3")
    if p.RebuildLogIndex then
        p:RebuildLogIndex()
    end
    p._adminUsers = { OWNER, OTHER }
    return p
end
local function ownerWindow(p)
    local summary = p:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
    local rows = summary and summary["owner-Garona"]
    return rows and rows[1] or nil
end

-- 1. Same max, missing earlier exact row
resetEnv()
local src = seedSparseExact("ProofSameMaxA")
local dest = cloneWithout(src, "ProofSameMaxB", "owner-Garona:1")
assertTrue(hasLogId(dest, "owner-Garona:3"), "local keeps owner-Garona:3")
assertFalse(hasLogId(dest, "owner-Garona:1"), "local lacks owner-Garona:1")
registerProfile(dest)
local missing, integrity = discoverFrom(dest, src)
assertTrue(rangeForAuthor(integrity, "owner-Garona") ~= nil, "same-max missing :1 still creates integrity mismatch")
local evid = rangeForAuthor(integrity, "owner-Garona")
assertEq(evid.expectedCount, 2, "integrity expectedCount is remote window count")
assertEq(evid.expectedMaxCounter, 3, "integrity expectedMaxCounter is remote filled frontier")
assertFalse(Sync:_ExactAuthorRangeSatisfied(dest:GetProfileId(), "owner-Garona", 1, 3, {
    expectedCount = 2,
    expectedMaxCounter = 3,
    expectedChecksum = evid.expectedChecksum,
    expectedFromCounter = evid.expectedFromCounter,
    expectedToCounter = evid.expectedToCounter,
    expectedWindows = evid.expectedWindows,
}), "exact max 3 does not satisfy missing owner-Garona:1")
applyDiscoveredRange(src, dest, evid, "REQ-PROOF-SAME-MAX")
assertTrue(hasLogId(dest, "owner-Garona:1"), "integrity obtained missing owner-Garona:1")
assertFalse(hasLogId(dest, "owner-Garona:2"), "same-max repair does not invent owner-Garona:2")
assertEq(dest:GetLogById("owner-Garona:1"):GetAuthor(), "owner-Garona", "repaired :1 keeps exact author")
assertTrue(Sync:_ExactAuthorRangeSatisfied(dest:GetProfileId(), "owner-Garona", evid.fromCounter, evid.toCounter, {
    expectedWindows = evid.expectedWindows,
    expectedCount = evid.expectedCount,
    expectedChecksum = evid.expectedChecksum,
    expectedMaxCounter = evid.expectedMaxCounter,
    expectedFromCounter = evid.expectedFromCounter,
    expectedToCounter = evid.expectedToCounter,
}), "local window matches remote after :1 arrives")
assertTrue(Sync.state.requests["REQ-PROOF-SAME-MAX"] == nil, "request completes only after window proof matches")

-- 2. Empty integrity AUTH_LOGS
resetEnv()
src = seedSparseExact("ProofEmptyA")
dest = cloneWithout(src, "ProofEmptyB", "owner-Garona:1")
registerProfile(dest)
activateSession(dest)
evid = ownerWindow(src)
Sync.state.requests["REQ-EMPTY"] = {
    kind = "LOG_REQ",
    meta = {
        profileId = dest:GetProfileId(),
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 3,
        exactAuthor = true,
        integrityRepair = true,
        expectedCount = evid.count,
        expectedChecksum = evid.checksum,
        expectedMaxCounter = evid.maxCounter,
        expectedFromCounter = evid.fromCounter,
        expectedToCounter = evid.toCounter,
        expectedWindows = {
            {
                fromCounter = evid.fromCounter,
                toCounter = evid.toCounter,
                count = evid.count,
                maxCounter = evid.maxCounter,
                checksum = evid.checksum,
            },
        },
    },
}
Sync:HandleAuthLogs(OWNER, {
    sessionId = "SES1",
    profileId = dest:GetProfileId(),
    requestId = "REQ-EMPTY",
    author = "owner-Garona",
    fromCounter = 1,
    toCounter = 3,
    logs = {},
})
assertTrue(Sync.state.requests["REQ-EMPTY"] ~= nil, "empty integrity AUTH_LOGS does not complete")
assertFalse(hasLogId(dest, "owner-Garona:1"), "empty payload does not insert owner-Garona:1")
assertTrue(#deferredAfter > 0, "empty integrity response schedules retry/fallback")

-- 3. Non-empty partial response (only :3)
resetEnv()
src = seedSparseExact("ProofPartialA")
dest = cloneWithout(src, "ProofPartialB", "owner-Garona:1")
registerProfile(dest)
activateSession(dest)
evid = ownerWindow(src)
local partial = dest:GetLogById("owner-Garona:3"):ToTable()
Sync.state.requests["REQ-PARTIAL"] = {
    kind = "LOG_REQ",
    meta = {
        profileId = dest:GetProfileId(),
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 3,
        exactAuthor = true,
        integrityRepair = true,
        expectedCount = evid.count,
        expectedChecksum = evid.checksum,
        expectedMaxCounter = evid.maxCounter,
        expectedFromCounter = evid.fromCounter,
        expectedToCounter = evid.toCounter,
        expectedWindows = {
            {
                fromCounter = evid.fromCounter,
                toCounter = evid.toCounter,
                count = evid.count,
                maxCounter = evid.maxCounter,
                checksum = evid.checksum,
            },
        },
    },
}
Sync:HandleAuthLogs(OWNER, {
    sessionId = "SES1",
    profileId = dest:GetProfileId(),
    requestId = "REQ-PARTIAL",
    author = "owner-Garona",
    fromCounter = 1,
    toCounter = 3,
    logs = { partial },
})
assertTrue(Sync.state.requests["REQ-PARTIAL"] ~= nil, "partial :3 AUTH_LOGS does not complete expected count 2")
assertFalse(hasLogId(dest, "owner-Garona:1"), "partial payload still lacks owner-Garona:1")
assertFalse(Sync:_ExactAuthorRangeSatisfied(dest:GetProfileId(), "owner-Garona", 1, evid.toCounter, {
    expectedCount = evid.count,
    expectedChecksum = evid.checksum,
    expectedMaxCounter = evid.maxCounter,
    expectedFromCounter = evid.fromCounter,
    expectedToCounter = evid.toCounter,
}), "receivedExactCount>0 is not enough without checksum/count match")

-- 4. Sparse complete response
resetEnv()
src = seedSparseExact("ProofSparseA")
dest = cloneWithout(src, "ProofSparseB", "owner-Garona:1")
evid = ownerWindow(src)
applyDiscoveredRange(src, dest, {
    author = "owner-Garona",
    fromCounter = 1,
    toCounter = 3,
    exactAuthor = true,
    integrityRepair = true,
    expectedCount = evid.count,
    expectedChecksum = evid.checksum,
    expectedMaxCounter = evid.maxCounter,
    expectedFromCounter = evid.fromCounter,
    expectedToCounter = evid.toCounter,
    expectedWindows = {
        {
            fromCounter = evid.fromCounter,
            toCounter = evid.toCounter,
            count = evid.count,
            maxCounter = evid.maxCounter,
            checksum = evid.checksum,
        },
    },
}, "REQ-SPARSE-COMPLETE")
assertTrue(hasLogId(dest, "owner-Garona:1"), "sparse complete obtained owner-Garona:1")
assertTrue(hasLogId(dest, "owner-Garona:3"), "sparse complete kept owner-Garona:3")
assertFalse(hasLogId(dest, "owner-Garona:2"), "sparse complete does not invent owner-Garona:2")
assertTrue(Sync.state.requests["REQ-SPARSE-COMPLETE"] == nil, "sparse complete AUTH_LOGS finished the request")
local destWindow = ownerWindow(dest)
assertEq(destWindow.count, evid.count, "sparse complete count matches remote")
assertEq(destWindow.maxCounter, evid.maxCounter, "sparse complete max matches remote")
assertEq(destWindow.checksum, evid.checksum, "sparse complete checksum matches remote")
registerProfile(src)
Sync.state.authorMax = src:ComputeAuthorMax()
Sync.state.authorWindowSummary = src:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
registerProfile(dest)
missing, integrity = discoverFrom(dest, src)
assertEq(#missing, 0, "sparse complete later discovery has no missing ranges")
assertTrue(rangeForAuthor(integrity, "owner-Garona") == nil, "sparse complete later discovery has no owner-Garona integrity")

-- 5. Fingerprint replacement
resetEnv()
src = seedSparseExact("ProofFpA")
dest = cloneWithout(src, "ProofFpB", "__none__")
local wrong = dest:GetLogById("owner-Garona:1"):ToTable()
wrong._data = { member = ALT_A, change = SF.LootLogPointChangeTypes.INCREMENT, amount = 99 }
wrong._fingerprint = SF.LootLog.ComputeFingerprintFromTable(wrong)
assertTrue(dest:MergeLogTables({ wrong }, { allowReplaceExisting = true }) >= 0, "local installs mismatched owner-Garona:1")
assertTrue(hasLogId(dest, "owner-Garona:1"), "fingerprint dest still has owner-Garona:1")
assertTrue(hasLogId(dest, "owner-Garona:3"), "fingerprint dest still has owner-Garona:3")
assertTrue(dest:GetLogById("owner-Garona:1"):GetFingerprint() ~= src:GetLogById("owner-Garona:1"):GetFingerprint(),
    "local :1 fingerprint disagrees with remote")
registerProfile(dest)
missing, integrity = discoverFrom(dest, src)
assertEq(#missing, 0, "matching maxima do not create completeness missing")
assertTrue(rangeForAuthor(integrity, "owner-Garona") ~= nil, "fingerprint mismatch still creates integrity repair")
evid = rangeForAuthor(integrity, "owner-Garona")
assertFalse(Sync:_ExactAuthorRangeSatisfied(dest:GetProfileId(), "owner-Garona", 1, 3, {
    expectedChecksum = evid.expectedChecksum,
    expectedCount = evid.expectedCount,
    expectedMaxCounter = evid.expectedMaxCounter,
    expectedFromCounter = evid.expectedFromCounter,
    expectedToCounter = evid.expectedToCounter,
    expectedWindows = evid.expectedWindows,
}), "mismatched fingerprint fails advertised checksum")
applyDiscoveredRange(src, dest, evid, "REQ-FP")
assertEq(dest:GetLogById("owner-Garona:1"):GetFingerprint(), src:GetLogById("owner-Garona:1"):GetFingerprint(),
    "trusted integrity merge replaces mismatched owner-Garona:1")
assertEq(dest:GetLogById("owner-Garona:1"):GetAuthor(), "owner-Garona", "replacement keeps exact _author")
assertEq(dest:GetLogById("owner-Garona:1"):GetID(), "owner-Garona:1", "replacement keeps exact _id")
assertTrue(Sync.state.requests["REQ-FP"] == nil, "fingerprint repair completes after checksum matches")
assertEq(ownerWindow(dest).checksum, evid.expectedChecksum, "local checksum matches expected after replace")

-- 6. Fallback helper with same exact max but incomplete set
resetEnv()
src = seedSparseExact("ProofHelperA")
local helper = cloneWithout(src, "ProofHelperH", "owner-Garona:1")
dest = cloneWithout(src, "ProofHelperM", "owner-Garona:1")
dest = cloneWithout(dest, "ProofHelperM2", "owner-Garona:3")
src._adminUsers = { OWNER, OTHER }
helper._adminUsers = { OWNER, OTHER }
dest._adminUsers = { OWNER, OTHER }
assertFalse(hasLogId(helper, "owner-Garona:1"), "helper lacks owner-Garona:1")
assertTrue(hasLogId(helper, "owner-Garona:3"), "helper has owner-Garona:3")
assertFalse(hasLogId(dest, "owner-Garona:1"), "member lacks owner-Garona:1")
assertFalse(hasLogId(dest, "owner-Garona:3"), "member lacks owner-Garona:3")
evid = ownerWindow(src)
registerProfile(dest)
activateSession(dest)
Sync.state.isCoordinator = false
Sync.state.coordinator = OWNER
Sync.state.helpers = { OTHER }
Sync.state.authorWindowSummary = src:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.authorMax = src:ComputeAuthorMax()
Sync.cfg.maxRetries = 5
local originalSend = SF.LootHelperComm.Send
local originalQueue = Sync.QueueRepairRanges
Sync.QueueRepairRanges = ProductionSync.QueueRepairRanges
SF.LootHelperComm.Send = function(_, prefix, msgType, payload, dist, target)
    capturedComm[#capturedComm + 1] = { prefix = prefix, msgType = msgType, payload = payload, target = target }
    return true
end
assertTrue(Sync:RequestMissingLogs({
    {
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 3,
        exactAuthor = true,
        preferredTarget = OWNER,
        expectedCount = evid.count,
        expectedChecksum = evid.checksum,
        expectedMaxCounter = evid.maxCounter,
        expectedFromCounter = evid.fromCounter,
        expectedToCounter = evid.toCounter,
        expectedWindows = {
            {
                fromCounter = evid.fromCounter,
                toCounter = evid.toCounter,
                count = evid.count,
                maxCounter = evid.maxCounter,
                checksum = evid.checksum,
            },
        },
    },
}, "proof-helper-fallback", { preferredTarget = OWNER, exactAuthor = true }), "exact completeness request registered")
local reqId = nil
local req = nil
for id, pending in pairs(Sync.state.requests) do
    reqId = id
    req = pending
    break
end
assertTrue(req ~= nil, "fallback test has an outstanding NEED_LOGS")
assertEq(req.lastTarget, OWNER, "first attempt prefers the advertising coordinator")
Sync:OnRequestTimeout(reqId)
assertEq(req.lastTarget, OTHER, "timeout walks to the fallback helper")
registerProfile(helper)
local helperPlayer = PLAYER
PLAYER = OTHER
capturedComm = {}
Sync:HandleNeedLogs(dest._author or "Member-Garona", {
    sessionId = "SES1",
    profileId = dest:GetProfileId(),
    requestId = reqId,
    exactAuthor = true,
    missing = {
        {
            author = "owner-Garona",
            fromCounter = 1,
            toCounter = 3,
            exactAuthor = true,
        },
    },
})
PLAYER = helperPlayer
local helperServed = findCaptured(Sync.MSG.AUTH_LOGS)
assertTrue(helperServed ~= nil, "helper produced AUTH_LOGS")
assertEq(#(helperServed.payload.logs or {}), 1, "helper AUTH_LOGS contains only the exact row it has")
assertTrue(payloadHasAuthor(helperServed.payload, "owner-Garona"), "helper AUTH_LOGS is exact owner-Garona")
registerProfile(dest)
PLAYER = OWNER
Sync.state.isCoordinator = false
Sync.state.coordinator = OWNER
helperServed.payload.sessionId = "SES1"
helperServed.payload.profileId = dest:GetProfileId()
helperServed.payload.requestId = reqId
Sync:HandleAuthLogs(OTHER, helperServed.payload)
assertTrue(Sync.state.requests[reqId] ~= nil, "helper :3 does not satisfy coordinator sparse history")
assertFalse(hasLogId(dest, "owner-Garona:1"), "helper fallback did not supply owner-Garona:1")
registerProfile(src)
capturedComm = {}
PLAYER = OWNER
Sync.state.isCoordinator = true
Sync.state.coordinator = OWNER
Sync:HandleNeedLogs("Member-Garona", {
    sessionId = "SES1",
    profileId = dest:GetProfileId(),
    requestId = reqId,
    exactAuthor = true,
    missing = {
        {
            author = "owner-Garona",
            fromCounter = 1,
            toCounter = 3,
            exactAuthor = true,
        },
    },
})
local coordServed = findCaptured(Sync.MSG.AUTH_LOGS)
assertTrue(coordServed ~= nil, "coordinator produced complete sparse AUTH_LOGS")
registerProfile(dest)
coordServed.payload.sessionId = "SES1"
coordServed.payload.profileId = dest:GetProfileId()
coordServed.payload.requestId = reqId
Sync.state.isCoordinator = false
Sync.state.coordinator = OWNER
Sync:HandleAuthLogs(OWNER, coordServed.payload)
assertTrue(hasLogId(dest, "owner-Garona:1"), "coordinator recovered owner-Garona:1 after helper fallback")
assertTrue(hasLogId(dest, "owner-Garona:3"), "coordinator recovered owner-Garona:3")
assertFalse(hasLogId(dest, "owner-Garona:2"), "fallback recovery does not invent :2")
assertEq(ownerWindow(dest).checksum, evid.checksum, "final raw window matches expected checksum")
assertTrue(Sync.state.requests[reqId] == nil, "request completes after coordinator proof matches")
SF.LootHelperComm.Send = originalSend
Sync.QueueRepairRanges = originalQueue

-- 7. Exact missing must not suppress exact integrity
resetEnv()
src = seedSparseExact("ProofOverlapA")
dest = cloneWithout(src, "ProofOverlapB", "owner-Garona:3")
wrong = dest:GetLogById("owner-Garona:1"):ToTable()
wrong._data = { member = ALT_A, change = SF.LootLogPointChangeTypes.INCREMENT, amount = 77 }
wrong._fingerprint = SF.LootLog.ComputeFingerprintFromTable(wrong)
assertTrue(dest:MergeLogTables({ wrong }, { allowReplaceExisting = true }) >= 0, "overlap dest has mismatched :1")
registerProfile(dest)
missing, integrity = discoverFrom(dest, src)
assertTrue(rangeForAuthor(missing, "owner-Garona") ~= nil, "absent :3 creates exact missing")
assertTrue(rangeForAuthor(integrity, "owner-Garona") ~= nil, "mismatched :1 creates exact integrity")
activateSession(dest)
Sync.state.requests["REQ-MISS"] = {
    kind = "NEED_LOGS",
    meta = {
        profileId = dest:GetProfileId(),
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 3,
        exactAuthor = true,
    },
}
assertFalse(Sync:_HasOutstandingLogRangeRequest(dest:GetProfileId(), "owner-Garona", 1, 3, true, true),
    "exact missing does not suppress exact integrity")
Sync.QueueRepairRanges = ProductionSync.QueueRepairRanges
assertTrue(ProductionSync.QueueRepairRanges(Sync, dest:GetProfileId(), {
    rangeForAuthor(integrity, "owner-Garona"),
}, { mode = "integrity", reason = "proof-overlap" }), "integrity still queues beside exact missing")
local queuedIntegrity = false
for _, entry in pairs(Sync.state.repairQueue.items or {}) do
    if entry.mode == "integrity" and entry.author == "owner-Garona" then
        queuedIntegrity = true
    end
end
assertTrue(queuedIntegrity, "integrity repair entry exists beside outstanding exact missing")
evid = rangeForAuthor(integrity, "owner-Garona")
applyDiscoveredRange(src, dest, evid, "REQ-OVERLAP-INT")
assertTrue(hasLogId(dest, "owner-Garona:3"), "overlap integrity added missing owner-Garona:3")
assertEq(dest:GetLogById("owner-Garona:1"):GetFingerprint(), src:GetLogById("owner-Garona:1"):GetFingerprint(),
    "overlap integrity replaced mismatched owner-Garona:1")
assertEq(ownerWindow(dest).checksum, evid.expectedChecksum, "overlap local window matches expected checksum")

-- 8. Identity-admin gating stays blocked on incomplete integrity
resetEnv()
src = seedSparseExact("ProofGateA")
dest = cloneWithout(src, "ProofGateB", "owner-Garona:1")
addMember(dest, ALT_B)
dest:AddAdminMemberId(ALT_A)
local impliedLink = makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
    memberA = ALT_A,
    memberB = ALT_B,
    adminMembersAtLink = { ALT_A },
}, { timestamp = 1700020500, counter = (dest._authorCounters[OWNER] or 0) + 1 })
assertTrue(dest:MergeLogTables({ impliedLink }) > 0, "implied LINK waits on integrity proof")
registerProfile(dest)
activateSession(dest)
evid = ownerWindow(src)
Sync.state.authorMax = src:ComputeAuthorMax()
Sync.state.authorWindowSummary = src:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.requests["REQ-GATE"] = {
    id = "REQ-GATE",
    kind = "LOG_REQ",
    meta = {
        profileId = dest:GetProfileId(),
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 3,
        exactAuthor = true,
        integrityRepair = true,
        expectedCount = evid.count,
        expectedChecksum = evid.checksum,
        expectedMaxCounter = evid.maxCounter,
        expectedFromCounter = evid.fromCounter,
        expectedToCounter = evid.toCounter,
        expectedWindows = {
            {
                fromCounter = evid.fromCounter,
                toCounter = evid.toCounter,
                count = evid.count,
                maxCounter = evid.maxCounter,
                checksum = evid.checksum,
            },
        },
    },
}
local grantsBefore = adminAddedCount(dest)
assertFalse(Sync:IsIdentityAdminReconcileReady(dest:GetProfileId()), "integrity discrepancy blocks identity-admin reconcile")
Sync:ScheduleIdentityAdminReconcile(dest:GetProfileId())
assertFalse(dest:IsAdminMemberId(ALT_B), "incomplete integrity does not persist implied ADMIN_ADDED")
Sync:HandleAuthLogs(OWNER, {
    sessionId = "SES1",
    profileId = dest:GetProfileId(),
    requestId = "REQ-GATE",
    author = "owner-Garona",
    fromCounter = 1,
    toCounter = 3,
    logs = {},
})
assertTrue(Sync.state.requests["REQ-GATE"] ~= nil, "empty integrity AUTH_LOGS keeps the request pending")
assertFalse(Sync:IsIdentityAdminReconcileReady(dest:GetProfileId()), "empty integrity response keeps reconcile unready")
Sync:ConsiderIdentityAdminSideEffects(dest:GetProfileId())
assertFalse(dest:IsAdminMemberId(ALT_B), "false completion does not emit ADMIN_ADDED")
assertEq(adminAddedCount(dest), grantsBefore, "no extra ADMIN_ADDED during incomplete integrity")
applyDiscoveredRange(src, dest, {
    author = "owner-Garona",
    fromCounter = 1,
    toCounter = 3,
    exactAuthor = true,
    integrityRepair = true,
    expectedCount = evid.count,
    expectedChecksum = evid.checksum,
    expectedMaxCounter = evid.maxCounter,
    expectedFromCounter = evid.fromCounter,
    expectedToCounter = evid.toCounter,
    expectedWindows = {
        {
            fromCounter = evid.fromCounter,
            toCounter = evid.toCounter,
            count = evid.count,
            maxCounter = evid.maxCounter,
            checksum = evid.checksum,
        },
    },
}, "REQ-GATE-COMPLETE")
assertTrue(hasLogId(dest, "owner-Garona:1"), "gating path obtained owner-Garona:1")
assertEq(ownerWindow(dest).checksum, evid.checksum, "gating path window proof matches")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state.authorMax = dest:ComputeAuthorMax()
Sync.state.authorWindowSummary = dest:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
assertTrue(Sync:IsIdentityAdminReconcileReady(dest:GetProfileId()), "reconcile may proceed after integrity proof matches")
Sync:ScheduleIdentityAdminReconcile(dest:GetProfileId())
assertTrue(dest:IsAdminMemberId(ALT_B), "reconcile grants after exact integrity is proven")

local function runExactAuthorHangTests()
-- Mutation integrity without pre-stamped windows binds session proof and
-- still refuses to complete on max alone while :1 is missing.
resetEnv()
src = seedSparseExact("ProofHangMutA")
dest = cloneWithout(src, "ProofHangMutB", "owner-Garona:1")
registerProfile(dest)
activateSession(dest)
Sync.state.isCoordinator = false
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 1
Sync.QueueRepairRanges = ProductionSync.QueueRepairRanges
local srcSummary = src:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.authorWindowSummary = srcSummary
assertTrue(ProductionSync.QueueRepairRanges(Sync, dest:GetProfileId(), {
    {
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 3,
        mode = "integrity",
        exactAuthor = true,
    },
}, { mode = "integrity", reason = "proof-mutation-no-windows" }), "proof-less mutation integrity still queues")
local queuedMutation = nil
for _, entry in pairs(Sync.state.repairQueue.items or {}) do
    if entry.mode == "integrity" and entry.author == "owner-Garona" then
        queuedMutation = entry
    end
end
assertTrue(queuedMutation ~= nil, "mutation integrity queue entry exists")
assertTrue(type(queuedMutation.expectedWindows) == "table" and #queuedMutation.expectedWindows > 0,
    "queue stamps session window proof onto proof-less mutation integrity")
assertEq(queuedMutation.expectedCount, srcSummary["owner-Garona"][1].count,
    "stamped mutation evidence uses advertiser count")
assertFalse(Sync:_ExactAuthorRangeSatisfied(dest:GetProfileId(), "owner-Garona", 1, 3),
    "late-bind session proof still fails while owner-Garona:1 is missing")
assertFalse(Sync:_ExactAuthorRangeSatisfied(dest:GetProfileId(), "owner-Garona", 1, 3, {
    expectedMaxCounter = 3,
}), "exact max 3 without count/checksum is not window proof")

-- AdvertiseProfileMutation stamps the advertiser's local windows.
resetEnv()
src = seedSparseExact("ProofHangAdvA")
registerProfile(src)
activateSession(src)
assertTrue(Sync:AdvertiseProfileMutation(src:GetProfileId(), {
    { author = "owner-Garona", fromCounter = 1, toCounter = 3 },
}, "proof-advertise"), "mutation advertisement stored")
local pending = Sync.state._pendingMutationAdvertisement
assertTrue(pending ~= nil and type(pending.ranges) == "table" and pending.ranges[1] ~= nil,
    "pending mutation ranges exist")
assertTrue(type(pending.ranges[1].expectedWindows) == "table" and #pending.ranges[1].expectedWindows > 0,
    "advertiser stamps overlapping local windows onto mutation ranges")

-- Proof-less outstanding integrity is upgraded instead of blocking later proof.
resetEnv()
src = seedSparseExact("ProofHangUpA")
dest = cloneWithout(src, "ProofHangUpB", "owner-Garona:1")
registerProfile(dest)
activateSession(dest)
evid = ownerWindow(src)
Sync.state.requests["REQ-PROOFLESS"] = {
    kind = "LOG_REQ",
    meta = {
        profileId = dest:GetProfileId(),
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 3,
        exactAuthor = true,
        integrityRepair = true,
    },
}
assertTrue(Sync:_HasOutstandingLogRangeRequest(dest:GetProfileId(), "owner-Garona", 1, 3, true, true),
    "proof-less integrity is outstanding")
Sync.QueueRepairRanges = ProductionSync.QueueRepairRanges
assertFalse(ProductionSync.QueueRepairRanges(Sync, dest:GetProfileId(), {
    {
        author = "owner-Garona",
        fromCounter = 1,
        toCounter = 3,
        mode = "integrity",
        exactAuthor = true,
        expectedCount = evid.count,
        expectedChecksum = evid.checksum,
        expectedMaxCounter = evid.maxCounter,
        expectedFromCounter = evid.fromCounter,
        expectedToCounter = evid.toCounter,
        expectedWindows = {
            {
                fromCounter = evid.fromCounter,
                toCounter = evid.toCounter,
                count = evid.count,
                maxCounter = evid.maxCounter,
                checksum = evid.checksum,
            },
        },
    },
}, { mode = "integrity", reason = "proof-upgrade" }), "later evidence does not duplicate an outstanding integrity request")
assertEq(Sync.state.requests["REQ-PROOFLESS"].meta.expectedChecksum, evid.checksum,
    "outstanding proof-less integrity is upgraded with advertised checksum")
assertTrue(type(Sync.state.requests["REQ-PROOFLESS"].meta.expectedWindows) == "table"
    and #Sync.state.requests["REQ-PROOFLESS"].meta.expectedWindows > 0,
    "upgraded outstanding request carries expectedWindows")
applyDiscoveredRange(src, dest, {
    author = "owner-Garona",
    fromCounter = 1,
    toCounter = 3,
    exactAuthor = true,
    integrityRepair = true,
    expectedCount = evid.count,
    expectedChecksum = evid.checksum,
    expectedMaxCounter = evid.maxCounter,
    expectedFromCounter = evid.fromCounter,
    expectedToCounter = evid.toCounter,
    expectedWindows = Sync.state.requests["REQ-PROOFLESS"].meta.expectedWindows,
}, "REQ-PROOFLESS")
assertTrue(hasLogId(dest, "owner-Garona:1"), "upgraded integrity obtained owner-Garona:1")
assertFalse(hasLogId(dest, "owner-Garona:2"), "upgraded integrity does not invent owner-Garona:2")
assertTrue(Sync.state.requests["REQ-PROOFLESS"] == nil, "upgraded integrity completes after window proof matches")

-- Heartbeat mutation copies advertiser windows even when range fields omit them.
resetEnv()
src = seedSparseExact("ProofHangHbA")
dest = cloneWithout(src, "ProofHangHbB", "owner-Garona:1")
registerProfile(dest)
activateSession(dest)
PLAYER = OTHER
Sync.state.isCoordinator = false
Sync.state.coordinator = OWNER
Sync.state.coordEpoch = 1
Sync.state.heartbeat = { lastCatchupAt = 0 }
Sync.cfg.catchupOnHeartbeatCooldownSec = 10
Sync.QueueRepairRanges = ProductionSync.QueueRepairRanges
local hbSummary = src:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync:HandleSessionHeartbeat(OWNER, {
    sessionId = "SES1",
    profileId = dest:GetProfileId(),
    coordinator = OWNER,
    coordEpoch = 1,
    helpers = {},
    authorMax = src:ComputeAuthorMax(),
    authorWindowSummary = hbSummary,
    integrityHint = "mutation",
    mutationReason = "proof-heartbeat-mutation",
    mutationRanges = {
        { author = "owner-Garona", fromCounter = 1, toCounter = 3 },
    },
    sentAt = 1,
})
PLAYER = OWNER
queuedMutation = nil
for _, entry in pairs(Sync.state.repairQueue.items or {}) do
    if entry.mode == "integrity" and entry.author == "owner-Garona" then
        queuedMutation = entry
    end
end
assertTrue(queuedMutation ~= nil, "heartbeat mutation queued integrity without pre-stamped range windows")
assertTrue(type(queuedMutation.expectedWindows) == "table" and #queuedMutation.expectedWindows > 0,
    "heartbeat mutation attached overlapping advertiser windows")
assertEq(queuedMutation.expectedChecksum, hbSummary["owner-Garona"][1].checksum,
    "heartbeat mutation evidence matches advertiser checksum")

-- Single-counter NEW_LOG fingerprint mismatch stamps row proof.
resetEnv()
src = seedSparseExact("ProofHangFpA")
dest = cloneWithout(src, "ProofHangFpB", "__none__")
local incoming = src:GetLogById("owner-Garona:1"):ToTable()
local localWrong = dest:GetLogById("owner-Garona:1"):ToTable()
localWrong._data = { member = ALT_A, change = SF.LootLogPointChangeTypes.INCREMENT, amount = 99 }
localWrong._fingerprint = SF.LootLog.ComputeFingerprintFromTable(localWrong)
assertTrue(dest:MergeLogTables({ localWrong }, { allowReplaceExisting = true }) >= 0,
    "local installs mismatched owner-Garona:1 for NEW_LOG")
registerProfile(dest)
activateSession(dest)
Sync.state.isCoordinator = true
Sync.QueueRepairRanges = ProductionSync.QueueRepairRanges
Sync:HandleNewLog(OWNER, {
    sessionId = "SES1",
    profileId = dest:GetProfileId(),
    log = incoming,
})
local queuedFp = nil
for _, entry in pairs(Sync.state.repairQueue.items or {}) do
    if entry.mode == "integrity" and entry.author == "owner-Garona" then
        queuedFp = entry
    end
end
assertTrue(queuedFp ~= nil, "NEW_LOG fingerprint mismatch queued integrity")
assertEq(queuedFp.fromCounter, 1, "fingerprint integrity is the mismatched counter")
assertEq(queuedFp.toCounter, 1, "fingerprint integrity stays single-counter")
assertTrue(type(queuedFp.expectedWindows) == "table" and #queuedFp.expectedWindows > 0,
    "fingerprint integrity carries row window proof")
assertEq(queuedFp.expectedCount, 1, "fingerprint row proof expects a single exact row")
local rowWindow = Sync:_MakeExactRowWindowEvidence("owner-Garona", 1, "owner-Garona:1", incoming._fingerprint)
assertEq(queuedFp.expectedChecksum, rowWindow.checksum, "fingerprint proof checksum matches incoming row")
assertFalse(Sync:_ExactAuthorRangeSatisfied(dest:GetProfileId(), "owner-Garona", 1, 1, {
    expectedWindows = queuedFp.expectedWindows,
    expectedCount = queuedFp.expectedCount,
    expectedChecksum = queuedFp.expectedChecksum,
    expectedMaxCounter = queuedFp.expectedMaxCounter,
}), "mismatched local fingerprint does not satisfy incoming row proof")
end
runExactAuthorHangTests()

local function runAdminConvergenceIntegrityTests()
local function installUniqueNonces()
    local nonce = 0
    function Sync:_NextNonce(tag)
        nonce = nonce + 1
        return tostring(tag or "N") .. tostring(nonce)
    end
end
local function restoreUniqueNonces()
    function Sync:_NextNonce(tag)
        return tostring(tag or "N") .. "1"
    end
end
local function findReqForAuthor(author, integrity)
    for id, req in pairs(Sync.state.requests or {}) do
        local meta = req and req.meta
        if type(meta) == "table" and meta.author == author then
            if integrity == nil or (meta.integrityRepair == true) == integrity then
                return id, req
            end
        end
    end
    return nil, nil
end
local function queuedRepairFor(author)
    for _, entry in pairs((Sync.state.repairQueue and Sync.state.repairQueue.items) or {}) do
        if entry.author == author then
            return entry
        end
    end
    return nil
end
local function seedEqualMaxMissing(coordName, remoteName)
    local remote = makeProfile(remoteName)
    addMember(remote, ALT_A)
    addMember(remote, ALT_B)
    addMember(remote, OTHER)
    if remote.RebuildLogIndex then
        remote:RebuildLogIndex()
    end
    assertTrue(remote:MergeLogTables({
        makeTable(SF.LootLogEventTypes.ADMIN_ADDED, {
            member = ALT_A,
        }, { author = OWNER, counter = 2, timestamp = 1700020575 }),
        makeTable(SF.LootLogEventTypes.ADMIN_REMOVED, {
            member = ALT_A,
            preOpAuthorMax = {
                { author = OWNER, counter = 2 },
            },
        }, { author = "owner-Garona", counter = 1, timestamp = 1700020590 }),
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 2,
        }, { author = OWNER, counter = 3, timestamp = 1700020602 }),
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 13,
        }, { author = "owner-Garona", counter = 3, timestamp = 1700020613 }),
        makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
            memberA = ALT_A,
            memberB = ALT_B,
            adminMembersAtLink = { ALT_A },
        }, { author = OWNER, counter = 4, timestamp = 1700020700 }),
    }) > 0, "remote equal-max store has owner-Garona:1 and :3")
    if remote.RebuildLogIndex then
        remote:RebuildLogIndex()
    end
    remote._adminUsers = { OWNER, OTHER }
    local coord = cloneWithout(remote, coordName, "owner-Garona:1")
    coord._adminUsers = { OWNER, OTHER }
    assertTrue(hasLogId(coord, OWNER .. ":4"), "coordinator implied LINK waits on remote owner-Garona:1")
    return coord, remote
end
local function startConv(profile)
    registerProfile(profile)
    activateSession(profile)
    profile._adminUsers = { OWNER, OTHER }
    Sync.state.isCoordinator = true
    Sync.state.coordEpoch = 1
    Sync.QueueRepairRanges = ProductionSync.QueueRepairRanges
    installUniqueNonces()
    Sync:BeginAdminConvergence(Sync.state.sessionId, profile:GetProfileId(), {
        onComplete = function() end,
    })
end

-- A. Equal raw max, missing earlier exact row; fetch failure must not forget proof.
resetEnv()
local coord, remote = seedEqualMaxMissing("ConvMissCoord", "ConvMissRemote")
assertFalse(hasLogId(coord, "owner-Garona:1"), "coordinator lacks owner-Garona:1")
assertTrue(hasLogId(coord, "owner-Garona:3"), "coordinator has owner-Garona:3")
assertEq(coord:ComputeAuthorMax()["owner-Garona"], remote:ComputeAuthorMax()["owner-Garona"],
    "raw owner-Garona max is equal")
startConv(coord)
local remoteSummary = remote:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
local localSummary = coord:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.authorWindowSummary = localSummary
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remoteSummary,
    },
}
Sync:FinalizeAdminConvergence()
local reqId, req = findReqForAuthor("owner-Garona", true)
assertTrue(req ~= nil, "equal-max missing :1 creates integrity ADMIN_LOG_REQ")
assertTrue(req.meta.integrityRepair == true, "equal-max discrepancy is integrity repair")
assertTrue(req.meta.backgroundRepair == true, "admin integrity request is background-repair-backed")
assertEq(req.meta.preferredTarget, OTHER, "integrity provider is the advertising admin")
assertTrue(type(req.meta.expectedWindows) == "table" and #req.meta.expectedWindows > 0,
    "integrity request carries remote window proof")
assertEq(req.meta.expectedChecksum, remoteSummary["owner-Garona"][1].checksum,
    "integrity expected checksum is the remote advertiser checksum")
assertTrue(req.meta.expectedChecksum ~= (localSummary["owner-Garona"] and localSummary["owner-Garona"][1] and localSummary["owner-Garona"][1].checksum),
    "integrity proof is not the coordinator-local checksum")
local grantsBefore = adminAddedCount(coord)
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()), "known remote integrity blocks reconcile")
Sync:ScheduleIdentityAdminReconcile(coord:GetProfileId())
assertFalse(coord:IsAdminMemberId(ALT_B), "unresolved integrity does not persist implied ADMIN_ADDED")
assertEq(adminAddedCount(coord), grantsBefore, "no ADMIN_ADDED while remote proof is unresolved")

-- Case 1: convergence timeout first, then request exhausts.
Sync:_FinishAdminConvergence("timeout")
assertTrue(Sync.state.requests[reqId] ~= nil, "timeout leaves ADMIN_LOG_REQ outstanding")
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()), "timeout while outstanding still blocks reconcile")
assertFalse(coord:IsAdminMemberId(ALT_B), "timeout does not emit ADMIN_ADDED")
Sync:_FailRequest(req, "max attempts reached")
assertTrue(Sync.state.requests[reqId] == nil, "exhausted ADMIN_LOG_REQ is removed")
assertTrue(queuedRepairFor("owner-Garona") ~= nil, "failed admin integrity is requeued with proof")
assertEq(queuedRepairFor("owner-Garona").expectedChecksum, remoteSummary["owner-Garona"][1].checksum,
    "requeued integrity keeps remote checksum")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "clearing the failed request does not forget advertised remote windows")
assertFalse(coord:IsAdminMemberId(ALT_B), "forgotten request still cannot grant ADMIN_ADDED")

-- Case 2: request failure first.
resetEnv()
coord, remote = seedEqualMaxMissing("ConvFailFirstCoord", "ConvFailFirstRemote")
startConv(coord)
remoteSummary = remote:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.authorWindowSummary = coord:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remoteSummary,
    },
}
Sync:FinalizeAdminConvergence()
reqId, req = findReqForAuthor("owner-Garona", true)
assertTrue(req ~= nil, "failure-first path created integrity ADMIN_LOG_REQ")
grantsBefore = adminAddedCount(coord)
Sync:_FailRequest(req, "max attempts reached")
assertTrue(Sync.state._adminConvergence == nil, "pendingCount 0 finishes admin convergence after failure")
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "complete_after_failure does not erase remote integrity frontier")
assertFalse(coord:IsAdminMemberId(ALT_B), "failure-first path does not persist implied ADMIN_ADDED")
assertEq(adminAddedCount(coord), grantsBefore, "no extra ADMIN_ADDED after request failure")

-- Case 3: RegisterRequest failure still keeps the mismatch known/retryable.
resetEnv()
coord, remote = seedEqualMaxMissing("ConvRegFailCoord", "ConvRegFailRemote")
startConv(coord)
remoteSummary = remote:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.authorWindowSummary = coord:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remoteSummary,
    },
}
local originalRegister = Sync.RegisterRequest
function Sync:RegisterRequest()
    return false
end
Sync:FinalizeAdminConvergence()
Sync.RegisterRequest = originalRegister
assertTrue(queuedRepairFor("owner-Garona") ~= nil, "register failure queues advertised integrity repair")
assertEq(queuedRepairFor("owner-Garona").expectedChecksum, remoteSummary["owner-Garona"][1].checksum,
    "queued register-failure repair uses remote checksum")
Sync.state.requests = {}
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "register failure does not treat remote integrity as resolved")
assertFalse(coord:IsAdminMemberId(ALT_B), "register failure does not persist implied ADMIN_ADDED")

-- Restore provider and prove the missing row; only then reconcile.
resetEnv()
coord, remote = seedEqualMaxMissing("ConvRestoreCoord", "ConvRestoreRemote")
startConv(coord)
remoteSummary = remote:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.authorWindowSummary = coord:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remoteSummary,
    },
}
Sync:FinalizeAdminConvergence()
local evid = remoteSummary["owner-Garona"][1]
applyDiscoveredRange(remote, coord, {
    author = "owner-Garona",
    fromCounter = evid.fromCounter,
    toCounter = evid.maxCounter,
    exactAuthor = true,
    integrityRepair = true,
    expectedCount = evid.count,
    expectedChecksum = evid.checksum,
    expectedMaxCounter = evid.maxCounter,
    expectedFromCounter = evid.fromCounter,
    expectedToCounter = evid.toCounter,
    expectedWindows = { evid },
}, "REQ-CONV-RESTORE")
assertTrue(hasLogId(coord, "owner-Garona:1"), "restored provider supplied owner-Garona:1")
assertEq(coord:GetLogById("owner-Garona:1"):GetAuthor(), "owner-Garona", "restored row keeps exact author")
assertFalse(hasLogId(coord, "owner-Garona:2"), "restore does not invent owner-Garona:2")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state._adminConvergence = nil
assertTrue(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "reconcile may run after local window matches remote proof")
Sync:ScheduleIdentityAdminReconcile(coord:GetProfileId())
assertFalse(coord:IsAdminMemberId(ALT_B), "complete remote history with ADMIN_REMOVED does not grant B")
assertFalse(coord:IsAdminMemberId(ALT_A), "ADMIN_REMOVED remains in force after integrity proof matches")

-- B. Fingerprint mismatch with equal max.
resetEnv()
coord, remote = seedEqualMaxMissing("ConvFpCoord", "ConvFpRemote")
local wrong = coord:GetLogById("owner-Garona:3"):ToTable()
wrong._data = { member = ALT_A, change = SF.LootLogPointChangeTypes.INCREMENT, amount = 99 }
wrong._fingerprint = SF.LootLog.ComputeFingerprintFromTable(wrong)
assertTrue(coord:MergeLogTables({
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 11,
    }, { author = "owner-Garona", counter = 1, timestamp = 1700020590 }),
}, { allowReplaceExisting = true }) >= 0, "fingerprint coord installs owner-Garona:1 placeholder")
assertTrue(coord:MergeLogTables({ wrong }, { allowReplaceExisting = true }) >= 0,
    "fingerprint coord installs mismatched owner-Garona:3")
-- rebuild remote as sparse {1,3} with distinct :1 fingerprint vs coordinator placeholder
-- seedEqualMaxMissing remote already has ADMIN_REMOVED as :1; coordinator now has a POINT :1 plus wrong :3
startConv(coord)
remoteSummary = remote:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.authorWindowSummary = coord:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remoteSummary,
    },
}
Sync:FinalizeAdminConvergence()
reqId, req = findReqForAuthor("owner-Garona", true)
assertTrue(req ~= nil, "equal-max fingerprint mismatch creates integrity ADMIN_LOG_REQ")
assertEq(req.meta.expectedChecksum, remoteSummary["owner-Garona"][1].checksum,
    "fingerprint integrity uses remote checksum")
Sync:_FailRequest(req, "max attempts reached")
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "failed fingerprint integrity remains unresolved")
evid = remoteSummary["owner-Garona"][1]
applyDiscoveredRange(remote, coord, {
    author = "owner-Garona",
    fromCounter = evid.fromCounter,
    toCounter = evid.maxCounter,
    exactAuthor = true,
    integrityRepair = true,
    expectedCount = evid.count,
    expectedChecksum = evid.checksum,
    expectedMaxCounter = evid.maxCounter,
    expectedFromCounter = evid.fromCounter,
    expectedToCounter = evid.toCounter,
    expectedWindows = { evid },
}, "REQ-CONV-FP")
assertEq(coord:GetLogById("owner-Garona:1"):GetFingerprint(), remote:GetLogById("owner-Garona:1"):GetFingerprint(),
    "trusted integrity replaces mismatched/missing owner-Garona:1")
assertEq(coord:GetLogById("owner-Garona:3"):GetFingerprint(), remote:GetLogById("owner-Garona:3"):GetFingerprint(),
    "trusted integrity replaces mismatched owner-Garona:3")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
assertTrue(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "fingerprint repair completes only after remote checksum matches")

-- C. Exact missing uses remote provider windows, not coordinator-local proof.
resetEnv()
remote = makeProfile("ConvLocalProofRemote")
addMember(remote, ALT_A)
addMember(remote, OTHER)
assertTrue(remote:MergeLogTables({
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 2,
    }, { author = OWNER, counter = 2, timestamp = 1700020802 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 3,
    }, { author = OWNER, counter = 3, timestamp = 1700020803 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 11,
    }, { author = "owner-Garona", counter = 1, timestamp = 1700020811 }),
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 13,
    }, { author = "owner-Garona", counter = 3, timestamp = 1700020813 }),
}) > 0, "remote exact-missing source has owner-Garona:1 and :3")
if remote.RebuildLogIndex then
    remote:RebuildLogIndex()
end
remote._adminUsers = { OWNER, OTHER }
coord = cloneWithout(remote, "ConvLocalProofCoord", "owner-Garona:3")
coord._adminUsers = { OWNER, OTHER }
startConv(coord)
remoteSummary = remote:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
localSummary = coord:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.authorWindowSummary = localSummary
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remoteSummary,
    },
}
Sync:FinalizeAdminConvergence()
reqId, req = findReqForAuthor("owner-Garona", false)
if req == nil then
    reqId, req = findReqForAuthor("owner-Garona", true)
end
assertTrue(req ~= nil, "exact missing owner-Garona:3 is requested")
assertTrue(req.meta.exactAuthor == true, "exact missing keeps exactAuthor")
assertEq(req.meta.expectedChecksum, remoteSummary["owner-Garona"][1].checksum,
    "exact missing carries remote advertiser checksum")
assertTrue(req.meta.expectedChecksum ~= (localSummary["owner-Garona"] and localSummary["owner-Garona"][1] and localSummary["owner-Garona"][1].checksum),
    "exact missing does not use coordinator-local checksum")
assertEq(req.meta.expectedCount, remoteSummary["owner-Garona"][1].count,
    "exact missing expected count is remote window count")
assertEq(req.lastTarget, OTHER, "exact missing provider advertised owner-Garona max")
applyDiscoveredRange(remote, coord, {
    author = req.meta.author,
    fromCounter = req.meta.fromCounter,
    toCounter = req.meta.toCounter,
    exactAuthor = true,
    integrityRepair = req.meta.integrityRepair == true,
    expectedCount = req.meta.expectedCount,
    expectedChecksum = req.meta.expectedChecksum,
    expectedMaxCounter = req.meta.expectedMaxCounter,
    expectedFromCounter = req.meta.expectedFromCounter,
    expectedToCounter = req.meta.expectedToCounter,
    expectedWindows = req.meta.expectedWindows,
}, "REQ-CONV-LOCAL-PROOF")
assertTrue(hasLogId(coord, "owner-Garona:3"), "remote sparse :3 merged")
assertTrue(hasLogId(coord, "owner-Garona:1"), "remote sparse :1 kept")
assertFalse(hasLogId(coord, "owner-Garona:2"), "sparse exact missing does not invent :2")
assertTrue(Sync:_ExactAuthorRangeSatisfied(coord:GetProfileId(), "owner-Garona", req.meta.fromCounter, req.meta.toCounter, {
    expectedWindows = req.meta.expectedWindows,
    expectedCount = req.meta.expectedCount,
    expectedChecksum = req.meta.expectedChecksum,
    expectedMaxCounter = req.meta.expectedMaxCounter,
}), "merged remote {1,3} satisfies advertiser proof")

-- Fallback with a different window proof is not attached to the request.
resetEnv()
coord, remote = seedEqualMaxMissing("ConvFbCoord", "ConvFbRemote")
local otherRemote = cloneWithout(remote, "ConvFbOther", "__none__")
local wrongOther = otherRemote:GetLogById("owner-Garona:1"):ToTable()
wrongOther._data = { member = ALT_B }
wrongOther._fingerprint = SF.LootLog.ComputeFingerprintFromTable(wrongOther)
assertTrue(otherRemote:MergeLogTables({ wrongOther }, { allowReplaceExisting = true }) >= 0,
    "conflicting admin has a different owner-Garona:1 fingerprint")
startConv(coord)
remoteSummary = remote:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
local conflictSummary = otherRemote:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remoteSummary,
    },
    [ALT_C] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = otherRemote:ComputeAuthorMax(),
        authorWindowSummary = conflictSummary,
    },
}
addMember(coord, ALT_C)
coord._adminUsers = { OWNER, OTHER, ALT_C }
Sync:FinalizeAdminConvergence()
local otherReq = nil
local ownerReq = nil
for _, pending in pairs(Sync.state.requests or {}) do
    if pending.meta and pending.meta.author == "owner-Garona" and pending.meta.integrityRepair == true then
        if pending.meta.expectedChecksum == remoteSummary["owner-Garona"][1].checksum then
            ownerReq = pending
        elseif pending.meta.expectedChecksum == conflictSummary["owner-Garona"][1].checksum then
            otherReq = pending
        end
    end
end
assertTrue(ownerReq ~= nil, "OTHER's remote checksum gets its own integrity request")
assertTrue(otherReq ~= nil, "conflicting ALT_C checksum gets a distinct integrity request")
assertTrue(ownerReq.meta.expectedChecksum ~= otherReq.meta.expectedChecksum,
    "conflicting admin proofs are not flattened")
local otherInOwnerFallback = false
for _, target in ipairs(ownerReq.targets or {}) do
    if target == ALT_C then
        otherInOwnerFallback = true
    end
end
assertFalse(otherInOwnerFallback, "fallback list does not include a provider with unrelated proof")
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "conflicting admin window proofs fail closed")

-- Same-session reannounce/takeover rebuilds evidence from ADMIN_STATUS.
resetEnv()
coord, remote = seedEqualMaxMissing("ConvTakeCoord", "ConvTakeRemote")
startConv(coord)
remoteSummary = remote:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remoteSummary,
    },
}
Sync:FinalizeAdminConvergence()
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()), "pre-takeover remote proof blocks reconcile")
Sync.state.adminStatuses = {}
Sync.state._adminConvergence = nil
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
assertTrue(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "takeover/session rebuild may clear transient remote window evidence")
startConv(coord)
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remoteSummary,
    },
}
Sync:FinalizeAdminConvergence()
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "reconverged ADMIN_STATUS rebuilds the unresolved integrity blocker")

-- A behind admin's poorer window is not an unresolved remote dependency.
resetEnv()
coord, remote = seedEqualMaxMissing("ConvBehindCoord", "ConvBehindRemote")
startConv(coord)
remoteSummary = remote:ComputeAuthorWindowSummary(3)
evid = remoteSummary["owner-Garona"][1]
applyDiscoveredRange(remote, coord, {
    author = "owner-Garona",
    fromCounter = evid.fromCounter,
    toCounter = evid.maxCounter,
    exactAuthor = true,
    integrityRepair = true,
    expectedCount = evid.count,
    expectedChecksum = evid.checksum,
    expectedMaxCounter = evid.maxCounter,
    expectedFromCounter = evid.fromCounter,
    expectedToCounter = evid.toCounter,
    expectedWindows = { evid },
}, "REQ-CONV-BEHIND")
Sync.cfg = Sync.cfg or {}
local prevWindow = Sync.cfg.integrityWindowSize
Sync.cfg.integrityWindowSize = 3
startConv(coord)
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state._adminConvergence = nil
Sync.state.authorWindowSummary = coord:ComputeAuthorWindowSummary(3)
Sync.state.authorMax = coord:ComputeAuthorMax()
local behindRow = coord:GetLogById("owner-Garona:1")
local behindProof = Sync:_MakeExactRowWindowEvidence(
    "owner-Garona",
    1,
    "owner-Garona:1",
    behindRow and behindRow:GetFingerprint()
)
local behindWindow = {
    fromCounter = 1,
    toCounter = 3,
    count = 1,
    maxCounter = 1,
    checksum = behindProof.checksum,
}
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remote:ComputeAuthorWindowSummary(3),
    },
    [ALT_C] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = { [OWNER] = 2, ["owner-Garona"] = 1 },
        authorWindowSummary = {
            ["owner-Garona"] = { behindWindow },
        },
    },
}
addMember(coord, ALT_C)
coord._adminUsers = { OWNER, OTHER, ALT_C }
assertFalse(Sync:_HasUnresolvedRemoteWindowMismatch(coord:GetProfileId()),
    "behind admin poorer window is not an unresolved dependency")
assertTrue(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "behind admin does not stall identity-admin reconcile")
startConv(coord)
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = remote:ComputeAuthorMax(),
        authorWindowSummary = remote:ComputeAuthorWindowSummary(3),
    },
    [ALT_C] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = { [OWNER] = 2, ["owner-Garona"] = 1 },
        authorWindowSummary = {
            ["owner-Garona"] = { behindWindow },
        },
    },
}
coord._adminUsers = { OWNER, OTHER, ALT_C }
Sync:FinalizeAdminConvergence()
local aimedBehind = false
for _, pending in pairs(Sync.state.requests or {}) do
    if pending.meta and pending.meta.author == "owner-Garona" and pending.meta.preferredTarget == ALT_C then
        aimedBehind = true
    end
end
assertFalse(aimedBehind, "integrity is not aimed at a behind advertiser")
Sync.cfg.integrityWindowSize = prevWindow

-- Logical catch-up keeps in-request fallbacks when no window proof is attached.
resetEnv()
coord = makeProfile("ConvLogicalFb")
addMember(coord, OTHER)
addMember(coord, ALT_C)
startConv(coord)
coord._adminUsers = { OWNER, OTHER, ALT_C }
Sync.state.adminStatuses = {
    [OTHER] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = { [OWNER] = 2 },
    },
    [ALT_C] = {
        hasProfile = true,
        hasGaps = false,
        authorMax = { [OWNER] = 2 },
    },
}
Sync:FinalizeAdminConvergence()
local logicalReq = nil
for _, pending in pairs(Sync.state.requests or {}) do
    if pending.meta and pending.meta.author == OWNER and pending.meta.integrityRepair ~= true then
        logicalReq = pending
    end
end
assertTrue(logicalReq ~= nil, "logical catch-up request exists")
local sawOther, sawC = false, false
for _, name in ipairs(logicalReq.targets or {}) do
    if name == OTHER then
        sawOther = true
    end
    if name == ALT_C then
        sawC = true
    end
end
assertTrue(sawOther and sawC, "logical ADMIN_LOG_REQ keeps in-request fallbacks")

restoreUniqueNonces()
end
runAdminConvergenceIntegrityTests()

local function runAdvertisedContainmentTests()
local function installUniqueNonces()
    local nonce = 0
    function Sync:_NextNonce(tag)
        nonce = nonce + 1
        return tostring(tag or "N") .. tostring(nonce)
    end
end
local function restoreUniqueNonces()
    function Sync:_NextNonce(tag)
        return tostring(tag or "N") .. "1"
    end
end
local function findReqForAuthor(author, integrity)
    for id, req in pairs(Sync.state.requests or {}) do
        local meta = req and req.meta
        if type(meta) == "table" and meta.author == author then
            if integrity == nil or (meta.integrityRepair == true) == integrity then
                return id, req
            end
        end
    end
    return nil, nil
end
local function queuedRepairFor(author)
    for _, entry in pairs((Sync.state.repairQueue and Sync.state.repairQueue.items) or {}) do
        if entry.author == author then
            return entry
        end
    end
    return nil
end
local function startConv(profile)
    registerProfile(profile)
    activateSession(profile)
    profile._adminUsers = { OWNER, OTHER }
    Sync.state.isCoordinator = true
    Sync.state.coordEpoch = 1
    Sync.QueueRepairRanges = ProductionSync.QueueRepairRanges
    installUniqueNonces()
    Sync:BeginAdminConvergence(Sync.state.sessionId, profile:GetProfileId(), {
        onComplete = function() end,
    })
end
local function setRemoteAdmin(coord, remote, extraStatuses)
    local summary = remote:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
    Sync.state.authorWindowSummary = coord:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
    Sync.state.authorMax = coord:ComputeAuthorMax()
    Sync.state.adminStatuses = {
        [OTHER] = {
            hasProfile = true,
            hasGaps = false,
            authorMax = remote:ComputeAuthorMax(),
            authorWindowSummary = summary,
        },
    }
    if type(extraStatuses) == "table" then
        for name, st in pairs(extraStatuses) do
            Sync.state.adminStatuses[name] = st
        end
    end
    return summary
end
local function addOwnerSiblings(profile)
    assertTrue(profile:MergeLogTables({
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 2,
        }, { author = OWNER, counter = 2, timestamp = 1700030002 }),
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 3,
        }, { author = OWNER, counter = 3, timestamp = 1700030003 }),
    }) > 0, "SameAuthor sibling Owner-Garona rows exist")
end
local function seedLaterWindowConflict(coordName, remoteName)
    local remote = makeProfile(remoteName)
    addMember(remote, ALT_A)
    addMember(remote, ALT_B)
    addMember(remote, OTHER)
    addOwnerSiblings(remote)
    assertTrue(remote:MergeLogTables({
        makeTable(SF.LootLogEventTypes.ADMIN_ADDED, {
            member = ALT_A,
        }, { author = OWNER, counter = 4, timestamp = 1700030010 }),
        makeTable(SF.LootLogEventTypes.ADMIN_REMOVED, {
            member = ALT_A,
            preOpAuthorMax = {
                { author = OWNER, counter = 4 },
            },
        }, { author = "owner-Garona", counter = 1, timestamp = 1700030020 }),
        makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
            memberA = ALT_A,
            memberB = ALT_B,
            adminMembersAtLink = { ALT_A },
        }, { author = OWNER, counter = 5, timestamp = 1700030030 }),
    }) > 0, "remote later-window source has owner-Garona:1 ADMIN_REMOVED")
    if remote.RebuildLogIndex then
        remote:RebuildLogIndex()
    end
    remote._adminUsers = { OWNER, OTHER }
    local coord = cloneWithout(remote, coordName, "owner-Garona:1")
    local wrong = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 99,
    }, { author = "owner-Garona", counter = 1, timestamp = 1700030020 })
    assertTrue(coord:MergeLogTables({
        wrong,
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 30,
        }, { author = "owner-Garona", counter = 30, timestamp = 1700030090 }),
    }, { allowReplaceExisting = true }) > 0, "coordinator has wrong :1 plus later :30")
    if coord.RebuildLogIndex then
        coord:RebuildLogIndex()
    end
    coord._adminUsers = { OWNER, OTHER }
    return coord, remote
end
local function seedMissingEarlier(coordName, remoteName)
    local remote = makeProfile(remoteName)
    addMember(remote, ALT_A)
    addMember(remote, OTHER)
    addOwnerSiblings(remote)
    assertTrue(remote:MergeLogTables({
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 11,
        }, { author = "owner-Garona", counter = 1, timestamp = 1700030101 }),
    }) > 0, "remote missing-earlier source has owner-Garona:1")
    if remote.RebuildLogIndex then
        remote:RebuildLogIndex()
    end
    remote._adminUsers = { OWNER, OTHER }
    local coord = cloneWithout(remote, coordName, "owner-Garona:1")
    assertTrue(coord:MergeLogTables({
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 12,
        }, { author = "owner-Garona", counter = 2, timestamp = 1700030102 }),
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 13,
        }, { author = "owner-Garona", counter = 3, timestamp = 1700030103 }),
    }) > 0, "local missing-earlier store has owner-Garona:2 and :3")
    if coord.RebuildLogIndex then
        coord:RebuildLogIndex()
    end
    coord._adminUsers = { OWNER, OTHER }
    return coord, remote
end
local function seedTrueBehind(coordName, remoteName)
    local remote = makeProfile(remoteName)
    addMember(remote, ALT_A)
    addMember(remote, OTHER)
    addOwnerSiblings(remote)
    assertTrue(remote:MergeLogTables({
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 11,
        }, { author = "owner-Garona", counter = 1, timestamp = 1700030201 }),
    }) > 0, "true-behind remote has owner-Garona:1")
    if remote.RebuildLogIndex then
        remote:RebuildLogIndex()
    end
    remote._adminUsers = { OWNER, OTHER }
    local coord = cloneWithout(remote, coordName, "__none__")
    assertTrue(coord:MergeLogTables({
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 13,
        }, { author = "owner-Garona", counter = 3, timestamp = 1700030203 }),
    }) > 0, "true-behind local keeps :1 and adds :3")
    if coord.RebuildLogIndex then
        coord:RebuildLogIndex()
    end
    coord._adminUsers = { OWNER, OTHER }
    return coord, remote
end
local function seedSuperset(coordName, remoteName, conflictFirst)
    local remote = makeProfile(remoteName)
    addMember(remote, ALT_A)
    addMember(remote, OTHER)
    addOwnerSiblings(remote)
    assertTrue(remote:MergeLogTables({
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 11,
        }, { author = "owner-Garona", counter = 1, timestamp = 1700030301 }),
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 13,
        }, { author = "owner-Garona", counter = 3, timestamp = 1700030303 }),
    }) > 0, "superset remote has owner-Garona:1 and :3")
    if remote.RebuildLogIndex then
        remote:RebuildLogIndex()
    end
    remote._adminUsers = { OWNER, OTHER }
    local coord = cloneWithout(remote, coordName, "__none__")
    assertTrue(coord:MergeLogTables({
        makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 12,
        }, { author = "owner-Garona", counter = 2, timestamp = 1700030302 }),
    }) > 0, "superset local inserts interleaved owner-Garona:2")
    if conflictFirst then
        local wrong = coord:GetLogById("owner-Garona:1"):ToTable()
        wrong._data = { member = ALT_A, change = SF.LootLogPointChangeTypes.INCREMENT, amount = 99 }
        wrong._fingerprint = SF.LootLog.ComputeFingerprintFromTable(wrong)
        assertTrue(coord:MergeLogTables({ wrong }, { allowReplaceExisting = true }) >= 0,
            "superset conflict replaces owner-Garona:1 fingerprint")
    end
    if coord.RebuildLogIndex then
        coord:RebuildLogIndex()
    end
    coord._adminUsers = { OWNER, OTHER }
    return coord, remote
end
local function assertRepairObtains(remote, coord, evid, requestId, expectId)
    applyDiscoveredRange(remote, coord, {
        author = "owner-Garona",
        fromCounter = evid.fromCounter,
        toCounter = evid.maxCounter > 0 and evid.maxCounter or evid.toCounter,
        exactAuthor = true,
        integrityRepair = true,
        expectedCount = evid.count,
        expectedChecksum = evid.checksum,
        expectedMaxCounter = evid.maxCounter,
        expectedFromCounter = evid.fromCounter,
        expectedToCounter = evid.toCounter,
        expectedWindows = { evid },
    }, requestId)
    assertTrue(hasLogId(coord, expectId), "repair obtained " .. tostring(expectId))
end

-- 1 / 6 / 7 / 8 / 9 / 10. Later window must not hide earlier fingerprint conflict.
resetEnv()
local coord, remote = seedLaterWindowConflict("ContainLaterCoord", "ContainLaterRemote")
assertEq(coord:ComputeAuthorMax()["owner-Garona"], 30, "later-window fixture has global raw max 30")
assertTrue(coord:ComputeAuthorMax()["owner-Garona"] > (remote:ComputeAuthorMax()["owner-Garona"] or 0),
    "later local max is newer than remote first-window max")
local _, hbIntegrity = discoverFrom(coord, remote)
assertTrue(rangeForAuthor(hbIntegrity, "owner-Garona") ~= nil,
    "heartbeat/member discovery still sees the first-window conflict")
assertEq(rangeForAuthor(hbIntegrity, "owner-Garona").toCounter, 1,
    "first-window conflict requests the remote filled frontier, not :30")
startConv(coord)
local remoteSummary = setRemoteAdmin(coord, remote)
local evid = remoteSummary["owner-Garona"][1]
assertEq(evid.maxCounter, 1, "remote first window filled frontier is 1")
assertTrue(Sync:_IsUnresolvedAdvertisedWindow(coord:GetProfileId(), {
    author = "owner-Garona",
    expectedMaxCounter = evid.maxCounter,
    toCounter = evid.toCounter,
    expectedWindows = { evid },
}), "global :30 does not contain the conflicting 1..25 window")
assertTrue(Sync:_HasUnresolvedRemoteWindowMismatch(coord:GetProfileId()),
    "later-window conflict remains an unresolved remote mismatch")
local grantsBefore = adminAddedCount(coord)
Sync:FinalizeAdminConvergence()
local _, req = findReqForAuthor("owner-Garona", true)
assertTrue(req ~= nil, "admin convergence still queues first-window integrity")
assertEq(req.meta.expectedChecksum, evid.checksum, "integrity proof stays advertiser-owned")
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "later local max does not make identity-admin reconcile ready")
assertFalse(coord:IsAdminMemberId(ALT_B), "unresolved earlier window does not persist implied ADMIN_ADDED")
assertEq(adminAddedCount(coord), grantsBefore, "no ADMIN_ADDED while earlier window is uncontained")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state._adminConvergence = nil
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "clearing the request does not treat the earlier window as contained")
Sync.state._adminConvergence = { finished = false, finalizeStarted = true }
assertTrue(Sync:_QueueRemoteWindowMismatches(coord:GetProfileId(), OTHER, remoteSummary),
    "late ADMIN_STATUS still queues the earlier-window conflict")
assertTrue(queuedRepairFor("owner-Garona") ~= nil, "late ADMIN_STATUS repair keeps first-window proof")
assertRepairObtains(remote, coord, evid, "REQ-CONTAIN-LATER", "owner-Garona:1")
assertEq(coord:GetLogById("owner-Garona:1"):GetFingerprint(), remote:GetLogById("owner-Garona:1"):GetFingerprint(),
    "trusted integrity replaces the conflicting first-window row")
assertTrue(hasLogId(coord, "owner-Garona:30"), "later local row is retained")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state._adminConvergence = nil
assertTrue(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "reconcile may run after the earlier advertised window is contained")
Sync:ScheduleIdentityAdminReconcile(coord:GetProfileId())
assertFalse(coord:IsAdminMemberId(ALT_A), "ADMIN_REMOVED remains in force after containment")
assertFalse(coord:IsAdminMemberId(ALT_B), "contained ADMIN_REMOVED history does not grant B")

-- 2 / 6 / 7 / 10 / 11. Higher local max with a genuinely missing earlier row.
resetEnv()
coord, remote = seedMissingEarlier("ContainMissingCoord", "ContainMissingRemote")
assertEq(coord:ComputeAuthorMax()["owner-Garona"], 3, "missing-earlier local exact max is 3")
assertEq(remote:ComputeAuthorMax()["owner-Garona"], 1, "missing-earlier remote exact max is 1")
assertFalse(hasLogId(coord, "owner-Garona:1"), "local does not already have remote :1")
local missingHb, missingIntegrity = discoverFrom(coord, remote)
assertTrue(rangeForAuthor(missingHb, "owner-Garona") == nil,
    "exact catch-up stays idle when local raw max is already newer")
assertTrue(rangeForAuthor(missingIntegrity, "owner-Garona") ~= nil,
    "heartbeat/member path discovers missing remote :1 despite a newer local max")
startConv(coord)
remoteSummary = setRemoteAdmin(coord, remote)
evid = remoteSummary["owner-Garona"][1]
assertTrue(Sync:_IsUnresolvedAdvertisedWindow(coord:GetProfileId(), {
    author = "owner-Garona",
    expectedWindows = { evid },
    expectedMaxCounter = evid.maxCounter,
}), "missing :1 is not resolved by local :2/:3")
Sync:FinalizeAdminConvergence()
_, req = findReqForAuthor("owner-Garona", true)
assertTrue(req ~= nil, "admin convergence requests the missing earlier row")
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "missing earlier row blocks identity-admin reconcile")
Sync.state._adminConvergence = { finished = false, finalizeStarted = true }
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
assertTrue(Sync:_QueueRemoteWindowMismatches(coord:GetProfileId(), OTHER, remoteSummary),
    "late ADMIN_STATUS still discovers the missing earlier row")
assertRepairObtains(remote, coord, evid, "REQ-CONTAIN-MISSING", "owner-Garona:1")
assertTrue(hasLogId(coord, "owner-Garona:2"), "local :2 is retained after missing-row repair")
assertTrue(hasLogId(coord, "owner-Garona:3"), "local :3 is retained after missing-row repair")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state._adminConvergence = nil
assertTrue(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "reconcile may run after the missing advertised row is present")

-- 3 / 6 / 7. True behind advertiser whose advertised rows are already local.
resetEnv()
coord, remote = seedTrueBehind("ContainBehindCoord", "ContainBehindRemote")
assertTrue(hasLogId(coord, "owner-Garona:1"), "true-behind local already has remote :1")
assertTrue(hasLogId(coord, "owner-Garona:3"), "true-behind local also has extra :3")
assertEq(coord:GetLogById("owner-Garona:1"):GetFingerprint(), remote:GetLogById("owner-Garona:1"):GetFingerprint(),
    "true-behind :1 fingerprints match")
local _, behindIntegrity = discoverFrom(coord, remote)
assertTrue(rangeForAuthor(behindIntegrity, "owner-Garona") == nil,
    "heartbeat/member path does not repair a true-behind advertiser")
startConv(coord)
remoteSummary = setRemoteAdmin(coord, remote)
evid = remoteSummary["owner-Garona"][1]
assertFalse(Sync:_IsUnresolvedAdvertisedWindow(coord:GetProfileId(), {
    author = "owner-Garona",
    expectedWindows = { evid },
    expectedMaxCounter = evid.maxCounter,
}), "advertised :1 is contained despite local :3")
assertFalse(Sync:_HasUnresolvedRemoteWindowMismatch(coord:GetProfileId()),
    "true-behind remote window is not an unresolved dependency")
Sync:FinalizeAdminConvergence()
_, req = findReqForAuthor("owner-Garona", true)
assertTrue(req == nil, "admin convergence does not aim integrity at a contained behind window")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state._adminConvergence = nil
assertTrue(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "true-behind advertiser does not stall identity-admin reconcile")
Sync.state._adminConvergence = { finished = false, finalizeStarted = true }
assertFalse(Sync:_QueueRemoteWindowMismatches(coord:GetProfileId(), OTHER, remoteSummary),
    "late ADMIN_STATUS does not requeue a contained behind window")
assertTrue(hasLogId(coord, "owner-Garona:3"), "true-behind path does not delete local :3")

-- 4 / 6 / 7 / 10. Local superset with an interleaved extra sparse row.
resetEnv()
coord, remote = seedSuperset("ContainSuperCoord", "ContainSuperRemote", false)
assertTrue(hasLogId(coord, "owner-Garona:2"), "superset local has interleaved :2")
assertEq(coord:GetLogById("owner-Garona:1"):GetFingerprint(), remote:GetLogById("owner-Garona:1"):GetFingerprint(),
    "superset remote :1 is already present locally")
assertEq(coord:GetLogById("owner-Garona:3"):GetFingerprint(), remote:GetLogById("owner-Garona:3"):GetFingerprint(),
    "superset remote :3 is already present locally")
local _, superIntegrity = discoverFrom(coord, remote)
assertTrue(rangeForAuthor(superIntegrity, "owner-Garona") ~= nil,
    "compact window summary cannot prove interleaved containment without AUTH_LOGS")
startConv(coord)
remoteSummary = setRemoteAdmin(coord, remote)
evid = remoteSummary["owner-Garona"][1]
assertTrue(Sync:_IsUnresolvedAdvertisedWindow(coord:GetProfileId(), {
    author = "owner-Garona",
    expectedWindows = { evid },
}), "interleaved extra :2 is not compact containment of remote {1,3}")
Sync:FinalizeAdminConvergence()
_, req = findReqForAuthor("owner-Garona", true)
assertTrue(req ~= nil, "admin convergence fetches advertiser rows to prove the superset")
assertRepairObtains(remote, coord, evid, "REQ-CONTAIN-SUPER", "owner-Garona:1")
assertTrue(hasLogId(coord, "owner-Garona:2"), "proof-bearing AUTH_LOGS does not delete interleaved :2")
assertTrue(hasLogId(coord, "owner-Garona:3"), "superset :3 remains")
assertFalse(Sync:_IsUnresolvedAdvertisedWindow(coord:GetProfileId(), {
    author = "owner-Garona",
    expectedWindows = { evid },
}), "AUTH_LOGS row proof marks the advertised {1,3} window contained")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state._adminConvergence = nil
assertTrue(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "contained superset does not permanently block identity-admin reconcile")
assertFalse(Sync:_QueueRemoteWindowMismatches(coord:GetProfileId(), OTHER, remoteSummary),
    "late ADMIN_STATUS is idle after AUTH_LOGS proved the superset")

-- 5 / 6 / 9 / 10. Local superset plus one conflicting advertised fingerprint.
resetEnv()
coord, remote = seedSuperset("ContainSuperFpCoord", "ContainSuperFpRemote", true)
assertTrue(coord:GetLogById("owner-Garona:1"):GetFingerprint() ~= remote:GetLogById("owner-Garona:1"):GetFingerprint(),
    "conflicting superset has the wrong owner-Garona:1 fingerprint")
startConv(coord)
remoteSummary = setRemoteAdmin(coord, remote)
evid = remoteSummary["owner-Garona"][1]
grantsBefore = adminAddedCount(coord)
assertTrue(Sync:_HasUnresolvedRemoteWindowMismatch(coord:GetProfileId()),
    "conflicting advertised :1 stays unresolved despite local :2/:3")
assertFalse(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "fingerprint conflict blocks identity-admin reconcile")
Sync:FinalizeAdminConvergence()
_, req = findReqForAuthor("owner-Garona", true)
assertTrue(req ~= nil, "admin convergence requests the conflicting advertised row")
assertEq(adminAddedCount(coord), grantsBefore, "no ADMIN_ADDED while advertised :1 still conflicts")
assertRepairObtains(remote, coord, evid, "REQ-CONTAIN-SUPER-FP", "owner-Garona:1")
assertEq(coord:GetLogById("owner-Garona:1"):GetFingerprint(), remote:GetLogById("owner-Garona:1"):GetFingerprint(),
    "trusted integrity replaces the conflicting superset :1")
assertTrue(hasLogId(coord, "owner-Garona:2"), "conflicting-superset repair retains interleaved :2")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state._adminConvergence = nil
assertTrue(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "reconcile may run after the conflicting advertised row is repaired")

local function runStaleContainmentProofTests()
local function seedConflictAdmins(coordName, aName, bName)
    local adminA = makeProfile(aName)
    addMember(adminA, ALT_A)
    addMember(adminA, ALT_B)
    addMember(adminA, OTHER)
    addMember(adminA, ALT_C)
    addOwnerSiblings(adminA)
    assertTrue(adminA:MergeLogTables({
        makeTable(SF.LootLogEventTypes.ADMIN_ADDED, {
            member = ALT_A,
        }, { author = OWNER, counter = 4, timestamp = 1700031004 }),
        makeTable(SF.LootLogEventTypes.ADMIN_REMOVED, {
            member = ALT_A,
            preOpAuthorMax = {
                { author = OWNER, counter = 4 },
            },
        }, { author = "owner-Garona", counter = 1, timestamp = 1700031010 }),
        makeTable(SF.LootLogEventTypes.CHARACTER_LINK, {
            memberA = ALT_A,
            memberB = ALT_B,
            adminMembersAtLink = { ALT_A },
        }, { author = OWNER, counter = 5, timestamp = 1700031020 }),
    }) > 0, "conflict admin A stores ADMIN_REMOVED as owner-Garona:1")
    if adminA.RebuildLogIndex then
        adminA:RebuildLogIndex()
    end
    adminA._adminUsers = { OWNER, OTHER, ALT_C }
    local adminB = cloneWithout(adminA, bName, "__none__")
    local conflictRow = makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 77,
    }, { author = "owner-Garona", counter = 1, timestamp = 1700031010 })
    assertTrue(adminB:MergeLogTables({ conflictRow }, { allowReplaceExisting = true }) >= 0,
        "conflict admin B replaces owner-Garona:1 with a different fingerprint")
    if adminB.RebuildLogIndex then
        adminB:RebuildLogIndex()
    end
    adminB._adminUsers = { OWNER, OTHER, ALT_C }
    local coord = cloneWithout(adminA, coordName, "owner-Garona:1")
    coord._adminUsers = { OWNER, OTHER, ALT_C }
    return coord, adminA, adminB
end
local function bindConflictAdmins(coord, adminA, adminB)
    startConv(coord)
    coord._adminUsers = { OWNER, OTHER, ALT_C }
    local summaryA = adminA:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
    local summaryB = adminB:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
    Sync.state.authorWindowSummary = coord:ComputeAuthorWindowSummary(Sync:GetIntegrityWindowSize())
    Sync.state.authorMax = coord:ComputeAuthorMax()
    Sync.state.adminStatuses = {
        [OTHER] = {
            hasProfile = true,
            hasGaps = false,
            authorMax = adminA:ComputeAuthorMax(),
            authorWindowSummary = summaryA,
        },
        [ALT_C] = {
            hasProfile = true,
            hasGaps = false,
            authorMax = adminB:ComputeAuthorMax(),
            authorWindowSummary = summaryB,
        },
    }
    return summaryA["owner-Garona"][1], summaryB["owner-Garona"][1]
end
local function applyAdvertiser(src, coord, evid, requestId)
    applyDiscoveredRange(src, coord, {
        author = "owner-Garona",
        fromCounter = evid.fromCounter,
        toCounter = evid.maxCounter > 0 and evid.maxCounter or evid.toCounter,
        exactAuthor = true,
        integrityRepair = true,
        expectedCount = evid.count,
        expectedChecksum = evid.checksum,
        expectedMaxCounter = evid.maxCounter,
        expectedFromCounter = evid.fromCounter,
        expectedToCounter = evid.toCounter,
        expectedWindows = { evid },
    }, requestId)
    registerProfile(coord)
end
local function assertConflictOpen(coord, evidA, evidB, message)
    local pid = coord:GetProfileId()
    local aContained = Sync:_IsAdvertisedExactWindowContained(pid, "owner-Garona", evidA)
    local bContained = Sync:_IsAdvertisedExactWindowContained(pid, "owner-Garona", evidB)
    assertFalse(aContained and bContained, message .. ": both contradictory proofs cannot be contained")
    assertTrue(Sync:_HasUnresolvedRemoteWindowMismatch(pid),
        message .. ": unresolved remote window mismatch remains")
    Sync.state.requests = {}
    Sync.state.repairQueue = { order = {}, items = {} }
    Sync.state._adminConvergence = nil
    assertFalse(Sync:IsIdentityAdminReconcileReady(pid),
        message .. ": identity-admin reconcile stays blocked")
    assertFalse(coord:IsAdminMemberId(ALT_B), message .. ": no implied ADMIN_ADDED for B")
    return aContained, bContained
end

-- 1 / 3 / 4 / 5 / 6. Conflicting advertiser A then B.
resetEnv()
local coord, adminA, adminB = seedConflictAdmins("StaleABCoord", "StaleAdminA", "StaleAdminB")
assertTrue(adminA:GetLogById("owner-Garona:1"):GetFingerprint() ~= adminB:GetLogById("owner-Garona:1"):GetFingerprint(),
    "admin A and admin B disagree on owner-Garona:1")
local evidA, evidB = bindConflictAdmins(coord, adminA, adminB)
assertTrue(evidA.checksum ~= evidB.checksum, "conflicting advertisers have distinct window checksums")
local grantsBefore = adminAddedCount(coord)
applyAdvertiser(adminA, coord, evidA, "REQ-STALE-A1")
assertEq(coord:GetLogById("owner-Garona:1"):GetFingerprint(), adminA:GetLogById("owner-Garona:1"):GetFingerprint(),
    "after A, local fingerprint is A's ADMIN_REMOVED")
local aContained, bContained = assertConflictOpen(coord, evidA, evidB, "after A")
assertTrue(aContained, "after A, A's advertised proof is contained")
assertFalse(bContained, "after A, B's advertised proof remains unresolved")
assertEq(adminAddedCount(coord), grantsBefore, "no ADMIN_ADDED after A's repair while B still conflicts")
applyAdvertiser(adminB, coord, evidB, "REQ-STALE-B1")
assertEq(coord:GetLogById("owner-Garona:1"):GetFingerprint(), adminB:GetLogById("owner-Garona:1"):GetFingerprint(),
    "trusted integrity replaces fingerprint A with B")
aContained, bContained = assertConflictOpen(coord, evidA, evidB, "after A then B")
assertFalse(aContained, "after B replaces A, A's advertised proof is unresolved again")
assertTrue(bContained, "after B replaces A, B's advertised proof is contained")
assertFalse(Sync:_HasContainedExactWindowProof(coord:GetProfileId(), "owner-Garona", evidA),
    "stale AUTH_LOGS cache for A does not survive fingerprint replacement")

-- 2 / 7. Reverse arrival and alternating replacements.
resetEnv()
coord, adminA, adminB = seedConflictAdmins("StaleBACoord", "StaleAdminA2", "StaleAdminB2")
evidA, evidB = bindConflictAdmins(coord, adminA, adminB)
applyAdvertiser(adminB, coord, evidB, "REQ-STALE-B2")
aContained, bContained = assertConflictOpen(coord, evidA, evidB, "after B first")
assertFalse(aContained, "after B first, A's proof is unresolved")
assertTrue(bContained, "after B first, B's proof is contained")
applyAdvertiser(adminA, coord, evidA, "REQ-STALE-A2")
aContained, bContained = assertConflictOpen(coord, evidA, evidB, "after B then A")
assertTrue(aContained, "after A replaces B, A's proof is contained")
assertFalse(bContained, "after A replaces B, B's proof is unresolved")
applyAdvertiser(adminB, coord, evidB, "REQ-STALE-B3")
applyAdvertiser(adminA, coord, evidA, "REQ-STALE-A3")
aContained, bContained = assertConflictOpen(coord, evidA, evidB, "after alternating replacements")
assertTrue(aContained, "last writer A is contained")
assertFalse(bContained, "last writer A leaves B unresolved")
assertFalse(aContained and bContained, "alternating replacements never satisfy both contradictory proofs")

-- 8. Identical proof from two admins is satisfied normally.
resetEnv()
coord, adminA, adminB = seedConflictAdmins("StaleSameCoord", "StaleSameA", "StaleSameB")
adminB = cloneWithout(adminA, "StaleSameB2", "__none__")
adminB._adminUsers = { OWNER, OTHER, ALT_C }
evidA, evidB = bindConflictAdmins(coord, adminA, adminB)
assertEq(evidA.checksum, evidB.checksum, "identical advertisers share one window checksum")
applyAdvertiser(adminA, coord, evidA, "REQ-STALE-SAME")
assertTrue(Sync:_IsAdvertisedExactWindowContained(coord:GetProfileId(), "owner-Garona", evidA),
    "identical A proof is contained")
assertTrue(Sync:_IsAdvertisedExactWindowContained(coord:GetProfileId(), "owner-Garona", evidB),
    "identical B proof is contained by the same local history")
Sync.state.requests = {}
Sync.state.repairQueue = { order = {}, items = {} }
Sync.state._adminConvergence = nil
assertFalse(Sync:_HasUnresolvedRemoteWindowMismatch(coord:GetProfileId()),
    "identical advertiser windows are not an unresolved mismatch")
assertTrue(Sync:IsIdentityAdminReconcileReady(coord:GetProfileId()),
    "identical advertiser proofs allow identity-admin reconcile")
Sync:ScheduleIdentityAdminReconcile(coord:GetProfileId())
assertFalse(coord:IsAdminMemberId(ALT_A), "ADMIN_REMOVED remains in force for identical proofs")
assertFalse(coord:IsAdminMemberId(ALT_B), "identical contained ADMIN_REMOVED does not grant B")

-- 9 / 10. Ordinary append does not invalidate valid cached containment,
-- including interleaved-superset AUTH_LOGS proof.
resetEnv()
coord, remote = seedSuperset("StaleAppendCoord", "StaleAppendRemote", false)
startConv(coord)
remoteSummary = setRemoteAdmin(coord, remote)
evid = remoteSummary["owner-Garona"][1]
applyAdvertiser(remote, coord, evid, "REQ-STALE-APPEND")
assertFalse(Sync:_IsUnresolvedAdvertisedWindow(coord:GetProfileId(), {
    author = "owner-Garona",
    expectedWindows = { evid },
}), "interleaved superset AUTH_LOGS proof is contained before append")
assertTrue(Sync:_HasContainedExactWindowProof(coord:GetProfileId(), "owner-Garona", evid),
    "interleaved superset uses cached row-level AUTH_LOGS proof")
assertTrue(coord:MergeLogTables({
    makeTable(SF.LootLogEventTypes.POINT_CHANGE, {
        member = ALT_A,
        change = SF.LootLogPointChangeTypes.INCREMENT,
        amount = 14,
    }, { author = "owner-Garona", counter = 4, timestamp = 1700031090 }),
}) > 0, "ordinary append adds owner-Garona:4")
assertTrue(hasLogId(coord, "owner-Garona:2"), "append keeps interleaved :2")
assertTrue(Sync:_HasContainedExactWindowProof(coord:GetProfileId(), "owner-Garona", evid),
    "ordinary append does not drop cached containment")
assertFalse(Sync:_IsUnresolvedAdvertisedWindow(coord:GetProfileId(), {
    author = "owner-Garona",
    expectedWindows = { evid },
}), "advertised {1,3} stays contained after an unrelated later row")

-- 11. Session reset / takeover clears transient containment evidence.
Sync:_ClearIdentitySessionBookkeeping("test-session-reset")
assertFalse(Sync:_HasContainedExactWindowProof(coord:GetProfileId(), "owner-Garona", evid),
    "session reset clears cached AUTH_LOGS containment")
assertTrue(Sync:_IsUnresolvedAdvertisedWindow(coord:GetProfileId(), {
    author = "owner-Garona",
    expectedWindows = { evid },
}), "interleaved superset becomes unproven after session reset until AUTH_LOGS re-proves it")
applyAdvertiser(remote, coord, evid, "REQ-STALE-TAKEOVER")
assertTrue(Sync:_HasContainedExactWindowProof(coord:GetProfileId(), "owner-Garona", evid),
    "AUTH_LOGS can re-prove interleaved containment after reset")
Sync.state.containedExactWindows = {}
assertFalse(Sync:_HasContainedExactWindowProof(coord:GetProfileId(), "owner-Garona", evid),
    "coordinator takeover clears transient containment evidence")

-- 12. Snapshot/import replacement path (MergeLogTables allowReplaceExisting)
-- invalidates the replaced advertiser's proof.
resetEnv()
coord, adminA, adminB = seedConflictAdmins("StaleSnapCoord", "StaleSnapA", "StaleSnapB")
evidA, evidB = bindConflictAdmins(coord, adminA, adminB)
applyAdvertiser(adminA, coord, evidA, "REQ-STALE-SNAP-A")
assertTrue(Sync:_IsAdvertisedExactWindowContained(coord:GetProfileId(), "owner-Garona", evidA),
    "snapshot fixture starts with A's proof contained")
local replaced = adminB:GetLogById("owner-Garona:1"):ToTable()
assertTrue(coord:MergeLogTables({ replaced }, { allowReplaceExisting = true }) >= 0,
    "ImportSnapshot/MergeLogTables replacement path rewrites owner-Garona:1")
aContained, bContained = assertConflictOpen(coord, evidA, evidB, "after snapshot replacement")
assertFalse(aContained, "snapshot replacement uncontains A's previous proof")
assertFalse(Sync:_HasContainedExactWindowProof(coord:GetProfileId(), "owner-Garona", evidA),
    "row-level cache rejects the replaced fingerprint")
end
runStaleContainmentProofTests()

restoreUniqueNonces()
end
runAdvertisedContainmentTests()
end
runExactAuthorProofTests()

-- Performance: large history with a few alias collisions
resetEnv()
local perfLogs = {}
local perfCounters = {}
local perfAuthors = { OWNER, ALT_A, OTHER, ALT_C }
for i = 1, 1800 do
    local author = perfAuthors[(i % #perfAuthors) + 1]
    perfCounters[author] = (perfCounters[author] or 0) + 1
    perfLogs[#perfLogs + 1] = {
        _timestamp = 1700070000 + math.floor(i / 6),
        _author = author,
        _counter = perfCounters[author],
        _eventType = SF.LootLogEventTypes.POINT_CHANGE,
        _data = {
            member = ALT_D,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 1,
        },
        _id = string.format("%s:%d", author, perfCounters[author]),
    }
end
for i = 1, 4 do
    perfLogs[#perfLogs + 1] = {
        _timestamp = 1700070000,
        _author = "owner-Garona",
        _counter = i,
        _eventType = SF.LootLogEventTypes.ATTENDANCE_CHANGE,
        _data = {
            member = ALT_A,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 1,
        },
        _id = string.format("owner-Garona:%d", i),
    }
end
perfLogs[#perfLogs + 1] = {
    _timestamp = 1700071000,
    _author = OWNER,
    _counter = (perfCounters[OWNER] or 0) + 1,
    _eventType = SF.LootLogEventTypes.ADMIN_ADDED,
    _data = { member = ALT_B, sourceLogId = nil },
    _id = string.format("%s:%d", OWNER, (perfCounters[OWNER] or 0) + 1),
}
perfCounters[OWNER] = (perfCounters[OWNER] or 0) + 1
perfLogs[#perfLogs + 1] = {
    _timestamp = 1700071001,
    _author = OWNER,
    _counter = perfCounters[OWNER] + 1,
    _eventType = SF.LootLogEventTypes.CHARACTER_LINK,
    _data = {
        memberA = ALT_A,
        memberB = ALT_B,
        adminMembersAtLink = { OWNER },
        preOpAuthorMax = {
            { author = OWNER, counter = perfCounters[OWNER] },
            { author = "owner-Garona", counter = 4 },
        },
        sourceLogId = nil,
    },
    _id = string.format("%s:%d", OWNER, perfCounters[OWNER] + 1),
}
local t0 = os.clock()
local perfOrdered = SF.LootHelperIdentity.OrderLogs(perfLogs)
local elapsed = os.clock() - t0
local perfStats = SF.LootHelperIdentity.lastOrderStats
assertEq(#perfOrdered, #perfLogs, "performance order retains every log")
assertEq(perfStats.leftover or 0, 0, "performance order has no causal cycle")
assertTrue(perfStats.heapOps < perfStats.n * perfStats.n / 8, "alias-collision heap work stays far below n^2")
assertTrue((perfStats.edgeCalls or 0) < perfStats.n * 8, "alias-collision edges stay linear in n")
assertTrue(elapsed < 2.0, "1800-log alias-collision OrderLogs stays comfortably sub-quadratic")
end
runHistoricalAliasConvergenceTests()

local function runProtocolAndSourceIdTests()
-- ---------------------------------------------------------------------------
-- Protocol
-- ---------------------------------------------------------------------------
assertEq(SF.SyncProtocol.PROTO_CURRENT, 3, "protocol current is 3")
assertEq(SF.LootHelperSync.PROTO_VERSION, 3, "sync PROTO_VERSION is 3")
local protoOk, _, protoCode = SF.SyncProtocol.ValidateProtocolVersion(2)
assertFalse(protoOk, "protocol 2 cannot participate")
assertEq(protoCode, "TOO_OLD", "old clients are TOO_OLD")
assertTrue(SF.SyncProtocol.ValidateProtocolVersion(3), "protocol 3 is accepted")

resetEnv()
local histA = makeProfile("HistA")
addMember(histA, ALT_A)
addMember(histA, ALT_B)
addLog(histA, SF.LootLogEventTypes.POINT_CHANGE, {
    member = ALT_A,
    change = SF.LootLogPointChangeTypes.INCREMENT,
    amount = 2,
}, { timestamp = 1700000300 })
assertTrue(histA:LinkCharacters(ALT_A, ALT_B), "history A link")
local tables = {}
for _, log in ipairs(histA:GetLootLogs()) do
    tables[#tables + 1] = log:ToTable()
end
local histB = makeProfile("HistB")
assertTrue(histB:MergeLogTables(tables) >= 0, "identical history import")
histA:ApplyIdentityProjection()
histB:ApplyIdentityProjection()
local replayA = SF.LootHelperIdentity.Replay(histA:GetLootLogs(), { owner = histA._owner })
local replayB = SF.LootHelperIdentity.Replay(histB:GetLootLogs(), { owner = histB._owner })
assertEq(replayA.points[ALT_A], replayB.points[ALT_A], "identical complete history yields identical points")
assertEq(replayA.attendance[ALT_A], replayB.attendance[ALT_A], "identical complete history yields identical attendance")
assertTrue(SF.LootHelperIdentity.SameIdentity(histB:GetLootLogs(), ALT_A, ALT_B), "identical complete history yields identical identity")

-- sourceLogIds and targetAssignmentId are causal predecessors
resetEnv()
local predA = makeTable("POINT_CHANGE", {
    member = ALT_A,
    change = "INCREMENT",
    amount = 1,
}, { author = OWNER, counter = 2, timestamp = 1700005000 })
local predB = makeTable("POINT_CHANGE", {
    member = ALT_B,
    change = "INCREMENT",
    amount = 1,
}, { author = ALT_A, counter = 2, timestamp = 1700005000 })
local multiChild = makeTable("ADMIN_ADDED", {
    member = ALT_C,
    sourceLogId = predA._id,
    sourceLogIds = { predA._id, predB._id },
    targetAssignmentId = predB._id,
}, { author = "Zulu-Garona", counter = 2, timestamp = 1700005000 })
local orderedSources = SF.LootHelperIdentity.OrderLogs({ multiChild, predB, predA })
assertEq(#orderedSources, 3, "sourceLogIds OrderLogs retains all rows")
local readyBeforeChild = {}
for i = 1, #orderedSources do
    if orderedSources[i]._id ~= multiChild._id then
        readyBeforeChild[orderedSources[i]._id] = true
    end
end
assertTrue(readyBeforeChild[predA._id] == true, "sourceLogId predecessor is before dependent")
assertTrue(readyBeforeChild[predB._id] == true, "sourceLogIds second predecessor is before dependent")
assertEq(orderedSources[3]._id, multiChild._id, "dependent waits for sourceLogIds and targetAssignmentId")

local missingParent = makeTable("ADMIN_ADDED", {
    member = ALT_C,
    sourceLogId = "missing-award-key",
    sourceLogIds = { "also-missing" },
    targetAssignmentId = "also-missing",
}, { author = OWNER, counter = 9, timestamp = 1700005001 })
local orderedMissing = SF.LootHelperIdentity.OrderLogs({ missingParent })
assertEq(#orderedMissing, 1, "missing source ids add no edges and still order")
assertEq(orderedMissing[1]._id, missingParent._id, "orphan dependent remains in OrderLogs")
end
runProtocolAndSourceIdTests()

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
