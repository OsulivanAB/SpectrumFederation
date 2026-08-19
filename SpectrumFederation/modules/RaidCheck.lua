-- Grab the namespace
local addonName, SF = ...

-- luacheck: globals INVSLOT_HEAD INVSLOT_NECK INVSLOT_SHOULDER INVSLOT_BACK INVSLOT_CHEST INVSLOT_WRIST INVSLOT_HAND INVSLOT_WAIST INVSLOT_LEGS INVSLOT_FEET
-- luacheck: globals INVSLOT_FINGER1 INVSLOT_FINGER2 INVSLOT_TRINKET1 INVSLOT_TRINKET2 INVSLOT_MAINHAND INVSLOT_OFFHAND
-- luacheck: globals GetInventoryItemLink GetInventoryItemTexture GetItemInfo GetItemInfoInstant GetItemStats GetItemGem GetDetailedItemLevelInfo C_Item
-- luacheck: globals GetInventoryItemID C_TooltipInfo TooltipUtil Enum
-- luacheck: globals EMPTY_SOCKET_PRISMATIC EMPTY_SOCKET_META EMPTY_SOCKET_RED EMPTY_SOCKET_YELLOW EMPTY_SOCKET_BLUE
-- luacheck: globals EMPTY_SOCKET_HYDRAULIC EMPTY_SOCKET_COGWHEEL EMPTY_SOCKET_DOMINATION EMPTY_SOCKET_TINKER EMPTY_SOCKET_PRIMORDIAL
-- luacheck: globals GetNumGroupMembers IsInRaid IsInGroup SendChatMessage UnitFullName UnitClass GetRealmName UnitGUID UnitExists UnitIsUnit
-- luacheck: globals CreateFrame C_Timer NotifyInspect ClearInspectPlayer CanInspect CheckInteractDistance GetTime GetServerTime InCombatLockdown
-- luacheck: globals InspectFrame InspectUnit hooksecurefunc canaccessvalue

SF.RaidCheck = SF.RaidCheck or {}
local RC = SF.RaidCheck

local RAID_CHECK_REASON = "RAID_CHECK"
local RAID_CHECK_POINT_AWARD_DEFAULT = 0.5
local META_GEM_QUALITY = 4
local MAX_GEM_SOCKETS_TO_SCAN = 8
local INSPECT_CACHE_TTL_SECONDS = 30 -- Background recheck cadence for live inspect data.
local EQUIPMENT_SNAPSHOT_MAX_AGE_SECONDS = 24 * 60 * 60
local INSPECT_RETRY_BASE_SECONDS = 2
local INSPECT_RETRY_MAX_SECONDS = 10
local INSPECT_REQUEST_TIMEOUT_SECONDS = 1.5
local BACKGROUND_INSPECT_POLL_SECONDS = 5
local MANUAL_INSPECT_INTENT_PAUSE_SECONDS = 30
local MANUAL_INSPECT_POST_HIDE_PAUSE_SECONDS = 2
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

local function CalculateInspectRetryDelay(failCount)
	local attempts = math.max(1, tonumber(failCount) or 1)
	return math.min(INSPECT_RETRY_MAX_SECONDS, INSPECT_RETRY_BASE_SECONDS * attempts)
end

local function CanAccessValue(value)
	return not canaccessvalue or canaccessvalue(value)
end

local function GetAccessibleUnitGUID(unit)
	if not UnitGUID then
		return nil
	end

	local guid = UnitGUID(unit)
	if not CanAccessValue(guid) then
		return nil
	end
	return guid
end

local TROUBLESHOOTING_COLUMNS = {
	{ key = "head", label = "Head", shortLabel = "Hd", inventorySlot = INVSLOT_HEAD },
	{ key = "neck", label = "Neck", shortLabel = "Nk", inventorySlot = INVSLOT_NECK },
	{ key = "shoulders", label = "Shoulders", shortLabel = "Sh", inventorySlot = INVSLOT_SHOULDER },
	{ key = "back", label = "Back", shortLabel = "Bk", inventorySlot = INVSLOT_BACK },
	{ key = "chest", label = "Chest", shortLabel = "Ch", inventorySlot = INVSLOT_CHEST },
	{ key = "wrist", label = "Wrist", shortLabel = "Wr", inventorySlot = INVSLOT_WRIST },
	{ key = "hands", label = "Gloves", shortLabel = "Gl", inventorySlot = INVSLOT_HAND },
	{ key = "belt", label = "Belt", shortLabel = "Bt", inventorySlot = INVSLOT_WAIST },
	{ key = "legs", label = "Legs", shortLabel = "Lg", inventorySlot = INVSLOT_LEGS },
	{ key = "boots", label = "Boots", shortLabel = "Ft", inventorySlot = INVSLOT_FEET },
	{ key = "rings", label = "Ring 1", shortLabel = "R1", inventorySlot = INVSLOT_FINGER1 },
	{ key = "rings", label = "Ring 2", shortLabel = "R2", inventorySlot = INVSLOT_FINGER2 },
	{ key = "trinkets", label = "Trinket 1", shortLabel = "T1", inventorySlot = INVSLOT_TRINKET1 },
	{ key = "trinkets", label = "Trinket 2", shortLabel = "T2", inventorySlot = INVSLOT_TRINKET2 },
	{ key = "mainHand", label = "Weapon", shortLabel = "MH", inventorySlot = INVSLOT_MAINHAND },
	{ key = "offHand", label = "Off Hand", shortLabel = "OH", inventorySlot = INVSLOT_OFFHAND },
}

local function NormalizeNameRealm(name, realm)
	if not CanAccessValue(name) or not CanAccessValue(realm) then
		return nil
	end
	if not name or name == "" then return nil end
	realm = realm or GetRealmName()
	if not CanAccessValue(realm) then
		return nil
	end
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

local function ToWoWHexColor(color)
	if type(color) == "table" then
		local r = tonumber(color.r or color[1] or 1) or 1
		local g = tonumber(color.g or color[2] or 1) or 1
		local b = tonumber(color.b or color[3] or 1) or 1
		r = math.min(math.max(r, 0), 1)
		g = math.min(math.max(g, 0), 1)
		b = math.min(math.max(b, 0), 1)
		return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
	end
	return "|cffffffff"
end

local function ColorizeUnitName(unit, name)
	if not unit or not name or name == "" then
		return name or "Unknown"
	end

	local _, classToken = UnitClass(unit)
	local classData = classToken and SF.WOW_CLASSES and SF.WOW_CLASSES[classToken]
	if classData and classData.colorCode then
		return string.format("%s%s|r", ToWoWHexColor(classData.colorCode), name)
	end

	return name
end

local function ColorizeProfileMemberName(profile, memberId, name)
	if not profile or type(profile.GetMemberByID) ~= "function" or not name or name == "" then
		return name or "Unknown"
	end

	local member = profile:GetMemberByID(memberId)
	local classData = member and member.class and SF.WOW_CLASSES and SF.WOW_CLASSES[member.class]
	if classData and classData.colorCode then
		return string.format("%s%s|r", ToWoWHexColor(classData.colorCode), name)
	end

	return name
end

local function ParseEnchantIdFromLink(link)
	if type(link) ~= "string" then return nil end
	local itemString = link:match("item:([%-%d:]+)")
	if not itemString then return nil end
	local _, enchantId = strsplit(":", itemString)
	if enchantId and enchantId ~= "" and enchantId ~= "0" then
		return enchantId
	end
	return nil
end

local function HasEnchant(link)
	if type(link) ~= "string" then return false end

	-- Primary: parse enchantId directly from the item link string.
	if ParseEnchantIdFromLink(link) then
		return true
	end

	-- Fallback: use C_Item.GetItemEnchantID if the client provides it.
	-- In TWW (11.0+), GetInventoryItemLink for inspected players may
	-- temporarily return a link with enchantId=0 before the full item
	-- data resolves; this API reads from the resolved item cache instead.
	if C_Item and C_Item.GetItemEnchantID then
		local ok, enchantID = pcall(C_Item.GetItemEnchantID, link)
		if ok and type(enchantID) == "number" and enchantID ~= 0 then
			return true
		end
	end

	return false
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

local function IsGemPresentInSocket(link, i)
	-- C_Item.GetItemGemID reads the gem's item ID directly from the item link
	-- without requiring the gem's data to be loaded in item sparse.
	-- GetItemGem (C_Item.GetItemGem) may return nil for a filled socket when the
	-- gem's item data has not yet been cached, causing false missing-gem reports.
	if C_Item and C_Item.GetItemGemID then
		local ok, gemID = pcall(C_Item.GetItemGemID, link, i)
		if ok then
			return type(gemID) == "number" and gemID ~= 0
		end
	end

	-- Fallback: parse gem IDs directly from the item link string.
	-- Gem fields start at position 3 (0-indexed) in the item string:
	-- item:itemID:enchantID:gem1:gem2:gem3:gem4:...
	if type(link) == "string" then
		local itemString = link:match("item:([%-%d:]+)")
		if itemString then
			local fields = { strsplit(":", itemString) }
			-- Gem slots occupy fields 3-6 (indices 3+i-1 in the array, offset by 2 for itemId & enchant)
			local fieldIndex = 2 + i
			local gemField = fields[fieldIndex]
			if gemField and gemField ~= "" and gemField ~= "0" then
				return true
			end
		end
	end

	return (GetItemGem ~= nil) and (GetItemGem(link, i) ~= nil) or false
end

local function CountGemsFilledFromLink(link)
	-- Parse gem IDs directly from the item link to detect filled sockets
	-- without depending on GetItemGem/C_Item API calls which may fail for
	-- inspected players whose gem item data isn't locally cached.
	if type(link) ~= "string" then return 0 end
	local itemString = link:match("item:([%-%d:]+)")
	if not itemString then return 0 end
	local fields = { strsplit(":", itemString) }
	local filled = 0
	-- Gem fields are at indices 3-6 in the item string fields array
	for idx = 3, math.min(6, #fields) do
		local gemField = fields[idx]
		if gemField and gemField ~= "" and gemField ~= "0" then
			filled = filled + 1
		end
	end
	return filled
end

local function CountSocketsFromItemStats(link)
	local stats = GetItemStatsSafe(link) or {}
	local sockets = 0
	for stat, value in pairs(stats) do
		if type(stat) == "string" and stat:match("^EMPTY_SOCKET") then
			sockets = sockets + (tonumber(value) or 0)
		end
	end
	return sockets
end

local function CountItemSockets(link)
	-- Prefer the dedicated socket-count API when it accepts an item link.
	-- A zero/failed result is ignored because some clients only support
	-- ItemLocation inputs; fall back to EMPTY_SOCKET* stats in that case.
	if C_Item and C_Item.GetItemNumSockets then
		local ok, num = pcall(C_Item.GetItemNumSockets, link)
		if ok then
			num = tonumber(num)
			if num and num > 0 then
				return num
			end
		end
	end

	return CountSocketsFromItemStats(link)
end

local function GetGemSocketLineType()
	if Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.GemSocket then
		return Enum.TooltipDataLineType.GemSocket
	end
	return 3
end

local function IsLocalizedEmptySocketText(text)
	if type(text) ~= "string" or text == "" then
		return false
	end

	if EMPTY_SOCKET_PRISMATIC and text == EMPTY_SOCKET_PRISMATIC then return true end
	if EMPTY_SOCKET_META and text == EMPTY_SOCKET_META then return true end
	if EMPTY_SOCKET_RED and text == EMPTY_SOCKET_RED then return true end
	if EMPTY_SOCKET_YELLOW and text == EMPTY_SOCKET_YELLOW then return true end
	if EMPTY_SOCKET_BLUE and text == EMPTY_SOCKET_BLUE then return true end
	if EMPTY_SOCKET_HYDRAULIC and text == EMPTY_SOCKET_HYDRAULIC then return true end
	if EMPTY_SOCKET_COGWHEEL and text == EMPTY_SOCKET_COGWHEEL then return true end
	if EMPTY_SOCKET_DOMINATION and text == EMPTY_SOCKET_DOMINATION then return true end
	if EMPTY_SOCKET_TINKER and text == EMPTY_SOCKET_TINKER then return true end
	if EMPTY_SOCKET_PRIMORDIAL and text == EMPTY_SOCKET_PRIMORDIAL then return true end

	return false
end

local function SurfaceTooltipTable(data)
	if type(data) == "table" and TooltipUtil and TooltipUtil.SurfaceArgs then
		pcall(TooltipUtil.SurfaceArgs, data)
	end
end

local function CountEmptySocketsFromTooltip(link)
	if type(link) ~= "string" or not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then
		return 0, 0
	end

	local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
	if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then
		return 0, 0
	end

	SurfaceTooltipTable(data)

	local gemSocketType = GetGemSocketLineType()
	local empty = 0
	local total = 0
	for i = 1, #data.lines do
		local line = data.lines[i]
		if type(line) == "table" then
			SurfaceTooltipTable(line)
			if line.type == gemSocketType then
				total = total + 1
				local text = line.leftText
				if IsLocalizedEmptySocketText(text) or type(text) ~= "string" or text == "" then
					empty = empty + 1
				end
			end
		end
	end

	return empty, total
end

local function HasMissingGems(link)
	if type(link) ~= "string" then return false end

	-- The item tooltip is the same source players see, including bonus-ID
	-- prismatic sockets that may not appear in GetItemStats or gem link fields.
	local emptyFromTooltip, socketsFromTooltip = CountEmptySocketsFromTooltip(link)
	if socketsFromTooltip > 0 then
		return emptyFromTooltip > 0
	end

	-- Every socket on the item must contain a gem. Socket count comes from
	-- item stats / C_Item; fill state is checked per index so one empty
	-- socket still fails even when other sockets are filled.
	local sockets = CountItemSockets(link)
	if sockets == 0 then
		return false
	end

	for i = 1, sockets do
		if not IsGemPresentInSocket(link, i) then
			return true
		end
	end

	return false
end

local function GetDetailedItemLevelSafe(link)
	if type(link) ~= "string" then return nil end

	if GetDetailedItemLevelInfo then
		local ok, itemLevel = pcall(GetDetailedItemLevelInfo, link)
		if ok and tonumber(itemLevel) then
			return tonumber(itemLevel)
		end
	end

	if C_Item and C_Item.GetDetailedItemLevelInfo then
		local ok, itemLevel = pcall(C_Item.GetDetailedItemLevelInfo, link)
		if ok and tonumber(itemLevel) then
			return tonumber(itemLevel)
		end
	end

	return nil
end

local function IsEpicQualityLink(link)
	if type(link) ~= "string" then return false end
	local colorCode = link:match("|c(%x%x%x%x%x%x%x%x)|H")
	return colorCode ~= nil and colorCode:lower() == "ffa335ee"
end

local function IsMetaGemSocketed(gemName, gemLink, gemID)
	if IsEpicQualityLink(gemLink) or IsEpicQualityLink(gemName) then
		return true, false
	end

	local infoArg = gemLink or gemName or gemID
	if GetItemInfo and infoArg then
		local _, itemLink, quality = GetItemInfo(infoArg)
		if quality == META_GEM_QUALITY then
			return true, false
		end
		if IsEpicQualityLink(itemLink) then
			return true, false
		end
		if quality ~= nil then
			return false, false
		end
		return false, true
	end

	if gemLink or gemName or gemID then
		return false, true
	end

	return false, false
end

local function GetSocketedGemIdentity(link, gemIndex)
	local gemID = nil
	if C_Item and C_Item.GetItemGemID then
		local ok, id = pcall(C_Item.GetItemGemID, link, gemIndex)
		if ok and type(id) == "number" and id ~= 0 then
			gemID = id
		end
	end

	local gemName, gemLink = nil, nil
	if GetItemGem then
		gemName, gemLink = GetItemGem(link, gemIndex)
	end

	if not gemID and type(link) == "string" then
		local itemString = link:match("item:([%-%d:]+)")
		if itemString then
			local fields = { strsplit(":", itemString) }
			local gemField = fields[2 + gemIndex]
			local parsedId = tonumber(gemField)
			if parsedId and parsedId ~= 0 then
				gemID = parsedId
			end
		end
	end

	return gemName, gemLink, gemID
end

local function HasEquippedMetaGem(unit)
	for _, slotDef in pairs(SLOT_DEFS) do
		for idx = 1, #slotDef.slots do
			local link = GetInventoryItemLink(unit, slotDef.slots[idx])
			if type(link) == "string" then
				for gemIndex = 1, MAX_GEM_SOCKETS_TO_SCAN do
					local gemName, gemLink, gemID = GetSocketedGemIdentity(link, gemIndex)
					local isMeta = IsMetaGemSocketed(gemName, gemLink, gemID)
					if isMeta then
						return true
					end
				end
			end
		end
	end

	return false
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

local function ShouldCheckTroubleshootingEnchant(slotKey, link)
	if slotKey == "offHand" then
		return ShouldCheckEnchant(SLOT_DEFS.offHand, link)
	end

	return true
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

local function IsSelfUnit(unit)
	if not unit then
		return false
	end

	if unit == "player" then
		return true
	end

	if UnitIsUnit then
		local isSelf = UnitIsUnit(unit, "player")
		if not CanAccessValue(isSelf) then
			return false
		end
		return isSelf and true or false
	end

	return false
end

local function GetTroubleshootingCaptureUnit(unit)
	if IsSelfUnit(unit) then
		return "player"
	end
	return unit
end

local function IsUnitInInspectRange(unit)
	if not unit then
		return false
	end

	if CheckInteractDistance then
		if InCombatLockdown and InCombatLockdown() then
			return false
		end
		return CheckInteractDistance(unit, 1) ~= false
	end
	return true
end

local function IsInspectPausedForCombat()
	return InCombatLockdown and InCombatLockdown() or false
end

local function IsInspectFrameShown()
	return InspectFrame and InspectFrame.IsShown and InspectFrame:IsShown() or false
end

local function HasActiveLootHelperSession()
	if not SF.LootHelperSync or type(SF.LootHelperSync.IsSessionActive) ~= "function" then
		return false
	end

	return SF.LootHelperSync:IsSessionActive()
end

local function CanInspectUnitNow(unit)
	return unit
		and UnitExists and UnitExists(unit)
		and not IsInspectPausedForCombat()
		and CanInspect and CanInspect(unit)
		and IsUnitInInspectRange(unit)
end

local function GetSnapshotSlotLink(slotsByInventory, inventorySlot)
	local slotData = slotsByInventory and slotsByInventory[inventorySlot]
	return slotData and slotData.link or nil
end

-- Returns true when a slot has evidence that an item is equipped (texture or
-- itemId present) but the full item link has not loaded yet.  This allows the
-- raid check to distinguish between "slot is empty" and "item data is still
-- loading" to avoid false positives.
local function IsSlotItemDataPending(slotsByInventory, inventorySlot)
	local slotData = slotsByInventory and slotsByInventory[inventorySlot]
	if type(slotData) ~= "table" then
		return false
	end
	if slotData.link then
		return false
	end
	local itemId = tonumber(slotData.itemId)
	if (itemId and itemId > 0) or slotData.texture then
		return true
	end
	return false
end

-- Returns true when a slot has a link but the link looks like it may be a
-- stub with incomplete modification data.  In TWW (11.0+), inspect responses
-- can arrive in stages: the item placement is known immediately, but enchant,
-- gem, and bonus ID data may not be populated in the link until the full item
-- resolution completes.  Detecting this avoids caching false "missing enchant"
-- or "missing gem" results.
local function IsSlotLinkPotentiallyIncomplete(slotsByInventory, inventorySlot)
	local slotData = slotsByInventory and slotsByInventory[inventorySlot]
	if type(slotData) ~= "table" or not slotData.link then
		return false
	end

	local link = slotData.link
	local itemString = link:match("item:([%-%d:]+)")
	if not itemString then
		return false
	end

	-- Split the item string and inspect modification fields.
	-- Format: itemID:enchantID:gem1:gem2:gem3:gem4:suffixID:uniqueID:level:...
	-- If ALL modification fields (enchant + gems + suffix, indices 2-7) are
	-- empty/zero, the link is likely a stub that has not fully resolved yet.
	local fields = { strsplit(":", itemString) }
	if #fields < 7 then
		-- Very short link; could be incomplete or non-standard.
		return true
	end

	for i = 2, math.min(7, #fields) do
		local v = fields[i]
		if v and v ~= "" and v ~= "0" then
			-- At least one modification field is populated; link looks complete.
			return false
		end
	end

	-- Bonus IDs / item context mean inspect data has resolved. An unenchanted
	-- item with empty sockets is a complete link, not a TWW inspect stub.
	-- Format after uniqueID: linkLevel:spec:modifiersMask:itemContext:numBonusIDs:...
	local itemContext = tonumber(fields[12])
	local numBonusIDs = tonumber(fields[13])
	if (itemContext and itemContext ~= 0) or (numBonusIDs and numBonusIDs > 0) then
		return false
	end

	local itemLevel = tonumber(slotData.itemLevel)
	if itemLevel and itemLevel > 0 and #fields >= 9 then
		return false
	end

	-- All modification fields are zero/empty.  If the item also has a texture
	-- or itemId (meaning the server confirmed an item is equipped), the link is
	-- likely a stub awaiting full resolution.
	local itemId = tonumber(slotData.itemId)
	if (itemId and itemId > 0) or slotData.texture then
		return true
	end

	return false
end

local function SlotHasAnyItemData(slotData)
	if type(slotData) ~= "table" then
		return false
	end
	if slotData.link then
		return true
	end
	local itemId = tonumber(slotData.itemId)
	if itemId and itemId > 0 then
		return true
	end
	if slotData.texture then
		return true
	end
	return slotData.hasItem and true or false
end

local function HasEquipmentData(slotsByInventory)
	if type(slotsByInventory) ~= "table" then
		return false
	end

	-- Count any populated slot metadata as usable inspect data so raid checks do
	-- not treat an empty placeholder snapshot as a real equipment capture.
	for _, slotData in pairs(slotsByInventory) do
		local itemLevel = type(slotData) == "table" and tonumber(slotData.itemLevel) or nil
		if type(slotData) == "table" and (SlotHasAnyItemData(slotData) or itemLevel ~= nil) then
			return true
		end
	end

	return false
end

local function NormalizeSlotData(slotData)
	if type(slotData) ~= "table" then
		return slotData
	end
	if slotData.hasItem == nil then
		slotData.hasItem = SlotHasAnyItemData(slotData)
	end
	return slotData
end

local function CalculateAverageItemLevel(slotsByInventory)
	local total = 0
	local count = 0

	for _, column in ipairs(TROUBLESHOOTING_COLUMNS) do
		local slotData = slotsByInventory and slotsByInventory[column.inventorySlot]
		local itemLevel = slotData and slotData.itemLevel or nil
		if itemLevel and itemLevel > 0 then
			total = total + itemLevel
			count = count + 1
		end
	end

	if count == 0 then
		return nil
	end

	return total / count
end

local function RecalculateCapturedSummary(captured)
	if type(captured) ~= "table" then
		return captured
	end
	if type(captured.slotsByInventory) ~= "table" then
		captured.sawAnyData = false
		captured.averageItemLevel = nil
		return captured
	end

	local sawAnyData = false
	for _, slotData in pairs(captured.slotsByInventory) do
		NormalizeSlotData(slotData)
		if SlotHasAnyItemData(slotData) or slotData.texture then
			sawAnyData = true
		end
	end

	captured.sawAnyData = sawAnyData
	captured.averageItemLevel = CalculateAverageItemLevel(captured.slotsByInventory)
	return captured
end

-- Collapse the raid check config into a stable cache key so prepared slot
-- results can be reused until the profile settings actually change.
local function BuildTroubleshootingConfigSignature(cfg)
	if type(cfg) ~= "table" then
		return "none"
	end

	local parts = {
		(cfg.checkGemsInSockets ~= false) and "g1" or "g0",
		(cfg.requireMetaGem and true or false) and "m1" or "m0",
	}
	local slotKeys = {}

	for key in pairs(cfg.slots or {}) do
		slotKeys[#slotKeys + 1] = tostring(key)
	end

	table.sort(slotKeys)
	for _, key in ipairs(slotKeys) do
		parts[#parts + 1] = string.format("%s=%d", key, cfg.slots[key] and 1 or 0)
	end

	return table.concat(parts, ";")
end

-- Forward-declared so early troubleshooting refresh helpers can safely call it
-- before the later shared row-building helpers are defined.
local BuildUnitInfo

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

local function PersistProfileEquipmentSnapshot(memberId, captured)
	local profile = GetProfile()
	if not profile or type(profile.SetRaidCheckEquipmentSnapshot) ~= "function" then
		return false
	end
	if type(memberId) ~= "string" or memberId == "" or type(captured) ~= "table" or type(captured.slotsByInventory) ~= "table" then
		return false
	end

	return profile:SetRaidCheckEquipmentSnapshot(memberId, {
		capturedAt = GetServerTime and GetServerTime() or nil,
		averageItemLevel = captured.averageItemLevel,
		slotsByInventory = captured.slotsByInventory,
	})
end

local function GetProfileEquipmentSnapshot(memberId)
	local profile = GetProfile()
	if not profile or type(profile.GetRaidCheckEquipmentSnapshot) ~= "function" then
		return nil
	end
	if type(memberId) ~= "string" or memberId == "" then
		return nil
	end
	return profile:GetRaidCheckEquipmentSnapshot(memberId)
end

local function GetEquipmentSnapshotAgeSeconds(snapshot)
	local capturedAt = snapshot and snapshot.capturedAt or nil
	if type(capturedAt) == "number" and capturedAt > 0 then
		local now = GetServerTime and GetServerTime() or nil
		if type(now) ~= "number" or now < capturedAt then
			return nil
		end

		return math.max(0, now - capturedAt)
	end

	local updatedAt = snapshot and snapshot.updatedAt or nil
	if type(updatedAt) ~= "number" or updatedAt <= 0 then
		return nil
	end

	local now = GetTime and GetTime() or nil
	if type(now) ~= "number" or now < updatedAt then
		return nil
	end

	return math.max(0, now - updatedAt)
end

local function IsEquipmentSnapshotFresh(snapshot)
	local ageSeconds = GetEquipmentSnapshotAgeSeconds(snapshot)
	return ageSeconds ~= nil and ageSeconds <= EQUIPMENT_SNAPSHOT_MAX_AGE_SECONDS
end

local function BuildSavedSnapshotMessage(snapshot, whileRefreshing)
	local baseMessage = whileRefreshing
		and "Showing the saved profile snapshot while a fresh inspect loads."
		or "Showing the last saved profile snapshot for this member."
	local ageSeconds = GetEquipmentSnapshotAgeSeconds(snapshot)
	if ageSeconds == nil then
		return baseMessage
	end
	if ageSeconds < 60 then
		return baseMessage .. " Last seen less than a minute ago."
	end
	if ageSeconds < 3600 then
		return string.format("%s Last seen %dm ago.", baseMessage, math.floor(ageSeconds / 60))
	end
	if ageSeconds < 86400 then
		return string.format("%s Last seen %dh ago.", baseMessage, math.floor(ageSeconds / 3600))
	end

	return string.format("%s Last seen %dd ago.", baseMessage, math.floor(ageSeconds / 86400))
end

local function FindUnitByGuidOrId(guid, id)
	if not CanAccessValue(guid) then
		guid = nil
	end
	if not CanAccessValue(id) then
		id = nil
	end

	if guid then
		for _, unit in ipairs(CollectUnits()) do
			local unitGUID = GetAccessibleUnitGUID(unit)
			if unitGUID and unitGUID == guid then
				return unit
			end
		end
	end

	if id then
		for _, unit in ipairs(CollectUnits()) do
			local name, realm = UnitFullName(unit)
			if NormalizeNameRealm(name, realm) == id then
				return unit
			end
		end
	end

	return nil
end

local function CaptureTroubleshootingInventory(unit)
	unit = GetTroubleshootingCaptureUnit(unit)
	local slotsByInventory = {}
	local sawAnyData = false

	for _, column in ipairs(TROUBLESHOOTING_COLUMNS) do
		local inventorySlot = column and column.inventorySlot
		if inventorySlot and not slotsByInventory[inventorySlot] then
			local link = GetInventoryItemLink(unit, inventorySlot)
			local itemId = GetInventoryItemID and GetInventoryItemID(unit, inventorySlot) or nil
			local texture = GetInventoryItemTexture and GetInventoryItemTexture(unit, inventorySlot) or nil
			if not texture and itemId and C_Item and C_Item.GetItemIconByID then
				local ok, icon = pcall(C_Item.GetItemIconByID, itemId)
				if ok then
					texture = icon
				end
			end
			local itemLevel = GetDetailedItemLevelSafe(link)
			local slotData = {
				link = link,
				itemId = itemId,
				texture = texture,
				itemLevel = itemLevel,
			}
			slotData.hasItem = SlotHasAnyItemData(slotData)
			slotsByInventory[inventorySlot] = slotData
			if slotData.hasItem or texture then
				sawAnyData = true
			end
		end
	end

	return {
		averageItemLevel = CalculateAverageItemLevel(slotsByInventory),
		slotsByInventory = slotsByInventory,
		sawAnyData = sawAnyData,
	}
end

function RC:_GetInspectState()
	self._inspectState = self._inspectState or {
		cache = {},
		queue = {},
		queueHead = 1,
		queued = {},
		listeners = {},
		active = nil,
		inspectPausedForCombat = false,
		manualInspectPauseUntil = nil,
		localSnapshot = nil,
		snapshotVersion = 0,
		lastNotifiedVersion = -1,
		backgroundInspectEnabled = false,
		backgroundMonitorStarted = false,
	}
	return self._inspectState
end

function RC:SetBackgroundInspectEnabled(enabled, reason)
	self:EnsureInspectSupport()

	local state = self:_GetInspectState()
	enabled = enabled and true or false
	if state.backgroundInspectEnabled == enabled then
		return
	end

	state.backgroundInspectEnabled = enabled

	if SF.Debug then
		SF.Debug:Info("RAID_CHECK", "Background inspect %s (%s)", enabled and "enabled" or "disabled", tostring(reason or "unknown"))
	end

	if enabled then
		self:_StartBackgroundInspectMonitor()
		self:_RunBackgroundInspectPass()
	end
end

function RC:_IsInspectPausedForManual(now)
	local state = self:_GetInspectState()
	now = now or (GetTime and GetTime() or 0)
	return IsInspectFrameShown() or (state.manualInspectPauseUntil and state.manualInspectPauseUntil > now) or false
end

function RC:_PauseInspectForManualInspect(reason)
	local state = self:_GetInspectState()
	local now = GetTime and GetTime() or 0
	local pauseUntil = now + MANUAL_INSPECT_INTENT_PAUSE_SECONDS
	if not state.manualInspectPauseUntil or state.manualInspectPauseUntil < pauseUntil then
		state.manualInspectPauseUntil = pauseUntil
	end

	if state.active then
		local active = state.active
		state.active = nil

		if active.key and not state.queued[active.key] then
			state.queued[active.key] = true
			local insertAt = state.queueHead
			table.insert(state.queue, insertAt, {
				key = active.key,
				guid = active.guid,
				id = active.id,
				aliases = active.aliases,
			})
		end
	end

	if SF.Debug then
		SF.Debug:Verbose("RAID_CHECK", "Pausing background inspect for manual inspect (%s)", tostring(reason or "unknown"))
	end

	self:_MarkTroubleshootingDirty()
	self:_NotifyTroubleshootingListeners()

	if C_Timer and C_Timer.After then
		local expectedUntil = state.manualInspectPauseUntil
		C_Timer.After(math.max(0.1, expectedUntil - now), function()
			if not self or not self._inspectFrame then
				return
			end
			local stillPaused = self:_IsInspectPausedForManual()
			local currentUntil = self:_GetInspectState().manualInspectPauseUntil
			if stillPaused or (currentUntil and expectedUntil and currentUntil > expectedUntil) then
				return
			end
			self:_ResumeInspectAfterManualInspect("pause window elapsed")
		end)
	end
end

function RC:_OnInspectFrameHidden()
	local state = self:_GetInspectState()
	if not state.manualInspectPauseUntil then
		return
	end

	local now = GetTime and GetTime() or 0
	local pauseUntil = now + MANUAL_INSPECT_POST_HIDE_PAUSE_SECONDS
	if state.manualInspectPauseUntil > pauseUntil then
		state.manualInspectPauseUntil = pauseUntil
	end

	if C_Timer and C_Timer.After then
		local expectedUntil = state.manualInspectPauseUntil
		C_Timer.After(math.max(0.1, expectedUntil - now), function()
			if not self or not self._inspectFrame then
				return
			end
			local stillPaused = self:_IsInspectPausedForManual()
			local currentUntil = self:_GetInspectState().manualInspectPauseUntil
			if stillPaused or (currentUntil and expectedUntil and currentUntil > expectedUntil) then
				return
			end
			self:_ResumeInspectAfterManualInspect("InspectFrame hidden")
		end)
	else
		self:_ResumeInspectAfterManualInspect("InspectFrame hidden")
	end
end

function RC:_ResumeInspectAfterManualInspect(reason)
	if self:_IsInspectPausedForManual() then
		return
	end

	local state = self:_GetInspectState()
	if not state.manualInspectPauseUntil then
		return
	end

	state.manualInspectPauseUntil = nil

	if SF.Debug then
		SF.Debug:Verbose("RAID_CHECK", "Resuming background inspect after manual inspect (%s)", tostring(reason or "unknown"))
	end

	self:_ProcessInspectQueue()
	self:_RunBackgroundInspectPass()
	self:_MarkTroubleshootingDirty()
	self:_NotifyTroubleshootingListeners()
end

function RC:_MarkTroubleshootingDirty()
	local state = self:_GetInspectState()
	state.snapshotVersion = (state.snapshotVersion or 0) + 1
	return state.snapshotVersion
end

function RC:GetTroubleshootingVersion()
	local state = self:_GetInspectState()
	return state.snapshotVersion or 0
end

function RC:_InvalidateLocalTroubleshootingSnapshot()
	local state = self:_GetInspectState()
	state.localSnapshot = nil
end

function RC:_GetLocalTroubleshootingSnapshot()
	local state = self:_GetInspectState()
	if state.localSnapshot then
		return state.localSnapshot
	end

	-- Cache the player snapshot until gear, profile state, or a manual refresh
	-- invalidates it. This avoids repeating full live inventory scans on every
	-- Equipment page redraw.
	local captured = CaptureTroubleshootingInventory("player")
	state.localSnapshot = {
		averageItemLevel = captured.averageItemLevel,
		slotsByInventory = captured.slotsByInventory,
		sawAnyData = captured.sawAnyData,
		preparedSlotsByConfig = {},
		capturedAt = GetServerTime and GetServerTime() or nil,
	}
	if captured.sawAnyData then
		PersistProfileEquipmentSnapshot(SF:GetPlayerFullIdentifier(), captured)
	end
	return state.localSnapshot
end

function RC:_StoreInspectCacheEntry(entry, aliases)
	if type(entry) ~= "table" then
		return
	end

	local state = self:_GetInspectState()
	entry.aliases = aliases or entry.aliases or {}
	for _, key in ipairs(entry.aliases) do
		if key then
			state.cache[key] = entry
		end
	end
end

function RC:_GetInspectCacheEntryByAliases(aliases)
	local state = self:_GetInspectState()
	for _, key in ipairs(aliases or {}) do
		if key and state.cache[key] then
			return state.cache[key]
		end
	end
	return nil
end

function RC:_GetInspectAliases(unit, info)
	local aliases = {}
	local guid = GetAccessibleUnitGUID(unit)
	local id = info and info.id or nil

	if not CanAccessValue(id) then
		id = nil
	end

	if not id and unit and UnitFullName then
		local name, realm = UnitFullName(unit)
		if CanAccessValue(name) and CanAccessValue(realm) then
			id = NormalizeNameRealm(name, realm)
		end
	end

	if guid and guid ~= "" then
		aliases[#aliases + 1] = guid
	end
	if id and id ~= "" then
		aliases[#aliases + 1] = id
	end

	return aliases, guid, id
end

function RC:_NotifyTroubleshootingListeners(force)
	local state = self:_GetInspectState()
	local version = state.snapshotVersion or 0
	if not force and state.lastNotifiedVersion == version then
		return version
	end

	state.lastNotifiedVersion = version
	for _, callback in pairs(state.listeners) do
		pcall(callback, version)
	end
	return version
end

function RC:_ClearPreparedSlotCaches()
	local state = self:_GetInspectState()
	if state.localSnapshot then
		state.localSnapshot.preparedSlotsByConfig = {}
	end

	local seen = {}
	for _, entry in pairs(state.cache) do
		if type(entry) == "table" and not seen[entry] then
			seen[entry] = true
			entry.preparedSlotsByConfig = {}
		end
	end

	local profile = GetProfile()
	if profile and type(profile.GetRaidCheckEquipmentSnapshotIds) == "function" then
		for _, memberId in ipairs(profile:GetRaidCheckEquipmentSnapshotIds() or {}) do
			local snapshot = profile:GetRaidCheckEquipmentSnapshot(memberId)
			if type(snapshot) == "table" then
				snapshot.preparedSlotsByConfig = {}
			end
		end
	end
end

function RC:_ScheduleTooltipDataRefresh()
	local state = self:_GetInspectState()
	if not next(state.listeners) then
		return
	end
	if state.tooltipRefreshScheduled then
		return
	end
	if not (C_Timer and C_Timer.After) then
		self:_ClearPreparedSlotCaches()
		self:_MarkTroubleshootingDirty()
		self:_NotifyTroubleshootingListeners()
		return
	end

	state.tooltipRefreshScheduled = true
	C_Timer.After(0.25, function()
		local current = self:_GetInspectState()
		current.tooltipRefreshScheduled = false
		if not next(current.listeners) then
			return
		end
		self:_ClearPreparedSlotCaches()
		self:_MarkTroubleshootingDirty()
		self:_NotifyTroubleshootingListeners()
	end)
end

function RC:RegisterTroubleshootingListener(key, callback)
	if not key or type(callback) ~= "function" then
		return
	end

	local state = self:_GetInspectState()
	state.listeners[key] = callback
end

function RC:UnregisterTroubleshootingListener(key)
	if not key then
		return
	end

	local state = self:_GetInspectState()
	state.listeners[key] = nil
end

function RC:_InvalidateInspectAliases(aliases)
	local state = self:_GetInspectState()
	for _, key in ipairs(aliases or {}) do
		if key then
			state.cache[key] = nil
			state.queued[key] = nil
		end
	end
end

function RC:_InvalidateInspectUnit(unit)
	if not unit then
		return
	end

	if IsSelfUnit(unit) then
		self:_InvalidateLocalTroubleshootingSnapshot()
		self:_MarkTroubleshootingDirty()
		if SF.Debug then
			SF.Debug:Verbose("RAID_CHECK", "Player inventory changed; notifying troubleshooting listeners")
		end
		self:_NotifyTroubleshootingListeners()
		return
	end

	local aliases = self:_GetInspectAliases(unit)
	self:_InvalidateInspectAliases(aliases)
	self:_MarkTroubleshootingDirty()
	self:_NotifyTroubleshootingListeners()
end

function RC:_PrimeBackgroundInspectQueue()
	local state = self:_GetInspectState()
	if not state.backgroundInspectEnabled then
		return
	end

	if not HasActiveLootHelperSession() or IsInspectPausedForCombat() or self:_IsInspectPausedForManual() then
		return
	end

	local now = GetTime and GetTime() or 0

	for _, unit in ipairs(CollectUnits()) do
		if not IsSelfUnit(unit) then
			local info = BuildUnitInfo(unit)
			if info.id then
				local aliases = self:_GetInspectAliases(unit, info)
				local cacheEntry = self:_GetInspectCacheEntryByAliases(aliases)
				local hasFreshData = cacheEntry
					and cacheEntry.updatedAt
					and (now - cacheEntry.updatedAt) <= INSPECT_CACHE_TTL_SECONDS

				if not hasFreshData then
					self:_QueueInspectForUnit(unit, info, cacheEntry)
				end
			end
		end
	end
end

function RC:_RunBackgroundInspectPass()
	self:_PrimeBackgroundInspectQueue()
end

function RC:_StartBackgroundInspectMonitor()
	local state = self:_GetInspectState()
	if not state.backgroundInspectEnabled or state.backgroundMonitorStarted or not (C_Timer and C_Timer.After) then
		return
	end

	state.backgroundMonitorStarted = true

	local function BackgroundInspectTick()
		if not self._inspectFrame then
			self:_GetInspectState().backgroundMonitorStarted = false
			return
		end

		if not self:_GetInspectState().backgroundInspectEnabled then
			self:_GetInspectState().backgroundMonitorStarted = false
			return
		end

		self:_RunBackgroundInspectPass()
		C_Timer.After(BACKGROUND_INSPECT_POLL_SECONDS, BackgroundInspectTick)
	end

	C_Timer.After(BACKGROUND_INSPECT_POLL_SECONDS, BackgroundInspectTick)
end

function RC:_PauseInspectForCombat()
	local state = self:_GetInspectState()
	if state.inspectPausedForCombat then
		return
	end

	state.inspectPausedForCombat = true

	if state.active then
		local active = state.active
		state.active = nil

		if active.key and not state.queued[active.key] then
			state.queued[active.key] = true
			local insertAt = state.queueHead
			table.insert(state.queue, insertAt, {
				key = active.key,
				guid = active.guid,
				id = active.id,
				aliases = active.aliases,
			})
		end

		if ClearInspectPlayer then
			pcall(ClearInspectPlayer)
		end
	end

	self:_MarkTroubleshootingDirty()
	self:_NotifyTroubleshootingListeners()
end

function RC:_ResumeInspectAfterCombat()
	local state = self:_GetInspectState()
	if not state.inspectPausedForCombat then
		return
	end

	state.inspectPausedForCombat = false
	self:_ProcessInspectQueue()
	self:_RunBackgroundInspectPass()
	self:_MarkTroubleshootingDirty()
	self:_NotifyTroubleshootingListeners()
end

function RC:EnsureInspectSupport()
	if self._inspectFrame then
		return
	end

	local frame = CreateFrame("Frame")
	self._inspectFrame = frame
	frame:RegisterEvent("ADDON_LOADED")
	frame:RegisterEvent("INSPECT_READY")
	frame:RegisterEvent("GROUP_ROSTER_UPDATE")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:RegisterEvent("PLAYER_REGEN_DISABLED")
	frame:RegisterEvent("PLAYER_REGEN_ENABLED")
	frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
	frame:RegisterEvent("UNIT_INVENTORY_CHANGED")
	frame:RegisterEvent("TOOLTIP_DATA_UPDATE")
	frame:SetScript("OnEvent", function(_, event, arg1)
		if event == "ADDON_LOADED" then
			if arg1 == "Blizzard_InspectUI" then
				self:_HookInspectUI()
			end
		elseif event == "INSPECT_READY" then
			self:_HandleInspectReady(arg1)
		elseif event == "PLAYER_REGEN_DISABLED" then
			self:_PauseInspectForCombat()
		elseif event == "PLAYER_REGEN_ENABLED" then
			self:_ResumeInspectAfterCombat()
		elseif event == "PLAYER_EQUIPMENT_CHANGED" then
			if SF.Debug then
				SF.Debug:Verbose("RAID_CHECK", "PLAYER_EQUIPMENT_CHANGED fired for slot %s; invalidating player inventory state and notifying troubleshooting listeners", tostring(arg1))
			end
			self:_InvalidateInspectUnit("player")
		elseif event == "UNIT_INVENTORY_CHANGED" then
			self:_InvalidateInspectUnit(arg1)
		elseif event == "TOOLTIP_DATA_UPDATE" then
			self:_ScheduleTooltipDataRefresh()
		elseif event == "PLAYER_ENTERING_WORLD" then
			local state = self:_GetInspectState()
			-- Preserve cached inspect snapshots across zoning so the Equipment
			-- page can still show the last known remote gear until a fresh
			-- inspect becomes possible again. Leave state.cache intact, but
			-- clear queue-related state before resuming normal inspect flow.
			state.queue = {}
			state.queueHead = 1
			state.queued = {}
			state.active = nil
			self:_InvalidateLocalTroubleshootingSnapshot()
			self:_MarkTroubleshootingDirty()
			if ClearInspectPlayer then
				pcall(ClearInspectPlayer)
			end
			self:_NotifyTroubleshootingListeners()
			self:_RunBackgroundInspectPass()
		elseif event == "GROUP_ROSTER_UPDATE" then
			self:_MarkTroubleshootingDirty()
			self:_NotifyTroubleshootingListeners()
			self:_ProcessInspectQueue()
			self:_RunBackgroundInspectPass()
		end
	end)

	if IsInspectPausedForCombat() then
		self:_GetInspectState().inspectPausedForCombat = true
	end
	self:_HookInspectUI()
	self:_StartBackgroundInspectMonitor()
end

function RC:_HookInspectUI()
	if not self._inspectUnitHookInstalled and hooksecurefunc and type(InspectUnit) == "function" then
		self._inspectUnitHookInstalled = true
		hooksecurefunc("InspectUnit", function()
			if RC and RC._PauseInspectForManualInspect then
				RC:_PauseInspectForManualInspect("InspectUnit")
			end
		end)
	end

	if InspectFrame and InspectFrame.HookScript and not InspectFrame.__sfRaidCheckHooked then
		InspectFrame.__sfRaidCheckHooked = true

		InspectFrame:HookScript("OnShow", function()
			if RC and RC._PauseInspectForManualInspect then
				RC:_PauseInspectForManualInspect("InspectFrame shown")
			end
		end)

		InspectFrame:HookScript("OnHide", function()
			if RC and RC._OnInspectFrameHidden then
				RC:_OnInspectFrameHidden()
			end
		end)
	end
end

function RC:_HandleInspectTimeout(key, requestedAt)
	local state = self:_GetInspectState()
	local active = state.active
	if not active or active.key ~= key or active.requestedAt ~= requestedAt then
		return
	end

	local now = GetTime and GetTime() or 0
	local entry = self:_GetInspectCacheEntryByAliases(active.aliases) or {}
	local failCount = (entry.failCount or 0) + 1

	entry.status = "timeout"
	entry.failCount = failCount
	entry.lastAttemptAt = requestedAt
	-- Use a short capped linear backoff so repeated failures do not hammer
	-- NotifyInspect, while still recovering quickly once the player becomes
	-- inspectable again. The delay scales from INSPECT_RETRY_BASE_SECONDS up
	-- to INSPECT_RETRY_MAX_SECONDS.
	entry.nextRetryAt = now + CalculateInspectRetryDelay(failCount)
	self:_StoreInspectCacheEntry(entry, active.aliases)

	state.active = nil
	if ClearInspectPlayer then
		pcall(ClearInspectPlayer)
	end

	self:_MarkTroubleshootingDirty()
	self:_NotifyTroubleshootingListeners()
	self:_ProcessInspectQueue()
end

function RC:_HandleInspectReady(guid)
	local state = self:_GetInspectState()
	local active = state.active
	if not active then
		return
	end
	if not CanAccessValue(guid) then
		guid = nil
	end
	if not CanAccessValue(active.guid) then
		active.guid = nil
	end
	if guid and active.guid and guid ~= active.guid then
		return
	end

	local unit = FindUnitByGuidOrId(guid or active.guid, active.id)
	if not unit and active.unit and UnitExists and UnitExists(active.unit) then
		unit = active.unit
	end

	local entry = self:_GetInspectCacheEntryByAliases(active.aliases) or {}
	local now = GetTime and GetTime() or 0
	local captured = unit and CaptureTroubleshootingInventory(unit) or nil

	if captured and type(captured.slotsByInventory) == "table" then
		-- Occasionally, inspect responses return partial inventory data (certain
		-- slots missing link/texture temporarily). Prefer the new snapshot where
		-- it has real data, but do not overwrite a previously-known slot with a
		-- completely blank result.
		local fallbackSlots = entry and entry.slotsByInventory or nil
		if type(fallbackSlots) == "table" then
			for inventorySlot, fallbackSlot in pairs(fallbackSlots) do
				if type(inventorySlot) == "number" and type(fallbackSlot) == "table" then
					local nextSlot = captured.slotsByInventory[inventorySlot]
					local hasNext = SlotHasAnyItemData(nextSlot) or (type(nextSlot) == "table" and nextSlot.texture) or false
					local hasFallback = SlotHasAnyItemData(fallbackSlot) or fallbackSlot.texture or false
					if (not hasNext) and hasFallback then
						local copy = {}
						for key, value in pairs(fallbackSlot) do
							copy[key] = value
						end
						NormalizeSlotData(copy)
						captured.slotsByInventory[inventorySlot] = copy
					else
						NormalizeSlotData(nextSlot)
					end
				end
			end
		else
			for _, slotData in pairs(captured.slotsByInventory) do
				NormalizeSlotData(slotData)
			end
		end

		RecalculateCapturedSummary(captured)
	end

	if captured and captured.sawAnyData then
		entry.guid = guid or active.guid
		entry.id = active.id
		entry.status = "ready"
		entry.failCount = 0
		entry.lastAttemptAt = active.requestedAt
		entry.nextRetryAt = nil
		entry.updatedAt = now
		entry.capturedAt = GetServerTime and GetServerTime() or nil
		entry.averageItemLevel = captured.averageItemLevel
		entry.slotsByInventory = captured.slotsByInventory
		PersistProfileEquipmentSnapshot(active.id, captured)

		-- If any tracked slot has evidence of an item (texture/itemId) but the
		-- link is unavailable, or the link looks like an incomplete stub, the
		-- data is only partially loaded.  Shorten the cache freshness window so
		-- the background poll re-inspects this player sooner rather than waiting
		-- the full TTL.
		if type(captured.slotsByInventory) == "table" then
			for _, column in ipairs(TROUBLESHOOTING_COLUMNS) do
				if IsSlotItemDataPending(captured.slotsByInventory, column.inventorySlot)
					or IsSlotLinkPotentiallyIncomplete(captured.slotsByInventory, column.inventorySlot) then
					entry.updatedAt = now - (INSPECT_CACHE_TTL_SECONDS - INSPECT_RETRY_BASE_SECONDS)
					break
				end
			end
		end
	else
		entry.status = "timeout"
		entry.failCount = (entry.failCount or 0) + 1
		entry.lastAttemptAt = active.requestedAt
		-- Use a short capped linear backoff so repeated failures do not hammer
		-- NotifyInspect, while still recovering quickly once the player becomes
		-- inspectable again. The delay scales from INSPECT_RETRY_BASE_SECONDS up
		-- to INSPECT_RETRY_MAX_SECONDS.
		entry.nextRetryAt = now + CalculateInspectRetryDelay(entry.failCount)
	end

	self:_StoreInspectCacheEntry(entry, active.aliases)
	state.active = nil
	if ClearInspectPlayer then
		pcall(ClearInspectPlayer)
	end

	self:_MarkTroubleshootingDirty()
	self:_NotifyTroubleshootingListeners()
	self:_ProcessInspectQueue()
end

function RC:_ProcessInspectQueue()
	local state = self:_GetInspectState()
	if state.active or state.inspectPausedForCombat or self:_IsInspectPausedForManual() then
		return
	end

	while state.queueHead <= #state.queue do
		local item = state.queue[state.queueHead]
		-- Keep the numeric keys dense until the queue drains so `#state.queue`
		-- continues to reflect the tail correctly while we advance queueHead.
		state.queue[state.queueHead] = false
		state.queueHead = state.queueHead + 1
		if item and item.key then
			state.queued[item.key] = nil
		end

		local unit = item and FindUnitByGuidOrId(item.guid, item.id) or nil
		if CanInspectUnitNow(unit) then
			local now = GetTime and GetTime() or 0
			state.active = {
				key = item.key,
				guid = (CanAccessValue(item.guid) and item.guid) or GetAccessibleUnitGUID(unit),
				id = item.id,
				aliases = item.aliases,
				unit = unit,
				requestedAt = now,
			}

			local entry = self:_GetInspectCacheEntryByAliases(item.aliases) or {}
			entry.lastAttemptAt = now
			self:_StoreInspectCacheEntry(entry, item.aliases)

			NotifyInspect(unit)
			if C_Timer and C_Timer.After then
				C_Timer.After(INSPECT_REQUEST_TIMEOUT_SECONDS, function()
					-- The active-request guard in _HandleInspectTimeout ignores stale callbacks
					-- once INSPECT_READY advances the queue or a newer request replaces this one.
					if self and self._HandleInspectTimeout then
						self:_HandleInspectTimeout(item.key, now)
					end
				end)
			end
			return
		end
	end

	if state.queueHead > #state.queue then
		state.queue = {}
		state.queueHead = 1
	end
end

function RC:_QueueInspectForUnit(unit, info, cacheEntry)
	if not unit or IsSelfUnit(unit) then
		return
	end

	if not CanInspectUnitNow(unit) then
		return
	end

	local state = self:_GetInspectState()
	local aliases, guid, id = self:_GetInspectAliases(unit, info)
	local key = guid or id
	local now = GetTime and GetTime() or 0

	if not key or (cacheEntry and cacheEntry.nextRetryAt and cacheEntry.nextRetryAt > now) then
		return
	end
	if state.active and state.active.key == key then
		return
	end
	if state.queued[key] then
		return
	end

	state.queued[key] = true
	table.insert(state.queue, {
		key = key,
		guid = guid,
		id = id,
		aliases = aliases,
	})
	self:_ProcessInspectQueue()
end

function RC:RequestTroubleshootingRefresh()
	self:EnsureInspectSupport()
	self:_InvalidateLocalTroubleshootingSnapshot()

	for _, unit in ipairs(CollectUnits()) do
		local info = BuildUnitInfo(unit)
		if info.id then
			local aliases = self:_GetInspectAliases(unit, info)
			local cacheEntry = self:_GetInspectCacheEntryByAliases(aliases)
			if type(cacheEntry) == "table" then
				cacheEntry.updatedAt = nil
				cacheEntry.nextRetryAt = nil
				self:_StoreInspectCacheEntry(cacheEntry, aliases)
			end
			self:_QueueInspectForUnit(unit, info, cacheEntry)
		end
	end

	self:_MarkTroubleshootingDirty()
	self:_NotifyTroubleshootingListeners()
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

	local missing = {}

	-- If the link has all modification fields zeroed (enchant, gems, suffix),
	-- it may be a stub that has not fully resolved.  Skip enchant/gem checks
	-- to avoid false positives; the background poll will re-check soon.
	local itemString = link:match("item:([%-%d:]+)")
	local linkMayBeIncomplete = false
	if itemString then
		local fields = { strsplit(":", itemString) }
		if #fields >= 7 then
			linkMayBeIncomplete = true
			for i = 2, math.min(7, #fields) do
				local v = fields[i]
				if v and v ~= "" and v ~= "0" then
					linkMayBeIncomplete = false
					break
				end
			end
		end
	end

	if not linkMayBeIncomplete and IsSlotEnabledInConfig(cfg, slotKey, link) and ShouldCheckEnchant(slotDef, link) and not HasEnchant(link) then
		table.insert(missing, label .. " Enchant")
	end

	if cfg and cfg.checkGemsInSockets ~= false and HasMissingGems(link) then
		table.insert(missing, label .. " Gem")
	end

	return missing
end

local function BuildMissingForSlotSnapshot(slotsByInventory, slotKey, slotDef, idx, mainHandLink, cfg)
	local inventorySlot = slotDef.slots[idx]
	local link = GetSnapshotSlotLink(slotsByInventory, inventorySlot)
	local label = slotDef.label
	if #slotDef.slots > 1 then
		label = string.format("%s %d", label, idx)
	end

	if not link then
		if slotDef == SLOT_DEFS.offHand and mainHandLink and IsTwoHandWeapon(mainHandLink) then
			return {}, false
		end
		if not IsSlotEnabledInConfig(cfg, slotKey, nil) then
			return {}, false
		end
		-- If the slot has evidence of an equipped item (texture/itemId) but the
		-- link has not loaded yet, do not report it as definitively missing.
		-- Signal the caller that this slot is still pending item data.
		if IsSlotItemDataPending(slotsByInventory, inventorySlot) then
			return {}, true
		end
		return { label .. " Item" }, false
	end

	-- If the link looks like an incomplete stub (all modification fields are
	-- zero), do not flag enchant requirements as missing. Gem checks still run
	-- because a resolved unenchanted item with empty sockets has the same
	-- zeroed early fields.
	if IsSlotLinkPotentiallyIncomplete(slotsByInventory, inventorySlot) then
		if cfg and cfg.checkGemsInSockets ~= false and HasMissingGems(link) then
			return { label .. " Gem" }, false
		end
		return {}, true
	end

	local missing = {}
	if IsSlotEnabledInConfig(cfg, slotKey, link) and ShouldCheckEnchant(slotDef, link) and not HasEnchant(link) then
		table.insert(missing, label .. " Enchant")
	end

	if cfg and cfg.checkGemsInSockets ~= false and HasMissingGems(link) then
		table.insert(missing, label .. " Gem")
	end

	return missing, false
end

local function HasEquippedMetaGemInSnapshot(slotsByInventory)
	local unresolved = false
	for _, slotDef in pairs(SLOT_DEFS) do
		for idx = 1, #slotDef.slots do
			local link = GetSnapshotSlotLink(slotsByInventory, slotDef.slots[idx])
			if type(link) == "string" then
				for gemIndex = 1, MAX_GEM_SOCKETS_TO_SCAN do
					local gemName, gemLink, gemID = GetSocketedGemIdentity(link, gemIndex)
					local isMeta, qualityPending = IsMetaGemSocketed(gemName, gemLink, gemID)
					if isMeta then
						return true, false
					end
					if qualityPending then
						unresolved = true
					end
				end
			end
		end
	end

	return false, unresolved
end

local function EvaluateSnapshot(slotsByInventory, cfg)
	local mainHandLink = GetSnapshotSlotLink(slotsByInventory, INVSLOT_MAINHAND)
	local missing = {}
	local hasItemDataPending = false

	for slotKey, slotDef in pairs(SLOT_DEFS) do
		for idx = 1, #slotDef.slots do
			local slotMissing, slotPending = BuildMissingForSlotSnapshot(slotsByInventory, slotKey, slotDef, idx, mainHandLink, cfg)
			if slotPending then
				hasItemDataPending = true
			end
			for _, entry in ipairs(slotMissing) do
				table.insert(missing, entry)
			end
		end
	end

	if cfg and cfg.requireMetaGem then
		local hasMetaGem, metaGemPending = HasEquippedMetaGemInSnapshot(slotsByInventory)
		if metaGemPending and not hasMetaGem then
			hasItemDataPending = true
		elseif not hasMetaGem then
			table.insert(missing, "Meta Gem")
		end
	end

	return missing, hasItemDataPending
end

local function EvaluateMetaGemRowState(slotsByInventory, cfg, isKnown)
	if not (cfg and cfg.requireMetaGem and isKnown and type(slotsByInventory) == "table") then
		return false, false
	end

	local hasMetaGem, metaGemPending = HasEquippedMetaGemInSnapshot(slotsByInventory)
	if hasMetaGem then
		return false, false
	end

	return not metaGemPending, metaGemPending and true or false
end

local function BuildTroubleshootingSlotBase(column, mainHandLink, cfg, sourceSlot, isKnown)
	local inventorySlot = column and column.inventorySlot
	local slotKey = column and column.key
	local link = sourceSlot and sourceSlot.link or nil
	local itemId = sourceSlot and sourceSlot.itemId or nil
	local hasItem = sourceSlot and (sourceSlot.hasItem or link or itemId or sourceSlot.texture) and true or false
	local configEnabled = IsSlotEnabledInConfig(cfg, slotKey, link)
	if not configEnabled and slotKey == "offHand" and hasItem and not link and cfg and type(cfg.slots) == "table" then
		-- If we can tell something is equipped in the offhand, but item metadata
		-- isn't available yet, treat the slot as tracked if either the physical
		-- offhand toggle or the logical weapon toggle is enabled.
		configEnabled = (cfg.slots.offHand or cfg.slots.weapon) and true or false
	end
	local twoHandExempt = isKnown and (slotKey == "offHand") and (not hasItem) and mainHandLink and IsTwoHandWeapon(mainHandLink) or false
	local shouldCheckEnchant = isKnown and link and configEnabled and ShouldCheckTroubleshootingEnchant(slotKey, link) or false
	local hasEnchant = isKnown and link and HasEnchant(link) or false

	-- Detect potentially incomplete links: if the link is a stub with all
	-- modification fields zeroed, suppress false missing-enchant/gem alerts
	-- until the data fully resolves on the next inspect cycle.
	local linkIncomplete = false
	if isKnown and link and sourceSlot then
		local tempSlots = { [inventorySlot] = sourceSlot }
		linkIncomplete = IsSlotLinkPotentiallyIncomplete(tempSlots, inventorySlot)
	end

	local missingEnchant = shouldCheckEnchant and not hasEnchant and not linkIncomplete
	-- Gem checks are independent of enchant-slot toggles and of the stub-link
	-- guard. A fully resolved unenchanted item with an empty prismatic socket
	-- has zeroed enchant/gem fields and must still blink for missing gems.
	local missingGems = isKnown and link and cfg and cfg.checkGemsInSockets ~= false and HasMissingGems(link) or false
	local missingItem = isKnown and (not hasItem) and configEnabled and not twoHandExempt
	local skippedEnchant = isKnown and link and configEnabled and not shouldCheckEnchant
	local itemDataPending = ((isKnown and hasItem and not link) or linkIncomplete) and true or false

	return {
		key = slotKey,
		label = column and column.label or tostring(slotKey or "Slot"),
		shortLabel = column and column.shortLabel or tostring(slotKey or "Slot"),
		inventorySlot = inventorySlot,
		configKey = GetRaidCheckSlotConfigKey(slotKey, link),
		configEnabled = configEnabled and true or false,
		known = isKnown and true or false,
		link = link,
		itemId = itemId,
		hasItem = hasItem,
		texture = sourceSlot and sourceSlot.texture or nil,
		expectedEnchant = shouldCheckEnchant and true or false,
		hasEnchant = hasEnchant and true or false,
		missingEnchant = missingEnchant and true or false,
		missingGems = missingGems and true or false,
		missingItem = missingItem and true or false,
		skippedEnchant = skippedEnchant and true or false,
		itemDataPending = itemDataPending,
	}
end

local function BuildTroubleshootingSlot(column, mainHandLink, cfg, sourceSlot, inspectState)
	local slot = BuildTroubleshootingSlotBase(
		column,
		mainHandLink,
		cfg,
		sourceSlot,
		inspectState and inspectState.isKnown and true or false
	)
	slot.inspectStatus = inspectState and inspectState.status or "ready"
	slot.inspectMessage = inspectState and inspectState.message or nil
	slot.stale = inspectState and inspectState.stale and true or false
	return slot
end

local function BuildTroubleshootingSlots(inspectState, cfg)
	local isKnown = inspectState and inspectState.isKnown and inspectState.slotsByInventory
	local cacheHolder = inspectState and inspectState.cacheHolder or nil
	local configSignature = BuildTroubleshootingConfigSignature(cfg)
	local cachedBaseSlots = nil
	local slots = {}
	local mainHandLink = nil

	if isKnown and inspectState.slotsByInventory[INVSLOT_MAINHAND] then
		mainHandLink = inspectState.slotsByInventory[INVSLOT_MAINHAND].link
	end

	if cacheHolder and isKnown then
		-- Remote inspect snapshots and the cached local-player snapshot can both
		-- reuse slot audit results until their source data or profile settings change.
		cacheHolder.preparedSlotsByConfig = cacheHolder.preparedSlotsByConfig or {}
		cachedBaseSlots = cacheHolder.preparedSlotsByConfig[configSignature]
		if not cachedBaseSlots then
			cachedBaseSlots = {}
			for index, column in ipairs(TROUBLESHOOTING_COLUMNS) do
				local sourceSlot = inspectState.slotsByInventory[column.inventorySlot]
				cachedBaseSlots[index] = BuildTroubleshootingSlotBase(column, mainHandLink, cfg, sourceSlot, true)
			end
			cacheHolder.preparedSlotsByConfig[configSignature] = cachedBaseSlots
		end
	end

	for index, column in ipairs(TROUBLESHOOTING_COLUMNS) do
		if cachedBaseSlots then
			local cached = cachedBaseSlots[index]
			local slot = {}
			if cached then
				for key, value in pairs(cached) do
					slot[key] = value
				end
			end
			slot.inspectStatus = inspectState and inspectState.status or "ready"
			slot.inspectMessage = inspectState and inspectState.message or nil
			slot.stale = inspectState and inspectState.stale and true or false
			slots[index] = slot
		else
			local sourceSlot = inspectState and inspectState.slotsByInventory and inspectState.slotsByInventory[column.inventorySlot] or nil
			slots[index] = BuildTroubleshootingSlot(column, mainHandLink, cfg, sourceSlot, inspectState)
		end
	end

	return slots
end

function RC:_GetTroubleshootingInspectState(unit, info)
	self:EnsureInspectSupport()
	local memberId = info and info.id or nil

	if IsSelfUnit(unit) then
		local captured = self:_GetLocalTroubleshootingSnapshot()
		return {
			status = "ready",
			isKnown = true,
			averageItemLevel = captured.averageItemLevel,
			slotsByInventory = captured.slotsByInventory,
			message = nil,
			label = nil,
			stale = false,
			cacheHolder = captured,
		}
	end

	local aliases = self:_GetInspectAliases(unit, info)
	local cacheEntry = self:_GetInspectCacheEntryByAliases(aliases)
	local profileSnapshot = GetProfileEquipmentSnapshot(memberId)
	local now = GetTime and GetTime() or 0
	local hasFreshData = cacheEntry and cacheEntry.updatedAt and (now - cacheEntry.updatedAt) <= INSPECT_CACHE_TTL_SECONDS
	local hasFreshCachedSnapshot = cacheEntry and cacheEntry.slotsByInventory and IsEquipmentSnapshotFresh(cacheEntry)
	local hasFreshProfileSnapshot = profileSnapshot and profileSnapshot.slotsByInventory and IsEquipmentSnapshotFresh(profileSnapshot)

	if hasFreshData and cacheEntry.slotsByInventory then
		return {
			status = "ready",
			isKnown = true,
			averageItemLevel = cacheEntry.averageItemLevel,
			slotsByInventory = cacheEntry.slotsByInventory,
			entry = cacheEntry,
			cacheHolder = cacheEntry,
		}
	end

	local pausedForCombat = IsInspectPausedForCombat()
	local pausedForManual = self:_IsInspectPausedForManual()
	local inRange = pausedForCombat and false or IsUnitInInspectRange(unit)
	local canInspectNow = CanInspectUnitNow(unit)
	local state = self:_GetInspectState()
	local activeKey = state.active and state.active.key or nil
	local key = aliases[1] or aliases[2]
	local isInspectActive = activeKey == key
	local isQueued = not not (key and state.queued and state.queued[key])
	local hasInspectActivity = isInspectActive or isQueued or canInspectNow

	if canInspectNow and not pausedForManual then
		self:_QueueInspectForUnit(unit, info, cacheEntry)
	end

	if hasFreshCachedSnapshot then
		local status = "ready"
		local label = nil
		local message = nil

		if pausedForCombat then
			status = "paused"
			label = "Paused"
			message = "Showing cached inspect data until combat ends."
		elseif pausedForManual then
			status = "paused"
			label = "Paused"
			message = "Showing cached inspect data while the Inspect window is open."
		elseif isInspectActive or isQueued then
			status = "refreshing"
			label = "Refreshing"
			message = "Showing cached inspect data while a fresh snapshot loads."
		elseif not inRange then
			message = "Showing cached inspect data. Move closer to refresh this player."
		end

		return {
			status = status,
			label = label,
			message = message,
			isKnown = true,
			averageItemLevel = cacheEntry.averageItemLevel,
			slotsByInventory = cacheEntry.slotsByInventory,
			entry = cacheEntry,
			stale = false,
			cacheHolder = cacheEntry,
		}
	end

	if hasFreshProfileSnapshot then
		local status = "saved"
		local label = "Saved"
		local message = BuildSavedSnapshotMessage(profileSnapshot, false)

		if pausedForCombat then
			status = "paused"
			label = "Paused"
			message = "Showing the saved profile snapshot until combat ends."
		elseif pausedForManual then
			status = "paused"
			label = "Paused"
			message = "Showing the saved profile snapshot while the Inspect window is open."
		elseif isInspectActive then
			status = "refreshing"
			label = "Refreshing"
			message = BuildSavedSnapshotMessage(profileSnapshot, true)
		elseif isQueued or canInspectNow then
			status = "loading"
			label = "Loading"
			message = BuildSavedSnapshotMessage(profileSnapshot, true)
		elseif not inRange then
			message = BuildSavedSnapshotMessage(profileSnapshot, false) .. " Move closer to refresh this player."
		end

		return {
			status = status,
			label = label,
			message = message,
			isKnown = true,
			averageItemLevel = profileSnapshot.averageItemLevel,
			slotsByInventory = profileSnapshot.slotsByInventory,
			entry = profileSnapshot,
			stale = true,
			cacheHolder = profileSnapshot,
		}
	end

	-- Stale-but-available data: if equipment data exists (even beyond the
	-- freshness window), return it as known so raid checks can evaluate it
	-- rather than reporting the player as pending/unavailable.  The background
	-- inspect system will continue to attempt refreshes independently.
	local hasStaleCachedData = cacheEntry and cacheEntry.slotsByInventory and HasEquipmentData(cacheEntry.slotsByInventory)
	local hasStaleProfileData = (not hasStaleCachedData)
		and profileSnapshot and profileSnapshot.slotsByInventory
		and HasEquipmentData(profileSnapshot.slotsByInventory)

	if hasStaleCachedData then
		return {
			status = "stale",
			label = nil,
			message = "Showing older cached inspect data. Background refresh will update when possible.",
			isKnown = true,
			averageItemLevel = cacheEntry.averageItemLevel,
			slotsByInventory = cacheEntry.slotsByInventory,
			entry = cacheEntry,
			stale = true,
			cacheHolder = cacheEntry,
		}
	end

	if hasStaleProfileData then
		return {
			status = "stale",
			label = nil,
			message = BuildSavedSnapshotMessage(profileSnapshot, false),
			isKnown = true,
			averageItemLevel = profileSnapshot.averageItemLevel,
			slotsByInventory = profileSnapshot.slotsByInventory,
			entry = profileSnapshot,
			stale = true,
			cacheHolder = profileSnapshot,
		}
	end

	if cacheEntry and cacheEntry.nextRetryAt and cacheEntry.nextRetryAt > now then
		return {
			status = "retrying",
			label = "Retrying",
			message = "Last inspect attempt timed out. Raid Check will retry shortly.",
			isKnown = false,
			stale = false,
		}
	end

	if pausedForCombat then
		return {
			status = "paused",
			label = "Paused",
			message = "Inspect is paused during combat and will resume afterwards.",
			isKnown = false,
			stale = false,
		}
	end

	if pausedForManual then
		return {
			status = "paused",
			label = "Paused",
			message = "Inspect is paused while the Inspect window is open.",
			isKnown = false,
			stale = false,
		}
	end

	if hasInspectActivity then
		return {
			status = "loading",
			label = "Loading",
			message = "Inspect data is loading for this player.",
			isKnown = false,
			stale = false,
		}
	end

	if not inRange then
		return {
			status = "out_of_range",
			label = "Out of range",
			message = "Move closer to inspect this player.",
			isKnown = false,
			stale = false,
		}
	end

	return {
		status = "unavailable",
		label = "Unavailable",
		message = "This player cannot be inspected right now.",
		isKnown = false,
		stale = false,
	}
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

local function FormatPointAmount(amount)
	amount = tonumber(amount) or 0
	if amount == math.floor(amount) then
		return tostring(amount)
	end

	local text = string.format("%.2f", amount)
	text = text:gsub("0+$", ""):gsub("%.$", "")
	return text
end

local function RenderWhisperTemplate(template, vars)
	if type(template) ~= "string" or template == "" then
		return nil
	end

	vars = type(vars) == "table" and vars or {}
	return (template:gsub("%{([%w_]+)%}", function(key)
		local value = vars[key]
		if value == nil then
			return "{" .. key .. "}"
		end
		return tostring(value)
	end))
end

local function GetRaidCheckPointAward(cfg)
	if type(cfg) ~= "table" then
		return RAID_CHECK_POINT_AWARD_DEFAULT
	end

	local amount = tonumber(cfg.pointsAwardPerRaidCheck)
	if amount == nil then
		return RAID_CHECK_POINT_AWARD_DEFAULT
	end

	amount = math.max(0, math.min(1, amount))
	amount = math.floor((amount / 0.5) + 0.5) * 0.5
	return amount
end

local function AwardPrepared(profile, member, pointName, pointAward)
	if not member or not member.IncrementPoints then
		return false
	end

	local ok = member:IncrementPoints({
		amount = pointAward,
		logAuthor = "Raid Check",
		reason = RAID_CHECK_REASON,
	})

	if not ok then
		return false
	end

	if SF.Debug then
		local identifier = (member and member.GetFullIdentifier and member:GetFullIdentifier()) or "?"
		SF.Debug:Info("RAID_CHECK", "Awarded %s raid check points to %s", FormatPointAmount(pointAward), tostring(identifier))
	end

	return true
end

local function WhisperPrepared(target, cfg, playerName, pointName, pointAward)
	local template = type(cfg) == "table" and cfg.whisperTemplateRaidPrepared or nil
	local message = RenderWhisperTemplate(template, {
		player_name = playerName,
		point_name = pointName,
		points_awarded = FormatPointAmount(pointAward),
	})

	if not message then
		message = ("Spectrum Federation: You've been awarded %s %s. Thanks for showing up prepared and on time!"):format(FormatPointAmount(pointAward), pointName)
	end

	SendWhisper(target, message)
end

local function WhisperMissing(target, cfg, playerName, pointName, list, mode)
	local template
	if mode == "pre" then
		template = type(cfg) == "table" and cfg.whisperTemplatePreRaidMissing or nil
	else
		template = type(cfg) == "table" and cfg.whisperTemplateRaidMissing or nil
	end

	local message = RenderWhisperTemplate(template, {
		player_name = playerName,
		missing = list,
		point_name = pointName,
	})

	if not message then
		if mode == "pre" then
			message = ("Spectrum Federation: You're missing the following enchants/gems: %s."):format(list)
		else
			message = ("Spectrum Federation: You're missing the following enchants/gems: %s. No new %s awarded."):format(list, pointName)
		end
	end

	SendWhisper(target, message)
end

local function GetPointName(profile)
	if profile and profile.GetPointName then
		return profile:GetPointName()
	end
	return "Points"
end

BuildUnitInfo = function(unit)
	local name, realm = UnitFullName(unit)
	local id = NormalizeNameRealm(name, realm)
	local short = ShortName(id)
	return {
		unit = unit,
		id = id,
		short = short,
		displayName = ColorizeUnitName(unit, short),
	}
end

local function BuildProfileMemberInfo(profile, memberId)
	local short = ShortName(memberId)
	return {
		unit = nil,
		id = memberId,
		short = short,
		displayName = ColorizeProfileMemberName(profile, memberId, short),
	}
end

local function CollectTroubleshootingUnitsAndMembers(profile)
	local items = {}
	local seen = {}

	for _, unit in ipairs(CollectUnits()) do
		local info = BuildUnitInfo(unit)
		if info.id and not seen[info.id] then
			seen[info.id] = true
			items[#items + 1] = info
		end
	end

	if not IsInRaid() and not IsInGroup() and profile and type(profile.GetRaidCheckEquipmentSnapshotIds) == "function" then
		for _, memberId in ipairs(profile:GetRaidCheckEquipmentSnapshotIds() or {}) do
			if memberId and not seen[memberId] then
				seen[memberId] = true
				items[#items + 1] = BuildProfileMemberInfo(profile, memberId)
			end
		end
	end

	return items
end

local function FormatAverageItemLevel(value)
	if not value or value <= 0 then
		return nil
	end

	local rounded = math.floor((value * 10) + 0.5) / 10
	if math.abs(rounded - math.floor(rounded + 0.5)) < 0.05 then
		return tostring(math.floor(rounded + 0.5))
	end
	return string.format("%.1f", rounded)
end

local function ShouldWhisper(mode, cfg)
	if mode == "pre" then
		return cfg.enableWhispersPreRaid
	end
	return cfg.enableWhispersRaid
end

local function ShouldWhisperPrepared(cfg)
	if type(cfg) ~= "table" then
		return true
	end
	return cfg.enableWhispersRaidPrepared ~= false
end

local function GetWhisperDayKey(timestamp)
	local value = tonumber(timestamp)
	if not value then
		return nil
	end
	return date("%Y-%m-%d", value)
end

local function GetMostRecentWhisperTimestamp(member, mode)
	if type(member) ~= "table" then
		return nil
	end

	if mode == "pre" then
		if type(member.GetMostRecentPreRaidCheckWhisper) == "function" then
			return tonumber(member:GetMostRecentPreRaidCheckWhisper()) or nil
		end
		return tonumber(member.most_recent_pre_raid_check_whisper) or nil
	end

	if type(member.GetMostRecentRaidCheckWhisper) == "function" then
		return tonumber(member:GetMostRecentRaidCheckWhisper()) or nil
	end
	return tonumber(member.most_recent_raid_check_whisper) or nil
end

local function MarkWhisperSent(member, mode, timestamp)
	if type(member) ~= "table" then
		return
	end

	if mode == "pre" then
		if type(member.MarkPreRaidCheckWhisperSent) == "function" then
			member:MarkPreRaidCheckWhisperSent(timestamp)
		else
			member.most_recent_pre_raid_check_whisper = tonumber(timestamp) or time()
		end
		return
	end

	if type(member.MarkRaidCheckWhisperSent) == "function" then
		member:MarkRaidCheckWhisperSent(timestamp)
	else
		member.most_recent_raid_check_whisper = tonumber(timestamp) or time()
	end
end

local function HasBeenWhisperedToday(member, mode)
	local timestamp = GetMostRecentWhisperTimestamp(member, mode)
	if not timestamp then
		return false
	end

	local whisperDay = GetWhisperDayKey(timestamp)
	if not whisperDay then
		return false
	end


	local currentDay = GetWhisperDayKey(time())
	return whisperDay == currentDay
end

local function EmitAdminMessage(message)
	if type(message) ~= "string" or message == "" then
		return
	end
	if SF.SystemMessage then
		SF:SystemMessage(message)
	else
		SF:PrintWarning(message)
	end
end

local function EmitAdminMissingSummary(modeLabel, summaryMissing)
	if type(summaryMissing) ~= "table" or #summaryMissing == 0 then
		return
	end

	EmitAdminMessage(string.format("[%s] Players missing enchants/gems:", modeLabel))
	for _, entry in ipairs(summaryMissing) do
		local suffix = ""
		if entry.whisperedMissing then
			suffix = " (whispered)"
		elseif entry.alreadyWhispered then
			suffix = " (already whispered today)"
		end
		EmitAdminMessage(string.format("  %s - %s%s", entry.displayName or entry.name, entry.missing, suffix))
	end
end

local function EmitAdminPendingSummary(modeLabel, summaryPending)
	if type(summaryPending) ~= "table" or #summaryPending == 0 then
		return
	end

	SF:PrintInfo(string.format("[%s] Players still waiting on inspect data:", modeLabel))
	for _, entry in ipairs(summaryPending) do
		SF:PrintInfo(string.format("  %s - %s", entry.displayName or entry.name, entry.inspectPending))
	end
end

local function RunForUnit(unitInfo, profile, cfg, mode, pointName, pointAward)
	local inspectState = RC:_GetTroubleshootingInspectState(unitInfo.unit, unitInfo)
	local whisper = ShouldWhisper(mode, cfg)
	local whisperTarget = unitInfo.id or unitInfo.short
	local member = nil
	if whisper or mode == "raid" then
		member = FindMember(profile, unitInfo.id)
	end
	local result = {
		name = unitInfo.short,
		displayName = unitInfo.displayName or unitInfo.short,
		id = unitInfo.id,
		missing = nil,
		inspectPending = nil,
		whisperedMissing = false,
		alreadyWhispered = false,
	}

	if type(inspectState) ~= "table" then
		result.inspectPending = "Unavailable"
		return result
	end

	if not (inspectState.isKnown and HasEquipmentData(inspectState.slotsByInventory)) then
		result.inspectPending = inspectState and (inspectState.label or inspectState.status) or "Loading"
		return result
	end

	local missing, hasItemDataPending = EvaluateSnapshot(inspectState.slotsByInventory, cfg)

	-- If any tracked slot still has incomplete item data (texture/itemId present
	-- but link unavailable), treat the player as pending rather than definitively
	-- missing requirements.  This prevents false-positive whispers and raid check
	-- failures caused by partially-loaded item data.
	if hasItemDataPending then
		result.inspectPending = "Item data loading"
		return result
	end

	if #missing > 0 then
		local list = FormatMissingList(missing)
		local alreadyWhispered = HasBeenWhisperedToday(member, mode)
		if whisper and not alreadyWhispered then
			WhisperMissing(whisperTarget, cfg, unitInfo.short, pointName, list, mode)
			result.whisperedMissing = true
			MarkWhisperSent(member, mode, time())
		elseif whisper and alreadyWhispered then
			result.alreadyWhispered = true
		end
		result.missing = list
		return result
	end

	if mode == "raid" then
		if not member then
			result.skippedAward = true
			return result
		end

		local awarded = AwardPrepared(profile, member, pointName, pointAward)
		if awarded and whisper and ShouldWhisperPrepared(cfg) then
			WhisperPrepared(whisperTarget, cfg, unitInfo.short, pointName, pointAward)
		end
	end

	return result
end

function RC:RunPreRaidCheck()
	local profile, cfg = ValidateCanRun("pre")
	if not profile then return end

	self:RequestTroubleshootingRefresh()

	if SF.SystemMessage then
		SF:SystemMessage("Pre-Raid Check started.")
	else
		SF:PrintInfo("[Pre-Raid Check] Initiated.")
	end

	local summaryMissing = {}
	local summaryPending = {}

	for _, unit in ipairs(CollectUnits()) do
		local info = BuildUnitInfo(unit)
		if info.id then
			local res = RunForUnit(info, profile, cfg, "pre", GetPointName(profile))
			if res then
				if res.missing then
					table.insert(summaryMissing, res)
				elseif res.inspectPending then
					table.insert(summaryPending, res)
				end
			end
		end
	end

	EmitAdminMissingSummary("Pre-Raid Check", summaryMissing)
	EmitAdminPendingSummary("Pre-Raid Check", summaryPending)
	if SF.Debug then
		SF.Debug:Info("RAID_CHECK", "Pre-Raid Check finished: %d missing, %d pending", #summaryMissing, #summaryPending)
	end
	SF:PrintSuccess("[Pre-Raid Check] Complete.")
end

function RC:RunRaidCheck()
	local profile, cfg = ValidateCanRun("raid")
	if not profile then return end

	self:RequestTroubleshootingRefresh()

	if SF.SystemMessage then
		SF:SystemMessage("Raid Check started.")
	else
		SF:PrintInfo("[Raid Check] Initiated.")
	end

	local pointName = GetPointName(profile)
	local pointAward = GetRaidCheckPointAward(cfg)
	local summaryMissing = {}
	local summaryPending = {}
	local summarySkippedAward = {}

	for _, unit in ipairs(CollectUnits()) do
		local info = BuildUnitInfo(unit)
		if info.id then
			local res = RunForUnit(info, profile, cfg, "raid", pointName, pointAward)
			if res then
				if res.missing then
					table.insert(summaryMissing, res)
				elseif res.inspectPending then
					table.insert(summaryPending, res)
				elseif res.skippedAward then
					table.insert(summarySkippedAward, res)
				end
			end
		end
	end

	EmitAdminMissingSummary("Raid Check", summaryMissing)
	for _, entry in ipairs(summarySkippedAward) do
		EmitAdminMessage(("Skipping point award for %s (not in active profile)."):format(entry.name))
	end
	EmitAdminPendingSummary("Raid Check", summaryPending)
	if SF.Debug then
		SF.Debug:Info("RAID_CHECK", "Raid Check finished: %d missing, %d pending, %d skipped awards", #summaryMissing, #summaryPending, #summarySkippedAward)
	end
	SF:PrintSuccess("[Raid Check] Complete.")
end

function RC:Run(mode)
	if mode == "pre" then
		return self:RunPreRaidCheck()
	end
	return self:RunRaidCheck()
end

function RC:GetTroubleshootingColumns()
	local columns = {}

	for index, column in ipairs(TROUBLESHOOTING_COLUMNS) do
		columns[index] = {
			key = column.key,
			label = column.label,
			shortLabel = column.shortLabel,
			inventorySlot = column.inventorySlot,
		}
	end

	return columns
end

function RC:GetTroubleshootingSnapshot()
	self:EnsureInspectSupport()
	local profile = GetProfile()
	local cfg = profile and profile.GetRaidCheckConfig and profile:GetRaidCheckConfig() or nil
	local rows = {}

	for _, info in ipairs(CollectTroubleshootingUnitsAndMembers(profile)) do
		if info.id then
			local inspectState = self:_GetTroubleshootingInspectState(info.unit, info)
			local missingMetaGem, metaGemPending = EvaluateMetaGemRowState(
				inspectState and inspectState.slotsByInventory or nil,
				cfg,
				inspectState and inspectState.isKnown
			)
			rows[#rows + 1] = {
				unit = info.unit,
				id = info.id,
				name = info.short,
				displayName = info.displayName or info.short,
				itemLevel = inspectState and inspectState.averageItemLevel or nil,
				itemLevelText = FormatAverageItemLevel(inspectState and inspectState.averageItemLevel or nil),
				inspectStatus = inspectState and inspectState.status or "ready",
				inspectLabel = inspectState and inspectState.label or nil,
				inspectMessage = inspectState and inspectState.message or nil,
				missingMetaGem = missingMetaGem,
				metaGemPending = metaGemPending,
				slots = BuildTroubleshootingSlots(inspectState, cfg),
			}
		end
	end

	return {
		hasActiveProfile = profile ~= nil,
		version = self:GetTroubleshootingVersion(),
		columns = self:GetTroubleshootingColumns(),
		rows = rows,
	}
end

function RC:GetTroubleshootingSlotsForUnit(unit, cfg)
	if not unit or not UnitExists or not UnitExists(unit) then
		return nil
	end

	self:EnsureInspectSupport()
	if cfg == nil then
		local profile = GetProfile()
		cfg = profile and profile.GetRaidCheckConfig and profile:GetRaidCheckConfig() or nil
	end

	local info = BuildUnitInfo(unit)
	local inspectState = self:_GetTroubleshootingInspectState(unit, info)
	if type(inspectState) ~= "table" then
		return nil
	end

	local missingMetaGem, metaGemPending = EvaluateMetaGemRowState(
		inspectState.slotsByInventory,
		cfg,
		inspectState.isKnown
	)

	return {
		status = inspectState.status,
		label = inspectState.label,
		message = inspectState.message,
		stale = inspectState.stale and true or false,
		missingMetaGem = missingMetaGem,
		metaGemPending = metaGemPending,
		slots = BuildTroubleshootingSlots(inspectState, cfg),
	}
end
