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
        return nil
    end

    local decoded = C_EncodingUtil.DecodeBase64(serializedData)
    if not decoded then return nil end

    local ok, t = pcall(C_EncodingUtil.DeserializeCBOR, decoded)
    if not ok or type(t) ~= "table" then return nil end

    local log, err = LootLog.FromTable(t, { allowUnknownEventType = true })
    if not log and SF.Debug then
        SF.Debug:Warn("LOOTLOG", "FromTable failed: %s", tostring(err))
    end

    return log
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
    local t = self:ToTable()

    local ok, cborData = pcall(C_EncodingUtil.SerializeCBOR, t)
    if not ok or not cborData then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "SerializeCBOR failed for %s", tostring(self._id))
        end
        return nil
    end

    local encoded = C_EncodingUtil.EncodeBase64(cborData)
    if not encoded then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "EncodeBase64 failed for %s", tostring(self._id))
        end
        return nil
    end

    return encoded
end

-- Function Convert this log to a network-safe plain table.
-- Goal: single source of truth for wire format.
-- @param none
-- @return table logTable Plain table representation of the log
function LootLog:ToTable()
    return {
        version     = LOG_FORMAT_VERSION,
        _id         = self._id,
        _timestamp  = self._timestamp,
        _author     = self._author,
        _counter    = self._counter,
        _eventType  = self._eventType,
        _data       = self._data
    }
end

-- Function Validate a log wire table (structural validation).
-- @param t table logTable Plain table representation of the log
-- @param opts table|nil optional:
--     opts.allowUnknownEventType boolean (defaul true)
-- @return boolean ok
-- @return string|nil errMsg
function LootLog.ValidateTable(t, opts)
    opts = opts or {}
    local allowUnknown  = (opts.allowUnknownEventType ~= false)

    if type(t) ~= "table" then return false, "log is not a table" end
    if type(t.version) ~= "number" then return false, "log.version must be a number" end
    if t.version ~= LOG_FORMAT_VERSION then
        return false, ("unsupported log version %s (expected %s)"):format(tostring(t.version), tostring(LOG_FORMAT_VERSION))
    end
    if type(t._id) ~= "string" or t._id == "" then return false, "log._id must be a non-empty string" end
    if type(t._timestamp) ~= "number" then return false, "log._timestamp must be a number" end
    if type(t._author) ~= "string" or t._author == "" then return false, "log._author must be a non-empty string" end
    if type(t._counter) ~= "number" or t._counter < 1 or t._counter ~= math.floor(t._counter) then
        return false, "log._counter must be a positive integer"
    end
    if type(t._eventType) ~= "string" or t._eventType == "" then
        return false, "log._eventType must be a non-empty string"
    end
    if type(t._data) ~= "table" then return false, "log._data must be a table" end

    -- Integrity check: id must match author:counter
    local expectedId = ("%s:%d"):format(t._author, t._counter)
    if t._id ~= expectedId then
        return false, ("log._id mismatch (expected %s, got %s)"):format(expectedId, tostring(t._id))
    end

    -- Semantic enforcement (off by default for forward compatibility)
    if not allowUnknown  then
        if not EVENT_TYPES[t._eventType] then
            return false, ("unknown event type %s"):format(tostring(t._eventType))
        end
    end

    return true, nil
end

-- Function Create a LootLog instance from a wire table.
-- @param t table logTable Plain table representation of the log
-- @param opts table|nil optional:
--     opts.allowUnknownEventType boolean (defaul true)
-- @return LootLog|nil instance
-- @return string|nil errMsg
function LootLog.FromTable(t, opts)
    local ok, errMsg = LootLog.ValidateTable(t, opts)
    if not ok then return nil, errMsg end

    -- Build without permission checks since this is deserialization/import
    local instance = setmetatable({}, LootLog)
    instance._id        = t._id
    instance._timestamp = t._timestamp
    instance._author    = t._author
    instance._counter   = t._counter
    instance._eventType = t._eventType
    instance._data      = t._data

    return instance, nil
end

-- ============================================================================
-- Export to Namespace
-- ============================================================================
SF.LootLog = LootLog
SF.LootLogEventTypes = EVENT_TYPES
SF.LootLogPointChangeTypes = POINT_CHANGE_TYPES
SF.LootLogArmorActions = ARMOR_ACTIONS