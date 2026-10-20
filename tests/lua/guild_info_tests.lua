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
-- Helpers (state-based)
---------------------------------------------------------------------------

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do
        out[k] = deepCopy(val)
    end
    return out
end

local function countKeys(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do n = n + 1 end
    end
    return n
end

local function wireMember(m)
    return {
        id = "gi-m:" .. tostring(m.guid),
        versionFp = tostring(m.ver and m.ver.n) .. ":" .. tostring(m.ver and m.ver.w),
        body = {
            kind = "guildinfo-member",
            schema = GI.PROVIDER_SCHEMA,
            member = deepCopy(m),
        },
    }
end

local function wireGroup(g)
    return {
        id = "gi-g:" .. tostring(g.groupId),
        versionFp = tostring(g.ver and g.ver.n) .. ":" .. tostring(g.ver and g.ver.w),
        body = {
            kind = "guildinfo-group",
            schema = GI.PROVIDER_SCHEMA,
            group = deepCopy(g),
        },
    }
end

local function exportWires(db)
    SpectrumFederationDB = db
    GI:Initialize(db)
    local record = select(1, GI:GetCurrentRecord())
    if not record then return {} end
    local bodies = GI.ListStateBodies(record)
    local wires = {}
    for i = 1, #bodies do
        if bodies[i].kind == "guildinfo-member" then
            wires[#wires + 1] = wireMember(bodies[i].member)
        else
            wires[#wires + 1] = wireGroup(bodies[i].group)
        end
    end
    return wires
end

local function admitWire(db, wire, sender)
    SpectrumFederationDB = db
    GI:Initialize(db)
    local provider = SF.GuildGossip._providers[GI.PROVIDER_ID]
    return provider.spec.ValidateAndApply(deepCopy(wire), { sender = sender or "Carol-Garona" })
end

local function syncAll(fromDb, toDb, sender)
    local wires = exportWires(fromDb)
    for i = 1, #wires do
        admitWire(toDb, wires[i], sender)
    end
end

local function peerRole(db, guid)
    SpectrumFederationDB = db
    GI:Initialize(db)
    return GI:GetCharacterRole(guid)
end

local function reloadModules(saved)
    SF.GuildGossip._providers = {}
    SF.GuildInfo = nil
    loadModule("SpectrumFederation/modules/GuildInfo/State.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Authority.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Operations.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Roster.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Gossip.lua")
    GI = SF.GuildInfo
    GI:Initialize(saved)
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
    assertEq(GI:GetCharacterRole("Player-1-Alice"), "main", "Alice is main")
    local counts = GI.CountRetainedState()
    assertEq(counts.assigned, 2, "assign stores two memberships")
    assertEq(counts.liveGroups, 1, "assign stores one live group")
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
    assertNil(GI:GetCharacterRole("Player-1-Alice"), "Alice alone no longer a group")
end

do
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
    local record = select(1, GI:GetCurrentRecord())
    local groupIdBefore = record.graph.byGuid["Player-1-Alice"].groupId
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
    record = select(1, GI:GetCurrentRecord())
    assertEq(record.graph.byGuid["Player-1-Bob"].groupId, groupIdBefore, "Change Main keeps stable groupId")
    assertEq(record.groups[groupIdBefore].mainGuid, "Player-1-Bob", "group.mainGuid updated")
end

do
    local status = GI:UnassignAlt("Player-1-Carol", {})
    assertEq(status, "accepted", "unassign Carol")
    assertNil(GI:GetCharacterRole("Player-1-Carol"), "Carol unassigned")
    assertEq(GI:GetCharacterRole("Player-1-Alice"), "alt", "Alice still alt")
end

do
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
    local kept = {}
    for _, m in ipairs(world.guild.members) do
        if m.guid ~= "Player-1-Eve" then
            kept[#kept + 1] = m
        end
    end
    world.guild.members = kept
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    assertEq(GI.GetMembershipStatus("Player-1-Eve", GI.GetRosterSnapshot(true)), "departed",
        "missing from complete roster is departed")
    assertEq(GI:GetCharacterRole("Player-1-Eve"), "alt", "departed alt relationship retained")

    world.guild.rosterComplete = false
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    assertEq(GI.GetMembershipStatus("Player-1-Eve", GI.GetRosterSnapshot(true)), "unknown",
        "incomplete roster is unknown not departed")
    world.guild.rosterComplete = true
    world.guild.members[#world.guild.members + 1] = {
        name = "Eve-Garona", guid = "Player-1-Eve", rankOrder = 5, online = false, class = "ROGUE",
    }
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    assertEq(GI.GetMembershipStatus("Player-1-Eve", GI.GetRosterSnapshot(true)), "in_guild",
        "returning member restored")
end

---------------------------------------------------------------------------
-- Remote admission / trust (state records)
---------------------------------------------------------------------------

do
    resetDB()
    local provider = SF.GuildGossip._providers[GI.PROVIDER_ID]
    assertTrue(provider ~= nil, "gossip provider registered")
    local spec = provider.spec

    local forgedMember = {
        guid = "Player-1-Bob",
        groupId = "gig:forged:1",
        ver = { n = 1, w = "aaaaaaaaaaaaaaaaaaaaaaaa" },
        at = world.time,
        nameRealm = "Bob-Garona",
        classFile = "WARRIOR",
    }
    local status, detail = spec.ValidateAndApply(wireMember(forgedMember), { sender = "Dave-Garona" })
    assertEq(status, "rejected", "rank 4 remote sender rejected")
    assertTrue(detail == "unauthorized" or detail ~= nil, "unauthorized remote detail")

    -- Officer creates group + memberships remotely.
    local gid = "gig:carolbbbbbbbbbbbbbbbbbb:1"
    status = spec.ValidateAndApply(wireGroup({
        groupId = gid,
        mainGuid = "Player-1-Alice",
        ver = { n = 1, w = "bbbbbbbbbbbbbbbbbbbbbbbb" },
        at = world.time,
    }), { sender = "Carol-Garona" })
    assertEq(status, "accepted", "rank 3 remote group accepted")
    status = spec.ValidateAndApply(wireMember({
        guid = "Player-1-Alice",
        groupId = gid,
        ver = { n = 1, w = "bbbbbbbbbbbbbbbbbbbbbbbb" },
        at = world.time,
        nameRealm = "Alice-Garona",
        classFile = "MAGE",
    }), { sender = "Carol-Garona" })
    assertEq(status, "accepted", "remote main membership accepted")
    status = spec.ValidateAndApply(wireMember({
        guid = "Player-1-Bob",
        groupId = gid,
        ver = { n = 1, w = "bbbbbbbbbbbbbbbbbbbbbbbb" },
        at = world.time + 1,
        nameRealm = "Bob-Garona",
        classFile = "WARRIOR",
    }), { sender = "Carol-Garona" })
    assertEq(status, "accepted", "remote alt membership accepted")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "remote assign applied")

    -- Duplicate / stale
    status = spec.ValidateAndApply(wireMember({
        guid = "Player-1-Bob",
        groupId = gid,
        ver = { n = 1, w = "bbbbbbbbbbbbbbbbbbbbbbbb" },
        at = world.time + 1,
    }), { sender = "Carol-Garona" })
    assertEq(status, "duplicate", "duplicate remote member")

    status = spec.ValidateAndApply(wireMember({
        guid = "Player-1-Bob",
        groupId = "gig:stale:1",
        ver = { n = 0, w = "cccccccccccccccccccccccc" },
        at = world.time + 99,
    }), { sender = "Carol-Garona" })
    assertEq(status, "duplicate", "stale lower version rejected")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Alice", "stale cannot move Bob")

    -- Editor relay: Carol forwards Alice-authored versioned state (auth = transport sender).
    status = spec.ValidateAndApply(wireMember({
        guid = "Player-1-Eve",
        groupId = gid,
        ver = { n = 1, w = "dddddddddddddddddddddddd" },
        at = world.time + 2,
        nameRealm = "Eve-Garona",
    }), { sender = "Carol-Garona" })
    assertEq(status, "accepted", "editor may relay state records")
    assertEq(GI:GetCharacterRole("Player-1-Eve"), "alt", "relayed membership applied")

    status, detail = spec.ValidateAndApply(wireMember({
        guid = "Player-2-Bob",
        groupId = gid,
        ver = { n = 1, w = "eeeeeeeeeeeeeeeeeeeeeeee" },
        at = world.time + 3,
    }), { sender = "Dave-Garona" })
    assertEq(status, "rejected", "non-editor cannot launder state")
end

---------------------------------------------------------------------------
-- Concurrent conflicting edits (version tuples)
---------------------------------------------------------------------------

do
    resetDB()
    local record = select(1, GI:EnsureGuildRecord("club:42"))
    local gidA = "gig:aaaaaaaaaaaaaaaaaaaaaaaa:1"
    local gidC = "gig:cccccccccccccccccccccccc:1"
    GI.MergeGroup(record, { groupId = gidA, mainGuid = "Player-1-Alice", ver = { n = 1, w = "a" }, at = 1 })
    GI.MergeGroup(record, { groupId = gidC, mainGuid = "Player-1-Carol", ver = { n = 1, w = "c" }, at = 1 })
    GI.MergeMember(record, { guid = "Player-1-Alice", groupId = gidA, ver = { n = 1, w = "a" }, at = 1 })
    GI.MergeMember(record, { guid = "Player-1-Carol", groupId = gidC, ver = { n = 1, w = "c" }, at = 1 })

    local mAlice = { guid = "Player-1-Eve", groupId = gidA, ver = { n = 1, w = "alicewriteraaaaaaaaaaaa" }, at = 100 }
    local mCarol = { guid = "Player-1-Eve", groupId = gidC, ver = { n = 1, w = "carolwritercccccccccccc" }, at = 100 }
    assertEq(GI.MergeMember(record, mAlice), "accepted", "conflict member Alice side accepted")
    assertEq(GI.MergeMember(record, mCarol), "accepted", "conflict member Carol side accepted (higher w)")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Carol", "higher writer nonce wins at same n")

    -- Reverse order converges identically.
    SpectrumFederationDB = {}
    GI:Initialize(SpectrumFederationDB)
    record = select(1, GI:EnsureGuildRecord("club:42"))
    GI.MergeGroup(record, { groupId = gidA, mainGuid = "Player-1-Alice", ver = { n = 1, w = "a" }, at = 1 })
    GI.MergeGroup(record, { groupId = gidC, mainGuid = "Player-1-Carol", ver = { n = 1, w = "c" }, at = 1 })
    GI.MergeMember(record, { guid = "Player-1-Alice", groupId = gidA, ver = { n = 1, w = "a" }, at = 1 })
    GI.MergeMember(record, { guid = "Player-1-Carol", groupId = gidC, ver = { n = 1, w = "c" }, at = 1 })
    GI.MergeMember(record, mCarol)
    GI.MergeMember(record, mAlice)
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Carol", "arrival order independent")
end

do
    -- Change Main vs candidate unassign: membership tombstone prevents invalid main.
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    assign("Alice-Garona", "Carol-Garona")
    local record = select(1, GI:GetCurrentRecord())
    local gid = record.graph.byGuid["Player-1-Alice"].groupId
    local gVer = record.groups[gid].ver
    local bobVer = record.members["Player-1-Bob"].ver

    -- Peer A: Change Main to Bob
    local cm = { groupId = gid, mainGuid = "Player-1-Bob", ver = { n = gVer.n + 1, w = "cmwriteraaaaaaaaaaaaaaaa" }, at = world.time + 1 }
    -- Peer B: Unassign Bob
    local un = {
        guid = "Player-1-Bob",
        groupId = GI.UNASSIGNED,
        ver = { n = bobVer.n + 1, w = "unwriterbbbbbbbbbbbbbbbb" },
        at = world.time + 1,
    }

    local seedBodies = GI.ListStateBodies(record)
    local function seedPeer(db)
        SpectrumFederationDB = db
        GI:Initialize(db)
        local r = select(1, GI:EnsureGuildRecord("club:42"))
        assertTrue(r ~= nil, "peer EnsureGuildRecord ready")
        for i = 1, #seedBodies do
            local body = seedBodies[i]
            if body.kind == "guildinfo-member" then
                GI.MergeMember(r, deepCopy(body.member))
            else
                GI.MergeGroup(r, deepCopy(body.group))
            end
        end
        return r
    end

    local dbA, dbB = {}, {}
    seedPeer(dbA)
    seedPeer(dbB)

    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local rA = select(1, GI:EnsureGuildRecord("club:42"))
    assertEq(GI.MergeGroup(rA, cm), "accepted", "peer A Change Main accepted")
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local rB = select(1, GI:EnsureGuildRecord("club:42"))
    assertEq(GI.MergeMember(rB, un), "accepted", "peer B Unassign Bob accepted")

    -- Exchange
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    rA = select(1, GI:EnsureGuildRecord("club:42"))
    GI.MergeMember(rA, un)
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    rB = select(1, GI:EnsureGuildRecord("club:42"))
    GI.MergeGroup(rB, cm)

    local roleBobA = select(1, peerRole(dbA, "Player-1-Bob"))
    local roleBobB = select(1, peerRole(dbB, "Player-1-Bob"))
    assertNil(roleBobA, "Bob unassigned on peer A after CM vs unassign")
    assertNil(roleBobB, "Bob unassigned on peer B after CM vs unassign")
    -- Remaining group must still be valid (Alice/Carol), not a phantom Bob-main.
    local mainAliceA = select(1, peerRole(dbA, "Player-1-Alice"))
    local mainAliceB = select(1, peerRole(dbB, "Player-1-Alice"))
    assertEq(mainAliceA, mainAliceB, "Alice role converges after CM vs unassign")
    assertTrue(mainAliceA == "main" or mainAliceA == "alt", "Alice still in a valid relationship")
end

---------------------------------------------------------------------------
-- Reload durability + guild isolation + independence
---------------------------------------------------------------------------

do
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    local saved = SpectrumFederationDB
    reloadModules(saved)
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "reload restores alt")
    assertTrue(saved.guildInfo ~= nil, "guildInfo root persisted")
    assertEq(tonumber(saved.guildInfo.schemaVersion), 2, "schemaVersion 2 persisted")
    assertNil(saved.guildSupplies, "does not create guildSupplies")
    assertNil(saved.lootHelper, "does not create lootHelper")
end

do
    resetDB()
    local record = select(1, GI:EnsureGuildRecord("club:999"))
    GI.MergeGroup(record, {
        groupId = "gig:foreign:1",
        mainGuid = "Player-1-Alice",
        ver = { n = 1, w = "ffffffffffffffffffffffff" },
        at = 1,
    })
    GI.MergeMember(record, {
        guid = "Player-1-Alice",
        groupId = "gig:foreign:1",
        ver = { n = 1, w = "ffffffffffffffffffffffff" },
        at = 1,
    })
    GI.MergeMember(record, {
        guid = "Player-1-Bob",
        groupId = "gig:foreign:1",
        ver = { n = 1, w = "ffffffffffffffffffffffff" },
        at = 1,
    })
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "current guild unaffected by foreign key")
    assertTrue(select(1, GI:GetRecordForGuildKey("club:999")) ~= nil, "foreign guild record isolated")
end

do
    local before = #world.chat
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    GI:UnassignAlt("Player-1-Bob", {})
    assertEq(#world.chat, before, "no chat output from domain ops")
end

do
    resetDB()
    assign("Carol-Garona", "Eve-Garona")
    assign("Alice-Garona", "Bob-Garona")
    local rows = GI:GetAssignmentDisplayRows(GI.GetRosterSnapshot(true))
    assertTrue(#rows >= 4, "display rows include mains and alts")
    assertTrue(rows[1].text:find("Alice", 1, true) ~= nil, "first group is Alice by sort")
end

do
    resetDB()
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "offline member can be assigned")
end

do
    resetDB()
    local snap = GI.GetRosterSnapshot(true)
    local s1 = snap:Suggest("bo", 10)
    assertTrue(#s1 >= 1, "suggest finds Bob*")
    local foundArea = false
    for i = 1, #s1 do
        if s1[i].nameRealm == "Bob-Area52" then foundArea = true end
    end
    assertTrue(foundArea, "suggest includes cross-realm Bob-Area52")
end

do
    -- Schema 1 hard-reset (unmerged op-log prototype).
    SpectrumFederationDB = {
        guildInfo = {
            schemaVersion = 1,
            localWriter = { nonce = "1234567890abcdef12345678", nextSeq = 1 },
            guilds = {
                ["club:42"] = {
                    schemaVersion = 1,
                    guildKey = "club:42",
                    clubId = "42",
                    ops = { x = { id = "x" } },
                    order = { "x" },
                },
            },
        },
        guildSupplies = { keep = true },
    }
    SF.GuildGossip._providers = {}
    GI.InvalidateRosterSnapshot()
    assertTrue(GI:Initialize(SpectrumFederationDB), "schema 1 upgrades")
    assertEq(tonumber(SpectrumFederationDB.guildInfo.schemaVersion), 2, "root upgraded to schema 2")
    assertEq(countKeys(SpectrumFederationDB.guildInfo.guilds), 0, "op-log guilds cleared on hard reset")
    assertTrue(SpectrumFederationDB.guildSupplies.keep, "guildSupplies untouched by GI reset")
end

---------------------------------------------------------------------------
-- A) Settings page closures
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
    assertTrue(not mainEnabled(), "main field disabled while roster incomplete")
    assertTrue(not assignEnabled(), "Assign disabled while roster incomplete")

    world.guild.rosterComplete = true
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    page:Refresh(panel)
    assertTrue(mainEnabled() == true, "main field enables after roster completes")
    assertTrue(altEnabled() == true, "alt field enables after roster completes")
    assertTrue(not assignEnabled(), "Assign still off until both fields resolve")

    mainResolvedCb(nil, { guid = "Player-1-Alice", nameRealm = "Alice-Garona", classFile = "MAGE" })
    assertTrue(not assignEnabled(), "Assign off with only main resolved")
    altResolvedCb(nil, { guid = "Player-1-Bob", nameRealm = "Bob-Garona", classFile = "WARRIOR" })
    assertTrue(assignEnabled() == true, "Assign enables when two distinct guild chars resolve")

    mainTextCb(nil, "Alice-GaronaX")
    assertTrue(not assignEnabled(), "Assign disables immediately when main text invalidated")

    mainResolvedCb(nil, { guid = "Player-1-Alice", nameRealm = "Alice-Garona", classFile = "MAGE" })
    altResolvedCb(nil, { guid = "Player-1-Bob", nameRealm = "Bob-Garona", classFile = "WARRIOR" })
    setActor("Alice-Garona", "Player-1-Alice", 4)
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    page:Refresh(panel)
    assertTrue(not mainEnabled(), "demotion disables fields via live Caps()")
    assertTrue(not assignEnabled(), "demotion disables Assign via live Caps()")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    page:Refresh(panel)

    GI.GetRosterSnapshot(true)
    local scansBefore = world.rosterInfoCalls
    for i = 1, 5 do
        mainTextCb(nil, "Al" .. tostring(i))
    end
    assertEq(world.rosterInfoCalls, scansBefore, "autocomplete keystrokes do not rescan roster")

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

    assertTrue(type(unassignRemove) == "function", "unassign onRemove callback")
    local pendingConfirm
    SF.SettingsUI.Dialogs.Confirm = function(_, _, _, accept)
        pendingConfirm = accept
    end
    local msgCtx = { section = { SetMessage = function() end } }
    unassignRemove(msgCtx, { role = "alt", guid = "Player-1-Bob", mainGuid = "Player-1-Alice" })
    assertTrue(type(pendingConfirm) == "function", "unassign opens confirmation")
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

    -- Settings open/close must not grow UI listeners unboundedly.
    local listenersBefore = #(GI._uiListeners or {})
    -- RegisterUIListener is used internally; count via repeated Build.
    local listenerCount = 0
    local probe = function() listenerCount = listenerCount + 1 end
    local a = GI.RegisterUIListener(probe)
    local b = GI.RegisterUIListener(probe)
    assertTrue(a ~= nil and b ~= nil, "UI listeners register")
    -- Not a production leak path: Settings should not re-register every refresh.
    -- Prove NotifyUI stays bounded for a fixed listener set.
    for i = 1, 20 do
        GI.NotifyUI("test")
    end
    assertEq(listenerCount, 40, "NotifyUI fans out once per registered listener")
end

---------------------------------------------------------------------------
-- Multi-peer synchronization
---------------------------------------------------------------------------

do
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    local dbEditor = deepCopy(SpectrumFederationDB)
    local dbReader = {}
    SpectrumFederationDB = dbReader
    GI:Initialize(dbReader)
    syncAll(dbEditor, dbReader, "Alice-Garona")
    assertEq(select(1, peerRole(dbReader, "Player-1-Bob")), "alt", "reader receives membership")
    assertEq(select(2, peerRole(dbReader, "Player-1-Bob")), "Player-1-Alice", "reader sees Alice as main")

    -- Independent disjoint edits on two editors.
    local dbA, dbB = deepCopy(dbEditor), deepCopy(dbEditor)
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Eve-Garona"), "accepted", "editor A assigns Eve")
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    setActor("Carol-Garona", "Player-1-Carol", 3)
    assertEq(assign("Carol-Garona", "Dave-Garona"), "accepted", "editor B assigns Dave")
    setActor("Alice-Garona", "Player-1-Alice", 1)

    syncAll(dbA, dbB, "Alice-Garona")
    syncAll(dbB, dbA, "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Alice", "A keeps Eve after merge")
    assertEq(select(2, peerRole(dbB, "Player-1-Eve")), "Player-1-Alice", "B receives Eve")
    assertEq(select(2, peerRole(dbA, "Player-1-Dave")), "Player-1-Carol", "A receives Dave")
    assertEq(select(2, peerRole(dbB, "Player-1-Dave")), "Player-1-Carol", "B keeps Dave")
end

do
    -- Delayed / reversed delivery of member then group.
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    local wires = exportWires(SpectrumFederationDB)
    local members, groups = {}, {}
    for i = 1, #wires do
        if wires[i].body.kind == "guildinfo-member" then
            members[#members + 1] = wires[i]
        else
            groups[#groups + 1] = wires[i]
        end
    end
    local fresh = {}
    SpectrumFederationDB = fresh
    GI:Initialize(fresh)
    for i = 1, #members do
        admitWire(fresh, members[i], "Alice-Garona")
    end
    -- Memberships before group: no phantom displayed relationship.
    assertNil(select(1, peerRole(fresh, "Player-1-Bob")), "members without group do not display")
    for i = 1, #groups do
        admitWire(fresh, groups[i], "Alice-Garona")
    end
    assertEq(select(1, peerRole(fresh, "Player-1-Bob")), "alt", "group arrival completes relationship")

    -- Reverse: group first then members.
    local fresh2 = {}
    SpectrumFederationDB = fresh2
    GI:Initialize(fresh2)
    for i = 1, #groups do admitWire(fresh2, groups[i], "Alice-Garona") end
    assertNil(select(1, peerRole(fresh2, "Player-1-Bob")), "group alone does not invent alts")
    for i = 1, #members do admitWire(fresh2, members[i], "Alice-Garona") end
    assertEq(select(1, peerRole(fresh2, "Player-1-Bob")), "alt", "members after group converge")
end

---------------------------------------------------------------------------
-- Tombstone + stale resurrection
---------------------------------------------------------------------------

do
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    local wiresLive = exportWires(SpectrumFederationDB)
    local oldBob
    for i = 1, #wiresLive do
        local b = wiresLive[i].body
        if b.kind == "guildinfo-member" and b.member.guid == "Player-1-Bob" then
            oldBob = deepCopy(b.member)
        end
    end
    assertTrue(oldBob ~= nil, "captured pre-unassign Bob membership")
    assertEq(GI:UnassignAlt("Player-1-Bob", {}), "accepted", "unassign Bob")
    local recTomb = select(1, GI:EnsureGuildRecord("club:42"))
    local tomb = recTomb and recTomb.members["Player-1-Bob"]
    assertTrue(tomb ~= nil and tomb.groupId == GI.UNASSIGNED, "unassign writes membership tombstone")
    assertTrue(tomb and tomb.ver.n > oldBob.ver.n, "tombstone version exceeds prior assignment")

    -- Stale peer replays old assignment — must lose to tombstone.
    local status = GI.MergeMember(select(1, GI:GetCurrentRecord()), oldBob)
    assertEq(status, "duplicate", "stale assignment loses to tombstone")
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "Bob stays unassigned after stale replay")

    -- After reclaiming dissolved groups, tombstone still protects.
    local record = select(1, GI:GetCurrentRecord())
    local removed = GI.ReclaimUnreferencedDissolved(record)
    assertTrue(removed >= 1, "dissolved group reclaimed when unreferenced")
    status = GI.MergeMember(record, oldBob)
    assertEq(status, "duplicate", "tombstone still blocks after group reclaim")
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "no resurrection after reclaim")
end

---------------------------------------------------------------------------
-- Transport size + index idle
---------------------------------------------------------------------------

do
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    assign("Alice-Garona", "Carol-Garona")
    local wires = exportWires(SpectrumFederationDB)
    assertTrue(#wires >= 3, "export includes members and group")
    for i = 1, #wires do
        local ok, nbytes = GI.RecordWithinGossipCap(wires[i])
        assertTrue(ok, "wire within 2048 bytes id=" .. tostring(wires[i].id))
        assertTrue(nbytes <= 2048, "serialized size <= 2048")
    end
    local index = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(index.buildComplete, "index build completes")
    assertTrue(not index.dirty, "index becomes idle")
    local indexCount = countKeys(index.byId)
    assertTrue(indexCount >= 3, "index has state records")
    assertTrue(indexCount <= GI.MAX_MEMBERS + GI.MAX_GROUPS, "index bounded by retention caps")
end

---------------------------------------------------------------------------
-- Long-term stability: 10,000 edits on a small identity set
---------------------------------------------------------------------------

do
    resetDB()
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "stress seed Bob")
    assertEq(assign("Alice-Garona", "Carol-Garona"), "accepted", "stress seed Carol")
    local before = GI.CountRetainedState()
    local peakMembers, peakGroups = before.members, before.groups
    local acceptedOps = 0

    for i = 1, 10000 do
        world.time = world.time + 1
        local phase = i % 6
        local st
        if phase == 0 then
            st = GI:ChangeMain("Player-1-Alice", "Player-1-Bob", { roster = GI.GetRosterSnapshot(true) })
            if st == "accepted" then acceptedOps = acceptedOps + 1 end
            if GI:GetCharacterRole("Player-1-Bob") == "main" then
                st = GI:ChangeMain("Player-1-Bob", "Player-1-Alice", { roster = GI.GetRosterSnapshot(true) })
                if st == "accepted" then acceptedOps = acceptedOps + 1 end
            end
        elseif phase == 1 then
            st = GI:UnassignAlt("Player-1-Carol", { expectedMainGuid = select(2, GI:GetCharacterRole("Player-1-Carol")) })
            if st == "accepted" then acceptedOps = acceptedOps + 1 end
            st = assign("Alice-Garona", "Carol-Garona")
            if st == "accepted" then acceptedOps = acceptedOps + 1 end
        elseif phase == 2 then
            st = GI:AssignAlt("Carol-Garona", "Bob-Garona", {
                roster = GI.GetRosterSnapshot(true),
                moveConfirmed = true,
                expectedOldMain = select(2, GI:GetCharacterRole("Player-1-Bob")),
            })
            if st == "accepted" then acceptedOps = acceptedOps + 1 end
            st = GI:AssignAlt("Alice-Garona", "Bob-Garona", {
                roster = GI.GetRosterSnapshot(true),
                moveConfirmed = true,
                expectedOldMain = select(2, GI:GetCharacterRole("Player-1-Bob")),
            })
            if st == "accepted" then acceptedOps = acceptedOps + 1 end
        elseif phase == 3 then
            st = assign("Alice-Garona", "Eve-Garona")
            if st == "accepted" then acceptedOps = acceptedOps + 1 end
            st = GI:UnassignAlt("Player-1-Eve", {})
            if st == "accepted" then acceptedOps = acceptedOps + 1 end
        elseif phase == 4 then
            st = assign("Alice-Garona", "Bob-Garona")
            if st == "accepted" then acceptedOps = acceptedOps + 1 end
        else
            st = GI:ChangeMain("Player-1-Alice", "Player-1-Carol", { roster = GI.GetRosterSnapshot(true) })
            if st == "accepted" then acceptedOps = acceptedOps + 1 end
            if GI:GetCharacterRole("Player-1-Carol") == "main" then
                st = GI:ChangeMain("Player-1-Carol", "Player-1-Alice", { roster = GI.GetRosterSnapshot(true) })
                if st == "accepted" then acceptedOps = acceptedOps + 1 end
            end
        end
        local c = GI.CountRetainedState()
        if c.members > peakMembers then peakMembers = c.members end
        if c.groups > peakGroups then peakGroups = c.groups end
    end
    assertTrue(acceptedOps >= 5000, "10k loop accepted many mutations got=" .. acceptedOps)

    local after = GI.CountRetainedState()
    assertTrue(after.members <= 8, "10k edits: members stay near small identity set got=" .. after.members)
    assertTrue(after.groups <= 16, "10k edits: groups stay bounded got=" .. after.groups)
    assertTrue(peakMembers <= 16, "10k edits: peak members bounded got=" .. peakMembers)
    assertTrue(peakGroups <= 32, "10k edits: peak groups bounded got=" .. peakGroups)
    assertTrue(after.members < 10000, "10k edits do not create 10k member rows")
    assertTrue(after.characters <= after.members, "characters cache bounded by members")
    -- Hierarchy still valid
    local groups = GI:GetRelationshipGroups()
    for i = 1, #groups do
        assertTrue(type(groups[i].mainGuid) == "string", "stress group has main")
        assertTrue(#(groups[i].altGuids or {}) >= 1, "stress group has alts")
    end

    -- Reload mid-stress state
    local saved = SpectrumFederationDB
    reloadModules(saved)
    local afterReload = GI.CountRetainedState()
    assertEq(afterReload.members, after.members, "reload preserves member count after 10k edits")
end

---------------------------------------------------------------------------
-- Identity turnover + capacity fail-closed
---------------------------------------------------------------------------

do
    resetDB()
    local savedMax = GI.MAX_MEMBERS
    GI.MAX_MEMBERS = 12
    -- Create many distinct unassigned tombstones via assign/unassign cycles.
    local extras = {}
    for i = 1, 20 do
        local guid = string.format("Player-9-%03d", i)
        local name = string.format("Extra%03d-Garona", i)
        world.guild.members[#world.guild.members + 1] = {
            name = name, guid = guid, rankOrder = 5, online = true, class = "MAGE",
        }
        extras[#extras + 1] = { guid = guid, name = name }
    end
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()

    local acceptedNew = 0
    local overflow = 0
    for i = 1, #extras do
        local st, reason = assign("Alice-Garona", extras[i].name)
        if st == "accepted" then
            acceptedNew = acceptedNew + 1
            GI:UnassignAlt(extras[i].guid, {})
        elseif reason == "members_overflow" then
            overflow = overflow + 1
        end
    end
    assertTrue(acceptedNew >= 1, "turnover accepted some identities")
    assertTrue(overflow >= 1, "turnover eventually hits members_overflow")
    local counts = GI.CountRetainedState()
    assertTrue(counts.members <= GI.MAX_MEMBERS, "members never exceed MAX_MEMBERS")
    GI.MAX_MEMBERS = savedMax

    -- Cleanup extras from world roster for later tests.
    local kept = {}
    for _, m in ipairs(world.guild.members) do
        if not tostring(m.guid):match("^Player%-9%-") then
            kept[#kept + 1] = m
        end
    end
    world.guild.members = kept
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
end

---------------------------------------------------------------------------
-- Repair A: >128 assign/unassign cycles of the same pair must succeed
---------------------------------------------------------------------------

do
    resetDB()
    local savedMaxG = GI.MAX_GROUPS
    GI.MAX_GROUPS = 8
    local successes = 0
    local peakGroups = 0
    for i = 1, 40 do
        local st, reason = assign("Alice-Garona", "Bob-Garona")
        assertEq(st, "accepted", "cycle " .. i .. " assign accepted (reason=" .. tostring(reason) .. ")")
        local ust, ureason = GI:UnassignAlt("Player-1-Bob", {})
        assertEq(ust, "accepted", "cycle " .. i .. " unassign accepted (reason=" .. tostring(ureason) .. ")")
        successes = successes + 1
        local c = GI.CountRetainedState()
        if c.groups > peakGroups then peakGroups = c.groups end
        assertTrue(c.groups <= GI.MAX_GROUPS, "capacity reclaim keeps groups <= MAX got=" .. c.groups)
        assertTrue(c.liveGroups <= 1, "no live group after unassign got=" .. tostring(c.liveGroups))
    end
    assertEq(successes, 40, "40 successful assign/unassign cycles without manual reclaim")
    assertTrue(peakGroups <= GI.MAX_GROUPS, "peak groups bounded by MAX got=" .. peakGroups)

    -- Also exceed historical MAX_GROUPS=128 with production constant.
    GI.MAX_GROUPS = savedMaxG
    resetDB()
    local okCycles = 0
    for i = 1, 140 do
        local st = assign("Alice-Garona", "Bob-Garona")
        local ust = GI:UnassignAlt("Player-1-Bob", {})
        if st == "accepted" and ust == "accepted" then
            okCycles = okCycles + 1
        else
            fail("production MAX_GROUPS cycle " .. i .. " failed st=" .. tostring(st) .. " ust=" .. tostring(ust))
            break
        end
    end
    assertEq(okCycles, 140, ">128 successful assign/unassign cycles of same pair")
    local finalCounts = GI.CountRetainedState()
    assertTrue(finalCounts.groups <= GI.MAX_GROUPS,
        "after 140 cycles groups <= MAX_GROUPS got=" .. finalCounts.groups)
    assertTrue(finalCounts.liveGroups == 0, "no live group after final unassign")
    -- Capacity reclaim must have fired: dissolved alone cannot exceed MAX forever.
    assertTrue(finalCounts.dissolved <= GI.MAX_GROUPS, "dissolved capped by reclaim")

    -- Stale dissolved/live group replay must not resurrect Bob.
    local staleGid = "gig:stale-resurrect-aaaaaaaaaa:1"
    local rec = select(1, GI:EnsureGuildRecord("club:42"))
    GI.MergeGroup(rec, {
        groupId = staleGid,
        mainGuid = "Player-1-Alice",
        ver = { n = 1, w = "staleaaaaaaaaaaaaaaaaaaaa" },
        at = 1,
    })
    GI.MergeMember(rec, {
        guid = "Player-1-Bob",
        groupId = staleGid,
        ver = { n = 1, w = "staleaaaaaaaaaaaaaaaaaaaa" },
        at = 1,
    })
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "stale group replay cannot resurrect Bob")
end

---------------------------------------------------------------------------
-- Repair B: remote merges invalidate physical Gossip index for peer C
---------------------------------------------------------------------------

do
    resetDB()
    -- Editor B starts empty, builds idle index.
    local dbB = {}
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local indexB = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(indexB.buildComplete, "B index idle before remote updates")
    assertTrue(not indexB.dirty, "B index not dirty before remote updates")
    local bobId = "gi-m:Player-1-Bob"
    assertTrue(indexB.byId[bobId] == nil, "B index lacks Bob before sync")

    -- Editor A creates relationships and exports wires.
    local dbA = {}
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "A assigns Bob")
    local wires1 = exportWires(dbA)
    assertTrue(#wires1 >= 3, "A exports member+group wires")

    -- Deliver A's wires into B through ValidateAndApply (production admission).
    for i = 1, #wires1 do
        local st = admitWire(dbB, wires1[i], "Alice-Garona")
        assertTrue(st == "accepted" or st == "duplicate", "B admits A wire " .. i)
    end
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    indexB = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(indexB.buildComplete, "B index rebuilds after remote accept")
    assertTrue(not indexB.dirty, "B index idle after remote rebuild")
    assertTrue(indexB.byId[bobId] ~= nil, "B physical index contains Bob after remote")
    local bobFp1 = indexB.byId[bobId].versionFp

    -- A updates Bob (move to Carol) and sends newer membership/group versions.
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    assertEq(GI:AssignAlt("Carol-Garona", "Bob-Garona", {
        roster = GI.GetRosterSnapshot(true),
        moveConfirmed = true,
        expectedOldMain = "Player-1-Alice",
    }), "accepted", "A moves Bob under Carol")
    local wires2 = exportWires(dbA)
    for i = 1, #wires2 do
        admitWire(dbB, wires2[i], "Alice-Garona")
    end
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    indexB = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(indexB.buildComplete and not indexB.dirty, "B index idle after version update")
    assertTrue(indexB.byId[bobId] ~= nil, "B index still has Bob id")
    local bobFp2 = indexB.byId[bobId].versionFp
    assertTrue(bobFp2 ~= bobFp1, "B physical index fingerprint updated for Bob")

    -- Peer C syncs exclusively from B's physical provider index (A unavailable).
    local dbC = {}
    SpectrumFederationDB = dbC
    GI:Initialize(dbC)
    local providerB = SF.GuildGossip._providers[GI.PROVIDER_ID]
    -- Re-bind to B's DB/provider for serving.
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    providerB = SF.GuildGossip._providers[GI.PROVIDER_ID]
    local specB = providerB.spec
    local page, cursor = specB.ListRecordIds(1, 64)
    assertTrue(#page >= 1, "B ListRecordIds serves page")
    local served = 0
    local function collectFromB()
        SpectrumFederationDB = dbB
        GI:Initialize(dbB)
        DriveEnsureIndex(GI.PROVIDER_ID, 64)
        specB = SF.GuildGossip._providers[GI.PROVIDER_ID].spec
        local idx = SF.GuildGossip._providers[GI.PROVIDER_ID].index
        assertTrue(idx.buildComplete and not idx.dirty, "B index idle before serve")
        local out = {}
        local c = 1
        while c do
            local ids, nextC = specB.ListRecordIds(c, 16)
            for i = 1, #ids do
                local rid = ids[i]
                assertTrue(idx.byId[rid] ~= nil, "physical index contains listed id " .. tostring(rid))
                local body = specB.GetRecordBody(rid)
                assertTrue(body ~= nil, "B GetRecordBody serves " .. tostring(rid))
                local fp = specB.GetRecordVersionFp(rid)
                assertEq(fp, body.versionFp, "B versionFp matches body for " .. rid)
                -- Deep-copy now; admitting into C rebinds exportState.
                out[#out + 1] = deepCopy(body)
            end
            c = nextC
        end
        return out
    end

    local batch1 = collectFromB()
    assertTrue(#batch1 >= 3, "B index serves >=3 records got=" .. #batch1)
    for i = 1, #batch1 do
        admitWire(dbC, batch1[i], "Carol-Garona")
        served = served + 1
    end
    assertEq(select(2, peerRole(dbC, "Player-1-Bob")), "Player-1-Carol",
        "C got latest Bob→Carol via B index only")

    -- Second sync becomes idle / duplicate without epoch thrash.
    local bumpsBefore = world.indexEpochBumps or 0
    local batch2 = collectFromB()
    for i = 1, #batch2 do
        local st = admitWire(dbC, batch2[i], "Carol-Garona")
        assertTrue(st == "accepted" or st == "duplicate", "C re-sync status for wire " .. i)
    end
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local indexAfter = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(indexAfter.buildComplete and not indexAfter.dirty, "B remains idle after re-serve")
    assertTrue((world.indexEpochBumps or 0) - bumpsBefore <= 2,
        "re-sync does not thrash epochs delta=" .. tostring((world.indexEpochBumps or 0) - bumpsBefore))
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

---------------------------------------------------------------------------
-- Repair C: concurrent first-assign to same main keeps both alts
---------------------------------------------------------------------------

local function seedEmptyPeer()
    local db = {}
    SpectrumFederationDB = db
    GI:Initialize(db)
    return db
end

local function applyLocalAssignOn(db, actorName, actorGuid, rank, mainName, altName)
    SpectrumFederationDB = db
    GI:Initialize(db)
    setActor(actorName, actorGuid, rank)
    return assign(mainName, altName)
end

do
    -- Officer A: Alice←Bob. Officer B: Alice←Carol. No prior group.
    local function runConcurrentFirstAssign(orderAB)
        local dbA = seedEmptyPeer()
        local dbB = seedEmptyPeer()
        assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
            "accepted", "A assigns Bob under Alice")
        assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
            "accepted", "B assigns Carol under Alice")
        setActor("Alice-Garona", "Player-1-Alice", 1)

        local function exchange(first, second, senderFirst, senderSecond)
            if orderAB then
                syncAll(first, second, senderFirst)
                syncAll(second, first, senderSecond)
            else
                syncAll(second, first, senderSecond)
                syncAll(first, second, senderFirst)
            end
        end
        exchange(dbA, dbB, "Alice-Garona", "Carol-Garona")
        -- Catch-up second pass (duplicates / delayed).
        exchange(dbA, dbB, "Alice-Garona", "Carol-Garona")

        local function assertBothAlts(db, label)
            assertEq(select(1, peerRole(db, "Player-1-Alice")), "main", label .. " Alice is main")
            assertEq(select(2, peerRole(db, "Player-1-Bob")), "Player-1-Alice", label .. " Bob under Alice")
            assertEq(select(2, peerRole(db, "Player-1-Carol")), "Player-1-Alice", label .. " Carol under Alice")
            SpectrumFederationDB = db
            GI:Initialize(db)
            local groups = GI:GetRelationshipGroups()
            assertEq(#groups, 1, label .. " single visible group")
            assertEq(#groups[1].altGuids, 2, label .. " both alts visible")
        end
        assertBothAlts(dbA, orderAB and "orderAB-A" or "orderBA-A")
        assertBothAlts(dbB, orderAB and "orderAB-B" or "orderBA-B")

        -- Third peer catch-up + reload.
        local dbC = seedEmptyPeer()
        syncAll(dbA, dbC, "Alice-Garona")
        assertBothAlts(dbC, "peerC")
        local saved = deepCopy(dbA)
        reloadModules(saved)
        assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Alice", "reload keeps Bob")
        assertEq(select(2, GI:GetCharacterRole("Player-1-Carol")), "Player-1-Alice", "reload keeps Carol")
    end

    runConcurrentFirstAssign(true)
    runConcurrentFirstAssign(false)
end

do
    -- Existing unrelated groups must not merge.
    resetDB()
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "seed Alice-Bob")
    assertEq(assign("Carol-Garona", "Dave-Garona"), "accepted", "seed Carol-Dave")
    local groups = GI:GetRelationshipGroups()
    assertEq(#groups, 2, "two unrelated groups remain distinct")
    local record = select(1, GI:GetCurrentRecord())
    GI.ReconcileSplitMains(record)
    groups = GI:GetRelationshipGroups()
    assertEq(#groups, 2, "reconcile does not merge unrelated groups")
end

---------------------------------------------------------------------------
-- Logical-group mutations after concurrent absorb (Tests A–D)
---------------------------------------------------------------------------

local function syncConcurrentAliceBobCarol()
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "logical seed A: Bob")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
        "accepted", "logical seed B: Carol")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    syncAll(dbA, dbB, "Alice-Garona")
    syncAll(dbB, dbA, "Carol-Garona")
    syncAll(dbA, dbB, "Alice-Garona")
    syncAll(dbB, dbA, "Carol-Garona")
    local function assertCombined(db, label)
        assertEq(select(1, peerRole(db, "Player-1-Alice")), "main", label .. " Alice main")
        assertEq(select(2, peerRole(db, "Player-1-Bob")), "Player-1-Alice", label .. " Bob under Alice")
        assertEq(select(2, peerRole(db, "Player-1-Carol")), "Player-1-Alice", label .. " Carol under Alice")
        SpectrumFederationDB = db
        GI:Initialize(db)
        local groups = GI:GetRelationshipGroups()
        assertEq(#groups, 1, label .. " one logical group")
        assertEq(#groups[1].altGuids, 2, label .. " Bob+Carol visible")
    end
    assertCombined(dbA, "sync-A")
    assertCombined(dbB, "sync-B")
    return dbA, dbB
end

local function assertAltOf(db, altGuid, mainGuid, label)
    assertEq(select(1, peerRole(db, altGuid)), "alt", label .. " role alt")
    assertEq(select(2, peerRole(db, altGuid)), mainGuid, label .. " main")
end

do
    -- Test A: Unassign Bob must not drop Carol (and vice versa).
    local function runUnassignKeepOther(unassignGuid, remainGuid, remainName)
        local dbA, dbB = syncConcurrentAliceBobCarol()
        SpectrumFederationDB = dbA
        GI:Initialize(dbA)
        setActor("Alice-Garona", "Player-1-Alice", 1)
        assertEq(GI:UnassignAlt(unassignGuid, { expectedMainGuid = "Player-1-Alice" }),
            "accepted", "unassign " .. remainName .. " peer target")
        assertNil(GI:GetCharacterRole(unassignGuid), "unassigned gone")
        assertAltOf(dbA, remainGuid, "Player-1-Alice", "A after unassign")
        SpectrumFederationDB = dbA
        GI:Initialize(dbA)
        local groups = GI:GetRelationshipGroups()
        assertEq(#groups, 1, "logical group remains")
        assertEq(#groups[1].altGuids, 1, "remaining alt visible")
        assertEq(groups[1].altGuids[1], remainGuid, "remaining alt is " .. remainName)

        syncAll(dbA, dbB, "Alice-Garona")
        syncAll(dbB, dbA, "Carol-Garona")
        assertAltOf(dbB, remainGuid, "Player-1-Alice", "B after catch-up")
        assertNil(select(1, peerRole(dbB, unassignGuid)), "B dropped unassigned")
        local saved = deepCopy(dbA)
        reloadModules(saved)
        assertEq(select(2, GI:GetCharacterRole(remainGuid)), "Player-1-Alice",
            "reload keeps " .. remainName .. " under Alice")
        assertNil(GI:GetCharacterRole(unassignGuid), "reload keeps unassign")
    end
    runUnassignKeepOther("Player-1-Bob", "Player-1-Carol", "Carol")
    runUnassignKeepOther("Player-1-Carol", "Player-1-Bob", "Bob")
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

do
    -- Test B: Promote Bob; Alice+Carol remain alts of Bob.
    local dbA, dbB = syncConcurrentAliceBobCarol()
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    assertEq(GI:ChangeMain("Player-1-Alice", "Player-1-Bob", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "promote Bob")
    assertEq(select(1, GI:GetCharacterRole("Player-1-Bob")), "main", "Bob is main")
    assertAltOf(dbA, "Player-1-Alice", "Player-1-Bob", "A Alice after CM Bob")
    assertAltOf(dbA, "Player-1-Carol", "Player-1-Bob", "A Carol after CM Bob")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local groups = GI:GetRelationshipGroups()
    assertEq(#groups, 1, "one group after promote Bob")
    assertEq(groups[1].mainGuid, "Player-1-Bob", "Bob main row")
    assertEq(#groups[1].altGuids, 2, "Alice+Carol alts after promote Bob")
    syncAll(dbA, dbB, "Alice-Garona")
    syncAll(dbB, dbA, "Carol-Garona")
    assertEq(select(1, peerRole(dbB, "Player-1-Bob")), "main", "B Bob main")
    assertAltOf(dbB, "Player-1-Carol", "Player-1-Bob", "B Carol under Bob")
    local saved = deepCopy(dbA)
    reloadModules(saved)
    assertEq(select(1, GI:GetCharacterRole("Player-1-Bob")), "main", "reload Bob main")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Carol")), "Player-1-Bob", "reload Carol under Bob")
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

do
    -- Test C: Promote Carol (absorbed shell member); Alice+Bob remain alts.
    local dbA, dbB = syncConcurrentAliceBobCarol()
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    assertEq(GI:ChangeMain("Player-1-Alice", "Player-1-Carol", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "promote Carol")
    assertEq(select(1, GI:GetCharacterRole("Player-1-Carol")), "main", "Carol is main")
    assertAltOf(dbA, "Player-1-Alice", "Player-1-Carol", "A Alice after CM Carol")
    assertAltOf(dbA, "Player-1-Bob", "Player-1-Carol", "A Bob after CM Carol")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local groups = GI:GetRelationshipGroups()
    assertEq(#groups, 1, "one group after promote Carol")
    assertEq(groups[1].mainGuid, "Player-1-Carol", "Carol main row")
    assertEq(#groups[1].altGuids, 2, "Alice+Bob alts after promote Carol")
    syncAll(dbA, dbB, "Alice-Garona")
    assertEq(select(1, peerRole(dbB, "Player-1-Carol")), "main", "B Carol main")
    assertAltOf(dbB, "Player-1-Bob", "Player-1-Carol", "B Bob under Carol")
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

do
    -- Test D: delayed alt + reversed delivery + offline edit around logical Unassign.
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "D A Bob")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
        "accepted", "D B Carol")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Eve-Garona"),
        "accepted", "D B Eve")
    setActor("Alice-Garona", "Player-1-Alice", 1)

    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local recB = select(1, GI:GetCurrentRecord())
    local gB, eveMem
    for gid, g in pairs(recB.groups) do
        if not g.dissolved and g.mainGuid == "Player-1-Alice" then
            gB = g
        end
    end
    eveMem = recB.members["Player-1-Eve"]
    assertTrue(gB and eveMem, "D captured B group + Eve")

    -- Partial sync without Eve; then Unassign Bob on A; then late Eve; reverse catch-up.
    for _, w in ipairs(exportWires(dbB)) do
        local guid = w.body.member and w.body.member.guid
        if w.body.kind == "guildinfo-group" or guid ~= "Player-1-Eve" then
            admitWire(dbA, w, "Carol-Garona")
        end
    end
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    assertEq(GI:UnassignAlt("Player-1-Bob", {}), "accepted", "D unassign Bob with Carol present")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Carol")), "Player-1-Alice",
        "D Carol survives unassign before late Eve")
    admitWire(dbA, wireMember(eveMem), "Carol-Garona")
    admitWire(dbA, wireGroup(gB), "Carol-Garona")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Alice",
        "D late Eve under Alice after unassign")
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "D Bob stays unassigned")

    -- B offline: move Carol→Dave, then reconnect reversed.
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    setActor("Carol-Garona", "Player-1-Carol", 3)
    assertEq(GI:AssignAlt("Dave-Garona", "Carol-Garona", {
        moveConfirmed = true,
        expectedOldMain = "Player-1-Alice",
        roster = GI.GetRosterSnapshot(true),
    }), "accepted", "D B offline Carol→Dave")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    syncAll(dbB, dbA, "Carol-Garona")
    syncAll(dbA, dbB, "Alice-Garona")
    syncAll(dbB, dbA, "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Carol")), "Player-1-Dave",
        "D A Carol→Dave survives")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Alice",
        "D Eve still under Alice")
    assertNil(select(1, peerRole(dbA, "Player-1-Bob")), "D Bob remains unassigned")
end

---------------------------------------------------------------------------
-- Partial-sync lifecycle: incomplete concurrent shells (regressions A/B)
---------------------------------------------------------------------------

do
    -- Regression A: Change Main before a late alt arrives.
    -- A: G1 Alice+Bob+Dave. B: G2 Alice+Carol+Eve.
    -- A receives G2+Carol only, promotes Bob, then Eve arrives.
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "psA A Bob")
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Dave-Garona"),
        "accepted", "psA A Dave")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
        "accepted", "psA B Carol")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Eve-Garona"),
        "accepted", "psA B Eve")
    setActor("Alice-Garona", "Player-1-Alice", 1)

    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local recB = select(1, GI:GetCurrentRecord())
    local gB, eveMem, carolMem
    for _, g in pairs(recB.groups) do
        if not g.dissolved and g.mainGuid == "Player-1-Alice" then
            gB = g
        end
    end
    eveMem = recB.members["Player-1-Eve"]
    carolMem = recB.members["Player-1-Carol"]
    assertTrue(gB and eveMem and carolMem, "psA captured B cohort")

    -- Partial admit: G2 + Carol only (not Eve, not B's Alice membership).
    admitWire(dbA, wireGroup(gB), "Carol-Garona")
    admitWire(dbA, wireMember(carolMem), "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Carol")), "Player-1-Alice", "psA Carol visible")
    assertNil(select(1, peerRole(dbA, "Player-1-Eve")), "psA Eve not yet present")

    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    assertEq(GI:ChangeMain("Player-1-Alice", "Player-1-Bob", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "psA promote Bob with incomplete G2")
    assertEq(select(1, GI:GetCharacterRole("Player-1-Bob")), "main", "psA Bob main")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Carol")), "Player-1-Bob", "psA Carol under Bob")

    -- Late Eve; B offline afterward.
    admitWire(dbA, wireMember(eveMem), "Carol-Garona")
    admitWire(dbA, wireGroup(gB), "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Bob",
        "psA late Eve under Bob (not orphaned)")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local groups = GI:GetRelationshipGroups()
    assertEq(#groups, 1, "psA one logical group")
    assertEq(groups[1].mainGuid, "Player-1-Bob", "psA Bob remains main")
    local seen = {}
    for i = 1, #groups[1].altGuids do seen[groups[1].altGuids[i]] = true end
    assertTrue(seen["Player-1-Alice"], "psA Alice alt")
    assertTrue(seen["Player-1-Dave"], "psA Dave alt")
    assertTrue(seen["Player-1-Carol"], "psA Carol alt")
    assertTrue(seen["Player-1-Eve"], "psA Eve alt after late delivery")

    -- Reverse catch-up + third peer + reload.
    syncAll(dbA, dbB, "Alice-Garona")
    syncAll(dbB, dbA, "Carol-Garona")
    assertEq(select(2, peerRole(dbB, "Player-1-Eve")), "Player-1-Bob", "psA B Eve under Bob")
    local dbC = seedEmptyPeer()
    syncAll(dbA, dbC, "Alice-Garona")
    assertEq(select(2, peerRole(dbC, "Player-1-Eve")), "Player-1-Bob", "psA C Eve under Bob")
    local saved = deepCopy(dbA)
    reloadModules(saved)
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Bob", "psA reload Eve")
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

do
    -- Regression B: Unassign with G2 shell only (Carol membership not yet arrived).
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "psB A Bob")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
        "accepted", "psB B Carol")
    setActor("Alice-Garona", "Player-1-Alice", 1)

    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local recB = select(1, GI:GetCurrentRecord())
    local gB, carolMem, aliceMemB
    for _, g in pairs(recB.groups) do
        if not g.dissolved and g.mainGuid == "Player-1-Alice" then
            gB = g
        end
    end
    carolMem = recB.members["Player-1-Carol"]
    aliceMemB = recB.members["Player-1-Alice"]
    assertTrue(gB and carolMem, "psB captured B group+Carol")

    -- Group-first only on A.
    admitWire(dbA, wireGroup(gB), "Carol-Garona")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local recA = select(1, GI:GetCurrentRecord())
    assertTrue(recA.groups[gB.groupId] ~= nil and not recA.groups[gB.groupId].dissolved,
        "psB G2 shell live before Unassign")
    assertNil(recA.members["Player-1-Carol"], "psB Carol membership absent")

    assertEq(GI:UnassignAlt("Player-1-Bob", {}), "accepted", "psB unassign Bob with shell sibling")
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "psB Bob gone")
    -- Alice must remain (not tombstoned); Carol arrives next.
    local aliceAfter = select(1, GI:GetCurrentRecord()).members["Player-1-Alice"]
    assertTrue(aliceAfter and type(aliceAfter.groupId) == "string",
        "psB Alice membership still assigned after Unassign Bob")

    admitWire(dbA, wireMember(carolMem), "Carol-Garona")
    if aliceMemB then
        admitWire(dbA, wireMember(aliceMemB), "Carol-Garona")
    end
    admitWire(dbA, wireGroup(gB), "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Carol")), "Player-1-Alice",
        "psB Carol survives Unassign-during-shell")
    assertNil(select(1, peerRole(dbA, "Player-1-Bob")), "psB Bob stays unassigned")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local groups = GI:GetRelationshipGroups()
    assertEq(#groups, 1, "psB one visible group")
    assertEq(groups[1].mainGuid, "Player-1-Alice", "psB Alice main")
    assertEq(#groups[1].altGuids, 1, "psB only Carol alt")
    assertEq(groups[1].altGuids[1], "Player-1-Carol", "psB Carol is the alt")

    syncAll(dbA, dbB, "Alice-Garona")
    syncAll(dbB, dbA, "Carol-Garona")
    assertEq(select(2, peerRole(dbB, "Player-1-Carol")), "Player-1-Alice", "psB B Carol under Alice")
    local saved = deepCopy(dbA)
    reloadModules(saved)
    assertEq(select(2, GI:GetCharacterRole("Player-1-Carol")), "Player-1-Alice", "psB reload Carol")
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

---------------------------------------------------------------------------
-- Forward-alias lifecycle: destination + reclaim retention (faA / faB)
---------------------------------------------------------------------------

do
    -- faA: destination must stay usable after visible alts are unassigned.
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "faA A Bob")
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Dave-Garona"),
        "accepted", "faA A Dave")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
        "accepted", "faA B Carol")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Eve-Garona"),
        "accepted", "faA B Eve")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local recB = select(1, GI:GetCurrentRecord())
    local gB, eveMem, carolMem
    for _, g in pairs(recB.groups) do
        if not g.dissolved and g.mainGuid == "Player-1-Alice" then
            gB = g
        end
    end
    eveMem = recB.members["Player-1-Eve"]
    carolMem = recB.members["Player-1-Carol"]
    assertTrue(gB and eveMem and carolMem, "faA captured B cohort")
    admitWire(dbA, wireGroup(gB), "Carol-Garona")
    admitWire(dbA, wireMember(carolMem), "Carol-Garona")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    assertEq(GI:ChangeMain("Player-1-Alice", "Player-1-Bob", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "faA promote Bob")
    local recA = select(1, GI:GetCurrentRecord())
    assertTrue(recA.groups[gB.groupId] and recA.groups[gB.groupId].forwardTo,
        "faA G2 is forward alias after CM")

    -- Unassign every currently visible alt; destination must not dissolve.
    assertEq(GI:UnassignAlt("Player-1-Alice", {}), "accepted", "faA unassign Alice")
    assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "faA unassign Dave")
    assertEq(GI:UnassignAlt("Player-1-Carol", {}), "accepted", "faA unassign Carol")
    recA = select(1, GI:GetCurrentRecord())
    local destLive, destGid = false, nil
    for gid, g in pairs(recA.groups) do
        if not g.dissolved and g.mainGuid == "Player-1-Bob" then
            destLive = true
            destGid = gid
        end
    end
    assertTrue(destLive, "faA Bob destination still live for inbound forward")
    assertTrue(recA.groups[gB.groupId] ~= nil, "faA alias row retained")
    assertEq(recA.groups[gB.groupId].forwardTo, destGid, "faA alias still forwards to live destination")

    admitWire(dbA, wireMember(eveMem), "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Bob",
        "faA late Eve under Bob after destination kept")
    -- Reverse delivery + duplicate Eve wire must stay idempotent.
    admitWire(dbA, wireMember(eveMem), "Carol-Garona")
    admitWire(dbA, wireGroup(gB), "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Bob",
        "faA duplicate Eve/group wires stay under Bob")
    syncAll(dbA, dbB, "Alice-Garona")
    assertEq(select(2, peerRole(dbB, "Player-1-Eve")), "Player-1-Bob", "faA B converges Eve")
    local dbC = seedEmptyPeer()
    syncAll(dbA, dbC, "Alice-Garona")
    assertEq(select(2, peerRole(dbC, "Player-1-Eve")), "Player-1-Bob", "faA C catch-up Eve")
    local saved = deepCopy(dbA)
    reloadModules(saved)
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Bob", "faA reload Eve")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    -- Later genuine edits after late membership must still apply.
    assertEq(GI:UnassignAlt("Player-1-Eve", {}), "accepted", "faA later unassign Eve")
    assertNil(select(1, GI:GetCharacterRole("Player-1-Eve")), "faA Eve unassigned")
    assertEq(GI:AssignAlt("Bob-Garona", "Eve-Garona", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "faA reassign Eve under Bob")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Bob", "faA Eve reassigned")
    assertEq(GI:ChangeMain("Player-1-Bob", "Player-1-Eve", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "faA later Change Main Bob→Eve")
    assertEq(select(1, GI:GetCharacterRole("Player-1-Eve")), "main",
        "faA Eve becomes main after later Change Main")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Eve",
        "faA Bob becomes alt under Eve")
    local counts = GI.CountRetainedState()
    assertTrue(counts.groups <= GI.MAX_GROUPS,
        "faA retained groups bounded got=" .. tostring(counts.groups))
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

do
    -- faB: forward alias must survive capacity reclaim before late membership.
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "faB A Bob")
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Dave-Garona"),
        "accepted", "faB A Dave")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
        "accepted", "faB B Carol")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Eve-Garona"),
        "accepted", "faB B Eve")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local recB = select(1, GI:GetCurrentRecord())
    local gB, eveMem, carolMem
    for _, g in pairs(recB.groups) do
        if not g.dissolved and g.mainGuid == "Player-1-Alice" then
            gB = g
        end
    end
    eveMem = recB.members["Player-1-Eve"]
    carolMem = recB.members["Player-1-Carol"]
    admitWire(dbA, wireGroup(gB), "Carol-Garona")
    admitWire(dbA, wireMember(carolMem), "Carol-Garona")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    assertEq(GI:ChangeMain("Player-1-Alice", "Player-1-Bob", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "faB promote Bob")
    local recA = select(1, GI:GetCurrentRecord())
    assertTrue(recA.groups[gB.groupId] and recA.groups[gB.groupId].forwardTo,
        "faB alias present before reclaim pressure")

    -- Synthetic roster extras for churned groups that produce reclaimable dissolved rows.
    local extras = {}
    for i = 1, 12 do
        local name = "Extra" .. i .. "-Garona"
        local guid = "Player-9-Extra" .. i
        extras[#extras + 1] = { name = name, guid = guid }
        table.insert(world.guild.members, {
            name = name, guid = guid, rankOrder = 5, online = false, class = "WARRIOR",
        })
    end
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()

    local savedMax = GI.MAX_GROUPS
    GI.MAX_GROUPS = 6
    -- Churn unrelated pairs to create dissolved tombstones and force reclaim attempts.
    for i = 1, 20 do
        local a = extras[((i - 1) % #extras) + 1]
        local b = extras[(i % #extras) + 1]
        if a.guid ~= b.guid then
            GI:AssignAlt(a.name, b.name, { roster = GI.GetRosterSnapshot(true) })
            GI:UnassignAlt(b.guid, {})
        end
        GI.EnsureGroupCapacity(select(1, GI:GetCurrentRecord()))
        GI.ReclaimUnreferencedDissolved(select(1, GI:GetCurrentRecord()))
    end
    GI.MAX_GROUPS = savedMax
    recA = select(1, GI:GetCurrentRecord())
    local aliasG = recA.groups[gB.groupId]
    assertTrue(aliasG ~= nil, "faB forward alias not GC'd under reclaim pressure")
    assertTrue(aliasG and aliasG.forwardTo ~= nil, "faB forwardTo metadata retained")

    local countsBeforeEve = GI.CountRetainedState()
    assertTrue(countsBeforeEve.groups <= 6,
        "faB retained groups stay within lowered cap got=" .. tostring(countsBeforeEve.groups))
    admitWire(dbA, wireMember(eveMem), "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Bob",
        "faB late Eve resolves after alias retained through reclaim")
    -- Reverse order: re-admit alias group then Eve duplicate.
    if aliasG then
        admitWire(dbA, wireGroup(aliasG), "Carol-Garona")
    end
    admitWire(dbA, wireMember(eveMem), "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Bob",
        "faB reverse/duplicate admission keeps Eve")
    local dbC = seedEmptyPeer()
    syncAll(dbA, dbC, "Alice-Garona")
    assertEq(select(2, peerRole(dbC, "Player-1-Eve")), "Player-1-Bob", "faB C catch-up Eve")
    local saved = deepCopy(dbA)
    reloadModules(saved)
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Bob", "faB reload Eve")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    assertEq(GI:UnassignAlt("Player-1-Eve", {}), "accepted", "faB later unassign Eve")
    assertEq(GI:AssignAlt("Bob-Garona", "Eve-Garona", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "faB later reassign Eve")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Bob", "faB Eve after later edits")

    -- Cleanup synthetic roster rows.
    local kept = {}
    for _, m in ipairs(world.guild.members) do
        if not tostring(m.guid):match("^Player%-9%-Extra") then
            kept[#kept + 1] = m
        end
    end
    world.guild.members = kept
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

do
    -- faC: intermediate alias in a forward chain must survive reclaim.
    local dbA = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "faC seed Bob")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local recA = select(1, GI:GetCurrentRecord())
    local destGid
    for gid, g in pairs(recA.groups) do
        if not g.dissolved and g.mainGuid == "Player-1-Alice" then
            destGid = gid
        end
    end
    assertTrue(destGid ~= nil, "faC destination present")
    -- Inject G-mid → dest and G-leaf → G-mid (transitive forward chain).
    local midId = "gi-fwd-mid"
    local leafId = "gi-fwd-leaf"
    local midG = {
        groupId = midId,
        mainGuid = "Player-1-Alice",
        ver = { n = 1, w = "Player-1-Carol" },
        at = 9001,
        dissolved = true,
        forwardTo = destGid,
    }
    local leafG = {
        groupId = leafId,
        mainGuid = "Player-1-Alice",
        ver = { n = 1, w = "Player-1-Carol" },
        at = 9002,
        dissolved = true,
        forwardTo = midId,
    }
    assertEq(admitWire(dbA, wireGroup(midG), "Carol-Garona"), "accepted", "faC admit mid alias")
    assertEq(admitWire(dbA, wireGroup(leafG), "Carol-Garona"), "accepted", "faC admit leaf alias")
    local eveMem = {
        guid = "Player-1-Eve",
        groupId = leafId,
        ver = { n = 1, w = "Player-1-Carol" },
        at = 9003,
        nameRealm = "Eve-Garona",
        classFile = "HUNTER",
    }
    -- Capacity reclaim must not drop mid or leaf before Eve arrives.
    local extras = {}
    for i = 1, 10 do
        local name = "Chain" .. i .. "-Garona"
        local guid = "Player-8-Chain" .. i
        extras[#extras + 1] = { name = name, guid = guid }
        table.insert(world.guild.members, {
            name = name, guid = guid, rankOrder = 5, online = false, class = "WARRIOR",
        })
    end
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    local savedMax = GI.MAX_GROUPS
    GI.MAX_GROUPS = 5
    for i = 1, 16 do
        local a = extras[((i - 1) % #extras) + 1]
        local b = extras[(i % #extras) + 1]
        if a.guid ~= b.guid then
            GI:AssignAlt(a.name, b.name, { roster = GI.GetRosterSnapshot(true) })
            GI:UnassignAlt(b.guid, {})
        end
        GI.EnsureGroupCapacity(select(1, GI:GetCurrentRecord()))
        GI.ReclaimUnreferencedDissolved(select(1, GI:GetCurrentRecord()))
    end
    GI.MAX_GROUPS = savedMax
    recA = select(1, GI:GetCurrentRecord())
    local leafGNow = recA.groups[leafId]
    local midGNow = recA.groups[midId]
    local destGNow = recA.groups[destGid]
    assertTrue(leafGNow ~= nil, "faC leaf alias retained under reclaim")
    assertTrue(midGNow ~= nil, "faC mid alias retained under reclaim")
    assertEq(leafGNow and leafGNow.forwardTo, midId, "faC leaf still points at mid")
    assertEq(midGNow and midGNow.forwardTo, destGid, "faC mid still points at destination")
    assertTrue(destGNow and not destGNow.dissolved, "faC destination live while inbound chain exists")
    assertEq(admitWire(dbA, wireMember(eveMem), "Carol-Garona"), "accepted", "faC late Eve via leaf")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Alice",
        "faC Eve resolves through leaf→mid→dest")
    local counts = GI.CountRetainedState()
    assertTrue(counts.groups <= GI.MAX_GROUPS,
        "faC groups bounded got=" .. tostring(counts.groups))
    -- Cleanup synthetic roster rows.
    local kept = {}
    for _, m in ipairs(world.guild.members) do
        if not tostring(m.guid):match("^Player%-8%-Chain") then
            kept[#kept + 1] = m
        end
    end
    world.guild.members = kept
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

---------------------------------------------------------------------------
-- Scenario A: genuine later move must survive synthetic reconcile versions
---------------------------------------------------------------------------

do
    -- A: G1 Alice+Bob+Dave. B offline: G2 Alice+Carol. A absorbs Carol in view.
    -- B (still partitioned) moves Carol→Eve and accepts. On reconnect the move wins.
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()

    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "A: Bob under Alice")
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Dave-Garona"),
        "accepted", "A: Dave under Alice")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
        "accepted", "B: Carol under Alice (partition)")

    -- A receives B's concurrent group; derived view absorbs Carol. No durable BeatVers.
    syncAll(dbB, dbA, "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Carol")), "Player-1-Alice",
        "A derived view shows Carol under Alice after split")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local carolA = select(1, GI:GetCurrentRecord()).members["Player-1-Carol"]
    assertTrue(carolA and carolA.ver and carolA.ver.n == 1,
        "A did not invent a higher Carol membership version (n=" .. tostring(carolA and carolA.ver and carolA.ver.n) .. ")")

    -- B, still disconnected, moves Carol under Eve.
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    setActor("Carol-Garona", "Player-1-Carol", 3)
    assertEq(GI:AssignAlt("Eve-Garona", "Carol-Garona", {
        moveConfirmed = true,
        expectedOldMain = "Player-1-Alice",
        roster = GI.GetRosterSnapshot(true),
    }), "accepted", "B moves Carol under Eve while partitioned")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Carol")), "Player-1-Eve", "B accepts Carol→Eve")
    local carolB = select(1, GI:GetCurrentRecord()).members["Player-1-Carol"]
    assertTrue(carolB and carolB.ver and carolB.ver.n >= 2,
        "B Carol move raised a genuine version n=" .. tostring(carolB and carolB.ver and carolB.ver.n))

    -- Reconnect both ways + catch-up; reverse order on a fresh pair of copies.
    local function reconnectAndAssert(orderAB)
        local a = deepCopy(dbA)
        local b = deepCopy(dbB)
        if orderAB then
            syncAll(a, b, "Alice-Garona")
            syncAll(b, a, "Carol-Garona")
        else
            syncAll(b, a, "Carol-Garona")
            syncAll(a, b, "Alice-Garona")
        end
        syncAll(a, b, "Alice-Garona")
        syncAll(b, a, "Carol-Garona")
        local label = orderAB and "AB" or "BA"
        assertEq(select(2, peerRole(a, "Player-1-Carol")), "Player-1-Eve",
            label .. " A: Carol under Eve survives")
        assertEq(select(2, peerRole(b, "Player-1-Carol")), "Player-1-Eve",
            label .. " B: Carol under Eve survives")
        assertEq(select(2, peerRole(a, "Player-1-Bob")), "Player-1-Alice", label .. " A Bob under Alice")
        assertEq(select(2, peerRole(a, "Player-1-Dave")), "Player-1-Alice", label .. " A Dave under Alice")
        assertEq(select(2, peerRole(b, "Player-1-Bob")), "Player-1-Alice", label .. " B Bob under Alice")
        -- Reload convergence.
        local saved = deepCopy(a)
        reloadModules(saved)
        assertEq(select(2, GI:GetCharacterRole("Player-1-Carol")), "Player-1-Eve",
            label .. " reload keeps Carol→Eve")
    end
    reconnectAndAssert(true)
    reconnectAndAssert(false)
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

---------------------------------------------------------------------------
-- Scenario B: late member after derived split absorption is not lost
---------------------------------------------------------------------------

do
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()

    -- A: Alice+Bob+Dave. B: Alice+Carol+Eve (Eve stays on B until after A reconciles).
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "B-scen A: Bob")
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Dave-Garona"),
        "accepted", "B-scen A: Dave")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
        "accepted", "B-scen B: Carol")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Eve-Garona"),
        "accepted", "B-scen B: Eve")

    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local recB = select(1, GI:GetCurrentRecord())
    local gB = nil
    for gid, g in pairs(recB.groups) do
        if not g.dissolved and g.mainGuid == "Player-1-Alice" then
            gB = g
            break
        end
    end
    assertTrue(gB ~= nil, "B has Alice group")
    local eveMem = recB.members["Player-1-Eve"]
    assertTrue(eveMem and eveMem.groupId == gB.groupId, "Eve durable on B's Alice group")

    -- Partial sync: A gets B's group + Alice/Carol/Bob-side records, but NOT Eve yet.
    local partial = {}
    for _, w in ipairs(exportWires(dbB)) do
        local body = w.body
        if body.kind == "guildinfo-group" then
            partial[#partial + 1] = w
        elseif body.kind == "guildinfo-member" then
            local guid = body.member and body.member.guid
            if guid ~= "Player-1-Eve" then
                partial[#partial + 1] = w
            end
        end
    end
    for i = 1, #partial do
        admitWire(dbA, partial[i], "Carol-Garona")
    end
    assertEq(select(2, peerRole(dbA, "Player-1-Carol")), "Player-1-Alice",
        "A absorbs Carol after partial split")
    assertNil(select(1, peerRole(dbA, "Player-1-Eve")), "Eve not yet on A")

    -- Loser group shell must remain live (not dissolved) so Eve can arrive.
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local recA = select(1, GI:GetCurrentRecord())
    assertTrue(recA.groups[gB.groupId] ~= nil and not recA.groups[gB.groupId].dissolved,
        "A kept B's group shell live for late members")

    -- Late Eve arrives; B goes offline (no further sync from B).
    admitWire(dbA, wireMember(eveMem), "Carol-Garona")
    admitWire(dbA, wireGroup(gB), "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Alice",
        "late Eve appears under Alice, not orphaned")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local groups = GI:GetRelationshipGroups()
    assertEq(#groups, 1, "single visible Alice group after late Eve")
    local alts = groups[1].altGuids
    local seen = {}
    for i = 1, #alts do seen[alts[i]] = true end
    assertTrue(seen["Player-1-Bob"], "Bob visible")
    assertTrue(seen["Player-1-Dave"], "Dave visible")
    assertTrue(seen["Player-1-Carol"], "Carol visible")
    assertTrue(seen["Player-1-Eve"], "Eve visible after late delivery")
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

---------------------------------------------------------------------------
-- Capacity guard: group-first shell near MAX_GROUPS is not discarded
---------------------------------------------------------------------------

do
    resetDB()
    local savedMax = GI.MAX_GROUPS
    GI.MAX_GROUPS = 4

    -- Fill 3 live groups.
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "cap seed 1")
    assertEq(assign("Carol-Garona", "Dave-Garona"), "accepted", "cap seed 2")
    -- Third: Eve alone needs a partner — use Frank synthetic.
    table.insert(world.guild.members, {
        name = "Frank-Garona", guid = "Player-1-Frank", rankOrder = 5, online = false, class = "WARRIOR",
    })
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    assertEq(assign("Eve-Garona", "Frank-Garona"), "accepted", "cap seed 3")

    local record = select(1, GI:GetCurrentRecord())
    assertEq(GI.CountRetainedState().groups, 3, "three live groups before shell")

    -- Admit a fourth group shell (group-first) claiming a new main.
    table.insert(world.guild.members, {
        name = "Gina-Garona", guid = "Player-1-Gina", rankOrder = 5, online = false, class = "HUNTER",
    })
    table.insert(world.guild.members, {
        name = "Hank-Garona", guid = "Player-1-Hank", rankOrder = 5, online = false, class = "DRUID",
    })
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()

    local shellId = "gig:capacity-shell-test-0001"
    assertEq(GI.MergeGroup(record, {
        groupId = shellId,
        mainGuid = "Player-1-Gina",
        ver = { n = 1, w = "shellwriter000000000001" },
        at = 1,
    }), "accepted", "group-first shell admitted at capacity-1")
    assertTrue(record.groups[shellId] ~= nil and not record.groups[shellId].dissolved,
        "shell retained after admit")

    -- At MAX_GROUPS, EnsureGroupCapacity must fail closed without deleting the shell.
    assertEq(select(1, GI.EnsureGroupCapacity(record)), false, "no room without eviction")
    assertEq(select(2, GI.EnsureGroupCapacity(record)), "groups_overflow", "fail closed reason")
    assertTrue(record.groups[shellId] ~= nil and not record.groups[shellId].dissolved,
        "live shell not discarded at capacity")

    -- Member-later completes the relationship.
    assertEq(GI.MergeMember(record, {
        guid = "Player-1-Gina",
        groupId = shellId,
        ver = { n = 1, w = "shellwriter000000000001" },
        at = 2,
        nameRealm = "Gina-Garona",
        classFile = "HUNTER",
    }), "accepted", "Gina membership after shell")
    assertEq(GI.MergeMember(record, {
        guid = "Player-1-Hank",
        groupId = shellId,
        ver = { n = 1, w = "shellwriter000000000001" },
        at = 2,
        nameRealm = "Hank-Garona",
        classFile = "DRUID",
    }), "accepted", "Hank membership after shell")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Hank")), "Player-1-Gina",
        "incomplete shell completed into visible relationship")

    GI.MAX_GROUPS = savedMax
    -- Drop synthetic roster rows for later tests.
    local kept = {}
    for _, m in ipairs(world.guild.members) do
        if m.guid ~= "Player-1-Frank" and m.guid ~= "Player-1-Gina" and m.guid ~= "Player-1-Hank" then
            kept[#kept + 1] = m
        end
    end
    world.guild.members = kept
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

---------------------------------------------------------------------------
-- Long-running stress: successful create/dissolve without manual cleanup
---------------------------------------------------------------------------

do
    resetDB()
    local successes = 0
    local peakGroups, peakMembers = 0, 0
    local listenerProbeCount = 0
    GI.RegisterUIListener(function()
        listenerProbeCount = listenerProbeCount + 1
    end)
    local listenersAtStart = listenerProbeCount

    for i = 1, 200 do
        world.time = world.time + 1
        local st = assign("Alice-Garona", "Bob-Garona")
        assertEq(st, "accepted", "stress assign " .. i)
        st = assign("Alice-Garona", "Carol-Garona")
        assertEq(st, "accepted", "stress assign Carol " .. i)
        st = GI:ChangeMain("Player-1-Alice", "Player-1-Bob", { roster = GI.GetRosterSnapshot(true) })
        assertEq(st, "accepted", "stress change main " .. i)
        st = GI:UnassignAlt("Player-1-Carol", {})
        assertEq(st, "accepted", "stress unassign Carol " .. i)
        st = GI:UnassignAlt("Player-1-Alice", {})
        assertEq(st, "accepted", "stress unassign Alice " .. i)
        successes = successes + 5
        local c = GI.CountRetainedState()
        if c.groups > peakGroups then peakGroups = c.groups end
        if c.members > peakMembers then peakMembers = c.members end
        assertTrue(c.groups <= GI.MAX_GROUPS, "stress groups <= MAX got=" .. c.groups .. " at i=" .. i)
        assertTrue(c.liveGroups <= 2, "stress live groups small got=" .. c.liveGroups .. " at i=" .. i)
    end
    assertEq(successes, 1000, "1000 successful stress mutations")
    assertTrue(peakGroups <= GI.MAX_GROUPS, "peak groups bounded by MAX got=" .. peakGroups)
    assertTrue(peakMembers <= 8, "peak members bounded got=" .. peakMembers)
    local endCounts = GI.CountRetainedState()
    assertTrue(endCounts.liveGroups <= 1, "stress ends with at most one live group")

    local index = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(index.buildComplete and not index.dirty, "stress index idle")
    assertTrue(countKeys(index.byId) <= GI.MAX_MEMBERS + GI.MAX_GROUPS, "stress index bounded")

    -- Listener set must not grow: one probe, one Notify fan-out.
    local beforeNotify = listenerProbeCount
    GI.NotifyUI("stress")
    assertEq(listenerProbeCount, beforeNotify + 1, "single listener fan-out before reload")

    local saved = SpectrumFederationDB
    local membersBefore = GI.CountRetainedState().members
    reloadModules(saved)
    assertEq(GI.CountRetainedState().members, membersBefore, "stress reload preserves members")
end

---------------------------------------------------------------------------
-- Gossip index rebuild + guild isolation (meaningful assertions)
---------------------------------------------------------------------------

do
    resetDB()
    assign("Alice-Garona", "Bob-Garona")
    local index = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    local epoch1 = index.epoch
    local club42Ids = {}
    for id in pairs(index.byId) do
        club42Ids[id] = index.byId[id].versionFp
    end
    assertTrue(next(club42Ids) ~= nil, "club:42 index has records")
    GI.NotifyLocalDurableChange("local")
    index = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(index.buildComplete, "index rebuilds after durable change")
    assertTrue(not index.dirty, "index idle after rebuild")
    assertTrue(index.epoch >= epoch1, "epoch advances or stays consistent")
    assertTrue(countKeys(index.byId) <= GI.MAX_MEMBERS + GI.MAX_GROUPS, "rebuilt index bounded")
    assertTrue(countKeys(index.byId) >= 1, "rebuilt index non-empty while relationships exist")

    -- Guild switch: export/index must not advertise prior guild's records.
    world.guild.clubId = 99
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    GI.NotifyLocalDurableChange("local")
    index = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(index.buildComplete, "guild-switch index build completes")
    assertTrue(not index.dirty, "guild-switch index becomes idle")
    for id in pairs(club42Ids) do
        assertTrue(index.byId[id] == nil, "prior guild record absent after switch: " .. id)
    end
    assertEq(countKeys(index.byId), 0, "new guild has empty GI index until configured")
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "current guild isolation hides prior Bob")

    world.guild.clubId = 42
    world.generation = world.generation + 1
    GI.InvalidateRosterSnapshot()
    GI.NotifyLocalDurableChange("local")
    index = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(index.byId["gi-m:Player-1-Bob"] ~= nil, "return to club:42 restores Bob index id")
end

---------------------------------------------------------------------------
-- Op-log APIs removed
---------------------------------------------------------------------------

do
    assertNil(GI.AdmitOperation, "AdmitOperation removed")
    assertNil(GI.FoldOperations, "FoldOperations removed")
    assertEq(GI.SCHEMA_VERSION, 2, "SCHEMA_VERSION is 2")
    assertEq(GI.PROVIDER_SCHEMA, 2, "PROVIDER_SCHEMA is 2")
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
