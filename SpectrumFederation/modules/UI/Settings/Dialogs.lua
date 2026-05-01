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
local TRANSFER_CONTENT_WIDTH = 360
local transferPopupContent

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

local function EnsureTransferPopupContent()
    if transferPopupContent then
        return transferPopupContent
    end

    local content = CreateFrame("Frame", nil, UIParent)
    content:SetSize(TRANSFER_CONTENT_WIDTH, 1)
    content:Hide()

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
    content.validationText:SetWidth(TRANSFER_CONTENT_WIDTH)

    transferPopupContent = content
    return content
end

local function LayoutTransferPopupContent(content)
    if not content then
        return
    end

    content.sourceLabel:ClearAllPoints()
    content.sourceLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)

    content.sourceDropdown:ClearAllPoints()
    content.sourceDropdown:SetPoint("TOPLEFT", content.sourceLabel, "BOTTOMLEFT", 0, -4)
    content.sourceDropdown:SetWidth(TRANSFER_CONTENT_WIDTH)

    content.targetLabel:ClearAllPoints()
    content.targetLabel:SetPoint("TOPLEFT", content.sourceDropdown, "BOTTOMLEFT", 0, -10)

    content.targetDropdown:ClearAllPoints()
    content.targetDropdown:SetPoint("TOPLEFT", content.targetLabel, "BOTTOMLEFT", 0, -4)
    content.targetDropdown:SetWidth(TRANSFER_CONTENT_WIDTH)

    content.validationText:ClearAllPoints()
    content.validationText:SetPoint("TOPLEFT", content.targetDropdown, "BOTTOMLEFT", 0, -10)

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
    local content = dialog.insertedFrame or EnsureTransferPopupContent()
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
            local content = self.insertedFrame or EnsureTransferPopupContent()
            content:Show()

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
            if self.insertedFrame and self.insertedFrame.validationText then
                self.insertedFrame.validationText:SetText("")
            end
            if self.insertedFrame and self.insertedFrame.sourceDropdown and self.insertedFrame.sourceDropdown.SetDefaultText then
                self.insertedFrame.sourceDropdown:SetDefaultText("Select member")
            end
            if self.insertedFrame and self.insertedFrame.targetDropdown and self.insertedFrame.targetDropdown.SetDefaultText then
                self.insertedFrame.targetDropdown:SetDefaultText("Select member")
            end
            if self.insertedFrame then
                LayoutTransferPopupContent(self.insertedFrame)
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
    local content = EnsureTransferPopupContent()
    return StaticPopup_Show(TRANSFER_KEY, message, nil, {
        sourceOptions = sourceOptions or {},
        targetOptions = targetOptions or {},
        onAccept = onAccept,
    }, content) ~= nil
end
