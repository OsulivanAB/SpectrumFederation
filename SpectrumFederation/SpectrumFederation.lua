-- Grab the namespace
local addonName, SF = ...

-- Create an Event Frame for Addon Initialization
local EventFrame = CreateFrame("Frame")

-- Register the Player Login Event
EventFrame:RegisterEvent("PLAYER_LOGIN")

-- Script to run when Player Login Event fires
-- TODO: Add Debug Logging
EventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        
        -- Check to make sure Settings UI function exists
        if SF.CreateSettingsUI then
            SF:CreateSettingsUI()
        end

        -- Send a quick message saying that Addon is Initialized
        print("|cFF00FF00" .. addonName .. "|r: Online. Type /sf to open settings.")

        -- Unregister the Event after initialization
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

-- Register Slash Command '/sf'
SLASH_SPECFED1 = "/sf"
SlashCmdList["SPECFED"] = function(msg)
    
    if SF.SettingsCategory and SF.SettingsPanel then
        -- Get the ID for the Settings Category 
        local categoryID = SF.SettingsCategory:GetID()
        -- Open the Settings to our Addon's Category
        Settings.OpenToCategory(categoryID)
    else
        print("|cFF00FF00" .. addonName .. "|r: Settings UI is not available.")
    end

end