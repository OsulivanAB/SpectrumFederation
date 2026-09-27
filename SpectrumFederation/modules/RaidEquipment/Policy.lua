-- Current-Retail Raid Equipment policy.
-- Enchant and gem rules are addon-owned. Minimum item level is the profile-configured exception.
-- luacheck: globals GetItemInfoInstant C_Item

local _, SF = ...

SF.RaidEquipment = SF.RaidEquipment or {}
local Policy = {}
SF.RaidEquipment.Policy = Policy

Policy.INVSLOT = {
	HEAD = 1,
	NECK = 2,
	SHOULDER = 3,
	CHEST = 5,
	WAIST = 6,
	LEGS = 7,
	FEET = 8,
	WRIST = 9,
	HANDS = 10,
	FINGER1 = 11,
	FINGER2 = 12,
	TRINKET1 = 13,
	TRINKET2 = 14,
	BACK = 15,
	MAINHAND = 16,
	OFFHAND = 17,
}

Policy.TRACKED_SLOTS = {
	{ key = "head", label = "Head", inventorySlot = Policy.INVSLOT.HEAD, enchantRequired = true },
	{ key = "neck", label = "Neck", inventorySlot = Policy.INVSLOT.NECK, enchantRequired = false },
	{ key = "shoulders", label = "Shoulders", inventorySlot = Policy.INVSLOT.SHOULDER, enchantRequired = true },
	{ key = "back", label = "Back", inventorySlot = Policy.INVSLOT.BACK, enchantRequired = false },
	{ key = "chest", label = "Chest", inventorySlot = Policy.INVSLOT.CHEST, enchantRequired = true },
	{ key = "wrist", label = "Wrist", inventorySlot = Policy.INVSLOT.WRIST, enchantRequired = false },
	{ key = "hands", label = "Gloves", inventorySlot = Policy.INVSLOT.HANDS, enchantRequired = false },
	{ key = "belt", label = "Belt", inventorySlot = Policy.INVSLOT.WAIST, enchantRequired = false },
	{ key = "legs", label = "Legs", inventorySlot = Policy.INVSLOT.LEGS, enchantRequired = true },
	{ key = "boots", label = "Boots", inventorySlot = Policy.INVSLOT.FEET, enchantRequired = true },
	{ key = "finger1", label = "Ring 1", inventorySlot = Policy.INVSLOT.FINGER1, enchantRequired = true },
	{ key = "finger2", label = "Ring 2", inventorySlot = Policy.INVSLOT.FINGER2, enchantRequired = true },
	{ key = "trinket1", label = "Trinket 1", inventorySlot = Policy.INVSLOT.TRINKET1, enchantRequired = false },
	{ key = "trinket2", label = "Trinket 2", inventorySlot = Policy.INVSLOT.TRINKET2, enchantRequired = false },
	{ key = "mainHand", label = "Main Hand", inventorySlot = Policy.INVSLOT.MAINHAND, enchantRequired = true },
	{ key = "offHand", label = "Off Hand", inventorySlot = Policy.INVSLOT.OFFHAND, enchantRequired = "weapon" },
}

Policy.LIMITED_GEM = {
	epicGemAvailable = true,
	maxEpicGems = 1,
	uniquenessCategory = "Thalassian Diamond",
	rawReagentItemIds = {
		[242712] = true, -- raw Eversong Diamond crafting reagent
	},
	-- Socketable Midnight Eversong Diamond cuts and quality variants confirmed
	-- from Wowhead item pages (240966-240971, 240982-240983). The uniqueness
	-- category Thalassian Diamond is a secondary recognizer. In-game verification
	-- of every quality rank remains listed as manual QA.
	itemIds = {
		[240966] = true, -- Powerful Eversong Diamond
		[240967] = true, -- Powerful Eversong Diamond (quality variant)
		[240968] = true, -- Telluric Eversong Diamond
		[240969] = true, -- Telluric Eversong Diamond (quality variant)
		[240970] = true, -- Stoic Eversong Diamond
		[240971] = true, -- Stoic Eversong Diamond (quality variant)
		[240982] = true, -- Indecipherable Eversong Diamond
		[240983] = true, -- Indecipherable Eversong Diamond (quality variant)
	},
}

-- Whole-number raid thresholds. Wide enough that a later season does not overflow the setting.
local MIN_ITEM_LEVEL = 0
local MAX_ITEM_LEVEL = 99999

local LEGACY_ENCHANT_GEM_PRE = "Spectrum Federation: You're missing the following enchants/gems: {missing}."
local LEGACY_ENCHANT_GEM_RAID = "Spectrum Federation: You're missing the following enchants/gems: {missing}. No new {point_name} awarded."

-- One decimal matches the character sheet. Comparison and display both use this
-- value so a rounded label cannot disagree with Prepared/Unprepared.
function Policy.CanonicalOverallItemLevel(value)
	local number = tonumber(value)
	if not number or number <= 0 then
		return nil
	end
	local scaled = number * 10
	local rounded
	if scaled >= 0 then
		rounded = math.floor(scaled + 0.5)
	else
		rounded = math.ceil(scaled - 0.5)
	end
	return rounded / 10
end

-- A later inspect can return gear while GetInspectItemLevel is still missing.
-- Keep the last known Blizzard overall value in that case. A new positive
-- reading replaces it. Zero is not a usable item level.
function Policy.KeepKnownOverallItemLevel(nextValue, previousValue)
	local nextCanonical = Policy.CanonicalOverallItemLevel(nextValue)
	if nextCanonical then
		return nextCanonical
	end
	return Policy.CanonicalOverallItemLevel(previousValue)
end

function Policy.FormatOverallItemLevel(value)
	local canonical = Policy.CanonicalOverallItemLevel(value)
	if not canonical then
		return nil
	end
	local nearest = math.floor(canonical + 0.5)
	if math.abs(canonical - nearest) < 0.001 then
		return tostring(nearest)
	end
	return string.format("%.1f", canonical)
end

function Policy.NormalizeMinimumItemLevel(value)
	local number = tonumber(value)
	if not number then
		return nil
	end
	if number < MIN_ITEM_LEVEL then
		number = MIN_ITEM_LEVEL
	end
	number = math.floor(number + 0.5)
	if number > MAX_ITEM_LEVEL then
		number = MAX_ITEM_LEVEL
	end
	return number
end

function Policy.ItemLevelRequirementActive(config)
	if type(config) ~= "table" or config.requireMinimumItemLevel ~= true then
		return false
	end
	return Policy.NormalizeMinimumItemLevel(config.minimumItemLevel) ~= nil
end

function Policy.ItemLevelFailureText(itemLevel, minimum)
	local shown = Policy.FormatOverallItemLevel(itemLevel)
	local required = Policy.NormalizeMinimumItemLevel(minimum)
	if not shown or required == nil then
		return nil
	end
	return string.format("Item Level %s (%d required)", shown, required)
end

-- Live Raid Equipment warning. Unknown values and a disabled requirement do not warn.
function Policy.ShouldWarnItemLevel(itemLevel, config)
	if not Policy.ItemLevelRequirementActive(config) then
		return false
	end
	local canonical = Policy.CanonicalOverallItemLevel(itemLevel)
	if not canonical then
		return false
	end
	local minimum = Policy.NormalizeMinimumItemLevel(config.minimumItemLevel)
	return canonical < minimum
end

-- Previous default whispers named only enchants/gems. Exact matches are defaults, not customizations.
function Policy.IsLegacyEnchantGemWhisper(template, kind)
	if kind == "pre" then
		return template == LEGACY_ENCHANT_GEM_PRE
	end
	if kind == "raid" then
		return template == LEGACY_ENCHANT_GEM_RAID
	end
	return false
end

local WEAPON_EQUIP_LOCS = {
	INVTYPE_WEAPON = true,
	INVTYPE_WEAPONMAINHAND = true,
	INVTYPE_WEAPONOFFHAND = true,
	INVTYPE_2HWEAPON = true,
}

local NONWEAPON_OFFHAND_LOCS = {
	INVTYPE_SHIELD = true,
	INVTYPE_HOLDABLE = true,
	INVTYPE_RANGED = true,
	INVTYPE_RANGEDRIGHT = true,
	INVTYPE_RELIC = true,
}

function Policy.GetItemIdentity(linkOrId)
	if linkOrId == nil or not GetItemInfoInstant then
		return nil, nil, nil
	end
	local ok, _, _, _, equipLoc, _, classID, subClassID = pcall(GetItemInfoInstant, linkOrId)
	if not ok then
		return nil, nil, nil
	end
	if type(equipLoc) ~= "string" or equipLoc == "" then
		equipLoc = nil
	end
	return equipLoc, tonumber(classID), tonumber(subClassID)
end

function Policy.GetItemEquipLocation(linkOrId)
	local equipLoc = Policy.GetItemIdentity(linkOrId)
	return equipLoc
end

function Policy.IsTwoHandWeapon(equipLoc)
	return equipLoc == "INVTYPE_2HWEAPON"
end

local function RangedEquipLoc(equipLoc)
	local SpecWeapons = SF.LootHelperBis and SF.LootHelperBis.SpecWeapons
	if SpecWeapons and SpecWeapons.IsRangedEquipLoc then
		return SpecWeapons.IsRangedEquipLoc(equipLoc) and true or false
	end
	return equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT"
end

-- True when this subclass is a bow, gun, or crossbow.
-- False when the subclass is resolved and is not one of those weapons.
-- Nil when SpecWeapons or the subclass identity is unavailable.
local function ConsumingRangedWeapon(itemClass, itemSubClass)
	local SpecWeapons = SF.LootHelperBis and SF.LootHelperBis.SpecWeapons
	if not (SpecWeapons and SpecWeapons.IsTwoHandRangedWeapon) then
		return nil
	end
	if itemClass == nil or itemSubClass == nil then
		return nil
	end
	return SpecWeapons.IsTwoHandRangedWeapon(itemClass, itemSubClass) and true or false
end

function Policy.IsWeaponEquipLoc(equipLoc)
	return equipLoc ~= nil and WEAPON_EQUIP_LOCS[equipLoc] == true
end

function Policy.IsNonWeaponOffHand(equipLoc)
	return equipLoc ~= nil and NONWEAPON_OFFHAND_LOCS[equipLoc] == true
end

function Policy.RequiresOffHandEnchant(equipLoc)
	if equipLoc == nil then
		return nil
	end
	if Policy.IsWeaponEquipLoc(equipLoc) and not Policy.IsTwoHandWeapon(equipLoc) then
		return true
	end
	return false
end

local function SlotHasEquippedEvidence(slot)
	if type(slot) ~= "table" then
		return false
	end
	if slot.empty == true then
		return false
	end
	local itemId = tonumber(slot.itemId)
	if itemId and itemId > 0 then
		return true
	end
	if slot.texture then
		return true
	end
	if type(slot.link) == "string" and slot.link ~= "" then
		return true
	end
	if type(slot.itemLink) == "string" and slot.itemLink ~= "" then
		return true
	end
	return false
end

local function SlotLink(slot)
	if type(slot) ~= "table" then
		return nil
	end
	if type(slot.link) == "string" and slot.link ~= "" then
		return slot.link
	end
	if type(slot.itemLink) == "string" and slot.itemLink ~= "" then
		return slot.itemLink
	end
	return nil
end

function Policy.DescribeSlotPresence(slot)
	if type(slot) ~= "table" then
		return "unresolved", "missing_slot_table"
	end
	local link = SlotLink(slot)
	if slot.empty == true or (not SlotHasEquippedEvidence(slot) and link == nil) then
		if SlotHasEquippedEvidence(slot) then
			return "unresolved", "empty_flag_with_item_evidence"
		end
		return "empty", nil
	end
	if not SlotHasEquippedEvidence(slot) then
		return "empty", nil
	end
	if type(link) ~= "string" or link == "" then
		return "unresolved", "pending_link"
	end
	if slot.linkComplete == false then
		return "unresolved", "incomplete_link"
	end
	return "equipped", nil
end

-- Does this equipped Main Hand make an empty Off Hand legitimate?
-- True: INVTYPE_2HWEAPON, or a bow, gun, or crossbow.
-- False: the item is known not to occupy the Off Hand.
-- Nil: weapon identity has not resolved. Callers must stay incomplete.
-- INVTYPE_2HWEAPON stays spec-agnostic, including Fury Titan's Grip. A ranged
-- equip location alone is not enough, because wands use that location too.
function Policy.MainHandAllowsEmptyOffHand(slot, knownEquipLoc)
	if type(slot) ~= "table" then
		if Policy.IsTwoHandWeapon(knownEquipLoc) then
			return true
		end
		return false
	end

	local presence = Policy.DescribeSlotPresence(slot)
	if presence == "empty" then
		return false
	end
	if presence == "unresolved" then
		return nil
	end

	local equipLoc = knownEquipLoc
	if type(equipLoc) ~= "string" or equipLoc == "" then
		equipLoc = slot.equipLoc
	end
	local itemClass = tonumber(slot.itemClass)
	local itemSubClass = tonumber(slot.itemSubClass)
	if equipLoc == nil or itemClass == nil or itemSubClass == nil then
		local lookedLoc, lookedClass, lookedSub = Policy.GetItemIdentity(SlotLink(slot) or slot.itemId)
		if equipLoc == nil then
			equipLoc = lookedLoc
		end
		if itemClass == nil then
			itemClass = lookedClass
		end
		if itemSubClass == nil then
			itemSubClass = lookedSub
		end
	end

	if Policy.IsTwoHandWeapon(equipLoc) then
		return true
	end

	local consuming = ConsumingRangedWeapon(itemClass, itemSubClass)
	if consuming == true then
		return true
	end
	if RangedEquipLoc(equipLoc) then
		if consuming == nil then
			return nil
		end
		return false
	end
	if equipLoc == nil then
		return nil
	end
	return false
end

function Policy.IsQualifyingLimitedGem(gemId, uniqueness)
	gemId = tonumber(gemId)
	if not gemId or gemId == 0 then
		return nil, "unresolved"
	end
	if Policy.LIMITED_GEM.rawReagentItemIds[gemId] then
		return false, "reagent"
	end
	if Policy.LIMITED_GEM.itemIds[gemId] then
		return true, "allowlist"
	end
	if type(uniqueness) == "table" then
		local category = uniqueness.category or uniqueness.name or uniqueness[1]
		if type(category) == "string" and category:find(Policy.LIMITED_GEM.uniquenessCategory, 1, true) then
			return true, "uniqueness"
		end
		-- A successful uniqueness lookup with no category means this gem is not
		-- a Thalassian Diamond. Do not treat that as unresolved identity.
		if uniqueness.resolved == true or uniqueness.resolved == false then
			return false, "not_family"
		end
		return nil, "unresolved_uniqueness"
	end
	if uniqueness == false then
		return nil, "unresolved_uniqueness"
	end
	return nil, "unresolved_identity"
end

function Policy.LookupUniqueness(gemId)
	gemId = tonumber(gemId)
	if not gemId then
		return nil
	end
	if C_Item and C_Item.GetItemUniquenessByID then
		local ok, uniqueEquipped, category = pcall(C_Item.GetItemUniquenessByID, gemId)
		if ok and (uniqueEquipped or category) then
			return {
				resolved = true,
				uniqueEquipped = uniqueEquipped,
				category = category,
			}
		end
		if ok then
			return { resolved = false }
		end
	end
	return nil
end

local function CountSocketsAndLimitedGems(slot)
	local sockets = slot.sockets
	if type(sockets) ~= "table" then
		if slot.socketCount == nil then
			return nil, nil, nil, "unresolved_sockets"
		end
		local count = tonumber(slot.socketCount) or 0
		if count <= 0 then
			return 0, 0, 0, nil
		end
		return nil, nil, nil, "unresolved_gems"
	end

	local total = #sockets
	local filled = 0
	local limited = 0
	for i = 1, total do
		local gem = sockets[i]
		if type(gem) ~= "table" then
			return nil, nil, nil, "unresolved_gems"
		end
		local filledSocket = gem.filled
		if filledSocket == nil then
			if gem.empty == true then
				filledSocket = false
			elseif gem.empty == false then
				filledSocket = true
			end
		end
		if filledSocket == true then
			filled = filled + 1
			local gemId = gem.gemId or gem.gemItemId
			local qualifying, why = Policy.IsQualifyingLimitedGem(gemId, gem.uniqueness)
			if qualifying == nil then
				return nil, nil, nil, why or "unresolved_limited_gem"
			end
			if qualifying then
				limited = limited + 1
			end
		elseif filledSocket == false then
			-- empty socket
		else
			return nil, nil, nil, "unresolved_gems"
		end
	end
	return total, filled, limited, nil
end

function Policy.EvaluateObservation(observation, config)
	local result = {
		complete = false,
		incompleteReason = nil,
		prepared = false,
		missing = {},
		usableSockets = 0,
		limitedGems = 0,
	}

	if type(observation) ~= "table" or type(observation.slotsByInventory) ~= "table" then
		result.incompleteReason = "missing_slots"
		return result
	end

	local slots = observation.slotsByInventory
	local mainHand = slots[Policy.INVSLOT.MAINHAND]
	local mainHandLoc = observation.mainHandEquipLoc
	if mainHandLoc == nil and type(mainHand) == "table" then
		mainHandLoc = mainHand.equipLoc or Policy.GetItemEquipLocation(mainHand.link or mainHand.itemId)
	end

	local usableSockets = 0
	local limitedGems = 0

	for _, def in ipairs(Policy.TRACKED_SLOTS) do
		local slot = slots[def.inventorySlot]
		local presence, reason = Policy.DescribeSlotPresence(slot)
		if presence == "unresolved" then
			result.incompleteReason = reason or "unresolved_slot"
			return result
		end

		if presence == "empty" then
			local allowsEmptyOffHand = false
			if def.key == "offHand" then
				allowsEmptyOffHand = Policy.MainHandAllowsEmptyOffHand(mainHand, mainHandLoc)
				if allowsEmptyOffHand == nil then
					result.incompleteReason = "unresolved_mainhand_weapon"
					return result
				end
			end
			if not allowsEmptyOffHand then
				table.insert(result.missing, def.label .. " Item")
			end
		else
			local equipLoc = slot.equipLoc or Policy.GetItemEquipLocation(slot.link or slot.itemId)
			if def.key == "offHand" then
				if equipLoc == nil then
					result.incompleteReason = "unresolved_offhand_type"
					return result
				end
			end

			local needsEnchant = def.enchantRequired == true
			if def.enchantRequired == "weapon" then
				local required = Policy.RequiresOffHandEnchant(equipLoc)
				if required == nil then
					result.incompleteReason = "unresolved_offhand_type"
					return result
				end
				needsEnchant = required
			end

			if needsEnchant then
				if slot.hasEnchant == nil and slot.enchantId == nil then
					result.incompleteReason = "unresolved_enchant"
					return result
				end
				local hasEnchant = slot.hasEnchant
				if hasEnchant == nil then
					local enchantId = tonumber(slot.enchantId)
					hasEnchant = enchantId ~= nil and enchantId > 0
				end
				if not hasEnchant then
					table.insert(result.missing, def.label .. " Enchant")
				end
			end

			local socketTotal, socketFilled, socketLimited, socketErr = CountSocketsAndLimitedGems(slot)
			if socketErr then
				result.incompleteReason = socketErr
				return result
			end
			if socketTotal and socketTotal > 0 then
				usableSockets = usableSockets + socketTotal
				if socketFilled < socketTotal then
					table.insert(result.missing, def.label .. " Gem")
				end
				limitedGems = limitedGems + (socketLimited or 0)
			end
		end
	end

	result.usableSockets = usableSockets
	result.limitedGems = limitedGems
	local requiredLimited = 0
	if Policy.LIMITED_GEM.epicGemAvailable and usableSockets > 0 then
		requiredLimited = math.min(Policy.LIMITED_GEM.maxEpicGems, usableSockets)
	end
	if requiredLimited > 0 and limitedGems < requiredLimited then
		table.insert(result.missing, "Limited Gem")
	end

	-- Item level is optional profile configuration. A known low value is one more
	-- missing requirement. An unknown value makes the observation incomplete
	-- instead of Unprepared, and only when the requirement is actually active.
	if Policy.ItemLevelRequirementActive(config) then
		local canonical = Policy.CanonicalOverallItemLevel(observation.overallEquippedItemLevel)
		if not canonical then
			result.incompleteReason = "unresolved_item_level"
			return result
		end
		local minimum = Policy.NormalizeMinimumItemLevel(config.minimumItemLevel)
		if canonical < minimum then
			table.insert(result.missing, Policy.ItemLevelFailureText(canonical, minimum))
		end
	end

	result.complete = true
	result.prepared = #result.missing == 0
	return result
end

function Policy.EvaluateCompleteness(observation, config)
	local result = Policy.EvaluateObservation(observation, config)
	return {
		complete = result.complete == true,
		reason = result.incompleteReason,
	}
end

-- Map a Policy observation to the Raid Equipment glance readiness states.
-- Incomplete or missing observations stay Unknown; range/presence is not a Policy concern.
function Policy.ReadinessFromObservation(observation, config)
	if type(observation) ~= "table" then
		return {
			state = "unknown",
			missing = {},
			incompleteReason = "missing_observation",
		}
	end
	local result = Policy.EvaluateObservation(observation, config)
	if not result.complete then
		return {
			state = "unknown",
			missing = {},
			incompleteReason = result.incompleteReason,
		}
	end
	if result.prepared then
		return {
			state = "ready",
			missing = {},
			incompleteReason = nil,
		}
	end
	local missing = {}
	for i = 1, #(result.missing or {}) do
		missing[i] = result.missing[i]
	end
	return {
		state = "not_ready",
		missing = missing,
		incompleteReason = nil,
	}
end
