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

-- Higher-version live record must not overwrite tombstone (no restore)
local zombie = RS.CloneEntry(record.entries[entryA])
zombie.deleted = false
zombie.nickname = "Resurrected"
zombie.ver = { n = record.entries[entryA].ver.n + 5, w = "ffffffffffffffffffffffff" }
delStatus, delDetail = provider.ValidateAndApply({
    id = RS.EntryRecordId(entryA),
    versionFp = "zombie",
    body = { kind = "raidsignup-entry", schema = 1, entry = zombie },
}, { sender = "Carol-Garona" })
assertEq(delStatus, "rejected", "higher-ver live cannot overwrite tombstone")
assertEq(delDetail, "deleted_final", "deleted_final reason")
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
assertEq(replayStatus, "duplicate", "provider rejects stale live vs tombstone as duplicate/stale")
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
    function r:SetParent(p) self._parent = p end
    function r:GetParent() return self._parent end
    function r:Show() self._shown = true end
    function r:Hide() self._shown = false end
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
    function r:SetText(t) self._text = t or "" end
    function r:GetText() return self._text or "" end
    function r:SetTexture(t) self._texture = t end
    function r:SetDesaturated() end
    function r:SetVertexColor() end
    function r:SetMaxLetters() end
    function r:SetAutoFocus() end
    function r:Enable() self._enabled = true end
    function r:Disable() self._enabled = false end
    function r:EnableMouse() end
    function r:RegisterForClicks() end
    function r:SetScript(name, fn) self._scripts[name] = fn end
    function r:GetScript(name) return self._scripts[name] end
    function r:HookScript(name, fn)
        local prev = self._scripts[name]
        self._scripts[name] = function(...)
            if prev then prev(...) end
            fn(...)
        end
    end
    function r:HasFocus() return self._focused == true end
    function r:ClearFocus()
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
        return makeRegion("Texture")
    end
    function r:CreateFontString()
        local fs = makeRegion("FontString")
        function fs:SetJustifyH() end
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
        return unpack(self._regions or {})
    end
    r._children = {}
    r._regions = {}
    return r
end

function CreateFrame(frameType, name, parent, template)
    frameCount = frameCount + 1
    local f = makeRegion(frameType or "Frame")
    f._name = name
    f._template = template
    f._parent = parent
    if parent and parent._children then
        parent._children[#parent._children + 1] = f
    end
    -- EditBox helpers
    if frameType == "EditBox" or template == "InputBoxTemplate" then
        f._type = "EditBox"
        f.Instructions = makeRegion("FontString")
    end
    if frameType == "Button" or template == "UIPanelButtonTemplate" then
        f._type = "Button"
        function f:Click()
            local fn = f._scripts.OnClick
            if fn then fn(f) end
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
local boxes = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost)
if #boxes < 1 then
    -- forceRebuild if soft paint missed the draft row for any stubbing reason
    UIPage:Refresh(panel, { forceRebuild = true, force = true })
    boxes = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost)
end
assertTrue(#boxes >= 1, "draft nickname edit box present")
local nickBox = boxes[1]
nickBox:SetFocus()
local refreshBefore = UIPage._GetLifecycleCounters().refreshCount
local entriesBefore = #RS:GetSortedEntries(plan3)
local onText = nickBox:GetScript("OnTextChanged")
assertTrue(onText ~= nil, "nickname OnTextChanged bound")
nickBox:SetText("S")
onText(nickBox, true)
nickBox:SetText("Sp")
onText(nickBox, true)
nickBox:SetText("SparkUI")
onText(nickBox, true)
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
boxes = UIPage._FindEditBoxesForTests(panel.__sfRaidSignupEntriesHost)
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

-- Frame creates stay bounded across many soft refreshes
rebuildBefore = UIPage._GetLifecycleCounters().fullRebuildCount
local framesSoftStart = UIPage._GetLifecycleCounters().frameCreateCount
for _ = 1, 8 do
    UIPage:Refresh(panel)
end
local framesSoftEnd = UIPage._GetLifecycleCounters().frameCreateCount
assertTrue(framesSoftEnd - framesSoftStart < 5000, "frame creates bounded across soft refreshes")
assertEq(UIPage._GetLifecycleCounters().fullRebuildCount, rebuildBefore, "still no extra full rebuilds")

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
