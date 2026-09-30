-- Production-Lua tests for Early Preparation whisper decisions, session dedupe, and inspect consumers.
-- Run from the repository root: lua5.1 tests/lua/early_preparation_tests.lua

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
assert(loadfile("SpectrumFederation/modules/Settings/Schema.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/RaidEquipment/EarlyPreparation.lua"))("SpectrumFederation", SF)

local EarlyPrep = SF.RaidEquipment.EarlyPreparation
local openCtx = {
	settingEnabled = true,
	sessionActive = true,
	announced = true,
	isCoordinator = true,
	isEffectiveAdmin = true,
	profileReady = true,
	groupIsRaid = true,
	raidCheckBegun = false,
	eligible = true,
	inRaid = true,
	fresh = true,
	complete = true,
	prepared = false,
	alreadyWarned = false,
}

assertEq(SF.SettingsSchema.DEFAULTS.lootHelper.earlyPreparationWhispers, true, "schema default is enabled")
assertTrue(EarlyPrep.IsSettingEnabled(nil), "missing saved value is enabled")
assertTrue(EarlyPrep.IsSettingEnabled(true), "explicit true stays enabled")
assertTrue(not EarlyPrep.IsSettingEnabled(false), "explicit false stays disabled")

local open, why = EarlyPrep.WindowOpen(openCtx)
assertTrue(open, "window is open for an announced coordinator")
assertEq(why, "open", "open window reason")

local closed = {}
for key, value in pairs(openCtx) do
	closed[key] = value
end
closed.announced = false
open, why = EarlyPrep.WindowOpen(closed)
assertTrue(not open, "unannounced session does not open the window")
assertEq(why, "announced", "unannounced reason")

closed.announced = true
closed.isCoordinator = false
open, why = EarlyPrep.WindowOpen(closed)
assertTrue(not open, "non-coordinator does not scan")
assertEq(why, "coordinator", "coordinator reason")

closed.isCoordinator = true
closed.settingEnabled = false
assertTrue(not EarlyPrep.WindowOpen(closed), "disabled setting keeps the window closed")

closed.settingEnabled = true
closed.groupIsRaid = false
open, why = EarlyPrep.WindowOpen(closed)
assertTrue(not open, "a party does not open early preparation")
assertEq(why, "party", "party reason")
closed.groupIsRaid = true

closed.settingEnabled = true
closed.isEffectiveAdmin = false
open, why = EarlyPrep.WindowOpen(closed)
assertTrue(not open, "preview or lost admin fails closed")
assertEq(why, "admin", "admin reason")

closed.isEffectiveAdmin = true
closed.raidCheckBegun = true
closed.inCombat = true
open, why = EarlyPrep.WindowOpen(closed)
assertTrue(not open, "raid check begun closes the window")
assertEq(why, "raid_check", "raid check reason")

local combatOpen = {}
for key, value in pairs(openCtx) do
	combatOpen[key] = value
end
combatOpen.inCombat = true
assertTrue(EarlyPrep.WindowOpen(combatOpen), "combat does not close the window")

local send, sendWhy = EarlyPrep.ShouldWarn(openCtx)
assertTrue(send, "complete unprepared observation may whisper")
assertEq(sendWhy, "send", "send reason")

local prepared = {}
for key, value in pairs(openCtx) do
	prepared[key] = value
end
prepared.prepared = true
send, sendWhy = EarlyPrep.ShouldWarn(prepared)
assertTrue(not send, "prepared observation does not whisper")
assertEq(sendWhy, "prepared", "prepared reason")

local incomplete = {}
for key, value in pairs(openCtx) do
	incomplete[key] = value
end
incomplete.complete = false
send, sendWhy = EarlyPrep.ShouldWarn(incomplete)
assertTrue(not send, "incomplete observation does not whisper")
assertEq(sendWhy, "incomplete", "incomplete reason")

local stale = {}
for key, value in pairs(openCtx) do
	stale[key] = value
end
stale.fresh = false
send, sendWhy = EarlyPrep.ShouldWarn(stale)
assertTrue(not send, "stale observation does not whisper")
assertEq(sendWhy, "stale", "stale reason")

local noticed = EarlyPrep.NewNotice()
assertTrue(EarlyPrep.BindNotice(noticed, "session-a", "profile-a"), "first bind adopts the session")
assertTrue(EarlyPrep.MarkWarned(noticed, "Bob-Realm"), "first unprepared result is recorded")
assertTrue(EarlyPrep.IsWarned(noticed, "Bob-Realm"), "recorded member is warned")
assertTrue(not EarlyPrep.MarkWarned(noticed, "Bob-Realm"), "second unprepared result does not record again")

local later = {}
for key, value in pairs(openCtx) do
	later[key] = value
end
later.alreadyWarned = true
assertTrue(not EarlyPrep.ShouldWarn(later), "already warned member is not whispered again")

assertTrue(not EarlyPrep.BindNotice(noticed, "session-a", "profile-a"), "same session keeps warning state")
assertTrue(EarlyPrep.IsWarned(noticed, "Bob-Realm"), "coordinator change on the same session keeps warnings")
assertTrue(EarlyPrep.BindNotice(noticed, "session-b", "profile-a"), "new session id resets warnings")
assertTrue(not EarlyPrep.IsWarned(noticed, "Bob-Realm"), "new session can warn again")

local dedupe = EarlyPrep.NewNotice()
EarlyPrep.BindNotice(dedupe, "session-a", "profile-a")
local accepted, changed = EarlyPrep.ApplyNotice(dedupe, "session-a", "profile-a", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Bob-Realm",
})
assertTrue(accepted and changed, "authorized matching notice records Bob")
accepted, changed = EarlyPrep.ApplyNotice(dedupe, "session-a", "profile-a", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Bob-Realm",
	raidCheckBegun = false,
})
assertTrue(accepted and not changed, "duplicate and false raid-begun notice are harmless")
accepted, changed = EarlyPrep.ApplyNotice(dedupe, "session-a", "profile-a", {
	sessionId = "session-old",
	profileId = "profile-a",
	memberId = "Cara-Realm",
})
assertTrue(not accepted and not changed, "stale session notice is ignored")
assertTrue(not EarlyPrep.IsWarned(dedupe, "Cara-Realm"), "stale notice did not warn Cara")
accepted, changed = EarlyPrep.ApplyNotice(dedupe, "session-a", "profile-a", {
	sessionId = "session-a",
	profileId = "profile-a",
	warned = { "Cara-Realm", "Bob-Realm" },
	raidCheckBegun = true,
})
assertTrue(accepted and changed, "snapshot adds Cara and raid check begun")
assertTrue(EarlyPrep.IsWarned(dedupe, "Cara-Realm"), "snapshot warned Cara")
assertTrue(dedupe.raidCheckBegun, "raid check begun sticks")
accepted, changed = EarlyPrep.ApplyNotice(dedupe, "session-a", "profile-a", {
	sessionId = "session-a",
	profileId = "profile-a",
	raidCheckBegun = false,
	warned = {},
})
assertTrue(accepted and not changed, "later empty snapshot does not clear warnings or raid check")
assertTrue(dedupe.raidCheckBegun, "raid check begun stays set")
assertTrue(EarlyPrep.IsWarned(dedupe, "Bob-Realm"), "empty snapshot does not unwarn Bob")

assertTrue(not EarlyPrep.ShouldNoteRaidCheckBegun("pre", { expectedSessionId = "session-a" }), "pre-raid check does not stop early preparation")
assertTrue(not EarlyPrep.ShouldNoteRaidCheckBegun("raid", { sessionMismatch = true, expectedSessionId = "session-a" }), "mismatched raid check does not stop the session")
assertTrue(not EarlyPrep.ShouldNoteRaidCheckBegun("raid", {}), "raid check without a session id does not stop early preparation")
assertTrue(EarlyPrep.ShouldNoteRaidCheckBegun("raid", { expectedSessionId = "session-a" }), "matching raid check start stops early preparation")

local session = { active = true, announced = true, sessionId = "session-a", profileId = "profile-a" }
local matchingRun = { expectedSessionId = "session-a", expectedSessionProfileId = "profile-a" }
assertTrue(EarlyPrep.SessionDedupeApplies(matchingRun, session), "matching announced session uses session dedupe")
local quiet = { active = false, announced = false, sessionId = nil }
assertTrue(not EarlyPrep.SessionDedupeApplies(matchingRun, quiet), "no session keeps the day-based fallback")
assertTrue(not EarlyPrep.SessionDedupeApplies({ expectedSessionId = "session-a", sessionMismatch = true }, session), "mismatched run does not use this session's dedupe")

assertEq(EarlyPrep.MissingWhisperAction({
	whispersEnabled = true,
	sessionDedupe = true,
	alreadyWarned = true,
	alreadyToday = false,
}), "session_contacted", "session dedupe suppresses a second missing whisper")
assertEq(EarlyPrep.MissingWhisperAction({
	whispersEnabled = true,
	sessionDedupe = true,
	alreadyWarned = false,
	alreadyToday = true,
}), "send", "a new session warning is not blocked by an older same-day whisper")
assertEq(EarlyPrep.MissingWhisperAction({
	whispersEnabled = true,
	sessionDedupe = false,
	alreadyWarned = false,
	alreadyToday = true,
}), "today", "no-session checks keep the calendar-day fallback")
assertTrue(not EarlyPrep.PreparedWhisperSuppressedByMissingWarning(true), "prepared whispers stay independent")

local consumers = {}
local any = false
for _ = 1, 100 do
	consumers, any = EarlyPrep.MutateConsumers(consumers, "equipment page", true, {})
	consumers, any = EarlyPrep.MutateConsumers(consumers, "early_preparation", true, {
		filter = function()
			return false
		end,
	})
	consumers, any = EarlyPrep.MutateConsumers(consumers, "equipment page", false)
end
local count = 0
for _ in pairs(consumers) do
	count = count + 1
end
assertEq(count, 1, "repeated enable and disable leaves one consumer")
assertTrue(any, "early preparation consumer still requires inspection")
assertTrue(not EarlyPrep.ConsumerWantsUnit(consumers, { id = "Eve-Realm" }), "filtered consumer skips non-matching units")
consumers, any = EarlyPrep.MutateConsumers(consumers, "equipment page", true, {})
assertTrue(EarlyPrep.ConsumerWantsUnit(consumers, { id = "Eve-Realm" }), "equipment page consumer still inspects the whole group")
consumers, any = EarlyPrep.MutateConsumers(consumers, "equipment page", false)
consumers, any = EarlyPrep.MutateConsumers(consumers, "early_preparation", false)
assertTrue(not any, "disabling the last consumer stops shared inspection")
assertEq(next(consumers), nil, "consumer map is empty after the last disable")

SF.LootHelperSync = {
	state = { active = true, sessionId = "session-a", profileId = "profile-a", isCoordinator = false },
	IsSessionActive = function()
		return true
	end,
	GetSessionId = function()
		return "session-a"
	end,
	GetSessionProfileId = function()
		return "profile-a"
	end,
	HasAnnouncedCurrentSession = function()
		return true
	end,
	IsSenderAuthorized = function(_, profileId, sender)
		return profileId == "profile-a" and sender == "Admin-Realm"
	end,
	IsRequesterInGroup = function(_, sender)
		return sender == "Admin-Realm" or sender == "Helper-Realm"
	end,
	FindLocalProfileById = function()
		return { id = "profile-a" }
	end,
}
EarlyPrep.notice = EarlyPrep.NewNotice()
EarlyPrep:HandlePrepNotice("Stranger-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Bob-Realm",
})
assertTrue(not EarlyPrep:WasWarned("Bob-Realm"), "unauthorized sender cannot mark a warning")
assertEq(EarlyPrep._deferredNotices, nil, "a known non-admin notice is not deferred")
EarlyPrep:HandlePrepNotice("Admin-Realm", {
	sessionId = "other-session",
	profileId = "profile-a",
	memberId = "Bob-Realm",
})
assertTrue(not EarlyPrep:WasWarned("Bob-Realm"), "wrong session notice is ignored")
EarlyPrep:HandlePrepNotice("Admin-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Bob-Realm",
})
assertTrue(EarlyPrep:WasWarned("Bob-Realm"), "authorized admin notice marks Bob")
EarlyPrep:HandlePrepNotice("Admin-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Bob-Realm",
})
assertTrue(EarlyPrep:WasWarned("Bob-Realm"), "duplicate authorized notice stays marked once")
EarlyPrep.notice = EarlyPrep.NewNotice()
EarlyPrep.notice.sessionId = "session-a"
EarlyPrep.notice.profileId = "profile-a"
SF.LootHelperSync.IsRequesterInGroup = function(_, sender)
	return sender == "Admin-Realm"
end
SF.LootHelperSync.IsSenderAuthorized = function(_, profileId, sender)
	return profileId == "profile-a" and sender == "LeftAdmin-Realm"
end
EarlyPrep:HandlePrepNotice("LeftAdmin-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Bob-Realm",
	raidCheckBegun = true,
})
assertTrue(not EarlyPrep:WasWarned("Bob-Realm"), "an out-of-group admin cannot mark a warning")
assertTrue(EarlyPrep.notice.raidCheckBegun ~= true, "an out-of-group admin cannot set raid check begun")
assertEq(EarlyPrep._deferredNotices, nil, "an out-of-group admin notice is not deferred")
assertTrue(not EarlyPrep:AcceptRemotePrepNotice("LeftAdmin-Realm", "session-a", "profile-a", {
	warned = { "Bob-Realm" },
	raidCheckBegun = true,
}), "an out-of-group admin snapshot is rejected")
SF.LootHelperSync.IsSenderAuthorized = function(_, profileId, sender)
	return profileId == "profile-a" and sender == "Admin-Realm"
end
SF.LootHelperSync.IsRequesterInGroup = function(_, sender)
	return sender == "Admin-Realm" or sender == "Helper-Realm"
end

local refreshes = 0
SF.RaidCheck = {
	SetBackgroundInspectEnabled = function()
		refreshes = refreshes + 1
	end,
}
SF.SettingsStore = {
	Get = function()
		return false
	end,
}
for _ = 1, 50 do
	EarlyPrep:Refresh("test")
end
assertTrue(refreshes <= 50, "inactive refresh stays bounded")
assertTrue(not EarlyPrep._windowOpen, "disabled setting leaves the window closed")

local shownId = EarlyPrep.ConsumerId("equipment page shown", { consumerId = "equipment page" })
local hiddenId = EarlyPrep.ConsumerId("equipment page hidden", { consumerId = "equipment page" })
assertEq(shownId, "equipment page", "show uses the stable equipment consumer")
assertEq(hiddenId, shownId, "hide uses the same equipment consumer")
local pageConsumers = {}
pageConsumers = EarlyPrep.MutateConsumers(pageConsumers, shownId, true, {})
pageConsumers = EarlyPrep.MutateConsumers(pageConsumers, EarlyPrep.ConsumerId("auto refresh toggle", { consumerId = "equipment page" }), true, {})
local pageCount = 0
for _ in pairs(pageConsumers) do
	pageCount = pageCount + 1
end
assertEq(pageCount, 1, "diagnostic reasons do not create extra equipment consumers")
pageConsumers = EarlyPrep.MutateConsumers(pageConsumers, hiddenId, false)
assertEq(next(pageConsumers), nil, "hiding the equipment page removes its consumer")

assertTrue(not EarlyPrep.SessionAnnouncedForDedupe(true, false, true, "session-a"), "unannounced coordinator does not use session dedupe")
assertTrue(EarlyPrep.SessionAnnouncedForDedupe(true, false, false, "session-a"), "a joined client uses session dedupe")
assertTrue(EarlyPrep.SessionAnnouncedForDedupe(true, true, true, "session-a"), "an announced coordinator uses session dedupe")
assertTrue(not EarlyPrep.SessionAnnouncedForDedupe(false, false, false, "session-a"), "an inactive session does not use session dedupe")

EarlyPrep.notice = EarlyPrep.NewNotice()
EarlyPrep.notice.sessionId = "session-a"
EarlyPrep.notice.profileId = "profile-a"
EarlyPrep.MarkWarned(EarlyPrep.notice, "Bob-Realm")
EarlyPrep.notice.raidCheckBegun = true
local reannounce = { sessionId = "session-a", profileId = "profile-a" }
EarlyPrep:AttachToPayload(reannounce)
assertTrue(type(reannounce.prepNotice) == "table", "reannounce payload includes the preparation snapshot")
assertEq(reannounce.prepNotice.warned[1], "Bob-Realm", "reannounce snapshot includes Bob")
assertTrue(reannounce.prepNotice.raidCheckBegun == true, "reannounce snapshot includes raid check begun")

local sessionStart = { sessionId = "session-a", profileId = "profile-a" }
EarlyPrep.notice = EarlyPrep.NewNotice()
EarlyPrep.notice.sessionId = "session-a"
EarlyPrep.notice.profileId = "profile-a"
EarlyPrep.notice.raidCheckBegun = true
EarlyPrep:AttachToPayload(sessionStart)
assertTrue(sessionStart.prepNotice and sessionStart.prepNotice.raidCheckBegun == true, "session start payload includes raid check begun")
EarlyPrep.notice = EarlyPrep.NewNotice()
EarlyPrep:ApplyHeartbeat("session-a", "profile-a", sessionStart.prepNotice)
assertTrue(EarlyPrep.notice.raidCheckBegun == true, "a received session start records raid check begun")

EarlyPrep.notice = EarlyPrep.NewNotice()
EarlyPrep:ApplyHeartbeat("session-a", "profile-a", reannounce.prepNotice)
assertTrue(EarlyPrep:WasWarned("Bob-Realm"), "a received reannounce records Bob")
assertTrue(EarlyPrep.notice.raidCheckBegun == true, "a received reannounce records raid check begun")

local fullNotice = EarlyPrep.NewNotice()
fullNotice.sessionId = "session-a"
fullNotice.profileId = "profile-a"
local recorded = 0
for i = 1, EarlyPrep.MAX_NOTICE_MEMBERS do
	if EarlyPrep.MarkWarned(fullNotice, string.format("Member%02d-Realm", i)) then
		recorded = recorded + 1
	end
end
assertEq(recorded, EarlyPrep.MAX_NOTICE_MEMBERS, "warnings fit under the cap")
assertTrue(not EarlyPrep.WarningRecordable(fullNotice, "Extra-Realm"), "a full warning list cannot record another player")
assertTrue(not EarlyPrep.MarkWarned(fullNotice, "Extra-Realm"), "the cap rejects another warning")
assertTrue(EarlyPrep.IsWarned(fullNotice, "Member01-Realm"), "the cap does not drop an existing warning")

assertEq(EarlyPrep.PrepNoticeSenderState(false, false), "defer", "a missing profile defers the snapshot")
assertEq(EarlyPrep.PrepNoticeSenderState(true, true), "apply", "an authorized sender applies the snapshot")
assertEq(EarlyPrep.PrepNoticeSenderState(true, false), "reject", "a known non-admin is rejected")
assertTrue(not EarlyPrep.ObservationAuthoritative({ blended = true }), "a blended inspect is not authoritative")
assertTrue(EarlyPrep.ObservationAuthoritative({ status = "ready" }), "an unblended inspect stays authoritative")

EarlyPrep._deferredNotices = nil
EarlyPrep.notice = EarlyPrep.NewNotice()
SF.LootHelperSync.FindLocalProfileById = function()
	return nil
end
SF.LootHelperSync.IsSenderAuthorized = function()
	return false
end
EarlyPrep:AcceptRemotePrepNotice("Admin-Realm", "session-a", "profile-a", {
	warned = { "Bob-Realm" },
	raidCheckBegun = true,
})
assertTrue(not EarlyPrep:WasWarned("Bob-Realm"), "a deferred snapshot is not applied before the profile exists")
SF.LootHelperSync.FindLocalProfileById = function()
	return { id = "profile-a" }
end
SF.LootHelperSync.IsSenderAuthorized = function()
	return true
end
assertTrue(EarlyPrep:FlushDeferredPrepNotice(), "the deferred snapshot applies once the sender is authorized")
assertTrue(EarlyPrep:WasWarned("Bob-Realm"), "the applied snapshot records Bob")
assertTrue(EarlyPrep.notice.raidCheckBegun == true, "the applied snapshot keeps raid check begun")

EarlyPrep._deferredNotices = nil
EarlyPrep.notice = EarlyPrep.NewNotice()
SF.LootHelperSync.FindLocalProfileById = function()
	return nil
end
SF.LootHelperSync.IsSenderAuthorized = function()
	return false
end
EarlyPrep:HandlePrepNotice("Admin-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Cara-Realm",
	raidCheckBegun = true,
})
assertTrue(not EarlyPrep:WasWarned("Cara-Realm"), "a direct notice is not applied before the profile exists")
SF.LootHelperSync.FindLocalProfileById = function()
	return { id = "profile-a" }
end
SF.LootHelperSync.IsSenderAuthorized = function(_, _, sender)
	return sender == "Admin-Realm"
end
assertTrue(EarlyPrep:FlushDeferredPrepNotice(), "a deferred direct notice applies after import")
assertTrue(EarlyPrep:WasWarned("Cara-Realm"), "the deferred direct notice records Cara")

EarlyPrep._deferredNotices = nil
EarlyPrep.notice = EarlyPrep.NewNotice()
SF.LootHelperSync.FindLocalProfileById = function()
	return nil
end
EarlyPrep:AcceptRemotePrepNotice("Stranger-Realm", "session-a", "profile-a", {
	warned = { "Bob-Realm" },
	raidCheckBegun = true,
})
EarlyPrep:HandlePrepNotice("Admin-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Cara-Realm",
})
assertTrue(not EarlyPrep:WasWarned("Bob-Realm"), "a forged deferred warning stays unapplied")
assertTrue(not EarlyPrep:WasWarned("Cara-Realm"), "an authorized deferred warning stays unapplied until import")
SF.LootHelperSync.FindLocalProfileById = function()
	return { id = "profile-a" }
end
SF.LootHelperSync.IsSenderAuthorized = function(_, _, sender)
	return sender == "Admin-Realm"
end
assertTrue(EarlyPrep:FlushDeferredPrepNotice(), "flush applies only the authorized sender")
assertTrue(EarlyPrep:WasWarned("Cara-Realm"), "the authorized sender's warning is applied")
assertTrue(not EarlyPrep:WasWarned("Bob-Realm"), "a non-admin warning is not applied with the authorized sender")
assertTrue(EarlyPrep.notice.raidCheckBegun ~= true, "a non-admin raid-check flag is not applied with the authorized sender")
assertEq(EarlyPrep._deferredNotices, nil, "flush drops every deferred sender")

EarlyPrep._deferredNotices = nil
EarlyPrep.notice = EarlyPrep.NewNotice()
SF.LootHelperSync.FindLocalProfileById = function()
	return nil
end
EarlyPrep:HandlePrepNotice("Admin-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Cara-Realm",
})
EarlyPrep:AcceptRemotePrepNotice("Stranger-Realm", "session-a", "profile-a", {
	warned = { "Bob-Realm" },
	raidCheckBegun = true,
})
SF.LootHelperSync.FindLocalProfileById = function()
	return { id = "profile-a" }
end
SF.LootHelperSync.IsSenderAuthorized = function(_, _, sender)
	return sender == "Admin-Realm"
end
assertTrue(EarlyPrep:FlushDeferredPrepNotice(), "a later forged notice does not replace the authorized sender")
assertTrue(EarlyPrep:WasWarned("Cara-Realm"), "the earlier authorized warning still applies")
assertTrue(not EarlyPrep:WasWarned("Bob-Realm"), "the later forged warning stays dropped")
assertTrue(EarlyPrep.notice.raidCheckBegun ~= true, "the later forged raid-check flag stays dropped")

EarlyPrep._deferredNotices = nil
EarlyPrep.notice = EarlyPrep.NewNotice()
SF.LootHelperSync.FindLocalProfileById = function()
	return nil
end
assertTrue(EarlyPrep:DeferPrepNotice("session-a", "profile-a", "Admin-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	warned = { "Bob-Realm" },
}), "the first notice from a sender is deferred")
assertTrue(EarlyPrep:DeferPrepNotice("session-a", "profile-a", "Admin-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	raidCheckBegun = true,
}), "a later notice from the same sender stays on that sender")
SF.LootHelperSync.FindLocalProfileById = function()
	return { id = "profile-a" }
end
SF.LootHelperSync.IsSenderAuthorized = function(_, _, sender)
	return sender == "Admin-Realm"
end
assertTrue(EarlyPrep:FlushDeferredPrepNotice(), "one authorized sender's own notices merge")
assertTrue(EarlyPrep:WasWarned("Bob-Realm"), "the sender's earlier warning is kept")
assertTrue(EarlyPrep.notice.raidCheckBegun == true, "the sender's later raid-check flag is kept")

EarlyPrep._deferredNotices = nil
SF.LootHelperSync.FindLocalProfileById = function()
	return nil
end
local storedSenders = 0
for i = 1, EarlyPrep.MAX_DEFERRED_SENDERS do
	if EarlyPrep:DeferPrepNotice("session-a", "profile-a", string.format("Sender%02d-Realm", i), {
		sessionId = "session-a",
		profileId = "profile-a",
		memberId = "Bob-Realm",
	}) then
		storedSenders = storedSenders + 1
	end
end
assertEq(storedSenders, EarlyPrep.MAX_DEFERRED_SENDERS, "deferred senders fit under the cap")
assertTrue(not EarlyPrep:DeferPrepNotice("session-a", "profile-a", "Overflow-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Cara-Realm",
}), "a new sender is rejected once the deferred map is full")
assertTrue(EarlyPrep:DeferPrepNotice("session-a", "profile-a", "Sender01-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	raidCheckBegun = true,
}), "an existing sender can still update after the cap")
assertTrue(not EarlyPrep:DeferPrepNotice("session-a", "profile-a", "", {
	sessionId = "session-a",
	profileId = "profile-a",
	memberId = "Cara-Realm",
}), "a notice with no sender is not deferred")

EarlyPrep._deferredNotices = nil
EarlyPrep.notice = EarlyPrep.NewNotice()
SF.LootHelperSync.FindLocalProfileById = function()
	return nil
end
assertTrue(EarlyPrep:DeferPrepNotice("session-a", "profile-a", "Admin-Realm", {
	sessionId = "session-a",
	profileId = "profile-a",
	warned = { "Bob-Realm" },
	raidCheckBegun = true,
}), "a deferred notice is retained for persistence")
local persisted = {
	sessionId = "session-a",
	profileId = "profile-a",
}
EarlyPrep:WritePersisted(persisted)
assertTrue(type(persisted.deferredPrepNotices) == "table", "deferred notices are written to the session record")
assertTrue(type(persisted.deferredPrepNotices.bySender["Admin-Realm"]) == "table", "deferred persistence keeps the sender")
assertEq(persisted.deferredPrepNotices.bySender["Admin-Realm"].warned[1], "Bob-Realm", "deferred persistence keeps Bob")
assertTrue(persisted.deferredPrepNotices.bySender["Admin-Realm"].raidCheckBegun == true, "deferred persistence keeps raid check begun")
EarlyPrep._deferredNotices = nil
EarlyPrep.notice = EarlyPrep.NewNotice()
EarlyPrep:RestorePersisted(persisted)
assertTrue(type(EarlyPrep._deferredNotices) == "table", "restore rebuilds deferred notices")
assertTrue(type(EarlyPrep._deferredNotices.bySender["Admin-Realm"]) == "table", "restore keeps the deferred sender")
SF.LootHelperSync.FindLocalProfileById = function()
	return { id = "profile-a" }
end
SF.LootHelperSync.IsSenderAuthorized = function(_, _, sender)
	return sender == "Admin-Realm"
end
assertTrue(EarlyPrep:FlushDeferredPrepNotice(), "a restored deferred notice applies after import")
assertTrue(EarlyPrep:WasWarned("Bob-Realm"), "the restored deferred notice records Bob")
assertTrue(EarlyPrep.notice.raidCheckBegun == true, "the restored deferred notice keeps raid check begun")

local coverLocal = EarlyPrep.NewNotice()
coverLocal.sessionId = "session-a"
coverLocal.profileId = "profile-a"
EarlyPrep.MarkWarned(coverLocal, "Bob-Realm")
coverLocal.raidCheckBegun = true
assertTrue(EarlyPrep.RemoteCoversLocal(coverLocal, {
	warned = { "Bob-Realm", "Cara-Realm" },
	raidCheckBegun = true,
}), "a covering remote snapshot matches local state")
assertTrue(not EarlyPrep.RemoteCoversLocal(coverLocal, {
	warned = { "Bob-Realm" },
	raidCheckBegun = false,
}), "a remote snapshot without raid check begun does not cover local")
assertTrue(not EarlyPrep.RemoteCoversLocal(coverLocal, {
	warned = { "Cara-Realm" },
	raidCheckBegun = true,
}), "a remote snapshot missing a warned member does not cover local")

local sentKinds = {}
SF.LootHelperComm = {
	Send = function(_, _, msgType, payload)
		sentKinds[#sentKinds + 1] = {
			msgType = msgType,
			kind = payload and payload.kind,
		}
		return true
	end,
}
SF.LootHelperSync.MSG = { PREP_NOTICE = "PREP_NOTICE" }
SF.LootHelperSync.GetGroupDistribution = function()
	return "RAID"
end
SF.LootHelperSync._SelfId = function()
	return "Helper-Realm"
end
SF.LootHelperSync.IsSenderAuthorized = function(_, profileId, sender)
	return profileId == "profile-a" and (sender == "Admin-Realm" or sender == "Helper-Realm")
end
SF.LootHelperSync.state.isCoordinator = false
SF.LootHelperSync.state.coordinator = "Admin-Realm"
EarlyPrep.notice = EarlyPrep.NewNotice()
EarlyPrep.notice.sessionId = "session-a"
EarlyPrep.notice.profileId = "profile-a"
EarlyPrep:ClearOutboundPending()
assertTrue(EarlyPrep:CommitWarned("Bob-Realm", "pre"), "a non-coordinator warning records Bob")
assertTrue(EarlyPrep._outboundPending == true, "a non-coordinator warning stays pending until covered")
sentKinds = {}
EarlyPrep:RetryOutboundNotice("heartbeat")
assertEq(#sentKinds, 1, "a pending non-coordinator notice retries once")
assertEq(sentKinds[1].kind, "snapshot", "the outbound retry publishes a snapshot")
EarlyPrep:ObserveRemoteCoverage({
	warned = { "Cara-Realm" },
	raidCheckBegun = false,
}, "Admin-Realm")
assertTrue(EarlyPrep._outboundPending == true, "a coordinator heartbeat missing Bob keeps outbound pending")
assertTrue(EarlyPrep:NoteRaidCheckBegun("session-a", "profile-a"), "a non-coordinator can note raid check begun")
assertTrue(EarlyPrep._outboundPending == true, "raid check begun stays pending until covered")
EarlyPrep:ObserveRemoteCoverage({
	warned = { "Bob-Realm" },
	raidCheckBegun = true,
}, "Helper-Realm")
assertTrue(EarlyPrep._outboundPending == true, "a covering peer-admin notice does not clear outbound pending")
EarlyPrep:ObserveRemoteCoverage({
	warned = { "Bob-Realm" },
	raidCheckBegun = false,
}, "Admin-Realm")
assertTrue(EarlyPrep._outboundPending == true, "a partial coordinator heartbeat keeps the outbound pending")
EarlyPrep:ObserveRemoteCoverage({
	warned = { "Bob-Realm" },
	raidCheckBegun = true,
}, "Admin-Realm")
assertTrue(not EarlyPrep._outboundPending, "a covering coordinator snapshot clears outbound pending")

EarlyPrep.notice = EarlyPrep.NewNotice()
EarlyPrep.notice.sessionId = "session-a"
EarlyPrep.notice.profileId = "profile-a"
EarlyPrep:ClearOutboundPending()
assertTrue(EarlyPrep:CommitWarned("Bob-Realm", "burst"), "a burst warning records Bob")
sentKinds = {}
for _ = 1, EarlyPrep.MAX_OUTBOUND_BURST do
	EarlyPrep:RetryOutboundNotice("heartbeat")
end
assertEq(#sentKinds, EarlyPrep.MAX_OUTBOUND_BURST, "the initial burst retries every heartbeat")
sentKinds = {}
for _ = 1, EarlyPrep.OUTBOUND_BACKOFF_HEARTBEATS - 1 do
	EarlyPrep:RetryOutboundNotice("heartbeat")
end
assertEq(#sentKinds, 0, "backoff skips heartbeats after the burst")
EarlyPrep:RetryOutboundNotice("heartbeat")
assertEq(#sentKinds, 1, "backoff still publishes after the interval")
assertTrue(EarlyPrep._outboundPending == true, "backoff keeps the publish obligation until covered")

SF.LootHelperSync.state.isCoordinator = false
EarlyPrep:ClearOutboundPending()
EarlyPrep.notice = EarlyPrep.NewNotice()
local restoreNotice = {
	sessionId = "session-a",
	profileId = "profile-a",
	prepNotice = {
		sessionId = "session-a",
		profileId = "profile-a",
		warned = { "Bob-Realm" },
		raidCheckBegun = true,
	},
}
EarlyPrep:RestorePersisted(restoreNotice)
assertTrue(EarlyPrep:WasWarned("Bob-Realm"), "restore rebuilds the warned set")
assertTrue(EarlyPrep.notice.raidCheckBegun == true, "restore rebuilds raid check begun")
assertTrue(EarlyPrep._outboundPending == true, "restore keeps non-coordinator publication pending")
SF.LootHelperSync.state.isCoordinator = true
EarlyPrep:ClearOutboundPending()
EarlyPrep.notice = EarlyPrep.NewNotice()
EarlyPrep:RestorePersisted(restoreNotice)
assertTrue(EarlyPrep:WasWarned("Bob-Realm"), "coordinator restore still rebuilds the warned set")
assertTrue(not EarlyPrep._outboundPending, "a restored coordinator does not keep outbound pending")
SF.LootHelperSync.state.isCoordinator = false
EarlyPrep._skipStamp = { ["Bob-Realm"] = "remote|1|ready|1|0|0|cfg" }
assertTrue(EarlyPrep:InvalidateObservationSkips("tooltip"), "observation skips can be cleared")
assertEq(EarlyPrep._skipStamp, nil, "invalidate clears every observation skip")
assertTrue(not EarlyPrep:InvalidateObservationSkips("tooltip"), "a second invalidate is a no-op")

IsInRaid = function()
	return true
end
SF.LootHelperSync.state.isCoordinator = true
SF.LootHelperSync.HasAnnouncedCurrentSession = function()
	return true
end
SF.SettingsStore = {
	Get = function()
		return true
	end,
}
local prepCalls = 0
local scans = 0
local whispers = 0
local observationStamp = "remote|1|ready|1|0|cfg"
SF.RaidCheck = {
	SetBackgroundInspectEnabled = function() end,
	CollectGroupMemberIds = function()
		scans = scans + 1
		return { "Bob-Realm", "Cara-Realm" }
	end,
	IsGroupMember = function()
		scans = scans + 100
		return true
	end,
	GetPreparationObservationStamp = function()
		return observationStamp
	end,
	GetAuthoritativePreparation = function()
		prepCalls = prepCalls + 1
		return { complete = true, prepared = true, missing = {} }, "fresh"
	end,
	DeliverMissingRequirementsWhisper = function()
		whispers = whispers + 1
		return false
	end,
}
SF.LootHelperSync.FindLocalProfileById = function()
	return {
		id = "profile-a",
		IsCurrentUserAdmin = function()
			return true
		end,
		GetMemberByID = function(_, memberId)
			if memberId == "Bob-Realm" or memberId == "Cara-Realm" then
				return { id = memberId }
			end
			return nil
		end,
		GetRaidCheckConfig = function()
			return { checkGemsInSockets = true, slots = { head = true } }
		end,
	}
end
EarlyPrep:OnSessionReset("test-reset")
scans = 0
prepCalls = 0
EarlyPrep:Refresh("setting")
assertEq(scans, 1, "opening the window scans the roster once")
assertEq(prepCalls, 2, "the first pass evaluates each eligible member")
prepCalls = 0
scans = 0
for _ = 1, 20 do
	EarlyPrep:OnBackgroundPass()
end
assertEq(prepCalls, 0, "twenty unchanged passes do not rebuild policy")
assertEq(scans, 20, "each later pass scans the roster once")
observationStamp = "remote|2|ready|1|0|cfg"
SF.RaidCheck.GetAuthoritativePreparation = function()
	prepCalls = prepCalls + 1
	return { complete = true, prepared = false, missing = { "gem" } }, "fresh"
end
prepCalls = 0
whispers = 0
EarlyPrep:OnBackgroundPass()
assertEq(prepCalls, 2, "a changed observation is evaluated")
assertEq(whispers, 2, "a blocked whisper is still attempted")
assertTrue(not EarlyPrep:WasWarned("Bob-Realm"), "a blocked whisper is not recorded")
prepCalls = 0
whispers = 0
EarlyPrep:OnBackgroundPass()
assertEq(prepCalls, 2, "a blocked whisper is evaluated again")
assertEq(whispers, 2, "a blocked whisper is retried")
scans = 0
EarlyPrep:Refresh("heartbeat")
EarlyPrep:Refresh("roster")
assertEq(scans, 0, "heartbeat and roster refreshes do not scan an open window")
EarlyPrep._windowOpen = false
scans = 0
EarlyPrep:Refresh("roster")
assertEq(scans, 1, "a roster refresh scans when the window has just opened")

local SyncSF = {}
assert(loadfile("SpectrumFederation/modules/LootHelperSync/09_AdminConvergence.lua"))("SpectrumFederation", SyncSF)
local RetrySync = SyncSF.LootHelperSync
assertEq(RetrySync.ReannounceRetryDecision(true, true, "session-a", nil, 0, false, 3), "schedule", "a failed reannounce can retry")
assertEq(RetrySync.ReannounceRetryDecision(true, true, "session-a", nil, 0, true, 3), "wait", "a pending reannounce retry does not stack")
assertEq(RetrySync.ReannounceRetryDecision(true, true, "session-a", nil, 3, false, 3), "exhausted", "reannounce retries exhaust at the cap")
assertEq(RetrySync.ReannounceRetryDecision(true, true, "session-a", "session-a", 0, false, 3), "stop", "an announced session does not retry reannounce")
assertEq(RetrySync.ReannounceRetryDecision(true, false, "session-a", nil, 0, false, 3), "stop", "a non-coordinator does not retry reannounce")
assertEq(RetrySync.ReannounceRetryDecision(false, true, "session-a", nil, 0, false, 3), "stop", "an inactive session does not retry reannounce")

-- A stuck _evaluating / _refreshing guard must not disable Early Preparation forever.
EarlyPrep._evaluating = true
EarlyPrep._refreshing = true
EarlyPrep:OnSessionReset("guard-reset")
assertTrue(not EarlyPrep._evaluating, "session reset clears the evaluating guard")
assertTrue(not EarlyPrep._refreshing, "session reset clears the refreshing guard")
local boomCalls = 0
SF.RaidCheck.GetAuthoritativePreparation = function()
	boomCalls = boomCalls + 1
	error("evaluate boom")
end
SF.RaidCheck.GetPreparationObservationStamp = function()
	return "remote|boom|ready|1|0|cfg"
end
EarlyPrep._skipStamp = nil
EarlyPrep._windowOpen = true
EarlyPrep._evaluating = false
local observedOk, observedErr = pcall(function()
	EarlyPrep:OnMemberObserved("Bob-Realm")
end)
assertTrue(not observedOk, "OnMemberObserved surfaces evaluation errors")
assertTrue(not EarlyPrep._evaluating, "OnMemberObserved clears evaluating after an error")
assertTrue(boomCalls >= 1, "OnMemberObserved evaluated before raising")
EarlyPrep._refreshing = false
local refreshOk = pcall(function()
	EarlyPrep:Refresh("setting")
end)
assertTrue(not refreshOk, "Refresh surfaces evaluation errors")
assertTrue(not EarlyPrep._refreshing, "Refresh clears refreshing after an error")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
	os.exit(1)
end
