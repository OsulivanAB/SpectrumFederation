-- Production-Lua tests for SyncProtocol incompatibility warning dedupe.
-- Run from the repository root: lua5.1 tests/lua/sync_protocol_tests.lua

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. message .. "\n")
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

function GetServerTime()
    return 1700000000
end

function GetTime()
    return 0
end

C_EncodingUtil = {
    SerializeCBOR = function()
        return "cbor-bytes"
    end,
    EncodeBase64 = function()
        return "YWJj"
    end,
    DecodeBase64 = function()
        return "cbor-bytes"
    end,
    DeserializeCBOR = function()
        return { kind = "PROTO_NACK" }
    end,
}

local SF = {}
local now = 1000
local warnings = {}
local debugWarns = {}

function SF:Now()
    return now
end

function SF:PrintWarning(message)
    warnings[#warnings + 1] = tostring(message)
end

SF.Debug = {
    Warn = function(_, _, fmt, ...)
        debugWarns[#debugWarns + 1] = string.format(tostring(fmt or ""), ...)
    end,
}

local chunk = assert(loadfile("SpectrumFederation/modules/LootHelper/SyncProtocol.lua"))
chunk("SpectrumFederation", SF)

local P = SF.SyncProtocol

local function nackPayload(overrides)
    local payload = {
        seenProto = 2,
        supportedMin = 1,
        supportedMax = 1,
        addonVersion = "1.4.1",
    }
    if type(overrides) == "table" then
        for k, v in pairs(overrides) do
            payload[k] = v
        end
    end
    return payload
end

local screenshotPayload = nackPayload()

for i = 1, 20 do
    P.OnProtoNack("Suspenders-Icecrown", screenshotPayload)
end
assertEq(#warnings, 1, "repeat PROTO_NACK from one peer prints once")
assertTrue(
    warnings[1]:find("Suspenders%-Icecrown says our protocol/version is incompatible", 1, false) ~= nil,
    "first PROTO_NACK keeps the user-facing incompatibility text"
)
assertTrue(#debugWarns >= 19, "repeat PROTO_NACK is logged as debug instead of chat")

P.OnProtoNack("suspenders-icecrown", screenshotPayload)
assertEq(#warnings, 1, "PROTO_NACK sender key is case-insensitive")

P.OnProtoNack("Otherplayer-Icecrown", screenshotPayload)
assertEq(#warnings, 2, "a different peer still gets one warning")

P.OnProtoNack("Suspenders-Icecrown", nackPayload({ addonVersion = "1.5.0-beta.2" }))
assertEq(#warnings, 3, "changed incompatibility details can warn again")

local beforeUnsupported = #warnings
local firstNack = P.OnUnsupportedProto("Oldclient-Icecrown", 1, "SES_HEARTBEAT")
assertTrue(type(firstNack) == "string" and firstNack:find("^PROTO_NACK\t", 1, false) ~= nil,
    "first unsupported proto returns a NACK envelope")
assertEq(#warnings, beforeUnsupported + 1, "first unsupported proto prints once")

local secondNack = P.OnUnsupportedProto("Oldclient-Icecrown", 1, "SES_START")
assertNil(secondNack, "unsupported proto NACK respects the 10s network cooldown")
assertEq(#warnings, beforeUnsupported + 1, "repeat unsupported proto does not reprint")

now = now + 10
local thirdNack = P.OnUnsupportedProto("Oldclient-Icecrown", 1, "SES_HEARTBEAT")
assertTrue(type(thirdNack) == "string", "NACK can be sent again after cooldown")
assertEq(#warnings, beforeUnsupported + 1, "NACK resend after cooldown still does not reprint")

local altSender = "Mixedpeer-Icecrown"
P.OnUnsupportedProto(altSender, 1, "SES_HEARTBEAT")
P.OnProtoNack(altSender, screenshotPayload)
P.OnUnsupportedProto(altSender, 1, "NEED_LOGS")
P.OnProtoNack(altSender, screenshotPayload)
local mixedCount = 0
for i = 1, #warnings do
    if warnings[i]:find("Mixedpeer%-Icecrown", 1, false) then
        mixedCount = mixedCount + 1
    end
end
assertEq(mixedCount, 2, "alternating NACK and unsupported warnings do not retrigger")

assertTrue(P.ShouldNack("Cooldown-One"), "first ShouldNack allows send")
assertTrue(not P.ShouldNack("Cooldown-One"), "second ShouldNack within 10s is blocked")
assertTrue(not P.ShouldNack("cooldown-one"), "ShouldNack sender key is case-insensitive")
now = now + 10
assertTrue(P.ShouldNack("Cooldown-One"), "ShouldNack allows send after 10s")

assertTrue(P.ShouldWarn("Warnpeer", "sig-a"), "first ShouldWarn allows print")
assertTrue(not P.ShouldWarn("Warnpeer", "sig-a"), "repeat ShouldWarn signature is blocked")
assertTrue(P.ShouldWarn("Warnpeer", "sig-b"), "new ShouldWarn signature is allowed")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
