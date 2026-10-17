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
    frames = {},
    framesByName = {},
}

function GetTime() return world.time end
function time() return math.floor(world.time) end
function GetServerTime() return math.floor(world.time) end
-- WoW provides date(); Lua 5.1 tests map it to os.date.
function date(fmt, ts)
    return os.date(fmt, ts)
end
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

local function flushTimers()
    local progressed = true
    while progressed do
        progressed = false
        local i = 1
        while i <= #timers do
            local t = timers[i]
            if t.at <= world.time then
                table.remove(timers, i)
                t.fn()
                progressed = true
            else
                i = i + 1
            end
        end
    end
end

function CreateFrame(_, name)
    local f = {
        name = name,
        events = {},
        RegisterEvent = function(self, e) self.events[e] = true end,
        UnregisterAllEvents = function(self) self.events = {} end,
        SetScript = function(self, _, fn) self._onEvent = fn end,
    }
    world.frames[#world.frames + 1] = f
    if type(name) == "string" and name ~= "" then
        world.framesByName[name] = f
    end
    return f
end

local function fireEvent(event)
    for _, f in ipairs(world.frames) do
        if f.events[event] and f._onEvent then
            f._onEvent(f, event)
        end
    end
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
    ValidGoal = function(value)
        local goal = tonumber(value)
        if not goal or goal ~= goal or goal == math.huge or goal == -math.huge then
            return nil
        end
        if goal ~= math.floor(goal) or goal < 0 or goal > 100000 then
            return nil
        end
        return goal
    end,
    ItemIdFromText = function(text)
        local n = tonumber(text)
        if n and n == math.floor(n) and n > 0 then return n end
        if type(text) == "string" then
            local id = text:match("item:(%d+)")
            if id then return tonumber(id) end
        end
        return nil
    end,
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
loadModule("SpectrumFederation/modules/GuildSupplies/Campaigns.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Admission.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Gossip.lua")

-- Minimal provider registry stub so EnsureGossipProvider can register without the
-- full engine. 3A multi-client tests exercise ValidateAndApply / AdmitRemote*.
do
    local providers = { byId = {}, order = {}, activeCount = 0 }
    SF.GuildGossip._providers = providers
    SF.GuildGossip.CreateIndex = SF.GuildGossip.CreateIndex or function()
        return { buildComplete = false, dirty = true, buckets = {} }
    end
    SF.GuildGossip.RegisterProvider = function(spec)
        if type(spec) ~= "table" or type(spec.id) ~= "string" then
            return false, "invalid_spec"
        end
        local entry = {
            id = spec.id,
            api = spec,
            enabled = spec.enabled and true or false,
            ready = spec.ready ~= false,
            index = SF.GuildGossip.CreateIndex(),
        }
        if not providers.byId[spec.id] then
            providers.order[#providers.order + 1] = spec.id
        end
        providers.byId[spec.id] = entry
        providers.activeCount = 0
        for _, id in ipairs(providers.order) do
            local p = providers.byId[id]
            if p and p.enabled and p.ready then
                providers.activeCount = providers.activeCount + 1
            end
        end
        return true, entry
    end
    SF.GuildGossip.UnregisterProvider = function(id)
        providers.byId[tostring(id or "")] = nil
    end
    SF.GuildGossip.SetProviderEnabled = function(id, enabled)
        local e = providers.byId[tostring(id or "")]
        if e then e.enabled = enabled and true or false end
        return true
    end
    SF.GuildGossip.GetProvider = function(id)
        return providers.byId[tostring(id or "")]
    end
    SF.GuildGossip.NotifyProviderChanged = function(id)
        world.notifyChanged = (world.notifyChanged or 0) + 1
        world.lastNotifyId = id
    end
    SF.GuildGossip.IndexUpsert = function() return true end
    SF.GuildGossip.BumpIndexEpoch = function() end
    SF.GuildGossip.MarkWorkPending = function() end
    SF.GuildGossip._RecountActiveProviders = function() end
    SF.GuildGossip.SyncGuildAdapterLifecycle = function() end
    SF.GuildGossip.GetGuildScopeId = function()
        if world.guild.inGuild and world.guild.clubId then
            return "club:" .. tostring(world.guild.clubId)
        end
    end
    -- Replace the idle stub with the real active-count check once providers exist.
    SF.GuildGossip.HasActiveProvider = function()
        return (providers.activeCount or 0) > 0
    end
end

local GS = SF.GuildSupplies
local GG = SF.GuildGossip

local function resetDemandRoster()
    world.rosterRequests = 0
    timers = {}
    if GG._demandRoster then
        GG._demandRoster.lastRequestAt = nil
        GG._demandRoster.boundClubId = nil
        GG._demandRoster.pendingClubId = nil
        GG._demandRoster.waitGeneration = (tonumber(GG._demandRoster.waitGeneration) or 0) + 1
        GG._demandRoster.waitActive = false
        local wf = GG._demandRoster.waitFrame
        if wf then
            if wf.UnregisterAllEvents then wf:UnregisterAllEvents() end
            if wf.SetScript then wf:SetScript("OnEvent", nil) end
        end
        GG._demandRoster.staleFingerprint = nil
    end
end

--- Complete the temporary demand roster wait for the current club (test helper).
local function settleRoster()
    if not world.guild.inGuild or world.guild.clubId == nil or world.guild.clubId == 0 then
        return
    end
    if #(world.guild.members or {}) <= 0 then
        return
    end
    local clubId = tostring(world.guild.clubId)
    if GG._demandRoster and GG._demandRoster.boundClubId == clubId then
        return
    end
    GG.GetGuildRanks()
    fireEvent("GUILD_ROSTER_UPDATE")
end

--- Simulate /reload clearing runtime demand-roster state while SV/world persist.
local function simulateRuntimeReload()
    resetDemandRoster()
end

local function resetDb()
    SpectrumFederationDB = {}
    GS._db = nil
    GS._root = nil
    GS._rootValid = false
    GS._rootReason = "not_initialized"
    GS._handleGeneration = 0
    GS._lastGuildKey = nil
    GS._adoptionEpoch = 0
    GS._adoption = nil
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    world.notifyChanged = 0
    world.chat = {}
    world.prints = {}
    world.debugLogs = {}
    world.unitName = "Alice"
    world.unitGuid = "Player-1-Alice"
    resetDemandRoster()
end

local function initGS(opts)
    opts = opts or {}
    local ok, reason = GS:Initialize(SpectrumFederationDB)
    if opts.settle ~= false then
        settleRoster()
    end
    return ok, reason
end

--- #386: campaign-owned items require an active campaign.
local function startCampaign()
    local op, st, err = GS:NewCampaignOperation()
    assertEq(st, "accepted", "campaign op prepared: " .. tostring(err))
    assertTrue(op ~= nil, "campaign op present")
    local status, reason = GS:ApplyStagedCampaignOperation(op)
    assertEq(status, "accepted", "campaign started: " .. tostring(reason))
    return op
end

local function minimalValidBankTabBody(id, datasetId, value)
    return {
        schemaVersion = 1,
        id = id,
        guildKey = "club:42",
        datasetId = datasetId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = value or 1,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 1,
        baseTargetRevision = datasetId,
        basePolicyRevision = datasetId,
    }
end

local function minimalValidConfirmBody(id, datasetId)
    return {
        schemaVersion = 1,
        id = id,
        guildKey = "club:42",
        datasetId = datasetId,
        kind = "confirm-candidate",
        candidateRef = {
            recordId = "cand-1",
            contentFingerprint = "fp-1",
        },
        contentFingerprint = "fp-1",
        campaignId = nil,
        basePolicyRevision = datasetId,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 1,
    }
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
    local ok = initGS()
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
    initGS()
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
    initGS()
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
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local a = GS:GetCurrentRecord()
    assertTrue(a ~= nil, "guild A record")
    local datasetA = a.datasetId

    world.guild.clubId = 99
    world.guild.name = "OtherGuild"
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    -- Club changed first while native roster still shows prior guild rows.
    local ctxB = GS:GetCurrentContext()
    assertEq(ctxB.ready, false, "stale roster keeps new club unready")
    assertEq(ctxB.reason, "roster_incomplete", "roster_incomplete until roster update event")
    -- Content alone must not authenticate; GUILD_ROSTER_UPDATE completes the wait.
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Zoe-Garona", guid = "Player-1-Zoe", rankOrder = 2, online = true },
    }
    assertEq(GS:GetCurrentContext().ready, false, "content change alone stays unready")
    fireEvent("GUILD_ROSTER_UPDATE")
    -- Same character, different guild — no leak of A
    local b, reason = GS:GetCurrentRecord()
    assertNil(b, "guild B not configured")
    assertEq(reason, "not_configured", "guild B not_configured")
    local recB, st = GS:CreateStagedRecord()
    assertEq(st, "accepted", "create guild B after roster update event")
    assertTrue(recB.datasetId ~= datasetA, "distinct dataset IDs")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"] ~= nil, true, "guild A retained")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:99"] ~= nil, true, "guild B present")

    world.guild.clubId = 42
    world.guild.name = "Spectrum"
    -- Again: identity flips before a roster update event for A.
    assertEq(GS:GetCurrentContext().ready, false, "return to A unready before roster event")
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
        { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true },
        { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
    }
    fireEvent("GUILD_ROSTER_UPDATE")
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
    local ok, reason = initGS()
    assertEq(ok, false, "future schema not accepted")
    assertEq(reason, "unsupported_schema", "unsupported_schema reason")
    assertEq(SpectrumFederationDB.guildSupplies.schemaVersion, 99, "future root preserved")

    resetDb()
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
    world.guild.clubId = 42
    world.guild.ranks = { "Guild Master", "Member" }
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
    }
    setPlayer("Bob-Garona", "Player-1-Bob", 2)
    local _, st, err = GS:CreateStagedRecord()
    assertEq(st, "rejected", "non-GM cannot init short rank list")
    assertEq(err, "policy_requires_gm", "non-GM policy_requires_gm")
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    _, st, err = GS:CreateStagedRecord()
    assertEq(st, "rejected", "GM cannot invent missing default position 3")
    assertEq(err, "threshold_unselected", "threshold_unselected without selection")
    _, st, err = GS:CreateStagedRecord(3)
    assertEq(st, "rejected", "GM cannot select missing rank 3")
    assertEq(err, "invalid_editor_rank_position", "invalid_editor_rank_position for missing rank")
    _, st, err = GS:CreateStagedRecord(0)
    assertEq(st, "rejected", "GM cannot select rank 0")
    local rec
    rec, st, err = GS:CreateStagedRecord(2)
    assertEq(st, "accepted", "GM selects existing threshold 2: " .. tostring(err))
    assertEq(rec.permission.editorRankPosition, 2, "selected threshold stored")
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
    initGS()
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
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    -- Bank tab remains shared without a campaign.
    local opTabEarly, stTabEarly = GS:NewConfigOperation("set-bank-tab", "bankTab", 1)
    assertEq(stTabEarly, "accepted", "bank tab before campaign prepared")
    assertEq(GS:ApplyStagedConfigOperation(opTabEarly), "accepted", "bank tab before campaign applied")
    -- Items require a campaign (#386).
    local noCamp, noCampSt, noCampReason = GS:NewConfigOperation(
        "set-requested-item", { itemId = 1 }, { itemId = 1, goal = 1 })
    assertNil(noCamp, "item prepare blocked without campaign")
    assertEq(noCampSt, "rejected", "item prepare rejected")
    assertEq(noCampReason, "no_campaign", "no_campaign reason")
    startCampaign()

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
    initGS()
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
    initGS()
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
    assertTrue(reason == "wrong_guild" or reason == "stale_handle" or reason == "not_configured"
            or reason == "not_ready" or reason == "roster_incomplete",
        "guild-change reason=" .. tostring(reason))
    world.guild.clubId = 42
    -- Restore roster trust for later tests after the club flip above.
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
        { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true },
        { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
    }
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
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()
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
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()
    local op = GS:NewConfigOperation("set-requested-item", { itemId = 7 }, { itemId = 7, goal = 3 })
    GS:ApplyStagedConfigOperation(op)
    local saved = SpectrumFederationDB
    -- Simulate reload
    GS._db = nil
    GS._root = nil
    GS._rootValid = false
    SpectrumFederationDB = saved
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
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
    startCampaign()
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
    initGS()
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
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()
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
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()
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
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()

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
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
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
    initGS()
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

    -- Oversized string rejected without durable mutation (budget is 49,152 bytes).
    local op = GS:NewConfigOperation("set-bank-tab", "bankTab", 2)
    op.actorName = string.rep("n", GS.MAX_SNAPSHOT_STRING_BYTES + 1)
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
    initGS()
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
    initGS()
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
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()
    local ops = record.operations
    local datasetId = record.datasetId
    for i = 1, GS.MAX_ACCEPTED_OPERATIONS do
        local id = "acc-" .. i
        ops.records[id] = minimalValidBankTabBody(id, datasetId, 1)
        ops.order[i] = id
    end
    -- Clear heads so historical bank-tab bodies do not need matching head keys.
    ops.heads = {}
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
    initGS({ settle = false })
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
    -- #387 registers the staged config provider on Initialize; demand-driven
    -- roster APIs must still work and must not arm permanent idle listeners here
    -- (SyncGuildAdapterLifecycle is stubbed in this harness).
    assertEq(GG._guild.listening, false, "no permanent listeners")
    assertEq(GG._guild.ready, false, "transport not marked ready")
    world.guild.members = savedMembers
    -- Population alone is not freshness after a cold wait; the update event binds.
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "still incomplete until roster update event")
    fireEvent("GUILD_ROSTER_UPDATE")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "later native readiness resolves after event")
    assertEq(member.guid, "Player-1-Alice", "member guid after roster present")
    assertEq(GG._demandRoster.waitActive, false, "cold wait cleaned up after event")
end

-- R15) Max confirmation batch + over-limit + XOR candidateRef + nested campaign
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()

    -- Both recordId and records rejected (exactly one form).
    local conf, st, err = GS:NewConfirmationOperation({
        recordId = "single",
        records = { { id = "r1", contentFingerprint = "fp-xor" } },
        contentFingerprint = "fp-xor",
    })
    assertEq(st, "rejected", "both candidate forms rejected at prepare")
    assertEq(err, "invalid_candidate_ref", "invalid_candidate_ref for both forms")

    conf, st, err = GS:NewConfirmationOperation({
        contentFingerprint = "fp-neither",
    })
    assertEq(st, "rejected", "neither candidate form rejected")
    assertEq(err, "invalid_candidate_ref", "invalid_candidate_ref for neither form")

    -- Nested campaign mismatch vs envelope (crafted after prepare).
    conf, st = GS:NewConfirmationOperation({
        recordId = "camp-bind",
        contentFingerprint = "fp-camp",
        campaignId = "camp-A",
    })
    assertEq(st, "accepted", "nested campaign prepare when matching envelope source")
    conf.campaignId = "camp-B"
    local ok, verr = GS:ValidateConfirmationOperation(conf)
    assertEq(ok, false, "nested/envelope campaign mismatch rejected")
    assertEq(verr, "invalid_campaign", "invalid_campaign for nested mismatch")
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "rejected", "mismatch not admitted")
    assertNil(GS:GetCurrentRecord().operations.records[conf.id], "no retention on campaign mismatch")

    -- Malformed nested campaignId type
    conf, st, err = GS:NewConfirmationOperation({
        recordId = "camp-bad",
        contentFingerprint = "fp-camp-bad",
        campaignId = false,
    })
    assertEq(st, "rejected", "non-string nested campaignId rejected")
    assertEq(err, "invalid_candidate_ref", "invalid_candidate_ref for bad campaignId")

    -- Maximum supported batch with realistic IDs/fingerprints/originalIds.
    local rows, oids = {}, {}
    local fp = "fp-" .. string.rep("a", 40)
    for i = 1, GS.MAX_CONFIRMATION_BATCH do
        local id = string.format("gs1:Player-1-Alice:%s:%d", string.rep("b", 24), i)
        rows[i] = { id = id, contentFingerprint = fp }
        oids[i] = string.format("txn:%s:%d", string.rep("c", 32), i)
    end
    conf, st, err = GS:NewConfirmationOperation({
        records = rows,
        contentFingerprint = fp,
        originalIds = oids,
    })
    assertEq(st, "accepted", "max confirmation batch prepares: " .. tostring(err))
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "accepted", "max confirmation batch admits")
    assertEq(GS:GetCurrentRecord().confirmationRefs[1], conf.id, "max batch confirmationRefs id")

    -- Just over limit rejected at prepare; no durable mutation.
    local overRows = {}
    for i = 1, GS.MAX_CONFIRMATION_BATCH + 1 do
        overRows[i] = { id = "over-" .. i, contentFingerprint = "fp-over" }
    end
    local beforeRefs = #GS:GetCurrentRecord().confirmationRefs
    conf, st, err = GS:NewConfirmationOperation({
        records = overRows,
        contentFingerprint = "fp-over",
    })
    assertEq(st, "rejected", "over-limit batch rejected at prepare")
    assertEq(err, "invalid_candidate_batch", "invalid_candidate_batch for 65 records")
    assertEq(#GS:GetCurrentRecord().confirmationRefs, beforeRefs, "no refs growth on over-limit")
end

-- R16) Heads, confirmationRefs, required body.id
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]

    -- Ghost head
    raw.operations.heads["item:1"] = "ghost"
    local exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "ghost head keeps record unavailable")
    assertEq(reason, "invalid_operations", "invalid_operations for ghost head")
    assertEq(raw.operations.heads["item:1"], "ghost", "ghost head preserved")

    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    local op = GS:NewConfigOperation("set-bank-tab", "bankTab", 2)
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "bank tab for wrong-target head fixture")
    raw.operations.heads["item:99"] = op.id
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "wrong-target head unavailable")
    assertEq(reason, "invalid_operations", "invalid_operations for wrong-target head")

    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.operations.heads["config:bankTab"] = true
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "non-string head unavailable")
    assertEq(reason, "invalid_operations", "invalid_operations for non-string head")

    -- Missing body.id on accepted
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.operations.records["acc-1"] = { kind = "set-bank-tab", target = "bankTab", value = 1 }
    raw.operations.order[1] = "acc-1"
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "missing accepted body.id unavailable")
    assertEq(reason, "invalid_operations", "invalid_operations for missing body.id")
    assertEq(raw.operations.records["acc-1"].id, nil, "missing body.id preserved")

    -- Mismatched pending body.id
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.operations.pending["p1"] = {
        id = "p1",
        reason = "stale_base",
        body = { id = "other", kind = "set-bank-tab" },
        at = 1,
    }
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "mismatched pending body.id unavailable")
    assertEq(reason, "invalid_operations", "invalid_operations for pending body.id")
    assertEq(raw.operations.pending["p1"].body.id, "other", "mismatched pending preserved")

    -- confirmationRefs: dangling / wrong kind / sparse / duplicate
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.confirmationRefs = { "missing-confirm" }
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "dangling confirmationRefs unavailable")
    assertEq(reason, "invalid_confirmation_refs", "invalid_confirmation_refs dangling")

    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    local bankOp = GS:NewConfigOperation("set-bank-tab", "bankTab", 3)
    assertEq(GS:ApplyStagedConfigOperation(bankOp), "accepted", "config for wrong-kind refs")
    raw.confirmationRefs = { bankOp.id }
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "wrong-kind confirmationRefs unavailable")
    assertEq(reason, "invalid_confirmation_refs", "invalid_confirmation_refs wrong kind")

    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    local conf = GS:NewConfirmationOperation({ recordId = "ref-ok", contentFingerprint = "fp-ref" })
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "accepted", "confirm for refs fixture")
    raw.confirmationRefs[2] = conf.id
    raw.confirmationRefs[1] = nil
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "sparse confirmationRefs unavailable")
    assertEq(reason, "invalid_confirmation_refs", "invalid_confirmation_refs sparse")

    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    conf = GS:NewConfirmationOperation({ recordId = "ref-dup", contentFingerprint = "fp-dup-ref" })
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "accepted", "confirm for dup refs")
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.confirmationRefs = { conf.id, conf.id }
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "duplicate confirmationRefs unavailable")
    assertEq(reason, "invalid_confirmation_refs", "invalid_confirmation_refs duplicate")
end

-- R17) Writer nonce recovery + boundary attribution/capture metadata
do
    resetDb()
    SpectrumFederationDB = {
        guildSupplies = {
            schemaVersion = 1,
            localWriter = { nonce = string.rep("z", 500), nextSeq = 1 },
            guilds = {
                ["club:42"] = {
                    schemaVersion = 1,
                    activation = "staged",
                    datasetId = "gs1:Player-1-Alice:aaaaaaaaaaaaaaaaaaaaaaaa:1",
                    permission = { editorRankPosition = 3, revisionId = "gs1:Player-1-Alice:aaaaaaaaaaaaaaaaaaaaaaaa:1" },
                    currentCampaignId = nil,
                    campaigns = {},
                    accounting = {
                        _consumables = {
                            guild = { guid = "42", name = "Spectrum", realm = "Garona" },
                            bankTab = nil,
                            requestedItems = {},
                            generation = 0,
                            configSeq = 0,
                            eventSeq = 0,
                            eligibility = {},
                            txnRegistry = {},
                        },
                        _consumableEvents = {},
                        _consumableEventArchive = {},
                    },
                    observations = { byCampaign = {} },
                    operations = { records = {}, order = {}, heads = {}, pending = {}, conflicts = {} },
                    confirmationRefs = {},
                    migration = nil,
                },
            },
        },
    }
    local oldDataset = SpectrumFederationDB.guildSupplies.guilds["club:42"].datasetId
    local ok = initGS()
    assertEq(ok, true, "malformed writer recovers on otherwise valid root")
    local nonce = SpectrumFederationDB.guildSupplies.localWriter.nonce
    assertEq(#nonce, 24, "recovered nonce is 24 hex")
    assertTrue(nonce:match("^[0-9a-fA-F]+$") ~= nil, "recovered nonce hex")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].datasetId, oldDataset,
        "old dataset/record preserved across writer recovery")
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    local rec = GS:GetCurrentRecord()
    assertTrue(rec ~= nil, "recovered root exposes preserved guild record")
    local newId = GS:_AllocateOperationId("Player-1-Alice")
    assertTrue(newId ~= nil and newId:find(nonce, 1, true) ~= nil, "new IDs use fresh nonce")

    -- Valid reload keeps nonce
    local kept = SpectrumFederationDB.guildSupplies.localWriter.nonce
    local seq = SpectrumFederationDB.guildSupplies.localWriter.nextSeq
    initGS()
    assertEq(SpectrumFederationDB.guildSupplies.localWriter.nonce, kept, "valid nonce survives reload")
    assertEq(SpectrumFederationDB.guildSupplies.localWriter.nextSeq, seq, "valid nextSeq survives reload")

    -- Exhaustion rotates to a fresh nonce without rewriting old records
    SpectrumFederationDB.guildSupplies.localWriter.nextSeq = GS.MAX_EVENT_SEQ + 1
    local rotated = GS:_EnsureWritableWriter()
    assertTrue(rotated.nonce ~= kept, "exhaustion rotates nonce")
    assertEq(rotated.nextSeq, 1, "fresh writer starts at 1")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].datasetId, oldDataset,
        "exhaustion preserves guild records")

    -- Unsupported schema still unavailable (no writer/domain normalize)
    resetDb()
    SpectrumFederationDB = {
        guildSupplies = {
            schemaVersion = 99,
            localWriter = { nonce = string.rep("f", 500), nextSeq = 1 },
            guilds = { ["club:1"] = { schemaVersion = 99 } },
        },
    }
    ok = initGS()
    assertEq(ok, false, "unsupported schema remains unavailable")
    assertEq(SpectrumFederationDB.guildSupplies.localWriter.nonce, string.rep("f", 500),
        "unsupported root writer not rewritten")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:1"].schemaVersion, 99,
        "unsupported guild preserved")

    -- Boundary attribution / capture metadata
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()

    local okStore, storeErr = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-no-author",
        datasetId = record.datasetId,
        guildKey = "club:42",
        resetOperationId = "camp-no-author",
        createdByGuid = nil,
        createdByName = nil,
        startedAt = 10,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextRecordCount = 0,
    })
    assertEq(okStore, false, "new-goal missing authors rejected")
    assertEq(storeErr, "invalid_attribution", "invalid_attribution for missing authors")

    okStore, storeErr = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-captured-bad",
        datasetId = record.datasetId,
        guildKey = "club:42",
        resetOperationId = "camp-captured-bad",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 10,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "captured",
        contextObservedAt = nil,
        contextRecordCount = 2,
    })
    assertEq(okStore, false, "captured without observedAt rejected")
    assertEq(storeErr, "invalid_context_observed_at", "invalid_context_observed_at")

    okStore, storeErr = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-empty-nonzero",
        datasetId = record.datasetId,
        guildKey = "club:42",
        resetOperationId = "camp-empty-nonzero",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 10,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "empty",
        contextObservedAt = 11,
        contextRecordCount = 3,
    })
    assertEq(okStore, false, "empty with nonzero count rejected")
    assertEq(storeErr, "invalid_context_record_count", "invalid_context_record_count for empty")

    okStore, storeErr = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-unavail-ok",
        datasetId = record.datasetId,
        guildKey = "club:42",
        resetOperationId = "camp-unavail-ok",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 10,
        bankTabAtStart = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextObservedAt = nil,
        contextRecordCount = nil,
    })
    assertEq(okStore, true, "unavailable may omit observation evidence: " .. tostring(storeErr))

    okStore, storeErr = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "legacy-no-fabricate",
        datasetId = record.datasetId,
        guildKey = "club:42",
        resetOperationId = nil,
        createdByGuid = nil,
        createdByName = nil,
        startedAt = nil,
        bankTabAtStart = nil,
        boundaryVersion = 1,
        boundaryKind = "legacy-preserved",
        contextStatus = "unavailable",
        contextObservedAt = nil,
        contextRecordCount = nil,
    })
    assertEq(okStore, true, "legacy-preserved without fabricated authors/timestamps: " .. tostring(storeErr))

    okStore, storeErr = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-captured-ok",
        datasetId = record.datasetId,
        guildKey = "club:42",
        resetOperationId = "camp-captured-ok",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 12,
        bankTabAtStart = 2,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "captured",
        contextObservedAt = 12,
        contextRecordCount = 4,
    })
    assertEq(okStore, true, "captured with evidence metadata accepted: " .. tostring(storeErr))
    local bound = GS:GetCurrentCampaignBoundary()
    assertEq(bound.contextRecordCount, 4, "captured count roundtrip")
    assertEq(bound.createdByName, "Alice-Garona", "captured author roundtrip")
end

-- R18) Canonical confirmation manifest rows + exact replay after reload
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()

    local conf, st, err = GS:NewConfirmationOperation({
        records = {
            {
                id = "r-extra",
                contentFingerprint = "fp-extra",
                extra = { a = { b = true } },
            },
        },
        contentFingerprint = "fp-extra",
        originalIds = { "txn-extra-1" },
    })
    assertEq(st, "accepted", "nested-extra prepare accepted after canonicalize: " .. tostring(err))
    assertNil(conf.candidateRef.records[1].extra, "prepared row strips nested extras")
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "accepted", "nested-extra admits as canonical")
    local stored = GS:GetCurrentRecord().operations.records[conf.id]
    assertNil(stored.candidateRef.records[1].extra, "durable row has no nested extras")

    -- Exact replay after reload
    local saved = SpectrumFederationDB
    GS._db = nil
    GS._root = nil
    GS._rootValid = false
    SpectrumFederationDB = saved
    assertEq(initGS(), true, "reload after confirm")
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    local status, reason = GS:ApplyStagedConfirmationOperation(conf)
    assertEq(status, "duplicate", "exact replay after reload is duplicate")
    assertEq(reason, "duplicate", "duplicate reason after reload")

    -- Genuinely changed body still conflicts
    local clash = {}
    for k, v in pairs(conf) do clash[k] = v end
    clash.timestamp = (tonumber(conf.timestamp) or 1) + 1
    status, reason = GS:ApplyStagedConfirmationOperation(clash)
    assertEq(status, "rejected", "changed-body confirmation rejected")
    assertEq(reason, "id_conflict", "id_conflict for changed body")

    -- Max batch still supported
    local rows, oids = {}, {}
    local fp = "fp-r18-" .. string.rep("d", 32)
    for i = 1, GS.MAX_CONFIRMATION_BATCH do
        rows[i] = {
            id = string.format("gs1:Player-1-Alice:%s:%d", string.rep("e", 24), i),
            contentFingerprint = fp,
            noise = { nested = true },
        }
        oids[i] = "oid-" .. i
    end
    conf, st, err = GS:NewConfirmationOperation({
        records = rows,
        contentFingerprint = fp,
        originalIds = oids,
    })
    assertEq(st, "accepted", "max batch with row noise still prepares: " .. tostring(err))
    assertNil(conf.candidateRef.records[1].noise, "max-batch rows canonicalized")
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "accepted", "max batch with noise admits")
end

-- R19) Finite campaign startedAt (reject inf/nan/negative; valid round-trip)
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()

    local function tryStart(startedAt)
        return GS:_StoreCampaignBoundaryForTests({
            schemaVersion = 1,
            campaignId = "camp-start-" .. tostring(startedAt),
            datasetId = record.datasetId,
            guildKey = "club:42",
            resetOperationId = "camp-start-" .. tostring(startedAt),
            createdByGuid = "Player-1-Alice",
            createdByName = "Alice-Garona",
            startedAt = startedAt,
            bankTabAtStart = 1,
            boundaryVersion = 1,
            boundaryKind = "new-goal",
            contextStatus = "unavailable",
        })
    end

    local ok, err = tryStart(math.huge)
    assertEq(ok, false, "math.huge startedAt rejected")
    assertEq(err, "invalid_started_at", "invalid_started_at for infinity")
    ok, err = tryStart(0 / 0)
    assertEq(ok, false, "NaN startedAt rejected")
    assertEq(err, "invalid_started_at", "invalid_started_at for NaN")
    ok, err = tryStart(-1)
    assertEq(ok, false, "negative startedAt rejected")
    assertEq(err, "invalid_started_at", "invalid_started_at for negative")
    ok, err = tryStart(123456)
    assertEq(ok, true, "finite startedAt accepted: " .. tostring(err))
    assertEq(GS:GetCurrentCampaignBoundary().startedAt, 123456, "finite startedAt roundtrip")

    ok, err = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "legacy-inf",
        datasetId = record.datasetId,
        guildKey = "club:42",
        boundaryKind = "legacy-preserved",
        boundaryVersion = 1,
        contextStatus = "unavailable",
        startedAt = math.huge,
    })
    assertEq(ok, false, "legacy math.huge startedAt rejected")
    assertEq(err, "invalid_started_at", "legacy invalid_started_at for infinity")
    ok, err = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "legacy-absent-start",
        datasetId = record.datasetId,
        guildKey = "club:42",
        boundaryKind = "legacy-preserved",
        boundaryVersion = 1,
        contextStatus = "unavailable",
        startedAt = nil,
    })
    assertEq(ok, true, "legacy absent startedAt preserved: " .. tostring(err))
end

-- R20) Small-guild GM threshold selection + denials
do
    resetDb()
    initGS()
    world.guild.clubId = 42
    world.guild.ranks = { "Guild Master", "Member" }
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
    }
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.impersonationActive = true
    local _, st, err = GS:CreateStagedRecord(1)
    assertEq(st, "rejected", "preview denies small-guild create")
    assertEq(err, "preview_non_admin", "preview_non_admin for small guild")
    world.impersonationActive = false

    GS._db = nil
    GS._root = nil
    GS._rootValid = false
    -- unreadiness: clear club
    local savedClub = world.guild.clubId
    world.guild.clubId = nil
    _, st, err = GS:CreateStagedRecord(1)
    assertEq(st, "rejected", "missing club readiness denies create")
    assertTrue(err == "club_id_unavailable" or err == "not_ready", "readiness reason")
    world.guild.clubId = savedClub
    initGS()

    local rec
    rec, st, err = GS:CreateStagedRecord(1)
    assertEq(st, "accepted", "GM selects threshold 1: " .. tostring(err))
    assertEq(rec.permission.editorRankPosition, 1, "threshold 1 stored")
    assertNil(GS:CreateStagedRecord(1), "no allocate on second create / already configured")

    -- Ordinary ≥3 ranks still defaults to 3 and ignores selection
    resetDb()
    initGS()
    world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
        { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true },
        { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
    }
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    rec, st = GS:CreateStagedRecord(1)
    assertEq(st, "accepted", "ordinary create ignores explicit selection")
    assertEq(rec.permission.editorRankPosition, 3, "ordinary default remains 3")
end

-- R21) Demand-driven roster scope after club identity change
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    local member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "initial roster trusted for club 42")
    assertEq(member.clubId, "42", "member labeled with club 42")
    GS:CreateStagedRecord()
    local op = GS:NewConfigOperation("set-bank-tab", "bankTab", 2)
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "writes work when roster scoped")

    -- New club identity, same stale nonempty roster rows.
    world.guild.clubId = 99
    world.guild.name = "OtherGuild"
    world.rosterRequests = 0
    if GG._demandRoster then GG._demandRoster.lastRequestAt = nil end
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "stale roster not trusted for new club")
    assertEq(reason, "roster_incomplete", "roster_incomplete during scope transition")
    assertTrue(world.rosterRequests >= 1, "demand roster request on scope change")
    assertEq(GG._demandRoster.waitActive, true, "temporary GUILD_ROSTER_UPDATE wait active")
    local ctx = GS:GetCurrentContext()
    assertEq(ctx.ready, false, "context not ready during roster uncertainty")
    local newOp, newSt, newErr = GS:NewConfigOperation("set-bank-tab", "bankTab", 3)
    assertNil(newOp, "no op prepared during uncertainty")
    assertEq(newSt, "rejected", "rejected prepare during uncertainty")
    assertTrue(newErr == "roster_incomplete" or newErr == "not_ready" or newErr == "rank_unavailable",
        "uncertainty reason on prepare: " .. tostring(newErr))

    -- Content change alone must not authenticate stale rank data.
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Eve-Garona", guid = "Player-1-Eve", rankOrder = 2, online = true },
    }
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "content change alone does not bind new club")
    assertEq(reason, "roster_incomplete", "still incomplete without roster event")

    -- Recovery: GUILD_ROSTER_UPDATE completes the bounded wait.
    fireEvent("GUILD_ROSTER_UPDATE")
    assertEq(GG._demandRoster.waitActive, false, "wait cleaned up after event")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "roster trusted after update event: " .. tostring(reason))
    assertEq(member.clubId, "99", "member labeled with new club 99")
    ctx = GS:GetCurrentContext()
    assertEq(ctx.ready, true, "context ready after scoped roster recovery")
    local rec99, st99 = GS:CreateStagedRecord()
    assertEq(st99, "accepted", "can create staged record after roster recovery")
    assertEq(rec99.accounting._consumables.guild.guid, "99", "new guild accounting guid")

    -- restore default world guild for later isolation
    world.guild.clubId = 42
    world.guild.name = "Spectrum"
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
        { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true },
        { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
    }
    world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
end

-- R22) Requested-item value canonicalization at admission (nested extras / remove / replay)
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()

    local op = GS:NewConfigOperation("set-requested-item", { itemId = 501 }, {
        itemId = 501, goal = 7, extra = { a = { b = { c = { d = true } } } },
    })
    assertTrue(op ~= nil, "prepare strips nested extras from constructor value")
    assertNil(op.value.extra, "constructor value has no nested extras")
    assertEq(op.value.itemId, 501, "canonical itemId")
    assertEq(op.value.goal, 7, "canonical goal")
    assertEq(op.value.removed, false, "canonical removed=false")

    -- Caller re-poisons the draft between prepare and apply.
    op.value.extra = { a = { b = { c = { d = true } } } }
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "admit re-canonicalizes poisoned draft")
    local stored = GS:GetCurrentRecord().operations.records[op.id]
    assertNil(stored.value.extra, "durable body has no nested extras")
    assertEq(stored.value.goal, 7, "durable goal preserved")

    -- Exact replay after "reload" (re-read durable body shape) → duplicate.
    local replay = {
        schemaVersion = stored.schemaVersion,
        id = stored.id,
        guildKey = stored.guildKey,
        datasetId = stored.datasetId,
        kind = stored.kind,
        target = { itemId = stored.target.itemId },
        value = {
            itemId = stored.value.itemId,
            goal = stored.value.goal,
            removed = false,
            extra = { a = { b = { c = { d = true } } } },
        },
        baseTargetRevision = stored.baseTargetRevision,
        basePolicyRevision = stored.basePolicyRevision,
        baseCampaignId = stored.baseCampaignId,
        campaignId = stored.campaignId,
        actorGuid = stored.actorGuid,
        actorName = stored.actorName,
        timestamp = stored.timestamp,
    }
    local stReplay, reasonReplay = GS:ApplyStagedConfigOperation(replay)
    assertEq(stReplay, "duplicate", "exact replay with nested extras is duplicate: " .. tostring(reasonReplay))

    -- Genuine semantic change with same id → id_conflict (before removal).
    local conflict = {
        schemaVersion = stored.schemaVersion,
        id = stored.id,
        guildKey = stored.guildKey,
        datasetId = stored.datasetId,
        kind = "set-requested-item",
        target = { itemId = 501 },
        value = { itemId = 501, goal = 99, removed = false },
        baseTargetRevision = stored.baseTargetRevision,
        basePolicyRevision = stored.basePolicyRevision,
        baseCampaignId = stored.baseCampaignId,
        campaignId = stored.campaignId,
        actorGuid = stored.actorGuid,
        actorName = stored.actorName,
        timestamp = stored.timestamp + 1,
    }
    local stConflict, reasonConflict = GS:ApplyStagedConfigOperation(conflict)
    assertEq(stConflict, "rejected", "semantic change rejected")
    assertEq(reasonConflict, "id_conflict", "id_conflict for changed goal")

    -- Removal values also drop extras.
    local opRm = GS:NewConfigOperation("set-requested-item", { itemId = 501 }, {
        removed = true, noise = { x = { y = true } },
    })
    assertEq(opRm.value.removed, true, "removal canonical removed")
    assertNil(opRm.value.noise, "removal drops extras at prepare")
    opRm.value.noise = { x = { y = true } }
    assertEq(GS:ApplyStagedConfigOperation(opRm), "accepted", "removal admits after re-canonicalize")
    local storedRm = GS:GetCurrentRecord().operations.records[opRm.id]
    assertEq(storedRm.value.removed, true, "durable removal")
    assertNil(storedRm.value.noise, "durable removal has no extras")
    assertNil(storedRm.value.itemId, "removal omits itemId")
end

-- R23) Roster readiness: unbound first wait, identical refresh, retarget, timeout
do
    resetDb()
    initGS({ settle = false })
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42

    -- Unbound first observation with nonempty stale-capable data starts a wait.
    local member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "first nonempty observation does not bind without refresh")
    assertEq(reason, "roster_incomplete", "incomplete until refresh event")
    assertEq(GG._demandRoster.waitActive, true, "wait started on unbound first observation")
    assertNil(GG._demandRoster.boundClubId, "not bound before event")
    local ctx = GS:GetCurrentContext()
    assertEq(ctx.ready, false, "privileged context unavailable before first refresh")
    local deniedOp, deniedSt = GS:NewConfigOperation("set-bank-tab", "bankTab", 1)
    assertNil(deniedOp, "no prepare before first refresh")
    assertEq(deniedSt, "rejected", "prepare rejected before first refresh")

    fireEvent("GUILD_ROSTER_UPDATE")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "first observation recovers after refresh event")
    assertEq(GG._demandRoster.boundClubId, "42", "bound to first club after event")
    assertEq(GG._demandRoster.waitActive, false, "wait cleaned after first refresh")

    -- Simulated /reload: runtime demand state clears; nonempty rows still need wait.
    simulateRuntimeReload()
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "reload leaves initial nonempty roster unbound")
    assertEq(reason, "roster_incomplete", "reload requires a new refresh wait")
    assertEq(GG._demandRoster.waitActive, true, "wait restarted after reload")
    fireEvent("GUILD_ROSTER_UPDATE")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "recovers after post-reload refresh")

    -- Stale nonempty after club change stays incomplete.
    local staleMembers = world.guild.members
    world.guild.clubId = 55
    world.rosterRequests = 0
    GG._demandRoster.lastRequestAt = nil
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "stale nonempty denied")
    assertEq(reason, "roster_incomplete", "incomplete while waiting")
    assertEq(GG._demandRoster.waitActive, true, "wait started for club 55")
    local waitFrame = world.framesByName["SFGuildGossipDemandRosterWait"]
    assertTrue(waitFrame ~= nil, "temporary wait frame created")
    assertEq(waitFrame.events["GUILD_ROSTER_UPDATE"], true, "wait registers GUILD_ROSTER_UPDATE")

    -- Identical refreshed roster must recover via event (no content change).
    world.guild.members = staleMembers
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "identical content alone still incomplete")
    fireEvent("GUILD_ROSTER_UPDATE")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "identical roster recovers after event: " .. tostring(reason))
    assertEq(member.clubId, "55", "bound to club 55")
    assertEq(GG._demandRoster.waitActive, false, "wait stopped after identical recovery")
    assertEq(waitFrame.events["GUILD_ROSTER_UPDATE"], nil, "event unregistered after completion")

    -- Another guild change while waiting retargets; stale event for old club must not bind.
    world.guild.clubId = 66
    GG._demandRoster.lastRequestAt = nil
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "club 66 incomplete while waiting")
    local genAt66 = GG._demandRoster.waitGeneration
    assertEq(GG._demandRoster.pendingClubId, "66", "pending retargeted to 66")
    world.guild.clubId = 77
    GG._demandRoster.lastRequestAt = nil
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "club 77 incomplete while waiting")
    assertEq(GG._demandRoster.pendingClubId, "77", "pending retargeted to 77")
    assertTrue(GG._demandRoster.waitGeneration ~= genAt66, "retarget bumps wait generation")
    fireEvent("GUILD_ROSTER_UPDATE")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "retargeted wait completes for current club")
    assertEq(member.clubId, "77", "bound to retargeted club 77")

    -- Unavailable/failed refresh cleanup: timeout terminates wait without binding.
    world.guild.clubId = 88
    GG._demandRoster.lastRequestAt = nil
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "club 88 incomplete")
    assertEq(GG._demandRoster.waitActive, true, "wait active before timeout")
    world.time = world.time + 11
    flushTimers()
    assertEq(GG._demandRoster.waitActive, false, "timeout clears waitActive")
    assertEq(GG._demandRoster.boundClubId, nil, "timeout does not bind")
    assertEq(GG._demandRoster.pendingClubId, "88", "pending retained fail-closed")
    waitFrame = world.framesByName["SFGuildGossipDemandRosterWait"]
    assertEq(waitFrame.events["GUILD_ROSTER_UPDATE"], nil, "timeout unregisters event")
    ctx = GS:GetCurrentContext()
    assertEq(ctx.ready, false, "not ready after timed-out wait")
    local op, st, err = GS:NewConfigOperation("set-bank-tab", "bankTab", 1)
    assertNil(op, "no prepare after timeout without refresh")
    assertEq(st, "rejected", "prepare rejected after timeout")
    assertTrue(err == "roster_incomplete" or err == "not_ready" or err == "rank_unavailable",
        "timeout deny reason: " .. tostring(err))
    GG._demandRoster.lastRequestAt = nil
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "still incomplete until new event")
    assertEq(GG._demandRoster.waitActive, true, "new wait after timeout")
    fireEvent("GUILD_ROSTER_UPDATE")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "recovers after post-timeout event")
    assertEq(member.clubId, "88", "bound to 88 after recovery")

    ensureIdleGossip()

    world.guild.clubId = 42
    world.guild.name = "Spectrum"
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
        { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true },
        { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
    }
end

-- R24) Bank-tab constructor: nil-only clear; reject failed conversions
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()

    local op, st = GS:NewConfigOperation("set-bank-tab", "bankTab", 3)
    assertEq(st, "accepted", "valid tab 3 prepares")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "valid tab 3 applies")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 3, "tab 3 stored")

    local badStr, stBad, errBad = GS:NewConfigOperation("set-bank-tab", "bankTab", "oops")
    assertNil(badStr, "malformed string rejected at prepare")
    assertEq(stBad, "rejected", "malformed string status")
    assertEq(errBad, "invalid_bank_tab", "malformed string reason")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 3, "tab unchanged after bad string")

    local badBool, stBool, errBool = GS:NewConfigOperation("set-bank-tab", "bankTab", false)
    assertNil(badBool, "false rejected at prepare")
    assertEq(stBool, "rejected", "false status")
    assertEq(errBool, "invalid_bank_tab", "false reason")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 3, "tab unchanged after false")

    -- Apply-path rejection also preserves the existing setting.
    local poison = GS:NewConfigOperation("set-bank-tab", "bankTab", 4)
    poison.value = "oops"
    local stPoison, errPoison = GS:ApplyStagedConfigOperation(poison)
    assertEq(stPoison, "rejected", "apply rejects poisoned bank tab")
    assertEq(errPoison, "invalid_bank_tab", "apply invalid_bank_tab")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 3, "tab unchanged after apply reject")

    local opStr, stStr = GS:NewConfigOperation("set-bank-tab", "bankTab", "5")
    assertEq(stStr, "accepted", "numeric string coerces")
    assertEq(opStr.value, 5, "coerced to number 5")
    assertEq(GS:ApplyStagedConfigOperation(opStr), "accepted", "coerced string applies")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 5, "tab 5 stored")

    local opClear, stClear = GS:NewConfigOperation("set-bank-tab", "bankTab", nil)
    assertEq(stClear, "accepted", "explicit nil prepares clear")
    assertNil(opClear.value, "clear sentinel is nil")
    assertEq(GS:ApplyStagedConfigOperation(opClear), "accepted", "explicit nil clears")
    assertNil(GS:GetCurrentRecord().accounting._consumables.bankTab, "tab cleared")
end

-- R25) Historical accepted body shape validation (no current-authority checks)
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()
    local datasetId = record.datasetId
    local raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]

    -- Malformed confirmation body (kind only) stays preserved but unavailable.
    raw.operations.records["bad-conf"] = { id = "bad-conf", kind = "confirm-candidate" }
    raw.operations.order = { "bad-conf" }
    raw.operations.heads = {}
    raw.confirmationRefs = { "bad-conf" }
    local exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "malformed confirmation body unavailable")
    assertTrue(reason == "invalid_operations" or reason == "invalid_fingerprint"
        or reason == "invalid_candidate_ref" or reason == "invalid_actor"
        or reason == "invalid_base_policy" or reason == "invalid_timestamp"
        or reason == "invalid_guild_key" or reason == "invalid_dataset_id"
        or reason == "unsupported_schema" or reason == "invalid_kind",
        "malformed confirm reason: " .. tostring(reason))
    assertEq(raw.operations.records["bad-conf"].kind, "confirm-candidate", "malformed confirm preserved")

    -- Malformed config body unavailable; SV preserved.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    datasetId = raw.datasetId
    raw.operations.records["bad-cfg"] = {
        id = "bad-cfg",
        kind = "set-bank-tab",
        target = "bankTab",
        value = 2,
        -- missing required envelope fields
    }
    raw.operations.order = { "bad-cfg" }
    raw.operations.heads = {}
    raw.confirmationRefs = {}
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "malformed config body unavailable")
    assertTrue(reason == "invalid_operations" or reason == "unsupported_schema"
        or reason == "invalid_guild_key" or reason == "invalid_dataset_id"
        or reason == "invalid_actor" or reason == "invalid_timestamp"
        or reason == "invalid_base_target" or reason == "invalid_base_policy",
        "malformed config reason: " .. tostring(reason))
    assertEq(raw.operations.records["bad-cfg"].value, 2, "malformed config preserved")

    -- Valid historical bodies remain usable after policy/campaign change.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    local bankOp = GS:NewConfigOperation("set-bank-tab", "bankTab", 2)
    assertEq(GS:ApplyStagedConfigOperation(bankOp), "accepted", "historical bank op accepted")
    local conf, confSt = GS:NewConfirmationOperation({
        recordId = "hist-cand",
        contentFingerprint = "fp-hist",
    })
    assertEq(confSt, "accepted", "historical confirm prepares")
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "accepted", "historical confirm admits")
    record = GS:GetCurrentRecord()
    assertTrue(record ~= nil, "record usable with valid historical bodies")
    -- Policy revision changes (editor rank op) — old bodies keep stale basePolicyRevision.
    local rankOp = GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 2)
    assertEq(GS:ApplyStagedConfigOperation(rankOp), "accepted", "policy revision advances")
    record = GS:GetCurrentRecord()
    assertTrue(record ~= nil, "record usable after policy change")
    assertTrue(record.operations.records[bankOp.id] ~= nil, "old bank body still present")
    assertTrue(record.operations.records[conf.id] ~= nil, "old confirm body still present")
    assertTrue(record.operations.records[bankOp.id].basePolicyRevision ~= record.permission.revisionId,
        "historical basePolicyRevision differs from current policy")
    -- Campaign pointer change must not invalidate historical accepted bodies.
    local okCamp, campErr = GS:_StoreCampaignBoundaryForTests({
        schemaVersion = 1,
        campaignId = "camp-hist",
        datasetId = record.datasetId,
        guildKey = "club:42",
        resetOperationId = "camp-hist",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 50,
        bankTabAtStart = 2,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
        contextRecordCount = 0,
    })
    assertEq(okCamp, true, "campaign stored: " .. tostring(campErr))
    record.currentCampaignId = "camp-hist"
    record = GS:GetCurrentRecord()
    assertTrue(record ~= nil, "record usable after campaign change with historical ops")
    assertEq(record.operations.records[bankOp.id].value, 2, "historical bank value intact")
end

-- R26) Immutable retained conflicts: first body preserved (config + confirmation + pending)
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()

    -- Config: original accepted -> divergent A -> divergent B -> retry A
    local orig = GS:NewConfigOperation("set-bank-tab", "bankTab", 1)
    assertEq(GS:ApplyStagedConfigOperation(orig), "accepted", "original config accepted")
    local storedOrig = GS:GetCurrentRecord().operations.records[orig.id]
    local function cloneConfig(base, value, ts)
        return {
            schemaVersion = base.schemaVersion,
            id = base.id,
            guildKey = base.guildKey,
            datasetId = base.datasetId,
            kind = base.kind,
            target = base.target,
            value = value,
            actorGuid = base.actorGuid,
            actorName = base.actorName,
            timestamp = ts,
            baseTargetRevision = base.baseTargetRevision,
            basePolicyRevision = base.basePolicyRevision,
            baseCampaignId = base.baseCampaignId,
            campaignId = base.campaignId,
        }
    end
    local divA = cloneConfig(storedOrig, 2, storedOrig.timestamp + 1)
    local stA, reasonA = GS:ApplyStagedConfigOperation(divA)
    assertEq(stA, "rejected", "divergent A rejected")
    assertEq(reasonA, "id_conflict", "divergent A id_conflict")
    local conflictA = GS:GetCurrentRecord().operations.conflicts[orig.id]
    assertTrue(conflictA ~= nil, "conflict A retained")
    assertEq(conflictA.body.value, 2, "conflict A body value 2")
    local slotCountAfterA = 0
    for _ in pairs(GS:GetCurrentRecord().operations.conflicts) do slotCountAfterA = slotCountAfterA + 1 end
    for _ in pairs(GS:GetCurrentRecord().operations.pending) do slotCountAfterA = slotCountAfterA + 1 end

    local divB = cloneConfig(storedOrig, 3, storedOrig.timestamp + 2)
    local stB, reasonB = GS:ApplyStagedConfigOperation(divB)
    assertEq(stB, "rejected", "divergent B rejected")
    assertEq(reasonB, "id_conflict", "divergent B id_conflict")
    local conflictAfterB = GS:GetCurrentRecord().operations.conflicts[orig.id]
    assertEq(conflictAfterB.body.value, 2, "first conflict body preserved (not replaced by B)")
    assertEq(GS:GetCurrentRecord().operations.records[orig.id].value, 1, "accepted original unchanged")
    local slotCountAfterB = 0
    for _ in pairs(GS:GetCurrentRecord().operations.conflicts) do slotCountAfterB = slotCountAfterB + 1 end
    for _ in pairs(GS:GetCurrentRecord().operations.pending) do slotCountAfterB = slotCountAfterB + 1 end
    assertEq(slotCountAfterB, slotCountAfterA, "divergent B does not consume another retention slot")

    local retryA = cloneConfig(storedOrig, 2, storedOrig.timestamp + 3)
    local stRetry, reasonRetry = GS:ApplyStagedConfigOperation(retryA)
    assertEq(stRetry, "rejected", "retry A rejected")
    assertEq(reasonRetry, "id_conflict", "retry A id_conflict")
    assertEq(GS:GetCurrentRecord().operations.conflicts[orig.id].body.value, 2, "retry A still preserves first conflict")

    -- Confirmation family: original -> A -> B -> retry A
    local conf, confSt = GS:NewConfirmationOperation({
        recordId = "c-imm",
        contentFingerprint = "fp-imm",
    })
    assertEq(confSt, "accepted", "confirm original prepares")
    assertEq(GS:ApplyStagedConfirmationOperation(conf), "accepted", "confirm original accepted")
    local confStored = GS:GetCurrentRecord().operations.records[conf.id]
    local function cloneConfirm(base, fp, ts)
        return {
            schemaVersion = base.schemaVersion,
            id = base.id,
            guildKey = base.guildKey,
            datasetId = base.datasetId,
            kind = base.kind,
            candidateRef = { recordId = "c-imm", contentFingerprint = fp },
            contentFingerprint = fp,
            campaignId = base.campaignId,
            basePolicyRevision = base.basePolicyRevision,
            actorGuid = base.actorGuid,
            actorName = base.actorName,
            timestamp = ts,
        }
    end
    local confA = cloneConfirm(confStored, "fp-A", confStored.timestamp + 1)
    assertEq(GS:ApplyStagedConfirmationOperation(confA), "rejected", "confirm divergent A rejected")
    assertEq(GS:GetCurrentRecord().operations.conflicts[conf.id].body.contentFingerprint, "fp-A",
        "confirm conflict A retained")
    local confB = cloneConfirm(confStored, "fp-B", confStored.timestamp + 2)
    assertEq(GS:ApplyStagedConfirmationOperation(confB), "rejected", "confirm divergent B rejected")
    assertEq(GS:GetCurrentRecord().operations.conflicts[conf.id].body.contentFingerprint, "fp-A",
        "confirm first conflict preserved against B")
    assertEq(GS:GetCurrentRecord().operations.records[conf.id].contentFingerprint, "fp-imm",
        "accepted confirm body unchanged")
    local confRetryA = cloneConfirm(confStored, "fp-A", confStored.timestamp + 3)
    assertEq(GS:ApplyStagedConfirmationOperation(confRetryA), "rejected", "confirm retry A rejected")
    assertEq(GS:GetCurrentRecord().operations.conflicts[conf.id].body.contentFingerprint, "fp-A",
        "confirm retry A keeps first conflict")

    -- Pending path: pending original -> divergent A conflict -> divergent B preserves A
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    GS:CreateStagedRecord()
    local headOp = GS:NewConfigOperation("set-bank-tab", "bankTab", 4)
    assertEq(GS:ApplyStagedConfigOperation(headOp), "accepted", "head bank accepted")
    -- Build a stale-base pending by using an outdated baseTargetRevision.
    local pendingOrig = GS:NewConfigOperation("set-bank-tab", "bankTab", 5)
    pendingOrig.baseTargetRevision = "stale-base-rev"
    local pst, preason = GS:ApplyStagedConfigOperation(pendingOrig)
    assertEq(pst, "pending", "stale-base becomes pending: " .. tostring(preason))
    local pendingBody = GS:GetCurrentRecord().operations.pending[pendingOrig.id].body
    assertEq(pendingBody.value, 5, "pending original value 5")
    local pendA = cloneConfig(pendingBody, 6, pendingBody.timestamp + 1)
    local pstA, preasonA = GS:ApplyStagedConfigOperation(pendA)
    assertEq(pstA, "rejected", "pending divergent A rejected")
    assertEq(preasonA, "id_conflict", "pending divergent A id_conflict")
    assertEq(GS:GetCurrentRecord().operations.conflicts[pendingOrig.id].body.value, 6,
        "pending-path conflict A retained")
    assertEq(GS:GetCurrentRecord().operations.pending[pendingOrig.id].body.value, 5,
        "original pending body unchanged")
    local pendB = cloneConfig(pendingBody, 7, pendingBody.timestamp + 2)
    local pstB, preasonB = GS:ApplyStagedConfigOperation(pendB)
    assertEq(pstB, "rejected", "pending divergent B rejected")
    assertEq(preasonB, "id_conflict", "pending divergent B id_conflict")
    assertEq(GS:GetCurrentRecord().operations.conflicts[pendingOrig.id].body.value, 6,
        "pending-path first conflict preserved against B")
    assertEq(GS:GetCurrentRecord().operations.pending[pendingOrig.id].body.value, 5,
        "pending original still unchanged after B")
end

-- R27) Demand-roster trust invalidated on observed identity loss
do
    resetDb()
    initGS({ settle = false })
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    world.guild.inGuild = true
    settleRoster()
    local member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "bound after refresh for club A")
    assertEq(GG._demandRoster.boundClubId, "42", "boundClubId is 42")

    -- Observed guild loss clears trust and terminates any wait.
    world.guild.inGuild = false
    local id, idReason = GG.GetGuildIdentity()
    assertNil(id, "identity nil when not in guild")
    assertEq(idReason, "not_in_guild", "not_in_guild reason")
    assertNil(GG._demandRoster.boundClubId, "bound cleared on guild loss")
    assertNil(GG._demandRoster.pendingClubId, "pending cleared on guild loss")
    assertEq(GG._demandRoster.waitActive, false, "wait inactive after guild loss")

    -- Rejoin same club with stale nonempty rows: must wait again.
    world.guild.inGuild = true
    world.guild.clubId = 42
    -- Rank change while away (stale authority risk if trust were kept).
    for _, m in ipairs(world.guild.members) do
        if m.guid == "Player-1-Alice" then m.rankOrder = 4 end
    end
    world.rosterRequests = 0
    GG._demandRoster.lastRequestAt = nil
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "rejoin A incomplete until refresh")
    assertEq(reason, "roster_incomplete", "roster_incomplete after rejoin")
    assertEq(GG._demandRoster.waitActive, true, "wait restarted for rejoin A")
    assertNil(GG._demandRoster.boundClubId, "not bound before rejoin refresh")
    local ctx = GS:GetCurrentContext()
    assertEq(ctx.ready, false, "privileged context unavailable after rejoin before refresh")
    local op, st = GS:NewConfigOperation("set-bank-tab", "bankTab", 1)
    assertNil(op, "no prepare after rejoin before refresh")
    assertEq(st, "rejected", "prepare rejected after rejoin before refresh")

    fireEvent("GUILD_ROSTER_UPDATE")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "recovers after rejoin refresh")
    assertEq(member.rankOrder, 4, "post-refresh rank reflects change while away")
    assertEq(GG._demandRoster.boundClubId, "42", "rebound to A after refresh")

    -- Identity loss while a wait is active: invalidate; old event must not bind.
    world.guild.clubId = 55
    GG._demandRoster.lastRequestAt = nil
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "club 55 wait started")
    assertEq(GG._demandRoster.waitActive, true, "wait active for 55")
    local genBeforeLoss = GG._demandRoster.waitGeneration
    world.guild.clubId = nil
    id, idReason = GG.GetGuildIdentity()
    assertNil(id, "club unavailable")
    assertEq(idReason, "club_id_unavailable", "club_id_unavailable")
    assertNil(GG._demandRoster.boundClubId, "bound cleared on club loss")
    assertNil(GG._demandRoster.pendingClubId, "pending cleared on club loss")
    assertEq(GG._demandRoster.waitActive, false, "wait terminated on club loss")
    assertTrue(GG._demandRoster.waitGeneration ~= genBeforeLoss, "generation bumped on club loss")
    -- Stale GUILD_ROSTER_UPDATE must not restore trust.
    world.guild.clubId = 55
    fireEvent("GUILD_ROSTER_UPDATE")
    assertNil(GG._demandRoster.boundClubId, "stale event after loss does not bind")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertNil(member, "still incomplete; needs a fresh wait after loss")
    fireEvent("GUILD_ROSTER_UPDATE")
    member, reason = GG.GetGuildMember("Alice-Garona")
    assertTrue(member ~= nil, "fresh wait after loss completes")
    ensureIdleGossip()

    -- restore defaults
    world.guild.inGuild = true
    world.guild.clubId = 42
    for _, m in ipairs(world.guild.members) do
        if m.guid == "Player-1-Alice" then m.rankOrder = 1 end
    end
end

-- R28) Finite nonnegative operation timestamps (config + confirmation + historical)
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()

    local op = GS:NewConfigOperation("set-bank-tab", "bankTab", 2)
    assertTrue(op ~= nil, "valid timestamp prepares")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "valid timestamp admits")

    local function assertBadTs(label, ts)
        local bad = GS:NewConfigOperation("set-bank-tab", "bankTab", 3)
        bad.timestamp = ts
        local st, err = GS:ApplyStagedConfigOperation(bad)
        assertEq(st, "rejected", label .. " rejected at admission")
        assertEq(err, "invalid_timestamp", label .. " invalid_timestamp")
    end
    assertBadTs("math.huge", math.huge)
    assertBadTs("-math.huge", -math.huge)
    assertBadTs("nan", 0/0)
    assertBadTs("fractional", 1.5)
    assertBadTs("negative", -1)

    -- Historical accepted body with non-finite timestamp: preserved, unavailable.
    local raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    local storedId = op.id
    local savedTs = raw.operations.records[storedId].timestamp
    raw.operations.records[storedId].timestamp = math.huge
    local exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "huge historical timestamp unavailable")
    assertEq(reason, "invalid_timestamp", "historical invalid_timestamp")
    assertEq(raw.operations.records[storedId].timestamp, math.huge, "malformed timestamp preserved")
    raw.operations.records[storedId].timestamp = savedTs
    assertTrue(GS:GetCurrentRecord() ~= nil, "restored finite timestamp usable")

    -- Confirmation shape rejects non-finite timestamps at prepare/admission.
    local conf, confSt, confErr = GS:NewConfirmationOperation({
        recordId = "ts-cand",
        contentFingerprint = "fp-ts",
    })
    assertEq(confSt, "accepted", "confirm with valid timestamp prepares")
    conf.timestamp = math.huge
    local cst, cerr = GS:ApplyStagedConfirmationOperation(conf)
    assertEq(cst, "rejected", "confirm huge timestamp rejected")
    assertEq(cerr, "invalid_timestamp", "confirm invalid_timestamp")
end

-- R29) Permission revision consistency with policy head / bootstrap
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()
    local datasetId = record.datasetId
    assertEq(record.permission.revisionId, datasetId, "bootstrap revision is datasetId")
    assertEq(record.permission.editorRankPosition, 3, "default bootstrap threshold 3")
    assertNil(record.operations.heads["permission:editorRankPosition"], "no policy head at bootstrap")

    -- Valid edited policy: head + revision + value agree.
    local rankOp = GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 2)
    assertEq(GS:ApplyStagedConfigOperation(rankOp), "accepted", "edited policy accepted")
    record = GS:GetCurrentRecord()
    assertEq(record.permission.revisionId, rankOp.id, "revision follows accepted op")
    assertEq(record.permission.editorRankPosition, 2, "threshold projected to 2")
    assertEq(record.operations.heads["permission:editorRankPosition"], rankOp.id, "policy head set")
    setPlayer("Carol-Garona", "Player-1-Carol", 3)
    local caps = GS:GetCapabilities()
    assertEq(caps.canEdit, false, "rank 3 cannot edit under threshold 2")
    setPlayer("Bob-Garona", "Player-1-Bob", 2)
    caps = GS:GetCapabilities()
    assertEq(caps.canEdit, true, "rank 2 can edit under valid edited policy")

    -- Mismatched projected value vs head body.
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    local raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.permission.editorRankPosition = 5
    local exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "value mismatch unavailable")
    assertEq(reason, "invalid_permission_revision", "value mismatch reason")
    caps = GS:GetCapabilities()
    assertEq(caps.canEdit, false, "ordinary edit denied on value mismatch")
    assertEq(caps.canRecoverPolicy, true, "GM recovery on value mismatch")
    raw.permission.editorRankPosition = 2

    -- Nonexistent / stale policy revision vs head.
    raw.permission.revisionId = "does-not-exist"
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "nonexistent revision unavailable")
    assertEq(reason, "invalid_permission_revision", "nonexistent revision reason")
    caps = GS:GetCapabilities()
    assertEq(caps.canRecoverPolicy, true, "GM recovery on nonexistent revision")
    assertEq(caps.canEdit, false, "no ordinary edit on nonexistent revision")
    raw.permission.revisionId = rankOp.id

    -- Stale revision (bootstrap id) while head points at edited op.
    raw.permission.revisionId = datasetId
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "stale bootstrap revision vs head unavailable")
    assertEq(reason, "invalid_permission_revision", "stale revision reason")
    raw.permission.revisionId = rankOp.id

    -- Wrong operation kind under the policy head key is structural (not waived).
    local headKey = "permission:editorRankPosition"
    local savedBody = raw.operations.records[rankOp.id]
    raw.operations.records[rankOp.id] = minimalValidBankTabBody(rankOp.id, datasetId, 1)
    raw.operations.heads[headKey] = rankOp.id
    exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "wrong-kind head body unavailable")
    assertEq(reason, "invalid_operations", "wrong-kind is structural invalid_operations")
    caps = GS:GetCapabilities()
    assertEq(caps.canRecoverPolicy, false, "structural corruption not GM policy recovery")
    assertEq(caps.canEdit, false, "no edit on structural corruption")
    raw.operations.records[rankOp.id] = savedBody

    -- Explicit GM recovery after permission-only mismatch.
    raw.permission.editorRankPosition = 5
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    caps = GS:GetCapabilities()
    assertEq(caps.canRecoverPolicy, true, "GM can recover after mismatch")
    local recoverOp, recoverSt = GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 3)
    assertEq(recoverSt, "accepted", "GM recovery prepare accepted: " .. tostring(recoverOp and recoverOp.id))
    assertEq(GS:ApplyStagedConfigOperation(recoverOp), "accepted", "GM recovery apply accepted")
    record = GS:GetCurrentRecord()
    assertTrue(record ~= nil, "record usable after GM recovery")
    assertEq(record.permission.editorRankPosition, 3, "recovered threshold 3")
    assertEq(record.permission.revisionId, recoverOp.id, "recovered revision is new op")

    -- Valid small-guild GM-selected threshold remains bootstrap (no policy head).
    resetDb()
    initGS()
    world.guild.clubId = 42
    world.guild.ranks = { "Guild Master", "Member" }
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
    }
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    settleRoster()
    local small, smallSt = GS:CreateStagedRecord(2)
    assertEq(smallSt, "accepted", "small-guild GM selection accepted")
    assertEq(small.permission.editorRankPosition, 2, "small-guild selected threshold")
    assertEq(small.permission.revisionId, small.datasetId, "small-guild bootstrap revision")
    assertNil(small.operations.heads["permission:editorRankPosition"], "small-guild has no policy head")
    assertTrue(GS:GetCurrentRecord() ~= nil, "small-guild bootstrap record usable")

    -- Preview restriction still applies (not waived by recovery path).
    resetDb()
    initGS()
    world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
        { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true },
        { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
    }
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    settleRoster()
    GS:CreateStagedRecord()
    raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    raw.permission.revisionId = "bogus-rev"
    world.impersonationActive = true
    caps = GS:GetCapabilities()
    assertEq(caps.canRecoverPolicy, false, "Preview as Non-Admin blocks GM recovery")
    assertEq(caps.canEdit, false, "Preview blocks edit")
    world.impersonationActive = false
end

-- R30) operations.order must be a bounded dense 1..n array (all keys inspected)
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()
    assertTrue(record ~= nil, "empty dense order readable at bootstrap")
    assertEq(next(record.operations.order), nil, "bootstrap order empty")

    local op1 = GS:NewConfigOperation("set-bank-tab", "bankTab", 1)
    assertEq(GS:ApplyStagedConfigOperation(op1), "accepted", "first append accepted")
    assertTrue(GS:GetCurrentRecord() ~= nil, "dense order after first append readable")
    local op2 = GS:NewConfigOperation("set-bank-tab", "bankTab", 2)
    assertEq(GS:ApplyStagedConfigOperation(op2), "accepted", "second append accepted")
    record = GS:GetCurrentRecord()
    assertTrue(record ~= nil, "valid dense append remains readable")
    assertEq(record.operations.order[1], op1.id, "dense order[1]")
    assertEq(record.operations.order[2], op2.id, "dense order[2]")

    local raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
    local datasetId = raw.datasetId
    local ghostId = "ghost-order-id"
    raw.operations.records[ghostId] = minimalValidBankTabBody(ghostId, datasetId, 7)

    -- Hole with an entry beyond the contiguous prefix (do not assert #order).
    raw.operations.order = { [1] = op1.id, [3] = ghostId }
    local exposed, reason = GS:GetCurrentRecord()
    assertNil(exposed, "hole beyond contiguous prefix unavailable")
    assertEq(reason, "invalid_operations", "hole invalid_operations")
    assertEq(raw.operations.order[1], op1.id, "hole order[1] preserved")
    assertEq(raw.operations.order[3], ghostId, "hole order[3] preserved")
    assertNil(raw.operations.order[2], "hole at 2 unchanged (still absent)")

    local function assertBadOrderKeys(label, orderTable)
        raw.operations.order = orderTable
        local ex, rs = GS:GetCurrentRecord()
        assertNil(ex, label .. " unavailable")
        assertEq(rs, "invalid_operations", label .. " invalid_operations")
        -- Malformed saved order remains unchanged (no rewrite/delete).
        for k, v in pairs(orderTable) do
            assertEq(raw.operations.order[k], v, label .. " key preserved: " .. tostring(k))
        end
    end

    assertBadOrderKeys("string key", { [1] = op1.id, ["2"] = op2.id })
    assertBadOrderKeys("zero key", { [0] = op1.id, [1] = op2.id })
    assertBadOrderKeys("negative key", { [-1] = op1.id, [1] = op2.id })
    assertBadOrderKeys("fractional key", { [1] = op1.id, [1.5] = op2.id })

    -- Restore a valid dense order; record becomes usable again.
    raw.operations.order = { op1.id, op2.id }
    raw.operations.records[ghostId] = nil
    exposed, reason = GS:GetCurrentRecord()
    assertTrue(exposed ~= nil, "restored dense order readable: " .. tostring(reason))
    local op3 = GS:NewConfigOperation("set-bank-tab", "bankTab", 3)
    assertEq(GS:ApplyStagedConfigOperation(op3), "accepted", "append after restore accepted")
    assertTrue(GS:GetCurrentRecord() ~= nil, "readable after valid append on restored dense order")
end

---------------------------------------------------------------------------
-- Part 2B (#386): fresh start, campaigns, eligibility, UI statuses
---------------------------------------------------------------------------

-- 2B1) Fresh setup imports nothing from legacy Consumables / unrelated profiles
do
    resetDb()
    SpectrumFederationDB = {
        lootHelper = {
            profiles = {
                legacy = {
                    _consumables = {
                        bankTab = 4,
                        requestedItems = { ["999"] = { itemId = 999, goal = 50 } },
                        txnRegistry = { ["txn-old"] = { id = "txn-old" } },
                    },
                    _consumableEvents = { { id = "ev-legacy", type = "donation", itemId = 999, quantity = 3 } },
                },
            },
            activeProfileId = "legacy",
            showRaidSupplyReminders = false,
        },
        otherFeature = { keep = true },
    }
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    assertNil(select(1, GS:GetCurrentRecord()), "no auto-bootstrap on read")
    local rec, st = GS:CreateStagedRecord()
    assertEq(st, "accepted", "explicit create")
    assertTrue(rec ~= nil, "record created")
    local nItems = 0
    for _ in pairs(rec.accounting._consumables.requestedItems) do nItems = nItems + 1 end
    assertEq(nItems, 0, "fresh requested items empty")
    assertNil(rec.accounting._consumables.bankTab, "bank tab unset until configured")
    assertEq(rec.currentCampaignId, nil, "no campaign until New Campaign")
    local nTxn = 0
    for _ in pairs(rec.accounting._consumables.txnRegistry) do nTxn = nTxn + 1 end
    assertEq(nTxn, 0, "no legacy txn import")
    assertEq(#rec.accounting._consumableEvents, 0, "no legacy event import")
    assertEq(SpectrumFederationDB.lootHelper.profiles.legacy._consumables.requestedItems["999"].goal, 50,
        "legacy profile untouched")
    assertEq(SpectrumFederationDB.otherFeature.keep, true, "unrelated account data untouched")
    assertEq(SpectrumFederationDB.lootHelper.showRaidSupplyReminders, false,
        "personal preference untouched by setup")
end

-- 2B2) New Campaign empty; archives prior config; guild/tab/rank preserved
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local tabOp = GS:NewConfigOperation("set-bank-tab", "bankTab", 3)
    assertEq(GS:ApplyStagedConfigOperation(tabOp), "accepted", "set shared bank tab")
    local camp1 = startCampaign()
    local itemOp = GS:NewConfigOperation("set-requested-item", { itemId = 42 }, { itemId = 42, goal = 10 })
    assertEq(GS:ApplyStagedConfigOperation(itemOp), "accepted", "add campaign item")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["42"].goal, 10, "item present")
    local eligBefore = GS:GetCurrentRecord().accounting._consumables.eligibility.items["42"]
    assertTrue(type(eligBefore) == "number", "item cutoff after baseline")

    local camp2 = startCampaign()
    assertTrue(camp1.id ~= camp2.id, "distinct campaign identities")
    local record = GS:GetCurrentRecord()
    assertEq(record.currentCampaignId, camp2.id, "current is second campaign")
    local nItems = 0
    for _ in pairs(record.accounting._consumables.requestedItems) do nItems = nItems + 1 end
    assertEq(nItems, 0, "new campaign starts empty")
    assertEq(record.accounting._consumables.bankTab, 3, "bank tab preserved")
    assertEq(record.permission.editorRankPosition, 3, "editor rank preserved")
    local archive = record.campaignArchives[camp1.id]
    assertTrue(archive ~= nil, "prior campaign archived")
    assertEq(archive.requestedItems["42"].goal, 10, "archived goals preserved")
    local progress = GS:ProjectCampaignProgress(camp2.id)
    assertEq(progress.itemTotals[42], nil, "new campaign zero progress")
    local archivedItems = GS:GetCampaignRequestedItems(camp1.id)
    assertEq(archivedItems["42"].goal, 10, "inspect archived items")
end

-- 2B3) Reset retry/reload idempotent; distinct confirmed reset gets new id
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local campOp = GS:NewCampaignOperation()
    assertEq(GS:ApplyStagedCampaignOperation(campOp), "accepted", "first campaign")
    local status = GS:ApplyStagedCampaignOperation(campOp)
    assertEq(status, "duplicate", "retry same op is duplicate")
    local record = GS:GetCurrentRecord()
    local nCamps = 0
    for _ in pairs(record.campaigns) do nCamps = nCamps + 1 end
    assertEq(nCamps, 1, "single campaign after retry")

    -- Reload persistence of campaign op
    local saved = SpectrumFederationDB
    GS._db = nil
    GS._root = nil
    GS._rootValid = false
    SpectrumFederationDB = saved
    initGS()
    assertEq(GS:ApplyStagedCampaignOperation(campOp), "duplicate", "duplicate after reload")
    assertEq(GS:GetCurrentRecord().currentCampaignId, campOp.id, "same current after reload")

    local campOp2 = GS:NewCampaignOperation()
    assertEq(GS:ApplyStagedCampaignOperation(campOp2), "accepted", "distinct subsequent reset")
    assertTrue(campOp2.id ~= campOp.id, "new reset identity")
    assertEq(GS:GetCurrentRecord().currentCampaignId, campOp2.id, "second current")
end

-- 2B4) Stale authority / campaign base leaves prior intact
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local first = startCampaign()
    local before = GS:GetCurrentRecord().currentCampaignId
    local op = GS:NewCampaignOperation()
    op.baseCampaignId = "not-current"
    op.campaignId = "not-current"
    local status, reason = GS:ApplyStagedCampaignOperation(op)
    assertEq(status, "pending", "stale campaign base pending")
    assertEq(reason, "stale_base", "stale_base reason")
    assertEq(GS:GetCurrentRecord().currentCampaignId, before, "current unchanged on stale")
    assertNil(GS:GetCurrentRecord().campaigns[op.id], "no partial campaign header")

    -- Rank revocation at commit
    op = GS:NewCampaignOperation()
    setPlayer("Dave-Garona", "Player-1-Dave", 4)
    settleRoster()
    status, reason = GS:ApplyStagedCampaignOperation(op)
    assertEq(status, "rejected", "unauthorized after demotion")
    assertEq(GS:GetCurrentRecord().currentCampaignId, first.id, "campaign intact after auth failure")
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    settleRoster()
end

-- 2B5) Eligibility: tab change + item add/re-add cutoffs; goal edit preserves
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()
    local add = GS:NewConfigOperation("set-requested-item", { itemId = 100 }, { itemId = 100, goal = 1 })
    assertEq(GS:ApplyStagedConfigOperation(add), "accepted", "add item")
    local cutoff1 = GS:GetCurrentRecord().accounting._consumables.eligibility.items["100"]
    assertTrue(type(cutoff1) == "number", "add establishes cutoff")

    world.time = world.time + 50
    local goal = GS:NewConfigOperation("set-requested-item", { itemId = 100 }, { itemId = 100, goal = 9 })
    assertEq(GS:ApplyStagedConfigOperation(goal), "accepted", "goal edit")
    assertEq(GS:GetCurrentRecord().accounting._consumables.eligibility.items["100"], cutoff1,
        "goal edit preserves cutoff")

    local rem = GS:NewConfigOperation("set-requested-item", { itemId = 100 }, { removed = true })
    assertEq(GS:ApplyStagedConfigOperation(rem), "accepted", "remove item")
    assertEq(GS:GetCurrentRecord().accounting._consumables.eligibility.items["100"], cutoff1,
        "remove preserves cutoff history")

    world.time = world.time + 50
    local readd = GS:NewConfigOperation("set-requested-item", { itemId = 100 }, { itemId = 100, goal = 2 })
    assertEq(GS:ApplyStagedConfigOperation(readd), "accepted", "re-add item")
    local cutoff2 = GS:GetCurrentRecord().accounting._consumables.eligibility.items["100"]
    assertTrue(cutoff2 > cutoff1, "re-add establishes newer cutoff")

    local beforeTab = GS:GetCurrentRecord().accounting._consumables.eligibility.tabEligibleFrom
    world.time = world.time + 50
    local tab = GS:NewConfigOperation("set-bank-tab", "bankTab", 5)
    assertEq(GS:ApplyStagedConfigOperation(tab), "accepted", "tab change")
    local afterTab = GS:GetCurrentRecord().accounting._consumables.eligibility.tabEligibleFrom
    assertTrue(afterTab ~= nil and (beforeTab == nil or afterTab >= beforeTab),
        "tab change updates tabEligibleFrom")
end

-- 2B6) Malformed archived headers retained but not exposed
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local good = startCampaign()
    local record = GS:GetCurrentRecord()
    record.campaigns["bad-camp"] = {
        schemaVersion = 1,
        campaignId = "wrong-id",
        datasetId = record.datasetId,
        guildKey = "club:42",
        resetOperationId = "bad-camp",
        createdByGuid = "Player-1-Alice",
        createdByName = "Alice-Garona",
        startedAt = 1,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
    }
    local list = GS:ListInspectableCampaigns()
    local seenBad = false
    local seenGood = false
    for i = 1, #list do
        if list[i].campaignId == "bad-camp" then seenBad = true end
        if list[i].campaignId == good.id then seenGood = true end
    end
    assertEq(seenBad, false, "malformed header not exposed")
    assertEq(seenGood, true, "valid campaign still listed")
    assertTrue(GS:GetCurrentRecord().campaigns["bad-camp"] ~= nil, "malformed retained in SV")
    assertTrue(GS:GetCurrentRecord() ~= nil, "guild record still usable")
end

-- 2B7) Capacity failure leaves prior campaign intact
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local first = startCampaign()
    local record = GS:GetCurrentRecord()
    local fill = 0
    while GS.CountCampaignHeaders(record) < GS.MAX_CAMPAIGNS do
        fill = fill + 1
        local id = "fill-camp-" .. fill
        if record.campaigns[id] == nil then
            record.campaigns[id] = {
                schemaVersion = 1,
                campaignId = id,
                datasetId = record.datasetId,
                guildKey = "club:42",
                resetOperationId = id,
                createdByGuid = "Player-1-Alice",
                createdByName = "Alice-Garona",
                startedAt = fill,
                boundaryVersion = 1,
                boundaryKind = "new-goal",
                contextStatus = "unavailable",
            }
        end
    end
    assertEq(GS.CountCampaignHeaders(record), GS.MAX_CAMPAIGNS, "at campaign capacity")
    assertTrue(GS:GetCurrentRecord() ~= nil, "record still usable at capacity")
    local before = record.currentCampaignId
    local beforeItems = record.accounting._consumables.requestedItems
    local op, pst, perr = GS:NewCampaignOperation()
    assertTrue(op ~= nil, "prepare still works at capacity: " .. tostring(perr))
    local status, reason = GS:ApplyStagedCampaignOperation(op)
    assertEq(status, "rejected", "full capacity rejects")
    assertEq(reason, "full", "full reason")
    assertEq(GS:GetCurrentRecord().currentCampaignId, before, "current intact")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems, beforeItems,
        "items table intact")
    assertNil(GS:GetCurrentRecord().campaigns[op.id], "no partial new campaign")
    assertEq(before, first.id, "first campaign still current")

    -- Oversized retained campaigns map: early-stop count, unavailable, SV unchanged.
    local overCap = GS.MAX_CAMPAIGNS + 40
    for i = 1, overCap do
        local id = "over-camp-" .. i
        if record.campaigns[id] == nil then
            record.campaigns[id] = {
                schemaVersion = 1,
                campaignId = id,
                datasetId = record.datasetId,
                guildKey = "club:42",
                resetOperationId = id,
                createdByGuid = "Player-1-Alice",
                createdByName = "Alice-Garona",
                startedAt = i,
                boundaryVersion = 1,
                boundaryKind = "new-goal",
                contextStatus = "unavailable",
            }
        end
    end
    local rawCount = 0
    for _ in pairs(record.campaigns) do rawCount = rawCount + 1 end
    assertTrue(rawCount > GS.MAX_CAMPAIGNS + 1, "fixture exceeds campaign header cap")
    local boundedCount = GS.CountCampaignHeaders(record)
    assertEq(boundedCount, GS.MAX_CAMPAIGNS + 1,
        "CountCampaignHeaders stops at MAX_CAMPAIGNS+1")
    assertTrue(boundedCount < rawCount, "bounded count is below full retained size")
    assertEq(select(1, GS:GetCurrentRecord()), nil, "over-cap campaigns make record unavailable")
    assertEq(select(2, GS:GetCurrentRecord()), "full", "over-cap campaigns reason is full")
    local afterRaw = 0
    for _ in pairs(SpectrumFederationDB.guildSupplies.guilds["club:42"].campaigns) do
        afterRaw = afterRaw + 1
    end
    assertEq(afterRaw, rawCount, "over-cap campaigns SV retained unchanged")
end

-- 2B7b) Archive capacity bound + preexisting current-campaign archive reject
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local first = startCampaign()
    local record = GS:GetCurrentRecord()
    record.accounting._consumables.requestedItems["10"] = { itemId = 10, goal = 7 }
    -- Fill archives to capacity with unrelated campaign ids (not the current one).
    record.campaignArchives = record.campaignArchives or {}
    local fill = 0
    while true do
        local n = 0
        for _ in pairs(record.campaignArchives) do n = n + 1 end
        if n >= GS.MAX_CAMPAIGNS then break end
        fill = fill + 1
        local id = "arch-fill-" .. fill
        if record.campaignArchives[id] == nil then
            record.campaignArchives[id] = {
                schemaVersion = GS.SCHEMA_VERSION,
                campaignId = id,
                datasetId = record.datasetId,
                requestedItems = {},
                generation = 1,
                archivedAt = fill,
            }
        end
    end
    local atCap = 0
    for _ in pairs(record.campaignArchives) do atCap = atCap + 1 end
    assertEq(atCap, GS.MAX_CAMPAIGNS, "archives at capacity")
    assertTrue(GS:GetCurrentRecord() ~= nil, "usable current with full archives")
    local beforeItems = record.accounting._consumables.requestedItems
    local beforeGoal = beforeItems["10"].goal
    local beforeCamp = record.currentCampaignId
    local beforeOps = 0
    for _ in pairs(record.operations.records or {}) do beforeOps = beforeOps + 1 end
    local opFull = GS:NewCampaignOperation()
    assertTrue(opFull ~= nil, "prepare at archive capacity")
    local stFull, reasonFull = GS:ApplyStagedCampaignOperation(opFull)
    assertEq(stFull, "rejected", "archive capacity rejects New Campaign")
    assertEq(reasonFull, "full", "archive capacity reason full")
    assertEq(GS:GetCurrentRecord().currentCampaignId, beforeCamp, "current campaign intact at archive cap")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["10"].goal, beforeGoal,
        "live goals intact at archive cap")
    local afterArch = 0
    for _ in pairs(GS:GetCurrentRecord().campaignArchives) do afterArch = afterArch + 1 end
    assertEq(afterArch, atCap, "archive map unchanged at capacity reject")

    -- Oversized archive map: bounded reject without clearing live config.
    for i = 1, 40 do
        local id = "arch-over-" .. i
        record.campaignArchives[id] = {
            schemaVersion = GS.SCHEMA_VERSION,
            campaignId = id,
            datasetId = record.datasetId,
            requestedItems = {},
            generation = 1,
            archivedAt = 1000 + i,
        }
    end
    local overRaw = 0
    for _ in pairs(record.campaignArchives) do overRaw = overRaw + 1 end
    assertTrue(overRaw > GS.MAX_CAMPAIGNS + 1, "archive fixture exceeds cap")
    assertTrue(GS:GetCurrentRecord() ~= nil,
        "oversized archives do not disable usable current campaign")
    local opOver = GS:NewCampaignOperation()
    assertTrue(opOver ~= nil, "prepare with oversized archives")
    local stOver, reasonOver = GS:ApplyStagedCampaignOperation(opOver)
    assertEq(stOver, "rejected", "oversized archives reject New Campaign")
    assertEq(reasonOver, "full", "oversized archives reason full")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["10"].goal, beforeGoal,
        "live goals intact after oversized archive reject")
    local afterOver = 0
    for _ in pairs(SpectrumFederationDB.guildSupplies.guilds["club:42"].campaignArchives) do
        afterOver = afterOver + 1
    end
    assertEq(afterOver, overRaw, "oversized archives SV retained unchanged")

    -- Preexisting archive for the ending current campaign: reject before clear.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local cur = startCampaign()
    record = GS:GetCurrentRecord()
    record.accounting._consumables.requestedItems["55"] = { itemId = 55, goal = 12 }
    record.campaignArchives = record.campaignArchives or {}
    record.campaignArchives[cur.id] = {
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = cur.id,
        datasetId = record.datasetId,
        requestedItems = { ["55"] = { itemId = 55, goal = 1 } }, -- divergent
        generation = 99,
        archivedAt = 1,
    }
    local opPrep = GS:NewCampaignOperation()
    assertTrue(opPrep ~= nil, "prepare with preexisting current archive")
    -- Also cover prepare-then-corrupt-archive-slot path.
    local stExist, reasonExist = GS:ApplyStagedCampaignOperation(opPrep)
    assertEq(stExist, "rejected", "preexisting current archive rejects reset")
    assertEq(reasonExist, "campaign_archive_exists", "preexisting archive reason")
    assertEq(GS:GetCurrentRecord().currentCampaignId, cur.id, "campaign identity preserved")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["55"].goal, 12,
        "live goals preserved with preexisting archive")
    assertEq(GS:GetCurrentRecord().campaignArchives[cur.id].requestedItems["55"].goal, 1,
        "divergent archive retained unchanged")
    local opsExist = 0
    for _ in pairs(GS:GetCurrentRecord().operations.records or {}) do opsExist = opsExist + 1 end
    -- Malformed preexisting archive for current campaign.
    record.campaignArchives[cur.id] = "not-an-archive"
    local opMal = GS:NewCampaignOperation()
    assertTrue(opMal ~= nil, "prepare with malformed preexisting archive")
    local stMal, reasonMal = GS:ApplyStagedCampaignOperation(opMal)
    assertEq(stMal, "rejected", "malformed preexisting archive rejects reset")
    assertEq(reasonMal, "campaign_archive_exists", "malformed preexisting archive reason")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["55"].goal, 12,
        "live goals preserved with malformed preexisting archive")
    assertEq(GS:GetCurrentRecord().campaignArchives[cur.id], "not-an-archive",
        "malformed preexisting archive SV unchanged")
end

-- 2B7c) Eligibility container shape guard
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()
    local record = GS:GetCurrentRecord()
    -- Supported 2A empty eligibility form remains usable.
    record.accounting._consumables.eligibility = {}
    assertTrue(GS:GetCurrentRecord() ~= nil, "2A eligibility={} remains available")
    assertEq(GS.ValidateEligibilityContainer({}), true, "empty eligibility container ok")
    assertEq(GS.ValidateEligibilityContainer(nil), true, "absent eligibility ok")
    -- Ordinary tab/item cutoff behavior with valid eligibility.
    record.accounting._consumables.eligibility = {
        items = {},
        baselineEstablished = true,
        baselineAt = world.time,
        tabEligibleFrom = world.time,
    }
    local tabOp = GS:NewConfigOperation("set-bank-tab", "bankTab", 2)
    assertEq(GS:ApplyStagedConfigOperation(tabOp), "accepted", "valid tab cutoff accepted")
    assertTrue(GS:GetCurrentRecord().accounting._consumables.eligibility.tabEligibleFrom ~= nil,
        "tab cutoff written")
    local itemOp = GS:NewConfigOperation("set-requested-item", { itemId = 77 }, { itemId = 77, goal = 4 })
    assertEq(GS:ApplyStagedConfigOperation(itemOp), "accepted", "valid item cutoff accepted")
    assertTrue(GS:GetCurrentRecord().accounting._consumables.eligibility.items["77"] ~= nil,
        "item cutoff written")

    -- Non-table eligibility: unavailable; prepare then corrupt then apply.
    record = GS:GetCurrentRecord()
    local snapCamp = record.currentCampaignId
    local snapOps = 0
    for _ in pairs(record.operations.records or {}) do snapOps = snapOps + 1 end
    local prepTab = GS:NewConfigOperation("set-bank-tab", "bankTab", 3)
    assertTrue(prepTab ~= nil, "prepare before eligibility corruption")
    record.accounting._consumables.eligibility = "bad-eligibility"
    assertEq(select(1, GS:GetCurrentRecord()), nil, "non-table eligibility unavailable")
    assertEq(select(2, GS:GetCurrentRecord()), "invalid_eligibility", "non-table eligibility reason")
    local stBad, reasonBad = GS:ApplyStagedConfigOperation(prepTab)
    assertEq(stBad, "rejected", "commit rejects after eligibility corruption")
    assertEq(reasonBad, "invalid_eligibility", "commit surfaces invalid_eligibility")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].accounting._consumables.eligibility,
        "bad-eligibility", "malformed eligibility SV preserved on reject")
    local opsAfterCorrupt = 0
    for _ in pairs(SpectrumFederationDB.guildSupplies.guilds["club:42"].operations.records or {}) do
        opsAfterCorrupt = opsAfterCorrupt + 1
    end
    assertEq(opsAfterCorrupt, snapOps, "operations unchanged after eligibility reject")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].currentCampaignId, snapCamp,
        "campaign unchanged after eligibility reject")

    -- Present non-table items container.
    SpectrumFederationDB.guildSupplies.guilds["club:42"].accounting._consumables.eligibility = {
        items = "bad-items",
        baselineEstablished = true,
    }
    assertEq(select(2, GS:GetCurrentRecord()), "invalid_eligibility",
        "non-table eligibility.items unavailable")
    local prepItem, prepItemSt, prepItemReason = GS:NewConfigOperation(
        "set-requested-item", { itemId = 88 }, { itemId = 88, goal = 1 })
    assertEq(prepItem, nil, "prepare blocked by non-table eligibility.items")
    assertEq(prepItemSt, "rejected", "prepare status rejected")
    assertEq(prepItemReason, "invalid_eligibility", "prepare reason invalid_eligibility")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].accounting._consumables.eligibility.items,
        "bad-items", "non-table items container SV preserved")
end

-- 2B8) Status feedback never reports Saved for rejection; bank context unavailable
do
    local msg, sev = GS.FormatMutationFeedback("rejected", "unauthorized")
    assertTrue(type(msg) == "string" and msg:find("not authorized", 1, true),
        "rejected message uses localized reason")
    assertEq(sev, "error", "rejected severity")
    assertEq(msg:find("Saved", 1, true), nil, "no Saved for rejection")
    msg, sev = GS.FormatMutationFeedback("accepted", nil)
    assertEq(sev, "success", "accepted severity")
    assertTrue(msg:find("Staged", 1, true) or msg:find("admitted", 1, true), "accepted staged wording")
    msg, sev = GS.FormatMutationFeedback("duplicate", "duplicate")
    assertEq(sev, "info", "duplicate severity")
    msg, sev = GS.FormatMutationFeedback("pending", "stale_base")
    assertEq(sev, "warn", "pending severity")
    assertTrue(msg:find("out of date", 1, true), "pending reason localized")
    assertTrue(GS.FormatReasonText("not_ready"):find("not ready", 1, true),
        "FormatReasonText maps known codes")

    local ctx = GS.CaptureBankContext(nil)
    assertEq(ctx.status, "unavailable", "unset tab is unavailable not empty")
    ctx = GS.CaptureBankContext(1)
    -- Without bank APIs / readiness in the harness, capture is unavailable (not empty).
    assertEq(ctx.status, "unavailable", "missing APIs unavailable")
    assertTrue(ctx.reason ~= nil, "unavailable reason present")
end

-- 2B9) Cross-campaign txn registry preserved; historical start-campaign body validates
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()
    local record = GS:GetCurrentRecord()
    record.accounting._consumables.txnRegistry["txn-keep"] = {
        id = "txn-keep",
        generation = 1,
    }
    startCampaign()
    assertTrue(GS:GetCurrentRecord().accounting._consumables.txnRegistry["txn-keep"] ~= nil,
        "txn registry survives campaign reset")

    local campOp = GS:NewCampaignOperation()
    local ok, err = GS.ValidateAcceptedOperationBody(campOp, "club:42", record.datasetId)
    -- campOp is prepared against current dataset; body shape must validate historically.
    assertEq(ok, true, "start-campaign historical body ok: " .. tostring(err))
end

-- 2B10) Inspectable campaign accessors remain stable (UI lifecycle covered in 2B16)
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()
    local list1 = GS:ListInspectableCampaigns()
    local list2 = GS:ListInspectableCampaigns()
    assertEq(#list1, #list2, "list size stable across repeated reads")
    local items1 = GS:GetCampaignRequestedItems(list1[1].campaignId)
    local items2 = GS:GetCampaignRequestedItems(list1[1].campaignId)
    assertTrue(items1 ~= items2, "accessors return copies, not live tables")
end

-- 2B11) Exact canonical-body equality for campaign retries / ID conflicts
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local op = startCampaign()
    local status, reason = GS:ApplyStagedCampaignOperation(op)
    assertEq(status, "duplicate", "exact replay after accept is duplicate: " .. tostring(reason))

    local divergent = {}
    for k, v in pairs(op) do divergent[k] = v end
    divergent.baseTargetRevision = "gs1:other:base:1"
    status, reason = GS:ApplyStagedCampaignOperation(divergent)
    assertEq(status, "rejected", "divergent accepted body is id_conflict")
    assertEq(reason, "id_conflict", "id_conflict reason for changed baseTargetRevision")
    assertTrue(GS:GetCurrentRecord().operations.records[op.id] ~= nil, "original accepted body retained")
    assertEq(GS:GetCurrentRecord().operations.records[op.id].baseTargetRevision, op.baseTargetRevision,
        "accepted body baseTargetRevision unchanged")

    -- Pending path: stale pending with exact body may stay pending; changed body conflicts.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local pendingOp = GS:NewCampaignOperation()
    local record = GS:GetCurrentRecord()
    record.operations.pending[pendingOp.id] = {
        id = pendingOp.id,
        reason = "stale_base",
        body = pendingOp,
        at = world.time,
    }
    local changedPending = {}
    for k, v in pairs(pendingOp) do changedPending[k] = v end
    changedPending.value = { extra = true }
    status, reason = GS:ApplyStagedCampaignOperation(changedPending)
    assertEq(status, "rejected", "changed pending body rejected")
    assertEq(reason, "id_conflict", "pending id_conflict")
    assertTrue(record.operations.pending[pendingOp.id] ~= nil, "original pending retained")
    local pendingValue = record.operations.pending[pendingOp.id].body.value
    assertTrue(type(pendingValue) == "table", "original pending value remains a table")
    assertNil(pendingValue.extra, "original pending body not replaced by divergent value")
end

-- 2B12) Bank context requires readiness; empty only when fresh; creation still works
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()

    world.bankTxnCounts = world.bankTxnCounts or {}
    function GetNumGuildBankTransactions(tab)
        return world.bankTxnCounts[tab] or 0
    end
    function GetGuildBankTransaction()
        return "deposit", "Alice-Garona", nil, 1, nil, nil, 0, 1, 1, 1
    end

    GS._BankContextReadinessProbe = function()
        return false, "bank_closed"
    end
    local ctx = GS.CaptureBankContext(1)
    assertEq(ctx.status, "unavailable", "closed bank is unavailable even with zero count")
    assertEq(ctx.reason, "bank_closed", "bank_closed reason")

    world.bankTxnCounts[2] = 0
    GS._BankContextReadinessProbe = function(tab)
        if tab == 2 then return true end
        return false, "tab_not_ready"
    end
    ctx = GS.CaptureBankContext(2)
    assertEq(ctx.status, "empty", "fresh ready zero count is empty")
    assertEq(ctx.recordCount, 0, "empty recordCount 0")

    world.bankTxnCounts[3] = 2
    GS._BankContextReadinessProbe = function() return false, "log_not_updated" end
    ctx = GS.CaptureBankContext(3)
    assertEq(ctx.status, "unavailable", "positive count without readiness is unavailable")

    GS._BankContextReadinessProbe = nil
    GetNumGuildBankTransactions = nil
    GetGuildBankTransaction = nil

    -- New Campaign still accepts with unavailable context.
    local op = GS:NewCampaignOperation()
    local status, reason = GS:ApplyStagedCampaignOperation(op)
    assertEq(status, "accepted", "campaign without bank context: " .. tostring(reason))
    local header = GS:GetCurrentRecord().campaigns[op.id]
    assertEq(header.contextStatus, "unavailable", "contextStatus unavailable when unreadiness")
end

-- 2B13) Complete bounded rollback on post-validation rejection
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local first = startCampaign()
    local record = GS:GetCurrentRecord()
    local cfg = record.accounting._consumables
    cfg.requestedItems["100"] = { itemId = 100, goal = 5 }
    -- Populated/oversized prior eligibility.items: rollback must restore the
    -- original object/map without copying or mutating those entries.
    cfg.eligibility = cfg.eligibility or {}
    cfg.eligibility.items = cfg.eligibility.items or {}
    local priorElig = cfg.eligibility
    local priorEligItems = priorElig.items
    for i = 1, 512 do
        priorEligItems["cut-" .. i] = world.time + i
    end
    local before = {
        current = record.currentCampaignId,
        generation = cfg.generation,
        configSeq = cfg.configSeq,
        items = cfg.requestedItems,
        eligibility = priorElig,
        eligibilityItems = priorEligItems,
        eligibilityBaseline = cfg.eligibility and cfg.eligibility.baselineAt,
        eligibilityTab = cfg.eligibility and cfg.eligibility.tabEligibleFrom,
        head = record.operations.heads[GS.CAMPAIGN_TARGET_KEY],
        archiveCount = 0,
        eligItemCount = 0,
    }
    for _ in pairs(priorEligItems) do
        before.eligItemCount = before.eligItemCount + 1
    end
    for _ in pairs(record.campaignArchives or {}) do
        before.archiveCount = before.archiveCount + 1
    end

    local realValidate = GS._ValidateGuildRecordStructure
    GS._ValidateGuildRecordStructure = function()
        return false, "injected_post_failure"
    end
    local op = GS:NewCampaignOperation()
    local status, reason = GS:ApplyStagedCampaignOperation(op)
    GS._ValidateGuildRecordStructure = realValidate

    assertEq(status, "rejected", "post-validation rejection status")
    assertEq(reason, "injected_post_failure", "post-validation rejection reason")
    record = GS:GetCurrentRecord()
    cfg = record.accounting._consumables
    assertEq(record.currentCampaignId, before.current, "rollback restores current campaign")
    assertEq(cfg.generation, before.generation, "rollback restores generation")
    assertEq(cfg.configSeq, before.configSeq, "rollback restores configSeq")
    assertTrue(cfg.requestedItems == before.items, "rollback restores requestedItems ref")
    assertTrue(cfg.eligibility == before.eligibility, "rollback restores original eligibility object")
    assertTrue(cfg.eligibility.items == before.eligibilityItems,
        "rollback restores original eligibility.items map")
    local eligCountAfter = 0
    for _ in pairs(cfg.eligibility.items) do
        eligCountAfter = eligCountAfter + 1
    end
    assertEq(eligCountAfter, before.eligItemCount, "rollback leaves prior eligibility items untouched")
    assertEq(cfg.eligibility and cfg.eligibility.baselineAt, before.eligibilityBaseline,
        "rollback restores eligibility baselineAt")
    assertEq(cfg.eligibility and cfg.eligibility.tabEligibleFrom, before.eligibilityTab,
        "rollback restores eligibility tabEligibleFrom")
    assertEq(record.operations.heads[GS.CAMPAIGN_TARGET_KEY], before.head, "rollback restores campaign head")
    assertNil(record.operations.records[op.id], "rejected op not accepted")
    assertNil(record.campaigns[op.id], "rejected campaign header removed")
    local archiveCount = 0
    for _ in pairs(record.campaignArchives or {}) do
        archiveCount = archiveCount + 1
    end
    assertEq(archiveCount, before.archiveCount, "rollback removes newly inserted archive only")
    assertTrue(record.campaigns[first.id] ~= nil, "prior campaign retained")

    -- Successful reset installs fresh empty eligibility and leaves the old map intact.
    local oldElig = cfg.eligibility
    local oldItems = cfg.eligibility.items
    local oldCount = before.eligItemCount
    local okOp = startCampaign()
    record = GS:GetCurrentRecord()
    cfg = record.accounting._consumables
    assertTrue(cfg.eligibility ~= oldElig, "success installs fresh eligibility object")
    assertTrue(cfg.eligibility.items ~= oldItems, "success installs fresh eligibility.items")
    local freshCount = 0
    for _ in pairs(cfg.eligibility.items) do
        freshCount = freshCount + 1
    end
    assertEq(freshCount, 0, "success uses empty eligibility.items baseline")
    local retainedCount = 0
    for _ in pairs(oldItems) do
        retainedCount = retainedCount + 1
    end
    assertEq(retainedCount, oldCount, "old eligibility.items map not traversed/cleared on success")
    assertTrue(record.campaigns[okOp.id] ~= nil, "successful campaign present")
end

-- 2B14) Archive ledger + adjustment attribution in projections and history
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local camp1 = startCampaign()
    local record = GS:GetCurrentRecord()
    local gen1 = record.accounting._consumables.generation
    record.accounting._consumableEvents[#record.accounting._consumableEvents + 1] = {
        id = "ev-don-1",
        type = "donation",
        itemId = 200,
        quantity = 4,
        actor = "Bob-Garona",
        generation = gen1,
        timestamp = world.time,
        source = "guildbank",
    }
    record.accounting._consumableEvents[#record.accounting._consumableEvents + 1] = {
        id = "ev-adj-1",
        type = "adjustment",
        itemId = 200,
        quantity = -1,
        actor = "Alice-Garona",
        attributed = "Bob-Garona",
        generation = gen1,
        timestamp = world.time + 1,
    }
    record.accounting._consumableEvents[#record.accounting._consumableEvents + 1] = {
        id = "ev-adj-2",
        type = "adjustment",
        itemId = 200,
        quantity = 2,
        actor = "Alice-Garona",
        attributed = nil,
        generation = gen1,
        timestamp = world.time + 2,
    }

    local progress = GS:ProjectCampaignProgress(camp1.id)
    assertEq(progress.itemTotals[200], 5, "live donation+adjustments item total")
    assertEq(progress.contributions["Bob-Garona"][200], 3, "attributed adjustment credits contributor")

    local camp2 = startCampaign()
    -- Move gen1 events into archive after reset (simulates retention).
    record = GS:GetCurrentRecord()
    local archive = record.accounting._consumableEventArchive
    if type(archive) ~= "table" then
        record.accounting._consumableEventArchive = {}
        archive = record.accounting._consumableEventArchive
    end
    local live = record.accounting._consumableEvents
    local kept = {}
    for i = 1, #live do
        if tonumber(live[i].generation) == gen1 then
            archive[#archive + 1] = live[i]
        else
            kept[#kept + 1] = live[i]
        end
    end
    record.accounting._consumableEvents = kept

    progress = GS:ProjectCampaignProgress(camp1.id)
    assertEq(progress.itemTotals[200], 5, "archived campaign totals include archive ledger")
    assertEq(progress.contributions["Bob-Garona"][200], 3, "archived attribution preserved")

    local currentProgress = GS:ProjectCampaignProgress(camp2.id)
    assertEq(currentProgress.itemTotals[200] or 0, 0, "new campaign isolated from prior totals")

    local rows, total = GS:ListCampaignHistory(camp1.id, 10, 0)
    assertEq(total, 3, "history total for archived campaign")
    assertEq(#rows, 3, "history rows returned")
    assertTrue(rows[1].text:find("adjusted", 1, true) or rows[1].text:find("donated", 1, true),
        "history text formatted")

    -- Overlapping accepted IDs across live+archive must count once in totals/history.
    -- Distinct IDs with identical payloads still count separately.
    record = GS:GetCurrentRecord()
    local liveList = record.accounting._consumableEvents
    local archList = record.accounting._consumableEventArchive
    local overlapDon = {
        id = "ev-don-1",
        type = "donation",
        itemId = 200,
        quantity = 4,
        actor = "Bob-Garona",
        generation = gen1,
        timestamp = world.time,
        source = "guildbank",
    }
    local overlapAdj = {
        id = "ev-adj-1",
        type = "adjustment",
        itemId = 200,
        quantity = -1,
        actor = "Alice-Garona",
        attributed = "Bob-Garona",
        generation = gen1,
        timestamp = world.time + 1,
    }
    liveList[#liveList + 1] = overlapDon
    liveList[#liveList + 1] = overlapAdj
    archList[#archList + 1] = {
        id = "ev-don-dup-payload",
        type = "donation",
        itemId = 200,
        quantity = 4,
        actor = "Bob-Garona",
        generation = gen1,
        timestamp = world.time + 3,
        source = "guildbank",
    }
    progress = GS:ProjectCampaignProgress(camp1.id)
    -- Original 5 + distinct-id duplicate donation 4 = 9; overlapping IDs not double-counted.
    assertEq(progress.itemTotals[200], 9, "overlapping event IDs deduped in item totals")
    assertEq(progress.contributions["Bob-Garona"][200], 7,
        "overlapping IDs deduped in contributor totals")
    rows, total = GS:ListCampaignHistory(camp1.id, 20, 0)
    assertEq(total, 4, "history dedupes overlapping IDs; distinct IDs remain")
    local currentProgress2 = GS:ProjectCampaignProgress(camp2.id)
    assertEq(currentProgress2.itemTotals[200] or 0, 0, "new campaign still isolated after overlap fixture")
end

-- 2B14b) Missing vs empty new-goal archives; invalid current generations
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    -- Pre-campaign generation 0 remains usable for first New Campaign.
    assertEq(GS:GetCurrentRecord().accounting._consumables.generation, 0,
        "fresh setup generation 0")
    local campEmpty = startCampaign()
    local record = GS:GetCurrentRecord()
    assertEq(record.accounting._consumables.generation, 1, "first campaign generation 1")
    -- Valid empty archived snapshot (requestedItems={}) is inspectable/readable.
    local campAfterEmpty = startCampaign()
    record = GS:GetCurrentRecord()
    local emptyArchive = record.campaignArchives[campEmpty.id]
    assertTrue(type(emptyArchive) == "table", "empty campaign has archive snapshot")
    emptyArchive.requestedItems = {}
    assertEq(GS.ValidateCampaignArchive(emptyArchive, campEmpty.id, record), true,
        "validated empty archive remains valid")
    local emptyItems, emptyErr = GS:GetCampaignRequestedItems(campEmpty.id)
    assertEq(emptyErr, nil, "valid empty archive has no error")
    assertTrue(type(emptyItems) == "table", "valid empty archive returns table")
    local emptyCount = 0
    for _ in pairs(emptyItems) do emptyCount = emptyCount + 1 end
    assertEq(emptyCount, 0, "valid empty archive returns empty map")
    local listEmpty = GS:ListInspectableCampaigns()
    local sawEmpty = false
    for i = 1, #listEmpty do
        if listEmpty[i].campaignId == campEmpty.id then sawEmpty = true end
    end
    assertEq(sawEmpty, true, "valid empty archive remains inspectable")

    -- Missing required new-goal archive is unavailable (not successful empty).
    record.campaignArchives[campEmpty.id] = nil
    local missingItems, missingErr = GS:GetCampaignRequestedItems(campEmpty.id)
    assertEq(missingItems, nil, "missing archive items unavailable")
    assertEq(missingErr, "missing_campaign_archive", "missing archive reason")
    local missProgress, missProgErr = GS:ProjectCampaignProgress(campEmpty.id)
    assertEq(missProgress, nil, "missing archive progress unavailable")
    assertEq(missProgErr, "missing_campaign_archive", "progress missing archive reason")
    local listMissing = GS:ListInspectableCampaigns()
    local sawMissing = false
    for i = 1, #listMissing do
        if listMissing[i].campaignId == campEmpty.id then sawMissing = true end
    end
    assertEq(sawMissing, false, "missing archive excluded from inspectable selector")
    assertTrue(GS:GetCurrentRecord() ~= nil, "current record usable with missing historical archive")
    local curItems = GS:GetCampaignRequestedItems(campAfterEmpty.id)
    assertTrue(type(curItems) == "table", "current campaign reads remain independent")

    -- Non-table retained archive is also unavailable / excluded.
    record.campaignArchives[campEmpty.id] = "not-a-table"
    local badItems, badErr = GS:GetCampaignRequestedItems(campEmpty.id)
    assertEq(badItems, nil, "non-table archive unavailable")
    assertEq(badErr, "missing_campaign_archive", "non-table archive treated as missing snapshot")
    local listBad = GS:ListInspectableCampaigns()
    local sawBad = false
    for i = 1, #listBad do
        if listBad[i].campaignId == campEmpty.id then sawBad = true end
    end
    assertEq(sawBad, false, "non-table archive excluded from inspectable")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].campaignArchives[campEmpty.id],
        "not-a-table", "malformed archive retained in SV")
    record.campaignArchives[campEmpty.id] = nil

    -- Invalid current generations reject archival/reset; state unchanged.
    local function assertGenReject(mutate, label)
        resetDb()
        initGS()
        setPlayer("Alice-Garona", "Player-1-Alice", 1)
        world.guild.clubId = 42
        GS:CreateStagedRecord()
        local camp = startCampaign()
        local rec = GS:GetCurrentRecord()
        rec.accounting._consumables.requestedItems["77"] = { itemId = 77, goal = 3 }
        local genBefore = rec.accounting._consumables.generation
        local events = rec.accounting._consumableEvents
        events[#events + 1] = {
            id = "ev-gen-" .. label,
            type = "donation",
            itemId = 77,
            quantity = 2,
            actor = "Bob-Garona",
            generation = genBefore,
            timestamp = world.time,
            source = "guildbank",
        }
        local op = GS:NewCampaignOperation()
        assertTrue(op ~= nil, label .. " prepare while generation valid")
        mutate(rec.accounting._consumables)
        local corruptedGen = rec.accounting._consumables.generation
        local st, reason = GS:ApplyStagedCampaignOperation(op)
        assertEq(st, "rejected", label .. " apply rejected")
        assertEq(reason, "invalid_generation", label .. " reason invalid_generation")
        local raw = SpectrumFederationDB.guildSupplies.guilds["club:42"]
        assertEq(raw.currentCampaignId, camp.id, label .. " campaign unchanged")
        assertEq(raw.accounting._consumables.requestedItems["77"].goal, 3,
            label .. " live goals unchanged")
        assertEq(raw.accounting._consumables.generation, corruptedGen,
            label .. " stored generation retained")
        -- Restore for isolation proof after a valid subsequent reset.
        raw.accounting._consumables.generation = genBefore
        assertTrue(GS:GetCurrentRecord() ~= nil, label .. " restored usable")
        local nextCamp = startCampaign()
        local progOld = GS:ProjectCampaignProgress(camp.id)
        assertEq(progOld.itemTotals[77], 2, label .. " prior donation stays on archived campaign")
        local progNew = GS:ProjectCampaignProgress(nextCamp.id)
        assertEq(progNew.itemTotals[77] or 0, 0, label .. " new campaign isolated from prior donation")
        assertTrue(raw.accounting._consumables.generation ~= genBefore,
            label .. " valid reset advances generation")
    end

    assertGenReject(function(cfg)
        cfg.generation = nil
    end, "missing")
    assertGenReject(function(cfg)
        cfg.generation = 0
    end, "zero")
    assertGenReject(function(cfg)
        cfg.generation = "nope"
    end, "nonnumeric")
    assertGenReject(function(cfg)
        cfg.generation = 1.5
    end, "fractional")
    assertGenReject(function(cfg)
        cfg.generation = math.huge
    end, "infinite")
end

-- 2B15–2B16) Production DefinitionRenderer page contracts (Build/Refresh/mutations)
do
    local created = {}
    local function fire(region, event, ...)
        local script = region.scripts and region.scripts[event]
        if script then script(region, ...) end
        for _, hook in ipairs((region.hooks and region.hooks[event]) or {}) do
            hook(region, ...)
        end
    end
    local function makeRegion(kind, name, parent, template)
        local region = {
            kind = kind,
            name = name,
            parent = parent,
            shown = true,
            height = 40,
            width = 400,
            points = {},
            scripts = {},
            hooks = {},
            children = {},
            text = "",
            enabled = true,
            focused = false,
            registeredEvents = {},
        }
        created[#created + 1] = region
        if parent and parent.children then
            parent.children[#parent.children + 1] = region
        end
        function region:GetObjectType() return self.kind or "Frame" end
        function region:SetPoint(point, relativeTo, relativePoint, x, y)
            if type(relativeTo) == "number" then
                x, y = relativeTo, relativePoint
                relativeTo, relativePoint = nil, point
            elseif type(relativePoint) == "number" then
                x, y = relativePoint, x
                relativePoint = point
            end
            self.points[#self.points + 1] = {
                point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x or 0, y = y or 0,
            }
        end
        function region:ClearAllPoints() self.points = {} end
        function region:SetAllPoints(target) self.allPoints = target or self.parent end
        function region:SetHeight(h) self.height = tonumber(h) or 0 end
        function region:GetHeight() return self.height end
        function region:SetWidth(w) self.width = tonumber(w) or 0 end
        function region:GetWidth() return self.width end
        function region:SetSize(w, h) self:SetWidth(w); self:SetHeight(h) end
        function region:Show() self.shown = true end
        function region:Hide() self.shown = false end
        function region:IsShown() return self.shown and true or false end
        function region:SetShown(v) self.shown = v and true or false end
        function region:SetAlpha() end
        function region:SetScript(event, fn) self.scripts[event] = fn end
        function region:HookScript(event, fn)
            self.hooks[event] = self.hooks[event] or {}
            self.hooks[event][#self.hooks[event] + 1] = fn
        end
        function region:EnableMouse() end
        function region:SetHitRectInsets() end
        function region:Enable() self.enabled = true end
        function region:Disable() self.enabled = false end
        function region:SetEnabled(v) self.enabled = v and true or false end
        function region:IsEnabled() return self.enabled end
        function region:SetText(t) self.text = tostring(t or "") end
        function region:GetText() return self.text end
        function region:SetTextColor() end
        function region:SetJustifyH() end
        function region:SetJustifyV() end
        function region:SetWordWrap() end
        function region:SetNonSpaceWrap() end
        function region:SetMaxLines() end
        function region:SetAutoFocus() end
        function region:SetNumeric() end
        function region:SetMaxLetters() end
        function region:SetHighlightColor() end
        function region:SetCursorPosition() end
        function region:HasFocus() return self.focused end
        function region:ClearFocus()
            self.focused = false
            fire(self, "OnEditFocusLost")
        end
        function region:SetFocus() self.focused = true end
        function region:GetStringWidth() return math.max(1, #(self.text or "") * 7) end
        function region:GetStringHeight() return 12 end
        function region:SetColorTexture() end
        function region:SetTexture() end
        function region:SetAtlas() end
        function region:SetTexCoord() end
        function region:SetVertexColor() end
        function region:SetBlendMode() end
        function region:SetVerticalScroll() end
        function region:SetScrollChild(child) self.scrollChild = child end
        function region:CreateTexture() return makeRegion("Texture", nil, self) end
        function region:CreateFontString() return makeRegion("FontString", nil, self) end
        function region:CreateFrame() return makeRegion("Frame", nil, self) end
        function region:RegisterEvent(e) self.registeredEvents[e] = true end
        function region:UnregisterAllEvents() self.registeredEvents = {} end
        function region:SetDefaultText(t) self.defaultText = t end
        function region:SetupMenu(gen)
            self.menuGenerator = gen
            self.menuOptions = {}
            local root = {
                CreateRadio = function(_, label, isSelected, setSelected, value)
                    self.menuOptions[#self.menuOptions + 1] = {
                        label = label, value = value, isSelected = isSelected, setSelected = setSelected,
                    }
                end,
            }
            if type(gen) == "function" then
                gen(self, root)
            end
        end
        function region:GenerateMenu()
            if self.menuGenerator then self:SetupMenu(self.menuGenerator) end
        end
        if template == "UIPanelScrollFrameTemplate" then
            region.ScrollBar = makeRegion("Slider", nil, region)
            region.ScrollBar:SetWidth(20)
            region.ScrollBar.shown = false
        end
        function region:SetChecked(v) self.checked = v and true or false end
        function region:GetChecked() return self.checked and true or false end
        function region:SetNormalFontObject() end
        function region:SetHighlightFontObject() end
        function region:SetDisabledFontObject() end
        function region:SetNormalTexture() end
        function region:SetPushedTexture() end
        function region:SetHighlightTexture() end
        function region:SetCheckedTexture() end
        function region:SetDisabledCheckedTexture() end
        function region:RegisterForClicks() end
        function region:Click()
            fire(self, "OnClick")
        end
        function region:SetFontObject() end
        function region:SetFont() end
        function region:GetFont() return "Fonts\\FRIZQT__.TTF", 12 end
        function region:SetParent(p) self.parent = p end
        function region:GetParent() return self.parent end
        function region:SetFrameStrata() end
        function region:SetFrameLevel() end
        function region:SetClipsChildren() end
        function region:EnableDrawLayer() end
        function region:DisableDrawLayer() end
        function region:SetPropagateKeyboardInput() end
        function region:SetObeyStepOnDrag() end
        function region:SetMinMaxValues() end
        function region:SetValueStep() end
        function region:SetValue() end
        function region:GetValue() return self.value or 0 end
        function region:SetOrientation() end
        function region:SetThumbTexture() end
        function region:SetStatusBarTexture() end
        function region:SetStatusBarColor() end
        function region:GetName() return self.name end
        return region
    end

    local priorCreateFrame = CreateFrame
    function CreateFrame(frameType, name, parent, template)
        return makeRegion(frameType or "Frame", name, parent, template)
    end

    -- Minimal Settings chrome dependencies.
    GameTooltip = GameTooltip or {
        Hide = function() end, SetOwner = function() end, SetText = function() end,
        AddLine = function() end, Show = function() end,
    }
    OKAY = OKAY or "OK"
    CANCEL = CANCEL or "Cancel"
    if type(CopyTable) ~= "function" then
        function CopyTable(t)
            if type(t) ~= "table" then return t end
            local out = {}
            for k, v in pairs(t) do
                if type(v) == "table" then
                    out[k] = CopyTable(v)
                else
                    out[k] = v
                end
            end
            return out
        end
    end
    StaticPopupDialogs = StaticPopupDialogs or {}
    local pendingConfirm
    function StaticPopup_Show(key, message, _, data)
        pendingConfirm = { key = key, message = message, data = data }
        return { key = key }
    end

    SF.SettingsUI = SF.SettingsUI or {}
    SF.SettingsUI.pagesById = {}
    SF.SettingsUI.pages = {}
    SF.SettingsUI.categories = {}
    function SF.SettingsUI:RegisterCategory(cat)
        self.categories[cat.id] = cat
    end
    function SF.SettingsUI:RegisterPage(page)
        self.pagesById[page.id] = page
        self.pages[#self.pages + 1] = page
    end
    SF.SettingsStore = {
        Get = function(_, _) return true end,
        Set = function() end,
    }

    loadModule("SpectrumFederation/modules/UI/Settings/Style.lua")
    loadModule("SpectrumFederation/modules/UI/Settings/Widgets/Section.lua")
    loadModule("SpectrumFederation/modules/UI/Settings/PageBuilder.lua")
    loadModule("SpectrumFederation/modules/UI/Settings/Control/Controls.lua")
    loadModule("SpectrumFederation/modules/UI/Settings/Dialogs.lua")
    loadModule("SpectrumFederation/modules/UI/Settings/DefinitionRenderer.lua")
    loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesConfiguration.lua")
    loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesLogs.lua")

    local configPage = SF.SettingsUI.pagesById.guildSuppliesConfiguration
    local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
    assertTrue(configPage ~= nil, "Configuration page registered")
    assertTrue(logsPage ~= nil, "Logs page registered")
    assertTrue(type(configPage.Build) == "function" and type(configPage.Refresh) == "function",
        "Configuration exposes Build/Refresh")
    assertTrue(type(logsPage.Build) == "function" and type(logsPage.Refresh) == "function",
        "Logs exposes Build/Refresh")
    assertEq(SF.SettingsUI.categories.guildSupplies.name, "Guild Supplies",
        "category name localized through Loc default")

    local function findEditBoxes(node, out)
        out = out or {}
        if node.kind == "EditBox" then
            out[#out + 1] = node
        end
        for _, child in ipairs(node.children or {}) do
            findEditBoxes(child, out)
        end
        return out
    end
    local function findButtons(node, out)
        out = out or {}
        if node.kind == "Button" and node.text then
            out[#out + 1] = node
        end
        for _, child in ipairs(node.children or {}) do
            findButtons(child, out)
        end
        return out
    end
    local function findDropdowns(node, out)
        out = out or {}
        if node.kind == "DropdownButton" then
            out[#out + 1] = node
        end
        for _, child in ipairs(node.children or {}) do
            findDropdowns(child, out)
        end
        return out
    end

    -- Configuration: Build renders; bank-tab onCommit; New Campaign confirmation binding.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()

    local configPanel = makeRegion("Frame", "GSConfigPanel", nil)
    configPanel:SetSize(600, 800)
    local beforeBuild = #created
    configPage:Build(configPanel)
    assertTrue(#created > beforeBuild, "Configuration Build creates controls")
    assertTrue(configPanel.__sfPageBuilder ~= nil, "Configuration uses DefinitionRenderer:Build")
    local pageDef = configPanel.__sfPageDef
    assertTrue(type(pageDef) == "table", "Build stores page definition")
    local foundBankCommit, foundGoalCommit, foundHelpGetText = false, false, false
    for _, sec in ipairs(pageDef.sections or {}) do
        for _, item in ipairs(sec.items or {}) do
            if item.type == "editbox" and type(item.onCommit) == "function" then
                foundBankCommit = true
            end
            if item.type == "consumableRequestedList" and type(item.onGoalCommit) == "function" then
                foundGoalCommit = true
            end
            if item.type == "help" and type(item.getText) == "function" then
                foundHelpGetText = true
            end
        end
    end
    assertTrue(foundBankCommit, "bank tab uses onCommit")
    assertTrue(foundGoalCommit, "requested list uses onGoalCommit")
    assertTrue(foundHelpGetText, "status help uses getText")

    local edits = findEditBoxes(configPanel)
    assertTrue(#edits >= 1, "bank tab editbox present")
    local bankEdit = edits[1]
    bankEdit:SetText("2")
    fire(bankEdit, "OnEnterPressed")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 2, "onCommit sets bank tab")

    bankEdit:SetText("")
    fire(bankEdit, "OnEditFocusLost")
    assertNil(GS:GetCurrentRecord().accounting._consumables.bankTab, "onCommit clear removes bank tab")

    -- Rejected invalid tab leaves state unchanged.
    local opSet = GS:NewConfigOperation("set-bank-tab", "bankTab", 3)
    GS:ApplyStagedConfigOperation(opSet)
    bankEdit:SetText("9")
    local messages = {}
    local section = configPanel.__sfSections and configPanel.__sfSections.gsStatus
    if section then
        local priorSet = section.SetMessage
        section.SetMessage = function(self, msg, sev)
            messages[#messages + 1] = { msg = msg, sev = sev }
            if priorSet then priorSet(self, msg, sev) end
        end
    end
    fire(bankEdit, "OnEnterPressed")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 3, "invalid tab leaves state")

    -- New Campaign: bind before confirm; cancel leaves state; accept applies bound op.
    local buttons = findButtons(configPanel)
    local newCampaignBtn
    for i = 1, #buttons do
        if buttons[i].text == "New Campaign" then
            newCampaignBtn = buttons[i]
            break
        end
    end
    assertTrue(newCampaignBtn ~= nil, "New Campaign button present")
    local beforeCampaign = GS:GetCurrentRecord().currentCampaignId
    pendingConfirm = nil
    newCampaignBtn:Click()
    assertTrue(pendingConfirm ~= nil, "New Campaign shows confirmation")
    -- Cancel: do not invoke accept.
    assertEq(GS:GetCurrentRecord().currentCampaignId, beforeCampaign, "cancel leaves campaign")
    -- Accept bound op.
    local acceptFn = pendingConfirm.data
    assertTrue(type(acceptFn) == "function", "confirm binds accept function")
    acceptFn()
    assertTrue(GS:GetCurrentRecord().currentCampaignId ~= beforeCampaign, "accept starts new campaign")

    -- Concurrent campaign change while the dialog is open keeps the bound op from applying.
    pendingConfirm = nil
    newCampaignBtn:Click()
    local boundAccept = pendingConfirm.data
    assertTrue(type(boundAccept) == "function", "stale-case confirm binds accept")
    local concurrent = GS:NewCampaignOperation()
    local concStatus = GS:ApplyStagedCampaignOperation(concurrent)
    assertEq(concStatus, "accepted", "concurrent campaign applies while dialog open")
    local midCampaign = GS:GetCurrentRecord().currentCampaignId
    local okCall = pcall(boundAccept)
    assertTrue(okCall, "bound accept does not error")
    assertEq(GS:GetCurrentRecord().currentCampaignId, midCampaign,
        "stale bound campaign op does not overwrite newer campaign")
    assertTrue(GS:GetCurrentRecord().operations.records[concurrent.id] ~= nil,
        "concurrent accepted op retained")

    -- Cached Refresh after setup/campaign changes (no rebuild).
    local refreshCalls = 0
    local realRefresh = SF.SettingsUI.DefinitionRenderer.Refresh
    SF.SettingsUI.DefinitionRenderer.Refresh = function(self, panel)
        refreshCalls = refreshCalls + 1
        return realRefresh(self, panel)
    end
    configPage:Refresh(configPanel)
    assertEq(refreshCalls, 1, "Configuration Refresh uses renderer:Refresh")
    configPanel.shown = false
    configPage:Refresh(configPanel)
    assertEq(refreshCalls, 1, "hidden Configuration skips Refresh")
    configPanel.shown = true
    SF.SettingsUI.DefinitionRenderer.Refresh = realRefresh

    -- Logs: Build/reopen without openCount crash; dropdown labels; history rows.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local c1 = startCampaign()
    local r = GS:GetCurrentRecord()
    local gen = r.accounting._consumables.generation
    r.accounting._consumableEvents[#r.accounting._consumableEvents + 1] = {
        id = "ui-don",
        type = "donation",
        itemId = 50,
        quantity = 3,
        actor = "Carol-Garona",
        generation = gen,
        timestamp = world.time,
        source = "guildbank",
    }
    startCampaign()

    local logsPanel = makeRegion("Frame", "GSLogsPanel", nil)
    logsPanel:SetSize(600, 800)
    logsPage:Build(logsPanel)
    assertTrue(logsPanel.__sfPageBuilder ~= nil, "Logs uses DefinitionRenderer:Build")
    logsPage:Build(logsPanel) -- reopen / rebuild
    assertTrue(logsPanel.__sfPageBuilder ~= nil, "Logs rebuild succeeds (no openCount crash)")

    local drops = findDropdowns(logsPanel)
    assertTrue(#drops >= 1, "campaign dropdown present")
    local drop = drops[1]
    assertTrue(type(drop.menuOptions) == "table" and #drop.menuOptions >= 1, "dropdown options built")
    local labeled = false
    for i = 1, #drop.menuOptions do
        local lab = tostring(drop.menuOptions[i].label or "")
        if lab:find("Current", 1, true) or lab:find("Archived", 1, true) then
            labeled = true
            break
        end
    end
    assertTrue(labeled, "dropdown options use readable labels not raw ids only")

    logsPage:Refresh(logsPanel)
    -- Select archived campaign via set path and refresh history.
    if drop.menuOptions[1] and drop.menuOptions[1].setSelected then
        drop.menuOptions[1].setSelected(drop.menuOptions[1].value)
    end
    logsPage:Refresh(logsPanel)
    local histRows, histTotal = GS:ListCampaignHistory(c1.id, 25, 0)
    assertTrue((histTotal or 0) >= 1, "history projection available for UI")

    -- Small-guild explicit threshold through CreateStagedRecord path used by UI.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    world.guild.ranks = { "Guild Master", "Member" }
    settleRoster()
    local _, stInit, errInit = GS:CreateStagedRecord()
    assertEq(stInit, "rejected", "small guild without threshold rejected")
    assertEq(errInit, "threshold_unselected", "threshold_unselected")
    local recInit, stOk = GS:CreateStagedRecord(2)
    assertEq(stOk, "accepted", "small guild with explicit threshold accepted")
    assertEq(recInit.permission.editorRankPosition, 2, "selected threshold stored")
    world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    settleRoster()

    CreateFrame = priorCreateFrame
end

-- 2B17) Confirmation start-time finalization, reason fallback, BankLog freshness lifecycle
do
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local op = GS:NewCampaignOperation()
    local preparedTs = op.timestamp
    local preparedBase = op.baseTargetRevision
    local preparedPolicy = op.basePolicyRevision
    local preparedGuild = op.guildKey
    world.time = world.time + 120
    local okFinal, finalErr = GS:FinalizeCampaignStartTime(op)
    assertEq(okFinal, true, "finalize start time ok: " .. tostring(finalErr))
    assertTrue(op.timestamp ~= preparedTs, "timestamp finalized at accept time")
    assertEq(op.timestamp, math.floor(world.time), "final timestamp uses accept-time server time")
    assertEq(op.baseTargetRevision, preparedBase, "base target preserved")
    assertEq(op.basePolicyRevision, preparedPolicy, "base policy preserved")
    assertEq(op.guildKey, preparedGuild, "guild scope preserved")
    local status = GS:ApplyStagedCampaignOperation(op)
    assertEq(status, "accepted", "delayed finalize then apply accepted")
    assertEq(GS:GetCurrentRecord().campaigns[op.id].startedAt, op.timestamp,
        "campaign startedAt uses finalized timestamp")
    -- Exact retry must not restamp.
    local priorTs = op.timestamp
    world.time = world.time + 50
    assertEq(GS:FinalizeCampaignStartTime(op), true, "finalize no-op after accept")
    assertEq(op.timestamp, priorTs, "accepted body timestamp not restamped")
    assertEq(GS:ApplyStagedCampaignOperation(op), "duplicate", "exact replay remains duplicate")

    local generic = GS.FormatReasonText("totally_unknown_code_xyz")
    assertTrue(generic:find("could not be applied", 1, true), "generic reason localized")
    assertEq(generic:find("totally_unknown_code_xyz", 1, true), nil, "generic reason hides raw code")
    assertTrue(GS.FormatReasonText("no_campaign"):find("New Campaign", 1, true),
        "mapped no_campaign wording")
    assertTrue(GS.FormatReasonText("stale_handle"):find("out of date", 1, true),
        "mapped stale_handle wording")

    -- Production BankLog → adapter lifecycle (RequestLog / CancelTimers / ProcessLogUpdate).
    GS._BankContextReadinessProbe = nil
    world.bankTxnCounts = { [1] = 0 }
    world.bankTabInfo = {
        [1] = { name = "Supplies", isViewable = true },
    }
    world.logQueries = {}
    world.afterFns = {}
    function GetNumGuildBankTransactions(tab) return world.bankTxnCounts[tab] or 0 end
    function GetGuildBankTransaction()
        return "deposit", "Alice-Garona", nil, 1, nil, nil, 0, 1, 1, 1
    end
    function GetGuildBankTabInfo(tab)
        local info = world.bankTabInfo[tab]
        if not info then return nil end
        return info.name, nil, info.isViewable
    end
    function QueryGuildBankLog(tab)
        world.logQueries[#world.logQueries + 1] = tab
    end
    local priorAfter = C_Timer and C_Timer.After
    C_Timer = C_Timer or {}
    C_Timer.After = function(_, fn)
        world.afterFns[#world.afterFns + 1] = fn
    end
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesBankLog.lua")
    local BankLog = SF.ConsumablesBankLog
    BankLog.active = true
    BankLog.bankOpen = true
    BankLog.awaitingLogUpdate = false
    BankLog.queryRetries = 0
    BankLog.queryToken = 0
    BankLog.activeContext = {
        bankTab = 1, guildGuid = "42", profileId = "p-gs",
        generation = 1, requestedSet = { [10] = true }, observedBy = "Alice-Garona",
    }
    BankLog.lastFreshLogTab = 1
    BankLog.lastFreshLogGuild = "42"
    BankLog.lastFreshLogAt = world.time
    local priorEligible = BankLog.EligibleContext
    function BankLog:EligibleContext()
        return self.activeContext
    end

    assertEq(GS.IsBankContextSampleReady(1), true, "viewable stamped tab is ready")
    local ctx = GS.CaptureBankContext(1)
    assertEq(ctx.status, "empty", "ready viewable tab may be empty")

    -- New query invalidates prior stamp via production RequestLog.
    BankLog:RequestLog("test")
    assertEq(BankLog.lastFreshLogTab, nil, "RequestLog clears freshness stamp")
    assertEq(BankLog.awaitingLogUpdate, true, "RequestLog awaits update")
    assertEq(GS.CaptureBankContext(1).status, "unavailable", "awaiting query is unavailable")
    assertEq(GS.CaptureBankContext(1).reason, "log_pending", "log_pending while awaiting")

    -- Failed ProcessLogUpdate clears stamp and awaiting.
    BankLog.lastFreshLogTab = 1
    BankLog.lastFreshLogGuild = "42"
    local priorCount = GetNumGuildBankTransactions
    GetNumGuildBankTransactions = function() return "bad" end
    BankLog:ProcessLogUpdate("failed")
    assertEq(BankLog.lastFreshLogTab, nil, "failed ProcessLogUpdate clears stamp")
    assertEq(BankLog.awaitingLogUpdate, false, "failed ProcessLogUpdate clears awaiting")
    GetNumGuildBankTransactions = priorCount

    -- Exhaustion path clears stamp.
    BankLog.lastFreshLogTab = 1
    BankLog.lastFreshLogGuild = "42"
    BankLog.awaitingLogUpdate = true
    BankLog.queryRetries = 5
    BankLog:RequestLog("retry")
    assertEq(BankLog.lastFreshLogTab, nil, "exhausted RequestLog clears stamp before terminal wait")
    local terminal = world.afterFns[#world.afterFns]
    assertTrue(type(terminal) == "function", "exhaustion schedules terminal callback")
    terminal()
    assertEq(BankLog.awaitingLogUpdate, false, "exhaustion clears awaiting")
    assertEq(BankLog.lastFreshLogTab, nil, "exhaustion keeps stamp cleared")

    -- Successful update restores stamp.
    BankLog.awaitingLogUpdate = true
    GetNumGuildBankTransactions = function() return 0 end
    BankLog:ProcessLogUpdate("success")
    assertEq(BankLog.lastFreshLogTab, 1, "successful update restores stamp")
    assertEq(GS.CaptureBankContext(1).status, "empty", "restored stamp allows empty")

    -- Slot-change inside throttle: invalidate stamp without issuing another query.
    world.logQueries = {}
    BankLog.awaitingLogUpdate = false
    BankLog.lastQueryAt = world.time
    BankLog.lastFreshLogTab = 1
    BankLog.lastFreshLogGuild = "42"
    BankLog.lastFreshLogAt = world.time
    BankLog:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertEq(#world.logQueries, 0, "throttled slots_changed does not query")
    assertEq(BankLog.lastFreshLogTab, nil, "slots_changed clears stamp inside throttle")
    assertEq(GS.IsBankContextSampleReady(1), false, "readiness unavailable after throttled slot change")
    assertEq(select(2, GS.IsBankContextSampleReady(1)), "log_not_updated",
        "throttled slot change reason is log_not_updated")
    assertEq(GS.CaptureBankContext(1).status, "unavailable",
        "CaptureBankContext unavailable after throttled slot change")
    -- Genuine successful update restores readiness without requiring a new query first.
    BankLog.awaitingLogUpdate = true
    BankLog:ProcessLogUpdate("slot_restore")
    assertEq(BankLog.lastFreshLogTab, 1, "successful update restores stamp after slot invalidate")
    assertEq(GS.IsBankContextSampleReady(1), true, "readiness restored after successful update")

    -- Slot change while a query is already outstanding: clear stamp, coalesce query.
    world.logQueries = {}
    BankLog.awaitingLogUpdate = true
    BankLog.lastFreshLogTab = 1
    BankLog.lastFreshLogGuild = "42"
    BankLog:OnEvent("GUILDBANKBAGSLOTS_CHANGED")
    assertEq(#world.logQueries, 0, "outstanding slots_changed does not start a second query")
    assertEq(BankLog.lastFreshLogTab, nil, "outstanding slots_changed clears stamp")
    assertEq(BankLog.awaitingLogUpdate, true, "outstanding query remains awaiting")
    assertEq(select(2, GS.IsBankContextSampleReady(1)), "log_pending",
        "outstanding slots_changed stays log_pending")

    -- Production CancelTimers clears stamp and awaiting.
    BankLog.lastFreshLogTab = 1
    BankLog.lastFreshLogGuild = "42"
    BankLog.awaitingLogUpdate = true
    BankLog:CancelTimers("test_cancel")
    assertEq(BankLog.lastFreshLogTab, nil, "CancelTimers clears freshness stamp")
    assertEq(BankLog.awaitingLogUpdate, false, "CancelTimers clears awaiting")
    assertEq(GS.IsBankContextSampleReady(1), false, "CancelTimers leaves readiness unavailable")

    -- Denied / unknown tab access.
    BankLog.awaitingLogUpdate = false
    BankLog.lastFreshLogTab = 1
    BankLog.lastFreshLogGuild = "42"
    world.bankTabInfo[1].isViewable = false
    local deniedReady, deniedReason = GS.IsBankContextSampleReady(1)
    assertEq(deniedReady, false, "denied tab access not ready")
    assertEq(deniedReason, "tab_access_denied", "denied reason")
    assertEq(GS.CaptureBankContext(1).status, "unavailable", "denied access is unavailable")
    world.bankTabInfo[1].isViewable = true
    world.bankTabInfo[1].name = nil
    assertEq(select(2, GS.IsBankContextSampleReady(1)), "tab_access_unknown", "unknown access")
    -- New Campaign still succeeds when context unavailable.
    world.bankTabInfo[1] = { name = "Supplies", isViewable = true }
    BankLog.lastFreshLogTab = nil
    local campOp = GS:NewCampaignOperation()
    assertTrue(campOp ~= nil, "New Campaign prepared while bank unavailable")
    assertEq(GS:ApplyStagedCampaignOperation(campOp), "accepted", "New Campaign accepted without bank context")

    BankLog.EligibleContext = priorEligible
    C_Timer.After = priorAfter
    GetNumGuildBankTransactions = nil
    GetGuildBankTransaction = nil
    GetGuildBankTabInfo = nil
    QueryGuildBankLog = nil
end

-- 2B18) Extended production UI: bank double-commit, duplicate Add, history pager, recovery, roster
do
    local created = {}
    local function fire(region, event, ...)
        local script = region.scripts and region.scripts[event]
        if script then script(region, ...) end
        for _, hook in ipairs((region.hooks and region.hooks[event]) or {}) do
            hook(region, ...)
        end
    end
    local function makeRegion(kind, name, parent, template)
        local region = {
            kind = kind, name = name, parent = parent, shown = true,
            height = 40, width = 400, points = {}, scripts = {}, hooks = {},
            children = {}, text = "", enabled = true, focused = false,
            registeredEvents = {},
        }
        created[#created + 1] = region
        if parent and parent.children then parent.children[#parent.children + 1] = region end
        function region:GetObjectType() return self.kind or "Frame" end
        function region:SetPoint() end
        function region:ClearAllPoints() end
        function region:SetAllPoints() end
        function region:SetHeight(h) self.height = tonumber(h) or 0 end
        function region:GetHeight() return self.height end
        function region:SetWidth(w) self.width = tonumber(w) or 0 end
        function region:GetWidth() return self.width end
        function region:SetSize(w, h) self:SetWidth(w); self:SetHeight(h) end
        function region:Show() self.shown = true end
        function region:Hide() self.shown = false end
        function region:IsShown() return self.shown and true or false end
        -- Model StandaloneWindow: child may stay IsShown while parent is hidden.
        function region:IsVisible()
            if self.visible ~= nil then return self.visible == true end
            local p = self.parent
            while p do
                if p.visible == false or p.shown == false then return false end
                p = p.parent
            end
            return self.shown and true or false
        end
        function region:SetShown(v) self.shown = v and true or false end
        function region:SetAlpha() end
        function region:SetScript(event, fn) self.scripts[event] = fn end
        function region:HookScript(event, fn)
            self.hooks[event] = self.hooks[event] or {}
            self.hooks[event][#self.hooks[event] + 1] = fn
        end
        function region:EnableMouse() end
        function region:SetHitRectInsets() end
        function region:Enable() self.enabled = true end
        function region:Disable() self.enabled = false end
        function region:SetEnabled(v) self.enabled = v and true or false end
        function region:IsEnabled() return self.enabled end
        function region:SetText(t) self.text = tostring(t or "") end
        function region:GetText() return self.text end
        function region:SetTextColor() end
        function region:SetJustifyH() end
        function region:SetJustifyV() end
        function region:SetWordWrap() end
        function region:SetNonSpaceWrap() end
        function region:SetMaxLines() end
        function region:SetAutoFocus() end
        function region:SetNumeric() end
        function region:SetMaxLetters() end
        function region:SetHighlightColor() end
        function region:SetCursorPosition() end
        function region:HasFocus() return self.focused end
        function region:ClearFocus()
            self.focused = false
            fire(self, "OnEditFocusLost")
        end
        function region:SetFocus() self.focused = true end
        function region:GetStringWidth() return 40 end
        function region:GetStringHeight() return 12 end
        function region:SetColorTexture() end
        function region:SetTexture() end
        function region:SetAtlas() end
        function region:SetTexCoord() end
        function region:SetVertexColor() end
        function region:SetBlendMode() end
        function region:SetVerticalScroll() end
        function region:SetScrollChild(child) self.scrollChild = child end
        function region:CreateTexture() return makeRegion("Texture", nil, self) end
        function region:CreateFontString() return makeRegion("FontString", nil, self) end
        function region:CreateFrame() return makeRegion("Frame", nil, self) end
        function region:RegisterEvent(e) self.registeredEvents[e] = true end
        function region:UnregisterAllEvents() self.registeredEvents = {} end
        function region:SetDefaultText(t) self.defaultText = t end
        function region:SetupMenu(gen)
            self.menuGenerator = gen
            self.menuOptions = {}
            local root = {
                CreateRadio = function(_, label, isSelected, setSelected, value)
                    self.menuOptions[#self.menuOptions + 1] = {
                        label = label, value = value, isSelected = isSelected, setSelected = setSelected,
                    }
                end,
            }
            if type(gen) == "function" then gen(self, root) end
        end
        function region:GenerateMenu()
            if self.menuGenerator then self:SetupMenu(self.menuGenerator) end
        end
        function region:SetChecked(v) self.checked = v and true or false end
        function region:GetChecked() return self.checked and true or false end
        function region:SetNormalFontObject() end
        function region:SetHighlightFontObject() end
        function region:SetDisabledFontObject() end
        function region:SetNormalTexture() end
        function region:SetPushedTexture() end
        function region:SetHighlightTexture() end
        function region:SetCheckedTexture() end
        function region:SetDisabledCheckedTexture() end
        function region:RegisterForClicks() end
        function region:Click() fire(self, "OnClick") end
        function region:SetFontObject() end
        function region:SetFont() end
        function region:GetFont() return "Fonts\\FRIZQT__.TTF", 12 end
        function region:SetParent(p) self.parent = p end
        function region:GetParent() return self.parent end
        function region:SetFrameStrata() end
        function region:SetFrameLevel() end
        function region:SetClipsChildren() end
        function region:EnableDrawLayer() end
        function region:DisableDrawLayer() end
        function region:SetPropagateKeyboardInput() end
        function region:SetObeyStepOnDrag() end
        function region:SetMinMaxValues() end
        function region:SetValueStep() end
        function region:SetValue() end
        function region:GetValue() return self.value or 0 end
        function region:SetOrientation() end
        function region:SetThumbTexture() end
        function region:SetStatusBarTexture() end
        function region:SetStatusBarColor() end
        function region:GetName() return self.name end
        if template == "UIPanelScrollFrameTemplate" then
            region.ScrollBar = makeRegion("Slider", nil, region)
            region.ScrollBar:SetWidth(20)
            region.ScrollBar.shown = false
        end
        return region
    end

    local priorCreateFrame = CreateFrame
    function CreateFrame(frameType, name, parent, template)
        return makeRegion(frameType or "Frame", name, parent, template)
    end
    if type(CopyTable) ~= "function" then
        function CopyTable(t)
            if type(t) ~= "table" then return t end
            local out = {}
            for k, v in pairs(t) do
                out[k] = type(v) == "table" and CopyTable(v) or v
            end
            return out
        end
    end
    GameTooltip = GameTooltip or {
        Hide = function() end, SetOwner = function() end, SetText = function() end,
        AddLine = function() end, Show = function() end,
    }
    OKAY = OKAY or "OK"
    CANCEL = CANCEL or "Cancel"
    StaticPopupDialogs = StaticPopupDialogs or {}
    local pendingConfirm
    function StaticPopup_Show(key, message, _, data)
        pendingConfirm = { key = key, message = message, data = data }
        return { key = key }
    end

    SF.SettingsUI = SF.SettingsUI or {}
    SF.SettingsUI.pagesById = SF.SettingsUI.pagesById or {}
    SF.SettingsUI.pages = SF.SettingsUI.pages or {}
    SF.SettingsUI.categories = SF.SettingsUI.categories or {}
    function SF.SettingsUI:RegisterCategory(cat) self.categories[cat.id] = cat end
    function SF.SettingsUI:RegisterPage(page)
        self.pagesById[page.id] = page
        self.pages[#self.pages + 1] = page
    end
    SF.SettingsStore = SF.SettingsStore or {
        Get = function() return true end,
        Set = function() end,
    }
    -- Reload page modules under this CreateFrame so roster listeners join this harness.
    if not SF.SettingsUI.DefinitionRenderer then
        loadModule("SpectrumFederation/modules/UI/Settings/Style.lua")
        loadModule("SpectrumFederation/modules/UI/Settings/Widgets/Section.lua")
        loadModule("SpectrumFederation/modules/UI/Settings/PageBuilder.lua")
        loadModule("SpectrumFederation/modules/UI/Settings/Control/Controls.lua")
        loadModule("SpectrumFederation/modules/UI/Settings/Dialogs.lua")
        loadModule("SpectrumFederation/modules/UI/Settings/DefinitionRenderer.lua")
    end
    loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesConfiguration.lua")
    loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesLogs.lua")

    local configPage = SF.SettingsUI.pagesById.guildSuppliesConfiguration
    local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
    assertTrue(configPage ~= nil and logsPage ~= nil, "pages available for 2B18")

    local function findEditBoxes(node, out)
        out = out or {}
        if node.kind == "EditBox" then out[#out + 1] = node end
        for _, child in ipairs(node.children or {}) do findEditBoxes(child, out) end
        return out
    end
    local function countOps(record)
        local n = 0
        for _ in pairs(record.operations.records or {}) do n = n + 1 end
        return n
    end

    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    startCampaign()

    local configPanel = makeRegion("Frame", "GSConfigPanel2", nil)
    configPanel:SetSize(600, 800)
    configPage:Build(configPanel)
    local edits = findEditBoxes(configPanel)
    assertTrue(#edits >= 1, "bank edit present in 2B18")
    local bankEdit = edits[1]
    local beforeOps = countOps(GS:GetCurrentRecord())
    bankEdit:SetText("4")
    fire(bankEdit, "OnEnterPressed")
    -- AddEditBox ClearFocus after Enter.
    bankEdit:ClearFocus()
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 4, "bank tab set once")
    assertEq(countOps(GS:GetCurrentRecord()), beforeOps + 1,
        "Enter+focus-loss admits exactly one bank-tab operation")
    -- Unchanged focus loss admits none.
    beforeOps = countOps(GS:GetCurrentRecord())
    fire(bankEdit, "OnEditFocusLost")
    assertEq(countOps(GS:GetCurrentRecord()), beforeOps, "unchanged focus loss allocates no op")

    -- Add + goal edit through production control callbacks (not domain-only).
    local def = configPanel.__sfPageDef
    local addHandler, goalHandler
    for _, sec in ipairs(def.sections or {}) do
        for _, item in ipairs(sec.items or {}) do
            if item.type == "editboxButton" and type(item.onSubmit) == "function" then
                addHandler = item.onSubmit
            end
            if item.type == "consumableRequestedList" and type(item.onGoalCommit) == "function" then
                goalHandler = item.onGoalCommit
            end
        end
    end
    assertTrue(addHandler ~= nil, "Add onSubmit present")
    assertTrue(goalHandler ~= nil, "onGoalCommit present")
    local messages = {}
    local refreshViaPass = 0
    local ctx = {
        section = {
            SetMessage = function(_, msg, sev) messages[#messages + 1] = { msg = msg, sev = sev } end,
            ClearMessage = function() end,
        },
        pageBuilder = {
            Refresh = function()
                -- Legacy path should not be required; Page:Refresh owns pass cache.
                refreshViaPass = refreshViaPass + 1
            end,
        },
    }
    beforeOps = countOps(GS:GetCurrentRecord())
    addHandler(ctx, "777")
    assertEq(countOps(GS:GetCurrentRecord()), beforeOps + 1, "Add admits one operation")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["777"].goal, 0, "Add starts goal 0")
    beforeOps = countOps(GS:GetCurrentRecord())
    goalHandler(ctx, { itemId = 777 }, "12")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["777"].goal, 12,
        "goal commit via onGoalCommit")
    assertEq(countOps(GS:GetCurrentRecord()), beforeOps + 1, "goal commit admits one operation")
    -- Range feedback for MAX_GOAL+1.
    messages = {}
    beforeOps = countOps(GS:GetCurrentRecord())
    goalHandler(ctx, { itemId = 777 }, "100001")
    assertTrue(#messages >= 1, "over-max goal shows feedback")
    assertTrue((messages[#messages].msg or ""):find("0 to 100000", 1, true)
        or (messages[#messages].msg or ""):find("100000", 1, true),
        "over-max goal localized range: " .. tostring(messages[#messages] and messages[#messages].msg))
    assertEq(countOps(GS:GetCurrentRecord()), beforeOps, "over-max goal allocates no op")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["777"].goal, 12,
        "over-max preserves prior goal")
    goalHandler(ctx, { itemId = 777 }, "0")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["777"].goal, 0, "goal 0 accepted")
    goalHandler(ctx, { itemId = 777 }, "100000")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["777"].goal, 100000,
        "MAX_GOAL accepted")
    goalHandler(ctx, { itemId = 777 }, "12")
    local cutoff = GS:GetCurrentRecord().accounting._consumables.eligibility.items["777"]
    beforeOps = countOps(GS:GetCurrentRecord())
    messages = {}
    addHandler(ctx, "777")
    assertTrue(#messages >= 1, "duplicate Add shows feedback")
    assertTrue((messages[1].msg or ""):find("already", 1, true), "duplicate Add localized")
    assertEq(countOps(GS:GetCurrentRecord()), beforeOps, "duplicate Add allocates no operation")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["777"].goal, 12,
        "duplicate Add preserves goal")
    assertEq(GS:GetCurrentRecord().accounting._consumables.eligibility.items["777"], cutoff,
        "duplicate Add preserves eligibility cutoff")

    -- Delayed confirmation finalizes timestamp through UI accept path.
    pendingConfirm = nil
    local newCampaignBtn
    local function findButtons(node, out)
        out = out or {}
        if node.kind == "Button" and node.text then out[#out + 1] = node end
        for _, child in ipairs(node.children or {}) do findButtons(child, out) end
        return out
    end
    for _, btn in ipairs(findButtons(configPanel)) do
        if btn.text == "New Campaign" then newCampaignBtn = btn break end
    end
    assertTrue(newCampaignBtn ~= nil, "New Campaign button in 2B18")
    newCampaignBtn:Click()
    assertTrue(pendingConfirm ~= nil, "confirm shown")
    local acceptFn = pendingConfirm.data
    local prepareTime = world.time
    world.time = world.time + 90
    acceptFn()
    local curId = GS:GetCurrentRecord().currentCampaignId
    local startedAt = GS:GetCurrentRecord().campaigns[curId].startedAt
    assertTrue(startedAt >= prepareTime + 90 or startedAt == math.floor(world.time),
        "UI accept finalizes start timestamp")

    -- Cached open/hide/reopen: Settings parent hide (panel stays IsShown).
    local settingsParent = makeRegion("Frame", "GSSettingsParent", nil)
    configPanel.parent = settingsParent
    settingsParent.shown = true
    local refreshCount = 0
    local realRefresh = SF.SettingsUI.DefinitionRenderer.Refresh
    SF.SettingsUI.DefinitionRenderer.Refresh = function(self, panel)
        refreshCount = refreshCount + 1
        return realRefresh(self, panel)
    end
    local function fireRosterEvents()
        for i = 1, #created do
            local f = created[i]
            if f.registeredEvents and f.registeredEvents.GUILD_ROSTER_UPDATE
                and f.scripts and f.scripts.OnEvent then
                f.scripts.OnEvent(f, "GUILD_ROSTER_UPDATE")
            end
        end
    end
    local priorAfter = C_Timer.After
    local deferredFns = {}
    C_Timer.After = function(_, fn)
        deferredFns[#deferredFns + 1] = fn
    end
    settingsParent.shown = false
    configPanel.shown = true -- child remains locally shown under hidden parent
    refreshCount = 0
    deferredFns = {}
    fireRosterEvents()
    assertEq(#deferredFns, 0, "hidden Settings parent does not queue roster refresh")
    assertEq(refreshCount, 0, "hidden Settings parent skips roster refresh")
    settingsParent.shown = true
    configPage:Refresh(configPanel)
    assertTrue(refreshCount >= 1, "cached reopen uses Refresh when parent visible")
    local rosterListeners = 0
    for i = 1, #created do
        local f = created[i]
        if f.registeredEvents and f.registeredEvents.GUILD_ROSTER_UPDATE then
            rosterListeners = rosterListeners + 1
        end
    end
    assertTrue(rosterListeners >= 1 and rosterListeners <= 4,
        "bounded guild roster listeners: " .. tostring(rosterListeners))
    refreshCount = 0
    deferredFns = {}
    fireRosterEvents()
    fireRosterEvents()
    fireRosterEvents()
    assertEq(#deferredFns, 1, "roster burst queues a single coalesced callback")
    deferredFns[1]()
    assertEq(refreshCount, 1, "deferred roster burst coalesces to one refresh")
    C_Timer.After = priorAfter
    SF.SettingsUI.DefinitionRenderer.Refresh = realRefresh

    -- Membership/readiness restoration through deferred roster event (no manual Refresh).
    local priorMembers = world.guild.members
    local function statusAndItemCount()
        local status, itemCount
        for _, sec in ipairs((configPanel.__sfPageDef and configPanel.__sfPageDef.sections) or {}) do
            for _, item in ipairs(sec.items or {}) do
                if item.type == "help" and type(item.getText) == "function" and sec.id == "gsStatus" then
                    status = item.getText()
                end
                if item.type == "consumableRequestedList" and type(item.getItems) == "function" then
                    itemCount = #item.getItems()
                end
            end
        end
        return status, itemCount
    end
    world.guild.members = {} -- demand roster no longer verifies local membership
    deferredFns = {}
    C_Timer.After = function(_, fn)
        deferredFns[#deferredFns + 1] = fn
    end
    fireRosterEvents()
    assertEq(#deferredFns, 1, "membership loss queues deferred page refresh")
    deferredFns[1]()
    assertEq(GS:GetCapabilities().canRead, false, "unverified membership canRead false")
    local statusText, itemCount = statusAndItemCount()
    assertEq(itemCount, 0, "items redacted without canRead via deferred event")
    assertTrue(type(statusText) == "string" and statusText:find("membership", 1, true),
        "status redacts shared data pending membership: " .. tostring(statusText))
    world.guild.members = priorMembers
    settleRoster()
    deferredFns = {}
    fireRosterEvents()
    assertEq(#deferredFns, 1, "membership restore queues deferred page refresh")
    deferredFns[1]()
    assertEq(GS:GetCapabilities().canRead, true, "membership ready restores canRead via deferred event")
    statusText, itemCount = statusAndItemCount()
    assertTrue(type(statusText) == "string" and not statusText:find("membership is still", 1, true),
        "status leaves membership-pending wording after restore")
    C_Timer.After = priorAfter
    SF.SettingsUI.DefinitionRenderer.Refresh = realRefresh

    -- History pager: drive Older/Newer and assert displayed ranges + pager state.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    GS:CreateStagedRecord()
    local archiveCamp = startCampaign()
    local rec = GS:GetCurrentRecord()
    local gen = rec.accounting._consumables.generation
    for i = 1, 30 do
        rec.accounting._consumableEvents[#rec.accounting._consumableEvents + 1] = {
            id = "hist-" .. i,
            type = "donation",
            itemId = 10,
            quantity = 1,
            actor = "Bob-Garona",
            generation = gen,
            timestamp = world.time + i,
            source = "guildbank",
        }
    end
    startCampaign() -- current empty
    local rows, total = GS:ListCampaignHistory(archiveCamp.id, 25, 0)
    assertEq(total, 30, "archived history total 30")
    assertTrue((rows[1].text or ""):find("donated", 1, true), "history text includes donation")
    assertTrue((rows[1].text or ""):find("%d%d%d%d%-%d%d%-%d%d", 1) ~= nil,
        "history text includes recognizable timestamp: " .. tostring(rows[1].text))

    local logsParent = makeRegion("Frame", "GSLogsParent", nil)
    local logsPanel = makeRegion("Frame", "GSLogsPanel2", logsParent)
    logsPanel:SetSize(600, 800)
    logsPage:Build(logsPanel)
    local drops = {}
    local function findDropdowns(node)
        if node.kind == "DropdownButton" then drops[#drops + 1] = node end
        for _, child in ipairs(node.children or {}) do findDropdowns(child) end
    end
    findDropdowns(logsPanel)
    assertTrue(#drops >= 1, "logs dropdown present")
    local archivedValue
    for i = 1, #(drops[1].menuOptions or {}) do
        local opt = drops[1].menuOptions[i]
        if tostring(opt.label or ""):find("Archived", 1, true) then
            archivedValue = opt.value
            opt.setSelected(opt.value)
            break
        end
    end
    assertTrue(archivedValue ~= nil, "archived campaign option present")
    logsPage:Refresh(logsPanel)
    assertTrue((logsPage.historyTotal or 0) > 25, "historyTotal synced before pager")
    assertEq(logsPage.historyOffset or 0, 0, "pager starts at offset 0")
    local function historyItemsFromDef()
        for _, sec in ipairs((logsPanel.__sfPageDef and logsPanel.__sfPageDef.sections) or {}) do
            for _, item in ipairs(sec.items or {}) do
                if item.type == "scrollList" and type(item.getItems) == "function" then
                    local got = item.getItems()
                    if type(got) == "table" and got[1] and type(got[1].id) == "string"
                        and tostring(got[1].id):find("^hist%-") then
                        return got
                    end
                end
            end
        end
        return nil
    end
    local page0 = historyItemsFromDef()
    assertTrue(type(page0) == "table" and #page0 == 25, "first history page has 25 rows")
    assertEq(page0[1].id, "hist-30", "newest event first on page 0")
    assertEq(page0[25].id, "hist-6", "oldest-on-page event at end of page 0")
    local olderBtn, newerBtn
    local function findNamedButtons(node)
        olderBtn, newerBtn = nil, nil
        local function walk(n)
            if n.kind == "Button" then
                if n.text == "Older" then olderBtn = n end
                if n.text == "Newer" then newerBtn = n end
            end
            for _, child in ipairs(n.children or {}) do walk(child) end
        end
        walk(node)
    end
    findNamedButtons(logsPanel)
    assertTrue(olderBtn ~= nil, "Older button present")
    assertTrue(newerBtn ~= nil, "Newer button present")
    assertTrue(olderBtn.enabled ~= false, "Older enabled for >25 archive rows")
    local totalBefore = logsPage.historyTotal
    local recordCalls = 0
    local realGetCurrentRecord = GS.GetCurrentRecord
    GS.GetCurrentRecord = function(self, ...)
        recordCalls = recordCalls + 1
        return realGetCurrentRecord(self, ...)
    end
    olderBtn:Click()
    assertEq(logsPage.historyTotal, totalBefore, "pager keeps total after Older")
    assertEq(logsPage.historyOffset, 25, "Older advances historyOffset to 25")
    local page1 = historyItemsFromDef()
    assertTrue(type(page1) == "table" and #page1 == 5, "second history page has remaining 5 rows")
    assertEq(page1[1].id, "hist-5", "Older page starts at hist-5")
    assertEq(page1[5].id, "hist-1", "Older page ends at hist-1")
    -- Bound is control/render-pass scale, not one call per retained history event.
    assertTrue(recordCalls > 0 and recordCalls <= 40 and recordCalls < total,
        "populated-history validation work stays bounded on Older render: " .. tostring(recordCalls))
    findNamedButtons(logsPanel)
    assertTrue(newerBtn ~= nil and newerBtn.enabled ~= false, "Newer enabled after Older")
    newerBtn:Click()
    assertEq(logsPage.historyOffset, 0, "Newer returns historyOffset to 0")
    local pageBack = historyItemsFromDef()
    assertEq(pageBack[1].id, "hist-30", "Newer restores newest page")
    assertEq(pageBack[25].id, "hist-6", "Newer restores first-page tail")
    GS.GetCurrentRecord = realGetCurrentRecord

    -- Ordinary-guild GM recovery through dropdown + confirmation (not domain-only).
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    GS:CreateStagedRecord()
    local record = GS:GetCurrentRecord()
    record.permission.revisionId = "gs1:broken-policy-rev:1"
    assertEq(GS:GetCapabilities().canRecoverPolicy, true, "GM canRecoverPolicy under permission-only failure")
    assertNil(select(1, GS:GetCurrentRecord()), "GetCurrentRecord nil for permission-only failure")
    local recoverPanel = makeRegion("Frame", "GSRecoverPanel", nil)
    recoverPanel:SetSize(600, 800)
    pendingConfirm = nil
    configPage:Build(recoverPanel)
    local recoverDrops = {}
    local function findDrops(node)
        if node.kind == "DropdownButton" then recoverDrops[#recoverDrops + 1] = node end
        for _, child in ipairs(node.children or {}) do findDrops(child) end
    end
    findDrops(recoverPanel)
    assertTrue(#recoverDrops >= 1, "recovery rank dropdown present")
    recoverDrops[1]:GenerateMenu()
    local picked
    for i = 1, #(recoverDrops[1].menuOptions or {}) do
        local opt = recoverDrops[1].menuOptions[i]
        if opt.value == 2 then
            picked = opt
            opt.setSelected(opt.value)
            break
        end
    end
    assertTrue(picked ~= nil, "recovery selected rank 2")
    assertTrue(pendingConfirm ~= nil, "recovery confirmation shown")
    pendingConfirm.data()
    assertEq(GS:GetCurrentRecord().permission.editorRankPosition, 2,
        "UI recovery admits editor rank")

    -- Small-guild permission-only recovery must not take the Initialize branch.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    world.guild.ranks = { "Guild Master", "Member" }
    settleRoster()
    local smallRec, smallSt = GS:CreateStagedRecord(2)
    assertEq(smallSt, "accepted", "small guild configured with explicit threshold")
    assertTrue(smallRec ~= nil, "small guild record created")
    smallRec.permission.revisionId = "gs1:broken-small:1"
    assertNil(select(1, GS:GetCurrentRecord()), "small guild GetCurrentRecord nil")
    assertEq(GS:GetCapabilities().canRecoverPolicy, true, "small guild GM canRecoverPolicy")
    pendingConfirm = nil
    local smallPanel = makeRegion("Frame", "GSSmallRecover", nil)
    smallPanel:SetSize(600, 800)
    configPage:Build(smallPanel)
    local initEnabled = false
    for _, sec in ipairs((smallPanel.__sfPageDef and smallPanel.__sfPageDef.sections) or {}) do
        for _, item in ipairs(sec.items or {}) do
            if item.type == "button" and item.buttonText and item.buttonText:find("Initialize", 1, true) then
                initEnabled = item.enabled and item.enabled() or false
            end
        end
    end
    assertEq(initEnabled, false, "Initialize disabled for existing unusable record")
    local smallDrops = {}
    local function findSmallDrops(node)
        if node.kind == "DropdownButton" then smallDrops[#smallDrops + 1] = node end
        for _, child in ipairs(node.children or {}) do findSmallDrops(child) end
    end
    findSmallDrops(smallPanel)
    assertTrue(#smallDrops >= 1, "small-guild recovery dropdown present")
    smallDrops[1]:GenerateMenu()
    for i = 1, #(smallDrops[1].menuOptions or {}) do
        local opt = smallDrops[1].menuOptions[i]
        if opt.value == 1 then
            opt.setSelected(opt.value)
            break
        end
    end
    assertTrue(pendingConfirm ~= nil, "small-guild recovery opens confirmation not init")
    pendingConfirm.data()
    assertEq(GS:GetCurrentRecord().permission.editorRankPosition, 1,
        "small-guild UI recovery admits rank")

    -- Ordinary (>=3 ranks) not_configured: rank edits disabled until Initialize.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    settleRoster()
    pendingConfirm = nil
    local ordinaryInitPanel = makeRegion("Frame", "GSOrdinaryInit", nil)
    ordinaryInitPanel:SetSize(600, 800)
    configPage:Build(ordinaryInitPanel)
    local function rankDropdownEnabled(panel)
        for _, sec in ipairs((panel.__sfPageDef and panel.__sfPageDef.sections) or {}) do
            for _, item in ipairs(sec.items or {}) do
                if item.type == "dropdown" and item.label
                    and tostring(item.label):find("Editor", 1, true)
                    and type(item.enabled) == "function" then
                    return item.enabled() and true or false
                end
            end
        end
        return nil
    end
    assertEq(rankDropdownEnabled(ordinaryInitPanel), false,
        "ordinary not_configured disables editor-rank edits")
    assertEq(select(2, GS:GetCurrentRecord()), "not_configured", "ordinary guild not_configured")
    local ordinaryInitBtn
    local function findOrdinaryInit(node)
        if node.kind == "Button" and node.text and node.text:find("Initialize", 1, true) then
            ordinaryInitBtn = node
        end
        for _, child in ipairs(node.children or {}) do findOrdinaryInit(child) end
    end
    findOrdinaryInit(ordinaryInitPanel)
    configPage:Refresh(ordinaryInitPanel)
    findOrdinaryInit(ordinaryInitPanel)
    assertTrue(ordinaryInitBtn ~= nil and ordinaryInitBtn.enabled ~= false,
        "ordinary Initialize enabled without explicit threshold")
    ordinaryInitBtn:Click()
    local ordinaryRec = GS:GetCurrentRecord()
    assertTrue(ordinaryRec ~= nil, "ordinary Initialize creates dataset")
    assertEq(ordinaryRec.permission.editorRankPosition, GS.DEFAULT_EDITOR_RANK_POSITION or 3,
        "ordinary Initialize admits default editor rank policy")
    configPage:Refresh(ordinaryInitPanel)
    assertEq(rankDropdownEnabled(ordinaryInitPanel), true,
        "editor-rank edits enabled after ordinary Initialize")

    -- Pending init rank bound to guild context; click Initialize and assert dataset/policy.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    world.guild.ranks = { "Guild Master", "Member" }
    settleRoster()
    pendingConfirm = nil
    local initPanel = makeRegion("Frame", "GSInitPanel", nil)
    initPanel:SetSize(600, 800)
    configPage:Build(initPanel)
    local initDrops = {}
    local function findInitDrops(node)
        if node.kind == "DropdownButton" then initDrops[#initDrops + 1] = node end
        for _, child in ipairs(node.children or {}) do findInitDrops(child) end
    end
    findInitDrops(initPanel)
    initDrops[1]:GenerateMenu()
    for i = 1, #(initDrops[1].menuOptions or {}) do
        local opt = initDrops[1].menuOptions[i]
        if opt.value == 2 then
            opt.setSelected(opt.value)
            break
        end
    end
    local initBtn
    local function findInitBtn(node)
        if node.kind == "Button" and node.text and node.text:find("Initialize", 1, true) then
            initBtn = node
        end
        for _, child in ipairs(node.children or {}) do findInitBtn(child) end
    end
    findInitBtn(initPanel)
    configPage:Refresh(initPanel)
    findInitBtn(initPanel)
    assertTrue(initBtn ~= nil and initBtn.enabled ~= false, "Initialize enabled after pending rank")
    assertNil(select(1, GS:GetCurrentRecord()), "no dataset before Initialize click")
    initBtn:Click()
    local createdRec, createdReason = GS:GetCurrentRecord()
    assertTrue(createdRec ~= nil, "Initialize click creates dataset: " .. tostring(createdReason))
    assertEq(createdRec.permission.editorRankPosition, 2,
        "Initialize click admits selected editor rank policy")
    assertEq(createdRec.activation, GS.ACTIVATION_STAGED, "Initialize creates staged activation")
    assertTrue(type(createdRec.datasetId) == "string" and createdRec.datasetId ~= "",
        "Initialize creates datasetId")

    -- Fresh not-configured guild: unchanged roster keeps pending rank; guild change clears it.
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    world.guild.clubId = 42
    world.guild.ranks = { "Guild Master", "Member" }
    settleRoster()
    pendingConfirm = nil
    initPanel = makeRegion("Frame", "GSInitPanel2", nil)
    initPanel:SetSize(600, 800)
    configPage:Build(initPanel)
    initDrops = {}
    findInitDrops(initPanel)
    assertTrue(#initDrops >= 1, "init rank dropdown present for reselect")
    initDrops[1]:GenerateMenu()
    local selectedPending = false
    for i = 1, #(initDrops[1].menuOptions or {}) do
        local opt = initDrops[1].menuOptions[i]
        if opt.value == 2 then
            opt.setSelected(opt.value)
            selectedPending = true
            break
        end
    end
    assertEq(selectedPending, true, "pending init rank 2 selected")
    initBtn = nil
    configPage:Refresh(initPanel)
    findInitBtn(initPanel)
    assertTrue(initBtn ~= nil and initBtn.enabled ~= false, "Initialize enabled after reselect")
    C_Timer.After = function(_, fn) fn() end
    for i = 1, #created do
        local f = created[i]
        if f.registeredEvents and f.registeredEvents.GUILD_ROSTER_UPDATE
            and f.scripts and f.scripts.OnEvent then
            f.scripts.OnEvent(f, "GUILD_ROSTER_UPDATE")
        end
    end
    initBtn = nil
    configPage:Refresh(initPanel)
    findInitBtn(initPanel)
    assertTrue(initBtn ~= nil and initBtn.enabled ~= false, "unchanged roster keeps pending init rank")
    -- Restore deferred timers before further settleRoster calls; an immediate
    -- C_Timer.After would fire the demand-roster wait timeout before the update.
    C_Timer.After = priorAfter
    -- Guild change clears pending selection.
    world.guild.clubId = 99
    settleRoster()
    initBtn = nil
    configPage:Refresh(initPanel)
    findInitBtn(initPanel)
    local stillEnabled = initBtn and initBtn.enabled
    -- After guild change, needs reselection (Initialize disabled until new pending).
    assertTrue(stillEnabled == false or stillEnabled == nil,
        "guild change requires init rank reselection")

    -- Requested-item bounds: over-cap/invalid fixtures stay unavailable; valid max renders.
    world.guild.clubId = 42
    world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    resetDb()
    initGS()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    settleRoster()
    local createdBound, createdBoundStatus, createdBoundReason = GS:CreateStagedRecord()
    assertEq(createdBoundStatus, "accepted",
        "bounds fixture CreateStagedRecord: " .. tostring(createdBoundReason))
    assertTrue(createdBound ~= nil, "bounds fixture record created")
    startCampaign()
    local boundRec = GS:GetCurrentRecord()
    assertTrue(boundRec ~= nil, "bounds fixture current record available")
    local boundItems = boundRec.accounting._consumables.requestedItems
    local maxItems = (SF.Consumables and SF.Consumables.MAX_REQUESTED_ITEMS) or 256
    for i = 1, maxItems do
        boundItems[tostring(1000 + i)] = { itemId = 1000 + i, goal = i }
    end
    local okMax, errMax = GS.ValidateRequestedItemsMap(boundItems)
    assertEq(okMax, true, "valid maximum-sized map accepted")
    local copiedMax = GS:GetCampaignRequestedItems(boundRec.currentCampaignId)
    local copiedCount = 0
    for _ in pairs(copiedMax or {}) do copiedCount = copiedCount + 1 end
    assertEq(copiedCount, maxItems, "GetCampaignRequestedItems returns full max-sized map")
    local boundsPanel = makeRegion("Frame", "GSBoundsPanel", nil)
    boundsPanel:SetSize(600, 800)
    configPage:Build(boundsPanel)
    local maxRowCount
    for _, sec in ipairs((boundsPanel.__sfPageDef and boundsPanel.__sfPageDef.sections) or {}) do
        for _, item in ipairs(sec.items or {}) do
            if item.type == "consumableRequestedList" and type(item.getItems) == "function" then
                maxRowCount = #item.getItems()
            end
        end
    end
    assertEq(maxRowCount, maxItems, "UI constructs bounded rows for valid max-sized map")
    -- Over-cap: preserve SV unchanged and make record unavailable.
    boundItems[tostring(1000 + maxItems + 1)] = { itemId = 1000 + maxItems + 1, goal = 1 }
    local overflowSnapshot = {}
    for k, v in pairs(boundItems) do
        overflowSnapshot[k] = v
    end
    local overflowCount = 0
    for _ in pairs(boundItems) do overflowCount = overflowCount + 1 end
    assertTrue(overflowCount > maxItems, "fixture exceeds requested-item cap")
    assertEq(select(1, GS:GetCurrentRecord()), nil, "over-cap current map makes record unavailable")
    assertEq(select(2, GS:GetCurrentRecord()), "requested_items_overflow",
        "over-cap reason is requested_items_overflow")
    local afterCount = 0
    local preserved = true
    for k, v in pairs(overflowSnapshot) do
        afterCount = afterCount + 1
        if boundItems[k] ~= v then
            preserved = false
        end
    end
    assertEq(afterCount, overflowCount, "over-cap SV entry count preserved")
    assertEq(preserved, true, "over-cap SV entries preserved unchanged")
    configPage:Refresh(boundsPanel)
    local overflowRows = 0
    local overflowStatus
    for _, sec in ipairs((boundsPanel.__sfPageDef and boundsPanel.__sfPageDef.sections) or {}) do
        for _, item in ipairs(sec.items or {}) do
            if item.type == "consumableRequestedList" and type(item.getItems) == "function" then
                overflowRows = #item.getItems()
            end
            if item.type == "help" and type(item.getText) == "function" and sec.id == "gsStatus" then
                overflowStatus = item.getText()
            end
        end
    end
    assertEq(overflowRows, 0, "over-cap UI constructs no requested-item rows")
    assertTrue(type(overflowStatus) == "string" and overflowStatus ~= "",
        "over-cap presents unavailable status text")
    -- Invalid-heavy map: non-table rows fail closed (malformed, not truncated).
    boundItems[tostring(1000 + maxItems + 1)] = nil
    for i = 1, maxItems do
        boundItems[tostring(1000 + i)] = nil
    end
    for i = 1, maxItems + 5 do
        boundItems["bad-" .. i] = "not-a-row"
    end
    local badOk, badErr = GS.ValidateRequestedItemsMap(boundItems)
    assertEq(badOk, false, "invalid raw entries fail closed")
    assertEq(badErr, "requested_items_malformed", "non-table rows are malformed")
    assertEq(select(2, GS:GetCurrentRecord()), "requested_items_malformed",
        "invalid raw entries make record unavailable")
    for i = 1, maxItems + 5 do
        boundItems["bad-" .. i] = nil
    end

    -- In-cap malformed rows: reject/unavailable; preserve original retained state.
    local function assertMalformedReject(label, mutator)
        boundItems["42"] = { itemId = 42, goal = 3 }
        local baseline = GS:GetCurrentRecord()
        assertTrue(baseline ~= nil, label .. " baseline usable")
        local snapCampaign = baseline.currentCampaignId
        local snapOps = 0
        for _ in pairs(baseline.operations.records or {}) do snapOps = snapOps + 1 end
        local archiveCount = 0
        for _ in pairs(baseline.campaignArchives or {}) do
            archiveCount = archiveCount + 1
        end
        local snapRow = boundItems["42"]
        mutator(boundItems)
        local vok, verr = GS.ValidateRequestedItemsMap(boundItems)
        assertEq(vok, false, label .. " validation rejects")
        assertEq(verr, "requested_items_malformed", label .. " reason malformed")
        assertEq(select(1, GS:GetCurrentRecord()), nil, label .. " record unavailable")
        local opBad, prepSt = GS:NewCampaignOperation()
        assertEq(opBad, nil, label .. " New Campaign prepare blocked")
        assertEq(prepSt, "rejected", label .. " New Campaign prepare rejected")
        -- Restore original row; SV must still hold the mutated raw entry until we clear it.
        boundItems["42"] = snapRow
        local restored = GS:GetCurrentRecord()
        assertTrue(restored ~= nil, label .. " restored after clearing malformation")
        assertEq(restored.currentCampaignId, snapCampaign, label .. " current campaign unchanged")
        local opsAfter = 0
        for _ in pairs(restored.operations.records or {}) do opsAfter = opsAfter + 1 end
        assertEq(opsAfter, snapOps, label .. " operations unchanged")
        local archivesAfter = 0
        for _ in pairs(restored.campaignArchives or {}) do archivesAfter = archivesAfter + 1 end
        assertEq(archivesAfter, archiveCount, label .. " archives unchanged")
        assertEq(restored.accounting._consumables.requestedItems["42"].goal, 3,
            label .. " retained goal preserved")
    end
    assertMalformedReject("non-table", function(items)
        items["42"] = "not-a-row"
    end)
    assertMalformedReject("missing itemId", function(items)
        items["42"] = { goal = 3 }
    end)
    assertMalformedReject("invalid itemId", function(items)
        items["42"] = { itemId = 0, goal = 3 }
    end)
    assertMalformedReject("key/item mismatch", function(items)
        items["42"] = { itemId = 99, goal = 3 }
    end)
    assertMalformedReject("missing goal", function(items)
        items["42"] = { itemId = 42 }
    end)
    assertMalformedReject("negative goal", function(items)
        items["42"] = { itemId = 42, goal = -1 }
    end)
    assertMalformedReject("fractional goal", function(items)
        items["42"] = { itemId = 42, goal = 1.5 }
    end)
    local maxGoal = (SF.Consumables and SF.Consumables.MAX_GOAL) or 100000
    assertMalformedReject("over-max goal", function(items)
        items["42"] = { itemId = 42, goal = maxGoal + 1 }
    end)

    -- Canonical string keys only: numeric / mixed aliases fail closed (no collapse).
    boundItems["42"] = nil
    boundItems[42] = { itemId = 42, goal = 5 }
    assertEq(GS.ValidateRequestedItemsMap(boundItems), false,
        "numeric-only requested-item key rejected")
    assertEq(select(2, GS:GetCurrentRecord()), "requested_items_malformed",
        "numeric-only key makes record unavailable")
    boundItems[42] = nil
    boundItems["42"] = { itemId = 42, goal = 5 }
    boundItems[42] = { itemId = 42, goal = 9 }
    assertEq(GS.ValidateRequestedItemsMap(boundItems), false,
        "mixed numeric/string requested-item keys rejected")
    assertEq(select(2, GS:GetCurrentRecord()), "requested_items_malformed",
        "mixed-key map makes record unavailable")
    -- Prepare New Campaign on a clean canonical map, then corrupt keys before commit.
    boundItems[42] = nil
    boundItems["42"] = { itemId = 42, goal = 5 }
    local keyRec = GS:GetCurrentRecord()
    assertTrue(keyRec ~= nil, "canonical string key usable before corruption")
    local keyCamp = keyRec.currentCampaignId
    local keyOps = 0
    for _ in pairs(keyRec.operations.records or {}) do keyOps = keyOps + 1 end
    local keyArch = 0
    for _ in pairs(keyRec.campaignArchives or {}) do keyArch = keyArch + 1 end
    local keyOp = GS:NewCampaignOperation()
    assertTrue(keyOp ~= nil, "prepare New Campaign before key corruption")
    boundItems[42] = { itemId = 42, goal = 11 }
    local keySt, keyReason = GS:ApplyStagedCampaignOperation(keyOp)
    assertEq(keySt, "rejected", "commit rejects after mixed-key corruption")
    assertEq(keyReason, "requested_items_malformed",
        "commit revalidation surfaces requested_items_malformed")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].accounting._consumables.requestedItems[42].goal,
        11, "numeric alias row preserved on reject")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].accounting._consumables.requestedItems["42"].goal,
        5, "string key row preserved on reject")
    assertEq(SpectrumFederationDB.guildSupplies.guilds["club:42"].currentCampaignId, keyCamp,
        "campaign unchanged after key-collision reject")
    local keyOpsAfter = 0
    for _ in pairs(SpectrumFederationDB.guildSupplies.guilds["club:42"].operations.records or {}) do
        keyOpsAfter = keyOpsAfter + 1
    end
    assertEq(keyOpsAfter, keyOps, "operations unchanged after key-collision reject")
    local keyArchAfter = 0
    for _ in pairs(SpectrumFederationDB.guildSupplies.guilds["club:42"].campaignArchives or {}) do
        keyArchAfter = keyArchAfter + 1
    end
    assertEq(keyArchAfter, keyArch, "archives unchanged after key-collision reject")
    boundItems[42] = nil
    boundItems["42"] = { itemId = 42, goal = 3 }

    -- Malformed archive must not disable a usable current campaign.
    boundItems["42"] = { itemId = 42, goal = 3 }
    local usable = GS:GetCurrentRecord()
    assertTrue(usable ~= nil, "usable current restored after clearing overflow")
    local priorCampaignId = usable.currentCampaignId
    startCampaign() -- archives prior campaign with item 42
    usable = GS:GetCurrentRecord()
    assertTrue(usable.campaignArchives and usable.campaignArchives[priorCampaignId],
        "prior campaign archived on New Campaign")
    local archiveItems = usable.campaignArchives[priorCampaignId].requestedItems
    archiveItems["42"] = { itemId = 42, goal = -5 }
    local archivedItems, archiveErr = GS:GetCampaignRequestedItems(priorCampaignId)
    assertEq(archivedItems, nil, "malformed archive items unavailable")
    assertEq(archiveErr, "requested_items_malformed", "malformed archive reason")
    -- Also cover over-cap archive isolation.
    archiveItems["42"] = { itemId = 42, goal = 3 }
    for i = 1, maxItems + 2 do
        archiveItems[tostring(2000 + i)] = { itemId = 2000 + i, goal = 1 }
    end
    archivedItems, archiveErr = GS:GetCampaignRequestedItems(priorCampaignId)
    assertEq(archivedItems, nil, "over-cap archive items unavailable")
    assertEq(archiveErr, "requested_items_overflow", "over-cap archive reason")
    -- Current campaign remains readable after the bad archive mutation.
    usable.accounting._consumables.requestedItems["99"] = { itemId = 99, goal = 5 }
    local currentItems = GS:GetCampaignRequestedItems(usable.currentCampaignId)
    assertTrue(type(currentItems) == "table" and currentItems["99"] ~= nil,
        "usable current items survive bad archive")
    assertTrue(GS:GetCurrentRecord() ~= nil, "guild record still usable with bad archive")

    CreateFrame = priorCreateFrame
    C_Timer.After = priorAfter
    world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    world.guild.clubId = 42
end

---------------------------------------------------------------------------
-- 3A) Staged configuration gossip / remote admission / adoption (#387)
---------------------------------------------------------------------------

local function switchPlayer(name, guid, rankOrder)
    world.unitName = name
    world.unitGuid = guid
    -- Rank order is sourced from the roster entry for this GUID.
    for _, m in ipairs(world.guild.members) do
        if m.guid == guid then
            m.rankOrder = rankOrder or m.rankOrder
        end
    end
end

local function providerApply(body, sender)
    local entry = GG.GetProvider(GS.PROVIDER_ID)
    assertTrue(entry and entry.api and entry.api.ValidateAndApply, "provider registered")
    local rid = "test:" .. tostring(body.kind) .. ":" .. tostring((body.op and body.op.id) or body.datasetId or math.random(1, 1e9))
    local record = {
        id = rid,
        versionFp = GS.ContentFingerprint(body),
        body = body,
    }
    return entry.api.ValidateAndApply(record, { sender = sender })
end

local function snapshotOp(op)
    return select(1, GS._SnapshotPublicOp(op))
end

-- 3A1) Ordinary member receives authenticated editor config without gaining edit rights
do
    resetDb()
    world.notifyChanged = 0
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    local camp = startCampaign()
    local campStored = snapshotOp(camp)
    local header = GS:GetCurrentCampaignBoundary()
    local tabOp = select(1, GS:NewConfigOperation("set-bank-tab", "bankTab", 2))
    assertEq(GS:ApplyStagedConfigOperation(tabOp), "accepted", "3A1: tab accepted locally")
    assertTrue((world.notifyChanged or 0) >= 1, "3A1: NotifyProviderChanged on local write")
    local tabStored = snapshotOp(tabOp)
    local datasetId = GS:GetCurrentRecord().datasetId

    -- Dave empty client
    SpectrumFederationDB = {}
    switchPlayer("Dave", "Player-1-Dave", 4)
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:EnsureGossipProvider()
    assertEq(select(2, GS:GetCurrentRecord()), "not_configured", "3A1: member empty")
    assertEq(GS:GetCapabilities().canEdit, false, "3A1: member cannot edit")
    assertEq(providerApply({
        kind = "dataset-desc",
        schemaVersion = 1,
        guildKey = "club:42",
        datasetId = datasetId,
        editorRankPosition = 3,
        permissionRevisionId = datasetId,
        activation = "staged",
    }, "Alice-Garona"), "accepted", "3A1: desc install")
    assertEq(GS:GetCurrentRecord().datasetId, datasetId, "3A1: same dataset")
    assertEq(GS:GetCapabilities().canEdit, false, "3A1: install does not grant edit")

    local stCamp, reasonCamp = providerApply({
        kind = "gs-op",
        op = campStored,
        boundary = header,
    }, "Alice-Garona")
    assertEq(stCamp, "accepted", "3A1: remote campaign: " .. tostring(reasonCamp))
    local stTab, reasonTab = providerApply({
        kind = "gs-op",
        op = tabStored,
    }, "Alice-Garona")
    assertEq(stTab, "accepted", "3A1: remote tab: " .. tostring(reasonTab))
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 2, "3A1: tab replicated")
    assertEq(GS:GetCapabilities().canEdit, false, "3A1: still not editor")
    -- Spoofed actor rejected
    local spoof = {}
    for k, v in pairs(tabStored) do spoof[k] = v end
    spoof.id = "spoof-op-1"
    spoof.actorGuid = "Player-1-Eve"
    spoof.actorName = "Eve-Garona"
    spoof.baseTargetRevision = tabStored.id
    spoof.value = 5
    local stSpoof, reasonSpoof = GS:AdmitRemoteOperation(spoof, { sender = "Alice-Garona" })
    assertEq(stSpoof, "pending", "3A1: spoofed actor retained for confirmation")
    assertEq(reasonSpoof, "untrusted_relay", "3A1: untrusted_relay not silent apply")
    assertNil(GS:GetCurrentRecord().operations.records["spoof-op-1"],
        "3A1: spoofed body not accepted")
end

-- 3A2) Dataset mismatch blocked; adoption replaces; cancel / incomplete leave prior intact
do
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    local aliceDataset = GS:GetCurrentRecord().datasetId
    GS:EnsureGossipProvider()

    -- Bob independently creates another dataset (simulated by swapping roots).
    local aliceRoot = SpectrumFederationDB.guildSupplies
    SpectrumFederationDB = {}
    switchPlayer("Bob", "Player-1-Bob", 2)
    initGS()
    GS:CreateStagedRecord()
    local bobDataset = GS:GetCurrentRecord().datasetId
    assertTrue(bobDataset ~= aliceDataset, "3A2: independent dataset ids")
    local bobDesc = {
        kind = "dataset-desc",
        schemaVersion = 1,
        guildKey = "club:42",
        datasetId = bobDataset,
        editorRankPosition = 3,
        permissionRevisionId = bobDataset,
        bootstrapEditorRankPosition = 3,
        activation = "staged",
        acceptedOpCount = 0,
        campaignCount = 0,
        archiveCount = 0,
    }

    -- Alice sees Bob's foreign dataset → pending mismatch, local unchanged.
    SpectrumFederationDB.guildSupplies = aliceRoot
    switchPlayer("Alice", "Player-1-Alice", 1)
    GS._db = SpectrumFederationDB
    GS._root = aliceRoot
    GS._rootValid = true
    GS._rootReason = nil
    GS._peerDatasets = {}
    settleRoster()
    GS:EnsureGossipProvider()
    local stMis, reasonMis = providerApply(bobDesc, "Bob-Garona")
    assertEq(stMis, "pending", "3A2: foreign dataset pending")
    assertEq(reasonMis, "dataset_mismatch", "3A2: dataset_mismatch")
    assertEq(GS:GetCurrentRecord().datasetId, aliceDataset, "3A2: local dataset retained")

    -- Begin adoption then cancel.
    local _, stBegin = GS:BeginDatasetAdoption("Bob-Garona", bobDataset)
    assertEq(stBegin, "accepted", "3A2: begin adoption")
    GS:CancelDatasetAdoption()
    assertEq(GS:GetPendingAdoption(), nil, "3A2: cancelled")
    assertEq(GS:GetCurrentRecord().datasetId, aliceDataset, "3A2: cancel leaves local")

    -- Incomplete commit leaves local intact.
    local _, stBegin2 = GS:BeginDatasetAdoption("Bob-Garona", bobDataset)
    assertEq(stBegin2, "accepted", "3A2: begin again")
    local stCommit, reasonCommit = GS:CommitDatasetAdoption()
    assertEq(stCommit, "rejected", "3A2: incomplete rejected")
    assertEq(reasonCommit, "incomplete_transfer", "3A2: incomplete_transfer")
    assertEq(GS:GetCurrentRecord().datasetId, aliceDataset, "3A2: incomplete leaves local")
    GS:CancelDatasetAdoption()

    -- Successful adoption: buffer desc + commit.
    local epochBefore = GS._adoptionEpoch or 0
    GS:BeginDatasetAdoption("Bob-Garona", bobDataset)
    assertEq(GS:BufferAdoptionRecord("gs:desc:" .. bobDataset, bobDesc), "accepted", "3A2: buffer desc")
    -- Empty ops-only dataset is valid to install via replay of just the descriptor.
    local stOk, reasonOk = GS:CommitDatasetAdoption()
    assertEq(stOk, "accepted", "3A2: adoption commit: " .. tostring(reasonOk))
    assertEq(GS:GetCurrentRecord().datasetId, bobDataset, "3A2: replaced with Bob dataset")
    assertTrue((GS._adoptionEpoch or 0) > epochBefore, "3A2: epoch bumped")

    -- Old-dataset traffic rejected after replacement.
    local oldOp = {
        schemaVersion = 1,
        id = "old-ds-op",
        guildKey = "club:42",
        datasetId = aliceDataset,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 7,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 9000,
        baseTargetRevision = aliceDataset,
        basePolicyRevision = aliceDataset,
    }
    local stOld, reasonOld = providerApply({ kind = "gs-op", op = oldOp }, "Alice-Garona")
    assertEq(stOld, "rejected", "3A2: old dataset rejected")
    assertEq(reasonOld, "dataset_mismatch", "3A2: old dataset_mismatch")
end

-- 3A3) Independent edits merge; same-field conflict + explicit resolution; opposite order
do
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    startCampaign()
    local datasetId = GS:GetCurrentRecord().datasetId
    local policy = datasetId

    -- Alice sets bank tab 1.
    local opTab = select(1, GS:NewConfigOperation("set-bank-tab", "bankTab", 1))
    assertEq(GS:ApplyStagedConfigOperation(opTab), "accepted", "3A3: tab1")
    local tabStored = snapshotOp(opTab)

    -- Independent item edit based on same campaign (compatible ancestry).
    local opItem = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 100 }, {
        itemId = 100, goal = 5, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(opItem), "accepted", "3A3: item merge locally")

    -- Simulate Bob's divergent bank-tab based on same base as Alice's tab (sibling).
    local bobTab = {
        schemaVersion = 1,
        id = "bob-tab-conflict",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = GS:GetCurrentRecord().currentCampaignId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 4,
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 9100,
        baseTargetRevision = datasetId, -- same base Alice used
        basePolicyRevision = policy,
        baseCampaignId = GS:GetCurrentRecord().currentCampaignId,
    }
    local stConf, reasonConf = GS:AdmitRemoteOperation(bobTab, { sender = "Bob-Garona" })
    assertTrue(stConf == "pending" or stConf == "rejected", "3A3: divergent retained")
    assertTrue(reasonConf == "divergent_edit" or reasonConf == "open_conflict" or reasonConf == "stale_base"
        or reasonConf == "id_conflict", "3A3: conflictish reason: " .. tostring(reasonConf))
    local conflicts = GS:ListOpenConflicts()
    assertTrue(#conflicts >= 1, "3A3: open conflict listed")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 1,
        "3A3: provisional remains Alice value until resolution")

    local entry = conflicts[1]
    local chosen = entry.candidates[1].id
    local ids = {}
    for i = 1, #entry.candidates do ids[i] = entry.candidates[i].id end
    local resOp = select(1, GS:NewConflictResolutionOperation(entry.targetKey, chosen, ids))
    assertTrue(resOp ~= nil, "3A3: resolution prepared")
    local stRes, reasonRes = GS:ApplyStagedConflictResolution(resOp)
    assertEq(stRes, "accepted", "3A3: resolution accepted: " .. tostring(reasonRes))
    assertEq(#GS:ListOpenConflicts(), 0, "3A3: conflicts cleared")

    -- Opposite delivery: resolution body applied on a fresh peer that saw Bob first.
    -- Rebuild a sibling conflict then apply the same resolution op remotely.
    -- (Smoke: resolution duplicate is safe.)
    assertEq(GS:AdmitRemoteOperation(snapshotOp(resOp), { sender = "Alice-Garona" }),
        "duplicate", "3A3: resolution duplicate")
end

-- 3A4) Untrusted relay pending; confirmation; rank revocation; eligibility timestamps
do
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    startCampaign()
    local datasetId = GS:GetCurrentRecord().datasetId
    local campId = GS:GetCurrentRecord().currentCampaignId
    local originalTs = 7777
    local itemOp = {
        schemaVersion = 1,
        id = "hist-item-1",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-requested-item",
        target = { itemId = 55 },
        value = { itemId = 55, goal = 3, removed = false },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = originalTs,
        baseTargetRevision = datasetId,
        basePolicyRevision = datasetId,
        baseCampaignId = campId,
    }
    -- Dave (non-editor) relays historical candidate → pending untrusted.
    local stRelay, reasonRelay = providerApply({ kind = "gs-op", op = itemOp }, "Dave-Garona")
    assertEq(stRelay, "pending", "3A4: untrusted relay pending")
    assertEq(reasonRelay, "untrusted_relay", "3A4: untrusted_relay")
    assertEq(GS:GetCurrentRecord().accounting._consumables.requestedItems["55"], nil,
        "3A4: not applied from relay")

    -- Alice confirms exact candidate — confirmation itself applies the body
    -- with original attribution (no manual resend / restamp).
    local fp = GS.ContentFingerprint(itemOp)
    local confOp = select(1, GS:NewConfirmationOperation({
        recordId = itemOp.id,
        contentFingerprint = fp,
        originalIds = { itemOp.id },
        campaignId = campId,
    }))
    assertTrue(confOp ~= nil, "3A4: confirmation prepared")
    assertEq(GS:ApplyStagedConfirmationOperation(confOp), "accepted", "3A4: confirmation accepted")
    local applied = GS:GetCurrentRecord().accounting._consumables.requestedItems["55"]
    assertTrue(type(applied) == "table", "3A4: confirmation applied retained candidate")
    assertEq(applied.goal, 3, "3A4: confirmed goal applied")
    local acceptedHist = GS:GetCurrentRecord().operations.records[itemOp.id]
    assertTrue(type(acceptedHist) == "table", "3A4: historical op accepted under original id")
    assertEq(acceptedHist.actorGuid, "Player-1-Alice", "3A4: original attribution preserved")
    assertEq(acceptedHist.actorName, "Alice-Garona", "3A4: original actor name preserved")
    assertEq(acceptedHist.timestamp, originalTs, "3A4: original timestamp preserved")
    local eligAfterConfirm = GS:GetCurrentRecord().accounting._consumables.eligibility
    assertEq(eligAfterConfirm.items["55"], originalTs, "3A4: eligibility uses original timestamp")
    assertEq(GS._pendingRelay[itemOp.id], nil, "3A4: applied candidate cleared from pending relay")

    -- Claimed-author current editor rank must NOT auto-authorize a forged relay.
    local forged = {
        schemaVersion = 1,
        id = "forged-by-alice-claim",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 4,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 8888,
        baseTargetRevision = datasetId,
        basePolicyRevision = datasetId,
        baseCampaignId = campId,
    }
    local stForge, reasonForge = providerApply({ kind = "gs-op", op = forged }, "Dave-Garona")
    assertEq(stForge, "pending", "3A4: forged author claim stays pending")
    assertEq(reasonForge, "untrusted_relay", "3A4: untrusted despite claimed editor author")
    assertTrue(GS:GetCurrentRecord().accounting._consumables.bankTab ~= 4,
        "3A4: forged claim did not mutate bank tab")

    -- Rank revocation: demote below threshold then reject remote from Bob.
    local rankOp = select(1, GS:NewConfigOperation("set-editor-rank", "editorRankPosition", 1))
    assertEq(GS:ApplyStagedConfigOperation(rankOp), "accepted", "3A4: tighten rank to GM only")
    switchPlayer("Bob", "Player-1-Bob", 2)
    local bobOp = {
        schemaVersion = 1,
        id = "bob-after-revoke",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 8,
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 9900,
        baseTargetRevision = datasetId,
        basePolicyRevision = rankOp.id,
        baseCampaignId = campId,
    }
    local stRev, reasonRev = GS:AdmitRemoteOperation(bobOp, { sender = "Bob-Garona" })
    assertEq(stRev, "pending", "3A4: revoked editor not applied")
    assertEq(reasonRev, "untrusted_relay", "3A4: untrusted after revoke")
    assertTrue(GS:GetCurrentRecord().accounting._consumables.bankTab ~= 8,
        "3A4: revoked sender did not mutate bank tab")

    -- Eligibility: GM admits a second item with original timestamp preserved.
    switchPlayer("Alice", "Player-1-Alice", 1)
    settleRoster()
    local itemOp2 = {
        schemaVersion = 1,
        id = "hist-item-2",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-requested-item",
        target = { itemId = 66 },
        value = { itemId = 66, goal = 2, removed = false },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = originalTs,
        baseTargetRevision = datasetId,
        basePolicyRevision = rankOp.id,
        baseCampaignId = campId,
    }
    local stItem, reasonItem = GS:AdmitRemoteOperation(itemOp2, { sender = "Alice-Garona" })
    assertEq(stItem, "accepted", "3A4: GM admits item: " .. tostring(reasonItem))
    local elig = GS:GetCurrentRecord().accounting._consumables.eligibility
    assertEq(elig.items["66"], originalTs, "3A4: original eligibility timestamp preserved")
end

-- 3A5) Missing predecessor pending; duplicates; bounded idle; concurrent campaigns
do
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    startCampaign()
    local datasetId = GS:GetCurrentRecord().datasetId
    local campId = GS:GetCurrentRecord().currentCampaignId
    local missing = {
        schemaVersion = 1,
        id = "needs-pred",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 2,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 10001,
        baseTargetRevision = "missing-pred-id",
        basePolicyRevision = datasetId,
        baseCampaignId = campId,
    }
    local stPend, reasonPend = GS:AdmitRemoteOperation(missing, { sender = "Alice-Garona" })
    assertEq(stPend, "pending", "3A5: missing predecessor pending")
    assertTrue(reasonPend == "missing_predecessor" or reasonPend == "stale_base",
        "3A5: missing predecessor reason: " .. tostring(reasonPend))
    assertEq(GS:AdmitRemoteOperation(missing, { sender = "Alice-Garona" }), "pending",
        "3A5: exact pending retry idempotent")

    -- Concurrent campaign conflict
    local c1 = select(1, GS:NewCampaignOperation())
    assertEq(GS:ApplyStagedCampaignOperation(c1), "accepted", "3A5: campaign A")
    local c2 = {
        schemaVersion = 1,
        id = "camp-conflict-b",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = c1.baseCampaignId,
        kind = "start-campaign",
        target = "campaign",
        value = {},
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 10050,
        baseTargetRevision = c1.baseTargetRevision,
        basePolicyRevision = datasetId,
        baseCampaignId = c1.baseCampaignId,
    }
    local border = {
        schemaVersion = 1,
        campaignId = c2.id,
        datasetId = datasetId,
        guildKey = "club:42",
        parentCampaignId = c1.baseCampaignId,
        resetOperationId = c2.id,
        createdByGuid = "Player-1-Bob",
        createdByName = "Bob-Garona",
        startedAt = 10050,
        bankTabAtStart = nil,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = "unavailable",
    }
    local stCC, reasonCC = GS:AdmitRemoteOperation(c2, { sender = "Bob-Garona", boundary = border })
    assertTrue(stCC == "pending" or stCC == "rejected", "3A5: campaign conflict retained")
    assertTrue(reasonCC == "campaign_conflict" or reasonCC == "divergent_edit"
        or reasonCC == "open_conflict" or reasonCC == "stale_base",
        "3A5: campaign conflict reason: " .. tostring(reasonCC))

    -- No chat noise
    assertEq(#world.chat, 0, "3A5: no chat frames")
    assertEq(#world.prints, 0, "3A5: no prints")
end

-- 3A6) Provider export lists records; EnsureGossipProvider idempotent; Debug-off silence
do
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    world.debugLogs = {}
    SF.Debug:SetEnabled(false)
    initGS()
    GS:CreateStagedRecord()
    assertTrue(GS:EnsureGossipProvider(), "3A6: ensure")
    assertTrue(GS:EnsureGossipProvider(), "3A6: idempotent")
    startCampaign()
    local entry = GG.GetProvider(GS.PROVIDER_ID)
    local page = entry.api.ListRecordIds(1, 64)
    assertTrue(#page >= 2, "3A6: export has desc + ops")
    assertEq(#world.debugLogs, 0, "3A6: debug-off silent")
    assertEq(#world.chat, 0, "3A6: no chat")
end

-- 3A7) Valid-policy editor rank replicates without GM recovery; opposite-order
-- conflicts converge; late peer reconstructs; unauthorized archive rejected;
-- pending-relay / conflict capacity bounds; adoption expiry; export prune.
do
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    startCampaign()
    local datasetId = GS:GetCurrentRecord().datasetId
    local campId = GS:GetCurrentRecord().currentCampaignId
    local policy = GS:GetCurrentRecord().permission.revisionId

    -- Valid policy: Bob (rank 2, threshold 3) admits a set-editor-rank change.
    local rankOp = {
        schemaVersion = 1,
        id = "rank-from-bob",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-editor-rank",
        target = "editorRankPosition",
        value = 2,
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 12000,
        baseTargetRevision = policy,
        basePolicyRevision = policy,
        baseCampaignId = campId,
    }
    local stRank, reasonRank = GS:AdmitRemoteOperation(rankOp, { sender = "Bob-Garona" })
    assertEq(stRank, "accepted", "3A7: valid-policy rank from editor: " .. tostring(reasonRank))
    assertEq(GS:GetCurrentRecord().permission.editorRankPosition, 2, "3A7: rank applied")
    assertEq(GS:GetCurrentRecord().permission.revisionId, "rank-from-bob", "3A7: policy revision advanced")

    -- Unauthorized archive (non-editor) rejected; forged current-campaign archive rejected.
    local stArch, reasonArch = providerApply({
        kind = "campaign-archive",
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = campId,
        datasetId = datasetId,
        requestedItems = {},
        generation = 1,
        archivedAt = 1,
    }, "Dave-Garona")
    assertEq(stArch, "rejected", "3A7: non-editor current-campaign archive rejected")
    assertEq(reasonArch, "unauthorized",
        "3A7: non-editor archive must fail auth before current guard: " .. tostring(reasonArch))

    -- Separately: editor's current-campaign archive is rejected for current_campaign.
    local stArchCur, reasonArchCur = providerApply({
        kind = "campaign-archive",
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = campId,
        datasetId = datasetId,
        requestedItems = {},
        generation = 1,
        archivedAt = 1,
    }, "Alice-Garona")
    assertEq(stArchCur, "rejected", "3A7: editor current-campaign archive rejected")
    assertEq(reasonArchCur, "current_campaign",
        "3A7: editor current archive reason: " .. tostring(reasonArchCur))

    -- Opposite-order same-field conflict then resolve to Bob's value.
    local aliceTab = {
        schemaVersion = 1,
        id = "alice-tab-a",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 1,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 13000,
        baseTargetRevision = datasetId,
        basePolicyRevision = "rank-from-bob",
        baseCampaignId = campId,
    }
    local bobTab = {
        schemaVersion = 1,
        id = "bob-tab-b",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 5,
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 13001,
        baseTargetRevision = datasetId,
        basePolicyRevision = "rank-from-bob",
        baseCampaignId = campId,
    }
    assertEq(GS:AdmitRemoteOperation(aliceTab, { sender = "Alice-Garona" }), "accepted", "3A7: alice tab")
    local stB, reasonB = GS:AdmitRemoteOperation(bobTab, { sender = "Bob-Garona" })
    assertTrue(stB == "pending" or stB == "rejected", "3A7: bob divergent retained")
    local conflicts = GS:ListOpenConflicts()
    assertTrue(#conflicts >= 1, "3A7: open conflict")
    local entry = conflicts[1]
    local ids = {}
    for i = 1, #entry.candidates do
        ids[#ids + 1] = entry.candidates[i].id
    end
    -- Choose non-first candidate (Bob) explicitly.
    local chosen = "bob-tab-b"
    local resOp = select(1, GS:NewConflictResolutionOperation(entry.targetKey, chosen, ids))
    assertTrue(resOp ~= nil, "3A7: resolution prepared")
    assertEq(GS:ApplyStagedConflictResolution(resOp), "accepted", "3A7: resolve to Bob")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 5, "3A7: Bob value wins")
    assertEq(#GS:ListOpenConflicts(), 0, "3A7: conflicts cleared")

    -- Pending relay capacity bound does not corrupt accepted state.
    local tabBefore = GS:GetCurrentRecord().accounting._consumables.bankTab
    GS._pendingRelay = {}
    local full = 0
    for i = 1, (GS.MAX_PENDING_RELAY or 64) + 4 do
        local junk = {
            schemaVersion = 1,
            id = "relay-cap-" .. i,
            guildKey = "club:42",
            datasetId = GS:GetCurrentRecord().datasetId,
            campaignId = GS:GetCurrentRecord().currentCampaignId,
            kind = "set-bank-tab",
            target = "bankTab",
            value = ((i - 1) % 8) + 1,
            actorGuid = "Player-1-Alice",
            actorName = "Alice-Garona",
            timestamp = 14000 + i,
            baseTargetRevision = datasetId,
            basePolicyRevision = GS:GetCurrentRecord().permission.revisionId,
            baseCampaignId = GS:GetCurrentRecord().currentCampaignId,
        }
        local st = select(1, providerApply({ kind = "gs-op", op = junk }, "Dave-Garona"))
        if st == "rejected" then
            full = full + 1
        end
    end
    local pendingCount = 0
    for _ in pairs(GS._pendingRelay or {}) do
        pendingCount = pendingCount + 1
    end
    assertEq(pendingCount, GS.MAX_PENDING_RELAY or 64,
        "3A7: pending relay sits at configured cap")
    assertTrue(full >= 1, "3A7: pending relay capacity rejects overflow")
    local lastSt, lastReason = providerApply({
        kind = "gs-op",
        op = {
            schemaVersion = 1,
            id = "relay-cap-overflow-exact",
            guildKey = "club:42",
            datasetId = GS:GetCurrentRecord().datasetId,
            campaignId = GS:GetCurrentRecord().currentCampaignId,
            kind = "set-bank-tab",
            target = "bankTab",
            value = 3,
            actorGuid = "Player-1-Alice",
            actorName = "Alice-Garona",
            timestamp = 14999,
            baseTargetRevision = datasetId,
            basePolicyRevision = GS:GetCurrentRecord().permission.revisionId,
            baseCampaignId = GS:GetCurrentRecord().currentCampaignId,
        },
    }, "Dave-Garona")
    assertEq(lastSt, "rejected", "3A7: overflow status rejected")
    assertEq(lastReason, "full", "3A7: overflow reason full")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, tabBefore,
        "3A7: capacity reject left accepted state intact")
    GS._pendingRelay = {}

    -- Adoption expiry clears abandoned session.
    GS.NotePeerDataset("Bob-Garona", "foreign-ds-expiry", { editorRankPosition = 2 })
    GS:BeginDatasetAdoption("Bob-Garona", "foreign-ds-expiry")
    assertTrue(GS:GetPendingAdoption() ~= nil, "3A7: adoption pending")
    GS._adoption.startedAt = (GetServerTime() or 0) - ((GS.MAX_ADOPTION_SECONDS or 600) + 5)
    assertEq(GS:GetPendingAdoption(), nil, "3A7: expired adoption cleared")

    -- Snapshot export for late-peer adoption BEFORE prune replaces the dataset.
    GS.NotifyLocalDurableChange("dataset")
    local exportBodies = {}
    local prov = GG.GetProvider(GS.PROVIDER_ID)
    local page = prov.api.ListRecordIds(1, 128)
    for i = 1, #page do
        local rec = prov.api.GetRecordBody(page[i])
        if rec and rec.body then
            exportBodies[#exportBodies + 1] = {
                id = page[i],
                body = rec.body,
            }
        end
    end
    assertTrue(#exportBodies >= 2, "3A7: export snapshot non-empty")
    local sourceDataset = GS:GetCurrentRecord().datasetId
    local aliceRoot = SpectrumFederationDB.guildSupplies

    -- Late third client reconstructs via out-of-order adoption replay.
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._pendingCampaignBoundaries = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 2 })
    local _, stBeginLate = GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)
    assertEq(stBeginLate, "accepted", "3A7: late begin adoption")
    for i = #exportBodies, 1, -1 do
        local row = exportBodies[i]
        GS:BufferAdoptionRecord(row.id, row.body)
    end
    local adopLate = GS:GetPendingAdoption()
    assertTrue(adopLate and adopLate.ready, "3A7: late adoption transfer ready")
    local stLate, reasonLate = GS:CommitDatasetAdoption()
    assertEq(stLate, "accepted", "3A7: late adoption commit: " .. tostring(reasonLate))
    assertEq(GS:GetCurrentRecord().datasetId, sourceDataset, "3A7: late peer on source dataset")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 5,
        "3A7: late peer converges to resolved tab")
    assertEq(GS:GetCurrentRecord().permission.editorRankPosition, 2,
        "3A7: late peer has rank policy")

    -- Export index prune after adoption on Alice's root.
    SpectrumFederationDB.guildSupplies = aliceRoot
    GS._db = SpectrumFederationDB
    GS._root = aliceRoot
    GS._rootValid = true
    GS._rootReason = nil
    GS._adoption = nil
    GS._pendingRelay = {}
    switchPlayer("Alice", "Player-1-Alice", 1)
    settleRoster()
    GS:EnsureGossipProvider()
    local oldDataset = GS:GetCurrentRecord().datasetId
    GS.NotePeerDataset("Bob-Garona", "adopt-prune-ds", { editorRankPosition = 2 })
    GS:BeginDatasetAdoption("Bob-Garona", "adopt-prune-ds")
    GS:BufferAdoptionRecord("gs:desc:adopt-prune-ds", {
        kind = "dataset-desc",
        schemaVersion = 1,
        guildKey = "club:42",
        datasetId = "adopt-prune-ds",
        editorRankPosition = 2,
        permissionRevisionId = "adopt-prune-ds",
        bootstrapEditorRankPosition = 2,
        activation = "staged",
        acceptedOpCount = 0,
        campaignCount = 0,
        archiveCount = 0,
    })
    local stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
    assertEq(stAdopt, "accepted", "3A7: adoption for prune: " .. tostring(reasonAdopt))
    assertEq(GS:GetCurrentRecord().datasetId, "adopt-prune-ds", "3A7: adopted new dataset")
    local page3 = GG.GetProvider(GS.PROVIDER_ID).api.ListRecordIds(1, 128)
    local stillOld = false
    for i = 1, #page3 do
        if tostring(page3[i]):find(oldDataset, 1, true) then
            stillOld = true
        end
    end
    assertEq(stillOld, false, "3A7: stale export ids pruned after adoption")
    assertEq(#world.chat, 0, "3A7: no chat")
end


-- 3A8) Repair-batch regressions: editor-forward confirmation gate, confirm-first
-- redrive, concurrent rank conflict, rank bounds, campaign sibling resolve,
-- repeated-conflict unwrap, adoption freshness, conflict capacity, validated relay.
do
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    startCampaign()
    local datasetId = GS:GetCurrentRecord().datasetId
    local campId = GS:GetCurrentRecord().currentCampaignId
    local policy = GS:GetCurrentRecord().permission.revisionId

    -- Editor carrier forwarding another author's body retains for confirmation.
    local foreign = {
        schemaVersion = 1,
        id = "fwd-bob-tab",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 6,
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 15000,
        baseTargetRevision = datasetId,
        basePolicyRevision = policy,
        baseCampaignId = campId,
    }
    local stFwd, reasonFwd = providerApply({ kind = "gs-op", op = foreign }, "Alice-Garona")
    assertEq(stFwd, "pending", "3A8: editor-forward foreign body pending")
    assertEq(reasonFwd, "untrusted_relay", "3A8: editor-forward reason untrusted_relay")
    assertTrue(GS._pendingRelay["fwd-bob-tab"] ~= nil, "3A8: retained pending relay")
    assertNil(GS:GetCurrentRecord().operations.records["fwd-bob-tab"],
        "3A8: foreign body not silently accepted")

    -- Confirm-first then candidate arrival redrives exact confirmation.
    local fpFwd = GS.ContentFingerprint(foreign)
    local confFirst = {
        schemaVersion = 1,
        id = "conf-first-fwd",
        guildKey = "club:42",
        datasetId = datasetId,
        kind = "confirm-candidate",
        candidateRef = {
            recordId = "fwd-bob-tab",
            contentFingerprint = fpFwd,
        },
        contentFingerprint = fpFwd,
        campaignId = campId,
        basePolicyRevision = policy,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 15001,
    }
    -- Clear relay and accept confirmation first (candidate absent).
    GS._pendingRelay = {}
    assertEq(GS:AdmitRemoteOperation(confFirst, { sender = "Alice-Garona" }), "accepted",
        "3A8: confirm-first accepted")
    assertNil(GS:GetCurrentRecord().operations.records["fwd-bob-tab"],
        "3A8: confirm-first does not invent candidate")
    local stCand = GS:AdmitRemoteOperation(foreign, {
        sender = "Alice-Garona",
        relay = true,
    })
    assertEq(stCand, "pending", "3A8: candidate retained after confirm-first")
    assertTrue(GS:GetCurrentRecord().operations.records["fwd-bob-tab"] ~= nil,
        "3A8: confirm-first redrive applied candidate")

    -- Concurrent same-base rank edits conflict (arrival order must not supersede).
    local rankA = {
        schemaVersion = 1,
        id = "rank-sib-a",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-editor-rank",
        target = "editorRankPosition",
        value = 2,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 15100,
        baseTargetRevision = policy,
        basePolicyRevision = policy,
        baseCampaignId = campId,
    }
    local rankB = {
        schemaVersion = 1,
        id = "rank-sib-b",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-editor-rank",
        target = "editorRankPosition",
        value = 1,
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 15101,
        baseTargetRevision = policy,
        basePolicyRevision = policy,
        baseCampaignId = campId,
    }
    assertEq(GS:AdmitRemoteOperation(rankA, { sender = "Alice-Garona" }), "accepted",
        "3A8: first rank sibling accepted")
    local stRankB, reasonRankB = GS:AdmitRemoteOperation(rankB, { sender = "Bob-Garona" })
    assertEq(stRankB, "pending", "3A8: concurrent rank sibling pending conflict")
    assertTrue(reasonRankB == "divergent_edit" or reasonRankB == "open_conflict"
        or reasonRankB == "stale_base",
        "3A8: concurrent rank conflict reason: " .. tostring(reasonRankB))
    assertTrue(#GS:ListOpenConflicts() >= 1, "3A8: open rank conflict retained")

    -- Out-of-range rank rejected; policy unchanged.
    local policyBefore = GS:GetCurrentRecord().permission.editorRankPosition
    local rankBad = {
        schemaVersion = 1,
        id = "rank-oor",
        guildKey = "club:42",
        datasetId = datasetId,
        campaignId = campId,
        kind = "set-editor-rank",
        target = "editorRankPosition",
        value = 999,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 15200,
        baseTargetRevision = GS:GetCurrentRecord().permission.revisionId,
        basePolicyRevision = GS:GetCurrentRecord().permission.revisionId,
        baseCampaignId = campId,
    }
    -- Resolve open rank conflict first by choosing rankA so policy is coherent.
    local conflicts = GS:ListOpenConflicts()
    for i = 1, #conflicts do
        if conflicts[i].targetKey == "permission:editorRankPosition" then
            local ids = {}
            for j = 1, #conflicts[i].candidates do
                ids[#ids + 1] = conflicts[i].candidates[j].id
            end
            local res = select(1, GS:NewConflictResolutionOperation(
                conflicts[i].targetKey, "rank-sib-a", ids))
            if res then
                GS:ApplyStagedConflictResolution(res)
            end
        end
    end
    policyBefore = GS:GetCurrentRecord().permission.editorRankPosition
    local stBad, reasonBad = GS:AdmitRemoteOperation(rankBad, { sender = "Alice-Garona" })
    assertEq(stBad, "rejected", "3A8: out-of-range rank rejected")
    assertEq(reasonBad, "invalid_editor_rank_position",
        "3A8: OOR rank reason: " .. tostring(reasonBad))
    assertEq(GS:GetCurrentRecord().permission.editorRankPosition, policyBefore,
        "3A8: OOR rank left policy unchanged")

    -- Malformed relay (bankTab=9) must not consume capacity.
    GS._pendingRelay = {}
    local stMal, reasonMal = providerApply({
        kind = "gs-op",
        op = {
            schemaVersion = 1,
            id = "bad-tab-9",
            guildKey = "club:42",
            datasetId = datasetId,
            campaignId = campId,
            kind = "set-bank-tab",
            target = "bankTab",
            value = 9,
            actorGuid = "Player-1-Alice",
            actorName = "Alice-Garona",
            timestamp = 15300,
            baseTargetRevision = datasetId,
            basePolicyRevision = GS:GetCurrentRecord().permission.revisionId,
            baseCampaignId = campId,
        },
    }, "Dave-Garona")
    assertEq(stMal, "rejected", "3A8: malformed bankTab=9 rejected")
    assertTrue(reasonMal == "invalid_bank_tab" or reasonMal == "invalid_operation",
        "3A8: malformed relay reason: " .. tostring(reasonMal))
    local malCount = 0
    for _ in pairs(GS._pendingRelay or {}) do malCount = malCount + 1 end
    assertEq(malCount, 0, "3A8: malformed relay did not retain a slot")

    -- Conflict candidate capacity uses shared MAX_CONFLICT_CANDIDATES.
    local maxCand = GS.MAX_CONFLICT_CANDIDATES or 16
    assertEq(maxCand, 16, "3A8: shared conflict candidate bound is 16")
    local ops = GS:GetCurrentRecord().operations
    local fakeIds = {}
    for i = 1, maxCand do
        fakeIds[i] = "cand-cap-" .. i
    end
    local okMark, errMark = GS._MarkTargetConflict(ops, "config:bankTab", fakeIds, 1)
    assertEq(okMark, true, "3A8: 16 candidates mark ok: " .. tostring(errMark))
    local ok17, err17 = GS._MarkTargetConflict(ops, "config:bankTab",
        { "cand-cap-1", "cand-cap-extra" }, 2)
    -- Merging an already-seen id is fine; new 17th must fail.
    local ids17 = {}
    for i = 1, maxCand do ids17[i] = "cand-cap-" .. i end
    ids17[maxCand + 1] = "cand-cap-17"
    local okFull, errFull = GS._MarkTargetConflict(ops, "config:overflow-test", ids17, 3)
    assertEq(okFull, false, "3A8: 17 candidates rejected")
    assertEq(errFull, "full", "3A8: 17 candidates reason full")
    -- Reload accessor still valid.
    local exposed, exposeReason = GS:GetCurrentRecord()
    assertTrue(exposed ~= nil, "3A8: record available after conflict capacity: " .. tostring(exposeReason))

    -- Repeated conflict: resolve A/B to A, late C conflicts with underlying A (not envelope).
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    startCampaign()
    datasetId = GS:GetCurrentRecord().datasetId
    campId = GS:GetCurrentRecord().currentCampaignId
    policy = GS:GetCurrentRecord().permission.revisionId
    local tabA = {
        schemaVersion = 1, id = "tab-rep-a", guildKey = "club:42", datasetId = datasetId,
        campaignId = campId, kind = "set-bank-tab", target = "bankTab", value = 1,
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona", timestamp = 16000,
        baseTargetRevision = datasetId, basePolicyRevision = policy, baseCampaignId = campId,
    }
    local tabB = {
        schemaVersion = 1, id = "tab-rep-b", guildKey = "club:42", datasetId = datasetId,
        campaignId = campId, kind = "set-bank-tab", target = "bankTab", value = 2,
        actorGuid = "Player-1-Bob", actorName = "Bob-Garona", timestamp = 16001,
        baseTargetRevision = datasetId, basePolicyRevision = policy, baseCampaignId = campId,
    }
    assertEq(GS:AdmitRemoteOperation(tabA, { sender = "Alice-Garona" }), "accepted", "3A8: tab A")
    assertEq(select(1, GS:AdmitRemoteOperation(tabB, { sender = "Bob-Garona" })), "pending", "3A8: tab B conflict")
    local open = GS:ListOpenConflicts()[1]
    local ids = {}
    for i = 1, #open.candidates do ids[#ids + 1] = open.candidates[i].id end
    local resAB = select(1, GS:NewConflictResolutionOperation(open.targetKey, "tab-rep-a", ids))
    assertEq(GS:ApplyStagedConflictResolution(resAB), "accepted", "3A8: resolve A/B to A")
    assertEq(GS:GetCurrentRecord().operations.heads["config:bankTab"], "tab-rep-a",
        "3A8: head is underlying chosen value not resolve envelope")
    local tabC = {
        schemaVersion = 1, id = "tab-rep-c", guildKey = "club:42", datasetId = datasetId,
        campaignId = campId, kind = "set-bank-tab", target = "bankTab", value = 3,
        actorGuid = "Player-1-Bob", actorName = "Bob-Garona", timestamp = 16002,
        baseTargetRevision = "tab-rep-a", basePolicyRevision = policy, baseCampaignId = campId,
    }
    -- Same base as head for divergent conflict: use datasetId base to force conflict.
    tabC.baseTargetRevision = datasetId
    local stC, reasonC = GS:AdmitRemoteOperation(tabC, { sender = "Bob-Garona" })
    assertEq(stC, "pending", "3A8: late C conflicts with resolved A")
    local open2 = GS:ListOpenConflicts()
    assertTrue(#open2 >= 1, "3A8: repeated conflict open")
    local candIds = {}
    for i = 1, #open2[1].candidates do
        candIds[#candIds + 1] = open2[1].candidates[i].id
        assertTrue(open2[1].candidates[i].id ~= resAB.id,
            "3A8: resolve envelope not a conflict candidate")
    end
    local resKeep = select(1, GS:NewConflictResolutionOperation(open2[1].targetKey, "tab-rep-a", candIds))
    assertTrue(resKeep ~= nil, "3A8: keep-A resolution prepared")
    assertEq(GS:ApplyStagedConflictResolution(resKeep), "accepted", "3A8: keep-A accepted")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 1, "3A8: keep-A value")

    -- Adoption freshness: local edit while buffering rejects commit and preserves state.
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    startCampaign()
    local localDs = GS:GetCurrentRecord().datasetId
    local beforeTab = GS:GetCurrentRecord().accounting._consumables.bankTab
    GS.NotePeerDataset("Bob-Garona", "fresh-ds", {
        editorRankPosition = 2,
        permissionRevisionId = "fresh-ds",
    })
    GS:BeginDatasetAdoption("Bob-Garona", "fresh-ds")
    GS:BufferAdoptionRecord("gs:desc:fresh-ds", {
        kind = "dataset-desc",
        schemaVersion = 1,
        guildKey = "club:42",
        datasetId = "fresh-ds",
        editorRankPosition = 2,
        permissionRevisionId = "fresh-ds",
        bootstrapEditorRankPosition = 2,
        activation = "staged",
        acceptedOpCount = 0,
        campaignCount = 0,
        archiveCount = 0,
    })
    -- Local edit after Begin.
    local editOp, est = GS:NewConfigOperation("set-bank-tab", "bankTab", 4)
    assertEq(est, "accepted", "3A8: local edit prepared during adoption")
    assertEq(GS:ApplyStagedConfigOperation(editOp), "accepted", "3A8: local edit applied during adoption")
    local stCommit, reasonCommit = GS:CommitDatasetAdoption()
    assertEq(stCommit, "rejected", "3A8: commit rejected after local edit")
    assertEq(reasonCommit, "stale_base", "3A8: freshness reason stale_base")
    assertEq(GS:GetCurrentRecord().datasetId, localDs, "3A8: local dataset preserved")
    assertEq(GS:GetCurrentRecord().accounting._consumables.bankTab, 4,
        "3A8: local edit preserved after failed adoption")

    -- Adoption ready notify fires for UI refresh hook.
    local notifyCount = 0
    GS.OnAdoptionStateChanged = function()
        notifyCount = notifyCount + 1
    end
    GS:CancelDatasetAdoption()
    GS.NotePeerDataset("Bob-Garona", "notify-ds", {
        editorRankPosition = 2,
        permissionRevisionId = "notify-ds",
    })
    GS:BeginDatasetAdoption("Bob-Garona", "notify-ds")
    assertTrue(notifyCount >= 1, "3A8: begin notifies adoption state")
    notifyCount = 0
    GS:BufferAdoptionRecord("gs:desc:notify-ds", {
        kind = "dataset-desc",
        schemaVersion = 1,
        guildKey = "club:42",
        datasetId = "notify-ds",
        editorRankPosition = 2,
        permissionRevisionId = "notify-ds",
        bootstrapEditorRankPosition = 2,
        activation = "staged",
        acceptedOpCount = 0,
        campaignCount = 0,
        archiveCount = 0,
    })
    assertTrue(notifyCount >= 1, "3A8: ready notifies adoption state")
    assertTrue(GS:GetPendingAdoption().ready == true, "3A8: adoption ready")

    -- bootstrapEditorRankPosition preserved across rank change.
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    local created = GS:CreateStagedRecord()
    assertEq(created.permission.bootstrapEditorRankPosition, 3, "3A8: bootstrap captured at create")
    GS:EnsureGossipProvider()
    startCampaign()
    local bootPolicy = GS:GetCurrentRecord().permission.revisionId
    local rankTo1 = {
        schemaVersion = 1, id = "rank-to-1", guildKey = "club:42",
        datasetId = GS:GetCurrentRecord().datasetId,
        campaignId = GS:GetCurrentRecord().currentCampaignId,
        kind = "set-editor-rank", target = "editorRankPosition", value = 1,
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona", timestamp = 17000,
        baseTargetRevision = bootPolicy, basePolicyRevision = bootPolicy,
        baseCampaignId = GS:GetCurrentRecord().currentCampaignId,
    }
    assertEq(GS:AdmitRemoteOperation(rankTo1, { sender = "Alice-Garona" }), "accepted",
        "3A8: rank change to 1")
    assertEq(GS:GetCurrentRecord().permission.editorRankPosition, 1, "3A8: live rank 1")
    assertEq(GS:GetCurrentRecord().permission.bootstrapEditorRankPosition, 3,
        "3A8: bootstrap threshold preserved")
    GS.NotifyLocalDurableChange("config")
    local descBody
    local page = GG.GetProvider(GS.PROVIDER_ID).api.ListRecordIds(1, 32)
    for i = 1, #page do
        local rec = GG.GetProvider(GS.PROVIDER_ID).api.GetRecordBody(page[i])
        if rec and rec.body and rec.body.kind == "dataset-desc" then
            descBody = rec.body
        end
    end
    assertTrue(descBody ~= nil, "3A8: dataset desc exported")
    assertEq(descBody.bootstrapEditorRankPosition, 3,
        "3A8: export bootstrapEditorRankPosition is original")

    -- Non-editor archive of an ended (non-current) campaign is unauthorized.
    local endedId = GS:GetCurrentRecord().currentCampaignId
    startCampaign() -- archives previous
    local stEnded, reasonEnded = providerApply({
        kind = "campaign-archive",
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = endedId,
        datasetId = GS:GetCurrentRecord().datasetId,
        requestedItems = {},
        generation = 1,
        archivedAt = 1,
    }, "Dave-Garona")
    assertEq(stEnded, "rejected", "3A8: non-editor ended-campaign archive rejected")
    assertEq(reasonEnded, "unauthorized",
        "3A8: ended archive unauthorized: " .. tostring(reasonEnded))

    assertEq(#world.chat, 0, "3A8: no chat")
end


io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
