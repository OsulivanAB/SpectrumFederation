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
function LootLogValidators.MemberExistsInProfiles(memberIdentifier, profile)
	if type(profile) ~= "table" or not profile.GetMemberList then
		return true
	end

	local members = profile:GetMemberList()
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

local function NormalizeStoredNameRealm(id)
    if type(id) ~= "string" or id == "" or not id:find("-", 1, true) then
        return nil
    end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(id)
    end
    return id
end

local function SameStoredPlayer(a, b)
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    local na = NormalizeStoredNameRealm(a)
    local nb = NormalizeStoredNameRealm(b)
    return na ~= nil and na == nb
end

local function ValidateStoredNameRealmField(memberID, fieldName)
    if not NormalizeStoredNameRealm(memberID) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "%s has invalid member ID: %s", tostring(fieldName), tostring(memberID))
        end
        return false
    end
    return true
end

local function IsArrayLikeList(list)
    if type(list) ~= "table" then
        return false
    end
    local count = 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return false
        end
        count = count + 1
    end
    return count == #list
end

-- Function to validate the POINT_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @param POINT_CHANGE_TYPES (table) - Point change type constants
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidatePointChangeData(eventData, POINT_CHANGE_TYPES, profile)
    local memberID = eventData.member
    local changeType = eventData.change
    local amount = eventData.amount

    -- Validate member exists in the owning profile when one is supplied
    if not LootLogValidators.MemberExistsInProfiles(memberID, profile) then
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

    if amount ~= nil then
        amount = tonumber(amount)
        if not amount or amount <= 0 then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Invalid point change amount in log for member %s: %s", tostring(memberID), tostring(eventData.amount))
            end
            return false
        end
    end

    return true
end

-- Function to validate the ARMOR_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @param ARMOR_ACTIONS (table) - Armor action constants
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateArmorChangeData(eventData, ARMOR_ACTIONS, profile)
    local memberID = eventData.member
    local slot = eventData.slot
    local action = eventData.action

    -- Validate member exists in the owning profile when one is supplied
    if not LootLogValidators.MemberExistsInProfiles(memberID, profile) then
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

    if eventData.scope ~= nil then
        if eventData.scope ~= "identity" then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Invalid armor scope for member %s: %s", tostring(memberID), tostring(eventData.scope))
            end
            return false
        end
        if type(eventData.identityMembers) ~= "table" then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Identity armor change missing identityMembers for member %s", tostring(memberID))
            end
            return false
        end
        local seen = {}
        local count = 0
        if not IsArrayLikeList(eventData.identityMembers) then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "identityMembers must be an array")
            end
            return false
        end
        for _, id in ipairs(eventData.identityMembers) do
            local normalized = NormalizeStoredNameRealm(id)
            if not normalized then
                if SF.Debug then
                    SF.Debug:Warn("LOOTLOG", "Invalid identityMembers entry: %s", tostring(id))
                end
                return false
            end
            for seenId in pairs(seen) do
                if SameStoredPlayer(seenId, normalized) then
                    if SF.Debug then
                        SF.Debug:Warn("LOOTLOG", "Duplicate identityMembers entry: %s", tostring(id))
                    end
                    return false
                end
            end
            seen[normalized] = true
            count = count + 1
        end
        if count < 2 then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "identityMembers must contain at least two members")
            end
            return false
        end
    end

    return true
end

-- Function to validate the ROLE_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateRoleChangeData(eventData, profile)
    local memberID = eventData.member
    local newRole = eventData.newRole

    -- Validate member exists in the owning profile when one is supplied
    if not LootLogValidators.MemberExistsInProfiles(memberID, profile) then
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
    if not ValidateStoredNameRealmField(eventData and eventData.member, "ADMIN_ADDED") then
        return false
    end
    if eventData.sourceLogId ~= nil then
        if type(eventData.sourceLogId) ~= "string" then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "ADMIN_ADDED sourceLogId must be a string")
            end
            return false
        end
    end
    return true
end

-- Function to validate the ADMIN_REMOVED event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateAdminRemovedData(eventData)
    return ValidateStoredNameRealmField(eventData and eventData.member, "ADMIN_REMOVED")
end

-- Function to validate the MAIN_SWAP event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateMainSwapData(eventData)
    if not ValidateStoredNameRealmField(eventData and eventData.member, "MAIN_SWAP target") then
        return false
    end
    if not ValidateStoredNameRealmField(eventData and eventData.sourceMember, "MAIN_SWAP source") then
        return false
    end
    local memberID = eventData.member
    local sourceMember = eventData.sourceMember
    if SameStoredPlayer(memberID, sourceMember) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "MAIN_SWAP source and target must be different")
        end
        return false
    end
    return true
end

local function ValidateNameRealmList(list, fieldName, allowEmpty)
    if not IsArrayLikeList(list) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "%s must be an array", tostring(fieldName))
        end
        return false
    end
    local seen = {}
    local count = 0
    for _, id in ipairs(list) do
        local normalized = NormalizeStoredNameRealm(id)
        if not normalized then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Invalid %s entry: %s", tostring(fieldName), tostring(id))
            end
            return false
        end
        for seenId in pairs(seen) do
            if SameStoredPlayer(seenId, normalized) then
                if SF.Debug then
                    SF.Debug:Warn("LOOTLOG", "Duplicate %s entry: %s", tostring(fieldName), tostring(id))
                end
                return false
            end
        end
        seen[normalized] = true
        count = count + 1
    end
    if count == 0 and not allowEmpty then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "%s must not be empty", tostring(fieldName))
        end
        return false
    end
    return true
end

local function ValidatePreOpAuthorMax(list)
    if list == nil then
        return true
    end
    if not IsArrayLikeList(list) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "preOpAuthorMax must be an array")
        end
        return false
    end
    local seen = {}
    for _, entry in ipairs(list) do
        if type(entry) ~= "table" then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "preOpAuthorMax entries must be tables")
            end
            return false
        end
        local author = NormalizeStoredNameRealm(entry.author)
        local counter = tonumber(entry.counter)
        if not author then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Invalid preOpAuthorMax author: %s", tostring(entry.author))
            end
            return false
        end
        if not counter or counter < 1 or counter ~= math.floor(counter) then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Invalid preOpAuthorMax counter for %s: %s", tostring(author), tostring(entry.counter))
            end
            return false
        end
        for seenId in pairs(seen) do
            if SameStoredPlayer(seenId, author) then
                if SF.Debug then
                    SF.Debug:Warn("LOOTLOG", "Duplicate preOpAuthorMax author: %s", tostring(author))
                end
                return false
            end
        end
        seen[author] = true
    end
    return true
end

function LootLogValidators.ValidateCharacterLinkData(eventData)
    if type(eventData) ~= "table" then
        return false
    end
    local memberA = NormalizeStoredNameRealm(eventData.memberA)
    local memberB = NormalizeStoredNameRealm(eventData.memberB)
    if not memberA then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "CHARACTER_LINK has invalid memberA: %s", tostring(eventData.memberA))
        end
        return false
    end
    if not memberB then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "CHARACTER_LINK has invalid memberB: %s", tostring(eventData.memberB))
        end
        return false
    end
    if SameStoredPlayer(memberA, memberB) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "CHARACTER_LINK requires two different characters")
        end
        return false
    end
    if not ValidateNameRealmList(eventData.adminMembersAtLink, "adminMembersAtLink", true) then
        return false
    end
    return ValidatePreOpAuthorMax(eventData.preOpAuthorMax)
end

function LootLogValidators.ValidateCharacterUnlinkData(eventData)
    if not ValidateStoredNameRealmField(eventData and eventData.member, "CHARACTER_UNLINK") then
        return false
    end
    return ValidatePreOpAuthorMax(eventData and eventData.preOpAuthorMax)
end

local VALID_LOOT_MODES = {
    point_based = true,
    reward_pot = true,
}

local VALID_DEDUCTION_TYPES = {
    flat = true,
    percent = true,
}

-- Function to validate the LOOT_MODE_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateLootModeChangeData(eventData)
    local oldMode = eventData.oldMode
    local newMode = eventData.newMode

    if type(oldMode) ~= "string" or not VALID_LOOT_MODES[oldMode] then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid oldMode in LOOT_MODE_CHANGE: %s", tostring(oldMode))
        end
        return false
    end

    if type(newMode) ~= "string" or not VALID_LOOT_MODES[newMode] then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid newMode in LOOT_MODE_CHANGE: %s", tostring(newMode))
        end
        return false
    end

    return true
end

-- Function to validate the REWARD_POT_CONFIG_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateRewardPotConfigChangeData(eventData)
    local startingPotCopper = math.floor(tonumber(eventData.startingPotCopper) or -1)
    local deductionType = eventData.deductionType
    local deductionValue = tonumber(eventData.deductionValue)

    if startingPotCopper < 0 then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid startingPotCopper in REWARD_POT_CONFIG_CHANGE: %s", tostring(eventData.startingPotCopper))
        end
        return false
    end

    if type(deductionType) ~= "string" or not VALID_DEDUCTION_TYPES[deductionType] then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid deductionType in REWARD_POT_CONFIG_CHANGE: %s", tostring(deductionType))
        end
        return false
    end

    if not deductionValue or deductionValue < 0 then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid deductionValue in REWARD_POT_CONFIG_CHANGE: %s", tostring(eventData.deductionValue))
        end
        return false
    end

    return true
end

-- Function to validate the REWARD_POT_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @param POINT_CHANGE_TYPES (table) - Increment/decrement constants
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateRewardPotChangeData(eventData, POINT_CHANGE_TYPES)
    local changeType = eventData.change
    local amount = math.floor(tonumber(eventData.amount) or 0)

    if changeType ~= POINT_CHANGE_TYPES.INCREMENT and changeType ~= POINT_CHANGE_TYPES.DECREMENT then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid reward pot change type: %s", tostring(changeType))
        end
        return false
    end

    if amount <= 0 then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid reward pot change amount: %s", tostring(eventData.amount))
        end
        return false
    end

    return true
end

-- Function to validate the ATTENDANCE_CHANGE event data
-- @param eventData (table) - Event data to validate
-- @param POINT_CHANGE_TYPES (table) - Increment/decrement constants
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateAttendanceChangeData(eventData, POINT_CHANGE_TYPES, profile)
    local memberID = eventData.member
    local changeType = eventData.change
    local amount = eventData.amount

    if not LootLogValidators.MemberExistsInProfiles(memberID, profile) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Attendance change log references non-existent member: %s", tostring(memberID))
        end
        return false
    end

    if changeType ~= POINT_CHANGE_TYPES.INCREMENT and changeType ~= POINT_CHANGE_TYPES.DECREMENT then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid attendance change type in log for member %s: %s", tostring(memberID), tostring(changeType))
        end
        return false
    end

    if amount ~= nil then
        amount = tonumber(amount)
        if not amount or amount <= 0 then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Invalid attendance change amount in log for member %s: %s", tostring(memberID), tostring(eventData.amount))
            end
            return false
        end
    end

    return true
end

-- Function to validate RC_LOOT_COUNCIL event data
-- @param eventData (table) - Event data to validate
-- @return (boolean) - True if valid, false otherwise
function LootLogValidators.ValidateRCLootCouncilData(eventData)
    if type(eventData) ~= "table" then
        return false
    end

    if type(eventData.member) ~= "string" or eventData.member == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "RC Loot Council log is missing member")
        end
        return false
    end
    if type(eventData.itemLink) ~= "string" or eventData.itemLink == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "RC Loot Council log is missing itemLink")
        end
        return false
    end
    if type(eventData.response) ~= "string" or eventData.response == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "RC Loot Council log is missing response")
        end
        return false
    end
    if type(eventData.rcAwardId) ~= "string" or eventData.rcAwardId == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "RC Loot Council log is missing rcAwardId")
        end
        return false
    end
    if type(eventData.awardKey) ~= "string" or eventData.awardKey == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "RC Loot Council log is missing awardKey")
        end
        return false
    end

    return true
end

local _ValidateArmorChangeData = LootLogValidators.ValidateArmorChangeData
function LootLogValidators.ValidateArmorChangeData(eventData, ARMOR_ACTIONS, profile)
    if not _ValidateArmorChangeData(eventData, ARMOR_ACTIONS, profile) then
        return false
    end
    return ValidatePreOpAuthorMax(eventData and eventData.preOpAuthorMax)
end

local function RequirePreOpAuthorMax(eventData)
    if type(eventData) ~= "table" or eventData.preOpAuthorMax == nil then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "preOpAuthorMax is required")
        end
        return false
    end
    return ValidatePreOpAuthorMax(eventData.preOpAuthorMax)
end

local function ValidateSourceLogId(value, fieldName)
    if type(value) ~= "string" or value == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "%s must be a non-empty string", tostring(fieldName or "sourceLogId"))
        end
        return false
    end
    return true
end

function LootLogValidators.ValidateSpecChangeData(eventData, profile)
    if type(eventData) ~= "table" then
        return false
    end
    if not ValidateStoredNameRealmField(eventData.member, "SPEC_CHANGE.member") then
        return false
    end
    if not LootLogValidators.MemberExistsInProfiles(eventData.member, profile) then
        return false
    end
    local specId = tonumber(eventData.specId)
    if not specId or specId < 1 or specId ~= math.floor(specId) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "SPEC_CHANGE specId is invalid: %s", tostring(eventData.specId))
        end
        return false
    end
    local SpecWeapons = SF.LootHelperBis and SF.LootHelperBis.SpecWeapons
    if not (SpecWeapons and SpecWeapons.IsKnownSpec and SpecWeapons.IsKnownSpec(specId)) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "SPEC_CHANGE specId is not a supported Retail specialization: %s", tostring(specId))
        end
        return false
    end
    local member = profile and profile.getMemberByID and profile:getMemberByID(eventData.member)
    local classToken = member and member.GetClass and member:GetClass()
    if type(classToken) ~= "string" or classToken == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "SPEC_CHANGE member class is unknown")
        end
        return false
    end
    if not (SpecWeapons.IsSpecValidForClass and SpecWeapons.IsSpecValidForClass(specId, classToken)) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "SPEC_CHANGE specId %s does not belong to class %s", tostring(specId), tostring(classToken))
        end
        return false
    end
    return RequirePreOpAuthorMax(eventData)
end

function LootLogValidators.ValidateBisOutcomeData(eventData, profile)
    if type(eventData) ~= "table" then
        return false
    end
    if SF.LootHelperBis and SF.LootHelperBis.IsOutcomeSchemaValid then
        if not SF.LootHelperBis.IsOutcomeSchemaValid(eventData) then
            return false
        end
    end
    if not ValidateStoredNameRealmField(eventData.awardMember, "BIS_OUTCOME.awardMember") then
        return false
    end
    if not LootLogValidators.MemberExistsInProfiles(eventData.awardMember, profile) then
        return false
    end
    return RequirePreOpAuthorMax(eventData)
end

local function ValidateAssignmentScopeMembers(value)
    if type(value) ~= "table" or #value == 0 then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "assignmentScopeMembers must be a non-empty list")
        end
        return false
    end
    for i = 1, #value do
        if not ValidateStoredNameRealmField(value[i], "assignmentScopeMembers") then
            return false
        end
    end
    return true
end

local function SourceLogIdsContains(eventData, needle)
    if type(needle) ~= "string" or needle == "" then
        return false
    end
    local list = eventData and eventData.sourceLogIds
    if type(list) ~= "table" then
        return false
    end
    for i = 1, #list do
        if list[i] == needle then
            return true
        end
    end
    return false
end

function LootLogValidators.ValidateBisOverrideData(eventData, profile)
    if type(eventData) ~= "table" then
        return false
    end
    local actions = SF.LootLogBisOverrideActions or {}
    local action = eventData.action
    if action ~= actions.ASSIGN and action ~= actions.CLEAR
        and action ~= actions.REPLACE and action ~= actions.ASSOCIATE_LEGACY then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "BIS_OVERRIDE action is invalid: %s", tostring(action))
        end
        return false
    end
    if not RequirePreOpAuthorMax(eventData) then
        return false
    end
    if eventData.viewMember ~= nil and not ValidateStoredNameRealmField(eventData.viewMember, "BIS_OVERRIDE.viewMember") then
        return false
    end
    if action == actions.CLEAR then
        if not ValidateSourceLogId(eventData.targetAssignmentId, "targetAssignmentId") then
            return false
        end
        if eventData.assignedSlots ~= nil then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "CLEAR must target an assignment id, not slots")
            end
            return false
        end
        return true
    end
    if action == actions.REPLACE then
        if not ValidateSourceLogId(eventData.targetAssignmentId, "targetAssignmentId") then
            return false
        end
    end
    local ref = eventData.awardRef
    if type(ref) ~= "table" or (ref.kind ~= "RC" and ref.kind ~= "MANUAL")
        or type(ref.id) ~= "string" or ref.id == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "BIS_OVERRIDE awardRef is invalid")
        end
        return false
    end
    if not ValidateSourceLogId(eventData.sourceLogId, "sourceLogId") then
        return false
    end
    if eventData.sourceLogId ~= ref.id then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "BIS_OVERRIDE sourceLogId must equal awardRef.id")
        end
        return false
    end
    if not ValidateAssignmentScopeMembers(eventData.assignmentScopeMembers) then
        return false
    end
    if action == actions.ASSIGN or action == actions.REPLACE then
        local binding = eventData.slotBinding
        if binding ~= "PACKABLE" and binding ~= "BOUND" then
            return false
        end
        local slotsValid = SF.LootHelperBis and SF.LootHelperBis.IsLegalSlotShape
            and SF.LootHelperBis.IsLegalSlotShape(eventData.assignedSlots)
        if not slotsValid then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "BIS_OVERRIDE assignedSlots shape is invalid")
            end
            return false
        end
    end
    if action == actions.ASSOCIATE_LEGACY then
        if not ValidateSourceLogId(eventData.legacyOriginLogId, "legacyOriginLogId") then
            return false
        end
        if not SourceLogIdsContains(eventData, eventData.legacyOriginLogId) then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "ASSOCIATE_LEGACY sourceLogIds must contain legacyOriginLogId")
            end
            return false
        end
        if eventData.assignedSlots ~= nil then
            local slotsValid = SF.LootHelperBis and SF.LootHelperBis.IsLegalSlotShape
                and SF.LootHelperBis.IsLegalSlotShape(eventData.assignedSlots)
            if not slotsValid then
                if SF.Debug then
                    SF.Debug:Warn("LOOTLOG", "ASSOCIATE_LEGACY assignedSlots shape is invalid")
                end
                return false
            end
        end
    end
    return true
end

function LootLogValidators.ValidateManualAwardData(eventData, profile)
    if type(eventData) ~= "table" then
        return false
    end
    if not ValidateStoredNameRealmField(eventData.member, "MANUAL_AWARD.member") then
        return false
    end
    if not LootLogValidators.MemberExistsInProfiles(eventData.member, profile) then
        return false
    end
    if type(eventData.itemLink) ~= "string" or eventData.itemLink == "" then
        return false
    end
    if type(eventData.itemString) ~= "string" or eventData.itemString == "" then
        return false
    end
    return RequirePreOpAuthorMax(eventData)
end

function LootLogValidators.ValidateManualAwardReverseData(eventData, profile)
    if type(eventData) ~= "table" then
        return false
    end
    if not ValidateSourceLogId(eventData.sourceLogId, "sourceLogId") then
        return false
    end
    return RequirePreOpAuthorMax(eventData)
end

-- Export to namespace
SF.LootLogValidators = LootLogValidators
