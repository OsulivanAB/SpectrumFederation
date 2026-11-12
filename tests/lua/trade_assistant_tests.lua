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
local LINK_VARIANT_A = "|cff00ff00|Hitem:123:0:0:0:0:0:81:::|h[Rune Variant A]|h|r"
local LINK_VARIANT_B = "|cff00ff00|Hitem:123:0:0:0:0:0:82:::|h[Rune Variant B]|h|r"
local LINK_VARIANT_SHARED_A = "|cff00ff00|Hitem:123:0:0:0:0:0:83:::|h[Shared Rune]|h|r"
local LINK_VARIANT_SHARED_B = "|cff00ff00|Hitem:123:0:0:0:0:0:84:::|h[Shared Rune]|h|r"

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
    local itemId = id and tonumber(id) or nil
    if itemId == 123 or itemId == 456 or (itemId and itemId >= 1001 and itemId <= 1007) then
        return itemId
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
        world.cursor = { itemId = row.itemId, count = count, bag = bag, slot = slot, link = row.link }
    end,
    PickupContainerItem = function(bag, slot)
        world.pickups[#world.pickups + 1] = { bag = bag, slot = slot }
        local row = bagRow(bag, slot)
        if not row or row.count <= 0 then
            return
        end
        world.cursor = { itemId = row.itemId, count = row.count, bag = bag, slot = slot, link = row.link }
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
        local name = "Trade Item"
        if type(item.link) == "string" then
            local bracket = item.link:match("%[([^%]]+)%]")
            if bracket and bracket ~= "" then
                name = bracket
            elseif not item.link:find("|H", 1, true) then
                name = tostring(item.itemId)
            end
        end
        return name, nil, item.count
    end
    return nil
end

function GetTradePlayerItemLink(slot)
    local item = world.tradeSlots[slot]
    if not item then
        return nil
    end
    if type(item.link) == "string" and item.link:find("|H", 1, true) then
        return item.link
    end
    local itemId = tonumber(item.itemId) or 0
    if itemId == 123 then
        return LINK1
    elseif itemId == 456 then
        return LINK2
    end
    return "|Hitem:" .. tostring(itemId) .. ":0:0:0:0:0:80:::|h[Item]|h|r"
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

    for _, malformed in ipairs({ LINK1 .. " -1", LINK1 .. " 1.5", LINK1 .. " soon", LINK1 .. " 0" }) do
        local parsed, err = TA:ParseCommand(malformed)
        assertTrue(parsed == nil and err == "invalid_quantity", "malformed quantity suffix is rejected")
    end

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

-- Exact link variants reserve inventory independently.
do
    resetWorld()
    resetAssistant()
    world.bagSlots = 4
    world.bags[0] = {
        [1] = { itemId = 123, count = 1, link = LINK_VARIANT_A },
        [2] = { itemId = 123, count = 1, link = LINK_VARIANT_A },
        [3] = { itemId = 123, count = 1, link = LINK_VARIANT_B },
        [4] = { itemId = 123, count = 1, link = LINK_VARIANT_B },
    }
    assertTrue(TA:HandleCommand(LINK_VARIANT_A .. " 1") == true, "variant reservation queues variant A")
    assertTrue(TA:HandleCommand(LINK_VARIANT_B .. " 1") == true, "variant reservation queues variant B")
    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "variant reservation keeps both raid members queued")
    assertEq(snapshot[1].itemCount, 2, "variant reservation keeps both entries for Alice")
    assertEq(snapshot[1].totalQuantity, 2, "variant reservation totals two for Alice")
    assertEq(snapshot[2].itemCount, 2, "variant reservation keeps both entries for Bob")
    assertEq(snapshot[2].totalQuantity, 2, "variant reservation totals two for Bob")
end

-- Planned moves do not reuse bag stacks across queued item entries.
do
    resetWorld()
    resetAssistant()
    world.bagSlots = 2
    world.bags[0] = {
        [1] = { itemId = 123, count = 2, link = LINK_VARIANT_A },
        [2] = { itemId = 123, count = 2, link = LINK_VARIANT_B },
    }
    assertTrue(TA:HandleCommand(LINK_VARIANT_A .. " 1") == true, "planned depletion queues variant A")
    assertTrue(TA:HandleCommand("123 1") == true, "planned depletion queues bare id")
    world.bags[0][1].count = 1
    world.bags[0][2].count = 1
    assertTrue(TA:TradeWithPlayer("Bob-TestRealm") == true, "planned depletion can trade Bob")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 2, "planned depletion places both items")
    assertEq(world.tradeSlots[1].link, LINK_VARIANT_A, "planned depletion reserves variant A slot")
    assertEq(world.tradeSlots[2].link, LINK_VARIANT_B, "planned depletion moves bare id to variant B")
end

-- Clicking a queued player prefills every queued item; accepted trade removes only that player.
do
    resetWorld()
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
    runAfter()

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 1, "completed trade removes only that player")
    assertEq(snapshot[1].name, "Bob", "Bob remains queued")
end

-- Player-first acceptance still settles when the trade closes without a cancel.
do
    resetWorld()
    resetAssistant()
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "player-first test queues item")
    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "player-first test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 1, "player-first prefill places item")

    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 0)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 1, "player-first completed trade removes Alice")
    assertEq(snapshot[1].name, "Bob", "Bob remains queued after player-first settlement")
end

-- Partial prefill settles only offered quantities and retains the rest.
do
    resetWorld()
    resetAssistant()
    world.bagSlots = 7
    world.bags[0] = {}
    for index = 1001, 1007 do
        world.bags[0][index - 1000] = { itemId = index, count = 5, link = tostring(index) }
        assertTrue(TA:HandleCommand(tostring(index) .. " 1") == true, "partial settlement queues item " .. index)
    end

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "partial settlement can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 6, "partial prefill places only six trade slots")

    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "partial settlement keeps both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice remains for unoffered items")
    assertEq(snapshot[1].itemCount, 1, "Alice retains one unoffered item entry")
    assertEq(snapshot[1].totalQuantity, 1, "Alice retains unoffered quantity")
    assertEq(snapshot[1].items[1].itemId, 1007, "Alice retains the seventh queued item")
    assertEq(snapshot[2].name, "Bob", "Bob remains queued after Alice partial settlement")
    assertEq(snapshot[2].itemCount, 7, "Bob keeps all seven queued item entries")
end

-- Edited trade offers settle only the accepted contents.
do
    resetWorld()
    resetAssistant()
    world.bags[0][1].count = 10
    world.bags[0][2].count = 5
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "edited offer test queues item one")
    assertTrue(TA:HandleCommand(LINK2 .. " 2") == true, "edited offer test queues item two")

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "edited offer test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 2, "edited offer prefill places both items")

    world.tradeSlots[2] = nil -- simulate removing the second offer before accepting
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "edited offer keeps both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice remains for the removed offer")
    assertEq(snapshot[1].itemCount, 1, "Alice retains only the unaccepted item")
    assertEq(snapshot[1].items[1].itemId, 456, "Alice retains item two")
    assertEq(snapshot[1].totalQuantity, 2, "Alice retains item two quantity")
    assertEq(snapshot[2].name, "Bob", "Bob remains fully queued after edited offer")
    assertEq(snapshot[2].itemCount, 2, "Bob keeps both queued item entries")
end

-- A queued item manually added after prefill settles from the final offer.
do
    resetWorld()
    resetAssistant()
    world.bagSlots = 7
    world.bags[0] = {}
    for index = 1001, 1007 do
        world.bags[0][index - 1000] = { itemId = index, count = 5, link = tostring(index) }
        assertTrue(TA:HandleCommand(tostring(index) .. " 1") == true, "manual add settlement queues item " .. index)
    end

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "manual add settlement can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 6, "manual add settlement prefill places six items")

    world.tradeSlots[1] = { itemId = 1007, count = 1 } -- manually replace the first offer with the unoffered item
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "manual add settlement keeps both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice remains for the replaced offer")
    assertEq(snapshot[1].itemCount, 1, "Alice retains only the replaced item entry")
    assertEq(snapshot[1].items[1].itemId, 1001, "Alice retains the replaced item")
    assertEq(snapshot[2].name, "Bob", "Bob remains queued after Alice manual add settlement")
    assertEq(snapshot[2].itemCount, 7, "Bob keeps all seven queued item entries")
end

-- Same-item variants settle by traded link, not by item ID order.
do
    resetWorld()
    resetAssistant()
    world.bags[0] = {
        [1] = { itemId = 123, count = 10, link = LINK_VARIANT_A },
        [2] = { itemId = 123, count = 10, link = LINK_VARIANT_B },
    }
    assertTrue(TA:HandleCommand(LINK_VARIANT_A .. " 1") == true, "variant test queues variant A")
    assertTrue(TA:HandleCommand(LINK_VARIANT_B .. " 1") == true, "variant test queues variant B")

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "variant test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 2, "variant prefill places both variants")
    assertEq(world.tradeSlots[1].link, LINK_VARIANT_A, "first trade slot holds variant A")
    assertEq(world.tradeSlots[2].link, LINK_VARIANT_B, "second trade slot holds variant B")

    world.tradeSlots[1] = nil -- remove variant A; variant B remains offered
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "variant settlement keeps both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice remains for variant A")
    assertEq(snapshot[1].itemCount, 1, "Alice retains only variant A")
    assertEq(snapshot[1].items[1].itemLink, LINK_VARIANT_A, "Alice retains the undelivered variant")
    assertEq(snapshot[2].name, "Bob", "Bob remains queued after Alice variant settlement")
    assertEq(snapshot[2].itemCount, 2, "Bob keeps both queued variants")
end

-- Missing trade links fall back to the prefill settlement snapshot.
do
    resetWorld()
    resetAssistant()
    world.bags[0][1].count = 10
    world.bags[0][2].count = 5
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "missing link test queues item one")
    assertTrue(TA:HandleCommand(LINK2 .. " 2") == true, "missing link test queues item two")

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "missing link test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 2, "missing link prefill places both items")

    local originalTradeLink = GetTradePlayerItemLink
    GetTradePlayerItemLink = function()
        return nil
    end
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()
    GetTradePlayerItemLink = originalTradeLink

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 1, "missing trade links still settle prefilled offers")
    assertEq(snapshot[1].name, "Bob", "Alice is removed after fallback settlement")
end

-- Missing links still respect offers removed before acceptance.
do
    resetWorld()
    resetAssistant()
    world.bags[0][1].count = 10
    world.bags[0][2].count = 5
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "missing link removal test queues item one")
    assertTrue(TA:HandleCommand(LINK2 .. " 2") == true, "missing link removal test queues item two")

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "missing link removal test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 2, "missing link removal prefill places both items")

    world.tradeSlots[1] = nil -- remove item one; item two remains offered
    local originalTradeLink = GetTradePlayerItemLink
    GetTradePlayerItemLink = function()
        return nil
    end
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()
    GetTradePlayerItemLink = originalTradeLink

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "missing link removal keeps both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice remains for the removed offer")
    assertEq(snapshot[1].itemCount, 1, "Alice retains only the removed offer")
    assertEq(snapshot[1].items[1].itemLink, LINK1, "Alice retains item one")
    assertEq(snapshot[2].name, "Bob", "Bob remains queued after missing link removal")
end

-- Missing-link captures refresh when offers change before reacceptance.
do
    resetWorld()
    resetAssistant()
    world.bags[0][1].count = 10
    world.bags[0][2].count = 5
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "reacceptance test queues item one")
    assertTrue(TA:HandleCommand(LINK2 .. " 2") == true, "reacceptance test queues item two")

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "reacceptance test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 2, "reacceptance prefill places both items")

    local originalTradeLink = GetTradePlayerItemLink
    GetTradePlayerItemLink = function()
        return nil
    end
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 0)
    world.tradeSlots[1] = nil -- remove item one before reaccepting
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()
    GetTradePlayerItemLink = originalTradeLink

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "reacceptance keeps both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice remains for the removed offer")
    assertEq(snapshot[1].itemCount, 1, "Alice retains only the removed offer")
    assertEq(snapshot[1].items[1].itemLink, LINK1, "Alice retains item one")
    assertEq(snapshot[2].name, "Bob", "Bob remains queued after reacceptance")
end

-- Missing-link fallback matches moved offers by name and quantity.
do
    resetWorld()
    resetAssistant()
    world.bags[0][1].count = 10
    world.bags[0][2].count = 5
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "moved offer test queues item one")
    assertTrue(TA:HandleCommand(LINK2 .. " 2") == true, "moved offer test queues item two")

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "moved offer test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 2, "moved offer prefill places both items")

    world.tradeSlots[3] = world.tradeSlots[2]
    world.tradeSlots[2] = nil -- move item two to another trade slot
    local originalTradeLink = GetTradePlayerItemLink
    GetTradePlayerItemLink = function()
        return nil
    end
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()
    GetTradePlayerItemLink = originalTradeLink

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 1, "moved offer still settles both items")
    assertEq(snapshot[1].name, "Bob", "Alice is removed after moved offer settlement")
end

-- Ambiguous same-name variants are not settled by missing-link fallbacks.
do
    resetWorld()
    resetAssistant()
    world.bags[0] = {
        [1] = { itemId = 123, count = 10, link = LINK_VARIANT_SHARED_A },
        [2] = { itemId = 123, count = 10, link = LINK_VARIANT_SHARED_B },
    }
    assertTrue(TA:HandleCommand(LINK_VARIANT_SHARED_A .. " 1") == true, "ambiguous variant test queues variant A")
    assertTrue(TA:HandleCommand(LINK_VARIANT_SHARED_B .. " 1") == true, "ambiguous variant test queues variant B")

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "ambiguous variant test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 2, "ambiguous variant prefill places both items")
    assertEq(world.tradeSlots[1].link, LINK_VARIANT_SHARED_A, "ambiguous first slot holds variant A")
    assertEq(world.tradeSlots[2].link, LINK_VARIANT_SHARED_B, "ambiguous second slot holds variant B")

    world.tradeSlots[1] = world.tradeSlots[2] -- move variant B into variant A's slot
    world.tradeSlots[2] = nil
    local originalTradeLink = GetTradePlayerItemLink
    GetTradePlayerItemLink = function()
        return nil
    end
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()
    GetTradePlayerItemLink = originalTradeLink

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "ambiguous variants keep both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice is not settled by an ambiguous variant")
    assertEq(snapshot[1].itemCount, 2, "Alice retains both ambiguous variants")
    assertEq(snapshot[2].name, "Bob", "Bob remains queued after ambiguous settlement")
end

-- Missing-link same-name fallback does not settle when the queue has an unoffered variant.
do
    resetWorld()
    resetAssistant()
    world.bagSlots = 2
    world.bags[0] = {
        [1] = { itemId = 123, count = 2, link = LINK_VARIANT_SHARED_A },
        [2] = { itemId = 123, count = 2, link = LINK_VARIANT_SHARED_B },
    }
    assertTrue(TA:HandleCommand(LINK_VARIANT_SHARED_A .. " 1") == true, "missing-link replacement test queues variant A")
    assertTrue(TA:HandleCommand(LINK_VARIANT_SHARED_B .. " 1") == true, "missing-link replacement test queues variant B")
    world.bags[0][2] = nil -- variant B is no longer available, so only A is prefilled

    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "missing-link replacement test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 1, "missing-link replacement prefill places only variant A")

    local originalTradeLink = GetTradePlayerItemLink
    GetTradePlayerItemLink = function()
        return nil
    end
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()
    GetTradePlayerItemLink = originalTradeLink

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "missing-link replacement keeps both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice is not settled by an incomplete identity set")
    assertEq(snapshot[1].itemCount, 2, "Alice retains both same-name variants")
    assertEq(snapshot[2].name, "Bob", "Bob remains queued after missing-link replacement")
end

-- Unchanged same-name variants settle by their original slots.
do
    resetWorld()
    resetAssistant()
    world.bagSlots = 3
    world.bags[0] = {
        [1] = { itemId = 123, count = 1, link = LINK_VARIANT_SHARED_A },
        [2] = { itemId = 123, count = 1, link = LINK_VARIANT_SHARED_A },
        [3] = { itemId = 123, count = 6, link = LINK_VARIANT_SHARED_B },
    }
    assertTrue(TA:HandleCommand(LINK_VARIANT_SHARED_A .. " 1") == true, "unchanged variant test queues variant A")
    assertTrue(TA:HandleCommand(LINK_VARIANT_SHARED_B .. " 2") == true, "unchanged variant test queues variant B")
    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "unchanged variant test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 2, "unchanged variant prefill places both items")
    assertEq(world.tradeSlots[1].link, LINK_VARIANT_SHARED_A, "first unchanged variant stays in slot one")
    assertEq(world.tradeSlots[2].link, LINK_VARIANT_SHARED_B, "second unchanged variant stays in slot two")

    local originalTradeLink = GetTradePlayerItemLink
    GetTradePlayerItemLink = function()
        return nil
    end
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()
    GetTradePlayerItemLink = originalTradeLink

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 1, "Alice is removed after unchanged variant settlement")
    assertEq(snapshot[1].name, "Bob", "Bob remains queued after unchanged variant settlement")
    assertEq(snapshot[1].itemCount, 2, "Bob retains both variant entries")
    assertEq(snapshot[1].totalQuantity, 3, "Bob retains both variant quantities")
end

-- Edited same-name variants do not settle removed stacks by quantity.
do
    resetWorld()
    resetAssistant()
    world.bagSlots = 5
    world.bags[0] = {
        [1] = { itemId = 123, count = 1, link = LINK_VARIANT_SHARED_A },
        [2] = { itemId = 123, count = 1, link = LINK_VARIANT_SHARED_A },
        [3] = { itemId = 123, count = 1, link = LINK_VARIANT_SHARED_A },
        [4] = { itemId = 123, count = 1, link = LINK_VARIANT_SHARED_A },
        [5] = { itemId = 123, count = 8, link = LINK_VARIANT_SHARED_B },
    }
    assertTrue(TA:HandleCommand(LINK_VARIANT_SHARED_A .. " 2") == true, "edited variant test queues variant A")
    assertTrue(TA:HandleCommand(LINK_VARIANT_SHARED_B .. " 2") == true, "edited variant test queues variant B")
    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "edited variant test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 3, "edited variant prefill places split A and B")

    world.tradeSlots = {
        [3] = { itemId = 123, count = 1, link = LINK_VARIANT_SHARED_B },
    }
    local originalTradeLink = GetTradePlayerItemLink
    GetTradePlayerItemLink = function()
        return nil
    end
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()
    GetTradePlayerItemLink = originalTradeLink

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "edited variant keeps both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice is not settled by removed variant stacks")
    assertEq(snapshot[1].itemCount, 2, "Alice retains both same-name variants")
    assertEq(snapshot[1].totalQuantity, 4, "Alice retains both variant quantities")
    assertEq(snapshot[2].name, "Bob", "Bob remains queued after edited variant settlement")
end

-- Identical missing-link stacks still settle by slot.
do
    resetWorld()
    resetAssistant()
    world.bagSlots = 4
    world.bags[0] = {
        [1] = { itemId = 123, count = 1, link = LINK1 },
        [2] = { itemId = 123, count = 1, link = LINK1 },
        [3] = { itemId = 123, count = 1, link = LINK1 },
        [4] = { itemId = 123, count = 1, link = LINK1 },
    }
    assertTrue(TA:HandleCommand(LINK1 .. " 2") == true, "identical stacks test queues item")
    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "identical stacks test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 2, "identical stacks prefill places both stacks")

    local originalTradeLink = GetTradePlayerItemLink
    GetTradePlayerItemLink = function()
        return nil
    end
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()
    GetTradePlayerItemLink = originalTradeLink

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 1, "identical stacks settle after delivery")
    assertEq(snapshot[1].name, "Bob", "Alice is removed after identical stack settlement")
end

-- Bare IDs resolve through C_Item when GetItemInfo is uncached.
do
    resetWorld()
    resetAssistant()
    world.bags[0][1].count = 10
    world.bags[0][2].count = 0
    local originalGetItemInfo = GetItemInfo
    local originalCItem = C_Item
    GetItemInfo = function()
        return nil
    end
    C_Item = {
        GetItemNameByID = function(itemId)
            if tonumber(itemId) == 123 then
                return "Rune One"
            end
            return nil
        end,
    }

    assertTrue(TA:HandleCommand("123 1") == true, "bare id test queues item")
    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "bare id test can trade Alice")
    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    assertEq(#world.placed, 1, "bare id prefill places item")

    local originalTradeLink = GetTradePlayerItemLink
    GetTradePlayerItemLink = function()
        return nil
    end
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()
    GetTradePlayerItemLink = originalTradeLink
    GetItemInfo = originalGetItemInfo
    C_Item = originalCItem

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 1, "bare id settles when name resolves through C_Item")
    assertEq(snapshot[1].name, "Bob", "Alice is removed after bare id settlement")
end

-- A close followed by cancel does not settle the trade.
do
    resetWorld()
    resetAssistant()
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "close-before-cancel test queues item one")
    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "close-before-cancel test can trade Alice")

    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 1)
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    frame.scripts.OnEvent(frame, "TRADE_REQUEST_CANCEL")
    runAfter()

    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "close followed by cancel keeps both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice remains queued after close-before-cancel")
    assertEq(snapshot[1].itemCount, 1, "Alice retains the cancelled item")
    assertEq(snapshot[2].name, "Bob", "Bob remains queued after close-before-cancel")
end

-- A cancelled request does not arm autofill for a later manual trade.
do
    resetWorld()
    resetAssistant()
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "cancelled-request test queues item")
    assertTrue(TA:TradeWithPlayer("Alice-TestRealm") == true, "cancelled-request test can request Alice")

    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_REQUEST_CANCEL")
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()

    assertEq(#world.placed, 0, "cancelled request does not prefill a later trade")
    local snapshot = TA:GetQueueSnapshot()
    assertEq(#snapshot, 2, "cancelled request keeps both players queued")
    assertEq(snapshot[1].name, "Alice", "Alice remains queued after cancelled request")
end

-- A declined/cancelled trade leaves the player queued.
do
    resetWorld()
    resetAssistant()
    assertTrue(TA:HandleCommand(LINK1 .. " 1") == true, "cancel test queues item")
    assertTrue(TA:TradeWithPlayer("Bob-TestRealm") == true, "Bob can be traded")

    local frame = listenerFrame()
    frame.scripts.OnEvent(frame, "TRADE_SHOW")
    runAfter()
    frame.scripts.OnEvent(frame, "TRADE_ACCEPT_UPDATE", 1, 0)
    frame.scripts.OnEvent(frame, "TRADE_REQUEST_CANCEL")
    frame.scripts.OnEvent(frame, "TRADE_CLOSED")
    runAfter()

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
