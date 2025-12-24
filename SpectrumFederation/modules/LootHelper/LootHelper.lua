-- Grab the namespace
local addonName, SF = ...

-- Function to toggle visibility of loot helper ui window
function SF:ToggleLootHelperUI()
-- TODO: Implement function once the loot helper UI window is created
end

-- Register the slash command to toggle loot helper UI
SF:RegisterSlashCommand("loot", function(args)
    if args and args:lower() == "test" then
        if SF.LootWindow then
            SF.LootWindow:ToggleTestMode()
        else
            SF:PrintError("Loot Helper not initialized")
        end
    else
        -- Default behavior - toggle UI
        SF:ToggleLootHelperUI()
    end
end, "Toggle the Loot Helper UI window")

-- Register the test mode subcommand for help display
SF:RegisterSlashCommand("loot test", function(args)
    -- This handler won't be called directly (loot handles it)
    -- But registering it makes it show up in /sf help
    if SF.LootWindow then
        SF.LootWindow:ToggleTestMode()
    else
        SF:PrintError("Loot Helper not initialized")
    end
end, "Toggle Loot Helper test mode (shows 15 test members)")

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