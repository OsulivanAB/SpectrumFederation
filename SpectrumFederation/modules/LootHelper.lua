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

-- Function to toggle visibility of loot helper ui window
function SF:ToggleLootHelperUI()
-- TODO: Implement function once the loot helper UI window is created
end

-- Register the slash command to toggle loot helper UI
SF:RegisterSlashCommand("loot", SF:ToggleLootHelperUI(), "Toggle the Loot Helper UI window.")

-- Creates a new loot helper entry in the database
function SF:CreateLootHelperEntry(entryData)
    -- TODO: Implement function to create loot helper entry
end

-- Reads a loot helper entry from the database by ID
function SF:ReadLootHelperEntry(entryID)
    -- TODO: Implement function to read loot helper entry
end

-- Updates an existing loot helper entry in the database
function SF:UpdateLootHelperEntry(entryID, updatedData)
    -- TODO: Implement function to update loot helper entry
end

-- Deletes a loot helper entry from the database by ID
function SF:DeleteLootHelperEntry(entryID)
    -- TODO: Implement function to delete loot helper entry
end