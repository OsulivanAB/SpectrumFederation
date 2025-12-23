-- Grab the namespace
local addonName, SF = ...

local WINDOW_DEFAULTS = {
    enabled = true,
    shown = true,
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
    width = 420,
    height = 300
}

-- Database Initialization for Loot Helper Module
-- @return: none
function SF:InitializeLootHelperDatabase()
    -- Initialize loot helper settings in main database if not present
    if not SpectrumFederationDB.lootHelper then
        SpectrumFederationDB.lootHelper = {
            lootProfiles = {},
            activeProfile = nil,
            windowSettings = WINDOW_DEFAULTS
        }
        if SF.Debug then SF.Debug:Info("DATABASE", "Initialized loot helper settings in main database") end
    else
        if SF.Debug then SF.Debug:Info("DATABASE", "Loaded existing loot helper settings from main database") end
    end

    SF.lootHelperDB = SpectrumFederationDB.lootHelper
end