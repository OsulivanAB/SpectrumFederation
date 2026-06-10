-- Grab the namespace
local addonName, SF = ...

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, _, loadedAddonName)
    if loadedAddonName ~= addonName then return end

    if SF.Debug then
        SF.Debug:Info("INIT", "SpectrumFederation addon loaded, initializing modules")
    end

    -- TODO: Refactor Debug so it has an init that we can put here

    if SF.SettingsStore and SF.SettingsStore.Init then
        if SF.Debug then
            SF.Debug:Verbose("INIT", "Initializing SettingsStore")
        end
        SF.SettingsStore:Init()
    end

    if SF.SettingsApply and SF.SettingsApply.Init then
        if SF.Debug then
            SF.Debug:Verbose("INIT", "Initializing SettingsApply")
        end
        SF.SettingsApply:Init()
    end

    if SF.SettingsUI and SF.SettingsUI.Init then
        if SF.Debug then
            SF.Debug:Verbose("INIT", "Initializing SettingsUI")
        end
        SF.SettingsUI:Init()
    end

    -- Initialize Standalone Settings Window (if Blizzard Settings is disabled)
    if SF.SettingsWindow and SF.SettingsWindow.Init then
        if SF.Debug then
            SF.Debug:Verbose("INIT", "Initializing Standalone Settings Window")
        end
        SF.SettingsWindow:Init()
    end

    if SF.RaidCheck and SF.RaidCheck.EnsureInspectSupport then
        if SF.Debug then
            SF.Debug:Verbose("INIT", "Initializing Raid Check inspect support")
        end
        SF.RaidCheck:EnsureInspectSupport()
    end

    if SF.RCLCListener and SF.RCLCListener.Init then
        if SF.Debug then
            SF.Debug:Verbose("INIT", "Initializing RCLootCouncil Listener")
        end
        SF.RCLCListener:Init()
    end

    if SF.Debug then
        SF.Debug:Info("INIT", "All modules initialized successfully")
    end
end)
