-- modules/LootHelper/EnchantmentCheck.lua
-- Handles checking raid members for missing enchantments and gems
local addonName, SF = ...

SF.EnchantmentCheck = SF.EnchantmentCheck or {}
local EC = SF.EnchantmentCheck

-- Equipment slot IDs that can be enchanted or have sockets
local CHECKABLE_SLOTS = {
    [1] = "Head",
    [2] = "Neck",
    [3] = "Shoulder",
    [5] = "Chest",
    [6] = "Waist",
    [7] = "Legs",
    [8] = "Feet",
    [9] = "Wrist",
    [10] = "Hands",
    [11] = "Finger0",
    [12] = "Finger1",
    [15] = "Back",
    [16] = "MainHand",
    [17] = "OffHand"
}

-- Slots that typically have enchantments in WoW
local ENCHANTABLE_SLOTS = {
    [2] = true,   -- Neck
    [3] = true,   -- Shoulder
    [5] = true,   -- Chest
    [7] = true,   -- Legs
    [8] = true,   -- Feet
    [9] = true,   -- Wrist
    [10] = true,  -- Hands
    [11] = true,  -- Finger0
    [12] = true,  -- Finger1
    [15] = true,  -- Back
    [16] = true,  -- MainHand
    [17] = true   -- OffHand (weapons)
}

-- Check if a unit has all required enchantments and gems
-- @param unit string Unit identifier (e.g., "raid1", "player")
-- @return table|nil missingInfo Table with missing enchantments/gems or nil if fully prepared
local function CheckUnitGear(unit)
    if not unit or not UnitExists(unit) then
        return nil
    end
    
    local missing = {
        enchantments = {},
        gems = {}
    }
    
    local hasMissing = false
    
    -- Iterate through all equipment slots
    for slotId, slotName in pairs(CHECKABLE_SLOTS) do
        local itemLink = GetInventoryItemLink(unit, slotId)
        
        if itemLink then
            -- Check for enchantments on enchantable slots
            -- Item link format: |cffffffff|Hitem:itemId:enchantId:gem1:gem2:gem3:...
            if ENCHANTABLE_SLOTS[slotId] then
                -- Extract enchant ID (4th field in item link) - use %d* to handle empty/missing enchant IDs
                local enchantId = string.match(itemLink, '^|c%x+|Hitem:%d+:(%d*)')
                
                -- Check if item can be enchanted (quality and item level check)
                local _, _, itemQuality, itemLevel = GetItemInfo(itemLink)
                local canBeEnchanted = itemQuality and itemQuality >= 2 and itemLevel and itemLevel >= 1
                
                -- Only flag as missing if item can be enchanted but has no enchant
                if canBeEnchanted and (not enchantId or enchantId == "" or enchantId == "0") then
                    table.insert(missing.enchantments, slotName)
                    hasMissing = true
                end
            end
            
            -- Check for empty gem sockets using GetItemStats
            local stats = GetItemStats(itemLink)
            if stats then
                for statName, _ in pairs(stats) do
                    if statName:find("EMPTY_SOCKET") then
                        table.insert(missing.gems, slotName)
                        hasMissing = true
                        break
                    end
                end
            end
        end
    end
    
    return hasMissing and missing or nil
end

-- Get a list of all raid members with missing enchantments/gems
-- @return table Dictionary keyed by player name-realm with missing info
function EC:GetMissingEnchantments()
    local results = {}
    
    if not IsInRaid() then
        if SF.Debug then
            SF.Debug:Info("ENCHANT_CHECK", "Not in a raid, cannot check enchantments")
        end
        return results
    end
    
    local numMembers = GetNumGroupMembers() or 0
    for i = 1, numMembers do
        local unit = "raid" .. i
        local name, realm = UnitName(unit)
        
        if name then
            realm = realm and realm ~= "" and realm or GetRealmName()
            local fullName = name .. "-" .. realm
            
            local missing = CheckUnitGear(unit)
            if missing then
                results[fullName] = missing
            end
        end
    end
    
    return results
end

-- Report missing enchantments to chat
-- @param missingData table Data from GetMissingEnchantments()
function EC:ReportMissingEnchantments(missingData)
    if not missingData or not next(missingData) then
        SF:PrintSuccess("All raid members are fully enchanted and have all gems!")
        return
    end
    
    SF:PrintWarning("The following raid members are missing enchantments or gems:")
    
    for playerName, missing in pairs(missingData) do
        local issues = {}
        
        if #missing.enchantments > 0 then
            table.insert(issues, "Missing enchantments on: " .. table.concat(missing.enchantments, ", "))
        end
        
        if #missing.gems > 0 then
            table.insert(issues, "Empty sockets on: " .. table.concat(missing.gems, ", "))
        end
        
        if #issues > 0 then
            SF:PrintInfo(string.format("  %s - %s", playerName, table.concat(issues, " | ")))
        end
    end
end

-- Award points to members who are fully prepared (all enchants and gems)
-- @param missingData table Data from GetMissingEnchantments()
-- @param inspectorName string Name of the admin who ran the check
-- @return number Number of points awarded
function EC:AwardPreparednessPoints(missingData, inspectorName)
    local profile = SF:GetActiveProfile()
    if not profile then
        SF:PrintError("No active profile - cannot award points")
        return 0
    end
    
    if not profile:IsCurrentUserAdmin() then
        SF:PrintError("You must be an admin to award preparedness points")
        return 0
    end
    
    local numMembers = GetNumGroupMembers() or 0
    local pointsAwarded = 0
    
    for i = 1, numMembers do
        local unit = "raid" .. i
        local name, realm = UnitName(unit)
        
        if name then
            realm = realm and realm ~= "" and realm or GetRealmName()
            local fullName = name .. "-" .. realm
            
            -- If member is NOT in the missing list, they're fully prepared
            if not missingData[fullName] then
                local member = profile:GetMemberByIdentifier(fullName)
                if member then
                    -- Increment their points
                    member:IncrementPoints()
                    pointsAwarded = pointsAwarded + 1
                    
                    -- Create a special loot log for preparedness
                    local logEntry = SF.LootLog.new(
                        SF.LootLogEventTypes.POINT_CHANGE,
                        {
                            member = fullName,
                            change = "PREPARED"
                        }
                    )
                    
                    if logEntry and profile.AddLootLog then
                        profile:AddLootLog(logEntry)
                    end
                    
                    if SF.Debug then
                        SF.Debug:Info("ENCHANT_CHECK", "Awarded preparedness point to %s", fullName)
                    end
                end
            end
        end
    end
    
    SF:PrintSuccess(string.format("Awarded preparedness points to %d raid members", pointsAwarded))
    return pointsAwarded
end

-- Whisper players about their missing enchantments/gems
-- @param missingData table Data from GetMissingEnchantments()
function EC:WhisperMissingPlayers(missingData)
    if not missingData or not next(missingData) then
        return
    end
    
    for playerName, missing in pairs(missingData) do
        local issues = {}
        
        if #missing.enchantments > 0 then
            table.insert(issues, "missing enchantments on: " .. table.concat(missing.enchantments, ", "))
        end
        
        if #missing.gems > 0 then
            table.insert(issues, "empty gem sockets on: " .. table.concat(missing.gems, ", "))
        end
        
        if #issues > 0 then
            -- Extract character name without realm for whisper
            local nameOnly = playerName:match('^([^-]+)') or playerName
            local message = "Please prepare your gear - you have " .. table.concat(issues, " and ")
            SendChatMessage(message, "WHISPER", nil, nameOnly)
        end
    end
    
    SF:PrintInfo("Whispered all players with missing enchantments/gems")
end

-- Main entry point for the enchantment check command
-- @param raidStarted boolean True if raid has started (award points), false for pre-raid check (whisper)
function EC:RunEnchantmentCheck(raidStarted)
    local missingData = self:GetMissingEnchantments()
    self:ReportMissingEnchantments(missingData)
    
    if raidStarted then
        self:AwardPreparednessPoints(missingData, SF:GetPlayerFullIdentifier())
    else
        self:WhisperMissingPlayers(missingData)
    end
end

