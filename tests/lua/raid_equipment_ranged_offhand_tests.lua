-- Raid Check and Raid Equipment must share the empty-Off-Hand verdict.
-- Run from the repository root: lua5.1 tests/lua/raid_equipment_ranged_offhand_tests.lua

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

local function assertHas(list, value, message)
    for i = 1, #(list or {}) do
        if list[i] == value then
            pass(message)
            return
        end
    end
    fail(message .. " (missing " .. tostring(value) .. ")")
end

local function assertNotHas(list, value, message)
    for i = 1, #(list or {}) do
        if list[i] == value then
            fail(message .. " (unexpected " .. tostring(value) .. ")")
            return
        end
    end
    pass(message)
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

function strsplit(sep, text)
    local result = {}
    local start = 1
    local sepLen = string.len(sep)
    while true do
        local found = string.find(text, sep, start, true)
        if not found then
            result[#result + 1] = string.sub(text, start)
            break
        end
        result[#result + 1] = string.sub(text, start, found - 1)
        start = found + sepLen
    end
    return unpack(result)
end

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
        return "Hunter", "TestRealm"
    end
    return nil
end

function GetRealmName()
    return "TestRealm"
end

function UnitGUID(unit)
    if unit == "player" then
        return "Player-1-00000002"
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
    return "Hunter", "HUNTER"
end

function GetTime()
    return 1000
end

function GetServerTime()
    return 1000
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

local items = {}
local equipped = {}

local function defineItem(itemId, equipLoc, classId, subClassId)
    items[itemId] = {
        equipLoc = equipLoc,
        classId = classId,
        subClassId = subClassId,
    }
end

function GetItemInfoInstant(item)
    local itemId = item
    if type(item) == "string" then
        itemId = tonumber(item:match("item:(%d+)"))
    end
    local info = items[tonumber(itemId)]
    if not info then
        return nil
    end
    return itemId, "Weapon", "Subclass", info.equipLoc, 1, info.classId, info.subClassId
end

function GetInventoryItemLink(unit, slot)
    local itemId = equipped[slot]
    if not itemId then
        return nil
    end
    return string.format("|cffa335ee|Hitem:%d:1:0:0:0:0:0:0:80:0:0:0:0|h[Item]|h|r", itemId)
end

function GetInventoryItemID(unit, slot)
    return equipped[slot]
end

function GetInventoryItemTexture(unit, slot)
    if equipped[slot] then
        return "tex"
    end
    return nil
end

defineItem(101, "INVTYPE_HEAD", 4, 1)
defineItem(102, "INVTYPE_NECK", 4, 0)
defineItem(103, "INVTYPE_SHOULDER", 4, 1)
defineItem(105, "INVTYPE_CHEST", 4, 1)
defineItem(106, "INVTYPE_WAIST", 4, 1)
defineItem(107, "INVTYPE_LEGS", 4, 1)
defineItem(108, "INVTYPE_FEET", 4, 1)
defineItem(109, "INVTYPE_WRIST", 4, 1)
defineItem(110, "INVTYPE_HAND", 4, 1)
defineItem(111, "INVTYPE_FINGER", 4, 0)
defineItem(112, "INVTYPE_FINGER", 4, 0)
defineItem(113, "INVTYPE_TRINKET", 4, 0)
defineItem(114, "INVTYPE_TRINKET", 4, 0)
defineItem(115, "INVTYPE_CLOAK", 4, 1)
defineItem(201, "INVTYPE_RANGED", 2, 2) -- bow
defineItem(202, "INVTYPE_RANGEDRIGHT", 2, 3) -- gun
defineItem(203, "INVTYPE_RANGED", 2, 18) -- crossbow
defineItem(204, "INVTYPE_2HWEAPON", 2, 1) -- two-hand axe
defineItem(205, "INVTYPE_RANGEDRIGHT", 2, 19) -- wand
defineItem(206, "INVTYPE_WEAPONMAINHAND", 2, 0) -- one-hand axe
defineItem(207, "INVTYPE_SHIELD", 4, 6)
defineItem(208, "INVTYPE_RANGED", nil, nil) -- unresolved ranged identity
defineItem(209, "INVTYPE_WEAPONOFFHAND", 2, 7)

local function wearArmor()
    equipped = {
        [1] = 101,
        [2] = 102,
        [3] = 103,
        [5] = 105,
        [6] = 106,
        [7] = 107,
        [8] = 108,
        [9] = 109,
        [10] = 110,
        [11] = 111,
        [12] = 112,
        [13] = 113,
        [14] = 114,
        [15] = 115,
    }
end

local SF = {}
function SF:GetActiveProfile()
    return nil
end

function SF:GetPlayerFullIdentifier()
    return "Hunter-TestRealm"
end

assert(loadfile("SpectrumFederation/modules/LootHelper/SpecWeapons.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/RaidEquipment/Policy.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/RaidCheck.lua"))("SpectrumFederation", SF)
local RC = SF.RaidCheck

local function slotByInventory(slots, inventorySlot)
    for i = 1, #(slots or {}) do
        if slots[i].inventorySlot == inventorySlot then
            return slots[i]
        end
    end
    return nil
end

local function evaluate(label)
    RC:_InvalidateLocalTroubleshootingSnapshot()
    local snapshot = RC:GetTroubleshootingSnapshot()
    local row = snapshot.rows and snapshot.rows[1]
    assertTrue(type(row) == "table", label .. " audit row exists")
    local offHand = slotByInventory(row and row.slots, INVSLOT_OFFHAND)
    assertTrue(type(offHand) == "table", label .. " off-hand audit slot exists")
    local readiness = RC:GetCachedEquipmentReadiness("player")
    return offHand, readiness
end

local function assertAgreesPrepared(label)
    local offHand, readiness = evaluate(label)
    assertEq(readiness.state, "ready", label .. " readiness is ready")
    assertNotHas(readiness.missing, "Off Hand Item", label .. " readiness does not list Off Hand Item")
    assertEq(offHand.missingItem, false, label .. " audit slot does not flag a missing off hand")
    assertEq(offHand.missingEnchant, false, label .. " empty off hand does not require an enchant")
end

wearArmor()
equipped[16] = 201
assertAgreesPrepared("hunter bow")

wearArmor()
equipped[16] = 202
assertAgreesPrepared("hunter gun")

wearArmor()
equipped[16] = 203
assertAgreesPrepared("hunter crossbow")

wearArmor()
equipped[16] = 204
assertAgreesPrepared("two-hand weapon")

wearArmor()
equipped[16] = 205
local wandSlot, wandReady = evaluate("wand")
assertEq(wandReady.state, "not_ready", "wand with an empty off hand is not ready")
assertHas(wandReady.missing, "Off Hand Item", "wand readiness reports Off Hand Item")
assertEq(wandSlot.missingItem, true, "wand audit slot flags the missing off hand")

wearArmor()
equipped[16] = 206
local oneHandSlot, oneHandReady = evaluate("one-hand weapon")
assertEq(oneHandReady.state, "not_ready", "one-hand weapon with an empty off hand is not ready")
assertHas(oneHandReady.missing, "Off Hand Item", "one-hand readiness reports Off Hand Item")
assertEq(oneHandSlot.missingItem, true, "one-hand audit slot flags the missing off hand")

wearArmor()
equipped[16] = 206
equipped[17] = 207
local shieldSlot, shieldReady = evaluate("one-hand and shield")
assertEq(shieldReady.state, "ready", "shield off hand is ready without a weapon enchant")
assertNotHas(shieldReady.missing, "Off Hand Item", "equipped shield is not a missing off hand")
assertNotHas(shieldReady.missing, "Off Hand Enchant", "shield enchant rule is unchanged")
assertEq(shieldSlot.missingItem, false, "shield audit slot is not missing")
assertEq(shieldSlot.missingEnchant, false, "shield audit slot does not expect a weapon enchant")

wearArmor()
equipped[16] = 206
equipped[17] = 209
local weaponOffHand, weaponReady = evaluate("one-hand and off-hand weapon")
assertEq(weaponReady.state, "ready", "enchanted off-hand weapon is ready")
assertEq(weaponOffHand.missingItem, false, "equipped off-hand weapon is not missing")
assertEq(weaponOffHand.missingEnchant, false, "enchanted off-hand weapon satisfies the enchant rule")

wearArmor()
equipped[16] = 208
local pendingSlot, pendingReady = evaluate("unresolved ranged weapon")
assertEq(pendingReady.state, "unknown", "unresolved ranged weapon stays unknown")
assertNotHas(pendingReady.missing, "Off Hand Item", "unresolved ranged readiness does not list Off Hand Item")
assertEq(pendingSlot.missingItem, false, "unresolved ranged audit slot does not flag a missing off hand")
assertEq(pendingSlot.itemDataPending, true, "unresolved ranged audit slot stays pending")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
