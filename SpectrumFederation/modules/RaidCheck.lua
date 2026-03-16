-- Grab the namespace
local addonName, SF = ...

-- luacheck: globals INVSLOT_HEAD INVSLOT_NECK INVSLOT_SHOULDER INVSLOT_BACK INVSLOT_CHEST INVSLOT_WRIST INVSLOT_HAND INVSLOT_WAIST INVSLOT_LEGS INVSLOT_FEET INVSLOT_FINGER1 INVSLOT_FINGER2 INVSLOT_TRINKET1 INVSLOT_TRINKET2 INVSLOT_MAINHAND INVSLOT_OFFHAND
-- luacheck: globals GetInventoryItemLink GetItemInfoInstant GetItemStats GetItemGem GetNumGroupMembers IsInRaid IsInGroup SendChatMessage UnitFullName GetRealmName C_Item

SF.RaidCheck = SF.RaidCheck or {}
local RC = SF.RaidCheck

local RAID_CHECK_REASON = "RAID_CHECK"
local SLOT_DEFS = {
	head = { label = "Head", slots = { INVSLOT_HEAD } },
	neck = { label = "Neck", slots = { INVSLOT_NECK } },
	shoulders = { label = "Shoulders", slots = { INVSLOT_SHOULDER } },
	back = { label = "Back", slots = { INVSLOT_BACK } },
	chest = { label = "Chest", slots = { INVSLOT_CHEST } },
	wrist = { label = "Wrist", slots = { INVSLOT_WRIST } },
	hands = { label = "Gloves", slots = { INVSLOT_HAND } },
	belt = { label = "Belt", slots = { INVSLOT_WAIST } },
	legs = { label = "Legs", slots = { INVSLOT_LEGS } },
	boots = { label = "Boots", slots = { INVSLOT_FEET } },
	rings = { label = "Ring", slots = { INVSLOT_FINGER1, INVSLOT_FINGER2 } },
	trinkets = { label = "Trinket", slots = { INVSLOT_TRINKET1, INVSLOT_TRINKET2 } },
	mainHand = { label = "Main Hand", slots = { INVSLOT_MAINHAND } },
	offHand = { label = "Off Hand", slots = { INVSLOT_OFFHAND } },
}

local function NormalizeNameRealm(name, realm)
	if not name or name == "" then return nil end
	realm = realm or GetRealmName()
	if realm then realm = realm:gsub("%s+", "") end
	local full = realm and (name .. "-" .. realm) or name
	if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
		return SF.NameUtil.NormalizeNameRealm(full) or full
	end
	return full
end

local function ShortName(full)
	if type(full) ~= "string" then return "Unknown" end
	return full:match("^[^%-]+") or full
end

local function HasEnchant(link)
	if type(link) ~= "string" then return false end
	local itemString = link:match("item:([%-%d:]+)")
	if not itemString then return false end
	local _, enchantId = strsplit(":", itemString)
	return enchantId and enchantId ~= "" and enchantId ~= "0"
end

local function GetItemEquipLocation(link)
	if type(link) ~= "string" then return nil end
	local _, _, _, equipLoc = GetItemInfoInstant(link)
	if type(equipLoc) == "string" and equipLoc ~= "" then
		return equipLoc
	end
	return nil
end

local function GetItemStatsSafe(link)
	if type(link) ~= "string" then return nil end

	if GetItemStats then
		local ok, stats = pcall(GetItemStats, link)
		if ok and type(stats) == "table" then
			return stats
		end
	end

	if C_Item and C_Item.GetItemStats then
		local ok, stats = pcall(C_Item.GetItemStats, link)
		if ok and type(stats) == "table" then
			return stats
		end
	end

	return nil
end

local function HasMissingGems(link)
	if type(link) ~= "string" then return false end

	local stats = GetItemStatsSafe(link) or {}
	local sockets = 0
	for stat, value in pairs(stats) do
		if type(stat) == "string" and stat:match("^EMPTY_SOCKET") then
			sockets = sockets + (tonumber(value) or 0)
		end
	end

	if sockets == 0 then
		return false
	end

	local filled = 0
	for i = 1, sockets do
		if GetItemGem(link, i) then
			filled = filled + 1
		end
	end

	return filled < sockets
end

local function IsTwoHandWeapon(link)
	if type(link) ~= "string" then return false end
	return GetItemEquipLocation(link) == "INVTYPE_2HWEAPON"
end

local function CanReceiveWeaponEnchant(link)
	if type(link) ~= "string" then return false end
	local equipLoc = GetItemEquipLocation(link)
	if not equipLoc then return false end
	return equipLoc == "INVTYPE_WEAPON"
		or equipLoc == "INVTYPE_WEAPONMAINHAND"
		or equipLoc == "INVTYPE_WEAPONOFFHAND"
		or equipLoc == "INVTYPE_2HWEAPON"
end

local function ShouldCheckEnchant(slotDef, link)
	if slotDef ~= SLOT_DEFS.offHand then
		return true
	end

	if CanReceiveWeaponEnchant(link) then
		return true
	end

	-- Held-in-offhand items and shields do not use weapon enchants.
	-- If item metadata is unavailable for an equipped offhand, skip the enchant
	-- warning to avoid false positives until the client can resolve the item.
	return false
end

local function GetRaidCheckSlotConfigKey(slotKey, link)
	-- Raid Check evaluates physical equipment slots, but the settings model
	-- now exposes a logical "weapon" toggle that covers main-hand weapons and
	-- offhand weapons alike. Empty offhands and non-weapon offhands keep using
	-- the physical offhand toggle because there is no weapon item to classify.
	if slotKey == "mainHand" then
		return "weapon"
	end

	if slotKey == "offHand" and link and CanReceiveWeaponEnchant(link) then
		return "weapon"
	end

	return slotKey
end

local function IsSlotEnabledInConfig(cfg, slotKey, link)
	if not cfg or type(cfg.slots) ~= "table" then
		return false
	end

	local configKey = GetRaidCheckSlotConfigKey(slotKey, link)
	return cfg.slots[configKey] and true or false
end

local function CollectUnits()
	local units = {}

	if IsInRaid() then
		for i = 1, (GetNumGroupMembers() or 0) do
			table.insert(units, "raid" .. i)
		end
	elseif IsInGroup() then
		for i = 1, (GetNumGroupMembers() or 1) - 1 do
			table.insert(units, "party" .. i)
		end
		table.insert(units, "player")
	else
		table.insert(units, "player")
	end

	return units
end

local function GetProfile()
	return SF.GetActiveProfile and SF:GetActiveProfile() or nil
end

local function IsCurrentUserAdmin(profile)
	return profile and profile.IsCurrentUserAdmin and profile:IsCurrentUserAdmin()
end

local function AnySlotEnabled(cfg)
	if not cfg or type(cfg.slots) ~= "table" then return false end
	for _, enabled in pairs(cfg.slots) do
		if enabled then return true end
	end
	return false
end

local function BuildMissingForSlot(unit, slotKey, slotDef, idx, mainHandLink, cfg)
	local link = GetInventoryItemLink(unit, slotDef.slots[idx])
	local label = slotDef.label
	if #slotDef.slots > 1 then
		label = string.format("%s %d", label, idx)
	end

	if not link then
		if slotDef == SLOT_DEFS.offHand and mainHandLink and IsTwoHandWeapon(mainHandLink) then
			return {}
		end
		-- Empty slots use their physical slot toggle. For offhand specifically,
		-- that means an empty offhand follows the offHand setting because there is
		-- no equipped item to classify as a weapon or non-weapon.
		if not IsSlotEnabledInConfig(cfg, slotKey, nil) then
			return {}
		end
		return { label .. " Item" }
	end

	if not IsSlotEnabledInConfig(cfg, slotKey, link) then
		return {}
	end

	local missing = {}
	if ShouldCheckEnchant(slotDef, link) and not HasEnchant(link) then
		table.insert(missing, label .. " Enchant")
	end

	if HasMissingGems(link) then
		table.insert(missing, label .. " Gem")
	end

	return missing
end

local function EvaluateUnit(unit, cfg)
	local mainHandLink = GetInventoryItemLink(unit, INVSLOT_MAINHAND)
	local missing = {}

	for slotKey, slotDef in pairs(SLOT_DEFS) do
		for idx = 1, #slotDef.slots do
			local slotMissing = BuildMissingForSlot(unit, slotKey, slotDef, idx, mainHandLink, cfg)
			for _, m in ipairs(slotMissing) do
				table.insert(missing, m)
			end
		end
	end

	return missing
end

local function SendWhisper(target, message)
	if not target or target == "" or not message then return end
	SendChatMessage(message, "WHISPER", nil, target)
end

local function FindMember(profile, memberId)
	if not profile or not memberId then return nil end

	if type(profile.getMemberByID) == "function" then
		local ok, member = pcall(profile.getMemberByID, profile, memberId)
		if ok then return member end
	end

	if type(profile.GetMemberByID) == "function" then
		local ok, member = pcall(profile.GetMemberByID, profile, memberId)
		if ok then return member end
	end

	return nil
end

local function ValidateCanRun(mode)
	local profile = GetProfile()
	if not profile then
		SF:PrintError("No active loot profile selected. Set an active profile before running a raid check.")
		return nil
	end

	if not IsCurrentUserAdmin(profile) then
		SF:PrintError("Only admins can run raid checks.")
		return nil
	end

	if not profile.GetRaidCheckConfig then
		SF:PrintError("Raid Check settings are unavailable for the active profile.")
		return nil
	end

	local cfg = profile:GetRaidCheckConfig()
	if mode ~= "pre" and mode ~= "raid" then
		SF:PrintError("Invalid Raid Check mode.")
		return nil
	end

	return profile, cfg
end

local function FormatMissingList(missing)
	return table.concat(missing, ", ")
end

local function AwardPrepared(profile, member, pointName)
	if not member or not member.IncrementPoints then
		return false
	end

	local ok = member:IncrementPoints({
		logAuthor = "Raid Check",
		reason = RAID_CHECK_REASON,
	})

	if not ok then
		return false
	end

	if SF.Debug then
		local identifier = (member and member.GetFullIdentifier and member:GetFullIdentifier()) or "?"
		SF.Debug:Info("RAID_CHECK", "Awarded raid check point to %s", tostring(identifier))
	end

	return true
end

local function WhisperPrepared(target, pointName)
	SendWhisper(target, ("Spectrum Federation: You've been awarded 1 %s. Thanks for showing up prepared and on time!"):format(pointName))
end

local function WhisperMissing(target, pointName, list, mode)
	if mode == "pre" then
		SendWhisper(target, ("Spectrum Federation: You're missing the following enchants/gems: %s."):format(list))
	else
		SendWhisper(target, ("Spectrum Federation: You're missing the following enchants/gems: %s. No new %s awarded."):format(list, pointName))
	end
end

local function GetPointName(profile)
	if profile and profile.GetPointName then
		return profile:GetPointName()
	end
	return "Points"
end

local function BuildUnitInfo(unit)
	local name, realm = UnitFullName(unit)
	local id = NormalizeNameRealm(name, realm)
	return {
		unit = unit,
		id = id,
		short = ShortName(id),
	}
end

local function ShouldWhisper(mode, cfg)
	if mode == "pre" then
		return cfg.enableWhispersPreRaid
	end
	return cfg.enableWhispersRaid
end

	local function RunForUnit(unitInfo, profile, cfg, mode, pointName)
	local missing = EvaluateUnit(unitInfo.unit, cfg)
	local whisper = ShouldWhisper(mode, cfg)
	local whisperTarget = unitInfo.id or unitInfo.short
	local result = {
		name = unitInfo.short,
		id = unitInfo.id,
		missing = nil,
		whisperedMissing = false,
	}
		
		if #missing > 0 then
			local list = FormatMissingList(missing)
			local suffix = ""
			if whisper and mode == "pre" then
				suffix = " (whispered)"
			end
			SF:PrintWarning(("%s Missing: %s%s"):format(unitInfo.short, list, suffix))
			
			if whisper then
				WhisperMissing(whisperTarget, pointName, list, mode)
			end
			
			result.missing = list
			return result
		end

	if mode == "raid" then
		local member = FindMember(profile, unitInfo.id)
		if not member then
			SF:PrintWarning(("Skipping point award for %s (not in active profile)."):format(unitInfo.short))
			return result
		end

		local awarded = AwardPrepared(profile, member, pointName)
		if awarded and whisper then
			WhisperPrepared(whisperTarget, pointName)
		end
	end

	return result
end

	function RC:RunPreRaidCheck()
		local profile, cfg = ValidateCanRun("pre")
		if not profile then return end
	
		if SF.SystemMessage then
			SF:SystemMessage("Pre-Raid Check started.")
		else
			SF:PrintInfo("[Pre-Raid Check] Initiated.")
		end

	local summaryMissing = {}

	for _, unit in ipairs(CollectUnits()) do
		local info = BuildUnitInfo(unit)
		if info.id then
			local res = RunForUnit(info, profile, cfg, "pre", GetPointName(profile))
			if res then
				if res.whisperedMissing then
					SF:PrintInfo(string.format("[Pre-Raid Check] Whispered %s about missing enchants/gems.", res.name))
				end
				if res.missing then
					table.insert(summaryMissing, res)
				end
			end
		end
	end

	if not ShouldWhisper("pre", cfg) and #summaryMissing > 0 then
		SF:PrintWarning("[Pre-Raid Check] Players missing enchants/gems:")
		for _, entry in ipairs(summaryMissing) do
			SF:PrintWarning(string.format("  %s - %s", entry.name, entry.missing))
		end
	end

	SF:PrintSuccess("[Pre-Raid Check] Complete.")
end

	function RC:RunRaidCheck()
		local profile, cfg = ValidateCanRun("raid")
		if not profile then return end
	
		if SF.SystemMessage then
			SF:SystemMessage("Raid Check started.")
		else
			SF:PrintInfo("[Raid Check] Initiated.")
		end

	local pointName = GetPointName(profile)
	local summaryMissing = {}

	for _, unit in ipairs(CollectUnits()) do
		local info = BuildUnitInfo(unit)
		if info.id then
			local res = RunForUnit(info, profile, cfg, "raid", pointName)
			if res then
				if res.whisperedMissing then
					SF:PrintInfo(string.format("[Raid Check] Whispered %s about missing enchants/gems.", res.name))
				end
				if res.missing then
					table.insert(summaryMissing, res)
				end
			end
		end
	end

	if not ShouldWhisper("raid", cfg) and #summaryMissing > 0 then
		SF:PrintWarning("[Raid Check] Players missing enchants/gems:")
		for _, entry in ipairs(summaryMissing) do
			SF:PrintWarning(string.format("  %s - %s", entry.name, entry.missing))
		end
	end

	SF:PrintSuccess("[Raid Check] Complete.")
end

function RC:Run(mode)
	if mode == "pre" then
		return self:RunPreRaidCheck()
	end
	return self:RunRaidCheck()
end
