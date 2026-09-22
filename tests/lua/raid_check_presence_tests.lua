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

local function presenceLog(opportunityId, presentMembers, eligibleMembers, rank, preparedMembers)
    return {
        _eventType = "RAID_CHECK_PRESENCE",
        _data = {
            opportunityId = opportunityId,
            presentMembers = presentMembers,
            eligibleMembers = eligibleMembers,
            preparedMembers = preparedMembers,
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
assertEq(Identity.FormatRaidCheckPreparedness(empty, ALICE), "—", "no preparedness history displays an em dash")
assertTrue(Identity.AffectsProjection("RAID_CHECK_PRESENCE"), "presence logs affect projection")

local first = Identity.Replay({
    presenceLog("p1:1", { ALICE, BOB }, { ALICE, BOB, CAROL }, 1, { ALICE }),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(first, ALICE), "100%", "present roster member is 100%")
assertEq(Identity.FormatRaidCheckAttendance(first, BOB), "100%", "second present member is 100%")
assertEq(Identity.FormatRaidCheckAttendance(first, CAROL), "0%", "eligible but absent member is 0%")
assertEq(Identity.FormatRaidCheckPreparedness(first, ALICE), "100%", "present and prepared member is 100% prepared")
assertEq(Identity.FormatRaidCheckPreparedness(first, BOB), "0%", "present unprepared member is 0% prepared")
assertEq(Identity.FormatRaidCheckPreparedness(first, CAROL), "0%", "absent member is 0% prepared")
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
assertEq(Identity.FormatRaidCheckPreparedness(two, ALICE), "—", "legacy logs without preparedMembers do not invent preparedness")
assertEq(Identity.FormatRaidCheckPreparedness(two, BOB), "—", "legacy logs without preparedMembers stay an em dash for bob")

local mixedPrep = Identity.Replay({
    presenceLog("p1:1", { ALICE }, { ALICE, BOB }, 1),
    presenceLog("p1:2", { ALICE, BOB }, { ALICE, BOB }, 2, { ALICE }),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(mixedPrep, ALICE), "100%", "mixed history still counts both attendance opportunities")
assertEq(Identity.FormatRaidCheckAttendance(mixedPrep, BOB), "50%", "mixed history keeps bob attendance at 50%")
assertEq(Identity.FormatRaidCheckPreparedness(mixedPrep, ALICE), "100%", "only logs with preparedMembers enter the preparedness denominator")
assertEq(Identity.FormatRaidCheckPreparedness(mixedPrep, BOB), "0%", "present unprepared member on a prepared log is 0%")

local emptyPrepared = Identity.Replay({
    presenceLog("p1:1", { ALICE }, { ALICE }, 1, {}),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(emptyPrepared, ALICE), "100%", "empty preparedMembers still counts attendance")
assertEq(Identity.FormatRaidCheckPreparedness(emptyPrepared, ALICE), "0%", "explicit empty preparedMembers is 0% not an em dash")

local preparedAbsent = Identity.Replay({
    presenceLog("p1:1", { ALICE }, { ALICE, BOB }, 1, { BOB }),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckPreparedness(preparedAbsent, ALICE), "0%", "present unlisted member is not prepared")
assertEq(Identity.FormatRaidCheckPreparedness(preparedAbsent, BOB), "0%", "prepared but absent member is not credited")

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

local malformedPresent = Identity.Replay({
    presenceLog("bad-present", "Alice-Garona", { ALICE, BOB }, 1),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(malformedPresent, BOB), "—", "string presentMembers does not invent absences")
assertEq(Identity.FormatRaidCheckAttendance(malformedPresent, ALICE), "—", "string presentMembers is skipped entirely")

local malformedEligible = Identity.Replay({
    presenceLog("bad-eligible", { ALICE }, "Alice-Garona", 1),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(malformedEligible, ALICE), "—", "string eligibleMembers is skipped entirely")

local malformedThenValid = Identity.Replay({
    presenceLog("same", "Alice-Garona", { ALICE, BOB }, 1),
    presenceLog("same", { ALICE }, { ALICE, BOB }, 2),
}, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(malformedThenValid, ALICE), "100%", "malformed first write does not occupy the opportunity id")
assertEq(Identity.FormatRaidCheckAttendance(malformedThenValid, BOB), "0%", "first valid write still counts the opportunity")

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
assertTrue(not Validators.ValidateRaidCheckPresenceData({
    opportunityId = "x",
    presentMembers = "Alice-Garona",
    eligibleMembers = { ALICE },
}), "string presentMembers is rejected")
assertTrue(Validators.ValidateRaidCheckPresenceData({
    opportunityId = "legacy",
    presentMembers = { ALICE },
    eligibleMembers = { ALICE },
}), "validator accepts a legacy log that omits preparedMembers")
assertTrue(Validators.ValidateRaidCheckPresenceData({
    opportunityId = "empty-prep",
    presentMembers = { ALICE },
    eligibleMembers = { ALICE },
    preparedMembers = {},
}), "validator accepts an explicit empty preparedMembers list")
assertTrue(not Validators.ValidateRaidCheckPresenceData({
    opportunityId = "x",
    presentMembers = { ALICE },
    eligibleMembers = { ALICE },
    preparedMembers = "Alice-Garona",
}), "string preparedMembers is rejected")

local importProbe = {
    opportunityId = "profile:2",
    presentMembers = { BOB, ALICE },
    eligibleMembers = { ALICE, BOB },
}
assertTrue(Validators.ValidateRaidCheckPresenceData(importProbe, { mutate = false }), "mutate=false still accepts valid lists")
assertEq(importProbe.presentMembers[1], BOB, "mutate=false leaves the original present order intact")

local logsChunk = assert(loadfile("SpectrumFederation/modules/LootHelper/LootLogs.lua"))
logsChunk("SpectrumFederation", SF)
local function presenceWire(data)
    local t = {
        version = 2,
        _id = "Alice-Garona:40",
        _timestamp = 1700000040,
        _author = "Alice-Garona",
        _counter = 40,
        _eventType = "RAID_CHECK_PRESENCE",
        _data = data,
    }
    t._fingerprint = SF.LootLog.ComputeFingerprintFromTable(t)
    return t
end
local goodWire = presenceWire({
    opportunityId = "profile:1",
    presentMembers = { ALICE },
    eligibleMembers = { ALICE, BOB },
})
assertTrue(select(1, SF.LootLog.ValidateTable(goodWire)), "ValidateTable accepts a well-formed presence log")
local badWire = presenceWire({
    opportunityId = "profile:1",
    presentMembers = "Alice-Garona",
    eligibleMembers = { ALICE, BOB },
})
assertTrue(not select(1, SF.LootLog.ValidateTable(badWire)), "ValidateTable rejects a string presentMembers list")
assertEq(badWire._data.presentMembers, "Alice-Garona", "ValidateTable does not rewrite rejected presence data")
local legacyWire = presenceWire({
    opportunityId = "profile:1",
    presentMembers = { ALICE },
    eligibleMembers = { ALICE, BOB },
})
assertTrue(select(1, SF.LootLog.ValidateTable(legacyWire)), "ValidateTable accepts a legacy presence log without preparedMembers")
local badPrepWire = presenceWire({
    opportunityId = "profile:1",
    presentMembers = { ALICE },
    eligibleMembers = { ALICE, BOB },
    preparedMembers = "Alice-Garona",
})
assertTrue(not select(1, SF.LootLog.ValidateTable(badPrepWire)), "ValidateTable rejects a string preparedMembers list")
assertEq(badPrepWire._data.preparedMembers, "Alice-Garona", "ValidateTable does not rewrite rejected preparedMembers")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
