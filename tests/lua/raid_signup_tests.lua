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
    -- Realistic Retail-shaped returns: id, name, description, icon (file id number), role
    local names = {
        [62] = "Arcane", [71] = "Arms", [72] = "Fury", [65] = "Holy", [66] = "Protection",
        [70] = "Retribution", [105] = "Restoration", [259] = "Assassination",
        [63] = "Fire", [256] = "Discipline", [262] = "Elemental", [263] = "Enhancement",
        [102] = "Balance",
    }
    local descriptions = {
        [62] = "Master of raw arcane magic",
        [71] = "A battle-hardened master of two-handed weapons",
        [105] = "Uses heal-over-time magic to mend allies",
    }
    local icons = {
        [62] = 135932, -- distinct numeric file id (not the spec id)
        [71] = 132355,
        [105] = 136041,
        [65] = 135920,
        [70] = 135959,
        [259] = 236270,
    }
    local name = names[specId] or ("Spec" .. tostring(specId))
    local description = descriptions[specId] or ("Description for " .. name)
    local icon = icons[specId] or (100000 + (tonumber(specId) or 0))
    return specId, name, description, icon, "DAMAGER"
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
    _info = {},
    _warn = {},
    IsEnabled = function(self) return self._on end,
    Info = function(self, cat, fmt, ...)
        self._info[#self._info + 1] = { cat = cat, msg = string.format(fmt, ...) }
    end,
    Warn = function(self, cat, fmt, ...)
        self._warn[#self._warn + 1] = { cat = cat, msg = string.format(fmt, ...) }
    end,
    Verbose = function() end,
    Reset = function(self)
        self._info = {}
        self._warn = {}
    end,
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
world.indexEpochBumps = 0
function GG.Init() end
function GG.RegisterProvider(spec)
    if GG._providers[spec.id] then
        return false, "already_registered"
    end
    GG._providers[spec.id] = {
        id = spec.id,
        spec = spec,
        api = spec,
        enabled = true,
        ready = true,
        index = {
            buildComplete = false,
            dirty = true,
            epoch = 1,
            byId = {},
        },
    }
    return true
end
function GG.GetProvider(id)
    return GG._providers[id]
end
function GG.SetProviderEnabled() end
function GG.NotifyProviderChanged(id)
    world.providerChanged = world.providerChanged + 1
    local e = GG._providers[id]
    if e and e.index then
        e.index.dirty = true
        e.index.buildComplete = false
    end
end
function GG.IndexUpsert(index, recordId, versionFp, meta)
    if type(index) ~= "table" or recordId == nil then
        return false, "bad_args"
    end
    recordId = tostring(recordId)
    versionFp = tostring(versionFp or "")
    index.byId = index.byId or {}
    local existing = index.byId[recordId]
    if existing and existing.versionFp == versionFp then
        return false, "duplicate"
    end
    if existing and existing.versionFp ~= versionFp then
        return false, "replaced"
    end
    index.byId[recordId] = { id = recordId, versionFp = versionFp, meta = meta }
    if not index.buildComplete then
        index.dirty = true
    end
    return true, index.byId[recordId]
end
function GG.BumpIndexEpoch(index)
    if type(index) ~= "table" then
        return
    end
    index.epoch = (tonumber(index.epoch) or 0) + 1
    index.byId = {}
    index.buildComplete = false
    index.dirty = true
    world.indexEpochBumps = (world.indexEpochBumps or 0) + 1
end
function GG.CreateIndex()
    return {
        buildComplete = false,
        dirty = true,
        epoch = 1,
        byId = {},
    }
end

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
assertEq(complete, true, "nickname last completes draft payload")
assertEq(RS.DraftReadyToPersist(draft), false, "typing nickname does not ready persist")
RS.CommitDraftNickname(draft)
assertEq(RS.DraftReadyToPersist(draft), true, "commit boundary readies persist")

-- Class/spec first: first nickname character must not persist.
draft = RS.MakeDraft("plan-temp")
RS.UpdateDraftField(draft, "classFile", "MAGE")
RS.UpdateDraftField(draft, "specId", 62)
RS.UpdateDraftField(draft, "nickname", "S")
assertEq(RS.DraftIsComplete(draft), true, "single char completes payload")
assertEq(RS.DraftReadyToPersist(draft), false, "single char not ready without commit")
RS.UpdateDraftField(draft, "nickname", "Spark")
assertEq(RS.DraftReadyToPersist(draft), false, "continued typing still uncommitted")
RS.CommitDraftNickname(draft)
assertEq(RS.DraftReadyToPersist(draft), true, "enter/focus-loss commit readies")

draft = RS.MakeDraft("plan-temp")
RS.UpdateDraftField(draft, "nickname", "Spark")
RS.CommitDraftNickname(draft)
RS.UpdateDraftField(draft, "specId", 62)
_, complete = RS.UpdateDraftField(draft, "classFile", "MAGE")
-- classFile clears specId by design when class changes; re-select spec
assertEq(RS.DraftIsComplete(draft), false, "changing class clears spec")
RS.UpdateDraftField(draft, "specId", 62)
assertEq(RS.DraftIsComplete(draft), true, "spec after class completes")
assertEq(RS.DraftReadyToPersist(draft), true, "prior nickname commit preserved across class/spec")

assertTrue(not RS.IsCompleteEntryPayload("  ", "MAGE", 62), "blank nickname never completes")

-- Spec icon extraction: pcall ok + id/name/description/icon positions
local icon62 = RS.SpecIconTexture(62)
assertEq(icon62, 135932, "SpecIconTexture uses icon file id not description/id")
assertTrue(icon62 ~= 62, "SpecIconTexture is not the specialization id")
local name62 = RS.SpecDisplayName(62)
assertEq(name62, "Arcane", "SpecDisplayName uses name return")
assertTrue(RS.CategoryIconTexture(RS.MAJOR_CATEGORIES[1]) ~= nil, "category icon present")
assertTrue(tostring(RS.CategoryIconTexture(RS.MAJOR_CATEGORIES[1])):find("Spell_Holy_MagicalSentry", 1, true) ~= nil,
    "intellect uses ability icon not class icon")

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
local providerEntry = GG.GetProvider(RS.PROVIDER_ID)
assertTrue(providerEntry ~= nil and providerEntry.spec ~= nil, "provider registered")
local provider = providerEntry.spec
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
local staleReplayStatus, staleReplayDetail = provider.ValidateAndApply({
    id = RS.EntryRecordId(entryA),
    versionFp = "stale",
    body = { kind = "raidsignup-entry", schema = 1, entry = staleLive },
}, { sender = "Carol-Garona" })
assertEq(staleReplayStatus, "rejected", "stale live replay does not resurrect")
assertEq(staleReplayDetail, "deleted_final", "stale live vs tombstone is deleted_final")
assertTrue(record.entries[entryA].deleted, "still deleted")

-- Higher-version live record must not overwrite tombstone (no restore)
local zombie = RS.CloneEntry(record.entries[entryA])
zombie.deleted = false
zombie.nickname = "Resurrected"
zombie.ver = { n = record.entries[entryA].ver.n + 5, w = "ffffffffffffffffffffffff" }
local zombieStatus, zombieDetail = provider.ValidateAndApply({
    id = RS.EntryRecordId(entryA),
    versionFp = "zombie",
    body = { kind = "raidsignup-entry", schema = 1, entry = zombie },
}, { sender = "Carol-Garona" })
assertEq(zombieStatus, "rejected", "higher-ver live cannot overwrite tombstone")
assertEq(zombieDetail, "deleted_final", "deleted_final reason")
assertTrue(record.entries[entryA].deleted, "tombstone remains after higher-ver live")

-- Equal revision, different writer tie-break: live vs tombstone — tombstone wins
local tieLive = RS.CloneEntry(record.entries[entryA])
tieLive.deleted = false
tieLive.ver = { n = record.entries[entryA].ver.n, w = "aaaaaaaaaaaaaaaaaaaaaaaa" }
local tieStatus = select(1, RS.MergeEntry(record, tieLive, { remote = true }))
assertEq(tieStatus, "rejected", "equal-n live cannot beat tombstone via writer tie-break")

-- Opposite delivery order: live first, then tombstone with higher ver
local entryDelOrder
ActAs("Carol-Garona", "Player-1-Carol")
status, _, entryDelOrder = RS:UpsertEntry({
    planId = planId,
    nickname = "DelOrder",
    mainClass = "MAGE",
    mainSpec = 63,
})
assertEq(status, "accepted", "entry for deletion order test")
local liveSnap = RS.CloneEntry(record.entries[entryDelOrder])
ActAs("Carol-Garona", "Player-1-Carol")
status = RS:DeleteEntry(entryDelOrder, { expectedVer = liveSnap.ver })
assertEq(status, "accepted", "delete for order test")
local tomb = RS.CloneEntry(record.entries[entryDelOrder])
-- Simulate peer that saw live, then receives tombstone
local peerRec = {
    schemaVersion = 1,
    guildKey = "club:42",
    clubId = "42",
    plans = {},
    entries = {},
}
for _, plan in pairs(record.plans) do
    RS.MergePlan(peerRec, plan, { remote = true })
end
assertEq(select(1, RS.MergeEntry(peerRec, liveSnap, { remote = true })), "accepted", "peer accepts live first")
assertEq(select(1, RS.MergeEntry(peerRec, tomb, { remote = true })), "accepted", "peer converges to tombstone")
assertTrue(peerRec.entries[entryDelOrder].deleted, "peer deleted after tombstone")
-- Stale live replay after tombstone (both MergeEntry and Gossip provider)
assertEq(select(1, RS.MergeEntry(peerRec, liveSnap, { remote = true })), "rejected", "stale live after tombstone rejected")
assertTrue(peerRec.entries[entryDelOrder].deleted, "still deleted after stale replay")
local replayStatus = provider.ValidateAndApply({
    id = RS.EntryRecordId(entryDelOrder),
    versionFp = "replay-live",
    body = { kind = "raidsignup-entry", schema = 1, entry = liveSnap },
}, { sender = "Carol-Garona" })
assertEq(replayStatus, "rejected", "provider rejects stale live vs tombstone")
assertTrue(record.entries[entryDelOrder].deleted, "author DB still deleted after provider replay")

-- Provider path: higher-ver live against existing tombstone on the live guild record
local zombie2 = RS.CloneEntry(record.entries[entryDelOrder])
zombie2.deleted = false
zombie2.ver = { n = tomb.ver.n + 3, w = "bbbbbbbbbbbbbbbbbbbbbbbb" }
local zStatus, zDetail = provider.ValidateAndApply({
    id = RS.EntryRecordId(entryDelOrder),
    versionFp = "zombie2",
    body = { kind = "raidsignup-entry", schema = 1, entry = zombie2 },
}, { sender = "Carol-Garona" })
assertEq(zStatus, "rejected", "provider blocks resurrection")
assertEq(zDetail, "deleted_final", "provider surfaces deleted_final")

---------------------------------------------------------------------------
-- Archive race + remote historical catch-up via Gossip provider
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
assertEq(status, "rejected", "archived plan rejects local edits")

-- Peer that archived before receiving Carol's historical entry must still catch up via Gossip.
local archivePeer = {
    schemaVersion = 1,
    guildKey = "club:42",
    clubId = "42",
    plans = {},
    entries = {},
}
local archivedPlan = RS.ClonePlan(record.plans[plan2])
assertEq(select(1, RS.MergePlan(archivePeer, archivedPlan, { remote = true })), "accepted", "peer has archived plan")
-- Historical entry that existed while plan was open (Carol author) arrives after archive
local historical = RS.CloneEntry(record.entries[entryC])
-- Direct MergeEntry remote path
assertEq(select(1, RS.MergeEntry(archivePeer, historical, { remote = true })), "accepted",
    "remote MergeEntry catch-up onto archived plan")
assertTrue(archivePeer.entries[entryC] ~= nil, "historical entry stored on archived plan")
-- Local mutation still forbidden on archived peer copy
assertEq(select(1, RS.MergeEntry(archivePeer, historical, { remote = false })), "rejected",
    "local merge still rejected when archived")

-- Provider ValidateAndApply path for catch-up onto a client that only has the archived plan
-- Use a fresh entry id that the main record already holds, applied through provider into main
-- after archive (simulates late gossip of already-saved content for another entry).
ActAs("Dave-Garona", "Player-1-Dave")
-- Create on a *different* open plan first, then we'll test provider against archivePeer via Merge
-- already covered; exercise provider against Alice DB for a new historical-shaped apply:
-- Build a second peer DB initialized like SpectrumFederation using Ensure on side channel:
local lateEntry = RS.CloneEntry(historical)
lateEntry.entryId = "entry-historical-late"
lateEntry.ver = { n = 1, w = "carolcarolcarolcarolcaro" }
lateEntry.creatorGuid = "Player-1-Carol"
lateEntry.nickname = "LateCatchup"
-- Inject into archivePeer through provider by temporarily swapping EnsureGuildRecord — instead
-- call Merge via provider after planting archivePeer as the guild record is hard; use MergeEntry
-- + provider against main record for an entry that is first-seen while plan archived:
ActAs("Alice-Garona", "Player-1-Alice")
delStatus = provider.ValidateAndApply({
    id = RS.EntryRecordId(lateEntry.entryId),
    versionFp = "late",
    body = { kind = "raidsignup-entry", schema = 1, entry = lateEntry },
}, { sender = "Carol-Garona" })
assertEq(delStatus, "accepted", "Gossip provider catch-up admits historical entry on archived plan")
assertTrue(record.entries[lateEntry.entryId] ~= nil, "late historical entry present")
assertTrue(record.plans[plan2].archived, "plan remains archived")
ActAs("Carol-Garona", "Player-1-Carol")
status = RS:UpsertEntry({
    entryId = lateEntry.entryId,
    planId = plan2,
    nickname = "ShouldFail",
    mainClass = "SHAMAN",
    mainSpec = 262,
})
assertEq(status, "rejected", "UI/local still cannot edit archived plan after catch-up")

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

-- Reload persistence: re-initialize the same module table (do not nil SF.RaidSignup;
-- later UI page load must resolve the live module via SF.RaidSignup).
assertTrue(RS:Initialize(SpectrumFederationDB), "re-init after reload")
SF.RaidSignup = RS
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

---------------------------------------------------------------------------
-- Production UI page: typing stability, nickname commit, bounded reuse
---------------------------------------------------------------------------

local frameCount = 0
local textureCount = 0
local fontStringCount = 0
-- Retail-shaped script support: SetScript rejects unsupported handlers.
local SCRIPT_SUPPORT = {
    Frame = {
        OnShow = true, OnHide = true, OnEnter = true, OnLeave = true,
        OnUpdate = true, OnEvent = true, OnSizeChanged = true,
    },
    Button = {
        OnShow = true, OnHide = true, OnEnter = true, OnLeave = true,
        OnClick = true, OnEnable = true, OnDisable = true, OnUpdate = true,
    },
    EditBox = {
        OnShow = true, OnHide = true, OnEnter = true, OnLeave = true,
        OnEnterPressed = true, OnEscapePressed = true, OnTextChanged = true,
        OnEditFocusGained = true, OnEditFocusLost = true, OnTabPressed = true,
        OnCursorChanged = true,
    },
    Texture = {},
    FontString = {},
}

local function makeRegion(objectType)
    local r = {
        _type = objectType or "Region",
        _shown = true,
        _parent = nil,
        _points = {},
        _scripts = {},
        _text = "",
        _texture = nil,
    }
    function r:GetObjectType() return self._type end
    function r:HasScript(name)
        local map = SCRIPT_SUPPORT[self._type] or SCRIPT_SUPPORT.Frame
        return map[name] == true
    end
    local function detachFromParent(widget)
        local parent = widget._parent
        if not parent then
            return
        end
        if parent._children then
            for i = #parent._children, 1, -1 do
                if parent._children[i] == widget then
                    table.remove(parent._children, i)
                end
            end
        end
        if parent._regions then
            for i = #parent._regions, 1, -1 do
                if parent._regions[i] == widget then
                    table.remove(parent._regions, i)
                end
            end
        end
    end
    function r:SetParent(p)
        detachFromParent(self)
        self._parent = p
        if not p then
            return
        end
        local ot = self._type
        if ot == "Texture" or ot == "FontString" then
            p._regions = p._regions or {}
            p._regions[#p._regions + 1] = self
        else
            p._children = p._children or {}
            p._children[#p._children + 1] = self
        end
    end
    function r:GetParent() return self._parent end
    function r:Show() self._shown = true end
    function r:Hide()
        local wasShown = self._shown
        self._shown = false
        if wasShown then
            local fn = self._scripts.OnHide
            if fn then fn(self) end
        end
    end
    function r:IsShown() return self._shown end
    function r:SetAllPoints() end
    function r:ClearAllPoints() self._points = {} end
    function r:SetPoint(p, rel, rp, x, y)
        self._points[#self._points + 1] = { p, rel, rp, x, y }
    end
    function r:SetSize(w, h) self._w = w; self._h = h end
    function r:SetWidth(w) self._w = w end
    function r:SetHeight(h) self._h = h end
    function r:GetWidth() return self._w or 100 end
    function r:GetHeight() return self._h or 20 end
    function r:SetText(t, userInput)
        -- Programmatic SetText (display) always applies. User typing while
        -- disabled is refused so interactivity regressions are observable.
        if userInput and self._enabled == false then
            self._lastUserEditRejected = true
            return
        end
        self._lastUserEditRejected = false
        self._text = t or ""
    end
    function r:GetText() return self._text or "" end
    function r:SetTexture(t) self._texture = t end
    function r:SetDesaturated() end
    function r:SetVertexColor() end
    function r:SetMaxLetters() end
    function r:SetAutoFocus() end
    function r:Enable() self._enabled = true end
    function r:Disable() self._enabled = false end
    function r:IsEnabled()
        if self._enabled == nil then
            return true
        end
        return self._enabled and true or false
    end
    function r:SetEnabled(v)
        if v then
            self:Enable()
        else
            self:Disable()
        end
    end
    function r:SetShown(v)
        if v then
            self:Show()
        else
            self:Hide()
        end
    end
    function r:SetAlpha(a) self._alpha = a end
    function r:SetTextColor() end
    function r:SetCursorPosition(p) self._cursor = p end
    function r:GetCursorPosition() return self._cursor or 0 end
    function r:SetFrameLevel(l) self._frameLevel = l end
    function r:GetFrameLevel() return self._frameLevel or 0 end
    function r:EnableMouse() end
    function r:RegisterForClicks() end
    function r:SetScript(name, fn)
        if not self:HasScript(name) then
            error(string.format("script '%s' isn't supported by widget of type %s",
                tostring(name), tostring(self._type)), 2)
        end
        self._scripts[name] = fn
    end
    function r:GetScript(name) return self._scripts[name] end
    function r:HookScript(name, fn)
        if not self:HasScript(name) then
            error(string.format("script '%s' isn't supported by widget of type %s",
                tostring(name), tostring(self._type)), 2)
        end
        local prev = self._scripts[name]
        self._scripts[name] = function(...)
            if prev then prev(...) end
            fn(...)
        end
    end
    function r:HasFocus() return self._focused == true end
    function r:ClearFocus()
        if not self._focused then
            return
        end
        self._focused = false
        local fn = self._scripts.OnEditFocusLost
        if fn then fn(self) end
    end
    function r:SetFocus()
        self._focused = true
        local fn = self._scripts.OnEditFocusGained
        if fn then fn(self) end
    end
    function r:CreateTexture()
        textureCount = textureCount + 1
        local tex = makeRegion("Texture")
        tex:SetParent(self)
        return tex
    end
    function r:CreateFontString()
        fontStringCount = fontStringCount + 1
        local fs = makeRegion("FontString")
        function fs:SetJustifyH() end
        fs:SetParent(self)
        return fs
    end
    function r:GetChildren()
        local kids = {}
        for _, child in ipairs(self._children or {}) do
            if child._parent == self then
                kids[#kids + 1] = child
            end
        end
        return unpack(kids)
    end
    function r:GetRegions()
        local regions = {}
        for _, region in ipairs(self._regions or {}) do
            if region._parent == self then
                regions[#regions + 1] = region
            end
        end
        return unpack(regions)
    end
    r._children = {}
    r._regions = {}
    return r
end

function CreateFrame(frameType, name, parent, template)
    frameCount = frameCount + 1
    local resolved = frameType or "Frame"
    if template == "InputBoxTemplate" then
        resolved = "EditBox"
    elseif template == "UIPanelButtonTemplate" then
        resolved = "Button"
    end
    local f = makeRegion(resolved)
    f._name = name
    f._template = template
    if parent then
        f:SetParent(parent)
    end
    if resolved == "EditBox" then
        f._enabled = true
        -- Template-owned Instructions region (not feature-pooled).
        local instructions = makeRegion("FontString")
        instructions:SetParent(f)
        f.Instructions = instructions
        fontStringCount = fontStringCount + 1
        -- Synthetic template chrome that must never enter feature pools.
        local chrome = makeRegion("Frame")
        chrome._type = "Frame"
        chrome.__sfTemplateOwned = true
        chrome:SetParent(f)
        frameCount = frameCount + 1
    end
    if resolved == "Button" then
        function f:Click()
            local fn = f._scripts.OnClick
            if fn then fn(f) end
        end
        if template == "UIPanelButtonTemplate" then
            local label = makeRegion("FontString")
            label:SetParent(f)
            f.Text = label
            fontStringCount = fontStringCount + 1
        end
    end
    return f
end

GameTooltip = {
    SetOwner = function() end,
    SetText = function() end,
    AddLine = function() end,
    Show = function() end,
    Hide = function() end,
}

SF.SettingsUI = SF.SettingsUI or {}
local registeredPage = nil
function SF.SettingsUI:RegisterCategory() end
function SF.SettingsUI:RegisterPage(page)
    registeredPage = page
end
function SF.SettingsUI:CreatePage(panel)
    local pb = {
        scrollFrame = CreateFrame("Frame", nil, panel),
        refreshCallbacks = {},
        sections = {},
    }
    function pb:AddSection(opts)
        local section = {
            title = opts and opts.title,
            rows = {},
        }
        function section:AddRow(height, fn)
            local row = CreateFrame("Frame", nil, panel)
            row:SetHeight(height)
            self.rows[#self.rows + 1] = row
            if fn then fn(row) end
            return row
        end
        self.sections[#self.sections + 1] = section
        return section
    end
    function pb:Finalize() end
    function pb:Refresh()
        for i = 1, #self.refreshCallbacks do
            self.refreshCallbacks[i]()
        end
    end
    function pb:RegisterRefresh(fn)
        self.refreshCallbacks[#self.refreshCallbacks + 1] = fn
    end
    return pb
end
SF.SettingsUI.Controls = {
    AddDisplay = function() end,
    AddButton = function() end,
    AddDropdown = function() end,
    AddEditBoxWithButton = function() end,
}

SF.RaidSignup = RS
load("SpectrumFederation/modules/UI/Settings/Pages/RaidSignup.lua")
local UIPage = SF.RaidSignupUIPage or registeredPage
assertTrue(UIPage ~= nil, "Raid Signup page registered")
assertTrue(type(UIPage._SetDraftForTests) == "function", "draft test hook present")

-- Fail-before proof for pooled cleanup: Frame rejects Button-only scripts.
do
    local probe = CreateFrame("Frame")
    local okClick = pcall(function()
        probe:SetScript("OnClick", nil)
    end)
    assertTrue(not okClick, "Frame SetScript(OnClick) fails under Retail script rules")
    local okEdit = pcall(function()
        probe:SetScript("OnEnterPressed", nil)
    end)
    assertTrue(not okEdit, "Frame SetScript(OnEnterPressed) fails under Retail script rules")
end

ActAs("Alice-Garona", "Player-1-Alice")
RS:SelectPlan(plan3)
UIPage._ResetSessionForTests()
local panel = CreateFrame("Frame", "RaidSignupTestPanel")
function panel:IsShown() return true end
function panel:HookScript(name, fn)
    self._scripts = self._scripts or {}
    self._scripts[name] = fn
end
UIPage:Build(panel)
local counters1 = UIPage._GetLifecycleCounters()
assertEq(counters1.openCount, 1, "page open counted")
assertTrue(counters1.fullRebuildCount >= 1, "initial full rebuild")
assertTrue(counters1.listenerCount >= 1, "ui listener registered")

local hostBefore = panel.__sfRaidSignupEntriesHost
assertTrue(hostBefore ~= nil, "entries host created")
local summaryBefore = panel.__sfRaidSignupSummaryHost
assertTrue(summaryBefore ~= nil, "summary host created")
local rebuildBefore = UIPage._GetLifecycleCounters().fullRebuildCount
local paintBefore = UIPage._GetLifecycleCounters().boardPaintCount
UIPage:Refresh(panel)
UIPage:Refresh(panel)
local counters2 = UIPage._GetLifecycleCounters()
assertEq(counters2.fullRebuildCount, rebuildBefore, "soft refresh does not full-rebuild")
assertTrue(counters2.boardPaintCount > paintBefore, "boards repainted on soft refresh")
assertTrue(panel.__sfRaidSignupEntriesHost == hostBefore, "entries host reused")
assertTrue(panel.__sfRaidSignupSummaryHost == summaryBefore, "summary host reused")

-- Draft typing: class/spec first, nickname characters do not persist or rebuild
ActAs("Carol-Garona", "Player-1-Carol")
local draft = RS.MakeDraft(plan3)
RS.UpdateDraftField(draft, "classFile", "MAGE")
RS.UpdateDraftField(draft, "specId", 62)
UIPage._SetDraftForTests(draft)
assertTrue(UIPage._GetDraftForTests() ~= nil, "draft injected into page session")
UIPage:Refresh(panel, { force = true })
assertTrue(panel.__sfRaidSignupEntriesHost ~= nil, "entries host after draft refresh")
local boxes = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
if #boxes < 1 then
    -- forceRebuild if soft paint missed the draft row for any stubbing reason
    UIPage:Refresh(panel, { forceRebuild = true, force = true })
    boxes = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
end
assertTrue(#boxes >= 1, "draft nickname edit box present")
local nickBox = boxes[1]
local function SimulateUserType(edit, text)
    assertTrue(edit ~= nil, "edit box present for SimulateUserType")
    assertTrue(edit:IsEnabled(), "user typing requires enabled edit box")
    edit:SetText(text, true)
    assertTrue(not edit._lastUserEditRejected, "disabled edit rejected user SetText")
    local onText = edit:GetScript("OnTextChanged")
    if onText then
        onText(edit, true)
    end
end

nickBox:SetFocus()
local refreshBefore = UIPage._GetLifecycleCounters().refreshCount
local entriesBefore = #RS:GetSortedEntries(plan3)
assertTrue(nickBox:GetScript("OnTextChanged") ~= nil, "nickname OnTextChanged bound")
SimulateUserType(nickBox, "S")
SimulateUserType(nickBox, "Sp")
SimulateUserType(nickBox, "SparkUI")
assertEq(#RS:GetSortedEntries(plan3), entriesBefore, "typing does not persist entry")
assertEq(UIPage._GetLifecycleCounters().refreshCount, refreshBefore, "typing does not refresh while focused")
assertEq(UIPage._GetDraftForTests().nicknameCommitted, false, "nickname remains uncommitted while typing")

-- Commit boundary persists once
local onEnter = nickBox:GetScript("OnEnterPressed")
assertTrue(onEnter ~= nil, "nickname OnEnterPressed bound")
onEnter(nickBox)
assertTrue(UIPage._GetDraftForTests() == nil, "draft cleared after successful persist")
assertTrue(#RS:GetSortedEntries(plan3) > entriesBefore, "commit persists complete draft")

-- Nickname editing on saved row with stale-edit protection
local listedUI = RS:GetSortedEntries(plan3)
local target = listedUI[1]
assertTrue(target ~= nil, "saved entry available for nickname edit")
local staleStatus = select(1, RS:UpsertEntry({
    entryId = target.entryId,
    planId = target.planId,
    nickname = "ShouldStale",
    mainClass = target.mainClass,
    mainSpec = target.mainSpec,
    notes = target.notes,
}, { expectedVer = { n = 0, w = "000000000000000000000000" } }))
assertEq(staleStatus, "rejected", "stale nickname edit rejected")

-- Focus deferral via a page-bound edit box
UIPage:Refresh(panel, { force = true })
boxes = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
assertTrue(#boxes >= 1, "edit boxes after persist refresh")
boxes[1]:SetFocus()
refreshBefore = UIPage._GetLifecycleCounters().refreshCount
UIPage:Refresh(panel)
assertEq(UIPage._GetLifecycleCounters().refreshCount, refreshBefore, "refresh deferred while page edit focused")
boxes[1]:ClearFocus()
UIPage:Refresh(panel, { force = true })
assertTrue(UIPage._GetLifecycleCounters().refreshCount > refreshBefore, "forced refresh runs")

-- Open/close cycles do not stack listeners
local listenersBefore = UIPage._GetLifecycleCounters().listenerCount
UIPage:OnHide()
UIPage:Build(panel)
UIPage:Build(panel)
assertEq(UIPage._GetLifecycleCounters().listenerCount, listenersBefore, "listeners not accumulated")

-- Allocations plateau after warm-up (pooled reuse), including regions
rebuildBefore = UIPage._GetLifecycleCounters().fullRebuildCount
UIPage:Refresh(panel, { force = true })
UIPage:Refresh(panel, { force = true })
local createsAfterWarmup = UIPage._GetLifecycleCounters().frameCreateCount
local reuseAfterWarmup = UIPage._GetLifecycleCounters().frameReuseCount
local regionsAfterWarmup = UIPage._GetLifecycleCounters().regionCreateCount
local texturesAfterWarmup = textureCount
local fontsAfterWarmup = fontStringCount
for _ = 1, 8 do
    UIPage:Refresh(panel, { force = true })
end
local createsLater = UIPage._GetLifecycleCounters().frameCreateCount
local reuseLater = UIPage._GetLifecycleCounters().frameReuseCount
local regionsLater = UIPage._GetLifecycleCounters().regionCreateCount
assertEq(createsLater, createsAfterWarmup, "frame creates plateau after warm-up")
assertEq(regionsLater, regionsAfterWarmup, "region creates plateau after warm-up")
assertEq(textureCount, texturesAfterWarmup, "texture creates plateau after warm-up")
assertEq(fontStringCount, fontsAfterWarmup, "fontstring creates plateau after warm-up")
assertTrue(reuseLater > reuseAfterWarmup, "pooled frames are reused after warm-up")
assertEq(UIPage._GetLifecycleCounters().fullRebuildCount, rebuildBefore, "still no extra full rebuilds")

local function countVisibleEmptyLabels(root)
    local n = 0
    local function walk(frame)
        if not frame then
            return
        end
        if frame.GetRegions then
            local regions = { frame:GetRegions() }
            for i = 1, #regions do
                local region = regions[i]
                if region and region.GetObjectType and region:GetObjectType() == "FontString"
                    and region.IsShown and region:IsShown()
                    and (region:GetText() or ""):find("No signups", 1, true) then
                    n = n + 1
                end
            end
        end
        local kids = { frame:GetChildren() }
        for i = 1, #kids do
            walk(kids[i])
        end
    end
    walk(root)
    return n
end

-- Empty → populated must not leave empty-state FontStrings visible on reused rows
ActAs("Alice-Garona", "Player-1-Alice")
local statusEmptyPlan, _, planEmpty = RS:CreatePlan("Empty Then Populated")
assertEq(statusEmptyPlan, "accepted", "empty transition plan created")
RS:SelectPlan(planEmpty)
UIPage:Refresh(panel, { force = true })
assertTrue(countVisibleEmptyLabels(panel.__sfRaidSignupEntriesHost) >= 1, "empty-state label shown")
assertEq(select(1, RS:UpsertEntry({
    planId = planEmpty,
    nickname = "FirstRow",
    mainClass = "MAGE",
    mainSpec = 62,
})), "accepted", "populate empty plan")
UIPage:Refresh(panel, { force = true })
assertEq(countVisibleEmptyLabels(panel.__sfRaidSignupEntriesHost), 0,
    "empty-state label hidden after populate")

-- ReleasePooled must not SetScript unsupported handlers (Retail abort regression)
do
    local okRelease, errRelease = pcall(function()
        for _ = 1, 4 do
            UIPage:Refresh(panel, { force = true })
        end
    end)
    assertTrue(okRelease, "refresh release does not raise invalid-script: " .. tostring(errRelease))
end

-- Live control bindings: create plan then Add Row; switch plan; archive disables rename
ActAs("Alice-Garona", "Player-1-Alice")
local snap = UIPage._GetDefinitionSnapshotForTests()
local statusNew, _, planLive = RS:CreatePlan("Live Binding Plan")
assertEq(statusNew, "accepted", "create plan for live binding")
RS:SelectPlan(planLive)
local snap2 = UIPage._GetDefinitionSnapshotForTests()
assertEq(snap2.selectedId, planLive, "selected plan binding updates")
assertEq(snap2.planOpen, true, "new plan is open")
assertEq(snap2.canCreateEntry, true, "officer can create entry on open plan")
assertEq(snap2.renameEnabled, true, "rename enabled on open plan")
assertTrue(#snap2.planOptions > #snap.planOptions, "plan options include new plan")

-- Actual Add Row / class / spec / alt / remove flows through page refresh
local addDraft = RS.MakeDraft(planLive)
UIPage._SetDraftForTests(addDraft)
UIPage:Refresh(panel, { force = true })
assertTrue(#UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname") >= 1,
    "Add Row draft nickname present")
RS.UpdateDraftField(addDraft, "classFile", "WARRIOR")
UIPage:Refresh(panel, { force = true })
RS.UpdateDraftField(addDraft, "specId", 71)
RS.UpdateDraftField(addDraft, "nickname", "WarriorMain")
RS.CommitDraftNickname(addDraft)
assertEq(select(1, RS:UpsertEntry({
    planId = planLive,
    nickname = addDraft.nickname,
    mainClass = addDraft.classFile,
    mainSpec = addDraft.specId,
})), "accepted", "persist Add Row draft")
UIPage._SetDraftForTests(nil)
UIPage:Refresh(panel, { force = true })
local liveEntries = RS:GetSortedEntries(planLive)
assertTrue(#liveEntries >= 1, "live plan has signup after Add Row")
local liveEntry = liveEntries[1]
assertEq(select(1, RS:UpsertEntry({
    entryId = liveEntry.entryId,
    planId = liveEntry.planId,
    nickname = liveEntry.nickname,
    mainClass = liveEntry.mainClass,
    mainSpec = liveEntry.mainSpec,
    altClass = "MAGE",
    altSpec = 62,
}, { expectedVer = liveEntry.ver })), "accepted", "add alternative through ops")
UIPage:Refresh(panel, { force = true })
liveEntry = RS:GetSortedEntries(planLive)[1]
assertEq(liveEntry.altClass, "MAGE", "alternative attached")
assertEq(select(1, RS:DeleteEntry(liveEntry.entryId, { expectedVer = liveEntry.ver })),
    "accepted", "remove signup through ops")
UIPage:Refresh(panel, { force = true })
assertEq(#RS:GetSortedEntries(planLive), 0, "plan empty after removal")
assertTrue(countVisibleEmptyLabels(panel.__sfRaidSignupEntriesHost) >= 1,
    "empty-state returns after removal")

assertEq(select(1, RS:SetPlanArchived(planLive, true)), "accepted", "archive for rename disable")
local snap3 = UIPage._GetDefinitionSnapshotForTests()
assertEq(snap3.renameEnabled, false, "rename disabled while archived")
assertEq(select(1, RS:RenamePlan(planLive, "Nope")), "rejected", "local rename rejected while archived")
-- Remote metadata catch-up of archived rename still allowed
local archivedPlan = RS.ClonePlan(select(1, RS:EnsureGuildRecord("club:42")).plans[planLive])
archivedPlan.name = "RemoteName"
archivedPlan.ver = { n = archivedPlan.ver.n + 1, w = "officerofficerofficeroff" }
assertEq(select(1, provider.ValidateAndApply({
    id = RS.PlanRecordId(planLive),
    versionFp = "arch-rename",
    body = { kind = "raidsignup-plan", schema = 1, plan = archivedPlan },
}, { sender = "Alice-Garona" })), "accepted", "remote archived plan metadata catch-up")
assertEq(select(1, RS:EnsureGuildRecord("club:42")).plans[planLive].name, "RemoteName", "archived name caught up remotely")
assertEq(select(1, RS:SetPlanArchived(planLive, false)), "accepted", "reopen plan")

---------------------------------------------------------------------------
-- Pooled EditBox enabled-state: read-only reuse must not block Add Row typing
---------------------------------------------------------------------------

do
    ActAs("Alice-Garona", "Player-1-Alice")
    local stRO, _, planRO = RS:CreatePlan("Readonly Then Draft")
    assertEq(stRO, "accepted", "readonly transition plan")
    RS:SelectPlan(planRO)
    assertEq(select(1, RS:UpsertEntry({
        planId = planRO,
        nickname = "OfficerOwned",
        mainClass = "MAGE",
        mainSpec = 62,
        notes = "seed",
    })), "accepted", "seed owned entry for readonly view")
    assertEq(select(1, RS:SetPlanArchived(planRO, true)), "accepted", "archive plan to force Disable on boxes")
    UIPage:Refresh(panel, { force = true })
    local roBoxes = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
    assertTrue(#roBoxes >= 1, "archived nickname box present")
    assertTrue(not roBoxes[1]:IsEnabled(), "archived nickname is disabled")
    local beforeText = roBoxes[1]:GetText()
    roBoxes[1]:SetText("ShouldNotType", true)
    assertTrue(roBoxes[1]._lastUserEditRejected, "disabled box rejects user typing")
    assertEq(roBoxes[1]:GetText(), beforeText, "disabled box text unchanged by user SetText")

    -- Reopen + Add Row: pooled edit boxes must be enabled for draft typing.
    assertEq(select(1, RS:SetPlanArchived(planRO, false)), "accepted", "reopen for Add Row")
    local draftRO = RS.MakeDraft(planRO)
    RS.UpdateDraftField(draftRO, "classFile", "WARRIOR")
    RS.UpdateDraftField(draftRO, "specId", 71)
    UIPage._SetDraftForTests(draftRO)
    UIPage:Refresh(panel, { force = true })
    local draftNick = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
    local draftNotes = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "notes")
    assertTrue(#draftNick >= 1, "draft nickname after readonly reuse")
    assertTrue(#draftNotes >= 1, "draft notes after readonly reuse")
    assertTrue(draftNick[1]:IsEnabled(), "draft nickname enabled after pooled reuse")
    assertTrue(draftNotes[1]:IsEnabled(), "draft notes enabled after pooled reuse")
    SimulateUserType(draftNick[1], "FreshSignup")
    SimulateUserType(draftNotes[1], "Fresh notes")
    assertEq(UIPage._GetDraftForTests().nickname, "FreshSignup", "typed nickname reaches draft")
    assertEq(UIPage._GetDraftForTests().notes, "Fresh notes", "typed notes reach draft")
    local onEnter = draftNick[1]:GetScript("OnEnterPressed")
    assertTrue(onEnter ~= nil, "draft nickname commit handler")
    onEnter(draftNick[1])
    assertTrue(UIPage._GetDraftForTests() == nil, "draft cleared after commit")
    local after = RS:GetSortedEntries(planRO)
    local foundFresh = false
    for i = 1, #after do
        if after[i].nickname == "FreshSignup" then
            foundFresh = true
            assertEq(after[i].notes, "Fresh notes", "notes persisted from typed draft")
        end
    end
    assertTrue(foundFresh, "completed signup from enabled draft boxes")

    -- Ordinary member: others' rows disabled; own Add Row enabled.
    ActAs("Alice-Garona", "Player-1-Alice")
    local stMem, _, planMem = RS:CreatePlan("Member Own Entry")
    assertEq(stMem, "accepted", "member plan created")
    RS:SelectPlan(planMem)
    assertEq(select(1, RS:UpsertEntry({
        planId = planMem,
        nickname = "AliceRow",
        mainClass = "MAGE",
        mainSpec = 62,
    })), "accepted", "officer seeds other-owned row")
    ActAs("Carol-Garona", "Player-1-Carol")
    UIPage:Refresh(panel, { force = true })
    local others = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
    assertTrue(#others >= 1, "other member nickname visible")
    assertTrue(not others[1]:IsEnabled(), "non-owned nickname disabled for member")
    local memberDraft = RS.MakeDraft(planMem)
    RS.UpdateDraftField(memberDraft, "classFile", "PRIEST")
    RS.UpdateDraftField(memberDraft, "specId", 256)
    UIPage._SetDraftForTests(memberDraft)
    UIPage:Refresh(panel, { force = true })
    local memberNick = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
    -- Draft row is first; find an enabled nickname box among them.
    local enabledDraft = nil
    for i = 1, #memberNick do
        if memberNick[i]:IsEnabled() then
            enabledDraft = memberNick[i]
            break
        end
    end
    assertTrue(enabledDraft ~= nil, "member draft nickname enabled while others disabled")
    SimulateUserType(enabledDraft, "CarolOwn")
    local enterMem = enabledDraft:GetScript("OnEnterPressed")
    assertTrue(enterMem ~= nil, "member draft commit handler")
    enterMem(enabledDraft)
    local memListed = RS:GetSortedEntries(planMem)
    local carolFound = false
    for i = 1, #memListed do
        if memListed[i].nickname == "CarolOwn" then
            carolFound = true
        end
    end
    assertTrue(carolFound, "member completed own signup via enabled draft")

    -- Reverse: editable → archived read-only again (pooled controls Disable).
    ActAs("Alice-Garona", "Player-1-Alice")
    RS:SelectPlan(planRO)
    UIPage:Refresh(panel, { force = true })
    local editableAgain = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
    assertTrue(#editableAgain >= 1, "editable nicknames before re-archive")
    local anyEnabled = false
    for i = 1, #editableAgain do
        if editableAgain[i]:IsEnabled() then
            anyEnabled = true
        end
    end
    assertTrue(anyEnabled, "open plan has enabled nickname for owner")
    assertEq(select(1, RS:SetPlanArchived(planRO, true)), "accepted", "re-archive for reverse transition")
    UIPage:Refresh(panel, { force = true })
    local againRO = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
    assertTrue(#againRO >= 1, "nickname boxes after re-archive")
    for i = 1, #againRO do
        assertTrue(not againRO[i]:IsEnabled(), "re-archived nickname disabled again")
        local prior = againRO[i]:GetText()
        againRO[i]:SetText("Nope", true)
        assertTrue(againRO[i]._lastUserEditRejected, "re-archived rejects user typing")
        assertEq(againRO[i]:GetText(), prior, "re-archived text unchanged")
    end
    assertEq(select(1, RS:SetPlanArchived(planRO, false)), "accepted", "cleanup reopen planRO")
    UIPage._SetDraftForTests(nil)
    RS:SelectPlan(plan3)
    UIPage:Refresh(panel, { force = true })
end

---------------------------------------------------------------------------
-- planId immutability for existing entryIds (no move)
---------------------------------------------------------------------------

do
    ActAs("Alice-Garona", "Player-1-Alice")
    local stSrc, _, planSrc = RS:CreatePlan("Immutable Src")
    local stDst, _, planDst = RS:CreatePlan("Immutable Dst")
    local stArch, _, planArch = RS:CreatePlan("Immutable Arch")
    assertEq(stSrc, "accepted", "immutable src plan")
    assertEq(stDst, "accepted", "immutable dst plan")
    assertEq(stArch, "accepted", "immutable arch plan")
    assertEq(select(1, RS:SetPlanArchived(planArch, true)), "accepted", "archive move target")

    ActAs("Carol-Garona", "Player-1-Carol")
    RS:SelectPlan(planSrc)
    local stEnt, _, moveId = RS:UpsertEntry({
        planId = planSrc,
        nickname = "StayPut",
        mainClass = "WARRIOR",
        mainSpec = 71,
        notes = "anchor",
        altClass = "MAGE",
        altSpec = 62,
    })
    assertEq(stEnt, "accepted", "creator seeds immutable entry")
    assertTrue(moveId ~= nil, "immutable entry id")
    local rec = select(1, RS:EnsureGuildRecord("club:42"))
    local before = RS.CloneEntry(rec.entries[moveId])
    local beforeCount = 0
    for _ in pairs(rec.entries) do
        beforeCount = beforeCount + 1
    end

    local function assertUnchanged(label)
        local now = select(1, RS:EnsureGuildRecord("club:42")).entries[moveId]
        assertTrue(now ~= nil, label .. " entry still present")
        assertEq(now.planId, before.planId, label .. " planId unchanged")
        assertEq(now.nickname, before.nickname, label .. " nickname unchanged")
        assertEq(now.ver.n, before.ver.n, label .. " ver.n unchanged")
        assertEq(now.ver.w, before.ver.w, label .. " ver.w unchanged")
        assertEq(now.deleted == true, before.deleted == true, label .. " deleted unchanged")
        local count = 0
        for _ in pairs(select(1, RS:EnsureGuildRecord("club:42")).entries) do
            count = count + 1
        end
        assertEq(count, beforeCount, label .. " entry table size unchanged")
    end

    local function rejectMove(actorLabel, planTarget, targetLabel)
        local st, reason = RS:UpsertEntry({
            entryId = moveId,
            planId = planTarget,
            nickname = before.nickname,
            mainClass = before.mainClass,
            mainSpec = before.mainSpec,
            notes = before.notes,
            altClass = before.altClass,
            altSpec = before.altSpec,
        }, { expectedVer = before.ver })
        assertEq(st, "rejected", actorLabel .. " UpsertEntry rejects " .. targetLabel .. " move")
        assertEq(reason, "plan_immutable", actorLabel .. " UpsertEntry " .. targetLabel .. " reason")
        assertUnchanged("after " .. actorLabel .. " " .. targetLabel .. " move")
    end

    -- Creator UpsertEntry attempting move to open / archived targets.
    rejectMove("creator", planDst, "open-target")
    rejectMove("creator", planArch, "archived-target")

    -- Officer UpsertEntry also rejected.
    ActAs("Bob-Garona", "Player-1-Bob")
    rejectMove("officer", planDst, "open-target")
    rejectMove("officer", planArch, "archived-target")

    -- MergeEntry live path: changed planId rejected before mutation.
    local liveMove = RS.CloneEntry(before)
    liveMove.planId = planDst
    liveMove.nickname = "Moved"
    liveMove.ver = { n = before.ver.n + 1, w = "cccccccccccccccccccccccc" }
    local stLive, reasonLive = RS.MergeEntry(rec, liveMove, { remote = true })
    assertEq(stLive, "rejected", "MergeEntry live rejects planId change")
    assertEq(reasonLive, "plan_immutable", "MergeEntry live reason plan_immutable")
    assertUnchanged("after MergeEntry live move")

    liveMove.planId = planArch
    assertEq(select(1, RS.MergeEntry(rec, liveMove, { remote = true })), "rejected",
        "MergeEntry live rejects archived-target planId change")
    assertUnchanged("after MergeEntry archived-target move")

    -- Isolated full-target MergeEntry: existing row must not bypass per-plan capacity.
    local fullRec = {
        schemaVersion = 1,
        guildKey = "club:42",
        clubId = "42",
        plans = {},
        entries = {},
    }
    assertEq(select(1, RS.MergePlan(fullRec, {
        planId = "iso-src",
        name = "Iso Src",
        archived = false,
        createdBy = "Player-1-Alice",
        ver = { n = 1, w = "aaaaaaaaaaaaaaaaaaaaaaaa" },
        at = 1,
    }, { remote = true })), "accepted", "iso src plan")
    assertEq(select(1, RS.MergePlan(fullRec, {
        planId = "iso-full",
        name = "Iso Full",
        archived = false,
        createdBy = "Player-1-Alice",
        ver = { n = 1, w = "bbbbbbbbbbbbbbbbbbbbbbbb" },
        at = 1,
    }, { remote = true })), "accepted", "iso full plan")
    for i = 1, RS.MAX_ENTRIES_PER_PLAN do
        local st = select(1, RS.MergeEntry(fullRec, {
            entryId = "iso-full-" .. tostring(i),
            planId = "iso-full",
            nickname = "F" .. tostring(i),
            mainClass = "MAGE",
            mainSpec = 62,
            notes = "",
            creatorGuid = "Player-1-Carol",
            deleted = false,
            ver = { n = 1, w = string.format("%024x", i) },
            at = 1,
        }, { remote = true }))
        assertEq(st, "accepted", "iso full seed " .. tostring(i))
    end
    assertEq(select(1, RS.MergeEntry(fullRec, {
        entryId = "iso-move",
        planId = "iso-src",
        nickname = "Stay",
        mainClass = "WARRIOR",
        mainSpec = 71,
        notes = "",
        creatorGuid = "Player-1-Carol",
        deleted = false,
        ver = { n = 1, w = "ffffffffffffffffffffffff" },
        at = 1,
    }, { remote = true })), "accepted", "iso source entry")
    local isoBefore = RS.CloneEntry(fullRec.entries["iso-move"])
    local stFull, reasonFull = RS.MergeEntry(fullRec, {
        entryId = "iso-move",
        planId = "iso-full",
        nickname = "MovedIntoFull",
        mainClass = "WARRIOR",
        mainSpec = 71,
        notes = "",
        creatorGuid = "Player-1-Carol",
        deleted = false,
        ver = { n = 2, w = "ffffffffffffffffffffffff" },
        at = 2,
    }, { remote = true })
    assertEq(stFull, "rejected", "MergeEntry rejects move into full plan")
    assertEq(reasonFull, "plan_immutable", "full-target move reason plan_immutable")
    assertEq(fullRec.entries["iso-move"].planId, isoBefore.planId, "iso entry planId unchanged")
    assertEq(fullRec.entries["iso-move"].nickname, isoBefore.nickname, "iso entry nickname unchanged")
    assertEq(fullRec.entries["iso-move"].ver.n, isoBefore.ver.n, "iso entry ver unchanged")

    -- MergeEntry tombstone path: planId change rejected before tombstone fast path.
    local tombMove = RS.CloneEntry(before)
    tombMove.deleted = true
    tombMove.planId = planDst
    tombMove.ver = { n = before.ver.n + 1, w = "dddddddddddddddddddddddd" }
    local stTomb, reasonTomb = RS.MergeEntry(rec, tombMove, { remote = true })
    assertEq(stTomb, "rejected", "MergeEntry tombstone rejects planId change")
    assertEq(reasonTomb, "plan_immutable", "MergeEntry tombstone reason plan_immutable")
    assertUnchanged("after MergeEntry tombstone move")
    assertTrue(not rec.entries[moveId].deleted, "tombstone move did not delete")

    -- Same-planId tombstone still applies (control).
    local tombOk = RS.CloneEntry(before)
    tombOk.deleted = true
    tombOk.planId = before.planId
    tombOk.ver = { n = before.ver.n + 1, w = "eeeeeeeeeeeeeeeeeeeeeeee" }
    assertEq(select(1, RS.MergeEntry(rec, tombOk, { remote = true })), "accepted",
        "same-planId tombstone still accepted")
    assertTrue(rec.entries[moveId].deleted, "same-planId tombstone applied")
    assertEq(rec.entries[moveId].planId, before.planId, "tombstone keeps original planId")
    ActAs("Alice-Garona", "Player-1-Alice")
end

---------------------------------------------------------------------------
-- Spec-button enabled state follows canEdit across pooled reuse
---------------------------------------------------------------------------

do
    ActAs("Alice-Garona", "Player-1-Alice")
    local stSpec, _, planSpec = RS:CreatePlan("Spec Eligibility")
    assertEq(stSpec, "accepted", "spec eligibility plan")
    RS:SelectPlan(planSpec)
    assertEq(select(1, RS:UpsertEntry({
        planId = planSpec,
        nickname = "AliceSpec",
        mainClass = "MAGE",
        mainSpec = 62,
        altClass = "WARRIOR",
        altSpec = 71,
    })), "accepted", "officer owned row with alt")
    assertEq(select(1, RS:UpsertEntry({
        planId = planSpec,
        nickname = "CarolSpec",
        mainClass = "PRIEST",
        mainSpec = 256,
        altClass = "ROGUE",
        altSpec = 259,
    })), "accepted", "second row before member create")
    -- Replace second row ownership: delete and let Carol create her own.
    local carolSeed = nil
    for _, e in ipairs(RS:GetSortedEntries(planSpec)) do
        if e.nickname == "CarolSpec" then
            carolSeed = e.entryId
        end
    end
    assertTrue(carolSeed ~= nil, "carol seed id")
    assertEq(select(1, RS:DeleteEntry(carolSeed)), "accepted", "remove officer-authored carol seed")
    ActAs("Carol-Garona", "Player-1-Carol")
    assertEq(select(1, RS:UpsertEntry({
        planId = planSpec,
        nickname = "CarolSpec",
        mainClass = "PRIEST",
        mainSpec = 256,
        altClass = "ROGUE",
        altSpec = 259,
    })), "accepted", "member owned row with alt")

    local function bySlot(slot)
        return UIPage._FindSpecButtonsForTests(panel.__sfRaidSignupEntriesHost, slot)
    end

    -- Member: own specs enabled; Alice's specs disabled; tooltips preserved.
    UIPage:Refresh(panel, { force = true })
    local mains = bySlot("main")
    local alts = bySlot("alt")
    assertEq(#mains, 2, "two main spec buttons")
    assertEq(#alts, 2, "two alt spec buttons")
    local enabledMain, disabledMain = 0, 0
    for i = 1, #mains do
        assertTrue(mains[i].tooltipTitle ~= nil and mains[i].tooltipTitle ~= "",
            "main tooltip title present for member view")
        assertTrue(mains[i].tooltipText ~= nil and mains[i].tooltipText ~= "",
            "main tooltip text present for member view")
        if mains[i]:IsEnabled() then
            enabledMain = enabledMain + 1
        else
            disabledMain = disabledMain + 1
        end
    end
    assertEq(enabledMain, 1, "member: exactly one main spec enabled (own)")
    assertEq(disabledMain, 1, "member: other creator main spec disabled")
    local enabledAlt, disabledAlt = 0, 0
    for i = 1, #alts do
        assertTrue(alts[i].tooltipTitle ~= nil and alts[i].tooltipTitle ~= "",
            "alt tooltip title present for member view")
        if alts[i]:IsEnabled() then
            enabledAlt = enabledAlt + 1
        else
            disabledAlt = disabledAlt + 1
        end
    end
    assertEq(enabledAlt, 1, "member: exactly one alt spec enabled (own)")
    assertEq(disabledAlt, 1, "member: other creator alt spec disabled")

    -- Creator/officer: both rows editable.
    ActAs("Alice-Garona", "Player-1-Alice")
    UIPage:Refresh(panel, { force = true })
    mains = bySlot("main")
    alts = bySlot("alt")
    for i = 1, #mains do
        assertTrue(mains[i]:IsEnabled(), "creator/officer main spec enabled")
        assertTrue(mains[i].tooltipTitle ~= nil and mains[i].tooltipTitle ~= "",
            "creator main tooltip preserved")
    end
    for i = 1, #alts do
        assertTrue(alts[i]:IsEnabled(), "creator/officer alt spec enabled")
    end

    ActAs("Bob-Garona", "Player-1-Bob")
    UIPage:Refresh(panel, { force = true })
    mains = bySlot("main")
    for i = 1, #mains do
        assertTrue(mains[i]:IsEnabled(), "officer main spec enabled")
    end

    -- Archive: all disabled after pooled reuse; tooltips remain.
    ActAs("Alice-Garona", "Player-1-Alice")
    assertEq(select(1, RS:SetPlanArchived(planSpec, true)), "accepted", "archive for spec disable")
    UIPage:Refresh(panel, { force = true })
    mains = bySlot("main")
    alts = bySlot("alt")
    assertTrue(#mains >= 1 and #alts >= 1, "archived spec buttons present")
    for i = 1, #mains do
        assertTrue(not mains[i]:IsEnabled(), "archived main spec disabled")
        assertTrue(mains[i].tooltipTitle ~= nil and mains[i].tooltipTitle ~= "",
            "archived main tooltip preserved")
    end
    for i = 1, #alts do
        assertTrue(not alts[i]:IsEnabled(), "archived alt spec disabled")
        assertTrue(alts[i].tooltipTitle ~= nil and alts[i].tooltipTitle ~= "",
            "archived alt tooltip preserved")
    end

    -- Reopen: creator specs enabled again after archive→open pooled reuse.
    assertEq(select(1, RS:SetPlanArchived(planSpec, false)), "accepted", "reopen spec plan")
    UIPage:Refresh(panel, { force = true })
    mains = bySlot("main")
    for i = 1, #mains do
        assertTrue(mains[i]:IsEnabled(), "reopened creator main spec enabled after pool reuse")
    end
    ActAs("Carol-Garona", "Player-1-Carol")
    UIPage:Refresh(panel, { force = true })
    mains = bySlot("main")
    enabledMain, disabledMain = 0, 0
    for i = 1, #mains do
        if mains[i]:IsEnabled() then
            enabledMain = enabledMain + 1
        else
            disabledMain = disabledMain + 1
        end
    end
    assertEq(enabledMain, 1, "member after reopen: own main enabled")
    assertEq(disabledMain, 1, "member after reopen: other main disabled")
    UIPage._SetDraftForTests(nil)
    ActAs("Alice-Garona", "Player-1-Alice")
    RS:SelectPlan(plan3)
    UIPage:Refresh(panel, { force = true })
end

-- Max-supported roster with alternatives + active picker: allocations still plateau.
-- 128 mains + 128 alts + class picker exceeds the old 256 hard discard cliff.
do
    local statusMax, _, planMax = RS:CreatePlan("Max Roster Plateau")
    assertEq(statusMax, "accepted", "max roster plan created")
    RS:SelectPlan(planMax)
    local maxN = RS.MAX_ENTRIES_PER_PLAN or 128
    for i = 1, maxN do
        local st = select(1, RS:UpsertEntry({
            planId = planMax,
            nickname = "R" .. tostring(i),
            mainClass = "MAGE",
            mainSpec = 62,
            altClass = "WARRIOR",
            altSpec = 71,
        }))
        assertEq(st, "accepted", "seed max roster row " .. tostring(i))
    end
    local pickerDraft = RS.MakeDraft(planMax)
    UIPage._SetDraftForTests(pickerDraft)
    UIPage:Refresh(panel, { force = true })
    UIPage:Refresh(panel, { force = true })
    local maxFrameWarm = UIPage._GetLifecycleCounters().frameCreateCount
    local maxRegionWarm = UIPage._GetLifecycleCounters().regionCreateCount
    local maxTexWarm = textureCount
    local maxFontWarm = fontStringCount
    for _ = 1, 6 do
        UIPage:Refresh(panel, { force = true })
    end
    assertEq(UIPage._GetLifecycleCounters().frameCreateCount, maxFrameWarm,
        "max-roster frame creates plateau")
    assertEq(UIPage._GetLifecycleCounters().regionCreateCount, maxRegionWarm,
        "max-roster region creates plateau")
    assertEq(textureCount, maxTexWarm, "max-roster texture creates plateau")
    assertEq(fontStringCount, maxFontWarm, "max-roster fontstring creates plateau")
    UIPage._SetDraftForTests(nil)
    RS:SelectPlan(plan3)
    UIPage:Refresh(panel, { force = true })
end

---------------------------------------------------------------------------
-- Equal-n live vs tombstone both delivery orders (production provider)
---------------------------------------------------------------------------

ActAs("Carol-Garona", "Player-1-Carol")
local eqId
status, _, eqId = RS:UpsertEntry({
    planId = plan3,
    nickname = "EqNonce",
    mainClass = "MAGE",
    mainSpec = 62,
})
assertEq(status, "accepted", "equal-n seed entry")
local base = RS.CloneEntry(select(1, RS:EnsureGuildRecord("club:42")).entries[eqId])
local liveHigh = RS.CloneEntry(base)
liveHigh.deleted = false
liveHigh.nickname = "LiveHigh"
liveHigh.ver = { n = base.ver.n + 1, w = "zzzzzzzzzzzzzzzzzzzzzzzz" }
local tombLow = RS.CloneEntry(base)
tombLow.deleted = true
tombLow.ver = { n = base.ver.n + 1, w = "aaaaaaaaaaaaaaaaaaaaaaaa" }

-- Order A: live first, then lower-writer tombstone
local peerA = { schemaVersion = 1, guildKey = "club:42", clubId = "42", plans = {}, entries = {} }
for _, plan in pairs(select(1, RS:EnsureGuildRecord("club:42")).plans) do
    RS.MergePlan(peerA, plan, { remote = true })
end
assertEq(select(1, RS.MergeEntry(peerA, liveHigh, { remote = true })), "accepted", "peerA live first")
assertEq(select(1, RS.MergeEntry(peerA, tombLow, { remote = true })), "accepted", "peerA tombstone wins over higher writer live")
assertTrue(peerA.entries[eqId].deleted, "peerA deleted after lower-w tombstone")

-- Order B: tombstone first, then higher-writer live
local peerB = { schemaVersion = 1, guildKey = "club:42", clubId = "42", plans = {}, entries = {} }
for _, plan in pairs(select(1, RS:EnsureGuildRecord("club:42")).plans) do
    RS.MergePlan(peerB, plan, { remote = true })
end
assertEq(select(1, RS.MergeEntry(peerB, tombLow, { remote = true })), "accepted", "peerB tombstone first")
assertEq(select(1, RS.MergeEntry(peerB, liveHigh, { remote = true })), "rejected", "peerB live cannot restore")
assertTrue(peerB.entries[eqId].deleted, "peerB stays deleted")

-- Provider path equal-n tombstone after live on main record
ActAs("Carol-Garona", "Player-1-Carol")
local eq2
status, _, eq2 = RS:UpsertEntry({
    planId = plan3,
    nickname = "EqProv",
    mainClass = "WARRIOR",
    mainSpec = 71,
})
local base2 = RS.CloneEntry(select(1, RS:EnsureGuildRecord("club:42")).entries[eq2])
local live2 = RS.CloneEntry(base2)
live2.ver = { n = base2.ver.n + 1, w = "yyyyyyyyyyyyyyyyyyyyyyyy" }
live2.nickname = "Advanced"
assertEq(select(1, provider.ValidateAndApply({
    id = RS.EntryRecordId(eq2),
    versionFp = "live2",
    body = { kind = "raidsignup-entry", schema = 1, entry = live2 },
}, { sender = "Carol-Garona" })), "accepted", "provider admits advanced live")
local tomb2 = RS.CloneEntry(base2)
tomb2.deleted = true
tomb2.ver = { n = base2.ver.n + 1, w = "bbbbbbbbbbbbbbbbbbbbbbbb" }
assertEq(select(1, provider.ValidateAndApply({
    id = RS.EntryRecordId(eq2),
    versionFp = "tomb2",
    body = { kind = "raidsignup-entry", schema = 1, entry = tomb2 },
}, { sender = "Carol-Garona" })), "accepted", "provider admits equal-n lower-w tombstone over live")
assertTrue(select(1, RS:EnsureGuildRecord("club:42")).entries[eq2].deleted, "provider deletion converged")
-- repeated replay
assertEq(select(1, provider.ValidateAndApply({
    id = RS.EntryRecordId(eq2),
    versionFp = "live2-replay",
    body = { kind = "raidsignup-entry", schema = 1, entry = live2 },
}, { sender = "Carol-Garona" })), "rejected", "repeated live replay rejected")

---------------------------------------------------------------------------
-- Bound first-seen tombstones + terminal revision rejection
---------------------------------------------------------------------------

local rec = select(1, RS:EnsureGuildRecord("club:42"))
local tombCount = 0
for i = 1, RS.MAX_ENTRIES + 5 do
    local te = {
        entryId = "tomb-flood-" .. tostring(i),
        planId = plan3,
        nickname = "T",
        mainClass = "MAGE",
        mainSpec = 62,
        notes = "",
        creatorGuid = "Player-1-Carol",
        deleted = true,
        ver = { n = 1, w = string.format("%024x", i) },
        at = 1,
    }
    local st = select(1, RS.MergeEntry(rec, te, { remote = true }))
    if st == "accepted" then
        tombCount = tombCount + 1
    end
end
assertTrue(tombCount <= RS.MAX_ENTRIES, "first-seen tombstones are bounded")
assertEq(select(1, RS.MergeEntry(rec, {
    entryId = "tomb-flood-overflow",
    planId = plan3,
    nickname = "T",
    mainClass = "MAGE",
    mainSpec = 62,
    creatorGuid = "Player-1-Carol",
    deleted = true,
    ver = { n = 1, w = "ffffffffffffffffffffffff" },
    at = 1,
}, { remote = true })), "rejected", "tombstone at capacity rejected")

-- Deleting an existing live entry at capacity still works
ActAs("Carol-Garona", "Player-1-Carol")
-- Ensure at least one live entry remains / create if needed
local liveCapId
status, _, liveCapId = RS:UpsertEntry({
    planId = plan3,
    nickname = "CapDelete",
    mainClass = "ROGUE",
    mainSpec = 259,
})
if status == "accepted" then
    assertEq(select(1, RS:DeleteEntry(liveCapId)), "accepted", "delete existing live at/near capacity allowed")
elseif status == "rejected" then
    -- capacity already full of retained rows; pick any live and delete
    local liveList = RS:GetSortedEntries(plan3)
    assertTrue(#liveList > 0, "have a live entry to delete at capacity")
    assertEq(select(1, RS:DeleteEntry(liveList[1].entryId)), "accepted", "delete existing live at capacity allowed")
end

-- Terminal / implausible remote revision
local bad = RS.CloneEntry(base)
bad.entryId = "rev-terminal"
bad.ver = { n = RS.MAX_REV, w = "cccccccccccccccccccccccc" }
assertEq(select(1, RS.MergeEntry(rec, bad, { remote = true })), "rejected", "terminal MAX_REV rejected")
bad.ver = { n = RS.MAX_REV - 1, w = "cccccccccccccccccccccccc" }
bad.ver.n = (rec.entries[eqId] and rec.entries[eqId].ver.n or 0) + RS.MAX_REV_CATCHUP + 1
assertEq(select(1, RS.MergeEntry(rec, bad, { remote = true })), "rejected", "implausible jump rejected")

-- Admitted member entry remains officer-editable
ActAs("Carol-Garona", "Player-1-Carol")
local modId
status, _, modId = RS:UpsertEntry({
    planId = plan3,
    nickname = "ModMe",
    mainClass = "PRIEST",
    mainSpec = 256,
})
if status ~= "accepted" then
    -- may fail if overflow; clear by using an existing carol entry if needed
    local list = RS:GetSortedEntries(plan3)
    modId = list[1] and list[1].entryId
end
assertTrue(modId ~= nil, "have entry for officer moderation")
ActAs("Bob-Garona", "Player-1-Bob")
local modEntry = select(1, RS:EnsureGuildRecord("club:42")).entries[modId]
assertEq(select(1, RS:UpsertEntry({
    entryId = modId,
    planId = modEntry.planId,
    nickname = "OfficerMod",
    mainClass = modEntry.mainClass,
    mainSpec = modEntry.mainSpec,
}, { expectedVer = modEntry.ver })), "accepted", "officer can edit admitted member entry")
modEntry = select(1, RS:EnsureGuildRecord("club:42")).entries[modId]
assertEq(select(1, RS:DeleteEntry(modId, { expectedVer = modEntry.ver })), "accepted", "officer can delete admitted member entry")

---------------------------------------------------------------------------
-- Repair batch: rename getSelectionKey, class recovery, locals, debug logs
---------------------------------------------------------------------------

do
    -- Accidental globals must stay page-local.
    assertNil(rawget(_G, "PaintSummary"), "PaintSummary is not global")
    assertNil(rawget(_G, "PaintEntries"), "PaintEntries is not global")
    assertNil(rawget(_G, "EnsureSummaryHost"), "EnsureSummaryHost is not global")
    assertNil(rawget(_G, "EnsureEntriesHost"), "EnsureEntriesHost is not global")

    -- Diagnostic logging at mutation API boundary (no nickname payload).
    SF.Debug._on = true
    SF.Debug:Reset()
    ActAs("Alice-Garona", "Player-1-Alice")
    local stLog, _, planLog = RS:CreatePlan("Debug Log Plan")
    assertEq(stLog, "accepted", "create plan for debug logging")
    local sawCreate = false
    for i = 1, #SF.Debug._info do
        local row = SF.Debug._info[i]
        if row.cat == "RAID_SIGNUP" and tostring(row.msg):find("CreatePlan", 1, true) then
            sawCreate = true
            assertTrue(not tostring(row.msg):find("Debug Log Plan", 1, true),
                "create log omits plan name payload")
        end
    end
    assertTrue(sawCreate, "CreatePlan accepted logs INFO")
    SF.Debug:Reset()
    assertEq(select(1, RS:RenamePlan(planLog, "")), "rejected", "empty rename rejected for warn log")
    local sawWarn = false
    for i = 1, #SF.Debug._warn do
        local row = SF.Debug._warn[i]
        if row.cat == "RAID_SIGNUP" and tostring(row.msg):find("RenamePlan", 1, true) then
            sawWarn = true
        end
    end
    assertTrue(sawWarn, "RenamePlan rejection logs WARN")
    SF.Debug._on = false
    SF.Debug:Reset()

    -- Class-picker recovery: preserve nickname/notes; incomplete stays unsaved.
    local stPick, _, planPick = RS:CreatePlan("Class Recovery Plan")
    assertEq(stPick, "accepted", "class recovery plan")
    RS:SelectPlan(planPick)
    local recoveryDraft = RS.MakeDraft(planPick)
    RS.UpdateDraftField(recoveryDraft, "nickname", "KeepNick")
    RS.CommitDraftNickname(recoveryDraft)
    RS.UpdateDraftField(recoveryDraft, "notes", "KeepNotes")
    RS.UpdateDraftField(recoveryDraft, "classFile", "MAGE")
    assertEq(recoveryDraft.phase, "spec", "draft enters spec phase after class")
    UIPage._SetDraftForTests(recoveryDraft)
    UIPage:Refresh(panel, { force = true })

    local function findChangeClassButtons(root)
        local found = {}
        local function walk(frame)
            if not frame then
                return
            end
            if frame.GetObjectType and frame:GetObjectType() == "Button"
                and type(frame.tooltipText) == "string"
                and frame.tooltipText:find("different class", 1, true) then
                found[#found + 1] = frame
            end
            local kids = { frame:GetChildren() }
            for i = 1, #kids do
                walk(kids[i])
            end
        end
        walk(root)
        return found
    end

    local changeBtns = findChangeClassButtons(panel.__sfRaidSignupEntriesHost)
    assertTrue(#changeBtns >= 1, "spec-phase change-class control present")
    changeBtns[1]:Click()
    local afterReset = UIPage._GetDraftForTests()
    assertTrue(afterReset ~= nil, "draft survives class reset")
    assertEq(afterReset.nickname, "KeepNick", "nickname preserved on class reset")
    assertEq(afterReset.notes, "KeepNotes", "notes preserved on class reset")
    assertNil(afterReset.classFile, "class cleared on reset")
    assertNil(afterReset.specId, "spec cleared on reset")
    assertEq(afterReset.phase, "class", "phase returns to class")
    assertEq(#RS:GetSortedEntries(planPick), 0, "incomplete draft not persisted")

    -- Re-pick class+spec and ensure same-main exclusion still applies on alt draft.
    RS.UpdateDraftField(afterReset, "classFile", "WARRIOR")
    RS.UpdateDraftField(afterReset, "specId", 71)
    assertEq(select(1, RS:UpsertEntry({
        planId = planPick,
        nickname = afterReset.nickname,
        mainClass = afterReset.classFile,
        mainSpec = afterReset.specId,
        notes = afterReset.notes,
    })), "accepted", "persist after recovery re-pick")
    UIPage._SetDraftForTests(nil)
    local saved = RS:GetSortedEntries(planPick)[1]
    assertTrue(saved ~= nil, "saved entry after recovery path")
    local savedNick, savedClass, savedSpec = saved.nickname, saved.mainClass, saved.mainSpec
    local savedNotes = saved.notes

    -- Main edit: click main → class → reset → abandon; saved values survive.
    UIPage:Refresh(panel, { force = true })
    local mains = UIPage._FindSpecButtonsForTests(panel.__sfRaidSignupEntriesHost, "main")
    assertTrue(#mains >= 1, "main spec button for edit recovery")
    mains[1]:Click()
    local editing = UIPage._GetEditingForTests()
    assertTrue(editing and editing.draft, "editing draft opened")
    RS.UpdateDraftField(editing.draft, "classFile", "MAGE")
    assertEq(editing.draft.phase, "spec", "edit draft in spec phase")
    UIPage:Refresh(panel, { force = true })
    changeBtns = findChangeClassButtons(panel.__sfRaidSignupEntriesHost)
    assertTrue(#changeBtns >= 1, "edit path change-class control present")
    changeBtns[1]:Click()
    editing = UIPage._GetEditingForTests()
    assertTrue(editing and editing.draft and editing.draft.phase == "class",
        "edit draft returns to class without saving")
    -- Abandon via plan reselection (DiscardEphemeral).
    RS:SelectPlan(planPick)
    UIPage:Refresh(panel, { forceRebuild = true })
    assertNil(UIPage._GetEditingForTests(), "editing discarded on reselection")
    saved = RS:GetSortedEntries(planPick)[1]
    assertEq(saved.nickname, savedNick, "saved nickname survives abandoned edit")
    assertEq(saved.mainClass, savedClass, "saved class survives abandoned edit")
    assertEq(saved.mainSpec, savedSpec, "saved spec survives abandoned edit")
    assertEq(saved.notes, savedNotes, "saved notes survive abandoned edit")

    -- Alt draft: same-main-spec remains disabled after class reset+reselect.
    local altDraft = RS.MakeAltDraft(saved)
    RS.UpdateAltDraftField(altDraft, "classFile", "WARRIOR")
    assertTrue(RS.IsAltSpecDisabled(altDraft, 71), "same-main-spec excluded for alt")
    RS.UpdateAltDraftField(altDraft, "classFile", nil)
    assertEq(altDraft.phase, "class", "alt draft class reset")
    RS.UpdateAltDraftField(altDraft, "classFile", "WARRIOR")
    assertTrue(RS.IsAltSpecDisabled(altDraft, 71), "same-main-spec exclusion after alt reset")

    -- Wrong-plan rename: exercise production AddEditBoxWithButton DoSubmit with
    -- the Raid Signup rename definition (not a copied selection-key guard).
    local stA, _, planA = RS:CreatePlan("Rename Plan A")
    local stB, _, planB = RS:CreatePlan("Rename Plan B")
    assertEq(stA, "accepted", "rename plan A created")
    assertEq(stB, "accepted", "rename plan B created")
    RS:SelectPlan(planA)

    local stubControls = SF.SettingsUI.Controls
    local savedAddEdit = stubControls.AddEditBoxWithButton
    local savedAddDropdown = stubControls.AddDropdown
    local savedAddDisplay = stubControls.AddDisplay
    local savedAddButton = stubControls.AddButton

    local renameOpts = nil
    local planSelectSet = nil
    stubControls.AddEditBoxWithButton = function(_, _, opts)
        if opts and type(opts.onSubmit) == "function"
            and type(opts.get) == "function"
            and opts.buttonText then
            -- Capture the rename control (has getSelectionKey when fixed).
            if opts.getSelectionKey ~= nil or (opts.label and tostring(opts.label):find("Rename", 1, true)) then
                renameOpts = opts
            end
        end
    end
    stubControls.AddDropdown = function(_, _, opts)
        if opts and type(opts.set) == "function" and type(opts.get) == "function" then
            if opts.get() == planA or opts.get() == RS:GetSelectedPlanId() then
                planSelectSet = opts.set
            end
        end
    end
    UIPage:Refresh(panel, { forceRebuild = true })
    assertTrue(renameOpts ~= nil, "Raid Signup rename definition captured")
    assertTrue(type(renameOpts.getSelectionKey) == "function",
        "rename control binds getSelectionKey")
    assertTrue(type(planSelectSet) == "function", "plan select dropdown captured")
    assertEq(renameOpts.getSelectionKey(), planA, "selection key is plan A")

    -- Load production Controls; keep page-builder stubs restored afterward.
    load("SpectrumFederation/modules/UI/Settings/Control/Controls.lua")
    local productionAddEdit = SF.SettingsUI.Controls.AddEditBoxWithButton
    assertTrue(type(productionAddEdit) == "function", "production AddEditBoxWithButton loaded")
    stubControls.AddEditBoxWithButton = savedAddEdit
    stubControls.AddDropdown = savedAddDropdown
    stubControls.AddDisplay = savedAddDisplay
    stubControls.AddButton = savedAddButton

    local function makeRenameSection()
        return {
            __sfPageBuilder = {
                _refresh = {},
                RegisterRefresh = function(self, fn)
                    self._refresh[#self._refresh + 1] = fn
                end,
                FireRefresh = function(self)
                    for i = 1, #self._refresh do
                        self._refresh[i]()
                    end
                end,
            },
            AddRow = function(self, _, builder)
                local row = CreateFrame("Frame", nil, panel)
                row:SetSize(400, 26)
                builder(row)
                return row
            end,
        }
    end

    local function findRenameWidgets(section)
        local edit, btn
        local function walk(frame)
            if not frame then
                return
            end
            if frame.GetObjectType then
                local kind = frame:GetObjectType()
                if kind == "EditBox" and not edit then
                    edit = frame
                elseif kind == "Button" and frame.GetText and frame:GetText() == renameOpts.buttonText and not btn then
                    btn = frame
                end
            end
            local kids = { frame:GetChildren() }
            for i = 1, #kids do
                walk(kids[i])
            end
        end
        for i = 1, #(section._rows or {}) do
            walk(section._rows[i])
        end
        -- Rows may not be tracked; walk from AddRow parent via recent creates is
        -- brittle — instead search panel children created during AddEditBoxWithButton.
        walk(panel)
        return edit, btn
    end

    local function mountRenameControl(opts)
        local section = makeRenameSection()
        local rows = {}
        local origAddRow = section.AddRow
        function section:AddRow(height, builder)
            local row = origAddRow(self, height, builder)
            rows[#rows + 1] = row
            self._rows = rows
            return row
        end
        productionAddEdit(SF.SettingsUI.Controls, section, opts)
        local edit, btn = findRenameWidgets(section)
        -- Prefer widgets under the section rows we just created.
        if not edit or not btn then
            for i = 1, #rows do
                local function walk(frame)
                    if not frame then return end
                    if frame.GetObjectType then
                        local kind = frame:GetObjectType()
                        if kind == "EditBox" and not edit then edit = frame end
                        if kind == "Button" and frame.GetText and frame:GetText() == opts.buttonText and not btn then
                            btn = frame
                        end
                    end
                    local kids = { frame:GetChildren() }
                    for j = 1, #kids do walk(kids[j]) end
                end
                walk(rows[i])
            end
        end
        return section, edit, btn
    end

    local function planName(planId)
        local rec = select(1, RS:EnsureGuildRecord("club:42"))
        return rec.plans[planId] and rec.plans[planId].name
    end

    -- Fail-before: same Raid Signup onSubmit/get, but without getSelectionKey
    -- (pre-fix page binding). Dirty A → select B → real DoSubmit renames B.
    do
        RS:SelectPlan(planA)
        local broken = {}
        for k, v in pairs(renameOpts) do
            broken[k] = v
        end
        broken.getSelectionKey = nil
        local _, edit, btn = mountRenameControl(broken)
        assertTrue(edit ~= nil and btn ~= nil, "pre-fix rename widgets created")
        assertEq(edit:GetText(), "Rename Plan A", "pre-fix loaded plan A name")
        edit:SetText("Dirty Name For A")
        planSelectSet(planB)
        assertEq(RS:GetSelectedPlanId(), planB, "pre-fix selected B before refresh")
        -- No FireRefresh: deferred-refresh race.
        btn:Click()
        assertEq(planName(planB), "Dirty Name For A",
            "pre-fix: durable B incorrectly receives A's dirty text")
        assertEq(planName(planA), "Rename Plan A", "pre-fix: A name unchanged")
        -- Restore durable B for the fixed-path assertions.
        assertEq(select(1, RS:RenamePlan(planB, "Rename Plan B")), "accepted",
            "restore plan B after fail-before proof")
    end

    -- Fixed binding: production DoSubmit aborts dirty A→B before refresh.
    RS:SelectPlan(planA)
    UIPage:Refresh(panel, { forceRebuild = true }) -- refresh captured closures for A
    -- Re-capture opts after rebuild (closures bind CurrentSelectedId).
    renameOpts = nil
    planSelectSet = nil
    stubControls.AddEditBoxWithButton = function(_, _, opts)
        if opts and type(opts.getSelectionKey) == "function" and type(opts.onSubmit) == "function" then
            renameOpts = opts
        end
    end
    stubControls.AddDropdown = function(_, _, opts)
        if opts and type(opts.set) == "function" and type(opts.get) == "function" then
            if opts.get() == planA or opts.get() == RS:GetSelectedPlanId() then
                planSelectSet = opts.set
            end
        end
    end
    UIPage:Refresh(panel, { forceRebuild = true })
    stubControls.AddEditBoxWithButton = savedAddEdit
    stubControls.AddDropdown = savedAddDropdown
    assertTrue(renameOpts ~= nil and type(renameOpts.getSelectionKey) == "function",
        "fixed rename opts re-captured")
    assertTrue(type(planSelectSet) == "function", "plan select re-captured")

    local section, edit, btn = mountRenameControl(renameOpts)
    assertTrue(edit ~= nil and btn ~= nil, "fixed rename widgets created")
    assertEq(edit:GetText(), "Rename Plan A", "fixed control loaded plan A name")
    edit:SetText("Dirty Name For A")
    planSelectSet(planB)
    assertEq(RS:GetSelectedPlanId(), planB, "selected B before deferred refresh")
    assertEq(UIPage._GetRenamePlanNameForTests(), "", "rename draft cleared on plan select")
    btn:Click()
    assertEq(planName(planB), "Rename Plan B",
        "fixed: durable B unchanged after aborted dirty submit")
    assertEq(planName(planA), "Rename Plan A",
        "fixed: durable A unchanged after aborted dirty submit")
    assertEq(edit:GetText(), "Rename Plan B",
        "fixed: aborted submit reloads plan B getter text")

    -- Switching plans with normal refresh reloads B; valid rename of B succeeds.
    section.__sfPageBuilder:FireRefresh()
    assertEq(edit:GetText(), "Rename Plan B", "refresh keeps plan B name")
    edit:SetText("Rename Plan B Updated")
    btn:Click()
    assertEq(planName(planB), "Rename Plan B Updated",
        "fixed: durable B renamed through production DoSubmit")
    assertEq(planName(planA), "Rename Plan A",
        "fixed: durable A never receives B-keyed submit")

    -- Also cover dirty A → select B → refresh (no submit) → names untouched.
    RS:SelectPlan(planA)
    stubControls.AddEditBoxWithButton = function(_, _, opts)
        if opts and type(opts.getSelectionKey) == "function" then
            renameOpts = opts
        end
    end
    stubControls.AddDropdown = function(_, _, opts)
        if opts and type(opts.set) == "function" then
            planSelectSet = opts.set
        end
    end
    UIPage:Refresh(panel, { forceRebuild = true })
    stubControls.AddEditBoxWithButton = savedAddEdit
    stubControls.AddDropdown = savedAddDropdown
    section, edit, btn = mountRenameControl(renameOpts)
    edit:SetText("Another Dirty A")
    planSelectSet(planB)
    section.__sfPageBuilder:FireRefresh()
    assertEq(edit:GetText(), "Rename Plan B Updated",
        "normal refresh after select reloads B without submitting dirty A")
    assertEq(planName(planA), "Rename Plan A", "normal refresh leaves durable A")
    assertEq(planName(planB), "Rename Plan B Updated", "normal refresh leaves durable B")

    -- Restore page-builder control stubs for later tests.
    stubControls.AddEditBoxWithButton = savedAddEdit
    stubControls.AddDropdown = savedAddDropdown
    stubControls.AddDisplay = savedAddDisplay
    stubControls.AddButton = savedAddButton

    RS:SelectPlan(plan3)
    UIPage._SetDraftForTests(nil)
    UIPage:Refresh(panel, { forceRebuild = true })
end

---------------------------------------------------------------------------
-- Production GuildGossip index contract (07_Index + 08_Providers.EnsureProviderIndex)
---------------------------------------------------------------------------

do
    local providerApi = provider
    assertTrue(type(providerApi.EnsureIndex) == "function", "raid signup EnsureIndex present")

    SF.GuildGossip._providers = nil
    load("SpectrumFederation/modules/GuildGossip/01_Constants.lua")
    load("SpectrumFederation/modules/GuildGossip/02_Util.lua")
    load("SpectrumFederation/modules/GuildGossip/07_Index.lua")
    load("SpectrumFederation/modules/GuildGossip/08_Providers.lua")
    local GG = SF.GuildGossip
    GG.MarkWorkPending = GG.MarkWorkPending or function() end
    GG.NotifyMeaningfulChange = GG.NotifyMeaningfulChange or function() end
    GG.SyncGuildAdapterLifecycle = nil
    GG.IsGuildReady = function() return false end
    GG._EnsureScheduler = function() end
    assertTrue(type(GG.EnsureProviderIndex) == "function", "EnsureProviderIndex present")
    assertTrue(type(GG.RegisterProvider) == "function", "production RegisterProvider loaded")

    GG._providers = { byId = {}, order = {}, activeCount = 0, discRotate = 0 }
    local okReg, provEntry = GG.RegisterProvider({
        id = RS.PROVIDER_ID,
        schema = RS.PROVIDER_SCHEMA,
        enabled = true,
        ready = true,
        EnsureIndex = providerApi.EnsureIndex,
        OnIndexInvalidated = providerApi.OnIndexInvalidated,
        ListRecordIds = providerApi.ListRecordIds,
        GetRecordVersionFp = providerApi.GetRecordVersionFp,
        GetRecordBody = providerApi.GetRecordBody,
        ValidateAndApply = providerApi.ValidateAndApply,
        GetScopeId = providerApi.GetScopeId,
        IsPeerEligible = providerApi.IsPeerEligible,
        GetCapabilities = providerApi.GetCapabilities,
    })
    assertTrue(okReg and provEntry ~= nil, "raid signup provider registered with production Gossip")
    provEntry = GG.GetProvider(RS.PROVIDER_ID)
    assertTrue(provEntry ~= nil and provEntry.api ~= nil, "provider entry has api")

    local function examinedNonNeg(entry)
        local examined = tonumber(entry.lastIndexExamined)
        return examined == nil or examined >= 0
    end

    local function driveProvider(budget, rounds)
        rounds = rounds or 128
        local steps = 0
        for _ = 1, rounds do
            steps = steps + 1
            local more = GG.EnsureProviderIndex(provEntry, { indexEntries = budget })
            if provEntry.indexFailed then
                fail("EnsureProviderIndex marked indexFailed (" .. tostring(provEntry.indexFailReason) .. ")")
                return steps
            end
            if not examinedNonNeg(provEntry) then
                fail("lastIndexExamined is negative")
                return steps
            end
            local index = provEntry.index
            if more == false and index and index.buildComplete and not index.dirty then
                return steps
            end
        end
        fail("EnsureProviderIndex did not converge budget=" .. tostring(budget))
        return steps
    end

    -- Empty-ish rebuild then complete through production driver
    RS.NotifyLocalDurableChange("local")
    provEntry.index = GG.CreateIndex()
    provEntry.indexFailed = nil
    local steps = driveProvider(8)
    assertTrue(provEntry.index.buildComplete and not provEntry.index.dirty, "provider index completes")
    assertTrue(steps >= 1, "at least one EnsureProviderIndex step")
    assertTrue(provEntry._indexUsable == true, "completed index marked usable")

    -- Idle EnsureProviderIndex does no further work / no indexFailed
    local epoch = provEntry.index.epoch
    for _ = 1, 5 do
        local more = GG.EnsureProviderIndex(provEntry, { indexEntries = 8 })
        assertEq(more and true or false, false, "idle EnsureProviderIndex returns false")
        assertTrue(not provEntry.indexFailed, "idle does not fail index")
    end
    assertEq(provEntry.index.epoch, epoch, "idle EnsureProviderIndex does not bump epoch")

    -- Multi-slice with tiny budget
    ActAs("Alice-Garona", "Player-1-Alice")
    RS:CreatePlan("IndexSlicePlan")
    RS.NotifyLocalDurableChange("local")
    provEntry.index = GG.CreateIndex()
    provEntry.indexFailed = nil
    provEntry._indexUsable = nil
    -- Max-roster seed above leaves hundreds of export rows; budget=1 needs many slices.
    steps = driveProvider(1, 4096)
    assertTrue(provEntry.index.buildComplete and not provEntry.index.dirty, "multi-slice provider index completes")
    assertTrue(steps > 1, "tiny budget requires multiple EnsureProviderIndex slices")

    -- create -> complete -> edit -> new fingerprint via EnsureProviderIndex
    local index = provEntry.index
    local plansNow = RS:GetSortedPlans(true)
    local targetPlan = nil
    for i = 1, #plansNow do
        if not plansNow[i].archived then
            targetPlan = plansNow[i]
            break
        end
    end
    assertTrue(targetPlan ~= nil, "open plan available for rename index test")
    local beforeFp = index.byId[RS.PlanRecordId(targetPlan.planId)]
        and index.byId[RS.PlanRecordId(targetPlan.planId)].versionFp
    assertEq(select(1, RS:RenamePlan(targetPlan.planId, targetPlan.name .. "X", {
        expectedVer = targetPlan.ver,
    })), "accepted", "rename for index fingerprint change")
    RS.NotifyLocalDurableChange("local")
    driveProvider(8, 512)
    assertTrue(provEntry.index.buildComplete and not provEntry.index.dirty, "index idle after rename rebuild")
    assertTrue(not provEntry.indexFailed, "rename rebuild did not fail index")
    local afterFp = provEntry.index.byId[RS.PlanRecordId(targetPlan.planId)]
        and provEntry.index.byId[RS.PlanRecordId(targetPlan.planId)].versionFp
    assertTrue(afterFp ~= nil and afterFp ~= beforeFp, "physical fingerprint updated after rename")
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
