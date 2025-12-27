-- This file contains validation functions for LootLog event data
-- These validators ensure that log data is valid before log creation

-- Grab the namespace
local addonName, SF = ...

-- Create validators namespace
local LootLogValidators = {}

-- Access constants from SF namespace (will be available after LootLogs.lua loads)
-- We'll use dynamic access in validation functions

-- Function to validate if member exists in Loot Profiles member dictionary
-- @param memberIdentifier (string) - Member full identifier "Name-Realm"
-- @return (boolean) - True if member exists, false otherwise
function LootLogValidators.MemberExistsInProfiles(memberIdentifier)
    -- TODO: Implement this function to check if the member exists in any loot profile's member dictionary
    return true
end

-- Function to validate the POINT_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @param POINT_CHANGE_TYPES (table) - Point change type constants
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidatePointChangeData(eventData, POINT_CHANGE_TYPES)
    local memberID = eventData.member
    local changeType = eventData.change

    -- Validate member exists in profiles
    if not LootLogValidators.MemberExistsInProfiles(memberID) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Point change log references non-existent member: %s", tostring(memberID))
        end
        return false
    end

    -- Validate change type by checking if the passed value matches valid constants
    if changeType ~= POINT_CHANGE_TYPES.INCREMENT and changeType ~= POINT_CHANGE_TYPES.DECREMENT then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid point change type in log for member %s: %s", tostring(memberID), tostring(changeType))
        end
        return false
    end

    return true
end

-- Function to validate the ARMOR_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @param ARMOR_ACTIONS (table) - Armor action constants
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateArmorChangeData(eventData, ARMOR_ACTIONS)
    local memberID = eventData.member
    local slot = eventData.slot
    local action = eventData.action

    -- Validate member exists in profiles
    if not LootLogValidators.MemberExistsInProfiles(memberID) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Armor change log references non-existent member: %s", tostring(memberID))
        end
        return false
    end
    
    -- Validate slot by checking if the passed value matches any valid armor slot
    local validSlot = false
    for _, slotValue in pairs(SF.ArmorSlots) do
        if slot == slotValue then
            validSlot = true
            break
        end
    end
    
    if not validSlot then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid armor slot in log for member %s: %s", tostring(memberID), tostring(slot))
        end
        return false
    end
    
    -- Validate action by checking if the passed value matches valid constants
    if action ~= ARMOR_ACTIONS.USED and action ~= ARMOR_ACTIONS.AVAILABLE then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid armor action in log for member %s: %s", tostring(memberID), tostring(action))
        end
        return false
    end
    
    return true
end

-- Function to validate the ROLE_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateRoleChangeData(eventData)
    local memberID = eventData.member
    local newRole = eventData.newRole

    -- Validate member exists in profiles
    if not LootLogValidators.MemberExistsInProfiles(memberID) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Role change log references non-existent member: %s", tostring(memberID))
        end
        return false
    end
    
    -- Validate newRole is a valid member role constant value
    if newRole ~= SF.MemberRoles.ADMIN and newRole ~= SF.MemberRoles.MEMBER then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid role in log for member %s: %s", tostring(memberID), tostring(newRole))
        end
        return false
    end
    
    return true
end

-- Export to namespace
SF.LootLogValidators = LootLogValidators
