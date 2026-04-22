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

local function EnsureTransferPopupWidgets(popup)
    if popup.__sfTransferWidgetsReady then
        return
    end

    popup:SetWidth(420)

    popup.sourceLabel = popup:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    popup.sourceLabel:SetPoint("TOPLEFT", popup, "TOPLEFT", 18, -44)
    popup.sourceLabel:SetText("Transfer points from")

    popup.sourceDropdown = CreateFrame("DropdownButton", nil, popup, "WowStyle1DropdownTemplate")
    popup.sourceDropdown:SetPoint("TOPLEFT", popup.sourceLabel, "BOTTOMLEFT", 0, -4)
    popup.sourceDropdown:SetWidth(240)
    popup.sourceDropdown:SetDefaultText("Select member")

    popup.targetLabel = popup:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    popup.targetLabel:SetPoint("TOPLEFT", popup.sourceDropdown, "BOTTOMLEFT", 0, -16)
    popup.targetLabel:SetText("Transfer points to")

    popup.targetDropdown = CreateFrame("DropdownButton", nil, popup, "WowStyle1DropdownTemplate")
    popup.targetDropdown:SetPoint("TOPLEFT", popup.targetLabel, "BOTTOMLEFT", 0, -4)
    popup.targetDropdown:SetWidth(240)
    popup.targetDropdown:SetDefaultText("Select member")

    popup.validationText = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    popup.validationText:SetPoint("TOPLEFT", popup.targetDropdown, "BOTTOMLEFT", 0, -12)
    popup.validationText:SetPoint("RIGHT", popup, "RIGHT", -18, 0)
    popup.validationText:SetJustifyH("LEFT")
    popup.validationText:SetJustifyV("TOP")

    popup.__sfTransferWidgetsReady = true
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

local function UpdateTransferPopupState(popup)
    local data = popup.data or {}
    local sourceMemberId = popup.__sfSourceMemberId
    local targetMemberId = popup.__sfTargetMemberId

    local valid = true
    local message = ""

    if not sourceMemberId or sourceMemberId == "" or not targetMemberId or targetMemberId == "" then
        valid = false
        message = "Select both characters before confirming."
    elseif SameMember(sourceMemberId, targetMemberId) then
        valid = false
        message = "Source and target must be different characters."
    end

    if popup.button1 then
        if valid then
            popup.button1:Enable()
        else
            popup.button1:Disable()
        end
    end

    if popup.validationText then
        popup.validationText:SetText(message)
        if valid then
            popup.validationText:SetTextColor(0.65, 0.65, 0.65)
        else
            popup.validationText:SetTextColor(1, 0.2, 0.2)
        end
    end

    if popup.sourceDropdown and popup.sourceDropdown.SetDefaultText then
        popup.sourceDropdown:SetDefaultText(FindOptionLabel(data.sourceOptions, sourceMemberId) or "Select member")
    end
    if popup.targetDropdown and popup.targetDropdown.SetDefaultText then
        popup.targetDropdown:SetDefaultText(FindOptionLabel(data.targetOptions, targetMemberId) or "Select member")
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
            EnsureTransferPopupWidgets(self)

            self:SetHeight(238)
            self.__sfSourceMemberId = nil
            self.__sfTargetMemberId = nil

            SetupTransferDropdown(
                self.sourceDropdown,
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
                self.targetDropdown,
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
            if self.validationText then
                self.validationText:SetText("")
            end
        end,
    }
end

function Dialogs:TransferMemberHistory(message, acceptText, sourceOptions, targetOptions, onAccept)
    if SF.Debug then
        SF.Debug:Verbose("UI", "Showing transfer dialog: %s", message)
    end

    StaticPopupDialogs[TRANSFER_KEY].button1 = acceptText or ACCEPT
    return StaticPopup_Show(TRANSFER_KEY, message, nil, {
        sourceOptions = sourceOptions or {},
        targetOptions = targetOptions or {},
        onAccept = onAccept,
    }) ~= nil
end
