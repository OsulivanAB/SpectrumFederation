-- Production-Lua tests for Raid Signup (#404).
-- Run from repository root: lua5.1 tests/lua/raid_signup_tests.lua

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
    time = 12000,
    guild = {
        inGuild = true,
        name = "Spectrum",
        realm = "Garona",
        clubId = 42,
        ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
        members = {
            { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
            { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
            { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 4, online = true },
            { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
        },
        rosterComplete = true,
    },
    unitName = "Alice",
    unitGuid = "Player-1-Alice",
    impersonationActive = false,
    providerChanged = 0,
    timers = 0,
}

function GetTime() return world.time end
function time() return math.floor(world.time) end
function GetServerTime() return math.floor(world.time) end
function IsInGuild() return world.guild.inGuild end
function GetRealmName() return "Garona" end
function strtrim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
function UnitName() return world.unitName end
function UnitFullName() return world.unitName, "Garona" end
function UnitGUID(unit)
    if unit == "player" then return world.unitGuid end
end
function UnitClass() return "Mage", "MAGE" end
function GetNumGuildMembers()
    if not world.guild.rosterComplete then return 0, 0, 0 end
    return #world.guild.members, #world.guild.members, #world.guild.members
end
function GetGuildRosterInfo(i)
    local m = world.guild.members[i]
    if not m then return end
    local rankIndex = (tonumber(m.rankOrder) or 1) - 1
    return m.name, world.guild.ranks[m.rankOrder] or "Rank", rankIndex, 80, "Mage", "Zone",
        "", "", m.online, 0, "MAGE", 0, 0, false, false, 0, m.guid
end
function date(fmt, ts) return os.date(fmt, ts) end
function GetSpecializationInfoByID(specId)
    local names = {
        [62] = "Arcane", [71] = "Arms", [72] = "Fury", [65] = "Holy", [66] = "Protection",
        [70] = "Retribution", [105] = "Restoration", [259] = "Assassination",
    }
    return specId, names[specId] or ("Spec" .. tostring(specId)), nil, "Interface\\Icons\\INV_Misc_QuestionMark"
end

C_Timer = {
    After = function()
        world.timers = world.timers + 1
    end,
    NewTimer = function()
        world.timers = world.timers + 1
        return { Cancel = function() end }
    end,
}

local function serTable(t, depth)
    depth = (depth or 0) + 1
    if depth > 12 then return "?" end
    if type(t) ~= "table" then return tostring(t) end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = { "{" }
    for i = 1, #keys do
        parts[#parts + 1] = tostring(keys[i]) .. "=" .. serTable(t[keys[i]], depth) .. ";"
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

C_EncodingUtil = { SerializeCBOR = serTable }

local SF = {}
local addonName = "SpectrumFederation"
SF.L = {}
function SF.LocaleText(key, default)
    local v = SF.L[key]
    if type(v) == "string" and v ~= "" then return v end
    return default or key
end

SF.Debug = {
    _on = false,
    IsEnabled = function(self) return self._on end,
    Info = function() end,
    Warn = function() end,
    Verbose = function() end,
}

SF.WOW_CLASSES = {
    WARRIOR = { textureFile = "Interface\\Icons\\ClassIcon_Warrior" },
    PALADIN = { textureFile = "Interface\\Icons\\ClassIcon_Paladin" },
    HUNTER = { textureFile = "Interface\\Icons\\ClassIcon_Hunter" },
    ROGUE = { textureFile = "Interface\\Icons\\ClassIcon_Rogue" },
    PRIEST = { textureFile = "Interface\\Icons\\ClassIcon_Priest" },
    DEATHKNIGHT = { textureFile = "Interface\\Icons\\ClassIcon_DeathKnight" },
    SHAMAN = { textureFile = "Interface\\Icons\\ClassIcon_Shaman" },
    MAGE = { textureFile = "Interface\\Icons\\ClassIcon_Mage" },
    WARLOCK = { textureFile = "Interface\\Icons\\ClassIcon_Warlock" },
    MONK = { textureFile = "Interface\\Icons\\ClassIcon_Monk" },
    DRUID = { textureFile = "Interface\\Icons\\ClassIcon_Druid" },
    DEMONHUNTER = { textureFile = "Interface\\Icons\\ClassIcon_DemonHunter" },
    EVOKER = { textureFile = "Interface\\Icons\\ClassIcon_Evoker" },
}

SF.LootHelperImpersonation = {
    IsActive = function()
        return world.impersonationActive
    end,
}

-- Minimal Guild Gossip adapter (identity/roster only).
local GG = {}
SF.GuildGossip = GG

local function Norm(name)
    return tostring(name or "")
end

function GG.SelfId()
    return world.unitName .. "-Garona"
end

function GG.GetGuildIdentity()
    if not world.guild.inGuild then
        return nil, "not_in_guild"
    end
    return {
        guildKey = "club:" .. tostring(world.guild.clubId),
        clubId = tostring(world.guild.clubId),
        guildName = world.guild.name,
        guildRealm = world.guild.realm,
        transportScopeId = "club:" .. tostring(world.guild.clubId),
    }
end

function GG.GetGuildScopeId()
    local id = GG.GetGuildIdentity()
    return id and id.transportScopeId or nil
end

function GG.GetGuildRanks()
    local ranks = { count = #world.guild.ranks, guildKey = "club:" .. tostring(world.guild.clubId) }
    for i = 1, #world.guild.ranks do
        ranks[i] = world.guild.ranks[i]
    end
    return ranks
end

function GG.GetGuildMember(name)
    name = Norm(name)
    for i = 1, #world.guild.members do
        local m = world.guild.members[i]
        if m.name == name then
            return {
                name = m.name,
                guid = m.guid,
                rankOrder = m.rankOrder,
                guildKey = "club:" .. tostring(world.guild.clubId),
                online = m.online,
            }
        end
    end
    return nil, "unknown_sender"
end

function GG.IsGuildMember(name)
    return GG.GetGuildMember(name) ~= nil
end

function GG.Hash32(s)
    local h = 0
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 4294967296
    end
    return h
end

GG.MAX_RECORD_CBOR = 2048
GG._providers = {}
function GG.Init() end
function GG.RegisterProvider(spec)
    if GG._providers[spec.id] then
        return false, "already_registered"
    end
    GG._providers[spec.id] = spec
    return true
end
function GG.GetProvider(id)
    return GG._providers[id]
end
function GG.SetProviderEnabled() end
function GG.NotifyProviderChanged()
    world.providerChanged = world.providerChanged + 1
end
function GG.BumpIndexEpoch() end
function GG.IndexUpsert() end
function GG.CreateIndex() return {} end

SF.NameUtil = {
    NormalizeNameRealm = function(name)
        if type(name) ~= "string" or name == "" then
            return nil
        end
        return name
    end,
}

-- Load Guild Officer (threshold) then Raid Signup modules.
local function load(path)
    local chunk, err = loadfile(path)
    if not chunk then
        error("loadfile failed " .. path .. ": " .. tostring(err))
    end
    chunk(addonName, SF)
end

load("SpectrumFederation/modules/GuildOfficer/Policy.lua")
load("SpectrumFederation/modules/GuildOfficer/Gossip.lua")
load("SpectrumFederation/modules/RaidSignup/Coverage.lua")
load("SpectrumFederation/modules/RaidSignup/State.lua")
load("SpectrumFederation/modules/RaidSignup/Authority.lua")
load("SpectrumFederation/modules/RaidSignup/Operations.lua")
load("SpectrumFederation/modules/RaidSignup/Gossip.lua")

local RS = SF.RaidSignup
local GO = SF.GuildOfficer

local function ActAs(name, guid)
    world.unitName = name:match("^([^-]+)") or name
    world.unitGuid = guid
end

SpectrumFederationDB = {}
ActAs("Alice-Garona", "Player-1-Alice")
assertTrue(GO:Initialize(SpectrumFederationDB), "officer initialize")
assertEq(select(1, GO:Bootstrap()), "accepted", "GM bootstrap officer policy")
assertTrue(RS:Initialize(SpectrumFederationDB), "raid signup initialize")

---------------------------------------------------------------------------
-- Draft completion order / incomplete discard
---------------------------------------------------------------------------

local draft = RS.MakeDraft("plan-temp")
local _, complete = RS.UpdateDraftField(draft, "classFile", "MAGE")
assertEq(complete, false, "class alone is incomplete")
_, complete = RS.UpdateDraftField(draft, "specId", 62)
assertEq(complete, false, "class+spec without nickname incomplete")
_, complete = RS.UpdateDraftField(draft, "nickname", "Spark")
assertEq(complete, true, "nickname last completes draft")

draft = RS.MakeDraft("plan-temp")
RS.UpdateDraftField(draft, "nickname", "Spark")
RS.UpdateDraftField(draft, "specId", 62)
_, complete = RS.UpdateDraftField(draft, "classFile", "MAGE")
-- classFile clears specId by design when class changes; re-select spec
assertEq(RS.DraftIsComplete(draft), false, "changing class clears spec")
RS.UpdateDraftField(draft, "specId", 62)
assertEq(RS.DraftIsComplete(draft), true, "spec after class completes")

assertTrue(not RS.IsCompleteEntryPayload("  ", "MAGE", 62), "blank nickname never completes")

---------------------------------------------------------------------------
-- Plan + entry local lifecycle
---------------------------------------------------------------------------

ActAs("Alice-Garona", "Player-1-Alice")
local status, _, planId = RS:CreatePlan("Midnight S2")
assertEq(status, "accepted", "officer creates plan")
assertTrue(type(planId) == "string", "planId returned")

ActAs("Carol-Garona", "Player-1-Carol")
status = RS:CreatePlan("Should Fail")
assertEq(status, "rejected", "member cannot create plan")

-- Member creates entries with different input orders via UpsertEntry (complete only).
ActAs("Carol-Garona", "Player-1-Carol")
local entryA, entryB
status, _, entryA = RS:UpsertEntry({
    planId = planId,
    nickname = "CarolMain",
    mainClass = "MAGE",
    mainSpec = 62,
    notes = "note-a",
})
assertEq(status, "accepted", "member creates entry A")

status, _, entryB = RS:UpsertEntry({
    planId = planId,
    nickname = "carolmain", -- duplicate nickname allowed (different case)
    mainClass = "WARRIOR",
    mainSpec = 71,
})
assertEq(status, "accepted", "duplicate nickname allowed")

local listed = RS:GetSortedEntries(planId)
assertEq(#listed, 2, "two live entries")
assertEq(listed[1].nickname, "CarolMain", "sort by nickname keeps first equal-insensitive? stable by id")
-- lower-case c sorts after C in byte order? string.lower makes them equal then entryId tie-break
assertTrue(listed[1].entryId ~= listed[2].entryId, "stable distinct ids")

---------------------------------------------------------------------------
-- Alternative completion / abandonment / duplicate rejection
---------------------------------------------------------------------------

local alt = RS.MakeAltDraft(listed[1])
RS.UpdateAltDraftField(alt, "classFile", "MAGE")
assertTrue(RS.IsAltSpecDisabled(alt, 62), "same-class main spec disabled for alt")
assertEq(RS.AltDraftIsComplete(alt), false, "alt incomplete without spec")
RS.UpdateAltDraftField(alt, "specId", 62)
assertEq(RS.AltDraftIsComplete(alt), false, "identical alt rejected by completeness")

RS.UpdateAltDraftField(alt, "specId", 63)
assertEq(RS.AltDraftIsComplete(alt), true, "different mage spec alt ok")

status = RS:UpsertEntry({
    entryId = entryA,
    planId = planId,
    nickname = "CarolMain",
    mainClass = "MAGE",
    mainSpec = 62,
    notes = "note-a",
    altClass = "MAGE",
    altSpec = 62,
})
assertEq(status, "rejected", "persist rejects duplicate main/alt spec")

status = RS:UpsertEntry({
    entryId = entryA,
    planId = planId,
    nickname = "CarolMain",
    mainClass = "MAGE",
    mainSpec = 62,
    notes = "note-a",
    altClass = "ROGUE",
    altSpec = 259,
})
assertEq(status, "accepted", "alt persists")

-- Abandon incomplete alt: main unchanged
local before = RS.GetEntry(select(1, RS:EnsureGuildRecord("club:42")), entryA)
assertEq(before.altClass, "ROGUE", "main retained alt")
assertEq(before.mainClass, "MAGE", "main class preserved during alt abandon scenario")

status = RS:RemoveAlternative(entryA)
assertEq(status, "accepted", "remove alt keeps main")
local after = RS.GetEntry(select(1, RS:EnsureGuildRecord("club:42")), entryA)
assertNil(after.altClass, "alt cleared")
assertEq(after.mainClass, "MAGE", "main preserved after alt removal")

-- Editing main to collide with existing alt must fail without deleting alt
RS:UpsertEntry({
    entryId = entryA,
    planId = planId,
    nickname = "CarolMain",
    mainClass = "MAGE",
    mainSpec = 62,
    altClass = "WARRIOR",
    altSpec = 71,
})
status = RS:UpsertEntry({
    entryId = entryA,
    planId = planId,
    nickname = "CarolMain",
    mainClass = "WARRIOR",
    mainSpec = 71,
})
assertEq(status, "rejected", "main edit colliding with alt rejected")
after = RS.GetEntry(select(1, RS:EnsureGuildRecord("club:42")), entryA)
assertEq(after.altClass, "WARRIOR", "alt not silently deleted on conflict")

---------------------------------------------------------------------------
-- Saved-selection preservation semantics (incomplete edit does not mutate)
---------------------------------------------------------------------------

local verBefore = after.ver.n
-- Incomplete local draft helpers never call UpsertEntry; stored ver unchanged.
local editDraft = RS.MakeDraft(planId)
RS.UpdateDraftField(editDraft, "classFile", "PRIEST")
assertEq(RS.DraftIsComplete(editDraft), false, "incomplete edit draft")
after = RS.GetEntry(select(1, RS:EnsureGuildRecord("club:42")), entryA)
assertEq(after.ver.n, verBefore, "incomplete draft does not bump stored entry")

---------------------------------------------------------------------------
-- Permissions + remote admission
---------------------------------------------------------------------------

ActAs("Dave-Garona", "Player-1-Dave")
status = RS:UpsertEntry({
    entryId = entryA,
    planId = planId,
    nickname = "Hijack",
    mainClass = "PRIEST",
    mainSpec = 256,
})
assertEq(status, "rejected", "non-creator member cannot edit Carol entry")

ActAs("Bob-Garona", "Player-1-Bob") -- officer
status = RS:UpsertEntry({
    entryId = entryA,
    planId = planId,
    nickname = "OfficerEdit",
    mainClass = "PRIEST",
    mainSpec = 256,
    clearAlt = true,
})
assertEq(status, "accepted", "officer can edit any entry")

-- Remote admission: creator hop ok
local record = select(1, RS:EnsureGuildRecord("club:42"))
local live = record.entries[entryA]
local remoteEntry = RS.CloneEntry(live)
remoteEntry.nickname = "FromCarol"
remoteEntry.ver = { n = live.ver.n + 1, w = "cccccccccccccccccccccccc" }
local provider = GG.GetProvider(RS.PROVIDER_ID)
assertTrue(provider ~= nil, "provider registered")
local delStatus, delDetail = provider.ValidateAndApply({
    id = RS.EntryRecordId(entryA),
    versionFp = "x",
    body = { kind = "raidsignup-entry", schema = 1, entry = remoteEntry },
}, { sender = "Carol-Garona" })
assertEq(delStatus, "accepted", "creator transport hop admits entry")

-- Non-officer relay of newer third-party entry rejected
remoteEntry = RS.CloneEntry(record.entries[entryA])
remoteEntry.nickname = "Relayed"
remoteEntry.ver = { n = remoteEntry.ver.n + 1, w = "dddddddddddddddddddddddd" }
delStatus = provider.ValidateAndApply({
    id = RS.EntryRecordId(entryA),
    versionFp = "y",
    body = { kind = "raidsignup-entry", schema = 1, entry = remoteEntry },
}, { sender = "Dave-Garona" })
assertEq(delStatus, "rejected", "non-officer non-creator relay rejected")

-- Officer relay ok
remoteEntry.ver = { n = record.entries[entryA].ver.n + 1, w = "eeeeeeeeeeeeeeeeeeeeeeee" }
delStatus = provider.ValidateAndApply({
    id = RS.EntryRecordId(entryA),
    versionFp = "z",
    body = { kind = "raidsignup-entry", schema = 1, entry = remoteEntry },
}, { sender = "Bob-Garona" })
assertEq(delStatus, "accepted", "officer relay admits newer entry")

---------------------------------------------------------------------------
-- Deletion / stale resurrection / concurrent ver
---------------------------------------------------------------------------

ActAs("Carol-Garona", "Player-1-Carol")
-- Carol no longer creator-authoritative content after officer edits? creatorGuid immutable.
local cur = record.entries[entryA]
assertEq(cur.creatorGuid, "Player-1-Carol", "creatorGuid immutable")
status = RS:DeleteEntry(entryA, { expectedVer = cur.ver })
assertEq(status, "accepted", "creator can delete own entry")
assertTrue(record.entries[entryA].deleted, "tombstone stored")

-- Stale live replay cannot resurrect
local staleLive = RS.CloneEntry(cur)
staleLive.deleted = false
staleLive.ver = cur.ver -- older than tombstone
delStatus = provider.ValidateAndApply({
    id = RS.EntryRecordId(entryA),
    versionFp = "stale",
    body = { kind = "raidsignup-entry", schema = 1, entry = staleLive },
}, { sender = "Carol-Garona" })
assertEq(delStatus, "duplicate", "stale live replay does not resurrect")
assertTrue(record.entries[entryA].deleted, "still deleted")

---------------------------------------------------------------------------
-- Archive race
---------------------------------------------------------------------------

ActAs("Alice-Garona", "Player-1-Alice")
local plan2, entryC, plan3
status, _, plan2 = RS:CreatePlan("Archived Plan")
assertEq(status, "accepted", "second plan")
ActAs("Carol-Garona", "Player-1-Carol")
status, _, entryC = RS:UpsertEntry({
    planId = plan2,
    nickname = "Temp",
    mainClass = "SHAMAN",
    mainSpec = 262,
})
assertEq(status, "accepted", "entry on open plan")
ActAs("Alice-Garona", "Player-1-Alice")
status = RS:SetPlanArchived(plan2, true)
assertEq(status, "accepted", "archive plan")
ActAs("Carol-Garona", "Player-1-Carol")
status = RS:UpsertEntry({
    entryId = entryC,
    planId = plan2,
    nickname = "Temp2",
    mainClass = "SHAMAN",
    mainSpec = 263,
})
assertEq(status, "rejected", "archived plan rejects edits")

---------------------------------------------------------------------------
-- Summary main-only counts + coverage
---------------------------------------------------------------------------

ActAs("Alice-Garona", "Player-1-Alice")
status, _, plan3 = RS:CreatePlan("Coverage Plan")
RS:SelectPlan(plan3)
ActAs("Carol-Garona", "Player-1-Carol")
RS:UpsertEntry({
    planId = plan3,
    nickname = "Mage",
    mainClass = "MAGE",
    mainSpec = 62,
    altClass = "WARRIOR",
    altSpec = 71,
})
RS:UpsertEntry({
    planId = plan3,
    nickname = "Ret",
    mainClass = "PALADIN",
    mainSpec = 70, -- Retribution: no Devotion Aura
})
RS:UpsertEntry({
    planId = plan3,
    nickname = "HolyPal",
    mainClass = "PALADIN",
    mainSpec = 65,
})

local summary = RS:GetPlanSummary(plan3)
assertEq(summary.classCounts.MAGE, 1, "mage main counted once")
assertEq(summary.classCounts.WARRIOR, 0, "alt warrior not counted")
assertEq(summary.classCounts.PALADIN, 2, "two paladin mains")
assertEq(summary.classCounts.PRIEST, 0, "zero classes included")
assertTrue(summary.major.intellect, "mage covers intellect")
assertTrue(not summary.major.attack_power, "warrior alt does not cover AP")
assertTrue(summary.major.devo_aura, "holy paladin covers deovo")
-- Ret alone would not; holy does.

-- Innervate requires resto druid
assertTrue(not summary.utility.innervate, "no resto druid => no innervate")
RS:UpsertEntry({
    planId = plan3,
    nickname = "Trees",
    mainClass = "DRUID",
    mainSpec = 102, -- balance
})
summary = RS:GetPlanSummary(plan3)
assertTrue(not summary.utility.innervate, "balance druid does not cover innervate")
RS:UpsertEntry({
    planId = plan3,
    nickname = "Resto",
    mainClass = "DRUID",
    mainSpec = 105,
})
summary = RS:GetPlanSummary(plan3)
assertTrue(summary.utility.innervate, "resto druid covers innervate")
assertTrue(summary.utility.atrophic_poison == false or summary.utility.atrophic_poison == nil or not summary.utility.atrophic_poison,
    "no rogue => atrophic uncovered")
assertEq(summary.utility.atrophic_poison, false, "atrophic explicitly false")
assertTrue(summary.major.versatility, "druid covers versatility")

---------------------------------------------------------------------------
-- Reload persistence
---------------------------------------------------------------------------

local snap = SpectrumFederationDB.raidSignup
SF.RaidSignup = nil
-- reload modules onto fresh SF table would be heavy; instead re-init same RS
assertTrue(RS:Initialize(SpectrumFederationDB), "re-init after reload")
local restored = RS:GetSortedPlans(true)
local found = false
for i = 1, #restored do
    if restored[i].planId == plan3 then found = true end
end
assertTrue(found, "plans survive re-init")
assertTrue(#RS:GetSortedEntries(plan3) >= 4, "entries survive re-init")

---------------------------------------------------------------------------
-- Peer convergence via ValidateAndApply (second client)
---------------------------------------------------------------------------

local db2 = { raidSignup = nil }
-- Simulate second client state by cloning root after init on alternate table is complex;
-- apply accepted records onto a fresh guild record using Merge* directly.
local root2 = { schemaVersion = 1, localWriter = { nonce = "ffffffffffffffffffffffff", nextSeq = 1 }, guilds = {} }
local rec2 = {
    schemaVersion = 1,
    guildKey = "club:42",
    clubId = "42",
    plans = {},
    entries = {},
}
root2.guilds["club:42"] = rec2
local src = select(1, RS:EnsureGuildRecord("club:42"))
for _, plan in pairs(src.plans) do
    RS.MergePlan(rec2, plan, { remote = true })
end
for _, entry in pairs(src.entries) do
    RS.MergeEntry(rec2, entry, { remote = true })
end
assertEq(RS.ListEntries(rec2, plan3)[1] ~= nil, true, "peer receives entries")

---------------------------------------------------------------------------
-- UI listener bounded registration
---------------------------------------------------------------------------

RS._ResetUIListenersForTests()
local notifyCount = 0
RS.RegisterUIListener(function()
    notifyCount = notifyCount + 1
end)
RS.NotifyUI("local")
RS.NotifyUI("local")
assertEq(notifyCount, 2, "ui notifies without looping")
local perf = RS.GetExportPerfCounters()
assertEq(perf.listenerCount, 1, "single listener retained")

-- Idle: no timer storms from module itself
local timersBefore = world.timers
RS.NotifyLocalDurableChange("local")
assertEq(world.timers, timersBefore, "durable notify does not schedule timers")

---------------------------------------------------------------------------
-- Coverage name confirmations
---------------------------------------------------------------------------

local foundAtrophic, foundBronze = false, false
for i = 1, #RS.UTILITY_CATEGORIES do
    local cat = RS.UTILITY_CATEGORIES[i]
    if cat.id == "atrophic_poison" then
        foundAtrophic = cat.nameDefault == "Atrophic Poison"
    end
    if cat.id == "blessing_bronze" then
        foundBronze = cat.nameDefault == "Blessing of the Bronze"
    end
end
assertTrue(foundAtrophic, "Atrophic Poison naming")
assertTrue(foundBronze, "Blessing of the Bronze naming")

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
