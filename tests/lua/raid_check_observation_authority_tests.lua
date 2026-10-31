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

local socketCountByItemId = {}

local function slotLink(slot, itemId, opts)
	-- Include a non-zero enchant field so remote links are not treated as TWW
	-- inspect stubs by IsSlotLinkPotentiallyIncomplete.
	opts = opts or {}
	itemId = itemId or (1000 + slot)
	local enchant = opts.enchant
	if enchant == nil then
		enchant = 1
	end
	local gem = opts.gem
	if gem == nil then
		gem = ""
	end
	return string.format(
		"|cffffffff|Hitem:%d:%s:%s::::::80:72:::::::::|h[Item%d]|h|r",
		itemId,
		tostring(enchant),
		tostring(gem),
		slot
	)
end

local function slotLinkStub(slot, itemId)
	-- All modification fields empty: TWW inspect stub / incomplete link.
	itemId = itemId or (1000 + slot)
	return string.format(
		"|cffffffff|Hitem:%d::::::::::::::|h[Item%d]|h|r",
		itemId,
		slot
	)
end

local function fillAlternateKit()
	local bag = {}
	for _, slot in ipairs(TRACKED_SLOTS) do
		bag[slot] = slotLink(slot, 1050 + slot)
	end
	return bag
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
	return tonumber(string.match(link, "item:(%d+)"))
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
	local slot = nil
	-- Default kit: 1000+slot. Alternate gear-change kit: 1050+slot.
	for _, tracked in ipairs(TRACKED_SLOTS) do
		if itemId == 1000 + tracked or itemId == 1050 + tracked then
			slot = tracked
			break
		end
	end
	local identity = slot and SLOT_IDENTITY[slot] or nil
	if not identity then
		return nil
	end
	-- itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subclassID
	return itemId, "Armor", "Misc", identity[1], "Interface\\Icons\\INV_Misc_QuestionMark", identity[2], identity[3]
end
local inspectItemLevel = 700
C_PaperDollInfo = {
	GetInspectItemLevel = function()
		return inspectItemLevel
	end,
	GetAverageItemLevel = function()
		return inspectItemLevel, inspectItemLevel
	end,
}
C_Item = {
	GetItemNumSockets = function(link)
		if type(link) ~= "string" then
			return 0
		end
		local itemId = tonumber(string.match(link, "item:(%d+)"))
		if not itemId then
			return 0
		end
		return tonumber(socketCountByItemId[itemId]) or 0
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
	inspectItemLevel = 700
	socketCountByItemId = {}
	inventoryByUnit = {
		player = fillAllSlots(),
		raid1 = fillAllSlots(),
	}
end

local function enableMinimumItemLevel(state, minimum)
	state.adhocRun = state.adhocRun or CheckRun.NewRun({
		targetIds = { "Remote-Realm" },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	state.adhocRun.cfg = {
		requireMinimumItemLevel = true,
		minimumItemLevel = minimum or 690,
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
	RC:_StampInspectRequestAuthority(state.active, nowTime)
end

local function inspectReadyOnce(state, memberId, guid)
	beginAdhocInspect(state, memberId, guid)
	RC:_HandleInspectReady(guid)
	nowTime = nowTime + 1
	return state.cache[memberId], state.lastGood[memberId], state.adhocRun.players[memberId]
end

local function expireInspectInventoryGrace(state)
	local req = state.active or state.retired
	if req then
		req.inventoryGraceUntil = (nowTime or 0) - 1
	end
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
beginAdhocInspect(state, memberId, guid)

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
nowTime = nowTime + 1
beginAdhocInspect(state, memberId, guid)
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
beginAdhocInspect(state, memberId, guid)
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
assertEq(fallbackClass.verified, CheckRun.VERIFIED.SESSION, "post-authoritative OOR fallback is same-session Recently Verified")

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

-- ---------------------------------------------------------------------------
-- 6) Equipped off-hand -> 2H out of range (no UNIT_INVENTORY_CHANGED) retires
--    copied evidence after independent blank inspects
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
memberId = "Remote-Realm"
guid = "Player-1-REMOTE"
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, priorGood, priorPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(priorGood ~= nil, "1H+off-hand baseline writes authoritative lastGood")
assertEq(priorGood.policy and priorGood.policy.prepared, true, "1H+off-hand baseline is Prepared")
local oldPolicyPrepared = priorGood.policy.prepared
priorPlayer.freshObservation = {
	complete = true,
	policy = priorGood.policy,
	observation = priorGood.observation,
	capturedAt = priorGood.capturedAt,
}

-- Player switches to 2H out of observable range: no inventory invalidation.
setMainHandIdentity("INVTYPE_2HWEAPON", 2, 8)
inventoryByUnit.raid1 = fillSlotsExceptOffHand()

local firstBlankCache = inspectReadyOnce(state, memberId, guid)
assertEq(firstBlankCache.blended, true, "first blank over previously equipped off-hand stays blended (copied evidence)")
assertTrue(
	type(firstBlankCache.slotsByInventory[INVSLOT_OFFHAND]) == "table"
		and firstBlankCache.slotsByInventory[INVSLOT_OFFHAND].copiedEvidence == true,
	"first blank copies prior off-hand and marks copiedEvidence"
)
assertEq(state.lastGood[memberId], priorGood, "first blank does not replace same-session lastGood yet")

local secondBlankCache, secondBlankGood, secondBlankPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(secondBlankCache.blended ~= true, "second independent blank retires copied off-hand evidence")
local retiredOffHand = secondBlankCache.slotsByInventory[INVSLOT_OFFHAND]
assertTrue(
	type(retiredOffHand) ~= "table"
		or (not retiredOffHand.link and not retiredOffHand.texture and not retiredOffHand.copiedEvidence),
	"retired off-hand slot is genuinely empty after two independent blanks"
)
assertTrue(secondBlankGood ~= nil, "confirmed 2H empty-offhand after retiring copy writes new lastGood")
assertEq(secondBlankGood.complete, true, "confirmed 2H empty-offhand after retiring copy is complete")
assertTrue(
	secondBlankPlayer.freshObservation and secondBlankPlayer.freshObservation.complete == true,
	"confirmed 2H empty-offhand sets fresh complete observation"
)
local switchedClass = CheckRun.ClassifyPlayer(secondBlankPlayer, nowTime, secondBlankGood, "SES-A")
assertEq(switchedClass.class, CheckRun.CLASS.PREPARED, "authoritative current 2H empty-offhand classifies Prepared")
assertEq(switchedClass.verified, CheckRun.VERIFIED.FRESH, "authoritative current 2H empty-offhand is Fresh Verified")
assertTrue(
	secondBlankGood ~= priorGood,
	"confirmed equipment replaces the previous same-session lastGood entry"
)
assertTrue(oldPolicyPrepared == true, "baseline Prepared flag preserved for comparison sanity")

-- Existing same-session lastGood cannot override subsequently confirmed different equipment.
secondBlankPlayer.freshObservation = nil
CheckRun.MarkAttempt(secondBlankPlayer, "timeout", true, nowTime)
secondBlankPlayer.currentlyInspectable = false
secondBlankPlayer.rangeOnlyFailure = true
local afterConfirmFallback = CheckRun.ClassifyPlayer(secondBlankPlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(afterConfirmFallback.class, CheckRun.CLASS.PREPARED, "fallback after 2H confirmation uses the new observation")
assertEq(afterConfirmFallback.verified, CheckRun.VERIFIED.SESSION, "fallback after 2H confirmation is same-session Recently Verified")

-- ---------------------------------------------------------------------------
-- 7) Temporary missing equipment data does not produce a false empty conclusion
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
local oneBlankCache = inspectReadyOnce(state, memberId, guid)
assertEq(oneBlankCache.blended, true, "single temporary blank over equipped off-hand stays blended")
assertEq(state.lastGood[memberId], nil, "single temporary blank does not write authoritative emptiness")
assertTrue(
	oneBlankCache.slotsByInventory[INVSLOT_OFFHAND]
		and oneBlankCache.slotsByInventory[INVSLOT_OFFHAND].copiedEvidence == true,
	"single temporary blank retains copied equipped evidence"
)

-- ---------------------------------------------------------------------------
-- 8) Gear change while NotifyInspect is outstanding: delayed obsolete response
--    cannot restore stale lastGood / freshObservation
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, liveGood, livePlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(liveGood ~= nil, "pre-change inspect writes lastGood")
livePlayer.freshObservation = {
	complete = true,
	policy = liveGood.policy,
	observation = liveGood.observation,
	capturedAt = liveGood.capturedAt,
}

-- Outstanding NotifyInspect stamped at the pre-change authority generation.
beginAdhocInspect(state, memberId, guid)
local outstandingGeneration = state.active.equipmentAuthorityGeneration
assertTrue(outstandingGeneration ~= nil, "outstanding inspect is stamped with equipment authority generation")

-- Genuine gear-change signal after inspect inventory grace: clears lastGood and
-- bumps authority so the delayed pre-change response is non-authoritative.
expireInspectInventoryGrace(state)
RC:_InvalidateInspectUnit("raid1")
assertEq(state.lastGood[memberId], nil, "gear change during outstanding inspect clears lastGood")
assertEq(livePlayer.freshObservation, nil, "gear change during outstanding inspect clears freshObservation")
assertTrue(
	RC:_CurrentEquipmentAuthorityGeneration({ guid, memberId }) > outstandingGeneration,
	"gear change during outstanding inspect bumps equipment authority generation"
)
assertTrue(state.active ~= nil, "gear change does not cancel the outstanding inspect request itself")
assertEq(
	RC:_InspectRequestHasEquipmentAuthority(state.active),
	false,
	"outstanding inspect loses equipment authority after gear-change invalidation"
)

-- Delayed pre-change response still describes the old full kit.
inventoryByUnit.raid1 = fillAllSlots()
RC:_HandleInspectReady(guid)
assertEq(state.lastGood[memberId], nil, "delayed obsolete INSPECT_READY does not restore lastGood")
assertTrue(
	not (state.adhocRun.players[memberId].freshObservation
		and state.adhocRun.players[memberId].freshObservation.complete),
	"delayed obsolete INSPECT_READY does not restore fresh complete observation"
)
assertTrue(type(state.cache[memberId]) == "table", "delayed obsolete INSPECT_READY may still update troubleshooting cache")
assertEq(state.cache[memberId].authorityInvalidated, true, "delayed obsolete INSPECT_READY marks cache authorityInvalidated")
assertEq(
	RC.CacheEntryHasEquipmentAuthority(state.cache[memberId]),
	false,
	"authority-invalidated cache is not treated as verified equipment"
)
local prepAfterObsolete, prepWhy = RC:GetAuthoritativePreparation(memberId, {})
assertEq(prepAfterObsolete, nil, "GetAuthoritativePreparation rejects authority-invalidated cache")
assertEq(prepWhy, "authority_invalidated", "GetAuthoritativePreparation reports authority_invalidated")
assertEq(
	state.adhocRun.players[memberId].lastIncompleteReason,
	"authority_invalidated",
	"delayed obsolete INSPECT_READY records authority_invalidated"
)

-- A later inspect under the new generation can become authoritative again.
nowTime = nowTime + 1
inventoryByUnit.raid1 = fillAllSlots()
local _, recoveredGood2, recoveredPlayer2 = inspectReadyOnce(state, memberId, guid)
assertTrue(recoveredGood2 ~= nil, "post-invalidation inspect under new authority generation writes lastGood")
assertTrue(
	recoveredPlayer2.freshObservation and recoveredPlayer2.freshObservation.complete == true,
	"post-invalidation inspect sets fresh complete observation"
)
assertTrue(
	state.cache[memberId].authorityInvalidated ~= true,
	"authoritative recovery clears authorityInvalidated on the cache entry"
)
local prepRecovered = RC:GetAuthoritativePreparation(memberId, {})
assertTrue(prepRecovered ~= nil, "GetAuthoritativePreparation accepts recovered authoritative cache")

-- ---------------------------------------------------------------------------
-- 9) Normal inspect-related inventory notifications still allow INSPECT_READY
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, noiseBaselineGood = inspectReadyOnce(state, memberId, guid)
assertTrue(noiseBaselineGood ~= nil, "noise-path baseline inspect writes lastGood")
beginAdhocInspect(state, memberId, guid)
local stampedBeforeNoise = state.active.equipmentAuthorityGeneration
assertTrue(next(state.active.equipmentBaselineBySlot or {}) ~= nil, "outstanding inspect stamps an equipment baseline")
local lastGoodBeforeNoise = state.lastGood[memberId]
-- Inventory notification inside grace with the same equipped identities
-- (NotifyInspect payload noise / still-loading blanks do not conflict).
RC:_InvalidateInspectUnit("raid1")
assertEq(
	RC:_CurrentEquipmentAuthorityGeneration({ guid, memberId }),
	stampedBeforeNoise,
	"inspect-driven inventory noise does not bump equipment authority generation"
)
assertTrue(state.active ~= nil, "inspect-driven inventory noise leaves the active inspect intact")
assertTrue(state.lastGood[memberId] == lastGoodBeforeNoise, "same-identity inventory noise does not clear lastGood")
RC:_HandleInspectReady(guid)
assertTrue(state.lastGood[memberId] ~= nil, "INSPECT_READY after inspect-driven inventory noise writes lastGood")
assertTrue(
	state.adhocRun.players[memberId].freshObservation
		and state.adhocRun.players[memberId].freshObservation.complete == true,
	"INSPECT_READY after inspect-driven inventory noise sets fresh complete observation"
)
assertTrue(RC:GetAuthoritativePreparation(memberId, {}) ~= nil, "GetAuthoritativePreparation accepts post-noise ready")

-- ---------------------------------------------------------------------------
-- 9b) Genuine remote gear change inside inventory grace invalidates authority
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, graceGood, gracePlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(graceGood ~= nil, "pre-change baseline for within-grace swap writes lastGood")
gracePlayer.freshObservation = {
	complete = true,
	policy = graceGood.policy,
	observation = graceGood.observation,
	capturedAt = graceGood.capturedAt,
}

beginAdhocInspect(state, memberId, guid)
local graceGeneration = state.active.equipmentAuthorityGeneration
assertTrue(RC:_IsWithinInspectInventoryGrace("raid1", nowTime), "request is still inside inventory grace")
-- Observable equipped identity conflict while still inside grace.
inventoryByUnit.raid1 = fillAlternateKit()
RC:_InvalidateInspectUnit("raid1")
assertEq(state.lastGood[memberId], nil, "observable gear change inside grace clears lastGood")
assertEq(gracePlayer.freshObservation, nil, "observable gear change inside grace clears freshObservation")
assertTrue(
	RC:_CurrentEquipmentAuthorityGeneration({ guid, memberId }) > graceGeneration,
	"observable gear change inside grace bumps equipment authority generation"
)
assertEq(
	RC:_InspectRequestHasEquipmentAuthority(state.active),
	false,
	"outstanding inspect loses authority after observable within-grace gear change"
)

-- Delayed obsolete ready still describes the pre-change kit.
inventoryByUnit.raid1 = fillAllSlots()
RC:_HandleInspectReady(guid)
assertEq(state.lastGood[memberId], nil, "within-grace change: obsolete ready does not restore lastGood")
assertEq(state.cache[memberId].authorityInvalidated, true, "within-grace change: obsolete ready marks cache non-authoritative")
assertEq(RC:GetAuthoritativePreparation(memberId, {}), nil, "within-grace change: GetAuthoritativePreparation rejects obsolete cache")

-- Fresh post-change inspect becomes authoritative.
nowTime = nowTime + 1
inventoryByUnit.raid1 = fillAlternateKit()
local _, postGraceGood, postGracePlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(postGraceGood ~= nil, "fresh inspect after within-grace change writes lastGood")
assertTrue(
	postGracePlayer.freshObservation and postGracePlayer.freshObservation.complete == true,
	"fresh inspect after within-grace change sets fresh complete observation"
)
assertTrue(RC:GetAuthoritativePreparation(memberId, {}) ~= nil, "GetAuthoritativePreparation accepts post-change authoritative cache")

-- ---------------------------------------------------------------------------
-- 9c) Ready-time live-vs-capture identity conflict refuses authority
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
beginAdhocInspect(state, memberId, guid)
local originalSample = RC._SampleLiveEquipmentSlotIdentityMap
RC._SampleLiveEquipmentSlotIdentityMap = function()
	local map = {}
	for _, slot in ipairs(TRACKED_SLOTS) do
		map[slot] = 1050 + slot
	end
	return map
end
RC:_HandleInspectReady(guid)
RC._SampleLiveEquipmentSlotIdentityMap = originalSample
assertEq(state.lastGood[memberId], nil, "ready-time identity conflict does not write lastGood")
assertEq(state.cache[memberId].authorityInvalidated, true, "ready-time identity conflict marks cache authorityInvalidated")
assertEq(RC:GetAuthoritativePreparation(memberId, {}), nil, "ready-time identity conflict rejected by GetAuthoritativePreparation")

-- ---------------------------------------------------------------------------
-- 9d) Authority-invalidated cache does not block background refresh for full TTL
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
beginAdhocInspect(state, memberId, guid)
expireInspectInventoryGrace(state)
RC:_InvalidateInspectUnit("raid1")
RC:_HandleInspectReady(guid)
assertEq(state.cache[memberId].authorityInvalidated, true, "setup: cache is authority-invalidated")
assertTrue(
	state.cache[memberId].updatedAt and (nowTime - state.cache[memberId].updatedAt) <= 30,
	"setup: invalidated cache still has a recent updatedAt"
)
state.adhocRun = nil
state.backgroundInspectEnabled = true
state.queue = {}
state.queueHead = 1
state.queued = {}
state.active = nil
state.retired = nil
nowTime = nowTime + 1
if state.cache[memberId] then
	state.cache[memberId].nextRetryAt = nil
end
local queuedBackground = 0
local originalQueue = RC._QueueInspectForUnit
RC._QueueInspectForUnit = function(self, unit, info, cacheEntry)
	queuedBackground = queuedBackground + 1
	return originalQueue(self, unit, info, cacheEntry)
end
RC:_PrimeBackgroundInspectQueue()
RC._QueueInspectForUnit = originalQueue
assertTrue(queuedBackground >= 1, "background inspection requeues authority-invalidated members without waiting full TTL")

-- ---------------------------------------------------------------------------
-- 10) Ordinary late-ready-after-timeout remains safe
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
beginAdhocInspect(state, memberId, guid)
local lateKey = state.active.key or guid
local lateRequestedAt = state.active.requestedAt
CheckRun.RetireActive(state, "timeout")
assertEq(state.active, nil, "timeout retires the active inspect")
assertTrue(state.retired ~= nil, "timeout keeps retired current request for late ready")
-- Keep grace so accompanying inspect inventory noise cannot bump under the late ready.
assertTrue(
	RC:_IsWithinInspectInventoryGrace("raid1", nowTime),
	"retired-current request retains inventory grace for late ready"
)
local canAccept, acceptReason = CheckRun.CanAcceptInspectReady(state, guid)
assertEq(canAccept, true, "late ready after timeout remains acceptable")
assertEq(acceptReason, "retired_current", "late ready binds to retired current generation")
RC:_HandleInspectReady(guid)
assertTrue(state.lastGood[memberId] ~= nil, "late ready after timeout can still write authoritative lastGood")
assertTrue(
	state.adhocRun.players[memberId].freshObservation
		and state.adhocRun.players[memberId].freshObservation.complete == true,
	"late ready after timeout sets fresh complete observation"
)
-- Old timeout callback must not disrupt newer work: issue a successor, then fire the old timeout.
beginAdhocInspect(state, memberId, guid)
local successorGeneration = state.active.generation
RC:_HandleInspectTimeout(lateKey, lateRequestedAt)
assertTrue(state.active ~= nil, "stale timeout callback does not clear a newer active inspect")
assertEq(state.active.generation, successorGeneration, "stale timeout callback leaves successor generation intact")
state.active = nil
state.retired = nil

-- ---------------------------------------------------------------------------
-- 11) Multiple blank tracked slots are confirmed independently
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_2HWEAPON", 2, 8)
state = RC:_GetInspectState()
memberId = "Remote-Realm"
guid = "Player-1-REMOTE"
local multiBlank = fillSlotsExceptOffHand()
multiBlank[INVSLOT_TRINKET2] = nil
inventoryByUnit.raid1 = multiBlank
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local firstMulti = inspectReadyOnce(state, memberId, guid)
assertEq(firstMulti.blended, true, "first multi-blank capture stays blended")
assertTrue(
	(firstMulti.independentBlankCounts[INVSLOT_OFFHAND] or 0) >= 1
		and (firstMulti.independentBlankCounts[INVSLOT_TRINKET2] or 0) >= 1,
	"first inspect records independent blank counts for every blank tracked slot"
)
assertEq(state.lastGood[memberId], nil, "first multi-blank capture is not authoritative")

-- Second inspect still blanks both: both can confirm. Keep 2H for OH legitimacy.
local secondMulti, secondMultiGood = inspectReadyOnce(state, memberId, guid)
-- Off-hand can confirm with 2H, but missing trinket should make policy Unprepared
-- only once both blanks are confirmed and the capture is non-blended.
assertTrue(secondMulti.blended ~= true, "second inspect confirms every previously blank slot")
assertTrue(secondMultiGood ~= nil, "fully confirmed multi-blank capture can write lastGood")
assertTrue(secondMulti.confirmedEmptySlots[INVSLOT_OFFHAND], "off-hand is independently confirmed empty")
assertTrue(secondMulti.confirmedEmptySlots[INVSLOT_TRINKET2], "trinket2 is independently confirmed empty")

-- New blank appearing only on a later inspect needs its own two generations.
resetState()
setMainHandIdentity("INVTYPE_2HWEAPON", 2, 8)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillSlotsExceptOffHand()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
inspectReadyOnce(state, memberId, guid)
local _, confirmedOhGood = inspectReadyOnce(state, memberId, guid)
assertTrue(confirmedOhGood ~= nil, "confirmed 2H empty-offhand writes lastGood before a new blank appears")

-- Third inspect: introduce a new blank trinket while OH stays empty.
local withNewBlank = fillSlotsExceptOffHand()
withNewBlank[INVSLOT_TRINKET2] = nil
inventoryByUnit.raid1 = withNewBlank
local lastGoodBeforeNewBlank = state.lastGood[memberId]
local newBlankCache = inspectReadyOnce(state, memberId, guid)
assertEq(newBlankCache.blended, true, "new blank slot on later inspect keeps capture non-authoritative")
assertTrue(
	(newBlankCache.independentBlankCounts[INVSLOT_TRINKET2] or 0) == 1,
	"new blank slot starts its own independent confirmation streak"
)
assertTrue(
	not (newBlankCache.confirmedEmptySlots and newBlankCache.confirmedEmptySlots[INVSLOT_TRINKET2]),
	"new blank slot is not confirmed empty after only one independent observation"
)
assertTrue(
	state.lastGood[memberId] == lastGoodBeforeNewBlank
		or state.lastGood[memberId] == nil,
	"unconfirmed new blank does not write a fabricated complete observation for the new empty slot"
)
local secondNewBlank, secondNewBlankGood = inspectReadyOnce(state, memberId, guid)
assertTrue(secondNewBlank.blended ~= true, "new blank becomes authoritative only after its second independent confirmation")
assertTrue(secondNewBlank.confirmedEmptySlots[INVSLOT_TRINKET2], "new blank slot is confirmed empty on its second generation")
assertTrue(secondNewBlankGood ~= nil, "second confirmation of the new blank can write authoritative lastGood")
assertTrue(
	secondNewBlankGood.policy and secondNewBlankGood.policy.prepared == false,
	"confirmed missing trinket is Unprepared rather than reusing prior Prepared"
)

-- ---------------------------------------------------------------------------
-- 12) Equipped <-> confirmed-empty transitions retire contradicted lastGood
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, equippedGood, equippedPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(equippedGood ~= nil, "equipped baseline writes lastGood")
assertEq(equippedGood.policy and equippedGood.policy.prepared, true, "equipped baseline is Prepared")

-- Independently confirm empty off-hand (1H setup => Unprepared once authoritative).
inventoryByUnit.raid1 = fillSlotsExceptOffHand()
inspectReadyOnce(state, memberId, guid)
local _, emptyOhGood, emptyOhPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(emptyOhGood ~= nil, "confirmed empty off-hand over prior equipped writes new lastGood")
assertTrue(emptyOhGood.policy and emptyOhGood.policy.prepared == false, "confirmed missing required off-hand is Unprepared")
assertTrue(
	emptyOhPlayer.freshObservation and emptyOhPlayer.freshObservation.complete == true,
	"confirmed empty-offhand transition sets fresh complete observation"
)
-- Stale Prepared must not remain as fallback after confirmed transition.
emptyOhPlayer.freshObservation = nil
CheckRun.MarkAttempt(emptyOhPlayer, "timeout", true, nowTime)
emptyOhPlayer.currentlyInspectable = false
emptyOhPlayer.rangeOnlyFailure = true
local afterEmptyTransition = CheckRun.ClassifyPlayer(emptyOhPlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(afterEmptyTransition.class, CheckRun.CLASS.UNPREPARED, "after equipped->empty confirmation, fallback uses the new Unprepared observation")
assertEq(afterEmptyTransition.verified, CheckRun.VERIFIED.SESSION, "post-transition fallback uses SESSION provenance")

-- Confirmed empty -> newly equipped recovers Prepared.
inventoryByUnit.raid1 = fillAllSlots()
local _, reequippedGood, reequippedPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(reequippedGood ~= nil, "empty->equipped transition writes authoritative lastGood")
assertTrue(reequippedGood.policy and reequippedGood.policy.prepared == true, "empty->equipped transition is Prepared")
assertTrue(
	state.cache[memberId].confirmedEmptySlots == nil
		or state.cache[memberId].confirmedEmptySlots[INVSLOT_OFFHAND] ~= true,
	"reequipping clears confirmed-empty for that slot"
)

-- ---------------------------------------------------------------------------
-- 13) Partial inspect with reliable changed item retires Prepared fallback
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, preparedGood, preparedPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(preparedGood ~= nil and preparedGood.policy.prepared == true, "setup Prepared same-session lastGood")

-- Partial capture: identifiable different item in one slot, other slots blank/copied.
inventoryByUnit.raid1 = fillAlternateKit()
inventoryByUnit.raid1[INVSLOT_TRINKET2] = nil
local partialChanged = inspectReadyOnce(state, memberId, guid)
assertEq(partialChanged.blended, true, "partial changed-item capture stays blended/non-authoritative")
assertEq(state.lastGood[memberId], nil, "reliable changed equipped item retires contradicted same-session lastGood")
assertEq(preparedPlayer.lastGood, nil, "player-attached lastGood is cleared on reliable contradiction")
assertEq(preparedPlayer.freshObservation, nil, "player freshObservation is cleared on reliable contradiction")
CheckRun.MarkAttempt(preparedPlayer, "incomplete", true, nowTime)
preparedPlayer.technicalFailure = true
local contradictedClass = CheckRun.ClassifyPlayer(preparedPlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(
	contradictedClass.class,
	CheckRun.CLASS.INSPECTION_FAILED,
	"after reliable contradiction, failed refresh cannot reuse stale Prepared"
)
assertTrue(not contradictedClass.countsForPot, "Inspection Failed after contradiction does not count for Reward Pot")

-- Genuinely incomplete refresh with unchanged known gear still allows fallback.
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, stableGood, stablePlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(stableGood ~= nil, "stable Prepared baseline exists")
-- Temporary blank over same kit (copied evidence): no reliable contradiction.
inventoryByUnit.raid1 = fillSlotsExceptOffHand()
local tempPartial = inspectReadyOnce(state, memberId, guid)
assertEq(tempPartial.blended, true, "temporary blank over unchanged kit stays blended")
assertTrue(state.lastGood[memberId] ~= nil, "temporary blank without reliable contradiction keeps same-session lastGood")
CheckRun.MarkAttempt(stablePlayer, "incomplete", true, nowTime)
stablePlayer.technicalFailure = true
stablePlayer.freshObservation = nil
local stableFallback = CheckRun.ClassifyPlayer(stablePlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(stableFallback.class, CheckRun.CLASS.PREPARED, "incomplete refresh with unchanged known gear still uses same-session fallback")
assertEq(stableFallback.verified, CheckRun.VERIFIED.SESSION, "unchanged-gear incomplete refresh uses SESSION provenance")

-- ---------------------------------------------------------------------------
-- 14) Retries terminate; no request/timer storms after authority invalidation
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local notifyCount = 0
local originalNotify = NotifyInspect
NotifyInspect = function()
	notifyCount = notifyCount + 1
end
local timerCount = 0
C_Timer = {
	After = function(_, cb)
		timerCount = timerCount + 1
		-- Do not auto-fire callbacks; assert scheduling stays bounded.
		if type(cb) ~= "function" then
			fail("timeout callback should be a function")
		end
	end,
}

for _ = 1, 6 do
	RC:_QueueInspectForUnit("raid1", { id = memberId }, nil)
	if state.active then
		expireInspectInventoryGrace(state)
		RC:_InvalidateInspectUnit("raid1", { clearLastGood = true })
		inventoryByUnit.raid1 = fillAllSlots()
		RC:_HandleInspectReady(guid)
	end
	nowTime = nowTime + 1
	-- Allow pending retry gates to elapse between forced attempts.
	local cacheEntry = state.cache[memberId]
	if cacheEntry then
		cacheEntry.nextRetryAt = nil
	end
	local player = state.adhocRun.players[memberId]
	if player then
		player.nextPendingRetryAt = nil
	end
end
NotifyInspect = originalNotify
C_Timer = nil
assertTrue(notifyCount <= CheckRun.PER_TARGET_ATTEMPT_CAP + 2, "NotifyInspect remains bounded across invalidation retries")
assertTrue(timerCount <= notifyCount + 2, "inspect timeout timers remain bounded with NotifyInspect")
assertTrue(notifyCount >= 1, "invalidation recovery still issues at least one inspect")

-- ---------------------------------------------------------------------------
-- 15) Fresh below-minimum item level on partial inspect retires Prepared
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
enableMinimumItemLevel(state, 690)
inspectItemLevel = 700
local _, ilvlPreparedGood, ilvlPreparedPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(ilvlPreparedGood ~= nil and ilvlPreparedGood.policy.prepared == true, "item-level baseline is Prepared")

-- Partial refresh: fresh IL below minimum, unrelated slot still unresolved.
inspectItemLevel = 640
inventoryByUnit.raid1 = fillAllSlots()
inventoryByUnit.raid1[INVSLOT_TRINKET2] = nil
local lowIlvlPartial = inspectReadyOnce(state, memberId, guid)
assertEq(lowIlvlPartial.blended, true, "low item-level partial capture stays blended/incomplete")
assertEq(state.lastGood[memberId], nil, "fresh below-minimum item level retires contradicted Prepared lastGood")
assertEq(ilvlPreparedPlayer.lastGood, nil, "player-attached lastGood cleared on fresh item-level contradiction")
assertEq(ilvlPreparedPlayer.freshObservation, nil, "player freshObservation cleared on fresh item-level contradiction")
CheckRun.MarkAttempt(ilvlPreparedPlayer, "incomplete", true, nowTime)
ilvlPreparedPlayer.technicalFailure = true
local lowIlvlClass = CheckRun.ClassifyPlayer(ilvlPreparedPlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(
	lowIlvlClass.class,
	CheckRun.CLASS.INSPECTION_FAILED,
	"partial low item-level contradiction does not award stale Prepared"
)
assertTrue(not lowIlvlClass.countsForPot, "item-level contradiction Inspection Failed does not count for Reward Pot")
assertTrue(
	lowIlvlClass.class ~= CheckRun.CLASS.UNPREPARED,
	"partial capture with one known violation is not fabricated complete Unprepared"
)

-- ---------------------------------------------------------------------------
-- 16) Same-ID confirmed missing gem on partial inspect retires Prepared
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
local chestId = 1000 + INVSLOT_CHEST
socketCountByItemId[chestId] = 1
local gemmedKit = fillAllSlots()
gemmedKit[INVSLOT_CHEST] = slotLink(INVSLOT_CHEST, chestId, { gem = "240967" })
inventoryByUnit.raid1 = gemmedKit
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, gemPreparedGood, gemPreparedPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(gemPreparedGood ~= nil and gemPreparedGood.policy.prepared == true, "gemmed baseline is Prepared")
assertTrue(
	gemPreparedGood.observation.slotsByInventory[INVSLOT_CHEST]
		and #(gemPreparedGood.observation.slotsByInventory[INVSLOT_CHEST].sockets or {}) == 1
		and gemPreparedGood.observation.slotsByInventory[INVSLOT_CHEST].sockets[1].filled == true,
	"baseline chest socket is recorded as filled"
)

-- Same chest item ID, fully resolved empty socket, unrelated slot incomplete.
local missingGemKit = fillAllSlots()
missingGemKit[INVSLOT_CHEST] = slotLink(INVSLOT_CHEST, chestId, { gem = "" })
missingGemKit[INVSLOT_TRINKET2] = nil
inventoryByUnit.raid1 = missingGemKit
local missingGemPartial = inspectReadyOnce(state, memberId, guid)
assertEq(missingGemPartial.blended, true, "missing-gem partial capture stays blended")
assertEq(state.lastGood[memberId], nil, "confirmed missing required gem retires contradicted Prepared lastGood")
assertEq(gemPreparedPlayer.freshObservation, nil, "missing-gem contradiction clears player freshObservation")
CheckRun.MarkAttempt(gemPreparedPlayer, "incomplete", true, nowTime)
gemPreparedPlayer.technicalFailure = true
local missingGemClass = CheckRun.ClassifyPlayer(gemPreparedPlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(
	missingGemClass.class,
	CheckRun.CLASS.INSPECTION_FAILED,
	"partial missing-gem contradiction does not award stale Prepared"
)
assertTrue(not missingGemClass.countsForPot, "missing-gem contradiction does not award Reward Pot credit")

-- Control: still-loading gem/link stub must not invent a contradiction.
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
socketCountByItemId[chestId] = 1
inventoryByUnit.raid1 = gemmedKit
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, stubBaselineGood, stubBaselinePlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(stubBaselineGood ~= nil, "stub-control baseline Prepared exists")
local stubKit = fillAllSlots()
stubKit[INVSLOT_CHEST] = slotLinkStub(INVSLOT_CHEST, chestId)
stubKit[INVSLOT_TRINKET2] = nil
inventoryByUnit.raid1 = stubKit
local stubPartial = inspectReadyOnce(state, memberId, guid)
assertEq(stubPartial.blended, true, "incomplete chest stub partial stays blended")
assertTrue(state.lastGood[memberId] ~= nil, "incomplete gem/link stub without reliable contradiction keeps lastGood")
CheckRun.MarkAttempt(stubBaselinePlayer, "incomplete", true, nowTime)
stubBaselinePlayer.technicalFailure = true
stubBaselinePlayer.freshObservation = nil
local stubFallback = CheckRun.ClassifyPlayer(stubBaselinePlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(stubFallback.class, CheckRun.CLASS.PREPARED, "incomplete link/gem stub still allows same-session fallback")
assertEq(stubFallback.verified, CheckRun.VERIFIED.SESSION, "stub-control fallback uses SESSION provenance")

-- ---------------------------------------------------------------------------
-- 17) Same-ID resolved enchant change during grace invalidates authority
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
local fingerId = 1000 + INVSLOT_FINGER1
-- Non-zero gem *field* keeps enchant=0 links from looking like TWW stubs, but
-- do not register socket counts so Policy does not require limited gems.
local enchantedKit = fillAllSlots()
enchantedKit[INVSLOT_FINGER1] = slotLink(INVSLOT_FINGER1, fingerId, { enchant = 1, gem = "" })
inventoryByUnit.raid1 = enchantedKit
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, enchantGood, enchantPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(enchantGood ~= nil and enchantGood.policy.prepared == true, "same-ID enchant baseline is Prepared")
enchantPlayer.freshObservation = {
	complete = true,
	policy = enchantGood.policy,
	observation = enchantGood.observation,
	capturedAt = enchantGood.capturedAt,
}

beginAdhocInspect(state, memberId, guid)
local enchantGraceGeneration = state.active.equipmentAuthorityGeneration
assertTrue(RC:_IsWithinInspectInventoryGrace("raid1", nowTime), "same-ID enchant change is inside inventory grace")
-- Same base item ID; resolved live link lost the required enchant.
inventoryByUnit.raid1 = fillAllSlots()
inventoryByUnit.raid1[INVSLOT_FINGER1] = slotLink(INVSLOT_FINGER1, fingerId, { enchant = 0, gem = "1" })
RC:_InvalidateInspectUnit("raid1")
assertEq(state.lastGood[memberId], nil, "same-ID resolved enchant loss during grace clears lastGood")
assertEq(enchantPlayer.freshObservation, nil, "same-ID enchant loss during grace clears freshObservation")
assertTrue(
	RC:_CurrentEquipmentAuthorityGeneration({ guid, memberId }) > enchantGraceGeneration,
	"same-ID enchant loss during grace bumps equipment authority generation"
)
assertEq(
	RC:_InspectRequestHasEquipmentAuthority(state.active),
	false,
	"outstanding inspect loses authority after same-ID enchant loss in grace"
)

-- Obsolete ready with the old enchanted payload must not restore authority.
inventoryByUnit.raid1 = enchantedKit
RC:_HandleInspectReady(guid)
assertEq(state.lastGood[memberId], nil, "obsolete ready after same-ID grace change does not restore lastGood")
assertEq(state.cache[memberId].authorityInvalidated, true, "obsolete ready after same-ID grace change is non-authoritative")

-- Fresh retry recovers the post-change (Unprepared) observation.
nowTime = nowTime + 1
inventoryByUnit.raid1 = fillAllSlots()
inventoryByUnit.raid1[INVSLOT_FINGER1] = slotLink(INVSLOT_FINGER1, fingerId, { enchant = 0, gem = "1" })
local _, postEnchantGood, postEnchantPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(postEnchantGood ~= nil, "fresh inspect after same-ID enchant change writes lastGood")
assertTrue(
	postEnchantGood.policy and postEnchantGood.policy.prepared == false,
	"fresh inspect after enchant loss is Unprepared rather than stale Prepared"
)
assertTrue(
	postEnchantPlayer.freshObservation and postEnchantPlayer.freshObservation.complete == true,
	"fresh inspect after same-ID enchant change sets fresh complete observation"
)

-- Ordinary inspect-driven inventory event without a proven change still completes.
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, noise2Good = inspectReadyOnce(state, memberId, guid)
assertTrue(noise2Good ~= nil, "ordinary-noise baseline writes lastGood")
beginAdhocInspect(state, memberId, guid)
local noise2Generation = state.active.equipmentAuthorityGeneration
RC:_InvalidateInspectUnit("raid1")
assertEq(
	RC:_CurrentEquipmentAuthorityGeneration({ guid, memberId }),
	noise2Generation,
	"ordinary inspect-driven inventory event without proven change does not bump authority"
)
assertTrue(state.lastGood[memberId] ~= nil, "ordinary inspect-driven inventory event keeps lastGood")
RC:_HandleInspectReady(guid)
assertTrue(state.lastGood[memberId] ~= nil, "ordinary inspect completes after inspect-driven inventory event")
assertTrue(
	state.adhocRun.players[memberId].freshObservation
		and state.adhocRun.players[memberId].freshObservation.complete == true,
	"ordinary inspect after inventory event sets fresh complete observation"
)

-- ---------------------------------------------------------------------------
-- 18) Symmetric invalidation: confirmed Unprepared fixes retire stale fallback
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
local fingerIdFix = 1000 + INVSLOT_FINGER1
local missingEnchantKit = fillAllSlots()
missingEnchantKit[INVSLOT_FINGER1] = slotLink(INVSLOT_FINGER1, fingerIdFix, { enchant = 0, gem = "1" })
inventoryByUnit.raid1 = missingEnchantKit
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, unpreparedEnchantGood, unpreparedEnchantPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(unpreparedEnchantGood ~= nil, "missing-enchant baseline writes lastGood")
assertEq(unpreparedEnchantGood.policy and unpreparedEnchantGood.policy.prepared, false, "missing-enchant baseline is Unprepared")
assertEq(unpreparedEnchantGood.policy and unpreparedEnchantGood.policy.complete, true, "missing-enchant baseline is complete")

-- Partial follow-up independently confirms the enchant is restored; other slot unresolved.
inventoryByUnit.raid1 = fillAllSlots()
inventoryByUnit.raid1[INVSLOT_FINGER1] = slotLink(INVSLOT_FINGER1, fingerIdFix, { enchant = 1, gem = "" })
inventoryByUnit.raid1[INVSLOT_TRINKET2] = nil
local fixedEnchantPartial = inspectReadyOnce(state, memberId, guid)
assertEq(fixedEnchantPartial.blended, true, "enchant-fix partial capture stays blended/incomplete")
assertEq(state.lastGood[memberId], nil, "confirmed enchant fix retires contradicted Unprepared lastGood")
assertEq(unpreparedEnchantPlayer.freshObservation, nil, "enchant fix clears player freshObservation")
CheckRun.MarkAttempt(unpreparedEnchantPlayer, "timeout", true, nowTime)
unpreparedEnchantPlayer.technicalFailure = true
unpreparedEnchantPlayer.currentlyInspectable = false
unpreparedEnchantPlayer.rangeOnlyFailure = true
local afterEnchantFix = CheckRun.ClassifyPlayer(
	unpreparedEnchantPlayer,
	nowTime,
	state.lastGood[memberId],
	"SES-A"
)
assertEq(
	afterEnchantFix.class,
	CheckRun.CLASS.INSPECTION_FAILED,
	"after confirmed enchant fix, incomplete/timeout does not reuse stale Unprepared"
)
assertTrue(not afterEnchantFix.countsForPot, "stale Unprepared after enchant fix does not deduct Reward Pot")

-- Gem fix (same-ID) retires Unprepared; unresolved control keeps fallback.
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
local chestIdFix = 1000 + INVSLOT_CHEST
socketCountByItemId[chestIdFix] = 1
local missingGemBaseline = fillAllSlots()
missingGemBaseline[INVSLOT_CHEST] = slotLink(INVSLOT_CHEST, chestIdFix, { gem = "" })
inventoryByUnit.raid1 = missingGemBaseline
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, unpreparedGemGood, unpreparedGemPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(unpreparedGemGood ~= nil and unpreparedGemGood.policy.prepared == false, "missing-gem baseline is Unprepared")

local fixedGemPartialKit = fillAllSlots()
fixedGemPartialKit[INVSLOT_CHEST] = slotLink(INVSLOT_CHEST, chestIdFix, { gem = "240967" })
fixedGemPartialKit[INVSLOT_TRINKET2] = nil
inventoryByUnit.raid1 = fixedGemPartialKit
local fixedGemPartial = inspectReadyOnce(state, memberId, guid)
assertEq(fixedGemPartial.blended, true, "gem-fix partial capture stays blended")
assertEq(state.lastGood[memberId], nil, "confirmed gem fill retires contradicted Unprepared lastGood")
CheckRun.MarkAttempt(unpreparedGemPlayer, "incomplete", true, nowTime)
unpreparedGemPlayer.technicalFailure = true
local afterGemFix = CheckRun.ClassifyPlayer(unpreparedGemPlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(afterGemFix.class, CheckRun.CLASS.INSPECTION_FAILED, "after gem fix, incomplete refresh is not stale Unprepared")

-- Item-level restore with fresh value retires Unprepared.
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = fillAllSlots()
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
enableMinimumItemLevel(state, 690)
inspectItemLevel = 640
local _, lowIlvlUnprepared, lowIlvlPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(lowIlvlUnprepared ~= nil and lowIlvlUnprepared.policy.prepared == false, "low item-level baseline is Unprepared")
inspectItemLevel = 700
inventoryByUnit.raid1 = fillAllSlots()
inventoryByUnit.raid1[INVSLOT_TRINKET2] = nil
local fixedIlvlPartial = inspectReadyOnce(state, memberId, guid)
assertEq(fixedIlvlPartial.blended, true, "item-level fix partial stays blended")
assertEq(state.lastGood[memberId], nil, "fresh restored item level retires contradicted Unprepared lastGood")
CheckRun.MarkAttempt(lowIlvlPlayer, "timeout", true, nowTime)
lowIlvlPlayer.technicalFailure = true
local afterIlvlFix = CheckRun.ClassifyPlayer(lowIlvlPlayer, nowTime, state.lastGood[memberId], "SES-A")
assertEq(afterIlvlFix.class, CheckRun.CLASS.INSPECTION_FAILED, "after item-level fix, timeout is not stale Unprepared")

-- Unresolved stub after Unprepared does not invent a correction.
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = missingEnchantKit
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
local _, keepUnpreparedGood, keepUnpreparedPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(keepUnpreparedGood ~= nil and keepUnpreparedGood.policy.prepared == false, "unresolved-control Unprepared baseline exists")
local unresolvedFixKit = fillAllSlots()
unresolvedFixKit[INVSLOT_FINGER1] = slotLinkStub(INVSLOT_FINGER1, fingerIdFix)
unresolvedFixKit[INVSLOT_TRINKET2] = nil
inventoryByUnit.raid1 = unresolvedFixKit
local unresolvedPartial = inspectReadyOnce(state, memberId, guid)
assertEq(unresolvedPartial.blended, true, "unresolved stub partial stays blended")
assertTrue(state.lastGood[memberId] ~= nil, "unresolved stub without proven correction keeps Unprepared lastGood")
CheckRun.MarkAttempt(keepUnpreparedPlayer, "incomplete", true, nowTime)
keepUnpreparedPlayer.technicalFailure = true
keepUnpreparedPlayer.freshObservation = nil
local keepUnpreparedClass = CheckRun.ClassifyPlayer(
	keepUnpreparedPlayer,
	nowTime,
	state.lastGood[memberId],
	"SES-A"
)
assertEq(keepUnpreparedClass.class, CheckRun.CLASS.UNPREPARED, "unresolved stub still allows legitimate Unprepared fallback")
assertEq(keepUnpreparedClass.verified, CheckRun.VERIFIED.SESSION, "preserved Unprepared fallback uses SESSION provenance")

-- ---------------------------------------------------------------------------
-- 19) First-inspect grace evidence reconciled with conflicting ready payload
-- ---------------------------------------------------------------------------
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
-- No cache / lastGood: stamp an empty-baseline first inspect.
inventoryByUnit.raid1 = {}
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
beginAdhocInspect(state, memberId, guid)
assertTrue(next(state.active.equipmentBaselineBySlot or {}) == nil, "first inspect has empty equipment baseline")
assertEq(state.lastGood[memberId], nil, "first inspect has no lastGood")
assertTrue(RC:_IsWithinInspectInventoryGrace("raid1", nowTime), "first inspect is inside inventory grace")

-- Credible grace-time kit A.
inventoryByUnit.raid1 = fillAlternateKit()
RC:_InvalidateInspectUnit("raid1")
assertEq(state.lastGood[memberId], nil, "first-inspect grace retain does not invent lastGood")
assertTrue(
	state.active.graceReliableEquipmentBySlot
		and next(state.active.graceReliableEquipmentBySlot) ~= nil,
	"first-inspect grace retains reliable slot evidence on the request"
)
assertEq(
	RC:_InspectRequestHasEquipmentAuthority(state.active),
	true,
	"first-inspect grace retain without conflict keeps request authority"
)

-- Conflicting ready-time kit B must not become authoritative.
inventoryByUnit.raid1 = fillAllSlots()
RC:_HandleInspectReady(guid)
assertEq(state.lastGood[memberId], nil, "conflicting first-inspect ready does not write lastGood")
assertEq(state.cache[memberId].authorityInvalidated, true, "conflicting first-inspect ready is authority-invalidated")
local firstConflictPlayer = state.adhocRun.players[memberId]
assertTrue(
	not (firstConflictPlayer.freshObservation and firstConflictPlayer.freshObservation.complete == true),
	"conflicting first-inspect ready does not set complete freshObservation"
)

-- Fresh subsequent inspect recovers.
nowTime = nowTime + 1
inventoryByUnit.raid1 = fillAllSlots()
local _, recoveredFirstGood, recoveredFirstPlayer = inspectReadyOnce(state, memberId, guid)
assertTrue(recoveredFirstGood ~= nil, "fresh inspect after first-inspect conflict writes lastGood")
assertTrue(
	recoveredFirstPlayer.freshObservation and recoveredFirstPlayer.freshObservation.complete == true,
	"fresh inspect after first-inspect conflict sets fresh complete observation"
)

-- Benign first-inspect inventory notification still completes.
resetState()
setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
state = RC:_GetInspectState()
inventoryByUnit.raid1 = {}
state.adhocRun = CheckRun.NewRun({
	targetIds = { memberId },
	expectedSessionId = "SES-A",
	now = nowTime,
})
beginAdhocInspect(state, memberId, guid)
inventoryByUnit.raid1 = fillAllSlots()
RC:_InvalidateInspectUnit("raid1")
assertTrue(
	state.active.graceReliableEquipmentBySlot
		and next(state.active.graceReliableEquipmentBySlot) ~= nil,
	"benign first-inspect grace retains matching kit evidence"
)
RC:_HandleInspectReady(guid)
assertTrue(state.lastGood[memberId] ~= nil, "benign first-inspect inventory notification still completes authoritatively")
assertTrue(
	state.adhocRun.players[memberId].freshObservation
		and state.adhocRun.players[memberId].freshObservation.complete == true,
	"benign first-inspect ready sets fresh complete observation"
)

-- Same-ID / item-level first-inspect grace vs ready policy contradictions.
-- Nested function keeps Lua 5.1 main-chunk local limits under control.
local function runFirstInspectSameIdGracePolicyTests()
	local fingerSameId = 1000 + INVSLOT_FINGER1
	local chestSameId = 1000 + INVSLOT_CHEST

	-- Same base item ID, grace/ready disagree on required enchant → reject authority.
	resetState()
	setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
	local localState = RC:_GetInspectState()
	inventoryByUnit.raid1 = {}
	localState.adhocRun = CheckRun.NewRun({
		targetIds = { memberId },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	beginAdhocInspect(localState, memberId, guid)
	local graceEnchantKit = fillAllSlots()
	graceEnchantKit[INVSLOT_FINGER1] = slotLink(INVSLOT_FINGER1, fingerSameId, { enchant = 1, gem = "" })
	inventoryByUnit.raid1 = graceEnchantKit
	RC:_InvalidateInspectUnit("raid1")
	assertTrue(
		localState.active.graceReliableEquipmentBySlot
			and localState.active.graceReliableEquipmentBySlot[INVSLOT_FINGER1] ~= nil,
		"same-ID enchant grace retains finger evidence"
	)
	local readyMissingEnchantKit = fillAllSlots()
	readyMissingEnchantKit[INVSLOT_FINGER1] = slotLink(INVSLOT_FINGER1, fingerSameId, { enchant = 0, gem = "1" })
	inventoryByUnit.raid1 = readyMissingEnchantKit
	RC:_HandleInspectReady(guid)
	assertEq(localState.lastGood[memberId], nil, "same-ID enchant grace/ready conflict does not write lastGood")
	assertEq(
		localState.cache[memberId].authorityInvalidated,
		true,
		"same-ID enchant grace/ready conflict rejects ready authority"
	)
	assertTrue(
		not (
			localState.adhocRun.players[memberId].freshObservation
			and localState.adhocRun.players[memberId].freshObservation.complete == true
		),
		"same-ID enchant conflict does not set complete freshObservation"
	)
	nowTime = nowTime + 1
	inventoryByUnit.raid1 = readyMissingEnchantKit
	local _, recoveredEnchantGood, recoveredEnchantPlayer = inspectReadyOnce(localState, memberId, guid)
	assertTrue(recoveredEnchantGood ~= nil, "fresh inspect recovers after same-ID enchant grace conflict")
	assertTrue(
		recoveredEnchantPlayer.freshObservation and recoveredEnchantPlayer.freshObservation.complete == true,
		"recovery after same-ID enchant conflict sets fresh complete observation"
	)
	assertEq(
		recoveredEnchantGood.policy and recoveredEnchantGood.policy.prepared,
		false,
		"recovery after enchant conflict reflects the missing-enchant kit"
	)

	-- Same-ID gem-state disagreement → reject authority.
	resetState()
	setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
	localState = RC:_GetInspectState()
	socketCountByItemId[chestSameId] = 1
	inventoryByUnit.raid1 = {}
	localState.adhocRun = CheckRun.NewRun({
		targetIds = { memberId },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	beginAdhocInspect(localState, memberId, guid)
	local graceGemKit = fillAllSlots()
	graceGemKit[INVSLOT_CHEST] = slotLink(INVSLOT_CHEST, chestSameId, { gem = "240967" })
	inventoryByUnit.raid1 = graceGemKit
	RC:_InvalidateInspectUnit("raid1")
	local readyEmptyGemKit = fillAllSlots()
	readyEmptyGemKit[INVSLOT_CHEST] = slotLink(INVSLOT_CHEST, chestSameId, { gem = "" })
	inventoryByUnit.raid1 = readyEmptyGemKit
	RC:_HandleInspectReady(guid)
	assertEq(localState.lastGood[memberId], nil, "same-ID gem grace/ready conflict does not write lastGood")
	assertEq(localState.cache[memberId].authorityInvalidated, true, "same-ID gem grace/ready conflict rejects ready authority")

	-- Fresh item levels on opposite sides of the configured minimum → reject.
	resetState()
	setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
	localState = RC:_GetInspectState()
	inventoryByUnit.raid1 = {}
	localState.adhocRun = CheckRun.NewRun({
		targetIds = { memberId },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	enableMinimumItemLevel(localState, 690)
	beginAdhocInspect(localState, memberId, guid)
	inspectItemLevel = 700
	inventoryByUnit.raid1 = fillAllSlots()
	RC:_InvalidateInspectUnit("raid1")
	assertEq(localState.active.graceFreshItemLevel, 700, "grace retains fresh item level above minimum")
	inspectItemLevel = 640
	RC:_HandleInspectReady(guid)
	assertEq(localState.lastGood[memberId], nil, "item-level grace/ready conflict across minimum does not write lastGood")
	assertEq(
		localState.cache[memberId].authorityInvalidated,
		true,
		"item-level grace/ready conflict across minimum rejects ready authority"
	)
	nowTime = nowTime + 1
	inspectItemLevel = 640
	local _, recoveredIlvlGood = inspectReadyOnce(localState, memberId, guid)
	assertTrue(recoveredIlvlGood ~= nil, "fresh inspect recovers after item-level grace conflict")
	assertEq(
		recoveredIlvlGood.policy and recoveredIlvlGood.policy.prepared,
		false,
		"recovery after IL conflict is Unprepared below minimum"
	)

	-- Incomplete grace metadata must not falsely invalidate a matching ready kit.
	resetState()
	setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
	localState = RC:_GetInspectState()
	inventoryByUnit.raid1 = {}
	localState.adhocRun = CheckRun.NewRun({
		targetIds = { memberId },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	beginAdhocInspect(localState, memberId, guid)
	-- Manually retain only a stub link as "grace" evidence (would not normally be
	-- filtered in, but guards against incomplete comparisons if present).
	localState.active.graceReliableEquipmentBySlot = {
		[INVSLOT_FINGER1] = {
			link = slotLinkStub(INVSLOT_FINGER1, fingerSameId),
			itemId = fingerSameId,
			hasItem = true,
			texture = "Interface\\Icons\\INV_Misc_QuestionMark",
		},
	}
	localState.active.inventoryObservedDuringGrace = true
	inventoryByUnit.raid1 = fillAllSlots()
	RC:_HandleInspectReady(guid)
	assertTrue(
		localState.lastGood[memberId] ~= nil,
		"incomplete grace stub metadata does not falsely invalidate a valid ready inspection"
	)
	assertTrue(
		localState.adhocRun.players[memberId].freshObservation
			and localState.adhocRun.players[memberId].freshObservation.complete == true,
		"valid ready after incomplete grace stub remains authoritative"
	)

	-- Matching resolved grace/ready observations remain authoritative (control).
	resetState()
	setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
	localState = RC:_GetInspectState()
	inventoryByUnit.raid1 = {}
	localState.adhocRun = CheckRun.NewRun({
		targetIds = { memberId },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	beginAdhocInspect(localState, memberId, guid)
	inspectItemLevel = 700
	inventoryByUnit.raid1 = fillAllSlots()
	RC:_InvalidateInspectUnit("raid1")
	RC:_HandleInspectReady(guid)
	assertTrue(localState.lastGood[memberId] ~= nil, "matching resolved grace/ready observations remain authoritative")
	assertEq(
		localState.cache[memberId].authorityInvalidated ~= true,
		true,
		"matching resolved grace/ready does not mark cache authorityInvalidated"
	)

	-- Grace retains only a valid fresh item level (no resolved links); ready
	-- crosses the configured minimum → reject authority.
	resetState()
	setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
	localState = RC:_GetInspectState()
	inventoryByUnit.raid1 = {}
	localState.adhocRun = CheckRun.NewRun({
		targetIds = { memberId },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	enableMinimumItemLevel(localState, 690)
	beginAdhocInspect(localState, memberId, guid)
	inspectItemLevel = 700
	-- No resolved links during grace; only the fresh item-level reading is retained.
	inventoryByUnit.raid1 = {}
	RC:_InvalidateInspectUnit("raid1")
	assertEq(
		localState.active.graceReliableEquipmentBySlot == nil
			or next(localState.active.graceReliableEquipmentBySlot) == nil,
		true,
		"grace with unresolved links retains no slot map"
	)
	assertEq(localState.active.graceFreshItemLevel, 700, "grace retains fresh item level without resolved links")
	inspectItemLevel = 640
	inventoryByUnit.raid1 = fillAllSlots()
	RC:_HandleInspectReady(guid)
	assertEq(localState.lastGood[memberId], nil, "IL-only grace conflict does not write lastGood")
	assertEq(
		localState.cache[memberId].authorityInvalidated,
		true,
		"IL-only grace conflict rejects ready authority"
	)
	assertTrue(
		not (
			localState.adhocRun.players[memberId].freshObservation
			and localState.adhocRun.players[memberId].freshObservation.complete == true
		),
		"IL-only grace conflict does not set complete freshObservation"
	)
	CheckRun.MarkAttempt(localState.adhocRun.players[memberId], "incomplete", true, nowTime)
	localState.adhocRun.players[memberId].technicalFailure = true
	local ilOnlyClass = CheckRun.ClassifyPlayer(
		localState.adhocRun.players[memberId],
		nowTime,
		localState.lastGood[memberId],
		"SES-A"
	)
	assertEq(
		ilOnlyClass.class,
		CheckRun.CLASS.INSPECTION_FAILED,
		"IL-only grace conflict cannot award Prepared/Unprepared from rejected ready"
	)
	assertTrue(not ilOnlyClass.countsForPot, "IL-only grace conflict does not count for Reward Pot")
	nowTime = nowTime + 1
	inspectItemLevel = 640
	inventoryByUnit.raid1 = fillAllSlots()
	local _, recoveredIlOnlyGood, recoveredIlOnlyPlayer = inspectReadyOnce(localState, memberId, guid)
	assertTrue(recoveredIlOnlyGood ~= nil, "fresh inspect recovers after IL-only grace conflict")
	assertTrue(
		recoveredIlOnlyPlayer.freshObservation and recoveredIlOnlyPlayer.freshObservation.complete == true,
		"recovery after IL-only grace conflict sets fresh complete observation"
	)

	-- Matching item-level control: grace IL-only 700, ready 700 stays authoritative.
	resetState()
	setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
	localState = RC:_GetInspectState()
	inventoryByUnit.raid1 = {}
	localState.adhocRun = CheckRun.NewRun({
		targetIds = { memberId },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	enableMinimumItemLevel(localState, 690)
	beginAdhocInspect(localState, memberId, guid)
	inspectItemLevel = 700
	inventoryByUnit.raid1 = {}
	RC:_InvalidateInspectUnit("raid1")
	assertEq(localState.active.graceFreshItemLevel, 700, "matching IL-only control retains grace item level")
	inspectItemLevel = 700
	inventoryByUnit.raid1 = fillAllSlots()
	RC:_HandleInspectReady(guid)
	assertTrue(localState.lastGood[memberId] ~= nil, "matching IL-only grace/ready remains authoritative")
	assertEq(
		localState.cache[memberId].authorityInvalidated ~= true,
		true,
		"matching IL-only grace/ready does not mark authorityInvalidated"
	)

	-- Missing grace item-level control: no graceFreshItemLevel, ready below minimum
	-- still completes normally (no fabricated grace contradiction).
	resetState()
	setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
	localState = RC:_GetInspectState()
	inventoryByUnit.raid1 = {}
	localState.adhocRun = CheckRun.NewRun({
		targetIds = { memberId },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	enableMinimumItemLevel(localState, 690)
	beginAdhocInspect(localState, memberId, guid)
	assertEq(localState.active.graceFreshItemLevel, nil, "missing-level control starts with no grace item level")
	inspectItemLevel = 640
	inventoryByUnit.raid1 = fillAllSlots()
	RC:_HandleInspectReady(guid)
	assertTrue(localState.lastGood[memberId] ~= nil, "missing grace item level does not invent a contradiction")
	assertEq(
		localState.lastGood[memberId].policy and localState.lastGood[memberId].policy.prepared,
		false,
		"missing-level control ready below minimum is Unprepared"
	)

	state = localState
end
runFirstInspectSameIdGracePolicyTests()

-- ---------------------------------------------------------------------------
-- 20) GetCachedEquipmentReadiness hides authority-invalidated captures
-- ---------------------------------------------------------------------------
local function runCachedReadinessAuthorityTests()
	local fingerId = 1000 + INVSLOT_FINGER1
	resetState()
	setMainHandIdentity("INVTYPE_WEAPONMAINHAND", 2, 7)
	local localState = RC:_GetInspectState()
	inventoryByUnit.raid1 = fillAllSlots()
	localState.adhocRun = CheckRun.NewRun({
		targetIds = { memberId },
		expectedSessionId = "SES-A",
		now = nowTime,
	})
	local _, readyCacheGood = inspectReadyOnce(localState, memberId, guid)
	assertTrue(readyCacheGood ~= nil, "readiness valid-cache baseline exists")
	local validReadiness = RC:GetCachedEquipmentReadiness("raid1", memberId)
	assertEq(validReadiness.state, "ready", "valid authoritative cache yields Ready")

	-- Populate a complete but authority-invalidated cache (troubleshooting retained).
	localState.cache[memberId].authorityInvalidated = true
	localState.lastGood[memberId] = nil
	local invalidatedReadiness = RC:GetCachedEquipmentReadiness("raid1", memberId)
	assertEq(
		invalidatedReadiness.state,
		"unknown",
		"authority-invalidated complete cache yields Unknown readiness"
	)

	-- Non-invalidated blended known-Unprepared remains usable as Not Ready.
	-- Alias keys (guid + memberId) must reference the same entry object.
	local blendedSlots = {}
	for _, slot in ipairs(TRACKED_SLOTS) do
		blendedSlots[slot] = {
			link = slotLink(slot),
			itemId = 1000 + slot,
			texture = "Interface\\Icons\\INV_Misc_QuestionMark",
			hasItem = true,
		}
	end
	blendedSlots[INVSLOT_FINGER1] = {
		link = slotLink(INVSLOT_FINGER1, fingerId, { enchant = 0, gem = "1" }),
		itemId = fingerId,
		texture = "Interface\\Icons\\INV_Misc_QuestionMark",
		hasItem = true,
		copiedEvidence = false,
	}
	local blendedEntry = {
		guid = guid,
		id = memberId,
		status = "ready",
		updatedAt = nowTime,
		capturedAt = nowTime,
		overallEquippedItemLevel = 700,
		averageItemLevel = 700,
		slotsByInventory = blendedSlots,
		blended = true,
		authorityInvalidated = false,
		aliases = { guid, memberId },
	}
	localState.cache[memberId] = blendedEntry
	localState.cache[guid] = blendedEntry
	local blendedReadiness = RC:GetCachedEquipmentReadiness("raid1", memberId)
	assertEq(
		blendedReadiness.state,
		"not_ready",
		"blended non-invalidated known-Unprepared remains Not Ready"
	)

	-- RosterModel readiness consumer reflects Unknown for invalidated cache.
	local rosterChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/RosterModel.lua"))
	rosterChunk("SpectrumFederation", SF)
	SF.LootHelperWindow = SF.LootHelperWindow or {}
	local Model = SF.LootHelperWindow.RosterModel
	assertTrue(Model and type(Model.Build) == "function", "RosterModel loads for readiness consumer check")
	blendedEntry.authorityInvalidated = true
	blendedEntry.blended = false
	local rosterReadiness = RC:GetCachedEquipmentReadiness("raid1", memberId)
	assertEq(rosterReadiness.state, "unknown", "Loot Helper roster readiness source is Unknown for invalidated cache")
	state = localState
end
runCachedReadinessAuthorityTests()

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
	os.exit(1)
end
