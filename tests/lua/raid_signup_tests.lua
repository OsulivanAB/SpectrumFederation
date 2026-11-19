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
    WARRIOR = { colorCode = { r = 0.78, g = 0.61, b = 0.43 }, textureFile = "Interface\\Icons\\ClassIcon_Warrior" },
    PALADIN = { colorCode = { r = 0.96, g = 0.55, b = 0.73 }, textureFile = "Interface\\Icons\\ClassIcon_Paladin" },
    HUNTER = { colorCode = { r = 0.67, g = 0.83, b = 0.45 }, textureFile = "Interface\\Icons\\ClassIcon_Hunter" },
    ROGUE = { colorCode = { r = 1.00, g = 0.96, b = 0.41 }, textureFile = "Interface\\Icons\\ClassIcon_Rogue" },
    PRIEST = { colorCode = { r = 1.00, g = 1.00, b = 1.00 }, textureFile = "Interface\\Icons\\ClassIcon_Priest" },
    DEATHKNIGHT = { colorCode = { r = 0.77, g = 0.12, b = 0.23 }, textureFile = "Interface\\Icons\\ClassIcon_DeathKnight" },
    SHAMAN = { colorCode = { r = 0.00, g = 0.44, b = 0.87 }, textureFile = "Interface\\Icons\\ClassIcon_Shaman" },
    MAGE = { colorCode = { r = 0.25, g = 0.78, b = 0.92 }, textureFile = "Interface\\Icons\\ClassIcon_Mage" },
    WARLOCK = { colorCode = { r = 0.53, g = 0.53, b = 0.93 }, textureFile = "Interface\\Icons\\ClassIcon_Warlock" },
    MONK = { colorCode = { r = 0.00, g = 1.00, b = 0.59 }, textureFile = "Interface\\Icons\\ClassIcon_Monk" },
    DRUID = { colorCode = { r = 1.00, g = 0.49, b = 0.04 }, textureFile = "Interface\\Icons\\ClassIcon_Druid" },
    DEMONHUNTER = { colorCode = { r = 0.64, g = 0.19, b = 0.79 }, textureFile = "Interface\\Icons\\ClassIcon_DemonHunter" },
    EVOKER = { colorCode = { r = 0.20, g = 0.58, b = 0.50 }, textureFile = "Interface\\Icons\\ClassIcon_Evoker" },
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
for _, cat in ipairs(RS.MAJOR_CATEGORIES) do
    assertTrue((type(cat.icon) == "string" and cat.icon ~= "") or type(cat.icon) == "number",
        "major category has icon: " .. tostring(cat.id))
end
for _, cat in ipairs(RS.UTILITY_CATEGORIES) do
    assertTrue((type(cat.icon) == "string" and cat.icon ~= "") or type(cat.icon) == "number",
        "utility category has icon: " .. tostring(cat.id))
end
-- Skyfury uses the owner-specified numeric FileDataID and survives icon resolution.
do
    local skyfuryCat, bronzeCat
    for _, cat in ipairs(RS.MAJOR_CATEGORIES) do
        if cat.id == "skyfury" then
            skyfuryCat = cat
        end
        if cat.id == "blessing_bronze" then
            bronzeCat = cat
        end
    end
    assertTrue(skyfuryCat ~= nil, "skyfury relocated to Major Buffs/Debuffs")
    assertEq(skyfuryCat and skyfuryCat.icon, 4630367, "skyfury uses numeric FileDataID 4630367")
    assertEq(RS.CategoryIconTexture(skyfuryCat), 4630367, "numeric FileDataID passes through")
    assertTrue(bronzeCat ~= nil, "blessing of the bronze relocated to Major Buffs/Debuffs")
end

-- UTF-8-safe byte-cap truncation never persists split multibyte characters.
local nick47 = ("a"):rep(47) .. "\195\169" -- 47 ASCII + é (2 bytes) = 49 > 48 cap
assertEq(RS.NormalizeNickname(nick47), ("a"):rep(47), "nickname drops dangling lead byte")
assertEq(#RS.NormalizeNickname(nick47), 47, "nickname stays within byte cap")
local nickExact = ("a"):rep(46) .. "\195\169" -- exactly 48 bytes
assertEq(RS.NormalizeNickname(nickExact), nickExact, "complete 2-byte char within cap kept")
local nick3 = ("a"):rep(45) .. "\226\130\172" -- 45 + € (3 bytes) = exactly 48
assertEq(RS.NormalizeNickname(nick3), nick3, "complete 3-byte char within cap kept")
local nickOver3 = ("a"):rep(46) .. "\226\130\172" -- 46 + € (3 bytes) = 49 > 48 cap
assertEq(#RS.NormalizeNickname(nickOver3), 46, "incomplete 3-byte sequence dropped")
local plan63 = ("p"):rep(63) .. "\195\169" -- 63 + é = 65 > 64 cap
assertEq(#RS.NormalizePlanName(plan63), 63, "plan name truncation is UTF-8 safe")
local notes159 = ("b"):rep(159) .. "\195\169" -- 159 + é = 161 > 160 cap
assertEq(#RS.NormalizeNotes(notes159), 159, "notes truncation is UTF-8 safe")

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
assertTrue(summary.utility.innervate, "balance druid covers innervate (talent-dependent, all specs)")
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
-- Provider-count aggregation, warlock split, and category placement
---------------------------------------------------------------------------
do
    -- One summary covering: heroism equivalents, warlock utilities, DK grip
    -- overlay split, innervate eligibility, and exclusion of deleted entries
    -- and incomplete drafts.
    local summary = RS.BuildSummary({
        { mainClass = "MAGE", mainSpec = 62 },        -- heroism, intellect
        { mainClass = "PRIEST", mainSpec = 256 },     -- stamina, mass dispel
        { mainClass = "WARLOCK", mainSpec = 265 },    -- heroism? no; 3 warlock utils, combat res, cast slow
        { mainClass = "DEATHKNIGHT", mainSpec = 251 },-- frost: grip overlay +1
        { mainClass = "DEATHKNIGHT", mainSpec = 250 },-- blood: AMZ coverage, no grip overlay
        { mainClass = "DRUID", mainSpec = 102 },      -- balance: innervate now eligible
        { mainClass = "DRUID", mainSpec = 105 },      -- resto: innervate
        { mainClass = "ROGUE", mainSpec = 259, deleted = true },
        { mainClass = "MONK" },                       -- incomplete draft: no spec
    })
    local pc = summary.providerCounts
    assertTrue(type(pc) == "table", "provider counts aggregated")
    assertEq(pc.intellect, 1, "intellect counts the mage main once")
    assertEq(pc.bloodlust, 1, "heroism counts mage only (internal category id retained)")
    assertEq(pc.mass_dispel, 1, "mass dispel counts the priest main")
    assertEq(pc.combat_res, 5, "combat res counts warlock + 2 DKs + 2 druids")
    assertEq(pc.warlock_ritual, 1, "ritual of summoning counts warlock mains")
    assertEq(pc.warlock_healthstone, 1, "healthstone counts warlock mains")
    assertEq(pc.warlock_gateway, 1, "demonic gateway counts warlock mains")
    assertEq(pc.dk_grip_amz, 1, "grip overlay counts Frost DK providers only")
    assertEq(pc.burst_move, 2, "burst move counts two druids; deleted shaman and spec-less monk draft excluded")
    assertEq(pc.innervate, 2, "innervate counts balance and resto druids")
    assertEq(pc.atk_speed_slow, 0, "deleted rogue excluded from provider counts")
    -- Coverage booleans still derive from any-provider rules.
    assertTrue(summary.utility.dk_grip_amz, "any DK covers grip/AMZ")
    assertEq(summary.utility.lock_stuff, nil, "lock stuff category removed")
    assertTrue(summary.major.skyfury == false, "skyfury uncovered without shaman, but present")
    assertTrue(summary.major.blessing_bronze == false, "bronze uncovered without evoker")
    assertTrue(summary.utility.skyfury == nil, "skyfury no longer in utility")
    assertTrue(summary.utility.blessing_bronze == nil, "bronze no longer in utility")
    -- Heroism: equivalent abilities keep coverage on the retained category id.
    local heroismCat
    for _, cat in ipairs(RS.UTILITY_CATEGORIES) do
        if cat.id == "bloodlust" then
            heroismCat = cat
        end
    end
    assertEq(heroismCat and heroismCat.nameDefault, "Heroism", "visible name is Heroism")
    assertTrue(heroismCat and heroismCat.iconSpell == 32182, "heroism spell artwork reference")
    assertTrue(RS.CategoryCoveredBySelection(heroismCat, "SHAMAN", 262)
        and RS.CategoryCoveredBySelection(heroismCat, "MAGE", 62),
        "heroism equivalents still covered")
    -- One main matching several rules counts once per category.
    local one = RS.BuildSummary({ { mainClass = "WARLOCK", mainSpec = 266 } })
    assertEq(one.providerCounts.combat_res, 1, "one warlock counts once for combat res")
    assertEq(one.providerCounts.warlock_ritual, 1, "one warlock counts once for ritual")
end

---------------------------------------------------------------------------
-- Role totals aggregation
---------------------------------------------------------------------------
do
    local totals = RS.BuildRoleTotals({
        { mainClass = "MAGE", mainSpec = 62 },
        { mainClass = "PALADIN", mainSpec = 65, altClass = "WARRIOR", altSpec = 73 },
        { mainClass = "DRUID", mainSpec = 105 },
        { mainClass = "DEATHKNIGHT", mainSpec = 251 },
        { mainClass = "PRIEST", mainSpec = 999 }, -- invalid spec: skipped
        { mainClass = "HUNTER", mainSpec = 253, deleted = true }, -- deleted: skipped
    })
    assertEq(totals.ranged, 1, "fire mage counts as ranged DPS")
    assertEq(totals.healer, 2, "holy paladin and resto druid count as healers")
    assertEq(totals.tank, 0, "no tanks in fixture")
    assertEq(totals.melee, 1, "melee death knight counts as melee DPS")
    assertEq(totals.tank + totals.healer + totals.ranged + totals.melee, 4,
        "alternate selections never inflate role totals")
    assertEq(RS.SpecRole(1480), "ranged", "devourer counts as ranged DPS")
end

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
end
for i = 1, #RS.MAJOR_CATEGORIES do
    local cat = RS.MAJOR_CATEGORIES[i]
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
    ScrollFrame = {
        OnShow = true, OnHide = true, OnMouseWheel = true,
    },
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
    function r:SetAtlas(name, useAtlasSize)
        self._atlas = name
        self._texture = nil
        -- Mimic the client: useAtlasSize adopts the atlas's native dimensions.
        if useAtlasSize then
            local native = C_Texture and C_Texture.GetAtlasInfo
                and C_Texture.GetAtlasInfo(name)
            if native then
                self._w = native
                self._h = native
            end
        end
    end
    function r:SetTexCoord(l, r, t, b) self._texCoord = { l, r, t, b } end
    function r:SetDesaturated(v) self._desaturated = v end
    function r:SetVertexColor(cr, cg, cb) self._vertexColor = { cr, cg, cb } end
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
    function r:SetTextColor(cr, cg, cb) self._textColor = { cr, cg, cb } end
    function r:SetCursorPosition(p) self._cursor = p end
    function r:GetCursorPosition() return self._cursor or 0 end
    function r:SetFrameLevel(l) self._frameLevel = l end
    function r:GetFrameLevel() return self._frameLevel or 0 end
    function r:EnableMouse() end
    function r:RegisterForClicks() end
    function r:SetColorTexture() end
    function r:GetStringWidth() return #(self._text or "") * 7 end
    function r:SetScrollChild() end
    function r:GetHorizontalScroll() return 0 end
    function r:SetHorizontalScroll() end
    function r:EnableMouseWheel() end
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

-- Atlas registry for role-icon tests. Values are native square sizes in UI
-- pixels; the LFG role atlases are 64px natively, far larger than the 14px
-- role totals icons, so native-size adoption is observable.
SF.__testAtlases = {
    ["UI-LFG-RoleIcon-Tank-Micro-GroupFinder"] = 64,
    ["UI-LFG-RoleIcon-Healer-Micro-GroupFinder"] = 64,
    ["UI-LFG-RoleIcon-RangedDPS-Micro-GroupFinder"] = 64,
    ["UI-LFG-RoleIcon-DPS-Micro-GroupFinder"] = 64,
    ["UI-LFG-RoleIcon-Tank-Micro"] = 64,
    ["UI-LFG-RoleIcon-Healer-Micro"] = 64,
    ["UI-LFG-RoleIcon-RangedDPS-Micro"] = 64,
    ["UI-LFG-RoleIcon-DPS-Micro"] = 64,
    -- Names the first icon implementation used; kept so fallback ordering is
    -- exercised against the real atlas family.
    ["UI-LFG-RoleIcon-MeleeDPS-Micro"] = 64,
}
C_Texture = {
    GetAtlasInfo = function(name)
        local size = SF.__testAtlases and SF.__testAtlases[name]
        if size then
            return size, size
        end
        return nil
    end,
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
            _shown = true,
        }
        function section:Show() self._shown = true end
        function section:Hide() self._shown = false end
        function section:IsShown() return self._shown end
        function section:SetShown(v) self._shown = v and true or false end
        function section:SetMessage(text, kind)
            self._message = text
            self._messageKind = kind
        end
        function section:ClearMessage()
            self._message = nil
            self._messageKind = nil
        end
        function section:ReflowRows() end
        function section:_NotifyPageReflow() end
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
    function pb:Reflow()
        self.reflowCount = (self.reflowCount or 0) + 1
    end
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
load("SpectrumFederation/modules/UI/Settings/Widgets/TabBar.lua")
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

-- Focus deferral via a page-bound edit box (expanded edit row)
UIPage:Refresh(panel, { force = true })
local focusEntries = RS:GetSortedEntries(plan3)
assertTrue(#focusEntries >= 1, "saved entry available for focus-deferral check")
UIPage._SetEditingForTests({
    entryId = focusEntries[1].entryId,
    slot = "main",
    draft = {
        nickname = focusEntries[1].nickname,
        nicknameCommitted = true,
        classFile = nil,
        specId = nil,
        phase = "class",
    },
})
UIPage:Refresh(panel, { force = true })
boxes = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
assertTrue(#boxes >= 1, "expanded edit row nickname box present")
boxes[1]:SetFocus()
refreshBefore = UIPage._GetLifecycleCounters().refreshCount
UIPage:Refresh(panel)
assertEq(UIPage._GetLifecycleCounters().refreshCount, refreshBefore, "refresh deferred while page edit focused")
boxes[1]:ClearFocus()
UIPage._SetEditingForTests(nil)
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
    -- Collapsed rows are text-only; an expanded edit row still has edit boxes,
    -- which must be disabled while the plan is archived.
    local roEntries = RS:GetSortedEntries(planRO)
    assertTrue(#roEntries >= 1, "archived plan entry available")
    UIPage._SetEditingForTests({
        entryId = roEntries[1].entryId,
        slot = "main",
        draft = {
            nickname = roEntries[1].nickname,
            nicknameCommitted = true,
            classFile = nil,
            specId = nil,
            phase = "class",
        },
    })
    UIPage:Refresh(panel, { force = true })
    local roBoxes = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
    assertTrue(#roBoxes >= 1, "archived expanded nickname box present")
    assertTrue(not roBoxes[1]:IsEnabled(), "archived nickname is disabled")
    local beforeText = roBoxes[1]:GetText()
    roBoxes[1]:SetText("ShouldNotType", true)
    assertTrue(roBoxes[1]._lastUserEditRejected, "disabled box rejects user typing")
    assertEq(roBoxes[1]:GetText(), beforeText, "disabled box text unchanged by user SetText")
    UIPage._SetEditingForTests(nil)

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

    -- Ordinary member: others' collapsed rows are text-only with disabled spec
    -- icons; own Add Row stays enabled.
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
    assertEq(#UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname"), 0,
        "collapsed rows expose no nickname edit boxes")
    local othersIcons = UIPage._FindSpecButtonsForTests(panel.__sfRaidSignupEntriesHost, "main")
    assertTrue(#othersIcons >= 1, "other member spec icon visible")
    assertTrue(not othersIcons[1]:IsEnabled(), "other member spec icon disabled for member")
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
    -- Collapsed rows are text-only, so exercise the boxes via an expanded edit
    -- session; archiving clears it, so re-arm after each transition.
    ActAs("Alice-Garona", "Player-1-Alice")
    RS:SelectPlan(planRO)
    UIPage:Refresh(panel, { force = true })
    local revEntries = RS:GetSortedEntries(planRO)
    assertTrue(#revEntries >= 1, "planRO entry available for reverse check")
    local function ArmEditSession()
        UIPage._SetEditingForTests({
            entryId = revEntries[1].entryId,
            slot = "main",
            draft = {
                nickname = revEntries[1].nickname,
                nicknameCommitted = true,
                classFile = nil,
                specId = nil,
                phase = "class",
            },
        })
        UIPage:Refresh(panel, { force = true })
    end
    ArmEditSession()
    local editableAgain = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
    assertTrue(#editableAgain >= 1, "expanded nickname box before re-archive")
    assertTrue(editableAgain[1]:IsEnabled(), "open plan nickname enabled for owner")
    assertEq(select(1, RS:SetPlanArchived(planRO, true)), "accepted", "re-archive for reverse transition")
    ArmEditSession()
    local againRO = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost, "nickname")
    assertTrue(#againRO >= 1, "nickname boxes after re-archive")
    for i = 1, #againRO do
        assertTrue(not againRO[i]:IsEnabled(), "re-archived nickname disabled again")
        local prior = againRO[i]:GetText()
        againRO[i]:SetText("Nope", true)
        assertTrue(againRO[i]._lastUserEditRejected, "re-archived rejects user typing")
        assertEq(againRO[i]:GetText(), prior, "re-archived text unchanged")
    end
    UIPage._SetEditingForTests(nil)
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

    -- Local mutation on an idle index must not arm a redundant follow-up pass.
    driveProvider(8, 512)
    assertTrue(provEntry.index.buildComplete and not provEntry.index.dirty, "index idle before follow-up check")
    provEntry._reconcileFollowUp = nil
    RS.NotifyLocalDurableChange("local")
    assertEq(provEntry._reconcileFollowUp, nil, "idle mutation arms no reconcile follow-up")
    driveProvider(8, 512)
    assertTrue(provEntry.index.buildComplete and not provEntry.index.dirty, "index completes after idle mutation")
    assertTrue(not provEntry.indexFailed, "idle mutation rebuild did not fail index")

    -- Consecutive idle mutations stay clean (no double full pass per mutation).
    RS.NotifyLocalDurableChange("local")
    assertEq(provEntry._reconcileFollowUp, nil, "second idle mutation arms no follow-up")
    driveProvider(8, 4096)
    assertTrue(provEntry.index.buildComplete and not provEntry.index.dirty, "index completes after second mutation")
end

---------------------------------------------------------------------------
-- UI: Status removal, officer-only Manage tab, class summary layout
---------------------------------------------------------------------------

do
    ActAs("Alice-Garona", "Player-1-Alice")
    world.impersonationActive = false
    UIPage._ResetSessionForTests()

    local function NewPagePanel()
        local p = CreateFrame("Frame", nil, nil)
        function p:IsShown() return true end
        function p:HookScript(name, fn)
            self._scripts = self._scripts or {}
            self._scripts[name] = fn
        end
        return p
    end

    local tabPlanStatus = select(1, RS:CreatePlan("Tab Layout Plan"))
    assertEq(tabPlanStatus, "accepted", "officer creates tab test plan")
    local tabPlanId
    for _, p in ipairs(RS:GetSortedPlans(true)) do
        if p.name == "Tab Layout Plan" and not p.archived then
            tabPlanId = p.planId
            break
        end
    end
    assertTrue(tabPlanId ~= nil, "tab test plan id found")
    RS:SelectPlan(tabPlanId)

    -- Officer view: default Signup tab, Manage hidden sections
    local panel = NewPagePanel()
    UIPage:Build(panel)
    assertEq(UIPage._GetViewForTests(), "signup", "default view is signup")
    local bar = UIPage._GetTabBarForTests(panel)
    assertTrue(bar ~= nil, "officer gets tab bar")
    assertTrue(bar:IsShown(), "tab bar visible for officer")
    assertEq(#bar.tabs, 2, "two tabs for officer")
    assertEq(bar.tabs[1].id, "signup", "first tab is signup")
    assertEq(bar.tabs[2].id, "manage", "second tab is manage")
    local vis = UIPage._GetSectionVisibilityForTests(panel)
    assertEq(vis.raidSignupPlanSelect, true, "signup plan selector visible")
    assertEq(vis.raidSignupBoard, true, "signup board visible in signup view")
    assertEq(vis.raidSignupPlans, false, "manage section hidden in signup view")
    assertEq(vis.raidSignupStatus, nil, "status/access section removed")

    -- Switch to Manage; shared selected plan
    bar.buttons[2]:Click()
    assertEq(UIPage._GetViewForTests(), "manage", "manage tab selects manage view")
    vis = UIPage._GetSectionVisibilityForTests(panel)
    assertEq(vis.raidSignupPlans, true, "roster plans visible in manage view")
    assertEq(vis.raidSignupPlanSelect, false, "signup selector hidden in manage view")
    assertEq(vis.raidSignupBoard, false, "signup board hidden in manage view")
    local snap = UIPage._GetDefinitionSnapshotForTests()
    assertEq(snap.selectedId, tabPlanId, "manage view shares selected plan")
    assertEq(snap.canManagePlans, true, "officer capability retained")

    -- Rename draft scoped to selection survives tab switches
    UIPage._SetRenamePlanNameForTests("Renamed Tab Plan")
    bar.buttons[1]:Click()
    assertEq(UIPage._GetViewForTests(), "signup", "back to signup view")
    assertEq(UIPage._GetRenamePlanNameForTests(), "Renamed Tab Plan", "rename text survives switch")
    bar.buttons[2]:Click()
    assertEq(UIPage._GetRenamePlanNameForTests(), "Renamed Tab Plan", "rename text intact in manage")
    bar.buttons[1]:Click()

    -- Incomplete draft survives view changes and is never persisted
    UIPage._ResetSessionForTests()
    local entriesBefore = #RS:GetSortedEntries(tabPlanId)
    local draft = RS.MakeDraft(tabPlanId)
    RS.UpdateDraftField(draft, "classFile", "MAGE")
    RS.UpdateDraftField(draft, "specId", 62)
    UIPage._SetDraftForTests(draft)
    assertEq(RS.DraftReadyToPersist(draft), false, "test draft is incomplete")
    bar.buttons[2]:Click()
    assertTrue(UIPage._GetDraftForTests() ~= nil, "incomplete draft survives manage switch")
    bar.buttons[1]:Click()
    assertTrue(UIPage._GetDraftForTests() ~= nil, "incomplete draft survives signup return")
    assertEq(#RS:GetSortedEntries(tabPlanId), entriesBefore, "view switches never persist drafts")

    -- Repeated switching/reopening: no widget churn, tab bar reused
    UIPage:Refresh(panel, { force = true })
    local life = UIPage._GetLifecycleCounters()
    local framesBefore = life.frameCreateCount
    local regionsBefore = life.regionCreateCount
    local rebuildsBefore = life.fullRebuildCount
    bar.buttons[2]:Click()
    bar.buttons[1]:Click()
    bar.buttons[2]:Click()
    bar.buttons[1]:Click()
    life = UIPage._GetLifecycleCounters()
    assertEq(life.fullRebuildCount, rebuildsBefore, "tab switches never rebuild page")
    assertEq(life.frameCreateCount, framesBefore, "tab switches create no frames")
    assertEq(life.regionCreateCount, regionsBefore, "tab switches create no regions")
    UIPage:Build(panel)
    assertTrue(UIPage._GetTabBarForTests(panel) == bar, "tab bar reused across rebuild")
    UIPage._ResetSessionForTests()
    UIPage:Refresh(panel, { force = true })

    -- Permission loss while Manage is open: safe fallback to Signup, tab hidden
    bar.buttons[2]:Click()
    assertEq(UIPage._GetViewForTests(), "manage", "manage view active before loss")
    world.impersonationActive = true
    UIPage:Refresh(panel, { force = true })
    assertEq(UIPage._GetViewForTests(), "signup", "eligibility loss returns to signup view")
    assertTrue(not bar:IsShown(), "tab bar hidden when manage eligibility lost")
    vis = UIPage._GetSectionVisibilityForTests(panel)
    assertEq(vis.raidSignupPlans, false, "manage section hidden after eligibility loss")
    assertEq(vis.raidSignupBoard, true, "signup view still shown after eligibility loss")
    world.impersonationActive = false
    UIPage:Refresh(panel, { force = true })

    -- Member: no tabs, signup view with plan selector and boards
    ActAs("Carol-Garona", "Player-1-Carol")
    UIPage._ResetSessionForTests()
    local memberPanel = NewPagePanel()
    UIPage:Build(memberPanel)
    assertEq(UIPage._GetViewForTests(), "signup", "member default view is signup")
    assertTrue(UIPage._GetTabBarForTests(memberPanel) == nil, "member gets no tab bar")
    vis = UIPage._GetSectionVisibilityForTests(memberPanel)
    assertEq(vis.raidSignupPlanSelect, true, "member plan selector visible")
    assertEq(vis.raidSignupBoard, true, "member signup board visible")
    assertEq(vis.raidSignupPlans, false, "member never sees manage section")
    RS:SelectPlan(tabPlanId)
    UIPage:Refresh(memberPanel, { force = true })
    snap = UIPage._GetDefinitionSnapshotForTests()
    assertEq(snap.selectedId, tabPlanId, "member selects roster plan")
    assertEq(snap.canManagePlans, false, "member cannot manage plans")
    assertEq(snap.canCreateEntry, true, "member keeps signup access")
    assertTrue(memberPanel.__sfRaidSignupEntriesHost ~= nil, "member entries board painted")

    -- Class summary: every class once, three columns, zero counts, content height
    local host = memberPanel.__sfRaidSignupSummaryHost
    assertTrue(host ~= nil, "summary host painted for member")
    local counts = host.__sfClassCounts
    local seen, n = {}, 0
    for classFile, fs in pairs(counts) do
        n = n + 1
        seen[classFile] = true
        assertEq(fs:GetText(), "0", "zero count shown for " .. tostring(classFile))
    end
    assertEq(n, #RS.CLASS_ORDER, "every class shown exactly once")
    for _, classFile in ipairs(RS.CLASS_ORDER) do
        assertTrue(seen[classFile], "class present in summary: " .. tostring(classFile))
    end
    -- Compact sidebar grid: row-major, width-adaptive columns, content height
    local classXs = {}
    local classIconCount = 0
    for _, btn in pairs(host.__sfClassIcons or {}) do
        classIconCount = classIconCount + 1
        for _, pt in ipairs(btn._points or {}) do
            if pt[1] == "TOPLEFT" then
                classXs[pt[4]] = (classXs[pt[4]] or 0) + 1
            end
        end
    end
    assertEq(classIconCount, #RS.CLASS_ORDER, "one class icon button per class")
    do
        -- Stub: board width falls back to 720, sidebar gets the remaining column.
        local w = 720 - math.floor(720 * 0.62) - 16
        local classPitch = 22 + 6 + 24 + 8
        local cols = math.max(1, math.min(5, math.floor((w + 8) / classPitch)))
        local classRows = math.ceil(#RS.CLASS_ORDER / cols)
        local tokenRows = math.max(1, math.ceil(#(RS.ARMOR_TOKEN_GROUPS or {}) / cols))
        local iconPitch = 22 + 8
        local iconCols = math.max(1, math.min(5, math.floor((w + 8) / iconPitch)))
        local majorRows = math.max(1, math.ceil(#RS.MAJOR_CATEGORIES / iconCols))
        local utilityRows = math.max(1, math.ceil(#RS.UTILITY_CATEGORIES / iconCols))
        -- Mirrors PaintSummary group geometry: title, 20px gap, icon rows,
        -- 8px gap to the next heading below the actual grid bottom.
        local function gridBottom(titleY, rows)
            return titleY - 20 - (rows - 1) * 26 - 22
        end
        -- Role totals lead the sidebar: one 15px line plus a 10px gap.
        local classTitleY = -(15 + 10)
        local tokenTitleY = gridBottom(classTitleY, classRows) - 8
        local majorTitleY = gridBottom(tokenTitleY, tokenRows) - 8
        local utilityTitleY = gridBottom(majorTitleY, majorRows) - 8
        local expectedH = -gridBottom(utilityTitleY, utilityRows) + 4
        assertEq(host:GetHeight(), expectedH, "summary height sized to stacked groups")
        assertEq(classXs[0], classRows, "first grid column holds one icon per row")
        assertTrue(memberPanel.__sfRaidSignupBoardRow ~= nil, "board row exists")
        assertTrue((memberPanel.__sfRaidSignupBoardRow:GetHeight() or 0) > 0, "board row sized")
    end

    -- Board chrome: headings, + button, column headers, role totals, status line
    assertTrue(memberPanel.__sfRaidSignupAddBtn ~= nil, "add-signup + button exists")
    assertTrue(memberPanel.__sfRaidSignupNickHeader ~= nil, "Nickname column header exists")
    assertTrue(memberPanel.__sfRaidSignupMainHeader ~= nil, "Main column header exists")
    assertTrue(memberPanel.__sfRaidSignupAltHeader ~= nil, "Alt column header exists")
    assertEq(memberPanel.__sfRaidSignupMainHeader:GetText(), "Main", "Main header text")
    assertEq(memberPanel.__sfRaidSignupAltHeader:GetText(), "Alt", "Alt header text")
    assertTrue(memberPanel.__sfRaidSignupStatusFs ~= nil, "status line beneath list exists")
    local role = memberPanel.__sfRaidSignupRole
    assertTrue(role ~= nil, "role totals row exists")
    for _, key in ipairs({ "tank", "healer", "ranged", "melee" }) do
        assertTrue(role[key] and role[key].count, "role total slot present: " .. key)
    end
    assertEq(role.tank.count:GetText(), "0", "empty plan tank total is zero")
    assertEq(role.ranged.count:GetText(), "0", "empty plan ranged total is zero")
    -- Signups heading divider ends just before the + button, anchored to it.
    local dividerAnchored = false
    for _, pt in ipairs((memberPanel.__sfRaidSignupLeftLine and memberPanel.__sfRaidSignupLeftLine._points) or {}) do
        if pt[1] == "TOPRIGHT" and pt[2] == memberPanel.__sfRaidSignupAddBtn then
            dividerAnchored = true
        end
    end
    assertTrue(dividerAnchored, "Signups divider anchored to the + button")

    -- Main-only counts update; alternatives excluded
    local upsertStatus = select(1, RS:UpsertEntry({
        planId = tabPlanId,
        nickname = "CountMain",
        mainClass = "MAGE",
        mainSpec = 62,
        altClass = "WARRIOR",
        altSpec = 71,
    }))
    assertEq(upsertStatus, "accepted", "member entry with alternative created")
    UIPage:Refresh(memberPanel, { force = true })
    counts = memberPanel.__sfRaidSignupSummaryHost.__sfClassCounts
    assertEq(counts.MAGE:GetText(), "1", "main class counted in summary")
    assertEq(counts.WARRIOR:GetText(), "0", "alternative class excluded from summary counts")
    do
        local roleNow = memberPanel.__sfRaidSignupRole
        local totalsNow = RS.BuildRoleTotals(RS:GetSortedEntries(tabPlanId))
        for _, key in ipairs({ "tank", "healer", "ranged", "melee" }) do
            assertEq(roleNow[key].count:GetText(), tostring(totalsNow[key] or 0),
                "role total line matches aggregation: " .. key)
        end
        assertEq(roleNow.ranged.count:GetText(), "1", "fire mage signup counts as ranged DPS")
    end

    -- Review repairs: scroll offset, create-plan draft safety, plan-bound
    -- draft rendering, localized class names, expanded-row layout.
    local function LastScrollTopY(scroll)
        local y = nil
        for _, pt in ipairs((scroll and scroll._points) or {}) do
            if pt[1] == "TOPLEFT" then
                y = pt[5]
            end
        end
        return y
    end

    ActAs("Alice-Garona", "Player-1-Alice")
    UIPage._ResetSessionForTests()
    RS:SelectPlan(tabPlanId)
    UIPage:Refresh(panel, { force = true })
    local officerScroll = panel.__sfPageBuilder and panel.__sfPageBuilder.scrollFrame
    assertTrue(officerScroll ~= nil, "officer page builder scroll frame exists")
    local officerScrollY = LastScrollTopY(officerScroll)
    assertTrue(officerScrollY ~= nil and officerScrollY < 0,
        "officer scroll content starts below the tab strip")

    ActAs("Carol-Garona", "Player-1-Carol")
    UIPage._ResetSessionForTests()
    RS:SelectPlan(tabPlanId)
    UIPage:Refresh(memberPanel, { force = true })
    local memberScroll = memberPanel.__sfPageBuilder and memberPanel.__sfPageBuilder.scrollFrame
    local memberScrollY = LastScrollTopY(memberScroll)
    assertEq(memberScrollY, 0, "member scroll content starts at panel top")

    -- Localized class display names with token fallback
    local savedCreatureInfo = C_CreatureInfo
    C_CreatureInfo = {
        GetClassInfo = function(classId)
            return { classID = classId, className = "Localized" .. classId, classFile = "TOKEN" }
        end,
    }
    assertEq(RS.ClassDisplayName("MAGE"), "Localized8", "class display name localized")
    assertEq(RS.ClassDisplayName("mage"), "Localized8", "class display name normalizes token")
    C_CreatureInfo = nil
    assertEq(RS.ClassDisplayName("MAGE"), "MAGE", "class display name falls back to token")
    C_CreatureInfo = savedCreatureInfo

    -- Creating a plan discards an in-progress signup draft instead of leaking
    -- it into the previously selected roster.
    ActAs("Alice-Garona", "Player-1-Alice")
    UIPage._ResetSessionForTests()
    RS:SelectPlan(tabPlanId)
    local draftForCreate = RS.MakeDraft(tabPlanId)
    RS.UpdateDraftField(draftForCreate, "nickname", "Unsaved Draft")
    UIPage._SetDraftForTests(draftForCreate)
    local entriesBeforeCreate = #RS:GetSortedEntries(tabPlanId)
    UIPage._SubmitCreatePlanForTests("Created With Draft")
    assertTrue(UIPage._GetDraftForTests() == nil, "create plan discards in-progress draft")
    local snapAfterCreate = UIPage._GetDefinitionSnapshotForTests()
    assertTrue(snapAfterCreate.selectedId ~= tabPlanId, "create plan selects the new roster")
    assertEq(#RS:GetSortedEntries(tabPlanId), entriesBeforeCreate,
        "create plan never persists the stale draft")
    local createdPlanId = snapAfterCreate.selectedId

    -- Defense in depth: a draft bound to another plan never renders.
    local function CountDraftRows(host)
        local n = 0
        if not host then
            return n
        end
        for _, child in ipairs({ host:GetChildren() }) do
            -- Draft/editor rows are sized from their stacked content (>26px);
            -- collapsed rows are exactly 26.
            if child._h and child._h > 26 and child.IsShown and child:IsShown() then
                n = n + 1
            end
        end
        return n
    end
    UIPage._SetDraftForTests(RS.MakeDraft(tabPlanId))
    UIPage:Refresh(panel, { force = true })
    assertEq(CountDraftRows(panel.__sfRaidSignupEntriesHost), 0,
        "foreign-plan draft is not painted")
    UIPage._SetDraftForTests(RS.MakeDraft(createdPlanId))
    UIPage:Refresh(panel, { force = true })
    assertEq(CountDraftRows(panel.__sfRaidSignupEntriesHost), 1,
        "matching-plan draft is painted")
    UIPage._SetDraftForTests(nil)

    -- Localized class names reach entry tooltips and the class picker.
    C_CreatureInfo = {
        GetClassInfo = function(classId)
            return { classID = classId, className = "Localized" .. classId, classFile = "TOKEN" }
        end,
    }
    ActAs("Carol-Garona", "Player-1-Carol")
    UIPage._ResetSessionForTests()
    RS:SelectPlan(tabPlanId)
    UIPage:Refresh(memberPanel, { force = true })
    local entryHost = memberPanel.__sfRaidSignupEntriesHost
    local mainBtns = UIPage._FindSpecButtonsForTests(entryHost, "main")
    assertTrue(#mainBtns >= 1, "main spec button present for tooltip check")
    assertEq(mainBtns[1].tooltipTitle, "Main", "main icon tooltip identifies Main")
    assertEq(mainBtns[1].tooltipText, "Localized8 · Arcane",
        "main tooltip uses localized class name")
    local altBtns = UIPage._FindSpecButtonsForTests(entryHost, "alt")
    assertTrue(#altBtns >= 1, "alt spec button present for tooltip check")
    assertEq(altBtns[1].tooltipTitle, "Alt", "alt icon tooltip identifies Alt")
    assertEq(altBtns[1].tooltipText, "Localized1 · Arms",
        "alt tooltip uses localized class name")
    local function FindBySize(root, w, h)
        local found = nil
        local function walk(f)
            if found or not f then
                return
            end
            if f._w == w and f._h == h then
                found = f
                return
            end
            for _, k in ipairs({ f:GetChildren() }) do
                walk(k)
            end
        end
        walk(root)
        return found
    end
    do
    -- Rows expose fontstrings as regions, so walks must cover both children
    -- and regions to find labels and collapsed-row text.
    local function FindFontStringByText(root, text)
        local found = nil
        local function walk(f)
            if found or not f then
                return
            end
            if f.GetObjectType and f:GetObjectType() == "FontString"
                and f.GetText and f:GetText() == text then
                found = f
                return
            end
            if f.GetChildren then
                for _, k in ipairs({ f:GetChildren() }) do
                    walk(k)
                end
            end
            if f.GetRegions then
                for _, r in ipairs({ f:GetRegions() }) do
                    walk(r)
                end
            end
        end
        walk(root)
        return found
    end
    local function AnchorTarget(widget, pointType)
        for _, pt in ipairs(widget._points or {}) do
            if pt[1] == pointType then
                return pt[2]
            end
        end
        return nil
    end

    do
    -- Collapsed rows render fixed Main / Alt icon columns: class-colored
    -- nickname, spec icons with Main/Alt tooltips, notes — no standalone spec
    -- text, and a muted dash in the Alt column when no alternate is selected.
    local collapsedEntries = RS:GetSortedEntries(tabPlanId)
    assertTrue(#collapsedEntries >= 1, "entry available for collapsed row check")
    local collapsedTarget = collapsedEntries[1]
    assertEq(#UIPage._FindEditBoxesForTests(entryHost, "nickname"), 0,
        "collapsed rows have no nickname edit box")
    local collapsedName = FindFontStringByText(entryHost, collapsedTarget.nickname)
    assertTrue(collapsedName ~= nil, "collapsed row shows nickname as text")
    local classColor = SF.WOW_CLASSES[collapsedTarget.mainClass]
        and SF.WOW_CLASSES[collapsedTarget.mainClass].colorCode
    assertTrue(classColor ~= nil, "class color available for entry class")
    local nameColor = collapsedName._textColor
    assertTrue(nameColor ~= nil, "collapsed name has a text color")
    assertTrue(math.abs(nameColor[1] - classColor.r) < 0.001
        and math.abs(nameColor[2] - classColor.g) < 0.001
        and math.abs(nameColor[3] - classColor.b) < 0.001,
        "collapsed name uses class color")
    if collapsedTarget.notes and collapsedTarget.notes ~= "" then
        assertTrue(FindFontStringByText(entryHost, collapsedTarget.notes) ~= nil,
            "collapsed row shows notes text")
    end
    if collapsedTarget.altClass and collapsedTarget.altSpec then
        local altSpecName = RS.SpecDisplayName and RS.SpecDisplayName(collapsedTarget.altSpec)
        if altSpecName then
            assertTrue(FindFontStringByText(entryHost, altSpecName) == nil,
                "collapsed row no longer shows standalone alt spec name")
        end
    end
    local noAltEntry = nil
    for _, e in ipairs(collapsedEntries) do
        if not (e.altClass and e.altSpec) then
            noAltEntry = e
            break
        end
    end
    if noAltEntry then
        assertTrue(FindFontStringByText(entryHost, "—") ~= nil,
            "collapsed row without alt shows muted dash in Alt column")
    end
    end

    do
    -- Expanded alt row: labeled fields stacked Name / Class / Spec / Notes,
    -- each control anchored right of its label.
    local entriesForAlt = RS:GetSortedEntries(tabPlanId)
    assertTrue(#entriesForAlt >= 1, "entry available for alt row check")
    UIPage._SetAltDraftForTests({
        entryId = entriesForAlt[1].entryId,
        draft = RS.MakeAltDraft(entriesForAlt[1]),
    })
    UIPage._SetDraftForTests(nil)
    UIPage:Refresh(memberPanel, { force = true })
    local nickBoxes = UIPage._FindEditBoxesForTests(entryHost, "nickname")
    assertEq(#nickBoxes, 1, "exactly one entry nickname box in alt row check")
    local nickBox = nickBoxes[1]
    local nameLabel = FindFontStringByText(entryHost, "Name")
    assertTrue(nameLabel ~= nil, "Name label present in expanded row")
    assertTrue(AnchorTarget(nickBox, "TOPLEFT") == nameLabel,
        "nickname box sits right of the Name label")
    local classLabel = FindFontStringByText(entryHost, "Class / Spec")
    assertTrue(classLabel ~= nil, "Class / Spec label present in expanded row")
    -- The picker width is derived from the column geometry, so find it by its
    -- anchor to the Class / Spec label rather than a fixed size.
    local altPicker = nil
    local function FindAnchoredTopLeft(root, target)
        local found = nil
        local function walk(f)
            if found or not f then
                return
            end
            if AnchorTarget(f, "TOPLEFT") == target then
                found = f
                return
            end
            if f.GetChildren then
                for _, k in ipairs({ f:GetChildren() }) do
                    walk(k)
                end
            end
        end
        walk(root)
        return found
    end
    altPicker = FindAnchoredTopLeft(entryHost, classLabel)
    assertTrue(altPicker ~= nil, "alt class picker painted")
    local notesLabel = FindFontStringByText(entryHost, "Notes")
    assertTrue(notesLabel ~= nil, "Notes label present in expanded row")
    local notesBoxes = UIPage._FindEditBoxesForTests(entryHost, "notes")
    assertEq(#notesBoxes, 1, "notes box present in expanded row")
    assertTrue(AnchorTarget(notesBoxes[1], "TOPLEFT") == notesLabel,
        "notes box sits right of the Notes label")
    local doneBtn = nil
    local function FindDoneButton(root)
        local function walk(f)
            if doneBtn or not f then
                return
            end
            if f.GetObjectType and f:GetObjectType() == "Button"
                and f.GetText and f:GetText() == "Done" then
                doneBtn = f
                return
            end
            if f.GetChildren then
                for _, k in ipairs({ f:GetChildren() }) do
                    walk(k)
                end
            end
        end
        walk(root)
    end
    FindDoneButton(entryHost)
    assertTrue(doneBtn ~= nil, "Done button present in expanded row")
    -- Done saves pending Name/Notes edits, then leaves edit mode.
    local nickBeforeDone = entriesForAlt[1].nickname
    if notesBoxes[1]:IsEnabled() then
        SimulateUserType(notesBoxes[1], "Saved via Done")
    else
        notesBoxes[1]:SetText("Saved via Done", true)
    end
    doneBtn:GetScript("OnClick")(doneBtn)
    assertTrue(UIPage._GetAltDraftForTests() == nil, "Done clears the alt draft")
    UIPage:Refresh(memberPanel, { force = true })
    local afterDone = RS:GetSortedEntries(tabPlanId)[1]
    assertEq(afterDone.nickname, nickBeforeDone, "Done does not rename the entry")
    assertEq(afterDone.notes or "", "Saved via Done", "Done persists pending notes")
    -- Re-arm the alt picker for the localized class-name checks below.
    UIPage._SetAltDraftForTests({
        entryId = entriesForAlt[1].entryId,
        draft = RS.MakeAltDraft(entriesForAlt[1]),
    })
    UIPage:Refresh(memberPanel, { force = true })
    end
    end

    -- The class picker itself shows localized class names.
    local classPickerBtn = nil
    local function FindClassPickerBtn(root)
        local function walk(f)
            if classPickerBtn or not f then
                return
            end
            if f.tooltipTitle == "Localized8" then
                classPickerBtn = f
                return
            end
            for _, k in ipairs({ f:GetChildren() }) do
                walk(k)
            end
        end
        walk(root)
    end
    FindClassPickerBtn(entryHost)
    assertTrue(classPickerBtn ~= nil, "class picker button uses localized class name")
    UIPage._SetAltDraftForTests(nil)
    C_CreatureInfo = savedCreatureInfo
    ActAs("Alice-Garona", "Player-1-Alice")
    UIPage._ResetSessionForTests()
    RS:SelectPlan(tabPlanId)
    UIPage:Refresh(panel, { force = true })

local function RaidSignupLayoutRegressionTests(panel, UIPage, RS, tabPlanId)
    -- Layout defect repairs: width-derived columns, measured role totals,
    -- summary rebuilds on small resizes, and content-sized draft/editor rows.
    local boardHost = panel.__sfRaidSignupBoardHost
    assertTrue(boardHost ~= nil, "board host exists for layout checks")
    local entriesHost = panel.__sfRaidSignupEntriesHost
    local summaryHost = panel.__sfRaidSignupSummaryHost

    local function TopLeftOffset(widget)
        for _, pt in ipairs((widget and widget._points) or {}) do
            if pt[1] == "TOPLEFT" and pt[3] == "TOPLEFT" then
                return pt[4], pt[5]
            end
        end
        return nil, nil
    end
    local function FindFontStringByText(root, text)
        local found = nil
        local function walk(f)
            if found or not f then
                return
            end
            if f.GetObjectType and f:GetObjectType() == "FontString"
                and f.GetText and f:GetText() == text then
                found = f
                return
            end
            if f.GetChildren then
                for _, k in ipairs({ f:GetChildren() }) do
                    walk(k)
                end
            end
            if f.GetRegions then
                for _, r in ipairs({ f:GetRegions() }) do
                    walk(r)
                end
            end
        end
        walk(root)
        return found
    end
    local function FindAnchoredTopLeft(root, target)
        local found = nil
        local function walk(f)
            if found or not f then
                return
            end
            for _, pt in ipairs((f._points) or {}) do
                if pt[1] == "TOPLEFT" and pt[2] == target then
                    found = f
                    return
                end
            end
            if f.GetChildren then
                for _, k in ipairs({ f:GetChildren() }) do
                    walk(k)
                end
            end
        end
        walk(root)
        return found
    end

    -- 1. Narrow signup column (~340px): columns and actions get separate space.
    boardHost._w = 548 -- real, already-sized host: left column ~= 339px
    UIPage:Refresh(panel, { force = true })
    local narrowGeom = panel.__sfEntryGeom
    assertTrue(narrowGeom ~= nil, "row geometry computed from board width")
    local contentRight = narrowGeom.leftW - narrowGeom.rightReserve
    assertTrue(narrowGeom.mainX + 22 <= contentRight,
        "Main column clears the reserved action group at narrow width")
    assertTrue(narrowGeom.altX + 22 <= contentRight,
        "Alt column clears the reserved action group at narrow width")
    assertTrue(narrowGeom.notesX < contentRight,
        "notes start left of the action group at narrow width")
    assertTrue(narrowGeom.mainX < narrowGeom.altX and narrowGeom.altX < narrowGeom.notesX,
        "column order Nickname/Main/Alt/Notes preserved")
    local headerX, headerY = TopLeftOffset(panel.__sfRaidSignupMainHeader)
    assertEq(headerX, narrowGeom.mainX, "Main header shares row geometry")
    local altHeaderX = TopLeftOffset(panel.__sfRaidSignupAltHeader)
    assertEq(altHeaderX, narrowGeom.altX, "Alt header shares row geometry")
    local mainIcons = UIPage._FindSpecButtonsForTests(entriesHost, "main")
    assertTrue(#mainIcons >= 1, "collapsed main icons present for geometry check")
    local iconX = nil
    for _, pt in ipairs(mainIcons[1]._points or {}) do
        if pt[1] == "LEFT" then
            iconX = pt[4]
        end
    end
    assertEq(iconX, narrowGeom.mainX, "collapsed Main icon matches header column")

    -- Nickname and notes are bounded by rendered width, not character count.
    local longNick = string.rep("n", 40)
    RS:UpsertEntry({ planId = tabPlanId, nickname = longNick,
        mainClass = "MAGE", mainSpec = 62 })
    UIPage:Refresh(panel, { force = true })
    local clippedNick = nil
    local function FindClipped(root)
        local function walk(f)
            if clippedNick or not f then
                return
            end
            if f.GetObjectType and f:GetObjectType() == "FontString"
                and f.GetText and f:GetText():sub(1, 1) == "n"
                and #f:GetText() < 40 and f:GetText():sub(-3) == "…" then
                clippedNick = f
                return
            end
            if f.GetChildren then
                for _, k in ipairs({ f:GetChildren() }) do
                    walk(k)
                end
            end
            if f.GetRegions then
                for _, r in ipairs({ f:GetRegions() }) do
                    walk(r)
                end
            end
        end
        walk(root)
    end
    FindClipped(entriesHost)
    assertTrue(clippedNick ~= nil, "long nickname clipped with ellipsis")
    assertTrue((clippedNick:GetStringWidth() or 0) <= narrowGeom.nickW,
        "clipped nickname fits its column width")
    assertTrue(narrowGeom.nickW >= 48 and narrowGeom.nickW <= 80,
        "nickname column is compact and bounded")
    assertTrue((clippedNick:GetStringWidth() or 0) + 4 <= narrowGeom.mainX - 4,
        "clipped nickname clears the Main column")
    -- Truncated nicknames keep the full stored value on hover.
    local nickHover = nil
    local function FindNickHover(root)
        local function walk(f)
            if nickHover or not f then
                return
            end
            if f.__sfHoverText == longNick then
                nickHover = f
                return
            end
            if f.GetChildren then
                for _, k in ipairs({ f:GetChildren() }) do
                    walk(k)
                end
            end
        end
        walk(root)
    end
    FindNickHover(entriesHost)
    assertTrue(nickHover ~= nil, "truncated nickname shows its full value on hover")

    -- 2. Role totals: compact icon+count groups on one line at supported
    -- widths, multi-digit counts, distinct icons, full-name hover tooltips.
    boardHost._w = nil -- back to the 720 fallback (left column 446px)
    for i = 1, 10 do
        RS:UpsertEntry({ planId = tabPlanId, nickname = "Tot" .. i,
            mainClass = "MAGE", mainSpec = 62 })
    end
    UIPage:Refresh(panel, { force = true })
    local rangedCount = panel.__sfRaidSignupRole.ranged.count:GetText()
    assertTrue(#rangedCount >= 2, "multi-digit role total rendered")
    local function DistinctTotalLines()
        local ys = {}
        for _, key in ipairs({ "tank", "healer", "ranged", "melee" }) do
            local _, y = TopLeftOffset(panel.__sfRaidSignupRole[key].count)
            if y ~= nil then
                ys[y] = true
            end
        end
        local n = 0
        for _ in pairs(ys) do
            n = n + 1
        end
        return n
    end
    assertEq(DistinctTotalLines(), 1, "multi-digit totals stay on one line at full width")
    assertEq(panel.__sfEntryGeom.nickW, narrowGeom.nickW,
        "nickname column width is consistent across window widths")
    local wideHeaderY = select(2, TopLeftOffset(panel.__sfRaidSignupMainHeader))
    assertEq(wideHeaderY, -26, "headings sit beneath the Signups divider without role totals")

    -- Icon+count structure: distinct icons, zero counts visible, localized names.
    local roleOrder = { "tank", "healer", "ranged", "melee" }
    local expectedNames = {
        tank = "Tanks", healer = "Healers", ranged = "Ranged DPS", melee = "Melee DPS",
    }
    local expectedAtlases = {
        tank = "UI-LFG-RoleIcon-Tank-Micro-GroupFinder",
        healer = "UI-LFG-RoleIcon-Healer-Micro-GroupFinder",
        ranged = "UI-LFG-RoleIcon-RangedDPS-Micro-GroupFinder",
        melee = "UI-LFG-RoleIcon-DPS-Micro-GroupFinder",
    }
    local seenArt = {}
    for _, key in ipairs(roleOrder) do
        local slot = panel.__sfRaidSignupRole[key]
        assertTrue(slot ~= nil and slot.icon ~= nil, "role icon present: " .. key)
        assertTrue(slot and slot.count ~= nil, "role count present: " .. key)
        assertTrue(slot and slot.hover ~= nil, "role hover region present: " .. key)
        assertEq(slot and slot.name, expectedNames[key], "localized role name: " .. key)
        assertEq(slot and slot.icon._atlas, expectedAtlases[key],
            "role icon uses the circular group-finder atlas: " .. key)
        -- The atlas's native size (64px in the stub) must not survive: the
        -- layout budgets 14px, so the final size is enforced after SetAtlas.
        assertEq(slot and slot.icon.GetWidth and slot.icon:GetWidth(), 14,
            "role icon final width is 14px: " .. key)
        assertEq(slot and slot.icon.GetHeight and slot.icon:GetHeight(), 14,
            "role icon final height is 14px: " .. key)
        local art = slot and slot.icon and (slot.icon._atlas or slot.icon._texture)
        assertTrue(type(art) == "string" and art ~= "", "role icon has artwork: " .. key)
        if type(art) == "string" and art ~= "" then
            assertTrue(seenArt[art] == nil, "role icons are distinct: " .. key)
            seenArt[art] = true
        end
        assertTrue(slot and slot.count and slot.count:GetText() ~= "",
            "zero counts still render: " .. key)
    end
    -- Hovering either the icon or its count shows the full role name.
    local realTooltip = GameTooltip
    local tooltipTitles = {}
    GameTooltip = {
        SetOwner = function() end,
        SetText = function(_, t) tooltipTitles[#tooltipTitles + 1] = t end,
        AddLine = function() end,
        Show = function() end,
        Hide = function() end,
    }
    for _, key in ipairs(roleOrder) do
        local slot = panel.__sfRaidSignupRole[key]
        local enter = slot.hover and slot.hover._scripts and slot.hover._scripts.OnEnter
        assertTrue(enter ~= nil, "role hover handler present: " .. key)
        if enter then
            tooltipTitles = {}
            enter(slot.hover)
            assertEq(tooltipTitles[1], expectedNames[key],
                "hover shows the full role name: " .. key)
        end
    end
    GameTooltip = realTooltip
    -- Groups stay inside the Summary sidebar column, clear of its edges.
    local sidebarW = summaryHost.GetWidth and summaryHost:GetWidth() or 258
    local maxRight = 0
    for _, key in ipairs(roleOrder) do
        local slot = panel.__sfRaidSignupRole[key]
        local cx = TopLeftOffset(slot.count)
        local countW = slot.count.GetStringWidth and slot.count:GetStringWidth() or 0
        if cx and countW and cx + countW > maxRight then
            maxRight = cx + countW
        end
    end
    assertTrue(maxRight <= sidebarW - 4 + 1,
        "role totals stay inside the summary sidebar")
    -- Tight widths wrap whole icon+count groups rather than crossing the divider.
    local wrapFn = UIPage._LayoutRoleTotalsForTests
    local wrapLines = wrapFn and wrapFn(panel, 124)
    assertTrue(wrapLines ~= nil and wrapLines >= 2,
        "totals wrap deliberately when space is tight")
    for _, key in ipairs(roleOrder) do
        local slot = panel.__sfRaidSignupRole[key]
        local cx = TopLeftOffset(slot.count)
        local countW = slot.count.GetStringWidth and slot.count:GetStringWidth() or 0
        assertTrue(cx ~= nil and cx + countW <= 120,
            "wrapped group stays inside its line width: " .. key)
    end
    UIPage:Refresh(panel, { force = true }) -- restore the normal single-line layout
    boardHost._w = 548 -- narrow supported width: icon groups still fit one line
    UIPage:Refresh(panel, { force = true })
    assertEq(DistinctTotalLines(), 1, "icon totals stay on one line at narrow width")
    assertEq(select(2, TopLeftOffset(panel.__sfRaidSignupMainHeader)), -26,
        "column headers keep the position without role totals")

    -- 2b. Summary content starts beneath its own divider, independent of the
    -- left column's totals/header stack.
    boardHost._w = nil -- 720 fallback: totals on one line
    UIPage:Refresh(panel, { force = true })
    UIPage:Refresh(panel, { force = true })
    local summaryTopY = select(2, TopLeftOffset(summaryHost))
    local entriesTopSingle = select(2, TopLeftOffset(entriesHost))
    assertTrue(summaryTopY ~= nil
        and summaryTopY == -(panel.__sfRaidSignupSummaryTopH or -1),
        "summary host anchored to its own top offset")
    assertTrue(summaryTopY < 0 and math.abs(summaryTopY) < math.abs(entriesTopSingle),
        "summary content starts above the signup entries")
    local classTitle = FindFontStringByText(summaryHost, "Classes")
    assertTrue(classTitle ~= nil, "Classes heading rendered in the sidebar")
    local _, classTitleY = TopLeftOffset(classTitle)
    -- Role totals occupy the top 15px; Classes starts below them with a gap.
    assertTrue(classTitleY ~= nil and classTitleY <= -23 and classTitleY >= -30,
        "Classes heading sits below the role totals, clear of the Summary divider")
    boardHost._w = 548 -- narrower width: the sidebar keeps its own offset
    UIPage:Refresh(panel, { force = true })
    UIPage:Refresh(panel, { force = true })
    assertEq(select(2, TopLeftOffset(summaryHost)), summaryTopY,
        "summary keeps its own offset across window widths")
    assertEq(select(2, TopLeftOffset(entriesHost)), entriesTopSingle,
        "left column headers keep the approved position with icon totals")
    local _, rightHostY = TopLeftOffset(summaryHost)
    local summaryBottom = math.abs(rightHostY) + (summaryHost:GetHeight() or 0)
    local entriesBottom = math.abs(entriesTopSingle) + (entriesHost:GetHeight() or 0)
    assertTrue(boardHost:GetHeight() >= summaryBottom + 24 - 1,
        "board height contains the raised summary column")
    assertTrue(boardHost:GetHeight() >= entriesBottom + 24 - 1,
        "board height still contains the signup entries")

    -- 3. Summary: a 2px resize across the class-grid threshold rebuilds geometry.
    boardHost._w = 650
    summaryHost._w = 231
    UIPage:Refresh(panel, { force = true })
    UIPage:Refresh(panel, { force = true }) -- let LayoutBoard settle the width
    local keyThree = summaryHost.__sfSummaryBuiltKey
    local heightThree = summaryHost:GetHeight()
    boardHost._w = 654
    summaryHost._w = 233
    UIPage:Refresh(panel, { force = true })
    UIPage:Refresh(panel, { force = true })
    local keyFour = summaryHost.__sfSummaryBuiltKey
    assertTrue(keyThree ~= nil and keyFour ~= nil and keyThree ~= keyFour,
        "small resize across the grid threshold changes summary geometry")
    local hasFourthColumn = false
    for _, btn in pairs(summaryHost.__sfClassIcons or {}) do
        local x = TopLeftOffset(btn)
        if x == 180 then
            hasFourthColumn = true
        end
    end
    assertTrue(hasFourthColumn, "four-class-column layout rendered after resize")
    assertTrue(summaryHost:GetHeight() < heightThree,
        "sidebar height follows the rendered grid rows")
    -- Settled: further refreshes reuse widgets instead of rebuilding.
    local iconsBefore = summaryHost.__sfClassIcons
    UIPage:Refresh(panel, { force = true })
    UIPage:Refresh(panel, { force = true })
    assertTrue(summaryHost.__sfClassIcons == iconsBefore,
        "repeated refreshes converge without rebuilding summary widgets")

    -- 4. Draft and expanded-editor rows: fields anchored from the row top,
    -- wrapped picker height drives the row size, fields below clear it.
    boardHost._w = 548
    summaryHost._w = 233
    UIPage._SetDraftForTests(RS.MakeDraft(tabPlanId))
    UIPage:Refresh(panel, { force = true })
    local draftRow = nil
    for _, child in ipairs({ entriesHost:GetChildren() }) do
        if child._h and child._h > 26 and child.IsShown and child:IsShown()
            and #UIPage._FindEditBoxesForTests(child, "nickname") > 0 then
            draftRow = child
            break
        end
    end
    assertTrue(draftRow ~= nil, "draft row present for bounds check")
    local draftNameLabel = FindFontStringByText(entriesHost, "Name")
    local draftClassLabel = FindFontStringByText(entriesHost, "Class / Spec")
    local draftNotesLabel = FindFontStringByText(entriesHost, "Notes")
    assertTrue(draftNameLabel and draftClassLabel and draftNotesLabel,
        "draft row shows Name/Class-Spec/Notes labels")
    local _, nameY = TopLeftOffset(draftNameLabel)
    assertEq(nameY, -6, "draft Name label anchored at the row top")
    local draftPicker = FindAnchoredTopLeft(entriesHost, draftClassLabel)
    assertTrue(draftPicker ~= nil, "draft class picker painted")
    assertTrue((draftPicker._h or 0) > 24, "picker wraps at narrow column width")
    local pickerH = draftPicker._h
    local _, notesY = TopLeftOffset(draftNotesLabel)
    assertEq(notesY, -(pickerH + 40),
        "draft Notes label clears the wrapped picker's real bottom")
    assertEq(draftRow:GetHeight(), pickerH + 66,
        "draft row sized from its resulting content")
    UIPage._SetDraftForTests(nil)

    -- Main replacement editor gets the same bounds treatment.
    local editTarget = RS:GetSortedEntries(tabPlanId)[1]
    assertTrue(editTarget ~= nil, "entry available for editor bounds check")
    UIPage._SetEditingForTests({
        entryId = editTarget.entryId,
        slot = "main",
        draft = {
            nickname = editTarget.nickname,
            nicknameCommitted = true,
            classFile = nil,
            specId = nil,
            phase = "class",
        },
    })
    UIPage:Refresh(panel, { force = true })
    local editRow = nil
    for _, child in ipairs({ entriesHost:GetChildren() }) do
        if child._h and child._h > 26 and child.IsShown and child:IsShown()
            and #UIPage._FindEditBoxesForTests(child, "nickname") > 0 then
            editRow = child
            break
        end
    end
    assertTrue(editRow ~= nil, "expanded editor row present for bounds check")
    local editClassLabel = FindFontStringByText(entriesHost, "Class / Spec")
    local editNotesLabel = FindFontStringByText(entriesHost, "Notes")
    local editPicker = FindAnchoredTopLeft(entriesHost, editClassLabel)
    assertTrue(editPicker ~= nil, "editor class picker painted")
    local editPickerH = editPicker._h or 0
    assertTrue(editPickerH > 24, "editor picker wraps at narrow column width")
    local _, editNotesY = TopLeftOffset(editNotesLabel)
    assertEq(editNotesY, -(editPickerH + 40),
        "editor Notes label clears the wrapped picker's real bottom")
    assertEq(editRow:GetHeight(), editPickerH + 66,
        "editor row sized from its resulting content")
    UIPage._SetEditingForTests(nil)

    -- 5. Convergence: board height and summary widgets stable once settled.
    boardHost._w = nil
    UIPage:Refresh(panel, { force = true })
    local settledH = panel.__sfRaidSignupBoardRow:GetHeight()
    UIPage:Refresh(panel, { force = true })
    assertEq(panel.__sfRaidSignupBoardRow:GetHeight(), settledH,
        "board height converges across refreshes")
    local settledIcons = summaryHost.__sfClassIcons
    UIPage:Refresh(panel, { force = true })
    assertTrue(summaryHost.__sfClassIcons == settledIcons,
        "summary widgets stable once layout settles")

end
RaidSignupLayoutRegressionTests(panel, UIPage, RS, tabPlanId)

-- Role icon asset fallback chain: GroupFinder atlas -> plain Micro atlas ->
-- circular portrait sheet, with the final 14x14 size enforced on every path.
local function RaidSignupRoleIconFallbackTests(UIPage)
    local savedAtlases = SF.__testAtlases
    local roleOrder = { "tank", "healer", "ranged", "melee" }
    local microOnly = {
        ["UI-LFG-RoleIcon-Tank-Micro"] = 64,
        ["UI-LFG-RoleIcon-Healer-Micro"] = 64,
        ["UI-LFG-RoleIcon-RangedDPS-Micro"] = 64,
        ["UI-LFG-RoleIcon-DPS-Micro"] = 64,
    }
    local expectedMicro = {
        tank = "UI-LFG-RoleIcon-Tank-Micro",
        healer = "UI-LFG-RoleIcon-Healer-Micro",
        ranged = "UI-LFG-RoleIcon-RangedDPS-Micro",
        melee = "UI-LFG-RoleIcon-DPS-Micro",
    }

    SF.__testAtlases = microOnly
    local microPanel = NewPagePanel()
    UIPage:Build(microPanel)
    for _, key in ipairs(roleOrder) do
        local icon = microPanel.__sfRaidSignupRole[key].icon
        assertEq(icon._atlas, expectedMicro[key], "micro atlas fallback: " .. key)
        assertEq(icon:GetWidth(), 14, "micro fallback icon width: " .. key)
        assertEq(icon:GetHeight(), 14, "micro fallback icon height: " .. key)
    end

    SF.__testAtlases = {}
    local sheetPanel = NewPagePanel()
    UIPage:Build(sheetPanel)
    for _, key in ipairs(roleOrder) do
        local icon = sheetPanel.__sfRaidSignupRole[key].icon
        assertEq(icon._texture, "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES",
            "portrait-sheet fallback texture: " .. key)
        assertTrue(icon._texCoord ~= nil, "portrait-sheet fallback texcoord: " .. key)
        assertEq(icon:GetWidth(), 14, "sheet fallback icon width: " .. key)
        assertEq(icon:GetHeight(), 14, "sheet fallback icon height: " .. key)
    end
    SF.__testAtlases = savedAtlases
end
RaidSignupRoleIconFallbackTests(UIPage)

-- Summary presentation: shared heading left edge, and zero-count classes
-- greyed with the missing-coverage treatment while staying enabled.
local function RaidSignupSummaryPresentationTests(panel, UIPage, RS, tabPlanId)
    local function pointXY(widget, point)
        for _, pt in ipairs(widget._points or {}) do
            if pt[1] == point then
                return pt[4], pt[5]
            end
        end
        return nil, nil
    end

    -- The Summary heading shares the sidebar's left edge after build, refresh,
    -- and resize (never reverts to the right edge).
    local title = panel.__sfRaidSignupSummaryTitle
    local summaryHost = panel.__sfRaidSignupSummaryHost
    local boardHost = panel.__sfRaidSignupBoardHost
    assertTrue(title ~= nil and summaryHost ~= nil, "summary heading and host exist")
    local function assertSharedLeftEdge(tag)
        local tx = pointXY(title, "TOPLEFT")
        local hx = pointXY(summaryHost, "TOPLEFT")
        assertTrue(tx ~= nil, "summary heading anchored TOPLEFT: " .. tag)
        assertTrue(hx ~= nil, "summary host anchored TOPLEFT: " .. tag)
        assertEq(tx, hx, "summary heading shares the sidebar left edge: " .. tag)
    end
    assertSharedLeftEdge("initial")
    boardHost._w = 548
    UIPage:Refresh(panel, { force = true })
    assertSharedLeftEdge("after resize")
    boardHost._w = nil

    -- Zero-count classes are greyed but enabled; nonzero counts are full
    -- colour. Transitions apply on refresh without rebuilding the grid.
    ActAs("Alice-Garona", "Player-1-Alice")
    local status, _, greyPlanId = RS:CreatePlan("Summary Grey Plan")
    assertEq(status, "accepted", "officer creates grey-test plan")
    RS:SelectPlan(greyPlanId)
    UIPage:Refresh(panel, { force = true })
    local icons = summaryHost.__sfClassIcons
    local counts = summaryHost.__sfClassCounts
    assertTrue(icons ~= nil and counts ~= nil, "class grid widgets exist")
    assertEq(summaryHost.__sfSummaryBuilt, true, "class grid built")

    local function greyState(classFile)
        local btn = icons[classFile]
        if not (btn and btn.icon) then
            return nil
        end
        return {
            desaturated = btn.icon._desaturated == true,
            shade = btn.icon._vertexColor and btn.icon._vertexColor[1],
            enabled = btn._enabled ~= false,
            count = counts[classFile] and counts[classFile]:GetText(),
        }
    end
    local function assertGrey(classFile, tag)
        local s = greyState(classFile)
        assertTrue(s ~= nil, "class icon present: " .. classFile .. " (" .. tag .. ")")
        assertTrue(s.desaturated, "zero-count class desaturated: " .. classFile .. " (" .. tag .. ")")
        assertEq(s.shade, 0.45, "zero-count class grey shade: " .. classFile .. " (" .. tag .. ")")
        assertTrue(s.enabled, "zero-count class stays enabled: " .. classFile .. " (" .. tag .. ")")
        assertEq(s.count, "0", "zero-count class count text: " .. classFile .. " (" .. tag .. ")")
    end
    local function assertFull(classFile, expectedCount, tag)
        local s = greyState(classFile)
        assertTrue(s ~= nil, "class icon present: " .. classFile .. " (" .. tag .. ")")
        assertTrue(not s.desaturated, "nonzero class not desaturated: " .. classFile .. " (" .. tag .. ")")
        assertEq(s.shade, 1, "nonzero class full colour: " .. classFile .. " (" .. tag .. ")")
        assertTrue(s.enabled, "nonzero class enabled: " .. classFile .. " (" .. tag .. ")")
        assertEq(s.count, tostring(expectedCount),
            "nonzero class count text: " .. classFile .. " (" .. tag .. ")")
    end

    -- Initially every class has zero signups: all grey.
    UIPage:Refresh(panel, { force = true })
    assertGrey("MAGE", "initial")
    assertGrey("WARRIOR", "initial")

    -- zero -> nonzero for Mage only; alt selections do not count.
    status, _, greyEntryA = RS:UpsertEntry({
        planId = greyPlanId,
        nickname = "GreyMage",
        mainClass = "MAGE",
        mainSpec = 62,
    })
    assertEq(status, "accepted", "mage entry accepted")
    UIPage:Refresh(panel, { force = true })
    assertFull("MAGE", 1, "after adding mage")
    assertGrey("WARRIOR", "after adding mage")
    status, _, greyEntryB = RS:UpsertEntry({
        planId = greyPlanId,
        nickname = "GreyWar",
        mainClass = "WARRIOR",
        mainSpec = 71,
        altClass = "MAGE",
        altSpec = 62,
    })
    assertEq(status, "accepted", "warrior entry with mage alt accepted")
    UIPage:Refresh(panel, { force = true })
    assertFull("WARRIOR", 1, "after adding warrior")
    assertFull("MAGE", 1, "alt mage still not counted")

    -- nonzero -> zero by deleting both entries.
    local record = RS:EnsureGuildRecord("club:42")
    for _, entryId in ipairs({ greyEntryA, greyEntryB }) do
        local cur = RS.GetEntry(record, entryId)
        status = RS:DeleteEntry(entryId, { expectedVer = cur and cur.ver })
        assertEq(status, "accepted", "grey-test entry deleted: " .. tostring(entryId))
    end
    UIPage:Refresh(panel, { force = true })
    assertGrey("MAGE", "after deleting mage")
    assertGrey("WARRIOR", "after deleting warrior")

    -- Changing an entry's main class moves the count between classes.
    status, _, greyEntryC = RS:UpsertEntry({
        planId = greyPlanId,
        nickname = "GreySwitch",
        mainClass = "MAGE",
        mainSpec = 62,
    })
    assertEq(status, "accepted", "switch entry accepted")
    status, _, greyEntryC = RS:UpsertEntry({
        planId = greyPlanId,
        entryId = greyEntryC,
        nickname = "GreySwitch",
        mainClass = "WARRIOR",
        mainSpec = 71,
    })
    assertEq(status, "accepted", "switch entry main class changed")
    UIPage:Refresh(panel, { force = true })
    assertGrey("MAGE", "after main class changed away")
    assertFull("WARRIOR", 1, "after main class changed to")

    -- Restore the tab plan for the remaining suites.
    local cur = RS.GetEntry(RS:EnsureGuildRecord("club:42"), greyEntryC)
    RS:DeleteEntry(greyEntryC, { expectedVer = cur and cur.ver })
    RS:SelectPlan(tabPlanId)
    UIPage:Refresh(panel, { force = true })
end
RaidSignupSummaryPresentationTests(panel, UIPage, RS, tabPlanId)

-- Role-total guidance colors: threshold boundaries, healer rounding, DPS
-- minimum precedence, and live color/tooltip transitions through refresh.
local function RaidSignupRoleTotalColorTests(panel, UIPage, RS, tabPlanId)
    local assess = UIPage._AssessRoleTotalsForTests
    assertTrue(assess ~= nil, "assessment helper exposed for tests")

    local function levelOf(totals, role)
        local a = assess and assess(totals)
        return a and a[role] and a[role].level
    end
    local function textOf(totals, role)
        local a = assess and assess(totals)
        return a and a[role] and a[role].text
    end

    -- Tanks: exactly two yellow, anything else red.
    assertEq(levelOf({ tank = 2, healer = 0, ranged = 0, melee = 0 }, "tank"), "yellow",
        "two tanks yellow")
    assertEq(levelOf({ tank = 1, healer = 0, ranged = 0, melee = 0 }, "tank"), "red",
        "one tank red")
    assertEq(levelOf({ tank = 3, healer = 0, ranged = 0, melee = 0 }, "tank"), "red",
        "three tanks red")
    assertTrue((textOf({ tank = 2, healer = 0, ranged = 0, melee = 0 }, "tank") or ""):find("target: 2"),
        "tank tooltip explains the two-tank target")

    -- Healers: rounding band per roster size N (tank=0, melee=0, ranged=N-H).
    local function healerCase(N, H)
        local a = assess and assess({ tank = 0, healer = H, ranged = N - H, melee = 0 }) or {}
        return a.healer and a.healer.level
    end
    -- N=10 -> yellow {2}; orange 3; red 0-1 or 4+
    assertEq(healerCase(10, 2), "yellow", "N=10 H=2 yellow")
    assertEq(healerCase(10, 3), "orange", "N=10 H=3 orange")
    assertEq(healerCase(10, 4), "red", "N=10 H=4 red")
    assertEq(healerCase(10, 1), "red", "N=10 H=1 red")
    -- N=14/15 -> yellow {3}; orange 2 or 4
    assertEq(healerCase(14, 3), "yellow", "N=14 H=3 yellow")
    assertEq(healerCase(14, 2), "orange", "N=14 H=2 orange")
    assertEq(healerCase(14, 4), "orange", "N=14 H=4 orange")
    assertEq(healerCase(14, 5), "red", "N=14 H=5 red")
    assertEq(healerCase(15, 3), "yellow", "N=15 H=3 yellow")
    -- N=20 -> yellow 4-5; orange 3 or 6; red 0-2 or 7+
    assertEq(healerCase(20, 4), "yellow", "N=20 H=4 yellow")
    assertEq(healerCase(20, 5), "yellow", "N=20 H=5 yellow")
    assertEq(healerCase(20, 3), "orange", "N=20 H=3 orange")
    assertEq(healerCase(20, 6), "orange", "N=20 H=6 orange")
    assertEq(healerCase(20, 2), "red", "N=20 H=2 red")
    assertEq(healerCase(20, 7), "red", "N=20 H=7 red")
    -- N=25 -> yellow 5-6; orange 4 or 7
    assertEq(healerCase(25, 5), "yellow", "N=25 H=5 yellow")
    assertEq(healerCase(25, 6), "yellow", "N=25 H=6 yellow")
    assertEq(healerCase(25, 4), "orange", "N=25 H=4 orange")
    assertEq(healerCase(25, 7), "orange", "N=25 H=7 orange")
    -- N=30 -> yellow 6-7; orange 5 or 8
    assertEq(healerCase(30, 6), "yellow", "N=30 H=6 yellow")
    assertEq(healerCase(30, 7), "yellow", "N=30 H=7 yellow")
    assertEq(healerCase(30, 5), "orange", "N=30 H=5 orange")
    assertEq(healerCase(30, 8), "orange", "N=30 H=8 orange")
    -- Outside 10-30: H>=2 stays normal yellow with an explicit not-assessed note.
    local ungraded = textOf({ tank = 0, healer = 2, ranged = 7, melee = 0 }, "healer")
    assertEq(levelOf({ tank = 0, healer = 2, ranged = 7, melee = 0 }, "healer"), "yellow",
        "N=9 healer ungraded yellow")
    assertTrue((ungraded or ""):find("not assessed"), "ungraded healer tooltip states not assessed")
    assertEq(levelOf({ tank = 0, healer = 6, ranged = 25, melee = 0 }, "healer"), "yellow",
        "N=31 healer ungraded yellow")
    -- Fewer than two healers is red at any roster size.
    assertEq(levelOf({ tank = 0, healer = 1, ranged = 20, melee = 0 }, "healer"), "red",
        "H=1 red even at N=21")
    assertEq(levelOf({ tank = 0, healer = 0, ranged = 5, melee = 0 }, "healer"), "red",
        "H=0 red at small roster")

    -- DPS: combined minimum overrides the split; boundaries are exact.
    local function dpsCase(M, R)
        local a = assess and assess({ tank = 2, healer = 2, ranged = R, melee = M }) or {}
        return {
            melee = a.melee or {},
            ranged = a.ranged or {},
        }
    end
    local minDps = dpsCase(3, 5)
    assertEq(minDps.melee.level, "red", "D=8 melee red")
    assertEq(minDps.ranged.level, "red", "D=8 ranged red (same color)")
    assertTrue((minDps.melee.text or ""):find("at least 9"), "DPS minimum tooltip")
    -- Owner examples at D=14.
    assertEq(dpsCase(6, 8).melee.level, "yellow", "6/8 yellow")
    assertEq(dpsCase(9, 5).melee.level, "yellow", "9/5 yellow")
    assertEq(dpsCase(10, 4).melee.level, "orange", "10/4 orange")
    assertEq(dpsCase(12, 2).melee.level, "red", "12/2 red")
    assertEq(dpsCase(2, 12).melee.level, "orange", "2/12 orange")
    assertEq(dpsCase(0, 14).melee.level, "orange", "0/14 orange")
    -- Exact boundaries: 20% and 65% inclusive, 85% exclusive.
    assertEq(dpsCase(2, 8).melee.level, "yellow", "20% boundary yellow (D=10)")
    assertEq(dpsCase(13, 7).melee.level, "yellow", "65% boundary yellow (D=20)")
    assertEq(dpsCase(14, 6).melee.level, "orange", "just above 65% orange")
    assertEq(dpsCase(17, 3).melee.level, "orange", "85% boundary orange (D=20)")
    assertEq(dpsCase(18, 2).melee.level, "red", "above 85% red")
    -- Ranged-heavy never exceeds orange while D >= 9.
    assertEq(dpsCase(0, 9).melee.level, "orange", "0/9 ranged-heavy orange")

    -- UI path: colors and tooltips follow real refreshes and transitions.
    ActAs("Alice-Garona", "Player-1-Alice")
    local status, _, colorPlanId = RS:CreatePlan("Role Color Plan")
    assertEq(status, "accepted", "officer creates color-test plan")
    RS:SelectPlan(colorPlanId)
    local function addEntry(nick, classFile, specId)
        status, _, entryId = RS:UpsertEntry({
            planId = colorPlanId, nickname = nick, mainClass = classFile, mainSpec = specId,
        })
        assertEq(status, "accepted", "color-test entry accepted: " .. nick)
        return entryId
    end
    local ids = {}
    ids[#ids + 1] = addEntry("ColTank1", "PALADIN", 66)
    ids[#ids + 1] = addEntry("ColTank2", "PALADIN", 66)
    ids[#ids + 1] = addEntry("ColHeal1", "PALADIN", 65)
    ids[#ids + 1] = addEntry("ColMelee1", "WARRIOR", 71)
    ids[#ids + 1] = addEntry("ColRange1", "MAGE", 62)
    UIPage:Refresh(panel, { force = true })

    local role = panel.__sfRaidSignupRole
    local function countColor(key)
        local tc = role[key].count._textColor
        return tc and tc[2]
    end
    -- T=2,H=1,M=1,R=1 -> N=5, D=2.
    assertEq(countColor("tank"), 1, "tank count white at 2 tanks")
    assertEq(countColor("healer"), 0.2, "healer count red below two at any size")
    assertEq(countColor("melee"), 0.2, "melee count red below DPS minimum")
    assertEq(countColor("ranged"), 0.2, "ranged count red below DPS minimum")
    assertTrue((role.healer.hover.__sfRoleTooltip or ""):find("at least 2"),
        "under-staffed healer tooltip on the live hover region")

    -- Grow to D=9 (7 more ranged): DPS flips to orange, healer stays red (H=1).
    for i = 1, 7 do
        ids[#ids + 1] = addEntry("ColRange" .. (i + 1), "MAGE", 62)
    end
    UIPage:Refresh(panel, { force = true })
    assertEq(countColor("melee"), 0.6, "melee count orange at D=9 ranged-heavy")
    assertEq(countColor("ranged"), 0.6, "ranged count shares the DPS color")
    assertEq(countColor("healer"), 0.2, "healer count red below two")
    assertTrue((role.melee.hover.__sfRoleTooltip or ""):find("Ranged%-heavy"),
        "ranged-heavy tooltip text")

    -- Tooltip path: hover shows the role name plus the assessment line.
    local realTooltip = GameTooltip
    local tooltipLines = {}
    GameTooltip = {
        SetOwner = function() end,
        SetText = function(_, t) tooltipLines[#tooltipLines + 1] = t end,
        AddLine = function(_, t) tooltipLines[#tooltipLines + 1] = t end,
        Show = function() end,
        Hide = function() end,
    }
    local meleeEnter = role.melee.hover._scripts.OnEnter
    tooltipLines = {}
    meleeEnter(role.melee.hover)
    assertEq(tooltipLines[1], "Melee DPS", "tooltip keeps the full role name")
    assertTrue(tooltipLines[2] and tooltipLines[2]:find("Ranged%-heavy"),
        "tooltip shows the DPS assessment line")
    GameTooltip = realTooltip

    -- Add a second healer (N=13 -> band {3}, H=2 one below -> orange).
    ids[#ids + 1] = addEntry("ColHeal2", "PALADIN", 65)
    UIPage:Refresh(panel, { force = true })
    assertEq(countColor("healer"), 0.6, "healer count orange one below band")
    assertTrue((role.healer.hover.__sfRoleTooltip or ""):find("Slightly below"),
        "healer tooltip explains the band position")

    -- Turn one ranged entry into melee: M=2,R=7,D=9 -> balanced yellow again.
    local record = RS:EnsureGuildRecord("club:42")
    local rangeEntryId = ids[5]
    local cur = RS.GetEntry(record, rangeEntryId)
    status, _, rangeEntryId = RS:UpsertEntry({
        planId = colorPlanId,
        entryId = rangeEntryId,
        nickname = "ColRange1",
        mainClass = "WARRIOR",
        mainSpec = 71,
    })
    assertEq(status, "accepted", "ranged entry switched to melee")
    assertTrue(cur ~= nil, "entry snapshot for ver lookup")
    UIPage:Refresh(panel, { force = true })
    assertEq(countColor("melee"), 1, "melee count white when balanced")
    assertEq(countColor("ranged"), 1, "ranged count white with the split")

    -- Cleanup: remove color-test entries and restore the tab plan.
    for _, entryId in ipairs(ids) do
        local live = RS.GetEntry(record, entryId)
        if live and not live.deleted then
            RS:DeleteEntry(entryId, { expectedVer = live.ver })
        end
    end
    RS:SelectPlan(tabPlanId)
    UIPage:Refresh(panel, { force = true })
end
RaidSignupRoleTotalColorTests(panel, UIPage, RS, tabPlanId)

-- Tier Tokens summary group: armor-family mapping, crowding color boundaries,
-- tooltips, empty roster, and refresh transitions.
local function RaidSignupTokenTests(panel, UIPage, RS, tabPlanId)
    local assess = UIPage._AssessTokenCrowdingForTests
    assertTrue(assess ~= nil, "token crowding helper exposed for tests")
    local function level(count, total)
        local a = assess and assess(count, total)
        return a and a.level
    end

    -- Mapping: every class exactly once; group sizes 3/4/3/3 in order.
    local groups = RS.ARMOR_TOKEN_GROUPS or {}
    assertEq(#groups, 4, "four token groups")
    local seenClasses = {}
    local mappedCount = 0
    local dupes = 0
    local sizes = {}
    for i = 1, #groups do
        sizes[#sizes + 1] = #(groups[i].classes or {})
        for _, cf in ipairs(groups[i].classes or {}) do
            if seenClasses[cf] then
                dupes = dupes + 1
            else
                seenClasses[cf] = true
                mappedCount = mappedCount + 1
            end
        end
    end
    assertEq(dupes, 0, "no class in two token groups")
    assertEq(mappedCount, #RS.CLASS_ORDER, "every class mapped exactly once")
    assertEq(table.concat(sizes, "/"), "3/4/3/3", "cloth/leather/mail/plate sizes")
    for _, cf in ipairs(RS.CLASS_ORDER) do
        assertTrue(seenClasses[cf], "class mapped: " .. tostring(cf))
    end

    -- Crowding boundaries (owner examples).
    local function band(N)
        local a = assess and assess(0, N) or {}
        return a.fairMax, math.max(1, math.floor(N * 0.05 + 0.5))
    end
    -- N=14: yellow 0-4, orange 5, red 6+
    assertEq(level(4, 14), "yellow", "N=14 C=4 yellow")
    assertEq(level(5, 14), "orange", "N=14 C=5 orange")
    assertEq(level(6, 14), "red", "N=14 C=6 red")
    -- N=20: yellow 0-5, orange 6, red 7+
    assertEq(level(5, 20), "yellow", "N=20 C=5 yellow")
    assertEq(level(6, 20), "orange", "N=20 C=6 orange")
    assertEq(level(7, 20), "red", "N=20 C=7 red")
    -- N=25: yellow 0-7, orange 8, red 9+
    assertEq(level(7, 25), "yellow", "N=25 C=7 yellow")
    assertEq(level(8, 25), "orange", "N=25 C=8 orange")
    assertEq(level(9, 25), "red", "N=25 C=9 red")
    -- N=30: yellow 0-8, orange 9-10, red 11+
    assertEq(level(8, 30), "yellow", "N=30 C=8 yellow")
    assertEq(level(9, 30), "orange", "N=30 C=9 orange")
    assertEq(level(10, 30), "orange", "N=30 C=10 orange")
    assertEq(level(11, 30), "red", "N=30 C=11 red")
    -- N=40: yellow 0-10, orange 11-12, red 13+
    assertEq(level(10, 40), "yellow", "N=40 C=10 yellow")
    assertEq(level(11, 40), "orange", "N=40 C=11 orange")
    assertEq(level(12, 40), "orange", "N=40 C=12 orange")
    assertEq(level(13, 40), "red", "N=40 C=13 red")
    -- Asymmetry: low/zero representation never leaves yellow.
    assertEq(level(0, 40), "yellow", "zero count yellow at N=40")
    assertEq(level(1, 40), "yellow", "single participant yellow at N=40")
    assertEq(level(0, 14), "yellow", "zero count yellow at N=14")
    -- N=0: no division, yellow, flagged empty.
    local empty = assess and assess(0, 0) or {}
    assertEq(empty.level, "yellow", "empty roster yellow")
    assertTrue(empty.empty, "empty roster flagged")
    assertEq(empty.fairMax, 0, "empty roster fair share zero")
    -- Non-divisible sizes use the rounded fair share (14 -> 4, not 3.5).
    local fm14 = band(14)
    assertEq(fm14, 4, "N=14 fair share rounds up to 4")

    -- UI path: real plan, real refreshes, pooled summary.
    ActAs("Alice-Garona", "Player-1-Alice")
    local status, _, tokenPlanId = RS:CreatePlan("Token Plan")
    assertEq(status, "accepted", "officer creates token-test plan")
    RS:SelectPlan(tokenPlanId)
    local function addEntry(nick, classFile)
        local specs = RS.CLASS_SPECS[classFile]
        status, _, entryId = RS:UpsertEntry({
            planId = tokenPlanId, nickname = nick,
            mainClass = classFile, mainSpec = specs[1],
        })
        assertEq(status, "accepted", "token-test entry accepted: " .. nick)
        return entryId
    end
    local ids = {}
    for _, cf in ipairs(RS.CLASS_ORDER) do
        ids[#ids + 1] = addEntry("Tok" .. cf, cf)
    end
    UIPage:Refresh(panel, { force = true })

    local host = panel.__sfRaidSignupSummaryHost
    assertTrue(host ~= nil, "summary host exists")
    if not (host and host.__sfTokenCounts) then
        assertTrue(false, "tier token counts built in summary")
        assertTrue(false, "tier token icons built in summary")
        for _, entryId in ipairs(ids) do
            local live = RS.GetEntry(RS:EnsureGuildRecord("club:42"), entryId)
            if live and not live.deleted then
                RS:DeleteEntry(entryId, { expectedVer = live.ver })
            end
        end
        RS:SelectPlan(tabPlanId)
        UIPage:Refresh(panel, { force = true })
        return
    end
    local function tokenCountText(id)
        local fs = host.__sfTokenCounts and host.__sfTokenCounts[id]
        return fs and fs:GetText()
    end
    local function tokenColor(id)
        local fs = host.__sfTokenCounts and host.__sfTokenCounts[id]
        local tc = fs and fs._textColor
        return tc and tc[2]
    end
    local function tokenIcon(id)
        return host.__sfTokenIcons and host.__sfTokenIcons[id]
    end
    -- One of each class: cloth 3, leather 4, mail 3, plate 3; N=13 -> fairMax 4.
    assertEq(tokenCountText("cloth"), "3", "cloth count 3")
    assertEq(tokenCountText("leather"), "4", "leather count 4")
    assertEq(tokenCountText("mail"), "3", "mail count 3")
    assertEq(tokenCountText("plate"), "3", "plate count 3")
    assertEq(tokenColor("cloth"), 1, "cloth white within share")
    assertEq(tokenColor("leather"), 1, "leather white at fair share")
    local clothIcon = tokenIcon("cloth")
    assertTrue(clothIcon ~= nil, "cloth token icon exists")
    assertTrue(clothIcon.icon and clothIcon.icon._desaturated == false,
        "populated token icon not greyed")
    -- Containment: every token icon sits inside the sidebar width.
    local sideW = host:GetWidth()
    for id, icon in pairs(host.__sfTokenIcons or {}) do
        local maxX = -1
        for _, pt in ipairs(icon._points or {}) do
            if pt[1] == "TOPLEFT" then
                maxX = math.max(maxX, pt[4])
            end
        end
        assertTrue(maxX >= 0 and maxX + 22 <= sideW + 0.5,
            "token icon " .. id .. " inside sidebar")
    end

    -- Tooltip path: hover shows armor/family, classes, count/percent, target,
    -- and assessment.
    local realTooltip = GameTooltip
    local tooltipLines = {}
    GameTooltip = {
        SetOwner = function() end,
        SetText = function(_, t) tooltipLines[#tooltipLines + 1] = t end,
        AddLine = function(_, t) tooltipLines[#tooltipLines + 1] = t end,
        Show = function() end,
        Hide = function() end,
    }
    tooltipLines = {}
    clothIcon._scripts.OnEnter(clothIcon)
    assertEq(tooltipLines[1], "Cloth — Woven", "token tooltip title")
    assertTrue(tooltipLines[2] and tooltipLines[2]:find("MAGE")
        and tooltipLines[2]:find("PRIEST") and tooltipLines[2]:find("WARLOCK"),
        "token tooltip lists eligible classes")
    assertEq(tooltipLines[3], "3 of 13 signups: 23%", "token tooltip count and percent")
    assertEq(tooltipLines[4], "Even-share target: 4", "token tooltip even-share target")
    assertEq(tooltipLines[5], "Within the even-share range.", "token tooltip assessment")

    -- Crowding transition: two more cloth mains -> cloth 5 of 15 (fairMax 4,
    -- wiggle 1) -> orange; one more -> 6 of 16 -> red.
    ids[#ids + 1] = addEntry("TokMage2", "MAGE")
    ids[#ids + 1] = addEntry("TokMage3", "MAGE")
    UIPage:Refresh(panel, { force = true })
    assertEq(tokenCountText("cloth"), "5", "cloth count 5")
    assertEq(tokenColor("cloth"), 0.6, "cloth orange one past fair share")
    assertEq(tokenColor("leather"), 1, "leather stays white")
    ids[#ids + 1] = addEntry("TokMage4", "MAGE")
    UIPage:Refresh(panel, { force = true })
    assertEq(tokenCountText("cloth"), "6", "cloth count 6")
    assertEq(tokenColor("cloth"), 0.2, "cloth red beyond wiggle")
    tooltipLines = {}
    clothIcon._scripts.OnEnter(clothIcon)
    assertEq(tooltipLines[3], "6 of 16 signups: 38%", "crowded tooltip percent")
    assertEq(tooltipLines[5], "Outside the usual range.", "crowded tooltip assessment")

    -- Empty plan: four grey icons, yellow zero counts, empty-roster tooltip.
    local status2, _, emptyPlanId = RS:CreatePlan("Token Empty Plan")
    assertEq(status2, "accepted", "officer creates empty token plan")
    RS:SelectPlan(emptyPlanId)
    UIPage:Refresh(panel, { force = true })
    for _, id in ipairs({ "cloth", "leather", "mail", "plate" }) do
        assertEq(tokenCountText(id), "0", "empty plan zero count: " .. id)
        assertEq(tokenColor(id), 1, "empty plan white zero count: " .. id)
        local icon = tokenIcon(id)
        assertTrue(icon and icon.icon and icon.icon._desaturated == true,
            "empty plan token icon greyed: " .. id)
    end
    tooltipLines = {}
    tokenIcon("cloth")._scripts.OnEnter(tokenIcon("cloth"))
    assertEq(tooltipLines[#tooltipLines], "No completed signups yet.",
        "empty roster tooltip explanation")

    -- Plan switch back: pooled controls repaint with live counts/colors.
    RS:SelectPlan(tokenPlanId)
    UIPage:Refresh(panel, { force = true })
    assertEq(tokenCountText("cloth"), "6", "pooled count restored after plan switch")
    assertEq(tokenColor("cloth"), 0.2, "pooled color restored after plan switch")
    tooltipLines = {}
    tokenIcon("cloth")._scripts.OnEnter(tokenIcon("cloth"))
    assertEq(tooltipLines[3], "6 of 16 signups: 38%", "pooled tooltip restored")
    GameTooltip = realTooltip

    -- Cleanup.
    for _, entryId in ipairs(ids) do
        local live = RS.GetEntry(RS:EnsureGuildRecord("club:42"), entryId)
        if live and not live.deleted then
            RS:DeleteEntry(entryId, { expectedVer = live.ver })
        end
    end
    RS:SelectPlan(tabPlanId)
    UIPage:Refresh(panel, { force = true })
end
RaidSignupTokenTests(panel, UIPage, RS, tabPlanId)

local function RaidSignupProviderOverlayTests(panel, UIPage, RS, tabPlanId)
    -- Provider-count overlays on Combat Res / Burst Move Speed / Death Grip+AMZ,
    -- role totals as the first Summary content, and Classes beneath them.
    local summaryHost = panel.__sfRaidSignupSummaryHost
    assertTrue(summaryHost ~= nil, "summary host exists for overlay checks")
    local status, _, overlayPlanId = RS:CreatePlan("Provider Overlay Plan")
    assertEq(status, "accepted", "officer creates overlay plan")
    RS:SelectPlan(overlayPlanId)
    local ids = {}
    local function add(nick, classFile, specId)
        local st, _, eid = RS:UpsertEntry({ planId = overlayPlanId, nickname = nick,
            mainClass = classFile, mainSpec = specId })
        assertEq(st, "accepted", "overlay plan entry: " .. nick)
        ids[#ids + 1] = eid
    end
    add("OvLock", "WARLOCK", 266)
    add("OvFrost", "DEATHKNIGHT", 251)
    add("OvBlood", "DEATHKNIGHT", 250)
    UIPage:Refresh(panel, { force = true })

    local overlays = summaryHost.__sfProviderOverlays
    assertTrue(type(overlays) == "table", "provider overlays created")
    for _, id in ipairs({ "combat_res", "burst_move", "dk_grip_amz" }) do
        assertTrue(overlays[id] ~= nil, "overlay present: " .. id)
    end
    local function overlayText(id)
        local ov = overlays[id]
        return ov and ov.GetText and ov:GetText() or nil
    end
    local function overlayColor(id)
        local ov = overlays[id]
        local c = ov and ov._textColor
        return c and c[1] or nil
    end
    assertEq(overlayText("combat_res"), "3", "combat res counts warlock + 2 DKs")
    assertEq(overlayText("dk_grip_amz"), "1", "grip overlay counts Frost DK only")
    assertEq(overlayText("burst_move"), "0", "zero providers still shown")
    for _, id in ipairs({ "combat_res", "burst_move", "dk_grip_amz" }) do
        assertEq(overlayColor(id), 1, "overlay count is white: " .. id)
    end

    -- Role totals are the first Summary content, above Classes.
    -- Stub point tuples: { point, relativeTo, relativePoint, x, y }.
    local function TopLeftY(region)
        for _, pt in ipairs(region._points or {}) do
            if pt[1] == "TOPLEFT" then
                return pt[5]
            end
        end
        return nil
    end
    local roleCountY = TopLeftY(panel.__sfRaidSignupRole.tank.count)
    assertTrue(roleCountY ~= nil and roleCountY >= -2 and roleCountY <= 2,
        "role totals at the top of the summary content")
    local classTitle
    if summaryHost.GetRegions then
        for _, r in ipairs({ summaryHost:GetRegions() }) do
            if r.GetText and r:GetText() == "Classes" then
                classTitle = r
                break
            end
        end
    end
    local classTitleY = classTitle and TopLeftY(classTitle)
    assertTrue(classTitleY ~= nil and classTitleY <= -23,
        "Classes heading below the role totals")

    -- Deletions repaint overlays back to zero without a rebuild.
    for _, entryId in ipairs(ids) do
        local live = RS.GetEntry(RS:EnsureGuildRecord("club:42"), entryId)
        if live and not live.deleted then
            RS:DeleteEntry(entryId, { expectedVer = live.ver })
        end
    end
    UIPage:Refresh(panel, { force = true })
    assertEq(overlayText("combat_res"), "0", "overlay resets to zero after deletions")
    assertEq(overlayText("dk_grip_amz"), "0", "grip overlay resets after deletions")

    RS:SelectPlan(tabPlanId)
    UIPage:Refresh(panel, { force = true })
end
RaidSignupProviderOverlayTests(panel, UIPage, RS, tabPlanId)

local function RaidSignupRowActionTests(panel, UIPage, RS, tabPlanId)
    -- Collapsed-row actions: notes preview + full-note hover, clickable alt
    -- dash, in-editor Remove Alt, and the compact delete X.
    local entriesHost = panel.__sfRaidSignupEntriesHost
    local boardHost = panel.__sfRaidSignupBoardHost
    assertTrue(entriesHost ~= nil, "entries host exists for row action checks")

    local function WalkAll(root, fn)
        local function walk(f)
            if not f then
                return
            end
            fn(f)
            if f.GetChildren then
                for _, k in ipairs({ f:GetChildren() }) do
                    walk(k)
                end
            end
            if f.GetRegions then
                for _, r in ipairs({ f:GetRegions() }) do
                    walk(r)
                end
            end
        end
        walk(root)
    end
    local function FindButtonsByTooltip(title)
        local found = {}
        WalkAll(entriesHost, function(f)
            if f.GetObjectType and f:GetObjectType() == "Button"
                and f.tooltipTitle == title then
                found[#found + 1] = f
            end
        end)
        return found
    end
    local function FindHovers()
        local found = {}
        WalkAll(entriesHost, function(f)
            if f.__sfRaidSignupHover then
                found[#found + 1] = f
            end
        end)
        return found
    end
    local function FindFontString(root, text)
        local found = nil
        WalkAll(root, function(f)
            if found then
                return
            end
            if f.GetObjectType and f:GetObjectType() == "FontString"
                and f.GetText and f:GetText() == text then
                found = f
            end
        end)
        return found
    end
    local function RowHasText(widget, text)
        local has = false
        WalkAll(widget, function(f)
            if has then
                return
            end
            if f.GetObjectType and f:GetObjectType() == "FontString"
                and f.GetText and f:GetText() == text then
                has = true
            end
        end)
        return has
    end
    local function EntryByNick(nick)
        for _, e in ipairs(RS:GetSortedEntries(tabPlanId)) do
            if e.nickname == nick and not e.deleted then
                return e
            end
        end
        return nil
    end

    -- Capture GameTooltip output so the real hover handlers can be exercised.
    local tooltipEvents = {}
    local savedTooltip = {
        SetOwner = GameTooltip.SetOwner,
        SetText = GameTooltip.SetText,
        AddLine = GameTooltip.AddLine,
        Show = GameTooltip.Show,
        Hide = GameTooltip.Hide,
    }
    GameTooltip.SetOwner = function() end
    GameTooltip.SetText = function(_, text)
        tooltipEvents[#tooltipEvents + 1] = "text:" .. tostring(text)
    end
    GameTooltip.AddLine = function(_, text)
        tooltipEvents[#tooltipEvents + 1] = "line:" .. tostring(text)
    end
    GameTooltip.Show = function()
        tooltipEvents[#tooltipEvents + 1] = "show"
    end
    GameTooltip.Hide = function()
        tooltipEvents[#tooltipEvents + 1] = "hide"
    end
    local function TooltipSaw(fullText)
        local sawText, sawShow = false, false
        for _, ev in ipairs(tooltipEvents) do
            if ev == "text:" .. fullText then
                sawText = true
            elseif ev == "show" then
                sawShow = true
            end
        end
        return sawText and sawShow
    end

    -- 1. Notes: short shown in full, long clipped with the full text on hover,
    -- pooled rows reset cleanly when the note changes or is removed.
    assertEq(select(1, RS:UpsertEntry({
        planId = tabPlanId, nickname = "NoteFull",
        mainClass = "MAGE", mainSpec = 62, notes = "Short note",
    })), "accepted", "note test entry created")
    UIPage:Refresh(panel, { force = true })
    local noteEntry = EntryByNick("NoteFull")
    assertTrue(noteEntry ~= nil, "note test entry found")
    assertTrue(FindFontString(entriesHost, "Short note") ~= nil,
        "short note displayed in full")
    local shortHover = nil
    for _, h in ipairs(FindHovers()) do
        if h.__sfHoverText == "Short note" then
            shortHover = h
            break
        end
    end
    assertTrue(shortHover ~= nil, "short note has a hover region")
    if shortHover then
        tooltipEvents = {}
        shortHover:GetScript("OnEnter")(shortHover)
        assertTrue(TooltipSaw("Short note"), "hover shows the full short note")
        shortHover:GetScript("OnLeave")(shortHover)
        assertTrue(tooltipEvents[#tooltipEvents] == "hide", "hover leave hides tooltip")
    end

    local longNote = string.rep("x", 120)
    assertEq(select(1, RS:UpsertEntry({
        entryId = noteEntry.entryId, planId = tabPlanId,
        nickname = "NoteFull", mainClass = "MAGE", mainSpec = 62,
        notes = longNote,
    }, { expectedVer = noteEntry.ver })), "accepted", "long note saved")
    UIPage:Refresh(panel, { force = true })
    local clippedNote = nil
    WalkAll(entriesHost, function(f)
        if clippedNote then
            return
        end
        if f.GetObjectType and f:GetObjectType() == "FontString" and f.GetText then
            local t = f:GetText() or ""
            if t:sub(1, 1) == "x" and t:sub(-3) == "…" and #t < #longNote then
                clippedNote = f
            end
        end
    end)
    assertTrue(clippedNote ~= nil, "long note truncated with ellipsis")
    local geomNow = panel.__sfEntryGeom
    local noteBudget = geomNow.leftW - geomNow.notesX - geomNow.rightReserve - 6
    assertTrue((clippedNote:GetStringWidth() or 0) <= noteBudget,
        "truncated note fits its allocated region")
    local longHover = nil
    for _, h in ipairs(FindHovers()) do
        if h.__sfHoverText == longNote then
            longHover = h
            break
        end
    end
    assertTrue(longHover ~= nil, "truncated note keeps the full text on hover")
    if longHover then
        tooltipEvents = {}
        longHover:GetScript("OnEnter")(longHover)
        assertTrue(TooltipSaw(longNote), "hover delivers the complete untruncated note")
    end

    local fresh = EntryByNick("NoteFull")
    assertEq(select(1, RS:UpsertEntry({
        entryId = fresh.entryId, planId = tabPlanId,
        nickname = "NoteFull", mainClass = "MAGE", mainSpec = 62,
        notes = "Second note",
    }, { expectedVer = fresh.ver })), "accepted", "note changed on reused row")
    UIPage:Refresh(panel, { force = true })
    local secondHover = nil
    for _, h in ipairs(FindHovers()) do
        assertTrue(h.__sfHoverText ~= longNote, "no hover retains the previous note")
        if h.__sfHoverText == "Second note" then
            secondHover = h
        end
    end
    assertTrue(secondHover ~= nil, "changed note shows its own preview")
    assertTrue(FindFontString(entriesHost, "Second note") ~= nil,
        "short replacement note shown in full")

    fresh = EntryByNick("NoteFull")
    assertEq(select(1, RS:UpsertEntry({
        entryId = fresh.entryId, planId = tabPlanId,
        nickname = "NoteFull", mainClass = "MAGE", mainSpec = 62, notes = "",
    }, { expectedVer = fresh.ver })), "accepted", "note emptied")
    UIPage:Refresh(panel, { force = true })
    assertTrue(FindFontString(entriesHost, "Second note") == nil,
        "empty note shows no preview")
    for _, h in ipairs(FindHovers()) do
        assertTrue(h.__sfHoverText ~= "" and h.__sfHoverText ~= "Second note",
            "empty note leaves no hover text behind")
    end
    GameTooltip.SetOwner = savedTooltip.SetOwner
    GameTooltip.SetText = savedTooltip.SetText
    GameTooltip.AddLine = savedTooltip.AddLine
    GameTooltip.Show = savedTooltip.Show
    GameTooltip.Hide = savedTooltip.Hide

    -- 2. The empty Alt slot is a clickable dash that starts the add-alt workflow.
    assertEq(select(1, RS:UpsertEntry({
        planId = tabPlanId, nickname = "DashTest",
        mainClass = "MAGE", mainSpec = 62,
    })), "accepted", "dash test entry created")
    UIPage:Refresh(panel, { force = true })
    local dashEntry = EntryByNick("DashTest")
    assertTrue(dashEntry ~= nil, "dash test entry found")
    local dash = nil
    for _, b in ipairs(FindButtonsByTooltip("Add alternative")) do
        if b._parent and RowHasText(b._parent, "DashTest") then
            dash = b
            break
        end
    end
    assertTrue(dash ~= nil, "empty alt slot renders a clickable dash")
    assertTrue(dash ~= nil and dash.GetWidth and dash:GetWidth() >= 22,
        "dash hit area comparable to the spec icons")
    if dash then
        dash:GetScript("OnClick")(dash)
    end
    local altDraft = UIPage._GetAltDraftForTests()
    assertTrue(altDraft ~= nil and altDraft.entryId == dashEntry.entryId,
        "dash click starts the add-alt workflow for its entry")
    UIPage._SetAltDraftForTests(nil)
    UIPage:Refresh(panel, { force = true })

    -- Read-only users cannot mutate through the dash.
    ActAs("Carol-Garona", "Player-1-Carol")
    UIPage:Refresh(panel, { force = true })
    local roDash = nil
    for _, b in ipairs(FindButtonsByTooltip("Add alternative")) do
        if b._parent and RowHasText(b._parent, "DashTest") then
            roDash = b
            break
        end
    end
    assertTrue(roDash ~= nil, "dash still rendered for read-only users")
    assertTrue(roDash ~= nil and roDash:IsEnabled() == false,
        "dash disabled for read-only users")
    if roDash then
        roDash:GetScript("OnClick")(roDash)
    end
    assertTrue(UIPage._GetAltDraftForTests() == nil,
        "read-only dash click cannot start an alternative")
    ActAs("Alice-Garona", "Player-1-Alice")
    UIPage:Refresh(panel, { force = true })

    -- 3. Remove Alt lives inside the alt editor and preserves the main signup.
    assertEq(select(1, RS:UpsertEntry({
        planId = tabPlanId, nickname = "AltTest",
        mainClass = "MAGE", mainSpec = 62, notes = "keep me",
        altClass = "WARRIOR", altSpec = 71,
    })), "accepted", "alt test entry created")
    UIPage:Refresh(panel, { force = true })
    local altEntry = EntryByNick("AltTest")
    assertTrue(altEntry ~= nil, "alt test entry found")
    -- Add-alt flow (no alternative yet) has no Remove Alt action.
    UIPage._SetAltDraftForTests({
        entryId = dashEntry.entryId,
        draft = RS.MakeAltDraft(dashEntry),
    })
    UIPage:Refresh(panel, { force = true })
    local removeButtons = {}
    WalkAll(entriesHost, function(f)
        if f.GetObjectType and f:GetObjectType() == "Button" and f.GetText
            and f:GetText() == "Remove Alt" then
            removeButtons[#removeButtons + 1] = f
        end
    end)
    assertEq(#removeButtons, 0, "add-alt editor offers no Remove Alt")
    -- Alt editor for an entry that has an alternative does.
    UIPage._SetAltDraftForTests({
        entryId = altEntry.entryId,
        draft = RS.MakeAltDraft(altEntry),
    })
    UIPage:Refresh(panel, { force = true })
    removeButtons = {}
    WalkAll(entriesHost, function(f)
        if f.GetObjectType and f:GetObjectType() == "Button" and f.GetText
            and f:GetText() == "Remove Alt" then
            removeButtons[#removeButtons + 1] = f
        end
    end)
    assertEq(#removeButtons, 1, "alt editor shows Remove Alt")
    if #removeButtons == 1 then
        removeButtons[1]:GetScript("OnClick")(removeButtons[1])
    end
    local afterRemoval = EntryByNick("AltTest")
    assertTrue(afterRemoval ~= nil, "main signup survives alt removal")
    assertEq(afterRemoval.mainClass, "MAGE", "main class preserved")
    assertEq(afterRemoval.mainSpec, 62, "main spec preserved")
    assertEq(afterRemoval.nickname, "AltTest", "nickname preserved")
    assertEq(afterRemoval.notes or "", "keep me", "notes preserved")
    assertTrue(afterRemoval.altClass == nil, "alternative removed")
    assertTrue(UIPage._GetAltDraftForTests() == nil, "editor closes after removal")
    UIPage:Refresh(panel, { force = true })

    -- 4. The compact X keeps the confirmation flow and deletes its entry.
    assertEq(select(1, RS:UpsertEntry({
        planId = tabPlanId, nickname = "DeleteMe",
        mainClass = "MAGE", mainSpec = 62,
    })), "accepted", "delete test entry created")
    UIPage:Refresh(panel, { force = true })
    local delEntry = EntryByNick("DeleteMe")
    assertTrue(delEntry ~= nil, "delete test entry found")
    local delX = nil
    for _, b in ipairs(FindButtonsByTooltip("Delete signup")) do
        if b._parent and RowHasText(b._parent, "DeleteMe") then
            delX = b
            break
        end
    end
    assertTrue(delX ~= nil, "compact delete X rendered")
    if delX then
        assertTrue(delX.GetWidth and delX:GetWidth() <= 28,
            "delete control is compact, not a wide button")
    end
    local savedDialogs = SF.SettingsUI.Dialogs
    local confirmCalls = {}
    SF.SettingsUI.Dialogs = {
        Confirm = function(_, msg, title, commit)
            confirmCalls[#confirmCalls + 1] = { msg = msg, title = title, commit = commit }
        end,
    }
    if delX then
        delX:GetScript("OnClick")(delX)
    end
    assertEq(#confirmCalls, 1, "delete still asks for confirmation")
    assertEq(confirmCalls[1] and confirmCalls[1].msg, "Delete this signup entry?",
        "confirmation text preserved")
    assertTrue(EntryByNick("DeleteMe") ~= nil, "entry kept until confirmed")
    if confirmCalls[1] and confirmCalls[1].commit then
        confirmCalls[1].commit()
        UIPage:Refresh(panel, { force = true })
        assertTrue(EntryByNick("DeleteMe") == nil, "confirmed delete removes the entry")
    end
    SF.SettingsUI.Dialogs = savedDialogs

    -- 5. Geometry: hover region and X stay inside the signup column, separated
    -- from the note preview, at the current and a narrow width.
    for _, width in ipairs({ nil, 548 }) do
        boardHost._w = width
        UIPage:Refresh(panel, { force = true })
        local g = panel.__sfEntryGeom
        assertTrue(g ~= nil, "row geometry present at width " .. tostring(width))
        if not g then
            break
        end
        assertEq(g.rightReserve, 28, "only the compact X is reserved")
        local anyHover = nil
        for _, h in ipairs(FindHovers()) do
            if h.__sfHoverText and h.__sfHoverText ~= "" then
                anyHover = h
                break
            end
        end
        if anyHover then
            local rightX = nil
            for _, pt in ipairs(anyHover._points or {}) do
                if pt[1] == "BOTTOMRIGHT" then
                    rightX = pt[4]
                end
            end
            assertEq(rightX, -(28 + 4),
                "note hover region clears the delete X at width " .. tostring(width))
        end
        local xs = FindButtonsByTooltip("Delete signup")
        assertTrue(#xs >= 1, "delete X present at width " .. tostring(width))
        if #xs < 1 then
            break
        end
        local xRight = nil
        for _, pt in ipairs(xs[1]._points or {}) do
            if pt[1] == "RIGHT" then
                xRight = pt[4]
            end
        end
        assertEq(xRight, -4, "delete X hugs the row's right edge")
        assertTrue(g.notesX + 24 <= g.leftW - 28,
            "notes region and X do not overlap at width " .. tostring(width))
    end
    boardHost._w = nil
    UIPage:Refresh(panel, { force = true })
end
RaidSignupRowActionTests(panel, UIPage, RS, tabPlanId)

    -- Two hosts (Blizzard Settings panel + standalone window) each get rebuilt
    -- and refreshed; hosts keep their own panel association.
    local savedPanels = UIPage._builtPanels
    UIPage._builtPanels = {}
    local panelA2 = NewPagePanel()
    local panelB2 = NewPagePanel()
    UIPage:Build(panelA2)
    UIPage:Build(panelB2)
    UIPage._ResetSessionForTests()
    local refreshedPanels = UIPage._RefreshShownPanelsForTests()
    assertEq(refreshedPanels, 2, "queued refresh reaches every shown host")
    assertEq(panelA2.__sfRaidSignupSummaryHost.__sfRaidSignupPanel, panelA2,
        "summary host bound to first panel")
    assertEq(panelB2.__sfRaidSignupSummaryHost.__sfRaidSignupPanel, panelB2,
        "summary host bound to second panel")
    UIPage._builtPanels = savedPanels
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
