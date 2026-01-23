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