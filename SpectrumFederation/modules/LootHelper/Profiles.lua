-- Grab the namespace
local addonName, SF = ...

-- ============================================================================
-- Loot Profile
-- ============================================================================

local LootProfile = {}
LootProfile.__index = LootProfile

local PROFILE_META_VERSION = 1
local PROFILE_SNAPSHOT_VERSION = 1

local function CopyArray(arr)
    local out = {}
    for i = 1, #(arr or {}) do out[i] = arr[i] end
    return out
end

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
    local logEventData = SF.LootLog.GetEventDataTemplate(logEventType)
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

-- Function Compute max counter per author found in this profile's logs.
-- This is the sync summary: { [author] = maxCounterSeen }
-- @param none
-- @return table authorMaxCounters
function LootProfile:ComputeAuthorMax()
    local authorMax = {}

    for _, log in ipairs(self._lootLogs or {}) do
        local author = log.GetAuthor and log:GetAuthor() or log._author
        local counter = log.GetCounter and log:GetCounter() or log._counter

        if type(author) == "string" and type(counter) == "number" then
            local prev = authorMax[author] or 0
            if counter > prev then
                authorMax[author] = counter
            end
        end
    end

    return authorMax
end

-- Function Compute number of logs per author (debug only; not used for sync decisions)
-- @param none
-- @return table counts { [author] = numberOfLogs }
function LootProfile:ComputeAuthorCounts()
    local counts = {}

    for _, log in ipairs(self._lootLogs or {}) do
        local author = log.GetAuthor and log:GetAuthor() or log._author

        if type(author) == "string" then
            counts[author] = (counts[author] or 0) + 1
        end
    end

    return counts
end

-- Function Rebuild log index and refresh max counters from the current log list
-- @param none
-- @return nil
function LootProfile:RebuildLogIndex()
    self._logIndex = {}
    self._authorCounters = self._authorCounters or {}

    for _, log in ipairs(self._lootLogs or {}) do
        local id = log.GetID and log:GetID() or log._id
        if type(id) == "string" and id ~= "" then
            self._logIndex[id] = true
        end

        local author = log.GetAuthor and log:GetAuthor() or log._author
        local counter = log.GetCounter and log:GetCounter() or log._counter
        if type(author) == "string" and type(counter) == "number" then
            local prev = self._authorCounters[author] or 0
            if counter > prev then
                self._authorCounters[author] = counter
            end
        end
    end
end

-- Function Compare two logs for stable deterministic ordering
-- Primary key: timestamp
-- Tie-breaks: author, counter, id
-- @param a LootLog instance A
-- @param b LootLog instance B
-- @return boolean true if a < b
function LootProfile:_CompareLogs(a, b)
    local aTime = a.GetTimestamp and a:GetTimestamp() or a._timestamp
    local bTime = b.GetTimestamp and b:GetTimestamp() or b._timestamp
    if aTime ~= bTime then
        return aTime < bTime
    end

    local aAuthor = a.GetAuthor and a:GetAuthor() or a._author
    local bAuthor = b.GetAuthor and b:GetAuthor() or b._author
    if aAuthor ~= bAuthor then
        return aAuthor < bAuthor
    end

    local aCounter = a.GetCounter and a:GetCounter() or a._counter
    local bCounter = b.GetCounter and b:GetCounter() or b._counter
    if aCounter ~= bCounter then
        return aCounter < bCounter
    end

    local aId = a.GetID and a:GetID() or a._id
    local bId = b.GetID and b:GetID() or b._id
    return aId < bId
end

-- ========================================================================
-- Getter Methods
-- ========================================================================

-- Function to get creation time by finding the PROFILE_CREATION log
-- @return number Creation timestamp or nil if not found
function LootProfile:GetCreationTime()
    for _, logEntry in ipairs(self._lootLogs or {}) do
        if logEntry:GetEventType() == SF.LootLogEventTypes.PROFILE_CREATION then
            return logEntry:GetTimestamp()
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
    for _, logEntry in ipairs(self._lootLogs or {}) do
        local ts = logEntry:GetTimestamp()
        if not latestTime or ts > latestTime then
            latestTime = ts
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
    return self:_InsertLog(lootLog, { requireAdmin = true })
end

-- Function Insert a log entry with dedupe + stable ordering
-- opts.requireAdmin: if true, enforce current user admin check (local writes).
-- @param lootLog LootLog instance to insert
-- @param opts table|nil optional:
--     opts.requireAdmin boolean enforce admin check (default: true)
-- @return boolean inserted True if new, false if duplicate/invalid
function LootProfile:_InsertLog(lootLog, opts)
    opts = opts or {}

    if getmetatable(lootLog) ~= SF.LootLog then
        if SF.Debug then
            SF.Debug("LootProfile", "_InsertLog: Invalid LootLog instance provided:", tostring(lootLog))
        end
        return false
    end

    if opts.requireAdmin and not self:IsCurrentUserAdmin() then
        if SF.Debug then
            SF.Debug("LootProfile", "_InsertLog: Current user is not an admin; cannot add loot log entries")
        end
        return false
    end

    self._lootLogs = self._lootLogs or {}
    self._logIndex = self._logIndex or {}
    self._authorCounters = self._authorCounters or {}

    local id = lootLog:GetID()
    if type(id) ~= "string" or id == "" then
        return false
    end

    -- Dedupe
    if self._logIndex[id] then
        return false
    end

    self._logIndex[id] = true
    table.insert(self._lootLogs, lootLog)
    
    -- Keep authorCoutners synced to max seen
    local author = lootLog:GetAuthor()
    local counter = lootLog:GetCounter()
    if type(author) == "string" and type(counter) == "number" then
        local prev = self._authorCounters[author] or 0
        if counter > prev then
            self._authorCounters[author] = counter
        end
    end

    table.sort(self._lootLogs, function(a, b)
        return self:_CompareLogs(a, b)
    end)

    return true
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
-- Exports and Imports
-- ========================================================================

-- Function Export profile header/meta as a network-safe table
function LootProfile:ExportMeta()
    return {
        version         = PROFILE_META_VERSION,
        _profileId      = self._profileId,
        _profileName    = self._profileName,
        _author         = self._author,
        _owner          = self._owner,
    }
end

-- Function Export a full profile snapshot (meta + admins + logs) as a network-safe table
-- @param none
-- @return table snapshot
function LootProfile:ExportSnapshot()
    local logsOut = {}
    for i, log in ipairs(self._lootLogs or {}) do
        logsOut[i] = log:ToTable()
    end

    return {
        version         = PROFILE_SNAPSHOT_VERSION,
        meta            = self:ExportMeta(),
        adminUsers      = CopyArray(self._adminUsers),
        lootLogs       = logsOut,
    }
end

-- Function Validate profile meta table (structural)
-- @param table meta Profile meta table to validate
-- @return boolean ok
-- @return string|nil errMsg
function LootProfile.ValidateMeta(meta)
    if type(meta) ~= "table" then return false, "Meta is not a table" end
    if meta.version  ~= PROFILE_META_VERSION then
        return false, ("Unsupported meta version %s"):format(tostring(meta.version))
    end

    if type(meta._profileId) ~= "string" or meta._profileId == "" then return false, "Invalid or missing _profileId" end
    if type(meta._profileName) ~= "string" or meta._profileName == "" then return false, "Invalid or missing _profileName" end
    if type(meta._author) ~= "string" or meta._author == "" then return false, "Invalid or missing _author" end
    if type(meta._owner) ~= "string" or meta._owner == "" then return false, "Invalid or missing _owner" end

    return true, nil
end

-- Function Validate snapshot table (structural)
-- @param table snapshot Profile snapshot table to validate
-- @return boolean ok
-- @return string|nil errMsg
function LootProfile.ValidateSnapshot(snapshot)
    if type(snapshot) ~= "table" then return false, "Snapshot is not a table" end
    if snapshot.version ~= PROFILE_SNAPSHOT_VERSION then
        return false, ("Unsupported snapshot version %s"):format(tostring(snapshot.version))
    end

    local ok, err = LootProfile.ValidateMeta(snapshot.meta)
    if not ok then return false, ("Invalid meta in snapshot: %s"):format(err) end

    if type(snapshot.adminUsers) ~= "table" then return false, "Invalid or missing adminUsers" end
    for i, admin in ipairs(snapshot.adminUsers) do
        if type(admin) ~= "string" or admin == "" then
            return false, ("snapshot.adminUsers[%d] is invalid"):format(i)
        end
    end

    if type(snapshot.lootLogs) ~= "table" then return false, "snapshot.logs must be a table" end

    return true, nil
end

-- Function Import a snapshot into this profile instance
-- Behavior:
--  - If self has no profileId yet, adopt snapshot meta.
--  - If self has a different profileId, reject.
--  - Replace adminUsers with snapshot adminUsers (authoritative list for now)
--  - Merge logs idempotently (dedupe by logId).
-- @param table snapshot Profile snapshot table
-- @param opts table|nil optional:
--     opts.allowUnknownEventType boolean (default true)
-- @return boolean success
-- @return number insertedLogs Number of logs newly inserted
-- @return string|nil errMsg
function LootProfile:ImportSnapshot(snapshot, opts)
    local success, err = LootProfile.ValidateSnapshot(snapshot)
    if not success then return false, 0, err end

    local meta = snapshot.meta

    -- Adopt or validate identity
    if not self._profileId then
        self._profileId = meta._profileId
    elseif self._profileId ~= meta._profileId then
        return false, 0, "Snapshot profileId does not match existing profileId"
    end

    -- Update label/ownership fields (these are not the identity)
    self._profileName   = meta._profileName
    self._author        = meta._author
    self._owner         = meta._owner

    -- Replace admin list (later we may derive this from logs; for now keep it explicit)
    self._adminUsers = CopyArray(snapshot.adminUsers)

    -- Merge Logs
    local inserted = self:MergeLogTables(snapshot.lootLogs, opts)

    return true, inserted, nil
end

-- Function Merge a list of LootLog wire tables into this profile
-- Dedupe by logId; stable sort at the end; update logIndex + authorCounters.
-- @param logTables table array of LootLog wire tables
-- @param opts table|nil passed to LootLog.FromTable/ValidateTable
-- @return number insertedLogs Number of logs newly inserted
function LootProfile:MergeLogTables(logTables, opts)
    if type(logTables) ~= "table" then return 0 end

    self._lootLogs = self._lootLogs or {}
    self._logIndex = self._logIndex or {}
    self._authorCounters = self._authorCounters or {}

    local inserted = 0
    local dirtySort = false

    for _, t in ipairs(logTables) do
        local log, err = SF.LootLog.FromTable(t, opts)
        if log then
            local id = log:GetID()
            if not self._logIndex[id] then
                self._logIndex[id] = true
                table.insert(self._lootLogs, log)
                inserted = inserted + 1
                dirtySort = true

                -- Keep authorCoutners synced to max seen
                local author = log:GetAuthor()
                local counter = log:GetCounter()
                if type(author) == "string" and type(counter) == "number" then
                    local prev = self._authorCounters[author] or 0
                    if counter > prev then
                        self._authorCounters[author] = counter
                    end
                end
            end
        else
            if SF.Debug then
                SF.Debug:Warn("LootProfile", "Skipping invalid log table: %s", tostring(err))
            end
        end
    end

    if dirtySort then
        table.sort(self._lootLogs, function(a, b) return self:_CompareLogs(a, b) end)
    end

    return inserted
end

-- ========================================================================
-- Export to Namespace
-- ========================================================================
SF.LootProfile = LootProfile