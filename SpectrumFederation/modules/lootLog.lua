local addonName, ns = ...

-- Local reference to LootLog module
local LootLog = ns.LootLog or {}
ns.LootLog = LootLog

-- AppendEntry: Adds a new log entry to the current profile's logs
-- @param entryTable: Table containing entry data (actor, target, delta, newTotal, reason)
-- @return: Boolean success status, entry ID if successful
function LootLog:AppendEntry(entryTable)
    if not ns.Core then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append entry - Core module not available")
        end
        return false, nil
    end
    
    local profileData = ns.Core:GetActiveProfile()
    if not profileData then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append entry - profile data not available")
        end
        return false, nil
    end
    
    -- Ensure required fields exist
    if not entryTable.actor or not entryTable.target then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append entry - missing required fields (actor/target)")
        end
        return false, nil
    end
    
    -- Merge in ID, timestamp, and profile information
    local entry = {
        id = profileData.nextLogId,
        timestamp = time(),
        actor = entryTable.actor,
        target = entryTable.target,
        delta = entryTable.delta or 0,
        newTotal = entryTable.newTotal or 0,
        reason = entryTable.reason or "Unknown",
        profile = ns.Core:GetActiveProfileName()
    }
    
    -- Save to database
    profileData.logs[profileData.nextLogId] = entry
    profileData.nextLogId = profileData.nextLogId + 1
    
    -- Debug logging
    if ns.Debug then
        ns.Debug:Info("LOOT_LOG", 
            "Log entry #%d: %s → %s, delta: %+d, new total: %d, reason: %s",
            entry.id, entry.actor, entry.target, entry.delta, entry.newTotal, entry.reason)
    end
    
    return true, entry.id
end

-- GetEntriesForProfile: Retrieves all log entries for a specific profile
-- @param profileName: The profile name (e.g., "Default", "Raid-Team-A")
-- @return: Array of log entries sorted by ID, or empty table if profile doesn't exist
function LootLog:GetEntriesForProfile(profileName)
    if not ns.db or not ns.db.profiles then
        if ns.Debug then
            ns.Debug:Warn("LOOT_LOG", "Cannot get entries - database not initialized")
        end
        return {}
    end
    
    local profileData = ns.db.profiles[profileName]
    if not profileData or not profileData.logs then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No logs found for profile: %s", profileName)
        end
        return {}
    end
    
    -- Convert to sorted array
    local entries = {}
    for id, entry in pairs(profileData.logs) do
        table.insert(entries, entry)
    end
    
    -- Sort by ID
    table.sort(entries, function(a, b)
        return a.id < b.id
    end)
    
    if ns.Debug then
        ns.Debug:Verbose("LOOT_LOG", "Retrieved %d log entries for profile: %s", #entries, profileName)
    end
    
    return entries
end

-- GetAllEntries: Retrieves all log entries for the current profile
-- @return: Array of log entries sorted by ID
function LootLog:GetAllEntries()
    if not ns.Core then
        return {}
    end
    
    local profileName = ns.Core:GetActiveProfileName()
    return self:GetEntriesForProfile(profileName)
end

-- GetLatestTimestampForProfile: Find the maximum timestamp in a profile's logs
-- @param profileName: The profile name (e.g., "Default"). If nil, uses active profile
-- @return: Maximum timestamp found, or 0 if no logs exist
function LootLog:GetLatestTimestampForProfile(profileName)
    -- Use active profile if not specified
    local profile = profileName
    if not profile then
        if ns.Core then
            profile = ns.Core:GetActiveProfileName()
        else
            if ns.Debug then
                ns.Debug:Warn("LOOT_LOG", "Cannot get latest timestamp - no profile specified and Core not available")
            end
            return 0
        end
    end
    
    -- Get profile data
    if not ns.db or not ns.db.profiles then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No profiles available for timestamp lookup")
        end
        return 0
    end
    
    local profileData = ns.db.profiles[profile]
    if not profileData or not profileData.logs then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No logs in profile %s for timestamp lookup", profile)
        end
        return 0
    end
    
    -- Walk through all logs to find maximum timestamp
    local maxTimestamp = 0
    local entryCount = 0
    
    for id, entry in pairs(profileData.logs) do
        entryCount = entryCount + 1
        if entry.timestamp and entry.timestamp > maxTimestamp then
            maxTimestamp = entry.timestamp
        end
    end
    
    if ns.Debug then
        ns.Debug:Verbose("LOOT_LOG", "Latest timestamp for profile %s: %d (from %d entries)", 
            profile, maxTimestamp, entryCount)
    end
    
    return maxTimestamp
end

-- HasLogEntryId: Check if a log entry with the given ID exists in the current profile
-- @param id: The log entry ID to check
-- @return: Boolean indicating whether the entry exists
function LootLog:HasLogEntryId(id)
    if not id then
        return false
    end
    
    if not ns.Core then
        return false
    end
    
    local profileData = ns.Core:GetActiveProfile()
    if not profileData or not profileData.logs then
        return false
    end
    
    -- Check if entry exists
    local exists = profileData.logs[id] ~= nil
    
    if ns.Debug and exists then
        ns.Debug:Verbose("LOOT_LOG", "Log entry ID %d exists in current profile", id)
    end
    
    return exists
end

-- GetEntriesNewerThan: Get all log entries with timestamp greater than the specified value
-- @param profileName: The profile name (e.g., "Default"). If nil, uses active profile
-- @param timestamp: The timestamp threshold
-- @return: Array of log entries with timestamp > threshold
function LootLog:GetEntriesNewerThan(profileName, timestamp)
    if not timestamp then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot get newer entries - timestamp not specified")
        end
        return {}
    end
    
    -- Use active profile if not specified
    local profile = profileName
    if not profile then
        if ns.Core then
            profile = ns.Core:GetActiveProfileName()
        else
            if ns.Debug then
                ns.Debug:Warn("LOOT_LOG", "Cannot get newer entries - no profile specified and Core not available")
            end
            return {}
        end
    end
    
    -- Get profile data
    if not ns.db or not ns.db.profiles then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No profiles available for entry lookup")
        end
        return {}
    end
    
    local profileData = ns.db.profiles[profile]
    if not profileData or not profileData.logs then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No logs in profile %s for entry lookup", profile)
        end
        return {}
    end
    
    -- Collect entries newer than the threshold
    local newerEntries = {}
    for id, entry in pairs(profileData.logs) do
        if entry.timestamp and entry.timestamp > timestamp then
            table.insert(newerEntries, entry)
        end
    end
    
    if ns.Debug then
        ns.Debug:Verbose("LOOT_LOG", "Found %d entries newer than timestamp %d in profile %s", 
            #newerEntries, timestamp, profile)
    end
    
    return newerEntries
end

-- AppendIfNew: Append a log entry only if its ID doesn't already exist (deduplication)
-- This is used for merging entries received from other addon users via sync
-- @param entry: The complete log entry table to append (must include all fields)
-- @return: Status string ("added", "skipped", or "error")
function LootLog:AppendIfNew(entry)
    -- Validate entry exists
    if not entry then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append - entry is nil")
        end
        return "error"
    end
    
    -- Validate entry has an ID
    if not entry.id then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append - entry has no ID")
        end
        return "error"
    end
    
    -- Validate entry has required fields (note: support both 'tier' and 'profile' fields for migration compatibility)
    if not entry.timestamp or not entry.actor or not entry.target 
       or not entry.delta or not entry.newTotal or not entry.reason or (not entry.profile and not entry.tier) then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append - entry missing required fields (id: %s)", 
                tostring(entry.id))
        end
        return "error"
    end
    
    -- Normalize entry: if it has 'tier' field but not 'profile', use tier as profile (migration compatibility)
    if entry.tier and not entry.profile then
        entry.profile = entry.tier
    end
    
    -- Check if entry already exists using HasLogEntryId
    if self:HasLogEntryId(entry.id) then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "Skipping entry ID %s - already exists", tostring(entry.id))
        end
        return "skipped"
    end
    
    -- Get profile data for the entry's profile
    if not ns.db or not ns.db.profiles then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append - database not initialized")
        end
        return "error"
    end
    
    -- Ensure profile exists in database (create if needed for sync)
    if not ns.db.profiles[entry.profile] then
        if ns.Debug then
            ns.Debug:Warn("LOOT_LOG", "Profile %s does not exist - creating it", entry.profile)
        end
        if ns.Core then
            ns.Core:CreateProfile(entry.profile, "Sync")
        else
            -- Fallback if Core not available
            ns.db.profiles[entry.profile] = {
                points = {},
                logs = {},
                nextLogId = 1,
                createdAt = time(),
                createdBy = "Sync"
            }
        end
    end
    
    local profileData = ns.db.profiles[entry.profile]
    
    -- Insert the entry into the profile's logs
    profileData.logs[entry.id] = entry
    
    -- Update nextLogId if necessary (ensure it's always higher than any existing ID)
    if entry.id >= profileData.nextLogId then
        profileData.nextLogId = entry.id + 1
    end
    
    if ns.Debug then
        ns.Debug:Info("LOOT_LOG", 
            "Appended entry ID %s from sync: %s → %s, delta: %+d, new total: %d, profile: %s",
            tostring(entry.id), entry.actor, entry.target, entry.delta, entry.newTotal, entry.profile)
    end
    
    return "added"
end

-- AppendBatchIfNew: Append multiple log entries, deduplicating by ID
-- This is used for bulk sync operations when receiving many entries at once
-- @param entries: Array of log entry tables
-- @return: Table with counts: { added = number, skipped = number, errors = number }
function LootLog:AppendBatchIfNew(entries)
    local results = {
        added = 0,
        skipped = 0,
        errors = 0
    }
    
    if not entries then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append batch - entries is nil")
        end
        results.errors = 1
        return results
    end
    
    if type(entries) ~= "table" then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append batch - entries is not a table")
        end
        results.errors = 1
        return results
    end
    
    -- Check for empty array
    if #entries == 0 then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "Batch append called with empty entries array")
        end
        return results
    end
    
    -- Process each entry
    for i, entry in ipairs(entries) do
        local status = self:AppendIfNew(entry)
        
        if status == "added" then
            results.added = results.added + 1
        elseif status == "skipped" then
            results.skipped = results.skipped + 1
        elseif status == "error" then
            results.errors = results.errors + 1
        end
    end
    
    if ns.Debug then
        ns.Debug:Info("LOOT_LOG", 
            "Batch append complete: %d added, %d skipped, %d errors (total: %d entries)",
            results.added, results.skipped, results.errors, #entries)
    end
    
    return results
end
-- GetLogIdsForProfile: Get all log IDs for a specific profile
-- @param profileName: The profile name (e.g., "Default"). If nil, uses active profile
-- @return: Array of log IDs
function LootLog:GetLogIdsForProfile(profileName)
    -- Use active profile if not specified
    local profile = profileName
    if not profile then
        if ns.Core then
            profile = ns.Core:GetActiveProfileName()
        else
            if ns.Debug then
                ns.Debug:Warn("LOOT_LOG", "Cannot get log IDs - no profile specified and Core not available")
            end
            return {}
        end
    end
    
    -- Get profile data
    if not ns.db or not ns.db.profiles then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No profiles available for log ID lookup")
        end
        return {}
    end
    
    local profileData = ns.db.profiles[profile]
    if not profileData or not profileData.logs then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No logs in profile %s for ID lookup", profile)
        end
        return {}
    end
    
    -- Collect all log IDs
    local logIds = {}
    for id in pairs(profileData.logs) do
        table.insert(logIds, id)
    end
    
    -- Sort numerically
    table.sort(logIds)
    
    if ns.Debug then
        ns.Debug:Verbose("LOOT_LOG", "Retrieved %d log IDs for profile %s", #logIds, profile)
    end
    
    return logIds
end
