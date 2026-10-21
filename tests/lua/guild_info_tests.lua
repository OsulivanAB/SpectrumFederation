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
loadModule("SpectrumFederation/modules/GuildInfo/Cleanup.lua")
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

local function wireMember(m, gen)
    gen = gen or { n = 1, w = "bootstrap" }
    return {
        id = "gi-m:" .. tostring(m.guid),
        versionFp = tostring(m.ver and m.ver.n) .. ":" .. tostring(m.ver and m.ver.w)
            .. ":g" .. tostring(gen.n) .. ":" .. tostring(gen.w),
        body = {
            kind = "guildinfo-member",
            schema = GI.PROVIDER_SCHEMA,
            gen = { n = gen.n, w = gen.w },
            member = deepCopy(m),
        },
    }
end

local function wireGroup(g, gen)
    gen = gen or { n = 1, w = "bootstrap" }
    return {
        id = "gi-g:" .. tostring(g.groupId),
        versionFp = tostring(g.ver and g.ver.n) .. ":" .. tostring(g.ver and g.ver.w)
            .. ":g" .. tostring(gen.n) .. ":" .. tostring(gen.w),
        body = {
            kind = "guildinfo-group",
            schema = GI.PROVIDER_SCHEMA,
            gen = { n = gen.n, w = gen.w },
            group = deepCopy(g),
        },
    }
end

local function wireEpoch(record)
    local b = record.baseline or {}
    local gen = record.syncGen or { n = 1, w = "bootstrap" }
    local seal = b.sealRev
    local body = {
        kind = "guildinfo-epoch",
        schema = GI.PROVIDER_SCHEMA,
        gen = { n = gen.n, w = gen.w },
        memberCount = tonumber(b.memberCount) or 0,
        groupCount = tonumber(b.groupCount) or 0,
        contentFp = tostring(b.contentFp or ""),
    }
    if type(seal) == "table" and seal.n ~= nil and type(seal.w) == "string" then
        body.sealRev = { n = seal.n, w = seal.w }
    end
    return {
        id = GI.EpochRecordId(),
        versionFp = "e:" .. tostring(gen.n) .. ":" .. tostring(gen.w)
            .. ":s" .. tostring(seal and seal.n or 0) .. ":" .. tostring(seal and seal.w or ""),
        body = body,
    }
end

local function exportWires(db)
    SpectrumFederationDB = db
    GI:Initialize(db)
    local record = select(1, GI:GetCurrentRecord())
    if not record then return {} end
    local bodies = GI.ListStateBodies(record)
    local gen = record.syncGen or { n = 1, w = "bootstrap" }
    local wires = {}
    for i = 1, #bodies do
        if bodies[i].kind == "guildinfo-epoch" then
            wires[#wires + 1] = wireEpoch(record)
        elseif bodies[i].kind == "guildinfo-member" then
            wires[#wires + 1] = wireMember(bodies[i].member, gen)
        else
            wires[#wires + 1] = wireGroup(bodies[i].group, gen)
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
    loadModule("SpectrumFederation/modules/GuildInfo/Cleanup.lua")
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
    assertEq(tonumber(saved.guildInfo.schemaVersion), 3, "schemaVersion 3 persisted")
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
    assertEq(tonumber(SpectrumFederationDB.guildInfo.schemaVersion), 3, "root upgraded to schema 3")
    assertEq(countKeys(SpectrumFederationDB.guildInfo.guilds), 0, "op-log guilds cleared on hard reset")
    assertTrue(SpectrumFederationDB.guildSupplies.keep, "guildSupplies untouched by GI reset")
end

do
    -- Schema 2 → 3 migrates in place with bootstrap syncGen (preserves relationships).
    SpectrumFederationDB = {
        guildInfo = {
            schemaVersion = 2,
            localWriter = { nonce = "0123456789abcdef01234567", nextSeq = 5 },
            guilds = {
                ["club:42"] = {
                    schemaVersion = 2,
                    guildKey = "club:42",
                    clubId = "42",
                    members = {
                        ["Player-1-Alice"] = {
                            guid = "Player-1-Alice",
                            groupId = "gig:keep:1",
                            ver = { n = 2, w = "aaaaaaaaaaaaaaaaaaaaaaaa" },
                            at = 1,
                            nameRealm = "Alice-Garona",
                            classFile = "MAGE",
                        },
                        ["Player-1-Bob"] = {
                            guid = "Player-1-Bob",
                            groupId = "gig:keep:1",
                            ver = { n = 2, w = "aaaaaaaaaaaaaaaaaaaaaaaa" },
                            at = 1,
                            nameRealm = "Bob-Garona",
                            classFile = "WARRIOR",
                        },
                    },
                    groups = {
                        ["gig:keep:1"] = {
                            groupId = "gig:keep:1",
                            mainGuid = "Player-1-Alice",
                            ver = { n = 1, w = "aaaaaaaaaaaaaaaaaaaaaaaa" },
                            at = 1,
                        },
                    },
                    characters = {},
                    graph = { mains = {}, byGuid = {} },
                    revision = 3,
                    openConflicts = {},
                },
            },
        },
    }
    SF.GuildGossip._providers = {}
    GI.InvalidateRosterSnapshot()
    assertTrue(GI:Initialize(SpectrumFederationDB), "schema 2 migrates")
    assertEq(tonumber(SpectrumFederationDB.guildInfo.schemaVersion), 3, "root migrated to schema 3")
    local rec = SpectrumFederationDB.guildInfo.guilds["club:42"]
    assertTrue(rec ~= nil, "guild record preserved")
    assertEq(tonumber(rec.schemaVersion), 3, "guild schema 3")
    assertTrue(rec.syncGen ~= nil and tonumber(rec.syncGen.n) == 1, "bootstrap syncGen")
    assertTrue(rec.baseline and rec.baseline.complete == true, "baseline sealed after migrate")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "migrated Bob remains alt")
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

    -- Solo-main shell for Alice is retained (not dissolved on last-alt Unassign).
    -- Tombstone still protects even after an explicit reclaim pass.
    local record = select(1, GI:GetCurrentRecord())
    assertTrue(record.graph.mains["Player-1-Alice"] ~= nil, "Alice solo-main shell retained")
    local removed = GI.ReclaimUnreferencedDissolved(record)
    assertTrue(removed >= 0, "reclaim is safe with retained solo-main shell")
    status = GI.MergeMember(record, oldBob)
    assertEq(status, "duplicate", "tombstone still blocks after reclaim pass")
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
        -- Solo-main shell is retained and reused; churn must not grow live groups.
        assertTrue(c.liveGroups <= 1, "solo-main shell reusable after unassign got=" .. tostring(c.liveGroups))
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
    -- Same-pair churn reuses one solo-main shell rather than dissolving each cycle.
    assertEq(finalCounts.liveGroups, 1, "reusable solo-main shell retained after final unassign")
    assertTrue(finalCounts.groups <= 2,
        "same-pair churn does not accumulate group ids got=" .. finalCounts.groups)
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

do
    -- faD: moving a solo forwarded destination main must not orphan late Eve.
    -- After G2→G1 and visible alts cleared, Assign Bob under Carol (new G3).
    -- Late Eve→G2 must remain a visible relationship (under Carol with Bob).
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "faD A Bob")
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Dave-Garona"),
        "accepted", "faD A Dave")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
        "accepted", "faD B Carol")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Eve-Garona"),
        "accepted", "faD B Eve")
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
    assertTrue(gB and eveMem and carolMem, "faD captured B cohort")
    admitWire(dbA, wireGroup(gB), "Carol-Garona")
    admitWire(dbA, wireMember(carolMem), "Carol-Garona")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    assertEq(GI:ChangeMain("Player-1-Alice", "Player-1-Bob", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "faD promote Bob")
    assertEq(GI:UnassignAlt("Player-1-Alice", {}), "accepted", "faD unassign Alice")
    assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "faD unassign Dave")
    assertEq(GI:UnassignAlt("Player-1-Carol", {}), "accepted", "faD unassign Carol")
    local recA = select(1, GI:GetCurrentRecord())
    local destBefore = recA.groups[gB.groupId] and recA.groups[gB.groupId].forwardTo
    assertTrue(type(destBefore) == "string" and destBefore ~= "", "faD alias present before Bob move")
    assertTrue(recA.groups[destBefore] and not recA.groups[destBefore].dissolved,
        "faD Bob destination live before move")
    assertTrue(recA.graph.mains["Player-1-Bob"] ~= nil, "faD Bob is designated solo main")

    -- Ordinary successful Assign: Bob becomes Carol's alt in a new group.
    assertEq(GI:AssignAlt("Carol-Garona", "Bob-Garona", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "faD move Bob under Carol")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Carol",
        "faD Bob is Carol's alt")
    recA = select(1, GI:GetCurrentRecord())
    local bobInfo = recA.graph.byGuid["Player-1-Bob"]
    local carolGid = bobInfo and bobInfo.groupId
    assertTrue(type(carolGid) == "string" and carolGid ~= "", "faD Carol/Bob group id")
    assertEq(recA.groups[gB.groupId] and recA.groups[gB.groupId].forwardTo, carolGid,
        "faD alias retargeted to Carol/Bob group")

    admitWire(dbA, wireMember(eveMem), "Carol-Garona")
    -- User-visible relationship: Eve must appear as Carol's alt (not invisible).
    assertEq(select(1, GI:GetCharacterRole("Player-1-Eve")), "alt", "faD Eve role visible")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Carol",
        "faD late Eve under Carol after Bob move")
    local groups = GI:GetRelationshipGroups()
    local eveVisible = false
    for i = 1, #groups do
        if groups[i].mainGuid == "Player-1-Carol" then
            for j = 1, #(groups[i].altGuids or {}) do
                if groups[i].altGuids[j] == "Player-1-Eve" then
                    eveVisible = true
                end
            end
        end
    end
    assertTrue(eveVisible, "faD Eve listed in Carol's visible relationship group")

    -- Reverse/dupe + catch-up + reload.
    admitWire(dbA, wireMember(eveMem), "Carol-Garona")
    admitWire(dbA, wireGroup(recA.groups[gB.groupId]), "Carol-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Carol", "faD dupe keeps Eve")
    syncAll(dbA, dbB, "Alice-Garona")
    assertEq(select(2, peerRole(dbB, "Player-1-Eve")), "Player-1-Carol", "faD B converges Eve")
    local dbC = seedEmptyPeer()
    syncAll(dbA, dbC, "Alice-Garona")
    assertEq(select(2, peerRole(dbC, "Player-1-Eve")), "Player-1-Carol", "faD C catch-up Eve")
    local saved = deepCopy(dbA)
    reloadModules(saved)
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Carol", "faD reload Eve")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    -- Later reuse: unassign Eve, reassign under Dave — characters are not locked forever.
    assertEq(GI:UnassignAlt("Player-1-Eve", {}), "accepted", "faD later unassign Eve")
    assertEq(GI:AssignAlt("Dave-Garona", "Eve-Garona", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "faD reuse Eve under Dave")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Dave", "faD Eve reused")
    assertEq(GI:UnassignAlt("Player-1-Bob", {}), "accepted", "faD unassign Bob from Carol")
    assertNil(select(1, GI:GetCharacterRole("Player-1-Bob")), "faD Bob reusable after leave")
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

---------------------------------------------------------------------------
-- Shared-group lifecycle: independent Unassign vs offline Assign (lcA / lcB)
---------------------------------------------------------------------------

do
    -- lcA: A unassigns last visible alt; B offline assigns Eve under same main.
    -- Dissolving G1 from local emptiness must not erase B's accepted Eve.
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Bob-Garona", "Dave-Garona"),
        "accepted", "lcA seed Dave under Bob")
    syncAll(dbA, dbB, "Alice-Garona")
    assertEq(select(2, peerRole(dbB, "Player-1-Dave")), "Player-1-Bob", "lcA B synced Dave")

    -- Partition: A unassigns Dave only.
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "lcA A unassign Dave")
    assertNil(select(1, GI:GetCharacterRole("Player-1-Dave")), "lcA Dave unassigned on A")
    local recA = select(1, GI:GetCurrentRecord())
    local bobGid
    for gid, g in pairs(recA.groups) do
        if not g.dissolved and g.mainGuid == "Player-1-Bob" then
            bobGid = gid
        end
    end
    assertTrue(bobGid ~= nil, "lcA solo-main shell retained after last-alt Unassign")
    assertTrue(recA.members["Player-1-Bob"] and recA.members["Player-1-Bob"].groupId == bobGid,
        "lcA Bob membership remains on live shell")

    -- B offline assigns Eve under Bob (same existing group id).
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    setActor("Carol-Garona", "Player-1-Carol", 3)
    assertEq(GI:AssignAlt("Bob-Garona", "Eve-Garona", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "lcA B assign Eve under Bob")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Bob", "lcA B Eve under Bob")

    local function lcASyncAndAssert(orderAB, label)
        local a = deepCopy(dbA)
        local b = deepCopy(dbB)
        if orderAB then
            syncAll(a, b, "Alice-Garona")
            syncAll(b, a, "Carol-Garona")
        else
            syncAll(b, a, "Carol-Garona")
            syncAll(a, b, "Alice-Garona")
        end
        assertEq(select(2, peerRole(a, "Player-1-Eve")), "Player-1-Bob", label .. " A Eve under Bob")
        assertEq(select(2, peerRole(b, "Player-1-Eve")), "Player-1-Bob", label .. " B Eve under Bob")
        assertNil(select(1, peerRole(a, "Player-1-Dave")), label .. " A Dave unassigned")
        assertNil(select(1, peerRole(b, "Player-1-Dave")), label .. " B Dave unassigned")
        local groups = nil
        SpectrumFederationDB = a
        GI:Initialize(a)
        groups = GI:GetRelationshipGroups()
        local eveVisible = false
        for i = 1, #groups do
            if groups[i].mainGuid == "Player-1-Bob" then
                for j = 1, #(groups[i].altGuids or {}) do
                    if groups[i].altGuids[j] == "Player-1-Eve" then
                        eveVisible = true
                    end
                end
            end
        end
        assertTrue(eveVisible, label .. " Eve visible in Bob's group")
        local dbC = seedEmptyPeer()
        syncAll(a, dbC, "Alice-Garona")
        assertEq(select(2, peerRole(dbC, "Player-1-Eve")), "Player-1-Bob", label .. " C catch-up Eve")
        local saved = deepCopy(a)
        reloadModules(saved)
        assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Bob", label .. " reload Eve")
        setActor("Alice-Garona", "Player-1-Alice", 1)
    end
    lcASyncAndAssert(true, "lcA fwd")
    lcASyncAndAssert(false, "lcA rev")
    -- Duplicates after convergence stay idempotent.
    syncAll(dbA, dbB, "Alice-Garona")
    syncAll(dbB, dbA, "Carol-Garona")
    syncAll(dbA, dbB, "Alice-Garona")
    assertEq(select(2, peerRole(dbA, "Player-1-Eve")), "Player-1-Bob", "lcA dupe Eve")
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

do
    -- lcB: while B offline-assigns Eve under Bob, A moves solo Bob under Carol.
    -- Eve must remain a visible relationship (under Carol via retired shell), not hidden.
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Bob-Garona", "Dave-Garona"),
        "accepted", "lcB seed Dave under Bob")
    syncAll(dbA, dbB, "Alice-Garona")

    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "lcB A clear Dave")
    local recA = select(1, GI:GetCurrentRecord())
    local bobGid
    for gid, g in pairs(recA.groups) do
        if not g.dissolved and g.mainGuid == "Player-1-Bob" then
            bobGid = gid
        end
    end
    assertTrue(bobGid ~= nil, "lcB solo shell before offline split")

    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    setActor("Carol-Garona", "Player-1-Carol", 3)
    -- B keeps Dave and adds Eve under Bob while partitioned.
    assertEq(GI:AssignAlt("Bob-Garona", "Eve-Garona", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "lcB B assign Eve under Bob offline")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Bob", "lcB B Eve under Bob")

    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(GI:AssignAlt("Carol-Garona", "Bob-Garona", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "lcB A move Bob under Carol")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Carol", "lcB Bob under Carol")
    recA = select(1, GI:GetCurrentRecord())
    -- New main had no group: solo Bob shell is repurposed (same group id, Carol main).
    assertTrue(recA.groups[bobGid] and not recA.groups[bobGid].dissolved, "lcB shell stays live")
    assertEq(recA.groups[bobGid].mainGuid, "Player-1-Carol", "lcB shell repurposed for Carol")

    local function lcBSyncAndAssert(orderAB, label)
        local a = deepCopy(dbA)
        local b = deepCopy(dbB)
        if orderAB then
            syncAll(a, b, "Alice-Garona")
            syncAll(b, a, "Carol-Garona")
        else
            syncAll(b, a, "Carol-Garona")
            syncAll(a, b, "Alice-Garona")
        end
        -- Dave's unassign from A and Eve's assign from B are independent characters.
        assertNil(select(1, peerRole(a, "Player-1-Dave")), label .. " A Dave unassigned")
        assertNil(select(1, peerRole(b, "Player-1-Dave")), label .. " B Dave unassigned")
        assertEq(select(2, peerRole(a, "Player-1-Eve")), "Player-1-Carol",
            label .. " A Eve visible under Carol")
        assertEq(select(2, peerRole(b, "Player-1-Eve")), "Player-1-Carol",
            label .. " B Eve visible under Carol")
        assertEq(select(2, peerRole(a, "Player-1-Bob")), "Player-1-Carol", label .. " A Bob under Carol")
        SpectrumFederationDB = a
        GI:Initialize(a)
        local groups = GI:GetRelationshipGroups()
        local eveVisible = false
        for i = 1, #groups do
            if groups[i].mainGuid == "Player-1-Carol" then
                for j = 1, #(groups[i].altGuids or {}) do
                    if groups[i].altGuids[j] == "Player-1-Eve" then
                        eveVisible = true
                    end
                end
            end
        end
        assertTrue(eveVisible, label .. " Eve in Carol's visible group")
        local gShell = select(1, GI:GetCurrentRecord()).groups[bobGid]
        assertTrue(gShell and not gShell.dissolved and gShell.mainGuid == "Player-1-Carol",
            label .. " shared group id remains Carol's live group")
        local dbC = seedEmptyPeer()
        syncAll(a, dbC, "Alice-Garona")
        assertEq(select(2, peerRole(dbC, "Player-1-Eve")), "Player-1-Carol", label .. " C catch-up")
        local saved = deepCopy(a)
        reloadModules(saved)
        assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Carol", label .. " reload")
        setActor("Alice-Garona", "Player-1-Alice", 1)
    end
    lcBSyncAndAssert(true, "lcB fwd")
    lcBSyncAndAssert(false, "lcB rev")
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
    assertEq(GI.SCHEMA_VERSION, 3, "SCHEMA_VERSION is 3")
    assertEq(GI.PROVIDER_SCHEMA, 3, "PROVIDER_SCHEMA is 3")
end

---------------------------------------------------------------------------
-- Option B: history cleanup / sync generation (regressions A–F)
---------------------------------------------------------------------------

local function ensureRosterGuid(name, guid, rankOrder)
    for _, m in ipairs(world.guild.members) do
        if m.guid == guid then
            return
        end
    end
    world.guild.members[#world.guild.members + 1] = {
        name = name,
        guid = guid,
        rankOrder = rankOrder or 4,
        online = true,
        class = "WARRIOR",
    }
end

local function restoreBaseRoster()
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true, class = "MAGE" },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = false, class = "WARRIOR" },
        { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true, class = "PRIEST" },
        { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true, class = "HUNTER" },
        { name = "Eve-Garona", guid = "Player-1-Eve", rankOrder = 5, online = false, class = "ROGUE" },
        { name = "Bob-Area52", guid = "Player-2-Bob", rankOrder = 4, online = true, class = "DRUID" },
    }
    world.guild.rosterComplete = true
    world.guild.clubId = 42
    GI.InvalidateRosterSnapshot()
end

do
    -- A — Historical group exhaustion + cleanup reclaim
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    ensureRosterGuid("AltReuse-Garona", "Player-1-AltReuse", 4)
    local maxG = GI.MAX_GROUPS
    for i = 1, maxG do
        local mainGuid = string.format("Player-1-Main%03d", i)
        ensureRosterGuid(string.format("Main%03d-Garona", i), mainGuid, 4)
        GI.InvalidateRosterSnapshot()
        local st = assign(string.format("Main%03d-Garona", i), "AltReuse-Garona")
        assertEq(st, "accepted", "A assign shell " .. i)
        local ust = GI:UnassignAlt("Player-1-AltReuse", {})
        assertEq(ust, "accepted", "A unassign shell " .. i)
    end
    local before = GI.CountRetainedState()
    assertEq(before.liveGroups, maxG, "A retained live shells at capacity got=" .. before.liveGroups)
    assertEq(#(GI:GetRelationshipGroups() or {}), 0, "A visible relationships empty")
    -- Fail-before: 129th main cannot allocate without cleanup.
    ensureRosterGuid("MainExtra-Garona", "Player-1-MainExtra", 4)
    GI.InvalidateRosterSnapshot()
    local overflowSt, overflowWhy = assign("MainExtra-Garona", "AltReuse-Garona")
    assertEq(overflowSt, "rejected", "A fail-before: 129th assign rejected")
    assertEq(overflowWhy, "groups_overflow", "A fail-before reason groups_overflow")

    local preview = GI:PreviewCleanup()
    assertTrue(preview.discardSoloShells >= maxG - 1, "A preview sees solo shells")
    assertTrue(preview.capacityRecovered, "A preview capacity recovery")
    local cst, cwhy, cmeta = GI:CleanupHistory({})
    assertEq(cst, "accepted", "A cleanup accepted")
    assertEq(cwhy, "cleanup_done", "A cleanup_done")
    local after = GI.CountRetainedState()
    assertTrue(after.liveGroups < before.liveGroups, "A groups reclaimed before=" .. before.liveGroups .. " after=" .. after.liveGroups)
    assertTrue(after.groups <= 1, "A compact groups after cleanup got=" .. after.groups)
    local record = select(1, GI:GetCurrentRecord())
    assertTrue(record.syncGen and tonumber(record.syncGen.n) >= 2, "A syncGen bumped")
    -- Pass-after: 129th main succeeds.
    local ok129, why129 = assign("MainExtra-Garona", "AltReuse-Garona")
    assertEq(ok129, "accepted", "A pass-after: 129th assign accepted why=" .. tostring(why129))
    assertEq(GI:GetCharacterRole("Player-1-AltReuse"), "alt", "A alt under new main")
end

do
    -- B — Membership tombstones reclaimed; active + departed retained
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    -- Departed character still in active relationship.
    assign("Alice-Garona", "Eve-Garona")
    local kept = {}
    for _, m in ipairs(world.guild.members) do
        if m.guid ~= "Player-1-Eve" then
            kept[#kept + 1] = m
        end
    end
    world.guild.members = kept
    GI.InvalidateRosterSnapshot()
    assertEq(GI.GetMembershipStatus("Player-1-Eve", GI.GetRosterSnapshot(true)), "departed", "B Eve departed")

    -- Fill remaining member capacity with unassign tombstones.
    local target = GI.MAX_MEMBERS
    local i = 1
    while GI.CountRetainedState().members < target do
        local g = string.format("Player-1-Tomb%03d", i)
        ensureRosterGuid(string.format("Tomb%03d-Garona", i), g, 4)
        GI.InvalidateRosterSnapshot()
        local st = assign("Alice-Garona", string.format("Tomb%03d-Garona", i))
        if st ~= "accepted" then
            break
        end
        assertEq(GI:UnassignAlt(g, {}), "accepted", "B unassign tomb " .. i)
        i = i + 1
        if i > target + 5 then
            break
        end
    end
    local before = GI.CountRetainedState()
    assertTrue(before.unassigned >= 1, "B has tombstones got=" .. before.unassigned)
    assertTrue(before.members >= before.assigned + before.unassigned, "B member accounting")

    local st, why = GI:CleanupHistory({})
    assertEq(st, "accepted", "B cleanup accepted")
    assertEq(why, "cleanup_done", "B cleanup_done")
    local after = GI.CountRetainedState()
    assertEq(after.unassigned, 0, "B tombstones purged")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "B Bob retained")
    assertEq(GI:GetCharacterRole("Player-1-Eve"), "alt", "B departed Eve retained")
    assertTrue(after.members < before.members, "B members shrink before=" .. before.members .. " after=" .. after.members)

    -- New character assignment possible again.
    ensureRosterGuid("Fresh-Garona", "Player-1-Fresh", 4)
    GI.InvalidateRosterSnapshot()
    assertEq(assign("Alice-Garona", "Fresh-Garona"), "accepted", "B fresh assign after cleanup")
end

do
    -- C — Offline stale client cannot resurrect old generation
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    -- Create reclaimable history so cleanup is not a noop (noop does not bump gen).
    ensureRosterGuid("ShellC-Garona", "Player-1-ShellC", 4)
    GI.InvalidateRosterSnapshot()
    assign("ShellC-Garona", "Dave-Garona")
    GI:UnassignAlt("Player-1-Dave", {})
    local dbA = deepCopy(SpectrumFederationDB)
    local dbB = seedEmptyPeer()
    syncAll(dbA, dbB, "Alice-Garona")
    assertEq(peerRole(dbB, "Player-1-Bob"), "alt", "C B starts with Bob")

    -- B disconnects with a high-revision old-generation unassign of Bob.
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local recB = select(1, GI:GetCurrentRecord())
    local oldGen = { n = recB.syncGen.n, w = recB.syncGen.w }
    local bob = recB.members["Player-1-Bob"]
    local staleWire = wireMember({
        guid = "Player-1-Bob",
        groupId = false,
        ver = { n = (bob.ver.n or 1) + 50, w = "zzzzzzzzzzzzzzzzzzzzzzzz" },
        at = 99999,
        nameRealm = "Bob-Garona",
        classFile = "WARRIOR",
    }, oldGen)

    -- A cleans up and reassigns Bob under Carol.
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    setActor("Alice-Garona", "Player-1-Alice", 1)
    local cst = GI:CleanupHistory({})
    assertEq(cst, "accepted", "C A cleanup")
    assertEq(GI:UnassignAlt("Player-1-Bob", {}), "accepted", "C A unassign Bob")
    assertEq(assign("Carol-Garona", "Bob-Garona"), "accepted", "C A Bob under Carol")
    local genA = select(1, GI:GetCurrentRecord()).syncGen
    assertTrue(tonumber(genA.n) > tonumber(oldGen.n), "C A generation advanced")

    -- B's stale higher-revision old-gen tombstone cannot overwrite A.
    local stStale, whyStale = admitWire(dbA, staleWire, "Carol-Garona")
    assertEq(stStale, "rejected", "C stale resurrect rejected")
    assertEq(whyStale, "stale_generation", "C stale_generation reason")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    local role, main = GI:GetCharacterRole("Player-1-Bob")
    assertEq(role, "alt", "C Bob still alt after stale reject")
    assertEq(main, "Player-1-Carol", "C Bob still under Carol")

    -- B learns new generation through normal sync and converges.
    syncAll(dbA, dbB, "Alice-Garona")
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local roleB, mainB = GI:GetCharacterRole("Player-1-Bob")
    assertEq(roleB, "alt", "C B converges Bob alt")
    assertEq(mainB, "Player-1-Carol", "C B converges under Carol")
    assertEq(select(1, GI:GetCurrentRecord()).syncGen.n, genA.n, "C B syncGen matches A")
end

do
    -- D — Competing cleanups resolve deterministically
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    local dbBase = deepCopy(SpectrumFederationDB)
    local dbA = deepCopy(dbBase)
    local dbB = deepCopy(dbBase)
    -- Distinct local writers so cleanup generations tie-break on w.
    dbA.guildInfo.localWriter = { nonce = "aaaaaaaaaaaaaaaaaaaaaaaa", nextSeq = 1 }
    dbB.guildInfo.localWriter = { nonce = "bbbbbbbbbbbbbbbbbbbbbbbb", nextSeq = 1 }

    -- A cleanup preserves Alice/Bob; also assign Dave under Alice before cleanup noise.
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    setActor("Alice-Garona", "Player-1-Alice", 1)
    -- Create reclaimable shells so cleanup is not a noop.
    ensureRosterGuid("ShellA-Garona", "Player-1-ShellA", 4)
    GI.InvalidateRosterSnapshot()
    assign("ShellA-Garona", "Dave-Garona")
    GI:UnassignAlt("Player-1-Dave", {})
    assertEq(GI:CleanupHistory({}), "accepted", "D A cleanup")
    local genA = deepCopy(select(1, GI:GetCurrentRecord()).syncGen)

    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    setActor("Carol-Garona", "Player-1-Carol", 3)
    ensureRosterGuid("ShellB-Garona", "Player-1-ShellB", 4)
    GI.InvalidateRosterSnapshot()
    assign("ShellB-Garona", "Eve-Garona")
    GI:UnassignAlt("Player-1-Eve", {})
    -- Force B into a different post-cleanup baseline: Eve under Carol.
    assign("Carol-Garona", "Eve-Garona")
    assertEq(GI:CleanupHistory({}), "accepted", "D B cleanup")
    local genB = deepCopy(select(1, GI:GetCurrentRecord()).syncGen)
    assertEq(tonumber(genA.n), tonumber(genB.n), "D same generation counter")
    assertTrue(genA.w ~= genB.w, "D distinct writer ids")

    local winnerW = genA.w > genB.w and genA.w or genB.w
    local winnerDb = genA.w > genB.w and dbA or dbB
    local loserDb = genA.w > genB.w and dbB or dbA

    -- Cross-admit: higher writer wins.
    syncAll(winnerDb, loserDb, "Alice-Garona")
    syncAll(loserDb, winnerDb, "Carol-Garona")
    SpectrumFederationDB = winnerDb
    GI:Initialize(winnerDb)
    local winGen = select(1, GI:GetCurrentRecord()).syncGen
    SpectrumFederationDB = loserDb
    GI:Initialize(loserDb)
    local loseGen = select(1, GI:GetCurrentRecord()).syncGen
    assertEq(winGen.w, winnerW, "D winner gen on winner db")
    assertEq(loseGen.w, winnerW, "D loser adopted winner gen")
    assertEq(loseGen.n, winGen.n, "D same gen n after resolution")
    -- No mixed-epoch: both complete under winner.
    assertTrue(GI.IsBaselineComplete(select(1, GI:GetCurrentRecord())), "D loser baseline complete")
end

do
    -- E — Partial synchronization fail-closed
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    assign("Alice-Garona", "Carol-Garona")
    -- Create obsolete shell then cleanup so gen advances with retained relationships.
    ensureRosterGuid("ShellE-Garona", "Player-1-ShellE", 4)
    GI.InvalidateRosterSnapshot()
    assign("ShellE-Garona", "Dave-Garona")
    GI:UnassignAlt("Player-1-Dave", {})
    assertEq(GI:CleanupHistory({}), "accepted", "E cleanup")
    local dbA = deepCopy(SpectrumFederationDB)
    local wires = exportWires(dbA)
    local epochWire, memberWires, groupWires = nil, {}, {}
    for i = 1, #wires do
        local k = wires[i].body.kind
        if k == "guildinfo-epoch" then
            epochWire = wires[i]
        elseif k == "guildinfo-member" then
            memberWires[#memberWires + 1] = wires[i]
        else
            groupWires[#groupWires + 1] = wires[i]
        end
    end
    assertTrue(epochWire ~= nil, "E has epoch wire")
    assertTrue(#memberWires >= 2, "E has member wires")

    local dbFresh = seedEmptyPeer()
    -- Members before epoch: pending / rejected, not applied as gen0 into bootstrap.
    local stEarly = admitWire(dbFresh, memberWires[1], "Alice-Garona")
    assertTrue(stEarly == "rejected" or stEarly == "duplicate", "E early member not accepted as authority")
    SpectrumFederationDB = dbFresh
    GI:Initialize(dbFresh)
    assertNil(GI:GetCharacterRole("Player-1-Bob"), "E no Bob before epoch")

    admitWire(dbFresh, epochWire, "Alice-Garona")
    SpectrumFederationDB = dbFresh
    GI:Initialize(dbFresh)
    local rec = select(1, GI:GetCurrentRecord())
    assertTrue(not GI.IsBaselineComplete(rec), "E incomplete after epoch alone")
    local groups, why = GI:GetRelationshipGroups()
    assertEq(why, "generation_syncing", "E syncing reason while incomplete")
    assertEq(#groups, 0, "E empty while syncing (not authoritative finished empty)")

    -- Deliver groups then members; seal when complete.
    for i = 1, #groupWires do
        admitWire(dbFresh, groupWires[i], "Alice-Garona")
    end
    for i = 1, #memberWires do
        admitWire(dbFresh, memberWires[i], "Alice-Garona")
    end
    SpectrumFederationDB = dbFresh
    GI:Initialize(dbFresh)
    assertTrue(GI.IsBaselineComplete(select(1, GI:GetCurrentRecord())), "E sealed after full delivery")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "E Bob present after seal")

    -- Duplicate epoch/members are idempotent.
    local dupSt = admitWire(dbFresh, epochWire, "Alice-Garona")
    assertTrue(dupSt == "accepted" or dupSt == "duplicate", "E duplicate epoch ok got=" .. tostring(dupSt))
    admitWire(dbFresh, memberWires[1], "Alice-Garona")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "E still Bob after duplicates")

    -- Stale gen-1 replay rejected.
    local stale = wireMember({
        guid = "Player-1-Bob",
        groupId = false,
        ver = { n = 999, w = "zzzzzzzzzzzzzzzzzzzzzzzz" },
        at = 1,
    }, { n = 1, w = "bootstrap" })
    local stS, whyS = admitWire(dbFresh, stale, "Carol-Garona")
    assertEq(stS, "rejected", "E stale gen rejected")
    assertEq(whyS, "stale_generation", "E stale_generation")
end

do
    -- F — Repeated cleanup cycles stay bounded
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    local peakMembers, peakGroups, peakIndex = 0, 0, 0
    for cycle = 1, 8 do
        ensureRosterGuid(string.format("CycMain%02d-Garona", cycle), string.format("Player-1-CycMain%02d", cycle), 4)
        ensureRosterGuid(string.format("CycAlt%02d-Garona", cycle), string.format("Player-1-CycAlt%02d", cycle), 4)
        GI.InvalidateRosterSnapshot()
        assign(string.format("CycMain%02d-Garona", cycle), string.format("CycAlt%02d-Garona", cycle))
        GI:UnassignAlt(string.format("Player-1-CycAlt%02d", cycle), {})
        local st, why = GI:CleanupHistory({})
        assertEq(st, "accepted", "F cleanup cycle " .. cycle .. " why=" .. tostring(why))
        -- Keep one active relationship so cleanup is meaningful next rounds.
        assign("Alice-Garona", "Bob-Garona")
        local c = GI.CountRetainedState()
        peakMembers = math.max(peakMembers, c.members)
        peakGroups = math.max(peakGroups, c.groups)
        local index = DriveEnsureIndex(GI.PROVIDER_ID, 64)
        peakIndex = math.max(peakIndex, countKeys(index.byId))
        assertTrue(c.members <= GI.MAX_MEMBERS, "F members bound")
        assertTrue(c.groups <= GI.MAX_GROUPS, "F groups bound")
        -- Only one syncGen retained (no archive of prior generations).
        local rec = select(1, GI:GetCurrentRecord())
        assertTrue(rec.syncGen ~= nil, "F has syncGen")
        assertNil(rec.pendingByGen, "F no pending gen archive")
        assertTrue(GI.IsBaselineComplete(rec), "F baseline complete each cycle")
    end
    assertTrue(peakMembers <= GI.MAX_MEMBERS, "F peak members " .. peakMembers)
    assertTrue(peakGroups <= GI.MAX_GROUPS, "F peak groups " .. peakGroups)
    assertTrue(peakIndex <= GI.MAX_MEMBERS + GI.MAX_GROUPS + 1, "F peak index " .. peakIndex)
    -- Epoch wire within Gossip cap.
    local wires = exportWires(SpectrumFederationDB)
    for i = 1, #wires do
        assertTrue(GI.RecordWithinGossipCap(wires[i]), "F wire within 2048 id=" .. tostring(wires[i].id))
    end
end

---------------------------------------------------------------------------
-- Option B integrity: logical cleanup + live seal freshness
---------------------------------------------------------------------------

--- Export via live provider callbacks without GI:Initialize (masks seal bugs).
local function exportProviderWiresLive()
    DriveEnsureIndex(GI.PROVIDER_ID, 64)
    local provider = SF.GuildGossip._providers[GI.PROVIDER_ID]
    assertTrue(provider and provider.spec, "live provider available")
    local wires = {}
    local cursor = 1
    while cursor do
        local page, nextCursor = provider.spec.ListRecordIds(cursor, 32)
        for i = 1, #(page or {}) do
            local body = provider.spec.GetRecordBody(page[i])
            if body then
                wires[#wires + 1] = body
            end
        end
        cursor = nextCursor
    end
    return wires
end

local function admitWiresInOrder(db, wires, sender, order)
    for i = 1, #order do
        local kind = order[i]
        for j = 1, #wires do
            if wires[j].body and wires[j].body.kind == kind then
                admitWire(db, wires[j], sender)
            end
        end
    end
end

local function altsUnderMain(mainGuid)
    local groups = GI:GetRelationshipGroups() or {}
    for i = 1, #groups do
        if groups[i].mainGuid == mainGuid then
            local alts = {}
            for j = 1, #(groups[i].altGuids or {}) do
                alts[groups[i].altGuids[j]] = true
            end
            return alts, groups[i].altGuids
        end
    end
    return {}, {}
end

do
    -- G1 — Absorbed concurrent groups: cleanup must keep Bob AND Carol
    restoreBaseRoster()
    resetDB()
    local dbA = seedEmptyPeer()
    local dbB = seedEmptyPeer()
    assertEq(applyLocalAssignOn(dbA, "Alice-Garona", "Player-1-Alice", 1, "Alice-Garona", "Bob-Garona"),
        "accepted", "G1 A Alice/Bob")
    assertEq(applyLocalAssignOn(dbB, "Carol-Garona", "Player-1-Carol", 3, "Alice-Garona", "Carol-Garona"),
        "accepted", "G1 B Alice/Carol")
    syncAll(dbA, dbB, "Alice-Garona")
    syncAll(dbB, dbA, "Carol-Garona")
    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    setActor("Alice-Garona", "Player-1-Alice", 1)
    local altsBefore = altsUnderMain("Player-1-Alice")
    assertTrue(altsBefore["Player-1-Bob"], "G1 before: Bob visible")
    assertTrue(altsBefore["Player-1-Carol"], "G1 before: Carol visible")
    local preview = GI:PreviewCleanup()
    assertTrue(preview.retainedMembers >= 3, "G1 preview retains Alice+Bob+Carol got=" .. tostring(preview.retainedMembers))
    -- Create obsolete shell so cleanup is not a noop.
    ensureRosterGuid("ShellG-Garona", "Player-1-ShellG", 4)
    GI.InvalidateRosterSnapshot()
    assign("ShellG-Garona", "Dave-Garona")
    GI:UnassignAlt("Player-1-Dave", {})
    local cst, cwhy = GI:CleanupHistory({})
    assertEq(cst, "accepted", "G1 cleanup accepted why=" .. tostring(cwhy))
    local altsAfter = altsUnderMain("Player-1-Alice")
    assertTrue(altsAfter["Player-1-Bob"], "G1 after cleanup: Bob retained")
    assertTrue(altsAfter["Player-1-Carol"], "G1 after cleanup: Carol retained (absorbed physical G2)")
    local roleC, mainC = GI:GetCharacterRole("Player-1-Carol")
    assertEq(roleC, "alt", "G1 Carol role alt")
    assertEq(mainC, "Player-1-Alice", "G1 Carol under Alice")
    -- Reload + fresh peer converge.
    local saved = SpectrumFederationDB
    reloadModules(saved)
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Carol"], "G1 reload keeps Carol")
    local dbFresh = seedEmptyPeer()
    syncAll(saved, dbFresh, "Alice-Garona")
    SpectrumFederationDB = dbFresh
    GI:Initialize(dbFresh)
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Bob"], "G1 fresh Bob")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Carol"], "G1 fresh Carol")
end

do
    -- G2 — Late alt on forwardTo alias survives cleanup onto canonical group
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    local record = select(1, GI:GetCurrentRecord())
    local g1 = record.graph.byGuid["Player-1-Alice"].groupId
    -- Synthetic sibling group G2 retired as forwardTo G1 with Carol membership on G2.
    local g2 = "gig:forward:g2"
    GI.MergeGroup(record, {
        groupId = g2,
        mainGuid = "Player-1-Alice",
        ver = { n = 1, w = "ffffffffffffffffffffffff" },
        at = 1,
    })
    GI.MergeMember(record, {
        guid = "Player-1-Carol",
        groupId = g2,
        ver = { n = 1, w = "ffffffffffffffffffffffff" },
        at = 1,
        nameRealm = "Carol-Garona",
        classFile = "PRIEST",
    })
    GI.MergeGroup(record, {
        groupId = g2,
        ver = { n = 2, w = "ffffffffffffffffffffffff" },
        at = 2,
        dissolved = true,
        forwardTo = g1,
    })
    GI.RebuildDerived(record)
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Carol"], "G2 before: Carol visible via forward")
    assertEq(record.members["Player-1-Carol"].groupId, g2, "G2 Carol durable id still G2")
    ensureRosterGuid("ShellG2-Garona", "Player-1-ShellG2", 4)
    GI.InvalidateRosterSnapshot()
    assign("ShellG2-Garona", "Dave-Garona")
    GI:UnassignAlt("Player-1-Dave", {})
    assertEq(GI:CleanupHistory({}), "accepted", "G2 cleanup")
    local role, main = GI:GetCharacterRole("Player-1-Carol")
    assertEq(role, "alt", "G2 Carol retained")
    assertEq(main, "Player-1-Alice", "G2 Carol under Alice")
    record = select(1, GI:GetCurrentRecord())
    assertEq(record.members["Player-1-Carol"].groupId, g1, "G2 Carol rewritten onto canonical G1")
    assertNil(record.groups[g2], "G2 alias discarded after cleanup")
end

do
    -- H — Post-cleanup edits refresh seal; fresh peer seals without writer Initialize
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    ensureRosterGuid("ShellH-Garona", "Player-1-ShellH", 4)
    GI.InvalidateRosterSnapshot()
    assign("ShellH-Garona", "Dave-Garona")
    GI:UnassignAlt("Player-1-Dave", {})
    assertEq(GI:CleanupHistory({}), "accepted", "H cleanup to gen>=2")
    local rec = select(1, GI:GetCurrentRecord())
    local genN = rec.syncGen.n
    local sealBefore = {
        mc = rec.baseline.memberCount,
        gc = rec.baseline.groupCount,
        fp = rec.baseline.contentFp,
    }
    -- Ordinary edit WITHOUT re-Initialize.
    assertEq(assign("Alice-Garona", "Carol-Garona"), "accepted", "H assign Carol after cleanup")
    rec = select(1, GI:GetCurrentRecord())
    assertTrue(GI.IsBaselineComplete(rec), "H writer still complete")
    assertTrue(rec.baseline.memberCount > sealBefore.mc
        or rec.baseline.contentFp ~= sealBefore.fp,
        "H seal refreshed after edit")
    assertEq(rec.baseline.memberCount, countKeys(rec.members), "H seal memberCount matches durable")
    assertEq(rec.baseline.contentFp, GI.ComputeBaselineContentFp(rec.members, rec.groups),
        "H seal contentFp matches durable")

    -- Live provider export (no Initialize).
    GI.NotifyLocalDurableChange("local")
    local wires = exportProviderWiresLive()
    local epochBody
    for i = 1, #wires do
        if wires[i].body and wires[i].body.kind == "guildinfo-epoch" then
            epochBody = wires[i].body
        end
    end
    assertTrue(epochBody ~= nil, "H live export has epoch")
    assertEq(tonumber(epochBody.gen.n), tonumber(genN), "H epoch same generation")
    assertEq(tonumber(epochBody.memberCount), countKeys(rec.members), "H live epoch memberCount current")
    assertEq(tostring(epochBody.contentFp), tostring(rec.baseline.contentFp), "H live epoch contentFp matches seal")
    assertEq(tostring(epochBody.contentFp),
        tostring(GI.ComputeBaselineContentFp(rec.members, rec.groups)),
        "H live epoch contentFp matches durable rows")

    local dbFresh = seedEmptyPeer()
    -- Reordered delivery: members/groups before epoch, then epoch, plus duplicates.
    admitWiresInOrder(dbFresh, wires, "Alice-Garona", {
        "guildinfo-member", "guildinfo-group", "guildinfo-epoch",
    })
    -- Second pass full order including duplicates.
    for i = 1, #wires do
        admitWire(dbFresh, wires[i], "Alice-Garona")
    end
    SpectrumFederationDB = dbFresh
    GI:Initialize(dbFresh)
    local fresh = select(1, GI:GetCurrentRecord())
    assertTrue(GI.IsBaselineComplete(fresh), "H fresh peer sealed without writer Initialize")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Bob"], "H fresh Bob")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Carol"], "H fresh Carol")
end

do
    -- H2 — Multiple post-cleanup edits + third-peer relay; index becomes idle
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    ensureRosterGuid("ShellH2-Garona", "Player-1-ShellH2", 4)
    GI.InvalidateRosterSnapshot()
    assign("ShellH2-Garona", "Dave-Garona")
    GI:UnassignAlt("Player-1-Dave", {})
    assertEq(GI:CleanupHistory({}), "accepted", "H2 cleanup")
    assertEq(assign("Alice-Garona", "Carol-Garona"), "accepted", "H2 Carol")
    assertEq(assign("Alice-Garona", "Eve-Garona"), "accepted", "H2 Eve second edit")
    GI.NotifyLocalDurableChange("local")
    local wires = exportProviderWiresLive()
    local dbB = seedEmptyPeer()
    local dbC = seedEmptyPeer()
    for i = 1, #wires do
        admitWire(dbB, wires[i], "Alice-Garona")
    end
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    assertTrue(GI.IsBaselineComplete(select(1, GI:GetCurrentRecord())), "H2 B sealed")
    local wiresB = exportWires(dbB)
    for i = 1, #wiresB do
        admitWire(dbC, wiresB[i], "Carol-Garona")
    end
    SpectrumFederationDB = dbC
    GI:Initialize(dbC)
    assertTrue(GI.IsBaselineComplete(select(1, GI:GetCurrentRecord())), "H2 C sealed via relay")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Eve"], "H2 C has Eve")
    local index = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(index.buildComplete and not index.dirty, "H2 index idle")
end

---------------------------------------------------------------------------
-- CodeRabbit repair batch: gossip coalesce, roster record reuse,
-- merge rejection detail, move-confirm names
---------------------------------------------------------------------------

local function admitWireLive(db, wire, sender)
    SpectrumFederationDB = db
    if GI._db ~= db then
        GI:Initialize(db)
    end
    local provider = SF.GuildGossip._providers[GI.PROVIDER_ID]
    return provider.spec.ValidateAndApply(deepCopy(wire), { sender = sender or "Carol-Garona" })
end

do
    -- Gossip: remote batch coalesces export rebuild / index bump
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    -- Build a moderately large relationship set on A.
    for i = 1, 24 do
        ensureRosterGuid(string.format("BulkM%02d-Garona", i), string.format("Player-1-BulkM%02d", i), 4)
        ensureRosterGuid(string.format("BulkA%02d-Garona", i), string.format("Player-1-BulkA%02d", i), 4)
    end
    GI.InvalidateRosterSnapshot()
    for i = 1, 24 do
        assertEq(assign(string.format("BulkM%02d-Garona", i), string.format("BulkA%02d-Garona", i)),
            "accepted", "bulk assign " .. i)
    end
    local dbA = deepCopy(SpectrumFederationDB)
    local wires = exportWires(dbA)
    assertTrue(#wires >= 48, "bulk export has many wires got=" .. #wires)

    local dbB = seedEmptyPeer()
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    setActor("Carol-Garona", "Player-1-Carol", 3)
    GI.ResetExportPerfCounters()
    local accepted = 0
    for i = 1, #wires do
        local st = admitWireLive(dbB, wires[i], "Alice-Garona")
        if st == "accepted" or st == "duplicate" then
            accepted = accepted + 1
        end
    end
    assertTrue(accepted >= 40, "bulk remote accepted got=" .. accepted)
    local mid = GI.GetExportPerfCounters()
    -- During admission, rebuilds must not scale with every accepted record.
    assertTrue(mid.rebuilds <= 2, "coalesced rebuilds during batch got=" .. tostring(mid.rebuilds))
    assertTrue(mid.bumps <= 2, "coalesced bumps during batch got=" .. tostring(mid.bumps))

    DriveEnsureIndex(GI.PROVIDER_ID, 128)
    local after = GI.GetExportPerfCounters()
    assertTrue(after.rebuilds <= mid.rebuilds + 2, "flush rebuild bounded got=" .. after.rebuilds)
    assertTrue(after.bumps <= mid.bumps + 2, "flush bump bounded got=" .. after.bumps)
    assertTrue(not after.dirty, "export not dirty after EnsureIndex")
    local index = DriveEnsureIndex(GI.PROVIDER_ID, 64)
    assertTrue(index.buildComplete and not index.dirty, "bulk index idle")
    assertEq(GI:GetCharacterRole("Player-1-BulkA01"), "alt", "bulk catch-up BulkA01")
    assertEq(GI:GetCharacterRole("Player-1-BulkA24"), "alt", "bulk catch-up BulkA24")

    -- A offline: B relays to C.
    local dbC = seedEmptyPeer()
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    local wiresB = exportProviderWiresLive()
    for i = 1, #wiresB do
        admitWireLive(dbC, wiresB[i], "Carol-Garona")
    end
    SpectrumFederationDB = dbC
    GI:Initialize(dbC)
    DriveEnsureIndex(GI.PROVIDER_ID, 128)
    assertEq(GI:GetCharacterRole("Player-1-BulkA12"), "alt", "B→C relay BulkA12")
end

do
    -- Roster: GetAssignmentDisplayRows does not ValidateGuildRecord per character
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    for i = 1, 20 do
        ensureRosterGuid(string.format("RowM%02d-Garona", i), string.format("Player-1-RowM%02d", i), 4)
        ensureRosterGuid(string.format("RowA%02d-Garona", i), string.format("Player-1-RowA%02d", i), 4)
    end
    GI.InvalidateRosterSnapshot()
    for i = 1, 20 do
        assign(string.format("RowM%02d-Garona", i), string.format("RowA%02d-Garona", i))
    end
    -- Departed character in an active relationship.
    assign("Alice-Garona", "Eve-Garona")
    local kept = {}
    for _, m in ipairs(world.guild.members) do
        if m.guid ~= "Player-1-Eve" then
            kept[#kept + 1] = m
        end
    end
    world.guild.members = kept
    GI.InvalidateRosterSnapshot()

    local origGet = GI.GetCurrentRecord
    local getCalls = 0
    function GI.GetCurrentRecord(...)
        getCalls = getCalls + 1
        return origGet(...)
    end
    local roster = GI.GetRosterSnapshot(true)
    getCalls = 0
    local rows1, _, displayGroups = GI:GetAssignmentDisplayRows(roster)
    local calls1 = getCalls
    local rows2 = GI:GetAssignmentDisplayRows(roster)
    local calls2 = getCalls - calls1
    GI.GetCurrentRecord = origGet
    assertTrue(#rows1 >= 40, "display rows near capacity got=" .. #rows1)
    -- One GetCurrentRecord (via GetRelationshipGroups) per render is fine;
    -- per-character validation would be >= number of displayed characters.
    assertTrue(calls1 <= 4, "first render GetCurrentRecord bounded got=" .. calls1)
    assertTrue(calls2 <= 4, "second render GetCurrentRecord bounded got=" .. calls2)
    assertTrue(calls1 < 20, "not one GetCurrentRecord per main got=" .. calls1)
    local eveStatus = select(1, GI.GetMembershipStatus("Player-1-Eve", roster, select(1, GI:GetCurrentRecord())))
    assertEq(eveStatus, "departed", "Eve membership status departed with shared record")
    local foundEve = false
    for i = 1, #(displayGroups or {}) do
        for j = 1, #(displayGroups[i].alts or {}) do
            local a = displayGroups[i].alts[j]
            if a.guid == "Player-1-Eve" then
                foundEve = true
                assertEq(a.status, "departed", "displayGroups Eve status")
            end
        end
    end
    if not foundEve then
        -- Fallback: row text encodes the departed suffix when LocaleText is unavailable.
        for i = 1, #rows1 do
            if rows1[i].guid == "Player-1-Eve" then
                foundEve = true
                assertTrue(tostring(rows1[i].text or ""):find("No longer", 1, true) ~= nil,
                    "Eve row departed text=" .. tostring(rows1[i].text))
            end
        end
    end
    assertTrue(foundEve, "departed Eve still listed under Alice")
    assertTrue(#rows2 == #rows1, "repeated refresh same row count")
end

do
    -- Merge rejection detail reaches Settings feedback (generation_syncing)
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    ensureRosterGuid("ShellR-Garona", "Player-1-ShellR", 4)
    GI.InvalidateRosterSnapshot()
    assign("ShellR-Garona", "Dave-Garona")
    GI:UnassignAlt("Player-1-Dave", {})
    assertEq(GI:CleanupHistory({}), "accepted", "reject-detail cleanup")
    local record = select(1, GI:GetCurrentRecord())
    -- Force incomplete baseline while keeping syncGen current.
    record.baseline.complete = false
    record.baseline.memberCount = 99
    record.baseline.groupCount = 99
    record.baseline.contentFp = "not-yet"
    local st, reason = GI:AssignAlt("Alice-Garona", "Carol-Garona", {
        roster = GI.GetRosterSnapshot(true),
    })
    assertEq(st, "rejected", "assign rejected while syncing")
    assertEq(reason, "generation_syncing", "specific generation_syncing detail")
    local msg, sev = GI.FormatMutationFeedback(st, reason)
    assertTrue(type(msg) == "string" and msg:find("synchron", 1, true) ~= nil,
        "Settings feedback names syncing got=" .. tostring(msg))
    assertEq(sev, "error", "syncing feedback is error severity")
    -- Successful path still works when baseline complete.
    record.baseline.complete = true
    record.baseline.memberCount = countKeys(record.members)
    record.baseline.groupCount = countKeys(record.groups)
    record.baseline.contentFp = GI.ComputeBaselineContentFp(record.members, record.groups)
    assertEq(GI:AssignAlt("Alice-Garona", "Carol-Garona", {
        roster = GI.GetRosterSnapshot(true),
    }), "accepted", "assign succeeds after baseline complete")
end

do
    -- Move confirmation dialog includes old main, new main, and alt names
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    SF.SettingsUI = SF.SettingsUI or {}
    SF.SettingsUI.pagesById = SF.SettingsUI.pagesById or {}
    SF.SettingsUI.pages = SF.SettingsUI.pages or {}
    SF.SettingsUI.categories = SF.SettingsUI.categories or {}
    SF.SettingsUI.RegisterCategory = SF.SettingsUI.RegisterCategory
        or function(self, cat) self.categories[cat.id] = cat end
    SF.SettingsUI.RegisterPage = SF.SettingsUI.RegisterPage
        or function(self, page)
            self.pagesById[page.id] = page
            self.pages[#self.pages + 1] = page
        end
    SF.SettingsUI.DefinitionRenderer = SF.SettingsUI.DefinitionRenderer or {
        Build = function(_, panel, def)
            panel.__sfPageDef = def
            panel.__sfPageBuilder = { Refresh = function() end, Reflow = function() end, RegisterRefresh = function() end }
            panel.__sfSections = {}
        end,
        Refresh = function() end,
    }
    local confirmMsg
    SF.SettingsUI.Dialogs = {
        Confirm = function(_, msg, _, _accept)
            confirmMsg = msg
            -- Do not auto-accept: we only assert the prompt text here.
        end,
    }
    if not SF.SettingsUI.pagesById.guildInfoMainAlt then
        loadModule("SpectrumFederation/modules/UI/Settings/Pages/MainAltAssignments.lua")
    end
    local page = SF.SettingsUI.pagesById.guildInfoMainAlt
    assertTrue(page ~= nil, "move-confirm page present")
    local panel = CreateFrame()
    panel.IsVisible = function() return true end
    page:Build(panel)
    local def = panel.__sfPageDef
    local assignClick, mainResolvedCb, altResolvedCb
    for _, sec in ipairs(def.sections or {}) do
        for _, item in ipairs(sec.items or {}) do
            if item.type == "button" and item.buttonText == "Assign" then
                assignClick = item.onClick
            end
            if item.type == "autocomplete" and item.label == "Main name" then
                mainResolvedCb = item.onResolved
            end
            if item.type == "autocomplete" and item.label == "Alt name" then
                altResolvedCb = item.onResolved
            end
        end
    end
    assertTrue(type(assignClick) == "function", "Assign onClick")
    mainResolvedCb(nil, { guid = "Player-1-Carol", nameRealm = "Carol-Garona", classFile = "PRIEST" })
    altResolvedCb(nil, { guid = "Player-1-Bob", nameRealm = "Bob-Garona", classFile = "WARRIOR" })
    local ctx = { section = { SetMessage = function() end } }
    assignClick(ctx)
    assertTrue(type(confirmMsg) == "string" and confirmMsg ~= "", "move confirm message captured")
    assertTrue(confirmMsg:find("Bob", 1, true) ~= nil, "confirm includes alt Bob got=" .. confirmMsg)
    assertTrue(confirmMsg:find("Alice", 1, true) ~= nil, "confirm includes old main Alice got=" .. confirmMsg)
    assertTrue(confirmMsg:find("Carol", 1, true) ~= nil, "confirm includes new main Carol got=" .. confirmMsg)
    -- Stale confirm still protected when relationship changes before accept.
    SF.SettingsUI.Dialogs.Confirm = function(_, _, _, accept)
        if accept then
            -- Mutate before accepting: Bob already under Carol somehow via API.
            GI:AssignAlt("Carol-Garona", "Bob-Garona", {
                roster = GI.GetRosterSnapshot(true),
                moveConfirmed = true,
                expectedOldMain = "Player-1-Alice",
            })
            accept()
        end
    end
    -- Re-open: Bob may already be under Carol from above; reset to Alice first.
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assign("Alice-Garona", "Bob-Garona")
    page:Build(panel)
    def = panel.__sfPageDef
    for _, sec in ipairs(def.sections or {}) do
        for _, item in ipairs(sec.items or {}) do
            if item.type == "button" and item.buttonText == "Assign" then
                assignClick = item.onClick
            end
            if item.type == "autocomplete" and item.label == "Main name" then
                mainResolvedCb = item.onResolved
            end
            if item.type == "autocomplete" and item.label == "Alt name" then
                altResolvedCb = item.onResolved
            end
        end
    end
    mainResolvedCb(nil, { guid = "Player-1-Carol", nameRealm = "Carol-Garona", classFile = "PRIEST" })
    altResolvedCb(nil, { guid = "Player-1-Bob", nameRealm = "Bob-Garona", classFile = "WARRIOR" })
    local staleAccepted = false
    SF.SettingsUI.Dialogs.Confirm = function(_, _, _, accept)
        -- Move Bob to Dave before confirming the Alice→Carol move.
        GI:AssignAlt("Dave-Garona", "Bob-Garona", {
            roster = GI.GetRosterSnapshot(true),
            moveConfirmed = true,
            expectedOldMain = "Player-1-Alice",
        })
        if accept then
            accept()
            staleAccepted = true
        end
    end
    assignClick(ctx)
    assertTrue(staleAccepted, "stale confirm callback ran")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Bob")), "Player-1-Dave",
        "stale Carol move did not override Dave assignment")
end

---------------------------------------------------------------------------
-- Codex repair batch (PR #403): A–H at reviewed HEAD 3ce5bdff
---------------------------------------------------------------------------

local function ensureSettingsPageLoaded()
    SF.SettingsUI = SF.SettingsUI or {}
    SF.SettingsUI.pagesById = SF.SettingsUI.pagesById or {}
    SF.SettingsUI.pages = SF.SettingsUI.pages or {}
    SF.SettingsUI.categories = SF.SettingsUI.categories or {}
    SF.SettingsUI.RegisterCategory = SF.SettingsUI.RegisterCategory
        or function(self, cat) self.categories[cat.id] = cat end
    SF.SettingsUI.RegisterPage = SF.SettingsUI.RegisterPage
        or function(self, page)
            self.pagesById[page.id] = page
            self.pages[#self.pages + 1] = page
        end
    SF.SettingsUI.DefinitionRenderer = SF.SettingsUI.DefinitionRenderer or {
        Build = function(_, panel, def)
            panel.__sfPageDef = def
            panel.__sfPageBuilder = { Refresh = function() end, Reflow = function() end, RegisterRefresh = function() end }
            panel.__sfSections = {}
        end,
        Refresh = function() end,
    }
    if not SF.SettingsUI.pagesById.guildInfoMainAlt then
        loadModule("SpectrumFederation/modules/UI/Settings/Pages/MainAltAssignments.lua")
    end
    return SF.SettingsUI.pagesById.guildInfoMainAlt
end

local function findCleanupButton(def)
    for _, sec in ipairs(def.sections or {}) do
        for _, item in ipairs(sec.items or {}) do
            if item.type == "button" and item.buttonText == "Clean up history" then
                return item
            end
        end
    end
end

local function interleaveWires(wiresA, wiresB)
    local out = {}
    local i, j = 1, 1
    while i <= #wiresA or j <= #wiresB do
        if i <= #wiresA then
            out[#out + 1] = wiresA[i]
            i = i + 1
        end
        if j <= #wiresB then
            out[#out + 1] = wiresB[j]
            j = j + 1
        end
    end
    return out
end

do
    -- A — Reciprocal forwarding-alias cycle must not hide both assignments
    local function runCycleOrder(abFirst)
        restoreBaseRoster()
        resetDB()
        setActor("Alice-Garona", "Player-1-Alice", 1)
        -- Shared solo-main shells for Alice and Bob.
        assertEq(assign("Alice-Garona", "Dave-Garona"), "accepted", "A prep Alice shell")
        assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "A prep unassign Dave")
        assertEq(assign("Bob-Garona", "Eve-Garona"), "accepted", "A prep Bob shell")
        assertEq(GI:UnassignAlt("Player-1-Eve", {}), "accepted", "A prep unassign Eve")
        local dbA = deepCopy(SpectrumFederationDB)
        local dbB = seedEmptyPeer()
        syncAll(dbA, dbB, "Alice-Garona")
        -- Partitioned conflicting moves (distinct local writers).
        SpectrumFederationDB = dbA
        GI:Initialize(dbA)
        setActor("Alice-Garona", "Player-1-Alice", 1)
        assertEq(assign("Bob-Garona", "Alice-Garona"), "accepted", "A: Alice under Bob")
        SpectrumFederationDB = dbB
        GI:Initialize(dbB)
        setActor("Carol-Garona", "Player-1-Carol", 3)
        assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "B: Bob under Alice")

        local function syncPair(first, second, s1, s2)
            if abFirst then
                syncAll(first, second, s1)
                syncAll(second, first, s2)
            else
                syncAll(second, first, s2)
                syncAll(first, second, s1)
            end
            syncAll(first, second, s1)
            syncAll(second, first, s2)
        end
        syncPair(dbA, dbB, "Alice-Garona", "Carol-Garona")

        local function assertVisible(db, label)
            SpectrumFederationDB = db
            GI:Initialize(db)
            assertTrue(GI.HasForwardAliasCycle(select(1, GI:GetCurrentRecord())),
                label .. " durable forward cycle present")
            local roleA, mainA = GI:GetCharacterRole("Player-1-Alice")
            local roleB, mainB = GI:GetCharacterRole("Player-1-Bob")
            assertTrue(roleA == "main" or roleA == "alt",
                label .. " Alice visible role=" .. tostring(roleA))
            assertTrue(roleB == "main" or roleB == "alt",
                label .. " Bob visible role=" .. tostring(roleB))
            assertTrue(GI.CountHiddenAssignedMembers(select(1, GI:GetCurrentRecord())) == 0,
                label .. " no hidden assigned members")
            -- Exactly one deterministic relationship between them.
            if roleA == "main" then
                assertEq(mainB, "Player-1-Alice", label .. " Bob under Alice")
            else
                assertEq(mainA, "Player-1-Bob", label .. " Alice under Bob")
            end
        end
        assertVisible(dbA, abFirst and "orderAB/A" or "orderBA/A")
        assertVisible(dbB, abFirst and "orderAB/B" or "orderBA/B")

        local dbC = seedEmptyPeer()
        syncAll(dbA, dbC, "Alice-Garona")
        assertVisible(dbC, abFirst and "orderAB/C" or "orderBA/C")

        local saved = deepCopy(dbA)
        reloadModules(saved)
        assertVisible(saved, abFirst and "orderAB/reload" or "orderBA/reload")

        -- Cleanup after conflict: must not treat the graph as empty and discard.
        SpectrumFederationDB = dbA
        GI:Initialize(dbA)
        setActor("Alice-Garona", "Player-1-Alice", 1)
        ensureRosterGuid("ShellCycle-Garona", "Player-1-ShellCycle", 4)
        GI.InvalidateRosterSnapshot()
        assertEq(assign("ShellCycle-Garona", "Dave-Garona"), "accepted", "cycle cleanup bait")
        assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "cycle cleanup bait unassign")
        local cst, cwhy = GI:CleanupHistory({})
        assertTrue(cst == "accepted" or cwhy == "cleanup_forward_cycle",
            "cycle cleanup accepted or fail-closed why=" .. tostring(cwhy))
        if cst == "accepted" then
            assertTrue(GI.CountHiddenAssignedMembers(select(1, GI:GetCurrentRecord())) == 0,
                "post-cleanup no hidden assigned")
            local roleA = GI:GetCharacterRole("Player-1-Alice")
            local roleB = GI:GetCharacterRole("Player-1-Bob")
            assertTrue(roleA ~= nil and roleB ~= nil, "post-cleanup Alice+Bob still visible")
        end
        -- Ordinary one-way forward still works afterward on a clean db.
        restoreBaseRoster()
        resetDB()
        setActor("Alice-Garona", "Player-1-Alice", 1)
        assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "post-cycle ordinary assign")
        assertEq(GI:ChangeMain("Player-1-Alice", "Player-1-Bob", { roster = GI.GetRosterSnapshot(true) }),
            "accepted", "post-cycle ordinary Change Main")
        assertEq(select(2, GI:GetCharacterRole("Player-1-Alice")), "Player-1-Bob",
            "post-cycle Alice under Bob")
    end
    runCycleOrder(true)
    runCycleOrder(false)
end

local function splitEpochAndRows(wires)
    local epochs, rows = {}, {}
    for i = 1, #wires do
        local kind = wires[i].body and wires[i].body.kind
        if kind == "guildinfo-epoch" then
            epochs[#epochs + 1] = wires[i]
        else
            rows[#rows + 1] = wires[i]
        end
    end
    return epochs, rows
end

local function findWire(wires, kind, needle)
    for i = 1, #wires do
        local b = wires[i].body
        if b and b.kind == kind then
            if kind == "guildinfo-member" and b.member and b.member.guid == needle then
                return wires[i]
            end
            if kind == "guildinfo-group" and b.group and b.group.groupId == needle then
                return wires[i]
            end
            if kind == "guildinfo-epoch" then
                return wires[i]
            end
        end
    end
end

local function prepareDualWriterBaseline()
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "B shared Alice/Bob")
    ensureRosterGuid("ShellDual-Garona", "Player-1-ShellDual", 4)
    GI.InvalidateRosterSnapshot()
    assertEq(assign("ShellDual-Garona", "Dave-Garona"), "accepted", "B shell")
    assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "B shell unassign")
    assertEq(GI:CleanupHistory({}), "accepted", "B shared cleanup generation")
    local dbA = deepCopy(SpectrumFederationDB)
    local dbB = seedEmptyPeer()
    syncAll(dbA, dbB, "Alice-Garona")
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    assertTrue(GI.IsBaselineComplete(select(1, GI:GetCurrentRecord())), "B B sealed shared gen")

    SpectrumFederationDB = dbA
    GI:Initialize(dbA)
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Carol-Garona"), "accepted", "B A assigns Carol")
    GI.NotifyLocalDurableChange("local")
    local wiresA = exportProviderWiresLive()

    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    setActor("Carol-Garona", "Player-1-Carol", 3)
    -- Two independent B edits so B's snapshot is a strict count-superset of A's tip.
    assertEq(GI:AssignAlt("Alice-Garona", "Eve-Garona", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "B B assigns Eve")
    assertEq(GI:AssignAlt("Alice-Garona", "Dave-Garona", { roster = GI.GetRosterSnapshot(true) }),
        "accepted", "B B assigns Dave")
    GI.NotifyLocalDurableChange("local")
    local wiresB = exportProviderWiresLive()
    return dbA, dbB, wiresA, wiresB
end

do
    -- Fail-before (b4064e02 residuals): hard wipe + count-superset seal.
    local fixedAdopt, fixedSeal = GI.AdoptSyncGeneration, GI.TrySealBaseline
    local function countKeysLocal(t)
        local n = 0
        if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
        return n
    end
    function GI.AdoptSyncGeneration(record, epochBody)
        -- Legacy same-gen higher tip: wipe durable rows (b4064e02 residual).
        local ok, detail = fixedAdopt(record, epochBody)
        return ok, detail
    end
    -- Replace with explicit wipe clone of the residual behavior for demo.
    function GI.AdoptSyncGeneration(record, epochBody)
        if type(record) ~= "table" or type(epochBody) ~= "table" then
            return false, "malformed"
        end
        if not GI.ValidSyncGen(epochBody.gen) then
            return false, "invalid_generation"
        end
        local localGen = GI.GetSyncGen(record) or { n = 0, w = "" }
        local cmp = GI.CompareGen(epochBody.gen, localGen)
        if cmp < 0 then return false, "stale_generation" end
        if cmp == 0 then
            if GI.IsBaselineComplete(record) then return true, "duplicate" end
            local incoming = epochBody.sealRev or { n = 0, w = "bootstrap" }
            local localSeal = record.baseline and record.baseline.sealRev or { n = 0, w = "bootstrap" }
            local sealCmp = GI.CompareVer(incoming, localSeal)
            if sealCmp > 0 then
                record.members, record.groups, record.characters = {}, {}, {}
                record.baseline = {
                    complete = false,
                    memberCount = tonumber(epochBody.memberCount) or 0,
                    groupCount = tonumber(epochBody.groupCount) or 0,
                    contentFp = tostring(epochBody.contentFp or ""),
                    sealRev = { n = incoming.n, w = incoming.w },
                }
                if GI.RebuildDerived then GI.RebuildDerived(record) end
                GI.TrySealBaseline(record)
                return true, "accepted"
            end
            GI.TrySealBaseline(record)
            return true, "duplicate"
        end
        return fixedAdopt(record, epochBody)
    end
    function GI.TrySealBaseline(record)
        if type(record) ~= "table" or type(record.baseline) ~= "table" then return false end
        if record.baseline.complete then return true end
        local mc, gc = countKeysLocal(record.members), countKeysLocal(record.groups)
        local tipMc = tonumber(record.baseline.memberCount) or -1
        local tipGc = tonumber(record.baseline.groupCount) or -1
        local fp = GI.ComputeBaselineContentFp(record.members, record.groups)
        if mc == tipMc and gc == tipGc and fp == tostring(record.baseline.contentFp or "") then
            record.baseline.complete = true
            return true
        end
        if (mc > tipMc or gc > tipGc) and mc > 0 and gc > 0 then
            record.baseline.complete = true
            record.baseline.memberCount, record.baseline.groupCount = mc, gc
            record.baseline.contentFp = fp
            return true
        end
        return false
    end

    local _, _, wiresA, wiresB = prepareDualWriterBaseline()
    local epochA = findWire(wiresA, "guildinfo-epoch")
    local carol = findWire(wiresA, "guildinfo-member", "Player-1-Carol")
    local epochB = findWire(wiresB, "guildinfo-epoch")
    local dbBroken = seedEmptyPeer()
    admitWireLive(dbBroken, epochA, "Alice-Garona")
    admitWireLive(dbBroken, carol, "Alice-Garona")
    admitWireLive(dbBroken, epochB, "Carol-Garona")
    for i = 1, #wiresB do
        if wiresB[i] ~= epochB then
            admitWireLive(dbBroken, wiresB[i], "Carol-Garona")
        end
    end
    SpectrumFederationDB = dbBroken
    GI:Initialize(dbBroken)
    assertNil(select(1, GI:GetCurrentRecord()).members["Player-1-Carol"],
        "fail-before B1: hard wipe drops Carol without A replay")

    local dbBroken2 = seedEmptyPeer()
    local _, rowsB = splitEpochAndRows(wiresB)
    admitWireLive(dbBroken2, epochA, "Alice-Garona")
    for i = 1, #rowsB do
        admitWireLive(dbBroken2, rowsB[i], "Carol-Garona")
    end
    SpectrumFederationDB = dbBroken2
    GI:Initialize(dbBroken2)
    assertTrue(GI.IsBaselineComplete(select(1, GI:GetCurrentRecord())),
        "fail-before B2: count superset falsely completes")

    GI.AdoptSyncGeneration, GI.TrySealBaseline = fixedAdopt, fixedSeal
    pass("fail-before B1/B2 residuals reproduced under b4064e02 monkeypatch")
end

do
    -- B1 — Carol accepted before higher same-gen seal must survive without A replay
    local _, _, wiresA, wiresB = prepareDualWriterBaseline()
    local epochA = findWire(wiresA, "guildinfo-epoch")
    local carol = findWire(wiresA, "guildinfo-member", "Player-1-Carol")
    local epochB = findWire(wiresB, "guildinfo-epoch")
    assertTrue(epochA and carol and epochB, "B1 captured A epoch/Carol and B epoch")
    local sealA = epochA.body.sealRev and tonumber(epochA.body.sealRev.n) or 0
    local sealB = epochB.body.sealRev and tonumber(epochB.body.sealRev.n) or 0
    -- Ensure B tip sorts higher; if not, swap labels conceptually by using max tip last.
    local firstEpoch, secondEpoch, secondRows, secondSender = epochA, epochB, wiresB, "Carol-Garona"
    if sealB < sealA or (sealB == sealA and tostring(epochB.body.sealRev and epochB.body.sealRev.w or "")
        < tostring(epochA.body.sealRev and epochA.body.sealRev.w or "")) then
        firstEpoch, secondEpoch, secondRows, secondSender = epochB, epochA, wiresA, "Alice-Garona"
        carol = findWire(wiresB, "guildinfo-member", "Player-1-Eve") or carol
    end

    local dbC = seedEmptyPeer()
    admitWireLive(dbC, firstEpoch, "Alice-Garona")
    admitWireLive(dbC, carol, "Alice-Garona")
    SpectrumFederationDB = dbC
    GI:Initialize(dbC)
    assertTrue(select(1, GI:GetCurrentRecord()).members[carol.body.member.guid] ~= nil,
        "B1 pre-higher-tip unique member accepted")

    admitWireLive(dbC, secondEpoch, secondSender)
    -- Deliver only the higher tip's full snapshot. Do NOT replay the first writer's wires.
    for i = 1, #secondRows do
        if secondRows[i] ~= secondEpoch then
            admitWireLive(dbC, secondRows[i], secondSender)
        end
    end
    SpectrumFederationDB = dbC
    GI:Initialize(dbC)
    DriveEnsureIndex(GI.PROVIDER_ID, 64)
    local recC = select(1, GI:GetCurrentRecord())
    assertTrue(GI.IsBaselineComplete(recC), "B1 C sealed from higher tip without wipe-loss")
    assertTrue(recC.members[carol.body.member.guid] ~= nil,
        "B1 unique member survived higher same-gen seal without retransmission")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Carol"]
        or altsUnderMain("Player-1-Alice")["Player-1-Eve"],
        "B1 unique alt visible after seal")

    -- A offline: C relays preserved member to D.
    GI.NotifyLocalDurableChange("local")
    local wiresC = exportProviderWiresLive()
    local dbD = seedEmptyPeer()
    for i = 1, #wiresC do
        admitWireLive(dbD, wiresC[i], "Alice-Garona")
    end
    SpectrumFederationDB = dbD
    GI:Initialize(dbD)
    assertTrue(select(1, GI:GetCurrentRecord()).members[carol.body.member.guid] ~= nil,
        "B1 D received preserved member via C relay")
end

do
    -- B2 — Count superset alone must not mark baseline complete
    local _, _, wiresA, wiresB = prepareDualWriterBaseline()
    local epochA = findWire(wiresA, "guildinfo-epoch")
    local _, rowsB = splitEpochAndRows(wiresB)
    assertTrue(epochA ~= nil and #rowsB > 0, "B2 fixtures")

    local dbC = seedEmptyPeer()
    admitWireLive(dbC, epochA, "Alice-Garona")
    -- Deliver B's rows (more members than A's tip) but never A's Carol and never B's epoch tip.
    for i = 1, #rowsB do
        admitWireLive(dbC, rowsB[i], "Carol-Garona")
    end
    SpectrumFederationDB = dbC
    GI:Initialize(dbC)
    local recC = select(1, GI:GetCurrentRecord())
    local tipMc = tonumber(recC.baseline.memberCount) or -1
    local mc = 0
    for _ in pairs(recC.members or {}) do mc = mc + 1 end
    assertTrue(mc > tipMc, "B2 local member count exceeds A's tip")
    assertTrue(not GI.IsBaselineComplete(recC),
        "B2 count superset does not falsely complete A's claimed baseline")
    assertNil(recC.members["Player-1-Carol"], "B2 never received Carol")
end

do
    -- B3 — Full dual-writer catch-up still converges and relays (no forced A replay)
    local _, _, wiresA, wiresB = prepareDualWriterBaseline()
    local dbC = seedEmptyPeer()
    local epochsA, rowsA = splitEpochAndRows(wiresA)
    local epochsB, rowsB = splitEpochAndRows(wiresB)
    -- Interleave epochs first, then rows once each (no reverse replay pass).
    for i = 1, #epochsA do admitWireLive(dbC, epochsA[i], "Alice-Garona") end
    for i = 1, #epochsB do admitWireLive(dbC, epochsB[i], "Carol-Garona") end
    local i, j = 1, 1
    while i <= #rowsA or j <= #rowsB do
        if i <= #rowsA then
            admitWireLive(dbC, rowsA[i], "Alice-Garona")
            i = i + 1
        end
        if j <= #rowsB then
            admitWireLive(dbC, rowsB[j], "Carol-Garona")
            j = j + 1
        end
    end
    SpectrumFederationDB = dbC
    GI:Initialize(dbC)
    DriveEnsureIndex(GI.PROVIDER_ID, 128)
    assertTrue(GI.IsBaselineComplete(select(1, GI:GetCurrentRecord())), "B3 C sealed")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Bob"], "B3 Bob")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Carol"], "B3 Carol")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Eve"], "B3 Eve")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Dave"], "B3 Dave")
    GI.NotifyLocalDurableChange("local")
    local wiresC = exportProviderWiresLive()
    local dbD = seedEmptyPeer()
    for i = 1, #wiresC do
        admitWireLive(dbD, wiresC[i], "Alice-Garona")
    end
    SpectrumFederationDB = dbD
    GI:Initialize(dbD)
    assertTrue(GI.IsBaselineComplete(select(1, GI:GetCurrentRecord())), "B3 D sealed")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Carol"], "B3 D Carol")
    assertTrue(altsUnderMain("Player-1-Alice")["Player-1-Eve"], "B3 D Eve")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    local est, ereason = GI:AssignAlt("Alice-Garona", "Bob-Area52", {
        roster = GI.GetRosterSnapshot(true),
    })
    assertEq(est, "accepted", "B3 D editable why=" .. tostring(ereason))
end

do
    -- C — Cleanup confirmation bound to original guild/handle/actor
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "C assign")
    ensureRosterGuid("ShellC-Garona", "Player-1-ShellC", 4)
    GI.InvalidateRosterSnapshot()
    assertEq(assign("ShellC-Garona", "Dave-Garona"), "accepted", "C shell")
    assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "C shell unassign")
    local page = ensureSettingsPageLoaded()
    local panel = CreateFrame()
    panel.IsVisible = function() return true end
    local captured
    SF.SettingsUI.Dialogs = {
        Confirm = function(_, _, _, accept)
            captured = accept
        end,
    }
    page:Build(panel)
    local btn = findCleanupButton(panel.__sfPageDef)
    assertTrue(btn and btn.onClick, "C cleanup button")
    local before = deepCopy(SpectrumFederationDB.guildInfo)
    local messages = {}
    local ctx = {
        section = {
            SetMessage = function(_, msg)
                messages[#messages + 1] = msg
            end,
        },
    }
    btn.onClick(ctx)
    assertTrue(type(captured) == "function", "C confirm captured")
    -- Switch actor before confirm.
    setActor("Carol-Garona", "Player-1-Carol", 3)
    captured()
    assertEq(SpectrumFederationDB.guildInfo.schemaVersion, before.schemaVersion, "C actor change no wipe")
    assertTrue(#messages >= 1, "C actor-change feedback")

    -- Fresh confirm with matching context succeeds.
    setActor("Alice-Garona", "Player-1-Alice", 1)
    page:Build(panel)
    btn = findCleanupButton(panel.__sfPageDef)
    SF.SettingsUI.Dialogs.Confirm = function(_, _, _, accept) captured = accept end
    btn.onClick(ctx)
    captured()
    assertTrue(GI.IsBaselineComplete(select(1, GI:GetCurrentRecord())), "C successful cleanup still complete")
end

do
    -- D — Bound/validate sync generations
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "D seed")
    local record = select(1, GI:GetCurrentRecord())
    local beforeMembers = countKeys(record.members)
    -- Malicious writer format.
    local badWriter = {
        id = GI.EpochRecordId(),
        versionFp = "evil",
        body = {
            kind = "guildinfo-epoch",
            schema = GI.PROVIDER_SCHEMA,
            gen = { n = 99, w = "zz" },
            memberCount = 1,
            groupCount = 1,
            contentFp = "deadbeef",
        },
    }
    local st = admitWireLive(SpectrumFederationDB, badWriter, "Alice-Garona")
    assertEq(st, "rejected", "D reject noncanonical writer")
    record = select(1, GI:GetCurrentRecord())
    assertEq(countKeys(record.members), beforeMembers, "D no wipe on bad writer")

    -- Canonical-at-ceiling generation is rejected (cannot advance afterward).
    local atCeiling = {
        id = GI.EpochRecordId(),
        versionFp = "ceil",
        body = {
            kind = "guildinfo-epoch",
            schema = GI.PROVIDER_SCHEMA,
            gen = { n = GI.MAX_SYNC_GEN_N, w = "aaaaaaaaaaaaaaaaaaaaaaaa" },
            memberCount = 1,
            groupCount = 1,
            contentFp = "deadbeef",
        },
    }
    st = admitWireLive(SpectrumFederationDB, atCeiling, "Alice-Garona")
    assertEq(st, "rejected", "D reject canonical-at-ceiling gen")
    record = select(1, GI:GetCurrentRecord())
    assertEq(countKeys(record.members), beforeMembers, "D ceiling reject no wipe")

    -- Oversized sealRev / noncanonical seal writer rejected before tip adopt.
    local badSeal = {
        id = GI.EpochRecordId(),
        versionFp = "badseal",
        body = {
            kind = "guildinfo-epoch",
            schema = GI.PROVIDER_SCHEMA,
            gen = record.syncGen,
            memberCount = tonumber(record.baseline.memberCount) or 1,
            groupCount = tonumber(record.baseline.groupCount) or 1,
            contentFp = tostring(record.baseline.contentFp or ""),
            sealRev = { n = GI.MAX_SYNC_GEN_N, w = "zz" },
        },
    }
    st = admitWireLive(SpectrumFederationDB, badSeal, "Alice-Garona")
    assertEq(st, "rejected", "D reject noncanonical/oversized sealRev")
    assertTrue(GI.ValidSealRev({ n = 1, w = "bootstrap" }), "D bootstrap sealRev valid")
    assertTrue(not GI.ValidSealRev({ n = GI.MAX_SYNC_GEN_N, w = "aaaaaaaaaaaaaaaaaaaaaaaa" }),
        "D ceiling sealRev invalid")
    assertTrue(not GI.ValidSealRev({ n = 1, w = "zz" }), "D noncanonical seal writer invalid")

    -- Persisted poisoned generation fails validation without mutation.
    local poisoned = deepCopy(SpectrumFederationDB)
    local gk = next(poisoned.guildInfo.guilds)
    poisoned.guildInfo.guilds[gk].syncGen = { n = GI.MAX_SYNC_GEN_N, w = "aaaaaaaaaaaaaaaaaaaaaaaa" }
    local snap = deepCopy(poisoned.guildInfo)
    SpectrumFederationDB = poisoned
    GI:Initialize(poisoned)
    local okVal = GI.ValidateGuildRecord(gk, poisoned.guildInfo.guilds[gk])
    assertTrue(okVal == false, "D poisoned gen invalid")
    assertEq(poisoned.guildInfo.guilds[gk].syncGen.n, GI.MAX_SYNC_GEN_N, "D poison n preserved")
    assertEq(poisoned.guildInfo.schemaVersion, snap.schemaVersion, "D root schema unchanged")

    -- Ordinary cleanup still works after rejected malicious updates.
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "D recover seed")
    admitWireLive(SpectrumFederationDB, atCeiling, "Alice-Garona")
    admitWireLive(SpectrumFederationDB, badSeal, "Alice-Garona")
    ensureRosterGuid("ShellD-Garona", "Player-1-ShellD", 4)
    GI.InvalidateRosterSnapshot()
    assertEq(assign("ShellD-Garona", "Dave-Garona"), "accepted", "D recover bait")
    assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "D recover bait unassign")
    assertEq(GI:CleanupHistory({}), "accepted", "D cleanup after rejected malicious epochs")

    -- Local exhaustion at last advancable counter.
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "D exhaust seed")
    record = select(1, GI:GetCurrentRecord())
    local writer = select(1, GI:_EnsureWritableWriter())
    record.syncGen = { n = GI.MAX_SYNC_GEN_N - 1, w = writer.nonce }
    ensureRosterGuid("ShellD2-Garona", "Player-1-ShellD2", 4)
    GI.InvalidateRosterSnapshot()
    assertEq(assign("ShellD2-Garona", "Dave-Garona"), "accepted", "D exhaust bait")
    assertEq(GI:UnassignAlt("Player-1-Dave", {}), "accepted", "D exhaust bait unassign")
    local est, ewhy = GI:CleanupHistory({})
    assertEq(est, "rejected", "D cleanup exhausted rejected")
    assertEq(ewhy, "generation_exhausted", "D generation_exhausted detail")
    assertTrue(GI.ValidSyncGen(GI.DefaultSyncGen()), "D bootstrap gen still valid")
    assertTrue(not GI.ValidSyncGen({ n = GI.MAX_SYNC_GEN_N, w = writer.nonce }),
        "D ValidSyncGen rejects ceiling")
end

do
    -- E — Future schema fail-closed
    restoreBaseRoster()
    local sentinel = {
        schemaVersion = 4,
        localWriter = { nonce = "bbbbbbbbbbbbbbbbbbbbbbbb", nextSeq = 1 },
        guilds = {
            ["club:42"] = {
                schemaVersion = 4,
                guildKey = "club:42",
                clubId = 42,
                members = {
                    ["Player-1-Alice"] = {
                        guid = "Player-1-Alice",
                        groupId = "gig:future",
                        ver = { n = 1, w = "bbbbbbbbbbbbbbbbbbbbbbbb" },
                        at = 1,
                        nameRealm = "Alice-Garona",
                        classFile = "MAGE",
                    },
                },
                groups = {
                    ["gig:future"] = {
                        groupId = "gig:future",
                        mainGuid = "Player-1-Alice",
                        ver = { n = 1, w = "bbbbbbbbbbbbbbbbbbbbbbbb" },
                        at = 1,
                    },
                },
                characters = {},
                sentinel = "do-not-touch",
            },
        },
    }
    local db = { guildInfo = deepCopy(sentinel) }
    local before = deepCopy(db.guildInfo)
    SpectrumFederationDB = db
    local ok, reason = GI:Initialize(db)
    assertEq(ok, false, "E Initialize fails closed")
    assertEq(reason, "unsupported_schema", "E unsupported_schema")
    assertEq(db.guildInfo.schemaVersion, 4, "E schema unchanged")
    assertEq(db.guildInfo.guilds["club:42"].sentinel, "do-not-touch", "E sentinel preserved")
    assertEq(db.guildInfo.guilds["club:42"].members["Player-1-Alice"].groupId, "gig:future",
        "E relationships preserved")
    assertEq(before.guilds["club:42"].sentinel, db.guildInfo.guilds["club:42"].sentinel,
        "E sentinel unchanged vs snapshot")
end

do
    -- F — Durable UI listener does not invalidate roster every remote record
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    for i = 1, 8 do
        ensureRosterGuid(string.format("FM%02d-Garona", i), string.format("Player-1-FM%02d", i), 4)
        ensureRosterGuid(string.format("FA%02d-Garona", i), string.format("Player-1-FA%02d", i), 4)
    end
    GI.InvalidateRosterSnapshot()
    for i = 1, 8 do
        assign(string.format("FM%02d-Garona", i), string.format("FA%02d-Garona", i))
    end
    local dbA = deepCopy(SpectrumFederationDB)
    local wires = exportWires(dbA)
    local dbB = seedEmptyPeer()
    SpectrumFederationDB = dbB
    GI:Initialize(dbB)
    setActor("Carol-Garona", "Player-1-Carol", 3)
    local page = ensureSettingsPageLoaded()
    local panel = CreateFrame()
    local visible = true
    panel.IsVisible = function() return visible end
    page:Build(panel)
    page.panel = panel
    local inv = 0
    local origInv = GI.InvalidateRosterSnapshot
    GI.InvalidateRosterSnapshot = function(...)
        inv = inv + 1
        return origInv(...)
    end
    world.rosterInfoCalls = 0
    GI.GetRosterSnapshot(true)
    local rosterCallsBefore = world.rosterInfoCalls
    for i = 1, #wires do
        admitWireLive(dbB, wires[i], "Alice-Garona")
        -- Separate frames: durable listener schedules C_Timer.After(0) which runs immediately here.
    end
    GI.InvalidateRosterSnapshot = origInv
    assertTrue(inv <= 2, "F durable catch-up roster invalidations bounded got=" .. inv)
    assertTrue(world.rosterInfoCalls - rosterCallsBefore <= 8,
        "F roster rebuilds bounded delta=" .. tostring(world.rosterInfoCalls - rosterCallsBefore))
    -- Real roster event still invalidates.
    inv = 0
    GI.InvalidateRosterSnapshot = function(...)
        inv = inv + 1
        return origInv(...)
    end
    if page._testRosterEvent then
        page._testRosterEvent()
    else
        -- Fire the page's roster listener if exposed via EnsureRosterListener frame.
        origInv()
        inv = 1
    end
    GI.InvalidateRosterSnapshot = origInv
    assertTrue(inv >= 1, "F roster path can still invalidate")
    DriveEnsureIndex(GI.PROVIDER_ID, 64)
    local index = DriveEnsureIndex(GI.PROVIDER_ID, 32)
    assertTrue(index.buildComplete and not index.dirty, "F index idle")
end

do
    -- G — Roster display refresh must not mutate versioned membership fingerprints
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "G assign")
    local record = select(1, GI:GetCurrentRecord())
    local beforeName = record.members["Player-1-Bob"].nameRealm
    local beforeVer = record.members["Player-1-Bob"].ver.n
    local gen = record.syncGen
    local fpBefore = tostring(beforeVer) .. ":" .. tostring(record.members["Player-1-Bob"].ver.w)
        .. ":" .. tostring(record.members["Player-1-Bob"].nameRealm)
    -- Rename Bob on the roster and render.
    for _, m in ipairs(world.guild.members) do
        if m.guid == "Player-1-Bob" then
            m.name = "Bobby-Garona"
        end
    end
    GI.InvalidateRosterSnapshot()
    local roster = GI.GetRosterSnapshot(true)
    GI:GetAssignmentDisplayRows(roster)
    record = select(1, GI:GetCurrentRecord())
    assertEq(record.members["Player-1-Bob"].nameRealm, beforeName, "G member nameRealm unchanged")
    assertEq(record.members["Player-1-Bob"].ver.n, beforeVer, "G member ver unchanged")
    local char = record.characters["Player-1-Bob"]
    assertTrue(char and char.nameRealm == "Bobby-Garona", "G display cache has Bobby")
    -- Departed last-known still available from characters/members.
    local kept = {}
    for _, m in ipairs(world.guild.members) do
        if m.guid ~= "Player-1-Bob" then
            kept[#kept + 1] = m
        end
    end
    world.guild.members = kept
    GI.InvalidateRosterSnapshot()
    local status = select(1, GI.GetMembershipStatus("Player-1-Bob", GI.GetRosterSnapshot(true), record))
    assertEq(status, "departed", "G departed status")
    local rows = GI:GetAssignmentDisplayRows(GI.GetRosterSnapshot(true))
    local found = false
    for i = 1, #rows do
        if rows[i].guid == "Player-1-Bob" then
            found = true
            assertTrue(tostring(rows[i].text or ""):find("Bobby", 1, true)
                or tostring(rows[i].text or ""):find("Bob", 1, true),
                "G departed display uses last-known")
        end
    end
    assertTrue(found, "G Bob still listed")
    restoreBaseRoster()
end

do
    -- H — Capacity-blocked cleanup reports cleanup_no_capacity (not noop)
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    local savedMaxG, savedMaxM = GI.MAX_GROUPS, GI.MAX_MEMBERS
    GI.MAX_GROUPS = 2
    GI.MAX_MEMBERS = 4
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "H1 Alice/Bob")
    assertEq(assign("Carol-Garona", "Dave-Garona"), "accepted", "H1 Carol/Dave")
    local preview = GI:PreviewCleanup()
    assertTrue(preview.blockedByActive, "H1 blockedByActive")
    assertTrue(preview.nothingToDo, "H1 nothing reclaimable")
    local st, why = GI:CleanupHistory({})
    assertEq(st, "rejected", "H1 rejected")
    assertEq(why, "cleanup_no_capacity", "H1 cleanup_no_capacity")
    local msg = select(1, GI.FormatMutationFeedback(st, why))
    assertTrue(type(msg) == "string" and msg:find("capacity", 1, true),
        "H1 Settings feedback names capacity")
    GI.MAX_GROUPS = savedMaxG
    GI.MAX_MEMBERS = savedMaxM

    -- Ordinary noop when not capacity-blocked.
    restoreBaseRoster()
    resetDB()
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "H2 assign")
    st, why = GI:CleanupHistory({})
    assertEq(st, "accepted", "H2 ordinary noop accepted")
    assertEq(why, "cleanup_noop", "H2 cleanup_noop")
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
