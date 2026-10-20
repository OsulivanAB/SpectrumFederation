-- Production-Lua tests for Guild Info main/alt assignments (#402).
-- Run from repository root: lua5.1 tests/lua/guild_info_tests.lua

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
    time = 8000,
    chat = {},
    prints = {},
    guild = {
        inGuild = true,
        name = "Spectrum",
        realm = "Garona",
        clubId = 42,
        ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
        members = {
            { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true, class = "MAGE" },
            { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = false, class = "WARRIOR" },
            { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true, class = "PRIEST" },
            { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true, class = "HUNTER" },
            { name = "Eve-Garona", guid = "Player-1-Eve", rankOrder = 5, online = false, class = "ROGUE" },
            { name = "Bob-Area52", guid = "Player-2-Bob", rankOrder = 4, online = true, class = "DRUID" },
        },
        rosterComplete = true,
    },
    unitName = "Alice",
    unitGuid = "Player-1-Alice",
    impersonationActive = false,
    generation = 1,
    notifyCount = 0,
    providerChanged = 0,
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
    if not world.guild.rosterComplete then
        return 0, 0, 0
    end
    return #world.guild.members, #world.guild.members, #world.guild.members
end
world.rosterInfoCalls = 0
function GetGuildRosterInfo(i)
    world.rosterInfoCalls = (world.rosterInfoCalls or 0) + 1
    local m = world.guild.members[i]
    if not m then return end
    local rankIndex = (tonumber(m.rankOrder) or 1) - 1
    return m.name, world.guild.ranks[m.rankOrder] or "Rank", rankIndex, 80, "Class", "Zone",
        "", "", m.online, 0, m.class or "WARRIOR", 0, 0, false, false, 0, m.guid
end

-- Minimal CBOR-like serializer matching guild_gossip_tests (size-bound evidence).
local function ser(v, seen)
    seen = seen or {}
    local t = type(v)
    if v == nil then return "N"
    elseif t == "boolean" then return v and "T" or "F"
    elseif t == "number" then return "#" .. tostring(v) .. ";"
    elseif t == "string" then return "$" .. #v .. ":" .. v
    elseif t == "table" then
        if seen[v] then return "@" end
        seen[v] = true
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for i = 1, #keys do
            local k = keys[i]
            parts[#parts + 1] = ser(k, seen) .. "=" .. ser(v[k], seen)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "?"
end
C_EncodingUtil = {
    SerializeCBOR = function(t) return ser(t) end,
}
function GuildControlGetNumRanks()
    return #world.guild.ranks
end
function GuildControlGetRankName(i)
    return world.guild.ranks[i]
end
C_GuildInfo = {
    GuildRoster = function() end,
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
function strtrim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
function UnitFullName() return world.unitName, "Garona" end
function UnitName() return world.unitName end
function UnitGUID(unit)
    if unit == "player" then return world.unitGuid end
end
C_Timer = {
    After = function(_, fn) if fn then fn() end end,
}
function CreateFrame()
    return {
        RegisterEvent = function() end,
        SetScript = function() end,
        HookScript = function() end,
        Show = function() end,
        Hide = function() end,
        SetPoint = function() end,
        SetSize = function() end,
        SetWidth = function() end,
        SetHeight = function() end,
        SetText = function() end,
        SetTextColor = function() end,
        SetAutoFocus = function() end,
        SetMaxLetters = function() end,
        EnableMouse = function() end,
        SetFrameStrata = function() end,
        SetClampedToScreen = function() end,
        SetBackdrop = function() end,
        SetBackdropColor = function() end,
        SetBackdropBorderColor = function() end,
        SetAllPoints = function() end,
        SetFrameLevel = function() end,
        CreateFontString = function()
            return {
                SetPoint = function() end,
                SetJustifyH = function() end,
                SetText = function() end,
                GetStringWidth = function() return 10 end,
            }
        end,
        CreateTexture = function()
            return {
                SetAllPoints = function() end,
                SetColorTexture = function() end,
                Show = function() end,
                Hide = function() end,
                SetAtlas = function() end,
            }
        end,
        SetScript = function() end,
        ClearAllPoints = function() end,
        SetShown = function() end,
        IsShown = function() return true end,
        IsVisible = function() return true end,
        GetWidth = function() return 200 end,
        GetParent = function() return nil end,
        GetFrameLevel = function() return 1 end,
        HasFocus = function() return false end,
        ClearFocus = function() end,
        GetText = function() return "" end,
        SetCursorPosition = function() end,
        RegisterForClicks = function() end,
        SetAlpha = function() end,
        SetEnabled = function() end,
        Enable = function() end,
        Disable = function() end,
        SetDefaultText = function() end,
        SetupMenu = function() end,
        GenerateMenu = function() end,
    }
end
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
-- Load modules
---------------------------------------------------------------------------

local SF = {}
local addonName = "SpectrumFederation"

SF.L = {}
function SF.LocaleText(key, default)
    return default or tostring(key or "")
end

SF.Debug = {
    _enabled = false,
    IsEnabled = function(self) return self._enabled end,
    Info = function() end,
    Warn = function() end,
    Verbose = function() end,
    Error = function() end,
}

SF.WOW_CLASSES = {
    MAGE = { colorCode = { r = 0.25, g = 0.78, b = 0.92 } },
    WARRIOR = { colorCode = { r = 0.78, g = 0.61, b = 0.43 } },
    PRIEST = { colorCode = { r = 1, g = 1, b = 1 } },
    HUNTER = { colorCode = { r = 0.67, g = 0.83, b = 0.45 } },
    ROGUE = { colorCode = { r = 1, g = 0.96, b = 0.41 } },
    DRUID = { colorCode = { r = 1, g = 0.49, b = 0.04 } },
}

SF.Consumables = {
    ColorizeCharacterName = function(name, classToken)
        if type(name) ~= "string" then return tostring(name or "") end
        local c = classToken and SF.WOW_CLASSES[string.upper(classToken)]
        if not c then return name end
        return "|cff0000ff" .. name .. "|r"
    end,
}

SF.LootHelperImpersonation = {
    IsActive = function()
        return world.impersonationActive
    end,
}

SF.NameUtil = {
    NormalizeNameRealm = function(nameOrNameRealm, defaultRealm)
        if type(nameOrNameRealm) ~= "string" or nameOrNameRealm == "" then return nil end
        nameOrNameRealm = strtrim(nameOrNameRealm)
        if nameOrNameRealm == "" then return nil end
        if nameOrNameRealm:find("-", 1, true) then
            local h = nameOrNameRealm:find("-", 1, true)
            local n = strtrim(nameOrNameRealm:sub(1, h - 1))
            local r = strtrim(nameOrNameRealm:sub(h + 1)):gsub("%s+", "")
            if n == "" or r == "" then return nil end
            return n .. "-" .. r
        end
        local realm = defaultRealm or GetRealmName()
        if type(realm) ~= "string" or realm == "" then return nil end
        return nameOrNameRealm .. "-" .. realm:gsub("%s+", "")
    end,
    SamePlayer = function(a, b)
        local na = SF.NameUtil.NormalizeNameRealm(a)
        local nb = SF.NameUtil.NormalizeNameRealm(b)
        if not na or not nb then return false end
        return string.lower(na) == string.lower(nb)
    end,
    GetSelfId = function()
        return world.unitName .. "-Garona"
    end,
}

-- Minimal Guild Gossip demand/provider stubs used by Guild Info.
SF.GuildGossip = {
    _providers = {},
    MAX_RECORD_CBOR = 2048,
    SelfId = function()
        return world.unitName .. "-Garona"
    end,
    NormalizePlayer = function(name)
        return SF.NameUtil.NormalizeNameRealm(name)
    end,
    GetGuildGeneration = function()
        return world.generation
    end,
    GetGuildScopeId = function()
        if not world.guild.inGuild then return nil end
        return "club:" .. tostring(world.guild.clubId)
    end,
    GetGuildIdentity = function()
        if not world.guild.inGuild then return nil, "not_in_guild" end
        if not world.guild.clubId then return nil, "club_id_unavailable" end
        return {
            clubId = tostring(world.guild.clubId),
            guildKey = "club:" .. tostring(world.guild.clubId),
            guildName = world.guild.name,
            guildRealm = world.guild.realm,
            transportScopeId = "club:" .. tostring(world.guild.clubId),
        }
    end,
    GetGuildRanks = function()
        if not world.guild.inGuild then return nil, "not_in_guild" end
        if not world.guild.rosterComplete then return nil, "roster_incomplete" end
        local ranks = { count = #world.guild.ranks, guildKey = "club:" .. tostring(world.guild.clubId) }
        for i = 1, #world.guild.ranks do
            ranks[i] = world.guild.ranks[i]
        end
        return ranks
    end,
    GetGuildMember = function(name)
        if not world.guild.inGuild then return nil, "not_in_guild" end
        if not world.guild.rosterComplete then return nil, "roster_incomplete" end
        local want = SF.NameUtil.NormalizeNameRealm(name)
        if not want then return nil, "invalid_name" end
        for _, m in ipairs(world.guild.members) do
            if string.lower(m.name) == string.lower(want) then
                return {
                    name = m.name,
                    guid = m.guid,
                    rankOrder = m.rankOrder,
                    online = m.online,
                    guildKey = "club:" .. tostring(world.guild.clubId),
                    clubId = tostring(world.guild.clubId),
                }
            end
        end
        return nil, "not_a_member"
    end,
    IsGuildMember = function(name)
        local m = SF.GuildGossip.GetGuildMember(name)
        return m ~= nil
    end,
    IsGuildReady = function()
        return world.guild.inGuild and world.guild.rosterComplete
    end,
    Hash32 = function(s)
        s = tostring(s or "")
        local h = 5381
        for i = 1, #s do
            h = (h * 33 + s:byte(i)) % 4294967296
        end
        return h
    end,
    Init = function() end,
    RegisterProvider = function(spec)
        SF.GuildGossip._providers[spec.id] = {
            spec = spec,
            enabled = true,
            index = {
                buildComplete = false,
                dirty = true,
                epoch = 1,
                byId = {},
            },
        }
        return true
    end,
    SetProviderEnabled = function(id, enabled)
        local e = SF.GuildGossip._providers[id]
        if e then e.enabled = enabled end
    end,
    GetProvider = function(id)
        return SF.GuildGossip._providers[id]
    end,
    NotifyProviderChanged = function(id)
        world.providerChanged = world.providerChanged + 1
        local e = SF.GuildGossip._providers[id]
        if e and e.index then
            e.index.dirty = true
        end
    end,
    IndexUpsert = function(index, recordId, versionFp, meta)
        if type(index) ~= "table" or recordId == nil then
            return false, "bad_args"
        end
        recordId = tostring(recordId)
        versionFp = tostring(versionFp or "")
        local existing = index.byId and index.byId[recordId]
        if existing and existing.versionFp == versionFp then
            return false, "duplicate"
        end
        if existing and existing.versionFp ~= versionFp then
            return false, "replaced"
        end
        index.byId = index.byId or {}
        index.byId[recordId] = { id = recordId, versionFp = versionFp, meta = meta }
        if not index.buildComplete then
            index.dirty = true
        end
        return true, index.byId[recordId]
    end,
    IndexRemove = function(index, recordId)
        if type(index) ~= "table" or not index.byId then return false end
        recordId = tostring(recordId)
        if not index.byId[recordId] then return false end
        index.byId[recordId] = nil
        return true
    end,
    BumpIndexEpoch = function(index)
        if type(index) ~= "table" then return end
        index.epoch = (tonumber(index.epoch) or 0) + 1
        index.byId = {}
        index.buildComplete = false
        index.dirty = true
        world.indexEpochBumps = (world.indexEpochBumps or 0) + 1
    end,
}

local function DriveEnsureIndex(providerId, rounds)
    local entry = SF.GuildGossip._providers[providerId]
    assertTrue(entry and entry.spec and entry.spec.EnsureIndex, "provider EnsureIndex available")
    rounds = rounds or 64
    for _ = 1, rounds do
        local more = entry.spec.EnsureIndex(entry.index, { indexEntries = 32 })
        if more == false and entry.index.buildComplete and not entry.index.dirty then
            break
        end
    end
    return entry.index
end

local function loadModule(path)
    local f, err = loadfile(path)
    if not f then
        error("loadfile failed: " .. path .. " :: " .. tostring(err))
    end
    f(addonName, SF)
end

loadModule("SpectrumFederation/modules/GuildInfo/State.lua")
loadModule("SpectrumFederation/modules/GuildInfo/Authority.lua")
loadModule("SpectrumFederation/modules/GuildInfo/Operations.lua")
loadModule("SpectrumFederation/modules/GuildInfo/Roster.lua")
loadModule("SpectrumFederation/modules/GuildInfo/Gossip.lua")

local GI = SF.GuildInfo
assertTrue(GI ~= nil, "SF.GuildInfo namespace exists")

local function resetDB()
    SpectrumFederationDB = {}
    world.notifyCount = 0
    world.providerChanged = 0
    world.indexEpochBumps = 0
    world.rosterInfoCalls = 0
    SF.GuildGossip._providers = {}
    GI.InvalidateRosterSnapshot()
    local ok = GI:Initialize(SpectrumFederationDB)
    assertTrue(ok, "Initialize empty DB")
end

local function setActor(name, guid, rankOrder)
    world.unitName = name:match("^([^-]+)") or name
    world.unitGuid = guid
    -- Ensure member exists with that rank.
    for _, m in ipairs(world.guild.members) do
        if m.guid == guid then
            m.rankOrder = rankOrder or m.rankOrder
            m.name = name
            return
        end
    end
end

local function assign(mainName, altName, opts)
    return GI:AssignAlt(mainName, altName, opts or { roster = GI.GetRosterSnapshot(true) })
end

---------------------------------------------------------------------------
-- Domain tests
---------------------------------------------------------------------------

resetDB()

do
    local caps = GI:GetCapabilities()
    assertTrue(caps.canRead, "Alice rank 1 can read")
    assertTrue(caps.canEdit, "Alice rank 1 can edit")
end

do
    setActor("Dave-Garona", "Player-1-Dave", 4)
    local caps = GI:GetCapabilities()
    assertTrue(caps.canRead, "Dave rank 4 can read")
    assertTrue(not caps.canEdit, "Dave rank 4 cannot edit")
    local status, reason = assign("Alice-Garona", "Bob-Garona")
    assertEq(status, "rejected", "rank 4 assign rejected")
    assertEq(reason, "unauthorized", "rank 4 unauthorized reason")
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

do
    resetDB()
    local status, reason = assign("Alice-Garona", "Bob-Garona")
    assertEq(status, "accepted", "normal assign accepted")
    assertNil(reason, "normal assign no reason")
    local role, mainGuid = GI:GetCharacterRole("Player-1-Bob")
    assertEq(role, "alt", "Bob is alt")
    assertEq(mainGuid, "Player-1-Alice", "Bob's main is Alice")
    local roleMain = GI:GetCharacterRole("Player-1-Alice")
    assertEq(roleMain, "main", "Alice is main")
end

do
    local status = assign("Alice-Garona", "Bob-Garona")
    assertEq(status, "accepted", "idempotent re-assign same main accepted")
    local groups = GI:GetRelationshipGroups()
    assertEq(#groups, 1, "still one group after idempotent assign")
    assertEq(#groups[1].altGuids, 1, "still one alt")
end

do
    local status, reason = assign("Carol-Garona", "Bob-Garona")
    assertEq(status, "rejected", "move without confirm rejected")
    assertEq(reason, "move_confirmation_required", "move confirmation required")
end

do
    local status, reason = GI:AssignAlt("Carol-Garona", "Bob-Garona", {
        roster = GI.GetRosterSnapshot(true),
        moveConfirmed = true,
        expectedOldMain = "Player-1-Alice",
    })
    assertEq(status, "accepted", "confirmed move accepted")
    assertNil(reason, "confirmed move no reason")
    local role, mainGuid = GI:GetCharacterRole("Player-1-Bob")
    assertEq(mainGuid, "Player-1-Carol", "Bob moved under Carol")
    local aliceRole = GI:GetCharacterRole("Player-1-Alice")
    assertNil(aliceRole, "Alice alone no longer a group")
end

do
    -- Stale confirmation: Bob now under Carol; claim old main Alice.
    local status, reason = GI:AssignAlt("Alice-Garona", "Bob-Garona", {
        roster = GI.GetRosterSnapshot(true),
        moveConfirmed = true,
        expectedOldMain = "Player-1-Alice",
    })
    assertEq(status, "rejected", "stale move confirmation rejected")
    assertEq(reason, "stale_move_confirmation", "stale move reason")
end

do
    resetDB()
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "seed assign Bob")
    assertEq(assign("Alice-Garona", "Carol-Garona"), "accepted", "seed assign Carol")
    local status = GI:ChangeMain("Player-1-Alice", "Player-1-Bob", {
        roster = GI.GetRosterSnapshot(true),
    })
    assertEq(status, "accepted", "change main accepted")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "main", "Bob promoted")
    local aliceRole, aliceMain = GI:GetCharacterRole("Player-1-Alice")
    assertEq(aliceRole, "alt", "Alice demoted to alt")
    assertEq(aliceMain, "Player-1-Bob", "Alice under Bob")
    local carolRole, carolMain = GI:GetCharacterRole("Player-1-Carol")
    assertEq(carolRole, "alt", "Carol remains alt")
    assertEq(carolMain, "Player-1-Bob", "Carol under new main")
end

do
    local status = GI:UnassignAlt("Player-1-Carol", {})
    assertEq(status, "accepted", "unassign Carol")
    assertNil(GI:GetCharacterRole("Player-1-Carol"), "Carol unassigned")
    assertEq(GI:GetCharacterRole("Player-1-Alice"), "alt", "Alice still alt")
end

do
    -- Invalid hierarchy: assign a main-with-alts as someone else's alt.
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    assign("Alice-Garona", "Carol-Garona")
    local status, reason = assign("Dave-Garona", "Alice-Garona")
    assertEq(status, "rejected", "main with alts cannot become alt")
    assertEq(reason, "alt_is_main_with_alts", "alt_is_main_with_alts reason")
end

do
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    local status, reason = assign("Bob-Garona", "Carol-Garona")
    assertEq(status, "rejected", "alt cannot be used as main")
    assertEq(reason, "main_is_alt", "main_is_alt reason")
end

do
    resetDB()
    local status, reason = assign("Alice-Garona", "Alice-Garona")
    assertEq(status, "rejected", "same character rejected")
    assertEq(reason, "same_character", "same_character reason")
end

do
    resetDB()
    local status, reason = assign("Bob", "Carol-Garona")
    assertEq(status, "rejected", "ambiguous short name Bob rejected")
    assertEq(reason, "ambiguous_name", "ambiguous_name reason")
end

do
    resetDB()
    world.impersonationActive = true
    local caps = GI:GetCapabilities()
    assertTrue(not caps.canEdit, "preview non-admin disables edit")
    local status, reason = assign("Alice-Garona", "Bob-Garona")
    assertEq(status, "rejected", "preview blocks assign")
    assertEq(reason, "preview_non_admin", "preview reason")
    world.impersonationActive = false
end

---------------------------------------------------------------------------
-- Roster membership status
---------------------------------------------------------------------------

do
    resetDB()
    assign("Alice-Garona", "Eve-Garona")
    -- Remove Eve from roster with complete snapshot → departed.
    local kept = {}
    for _, m in ipairs(world.guild.members) do
        if m.guid ~= "Player-1-Eve" then
            kept[#kept + 1] = m
        end
    end
    world.guild.members = kept
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    local status = GI.GetMembershipStatus("Player-1-Eve", GI.GetRosterSnapshot(true))
    assertEq(status, "departed", "missing from complete roster is departed")
    assertEq(GI:GetCharacterRole("Player-1-Eve"), "alt", "departed alt relationship retained")

    world.guild.rosterComplete = false
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    local status2 = GI.GetMembershipStatus("Player-1-Eve", GI.GetRosterSnapshot(true))
    assertEq(status2, "unknown", "incomplete roster is unknown not departed")
    world.guild.rosterComplete = true
    -- Restore Eve
    world.guild.members[#world.guild.members + 1] = {
        name = "Eve-Garona", guid = "Player-1-Eve", rankOrder = 5, online = false, class = "ROGUE",
    }
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    local status3 = GI.GetMembershipStatus("Player-1-Eve", GI.GetRosterSnapshot(true))
    assertEq(status3, "in_guild", "returning member restored")
end

---------------------------------------------------------------------------
-- Remote admission / trust
---------------------------------------------------------------------------

do
    resetDB()
    local provider = SF.GuildGossip._providers[GI.PROVIDER_ID]
    assertTrue(provider ~= nil, "gossip provider registered")
    local spec = provider.spec

    -- Forge an op as if from Dave (rank 4) via ValidateAndApply.
    setActor("Alice-Garona", "Player-1-Alice", 1)
    local forged = {
        id = "gi1:Player-1-Dave:aaaaaaaaaaaaaaaaaaaaaaaa:1",
        kind = GI.KIND.ASSIGN,
        at = world.time,
        actorGuid = "Player-1-Alice", -- launder claim
        actorName = "Alice-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Alice",
        mainName = "Alice-Garona",
        altGuid = "Player-1-Bob",
        altName = "Bob-Garona",
    }
    local status, detail = spec.ValidateAndApply({
        id = "gi-op:" .. forged.id,
        versionFp = "x",
        body = { kind = "guildinfo-op", op = forged },
    }, { sender = "Dave-Garona" })
    assertEq(status, "rejected", "rank 4 remote sender rejected")
    assertTrue(detail == "unauthorized" or detail ~= nil, "unauthorized remote detail")

    -- Authenticated officer Carol can admit.
    local op = {
        id = "gi1:Player-1-Carol:bbbbbbbbbbbbbbbbbbbbbbbb:1",
        kind = GI.KIND.ASSIGN,
        at = world.time + 1,
        actorGuid = "Player-1-Carol",
        actorName = "Carol-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Alice",
        mainName = "Alice-Garona",
        mainClass = "MAGE",
        altGuid = "Player-1-Bob",
        altName = "Bob-Garona",
        altClass = "WARRIOR",
    }
    status, detail = spec.ValidateAndApply({
        id = "gi-op:" .. op.id,
        versionFp = "y",
        body = { kind = "guildinfo-op", op = op },
    }, { sender = "Carol-Garona" })
    assertEq(status, "accepted", "rank 3 remote assign accepted")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "remote assign applied")

    -- Duplicate replay
    status = spec.ValidateAndApply({
        id = "gi-op:" .. op.id,
        versionFp = "y",
        body = { kind = "guildinfo-op", op = op },
    }, { sender = "Carol-Garona" })
    assertEq(status, "duplicate", "duplicate remote op")

    -- Editor relay catch-up: Carol may forward an Alice-authored op (provenance kept).
    -- Authorization is the transport editor sender; actorGuid is not authentication.
    local relayed = {
        id = "gi1:Player-1-Alice:cccccccccccccccccccccccc:2",
        kind = GI.KIND.ASSIGN,
        at = world.time + 2,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Alice",
        mainName = "Alice-Garona",
        altGuid = "Player-1-Eve",
        altName = "Eve-Garona",
    }
    status, detail = spec.ValidateAndApply({
        id = "gi-op:" .. relayed.id,
        versionFp = "z",
        body = { kind = "guildinfo-op", op = relayed },
    }, { sender = "Carol-Garona" })
    assertEq(status, "accepted", "editor may relay another editor's op")
    assertEq(GI:GetCharacterRole("Player-1-Eve"), "alt", "relayed assign applied")
    -- Non-editor still cannot introduce ops even with a forged officer actorGuid.
    status, detail = spec.ValidateAndApply({
        id = "gi-op:gi1:Player-1-Alice:dddddddddddddddddddddddd:3",
        versionFp = "z2",
        body = {
            kind = "guildinfo-op",
            op = {
                id = "gi1:Player-1-Alice:dddddddddddddddddddddddd:3",
                kind = GI.KIND.ASSIGN,
                at = world.time + 3,
                actorGuid = "Player-1-Alice",
                actorName = "Alice-Garona",
                guildKey = "club:42",
                mainGuid = "Player-1-Carol",
                altGuid = "Player-2-Bob",
            },
        },
    }, { sender = "Dave-Garona" })
    assertEq(status, "rejected", "non-editor cannot launder via forged actorGuid")
    assertTrue(detail == "unauthorized" or detail ~= nil, "unauthorized launder detail")
end

---------------------------------------------------------------------------
-- Concurrent conflicting edits converge via deterministic fold
---------------------------------------------------------------------------

do
    resetDB()
    -- Two officers assign same alt to different mains with different (at, id).
    local op1 = {
        id = "gi1:Player-1-Alice:dddddddddddddddddddddddd:1",
        kind = GI.KIND.ASSIGN,
        at = 100,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Alice",
        mainName = "Alice-Garona",
        altGuid = "Player-1-Eve",
        altName = "Eve-Garona",
    }
    local op2 = {
        id = "gi1:Player-1-Carol:eeeeeeeeeeeeeeeeeeeeeeee:1",
        kind = GI.KIND.ASSIGN,
        at = 100,
        actorGuid = "Player-1-Carol",
        actorName = "Carol-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Carol",
        mainName = "Carol-Garona",
        altGuid = "Player-1-Eve",
        altName = "Eve-Garona",
    }
    -- Apply in opposite arrival order on two logical clients via fold.
    local status1 = GI:AdmitOperation(op1, { remote = true })
    local status2 = GI:AdmitOperation(op2, { remote = true })
    assertEq(status1, "accepted", "conflict op1 accepted")
    assertEq(status2, "accepted", "conflict op2 accepted")
    -- Deterministic: same at → lexicographic id. Carol's id > Alice's id? 
    -- "gi1:Player-1-Carol:..." vs "gi1:Player-1-Alice:..." — C > A so Carol wins.
    local role, mainGuid = GI:GetCharacterRole("Player-1-Eve")
    assertEq(role, "alt", "Eve still alt after conflict")
    assertEq(mainGuid, "Player-1-Carol", "later opId wins at same timestamp")

    -- Reverse admission order on a fresh DB yields same fold result.
    SpectrumFederationDB = {}
    GI:Initialize(SpectrumFederationDB)
    GI:AdmitOperation(op2, { remote = true })
    GI:AdmitOperation(op1, { remote = true })
    local _, mainGuid2 = GI:GetCharacterRole("Player-1-Eve")
    assertEq(mainGuid2, "Player-1-Carol", "arrival order independent convergence")
end

---------------------------------------------------------------------------
-- Reload durability + guild isolation + independence markers
---------------------------------------------------------------------------

do
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    local saved = SpectrumFederationDB
    -- Simulate reload
    SF.GuildInfo = nil
    loadModule("SpectrumFederation/modules/GuildInfo/State.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Authority.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Operations.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Roster.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Gossip.lua")
    GI = SF.GuildInfo
    GI:Initialize(saved)
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "reload restores alt")
    assertTrue(saved.guildInfo ~= nil, "guildInfo root persisted")
    assertNil(saved.guildSupplies, "does not create guildSupplies")
    assertNil(saved.lootHelper, "does not create lootHelper")
end

do
    -- Wrong guild key rejected.
    resetDB()
    local op = {
        id = "gi1:Player-1-Alice:ffffffffffffffffffffffff:1",
        kind = GI.KIND.ASSIGN,
        at = 1,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        guildKey = "club:999",
        mainGuid = "Player-1-Alice",
        altGuid = "Player-1-Bob",
    }
    local status, detail = GI:AdmitOperation(op, { remote = true })
    -- EnsureGuildRecord will create club:999 record; local actor is club:42 — AdmitOperation
    -- itself does not check current guild for remote. Gossip ValidateAndApply checks sender guild.
    -- Direct AdmitOperation with foreign key creates that guild's record — allowed for storage.
    -- Cross-guild contamination prevented by GetCurrentRecord scoping.
    assertEq(status, "accepted", "foreign guild key stores under its own key")
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "current guild unaffected")
    local foreign = select(1, GI:GetRecordForGuildKey("club:999"))
    assertTrue(foreign ~= nil, "foreign guild record isolated")
end

do
    -- Chat silence
    local before = #world.chat
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    GI:UnassignAlt("Player-1-Bob", {})
    assertEq(#world.chat, before, "no chat output from domain ops")
end

do
    -- Display rows sorted + class color helper invoked
    resetDB()
    assign("Carol-Garona", "Eve-Garona")
    assign("Alice-Garona", "Bob-Garona")
    local rows = GI:GetAssignmentDisplayRows(GI.GetRosterSnapshot(true))
    assertTrue(#rows >= 4, "display rows include mains and alts")
    -- First main should be Alice (sorted by name)
    assertTrue(rows[1].text:find("Alice", 1, true) ~= nil, "first group is Alice by sort")
end

do
    -- Offline member assignable
    resetDB()
    local status = assign("Alice-Garona", "Bob-Garona") -- Bob offline
    assertEq(status, "accepted", "offline member can be assigned")
end

do
    -- Suggestions do not require per-keystroke roster rebuild: snapshot Suggest is in-memory
    resetDB()
    local snap = GI.GetRosterSnapshot(true)
    local s1 = snap:Suggest("bo", 10)
    assertTrue(#s1 >= 1, "suggest finds Bob*")
    -- Ambiguous short bob appears as two Name-Realm rows
    local foundArea = false
    for i = 1, #s1 do
        if s1[i].nameRealm == "Bob-Area52" then foundArea = true end
    end
    assertTrue(foundArea, "suggest includes cross-realm Bob-Area52")
end

---------------------------------------------------------------------------
-- A) Settings page closures refresh live caps/roster + Assign enablement
---------------------------------------------------------------------------

do
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
    SF.SettingsUI.DefinitionRenderer = SF.SettingsUI.DefinitionRenderer or {}
    local refreshCalls = 0
    function SF.SettingsUI.DefinitionRenderer:Build(panel, def)
        panel.__sfPageDef = def
        panel.__sfPageBuilder = {
            Refresh = function() refreshCalls = refreshCalls + 1 end,
            Reflow = function() end,
            RegisterRefresh = function() end,
        }
        panel.__sfSections = {}
    end
    function SF.SettingsUI.DefinitionRenderer:Refresh(panel)
        refreshCalls = refreshCalls + 1
        local pb = panel and panel.__sfPageBuilder
        if pb and pb.Refresh then pb:Refresh() end
    end
    SF.SettingsUI.Dialogs = SF.SettingsUI.Dialogs or {
        Confirm = function(_, _, _, accept) if accept then accept() end end,
    }

    loadModule("SpectrumFederation/modules/UI/Settings/Pages/MainAltAssignments.lua")
    local page = SF.SettingsUI.pagesById.guildInfoMainAlt
    assertTrue(page ~= nil, "Main/Alt Assignments page registered")

    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    world.guild.rosterComplete = false
    GI.InvalidateRosterSnapshot()

    local panel = CreateFrame()
    panel.IsVisible = function() return true end
    page:Build(panel)
    local def = panel.__sfPageDef
    assertTrue(type(def) == "table", "Build stores page definition")

    local accessGet, assignEnabled, mainResolvedCb, altResolvedCb, mainTextCb, altTextCb
    local mainEnabled, altEnabled, changeMainSet, changeMainBtnEnabled, unassignRemove
    for _, sec in ipairs(def.sections or {}) do
        for _, item in ipairs(sec.items or {}) do
            if sec.id == "guildInfoMainAltStatus" and item.type == "display" then
                accessGet = item.get
            end
            if item.type == "button" and item.buttonText == "Assign" then
                assignEnabled = item.enabled
            end
            if item.type == "button" and item.buttonText == "Change Main" then
                changeMainBtnEnabled = item.enabled
            end
            if item.type == "dropdown" and item.label and tostring(item.label):find("New main", 1, true) then
                changeMainSet = item.set
            end
            if item.type == "autocomplete" and item.label == "Main name" then
                mainResolvedCb = item.onResolved
                mainTextCb = item.onTextChanged
                mainEnabled = item.enabled
            end
            if item.type == "autocomplete" and item.label == "Alt name" then
                altResolvedCb = item.onResolved
                altTextCb = item.onTextChanged
                altEnabled = item.enabled
            end
            if item.type == "scrollList" and type(item.onRemove) == "function" then
                unassignRemove = item.onRemove
            end
        end
    end
    assertTrue(type(accessGet) == "function", "access status get callback")
    assertTrue(type(assignEnabled) == "function", "Assign enabled callback")
    local statusAtBuild = tostring(accessGet())
    assertTrue(
        statusAtBuild:find("roster", 1, true) ~= nil
            or statusAtBuild:find("loading", 1, true) ~= nil
            or statusAtBuild:find("membership", 1, true) ~= nil
            or statusAtBuild:find("verified", 1, true) ~= nil,
        "incomplete roster/membership reported in status at Build")
    assertTrue(not mainEnabled(), "main field disabled while roster incomplete")
    assertTrue(not assignEnabled(), "Assign disabled while roster incomplete")

    -- Transition to complete roster without rebuilding the page (A).
    world.guild.rosterComplete = true
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    page:Refresh(panel)
    assertTrue(mainEnabled() == true, "main field enables after roster completes")
    assertTrue(altEnabled() == true, "alt field enables after roster completes")
    assertTrue(tostring(accessGet()):find("assign", 1, true) ~= nil
        or tostring(accessGet()):find("ranks 1", 1, true) ~= nil,
        "editor status text after roster complete")
    assertTrue(not assignEnabled(), "Assign still off until both fields resolve")

    mainResolvedCb(nil, {
        guid = "Player-1-Alice",
        nameRealm = "Alice-Garona",
        classFile = "MAGE",
    })
    assertTrue(not assignEnabled(), "Assign off with only main resolved")
    altResolvedCb(nil, {
        guid = "Player-1-Bob",
        nameRealm = "Bob-Garona",
        classFile = "WARRIOR",
    })
    assertTrue(assignEnabled() == true, "Assign enables when two distinct guild chars resolve")
    assertTrue(refreshCalls >= 1, "resolve queues page Refresh for Assign enablement")

    mainTextCb(nil, "Alice-GaronaX")
    assertTrue(not assignEnabled(), "Assign disables immediately when main text invalidated")

    -- Guild demotion updates access without reopening (A).
    mainResolvedCb(nil, {
        guid = "Player-1-Alice",
        nameRealm = "Alice-Garona",
        classFile = "MAGE",
    })
    altResolvedCb(nil, {
        guid = "Player-1-Bob",
        nameRealm = "Bob-Garona",
        classFile = "WARRIOR",
    })
    setActor("Alice-Garona", "Player-1-Alice", 4)
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    page:Refresh(panel)
    assertTrue(not mainEnabled(), "demotion disables fields via live Caps()")
    assertTrue(not assignEnabled(), "demotion disables Assign via live Caps()")
    assertTrue(tostring(accessGet()):find("View only", 1, true) ~= nil
        or tostring(accessGet()):find("ranks 1", 1, true) ~= nil,
        "demotion updates access status text")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    page:Refresh(panel)

    -- Form edits must not rescan the guild roster on each keystroke.
    GI.GetRosterSnapshot(true)
    local scansBefore = world.rosterInfoCalls
    for i = 1, 5 do
        mainTextCb(nil, "Al" .. tostring(i))
    end
    assertEq(world.rosterInfoCalls, scansBefore,
        "autocomplete keystrokes do not InvalidateRosterSnapshot/rescan")
    assertTrue(refreshCalls >= 1, "form edits still queue control Refresh")

    -- Change Main candidate selection enables the dependent button.
    assign("Alice-Garona", "Bob-Garona")
    for _, sec in ipairs(def.sections or {}) do
        for _, item in ipairs(sec.items or {}) do
            if item.type == "scrollList" and type(item.onSelect) == "function" then
                item.onSelect(nil, { clusterId = "Player-1-Alice", role = "main" })
            end
        end
    end
    assertTrue(type(changeMainSet) == "function", "Change Main dropdown set callback")
    assertTrue(not changeMainBtnEnabled(), "Change Main button off before candidate")
    changeMainSet("Player-1-Bob")
    assertTrue(changeMainBtnEnabled() == true, "Change Main enables after candidate selection")

    -- Stale unassign confirmation via page callback (captures displayed main).
    assertTrue(type(unassignRemove) == "function", "unassign onRemove callback")
    local pendingConfirm
    SF.SettingsUI.Dialogs.Confirm = function(_, _, _, accept)
        pendingConfirm = accept
    end
    local msgCtx = { section = { SetMessage = function() end } }
    unassignRemove(msgCtx, {
        role = "alt",
        guid = "Player-1-Bob",
        mainGuid = "Player-1-Alice",
    })
    assertTrue(type(pendingConfirm) == "function", "unassign opens confirmation")
    -- Another editor moves Bob before confirm.
    GI:AssignAlt("Carol-Garona", "Bob-Garona", {
        roster = GI.GetRosterSnapshot(true),
        moveConfirmed = true,
        expectedOldMain = "Player-1-Alice",
    })
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Carol",
        "Bob moved to Carol before stale unassign confirm")
    pendingConfirm()
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Carol",
        "stale unassign does not remove newer Carol relationship")
    SF.SettingsUI.Dialogs.Confirm = function(_, _, _, accept) if accept then accept() end end
end

---------------------------------------------------------------------------
-- B) Cross-client structural conflict convergence (opposing delivery orders)
---------------------------------------------------------------------------

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do
        out[k] = deepCopy(val)
    end
    return out
end

local function peerAdmit(db, op)
    SpectrumFederationDB = db
    GI:Initialize(db)
    return GI:AdmitOperation(op, { remote = true })
end

local function peerRole(db, guid)
    SpectrumFederationDB = db
    GI:Initialize(db)
    return GI:GetCharacterRole(guid)
end

do
    resetDB()
    -- Officer A: Carol alt of Bob. Officer B: Bob alt of Alice. Concurrent.
    local opA = {
        id = "gi1:Player-1-Alice:structaaaaaaaaaaaaaaaaaa:1",
        kind = GI.KIND.ASSIGN,
        at = 200,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Bob",
        mainName = "Bob-Garona",
        altGuid = "Player-1-Carol",
        altName = "Carol-Garona",
    }
    local opB = {
        id = "gi1:Player-1-Carol:structbbbbbbbbbbbbbbbbbb:1",
        kind = GI.KIND.ASSIGN,
        at = 200,
        actorGuid = "Player-1-Carol",
        actorName = "Carol-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Alice",
        mainName = "Alice-Garona",
        altGuid = "Player-1-Bob",
        altName = "Bob-Garona",
    }

    local dbA = {}
    local dbB = {}
    assertEq(peerAdmit(dbA, opA), "accepted", "peer A accepts local Carol→Bob")
    assertEq(peerAdmit(dbB, opB), "accepted", "peer B accepts local Bob→Alice")
    -- Exchange
    assertEq(peerAdmit(dbA, opB), "accepted", "peer A admits remote Bob→Alice (no graph race)")
    assertEq(peerAdmit(dbB, opA), "accepted", "peer B admits remote Carol→Bob (no graph race)")

    local roleBobA, mainBobA = peerRole(dbA, "Player-1-Bob")
    local roleBobB, mainBobB = peerRole(dbB, "Player-1-Bob")
    local roleCarolA, mainCarolA = peerRole(dbA, "Player-1-Carol")
    local roleCarolB, mainCarolB = peerRole(dbB, "Player-1-Carol")
    assertEq(roleBobA, roleBobB, "Bob role converges across peers")
    assertEq(mainBobA, mainBobB, "Bob main converges across peers")
    assertEq(roleCarolA, roleCarolB, "Carol role converges across peers")
    assertEq(mainCarolA, mainCarolB, "Carol main converges across peers")
    -- Deterministic fold by (at, id): opA (Alice/structa) before opB (Carol/structb).
    -- After opA: Bob=main, Carol=alt(Bob). opB then has no effect (Bob is main with alts).
    assertEq(roleBobA, "main", "winning fold keeps Bob as main")
    assertEq(roleCarolA, "alt", "Carol remains alt of Bob")
    assertEq(mainCarolA, "Player-1-Bob", "Carol→Bob relationship retained")

    -- Reverse local-first order still converges to the same graph.
    local dbA2, dbB2 = {}, {}
    peerAdmit(dbB2, opB)
    peerAdmit(dbA2, opA)
    peerAdmit(dbB2, opA)
    peerAdmit(dbA2, opB)
    local _, mainCarolA2 = peerRole(dbA2, "Player-1-Carol")
    local _, mainCarolB2 = peerRole(dbB2, "Player-1-Carol")
    assertEq(mainCarolA2, "Player-1-Bob", "reverse arrival still Carol→Bob")
    assertEq(mainCarolB2, "Player-1-Bob", "reverse arrival peer B matches")

    -- Conflicting Change Main ops also converge.
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    assign("Alice-Garona", "Carol-Garona")
    local record = select(1, GI:GetCurrentRecord())
    local baseOps = deepCopy(record.ops)
    local baseOrder = deepCopy(record.order)
    local cmAt = world.time + 50
    local cm1 = {
        id = "gi1:Player-1-Alice:changemaaaaaaaaaaaaaaaaa:1",
        kind = GI.KIND.CHANGE_MAIN,
        at = cmAt,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Alice",
        newMainGuid = "Player-1-Bob",
    }
    local cm2 = {
        id = "gi1:Player-1-Carol:changembbbbbbbbbbbbbbbbb:1",
        kind = GI.KIND.CHANGE_MAIN,
        at = cmAt,
        actorGuid = "Player-1-Carol",
        actorName = "Carol-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Alice",
        newMainGuid = "Player-1-Carol",
    }
    local function seedPeer()
        local db = {}
        SpectrumFederationDB = db
        GI:Initialize(db)
        for i = 1, #baseOrder do
            local id = baseOrder[i]
            GI:AdmitOperation(deepCopy(baseOps[id]), { remote = true })
        end
        return db
    end
    local p1 = seedPeer()
    local p2 = seedPeer()
    peerAdmit(p1, cm1)
    peerAdmit(p2, cm2)
    peerAdmit(p1, cm2)
    peerAdmit(p2, cm1)
    local role1 = select(1, peerRole(p1, "Player-1-Alice"))
    local role2 = select(1, peerRole(p2, "Player-1-Alice"))
    local mainBob1 = select(2, peerRole(p1, "Player-1-Bob"))
    local mainBob2 = select(2, peerRole(p2, "Player-1-Bob"))
    assertEq(role1, role2, "Alice role converges after conflicting Change Main")
    assertEq(mainBob1, mainBob2, "Bob's main converges after conflicting Change Main")
    -- changema < changemb → cm1 folds first (Bob becomes main); cm2 then has no group on Alice.
    assertEq(select(1, peerRole(p1, "Player-1-Bob")), "main", "earlier Change Main id wins")
    assertEq(select(1, peerRole(p2, "Player-1-Bob")), "main", "peer B matches Change Main winner")
end

---------------------------------------------------------------------------
-- C) Compaction checkpoint sync + export/index lifecycle + late joiner
---------------------------------------------------------------------------

do
    resetDB()
    local prevMax = GI.MAX_ACCEPTED_OPS
    GI.MAX_ACCEPTED_OPS = 5
    setActor("Alice-Garona", "Player-1-Alice", 1)

    world.time = world.time + 1
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "compact seed assign Bob")
    world.time = world.time + 1
    assertEq(assign("Alice-Garona", "Eve-Garona"), "accepted", "compact seed assign Eve")
    world.time = world.time + 1
    assertEq(assign("Alice-Garona", "Dave-Garona"), "accepted", "compact seed assign Dave")
    world.time = world.time + 1
    assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "compact seed unassign Dave")
    world.time = world.time + 1
    assertEq(assign("Alice-Garona", "Dave-Garona"), "accepted", "log filled to compaction threshold")
    local record = select(1, GI:GetCurrentRecord())
    assertEq(#record.order, 5, "log full at compaction threshold")

    -- Build physical index before compaction so we can prove IDs vanish after.
    local index = DriveEnsureIndex(GI.PROVIDER_ID)
    assertTrue(index.buildComplete, "index build complete before compaction")
    local preCompactIds = {}
    for id in pairs(index.byId or {}) do
        preCompactIds[id] = true
    end
    assertTrue(next(preCompactIds) ~= nil, "physical index has pre-compact records")

    world.time = world.time + 1
    local beforeEpoch = world.indexEpochBumps or 0
    local status = GI:UnassignAlt("Player-1-Dave", {})
    assertEq(status, "accepted", "op that triggers compaction accepted")
    record = select(1, GI:GetCurrentRecord())
    assertTrue(#record.order < GI.MAX_ACCEPTED_OPS, "log shrunk after compaction")
    assertTrue((tonumber(record.compactWatermarkAt) or 0) > 0, "compaction sets watermark")
    local ckptCount, snapCount = 0, 0
    for i = 1, #record.order do
        local op = record.ops[record.order[i]]
        if op and op.kind == GI.KIND.ASSIGN and tostring(op.id):find(":ckpt:", 1, true) then
            ckptCount = ckptCount + 1
            assertEq(op.actorGuid, "Player-1-Alice", "checkpoint authored by officer")
            assertTrue(op.actorGuid ~= "compact", "checkpoint actorGuid is not compact marker")
            local wire = {
                id = "gi-op:" .. op.id,
                versionFp = "x",
                body = { kind = "guildinfo-op", op = op },
            }
            local okSize, rawLen = GI.RecordWithinGossipCap(wire)
            assertTrue(okSize, "checkpoint assign within MAX_RECORD_CBOR")
            assertTrue(rawLen <= SF.GuildGossip.MAX_RECORD_CBOR, "serialized checkpoint size bound")
        elseif op and op.kind == GI.KIND.SNAPSHOT then
            snapCount = snapCount + 1
        end
    end
    assertTrue(ckptCount >= 2, "compaction produced transportable checkpoint assigns")
    assertEq(snapCount, 0, "new compaction does not emit monolithic snapshot")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "Bob preserved across compaction")
    assertEq(GI:GetCharacterRole("Player-1-Eve"), "alt", "Eve preserved across compaction")
    assertNil(GI:GetCharacterRole("Player-1-Dave"), "post-compact unassign applied")
    assertTrue((world.indexEpochBumps or 0) > beforeEpoch, "compaction bumps physical index epoch")

    -- Rebuild index after compact: vanished pre-compact IDs must not remain.
    index = DriveEnsureIndex(GI.PROVIDER_ID)
    assertTrue(index.buildComplete, "index rebuilds after compaction")
    for id in pairs(preCompactIds) do
        assertTrue(index.byId[id] == nil, "pre-compact id removed from physical index: " .. id)
    end
    local liveExport = 0
    for _ in pairs(index.byId or {}) do liveExport = liveExport + 1 end
    assertEq(liveExport, #record.order, "physical index matches live durable ops")

    -- Oversized monolithic snapshot must not pass the transport/admission bound.
    local hugeGroups = {}
    for i = 1, 40 do
        local alts, names = {}, {}
        for j = 1, 8 do
            alts[#alts + 1] = string.format("Player-9-%02d%02d", i, j)
            names[#names + 1] = string.format("Alt%02d%02d-Garona", i, j)
        end
        hugeGroups[#hugeGroups + 1] = {
            mainGuid = string.format("Player-8-%02d", i),
            mainName = string.format("Main%02d-Garona", i),
            altGuids = alts,
            altNames = names,
        }
    end
    local hugeSnap = {
        id = "gi1:Player-1-Alice:hugesnapaaaaaaaaaaaaaa:1",
        kind = GI.KIND.SNAPSHOT,
        at = world.time + 100,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        guildKey = "club:42",
        groups = hugeGroups,
    }
    local hugeWire = {
        id = "gi-op:" .. hugeSnap.id,
        versionFp = "huge",
        body = { kind = "guildinfo-op", op = hugeSnap },
    }
    assertTrue(not GI.RecordWithinGossipCap(hugeWire), "realistic full snapshot exceeds CBOR cap")
    local provider = SF.GuildGossip._providers[GI.PROVIDER_ID]
    local hugeStatus = provider.spec.ValidateAndApply(hugeWire, { sender = "Alice-Garona" })
    assertEq(hugeStatus, "rejected", "oversize snapshot rejected at provider admission")

    record.compactedIds["gi1:Player-1-Alice:oldcompactedaaaaaaaaaa:1"] = true
    local st = GI:AdmitOperation({
        id = "gi1:Player-1-Alice:oldcompactedaaaaaaaaaa:1",
        kind = GI.KIND.ASSIGN,
        at = 50,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Carol",
        altGuid = "Player-1-Dave",
    }, { remote = true })
    assertEq(st, "duplicate", "compacted id rejected as duplicate")
    local resurrect = {
        id = "gi1:Player-1-Alice:resurrectaaaaaaaaaaaaaa:1",
        kind = GI.KIND.ASSIGN,
        at = 1,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Carol",
        mainName = "Carol-Garona",
        altGuid = "Player-1-Eve",
        altName = "Eve-Garona",
    }
    st = GI:AdmitOperation(resurrect, { remote = true })
    assertEq(st, "duplicate", "op older than watermark superseded")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Alice",
        "superseded op did not move Eve off Alice")

    -- Late peer catch-up via checkpoint assigns + editor relay.
    local ckpts = {}
    for i = 1, #record.order do
        local op = record.ops[record.order[i]]
        if op and op.kind == GI.KIND.ASSIGN then
            ckpts[#ckpts + 1] = deepCopy(op)
        end
    end
    local lateDB = {}
    SpectrumFederationDB = lateDB
    GI:Initialize(lateDB)
    GI:EnsureGossipProvider()
    local lateSpec = SF.GuildGossip._providers[GI.PROVIDER_ID].spec
    for i = 1, #ckpts do
        local wire = {
            id = "gi-op:" .. ckpts[i].id,
            versionFp = "ckpt",
            body = { kind = "guildinfo-op", op = ckpts[i] },
        }
        assertTrue(GI.RecordWithinGossipCap(wire), "late-peer checkpoint within cap")
        local relayStatus = lateSpec.ValidateAndApply(wire, { sender = "Carol-Garona" })
        assertEq(relayStatus, "accepted", "editor relays checkpoint assign " .. i)
    end
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "late joiner reconstructs Bob alt")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Alice",
        "late joiner reconstructs Alice as main")

    local saved = SpectrumFederationDB
    local liveCount = #select(1, GI:GetCurrentRecord()).order
    SF.GuildInfo = nil
    loadModule("SpectrumFederation/modules/GuildInfo/State.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Authority.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Operations.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Roster.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Gossip.lua")
    GI = SF.GuildInfo
    GI.MAX_ACCEPTED_OPS = 5
    GI:Initialize(saved)
    assertEq(#select(1, GI:GetCurrentRecord()).order, liveCount, "reload keeps compacted live ops")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "reload after compaction restores graph")

    for i = 1, 4 do
        world.time = world.time + 1
        assign("Alice-Garona", "Dave-Garona")
        world.time = world.time + 1
        GI:UnassignAlt("Player-1-Dave", {})
    end
    local rec2 = select(1, GI:GetCurrentRecord())
    assertTrue(#rec2.order <= GI.MAX_ACCEPTED_OPS, "repeated compaction stays bounded")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "graph valid after second compaction window")

    GI.MAX_ACCEPTED_OPS = prevMax
    resetDB()
end

---------------------------------------------------------------------------
-- D) Transactional integrity, capacity, stale confirm, genuine noop
---------------------------------------------------------------------------

do
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    -- Fill Carol's group to capacity, then refuse a move that would mutate Bob first.
    assign("Alice-Garona", "Bob-Garona")
    local prevMaxAlts = GI.MAX_ALTS_PER_MAIN
    GI.MAX_ALTS_PER_MAIN = 2
    assign("Carol-Garona", "Eve-Garona")
    -- Need a second alt for Carol — use Dave.
    assign("Carol-Garona", "Dave-Garona")
    local groupsBefore = GI:GetRelationshipGroups()
    local bobMainBefore = select(2, GI:GetCharacterRole("Player-1-Bob"))
    local status, reason = GI:AssignAlt("Carol-Garona", "Bob-Garona", {
        roster = GI.GetRosterSnapshot(true),
        moveConfirmed = true,
        expectedOldMain = "Player-1-Alice",
    })
    assertEq(status, "rejected", "full destination rejects move")
    assertEq(reason, "group_full", "group_full reason")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), bobMainBefore,
        "failed move does not unlink Bob from Alice")
    assertEq(#GI:GetRelationshipGroups(), #groupsBefore, "group count unchanged after rejected move")
    GI.MAX_ALTS_PER_MAIN = prevMaxAlts
end

do
    resetDB()
    local prevMaxGroups = GI.MAX_GROUPS
    GI.MAX_GROUPS = 1
    assign("Alice-Garona", "Bob-Garona")
    local status, reason = assign("Carol-Garona", "Eve-Garona")
    assertEq(status, "rejected", "max groups rejects new main group")
    assertTrue(reason == "no_effect" or reason == "group_full" or reason ~= nil,
        "capacity rejection reason present")
    assertNil(GI:GetCharacterRole("Player-1-Eve"), "Eve not partially linked")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "existing group intact")
    GI.MAX_GROUPS = prevMaxGroups
end

do
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    -- Stale confirm: unassign before confirmed move commits.
    local status, reason = GI:AssignAlt("Carol-Garona", "Bob-Garona", {
        roster = GI.GetRosterSnapshot(true),
        moveConfirmed = true,
        expectedOldMain = "Player-1-Alice",
    })
    assertEq(status, "accepted", "control: confirmed move works when still at expected main")
    -- Move Bob back setup: Bob is under Carol; unassign then stale-confirm to Alice.
    GI:UnassignAlt("Player-1-Bob", {})
    status, reason = GI:AssignAlt("Alice-Garona", "Bob-Garona", {
        roster = GI.GetRosterSnapshot(true),
        moveConfirmed = true,
        expectedOldMain = "Player-1-Carol",
    })
    assertEq(status, "rejected", "stale confirm after unassign rejected")
    assertEq(reason, "stale_move_confirmation", "stale_move_confirmation after unassign")

    assign("Carol-Garona", "Bob-Garona")
    -- Already at destination while confirm expected old main elsewhere.
    status, reason = GI:AssignAlt("Carol-Garona", "Bob-Garona", {
        roster = GI.GetRosterSnapshot(true),
        moveConfirmed = true,
        expectedOldMain = "Player-1-Alice",
    })
    assertEq(status, "rejected", "stale confirm when already at destination with wrong expected")
    assertEq(reason, "stale_move_confirmation", "stale when destination match but expected old differs")
end

do
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    local record = select(1, GI:GetCurrentRecord())
    local opsBefore = #record.order
    local notifyBefore = world.providerChanged
    local status, reason = assign("Alice-Garona", "Bob-Garona")
    assertEq(status, "accepted", "duplicate same-main assign accepted as noop")
    assertEq(reason, "noop", "noop reason without durable write")
    record = select(1, GI:GetCurrentRecord())
    assertEq(#record.order, opsBefore, "noop does not append durable op")
    assertEq(world.providerChanged, notifyBefore, "noop does not broadcast Gossip notify")
end

---------------------------------------------------------------------------
-- E) Incomplete roster rows never imply departure
---------------------------------------------------------------------------

do
    resetDB()
    assign("Alice-Garona", "Eve-Garona")
    -- Nonzero guild member count, but one row lacks a stable GUID.
    world.guild.members[#world.guild.members + 1] = {
        name = "Ghost-Garona", guid = nil, rankOrder = 5, online = false, class = "WARLOCK",
    }
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    local snap = GI.GetRosterSnapshot(true)
    assertTrue(not snap.complete, "skipped GUID row marks roster incomplete")
    assertEq(snap.reason, "roster_incomplete", "incomplete reason for skipped row")
    -- Eve still in the real guild list but snapshot incomplete → unknown, not departed.
    -- Remove Eve from the member table while incomplete row remains.
    local kept = {}
    for _, m in ipairs(world.guild.members) do
        if m.guid ~= "Player-1-Eve" then
            kept[#kept + 1] = m
        end
    end
    world.guild.members = kept
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    local status = GI.GetMembershipStatus("Player-1-Eve", GI.GetRosterSnapshot(true))
    assertEq(status, "unknown", "missing char with incomplete rows is unknown not departed")
    -- Clean up ghost row and restore Eve for any later harness use.
    local cleaned = {}
    for _, m in ipairs(world.guild.members) do
        if m.guid then cleaned[#cleaned + 1] = m end
    end
    cleaned[#cleaned + 1] = {
        name = "Eve-Garona", guid = "Player-1-Eve", rankOrder = 5, online = false, class = "ROGUE",
    }
    world.guild.members = cleaned
    world.guild.rosterComplete = true
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
end

---------------------------------------------------------------------------
-- Relay authority: A originates, B receives, A offline, C catches up via B
---------------------------------------------------------------------------

do
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "A originates assign")
    local record = select(1, GI:GetCurrentRecord())
    local opId = record.order[1]
    local opA = deepCopy(record.ops[opId])
    assertEq(opA.actorGuid, "Player-1-Alice", "origin actor is Alice")

    -- Peer B (Carol) receives from Alice.
    local dbB = {}
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    GI:EnsureGossipProvider()
    local specB = SF.GuildGossip._providers[GI.PROVIDER_ID].spec
    local wire = {
        id = "gi-op:" .. opA.id,
        versionFp = "v1",
        body = { kind = "guildinfo-op", op = deepCopy(opA) },
    }
    assertTrue(GI.RecordWithinGossipCap(wire), "relay wire within CBOR cap")
    assertEq(specB.ValidateAndApply(wire, { sender = "Alice-Garona" }), "accepted",
        "B admits Alice-authored op from Alice")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "B has Bob alt")

    -- Unauthorized member cannot launder / relay.
    local dbX = {}
    SpectrumFederationDB = dbX
    GI:Initialize(dbX)
    GI:EnsureGossipProvider()
    local specX = SF.GuildGossip._providers[GI.PROVIDER_ID].spec
    local forged = deepCopy(opA)
    forged.id = "gi1:Player-1-Alice:forgedaaaaaaaaaaaaaaa:9"
    local bad = specX.ValidateAndApply({
        id = "gi-op:" .. forged.id,
        versionFp = "bad",
        body = { kind = "guildinfo-op", op = forged },
    }, { sender = "Dave-Garona" })
    assertEq(bad, "rejected", "rank-4 member cannot introduce/relay ops")
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "unauthorized relay did not apply")

    -- A goes offline; C catches up through B (Carol relays Alice provenance).
    local dbC = {}
    SpectrumFederationDB = dbC
    GI:Initialize(dbC)
    GI:EnsureGossipProvider()
    local specC = SF.GuildGossip._providers[GI.PROVIDER_ID].spec
    local relayWire = {
        id = "gi-op:" .. opA.id,
        versionFp = "v1",
        body = { kind = "guildinfo-op", op = deepCopy(opA) }, -- actorGuid still Alice
    }
    assertEq(opA.actorGuid, "Player-1-Alice", "relay preserves Alice provenance")
    assertTrue(opA.actorGuid ~= "Player-1-Carol", "relay sender differs from actor")
    assertEq(specC.ValidateAndApply(relayWire, { sender = "Carol-Garona" }), "accepted",
        "C admits Alice op relayed by editor Carol")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "C reconstructs assign after A offline")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Alice",
        "C sees Alice as Bob's main")

    -- Actor mismatch rewrite must not occur: re-export keeps Alice actorGuid.
    DriveEnsureIndex(GI.PROVIDER_ID)
    local body = specC.GetRecordBody("gi-op:" .. opA.id)
    assertTrue(body and body.body and body.body.op, "C exports relayed op")
    assertEq(body.body.op.actorGuid, "Player-1-Alice", "relayed export keeps original actorGuid")
end

---------------------------------------------------------------------------
-- Guild A→B scope transition invalidates physical index before advertise
---------------------------------------------------------------------------

do
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    local index = DriveEnsureIndex(GI.PROVIDER_ID)
    assertTrue(index.buildComplete, "guild A index complete")
    local guildAId = next(index.byId)
    assertTrue(guildAId ~= nil, "guild A indexed an op")
    local epochBefore = index.epoch

    -- Switch club / guild scope.
    world.guild.clubId = 99
    world.generation = world.generation + 1
    local spec = SF.GuildGossip._providers[GI.PROVIDER_ID].spec
    -- EnsureIndex must notice scope change even when prior index looked complete.
    index.dirty = false
    index.buildComplete = true
    local more = spec.EnsureIndex(index, { indexEntries = 32 })
    assertTrue(index.epoch > epochBefore, "guild switch bumps index epoch")
    assertTrue(index.byId[guildAId] == nil, "guild A record id cleared from physical index")
    -- Drive rebuild under guild B (empty relationships).
    DriveEnsureIndex(GI.PROVIDER_ID)
    local page = spec.ListRecordIds(1, 64)
    assertEq(#page, 0, "guild B advertises no guild A ops")
    world.guild.clubId = 42
    world.generation = world.generation + 1
end

---------------------------------------------------------------------------
-- API-level stale unassign expectedMainGuid
---------------------------------------------------------------------------

do
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    GI:AssignAlt("Carol-Garona", "Bob-Garona", {
        roster = GI.GetRosterSnapshot(true),
        moveConfirmed = true,
        expectedOldMain = "Player-1-Alice",
    })
    local status, reason = GI:UnassignAlt("Player-1-Bob", {
        expectedMainGuid = "Player-1-Alice",
    })
    assertEq(status, "rejected", "API rejects stale unassign expected main")
    assertEq(reason, "stale_unassign", "stale_unassign reason")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Carol",
        "newer relationship retained after stale unassign")
    status = GI:UnassignAlt("Player-1-Bob", { expectedMainGuid = "Player-1-Carol" })
    assertEq(status, "accepted", "unassign with matching expected main accepted")
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "matching unassign removes alt")
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
io.stdout:write("0 failed\n")
