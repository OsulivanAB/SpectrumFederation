-- Production-Lua tests for Raid Equipment on a fresh install / no-profile player.
-- Run from the repository root: lua5.1 tests/lua/raid_equipment_fresh_snapshot_tests.lua

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

local function assertFalse(cond, message)
    assertTrue(not cond, message)
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

INVSLOT_HEAD = 1
INVSLOT_NECK = 2
INVSLOT_SHOULDER = 3
INVSLOT_CHEST = 5
INVSLOT_WAIST = 6
INVSLOT_LEGS = 7
INVSLOT_FEET = 8
INVSLOT_WRIST = 9
INVSLOT_HAND = 10
INVSLOT_FINGER1 = 11
INVSLOT_FINGER2 = 12
INVSLOT_TRINKET1 = 13
INVSLOT_TRINKET2 = 14
INVSLOT_BACK = 15
INVSLOT_MAINHAND = 16
INVSLOT_OFFHAND = 17

local notifyInspectCount = 0
local queuedInspectUnits = {}

function IsInRaid()
    return false
end

function IsInGroup()
    return false
end

function GetNumGroupMembers()
    return 0
end

function UnitFullName(unit)
    if unit == "player" then
        return "Freshplayer", "TestRealm"
    end
    return nil
end

function GetRealmName()
    return "TestRealm"
end

function UnitGUID(unit)
    if unit == "player" then
        return "Player-1-00000001"
    end
    return nil
end

function UnitExists(unit)
    return unit == "player"
end

function UnitIsUnit(a, b)
    return a == b
end

function UnitClass()
    return "Warrior", "WARRIOR"
end

function GetInventoryItemLink()
    return nil
end

function GetInventoryItemID()
    return nil
end

function GetInventoryItemTexture()
    return nil
end

function GetTime()
    return 1000
end

function GetServerTime()
    return 1000
end

function NotifyInspect(unit)
    notifyInspectCount = notifyInspectCount + 1
    queuedInspectUnits[#queuedInspectUnits + 1] = unit
end

function CreateFrame()
    return {
        RegisterEvent = function() end,
        SetScript = function() end,
        HookScript = function() end,
        Hide = function() end,
        Show = function() end,
    }
end

local SF = {}
function SF:GetActiveProfile()
    return nil
end

assert(loadfile("SpectrumFederation/modules/RaidCheck.lua"))("SpectrumFederation", SF)
local RC = SF.RaidCheck

local snapshot = RC:GetTroubleshootingSnapshot()
assertTrue(type(snapshot) == "table", "fresh-install snapshot returns a table")
assertFalse(snapshot.hasActiveProfile, "fresh install has no active Loot Helper profile")
assertEq(#(snapshot.rows or {}), 1, "solo player audit roster is the player only")
assertEq(snapshot.rows[1].unit, "player", "solo audit row is the local player")
assertEq(snapshot.rows[1].id, "Freshplayer-TestRealm", "player row uses the canonical name-realm id")
assertEq(#(snapshot.rows[1].slots or {}), 16, "audit row is bounded to the tracked equipment slots")
assertEq(notifyInspectCount, 0, "opening the snapshot does not call NotifyInspect")

local state = RC:_GetInspectState()
assertFalse(state.backgroundInspectEnabled, "auto/background inspect stays off by default")
assertEq(#state.queue, 0, "fresh snapshot does not enqueue inspects")
assertTrue(state.queued == nil or not next(state.queued), "fresh snapshot does not mark queued inspect keys")

-- A Loot Helper profile with extra members must not expand the solo audit roster.
local fakeMembers = {}
for i = 1, 40 do
    fakeMembers["Alt" .. i .. "-TestRealm"] = true
end
function SF:GetActiveProfile()
    return {
        members = fakeMembers,
        GetMembers = function()
            return fakeMembers
        end,
    }
end

RC._inspectState = nil
notifyInspectCount = 0
local profiled = RC:GetTroubleshootingSnapshot()
assertTrue(profiled.hasActiveProfile, "snapshot reports an active profile when one exists")
assertEq(#(profiled.rows or {}), 1, "active profile members are not added to the solo audit roster")
assertEq(profiled.rows[1].unit, "player", "profiled solo audit is still the local player")
assertEq(notifyInspectCount, 0, "active profile does not start inspects merely by building the snapshot")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
