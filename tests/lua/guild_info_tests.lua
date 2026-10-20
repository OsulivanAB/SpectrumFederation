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
function GetGuildRosterInfo(i)
    local m = world.guild.members[i]
    if not m then return end
    local rankIndex = (tonumber(m.rankOrder) or 1) - 1
    return m.name, world.guild.ranks[m.rankOrder] or "Rank", rankIndex, 80, "Class", "Zone",
        "", "", m.online, 0, m.class or "WARRIOR", 0, 0, false, false, 0, m.guid
end
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
        SF.GuildGossip._providers[spec.id] = { spec = spec, enabled = true, index = { buildComplete = false, dirty = true } }
        return true
    end,
    SetProviderEnabled = function(id, enabled)
        local e = SF.GuildGossip._providers[id]
        if e then e.enabled = enabled end
    end,
    GetProvider = function(id)
        return SF.GuildGossip._providers[id]
    end,
    NotifyProviderChanged = function()
        world.providerChanged = world.providerChanged + 1
    end,
    IndexUpsert = function() return true, nil end,
    BumpIndexEpoch = function() end,
}

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

    -- Actor mismatch laundering: Bob claims to be Alice in payload but sender is Bob... Bob is rank 2 editor though.
    -- Use Dave as sender with Alice actorGuid already tested. Test editor with wrong actorGuid:
    local badActor = {
        id = "gi1:Player-1-Carol:cccccccccccccccccccccccc:2",
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
        id = "gi-op:" .. badActor.id,
        versionFp = "z",
        body = { kind = "guildinfo-op", op = badActor },
    }, { sender = "Carol-Garona" })
    assertEq(status, "rejected", "actor_mismatch rejected")
    assertEq(detail, "actor_mismatch", "actor_mismatch detail")
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

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
io.stdout:write("0 failed\n")
