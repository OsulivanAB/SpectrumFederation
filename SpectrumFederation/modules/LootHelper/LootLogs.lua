-- Grab the namespace
local addonName, SF = ...

local EVENT_TYPES = {
    PROFILE_CREATION = "PROFILE_CREATION",
    POINT_CHANGE = "POINT_CHANGE",
    ARMOR_CHANGE = "ARMOR_CHANGE"
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
    }
}

-- Class definition
local LootLog = {}
LootLog.__index = LootLog

-- Constructor
-- @param eventType (string) - Type of event being logged
-- @return LootLog instance or nil if failed
function LootLog.new(eventType, eventData)
    -- TODO: Enforce admin permissions
    local instance = setmetatable({}, LootLog)

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
    
    -- TODO: This timestamp should use the server time for the owner of the profile.
    instance.timestamp = os.time()  -- Log creation time
    instance.author = SF:GetPlayerFullIdentifier()  -- Author in "Name-Realm" format
    instance.eventType = eventType
    instance.data = eventData
    
    return instance
end

-- Export to namespace
SF.LootLog = LootLog
SF.LootLogEventTypes = EVENT_TYPES
SF.LootLogPointChangeTypes = POINT_CHANGE_TYPES
SF.LootLogArmorActions = ARMOR_ACTIONS

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