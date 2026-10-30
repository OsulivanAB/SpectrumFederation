-- Production-path tests for last-good invalidation and blended observation authority.
-- Run from the repository root:
--   lua5.1 tests/lua/raid_check_observation_authority_tests.lua

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

INVSLOT_HEAD = 1
INVSLOT_NECK = 2
INVSLOT_SHOULDER = 3
INVSLOT_CHEST = 5
INVSLOT_WAIST = 6
INVSLOT_LEGS = 7
INVSLOT_FEET = 8
INVSLOT_WRIST = 9
INVSLOT_HAND = 10
INVSLOT_FINGER1 = 11
INVSLOT_FINGER2 = 12
INVSLOT_TRINKET1 = 13
INVSLOT_TRINKET2 = 14
INVSLOT_BACK = 15
INVSLOT_MAINHAND = 16
INVSLOT_OFFHAND = 17

local TRACKED_SLOTS = {
	INVSLOT_HEAD,
	INVSLOT_NECK,
	INVSLOT_SHOULDER,
	INVSLOT_CHEST,
	INVSLOT_WAIST,
	INVSLOT_LEGS,
	INVSLOT_FEET,
	INVSLOT_WRIST,
	INVSLOT_HAND,
	INVSLOT_FINGER1,
	INVSLOT_FINGER2,
	INVSLOT_TRINKET1,
	INVSLOT_TRINKET2,
	INVSLOT_BACK,
	INVSLOT_MAINHAND,
	INVSLOT_OFFHAND,
}

local inventoryByUnit = {}
local nowTime = 1000

function strsplit(sep, text)
	local result = {}
	local start = 1
	local sepLen = string.len(sep)
	while true do
		local found = string.find(text, sep, start, true)
		if not found then
			result[#result + 1] = string.sub(text, start)
			break
		end
		result[#result + 1] = string.sub(text, start, found - 1)
		start = found + sepLen
	end
	return unpack(result)
end

CreateFrame = function()
	return {
		RegisterEvent = function() end,
		SetScript = function() end,
		HookScript = function() end,
		Hide = function() end,
		Show = function() end,
	}
end

NotifyInspect = function() end
ClearInspectPlayer = function() end
CanInspect = function()
	return true
end
CheckInteractDistance = function()
	return true
end
IsInRaid = function()
	return true
end
IsInGroup = function()
	return true
end
GetNumGroupMembers = function()
	return 1
end
GetRealmName = function()
	return "Realm"
end
GetTime = function()
	return nowTime
end
GetServerTime = function()
	return nowTime
end
UnitExists = function(unit)
	return inventoryByUnit[unit] ~= nil or unit == "player" or unit == "raid1"
end
UnitIsUnit = function(a, b)
	return a == b
end
UnitGUID = function(unit)
	if unit == "player" then
		return "Player-1-SELF"
	end
	if unit == "raid1" then
		return "Player-1-REMOTE"
	end
	return nil
end
UnitFullName = function(unit)
	if unit == "player" then
		return "Self", "Realm"
	end
	if unit == "raid1" then
		return "Remote", "Realm"
	end
	return nil
end
UnitClass = function()
	return "Warrior", "WARRIOR"
end

local function slotLink(slot)
	-- Include a non-zero enchant field so remote links are not treated as TWW
	-- inspect stubs by IsSlotLinkPotentiallyIncomplete.
	return string.format(
		"|cffffffff|Hitem:%d:1:::::::80:72:::::::::|h[Item%d]|h|r",
		1000 + slot,
		slot
	)
end

GetInventoryItemLink = function(unit, slot)
	local bag = inventoryByUnit[unit]
	if type(bag) ~= "table" then
		return nil
	end
	return bag[slot]
end
GetInventoryItemID = function(unit, slot)
	local link = GetInventoryItemLink(unit, slot)
	if not link then
		return nil
	end
	return 1000 + slot
end
GetInventoryItemTexture = function(unit, slot)
	if GetInventoryItemLink(unit, slot) then
		return "Interface\\Icons\\INV_Misc_QuestionMark"
	end
	return nil
end

-- Enough item identity for Policy to treat full captures as complete.
local SLOT_IDENTITY = {
	[INVSLOT_HEAD] = { "INVTYPE_HEAD", 4, 0 },
	[INVSLOT_NECK] = { "INVTYPE_NECK", 4, 0 },
	[INVSLOT_SHOULDER] = { "INVTYPE_SHOULDER", 4, 0 },
	[INVSLOT_CHEST] = { "INVTYPE_CHEST", 4, 0 },
	[INVSLOT_WAIST] = { "INVTYPE_WAIST", 4, 0 },
	[INVSLOT_LEGS] = { "INVTYPE_LEGS", 4, 0 },
	[INVSLOT_FEET] = { "INVTYPE_FEET", 4, 0 },
	[INVSLOT_WRIST] = { "INVTYPE_WRIST", 4, 0 },
	[INVSLOT_HAND] = { "INVTYPE_HAND", 4, 0 },
	[INVSLOT_FINGER1] = { "INVTYPE_FINGER", 4, 0 },
	[INVSLOT_FINGER2] = { "INVTYPE_FINGER", 4, 0 },
	[INVSLOT_TRINKET1] = { "INVTYPE_TRINKET", 4, 0 },
	[INVSLOT_TRINKET2] = { "INVTYPE_TRINKET", 4, 0 },
	[INVSLOT_BACK] = { "INVTYPE_CLOAK", 4, 1 },
	[INVSLOT_MAINHAND] = { "INVTYPE_WEAPONMAINHAND", 2, 7 },
	[INVSLOT_OFFHAND] = { "INVTYPE_WEAPONOFFHAND", 2, 0 },
}
GetItemInfoInstant = function(link)
	if type(link) ~= "string" then
		return nil
	end
	local itemId = tonumber(string.match(link, "item:(%d+)"))
	if not itemId then
		return nil
	end
	local slot = itemId - 1000
	local identity = SLOT_IDENTITY[slot]
	if not identity then
		return nil
	end
	-- itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subclassID
	return itemId, "Armor", "Misc", identity[1], "Interface\\Icons\\INV_Misc_QuestionMark", identity[2], identity[3]
end
C_PaperDollInfo = {
	GetInspectItemLevel = function()
		return 700
	end,
	GetAverageItemLevel = function()
		return 700, 700
	end,
}

local function fillAllSlots()
	local bag = {}
	for _, slot in ipairs(TRACKED_SLOTS) do
		bag[slot] = slotLink(slot)
	end
	return bag
end

local function fillSlotsExceptOffHand()
	local bag = fillAllSlots()
	bag[INVSLOT_OFFHAND] = nil
	return bag
end

local function setMainHandIdentity(equipLoc, classId, subClassId)
	SLOT_IDENTITY[INVSLOT_MAINHAND] = { equipLoc, classId, subClassId }
end

local function makePriorEntry(memberId, guid)
	local slots = {}
	for _, slot in ipairs(TRACKED_SLOTS) do
		slots[slot] = {
			link = slotLink(slot),
			itemId = 1000 + slot,
			texture = "Interface\\Icons\\INV_Misc_QuestionMark",
			hasItem = true,
		}
	end
	return {
		guid = guid,
		id = memberId,
		status = "ready",
		updatedAt = nowTime,
		capturedAt = nowTime,
		overallEquippedItemLevel = 700,
		averageItemLevel = 700,
		slotsByInventory = slots,
		blended = false,
		aliases = { guid, memberId },
	}
end

local SF = {}
function SF:GetPlayerFullIdentifier()
	return "Self-Realm"
end
function SF:GetActiveProfile()
	return nil
end
SF.LootHelperSync = {
	IsSessionActive = function()
		return true
	end,
	GetSessionId = function()
		return "SES-A"
	end,
	GetSessionProfileId = function()
		return "profile-1"
	end,
}

assert(loadfile("SpectrumFederation/modules/LootHelper/SpecWeapons.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/RaidEquipment/Policy.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/RaidEquipment/CheckRun.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/RaidCheck.lua"))("SpectrumFederation", SF)

local RC = SF.RaidCheck
local CheckRun = SF.RaidEquipment.CheckRun
local Policy = SF.RaidEquipment.Policy

local function resetState()
	RC._inspectState = nil
	nowTime = 1000
	inventoryByUnit = {
		player = fillAllSlots(),
		raid1 = fillAllSlots(),
	}
end

local function beginAdhocInspect(state, memberId, guid)
	state.adhocRun = state.adhocRun or CheckRun.NewRun({
		targetIds = { memberId },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	if not state.adhocRun.players[memberId] then
		state.adhocRun.players[memberId] = CheckRun.NewPlayer(memberId)
		state.adhocRun.targetIds[#state.adhocRun.targetIds + 1] = memberId
	end
	CheckRun.IssueInspect(state, {
		guid = guid,
		id = memberId,
		aliases = { guid, memberId },
		requestedAt = nowTime,
		runId = state.adhocRun.id,
	})
	state.active.unit = "raid1"
end

local function inspectReadyOnce(state, memberId, guid)
	beginAdhocInspect(state, memberId, guid)
	RC:_HandleInspectReady(guid)
	nowTime = nowTime + 1
	return state.cache[memberId], state.lastGood[memberId], state.adhocRun.players[memberId]
end

-- ---------------------------------------------------------------------------
-- 1) Equipment-change invalidation (member-scoped)
-- ---------------------------------------------------------------------------
resetState()
local state = RC:_GetInspectState()
state.lastGood["Remote-Realm"] = {
	capturedAt = nowTime - 30,
	complete = true,
	sessionId = "SES-A",
	policy = { prepared = true, missing = {}, complete = true },
	observation = { slotsByInventory = {} },
}
state.lastGood["Other-Realm"] = {
	capturedAt = nowTime - 30,
	complete = true,
	sessionId = "SES-A",
	policy = { prepared = true, missing = {}, complete = true },
	observation = { slotsByInventory = {} },
}
state.adhocRun = CheckRun.NewRun({
	targetIds = { "Remote-Realm" },
	expectedSessionId = "SES-A",
	now = nowTime,
})
state.adhocRun.players["Remote-Realm"].lastGood = state.lastGood["Remote-Realm"]
state.adhocRun.players["Remote-Realm"].freshObservation = {
	complete = true,
	policy = state.lastGood["Remote-Realm"].policy,
}

RC:_InvalidateInspectUnit("raid1")
assertEq(state.lastGood["Remote-Realm"], nil, "remote inventory change clears that member's lastGood")
assertTrue(state.lastGood["Other-Realm"] ~= nil, "remote inventory change does not clear unrelated members")
assertEq(state.adhocRun.players["Remote-Realm"].lastGood, nil, "remote inventory change clears run-attached lastGood")
assertEq(state.adhocRun.players["Remote-Realm"].freshObservation, nil, "remote inventory change clears stale freshObservation")

CheckRun.MarkAttempt(state.adhocRun.players["Remote-Realm"], "timeout", true, nowTime)
local afterInvalidate = CheckRun.ClassifyPlayer(
	state.adhocRun.players["Remote-Realm"],
	nowTime,
	state.lastGood["Remote-Realm"],
	"SES-A"
)
assertEq(afterInvalidate.class, CheckRun.CLASS.INSPECTION_FAILED, "after gear-change invalidation, failed refresh does not reuse stale lastGood")

-- Self bag-only UNIT_INVENTORY_CHANGED must not clear lastGood.
state.lastGood["Self-Realm"] = {
	capturedAt = nowTime - 20,
	complete = true,
	sessionId = "SES-A",
	policy = { prepared = true, missing = {}, complete = true },
	observation = { slotsByInventory = {} },
}
RC:_InvalidateInspectUnit("player") -- default: clearLastGood false for self
assertTrue(state.lastGood["Self-Realm"] ~= nil, "self UNIT_INVENTORY_CHANGED keeps lastGood (bag noise)")

RC:_InvalidateInspectUnit("player", { clearLastGood = true })
assertEq(state.lastGood["Self-Realm"], nil, "PLAYER_EQUIPMENT_CHANGED clears self lastGood")

-- Fallback remains when no invalidating change occurred.
state.lastGood["Remote-Realm"] = {
	capturedAt = nowTime - 40,
	complete = true,
	sessionId = "SES-A",
	policy = { prepared = true, missing = {}, complete = true },
	observation = { slotsByInventory = {} },
}
local untouched = CheckRun.NewPlayer("Remote-Realm")
CheckRun.MarkAttempt(untouched, "incomplete", true, nowTime)
untouched.currentlyInspectable = true
local stillUsable = CheckRun.ClassifyPlayer(untouched, nowTime, state.lastGood["Remote-Realm"], "SES-A")
assertEq(stillUsable.class, CheckRun.CLASS.PREPARED, "same-session fallback remains when no gear-change invalidation happened")

-- ---------------------------------------------------------------------------
-- 2) Blended InspectReady must not promote authoritative lastGood / fresh
-- ---------------------------------------------------------------------------
resetState()
state = RC:_GetInspectState()
local memberId = "Remote-Realm"
local guid = "Player-1-REMOTE"
local prior = makePriorEntry(memberId, guid)
RC:_StoreInspectCacheEntry(prior, prior.aliases)

-- Partial live capture: omit Off Hand so prior evidence is blended in.
local partial = fillAllSlots()
partial[INVSLOT_OFFHAND] = nil
inventoryByUnit.raid1 = partial

state.lastGood[memberId] = nil
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
CheckRun.IssueInspect(state, {
	guid = guid,
	id = memberId,
	aliases = { guid, memberId },
	requestedAt = nowTime,
	runId = state.adhocRun.id,
})
state.active.unit = "raid1"

RC:_HandleInspectReady(guid)

local cacheEntry = state.cache[memberId]
assertTrue(type(cacheEntry) == "table", "InspectReady still stores a cache entry for troubleshooting")
assertEq(cacheEntry.blended, true, "partial capture that merges prior slots is marked blended")
assertEq(state.lastGood[memberId], nil, "blended InspectReady does not write authoritative lastGood")
local blendedPlayer = state.adhocRun.players[memberId]
assertTrue(not (blendedPlayer.freshObservation and blendedPlayer.freshObservation.complete), "blended InspectReady does not mark a fresh complete observation")
assertEq(blendedPlayer.technicalFailure, true, "blended InspectReady remains a technical failure for classification")

local blendedClass = CheckRun.ClassifyPlayer(blendedPlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(blendedClass.class, CheckRun.CLASS.INSPECTION_FAILED, "blended capture is not classified Prepared/Unprepared via lastGood")

-- A later complete, non-blended capture may become authoritative again.
inventoryByUnit.raid1 = fillAllSlots()
state.cache[memberId] = nil
state.cache[guid] = nil
CheckRun.IssueInspect(state, {
	guid = guid,
	id = memberId,
	aliases = { guid, memberId },
	requestedAt = nowTime + 1,
	runId = state.adhocRun.id,
})
state.active.unit = "raid1"
nowTime = nowTime + 1
RC:_HandleInspectReady(guid)

assertTrue(state.lastGood[memberId] ~= nil, "complete non-blended InspectReady writes lastGood")
assertEq(state.lastGood[memberId].complete, true, "authoritative lastGood is complete")
assertTrue(state.cache[memberId].blended ~= true, "authoritative cache entry is not blended")
assertTrue(
	state.adhocRun.players[memberId].freshObservation
		and state.adhocRun.players[memberId].freshObservation.complete == true,
	"authoritative InspectReady sets fresh complete observation"
)

-- Empty-slot first capture without prior evidence stays non-authoritative.
resetState()
state = RC:_GetInspectState()
inventoryByUnit.raid1 = {
	[INVSLOT_HEAD] = slotLink(INVSLOT_HEAD),
	-- remaining tracked slots intentionally empty / unresolved
}
CheckRun.IssueInspect(state, {
	guid = guid,
	id = memberId,
	aliases = { guid, memberId },
	requestedAt = nowTime,
})
state.active.unit = "raid1"
RC:_HandleInspectReady(guid)
assertEq(state.lastGood[memberId], nil, "first partial capture with empty tracked slots does not invent complete lastGood")
assertEq(state.cache[memberId].blended, true, "first partial capture with empty tracked slots remains blended/unresolved")

-- Policy completeness alone is not enough when blended provenance is set.
local fakeComplete = Policy.EvaluateObservation({
	slotsByInventory = {
		[INVSLOT_HEAD] = { empty = false, link = slotLink(INVSLOT_HEAD), linkComplete = true, hasEnchant = true, sockets = {} },
	},
}, { checkGemsInSockets = false, slots = {} })
assertTrue(type(fakeComplete) == "table", "policy evaluation returns a result for the blended gate check")

-- ---------------------------------------------------------------------------
-- 3) Legitimate empty off-hand with two-handed main-hand can become authoritative
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_2HWEAPON", 2, 8)
state = RC:_GetInspectState()
memberId = "Remote-Realm"
guid = "Player-1-REMOTE"
inventoryByUnit.raid1 = fillSlotsExceptOffHand()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})

local firstCache = inspectReadyOnce(state, memberId, guid)
assertEq(firstCache.blended, true, "first 2H empty-offhand capture stays blended/unresolved")
assertEq(state.lastGood[memberId], nil, "first 2H empty-offhand capture is not yet authoritative")

local secondCache, secondGood, secondPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(secondCache.blended ~= true, "second consecutive 2H empty-offhand capture is not blended")
assertTrue(secondGood ~= nil, "second consecutive 2H empty-offhand capture writes lastGood")
assertEq(secondGood.complete, true, "confirmed empty off-hand with 2H main-hand is a complete observation")
assertTrue(
	secondPlayer.freshObservation and secondPlayer.freshObservation.complete == true,
	"confirmed empty off-hand sets fresh complete observation"
)
assertEq(secondPlayer.technicalFailure, false, "authoritative 2H empty-offhand clears technical failure")
local twoHandClass = CheckRun.ClassifyPlayer(secondPlayer, nowTime, secondGood, "SES-A")
assertEq(twoHandClass.class, CheckRun.CLASS.PREPARED, "authoritative 2H empty-offhand can classify Prepared")
assertEq(twoHandClass.verified, CheckRun.VERIFIED.FRESH, "authoritative 2H empty-offhand is Fresh Verified")

-- Out-of-range refresh failure still falls back to the same-session observation.
CheckRun.MarkAttempt(secondPlayer, "timeout", true, nowTime)
secondPlayer.currentlyInspectable = false
secondPlayer.rangeOnlyFailure = true
secondPlayer.freshObservation = nil
local fallbackClass = CheckRun.ClassifyPlayer(secondPlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(fallbackClass.class, CheckRun.CLASS.PREPARED, "same-session fallback works after authoritative 2H empty-offhand observation")
assertEq(fallbackClass.verified, CheckRun.VERIFIED.RECENT, "post-authoritative OOR fallback is Recently Verified")

-- ---------------------------------------------------------------------------
-- 4) Previously equipped off-hand temporarily blank must not become authoritative
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
prior = makePriorEntry(memberId, guid)
RC:_StoreInspectCacheEntry(prior, prior.aliases)
inventoryByUnit.raid1 = fillSlotsExceptOffHand()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local tempBlankCache = inspectReadyOnce(state, memberId, guid)
assertEq(tempBlankCache.blended, true, "temporary blank over previously equipped off-hand stays blended")
assertEq(state.lastGood[memberId], nil, "copied prior off-hand evidence does not manufacture authoritative completeness")

-- A later full independent inspection recovers.
inventoryByUnit.raid1 = fillAllSlots()
local recoveredCache, recoveredGood, recoveredPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(recoveredCache.blended ~= true, "full inspection after blended state is not blended")
assertTrue(recoveredGood ~= nil, "full inspection after blended state writes lastGood")
assertTrue(
	recoveredPlayer.freshObservation and recoveredPlayer.freshObservation.complete == true,
	"full inspection after blended state sets fresh complete observation"
)

-- ---------------------------------------------------------------------------
-- 5) One-handed main-hand with confirmed empty off-hand is authoritative Unprepared
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillSlotsExceptOffHand()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
inspectReadyOnce(state, memberId, guid)
local missingOhCache, missingOhGood, missingOhPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(missingOhCache.blended ~= true, "confirmed empty off-hand on 1H setup is not blended")
assertTrue(missingOhGood ~= nil, "confirmed empty off-hand on 1H setup writes lastGood")
assertEq(missingOhGood.complete, true, "confirmed missing required off-hand is still a complete observation")
assertTrue(missingOhGood.policy and missingOhGood.policy.prepared == false, "missing required off-hand is Unprepared")
local missingOhClass = CheckRun.ClassifyPlayer(missingOhPlayer, nowTime, missingOhGood, "SES-A")
assertEq(missingOhClass.class, CheckRun.CLASS.UNPREPARED, "authoritative missing off-hand classifies Unprepared")
assertTrue(missingOhClass.countsForPot, "authoritative missing off-hand counts for Reward Pot")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
	os.exit(1)
end
