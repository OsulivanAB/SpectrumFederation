-- Ad-hoc Raid Check run state: freeze, bounds, provenance, classification, inspect tokens.
local _, SF = ...

SF.RaidEquipment = SF.RaidEquipment or {}
local CheckRun = {}
SF.RaidEquipment.CheckRun = CheckRun

CheckRun.RECENT_GOOD_SECONDS = 120
-- Same-session last-good may back a Raid Check for this long after capture.
-- Sized for the typical ~15 minute pre-raid collection window with margin; not
-- a return to the short 120s legacy OOR window.
CheckRun.SESSION_LAST_GOOD_SECONDS = 20 * 60
CheckRun.PER_TARGET_ATTEMPT_CAP = 4
CheckRun.PER_INSPECT_ACTIVE_WAIT = 2.0
-- Minimum gap between remote/local retries after a still-loading (pending) result.
-- Reuses the per-inspect active wait so pending cannot re-queue on the 0.25s ticker.
CheckRun.PENDING_RETRY_SECONDS = CheckRun.PER_INSPECT_ACTIVE_WAIT
CheckRun.PER_TARGET_SLOT_SECONDS = 3.5
CheckRun.BASE_OVERALL_SECONDS = 8
CheckRun.SAFETY_CEILING_SECONDS = 180
CheckRun.NO_PROGRESS_SECONDS = 10
CheckRun.SESSION_READY_POLL_SECONDS = 0.2

CheckRun.CLASS = {
	PENDING = "pending",
	PREPARED = "prepared",
	UNPREPARED = "unprepared",
	UNPREPARED_AVAILABILITY = "unprepared_availability",
	INSPECTION_FAILED = "inspection_failed",
}

CheckRun.VERIFIED = {
	FRESH = "fresh",
	-- Legacy no-session / unscoped OOR fallback within RECENT_GOOD_SECONDS.
	RECENT = "recent",
	-- Same-session complete last-good within SESSION_LAST_GOOD_SECONDS.
	SESSION = "session",
}

function CheckRun.ComputeActiveBudget(targetCount)
	targetCount = tonumber(targetCount) or 0
	if targetCount < 0 then
		targetCount = 0
	end
	local scaled = CheckRun.BASE_OVERALL_SECONDS + (targetCount * CheckRun.PER_TARGET_SLOT_SECONDS)
	if scaled < CheckRun.BASE_OVERALL_SECONDS then
		scaled = CheckRun.BASE_OVERALL_SECONDS
	end
	if scaled > CheckRun.SAFETY_CEILING_SECONDS then
		return CheckRun.SAFETY_CEILING_SECONDS
	end
	return scaled
end

function CheckRun.NewInspectState()
	return {
		lastIssuedGeneration = 0,
		active = nil,
		retired = nil,
	}
end

function CheckRun.IssueInspect(inspectState, request)
	inspectState = inspectState or CheckRun.NewInspectState()
	inspectState.lastIssuedGeneration = (inspectState.lastIssuedGeneration or 0) + 1
	inspectState.active = {
		generation = inspectState.lastIssuedGeneration,
		guid = request and request.guid or nil,
		key = request and request.key or nil,
		id = request and request.id or nil,
		aliases = request and request.aliases or nil,
		runId = request and request.runId or nil,
		requestedAt = request and request.requestedAt or nil,
	}
	inspectState.retired = nil
	return inspectState.active
end

function CheckRun.RetireActive(inspectState, reason)
	if not inspectState or not inspectState.active then
		return
	end
	inspectState.retired = inspectState.active
	inspectState.retired.reason = reason
	inspectState.active = nil
end

function CheckRun.CanAcceptInspectReady(inspectState, eventGuid)
	if type(inspectState) ~= "table" then
		return false, "no_state"
	end
	local last = inspectState.lastIssuedGeneration or 0
	if last <= 0 then
		return false, "no_generation"
	end

	local active = inspectState.active
	if type(active) == "table" and active.generation == last then
		if eventGuid and active.guid and eventGuid ~= active.guid then
			return false, "guid_mismatch"
		end
		return true, "active"
	end

	local retired = inspectState.retired
	if type(active) ~= "table" and type(retired) == "table" and retired.generation == last then
		if eventGuid and retired.guid and eventGuid ~= retired.guid then
			return false, "guid_mismatch"
		end
		return true, "retired_current"
	end

	return false, "superseded"
end

function CheckRun.FreezeTargetIds(memberIds)
	local frozen = {}
	local order = {}
	for _, memberId in ipairs(memberIds or {}) do
		if type(memberId) == "string" and memberId ~= "" and not frozen[memberId] then
			frozen[memberId] = true
			order[#order + 1] = memberId
		end
	end
	return order, frozen
end

function CheckRun.IntersectMembershipAndGroup(memberIds, groupIds)
	local inGroup = {}
	for _, id in ipairs(groupIds or {}) do
		if type(id) == "string" then
			inGroup[id] = true
		end
	end
	local out = {}
	for _, id in ipairs(memberIds or {}) do
		if inGroup[id] then
			out[#out + 1] = id
		end
	end
	return out
end

function CheckRun.NewPlayer(memberId)
	return {
		id = memberId,
		unitHint = nil,
		aliases = nil,
		inspectableAtLeastOnce = false,
		attemptCount = 0,
		lastAttemptKind = nil,
		technicalFailure = false,
		freshObservation = nil,
		policyResult = nil,
		leftGroup = false,
		-- Live: can we inspect this player right now?
		currentlyInspectable = false,
		-- Sticky: observed reachable at least once this run (start or later).
		-- Distinct from currentlyInspectable so OOR unvisited targets do not
		-- block the first sweep, yet still avoid Reward Pot availability charges.
		wasReachable = false,
		rangeOnlyFailure = false,
		terminal = nil,
		verified = nil,
	}
end

-- Refresh live inspectability. Sticky wasReachable records historical reachability.
function CheckRun.UpdateReachability(player, canInspectNow)
	if type(player) ~= "table" then
		return
	end
	if canInspectNow then
		player.currentlyInspectable = true
		player.wasReachable = true
	else
		player.currentlyInspectable = false
	end
end

function CheckRun.NewRun(opts)
	opts = opts or {}
	local targetIds = opts.targetIds or {}
	local players = {}
	for _, id in ipairs(targetIds) do
		players[id] = CheckRun.NewPlayer(id)
	end
	return {
		id = opts.id,
		mode = opts.mode,
		profileId = opts.profileId,
		expectedSessionId = opts.expectedSessionId,
		expectedSessionProfileId = opts.expectedSessionProfileId,
		startedSessionForCheck = opts.startedSessionForCheck and true or false,
		sessionMismatch = opts.sessionMismatch and true or false,
		targetIds = targetIds,
		groupMemberIds = opts.groupMemberIds or {},
		rosterMemberIds = opts.rosterMemberIds or {},
		players = players,
		pauseReasons = {},
		activeElapsed = 0,
		lastRunningAt = opts.now,
		budgetSeconds = CheckRun.ComputeActiveBudget(#targetIds),
		lastProgressAt = opts.now,
		lastProgressActiveElapsed = 0,
		status = "running",
		classified = false,
		consequencesApplied = false,
		classifiedResults = nil,
	}
end

function CheckRun.IsPaused(run)
	if type(run) ~= "table" or type(run.pauseReasons) ~= "table" then
		return false
	end
	return next(run.pauseReasons) ~= nil
end

function CheckRun.SetPause(run, reason, enabled)
	if type(run) ~= "table" then
		return
	end
	run.pauseReasons = run.pauseReasons or {}
	if enabled then
		run.pauseReasons[reason] = true
	else
		run.pauseReasons[reason] = nil
	end
end

function CheckRun.AdvanceClock(run, now, opts)
	opts = opts or {}
	if type(run) ~= "table" or type(now) ~= "number" then
		return run and run.activeElapsed or 0
	end
	local paused = CheckRun.IsPaused(run) or opts.paused == true
	if paused then
		run.lastRunningAt = nil
		return run.activeElapsed or 0
	end
	if type(run.lastRunningAt) == "number" and now >= run.lastRunningAt then
		run.activeElapsed = (run.activeElapsed or 0) + (now - run.lastRunningAt)
	end
	run.lastRunningAt = now
	return run.activeElapsed
end

function CheckRun.NoteProgress(run, now)
	if type(run) == "table" then
		run.lastProgressAt = now
		run.lastProgressActiveElapsed = run.activeElapsed or 0
	end
end

-- pending = inspect/link data still loading. Counts for inspectability, but does
-- not burn PER_TARGET_ATTEMPT_CAP, set technicalFailure, or count as run progress.
-- A per-player nextPendingRetryAt gate spaces retries. Budget / no_progress still
-- settle the run if loading never completes.
function CheckRun.IsPendingAttemptKind(kind)
	return kind == "pending"
end

function CheckRun.IsPendingIncompleteReason(reason)
	return reason == "pending_link"
		or reason == "incomplete_link"
		or reason == "empty_flag_with_item_evidence"
		or reason == "missing_slot_table"
end

function CheckRun.PendingRetryDelaySeconds()
	return tonumber(CheckRun.PENDING_RETRY_SECONDS) or tonumber(CheckRun.PER_INSPECT_ACTIVE_WAIT) or 2.0
end

-- True when this attempt kind should refresh the run's no-progress clock.
-- Call before MarkAttempt so first-time pending still counts as acquisition
-- evidence. Repeated pending/link-loading must not keep the run alive forever.
function CheckRun.AttemptCountsAsProgress(kind, player)
	if not CheckRun.IsPendingAttemptKind(kind) then
		return true
	end
	-- First pending result for a never-visited player is first-time evidence.
	return type(player) == "table" and not player.inspectableAtLeastOnce
end

-- True while a reachable target has not yet received any inspect/capture attempt.
-- Serial NotifyInspect across a large group can exceed NO_PROGRESS_SECONDS; the
-- run must finish that first sweep (or hit budget) before settling on idle.
function CheckRun.InitialAcquisitionIncomplete(run)
	if type(run) ~= "table" then
		return false
	end
	for _, id in ipairs(run.targetIds or {}) do
		local player = run.players and run.players[id]
		if player
			and not player.inspectableAtLeastOnce
			and not player.leftGroup
			and player.currentlyInspectable
			and not player.rangeOnlyFailure
		then
			return true
		end
	end
	return false
end

function CheckRun.MarkAttempt(player, kind, inspectable, now)
	if type(player) ~= "table" then
		return
	end
	player.lastAttemptKind = kind
	if inspectable then
		player.inspectableAtLeastOnce = true
		player.currentlyInspectable = true
		player.wasReachable = true
	end
	if CheckRun.IsPendingAttemptKind(kind) then
		player.pendingAttemptCount = (player.pendingAttemptCount or 0) + 1
		now = tonumber(now)
		if now then
			player.nextPendingRetryAt = now + CheckRun.PendingRetryDelaySeconds()
		end
		return
	end
	player.nextPendingRetryAt = nil
	player.attemptCount = (player.attemptCount or 0) + 1
	if kind == "timeout" or kind == "incomplete" or kind == "api_failure" then
		player.technicalFailure = true
	elseif kind == "range" then
		player.rangeOnlyFailure = true
		player.currentlyInspectable = false
	end
end

function CheckRun.PlayerNeedsMoreInspects(player)
	if type(player) ~= "table" then
		return false
	end
	if player.freshObservation then
		return false
	end
	return (player.attemptCount or 0) < CheckRun.PER_TARGET_ATTEMPT_CAP
end

-- Whether acquisition may queue another inspect/capture right now.
-- Preserves the attempt cap and the pending retry gate across queue rebuilds.
-- When run is provided and the first inspect sweep is incomplete, already-visited
-- players defer so serial NotifyInspect slots finish never-visited targets first.
function CheckRun.PlayerMayQueueInspect(player, now, run)
	if not CheckRun.PlayerNeedsMoreInspects(player) then
		return false
	end
	if type(run) == "table"
		and CheckRun.InitialAcquisitionIncomplete(run)
		and type(player) == "table"
		and player.inspectableAtLeastOnce
	then
		return false
	end
	now = tonumber(now) or 0
	local gate = type(player) == "table" and tonumber(player.nextPendingRetryAt) or nil
	if gate and now < gate then
		return false
	end
	return true
end

function CheckRun.AttemptKindForIncompleteReason(reason)
	if CheckRun.IsPendingIncompleteReason(reason) then
		return "pending"
	end
	return "incomplete"
end

function CheckRun.ShouldSettle(run, now)
	if type(run) ~= "table" then
		return true, "no_run"
	end
	if CheckRun.IsPaused(run) then
		return false, "paused"
	end

	local allResolved = true
	for _, id in ipairs(run.targetIds or {}) do
		local player = run.players[id]
		-- A single timeout/incomplete sets technicalFailure for classification,
		-- but acquisition still retries until PER_TARGET_ATTEMPT_CAP.
		if not player or CheckRun.PlayerNeedsMoreInspects(player) then
			allResolved = false
			break
		end
	end
	if allResolved then
		return true, "targets_resolved"
	end

	local elapsed = run.activeElapsed or 0
	if elapsed >= (run.budgetSeconds or CheckRun.SAFETY_CEILING_SECONDS) then
		return true, "budget"
	end

	local sinceProgress = (run.activeElapsed or 0) - (run.lastProgressActiveElapsed or 0)
	if sinceProgress >= CheckRun.NO_PROGRESS_SECONDS then
		-- Do not treat an unfinished first inspect sweep as idle. Repeated
		-- pending after every reachable target has been visited still settles.
		if CheckRun.InitialAcquisitionIncomplete(run) then
			return false, "initial_acquisition"
		end
		return true, "no_progress"
	end

	return false, nil
end

local function AgeSeconds(capturedAt, now)
	if type(capturedAt) ~= "number" or type(now) ~= "number" then
		return nil
	end
	if now < capturedAt then
		return nil
	end
	return now - capturedAt
end

local function HasExpectedSession(expectedSessionId)
	return type(expectedSessionId) == "string" and expectedSessionId ~= ""
end

local function IsUnscopedLastGood(good)
	return type(good) == "table"
		and (good.sessionId == nil or good.sessionId == "")
end

-- Complete last-good observations stamped with the active Loot Helper session may
-- back a Raid Check classification when a fresh inspect cannot complete.
function CheckRun.SameSessionLastGood(good, expectedSessionId)
	return HasExpectedSession(expectedSessionId)
		and type(good) == "table"
		and good.complete == true
		and type(good.sessionId) == "string"
		and good.sessionId == expectedSessionId
end

function CheckRun.IsFreshEnoughLastGood(good, now, maxAgeSeconds)
	local age = good and AgeSeconds(good.capturedAt, now)
	maxAgeSeconds = tonumber(maxAgeSeconds)
	if age == nil or maxAgeSeconds == nil then
		return false, age
	end
	return age <= maxAgeSeconds, age
end

function CheckRun.UsableSameSessionLastGood(good, expectedSessionId, now)
	if not CheckRun.SameSessionLastGood(good, expectedSessionId) then
		return false, good and AgeSeconds(good.capturedAt, now) or nil
	end
	return CheckRun.IsFreshEnoughLastGood(good, now, CheckRun.SESSION_LAST_GOOD_SECONDS)
end

local function ClassificationFromLastGood(good, player, age, verifiedKind)
	local policy = (good and good.policy) or (player and player.policyResult)
	local prepared = policy and policy.prepared == true
	return {
		class = prepared and CheckRun.CLASS.PREPARED or CheckRun.CLASS.UNPREPARED,
		verified = verifiedKind or CheckRun.VERIFIED.RECENT,
		missing = (policy and policy.missing) or {},
		countsForPot = not prepared,
		verifiedAge = age,
	}
end

function CheckRun.ClassifyPlayer(player, now, lastGood, expectedSessionId)
	if type(player) ~= "table" then
		return {
			class = CheckRun.CLASS.INSPECTION_FAILED,
			verified = nil,
			missing = {},
		}
	end

	-- 1) Fresh complete observation from this Raid Check wins.
	if player.freshObservation and player.freshObservation.complete then
		local policy = player.policyResult or player.freshObservation.policy
		local prepared = policy and policy.prepared == true
		return {
			class = prepared and CheckRun.CLASS.PREPARED or CheckRun.CLASS.UNPREPARED,
			verified = CheckRun.VERIFIED.FRESH,
			missing = (policy and policy.missing) or {},
			countsForPot = not prepared,
		}
	end

	local good = lastGood or player.lastGood
	local age = good and AgeSeconds(good.capturedAt, now)

	-- 2) Same-session complete last-good within the session freshness bound:
	-- usable even when this run's refresh timed out, returned incomplete, or
	-- the player is now out of range. Expired same-session data falls through.
	-- A later inspect that proved contradictory reliable evidence must already
	-- have cleared this entry via member-scoped invalidation.
	local usableSameSession = CheckRun.UsableSameSessionLastGood(good, expectedSessionId, now)
	if usableSameSession then
		return ClassificationFromLastGood(good, player, age, CheckRun.VERIFIED.SESSION)
	end

	-- 3) A technical failure without a usable same-session fallback stays Inspection Failed.
	if player.technicalFailure then
		return {
			class = CheckRun.CLASS.INSPECTION_FAILED,
			verified = nil,
			missing = {},
			countsForPot = false,
		}
	end

	-- 4) Legacy recently-verified path: only truly unscoped last-good during a
	-- no-session check, within 120s, when the only obstacle is range.
	-- Prior-session observations are never reused here.
	if not HasExpectedSession(expectedSessionId)
		and IsUnscopedLastGood(good)
		and good.complete
		and age ~= nil
		and age <= CheckRun.RECENT_GOOD_SECONDS
	then
		if player.rangeOnlyFailure or not player.currentlyInspectable then
			return ClassificationFromLastGood(good, player, age, CheckRun.VERIFIED.RECENT)
		end
	end

	if not player.inspectableAtLeastOnce then
		-- Never-inspected but reachable now, or previously reachable this run
		-- (scheduling skip / range loss), must not charge Reward Pot as if the
		-- player were genuinely unavailable for the whole check.
		if player.currentlyInspectable or player.wasReachable then
			return {
				class = CheckRun.CLASS.INSPECTION_FAILED,
				verified = nil,
				missing = {},
				countsForPot = false,
			}
		end
		return {
			class = CheckRun.CLASS.UNPREPARED_AVAILABILITY,
			verified = nil,
			missing = {},
			countsForPot = true,
		}
	end

	return {
		class = CheckRun.CLASS.INSPECTION_FAILED,
		verified = nil,
		missing = {},
		countsForPot = false,
	}
end

function CheckRun.ClassifyRun(run, now, lastGoodById)
	lastGoodById = lastGoodById or {}
	local results = {}
	local expectedSessionId = run and run.expectedSessionId or nil
	for _, id in ipairs(run.targetIds or {}) do
		local player = run.players[id]
		results[id] = CheckRun.ClassifyPlayer(player, now, lastGoodById[id], expectedSessionId)
		if player then
			player.terminal = results[id].class
			player.verified = results[id].verified
		end
	end
	run.classified = true
	run.classifiedResults = results
	run.status = "classified"
	return results
end

function CheckRun.AnyUnpreparedForPot(results)
	if type(results) ~= "table" then
		return false
	end
	for _, entry in pairs(results) do
		if entry and entry.countsForPot then
			return true
		end
	end
	return false
end

function CheckRun.DecidePreflight(opts)
	opts = opts or {}
	if opts.dialogOpen or opts.runInFlight then
		return { action = "busy" }
	end
	if not opts.hasProfile then
		return { action = "error", reason = "no_profile" }
	end
	if not opts.isAdmin then
		return { action = "error", reason = "not_admin" }
	end
	if opts.sessionActive then
		local mismatch = opts.sessionProfileId ~= nil and opts.selectedProfileId ~= nil
			and opts.sessionProfileId ~= opts.selectedProfileId
		return {
			action = "start",
			warnMismatch = mismatch and true or false,
		}
	end
	return { action = "prompt" }
end

function CheckRun.ApplyDialogChoice(choice, startSessionSucceeded)
	if choice == "cancel" or choice == "escape" then
		return { action = "abort" }
	end
	if choice == "no" then
		return { action = "start", startSession = false }
	end
	if choice == "yes" then
		if startSessionSucceeded then
			return { action = "start", startSession = true }
		end
		return { action = "abort", reason = "session_start_failed" }
	end
	return { action = "abort" }
end

function CheckRun.NoteSessionStartFailed(run)
	if type(run) ~= "table" then
		return false
	end
	if run.sessionStartFailed then
		return false
	end
	run.sessionStartFailed = true
	return true
end

function CheckRun.ConsequenceSyncEligible(run, session)
	session = session or {}
	if type(run) ~= "table" then
		return false, "no_run"
	end
	if run.sessionMismatch then
		return false, "mismatch"
	end
	if run.startedSessionForCheck then
		if run.sessionStartFailed then
			return false, "announce_failed"
		end
		local expected = run.expectedSessionId
		if session.active and (not expected or session.sessionId == expected) and not session.announced then
			return false, "awaiting_announce"
		end
		if session.active and session.announced and (not expected or session.sessionId == expected) then
			if session.profileId ~= run.profileId then
				return false, "wrong_profile"
			end
			return true, "eligible"
		end
		if session.active and expected and session.sessionId ~= expected then
			return false, "session_changed"
		end
		return false, "announce_failed"
	end
	if not session.active then
		return false, "no_session"
	end
	if session.profileId ~= run.profileId then
		return false, "wrong_profile"
	end
	return true, "eligible"
end

function CheckRun.ShouldHoldConsequences(run, session)
	local eligible, reason = CheckRun.ConsequenceSyncEligible(run, session)
	if reason == "awaiting_announce" then
		return true, reason
	end
	return false, eligible and "apply" or reason
end
