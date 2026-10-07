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

local function countDebug(needle)
    local count = 0
    for i = 1, #debugWarns do
        if debugWarns[i]:find(needle, 1, false) then
            count = count + 1
        end
    end
    return count
end

local screenshotPayload = nackPayload()

for i = 1, 20 do
    P.OnProtoNack("Suspenders-Icecrown", screenshotPayload)
end
assertEq(#warnings, 0, "PROTO_NACK incompatibility never prints to chat")
assertEq(
    countDebug("Suspenders%-Icecrown says our protocol/version is incompatible"),
    1,
    "first PROTO_NACK records the incompatibility text in debug"
)
assertTrue(countDebug("Suppressed repeat PROTO_NACK from Suspenders%-Icecrown") >= 19,
    "repeat PROTO_NACK is logged as suppressed debug instead of chat")

P.OnProtoNack("suspenders-icecrown", screenshotPayload)
assertEq(
    countDebug("Suspenders%-Icecrown says our protocol/version is incompatible")
        + countDebug("suspenders%-icecrown says our protocol/version is incompatible"),
    1,
    "PROTO_NACK sender key is case-insensitive for debug latches"
)

local beforeOther = #debugWarns
P.OnProtoNack("Otherplayer-Icecrown", screenshotPayload)
assertTrue(countDebug("Otherplayer%-Icecrown says our protocol/version is incompatible") == 1,
    "a different peer still gets one debug incompatibility record")
assertTrue(#debugWarns > beforeOther, "different peer appends debug")

local beforeChanged = #debugWarns
P.OnProtoNack("Suspenders-Icecrown", nackPayload({ addonVersion = "1.5.0-beta.2" }))
assertTrue(countDebug("addon ver=1%.5%.0%-beta%.2") == 1,
    "changed incompatibility details can debug again")
assertTrue(#debugWarns > beforeChanged, "changed details append debug")

assertEq(#warnings, 0, "PROTO_NACK path still never prints to chat after more peers")

local firstNack = P.OnUnsupportedProto("Oldclient-Icecrown", 1, "SES_HEARTBEAT")
assertTrue(type(firstNack) == "string" and firstNack:find("^PROTO_NACK\t", 1, false) ~= nil,
    "first unsupported proto returns a NACK envelope")
assertEq(
    countDebug("Oldclient%-Icecrown is using unsupported protocol"),
    1,
    "first unsupported proto records the ask-to-update text in debug"
)
assertEq(#warnings, 0, "unsupported proto never prints to chat")

local secondNack = P.OnUnsupportedProto("Oldclient-Icecrown", 1, "SES_START")
assertNil(secondNack, "unsupported proto NACK respects the 10s network cooldown")
assertEq(
    countDebug("Oldclient%-Icecrown is using unsupported protocol"),
    1,
    "repeat unsupported proto does not re-log the ask-to-update debug text"
)

now = now + 10
local thirdNack = P.OnUnsupportedProto("Oldclient-Icecrown", 1, "SES_HEARTBEAT")
assertTrue(type(thirdNack) == "string", "NACK can be sent again after cooldown")
assertEq(
    countDebug("Oldclient%-Icecrown is using unsupported protocol"),
    1,
    "NACK resend after cooldown still does not re-log ask-to-update debug"
)

local altSender = "Mixedpeer-Icecrown"
P.OnUnsupportedProto(altSender, 1, "SES_HEARTBEAT")
P.OnProtoNack(altSender, screenshotPayload)
P.OnUnsupportedProto(altSender, 1, "NEED_LOGS")
P.OnProtoNack(altSender, screenshotPayload)
local mixedCount = 0
for i = 1, #debugWarns do
    local line = debugWarns[i]
    if line:find("Mixedpeer%-Icecrown is using unsupported protocol", 1, false)
        or line:find("Mixedpeer%-Icecrown says our protocol/version is incompatible", 1, false) then
        mixedCount = mixedCount + 1
    end
end
assertEq(mixedCount, 2, "alternating NACK and unsupported debug notices do not retrigger")
assertEq(#warnings, 0, "mixed unsupported/NACK traffic never prints to chat")

assertTrue(P.ShouldNack("Cooldown-One"), "first ShouldNack allows send")
assertTrue(not P.ShouldNack("Cooldown-One"), "second ShouldNack within 10s is blocked")
assertTrue(not P.ShouldNack("cooldown-one"), "ShouldNack sender key is case-insensitive")
now = now + 10
assertTrue(P.ShouldNack("Cooldown-One"), "ShouldNack allows send after 10s")

assertTrue(P.ShouldWarn("Warnpeer", "sig-a"), "first ShouldWarn allows debug emit")
assertTrue(not P.ShouldWarn("Warnpeer", "sig-a"), "repeat ShouldWarn signature is blocked")
assertTrue(P.ShouldWarn("Warnpeer", "sig-b"), "new ShouldWarn signature is allowed")

-- Source guards for Remove / Debug Only chat decisions that are not covered above.
local function readFile(path)
    local f = assert(io.open(path, "r"))
    local body = f:read("*a")
    f:close()
    return body
end

local mainAddon = readFile("SpectrumFederation/SpectrumFederation.lua")
assertTrue(
    mainAddon:find('PrintSuccess%("Online%. Type /sf to open settings."%)', 1, false) == nil,
    "login online banner PrintSuccess is removed"
)

local slash = readFile("SpectrumFederation/modules/SlashCommands.lua")
assertTrue(
    slash:find("Session started successfully", 1, true) == nil,
    "slash session start success chat is removed"
)
assertTrue(
    slash:find("Session ended successfully", 1, true) == nil,
    "slash session end success chat is removed"
)

local controller = readFile("SpectrumFederation/modules/UI/LootHelper/Controller.lua")
assertTrue(
    controller:find("Session started successfully", 1, true) == nil,
    "controller session start success chat is removed"
)
assertTrue(
    controller:find("Session ended successfully", 1, true) == nil,
    "controller session end success chat is removed"
)

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
