-- Production-Lua tests for Raid Equipment CheckRun and session announce gating.
-- Run from the repository root: lua5.1 tests/lua/raid_check_run_tests.lua

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

local SF = {}
assert(loadfile("SpectrumFederation/modules/RaidEquipment/CheckRun.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/LootHelperSync/09_AdminConvergence.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/LootHelperSync/18_PublicAPI.lua"))("SpectrumFederation", SF)

local CheckRun = SF.RaidEquipment.CheckRun
local Sync = SF.LootHelperSync

-- Bounds
assertTrue(CheckRun.ComputeActiveBudget(1) < CheckRun.ComputeActiveBudget(20), "scaled bound increases with target count")
assertEq(CheckRun.ComputeActiveBudget(0), CheckRun.BASE_OVERALL_SECONDS, "zero targets uses the base bound")
assertEq(CheckRun.ComputeActiveBudget(1000), CheckRun.SAFETY_CEILING_SECONDS, "final safety ceiling caps huge raids")
assertEq(CheckRun.PER_TARGET_ATTEMPT_CAP, 4, "per-target attempt cap is 4")
assertEq(CheckRun.RECENT_GOOD_SECONDS, 120, "recent-good window is 120s")

-- Inspect generation
local inspectState = CheckRun.NewInspectState()
local first = CheckRun.IssueInspect(inspectState, { guid = "g1", key = "p1", requestedAt = 1 })
assertEq(first.generation, 1, "first inspect is generation 1")
CheckRun.RetireActive(inspectState, "timeout")
local ok, why = CheckRun.CanAcceptInspectReady(inspectState, "g1")
assertTrue(ok, "timeout with no successor still accepts a late ready for the same GUID")
assertEq(why, "retired_current", "late ready is accepted as retired_current")

CheckRun.IssueInspect(inspectState, { guid = "g2", key = "p2", requestedAt = 2 })
ok, why = CheckRun.CanAcceptInspectReady(inspectState, "g1")
assertTrue(not ok, "unsafe late ready after a newer inspect is ignored")
assertEq(why, "guid_mismatch", "old GUID cannot capture the newer target")
ok, why = CheckRun.CanAcceptInspectReady(inspectState, "g2")
assertTrue(ok, "current inspect generation accepts its own GUID")

-- Frozen targets
local order, frozen = CheckRun.FreezeTargetIds({ "A", "B", "A" })
assertEq(#order, 2, "frozen target list de-duplicates")
assertTrue(frozen.A and frozen.B, "frozen membership map retains original members")
local intersected = CheckRun.IntersectMembershipAndGroup({ "A", "B", "C" }, { "B", "D", "A" })
assertEq(intersected[1], "A", "intersection preserves profile order")
assertEq(intersected[2], "B", "joiner D is ignored")
assertEq(#intersected, 2, "C is omitted because they are not in the group")

local run = CheckRun.NewRun({
    id = "run1",
    mode = "raid",
    profileId = "prof-a",
    targetIds = { "A", "B" },
    now = 10,
})
assertEq(run.profileId, "prof-a", "profile is frozen at run start")
assertEq(#run.targetIds, 2, "target list is frozen at run start")
assertTrue(run.players.A and run.players.B, "frozen players exist")
assertTrue(not run.players.C, "joiner is not added later")
run.players.A.leftGroup = true
assertTrue(run.players.A ~= nil, "leaver remains represented")

-- Classification
local preparedPlayer = CheckRun.NewPlayer("A")
preparedPlayer.freshObservation = { complete = true, policy = { prepared = true, missing = {} }, capturedAt = 10 }
local prepared = CheckRun.ClassifyPlayer(preparedPlayer, 10)
assertEq(prepared.class, CheckRun.CLASS.PREPARED, "fresh prepared")
assertEq(prepared.verified, CheckRun.VERIFIED.FRESH, "fresh prepared is Fresh Verified")
assertTrue(not prepared.countsForPot, "prepared does not count for Reward Pot")

local unpreparedPlayer = CheckRun.NewPlayer("B")
unpreparedPlayer.freshObservation = { complete = true, policy = { prepared = false, missing = { "Head Enchant" } }, capturedAt = 10 }
local unprepared = CheckRun.ClassifyPlayer(unpreparedPlayer, 10)
assertEq(unprepared.class, CheckRun.CLASS.UNPREPARED, "fresh policy Unprepared")
assertTrue(unprepared.countsForPot, "policy Unprepared counts for Reward Pot")

local never = CheckRun.NewPlayer("C")
local avail = CheckRun.ClassifyPlayer(never, 10)
assertEq(avail.class, CheckRun.CLASS.UNPREPARED_AVAILABILITY, "never inspectable is availability Unprepared")
assertTrue(avail.countsForPot, "availability Unprepared counts for Reward Pot")

local failed = CheckRun.NewPlayer("D")
CheckRun.MarkAttempt(failed, "timeout", true)
local failedClass = CheckRun.ClassifyPlayer(failed, 10)
assertEq(failedClass.class, CheckRun.CLASS.INSPECTION_FAILED, "technical failure is Inspection Failed")
assertTrue(not failedClass.countsForPot, "Inspection Failed is excluded from Reward Pot")

failed.currentlyInspectable = false
failed.rangeOnlyFailure = true
local failedLaterOor = CheckRun.ClassifyPlayer(failed, 50, {
    complete = true,
    capturedAt = 40,
    policy = { prepared = true, missing = {} },
})
assertEq(failedLaterOor.class, CheckRun.CLASS.INSPECTION_FAILED, "technical failure followed by OOR remains Inspection Failed")

local rangeOnly = CheckRun.NewPlayer("E")
rangeOnly.rangeOnlyFailure = true
rangeOnly.currentlyInspectable = false
local recent = CheckRun.ClassifyPlayer(rangeOnly, 50, {
    complete = true,
    capturedAt = 10,
    policy = { prepared = true, missing = {} },
})
assertEq(recent.class, CheckRun.CLASS.PREPARED, "120s range-only recent-good fallback")
assertEq(recent.verified, CheckRun.VERIFIED.RECENT, "recent-good is Recently Verified")

local stale = CheckRun.ClassifyPlayer(rangeOnly, 200, {
    complete = true,
    capturedAt = 10,
    policy = { prepared = true, missing = {} },
})
assertEq(stale.class, CheckRun.CLASS.UNPREPARED_AVAILABILITY, "expired last-good does not stay Recently Verified")

local techBeatsRecent = CheckRun.NewPlayer("F")
CheckRun.MarkAttempt(techBeatsRecent, "incomplete", true)
local techClass = CheckRun.ClassifyPlayer(techBeatsRecent, 20, {
    complete = true,
    capturedAt = 10,
    policy = { prepared = true, missing = {} },
})
assertEq(techClass.class, CheckRun.CLASS.INSPECTION_FAILED, "recent-good does not override current-run technical failure")

-- Combat pause does not consume active bounds
local pausedRun = CheckRun.NewRun({ targetIds = { "A" }, now = 0 })
CheckRun.AdvanceClock(pausedRun, 1)
CheckRun.SetPause(pausedRun, "combat", true)
CheckRun.AdvanceClock(pausedRun, 30)
assertEq(pausedRun.activeElapsed, 1, "paused duration does not consume active bounds")
local settlePaused = CheckRun.ShouldSettle(pausedRun, 30)
assertTrue(not settlePaused, "start/mid-run combat pause prevents settle")
CheckRun.SetPause(pausedRun, "combat", false)
CheckRun.AdvanceClock(pausedRun, 32)
CheckRun.AdvanceClock(pausedRun, 34)
assertEq(pausedRun.activeElapsed, 3, "resume continues remaining active time")

-- No-progress uses active elapsed, not wall clock
local progressRun = CheckRun.NewRun({ targetIds = { "A", "B", "C" }, now = 0 })
progressRun.lastProgressActiveElapsed = 0
CheckRun.SetPause(progressRun, "combat", true)
CheckRun.AdvanceClock(progressRun, 50)
CheckRun.SetPause(progressRun, "combat", false)
CheckRun.AdvanceClock(progressRun, 51)
local settle, why = CheckRun.ShouldSettle(progressRun, 51)
assertTrue(not settle, "long combat does not trip no-progress")
assertEq(why, nil, "no settle reason while still working after resume")

-- Per-target cap settles a broken target
local capRun = CheckRun.NewRun({ targetIds = { "A" }, now = 0 })
for _ = 1, CheckRun.PER_TARGET_ATTEMPT_CAP do
    CheckRun.MarkAttempt(capRun.players.A, "timeout", true)
end
settle, why = CheckRun.ShouldSettle(capRun, 1)
assertTrue(settle, "per-target cap prevents infinite retry")
assertEq(why, "targets_resolved", "attempt-capped target is treated as resolved")

-- Preflight
assertEq(CheckRun.DecidePreflight({ dialogOpen = true, hasProfile = true, isAdmin = true }).action, "busy", "duplicate clicks do not create duplicate dialogs")
assertEq(CheckRun.DecidePreflight({ runInFlight = true, hasProfile = true, isAdmin = true }).action, "busy", "in-flight run is busy")
assertEq(CheckRun.DecidePreflight({ hasProfile = false, isAdmin = true }).action, "error", "no profile is an error")
assertEq(CheckRun.DecidePreflight({ hasProfile = true, isAdmin = false }).reason, "not_admin", "non-admin cannot run")
local matching = CheckRun.DecidePreflight({
    hasProfile = true,
    isAdmin = true,
    sessionActive = true,
    sessionProfileId = "p1",
    selectedProfileId = "p1",
})
assertEq(matching.action, "start", "active matching session starts with no dialog")
assertTrue(not matching.warnMismatch, "matching session does not warn")
local mismatch = CheckRun.DecidePreflight({
    hasProfile = true,
    isAdmin = true,
    sessionActive = true,
    sessionProfileId = "other",
    selectedProfileId = "p1",
})
assertEq(mismatch.action, "start", "mismatched session still proceeds")
assertTrue(mismatch.warnMismatch, "mismatched session warns")
assertEq(CheckRun.DecidePreflight({ hasProfile = true, isAdmin = true, sessionActive = false }).action, "prompt", "no session prompts")

assertEq(CheckRun.ApplyDialogChoice("cancel").action, "abort", "Escape/cancel aborts")
assertEq(CheckRun.ApplyDialogChoice("escape").action, "abort", "escape aborts")
assertEq(CheckRun.ApplyDialogChoice("no").action, "start", "explicit No runs without a session")
assertTrue(not CheckRun.ApplyDialogChoice("no").startSession, "No does not start a session")
local yesOk = CheckRun.ApplyDialogChoice("yes", true)
assertEq(yesOk.action, "start", "Yes success starts the check")
assertTrue(yesOk.startSession, "Yes starts a session")
assertEq(CheckRun.ApplyDialogChoice("yes", false).action, "abort", "Yes failure does not start a run")

-- Session announce / consequences
local yesRun = CheckRun.NewRun({
    profileId = "p1",
    startedSessionForCheck = true,
    expectedSessionId = "SES1",
    targetIds = { "A" },
    now = 0,
})
local hold, holdReason = CheckRun.ShouldHoldConsequences(yesRun, {
    active = true,
    sessionId = "SES1",
    profileId = "p1",
    announced = false,
})
assertTrue(hold, "local StartSession return alone does not release consequences")
assertEq(holdReason, "awaiting_announce", "consequences wait for SES_START send acceptance")

local state = { sessionId = "SES1" }
assertTrue(not Sync.ApplySesStartSendResult(state, "SES1", false), "failed SES_START send does not mark announced")
assertEq(state._sessionAnnounced, nil, "failed send leaves _sessionAnnounced unset")
assertTrue(Sync.ApplySesStartSendResult(state, "SES1", true), "successful SES_START send marks announced")
assertEq(state._sessionAnnounced, "SES1", "successful announce records the session id")

Sync.state = {
    active = true,
    sessionId = "SES1",
    profileId = "p1",
    _sessionAnnounced = "SES1",
}
assertTrue(Sync:HasAnnouncedCurrentSession("SES1"), "HasAnnouncedCurrentSession is true after accepted send")
Sync.state._sessionAnnounced = nil
assertTrue(not Sync:HasAnnouncedCurrentSession("SES1"), "failed local send does not expose the session as announced")

hold = CheckRun.ShouldHoldConsequences(yesRun, {
    active = true,
    sessionId = "SES1",
    profileId = "p1",
    announced = true,
})
assertTrue(not hold, "announce releases consequences")

local eligible, eligReason = CheckRun.ConsequenceSyncEligible(yesRun, {
    active = true,
    sessionId = "SES2",
    profileId = "p1",
    announced = true,
})
assertTrue(not eligible, "unrelated/changed session is not eligible")
assertEq(eligReason, "session_changed", "expected session disappearing before ready is local-only")

local mismatchRun = CheckRun.NewRun({
    profileId = "p1",
    sessionMismatch = true,
    targetIds = { "A" },
    now = 0,
})
eligible, eligReason = CheckRun.ConsequenceSyncEligible(mismatchRun, {
    active = true,
    sessionId = "OTHER",
    profileId = "other",
    announced = true,
})
assertTrue(not eligible, "unrelated session never receives the frozen profile's logs")
assertEq(eligReason, "mismatch", "mismatch is decided before broadcast")

-- Classify before announce does not apply consequences
yesRun.classified = true
yesRun.consequencesApplied = false
hold = CheckRun.ShouldHoldConsequences(yesRun, {
    active = true,
    sessionId = "SES1",
    profileId = "p1",
    announced = false,
})
assertTrue(hold, "acquisition may classify before announce while consequences wait")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
