-- Production-Lua tests for shared background inspect queue ownership.
-- Run from the repository root: lua5.1 tests/lua/background_inspect_queue_tests.lua

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

CreateFrame = function()
	return {
		RegisterEvent = function() end,
		SetScript = function() end,
	}
end

local inspects = 0
NotifyInspect = function()
	inspects = inspects + 1
end
UnitExists = function()
	return true
end
CanInspect = function()
	return true
end
CheckInteractDistance = function()
	return true
end
IsInRaid = function()
	return true
end
GetNumGroupMembers = function()
	return 1
end
UnitGUID = function(unit)
	if unit == "raid1" then
		return "guid-a"
	end
	return nil
end
GetTime = function()
	return 1000
end
UnitFullName = function()
	return "A", "Realm"
end
UnitClass = function()
	return nil, nil
end

local SF = {}
assert(loadfile("SpectrumFederation/modules/RaidEquipment/EarlyPreparation.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/RaidCheck.lua"))("SpectrumFederation", SF)

local RC = SF.RaidCheck

local function resetQueue(items)
	local state = RC:_GetInspectState()
	state.queue = items
	state.queueHead = 1
	state.queued = {}
	state.active = nil
	state.adhocRun = nil
	state.inspectPausedForCombat = false
	for _, item in ipairs(items) do
		if type(item) == "table" and item.key then
			state.queued[item.key] = true
		end
	end
	return state
end

local function countSource(queue, source)
	local count = 0
	for _, item in ipairs(queue or {}) do
		if type(item) == "table" and item.source == source then
			count = count + 1
		end
	end
	return count
end

RC:SetBackgroundInspectEnabled(true, "early_preparation")
RC:SetBackgroundInspectEnabled(true, "equipment page shown", { consumerId = "equipment page" })
local state = resetQueue({
	{ key = "bg-1", guid = "guid-a", id = "A-Realm", source = "background" },
	{ key = "ad-1", guid = "guid-b", id = "B-Realm", source = "adhoc" },
})
inspects = 0
RC:SetBackgroundInspectEnabled(false, "early_preparation")
assertEq(countSource(state.queue, "background"), 1, "another consumer keeps queued background scans")
assertEq(countSource(state.queue, "adhoc"), 1, "another consumer keeps a queued ad-hoc scan")
assertEq(inspects, 0, "turning off one consumer does not inspect")
assertTrue(state.backgroundInspectEnabled == true, "inspection stays on while a consumer remains")

inspects = 0
RC:SetBackgroundInspectEnabled(false, "equipment page hidden", { consumerId = "equipment page" })
assertEq(countSource(state.queue, "background"), 0, "the last consumer drops queued background scans")
assertEq(countSource(state.queue, "adhoc"), 1, "the last consumer keeps a queued ad-hoc scan")
assertEq(state.queued["bg-1"], nil, "a dropped background scan clears its queued flag")
assertEq(state.queued["ad-1"], true, "an ad-hoc scan keeps its queued flag")
assertEq(inspects, 0, "dropping the background queue does not call NotifyInspect")
assertTrue(state.backgroundInspectEnabled ~= true, "the last consumer turns background inspection off")

local flooded = {}
for i = 1, 40 do
	flooded[i] = {
		key = "flood-" .. i,
		guid = "guid-a",
		id = "Member-Realm",
		source = "background",
	}
end
flooded[#flooded + 1] = { key = "ad-keep", id = "Keep-Realm", source = "adhoc" }
state = resetQueue(flooded)
state.backgroundInspectEnabled = true
state.backgroundInspectConsumers = { early_preparation = {} }
inspects = 0
local removed = RC:_DiscardQueuedBackgroundInspects()
assertEq(removed, 40, "one disable pass removes a full background queue")
assertEq(#state.queue, 1, "the ad-hoc scan is the only queue entry left")
assertEq(inspects, 0, "discarding a full queue does not inspect")

state = resetQueue({
	{ key = "guid-a", guid = "guid-a", id = "A-Realm", source = "background" },
	{ key = "guid-b", guid = "guid-b", id = "B-Realm", source = "background" },
})
state.backgroundInspectEnabled = false
inspects = 0
RC:_ProcessInspectQueue()
assertEq(inspects, 0, "the processor does not inspect background work after it is stopped")
assertEq(#state.queue, 0, "the processor drains stopped background work in one pass")
assertEq(state.queued["guid-a"], nil, "the processor clears the first stopped queued flag")
assertEq(state.queued["guid-b"], nil, "the processor clears the second stopped queued flag")

state = resetQueue({
	{ key = "guid-a", guid = "guid-a", id = "A-Realm", source = "background" },
})
state.backgroundInspectEnabled = true
state.backgroundInspectConsumers = { equipment = {} }
inspects = 0
RC:_ProcessInspectQueue()
assertEq(inspects, 1, "an enabled background scan still calls NotifyInspect once")
assertTrue(state.active ~= nil, "an enabled background scan becomes the active inspect")

RC:SetBackgroundInspectEnabled(false, "equipment", { consumerId = "equipment" })
RC:SetBackgroundInspectEnabled(true, "early_preparation", {
	filter = function(info)
		return info and info.id == "Profile-Realm"
	end,
})
RC:SetBackgroundInspectEnabled(true, "equipment page shown", { consumerId = "equipment page" })
state = resetQueue({
	{ key = "stranger", guid = "guid-a", id = "Stranger-Realm", source = "background" },
	{ key = "profile", guid = "guid-a", id = "Profile-Realm", source = "background" },
	{ key = "ad-keep", id = "Other-Realm", source = "adhoc" },
})
inspects = 0
RC:SetBackgroundInspectEnabled(false, "equipment page hidden", { consumerId = "equipment page" })
assertEq(countSource(state.queue, "background"), 1, "a filtered sole consumer drops the rest of a whole-raid queue")
assertEq(state.queue[1] and state.queue[1].id, "Profile-Realm", "the filtered consumer keeps its own queued member")
assertEq(countSource(state.queue, "adhoc"), 1, "hiding the equipment page keeps a queued ad-hoc scan")
assertEq(state.queued.stranger, nil, "a non-profile background scan clears its queued flag")
assertEq(state.queued.profile, true, "a profile background scan keeps its queued flag")
assertEq(inspects, 0, "hiding the equipment page does not inspect the leftover queue")
assertTrue(state.backgroundInspectEnabled == true, "early preparation keeps background inspection enabled")

state = resetQueue({
	{ key = "stranger", guid = "guid-a", id = "Stranger-Realm", source = "background" },
	{ key = "profile", guid = "guid-a", id = "Profile-Realm", source = "background" },
})
state.backgroundInspectEnabled = true
inspects = 0
RC:_ProcessInspectQueue()
assertEq(inspects, 1, "the processor issues only the member the remaining filter wants")
assertEq(state.active and state.active.id, "Profile-Realm", "the issued scan is the profile member")
assertEq(state.queued.stranger, nil, "the processor clears the rejected member")

state = resetQueue({})
state.backgroundInspectEnabled = true
state.active = {
	key = "guid-a",
	guid = "guid-a",
	id = "A-Realm",
	source = "background",
}
state.inspectPausedForCombat = false
RC:_PauseInspectForCombat()
assertEq(state.queue[1] and state.queue[1].source, "background", "combat requeue keeps the background source")
assertEq(state.active, nil, "combat pause clears the active inspect")
state.backgroundInspectEnabled = false
inspects = 0
RC:_DiscardQueuedBackgroundInspects()
RC:_ResumeInspectAfterCombat()
assertEq(inspects, 0, "a background inspect paused for combat is not sent after the feature stops")
assertEq(#state.queue, 0, "the combat-requeued background scan is gone after the feature stops")

state = resetQueue({})
state.active = {
	key = "ad-1",
	guid = "guid-b",
	id = "B-Realm",
	source = "adhoc",
}
state.inspectPausedForCombat = false
RC:_PauseInspectForCombat()
assertEq(state.queue[1] and state.queue[1].source, "adhoc", "combat requeue keeps the ad-hoc source")
RC:_DiscardQueuedBackgroundInspects()
assertEq(state.queue[1] and state.queue[1].source, "adhoc", "discarding background scans leaves the combat-requeued ad-hoc scan")

local whispers = 0
SendChatMessage = function()
	whispers = whispers + 1
end
C_ChatInfo = {
	InChatMessagingLockdown = function()
		return true
	end,
}
local sent = RC:DeliverMissingRequirementsWhisper("A-Realm", {}, { "gem" }, nil, "pre")
assertTrue(not sent, "chat lockdown does not accept a missing whisper")
assertEq(whispers, 0, "chat lockdown does not call SendChatMessage")
C_ChatInfo.InChatMessagingLockdown = function()
	return false
end
sent = RC:DeliverMissingRequirementsWhisper("A-Realm", {}, { "gem" }, nil, "pre")
assertTrue(sent == true, "an open chat accepts a missing whisper")
assertEq(whispers, 1, "an open chat calls SendChatMessage once")

local tooltipCalls = 0
C_TooltipInfo = {
	GetHyperlink = function()
		tooltipCalls = tooltipCalls + 1
		return nil
	end,
}
local inspectState = RC:_GetInspectState()
inspectState.cache["A-Realm"] = {
	updatedAt = GetTime(),
	status = "ready",
	blended = false,
}
local stamp = RC:GetPreparationObservationStamp("A-Realm", {
	checkGemsInSockets = true,
	requireMetaGem = false,
	slots = { head = true },
})
assertTrue(type(stamp) == "string" and string.find(stamp, "ready", 1, true) ~= nil, "the observation stamp includes cache status")
assertEq(tooltipCalls, 0, "an observation stamp does not read item tooltips")
local sameStamp = RC:GetPreparationObservationStamp("A-Realm", {
	checkGemsInSockets = true,
	requireMetaGem = false,
	slots = { head = true },
})
assertEq(sameStamp, stamp, "the same cache and policy produce the same stamp")
local changedStamp = RC:GetPreparationObservationStamp("A-Realm", {
	checkGemsInSockets = false,
	requireMetaGem = false,
	slots = { head = true },
})
assertTrue(changedStamp ~= stamp, "a policy change changes the observation stamp")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
	os.exit(1)
end
