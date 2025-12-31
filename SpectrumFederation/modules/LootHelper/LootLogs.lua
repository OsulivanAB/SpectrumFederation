-- Grab the namespace
local addonName, SF = ...

-- ============================================================================
-- LootLog
-- ============================================================================

local LOG_FORMAT_VERSION = 2

local EVENT_TYPES = {
    PROFILE_CREATION    = "PROFILE_CREATION",
    POINT_CHANGE        = "POINT_CHANGE",
    ARMOR_CHANGE        = "ARMOR_CHANGE",
    ROLE_CHANGE         = "ROLE_CHANGE"
}

local POINT_CHANGE_TYPES = {
    INCREMENT   = "INCREMENT",
    DECREMENT   = "DECREMENT"
}

local ARMOR_ACTIONS = {
    USED        = "USED",
    AVAILABLE   = "AVAILABLE"
}

local EVENT_DATA_TEMPLATES = {
    [EVENT_TYPES.PROFILE_CREATION] = {
        profileId = ""
    },
    [EVENT_TYPES.POINT_CHANGE] = {
        member = "", -- "Name-Realm"
        change = "" -- INCREMENT/DECREMENT
    },
    [EVENT_TYPES.ARMOR_CHANGE] = {
        member  = "",
        slot    = "",
        action  = ""
    },
    [EVENT_TYPES.ROLE_CHANGE] = {
        member  = "",
        newRole = ""
    }
}

-- Generates a unique log ID based on author and a counter
-- @param author string Author of the log
-- @param counter number Counter to ensure uniqueness
-- @return string logID Unique log ID
local function GenerateLogID(author, counter)
    return ("%s:%d"):format(author, counter)
end

local LootLog = {}
LootLog.__index = LootLog

-- Constructor for creating a new log entry
-- @param eventType string Type of event (from EVENT_TYPES)
-- @param eventData table Data associated with the event
-- @param opts table|nil optional:
--     opts.author string override author (used for imports / special cases)
--     opts.counter number override counter (used for imports / special cases)
--     opts.timestamp number override timestamp (used for imports)
--     opts.skipPermission boolean bypass admin check (used for profile creation/import)
-- @return LootLog instance or nil if failed
function LootLog.new(eventType, eventData, opts)
    opts = opts or {}

    -- Permission enforcement
    if not opts.skipPermission then
        local ap = SF.lootHelperDB and SF.lootHelperDB.activeProfile
        if not ap or not ap.IsCurrentUserAdmin then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Active profile missing or IsCurrentUserAdmin not found; cannot create log entry")
            end
            return nil
        elseif not ap:IsCurrentUserAdmin() then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Current user is not an admin; cannot create log entry")
            end
            return nil
        end
    end

    -- Validate event type
    if not EVENT_TYPES[eventType] then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid event type provided: %s", tostring(eventType))
        end
        return nil
    end

    -- Validate eventData keys
    local template = EVENT_DATA_TEMPLATES[eventType]
    for key, _ in pairs(template) do
        if eventData[key] == nil then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Missing event data key '%s' for event type '%s'", tostring(key), tostring(eventType))
            end
            return nil
        end
    end

    -- Additional validation based on event type
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

    local timestamp = opts.timestamp or GetServerTime()
    local author = opts.author or SF:GetPlayerFullIdentifier()

    -- Counter allocation: must be per-profile per-author to avoid collisions.
    local counter = opts.counter
    if type(counter) ~= "number" then
        local ap = SF.lootHelperDB and SF.lootHelperDB.activeProfile
        if ap and ap.AllocateNextCounter then
            counter = ap:AllocateNextCounter(author)
        end
    end

    if type(counter) ~= "number" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "No counter available. Pass opts.counter or ensure active profile supports AllocateNextCounter().")
        end
        return nil
    end

    local instance = setmetatable({}, LootLog)
    instance._timestamp = timestamp
    instance._author = author
    instance._counter = counter
    instance._eventType = eventType
    instance._data = eventData
    instance._id = GenerateLogID(author, counter)

    if SF.Debug then
        SF.Debug:Verbose("LOOTLOG", "Created log %s: %s", instance._id, instance._eventType)
    end

    return instance
end

-- Constructor for creating a log entry from serialized data
-- @param serializedData string Base64 encoded CBOR serialized log data
-- @return LootLog instance or nil if failed
function LootLog.newFromSerialized(serializedData)
    if type(serializedData) ~= "string" or serializedData == "" then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Invalid serialized data provided: expected non-empty string")
        end
        return nil
    end

    local decodedData = C_EncodingUtil.DecodeBase64(serializedData)
    if not decodedData then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Failed to decode Base64 data")
        end
        return nil
    end

    local success, logData = pcall(C_EncodingUtil.DeserializeCBOR, decodedData)
    if not success or not logData then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Failed to deserialize CBOR data: %s", tostring(logData))
        end
        return nil
    end

    if logData.version ~= LOG_FORMAT_VERSION then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Unsupported log format version: %s", tostring(logData.version))
        end
        return nil
    end

    if not logData._id or not logData._timestamp or not logData._author or not logData._counter
       or not logData._eventType or not logData._data then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Missing required fields in serialized log data")
        end
        return nil
    end

    local instance = setmetatable({}, LootLog)
    instance._id = logData._id
    instance._timestamp = logData._timestamp
    instance._author = logData._author
    instance._counter = logData._counter
    instance._eventType = logData._eventType
    instance._data = logData._data

    if SF.Debug then 
        SF.Debug:Verbose("LOOTLOG", "Deserialized log %s: %s", instance._id, instance._eventType)
    end

    return instance
end

-- ============================================================================
-- Getter Methods
-- ============================================================================

-- Functionn to get event data template for a given event type
-- @param eventType string Type of event (from EVENT_TYPES)
-- @return table|nil event data template or nil if unknown event type
function LootLog.GetEventDataTemplate(eventType)
    if not EVENT_DATA_TEMPLATES[eventType] then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Unknown event type for template: %s", tostring(eventType))
        end
        return nil
    end

    local template = {}
    for key, value in pairs(EVENT_DATA_TEMPLATES[eventType]) do
        template[key] = value
    end
    return template
end

-- Function to get the Unique ID of this log entry
-- @return string log ID
function LootLog:GetID()
    return self._id
end

-- Function to get the timestamp of this log entry
-- @return number timestamp
function LootLog:GetTimestamp()
    return self._timestamp
end

-- Function to get the author of this log entry
-- @return string author
function LootLog:GetAuthor()
    return self._author
end

-- Function to get the counter of this log entry
-- @return number counter
function LootLog:GetCounter()
    return self._counter
end

-- Function to get the event type of this log entry
-- @return string event type
function LootLog:GetEventType()
    return self._eventType
end

-- Function to get the event data of this log entry
-- @return table event data
function LootLog:GetEventData()
    return self._data
end

-- Function to serialize this log entry to a Base64 encoded CBOR string
-- @return string|nil serialized data or nil if failed
function LootLog:GetSerializedData()
    local serializationData = {
        version    = LOG_FORMAT_VERSION,
        _id         = self._id,
        _timestamp  = self._timestamp,
        _author     = self._author,
        _counter    = self._counter,
        _eventType  = self._eventType,
        _data       = self._data
    }

    local success, cborData = pcall(C_EncodingUtil.SerializeCBOR, serializationData)
    if not success or not cborData then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Failed to serialize log %s to CBOR: %s", self._id, tostring(cborData))
        end
        return nil
    end

    local encodedData = C_EncodingUtil.EncodeBase64(cborData)
    if not encodedData then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Failed to encode log %s to Base64", tostring(self._id))
        end
        return nil
    end

    return encodedData
end

-- ============================================================================
-- Export to Namespace
-- ============================================================================
SF.LootLog = LootLog
SF.LootLogEventTypes = EVENT_TYPES
SF.LootLogPointChangeTypes = POINT_CHANGE_TYPES
SF.LootLogArmorActions = ARMOR_ACTIONS