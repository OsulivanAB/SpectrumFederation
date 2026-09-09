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
loadModule("SpectrumFederation/modules/LootHelperSync/12_LiveUpdates.lua")

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
function Sync:FindLocalProfileById(profileId)
    return SF.lootHelperDB and SF.lootHelperDB.profiles and SF.lootHelperDB.profiles[profileId]
end
function Sync:RunAfter(_, fn)
    fn()
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

local function resetEnv()
    printed = {}
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
    }
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
assertFalse(profile:AreSameIdentity(OWNER, ALT_A), "normal admin live LINK into owner identity is rejected")

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
end), "linked effective-owner alt can UNLINK owner identity")

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
