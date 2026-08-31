-- Current-Retail Raid Equipment policy. Addon-owned; not profile-configured.
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

function Policy.GetItemEquipLocation(linkOrId)
	if linkOrId == nil then
		return nil
	end
	if GetItemInfoInstant then
		local ok, _, _, _, equipLoc = pcall(GetItemInfoInstant, linkOrId)
		if ok and type(equipLoc) == "string" and equipLoc ~= "" then
			return equipLoc
		end
	end
	return nil
end

function Policy.IsTwoHandWeapon(equipLoc)
	return equipLoc == "INVTYPE_2HWEAPON"
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

function Policy.IsQualifyingLimitedGem(gemId, uniqueness)
	gemId = tonumber(gemId)
	if not gemId or gemId == 0 then
		return false, "unresolved"
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
		if uniqueness.resolved == true then
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

function Policy.EvaluateObservation(observation)
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
			local twoHandExempt = def.key == "offHand" and Policy.IsTwoHandWeapon(mainHandLoc)
			if not twoHandExempt then
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

	result.complete = true
	result.prepared = #result.missing == 0
	return result
end

function Policy.EvaluateCompleteness(observation)
	local result = Policy.EvaluateObservation(observation)
	return {
		complete = result.complete == true,
		reason = result.incompleteReason,
	}
end
