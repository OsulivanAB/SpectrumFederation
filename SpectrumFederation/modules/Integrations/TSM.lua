-- Read-only TradeSkillMaster adapter.
-- Features call SF.TSM. This is the only place that talks to TSM_API.
-- The module does not scan, poll, register events, or store TSM data.
--
-- Public API verified from https://api.tradeskillmaster.com/addon/ :
--   TSM_API.ToItemString(item) -> TSM item string, or nil
--   TSM_API.GetCustomPriceValue(customPriceStr, itemString)
--     -> copper, or nil plus an error string when the source is invalid
-- ToItemString accepts an item link, a TSM item string, or a WoW item string.
-- TSM_API's metatable errors on unknown keys, so availability uses rawget.

local addonName, SF = ...

SF.TSM = SF.TSM or {}
local TSM = SF.TSM

TSM.REASON = {
    UNAVAILABLE = "unavailable",
    INVALID_ITEM = "invalid_item",
    INVALID_SOURCE = "invalid_source",
    NO_DATA = "no_data",
    API_ERROR = "api_error",
}

-- Public price-source keys forwarded to GetCustomPriceValue.
TSM.SOURCE = {
    MARKET = "DBMarket",
    MIN_BUYOUT = "DBMinBuyout",
}

local function Trim(value)
    return (value:match("^%s*(.-)%s*$"))
end

local function IsPositiveInteger(value)
    return type(value) == "number"
        and value >= 1
        and value == math.floor(value)
end

-- Numeric IDs are not a documented ToItemString input. A WoW item string is.
local function WowItemStringFromId(itemId)
    if not IsPositiveInteger(itemId) then
        return nil
    end
    local text = tostring(itemId)
    if not text:match("^%d+$") then
        return nil
    end
    return "item:" .. text
end

local function PrepareCandidate(item)
    local kind = type(item)
    if kind == "number" then
        return WowItemStringFromId(item)
    end
    if kind ~= "string" then
        return nil
    end
    local trimmed = Trim(item)
    if trimmed == "" then
        return nil
    end
    if trimmed:match("^%d+$") then
        return WowItemStringFromId(tonumber(trimmed))
    end
    return trimmed
end

-- Richer Spectrum records keep itemLink, then itemString, then itemId.
-- Try them in that order so a specific link is not reduced first.
local function CollectCandidates(item)
    if type(item) ~= "table" then
        return { item }
    end
    local list = {}
    if item.itemLink ~= nil then
        list[#list + 1] = item.itemLink
    end
    if item.itemString ~= nil then
        list[#list + 1] = item.itemString
    end
    if item.itemId ~= nil then
        list[#list + 1] = item.itemId
    end
    return list
end

local function LogApiError(operation, err)
    if SF.Debug and SF.Debug.Error then
        SF.Debug:Error("TSM", "TSM API %s failed: %s", tostring(operation), tostring(err))
    end
end

-- Returns the API table and the two functions this adapter needs, or nil.
-- rawget avoids TSM_API's erroring __index when a function is not registered yet.
local function GetApi()
    local api = rawget(_G, "TSM_API")
    if type(api) ~= "table" then
        return nil
    end
    local toItemString = rawget(api, "ToItemString")
    local getCustomPriceValue = rawget(api, "GetCustomPriceValue")
    if type(toItemString) ~= "function" or type(getCustomPriceValue) ~= "function" then
        return nil
    end
    return api, toItemString, getCustomPriceValue
end

function TSM.IsAvailable()
    return GetApi() ~= nil
end

--- Convert an item link, id, TSM item string, WoW item string, or item record.
--- @return string|nil TSM item string
--- @return string|nil reason when conversion fails
function TSM.NormalizeItem(item)
    local _, toItemString = GetApi()
    if not toItemString then
        return nil, TSM.REASON.UNAVAILABLE
    end

    local candidates = CollectCandidates(item)
    if #candidates == 0 then
        return nil, TSM.REASON.INVALID_ITEM
    end

    for index = 1, #candidates do
        local prepared = PrepareCandidate(candidates[index])
        if prepared then
            local ok, itemString = pcall(toItemString, prepared)
            if not ok then
                LogApiError("ToItemString", itemString)
                return nil, TSM.REASON.API_ERROR
            end
            if type(itemString) == "string" and itemString ~= "" then
                return itemString
            end
        end
    end

    return nil, TSM.REASON.INVALID_ITEM
end

--- Evaluate one TSM price source or custom-price expression.
--- A numeric result can be 0. Missing data returns nil plus a reason.
--- @param item any Item input accepted by NormalizeItem
--- @param sourceOrExpression string Price source key or custom price expression
--- @return number|nil copper value
--- @return string|nil reason when no value is available
function TSM.EvaluatePriceSource(item, sourceOrExpression)
    local _, _, getCustomPriceValue = GetApi()
    if not getCustomPriceValue then
        return nil, TSM.REASON.UNAVAILABLE
    end
    if type(sourceOrExpression) ~= "string" or Trim(sourceOrExpression) == "" then
        return nil, TSM.REASON.INVALID_SOURCE
    end

    local itemString, itemReason = TSM.NormalizeItem(item)
    if not itemString then
        return nil, itemReason
    end

    -- Forward the caller's source text unchanged, including expressions.
    local ok, value, err = pcall(getCustomPriceValue, sourceOrExpression, itemString)
    if not ok then
        LogApiError("GetCustomPriceValue", value)
        return nil, TSM.REASON.API_ERROR
    end
    if type(value) == "number" then
        return value
    end
    if value == nil and type(err) == "string" and err ~= "" then
        return nil, TSM.REASON.INVALID_SOURCE
    end
    if value == nil then
        return nil, TSM.REASON.NO_DATA
    end

    LogApiError("GetCustomPriceValue", "unexpected return type " .. type(value))
    return nil, TSM.REASON.API_ERROR
end

function TSM.GetMarketValue(item)
    return TSM.EvaluatePriceSource(item, TSM.SOURCE.MARKET)
end

function TSM.GetMinBuyout(item)
    return TSM.EvaluatePriceSource(item, TSM.SOURCE.MIN_BUYOUT)
end
