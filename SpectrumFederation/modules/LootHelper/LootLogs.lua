-- Grab the namespace
local addonName, SF = ...

-- ============================================================================
-- LootLog
-- ============================================================================

local LOG_FORMAT_VERSION = 2
local DEFAULT_POINT_CHANGE_AMOUNT = 1
local FINGERPRINT_MODULO = 2147483647

local EVENT_TYPES = {
    PROFILE_CREATION            = "PROFILE_CREATION",
    POINT_CHANGE                = "POINT_CHANGE",
    ARMOR_CHANGE                = "ARMOR_CHANGE",
    ROLE_CHANGE                 = "ROLE_CHANGE",
    POINT_NAME_CHANGE           = "POINT_NAME_CHANGE",
    PROFILE_NAME_CHANGE         = "PROFILE_NAME_CHANGE",
    SAFEMODE_CHANGE             = "SAFEMODE_CHANGE",
    SAFEMODE_ON_COMBAT_CHANGE   = "SAFEMODE_ON_COMBAT_CHANGE",
    ADMIN_ADDED                 = "ADMIN_ADDED",
    ADMIN_REMOVED               = "ADMIN_REMOVED",
    MAIN_SWAP                   = "MAIN_SWAP",
    LOOT_MODE_CHANGE            = "LOOT_MODE_CHANGE",
    REWARD_POT_CONFIG_CHANGE    = "REWARD_POT_CONFIG_CHANGE",
    REWARD_POT_CHANGE           = "REWARD_POT_CHANGE",
    ATTENDANCE_CHANGE           = "ATTENDANCE_CHANGE",
    RC_LOOT_COUNCIL             = "RC_LOOT_COUNCIL",
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
        -- @field source string|nil Integration name
        -- @field reason string|nil Machine-readable reason
        -- @field rollType string|nil Upstream response text
        -- @field itemLink string|nil WoW item link
    },
    [EVENT_TYPES.ROLE_CHANGE] = {
        member  = "",
        newRole = ""
    },
    [EVENT_TYPES.POINT_NAME_CHANGE] = {
        oldName = "",
        newName = ""
    },
    [EVENT_TYPES.PROFILE_NAME_CHANGE] = {
        oldName = "",
        newName = ""
    },
    [EVENT_TYPES.SAFEMODE_CHANGE] = {
        enabled = false -- true or false
    },
    [EVENT_TYPES.SAFEMODE_ON_COMBAT_CHANGE] = {
        enabled = false -- true or false
    },
    [EVENT_TYPES.ADMIN_ADDED] = {
        member = "" -- "Name-Realm"
    },
    [EVENT_TYPES.ADMIN_REMOVED] = {
        member = "" -- "Name-Realm"
    },
    [EVENT_TYPES.MAIN_SWAP] = {
        member = "", -- "Name-Realm" (the new/target character)
        sourceMember = "" -- "Name-Realm" (the old character that was consolidated)
    },
    [EVENT_TYPES.LOOT_MODE_CHANGE] = {
        oldMode = "",
        newMode = ""
    },
    [EVENT_TYPES.REWARD_POT_CONFIG_CHANGE] = {
        startingPotCopper = 0,
        deductionType = "",
        deductionValue = 0
    },
    [EVENT_TYPES.REWARD_POT_CHANGE] = {
        change = "", -- INCREMENT/DECREMENT
        amount = 0 -- copper
        -- @field reason string|nil MANUAL or RAID_DEDUCTION
        -- @field deductionType string|nil flat or percent at the time of a raid deduction
        -- @field percent number|nil percent used when deductionType is percent
    },
    [EVENT_TYPES.ATTENDANCE_CHANGE] = {
        member = "",
        change = "" -- INCREMENT/DECREMENT
        -- @field amount number|nil positive attendance amount
        -- @field reason string|nil RAID_CHECK or MANUAL
    },
    [EVENT_TYPES.RC_LOOT_COUNCIL] = {
        member = "",
        itemLink = "",
        response = "",
        rcAwardId = "",
        awardKey = ""
        -- @field itemString string|nil stable item identity
        -- @field owner string|nil RC item owner
        -- @field responseId number|nil RC response id
        -- @field isAwardReason boolean|nil RC award-reason flag
    }
}

-- Generates a unique log ID based on author and a counter
-- @param author string Author of the log
-- @param counter number Counter to ensure uniqueness
-- @return string logID Unique log ID
local function GenerateLogID(author, counter)
    return ("%s:%d"):format(author, counter)
end

local function _FingerprintAppend(checksum, text)
    text = tostring(text or "")
    for i = 1, #text do
        checksum = (checksum * 33 + text:byte(i)) % FINGERPRINT_MODULO
    end
    return checksum
end

local function _FingerprintValue(checksum, value)
    local valueType = type(value)
    checksum = _FingerprintAppend(checksum, valueType)

    if valueType == "table" then
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)

        for _, key in ipairs(keys) do
            checksum = _FingerprintAppend(checksum, key)
            checksum = _FingerprintValue(checksum, value[key])
        end
        return checksum
    end

    if valueType == "boolean" then
        return _FingerprintAppend(checksum, value and "true" or "false")
    end

    return _FingerprintAppend(checksum, value)
end

local function ComputeFingerprintFromFields(timestamp, author, counter, eventType, eventData)
    local checksum = 5381
    checksum = _FingerprintAppend(checksum, "timestamp")
    checksum = _FingerprintValue(checksum, tonumber(timestamp) or 0)
    checksum = _FingerprintAppend(checksum, "author")
    checksum = _FingerprintValue(checksum, author or "")
    checksum = _FingerprintAppend(checksum, "counter")
    checksum = _FingerprintValue(checksum, tonumber(counter) or 0)
    checksum = _FingerprintAppend(checksum, "eventType")
    checksum = _FingerprintValue(checksum, eventType or "")
    checksum = _FingerprintAppend(checksum, "data")
    checksum = _FingerprintValue(checksum, eventData or {})
    return checksum
end

local LootLog = {}
LootLog.__index = LootLog

function LootLog.IsSequentialCounter(counter)
    return type(counter) == "number" and counter >= 1 and counter == math.floor(counter)
end

function LootLog.IsExternalLogTable(t)
    return type(t) == "table" and type(t._externalId) == "string" and t._externalId ~= ""
end

function LootLog.ExtractItemString(link)
    if type(link) ~= "string" or link == "" then
        return nil
    end
    local itemString = link:match("(item:[%-%d:]+)")
    if type(itemString) == "string" and itemString ~= "" then
        return itemString
    end
    return nil
end

function LootLog.ExtractItemHyperlink(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local colored = text:match("(|c%x+|Hitem:[^|]+|h.-|h|r)")
    if colored then
        return colored
    end
    local plain = text:match("(|Hitem:[^|]+|h.-|h)")
    if plain then
        return plain
    end
    return LootLog.ExtractItemString(text)
end

function LootLog.ParseHistoryTimestamp(historyId)
    if type(historyId) ~= "string" or historyId == "" then
        return nil
    end
    local prefix = historyId:match("^(%d+)")
    local timestamp = tonumber(prefix)
    if type(timestamp) == "number" and timestamp > 0 then
        return math.floor(timestamp)
    end
    return nil
end

function LootLog.NormalizePlayerId(nameOrNameRealm)
    if type(nameOrNameRealm) ~= "string" or nameOrNameRealm == "" then
        return nil
    end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(nameOrNameRealm)
    end
    return strtrim(nameOrNameRealm)
end

function LootLog.MakeRCAwardExternalId(awarder, historyId, winner, itemLink, owner)
    local normalizedAwarder = LootLog.NormalizePlayerId(awarder)
    local normalizedWinner = LootLog.NormalizePlayerId(winner)
    local itemString = LootLog.ExtractItemString(itemLink)
    local normalizedOwner = LootLog.NormalizePlayerId(owner) or ""
    if not normalizedAwarder or not normalizedWinner or type(historyId) ~= "string" or historyId == "" or not itemString then
        return nil
    end
    return table.concat({
        "RCLootCouncil",
        normalizedAwarder,
        historyId,
        normalizedWinner,
        itemString,
        normalizedOwner,
    }, "|")
end

function LootLog.BuildRCLootCouncilCanonical(awarder, winner, history)
    if type(history) ~= "table" then
        return nil
    end
    local normalizedAwarder = LootLog.NormalizePlayerId(awarder)
    local normalizedWinner = LootLog.NormalizePlayerId(winner)
    local itemLink = history.lootWon
    if type(itemLink) ~= "string" or itemLink == "" then
        return nil
    end
    local response = history.response
    if type(response) ~= "string" or strtrim(response) == "" then
        return nil
    end
    local rcAwardId = history.id
    if type(rcAwardId) ~= "string" or rcAwardId == "" then
        return nil
    end
    local awardKey = LootLog.MakeRCAwardExternalId(normalizedAwarder, rcAwardId, normalizedWinner, itemLink, history.owner)
    if not awardKey then
        return nil
    end
    local timestamp = LootLog.ParseHistoryTimestamp(rcAwardId)
    if not timestamp then
        return nil
    end
    return {
        awarder = normalizedAwarder,
        winner = normalizedWinner,
        itemLink = itemLink,
        response = response,
        rcAwardId = rcAwardId,
        owner = LootLog.NormalizePlayerId(history.owner),
        itemString = LootLog.ExtractItemString(itemLink),
        responseId = history.responseID,
        isAwardReason = history.isAwardReason and true or false,
        timestamp = timestamp,
        awardKey = awardKey,
    }
end

function LootLog.BuildRCLootCouncilEventData(canonical)
    if type(canonical) ~= "table" then
        return nil
    end
    return {
        member = canonical.winner,
        itemLink = canonical.itemLink,
        response = canonical.response,
        rcAwardId = canonical.rcAwardId,
        awardKey = canonical.awardKey,
        itemString = canonical.itemString,
        owner = canonical.owner,
        responseId = canonical.responseId,
        isAwardReason = canonical.isAwardReason and true or false,
    }
end

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
        local Imp = SF.LootHelperImpersonation
        local isAdmin
        if Imp and Imp.IsEffectiveLocalAdmin then
            isAdmin = Imp:IsEffectiveLocalAdmin(ap)
        else
            isAdmin = ap and ap.IsCurrentUserAdmin and ap:IsCurrentUserAdmin()
        end
        if not ap or (not Imp and not ap.IsCurrentUserAdmin) then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Active profile missing or IsCurrentUserAdmin not found; cannot create log entry")
            end
            return nil
        elseif not isAdmin then
            if SF.Debug then
                SF.Debug:Warn("LOOTLOG", "Current user is not an admin; cannot create log entry")
            end
            return nil
        end

        if eventType == EVENT_TYPES.LOOT_MODE_CHANGE then
            local isOwner
            if Imp and Imp.IsEffectiveLocalOwner then
                isOwner = Imp:IsEffectiveLocalOwner(ap)
            else
                isOwner = type(ap.IsCurrentUserOwner) == "function" and ap:IsCurrentUserOwner()
            end
            if not isOwner then
                if SF.Debug then
                    SF.Debug:Warn("LOOTLOG", "Current user is not the owner; cannot change loot mode")
                end
                return nil
            end
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
    elseif eventType == EVENT_TYPES.POINT_NAME_CHANGE then
        if not SF.LootLogValidators.ValidatePointNameChangeData(eventData) then
            return nil
        end
    elseif eventType == EVENT_TYPES.PROFILE_NAME_CHANGE then
        if not SF.LootLogValidators.ValidateProfileNameChangeData(eventData) then
            return nil
        end
    elseif eventType == EVENT_TYPES.SAFEMODE_CHANGE then
        if not SF.LootLogValidators.ValidateSafemodeChangeData(eventData) then
            return nil
        end
    elseif eventType == EVENT_TYPES.SAFEMODE_ON_COMBAT_CHANGE then
        if not SF.LootLogValidators.ValidateSafemodeOnCombatChangeData(eventData) then
            return nil
        end
    elseif eventType == EVENT_TYPES.ADMIN_ADDED then
        if not SF.LootLogValidators.ValidateAdminAddedData(eventData) then
            return nil
        end
    elseif eventType == EVENT_TYPES.ADMIN_REMOVED then
        if not SF.LootLogValidators.ValidateAdminRemovedData(eventData) then
            return nil
        end
    elseif eventType == EVENT_TYPES.MAIN_SWAP then
        if not SF.LootLogValidators.ValidateMainSwapData(eventData) then
            return nil
        end
    elseif eventType == EVENT_TYPES.LOOT_MODE_CHANGE then
        if not SF.LootLogValidators.ValidateLootModeChangeData(eventData) then
            return nil
        end
    elseif eventType == EVENT_TYPES.REWARD_POT_CONFIG_CHANGE then
        if not SF.LootLogValidators.ValidateRewardPotConfigChangeData(eventData) then
            return nil
        end
    elseif eventType == EVENT_TYPES.REWARD_POT_CHANGE then
        if not SF.LootLogValidators.ValidateRewardPotChangeData(eventData, POINT_CHANGE_TYPES) then
            return nil
        end
    elseif eventType == EVENT_TYPES.ATTENDANCE_CHANGE then
        if not SF.LootLogValidators.ValidateAttendanceChangeData(eventData, POINT_CHANGE_TYPES) then
            return nil
        end
    elseif eventType == EVENT_TYPES.RC_LOOT_COUNCIL then
        if not SF.LootLogValidators.ValidateRCLootCouncilData(eventData) then
            return nil
        end
    end

    local timestamp = opts.timestamp or GetServerTime()
    local author = opts.author or SF:GetPlayerFullIdentifier()
    local externalId = opts.externalId
    local isExternal = type(externalId) == "string" and externalId ~= ""

    -- Counter allocation: must be per-profile per-author to avoid collisions.
    -- External RC awards use sentinel counter 0 and never allocate a sequence.
    local counter = opts.counter
    if isExternal then
        counter = 0
    elseif type(counter) ~= "number" then
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

    if isExternal then
        counter = 0
    elseif not LootLog.IsSequentialCounter(counter) then
        if SF.Debug then
            SF.Debug:Warn("LOOTLOG", "Ordinary logs require a positive integer counter")
        end
        return nil
    end

    local instance = setmetatable({}, LootLog)
    instance._timestamp = timestamp
    instance._author = author
    instance._counter = counter
    instance._eventType = eventType
    instance._data = eventData
    if isExternal then
        instance._externalId = externalId
        instance._id = externalId
    else
        instance._id = GenerateLogID(author, counter)
    end
    instance._fingerprint = ComputeFingerprintFromFields(timestamp, author, counter, eventType, eventData)

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

function LootLog.GetPointChangeAmount(eventData)
    if type(eventData) ~= "table" then
        return DEFAULT_POINT_CHANGE_AMOUNT
    end

    local amount = tonumber(eventData.amount)
    if amount and amount > 0 then
        return amount
    end

    return DEFAULT_POINT_CHANGE_AMOUNT
end

function LootLog.GetAttendanceChangeAmount(eventData)
    if type(eventData) ~= "table" then
        return 1
    end

    local amount = tonumber(eventData.amount)
    if amount and amount > 0 then
        return amount
    end

    return 1
end

function LootLog.GetRewardPotChangeAmount(eventData)
    if type(eventData) ~= "table" then
        return 0
    end

    local amount = math.floor(tonumber(eventData.amount) or 0)
    if amount < 0 then
        return 0
    end
    return amount
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

-- Function to get the deterministic content fingerprint of this log entry
-- @return number fingerprint
function LootLog:GetFingerprint()
    if type(self._fingerprint) ~= "number" then
        self._fingerprint = ComputeFingerprintFromFields(
            self._timestamp,
            self._author,
            self._counter,
            self._eventType,
            self._data
        )
    end
    return self._fingerprint
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
    local t = {
        version     = LOG_FORMAT_VERSION,
        _id         = self._id,
        _timestamp  = self._timestamp,
        _author     = self._author,
        _counter    = self._counter,
        _eventType  = self._eventType,
        _data       = self._data,
        _fingerprint= self:GetFingerprint(),
    }
    if type(self._externalId) == "string" and self._externalId ~= "" then
        t._externalId = self._externalId
    end
    return t
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
    local isExternal = LootLog.IsExternalLogTable(t)
    if isExternal then
        if t._id ~= t._externalId then
            return false, "log._id must match _externalId"
        end
        if type(t._counter) ~= "number" or t._counter ~= 0 then
            return false, "external log._counter must be 0"
        end
    else
        if type(t._counter) ~= "number" or t._counter < 1 or t._counter ~= math.floor(t._counter) then
            return false, "log._counter must be a positive integer"
        end
        local expectedId = ("%s:%d"):format(t._author, t._counter)
        if t._id ~= expectedId then
            return false, ("log._id mismatch (expected %s, got %s)"):format(expectedId, tostring(t._id))
        end
    end
    if type(t._eventType) ~= "string" or t._eventType == "" then
        return false, "log._eventType must be a non-empty string"
    end
    if type(t._data) ~= "table" then return false, "log._data must be a table" end

    local computedFingerprint = ComputeFingerprintFromFields(t._timestamp, t._author, t._counter, t._eventType, t._data)
    if t._fingerprint ~= nil then
        if type(t._fingerprint) ~= "number" then
            return false, "log._fingerprint must be a number when provided"
        end
        if t._fingerprint ~= computedFingerprint then
            return false, ("log._fingerprint mismatch (expected %s, got %s)"):format(
                tostring(computedFingerprint),
                tostring(t._fingerprint)
            )
        end
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
    if LootLog.IsExternalLogTable(t) then
        instance._externalId = t._externalId
    end
    instance._fingerprint = t._fingerprint or ComputeFingerprintFromFields(
        t._timestamp,
        t._author,
        t._counter,
        t._eventType,
        t._data
    )

    return instance, nil
end

function LootLog.ComputeFingerprintFromTable(t)
    if type(t) ~= "table" then return nil end
    return ComputeFingerprintFromFields(t._timestamp, t._author, t._counter, t._eventType, t._data)
end

-- ============================================================================
-- Export to Namespace
-- ============================================================================
SF.LootLog = LootLog
SF.LootLogEventTypes = EVENT_TYPES
SF.LootLogPointChangeTypes = POINT_CHANGE_TYPES
SF.LootLogArmorActions = ARMOR_ACTIONS
