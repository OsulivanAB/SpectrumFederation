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
	local activeProfile = SF.lootHelperDB and SF.lootHelperDB.activeProfile
	if not activeProfile or not activeProfile.GetMemberList then
		if SF.Debug then
			SF.Debug:Warn("LOOTLOG", "No active loot profile set when validating member: %s", tostring(memberIdentifier))
		end
		return false
	end

	local members = activeProfile:GetMemberList()
	if type(members) ~= "table" then return false end

	-- Normalize compare if NameUtil exists
	local function Same(a, b)
		if SF.NameUtil and SF.NameUtil.SamePlayer then
			return SF.NameUtil.SamePlayer(a, b)
		end
		return a == b
	end

	for _, member in ipairs(members) do
		local id = member
		if type(member) == "table" and member.GetFullIdentifier then
			id = member:GetFullIdentifier()
		elseif type(member) == "table" and member.identifier then
			id = member.identifier
		end

		if type(id) == "string" and Same(id, memberIdentifier) then
			return true
		end
	end

	return false
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

-- Function to validate the POINT_NAME_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidatePointNameChangeData(eventData)
    local oldName = eventData.oldName
    local newName = eventData.newName
    
    -- Both names must be non-empty strings
    if type(oldName) ~= "string" or oldName == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid oldName in POINT_NAME_CHANGE: %s", tostring(oldName))
        end
        return false
    end
    
    if type(newName) ~= "string" or newName == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid newName in POINT_NAME_CHANGE: %s", tostring(newName))
        end
        return false
    end
    
    return true
end

-- Function to validate the PROFILE_NAME_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateProfileNameChangeData(eventData)
    local oldName = eventData.oldName
    local newName = eventData.newName
    
    -- Both names must be non-empty strings
    if type(oldName) ~= "string" or oldName == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid oldName in PROFILE_NAME_CHANGE: %s", tostring(oldName))
        end
        return false
    end
    
    if type(newName) ~= "string" or newName == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid newName in PROFILE_NAME_CHANGE: %s", tostring(newName))
        end
        return false
    end
    
    return true
end

-- Function to validate the SAFEMODE_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateSafemodeChangeData(eventData)
    local enabled = eventData.enabled
    
    -- Must be a boolean
    if type(enabled) ~= "boolean" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid enabled value in SAFEMODE_CHANGE: %s", tostring(enabled))
        end
        return false
    end
    
    return true
end

-- Function to validate the SAFEMODE_ON_COMBAT_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateSafemodeOnCombatChangeData(eventData)
    local enabled = eventData.enabled
    
    -- Must be a boolean
    if type(enabled) ~= "boolean" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid enabled value in SAFEMODE_ON_COMBAT_CHANGE: %s", tostring(enabled))
        end
        return false
    end
    
    return true
end

-- Function to validate the ADMIN_ADDED event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateAdminAddedData(eventData)
    local memberID = eventData.member
    
    -- Validate member exists in profiles
    if not LootLogValidators.MemberExistsInProfiles(memberID) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Admin added log references non-existent member: %s", tostring(memberID))
        end
        return false
    end
    
    return true
end

-- Function to validate the ADMIN_REMOVED event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateAdminRemovedData(eventData)
    local memberID = eventData.member
    
    -- Validate member exists in profiles
    if not LootLogValidators.MemberExistsInProfiles(memberID) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Admin removed log references non-existent member: %s", tostring(memberID))
        end
        return false
    end
    
    return true
end

-- Export to namespace
SF.LootLogValidators = LootLogValidators
