-- modules/UI/Settings/Pages/LootHelper.lua
local _, SF = ...

local RootPage = {
	id = "lootHelper",
	name = "Loot Helper Settings",
	navLabel = "Loot Helper",
	defaultChildId = "lootHelperGeneral",
	order = 20,
}

local GeneralPage = {
	id = "lootHelperGeneral",
	parentId = "lootHelper",
	name = "General Settings",
	navLabel = "General",
	order = 20.5,
}

local ProfilePage = {
	id = "lootHelperProfile",
	parentId = "lootHelper",
	name = "Profile Settings",
	navLabel = "Profile",
	order = 21,
}

local SessionPage = {
	id = "lootHelperSession",
	parentId = "lootHelper",
	name = "Session Settings",
	navLabel = "Session",
	order = 22,
}

local EQUIPMENT_PAGE_WINDOW_WIDTH = 1280
local EQUIPMENT_REFRESH_DEBOUNCE_SECONDS = 0.15
local EQUIPMENT_MANUAL_REFRESH_WINDOW_SECONDS = 4.0
local EQUIPMENT_MANUAL_REFRESH_FOLLOW_UP_COUNT = 8
local EQUIPMENT_MANUAL_REFRESH_FOLLOW_UP_DELAY_SECONDS = 0.25
local EQUIPMENT_MANUAL_REFRESH_INITIAL_DELAY_SECONDS = 0.05

local EquipmentPage = {
	id = "lootHelperEquipment",
	parentId = "lootHelper",
	name = "Raid Check Equipment",
	navLabel = "Equipment",
	order = 22.5,
	layout = {
		windowWidth = EQUIPMENT_PAGE_WINDOW_WIDTH,
		disablePageScroll = true,
	},
}

local AdminPage = {
	id = "lootHelperAdmin",
	parentId = "lootHelper",
	name = "Admin Settings",
	navLabel = "Admin",
	order = 23,
}

local function GetActiveProfileObject(store)
	if store and store.GetActiveLootHelperProfileObject then
		return store:GetActiveLootHelperProfileObject()
	end
	if SF and SF.lootHelperDB then
		return SF.lootHelperDB.activeProfile
	end
	return nil
end

local function GetActiveProfileId(store)
	if store and store.GetActiveLootHelperProfileId then
		local id = store:GetActiveLootHelperProfileId()
		if id ~= nil then return id end
	end

	local id = store:Get("lootHelper.activeProfileId")
	if id ~= nil then return id end

	if SF and SF.lootHelperDB and SF.lootHelperDB.activeProfileId then
		return SF.lootHelperDB.activeProfileId
	end

	return store:Get("lootHelper.activeProfile")
end

local function GetProfileOptions(store)
	if store and store.GetLootHelperProfileOptions then
		return store:GetLootHelperProfileOptions()
	end
	if store and store.GetLootHelperProfileOptionsSorted then
		return store:GetLootHelperProfileOptionsSorted()
	end
	return {}
end

local function HasAnyProfiles(store)
	if store and store.HasActiveLootHelperProfile and store:HasActiveLootHelperProfile() then
		return true
	end
	if store and store.HasLootHelperProfiles and store:HasLootHelperProfiles() then
		return true
	end
	if store and store.GetLootHelperProfiles then
		local profiles = store:GetLootHelperProfiles()
		if type(profiles) == "table" and next(profiles) ~= nil then
			return true
		end
	end
	if SF and SF.lootHelperDB and type(SF.lootHelperDB.profiles) == "table" and next(SF.lootHelperDB.profiles) ~= nil then
		return true
	end
	local opts = GetProfileOptions(store)
	return type(opts) == "table" and #opts > 0
end

local function CanShowAdminTools(ctx)
	local store = (type(ctx) == "table" and ctx.store) or SF.SettingsStore
	if not store then return false end
	return GetActiveProfileObject(store) ~= nil or GetActiveProfileId(store) ~= nil
end

local function IsSessionActive()
	return SF.LootHelperSync and SF.LootHelperSync.IsSessionActive and SF.LootHelperSync:IsSessionActive()
end

local function IsAdmin()
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.IsCurrentUserAdmin then
		local ok, res = pcall(profile.IsCurrentUserAdmin, profile)
		if ok then
			return res and true or false
		end
	end
	return false
end

local function GetRaidCheckConfig()
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.GetRaidCheckConfig then
		return profile:GetRaidCheckConfig()
	end
	return nil
end

local function IsEquipmentAutoRefreshEnabled()
	local store = SF.SettingsStore
	if not store or not store.Get then
		return false
	end
	return store:Get("lootHelper.raidCheckAuditAutoRefresh") and true or false
end

local function IsRaidCheckSlotEnabled(slotKey)
	local cfg = GetRaidCheckConfig()
	if cfg and cfg.slots then
		return cfg.slots[slotKey] and true or false
	end
	return false
end

local function IsRaidCheckGemSocketsEnabled()
	local cfg = GetRaidCheckConfig()
	if cfg ~= nil then
		return cfg.checkGemsInSockets ~= false
	end
	return true
end

local function IsRaidCheckMetaGemRequired()
	local cfg = GetRaidCheckConfig()
	if cfg ~= nil then
		return cfg.requireMetaGem and true or false
	end
	return false
end

local function GetRaidCheckPointsAwardPerCheck()
	local cfg = GetRaidCheckConfig()
	if cfg ~= nil then
		local amount = tonumber(cfg.pointsAwardPerRaidCheck)
		if amount ~= nil then
			return amount
		end
	end
	return 0.5
end

local function SetRaidCheckSlot(slotKey, value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckSlotEnabled then
		profile:SetRaidCheckSlotEnabled(slotKey, value and true or false)
	end
end

local function SetRaidCheckPointsAwardPerCheck(value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckPointsAwardPerCheck then
		profile:SetRaidCheckPointsAwardPerCheck(tonumber(value) or 0.5)
	end
end

local function SetRaidCheckGemSockets(value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckGemSocketsEnabled then
		profile:SetRaidCheckGemSocketsEnabled(value and true or false)
	end
end

local function SetRaidCheckMetaGemRequired(value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckMetaGemRequired then
		profile:SetRaidCheckMetaGemRequired(value and true or false)
	end
end

local function SetRaidCheckWhispers(mode, value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckWhispers then
		profile:SetRaidCheckWhispers(mode, value and true or false)
	end
end

local function SetRaidCheckPreparedWhispers(value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckWhisperPrepared then
		profile:SetRaidCheckWhisperPrepared(value and true or false)
	end
end

local function GetRaidCheckWhisperTemplate(templateKey)
	local cfg = GetRaidCheckConfig()
	if not cfg then
		return ""
	end

	if templateKey == "pre_raid_missing" then
		return cfg.whisperTemplatePreRaidMissing or ""
	end
	if templateKey == "raid_missing" then
		return cfg.whisperTemplateRaidMissing or ""
	end
	if templateKey == "raid_prepared" then
		return cfg.whisperTemplateRaidPrepared or ""
	end

	return ""
end

local function SetRaidCheckWhisperTemplate(templateKey, template)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckWhisperTemplate then
		profile:SetRaidCheckWhisperTemplate(templateKey, template)
	end
end

local function ResetRaidCheckWhisperTemplate(templateKey)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.ResetRaidCheckWhisperTemplate then
		profile:ResetRaidCheckWhisperTemplate(templateKey)
	end
end

local function ShouldShowWhisperTemplates()
	local cfg = GetRaidCheckConfig()
	if not cfg then
		return false
	end
	return (cfg.enableWhispersPreRaid and true or false) or (cfg.enableWhispersRaid and true or false)
end

local function ToWoWHexColor(color)
	if type(color) == "string" then
		return color
	end
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

local function GetMemberClassColor(member)
	if type(member) == "table" then
		if type(member.GetClassColorCode) == "function" then
			return member:GetClassColorCode()
		end

		local className
		if type(member.getClass) == "function" then
			className = member:getClass()
		else
			className = member.class
		end

		if className and SF.WOW_CLASSES and SF.WOW_CLASSES[className] and SF.WOW_CLASSES[className].colorCode then
			return ToWoWHexColor(SF.WOW_CLASSES[className].colorCode)
		end
	end

	return "|cffffffff"
end

local AUDIT_MIN_NAME_COLUMN_WIDTH = 120
local AUDIT_PREFERRED_NAME_COLUMN_WIDTH = 150
local AUDIT_NAME_PADDING = 8
local AUDIT_ILVL_COLUMN_WIDTH = 52
local AUDIT_ICON_SIZE = 40
local AUDIT_COLUMN_GAP = 6
local AUDIT_ROW_HEIGHT = 46
local AUDIT_ROW_SPACING = 2
local AUDIT_HEADER_HEIGHT = 24
local AUDIT_MIN_TABLE_HEIGHT = 260
local AUDIT_HORIZONTAL_SCROLL_HEIGHT = 20
-- Fade fully out so the pulse is unmistakable without obscuring the icon at peak.
local AUDIT_MISSING_OVERLAY_MIN_ALPHA = 0
local AUDIT_MISSING_OVERLAY_MAX_ALPHA = 0.72
local AUDIT_PULSE_DURATION_SECONDS = 1.5
local AUDIT_SLOT_PLACEHOLDERS = {
	head = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Head",
	neck = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Neck",
	shoulders = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Shoulder",
	back = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest",
	chest = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest",
	wrist = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Wrists",
	hands = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Hands",
	belt = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Waist",
	legs = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Legs",
	boots = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Feet",
	rings = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger",
	trinkets = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket",
	mainHand = "Interface\\PaperDoll\\UI-PaperDoll-Slot-MainHand",
	offHand = "Interface\\PaperDoll\\UI-PaperDoll-Slot-SecondaryHand",
}

local function GetAuditSlotPlaceholderTexture(slotKey)
	return AUDIT_SLOT_PLACEHOLDERS[slotKey] or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function EnsureAuditPulse(texture)
	if texture.__sfPulse then
		return texture.__sfPulse
	end

	local pulse = texture:CreateAnimationGroup()
	pulse:SetLooping("REPEAT")

	local fadeIn = pulse:CreateAnimation("Alpha")
	fadeIn:SetOrder(1)
	fadeIn:SetFromAlpha(AUDIT_MISSING_OVERLAY_MIN_ALPHA)
	fadeIn:SetToAlpha(AUDIT_MISSING_OVERLAY_MAX_ALPHA)
	fadeIn:SetDuration(AUDIT_PULSE_DURATION_SECONDS)

	local fadeOut = pulse:CreateAnimation("Alpha")
	fadeOut:SetOrder(2)
	fadeOut:SetFromAlpha(AUDIT_MISSING_OVERLAY_MAX_ALPHA)
	fadeOut:SetToAlpha(AUDIT_MISSING_OVERLAY_MIN_ALPHA)
	fadeOut:SetDuration(AUDIT_PULSE_DURATION_SECONDS)

	texture.__sfPulse = pulse
	return pulse
end

local function SetOverlayToVisibleIconArea(texture, parent)
	texture:ClearAllPoints()
	texture:SetAllPoints(parent)
end

local function SetAuditMissingOverlay(texture, enabled)
	local pulse = EnsureAuditPulse(texture)
	if enabled then
		texture:SetAlpha(AUDIT_MISSING_OVERLAY_MIN_ALPHA)
		texture:Show()
		if not pulse:IsPlaying() then
			pulse:Play()
		end
		return
	end

	if pulse:IsPlaying() then
		pulse:Stop()
	end
	texture:Hide()
end

local function GetAuditDebugItemToken(link)
	if type(link) ~= "string" or link == "" then
		return "nil"
	end

	local itemId = string.match(link, "item:(%d+)")
	if itemId and itemId ~= "" then
		return string.format("item:%s", itemId)
	end

	return "link"
end

local function BuildAuditSlotSignature(slotData)
	if type(slotData) ~= "table" then
		return "nil"
	end

	-- Keep the signature compact so the Equipment page can cheaply detect
	-- whether a specific rendered cell actually changed.
	return table.concat({
		tostring(slotData.key or slotData.label or "?"),
		GetAuditDebugItemToken(slotData.link),
		tostring(slotData.texture or "nil"),
		slotData.known and "k1" or "k0",
		slotData.configEnabled and "c1" or "c0",
		slotData.expectedEnchant and "e1" or "e0",
		slotData.hasEnchant and "h1" or "h0",
		slotData.missingEnchant and "me1" or "me0",
		slotData.missingGems and "mg1" or "mg0",
		slotData.missingItem and "mi1" or "mi0",
		slotData.skippedEnchant and "se1" or "se0",
		slotData.stale and "s1" or "s0",
		tostring(slotData.inspectStatus or "ready"),
	}, "|")
end

local function BuildAuditRowSignature(rowData)
	if type(rowData) ~= "table" then
		return "nil"
	end

	-- The row signature lets the page skip rebuilding unchanged rows while
	-- still reacting immediately to slot, ilvl, or inspect-status changes.
	local parts = {
		tostring(rowData.id or rowData.name or "?"),
		tostring(rowData.displayName or rowData.name or "?"),
		tostring(rowData.itemLevelText or "--"),
		tostring(rowData.inspectStatus or "ready"),
		tostring(rowData.inspectLabel or ""),
		tostring(rowData.inspectMessage or ""),
	}

	for _, slotData in ipairs(rowData.slots or {}) do
		parts[#parts + 1] = BuildAuditSlotSignature(slotData)
	end

	return table.concat(parts, "||")
end

local function ShowAuditHeaderTooltip(self)
	if not self or not self._auditTooltipText or self._auditTooltipText == "" then
		return
	end

	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(self._auditTooltipTitle or "", 1, 1, 1)
	GameTooltip:AddLine(self._auditTooltipText, nil, nil, nil, true)
	GameTooltip:Show()
end

local function HideAuditTooltip()
	GameTooltip:Hide()
end

local function GetAuditInspectStatusColor(status)
	if status == "out_of_range" then
		return "|cffff9f40"
	end
	if status == "stale" or status == "refreshing" or status == "retrying" or status == "saved" then
		return "|cffffff00"
	end
	if status == "loading" then
		return "|cff9cd6ff"
	end
	return "|cffb8b8b8"
end

local function FormatAuditRowName(rowData)
	local name = (rowData and (rowData.displayName or rowData.name)) or "?"
	local status = rowData and rowData.inspectStatus
	if status == "saved" or status == "paused" then
		return name
	end
	local label = rowData and rowData.inspectLabel or nil
	if not label or label == "" then
		return name
	end
	return string.format("%s %s(%s)|r", name, GetAuditInspectStatusColor(rowData.inspectStatus), label)
end

local function ShowAuditCellTooltip(self)
	local slotData = self and self._slotData
	local rowData = self and self._rowData
	if not slotData then
		return
	end

	local hasItem = (slotData.hasItem or slotData.link or slotData.itemId or slotData.texture) and true or false

	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

	if slotData.link then
		GameTooltip:SetHyperlink(slotData.link)
	else
		GameTooltip:SetText(slotData.label or "Item Slot", 1, 1, 1)
	end

	if rowData and rowData.displayName then
		GameTooltip:AddLine(rowData.displayName, 0.75, 0.82, 1, true)
	end

	if rowData and rowData.inspectMessage then
		GameTooltip:AddLine(rowData.inspectMessage, 0.9, 0.82, 0.35, true)
	end

	if slotData.known == false then
		GameTooltip:AddLine("Raid Check will evaluate this slot after inspect data is available.", 0.75, 0.75, 0.75, true)
		GameTooltip:Show()
		return
	end

	if not hasItem then
		GameTooltip:AddLine("No item equipped.", 0.8, 0.8, 0.8, true)
	elseif not slotData.link then
		GameTooltip:AddLine("Item data is still loading for this slot.", 0.75, 0.75, 0.75, true)
	end

	if slotData.configEnabled then
		if slotData.missingEnchant then
			GameTooltip:AddLine("Missing required enchant.", 1, 0.25, 0.25, true)
		elseif slotData.expectedEnchant then
			GameTooltip:AddLine("Required enchant detected.", 0.3, 1, 0.3, true)
		elseif slotData.skippedEnchant then
			GameTooltip:AddLine("Enchant check skipped for this off-hand item type.", 0.75, 0.75, 0.75, true)
		else
			GameTooltip:AddLine("Raid Check is tracking this slot.", 0.75, 0.82, 1, true)
		end
	else
		GameTooltip:AddLine("Enchant checks are disabled for this slot in the active profile.", 0.75, 0.75, 0.75, true)
	end

	if slotData.missingGems then
		GameTooltip:AddLine("Missing gem sockets detected.", 1, 0.65, 0.2, true)
	end

	if slotData.missingItem then
		GameTooltip:AddLine("Raid Check will flag this slot as missing gear.", 1, 0.35, 0.35, true)
	end

	if slotData.stale then
		GameTooltip:AddLine("This row is showing cached inspect data while a fresh snapshot loads.", 0.95, 0.9, 0.5, true)
	end

	GameTooltip:Show()
end

local function CreateAuditCell(parent)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(AUDIT_ICON_SIZE, AUDIT_ICON_SIZE)
	button:EnableMouse(true)

	local bg = button:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(button)
	bg:SetColorTexture(0, 0, 0, 0.35)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints(button)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	button.Icon = icon

	local overlay = button:CreateTexture(nil, "OVERLAY")
	SetOverlayToVisibleIconArea(overlay, icon)
	overlay:SetColorTexture(1, 0, 0, 1)
	overlay:Hide()
	button.MissingOverlay = overlay

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints(button)
	highlight:SetColorTexture(1, 1, 1, 0.10)

	button:SetScript("OnEnter", ShowAuditCellTooltip)
	button:SetScript("OnLeave", HideAuditTooltip)

	return button
end

local function SetScrollBarShown(scroll, shown)
	local scrollBar = scroll and scroll.ScrollBar
	if not scrollBar then
		return 0
	end

	scrollBar:SetShown(shown)
	if shown then
		if scrollBar.Enable then
			scrollBar:Enable()
		end
		return scrollBar:GetWidth() or 20
	end

	scroll:SetVerticalScroll(0)
	if scrollBar.SetValue then
		scrollBar:SetValue(0)
	end
	if scrollBar.Disable then
		scrollBar:Disable()
	end
	return 0
end

local function SetAuditHorizontalScrollShown(slider, shown)
	if not slider then
		return 0
	end

	slider:SetShown(shown)
	if shown then
		return AUDIT_HORIZONTAL_SCROLL_HEIGHT
	end

	if slider.SetValue then
		slider:SetValue(0)
	end
	return 0
end

local function GetAuditNameColumnWidth(availableWidth, slotCount)
	local totalIconWidth = slotCount * AUDIT_ICON_SIZE
	local totalGap = (slotCount + 1) * AUDIT_COLUMN_GAP
	local availableNameWidth = availableWidth - totalIconWidth - totalGap - AUDIT_ILVL_COLUMN_WIDTH
	return math.max(
		AUDIT_MIN_NAME_COLUMN_WIDTH,
		math.min(AUDIT_PREFERRED_NAME_COLUMN_WIDTH, availableNameWidth)
	)
end

local function BuildEquipmentPage(panel)
	local pageBuilder = SF.SettingsUI:CreatePage(panel)
	panel.__sfPageBuilder = pageBuilder
	local manualRefreshUntil = 0
	local RefreshAuditTable
	local ScheduleRefreshAuditTable

	local function IsEquipmentPageActive()
		if not panel then
			return false
		end
		if panel.IsVisible then
			return panel:IsVisible() and true or false
		end
		return panel.IsShown and panel:IsShown() and true or false
	end

	local function UpdateBackgroundInspect(reason)
		if not (SF.RaidCheck and SF.RaidCheck.SetBackgroundInspectEnabled) then
			return
		end

		local now = GetTime and GetTime() or 0
		local manualWindowActive = now <= manualRefreshUntil
		local enabled = IsEquipmentPageActive() and (IsEquipmentAutoRefreshEnabled() or manualWindowActive) and true or false
		SF.RaidCheck:SetBackgroundInspectEnabled(enabled, reason or "equipment page")
	end

	local function ReflowEquipmentPage()
		if IsEquipmentPageActive() and pageBuilder and pageBuilder.Reflow then
			pageBuilder:Reflow()
		end
	end

	local function RequestEquipmentPageRedraw(reason)
		if not IsEquipmentPageActive() then
			return
		end
		if SF.Debug then
			SF.Debug:Verbose("UI", "Raid Check Equipment redraw requested (%s)", tostring(reason or "unknown"))
		end
		if RefreshAuditTable then
			RefreshAuditTable()
		elseif ScheduleRefreshAuditTable then
			ScheduleRefreshAuditTable()
		elseif pageBuilder and pageBuilder.Refresh then
			pageBuilder:Refresh()
		end
	end

	local function ScheduleManualRefreshFollowUps(reason)
		if not (C_Timer and C_Timer.After) then
			RequestEquipmentPageRedraw(reason)
			return
		end

		for attempt = 1, EQUIPMENT_MANUAL_REFRESH_FOLLOW_UP_COUNT do
			C_Timer.After(EQUIPMENT_MANUAL_REFRESH_FOLLOW_UP_DELAY_SECONDS * attempt, function()
				local now = GetTime and GetTime() or 0
				if now > manualRefreshUntil then
					if SF.Debug then
						SF.Debug:Verbose("UI", "Skipping manual refresh follow-up %d; refresh window expired", attempt)
					end
					return
				end
				if SF.Debug then
					SF.Debug:Verbose("UI", "Running manual refresh follow-up %d", attempt)
				end
				RequestEquipmentPageRedraw(string.format("%s #%d", tostring(reason or "manual refresh"), attempt))
			end)
		end
	end

	local controls = SF.SettingsUI.Controls
	local introSection = pageBuilder:AddSection({
		title = "Raid Check Equipment",
		tooltip = "Shows the equipment snapshot Raid Check uses for the audit.",
	})

	controls:AddCheckbox(introSection, {
		label = "Enable Auto Refresh",
		tooltip = "Automatically refresh this audit table as inspect results update. Leave this off to refresh only when you ask for it.",
		get = IsEquipmentAutoRefreshEnabled,
		set = function(value)
			if SF.SettingsStore and SF.SettingsStore.Set then
				SF.SettingsStore:Set("lootHelper.raidCheckAuditAutoRefresh", value and true or false)
			end
			if panel.__sfPageBuilder then
				panel.__sfPageBuilder:Refresh()
			end
			UpdateBackgroundInspect("auto refresh toggle")
		end,
	})
	controls:AddButton(introSection, {
		label = "Refresh Snapshot",
		buttonText = "Refresh",
		width = 120,
		onClick = function()
			manualRefreshUntil = (GetTime and GetTime() or 0) + EQUIPMENT_MANUAL_REFRESH_WINDOW_SECONDS
			if SF.Debug then
				SF.Debug:Info("UI", "Refresh Snapshot clicked; manual refresh window open for %.1f seconds", EQUIPMENT_MANUAL_REFRESH_WINDOW_SECONDS)
			end
			UpdateBackgroundInspect("manual refresh window started")
			RequestEquipmentPageRedraw("manual refresh button immediate")
			if SF.RaidCheck and SF.RaidCheck.RequestTroubleshootingRefresh then
				SF.RaidCheck:RequestTroubleshootingRefresh()
			end
			if C_Timer and C_Timer.After then
				C_Timer.After(EQUIPMENT_MANUAL_REFRESH_INITIAL_DELAY_SECONDS, function()
					if SF.Debug then
						SF.Debug:Verbose("UI", "Running delayed manual refresh redraw after %.2f seconds", EQUIPMENT_MANUAL_REFRESH_INITIAL_DELAY_SECONDS)
					end
					RequestEquipmentPageRedraw("manual refresh button")
				end)
			else
				RequestEquipmentPageRedraw("manual refresh button")
			end
			ScheduleManualRefreshFollowUps("manual refresh follow-up")

			if C_Timer and C_Timer.After then
				C_Timer.After(EQUIPMENT_MANUAL_REFRESH_WINDOW_SECONDS, function()
					UpdateBackgroundInspect("manual refresh window ended")
				end)
			end
		end,
		visible = function()
			return not IsEquipmentAutoRefreshEnabled()
		end,
	})

	local tableSection = pageBuilder:AddSection({
		title = "Current Group Equipment",
		tooltip = "Shows the last seen gear in each slot for every visible raid member. Slots pulse red when gear, required enchants, or gems are missing.",
	})
	tableSection.__sfFillHeight = true

	local columns = (SF.RaidCheck and SF.RaidCheck.GetTroubleshootingColumns and SF.RaidCheck:GetTroubleshootingColumns()) or {}

	tableSection:AddRow(AUDIT_MIN_TABLE_HEIGHT, function(row)
		local container = CreateFrame("Frame", nil, row)
		container:SetAllPoints(row)

		local headerViewport = CreateFrame("Frame", nil, container)
		headerViewport:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
		headerViewport:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
		headerViewport:SetHeight(AUDIT_HEADER_HEIGHT)
		headerViewport:SetClipsChildren(true)

		local headerBg = headerViewport:CreateTexture(nil, "BACKGROUND")
		headerBg:SetAllPoints(headerViewport)
		headerBg:SetColorTexture(1, 1, 1, 0.08)

		local header = CreateFrame("Frame", nil, headerViewport)
		header:SetPoint("TOPLEFT", headerViewport, "TOPLEFT", 0, 0)
		header:SetHeight(AUDIT_HEADER_HEIGHT)

		local scroll = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", headerViewport, "BOTTOMLEFT", 0, -4)
		scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)

		local content = CreateFrame("Frame", nil, scroll)
		content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		content:SetHeight(1)
		scroll:SetScrollChild(content)

		local horizontalScroll = CreateFrame("Slider", nil, container, "OptionsSliderTemplate")
		horizontalScroll:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 16, 0)
		horizontalScroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -16, 0)
		horizontalScroll:SetHeight(AUDIT_HORIZONTAL_SCROLL_HEIGHT)
		horizontalScroll:SetObeyStepOnDrag(true)
		horizontalScroll:SetValueStep(1)
		horizontalScroll.Low:Hide()
		horizontalScroll.High:Hide()
		horizontalScroll.Text:Hide()
		horizontalScroll:Hide()

		local emptyText = content:CreateFontString(nil, "ARTWORK", "GameFontDisable")
		emptyText:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -8)
		emptyText:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, -8)
		emptyText:SetJustifyH("LEFT")
		emptyText:SetText("No visible group members found.")
		emptyText:Hide()

		local nameHeader = CreateFrame("Frame", nil, header)
		local nameHeaderText = nameHeader:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		nameHeaderText:SetPoint("LEFT", nameHeader, "LEFT", 4, 0)
		nameHeaderText:SetPoint("RIGHT", nameHeader, "RIGHT", -4, 0)
		nameHeaderText:SetJustifyH("LEFT")
		nameHeaderText:SetText("Member")

		local itemLevelHeader = CreateFrame("Frame", nil, header)
		local itemLevelHeaderText = itemLevelHeader:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		itemLevelHeaderText:SetPoint("CENTER", itemLevelHeader, "CENTER", 0, 0)
		itemLevelHeaderText:SetJustifyH("CENTER")
		itemLevelHeaderText:SetText("iLvl")

		local headerCells = {}
		for index, column in ipairs(columns) do
			local cell = CreateFrame("Frame", nil, header)
			local text = cell:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			text:SetPoint("CENTER", cell, "CENTER", 0, 0)
			text:SetJustifyH("CENTER")
			text:SetText(column.shortLabel or column.label or "?")
			cell.Text = text
			cell._auditTooltipTitle = column.label or "Slot"
			cell._auditTooltipText = string.format("%s slot", column.label or "Item")
			cell:EnableMouse(true)
			cell:SetScript("OnEnter", ShowAuditHeaderTooltip)
			cell:SetScript("OnLeave", HideAuditTooltip)
			headerCells[index] = cell
		end

		local rows = {}

		local function EnsureRow(index)
			if rows[index] then
				return rows[index]
			end

			local dataRow = CreateFrame("Frame", nil, content)
			dataRow:SetHeight(AUDIT_ROW_HEIGHT)

			local hoverHighlight = dataRow:CreateTexture(nil, "BACKGROUND")
			hoverHighlight:SetAllPoints(dataRow)
			hoverHighlight:SetColorTexture(1, 1, 1, 0.06)
			hoverHighlight:Hide()
			dataRow.Hover = hoverHighlight

			dataRow:SetScript("OnEnter", function(self)
				self.Hover:Show()
			end)
			dataRow:SetScript("OnLeave", function(self)
				self.Hover:Hide()
			end)

			local name = dataRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
			name:SetPoint("LEFT", dataRow, "LEFT", 4, 0)
			name:SetJustifyH("LEFT")
			if name.SetWordWrap then
				name:SetWordWrap(false)
			end
			if name.SetMaxLines then
				name:SetMaxLines(1)
			end
			dataRow.Name = name

			local itemLevel = dataRow:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			itemLevel:SetJustifyH("CENTER")
			dataRow.ItemLevel = itemLevel

			dataRow.Cells = {}
			for columnIndex = 1, #columns do
				dataRow.Cells[columnIndex] = CreateAuditCell(dataRow)
			end

			rows[index] = dataRow
			return dataRow
		end

		local function LayoutRowWidgets(parent, nameWidget, itemLevelWidget, slotWidgets, availableWidth)
			local slotCount = #slotWidgets
			local totalIconWidth = slotCount * AUDIT_ICON_SIZE
			local totalGap = (slotCount + 1) * AUDIT_COLUMN_GAP
			local nameWidth = GetAuditNameColumnWidth(availableWidth, slotCount)
			local usedWidth = nameWidth + AUDIT_ILVL_COLUMN_WIDTH + totalIconWidth + totalGap
			local xOffset = 0

			nameWidget:ClearAllPoints()
			if nameWidget.GetObjectType and nameWidget:GetObjectType() == "Frame" then
				nameWidget:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
				nameWidget:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
				nameWidget:SetWidth(nameWidth)
			else
				nameWidget:SetPoint("LEFT", parent, "LEFT", 4, 0)
				nameWidget:SetWidth(math.max(1, nameWidth - AUDIT_NAME_PADDING))
			end

			itemLevelWidget:ClearAllPoints()
			if itemLevelWidget.GetObjectType and itemLevelWidget:GetObjectType() == "Frame" then
				itemLevelWidget:SetPoint("TOPLEFT", parent, "TOPLEFT", nameWidth + AUDIT_COLUMN_GAP, 0)
				itemLevelWidget:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", nameWidth + AUDIT_COLUMN_GAP, 0)
				itemLevelWidget:SetWidth(AUDIT_ILVL_COLUMN_WIDTH)
			else
				itemLevelWidget:SetPoint("CENTER", parent, "LEFT", nameWidth + AUDIT_COLUMN_GAP + (AUDIT_ILVL_COLUMN_WIDTH / 2), 0)
				itemLevelWidget:SetWidth(AUDIT_ILVL_COLUMN_WIDTH)
			end

			xOffset = nameWidth + AUDIT_COLUMN_GAP + AUDIT_ILVL_COLUMN_WIDTH + AUDIT_COLUMN_GAP
			for _, widget in ipairs(slotWidgets) do
				widget:ClearAllPoints()
				widget:SetPoint("LEFT", parent, "LEFT", xOffset, 0)
				xOffset = xOffset + AUDIT_ICON_SIZE + AUDIT_COLUMN_GAP
			end

			return usedWidth, nameWidth
		end

		local isRefreshingAuditTable = false
		local pendingAuditTableRefresh = false
		local refreshAuditTableLaterPending = false
		local lastRenderedSnapshotVersion = -1
		local lastLayoutState = nil

		local function ApplyHorizontalScrollOffset(value)
			scroll:SetHorizontalScroll(value)
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", headerViewport, "TOPLEFT", -value, 0)
			header:SetHeight(AUDIT_HEADER_HEIGHT)
		end

		local function UpdateAuditRowData(dataRow, rowData)
			dataRow.Name:SetText(FormatAuditRowName(rowData))
			dataRow.ItemLevel:SetText(rowData.itemLevelText or "--")
			if rowData.itemLevelText then
				dataRow.ItemLevel:SetTextColor(1, 0.82, 0.2, 1)
			else
				dataRow.ItemLevel:SetTextColor(0.65, 0.65, 0.65, 1)
		end

		local knownCount = 0
		local issueCount = 0
		for columnIndex, column in ipairs(columns) do
			local slotData = rowData.slots and rowData.slots[columnIndex] or nil
			local cell = dataRow.Cells[columnIndex]
			local texture = slotData and slotData.texture or GetAuditSlotPlaceholderTexture(column.key)
				local hasItem = (slotData and (slotData.hasItem or slotData.link or slotData.itemId or slotData.texture)) and true or false
			local shouldShowOverlay = slotData and slotData.known and (slotData.missingEnchant or slotData.missingGems or slotData.missingItem)

			cell._rowData = rowData
			cell._slotData = slotData or {
				label = column.label or "Slot",
				configEnabled = false,
			}
			cell.Icon:SetTexture(texture)
			cell.Icon:SetDesaturated(not hasItem)
			if hasItem then
				cell.Icon:SetVertexColor(1, 1, 1, 1)
			else
				cell.Icon:SetVertexColor(0.55, 0.55, 0.55, 0.85)
			end

				SetAuditMissingOverlay(cell.MissingOverlay, shouldShowOverlay)
				if slotData and slotData.known then
					knownCount = knownCount + 1
				end
				if shouldShowOverlay then
					issueCount = issueCount + 1
				end
				cell:Show()
			end

			return knownCount, issueCount
		end

		local function ApplyAuditTableLayout(rowCount, contentHeight, forceLayout)
			local containerWidth = math.floor((container:GetWidth() or 0) + 0.5)
			local containerHeight = math.floor((container:GetHeight() or 0) + 0.5)
			local nextLayoutState = string.format("%d:%d:%d:%d:%d", rowCount, #columns, containerWidth, containerHeight, contentHeight)
			if not forceLayout and lastLayoutState == nextLayoutState then
				return false
			end

			local scrollBarWidth = 0
			local horizontalScrollHeight = 0
			local availableWidth = 1
			local usedWidth, nameWidth = LayoutRowWidgets(header, nameHeader, itemLevelHeader, headerCells, availableWidth)
			for _ = 1, 2 do
				scroll:ClearAllPoints()
				scroll:SetPoint("TOPLEFT", headerViewport, "BOTTOMLEFT", 0, -4)
				scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, horizontalScrollHeight)

				local visibleHeight = math.max(1, (scroll:GetHeight() or 0) - 2)
				local showVerticalScroll = contentHeight > visibleHeight
				scrollBarWidth = SetScrollBarShown(scroll, showVerticalScroll)

				headerViewport:ClearAllPoints()
				headerViewport:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
				headerViewport:SetPoint("TOPRIGHT", container, "TOPRIGHT", -(showVerticalScroll and (scrollBarWidth + 4) or 0), 0)
				headerViewport:SetHeight(AUDIT_HEADER_HEIGHT)

				availableWidth = math.max(1, headerViewport:GetWidth() or ((scroll:GetWidth() or 0) - scrollBarWidth - 4))
				usedWidth, nameWidth = LayoutRowWidgets(header, nameHeader, itemLevelHeader, headerCells, availableWidth)
				horizontalScrollHeight = SetAuditHorizontalScrollShown(horizontalScroll, usedWidth > availableWidth)
			end

			scroll:ClearAllPoints()
			scroll:SetPoint("TOPLEFT", headerViewport, "BOTTOMLEFT", 0, -4)
			scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, horizontalScrollHeight)
			content:SetWidth(math.max(usedWidth, availableWidth))
			header:SetWidth(math.max(usedWidth, availableWidth))

			local maxHorizontalOffset = math.max(0, usedWidth - availableWidth)
			horizontalScroll:SetMinMaxValues(0, maxHorizontalOffset)
			local currentHorizontalOffset = horizontalScroll:GetValue() or 0
			if currentHorizontalOffset > maxHorizontalOffset then
				currentHorizontalOffset = maxHorizontalOffset
				horizontalScroll:SetValue(currentHorizontalOffset)
			end

			ApplyHorizontalScrollOffset(currentHorizontalOffset)

			nameHeaderText:SetWidth(math.max(1, nameWidth - AUDIT_NAME_PADDING))
			itemLevelHeader:SetWidth(AUDIT_ILVL_COLUMN_WIDTH)
			for index = 1, rowCount do
				local dataRow = rows[index]
				if dataRow and dataRow:IsShown() then
					local yOffset = (index - 1) * (AUDIT_ROW_HEIGHT + AUDIT_ROW_SPACING)
					dataRow:ClearAllPoints()
					dataRow:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOffset)
					dataRow:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOffset)
					LayoutRowWidgets(dataRow, dataRow.Name, dataRow.ItemLevel, dataRow.Cells, availableWidth)
				end
			end

			lastLayoutState = nextLayoutState
			return true
		end

		ScheduleRefreshAuditTable = function(forceLayout)
			if refreshAuditTableLaterPending then
				return
			end
			refreshAuditTableLaterPending = true
			if C_Timer and C_Timer.After then
				C_Timer.After(EQUIPMENT_REFRESH_DEBOUNCE_SECONDS, function()
					refreshAuditTableLaterPending = false
					if not IsEquipmentPageActive() then
						return
					end
					RefreshAuditTable(forceLayout and { forceLayout = true } or nil)
				end)
				return
			end
			refreshAuditTableLaterPending = false
			if not IsEquipmentPageActive() then
				return
			end
			RefreshAuditTable(forceLayout and { forceLayout = true } or nil)
		end

		RefreshAuditTable = function(options)
			if not IsEquipmentPageActive() then
				return
			end
			if isRefreshingAuditTable then
				pendingAuditTableRefresh = true
				return
			end

			isRefreshingAuditTable = true
			local ok, err = pcall(function()
				local snapshot = (SF.RaidCheck and SF.RaidCheck.GetTroubleshootingSnapshot and SF.RaidCheck:GetTroubleshootingSnapshot()) or { rows = {}, columns = columns, hasActiveProfile = false, version = 0 }
				local dataRows = snapshot.rows or {}
				local snapshotVersion = snapshot.version or 0
				local snapshotChanged = snapshotVersion ~= lastRenderedSnapshotVersion
				local forceLayout = type(options) == "table" and options.forceLayout and true or false
				if SF.Debug then
					SF.Debug:Verbose(
						"UI",
						"Refreshing Raid Check Equipment table with %d row(s), version=%s changed=%s forceLayout=%s",
						#dataRows,
						tostring(snapshotVersion),
						tostring(snapshotChanged),
						tostring(forceLayout)
					)
				end

				if snapshot.hasActiveProfile then
					tableSection:ClearMessage()
				else
					tableSection:SetMessage("Select an active Loot Helper profile to apply raid check expectations.", "warn")
				end

				local knownSlotCount = 0
				local issueSlotCount = 0
				for index, rowData in ipairs(dataRows) do
					local dataRow = EnsureRow(index)
					local rowSignature = BuildAuditRowSignature(rowData)
					if snapshotChanged or dataRow.__sfSignature ~= rowSignature then
						local rowKnownCount, rowIssueCount = UpdateAuditRowData(dataRow, rowData)
						knownSlotCount = knownSlotCount + rowKnownCount
						issueSlotCount = issueSlotCount + rowIssueCount
						dataRow.__sfSignature = rowSignature
					end
					dataRow:Show()
				end

				for index = #dataRows + 1, #rows do
					rows[index].__sfSignature = nil
					rows[index]:Hide()
				end

				local contentHeight = (#dataRows > 0) and (((#dataRows - 1) * (AUDIT_ROW_HEIGHT + AUDIT_ROW_SPACING)) + AUDIT_ROW_HEIGHT) or 1
				content:SetHeight(math.max(1, contentHeight))
				emptyText:SetShown(#dataRows == 0)

				local layoutChanged = ApplyAuditTableLayout(#dataRows, contentHeight, forceLayout)
				if snapshotChanged then
					lastRenderedSnapshotVersion = snapshotVersion
				end

				if SF.Debug and snapshotChanged then
					SF.Debug:Verbose(
						"UI",
						"Raid Check Equipment summary: rows=%d knownSlots=%d issueSlots=%d layoutChanged=%s",
						#dataRows,
						knownSlotCount,
						issueSlotCount,
						tostring(layoutChanged)
					)
				elseif SF.Debug and not snapshotChanged and not layoutChanged then
					SF.Debug:Verbose("UI", "Skipping redundant Raid Check Equipment redraw; snapshot version unchanged")
				end

				if layoutChanged then
					ReflowEquipmentPage()
				end
			end)

			isRefreshingAuditTable = false
			if pendingAuditTableRefresh then
				pendingAuditTableRefresh = false
				RefreshAuditTable()
			end
			if not ok then
				if SF.Debug then
					SF.Debug:Error("UI", "Raid Check equipment refresh failed: %s", tostring(err or "unknown error"))
				end
			end
		end

		if not horizontalScroll.__sfEquipmentOnValueChangedHooked then
			horizontalScroll.__sfEquipmentOnValueChangedHooked = true
			horizontalScroll:SetScript("OnValueChanged", function(_, value)
				ApplyHorizontalScrollOffset(value)
			end)
		end

		if SF.RaidCheck and SF.RaidCheck.RegisterTroubleshootingListener then
			if panel.__sfEquipmentListenerKey and SF.RaidCheck.UnregisterTroubleshootingListener then
				SF.RaidCheck:UnregisterTroubleshootingListener(panel.__sfEquipmentListenerKey)
			end
			panel.__sfEquipmentListenerKey = panel
			SF.RaidCheck:RegisterTroubleshootingListener(panel.__sfEquipmentListenerKey, function()
				local now = GetTime and GetTime() or 0
				local autoRefreshEnabled = IsEquipmentAutoRefreshEnabled()
				local manualWindowActive = now <= manualRefreshUntil
				if IsEquipmentPageActive() and (autoRefreshEnabled or manualWindowActive) then
					if SF.Debug then
						SF.Debug:Verbose("UI", "Raid Check Equipment listener scheduling refresh (auto=%s manualWindow=%s)", tostring(autoRefreshEnabled), tostring(manualWindowActive))
					end
					ScheduleRefreshAuditTable()
				end
			end)
		end

		pageBuilder:RegisterRefresh(RefreshAuditTable)
		RefreshAuditTable()
		if not scroll.__sfEquipmentSizeRefreshHooked then
			scroll.__sfEquipmentSizeRefreshHooked = true
			scroll:HookScript("OnSizeChanged", function()
				ScheduleRefreshAuditTable(true)
			end)
		end
	end, { fillHeight = true })

	pageBuilder:Finalize()

	if panel and panel.HookScript and not panel.__sfRaidCheckBackgroundInspectHooked then
		panel.__sfRaidCheckBackgroundInspectHooked = true
		panel:HookScript("OnShow", function()
			UpdateBackgroundInspect("equipment page shown")
		end)
		panel:HookScript("OnHide", function()
			UpdateBackgroundInspect("equipment page hidden")
		end)
	end

	UpdateBackgroundInspect("equipment page initialized")
end

local function BuildLootHelperDefinition(panel, sectionIds)
	local dialogs = SF.SettingsUI.Dialogs
	local store = SF.SettingsStore

	panel.__sfAddAdminSelectedId = panel.__sfAddAdminSelectedId or nil

	local function HasActiveProfile()
		return GetActiveProfileObject(store) ~= nil or GetActiveProfileId(store) ~= nil
	end

	local function ProfileActionsEnabled()
		return HasActiveProfile()
	end

	local function BuildOwnerDisplay()
		local profile = GetActiveProfileObject(store)
		if not profile then return "-" end

		local ownerId
		if type(profile.GetOwnerId) == "function" then
			ownerId = profile:GetOwnerId()
		else
			ownerId = profile.ownerId
		end

		if not ownerId then
			return "-"
		end

		local name = tostring(ownerId)
		local color = "|cffffffff"
		if type(profile.getMemberByID) == "function" then
			local member = profile:getMemberByID(ownerId)
			if type(member) == "table" then
				name = member.member_name or member.name or name
				color = GetMemberClassColor(member)
			end
		end

		return color .. name .. "|r"
	end

	local function BuildAdminItems()
		local profile = GetActiveProfileObject(store)
		if not profile then return {} end
		if type(profile.getAdminMemberIds) ~= "function" or type(profile.getMemberByID) ~= "function" then
			return {}
		end

		local ownerId
		if type(profile.GetOwnerId) == "function" then
			ownerId = profile:GetOwnerId()
		else
			ownerId = profile.ownerId
		end

		local items = {}
		for _, memberId in ipairs(profile:getAdminMemberIds() or {}) do
			local member = profile:getMemberByID(memberId)
			local name = (type(member) == "table" and (member.member_name or member.name)) or tostring(memberId)
			local color = GetMemberClassColor(member)
			table.insert(items, {
				id = memberId,
				name = name,
				text = color .. name .. "|r",
				canRemove = (ownerId ~= nil) and (memberId ~= ownerId) or false,
			})
		end

		table.sort(items, function(a, b)
			return tostring(a.name) < tostring(b.name)
		end)
		return items
	end

	local function BuildSelectableMemberOptions(includeAdmins)
		local profile = GetActiveProfileObject(store)
		if not profile or type(profile.getMemberIds) ~= "function" or type(profile.getMemberByID) ~= "function" then
			return {}
		end

		local adminById = {}
		if type(profile.getAdminMemberIds) == "function" then
			for _, memberId in ipairs(profile:getAdminMemberIds() or {}) do
				adminById[memberId] = true
			end
		end

		local out = {}
		for _, memberId in ipairs(profile:getMemberIds() or {}) do
			if includeAdmins or not adminById[memberId] then
				local member = profile:getMemberByID(memberId)
				local name = (type(member) == "table" and (member.member_name or member.name)) or tostring(memberId)
				local color = GetMemberClassColor(member)
				table.insert(out, { value = memberId, label = color .. name .. "|r", _sort = name })
			end
		end

		table.sort(out, function(a, b)
			return tostring(a._sort) < tostring(b._sort)
		end)
		for _, item in ipairs(out) do
			item._sort = nil
		end
		return out
	end

	local function BuildMemberOptions()
		return BuildSelectableMemberOptions(false)
	end

	local function BuildAllMemberOptions()
		return BuildSelectableMemberOptions(true)
	end

	local sectionsById = {
		general = {
			id = "general",
			title = "General Settings",
			tooltip = "Character-level Loot Helper options for this client, plus global actions such as a full reset.",
			items = {
				{ type = "checkbox", label = "Enable LootHelper", tooltip = "Turn Loot Helper on or off for this character. When it is off, the Loot Helper window and related features stay disabled on this client.", path = "lootHelper.enabled" },
				{ type = "checkbox", label = "Lock Loot Window", tooltip = "Prevent the Loot Helper window from being moved or resized.", path = "lootHelper.lockLootWindow" },
				{ type = "checkbox", label = "Show Members not in raid", tooltip = "Show profile members even when they are not currently in your raid. Turn this off to focus only on people who are present.", path = "lootHelper.showMembersNotInRaid" },
				{ type = "checkbox", label = "Show Loot Window outside of Raid", tooltip = "Allow the Loot Helper window to appear even when you are not currently in a raid.", path = "lootHelper.showWindowOutsideRaid" },
				{ type = "checkbox", label = "Enable Local Safemode", tooltip = "Pause bulk sync and profile transfer work on your client. Use this if you want to avoid large data updates locally; it does not affect other players.", path = "lootHelper.localSafeMode" },
				{ type = "checkbox", label = "Enable Local Safemode on Combat", tooltip = "Automatically turn on local safemode when you enter combat so bulk sync and profile transfers pause on your client.", path = "lootHelper.localSafeModeOnCombat" },
				{ type = "spacer", height = 10 },
				{
					type = "button",
					label = "Reset All LootHelper Settings",
					buttonText = "Reset All",
					width = 140,
					tooltip = "Delete every Loot Helper profile and reset every Loot Helper setting saved on this client.",
					onClick = function(ctx)
						ctx.section:ClearMessage()
						if not dialogs or not dialogs.Confirm then
							ctx.section:SetMessage("Dialogs.Confirm not available.", "error")
							return
						end

						dialogs:Confirm(
							"Reset ALL LootHelper settings and delete ALL profiles?",
							"Reset All",
							function()
								if type(ctx.store.ResetAllLootHelperSettings) ~= "function" then
									ctx.section:SetMessage("ResetAllLootHelperSettings() not implemented", "error")
									return
								end

								local ok, err = ctx.store:ResetAllLootHelperSettings()
								if not ok then
									ctx.section:SetMessage(err or "Reset failed", "error")
									return
								end

								ctx.section:SetMessage("LootHelper reset complete.", "success")
								ctx.pageBuilder:Refresh()
							end
						)
					end,
				},
			},
		},
		profile = {
			id = "profile",
			title = "Profile Settings",
			tooltip = "Manage the active Loot Helper profile: choose it, rename it, adjust point settings, and configure raid check requirements.",
			items = {
				{ type = "help", text = "You currently have no profiles. Create one in General Section", indent = "label", visible = function() return not HasAnyProfiles(store) and not HasActiveProfile() end },
				{
					type = "dropdownIconButton",
					label = "Active Profile",
					tooltip = "Choose which Loot Helper profile this character is currently viewing and editing.",
					defaultText = "Select profile",
					get = function() return GetActiveProfileId(store) end,
					set = function(value)
						if store.SetActiveLootHelperProfileId then
							store:SetActiveLootHelperProfileId(value)
						else
							store:Set("lootHelper.activeProfileId", value)
						end
					end,
					options = function() return GetProfileOptions(store) end,
					enabled = function() return HasAnyProfiles(store) end,
					iconAtlas = "common-icon-redx",
					iconTooltip = "Delete the currently active profile",
					iconEnabled = function() return ProfileActionsEnabled() end,
					onValueChanged = function(ctx)
						ctx.section:ClearMessage()
						ctx.pageBuilder:Refresh()
					end,
					onIconClick = function(ctx)
						ctx.section:ClearMessage()
						local activeId = GetActiveProfileId(ctx.store)
						if not activeId then
							ctx.section:SetMessage("No active profile to delete.", "error")
							return
						end

						dialogs:Confirm(
							"Delete the active profile?",
							"Delete",
							function()
								if type(ctx.store.DeleteLootHelperProfile) ~= "function" then
									ctx.section:SetMessage("DeleteLootHelperProfile() not implemented", "error")
									return
								end

								local ok, err = ctx.store:DeleteLootHelperProfile(activeId)
								if not ok then
									ctx.section:SetMessage(err or "Failed to delete profile", "error")
									return
								end

								ctx.section:SetMessage("Profile deleted.", "success")
								ctx.pageBuilder:Refresh()
							end
						)
					end,
				},
				{ type = "editboxButton", label = "Create Profile", hint = "Profile name", buttonText = "Create", buttonWidth = 90, editWidth = 170, tooltip = "Create a new Loot Helper profile and make it the active profile immediately.", onSubmit = function(ctx, text, editBox) ctx.section:ClearMessage() if type(ctx.store.CreateLootHelperProfile) ~= "function" then ctx.section:SetMessage("CreateLootHelperProfile() not implemented", "error") return end local ok, err = ctx.store:CreateLootHelperProfile(text) if not ok then ctx.section:SetMessage(err or "Failed to create profile", "error") return end editBox:SetText("") ctx.section:SetMessage("Profile created.", "success") ctx.pageBuilder:Refresh() end },
				{ type = "display", label = "Profile Owner", get = function() return BuildOwnerDisplay() end, visible = function() return HasActiveProfile() end },
				{
					type = "button",
					label = "Rename Profile",
					adminOnly = true,
					buttonText = "Rename",
					width = 120,
					tooltip = "Change the name of the active Loot Helper profile for everyone who uses it.",
					enabled = function() return ProfileActionsEnabled() end,
					onClick = function(ctx)
						local currentName = "(active profile)"
						if store.GetActiveProfileSettings then
							currentName = store:GetActiveProfileSetting("name", currentName)
						end

						ctx.ui.Dialogs:Prompt(
							"Enter a new profile name:",
							"Rename",
							"",
							function(newName)
								ctx.section:ClearMessage()
								if type(ctx.store.RenameActiveLootHelperProfile) ~= "function" then
									ctx.section:SetMessage("RenameActiveLootHelperProfile() not implemented", "error")
									return
								end

								local ok, err = ctx.store:RenameActiveLootHelperProfile(newName)
								if not ok then
									ctx.section:SetMessage(err or "Rename failed", "error")
									return
								end

								ctx.section:SetMessage("Profile renamed.", "success")
								ctx.pageBuilder:Refresh()
							end
						)
					end,
				},
				{
					type = "editbox",
					label = "Point Name",
					adminOnly = true,
					tooltip = "Rename the point currency used by this profile. This changes labels like 'Points' in the Loot Helper window and related messages.",
					enabled = function() return ProfileActionsEnabled() end,
					get = function()
						local profile = GetActiveProfileObject(store)
						if profile and type(profile.GetPointName) == "function" then
							return profile:GetPointName()
						end
						return "Points"
					end,
					set = function(value)
						local profile = GetActiveProfileObject(store)
						if profile and type(profile.SetPointName) == "function" then
							profile:SetPointName(value)
						end
					end,
					maxLetters = 24,
				},
				{
					type = "button",
					label = "Reset Current Profile",
					buttonText = "Reset",
					width = 120,
					tooltip = "Reset the active profile back to its default settings without deleting the profile itself.",
					enabled = function() return ProfileActionsEnabled() end,
					onClick = function(ctx)
						ctx.section:ClearMessage()
						dialogs:Confirm(
							"Reset settings for the current profile?",
							"Reset",
							function()
								if type(ctx.store.ResetCurrentLootHelperProfile) ~= "function" then
									ctx.section:SetMessage("ResetCurrentLootHelperProfile() not implemented", "error")
									return
								end

								local ok, err = ctx.store:ResetCurrentLootHelperProfile()
								if not ok then
									ctx.section:SetMessage(err or "Reset failed", "error")
									return
								end

								ctx.section:SetMessage("Profile reset complete.", "success")
								ctx.pageBuilder:Refresh()
							end
						)
					end,
				},
				{ type = "spacer", height = 12 },
				{ type = "heading", text = "Raid Check Profile Settings" },
				{ type = "slider", label = "Points Per Raid Check", adminOnly = true, min = 0, max = 1, step = 0.5, tooltip = "Set how many points each prepared player earns when running a Raid Check.", enabled = function() return ProfileActionsEnabled() end, get = function() return GetRaidCheckPointsAwardPerCheck() end, set = function(v) SetRaidCheckPointsAwardPerCheck(v) end },
				{ type = "text", text = "Requirements to look for" },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Gem in Sockets", tooltip = "Require socketed gear to have gems inserted during raid checks.", get = function() return IsRaidCheckGemSocketsEnabled() end, set = function(v) SetRaidCheckGemSockets(v) end }, { label = "At Least One Meta Gem", tooltip = "Require at least one meta gem to be equipped in a valid socket during raid checks.", get = function() return IsRaidCheckMetaGemRequired() end, set = function(v) SetRaidCheckMetaGemRequired(v) end } } },
				{ type = "text", text = "Enchants to look for" },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Head", get = function() return IsRaidCheckSlotEnabled("head") end, set = function(v) SetRaidCheckSlot("head", v) end }, { label = "Gloves", get = function() return IsRaidCheckSlotEnabled("hands") end, set = function(v) SetRaidCheckSlot("hands", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Neck", get = function() return IsRaidCheckSlotEnabled("neck") end, set = function(v) SetRaidCheckSlot("neck", v) end }, { label = "Belt", get = function() return IsRaidCheckSlotEnabled("belt") end, set = function(v) SetRaidCheckSlot("belt", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Shoulders", get = function() return IsRaidCheckSlotEnabled("shoulders") end, set = function(v) SetRaidCheckSlot("shoulders", v) end }, { label = "Legs", get = function() return IsRaidCheckSlotEnabled("legs") end, set = function(v) SetRaidCheckSlot("legs", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Back", get = function() return IsRaidCheckSlotEnabled("back") end, set = function(v) SetRaidCheckSlot("back", v) end }, { label = "Boots", get = function() return IsRaidCheckSlotEnabled("boots") end, set = function(v) SetRaidCheckSlot("boots", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Chest", get = function() return IsRaidCheckSlotEnabled("chest") end, set = function(v) SetRaidCheckSlot("chest", v) end }, { label = "Rings", get = function() return IsRaidCheckSlotEnabled("rings") end, set = function(v) SetRaidCheckSlot("rings", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Wrist", get = function() return IsRaidCheckSlotEnabled("wrist") end, set = function(v) SetRaidCheckSlot("wrist", v) end }, { label = "Trinkets", get = function() return IsRaidCheckSlotEnabled("trinkets") end, set = function(v) SetRaidCheckSlot("trinkets", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Weapon", get = function() return IsRaidCheckSlotEnabled("weapon") end, set = function(v) SetRaidCheckSlot("weapon", v) end }, { label = "Off Hand", get = function() return IsRaidCheckSlotEnabled("offHand") end, set = function(v) SetRaidCheckSlot("offHand", v) end } } },
			},
		},
		session = {
			id = "session",
			title = "Session Settings",
			tooltip = "Manage the live Loot Helper session for this profile, including session start and stop, raid-wide safemode, and raid check behavior.",
			condition = CanShowAdminTools,
			items = {
				{ type = "button", label = "Session Control", adminOnly = true, buttonText = function() if IsSessionActive() then return "End Session" end return "Start Session" end, width = 120, tooltip = "Start a Loot Helper session for the active profile, or end the current one if a session is already running.", enabled = function() return ProfileActionsEnabled() end, onClick = function(ctx) ctx.section:ClearMessage() if not (SF.LootHelperSync and SF.LootHelperSync.StartSession and SF.LootHelperSync.EndSession) then ctx.section:SetMessage("Loot Helper Sync system not available", "error") return end if IsSessionActive() then local ok = SF.LootHelperSync:EndSession("manual") if ok then ctx.section:SetMessage("Session ended successfully", "success") else ctx.section:SetMessage("Failed to end session", "error") end else local profileId = GetActiveProfileId(ctx.store) if not profileId then ctx.section:SetMessage("No active profile selected", "error") return end local sessionId = SF.LootHelperSync:StartSession(profileId) if sessionId then ctx.section:SetMessage("Session started successfully", "success") else ctx.section:SetMessage("Failed to start session (not in a group/raid?)", "error") end end ctx.pageBuilder:Refresh() end },
				{ type = "text", text = "Enable Raid Wide Safe Mode" },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Only in-combat", tooltip = "Automatically enable raid-wide safemode during combat. While active, everyone in the session pauses bulk sync and profile transfer operations.", get = function() if store.GetActiveProfileSetting then return store:GetActiveProfileSetting("raidWideSafeModeOnCombat", false) end return false end, set = function(value) if store.SetActiveProfileSetting then store:SetActiveProfileSetting("raidWideSafeModeOnCombat", value and true or false) end end }, { label = "All the Time", tooltip = "Keep raid-wide safemode enabled for the full session. While active, everyone in the session pauses bulk sync and profile transfer operations.", get = function() if store.GetActiveProfileSetting then return store:GetActiveProfileSetting("raidWideSafeMode", false) end return false end, set = function(value) if store.SetActiveProfileSetting then store:SetActiveProfileSetting("raidWideSafeMode", value and true or false) end end } } },
				{ type = "button", label = "Trigger Raid-Wide Sync", adminOnly = true, buttonText = "Sync", width = 120, tooltip = "Planned admin action: ask everyone in the active session to resend their Loot Helper data. This button is not implemented yet.", enabled = function() return ProfileActionsEnabled() end, onClick = function(ctx) ctx.section:SetMessage("Stub: Trigger Raid-Wide Sync (implement later).", "warn") end },
				{ type = "spacer", height = 12 },
				{ type = "heading", text = "Raid Check Settings" },
				{ type = "text", text = "Raid Checks..." },
					{ type = "buttonRow", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, { text = "Pre-Raid Check", width = 180, onClick = function(ctx) if SF.RaidCheck and SF.RaidCheck.RunPreRaidCheck then SF.RaidCheck:RunPreRaidCheck() ctx.section:SetMessage("Pre-Raid Check started.", "info") else ctx.section:SetMessage("Raid Check is not available.", "error") end end }, { text = "Raid Check", width = 180, onClick = function(ctx) if SF.RaidCheck and SF.RaidCheck.RunRaidCheck then SF.RaidCheck:RunRaidCheck() ctx.section:SetMessage("Raid Check started.", "info") else ctx.section:SetMessage("Raid Check is not available.", "error") end end } },
					{ type = "text", text = "Enable Whispers During..." },
					{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Pre-Raid Check", tooltip = "Whisper players after a Pre-Raid Check if they are missing required enchants or gems.", get = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersPreRaid or false end, set = function(value) SetRaidCheckWhispers("pre", value) if panel and panel.__sfPageBuilder then panel.__sfPageBuilder:Refresh() panel.__sfPageBuilder:Reflow() end end }, { label = "Raid Check", tooltip = "Whisper each player their Raid Check result. Players who are missing requirements are told what to fix; fully prepared players are told they earned a point.", get = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersRaid or false end, set = function(value) SetRaidCheckWhispers("raid", value) if panel and panel.__sfPageBuilder then panel.__sfPageBuilder:Refresh() panel.__sfPageBuilder:Reflow() end end } } },
					{ type = "checkbox", label = "Whisper when a point is earned", adminOnly = true, tooltip = "Only applies when Raid Check whispers are enabled. When checked, prepared players are whispered that they earned a point.", visible = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersRaid or false end, enabled = function() return ProfileActionsEnabled() end, get = function() local cfg = GetRaidCheckConfig() if cfg == nil then return true end return cfg.enableWhispersRaidPrepared ~= false end, set = function(value) SetRaidCheckPreparedWhispers(value) if panel and panel.__sfPageBuilder then panel.__sfPageBuilder:Refresh() panel.__sfPageBuilder:Reflow() end end },
					{
						type = "spacer",
						adminOnly = true,
						visible = function() return ShouldShowWhisperTemplates() end,
						height = 12,
					},
					{
						type = "titleDivider",
						text = "Whisper Templates",
						tooltip = "Customize the whisper that is sent by modifying the templates below.",
						adminOnly = true,
						visible = function() return ShouldShowWhisperTemplates() end,
					},
					{ type = "help", adminOnly = true, visible = function() return ShouldShowWhisperTemplates() end, indent = "label", text = "Customize the whisper that is sent by modifying the templates below." },
					{ type = "help", adminOnly = true, visible = function() return ShouldShowWhisperTemplates() end, indent = "label", text = "Use the variables below in the template as placeholders for dynamic data:" },
					{
						type = "keyValueBox",
						adminOnly = true,
						visible = function() return ShouldShowWhisperTemplates() end,
						keyWidth = 140,
						items = {
							{ key = "{player_name}", value = "The name of the player being whispered" },
							{ key = "{missing}", value = "Comma separated list of missing enchants/gems" },
							{ key = "{point_name}", value = "The profile's point name (Raid Check only)" },
							{ key = "{points_awarded}", value = "The number of points awarded (Raid Check only)" },
						},
					},
					{ type = "templateEditor", label = "Pre-Raid Check Whisper", adminOnly = true, buttonText = "Reset to default", enabled = function() return ProfileActionsEnabled() end, visible = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersPreRaid or false end, get = function() return GetRaidCheckWhisperTemplate("pre_raid_missing") end, set = function(value) SetRaidCheckWhisperTemplate("pre_raid_missing", value) end, onReset = function(ctx) ResetRaidCheckWhisperTemplate("pre_raid_missing") ctx.pageBuilder:Refresh() ctx.pageBuilder:Reflow() end },
					{ type = "templateEditor", label = "Raid-Check Whisper (Missing something)", adminOnly = true, buttonText = "Reset to default", enabled = function() return ProfileActionsEnabled() end, visible = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersRaid or false end, get = function() return GetRaidCheckWhisperTemplate("raid_missing") end, set = function(value) SetRaidCheckWhisperTemplate("raid_missing", value) end, onReset = function(ctx) ResetRaidCheckWhisperTemplate("raid_missing") ctx.pageBuilder:Refresh() ctx.pageBuilder:Reflow() end },
					{ type = "templateEditor", label = "Raid-Check Whisper (Nothing missing)", adminOnly = true, buttonText = "Reset to default", enabled = function() return ProfileActionsEnabled() end, visible = function() local cfg = GetRaidCheckConfig() return cfg and (cfg.enableWhispersRaid and cfg.enableWhispersRaidPrepared ~= false) or false end, get = function() return GetRaidCheckWhisperTemplate("raid_prepared") end, set = function(value) SetRaidCheckWhisperTemplate("raid_prepared", value) end, onReset = function(ctx) ResetRaidCheckWhisperTemplate("raid_prepared") ctx.pageBuilder:Refresh() ctx.pageBuilder:Reflow() end },
				},
			},
			admin = {
			id = "admin",
			title = "Admin Settings",
			tooltip = "Manage who can administer the active profile and use admin-only session tools.",
			condition = CanShowAdminTools,
			items = {
				{ type = "scrollList", label = "Admins", adminOnly = true, height = 160, rowHeight = 20, removeAtlas = "common-icon-redx", compactColumns = true, removeColumnGap = 6, enabled = function() return ProfileActionsEnabled() end, getItems = function() return BuildAdminItems() end, onRemove = function(ctx, item) if type(ctx.store.RemoveAdminFromActiveProfile) ~= "function" then ctx.section:SetMessage("RemoveAdminFromActiveProfile() not implemented", "error") return end local ok, err = ctx.store:RemoveAdminFromActiveProfile(item.id) if not ok then ctx.section:SetMessage(err or "Failed to remove admin", "error") return end ctx.section:SetMessage("Admin removed.", "success") ctx.pageBuilder:Refresh() end },
				{ type = "dropdownIconButton", label = "Add Admin", adminOnly = true, defaultText = "Select member", options = function() return BuildMemberOptions() end, get = function() return panel.__sfAddAdminSelectedId end, set = function(value) panel.__sfAddAdminSelectedId = value end, enabled = function() return ProfileActionsEnabled() end, iconAtlas = "common-icon-plus", iconToolTip = "Add the selected member as an admin for the active profile", iconEnabled = function() return ProfileActionsEnabled() and panel.__sfAddAdminSelectedId ~= nil end, onIconClick = function(ctx) if SF.Debug then SF.Debug:Info("UI", "Add Admin button clicked") end ctx.section:ClearMessage() local memberId = panel.__sfAddAdminSelectedId if SF.Debug then SF.Debug:Info("UI", "Selected memberId: %s", tostring(memberId)) end if not memberId then ctx.section:SetMessage("Select a member first.", "error") return end if type(ctx.store.AddAdminToActiveProfile) ~= "function" then ctx.section:SetMessage("AddAdminToActiveProfile() not implemented", "error") return end if SF.Debug then SF.Debug:Info("UI", "Calling AddAdminToActiveProfile with memberId: %s", tostring(memberId)) end local ok, err = ctx.store:AddAdminToActiveProfile(memberId) if SF.Debug then SF.Debug:Info("UI", "AddAdminToActiveProfile returned: ok=%s, err=%s", tostring(ok), tostring(err)) end if not ok then ctx.section:SetMessage(err or "Failed to add admin", "error") return end ctx.section:SetMessage("Admin added.", "success") ctx.pageBuilder:Refresh() end },
				{ type = "button", label = "Transfer Points / Main Swap", adminOnly = true, buttonText = "Main Swap", width = 140, tooltip = "Transfer all point and member-history references from one existing profile member to another existing profile member, then remove the old character from the profile.", enabled = function() return ProfileActionsEnabled() end, onClick = function(ctx) ctx.section:ClearMessage() if type(ctx.store.TransferMemberHistoryInActiveProfile) ~= "function" then ctx.section:SetMessage("TransferMemberHistoryInActiveProfile() not implemented", "error") return end local memberOptions = BuildAllMemberOptions() if #memberOptions < 2 then ctx.section:SetMessage("Add at least two profile members before using Main Swap.", "error") return end dialogs:TransferMemberHistory("Transfer all point history from one profile member to another, then remove the old character from this profile?", "Transfer", memberOptions, memberOptions, function(sourceMemberId, targetMemberId) local ok, err = ctx.store:TransferMemberHistoryInActiveProfile(sourceMemberId, targetMemberId) if not ok then ctx.section:SetMessage(err or "Main Swap failed", "error") return end ctx.section:SetMessage("Main Swap completed.", "success") ctx.pageBuilder:Refresh() end) end },
			},
		},
	}

	local sections = {}
	for _, sectionId in ipairs(sectionIds or {}) do
		local sectionDef = sectionsById[sectionId]
		if sectionDef then
			table.insert(sections, sectionDef)
		end
	end

	return {
		isAdmin = function()
			return IsAdmin()
		end,
		sections = sections,
	}
end

local function BuildPage(panel, pageName, sectionIds)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Building LootHelper settings page: %s", tostring(pageName))
	end

	SF.SettingsUI.DefinitionRenderer:Build(panel, BuildLootHelperDefinition(panel, sectionIds))
end

local function RefreshPage(panel)
	SF.SettingsUI.DefinitionRenderer:Refresh(panel)
end

function RootPage:Build(panel)
	BuildPage(panel, self.id, { "general" })
end

function RootPage:Refresh(panel)
	RefreshPage(panel)
end

function GeneralPage:Build(panel)
	BuildPage(panel, self.id, { "general" })
end

function GeneralPage:Refresh(panel)
	RefreshPage(panel)
end

function ProfilePage:Build(panel)
	BuildPage(panel, self.id, { "profile" })
end

function ProfilePage:Refresh(panel)
	RefreshPage(panel)
end

function SessionPage:Build(panel)
	BuildPage(panel, self.id, { "session" })
end

function SessionPage:Refresh(panel)
	RefreshPage(panel)
end

function EquipmentPage:Build(panel)
	BuildEquipmentPage(panel)
end

function EquipmentPage:Refresh(panel)
	local pageBuilder = panel.__sfPageBuilder
	if pageBuilder then
		pageBuilder:Refresh()
		pageBuilder:Reflow()
	end
end

function AdminPage:Build(panel)
	BuildPage(panel, self.id, { "admin" })
end

function AdminPage:Refresh(panel)
	RefreshPage(panel)
end

SF.SettingsUI:RegisterPage(RootPage)
SF.SettingsUI:RegisterPage(GeneralPage)
SF.SettingsUI:RegisterPage(ProfilePage)
SF.SettingsUI:RegisterPage(SessionPage)
SF.SettingsUI:RegisterPage(EquipmentPage)
SF.SettingsUI:RegisterPage(AdminPage)
