-- Grab the namespace
local addonName, SF = ...

-- Simple counter for unique log IDs (resets each session)
local logCounter = 0

local EVENT_TYPES = {
    PROFILE_CREATION = "PROFILE_CREATION",
    POINT_CHANGE = "POINT_CHANGE",
    ARMOR_CHANGE = "ARMOR_CHANGE",
    ROLE_CHANGE = "ROLE_CHANGE"
}

local POINT_CHANGE_TYPES = {
    INCREMENT = "INCREMENT",
    DECREMENT = "DECREMENT"
}

local ARMOR_ACTIONS = {
    USED = "USED",
    AVAILABLE = "AVAILABLE"
}

local EVENT_DATA_TEMPLATES = {
    [EVENT_TYPES.PROFILE_CREATION] = {
        -- No additional data needed
    },
    [EVENT_TYPES.POINT_CHANGE] = {
        member = "", -- Member full identifier "Name-Realm"
        change = "" -- SF.LootLogPointChangeTypes constant
    },
    [EVENT_TYPES.ARMOR_CHANGE] = {
        member = "", -- Member full identifier "Name-Realm"
        slot = "",   -- SF.ArmorSlots constant
        action = ""  -- SF.LootLogArmorActions constant
    },
    [EVENT_TYPES.ROLE_CHANGE] = {
        member = "", -- Member full identifier "Name-Realm"
        newRole = "" -- SF.MemberRoles constant (ADMIN or MEMBER)
    }
}

-- Local function to hash variables into an ID
-- @param timestamp (number) - Timestamp of the event
-- @param author (string) - Author of the event
-- @param eventType (string) - Type of event
-- @param counter (number) - Session-unique counter for this log
-- @return (string) - Hashed ID
local function GenerateLogID(timestamp, author, eventType, counter)
    return tostring(timestamp) .. "_" .. author .. "_" .. eventType .. "_" .. tostring(counter)
end

-- Function to get the timestamp in the Loot Profile's timezone
-- @return (number) - Timestamp adjusted to profile's timezone
local function GetProfileTimestamp()
    -- TODO: Implement timezone adjustment based on profile settings
    return time()
end

-- Class definition
local LootLog = {}
LootLog.__index = LootLog

-- Constructor for creating a new log entry
-- @param eventType (string) - Type of event being logged
-- @param eventData (table) - Data specific to the event type
-- @return LootLog instance or nil if failed
function LootLog.new(eventType, eventData)
    -- TODO: Enforce admin permissions
    
    -- Validate eventType is an option in EVENT_TYPES
    if not EVENT_TYPES[eventType] then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid event type provided: %s", tostring(eventType))
        end
        return nil
    end

    -- Validate that eventData matches expected template
    local template = EVENT_DATA_TEMPLATES[eventType]
    for key, _ in pairs(template) do
        if eventData[key] == nil then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Missing event data key '%s' for event type '%s'", tostring(key), tostring(eventType))
            end
            return nil
        end
    end    

    -- Additional validation based on event type (BEFORE creating instance)
    if eventType == EVENT_TYPES.POINT_CHANGE then
        if not SF.LootLogValidators.ValidatePointChangeData(eventData, POINT_CHANGE_TYPES) then
            return nil
        end
    elseif eventType == EVENT_TYPES.ARMOR_CHANGE then
        if not SF.LootLogValidators.ValidateArmorChangeData(eventData, ARMOR_ACTIONS) then
            return nil
        end
    elseif eventType == EVENT_TYPES.ROLE_CHANGE then
        if not SF.LootLogValidators.ValidateRoleChangeData(eventData) then
            return nil
        end
    end
    
    -- NOW create instance after all validation passes
    local instance = setmetatable({}, LootLog)
    
    -- TODO: This timestamp should use the server time for the owner of the profile.
    local timestamp = GetProfileTimestamp()  -- Log creation time
    local author = SF:GetPlayerFullIdentifier()  -- Author in "Name-Realm" format
    
    -- Increment counter for unique ID
    logCounter = logCounter + 1
    
    instance.timestamp = timestamp
    instance.author = author
    instance.eventType = eventType
    instance.data = eventData
    instance.id = GenerateLogID(timestamp, author, eventType, logCounter)
    
    -- Debug logging
    if SF.Debug then
        SF.Debug:Verbose("LOOTLOG", "Created log %s: %s", instance.id, eventType)
    end
    
    return instance
end

-- Constructor for creating a log entry from serialized data
-- Used for synchronizing logs across clients
-- @param serializedData (string) - Base64-encoded CBOR string from GetSerializedData()
-- @return LootLog instance or nil if deserialization failed
function LootLog.newFromSerialized(serializedData)
    -- Validate input
    if type(serializedData) ~= "string" or serializedData == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid serialized data provided: expected non-empty string")
        end
        return nil
    end
    
    -- Decode Base64
    local decodedData = C_EncodingUtil.DecodeBase64(serializedData)
    if not decodedData then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Failed to decode Base64 data")
        end
        return nil
    end
    
    -- Deserialize CBOR
    local success, logData = pcall(C_EncodingUtil.DeserializeCBOR, decodedData)
    if not success or not logData then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Failed to deserialize CBOR data: %s", tostring(logData))
        end
        return nil
    end
    
    -- Validate version
    if logData.version ~= 1 then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Unsupported log format version: %s (expected 1)", tostring(logData.version))
        end
        return nil
    end
    
    -- Validate required fields
    if not logData.id or not logData.timestamp or not logData.author or 
       not logData.eventType or not logData.data then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Missing required fields in serialized log data")
        end
        return nil
    end
    
    -- Create instance with exact deserialized values (no validation, no counter increment)
    local instance = setmetatable({}, LootLog)
    instance.id = logData.id
    instance.timestamp = logData.timestamp
    instance.author = logData.author
    instance.eventType = logData.eventType
    instance.data = logData.data
    
    -- Debug logging
    if SF.Debug then
        SF.Debug:Verbose("LOOTLOG", "Deserialized log %s: %s", instance.id, instance.eventType)
    end
    
    return instance
end

-- Get a copy of the event data template for a specific event type
-- @param eventType (string) - Event type constant
-- @return (table) - Empty template table (copy) or nil if invalid
function LootLog.GetEventDataTemplate(eventType)
    if not EVENT_DATA_TEMPLATES[eventType] then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Unknown event type for template: %s", tostring(eventType))
        end
        return nil
    end
    
    -- Return a copy of the template to prevent corruption
    local template = {}
    for key, value in pairs(EVENT_DATA_TEMPLATES[eventType]) do
        template[key] = value
    end
    return template
end

-- ============================================================================
-- Getter Methods
-- ============================================================================

-- Getter function for log ID
-- @return (string) - Unique log ID
function LootLog:GetID()
    return self.id
end

-- Getter function for timestamp
-- @return (number) - Timestamp of log creation
function LootLog:GetTimestamp()
    return self.timestamp
end

-- Getter function for author
-- @return (string) - Author of the log in "Name-Realm" format
function LootLog:GetAuthor()
    return self.author
end

-- Getter function for event type
-- @return (string) - Event type of the log
function LootLog:GetEventType()
    return self.eventType
end

-- Getter function for event data
-- @return (table) - Event data table
function LootLog:GetEventData()
    return self.data
end

-- Getter function for serialized log data
-- Returns a Base64-encoded CBOR string suitable for addon communication
-- @return (string) - Serialized log data, or nil if serialization failed
function LootLog:GetSerializedData()
    -- Create serialization table with version for future compatibility
    local serializationData = {
        version = 1,
        id = self.id,
        timestamp = self.timestamp,
        author = self.author,
        eventType = self.eventType,
        data = self.data
    }
    
    -- Serialize to CBOR
    local success, cborData = pcall(C_EncodingUtil.SerializeCBOR, serializationData)
    if not success or not cborData then
        if SF.Debug then
            SF.Debug:Error("LOOTLOG", "Failed to serialize log %s to CBOR: %s", self.id, tostring(cborData))
        end
        return nil
    end
    
    -- Encode to Base64
    local encodedData = C_EncodingUtil.EncodeBase64(cborData)
    if not encodedData then
        if SF.Debug then
            SF.Debug:Error("LOOTLOG", "Failed to encode log %s to Base64", self.id)
        end
        return nil
    end
    
    return encodedData
end

-- ============================================================================
-- Export to Namespace
-- ============================================================================

-- Export to namespace
SF.LootLog = LootLog
SF.LootLogEventTypes = EVENT_TYPES
SF.LootLogPointChangeTypes = POINT_CHANGE_TYPES
SF.LootLogArmorActions = ARMOR_ACTIONS