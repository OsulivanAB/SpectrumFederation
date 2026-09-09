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

function GetServerTime()
    return 1700001000
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

local function resetEnv()
    printed = {}
    PLAYER = "Owner-Garona"
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
    t._fingerprint = SF.LootLog.ComputeFingerprintFromTable(t)
    return t
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
assertEq(#correction.identityMembers, 2, "identityMembers records original membership")
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
assertTrue(profile:MergeLogTables({ swapLog, stale }) > 0, "known stale MAIN_SWAP fingerprint is repaired in batch import")
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
assertTrue(chainProfile:MergeLogTables({ chainedSwap1, chainedSwap2, chained }) > 0, "chained ancestor fingerprint repair")

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
assertTrue(roundTrip:MergeLogTables(snapshot.lootLogs) >= 0, "snapshot logs merge into another profile")
assertTrue(SF.LootHelperIdentity.SameIdentity(roundTrip:GetLootLogs(), ALT_A, ALT_B), "snapshot logs preserve MAIN_SWAP lineage")

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
