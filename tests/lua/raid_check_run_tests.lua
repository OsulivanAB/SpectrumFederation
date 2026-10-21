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

local function assertAlmost(actual, expected, epsilon, message)
    if type(actual) == "number" and type(expected) == "number" and math.abs(actual - expected) <= epsilon then
        pass(message)
    else
        fail(string.format("%s (expected %s ± %s, got %s)", message, tostring(expected), tostring(epsilon), tostring(actual)))
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

local unresolvedLocal = CheckRun.NewPlayer("L")
CheckRun.MarkAttempt(unresolvedLocal, "incomplete", true)
local unresolvedClass = CheckRun.ClassifyPlayer(unresolvedLocal, 10)
assertEq(unresolvedClass.class, CheckRun.CLASS.INSPECTION_FAILED, "incomplete local capture is Inspection Failed")
assertTrue(not unresolvedClass.countsForPot, "incomplete local capture does not count for Reward Pot")
assertTrue(CheckRun.PlayerNeedsMoreInspects(unresolvedLocal), "one incomplete local capture still retries")
for _ = 2, CheckRun.PER_TARGET_ATTEMPT_CAP do
    CheckRun.MarkAttempt(unresolvedLocal, "incomplete", true)
end
assertTrue(not CheckRun.PlayerNeedsMoreInspects(unresolvedLocal), "local incomplete retries stop at the attempt cap")

-- Still-loading link stubs must not burn the technical attempt cap or mark
-- technicalFailure; budget / no_progress still bound the run.
assertEq(CheckRun.AttemptKindForIncompleteReason("incomplete_link"), "pending", "incomplete_link is pending")
assertEq(CheckRun.AttemptKindForIncompleteReason("pending_link"), "pending", "pending_link is pending")
assertEq(CheckRun.AttemptKindForIncompleteReason("unresolved_item_level"), "incomplete", "item level stays incomplete")
assertEq(CheckRun.AttemptKindForIncompleteReason("unresolved_enchant"), "incomplete", "unresolved enchant stays incomplete")

local pendingPlayer = CheckRun.NewPlayer("P")
for _ = 1, 12 do
    CheckRun.MarkAttempt(pendingPlayer, "pending", true, 100)
end
assertEq(pendingPlayer.attemptCount or 0, 0, "pending attempts do not increment attemptCount")
assertEq(pendingPlayer.pendingAttemptCount, 12, "pending attempts are counted separately")
assertTrue(not pendingPlayer.technicalFailure, "pending does not set technicalFailure")
assertTrue(pendingPlayer.inspectableAtLeastOnce, "pending still marks inspectable")
assertTrue(CheckRun.PlayerNeedsMoreInspects(pendingPlayer), "pending-only player still needs inspects")
local pendingClass = CheckRun.ClassifyPlayer(pendingPlayer, 10)
assertEq(pendingClass.class, CheckRun.CLASS.INSPECTION_FAILED, "pending-only without complete obs is Inspection Failed at settle")
assertTrue(not pendingClass.countsForPot, "pending-only Inspection Failed does not count for Reward Pot")

CheckRun.MarkAttempt(pendingPlayer, "complete", true, 200)
assertTrue(pendingPlayer.nextPendingRetryAt == nil, "complete clears the pending retry gate")
pendingPlayer.freshObservation = { complete = true, policy = { prepared = true, missing = {} }, capturedAt = 10 }
pendingPlayer.technicalFailure = false
local pendingThenReady = CheckRun.ClassifyPlayer(pendingPlayer, 10)
assertEq(pendingThenReady.class, CheckRun.CLASS.PREPARED, "complete after pending classifies Prepared")
assertTrue(not pendingThenReady.countsForPot, "Prepared after pending does not count for Reward Pot")

-- Pending retries must be rate-limited and must not refresh no-progress forever.
assertTrue(CheckRun.AttemptCountsAsProgress("complete"), "complete counts as progress")
assertTrue(CheckRun.AttemptCountsAsProgress("incomplete"), "incomplete counts as progress")
assertTrue(CheckRun.AttemptCountsAsProgress("timeout"), "timeout counts as progress")
local firstPendingProbe = CheckRun.NewPlayer("FP")
assertTrue(
    CheckRun.AttemptCountsAsProgress("pending", firstPendingProbe),
    "first pending for an unvisited player counts as progress"
)
firstPendingProbe.inspectableAtLeastOnce = true
assertTrue(
    not CheckRun.AttemptCountsAsProgress("pending", firstPendingProbe),
    "repeated pending does not count as progress"
)

local unvisitedReachable = CheckRun.NewPlayer("UR")
unvisitedReachable.currentlyInspectable = true
local unvisitedClass = CheckRun.ClassifyPlayer(unvisitedReachable, 10)
assertEq(
    unvisitedClass.class,
    CheckRun.CLASS.INSPECTION_FAILED,
    "reachable but never-visited target is Inspection Failed, not availability Unprepared"
)
assertTrue(not unvisitedClass.countsForPot, "reachable unvisited target does not count for Reward Pot")

local genuineUnavailable = CheckRun.NewPlayer("GU")
genuineUnavailable.currentlyInspectable = false
local genuineClass = CheckRun.ClassifyPlayer(genuineUnavailable, 10)
assertEq(genuineClass.class, CheckRun.CLASS.UNPREPARED_AVAILABILITY, "never-inspectable stays availability Unprepared")
assertTrue(genuineClass.countsForPot, "genuine availability Unprepared still counts for Reward Pot")

local gated = CheckRun.NewPlayer("G")
local t0 = 1000
CheckRun.MarkAttempt(gated, "pending", true, t0)
assertTrue(gated.nextPendingRetryAt ~= nil, "pending schedules nextPendingRetryAt")
assertAlmost(
    gated.nextPendingRetryAt,
    t0 + CheckRun.PendingRetryDelaySeconds(),
    1e-6,
    "pending retry gate uses PENDING_RETRY_SECONDS"
)
assertTrue(not CheckRun.PlayerMayQueueInspect(gated, t0 + 0.25), "0.25s later pending still blocks queueing")
assertTrue(not CheckRun.PlayerMayQueueInspect(gated, gated.nextPendingRetryAt - 0.01), "just before the gate still blocks")
assertTrue(CheckRun.PlayerMayQueueInspect(gated, gated.nextPendingRetryAt), "at the gate pending may queue again")
assertTrue(CheckRun.PlayerNeedsMoreInspects(gated), "pending gate does not consume the attempt cap")

-- Simulate acquisition: fast pending responses must not issue per-ticker inspects,
-- must settle via no_progress when nothing resolves, and must recover on complete.
local function SimulatePendingAcquisition(opts)
    opts = opts or {}
    local run = CheckRun.NewRun({ targetIds = { "A" }, now = 0 })
    local player = run.players.A
    local inspectRequests = 0
    local pendingResults = 0
    local clock = 0
    local tick = opts.tick or 0.25
    local pendingReadyDelay = opts.pendingReadyDelay or 0.05
    local resolveAfterRequests = opts.resolveAfterRequests
    local maxTicks = opts.maxTicks or 500

    local function maybeQueue()
        if CheckRun.PlayerMayQueueInspect(player, clock) then
            inspectRequests = inspectRequests + 1
            player.__sfActiveRequestedAt = clock
            return true
        end
        return false
    end

    local function applyPending()
        pendingResults = pendingResults + 1
        local counts = CheckRun.AttemptCountsAsProgress("pending", player)
        CheckRun.MarkAttempt(player, "pending", true, clock)
        if counts then
            CheckRun.NoteProgress(run, clock)
        end
    end

    local function applyComplete()
        CheckRun.MarkAttempt(player, "complete", true, clock)
        player.freshObservation = {
            complete = true,
            policy = { prepared = true, missing = {} },
            capturedAt = clock,
        }
        player.policyResult = player.freshObservation.policy
        player.technicalFailure = false
        CheckRun.NoteProgress(run, clock)
    end

    maybeQueue()
    for _ = 1, maxTicks do
        clock = clock + tick
        CheckRun.AdvanceClock(run, clock)
        if player.__sfActiveRequestedAt then
            local issuedAt = player.__sfActiveRequestedAt
            if (clock - issuedAt) + 1e-9 >= pendingReadyDelay then
                player.__sfActiveRequestedAt = nil
                if resolveAfterRequests and inspectRequests >= resolveAfterRequests then
                    applyComplete()
                else
                    applyPending()
                end
            end
        end
        local settle, why = CheckRun.ShouldSettle(run, clock)
        if settle then
            CheckRun.ClassifyRun(run, clock, {})
            return {
                run = run,
                player = player,
                inspectRequests = inspectRequests,
                pendingResults = pendingResults,
                clock = clock,
                why = why,
                class = run.classifiedResults.A and run.classifiedResults.A.class or nil,
            }
        end
        if not player.__sfActiveRequestedAt then
            maybeQueue()
        end
    end
    return {
        run = run,
        player = player,
        inspectRequests = inspectRequests,
        pendingResults = pendingResults,
        clock = clock,
        why = "max_ticks",
        class = nil,
    }
end

local neverResolves = SimulatePendingAcquisition({})
assertEq(neverResolves.why, "no_progress", "unchanged pending settles via no_progress, not ticker storms")
assertTrue(neverResolves.inspectRequests >= 1, "at least one inspect was issued")
assertTrue(
    neverResolves.inspectRequests <= 1 + math.ceil(CheckRun.NO_PROGRESS_SECONDS / CheckRun.PendingRetryDelaySeconds()) + 1,
    "pending inspects stay near the pending-retry cadence, not 0.25s ticker cadence"
)
assertTrue(
    neverResolves.pendingResults <= neverResolves.inspectRequests,
    "each pending result corresponds to an issued inspect"
)
assertEq(neverResolves.player.attemptCount or 0, 0, "unresolved pending never burns technical attempts")
assertEq(neverResolves.class, CheckRun.CLASS.INSPECTION_FAILED, "unresolved pending classifies Inspection Failed")
assertTrue(not neverResolves.run.classifiedResults.A.countsForPot, "unresolved pending does not deduct Reward Pot")

local resolves = SimulatePendingAcquisition({ resolveAfterRequests = 3 })
assertEq(resolves.why, "targets_resolved", "complete observation settles targets_resolved")
assertEq(resolves.inspectRequests, 3, "resolved path issued exactly three inspects before success")
assertEq(resolves.pendingResults, 2, "two pending results precede the successful inspect")
assertEq(resolves.class, CheckRun.CLASS.PREPARED, "eventual complete observation classifies Prepared")
assertTrue(not resolves.run.classifiedResults.A.countsForPot, "Prepared after pending still does not deduct pot")
assertTrue(resolves.player.nextPendingRetryAt == nil, "success clears pending retry gate")

-- Multi-target serial acquisition: first sweep may exceed NO_PROGRESS_SECONDS without
-- charging Reward Pot for reachable players the queue has not visited yet.
local function SimulateSerialRaidAcquisition(opts)
    opts = opts or {}
    local targetCount = opts.targetCount or 14
    local targetIds = {}
    for i = 1, targetCount do
        targetIds[i] = string.format("T%02d", i)
    end
    local run = CheckRun.NewRun({ targetIds = targetIds, now = 0 })
    for _, id in ipairs(targetIds) do
        run.players[id].currentlyInspectable = true
    end
    local clock = 0
    local tick = opts.tick or 0.25
    local readyDelay = opts.readyDelay or CheckRun.PER_INSPECT_ACTIVE_WAIT
    local maxTicks = opts.maxTicks or 2000
    local inspectRequests = 0
    local activeId = nil
    local activeIssuedAt = nil
    local resolveAllAfterSweep = opts.resolveAllAfterSweep == true
    local keepPendingForever = opts.keepPendingForever ~= false

    local function queueNext()
        -- Match production: pass run so pending retries defer until every
        -- reachable target has received a first inspect opportunity.
        for _, id in ipairs(targetIds) do
            local player = run.players[id]
            if CheckRun.PlayerMayQueueInspect(player, clock, run) then
                inspectRequests = inspectRequests + 1
                activeId = id
                activeIssuedAt = clock
                return true
            end
        end
        return false
    end

    queueNext()
    for _ = 1, maxTicks do
        clock = clock + tick
        CheckRun.AdvanceClock(run, clock)
        if activeId and activeIssuedAt and (clock - activeIssuedAt) + 1e-9 >= readyDelay then
            local player = run.players[activeId]
            local sweepDone = true
            for _, id in ipairs(targetIds) do
                if not run.players[id].inspectableAtLeastOnce and id ~= activeId then
                    sweepDone = false
                    break
                end
            end
            if resolveAllAfterSweep and sweepDone then
                CheckRun.MarkAttempt(player, "complete", true, clock)
                player.freshObservation = {
                    complete = true,
                    policy = { prepared = true, missing = {} },
                    capturedAt = clock,
                }
                player.policyResult = player.freshObservation.policy
                player.technicalFailure = false
                CheckRun.NoteProgress(run, clock)
            else
                local counts = CheckRun.AttemptCountsAsProgress("pending", player)
                CheckRun.MarkAttempt(player, "pending", true, clock)
                if counts then
                    CheckRun.NoteProgress(run, clock)
                end
            end
            activeId = nil
            activeIssuedAt = nil
        end

        local settle, why = CheckRun.ShouldSettle(run, clock)
        if settle then
            CheckRun.ClassifyRun(run, clock, {})
            local potHits = 0
            local failedNoPot = 0
            local prepared = 0
            local unvisited = 0
            for _, id in ipairs(targetIds) do
                local result = run.classifiedResults[id]
                local player = run.players[id]
                if not player.inspectableAtLeastOnce then
                    unvisited = unvisited + 1
                end
                if result and result.countsForPot then
                    potHits = potHits + 1
                end
                if result and result.class == CheckRun.CLASS.INSPECTION_FAILED and not result.countsForPot then
                    failedNoPot = failedNoPot + 1
                end
                if result and result.class == CheckRun.CLASS.PREPARED then
                    prepared = prepared + 1
                end
            end
            return {
                run = run,
                clock = clock,
                why = why,
                inspectRequests = inspectRequests,
                potHits = potHits,
                failedNoPot = failedNoPot,
                prepared = prepared,
                unvisited = unvisited,
                anyUnpreparedForPot = CheckRun.AnyUnpreparedForPot(run.classifiedResults),
            }
        end

        if not activeId then
            queueNext()
        end
        if not keepPendingForever and resolveAllAfterSweep then
            -- continue until settle
        end
    end
    return {
        run = run,
        clock = clock,
        why = "max_ticks",
        inspectRequests = inspectRequests,
        potHits = -1,
        failedNoPot = -1,
        prepared = -1,
        unvisited = -1,
        anyUnpreparedForPot = true,
    }
end

local earlyStall = CheckRun.NewRun({
    targetIds = { "A", "B", "C" },
    now = 0,
})
earlyStall.players.A.currentlyInspectable = true
earlyStall.players.B.currentlyInspectable = true
earlyStall.players.C.currentlyInspectable = true
CheckRun.MarkAttempt(earlyStall.players.A, "pending", true, 0)
CheckRun.NoteProgress(earlyStall, 0)
CheckRun.AdvanceClock(earlyStall, 11)
local settleEarly, whyEarly = CheckRun.ShouldSettle(earlyStall, 11)
assertTrue(not settleEarly, "no_progress waits while reachable targets remain unvisited")
assertEq(whyEarly, "initial_acquisition", "unfinished first sweep reports initial_acquisition")
assertTrue(CheckRun.InitialAcquisitionIncomplete(earlyStall), "B/C still need a first inspect")
assertTrue(
    not CheckRun.PlayerMayQueueInspect(earlyStall.players.A, 11, earlyStall),
    "visited pending target defers while the first sweep is incomplete"
)
assertTrue(
    CheckRun.PlayerMayQueueInspect(earlyStall.players.B, 11, earlyStall),
    "unvisited reachable target may queue during the first sweep"
)

local multiPending = SimulateSerialRaidAcquisition({
    targetCount = 14,
    keepPendingForever = true,
    resolveAllAfterSweep = false,
})
assertTrue(multiPending.clock > CheckRun.NO_PROGRESS_SECONDS, "14-target serial sweep runs past 10s")
assertTrue(multiPending.unvisited == 0, "every reachable target receives at least one inspect before idle settle")
assertEq(multiPending.why, "no_progress", "after the first sweep, repeated pending settles via no_progress")
assertTrue(not multiPending.anyUnpreparedForPot, "multi-target pending settle does not deduct Reward Pot")
assertEq(multiPending.potHits, 0, "no classified target counts for Reward Pot after pending-only settle")
assertTrue(multiPending.failedNoPot == 14, "all fourteen pending targets are Inspection Failed without pot")

local multiResolve = SimulateSerialRaidAcquisition({
    targetCount = 14,
    keepPendingForever = false,
    resolveAllAfterSweep = true,
})
assertEq(multiResolve.why, "targets_resolved", "serial sweep can still resolve every target within budget")
assertEq(multiResolve.prepared, 14, "all fourteen targets classify Prepared after resolution")
assertTrue(not multiResolve.anyUnpreparedForPot, "resolved Prepared run does not deduct Reward Pot")
assertTrue(multiResolve.unvisited == 0, "resolved path still visits every target")

-- Budget settlement with an unvisited reachable target must not charge the pot.
local budgetRun = CheckRun.NewRun({ targetIds = { "A", "B" }, now = 0 })
budgetRun.budgetSeconds = 5
budgetRun.players.A.currentlyInspectable = true
budgetRun.players.B.currentlyInspectable = true
CheckRun.MarkAttempt(budgetRun.players.A, "pending", true, 0)
CheckRun.NoteProgress(budgetRun, 0)
CheckRun.AdvanceClock(budgetRun, 6)
local settleBudget, whyBudget = CheckRun.ShouldSettle(budgetRun, 6)
assertTrue(settleBudget, "budget still settles when elapsed exceeds budgetSeconds")
assertEq(whyBudget, "budget", "budget settlement reason is preserved")
CheckRun.ClassifyRun(budgetRun, 6, {})
assertEq(
    budgetRun.classifiedResults.B.class,
    CheckRun.CLASS.INSPECTION_FAILED,
    "budget-unvisited reachable target is Inspection Failed"
)
assertTrue(
    not budgetRun.classifiedResults.B.countsForPot,
    "budget-unvisited reachable target does not count for Reward Pot"
)
assertTrue(
    not CheckRun.AnyUnpreparedForPot(budgetRun.classifiedResults),
    "budget settle with unvisited reachable targets does not trigger pot deduction"
)

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

local lowLevel = CheckRun.ClassifyPlayer(rangeOnly, 50, {
    complete = true,
    capturedAt = 10,
    policy = { prepared = false, missing = { "Item Level 642.3 (650 required)" } },
})
assertEq(lowLevel.class, CheckRun.CLASS.UNPREPARED, "recent-good below item level is Unprepared")
assertEq(lowLevel.missing[1], "Item Level 642.3 (650 required)", "item-level reason is preserved")
assertTrue(lowLevel.countsForPot, "known low item level counts for Reward Pot")

local oorOnly = CheckRun.NewPlayer("E2")
oorOnly.rangeOnlyFailure = true
oorOnly.currentlyInspectable = false
local oorClass = CheckRun.ClassifyPlayer(oorOnly, 50, nil)
assertEq(oorClass.class, CheckRun.CLASS.UNPREPARED_AVAILABILITY, "out of range alone is not an item-level failure")
assertEq(#oorClass.missing, 0, "out of range does not invent an item-level reason")

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
CheckRun.MarkAttempt(capRun.players.A, "timeout", true)
local settleAfterOne, whyAfterOne = CheckRun.ShouldSettle(capRun, 1)
assertTrue(not settleAfterOne, "first timeout does not settle before the attempt cap")
assertTrue(CheckRun.PlayerNeedsMoreInspects(capRun.players.A), "technicalFailure still retries until the attempt cap")
for _ = 2, CheckRun.PER_TARGET_ATTEMPT_CAP do
    CheckRun.MarkAttempt(capRun.players.A, "timeout", true)
end
settle, why = CheckRun.ShouldSettle(capRun, 1)
assertTrue(settle, "per-target cap prevents infinite retry")
assertEq(why, "targets_resolved", "attempt-capped target is treated as resolved")
assertTrue(not CheckRun.PlayerNeedsMoreInspects(capRun.players.A), "capped target does not keep queueing inspects")

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

local function tryApply(run, session)
    if run.consequencesApplied then
        return false, "already_applied"
    end
    local shouldHold, reason = CheckRun.ShouldHoldConsequences(run, session)
    if shouldHold then
        return false, reason
    end
    local eligible, applyReason = CheckRun.ConsequenceSyncEligible(run, session)
    run.consequencesApplied = true
    run.consequencesEligible = eligible and true or false
    run.consequencesReason = applyReason
    run.consequencesSkipBroadcast = not eligible
    return true, applyReason
end

-- Successful announcement: classify before announce, hold, then apply once and stay active.
yesRun.classified = true
yesRun.consequencesApplied = false
local successState = { active = true, sessionId = "SES1", profileId = "p1" }
assertTrue(not Sync.ApplySesStartSendResult(successState, "SES1", false), "failed SES_START send does not mark announced")
assertEq(successState._sessionAnnounced, nil, "failed send leaves _sessionAnnounced unset")
local applied, appliedReason = tryApply(yesRun, {
    active = true,
    sessionId = "SES1",
    profileId = "p1",
    announced = false,
})
assertTrue(not applied, "classified results stay held until SES_START is accepted")
assertEq(appliedReason, "awaiting_announce", "pre-announce apply is skipped")
assertTrue(Sync.ApplySesStartSendResult(successState, "SES1", true), "successful SES_START send marks announced")
assertEq(successState._sessionAnnounced, "SES1", "successful announce records the session id")
assertEq(successState.active, true, "successful announce leaves the session active")
applied, appliedReason = tryApply(yesRun, {
    active = true,
    sessionId = "SES1",
    profileId = "p1",
    announced = true,
})
assertTrue(applied, "accepted SES_START releases consequences")
assertEq(appliedReason, "eligible", "successful announce is session-sync eligible")
assertTrue(not yesRun.consequencesSkipBroadcast, "successful announce may broadcast NEW_LOG")
applied, appliedReason = tryApply(yesRun, {
    active = true,
    sessionId = "SES1",
    profileId = "p1",
    announced = true,
})
assertTrue(not applied, "successful announce cannot apply consequences twice")
assertEq(appliedReason, "already_applied", "duplicate success callback is idempotent")
assertEq(Sync.ClassifyUnannouncedStartFailure(successState, "SES1"), "already_announced", "successful announcement cannot enter the failed-start path")
Sync.state = successState
local didReset, failOutcome = Sync:FailUnannouncedSessionStart("SES1")
assertTrue(not didReset, "FailUnannouncedSessionStart is a no-op after a successful announce")
assertEq(failOutcome, "already_announced", "announced sessions are not reset by a late fail callback")
assertEq(successState.active, true, "session remains active after a late failed-start callback")
assertEq(successState._sessionAnnounced, "SES1", "late fail callback does not clear an announced session")

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

-- Failed announcement: terminal failed-start, local apply once, no session broadcast, no SES_END.
local failedRun = CheckRun.NewRun({
    profileId = "p1",
    startedSessionForCheck = true,
    expectedSessionId = "SES-FAIL",
    targetIds = { "A" },
    now = 0,
})
failedRun.classified = true
failedRun.consequencesApplied = false
local failedState = { active = true, sessionId = "SES-FAIL", profileId = "p1", isCoordinator = true }
hold, holdReason = CheckRun.ShouldHoldConsequences(failedRun, {
    active = true,
    sessionId = "SES-FAIL",
    profileId = "p1",
    announced = false,
})
assertTrue(hold, "failed-send path still holds until terminal failed-start cleanup")
assertEq(holdReason, "awaiting_announce", "unannounced active session holds before cleanup")
assertTrue(not Sync.ApplySesStartSendResult(failedState, "SES-FAIL", false), "rejected SES_START send does not announce")
assertEq(Sync.ClassifyUnannouncedStartFailure(failedState, "SES-FAIL"), "reset", "rejected send classifies as a terminal reset")

local sentMessages = {}
SF.LootHelperComm = {
    Send = function(_, _, msg)
        sentMessages[#sentMessages + 1] = msg
        return true
    end,
}
local originalReset = Sync._ResetSessionState
local resetCount = 0
function Sync:_ResetSessionState(reason)
    resetCount = resetCount + 1
    local failedFor = self.state._sessionStartFailedFor
    self.state.active = false
    self.state.sessionId = nil
    self.state.profileId = nil
    self.state.isCoordinator = false
    self.state._sessionAnnounced = nil
    self.state._sessionStartFailedFor = failedFor
    self._lastResetReason = reason
end
local notified = {}
SF.RaidCheck = {
    OnSessionStartAnnounceFailed = function(_, sessionId)
        notified[#notified + 1] = sessionId
        CheckRun.NoteSessionStartFailed(failedRun)
    end,
}
Sync.state = failedState
didReset, failOutcome = Sync:FailUnannouncedSessionStart("SES-FAIL", "ses_start_send_failed")
assertTrue(didReset, "failed SES_START resets the never-announced session")
assertEq(failOutcome, "reset", "first failed-start cleanup resets")
assertEq(resetCount, 1, "failed-start uses one local session reset")
assertEq(failedState.active, false, "failed never-announced session is no longer active")
assertEq(failedState.sessionId, nil, "failed-start clears local session identity")
assertTrue(not Sync:HasAnnouncedCurrentSession("SES-FAIL"), "failed start is not announced")
assertEq(#sentMessages, 0, "failed-start cleanup does not broadcast SES_END")
assertEq(notified[1], "SES-FAIL", "Raid Check is notified of the failed start")
assertTrue(failedRun.sessionStartFailed, "run records terminal session-start failure")

local inactiveSession = { active = false, sessionId = nil, profileId = nil, announced = false }
hold, holdReason = CheckRun.ShouldHoldConsequences(failedRun, inactiveSession)
assertTrue(not hold, "terminal failed-start does not leave consequences pending")
assertEq(holdReason, "announce_failed", "hold reason becomes announce_failed after cleanup")
applied, appliedReason = tryApply(failedRun, inactiveSession)
assertTrue(applied, "deferred consequences apply locally after failed start")
assertEq(appliedReason, "announce_failed", "failed start applies with announce_failed")
assertTrue(failedRun.consequencesSkipBroadcast, "failed start uses local-only skipBroadcast")
assertTrue(not failedRun.consequencesEligible, "failed start is not session-sync eligible")
applied, appliedReason = tryApply(failedRun, inactiveSession)
assertTrue(not applied, "failed-start cleanup cannot apply consequences twice")
assertEq(appliedReason, "already_applied", "duplicate fail callback is idempotent")

didReset, failOutcome = Sync:FailUnannouncedSessionStart("SES-FAIL")
assertTrue(not didReset, "duplicate failed-start cleanup does not reset again")
assertEq(failOutcome, "already_failed", "second fail callback is already_failed")
assertEq(resetCount, 1, "duplicate fail does not reset session state twice")
assertEq(#sentMessages, 0, "duplicate fail still does not broadcast SES_END")

assertTrue(not Sync.ApplySesStartSendResult(failedState, "SES-FAIL", true), "late success cannot resurrect a terminally failed session")
assertEq(failedState.active, false, "late success leaves the reset session inactive")
assertTrue(failedState._sessionAnnounced ~= "SES-FAIL", "late success does not mark the failed session announced")
local resurrectState = {
    active = true,
    sessionId = "SES-FAIL",
    profileId = "p1",
    _sessionStartFailedFor = "SES-FAIL",
}
assertTrue(not Sync.ApplySesStartSendResult(resurrectState, "SES-FAIL", true), "late success cannot revive a failed session id even if active flags are present")
assertEq(resurrectState._sessionAnnounced, nil, "failed session id cannot be marked announced after terminal failure")

-- Subsequent Raid Check after failed-start cleanup sees no active session and prompts again.
assertEq(failedState.active, false, "IsSessionActive equivalent is false after failed start")
local laterPreflight = CheckRun.DecidePreflight({
    hasProfile = true,
    isAdmin = true,
    sessionActive = failedState.active and true or false,
})
assertEq(laterPreflight.action, "prompt", "later Raid Check shows Yes/No/Cancel preflight again")

-- Race: NoteSessionStartFailed is idempotent.
assertTrue(not CheckRun.NoteSessionStartFailed(failedRun), "session-start failure flag is set only once")

Sync._ResetSessionState = originalReset
SF.RaidCheck = nil
SF.LootHelperComm = nil

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
