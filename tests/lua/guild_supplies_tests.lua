-- Production-Lua tests for Guild Supplies Part 2A (#385).
-- Run from repository root: lua5.1 tests/lua/guild_supplies_tests.lua

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
    if cond then pass(message) else fail(message) end
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local function assertNil(actual, message)
    if actual == nil then pass(message) else fail(message .. " (got " .. tostring(actual) .. ")") end
end

---------------------------------------------------------------------------
-- Simulated world
---------------------------------------------------------------------------

local world = {
    time = 5000,
    chat = {},
    prints = {},
    debugEnabled = false,
    debugLogs = {},
    guild = {
        inGuild = true,
        name = "Spectrum",
        realm = "Garona",
        clubId = 42,
        ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
        members = {
            { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
            { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
            { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true },
            { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
        },
    },
    unitName = "Alice",
    unitGuid = "Player-1-Alice",
    impersonationActive = false,
    gossipListening = false,
    gossipReady = false,
    wireSends = 0,
    rosterRequests = 0,
}

function GetTime() return world.time end
function time() return math.floor(world.time) end
function GetServerTime() return math.floor(world.time) end
function IsInGuild() return world.guild.inGuild end
function GetGuildInfo(unit)
    if unit == "player" and world.guild.inGuild then
        return world.guild.name, world.guild.ranks[1], 0, world.guild.realm
    end
end
function GetNumGuildMembers()
    return #world.guild.members, #world.guild.members, #world.guild.members
end
function GetGuildRosterInfo(i)
    local m = world.guild.members[i]
    if not m then return end
    -- 3rd return is legacy 0-based rankIndex; 17th is GUID.
    local rankIndex = (tonumber(m.rankOrder) or 1) - 1
    return m.name, world.guild.ranks[m.rankOrder] or "Rank", rankIndex, 80, "Warrior", "Zone",
        "", "", m.online, 0, "WARRIOR", 0, 0, false, false, 0, m.guid
end
function GuildControlGetNumRanks()
    return #world.guild.ranks
end
function GuildControlGetRankName(i)
    return world.guild.ranks[i]
end
C_GuildInfo = {
    GuildRoster = function()
        world.rosterRequests = (world.rosterRequests or 0) + 1
    end,
    GetGuildRankOrder = function(guid)
        for _, m in ipairs(world.guild.members) do
            if m.guid == guid then
                return m.rankOrder
            end
        end
        return nil
    end,
}
C_Club = {
    GetGuildClubId = function()
        return world.guild.clubId
    end,
}
function GetRealmName() return "Garona" end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function UnitFullName() return world.unitName, "Garona" end
function UnitName() return world.unitName end
function UnitGUID(unit)
    if unit == "player" then return world.unitGuid end
end

local timers = {}
C_Timer = {
    After = function(delay, fn)
        timers[#timers + 1] = { at = world.time + delay, fn = fn }
    end,
}

function CreateFrame()
    local f = {
        events = {},
        RegisterEvent = function(self, e) self.events[e] = true end,
        UnregisterAllEvents = function(self) self.events = {} end,
        SetScript = function(self, _, fn) self._onEvent = fn end,
    }
    return f
end

-- Chat / print traps
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    world.prints[#world.prints + 1] = table.concat(parts, "\t")
end
DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, msg)
        world.chat[#world.chat + 1] = tostring(msg)
    end,
}

---------------------------------------------------------------------------
-- Load production modules
---------------------------------------------------------------------------

local SF = {}
local addonName = "SpectrumFederation"

-- Minimal locale
SF.L = {
    GUILD_SUPPLIES_EDITOR_RANK_LABEL = "%s and higher",
    GUILD_SUPPLIES_RANK_WAITING = "Guild rank information is unavailable.",
}
function SF.LocaleText(key, default)
    local v = SF.L[key]
    if type(v) == "string" and v ~= "" then return v end
    return default or tostring(key or "")
end

SF.Debug = {
    _enabled = false,
    IsEnabled = function(self) return self._enabled end,
    SetEnabled = function(self, v) self._enabled = v and true or false end,
    Info = function(self, cat, fmt, ...)
        if not self._enabled then return end
        world.debugLogs[#world.debugLogs + 1] = { cat = cat, msg = string.format(fmt, ...) }
    end,
    Warn = function(self, cat, fmt, ...)
        if not self._enabled then return end
        world.debugLogs[#world.debugLogs + 1] = { cat = cat, msg = string.format(fmt, ...) }
    end,
    Verbose = function() end,
    Error = function() end,
}

SF.Consumables = {
    MAX_REQUESTED_ITEMS = 256,
    MAX_GOAL = 100000,
}

SF.LootHelperImpersonation = {
    IsActive = function()
        return world.impersonationActive and true or false
    end,
}

local function loadModule(path)
    local f, err = loadfile(path)
    if not f then error(err) end
    f(addonName, SF)
end

SF.NameUtil = {}
loadModule("SpectrumFederation/modules/NameUtil.lua")

SF.GuildGossip = {}
loadModule("SpectrumFederation/modules/GuildGossip/01_Constants.lua")
loadModule("SpectrumFederation/modules/GuildGossip/02_Util.lua")
loadModule("SpectrumFederation/modules/GuildGossip/05_GuildAdapter.lua")

-- Stub provider lifecycle so SyncGuildAdapterLifecycle stays idle.
SF.GuildGossip.HasActiveProvider = function() return false end
SF.GuildGossip.Init = function() end

loadModule("SpectrumFederation/modules/GuildSupplies/State.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Authority.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Operations.lua")

local GS = SF.GuildSupplies
local GG = SF.GuildGossip

local function resetDb()
    SpectrumFederationDB = {}
    GS._db = nil
    GS._root = nil
    GS._rootValid = false
    GS._rootReason = "not_initialized"
    GS._handleGeneration = 0
    GS._lastGuildKey = nil
    world.rosterRequests = 0
    if GG._demandRoster then
        GG._demandRoster.lastRequestAt = nil
    end
end

local function setPlayer(name, guid, rankOrder)
    world.unitName = name:match("^([^-]+)") or name
    world.unitGuid = guid
    -- Ensure member exists
    local found = false
    for _, m in ipairs(world.guild.members) do
        if m.guid == guid or m.name == name then
            m.name = name
            m.guid = guid
            m.rankOrder = rankOrder
            found = true
            break
        end
    end
    if not found then
        world.guild.members[#world.guild.members + 1] = {
            name = name, guid = guid, rankOrder = rankOrder, online = true,
        }
    end
end

local function ensureIdleGossip()
    GG.SyncGuildAdapterLifecycle()
    local g = GG._guild
    assertTrue(g.listening ~= true, "gossip not listening with zero providers")
    assertTrue(g.ready ~= true, "gossip not ready with zero providers")
    assertEq(g.members and next(g.members), nil, "gossip membership cleared when idle")
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

-- 1) Root init does not bootstrap guilds / network
do
    resetDb()
    world.wireSends = 0
    local ok = GS:Initialize(SpectrumFederationDB)
    assertTrue(ok, "Initialize creates empty root")
    assertTrue(type(SpectrumFederationDB.guildSupplies) == "table", "root present")
    assertEq(next(SpectrumFederationDB.guildSupplies.guilds), nil, "no guild auto-created")
    local rec, reason = GS:GetCurrentRecord()
    assertNil(rec, "GetCurrentRecord does not allocate")
    assertEq(reason, "not_configured", "not_configured before create")
    ensureIdleGossip()
end

-- 2) Missing club readiness
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    local saved = world.guild.clubId
    world.guild.clubId = nil
    local ctx = GS:GetCurrentContext()
    assertEq(ctx.ready, false, "missing club => not ready")
    assertEq(ctx.reason, "club_id_unavailable", "club_id_unavailable reason")
    local caps = GS:GetCapabilities()
    assertEq(caps.canEdit, false, "no edit without club")
    world.guild.clubId = 0
    ctx = GS:GetCurrentContext()
    assertEq(ctx.reason, "club_id_unavailable", "zero club rejected")
    world.guild.clubId = saved
end

-- 3) Explicit staged create + default rank 3; ranks 1-3 edit, 4 denied
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    local rec, status = GS:CreateStagedRecord()
    assertEq(status, "accepted", "GM creates staged record")
    assertTrue(rec and rec.activation == "staged", "activation staged")
    assertEq(rec and rec.permission.editorRankPosition, 3, "default editor rank 3")

    local caps = GS:GetCapabilities()
    assertEq(caps.canEdit, true, "GM can edit")
    assertTrue(type(caps.editorRankName) == "string", "rank name resolved")
    assertTrue(caps.editorRankLabel:find("Veteran", 1, true) ~= nil, "label uses actual rank name")
    assertTrue(not caps.editorRankLabel:find("Rank 3", 1, true), "no numeric Rank 3 label")

    setPlayer("Carol-Garona", "Player-1-Carol", 3)
    caps = GS:GetCapabilities()
    assertEq(caps.canEdit, true, "rank 3 can edit")

    setPlayer("Dave-Garona", "Player-1-Dave", 4)
    caps = GS:GetCapabilities()
    assertEq(caps.canEdit, false, "rank 4 cannot edit")
    assertEq(caps.canRead, true, "rank 4 can still read")
end

-- 4) Guild isolation across characters / club change
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local a = GS:GetCurrentRecord()
    assertTrue(a ~= nil, "guild A record")
    local datasetA = a.datasetId

    world.guild.clubId = 99
    world.guild.name = "OtherGuild"
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    -- Same character, different guild — no leak of A
    local b, reason = GS:GetCurrentRecord()
    assertNil(b, "guild B not configured")
    assertEq(reason, "not_configured", "guild B not_configured")
    local recB, st = GS:CreateStagedRecord()
    assertEq(st, "accepted", "create guild B")
    assertTrue(recB.datasetId ~= datasetA, "distinct dataset IDs")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"] ~= nil, true, "guild A retained")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:99"] ~= nil, true, "guild B present")

    world.guild.clubId = 42
    world.guild.name = "Spectrum"
    local again = GS:GetCurrentRecord()
    assertEq(again.datasetId, datasetA, "return to guild A restores record")
end

-- 5) Future/malformed schema preserved
do
    resetDb()
    SpectrumFederationDB = {
        guildSupplies = {
            schemaVersion = 99,
            localWriter = { nonce = "abc", nextSeq = 1 },
            guilds = {},
        },
    }
    local ok, reason = GS:Initialize(SpectrumFederationDB)
    assertEq(ok, false, "future schema not accepted")
    assertEq(reason, "unsupported_schema", "unsupported_schema reason")
    assertEq(SpectrumFederationDB.guildSupplies.schemaVersion, 99, "future root preserved")

    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    SpectrumFederationDB.guildSupplies.guilds["club:42"].schemaVersion = 9
    local rec, rsn = GS:GetCurrentRecord()
    assertNil(rec, "malformed guild unavailable")
    assertEq(rsn, "unsupported_schema", "malformed reason")
    local _, st, err = GS:CreateStagedRecord()
    assertEq(st, "rejected", "cannot overwrite malformed")
    assertEq(err, "unsupported_schema", "overwrite blocked")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].schemaVersion, 9, "malformed retained")
end

-- 6) Rename refreshes names; reorder keeps numeric threshold
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    world.guild.ranks[3] = "Strategist"
    local caps = GS:GetCapabilities()
    assertTrue(caps.editorRankLabel:find("Strategist", 1, true) ~= nil, "rename refreshes label")

    -- Reorder: former Member (Dave rank 4) moves into position 3
    world.guild.members[4].rankOrder = 3 -- Dave
    world.guild.members[3].rankOrder = 4 -- Carol demoted
    setPlayer("Dave-Garona", "Player-1-Dave", 3)
    caps = GS:GetCapabilities()
    assertEq(caps.canEdit, true, "positional policy: new occupant of rank 3 edits")
    setPlayer("Carol-Garona", "Player-1-Carol", 4)
    caps = GS:GetCapabilities()
    assertEq(caps.canEdit, false, "former rank-3 holder loses edit after demotion")
end

-- 7) Invalid/out-of-range policy → GM recovery only
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()
    record.permission.editorRankPosition = 99
    setPlayer("Bob-Garona", "Player-1-Bob", 2)
    local caps = GS:GetCapabilities()
    assertEq(caps.canEdit, false, "officer cannot edit invalid policy")
    assertEq(caps.canRecoverPolicy, false, "non-GM no recovery")
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    caps = GS:GetCapabilities()
    assertEq(caps.canRecoverPolicy, true, "GM can recover policy")
    assertEq(caps.canEdit, false, "GM recovery is not silent full edit under invalid policy")
end

-- 8) Guild with fewer than three ranks
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    world.guild.ranks = { "Guild Master", "Member" }
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
    }
    setPlayer("Bob-Garona", "Player-1-Bob", 2)
    local _, st, err = GS:CreateStagedRecord()
    assertEq(st, "rejected", "non-GM cannot init short rank list")
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    _, st, err = GS:CreateStagedRecord()
    assertEq(st, "rejected", "GM cannot invent missing default position 3")
    assertEq(err, "threshold_unselected", "threshold_unselected")
    -- restore default roster
    world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
        { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true },
        { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
    }
end

-- 9) Preview as Non-Admin
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    world.impersonationActive = true
    local caps = GS:GetCapabilities()
    assertEq(caps.canEdit, false, "preview denies edit")
    assertEq(caps.canRecoverPolicy, false, "preview denies recovery")
    assertEq(caps.reason, "preview_non_admin", "preview reason")
    world.impersonationActive = false
end

-- 10) Staged operations: accept, duplicate, independent targets, remove ancestry
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()

    local op, st = GS:NewConfigOperation("set-requested-item", { itemId = 12345 }, { itemId = 12345, goal = 20 })
    assertEq(st, "accepted", "new item op built")
    local status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "accepted", "item op applied")
    local record = GS:GetCurrentRecord()
    assertEq(record.accounting._consumables.requestedItems["12345"].goal, 20, "goal stored")

    status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "duplicate", "replay is duplicate")

    local opTab, stTab = GS:NewConfigOperation("set-bank-tab", "bankTab", 2)
    assertEq(stTab, "accepted", "bank tab op built")
    status = GS:ApplyStagedConfigOperation(opTab)
    assertEq(status, "accepted", "bank tab independent of item head")

    -- Goal edit on same item uses prior item revision
    local opGoal = GS:NewConfigOperation("set-requested-item", { itemId = 12345 }, { itemId = 12345, goal = 40 })
    status = GS:ApplyStagedConfigOperation(opGoal)
    assertEq(status, "accepted", "goal edit accepted")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["12345"].goal, 40, "goal updated")

    local opRemove = GS:NewConfigOperation("set-requested-item", { itemId = 12345 }, { removed = true })
    status = GS:ApplyStagedConfigOperation(opRemove)
    assertEq(status, "accepted", "remove accepted")
    assertNil(GS:GetCurrentRecord().accounting._consumables.requestedItems["12345"], "item removed")

    -- Re-add cannot use pre-remove base; must use remove revision as base
    local stale = {}
    for k, v in pairs(opGoal) do stale[k] = v end
    stale.id = "gs1:Player-1-Alice:deadbeef:999"
    stale.value = { itemId = 12345, goal = 99 }
    stale.baseTargetRevision = opGoal.id -- stale vs current remove head
    status, reason = GS:ApplyStagedConfigOperation(stale)
    assertEq(status, "pending", "stale item base pending")

    local opReadd = GS:NewConfigOperation("set-requested-item", { itemId = 12345 }, { itemId = 12345, goal = 5 })
    status = GS:ApplyStagedConfigOperation(opReadd)
    assertEq(status, "accepted", "re-add on remove head")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["12345"].goal, 5, "re-add goal")
end

-- 11) Threshold change under old policy; restrictive self-lockout
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Carol-Garona", "Player-1-Carol", 3)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local op = GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 2)
    local status = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "accepted", "rank 3 can tighten threshold to 2")
    local caps = GS:GetCapabilities()
    assertEq(caps.canEdit, false, "rank 3 loses edit after threshold 2")
    assertEq(GS:GetCurrentRecord().permission.editorRankPosition, 2, "threshold stored")
end

-- 12) Prepare then rank revocation / guild change at commit
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local op = GS:NewConfigOperation("set-bank-tab", "bankTab", 3)
    assertTrue(op ~= nil, "prepared op")

    -- Demote Alice before commit
    for _, m in ipairs(world.guild.members) do
        if m.guid == "Player-1-Alice" then m.rankOrder = 5 end
    end
    world.guild.ranks[5] = world.guild.ranks[5] or "Initiate"
    local status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "rejected", "revoked rank rejects commit")
    assertTrue(reason == "unauthorized" or reason == "preview_non_admin", "unauthorized after revoke: " .. tostring(reason))

    -- Restore and test guild change
    for _, m in ipairs(world.guild.members) do
        if m.guid == "Player-1-Alice" then m.rankOrder = 1 end
    end
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    op = GS:NewConfigOperation("set-bank-tab", "bankTab", 4)
    world.guild.clubId = 77
    status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "rejected", "guild change rejects commit")
    assertTrue(reason == "wrong_guild" or reason == "stale_handle" or reason == "not_configured" or reason == "not_ready",
        "guild-change reason=" .. tostring(reason))
    world.guild.clubId = 42
end

-- 13) ID conflict retained; live profile ledger untouched
do
    resetDb()
    SpectrumFederationDB = {
        lootHelper = {
            profiles = {
                p1 = { _consumables = { requestedItems = { ["999"] = { itemId = 999, goal = 1 } } } },
            },
            activeProfileId = "p1",
        },
    }
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local op = GS:NewConfigOperation("set-requested-item", { itemId = 1 }, { itemId = 1, goal = 1 })
    GS:ApplyStagedConfigOperation(op)
    local clash = {}
    for k, v in pairs(op) do clash[k] = v end
    clash.value = { itemId = 1, goal = 2 }
    local status, reason = GS:ApplyStagedConfigOperation(clash)
    assertEq(status, "rejected", "id conflict rejected")
    assertEq(reason, "id_conflict", "id_conflict reason")
    assertTrue(GS:GetCurrentRecord().operations.conflicts[op.id] ~= nil, "conflict retained")
    assertEq(SpectrumFederationDB.lootHelper.profiles.p1._consumables.requestedItems["999"].goal, 1,
        "legacy profile ledger untouched")
end

-- 14) Confirmation contract
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local before = GS:GetCurrentRecord()
    local beforePerm = before.permission.editorRankPosition
    local beforeItems = before.accounting._consumables.requestedItems

    -- Candidate proposes a different policy; must not self-authorize Dave
    setPlayer("Dave-Garona", "Player-1-Dave", 4)
    local bad = GS:NewConfirmationOperation({
        recordId = "cand-1",
        contentFingerprint = "fp1",
        proposedEditorRankPosition = 4,
        originalIds = { "txn-old-1" },
    })
    assertNil(bad, "non-editor cannot confirm")

    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    local conf, st = GS:NewConfirmationOperation({
        recordId = "cand-1",
        contentFingerprint = "fp1",
        proposedEditorRankPosition = 1,
        originalIds = { "txn-old-1" },
        campaignId = nil,
    })
    assertEq(st, "accepted", "editor builds confirmation")
    local status = GS:ApplyStagedConfirmationOperation(conf)
    assertEq(status, "accepted", "confirmation staged")
    local after = GS:GetCurrentRecord()
    assertEq(after.permission.editorRankPosition, beforePerm, "accepted policy unchanged by confirm")
    assertEq(after.accounting._consumables.requestedItems, beforeItems, "items unchanged")
    assertEq(after.confirmationRefs[1], conf.id, "confirmationRefs stores id")
    assertEq(conf.candidateRef.originalIds[1], "txn-old-1", "original ids preserved")

    -- Changed fingerprint must not validate against stored candidate binding
    conf.contentFingerprint = "fp-changed"
    local ok, err = GS:ValidateConfirmationOperation(conf)
    assertEq(ok, false, "changed fingerprint rejected")
end

-- 15) Campaign boundary schema
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()

    local header = {
        schemaVersion = 1,
        campaignId = "gs1:Player-1-Alice:deadbeef:1",
        datasetId = record.datasetId,
        guildKey = "club:42",
        parentCampaignId = nil,
        resetOperationId = "gs1:Player-1-Alice:deadbeef:1",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 123456,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextObservedAt = nil,
        contextRecordCount = 0,
    }
    local ok, err = GS:_StoreCampaignBoundaryForTests(header)
    assertTrue(ok, "store new-goal unavailable boundary: " .. tostring(err))
    local bound = GS:GetCurrentCampaignBoundary()
    assertEq(bound.startedAt, 123456, "immutable startedAt roundtrip")
    assertEq(bound.contextStatus, "unavailable", "unavailable context")

    -- Competing campaign with equal legacy generation numbers still unique by id
    local header2 = {
        schemaVersion = 1,
        campaignId = "gs1:Player-1-Alice:deadbeef:2",
        datasetId = record.datasetId,
        guildKey = "club:42",
        parentCampaignId = header.campaignId,
        resetOperationId = "gs1:Player-1-Alice:deadbeef:2",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 123500,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "empty",
        contextObservedAt = 123500,
        contextRecordCount = 0,
    }
    ok, err = GS:_StoreCampaignBoundaryForTests(header2)
    assertTrue(ok, "second campaign id unique: " .. tostring(err))
    assertTrue(header.campaignId ~= header2.campaignId, "campaign ids differ")

    local legacy = {
        schemaVersion = 1,
        campaignId = "legacy-camp-1",
        datasetId = record.datasetId,
        guildKey = "club:42",
        parentCampaignId = nil,
        resetOperationId = nil,
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = nil,
        bankTabAtStart = nil,
        boundaryVersion = 1,
        boundaryKind = "legacy-preserved",
        contextStatus = "captured",
        contextObservedAt = 100,
        contextRecordCount = 3,
    }
    -- Switch current to legacy for validation accessor
    ok, err = GS:_StoreCampaignBoundaryForTests(legacy)
    assertTrue(ok, "legacy-preserved captured ok: " .. tostring(err))
    bound = GS:GetCurrentCampaignBoundary()
    assertEq(bound.boundaryKind, "legacy-preserved", "legacy kind")
    assertEq(bound.contextStatus, "captured", "captured status")
end

-- 16) Zero-provider native authority + gossip remains idle
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    ensureIdleGossip()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    local id = GG.GetGuildIdentity()
    assertEq(id.guildKey, "club:42", "demand-driven identity without provider")
    local member = GG.GetGuildMember("Alice-Garona")
    assertEq(member.rankOrder, 1, "demand-driven rank order")
    local ranks = GG.GetGuildRanks()
    assertEq(ranks[1], "Guild Master", "demand-driven rank names")
    ensureIdleGossip()
    GS:CreateStagedRecord()
    local op = GS:NewConfigOperation("set-bank-tab", "bankTab", 1)
    local status = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "accepted", "staged op works with zero providers")
    ensureIdleGossip()
    assertEq(#world.chat, 0, "no chat messages")
    assertEq(#world.prints, 0, "no print output")
end

-- 17) Reload persistence
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local op = GS:NewConfigOperation("set-requested-item", { itemId = 7 }, { itemId = 7, goal = 3 })
    GS:ApplyStagedConfigOperation(op)
    local saved = SpectrumFederationDB
    -- Simulate reload
    GS._db = nil
    GS._root = nil
    GS._rootValid = false
    SpectrumFederationDB = saved
    GS:Initialize(SpectrumFederationDB)
    local record = GS:GetCurrentRecord()
    assertEq(record.accounting._consumables.requestedItems["7"].goal, 3, "survives reload")
    local status = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "duplicate", "duplicate after reload")
end

-- 18) Legacy rankIndex normalization when GetGuildRankOrder absent
do
    local saved = C_GuildInfo.GetGuildRankOrder
    C_GuildInfo.GetGuildRankOrder = nil
    setPlayer("Bob-Garona", "Player-1-Bob", 2)
    local member = GG.GetGuildMember("Bob-Garona")
    assertEq(member.rankOrder, 2, "legacy 0-based rankIndex normalized to 1-based")
    C_GuildInfo.GetGuildRankOrder = saved
end

-- 19) Profile switch does not change guild key / create records
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    SpectrumFederationDB.lootHelper = { activeProfileId = "a" }
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    local ctx1 = GS:GetCurrentContext()
    SpectrumFederationDB.lootHelper.activeProfileId = "b"
    local ctx2 = GS:GetCurrentContext()
    assertEq(ctx1.guildKey, ctx2.guildKey, "profile switch does not change guild key")
    assertEq(next(SpectrumFederationDB.guildSupplies.guilds), nil, "profile switch does not create guild")
end

---------------------------------------------------------------------------
-- Repair regressions (PR #392 review batch)
---------------------------------------------------------------------------

-- R1) Malformed-policy GM recovery vs unrelated corruption
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.permission.editorRankPosition = 0
    local exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "malformed policy not exposed by read")
    assertEq(reason, "invalid_editor_rank_position", "permission-only reason")
    local caps = GS:GetCapabilities()
    assertEq(caps.canRecoverPolicy, true, "GM canRecoverPolicy for permission-only")
    local op, st = GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 2)
    assertEq(st, "accepted", "GM can prepare recovery op")
    local status = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "accepted", "GM recovery commit accepts")
    local fixed = GS:GetCurrentRecord()
    assertEq(fixed.permission.editorRankPosition, 2, "recovered threshold stored")

    -- Missing revision metadata
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.permission.revisionId = nil
    caps = GS:GetCapabilities()
    assertEq(caps.canRecoverPolicy, true, "GM recovers missing revisionId")
    op, st = GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 3)
    assertEq(st, "accepted", "prepare with missing revisionId")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "commit missing revisionId recovery")

    -- Unrelated corruption: malformed requestedItems — no recovery write path
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.accounting._consumables.requestedItems = "corrupt"
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "corrupt requestedItems unavailable")
    assertEq(reason, "invalid_accounting", "invalid_accounting reason")
    caps = GS:GetCapabilities()
    assertEq(caps.canRecoverPolicy, false, "no policy recovery for accounting corruption")
    assertEq(caps.canRead, false, "corrupt record not readable")
    op, st = GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 2)
    assertEq(st, "rejected", "recovery blocked for unrelated corruption")
    -- SavedVariables preserved
    assertEq(type(SpectrumFederationDB.guildSupplies.guilds["club:42"].accounting._consumables.requestedItems),
        "string", "corrupt requestedItems preserved")

    -- Preview as Non-Admin still denies recovery
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    SpectrumFederationDB.guildSupplies.guilds["club:42"].permission.editorRankPosition = 0
    world.impersonationActive = true
    caps = GS:GetCapabilities()
    assertEq(caps.canRecoverPolicy, false, "preview denies recovery")
    op, st = GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 2)
    assertEq(st, "rejected", "preview blocks recovery prepare")
    world.impersonationActive = false
end

-- R2) Shared pending/conflict capacity (128) + confirmation path
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()
    local ops = record.operations
    -- Fill 127 pending slots with unique fake bodies
    for i = 1, 127 do
        local id = "pend-" .. i
        ops.pending[id] = { id = id, reason = "stale_base", body = { id = id, kind = "x" }, at = 1 }
    end
    -- One conflict fills the shared budget to 128
    ops.conflicts["conf-1"] = { id = "conf-1", body = { id = "conf-1" }, at = 1 }
    local op = GS:NewConfigOperation("set-requested-item", { itemId = 50 }, { itemId = 50, goal = 1 })
    -- Force stale base
    op.baseTargetRevision = "missing-base"
    local status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "rejected", "shared cap rejects new pending")
    assertEq(reason, "full", "full reason for shared cap")
    assertNil(ops.pending[op.id], "no partial pending mutation")

    -- Existing-ID exact retry under a full shared budget does not grow retention.
    ops.pending = {}
    ops.conflicts = {}
    local retryOp = GS:NewConfigOperation("set-bank-tab", "bankTab", 2)
    retryOp.baseTargetRevision = "missing-base"
    status, reason = GS:ApplyStagedConfigOperation(retryOp)
    assertEq(status, "pending", "seed pending for retry")
    -- Fill remaining slots to the shared cap of 128.
    for i = 1, 127 do
        local id = "fill-" .. i
        ops.pending[id] = { id = id, reason = "stale_base", body = { id = id }, at = 1 }
    end
    local before = 0
    for _ in pairs(ops.pending) do before = before + 1 end
    for _ in pairs(ops.conflicts) do before = before + 1 end
    assertEq(before, 128, "budget full before exact retry")
    status, reason = GS:ApplyStagedConfigOperation(retryOp)
    assertEq(status, "pending", "exact pending retry idempotent under full budget")
    assertEq(reason, "stale_base", "exact retry still stale_base")
    local after = 0
    for _ in pairs(ops.pending) do after = after + 1 end
    for _ in pairs(ops.conflicts) do after = after + 1 end
    assertEq(after, 128, "retry did not grow retention budget")

    -- Confirmation path also respects shared cap / conflict-ID consistency
    ops.pending = {}
    ops.conflicts = { ["conf-x"] = { id = "conf-x", body = { id = "conf-x", kind = "confirm-candidate" }, at = 1 } }
    for i = 1, 127 do
        ops.pending["c" .. i] = { id = "c" .. i, reason = "stale_base", body = { id = "c" .. i }, at = 1 }
    end
    local conf = GS:NewConfirmationOperation({ recordId = "cand-cap", contentFingerprint = "fp-cap" })
    conf.basePolicyRevision = "stale-policy"
    status, reason = GS:ApplyStagedConfirmationOperation(conf)
    assertEq(status, "rejected", "confirmation shared cap")
    assertEq(reason, "full", "confirmation full")

    -- Confirmation conflict-ID consistency matches config path
    ops.pending = {}
    ops.conflicts = {}
    conf = GS:NewConfirmationOperation({ recordId = "cand-dup", contentFingerprint = "fp-dup" })
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "accepted", "confirm accepted once")
    local clash = {}
    for k, v in pairs(conf) do clash[k] = v end
    clash.timestamp = (tonumber(conf.timestamp) or 1) + 1
    status, reason = GS:ApplyStagedConfirmationOperation(clash)
    assertEq(status, "rejected", "confirm same-id different body rejected")
    assertEq(reason, "id_conflict", "confirm id_conflict")
    assertTrue(ops.conflicts[conf.id] ~= nil, "confirm conflict body retained")
    status, reason = GS:ApplyStagedConfirmationOperation(clash)
    assertEq(status, "rejected", "confirm conflict-id still rejected")
    assertEq(reason, "id_conflict", "confirm conflict-id consistent")
end

-- R3) Confirmation campaign bind (incl. nil→campaign)
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local conf, st = GS:NewConfirmationOperation({
        recordId = "cand-camp",
        contentFingerprint = "fp-camp",
        originalIds = { "txn-1" },
    })
    assertEq(st, "accepted", "confirm prepared under nil campaign")
    assertNil(conf.campaignId, "prepared campaignId nil")
    -- Introduce a campaign after prepare
    local record = GS:GetCurrentRecord()
    local ok = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-A",
        datasetId = record.datasetId,
        guildKey = "club:42",
        resetOperationId = "camp-A",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 100,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextRecordCount = 0,
    })
    assertTrue(ok, "campaign A stored")
    local status, reason = GS:ApplyStagedConfirmationOperation(conf)
    assertEq(status, "pending", "nil→campaign makes confirmation pending")
    assertEq(reason, "stale_base", "stale_base for campaign change")
    assertNil(GS:GetCurrentRecord().operations.records[conf.id], "not newly accepted")
    assertEq(conf.candidateRef.originalIds[1], "txn-1", "original ids preserved")
end

-- R4) Nested caller mutation after admission does not alter durable body
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local op = GS:NewConfigOperation("set-requested-item", { itemId = 77 }, { itemId = 77, goal = 5 })
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "admit item op")
    op.value.goal = 999
    op.target.itemId = 1
    local stored = GS:GetCurrentRecord().operations.records[op.id]
    assertEq(stored.value.goal, 5, "durable goal immune to caller mutation")
    assertEq(stored.target.itemId, 77, "durable target immune to caller mutation")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["77"].goal, 5,
        "projection unchanged")
end

-- R5) Malformed saved requestedItems unavailable
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    SpectrumFederationDB.guildSupplies.guilds["club:42"].accounting._consumables.requestedItems = true
    local rec, reason = GS:GetCurrentRecord()
    assertNil(rec, "truthy non-table requestedItems unavailable")
    assertEq(reason, "invalid_accounting", "invalid_accounting for requestedItems")
end

-- R6) Bank tab 1–8 domain + invalid confirmation fields
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local op9, st9 = GS:NewConfigOperation("set-bank-tab", "bankTab", 9)
    assertEq(st9, "rejected", "tab 9 rejected at prepare")
    local op0, st0 = GS:NewConfigOperation("set-bank-tab", "bankTab", 0)
    assertEq(st0, "rejected", "tab 0 rejected")
    local op8, st8 = GS:NewConfigOperation("set-bank-tab", "bankTab", 8)
    assertEq(st8, "accepted", "tab 8 accepted")
    assertEq(GS:ApplyStagedConfigOperation(op8), "accepted", "tab 8 applied")
    local opNil, stNil = GS:NewConfigOperation("set-bank-tab", "bankTab", nil)
    assertEq(stNil, "accepted", "nil bank tab prepare (unconfigured)")
    assertEq(GS:ApplyStagedConfigOperation(opNil), "accepted", "nil bank tab applied")
    assertNil(GS:GetCurrentRecord().accounting._consumables.bankTab, "nil unconfigured preserved")

    local conf = GS:NewConfirmationOperation({ recordId = "c-bad", contentFingerprint = "fp" })
    conf.actorName = nil
    local ok, err = GS:ValidateConfirmationOperation(conf)
    assertEq(ok, false, "missing actorName rejected")
    assertEq(err, "invalid_actor", "invalid_actor for missing name")
    conf = GS:NewConfirmationOperation({ recordId = "c-bad2", contentFingerprint = "fp" })
    conf.id = string.rep("x", 200)
    ok, err = GS:ValidateConfirmationOperation(conf)
    assertEq(ok, false, "oversized confirmation id rejected")
    assertEq(err, "invalid_id", "invalid_id for oversized")
    conf = GS:NewConfirmationOperation({ recordId = "c-bad3", contentFingerprint = "fp" })
    conf.actorGuid = "Player-1-Eve"
    ok, err = GS:ValidateConfirmationOperation(conf)
    assertEq(ok, false, "caller-supplied foreign actor rejected")
    assertEq(err, "unauthorized", "unauthorized for foreign actor")
end

-- R7) Foreign-guild campaign headers fail without mutation
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local before = GS:GetCurrentRecord().currentCampaignId
    local ok, err = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "foreign-1",
        datasetId = GS:GetCurrentRecord().datasetId,
        guildKey = "club:999",
        resetOperationId = "foreign-1",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 1,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextRecordCount = 0,
    })
    assertEq(ok, false, "foreign guildKey rejected")
    assertEq(err, "wrong_guild", "wrong_guild for foreign campaign")
    assertEq(GS:GetCurrentRecord().currentCampaignId, before, "no campaign mutation")
    assertNil(GS:GetCurrentRecord().campaigns["foreign-1"], "foreign header not stored")
end

-- R8) Changed-body pending replay → id_conflict; unchanged retry idempotent
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local op = GS:NewConfigOperation("set-requested-item", { itemId = 88 }, { itemId = 88, goal = 1 })
    op.baseTargetRevision = "not-yet"
    local status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "pending", "initial stale pending")
    local pendingBody = GS:GetCurrentRecord().operations.pending[op.id].body
    local goal1 = pendingBody.value.goal

    -- Changed body, same ID
    local clash = {}
    for k, v in pairs(op) do clash[k] = v end
    clash.value = { itemId = 88, goal = 2, removed = false }
    status, reason = GS:ApplyStagedConfigOperation(clash)
    assertEq(status, "rejected", "changed pending body rejected")
    assertEq(reason, "id_conflict", "id_conflict for changed pending body")
    assertEq(GS:GetCurrentRecord().operations.pending[op.id].body.value.goal, goal1,
        "original pending body preserved")
    assertTrue(GS:GetCurrentRecord().operations.conflicts[op.id] ~= nil, "conflict retained")

    -- Exact unchanged retry
    status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "pending", "exact pending retry idempotent")
    assertEq(reason, "stale_base", "still stale_base")
end

---------------------------------------------------------------------------
-- Repair regressions (PR #392 second batch)
---------------------------------------------------------------------------

-- R9) Canonical item targets: scalar/string/table + invalid removals
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()

    -- Scalar/string apply inputs normalize to { itemId = N }; no crash / nil key.
    local op = GS:NewConfigOperation("set-requested-item", { itemId = 10 }, { itemId = 10, goal = 1 })
    op.target = 10
    local status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "accepted", "numeric target normalizes without crash")
    assertEq(GS:GetCurrentRecord().operations.heads["item:10"], op.id, "canonical item head")
    assertEq(GS:GetCurrentRecord().operations.records[op.id].target.itemId, 10,
        "durable target is canonical table")
    assertNil(GS:GetCurrentRecord().accounting._consumables.requestedItems["nil"], "no nil item key")

    op = GS:NewConfigOperation("set-requested-item", { itemId = 11 }, { itemId = 11, goal = 2 })
    op.target = "11"
    status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "accepted", "string target normalizes without crash")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["11"].goal, 2,
        "string target projects correctly")

    -- Validate-only still requires canonical table shape (no silent scalar validate).
    op = GS:NewConfigOperation("set-requested-item", { itemId = 12 }, { itemId = 12, goal = 1 })
    op.target = 12
    local ok, err = GS:ValidateConfigOperation(op)
    assertEq(ok, false, "validate rejects bare numeric target shape")
    assertEq(err, "invalid_target", "invalid_target from validate on scalar")

    local st
    op, st = GS:NewConfigOperation("set-requested-item", { itemId = -1 }, { removed = true })
    assertEq(st, "rejected", "negative removal rejected at prepare")
    op, st = GS:NewConfigOperation("set-requested-item", { itemId = 1.5 }, { removed = true })
    assertEq(st, "rejected", "fractional removal rejected at prepare")
    op = GS:NewConfigOperation("set-requested-item", { itemId = 13 }, { itemId = 13, goal = 1 })
    op.target = -5
    status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "rejected", "negative scalar apply rejected")
    assertEq(reason, "invalid_target", "invalid_target for negative scalar")
    op, st = GS:NewConfigOperation("set-requested-item", 42, { itemId = 42, goal = 3 })
    assertEq(st, "accepted", "scalar prepare normalizes to table")
    assertEq(op.target.itemId, 42, "canonical target shape from scalar prepare")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "canonical table apply accepts")
end

-- R10) Campaign schema: reset ID, bank tab, key/header match, dangling current
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local rec = GS:GetCurrentRecord()

    local ok, err = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-nil-reset",
        datasetId = rec.datasetId,
        guildKey = "club:42",
        resetOperationId = nil,
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 1,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextRecordCount = 0,
    })
    assertEq(ok, false, "new-goal nil reset rejected")
    assertEq(err, "invalid_reset_operation", "invalid_reset_operation")

    ok, err = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-empty-reset",
        datasetId = rec.datasetId,
        guildKey = "club:42",
        resetOperationId = "",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 1,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextRecordCount = 0,
    })
    assertEq(ok, false, "new-goal empty reset rejected")
    assertEq(err, "invalid_reset_operation", "empty reset invalid_reset_operation")

    ok, err = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-mismatch-reset",
        datasetId = rec.datasetId,
        guildKey = "club:42",
        resetOperationId = "other-id",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 1,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextRecordCount = 0,
    })
    assertEq(ok, false, "new-goal mismatched reset rejected")
    assertEq(err, "campaign_id_mismatch", "campaign_id_mismatch for reset")

    ok, err = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-tab9",
        datasetId = rec.datasetId,
        guildKey = "club:42",
        resetOperationId = "camp-tab9",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 1,
        bankTabAtStart = 9,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextRecordCount = 0,
    })
    assertEq(ok, false, "bankTabAtStart 9 rejected")
    assertEq(err, "invalid_bank_tab", "invalid_bank_tab for tab 9")

    -- legacy-preserved may omit resetOperationId and bankTabAtStart
    ok, err = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "legacy-1",
        datasetId = rec.datasetId,
        guildKey = "club:42",
        resetOperationId = nil,
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = nil,
        bankTabAtStart = nil,
        boundaryVersion = 1,
        boundaryKind = "legacy-preserved",
        contextStatus = "unavailable",
        contextRecordCount = 0,
    })
    assertEq(ok, true, "legacy-preserved without reset preserved")

    -- Mismatched embedded campaignId under map key
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    rec = GS:GetCurrentRecord()
    rec.campaigns["A"] = {
        schemaVersion = 1,
        campaignId = "B",
        datasetId = rec.datasetId,
        guildKey = "club:42",
        resetOperationId = "B",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 1,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextRecordCount = 0,
    }
    rec.currentCampaignId = "A"
    local exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "key/header mismatch keeps record unavailable")
    assertEq(reason, "campaign_id_mismatch", "campaign_id_mismatch for embedded id")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].currentCampaignId, "A",
        "malformed campaign pointer preserved")

    -- Dangling currentCampaignId
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    SpectrumFederationDB.guildSupplies.guilds["club:42"].currentCampaignId = "missing"
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "dangling currentCampaignId unavailable")
    assertEq(reason, "dangling_campaign", "dangling_campaign reason")
end

-- R11) Attribution bind + exact duplicate after self-lockout / demotion
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Carol-Garona", "Player-1-Carol", 3)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local op = GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 2)
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "restrictive threshold accepted")
    local status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "duplicate", "exact retry after self-lockout is duplicate")
    assertEq(reason, "duplicate", "duplicate reason after self-lockout")

    -- Tampered actorName with correct GUID rejected before retention
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    op = GS:NewConfigOperation("set-bank-tab", "bankTab", 3)
    op.actorName = "Eve-Garona"
    status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "rejected", "tampered actorName rejected")
    assertEq(reason, "unauthorized", "unauthorized for tampered name")
    assertNil(GS:GetCurrentRecord().operations.pending[op.id], "no pending retention for bad name")
    assertNil(GS:GetCurrentRecord().operations.records[op.id], "no accepted retention for bad name")

    -- Confirmation demotion: exact accepted retry without edit rank
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Carol-Garona", "Player-1-Carol", 3)
    GS:CreateStagedRecord()
    local conf = GS:NewConfirmationOperation({ recordId = "cand-dup2", contentFingerprint = "fp-dup2" })
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "accepted", "confirm accepted")
    -- Demote Carol below threshold
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    local demote = GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 2)
    assertEq(GS:ApplyStagedConfigOperation(demote), "accepted", "GM demotes threshold")
    setPlayer("Carol-Garona", "Player-1-Carol", 3)
    status, reason = GS:ApplyStagedConfirmationOperation(conf)
    assertEq(status, "duplicate", "demoted confirm exact retry is duplicate")
    assertEq(reason, "duplicate", "duplicate after demotion")

    -- Changed-body negative still requires authority
    local clash = {}
    for k, v in pairs(conf) do clash[k] = v end
    clash.timestamp = (tonumber(conf.timestamp) or 1) + 5
    status, reason = GS:ApplyStagedConfirmationOperation(clash)
    assertEq(status, "rejected", "changed-body confirm rejected without edit")
    assertEq(reason, "unauthorized", "unauthorized for changed body after demotion")
end

-- R12) Snapshot bounds + batched originalIds validation
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()

    local conf, st, err = GS:NewConfirmationOperation({
        records = { { id = "a", contentFingerprint = "fp" } },
        contentFingerprint = "fp",
        originalIds = { false },
    })
    assertEq(st, "rejected", "false originalId rejected at prepare")
    assertTrue(err == "invalid_candidate_ref" or err == "invalid_candidate_batch",
        "invalid candidate reason for false originalId")

    conf, st, err = GS:NewConfirmationOperation({
        recordId = "single",
        contentFingerprint = "fp2",
        originalIds = { "" },
    })
    assertEq(st, "rejected", "empty originalId rejected")

    conf, st, err = GS:NewConfirmationOperation({
        records = { { id = "a", contentFingerprint = "fp3" } },
        contentFingerprint = "fp3",
        originalIds = { string.rep("z", GS.MAX_OPERATION_ID + 1) },
    })
    assertEq(st, "rejected", "oversized originalId rejected")

    -- Supported batch still works
    local ids = {}
    for i = 1, 16 do ids[i] = "txn-" .. i end
    conf, st = GS:NewConfirmationOperation({
        records = {
            { id = "r1", contentFingerprint = "fp-batch" },
            { id = "r2", contentFingerprint = "fp-batch" },
        },
        contentFingerprint = "fp-batch",
        originalIds = ids,
    })
    assertEq(st, "accepted", "supported confirmation batch prepares")
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "accepted", "supported batch admits")

    -- Wide scalar map rejected without durable mutation
    local op = GS:NewConfigOperation("set-bank-tab", "bankTab", 2)
    local wide = {}
    for i = 1, 200 do wide["k" .. i] = i end
    -- Inject oversized nested value through a crafted confirm-sized payload on config:
    -- snapshot whitelist only copies known fields; craft via candidate-like oversize string.
    op.actorName = string.rep("n", 9000)
    local beforeTab = GS:GetCurrentRecord().accounting._consumables.bankTab
    status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "rejected", "oversized string snapshot rejected")
    assertTrue(reason == "snapshot_string_too_large" or reason == "invalid_actor",
        "bounded rejection reason for long string")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, beforeTab, "no durable mutation")
end

-- R13) Retained ops store shape + accepted cap without trusting #order alone
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.operations.pending["bad"] = true
    local exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "pending=true keeps record unavailable")
    assertEq(reason, "invalid_operations", "invalid_operations for pending=true")
    assertEq(raw.operations.pending["bad"], true, "corrupt pending preserved")

    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    -- Short order + large records map: structurally inconsistent
    raw.operations.records["only"] = { id = "only", kind = "set-bank-tab" }
    raw.operations.order = {}
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "records/order mismatch unavailable")
    assertEq(reason, "invalid_operations", "invalid_operations for order mismatch")

    -- Cap fixture: structurally valid full accepted store rejects another admit
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()
    local ops = record.operations
    for i = 1, GS.MAX_ACCEPTED_OPERATIONS do
        local id = "acc-" .. i
        ops.records[id] = { id = id, kind = "set-bank-tab", target = "bankTab", value = 1 }
        ops.order[i] = id
    end
    assertEq(GS:GetCurrentRecord() ~= nil, true, "full structurally valid store readable")
    local op = GS:NewConfigOperation("set-bank-tab", "bankTab", 4)
    status, reason = GS:ApplyStagedConfigOperation(op)
    assertEq(status, "rejected", "accepted cap rejects new admit")
    assertEq(reason, "full", "full reason at accepted cap")
    assertNil(ops.records[op.id], "no partial accepted mutation at cap")
end

-- R14) Cold roster demand nudge (throttled) + idle transport
do
    resetDb()
    GS:Initialize(SpectrumFederationDB)
    local savedMembers = world.guild.members
    world.guild.members = {}
    world.rosterRequests = 0
    if GG._demandRoster then GG._demandRoster.lastRequestAt = nil end
    local member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "cold roster returns nil")
    assertEq(reason, "roster_incomplete", "roster_incomplete on cold cache")
    assertEq(world.rosterRequests, 1, "demand-driven roster request once")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertEq(reason, "roster_incomplete", "still incomplete")
    assertEq(world.rosterRequests, 1, "throttled; no spam on nested reads")
    world.time = world.time + 3
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertEq(world.rosterRequests, 2, "request allowed after throttle interval")
    assertEq(GG.HasActiveProvider(), false, "still zero providers")
    assertEq(GG._guild.listening, false, "no permanent listeners")
    assertEq(GG._guild.ready, false, "transport not marked ready")
    world.guild.members = savedMembers
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "later native readiness resolves")
    assertEq(member.guid, "Player-1-Alice", "member guid after roster present")
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
