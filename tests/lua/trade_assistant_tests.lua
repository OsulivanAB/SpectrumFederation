-- Production-Lua tests for the runtime-only /sf trade assistant (#269).
-- Run from the repository root: lua5.1 tests/lua/trade_assistant_tests.lua

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(message) .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. tostring(message) .. "\n")
end

local function assertTrue(cond, message)
    if cond then pass(message) else fail(message) end
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

local function contains(text, needle)
    return type(text) == "string" and text:find(needle, 1, true) ~= nil
end

function string.trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

function strtrim(s)
    return string.trim(s)
end

local LINK1 = "|cff00ff00|Hitem:123:0:0:0:0:0:80:::|h[Rune One]|h|r"
local LINK2 = "|cff0000ff|Hitem:456:0:0:0:0:0:80:::|h[Rune Two]|h|r"

local world
local frames = {}

local function resetWorld()
    world = {
        time = 100,
        inRaid = true,
        inCombat = false,
        self = { name = "Self", realm = "TestRealm" },
        raid = {
            { name = "Self", realm = "TestRealm" },
            { name = "Alice", realm = "TestRealm" },
            { name = "Bob", realm = "TestRealm" },
        },
        connected = { true, true, true },
        range = { true, true, true },
        bags = {},
        bagSlots = 3,
        reagentSlots = 0,
        cursor = nil,
        tradeSlots = {},
        placed = {},
        splits = {},
        pickups = {},
        afterFns = {},
        prints = {},
        errors = {},
        successes = {},
        initiated = {},
        tradeTarget = nil,
    }
    world.bags[0] = {
        [1] = { itemId = 123, count = 10, link = LINK1 },
        [2] = { itemId = 456, count = 5, link = LINK2 },
    }
    world.bags[5] = {}
end
resetWorld()

local function bagRow(bag, slot)
    local bagTable = world.bags[bag]
    return bagTable and bagTable[slot] or nil
end

local function raidIndex(unit)
    return tonumber(tostring(unit or ""):match("raid(%d+)"))
end

function GetRealmName()
    return "TestRealm"
end

function UnitFullName(unit)
    if unit == "player" then
        return world.self.name, world.self.realm
    end
    local index = raidIndex(unit)
    local player = index and world.raid[index] or nil
    if player then
        return player.name, player.realm
    end
    return nil
end

function UnitName(unit)
    if unit == "player" then
        return world.self.name, world.self.realm
    end
    if unit == "NPC" then
        if world.tradeTarget then
            return world.tradeTarget.name, world.tradeTarget.realm
        end
        return nil
    end
    local index = raidIndex(unit)
    local player = index and world.raid[index] or nil
    if player then
        return player.name, player.realm
    end
    return nil
end

function UnitExists(unit)
    local index = raidIndex(unit)
    return index ~= nil and world.raid[index] ~= nil
end

function UnitIsConnected(unit)
    local index = raidIndex(unit)
    return index ~= nil and world.connected[index] ~= false
end

function UnitIsUnit(unit, other)
    return other == "player" and unit == "raid1"
end

function UnitAffectingCombat()
    return world.inCombat
end

function InCombatLockdown()
    return false
end

function IsInRaid()
    return world.inRaid
end

function GetNumGroupMembers()
    return #world.raid
end

function CheckInteractDistance(unit, index)
    assertEq(index, 2, "trade range index")
    local raid = raidIndex(unit)
    if raid and world.range[raid] ~= nil then
        return world.range[raid]
    end
    return nil
end

function GetTime()
    return world.time
end

function GetItemInfoInstant(linkOrId)
    local id = tostring(linkOrId):match("item:(%d+)") or tostring(linkOrId):match("^(%d+)$")
    if id == "123" or id == "456" then
        return tonumber(id)
    end
    return nil
end

function GetItemInfo(itemId)
    if tonumber(itemId) == 123 then
        return "Rune One"
    elseif tonumber(itemId) == 456 then
        return "Rune Two"
    end
    return nil
end

C_Container = {
    GetContainerNumSlots = function(bag)
        if bag == 5 then
            return world.reagentSlots or 0
        end
        return bag == 0 and world.bagSlots or 0
    end,
    GetContainerItemInfo = function(bag, slot)
        local row = bagRow(bag, slot)
        if not row or (row.count or 0) <= 0 then
            return nil
        end
        return { itemID = row.itemId, stackCount = row.count, isLocked = row.locked == true }
    end,
    GetContainerItemLink = function(bag, slot)
        local row = bagRow(bag, slot)
        return row and row.link or nil
    end,
    SplitContainerItem = function(bag, slot, count)
        world.splits[#world.splits + 1] = { bag = bag, slot = slot, count = count }
        local row = bagRow(bag, slot)
        if not row or row.count < count then
            return
        end
        row.count = row.count - count
        world.cursor = { itemId = row.itemId, count = count, bag = bag, slot = slot }
    end,
    PickupContainerItem = function(bag, slot)
        world.pickups[#world.pickups + 1] = { bag = bag, slot = slot }
        local row = bagRow(bag, slot)
        if not row or row.count <= 0 then
            return
        end
        world.cursor = { itemId = row.itemId, count = row.count, bag = bag, slot = slot }
        row.count = 0
    end,
}

function GetCursorInfo()
    return world.cursor
end

function ClearCursor()
    world.cursor = nil
end

function GetTradePlayerItemInfo(slot)
    local item = world.tradeSlots[slot]
    if item then
        return "Trade Item"
    end
    return nil
end

function ClickTradeButton(slot)
    if not world.cursor then
        return
    end
    world.tradeSlots[slot] = world.cursor
    world.placed[#world.placed + 1] = {
        slot = slot,
        itemId = world.cursor.itemId,
        count = world.cursor.count,
    }
    world.cursor = nil
end

function InitiateTrade(unit)
    world.initiated[#world.initiated + 1] = unit
    if unit == "raid2" then
        world.tradeTarget = { name = "Alice", realm = "TestRealm" }
    elseif unit == "raid3" then
        world.tradeTarget = { name = "Bob", realm = "TestRealm" }
    end
end

C_Timer = {
    After = function(delay, fn)
        world.afterFns[#world.afterFns + 1] = fn
    end,
    NewTicker = function()
        return { Cancel = function() end }
    end,
}

function CreateFrame(kind, name)
    local frame = {
        kind = kind,
        name = name,
        events = {},
        scripts = {},
        shown = false,
    }
    function frame:RegisterEvent(event)
        self.events[event] = true
    end
    function frame:SetScript(event, fn)
        self.scripts[event] = fn
    end
    function frame:IsShown()
        return self.shown
    end
    function frame:Show()
        self.shown = true
    end
    function frame:Hide()
        self.shown = false
    end
    if name then
        frames[name] = frame
    end
    return frame
end

local SF = {}
function SF:PrintError(message)
    world.errors[#world.errors + 1] = tostring(message)
end
function SF:PrintInfo(message)
    world.prints[#world.prints + 1] = tostring(message)
end
function SF:PrintWarning(message)
    world.prints[#world.prints + 1] = tostring(message)
end
function SF:PrintSuccess(message)
    world.successes[#world.successes + 1] = tostring(message)
end

assert(loadfile("SpectrumFederation/locale/enUS.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/NameUtil.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/SlashCommands.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/TradeAssistant.lua"))("SpectrumFederation", SF)

local TA = SF.TradeAssistant
assertTrue(TA ~= nil, "TradeAssistant module loaded")
assertTrue(SF.SlashCommands.trade ~= nil, "trade slash command registered")
assertTrue(SF.SlashCommands.trade.preserveArgs == true, "trade command preserves item-link casing")

local function runAfter()
    local fns = world.afterFns
    world.afterFns = {}
    for _, fn in ipairs(fns) do
        fn()
    end
end

local function listenerFrame()
    return frames.SpectrumFederationTradeAssistant
end

local function resetAssistant()
    TA:ResetRuntime()
    world.tradeSlots = {}
    world.placed = {}
    world.splits = {}
    world.pickups = {}
    world.afterFns = {}
    world.initiated = {}
    world.tradeTarget = nil
    world.cursor = nil
end

-- Parsing preserves item-link casing and supports optional quantity.
do
    local item = TA:ParseCommand(LINK1 .. " 3")
    assertTrue(item ~= nil, "parse accepts item link with quantity")
    assertEq(item.itemId, 123, "parse extracts item id")
    assertEq(item.quantity, 3, "parse extracts quantity")
    assertEq(item.itemLink, LINK1, "parse preserves item link casing")

    local defaulted = TA:ParseCommand("456")
    assertTrue(defaulted ~= nil, "parse accepts bare item id")
    assertEq(defaulted.quantity, 1, "quantity defaults to 1")

    local badQty = TA:ParseCommand("not-an-item 0")
    assertTrue(badQty == nil, "invalid item is rejected")
end

-- Multiple commands merge into one row per raid member.
do
    resetAssistant()
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "first trade command queues")
    assertTrue(TA:HandleCommand(LINK2 .. " 2") == true, "second trade command queues")

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "each raid member appears once")
    assertEq(snapshot[1].name, "Alice", "first queued member is Alice")
    assertEq(snapshot[2].name, "Bob", "second queued member is Bob")
    assertEq(snapshot[1].itemCount, 2, "Alice has both queued item entries")
    assertEq(snapshot[1].totalQuantity, 3, "Alice total quantity is 3")
    assertEq(snapshot[2].itemCount, 2, "Bob has both queued item entries")

    assertTrue(TA:RemovePlayer("alice-wrongrealm") == false, "wrong realm does not match")
    assertTrue(TA:RemovePlayer("alice-testreallm") == false, "typo realm still does not match")
    assertTrue(TA:RemovePlayer("Alice-TestRealm") == true, "manual removal accepts canonical id")
    assertEq(#TA:GetQueueSnapshot(), 1, "manual removal leaves Bob queued")
end

-- Link color/display formatting is normalized to item data, not link presentation.
do
    resetWorld()
    resetAssistant()
    local altLink = "|cff123456|Hitem:123:0:0:0:0:0:80:::|h[Renamed Rune]|h|r"
    assertTrue(TA:HandleCommand(altLink .. " 1") == true, "reformatted item link queues")
    assertEq(#TA:GetQueueSnapshot(), 2, "reformatted item link queues raid members")
end

-- ID and link forms of the same item share inventory reservation.
do
    resetWorld()
    resetAssistant()
    world.bags[0][1].count = 2
    world.bags[0][2].count = 10
    assertTrue(TA:HandleCommand("123 1") == true, "id-form trade command queues")
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == false, "link form cannot overbook same item id")
    assertEq(#TA:GetQueueSnapshot(), 2, "overbook rejection leaves first queue intact")
end

-- Items carried only in the reagent bag are visible to queue and prefill.
do
    resetWorld()
    resetAssistant()
    world.bags[0][1].count = 0
    world.bags[0][2].count = 0
    world.reagentSlots = 1
    world.bags[5][1] = { itemId = 123, count = 4, link = LINK1 }
    assertTrue(TA:HandleCommand(LINK1 .. " 2") == true, "reagent bag stock queues")
    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "reagent bag player can trade")

    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 1, "reagent bag item is placed")
    assertEq(world.placed[1].count, 2, "reagent bag placed quantity is two")
    assertEq(world.bags[5][1].count, 2, "reagent bag stack is split correctly")
end

-- Insufficient carried inventory fails with only local chat feedback.
do
    resetWorld()
    resetAssistant()
    world.bags[0][1].count = 1
    world.errors = {}
    assertTrue(TA:HandleCommand(LINK1 .. " 2") == false, "insufficient inventory rejects command")
    assertEq(#TA:GetQueueSnapshot(), 0, "insufficient inventory queues nothing")
    assertEq(#world.errors, 1, "insufficient inventory prints one error")
    assertTrue(contains(world.errors[1], "SF Trade failed."), "insufficient inventory message is the failure message")
end

-- Clicking a queued player prefills every queued item; accepted trade removes only that player.
do
    resetAssistant()
    world.bags[0][1].count = 10
    world.bags[0][2].count = 5
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "prefill test queues item one")
    assertTrue(TA:HandleCommand(LINK2 .. " 2") == true, "prefill test queues item two")

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "in-range queued player can be traded")
    assertEq(world.initiated[#world.initiated], "raid2", "trade targets Alice's raid unit")

    local frame = listenerFrame()
    assertTrue(frame ~= nil, "trade listener frame exists")
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()

    assertEq(#world.placed, 2, "both queued item entries are placed")
    assertEq(world.placed[1].itemId, 123, "first placed item is item one")
    assertEq(world.placed[1].count, 1, "first placed quantity is one")
    assertEq(world.placed[2].itemId, 456, "second placed item is item two")
    assertEq(world.placed[2].count, 2, "second placed quantity is two")
    assertEq(world.bags[0][1].count, 9, "item one stack is split correctly")
    assertEq(world.bags[0][2].count, 3, "item two stack is split correctly")

    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 1, "completed trade removes only that player")
    assertEq(snapshot[1].name, "Bob", "Bob remains queued")
end

-- A declined/cancelled trade leaves the player queued.
do
    resetAssistant()
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "cancel test queues item")
    assertTrue(TA:TradeWithPlayer("Bob-TestRealm") == true, "Bob can be traded")

    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 0)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "cancelled trade keeps both players queued")
end

-- Out-of-range clicks do not initiate a trade.
do
    resetAssistant()
    world.range[3] = false
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "range test queues item")
    assertTrue(TA:TradeWithPlayer("Bob-TestRealm") == false, "out-of-range click is rejected")
    assertEq(#world.initiated, 0, "out-of-range click does not initiate trade")
    world.range[3] = true
end

-- Queue state is runtime-only and never touches SavedVariables.
do
    local source = assert(io.open("SpectrumFederation/modules/TradeAssistant.lua", "r")):read("*a")
    assertFalse(contains(source, "SpectrumFederationCharDB"), "TradeAssistant does not use character SavedVariables")
    assertFalse(contains(source, "SavedVariables"), "TradeAssistant does not reference SavedVariables")
    local windowSource = assert(io.open("SpectrumFederation/modules/UI/TradeAssistant/Window.lua", "r")):read("*a")
    assertFalse(contains(windowSource, "SpectrumFederationCharDB"), "Trade Assistant window does not use SavedVariables")
    assertFalse(contains(windowSource, "SavedVariables"), "Trade Assistant window does not reference SavedVariables")
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
