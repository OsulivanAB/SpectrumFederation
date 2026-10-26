-- Production-Lua tests for Guild Supplies Part 2A (#385).
-- Run from repository root: lua5.1 tests/lua/guild_supplies_tests.lua

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
    time = 5000,
    chat = {},
    prints = {},
    debugEnabled = false,
    debugLogs = {},
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
    },
    unitName = "Alice",
    unitGuid = "Player-1-Alice",
    impersonationActive = false,
    gossipListening = false,
    gossipReady = false,
    wireSends = 0,
    rosterRequests = 0,
    frames = {},
    framesByName = {},
}

function GetTime() return world.time end
function time() return math.floor(world.time) end
function GetServerTime() return math.floor(world.time) end
-- WoW provides date(); Lua 5.1 tests map it to os.date.
function date(fmt, ts)
    return os.date(fmt, ts)
end
function IsInGuild() return world.guild.inGuild end
function GetGuildInfo(unit)
    if unit == "player" and world.guild.inGuild then
        return world.guild.name, world.guild.ranks[1], 0, world.guild.realm
    end
end
function GetNumGuildMembers()
    return #world.guild.members, #world.guild.members, #world.guild.members
end
function GetGuildRosterInfo(i)
    local m = world.guild.members[i]
    if not m then return end
    -- 3rd return is legacy 0-based rankIndex; 17th is GUID.
    local rankIndex = (tonumber(m.rankOrder) or 1) - 1
    return m.name, world.guild.ranks[m.rankOrder] or "Rank", rankIndex, 80, "Warrior", "Zone",
        "", "", m.online, 0, "WARRIOR", 0, 0, false, false, 0, m.guid
end
function GuildControlGetNumRanks()
    return #world.guild.ranks
end
function GuildControlGetRankName(i)
    return world.guild.ranks[i]
end
C_GuildInfo = {
    GuildRoster = function()
        world.rosterRequests = (world.rosterRequests or 0) + 1
    end,
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
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function UnitFullName() return world.unitName, "Garona" end
function UnitName() return world.unitName end
function UnitGUID(unit)
    if unit == "player" then return world.unitGuid end
end

local timers = {}
C_Timer = {
    After = function(delay, fn)
        timers[#timers + 1] = { at = world.time + delay, fn = fn }
    end,
}

local function flushTimers()
    local progressed = true
    while progressed do
        progressed = false
        local i = 1
        while i <= #timers do
            local t = timers[i]
            if t.at <= world.time then
                table.remove(timers, i)
                t.fn()
                progressed = true
            else
                i = i + 1
            end
        end
    end
end

--- Run exactly one due timer callback (no coalesced drain of chained After(0)).
local function runOneDueTimer()
    local i = 1
    while i <= #timers do
        if timers[i].at <= (world.time or 0) then
            local t = table.remove(timers, i)
            t.fn()
            return true
        end
        i = i + 1
    end
    return false
end

-- Size-correlated CBOR stand-in (not bit-identical to Retail, but wrapper-byte aware).
local function serTable(t, depth)
    depth = (depth or 0) + 1
    if depth > 20 then
        return "?"
    end
    local ty = type(t)
    if ty == "nil" then
        return "N"
    elseif ty == "boolean" then
        return t and "T" or "F"
    elseif ty == "number" then
        return "#" .. tostring(t)
    elseif ty == "string" then
        return "$" .. tostring(#t) .. ":" .. t
    elseif ty == "table" then
        local keys = {}
        for k in pairs(t) do
            keys[#keys + 1] = k
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        local parts = { "{" }
        for i = 1, #keys do
            local k = keys[i]
            parts[#parts + 1] = tostring(k) .. "="
            parts[#parts + 1] = serTable(t[k], depth)
            parts[#parts + 1] = ";"
        end
        parts[#parts + 1] = "}"
        return table.concat(parts)
    end
    return "?"
end

C_EncodingUtil = {
    SerializeCBOR = function(t)
        return serTable(t)
    end,
    DeserializeCBOR = function(s)
        return s
    end,
    EncodeBase64 = function(s)
        return "B64" .. tostring(s)
    end,
    DecodeBase64 = function(s)
        if type(s) == "string" and s:sub(1, 3) == "B64" then
            return s:sub(4)
        end
        return s
    end,
}

function CreateFrame(_, name)
    local f = {
        name = name,
        events = {},
        RegisterEvent = function(self, e) self.events[e] = true end,
        UnregisterAllEvents = function(self) self.events = {} end,
        SetScript = function(self, _, fn) self._onEvent = fn end,
    }
    world.frames[#world.frames + 1] = f
    if type(name) == "string" and name ~= "" then
        world.framesByName[name] = f
    end
    return f
end

local function fireEvent(event)
    for _, f in ipairs(world.frames) do
        if f.events[event] and f._onEvent then
            f._onEvent(f, event)
        end
    end
end

-- Chat / print traps
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
-- Load production modules
---------------------------------------------------------------------------

local SF = {}
local addonName = "SpectrumFederation"

-- Minimal locale
SF.L = {
    GUILD_SUPPLIES_EDITOR_RANK_LABEL = "%s and higher",
    GUILD_SUPPLIES_RANK_WAITING = "Guild rank information is unavailable.",
}
function SF.LocaleText(key, default)
    local v = SF.L[key]
    if type(v) == "string" and v ~= "" then return v end
    return default or tostring(key or "")
end

SF.Debug = {
    _enabled = false,
    IsEnabled = function(self) return self._enabled end,
    SetEnabled = function(self, v) self._enabled = v and true or false end,
    Info = function(self, cat, fmt, ...)
        if not self._enabled then return end
        world.debugLogs[#world.debugLogs + 1] = { cat = cat, msg = string.format(fmt, ...) }
    end,
    Warn = function(self, cat, fmt, ...)
        if not self._enabled then return end
        world.debugLogs[#world.debugLogs + 1] = { cat = cat, msg = string.format(fmt, ...) }
    end,
    Verbose = function() end,
    Error = function(self, cat, fmt, ...)
        if not self._enabled then return end
        world.debugLogs[#world.debugLogs + 1] = {
            level = "ERROR",
            cat = cat,
            msg = string.format(fmt, ...),
        }
    end,
}

SF.Consumables = {
    MAX_REQUESTED_ITEMS = 256,
    MAX_GOAL = 100000,
    ValidGoal = function(value)
        local goal = tonumber(value)
        if not goal or goal ~= goal or goal == math.huge or goal == -math.huge then
            return nil
        end
        if goal ~= math.floor(goal) or goal < 0 or goal > 100000 then
            return nil
        end
        return goal
    end,
    ItemIdFromText = function(text)
        local n = tonumber(text)
        if n and n == math.floor(n) and n > 0 then return n end
        if type(text) == "string" then
            local id = text:match("item:(%d+)")
            if id then return tonumber(id) end
        end
        return nil
    end,
}

SF.LootHelperImpersonation = {
    IsActive = function()
        return world.impersonationActive and true or false
    end,
}

local function loadModule(path)
    local f, err = loadfile(path)
    if not f then error(err) end
    f(addonName, SF)
end

SF.NameUtil = {}
loadModule("SpectrumFederation/modules/NameUtil.lua")

SF.GuildGossip = {}
loadModule("SpectrumFederation/modules/GuildGossip/01_Constants.lua")
loadModule("SpectrumFederation/modules/GuildGossip/02_Util.lua")
loadModule("SpectrumFederation/modules/GuildGossip/05_GuildAdapter.lua")

-- Stub provider lifecycle so SyncGuildAdapterLifecycle stays idle.
SF.GuildGossip.HasActiveProvider = function() return false end
SF.GuildGossip.Init = function() end

-- Observation matching helpers reused by staged ledger (#388).
SF.ConsumablesObservation = {}
loadModule("SpectrumFederation/modules/LootHelper/ConsumablesObservation.lua")

loadModule("SpectrumFederation/modules/GuildSupplies/State.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Authority.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Operations.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Campaigns.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Activation.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Ledger.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Admission.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Valuation.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Gossip.lua")

-- Minimal provider registry stub so EnsureGossipProvider can register without the
-- full engine. 3A multi-client tests exercise ValidateAndApply / AdmitRemote*.
do
    local providers = { byId = {}, order = {}, activeCount = 0 }
    SF.GuildGossip._providers = providers
    SF.GuildGossip.CreateIndex = SF.GuildGossip.CreateIndex or function()
        return { buildComplete = false, dirty = true, buckets = {} }
    end
    SF.GuildGossip.RegisterProvider = function(spec)
        if type(spec) ~= "table" or type(spec.id) ~= "string" then
            return false, "invalid_spec"
        end
        local entry = {
            id = spec.id,
            schema = tonumber(spec.schema) or 1,
            api = spec,
            enabled = spec.enabled and true or false,
            ready = spec.ready ~= false,
            index = SF.GuildGossip.CreateIndex(),
        }
        if not providers.byId[spec.id] then
            providers.order[#providers.order + 1] = spec.id
        end
        providers.byId[spec.id] = entry
        providers.activeCount = 0
        for _, id in ipairs(providers.order) do
            local p = providers.byId[id]
            if p and p.enabled and p.ready then
                providers.activeCount = providers.activeCount + 1
            end
        end
        return true, entry
    end
    SF.GuildGossip.UnregisterProvider = function(id)
        providers.byId[tostring(id or "")] = nil
    end
    SF.GuildGossip.SetProviderEnabled = function(id, enabled)
        local e = providers.byId[tostring(id or "")]
        if e then e.enabled = enabled and true or false end
        return true
    end
    SF.GuildGossip.GetProvider = function(id)
        return providers.byId[tostring(id or "")]
    end
    SF.GuildGossip.NotifyProviderChanged = function(id)
        world.notifyChanged = (world.notifyChanged or 0) + 1
        world.lastNotifyId = id
    end
    -- Minimal index surface matching production IndexUpsert/Remove/GetEntry so
    -- ApplyRecordToProvider can prove adoption soft-ack vs durable publish.
    SF.GuildGossip.CreateIndex = function()
        return { buildComplete = false, dirty = true, buckets = {}, byId = {}, epoch = "1.0" }
    end
    SF.GuildGossip.IndexUpsert = function(index, recordId, versionFp, meta)
        if type(index) ~= "table" or recordId == nil then
            return false, "bad_args"
        end
        index.byId = index.byId or {}
        local id = tostring(recordId)
        local vfp = tostring(versionFp or "")
        local existing = index.byId[id]
        if existing and existing.versionFp == vfp then
            return false, "duplicate"
        end
        if existing and existing.versionFp ~= vfp then
            return false, "replaced"
        end
        index.byId[id] = { id = id, versionFp = vfp, meta = meta }
        world.indexUpserts = (world.indexUpserts or 0) + 1
        world.lastIndexUpsertId = id
        return true, index.byId[id]
    end
    SF.GuildGossip.IndexRemove = function(index, recordId)
        if type(index) ~= "table" or type(index.byId) ~= "table" then
            return false
        end
        local id = tostring(recordId or "")
        if index.byId[id] then
            index.byId[id] = nil
            return true
        end
        return false
    end
    SF.GuildGossip.IndexGetEntry = function(index, recordId)
        if type(index) ~= "table" or type(index.byId) ~= "table" then
            return nil
        end
        return index.byId[tostring(recordId or "")]
    end
    SF.GuildGossip.BumpIndexEpoch = function(index)
        if type(index) == "table" then
            index.epoch = tostring((tonumber(index.epoch) or 0) + 1) .. ".0"
            index.byId = {}
            index.buildComplete = false
            index.dirty = true
        end
        world.indexEpochBumps = (world.indexEpochBumps or 0) + 1
    end
    SF.GuildGossip.BumpProviderChangeGen = function()
        world.providerChangeGen = (world.providerChangeGen or 0) + 1
    end
    SF.GuildGossip.MarkWorkPending = function() end
    SF.GuildGossip._RecountActiveProviders = function() end
    SF.GuildGossip.SyncGuildAdapterLifecycle = function() end
    SF.GuildGossip.GetGuildScopeId = function()
        if world.guild.inGuild and world.guild.clubId then
            return "club:" .. tostring(world.guild.clubId)
        end
    end
    -- Replace the idle stub with the real active-count check once providers exist.
    SF.GuildGossip.HasActiveProvider = function()
        return (providers.activeCount or 0) > 0
    end
    -- Engine unresolved / recovery surfaces used by adoption assembly backpressure.
    SF.GuildGossip.DELIVERY = {
        ACCEPTED = "accepted",
        DUPLICATE = "duplicate",
        PENDING = "pending",
        REJECTED = "rejected",
    }
    SF.GuildGossip._engine = {
        unresolved = {},
        unresolvedBackoffUntil = {},
    }
    SF.GuildGossip.UNRESOLVED_BACKOFF_SEC = SF.GuildGossip.UNRESOLVED_BACKOFF_SEC or 30
    SF.GuildGossip.AckTransientDelivery = function(entry, recordId, versionFp)
        if type(entry) ~= "table" or recordId == nil or versionFp == nil then
            return
        end
        entry._transientDeliveryAck = entry._transientDeliveryAck or {}
        entry._transientDeliveryAck[tostring(recordId)] = tostring(versionFp)
        world.transientAcks = (world.transientAcks or 0) + 1
    end
    SF.GuildGossip.HasTransientDeliveryAck = function(entry, recordId, versionFp)
        if type(entry) ~= "table" or type(entry._transientDeliveryAck) ~= "table" then
            return false
        end
        return entry._transientDeliveryAck[tostring(recordId)] == tostring(versionFp)
    end
    SF.GuildGossip.ClearTransientDeliveryAcks = function(entry)
        if type(entry) == "table" then
            entry._transientDeliveryAck = nil
        end
        world.transientClears = (world.transientClears or 0) + 1
    end
    -- Production-shaped: clear provider bookmarks/coverage even with empty unresolved
    -- (soft-acked adoption deliveries leave no unresolved obligation).
    SF.GuildGossip.ReopenProviderCoverage = function(providerId)
        world.reopenProviderCoverage = (world.reopenProviderCoverage or 0) + 1
        world.lastReopenCoverageProviderId = providerId
        local e = SF.GuildGossip._engine
        if type(e) ~= "table" then
            return
        end
        local entry = SF.GuildGossip.GetProvider and SF.GuildGossip.GetProvider(providerId)
        if type(entry) == "table" then
            entry.bookmarks = {}
        end
        if type(e.peers) == "table" then
            for _, peer in pairs(e.peers) do
                if type(peer) == "table" and type(peer.covered) == "table" and providerId then
                    peer.covered[providerId] = nil
                end
            end
        end
        local out = e.outPull
        if type(out) == "table" and (not providerId or out.providerId == providerId) then
            out.needsFollowUp = true
            world.needsFollowUpArmed = (world.needsFollowUpArmed or 0) + 1
        end
    end
    SF.GuildGossip.ReopenUnresolvedEnumeration = function(providerId)
        world.reopenUnresolved = (world.reopenUnresolved or 0) + 1
        world.lastReopenProviderId = providerId
        local e = SF.GuildGossip._engine
        if type(e) ~= "table" or type(e.unresolved) ~= "table" then
            return
        end
        local keys = {}
        for key, item in pairs(e.unresolved) do
            if not providerId or (item and item.providerId == providerId) then
                keys[#keys + 1] = key
            end
        end
        for i = 1, #keys do
            e.unresolved[keys[i]] = nil
        end
        -- Mirror production needsFollowUp when an active outPull matches.
        local out = e.outPull
        if type(out) == "table" and (not providerId or out.providerId == providerId) then
            out.needsFollowUp = true
            world.needsFollowUpArmed = (world.needsFollowUpArmed or 0) + 1
        end
        -- When unresolved was empty, production still relies on ReopenProviderCoverage
        -- for soft-ack cancel; do not pretend bookmarks clear here.
    end
    SF.GuildGossip.NotifyMeaningfulChange = function()
        local e = SF.GuildGossip._engine
        if type(e) == "table" then
            e.unresolvedBackoffUntil = {}
        end
        if SF.GuildGossip.MarkWorkPending then
            SF.GuildGossip.MarkWorkPending()
        end
        world.meaningfulChange = (world.meaningfulChange or 0) + 1
    end
    -- Production-shaped ApplyRecordToProvider: durable accepts IndexUpsert;
    -- adoption_buffer/ready/updated soft-ack without publishing into the index.
    local TRANSIENT_ACCEPT = { adoption_buffer = true, ready = true, updated = true }
    SF.GuildGossip.ApplyRecordToProvider = function(entry, record, ctx)
        if not entry or not entry.api or type(entry.api.ValidateAndApply) ~= "function" then
            return "rejected", "no_provider"
        end
        local result, detail = entry.api.ValidateAndApply(record, ctx)
        if type(result) ~= "string" then
            return "rejected", "invalid_outcome"
        end
        if result == "accepted" then
            local id = record and (record.id or record.recordId)
            local vfp = record and (record.versionFp or record.v)
            local transient = type(detail) == "string" and TRANSIENT_ACCEPT[detail] == true
            if transient then
                if id and vfp then
                    SF.GuildGossip.AckTransientDelivery(entry, id, vfp)
                end
            else
                if id and vfp and entry.index then
                    local _, info = SF.GuildGossip.IndexUpsert(entry.index, id, tostring(vfp), record)
                    if info == "replaced" then
                        SF.GuildGossip.BumpIndexEpoch(entry.index)
                        SF.GuildGossip.IndexUpsert(entry.index, id, tostring(vfp), record)
                    end
                end
                SF.GuildGossip.BumpProviderChangeGen(entry.id)
                SF.GuildGossip.NotifyMeaningfulChange()
            end
        elseif result == "duplicate" and type(detail) == "string" and TRANSIENT_ACCEPT[detail] then
            local id = record and (record.id or record.recordId)
            local vfp = record and (record.versionFp or record.v)
            if id and vfp then
                SF.GuildGossip.AckTransientDelivery(entry, id, vfp)
            end
        end
        return result, detail
    end
end

loadModule("SpectrumFederation/modules/GuildOfficer/Policy.lua")
loadModule("SpectrumFederation/modules/GuildOfficer/Gossip.lua")

local GS = SF.GuildSupplies
local GG = SF.GuildGossip
local officerBootstrapping = false

local function ensureDefaultOfficerPolicy()
    if world.skipOfficerBootstrap or officerBootstrapping then
        return
    end
    local GO = SF.GuildOfficer
    if not GO or type(GO.Initialize) ~= "function" then
        return
    end
    officerBootstrapping = true
    local savedName, savedGuid = world.unitName, world.unitGuid
    local function tryBootstrap()
        GO:Initialize(SpectrumFederationDB)
        local view = GO:GetView()
        if view and view.status == "unknown" and view.canBootstrap then
            GO:Bootstrap()
        end
    end
    pcall(tryBootstrap)
    local view = SF.GuildOfficer:GetView()
    if view and view.status == "unknown" then
        local gm = nil
        for _, m in ipairs(world.guild.members or {}) do
            if m.rankOrder == 1 and type(m.name) == "string" then
                gm = m
                break
            end
        end
        if gm then
            world.unitName = gm.name:match("^([^-]+)") or gm.name
            world.unitGuid = gm.guid
            pcall(tryBootstrap)
        end
    end
    world.unitName = savedName
    world.unitGuid = savedGuid
    officerBootstrapping = false
end

local realGetCapabilities = GS.GetCapabilities
function GS:GetCapabilities(...)
    ensureDefaultOfficerPolicy()
    return realGetCapabilities(self, ...)
end

local realSenderHasEditorAuthority = GS.SenderHasEditorAuthority
function GS.SenderHasEditorAuthority(...)
    ensureDefaultOfficerPolicy()
    return realSenderHasEditorAuthority(...)
end

local function resetDemandRoster()
    world.rosterRequests = 0
    timers = {}
    if GG._demandRoster then
        GG._demandRoster.lastRequestAt = nil
        GG._demandRoster.boundClubId = nil
        GG._demandRoster.pendingClubId = nil
        GG._demandRoster.waitGeneration = (tonumber(GG._demandRoster.waitGeneration) or 0) + 1
        GG._demandRoster.waitActive = false
        local wf = GG._demandRoster.waitFrame
        if wf then
            if wf.UnregisterAllEvents then wf:UnregisterAllEvents() end
            if wf.SetScript then wf:SetScript("OnEvent", nil) end
        end
        GG._demandRoster.staleFingerprint = nil
    end
end

--- Complete the temporary demand roster wait for the current club (test helper).
local function settleRoster()
    if not world.guild.inGuild or world.guild.clubId == nil or world.guild.clubId == 0 then
        return
    end
    if #(world.guild.members or {}) <= 0 then
        return
    end
    local clubId = tostring(world.guild.clubId)
    if GG._demandRoster and GG._demandRoster.boundClubId == clubId then
        return
    end
    GG.GetGuildRanks()
    fireEvent("GUILD_ROSTER_UPDATE")
end

--- Simulate /reload clearing runtime demand-roster / session caches while SV persist.
local function simulateRuntimeReload()
    resetDemandRoster()
    -- Runtime-only caches drop; durable SavedVariables (_root via _db) remain.
    GS._bootstrapEditLock = {}
    GS._pendingRelay = {}
    GS._pendingCampaignBoundaries = {}
    GS._confirmationRedriveByKey = {}
    timers = {}
end

local function resetDb()
    SpectrumFederationDB = {}
    GS._db = nil
    GS._root = nil
    GS._rootValid = false
    GS._rootReason = "not_initialized"
    GS._handleGeneration = 0
    GS._lastGuildKey = nil
    GS._adoptionEpoch = 0
    GS._adoption = nil
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._pendingCampaignBoundaries = {}
    GS._bootstrapEditLock = {}
    GS._confirmationRedriveByKey = {}
    world.notifyChanged = 0
    world.meaningfulChange = 0
    world.indexUpserts = 0
    world.lastIndexUpsertId = nil
    world.indexEpochBumps = 0
    world.providerChangeGen = 0
    world.transientAcks = 0
    world.transientClears = 0
    world.needsFollowUpArmed = 0
    world.reopenUnresolved = 0
    if GG._engine then
        GG._engine.unresolved = {}
        GG._engine.unresolvedBackoffUntil = {}
        GG._engine.outPull = nil
    end
    timers = {}
    world.chat = {}
    world.prints = {}
    world.debugLogs = {}
    world.unitName = "Alice"
    world.unitGuid = "Player-1-Alice"
    resetDemandRoster()
end

local function initGS(opts)
    opts = opts or {}
    -- Default: drain adoption replay slices in-process so existing Commit
    -- assertions stay synchronous. Yield-path tests clear this flag.
    GS._adoptionReplaySyncDrain = true
    -- Default: sync-drain paced export construction so ListRecordIds after
    -- EnsureGossipProvider sees accepted ops. Paced/idle lifecycle tests clear it.
    GS._exportMaintSyncDrain = true
    local ok, reason = GS:Initialize(SpectrumFederationDB)
    if opts.settle ~= false then
        settleRoster()
    end
    return ok, reason
end

local function drainExportMaint(maxRounds)
    maxRounds = maxRounds or 64
    local rounds = 0
    while rounds < maxRounds do
        rounds = rounds + 1
        flushTimers()
        world.time = (world.time or 0) + 1
        flushTimers()
        -- Idle when no further maint is scheduled and export reports idle.
        if GS._exportMaintIsIdle and GS._exportMaintIsIdle() then
            break
        end
        -- Fallback: stop if no timers remain after a notify.
        if #timers == 0 then
            break
        end
    end
    return rounds
end

--- Collect every provider export body (paginate; logical transfer can exceed one page).
local function collectAllExportBodies()
    local exportBodies = {}
    local prov = GG.GetProvider(GS.PROVIDER_ID)
    if not prov or not prov.api then
        return exportBodies
    end
    local cursor = 1
    local guard = 0
    while cursor and guard < 256 do
        guard = guard + 1
        local page, nextCursor = prov.api.ListRecordIds(cursor, 64)
        for i = 1, #(page or {}) do
            local rec = prov.api.GetRecordBody(page[i])
            if rec and rec.body then
                exportBodies[#exportBodies + 1] = { id = page[i], body = rec.body }
            end
        end
        cursor = nextCursor
    end
    return exportBodies
end

--- #386: campaign-owned items require an active campaign.
local function startCampaign()
    local op, st, err = GS:NewCampaignOperation()
    assertEq(st, "accepted", "campaign op prepared: " .. tostring(err))
    assertTrue(op ~= nil, "campaign op present")
    local status, reason = GS:ApplyStagedCampaignOperation(op)
    assertEq(status, "accepted", "campaign started: " .. tostring(reason))
    return op
end

local function minimalValidBankTabBody(id, datasetId, value)
    return {
        schemaVersion = 1,
        id = id,
        guildKey = "club:42",
        datasetId = datasetId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = value or 1,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 1,
        baseTargetRevision = datasetId,
        basePolicyRevision = datasetId,
    }
end

--- Rebind guild operations onto a new table identity after test-only SV edits.
-- Production writers bump the ephemeral validation gen; harness corruption must
-- not call that private hook — a new ops table mimics reload/replacement.
local function rebindOperations(raw)
    local old = raw.operations
    raw.operations = {
        records = old.records,
        order = old.order,
        heads = old.heads,
        pending = old.pending,
        conflicts = old.conflicts,
        openConflicts = old.openConflicts,
    }
    return raw.operations
end

--- Build an authoritative candidate body for NewConfirmationOperation embedding.
-- Does not write pending (avoids invalidating GetCurrentRecord structure checks).
local function seedConfirmCandidate(recordId, overrides)
    local record = select(1, GS:GetCurrentRecord())
    if type(record) ~= "table" then
        local raw = SpectrumFederationDB and SpectrumFederationDB.guildSupplies
            and SpectrumFederationDB.guildSupplies.guilds
            and SpectrumFederationDB.guildSupplies.guilds["club:42"]
        record = raw
    end
    if type(record) ~= "table" then
        fail("seedConfirmCandidate needs current record")
        return nil
    end
    if not record.currentCampaignId then
        startCampaign()
        record = select(1, GS:GetCurrentRecord()) or record
    end
    -- Prefer the exact local retained/accepted body so confirmation embeds
    -- authoritative content (exact-content binding; fabricated bank-tab
    -- fixtures must not override a real candidate of a different kind/value).
    local ops = record.operations
    if type(ops) == "table" and type(recordId) == "string" then
        local localBody = nil
        if ops.records and type(ops.records[recordId]) == "table" then
            localBody = ops.records[recordId]
        elseif ops.pending and ops.pending[recordId]
            and type(ops.pending[recordId].body) == "table" then
            localBody = ops.pending[recordId].body
        elseif ops.conflicts and ops.conflicts[recordId]
            and type(ops.conflicts[recordId].body) == "table" then
            localBody = ops.conflicts[recordId].body
        end
        if type(localBody) ~= "table" and GS._pendingRelay
            and type(GS._pendingRelay[recordId]) == "table"
            and type(GS._pendingRelay[recordId].body) == "table" then
            localBody = GS._pendingRelay[recordId].body
        end
        if type(localBody) == "table" then
            local snap = localBody
            if GS._SnapshotPublicOp then
                snap = select(1, GS._SnapshotPublicOp(localBody)) or localBody
            end
            if type(overrides) == "table" then
                local copy = {}
                for k, v in pairs(snap) do
                    copy[k] = v
                end
                for k, v in pairs(overrides) do
                    copy[k] = v
                end
                return copy
            end
            return snap
        end
    end
    local ds = record.datasetId
    local camp = record.currentCampaignId
    local pol = record.permission and record.permission.revisionId or ds
    local body = {
        schemaVersion = 1,
        id = recordId,
        guildKey = "club:42",
        datasetId = ds,
        campaignId = camp,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 1,
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 9000,
        baseTargetRevision = ds,
        basePolicyRevision = pol,
        baseCampaignId = camp,
    }
    if type(overrides) == "table" then
        for k, v in pairs(overrides) do
            body[k] = v
        end
    end
    return body
end

local function minimalValidConfirmBody(id, datasetId)
    local candBody = {
        schemaVersion = 1,
        id = "cand-1",
        guildKey = "club:42",
        datasetId = datasetId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 1,
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 1,
        baseTargetRevision = datasetId,
        basePolicyRevision = datasetId,
        baseCampaignId = nil,
    }
    return {
        schemaVersion = 1,
        id = id,
        guildKey = "club:42",
        datasetId = datasetId,
        kind = "confirm-candidate",
        candidateRef = {
            recordId = "cand-1",
            body = candBody,
        },
        campaignId = nil,
        basePolicyRevision = datasetId,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 1,
    }
end

local function setPlayer(name, guid, rankOrder)
    world.unitName = name:match("^([^-]+)") or name
    world.unitGuid = guid
    -- Ensure member exists
    local found = false
    for _, m in ipairs(world.guild.members) do
        if m.guid == guid or m.name == name then
            m.name = name
            m.guid = guid
            m.rankOrder = rankOrder
            found = true
            break
        end
    end
    if not found then
        world.guild.members[#world.guild.members + 1] = {
            name = name, guid = guid, rankOrder = rankOrder, online = true,
        }
    end
end

local function ensureIdleGossip()
    GG.SyncGuildAdapterLifecycle()
    local g = GG._guild
    assertTrue(g.listening ~= true, "gossip not listening with zero providers")
    assertTrue(g.ready ~= true, "gossip not ready with zero providers")
    assertEq(g.members and next(g.members), nil, "gossip membership cleared when idle")
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

-- Focused helpers for #424 multi-client paths

local function switchPlayer(name, guid, rankOrder)
    world.unitName = name
    world.unitGuid = guid
    -- Rank order is sourced from the roster entry for this GUID.
    for _, m in ipairs(world.guild.members) do
        if m.guid == guid then
            m.rankOrder = rankOrder or m.rankOrder
        end
    end
end

local function providerApply(body, sender)
    local entry = GG.GetProvider(GS.PROVIDER_ID)
    assertTrue(entry and entry.api and entry.api.ValidateAndApply, "provider registered")
    local rid = "test:" .. tostring(body.kind) .. ":" .. tostring((body.op and body.op.id) or body.datasetId or math.random(1, 1e9))
    local record = {
        id = rid,
        versionFp = GS.ContentFingerprint(body),
        body = body,
    }
    return entry.api.ValidateAndApply(record, { sender = sender })
end

local function snapshotOp(op)
    return select(1, GS._SnapshotPublicOp(op))
end
---------------------------------------------------------------------------
-- #424) Campaign display names — authority, LWW sync, archives, adoption
---------------------------------------------------------------------------

do
    resetDb()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    local camp1 = startCampaign()
    local record = GS:GetCurrentRecord()
    local camp1Id = record.currentCampaignId
    assertEq(GS.GetCampaignDisplayName(record, camp1Id), camp1Id,
        "424: new campaign falls back to ID")
    assertEq(GS.PROVIDER_SCHEMA, 2, "424: provider schema stays 2")

    -- Ordinary member cannot rename.
    setPlayer("Dave-Garona", "Player-1-Dave", 4)
    local opDenied, stDenied, reasonDenied = GS:NewRenameCampaignOperation(camp1Id, "Denied")
    assertNil(opDenied, "424: member prepare denied")
    assertEq(stDenied, "rejected", "424: member rejected")
    assertEq(reasonDenied, "unauthorized", "424: member unauthorized")

    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    local badOp, badSt, badReason = GS:NewRenameCampaignOperation(camp1Id, "Bad|cFF0000")
    assertNil(badOp, "424: escape sequence rejected")
    assertEq(badReason, "invalid_campaign_name", "424: invalid_campaign_name for escapes")
    badOp, badSt, badReason = GS:NewRenameCampaignOperation(camp1Id, string.rep("x", 65))
    assertNil(badOp, "424: oversize rejected")
    assertEq(badReason, "invalid_campaign_name", "424: oversize invalid_campaign_name")

    world.time = 6000
    local renameOp, renamePrep = GS:NewRenameCampaignOperation(camp1Id, "  Alpha Run  ")
    assertEq(renamePrep, "accepted", "424: rename prepared")
    assertEq(renameOp.value, "Alpha Run", "424: name trimmed")
    assertEq(GS:ApplyStagedConfigOperation(renameOp), "accepted", "424: rename accepted")
    record = GS:GetCurrentRecord()
    assertEq(GS.GetCampaignDisplayName(record, camp1Id), "Alpha Run", "424: custom name shown")
    assertEq(record.currentCampaignId, camp1Id, "424: current campaign unchanged by rename")
    local genBefore = record.accounting._consumables.generation
    local itemsBefore = record.accounting._consumables.requestedItems
    assertEq(record.campaignNames[camp1Id].revisionId, renameOp.id, "424: revision stored")

    -- Clear restores ID fallback without discarding revision metadata.
    world.time = 6001
    local clearOp = select(1, GS:NewRenameCampaignOperation(camp1Id, "   "))
    assertEq(GS:ApplyStagedConfigOperation(clearOp), "accepted", "424: clear accepted")
    record = GS:GetCurrentRecord()
    assertEq(GS.GetCampaignDisplayName(record, camp1Id), camp1Id, "424: clear falls back to ID")
    assertEq(record.campaignNames[camp1Id].revisionId, clearOp.id, "424: clear keeps revision")
    assertNil(record.campaignNames[camp1Id].name, "424: cleared name is nil")
    assertEq(record.accounting._consumables.generation, genBefore, "424: generation unchanged")
    assertTrue(record.accounting._consumables.requestedItems == itemsBefore,
        "424: requestedItems table identity unchanged")

    -- Duplicate names across campaigns are allowed; archived rename works.
    local itemOp = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 19019 }, {
        itemId = 19019, goal = 5, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(itemOp), "accepted", "424: seed item before archive")
    world.time = 6100
    local camp2 = startCampaign()
    record = GS:GetCurrentRecord()
    local camp2Id = record.currentCampaignId
    assertTrue(camp2Id ~= camp1Id, "424: second campaign id differs")
    assertTrue(type(record.campaignArchives[camp1Id]) == "table", "424: prior campaign archived")
    world.time = 6101
    local archRename = select(1, GS:NewRenameCampaignOperation(camp1Id, "Legacy Alpha"))
    assertEq(archRename.target, camp1Id, "424: archived target is camp1")
    assertEq(archRename.campaignId, camp2Id, "424: authorship is current campaign")
    assertEq(GS:ApplyStagedConfigOperation(archRename), "accepted", "424: archived rename accepted")
    record = GS:GetCurrentRecord()
    assertEq(record.currentCampaignId, camp2Id, "424: archived rename does not switch current")
    assertEq(GS.GetCampaignDisplayName(record, camp1Id), "Legacy Alpha", "424: archived name set")
    world.time = 6102
    local dupName = select(1, GS:NewRenameCampaignOperation(camp2Id, "Legacy Alpha"))
    assertEq(GS:ApplyStagedConfigOperation(dupName), "accepted", "424: duplicate names allowed")
    record = GS:GetCurrentRecord()
    assertEq(GS.GetCampaignDisplayName(record, camp2Id), "Legacy Alpha", "424: current also Legacy Alpha")
    local list = GS:ListInspectableCampaigns()
    local sawArch, sawCur = false, false
    for i = 1, #list do
        if list[i].campaignId == camp1Id then
            sawArch = true
            assertEq(list[i].displayName, "Legacy Alpha", "424: list shows archived custom name")
            assertEq(list[i].hasCustomName, true, "424: archived hasCustomName")
            assertEq(list[i].isCurrent, false, "424: archived not current")
        elseif list[i].campaignId == camp2Id then
            sawCur = true
            assertEq(list[i].isCurrent, true, "424: current flagged")
        end
    end
    assertTrue(sawArch and sawCur, "424: both campaigns inspectable")

    -- Persistence across reload (re-init root from SavedVariables).
    local savedRoot = SpectrumFederationDB.guildSupplies
    SpectrumFederationDB = { guildSupplies = savedRoot }
    initGS()
    record = GS:GetCurrentRecord()
    assertEq(GS.GetCampaignDisplayName(record, camp1Id), "Legacy Alpha", "424: name survives reload")
    assertEq(GS.GetCampaignDisplayName(record, camp2Id), "Legacy Alpha", "424: current name survives reload")

    -- Older saves without campaignNames remain usable.
    record.campaignNames = nil
    assertTrue(select(1, GS:GetCurrentRecord()) ~= nil, "424: absent campaignNames still valid")
    assertEq(GS.GetCampaignDisplayName(GS:GetCurrentRecord(), camp2Id), camp2Id,
        "424: absent names fall back to ID")
end

-- #424 LWW convergence: equal-time ties, reverse delivery, delayed after clear
do
    resetDb()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    startCampaign()
    local record = GS:GetCurrentRecord()
    local campId = record.currentCampaignId
    local ds = record.datasetId
    local pol = record.permission.revisionId
    local nameKey = "name:" .. campId

    world.time = 7000
    local aliceRename = select(1, GS:NewRenameCampaignOperation(campId, "AliceName"))
    assertEq(GS:ApplyStagedConfigOperation(aliceRename), "accepted", "424-lww: alice local")
    local aliceStored = snapshotOp(aliceRename)
    local bobId = "gs1:Player-1-Bob:zzzzzzzzzzzzzzzzzzzzzzzz:00000002"
    assertTrue(bobId > aliceStored.id, "424-lww: bob id sorts after alice for tie-break")
    local bobBody = {
        schemaVersion = 1,
        id = bobId,
        guildKey = "club:42",
        datasetId = ds,
        campaignId = campId,
        kind = "rename-campaign",
        target = campId,
        value = "BobName",
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = aliceStored.timestamp,
        baseTargetRevision = aliceStored.baseTargetRevision,
        basePolicyRevision = pol,
        baseCampaignId = campId,
    }
    local stBob, reasonBob = GS:AdmitRemoteOperation(bobBody, { sender = "Bob-Garona" })
    assertEq(stBob, "accepted", "424-lww: equal-time higher id accepted reason=" .. tostring(reasonBob))
    record = GS:GetCurrentRecord()
    assertEq(GS.GetCampaignDisplayName(record, campId), "BobName", "424-lww: bob wins equal-time")
    assertEq(record.operations.heads[nameKey], bobId, "424-lww: head is bob")
    assertTrue(record.operations.openConflicts == nil
        or record.operations.openConflicts[nameKey] == nil,
        "424-lww: no open conflict for names")

    -- Reverse order + clear + delayed older name on a fresh record.
    resetDb()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    startCampaign()
    record = GS:GetCurrentRecord()
    campId = record.currentCampaignId
    ds = record.datasetId
    pol = record.permission.revisionId
    nameKey = "name:" .. campId

    local early = {
        schemaVersion = 1,
        id = "gs1:Player-1-Alice:aaaaaaaaaaaaaaaaaaaaaaaa:00000010",
        guildKey = "club:42",
        datasetId = ds,
        campaignId = campId,
        kind = "rename-campaign",
        target = campId,
        value = "Early",
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 8000,
        baseTargetRevision = ds,
        basePolicyRevision = pol,
        baseCampaignId = campId,
    }
    local late = {
        schemaVersion = 1,
        id = "gs1:Player-1-Bob:bbbbbbbbbbbbbbbbbbbbbbbb:00000011",
        guildKey = "club:42",
        datasetId = ds,
        campaignId = campId,
        kind = "rename-campaign",
        target = campId,
        value = "Late",
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 8001,
        baseTargetRevision = ds,
        basePolicyRevision = pol,
        baseCampaignId = campId,
    }
    local clear = {
        schemaVersion = 1,
        id = "gs1:Player-1-Alice:cccccccccccccccccccccccc:00000012",
        guildKey = "club:42",
        datasetId = ds,
        campaignId = campId,
        kind = "rename-campaign",
        target = campId,
        value = nil,
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = 8002,
        baseTargetRevision = late.id,
        basePolicyRevision = pol,
        baseCampaignId = campId,
    }

    assertEq(GS:AdmitRemoteOperation(late, { sender = "Bob-Garona" }), "accepted",
        "424-order: late first")
    local stEarly, reasonEarly = GS:AdmitRemoteOperation(early, { sender = "Alice-Garona" })
    assertEq(stEarly, "rejected", "424-order: early after late rejected")
    assertEq(reasonEarly, "stale_name", "424-order: early stale_name")
    record = GS:GetCurrentRecord()
    assertEq(GS.GetCampaignDisplayName(record, campId), "Late", "424-order: still Late")

    assertEq(GS:AdmitRemoteOperation(clear, { sender = "Alice-Garona" }), "accepted",
        "424-order: clear accepted")
    record = GS:GetCurrentRecord()
    assertEq(GS.GetCampaignDisplayName(record, campId), campId, "424-order: cleared to ID")
    local delayedEarly = {
        schemaVersion = 1,
        id = "gs1:Player-1-Bob:dddddddddddddddddddddddd:00000009",
        guildKey = "club:42",
        datasetId = ds,
        campaignId = campId,
        kind = "rename-campaign",
        target = campId,
        value = "Zombie",
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 7999,
        baseTargetRevision = ds,
        basePolicyRevision = pol,
        baseCampaignId = campId,
    }
    local stZombie, reasonZombie = GS:AdmitRemoteOperation(delayedEarly, { sender = "Bob-Garona" })
    assertEq(stZombie, "rejected", "424-order: delayed older rejected")
    assertEq(reasonZombie, "stale_name", "424-order: delayed stale_name")
    record = GS:GetCurrentRecord()
    assertEq(GS.GetCampaignDisplayName(record, campId), campId,
        "424-order: clear survives delayed older name")
    assertTrue(record.operations.openConflicts == nil
        or record.operations.openConflicts[nameKey] == nil,
        "424-order: still no name conflict")

    -- Unrelated bank-tab conflict behavior unchanged.
    local tabA = select(1, GS:NewConfigOperation("set-bank-tab", "bankTab", 1))
    assertEq(GS:ApplyStagedConfigOperation(tabA), "accepted", "424-order: tab A")
    local tabB = {
        schemaVersion = 1,
        id = "gs1:Player-1-Bob:eeeeeeeeeeeeeeeeeeeeeeee:00000020",
        guildKey = "club:42",
        datasetId = ds,
        campaignId = campId,
        kind = "set-bank-tab",
        target = "bankTab",
        value = 2,
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = 9000,
        baseTargetRevision = tabA.baseTargetRevision,
        basePolicyRevision = pol,
        baseCampaignId = campId,
    }
    local stTab, reasonTab = GS:AdmitRemoteOperation(tabB, { sender = "Bob-Garona" })
    assertTrue(stTab == "pending" or stTab == "rejected",
        "424-order: divergent tab not silently LWW st=" .. tostring(stTab))
    assertTrue(reasonTab == "divergent_edit" or reasonTab == "open_conflict"
        or reasonTab == "stale_base",
        "424-order: tab conflict reason=" .. tostring(reasonTab))
    record = GS:GetCurrentRecord()
    assertTrue(type(record.operations.openConflicts) == "table"
        and record.operations.openConflicts["config:bankTab"] ~= nil,
        "424-order: bank tab still opens Troubleshooting conflict")
end

-- #424 adoption carries names; wrong dataset rejected; schema stays 2
do
    resetDb()
    switchPlayer("Alice", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    startCampaign()
    local record = GS:GetCurrentRecord()
    local campId = record.currentCampaignId
    local ds = record.datasetId
    world.time = 10000
    local renameOp = select(1, GS:NewRenameCampaignOperation(campId, "AdoptMe"))
    assertEq(GS:ApplyStagedConfigOperation(renameOp), "accepted", "424-adopt: source rename")
    assertEq(GS.GetCampaignDisplayName(GS:GetCurrentRecord(), campId), "AdoptMe",
        "424-adopt: source shows name")

    local wrongDs = snapshotOp(renameOp)
    wrongDs.datasetId = "gs1:other:000000000000000000000000:00000001"
    wrongDs.id = "gs1:Player-1-Alice:ffffffffffffffffffffffff:00000099"
    local stWrong, reasonWrong = GS:AdmitRemoteOperation(wrongDs, { sender = "Alice-Garona" })
    assertEq(stWrong, "rejected", "424-adopt: wrong dataset rejected")
    assertEq(reasonWrong, "dataset_mismatch", "424-adopt: dataset_mismatch")

    -- Export Alice's provider bodies and adopt onto Bob.
    if GS.NotifyLocalDurableChange then
        GS.NotifyLocalDurableChange("config")
    end
    drainExportMaint(64)
    local exportBodies = collectAllExportBodies()
    assertTrue(#exportBodies >= 2, "424-adopt: exported bodies present")

    SpectrumFederationDB = {}
    switchPlayer("Bob", "Player-1-Bob", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._pendingCampaignBoundaries = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", ds, { editorRankPosition = 1 })
    local _, stBegin = GS:BeginDatasetAdoption("Alice-Garona", ds)
    assertEq(stBegin, "accepted", "424-adopt: begin")
    for i = #exportBodies, 1, -1 do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    local adop = GS:GetPendingAdoption()
    assertTrue(adop and adop.ready, "424-adopt: transfer ready")
    local stCommit, reasonCommit = GS:CommitDatasetAdoption()
    assertEq(stCommit, "accepted", "424-adopt: commit " .. tostring(reasonCommit))
    record = GS:GetCurrentRecord()
    assertEq(record.datasetId, ds, "424-adopt: dataset replaced")
    assertEq(GS.GetCampaignDisplayName(record, campId), "AdoptMe", "424-adopt: name adopted")
    assertEq(record.campaignNames[campId].name, "AdoptMe", "424-adopt: name metadata")
    assertEq(GS.PROVIDER_SCHEMA, 2, "424-adopt: schema remains 2")
end

SF.TSM = nil
world.impersonationActive = false
setPlayer("Alice-Garona", "Player-1-Alice", 1)

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
