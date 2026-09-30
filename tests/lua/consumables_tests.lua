-- Production-Lua tests for Raid Consumables v1: Member -> configured Guild Bank tab -> done.
-- Run from the repository root: lua5.1 tests/lua/consumables_tests.lua

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
    if cond then fail(message) else pass(message) end
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

-- ---------------------------------------------------------------------------
-- Simulated WoW client state. Globals below read from `world` so each check can
-- reset it and describe bags, guild bank tabs, cursor, combat, and timers.
-- ---------------------------------------------------------------------------

local world

local function resetWorld()
    world = {
        self = "Donor-Realm",
        clubId = "club-1",
        guildName = "Spectrum",
        guildRealm = "Realm",
        bankOpen = false,
        currentTab = 2,
        canDeposit = { true, true, true, true, true, true, true, true },
        numSlots = 4,
        bagSlots = 4,
        bags = {},
        bank = {},
        cursor = nil,
        cursorBroken = false,
        maxStack = 20,
        places = {},
        splits = {},
        withdrawAttempts = 0,
        acceptPlaces = nil,
        inCombat = false,
        mobileKnown = false,
        mobileCooldown = false,
        bindTypes = {},
        unknownItems = {},
        loadRequests = {},
        after = {},
        timers = {},
        warnings = {},
        infos = {},
        activeProfile = nil,
    }
end
resetWorld()

local function bagSlot(bag, slot)
    local b = world.bags[bag]
    return b and b[slot] or nil
end

local function bankSlot(tab, slot)
    local t = world.bank[tab]
    return t and t[slot] or nil
end

C_Container = {
    GetContainerNumSlots = function() return world.bagSlots end,
    GetContainerItemInfo = function(bag, slot)
        local row = bagSlot(bag, slot)
        if not row or (row.count or 0) <= 0 then return nil end
        return { itemID = row.itemId, stackCount = row.count, isLocked = row.locked == true }
    end,
    SplitContainerItem = function(bag, slot, count)
        world.splits[#world.splits + 1] = { bag = bag, slot = slot, count = count }
        local row = bagSlot(bag, slot)
        if not row or row.count < count then return end
        row.count = row.count - count
        world.cursor = { itemId = row.itemId, count = count, bag = bag, slot = slot }
    end,
    PickupContainerItem = function(bag, slot)
        local row = bagSlot(bag, slot)
        if not row or row.count <= 0 then return end
        world.cursor = { itemId = row.itemId, count = row.count, bag = bag, slot = slot }
        row.count = 0
    end,
}

function GetCursorInfo()
    if world.cursorBroken or not world.cursor then return nil end
    return "item", world.cursor.itemId
end

function PickupGuildBankItem(tab, slot)
    world.places[#world.places + 1] = { tab = tab, slot = slot }
    local cursor = world.cursor
    if not cursor then
        world.withdrawAttempts = world.withdrawAttempts + 1
        return
    end
    world.cursor = nil
    local accept = world.acceptPlaces == nil or #world.places <= world.acceptPlaces
    if not accept then
        local origin = bagSlot(cursor.bag, cursor.slot)
        origin.count = origin.count + cursor.count
        return
    end
    world.bank[tab] = world.bank[tab] or {}
    local target = world.bank[tab][slot]
    if target then
        target.count = target.count + cursor.count
    else
        world.bank[tab][slot] = { itemId = cursor.itemId, count = cursor.count }
    end
end

function GetGuildBankNumSlots() return world.numSlots end
function GetGuildBankItemLink(tab, slot)
    local row = bankSlot(tab, slot)
    if not row or row.count <= 0 then return nil end
    return "|Hitem:" .. tostring(row.itemId) .. "::|h[Item]|h"
end
function GetGuildBankItemInfo(tab, slot)
    local row = bankSlot(tab, slot)
    return nil, row and row.count or 0
end
function GetGuildBankTabInfo(tab)
    return "Tab " .. tostring(tab), "icon", true, world.canDeposit[tab]
end
function GetCurrentGuildBankTab() return world.currentTab end
GuildBankFrame = { IsShown = function() return world.bankOpen end }
C_Club = { GetGuildClubId = function() return world.clubId end }
function GetGuildInfo() return world.guildName, nil, nil, world.guildRealm end
function IsPlayerSpell() return world.mobileKnown end
C_Spell = {
    GetSpellInfo = function() return { name = "Mobile Banking" } end,
    GetSpellCooldown = function() return { duration = world.mobileCooldown and 30 or 0 } end,
}
C_Item = {
    GetItemInfo = function(itemId)
        if world.unknownItems[itemId] then return nil end
        return "Item" .. tostring(itemId), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
            world.bindTypes[itemId]
    end,
    GetItemMaxStackSizeByID = function() return world.maxStack end,
    RequestLoadItemDataByID = function(itemId)
        world.loadRequests[#world.loadRequests + 1] = itemId
    end,
}
function InCombatLockdown() return world.inCombat end
function GetTime() return 100 end
C_Timer = {
    After = function(_, fn)
        world.after[#world.after + 1] = fn
    end,
    NewTimer = function(_, fn)
        local handle = { fn = fn, cancelled = false }
        function handle:Cancel() self.cancelled = true end
        world.timers[#world.timers + 1] = handle
        return handle
    end,
}

local function drainAfter(limit)
    limit = limit or 64
    local ran = 0
    while #world.after > 0 and ran < limit do
        ran = ran + 1
        table.remove(world.after, 1)()
    end
    return ran
end

local function liveTimers()
    local live = {}
    for i = 1, #world.timers do
        if not world.timers[i].cancelled then live[#live + 1] = world.timers[i] end
    end
    return live
end

local function fireTimers()
    local live = liveTimers()
    for i = 1, #live do
        live[i].cancelled = true
        live[i].fn()
    end
    return #live
end

local frameCount = 0
local FrameMethods = {}
local function FrameMock(kind, parent)
    frameCount = frameCount + 1
    return setmetatable({ kind = kind, parent = parent, scripts = {}, hooks = {}, shown = true, enabled = true, text = "" },
        { __index = FrameMethods })
end
local function noop() end
for _, name in ipairs({
    "SetSize", "SetPoint", "ClearAllPoints", "SetAllPoints", "SetFrameStrata", "EnableMouse", "SetMovable",
    "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetBackdrop", "SetJustifyH", "SetWidth",
    "SetHeight", "SetAutoFocus", "SetNumeric", "ClearFocus", "SetScrollChild", "SetAttribute", "RegisterEvent",
}) do
    FrameMethods[name] = noop
end
function FrameMethods:GetLeft() return 100 end
function FrameMethods:GetBottom() return 200 end
function FrameMethods:SetScript(name, fn) self.scripts[name] = fn end
function FrameMethods:HookScript(name, fn)
    self.hooks[name] = self.hooks[name] or {}
    table.insert(self.hooks[name], fn)
end
function FrameMethods:SetText(text) self.text = text end
function FrameMethods:GetText() return self.text end
function FrameMethods:Show() self.shown = true end
function FrameMethods:Hide() self.shown = false end
function FrameMethods:IsShown() return self.shown == true end
function FrameMethods:SetShown(shown) self.shown = shown and true or false end
function FrameMethods:Enable() self.enabled = true end
function FrameMethods:Disable() self.enabled = false end
function FrameMethods:IsEnabled() return self.enabled end
function FrameMethods:CreateFontString() return FrameMock("FontString", self) end
function CreateFrame(kind, _, parent) return FrameMock(kind, parent) end
UIParent = FrameMock("Frame")

-- ---------------------------------------------------------------------------
-- SF namespace and production modules
-- ---------------------------------------------------------------------------

local SF = {
    Debug = {
        Info = function() end,
        Warn = function() end,
        Error = function() end,
        Verbose = function() end,
    },
}
function SF:GetActiveProfile() return world.activeProfile end
function SF:PrintWarning(text) world.warnings[#world.warnings + 1] = text end
function SF:PrintInfo(text) world.infos[#world.infos + 1] = text end
SF.lootHelperDB = { profiles = {} }
SF.NameUtil = { GetSelfId = function() return world.self end }
SF.SettingsStore = { values = {} }
function SF.SettingsStore:Get(key) return self.values[key] end

local reminderCalls = {}
SF.LootHelperWindow = { _frame = FrameMock("Frame") }
function SF.LootHelperWindow:SetSupplyReminder(visible, onOpen, onDismiss)
    reminderCalls[#reminderCalls + 1] = { visible = visible, onOpen = onOpen, onDismiss = onDismiss }
end

local clock = 1000
local function load(path)
    local chunk = assert(loadfile(path))
    chunk("SpectrumFederation", SF)
end
load("SpectrumFederation/modules/LootHelper/Consumables.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesRouting.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesWorkflow.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesSync.lua")
load("SpectrumFederation/modules/LootHelperSync/19_Consumables.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua")

local C = SF.Consumables
local R = SF.ConsumablesRouting
local W = SF.ConsumablesWorkflow
local S = SF.ConsumablesSync
local Sync = SF.LootHelperSync
local RT = SF.ConsumablesRuntime
C._clock = function()
    clock = clock + 1
    return clock
end

local notifyCount = 0
C.RegisterUIListener(function() notifyCount = notifyCount + 1 end)

local admin = "Admin-Realm"
local vann = "Vann-Realm"
local donor = "Donor-Realm"
local alt = "DonorAlt-Realm"
local aqirite = 190000
local aqiriteRank2 = 190001
local flask = 212283
local junk = 555

local function profile(id, owner, admins)
    local p = {
        _profileId = id or "profile-1",
        _owner = owner or admin,
        _adminUsers = admins or { owner or admin },
        _pointName = "Points",
        _lootLogs = { "keep-me" },
        _rewardPotStartingCopper = 42,
        _identity = {},
    }
    function p:IsAdminMemberId(memberId)
        for i = 1, #self._adminUsers do
            if self._adminUsers[i] == memberId then return true end
        end
        return false
    end
    function p:GetIdentityMembers(memberId)
        return self._identity[memberId] or { memberId }
    end
    C.Ensure(p)
    return p
end

local function unchanged(p, message)
    assertEq(p._pointName, "Points", message .. " keeps the point name")
    assertEq(p._lootLogs[1], "keep-me", message .. " keeps loot logs")
    assertEq(p._rewardPotStartingCopper, 42, message .. " keeps the reward pot")
end

local GUILD = { guid = "club-1", name = "Spectrum", realm = "Realm" }

local function configured(id)
    local p = profile(id, admin)
    assert(C.SetGuild(p, admin, GUILD, 2))
    assert(C.AddRequestedItem(p, admin, aqirite))
    return p
end

local function eventTypes(p)
    local seen = {}
    local function mark(list)
        for i = 1, #(list or {}) do
            local t = list[i].type
            seen[t] = (seen[t] or 0) + 1
        end
    end
    mark(p._consumableEvents)
    mark(p._consumableEventArchive)
    return seen
end

local function onlyDonationAndReset(p)
    for t in pairs(eventTypes(p)) do
        if t ~= C.EVENT.DONATION and t ~= C.EVENT.RESET then return false, t end
    end
    return true
end

local function resetRuntime()
    RT.depositWork = nil
    RT.depositIntent = nil
    RT.depositTimer = nil
    RT.depositContinueGen = 0
    RT.review = nil
    RT.mobileHolder = nil
    RT.mobileButtonPending = nil
    RT.dismissed = false
    RT.qtyOverrides = {}
    RT.pendingItemLoads = {}
    RT.bagCounts = {}
    RT.bagStacks = {}
    RT.reminderShown = nil
    RT.bankOpen = false
    RT.autoReviewedThisOpen = false
    RT._seenProfileId = nil
    RT.lastAccess = nil
    RT.tokenSeq = 0
end

local function resetSync()
    Sync.state = nil
    Sync.MSG = nil
    Sync._SelfId = nil
    Sync._SamePlayer = nil
    Sync._Now = nil
    Sync.IsRequesterInGroup = nil
    Sync.FindLocalProfileById = nil
    Sync.RequestProfileSnapshot = nil
    Sync.IsSafeModeEnabled = nil
    Sync._EnforceGroupedSessionActive = nil
    Sync._consumablesCatchUpKey = nil
    Sync._consumablesOpWindow = nil
    Sync._consumablesEventLimits = nil
    SF.LootHelperComm = nil
    S.ClearCoordinatorWatermarks()
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local function checkGuildConfiguration()
    local p = profile("cfg-guild", admin)
    local ok, err = C.SetGuild(p, donor, GUILD, 2)
    assertFalse(ok, "a non-admin cannot set the guild")
    assertTrue(contains(err, "admin"), "a denied guild edit explains that an admin is required")
    assertFalse(select(1, C.SetGuild(p, admin, { guid = "" }, 2)), "a guild without a stable id is rejected")
    assertFalse(select(1, C.SetGuild(p, admin, GUILD, 9)), "a bank tab outside 1-8 is rejected")
    assertFalse(select(1, C.SetGuild(p, admin, GUILD, 1.5)), "a fractional bank tab is rejected")
    assertFalse(select(1, C.SetBankTab(p, admin, 3)), "a bank tab cannot be set before the guild")
    assertEq(p._consumables.configSeq, 0, "rejected edits do not bump the config sequence")

    assertTrue(select(1, C.SetGuild(p, admin, GUILD, 2)), "an admin can set the guild and bank tab")
    assertEq(p._consumables.guild.guid, "club-1", "the guild id is stored")
    assertEq(p._consumables.bankTab, 2, "the bank tab is stored")
    assertEq(p._consumables.configSeq, 1, "setting the guild bumps the config sequence")
    local locked, lockErr = C.SetGuild(p, admin, { guid = "club-2" }, 3)
    assertFalse(locked, "a configured guild is locked until Clear")
    assertTrue(contains(lockErr, "Clear"), "the lock message points at Clear")

    assertFalse(select(1, C.SetBankTab(p, donor, 3)), "a non-admin cannot change the bank tab")
    assertTrue(select(1, C.SetBankTab(p, admin, 3)), "an admin can change the bank tab")
    assertEq(p._consumables.bankTab, 3, "the new bank tab is stored")
    local seq = p._consumables.configSeq
    assertTrue(select(1, C.SetBankTab(p, admin, 3)), "setting the same tab again succeeds")
    assertEq(p._consumables.configSeq, seq, "setting the same tab again is not a config change")
    assertFalse(select(1, C.SetBankTab(p, admin, 0)), "tab 0 is rejected")

    local asAdminFalse = C.SetBankTab(p, admin, 4, { asAdmin = false })
    assertFalse(asAdminFalse, "an explicit non-admin preview is denied even for a canonical admin")
    unchanged(p, "guild configuration")
end

local function checkRequestedItems()
    local p = profile("cfg-items", admin)
    local before = notifyCount
    assertTrue(select(1, C.AddRequestedItem(p, admin, aqirite)), "an admin can add a requested item")
    assertEq(notifyCount, before + 1, "adding an item notifies the UI once")
    assertTrue(C.IsRequested(p, aqirite), "the exact item id is requested")
    assertFalse(C.IsRequested(p, aqiriteRank2), "a different quality item id is not requested")
    assertFalse(C.IsRequested(p, "not-an-id"), "a non-numeric id is never requested")

    before = notifyCount
    local dup, dupErr = C.AddRequestedItem(p, admin, aqirite)
    assertFalse(dup, "a duplicate requested item is rejected")
    assertTrue(contains(dupErr, "already"), "the duplicate message says the item is already requested")
    assertEq(notifyCount, before, "a rejected add does not notify the UI")

    assertFalse(select(1, C.AddRequestedItem(p, donor, flask)), "a non-admin cannot add a requested item")
    assertFalse(select(1, C.AddRequestedItem(p, nil, flask)), "an anonymous actor cannot add a requested item")
    assertFalse(select(1, C.AddRequestedItem(p, admin, 0)), "item id 0 is rejected")
    assertFalse(select(1, C.AddRequestedItem(p, admin, 12.5)), "a fractional item id is rejected")
    local bound, boundErr = C.AddRequestedItem(p, admin, flask, { transferable = false })
    assertFalse(bound, "a non-transferable item is rejected")
    assertTrue(contains(boundErr, "guild bank"), "the transferable rejection mentions the guild bank")
    assertFalse(select(1, C.AddRequestedItem(p, admin, flask, { requireTransferable = true })),
        "an item with unknown transferability is rejected when transferability is required")
    assertTrue(select(1, C.AddRequestedItem(p, admin, flask, { requireTransferable = true, transferable = true })),
        "a confirmed transferable item is accepted")
    assertTrue(select(1, C.AddRequestedItem(p, admin, aqiriteRank2)), "a second quality can be requested explicitly")

    local ids = C.RequestedItemIds(p)
    assertEq(#ids, 3, "requested item ids list every requested item")
    assertEq(ids[1], aqirite, "requested item ids are sorted (first)")
    assertEq(ids[3], flask, "requested item ids are sorted (last)")

    assertFalse(select(1, C.RemoveRequestedItem(p, donor, flask)), "a non-admin cannot remove a requested item")
    assertTrue(C.IsRequested(p, flask), "a denied removal leaves the item requested")
    assertTrue(select(1, C.RemoveRequestedItem(p, admin, flask)), "an admin can remove a requested item")
    assertFalse(C.IsRequested(p, flask), "a removed item is no longer requested")
    assertFalse(select(1, C.RemoveRequestedItem(p, admin, flask)), "removing an item that is not requested is rejected")

    local cap = C.MAX_REQUESTED_ITEMS
    C.MAX_REQUESTED_ITEMS = 2
    local full, fullErr = C.AddRequestedItem(p, admin, junk)
    C.MAX_REQUESTED_ITEMS = cap
    assertFalse(full, "the requested item list is bounded")
    assertTrue(contains(fullErr, "maximum"), "the bounded list explains the maximum")

    assertEq(C.ItemIdFromText("|cff|Hitem:190000::|h[Aqirite]|h|r"), aqirite, "an item link parses to its id")
    assertEq(C.ItemIdFromText("190001"), aqiriteRank2, "a numeric string parses to its id")
    assertEq(C.ItemIdFromText("bogus"), nil, "bogus text has no item id")
    unchanged(p, "requested items")
end

local function checkApplyOpAndSettingsModel()
    local p = profile("cfg-ops", admin)
    assertTrue(select(1, C.ApplyOp(p, { name = "set_guild", guild = GUILD, bankTab = 5 }, admin)), "ApplyOp set_guild")
    assertTrue(select(1, C.ApplyOp(p, { name = "set_bank_tab", bankTab = 6 }, admin)), "ApplyOp set_bank_tab")
    assertEq(p._consumables.bankTab, 6, "ApplyOp set_bank_tab stores the tab")
    assertTrue(select(1, C.ApplyOp(p, { name = "add_item", itemId = aqirite }, admin)), "ApplyOp add_item")
    assertTrue(select(1, C.ApplyOp(p, { name = "add_item", itemId = flask }, admin)), "ApplyOp add_item second item")
    assertTrue(select(1, C.ApplyOp(p, { name = "remove_item", itemId = flask }, admin)), "ApplyOp remove_item")
    assertFalse(select(1, C.ApplyOp(p, { name = "add_item", itemId = flask }, donor)), "ApplyOp add_item denies a non-admin")
    assertFalse(select(1, C.ApplyOp(p, { name = "add_crafter", crafter = vann }, admin)), "a legacy add_crafter op is unknown")
    assertFalse(select(1, C.ApplyOp(p, { name = "add_assignment", itemId = aqirite }, admin)), "a legacy add_assignment op is unknown")
    assertFalse(select(1, C.ApplyOp(p, nil, admin)), "a missing op is rejected")

    local adminModel = C.SettingsModel(p, admin, true)
    assertTrue(adminModel.isAdmin and adminModel.canEditGuild and adminModel.canManageItems and adminModel.canClear,
        "admins can edit guild, items, and clear")
    assertTrue(adminModel.guildLocked, "the settings model shows the guild lock")
    assertEq(adminModel.bankTab, 6, "the settings model shows the bank tab")
    assertEq(#adminModel.requestedItems, 1, "the settings model lists requested items")
    assertEq(adminModel.requestedItems[1].itemId, aqirite, "the settings model lists the requested item id")
    assertTrue(adminModel.requestedItems[1].canRemove, "admins can remove requested rows")
    assertTrue(contains(adminModel.guildText, "Spectrum") and contains(adminModel.guildText, "tab 6"),
        "the guild text names the guild and tab")
    assertTrue(contains(adminModel.clearWarning, "Logs are kept"), "the clear warning says history is kept")
    local memberModel = C.SettingsModel(p, donor, false)
    assertFalse(memberModel.canEditGuild or memberModel.canManageItems or memberModel.canClear,
        "members get a read-only settings model")
    assertFalse(memberModel.requestedItems[1].canRemove, "members cannot remove requested rows")
    assertEq(C.SettingsModel(profile("cfg-empty"), admin, true).guildText, "No guild configured.",
        "an unconfigured profile says no guild is configured")
end

local function checkMigration()
    local fresh = { _profileId = "fresh" }
    local cfg = C.Ensure(fresh)
    assertEq(cfg.generation, 1, "a profile without consumables starts at generation 1")
    assertEq(next(cfg.requestedItems), nil, "a profile without consumables has no requested items")
    assertEq(#fresh._consumableEvents, 0, "a profile without consumables has no events")

    local old = {
        _profileId = "legacy",
        _adminUsers = { admin },
        _pointName = "Points",
        _lootLogs = { "keep-me" },
        _rewardPotStartingCopper = 42,
        _consumables = {
            generation = 3,
            configSeq = 7,
            eventSeq = 4,
            guild = { guid = "club-1", name = "Spectrum", realm = "Realm" },
            bankTab = 2,
            crafters = { vann },
            assignments = {
                [tostring(aqirite)] = { itemId = aqirite, crafters = { vann }, epoch = 2 },
                [tostring(aqiriteRank2)] = { itemId = aqiriteRank2, crafters = {}, epoch = 1 },
                [tostring(flask)] = { itemId = flask },
            },
            itemEpochs = { [tostring(aqirite)] = 2 },
        },
        _consumablesPendingFreezes = { { token = "trade-1" } },
        _consumableEvents = {
            { id = "ce:legacy:Donor-Realm:1", type = C.EVENT.DONATION, actor = donor, itemId = aqirite,
              quantity = 5, source = "guildbank", generation = 3, timestamp = 10 },
        },
    }
    local migrated = C.Ensure(old)
    assertTrue(C.IsRequested(old, aqirite), "an assigned item migrates to a requested item")
    assertTrue(C.IsRequested(old, flask), "a flat legacy requested row migrates")
    assertFalse(C.IsRequested(old, aqiriteRank2), "an assignment with no crafters is not migrated")
    assertEq(migrated.crafters, nil, "legacy crafters are cleared")
    assertEq(migrated.assignments, nil, "legacy assignments are cleared")
    assertEq(migrated.itemEpochs, nil, "legacy item epochs are cleared")
    assertEq(old._consumablesPendingFreezes, nil, "legacy pending trade freezes are cleared")
    assertEq(migrated.generation, 3, "migration keeps the generation")
    assertEq(migrated.configSeq, 7, "migration keeps the config sequence")
    assertEq(migrated.guild.guid, "club-1", "migration keeps the guild")
    assertEq(migrated.bankTab, 2, "migration keeps the bank tab")
    assertEq(#old._consumableEvents, 1, "migration keeps existing accounting events")
    assertEq(C.ContributionTotal(old, donor, aqirite), 5, "migrated donations still count")
    unchanged(old, "migration")

    local seq = old._consumables.configSeq
    C.Ensure(old)
    C.Ensure(old)
    assertEq(old._consumables.configSeq, seq, "Ensure is idempotent and does not bump the config sequence")
    assertTrue(C.IsRequested(old, aqirite), "a second Ensure keeps migrated requested items")

    local messy = { _profileId = "messy", _consumables = {
        generation = -4, configSeq = "x", eventSeq = 1.5,
        requestedItems = { ["190000"] = { itemId = 190000 }, ["212283"] = true, bad = { itemId = -1 } },
    } }
    local cleaned = C.Ensure(messy)
    assertEq(cleaned.generation, 1, "an invalid generation resets to 1")
    assertEq(cleaned.configSeq, 0, "an invalid config sequence resets to 0")
    assertTrue(C.IsRequested(messy, aqirite) and C.IsRequested(messy, flask), "valid requested rows survive normalization")
    assertEq(#C.RequestedItemIds(messy), 2, "invalid requested rows are dropped")

    local legacyPayload = C.ReplaceConfig(profile("legacy-payload", admin), {
        generation = 1,
        configSeq = 2,
        guild = GUILD,
        bankTab = 4,
        crafters = { vann },
        assignments = { [tostring(aqirite)] = { itemId = aqirite, crafters = { vann } } },
    })
    assertTrue(legacyPayload, "a legacy assignment payload replaces config")
    local replaced = profile("legacy-payload-2", admin)
    C.ReplaceConfig(replaced, { generation = 1, configSeq = 2, guild = GUILD, bankTab = 4,
        assignments = { [tostring(aqirite)] = { itemId = aqirite, crafters = { vann } } } })
    assertTrue(C.IsRequested(replaced, aqirite), "a legacy assignment payload migrates to requested items")
    assertEq(replaced._consumables.assignments, nil, "a legacy payload does not store assignments")
    assertTrue(C.ValidateSnapshot({ crafters = {}, assignments = {} }), "legacy snapshot fields still validate")
end

-- ---------------------------------------------------------------------------
-- Routing and reminder rules (pure)
-- ---------------------------------------------------------------------------

local function checkAccessRules()
    assertFalse(R.IsCarriedBag(-1), "the character bank is not carried")
    assertFalse(R.IsCarriedBag(-3), "the warband bank is not carried")
    assertFalse(R.IsCarriedBag(6), "bank bags are not carried")
    assertTrue(R.IsCarriedBag(0), "the backpack is carried")
    assertTrue(R.IsCarriedBag(5), "the reagent bag is carried")
    for _, bind in ipairs({ 1, 4, 7, 8, 9 }) do
        assertFalse(R.TransferableBindType(bind), "bind type " .. bind .. " cannot go to the guild bank")
    end
    assertTrue(R.TransferableBindType(0), "unbound items are transferable")
    assertTrue(R.TransferableBindType(2), "bind on equip items are transferable")
    assertEq(R.TransferableBindType(nil), nil, "unknown bind type is unknown")

    local wrong = R.GuildBankAccess({ configured = true, sameGuild = false, bankOpen = true, canDeposit = true, freeSlots = 4 })
    assertFalse(wrong.visible, "another guild hides guild bank actions")
    assertFalse(R.GuildBankAccess({ configured = false, sameGuild = true }).visible, "an unconfigured profile hides guild bank actions")
    local noPerm = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = true, canDeposit = false, freeSlots = 4 })
    assertEq(noPerm.reason, "no_permission", "missing deposit permission is reported")
    assertFalse(R.GuildBankUsable(noPerm), "missing deposit permission is not usable")
    local wrongTab = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = true, wrongTab = true, canDeposit = false, freeSlots = 4 })
    assertEq(wrongTab.reason, "wrong_tab", "viewing another tab is reported distinctly from no permission")
    assertFalse(R.GuildBankUsable(wrongTab), "a wrong-tab bank path is not usable")
    local full = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = true, canDeposit = true, freeSlots = 0 })
    assertEq(full.reason, "tab_full", "a full tab is reported")
    assertFalse(R.GuildBankUsable(full), "a full tab is not usable")
    local merge = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = true, canDeposit = true, freeSlots = 0, mergeRoom = true })
    assertTrue(R.GuildBankUsable(merge), "a full tab with room on a matching stack is usable")
    local open = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = true, canDeposit = true, freeSlots = 3 })
    assertEq(open.action, "deposit", "an open bank with permission offers deposit")
    assertTrue(R.GuildBankUsable(open), "an open bank with permission is usable")
    local mobile = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = false, mobileKnown = true })
    assertEq(mobile.action, "mobile", "known Mobile Banking offers the mobile path")
    assertTrue(R.GuildBankUsable(mobile), "Mobile Banking off cooldown is usable")
    local cooldown = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = false, mobileKnown = true, mobileCooldown = true })
    assertEq(cooldown.reason, "cooldown", "Mobile Banking cooldown is reported")
    assertFalse(R.GuildBankUsable(cooldown), "Mobile Banking on cooldown is not usable")
    local closed = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = false })
    assertEq(closed.reason, "bank_closed", "a closed bank without Mobile Banking is reported")
    assertFalse(R.GuildBankUsable(closed), "a closed bank is not usable")
    assertFalse(R.GuildBankUsable(nil), "no access is not usable")
    assertTrue(R.HasActionablePath(true), "a usable guild bank is an actionable path")
    assertFalse(R.HasActionablePath(false), "without a usable guild bank there is no path")
end

local function checkReminderRules()
    local base = { remindersEnabled = true, windowAllowed = true, carriesRequested = true, hasActionablePath = true }
    local function with(key, value)
        local copy = {}
        for k, v in pairs(base) do copy[k] = v end
        copy[key] = value
        return copy
    end
    assertTrue(R.ReminderVisible(base), "the reminder shows for a carried requested item with a usable path")
    assertFalse(R.ReminderVisible(with("remindersEnabled", false)), "the personal setting hides the reminder")
    assertFalse(R.ReminderVisible(with("windowAllowed", false)), "a hidden Loot Helper window hides the reminder")
    assertFalse(R.ReminderVisible(with("dismissed", true)), "a session dismissal hides the reminder")
    assertFalse(R.ReminderVisible(with("carriesRequested", false)), "carrying nothing requested hides the reminder")
    assertFalse(R.ReminderVisible(with("hasActionablePath", false)), "no usable guild bank path hides the reminder")
    assertFalse(R.ReminderVisible(nil), "missing reminder input hides the reminder")
    assertTrue(R.ReminderVisible(with("isCrafter", true)), "a legacy crafter flag has no effect on reminders")
    local snapshot = with("dismissed", false)
    for _ = 1, 100 do R.ReminderVisible(snapshot) end
    assertEq(snapshot.dismissed, false, "evaluating the reminder does not mutate its input")
end

-- ---------------------------------------------------------------------------
-- Donation plan and deposit workflow (pure)
-- ---------------------------------------------------------------------------

local function checkPlanAndWorkflow()
    local p = configured("plan")
    assertTrue(select(1, C.AddRequestedItem(p, admin, flask)), "plan fixture requests a second item")
    local carried = {
        { itemId = flask, quantity = 3, name = "Flask" },
        { itemId = junk, quantity = 50 },
        { itemId = aqirite, quantity = 40.9 },
        { itemId = aqiriteRank2, quantity = 10 },
        { itemId = flask, quantity = 0 },
    }
    local plan = C.BuildDonationPlan(p, carried, { guildBankUsable = true })
    assertEq(#plan.lines, 2, "the plan lists only requested carried items")
    assertEq(plan.lines[1].itemId, aqirite, "plan lines are sorted by item id")
    assertEq(plan.lines[1].quantity, 40, "plan quantities are whole items")
    assertTrue(plan.lines[1].guildBank, "plan lines target the guild bank")
    assertEq(plan.lines[1].generation, 1, "plan lines carry the configuration generation")
    assertEq(#plan.groups, 1, "the plan has one destination group")
    assertEq(plan.groups[1].key, "Guild Bank", "the destination group is the Guild Bank")
    assertEq(#C.BuildDonationPlan(p, carried, { guildBankUsable = false }).lines, 0, "without a usable guild bank the plan is empty")
    assertEq(#C.BuildDonationPlan(p, nil, { guildBankUsable = true }).lines, 0, "no carried items means an empty plan")

    local line = plan.lines[1]
    assertTrue(select(1, C.RevalidateDonation(p, line, { guildBankUsable = true }, 40)), "a current plan line revalidates")
    assertFalse(select(1, C.RevalidateDonation(p, line, { guildBankUsable = true }, 39)), "fewer items in bags fails revalidation")
    assertFalse(select(1, C.RevalidateDonation(p, line, { guildBankUsable = false }, 40)), "a lost guild bank path fails revalidation")
    assertFalse(select(1, C.RevalidateDonation(p, nil, { guildBankUsable = true }, 40)), "a missing line fails revalidation")
    C.RemoveRequestedItem(p, admin, aqirite)
    assertFalse(select(1, C.RevalidateDonation(p, line, { guildBankUsable = true }, 40)), "an unrequested item fails revalidation")
    C.AddRequestedItem(p, admin, aqirite)
    C.Clear(p, admin)
    local stale, staleErr = C.RevalidateDonation(p, line, { guildBankUsable = true }, 40)
    assertFalse(stale, "a line from an older generation fails revalidation")
    assertTrue(contains(staleErr, "configuration changed"), "a stale generation explains the change")

    assertEq(W.ClampDonationQuantity(999, 40), 40, "a quantity above the carried count clamps down")
    assertEq(W.ClampDonationQuantity(0, 40), 1, "a quantity below one clamps to one")
    assertEq(W.ClampDonationQuantity(7.8, 40), 7, "a fractional quantity floors")
    assertEq(W.ClampDonationQuantity(5, 0), 0, "nothing carried clamps to zero")
    assertEq(W.ClampDonationQuantity(-3, 10), 1, "a negative quantity clamps to one")

    local frozen = { generation = 1, itemId = aqirite, donor = donor, requested = true, timestamp = 50 }
    local events = W.DepositEvents(frozen, 12.7)
    assertEq(#events, 1, "a successful deposit produces one event")
    assertEq(events[1].type, C.EVENT.DONATION, "the deposit event is a donation")
    assertEq(events[1].source, "guildbank", "the deposit event source is the guild bank")
    assertEq(events[1].actor, donor, "the deposit event actor is the depositor")
    assertEq(events[1].quantity, 12, "the deposit event quantity is whole items")
    assertEq(#W.DepositEvents(frozen, 0), 0, "a zero-quantity deposit produces no event")
    assertEq(#W.DepositEvents(frozen, -5), 0, "a negative deposit produces no event")
    assertEq(#W.DepositEvents(nil, 5), 0, "a missing deposit context produces no event")
    local unrequested = { generation = 1, itemId = junk, donor = donor, requested = false }
    assertEq(#W.DepositEvents(unrequested, 5), 0, "an unrequested item deposit produces no event")

    local full = W.InterpretDeposit({ guildOk = true, configuredTab = 2, observedTab = 2, intendedQty = 20,
        beforeTab = 10, afterTab = 30, beforeBags = 20, afterBags = 0 })
    assertEq(full, 20, "a complete deposit records the intended quantity")
    local partial, partialErr = W.InterpretDeposit({ guildOk = true, configuredTab = 2, observedTab = 2, intendedQty = 20,
        beforeTab = 10, afterTab = 18, beforeBags = 20, afterBags = 12 })
    assertEq(partial, 8, "a partial deposit records only what landed")
    assertEq(partialErr, nil, "a partial deposit is not a hard failure")
    local slotPartial = W.InterpretDeposit({ guildOk = true, configuredTab = 2, observedTab = 2, intendedQty = 20,
        placedSlots = { { before = 18, after = 20 }, { before = 0, after = 3 }, { before = 5, after = 2 } },
        beforeBags = 20, afterBags = 0, beforeTab = 0, afterTab = 100 })
    assertEq(slotPartial, 5, "placed-slot gains take precedence over whole-tab deltas")
    local otherDeposit = W.InterpretDeposit({ guildOk = true, configuredTab = 2, observedTab = 2, intendedQty = 20,
        beforeTab = 0, afterTab = 50, beforeBags = 20, afterBags = 15 })
    assertEq(otherDeposit, 5, "another player's deposit does not inflate the bag-backed amount")
    local wrongGuild, wrongGuildErr = W.InterpretDeposit({ guildOk = false, configuredTab = 2, observedTab = 2,
        intendedQty = 10, beforeTab = 0, afterTab = 10, beforeBags = 10, afterBags = 0 })
    assertEq(wrongGuild, 0, "a wrong-guild deposit records nothing")
    assertEq(wrongGuildErr, "wrong_guild", "a wrong-guild deposit reports why")
    local wrongTab, wrongTabErr = W.InterpretDeposit({ guildOk = true, configuredTab = 2, observedTab = 3,
        intendedQty = 10, beforeTab = 0, afterTab = 10, beforeBags = 10, afterBags = 0 })
    assertEq(wrongTab, 0, "a deposit into another tab records nothing")
    assertEq(wrongTabErr, "wrong_tab", "a wrong-tab deposit reports why")
    local failed = W.InterpretDeposit({ guildOk = true, configuredTab = 2, observedTab = 2, intendedQty = 10,
        beforeTab = 5, afterTab = 5, beforeBags = 10, afterBags = 10 })
    assertEq(failed, 0, "a rejected deposit records nothing")

    assertEq(W.DepositDisposition(10, 10, false), "commit", "a complete deposit commits immediately")
    assertEq(W.DepositDisposition(4, 10, false), "wait", "a partial deposit waits for the rest")
    assertEq(W.DepositDisposition(4, 10, true), "commit", "the deadline commits a partial deposit")
    assertEq(W.DepositDisposition(0, 10, true), "drop", "the deadline drops an empty deposit")
    assertEq(W.DepositDisposition(0, 10, false), "wait", "an empty observation keeps waiting before the deadline")
end

-- ---------------------------------------------------------------------------
-- Accounting
-- ---------------------------------------------------------------------------

local function checkAccounting()
    local p = configured("accounting")
    local frozen = { generation = 1, itemId = aqirite, donor = donor, requested = true, timestamp = 70 }
    local events = W.DepositEvents(frozen, 25)
    assertTrue(select(1, C.CommitEvents(p, "deposit-Donor-Realm-1", events, { writer = donor })), "a deposit commits")
    assertEq(#p._consumableEvents, 1, "a successful deposit stores exactly one event")
    local stored = p._consumableEvents[1]
    assertEq(stored.type, C.EVENT.DONATION, "the stored event is a donation")
    assertEq(stored.source, "guildbank", "the stored donation came from the guild bank")
    assertEq(stored.writer, donor, "the stored donation records the observing writer")
    assertEq(C.ContributionTotal(p, donor, aqirite), 25, "the contribution total matches the deposit")
    assertEq(C.ContributionTotal(p, donor), 25, "the all-item contribution total matches the deposit")
    assertEq(C.ContributionTotal(p, vann, aqirite), 0, "another member has no contribution")
    assertEq(C.ContributionTotal(p, nil), 0, "an unknown member has no contribution")

    assertTrue(select(1, C.CommitEvents(p, "deposit-Donor-Realm-1", W.DepositEvents(frozen, 25))), "replaying a deposit succeeds")
    assertEq(#p._consumableEvents, 1, "replaying the same deposit does not add an event")
    assertEq(C.ContributionTotal(p, donor, aqirite), 25, "replaying the same deposit does not double count")
    assertFalse(select(1, C.CommitEvents(p, "", events)), "a commit without a transaction id is rejected")

    p._identity[donor] = { donor, alt }
    p._identity[alt] = { donor, alt }
    C.CommitEvents(p, "deposit-DonorAlt-Realm-1",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = alt, requested = true }, 5))
    assertEq(C.ContributionTotal(p, donor, aqirite), 30, "linked characters share a contribution total")
    assertEq(C.ContributionTotal(p, alt, aqirite), 30, "the linked alt sees the same total")

    local ok, bad = onlyDonationAndReset(p)
    assertTrue(ok, "deposits create no receipt or custody events (" .. tostring(bad) .. ")")

    assertEq(C.FormatEvent(stored, "Aqirite"), "Donor-Realm donated 25 Aqirite to the guild bank.", "a donation formats for history")
    assertEq(C.FormatEvent({ type = C.EVENT.DONATION, actor = donor, itemId = aqirite, quantity = 1, source = "trade" }), "",
        "a legacy trade donation is not formatted")
    assertEq(C.FormatEvent({ type = C.EVENT.RESET, actor = admin }), "Admin-Realm cleared the Raid Consumables configuration.",
        "a reset formats for history")
    for _, legacy in ipairs({ C.EVENT.RECEIPT, C.EVENT.CUSTODY, C.EVENT.RESOLVE, "SOMETHING_ELSE" }) do
        assertEq(C.FormatEvent({ type = legacy, actor = vann, itemId = aqirite, quantity = 1 }), "",
            "legacy event type " .. legacy .. " is not formatted")
    end
    assertEq(C.FormatEvent(nil), "", "a missing event formats as empty")
    assertTrue(contains(C.FormatEvent({ type = C.EVENT.DONATION, actor = donor, itemId = aqirite, quantity = 2, source = "guildbank" }),
        "item 190000"), "a donation without an item name falls back to the item id")

    C.AppendEvent(p, { id = "ce:accounting:Vann-Realm:9", type = C.EVENT.RECEIPT, actor = vann, itemId = aqirite,
        quantity = 3, generation = 1 }, { silent = true })
    local rows, total = C.HistoryRows(p, function() return "Aqirite" end)
    assertEq(total, 2, "history totals only displayable guild bank donations and resets")
    assertEq(#rows, 2, "history shows only guild bank donations and resets")
    assertTrue(contains(rows[1].text, "DonorAlt-Realm"), "history is newest first")
    local page, pageTotal = C.HistoryRows(p, function() return "Aqirite" end, 1, 0)
    assertEq(pageTotal, 2, "paginated history totals only displayable rows")
    assertEq(#page, 1, "paginated history returns the requested page size")
    assertTrue(contains(page[1].text, "DonorAlt-Realm"), "the first page shows the newest displayable row")

    local fullP = configured("accounting-full")
    local cap = C.MAX_LEDGER_EVENTS
    C.MAX_LEDGER_EVENTS = 0
    local fullOk, fullErr = C.CommitEvents(fullP, "full-token", W.DepositEvents(frozen, 1))
    C.MAX_LEDGER_EVENTS = cap
    assertFalse(fullOk, "a full ledger reports a failed commit")
    assertTrue(contains(fullErr, "full"), "a full ledger explains the failure")
    assertEq(#fullP._consumableEvents, 0, "a failed commit stores nothing")
end

-- ---------------------------------------------------------------------------
-- Sync and security
-- ---------------------------------------------------------------------------

local function donation(id, actor, qty, extra)
    local event = { id = id, type = C.EVENT.DONATION, actor = actor, itemId = aqirite, quantity = qty or 5,
        source = "guildbank", generation = 1, timestamp = 10 }
    for k, v in pairs(extra or {}) do event[k] = v end
    return event
end

local function checkAuthorizeAndConfigSync()
    local p = configured("authz")
    for _, name in ipairs({ "add_item", "remove_item", "set_guild", "set_bank_tab", "clear" }) do
        assertTrue(S.AuthorizeOp(p, { name = name }, admin), "an admin may send " .. name)
        assertFalse(S.AuthorizeOp(p, { name = name }, donor), "a member may not send " .. name)
    end
    assertFalse(S.AuthorizeOp(p, { name = "add_crafter" }, admin), "legacy crafter ops are not authorized")
    assertFalse(S.AuthorizeOp(p, nil, admin), "a missing op is not authorized")

    local source = profile("cfg-source", admin)
    local follower = profile("cfg-follower", admin)
    local function push()
        return S.ApplyRemoteConfig(follower, C.ExportSnapshot(source, { omitEvents = true }), admin)
    end
    C.SetGuild(source, admin, GUILD, 2)
    assertEq(select(2, push()), "applied", "the follower applies the next config sequence")
    C.AddRequestedItem(source, admin, aqirite)
    push()
    C.AddRequestedItem(source, admin, flask)
    push()
    C.RemoveRequestedItem(source, admin, flask)
    push()
    C.SetBankTab(source, admin, 5)
    push()
    assertEq(C.Descriptor(follower).configFingerprint, C.Descriptor(source).configFingerprint, "config converges after each edit")
    assertEq(follower._consumables.bankTab, 5, "the follower has the converged bank tab")
    assertTrue(C.IsRequested(follower, aqirite) and not C.IsRequested(follower, flask), "the follower has the converged requested items")
    assertEq(select(2, push()), "stale", "re-sending the same config is stale")
    C.Clear(source, admin)
    assertEq(select(2, push()), "applied", "a Clear generation bump converges")
    assertEq(follower._consumables.generation, 2, "the follower adopts the new generation")
    assertEq(follower._consumables.guild, nil, "the follower drops the cleared guild")
    assertEq(C.Descriptor(follower).configFingerprint, C.Descriptor(source).configFingerprint, "config converges after Clear")

    local forged = C.ExportSnapshot(source, { omitEvents = true })
    forged.configSeq = forged.configSeq + 1
    forged.bankTab = 8
    assertEq(select(2, S.ApplyRemoteConfig(follower, forged, donor)), "unauthorized", "a member cannot push config")
    local gap = C.ExportSnapshot(source, { omitEvents = true })
    gap.configSeq = gap.configSeq + 5
    assertEq(select(2, S.ApplyRemoteConfig(follower, gap, admin)), "gap", "a config gap asks for catch-up")
    assertEq(select(2, S.ApplyRemoteConfig(follower, gap, admin, { coordinatorAuthoritative = true, coordEpoch = 1 })), "applied",
        "the coordinator's authoritative config applies across a gap")
    assertEq(select(2, S.ApplyRemoteConfig(follower, nil, admin)), "invalid", "a missing config payload is invalid")
    local badSeq = C.ExportSnapshot(source, { omitEvents = true })
    badSeq.configSeq = 0 / 0
    assertEq(select(2, S.ApplyRemoteConfig(follower, badSeq, admin, { coordinatorAuthoritative = true, coordEpoch = 2 })), "invalid",
        "a NaN config sequence is rejected before watermarking")
    badSeq.configSeq = math.huge
    assertEq(select(2, S.ApplyRemoteConfig(follower, badSeq, admin, { coordinatorAuthoritative = true, coordEpoch = 2 })), "invalid",
        "an infinite config sequence is rejected before watermarking")
end

local function checkRemoteEvents()
    local p = configured("remote-events")
    local legit = donation("ce:remote:Donor-Realm:1", donor, 5)
    assertTrue(select(1, S.ApplyRemoteEvent(p, legit, donor)), "a member's own guild bank donation is accepted")
    assertEq(C.ContributionTotal(p, donor, aqirite), 5, "the accepted donation counts")
    local ok, status = S.ApplyRemoteEvent(p, donation("ce:remote:Donor-Realm:1", donor, 5), donor)
    assertTrue(ok and status == "duplicate", "replaying a remote donation is idempotent")
    assertEq(#p._consumableEvents, 1, "a replayed remote donation is stored once")

    local cases = {
        { donation("ce:remote:Donor-Realm:2", vann, 5), donor, "unauthorized", "a donation credited to another player is rejected" },
        { donation("ce:remote:Vann-Realm:3", vann, 5), donor, "unauthorized", "an event id naming another player is rejected" },
        { donation("ce:remote:Donor-Realm:4", donor, 5, { source = "trade" }), donor, "unauthorized", "a trade donation is rejected" },
        { donation("ce:remote:Donor-Realm:5", donor, 5, { source = false }), donor, "unauthorized", "a donation without a guild bank source is rejected" },
        { donation("ce:remote:Donor-Realm:6", donor, 0), donor, "unauthorized", "a zero-quantity donation is rejected" },
        { donation("ce:remote:Donor-Realm:7", donor, 1.5), donor, "unauthorized", "a fractional donation is rejected" },
        { donation("ce:remote:Donor-Realm:8", donor, S.MAX_EVENT_QUANTITY + 1), donor, "unauthorized", "an oversized donation is rejected" },
        { donation("ce:remote:Donor-Realm:9", donor, 0 / 0), donor, "unauthorized", "a NaN donation is rejected" },
        { donation("ce:remote:Donor-Realm:10", donor, 5, { itemId = -1 }), donor, "unauthorized", "an invalid item id is rejected" },
        { { id = "ce:remote:Vann-Realm:11", type = C.EVENT.RECEIPT, actor = vann, itemId = aqirite, quantity = 5, generation = 1 },
            vann, "invalid", "a crafter receipt is rejected" },
        { { id = "ce:remote:Admin-Realm:12", type = C.EVENT.CUSTODY, actor = admin, holder = admin, itemId = aqirite, quantity = 5, generation = 1 },
            admin, "invalid", "a custody event is rejected even from an admin" },
        { { id = "ce:remote:Admin-Realm:13", type = C.EVENT.RESOLVE, actor = admin, itemId = aqirite, generation = 1 },
            admin, "invalid", "a custody resolve is rejected" },
        { { id = "ce:remote:Donor-Realm:14", type = C.EVENT.RESET, actor = donor, generation = 1 }, donor,
            "unauthorized", "a member cannot send a reset" },
        { { id = "ce:remote:Donor-Realm:15", type = C.EVENT.RESET, actor = admin, generation = 1 }, donor,
            "unauthorized", "a reset credited to an admin but sent by a member is rejected" },
        { { id = "ce:remote:Donor-Realm:16" }, donor, "invalid", "an event without a type is invalid" },
    }
    for i = 1, #cases do
        local event, sender, want, message = cases[i][1], cases[i][2], cases[i][3], cases[i][4]
        if event.source == false then event.source = nil end
        local accepted, why = S.ApplyRemoteEvent(p, event, sender)
        assertTrue(not accepted and why == want, message)
    end
    assertEq(#p._consumableEvents, 1, "rejected remote events are never stored")
    local ok2, bad = onlyDonationAndReset(p)
    assertTrue(ok2, "remote traffic creates no receipt or custody events (" .. tostring(bad) .. ")")

    assertTrue(select(1, S.ApplyRemoteEvent(p, { id = "ce:remote:Admin-Realm:20", type = C.EVENT.RESET, actor = admin,
        generation = 1, timestamp = 20 }, admin)), "an admin's own reset is accepted")

    local relay = donation("ce:remote:Donor-Realm:30", donor, 3, { order = 4, writer = donor })
    assertTrue(select(1, S.ApplyRemoteEvent(p, relay, admin, { coordinatorRelay = true })), "a coordinator relay keeps the member writer")
    local forgedRelay = donation("ce:remote:Donor-Realm:31", vann, 3, { order = 5, writer = donor })
    assertFalse(select(1, S.ApplyRemoteEvent(p, forgedRelay, admin, { coordinatorRelay = true })),
        "a relay cannot credit another player")
    local noWriter = donation("ce:remote:Donor-Realm:32", donor, 3, { order = 6, writer = vann })
    assertFalse(select(1, S.ApplyRemoteEvent(p, noWriter, admin, { coordinatorRelay = true })),
        "a relay whose writer does not own the id is rejected")

    local asCoord = donation("ce:x:Donor-Realm:40", donor, 1, { order = 9, writer = "Evil-Realm" })
    local accept, isRelay = S.RemoteEventAdmission(true, false, asCoord)
    assertTrue(accept and not isRelay, "the coordinator admits member events")
    assertTrue(asCoord.order == nil and asCoord.writer == nil, "the coordinator discards member-supplied order and writer")
    assertFalse(select(1, S.RemoteEventAdmission(false, false, donation("ce:x:Donor-Realm:41", donor, 1))),
        "a follower ignores events that did not come from the coordinator")
    assertFalse(select(1, S.RemoteEventAdmission(false, true, donation("ce:x:Donor-Realm:42", donor, 1))),
        "a follower ignores unstamped coordinator events")
    local stampedOk, stampedRelay = S.RemoteEventAdmission(false, true, donation("ce:x:Donor-Realm:43", donor, 1, { order = 2 }))
    assertTrue(stampedOk and stampedRelay, "a follower accepts stamped coordinator relays")

    local bucket = {}
    local allowed = 0
    for _ = 1, S.MAX_REMOTE_OPS + 10 do
        if S.AllowRemoteOp(bucket, donor, 5) then allowed = allowed + 1 end
    end
    assertEq(allowed, S.MAX_REMOTE_OPS, "remote traffic from one sender is rate limited")
    assertTrue(S.AllowRemoteOp(bucket, donor, 5 + S.REMOTE_OP_WINDOW), "the rate limit resets after its window")
end

local function sessionStubs(state, profiles, sent)
    Sync.state = state
    Sync.MSG = { CONSUMABLES_EVENT = "CE", CONSUMABLES_OP = "CO", CONSUMABLES_CONFIG = "CC" }
    Sync._SamePlayer = function(_, a, b) return a == b end
    Sync.IsRequesterInGroup = function() return true end
    Sync.FindLocalProfileById = function(_, id) return profiles[id] end
    Sync._EnforceGroupedSessionActive = function() return "RAID" end
    Sync._Now = function() return clock end
    SF.LootHelperComm = {
        Send = function(_, _, msg, payload, dist, target)
            sent[#sent + 1] = { msg = msg, payload = payload, dist = dist, target = target }
            return true
        end,
    }
end

local function countMsg(sent, msg)
    local n = 0
    for i = 1, #sent do
        if sent[i].msg == msg then n = n + 1 end
    end
    return n
end

local function checkSessionTransport()
    resetSync()
    local coordP = configured("session")
    local sent = {}
    sessionStubs({ active = true, isCoordinator = true, coordinator = admin, sessionId = "s1",
        profileId = coordP._profileId, peers = {} }, { [coordP._profileId] = coordP }, sent)
    Sync._SelfId = function() return admin end

    local function member(event, sender)
        Sync:HandleConsumablesEvent(sender, { sessionId = "s1", profileId = coordP._profileId, event = event })
    end
    member(donation("ce:session:Donor-Realm:1", donor, 6), donor)
    assertEq(#coordP._consumableEvents, 1, "the coordinator stores a member's guild bank donation")
    assertEq(coordP._consumableEvents[1].order, 1, "the coordinator stamps the donation order")
    assertEq(countMsg(sent, "CE"), 1, "the coordinator relays the stamped donation once")
    member(donation("ce:session:Donor-Realm:2", vann, 6), donor)
    member(donation("ce:session:Donor-Realm:3", donor, 6, { source = "trade" }), donor)
    member({ id = "ce:session:Donor-Realm:4", type = C.EVENT.CUSTODY, actor = donor, itemId = aqirite, quantity = 1, generation = 1 }, donor)
    member(donation("ce:session:Donor-Realm:5", donor, 6), "Stranger-Realm")
    assertEq(#coordP._consumableEvents, 1, "forged, trade, custody, and spoofed events are not stored by the coordinator")
    assertEq(countMsg(sent, "CE"), 1, "rejected events are not relayed")
    Sync:HandleConsumablesEvent(donor, { sessionId = "other", profileId = coordP._profileId,
        event = donation("ce:session:Donor-Realm:6", donor, 6) })
    assertEq(#coordP._consumableEvents, 1, "events for another session are ignored")

    local function op(sender, actor, body)
        Sync:HandleConsumablesOp(sender, { sessionId = "s1", profileId = coordP._profileId, actor = actor, op = body })
    end
    op(donor, donor, { name = "add_item", itemId = flask })
    assertFalse(C.IsRequested(coordP, flask), "the coordinator rejects a member's config op")
    op(donor, admin, { name = "add_item", itemId = flask })
    assertFalse(C.IsRequested(coordP, flask), "the coordinator rejects an op whose actor is not the sender")
    op(admin, admin, { name = "add_crafter", crafter = vann })
    assertEq(countMsg(sent, "CC"), 0, "rejected ops do not broadcast config")
    op(admin, admin, { name = "add_item", itemId = flask })
    assertTrue(C.IsRequested(coordP, flask), "the coordinator applies an admin's config op")
    assertEq(countMsg(sent, "CC"), 1, "an applied op broadcasts config once")
    local ccPayload = sent[#sent].payload
    assertEq(ccPayload.events, nil, "config broadcasts omit the ledger")
    assertEq(ccPayload.crafters, nil, "config broadcasts carry no crafters")
    assertEq(ccPayload.assignments, nil, "config broadcasts carry no assignments")

    local followerP = profile("session", admin)
    followerP._profileId = coordP._profileId
    local fsent = {}
    sessionStubs({ active = true, isCoordinator = false, coordinator = admin, sessionId = "s1",
        profileId = coordP._profileId, peers = { [admin] = { consumablesCapable = true } } },
        { [coordP._profileId] = followerP }, fsent)
    Sync._SelfId = function() return vann end
    local cfgPayload = C.ExportSnapshot(coordP, { omitEvents = true })
    cfgPayload.sessionId = "s1"
    cfgPayload.profileId = coordP._profileId
    Sync:HandleConsumablesConfig(donor, cfgPayload)
    assertFalse(C.IsRequested(followerP, aqirite), "config from a non-coordinator is ignored")
    Sync:HandleConsumablesConfig(admin, cfgPayload)
    assertEq(C.Descriptor(followerP).configFingerprint, C.Descriptor(coordP).configFingerprint,
        "the follower converges on the coordinator's config")

    local requests = {}
    Sync.RequestProfileSnapshot = function(_, reason, opts)
        requests[#requests + 1] = { reason = reason, opts = opts }
        return true
    end
    Sync:HandleConsumablesConfig(admin, {
        sessionId = "s1",
        profileId = "missing-profile-id",
        generation = 1,
        configSeq = 1,
    })
    assertEq(#requests, 0, "config for a missing profile does not request a gap snapshot")
    local function heartbeat()
        local hb = { profileId = coordP._profileId, sessionId = "s1", coordinator = admin }
        local desc = C.Descriptor(coordP)
        hb.consumablesGeneration = desc.generation
        hb.consumablesConfigSeq = desc.configSeq
        hb.consumablesConfigFingerprint = desc.configFingerprint
        hb.consumablesEventCount = desc.eventCount
        hb.consumablesEventFingerprint = desc.eventFingerprint
        hb.consumablesArchiveCount = desc.archiveCount
        hb.consumablesArchiveFingerprint = desc.archiveFingerprint
        Sync:_ConsiderConsumablesCatchUp(hb)
    end
    assertTrue(S.NeedsCatchUp(C.Descriptor(followerP), C.Descriptor(coordP)), "a follower missing a donation needs catch-up")
    assertEq(S.CatchUpKind(C.Descriptor(followerP), C.Descriptor(coordP)), "ahead", "a missing donation is an ahead catch-up")
    heartbeat()
    assertEq(#requests, 1, "a heartbeat ahead of the follower requests one snapshot")
    assertEq(requests[1].reason, "consumables-catchup", "the snapshot request is a consumables catch-up")
    for _ = 1, 10 do heartbeat() end
    assertEq(#requests, 1, "repeated identical heartbeats do not request more snapshots")
    C.MergeSnapshot(followerP, C.ExportSnapshot(coordP), { consumablesFromCoordinator = true })
    Sync:_NoteConsumablesSnapshot(followerP, true)
    assertFalse(S.NeedsCatchUp(C.Descriptor(followerP), C.Descriptor(coordP)), "the coordinator snapshot converges the ledger")
    assertEq(C.ContributionTotal(followerP, donor, aqirite), 6, "the follower sees the donation after catch-up")
    heartbeat()
    assertEq(#requests, 1, "a converged follower does not request again")
    resetSync()
end

local function checkCatchUpRules()
    local base = { generation = 2, configSeq = 3, eventCount = 4, eventFingerprint = 11, archiveCount = 1, archiveFingerprint = 7 }
    local function remote(changes)
        local copy = {}
        for k, v in pairs(base) do copy[k] = v end
        for k, v in pairs(changes or {}) do copy[k] = v end
        return copy
    end
    assertFalse(S.NeedsCatchUp(base, remote()), "identical descriptors need no catch-up")
    assertEq(S.CatchUpKind(base, remote()), "none", "identical descriptors are catch-up kind none")
    assertTrue(S.NeedsCatchUp(base, remote({ generation = 3 })), "a newer generation needs catch-up")
    assertTrue(S.NeedsCatchUp(base, remote({ configSeq = 4 })), "a newer config needs catch-up")
    assertTrue(S.NeedsCatchUp(base, remote({ eventCount = 5 })), "more remote events need catch-up")
    assertTrue(S.NeedsCatchUp(base, remote({ eventFingerprint = 12 })), "a different event fingerprint needs catch-up")
    assertEq(S.CatchUpKind(base, remote({ eventFingerprint = 12 })), "fingerprint", "a fingerprint-only difference is kind fingerprint")
    assertTrue(S.NeedsCatchUp(base, remote({ archiveCount = 2 })), "a different archive count needs catch-up")
    assertTrue(S.NeedsCatchUp(base, remote({ archiveFingerprint = 8 })), "a different archive fingerprint needs catch-up")
    assertFalse(S.NeedsCatchUp(base, {}), "a remote without a descriptor needs no catch-up")
    assertFalse(S.NeedsCatchUp(base, remote({ generation = 1, configSeq = 1, eventCount = 2 })), "an older remote needs no catch-up")
end

-- ---------------------------------------------------------------------------
-- Runtime: inventory, reminders, review, and guild bank deposits
-- ---------------------------------------------------------------------------

local function runtimeFixture(id)
    resetWorld()
    resetRuntime()
    resetSync()
    reminderCalls = {}
    SF.SettingsStore.values = {}
    SF.LootHelperWindow._frame = FrameMock("Frame")
    local p = configured(id)
    world.activeProfile = p
    SF.lootHelperDB.profiles = { [p._profileId] = p }
    world.bags[0] = {
        [1] = { itemId = aqirite, count = 15 },
        [2] = { itemId = aqirite, count = 10 },
        [3] = { itemId = junk, count = 50 },
    }
    world.bags[5] = { [1] = { itemId = aqiriteRank2, count = 7 } }
    world.bank[2] = { [1] = { itemId = aqirite, count = 18 } }
    world.bank[1] = { [1] = { itemId = aqirite, count = 5 } }
    return p
end

local function lastReminder()
    local call = reminderCalls[#reminderCalls]
    return call and call.visible
end

local function checkRuntimeInventory()
    local p = runtimeFixture("rt-inventory")
    world.bankOpen = true
    local collected = RT:Collect()
    assertTrue(collected.usable, "an open configured tab with permission is usable")
    assertEq(collected.access.action, "deposit", "the open bank offers deposit")
    assertEq(#collected.plan.lines, 1, "only requested carried items are detected")
    assertEq(collected.plan.lines[1].itemId, aqirite, "the requested item is detected")
    assertEq(collected.plan.lines[1].quantity, 25, "carried stacks across bag slots are summed")
    assertEq(collected.plan.lines[1].name, "Item190000", "plan lines carry the item name")
    assertEq(RT.bagCounts[junk], 50, "non-requested items are scanned but ignored by the plan")

    RT.qtyOverrides[aqirite] = 999
    assertEq(RT:Collect().plan.lines[1].quantity, 25, "an edited quantity clamps to the carried count")
    RT.qtyOverrides[aqirite] = 4
    assertEq(RT:Collect().plan.lines[1].quantity, 4, "an edited quantity below the carried count is kept")
    RT.qtyOverrides = {}

    world.bankOpen = false
    collected = RT:Collect()
    assertFalse(collected.usable, "a closed bank without Mobile Banking is not usable")
    assertEq(#collected.plan.lines, 0, "without a usable path the plan is empty")
    world.mobileKnown = true
    assertTrue(RT:Collect().usable, "Mobile Banking off cooldown is usable")
    world.mobileCooldown = true
    assertFalse(RT:Collect().usable, "Mobile Banking on cooldown is not usable")
    world.mobileKnown = false
    world.mobileCooldown = false

    world.bankOpen = true
    world.clubId = "club-other"
    local wrong = RT:Collect()
    assertFalse(wrong.access.visible, "another guild hides guild bank actions")
    world.clubId = "club-1"
    world.currentTab = 1
    assertFalse(RT:Collect().usable, "viewing another tab is not a usable deposit path")
    assertEq(RT:Collect().access.reason, "wrong_tab", "viewing another tab reports wrong_tab rather than no_permission")
    world.currentTab = 2
    world.canDeposit[2] = false
    assertEq(RT:Collect().access.reason, "no_permission", "a tab without deposit permission is reported")
    world.canDeposit[2] = true
    world.numSlots = 1
    assertTrue(RT:Collect().usable, "a full tab with room on a matching stack is usable")
    world.bank[2][1].count = 20
    assertEq(RT:Collect().access.reason, "tab_full", "a full tab with no stack room is reported")
    world.numSlots = 4
    world.bank[2][1].count = 18

    world.bindTypes[flask] = 1
    assertFalse(RT:Transferable(flask), "a soulbound item is not transferable")
    world.bindTypes[flask] = 0
    assertTrue(RT:Transferable(flask), "an unbound item is transferable")
    world.unknownItems[junk] = true
    local unknown, unknownErr = RT:Transferable(junk)
    assertEq(unknown, nil, "uncached item data is not yet known")
    assertTrue(contains(unknownErr, "not ready"), "uncached item data asks to try again")
    RT:Transferable(junk)
    assertEq(#world.loadRequests, 1, "uncached item data is requested once")
    assertFalse(RT:Transferable("nope"), "text without an item id is rejected")
    unchanged(p, "runtime inventory")
end

local function checkRuntimeReminder()
    local p = runtimeFixture("rt-reminder")
    world.mobileKnown = true
    local window = SF.LootHelperWindow._frame
    RT:RefreshReminder()
    assertTrue(lastReminder(), "the reminder shows by default when carrying requested items with a usable path")
    assertEq(#(window.hooks.OnShow or {}), 1, "the reminder hooks the window OnShow once")

    SF.SettingsStore.values["lootHelper.showRaidSupplyReminders"] = false
    RT:RefreshReminder()
    assertFalse(lastReminder(), "the personal setting disables the reminder")
    SF.SettingsStore.values["lootHelper.showRaidSupplyReminders"] = true
    RT:RefreshReminder()
    assertTrue(lastReminder(), "re-enabling the setting restores the reminder")

    world.mobileKnown = false
    RT:RefreshReminder()
    assertFalse(lastReminder(), "without a usable guild bank path the reminder is hidden")
    world.mobileKnown = true

    world.bags[0][1].count = 0
    world.bags[0][2].count = 0
    RT:RefreshReminder()
    assertFalse(lastReminder(), "carrying only non-requested items hides the reminder")
    world.bags[0][1].count = 15
    world.bags[0][2].count = 10

    window:Hide()
    RT:RefreshReminder()
    assertFalse(lastReminder(), "a hidden Loot Helper window hides the reminder")
    window:Show()

    RT:RefreshReminder()
    assertTrue(lastReminder(), "the reminder is visible before dismissal")
    reminderCalls[#reminderCalls].onDismiss()
    assertTrue(RT.dismissed, "dismissing marks the reminder dismissed for the session")
    assertFalse(lastReminder(), "dismissing hides the reminder immediately")
    RT:OnProfileChanged(p)
    RT:RefreshReminder()
    assertFalse(lastReminder(), "the dismissal lasts for the session")
    assertEq(SF.SettingsStore.values["lootHelper.showRaidSupplyReminders"], true, "dismissal does not change the saved setting")

    RT.dismissed = false
    local frames = frameCount
    local calls = #reminderCalls
    for _ = 1, 100 do RT:RefreshReminder() end
    assertEq(#reminderCalls, calls + 100, "each refresh updates the reminder exactly once")
    assertEq(#(window.hooks.OnShow or {}), 1, "repeated refreshes do not add window hooks")
    assertEq(#(window.hooks.OnHide or {}), 1, "repeated refreshes do not add hide hooks")
    assertEq(frameCount, frames, "repeated refreshes allocate no frames")
    assertEq(#world.after, 0, "repeated refreshes schedule no deferred work")
    assertEq(#world.timers, 0, "repeated refreshes create no timers")

    window.hooks.OnHide[1]()
    assertFalse(RT.reminderShown, "hiding the window clears the reminder state")
end

local function checkRuntimeReview()
    local p = runtimeFixture("rt-review")
    world.bankOpen = true
    RT:OnBankOpened()
    local review = RT.review
    assertTrue(review ~= nil and review:IsShown(), "opening the guild bank auto-opens the review when carrying requested items")
    assertEq(review.Rows[1].Text.text, "Guild Bank", "the review groups lines under the Guild Bank")
    local row = review.Rows[2]
    assertEq(row.Text.text, "Item190000 x25", "the review shows the requested item and quantity")
    assertEq(row.Button.text, "Deposit", "the review action is Deposit")
    assertTrue(row.Button.enabled, "the Deposit action is enabled when the configured tab can take deposits")
    assertTrue(review.Rows[3] == nil or not review.Rows[3]:IsShown(), "non-requested items are not listed")
    assertEq(review.Status.text, "The configured guild bank tab can take deposits.", "the review explains the deposit path")

    review:Hide()
    RT:OnBankOpened()
    assertFalse(review:IsShown(), "the review auto-opens only once per bank visit")
    RT:OnBankClosed()
    RT:OnBankOpened()
    assertTrue(review:IsShown(), "a new bank visit can auto-open the review again")

    RT:OnBankClosed()
    review:Hide()
    world.currentTab = 1
    RT:OnBankOpened()
    assertFalse(review:IsShown(), "opening on the wrong tab does not auto-open the review")
    assertFalse(RT.autoReviewedThisOpen, "a non-actionable open does not latch auto-review")
    world.currentTab = 2
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertTrue(review:IsShown(), "switching to the configured tab can auto-open the review")
    row = review.Rows[2]
    assertTrue(row ~= nil, "the review still has the deposit row after a tab switch")

    row.Edit:SetText("999")
    row.Edit.scripts.OnEnterPressed(row.Edit)
    assertEq(RT.qtyOverrides[aqirite], 25, "an edited review quantity clamps to the carried count")
    row.Edit:SetText("3")
    row.Edit.scripts.OnEnterPressed(row.Edit)
    assertEq(review.Rows[2].Text.text, "Item190000 x3", "the review shows the edited quantity")

    row.Edit:SetText("7")
    row.Button.scripts.OnClick(row.Button)
    assertEq(RT.qtyOverrides[aqirite], 7, "Deposit commits the edit-box quantity without Enter")
    assertTrue(RT.depositWork ~= nil or RT.depositIntent ~= nil or #world.places > 0,
        "Deposit starts after committing the unentered edit")
    RT:CancelDepositWork()
    RT.depositIntent = nil
    world.places = {}
    world.after = {}

    local rows = #review.Rows
    for _ = 1, 20 do RT:RebuildReview() end
    assertEq(#review.Rows, rows, "rebuilding the review reuses its rows")

    world.bags[0][1].count = 0
    world.bags[0][2].count = 0
    RT:RebuildReview()
    assertEq(review.Rows[1].Text.text, "No raid supplies to deposit.", "the review says when nothing is left to deposit")
    unchanged(p, "runtime review")
end

local function startDeposit(line)
    local collected = RT:Collect()
    RT:BeginDeposit(line or collected.plan.lines[1], collected)
    return collected
end

local function placedTabs()
    local tabs = {}
    for i = 1, #world.places do tabs[world.places[i].tab] = true end
    return tabs
end

local function checkRuntimeDeposit()
    local p = runtimeFixture("rt-deposit")
    world.bankOpen = true
    startDeposit()
    assertEq(#world.places, 1, "a deposit places one target per frame")
    assertEq(world.splits[1] and world.splits[1].count, 2, "the first place splits only the room on the partial stack")
    local ran = drainAfter(32)
    assertTrue(ran <= 6, "multi-place continuations are bounded")
    assertEq(#world.after, 0, "multi-place continuations drain")
    assertEq(#world.places, 3, "a deposit continues across partial stacks and empty slots")
    local tabs = placedTabs()
    assertTrue(tabs[2] and not tabs[1], "deposits go only to the configured tab")
    assertEq(world.bank[2][1].count, 20, "the partial guild bank stack is topped up")
    assertEq(world.bank[2][2].count + world.bank[2][3].count, 23, "the rest lands in empty slots")
    assertEq(world.bank[1][1].count, 5, "the other tab is untouched")
    assertEq(world.withdrawAttempts, 0, "a deposit never picks up from the guild bank")
    assertTrue(type(RT.depositIntent) == "table", "the deposit waits for confirmation")
    assertEq(#p._consumableEvents, 0, "nothing is recorded before the bank confirms")
    assertEq(#liveTimers(), 1, "one confirmation deadline is armed")

    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertEq(RT.depositIntent, nil, "the confirmed deposit clears its intent")
    assertEq(#liveTimers(), 0, "the confirmed deposit cancels its deadline")
    assertEq(#p._consumableEvents, 1, "a confirmed deposit records one donation")
    local event = p._consumableEvents[1]
    assertEq(event.type, C.EVENT.DONATION, "the recorded event is a donation")
    assertEq(event.source, "guildbank", "the recorded donation is from the guild bank")
    assertEq(event.actor, donor, "the recorded donation credits the depositor")
    assertEq(event.quantity, 25, "the recorded donation matches what landed")
    assertTrue(S.RemoteEventIdOk(event.id, donor), "the donation id names the depositor for sync authorization")
    assertEq(C.ContributionTotal(p, donor, aqirite), 25, "the depositor's contribution total updates")
    assertEq(#world.warnings, 0, "a clean deposit shows no warnings")
    assertEq(#(p._consumablesUnsent or {}), 1, "an out-of-session deposit is queued for later sync")

    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    RT:OnEvent("BAG_UPDATE_DELAYED")
    assertEq(#p._consumableEvents, 1, "later bank events do not record the deposit again")
    assertEq(fireTimers(), 0, "no timers remain after the deposit")
    local ok, bad = onlyDonationAndReset(p)
    assertTrue(ok, "runtime deposits create no receipt or custody events (" .. tostring(bad) .. ")")
end

local function checkRuntimeDepositPartialAndFailure()
    local p = runtimeFixture("rt-partial")
    world.bankOpen = true
    world.acceptPlaces = 1
    startDeposit()
    drainAfter(32)
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertTrue(RT.depositIntent ~= nil, "a partial deposit waits for the rest")
    assertEq(#p._consumableEvents, 0, "a partial deposit is not recorded before the deadline")
    fireTimers()
    assertEq(RT.depositIntent, nil, "the deadline finishes a partial deposit")
    assertEq(#p._consumableEvents, 1, "the deadline records the partial deposit once")
    assertEq(p._consumableEvents[1].quantity, 2, "a partial deposit records only what landed")
    assertTrue(contains(world.infos[#world.infos], "The rest is still in your bags"), "a partial deposit explains the remainder")

    p = runtimeFixture("rt-failed")
    world.bankOpen = true
    world.acceptPlaces = 0
    startDeposit()
    drainAfter(32)
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    fireTimers()
    assertEq(RT.depositIntent, nil, "a rejected deposit clears its intent at the deadline")
    assertEq(#p._consumableEvents, 0, "a rejected deposit records nothing")
    assertEq(world.bags[0][1].count + world.bags[0][2].count, 25, "rejected items stay in the bags")

    p = runtimeFixture("rt-guild-changed")
    world.bankOpen = true
    startDeposit()
    drainAfter(32)
    world.clubId = "club-other"
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertEq(#p._consumableEvents, 0, "a deposit observed in another guild records nothing")
    assertTrue(contains(world.warnings[#world.warnings], "configured guild bank tab"), "a wrong-guild deposit warns")
    assertEq(#liveTimers(), 0, "a wrong-guild deposit cancels its deadline")

    p = runtimeFixture("rt-wrong-tab")
    world.bankOpen = true
    local collected = RT:Collect()
    world.currentTab = 1
    RT:BeginDeposit(collected.plan.lines[1], collected)
    assertEq(#world.places, 0, "a deposit is blocked while another tab is displayed")
    assertEq(RT.depositWork, nil, "a blocked wrong-tab deposit leaves no work")
    assertTrue(contains(world.warnings[#world.warnings], "Open the configured guild bank tab"), "a wrong-tab deposit says which tab to open")

    p = runtimeFixture("rt-overdraw")
    world.bankOpen = true
    collected = RT:Collect()
    local greedy = {}
    for k, v in pairs(collected.plan.lines[1]) do greedy[k] = v end
    greedy.quantity = 99
    RT:BeginDeposit(greedy, collected)
    assertEq(#world.places, 0, "a quantity above the carried count is not deposited")
    assertTrue(contains(world.warnings[#world.warnings], "no longer have that many"), "an over-large quantity explains why")

    p = runtimeFixture("rt-combat")
    world.bankOpen = true
    world.inCombat = true
    startDeposit()
    assertEq(#world.places, 0, "deposits wait until combat ends")
    world.inCombat = false

    p = runtimeFixture("rt-busy")
    world.bankOpen = true
    RT.depositIntent = { profileId = p._profileId }
    startDeposit()
    assertEq(#world.places, 0, "a second deposit waits for the first")
    assertTrue(contains(world.warnings[#world.warnings], "already in progress"), "a concurrent deposit explains why")
    RT.depositIntent = nil

    p = runtimeFixture("rt-empty-cursor")
    world.bankOpen = true
    world.cursorBroken = true
    startDeposit()
    assertEq(world.withdrawAttempts, 0, "an empty cursor never picks up a guild bank slot")
    assertEq(#world.places, 0, "an empty cursor places nothing")
    assertEq(RT.depositWork, nil, "an empty cursor ends the deposit work")
    assertEq(#p._consumableEvents, 0, "an empty cursor records nothing")

    p = runtimeFixture("rt-locked")
    world.bankOpen = true
    world.bags[0][1].locked = true
    startDeposit()
    local ran = drainAfter(200)
    assertTrue(ran <= 25, "a permanently locked source stack stops retrying")
    assertEq(#world.after, 0, "lock retries drain")
    assertEq(#world.places, 0, "a locked source stack places nothing")
    assertEq(RT.depositWork, nil, "a locked source stack ends the deposit work")
    assertEq(#p._consumableEvents, 0, "a locked source stack records nothing")
end

local function checkRuntimeCancelAndDeferredDelete()
    local deleted = {}
    SF.DeleteLootHelperProfile = function(_, id)
        deleted[#deleted + 1] = id
        SF.lootHelperDB.profiles[id] = nil
    end
    local p = runtimeFixture("rt-cancel")
    world.bankOpen = true
    assertFalse(RT:DeferProfileDelete(p), "a profile without pending deposit work is not deferred")
    world.bags[0][1].locked = true
    startDeposit()
    assertTrue(RT.depositWork ~= nil, "a waiting deposit keeps its work")
    assertTrue(RT:DeferProfileDelete(p), "deleting a profile with pending deposit work is deferred")
    assertEq(#deleted, 0, "the deferred delete waits for the deposit")
    RT:CancelDepositWork()
    assertEq(RT.depositWork, nil, "cancelling clears the deposit work")
    assertEq(deleted[1], p._profileId, "cancelling completes the deferred delete")
    assertEq(p._sfConsumablesDeleteAfter, nil, "the deferred delete flag is cleared")
    drainAfter(32)
    assertEq(#world.places, 0, "a cancelled deposit's queued continuation does nothing")
    RT:CancelDepositWork()
    assertEq(#deleted, 1, "cancelling again does not delete again")

    deleted = {}
    p = runtimeFixture("rt-close")
    world.bankOpen = true
    world.bags[0][1].locked = true
    startDeposit()
    RT:DeferProfileDelete(p)
    RT:OnBankClosed()
    assertEq(RT.depositWork, nil, "closing the guild bank cancels deposit work")
    assertEq(deleted[1], p._profileId, "closing the guild bank completes the deferred delete")
    drainAfter(32)
    assertEq(#world.places, 0, "nothing is placed after the bank closes")
    SF.DeleteLootHelperProfile = nil
end

-- ---------------------------------------------------------------------------
-- Lifecycle: Clear and CopyConfiguration
-- ---------------------------------------------------------------------------

local function checkClear()
    local p = configured("clear")
    C.CommitEvents(p, "deposit-Donor-Realm-9",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 12))
    assertFalse(select(1, C.Clear(p, donor)), "a non-admin cannot clear")
    assertFalse(select(1, C.Clear(p, nil)), "an anonymous actor cannot clear")
    assertEq(p._consumables.generation, 1, "a denied clear changes nothing")

    local seq = p._consumables.configSeq
    assertTrue(select(1, C.ApplyOp(p, { name = "clear" }, admin)), "an admin can clear")
    local cfg = p._consumables
    assertEq(cfg.generation, 2, "clear starts a new generation")
    assertEq(cfg.guild, nil, "clear removes the guild")
    assertEq(cfg.bankTab, nil, "clear removes the bank tab")
    assertEq(next(cfg.requestedItems), nil, "clear removes requested items")
    assertEq(cfg.configSeq, seq + 1, "clear bumps the config sequence")
    assertEq(#p._consumableEvents, 0, "clear leaves no live events")
    local archived = eventTypes(p)
    assertEq(archived[C.EVENT.DONATION], 1, "clear archives earlier donations")
    assertEq(archived[C.EVENT.RESET], 1, "clear archives one reset event")
    assertEq(C.Descriptor(p).archiveCount, 2, "the descriptor counts archived history")
    local rows = C.HistoryRows(p)
    assertEq(#rows, 2, "history still shows the donation and the reset")
    assertTrue(contains(rows[1].text, "cleared"), "the reset is the newest history row")
    assertTrue(contains(rows[2].text, "donated 12"), "the earlier donation remains in history")
    assertEq(C.ContributionTotal(p, donor, aqirite), 0, "contributions restart in the new generation")
    unchanged(p, "clear")

    assertTrue(select(1, C.SetGuild(p, admin, { guid = "club-2", name = "Other" }, 1)), "clear unlocks guild configuration")
    local late = C.CommitEvents(p, "late-deposit",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 3))
    assertTrue(late, "a deposit finishing after clear still records")
    assertEq(#p._consumableEvents, 0, "a deposit from the old generation goes to history, not the new ledger")
    assertEq(C.ContributionTotal(p, donor, aqirite), 0, "an old-generation deposit does not count toward the new generation")
    assertTrue(contains(C.ClearConfirmation(p), "Logs are kept"), "the clear confirmation says logs are kept")
end

local function checkCopyConfiguration()
    local source = configured("copy-source")
    C.AddRequestedItem(source, admin, flask)
    C.CommitEvents(source, "deposit-Donor-Realm-5",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 4))
    local dest = profile("copy-dest", admin)
    dest._consumablesPendingFreezes = { { token = "old" } }
    C.CommitEvents(dest, "deposit-Vann-Realm-1",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = vann, requested = true }, 9))
    assertTrue(C.CopyConfiguration(source, dest), "configuration copies to another profile")
    assertEq(dest._consumables.guild.guid, "club-1", "the guild is copied")
    assertEq(dest._consumables.bankTab, 2, "the bank tab is copied")
    assertTrue(C.IsRequested(dest, aqirite) and C.IsRequested(dest, flask), "requested items are copied")
    assertEq(#dest._consumableEvents, 0, "accounting events are not copied")
    assertEq(#(dest._consumableEventArchive or {}), 0, "history is not copied")
    assertEq(C.ContributionTotal(dest, donor, aqirite), 0, "the copy has no contributions")
    assertEq(dest._consumables.generation, 1, "the copy starts at generation 1")
    assertEq(dest._consumablesPendingFreezes, nil, "the copy clears legacy freezes")
    assertEq(dest._consumables.crafters, nil, "the copy has no crafters")
    C.RemoveRequestedItem(dest, admin, flask)
    assertTrue(C.IsRequested(source, flask), "editing the copy does not change the source")
    assertEq(#source._consumableEvents, 1, "the source keeps its events")
    assertEq(C.ContributionTotal(source, donor, aqirite), 4, "the source keeps its contributions")
end

checkGuildConfiguration()
checkRequestedItems()
checkApplyOpAndSettingsModel()
checkMigration()
checkAccessRules()
checkReminderRules()
checkPlanAndWorkflow()
checkAccounting()
checkAuthorizeAndConfigSync()
checkRemoteEvents()
checkCatchUpRules()
checkSessionTransport()
checkRuntimeInventory()
checkRuntimeReminder()
checkRuntimeReview()
checkRuntimeDeposit()
checkRuntimeDepositPartialAndFailure()
checkRuntimeCancelAndDeferredDelete()
checkClear()
checkCopyConfiguration()

if failures > 0 then
    io.stderr:write(string.format("%d failed, %d passed\n", failures, passes))
    os.exit(1)
end
io.stdout:write(string.format("%d passed, 0 failed\n", passes))
