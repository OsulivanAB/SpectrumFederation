-- Grab the namespace
local addonName, SF = ...

-- ============================================================================
-- Loot Profile
-- ============================================================================

local LootProfile = {}
LootProfile.__index = LootProfile

-- Local helper: generate a short, very-low-collision profileId
-- We use multiple random 31-bit chunks + server time.
-- math.random is backed by WoW's securerandom RNG in modern clients.
-- @return string profileId
local function GenerateProfileId()
    local time = GetServerTime() or time()
    local ran1 = math.random(0, 0x7fffffff)
    local ran2 = math.random(0, 0x7fffffff)
    -- Format: "p_" prefix + three 8-digit zero-padded hex values (time + 2 random numbers)
    return ("p_%08x%08x%08x"):format(time, ran1, ran2)
end

-- ========================================================================
-- Identity + Counters (FOUNDATION)
-- ========================================================================

-- Function: Return stable profileId for this profile
-- @param none
-- @return string profileId
function LootProfile:GetProfileId()
    return self._profileId
end

-- Function: Set profileId if it is currently nil (useful for imports/migrations)
-- @param string profileId Stable profile identifier
-- @return nil
function LootProfile:SetProfileIdIfNil(profileId)
    if self._profileId ~= nil then
        return  
    end

    if type(profileId) ~= "string" or profileId == "" then
        if SF.Debug then
            SF.Debug("LootProfile", "SetProfileIdIfNil called with invalid profileId:", profileId)
        end
        return
    end

    self._profileId = profileId
end

-- Function: allocate and return the next counter for a given author (used when creating new logs locally).
-- IMPORTANT: This is per-profile, per-author. That's what prevents multi-writer collissions.
-- @param author string "Name-Realm" of author
-- @return number nextCounter
function LootProfile:AllocateNextCounter(author)
    if type(author) ~= "string" or author == "" then
        if SF.Debug then
            SF.Debug("LootProfile", "AllocateNextCounter called with invalid author:", author)
        end
        return nil
    end

    self._authorCounters = self._authorCounters or {}
    local nextCounter = (self._authorCounters[author] or 0) + 1
    self._authorCounters[author] = nextCounter
    return nextCounter
end

-- ========================================================================
-- Constructor
-- ========================================================================

-- Constructor for creating a new loot profile
-- @param profileName string Human-readable name for this profile
-- @return LootProfile instance or nil if failed
function LootProfile.new(profileName)
    -- Validate profile Name
    if type(profileName) ~= "string" or profileName == "" then
        if SF.Debug then
            SF.Debug("LootProfile", "Invalid profile name provided: %s", tostring(profileName))
        end
        return nil
    end

    local instance = setmetatable({}, LootProfile)

    instance._profileName = profileName
    instance._profileId = GenerateProfileId()
    instance._author = SF:GetPlayerFullIdentifier() -- "Name-Realm" of creator
    instance._owner = instance._author -- Initially owned by creator
    instance._lootLogs = {}
    instance._members = {}
    instance._adminUsers = {}
    instance._activeProfile = false
    instance._authorCounters = {}

    -- Create member instance for author
    local class = SF:GetPlayerClass()
    local authorMember = SF.LootProfileMember.new(instance._author, class or "UNKNOWN")
    if not authorMember then
        if SF.Debug then
            SF.Debug("LootProfile", "Failed to create member instance for author:", instance._author)
        end
        return nil
    end

    table.insert(instance._members, authorMember)
    table.insert(instance._adminUsers, instance._author)


    -- Create Log Entry for profile creation
    local logEventType = SF.LootLogEventTypes.PROFILE_CREATION
    local logEventData = SF.LootLog.GetEventDataTempalte(logEventType)
    if not logEventData then
        if SF.Debug then
            SF.Debug("LootProfile", "Failed to get log event data template for profile creation")
        end
        return nil
    end

    -- Put profileId into the creation log so profile identity is log-backed
    logEventData.profileId = instance._profileId

    local creationCounter = instance:AllocateNextCounter(instance._author)
    local logEntry = SF.LootLog.new(logEventType, logEventData, {
        author = instance._author,
        counter = creationCounter,
        skipPermission = true, -- creation is special; no activeProfile yet
    })

    if not logEntry then
        if SF.Debug then
            SF.Debug("LootProfile", "Failed to create log entry for profile creation")
        end
        return nil
    end

    table.insert(instance._lootLogs, logEntry)

    return instance
end

-- ========================================================================
-- Getter Methods
-- ========================================================================

-- Function to get creation time by finding the PROFILE_CREATION log
-- @return number Creation timestamp or nil if not found
function LootProfile:GetCreationTime()
    for _, logEntry in ipairs(self._lootLogs) do
        if logEntry.eventType == SF.LootLogEventTypes.PROFILE_CREATION then
            return logEntry.timestamp
        end
    end
    return nil
end

-- Function to get the profile's human-readable name
-- @return string profileName
function LootProfile:GetProfileName()
    return self._profileName
end

-- Function to check if this profile is the active profile
-- @return boolean isActive
function LootProfile:IsActive()
    return self._activeProfile
end

-- Function to get the profile's author ("Name-Realm")
-- @return string author
function LootProfile:GetAuthor()
    return self._author
end

-- Function to get the profile's owner ("Name-Realm")
-- @return string owner
function LootProfile:GetOwner()
    return self._owner
end

-- Function to get the list of members in this profile
-- @return table members List of LootProfileMember instances
function LootProfile:GetMemberList()
    return self._members
end

-- Function to get the list of loot logs in this profile
-- @return table lootLogs List of LootLog instances
function LootProfile:GetLootLogs()
    return self._lootLogs
end

-- Function to get the list of admin users in this profile
-- @return table adminUsers List of "Name-Realm" strings
function LootProfile:GetAdminUsers()
    return self._adminUsers
end

-- Function to get the last modified time of the profile by checking all log entries
-- @return number latest timestamp or nil if no logs
function LootProfile:GetLastModifiedTime()
    local latestTime = nil
    for _, logEntry in ipairs(self._lootLogs) do
        if not latestTime or logEntry.timestamp > latestTime then
            latestTime = logEntry.timestamp
        end
    end
    return latestTime
end

-- Function to check if the current user is an admin of this profile
-- @return boolean isAdmin
function LootProfile:IsCurrentUserAdmin()
    local currentUser = SF:GetPlayerFullIdentifier()
    for _, admin in ipairs(self._adminUsers) do
        if admin == currentUser then
            return true
        end
    end
    return false
end

-- ========================================================================
-- Setter Methods
-- ========================================================================

-- Function to set this profile as active or inactive
-- @param boolean isActive
-- @return nil
function LootProfile:SetActive(isActive)
    self._activeProfile = isActive
end

-- Function to set a new profile name
-- @param string newName New human-readable name for this profile
-- @return nil
function LootProfile:SetProfileName(newName)
    if type(newName) == "string" and newName ~= "" then
        self._profileName = newName
    else
        if SF.Debug then
            SF.Debug("LootProfile", "Attempted to set invalid profile name: %s", tostring(newName))
        end
    end
end

-- Function to set a new owner for this profile
-- @param string newOwner "Name-Realm" of new owner
-- @return nil
function LootProfile:SetOwner(newOwner)
    if type(newOwner) == "string" and newOwner:match("^[^%-]+%-[^%-]+$") then
        self._owner = newOwner
    else
        if SF.Debug then
            SF.Debug("LootProfile", "Attempted to set invalid owner: %s", tostring(newOwner))
        end
    end
end

-- Function to add a loot log entry to this profile
-- @param LootLog lootLog Instance of LootLog to add
-- @return boolean success
function LootProfile:AddLootLog(lootLog)
    if not self:IsCurrentUserAdmin() then
        if SF.Debug then
            SF.Debug("LootProfile", "Current user is not an admin; cannot add loot log entries")
        end
        return false
    end

    if getmetatable(lootLog) == SF.LootLog then
        table.insert(self._lootLogs, lootLog)
        table.sort(self._lootLogs, function(a, b) return a:GetTimestamp() < b:GetTimestamp() end)
        return true
    else
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to add invalid loot log instance: %s", tostring(lootLog))
        end
        return false
    end
end

-- Function to add a member to this profile
-- @param LootProfileMember member Instance of LootProfileMember to add
-- @return boolean success
function LootProfile:AddMember(member)
    if getmetatable(member) == SF.LootProfileMember then
        table.insert(self._members, member)
        return true
    else
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to add invalid LootProfileMember instance: %s", tostring(member))
        end
        return false
    end
end

-- Function to add an admin user to this profile
-- @param LootProfileMember member Instance of LootProfileMember to add as admin
-- @return boolean success
function LootProfile:AddAdminUser(member)
    if getmetatable(member) == SF.LootProfileMember then
        table.insert(self._adminUsers, member:GetFullIdentifier())
        return true
    else
        if SF.Debug then
            SF.Debug:Warn("LootProfile", "Attempted to add invalid LootProfileMember instance as admin: %s", tostring(member))
        end
        return false
    end
end

-- ========================================================================
-- Export to Namespace
-- ========================================================================
SF.LootProfile = LootProfile