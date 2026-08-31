-- Standalone Raid Equipment settings page (no Loot Helper profile/session required).
-- luacheck: globals CreateFrame GameTooltip GetTime C_Timer UIPanelScrollFrameTemplate OptionsSliderTemplate

local _, SF = ...

SF.SettingsUI:RegisterCategory({
	id = "raidEquipment",
	name = "Raid Equipment",
	navLabel = "Raid Equipment",
	group = "Loot Tools",
	description = "Inspect current group equipment against current-Retail enchant and gem rules.",
	order = 18,
})

local EQUIPMENT_PAGE_WINDOW_WIDTH = 1280
local EQUIPMENT_REFRESH_DEBOUNCE_SECONDS = 0.15
local EQUIPMENT_MANUAL_REFRESH_WINDOW_SECONDS = 4.0
local EQUIPMENT_MANUAL_REFRESH_FOLLOW_UP_COUNT = 8
local EQUIPMENT_MANUAL_REFRESH_FOLLOW_UP_DELAY_SECONDS = 0.25
local EQUIPMENT_MANUAL_REFRESH_INITIAL_DELAY_SECONDS = 0.05

local Page = {
	id = "raidEquipmentAudit",
	categoryId = "raidEquipment",
	name = "Raid Equipment",
	navLabel = "Raid Equipment",
	contentHeading = "Raid Equipment",
	group = "Loot Tools",
	description = "Inspect current group equipment, refresh snapshots, and review missing enchants or gems.",
	order = 18,
	layout = {
		windowWidth = EQUIPMENT_PAGE_WINDOW_WIDTH,
		disablePageScroll = true,
	},
}

local function IsEquipmentAutoRefreshEnabled()
	local store = SF.SettingsStore
	if not store or not store.Get then
		return false
	end
	return store:Get("lootHelper.raidCheckAuditAutoRefresh") and true or false
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
		rowData.missingMetaGem and "mm1" or "mm0",
		rowData.metaGemPending and "mp1" or "mp0",
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
	if rowData and rowData.missingMetaGem then
		name = string.format("%s |cffff4040(Limited Gem)|r", name)
	end
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

	if rowData and rowData.missingMetaGem then
		GameTooltip:AddLine("Missing required limited gem (Eversong Diamond).", 1, 0.25, 0.25, true)
	elseif rowData and rowData.metaGemPending then
		GameTooltip:AddLine("Limited gem data is still loading.", 0.75, 0.75, 0.75, true)
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
		title = "Raid Equipment",
		tooltip = "Shows the current-Retail equipment audit. No Loot Helper profile or session is required.",
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

function Page:Build(panel)
	BuildEquipmentPage(panel)
end

function Page:Refresh(panel)
	local pageBuilder = panel.__sfPageBuilder
	if pageBuilder then
		pageBuilder:Refresh()
		pageBuilder:Reflow()
	end
end

SF.SettingsUI:RegisterPage(Page)
