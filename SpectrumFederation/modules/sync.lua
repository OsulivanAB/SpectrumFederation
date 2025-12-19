local addonName, ns = ...

-- Local reference to Sync module
local Sync = ns.Sync or {}
ns.Sync = Sync

-- Addon message prefix for communication (max 16 characters)
local ADDON_PREFIX = "SpecFed"

-- Message types for sync communication
-- SYNC_REQUEST: Request logs from other addon users. Includes the requester's latest timestamp
--               so others can send only newer entries. Also serves as a "handshake" when joining groups.
-- SYNC_RESPONSE: Response to a sync request containing log entries the requester is missing.
--                Sent via WHISPER to the specific requester to avoid channel spam.
-- LOG_ENTRY: Broadcast a single new log entry to the group/raid when a local change occurs.
--            Allows real-time synchronization of point changes while grouped.
local MSG_TYPE = {
    SYNC_REQUEST  = "SYNC_REQ",   -- "Tell me what I'm missing"
    SYNC_RESPONSE = "SYNC_RESP",  -- "Here are the entries you're missing"
    LOG_ENTRY     = "LOG",        -- "Here is a single new log entry"
}

-- Attach message types to module for external access if needed
Sync.MSG_TYPE = MSG_TYPE

-- Initialize: Set up the sync module
-- Called on PLAYER_LOGIN
function Sync:Initialize()
    if ns.Debug then
        ns.Debug:Info("SYNC", "Sync module initializing")
    end
    
    -- Register addon message prefix for communication
    local success = C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
    if success then
        self.isRegistered = true
        if ns.Debug then
            ns.Debug:Info("SYNC", "Successfully registered addon prefix: %s", ADDON_PREFIX)
        end
    else
        self.isRegistered = false
        if ns.Debug then
            ns.Debug:Error("SYNC", "Failed to register addon prefix: %s", ADDON_PREFIX)
        end
    end
    
    if ns.Debug then
        ns.Debug:Info("SYNC", "Sync module initialized (registered: %s)", tostring(self.isRegistered))
    end
end

-- OnPointsChanged: Handle local point changes
-- Called when a local log entry is created
-- @param logEntry: The log entry that was just created
function Sync:OnPointsChanged(logEntry)
    if not logEntry then
        if ns.Debug then
            ns.Debug:Error("SYNC", "OnPointsChanged called with nil logEntry")
        end
        return
    end
    
    if ns.Debug then
        ns.Debug:Verbose("SYNC", "Points changed for %s, delta: %d", 
            logEntry.target or "unknown", logEntry.delta or 0)
    end
    
    -- Check if we should broadcast this change
    if self:IsRegistered() and self:GetGroupChannel() then
        self:SendLogUpdate(logEntry)
    end
end

-- GetGroupChannel: Determine the appropriate channel for group/raid communication
-- @return: "RAID", "PARTY", or nil if not in a group
function Sync:GetGroupChannel()
    -- Validate WoW API functions are available
    if not IsInRaid or not IsInGroup then
        if ns.Debug then
            ns.Debug:Error("SYNC", "WoW group API functions not available")
        end
        return nil
    end
    
    if IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    else
        return nil
    end
end

-- SendLogUpdate: Broadcast a single log entry to the group/raid
-- @param logEntry: The log entry to broadcast
function Sync:SendLogUpdate(logEntry)
    -- Check if sync is ready
    if not self:IsRegistered() then
        if ns.Debug then
            ns.Debug:Verbose("SYNC", "Cannot send log update - not registered")
        end
        return
    end
    
    -- Check if in a group
    local channel = self:GetGroupChannel()
    if not channel then
        if ns.Debug then
            ns.Debug:Verbose("SYNC", "Cannot send log update - not in a group")
        end
        return
    end
    
    -- Serialize the log entry
    local serialized = self:SerializeLogEntry(logEntry)
    if not serialized then
        if ns.Debug then
            ns.Debug:Error("SYNC", "Failed to serialize log entry for broadcast")
        end
        return
    end
    
    -- Build the message
    local message = MSG_TYPE.LOG_ENTRY .. "\t" .. serialized
    
    -- Send the message
    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, message, channel)
    
    if ns.Debug then
        ns.Debug:Info("SYNC", "Broadcast log update to %s: entry ID %s for %s", 
            channel, tostring(logEntry.id), logEntry.target)
    end
end

-- SendSyncRequest: Request logs from other addon users in the group
-- Sends our latest timestamp so others can send only newer entries
function Sync:SendSyncRequest()
    -- Check if sync is ready
    if not self:IsRegistered() then
        if ns.Debug then
            ns.Debug:Verbose("SYNC", "Cannot send sync request - not registered")
        end
        return
    end
    
    -- Check if in a group
    local channel = self:GetGroupChannel()
    if not channel then
        if ns.Debug then
            ns.Debug:Verbose("SYNC", "Cannot send sync request - not in a group")
        end
        return
    end
    
    -- Get current profile
    local profileName = "Default"
    if ns.Core then
        profileName = ns.Core:GetActiveProfileName()
    end
    
    -- Get our latest timestamp
    local latestTimestamp = 0
    if ns.LootLog then
        latestTimestamp = ns.LootLog:GetLatestTimestampForProfile(profileName)
    end
    
    -- Build the message
    local message = MSG_TYPE.SYNC_REQUEST .. "\t" .. profileName .. "\t" .. tostring(latestTimestamp)
    
    -- Send the message
    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, message, channel)
    
    if ns.Debug then
        ns.Debug:Info("SYNC", "Sent sync request to %s for profile %s (our latest: %d)", 
            channel, profileName, latestTimestamp)
    end
end

-- SerializeLogBatch: Serialize multiple log entries into a single string
-- @param entries: Array of log entry tables
-- @return: Serialized string with entries separated by newlines, or nil on error
function Sync:SerializeLogBatch(entries)
    if not entries or type(entries) ~= "table" then
        if ns.Debug then
            ns.Debug:Error("SYNC", "Cannot serialize batch - invalid entries")
        end
        return nil
    end
    
    local serializedEntries = {}
    
    for i, entry in ipairs(entries) do
        local serialized = self:SerializeLogEntry(entry)
        if serialized then
            table.insert(serializedEntries, serialized)
        else
            if ns.Debug then
                ns.Debug:Warn("SYNC", "Skipping entry %d in batch - serialization failed", i)
            end
        end
    end
    
    if #serializedEntries == 0 then
        if ns.Debug then
            ns.Debug:Warn("SYNC", "No entries serialized in batch")
        end
        return nil
    end
    
    -- Join with newline separator
    return table.concat(serializedEntries, "\n")
end

-- OnAddonMessage: Receive and dispatch addon messages
-- @param prefix: The addon message prefix
-- @param message: The message content
-- @param channel: The channel it was sent on ("PARTY", "RAID", "WHISPER", etc.)
-- @param sender: Character key of the sender
function Sync:OnAddonMessage(prefix, message, channel, sender)
    -- Check prefix matches
    if prefix ~= ADDON_PREFIX then
        return
    end
    
    -- Ignore messages from self
    if ns.Core then
        local ourKey = ns.Core:GetCharacterKey("player")
        if ourKey and sender == ourKey then
            if ns.Debug then
                ns.Debug:Verbose("SYNC", "Ignoring message from self")
            end
            return
        end
    end
    
    -- Split message into type and payload
    local msgType, rest = strsplit("\t", message, 2)
    
    if not msgType then
        if ns.Debug then
            ns.Debug:Warn("SYNC", "Received malformed message from %s", sender)
        end
        return
    end
    
    if ns.Debug then
        ns.Debug:Verbose("SYNC", "Received %s from %s via %s", msgType, sender, channel)
    end
    
    -- Dispatch to appropriate handler
    if msgType == MSG_TYPE.SYNC_REQUEST then
        self:HandleSyncRequest(sender, rest)
    elseif msgType == MSG_TYPE.SYNC_RESPONSE then
        self:HandleSyncResponse(sender, rest)
    elseif msgType == MSG_TYPE.LOG_ENTRY then
        self:HandleLogEntry(sender, rest)
    else
        if ns.Debug then
            ns.Debug:Warn("SYNC", "Unknown message type: %s from %s", msgType, sender)
        end
    end
end

-- SendSyncResponse: Send log entries to a specific player in response to their sync request
-- @param target: Character key of the requester (for WHISPER)
-- @param profileName: The profile these entries belong to
-- @param entries: Array of log entry tables to send
function Sync:SendSyncResponse(target, profileName, entries)
    if not self:IsRegistered() then
        if ns.Debug then
            ns.Debug:Verbose("SYNC", "Cannot send sync response - not registered")
        end
        return
    end
    
    if not target or not profileName or not entries then
        if ns.Debug then
            ns.Debug:Error("SYNC", "Cannot send sync response - missing required parameters")
        end
        return
    end
    
    -- Validate target is a valid character key (Name-Realm format)
    if type(target) ~= "string" or not target:match("^.+%-.+$") then
        if ns.Debug then
            ns.Debug:Error("SYNC", "Cannot send sync response - invalid target format: %s", tostring(target))
        end
        return
    end
    
    if #entries == 0 then
        if ns.Debug then
            ns.Debug:Verbose("SYNC", "No entries to send in sync response to %s", target)
        end
        return
    end
    
    -- For v1, we'll send entries in small batches to avoid hitting the 255 char limit
    -- Batch size of 3 entries should be safe for most cases
    local batchSize = 3
    local totalSent = 0
    
    for i = 1, #entries, batchSize do
        local batch = {}
        for j = i, math.min(i + batchSize - 1, #entries) do
            table.insert(batch, entries[j])
        end
        
        -- Serialize the batch
        local serialized = self:SerializeLogBatch(batch)
        if not serialized then
            if ns.Debug then
                ns.Debug:Error("SYNC", "Failed to serialize batch for sync response")
            end
            -- Continue with next batch instead of aborting
        elseif #serialized >= 255 then
            -- Batch is too large, try with smaller batches
            if ns.Debug then
                ns.Debug:Warn("SYNC", "Batch too large (%d chars), splitting further", #serialized)
            end
            -- Send one at a time for this batch
            for _, entry in ipairs(batch) do
                local singleSerialized = self:SerializeLogEntry(entry)
                if singleSerialized then
                    local singleMessage = MSG_TYPE.SYNC_RESPONSE .. "\t" .. profileName .. "\t" .. singleSerialized
                    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, singleMessage, "WHISPER", target)
                    totalSent = totalSent + 1
                end
            end
        else
            -- Build and send the message
            local message = MSG_TYPE.SYNC_RESPONSE .. "\t" .. profileName .. "\t" .. serialized
            C_ChatInfo.SendAddonMessage(ADDON_PREFIX, message, "WHISPER", target)
            totalSent = totalSent + #batch
            
            if ns.Debug then
                ns.Debug:Verbose("SYNC", "Sent batch of %d entries to %s (%d chars)", 
                    #batch, target, #message)
            end
        end
    end
    
    if ns.Debug then
        ns.Debug:Info("SYNC", "Sync response complete: sent %d entries to %s for profile %s", 
            totalSent, target, profileName)
    end
end

-- IsRegistered: Check if the addon message prefix is registered
-- @return boolean: true if registered, false otherwise
function Sync:IsRegistered()
    return self.isRegistered == true
end

-- SerializeLogEntry: Convert a log entry table into a compact string for transmission
-- @param entry: The log entry table to serialize
-- @return string: Serialized entry, or nil if serialization fails or exceeds length limit
function Sync:SerializeLogEntry(entry)
    if not entry then
        if ns.Debug then
            ns.Debug:Error("SYNC", "Cannot serialize nil entry")
        end
        return nil
    end
    
    -- Validate required fields
    if not entry.id or not entry.timestamp or not entry.actor or not entry.target 
       or not entry.delta or not entry.newTotal or not entry.reason or not entry.tier then
        if ns.Debug then
            ns.Debug:Error("SYNC", "Cannot serialize entry - missing required fields")
        end
        return nil
    end
    
    -- Escape pipe character in reason field (replace | with \p)
    local escapedReason = tostring(entry.reason):gsub("|", "\\p")
    
    -- Build serialized string: id|timestamp|actor|target|delta|newTotal|reason|tier
    local serialized = string.format("%d|%d|%s|%s|%d|%d|%s|%s",
        entry.id,
        entry.timestamp,
        entry.actor,
        entry.target,
        entry.delta,
        entry.newTotal,
        escapedReason,
        entry.tier
    )
    
    -- Check WoW addon message length limit (255 characters)
    if #serialized >= 255 then
        if ns.Debug then
            ns.Debug:Warn("SYNC", "Serialized entry exceeds 255 char limit: %d characters", #serialized)
        end
        return nil
    end
    
    return serialized
end

-- DeserializeLogEntry: Parse a serialized string back into a log entry table
-- @param dataString: The serialized entry string
-- @return table: Reconstructed log entry table, or nil if parsing fails
function Sync:DeserializeLogEntry(dataString)
    if not dataString or dataString == "" then
        if ns.Debug then
            ns.Debug:Error("SYNC", "Cannot deserialize empty or nil string")
        end
        return nil
    end
    
    -- Split by pipe character
    local parts = {}
    for part in string.gmatch(dataString, "[^|]+") do
        table.insert(parts, part)
    end
    
    -- Validate we have exactly 8 parts
    if #parts ~= 8 then
        if ns.Debug then
            ns.Debug:Error("SYNC", "Invalid serialized entry - expected 8 fields, got %d", #parts)
        end
        return nil
    end
    
    -- Reconstruct the entry table
    local entry = {
        id = tonumber(parts[1]),
        timestamp = tonumber(parts[2]),
        actor = parts[3],
        target = parts[4],
        delta = tonumber(parts[5]),
        newTotal = tonumber(parts[6]),
        reason = parts[7]:gsub("\\p", "|"),  -- Unescape pipe character
        tier = parts[8]
    }
    
    -- Validate required fields were parsed correctly
    if not entry.id or not entry.timestamp or not entry.actor or not entry.target 
       or not entry.delta or not entry.newTotal or not entry.reason or not entry.tier then
        if ns.Debug then
            ns.Debug:Error("SYNC", "Failed to parse required fields from serialized entry")
        end
        return nil
    end
    
    return entry
end

-- HandleSyncRequest: Process a sync request from another player
-- @param sender: Character key of the requester
-- @param payload: The request payload (profileName \t latestTimestamp)
function Sync:HandleSyncRequest(sender, payload)
    if not payload then
        if ns.Debug then
            ns.Debug:Warn("SYNC", "Received sync request with no payload from %s", sender)
        end
        return
    end
    
    -- Parse payload
    local profileName, timestampStr = strsplit("\t", payload, 2)
    local latestTimestamp = tonumber(timestampStr) or 0
    
    if not profileName then
        if ns.Debug then
            ns.Debug:Warn("SYNC", "Malformed sync request from %s", sender)
        end
        return
    end
    
    if ns.Debug then
        ns.Debug:Info("SYNC", "Processing sync request from %s for profile %s (their latest: %d)", 
            sender, profileName, latestTimestamp)
    end
    
    -- Get entries newer than their timestamp
    local entries = {}
    if ns.LootLog then
        entries = ns.LootLog:GetEntriesNewerThan(profileName, latestTimestamp)
    end
    
    -- Send response
    if #entries > 0 then
        self:SendSyncResponse(sender, profileName, entries)
    else
        if ns.Debug then
            ns.Debug:Info("SYNC", "No newer entries to send to %s", sender)
        end
    end
end

-- HandleSyncResponse: Process a sync response containing log entries
-- @param sender: Character key of the sender
-- @param payload: The response payload (profileName \t batchData)
function Sync:HandleSyncResponse(sender, payload)
    if not payload then
        if ns.Debug then
            ns.Debug:Warn("SYNC", "Received sync response with no payload from %s", sender)
        end
        return
    end
    
    -- Parse payload
    local profileName, batchData = strsplit("\t", payload, 2)
    
    if not profileName or not batchData then
        if ns.Debug then
            ns.Debug:Warn("SYNC", "Malformed sync response from %s", sender)
        end
        return
    end
    
    if ns.Debug then
        ns.Debug:Info("SYNC", "Processing sync response from %s for profile %s", sender, profileName)
    end
    
    -- Split batch data into individual serialized entries
    local serializedEntries = {}
    for line in string.gmatch(batchData, "[^\n]+") do
        table.insert(serializedEntries, line)
    end
    
    -- Deserialize each entry
    local entries = {}
    for i, serialized in ipairs(serializedEntries) do
        local entry = self:DeserializeLogEntry(serialized)
        if entry then
            table.insert(entries, entry)
        else
            if ns.Debug then
                ns.Debug:Warn("SYNC", "Failed to deserialize entry %d from %s", i, sender)
            end
        end
    end
    
    if #entries == 0 then
        if ns.Debug then
            ns.Debug:Warn("SYNC", "No valid entries in sync response from %s", sender)
        end
        return
    end
    
    -- Append entries to log
    local results = { added = 0, skipped = 0, errors = 0 }
    if ns.LootLog then
        results = ns.LootLog:AppendBatchIfNew(entries)
    end
    
    if ns.Debug then
        ns.Debug:Info("SYNC", "Sync response processed: %d added, %d skipped, %d errors", 
            results.added, results.skipped, results.errors)
    end
    
    -- If any entries were added, recalculate points
    if results.added > 0 then
        if ns.Core then
            ns.Core:RecalculatePointsFromLogs(profileName)
        end
        
        -- Notify UI to refresh
        if ns.UI and ns.UI.RefreshRosterList then
            ns.UI:RefreshRosterList()
        end
    end
end

-- HandleLogEntry: Process a single log entry broadcast
-- @param sender: Character key of the sender
-- @param payload: The serialized log entry
function Sync:HandleLogEntry(sender, payload)
    if not payload then
        if ns.Debug then
            ns.Debug:Warn("SYNC", "Received log entry with no payload from %s", sender)
        end
        return
    end
    
    -- Deserialize the entry
    local entry = self:DeserializeLogEntry(payload)
    if not entry then
        if ns.Debug then
            ns.Debug:Error("SYNC", "Failed to deserialize log entry from %s", sender)
        end
        return
    end
    
    if ns.Debug then
        ns.Debug:Verbose("SYNC", "Processing log entry from %s: ID %s for %s", 
            sender, tostring(entry.id), entry.target)
    end
    
    -- Append entry to log
    local status = "error"
    if ns.LootLog then
        status = ns.LootLog:AppendIfNew(entry)
    end
    
    if status == "added" then
        -- Recalculate points for this entry's profile
        if ns.Core and entry.profile then
            ns.Core:RecalculatePointsFromLogs(entry.profile)
        end
        
        -- Notify UI to refresh
        if ns.UI and ns.UI.RefreshRosterList then
            ns.UI:RefreshRosterList()
        end
        
        if ns.Debug then
            ns.Debug:Info("SYNC", "Applied log entry from %s: %s now has %d points", 
                sender, entry.target, entry.newTotal)
        end
    elseif status == "skipped" then
        if ns.Debug then
            ns.Debug:Verbose("SYNC", "Skipped duplicate log entry from %s", sender)
        end
    end
end
