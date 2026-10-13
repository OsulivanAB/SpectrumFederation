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
    -- Always wake readiness after a verified guild identity is installed,
    -- including when an old scope was just invalidated.
    if GG.OnGuildReady then
        GG.OnGuildReady()
    end
end

local function coalesceRefresh()
    local g = GG._guild
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
    if g.frame then
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
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_GUILD_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
            requestRoster()
            coalesceRefresh()
        elseif event == "GUILD_ROSTER_UPDATE" then
            coalesceRefresh()
        end
    end)
    g.frame = frame
    requestRoster()
    GG.RefreshGuildState()
end

function GG.ShutdownGuildAdapter()
    local g = GG._guild
    if g.frame then
        g.frame:UnregisterAllEvents()
        g.frame:SetScript("OnEvent", nil)
        g.frame = nil
    end
    -- Invalidate any coalesced RefreshGuildState already scheduled via C_Timer.After.
    g.coalesceGen = (tonumber(g.coalesceGen) or 0) + 1
    g.coalescePending = false
    g.ready = false
    g.inGuild = false
    g.scopeId = nil
    g.members = {}
    g.generation = (g.generation or 0) + 1
end
