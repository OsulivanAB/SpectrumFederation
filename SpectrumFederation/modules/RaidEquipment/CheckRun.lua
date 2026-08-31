-- Ad-hoc Raid Check run state: freeze, bounds, provenance, classification, inspect tokens.
local _, SF = ...

SF.RaidEquipment = SF.RaidEquipment or {}
local CheckRun = {}
SF.RaidEquipment.CheckRun = CheckRun

CheckRun.RECENT_GOOD_SECONDS = 120
CheckRun.PER_TARGET_ATTEMPT_CAP = 4
CheckRun.PER_INSPECT_ACTIVE_WAIT = 2.0
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
	RECENT = "recent",
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
		currentlyInspectable = false,
		rangeOnlyFailure = false,
		terminal = nil,
		verified = nil,
	}
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

function CheckRun.MarkAttempt(player, kind, inspectable)
	if type(player) ~= "table" then
		return
	end
	player.attemptCount = (player.attemptCount or 0) + 1
	player.lastAttemptKind = kind
	if inspectable then
		player.inspectableAtLeastOnce = true
		player.currentlyInspectable = true
	end
	if kind == "timeout" or kind == "incomplete" or kind == "api_failure" then
		player.technicalFailure = true
	elseif kind == "range" then
		player.rangeOnlyFailure = true
		player.currentlyInspectable = false
	end
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
		if not player or not player.freshObservation then
			if not player or (not player.technicalFailure and (player.attemptCount or 0) < CheckRun.PER_TARGET_ATTEMPT_CAP) then
				allResolved = false
				break
			end
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

function CheckRun.ClassifyPlayer(player, now, lastGood)
	if type(player) ~= "table" then
		return {
			class = CheckRun.CLASS.INSPECTION_FAILED,
			verified = nil,
			missing = {},
		}
	end

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

	if player.technicalFailure then
		return {
			class = CheckRun.CLASS.INSPECTION_FAILED,
			verified = nil,
			missing = {},
			countsForPot = false,
		}
	end

	local good = lastGood or player.lastGood
	local age = good and AgeSeconds(good.capturedAt, now)
	if good and good.complete and age ~= nil and age <= CheckRun.RECENT_GOOD_SECONDS then
		if player.rangeOnlyFailure or not player.currentlyInspectable then
			local policy = good.policy or player.policyResult
			local prepared = policy and policy.prepared == true
			return {
				class = prepared and CheckRun.CLASS.PREPARED or CheckRun.CLASS.UNPREPARED,
				verified = CheckRun.VERIFIED.RECENT,
				missing = (policy and policy.missing) or {},
				countsForPot = not prepared,
				verifiedAge = age,
			}
		end
	end

	if not player.inspectableAtLeastOnce then
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
	for _, id in ipairs(run.targetIds or {}) do
		local player = run.players[id]
		results[id] = CheckRun.ClassifyPlayer(player, now, lastGoodById[id])
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
