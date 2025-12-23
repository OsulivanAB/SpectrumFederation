-- Grab the namespace
local addonName, SF = ...

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

        -- Initialize Loot Databases
        if SF.InitializeLootDatabase then
            SF:InitializeLootDatabase()
        else
            if SF.Debug then SF.Debug:Warn("DATABASE", "InitializeLootDatabase function not found") end
        end

        -- Create the Settings UI
        if SF.CreateSettingsUI then
            SF:CreateSettingsUI()
        else
            if SF.Debug then SF.Debug:Info("SETTINGS_UI", "No CreateSettingsUI function found") end
        end

        -- Send a quick message saying that Addon is Initialized
        print("|cFF00FF00" .. addonName .. "|r: Online. Type /sf to open settings.")

        -- Initialize Slash Commands
        if SF.InitializeSlashCommands then
            SF:InitializeSlashCommands()
        else
            if SF.Debug then SF.Debug:Warn("SLASH", "InitializeSlashCommands function not found") end
        end

        -- Unregister the Event after initialization
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

-- Create an Event Frame for Addon Loaded
local AddonLoadedFrame = CreateFrame("Frame")
-- Register the ADDON_LOADED Event
AddonLoadedFrame:RegisterEvent("ADDON_LOADED")
-- Script to run when ADDON_LOADED Event fires
AddonLoadedFrame:SetScript("OnEvent", function(self, event, addonName)

    -- Ensure the loaded addon is SpectrumFederation
    if addonName ~= "SpectrumFederation" then return end

    SF.LootWindow:Create()
end)