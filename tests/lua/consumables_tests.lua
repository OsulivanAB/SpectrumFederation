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
        bankReadable = true,
        cursor = nil,
        cursorBroken = false,
        maxStack = 20,
        places = {},
        splits = {},
        pickups = {},
        withdrawAttempts = 0,
        acceptPlaces = nil,
        inCombat = false,
        mobileKnown = false,
        mobileCooldown = false,
        mobileCooldownStart = nil,
        mobileCooldownDuration = nil,
        tabViewable = {},
        tabSelects = {},
        tabQueries = {},
        bindTypes = {},
        boundSlots = {},
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
        world.pickups[#world.pickups + 1] = { bag = bag, slot = slot }
        local row = bagSlot(bag, slot)
        if not row or row.count <= 0 then return end
        world.cursor = { itemId = row.itemId, count = row.count, bag = bag, slot = slot }
        row.count = 0
    end,
}

function GetCursorInfo()
    if world.cursorBroken or not world.cursor then return nil end
    return world.cursor.kind or "item", world.cursor.itemId
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
    if not world.bankReadable then return nil end
    local row = bankSlot(tab, slot)
    if not row or row.count <= 0 then return nil end
    return "|Hitem:" .. tostring(row.itemId) .. "::|h[Item]|h"
end
function GetGuildBankItemInfo(tab, slot)
    if not world.bankReadable then return nil, 0 end
    local row = bankSlot(tab, slot)
    return nil, row and row.count or 0
end
function GetGuildBankTabInfo(tab)
    local viewable = world.tabViewable[tab]
    if viewable == nil then viewable = true end
    if world.tabMissing and world.tabMissing[tab] then
        return nil, nil, false, false
    end
    return "Tab " .. tostring(tab), "icon", viewable, world.canDeposit[tab]
end
function GetCurrentGuildBankTab() return world.currentTab end
function SetCurrentGuildBankTab(tab)
    world.currentTab = tab
    world.tabSelects[#world.tabSelects + 1] = tab
end
function QueryGuildBankTab(tab)
    world.tabQueries[#world.tabQueries + 1] = tab
end
C_Club = { GetGuildClubId = function() return world.clubId end }
function GetGuildInfo() return world.guildName, nil, nil, world.guildRealm end
-- Retail exposes C_SpellBook. Legacy IsPlayerSpell remains as a fallback only.
Enum = {
    SpellBookSpellBank = { Player = 0, Pet = 1 },
    PlayerInteractionType = { GuildBanker = 10 },
}
C_SpellBook = {
    -- Guild perks like Mobile Banking are known but not always listed in the
    -- spellbook UI. Returning false here proves production does not treat
    -- IsSpellInSpellBook as the authority for Mobile Banking.
    IsSpellInSpellBook = function() return false end,
    IsSpellKnown = function() return world.mobileKnown end,
}
function IsPlayerSpell() return world.mobileKnown end
C_Spell = {
    GetSpellInfo = function() return { name = "Mobile Banking" } end,
    GetSpellTexture = function() return "Interface\\Icons\\INV_Misc_BagCoin_07" end,
    GetSpellCooldown = function()
        if world.mobileCooldown then
            return {
                startTime = world.mobileCooldownStart or GetTime(),
                duration = world.mobileCooldownDuration or 30,
                isEnabled = true,
                isActive = true,
                modRate = 1,
            }
        end
        return {
            startTime = 0,
            duration = 0,
            isEnabled = true,
            isActive = false,
            modRate = 1,
        }
    end,
}
GameTooltip = {
    owner = nil,
    text = nil,
    spellId = nil,
    itemId = nil,
    hyperlink = nil,
    shown = false,
}
function GameTooltip:SetOwner(owner)
    self.owner = owner
end
function GameTooltip:SetSpellByID(spellId)
    self.spellId = spellId
    self.text = "Mobile Banking"
end
function GameTooltip:SetItemByID(itemId)
    self.itemId = itemId
    self.text = "Item" .. tostring(itemId)
end
function GameTooltip:SetHyperlink(link)
    self.hyperlink = link
    self.text = tostring(link)
end
function GameTooltip:SetText(text)
    self.text = text
end
function GameTooltip:Show()
    self.shown = true
end
function GameTooltip:Hide()
    self.shown = false
end
function GetItemIcon(itemId)
    return "Interface\\Icons\\Item" .. tostring(itemId)
end
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
    IsBound = function(loc)
        return type(loc) == "table" and world.boundSlots[loc.key] == true
    end,
}
ItemLocation = {
    CreateFromBagAndSlot = function(_, bag, slot)
        return { key = tostring(bag) .. ":" .. tostring(slot) }
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
local createdFrames = {}
local FrameMethods = {}
local function FrameMock(kind, parent)
    frameCount = frameCount + 1
    return setmetatable({
        kind = kind,
        parent = parent,
        scripts = {},
        hooks = {},
        shown = true,
        enabled = true,
        text = "",
        width = 0,
        height = 0,
    }, { __index = FrameMethods })
end
local function noop() end
for _, name in ipairs({
    "ClearAllPoints", "SetAllPoints", "SetFrameStrata", "EnableMouse", "SetMovable",
    "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetBackdrop", "SetJustifyH",
    "SetAutoFocus", "SetNumeric", "SetScrollChild", "RegisterEvent",
    "SetMinMaxValues", "SetStatusBarTexture", "SetStatusBarColor", "SetWordWrap",
}) do
    FrameMethods[name] = noop
end
function FrameMethods:SetWidth(w)
    self.width = tonumber(w) or 0
end
function FrameMethods:GetWidth()
    return self.width or 0
end
function FrameMethods:SetHeight(h)
    self.height = tonumber(h) or 0
end
function FrameMethods:GetHeight()
    return self.height or 380
end
function FrameMethods:SetSize(w, h)
    self:SetWidth(w)
    self:SetHeight(h)
end
function FrameMethods:GetLeft() return self.pointLeft or 100 end
function FrameMethods:GetBottom() return self.pointBottom or 200 end
function FrameMethods:SetPoint(point, relative, relativePoint, x, y)
    self.anchor = {
        point = point,
        relative = relative,
        relativePoint = relativePoint,
        x = x,
        y = y,
    }
    if point == "BOTTOMLEFT" and relativePoint == "BOTTOMLEFT" then
        self.pointLeft = x
        self.pointBottom = y
    end
end
function FrameMethods:ClearAllPoints()
    self.anchor = nil
end
function FrameMethods:SetScript(name, fn) self.scripts[name] = fn end
function FrameMethods:HookScript(name, fn)
    self.hooks[name] = self.hooks[name] or {}
    table.insert(self.hooks[name], fn)
end
function FrameMethods:SetAttribute(key, value)
    self.attributes = self.attributes or {}
    self.attributes[key] = value
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
function FrameMethods:HasFocus() return self.focused == true end
function FrameMethods:SetFocus() self.focused = true end
function FrameMethods:ClearFocus() self.focused = false end
function FrameMethods:SetValue(value) self.value = value end
function FrameMethods:CreateFontString() return FrameMock("FontString", self) end
function FrameMethods:CreateTexture()
    local tex = FrameMock("Texture", self)
    tex.texture = nil
    tex.desaturated = false
    function tex:SetTexture(value) self.texture = value end
    function tex:SetDesaturated(value) self.desaturated = value and true or false end
    function tex:SetTexCoord() end
    function tex:SetColorTexture() end
    function tex:SetVertexColor() end
    return tex
end
function FrameMethods:RegisterForClicks() end
function FrameMethods:SetCooldown(startTime, duration)
    self.cooldownStart = startTime
    self.cooldownDuration = duration
end
function FrameMethods:Clear()
    self.cooldownStart = nil
    self.cooldownDuration = nil
end
function CreateFrame(kind, name, parent, template)
    local frame = FrameMock(kind, parent)
    frame.name = name
    frame.template = template
    createdFrames[#createdFrames + 1] = frame
    return frame
end
UIParent = FrameMock("Frame")
GuildBankFrame = FrameMock("Frame")
GuildBankFrame.height = 420
function GuildBankFrame:IsShown() return world.bankOpen end
-- Blizzard GuildBankTabTemplate geometry used for alignment clearance tests.
-- Clickable frame is 42 wide; BACKGROUND texture is 64 wide and overhangs.
local GUILD_BANK_SIDE_TAB_FRAME_WIDTH = 42
local GUILD_BANK_SIDE_TAB_TEXTURE_WIDTH = 64
local GUILD_BANK_SIDE_TAB_ANCHOR_X = -1
local GUILD_BANK_SIDE_TAB_VISIBLE_EXTENT =
    GUILD_BANK_SIDE_TAB_ANCHOR_X + GUILD_BANK_SIDE_TAB_TEXTURE_WIDTH
-- Visible art ends ~63 past GuildBankFrame TOPRIGHT; helper must clear that.
-- Compact donation helper target (~half of the previous 480 width).
local REVIEW_COMPACT_WIDTH_MIN = 230
local REVIEW_COMPACT_WIDTH_MAX = 280

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
-- Match production: SF.LootHelperWindow.Window owns the frame and reminder API.
SF.LootHelperWindow = { Window = {} }
local LHWindow = SF.LootHelperWindow.Window
LHWindow._frame = FrameMock("Frame")
function LHWindow:IsMinimized()
    return self._frame and self._frame.__sfMinimized and true or false
end
function LHWindow:SetSupplyReminder(visible, mobile)
    reminderCalls[#reminderCalls + 1] = {
        visible = visible,
        mobile = mobile,
    }
    local reminder = self._frame and self._frame.Content and self._frame.Content.SupplyReminder
    if reminder and reminder.MobileAnchor then
        reminder.MobileAnchor:SetShown(visible and mobile and mobile.visible and true or false)
    end
end

local clock = 1000
local function load(path)
    local chunk = assert(loadfile(path))
    chunk("SpectrumFederation", SF)
end
-- Locale must load before modules that render localized user-facing text.
load("SpectrumFederation/locale/enUS.lua")
load("SpectrumFederation/modules/LootHelper/Consumables.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesRouting.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesWorkflow.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesSync.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesObservation.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesVerification.lua")
load("SpectrumFederation/modules/LootHelperSync/19_Consumables.lua")
load("SpectrumFederation/modules/LootHelperSync/07_Validation.lua")
load("SpectrumFederation/modules/LootHelperSync/08_Requests.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua")

local C = SF.Consumables
local R = SF.ConsumablesRouting
local W = SF.ConsumablesWorkflow
local S = SF.ConsumablesSync
local Sync = SF.LootHelperSync
local RT = SF.ConsumablesRuntime
local O = SF.ConsumablesObservation
local V = SF.ConsumablesVerification
C._clock = function()
    clock = clock + 1
    return clock
end
if O then
    O._clock = function() return clock end
end
if V then
    V._clock = function() return clock end
end
_G.time = function() return clock end

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
        -- Default roster used by attribution guards; tests may mutate _memberIds.
        _memberIds = { admin, donor, vann, "DonorAlt-Realm", "HelperAdmin-Realm" },
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
    function p:GetMemberIds()
        return self._memberIds or {}
    end
    function p:getMemberByID(memberId)
        for i = 1, #(self._memberIds or {}) do
            if self._memberIds[i] == memberId then
                return { identifier = memberId }
            end
        end
        return nil
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

local function onlyKnownAccountingEvents(p)
    for t in pairs(eventTypes(p)) do
        if t ~= C.EVENT.DONATION and t ~= C.EVENT.RESET and t ~= C.EVENT.ADJUSTMENT then
            return false, t
        end
    end
    return true
end

-- Compatibility alias used by older deposit-path assertions.
local onlyDonationAndReset = onlyKnownAccountingEvents

local function resetRuntime()
    RT.depositWork = nil
    RT.depositIntent = nil
    RT.depositTimer = nil
    RT.depositContinueGen = 0
    RT.review = nil
    RT.mobileHolder = nil
    RT.mobileButtonPending = nil
    if RT.CancelMobileCooldownWatch then RT:CancelMobileCooldownWatch() end
    RT.mobileCooldownTimer = nil
    if RT.CancelBannerBankNavigation then RT:CancelBannerBankNavigation("reset") end
    RT.bannerMobileHolder = nil
    RT.bannerMobileButton = nil
    RT.bannerMobilePending = nil
    RT.bannerBankNav = nil
    RT.bannerBankNavTimer = nil
    RT.bannerBankNavGen = 0
    RT._reminderDebugFingerprint = nil
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
    if GuildBankFrame then
        GuildBankFrame.__sfConsumablesSizeHook = nil
        GuildBankFrame.height = 420
        GuildBankFrame.hooks = {}
        GuildBankFrame.anchor = nil
    end
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
    assertEq(p._consumables.requestedItems[tostring(aqirite)].goal, 0, "a newly added item defaults to goal 0")
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
    assertEq(adminModel.requestedItems[1].goal, 0, "the settings model defaults goal to 0")
    assertTrue(adminModel.requestedItems[1].canRemove, "admins can remove requested rows")
    assertTrue(adminModel.requestedItems[1].canEditGoal, "admins can edit goals")
    assertTrue(contains(adminModel.guildText, "Spectrum") and contains(adminModel.guildText, "tab 6"),
        "the guild text names the guild and tab")
    assertTrue(contains(adminModel.clearWarning, "Logs are kept"), "the clear warning says history is kept")
    local memberModel = C.SettingsModel(p, donor, false)
    assertFalse(memberModel.canEditGuild or memberModel.canManageItems or memberModel.canClear,
        "members get a read-only settings model")
    assertFalse(memberModel.requestedItems[1].canRemove, "members cannot remove requested rows")
    assertFalse(memberModel.requestedItems[1].canEditGoal, "members cannot edit goals")
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
    assertEq(migrated.requestedItems[tostring(aqirite)].goal, 0, "legacy requested items migrate to goal 0")
    assertEq(migrated.requestedItems[tostring(flask)].goal, 0, "flat legacy rows migrate to goal 0")
    assertEq(migrated.crafters, nil, "legacy crafters are cleared")
    assertEq(migrated.assignments, nil, "legacy assignments are cleared")
    assertEq(migrated.itemEpochs, nil, "legacy item epochs are cleared")
    assertEq(old._consumablesPendingFreezes, nil, "legacy pending trade freezes are cleared")
    assertEq(migrated.generation, 3, "migration keeps the generation")
    assertEq(migrated.configSeq, 7, "migration keeps the config sequence")
    assertEq(migrated.guild.guid, "club-1", "migration keeps the guild")
    assertEq(migrated.bankTab, 2, "migration keeps the bank tab")
    -- Issue #366 PR2: unreleased legacy deposit-assistant donations are discarded once.
    assertEq(#old._consumableEvents, 0, "observation-accounting migration discards legacy donations")
    assertEq(C.ContributionTotal(old, donor, aqirite), 0, "legacy donations no longer count after migration")
    assertEq(tonumber(migrated.obsAccountingSchema), C.OBS_ACCOUNTING_SCHEMA, "observation accounting schema is marked")
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

    local badLedger = { _profileId = "ledger-bad", _consumables = { ledgerSeq = 0 / 0 } }
    assertEq(C.Ensure(badLedger).ledgerSeq, 0, "a NaN ledgerSeq resets to 0")
    badLedger._consumables.ledgerSeq = -3
    assertEq(C.Ensure(badLedger).ledgerSeq, 0, "a negative ledgerSeq resets to 0")
    badLedger._consumables.ledgerSeq = math.huge
    assertEq(C.Ensure(badLedger).ledgerSeq, 0, "an infinite ledgerSeq resets to 0")
    local ledgerImport = profile("ledger-import", admin)
    ledgerImport._consumables.ledgerSeq = 3
    C.ReplaceConfig(ledgerImport, {
        generation = 1, configSeq = 1, ledgerSeq = 0 / 0, guild = GUILD, bankTab = 2,
    })
    assertEq(ledgerImport._consumables.ledgerSeq, 3, "an invalid remote ledgerSeq does not advance")
    C.ReplaceConfig(ledgerImport, {
        generation = 1, configSeq = 2, ledgerSeq = 9, guild = GUILD, bankTab = 2,
    })
    assertEq(ledgerImport._consumables.ledgerSeq, 9, "a valid remote ledgerSeq advances")
    C.ReplaceConfig(ledgerImport, {
        generation = 1, configSeq = 3, ledgerSeq = -1, guild = GUILD, bankTab = 2,
    })
    assertEq(ledgerImport._consumables.ledgerSeq, 9, "a negative remote ledgerSeq is ignored")

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
    assertTrue(R.HasReminderPath(mobile), "ready Mobile Banking is a reminder path")
    assertTrue(R.HasReminderPath(cooldown), "Mobile Banking on cooldown remains a reminder path")
    assertFalse(R.HasReminderPath(closed), "a closed bank without Mobile Banking is not a reminder path")
    assertFalse(R.HasReminderPath(nil), "missing access is not a reminder path")
end

local function checkReminderRules()
    local base = { remindersEnabled = true, windowAllowed = true, carriesRequested = true, hasReminderPath = true }
    local function with(key, value)
        local copy = {}
        for k, v in pairs(base) do copy[k] = v end
        copy[key] = value
        return copy
    end
    assertTrue(R.ReminderVisible(base), "the reminder shows for a carried requested item with a reminder path")
    assertFalse(R.ReminderVisible(with("remindersEnabled", false)), "the personal setting hides the reminder")
    assertFalse(R.ReminderVisible(with("windowAllowed", false)), "a hidden Loot Helper window hides the reminder")
    assertFalse(R.ReminderVisible(with("carriesRequested", false)), "carrying nothing requested hides the reminder")
    assertFalse(R.ReminderVisible(with("hasReminderPath", false)), "no reminder path hides the reminder")
    assertFalse(R.ReminderVisible(nil), "missing reminder input hides the reminder")
    assertTrue(R.ReminderVisible(with("isCrafter", true)), "a legacy crafter flag has no effect on reminders")
    assertEq(base.dismissed, nil, "reminder rules no longer carry a dismissed field")
    local snapshot = with("hasReminderPath", true)
    for _ = 1, 100 do R.ReminderVisible(snapshot) end
    assertEq(snapshot.hasReminderPath, true, "evaluating the reminder does not mutate its input")
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
    assertEq(plan.lines[1].available, 40, "plan lines retain the carried available count")
    assertTrue(plan.lines[1].noGoal, "default requested items are No Goal")
    assertFalse(plan.lines[1].goalComplete, "No Goal items are never goal-complete")
    assertTrue(plan.lines[1].guildBank, "plan lines target the guild bank")
    assertEq(plan.lines[1].generation, 1, "plan lines carry the configuration generation")
    assertEq(#plan.groups, 1, "the plan has one destination group")
    assertEq(plan.groups[1].key, "Guild Bank", "the destination group is the Guild Bank")
    assertTrue(plan.progress ~= nil, "the plan exposes authoritative GoalProgress")
    assertEq(#C.BuildDonationPlan(p, carried, { guildBankUsable = false }).lines, 0, "without a usable guild bank the plan is empty")
    assertEq(#C.BuildDonationPlan(p, nil, { guildBankUsable = true }).lines, 0, "no carried items means an empty plan")

    assertEq(C.SuggestedDonationQuantity(50, 200, 175), 25, "suggested quantity is min(available, remaining)")
    assertEq(C.SuggestedDonationQuantity(50, 0, 999), 50, "goal-0 suggestions use the full available count")
    local completeSuggested, completeFlag = C.SuggestedDonationQuantity(50, 100, 110)
    assertEq(completeSuggested, 0, "completed goals suggest zero")
    assertTrue(completeFlag, "completed goals report goalComplete")
    C.SetRequestedGoal(p, admin, aqirite, 200)
    C.CommitEvents(p, "plan-goal-donation", W.DepositEvents({
        generation = 1, itemId = aqirite, donor = donor, requested = true,
    }, 175))
    local limited = C.BuildDonationPlan(p, { { itemId = aqirite, available = 50, quantity = 50 } }, { guildBankUsable = true })
    assertEq(limited.lines[1].suggested, 25, "finite incomplete goals suggest the remaining need")
    assertEq(limited.lines[1].quantity, 25, "plan quantity defaults to the suggestion")
    assertEq(limited.lines[1].percent, 87, "plan lines carry the floor percent from GoalProgress")
    assertFalse(limited.lines[1].goalComplete, "incomplete goals remain depositable")
    C.CommitEvents(p, "plan-goal-complete", W.DepositEvents({
        generation = 1, itemId = aqirite, donor = donor, requested = true,
    }, 30))
    local done = C.BuildDonationPlan(p, { { itemId = aqirite, available = 50, quantity = 50 } }, { guildBankUsable = true })
    assertTrue(done.lines[1].goalComplete, "met goals stay in the plan when carried")
    assertEq(done.lines[1].percent, 102, "completed plan lines keep over-100 percents")
    assertEq(done.lines[1].quantity, 0, "completed goals suggest no deposit quantity")
    local blocked, blockedErr = C.RevalidateDonation(p, {
        itemId = aqirite, quantity = 5, generation = done.lines[1].generation,
    }, { guildBankUsable = true }, 50)
    assertFalse(blocked, "completed goals fail deposit revalidation")
    assertTrue(contains(blockedErr, "already met"), "completed-goal revalidation explains the block")
    C.SetRequestedGoal(p, admin, aqirite, 0)

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
    local nameCalls = 0
    C.HistoryRows(p, function()
        nameCalls = nameCalls + 1
        return "Aqirite"
    end, 1, 0)
    assertEq(nameCalls, 1, "history formats names only for the selected page")

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
        source = "guildbank", generation = 1, timestamp = 10,
        txnId = "ctx:test:" .. tostring(id) }
    for k, v in pairs(extra or {}) do event[k] = v end
    return event
end

local function checkAuthorizeAndConfigSync()
    local p = configured("authz")
    for _, name in ipairs({ "add_item", "remove_item", "set_goal", "set_guild", "set_bank_tab", "clear" }) do
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
    -- Non-admins cannot insert canonical donations; admins may with verified txnId.
    local memberAttempt = donation("ce:remote:Donor-Realm:1", donor, 5)
    assertFalse(select(1, S.ApplyRemoteEvent(p, memberAttempt, donor)),
        "a non-admin cannot insert a canonical donation event")
    local adminForDonor = donation("ce:remote:Admin-Realm:1", donor, 5)
    assertTrue(select(1, S.ApplyRemoteEvent(p, adminForDonor, admin)),
        "an admin-trusted donation for another donor is accepted")
    assertEq(C.ContributionTotal(p, donor, aqirite), 5, "the accepted donation counts for the actual donor")
    local ok, status = S.ApplyRemoteEvent(p, donation("ce:remote:Admin-Realm:1", donor, 5), admin)
    assertTrue(ok and status == "duplicate", "replaying a remote donation is idempotent")
    assertEq(#p._consumableEvents, 1, "a replayed remote donation is stored once")

    local cases = {
        { donation("ce:remote:Donor-Realm:2", vann, 5), donor, "unauthorized", "a non-admin donation for another player is rejected" },
        { donation("ce:remote:Vann-Realm:3", vann, 5), donor, "unauthorized", "an event id naming another player is rejected" },
        { donation("ce:remote:Donor-Realm:4", donor, 5, { source = "trade" }), donor, "unauthorized", "a trade donation is rejected" },
        { donation("ce:remote:Donor-Realm:5", donor, 5, { source = false }), donor, "unauthorized", "a donation without a guild bank source is rejected" },
        { donation("ce:remote:Donor-Realm:6", donor, 0), donor, "unauthorized", "a zero-quantity donation is rejected" },
        { donation("ce:remote:Donor-Realm:7", donor, 1.5), donor, "unauthorized", "a fractional donation is rejected" },
        { donation("ce:remote:Donor-Realm:8", donor, S.MAX_EVENT_QUANTITY + 1), donor, "unauthorized", "an oversized donation is rejected" },
        { donation("ce:remote:Donor-Realm:9", donor, 0 / 0), donor, "unauthorized", "a NaN donation is rejected" },
        { donation("ce:remote:Donor-Realm:10", donor, 5, { itemId = -1 }), donor, "unauthorized", "an invalid item id is rejected" },
        { donation("ce:remote:Admin-Realm:17", donor, 5, { txnId = false }), admin, "unauthorized", "a donation without txnId is rejected" },
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
        if event.txnId == false then event.txnId = nil end
        local accepted, why = S.ApplyRemoteEvent(p, event, sender)
        assertTrue(not accepted and why == want, message)
    end
    assertEq(#p._consumableEvents, 1, "rejected remote events are never stored")
    local ok2, bad = onlyDonationAndReset(p)
    assertTrue(ok2, "remote traffic creates no receipt or custody events (" .. tostring(bad) .. ")")

    assertTrue(select(1, S.ApplyRemoteEvent(p, { id = "ce:remote:Admin-Realm:20", type = C.EVENT.RESET, actor = admin,
        generation = 1, timestamp = 20 }, admin)), "an admin's own reset is accepted")

    -- Coordinator relay may credit a different donor when txnId provenance is present.
    local relay = donation("ce:remote:Admin-Realm:30", donor, 3, { order = 4, writer = admin })
    assertTrue(select(1, S.ApplyRemoteEvent(p, relay, admin, { coordinatorRelay = true })),
        "a coordinator relay accepts verified donor≠writer donations")
    local forgedRelay = donation("ce:remote:Donor-Realm:31", vann, 3, { order = 5, writer = donor })
    assertTrue(select(1, S.ApplyRemoteEvent(p, forgedRelay, admin, { coordinatorRelay = true })),
        "a coordinator relay with txnId may credit the stated donor under coordinator authority")
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
    for _, badOrder in ipairs({ 0, -1, 1.5, math.huge, C.MAX_EVENT_SEQ + 1 }) do
        local bad = donation("ce:x:Donor-Realm:bad-" .. tostring(badOrder), donor, 1,
            { order = badOrder, writer = donor })
        assertFalse(select(1, S.RemoteEventAdmission(false, true, bad)),
            "a follower rejects malformed coordinator order " .. tostring(badOrder))
    end
    local nanOrder = donation("ce:x:Donor-Realm:bad-nan", donor, 1, { order = 0 / 0, writer = donor })
    assertFalse(select(1, S.RemoteEventAdmission(false, true, nanOrder)), "a follower rejects NaN coordinator order")
    local boundary = donation("ce:x:Donor-Realm:boundary", donor, 1,
        { order = C.MAX_EVENT_SEQ, writer = donor })
    assertTrue(select(1, S.RemoteEventAdmission(false, true, boundary)), "the maximum sequence order is accepted")
    local beforeRelayOrder = C.EventIndex(p)[relay.id].order
    local malformedReplacement = donation(relay.id, donor, 3, { order = 2.5, writer = donor })
    assertFalse(select(1, S.ApplyRemoteEvent(p, malformedReplacement, admin, { coordinatorRelay = true })),
        "an invalid replacement order is rejected")
    assertEq(C.EventIndex(p)[relay.id].order, beforeRelayOrder,
        "a rejected replacement does not corrupt stored ordering")

    local bucket = {}
    local allowed = 0
    for _ = 1, S.MAX_REMOTE_OPS + 10 do
        if S.AllowRemoteOp(bucket, donor, 5) then allowed = allowed + 1 end
    end
    assertEq(allowed, S.MAX_REMOTE_OPS, "remote traffic from one sender is rate limited")
    assertTrue(S.AllowRemoteOp(bucket, donor, 5 + S.REMOTE_OP_WINDOW), "the rate limit resets after its window")

    assertFalse(S.AuthoritativeEventBodyOk(donation("ce:body:Donor-Realm:1", donor, 5, { source = "trade" })),
        "a trade donation body is not authoritative")
    assertFalse(S.AuthoritativeEventBodyOk({ id = "ce:body:Admin-Realm:2", type = C.EVENT.CUSTODY, actor = admin,
        itemId = aqirite, quantity = 1, generation = 1 }), "a custody body is not authoritative")
    assertTrue(S.AuthoritativeEventBodyOk(donation("ce:body:Donor-Realm:3", donor, 5)),
        "a guild bank donation body is authoritative")
    assertTrue(S.AuthoritativeEventBodyOk({
        id = "ce:body:Admin-Realm:4", type = C.EVENT.ADJUSTMENT, actor = admin, itemId = aqirite,
        quantity = -3, generation = 1,
    }), "a signed manual adjustment body is authoritative")
    assertFalse(S.AuthoritativeEventBodyOk({
        id = "ce:body:Admin-Realm:5", type = C.EVENT.ADJUSTMENT, actor = admin, itemId = aqirite,
        quantity = -3, generation = 1, source = "guildbank",
    }), "a guildbank-sourced adjustment body is not authoritative")
    assertFalse(S.AuthoritativeEventBodyOk({
        id = "ce:body:Admin-Realm:6", type = C.EVENT.ADJUSTMENT, actor = admin, itemId = aqirite,
        quantity = 0, generation = 1,
    }), "a zero-quantity adjustment body is not authoritative")
    local snapFollower = profile("snap-body", admin)
    C.MergeSnapshot(snapFollower, {
        generation = 1,
        configSeq = 1,
        guild = GUILD,
        bankTab = 2,
        requestedItems = { [tostring(aqirite)] = { itemId = aqirite } },
        events = {
            donation("ce:snap:Donor-Realm:1", donor, 5),
            donation("ce:snap:Donor-Realm:2", donor, 5, { source = "trade" }),
            { id = "ce:snap:Donor-Realm:3", type = C.EVENT.CUSTODY, actor = donor, itemId = aqirite,
              quantity = 1, generation = 1 },
            { id = "ce:snap:Admin-Realm:4", type = C.EVENT.ADJUSTMENT, actor = admin, itemId = aqirite,
              quantity = 2, generation = 1, order = 2 },
        },
    }, { consumablesFromCoordinator = true })
    assertEq(C.ContributionTotal(snapFollower, donor, aqirite), 5, "only valid guild bank snapshot bodies count for donors")
    assertEq(C.ItemDonatedTotal(snapFollower, aqirite), 7, "authoritative snapshot adjustments count toward item totals")
    assertEq(#snapFollower._consumableEvents, 2, "invalid authoritative snapshot bodies are skipped")
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

local function checkManualAdjustments()
    resetWorld()
    local p = configured("manual-adjust")
    C.CommitEvents(p, "deposit-Donor-Realm-adj",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 20))
    assertEq(C.ItemDonatedTotal(p, aqirite), 20, "seed donation establishes the item total")
    assertEq(C.ContributionTotal(p, donor, aqirite), 20, "seed donation establishes the player total")

    assertFalse(select(1, C.RecordManualAdjustment(p, donor, aqirite, 5, nil)),
        "a non-admin cannot create a manual adjustment")
    assertFalse(select(1, C.RecordManualAdjustment(p, admin, aqirite, 0, nil)),
        "a zero adjustment is rejected")
    assertFalse(select(1, C.RecordManualAdjustment(p, admin, aqirite, 1.5, nil)),
        "a fractional adjustment is rejected")
    assertFalse(select(1, C.RecordManualAdjustment(p, admin, flask, 5, nil)),
        "an unrequested item cannot be adjusted")
    assertFalse(select(1, C.RecordManualAdjustment(p, admin, aqirite, -21, nil)),
        "an adjustment that would make the item total negative is rejected")
    assertFalse(select(1, C.RecordManualAdjustment(p, admin, aqirite, -1, vann)),
        "an attributed negative adjustment cannot drive a player's contribution negative")
    assertFalse(select(1, C.RecordManualAdjustment(p, admin, aqirite, 5, nil, { asAdmin = false })),
        "Preview as Non-Admin blocks manual adjustments")

    local preview = C.PreviewManualAdjustment(p, aqirite, 5, nil)
    assertTrue(preview ~= nil, "an unattributed positive adjustment previews")
    assertEq(preview.currentItem, 20, "preview shows the current item total")
    assertEq(preview.nextItem, 25, "preview shows the resulting item total")
    assertEq(preview.attributed, nil, "unattributed preview has no player credit")
    assertTrue(contains(C.ManualAdjustmentConfirmation(preview, "Aqirite"), "25"),
        "confirmation text includes the resulting quantity")
    assertTrue(contains(C.ManualAdjustmentConfirmation(preview, "Aqirite"), "Unattributed"),
        "confirmation text marks unattributed credit")

    assertTrue(select(1, C.RecordManualAdjustment(p, admin, aqirite, 5, nil)),
        "an admin can apply an unattributed positive adjustment")
    assertEq(C.ItemDonatedTotal(p, aqirite), 25, "unattributed positive adjustments increase the item total")
    assertEq(C.ContributionTotal(p, donor, aqirite), 20, "unattributed adjustments do not change player totals")
    assertEq(C.ContributionTotal(p, admin, aqirite), 0, "unattributed adjustments do not credit the admin")

    assertTrue(select(1, C.RecordManualAdjustment(p, admin, aqirite, -3, nil)),
        "an admin can apply an unattributed negative adjustment")
    assertEq(C.ItemDonatedTotal(p, aqirite), 22, "unattributed negative adjustments decrease the item total")
    assertEq(C.ContributionTotal(p, donor, aqirite), 20, "unattributed negatives still leave player totals alone")

    assertTrue(select(1, C.RecordManualAdjustment(p, admin, aqirite, 4, donor)),
        "an admin can credit a positive adjustment to a player")
    assertEq(C.ItemDonatedTotal(p, aqirite), 26, "attributed positives increase the item total")
    assertEq(C.ContributionTotal(p, donor, aqirite), 24, "attributed positives increase the player total")

    assertTrue(select(1, C.RecordManualAdjustment(p, admin, aqirite, -6, donor)),
        "an admin can attribute a negative adjustment to a player")
    assertEq(C.ItemDonatedTotal(p, aqirite), 20, "attributed negatives decrease the item total")
    assertEq(C.ContributionTotal(p, donor, aqirite), 18, "attributed negatives decrease the player total")
    assertFalse(select(1, C.RecordManualAdjustment(p, admin, aqirite, -19, donor)),
        "attributed negatives stop at the player's contribution floor")

    local progress = C.GoalProgress(p)
    local found
    for i = 1, #(progress.items or {}) do
        if progress.items[i].itemId == aqirite then found = progress.items[i] end
    end
    assertTrue(found ~= nil, "goal progress includes the adjusted item")
    assertEq(found.donated, 20, "goal progress uses the adjusted item total")

    local rows, total = C.HistoryRows(p, function() return "Aqirite" end)
    assertTrue(total >= 5, "history includes donation and adjustment rows")
    assertEq(total, 5, "history counts the seed donation and four adjustments")
    local sawUnattributed, sawCredited = false, false
    for i = 1, #rows do
        if contains(rows[i].text, "unattributed / miscellaneous") then sawUnattributed = true end
        if contains(rows[i].text, "credited to Donor-Realm") then sawCredited = true end
        if contains(rows[i].text, "adjusted") then
            assertTrue(contains(rows[i].text, "Admin-Realm"), "adjustment history names the admin")
        end
    end
    assertTrue(sawUnattributed, "history distinguishes unattributed adjustments")
    assertTrue(sawCredited, "history distinguishes attributed adjustments")
    assertEq(C.FormatEvent({
        type = C.EVENT.DONATION, actor = donor, itemId = aqirite, quantity = 1, source = "guildbank",
    }, "Aqirite"), "Donor-Realm donated 1 Aqirite to the guild bank.",
        "donation formatting remains unchanged")

    -- Stale attribution target after roster removal.
    assertFalse(select(1, C.RecordManualAdjustment(p, admin, aqirite, 1, "Gone-Realm")),
        "attribution to a non-member is rejected at commit time")
    local staleMember = "Leaving-Realm"
    p._memberIds[#p._memberIds + 1] = staleMember
    assertTrue(select(1, C.PreviewManualAdjustment(p, aqirite, 1, staleMember)),
        "a current member can be selected for attribution")
    p._memberIds[#p._memberIds] = nil
    assertFalse(select(1, C.RecordManualAdjustment(p, admin, aqirite, 1, staleMember)),
        "member removal between selection and confirmation rejects the adjustment")

    -- Author-bound IDs, idempotent remote delivery, and coordinator relay.
    local token, events = C.ManualAdjustmentEvents(p, admin, aqirite, 2, vann)
    assertTrue(events ~= nil and token ~= nil, "manual adjustment events can be built")
    assertTrue(contains(token, admin), "adjustment tokens embed the admin author")
    local builtId = string.format("ce:%s:%s:1", p._profileId, token)
    assertTrue(S.RemoteEventIdOk(builtId, admin), "built adjustment IDs satisfy RemoteEventIdOk")
    assertEq(events[1].type, C.EVENT.ADJUSTMENT, "built events use the adjustment type")
    assertEq(events[1].source, nil, "adjustments are not guildbank-sourced")
    assertTrue(select(1, C.CommitEvents(p, token, events, { writer = admin })),
        "a prepared adjustment commits")
    local storedAdj = p._consumableEvents[#p._consumableEvents]
    assertTrue(S.RemoteEventIdOk(storedAdj.id, admin), "committed adjustment IDs bind the admin author")
    assertEq(C.ContributionTotal(p, vann, aqirite), 2, "attributed remote-style commit credits the player")
    local okDup, statusDup = C.CommitEvents(p, token, events, { writer = admin })
    assertTrue(okDup and statusDup == nil, "replaying the same adjustment commit succeeds")
    assertEq(C.ContributionTotal(p, vann, aqirite), 2, "replaying the same adjustment does not double-apply")
    assertEq(C.ItemDonatedTotal(p, aqirite), 22, "item total stays stable across the replay")

    local remote = {
        id = "ce:remote-adj:Admin-Realm:99",
        type = C.EVENT.ADJUSTMENT,
        actor = admin,
        writer = admin,
        itemId = aqirite,
        quantity = -1,
        attributed = vann,
        generation = 1,
    }
    assertTrue(select(1, S.ApplyRemoteEvent(p, remote, admin)),
        "an admin remote adjustment is accepted")
    assertEq(C.ContributionTotal(p, vann, aqirite), 1, "remote attributed adjustments update player totals")
    local okReplay, replayStatus = S.ApplyRemoteEvent(p, remote, admin)
    assertTrue(okReplay and replayStatus == "duplicate", "remote adjustment delivery is idempotent")
    assertEq(C.ContributionTotal(p, vann, aqirite), 1, "duplicate remote adjustments do not reapply")
    assertFalse(select(1, S.ApplyRemoteEvent(p, {
        id = "ce:remote-adj:Donor-Realm:100",
        type = C.EVENT.ADJUSTMENT,
        actor = donor,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
    }, donor)), "a non-admin remote adjustment is rejected")
    assertFalse(select(1, S.ApplyRemoteEvent(p, {
        id = "ce:remote-adj:Admin-Realm:101",
        type = C.EVENT.ADJUSTMENT,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
    }, admin)), "guildbank-sourced adjustments are rejected on the wire")

    local relay = {
        id = "ce:remote-adj:Admin-Realm:102",
        type = C.EVENT.ADJUSTMENT,
        actor = admin,
        writer = admin,
        itemId = aqirite,
        quantity = 3,
        generation = 1,
        order = 50,
    }
    assertTrue(select(1, S.ApplyRemoteEvent(p, relay, admin, { coordinatorRelay = true })),
        "coordinator relay accepts admin adjustments")
    assertEq(C.ItemDonatedTotal(p, aqirite), 24, "relayed unattributed adjustments update item totals")

    -- Historical attribution survives later roster removal.
    p._memberIds = { admin }
    assertEq(C.ContributionTotal(p, vann, aqirite), 1, "historical attributed totals remain after member removal")
    assertFalse(select(1, S.ApplyRemoteEvent(p, {
        id = "ce:remote-adj:Admin-Realm:103",
        type = C.EVENT.ADJUSTMENT,
        actor = admin,
        writer = admin,
        itemId = aqirite,
        quantity = 1,
        attributed = vann,
        generation = 1,
    }, admin)), "direct admission rejects attribution to a departed member")
    assertTrue(select(1, S.ApplyRemoteEvent(p, {
        id = "ce:remote-adj:Admin-Realm:104",
        type = C.EVENT.ADJUSTMENT,
        actor = admin,
        writer = admin,
        itemId = aqirite,
        quantity = 1,
        attributed = vann,
        generation = 1,
        order = 51,
    }, admin, { coordinatorRelay = true })),
        "coordinator relay still delivers historical attribution after member leave")
    assertEq(C.ContributionTotal(p, vann, aqirite), 2, "relayed historical attribution still credits the departed member")

    -- Outside-session persistence queues for eventual sync.
    resetSync()
    local outside = configured("manual-adjust-outside")
    C.CommitEvents(outside, "seed-outside",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 10))
    Sync.state = { active = false }
    Sync._SelfId = function() return admin end
    Sync.MSG = { CONSUMABLES_EVENT = "CE" }
    assertTrue(select(1, Sync:CommitConsumablesManualAdjustment(outside, aqirite, 7, nil, { asAdmin = true })),
        "manual adjustments work outside an active session")
    assertEq(C.ItemDonatedTotal(outside, aqirite), 17, "outside-session adjustments persist locally")
    assertTrue(#(outside._consumablesUnsent or {}) >= 1, "outside-session adjustments join the unsent queue")
    local queuedId = outside._consumablesUnsent[1]
    assertTrue(S.RemoteEventIdOk(queuedId, admin), "queued outside-session IDs remain author-bound")
    assertFalse(select(1, Sync:CommitConsumablesManualAdjustment(outside, aqirite, 1, nil, { asAdmin = false })),
        "Preview as Non-Admin blocks the sync adjustment path")

    -- Competing offline negatives: coordinator floor rejection + originator retract.
    local helperAdmin = "HelperAdmin-Realm"
    local coord = configured("floor-coord")
    coord._adminUsers = { admin, helperAdmin }
    C.CommitEvents(coord, "seed-floor-coord",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 10))
    local peer = configured("floor-peer")
    peer._adminUsers = { admin, helperAdmin }
    C.CommitEvents(peer, "seed-floor-peer",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 10))
    assertTrue(select(1, C.RecordManualAdjustment(coord, admin, aqirite, -10, nil)),
        "first offline negative adjustment applies locally on the coordinator")
    assertTrue(select(1, C.RecordManualAdjustment(peer, helperAdmin, aqirite, -10, nil)),
        "second offline negative adjustment applies locally on the peer")
    assertEq(C.ItemDonatedTotal(coord, aqirite), 0, "coordinator local total reaches zero")
    assertEq(C.ItemDonatedTotal(peer, aqirite), 0, "peer local total reaches zero before sync")
    local peerEvent = peer._consumableEvents[#peer._consumableEvents]
    peer._consumablesUnsent = { peerEvent.id }
    local floorOk, floorStatus = S.ApplyRemoteEvent(coord, {
        id = peerEvent.id,
        type = C.EVENT.ADJUSTMENT,
        actor = helperAdmin,
        writer = helperAdmin,
        itemId = aqirite,
        quantity = -10,
        generation = 1,
    }, helperAdmin)
    assertFalse(floorOk, "coordinator rejects a competing negative adjustment")
    assertEq(floorStatus, "floor", "competing negatives report a floor status")
    assertEq(C.ItemDonatedTotal(coord, aqirite), 0, "rejected competing adjustment does not change the coordinator")
    assertTrue(C.RetractEvent(peer, peerEvent.id), "originator retracts the floor-rejected adjustment")
    assertEq(C.ItemDonatedTotal(peer, aqirite), 10, "retract restores the peer's pre-adjustment total")
    assertEq(#(peer._consumablesUnsent or {}), 0, "retract clears endless unsent retries")
    assertFalse(C.RetractEvent(peer, peerEvent.id), "retract is idempotent once the event is gone")

    -- Session path: floor reject whisper from coordinator retracts peer state.
    resetSync()
    local sent = {}
    local sessionCoord = configured("floor-session-coord")
    sessionCoord._adminUsers = { admin, helperAdmin }
    C.CommitEvents(sessionCoord, "seed-session-coord",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 5))
    assertTrue(select(1, C.RecordManualAdjustment(sessionCoord, admin, aqirite, -5, nil)),
        "session coordinator consumes the remaining balance")
    local sessionPeer = configured("floor-session-peer")
    sessionPeer._adminUsers = { admin, helperAdmin }
    C.CommitEvents(sessionPeer, "seed-session-peer",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 5))
    assertTrue(select(1, C.RecordManualAdjustment(sessionPeer, helperAdmin, aqirite, -5, nil)),
        "session peer also applies a competing offline negative")
    local competing = sessionPeer._consumableEvents[#sessionPeer._consumableEvents]
    sessionPeer._consumablesUnsent = { competing.id }
    local profiles = {
        [sessionCoord._profileId] = sessionCoord,
        [sessionPeer._profileId] = sessionPeer,
    }
    sessionStubs({
        active = true,
        isCoordinator = true,
        coordinator = admin,
        sessionId = "floor-session",
        profileId = sessionCoord._profileId,
    }, profiles, sent)
    Sync:HandleConsumablesEvent(helperAdmin, {
        sessionId = "floor-session",
        profileId = sessionCoord._profileId,
        event = {
            id = competing.id,
            type = C.EVENT.ADJUSTMENT,
            actor = helperAdmin,
            writer = helperAdmin,
            itemId = aqirite,
            quantity = -5,
            generation = 1,
        },
    })
    local sawReject = false
    for i = 1, #sent do
        local payload = sent[i].payload
        if type(payload) == "table" and type(payload.event) == "table"
            and payload.event.reject == "floor" and payload.event.id == competing.id then
            sawReject = true
            assertEq(sent[i].target, helperAdmin, "floor rejection whispers the author")
        end
    end
    assertTrue(sawReject, "coordinator whispers a floor rejection for competing negatives")
    sessionStubs({
        active = true,
        isCoordinator = false,
        coordinator = admin,
        sessionId = "floor-session",
        profileId = sessionPeer._profileId,
    }, profiles, {})
    Sync:HandleConsumablesEvent(admin, {
        sessionId = "floor-session",
        profileId = sessionPeer._profileId,
        event = { id = competing.id, type = C.EVENT.ADJUSTMENT, reject = "floor", generation = 1 },
    })
    assertEq(C.ItemDonatedTotal(sessionPeer, aqirite), 5, "peer converges after floor-reject retract")
    assertEq(#(sessionPeer._consumablesUnsent or {}), 0, "peer stops retrying after floor-reject retract")

    -- Delayed duplicate of an already-accepted adjustment remains idempotent.
    assertTrue(select(1, S.ApplyRemoteEvent(sessionCoord, {
        id = "ce:delay:Admin-Realm:1",
        type = C.EVENT.ADJUSTMENT,
        actor = admin,
        itemId = aqirite,
        quantity = 2,
        generation = 1,
    }, admin)), "a delayed positive adjustment is accepted once")
    local okDelay, delayStatus = S.ApplyRemoteEvent(sessionCoord, {
        id = "ce:delay:Admin-Realm:1",
        type = C.EVENT.ADJUSTMENT,
        actor = admin,
        itemId = aqirite,
        quantity = 2,
        generation = 1,
    }, admin)
    assertTrue(okDelay and delayStatus == "duplicate", "delayed duplicate delivery is idempotent")

    -- Lost confirmation: accepted negative retransmission must be duplicate, not floor.
    -- Coordinator accepts -10 against 10 (balance 0). Stamped relay is lost, so the
    -- follower still has the unordered event + unsent ID and retransmits. Floor
    -- checks against the post-admit balance must not reject the known ID.
    resetSync()
    local lostSent = {}
    local lostCoord = configured("lost-relay-coord")
    lostCoord._adminUsers = { admin, helperAdmin }
    C.CommitEvents(lostCoord, "seed-lost-coord",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 10))
    local lostPeer = configured("lost-relay-peer")
    lostPeer._adminUsers = { admin, helperAdmin }
    C.CommitEvents(lostPeer, "seed-lost-peer",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 10))
    assertTrue(select(1, C.RecordManualAdjustment(lostPeer, helperAdmin, aqirite, -10, nil)),
        "follower applies a legitimate negative that consumes the remaining balance")
    local lostEvent = lostPeer._consumableEvents[#lostPeer._consumableEvents]
    assertTrue(type(lostEvent) == "table" and type(lostEvent.id) == "string",
        "follower retains the adjustment event for retransmission")
    lostPeer._consumablesUnsent = { lostEvent.id }
    local lostProfiles = {
        [lostCoord._profileId] = lostCoord,
        [lostPeer._profileId] = lostPeer,
    }
    sessionStubs({
        active = true,
        isCoordinator = true,
        coordinator = admin,
        sessionId = "lost-relay-session",
        profileId = lostCoord._profileId,
    }, lostProfiles, lostSent)
    local firstPayload = {
        id = lostEvent.id,
        type = C.EVENT.ADJUSTMENT,
        actor = helperAdmin,
        writer = helperAdmin,
        itemId = aqirite,
        quantity = -10,
        generation = 1,
    }
    Sync:HandleConsumablesEvent(helperAdmin, {
        sessionId = "lost-relay-session",
        profileId = lostCoord._profileId,
        event = firstPayload,
    })
    assertEq(C.ItemDonatedTotal(lostCoord, aqirite), 0, "coordinator accepts the first negative transmission")
    local stamped = C.EventIndex(lostCoord)[lostEvent.id]
    assertTrue(type(stamped) == "table" and C.ValidOrder(stamped.order) ~= nil,
        "coordinator stamps the accepted negative adjustment")
    local firstReject = false
    local firstBroadcast = false
    for i = 1, #lostSent do
        local payload = lostSent[i].payload
        if type(payload) == "table" and type(payload.event) == "table" then
            if payload.event.reject and payload.event.id == lostEvent.id then
                firstReject = true
            end
            if payload.event.id == lostEvent.id and not payload.event.reject then
                firstBroadcast = true
            end
        end
    end
    assertFalse(firstReject, "first legitimate negative is not floor-rejected")
    assertTrue(firstBroadcast, "coordinator broadcasts the stamped adjustment")
    -- Lost confirmation: discard the broadcast and leave the follower unsent.
    assertEq(#(lostPeer._consumablesUnsent or {}), 1, "follower still queues the unconfirmed event")
    assertEq(C.ValidOrder(lostEvent.order), nil, "follower still lacks a stamped order after the lost relay")
    lostSent = {}
    sessionStubs({
        active = true,
        isCoordinator = true,
        coordinator = admin,
        sessionId = "lost-relay-session",
        profileId = lostCoord._profileId,
    }, lostProfiles, lostSent)
    Sync:HandleConsumablesEvent(helperAdmin, {
        sessionId = "lost-relay-session",
        profileId = lostCoord._profileId,
        event = {
            id = lostEvent.id,
            type = C.EVENT.ADJUSTMENT,
            actor = helperAdmin,
            writer = helperAdmin,
            itemId = aqirite,
            quantity = -10,
            generation = 1,
        },
    })
    assertEq(C.ItemDonatedTotal(lostCoord, aqirite), 0,
        "retransmission of an accepted negative does not change the coordinator total")
    local sawFloorReject = false
    local sawStampedRebroadcast = false
    for i = 1, #lostSent do
        local payload = lostSent[i].payload
        if type(payload) == "table" and type(payload.event) == "table"
            and payload.event.id == lostEvent.id then
            if payload.event.reject == "floor" or payload.event.reject == "member" then
                sawFloorReject = true
            elseif C.ValidOrder(payload.event.order) ~= nil then
                sawStampedRebroadcast = true
            end
        end
    end
    assertFalse(sawFloorReject,
        "retransmission of an already-accepted negative is not floor/member rejected")
    assertTrue(sawStampedRebroadcast,
        "coordinator rebroadcasts the stamped duplicate after a lost confirmation")
    local okRetransmit, retransmitStatus = S.ApplyRemoteEvent(lostCoord, {
        id = lostEvent.id,
        type = C.EVENT.ADJUSTMENT,
        actor = helperAdmin,
        writer = helperAdmin,
        itemId = aqirite,
        quantity = -10,
        generation = 1,
    }, helperAdmin)
    assertTrue(okRetransmit and retransmitStatus == "duplicate",
        "ApplyRemoteEvent classifies the lost-confirmation retransmission as duplicate")
    assertEq(C.ItemDonatedTotal(lostPeer, aqirite), 0, "follower keeps its legitimate negative credit")
    assertTrue(type(C.EventIndex(lostPeer)[lostEvent.id]) == "table",
        "follower still holds the original adjustment after the duplicate path")
    assertEq(C.ValidOrder(lostEvent.order), nil,
        "lost confirmation leaves the follower unordered; duplicate path must not retract it")

    -- Generation / clear: history kept, new generation unaffected.
    assertTrue(select(1, C.Clear(p, admin)), "clear after adjustments succeeds")
    assertEq(C.ItemDonatedTotal(p, aqirite), 0, "clear restarts item totals for the new generation")
    local hist = C.HistoryRows(p, function() return "Aqirite" end)
    local sawAdj = false
    for i = 1, #hist do
        if contains(hist[i].text, "adjusted") then sawAdj = true end
    end
    assertTrue(sawAdj, "adjustment history remains after configuration clear")
    assertTrue(select(1, C.SetGuild(p, admin, GUILD, 2)), "guild can be reconfigured after clear")
    assertTrue(select(1, C.AddRequestedItem(p, admin, aqirite)), "items can be re-requested after clear")
    assertTrue(select(1, C.RecordManualAdjustment(p, admin, aqirite, 1, nil)),
        "new-generation adjustments start from zero")
    assertEq(C.ItemDonatedTotal(p, aqirite), 1, "new-generation adjustments do not inherit prior totals")

    local okTypes, badType = onlyKnownAccountingEvents(p)
    assertTrue(okTypes, "manual adjustments stay within known accounting event types (" .. tostring(badType) .. ")")
end

local function checkQueuedResendProtection()
    resetWorld()
    resetSync()
    local helperAdmin = "HelperAdmin-Realm"
    local follower = configured("queue-race")
    follower._adminUsers = { admin, helperAdmin }
    local coordinator = configured("queue-race")
    coordinator._adminUsers = { admin, helperAdmin }
    -- Admin-trusted donation for another donor; queue protection still applies.
    local event = donation("ce:queue-race:HelperAdmin-Realm:1", donor, 7, { order = 17, writer = helperAdmin })
    assertTrue(C.AppendEvent(follower, event), "the follower retains an authored ordered event")
    local sent = {}
    local followerState = { active = true, isCoordinator = false, coordinator = admin, sessionId = "queue-session",
        profileId = follower._profileId, peers = { [admin] = { consumablesCapable = true } } }
    sessionStubs(followerState, { [follower._profileId] = follower }, sent)
    Sync._SelfId = function() return helperAdmin end
    Sync.MSG.NEED_PROFILE = "NP"
    Sync._GetAddonVersion = function() return "test" end
    -- Real Comm.Send and its paced queue; only wire encoding and delivery are mocked.
    load("SpectrumFederation/modules/LootHelper/Comm.lua")
    local comm = SF.LootHelperComm
    comm._ready = true
    comm.cfg.perTargetMinIntervalSec = 0
    local wire = {}
    local function wireCopy(value)
        if type(value) ~= "table" then return value end
        local copy = {}
        for key, child in pairs(value) do copy[key] = wireCopy(child) end
        return copy
    end
    local sequence = 0
    local oldProtocol = SF.SyncProtocol
    SF.SyncProtocol = {
        PROTO_CURRENT = 4, ENC_B64CBOR = "B", ENC_NONE = "N",
        EncodePayloadTable = function(payload)
            sequence = sequence + 1
            wire[tostring(sequence)] = wireCopy(payload)
            return tostring(sequence)
        end,
        PackEnvelope = function(msg, _, _, encoded) return msg .. ":" .. encoded end,
    }
    local bulk = {}
    local snapshots = 0
    comm.SendCommMessage = function(_, prefix, message)
        local msg, encoded = message:match("^(%w+):(%d+)$")
        local payload = wire[encoded]
        if prefix == comm.PREFIX.BULK then
            bulk[#bulk + 1] = payload
        elseif msg == "NP" then
            snapshots = snapshots + 1
            C.MergeSnapshot(follower, C.ExportSnapshot(coordinator), { consumablesFromCoordinator = true })
        end
    end
    Sync.RequestProfileSnapshot = function()
        return Sync:_SendNeedProfileReq({ id = "queue-request" }, admin)
    end
    local desc = C.Descriptor(coordinator)
    local hb = { profileId = follower._profileId, sessionId = "queue-session", coordinator = admin,
        consumablesGeneration = desc.generation, consumablesConfigSeq = desc.configSeq,
        consumablesConfigFingerprint = desc.configFingerprint, consumablesEventCount = desc.eventCount,
        consumablesEventFingerprint = desc.eventFingerprint, consumablesArchiveCount = desc.archiveCount,
        consumablesArchiveFingerprint = desc.archiveFingerprint }
    -- Initial live sends need the same protection as catch-up resends.
    assertTrue(Sync:BroadcastConsumablesEvent(follower, event), "a follower's initial BULK send is accepted")
    assertEq(#follower._consumablesUnsent, 1, "initial send retains pending protection")
    Sync:_QueueAuthoredOrderedConsumablesEvents(follower, desc.eventCount, true)
    assertEq(#follower._consumablesUnsent, 1, "authored ordered event is queued for resend")
    Sync:_ConsiderConsumablesCatchUp(hb)
    assertEq(#bulk, 0, "BULK acceptance has not transmitted the event")
    assertTrue(comm.state.total > 0, "the actual paced Comm queue holds the resend")
    assertEq(snapshots, 1, "CONTROL NEED_PROFILE overtakes the queued BULK resend")
    assertEq(C.ContributionTotal(follower, donor, aqirite), 7, "the early authoritative snapshot preserves the follower's only copy")
    assertEq(#follower._consumablesUnsent, 1, "queue acceptance retains durable pending protection")
    for _ = 1, 10 do Sync:_ConsiderConsumablesCatchUp(hb) end
    assertEq(#follower._consumablesUnsent, 1, "repeated catch-up retains one pending ID")
    for _ = 1, 60 do comm:_PumpQueue() end
    assertTrue(#bulk > 0, "pumping the actual queue transmits the pending event")
    local relay = {}
    sessionStubs({ active = true, isCoordinator = true, coordinator = admin, sessionId = "queue-session",
        profileId = coordinator._profileId, peers = {} }, { [coordinator._profileId] = coordinator }, relay)
    Sync._SelfId = function() return admin end
    for i = 1, #bulk do Sync:HandleConsumablesEvent(helperAdmin, bulk[i]) end
    assertEq(#coordinator._consumableEvents, 1, "repeated resends are idempotent at the coordinator")
    assertEq(C.ContributionTotal(coordinator, donor, aqirite), 7, "the coordinator credits the donation once")
    sessionStubs(followerState, { [follower._profileId] = follower }, {})
    Sync._SelfId = function() return helperAdmin end
    local bogus = donation(event.id, donor, 7, { order = 1, writer = helperAdmin, source = "trade" })
    Sync:HandleConsumablesEvent(admin, { sessionId = "queue-session", profileId = follower._profileId, event = bogus })
    assertEq(#follower._consumablesUnsent, 1, "a rejected stamped relay cannot acknowledge the pending event")
    for i = 1, #relay do Sync:HandleConsumablesEvent(admin, relay[i].payload) end
    assertEq(#follower._consumablesUnsent, 0, "accepted coordinator-stamped echo clears pending protection")
    assertEq(#follower._consumableEvents, 1, "repeated stamped echoes remain idempotent")
    Sync:_QueueUnsentConsumablesEvent(follower, event.id)
    C.MergeSnapshot(follower, C.ExportSnapshot(coordinator), { consumablesFromCoordinator = true })
    assertEq(#follower._consumablesUnsent, 0, "authoritative snapshot acceptance also clears pending protection")
    -- More than one flush batch must progress rather than resend only its head.
    local rotated = {}
    SF.LootHelperComm.Send = function(_, _, _, payload)
        rotated[payload.event.id] = true
        return true
    end
    for i = 2, 18 do
        local row = donation("ce:queue-race:HelperAdmin-Realm:" .. tostring(i), donor, 1)
        assert(C.AppendEvent(follower, row))
        Sync:_QueueUnsentConsumablesEvent(follower, row.id)
    end
    for _ = 1, 3 do Sync:_FlushUnsentConsumablesEvents(follower) end
    local count = 0
    for _ in pairs(rotated) do count = count + 1 end
    assertEq(count, 17, "bounded flush rotation reaches IDs beyond the first batch")
    assertEq(#follower._consumablesUnsent, 17, "rotation preserves exactly one pending ID per event")
    SF.SyncProtocol = oldProtocol
    resetSync()
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
    -- Non-admins cannot insert canonical donations; admins submit verified provenance.
    member(donation("ce:session:Donor-Realm:1", donor, 6), donor)
    assertEq(#coordP._consumableEvents, 0, "the coordinator rejects a non-admin canonical donation")
    member(donation("ce:session:Admin-Realm:1", donor, 6), admin)
    assertEq(#coordP._consumableEvents, 1, "the coordinator stores an admin-trusted donation for another donor")
    assertEq(coordP._consumableEvents[1].order, 1, "the coordinator stamps the donation order")
    assertEq(coordP._consumableEvents[1].actor, donor, "the stamped donation preserves the actual donor")
    assertEq(countMsg(sent, "CE"), 1, "the coordinator relays the stamped donation once")
    member(donation("ce:session:Donor-Realm:2", vann, 6), donor)
    member(donation("ce:session:Donor-Realm:3", donor, 6, { source = "trade" }), donor)
    member({ id = "ce:session:Donor-Realm:4", type = C.EVENT.CUSTODY, actor = donor, itemId = aqirite, quantity = 1, generation = 1 }, donor)
    member(donation("ce:session:Donor-Realm:5", donor, 6), "Stranger-Realm")
    assertEq(#coordP._consumableEvents, 1, "forged, trade, custody, and spoofed events are not stored by the coordinator")
    assertEq(countMsg(sent, "CE"), 1, "rejected events are not relayed")
    Sync:HandleConsumablesEvent(donor, { sessionId = "other", profileId = coordP._profileId,
        event = donation("ce:session:Admin-Realm:6", donor, 6) })
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

    -- New coordinator with empty history holds until a joining peer supplies richer watermarks.
    local lateCoord = profile("late-coord", admin)
    lateCoord._profileId = coordP._profileId
    lateCoord._adminUsers = { admin, vann }
    C.SetGuild(lateCoord, admin, GUILD, 2)
    C.AddRequestedItem(lateCoord, admin, aqirite)
    sessionStubs({ active = true, isCoordinator = true, coordinator = admin, sessionId = "s1",
        profileId = lateCoord._profileId, peers = { [vann] = { inGroup = true } } },
        { [lateCoord._profileId] = lateCoord }, {})
    Sync._SelfId = function() return admin end
    local peerRecoveryReqs = {}
    local previousRequestProfileSnapshot = Sync.RequestProfileSnapshot
    Sync.RequestProfileSnapshot = function(_, reason, opts)
        peerRecoveryReqs[#peerRecoveryReqs + 1] = { reason = reason, opts = opts }
        return true
    end
    local peerDesc = C.Descriptor(coordP)
    Sync:_NotePeerConsumablesHistory(vann, {
        profileId = lateCoord._profileId,
        sessionId = "s1",
        consumablesGeneration = peerDesc.generation,
        consumablesConfigSeq = peerDesc.configSeq,
        consumablesRejectionSeq = peerDesc.rejectionSeq,
        consumablesTxnAllocSeq = peerDesc.txnAllocSeq,
        consumablesConfigFingerprint = peerDesc.configFingerprint,
        consumablesEventCount = peerDesc.eventCount,
        consumablesEventFingerprint = peerDesc.eventFingerprint,
        consumablesArchiveCount = peerDesc.archiveCount,
        consumablesArchiveFingerprint = peerDesc.archiveFingerprint,
    })
    assertTrue(lateCoord._consumablesPeerHistoryAhead == true,
        "a new coordinator marks peer-ahead history from HAVE_PROFILE watermarks")
    assertFalse(Sync:_ConsumablesHistoryReady(lateCoord),
        "peer-ahead history gates verification until local ledger catches up")
    assertEq(#peerRecoveryReqs, 1, "peer-ahead history requests recovery from the authorized peer")
    assertEq(peerRecoveryReqs[1].reason, "consumables-peer-history",
        "recovery request uses the consumables-peer-history reason")
    assertEq(peerRecoveryReqs[1].opts and peerRecoveryReqs[1].opts.preferredTarget, vann,
        "recovery prefers the ahead authorized peer (not only the original writer)")
    assertTrue(peerRecoveryReqs[1].opts and peerRecoveryReqs[1].opts.acceptAuthorizedAdmins == true,
        "recovery accepts an authorized admin snapshot")
    assertTrue(peerRecoveryReqs[1].opts and peerRecoveryReqs[1].opts.consumablesHistoryOnly == true,
        "recovery absorbs consumables history only from that admin")
    -- Peer is not the original writer; stamped RelayWriter events still recover.
    local peerSnap = C.ExportSnapshot(coordP)
    assertTrue(select(1, C.MergeSnapshot(lateCoord, peerSnap, { consumablesFromCoordinator = false })),
        "new coordinator absorbs stamped history from a non-writer authorized peer")
    Sync:_RefreshConsumablesHistoryGate(lateCoord)
    assertTrue(Sync:_ConsumablesHistoryReady(lateCoord),
        "history gate clears after the missing ledger/registry is absorbed")
    assertEq(C.ContributionTotal(lateCoord, donor, aqirite), 6,
        "recovered Tuesday donation credits once on the new coordinator")
    -- Untrusted stranger advertisements do not open recovery.
    local strangerReqs = #peerRecoveryReqs
    Sync:_NotePeerConsumablesHistory("Stranger-Realm", {
        profileId = lateCoord._profileId,
        sessionId = "s1",
        consumablesGeneration = peerDesc.generation,
        consumablesConfigSeq = peerDesc.configSeq,
        consumablesTxnAllocSeq = (peerDesc.txnAllocSeq or 0) + 5,
        consumablesEventCount = (peerDesc.eventCount or 0) + 5,
        consumablesEventFingerprint = 424242,
    })
    assertEq(#peerRecoveryReqs, strangerReqs,
        "unauthorized peers cannot trigger consumables history recovery")
    Sync.RequestProfileSnapshot = previousRequestProfileSnapshot

    -- Pre-advertisement baseline: newly elected coordinator is not history-ready
    -- until grace elapses or peer-ahead catch-up completes.
    local baselineCoord = profile("baseline-coord", admin)
    baselineCoord._profileId = "baseline-profile"
    baselineCoord._adminUsers = { admin, vann }
    C.SetGuild(baselineCoord, admin, GUILD, 2)
    sessionStubs({ active = true, isCoordinator = true, coordinator = admin, sessionId = "s-base",
        profileId = baselineCoord._profileId, peers = {} },
        { [baselineCoord._profileId] = baselineCoord }, {})
    Sync._SelfId = function() return admin end
    local nowBase = clock
    Sync._Now = function() return nowBase end
    Sync:_OnBecameConsumablesCoordinator(false, "test-baseline")
    assertEq(tonumber(baselineCoord._consumablesHistoryUnconfirmedAt), nowBase,
        "promotion marks consumables history unconfirmed")
    assertFalse(Sync:_ConsumablesHistoryReady(baselineCoord),
        "pre-advertisement window holds history-ready false")
    -- Advance past grace with no peer-ahead watermark.
    local grace = Sync.CONSUMABLES_HISTORY_BASELINE_GRACE_SEC or 90
    Sync._Now = function() return nowBase + grace + 1 end
    assertTrue(Sync:_ConsumablesHistoryReady(baselineCoord),
        "history-ready after baseline grace with no peer ahead")
    assertTrue(baselineCoord._consumablesHistoryUnconfirmedAt == nil,
        "baseline unconfirmed flag clears after grace")
    assertTrue(tonumber(baselineCoord._consumablesHistoryBaselineAt) == nowBase,
        "baseline timestamp retained after grace for clearly-new checks")
    Sync._Now = nil

    -- Held pending clusters reevaluate when peer catch-up clears the history gate.
    do
        local V = SF.ConsumablesVerification
        local O = SF.ConsumablesObservation
        assertTrue(type(V) == "table" and type(O) == "table",
            "verification/observation modules available for reeval lifecycle")
        V.ClearSessionClusters()
        local richPeer = profile("reeval-lifecycle-rich", admin)
        richPeer._profileId = "reeval-lifecycle-rich"
        richPeer._adminUsers = { admin, vann }
        C.SetGuild(richPeer, admin, GUILD, 2)
        C.AddRequestedItem(richPeer, admin, aqirite)
        local dbRich = {}
        local storeRich = O.EnsureProfileStore(dbRich, richPeer._profileId)
        local scopeRich = O.EnsureScope(storeRich, GUILD.guid, 2)
        local tuesday = {
            localId = "co:reeval-life:1",
            type = "deposit",
            donor = donor,
            itemId = aqirite,
            quantity = 9,
            guildGuid = GUILD.guid,
            bankTab = 2,
            generation = 1,
            approxTxnTime = clock - 300,
            ageHours = 0,
            occurrenceIndex = 1,
            neighborsOlder = { "deposit|Other-Realm|1|1" },
            neighborsNewer = {},
            observedBy = admin,
            firstSeen = clock - 300,
            status = "pending",
            coreSignature = O.CoreSignature("deposit", donor, aqirite, 9),
        }
        assertEq(V.IngestReport(richPeer, richPeer._profileId, admin, { tuesday }, {
            isAdmin = true, scope = scopeRich, obsStore = storeRich, historyComplete = true,
        }).verified, 1, "reeval-lifecycle rich peer verifies Tuesday")
        assertTrue(V.CommitVerifiedCluster(richPeer, V.ListVerifiedClusters(richPeer._profileId)[1], admin))
        local txnRich = V.ListVerifiedClusters(richPeer._profileId)[1].txnId
        local richSnap = C.ExportSnapshot(richPeer)

        V.ClearSessionClusters()
        local lateHold = profile("reeval-lifecycle-late", admin)
        lateHold._profileId = "reeval-lifecycle-late"
        lateHold._adminUsers = { admin, vann }
        C.SetGuild(lateHold, admin, GUILD, 2)
        C.AddRequestedItem(lateHold, admin, aqirite)
        sessionStubs({ active = true, isCoordinator = true, coordinator = admin, sessionId = "s-reeval",
            profileId = lateHold._profileId, peers = {} },
            { [lateHold._profileId] = lateHold }, {})
        Sync._SelfId = function() return admin end
        Sync._Now = function() return clock end
        Sync:_MarkConsumablesHistoryBaseline(lateHold, "reeval-lifecycle")
        lateHold._consumablesPeerHistoryAhead = true
        lateHold._consumablesCatchUpRemote = C.Descriptor(richPeer)
        SF.lootHelperDB = {}
        local storeLate = O.EnsureProfileStore(SF.lootHelperDB, lateHold._profileId)
        local scopeLate = O.EnsureScope(storeLate, GUILD.guid, 2)
        local held = V.IngestReport(lateHold, lateHold._profileId, admin, { tuesday }, {
            isAdmin = true, scope = scopeLate, obsStore = storeLate, historyComplete = false,
            historyBaselineAt = lateHold._consumablesHistoryBaselineAt,
        })
        assertEq(held.pending, 1, "reeval-lifecycle holds pending during peer-ahead")
        assertEq(C.ContributionTotal(lateHold, donor, aqirite), 0, "reeval-lifecycle no premature credit")
        assertTrue(select(1, C.MergeSnapshot(lateHold, richSnap, { consumablesFromCoordinator = false })),
            "reeval-lifecycle absorbs peer history")
        Sync:_RefreshConsumablesHistoryGate(lateHold)
        assertTrue(Sync:_ConsumablesHistoryReady(lateHold),
            "reeval-lifecycle history ready after peer absorb")
        assertTrue(C.FindRegistryTxn(lateHold, txnRich) ~= nil,
            "reeval-lifecycle recovered original txnId")
        local cluster = V.EnsureClusterStore(lateHold._profileId).clusters[1]
        assertTrue(cluster and (cluster.status == "verified" or V.ValidTxnId(cluster.txnId)),
            "reeval-lifecycle pending cluster reconsidered after gate clears")
        assertEq(C.ContributionTotal(lateHold, donor, aqirite), 9,
            "reeval-lifecycle credits Tuesday once after reevaluation")
        Sync._Now = nil
    end

    -- Two peer-ahead holds clearing within five seconds both reevaluate.
    do
        local V = SF.ConsumablesVerification
        local O = SF.ConsumablesObservation
        V.ClearSessionClusters()
        local function seedRich(profileId, qty, neighbor)
            local p = profile(profileId, admin)
            p._profileId = profileId
            p._adminUsers = { admin, vann }
            C.SetGuild(p, admin, GUILD, 2)
            C.AddRequestedItem(p, admin, aqirite)
            local store = O.EnsureProfileStore({}, profileId)
            local scope = O.EnsureScope(store, GUILD.guid, 2)
            local ev = {
                localId = "co:" .. profileId .. ":1",
                type = "deposit",
                donor = donor,
                itemId = aqirite,
                quantity = qty,
                guildGuid = GUILD.guid,
                bankTab = 2,
                generation = 1,
                approxTxnTime = clock - 250,
                ageHours = 0,
                occurrenceIndex = 1,
                neighborsOlder = { neighbor },
                neighborsNewer = {},
                observedBy = admin,
                firstSeen = clock - 250,
                status = "pending",
                coreSignature = O.CoreSignature("deposit", donor, aqirite, qty),
            }
            assertEq(V.IngestReport(p, profileId, admin, { ev }, {
                isAdmin = true, scope = scope, obsStore = store, historyComplete = true,
            }).verified, 1, "cooldown-race seeds " .. profileId)
            assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters(profileId)[1], admin))
            return p, ev, V.ListVerifiedClusters(profileId)[1].txnId
        end
        local rich1, ev1, txn1 = seedRich("cooldown-race-rich1", 4, "cool-a")
        local rich2, ev2, txn2 = seedRich("cooldown-race-rich2", 5, "cool-b")
        V.ClearSessionClusters()
        local late = profile("cooldown-race-late", admin)
        late._profileId = "cooldown-race-late"
        late._adminUsers = { admin, vann }
        C.SetGuild(late, admin, GUILD, 2)
        C.AddRequestedItem(late, admin, aqirite)
        sessionStubs({ active = true, isCoordinator = true, coordinator = admin, sessionId = "s-cool",
            profileId = late._profileId, peers = {} },
            { [late._profileId] = late }, {})
        Sync._SelfId = function() return admin end
        local t0 = clock
        Sync._Now = function() return t0 end
        Sync:_MarkConsumablesHistoryBaseline(late, "cooldown-race")
        SF.lootHelperDB = {}
        local storeLate = O.EnsureProfileStore(SF.lootHelperDB, late._profileId)
        local scopeLate = O.EnsureScope(storeLate, GUILD.guid, 2)
        -- First hold + absorb.
        late._consumablesPeerHistoryAhead = true
        late._consumablesCatchUpRemote = C.Descriptor(rich1)
        assertEq(V.IngestReport(late, late._profileId, admin, { ev1 }, {
            isAdmin = true, scope = scopeLate, obsStore = storeLate, historyComplete = false,
            historyBaselineAt = late._consumablesHistoryBaselineAt,
        }).pending, 1, "cooldown-race holds first observation")
        assertTrue(select(1, C.MergeSnapshot(late, C.ExportSnapshot(rich1), {
            consumablesFromCoordinator = false,
        })), "cooldown-race absorbs first peer")
        Sync:_RefreshConsumablesHistoryGate(late)
        assertTrue(C.HasTxnId(late, txn1), "cooldown-race first txn recovered")
        assertEq(C.ContributionTotal(late, donor, aqirite), 4, "cooldown-race first credit")
        -- Second hold clears within five seconds of the first reevaluation.
        t0 = t0 + 1
        Sync._Now = function() return t0 end
        late._consumablesPeerHistoryAhead = true
        late._consumablesCatchUpRemote = C.Descriptor(rich2)
        late._consumablesHistoryUnconfirmedAt = t0
        late._consumablesHistoryBaselineAt = t0
        assertEq(V.IngestReport(late, late._profileId, admin, { ev2 }, {
            isAdmin = true, scope = scopeLate, obsStore = storeLate, historyComplete = false,
            historyBaselineAt = late._consumablesHistoryBaselineAt,
        }).pending, 1, "cooldown-race holds second observation")
        assertTrue(select(1, C.MergeSnapshot(late, C.ExportSnapshot(rich2), {
            consumablesFromCoordinator = false,
        })), "cooldown-race absorbs second peer")
        Sync:_RefreshConsumablesHistoryGate(late)
        assertTrue(C.HasTxnId(late, txn2), "cooldown-race second txn recovered despite 5s window")
        assertEq(C.ContributionTotal(late, donor, aqirite), 9,
            "cooldown-race both credits after two rapid gate clears")
        local cluster2 = nil
        local store = V.EnsureClusterStore(late._profileId)
        for i = 1, #store.clusters do
            if store.clusters[i].txnId == txn2 or (store.clusters[i].evidence
                and store.clusters[i].evidence.quantity == 5) then
                cluster2 = store.clusters[i]
            end
        end
        assertTrue(cluster2 and (cluster2.status == "verified" or V.ValidTxnId(cluster2.txnId)),
            "cooldown-race second held cluster reconsidered")
        Sync._Now = nil
    end

    -- Restore the follower session under test before Preview as Non-Admin checks.
    sessionStubs({ active = true, isCoordinator = false, coordinator = admin, sessionId = "s1",
        profileId = coordP._profileId, peers = { [admin] = { consumablesCapable = true } } },
        { [coordP._profileId] = followerP }, fsent)
    Sync._SelfId = function() return vann end
    Sync.RequestProfileSnapshot = previousRequestProfileSnapshot

    local previewSent = #fsent
    local previewOk, previewErr = Sync:CommitConsumablesOp(followerP, { name = "add_item", itemId = flask }, admin,
        { asAdmin = false })
    assertFalse(previewOk, "Preview as Non-Admin blocks follower config sends")
    assertTrue(contains(previewErr, "Preview as Non-Admin"), "the preview block explains why")
    assertEq(#fsent, previewSent, "Preview as Non-Admin does not whisper a config op")

    local builds = 0
    local payload = { meta = { _profileId = coordP._profileId }, marker = "shared" }
    Sync.BuildProfileSnapshot = function()
        builds = builds + 1
        return payload
    end
    Sync.cfg = { requestTimeoutSec = 5 }
    Sync.state._profileSnapshotBodyCache = nil
    local first = Sync:_CachedProfileSnapshot(coordP._profileId)
    local second = Sync:_CachedProfileSnapshot(coordP._profileId)
    assertEq(builds, 1, "concurrent snapshot serves reuse one built body")
    assertTrue(first == second, "the cached snapshot body is reused")
    local envelope = {}
    for k, v in pairs(first) do
        envelope[k] = v
    end
    envelope.requestId = "sender-a"
    assertEq(first.requestId, nil, "copying the envelope protects the shared cache body")
    Sync.state.sessionId = "s2"
    Sync:_CachedProfileSnapshot(coordP._profileId)
    assertEq(builds, 2, "a new session id rebuilds the snapshot cache")
    Sync.state.sessionId = "s1"
    Sync.state._profileSnapshotBodyCache = {
        profileId = coordP._profileId,
        sessionId = "s1",
        revision = "stale",
        at = clock,
        payload = payload,
    }
    Sync:_CachedProfileSnapshot(coordP._profileId)
    assertEq(builds, 3, "a changed profile revision rebuilds the snapshot cache")
    local reused = Sync:_CachedProfileSnapshot(coordP._profileId)
    assertEq(builds, 3, "unchanged authoritative state continues to reuse the cache")
    assertTrue(reused == payload, "cache reuse remains profile-local")
    local cachedProfile = Sync:FindLocalProfileById(coordP._profileId)
    cachedProfile._snapshotRevision = (cachedProfile._snapshotRevision or 0) + 1
    Sync:_CachedProfileSnapshot(coordP._profileId)
    assertEq(builds, 4, "an equal-count exported-state mutation invalidates the cache")
    Sync._Now = function() return clock + 100 end
    Sync:_CachedProfileSnapshot(coordP._profileId)
    assertEq(builds, 5, "the snapshot cache expires after the request timeout window")

    -- Re-diverge after the earlier successful catch-up so a failed NEED_PROFILE
    -- can clear the sticky descriptor key and allow another identical heartbeat.
    C.CommitEvents(coordP, "catch-fail",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 3),
        { writer = donor })
    assertTrue(S.NeedsCatchUp(C.Descriptor(followerP), C.Descriptor(coordP)),
        "a second coordinator donation leaves the follower behind again")
    local pending = #requests
    heartbeat()
    assertEq(#requests, pending + 1, "a divergent heartbeat requests another snapshot")
    assertTrue(Sync._consumablesCatchUpKey ~= nil, "catch-up stores its descriptor key after a request")
    local suppressed = #requests
    heartbeat()
    assertEq(#requests, suppressed, "a pending catch-up key still suppresses identical heartbeats")
    Sync._MInc = function() end
    Sync._MetricsUpdateRequestQueueGauges = function() end
    Sync.RunAfter = function() end
    Sync:_FailRequest({ id = "catch-fail", kind = "NEED_PROFILE", attempt = 3, maxRetries = 2 }, "max attempts reached")
    assertEq(Sync._consumablesCatchUpKey, nil, "a failed NEED_PROFILE clears the catch-up dedupe key")
    heartbeat()
    assertEq(#requests, suppressed + 1, "after a failed catch-up the next heartbeat requests again")

    resetSync()
end

local function checkPeerHistoryRecoveryServePath()
    -- Load the production NEED_PROFILE / PROFILE_SNAPSHOT handlers used for
    -- writer-offline recovery (not covered by MergeSnapshot-only unit tests).
    load("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
    load("SpectrumFederation/modules/LootHelperSync/01_Constants.lua")
    load("SpectrumFederation/modules/LootHelperSync/05_Scheduling.lua")
    load("SpectrumFederation/modules/LootHelperSync/11_Heartbeat.lua")
    load("SpectrumFederation/modules/LootHelperSync/14_HandlersControl.lua")
    load("SpectrumFederation/modules/LootHelperSync/15_HandlersBulk.lua")
    load("SpectrumFederation/modules/LootHelperSync/16_ProfileIntegration.lua")
    Sync = SF.LootHelperSync

    local writer = admin
    local peerAdmin = vann
    local coordB = "CoordB-Realm"
    local peerP = configured("recovery-peer")
    peerP._adminUsers = { writer, peerAdmin, coordB }
    peerP._profileId = "recovery-profile"
    C.SetGuild(peerP, writer, GUILD, 2)
    C.AddRequestedItem(peerP, writer, aqirite)
    local event = donation("ce:recovery-profile:Admin-Realm:1", donor, 8, { order = 1, writer = writer })
    assertTrue(C.AppendEvent(peerP, event), "recovery-serve peer stores stamped donation")
    C.StampOrder(peerP, peerP._consumableEvents[1])
    C.NoteStoredWriter(peerP, peerP._consumableEvents[1], writer)

    local late = profile("recovery-late", writer)
    late._profileId = "recovery-profile"
    late._adminUsers = { writer, peerAdmin, coordB }
    C.SetGuild(late, writer, GUILD, 2)
    C.AddRequestedItem(late, writer, aqirite)

    local sends = {}
    Sync.RunWithJitter = function(_, _, _, fn) fn() end
    Sync.UpdatePeersFromRoster = function() end
    Sync.GetPeer = function(_, name)
        return { inGroup = true, name = name }
    end
    Sync.IsBulkTransferAllowed = function() return true end
    Sync._ProfileSnapshotServeAllowed = function() return true end
    Sync._NoteProfileSnapshotServe = function() end
    Sync._CachedProfileSnapshot = function(_, profileId)
        local p = Sync:FindLocalProfileById(profileId)
        if not p then return nil end
        return {
            sessionId = Sync.state.sessionId,
            profileId = profileId,
            snapshot = {
                meta = { _profileId = profileId },
                adminUsers = p._adminUsers,
                consumables = C.ExportSnapshot(p),
                lootLogs = {},
            },
        }
    end
    Sync.ValidateSessionPayload = function() return true end
    Sync._RecordHandshakeReply = function() end
    Sync._HandlePeerIntegrityAdvertisement = function() end
    Sync.IsSenderAuthorized = function(_, _, name)
        return name == writer or name == peerAdmin or name == coordB
    end
    Sync._GetProfileAdminUsers = function(_, p) return p and p._adminUsers or {} end
    Sync.IsSelfHelper = function() return false end
    Sync.IsHelper = function() return false end
    Sync.IsTrustedDataSender = function(_, name)
        return name == coordB
    end
    Sync._SamePlayer = function(_, a, b) return a == b end
    Sync._SelfId = function() return peerAdmin end
    Sync._Now = function() return clock end
    Sync.FindLocalProfileById = function(_, id)
        if id == late._profileId then
            if Sync.state and Sync.state.isCoordinator then return late end
            return peerP
        end
        return nil
    end
    Sync.CompleteRequest = function(_, id)
        if Sync.state and Sync.state.requests then Sync.state.requests[id] = nil end
        return true
    end
    Sync._ClassifyPrivilegedResponse = function(_, sender, _, req, opts)
        if opts and opts.coordinatorAcceptsAdmins and Sync.state.isCoordinator
            and Sync:IsSenderAuthorized(Sync.state.profileId, sender) then
            return "accept"
        end
        return "untrusted"
    end
    SF.LootHelperComm = {
        Send = function(_, _, msg, payload, dist, target)
            sends[#sends + 1] = { msg = msg, payload = payload, dist = dist, target = target }
            return true
        end,
    }
    Sync.MSG = Sync.MSG or {}
    Sync.MSG.NEED_PROFILE = "NEED_PROFILE"
    Sync.MSG.PROFILE_SNAPSHOT = "PROFILE_SNAPSHOT"
    Sync.MSG.HAVE_PROFILE = "HAVE_PROFILE"

    -- Peer (non-helper admin) serves NEED_PROFILE from the session coordinator.
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = coordB,
        sessionId = "recovery-s1",
        profileId = "recovery-profile",
        helpers = {},
        requests = {},
    }
    Sync:HandleNeedProfile(coordB, {
        sessionId = "recovery-s1",
        profileId = "recovery-profile",
        requestId = "need-recovery-1",
    })
    local snapSend = nil
    for i = 1, #sends do
        if sends[i].msg == "PROFILE_SNAPSHOT" then snapSend = sends[i] end
    end
    assertTrue(snapSend ~= nil, "recovery-serve authorized admin sends PROFILE_SNAPSHOT")
    assertEq(snapSend.target, coordB, "recovery-serve whispers the requesting coordinator")
    assertTrue(type(snapSend.payload.snapshot) == "table"
        and type(snapSend.payload.snapshot.consumables) == "table",
        "recovery-serve payload includes consumables history")

    -- Coordinator absorbs consumables-only recovery and clears the history gate.
    Sync._SelfId = function() return coordB end
    Sync.state = {
        active = true,
        isCoordinator = true,
        coordinator = coordB,
        sessionId = "recovery-s1",
        profileId = "recovery-profile",
        helpers = {},
        requests = {
            ["need-recovery-1"] = {
                id = "need-recovery-1",
                kind = "NEED_PROFILE",
                meta = {
                    acceptAuthorizedAdmins = true,
                    consumablesHistoryOnly = true,
                    preferredTarget = peerAdmin,
                },
            },
        },
    }
    Sync.IsRequesterInGroup = function() return true end
    Sync.FindLocalProfileById = function(_, id)
        return id == late._profileId and late or nil
    end
    Sync._NextNonce = function() return "n1" end
    Sync.RequestProfileSnapshot = function(_, reason, opts)
        return true
    end
    local peerDesc = C.Descriptor(peerP)
    Sync:_NotePeerConsumablesHistory(peerAdmin, {
        profileId = late._profileId,
        sessionId = "recovery-s1",
        consumablesGeneration = peerDesc.generation,
        consumablesConfigSeq = peerDesc.configSeq,
        consumablesRejectionSeq = peerDesc.rejectionSeq,
        consumablesTxnAllocSeq = peerDesc.txnAllocSeq,
        consumablesEventCount = peerDesc.eventCount,
        consumablesEventFingerprint = peerDesc.eventFingerprint,
        consumablesArchiveCount = peerDesc.archiveCount,
        consumablesArchiveFingerprint = peerDesc.archiveFingerprint,
    })
    assertFalse(Sync:_ConsumablesHistoryReady(late), "recovery-serve gate holds before absorb")
    Sync:HandleProfileSnapshot(peerAdmin, {
        sessionId = "recovery-s1",
        profileId = "recovery-profile",
        requestId = "need-recovery-1",
        snapshot = snapSend.payload.snapshot,
    })
    assertTrue(Sync:_ConsumablesHistoryReady(late), "recovery-serve gate clears after absorb")
    assertEq(C.ContributionTotal(late, donor, aqirite), 8,
        "recovery-serve credits the recovered donation once")
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

local function makeLootHelperFrame()
    local frame = FrameMock("Frame")
    frame.Content = FrameMock("Frame", frame)
    frame.Content.SupplyReminder = FrameMock("Frame", frame.Content)
    frame.Content.SupplyReminder.MobileAnchor = FrameMock("Frame", frame.Content.SupplyReminder)
    frame.Content.SupplyReminder.MobileAnchor.shown = false
    return frame
end

local function runtimeFixture(id)
    resetWorld()
    resetRuntime()
    resetSync()
    reminderCalls = {}
    SF.SettingsStore.values = {}
    local frame = makeLootHelperFrame()
    SF.LootHelperWindow.Window._frame = frame
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

local function lastReminderMobile()
    local call = reminderCalls[#reminderCalls]
    return call and call.mobile
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
    world.bindTypes[aqirite] = 2
    world.boundSlots["0:1"] = true
    assertTrue(RT:Transferable(aqirite),
        "Add Item admission uses BindType even when the first bag stack is bound")
    world.boundSlots["0:1"] = nil
    world.bindTypes[aqirite] = nil
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
    local window = SF.LootHelperWindow.Window._frame
    assertEq(RT:LootHelperWindow(), SF.LootHelperWindow.Window,
        "runtime resolves the production Loot Helper Window child object")
    assertFalse(C_SpellBook.IsSpellInSpellBook(83958), "the Retail fixture keeps IsSpellInSpellBook false for guild perks")
    assertTrue(C_SpellBook.IsSpellKnown(83958), "the Retail fixture exposes Mobile Banking through IsSpellKnown")
    assertEq(RT:MobileSpell(), "Mobile Banking", "MobileSpell uses C_SpellBook.IsSpellKnown on Retail")

    RT:RefreshReminder()
    assertTrue(lastReminder(), "eligible reminder + ready Mobile Banking shows the banner")
    local mobile = lastReminderMobile()
    assertTrue(mobile ~= nil and mobile.visible, "the reminder exposes a Mobile Banking action")
    assertEq(mobile.spell, "Mobile Banking", "the banner Mobile Banking action uses the spell name")
    assertFalse(mobile.onCooldown, "the banner Mobile Banking action is off cooldown")
    assertTrue(window.Content.SupplyReminder.MobileAnchor:IsShown(), "the banner reserves layout space for Mobile Banking")
    assertTrue(RT.bannerMobileButton ~= nil, "the banner creates a secure Mobile Banking button")
    assertTrue(contains(RT.bannerMobileButton.template or "", "SecureActionButtonTemplate"),
        "the banner Mobile Banking button uses SecureActionButtonTemplate")
    assertFalse(contains(RT.bannerMobileButton.template or "", "UIPanelButtonTemplate"),
        "the banner Mobile Banking control is a compact icon, not a full panel button")
    assertEq(RT.bannerMobileButton.attributes.type, "spell", "the banner button is a secure spell action")
    assertEq(RT.bannerMobileButton.attributes.spell, "Mobile Banking", "the banner button casts Mobile Banking")
    assertTrue(RT.bannerMobileButton.enabled, "the banner Mobile Banking button is enabled when ready")
    assertTrue(RT.bannerMobileButton.Icon ~= nil, "the banner button uses the spell icon texture")
    assertEq(RT.bannerMobileButton.Icon.texture, "Interface\\Icons\\INV_Misc_BagCoin_07",
        "the banner icon uses the Mobile Banking spell texture")
    assertTrue(RT.bannerMobileButton.Cooldown ~= nil, "the banner button has a cooldown frame")
    assertEq(reminderCalls[#reminderCalls].onDismiss, nil, "the banner no longer exposes a Dismiss callback")
    assertEq(reminderCalls[#reminderCalls].onOpen, nil, "the banner no longer exposes a Review callback")
    assertEq(RT.dismissed, nil, "session dismissal state is removed from the runtime")
    assertEq(#(window.hooks.OnShow or {}), 1, "the reminder hooks the window OnShow once")

    RT.bannerMobileButton.scripts.OnEnter(RT.bannerMobileButton)
    assertTrue(GameTooltip.shown, "hovering the icon shows a tooltip")
    assertEq(GameTooltip.spellId, 83958, "the tooltip identifies Mobile Banking by spell id")
    RT.bannerMobileButton.scripts.OnLeave()

    SF.SettingsStore.values["lootHelper.showRaidSupplyReminders"] = false
    RT:RefreshReminder()
    assertFalse(lastReminder(), "the personal setting disables the reminder")
    assertFalse(window.Content.SupplyReminder.MobileAnchor:IsShown(), "disabling reminders hides the Mobile Banking layout reserve")
    SF.SettingsStore.values["lootHelper.showRaidSupplyReminders"] = true
    RT:RefreshReminder()
    assertTrue(lastReminder(), "re-enabling the setting restores the reminder")

    world.mobileCooldown = true
    world.mobileCooldownStart = GetTime()
    world.mobileCooldownDuration = 30
    RT:RefreshReminder()
    assertTrue(lastReminder(), "Mobile Banking on cooldown keeps an otherwise-eligible reminder visible")
    mobile = lastReminderMobile()
    assertTrue(mobile ~= nil and mobile.onCooldown, "cooldown leaves the banner icon in the cooldown state")
    assertFalse(RT:Collect().usable, "Mobile Banking on cooldown is still not a usable deposit path")
    assertEq(#RT:Collect().plan.lines, 0, "cooldown does not populate a donation plan")
    assertFalse(RT.bannerMobileButton.enabled, "the cooldown icon is not clickable as a ready spell")
    assertTrue(RT.bannerMobileButton.Icon.desaturated, "the cooldown icon is desaturated")
    assertEq(RT.bannerMobileButton.Cooldown.cooldownDuration, 30, "readable cooldown timing drives the swipe")
    assertEq(#liveTimers(), 1, "cooldown arms one bounded expiry refresh")
    world.mobileCooldown = false
    assertEq(fireTimers(), 1, "the expiry timer fires once")
    assertTrue(lastReminder(), "the expiry refresh keeps the reminder when Mobile Banking becomes ready")
    assertFalse(lastReminderMobile().onCooldown, "the expiry refresh restores the ready icon")
    assertEq(#liveTimers(), 0, "the expiry timer does not reschedule when Mobile Banking is ready")

    world.mobileCooldown = true
    world.mobileCooldownStart = GetTime()
    RT:RefreshReminder()
    assertTrue(lastReminder(), "cooldown again keeps the reminder visible")
    assertEq(#liveTimers(), 1, "SPELL_UPDATE_COOLDOWN path can re-arm an expiry watch")
    RT:OnEvent("SPELL_UPDATE_COOLDOWN", 83958)
    assertEq(#liveTimers(), 1, "SPELL_UPDATE_COOLDOWN replaces rather than stacks expiry watches")
    world.mobileCooldown = false
    fireTimers()
    assertTrue(lastReminder(), "SPELL_UPDATE_COOLDOWN-armed expiry still restores the ready icon")

    world.mobileKnown = false
    RT:RefreshReminder()
    assertFalse(lastReminder(), "without Mobile Banking and with the bank closed the reminder is hidden")
    assertEq(lastReminderMobile(), nil, "without Mobile Banking the banner omits the Mobile Banking action")
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

    world.bankOpen = true
    RT:RefreshReminder()
    assertTrue(lastReminder(), "an open configured guild bank still shows the reminder")
    assertEq(lastReminderMobile(), nil, "an open deposit path does not show the banner Mobile Banking action")
    world.bankOpen = false

    RT:RefreshReminder()
    assertTrue(lastReminder(), "the reminder is visible with ready Mobile Banking")
    assertTrue(RT.bannerMobileButton:IsShown(), "the banner Mobile Banking button is shown")

    window.__sfMinimized = true
    RT:RefreshReminder()
    assertFalse(lastReminder(), "a minimized Loot Helper window hides the reminder")
    assertFalse(RT.bannerMobileButton:IsShown(), "minimizing hides the detached Mobile Banking button")
    window.__sfMinimized = false
    RT:RefreshReminder()
    assertTrue(lastReminder(), "restoring the window shows the reminder again")
    assertTrue(RT.bannerMobileButton:IsShown(), "restoring shows the detached Mobile Banking button again")

    local leftBefore = RT.bannerMobileHolder.pointLeft
    window.hooks.OnSizeChanged[1]()
    assertEq(RT.bannerMobileHolder.pointLeft, leftBefore or 100,
        "resize repositions the detached holder from the MobileAnchor")

    world.inCombat = true
    window.hooks.OnHide[1]()
    assertTrue(RT.bannerMobilePending, "hiding in combat defers secure banner button sync")
    assertTrue(RT.bannerMobileButton:IsShown(), "combat does not hide the secure banner button immediately")
    world.inCombat = false
    window:Show()
    RT:OnEvent("PLAYER_REGEN_ENABLED")
    assertFalse(RT.bannerMobilePending, "leaving combat clears the deferred banner sync")
    -- Window was shown again above; hide out of combat to verify immediate hide.
    window.hooks.OnHide[1]()
    assertFalse(RT.bannerMobileButton:IsShown(), "out of combat, hiding the window hides the banner button")
    window:Show()
    RT:RefreshReminder()

    world.timers = {}
    local frames = frameCount
    local calls = #reminderCalls
    for _ = 1, 100 do RT:RefreshReminder() end
    assertEq(#reminderCalls, calls + 100, "each refresh updates the reminder exactly once")
    assertEq(#(window.hooks.OnShow or {}), 1, "repeated refreshes do not add window hooks")
    assertEq(#(window.hooks.OnHide or {}), 1, "repeated refreshes do not add hide hooks")
    assertEq(frameCount, frames, "repeated refreshes allocate no frames")
    assertEq(#world.after, 0, "repeated refreshes schedule no deferred work")
    assertEq(#liveTimers(), 0, "repeated refreshes create no live timers")
    assertEq(RT.bannerBankNav, nil, "repeated refreshes do not accumulate pending navigation")

    window.hooks.OnHide[1]()
    assertFalse(RT.reminderShown, "hiding the window clears the reminder state")
    assertFalse(RT.bannerMobileButton:IsShown(), "hiding the window hides the banner Mobile Banking button")
    unchanged(p, "runtime reminder")
end

local function checkRuntimeBannerBankNavigation()
    local p = runtimeFixture("rt-banner-nav")
    world.mobileKnown = true
    world.currentTab = 1
    RT:RefreshReminder()
    assertTrue(lastReminder(), "banner navigation fixture starts with a visible reminder")
    assertTrue(RT.bannerMobileButton ~= nil, "banner navigation fixture has a secure button")

    -- Ready icon click records a short-lived navigation intent.
    RT.bannerMobileButton.scripts.PreClick()
    assertTrue(RT.bannerBankNav ~= nil, "clicking the banner Mobile Banking action records pending navigation")
    assertEq(RT.bannerBankNav.profileId, p._profileId, "pending navigation captures the profile id")
    assertEq(RT.bannerBankNav.guildGuid, "club-1", "pending navigation captures the configured guild")
    assertEq(RT.bannerBankNav.bankTab, 2, "pending navigation captures the configured tab")
    assertEq(RT.bannerBankNav.configSeq, p._consumables.configSeq, "pending navigation captures configSeq")
    assertEq(#liveTimers(), 1, "pending navigation arms one bounded expiry timer")

    world.bankOpen = true
    world.tabSelects = {}
    world.tabQueries = {}
    RT:OnBankOpened()
    assertEq(#world.tabSelects, 1, "banner-initiated Guild Bank open selects the configured tab once")
    assertEq(world.tabSelects[1], 2, "banner-initiated open selects the configured Raid Consumables tab")
    assertEq(#world.tabQueries, 1, "selecting the configured tab queries that tab")
    assertEq(world.currentTab, 2, "GetCurrentGuildBankTab reflects the configured tab")
    assertEq(RT.bannerBankNav, nil, "successful navigation consumes the pending intent")
    assertTrue(RT.review ~= nil and RT.review:IsShown(),
        "existing auto-review can open after banner navigation lands on the configured tab")

    -- Duplicate open signals must remain idempotent.
    local selectsAfterFirst = #world.tabSelects
    RT:OnEvent("GUILDBANKFRAME_OPENED")
    RT:OnEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.GuildBanker)
    assertEq(#world.tabSelects, selectsAfterFirst, "duplicate Guild Bank open signals do not select again")
    assertEq(RT.bannerBankNav, nil, "duplicate opens do not recreate pending navigation")

    RT:OnBankClosed()
    world.bankOpen = false
    if RT.review then RT.review:Hide() end
    RT.autoReviewedThisOpen = false
    world.currentTab = 1
    world.tabSelects = {}
    world.timers = {}

    -- Manual Guild Bank opening never auto-selects the Consumables tab.
    world.bankOpen = true
    RT:OnBankOpened()
    assertEq(#world.tabSelects, 0, "a normal/manual Guild Bank opening does not force the configured tab")
    assertEq(world.currentTab, 1, "manual open leaves the player's current tab alone")
    RT:OnBankClosed()
    world.bankOpen = false
    if RT.review then RT.review:Hide() end

    -- Failed/no bank opening must not leak pending navigation into a later visit.
    world.currentTab = 1
    world.tabSelects = {}
    world.timers = {}
    RT:RefreshReminder()
    RT.bannerMobileButton.scripts.PreClick()
    assertTrue(RT.bannerBankNav ~= nil, "a second banner click recreates pending navigation")
    assertEq(fireTimers(), 1, "pending navigation expires when the bank never opens")
    assertEq(RT.bannerBankNav, nil, "expired navigation clears the pending intent")
    world.bankOpen = true
    RT:OnBankOpened()
    assertEq(#world.tabSelects, 0, "a later manual open after expiry does not select the configured tab")
    RT:OnBankClosed()
    world.bankOpen = false
    if RT.review then RT.review:Hide() end

    -- Profile/config/tab/guild changing between click and open cancels navigation.
    world.currentTab = 1
    world.tabSelects = {}
    world.timers = {}
    RT:RefreshReminder()
    RT.bannerMobileButton.scripts.PreClick()
    assertTrue(RT.bannerBankNav ~= nil, "navigation pending before a configuration change")
    assertTrue(select(1, C.SetBankTab(p, admin, 3)), "admin can change the configured tab after the click")
    world.bankOpen = true
    RT:OnBankOpened()
    assertEq(#world.tabSelects, 0, "a changed bank tab cancels banner navigation")
    assertEq(RT.bannerBankNav, nil, "identity mismatch consumes/clears pending navigation")
    RT:OnBankClosed()
    world.bankOpen = false
    if RT.review then RT.review:Hide() end
    assertTrue(select(1, C.SetBankTab(p, admin, 2)), "restore the configured tab for later cases")

    world.currentTab = 1
    world.tabSelects = {}
    world.timers = {}
    RT:RefreshReminder()
    RT.bannerMobileButton.scripts.PreClick()
    world.clubId = "club-other"
    world.bankOpen = true
    RT:OnBankOpened()
    assertEq(#world.tabSelects, 0, "a guild mismatch cancels banner navigation")
    assertEq(RT.bannerBankNav, nil, "wrong-guild open clears pending navigation")
    world.clubId = "club-1"
    RT:OnBankClosed()
    world.bankOpen = false
    if RT.review then RT.review:Hide() end

    -- Invalid/non-viewable configured tab fails safely.
    world.currentTab = 1
    world.tabSelects = {}
    world.timers = {}
    world.tabViewable[2] = false
    RT:RefreshReminder()
    RT.bannerMobileButton.scripts.PreClick()
    world.bankOpen = true
    RT:OnBankOpened()
    assertEq(#world.tabSelects, 0, "a non-viewable configured tab is not selected")
    assertEq(RT.bannerBankNav, nil, "non-viewable tab still clears pending navigation")
    world.tabViewable[2] = nil
    RT:OnBankClosed()
    world.bankOpen = false
    if RT.review then RT.review:Hide() end

    -- Profile change cancels pending navigation immediately.
    world.timers = {}
    RT:RefreshReminder()
    RT.bannerMobileButton.scripts.PreClick()
    assertTrue(RT.bannerBankNav ~= nil, "navigation pending before profile change")
    local other = configured("rt-banner-nav-other")
    SF.lootHelperDB.profiles[other._profileId] = other
    RT:OnProfileChanged(other)
    assertEq(RT.bannerBankNav, nil, "profile change cancels pending banner navigation")

    -- Cooldown PreClick must not create navigation.
    world.activeProfile = p
    RT:OnProfileChanged(p)
    world.mobileCooldown = true
    world.mobileCooldownStart = GetTime()
    world.mobileCooldownDuration = 30
    world.timers = {}
    RT:RefreshReminder()
    assertTrue(lastReminderMobile().onCooldown, "cooldown icon is present for PreClick guard")
    RT.bannerMobileButton.scripts.PreClick()
    assertEq(RT.bannerBankNav, nil, "cooldown PreClick does not create pending navigation")
    world.mobileCooldown = false

    -- Repeated open/close cycles converge without growing pending state or frames.
    world.timers = {}
    world.tabSelects = {}
    local frames = frameCount
    for _ = 1, 20 do
        RT:RefreshReminder()
        RT.bannerMobileButton.scripts.PreClick()
        world.currentTab = 1
        world.bankOpen = true
        RT:OnBankOpened()
        RT:OnBankClosed()
        world.bankOpen = false
        if RT.review then RT.review:Hide() end
    end
    assertEq(RT.bannerBankNav, nil, "repeated banner open cycles leave no pending navigation")
    assertEq(frameCount, frames, "repeated banner navigation cycles allocate no frames")
    assertEq(#liveTimers(), 0, "repeated banner navigation cycles leave no live timers")
    unchanged(p, "runtime banner bank navigation")
end

-- Regression (#350): ConsumablesRuntime may initialize before Loot Helper creates
-- its frame. Attachment must succeed after the production Window._frame exists.
local function checkRuntimeReminderLifecycleAttach()
    resetWorld()
    resetRuntime()
    resetSync()
    reminderCalls = {}
    SF.SettingsStore.values = {}
    local p = configured("rt-lifecycle-attach")
    world.activeProfile = p
    SF.lootHelperDB.profiles = { [p._profileId] = p }
    world.mobileKnown = true
    world.bags[0] = {
        [1] = { itemId = aqirite, count = 15 },
        [2] = { itemId = aqirite, count = 10 },
    }

    -- 1) ConsumablesRuntime starts before the Loot Helper frame exists.
    SF.LootHelperWindow.Window._frame = nil
    local earlyCalls = #reminderCalls
    RT:WatchWindow()
    RT:RefreshReminder()
    assertEq(SF.LootHelperWindow.Window._frame, nil, "the Loot Helper frame is still missing during early init")
    assertEq(#reminderCalls, earlyCalls + 1, "early refresh still updates reminder state once")
    assertFalse(lastReminder(), "without a Loot Helper frame the reminder stays hidden")
    assertEq(SF.LootHelperWindow._frame, nil, "the parent namespace never owns the production frame")

    -- 2) Window:Create establishes the frame and notifies ConsumablesRuntime.
    local frame = makeLootHelperFrame()
    frame.shown = false
    SF.LootHelperWindow.Window._frame = frame
    RT:RefreshReminder()
    assertEq(#(frame.hooks.OnShow or {}), 1, "create-time refresh hooks OnShow once")
    assertEq(#(frame.hooks.OnHide or {}), 1, "create-time refresh hooks OnHide once")
    assertFalse(lastReminder(), "a created but still-hidden window keeps the reminder hidden")

    -- 3) Window becomes eligible/visible; OnShow reevaluates reminder state.
    frame:Show()
    frame.hooks.OnShow[1]()
    assertTrue(lastReminder(),
        "after the production Window becomes visible, carried items + Mobile Banking show the reminder")
    local mobile = lastReminderMobile()
    assertTrue(mobile ~= nil and mobile.visible, "lifecycle attach exposes Mobile Banking on the banner")

    -- Bag changes continue to drive the real Window object.
    world.bags[0][1].count = 0
    world.bags[0][2].count = 0
    RT:RefreshReminder()
    assertFalse(lastReminder(), "removing carried requested items hides the reminder after attach")
    world.bags[0][1].count = 15
    world.bags[0][2].count = 10
    RT:RefreshReminder()
    assertTrue(lastReminder(), "returning requested items shows the reminder on the attached Window")

    local hooksBefore = #(frame.hooks.OnShow or {})
    for _ = 1, 20 do RT:RefreshReminder() end
    assertEq(#(frame.hooks.OnShow or {}), hooksBefore, "post-attach refreshes do not accumulate OnShow hooks")
    assertEq(#(frame.hooks.OnHide or {}), 1, "post-attach refreshes do not accumulate OnHide hooks")
    unchanged(p, "runtime reminder lifecycle attach")
end

local function checkRuntimeMobileSpellDetection()
    local p = runtimeFixture("rt-mobile-api")
    world.mobileKnown = true
    world.bankOpen = false

    -- Regression: IsSpellInSpellBook false must not hide a known guild perk.
    assertFalse(C_SpellBook.IsSpellInSpellBook(83958, Enum.SpellBookSpellBank.Player),
        "IsSpellInSpellBook stays false for the Mobile Banking guild perk")
    assertTrue(RT:MobileSpellKnown(), "IsSpellKnown reports Mobile Banking as known")
    assertTrue(RT:Collect().usable, "the closed bank is usable through IsSpellKnown Mobile Banking")
    RT:RefreshReminder()
    assertTrue(lastReminder(), "the reminder appears through the modern C_SpellBook.IsSpellKnown path")

    -- Prefer NeverSecret isActive for cooldown decisions.
    world.mobileCooldown = true
    assertTrue(RT:MobileOnCooldown("Mobile Banking"), "isActive true means Mobile Banking is on cooldown")
    assertEq(RT:MobileCooldownRemaining("Mobile Banking"), 30, "readable remaining cooldown is available for expiry scheduling")
    world.mobileCooldown = false
    assertFalse(RT:MobileOnCooldown("Mobile Banking"), "isActive false means Mobile Banking is ready")

    -- Legacy fallback when C_SpellBook.IsSpellKnown is unavailable.
    local savedKnown = C_SpellBook.IsSpellKnown
    C_SpellBook.IsSpellKnown = nil
    assertTrue(RT:MobileSpellKnown(), "IsPlayerSpell remains a fallback when IsSpellKnown is absent")
    C_SpellBook.IsSpellKnown = savedKnown

    world.mobileKnown = false
    assertFalse(RT:MobileSpellKnown(), "IsSpellKnown false means Mobile Banking is unavailable")
    assertEq(RT:MobileSpell(), nil, "an unknown Mobile Banking spell resolves to nil")
    unchanged(p, "runtime mobile spell detection")
end

local function checkRuntimeReview()
    local p = runtimeFixture("rt-review")
    world.bankOpen = true
    RT:OnBankOpened()
    local review = RT.review
    assertTrue(review ~= nil and review:IsShown(), "opening the guild bank auto-opens the review when carrying requested items")
    assertEq(review.Rows[1].Text.text, "Guild Bank", "the review groups lines under the Guild Bank")
    local row = review.Rows[2]
    assertTrue(row.IconButton and row.IconButton:IsShown(), "donation rows show the item icon")
    assertEq(row.Icon.texture, "Interface\\Icons\\Item190000", "the icon matches the requested item")
    assertEq(row.Progress.text, "No Goal", "goal-0 items display No Goal")
    assertEq(row.Edit.text, "25", "goal-0 suggested quantity uses the carried count")
    assertEq(row.Button.text, "Deposit", "the review action is Deposit")
    assertTrue(row.Button.enabled, "the Deposit action is enabled when the configured tab can take deposits")
    assertTrue(review.Rows[3] == nil or not review.Rows[3]:IsShown(), "non-requested items are not listed")
    assertEq(review.Status.text, "The configured guild bank tab can take deposits.", "the review explains the deposit path")
    assertEq(review.ProgressEmpty.text, "No goals configured.", "no positive goals shows the empty overall state")
    assertFalse(review.ProgressBar:IsShown(), "no positive goals hides the overall progress bar")

    GameTooltip.shown = false
    GameTooltip.itemId = nil
    row.IconButton.scripts.OnEnter(row.IconButton)
    assertTrue(GameTooltip.shown, "hovering the item icon shows a tooltip")
    assertEq(GameTooltip.itemId, aqirite, "the tooltip identifies the requested item")

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
    assertEq(review.Rows[2].Edit.text, "3", "the review shows the edited quantity")

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

local function countCloseButtons(parent)
    local count = 0
    for i = 1, #createdFrames do
        local frame = createdFrames[i]
        if frame.parent == parent and type(frame.template) == "string"
            and frame.template:find("UIPanelCloseButton", 1, true) then
            count = count + 1
        end
    end
    return count
end

local function checkRuntimeReviewGuildBankLifecycle()
    local p = runtimeFixture("rt-review-lifecycle")
    world.bankOpen = true
    world.currentTab = 2
    RT:OnBankOpened()
    local review = RT.review
    assertTrue(review ~= nil and review:IsShown(),
        "configured-tab open shows the Raid Supplies window when eligible")
    assertEq(countCloseButtons(review), 0,
        "the standalone Raid Supplies window has no X/close control")

    -- Configured tab → other tab → hide (lifecycle, not dismissal).
    world.currentTab = 1
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertFalse(review:IsShown(),
        "leaving the configured tab hides the Raid Supplies window")
    assertFalse(RT.autoReviewedThisOpen,
        "leaving the configured tab clears the auto-review latch")

    -- Other tab → configured tab → show again when eligible.
    world.currentTab = 2
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertTrue(review:IsShown(),
        "returning to the configured tab shows the window again when eligible")
    assertTrue(RT.autoReviewedThisOpen,
        "returning to the configured tab re-latches auto-review for this visit")

    -- Final supplies deposited while staying on the configured tab → empty state stays.
    world.bags[0][1].count = 0
    world.bags[0][2].count = 0
    RT:OnEvent("BAG_UPDATE_DELAYED")
    assertTrue(review:IsShown(),
        "depositing the final supplies while on the configured tab keeps the window open")
    assertEq(review.Rows[1].Text.text, "No raid supplies to deposit.",
        "the already-open window keeps the empty deposit state")

    -- Empty window must not auto-appear when it was not already open.
    review:Hide()
    RT.autoReviewedThisOpen = false
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertFalse(review:IsShown(),
        "an empty review does not auto-open when nothing is eligible to deposit")

    -- Restore carried supplies for remaining lifecycle checks.
    world.bags[0][1] = { itemId = aqirite, count = 20 }
    world.bags[0][2] = { itemId = aqirite, count = 5 }
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertTrue(review:IsShown(),
        "eligible supplies on the configured tab can open the window again")

    -- Guild Bank close → window hidden.
    RT:OnBankClosed()
    world.bankOpen = false
    assertFalse(review:IsShown(),
        "closing the Guild Bank hides the Raid Supplies window")

    -- Reopen → behavior works again.
    world.bankOpen = true
    world.currentTab = 2
    RT:OnBankOpened()
    assertTrue(review:IsShown(),
        "reopening the Guild Bank on the configured tab can show the window again")

    -- Open on a non-configured tab does not show the window.
    RT:OnBankClosed()
    world.bankOpen = false
    world.currentTab = 1
    world.bankOpen = true
    RT:OnBankOpened()
    assertFalse(review:IsShown(),
        "opening on a non-configured tab does not show the Raid Supplies window")

    -- Repeated open/close and tab-switch cycles remain bounded.
    local frames = frameCount
    local afterN = #world.after
    local timersN = #liveTimers()
    local reviewRef = RT.review
    for _ = 1, 40 do
        world.currentTab = 2
        world.bankOpen = true
        RT:OnBankOpened()
        world.currentTab = 1
        RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
        RT:OnBankClosed()
        world.bankOpen = false
    end
    assertEq(frameCount, frames,
        "repeated Guild Bank open/close and tab cycles allocate no new frames")
    assertEq(#world.after, afterN,
        "repeated Guild Bank lifecycle cycles schedule no deferred work")
    assertEq(#liveTimers(), timersN,
        "repeated Guild Bank lifecycle cycles create no live timers")
    assertTrue(RT.review == reviewRef,
        "repeated Guild Bank lifecycle cycles reuse the same review frame")
    assertEq(RT.bannerBankNav, nil,
        "repeated Guild Bank lifecycle cycles do not accumulate pending navigation")

    -- #354 banner → Mobile Banking → configured tab → existing auto-review remains intact.
    world.mobileKnown = true
    world.currentTab = 1
    world.tabSelects = {}
    world.tabQueries = {}
    world.timers = {}
    world.bags[0][1] = { itemId = aqirite, count = 20 }
    world.bags[0][2] = { itemId = aqirite, count = 5 }
    RT:RefreshReminder()
    assertTrue(RT.bannerMobileButton ~= nil, "lifecycle fixture exposes the banner Mobile Banking button")
    RT.bannerMobileButton.scripts.PreClick()
    assertTrue(RT.bannerBankNav ~= nil, "banner Mobile Banking records pending navigation")
    world.bankOpen = true
    RT:OnBankOpened()
    assertEq(#world.tabSelects, 1, "banner-initiated open still selects the configured tab once")
    assertEq(world.tabSelects[1], 2, "banner-initiated open still selects the Raid Consumables tab")
    assertEq(world.currentTab, 2, "banner navigation still lands on the configured tab")
    assertEq(RT.bannerBankNav, nil, "banner navigation is still consumed before auto-review")
    assertTrue(review:IsShown(),
        "banner → Mobile Banking → configured tab still triggers the existing Raid Supplies window")
    RT:OnBankClosed()
    world.bankOpen = false
    unchanged(p, "runtime review guild bank lifecycle")
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

local function checkRuntimeReviewDepositTabSwitch()
    local p = runtimeFixture("rt-review-deposit-tab")
    world.bankOpen = true
    world.currentTab = 2
    RT:OnBankOpened()
    local review = RT.review
    assertTrue(review ~= nil and review:IsShown(),
        "deposit tab-switch fixture starts with a visible Raid Supplies window")

    -- Active depositWork: GUILDBANKBAGSLOTS_CHANGED must still lifecycle-sync.
    startDeposit()
    assertTrue(RT.depositWork ~= nil, "deposit work is active before the mid-deposit tab change")
    world.currentTab = 1
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertFalse(review:IsShown(),
        "leaving the configured tab during depositWork hides the Raid Supplies window")
    assertFalse(RT.autoReviewedThisOpen,
        "leaving the configured tab during depositWork clears the auto-review latch")

    RT:CancelDepositWork()
    RT.depositIntent = nil
    world.after = {}
    world.places = {}
    world.currentTab = 2
    world.bags[0][1] = { itemId = aqirite, count = 20 }
    world.bags[0][2] = { itemId = aqirite, count = 5 }
    world.bank[2] = { [1] = { itemId = aqirite, count = 18 } }
    RT.autoReviewedThisOpen = false
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertTrue(review:IsShown(),
        "returning to the configured tab after a mid-deposit leave can show the window again")

    -- Confirmation intent: FinishDeposit bookkeeping must still be followed by sync.
    startDeposit()
    drainAfter(32)
    assertTrue(RT.depositIntent ~= nil, "deposit settles into a confirmation intent")
    assertEq(RT.depositWork, nil, "deposit work is cleared before confirmation")
    assertTrue(review:IsShown(), "confirmation intent keeps the review visible on the configured tab")
    world.currentTab = 1
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertFalse(review:IsShown(),
        "leaving the configured tab while awaiting deposit confirmation hides the Raid Supplies window")
    assertFalse(RT.autoReviewedThisOpen,
        "leaving the configured tab during depositIntent clears the auto-review latch")

    RT:OnBankClosed()
    world.bankOpen = false
    unchanged(p, "runtime review deposit tab switch")
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
    -- Issue #366 PR2: deposit assistant no longer creates CONSUMABLE_DONATION.
    -- Guild Bank transaction observation/verification is the accounting source.
    assertEq(#p._consumableEvents, 0, "a confirmed deposit does not directly record a donation")
    assertEq(C.ContributionTotal(p, donor, aqirite), 0, "deposit assistant does not update contribution totals")
    assertTrue(#world.infos > 0, "a clean deposit still reports materials were moved")
    local infoText = table.concat(world.infos, "\n")
    assertTrue(contains(infoText, "verification") or contains(infoText, "Guild Bank"),
        "deposit success mentions verification wait")
    assertEq(#world.warnings, 0, "a clean deposit shows no warnings")
    assertEq(#(p._consumablesUnsent or {}), 0, "no donation is queued from the deposit assistant")

    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    RT:OnEvent("BAG_UPDATE_DELAYED")
    assertEq(#p._consumableEvents, 0, "later bank events do not invent a deposit-assistant donation")
    assertEq(fireTimers(), 0, "no timers remain after the deposit")
    local ok, bad = onlyDonationAndReset(p)
    assertTrue(ok, "runtime deposits create no receipt or custody events (" .. tostring(bad) .. ")")

    p = runtimeFixture("rt-deposit-race")
    world.bankOpen = true
    startDeposit()
    assertEq(#world.places, 1, "the first place still lands before a race")
    -- Another member fills the next precomputed empty targets before continuation.
    world.bank[2][2] = { itemId = flask, count = 1 }
    world.bank[2][3] = { itemId = flask, count = 1 }
    world.bank[2][4] = { itemId = flask, count = 1 }
    local placesBefore = #world.places
    drainAfter(32)
    assertEq(#world.places, placesBefore, "a raced target does not continue placements")
    assertEq(world.withdrawAttempts, 0, "a raced target never withdraws the foreign bank item")
    RT:CancelDepositWork()
    RT.depositIntent = nil
    if RT.depositTimer and RT.depositTimer.Cancel then RT.depositTimer:Cancel() end
    RT.depositTimer = nil
    world.after = {}
    world.places = {}
end


local function checkStaleDepositReview()
    local a = runtimeFixture("stale-A")
    local b = configured("stale-B")
    -- Stable IDs can be provided by the profile method rather than the storage field.
    function a:GetProfileId() return "stale-A" end
    function b:GetProfileId() return "stale-B" end
    SF.lootHelperDB.profiles[b:GetProfileId()] = b
    world.bankOpen = true
    RT:OnBankOpened()
    local oldClick = RT.review.Rows[2].Button.scripts.OnClick
    Sync.state = { active = true, profileId = b:GetProfileId(), sessionId = "profile-transition" }
    oldClick()
    assertEq(#world.places, 0, "a stale profile-A button performs no deposit")
    assertEq(RT.depositWork, nil, "a stale review does not begin deposit work")
    assertEq(#a._consumableEvents, 0, "a stale button records no contribution on A")
    assertEq(#(a._consumablesUnsent or {}), 0, "a stale button queues no contribution on A")
    assertTrue(RT.review.Rows[2].Button.scripts.OnClick ~= oldClick, "the stale review is rebuilt for the current profile")
    RT.review.Rows[2].Button.scripts.OnClick()
    drainAfter(32)
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertEq(#b._consumableEvents, 0, "the refreshed button deposits against B without direct accounting")
    assertTrue(#world.places > 0, "the refreshed unchanged-profile button still moves items for B")
    assertEq(#a._consumableEvents, 0, "the completed B deposit leaves A unchanged")
end

local function checkOccupiedDepositCursor()
    for case, itemId in ipairs({ junk, aqirite, aqirite }) do
        local p = runtimeFixture("occupied-" .. tostring(itemId))
        world.bankOpen = true
        RT:OnBankOpened()
        if case == 3 then world.bank[2] = {} end -- Exercise full-stack pickup, too.
        local held = { itemId = itemId, count = 99 }
        world.cursor = held
        RT.review.Rows[2].Button.scripts.OnClick()
        assertEq(#world.pickups, 0, "occupied cursor prevents bag pickup for " .. tostring(itemId))
        assertEq(#world.splits, 0, "occupied cursor prevents bag split for " .. tostring(itemId))
        assertEq(#world.places, 0, "occupied cursor prevents bank pickup for " .. tostring(itemId))
        assertTrue(world.cursor == held, "the player's occupied cursor is untouched")
        assertEq(RT.depositWork, nil, "occupied cursor prevents new deposit work")
        assertEq(#p._consumableEvents, 0, "occupied cursor records no contribution")
        assertEq(#(p._consumablesUnsent or {}), 0, "occupied cursor queues no contribution")
    end
    local p = runtimeFixture("occupied-between")
    world.bankOpen = true
    startDeposit()
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertEq(RT.depositWork.bestActual, 2, "the first placement has verified credit")
    local splits, pickups = #world.splits, #world.pickups
    local held = { itemId = aqirite, count = 99 }
    world.cursor = held
    drainAfter(32)
    fireTimers()
    assertEq(#world.pickups, pickups, "an occupied deferred cursor stops further bag pickups")
    assertEq(#world.splits, splits, "an occupied deferred cursor stops further splits")
    assertEq(#world.places, 1, "an occupied deferred cursor stops further bank placements")
    assertTrue(world.cursor == held, "cancellation leaves the manual cursor item untouched")
    assertEq(RT.depositWork, nil, "cursor interruption cancels future placement work")
    assertEq(#p._consumableEvents, 0, "cursor interruption does not create deposit-assistant accounting")
    assertEq(#world.after, 0, "cursor interruption leaves no continuations")
    assertEq(#liveTimers(), 0, "cursor interruption leaves no deadline")
    -- A non-item payload must not be confused with the requested item, either.
    p = runtimeFixture("occupied-spell")
    world.bankOpen = true
    world.cursor = { kind = "spell" }
    startDeposit()
    assertEq(#world.places, 0, "a non-item cursor payload performs no item movement")
    assertEq(#p._consumableEvents, 0, "a non-item cursor payload records no donation")
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
    assertEq(#p._consumableEvents, 0, "the deadline does not create deposit-assistant accounting")
    assertTrue(contains(world.infos[#world.infos], "The rest is still in your bags"), "a partial deposit explains the remainder")

    p = runtimeFixture("rt-bank-only")
    world.bankOpen = true
    startDeposit()
    drainAfter(32)
    world.bags[0][1].count = 15
    world.bags[0][2].count = 10
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    fireTimers()
    assertEq(#p._consumableEvents, 0, "slot increases without bag movement never receive credit")

    p = runtimeFixture("rt-bank-over-bags")
    world.bankOpen = true
    startDeposit()
    drainAfter(32)
    world.bags[0][1].count = 13
    world.bags[0][2].count = 10
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    fireTimers()
    assertEq(#p._consumableEvents, 0, "joint slot and bag evidence no longer creates deposit-assistant accounting")

    p = runtimeFixture("rt-split-observation")
    world.bankOpen = true
    startDeposit()
    drainAfter(32)
    world.bags[0][1].count = 15
    world.bags[0][2].count = 10
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertEq(#p._consumableEvents, 0, "a bank update waits while matching bag movement is pending")
    world.bags[0][1].count = 13
    RT:OnEvent("BAG_UPDATE_DELAYED")
    assertTrue(RT.depositIntent ~= nil, "separate bag evidence verifies the partial transfer without committing early")
    fireTimers()
    assertEq(#p._consumableEvents, 0, "separately arriving evidence does not create deposit-assistant accounting")

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

    p = runtimeFixture("rt-bound-source")
    world.bankOpen = true
    world.boundSlots["0:1"] = true
    world.boundSlots["0:2"] = true
    startDeposit()
    drainAfter(32)
    assertEq(#world.places, 0, "bound source stacks are never picked up")
    assertEq(RT.depositWork, nil, "skipping bound stacks ends the deposit work")
    assertEq(#p._consumableEvents, 0, "bound source stacks record nothing")
    assertEq(world.bags[0][1].count + world.bags[0][2].count, 25, "bound stacks stay in the bags")

    p = runtimeFixture("rt-bound-later")
    world.bankOpen = true
    startDeposit()
    assertEq(#world.places, 1, "an unbound first stack still places")
    world.boundSlots["0:2"] = true
    drainAfter(32)
    local placedAfterBound = #world.places
    assertTrue(placedAfterBound >= 1, "placing continues after the first stack")
    assertEq(world.bags[0][2].count, 10, "a later-bound residual stack is left in the bags")

    p = runtimeFixture("rt-no-numslots-api")
    world.bankOpen = true
    local savedNumSlots = GetGuildBankNumSlots
    GetGuildBankNumSlots = nil
    assertEq(RT:GuildBankSlotCount(2), 98, "without GetGuildBankNumSlots the retail tab size is used")
    assertTrue(RT:FreeSlots(2) >= 1, "free-slot scans work without GetGuildBankNumSlots")
    assertTrue(#RT:DepositTargets(2, aqirite, 3) >= 1, "deposit targets work without GetGuildBankNumSlots")
    local collectedNoApi = RT:Collect()
    assertTrue(collectedNoApi.usable, "an open configured tab is usable without GetGuildBankNumSlots")
    GetGuildBankNumSlots = savedNumSlots

    p = runtimeFixture("rt-config-mid-place")
    world.bankOpen = true
    startDeposit()
    assertEq(#world.places, 1, "the first place lands before a mid-deposit config change")
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    local placesBeforeConfig = #world.places
    assertTrue(select(1, C.RemoveRequestedItem(p, admin, aqirite)), "removing the requested item bumps configSeq")
    drainAfter(32)
    assertEq(#world.places, placesBeforeConfig, "a mid-deposit config change stops further placements")
    assertEq(RT.depositWork, nil, "a mid-deposit config change clears deposit work")
    assertEq(RT.depositIntent, nil, "a mid-deposit config change does not open a deposit intent")
    assertEq(#p._consumableEvents, 0, "a mid-deposit config change does not create deposit-assistant accounting")
    assertTrue(contains(world.warnings[#world.warnings], "configuration changed"),
        "a mid-deposit config change warns the player")

    p = runtimeFixture("rt-config-mid-confirm")
    world.bankOpen = true
    startDeposit()
    drainAfter(32)
    assertTrue(type(RT.depositIntent) == "table", "placements finish into a confirmation intent")
    assertTrue(select(1, C.SetBankTab(p, admin, 3)), "changing the bank tab bumps configSeq during confirmation")
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertEq(RT.depositIntent, nil, "a config change during confirmation clears the intent")
    assertEq(#p._consumableEvents, 0, "a config change during confirmation does not create deposit-assistant accounting")
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

    deleted = {}
    p = runtimeFixture("rt-close-after-place")
    world.bankOpen = true
    startDeposit()
    assertEq(#world.places, 1, "one placement can succeed before the bank closes")
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertEq(RT.depositWork and RT.depositWork.bestActual, 2, "partial credit is verified before closure")
    world.bankReadable = false
    RT:OnBankClosed()
    assertEq(#p._consumableEvents, 0, "bank closure does not create deposit-assistant accounting")
    drainAfter(32)
    fireTimers()
    assertEq(#p._consumableEvents, 0, "delayed continuations and timers cannot invent closed-bank credit")
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

local function checkGoalsAndProgress()
    local p = configured("goals")
    assertEq(p._consumables.requestedItems[tostring(aqirite)].goal, 0, "configured fixture starts at goal 0")
    assertTrue(select(1, C.SetRequestedGoal(p, admin, aqirite, 200)), "an admin can set a positive goal")
    assertEq(p._consumables.requestedItems[tostring(aqirite)].goal, 200, "the goal is stored on the requested row")
    assertFalse(select(1, C.SetRequestedGoal(p, donor, aqirite, 50)), "a non-admin cannot change goals")
    assertEq(p._consumables.requestedItems[tostring(aqirite)].goal, 200, "a denied goal change leaves the goal")
    assertFalse(select(1, C.SetRequestedGoal(p, admin, aqirite, -1)), "a negative goal is rejected")
    assertFalse(select(1, C.SetRequestedGoal(p, admin, aqirite, 1.5)), "a fractional goal is rejected")
    assertFalse(select(1, C.SetRequestedGoal(p, admin, aqirite, "nope")), "a non-numeric goal is rejected")
    assertFalse(select(1, C.SetRequestedGoal(p, admin, aqirite, math.huge)), "an infinite goal is rejected")
    assertEq(C.ValidGoal(999999), nil, "values above MAX_GOAL fail domain validation")
    assertFalse(select(1, C.SetRequestedGoal(p, admin, aqirite, C.MAX_GOAL + 1)),
        "out-of-range goals are rejected before sync")
    assertEq(C.ValidGoal(C.MAX_GOAL), C.MAX_GOAL, "MAX_GOAL itself is accepted")
    assertTrue(select(1, C.ApplyOp(p, { name = "set_goal", itemId = aqirite, goal = 100 }, admin)),
        "ApplyOp set_goal works for an admin")
    assertEq(p._consumables.requestedItems[tostring(aqirite)].goal, 100, "ApplyOp stores the goal")
    assertFalse(select(1, C.ApplyOp(p, { name = "set_goal", itemId = aqirite, goal = 10 }, donor)),
        "ApplyOp set_goal denies a non-admin")

    local beforeFp = C.Descriptor(p).configFingerprint
    assertTrue(select(1, C.SetRequestedGoal(p, admin, aqirite, 200)), "changing the goal bumps config")
    assertTrue(C.Descriptor(p).configFingerprint ~= beforeFp, "goal changes participate in config fingerprints")

    C.AddRequestedItem(p, admin, flask)
    C.AddRequestedItem(p, admin, aqiriteRank2)
    C.AddRequestedItem(p, admin, junk)
    C.SetRequestedGoal(p, admin, flask, 50)
    C.SetRequestedGoal(p, admin, aqiriteRank2, 100)
    C.SetRequestedGoal(p, admin, junk, 0)

    C.CommitEvents(p, "goal-a", W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 100))
    -- flask stays at 0 donations.
    C.CommitEvents(p, "goal-c", W.DepositEvents({ generation = 1, itemId = aqiriteRank2, donor = donor, requested = true }, 110))
    C.CommitEvents(p, "goal-d", W.DepositEvents({ generation = 1, itemId = junk, donor = donor, requested = true }, 300))

    assertEq(C.ItemDonatedTotal(p, aqirite), 100, "item totals use raw donation quantities")
    assertEq(C.ItemDonatedTotal(p, flask), 0, "an item with no donations has total 0")
    assertEq(C.ItemDonatedTotal(p, aqiriteRank2), 110, "over-complete donations stay in the raw total")
    assertEq(C.ItemDonatedTotal(p, junk), 300, "goal-0 items still accumulate raw totals")

    local progress = C.GoalProgress(p)
    assertTrue(progress.hasPositiveGoal, "positive goals enable overall progress")
    assertEq(progress.overallPercent, 57, "overall progress caps over-donations and excludes goal 0")
    local byId = {}
    for i = 1, #progress.items do
        byId[progress.items[i].itemId] = progress.items[i]
    end
    assertEq(byId[aqirite].percent, 50, "item A is 50%")
    assertEq(byId[flask].percent, 0, "item B is 0%")
    assertEq(byId[aqiriteRank2].percent, 110, "item C may exceed 100%")
    assertTrue(byId[junk].noGoal, "item D reports No Goal")
    assertEq(byId[junk].percent, nil, "No Goal items have no percentage")

    local onlyZero = configured("goals-zero")
    C.AddRequestedItem(onlyZero, admin, flask)
    C.SetRequestedGoal(onlyZero, admin, aqirite, 0)
    C.SetRequestedGoal(onlyZero, admin, flask, 0)
    C.CommitEvents(onlyZero, "zero-donations",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 40))
    local emptyOverall = C.GoalProgress(onlyZero)
    assertFalse(emptyOverall.hasPositiveGoal, "all goal-0 items produce no overall bar")
    assertEq(emptyOverall.overallPercent, nil, "no overall percent when no positive goals exist")
    assertEq(emptyOverall.overallEmptyText, "No goals configured.", "empty overall uses the No goals text")
    assertEq(#emptyOverall.items, 2, "goal-0 items still appear in the per-item summary")

    -- Changing 0 -> positive immediately uses existing current-generation donations.
    assertTrue(select(1, C.SetRequestedGoal(onlyZero, admin, aqirite, 80)), "goal 0 can become positive")
    local afterGoal = C.GoalProgress(onlyZero)
    assertEq(afterGoal.items[1].percent or afterGoal.items[2].percent, 50,
        "existing donations count immediately toward a newly set positive goal")
    local aqRow = nil
    for i = 1, #afterGoal.items do
        if afterGoal.items[i].itemId == aqirite then aqRow = afterGoal.items[i] end
    end
    assertEq(aqRow.percent, 50, "40 of 80 is 50%")

    -- Remove / re-add within the same generation restores counting.
    local rr = configured("goals-readd")
    C.SetRequestedGoal(rr, admin, aqirite, 40)
    C.CommitEvents(rr, "readd-1",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 25))
    assertEq(C.GoalProgress(rr).items[1].percent, 62, "25 of 40 floors to 62%")
    C.RemoveRequestedItem(rr, admin, aqirite)
    assertEq(#C.GoalProgress(rr).items, 0, "removed items leave the progress display")
    assertEq(C.ItemDonatedTotal(rr, aqirite), 25, "removing an item does not delete donation events")
    C.AddRequestedItem(rr, admin, aqirite)
    C.SetRequestedGoal(rr, admin, aqirite, 40)
    assertEq(C.GoalProgress(rr).items[1].percent, 62, "re-adding in the same generation restores progress")

    -- Clear / new generation resets progress while keeping history.
    C.Clear(rr, admin)
    assertEq(C.ItemDonatedTotal(rr, aqirite), 0, "a new generation resets item totals")
    assertEq(#C.GoalProgress(rr).items, 0, "clear removes requested items from progress")
    local historyAfterClear = C.HistoryRows(rr)
    local preservedDonation = false
    for i = 1, #historyAfterClear do
        if contains(historyAfterClear[i].text, "donated 25") then
            preservedDonation = true
            break
        end
    end
    assertTrue(preservedDonation, "clear preserves the prior donation in historical ledger")

    -- Linked characters: two donations each count once toward item totals.
    local linked = configured("goals-linked")
    local alt = "Alt-Realm"
    linked.GetIdentityMembers = function(_, memberId)
        if memberId == donor or memberId == alt then
            return { donor, alt }
        end
        return { memberId }
    end
    C.SetRequestedGoal(linked, admin, aqirite, 100)
    C.CommitEvents(linked, "link-donor",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 25))
    C.CommitEvents(linked, "link-alt",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = alt, requested = true }, 25))
    assertEq(C.ItemDonatedTotal(linked, aqirite), 50, "linked characters each contribute fully to item totals")
    assertEq(C.ContributionTotal(linked, donor, aqirite), 50, "identity-aware member totals still group")
    assertEq(C.GoalProgress(linked).items[1].percent, 50, "goal progress uses raw item totals, not member totals")
    local beforeLinkFp = C.ItemDonatedTotal(linked, aqirite)
    linked.GetIdentityMembers = function(_, memberId) return { memberId } end
    assertEq(C.ItemDonatedTotal(linked, aqirite), beforeLinkFp, "unlinking does not change item totals")
    assertEq(C.GoalProgress(linked).items[1].percent, 50, "unlinking does not change goal progress")
    linked.GetIdentityMembers = function(_, memberId)
        if memberId == donor or memberId == alt then return { donor, alt } end
        return { memberId }
    end
    assertEq(C.ItemDonatedTotal(linked, aqirite), 50, "relinking does not change item totals")

    -- Snapshot / config / profile-copy round trips preserve goals.
    local source = configured("goals-snap-src")
    C.SetRequestedGoal(source, admin, aqirite, 75)
    C.AddRequestedItem(source, admin, flask)
    C.SetRequestedGoal(source, admin, flask, 0)
    local snap = C.ExportSnapshot(source, { omitEvents = true })
    assertEq(snap.requestedItems[tostring(aqirite)].goal, 75, "snapshots export goals")
    assertEq(snap.requestedItems[tostring(flask)].goal, 0, "snapshots export goal 0")
    assertTrue(select(1, C.ValidateSnapshot(snap)), "goal-bearing snapshots validate")
    local badSnap = {
        generation = 1, configSeq = 1, requestedItems = {
            [tostring(aqirite)] = { itemId = aqirite, goal = -3 },
        },
    }
    assertFalse(select(1, C.ValidateSnapshot(badSnap)), "explicit malformed goals fail validation")
    local dest = profile("goals-snap-dst", admin)
    assertTrue(select(1, C.ReplaceConfig(dest, snap)), "ReplaceConfig accepts goal-bearing config")
    assertEq(dest._consumables.requestedItems[tostring(aqirite)].goal, 75, "ReplaceConfig restores goals")
    assertFalse(select(1, C.ReplaceConfig(dest, badSnap)), "ReplaceConfig rejects malformed goals")
    assertEq(dest._consumables.requestedItems[tostring(aqirite)].goal, 75, "rejected replace leaves prior goals")

    local follower = profile("goals-follow", admin)
    assertEq(select(2, S.ApplyRemoteConfig(follower, snap, admin, { coordinatorAuthoritative = true })),
        "applied", "remote config applies goals")
    assertEq(follower._consumables.requestedItems[tostring(aqirite)].goal, 75, "follower receives goals")
    assertEq(C.Descriptor(follower).configFingerprint, C.Descriptor(source).configFingerprint,
        "goal-aware fingerprints converge")

    -- Sequential non-authoritative catch-up for a goal mutation.
    local stepSrc = profile("goals-step-src", admin)
    local stepDst = profile("goals-step-dst", admin)
    C.SetGuild(stepSrc, admin, GUILD, 2)
    assertEq(select(2, S.ApplyRemoteConfig(stepDst, C.ExportSnapshot(stepSrc, { omitEvents = true }), admin)),
        "applied", "follower applies guild configuration")
    C.AddRequestedItem(stepSrc, admin, aqirite)
    assertEq(select(2, S.ApplyRemoteConfig(stepDst, C.ExportSnapshot(stepSrc, { omitEvents = true }), admin)),
        "applied", "follower applies the add_item step")
    C.SetRequestedGoal(stepSrc, admin, aqirite, 33)
    assertEq(select(2, S.ApplyRemoteConfig(stepDst, C.ExportSnapshot(stepSrc, { omitEvents = true }), admin)),
        "applied", "follower applies a goal change as the next config step")
    assertEq(stepDst._consumables.requestedItems[tostring(aqirite)].goal, 33, "stepped sync delivers the goal")
    assertEq(C.Descriptor(stepDst).configFingerprint, C.Descriptor(stepSrc).configFingerprint,
        "stepped goal sync fingerprints converge")

    local copyDest = profile("goals-copy-dst", admin)
    C.CopyConfiguration(source, copyDest)
    assertEq(copyDest._consumables.requestedItems[tostring(aqirite)].goal, 75, "profile copy preserves goals")
    assertEq(copyDest._consumables.requestedItems[tostring(flask)].goal, 0, "profile copy preserves goal 0")
    assertEq(C.ItemDonatedTotal(copyDest, aqirite), 0, "profile copy starts with zero progress")

    -- Multiple raw actors to the same item.
    local multi = configured("goals-multi")
    C.SetRequestedGoal(multi, admin, aqirite, 60)
    C.CommitEvents(multi, "multi-1",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = donor, requested = true }, 10))
    C.CommitEvents(multi, "multi-2",
        W.DepositEvents({ generation = 1, itemId = aqirite, donor = vann, requested = true }, 15))
    assertEq(C.ItemDonatedTotal(multi, aqirite), 25, "multiple actors each add once to item totals")
    assertEq(C.Project(multi).contributions[donor][aqirite], 10, "raw actor contributions stay separate")
    assertEq(C.Project(multi).contributions[vann][aqirite], 15, "raw actor contributions stay separate for each actor")
end

local function checkGoalCommitGate()
    load("SpectrumFederation/modules/UI/Settings/Control/Controls.lua")
    local should = SF.SettingsUI.Controls.ShouldCommitConsumableGoal
    assertTrue(type(should) == "function", "goal commit gate is exported for regression coverage")
    assertTrue(should({ boundItemId = aqirite, lastCommittedText = "0" }, "10", aqirite),
        "a changed goal text is eligible to commit")
    assertFalse(should({ boundItemId = aqirite, lastCommittedText = "10" }, "10", aqirite),
        "an unchanged goal text does not commit again")
    assertFalse(should({ boundItemId = aqirite, lastCommittedText = "0", ignore = true }, "10", aqirite),
        "ignored refresh updates do not commit")
    assertFalse(should({ boundItemId = aqirite, lastCommittedText = "0", cancel = true }, "10", aqirite),
        "cancelled rebound edits do not commit")
    assertFalse(should({ boundItemId = aqirite, lastCommittedText = "0" }, "10", flask),
        "text bound to a different item id does not commit")
    assertFalse(should({ boundItemId = aqirite, lastCommittedText = "0" }, "10", nil),
        "a missing commit item id does not commit")

    local maxWidth, reserved = SF.SettingsUI.Controls.ConsumableRequestedTextMaxWidth(300)
    assertTrue(type(reserved) == "number" and reserved > 0, "requested-list reserved width is exported")
    assertEq(maxWidth, 300 - reserved, "requested-list text max width subtracts reserved controls")
    assertEq(
        table.concat(SF.SettingsUI.Controls.CONSUMABLE_REQUESTED_CONTROL_ORDER, ","),
        "text,goalLabel,goalEdit,remove",
        "requested-list control order is Name → Goal → Input → Remove"
    )
    local effectiveGap, visualGap, inputInset = SF.SettingsUI.Controls.ConsumableRequestedGoalEditGap()
    assertEq(visualGap, 8, "Goal→input visual gap targets about 8px")
    assertTrue(inputInset > 0, "Goal→input gap includes InputBoxTemplate left inset")
    assertEq(effectiveGap, visualGap + inputInset, "effective Goal→input gap combines visual and inset")
    assertEq(
        SF.SettingsUI.Controls.ConsumableRequestedNameColumnWidth(300, 80),
        84,
        "shared name column uses longest string width plus padding when it fits"
    )
    assertEq(
        SF.SettingsUI.Controls.ConsumableRequestedNameColumnWidth(100, 500),
        SF.SettingsUI.Controls.ConsumableRequestedTextMaxWidth(100),
        "shared name column clamps to the reserved max when labels are too long"
    )
end

local function checkSessionProfileNoticeRemoved()
    resetWorld()
    local active = profile("active-profile", admin)
    local session = profile("session-profile", admin)
    world.activeProfile = active
    SF.lootHelperDB.profiles[active._profileId] = active
    SF.lootHelperDB.profiles[session._profileId] = session
    Sync.state = {
        active = true,
        sessionId = "SES-NOTICE",
        profileId = session._profileId,
    }
    world.infos = {}
    world.warnings = {}
    local resolved = RT:AccountingProfile()
    assertEq(resolved, session, "accounting uses the session profile when it differs from active")
    for i = 1, #world.infos do
        assertFalse(
            contains(world.infos[i], "recorded on the session profile"),
            "session-profile notice is not printed to chat"
        )
    end
    -- Feature still resolves the session profile on a second call.
    assertEq(RT:AccountingProfile(), session, "accounting still resolves the session profile without chat notice")
end

local function checkFocusedEditRowReuse()
    local p = runtimeFixture("rt-focused-row-reuse")
    assertTrue(select(1, C.AddRequestedItem(p, admin, flask)), "fixture requests a second item")
    world.bags[0] = {
        [1] = { itemId = aqirite, count = 10 },
        [2] = { itemId = flask, count = 8 },
    }
    world.bags[5] = {}
    world.bankOpen = true
    RT:OnBankOpened()
    local review = RT.review
    assertTrue(review ~= nil and review:IsShown(), "helper opens with two requested items")
    local aqRow = review.Rows[2]
    assertEq(aqRow.boundItemId, aqirite, "first data row binds aqirite")
    assertEq(aqRow.Edit.text, "10", "aqirite starts with its suggested quantity")
    aqRow.Edit:SetText("9")
    aqRow.Edit:SetFocus()
    assertTrue(aqRow.Edit:HasFocus(), "quantity edit is focused before the list changes")

    -- Same item rebuild preserves the in-progress edit.
    RT:RebuildReview()
    aqRow = review.Rows[2]
    assertEq(aqRow.boundItemId, aqirite, "same-item rebuild keeps the row binding")
    assertEq(aqRow.Edit.text, "9", "focused same-item edits survive RebuildReview")
    assertTrue(aqRow.Edit:HasFocus(), "same-item rebuild leaves focus intact")

    -- Removing the focused item rebinds the pooled row to flask.
    assertTrue(select(1, C.RemoveRequestedItem(p, admin, aqirite)), "removing aqirite changes the donation list")
    RT:RebuildReview()
    local flaskRow = review.Rows[2]
    assertEq(flaskRow.boundItemId, flask, "pooled row rebinds to the remaining requested item")
    assertFalse(flaskRow.Edit:HasFocus(), "stale focus is cleared when the row changes items")
    assertEq(flaskRow.Edit.text, "8", "rebound row shows the new item's suggested quantity")

    flaskRow.Button.scripts.OnClick(flaskRow.Button)
    assertEq(RT.qtyOverrides[flask], 8, "Deposit uses the rebound item's quantity, not the stale edit")
    assertEq(RT.qtyOverrides[aqirite], nil, "stale aqirite override is not applied after rebinding")
    assertTrue(RT.depositWork ~= nil or RT.depositIntent ~= nil or #world.places > 0,
        "Deposit starts for the rebound item")
    if RT.depositWork then
        assertEq(RT.depositWork.line.itemId, flask, "deposit work targets the rebound item")
        assertEq(RT.depositWork.intended, 8, "deposit work uses the new suggestion, not the stale 9")
    end
    RT:CancelDepositWork()
    RT.depositIntent = nil
    world.places = {}
    unchanged(p, "focused edit row reuse")
end

local function checkSmartDonationHelper()
    local p = runtimeFixture("rt-smart-donation")
    C.AddRequestedItem(p, admin, flask)
    C.SetRequestedGoal(p, admin, aqirite, 200)
    C.SetRequestedGoal(p, admin, flask, 0)
    C.CommitEvents(p, "smart-donated", W.DepositEvents({
        generation = 1, itemId = aqirite, donor = donor, requested = true,
    }, 175))
    world.bags[0][1] = { itemId = aqirite, count = 40 }
    world.bags[0][2] = { itemId = aqirite, count = 10 }
    world.bags[0][3] = { itemId = flask, count = 12 }
    world.bags[5] = {}
    world.bankOpen = true
    GuildBankFrame.height = 450
    RT:OnBankOpened()
    local review = RT.review
    assertTrue(review ~= nil and review:IsShown(), "smart helper auto-opens with mixed goals")
    local reviewWidth = review:GetWidth()
    assertTrue(reviewWidth >= REVIEW_COMPACT_WIDTH_MIN and reviewWidth <= REVIEW_COMPACT_WIDTH_MAX,
        "donation helper uses a compact width near half of 480")
    assertTrue(reviewWidth < 480, "donation helper is narrower than the previous 480 width")
    assertTrue(review.Child ~= nil and review.Child:GetWidth() > 0
            and review.Child:GetWidth() < reviewWidth,
        "scroll child is narrower than the compact helper frame")
    assertTrue(review.anchor and review.anchor.relative == GuildBankFrame,
        "opening aligns the helper to the Guild Bank")
    assertEq(review.anchor.point, "TOPLEFT", "helper top aligns beside the Guild Bank")
    assertEq(review.anchor.relativePoint, "TOPRIGHT", "helper sits alongside the Guild Bank")
    assertEq(review.anchor.y, 0, "helper top edge stays level with the Guild Bank")
    assertTrue(review.anchor.x ~= nil and review.anchor.x > GUILD_BANK_SIDE_TAB_VISIBLE_EXTENT,
        "helper clears the Guild Bank side-tab decorative overhang")
    assertTrue(review.anchor.x >= GUILD_BANK_SIDE_TAB_VISIBLE_EXTENT + 8
            and review.anchor.x <= GUILD_BANK_SIDE_TAB_VISIBLE_EXTENT + 12,
        "helper leaves about 8-10 UI units after the visible side-tab art")
    assertTrue(GUILD_BANK_SIDE_TAB_TEXTURE_WIDTH > GUILD_BANK_SIDE_TAB_FRAME_WIDTH,
        "side-tab mock reflects decorative texture wider than the clickable frame")
    assertEq(review:GetHeight(), 450, "helper height matches the Guild Bank")
    assertTrue(review.ProgressBar:IsShown(), "positive goals show the overall progress bar")
    assertEq(review.ProgressBar.Text.text, "87%", "overall progress uses GoalProgress (175/200)")
    assertFalse(review.ProgressEmpty:IsShown(), "positive goals hide the empty overall state")

    local aqRow, flaskRow
    for i = 1, #review.Rows do
        local row = review.Rows[i]
        if row:IsShown() and row.IconButton and row.IconButton:IsShown() then
            if row.Icon.texture == "Interface\\Icons\\Item190000" then aqRow = row end
            if row.Icon.texture == "Interface\\Icons\\Item" .. tostring(flask) then flaskRow = row end
        end
    end
    assertTrue(aqRow ~= nil, "finite-goal item row is shown")
    assertTrue(flaskRow ~= nil, "goal-0 item row is shown")
    assertTrue(aqRow:GetWidth() > 0 and aqRow:GetWidth() <= review.Child:GetWidth(),
        "item rows fit inside the compact scroll child")
    local rowControlsWidth = (aqRow.IconButton and aqRow.IconButton:GetWidth() or 0)
        + (aqRow.Progress and aqRow.Progress:GetWidth() or 0)
        + (aqRow.Edit and aqRow.Edit:GetWidth() or 0)
        + (aqRow.Button and aqRow.Button:GetWidth() or 0)
    assertTrue(rowControlsWidth > 0 and rowControlsWidth <= aqRow:GetWidth(),
        "icon, progress, qty, and Deposit fit inside the compact row width")
    assertEq(aqRow.Progress.text, "87%", "finite-goal row shows the floor percent")
    assertEq(aqRow.Edit.text, "25", "finite-goal suggestion is min(available, remaining)")
    assertTrue(aqRow.Button:IsShown(), "incomplete finite goals keep Deposit")
    assertEq(flaskRow.Progress.text, "No Goal", "goal-0 row shows No Goal")
    assertEq(flaskRow.Edit.text, "12", "goal-0 suggestion uses carried quantity")
    assertTrue(flaskRow.Button:IsShown(), "goal-0 items remain depositable")

    -- Manual over-donation while incomplete is allowed; inventory still clamps.
    aqRow.Edit:SetText("40")
    aqRow.Edit.scripts.OnEnterPressed(aqRow.Edit)
    assertEq(RT.qtyOverrides[aqirite], 40, "manual quantity above remaining goal is kept")
    aqRow = nil
    for i = 1, #review.Rows do
        local row = review.Rows[i]
        if row:IsShown() and row.Icon and row.Icon.texture == "Interface\\Icons\\Item190000" then
            aqRow = row
        end
    end
    assertEq(aqRow.Edit.text, "40", "rebuild preserves the visit override")
    aqRow.Edit:SetText("999")
    aqRow.Edit.scripts.OnEnterPressed(aqRow.Edit)
    assertEq(RT.qtyOverrides[aqirite], 50, "manual quantity above inventory clamps to available")

    -- Active edit is not overwritten by ordinary rebuilds.
    aqRow.Edit:SetText("33")
    aqRow.Edit:SetFocus()
    RT:RebuildReview()
    for i = 1, #review.Rows do
        local row = review.Rows[i]
        if row:IsShown() and row.Icon and row.Icon.texture == "Interface\\Icons\\Item190000" then
            aqRow = row
        end
    end
    assertEq(aqRow.Edit.text, "33", "focused quantity edits survive RebuildReview")
    aqRow.Edit:ClearFocus()
    aqRow.Edit.scripts.OnEnterPressed(aqRow.Edit)
    assertEq(RT.qtyOverrides[aqirite], 33, "leaving the edit commits the visit override")

    -- Tab switch must not clear overrides; bank close must.
    local kept = RT.qtyOverrides[aqirite]
    world.currentTab = 1
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertFalse(review:IsShown(), "leaving the configured tab hides the helper")
    assertEq(RT.qtyOverrides[aqirite], kept, "tab switch does not clear quantity overrides")
    world.currentTab = 2
    RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertTrue(review:IsShown(), "returning to the configured tab reopens the helper")
    assertEq(RT.qtyOverrides[aqirite], kept, "overrides survive configured-tab return")

    -- Successful deposit does not specially reset overrides.
    for i = 1, #review.Rows do
        local row = review.Rows[i]
        if row:IsShown() and row.Icon and row.Icon.texture == "Interface\\Icons\\Item190000" then
            aqRow = row
        end
    end
    aqRow.Button.scripts.OnClick(aqRow.Button)
    assertEq(RT.qtyOverrides[aqirite], 33, "starting a deposit does not clear the visit override")
    RT:CancelDepositWork()
    RT.depositIntent = nil
    world.places = {}

    -- Duplicate open while already open must not wipe overrides.
    RT:OnBankOpened()
    assertEq(RT.qtyOverrides[aqirite], 33, "duplicate Guild Bank open keeps visit overrides")

    -- Manual drag is preserved while visible; height still follows the bank.
    review:ClearAllPoints()
    review:SetPoint("CENTER", UIParent, "CENTER", 10, 20)
    GuildBankFrame.height = 500
    if GuildBankFrame.hooks.OnSizeChanged then
        for i = 1, #GuildBankFrame.hooks.OnSizeChanged do
            GuildBankFrame.hooks.OnSizeChanged[i]()
        end
    end
    assertEq(review:GetHeight(), 500, "Guild Bank height changes update the helper height")
    assertEq(review.anchor.point, "CENTER", "height updates do not snap a dragged helper")

    RT:OnBankClosed()
    assertEq(RT.qtyOverrides[aqirite], nil, "closing the Guild Bank clears quantity overrides")
    assertFalse(review:IsShown(), "closing the Guild Bank hides the helper")

    -- Reopen: fresh suggestions from current progress/inventory; realign.
    world.bags[0][1] = { itemId = aqirite, count = 40 }
    world.bags[0][2] = { itemId = aqirite, count = 10 }
    world.bankOpen = true
    GuildBankFrame.height = 430
    RT:OnBankOpened()
    assertTrue(review:IsShown(), "reopening can show the helper again")
    assertEq(RT.qtyOverrides[aqirite], nil, "a new visit starts without prior overrides")
    assertEq(review.anchor.point, "TOPLEFT", "reopening restores Guild Bank alignment")
    assertEq(review.anchor.relativePoint, "TOPRIGHT", "reopening restores side-of-bank anchoring")
    assertTrue(review.anchor.x ~= nil and review.anchor.x > GUILD_BANK_SIDE_TAB_VISIBLE_EXTENT,
        "reopening still clears the Guild Bank side-tab decorative overhang")
    assertEq(review:GetHeight(), 430, "reopening matches the current Guild Bank height")
    for i = 1, #review.Rows do
        local row = review.Rows[i]
        if row:IsShown() and row.Icon and row.Icon.texture == "Interface\\Icons\\Item190000" then
            aqRow = row
        end
    end
    assertEq(aqRow.Edit.text, "25", "reopen suggests remaining need from current progress")

    -- Completed finite goal: visible percent, no deposit controls; helper still auto-opens.
    C.CommitEvents(p, "smart-complete", W.DepositEvents({
        generation = 1, itemId = aqirite, donor = donor, requested = true,
    }, 30))
    world.bags[0][3] = nil
    RT:OnBankClosed()
    world.bankOpen = false
    world.bags[0][1] = { itemId = aqirite, count = 8 }
    world.bags[0][2] = nil
    world.bankOpen = true
    RT:OnBankOpened()
    assertTrue(review:IsShown(), "helper still auto-opens when only completed goals are carried")
    aqRow = nil
    for i = 1, #review.Rows do
        local row = review.Rows[i]
        if row:IsShown() and row.Icon and row.Icon.texture == "Interface\\Icons\\Item190000" then
            aqRow = row
        end
    end
    assertTrue(aqRow ~= nil, "completed-goal items remain listed when carried")
    assertEq(aqRow.Progress.text, "102%", "completed goals show percents above 100")
    assertFalse(aqRow.Edit:IsShown(), "completed goals hide the quantity field")
    assertFalse(aqRow.Button:IsShown(), "completed goals hide Deposit")
    assertEq(review.ProgressBar.Text.text, "100%", "overall progress caps the completed item at its goal")

    -- Stale completed-goal deposit callback must not start work.
    local staleLine = {
        itemId = aqirite,
        quantity = 5,
        generation = p._consumables.generation,
        guildBank = true,
    }
    local collected = RT:Collect()
    RT:BeginDeposit(staleLine, collected)
    assertEq(RT.depositWork, nil, "completed goals reject BeginDeposit")
    assertEq(RT.depositIntent, nil, "completed goals create no deposit intent")
    assertTrue(#world.warnings > 0, "completed-goal deposit warns the player")

    -- Progress update while open: incomplete → complete hides controls.
    C.SetRequestedGoal(p, admin, aqirite, 300)
    RT:RebuildReview()
    for i = 1, #review.Rows do
        local row = review.Rows[i]
        if row:IsShown() and row.Icon and row.Icon.texture == "Interface\\Icons\\Item190000" then
            aqRow = row
        end
    end
    assertTrue(aqRow.Edit:IsShown(), "raising the goal restores deposit controls")
    assertEq(aqRow.Edit.text, "8", "updated suggestion uses remaining need and bags")
    assertEq(aqRow.Progress.text, "68%", "progress updates while the helper is open")

    -- Bounded lifecycle with the new Guild Bank size hook.
    local frames = frameCount
    local afterN = #world.after
    local timersN = #liveTimers()
    for _ = 1, 30 do
        world.currentTab = 2
        world.bankOpen = true
        RT:OnBankOpened()
        world.currentTab = 1
        RT:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
        RT:OnBankClosed()
        world.bankOpen = false
    end
    assertEq(frameCount, frames, "smart helper lifecycle allocates no new frames")
    assertEq(#world.after, afterN, "smart helper lifecycle schedules no deferred work")
    assertEq(#liveTimers(), timersN, "smart helper lifecycle creates no live timers")
    unchanged(p, "smart donation helper")
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
checkManualAdjustments()
checkCatchUpRules()
checkSessionTransport()
checkPeerHistoryRecoveryServePath()
checkQueuedResendProtection()
checkRuntimeInventory()
checkRuntimeReminder()
checkRuntimeBannerBankNavigation()
checkRuntimeReminderLifecycleAttach()
checkRuntimeMobileSpellDetection()
checkRuntimeReview()
checkRuntimeReviewGuildBankLifecycle()
checkRuntimeReviewDepositTabSwitch()
checkRuntimeDeposit()
checkStaleDepositReview()
checkOccupiedDepositCursor()
checkRuntimeDepositPartialAndFailure()
checkRuntimeCancelAndDeferredDelete()
checkClear()
checkCopyConfiguration()
checkGoalsAndProgress()
checkGoalCommitGate()
checkSessionProfileNoticeRemoved()
checkFocusedEditRowReuse()
checkSmartDonationHelper()

if failures > 0 then
    io.stderr:write(string.format("%d failed, %d passed\n", failures, passes))
    os.exit(1)
end
io.stdout:write(string.format("%d passed, 0 failed\n", passes))
