-- Production-Lua tests for the shared guild officer rank (#405).
-- Run from repository root: lua5.1 tests/lua/guild_officer_tests.lua

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
    time = 9000,
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
    return default or tostring(key or "")
end
SF.Debug = {
    IsEnabled = function() return false end,
    Info = function() end,
    Warn = function() end,
    Error = function() end,
    Verbose = function() end,
}
SF.LootHelperImpersonation = {
    IsActive = function() return world.impersonationActive end,
}
SF.NameUtil = {
    NormalizeNameRealm = function(name)
        if type(name) ~= "string" or name == "" then return nil end
        name = strtrim(name)
        if name:find("-", 1, true) then return name end
        return name .. "-Garona"
    end,
    SamePlayer = function(a, b)
        local na = SF.NameUtil.NormalizeNameRealm(a)
        local nb = SF.NameUtil.NormalizeNameRealm(b)
        if not na or not nb then return false end
        return string.lower(na) == string.lower(nb)
    end,
    GetSelfId = function() return world.unitName .. "-Garona" end,
}

SF.GuildGossip = {
    _providers = {},
    MAX_RECORD_CBOR = 2048,
    SelfId = function() return world.unitName .. "-Garona" end,
    NormalizePlayer = function(name) return SF.NameUtil.NormalizeNameRealm(name) end,
    GetGuildScopeId = function()
        if not world.guild.inGuild or not world.guild.clubId then return nil end
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
        }
    end,
    GetGuildRanks = function()
        if not world.guild.inGuild then return nil, "not_in_guild" end
        if not world.guild.rosterComplete then return nil, "roster_incomplete" end
        local ranks = { count = #world.guild.ranks, guildKey = "club:" .. tostring(world.guild.clubId) }
        for i = 1, #world.guild.ranks do ranks[i] = world.guild.ranks[i] end
        return ranks
    end,
    GetGuildMember = function(name)
        if not world.guild.inGuild then return nil, "not_in_guild" end
        if not world.guild.rosterComplete then return nil, "roster_incomplete" end
        local want = SF.NameUtil.NormalizeNameRealm(name)
        if not want then return nil, "invalid_name" end
        local found = nil
        for _, m in ipairs(world.guild.members) do
            if string.lower(m.name) == string.lower(want) then
                if found then return nil, "ambiguous_name" end
                found = m
            end
        end
        if not found then return nil, "not_a_member" end
        if type(found.guid) ~= "string" or found.guid == "" then
            return {
                name = found.name,
                guid = nil,
                rankOrder = found.rankOrder,
                guildKey = "club:" .. tostring(world.guild.clubId),
            }, nil
        end
        return {
            name = found.name,
            guid = found.guid,
            rankOrder = found.rankOrder,
            guildKey = "club:" .. tostring(world.guild.clubId),
            clubId = tostring(world.guild.clubId),
        }
    end,
    IsGuildMember = function(name)
        local m = SF.GuildGossip.GetGuildMember(name)
        return m ~= nil and type(m.guid) == "string"
    end,
    Hash32 = function(s)
        s = tostring(s or "")
        local h = 5381
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
        return h
    end,
    Init = function() end,
    RegisterProvider = function(spec)
        SF.GuildGossip._providers[spec.id] = { spec = spec, enabled = true, index = { buildComplete = false, dirty = true, byId = {} } }
        return true
    end,
    SetProviderEnabled = function() end,
    GetProvider = function(id) return SF.GuildGossip._providers[id] end,
    NotifyProviderChanged = function()
        world.providerChanged = world.providerChanged + 1
    end,
    IndexUpsert = function(index, recordId, versionFp)
        index.byId = index.byId or {}
        index.byId[tostring(recordId)] = { versionFp = tostring(versionFp or "") }
        return true, "added"
    end,
    IndexRemove = function(index, recordId)
        if index and index.byId then index.byId[tostring(recordId)] = nil end
        return true
    end,
    BumpIndexEpoch = function(index)
        if type(index) == "table" then
            index.epoch = (tonumber(index.epoch) or 0) + 1
            index.byId = {}
            index.buildComplete = false
            index.dirty = true
        end
    end,
}

local function loadModule(path)
    local f, err = loadfile(path)
    if not f then error("loadfile failed: " .. path .. " :: " .. tostring(err)) end
    f(addonName, SF)
end

loadModule("SpectrumFederation/modules/GuildOfficer/Policy.lua")
loadModule("SpectrumFederation/modules/GuildOfficer/Gossip.lua")
loadModule("SpectrumFederation/modules/GuildInfo/State.lua")
loadModule("SpectrumFederation/modules/GuildInfo/Cleanup.lua")
loadModule("SpectrumFederation/modules/GuildInfo/Authority.lua")
loadModule("SpectrumFederation/modules/GuildInfo/Operations.lua")
loadModule("SpectrumFederation/modules/GuildInfo/Roster.lua")
loadModule("SpectrumFederation/modules/GuildInfo/Gossip.lua")

local GO = SF.GuildOfficer
local GI = SF.GuildInfo

local function setActor(name, guid, rankOrder)
    world.unitName = name:match("^([^-]+)") or name
    world.unitGuid = guid
    for _, m in ipairs(world.guild.members) do
        if m.guid == guid then
            m.rankOrder = rankOrder or m.rankOrder
            m.name = name
            return
        end
    end
end

local function resetDB()
    SpectrumFederationDB = {}
    world.providerChanged = 0
    world.timers = 0
    world.impersonationActive = false
    world.guild.inGuild = true
    world.guild.clubId = 42
    world.guild.rosterComplete = true
    world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
        { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true },
        { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
    }
    setActor("Alice-Garona", "Player-1-Alice", 1)
    SF.GuildGossip._providers = {}
    GO:Initialize(SpectrumFederationDB)
    GI:Initialize(SpectrumFederationDB)
end

local function policy()
    return select(1, GO:GetStoredPolicy("club:42"))
end

local function wireFor(body)
    local normalized = assert(GO.NormalizePolicy(body))
    return {
        id = GO.RECORD_ID,
        versionFp = GO.PolicyVersionFp(normalized),
        body = {
            kind = "guild-officer-policy",
            schema = GO.PROVIDER_SCHEMA,
            guildKey = normalized.guildKey,
            threshold = normalized.threshold,
            baseThreshold = normalized.baseThreshold,
            revN = normalized.revN,
            revW = normalized.revW,
            at = normalized.at,
        },
    }
end

---------------------------------------------------------------------------
-- Bootstrap, pending sync, and Guild Master recovery
---------------------------------------------------------------------------

resetDB()

do
    local view = GO:GetView()
    assertEq(view.status, "unknown", "empty cache is unknown")
    assertEq(view.canEdit, false, "unknown policy cannot be edited")
    assertEq(view.canBootstrap, true, "Guild Master can bootstrap an unknown policy")
    assertEq(select(1, GO:GetEstablishedThreshold()), nil, "unknown threshold is nil")
    local caps = GI:GetCapabilities()
    assertEq(caps.canRead, true, "members can read Guild Info while policy is unknown")
    assertEq(caps.canEdit, false, "Guild Info edits wait for a policy")
    assertEq(caps.reason, "policy_unknown", "Guild Info reports policy_unknown")
    local status, reason = GI:AssignAlt("Alice-Garona", "Bob-Garona", {})
    assertEq(status, "rejected", "assign rejected while policy is unknown")
    assertEq(reason, "policy_unknown", "assign reason is policy_unknown")
    setActor("Carol-Garona", "Player-1-Carol", 3)
    assertEq(select(1, GO:Bootstrap()), "rejected", "non-GM cannot bootstrap")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(select(1, GO:Bootstrap()), "accepted", "Guild Master bootstrap accepted")
    local stored = policy()
    assertEq(stored.threshold, 3, "default threshold is 3")
    assertEq(stored.baseThreshold, 0, "bootstrap base is 0")
    assertEq(select(1, GO:Bootstrap()), "rejected", "bootstrap does not overwrite a valid policy")
    assertEq(GO:GetView().canEdit, true, "GM can edit after bootstrap")
    assertEq(GI:GetCapabilities().canEdit, true, "Guild Info edit follows the established policy")
end

do
    resetDB()
    GO:Bootstrap()
    local stored = policy()
    stored.threshold = 99
    SpectrumFederationDB.guildOfficer.guilds["club:42"] = stored
    local view = GO:GetView()
    assertEq(view.status, "invalid", "out-of-range stored policy is invalid")
    assertEq(view.canEdit, false, "invalid policy is not editable")
    assertEq(view.canBootstrap, true, "Guild Master can recover an invalid policy")
    setActor("Bob-Garona", "Player-1-Bob", 2)
    assertEq(select(1, GO:Bootstrap()), "rejected", "non-GM cannot recover")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(select(1, GO:Bootstrap()), "accepted", "Guild Master recovery accepted")
    assertEq(policy().threshold, 3, "recovery installs the default threshold")
    assertTrue(policy().revN > 1, "recovery advances the revision")
end

---------------------------------------------------------------------------
-- Same-base concurrency, self-restrict, and rank changes
---------------------------------------------------------------------------

do
    local left = {
        guildKey = "club:42", threshold = 3, baseThreshold = 3,
        revN = 4, revW = "aaaaaaaaaaaaaaaaaaaaaaaa", at = 1,
    }
    local tighter = {
        guildKey = "club:42", threshold = 2, baseThreshold = 3,
        revN = 4, revW = "bbbbbbbbbbbbbbbbbbbbbbbb", at = 1,
    }
    local wider = {
        guildKey = "club:42", threshold = 4, baseThreshold = 3,
        revN = 4, revW = "cccccccccccccccccccccccc", at = 1,
    }
    local status, merged, detail = GO.MergePolicies(left, tighter)
    assertEq(status, "accepted", "more restrictive same-revision edit wins")
    assertEq(detail, "restrictive", "restrictive detail")
    assertEq(merged.threshold, 2, "winner threshold is 2")
    status, merged, detail = GO.MergePolicies(tighter, wider)
    assertEq(status, "duplicate", "wider same-revision edit loses")
    assertEq(merged.threshold, 2, "local restrictive threshold stays")
    local same = {
        guildKey = "club:42", threshold = 2, baseThreshold = 3,
        revN = 4, revW = "000000000000000000000000", at = 1,
    }
    status, merged, detail = GO.MergePolicies(tighter, same)
    assertEq(status, "accepted", "equal threshold breaks ties on writer nonce")
    assertEq(detail, "tiebreak", "tiebreak detail")
    local newer = {
        guildKey = "club:42", threshold = 3, baseThreshold = 2,
        revN = 5, revW = "dddddddddddddddddddddddd", at = 2,
    }
    status, merged, detail = GO.MergePolicies(tighter, newer)
    assertEq(status, "accepted", "higher revision replaces")
    assertEq(detail, "newer", "newer detail")
    assertEq(merged.threshold, 3, "deliberate widen is the later revision")
    status = select(1, GO.MergePolicies(newer, tighter))
    assertEq(status, "duplicate", "lower revision is stale")
    status, merged, detail = GO.MergePolicies(nil, tighter)
    assertEq(status, "accepted", "empty cache catches up")
    assertEq(detail, "catchup", "catchup detail")
end

do
    resetDB()
    GO:Bootstrap()
    setActor("Carol-Garona", "Player-1-Carol", 3)
    local before = policy().revN
    assertEq(select(1, GO:CommitThreshold(2)), "accepted", "rank 3 can restrict the previous threshold")
    assertEq(policy().threshold, 2, "self-restrict stored threshold is 2")
    assertEq(policy().baseThreshold, 3, "self-restrict records the previous threshold")
    assertEq(policy().revN, before + 1, "self-restrict advances revision")
    assertEq(select(1, GO:CommitThreshold(3)), "rejected", "rank 3 loses edit after restricting to 2")
    assertEq(GO:GetView().canEdit, false, "view denies the self-restricted officer")
    assertEq(GI:GetCapabilities().canEdit, false, "Guild Info denies the self-restricted officer")
    setActor("Bob-Garona", "Player-1-Bob", 2)
    assertEq(select(1, GO:CommitThreshold(3)), "accepted", "remaining officer can widen again")
    assertEq(policy().threshold, 3, "widened threshold restored")
    setActor("Dave-Garona", "Player-1-Dave", 4)
    assertEq(select(1, GO:CommitThreshold(4)), "rejected", "rank 4 cannot change the threshold")
    assertEq(GI:GetCapabilities().canEdit, false, "rank 4 cannot edit Guild Info")
end

do
    resetDB()
    GO:Bootstrap()
    local rev = policy().revN
    assertEq(select(1, GO:CommitThreshold(3, { expectedRevN = rev })), "accepted", "same threshold is a noop")
    assertEq(policy().revN, rev, "noop does not advance revision")
    assertEq(select(1, GO:CommitThreshold(2, { expectedRevN = rev + 9 })), "rejected", "stale confirmation is rejected")
    world.impersonationActive = true
    assertEq(select(1, GO:CommitThreshold(2)), "rejected", "preview blocks officer edits")
    assertEq(GI:GetCapabilities().canEdit, false, "preview blocks Guild Info edits")
    world.impersonationActive = false
end

---------------------------------------------------------------------------
-- Remote admission, guild switch, roster uncertainty, rank-list cap
---------------------------------------------------------------------------

do
    resetDB()
    GO:Bootstrap()
    local localPolicy = policy()
    local remote = {
        guildKey = "club:42",
        threshold = 2,
        baseThreshold = localPolicy.threshold,
        revN = localPolicy.revN + 1,
        revW = "eeeeeeeeeeeeeeeeeeeeeeee",
        at = 3,
    }
    local carol = SF.GuildGossip.GetGuildMember("Carol-Garona")
    local status = select(1, GO:ApplyRemotePolicy(remote, carol))
    assertEq(status, "accepted", "rank 3 remote restrict against the previous threshold is accepted")
    assertEq(policy().threshold, 2, "remote restrict is stored")
    local dave = SF.GuildGossip.GetGuildMember("Dave-Garona")
    local rejected = {
        guildKey = "club:42", threshold = 1, baseThreshold = 2,
        revN = policy().revN + 1, revW = "ffffffffffffffffffffffff", at = 4,
    }
    status = select(1, GO:ApplyRemotePolicy(rejected, dave))
    assertEq(status, "rejected", "rank 4 remote edit is rejected")
    assertEq(policy().threshold, 2, "rejected remote edit does not change storage")
    local alice = SF.GuildGossip.GetGuildMember("Alice-Garona")
    local widen = {
        guildKey = "club:42", threshold = 3, baseThreshold = 2,
        revN = policy().revN + 1, revW = "111111111111111111111111", at = 5,
    }
    status = select(1, GO:ApplyRemotePolicy(widen, alice))
    assertEq(status, "accepted", "Guild Master remote widen is accepted")
    local provider = SF.GuildGossip.GetProvider(GO.PROVIDER_ID)
    local daveWire = wireFor({
        guildKey = "club:42",
        threshold = 1,
        baseThreshold = 3,
        revN = policy().revN + 1,
        revW = "222222222222222222222222",
        at = 6,
    })
    local wireStatus = select(1, provider.spec.ValidateAndApply(daveWire, { sender = "Dave-Garona" }))
    assertEq(wireStatus, "rejected", "gossip rejects an unauthorized sender")
end

do
    resetDB()
    GO:Bootstrap()
    local established = policy()
    local dave = SF.GuildGossip.GetGuildMember("Dave-Garona")
    local forged = {
        guildKey = "club:42",
        threshold = 4,
        baseThreshold = 4,
        revN = established.revN + 1,
        revW = "444444444444444444444444",
        at = 9,
    }
    local status = select(1, GO:ApplyRemotePolicy(forged, dave))
    assertEq(status, "rejected", "rank 4 fabricated predecessor is rejected")
    assertEq(policy().threshold, 3, "fabricated predecessor does not change the threshold")
    assertEq(policy().revN, established.revN, "fabricated predecessor does not advance the revision")
    local alice = SF.GuildGossip.GetGuildMember("Alice-Garona")
    local replay = {
        guildKey = "club:42",
        threshold = 1,
        baseThreshold = 0,
        revN = established.revN + 3,
        revW = "777777777777777777777777",
        at = 9,
    }
    status = select(1, GO:ApplyRemotePolicy(replay, alice))
    assertEq(status, "rejected", "bootstrap replay does not replace a known policy")
    assertEq(policy().threshold, 3, "known policy survives a bootstrap replay")
    setActor("Carol-Garona", "Player-1-Carol", 3)
    assertEq(select(1, GO:CommitThreshold(2)), "accepted", "rank 3 officer can still tighten locally")
    local afterLocal = policy()
    local bob = SF.GuildGossip.GetGuildMember("Bob-Garona")
    local concurrent = {
        guildKey = "club:42",
        threshold = 1,
        baseThreshold = afterLocal.baseThreshold,
        revN = afterLocal.revN,
        revW = "555555555555555555555555",
        at = 10,
    }
    status = select(1, GO:ApplyRemotePolicy(concurrent, bob))
    assertEq(status, "accepted", "same-base concurrent edit keeps the more restrictive threshold")
    assertEq(policy().threshold, 1, "restrictive concurrent threshold is stored")
    world.guild.clubId = 99
    local carol = SF.GuildGossip.GetGuildMember("Carol-Garona")
    local catchup = {
        guildKey = "club:99",
        threshold = 3,
        baseThreshold = 3,
        revN = 4,
        revW = "666666666666666666666666",
        at = 11,
    }
    status = select(1, GO:ApplyRemotePolicy(catchup, carol))
    assertEq(status, "accepted", "empty client accepts a normal officer catch-up")
    assertEq(select(1, GO:GetStoredPolicy("club:99")).threshold, 3, "catch-up threshold is stored")
    assertEq(select(1, GO:GetStoredPolicy("club:42")).threshold, 1, "catch-up does not replace the other guild")
    local forgedCold = {
        guildKey = "club:99",
        threshold = 4,
        baseThreshold = 4,
        revN = 99,
        revW = "888888888888888888888888",
        at = 12,
    }
    status = select(1, GO:ApplyRemotePolicy(forgedCold, dave))
    assertEq(status, "rejected", "empty client rejects a rank-4 fabricated first policy")
    assertEq(select(1, GO:GetStoredPolicy("club:99")).threshold, 3,
        "cold-join forgery does not replace the officer catch-up")
    assertEq(select(1, GO:GetStoredPolicy("club:99")).revN, 4,
        "cold-join forgery does not advance the revision")
    world.guild.clubId = 42
end

do
    -- GM bootstraps, officer holds the record, empty client learns it from the officer.
    resetDB()
    GO:Bootstrap()
    local boot = policy()
    assertEq(boot.baseThreshold, 0, "bootstrap base is zero")
    assertEq(boot.threshold, 3, "bootstrap uses the default threshold")
    local relayBody = {
        guildKey = boot.guildKey,
        threshold = boot.threshold,
        baseThreshold = boot.baseThreshold,
        revN = boot.revN,
        revW = boot.revW,
        at = boot.at,
    }
    resetDB()
    assertNil(policy(), "fresh client starts without a policy")
    setActor("Bob-Garona", "Player-1-Bob", 2)
    local bob = SF.GuildGossip.GetGuildMember("Bob-Garona")
    local status = select(1, GO:ApplyRemotePolicy(relayBody, bob))
    assertEq(status, "accepted", "officer relays a GM bootstrap while the GM is offline")
    assertEq(policy().threshold, 3, "relayed bootstrap threshold is stored")
    assertEq(policy().baseThreshold, 0, "relayed bootstrap base is preserved")
    assertEq(policy().revN, boot.revN, "relayed bootstrap revision is preserved")
    setActor("Dave-Garona", "Player-1-Dave", 4)
    local dave = SF.GuildGossip.GetGuildMember("Dave-Garona")
    status = select(1, GO:ApplyRemotePolicy({
        guildKey = "club:42",
        threshold = 4,
        baseThreshold = 0,
        revN = boot.revN + 1,
        revW = "999999999999999999999999",
        at = 13,
    }, dave))
    assertEq(status, "rejected", "rank 4 cannot replace a known relayed policy")
    assertEq(policy().threshold, 3, "relayed policy survives a non-officer attempt")
    setActor("Alice-Garona", "Player-1-Alice", 1)
end

do
    resetDB()
    GO:Bootstrap()
    local saved = policy().threshold
    world.guild.clubId = 99
    local view = GO:GetView()
    assertEq(view.status, "unknown", "another guild does not inherit the policy")
    assertEq(view.canEdit, false, "unknown guild policy cannot be edited")
    assertEq(SpectrumFederationDB.guildOfficer.guilds["club:42"].threshold, saved,
        "switching guilds leaves the previous policy stored")
    world.guild.clubId = 42
    assertEq(GO:GetView().status, "established", "returning restores the stored policy")
    world.guild.rosterComplete = false
    view = GO:GetView()
    assertEq(view.canEdit, false, "roster uncertainty disables editing")
    assertEq(select(1, GO:CommitThreshold(2)), "rejected", "commit fails closed while the roster is incomplete")
    world.guild.rosterComplete = true
    assertEq(GO:GetView().canEdit, true, "editing returns when the roster is ready")
end

do
    resetDB()
    GO:Bootstrap()
    assertEq(policy().threshold, 3, "stored threshold before rank-list shrink")
    world.guild.ranks = { "Guild Master", "Member" }
    local view = GO:GetView()
    assertEq(view.threshold, 3, "stored threshold is not rewritten when ranks shrink")
    assertEq(view.effectiveThreshold, 2, "effective threshold caps to the last rank")
    assertEq(view.capped, true, "cap is visible")
    setActor("Bob-Garona", "Player-1-Bob", 2)
    assertEq(GO:RankMeetsThreshold(2, 2), true, "last remaining rank still meets the cap")
    assertEq(GO:GetView().canEdit, true, "capped last rank can edit")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(select(1, GO:Bootstrap()), "rejected", "cap does not let bootstrap overwrite a valid policy")
    assertEq(policy().threshold, 3, "stored threshold remains 3")
end

---------------------------------------------------------------------------
-- Guild Info authorization and cleanup independence
---------------------------------------------------------------------------

do
    resetDB()
    GO:Bootstrap()
    SpectrumFederationDB.guildSupplies = { schemaVersion = 1, marker = "keep" }
    local status = select(1, GI:AssignAlt("Alice-Garona", "Bob-Garona", {}))
    assertEq(status, "accepted", "officer assign accepted")
    setActor("Carol-Garona", "Player-1-Carol", 3)
    local member = SF.GuildGossip.GetGuildMember("Carol-Garona")
    assertEq(select(1, GI.SenderHasEditorAuthority(member)), true, "rank 3 remote sender is an editor")
    status = select(1, GI:CleanupHistory({}))
    assertTrue(status == "accepted" or status == "duplicate", "officer cleanup is allowed: " .. tostring(status))
    assertEq(policy().threshold, 3, "cleanup does not replace the officer threshold")
    assertEq(SpectrumFederationDB.guildSupplies.marker, "keep", "cleanup does not touch Guild Supplies")
    assertEq(GI:GetCharacterRole("Player-1-Bob"), "alt", "cleanup keeps the assignment")
    GO:CommitThreshold(2)
    member = SF.GuildGossip.GetGuildMember("Carol-Garona")
    assertEq(select(1, GI.SenderHasEditorAuthority(member)), false, "remote Guild Info auth follows the new threshold")
    status = select(1, GI:AssignAlt("Alice-Garona", "Dave-Garona", {}))
    assertEq(status, "rejected", "local Guild Info mutation fails after the threshold drops")
    setActor("Alice-Garona", "Player-1-Alice", 1)
    assertEq(policy().threshold, 2, "failed Guild Info mutation does not change the officer policy")
end

---------------------------------------------------------------------------
-- Reload, catch-up, and idle bounds
---------------------------------------------------------------------------

do
    resetDB()
    GO:Bootstrap()
    GO:CommitThreshold(2)
    local saved = SpectrumFederationDB
    local threshold = policy().threshold
    local rev = policy().revN
    SF.GuildOfficer = nil
    loadModule("SpectrumFederation/modules/GuildOfficer/Policy.lua")
    loadModule("SpectrumFederation/modules/GuildOfficer/Gossip.lua")
    GO = SF.GuildOfficer
    GO:Initialize(saved)
    local restored = select(1, GO:GetStoredPolicy("club:42"))
    assertEq(restored.threshold, threshold, "reload restores the stored threshold")
    assertEq(restored.revN, rev, "reload restores the revision")
    local catches = {
        guildKey = "club:99", threshold = 1, baseThreshold = 0,
        revN = 1, revW = "333333333333333333333333", at = 1,
    }
    local status, merged = GO.MergePolicies(nil, catches)
    assertEq(status, "accepted", "catch-up accepts a first valid record")
    assertEq(merged.guildKey, "club:99", "catch-up keeps the remote guild")
    GO.ResetIdleCounters()
    local before = world.providerChanged
    local beforeTimers = world.timers
    for _ = 1, 25 do
        GO:GetView()
    end
    assertEq(GO._readCount, 25, "repeated views are counted")
    assertEq(world.providerChanged, before, "repeated views do not notify gossip")
    assertEq(world.timers, beforeTimers, "repeated views schedule no timers")
end

---------------------------------------------------------------------------
-- Loot Helper one-time admin grant
---------------------------------------------------------------------------

function SF:GetPlayerFullIdentifier()
    return "Alice-Garona"
end
function SF:GetPlayerClass()
    return "MAGE"
end

loadModule("SpectrumFederation/modules/LootHelper/Members.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootLogValidators.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootLogs.lua")
loadModule("SpectrumFederation/modules/LootHelper/Identity.lua")
loadModule("SpectrumFederation/modules/LootHelper/SpecWeapons.lua")
loadModule("SpectrumFederation/modules/LootHelper/Bis.lua")
loadModule("SpectrumFederation/modules/LootHelper/Profiles.lua")

local function newProfile()
    local profile = SF.LootProfile.new("Officer Grant")
    assertTrue(profile ~= nil, "profile created")
    return profile
end

local function addNamed(profile, name, opts)
    local member = SF.Member.new(name, "member", "WARRIOR")
    assertTrue(member ~= nil, "member constructed " .. name)
    return profile:AddMember(member, opts), member
end

do
    resetDB()
    GO = SF.GuildOfficer
    GI = SF.GuildInfo
    GO:Initialize(SpectrumFederationDB)
    local profile = newProfile()
    assertEq(#profile._adminUsers, 1, "profile creation does not grant extra admins")
    assertEq(profile:IsAdminMemberId("Bob-Garona"), false, "creation does not scan Bob")
    assertEq(select(1, GO:Bootstrap()), "accepted", "loot grant bootstrap")
    addNamed(profile, "Bob-Garona")
    assertEq(profile:IsAdminMemberId("Bob-Garona"), true, "eligible new officer is granted admin once")
    local adminsBefore = #profile._adminUsers
    addNamed(profile, "Bob-Garona")
    assertEq(#profile._adminUsers, adminsBefore, "adding an existing member does not grant again")
    addNamed(profile, "Dave-Garona")
    assertEq(profile:IsAdminMemberId("Dave-Garona"), false, "ineligible rank stays a regular member")
    addNamed(profile, "Zoe-Garona")
    assertEq(profile:IsAdminMemberId("Zoe-Garona"), false, "non-member stays a regular member")
end

do
    resetDB()
    GO:Initialize(SpectrumFederationDB)
    GO:Bootstrap()
    local profile = newProfile()
    addNamed(profile, "Carol-Garona", { import = true })
    assertEq(profile:IsAdminMemberId("Carol-Garona"), false, "import does not grant admin")
    addNamed(profile, "Bob-Garona", { replay = true })
    assertEq(profile:IsAdminMemberId("Bob-Garona"), false, "replay does not grant admin")
    addNamed(profile, "Bob-Garona", { skipOfficerGrant = true })
    assertEq(profile:IsAdminMemberId("Bob-Garona"), false, "explicit skip does not grant admin")
end

do
    resetDB()
    GO:Initialize(SpectrumFederationDB)
    local profile = newProfile()
    addNamed(profile, "Bob-Garona")
    assertEq(profile:IsAdminMemberId("Bob-Garona"), false, "unknown policy does not grant admin")
    GO:Bootstrap()
    local fresh = newProfile()
    world.guild.members[#world.guild.members + 1] = {
        name = "Twin-Garona", guid = "Player-1-TwinA", rankOrder = 1, online = true,
    }
    world.guild.members[#world.guild.members + 1] = {
        name = "Twin-Garona", guid = "Player-1-TwinB", rankOrder = 1, online = true,
    }
    addNamed(fresh, "Twin-Garona")
    assertEq(fresh:IsAdminMemberId("Twin-Garona"), false, "ambiguous roster name does not grant admin")
    local noguid = newProfile()
    world.guild.members = {
        { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
        { name = "Bob-Garona", guid = "", rankOrder = 1, online = true },
    }
    addNamed(noguid, "Bob-Garona")
    assertEq(noguid:IsAdminMemberId("Bob-Garona"), false, "missing guid does not grant admin")
end

do
    resetDB()
    GO:Initialize(SpectrumFederationDB)
    GO:Bootstrap()
    local profile = newProfile()
    addNamed(profile, "Bob-Garona")
    assertEq(profile:IsAdminMemberId("Bob-Garona"), true, "grant happened before removal")
    assertEq(select(1, profile:RemoveAdminMemberId("Bob-Garona")), true, "manual admin removal")
    assertEq(profile:IsAdminMemberId("Bob-Garona"), false, "admin removed")
    profile:RemoveMemberById("Bob-Garona")
    addNamed(profile, "Bob-Garona")
    assertEq(profile:IsAdminMemberId("Bob-Garona"), false, "manual removal is not granted again")
    local later = newProfile()
    addNamed(later, "Carol-Garona")
    assertEq(later:IsAdminMemberId("Carol-Garona"), true, "Carol granted while eligible")
    for _, m in ipairs(world.guild.members) do
        if m.guid == "Player-1-Carol" then m.rankOrder = 5 end
    end
    assertEq(later:IsAdminMemberId("Carol-Garona"), true, "later demotion does not revoke admin")
    GO:CommitThreshold(1)
    assertEq(later:IsAdminMemberId("Dave-Garona"), false, "threshold change does not scan existing members")
    assertEq(profile:IsAdminMemberId("Alice-Garona"), true, "owner admin is preserved")
end

---------------------------------------------------------------------------
-- Real Guild Gossip index: replacement must keep the current policy exported
---------------------------------------------------------------------------

do
    loadModule("SpectrumFederation/modules/GuildGossip/01_Constants.lua")
    loadModule("SpectrumFederation/modules/GuildGossip/02_Util.lua")
    loadModule("SpectrumFederation/modules/GuildGossip/07_Index.lua")
    resetDB()
    local GG = SF.GuildGossip
    local provider = GG.GetProvider(GO.PROVIDER_ID)
    local index = GG.CreateIndex()
    provider.index = index
    local spec = provider.spec

    local function countRows()
        local n = 0
        for _ in pairs(index.byId or {}) do
            n = n + 1
        end
        return n
    end

    local function drive()
        local steps = 0
        local more = true
        while more do
            steps = steps + 1
            if steps > 6 then
                fail("officer index did not converge")
                return steps
            end
            more = spec.EnsureIndex(index, { indexEntries = 8 }) and true or false
        end
        assertEq(index.buildComplete, true, "converged index is complete")
        assertEq(index.dirty and true or false, false, "converged index is idle")
        return steps
    end

    local function assertCurrent(message)
        local stored = select(1, GO:GetStoredPolicy("club:" .. tostring(world.guild.clubId)))
        local row = index.byId[GO.RECORD_ID]
        if not stored then
            assertNil(row, message .. " has no export row")
            assertNil(spec.GetRecordBody(GO.RECORD_ID), message .. " has no export body")
            assertEq(countRows(), 0, message .. " exports nothing")
            return
        end
        assertTrue(row ~= nil, message .. " row present")
        assertEq(row.versionFp, GO.PolicyVersionFp(stored), message .. " fingerprint")
        local body = spec.GetRecordBody(GO.RECORD_ID)
        assertEq(body and body.body and body.body.threshold, stored.threshold, message .. " export threshold")
        assertEq(body and body.versionFp, row.versionFp, message .. " export fingerprint")
        assertEq(countRows(), 1, message .. " exports one row")
    end

    GO:Bootstrap()
    local steps = drive()
    assertTrue(steps <= 3, "bootstrap index converges quickly: " .. tostring(steps))
    assertCurrent("bootstrap")

    assertEq(select(1, GO:CommitThreshold(2)), "accepted", "index edit 1")
    steps = drive()
    assertTrue(steps >= 2, "a revision rebuilds through the real replacement pass: " .. tostring(steps))
    assertCurrent("one edit")

    assertEq(select(1, GO:CommitThreshold(1)), "accepted", "index edit 2")
    drive()
    assertCurrent("second edit")
    assertEq(select(1, GO:CommitThreshold(3)), "accepted", "index edit 3")
    drive()
    assertCurrent("third edit")

    local localPolicy = select(1, GO:GetStoredPolicy("club:42"))
    local carol = GG.GetGuildMember("Carol-Garona")
    local remote = {
        guildKey = "club:42",
        threshold = 2,
        baseThreshold = localPolicy.threshold,
        revN = localPolicy.revN + 1,
        revW = "abababababababababababab",
        at = 20,
    }
    assertEq(select(1, GO:ApplyRemotePolicy(remote, carol)), "accepted", "remote adoption accepted")
    drive()
    assertCurrent("remote adoption")

    local epoch = index.epoch
    for _ = 1, 5 do
        local more = spec.EnsureIndex(index, { indexEntries = 8 })
        assertEq(more and true or false, false, "idle EnsureIndex does no further work")
    end
    assertEq(index.epoch, epoch, "idle EnsureIndex does not bump the epoch")
    assertCurrent("idle")

    world.guild.clubId = 99
    drive()
    assertCurrent("guild switch")
    world.guild.clubId = 42
    drive()
    assertCurrent("return to original guild")
end

---------------------------------------------------------------------------
-- Canonical envelope validation through production ApplyRecordToProvider
---------------------------------------------------------------------------

do
    SF.GuildGossip._providers = nil
    loadModule("SpectrumFederation/modules/GuildGossip/01_Constants.lua")
    loadModule("SpectrumFederation/modules/GuildGossip/02_Util.lua")
    loadModule("SpectrumFederation/modules/GuildGossip/07_Index.lua")
    loadModule("SpectrumFederation/modules/GuildGossip/08_Providers.lua")
    local GG = SF.GuildGossip
    GG.NotifyMeaningfulChange = GG.NotifyMeaningfulChange or function() end
    GG.MarkWorkPending = GG.MarkWorkPending or function() end
    GG.SyncGuildAdapterLifecycle = nil
    GG.IsGuildReady = function() return false end

    local function resetProviderDB()
        SpectrumFederationDB = {}
        world.providerChanged = 0
        world.timers = 0
        world.impersonationActive = false
        world.guild.inGuild = true
        world.guild.clubId = 42
        world.guild.rosterComplete = true
        world.guild.ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
        world.guild.members = {
            { name = "Alice-Garona", guid = "Player-1-Alice", rankOrder = 1, online = true },
            { name = "Bob-Garona", guid = "Player-1-Bob", rankOrder = 2, online = true },
            { name = "Carol-Garona", guid = "Player-1-Carol", rankOrder = 3, online = true },
            { name = "Dave-Garona", guid = "Player-1-Dave", rankOrder = 4, online = true },
        }
        setActor("Alice-Garona", "Player-1-Alice", 1)
        SF.GuildGossip._providers = { byId = {}, order = {}, activeCount = 0, discRotate = 0 }
        GO:Initialize(SpectrumFederationDB)
        GI:Initialize(SpectrumFederationDB)
    end

    resetProviderDB()
    assertTrue(type(GG.RegisterProvider) == "function", "production RegisterProvider is loaded")
    assertTrue(type(GG.ApplyRecordToProvider) == "function", "production ApplyRecordToProvider is loaded")
    local okReg = select(1, GO:EnsureGossipProvider())
    assertEq(okReg, true, "officer provider registers with production Gossip")
    local entry = GG.GetProvider(GO.PROVIDER_ID)
    assertTrue(entry ~= nil and entry.index ~= nil, "provider entry has an index")
    entry.index = GG.CreateIndex()

    local function indexCount()
        local n = 0
        for _ in pairs(entry.index.byId or {}) do
            n = n + 1
        end
        return n
    end

    local function driveExport()
        local more = true
        local steps = 0
        while more do
            steps = steps + 1
            if steps > 6 then
                fail("export index did not converge after ApplyRecordToProvider")
                return
            end
            more = entry.api.EnsureIndex(entry.index, { indexEntries = 8 }) and true or false
        end
    end

    GO:Bootstrap()
    driveExport()
    local before = policy()
    local beforeFp = GO.PolicyVersionFp(before)
    assertEq(indexCount(), 1, "bootstrap export has one indexed row")

    local badId = wireFor({
        guildKey = "club:42",
        threshold = 2,
        baseThreshold = before.threshold,
        revN = before.revN + 1,
        revW = "cccccccccccccccccccccccc",
        at = 30,
    })
    badId.id = "go-p:forged"
    local st = select(1, GG.ApplyRecordToProvider(entry, badId, { sender = "Carol-Garona" }))
    assertEq(st, "rejected", "ApplyRecordToProvider rejects a noncanonical id")
    assertEq(policy().revN, before.revN, "bad id does not mutate the policy")
    assertNil(entry.index.byId["go-p:forged"], "bad id is not indexed")
    assertEq(indexCount(), 1, "bad id leaves the canonical index alone")

    local badFp = wireFor({
        guildKey = "club:42",
        threshold = 2,
        baseThreshold = before.threshold,
        revN = before.revN + 1,
        revW = "dddddddddddddddddddddddd",
        at = 31,
    })
    badFp.versionFp = "deadbeef"
    st = select(1, GG.ApplyRecordToProvider(entry, badFp, { sender = "Carol-Garona" }))
    assertEq(st, "rejected", "ApplyRecordToProvider rejects a mismatched fingerprint")
    assertEq(policy().revN, before.revN, "bad fingerprint does not mutate the policy")
    assertEq(entry.index.byId[GO.RECORD_ID].versionFp, beforeFp,
        "bad fingerprint does not replace the indexed version")
    assertEq(indexCount(), 1, "bad fingerprint leaves one index row")

    local good = wireFor({
        guildKey = "club:42",
        threshold = 2,
        baseThreshold = before.threshold,
        revN = before.revN + 1,
        revW = "eeeeeeeeeeeeeeeeeeeeeeee",
        at = 32,
    })
    st = select(1, GG.ApplyRecordToProvider(entry, good, { sender = "Carol-Garona" }))
    assertEq(st, "accepted", "ApplyRecordToProvider accepts a canonical officer update")
    assertEq(policy().threshold, 2, "canonical update mutates the stored threshold")
    driveExport()
    assertEq(indexCount(), 1, "accepted update keeps one canonical index row")
    assertEq(entry.index.byId[GO.RECORD_ID].versionFp, GO.PolicyVersionFp(policy()),
        "accepted update indexes the durable fingerprint")
    local export = entry.api.GetRecordBody(GO.RECORD_ID)
    assertEq(export and export.body and export.body.threshold, 2, "export body matches the update")
    assertEq(export and export.id, GO.RECORD_ID, "export keeps the canonical id")
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
