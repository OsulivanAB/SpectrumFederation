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

local function EnsureRaidCheckWhisperPopupContent(content)
	if not content then
		return nil
	end

	if content._sfRaidCheckWhisperInitialized then
		return content
	end

	content:SetSize(RAIDCHECK_WHISPER_CONTENT_WIDTH, RAIDCHECK_WHISPER_CONTENT_INITIAL_HEIGHT)

	content.instructions = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	content.instructions:SetJustifyH("LEFT")
	content.instructions:SetJustifyV("TOP")
	content.instructions:SetWordWrap(true)
	content.instructions:SetText(
		"Customize the whispers sent during Pre-Raid and Raid Check.\n\n" ..
			"Variables:\n" ..
			"  {missing_list}  - List of missing enchants/gems\n" ..
			"  {point_name}    - The profile point name\n" ..
			"  {point_award}   - The points awarded (raid only)\n" ..
			"  {player}        - The player's name\n\n" ..
			"Leave a box blank to use the default message."
	)

	content.preMissingLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	content.preMissingLabel:SetText("Pre-Raid: Missing requirements")

	content.preMissingScroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
	content.preMissingEditBox = CreateFrame("EditBox", nil, content.preMissingScroll)
	content.preMissingEditBox:SetPoint("TOPLEFT")
	content.preMissingEditBox:SetPoint("TOPRIGHT")
	content.preMissingEditBox:SetHeight(64)
	content.preMissingEditBox:SetMultiLine(true)
	content.preMissingEditBox:SetFontObject(ChatFontNormal)
	content.preMissingEditBox:SetAutoFocus(false)
	content.preMissingEditBox:SetTextColor(1, 1, 1)
	content.preMissingEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	content.preMissingEditBox:SetScript("OnTextChanged", function()
		if content.preMissingScroll and content.preMissingScroll.UpdateScrollChildRect then
			content.preMissingScroll:UpdateScrollChildRect()
		end
	end)
	content.preMissingScroll:SetScrollChild(content.preMissingEditBox)

	content.raidMissingLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	content.raidMissingLabel:SetText("Raid Check: Missing requirements")

	content.raidMissingScroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
	content.raidMissingEditBox = CreateFrame("EditBox", nil, content.raidMissingScroll)
	content.raidMissingEditBox:SetPoint("TOPLEFT")
	content.raidMissingEditBox:SetPoint("TOPRIGHT")
	content.raidMissingEditBox:SetHeight(64)
	content.raidMissingEditBox:SetMultiLine(true)
	content.raidMissingEditBox:SetFontObject(ChatFontNormal)
	content.raidMissingEditBox:SetAutoFocus(false)
	content.raidMissingEditBox:SetTextColor(1, 1, 1)
	content.raidMissingEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	content.raidMissingEditBox:SetScript("OnTextChanged", function()
		if content.raidMissingScroll and content.raidMissingScroll.UpdateScrollChildRect then
			content.raidMissingScroll:UpdateScrollChildRect()
		end
	end)
	content.raidMissingScroll:SetScrollChild(content.raidMissingEditBox)

	content.raidPreparedLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	content.raidPreparedLabel:SetText("Raid Check: Point awarded")

	content.raidPreparedScroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
	content.raidPreparedEditBox = CreateFrame("EditBox", nil, content.raidPreparedScroll)
	content.raidPreparedEditBox:SetPoint("TOPLEFT")
	content.raidPreparedEditBox:SetPoint("TOPRIGHT")
	content.raidPreparedEditBox:SetHeight(64)
	content.raidPreparedEditBox:SetMultiLine(true)
	content.raidPreparedEditBox:SetFontObject(ChatFontNormal)
	content.raidPreparedEditBox:SetAutoFocus(false)
	content.raidPreparedEditBox:SetTextColor(1, 1, 1)
	content.raidPreparedEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	content.raidPreparedEditBox:SetScript("OnTextChanged", function()
		if content.raidPreparedScroll and content.raidPreparedScroll.UpdateScrollChildRect then
			content.raidPreparedScroll:UpdateScrollChildRect()
		end
	end)
	content.raidPreparedScroll:SetScrollChild(content.raidPreparedEditBox)

	content._sfRaidCheckWhisperInitialized = true
	return content
end

local function LayoutRaidCheckWhisperPopupContent(content)
	if not content then
		return
	end

	local contentWidth = content:GetWidth() or RAIDCHECK_WHISPER_CONTENT_WIDTH
	local insetX = RAIDCHECK_WHISPER_CONTENT_INSET_X
	local innerWidth = math.max(1, contentWidth - (insetX * 2))

	content.instructions:ClearAllPoints()
	content.instructions:SetPoint("TOPLEFT", content, "TOPLEFT", insetX, 0)
	content.instructions:SetPoint("TOPRIGHT", content, "TOPRIGHT", -insetX, 0)
	content.instructions:SetWidth(innerWidth)

	local y = -(content.instructions:GetStringHeight() or 0) - 10

	content.preMissingLabel:ClearAllPoints()
	content.preMissingLabel:SetPoint("TOPLEFT", content, "TOPLEFT", insetX, y)
	y = y - (content.preMissingLabel:GetStringHeight() or 0) - 4

	content.preMissingScroll:ClearAllPoints()
	content.preMissingScroll:SetPoint("TOPLEFT", content, "TOPLEFT", insetX, y)
	content.preMissingScroll:SetSize(innerWidth, 64)
	y = y - 64 - 10

	content.raidMissingLabel:ClearAllPoints()
	content.raidMissingLabel:SetPoint("TOPLEFT", content, "TOPLEFT", insetX, y)
	y = y - (content.raidMissingLabel:GetStringHeight() or 0) - 4

	content.raidMissingScroll:ClearAllPoints()
	content.raidMissingScroll:SetPoint("TOPLEFT", content, "TOPLEFT", insetX, y)
	content.raidMissingScroll:SetSize(innerWidth, 64)
	y = y - 64 - 10

	content.raidPreparedLabel:ClearAllPoints()
	content.raidPreparedLabel:SetPoint("TOPLEFT", content, "TOPLEFT", insetX, y)
	y = y - (content.raidPreparedLabel:GetStringHeight() or 0) - 4

	content.raidPreparedScroll:ClearAllPoints()
	content.raidPreparedScroll:SetPoint("TOPLEFT", content, "TOPLEFT", insetX, y)
	content.raidPreparedScroll:SetSize(innerWidth, 64)
	y = y - 64

	content:SetHeight(math.max(1, -y))
end

if not StaticPopupDialogs[RAIDCHECK_WHISPER_KEY] then
	StaticPopupDialogs[RAIDCHECK_WHISPER_KEY] = {
		text = "%s",
		button1 = RAIDCHECK_WHISPER_SAVE_LABEL,
		button2 = CANCEL,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,

		OnShow = function(self, data)
			local content = EnsureRaidCheckWhisperPopupContent(self.insertedFrame)
			if not content then
				return
			end

			local templates = data and data.templates or {}
			content.preMissingEditBox:SetText(tostring(templates.preMissing or ""))
			content.raidMissingEditBox:SetText(tostring(templates.raidMissing or ""))
			content.raidPreparedEditBox:SetText(tostring(templates.raidPrepared or ""))

			content.preMissingEditBox:SetCursorPosition(0)
			content.raidMissingEditBox:SetCursorPosition(0)
			content.raidPreparedEditBox:SetCursorPosition(0)

			LayoutRaidCheckWhisperPopupContent(content)
			if self.Resize then
				self:Resize()
			end
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

	return StaticPopup_Show(RAIDCHECK_WHISPER_KEY, message, nil, {
		templates = templates or {},
		onAccept = onAccept,
	}, insertedFrame) ~= nil
end
