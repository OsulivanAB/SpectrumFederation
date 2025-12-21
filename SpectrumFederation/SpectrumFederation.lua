-- Grab the namespace
local addonName, SF = ...

-- Database Initialization
function SF:InitializeDatabase()

    -- Check if the global SavedVariable exists.
    -- If it is nil, it means this is a fresh install or first run
    if not SpectrumFederationDB then
        SpectrumFederationDB = {
            lootProfiles = {},
            activeLootProfile = nil
        }
        print("|cFF00FF00" .. addonName .. "|r: Initialized new database.")
        if SF.Debug then SF.Debug:Info("DATABASE", "Initialized new database for fresh install") end
    else
        if SF.Debug then SF.Debug:Info("DATABASE", "Loaded existing database") end
    end

    -- Create a shortcut in our namespace
    SF.db = SpectrumFederationDB
end



-- Create an Event Frame for Addon Initialization
local EventFrame = CreateFrame("Frame")

-- Register the Player Login Event
EventFrame:RegisterEvent("PLAYER_LOGIN")

-- Script to run when Player Login Event fires
EventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        
        -- Initialize DebugDB
        if not SpectrumFederationDebugDB then
            SpectrumFederationDebugDB = {
                enabled = false,
                logs = {},
                maxEntries = 500
            }
        end
        SF.debugDB = SpectrumFederationDebugDB
        
        -- Initialize Debug System
        if SF.Debug then
            SF.Debug:Initialize()
            SF.Debug:Info("ADDON", "SpectrumFederation addon loaded")
        end
        
        -- Initialize the Database
        SF:InitializeDatabase()

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