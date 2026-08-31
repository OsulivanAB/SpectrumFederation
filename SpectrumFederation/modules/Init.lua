-- Grab the namespace
local addonName, SF = ...

-- Optional child addons declare ## Dependencies: SpectrumFederation and
-- ## X-SpectrumFederation-Parent: SpectrumFederation. They may read
-- _G.SpectrumFederation for Debug, slash registration, and time helpers.
-- The parent discovers installed children from TOC metadata only and never
-- loads child Lua or XML.
_G[addonName] = SF

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

    if SF.MouseTracer and SF.MouseTracer.Init then
        if SF.Debug then
            SF.Debug:Verbose("INIT", "Initializing Mouse Tracer")
        end
        SF.MouseTracer:Init()
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

    if SF.VersionCheck and SF.VersionCheck.EnsureSupport then
        if SF.Debug then
            SF.Debug:Verbose("INIT", "Initializing addon version check")
        end
        SF.VersionCheck:EnsureSupport()
    end

    if SF.Debug then
        SF.Debug:Info("INIT", "All modules initialized successfully")
    end
end)
