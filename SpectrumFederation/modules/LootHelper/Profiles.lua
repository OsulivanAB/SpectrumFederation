-- Grab the namespace
local addonName, SF = ...

-- Class definition
local LootProfile = {}
LootProfile.__index = LootProfile

-- Constructor for creating a new loot profile
-- @param profileName (string) - Name of the loot profile
-- @return LootProfile instance or nil if failed
function LootProfile.new(profileName)

    -- Validate Profile Name
    if type(profileName) ~= "string" or profileName == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTPROFILE", "Invalid profile name provided: %s", tostring(profileName))
        end
        return nil
    end

    -- Create Log Entry for profile creation
    local logEventType = SF.LootLogEventTypes.PROFILE_CREATION
    local logEventData = SF.LootLog.GetEventDataTemplate(PROFILE_CREATION)  -- Empty template but just to be safe
    local logEntry = SF.LootLog.new(logEventType, logEventData)
    if not logEntry then
        if SF.Debug then
            SF.Debug:Warn("LOOTPROFILE", "Failed to create profile creation log entry for profile: %s", tostring(profileName))
        end
        return nil
    end

    -- Create member instance for author
    local name, realm = SF:GetPlayerInfo()
    local class = SF:GetPlayerClass()
    local authorMember = SF.LootProfileMember.new(name, realm, SF.LootProfileMemberRoles.ADMIN, class)
    if not authorMember then
        if SF.Debug then
            SF.Debug:Warn("LOOTPROFILE", "Failed to create author member for profile: %s", tostring(profileName))
        end
        return nil
    end

    local instance = setmetatable({}, LootProfile)
    instance._profileName = profileName
    instance._author = SF:GetPlayerFullIdentifier()  -- Author in "Name-Realm" format
    instance._owner = SF:GetPlayerFullIdentifier()  -- Owner in "Name-Realm" format
    instance._lootLogs = {}
    instance._members = {}
    instance._adminUsers = {}
    instance._activeProfile = false

    table.insert(instance._lootLogs, logEntry)
    table.insert(instance._members, authorMember)
    table.insert(instance._adminUsers, authorMember:GetFullIdentifier())    -- Add author as admin user

    return instance
end

-- ============================================================================
-- Getter Methods
-- ============================================================================

-- function to get creation time by finding the SF.LootLogEventTypes.PROFILE_CREATION log
-- @return (number) - Creation timestamp or nil if not found
function LootProfile:GetCreationTime()
    for _, logEntry in ipairs(self._lootLogs) do
        if logEntry.eventType == SF.LootLogEventTypes.PROFILE_CREATION then
            return logEntry.timestamp
        end
    end
    return nil
end

-- function to get profile name
-- @return (string) - Profile name
function LootProfile:GetProfileName()
    return self._profileName
end

-- function to check if profile is active
-- @return (boolean) - True if active, false otherwise
function LootProfile:IsActive()
    return self._activeProfile
end

-- function to get author
-- @return (string) - Author identifier
function LootProfile:GetAuthor()
    return self._author
end

-- function to get owner
-- @return (string) - Owner identifier
function LootProfile:GetOwner()
    return self._owner
end

-- function to get last modified timestamp by finding the most recent log entry
-- @return (number) - Last modified timestamp or nil if no logs
function LootProfile:GetLastModifiedTime()
    local latestTime = nil
    for _, logEntry in ipairs(self._lootLogs) do
        if not latestTime or logEntry.timestamp > latestTime then
            latestTime = logEntry.timestamp
        end
    end
    return latestTime
end

-- Check if current user is an admin of the profile
-- @return (boolean) - True if current user is admin, false otherwise
function LootProfile:IsCurrentUserAdmin()
    local currentUser = SF:GetPlayerFullIdentifier()
    for _, admin in ipairs(self._adminUsers) do
        if admin == currentUser then
            return true
        end
    end
    return false
end

-- Get a list of members names
-- @return (table) - List of member full identifiers "Name-Realm"
function LootProfile:GetMemberList()
    local memberList = {}
    for _, member in ipairs(self._members) do
        table.insert(memberList, member:GetFullIdentifier())
    end
    return memberList
end

-- Get the loot logs array
-- @return (table) - Array of LootLog instances
function LootProfile:GetLootLogs()
    return self._lootLogs
end

-- ============================================================================
-- Setter Methods
-- ============================================================================

-- function to set profile as active or inactive
-- @param isActive (boolean) - True to set active, false to set inactive
function LootProfile:SetActive(isActive)
    self._activeProfile = isActive
end

-- function to set profile name
-- @param newName (string) - New profile name
function LootProfile:SetProfileName(newName)
    if type(newName) == "string" and newName ~= "" then
        self._profileName = newName
    else
        if SF.Debug then
            SF.Debug:Warn("LOOTPROFILE", "Attempted to set invalid profile name: %s", tostring(newName))
        end
    end
end

-- function to set the owner of the profile
-- @param newOwner (string) - New owner identifier in "Name-Realm" format
function LootProfile:SetOwner(newOwner)
    -- Validate new Owner format and is a real player name
    if type(newOwner) == "string" and newOwner:match("^[^%-]+%-[^%-]+$") then
        self._owner = newOwner
    else
        if SF.Debug then
            SF.Debug:Warn("LOOTPROFILE", "Attempted to set invalid owner identifier: %s", tostring(newOwner))
        end
    end
end

-- function to add a loot log entry to the profile
-- @param lootLog (LootLog) - LootLog instance to add
-- @return (boolean) - True if added successfully, false otherwise
function LootProfile:AddLootLog(lootLog)

    -- Enforce Admin Permissions
    if not self:IsCurrentUserAdmin() then
        if SF.Debug then
            SF.Debug:Warn("LOOTPROFILE", "Current user is not an admin; cannot add loot log entries")
        end
        return false
    end

    if getmetatable(lootLog) == SF.LootLog then
        table.insert(self._lootLogs, lootLog)
        
        -- Sort logs by timestamp after insertion to maintain chronological order
        table.sort(self._lootLogs, function(a, b)
            return a:GetTimestamp() < b:GetTimestamp()
        end)
        
        return true
    else
        if SF.Debug then
            SF.Debug:Warn("LOOTPROFILE", "Attempted to add invalid LootLog instance: %s", tostring(lootLog))
        end
        return false
    end
end

-- Add a member to the members list
-- @param member (LootProfileMember) - Instance of LootProfileMember to add
-- @return (boolean) - true if added successfully, false otherwise
function LootProfile:AddMember(member)
    if getmetatable(member) == SF.LootProfileMember then
        table.insert(self._members, member)
        return true
    else
        if SF.Debug then
            SF.Debug:Warn("LOOTPROFILE", "Attempted to add invalid LootProfileMember instance: %s", tostring(member))
        end
        return false
    end
end

-- Add an admin user to the admin users list
-- @param member (LootProfileMember) - Instance of LootProfileMember to add
-- @return (boolean) - true if added successfully, false otherwise
function LootProfile:AddAdminUser(member)
    if getmetatable(member) == SF.LootProfileMember then
        table.insert(self._adminUsers, member:GetFullIdentifier())
        return true
    else
        if SF.Debug then
            SF.Debug:Warn("LOOTPROFILE", "Attempted to add invalid LootProfileMember instance as admin: %s", tostring(member))
        end
        return false
    end
end

-- ============================================================================
-- Export to Namespace
-- ============================================================================
SF.LootProfile = LootProfile