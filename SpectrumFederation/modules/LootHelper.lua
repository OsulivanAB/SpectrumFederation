-- Grab the namespace
local addonName, SF = ...

-- Database Initialization
function SF:InitializeLootDatabase()

    -- Check if the global SavedVariable exists.
    -- If it is nil, it means this is a fresh install or first run
    if not SpectrumLootDB then
        SpectrumLootDB = {
            lootProfiles = {},
            activeLootProfile = nil
        }
        print("|cFF00FF00" .. addonName .. "|r: Initialized Loot database.")
        if SF.Debug then SF.Debug:Info("DATABASE", "Initialized new loot database for fresh install") end
    else
        if SF.Debug then SF.Debug:Info("DATABASE", "Loaded existing loot database") end
    end

    -- Create a shortcut in our namespace
    SF.lootDB = SpectrumLootDB
end