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

local raidCheck = (io.open("SpectrumFederation/modules/RaidCheck.lua", "r")):read("*a")
assertTrue(raidCheck:find("function RC:GetCachedEquipmentReadiness", 1, true) ~= nil, "read-only readiness API exists")
local api = raidCheck:match("function RC:GetCachedEquipmentReadiness.-function RC:")
if not api then
    api = raidCheck:match("function RC:GetCachedEquipmentReadiness.*")
end
assertTrue(api and not api:find("_QueueInspectForUnit", 1, true), "cached readiness does not queue inspects")
assertTrue(raidCheck:find("RecordRaidCheckPresence", 1, true) ~= nil, "Raid Check records presence on raid-mode consequences")

local controller = (io.open("SpectrumFederation/modules/UI/LootHelper/Controller.lua", "r")):read("*a")
assertTrue(controller:find("RegisterTroubleshootingListener", 1, true) ~= nil, "roster listens for equipment-cache updates")
assertTrue(controller:find("SetBackgroundInspectEnabled", 1, true) == nil, "loot helper does not enable background inspect")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
