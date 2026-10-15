-- Event-driven guild membership/readiness adapter.
-- Fail closed when roster/guild identity is incomplete. Never infer membership
-- from an empty roster or a matching name alone. Party/raid roster is not used.
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

GG._guild = GG._guild or {
    ready = false,
    inGuild = false,
    scopeId = nil, -- stable guild scope string
    lastVerifiedScopeId = nil,
    guildName = nil,
    guildRealm = nil,
    clubId = nil,
    members = {}, -- [normalizedName] = { online = bool, lastSeen = t }
    generation = 0,
    coalescePending = false,
    coalesceGen = 0, -- invalidates deferred RefreshGuildState after shutdown
    listening = false, -- event/roster work only while an active provider needs it
    frame = nil,
}

local function requestRoster()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

local function computeScopeId(guildName, guildRealm, clubId)
    if clubId ~= nil and tostring(clubId) ~= "" then
        return "club:" .. tostring(clubId)
    end
    if type(guildName) == "string" and guildName ~= "" then
        local realm = tostring(guildRealm or "")
        realm = realm:gsub("%s+", "")
        return "name:" .. guildName .. "|" .. realm
    end
    return nil
end

function GG.GetGuildGeneration()
    return GG._guild.generation or 0
end

function GG.GetGuildScopeId()
    local g = GG._guild
    if not g.ready or not g.inGuild then
        return nil
    end
    return g.scopeId
end

function GG.IsGuildReady()
    local g = GG._guild
    return g.ready == true and g.inGuild == true and type(g.scopeId) == "string"
end

function GG.IsGuildMember(name)
    if not GG.IsGuildReady() then
        return false
    end
    local norm = GG.NormalizePlayer(name)
    if not norm then
        return false
    end
    local entry = GG._guild.members[norm] or GG._guild.members[string.lower(norm)]
    if not entry then
        -- Case-insensitive scan (bounded by roster size).
        local lower = string.lower(norm)
        for k, v in pairs(GG._guild.members) do
            if string.lower(k) == lower then
                return true, v
            end
        end
        return false
    end
    return true, entry
end

function GG.RefreshGuildState()
    local g = GG._guild
    local inGuild = (IsInGuild and IsInGuild()) and true or false
    if not inGuild then
        if g.inGuild or g.ready or g.scopeId then
            g.inGuild = false
            g.ready = false
            g.scopeId = nil
            g.guildName = nil
            g.guildRealm = nil
            g.clubId = nil
            g.members = {}
            g.generation = (g.generation or 0) + 1
            if GG.OnGuildInvalidated then
                GG.OnGuildInvalidated("left_or_missing")
            end
        end
        return
    end

    local guildName, _, _, guildRealm = nil, nil, nil, nil
    if GetGuildInfo then
        guildName, _, _, guildRealm = GetGuildInfo("player")
    end
    local clubId = nil
    if C_Club and C_Club.GetGuildClubId then
        clubId = C_Club.GetGuildClubId()
    end

    local scopeId = computeScopeId(guildName, guildRealm, clubId)
    if not scopeId then
        -- Guild claimed but identity incomplete — wait/fail closed.
        if g.ready and GG.OnGuildInvalidated then
            GG.OnGuildInvalidated("identity_incomplete")
        end
        g.inGuild = true
        g.ready = false
        g.scopeId = nil
        g.members = {}
        return
    end

    if not GetNumGuildMembers or not GetGuildRosterInfo then
        if g.ready and GG.OnGuildInvalidated then
            GG.OnGuildInvalidated("roster_unavailable")
        end
        g.inGuild = true
        g.ready = false
        g.scopeId = nil
        g.members = {}
        return
    end

    local total = select(1, GetNumGuildMembers())
    total = tonumber(total) or 0
    -- An empty total while claiming guild membership is treated as not ready
    -- (roster not yet available). Never treat empty as "zero members authenticated".
    if total <= 0 then
        if g.ready and GG.OnGuildInvalidated then
            GG.OnGuildInvalidated("roster_incomplete")
        end
        g.inGuild = true
        g.ready = false
        g.scopeId = nil
        g.members = {}
        requestRoster()
        return
    end

    local members = {}
    local now = GG._Now()
    for i = 1, total do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        local norm = GG.NormalizePlayer(name)
        if norm then
            members[norm] = { online = isOnline and true or false, lastSeen = now }
        end
    end

    local wasReady = g.ready == true
    local scopeChanged = g.lastVerifiedScopeId and g.lastVerifiedScopeId ~= scopeId
    g.inGuild = true
    g.ready = true
    g.scopeId = scopeId
    -- Preserve lastVerifiedScopeId across leave/incomplete gaps so a later
    -- verified guild can still detect a true scope transition.
    g.lastVerifiedScopeId = scopeId
    g.guildName = guildName
    g.guildRealm = guildRealm
    g.clubId = clubId
    g.members = members
    g.generation = (g.generation or 0) + 1

    if scopeChanged and GG.OnGuildInvalidated then
        GG.OnGuildInvalidated("scope_changed")
    end
    -- Restart initial discovery only on readiness recovery or verified scope change.
    -- Unchanged roster refreshes keep periodic discovery timing intact.
    local becameReady = (not wasReady) and g.ready
    if (becameReady or scopeChanged) and GG.OnGuildReady then
        GG.OnGuildReady()
    end
end

local function coalesceRefresh()
    local g = GG._guild
    -- Idle contract: no coalesced roster walks without an active provider.
    if not g.listening then
        return
    end
    if g.coalescePending then
        return
    end
    g.coalescePending = true
    local delay = 0.25
    local gen = (tonumber(g.coalesceGen) or 0)
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, function()
            -- Shutdown/reinit bumps coalesceGen; drop stale deferred work.
            if (tonumber(g.coalesceGen) or 0) ~= gen then
                return
            end
            if not g.listening then
                g.coalescePending = false
                return
            end
            g.coalescePending = false
            GG.RefreshGuildState()
        end)
    else
        g.coalescePending = false
        GG.RefreshGuildState()
    end
end

function GG.InitGuildAdapter()
    local g = GG._guild
    -- Mark listening before roster request/refresh so activation is a fresh verify.
    g.listening = true
    local function onEvent(_, event)
        if not GG._guild.listening then
            return
        end
        if event == "PLAYER_GUILD_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
            requestRoster()
            coalesceRefresh()
        elseif event == "GUILD_ROSTER_UPDATE" then
            coalesceRefresh()
        end
    end
    if g.frame then
        -- Reactivate a retained frame after Shutdown (named frames persist).
        if g.frame.UnregisterAllEvents then
            g.frame:UnregisterAllEvents()
        end
        if g.frame.RegisterEvent then
            g.frame:RegisterEvent("PLAYER_GUILD_UPDATE")
            g.frame:RegisterEvent("GUILD_ROSTER_UPDATE")
            g.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
        end
        if g.frame.SetScript then
            g.frame:SetScript("OnEvent", onEvent)
        end
        requestRoster()
        GG.RefreshGuildState()
        return
    end
    if not CreateFrame then
        GG.RefreshGuildState()
        return
    end
    local frame = CreateFrame("Frame", "SFGuildGossipGuildAdapter")
    frame:RegisterEvent("PLAYER_GUILD_UPDATE")
    frame:RegisterEvent("GUILD_ROSTER_UPDATE")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:SetScript("OnEvent", onEvent)
    g.frame = frame
    requestRoster()
    GG.RefreshGuildState()
end

function GG.ShutdownGuildAdapter()
    local g = GG._guild
    g.listening = false
    if g.frame then
        g.frame:UnregisterAllEvents()
        g.frame:SetScript("OnEvent", nil)
        -- Keep the named frame reference for Initialize reuse.
    end
    -- Invalidate any coalesced RefreshGuildState already scheduled via C_Timer.After.
    g.coalesceGen = (tonumber(g.coalesceGen) or 0) + 1
    g.coalescePending = false
    g.ready = false
    g.inGuild = false
    g.scopeId = nil
    g.members = {}
    g.generation = (g.generation or 0) + 1
    -- Preserve lastVerifiedScopeId across idle gaps so a later activation can
    -- still detect a true scope transition after guild changes while inactive.
end

-- Bind guild roster event work to the active-provider idle contract. Activation
-- always runs InitGuildAdapter for a fresh verified roster before auth/discovery;
-- idle clears cached membership so peers are not authorized from stale data.
function GG.SyncGuildAdapterLifecycle()
    local g = GG._guild
    if GG.HasActiveProvider and GG.HasActiveProvider() then
        if not g.listening then
            GG.InitGuildAdapter()
        end
        return
    end
    if g.listening or g.ready or g.inGuild or g.coalescePending
        or (g.members and next(g.members) ~= nil) then
        GG.ShutdownGuildAdapter()
    end
end

---------------------------------------------------------------------------
-- Demand-driven native identity/rank snapshot (no provider / no listeners).
-- Used by Guild Supplies (#385) and other dormant domain checks. Must never
-- mark transport ready, start discovery, or leave a permanent roster loop.
---------------------------------------------------------------------------

local function readActualClubId()
    if not (C_Club and C_Club.GetGuildClubId) then
        return nil
    end
    local clubId = C_Club.GetGuildClubId()
    if clubId == nil or clubId == 0 or clubId == "0" or clubId == "" then
        return nil
    end
    return tostring(clubId)
end

local function readGuildDisplay()
    local guildName, guildRealm = nil, nil
    if GetGuildInfo then
        local name, _, _, realm = GetGuildInfo("player")
        guildName, guildRealm = name, realm
    end
    return guildName, guildRealm
end

-- Normalize a native rank position to the locked 1-based guildRankOrder
-- convention (Guild Master = 1). Prefer C_GuildInfo.GetGuildRankOrder.
-- Zero-based legacy GetGuildRosterInfo rankIndex is converted exactly once.
local function normalizeRankOrder(guid, legacyRankIndex)
    if guid and C_GuildInfo and type(C_GuildInfo.GetGuildRankOrder) == "function" then
        local order = C_GuildInfo.GetGuildRankOrder(guid)
        order = tonumber(order)
        if order and order == math.floor(order) and order >= 1 then
            return order
        end
    end
    local idx = tonumber(legacyRankIndex)
    if idx and idx == math.floor(idx) and idx >= 0 then
        return idx + 1
    end
    return nil
end

--- Actual club-backed guild identity. Never persists or returns name: scopes.
-- @return table|nil identity, string|nil reason
function GG.GetGuildIdentity()
    local inGuild = (IsInGuild and IsInGuild()) and true or false
    if not inGuild then
        return nil, "not_in_guild"
    end
    local clubId = readActualClubId()
    if not clubId then
        return nil, "club_id_unavailable"
    end
    local guildName, guildRealm = readGuildDisplay()
    return {
        clubId = clubId,
        guildKey = "club:" .. clubId,
        guildName = type(guildName) == "string" and guildName or "",
        guildRealm = type(guildRealm) == "string" and guildRealm or "",
        -- Transport scope for comparison only; Guild Supplies rejects non-club scopes.
        transportScopeId = "club:" .. clubId,
    }
end

--- Demand-driven member snapshot (name/GUID/1-based rank order).
-- Does not consult or populate the idle gossip membership cache.
-- @param name string
-- @return table|nil member, string|nil reason
function GG.GetGuildMember(name)
    local identity, reason = GG.GetGuildIdentity()
    if not identity then
        return nil, reason or "not_ready"
    end
    local want = GG.NormalizePlayer(name)
    if not want then
        return nil, "invalid_name"
    end
    if not GetNumGuildMembers or not GetGuildRosterInfo then
        return nil, "roster_unavailable"
    end
    local total = GetNumGuildMembers()
    total = tonumber(total) or 0
    if total <= 0 then
        return nil, "roster_incomplete"
    end
    local wantLower = string.lower(want)
    for i = 1, total do
        local rosterName, _, rankIndex, _, _, _, _, _, isOnline, _, _, _, _, _, _, _, guid =
            GetGuildRosterInfo(i)
        local norm = GG.NormalizePlayer(rosterName)
        if norm and string.lower(norm) == wantLower then
            local rankOrder = normalizeRankOrder(guid, rankIndex)
            if not rankOrder then
                return nil, "rank_unavailable"
            end
            return {
                name = norm,
                guid = (type(guid) == "string" and guid ~= "") and guid or nil,
                rankOrder = rankOrder,
                online = isOnline and true or false,
                guildKey = identity.guildKey,
                clubId = identity.clubId,
            }
        end
    end
    return nil, "not_a_member"
end

--- Current 1-based rank-name list from GuildControl APIs.
-- @return table|nil ranks ({[position]=name, count=n}), string|nil reason
function GG.GetGuildRanks()
    local identity, reason = GG.GetGuildIdentity()
    if not identity then
        return nil, reason or "not_ready"
    end
    if type(GuildControlGetNumRanks) ~= "function" or type(GuildControlGetRankName) ~= "function" then
        return nil, "ranks_unavailable"
    end
    local count = tonumber(GuildControlGetNumRanks()) or 0
    if count < 1 then
        return nil, "ranks_unavailable"
    end
    local ranks = { count = count }
    for i = 1, count do
        local rankName = GuildControlGetRankName(i)
        if type(rankName) ~= "string" or rankName == "" then
            return nil, "rank_name_unavailable"
        end
        ranks[i] = rankName
    end
    ranks.guildKey = identity.guildKey
    return ranks
end
