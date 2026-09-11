-- Scale measurements for Identity.OrderLogs / Replay / RebuildProfile (F-02).
-- This does not optimize identity; it reports cost at representative history sizes.
-- Run from the repository root: lua5.1 tests/lua/identity_replay_benchmark_tests.lua

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

local PLAYER = "Owner-Garona"

function strtrim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

function string.trim(s)
    return strtrim(s)
end

function GetRealmName()
    return "Garona"
end

function UnitName(unit)
    if unit == "player" then
        return PLAYER:match("^([^%-]+)")
    end
    return "Unknown"
end

function UnitFullName(unit)
    if unit == "player" then
        return PLAYER:match("^([^%-]+)"), "Garona"
    end
    return "Unknown", "Garona"
end

function UnitClass()
    return "Warrior", "WARRIOR"
end

local NOW = 1700001000
function GetServerTime()
    NOW = NOW + 1
    return NOW
end

function GetTime()
    return 0
end

SpectrumFederationDB = { lootHelper = { profiles = {}, syncSession = {}, window = {} } }
SpectrumFederationDebugDB = { enabled = false, logs = {} }

local SF = {}
local function loadModule(relative)
    local chunk = assert(loadfile(relative))
    chunk("SpectrumFederation", SF)
end

loadModule("SpectrumFederation/modules/NameUtil.lua")
loadModule("SpectrumFederation/modules/core.lua")
loadModule("SpectrumFederation/modules/LootHelper/Members.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootLogValidators.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootLogs.lua")
loadModule("SpectrumFederation/modules/LootHelper/Identity.lua")
loadModule("SpectrumFederation/modules/LootHelper/Profiles.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootHelper.lua")
loadModule("SpectrumFederation/modules/LootHelper/SyncProtocol.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/01_Constants.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/02_State.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/05_Scheduling.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/16_ProfileIntegration.lua")

function SF:GetPlayerFullIdentifier()
    return PLAYER
end

function SF:GetPlayerClass()
    return "WARRIOR"
end

function SF:PrintError()
end

function SF:PrintWarning()
end

function SF:PrintInfo()
end

SF.lootHelperDB = SpectrumFederationDB.lootHelper
SF.LootHelper = SF.LootHelper or {}
SF.LootHelper.GetDB = function()
    return SF.lootHelperDB
end

local Sync = SF.LootHelperSync
local Identity = SF.LootHelperIdentity

local function makeProfile()
    local profile = SF.LootProfile.new("Bench")
    SF.lootHelperDB.profiles[profile:GetProfileId()] = profile
    return profile
end

local function addMember(profile, memberId)
    local member = SF.Member.new(memberId, "member", "WARRIOR")
    assert(profile:AddMember(member))
    return member
end

local function addLog(profile, eventType, data, extra)
    extra = extra or {}
    local opts = {
        profile = profile,
        skipPermission = true,
        author = extra.author or PLAYER,
        timestamp = extra.timestamp,
        counter = extra.counter,
    }
    if opts.counter == nil then
        opts.counter = profile:AllocateNextCounter(opts.author)
    end
    local log = SF.LootLog.new(eventType, data, opts)
    assert(profile:AddLootLog(log, { skipPermission = true, skipBroadcast = true }))
    return log
end

local function clock()
    if os and os.clock then
        return os.clock()
    end
    return 0
end

local SIZES = { 100, 1000, 5000, 10000, 25000, 50000 }
local results = {}

io.stdout:write("F-02 identity replay benchmark (seconds, lua5.1)\n")
io.stdout:write(string.format("%10s %12s %12s %14s %s\n", "records", "OrderLogs", "Replay", "RebuildProfile", "assessment"))

for _, count in ipairs(SIZES) do
    local profile = makeProfile()
    addMember(profile, PLAYER)
    addLog(profile, SF.LootLogEventTypes.PROFILE_CREATION, { profileId = profile:GetProfileId() })
    local logs = profile._lootLogs
    for index = 1, count do
        local log = SF.LootLog.new(SF.LootLogEventTypes.POINT_CHANGE, {
            member = PLAYER,
            change = SF.LootLogPointChangeTypes.INCREMENT,
            amount = 1,
        }, {
            profile = profile,
            skipPermission = true,
            author = PLAYER,
            timestamp = 1700001000 + index,
            counter = index + 1,
        })
        logs[#logs + 1] = log
    end
    if profile.RebuildLogIndex then
        profile:RebuildLogIndex()
    end

    local logs = profile:GetLootLogs()
    local t0 = clock()
    local ordered = Identity.OrderLogs(logs)
    local orderMs = clock() - t0

    local t1 = clock()
    local replay = Identity.Replay(ordered, { owner = PLAYER })
    local replayMs = clock() - t1

    local t2 = clock()
    Sync:RebuildProfile(profile:GetProfileId(), "benchmark")
    local rebuildMs = clock() - t2

    local assessment = "negligible"
    if rebuildMs >= 2.0 then
        assessment = "serious multi-second risk"
    elseif rebuildMs >= 0.25 then
        assessment = "likely visible hitch"
    elseif rebuildMs >= 0.05 then
        assessment = "measurable but acceptable"
    end

    results[#results + 1] = {
        count = count,
        order = orderMs,
        replay = replayMs,
        rebuild = rebuildMs,
        assessment = assessment,
        traversed = #(ordered or {}),
        replayMembers = replay and replay.members and 1 or 0,
    }

    io.stdout:write(string.format("%10d %12.4f %12.4f %14.4f %s\n", count, orderMs, replayMs, rebuildMs, assessment))
    assertTrue(#(ordered or {}) >= count, "OrderLogs returned the generated history for " .. tostring(count))
    assertTrue(type(replay) == "table", "Replay returned a projection for " .. tostring(count))
end

local largest = results[#results]
assertTrue(largest ~= nil, "benchmark produced results")
assertTrue(largest.traversed >= 100, "largest run traversed the generated records")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
