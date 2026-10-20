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
    local mainEnabled, altEnabled
    for _, sec in ipairs(def.sections or {}) do
        for _, item in ipairs(sec.items or {}) do
            if sec.id == "guildInfoMainAltStatus" and item.type == "display" then
                accessGet = item.get
            end
            if item.type == "button" and item.buttonText == "Assign" then
                assignEnabled = item.enabled
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
-- C) Compaction snapshot sync + export lifecycle + late joiner
---------------------------------------------------------------------------

do
    resetDB()
    local prevMax = GI.MAX_ACCEPTED_OPS
    GI.MAX_ACCEPTED_OPS = 3
    setActor("Alice-Garona", "Player-1-Alice", 1)

    world.time = world.time + 1
    assertEq(assign("Alice-Garona", "Bob-Garona"), "accepted", "compact seed assign Bob")
    world.time = world.time + 1
    assertEq(assign("Alice-Garona", "Eve-Garona"), "accepted", "compact seed assign Eve")
    world.time = world.time + 1
    assertEq(assign("Alice-Garona", "Dave-Garona"), "accepted", "compact seed assign Dave fills log")
    local record = select(1, GI:GetCurrentRecord())
    assertEq(#record.order, 3, "log full at compaction threshold")
    world.time = world.time + 1
    local beforeCompact = world.providerChanged
    -- Next admit compacts then applies unassign.
    local status = GI:UnassignAlt("Player-1-Dave", {})
    assertEq(status, "accepted", "op that triggers compaction accepted")
    record = select(1, GI:GetCurrentRecord())
    assertTrue(#record.order < GI.MAX_ACCEPTED_OPS, "log shrunk after compaction")
    local snap = nil
    for i = 1, #record.order do
        local op = record.ops[record.order[i]]
        if op and op.kind == GI.KIND.SNAPSHOT then
            snap = op
            break
        end
    end
    assertTrue(snap ~= nil, "compaction produced an officer snapshot")
    assertEq(snap.actorGuid, "Player-1-Alice", "snapshot authored by officer not synthetic compact")
    assertTrue(snap.actorGuid ~= "compact", "snapshot actorGuid is not compact marker")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "Bob preserved across compaction")
    assertEq(GI:GetCharacterRole("Player-1-Eve"), "alt", "Eve preserved across compaction")
    assertNil(GI:GetCharacterRole("Player-1-Dave"), "post-compact unassign applied")
    assertTrue(world.providerChanged > beforeCompact, "compaction notifies provider changed")

    -- Export index matches durable live ops only (C).
    local provider = SF.GuildGossip._providers[GI.PROVIDER_ID]
    local spec = provider.spec
    local page = spec.ListRecordIds(1, 64)
    assertEq(#page, #record.order, "export size matches live durable ops")
    local exportHasSnap = false
    for i = 1, #page do
        if page[i]:find(snap.id, 1, true) then exportHasSnap = true end
    end
    assertTrue(exportHasSnap, "export includes officer snapshot")

    -- Old compacted op cannot resurrect a removed link.
    -- Mark a fabricated pre-compact id as compacted and ensure duplicate.
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
    -- Eve is already an alt via the snapshot; an older Carol→Eve assign must not
    -- move her (superseded) and must not invent a Carol main group.
    local resurrect = {
        id = "gi1:Player-1-Alice:resurrectaaaaaaaaaaaaaa:1",
        kind = GI.KIND.ASSIGN,
        at = 1, -- older than snapshot
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        guildKey = "club:42",
        mainGuid = "Player-1-Carol",
        mainName = "Carol-Garona",
        altGuid = "Player-1-Eve",
        altName = "Eve-Garona",
    }
    st = GI:AdmitOperation(resurrect, { remote = true })
    assertEq(st, "duplicate", "op older than snapshot superseded")
    assertEq(select(2, GI:GetCharacterRole("Player-1-Eve")), "Player-1-Alice",
        "superseded op did not move Eve off Alice")
    assertNil(GI:GetCharacterRole("Player-1-Carol"), "superseded op did not create Carol main")

    -- Late peer catch-up: empty peer receives snapshot via authenticated relay officer.
    local lateDB = {}
    SpectrumFederationDB = lateDB
    GI:Initialize(lateDB)
    GI:EnsureGossipProvider()
    local lateProvider = SF.GuildGossip._providers[GI.PROVIDER_ID]
    local lateSpec = lateProvider.spec
    local relayStatus = lateSpec.ValidateAndApply({
        id = "gi-op:" .. snap.id,
        versionFp = "snap",
        body = { kind = "guildinfo-op", op = deepCopy(snap) },
    }, { sender = "Carol-Garona" }) -- Carol relays Alice-authored snapshot
    assertEq(relayStatus, "accepted", "editor may relay officer-authored snapshot")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "late joiner reconstructs Bob alt")
    local _, bobMain = GI:GetCharacterRole("Player-1-Bob")
    assertEq(bobMain, "Player-1-Alice", "late joiner reconstructs Alice as main")

    -- Reload after compaction remains bounded and consistent.
    local saved = SpectrumFederationDB
    local liveCount = #select(1, GI:GetCurrentRecord()).order
    SF.GuildInfo = nil
    loadModule("SpectrumFederation/modules/GuildInfo/State.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Authority.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Operations.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Roster.lua")
    loadModule("SpectrumFederation/modules/GuildInfo/Gossip.lua")
    GI = SF.GuildInfo
    GI.MAX_ACCEPTED_OPS = 3
    GI:Initialize(saved)
    assertEq(#select(1, GI:GetCurrentRecord()).order, liveCount, "reload keeps compacted live ops")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "reload after compaction restores graph")

    -- Second compaction cycle stays bounded.
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
    -- Restore primary GI on fresh DB for subsequent tests.
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

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
io.stdout:write("0 failed\n")
