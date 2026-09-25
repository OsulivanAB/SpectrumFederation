-- Production-Lua tests for the read-only TSM adapter.
-- Run from the repository root: lua5.1 tests/lua/tsm_integration_tests.lua

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(message) .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. tostring(message or "") .. "\n")
end

local function assertTrue(cond, message)
    if cond then
        pass(message)
    else
        fail(message)
    end
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local function assertNil(actual, message)
    if actual == nil then
        pass(message)
    else
        fail(string.format("%s (expected nil, got %s)", message, tostring(actual)))
    end
end

local debugErrors = {}

local SF = {
    Debug = {
        Error = function(_, category, message, ...)
            debugErrors[#debugErrors + 1] = string.format("%s %s", tostring(category), string.format(message, ...))
        end,
    },
}

local chunk = assert(loadfile("SpectrumFederation/modules/Integrations/TSM.lua"))
chunk("SpectrumFederation", SF)

local TSM = SF.TSM
local LINK = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0:80:0:0:0:0:1:1234:5678|h[Thunderfury]|h|r"
local TSM_ITEM = "i:19019:1234:5678"

local calls = {
    toItem = {},
    price = {},
}

local function resetCalls()
    calls.toItem = {}
    calls.price = {}
    debugErrors = {}
end

local function installApi(overrides)
    resetCalls()
    local api = {
        ToItemString = function(item)
            calls.toItem[#calls.toItem + 1] = item
            if type(item) ~= "string" or item == "" or item == "item:bad" then
                return nil
            end
            if item == LINK or item == "item:19019:0:0:0:0:0:0:0:80:0:0:0:0:1:1234:5678" then
                return TSM_ITEM
            end
            if item:match("^item:(%d+)$") then
                return "i:" .. item:match("^item:(%d+)$")
            end
            if item:match("^i:") or item:match("^p:") then
                return item
            end
            return nil
        end,
        GetCustomPriceValue = function(source, itemString)
            calls.price[#calls.price + 1] = { source = source, itemString = itemString }
            if source == "DBMarket" and itemString == TSM_ITEM then
                return 125000
            end
            if source == "DBMinBuyout" and itemString == TSM_ITEM then
                return 99000
            end
            if source == "DBMarket * 0.5" and itemString == TSM_ITEM then
                return 62500
            end
            if source == "ZERO" then
                return 0
            end
            if source == "MISSING" then
                return nil
            end
            if source == "BADSOURCE" then
                return nil, "Invalid custom price"
            end
            if source == "BOOM" then
                error("tsm exploded")
            end
            if source == "WEIRD" then
                return "not-a-number"
            end
            return nil
        end,
    }
    if type(overrides) == "table" then
        for key, value in pairs(overrides) do
            api[key] = value
        end
    end
    TSM_API = api
end

local function clearApi()
    resetCalls()
    TSM_API = nil
end

installApi()
assertTrue(TSM.IsAvailable(), "availability detection succeeds when both API functions exist")

local normalized = TSM.NormalizeItem(LINK)
assertEq(normalized, TSM_ITEM, "a valid item link normalizes through ToItemString")
assertEq(calls.toItem[1], LINK, "normalization forwards the full item link")
assertEq(#calls.toItem, 1, "one link uses one ToItemString call")

local fromId = TSM.NormalizeItem(19019)
assertEq(fromId, "i:19019", "a numeric item id normalizes")
assertEq(calls.toItem[#calls.toItem], "item:19019", "numeric ids become a WoW item string before TSM sees them")

local fromIdText = TSM.NormalizeItem(" 19019 ")
assertEq(fromIdText, "i:19019", "a numeric item id string normalizes")

local fromTsm = TSM.NormalizeItem("i:19019:1234:5678")
assertEq(fromTsm, "i:19019:1234:5678", "an existing TSM item string is preserved")
assertEq(calls.toItem[#calls.toItem], "i:19019:1234:5678", "TSM item strings are forwarded unchanged")

local fromRecord = TSM.NormalizeItem({
    itemLink = LINK,
    itemString = "item:1",
    itemId = 1,
})
assertEq(fromRecord, TSM_ITEM, "a record prefers the item link")
assertEq(calls.toItem[#calls.toItem], LINK, "the less specific record fields are not sent first")

installApi({
    ToItemString = function(item)
        calls.toItem[#calls.toItem + 1] = item
        if item == "not-a-link" then
            return nil
        end
        if item == "item:19019" then
            return "i:19019"
        end
        return nil
    end,
})
local fallback = TSM.NormalizeItem({
    itemLink = "not-a-link",
    itemString = "item:19019",
})
assertEq(fallback, "i:19019", "a rejected link falls back to the record item string")
assertEq(#calls.toItem, 2, "fallback tries the next representation once")

installApi()
local market, marketReason = TSM.GetMarketValue(LINK)
assertEq(market, 125000, "GetMarketValue returns the DBMarket copper value")
assertNil(marketReason, "a priced market value has no reason")
assertEq(calls.price[#calls.price].source, TSM.SOURCE.MARKET, "GetMarketValue delegates to DBMarket")
assertEq(calls.price[#calls.price].itemString, TSM_ITEM, "GetMarketValue evaluates the normalized item")

local buyout, buyoutReason = TSM.GetMinBuyout(LINK)
assertEq(buyout, 99000, "GetMinBuyout returns the DBMinBuyout copper value")
assertNil(buyoutReason, "a priced min buyout has no reason")
assertEq(calls.price[#calls.price].source, TSM.SOURCE.MIN_BUYOUT, "GetMinBuyout delegates to DBMinBuyout")

local expressed, expressedReason = TSM.EvaluatePriceSource(LINK, "DBMarket * 0.5")
assertEq(expressed, 62500, "a custom price expression evaluates")
assertNil(expressedReason, "a successful expression has no reason")
assertEq(calls.price[#calls.price].source, "DBMarket * 0.5", "the expression is forwarded unchanged")
assertEq(calls.price[#calls.price].itemString, TSM_ITEM, "the expression uses the normalized item")

local zeroValue, zeroReason = TSM.EvaluatePriceSource(LINK, "ZERO")
assertEq(zeroValue, 0, "a legitimate zero copper value is preserved")
assertNil(zeroReason, "zero is not reported as missing data")

local missing, missingReason = TSM.EvaluatePriceSource(LINK, "MISSING")
assertNil(missing, "missing price data returns nil")
assertEq(missingReason, TSM.REASON.NO_DATA, "missing price data uses the no_data reason")
assertTrue(missing ~= 0, "missing price data is not converted to zero")
assertEq(#debugErrors, 0, "missing price data does not log an API error")

local badSource, badSourceReason = TSM.EvaluatePriceSource(LINK, "BADSOURCE")
assertNil(badSource, "an invalid price source returns nil")
assertEq(badSourceReason, TSM.REASON.INVALID_SOURCE, "TSM's invalid-source error maps to invalid_source")

local priceCallsBeforeBlank = #calls.price
local convertCallsBeforeBlank = #calls.toItem
local emptySource, emptySourceReason = TSM.EvaluatePriceSource(LINK, "   ")
assertNil(emptySource, "a blank price source returns nil")
assertEq(emptySourceReason, TSM.REASON.INVALID_SOURCE, "a blank price source is invalid_source")
assertEq(#calls.price, priceCallsBeforeBlank, "a blank price source does not call GetCustomPriceValue")
assertEq(#calls.toItem, convertCallsBeforeBlank, "a blank price source does not convert an item")

local badItem, badItemReason = TSM.NormalizeItem("not-an-item")
assertNil(badItem, "an unrecognized item fails normalization")
assertEq(badItemReason, TSM.REASON.INVALID_ITEM, "an unrecognized item is invalid_item")

local priceCallsBeforeMalformed = #calls.price
local malformed, malformedReason = TSM.EvaluatePriceSource("", "DBMarket")
assertNil(malformed, "an empty item fails safely")
assertEq(malformedReason, TSM.REASON.INVALID_ITEM, "an empty item is invalid_item")
assertEq(#calls.price, priceCallsBeforeMalformed, "an invalid item does not evaluate a price")

local fractional, fractionalReason = TSM.NormalizeItem(1.5)
assertNil(fractional, "a fractional item id fails safely")
assertEq(fractionalReason, TSM.REASON.INVALID_ITEM, "a fractional item id is invalid_item")

local weird, weirdReason = TSM.EvaluatePriceSource(LINK, "WEIRD")
assertNil(weird, "a non-numeric TSM result returns nil")
assertEq(weirdReason, TSM.REASON.API_ERROR, "a non-numeric TSM result is an API error")
assertEq(#debugErrors, 1, "unexpected TSM return types are debug-logged")

installApi({
    GetCustomPriceValue = function()
        error("tsm exploded")
    end,
})
local beforeErrors = #debugErrors
local crashed = false
local boomValue, boomReason
local callOk = pcall(function()
    boomValue, boomReason = TSM.GetMarketValue(LINK)
end)
if not callOk then
    crashed = true
end
assertTrue(not crashed, "an unexpected TSM API failure does not escape the adapter")
assertNil(boomValue, "an API failure returns nil")
assertEq(boomReason, TSM.REASON.API_ERROR, "an API failure returns api_error")
assertTrue(#debugErrors > beforeErrors, "an API failure is recorded for diagnosis")

installApi({
    ToItemString = function()
        error("convert exploded")
    end,
})
local convertValue, convertReason = TSM.NormalizeItem(LINK)
assertNil(convertValue, "a ToItemString failure returns nil")
assertEq(convertReason, TSM.REASON.API_ERROR, "a ToItemString failure returns api_error")

clearApi()
assertTrue(not TSM.IsAvailable(), "availability is false when TSM_API is missing")
local absentValue, absentReason = TSM.GetMarketValue(LINK)
assertNil(absentValue, "price helpers return nil when TSM is absent")
assertEq(absentReason, TSM.REASON.UNAVAILABLE, "price helpers report unavailable when TSM is absent")
local absentItem, absentItemReason = TSM.NormalizeItem(LINK)
assertNil(absentItem, "normalization returns nil when TSM is absent")
assertEq(absentItemReason, TSM.REASON.UNAVAILABLE, "normalization reports unavailable when TSM is absent")
assertEq(#debugErrors, 0, "a missing TSM API is not an error log")

TSM_API = {
    ToItemString = function()
        return TSM_ITEM
    end,
}
assertTrue(not TSM.IsAvailable(), "availability is false until GetCustomPriceValue exists")
local partialValue, partialReason = TSM.GetMinBuyout(LINK)
assertNil(partialValue, "a partial TSM API fails safely")
assertEq(partialReason, TSM.REASON.UNAVAILABLE, "a partial TSM API reports unavailable")

local indexErrors = 0
TSM_API = setmetatable({}, {
    __index = function(_, key)
        indexErrors = indexErrors + 1
        error("Invalid TSM API function: " .. tostring(key))
    end,
})
local metaOk, metaAvailable = pcall(TSM.IsAvailable)
assertTrue(metaOk, "availability does not trip TSM_API's erroring metatable")
assertTrue(metaAvailable == false, "an unpopulated TSM_API table is not available")
assertEq(indexErrors, 0, "availability uses rawget and does not touch unknown keys")

installApi()
local priceCalls = 0
local convertCalls = 0
TSM_API.GetCustomPriceValue = function(source, itemString)
    priceCalls = priceCalls + 1
    calls.price[#calls.price + 1] = { source = source, itemString = itemString }
    return 10
end
TSM_API.ToItemString = function(item)
    convertCalls = convertCalls + 1
    calls.toItem[#calls.toItem + 1] = item
    return TSM_ITEM
end
local repeatedOk = true
for _ = 1, 25 do
    local value, reason = TSM.EvaluatePriceSource(LINK, "DBMarket")
    if value ~= 10 or reason ~= nil then
        repeatedOk = false
    end
end
assertTrue(repeatedOk, "repeated evaluation returns the stubbed price without a reason")
assertEq(priceCalls, 25, "25 evaluations call GetCustomPriceValue 25 times")
assertEq(convertCalls, 25, "25 evaluations call ToItemString 25 times")
assertEq(#calls.price, 25, "repeated evaluation does not multiply stored call records")

clearApi()
assertTrue(not TSM.IsAvailable(), "clearing TSM_API makes the adapter unavailable again")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
