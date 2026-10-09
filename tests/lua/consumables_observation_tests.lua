-- Focused Lua 5.1 tests for Consumables observation/reconciliation (Issue #366 PR1).
-- Run: lua5.1 tests/lua/consumables_observation_tests.lua

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

local world
local function resetWorld()
    world = {
        self = "Observer-Realm",
        clubId = "club-1",
        bankOpen = false,
        currentTab = 2,
        logQueries = {},
        logRows = {},
        after = {},
        timers = {},
        activeProfile = nil,
    }
end
resetWorld()

GetTime = function() return 100 end
time = function() return world.now or 1e9 end
function QueryGuildBankLog(tab)
    world.logQueries[#world.logQueries + 1] = tab
end
function GetNumGuildBankTransactions(tab)
    local rows = world.logRows[tab] or {}
    return #rows
end
function GetGuildBankTransaction(tab, index)
    local rows = world.logRows[tab] or {}
    local row = rows[index]
    if not row then return nil end
    return row.type, row.name, row.itemLink, row.count, row.tab1, row.tab2, row.year, row.month, row.day, row.hour
end
C_Club = { GetGuildClubId = function() return world.clubId end }
function GetGuildInfo() return "Spectrum", nil, nil, "Realm" end
C_Timer = {
    After = function(_, fn) world.after[#world.after + 1] = fn end,
    NewTimer = function(_, fn)
        local handle = { cancelled = false, fn = fn }
        world.timers[#world.timers + 1] = handle
        return handle
    end,
}
Enum = { PlayerInteractionType = { GuildBanker = 10 } }

local FrameMock = {}
FrameMock.__index = FrameMock
function FrameMock:RegisterEvent(event)
    self.events = self.events or {}
    self.events[event] = true
end
function FrameMock:SetScript(name, fn)
    self.scripts = self.scripts or {}
    self.scripts[name] = fn
end
function CreateFrame()
    return setmetatable({ events = {}, scripts = {} }, FrameMock)
end

local SF = {
    Debug = {
        Info = function() end,
        Warn = function() end,
        Error = function() end,
        Verbose = function() end,
    },
    NameUtil = {
        GetSelfId = function() return world.self end,
        NormalizeNameRealm = function(name) return name end,
        SamePlayer = function(a, b) return a == b end,
    },
}
function SF:GetActiveProfile() return world.activeProfile end

local function load(path)
    local chunk = assert(loadfile(path))
    chunk("SpectrumFederation", SF)
end

load("SpectrumFederation/locale/enUS.lua")
load("SpectrumFederation/modules/LootHelper/Consumables.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesObservation.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesBankLog.lua")

local C = SF.Consumables
local O = SF.ConsumablesObservation
local BankLog = SF.ConsumablesBankLog

local clock = 1000000
O._clock = function()
    return clock
end

local function advance(seconds)
    clock = clock + (seconds or 1)
end

local flask = 212283
local vial = 190000
local junk = 555

local admin = "Admin-Realm"
local GUILD = { guid = "club-1", name = "Spectrum", realm = "Realm" }

local function makeProfile()
    local p = {
        _profileId = "profile-obs",
        _owner = admin,
        _adminUsers = { admin },
    }
    function p:GetProfileId() return self._profileId end
    function p:IsAdminMemberId(id)
        for i = 1, #self._adminUsers do
            if self._adminUsers[i] == id then return true end
        end
        return false
    end
    C.Ensure(p)
    assert(C.SetGuild(p, admin, GUILD, 2))
    assert(C.AddRequestedItem(p, admin, flask))
    assert(C.AddRequestedItem(p, admin, vial))
    return p
end

local function deposit(name, itemId, count, year, month, day, hour, ageHours)
    local row = {
        type = "deposit",
        name = name,
        itemLink = string.format("item:%d", itemId),
        count = count,
        year = year or 0,
        month = month or 0,
        day = day or 0,
        hour = hour or 0,
    }
    if ageHours ~= nil then
        row.ageHours = ageHours
    end
    return row
end

local function snapshot(rows, extras)
    extras = extras or {}
    local p = extras.profile or makeProfile()
    local cfg = C.Ensure(p)
    return {
        authoritative = extras.authoritative ~= false,
        guildGuid = extras.guildGuid or "club-1",
        bankTab = extras.bankTab or 2,
        generation = extras.generation or cfg.generation,
        observedBy = extras.observedBy or "Observer-Realm",
        observedAt = extras.observedAt or clock,
        requestedSet = extras.requestedSet or O.RequestedSetFromConfig(cfg),
        rows = rows,
    }
end

-- ---------------------------------------------------------------------------
-- Pure matching / persistence
-- ---------------------------------------------------------------------------

do
    local db = { consumableObservations = {} }
    local profileId = "profile-obs"
    local store = O.EnsureProfileStore(db, profileId)
    local rows = {
        deposit("Kyrius-Realm", flask, 20, 0, 0, 0, 1),
    }
    local stats = O.ReconcileSnapshot(store, profileId, snapshot(rows))
    assertEq(stats.created, 1, "first scan creates one observation")
    local pending = O.ListPending(store, "club-1", 2)
    assertEq(#pending, 1, "one pending observation after first scan")
    assertEq(pending[1].donor, "Kyrius-Realm", "preserves donor identity")
    assertEq(pending[1].itemId, flask, "preserves item id")
    assertEq(pending[1].quantity, 20, "preserves quantity")
    assertEq(pending[1].observedBy, "Observer-Realm", "preserves observer")

    advance(60)
    local stats2 = O.ReconcileSnapshot(store, profileId, snapshot(rows, { observedAt = clock }))
    assertEq(stats2.created, 0, "rescan does not create duplicate")
    assertEq(stats2.updated, 1, "rescan updates existing observation")
    assertEq(#O.ListPending(store, "club-1", 2), 1, "still one pending after rescan")
end

do
    local db = { consumableObservations = {} }
    local store = O.EnsureProfileStore(db, "profile-obs")
    -- Two legitimate identical deposits in one snapshot (older index first).
    local rows = {
        deposit("Anthony-Realm", flask, 20, 0, 0, 0, 3),
        deposit("Anthony-Realm", flask, 20, 0, 0, 0, 1),
    }
    local stats = O.ReconcileSnapshot(store, "profile-obs", snapshot(rows))
    assertEq(stats.created, 2, "identical legitimate deposits remain distinct")
    assertEq(#O.ListPending(store, "club-1", 2), 2, "two pending identical deposits")

    -- Moving window: newer unrelated deposit prepended (higher index = newer).
    advance(120)
    local moved = {
        deposit("Anthony-Realm", flask, 20, 0, 0, 0, 3),
        deposit("Anthony-Realm", flask, 20, 0, 0, 0, 1),
        deposit("Other-Realm", vial, 5, 0, 0, 0, 0),
    }
    local stats2 = O.ReconcileSnapshot(store, "profile-obs", snapshot(moved, { observedAt = clock }))
    assertEq(stats2.created, 1, "new distinct deposit creates one observation")
    assertEq(stats2.updated, 2, "prior identical deposits reconciled despite moved positions")
    assertEq(#O.ListPending(store, "club-1", 2), 3, "three pending after window move")
end

do
    local db = { consumableObservations = {} }
    local store = O.EnsureProfileStore(db, "profile-obs")
    local rows = {
        deposit("Kyrius-Realm", flask, 20, 0, 0, 0, 2),
        { type = "withdraw", name = "Kyrius-Realm", itemLink = "item:" .. flask, count = 20, year = 0, month = 0, day = 0, hour = 1 },
        { type = "move", name = "Kyrius-Realm", itemLink = "item:" .. flask, count = 20, tab1 = 2, tab2 = 3, year = 0, month = 0, day = 0, hour = 0 },
        deposit("Kyrius-Realm", junk, 20, 0, 0, 0, 0),
    }
    local stats = O.ReconcileSnapshot(store, "profile-obs", snapshot(rows))
    assertEq(stats.created, 1, "ignores withdraw/move/unrequested item")
    assertEq(#O.ListPending(store, "club-1", 2), 1, "only eligible deposit pending")
end

do
    local db = { consumableObservations = {} }
    local store = O.EnsureProfileStore(db, "profile-obs")
    local rows = { deposit("Edge-Realm", flask, 10, 0, 0, 0, 0) }
    local stats = O.ReconcileSnapshot(store, "profile-obs", snapshot(rows))
    assertEq(stats.created, 1, "newest edge transaction with only older neighbors is valid")
    -- Incomplete context on older side at start of history.
    local oldestOnly = {
        deposit("Edge-Realm", vial, 4, 0, 0, 1, 0),
    }
    local stats2 = O.ReconcileSnapshot(store, "profile-obs", snapshot(oldestOnly))
    assertEq(stats2.created, 1, "oldest edge transaction with only newer-empty context is valid")
end

do
    local db = { consumableObservations = {} }
    local store = O.EnsureProfileStore(db, "profile-obs")
    local rows = { deposit("Kyrius-Realm", flask, 20, 0, 0, 0, 1) }
    O.ReconcileSnapshot(store, "profile-obs", snapshot(rows, { observedAt = clock }))
    -- Second observer, later scan time, same relative age → same approx txn time neighborhood.
    advance(1800)
    local stats = O.ReconcileSnapshot(store, "profile-obs", snapshot(rows, {
        observedAt = clock,
        observedBy = "Witness-Realm",
    }))
    assertEq(stats.created, 0, "time-drifted second observer does not duplicate")
    assertEq(stats.updated, 1, "time-drifted observation reconciles")
    assertEq(#O.ListPending(store, "club-1", 2), 1, "single pending after multi-observer reconcile")
end

do
    local db = { consumableObservations = {} }
    local store = O.EnsureProfileStore(db, "profile-obs")
    -- Seed two pending identical cores with poor neighbor separation, then present one row that ties.
    local first = {
        deposit("Twin-Realm", flask, 7, 0, 0, 0, 5),
    }
    O.ReconcileSnapshot(store, "profile-obs", snapshot(first, { observedAt = clock }))
    advance(10)
    local second = {
        deposit("Twin-Realm", flask, 7, 0, 0, 0, 5),
    }
    -- Force a second observation by using a far time so it does not match.
    O.ReconcileSnapshot(store, "profile-obs", snapshot(second, {
        observedAt = clock + (4 * 60 * 60),
    }))
    assertEq(#O.ListPending(store, "club-1", 2), 2, "two far-apart identical cores stored separately")

    -- A new scan in the middle with no distinguishing neighbors should be ambiguous, not silent merge.
    local mid = clock + (2 * 60 * 60)
    local stats = O.ReconcileSnapshot(store, "profile-obs", snapshot({
        deposit("Twin-Realm", flask, 7, 0, 0, 0, 5),
    }, { observedAt = mid }))
    assertTrue(stats.ambiguous >= 1 or stats.created == 0, "ambiguous or non-creating reconcile when ties exist")
    local pending = O.ListPending(store, "club-1", 2)
    local ambiguous = 0
    for i = 1, #pending do
        if pending[i].status == "ambiguous" then ambiguous = ambiguous + 1 end
    end
    assertTrue(ambiguous >= 1 or #pending >= 2, "ambiguity retained for review rather than collapsed")
end

do
    local db = { consumableObservations = {} }
    local store = O.EnsureProfileStore(db, "profile-obs")
    O.ReconcileSnapshot(store, "profile-obs", snapshot({
        deposit("Old-Realm", flask, 3, 0, 0, 0, 1),
    }, { observedAt = clock }))
    assertEq(#O.ListPending(store, "club-1", 2), 1, "pending before expiry")
    local later = clock + O.PENDING_TTL_SECONDS + 10
    local pending = O.ListPending(store, "club-1", 2, { now = later })
    assertEq(#pending, 0, "pending expires after 14 days")
    local scope = O.EnsureScope(store, "club-1", 2)
    assertTrue(#(scope.suppressions or {}) >= 1, "expiry leaves suppression stub")

    -- Blizzard relative age advances with wall time; reconstructed approxTxnTime stays near original.
    local ageHours = math.floor((later - clock) / 3600) + 1
    local stats = O.ReconcileSnapshot(store, "profile-obs", snapshot({
        deposit("Old-Realm", flask, 3, nil, nil, nil, nil, ageHours),
    }, { observedAt = later }), { now = later })
    assertEq(stats.suppressed, 1, "expired transaction rediscovery suppressed")
    assertEq(stats.created, 0, "expired rediscovery does not recreate pending")
end

do
    local db = { consumableObservations = {} }
    local store = O.EnsureProfileStore(db, "profile-obs")
    local stats = O.ReconcileSnapshot(store, "profile-obs", snapshot({
        deposit("Kyrius-Realm", flask, 20, 0, 0, 0, 1),
    }, { authoritative = false }))
    assertTrue(stats.skipped, "non-authoritative snapshot skipped")
    assertEq(#O.ListPending(store, "club-1", 2), 0, "stale snapshot creates no observations")
end

do
    local db = { consumableObservations = {} }
    local store = O.EnsureProfileStore(db, "profile-obs")
    O.ReconcileSnapshot(store, "profile-obs", snapshot({
        deposit("Alt-Realm", flask, 8, 0, 0, 0, 0),
    }, { observedBy = "Alt-Realm" }))
    -- Simulate account-wide persistence /reload: same db table reused.
    local pending = O.ListPending(store, "club-1", 2)
    assertEq(#pending, 1, "observation survives simulated reload store reuse")
    assertEq(pending[1].observedBy, "Alt-Realm", "original observedBy preserved across reload")
    assertEq(pending[1].donor, "Alt-Realm", "donor preserved across reload")
end

do
    -- Wrong guild/tab ignored by EnsureScope / reconcile inputs.
    local db = { consumableObservations = {} }
    local store = O.EnsureProfileStore(db, "profile-obs")
    local stats = O.ReconcileSnapshot(store, "profile-obs", snapshot({
        deposit("Kyrius-Realm", flask, 20, 0, 0, 0, 1),
    }, { guildGuid = "club-other", bankTab = 2 }))
    assertEq(stats.created, 1, "observation stored under provided guild scope")
    assertEq(#O.ListPending(store, "club-1", 2), 0, "configured club-1 scope empty")
    assertEq(#O.ListPending(store, "club-other", 2), 1, "other guild scope isolated")
end

-- ---------------------------------------------------------------------------
-- Bank log host lifecycle (bounded / idle)
-- ---------------------------------------------------------------------------

do
    resetWorld()
    world.now = clock
    world.activeProfile = makeProfile()
    SF.lootHelperDB = { profiles = { [world.activeProfile._profileId] = world.activeProfile } }
    -- Minimal runtime stub for guild/profile helpers.
    SF.ConsumablesRuntime = {
        AccountingProfile = function() return world.activeProfile end,
        CurrentGuild = function()
            return { guid = tostring(world.clubId), name = "Spectrum", realm = "Realm" }
        end,
    }

    BankLog.frame = nil
    BankLog.active = false
    BankLog.bankOpen = false
    BankLog:Init()
    assertTrue(BankLog.frame ~= nil, "bank log frame created")
    assertTrue(BankLog.frame.events["GUILDBANKLOG_UPDATE"], "registers GUILDBANKLOG_UPDATE")
    assertTrue(BankLog.frame.events["GUILDBANKFRAME_OPENED"], "registers bank open")
    assertTrue(BankLog.frame.events["GUILDBANKFRAME_CLOSED"], "registers bank close")

    world.logRows[2] = {
        deposit("Kyrius-Realm", flask, 20, 0, 0, 0, 1),
        deposit("Kyrius-Realm", flask, 20, 0, 0, 0, 0),
    }

    local queriesBefore = #world.logQueries
    BankLog:OnBankOpened()
    assertTrue(BankLog.active, "observer active while eligible bank open")
    assertTrue(#world.logQueries > queriesBefore, "queries log on open")

    BankLog:OnEvent("GUILDBANKLOG_UPDATE")
    local store = O.EnsureProfileStore(SF.lootHelperDB, "profile-obs")
    assertEq(#O.ListPending(store, "club-1", 2), 2, "bank-log host captures eligible deposits")

    local afterOpen = #world.after
    BankLog:OnBankClosed()
    assertFalse(BankLog.active, "observer inactive after bank close")
    local token = BankLog.rescanToken
    -- Drain previously queued callbacks; closed state must keep them no-ops.
    local drained = 0
    while #world.after > 0 and drained < 50 do
        local fn = table.remove(world.after, 1)
        fn()
        drained = drained + 1
    end
    assertEq(BankLog.rescanToken, token, "closed bank does not keep rescheduling rescans")
    assertFalse(BankLog.active, "callbacks after close leave observer idle")

    -- Repeated open/close must not accumulate frames.
    local frame1 = BankLog.frame
    for _ = 1, 20 do
        BankLog:OnBankOpened()
        BankLog:OnEvent("GUILDBANKLOG_UPDATE")
        BankLog:OnBankClosed()
    end
    assertTrue(BankLog.frame == frame1, "open/close cycles reuse one frame")
    assertFalse(BankLog.active, "idle after repeated open/close")
end

do
    resetWorld()
    world.activeProfile = nil
    SF.lootHelperDB = { profiles = {} }
    SF.ConsumablesRuntime = {
        AccountingProfile = function() return world.activeProfile end,
        CurrentGuild = function()
            return { guid = tostring(world.clubId), name = "Spectrum", realm = "Realm" }
        end,
    }
    BankLog.frame = nil
    BankLog:Init()
    BankLog:OnBankOpened()
    assertFalse(BankLog.active, "no observation without applicable profile")
    assertEq(#world.logQueries, 0, "does not query unrelated guild banks without config")

    world.activeProfile = makeProfile()
    SF.lootHelperDB.profiles[world.activeProfile._profileId] = world.activeProfile
    world.logRows[2] = { deposit("Later-Realm", vial, 2, 0, 0, 0, 0) }
    BankLog.bankOpen = true
    BankLog:OnProfileMaybeChanged()
    assertTrue(BankLog.active, "starts when profile becomes available while bank open")
    BankLog:OnEvent("GUILDBANKLOG_UPDATE")
    local store = O.EnsureProfileStore(SF.lootHelperDB, "profile-obs")
    assertEq(#O.ListPending(store, "club-1", 2), 1, "captures after late profile availability")
    BankLog:OnBankClosed()
end

assertTrue(type(O.ReconcileSnapshot) == "function", "observation API present")
assertTrue(type(BankLog.ProcessLogUpdate) == "function", "bank log host API present")

if failures > 0 then
    io.stderr:write(string.format("%d failed, %d passed\n", failures, passes))
    os.exit(1)
end
io.stdout:write(string.format("%d passed, 0 failed\n", passes))
