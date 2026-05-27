-- modules/UI/Settings/Dialogs.lua  
local _, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

UI.Dialogs = UI.Dialogs or {}
local Dialogs = UI.Dialogs

local KEY = "SF_SETTINGS_CONFIRM"

-- Create once
if not StaticPopupDialogs[KEY] then
    StaticPopupDialogs[KEY] = {
        text = "%s",
        button1 = OKAY,
        button2 = CANCEL,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,

        OnAccept = function(_, data)
            if type(data) == "function" then
                data()
            end
        end,
    }
end
-- Show a confirmation dialog with accept and cancel buttons
-- @param message string Message text to display
-- @param acceptText string|nil Text for accept button (defaults to OKAY)
-- @param onAccept function|nil Callback function called if user accepts
-- @return boolean True if dialog was shown, false otherwise
function Dialogs:Confirm(message, acceptText, onAccept)
    if SF.Debug then
        SF.Debug:Verbose("UI", "Showing confirmation dialog: %s", message)
    end
    StaticPopupDialogs[KEY].button1 = acceptText or OKAY
    local popup = StaticPopup_Show(KEY, message, nil, onAccept)
    return popup ~= nil
end

local PROMPT_KEY = "SF_SETTINGS_PROMPT"

if not StaticPopupDialogs[PROMPT_KEY] then
    StaticPopupDialogs[PROMPT_KEY] = {
        text = "%s",
        button1 = OKAY,
        button2 = CANCEL,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
        hasEditBox = true,
        editBoxWidth = 220,

        OnShow = function(self, data)
            local editBox = self.editBox or self.EditBox
            if not editBox then return end
            editBox:SetAutoFocus(true)

            if data and data.defaultText then
                editBox:SetText(data.defaultText)
                editBox:HighlightText()
            else
                editBox:SetText("")
            end
        end,

        OnAccept = function(self, data)
            local editBox = self.editBox or self.EditBox
            local text = (editBox and editBox:GetText()) or ""
            if data and type(data.onAccept) == "function" then
                data.onAccept(text)
            end
        end,

        EditBoxOnEnterPressed = function(self, data)
            local parent = self:GetParent()
            local editBox = (parent and (parent.editBox or parent.EditBox)) or self
            local text = (editBox and editBox:GetText()) or ""
            if data and type(data.onAccept) == "function" then
                data.onAccept(text)
            end
            parent:Hide()
        end,
    }
end

-- Show a prompt dialog with text input field
-- @param message string Message text to display
-- @param acceptText string|nil Text for accept button (defaults to OKAY)
-- @param defaultText string|nil Default text in the input field
-- @param onAccept function|nil Callback function(text) called if user accepts
-- @return boolean True if dialog was shown, false otherwise
function Dialogs:Prompt(message, acceptText, defaultText, onAccept)
    if SF.Debug then
        SF.Debug:Verbose("UI", "Showing prompt dialog: %s", message)
    end
    StaticPopupDialogs[PROMPT_KEY].button1 = acceptText or OKAY
    return StaticPopup_Show(PROMPT_KEY, message, nil, {
        defaultText = defaultText,
        onAccept = onAccept
    }) ~= nil
end

local TRANSFER_KEY = "SF_SETTINGS_MEMBER_TRANSFER"
-- Keep inserted content close to the default StaticPopup text width (290) so the dialog doesn't expand/warp.
local TRANSFER_CONTENT_WIDTH = 290
local TRANSFER_CONTENT_INITIAL_HEIGHT = 1
local TRANSFER_CONTENT_INSET_X = 8

local RAIDCHECK_WHISPER_KEY = "SF_SETTINGS_RAIDCHECK_WHISPERS"
local RAIDCHECK_WHISPER_CONTENT_WIDTH = 290
local RAIDCHECK_WHISPER_CONTENT_INITIAL_HEIGHT = 1
local RAIDCHECK_WHISPER_CONTENT_INSET_X = 8
local RAIDCHECK_WHISPER_SAVE_LABEL = (type(SAVE) == "string" and SAVE) or "Save"
local RAIDCHECK_WHISPER_BOX_INSET = 4
local RAIDCHECK_WHISPER_SCROLLBAR_WIDTH = 24
local RAIDCHECK_WHISPER_TEXTBOX_HEIGHT = 64
	local RAIDCHECK_WHISPER_SCROLL_RIGHT_GAP = 6
	local RAIDCHECK_WHISPER_MIN_WIDTH = 360
	local RAIDCHECK_WHISPER_MIN_HEIGHT = 420
	local RAIDCHECK_WHISPER_SCROLLBAR_TEXT_GAP = 10
	local RAIDCHECK_WHISPER_VARIABLE_NAME_COL_WIDTH = 110
	local RAIDCHECK_WHISPER_VARIABLE_GAP_X = 12
	local RAIDCHECK_WHISPER_DEFAULT_DIALOG_WIDTH = 700
	local RAIDCHECK_WHISPER_DEFAULT_DIALOG_HEIGHT = 650
	local RAIDCHECK_WHISPER_OUTER_SCROLL_INSET = 8

local RAIDCHECK_WHISPER_BOX_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 8,
	edgeSize = 12,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

	local function CreateTextBox(parent)
	local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	if box.SetBackdrop then
		box:SetBackdrop(RAIDCHECK_WHISPER_BOX_BACKDROP)
		box:SetBackdropColor(0, 0, 0, 0.12)
		box:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
	end

	local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", box, "TOPLEFT", RAIDCHECK_WHISPER_BOX_INSET, -RAIDCHECK_WHISPER_BOX_INSET)
	scroll:SetPoint(
		"BOTTOMRIGHT",
		box,
		"BOTTOMRIGHT",
		-(RAIDCHECK_WHISPER_BOX_INSET + RAIDCHECK_WHISPER_SCROLL_RIGHT_GAP),
		RAIDCHECK_WHISPER_BOX_INSET
	)

		local editBox = CreateFrame("EditBox", nil, scroll)
		editBox:SetPoint("TOPLEFT")
		editBox:SetMultiLine(true)
		editBox:SetFontObject(ChatFontNormal)
		editBox:SetAutoFocus(false)
		editBox:SetTextColor(1, 1, 1)
		editBox:SetTextInsets(2, 2, 2, 2)
		editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		scroll:SetScrollChild(editBox)

		editBox:SetWidth(200)
		editBox:SetHeight(RAIDCHECK_WHISPER_TEXTBOX_HEIGHT)

		local function GetScrollBarWidth()
			local sb = scroll.ScrollBar
			if sb and sb.GetWidth then
				local sbw = sb:GetWidth()
				if sbw and sbw > 0 then
					return sbw
				end
			end
			return RAIDCHECK_WHISPER_SCROLLBAR_WIDTH
		end

		local function UpdateSize()
			local scrollWidth = scroll:GetWidth() or 0
			if scrollWidth < 40 then
				return
			end

			local w = scrollWidth - GetScrollBarWidth() - RAIDCHECK_WHISPER_SCROLLBAR_TEXT_GAP
			if w > 20 then
				editBox:SetWidth(w)
			end

		local minH = scroll:GetHeight() or RAIDCHECK_WHISPER_TEXTBOX_HEIGHT
		local textH = (editBox:GetStringHeight() or 0) + 16
		editBox:SetHeight(math.max(minH, textH))

		if scroll.UpdateScrollChildRect then
			scroll:UpdateScrollChildRect()
			end
		end

		local function ScheduleUpdate()
			if box.__sfUpdateScheduled then return end
			box.__sfUpdateScheduled = true

			if C_Timer and C_Timer.After then
				C_Timer.After(0, function()
					box.__sfUpdateScheduled = false
					UpdateSize()
				end)
			else
				box.__sfUpdateScheduled = false
				UpdateSize()
			end
		end

		scroll:SetScript("OnSizeChanged", UpdateSize)
		editBox:SetScript("OnTextChanged", UpdateSize)

		ScheduleUpdate()
		return box, scroll, editBox, UpdateSize, ScheduleUpdate
	end

local function EnsureRaidCheckWhisperPopupContent(content)
	if not content then
		return nil
	end

	if content._sfRaidCheckWhisperInitialized then
		return content
	end

	content:SetSize(RAIDCHECK_WHISPER_CONTENT_WIDTH, RAIDCHECK_WHISPER_CONTENT_INITIAL_HEIGHT)

			if not content.__sfRaidCheckWhisperOuterScroll then
				local outerScroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
				outerScroll:SetPoint("TOPLEFT", content, "TOPLEFT", RAIDCHECK_WHISPER_OUTER_SCROLL_INSET, -RAIDCHECK_WHISPER_OUTER_SCROLL_INSET)
				outerScroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -RAIDCHECK_WHISPER_OUTER_SCROLL_INSET, RAIDCHECK_WHISPER_OUTER_SCROLL_INSET)

				outerScroll:EnableMouseWheel(true)
			outerScroll:SetScript("OnMouseWheel", function(self, delta)
				local step = 20
				local current = self.GetVerticalScroll and self:GetVerticalScroll() or 0
				local range = self.GetVerticalScrollRange and self:GetVerticalScrollRange() or 0
				local nextScroll = current - (delta * step)
				if nextScroll < 0 then nextScroll = 0 end
				if nextScroll > range then nextScroll = range end
				if self.SetVerticalScroll then
					self:SetVerticalScroll(nextScroll)
				end
			end)

			local child = CreateFrame("Frame", nil, outerScroll)
				child:SetSize(1, 1)
				outerScroll:SetScrollChild(child)

				if outerScroll.ScrollBar and outerScroll.ScrollBar.Hide then
					outerScroll.ScrollBar:Hide()
				end

				content.__sfRaidCheckWhisperOuterScroll = outerScroll
				content.__sfRaidCheckWhisperOuterChild = child
			end

		local root = content.__sfRaidCheckWhisperOuterChild or content

		content.titleText = root:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		content.titleText:SetJustifyH("LEFT")
		content.titleText:SetJustifyV("TOP")
		content.titleText:SetWordWrap(true)
		content.titleText:SetText("Customize whispers for Raid Check and Pre-Raid Check.")

		content.variablesHeader = root:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		content.variablesHeader:SetJustifyH("LEFT")
		content.variablesHeader:SetJustifyV("TOP")
		content.variablesHeader:SetText("Variables:")

		content.variablesFrame = CreateFrame("Frame", nil, root)

		content.variableRows = {}
		local variables = {
			{ "{missing_list}", "List of missing enchants/gems" },
			{ "{point_name}", "The profile point name" },
			{ "{point_award}", "The points awarded (raid only)" },
			{ "{player}", "The player's name" },
		}

		for i = 1, #variables do
			local row = CreateFrame("Frame", nil, content.variablesFrame)
			row.nameText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.nameText:SetJustifyH("LEFT")
			row.nameText:SetJustifyV("TOP")
			row.nameText:SetText(variables[i][1])

			row.descText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.descText:SetJustifyH("LEFT")
			row.descText:SetJustifyV("TOP")
			row.descText:SetWordWrap(true)
			row.descText:SetText(variables[i][2])

			content.variableRows[#content.variableRows + 1] = row
		end

		content.noteText = root:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		content.noteText:SetJustifyH("LEFT")
		content.noteText:SetJustifyV("TOP")
		content.noteText:SetWordWrap(true)
		content.noteText:SetText("Clearing a box and saving will reset it to the default message.")

	content.preMissingLabel = root:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	content.preMissingLabel:SetText("Pre-Raid: Missing requirements")

		content.preMissingBox, content.preMissingScroll, content.preMissingEditBox, content.preMissingUpdateSize, content.preMissingScheduleUpdateSize = CreateTextBox(root)

	content.raidMissingLabel = root:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	content.raidMissingLabel:SetText("Raid Check: Missing requirements")

		content.raidMissingBox, content.raidMissingScroll, content.raidMissingEditBox, content.raidMissingUpdateSize, content.raidMissingScheduleUpdateSize = CreateTextBox(root)

	content.raidPreparedLabel = root:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	content.raidPreparedLabel:SetText("Raid Check: Point awarded")

		content.raidPreparedBox, content.raidPreparedScroll, content.raidPreparedEditBox, content.raidPreparedUpdateSize, content.raidPreparedScheduleUpdateSize = CreateTextBox(root)

	content._sfRaidCheckWhisperInitialized = true
	return content
end

	local function LayoutRaidCheckWhisperPopupContent(content)
		if not content then
			return
		end

		local outerScroll = content.__sfRaidCheckWhisperOuterScroll
		local outerScrollBarWidth = 0
		if outerScroll and outerScroll.ScrollBar and outerScroll.ScrollBar.GetWidth then
			outerScrollBarWidth = outerScroll.ScrollBar:GetWidth() or 0
		end
		if outerScrollBarWidth <= 0 then
			outerScrollBarWidth = RAIDCHECK_WHISPER_SCROLLBAR_WIDTH
		end

		local root = content.__sfRaidCheckWhisperOuterChild or content

		local viewportWidth = content:GetWidth() or RAIDCHECK_WHISPER_CONTENT_WIDTH
		if outerScroll and outerScroll.GetWidth then
			local w = outerScroll:GetWidth() or 0
			if w > 0 then
				viewportWidth = w
			end
		end

		local reserveForScrollBar = 0
		if outerScroll and outerScroll.ScrollBar and outerScroll.ScrollBar.IsShown and outerScroll.ScrollBar:IsShown() then
			reserveForScrollBar = outerScrollBarWidth + RAIDCHECK_WHISPER_SCROLLBAR_TEXT_GAP
		end

		local contentWidth = viewportWidth - reserveForScrollBar
		if contentWidth < RAIDCHECK_WHISPER_CONTENT_WIDTH then
			contentWidth = RAIDCHECK_WHISPER_CONTENT_WIDTH
		end

		root:SetWidth(contentWidth)
	local insetX = RAIDCHECK_WHISPER_CONTENT_INSET_X
	local innerWidth = math.max(1, contentWidth - (insetX * 2))
	local boxHeight = content.__sfTextBoxHeight or RAIDCHECK_WHISPER_TEXTBOX_HEIGHT

		content.titleText:ClearAllPoints()
		content.titleText:SetPoint("TOPLEFT", root, "TOPLEFT", insetX, 0)
		content.titleText:SetPoint("TOPRIGHT", root, "TOPRIGHT", -insetX, 0)
		content.titleText:SetWidth(innerWidth)

		local y = -(content.titleText:GetStringHeight() or 0) - 8

		content.variablesHeader:ClearAllPoints()
		content.variablesHeader:SetPoint("TOPLEFT", root, "TOPLEFT", insetX, y)
		content.variablesHeader:SetPoint("TOPRIGHT", root, "TOPRIGHT", -insetX, y)
		content.variablesHeader:SetWidth(innerWidth)

		y = y - (content.variablesHeader:GetStringHeight() or 0) - 4

		local nameColWidth = RAIDCHECK_WHISPER_VARIABLE_NAME_COL_WIDTH
		local descX = nameColWidth + RAIDCHECK_WHISPER_VARIABLE_GAP_X
		local descWidth = math.max(1, innerWidth - descX)

		content.variablesFrame:ClearAllPoints()
		content.variablesFrame:SetPoint("TOPLEFT", root, "TOPLEFT", insetX, y)
		content.variablesFrame:SetWidth(innerWidth)

		local rowsHeight = 0
		for i = 1, #content.variableRows do
			local row = content.variableRows[i]

			row.nameText:ClearAllPoints()
			row.nameText:SetPoint("TOPLEFT", content.variablesFrame, "TOPLEFT", 0, -rowsHeight)
			row.nameText:SetWidth(nameColWidth)

			row.descText:ClearAllPoints()
			row.descText:SetPoint("TOPLEFT", content.variablesFrame, "TOPLEFT", descX, -rowsHeight)
			row.descText:SetWidth(descWidth)

			local nameHeight = row.nameText:GetStringHeight() or 0
			local descHeight = row.descText:GetStringHeight() or 0
			rowsHeight = rowsHeight + math.max(nameHeight, descHeight) + 2
		end

		content.variablesFrame:SetHeight(rowsHeight)
		y = y - rowsHeight - 6

		content.noteText:ClearAllPoints()
		content.noteText:SetPoint("TOPLEFT", root, "TOPLEFT", insetX, y)
		content.noteText:SetPoint("TOPRIGHT", root, "TOPRIGHT", -insetX, y)
		content.noteText:SetWidth(innerWidth)

		y = y - (content.noteText:GetStringHeight() or 0) - 10

	content.preMissingLabel:ClearAllPoints()
	content.preMissingLabel:SetPoint("TOPLEFT", root, "TOPLEFT", insetX, y)
	y = y - (content.preMissingLabel:GetStringHeight() or 0) - 4

	content.preMissingBox:ClearAllPoints()
	content.preMissingBox:SetPoint("TOPLEFT", root, "TOPLEFT", insetX, y)
	content.preMissingBox:SetSize(innerWidth, boxHeight)
	y = y - boxHeight - 10

	content.raidMissingLabel:ClearAllPoints()
	content.raidMissingLabel:SetPoint("TOPLEFT", root, "TOPLEFT", insetX, y)
	y = y - (content.raidMissingLabel:GetStringHeight() or 0) - 4

	content.raidMissingBox:ClearAllPoints()
	content.raidMissingBox:SetPoint("TOPLEFT", root, "TOPLEFT", insetX, y)
	content.raidMissingBox:SetSize(innerWidth, boxHeight)
	y = y - boxHeight - 10

	content.raidPreparedLabel:ClearAllPoints()
	content.raidPreparedLabel:SetPoint("TOPLEFT", root, "TOPLEFT", insetX, y)
	y = y - (content.raidPreparedLabel:GetStringHeight() or 0) - 4

	content.raidPreparedBox:ClearAllPoints()
	content.raidPreparedBox:SetPoint("TOPLEFT", root, "TOPLEFT", insetX, y)
	content.raidPreparedBox:SetSize(innerWidth, boxHeight)
	y = y - boxHeight

	root:SetHeight(math.max(1, -y))
end

local function UpdateRaidCheckWhisperDialogLayout(dialog)
	if not dialog then
		return
	end

	local content = EnsureRaidCheckWhisperPopupContent(dialog.insertedFrame)
	if not content then
		return
	end

		local dialogWidth = dialog:GetWidth() or 0
		local availableWidth = dialogWidth - 70
		if availableWidth < RAIDCHECK_WHISPER_CONTENT_WIDTH then
			availableWidth = RAIDCHECK_WHISPER_CONTENT_WIDTH
		end
		content:SetWidth(availableWidth)

		local dialogHeight = dialog:GetHeight() or 0
		local approxNonContent = 210
		local contentHeight = dialogHeight - approxNonContent
		if contentHeight < RAIDCHECK_WHISPER_CONTENT_INITIAL_HEIGHT then
			contentHeight = RAIDCHECK_WHISPER_CONTENT_INITIAL_HEIGHT
		end
		content:SetHeight(contentHeight)

		local outerScroll = content.__sfRaidCheckWhisperOuterScroll
		local availableHeight = contentHeight
		if outerScroll and outerScroll.GetHeight then
			local h = outerScroll:GetHeight() or 0
			if h > 0 then
				availableHeight = h
			end
		end

		local desiredBoxHeight = math.floor(availableHeight / 3)
		desiredBoxHeight = math.max(RAIDCHECK_WHISPER_TEXTBOX_HEIGHT, desiredBoxHeight)
		desiredBoxHeight = math.min(160, desiredBoxHeight)
		content.__sfTextBoxHeight = desiredBoxHeight

			LayoutRaidCheckWhisperPopupContent(content)

			if outerScroll and outerScroll.UpdateScrollChildRect then
				outerScroll:UpdateScrollChildRect()
			end
			if outerScroll and outerScroll.GetVerticalScrollRange and outerScroll.ScrollBar then
				local range = outerScroll:GetVerticalScrollRange() or 0
				local shouldShow = range > 0
				local isShown = outerScroll.ScrollBar.IsShown and outerScroll.ScrollBar:IsShown() or true
				if shouldShow ~= isShown then
					if shouldShow then
						outerScroll.ScrollBar:Show()
					else
						outerScroll.ScrollBar:Hide()
					end

					LayoutRaidCheckWhisperPopupContent(content)
					if outerScroll.UpdateScrollChildRect then
						outerScroll:UpdateScrollChildRect()
					end
				end
			end

			if content.preMissingUpdateSize then content.preMissingUpdateSize() end
			if content.raidMissingUpdateSize then content.raidMissingUpdateSize() end
		if content.raidPreparedUpdateSize then content.raidPreparedUpdateSize() end

		if content.preMissingScheduleUpdateSize then content.preMissingScheduleUpdateSize() end
		if content.raidMissingScheduleUpdateSize then content.raidMissingScheduleUpdateSize() end
		if content.raidPreparedScheduleUpdateSize then content.raidPreparedScheduleUpdateSize() end
	end

	local function EnsureRaidCheckWhisperDialogInteractions(dialog)
	if not dialog or dialog.__sfRaidCheckWhisperInteractive then
		return
	end

	dialog.__sfRaidCheckWhisperInteractive = true

	dialog:SetClampedToScreen(true)
	dialog:SetMovable(true)
	dialog:EnableMouse(true)
	dialog:RegisterForDrag("LeftButton")
	dialog:SetScript("OnDragStart", function(self)
		if self.IsMovable and self:IsMovable() then
			self:StartMoving()
		end
	end)
	dialog:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
	end)

		dialog:SetResizable(true)
		if dialog.SetMinResize then
			dialog:SetMinResize(RAIDCHECK_WHISPER_MIN_WIDTH, RAIDCHECK_WHISPER_MIN_HEIGHT)
		end

		if not dialog.__sfResizeButton then
			local resizeBtn = CreateFrame("Button", nil, dialog)
			resizeBtn:SetSize(16, 16)
			resizeBtn:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -4, 4)
			resizeBtn:SetFrameLevel((dialog:GetFrameLevel() or 0) + 20)

			resizeBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
			resizeBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
			resizeBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

			resizeBtn:SetScript("OnMouseDown", function(_, button)
				if button ~= "LeftButton" then return end
				if dialog.StartSizing then
					dialog:StartSizing("BOTTOMRIGHT")
				end
			end)
			resizeBtn:SetScript("OnMouseUp", function(_, button)
				if button ~= "LeftButton" then return end
				if dialog.StopMovingOrSizing then
					dialog:StopMovingOrSizing()
				end
			end)

			dialog.__sfResizeButton = resizeBtn
		end

	dialog:HookScript("OnSizeChanged", function(self)
		UpdateRaidCheckWhisperDialogLayout(self)
	end)
end

if not StaticPopupDialogs[RAIDCHECK_WHISPER_KEY] then
	StaticPopupDialogs[RAIDCHECK_WHISPER_KEY] = {
		text = "",
		button1 = RAIDCHECK_WHISPER_SAVE_LABEL,
		button2 = CANCEL,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,

		OnShow = function(self, data)
			EnsureRaidCheckWhisperDialogInteractions(self)

			if not self.__sfRaidCheckWhisperDefaultSizeApplied then
				self.__sfRaidCheckWhisperDefaultSizeApplied = true
				local w = self.GetWidth and self:GetWidth() or 0
				local h = self.GetHeight and self:GetHeight() or 0
				if w < RAIDCHECK_WHISPER_DEFAULT_DIALOG_WIDTH then
					self:SetWidth(RAIDCHECK_WHISPER_DEFAULT_DIALOG_WIDTH)
				end
				if h < RAIDCHECK_WHISPER_DEFAULT_DIALOG_HEIGHT then
					self:SetHeight(RAIDCHECK_WHISPER_DEFAULT_DIALOG_HEIGHT)
				end
			end

			local content = EnsureRaidCheckWhisperPopupContent(self.insertedFrame)
			if not content then
				return
			end

			local templates = data and data.templates or {}
			content.preMissingEditBox:SetText(tostring(templates.preMissing or ""))
			content.raidMissingEditBox:SetText(tostring(templates.raidMissing or ""))
			content.raidPreparedEditBox:SetText(tostring(templates.raidPrepared or ""))

			if content.preMissingScroll and content.preMissingScroll.SetVerticalScroll then content.preMissingScroll:SetVerticalScroll(0) end
			if content.raidMissingScroll and content.raidMissingScroll.SetVerticalScroll then content.raidMissingScroll:SetVerticalScroll(0) end
			if content.raidPreparedScroll and content.raidPreparedScroll.SetVerticalScroll then content.raidPreparedScroll:SetVerticalScroll(0) end

			content.preMissingEditBox:SetCursorPosition(0)
			content.raidMissingEditBox:SetCursorPosition(0)
			content.raidPreparedEditBox:SetCursorPosition(0)

			if content.__sfRaidCheckWhisperOuterScroll and content.__sfRaidCheckWhisperOuterScroll.SetVerticalScroll then
				content.__sfRaidCheckWhisperOuterScroll:SetVerticalScroll(0)
			end

			UpdateRaidCheckWhisperDialogLayout(self)
		end,

		OnAccept = function(self, data)
			if not data or type(data.onAccept) ~= "function" then
				return
			end

			local content = EnsureRaidCheckWhisperPopupContent(self.insertedFrame)
			if not content then
				return
			end

			data.onAccept(
				content.preMissingEditBox and content.preMissingEditBox:GetText() or "",
				content.raidMissingEditBox and content.raidMissingEditBox:GetText() or "",
				content.raidPreparedEditBox and content.raidPreparedEditBox:GetText() or ""
			)
		end,

		OnHide = function(self)
			local content = self.insertedFrame
			if content and content.preMissingEditBox then content.preMissingEditBox:SetText("") end
			if content and content.raidMissingEditBox then content.raidMissingEditBox:SetText("") end
			if content and content.raidPreparedEditBox then content.raidPreparedEditBox:SetText("") end
		end,
	}
end

local function SameMember(a, b)
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    return a == b
end

local function FindOptionLabel(options, value)
    for _, option in ipairs(options or {}) do
        local optionValue = type(option) == "table" and option.value or option
        if optionValue ~= nil and SameMember(optionValue, value) then
            if type(option) == "table" then
                return option.label or tostring(optionValue)
            end
            return tostring(optionValue)
        end
    end
    return nil
end

local function EnsureTransferPopupContent(content)
    if not content then
        return nil
    end

    if content._sfTransferContentInitialized then
        return content
    end

    content:SetSize(TRANSFER_CONTENT_WIDTH, TRANSFER_CONTENT_INITIAL_HEIGHT)

    content.sourceLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    content.sourceLabel:SetText("Transfer points from")

    content.sourceDropdown = CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate")
    content.sourceDropdown:SetDefaultText("Select member")

    content.targetLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    content.targetLabel:SetText("Transfer points to")

    content.targetDropdown = CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate")
    content.targetDropdown:SetDefaultText("Select member")

    content.validationText = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    content.validationText:SetJustifyH("LEFT")
    content.validationText:SetJustifyV("TOP")

    content._sfTransferContentInitialized = true
    return content
end

local function LayoutTransferPopupContent(content)
    if not content then
        return
    end

    local contentWidth = content:GetWidth() or TRANSFER_CONTENT_WIDTH
    local insetX = TRANSFER_CONTENT_INSET_X
    local innerWidth = math.max(1, contentWidth - (insetX * 2))

    content.sourceLabel:ClearAllPoints()
    content.sourceLabel:SetPoint("TOPLEFT", content, "TOPLEFT", insetX, 0)

    content.sourceDropdown:ClearAllPoints()
    content.sourceDropdown:SetPoint("TOPLEFT", content.sourceLabel, "BOTTOMLEFT", 0, -4)
    content.sourceDropdown:SetWidth(innerWidth)

    content.targetLabel:ClearAllPoints()
    content.targetLabel:SetPoint("TOPLEFT", content.sourceDropdown, "BOTTOMLEFT", 0, -10)

    content.targetDropdown:ClearAllPoints()
    content.targetDropdown:SetPoint("TOPLEFT", content.targetLabel, "BOTTOMLEFT", 0, -4)
    content.targetDropdown:SetWidth(innerWidth)

    content.validationText:ClearAllPoints()
    content.validationText:SetPoint("TOPLEFT", content.targetDropdown, "BOTTOMLEFT", 0, -10)
    content.validationText:SetWidth(innerWidth)

    local sourceLabelHeight = content.sourceLabel:GetStringHeight() or 0
    local sourceDropdownHeight = content.sourceDropdown:GetHeight() or 0
    local targetLabelHeight = content.targetLabel:GetStringHeight() or 0
    local targetDropdownHeight = content.targetDropdown:GetHeight() or 0
    local validationHeight = 0
    if content.validationText:GetText() ~= "" then
        validationHeight = content.validationText:GetStringHeight() or 0
    end

    content:SetHeight(
        sourceLabelHeight +
        4 + sourceDropdownHeight +
        10 + targetLabelHeight +
        4 + targetDropdownHeight +
        10 + validationHeight
    )
end

local function SetupTransferDropdown(dropdown, options, getValue, setValue)
    dropdown._sfOptions = options or {}
    dropdown._sfGetValue = getValue
    dropdown._sfSetValue = setValue

    local function IsSelected(value)
        local current = dropdown._sfGetValue and dropdown._sfGetValue() or nil
        if current == nil or value == nil then
            return current == value
        end
        return SameMember(current, value)
    end

    local function SetSelected(value)
        if dropdown._sfSetValue then
            dropdown._sfSetValue(value)
        end
    end

    local function Generator(_, rootDescription)
        for _, option in ipairs(dropdown._sfOptions or {}) do
            local value = type(option) == "table" and option.value or option
            local label = type(option) == "table" and option.label or tostring(option)
            if value ~= nil then
                rootDescription:CreateRadio(tostring(label or value), IsSelected, SetSelected, value)
            end
        end
    end

    dropdown:SetupMenu(Generator)
    if dropdown.GenerateMenu then
        dropdown:GenerateMenu()
    end
end

local function UpdateTransferPopupState(dialog)
    local data = dialog.data or {}
    local sourceMemberId = dialog.__sfSourceMemberId
    local targetMemberId = dialog.__sfTargetMemberId
    local content = EnsureTransferPopupContent(dialog.insertedFrame)
    if not content then
        return
    end
    local button1 = dialog.GetButton1 and dialog:GetButton1() or dialog.button1

    local valid = true
    local message = ""

    if not sourceMemberId or sourceMemberId == "" or not targetMemberId or targetMemberId == "" then
        valid = false
        message = "Select both characters before confirming."
    elseif SameMember(sourceMemberId, targetMemberId) then
        valid = false
        message = "Source and target must be different characters."
    end

    if button1 then
        if valid then
            button1:Enable()
        else
            button1:Disable()
        end
    end

    if content.validationText then
        content.validationText:SetText(message)
        if valid then
            content.validationText:SetTextColor(0.65, 0.65, 0.65)
        else
            content.validationText:SetTextColor(1, 0.2, 0.2)
        end
    end

    if content.sourceDropdown and content.sourceDropdown.SetDefaultText then
        content.sourceDropdown:SetDefaultText(FindOptionLabel(data.sourceOptions, sourceMemberId) or "Select member")
    end
    if content.targetDropdown and content.targetDropdown.SetDefaultText then
        content.targetDropdown:SetDefaultText(FindOptionLabel(data.targetOptions, targetMemberId) or "Select member")
    end

    LayoutTransferPopupContent(content)
    if dialog.Resize then
        dialog:Resize()
    end
end

if not StaticPopupDialogs[TRANSFER_KEY] then
    StaticPopupDialogs[TRANSFER_KEY] = {
        text = "%s",
        button1 = ACCEPT,
        button2 = CANCEL,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,

        OnShow = function(self, data)
            local content = EnsureTransferPopupContent(self.insertedFrame)
            if not content then
                return
            end

            self.__sfSourceMemberId = nil
            self.__sfTargetMemberId = nil
            LayoutTransferPopupContent(content)

            SetupTransferDropdown(
                content.sourceDropdown,
                data and data.sourceOptions or {},
                function()
                    return self.__sfSourceMemberId
                end,
                function(value)
                    self.__sfSourceMemberId = value
                    UpdateTransferPopupState(self)
                end
            )

            SetupTransferDropdown(
                content.targetDropdown,
                data and data.targetOptions or {},
                function()
                    return self.__sfTargetMemberId
                end,
                function(value)
                    self.__sfTargetMemberId = value
                    UpdateTransferPopupState(self)
                end
            )

            UpdateTransferPopupState(self)
        end,

        OnAccept = function(self, data)
            if not data or type(data.onAccept) ~= "function" then
                return
            end
            data.onAccept(self.__sfSourceMemberId, self.__sfTargetMemberId)
        end,

        OnHide = function(self)
            self.__sfSourceMemberId = nil
            self.__sfTargetMemberId = nil
            local content = self.insertedFrame
            if content and content.validationText then
                content.validationText:SetText("")
            end
            if content and content.sourceDropdown and content.sourceDropdown.SetDefaultText then
                content.sourceDropdown:SetDefaultText("Select member")
            end
            if content and content.targetDropdown and content.targetDropdown.SetDefaultText then
                content.targetDropdown:SetDefaultText("Select member")
            end
            if content then
                LayoutTransferPopupContent(content)
            end
        end,
    }
end

-- Show a member-transfer dialog with source/target dropdowns
-- @param message string Message text to display
-- @param acceptText string|nil Text for accept button (defaults to ACCEPT)
-- @param sourceOptions table|nil Dropdown options for the source member
-- @param targetOptions table|nil Dropdown options for the target member
-- @param onAccept function|nil Callback function(sourceMemberId, targetMemberId) called if user accepts
-- @return boolean True if dialog was shown, false otherwise
function Dialogs:TransferMemberHistory(message, acceptText, sourceOptions, targetOptions, onAccept)
    if SF.Debug then
        SF.Debug:Verbose("UI", "Showing transfer dialog: %s", message)
    end

    StaticPopupDialogs[TRANSFER_KEY].button1 = acceptText or ACCEPT

    if not self._sfTransferInsertedFrame then
        self._sfTransferInsertedFrame = CreateFrame("Frame", nil, UIParent)
    end

    local insertedFrame = EnsureTransferPopupContent(self._sfTransferInsertedFrame)
    insertedFrame:Show()
    LayoutTransferPopupContent(insertedFrame)

    return StaticPopup_Show(TRANSFER_KEY, message, nil, {
        sourceOptions = sourceOptions or {},
        targetOptions = targetOptions or {},
        onAccept = onAccept,
    }, insertedFrame) ~= nil
end

-- Show a dialog to edit Raid Check whisper templates
-- @param message string Message text to display
-- @param acceptText string|nil Text for accept button (defaults to SAVE)
-- @param templates table|nil Table containing preMissing, raidMissing, raidPrepared strings
-- @param onAccept function|nil Callback function(preMissing, raidMissing, raidPrepared) called if user accepts
-- @return boolean True if dialog was shown, false otherwise
function Dialogs:EditRaidCheckWhispers(message, acceptText, templates, onAccept)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Showing raid check whisper editor dialog")
	end

	StaticPopupDialogs[RAIDCHECK_WHISPER_KEY].button1 = acceptText or RAIDCHECK_WHISPER_SAVE_LABEL

	if not self._sfRaidCheckWhisperInsertedFrame then
		self._sfRaidCheckWhisperInsertedFrame = CreateFrame("Frame", nil, UIParent)
	end

	local insertedFrame = EnsureRaidCheckWhisperPopupContent(self._sfRaidCheckWhisperInsertedFrame)
	insertedFrame:Show()
	LayoutRaidCheckWhisperPopupContent(insertedFrame)

	return StaticPopup_Show(RAIDCHECK_WHISPER_KEY, message or "", nil, {
		templates = templates or {},
		onAccept = onAccept,
	}, insertedFrame) ~= nil
end
