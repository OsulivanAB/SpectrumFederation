-- Production-Lua tests for Raid Check presence attendance (#274).
-- Run from the repository root: lua5.1 tests/lua/raid_check_presence_tests.lua

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

local SF = {
    LootLogEventTypes = {
        PROFILE_CREATION = "PROFILE_CREATION",
        POINT_CHANGE = "POINT_CHANGE",
        ATTENDANCE_CHANGE = "ATTENDANCE_CHANGE",
        RAID_CHECK_PRESENCE = "RAID_CHECK_PRESENCE",
        ARMOR_CHANGE = "ARMOR_CHANGE",
        CHARACTER_LINK = "CHARACTER_LINK",
        CHARACTER_UNLINK = "CHARACTER_UNLINK",
        MAIN_SWAP = "MAIN_SWAP",
        ADMIN_ADDED = "ADMIN_ADDED",
        ADMIN_REMOVED = "ADMIN_REMOVED",
        ROLE_CHANGE = "ROLE_CHANGE",
        RC_LOOT_COUNCIL = "RC_LOOT_COUNCIL",
        SPEC_CHANGE = "SPEC_CHANGE",
        BIS_OUTCOME = "BIS_OUTCOME",
        BIS_OVERRIDE = "BIS_OVERRIDE",
        MANUAL_AWARD = "MANUAL_AWARD",
        MANUAL_AWARD_REVERSE = "MANUAL_AWARD_REVERSE",
    },
    LootLogPointChangeTypes = {
        INCREMENT = "INCREMENT",
        DECREMENT = "DECREMENT",
    },
}

local chunk = assert(loadfile("SpectrumFederation/modules/LootHelper/Identity.lua"))
chunk("SpectrumFederation", SF)
local Identity = SF.LootHelperIdentity

local function presenceLog(opportunityId, presentMembers, eligibleMembers, rank)
    return {
        _eventType = "RAID_CHECK_PRESENCE",
        _data = {
            opportunityId = opportunityId,
            presentMembers = presentMembers,
            eligibleMembers = eligibleMembers,
        },
        _id = "Raid Check:" .. tostring(rank or 1),
        _timestamp = 1700000000 + (rank or 1),
        _author = "Raid Check",
        _counter = rank or 1,
    }
end

local function pointLog(member, rank)
    return {
        _eventType = "POINT_CHANGE",
        _data = {
            member = member,
            change = "INCREMENT",
            amount = 1,
            reason = "RAID_CHECK",
        },
        _id = "Raid Check:" .. tostring(rank or 1),
        _timestamp = 1700000000 + (rank or 1),
        _author = "Raid Check",
        _counter = rank or 1,
    }
end

local ALICE = "Alice-Garona"
local BOB = "Bob-Garona"
local CAROL = "Carol-Garona"

local empty = Identity.Replay({}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(empty, ALICE), "—", "no history displays an em dash")
assertTrue(Identity.AffectsProjection("RAID_CHECK_PRESENCE"), "presence logs affect projection")

local first = Identity.Replay({
    presenceLog("p1:1", { ALICE, BOB }, { ALICE, BOB, CAROL }, 1),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(first, ALICE), "100%", "present roster member is 100%")
assertEq(Identity.FormatRaidCheckAttendance(first, BOB), "100%", "second present member is 100%")
assertEq(Identity.FormatRaidCheckAttendance(first, CAROL), "0%", "eligible but absent member is 0%")
assertTrue(Identity.HasRaidCheckPresenceOpportunity(first, "p1:1"), "opportunity id is recorded")

local two = Identity.Replay({
    presenceLog("p1:1", { ALICE }, { ALICE, BOB }, 1),
    presenceLog("p1:2", { ALICE, BOB }, { ALICE, BOB }, 2),
}, { owner = ALICE })
local alicePresent, aliceEligible = Identity.RaidCheckAttendanceCounts(two, ALICE)
local bobPresent, bobEligible = Identity.RaidCheckAttendanceCounts(two, BOB)
assertEq(alicePresent, 2, "alice present on both opportunities")
assertEq(aliceEligible, 2, "alice eligible on both opportunities")
assertEq(bobPresent, 1, "bob present only on the second opportunity")
assertEq(bobEligible, 2, "bob eligible on both opportunities")
assertEq(Identity.FormatRaidCheckAttendance(two, BOB), "50%", "bob attendance is 50%")

local lateJoin = Identity.Replay({
    presenceLog("p1:1", { ALICE }, { ALICE }, 1),
    presenceLog("p1:2", { ALICE, BOB }, { ALICE, BOB }, 2),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(lateJoin, BOB), "100%", "later roster member is not charged for earlier raids")
assertEq(Identity.FormatRaidCheckAttendance(lateJoin, ALICE), "100%", "existing member still counts both opportunities")

local guest = Identity.Replay({
    presenceLog("p1:1", { CAROL }, { ALICE }, 1),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(guest, CAROL), "100%", "present non-roster player gets credit without becoming an absence for others")
assertEq(Identity.FormatRaidCheckAttendance(guest, ALICE), "0%", "roster member who missed the check is absent")
assertEq(select(1, Identity.RaidCheckAttendanceCounts(guest, BOB)), 0, "unmentioned player has no present count")
assertEq(select(2, Identity.RaidCheckAttendanceCounts(guest, BOB)), 0, "unmentioned player is not eligible")

local duplicate = Identity.Replay({
    presenceLog("same", { ALICE }, { ALICE, BOB }, 1),
    presenceLog("same", { ALICE, BOB }, { ALICE, BOB }, 2),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(duplicate, BOB), "0%", "duplicate opportunity id does not invent a second event")
assertEq(Identity.FormatRaidCheckAttendance(duplicate, ALICE), "100%", "first write for an opportunity id wins")

local pointsOnly = Identity.Replay({
    pointLog(ALICE, 1),
    pointLog(ALICE, 2),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(pointsOnly, ALICE), "—", "point awards are not used as attendance history")

local validatorsChunk = assert(loadfile("SpectrumFederation/modules/LootHelper/LootLogValidators.lua"))
validatorsChunk("SpectrumFederation", SF)
local Validators = SF.LootLogValidators
local valid = {
    opportunityId = "profile:1",
    presentMembers = { BOB, ALICE, ALICE },
    eligibleMembers = { ALICE, BOB },
}
assertTrue(Validators.ValidateRaidCheckPresenceData(valid), "validator accepts a well-formed presence log")
assertEq(valid.presentMembers[1], ALICE, "validator normalizes and sorts present members")
assertEq(#valid.presentMembers, 2, "validator deduplicates present members")
assertTrue(not Validators.ValidateRaidCheckPresenceData({ opportunityId = "", presentMembers = {}, eligibleMembers = {} }), "empty opportunity id is rejected")
assertTrue(not Validators.ValidateRaidCheckPresenceData({ opportunityId = "x", presentMembers = { 1 }, eligibleMembers = {} }), "non-string member ids are rejected")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
