-- Production-Lua tests for Loot Helper glance columns (#274).
-- Run from the repository root: lua5.1 tests/lua/roster_glance_tests.lua

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

function IsInRaid()
    return true
end

function GetNumGroupMembers()
    return 2
end

function GetRealmName()
    return "Garona"
end

function UnitFullName(unit)
    if unit == "raid1" then
        return "Alice", "Garona"
    end
    if unit == "raid2" then
        return "Bob", "Garona"
    end
    return nil
end

function UnitClass(unit)
    if unit == "raid1" then
        return "Mage", "MAGE"
    end
    return "Warrior", "WARRIOR"
end

local inspectQueued = 0
local SF = {
    LootHelperWindow = {},
    LootHelperBis = {
        SLOTS = {
            "Head", "Neck", "Shoulder", "Back", "Chest", "Bracers",
            "Hands", "Belt", "Pants", "Boots",
            "Ring1", "Ring2", "Trinket1", "Trinket2",
            "Weapon", "OffHand",
        },
        LiveOccupancyFromProjection = function(_, memberId)
            if memberId == "Alice-Garona" then
                return { Head = true, Chest = true, Ring1 = true, Ring2 = true, Weapon = true }
            end
            return {}
        end,
    },
    RaidCheck = {
        GetCachedEquipmentReadiness = function(_, unit, memberId)
            if memberId == "Alice-Garona" then
                return {
                    state = "not_ready",
                    tooltip = "Chest Enchant",
                }
            end
            return {
                state = "unknown",
                tooltip = "Current equipment readiness could not be determined.",
            }
        end,
        _QueueInspectForUnit = function()
            inspectQueued = inspectQueued + 1
        end,
    },
    NameUtil = {
        NormalizeNameRealm = function(id)
            return id
        end,
        SamePlayer = function(a, b)
            return a == b
        end,
    },
}

local function member(id, points)
    return {
        identifier = id,
        class = "MAGE",
        className = "MAGE",
        pointBalance = points,
        GetClass = function(self)
            return self.class
        end,
        GetPointBalance = function(self)
            return self.pointBalance
        end,
        GetFullIdentifier = function(self)
            return self.identifier
        end,
    }
end

local alice = member("Alice-Garona", 12)
local bob = member("Bob-Garona", 9)

local function makeProfile(rewardPot)
    return {
        _members = { alice, bob },
        IsRewardPotMode = function()
            return rewardPot
        end,
        IsCurrentUserAdmin = function()
            return true
        end,
        GetPointName = function()
            return "DKP"
        end,
        GetIdentityPoints = function(_, id)
            if id == "Alice-Garona" then
                return 12
            end
            return 9
        end,
        GetIdentityProjection = function()
            return { armor = {}, bis = { slotsByMember = {} } }
        end,
        GetRaidCheckAttendanceDisplay = function(_, id)
            if id == "Alice-Garona" then
                return "96%"
            end
            return "—"
        end,
        getMemberIds = function(self)
            return { "Alice-Garona", "Bob-Garona" }
        end,
        getMemberByID = function(_, id)
            if id == "Alice-Garona" then
                return alice
            end
            return bob
        end,
    }
end

local modelChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/RosterModel.lua"))
modelChunk("SpectrumFederation", SF)
local Model = SF.LootHelperWindow.RosterModel

local rows, _ = Model:Build(makeProfile(false))
assertEq(#rows, 2, "point-based roster includes both profile members")
local aliceRow, bobRow
for i = 1, #rows do
    if rows[i].memberId == "Alice-Garona" then
        aliceRow = rows[i]
    else
        bobRow = rows[i]
    end
end
assertTrue(aliceRow.showPoints, "point-based mode shows the Points column")
assertEq(aliceRow.pointName, "DKP", "point column uses the configured point name")
assertEq(aliceRow.points, 12, "point-based row shows identity points")
assertEq(aliceRow.attendanceText, "96%", "attendance percent comes from presence history")
assertEq(aliceRow.bisText, "5/16", "BiS uses canonical occupied slots out of Bis.SLOTS")
assertEq(aliceRow.readinessState, "not_ready", "readiness uses cached equipment evaluation")
assertEq(aliceRow.readinessTooltip, "Chest Enchant", "not-ready tooltip reuses Policy missing reasons")
assertEq(bobRow.attendanceText, "—", "player with no presence history shows an em dash")
assertEq(bobRow.bisText, "0/16", "unused BiS board is 0/16")
assertEq(bobRow.readinessState, "unknown", "missing cache is Unknown rather than Not Ready")

local potRows = Model:Build(makeProfile(true))
assertEq(#potRows, 2, "reward pot roster still lists members")
assertTrue(not potRows[1].showPoints and not potRows[2].showPoints, "reward pot hides the Points column")
assertEq(potRows[1].attendanceText ~= nil and potRows[1].attendanceText ~= "", true, "attendance column remains in reward pot")

assertEq(inspectQueued, 0, "roster build does not queue inspects")

function IsInRaid()
    return false
end
SF.SettingsStore = {
    Get = function(_, path)
        if path == "lootHelper.showMembersNotInRaid" then
            return true
        end
        return nil
    end,
}
local outOfRaidRows, outOfRaidMeta = Model:Build(makeProfile(false))
assertEq(#outOfRaidRows, 2, "showMembersNotInRaid lists profile members outside a raid")
assertTrue(outOfRaidRows[1].sortKey ~= nil and outOfRaidRows[1].sortKey ~= "", "out-of-raid rows have a sort key")
assertTrue(outOfRaidMeta.emptyText == nil, "populated out-of-raid roster has no empty-state copy")

SF.SettingsStore.Get = function()
    return false
end
local hiddenRows, hiddenMeta = Model:Build(makeProfile(false))
assertEq(#hiddenRows, 0, "setting off hides profile members outside a raid")
assertTrue(
    type(hiddenMeta.emptyText) == "string" and hiddenMeta.emptyText:find("Show Members not in raid", 1, true) ~= nil,
    "empty copy tells the player to enable the setting"
)

SF.SettingsStore.Get = function()
    return true
end
local boomProfile = makeProfile(false)
function boomProfile:GetIdentityPoints()
    error("identity boom")
end
function boomProfile:GetRaidCheckAttendanceDisplay()
    error("attendance boom")
end
local reportedErrors = {}
function geterrorhandler()
    return function(message)
        reportedErrors[#reportedErrors + 1] = tostring(message)
    end
end
local originalReady = SF.RaidCheck.GetCachedEquipmentReadiness
function SF.RaidCheck:GetCachedEquipmentReadiness()
    error("UnitGUID(): Invalid unit")
end
local boomRows = Model:Build(boomProfile)
assertEq(#boomRows, 2, "glance helper errors do not wipe the out-of-raid roster")
assertEq(boomRows[1].readinessState, "unknown", "failed readiness falls back to unknown")
assertTrue(#reportedErrors >= 2, "caught glance errors are forwarded to geterrorhandler")
SF.RaidCheck.GetCachedEquipmentReadiness = originalReady

function IsInRaid()
    return true
end

local raidCheck = (io.open("SpectrumFederation/modules/RaidCheck.lua", "r")):read("*a")
assertTrue(raidCheck:find("function RC:GetCachedEquipmentReadiness", 1, true) ~= nil, "read-only readiness API exists")
local api = raidCheck:match("function RC:GetCachedEquipmentReadiness.-function RC:")
if not api then
    api = raidCheck:match("function RC:GetCachedEquipmentReadiness.*")
end
assertTrue(api and not api:find("_QueueInspectForUnit", 1, true), "cached readiness does not queue inspects")
assertTrue(raidCheck:find("RecordRaidCheckPresence", 1, true) ~= nil, "Raid Check records presence on raid-mode consequences")
assertTrue(raidCheck:find('if not unit or type(unit) ~= "string"', 1, true) ~= nil, "UnitGUID helper rejects a nil unit")
assertTrue(api and api:find("unit and self:_GetInspectAliases", 1, true) ~= nil, "cached readiness does not inspect with a nil unit")

local controllerSource = (io.open("SpectrumFederation/modules/UI/LootHelper/Controller.lua", "r")):read("*a")
assertTrue(controllerSource:find("RegisterTroubleshootingListener", 1, true) ~= nil, "roster listens for equipment-cache updates")
assertTrue(controllerSource:find("SetBackgroundInspectEnabled", 1, true) == nil, "loot helper does not enable background inspect")
assertTrue(controllerSource:find('reason == "tooltip"', 1, true) ~= nil, "roster ignores tooltip-driven troubleshooting notifies")
assertTrue(controllerSource:find("IsMinimized", 1, true) ~= nil, "roster refresh checks Window:IsMinimized")

local raidCheckSource = raidCheck
assertTrue(raidCheckSource:find('_NotifyTroubleshootingListeners(false, "tooltip")', 1, true) ~= nil, "tooltip refresh passes a tooltip reason")

local viewChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/RosterView.lua"))
viewChunk("SpectrumFederation", SF)
local View = SF.LootHelperWindow.RosterView
local readyCols = View.GlanceColumns({ type = "PROFILE_MEMBER", showPoints = true, readinessState = "ready" })
assertTrue(readyCols.readiness, "ready rows still reserve the readiness column")
assertTrue(readyCols.points, "point-based ready rows still reserve the points column")
local unknownCols = View.GlanceColumns({ type = "PROFILE_MEMBER", showPoints = false, readinessState = "unknown" })
assertTrue(unknownCols.readiness, "unknown rows reserve the same readiness column")
assertTrue(not unknownCols.points, "reward pot rows still hide points")
local nonMemberCols = View.GlanceColumns({ type = "RAID_NONMEMBER" })
assertTrue(not nonMemberCols.readiness, "raid non-members do not reserve glance columns")

local rosterBuilds = 0
local readinessCallbacks = {}
local minimized = false
local shown = true
SF.RaidCheck.RegisterTroubleshootingListener = function(_, key, callback)
    readinessCallbacks[key] = callback
end
SF.RaidCheck.UnregisterTroubleshootingListener = function(_, key)
    readinessCallbacks[key] = nil
end
SF.LootHelperWindow.RosterModel = {
    Build = function()
        rosterBuilds = rosterBuilds + 1
        return {}, {}
    end,
}
SF.LootHelperWindow.Window = {
    GetFrame = function()
        return {
            IsShown = function()
                return shown
            end,
        }
    end,
    IsMinimized = function()
        return minimized
    end,
    ToggleMinimized = function()
        minimized = not minimized
        if SF.LootHelperWindow.Controller.OnMinimizedStateChanged then
            SF.LootHelperWindow.Controller:OnMinimizedStateChanged(minimized)
        end
    end,
    SetProfileName = function() end,
    SetPointName = function() end,
    SetRewardPotHeader = function() end,
    SetPlayButtonVisible = function() end,
    SetSessionActive = function() end,
}

local controllerChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/Controller.lua"))
controllerChunk("SpectrumFederation", SF)
local Controller = SF.LootHelperWindow.Controller

rosterBuilds = 0
minimized = false
shown = true
Controller:RefreshRoster()
assertEq(rosterBuilds, 1, "visible expanded roster still builds")

rosterBuilds = 0
minimized = true
Controller:RefreshRoster()
assertEq(rosterBuilds, 0, "minimized window does not rebuild the roster")

rosterBuilds = 0
minimized = false
shown = false
Controller:RefreshRoster()
assertEq(rosterBuilds, 0, "hidden window still does not rebuild the roster")

shown = true
minimized = false
Controller._readinessListenerBound = false
Controller:_BindReadinessListener()
assertTrue(readinessCallbacks.lootHelperRoster ~= nil, "readiness listener is registered")

rosterBuilds = 0
readinessCallbacks.lootHelperRoster(1, "tooltip")
assertEq(rosterBuilds, 0, "tooltip notify does not rebuild the roster")

rosterBuilds = 0
readinessCallbacks.lootHelperRoster(2, nil)
assertEq(rosterBuilds, 1, "equipment-cache notify still rebuilds the roster")

rosterBuilds = 0
minimized = false
Controller:OnMinimizeClicked()
assertTrue(minimized, "minimize click toggles minimized")
assertTrue(readinessCallbacks.lootHelperRoster == nil, "minimized window unbinds the readiness listener")
assertEq(rosterBuilds, 0, "minimize does not rebuild the hidden roster")

rosterBuilds = 0
Controller:OnMinimizeClicked()
assertTrue(not minimized, "second minimize click restores")
assertTrue(readinessCallbacks.lootHelperRoster ~= nil, "restore rebinds the readiness listener")
assertEq(rosterBuilds, 1, "restore rebuilds the roster once")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
