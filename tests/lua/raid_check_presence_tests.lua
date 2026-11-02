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

-- #442: 15 present / 22 eligible remains the attendance shape; wording is
-- separate. Preparedness still requires an explicit preparedMembers list.
local raid15profile22Present = {}
local raid15profile22Eligible = {}
local raid15profile22Prepared = {}
for i = 1, 22 do
    raid15profile22Eligible[i] = string.format("Raider%02d-Garona", i)
end
for i = 1, 15 do
    raid15profile22Present[i] = raid15profile22Eligible[i]
end
for i = 1, 12 do
    raid15profile22Prepared[i] = raid15profile22Eligible[i]
end
local raid15 = Identity.Replay({
    presenceLog("p442:1", raid15profile22Present, raid15profile22Eligible, 1, raid15profile22Prepared),
}, { owner = ALICE })
assertEq(select(1, Identity.RaidCheckAttendanceCounts(raid15, "Raider01-Garona")), 1, "15/22: present profile member counts present")
assertEq(select(2, Identity.RaidCheckAttendanceCounts(raid15, "Raider01-Garona")), 1, "15/22: present profile member counts eligible")
assertEq(select(1, Identity.RaidCheckAttendanceCounts(raid15, "Raider16-Garona")), 0, "15/22: absent eligible member is not present")
assertEq(select(2, Identity.RaidCheckAttendanceCounts(raid15, "Raider16-Garona")), 1, "15/22: absent eligible member still counts eligible")
assertEq(Identity.FormatRaidCheckPreparedness(raid15, "Raider01-Garona"), "100%", "15/22: verified prepared member is 100%")
assertEq(Identity.FormatRaidCheckPreparedness(raid15, "Raider13-Garona"), "0%", "15/22: present unprepared member is 0%")
assertEq(Identity.FormatRaidCheckPreparedness(raid15, "Raider16-Garona"), "0%", "15/22: absent eligible member is 0% prepared")

function strtrim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end
function GetRealmName()
    return "Garona"
end
assert(loadfile("SpectrumFederation/modules/NameUtil.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/RaidEquipment/CheckRun.lua"))("SpectrumFederation", SF)
local CheckRun = SF.RaidEquipment.CheckRun
assertEq(
    CheckRun.FormatPresenceLogSummary(15, 22, 12),
    "Raid Check: 15 present · 22 eligible profile members · 12 verified prepared",
    "15/22 presence summary spells out present, eligible, and verified prepared"
)
assertEq(
    CheckRun.FormatPresenceLogSummary(15, 22, nil),
    "Raid Check: 15 present · 22 eligible profile members",
    "legacy presence summary omits prepared when preparedMembers is missing"
)
assertEq(
    CheckRun.FormatPresenceLogSummary(15, 22, 0),
    "Raid Check: 15 present · 22 eligible profile members · 0 verified prepared",
    "explicit empty preparedMembers still shows zero verified prepared"
)

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

-- #442 Codex P1: raw group alias casing vs profile IDs breaks Identity.Replay.
local mismatchedPresent = Identity.Replay({
    presenceLog("mismatch", { "alice-Garona", "Guest-Garona" }, { ALICE, BOB }, 1, { ALICE }),
}, { owner = ALICE })
assertEq(
    Identity.FormatRaidCheckAttendance(mismatchedPresent, ALICE),
    "0%",
    "raw group alias without canonicalization incorrectly marks the profile member absent"
)
assertEq(
    Identity.FormatRaidCheckPreparedness(mismatchedPresent, ALICE),
    "0%",
    "raw group alias without canonicalization incorrectly marks the profile member unprepared"
)

local rosterIds = { ALICE, BOB, CAROL }
local liveGroup = { "alice-Garona", "Guest-Garona", "BOB-garona", "alice-Garona" }
local canonicalPresent = CheckRun.CanonicalizePresentMembers(liveGroup, rosterIds)
assertEq(#canonicalPresent, 3, "canonical present keeps two profile members plus one guest")
assertEq(canonicalPresent[1], ALICE, "case-variant group id maps to the authoritative profile ID")
assertEq(canonicalPresent[2], "Guest-Garona", "non-profile guest is preserved")
assertEq(canonicalPresent[3], BOB, "second profile alias maps to the roster ID")
local aliceCount = 0
for i = 1, #canonicalPresent do
    if canonicalPresent[i] == ALICE then
        aliceCount = aliceCount + 1
    end
end
assertEq(aliceCount, 1, "duplicate group spellings of one character appear once")

-- Production path: CanonicalizePresentMembers -> RecordRaidCheckPresence -> Identity.Replay.
function UnitName(unit)
    if unit == "player" then
        return ALICE:match("^([^%-]+)")
    end
    return "Unknown"
end
function UnitFullName(unit)
    if unit == "player" then
        return ALICE:match("^([^%-]+)"), "Garona"
    end
    return "Unknown", "Garona"
end
function UnitClass()
    return "Warrior", "WARRIOR"
end
function GetServerTime()
    return 1700009000
end
function time()
    return 1700009000
end
function GetTime()
    return 0
end
SpectrumFederationDB = { lootHelper = { profiles = {}, syncSession = {}, window = {} } }
SpectrumFederationDebugDB = { enabled = false, logs = {} }
SF.Debug = setmetatable({
    Info = function() end,
    Warn = function() end,
    Error = function() end,
    Verbose = function() end,
    Log = function() end,
}, { __call = function() end })
SF.WOW_CLASSES = SF.WOW_CLASSES or {
    WARRIOR = { colorCode = { r = 0.78, g = 0.61, b = 0.43 } },
}
assert(loadfile("SpectrumFederation/modules/core.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/LootHelper/Members.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/LootHelper/Profiles.lua"))("SpectrumFederation", SF)
function SF:GetPlayerFullIdentifier()
    return ALICE
end
function SF:GetPlayerClass()
    return "WARRIOR"
end
SF.lootHelperDB = {
    enabled = true,
    profiles = {},
    activeProfileId = nil,
    activeProfile = nil,
    window = {},
    syncSession = {},
}
SpectrumFederationDB.lootHelper = SF.lootHelperDB
local profile = SF.LootProfile.new("Presence Canonicalize")
assertTrue(profile ~= nil, "profile was created for presence record/replay")
assertTrue(profile:AddMember(SF.Member.new(ALICE, "admin", "WARRIOR")), "alice added to profile")
assertTrue(profile:AddMember(SF.Member.new(BOB, "member", "WARRIOR")), "bob added to profile")
assertTrue(profile:AddMember(SF.Member.new(CAROL, "member", "WARRIOR")), "carol added to profile")
SF.lootHelperDB.profiles[profile:GetProfileId()] = profile
SF.lootHelperDB.activeProfileId = profile:GetProfileId()
SF.lootHelperDB.activeProfile = profile

local opportunityId = profile:GetProfileId() .. ":raid-check-alias"
local recordedPresent = CheckRun.CanonicalizePresentMembers(
    { "alice-Garona", "Guest-Garona", "BOB-garona" },
    { ALICE, BOB, CAROL }
)
local recordedPrepared = CheckRun.CollectPreparedPresentMembers({
    [ALICE] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FRESH },
    [BOB] = { class = CheckRun.CLASS.UNPREPARED, verified = CheckRun.VERIFIED.FRESH },
}, { "alice-Garona", "Guest-Garona", "BOB-garona" })
assertTrue(profile:RecordRaidCheckPresence({
    opportunityId = opportunityId,
    presentMembers = recordedPresent,
    eligibleMembers = { ALICE, BOB, CAROL },
    preparedMembers = recordedPrepared,
    logAuthor = "Raid Check",
    skipBroadcast = true,
    skipPermission = true,
}), "RecordRaidCheckPresence accepts the canonicalized presence payload")
assertTrue(not profile:RecordRaidCheckPresence({
    opportunityId = opportunityId,
    presentMembers = recordedPresent,
    eligibleMembers = { ALICE, BOB, CAROL },
    preparedMembers = recordedPrepared,
    logAuthor = "Raid Check",
    skipBroadcast = true,
    skipPermission = true,
}), "duplicate opportunity id is rejected by RecordRaidCheckPresence")

local storedLogs = profile:GetLootLogs() or {}
local presenceEvent = nil
for i = 1, #storedLogs do
    local log = storedLogs[i]
    local eventType = log.GetEventType and log:GetEventType() or log._eventType
    if eventType == "RAID_CHECK_PRESENCE" then
        presenceEvent = log
    end
end
assertTrue(presenceEvent ~= nil, "persisted RAID_CHECK_PRESENCE event exists")
local persisted = presenceEvent.GetEventData and presenceEvent:GetEventData() or presenceEvent._data
assertTrue(type(persisted) == "table", "persisted presence event data is a table")
local presentSet = {}
for i = 1, #(persisted.presentMembers or {}) do
    presentSet[persisted.presentMembers[i]] = true
end
assertTrue(presentSet[ALICE] == true, "persisted presentMembers uses the authoritative Alice profile ID")
assertTrue(presentSet["alice-Garona"] ~= true, "persisted presentMembers does not keep the live alias spelling")
assertTrue(presentSet["Guest-Garona"] == true, "persisted presentMembers keeps the non-profile guest")
assertTrue(presentSet[BOB] == true, "persisted presentMembers uses the authoritative Bob profile ID")
assertEq(#(persisted.eligibleMembers or {}), 3, "persisted eligibleMembers remains the 3-member profile roster")
assertEq(#(persisted.presentMembers or {}), 3, "persisted present count is 2 profile + 1 guest")

local replayed = Identity.Replay({ presenceEvent }, { owner = ALICE })
assertEq(Identity.FormatRaidCheckAttendance(replayed, ALICE), "100%", "canonical present credits Alice attendance")
assertEq(Identity.FormatRaidCheckPreparedness(replayed, ALICE), "100%", "canonical present credits Alice preparedness")
assertEq(Identity.FormatRaidCheckAttendance(replayed, BOB), "100%", "canonical present credits Bob attendance")
assertEq(Identity.FormatRaidCheckPreparedness(replayed, BOB), "0%", "unprepared Bob is 0% prepared")
assertEq(Identity.FormatRaidCheckAttendance(replayed, CAROL), "0%", "absent Carol remains 0% attendance")
assertEq(Identity.FormatRaidCheckAttendance(replayed, "Guest-Garona"), "100%", "non-profile guest still receives presence credit")
assertTrue(Identity.HasRaidCheckPresenceOpportunity(replayed, opportunityId), "opportunity id remains recorded once")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
