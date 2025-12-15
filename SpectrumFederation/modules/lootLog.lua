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
