-- Grab the namespace
local addonName, SF = ...

-- Function to toggle visibility of loot helper ui window
function SF:ToggleLootHelperUI()
    if SF.Debug then SF.Debug:Info("LOOT_HELPER", "ToggleLootHelperUI called") end
    
    if not SF.LootWindow then
        SF:PrintError("Loot Helper not initialized")
        if SF.Debug then SF.Debug:Error("LOOT_HELPER", "LootWindow not found") end
        return
    end
    
    -- Create window if it doesn't exist
    if not SF.LootWindow.frame then
        if SF.Debug then SF.Debug:Info("LOOT_HELPER", "Creating window frame") end
        SF.LootWindow:Create()
    end
    
    -- Toggle visibility
    if SF.LootWindow.frame:IsShown() then
        SF.LootWindow.frame:Hide()
        SF:PrintInfo("Loot Helper window hidden")
        if SF.Debug then SF.Debug:Info("LOOT_HELPER", "Window hidden") end
    else
        if SF.Debug then 
            SF.Debug:Info("LOOT_HELPER", "Showing window and refreshing content")
            -- Check if content is visible
            if SF.LootWindow.frame.content then
                SF.Debug:Info("LOOT_HELPER", "Content frame IsShown: %s", tostring(SF.LootWindow.frame.content:IsShown()))
            end
        end
        
        -- Ensure Loot Helper is enabled (content visible)
        if SF.lootHelperDB and SF.lootHelperDB.windowSettings then
            if not SF.lootHelperDB.windowSettings.enabled then
                SF.Debug:Warn("LOOT_HELPER", "Loot Helper was disabled, enabling it")
                SF.LootWindow:SetEnabled(true)
            end
        end
        
        SF.LootWindow.frame:Show()
        -- Refresh content when showing
        SF.LootWindow:PopulateContent(SF.LootWindow.testModeActive or false)
        SF:PrintInfo("Loot Helper window shown")
        
        if SF.Debug then 
            SF.Debug:Info("LOOT_HELPER", "Window shown and content populated")
            if SF.LootWindow.frame.content then
                SF.Debug:Info("LOOT_HELPER", "After show - Content frame IsShown: %s", tostring(SF.LootWindow.frame.content:IsShown()))
            end
        end
    end
end

-- Register the slash command to toggle loot helper UI
SF:RegisterSlashCommand("loot", function(args)
    if args and args:lower() == "test" then
        if SF.LootWindow then
            SF.LootWindow:ToggleTestMode()
        else
            SF:PrintError("Loot Helper not initialized")
        end
    elseif args and args:lower() == "status" then
        -- Debug command to check state
        if SF.LootWindow and SF.LootWindow.frame then
            local frame = SF.LootWindow.frame
            SF:PrintInfo("Loot Helper Status:")
            SF:PrintInfo("  Frame exists: true")
            SF:PrintInfo("  Frame shown: " .. tostring(frame:IsShown()))
            
            -- Position and size
            local w, h = frame:GetSize()
            SF:PrintInfo("  Frame size: " .. string.format("%.0f x %.0f", w or 0, h or 0))
            local x, y = frame:GetCenter()
            if x and y then
                SF:PrintInfo("  Frame center: " .. string.format("%.0f, %.0f", x, y))
            else
                SF:PrintInfo("  Frame center: OFF SCREEN")
            end
            SF:PrintInfo("  Frame alpha: " .. string.format("%.2f", frame:GetAlpha()))
            SF:PrintInfo("  Frame strata: " .. frame:GetFrameStrata())
            
            -- Content frame
            if frame.content then
                SF:PrintInfo("  Content shown: " .. tostring(frame.content:IsShown()))
                local cw, ch = frame.content:GetSize()
                SF:PrintInfo("  Content size: " .. string.format("%.0f x %.0f", cw or 0, ch or 0))
                SF:PrintInfo("  Content alpha: " .. string.format("%.2f", frame.content:GetAlpha()))
            else
                SF:PrintInfo("  Content: NIL")
            end
            
            -- Database
            if SF.lootHelperDB and SF.lootHelperDB.windowSettings then
                SF:PrintInfo("  DB enabled: " .. tostring(SF.lootHelperDB.windowSettings.enabled))
            end
            
            -- Row check
            if SF.LootWindow.memberRows and #SF.LootWindow.memberRows > 0 then
                local row = SF.LootWindow.memberRows[1]
                local rw, rh = row:GetSize()
                SF:PrintInfo("  Row 1 size: " .. string.format("%.0f x %.0f", rw or 0, rh or 0))
            end
        else
            SF:PrintInfo("Loot Helper window not created yet")
        end
    elseif args and args:lower() == "enable" then
        -- Force enable
        if SF.LootWindow then
            SF:PrintInfo("Forcing Loot Helper to enabled state...")
            SF.LootWindow:SetEnabled(true)
            SF:PrintSuccess("Loot Helper enabled")
        else
            SF:PrintError("Loot Helper not initialized")
        end
    else
        -- Default behavior - toggle UI
        SF:ToggleLootHelperUI()
    end
end, "Toggle the Loot Helper UI window (use 'loot test' to toggle test mode, 'loot status' to check state, 'loot enable' to force enable)")


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