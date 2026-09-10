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
loadModule("SpectrumFederation/modules/LootHelper/Profiles.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootHelper.lua")
loadModule("SpectrumFederation/modules/LootHelper/SyncProtocol.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/01_Constants.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/02_State.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/16_ProfileIntegration.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/07_Validation.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/08_Requests.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/12_LiveUpdates.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/09_AdminConvergence.lua")

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

local function resetEnv()
    printed = {}
    deferredAfter = {}
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
assertTrue(armorOf(profile, ALT_A, "Chest"), "re-link reactivates the historical correction")
assertTrue(armorOf(profile, ALT_B, "Chest"), "both original members see the correction again")

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
assertTrue(not stats1.cacheHit, "first order is not a cache hit")
local orderedCached = SF.LootHelperIdentity.OrderLogs(scaleLogs)
assertTrue(SF.LootHelperIdentity.lastOrderStats.cacheHit, "identical log table reuses ordered history")
assertEq(#orderedCached, #ordered1, "cached order has the same length")
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

-- ---------------------------------------------------------------------------
-- Protocol
-- ---------------------------------------------------------------------------
assertEq(SF.SyncProtocol.PROTO_CURRENT, 2, "protocol current is 2")
assertEq(SF.LootHelperSync.PROTO_VERSION, 2, "sync PROTO_VERSION is 2")
local protoOk, _, protoCode = SF.SyncProtocol.ValidateProtocolVersion(1)
assertFalse(protoOk, "protocol 1 cannot participate")
assertEq(protoCode, "TOO_OLD", "old clients are TOO_OLD")
assertTrue(SF.SyncProtocol.ValidateProtocolVersion(2), "protocol 2 is accepted")

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

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
