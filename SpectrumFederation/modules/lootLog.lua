local addonName, ns = ...

-- Local reference to LootLog module
local LootLog = ns.LootLog or {}
ns.LootLog = LootLog

-- AppendEntry: Adds a new log entry to the current tier's logs
-- @param entryTable: Table containing entry data (actor, target, delta, newTotal, reason)
-- @return: Boolean success status, entry ID if successful
function LootLog:AppendEntry(entryTable)
    if not ns.Core then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append entry - Core module not available")
        end
        return false, nil
    end
    
    local tierData = ns.Core:GetCurrentTierData()
    if not tierData then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append entry - tier data not available")
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
    
    -- Merge in ID, timestamp, and tier information
    local entry = {
        id = tierData.nextLogId,
        timestamp = time(),
        actor = entryTable.actor,
        target = entryTable.target,
        delta = entryTable.delta or 0,
        newTotal = entryTable.newTotal or 0,
        reason = entryTable.reason or "Unknown",
        tier = ns.db.currentTier
    }
    
    -- Save to database
    tierData.logs[tierData.nextLogId] = entry
    tierData.nextLogId = tierData.nextLogId + 1
    
    -- Debug logging
    if ns.Debug then
        ns.Debug:Info("LOOT_LOG", 
            "Log entry #%d: %s → %s, delta: %+d, new total: %d, reason: %s",
            entry.id, entry.actor, entry.target, entry.delta, entry.newTotal, entry.reason)
    end
    
    return true, entry.id
end

-- GetEntriesForTier: Retrieves all log entries for a specific tier
-- @param tierKey: The tier key (e.g., "0.0.0", "11.0.0")
-- @return: Array of log entries sorted by ID, or empty table if tier doesn't exist
function LootLog:GetEntriesForTier(tierKey)
    if not ns.db or not ns.db.tiers then
        if ns.Debug then
            ns.Debug:Warn("LOOT_LOG", "Cannot get entries - database not initialized")
        end
        return {}
    end
    
    local tierData = ns.db.tiers[tierKey]
    if not tierData or not tierData.logs then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No logs found for tier: %s", tierKey)
        end
        return {}
    end
    
    -- Convert to sorted array
    local entries = {}
    for id, entry in pairs(tierData.logs) do
        table.insert(entries, entry)
    end
    
    -- Sort by ID
    table.sort(entries, function(a, b)
        return a.id < b.id
    end)
    
    if ns.Debug then
        ns.Debug:Verbose("LOOT_LOG", "Retrieved %d log entries for tier: %s", #entries, tierKey)
    end
    
    return entries
end

-- GetAllEntries: Retrieves all log entries for the current tier
-- @return: Array of log entries sorted by ID
function LootLog:GetAllEntries()
    if not ns.db or not ns.db.currentTier then
        return {}
    end
    
    return self:GetEntriesForTier(ns.db.currentTier)
end

-- GetLatestTimestampForTier: Find the maximum timestamp in a tier's logs
-- @param tierKey: The tier key (e.g., "0.0.14"). If nil, uses current tier
-- @return: Maximum timestamp found, or 0 if no logs exist
function LootLog:GetLatestTimestampForTier(tierKey)
    -- Use current tier if not specified
    local tier = tierKey
    if not tier then
        if ns.db and ns.db.currentTier then
            tier = ns.db.currentTier
        else
            if ns.Debug then
                ns.Debug:Warn("LOOT_LOG", "Cannot get latest timestamp - no tier specified and no current tier")
            end
            return 0
        end
    end
    
    -- Get tier data
    if not ns.db or not ns.db.tiers then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No tiers available for timestamp lookup")
        end
        return 0
    end
    
    local tierData = ns.db.tiers[tier]
    if not tierData or not tierData.logs then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No logs in tier %s for timestamp lookup", tier)
        end
        return 0
    end
    
    -- Walk through all logs to find maximum timestamp
    local maxTimestamp = 0
    local entryCount = 0
    
    for id, entry in pairs(tierData.logs) do
        entryCount = entryCount + 1
        if entry.timestamp and entry.timestamp > maxTimestamp then
            maxTimestamp = entry.timestamp
        end
    end
    
    if ns.Debug then
        ns.Debug:Verbose("LOOT_LOG", "Latest timestamp for tier %s: %d (from %d entries)", 
            tier, maxTimestamp, entryCount)
    end
    
    return maxTimestamp
end

-- HasLogEntryId: Check if a log entry with the given ID exists in the current tier
-- @param id: The log entry ID to check
-- @return: Boolean indicating whether the entry exists
function LootLog:HasLogEntryId(id)
    if not id then
        return false
    end
    
    if not ns.Core then
        return false
    end
    
    local tierData = ns.Core:GetCurrentTierData()
    if not tierData or not tierData.logs then
        return false
    end
    
    -- Check if entry exists
    local exists = tierData.logs[id] ~= nil
    
    if ns.Debug and exists then
        ns.Debug:Verbose("LOOT_LOG", "Log entry ID %d exists in current tier", id)
    end
    
    return exists
end

-- GetEntriesNewerThan: Get all log entries with timestamp greater than the specified value
-- @param tierKey: The tier key (e.g., "0.0.14"). If nil, uses current tier
-- @param timestamp: The timestamp threshold
-- @return: Array of log entries with timestamp > threshold
function LootLog:GetEntriesNewerThan(tierKey, timestamp)
    if not timestamp then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot get newer entries - timestamp not specified")
        end
        return {}
    end
    
    -- Use current tier if not specified
    local tier = tierKey
    if not tier then
        if ns.db and ns.db.currentTier then
            tier = ns.db.currentTier
        else
            if ns.Debug then
                ns.Debug:Warn("LOOT_LOG", "Cannot get newer entries - no tier specified and no current tier")
            end
            return {}
        end
    end
    
    -- Get tier data
    if not ns.db or not ns.db.tiers then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No tiers available for entry lookup")
        end
        return {}
    end
    
    local tierData = ns.db.tiers[tier]
    if not tierData or not tierData.logs then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "No logs in tier %s for entry lookup", tier)
        end
        return {}
    end
    
    -- Collect entries newer than the threshold
    local newerEntries = {}
    for id, entry in pairs(tierData.logs) do
        if entry.timestamp and entry.timestamp > timestamp then
            table.insert(newerEntries, entry)
        end
    end
    
    if ns.Debug then
        ns.Debug:Verbose("LOOT_LOG", "Found %d entries newer than timestamp %d in tier %s", 
            #newerEntries, timestamp, tier)
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
    
    -- Validate entry has required fields
    if not entry.timestamp or not entry.actor or not entry.target 
       or not entry.delta or not entry.newTotal or not entry.reason or not entry.tier then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append - entry missing required fields (id: %s)", 
                tostring(entry.id))
        end
        return "error"
    end
    
    -- Check if entry already exists using HasLogEntryId
    if self:HasLogEntryId(entry.id) then
        if ns.Debug then
            ns.Debug:Verbose("LOOT_LOG", "Skipping entry ID %s - already exists", tostring(entry.id))
        end
        return "skipped"
    end
    
    -- Get tier data for the entry's tier
    if not ns.db or not ns.db.tiers then
        if ns.Debug then
            ns.Debug:Error("LOOT_LOG", "Cannot append - database not initialized")
        end
        return "error"
    end
    
    -- Ensure tier exists in database
    if not ns.db.tiers[entry.tier] then
        if ns.Debug then
            ns.Debug:Warn("LOOT_LOG", "Tier %s does not exist - creating it", entry.tier)
        end
        ns.db.tiers[entry.tier] = {
            points = {},
            logs = {},
            nextLogId = 1
        }
    end
    
    local tierData = ns.db.tiers[entry.tier]
    
    -- Insert the entry into the tier's logs
    tierData.logs[entry.id] = entry
    
    -- Update nextLogId if necessary (ensure it's always higher than any existing ID)
    if entry.id >= tierData.nextLogId then
        tierData.nextLogId = entry.id + 1
    end
    
    if ns.Debug then
        ns.Debug:Info("LOOT_LOG", 
            "Appended entry ID %s from sync: %s → %s, delta: %+d, new total: %d, tier: %s",
            tostring(entry.id), entry.actor, entry.target, entry.delta, entry.newTotal, entry.tier)
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
