-- Production-Lua tests for Guild Supplies soft-delete (#465).
-- Run from repository root: lua5.1 tests/lua/guild_supplies_465_tests.lua

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
loadModule("SpectrumFederation/modules/GuildSupplies/Recipes.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Operations.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Campaigns.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Activation.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Ledger.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Withdrawals.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Admission.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Valuation.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Gossip.lua")

-- Minimal Settings UI stub so Logs page hooks can exercise Edit eligibility (#465).
SF.SettingsUI = {
    pagesById = {},
    RegisterPage = function(self, page)
        if type(page) == "table" and type(page.id) == "string" then
            self.pagesById[page.id] = page
        end
    end,
    GetPage = function(self, id)
        return self.pagesById and self.pagesById[id]
    end,
    Dialogs = {
        Confirm = function(_, _msg, _btn, onConfirm)
            if type(onConfirm) == "function" then
                onConfirm()
            end
        end,
        Prompt = function(_, _msg, _btn, _default, onContinue)
            if type(onContinue) == "function" then
                onContinue(_default or "")
            end
        end,
    },
}
loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesLogs.lua")
loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesRankings.lua")

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


local GS = SF.GuildSupplies

local function seedLiveCampaignWithItem(itemId, goal)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    resetDb()
    initGS()
    assertEq(select(2, GS:CreateStagedRecord()), "accepted", "465 seed: create")
    startCampaign()
    local tabOp = select(1, GS:NewConfigOperation("set-bank-tab", "bankTab", 2))
    assertEq(GS:ApplyStagedConfigOperation(tabOp), "accepted", "465 seed: tab")
    local itemOp = select(1, GS:NewConfigOperation("set-requested-item", { itemId = itemId }, {
        itemId = itemId, goal = goal or 100, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(itemOp), "accepted", "465 seed: item")
    world.time = (world.time or 0) + 7200
    GetNumGuildBankTransactions = function() return 0 end
    GetGuildBankTransaction = function()
        return "deposit", "Donor-Garona", "|Hitem:" .. tostring(itemId) .. "::::::::|h[Item]|h", 2,
            1, 1, 2026, 10, 19, 12
    end
    GS._BankContextReadinessProbe = function() return true end
    local _, actSt = GS:ActivateCanonicalDataset()
    assertEq(actSt, "accepted", "465 seed: activate")
    GetNumGuildBankTransactions = nil
    GetGuildBankTransaction = nil
    GS._BankContextReadinessProbe = nil
    return GS:GetCurrentRecord()
end

local function injectProductionDonation(record, opts)
    opts = opts or {}
    local cfg = record.accounting._consumables
    local eventId = opts.id or ("don-" .. tostring(opts.itemId or 1001) .. "-" .. tostring(world.time))
    local event = {
        type = GS.LEDGER_EVENT.DONATION,
        id = eventId,
        txnId = eventId,
        generation = tonumber(cfg.generation) or 1,
        timestamp = tonumber(opts.timestamp) or world.time,
        actor = opts.actor or "Alice-Garona",
        actorGuid = opts.actorGuid or "Player-1-Alice",
        donorGuid = opts.actorGuid or "Player-1-Alice",
        itemId = opts.itemId or 1001,
        quantity = opts.quantity or 10,
        campaignId = record.currentCampaignId,
        datasetId = record.datasetId,
        verification = "officer",
        writer = "Player-1-Alice",
        gsProductionCredit = true,
    }
    local list = record.accounting._consumableEvents
    list[#list + 1] = event
    return event
end

local function injectProductionAdjustment(record, opts)
    opts = opts or {}
    local cfg = record.accounting._consumables
    local eventId = opts.id or ("adj-" .. tostring(opts.itemId or 1001) .. "-" .. tostring(world.time))
    local event = {
        type = GS.LEDGER_EVENT.ADJUSTMENT,
        id = eventId,
        txnId = eventId,
        opId = eventId,
        generation = tonumber(cfg.generation) or 1,
        timestamp = tonumber(opts.timestamp) or world.time,
        actor = "Alice-Garona",
        writer = "Player-1-Alice",
        itemId = opts.itemId or 1001,
        quantity = opts.quantity or -3,
        attributed = opts.attributed,
        attributedGuid = opts.attributedGuid,
        campaignId = record.currentCampaignId,
        datasetId = record.datasetId,
        gsProductionCredit = true,
        unitCopper = opts.unitCopper,
    }
    local list = record.accounting._consumableEvents
    list[#list + 1] = event
    return event
end


local GS = SF.GuildSupplies

local function injectWithdrawal(record, opts)
    opts = opts or {}
    local cfg = record.accounting._consumables
    local eventId = opts.id or ("gsw1:wd-" .. tostring(opts.itemId or 1001))
    local event = {
        type = GS.LEDGER_EVENT.WITHDRAWAL,
        id = eventId,
        txnId = eventId,
        generation = tonumber(cfg.generation) or 1,
        timestamp = tonumber(opts.timestamp) or world.time,
        actor = opts.actor or "Alice-Garona",
        actorGuid = opts.actorGuid or "Player-1-Alice",
        itemId = opts.itemId or 1001,
        quantity = opts.quantity or 2,
        campaignId = record.currentCampaignId,
        datasetId = record.datasetId,
        gsProductionCredit = false,
    }
    local list = record.accounting._consumableEvents
    list[#list + 1] = event
    return event
end

local function historyIds(record)
    local rows = select(1, GS:ListCampaignHistory(record.currentCampaignId))
    local ids = {}
    for i = 1, #(rows or {}) do
        ids[rows[i].id] = true
    end
    return ids, rows
end

assertEq(GS.PROVIDER_SCHEMA, 7, "465: PROVIDER_SCHEMA is 7")
assertTrue(GS.KIND.SOFT_DELETE_EVENT == "soft-delete-event", "465: soft-delete kind registered")
assertEq(GS.SCHEMA_VERSION, 1, "465: persisted root schema unchanged")

do
    -- Schema gate: older schema-6 peers are incompatible.
    GS:EnsureGossipProvider()
    local prov = GG.GetProvider(GS.PROVIDER_ID)
    assertTrue(type(prov) == "table", "465-schema7: provider registered")
    assertEq(tonumber(prov.schema), 7, "465-schema7: registered schema 7")
    local function schemaMatches(remoteSchema)
        return tonumber(remoteSchema) == tonumber(prov.schema)
    end
    assertTrue(not schemaMatches(6), "465-schema7: schema-6 peer incompatible")
    assertTrue(schemaMatches(7), "465-schema7: peers match")
end

do
    -- Soft-delete donation: hide from Logs, exclude progress/rankings/personal.
    local record = seedLiveCampaignWithItem(9201, 100)
    injectProductionDonation(record, {
        id = "del-don-1", itemId = 9201, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9201), 10,
        "465: Alice personal before delete")
    local progressBefore = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    assertEq(tonumber(progressBefore.itemTotals[9201]) or 0, 10, "465: item total before delete")
    local idsBefore = historyIds(record)
    assertTrue(idsBefore["del-don-1"], "465: donation visible before delete")

    local op, st, reason = GS:NewSoftDeleteOperation("del-don-1")
    assertTrue(op ~= nil, "465: prepare donation delete: " .. tostring(reason))
    assertEq(st, "accepted", "465: prepare status")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "465: apply donation delete")

    assertTrue(GS.IsEventSoftDeleted(record, "del-don-1"), "465: marked soft-deleted")
    local durable = GS.FindLedgerEventById(record, "del-don-1")
    assertTrue(type(durable) == "table", "465: evidence retained")
    assertEq(durable.actor, "Alice-Garona", "465: durable donor unchanged")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9201), 0,
        "465: Alice personal after delete")
    local progress = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    assertEq(tonumber(progress.itemTotals[9201]) or 0, 0, "465: item total after delete")
    local idsAfter = historyIds(record)
    assertTrue(not idsAfter["del-don-1"], "465: donation hidden after delete")
    local rankings = GS.ProjectCampaignRankingsOnRecord(record, record.currentCampaignId)
    for i = 1, #(rankings.rows or {}) do
        assertTrue(rankings.rows[i].name ~= "Alice-Garona", "465: Alice absent rankings")
    end
    assertEq(#world.chat, 0, "465: no chat after donation delete")
end

do
    -- Deletion creates signed debt; contribution projection stays readable;
    -- officer repairs with an explicit adjustment (#465 owner decision).
    local record = seedLiveCampaignWithItem(9202, 100)
    injectProductionDonation(record, {
        id = "floor-don", itemId = 9202, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(record, {
        id = "floor-adj", itemId = 9202, quantity = -8,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9202), 2,
        "465: personal 10-8=2")
    local op = select(1, GS:NewSoftDeleteOperation("floor-don"))
    assertTrue(op ~= nil, "465: delete +10 against −8 is prepared")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "465: delete succeeds with debt")
    assertTrue(GS.IsEventSoftDeleted(record, "floor-don"), "465: donation deleted")
    local personal, personalErr = GS.PersonalContributorItemTotal(
        record, "Alice-Garona", "Player-1-Alice", 9202)
    assertEq(personalErr, nil, "465: projection readable with debt got " .. tostring(personalErr))
    assertEq(personal, -8, "465: signed personal debt −8")
    local progress = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    assertEq(tonumber(progress.itemTotals[9202]) or 0, -8, "465: item total debt −8")
    local repair, repairSt, repairReason = GS:NewAdjustmentOperation(9202, 8, "Alice-Garona")
    assertTrue(repair ~= nil,
        "465: prepare repair adjustment got " .. tostring(repairSt) .. "/" .. tostring(repairReason))
    assertEq(GS:ApplyStagedConfigOperation(repair), "accepted", "465: repair adjustment applied")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9202), 0,
        "465: explicit repair restores zero")
end

do
    -- Deleting negative adjustment restores effect (not another subtraction).
    local record = seedLiveCampaignWithItem(9203, 100)
    injectProductionDonation(record, {
        id = "rest-don", itemId = 9203, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(record, {
        id = "rest-adj", itemId = 9203, quantity = -8,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    local op = select(1, GS:NewSoftDeleteOperation("rest-adj"))
    assertTrue(op ~= nil, "465: prepare negative adj delete")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "465: apply negative adj delete")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9203), 10,
        "465: personal restored to 10")
    local progress = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    assertEq(tonumber(progress.itemTotals[9203]) or 0, 10, "465: item total restored")
end

do
    -- Effective attribution: delete corrected donation leaving Bob with −8 debt.
    local record = seedLiveCampaignWithItem(9204, 100)
    injectProductionDonation(record, {
        id = "eff-don", itemId = 9204, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "eff-don", "Bob-Garona", "Player-1-Bob"))
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "465: correct to Bob")
    injectProductionAdjustment(record, {
        id = "eff-adj", itemId = 9204, quantity = -8,
        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
    })
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9204), 2,
        "465: Bob effective personal 2")
    local op = select(1, GS:NewSoftDeleteOperation("eff-don"))
    assertTrue(op ~= nil, "465: delete uses effective credit but floors do not block")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "465: delete corrected donation")
    local bob, bobErr = GS.PersonalContributorItemTotal(
        record, "Bob-Garona", "Player-1-Bob", 9204)
    assertEq(bobErr, nil, "465: Bob projection readable")
    assertEq(bob, -8, "465: Bob signed debt −8 after delete")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9204), 0,
        "465: Alice remains emptied")
end

do
    -- Deletion wins over contributor corrections.
    local record = seedLiveCampaignWithItem(9205, 100)
    injectProductionDonation(record, {
        id = "win-don", itemId = 9205, quantity = 6,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local del = select(1, GS:NewSoftDeleteOperation("win-don"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465: delete first")
    local corr, st, reason = GS:NewContributorCorrectionOperation(
        "win-don", "Bob-Garona", "Player-1-Bob")
    assertNil(corr, "465: correction after delete rejected")
    assertEq(reason, "already_deleted", "465: correction reason already_deleted got " .. tostring(reason))
end

do
    -- Idempotent duplicate delete.
    local record = seedLiveCampaignWithItem(9206, 50)
    injectProductionDonation(record, {
        id = "idem-don", itemId = 9206, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local op1 = select(1, GS:NewSoftDeleteOperation("idem-don"))
    assertEq(GS:ApplyStagedConfigOperation(op1), "accepted", "465: first delete")
    -- Second prepare sees already_deleted.
    local op2, st2, reason2 = GS:NewSoftDeleteOperation("idem-don")
    assertNil(op2, "465: second prepare rejected")
    assertEq(reason2, "already_deleted", "465: second prepare already_deleted")
    -- Re-admit same accepted body is duplicate.
    local snap = select(1, GS._SnapshotPublicOp(op1))
    local stDup, reasonDup = GS:AdmitRemoteOperation(snap, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertTrue(stDup == "duplicate" or stDup == "accepted",
        "465: re-admit got " .. tostring(stDup) .. "/" .. tostring(reasonDup))
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9206), 0,
        "465: credit removed once")
end

do
    -- Withdrawal delete hides row only; no progress impact.
    local record = seedLiveCampaignWithItem(9207, 40)
    injectProductionDonation(record, {
        id = "wd-base", itemId = 9207, quantity = 5,
        actor = "Carol-Garona", actorGuid = "Player-1-Carol",
    })
    injectWithdrawal(record, {
        id = "gsw1:wd-hide", itemId = 9207, quantity = 2,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local progressBefore = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    assertEq(tonumber(progressBefore.itemTotals[9207]) or 0, 5, "465: withdrawal ignored by progress")
    local idsBefore = historyIds(record)
    assertTrue(idsBefore["gsw1:wd-hide"], "465: withdrawal visible")
    local op = select(1, GS:NewSoftDeleteOperation("gsw1:wd-hide"))
    assertTrue(op ~= nil, "465: prepare withdrawal delete")
    assertEq(op.value.eventKind, "withdrawal", "465: withdrawal eventKind")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "465: apply withdrawal delete")
    local idsAfter = historyIds(record)
    assertTrue(not idsAfter["gsw1:wd-hide"], "465: withdrawal hidden")
    local progressAfter = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    assertEq(tonumber(progressAfter.itemTotals[9207]) or 0, 5, "465: progress unchanged after wd delete")
end

do
    -- Delete-before-base-event: pending then redrive.
    local record = seedLiveCampaignWithItem(9208, 60)
    local early = {
        schemaVersion = 1,
        id = "gs1:early-del:" .. tostring(world.time),
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.SOFT_DELETE_EVENT,
        target = "late-don",
        value = {
            eventId = "late-don",
            eventKind = "donation",
            itemId = 9208,
            quantity = 7,
            attributed = "Alice-Garona",
            attributedGuid = "Player-1-Alice",
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    local st, reason = GS:AdmitRemoteOperation(early, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(st, "pending", "465: early delete pending got " .. tostring(st) .. "/" .. tostring(reason))
    injectProductionDonation(record, {
        id = "late-don", itemId = 9208, quantity = 7,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    if GS.EnsureThenRedriveCreditCorrections then
        GS.EnsureThenRedriveCreditCorrections(record, { eventId = "late-don" })
    end
    flushTimers()
    assertTrue(GS.IsEventSoftDeleted(record, "late-don"),
        "465: pending delete promoted after event")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9208), 0,
        "465: credit after redrive")
end

do
    -- Cross-peer soft-delete converges.
    local peerA = seedLiveCampaignWithItem(9209, 40)
    injectProductionDonation(peerA, {
        id = "peer-don", itemId = 9209, quantity = 9,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local del = select(1, GS:NewSoftDeleteOperation("peer-don"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465: peerA delete")
    local snap = select(1, GS._SnapshotPublicOp(del))

    local peerB = seedLiveCampaignWithItem(9209, 40)
    injectProductionDonation(peerB, {
        id = "peer-don", itemId = 9209, quantity = 9,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local body = {}
    for k, v in pairs(snap) do body[k] = v end
    body.guildKey = select(1, GS:GetCurrentContext()).guildKey
    body.datasetId = peerB.datasetId
    body.campaignId = peerB.currentCampaignId
    body.baseCampaignId = peerB.currentCampaignId
    body.basePolicyRevision = peerB.permission and peerB.permission.revisionId
    body.baseTargetRevision = peerB.datasetId
    local stB, reasonB = GS:AdmitRemoteOperation(body, {
        sender = "Alice-Garona", offlineRecord = peerB, preserveAttribution = true,
    })
    assertEq(stB, "accepted",
        "465: peerB admits delete got " .. tostring(stB) .. "/" .. tostring(reasonB))
    flushTimers()
    assertTrue(GS.IsEventSoftDeleted(peerB, "peer-don"), "465: peerB soft-deleted")
    assertEq(GS.PersonalContributorItemTotal(peerA, "Alice-Garona", "Player-1-Alice", 9209),
        GS.PersonalContributorItemTotal(peerB, "Alice-Garona", "Player-1-Alice", 9209),
        "465: peers agree personal total")
end

do
    -- Missing-event soft-delete stays pending then promotes (floors are not a dependency).
    local record = seedLiveCampaignWithItem(9210, 100)
    local remoteDel = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "gs1:race-del:" .. tostring(world.time),
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.SOFT_DELETE_EVENT,
        target = "race-don",
        value = {
            eventId = "race-don",
            eventKind = "donation",
            itemId = 9210,
            quantity = 10,
            attributed = "Alice-Garona",
            attributedGuid = "Player-1-Alice",
        },
        actorGuid = "Player-1-Bob",
        actorName = "Bob-Garona",
        timestamp = world.time,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    local st, reason = GS:AdmitRemoteOperation(remoteDel, {
        sender = "Bob-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(st, "pending",
        "465: missing-event delete pending got " .. tostring(st) .. "/" .. tostring(reason))
    injectProductionDonation(record, {
        id = "race-don", itemId = 9210, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(record, {
        id = "race-adj", itemId = 9210, quantity = -8,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    flushTimers()
    if GS.EnsureThenRedriveCreditCorrections then
        GS.EnsureThenRedriveCreditCorrections(record, { eventId = "race-don" })
    elseif GS.RedrivePendingSoftDeletes then
        GS.RedrivePendingSoftDeletes(record, { eventId = "race-don" })
    end
    flushTimers()
    assertTrue(GS.IsEventSoftDeleted(record, "race-don"),
        "465: missing-event delete promoted after ledger arrives")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9210), -8,
        "465: debt remains after late delete promotion")
end

do
    -- Preview as Non-Admin cannot author delete.
    local record = seedLiveCampaignWithItem(9211, 30)
    injectProductionDonation(record, {
        id = "prev-don", itemId = 9211, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    world.impersonationActive = true
    local caps = GS:GetCapabilities()
    assertTrue(caps.canEdit ~= true, "465: preview cannot edit")
    local op, st, reason = GS:NewSoftDeleteOperation("prev-don")
    assertNil(op, "465: preview prepare rejected")
    assertEq(reason, "preview_non_admin", "465: preview reason got " .. tostring(reason))
    world.impersonationActive = false
end

do
    -- Logs UI: Delete shown for officers; Edit absent for withdrawals; preview hides.
    local record = seedLiveCampaignWithItem(9212, 30)
    injectProductionDonation(record, {
        id = "ui-don", itemId = 9212, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectWithdrawal(record, {
        id = "gsw1:ui-wd", itemId = 9212, quantity = 1,
    })
    local page = SF.SettingsUI:GetPage("guildSuppliesLogs")
    assertTrue(type(page) == "table" and type(page.__sfTest) == "table", "465: logs page hooks")
    local rows = page.__sfTest.ProjectWithGuildLookupStats and select(1, page.__sfTest.ProjectWithGuildLookupStats())
        or {}
    local donRow, wdRow
    for i = 1, #rows do
        if rows[i].id == "ui-don" then donRow = rows[i] end
        if rows[i].id == "gsw1:ui-wd" then wdRow = rows[i] end
    end
    assertTrue(type(donRow) == "table", "465: donation row projected")
    assertTrue(donRow.showDelete == true, "465: donation shows Delete")
    assertTrue(donRow.showEdit == true, "465: donation shows Edit")
    assertTrue(type(wdRow) == "table", "465: withdrawal row projected")
    assertTrue(wdRow.showDelete == true, "465: withdrawal shows Delete")
    assertTrue(wdRow.showEdit ~= true, "465: withdrawal hides Edit")
    world.impersonationActive = true
    page.__sfTest.ClearProjectedRowCache()
    local prevRows = select(1, page.__sfTest.ProjectWithGuildLookupStats())
    for i = 1, #prevRows do
        assertTrue(prevRows[i].showDelete ~= true, "465: preview hides Delete")
        assertTrue(prevRows[i].showEdit ~= true, "465: preview hides Edit")
    end
    world.impersonationActive = false
end

do
    -- Captured delete confirm; cancel-equivalent stale payload does not mutate.
    local record = seedLiveCampaignWithItem(9213, 30)
    injectProductionDonation(record, {
        id = "confirm-don", itemId = 9213, quantity = 2,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local page = SF.SettingsUI:GetPage("guildSuppliesLogs")
    -- Dialogs stub auto-accepts; exercise OpenDeleteDialog end-to-end.
    page.__sfTest.OpenDeleteDialog("confirm-don", {
        _eventKind = "donation",
        _contributorName = "Alice-Garona",
        _quantityText = "2",
        _itemText = "Item",
    })
    flushTimers()
    assertTrue(GS.IsEventSoftDeleted(record, "confirm-don"), "465: confirm delete applied")
end

do
    -- #465 P1: multi-entry pending soft-delete redrive is non-recursive, attempt-
    -- budgeted, and becomes idle after eligible drain.
    local record = seedLiveCampaignWithItem(9220, 500)
    local ctx = select(1, GS:GetCurrentContext())
    record.operations.pending = record.operations.pending or {}
    local count = 12
    for i = 1, count do
        local donId = string.format("sd-pend-don-%02d", i)
        injectProductionDonation(record, {
            id = donId, itemId = 9220, quantity = 2,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
        local id = string.format("sd-pend-del-%02d", i)
        record.operations.pending[id] = {
            id = id,
            sender = "Alice-Garona",
            reason = "item_negative",
            body = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = id,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.SOFT_DELETE_EVENT,
                target = donId,
                value = {
                    eventId = donId,
                    eventKind = "donation",
                    itemId = 9220,
                    quantity = 2,
                    attributed = "Alice-Garona",
                    attributedGuid = "Player-1-Alice",
                },
                actorGuid = "Player-1-Alice",
                actorName = "Alice-Garona",
                timestamp = world.time + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            },
        }
    end
    if GS._ClearSoftDeleteRedriveContinuationForTest then
        GS._ClearSoftDeleteRedriveContinuationForTest(record)
    end
    local depth = 0
    local maxDepth = 0
    local entries = 0
    local realRedrive = GS.RedrivePendingSoftDeletes
    GS.RedrivePendingSoftDeletes = function(rec, o)
        depth = depth + 1
        entries = entries + 1
        if depth > maxDepth then maxDepth = depth end
        local a, b = realRedrive(rec, o)
        depth = depth - 1
        return a, b
    end
    local _, attempts1 = GS.RedrivePendingSoftDeletes(record, {
        itemId = 9220, maxAttempts = 4,
    })
    assertEq(attempts1, 4, "465-P1: first slice capped at maxAttempts")
    assertEq(maxDepth, 1, "465-P1: no recursive redrive depth got " .. tostring(maxDepth))
    local slices = 0
    while slices < 16 do
        if not runOneDueTimer() then
            break
        end
        slices = slices + 1
    end
    GS.RedrivePendingSoftDeletes = realRedrive
    flushTimers()
    local remaining = 0
    for id, entry in pairs(record.operations.pending or {}) do
        local body = entry and entry.body
        if type(body) == "table" and body.kind == GS.KIND.SOFT_DELETE_EVENT then
            remaining = remaining + 1
        end
    end
    assertEq(remaining, 0, "465-P1: eligible pending soft-deletes drained")
    assertTrue(slices >= 1, "465-P1: continuation yielded across slices got " .. tostring(slices))
    assertTrue(#timers == 0, "465-P1: idle after drain")
    for i = 1, count do
        assertTrue(GS.IsEventSoftDeleted(record, string.format("sd-pend-don-%02d", i)),
            "465-P1: donation soft-deleted " .. i)
    end
end

do
    -- #465 P2: retain accepted losing delete revisions without replacing the head.
    local function makeDeleteBody(record, id, eventId, ts, actorName, actorGuid)
        local ctx = select(1, GS:GetCurrentContext())
        return {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = id,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.SOFT_DELETE_EVENT,
            target = eventId,
            value = {
                eventId = eventId,
                eventKind = "donation",
                itemId = 9221,
                quantity = 5,
                attributed = "Alice-Garona",
                attributedGuid = "Player-1-Alice",
            },
            actorGuid = actorGuid,
            actorName = actorName,
            timestamp = ts,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
    end
    local function assertBothOrders(label, firstWinner)
        local record = seedLiveCampaignWithItem(9221, 40)
        injectProductionDonation(record, {
            id = "lww-del-don", itemId = 9221, quantity = 5,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        })
        local early = makeDeleteBody(record, "del-lose-early", "lww-del-don",
            world.time + 1, "Bob-Garona", "Player-1-Bob")
        local late = makeDeleteBody(record, "del-win-late", "lww-del-don",
            world.time + 10, "Carol-Garona", "Player-1-Carol")
        local first = firstWinner and late or early
        local second = firstWinner and early or late
        assertEq(select(1, GS:AdmitRemoteOperation(first, {
            sender = first.actorName, offlineRecord = record, preserveAttribution = true,
        })), "accepted", label .. ": first admit")
        local st2, r2 = GS:AdmitRemoteOperation(second, {
            sender = second.actorName, offlineRecord = record, preserveAttribution = true,
        })
        assertTrue(st2 == "accepted" or st2 == "duplicate",
            label .. ": second retained got " .. tostring(st2) .. "/" .. tostring(r2))
        assertTrue(record.operations.records["del-lose-early"] ~= nil,
            label .. ": losing op retained")
        assertTrue(record.operations.records["del-win-late"] ~= nil,
            label .. ": winning op retained")
        local tKey = GS.SoftDeleteTargetKey(record, "lww-del-don")
        assertEq(record.operations.heads[tKey], "del-win-late",
            label .. ": head is winning revision")
        local entry = record.eventDeletions and record.eventDeletions["lww-del-don"]
        assertTrue(type(entry) == "table", label .. ": projection entry")
        assertEq(entry.revisionId, "del-win-late", label .. ": projection winner")
        assertEq(entry.actorName, "Carol-Garona", label .. ": winning actor")
    end
    assertBothOrders("465-P2-win-first", true)
    assertBothOrders("465-P2-lose-first", false)
end

do
    -- Fresh-target adoption: winner-first source export → adopt into empty target.
    local record = seedLiveCampaignWithItem(9230, 40)
    local ctx = select(1, GS:GetCurrentContext())
    local don = injectProductionDonation(record, {
        id = "adopt-del-don", itemId = 9230, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local function makeDel(id, ts, actorName, actorGuid)
        return {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = id,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.SOFT_DELETE_EVENT,
            target = "adopt-del-don",
            value = {
                eventId = "adopt-del-don", eventKind = "donation",
                itemId = 9230, quantity = 5,
                attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
            },
            actorGuid = actorGuid,
            actorName = actorName,
            timestamp = ts,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
    end
    local late = makeDel("adopt-del-win", world.time + 10, "Alice-Garona", "Player-1-Alice")
    local early = makeDel("adopt-del-lose", world.time + 1, "Alice-Garona", "Player-1-Alice")
    local function admitSettle(op)
        local st, r = GS:AdmitRemoteOperation(op, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        local g = 0
        while st == "pending" and g < 64 do
            if not runOneDueTimer() then break end
            st, r = GS:AdmitRemoteOperation(op, {
                sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
            })
            g = g + 1
        end
        return st, r
    end
    local stW, rW = admitSettle(late)
    assertTrue(stW == "accepted" or stW == "duplicate",
        "465-adopt-del: winner first st=" .. tostring(stW) .. "/" .. tostring(rW))
    local stL, rL = admitSettle(early)
    assertTrue(stL == "accepted" or stL == "duplicate",
        "465-adopt-del: loser retained st=" .. tostring(stL) .. "/" .. tostring(rL))
    assertTrue(record.operations.records["adopt-del-lose"] ~= nil, "465-adopt-del: source loser")
    assertTrue(record.operations.records["adopt-del-win"] ~= nil, "465-adopt-del: source winner")
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    local exportBodies = collectAllExportBodies()
    assertTrue(#exportBodies >= 1, "465-adopt-del: export bodies n=" .. tostring(#exportBodies))
    local sawWin, sawLose = false, false
    for i = 1, #exportBodies do
        local b = exportBodies[i].body
        local op = b and b.op
        if type(op) == "table" and op.id == "adopt-del-win" then sawWin = true end
        if type(op) == "table" and op.id == "adopt-del-lose" then sawLose = true end
    end
    assertTrue(sawWin, "465-adopt-del: winner exported")
    assertTrue(sawLose, "465-adopt-del: loser exported")
    local sourceDataset = record.datasetId
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-adopt-del: begin")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-adopt-del: transfer ready")
    local stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while stAdopt == "pending" and gAdopt < 128 do
        if not runOneDueTimer() then
            stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
        else
            stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
        end
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(stAdopt, "accepted",
        "465-adopt-del: commit got " .. tostring(stAdopt) .. "/" .. tostring(reasonAdopt))
    local adopted = GS:GetCurrentRecord()
    assertTrue(type(adopted) == "table", "465-adopt-del: adopted record")
    assertTrue(adopted.operations.records["adopt-del-win"] ~= nil, "465-adopt-del: winner on target")
    assertTrue(adopted.operations.records["adopt-del-lose"] ~= nil, "465-adopt-del: loser on target")
    assertTrue(GS.IsEventSoftDeleted(adopted, "adopt-del-don"), "465-adopt-del: event deleted")
    local tKey = GS.SoftDeleteTargetKey(adopted, "adopt-del-don")
    assertEq(adopted.operations.heads[tKey], "adopt-del-win", "465-adopt-del: winning head")
    local entry = adopted.eventDeletions and adopted.eventDeletions["adopt-del-don"]
    assertTrue(type(entry) == "table", "465-adopt-del: projection")
    assertEq(entry.actorName, "Alice-Garona", "465-adopt-del: winning actor")
    assertEq(don.id, "adopt-del-don", "465-adopt-del: source donation id stable")
end

do
    -- #465 P2: prior accepted correction retained inactive after delete-first delivery;
    -- new local edits to deleted rows still rejected.
    local record = seedLiveCampaignWithItem(9222, 40)
    injectProductionDonation(record, {
        id = "corr-del-don", itemId = 9222, quantity = 6,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "corr-del-don", "Bob-Garona", "Player-1-Bob"))
    assertTrue(corr ~= nil, "465-corr-del: prepare correction")
    local corrSnap = select(1, GS._SnapshotPublicOp(corr))
    local del = select(1, GS:NewSoftDeleteOperation("corr-del-don"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-corr-del: delete first")
    assertTrue(GS.IsEventSoftDeleted(record, "corr-del-don"), "465-corr-del: deleted")
    -- Delete-first: replaying the prior accepted correction must retain history.
    corrSnap.baseTargetRevision = record.datasetId
    local stCorr, rCorr = GS:AdmitRemoteOperation(corrSnap, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertTrue(stCorr == "accepted" or stCorr == "duplicate",
        "465-corr-del: prior correction retained got " .. tostring(stCorr) .. "/" .. tostring(rCorr))
    assertTrue(record.operations.records[corr.id] ~= nil,
        "465-corr-del: correction body in accepted history")
    -- Soft-delete still excludes accounting; correction must not reactivate credit.
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9222), 0,
        "465-corr-del: Bob credit stays excluded")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9222), 0,
        "465-corr-del: Alice credit stays excluded")
    local localCorr, localSt, localReason = GS:NewContributorCorrectionOperation(
        "corr-del-don", "Carol-Garona", "Player-1-Carol")
    assertNil(localCorr, "465-corr-del: new local edit rejected")
    assertEq(localReason, "already_deleted",
        "465-corr-del: local reason already_deleted got " .. tostring(localReason))
end

do
    -- Fresh-target adoption: delete-first then absent prior correction.
    local record = seedLiveCampaignWithItem(9231, 40)
    injectProductionDonation(record, {
        id = "adopt-corr-don", itemId = 9231, quantity = 6,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "adopt-corr-don", "Bob-Garona", "Player-1-Bob"))
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "465-adopt-corr: correction")
    local del = select(1, GS:NewSoftDeleteOperation("adopt-corr-don"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-adopt-corr: delete")
    assertTrue(record.operations.records[corr.id] ~= nil, "465-adopt-corr: source corr")
    assertTrue(record.operations.records[del.id] ~= nil, "465-adopt-corr: source del")
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    local exportBodies = collectAllExportBodies()
    assertTrue(#exportBodies >= 1, "465-adopt-corr: export bodies")
    local sourceDataset = record.datasetId
    local corrId, delId = corr.id, del.id
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-adopt-corr: begin")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-adopt-corr: transfer ready")
    local stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while stAdopt == "pending" and gAdopt < 128 do
        if not runOneDueTimer() then
            stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
        else
            stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
        end
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(stAdopt, "accepted",
        "465-adopt-corr: commit got " .. tostring(stAdopt) .. "/" .. tostring(reasonAdopt))
    local adopted = GS:GetCurrentRecord()
    assertTrue(adopted.operations.records[corrId] ~= nil, "465-adopt-corr: correction history")
    assertTrue(adopted.operations.records[delId] ~= nil, "465-adopt-corr: delete history")
    assertTrue(GS.IsEventSoftDeleted(adopted, "adopt-corr-don"), "465-adopt-corr: deleted")
    assertEq(GS.PersonalContributorItemTotal(adopted, "Bob-Garona", "Player-1-Bob", 9231), 0,
        "465-adopt-corr: credit not reinstated")
    simulateRuntimeReload()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(adopted)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(adopted, nil)
    end
    assertTrue(GS.IsEventSoftDeleted(adopted, "adopt-corr-don"),
        "465-adopt-corr: delete survives reload")
    assertTrue(adopted.operations.records[corrId] ~= nil,
        "465-adopt-corr: correction survives reload")
end

do
    -- Correction-then-delete order: both survive; deletion wins projection.
    local record = seedLiveCampaignWithItem(9223, 40)
    injectProductionDonation(record, {
        id = "corr-then-del", itemId = 9223, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "corr-then-del", "Bob-Garona", "Player-1-Bob"))
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "465-corr-then: correction")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9223), 4,
        "465-corr-then: Bob credited before delete")
    local del = select(1, GS:NewSoftDeleteOperation("corr-then-del"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-corr-then: delete")
    assertTrue(record.operations.records[corr.id] ~= nil, "465-corr-then: correction retained")
    assertTrue(record.operations.records[del.id] ~= nil, "465-corr-then: delete retained")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9223), 0,
        "465-corr-then: deletion wins accounting")
end

do
    -- Production alias install + late reobservation alias must not resurrect credit.
    local record = seedLiveCampaignWithItem(9224, 40)
    local don = injectProductionDonation(record, {
        id = "ctx:alias-canon", itemId = 9224, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    don.txnId = "ctx:alias-canon"
    assertTrue(GS._AddTxnAlias(record, "ctx:alias-canon", "ctx:alias-alt", don),
        "465-alias: production alias installed")
    local del = select(1, GS:NewSoftDeleteOperation("ctx:alias-alt"))
    assertTrue(del ~= nil, "465-alias: prepare via alias")
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-alias: apply")
    assertTrue(GS.IsEventSoftDeleted(record, "ctx:alias-canon"), "465-alias: canonical deleted")
    assertTrue(GS.IsEventSoftDeleted(record, "ctx:alias-alt"), "465-alias: alias deleted")
    -- Late reobservation discovers another alias for the same occurrence.
    assertTrue(GS._AddTxnAlias(record, "ctx:alias-canon", "ctx:alias-reobs", don),
        "465-alias: reobservation alias installed")
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(record)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(record, nil)
    end
    assertTrue(GS.IsEventSoftDeleted(record, "ctx:alias-reobs"),
        "465-alias: reobservation alias stays deleted")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9224), 0,
        "465-alias: credit not restored by reobservation")
    simulateRuntimeReload()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(record)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(record, nil)
    end
    assertTrue(GS.IsEventSoftDeleted(record, "ctx:alias-canon"),
        "465-alias: canonical deleted after reload rebuild")
    assertTrue(GS.IsEventSoftDeleted(record, "ctx:alias-alt"),
        "465-alias: alias deleted after reload rebuild")
    assertTrue(GS.IsEventSoftDeleted(record, "ctx:alias-reobs"),
        "465-alias: reobs alias deleted after reload")
end

do
    -- Cross-event concurrent deletes converge: both +10 donations deleted against
    -- −10 adjustment leave −10 everywhere; officer repairs with +10 (#465).
    local function seedConflictPeer(itemId)
        local record = seedLiveCampaignWithItem(itemId, 100)
        injectProductionDonation(record, {
            id = "xevt-d1", itemId = itemId, quantity = 10,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        })
        injectProductionDonation(record, {
            id = "xevt-d2", itemId = itemId, quantity = 10,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        })
        injectProductionAdjustment(record, {
            id = "xevt-adj", itemId = itemId, quantity = -10,
            attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
        })
        return record
    end
    local function rebind(body, record)
        local out = {}
        for k, v in pairs(body) do out[k] = v end
        out.guildKey = select(1, GS:GetCurrentContext()).guildKey
        out.datasetId = record.datasetId
        out.campaignId = record.currentCampaignId
        out.baseCampaignId = record.currentCampaignId
        out.basePolicyRevision = record.permission and record.permission.revisionId
        out.baseTargetRevision = record.datasetId
        return out
    end
    local function deletedSet(record)
        return {
            d1 = GS.IsEventSoftDeleted(record, "xevt-d1") and true or false,
            d2 = GS.IsEventSoftDeleted(record, "xevt-d2") and true or false,
        }
    end
    local function assertConverged(label, peerA, peerB, itemId)
        flushTimers()
        local setA, setB = deletedSet(peerA), deletedSet(peerB)
        assertTrue(setA.d1 and setA.d2, label .. ": A deleted {D1,D2}")
        assertTrue(setB.d1 and setB.d2, label .. ": B deleted {D1,D2}")
        local totA, errA = GS.PersonalContributorItemTotal(
            peerA, "Alice-Garona", "Player-1-Alice", itemId)
        local totB, errB = GS.PersonalContributorItemTotal(
            peerB, "Alice-Garona", "Player-1-Alice", itemId)
        assertEq(errA, nil, label .. ": A readable")
        assertEq(errB, nil, label .. ": B readable")
        assertEq(totA, -10, label .. ": A debt −10")
        assertEq(totB, -10, label .. ": B debt −10")
        assertTrue(peerA.operations.records and peerB.operations.records,
            label .. ": ops tables present")
    end

    local peerA = seedConflictPeer(9225)
    local delA = select(1, GS:NewSoftDeleteOperation("xevt-d1"))
    assertEq(GS:ApplyStagedConfigOperation(delA), "accepted", "465-xevt: A deletes D1")
    local snapA = select(1, GS._SnapshotPublicOp(delA))
    local peerB = seedConflictPeer(9225)
    local delB = select(1, GS:NewSoftDeleteOperation("xevt-d2"))
    assertEq(GS:ApplyStagedConfigOperation(delB), "accepted", "465-xevt: B deletes D2")
    local snapB = select(1, GS._SnapshotPublicOp(delB))
    assertEq(select(1, GS:AdmitRemoteOperation(rebind(snapB, peerA), {
        sender = "Alice-Garona", offlineRecord = peerA, preserveAttribution = true,
    })), "accepted", "465-xevt: A accepts B's D2 delete")
    assertEq(select(1, GS:AdmitRemoteOperation(rebind(snapA, peerB), {
        sender = "Alice-Garona", offlineRecord = peerB, preserveAttribution = true,
    })), "accepted", "465-xevt: B accepts A's D1 delete")
    assertConverged("465-xevt", peerA, peerB, 9225)

    -- Opposite delivery order.
    local peerA2 = seedConflictPeer(9226)
    local delA2 = select(1, GS:NewSoftDeleteOperation("xevt-d1"))
    assertEq(GS:ApplyStagedConfigOperation(delA2), "accepted", "465-xevt2: A deletes D1")
    local snapA2 = select(1, GS._SnapshotPublicOp(delA2))
    local peerB2 = seedConflictPeer(9226)
    local delB2 = select(1, GS:NewSoftDeleteOperation("xevt-d2"))
    assertEq(GS:ApplyStagedConfigOperation(delB2), "accepted", "465-xevt2: B deletes D2")
    local snapB2 = select(1, GS._SnapshotPublicOp(delB2))
    assertEq(select(1, GS:AdmitRemoteOperation(rebind(snapA2, peerB2), {
        sender = "Alice-Garona", offlineRecord = peerB2, preserveAttribution = true,
    })), "accepted", "465-xevt2: B accepts D1 delete first")
    assertEq(select(1, GS:AdmitRemoteOperation(rebind(snapB2, peerA2), {
        sender = "Alice-Garona", offlineRecord = peerA2, preserveAttribution = true,
    })), "accepted", "465-xevt2: A accepts D2 delete second")
    assertConverged("465-xevt2", peerA2, peerB2, 9226)

    -- Reload reconstruction on peer A2, then explicit repair to zero.
    simulateRuntimeReload()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(peerA2)
    end
    if GS.InvalidateCreditCorrectionProjection then
        GS.InvalidateCreditCorrectionProjection(peerA2)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(peerA2, nil)
    end
    if GS.EnsureCreditCorrectionProjection then
        GS.EnsureCreditCorrectionProjection(peerA2, nil)
    end
    assertTrue(GS.IsEventSoftDeleted(peerA2, "xevt-d1") and GS.IsEventSoftDeleted(peerA2, "xevt-d2"),
        "465-xevt2: deleted set survives reload rebuild")
    assertEq(GS.PersonalContributorItemTotal(peerA2, "Alice-Garona", "Player-1-Alice", 9226), -10,
        "465-xevt2: debt survives reload")
    -- Repair on a live current record (peerA2 may be offline after seed of later peers).
    local repairPeer = seedConflictPeer(9227)
    local d1 = select(1, GS:NewSoftDeleteOperation("xevt-d1"))
    local d2 = select(1, GS:NewSoftDeleteOperation("xevt-d2"))
    assertEq(GS:ApplyStagedConfigOperation(d1), "accepted", "465-xevt-repair: delete D1")
    assertEq(GS:ApplyStagedConfigOperation(d2), "accepted", "465-xevt-repair: delete D2")
    assertEq(GS.PersonalContributorItemTotal(repairPeer, "Alice-Garona", "Player-1-Alice", 9227), -10,
        "465-xevt-repair: debt −10")
    local repair = select(1, GS:NewAdjustmentOperation(9227, 10, "Alice-Garona"))
    assertTrue(repair ~= nil, "465-xevt-repair: prepare +10")
    assertEq(GS:ApplyStagedConfigOperation(repair), "accepted", "465-xevt-repair: apply +10")
    assertEq(GS.PersonalContributorItemTotal(repairPeer, "Alice-Garona", "Player-1-Alice", 9227), 0,
        "465-xevt-repair: zero after explicit adjustment")
end

do
    -- Surviving correction must stay active when a different deletion creates
    -- soft-delete baseline debt on the same item (Alice/Bob/Carol #465).
    local itemId = 9232
    local record = seedLiveCampaignWithItem(itemId, 100)
    injectProductionDonation(record, {
        id = "surv-d1", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionDonation(record, {
        id = "surv-d2", itemId = itemId, quantity = 10,
        actor = "Carol-Garona", actorGuid = "Player-1-Carol",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "surv-d2", "Bob-Garona", "Player-1-Bob"))
    assertTrue(corr ~= nil, "465-surv: prepare D2→Bob correction")
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "465-surv: apply correction")
    injectProductionAdjustment(record, {
        id = "surv-adj", itemId = itemId, quantity = -10,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", itemId), 0,
        "465-surv: Alice before delete")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 10,
        "465-surv: Bob before delete")
    assertEq(GS.PersonalContributorItemTotal(record, "Carol-Garona", "Player-1-Carol", itemId), 0,
        "465-surv: Carol before delete")
    local del = select(1, GS:NewSoftDeleteOperation("surv-d1"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-surv: delete D1")
    assertTrue(GS.IsEventSoftDeleted(record, "surv-d1"), "465-surv: D1 deleted")
    assertTrue(not GS.IsEventSoftDeleted(record, "surv-d2"), "465-surv: D2 survives")
    local alice, aliceErr = GS.PersonalContributorItemTotal(
        record, "Alice-Garona", "Player-1-Alice", itemId)
    local bob, bobErr = GS.PersonalContributorItemTotal(
        record, "Bob-Garona", "Player-1-Bob", itemId)
    local carol, carolErr = GS.PersonalContributorItemTotal(
        record, "Carol-Garona", "Player-1-Carol", itemId)
    assertEq(aliceErr, nil, "465-surv: Alice readable with debt")
    assertEq(bobErr, nil, "465-surv: Bob readable")
    assertEq(carolErr, nil, "465-surv: Carol readable")
    assertEq(alice, -10, "465-surv: Alice debt −10")
    assertEq(bob, 10, "465-surv: Bob keeps corrected credit")
    assertEq(carol, 0, "465-surv: Carol remains emptied")
    assertTrue(type(record.creditCorrections) == "table"
        and type(record.creditCorrections["surv-d2"]) == "table",
        "465-surv: D2 correction remains active")
    assertEq(record.creditCorrections["surv-d2"].attributed, "Bob-Garona",
        "465-surv: active head credits Bob")
    -- New local edits to the deleted row still fail closed.
    local localCorr, _, localReason = GS:NewContributorCorrectionOperation(
        "surv-d1", "Bob-Garona", "Player-1-Bob")
    assertNil(localCorr, "465-surv: edit deleted D1 rejected")
    assertEq(localReason, "already_deleted",
        "465-surv: deleted edit reason got " .. tostring(localReason))

    -- Reload reconstruction keeps the surviving correction + debt.
    simulateRuntimeReload()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(record)
    end
    if GS.InvalidateCreditCorrectionProjection then
        GS.InvalidateCreditCorrectionProjection(record)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(record, nil)
    end
    if GS.EnsureCreditCorrectionProjection then
        GS.EnsureCreditCorrectionProjection(record, nil)
    end
    assertTrue(GS.IsEventSoftDeleted(record, "surv-d1"), "465-surv: D1 deleted after reload")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", itemId), -10,
        "465-surv: Alice debt after reload")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 10,
        "465-surv: Bob credit after reload")
    assertTrue(type(record.creditCorrections["surv-d2"]) == "table",
        "465-surv: active correction after reload")

    -- Reordered remote replay: delete first, then prior correction, on a peer
    -- that starts without either op installed.
    local corrSnap = select(1, GS._SnapshotPublicOp(corr))
    local delSnap = select(1, GS._SnapshotPublicOp(del))
    local peer = seedLiveCampaignWithItem(itemId, 100)
    injectProductionDonation(peer, {
        id = "surv-d1", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionDonation(peer, {
        id = "surv-d2", itemId = itemId, quantity = 10,
        actor = "Carol-Garona", actorGuid = "Player-1-Carol",
    })
    injectProductionAdjustment(peer, {
        id = "surv-adj", itemId = itemId, quantity = -10,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    local function rebind(body, rec)
        local out = {}
        for k, v in pairs(body) do out[k] = v end
        out.guildKey = select(1, GS:GetCurrentContext()).guildKey
        out.datasetId = rec.datasetId
        out.campaignId = rec.currentCampaignId
        out.baseCampaignId = rec.currentCampaignId
        out.basePolicyRevision = rec.permission and rec.permission.revisionId
        out.baseTargetRevision = rec.datasetId
        return out
    end
    assertEq(select(1, GS:AdmitRemoteOperation(rebind(delSnap, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })), "accepted", "465-surv: peer delete-first")
    assertEq(select(1, GS:AdmitRemoteOperation(rebind(corrSnap, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })), "accepted", "465-surv: peer correction after delete")
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", itemId), -10,
        "465-surv: peer Alice debt")
    assertEq(GS.PersonalContributorItemTotal(peer, "Bob-Garona", "Player-1-Bob", itemId), 10,
        "465-surv: peer Bob keeps correction")
    assertEq(GS.PersonalContributorItemTotal(peer, "Carol-Garona", "Player-1-Carol", itemId), 0,
        "465-surv: peer Carol emptied")
    assertTrue(type(peer.creditCorrections) == "table"
        and type(peer.creditCorrections["surv-d2"]) == "table",
        "465-surv: peer D2 correction active")

    -- Explicit Alice +10 repairs debt without changing Bob's credit.
    local repair = select(1, GS:NewAdjustmentOperation(itemId, 10, "Alice-Garona"))
    assertTrue(repair ~= nil, "465-surv: prepare Alice +10")
    assertEq(GS:ApplyStagedConfigOperation(repair), "accepted", "465-surv: apply Alice +10")
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", itemId), 0,
        "465-surv: Alice repaired to zero")
    assertEq(GS.PersonalContributorItemTotal(peer, "Bob-Garona", "Player-1-Bob", itemId), 10,
        "465-surv: Bob unchanged after Alice repair")
end

do
    -- Soft-delete redrive: forced admit exception reports via geterrorhandler
    -- with debug OFF, clears re-entry guards, retains pending, then drains idle.
    local record = seedLiveCampaignWithItem(9233, 200)
    local ctx = select(1, GS:GetCurrentContext())
    record.operations.pending = record.operations.pending or {}
    local pendingIds = {}
    for i = 1, 3 do
        local donId = string.format("sd-ex-don-%02d", i)
        injectProductionDonation(record, {
            id = donId, itemId = 9233, quantity = 2,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
        local id = string.format("sd-ex-del-%02d", i)
        pendingIds[#pendingIds + 1] = id
        record.operations.pending[id] = {
            id = id,
            sender = "Alice-Garona",
            reason = "pending_event",
            body = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = id,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.SOFT_DELETE_EVENT,
                target = donId,
                value = {
                    eventId = donId,
                    eventKind = "donation",
                    itemId = 9233,
                    quantity = 2,
                    attributed = "Alice-Garona",
                    attributedGuid = "Player-1-Alice",
                },
                actorGuid = "Player-1-Alice",
                actorName = "Alice-Garona",
                timestamp = world.time + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            },
        }
    end
    if GS._ClearSoftDeleteRedriveContinuationForTest then
        GS._ClearSoftDeleteRedriveContinuationForTest(record)
    end
    world.debugLogs = {}
    SF.Debug:SetEnabled(false)
    local capturedErrors = {}
    local prevHandler = geterrorhandler
    geterrorhandler = function()
        return function(err)
            capturedErrors[#capturedErrors + 1] = err
        end
    end
    local realAdmit = GS.AdmitRemoteOperation
    local calls = 0
    GS.AdmitRemoteOperation = function(self, body, opts)
        calls = calls + 1
        if calls == 1 then
            error("forced soft-delete redrive admit failure")
        end
        return realAdmit(self, body, opts)
    end
    local promoted1, attempts1 = GS.RedrivePendingSoftDeletes(record, {
        itemId = 9233, maxAttempts = 8,
    })
    GS.AdmitRemoteOperation = realAdmit
    geterrorhandler = prevHandler
    assertEq(GS._softDeleteRedriveAdmitActive, false,
        "465-ex: admit guard cleared after exception")
    assertTrue(attempts1 >= 1, "465-ex: wave attempted admits")
    assertTrue(promoted1 >= 0, "465-ex: promoted count readable")
    local sawHandler = false
    for i = 1, #capturedErrors do
        local msg = tostring(capturedErrors[i] or "")
        if msg:find("forced soft%-delete redrive admit failure", 1, false) then
            sawHandler = true
            break
        end
    end
    assertTrue(sawHandler, "465-ex: geterrorhandler received original failure")
    assertEq(#world.debugLogs, 0, "465-ex: debug OFF produced no SF.Debug logs")
    local stillPending = 0
    for i = 1, #pendingIds do
        if record.operations.pending[pendingIds[i]] then
            stillPending = stillPending + 1
        end
    end
    assertTrue(stillPending >= 1, "465-ex: failed admit left pending work")
    -- Subsequent eligible drain succeeds and becomes idle.
    if GS._ClearSoftDeleteRedriveContinuationForTest then
        GS._ClearSoftDeleteRedriveContinuationForTest(record)
    end
    timers = {}
    GS.RedrivePendingSoftDeletes(record, { itemId = 9233, maxAttempts = 8 })
    local slices = 0
    while slices < 16 do
        if not runOneDueTimer() then
            break
        end
        slices = slices + 1
    end
    flushTimers()
    local remaining = 0
    for id, entry in pairs(record.operations.pending or {}) do
        local body = entry and entry.body
        if type(body) == "table" and body.kind == GS.KIND.SOFT_DELETE_EVENT then
            remaining = remaining + 1
        end
    end
    assertEq(remaining, 0, "465-ex: subsequent drain cleared pending")
    assertTrue(#timers == 0, "465-ex: idle after successful drain")
    assertEq(GS._softDeleteRedriveAdmitActive, false, "465-ex: idle guard cleared")
    for i = 1, 3 do
        assertTrue(GS.IsEventSoftDeleted(record, string.format("sd-ex-don-%02d", i)),
            "465-ex: donation soft-deleted " .. i)
    end
end

do
    -- No soft-delete: ordinary invalid Bob −20 accounting stays unavailable (#459).
    local record = seedLiveCampaignWithItem(9240, 50)
    injectProductionDonation(record, {
        id = "nodebt-don", itemId = 9240, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "nodebt-don", "Bob-Garona", "Player-1-Bob"))
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "465-nodebt: correct Alice→Bob")
    injectProductionAdjustment(record, {
        id = "nodebt-adj", itemId = 9240, quantity = -20,
        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
    })
    GS.InvalidateCreditCorrectionProjection(record)
    local okFail, errFail = GS.RebuildCreditCorrectionProjection(record, nil)
    assertTrue(okFail == false, "465-nodebt: rebuild fails")
    assertEq(errFail, "player_negative", "465-nodebt: player_negative")
    local bobTotal, bobErr = GS.PersonalContributorItemTotal(
        record, "Bob-Garona", "Player-1-Bob", 9240)
    assertNil(bobTotal, "465-nodebt: Bob total unavailable")
    assertEq(bobErr, GS.CREDIT_UNAVAILABLE, "465-nodebt: credit_unavailable")
end

do
    -- Unrelated soft-delete on another item must not permit Bob −20 debt floors.
    local record = seedLiveCampaignWithItem(9241, 50)
    local other = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 92411 }, {
        itemId = 92411, goal = 20, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(other), "accepted", "465-unrel: add other item")
    injectProductionDonation(record, {
        id = "unrel-other", itemId = 92411, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local delOther = select(1, GS:NewSoftDeleteOperation("unrel-other"))
    assertEq(GS:ApplyStagedConfigOperation(delOther), "accepted", "465-unrel: delete other item")
    injectProductionDonation(record, {
        id = "unrel-don", itemId = 9241, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "unrel-don", "Bob-Garona", "Player-1-Bob"))
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "465-unrel: correct Alice→Bob")
    injectProductionAdjustment(record, {
        id = "unrel-adj", itemId = 9241, quantity = -20,
        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
    })
    GS.InvalidateCreditCorrectionProjection(record)
    local okFail, errFail = GS.RebuildCreditCorrectionProjection(record, nil)
    assertTrue(okFail == false, "465-unrel: rebuild fails")
    assertEq(errFail, "player_negative", "465-unrel: player_negative")
end

do
    -- Late alias binding: delete-before-alias must not revive credit on C.
    -- Author deletes via alias B; peer receives B while only C is known →
    -- pending_event; late B→C wake migrates heads and promotes the delete.
    local author = seedLiveCampaignWithItem(9242, 40)
    local donA = injectProductionDonation(author, {
        id = "ctx:late-canon", itemId = 9242, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    donA.txnId = "ctx:late-canon"
    assertTrue(GS._AddTxnAlias(author, "ctx:late-canon", "ctx:late-alias", donA),
        "465-late: author alias B for prepare")
    local del = select(1, GS:NewSoftDeleteOperation("ctx:late-alias"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-late: author delete via B")
    assertTrue(GS.IsEventSoftDeleted(author, "ctx:late-canon"), "465-late: author C deleted")
    assertTrue(GS.IsEventSoftDeleted(author, "ctx:late-alias"), "465-late: author B deleted")

    local peer = seedLiveCampaignWithItem(9242, 40)
    local donP = injectProductionDonation(peer, {
        id = "ctx:late-canon", itemId = 9242, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    donP.txnId = "ctx:late-canon"
    local delSnap = select(1, GS._SnapshotPublicOp(del))
    local function rebind(body, rec)
        local out = {}
        for k, v in pairs(body) do out[k] = v end
        out.guildKey = select(1, GS:GetCurrentContext()).guildKey
        out.datasetId = rec.datasetId
        out.campaignId = rec.currentCampaignId
        out.baseCampaignId = rec.currentCampaignId
        out.basePolicyRevision = rec.permission and rec.permission.revisionId
        out.baseTargetRevision = rec.datasetId
        -- Force target/value to alias B for delete-before-alias delivery.
        out.target = "ctx:late-alias"
        if type(out.value) == "table" then
            local v = {}
            for vk, vv in pairs(out.value) do v[vk] = vv end
            v.eventId = "ctx:late-alias"
            out.value = v
        end
        return out
    end
    local admitSt, admitReason = GS:AdmitRemoteOperation(rebind(delSnap, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })
    assertEq(admitSt, "pending", "465-late: peer parks delete of unknown B")
    assertEq(admitReason, "pending_event", "465-late: pending_event reason")
    assertTrue(peer.operations.pending and peer.operations.pending[del.id] ~= nil,
        "465-late: delete retained pending")
    assertTrue(not GS.IsEventSoftDeleted(peer, "ctx:late-canon"),
        "465-late: C still visible before alias")
    assertTrue(GS._AddTxnAlias(peer, "ctx:late-canon", "ctx:late-alias", donP),
        "465-late: peer late alias B→C")
    flushTimers()
    assertTrue(GS.IsEventSoftDeleted(peer, "ctx:late-canon"),
        "465-late: canonical C deleted after late alias")
    assertTrue(GS.IsEventSoftDeleted(peer, "ctx:late-alias"),
        "465-late: alias B deleted after late alias")
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", 9242), 0,
        "465-late: credit not restored")
    -- Competing heads must fold onto one terminal delete key.
    local heads = peer.operations.heads
    local deleteHeads = 0
    if type(heads) == "table" then
        for k in pairs(heads) do
            if type(k) == "string" and k:sub(1, 7) == "delete:" then
                deleteHeads = deleteHeads + 1
            end
        end
    end
    assertTrue(deleteHeads == 1,
        "465-late: single logical delete head got " .. tostring(deleteHeads))
    simulateRuntimeReload()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(peer)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(peer, nil)
    end
    assertTrue(GS.IsEventSoftDeleted(peer, "ctx:late-canon"),
        "465-late: canonical deleted after reload")
    assertTrue(GS.IsEventSoftDeleted(peer, "ctx:late-alias"),
        "465-late: alias deleted after reload")
end

do
    -- Bound soft-delete pending filter: shared lookup, no per-entry history scan.
    local record = seedLiveCampaignWithItem(9243, 500)
    local ctx = select(1, GS:GetCurrentContext())
    -- Inflate archive so a naive FindLedgerEventById per pending would be costly.
    record.accounting._consumableEventArchive = record.accounting._consumableEventArchive or {}
    local archive = record.accounting._consumableEventArchive
    for i = 1, 200 do
        archive[#archive + 1] = {
            type = GS.LEDGER_EVENT.DONATION,
            id = string.format("arch-filler-%03d", i),
            txnId = string.format("arch-filler-%03d", i),
            itemId = 9243,
            quantity = 1,
            actor = "Alice-Garona",
            actorGuid = "Player-1-Alice",
            campaignId = record.currentCampaignId,
            datasetId = record.datasetId,
            gsProductionCredit = true,
            generation = 1,
            timestamp = world.time - 1000 - i,
        }
    end
    record.operations.pending = record.operations.pending or {}
    for i = 1, 40 do
        local donId = string.format("filt-don-%02d", i)
        injectProductionDonation(record, {
            id = donId, itemId = 9243, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
        local id = string.format("filt-del-%02d", i)
        record.operations.pending[id] = {
            id = id,
            sender = "Alice-Garona",
            reason = "pending_event",
            body = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = id,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.SOFT_DELETE_EVENT,
                target = donId,
                value = {
                    eventId = donId, eventKind = "donation", itemId = 9243, quantity = 1,
                    attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
                },
                actorGuid = "Player-1-Alice",
                actorName = "Alice-Garona",
                timestamp = world.time + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            },
        }
    end
    if GS._ClearSoftDeleteRedriveContinuationForTest then
        GS._ClearSoftDeleteRedriveContinuationForTest(record)
    end
    GS._softDeleteRedriveLookupVisits = 0
    local beforeFind = 0
    local realFind = GS.FindLedgerEventById
    GS.FindLedgerEventById = function(...)
        beforeFind = beforeFind + 1
        return realFind(...)
    end
    GS.RedrivePendingSoftDeletes(record, {
        eventId = "filt-don-01", maxAttempts = 8, maxFilterVisits = 64,
    })
    GS.FindLedgerEventById = realFind
    flushTimers()
    assertTrue(beforeFind < 40,
        "465-filt: filter avoided per-entry FindLedger scans got " .. tostring(beforeFind))
    assertTrue((tonumber(GS._softDeleteRedriveLookupVisits) or 0) > 0,
        "465-filt: shared canonical lookup charged")
    assertTrue(GS.IsEventSoftDeleted(record, "filt-don-01")
        or (record.operations.pending and next(record.operations.pending)),
        "465-filt: wake progressed or retained pending")
end

do
    -- Orphaned accepted deletion after archive eviction still adopts.
    local record = seedLiveCampaignWithItem(9244, 40)
    injectProductionDonation(record, {
        id = "orphan-don", itemId = 9244, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local del = select(1, GS:NewSoftDeleteOperation("orphan-don"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-orphan: delete")
    assertTrue(GS.IsEventSoftDeleted(record, "orphan-don"), "465-orphan: deleted")
    -- Evict the base ledger row while keeping the accepted soft-delete op.
    local live = record.accounting._consumableEvents
    local kept = {}
    for i = 1, #live do
        if live[i].id ~= "orphan-don" then
            kept[#kept + 1] = live[i]
        end
    end
    record.accounting._consumableEvents = kept
    if GS._BumpAccountingMutation then
        GS._BumpAccountingMutation(record)
    end
    assertNil(GS.FindLedgerEventById(record, "orphan-don"), "465-orphan: evidence gone")
    assertTrue(record.operations.records[del.id] ~= nil, "465-orphan: delete op retained")
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    local exportBodies = collectAllExportBodies()
    assertTrue(#exportBodies >= 1, "465-orphan: export bodies")
    local sourceDataset = record.datasetId
    local delId = del.id
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-orphan: begin")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-orphan: transfer ready")
    local commitSt, commitErr = GS:CommitDatasetAdoption()
    assertEq(commitSt, "accepted",
        "465-orphan: commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
    local adopted = GS:GetCurrentRecord()
    assertTrue(adopted ~= nil, "465-orphan: adopted record")
    assertTrue(adopted.operations.records[delId] ~= nil, "465-orphan: delete history")
    assertTrue(GS.IsEventSoftDeleted(adopted, "orphan-don"),
        "465-orphan: deletion projected without base evidence")
    -- Reintroduce matching evidence must not restore credit.
    injectProductionDonation(adopted, {
        id = "orphan-don", itemId = 9244, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(adopted)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(adopted, nil)
    end
    assertTrue(GS.IsEventSoftDeleted(adopted, "orphan-don"),
        "465-orphan: still deleted after evidence returns")
    assertEq(GS.PersonalContributorItemTotal(adopted, "Alice-Garona", "Player-1-Alice", 9244), 0,
        "465-orphan: credit stays excluded")
end

do
    -- Two accepted deletion revisions + retention-evicted evidence: winner-first
    -- adoption must retain both op IDs without pending the loser (#465
    -- discussion_r4517511170). Ordinary unknown-target ingress stays pending.
    local record = seedLiveCampaignWithItem(9245, 40)
    local ctx = select(1, GS:GetCurrentContext())
    injectProductionDonation(record, {
        id = "orphan2-don", itemId = 9245, quantity = 6,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local function makeDel(id, ts, actorName, actorGuid)
        return {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = id,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.SOFT_DELETE_EVENT,
            target = "orphan2-don",
            value = {
                eventId = "orphan2-don", eventKind = "donation",
                itemId = 9245, quantity = 6,
                attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
            },
            actorGuid = actorGuid,
            actorName = actorName,
            timestamp = ts,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
    end
    -- Source-authored by Alice so adoption authenticity matches the exporter.
    local late = makeDel("orphan2-win", world.time + 20, "Alice-Garona", "Player-1-Alice")
    local early = makeDel("orphan2-lose", world.time + 2, "Alice-Garona", "Player-1-Alice")
    local function admitSettle(op)
        local st, r = GS:AdmitRemoteOperation(op, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        local g = 0
        while st == "pending" and g < 64 do
            if not runOneDueTimer() then break end
            st, r = GS:AdmitRemoteOperation(op, {
                sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
            })
            g = g + 1
        end
        return st, r
    end
    local stW, rW = admitSettle(late)
    assertTrue(stW == "accepted" or stW == "duplicate",
        "465-orphan2: source winner st=" .. tostring(stW) .. "/" .. tostring(rW))
    local loseSt, loseReason = admitSettle(early)
    assertTrue(loseSt == "accepted" or loseSt == "duplicate",
        "465-orphan2: source loser retained got " .. tostring(loseSt) .. "/" .. tostring(loseReason))
    assertTrue(record.operations.records["orphan2-win"] ~= nil, "465-orphan2: win in source")
    assertTrue(record.operations.records["orphan2-lose"] ~= nil, "465-orphan2: lose in source")
    local tKeySrc = GS.SoftDeleteTargetKey(record, "orphan2-don")
    assertEq(record.operations.heads[tKeySrc], "orphan2-win", "465-orphan2: source head")
    -- Evict base evidence while both delete revisions remain accepted.
    local live = record.accounting._consumableEvents
    local kept = {}
    for i = 1, #live do
        if live[i].id ~= "orphan2-don" then
            kept[#kept + 1] = live[i]
        end
    end
    record.accounting._consumableEvents = kept
    if GS._BumpAccountingMutation then
        GS._BumpAccountingMutation(record)
    end
    assertNil(GS.FindLedgerEventById(record, "orphan2-don"), "465-orphan2: evidence gone")
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    local exportBodies = collectAllExportBodies()
    assertTrue(#exportBodies >= 1, "465-orphan2: export bodies")
    local winBody, loseBody = nil, nil
    local others = {}
    for i = 1, #exportBodies do
        local row = exportBodies[i]
        local op = row.body and row.body.op
        if type(op) == "table" and op.id == "orphan2-win" then
            winBody = row
        elseif type(op) == "table" and op.id == "orphan2-lose" then
            loseBody = row
        else
            others[#others + 1] = row
        end
    end
    assertTrue(winBody ~= nil, "465-orphan2: winner exported")
    assertTrue(loseBody ~= nil, "465-orphan2: loser exported")
    local sourceDataset = record.datasetId
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-orphan2: begin")
    -- Winner-first replay: buffer the newer delete before the older loser.
    local ordered = {}
    for i = 1, #others do
        ordered[#ordered + 1] = others[i]
    end
    ordered[#ordered + 1] = winBody
    ordered[#ordered + 1] = loseBody
    for i = 1, #ordered do
        GS:BufferAdoptionRecord(ordered[i].id, ordered[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-orphan2: transfer ready")
    local commitSt, commitErr = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while commitSt == "pending" and gAdopt < 128 do
        runOneDueTimer()
        commitSt, commitErr = GS:CommitDatasetAdoption()
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(commitSt, "accepted",
        "465-orphan2: commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
    local adopted = GS:GetCurrentRecord()
    assertTrue(adopted ~= nil, "465-orphan2: adopted record")
    assertTrue(adopted.operations.records["orphan2-win"] ~= nil, "465-orphan2: win survives")
    assertTrue(adopted.operations.records["orphan2-lose"] ~= nil, "465-orphan2: lose survives")
    assertTrue(not (adopted.operations.pending and adopted.operations.pending["orphan2-lose"]),
        "465-orphan2: loser not pending")
    assertTrue(GS.IsEventSoftDeleted(adopted, "orphan2-don"), "465-orphan2: deleted")
    local tKey = GS.SoftDeleteTargetKey(adopted, "orphan2-don")
    assertEq(adopted.operations.heads[tKey], "orphan2-win", "465-orphan2: winning head")
    local entry = adopted.eventDeletions and adopted.eventDeletions["orphan2-don"]
    assertTrue(type(entry) == "table", "465-orphan2: projection")
    assertEq(entry.revisionId, "orphan2-win", "465-orphan2: winning revisionId")
    assertEq(entry.actorName, "Alice-Garona", "465-orphan2: winning actor")
    assertEq(entry.deletedAt, late.timestamp, "465-orphan2: winning timestamp")
    simulateRuntimeReload()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(adopted)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(adopted, nil)
    end
    assertTrue(GS.IsEventSoftDeleted(adopted, "orphan2-don"),
        "465-orphan2: deletion survives reload")
    assertTrue(adopted.operations.records["orphan2-win"] ~= nil,
        "465-orphan2: win after reload")
    assertTrue(adopted.operations.records["orphan2-lose"] ~= nil,
        "465-orphan2: lose after reload")
    local tKey2 = GS.SoftDeleteTargetKey(adopted, "orphan2-don")
    assertEq(adopted.operations.heads[tKey2], "orphan2-win",
        "465-orphan2: winning head after reload")
    local entry2 = adopted.eventDeletions and adopted.eventDeletions["orphan2-don"]
    assertTrue(type(entry2) == "table", "465-orphan2: projection after reload")
    assertEq(entry2.revisionId, "orphan2-win", "465-orphan2: winner after reload")
end

do
    -- Ordinary unknown-target soft-delete ingress remains pending — orphan
    -- allowance is adoption/source-accepted only.
    local record = seedLiveCampaignWithItem(9246, 40)
    local ctx = select(1, GS:GetCurrentContext())
    local ghost = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "ghost-del-unknown",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.SOFT_DELETE_EVENT,
        target = "ghost-don-missing",
        value = {
            eventId = "ghost-don-missing", eventKind = "donation",
            itemId = 9246, quantity = 1,
            attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    local st, reason = GS:AdmitRemoteOperation(ghost, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(st, "pending", "465-unk: unknown target stays pending")
    assertEq(reason, "pending_event", "465-unk: pending_event reason")
    assertTrue(record.operations.pending and record.operations.pending[ghost.id] ~= nil,
        "465-unk: parked in pending")
    assertTrue(not GS.IsEventSoftDeleted(record, "ghost-don-missing"),
        "465-unk: no unrestricted deletion")
end

do
    -- Soft-delete alias ownership: pending delete body names B, late B→C migrates
    -- head to delete:C, then registry eviction + capacity reclaim must keep B→C
    -- (#465 discussion_r4518383396).
    local author = seedLiveCampaignWithItem(9250, 40)
    local donA = injectProductionDonation(author, {
        id = "ctx:sd-alias-c", itemId = 9250, quantity = 7,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    donA.txnId = "ctx:sd-alias-c"
    assertTrue(GS._AddTxnAlias(author, "ctx:sd-alias-c", "ctx:sd-alias-b", donA),
        "465-sd-alias: author B→C for prepare")
    local del = select(1, GS:NewSoftDeleteOperation("ctx:sd-alias-b"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-sd-alias: author delete")
    local delSnap = select(1, GS._SnapshotPublicOp(del))

    local peer = seedLiveCampaignWithItem(9250, 40)
    local donP = injectProductionDonation(peer, {
        id = "ctx:sd-alias-c", itemId = 9250, quantity = 7,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    donP.txnId = "ctx:sd-alias-c"
    local function rebindAliasDelete(body, rec)
        local out = {}
        for k, v in pairs(body) do out[k] = v end
        out.guildKey = select(1, GS:GetCurrentContext()).guildKey
        out.datasetId = rec.datasetId
        out.campaignId = rec.currentCampaignId
        out.baseCampaignId = rec.currentCampaignId
        out.basePolicyRevision = rec.permission and rec.permission.revisionId
        out.baseTargetRevision = rec.datasetId
        out.target = "ctx:sd-alias-b"
        if type(out.value) == "table" then
            local v = {}
            for vk, vv in pairs(out.value) do v[vk] = vv end
            v.eventId = "ctx:sd-alias-b"
            out.value = v
        end
        return out
    end
    local admitSt, admitReason = GS:AdmitRemoteOperation(rebindAliasDelete(delSnap, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })
    assertEq(admitSt, "pending", "465-sd-alias: peer parks B delete")
    assertEq(admitReason, "pending_event", "465-sd-alias: pending_event")
    assertTrue(GS._AddTxnAlias(peer, "ctx:sd-alias-c", "ctx:sd-alias-b", donP),
        "465-sd-alias: late B→C")
    flushTimers()
    assertTrue(GS.IsEventSoftDeleted(peer, "ctx:sd-alias-c"), "465-sd-alias: C deleted")
    assertTrue(GS.IsEventSoftDeleted(peer, "ctx:sd-alias-b"), "465-sd-alias: B deleted")
    local tKey = GS.SoftDeleteTargetKey(peer, "ctx:sd-alias-c")
    assertEq(tKey, "delete:ctx:sd-alias-c", "465-sd-alias: terminal head key")
    assertEq(peer.operations.heads[tKey], del.id, "465-sd-alias: head at delete:C")
    local stored = peer.operations.records[del.id]
    assertTrue(type(stored) == "table", "465-sd-alias: body retained")
    assertEq(stored.target, "ctx:sd-alias-b", "465-sd-alias: body still names B")
    local cfg = peer.accounting._consumables
    assertEq(cfg.creditEventAliases["ctx:sd-alias-b"], "ctx:sd-alias-c",
        "465-sd-alias: durable B→C before reclaim")
    -- Saturate alias map with junk; required soft-delete binding must survive prune.
    local maxAliases = tonumber(GS.MAX_CREDIT_EVENT_ALIASES) or 2048
    local junkN = 0
    for i = 1, maxAliases do
        local junk = string.format("ctx:sd-junk-%04d", i)
        if cfg.creditEventAliases[junk] == nil and junk ~= "ctx:sd-alias-b" then
            cfg.creditEventAliases[junk] = string.format("ctx:sd-junk-canon-%04d", i)
            junkN = junkN + 1
        end
        if junkN >= maxAliases - 2 then
            break
        end
    end
    cfg.txnRegistry = {}
    local removed = GS.PruneUnusedCreditEventAliases(peer)
    assertTrue(tonumber(removed) or 0 >= 0, "465-sd-alias: prune ran")
    assertEq(cfg.creditEventAliases["ctx:sd-alias-b"], "ctx:sd-alias-c",
        "465-sd-alias: B→C retained after reclaim")
    local ctx = select(1, GS:GetCurrentContext())
    local warmOk, warmErr = GS._ValidateGuildRecordStructure(ctx.guildKey, peer)
    assertTrue(warmOk, "465-sd-alias: validate after eviction got " .. tostring(warmErr))
    assertTrue(GS.IsEventSoftDeleted(peer, "ctx:sd-alias-c"),
        "465-sd-alias: C stays deleted")
    assertTrue(GS.IsEventSoftDeleted(peer, "ctx:sd-alias-b"),
        "465-sd-alias: B resolves deleted")
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", 9250), 0,
        "465-sd-alias: credit stays excluded")
    for i = 1, 32 do
        cfg.creditEventAliases[string.format("ctx:sd-extra-%04d", i)] =
            string.format("ctx:sd-extra-canon-%04d", i)
    end
    GS.PruneUnusedCreditEventAliases(peer)
    assertEq(cfg.creditEventAliases["ctx:sd-alias-b"], "ctx:sd-alias-c",
        "465-sd-alias: ownership after second reclaim")
    assertNil(cfg.creditEventAliases["ctx:sd-extra-0001"],
        "465-sd-alias: unrelated alias reclaimed")
    -- Fresh adoption export/reload keeps C deleted exactly once.
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    local exportBodies = collectAllExportBodies()
    assertTrue(#exportBodies >= 1, "465-sd-alias: export bodies")
    local sourceDataset = peer.datasetId
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-sd-alias: begin adoption")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-sd-alias: transfer ready")
    local commitSt, commitErr = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while commitSt == "pending" and gAdopt < 128 do
        runOneDueTimer()
        commitSt, commitErr = GS:CommitDatasetAdoption()
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(commitSt, "accepted",
        "465-sd-alias: commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
    local adopted = GS:GetCurrentRecord()
    assertTrue(GS.IsEventSoftDeleted(adopted, "ctx:sd-alias-c"),
        "465-sd-alias: adopted C deleted")
    local deleteHeads = 0
    for k in pairs(adopted.operations.heads or {}) do
        if type(k) == "string" and k:sub(1, 7) == "delete:" then
            deleteHeads = deleteHeads + 1
        end
    end
    assertEq(deleteHeads, 1, "465-sd-alias: single delete head after adoption")
    simulateRuntimeReload()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(adopted)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(adopted, nil)
    end
    assertTrue(GS.IsEventSoftDeleted(adopted, "ctx:sd-alias-c"),
        "465-sd-alias: deleted after reload")
end

do
    -- Altered soft-delete payload must not forge debt floors when evidence exists
    -- (#465 discussion_r4518378042). Verified facts bind to the real event.
    local itemId = 9251
    local record = seedLiveCampaignWithItem(itemId, 80)
    injectProductionDonation(record, {
        id = "forge-don", itemId = itemId, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(record, {
        id = "forge-adj", itemId = itemId, quantity = -3,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    local ctx = select(1, GS:GetCurrentContext())
    local forged = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "forge-del",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.SOFT_DELETE_EVENT,
        target = "forge-don",
        value = {
            eventId = "forge-don", eventKind = "donation",
            itemId = itemId, quantity = 50,
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 5,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    assertEq(select(1, GS:AdmitRemoteOperation(forged, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })), "accepted", "465-forge: forged-payload delete accepted")
    assertTrue(GS.IsEventSoftDeleted(record, "forge-don"), "465-forge: deleted")
    local entry = record.eventDeletions and record.eventDeletions["forge-don"]
    assertTrue(type(entry) == "table" and entry.verified == true, "465-forge: verified facts")
    assertEq(entry.quantity, 3, "465-forge: quantity from evidence not payload")
    assertEq(entry.attributed, "Alice-Garona", "465-forge: attribution from evidence")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", itemId), -3,
        "465-forge: Alice debt −3 from real qty")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 0,
        "465-forge: Bob gets no forged floor")
    -- Ordinary correction that would need the forged floor still fails closed.
    injectProductionDonation(record, {
        id = "forge-keep", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr, st, reason = GS:NewContributorCorrectionOperation(
        "forge-keep", "Bob-Garona", "Player-1-Bob")
    -- After Alice −3 and +10, Alice is +7; moving +10 to Bob leaves Alice −3 which
    -- is permitted only as deletion debt — FloorOk uses live balance and rejects.
    assertNil(corr, "465-forge: unsafe local correction rejected")
    assertEq(reason, "player_negative",
        "465-forge: player_negative got " .. tostring(reason) .. "/" .. tostring(st))
end

do
    -- Verified deletion debt survives evidence eviction, fresh adoption, reload,
    -- and an explicit officer repair (#465 discussion_r4518383410).
    local itemId = 9252
    local record = seedLiveCampaignWithItem(itemId, 80)
    injectProductionDonation(record, {
        id = "vd-don", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(record, {
        id = "vd-adj", itemId = itemId, quantity = -10,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    local del = select(1, GS:NewSoftDeleteOperation("vd-don"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-vd: delete")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", itemId), -10,
        "465-vd: debt before eviction")
    local entry = record.eventDeletions and record.eventDeletions["vd-don"]
    assertTrue(type(entry) == "table" and entry.verified == true, "465-vd: verified before eviction")
    assertEq(entry.quantity, 10, "465-vd: verified qty")
    -- Evict the deleted donation; keep the −10 adjustment.
    local live = record.accounting._consumableEvents
    local kept = {}
    for i = 1, #live do
        if live[i].id ~= "vd-don" then
            kept[#kept + 1] = live[i]
        end
    end
    record.accounting._consumableEvents = kept
    if GS._BumpAccountingMutation then
        GS._BumpAccountingMutation(record)
    end
    assertNil(GS.FindLedgerEventById(record, "vd-don"), "465-vd: evidence gone")
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(record)
    end
    if GS.InvalidateCreditCorrectionProjection then
        GS.InvalidateCreditCorrectionProjection(record)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(record, nil)
    end
    local entry2 = record.eventDeletions and record.eventDeletions["vd-don"]
    assertTrue(type(entry2) == "table" and entry2.verified == true,
        "465-vd: verified retained after eviction")
    assertEq(entry2.quantity, 10, "465-vd: verified qty after eviction")
    local alice, aliceErr = GS.PersonalContributorItemTotal(
        record, "Alice-Garona", "Player-1-Alice", itemId)
    assertEq(aliceErr, nil, "465-vd: readable after eviction")
    assertEq(alice, -10, "465-vd: signed debt after eviction")
    simulateRuntimeReload()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(record)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(record, nil)
    end
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", itemId), -10,
        "465-vd: debt after reload")
    settleRoster()
    -- Explicit repair on the source after eviction/reload.
    local repairSrc = select(1, GS:NewAdjustmentOperation(itemId, 10, "Alice-Garona"))
    assertTrue(repairSrc ~= nil, "465-vd: prepare source repair")
    assertEq(GS:ApplyStagedConfigOperation(repairSrc), "accepted", "465-vd: source repair")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", itemId), 0,
        "465-vd: source repaired to zero")
end

do
    -- Fresh peer receipt (delete admit) with evidence present, then eviction retains
    -- verified debt through reload and explicit repair (#465 discussion_r4518383410).
    local itemId = 9254
    local author = seedLiveCampaignWithItem(itemId, 80)
    injectProductionDonation(author, {
        id = "vd2-don", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(author, {
        id = "vd2-adj", itemId = itemId, quantity = -10,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    local del = select(1, GS:NewSoftDeleteOperation("vd2-don"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-vd2: author delete")
    local delSnap = select(1, GS._SnapshotPublicOp(del))
    local peer = seedLiveCampaignWithItem(itemId, 80)
    injectProductionDonation(peer, {
        id = "vd2-don", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(peer, {
        id = "vd2-adj", itemId = itemId, quantity = -10,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    local function rebind(body, rec)
        local out = {}
        for k, v in pairs(body) do out[k] = v end
        out.guildKey = select(1, GS:GetCurrentContext()).guildKey
        out.datasetId = rec.datasetId
        out.campaignId = rec.currentCampaignId
        out.baseCampaignId = rec.currentCampaignId
        out.basePolicyRevision = rec.permission and rec.permission.revisionId
        out.baseTargetRevision = rec.datasetId
        return out
    end
    assertEq(select(1, GS:AdmitRemoteOperation(rebind(delSnap, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })), "accepted", "465-vd2: peer admits delete")
    assertTrue(GS.IsEventSoftDeleted(peer, "vd2-don"), "465-vd2: peer deleted")
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", itemId), -10,
        "465-vd2: peer readable debt")
    local entry = peer.eventDeletions and peer.eventDeletions["vd2-don"]
    assertTrue(type(entry) == "table" and entry.verified == true, "465-vd2: verified on peer")
    -- Evict donation evidence; verified facts must keep debt readable.
    local liveA = peer.accounting._consumableEvents
    local keptA = {}
    for i = 1, #liveA do
        if liveA[i].id ~= "vd2-don" then
            keptA[#keptA + 1] = liveA[i]
        end
    end
    peer.accounting._consumableEvents = keptA
    if GS._BumpAccountingMutation then
        GS._BumpAccountingMutation(peer)
    end
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(peer)
    end
    if GS.InvalidateCreditCorrectionProjection then
        GS.InvalidateCreditCorrectionProjection(peer)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(peer, nil)
    end
    local aEntry = peer.eventDeletions and peer.eventDeletions["vd2-don"]
    assertTrue(type(aEntry) == "table" and aEntry.verified == true,
        "465-vd2: verified after eviction")
    assertEq(aEntry.quantity, 10, "465-vd2: verified qty after eviction")
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", itemId), -10,
        "465-vd2: debt after eviction")
    simulateRuntimeReload()
    settleRoster()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(peer)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(peer, nil)
    end
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", itemId), -10,
        "465-vd2: debt after reload")
    local repair = select(1, GS:NewAdjustmentOperation(itemId, 10, "Alice-Garona"))
    assertTrue(repair ~= nil, "465-vd2: prepare repair")
    assertEq(GS:ApplyStagedConfigOperation(repair), "accepted", "465-vd2: apply repair")
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", itemId), 0,
        "465-vd2: repaired to zero")
end

do
    -- Paired regressions for discussion_r4518383404 (DO NOT rewrite baseline):
    -- (1) new local post-delete correction that alone crosses zero is rejected;
    -- (2) valid correction-before-delete survives delete-first remote replay.
    local itemId = 9253
    -- (1) Local reject: D1 +10, D2 +10, Alice −5; delete D1 → Alice +5;
    -- correcting D2→Bob would leave Alice −5 and must fail FloorOk.
    local localRec = seedLiveCampaignWithItem(itemId, 100)
    injectProductionDonation(localRec, {
        id = "pair-d1", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionDonation(localRec, {
        id = "pair-d2", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(localRec, {
        id = "pair-adj", itemId = itemId, quantity = -5,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    local delLocal = select(1, GS:NewSoftDeleteOperation("pair-d1"))
    assertEq(GS:ApplyStagedConfigOperation(delLocal), "accepted", "465-pair-local: delete D1")
    assertEq(GS.PersonalContributorItemTotal(localRec, "Alice-Garona", "Player-1-Alice", itemId), 5,
        "465-pair-local: Alice +5 after delete")
    local badCorr, _, badReason = GS:NewContributorCorrectionOperation(
        "pair-d2", "Bob-Garona", "Player-1-Bob")
    assertNil(badCorr, "465-pair-local: unsafe correction rejected")
    assertEq(badReason, "player_negative",
        "465-pair-local: player_negative got " .. tostring(badReason))

    -- (2) Historical: correct D2→Bob while Alice still has +5, then delete D1.
    local hist = seedLiveCampaignWithItem(itemId, 100)
    injectProductionDonation(hist, {
        id = "pair-d1", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionDonation(hist, {
        id = "pair-d2", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(hist, {
        id = "pair-adj", itemId = itemId, quantity = -5,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    local goodCorr = select(1, GS:NewContributorCorrectionOperation(
        "pair-d2", "Bob-Garona", "Player-1-Bob"))
    assertTrue(goodCorr ~= nil, "465-pair-hist: prepare D2→Bob")
    assertEq(GS:ApplyStagedConfigOperation(goodCorr), "accepted", "465-pair-hist: correct")
    assertEq(GS.PersonalContributorItemTotal(hist, "Alice-Garona", "Player-1-Alice", itemId), 5,
        "465-pair-hist: Alice +5 after correction")
    assertEq(GS.PersonalContributorItemTotal(hist, "Bob-Garona", "Player-1-Bob", itemId), 10,
        "465-pair-hist: Bob +10 after correction")
    local delHist = select(1, GS:NewSoftDeleteOperation("pair-d1"))
    assertEq(GS:ApplyStagedConfigOperation(delHist), "accepted", "465-pair-hist: delete D1")
    assertEq(GS.PersonalContributorItemTotal(hist, "Alice-Garona", "Player-1-Alice", itemId), -5,
        "465-pair-hist: Alice −5 authorized debt")
    assertEq(GS.PersonalContributorItemTotal(hist, "Bob-Garona", "Player-1-Bob", itemId), 10,
        "465-pair-hist: Bob keeps credit")
    local corrSnap = select(1, GS._SnapshotPublicOp(goodCorr))
    local delSnap = select(1, GS._SnapshotPublicOp(delHist))
    local peer = seedLiveCampaignWithItem(itemId, 100)
    injectProductionDonation(peer, {
        id = "pair-d1", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionDonation(peer, {
        id = "pair-d2", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(peer, {
        id = "pair-adj", itemId = itemId, quantity = -5,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    local function rebind(body, rec)
        local out = {}
        for k, v in pairs(body) do out[k] = v end
        out.guildKey = select(1, GS:GetCurrentContext()).guildKey
        out.datasetId = rec.datasetId
        out.campaignId = rec.currentCampaignId
        out.baseCampaignId = rec.currentCampaignId
        out.basePolicyRevision = rec.permission and rec.permission.revisionId
        out.baseTargetRevision = rec.datasetId
        return out
    end
    assertEq(select(1, GS:AdmitRemoteOperation(rebind(delSnap, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })), "accepted", "465-pair-hist: peer delete-first")
    assertEq(select(1, GS:AdmitRemoteOperation(rebind(corrSnap, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })), "accepted", "465-pair-hist: peer correction after delete")
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", itemId), -5,
        "465-pair-hist: peer Alice −5")
    assertEq(GS.PersonalContributorItemTotal(peer, "Bob-Garona", "Player-1-Bob", itemId), 10,
        "465-pair-hist: peer Bob +10")
    assertTrue(type(peer.creditCorrections) == "table"
        and type(peer.creditCorrections["pair-d2"]) == "table",
        "465-pair-hist: correction head active")
end

do
    -- #465 r4529162895: same-event correct Alice→Bob, balance Bob −10, then
    -- delete. Verified deletion attribution must follow retained accepted
    -- correction history (not active creditCorrections). Delete-first /
    -- correction-second public receipt must refresh deletion facts without a
    -- manual InvalidateEventDeletionProjection crutch.
    local itemId = 9260
    local record = seedLiveCampaignWithItem(itemId, 80)
    injectProductionDonation(record, {
        id = "same-don", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "same-don", "Bob-Garona", "Player-1-Bob"))
    assertTrue(corr ~= nil, "465-same: prepare correction")
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "465-same: correct Alice→Bob")
    local adj = select(1, GS:NewAdjustmentOperation(itemId, -10, "Bob-Garona"))
    assertTrue(adj ~= nil, "465-same: prepare Bob balancing adj")
    assertEq(GS:ApplyStagedConfigOperation(adj), "accepted", "465-same: balance Bob −10")
    local del = select(1, GS:NewSoftDeleteOperation("same-don"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-same: delete corrected event")
    assertTrue(GS.IsEventSoftDeleted(record, "same-don"), "465-same: deleted")
    assertTrue(not (type(record.creditCorrections) == "table"
        and type(record.creditCorrections["same-don"]) == "table"),
        "465-same: deleted correction inactive in projection")
    local entry = record.eventDeletions and record.eventDeletions["same-don"]
    assertTrue(type(entry) == "table" and entry.verified == true, "465-same: verified")
    assertEq(entry.attributed, "Bob-Garona", "465-same: verified Bob not Alice")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), -10,
        "465-same: Bob debt −10")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", itemId), 0,
        "465-same: Alice not charged")
    local delSnap = select(1, GS._SnapshotPublicOp(del))
    local corrSnap = select(1, GS._SnapshotPublicOp(corr))
    -- Ordinary Ensure rounds (no forced Invalidate) must keep Bob.
    for round = 1, 3 do
        if GS.EnsureEventDeletionProjection then
            GS.EnsureEventDeletionProjection(record, nil)
        end
        local e = record.eventDeletions and record.eventDeletions["same-don"]
        assertEq(e and e.attributed, "Bob-Garona",
            "465-same: ensure " .. tostring(round) .. " keeps Bob")
        assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), -10,
            "465-same: ensure " .. tostring(round) .. " Bob debt")
        assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", itemId), 0,
            "465-same: ensure " .. tostring(round) .. " Alice zero")
    end
    simulateRuntimeReload()
    settleRoster()
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(record, nil)
    end
    local reloaded = record.eventDeletions and record.eventDeletions["same-don"]
    assertEq(reloaded and reloaded.attributed, "Bob-Garona", "465-same: reload Bob attribution")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), -10,
        "465-same: reload Bob debt")
    assertTrue(record.operations.records[corr.id] ~= nil, "465-same: correction history retained")
    assertTrue(not (type(record.creditCorrections) == "table"
        and type(record.creditCorrections["same-don"]) == "table"),
        "465-same: correction stays inactive after reload")

    -- Fresh adoption of corr + adj + delete keeps Bob debt immediately.
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    local exportBodies = collectAllExportBodies()
    local sourceDataset = record.datasetId
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-same: begin adoption")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-same: transfer ready")
    local commitSt, commitErr = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while commitSt == "pending" and gAdopt < 128 do
        runOneDueTimer()
        commitSt, commitErr = GS:CommitDatasetAdoption()
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(commitSt, "accepted",
        "465-same: commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
    local adopted = GS:GetCurrentRecord()
    local aEntry = adopted.eventDeletions and adopted.eventDeletions["same-don"]
    assertEq(aEntry and aEntry.attributed, "Bob-Garona", "465-same: adopted Bob attribution")
    assertEq(GS.PersonalContributorItemTotal(adopted, "Bob-Garona", "Player-1-Bob", itemId), -10,
        "465-same: adopted Bob debt")
    assertEq(GS.PersonalContributorItemTotal(adopted, "Alice-Garona", "Player-1-Alice", itemId), 0,
        "465-same: adopted Alice zero")
    assertTrue(not (type(adopted.creditCorrections) == "table"
        and type(adopted.creditCorrections["same-don"]) == "table"),
        "465-same: adopted correction inactive")

    -- Reordered public receipt: warm deletion cache on delete-first (Alice),
    -- then admit the prior accepted correction. Production histGen wake must
    -- refresh verified Bob facts — no manual Invalidate.
    switchPlayer("Alice", "Player-1-Alice", 1)
    settleRoster()
    local peer = seedLiveCampaignWithItem(itemId, 80)
    injectProductionDonation(peer, {
        id = "same-don", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local function rebind(body, rec)
        local out = {}
        for k, v in pairs(body) do out[k] = v end
        out.guildKey = select(1, GS:GetCurrentContext()).guildKey
        out.datasetId = rec.datasetId
        out.campaignId = rec.currentCampaignId
        out.baseCampaignId = rec.currentCampaignId
        out.basePolicyRevision = rec.permission and rec.permission.revisionId
        out.baseTargetRevision = rec.datasetId
        return out
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(peer, nil)
    end
    assertEq(select(1, GS:AdmitRemoteOperation(rebind(delSnap, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })), "accepted", "465-same: peer delete-first")
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(peer, nil)
    end
    local warmEntry = peer.eventDeletions and peer.eventDeletions["same-don"]
    assertTrue(type(warmEntry) == "table" and warmEntry.verified == true,
        "465-same: warm delete facts present")
    assertEq(warmEntry.attributed, "Alice-Garona",
        "465-same: warm cache still original donor before correction")
    local stCorr, rCorr = GS:AdmitRemoteOperation(rebind(corrSnap, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })
    assertTrue(stCorr == "accepted" or stCorr == "duplicate",
        "465-same: peer correction after delete got " .. tostring(stCorr) .. "/" .. tostring(rCorr))
    -- Ordinary reads immediately after public correction admission.
    local peerEntry = peer.eventDeletions and peer.eventDeletions["same-don"]
    assertEq(peerEntry and peerEntry.attributed, "Bob-Garona",
        "465-same: reordered verified Bob without manual invalidate")
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", itemId), 0,
        "465-same: reordered Alice zero (no incorrect allowance)")
    assertTrue(not (type(peer.creditCorrections) == "table"
        and type(peer.creditCorrections["same-don"]) == "table"),
        "465-same: reordered correction inactive")
    -- Production balancing adj already asserted on source/adoption. Peer inject
    -- proves signed Bob debt under refreshed deletion facts (remote adj snaps
    -- after delete-first are not the subject of this histGen repair).
    injectProductionAdjustment(peer, {
        id = "same-peer-adj", itemId = itemId, quantity = -10,
        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
    })
    if GS.InvalidateCreditCorrectionProjection then
        GS.InvalidateCreditCorrectionProjection(peer)
    end
    assertEq(GS.PersonalContributorItemTotal(peer, "Bob-Garona", "Player-1-Bob", itemId), -10,
        "465-same: reordered Bob debt −10")
    assertEq(GS.PersonalContributorItemTotal(peer, "Alice-Garona", "Player-1-Alice", itemId), 0,
        "465-same: reordered Alice still zero")
    -- Real accepted-history mutation after caches are warm: LWW-losing older
    -- correction retained via stale_credit bumps histGen and must keep Bob.
    local loseCorr = {}
    for k, v in pairs(corrSnap) do
        loseCorr[k] = v
    end
    loseCorr.id = "same-corr-lose"
    loseCorr.timestamp = (tonumber(corrSnap.timestamp) or world.time) - 120
    if type(corrSnap.value) == "table" then
        local v = {}
        for vk, vv in pairs(corrSnap.value) do
            v[vk] = vv
        end
        loseCorr.value = v
    end
    local stLose, rLose = GS:AdmitRemoteOperation(rebind(loseCorr, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })
    assertTrue(stLose == "accepted" or stLose == "duplicate",
        "465-same: loser correction retained got " .. tostring(stLose) .. "/" .. tostring(rLose))
    assertTrue(peer.operations.records["same-corr-lose"] ~= nil,
        "465-same: loser body in accepted history")
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(peer, nil)
    end
    local afterLose = peer.eventDeletions and peer.eventDeletions["same-don"]
    assertEq(afterLose and afterLose.attributed, "Bob-Garona",
        "465-same: loser retention keeps Bob attribution")
    assertEq(GS.PersonalContributorItemTotal(peer, "Bob-Garona", "Player-1-Bob", itemId), -10,
        "465-same: loser retention keeps Bob debt")
    simulateRuntimeReload()
    settleRoster()
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(peer, nil)
    end
    assertEq(peer.eventDeletions and peer.eventDeletions["same-don"]
        and peer.eventDeletions["same-don"].attributed, "Bob-Garona",
        "465-same: peer reload Bob attribution")
    assertEq(GS.PersonalContributorItemTotal(peer, "Bob-Garona", "Player-1-Bob", itemId), -10,
        "465-same: peer reload Bob debt")
    assertTrue(GS.IsEventSoftDeleted(peer, "same-don"), "465-same: deletion final after reload")
end

do
    -- #465 obligation 1: accepted Unassigned correction clears soft-delete
    -- attribution (nil/nil) and must not fall back to the original contributor.
    local itemId = 9260
    local record = seedLiveCampaignWithItem(itemId, 80)
    injectProductionDonation(record, {
        id = "ua-base", itemId = itemId, quantity = 12,
        actor = "Carol-Garona", actorGuid = "Player-1-Carol",
    })
    local adjOp = select(1, GS:NewAdjustmentOperation(itemId, 4, "Bob-Garona"))
    assertTrue(adjOp ~= nil, "465-ua: prepare Bob adjustment")
    assertEq(GS:ApplyStagedConfigOperation(adjOp), "accepted", "465-ua: apply Bob adj")
    local adjId = adjOp.id
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 4,
        "465-ua: Bob credited before Unassigned")
    local corr = select(1, GS:NewContributorCorrectionOperation(adjId, nil, nil))
    assertTrue(corr ~= nil, "465-ua: prepare Bob→Unassigned")
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "465-ua: apply Unassigned")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 0,
        "465-ua: Bob cleared after Unassigned")
    local del = select(1, GS:NewSoftDeleteOperation(adjId))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-ua: delete Unassigned adj")
    local entry = record.eventDeletions and record.eventDeletions[adjId]
    assertTrue(type(entry) == "table" and entry.verified == true, "465-ua: verified delete")
    assertNil(entry.attributed, "465-ua: Unassigned name nil")
    assertNil(entry.attributedGuid, "465-ua: Unassigned guid nil")
    assertEq(entry.eventKind, "adjustment", "465-ua: adjustment kind")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 0,
        "465-ua: Bob not charged after delete")
    assertEq(GS.PersonalContributorItemTotal(record, "Carol-Garona", "Player-1-Carol", itemId), 12,
        "465-ua: Carol donation untouched")
    -- Rebuild must preserve Unassigned (not fall back to Bob).
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(record)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(record, nil)
    end
    entry = record.eventDeletions and record.eventDeletions[adjId]
    assertNil(entry and entry.attributed, "465-ua: rebuild keeps Unassigned name")
    assertNil(entry and entry.attributedGuid, "465-ua: rebuild keeps Unassigned guid")
    local durable = record.accounting._consumables.softDeleteVerifiedFacts
    assertTrue(type(durable) == "table" and type(durable[adjId]) == "table"
        and durable[adjId].verified == true, "465-ua: durable Unassigned fact")
    assertNil(durable[adjId].attributed, "465-ua: durable name nil")
    assertNil(durable[adjId].attributedGuid, "465-ua: durable guid nil")
    -- Retention: keep the credited adjustment evidence for transfer (cutover
    -- provenance). Verified Unassigned facts must still win over durable Bob
    -- fields after export/adoption/reload — no personal Bob debt.
    assertTrue(GS.FindLedgerEventById(record, adjId) ~= nil, "465-ua: adj evidence retained")
    -- Export / fresh adoption must retain Unassigned facts (no Bob debt).
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    local exportBodies = collectAllExportBodies()
    local sourceDataset = record.datasetId
    local corrId, delId = corr.id, del.id
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-ua: begin adoption")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-ua: transfer ready")
    local commitSt, commitErr = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while commitSt == "pending" and gAdopt < 128 do
        runOneDueTimer()
        commitSt, commitErr = GS:CommitDatasetAdoption()
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(commitSt, "accepted",
        "465-ua: commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
    local adopted = GS:GetCurrentRecord()
    assertTrue(type(adopted) == "table", "465-ua: adopted record")
    assertTrue(adopted.operations.records[corrId] ~= nil, "465-ua: correction history")
    assertTrue(adopted.operations.records[delId] ~= nil, "465-ua: delete history")
    local aDurable = adopted.accounting and adopted.accounting._consumables
        and adopted.accounting._consumables.softDeleteVerifiedFacts
    assertTrue(type(aDurable) == "table" and type(aDurable[adjId]) == "table"
        and aDurable[adjId].verified == true, "465-ua: adopted durable fact")
    assertNil(aDurable[adjId].attributed, "465-ua: adopted Unassigned name")
    assertNil(aDurable[adjId].attributedGuid, "465-ua: adopted Unassigned guid")
    local aEntry = adopted.eventDeletions and adopted.eventDeletions[adjId]
    assertNil(aEntry and aEntry.attributed, "465-ua: adopted projection Unassigned")
    assertEq(GS.PersonalContributorItemTotal(adopted, "Bob-Garona", "Player-1-Bob", itemId), 0,
        "465-ua: adopted Bob not charged")
    simulateRuntimeReload()
    settleRoster()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(adopted)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(adopted, nil)
    end
    assertNil((adopted.eventDeletions and adopted.eventDeletions[adjId] or {}).attributed,
        "465-ua: Unassigned after reload")
    assertEq(GS.PersonalContributorItemTotal(adopted, "Bob-Garona", "Player-1-Bob", itemId), 0,
        "465-ua: Bob zero after reload")
    -- Ordinary invalid-accounting safeguard still rejects unsafe Bob debt.
    -- Keep item non-negative so the personal floor is the rejecting control.
    local badAdj, _, badReason = GS:NewAdjustmentOperation(itemId, -5, "Bob-Garona")
    assertNil(badAdj, "465-ua: unsafe Bob −5 rejected")
    assertEq(badReason, "player_negative",
        "465-ua: player_negative got " .. tostring(badReason))
end

do
    -- #465 obligation 2: production donation→correction→balancing adjustment→
    -- delete, retention eviction with adjustment retained, export/fresh-adopt
    -- INCLUDING the adjustment, immediate signed-debt assert, reload, then
    -- public repair to zero. No post-commit debt injection.
    local itemId = 9261
    local record = seedLiveCampaignWithItem(itemId, 80)
    injectProductionDonation(record, {
        id = "xfer-don", itemId = itemId, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "xfer-don", "Bob-Garona", "Player-1-Bob"))
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "465-xfer: correct to Bob")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 10,
        "465-xfer: Bob credited before balance")
    -- Balancing adjustment through the public writer while donation still counts.
    local bal = select(1, GS:NewAdjustmentOperation(itemId, -10, "Bob-Garona"))
    assertTrue(bal ~= nil, "465-xfer: prepare balancing adjustment")
    assertEq(GS:ApplyStagedConfigOperation(bal), "accepted", "465-xfer: apply balance")
    local adjId = bal.id
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 0,
        "465-xfer: Bob zero after balance")
    local del = select(1, GS:NewSoftDeleteOperation("xfer-don"))
    assertEq(GS:ApplyStagedConfigOperation(del), "accepted", "465-xfer: delete donation")
    local forgedEntry = record.eventDeletions and record.eventDeletions["xfer-don"]
    assertTrue(type(forgedEntry) == "table" and forgedEntry.verified == true,
        "465-xfer: verified before eviction")
    assertEq(forgedEntry.quantity, 10, "465-xfer: qty from evidence")
    assertEq(forgedEntry.attributed, "Bob-Garona", "465-xfer: Bob attribution")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), -10,
        "465-xfer: Bob signed debt after delete")
    assertTrue(GS.FindLedgerEventById(record, adjId) ~= nil, "465-xfer: adj retained pre-evict")
    local durable = record.accounting._consumables.softDeleteVerifiedFacts
    assertTrue(type(durable) == "table" and type(durable["xfer-don"]) == "table"
        and durable["xfer-don"].verified == true, "465-xfer: durable map before eviction")
    assertEq(durable["xfer-don"].attributed, "Bob-Garona", "465-xfer: durable Bob")
    -- Retention/rollover eviction of the donation only; keep the balancing adj.
    do
        local live = record.accounting._consumableEvents
        local kept = {}
        for i = 1, #live do
            if live[i].id ~= "xfer-don" then
                kept[#kept + 1] = live[i]
            end
        end
        record.accounting._consumableEvents = kept
        if type(record.observations) == "table"
            and type(record.observations.directExports) == "table" then
            local de, nextDe = record.observations.directExports, {}
            for k, row in pairs(de) do
                local rid = type(row) == "table" and (row.id or row.txnId or row.eventId)
                if rid ~= "xfer-don" then nextDe[k] = row end
            end
            record.observations.directExports = nextDe
        end
        if GS._BumpAccountingMutation then GS._BumpAccountingMutation(record) end
    end
    assertNil(GS.FindLedgerEventById(record, "xfer-don"), "465-xfer: evidence evicted")
    assertTrue(GS.FindLedgerEventById(record, adjId) ~= nil, "465-xfer: adj survives eviction")
    if GS.InvalidateEventDeletionProjection then GS.InvalidateEventDeletionProjection(record) end
    if GS.InvalidateCreditCorrectionProjection then
        GS.InvalidateCreditCorrectionProjection(record)
    end
    if GS.EnsureEventDeletionProjection then GS.EnsureEventDeletionProjection(record, nil) end
    durable = record.accounting._consumables.softDeleteVerifiedFacts
    assertTrue(type(durable) == "table" and type(durable["xfer-don"]) == "table"
        and durable["xfer-don"].verified == true, "465-xfer: durable map after eviction")
    local facts, factCount = GS.CollectSoftDeleteVerifiedFacts(record)
    assertTrue(factCount >= 1 and type(facts["xfer-don"]) == "table",
        "465-xfer: collect exports verified fact")
    assertEq(facts["xfer-don"].attributed, "Bob-Garona", "465-xfer: collected Bob")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), -10,
        "465-xfer: debt after eviction with adj present")
    -- Export INCLUDING the retained balancing adjustment + verified facts.
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    local exportBodies = collectAllExportBodies()
    local descBody = nil
    local sawAdjOp = false
    for i = 1, #exportBodies do
        local body = exportBodies[i].body
        if body and body.kind == "dataset-desc" then
            descBody = body
        elseif body and body.kind == "gs-op" and body.id == adjId then
            sawAdjOp = true
        elseif body and body.id == adjId then
            sawAdjOp = true
        end
    end
    -- Also accept ledger-event export of the adjustment.
    if not sawAdjOp then
        for i = 1, #exportBodies do
            local body = exportBodies[i].body
            if type(body) == "table" and (body.id == adjId or body.opId == adjId
                or (body.event and (body.event.id == adjId or body.event.opId == adjId))) then
                sawAdjOp = true
                break
            end
        end
    end
    assertTrue(type(descBody) == "table", "465-xfer: descriptor present")
    assertTrue(tonumber(descBody.softDeleteVerifiedFactCount) or 0 >= 1,
        "465-xfer: descriptor advertises verified facts")
    assertTrue(sawAdjOp or (GS.FindLedgerEventById(record, adjId) ~= nil),
        "465-xfer: source still holds balancing adjustment for transfer")
    local sourceDataset = record.datasetId
    local corrId, delId = corr.id, del.id
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-xfer: begin adoption")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-xfer: transfer ready")
    local commitSt, commitErr = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while commitSt == "pending" and gAdopt < 128 do
        runOneDueTimer()
        commitSt, commitErr = GS:CommitDatasetAdoption()
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(commitSt, "accepted",
        "465-xfer: commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
    local adopted = GS:GetCurrentRecord()
    assertTrue(type(adopted) == "table", "465-xfer: adopted record present")
    assertNil(GS.FindLedgerEventById(adopted, "xfer-don"),
        "465-xfer: adopted has no donation evidence")
    assertTrue(GS.FindLedgerEventById(adopted, adjId) ~= nil,
        "465-xfer: adopted retained balancing adjustment")
    assertTrue(adopted.operations.records[corrId] ~= nil, "465-xfer: correction history")
    assertTrue(adopted.operations.records[delId] ~= nil, "465-xfer: delete history")
    assertTrue(adopted.operations.records[adjId] ~= nil, "465-xfer: adjustment op history")
    local aDurable = adopted.accounting and adopted.accounting._consumables
        and adopted.accounting._consumables.softDeleteVerifiedFacts
    assertTrue(type(aDurable) == "table" and type(aDurable["xfer-don"]) == "table"
        and aDurable["xfer-don"].verified == true, "465-xfer: facts installed on adopt")
    assertEq(aDurable and aDurable["xfer-don"] and aDurable["xfer-don"].attributed,
        "Bob-Garona", "465-xfer: adopted durable Bob")
    local aEntry = adopted.eventDeletions and adopted.eventDeletions["xfer-don"]
    assertTrue(type(aEntry) == "table" and aEntry.verified == true,
        "465-xfer: adopted projection verified")
    assertEq(aEntry and aEntry.attributed, "Bob-Garona", "465-xfer: adopted projection Bob")
    assertEq(aEntry and aEntry.quantity, 10, "465-xfer: adopted qty not forged")
    -- Immediate signed-debt assert — no post-commit adjustment injection.
    assertEq(GS.PersonalContributorItemTotal(adopted, "Bob-Garona", "Player-1-Bob", itemId), -10,
        "465-xfer: adopted readable debt")
    assertEq(GS.PersonalContributorItemTotal(adopted, "Alice-Garona", "Player-1-Alice", itemId), 0,
        "465-xfer: adopted Alice not charged")
    simulateRuntimeReload()
    settleRoster()
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(adopted)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(adopted, nil)
    end
    assertEq(GS.PersonalContributorItemTotal(adopted, "Bob-Garona", "Player-1-Bob", itemId), -10,
        "465-xfer: debt after reload")
    -- Invalid-debt control: Alice donation cannot be corrected onto Bob while it
    -- would leave Alice negative without an authorized deletion floor.
    injectProductionDonation(adopted, {
        id = "xfer-keep", itemId = itemId, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local badCorr, _, badReason = GS:NewContributorCorrectionOperation(
        "xfer-keep", "Bob-Garona", "Player-1-Bob")
    assertNil(badCorr, "465-xfer: unsafe correction rejected")
    assertEq(badReason, "player_negative",
        "465-xfer: player_negative got " .. tostring(badReason))
    -- Officer adjustment repair Bob back to zero via public API.
    local repair = select(1, GS:NewAdjustmentOperation(itemId, 10, "Bob-Garona"))
    assertTrue(repair ~= nil, "465-xfer: prepare repair")
    assertEq(GS:ApplyStagedConfigOperation(repair), "accepted", "465-xfer: apply repair")
    assertEq(GS.PersonalContributorItemTotal(adopted, "Bob-Garona", "Player-1-Bob", itemId), 0,
        "465-xfer: Bob repaired to zero")
    assertEq(GS.PersonalContributorItemTotal(adopted, "Alice-Garona", "Player-1-Alice", itemId), 5,
        "465-xfer: Alice keep donation remains")
end

do
    -- #465 obligation 3: paged soft-delete verified-fact transfer under the real
    -- wire budget, including incomplete and conflicting transfer controls.
    local function wireRawBytes(id, body)
        local fp = (GS.ContentFingerprint and GS.ContentFingerprint(body))
            or string.rep("f", GS.MAX_OPERATION_ID or 192)
        local raw = C_EncodingUtil.SerializeCBOR({
            id = id, versionFp = fp, body = body,
        })
        return type(raw) == "string" and #raw or 0
    end
    local function filterWireBudget(bodies)
        local out, dropped = {}, 0
        local budget = GS.MAX_WIRE_RECORD_BYTES or 2048
        for i = 1, #bodies do
            local id, body = bodies[i].id, bodies[i].body
            if wireRawBytes(id, body) <= budget then
                out[#out + 1] = bodies[i]
            else
                dropped = dropped + 1
            end
        end
        return out, dropped
    end

    local itemId = 9263
    local record = seedLiveCampaignWithItem(itemId, 400)
    local N = 48
    local donors = { "Alice-Garona", "Bob-Garona", "Carol-Garona" }
    local guids = {
        ["Alice-Garona"] = "Player-1-Alice",
        ["Bob-Garona"] = "Player-1-Bob",
        ["Carol-Garona"] = "Player-1-Carol",
    }
    for i = 1, N do
        local id = string.format("sdf-wire-don-%04d-xxxxxxxxxxxxxxxx", i)
        local actor = donors[((i - 1) % #donors) + 1]
        injectProductionDonation(record, {
            id = id, itemId = itemId, quantity = 1,
            actor = actor, actorGuid = guids[actor],
            timestamp = world.time + i,
        })
        local del = select(1, GS:NewSoftDeleteOperation(id))
        assertEq(GS:ApplyStagedConfigOperation(del), "accepted",
            "465-sdf-wire: delete " .. id)
    end
    local facts, factCount = GS.CollectSoftDeleteVerifiedFacts(record)
    assertTrue(factCount >= N, "465-sdf-wire: collected facts n=" .. tostring(factCount))

    local bloatedDesc = {
        kind = "dataset-desc",
        schemaVersion = GS.PROVIDER_SCHEMA,
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = record.datasetId,
        softDeleteVerifiedFacts = facts,
        softDeleteVerifiedFactCount = factCount,
        softDeleteVerifiedFactPageCount = 0,
        acceptedOpCount = 0, transferOpCount = 0, campaignCount = 0, archiveCount = 0,
        acceptedLedgerCount = 0, donationEvidenceCount = 0, valuationCount = 0,
        hasBankTab = true,
    }
    local bloatedBytes = wireRawBytes("gs:desc:" .. record.datasetId, bloatedDesc)
    assertTrue(bloatedBytes > (GS.MAX_WIRE_RECORD_BYTES or 2048),
        "465-sdf-wire: monolithic facts exceed wire budget bytes=" .. tostring(bloatedBytes))

    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(256)
    local exportBodies = collectAllExportBodies()
    local descBody, pages = nil, {}
    local overBudget = 0
    for i = 1, #exportBodies do
        local id, body = exportBodies[i].id, exportBodies[i].body
        local nbytes = wireRawBytes(id, body)
        if nbytes > (GS.MAX_WIRE_RECORD_BYTES or 2048) then
            overBudget = overBudget + 1
        end
        if body and body.kind == "dataset-desc" then
            descBody = body
        elseif body and body.kind == "gs-soft-delete-facts-page" then
            pages[#pages + 1] = { id = id, body = body, page = tonumber(body.page) or 0 }
        end
    end
    assertEq(overBudget, 0, "465-sdf-wire: no exported body exceeds wire budget")
    assertTrue(type(descBody) == "table", "465-sdf-wire: dataset-desc present")
    assertEq(tonumber(descBody.softDeleteVerifiedFactCount), factCount,
        "465-sdf-wire: desc advertises fact count")
    assertTrue((tonumber(descBody.softDeleteVerifiedFactPageCount) or 0) >= 1,
        "465-sdf-wire: desc uses pages pageCount="
            .. tostring(descBody.softDeleteVerifiedFactPageCount))
    local inlineN = 0
    for _ in pairs(descBody.softDeleteVerifiedFacts or {}) do inlineN = inlineN + 1 end
    assertEq(inlineN, 0, "465-sdf-wire: paged desc strips inline map")
    assertEq(#pages, tonumber(descBody.softDeleteVerifiedFactPageCount),
        "465-sdf-wire: page bodies match pageCount")

    local filtered, dropped = filterWireBudget(exportBodies)
    assertEq(dropped, 0, "465-sdf-wire: filter drops none got=" .. tostring(dropped))
    assertEq(#filtered, #exportBodies, "465-sdf-wire: filter preserves all bodies")

    -- Missing page → incomplete_transfer.
    do
        SpectrumFederationDB = {}
        switchPlayer("Carol", "Player-1-Carol", 2)
        settleRoster()
        GS._adoptionEpoch = 0
        GS._peerDatasets = {}
        GS._adoption = nil
        initGS()
        GS:CreateStagedRecord()
        GS:EnsureGossipProvider()
        local sourceDataset = record.datasetId
        GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
        assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
            "465-sdf-miss: begin")
        local skipPage = pages[1] and pages[1].page
        for i = 1, #filtered do
            local b = filtered[i]
            if not (b.body.kind == "gs-soft-delete-facts-page"
                and tonumber(b.body.page) == skipPage) then
                GS:BufferAdoptionRecord(b.id, b.body)
            end
        end
        local readyMiss = GS:GetPendingAdoption() and GS:GetPendingAdoption().ready
        assertTrue(not readyMiss, "465-sdf-miss: missing page blocks ready")
        local okMiss, reasonMiss = GS:IsAdoptionTransferComplete()
        assertTrue(not okMiss, "465-sdf-miss: incomplete")
        assertEq(reasonMiss, "incomplete_transfer",
            "465-sdf-miss: reason got " .. tostring(reasonMiss))
        GS:CancelDatasetAdoption()
    end

    -- Conflicting fact page → source_changed.
    do
        SpectrumFederationDB = {}
        switchPlayer("Carol", "Player-1-Carol", 2)
        settleRoster()
        GS._adoptionEpoch = 0
        GS._peerDatasets = {}
        GS._adoption = nil
        initGS()
        GS:CreateStagedRecord()
        GS:EnsureGossipProvider()
        local sourceDataset = record.datasetId
        GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
        assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
            "465-sdf-confl: begin")
        for i = 1, #pages do
            if pages[i].page == 1 then
                local victim, victimEntry = nil, nil
                for eventId, entry in pairs(pages[i].body.facts or {}) do
                    victim, victimEntry = eventId, entry
                    break
                end
                assertTrue(victim ~= nil, "465-sdf-confl: victim fact")
                local badFacts = {}
                for eventId, entry in pairs(pages[i].body.facts or {}) do
                    badFacts[eventId] = entry
                end
                badFacts[victim] = {
                    verified = true,
                    eventId = victim,
                    eventKind = victimEntry.eventKind,
                    itemId = victimEntry.itemId,
                    quantity = (tonumber(victimEntry.quantity) or 1) + 7,
                    campaignId = victimEntry.campaignId,
                    attributed = "Conflict-Garona",
                    attributedGuid = "Player-1-Conflict",
                    gsProductionCredit = true,
                }
                local badPage = {
                    kind = "gs-soft-delete-facts-page",
                    datasetId = sourceDataset,
                    page = 1,
                    pageCount = tonumber(descBody.softDeleteVerifiedFactPageCount),
                    facts = badFacts,
                }
                local stGood = select(1, GS:BufferAdoptionRecord(pages[i].id, pages[i].body))
                assertTrue(stGood == "accepted" or stGood == "duplicate",
                    "465-sdf-confl: good page accepted")
                local stBad, rBad = GS:BufferAdoptionRecord(pages[i].id, badPage)
                assertEq(stBad, "rejected",
                    "465-sdf-confl: conflicting page rejected got "
                        .. tostring(stBad) .. "/" .. tostring(rBad))
                assertEq(rBad, "source_changed",
                    "465-sdf-confl: source_changed got " .. tostring(rBad))
                assertTrue(GS:GetPendingAdoption() == nil,
                    "465-sdf-confl: adoption aborted after changed page")
                break
            end
        end
        if GS:GetPendingAdoption() then
            GS:CancelDatasetAdoption()
        end
    end

    -- Full fresh adoption through filtered transport.
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    local sourceDataset = record.datasetId
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-sdf-adopt: begin")
    for i = 1, #filtered do
        GS:BufferAdoptionRecord(filtered[i].id, filtered[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-sdf-adopt: transfer ready")
    local commitSt, commitErr = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while commitSt == "pending" and gAdopt < 128 do
        runOneDueTimer()
        commitSt, commitErr = GS:CommitDatasetAdoption()
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(commitSt, "accepted",
        "465-sdf-adopt: commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
    local adopted = GS:GetCurrentRecord()
    assertTrue(type(adopted) == "table", "465-sdf-adopt: adopted record")
    local aDurable = adopted.accounting and adopted.accounting._consumables
        and adopted.accounting._consumables.softDeleteVerifiedFacts
    local installed = 0
    if type(aDurable) == "table" then
        for _ in pairs(aDurable) do installed = installed + 1 end
    end
    assertTrue(installed >= N,
        "465-sdf-adopt: installed facts n=" .. tostring(installed))
end

do
    -- #465 assessment 6775258160: +10 adjustment / −10 balancing / delete +10
    -- must create signed item (and personal, when attributed) debt floors so
    -- delete-first remote receipt and fresh adoption can replay the survivor.
    local function rebind(body, rec)
        local out = {}
        for k, v in pairs(body) do out[k] = v end
        out.guildKey = select(1, GS:GetCurrentContext()).guildKey
        out.datasetId = rec.datasetId
        out.campaignId = rec.currentCampaignId
        out.baseCampaignId = rec.currentCampaignId
        out.basePolicyRevision = rec.permission and rec.permission.revisionId
        out.baseTargetRevision = rec.datasetId
        return out
    end

    -- After delete-first remote admit of the balancing adj succeeds (proves the
    -- soft-delete debt floor), mark production credit the same way credited
    -- ledger-export rows do so signed totals are observable. Remote gs-op-only
    -- admit does not mint localProductionAuthority cutover credit.
    local function markPeerAdjustmentCredited(rec, eventId)
        local ev = GS.FindLedgerEventById(rec, eventId)
        assertTrue(type(ev) == "table", "465-adjfloor: peer adj present " .. tostring(eventId))
        ev.gsProductionCredit = true
        if GS._BumpAccountingMutation then
            GS._BumpAccountingMutation(rec)
        end
        if GS.InvalidateCreditCorrectionProjection then
            GS.InvalidateCreditCorrectionProjection(rec)
        end
        return ev
    end

    -- Attributed path (full suite with export collected on source first).
    do
        local label, itemId = "465-adjfloor", 9264
        local attributed, attributedGuid = "Bob-Garona", "Player-1-Bob"
        local record = seedLiveCampaignWithItem(itemId, 120)
        local pos = select(1, GS:NewAdjustmentOperation(itemId, 10, attributed))
        assertTrue(pos ~= nil, label .. ": prepare +10")
        assertEq(GS:ApplyStagedConfigOperation(pos), "accepted", label .. ": apply +10")
        local posId = pos.id
        local neg = select(1, GS:NewAdjustmentOperation(itemId, -10, attributed))
        assertTrue(neg ~= nil, label .. ": prepare −10")
        assertEq(GS:ApplyStagedConfigOperation(neg), "accepted", label .. ": apply −10")
        local negId = neg.id
        assertEq(GS.PersonalContributorItemTotal(record, attributed, attributedGuid, itemId), 0,
            label .. ": personal zero before delete")
        local del = select(1, GS:NewSoftDeleteOperation(posId))
        assertEq(GS:ApplyStagedConfigOperation(del), "accepted", label .. ": delete +10")
        assertEq(GS.PersonalContributorItemTotal(record, attributed, attributedGuid, itemId), -10,
            label .. ": personal debt after delete")
        local progress = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
        assertEq(tonumber(progress.itemTotals[itemId]) or 0, -10, label .. ": item −10")
        local delSnap = select(1, GS._SnapshotPublicOp(del))
        local negSnap = select(1, GS._SnapshotPublicOp(neg))

        GS:EnsureGossipProvider()
        GS.NotifyLocalDurableChange("dataset")
        drainExportMaint(128)
        local exportBodies = collectAllExportBodies()
        local sourceDataset = record.datasetId

        -- Delete-first remote: peer already holds credited +10 evidence (same id),
        -- receives delete, then must replay −10 against verified soft-delete floors.
        local peer = seedLiveCampaignWithItem(itemId, 120)
        injectProductionAdjustment(peer, {
            id = posId, itemId = itemId, quantity = 10,
            attributed = attributed, attributedGuid = attributedGuid,
        })
        assertEq(select(1, GS:AdmitRemoteOperation(rebind(delSnap, peer), {
            sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
        })), "accepted", label .. ": peer delete-first")
        local stNeg, rNeg = GS:AdmitRemoteOperation(rebind(negSnap, peer), {
            sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
        })
        assertEq(stNeg, "accepted",
            label .. ": peer −10 after delete-first got " .. tostring(stNeg) .. "/" .. tostring(rNeg))
        markPeerAdjustmentCredited(peer, negId)
        assertEq(GS.PersonalContributorItemTotal(peer, attributed, attributedGuid, itemId), -10,
            label .. ": peer personal debt")

        SpectrumFederationDB = {}
        switchPlayer("Carol", "Player-1-Carol", 2)
        settleRoster()
        GS._adoptionEpoch = 0
        GS._peerDatasets = {}
        GS._pendingRelay = {}
        GS._adoption = nil
        initGS()
        GS:CreateStagedRecord()
        GS:EnsureGossipProvider()
        GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
        assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
            label .. ": begin adoption")
        for i = 1, #exportBodies do
            GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
        end
        assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
            label .. ": transfer ready")
        local commitSt, commitErr = GS:CommitDatasetAdoption()
        local gAdopt = 0
        while commitSt == "pending" and gAdopt < 128 do
            runOneDueTimer()
            commitSt, commitErr = GS:CommitDatasetAdoption()
            gAdopt = gAdopt + 1
        end
        flushTimers()
        assertEq(commitSt, "accepted",
            label .. ": commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
        local adopted = GS:GetCurrentRecord()
        assertTrue(GS.FindLedgerEventById(adopted, negId) ~= nil, label .. ": survivor retained")
        assertEq(GS.PersonalContributorItemTotal(adopted, attributed, attributedGuid, itemId), -10,
            label .. ": adopted immediate debt")
        simulateRuntimeReload()
        settleRoster()
        assertEq(GS.PersonalContributorItemTotal(adopted, attributed, attributedGuid, itemId), -10,
            label .. ": debt after reload")
        local repair = select(1, GS:NewAdjustmentOperation(itemId, 10, attributed))
        assertTrue(repair ~= nil, label .. ": prepare repair")
        assertEq(GS:ApplyStagedConfigOperation(repair), "accepted", label .. ": apply repair")
        assertEq(GS.PersonalContributorItemTotal(adopted, attributed, attributedGuid, itemId), 0,
            label .. ": repaired to zero")
    end

    -- Unassigned +10 / −10 / delete +10 (item debt only; no personal allowance).
    do
        local label, itemId = "465-adjfloor-ua", 9265
        local record = seedLiveCampaignWithItem(itemId, 120)
        injectProductionDonation(record, {
            id = "adjfloor-ua-stock", itemId = itemId, quantity = 20,
            actor = "Carol-Garona", actorGuid = "Player-1-Carol",
        })
        local pos = select(1, GS:NewAdjustmentOperation(itemId, 10, nil))
        assertTrue(pos ~= nil, label .. ": prepare Unassigned +10")
        assertEq(GS:ApplyStagedConfigOperation(pos), "accepted", label .. ": apply +10")
        local posId = pos.id
        local neg = select(1, GS:NewAdjustmentOperation(itemId, -10, nil))
        assertTrue(neg ~= nil, label .. ": prepare Unassigned −10")
        assertEq(GS:ApplyStagedConfigOperation(neg), "accepted", label .. ": apply −10")
        local negId = neg.id
        local del = select(1, GS:NewSoftDeleteOperation(posId))
        assertEq(GS:ApplyStagedConfigOperation(del), "accepted", label .. ": delete +10")
        local entry = record.eventDeletions and record.eventDeletions[posId]
        assertNil(entry and entry.attributed, label .. ": Unassigned fact")
        assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 0,
            label .. ": Bob not charged")
        local progress = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
        -- Carol stock 20 + deleted Unassigned +10 + surviving Unassigned −10 → 10.
        assertEq(tonumber(progress.itemTotals[itemId]) or 0, 10, label .. ": item after delete")
        local delSnap = select(1, GS._SnapshotPublicOp(del))
        local negSnap = select(1, GS._SnapshotPublicOp(neg))

        GS:EnsureGossipProvider()
        GS.NotifyLocalDurableChange("dataset")
        drainExportMaint(128)
        local exportBodies = collectAllExportBodies()
        local sourceDataset = record.datasetId

        local peer = seedLiveCampaignWithItem(itemId, 120)
        injectProductionDonation(peer, {
            id = "adjfloor-ua-stock", itemId = itemId, quantity = 20,
            actor = "Carol-Garona", actorGuid = "Player-1-Carol",
        })
        injectProductionAdjustment(peer, {
            id = posId, itemId = itemId, quantity = 10,
            attributed = nil, attributedGuid = nil,
        })
        assertEq(select(1, GS:AdmitRemoteOperation(rebind(delSnap, peer), {
            sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
        })), "accepted", label .. ": peer delete-first")
        local stNeg, rNeg = GS:AdmitRemoteOperation(rebind(negSnap, peer), {
            sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
        })
        assertEq(stNeg, "accepted",
            label .. ": peer −10 after delete-first got " .. tostring(stNeg) .. "/" .. tostring(rNeg))
        markPeerAdjustmentCredited(peer, negId)
        local peerProgress = GS.ProjectCampaignProgressOnRecord(peer, peer.currentCampaignId)
        assertEq(tonumber(peerProgress.itemTotals[itemId]) or 0, 10, label .. ": peer item")

        SpectrumFederationDB = {}
        switchPlayer("Carol", "Player-1-Carol", 2)
        settleRoster()
        GS._adoptionEpoch = 0
        GS._peerDatasets = {}
        GS._pendingRelay = {}
        GS._adoption = nil
        initGS()
        GS:CreateStagedRecord()
        GS:EnsureGossipProvider()
        GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
        assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
            label .. ": begin adoption")
        for i = 1, #exportBodies do
            GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
        end
        assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
            label .. ": transfer ready")
        local commitSt, commitErr = GS:CommitDatasetAdoption()
        local gAdopt = 0
        while commitSt == "pending" and gAdopt < 128 do
            runOneDueTimer()
            commitSt, commitErr = GS:CommitDatasetAdoption()
            gAdopt = gAdopt + 1
        end
        flushTimers()
        assertEq(commitSt, "accepted",
            label .. ": commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
        local adopted = GS:GetCurrentRecord()
        assertTrue(GS.FindLedgerEventById(adopted, negId) ~= nil, label .. ": survivor retained")
        local aProgress = GS.ProjectCampaignProgressOnRecord(adopted, adopted.currentCampaignId)
        assertEq(tonumber(aProgress.itemTotals[itemId]) or 0, 10, label .. ": adopted item")
        assertEq(GS.PersonalContributorItemTotal(adopted, "Bob-Garona", "Player-1-Bob", itemId), 0,
            label .. ": adopted Bob zero")
        simulateRuntimeReload()
        settleRoster()
        assertEq(tonumber(GS.ProjectCampaignProgressOnRecord(adopted, adopted.currentCampaignId)
            .itemTotals[itemId]) or 0, 10, label .. ": item after reload")
        -- Explicit repair of Unassigned item debt from the surviving −10: +10 Unassigned.
        local repair = select(1, GS:NewAdjustmentOperation(itemId, 10, nil))
        assertTrue(repair ~= nil, label .. ": prepare Unassigned repair")
        assertEq(GS:ApplyStagedConfigOperation(repair), "accepted", label .. ": apply repair")
        assertEq(tonumber(GS.ProjectCampaignProgressOnRecord(adopted, adopted.currentCampaignId)
            .itemTotals[itemId]) or 0, 20, label .. ": item repaired to stock")
    end

    -- Deleting a negative adjustment must not manufacture a negative allowance.
    -- Unrelated same-item credit keeps the item positive so only personal fails.
    do
        local label, itemId = "465-negdel", 9266
        local record = seedLiveCampaignWithItem(itemId, 120)
        injectProductionDonation(record, {
            id = "negdel-alice", itemId = itemId, quantity = 20,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        })
        local pos = select(1, GS:NewAdjustmentOperation(itemId, 10, "Bob-Garona"))
        assertEq(GS:ApplyStagedConfigOperation(pos), "accepted", label .. ": Bob +10")
        local neg = select(1, GS:NewAdjustmentOperation(itemId, -5, "Bob-Garona"))
        assertEq(GS:ApplyStagedConfigOperation(neg), "accepted", label .. ": Bob −5")
        local negId = neg.id
        assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 5,
            label .. ": Bob 5 before delete")
        local del = select(1, GS:NewSoftDeleteOperation(negId))
        assertEq(GS:ApplyStagedConfigOperation(del), "accepted", label .. ": delete −5")
        assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", itemId), 10,
            label .. ": Bob restored to 10")
        local progress = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
        assertTrue((tonumber(progress.itemTotals[itemId]) or 0) > 0, label .. ": item stays positive")
        -- Soft-delete debt floors must not allow Bob below zero via abs(−5).
        local okFloor, floorErr = GS.AdjustmentFloorOk(
            record, itemId, -11, "Bob-Garona", nil, {
                respectSoftDeleteDebt = true,
                attributedGuid = "Player-1-Bob",
            })
        assertTrue(okFloor == false, label .. ": Bob −11 rejected")
        assertEq(floorErr, "player_negative",
            label .. ": player_negative got " .. tostring(floorErr))
        -- Local public writer agrees.
        local bad, _, badReason = GS:NewAdjustmentOperation(itemId, -11, "Bob-Garona")
        assertNil(bad, label .. ": public −11 rejected")
        assertEq(badReason, "player_negative",
            label .. ": public player_negative got " .. tostring(badReason))
    end
end

do
    -- #465 obligation 3b: many retained deletes + orphaned targets share one
    -- bounded event-object index; FindLedgerEventById must not run per head.
    local itemId = 9262
    local record = seedLiveCampaignWithItem(itemId, 200)
    local deleteN = 48
    for i = 1, deleteN do
        local id = string.format("scan-don-%02d", i)
        injectProductionDonation(record, {
            id = id, itemId = itemId, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        })
        local del = select(1, GS:NewSoftDeleteOperation(id))
        assertEq(GS:ApplyStagedConfigOperation(del), "accepted",
            "465-scan: delete " .. id)
    end
    -- Orphaned targets: keep delete heads but evict evidence.
    local live = record.accounting._consumableEvents
    local kept = {}
    for i = 1, #live do
        local id = live[i].id
        if type(id) ~= "string" or not id:match("^scan%-don%-") then
            kept[#kept + 1] = live[i]
        end
    end
    record.accounting._consumableEvents = kept
    if GS._BumpAccountingMutation then
        GS._BumpAccountingMutation(record)
    end
    -- Inflate archive so a naive FindLedger per head would be expensive.
    local archive = record.accounting._consumableEventArchive
    if type(archive) ~= "table" then
        archive = {}
        record.accounting._consumableEventArchive = archive
    end
    for i = 1, 120 do
        archive[#archive + 1] = {
            id = string.format("scan-noise-%03d", i),
            kind = "donation",
            itemId = itemId,
            quantity = 1,
            actor = "Noise",
            actorGuid = "Player-1-Noise",
            campaignId = record.currentCampaignId,
        }
    end
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(record)
    end
    local findCalls = 0
    local realFind = GS.FindLedgerEventById
    GS.FindLedgerEventById = function(...)
        findCalls = findCalls + 1
        return realFind(...)
    end
    GS._softDeleteEventIndexVisits = nil
    GS._softDeleteRebuildFindLedgerCalls = nil
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(record, nil)
    end
    local visits1 = tonumber(GS._softDeleteEventIndexVisits) or 0
    local findDuring = findCalls
    GS.FindLedgerEventById = realFind
    assertEq(findDuring, 0,
        "465-scan: no FindLedger during rebuild got " .. tostring(findDuring))
    assertEq(tonumber(GS._softDeleteRebuildFindLedgerCalls) or 0, 0,
        "465-scan: rebuild FindLedger counter zero")
    assertTrue(visits1 > 0, "465-scan: event-object index visited ledger once")
    -- Projection Invalidate keeps warm ledger indexes; second Ensure must reuse
    -- them (0 new ledger visits) while still avoiding FindLedger (#465 r4529162895).
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(record)
    end
    findCalls = 0
    GS.FindLedgerEventById = function(...)
        findCalls = findCalls + 1
        return realFind(...)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(record, nil)
    end
    local visits2 = tonumber(GS._softDeleteEventIndexVisits) or 0
    local findDuring2 = findCalls
    GS.FindLedgerEventById = realFind
    assertEq(findDuring2, 0, "465-scan: second rebuild still no FindLedger")
    assertEq(visits2, 0, "465-scan: warm index reuse after projection invalidate")
    assertEq(GS._softDeleteIndexReuse, true, "465-scan: reuse flag set")
    -- Explicit ledger-index invalidation + dependency change forces a cold rebuild.
    if GS.InvalidateSoftDeleteLedgerIndexes then
        GS.InvalidateSoftDeleteLedgerIndexes(record)
    end
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(record)
    end
    if GS.EnsureEventDeletionProjection then
        GS.EnsureEventDeletionProjection(record, nil)
    end
    local visits3 = tonumber(GS._softDeleteEventIndexVisits) or 0
    assertEq(visits3, visits1, "465-scan: cold rebuild after index invalidate")
    local deleted = 0
    for i = 1, deleteN do
        local id = string.format("scan-don-%02d", i)
        if GS.IsEventSoftDeleted(record, id) then
            deleted = deleted + 1
        end
    end
    assertEq(deleted, deleteN, "465-scan: all deletes projected")
    -- Work stays shared-linear: visits << deleteN * archiveLen.
    local archiveLen = #archive
    assertTrue(visits1 < deleteN * archiveLen,
        "465-scan: visits bounded below per-head archive scans ("
            .. tostring(visits1) .. " < " .. tostring(deleteN * archiveLen) .. ")")
end

do
    -- #465 r4529162866: valid source with >2048 verified facts must export and
    -- fresh-adopt without hitting the old 2048 install ceiling. Mix long IDs so
    -- wrapper-inclusive paging still stays under the wire budget.
    local itemId = 9270
    local record = seedLiveCampaignWithItem(itemId, 2500)
    local N = 2100
    local longPad = string.rep("x", 96)
    local maxFact = GS.MAX_SOFT_DELETE_VERIFIED_FACTS or 4096
    assertTrue(maxFact >= N, "465-cap: fact ceiling covers N=" .. tostring(N))
    assertTrue((GS.MAX_SOFT_DELETE_FACT_PAGE_COUNT or 0) >= N,
        "465-cap: page ceiling covers worst-case one-fact pages")
    for i = 1, N do
        local id
        if i % 17 == 0 then
            id = string.format("cap-long-%04d-%s", i, longPad)
        else
            id = string.format("cap-%04d", i)
        end
        assertTrue(#id <= (GS.MAX_TXN_ID or 160),
            "465-cap: supported id length " .. tostring(#id))
        injectProductionDonation(record, {
            id = id, itemId = itemId, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
        local del = select(1, GS:NewSoftDeleteOperation(id))
        assertTrue(del ~= nil, "465-cap: prepare delete " .. id)
        assertEq(GS:ApplyStagedConfigOperation(del), "accepted",
            "465-cap: delete " .. id)
    end
    local facts, factCount = GS.CollectSoftDeleteVerifiedFacts(record)
    assertTrue(factCount >= N,
        "465-cap: collected facts n=" .. tostring(factCount))
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(512)
    local exportBodies = collectAllExportBodies()
    local function wireRawBytes(id, body)
        local fp = (GS.ContentFingerprint and GS.ContentFingerprint(body))
            or string.rep("f", GS.MAX_OPERATION_ID or 192)
        local raw = C_EncodingUtil.SerializeCBOR({
            id = id, versionFp = fp, body = body,
        })
        return type(raw) == "string" and #raw or 0
    end
    local descBody, pageN, overBudget = nil, 0, 0
    for i = 1, #exportBodies do
        local id, body = exportBodies[i].id, exportBodies[i].body
        if wireRawBytes(id, body) > (GS.MAX_WIRE_RECORD_BYTES or 2048) then
            overBudget = overBudget + 1
        end
        if body and body.kind == "dataset-desc" then
            descBody = body
        elseif body and body.kind == "gs-soft-delete-facts-page" then
            pageN = pageN + 1
        end
    end
    assertEq(overBudget, 0, "465-cap: no body over wire budget")
    assertTrue(type(descBody) == "table", "465-cap: descriptor present")
    assertEq(tonumber(descBody.softDeleteVerifiedFactCount), factCount,
        "465-cap: desc fact count")
    assertTrue((tonumber(descBody.softDeleteVerifiedFactPageCount) or 0) >= 1
        or factCount < 1,
        "465-cap: paging or inline under budget")
    if (tonumber(descBody.softDeleteVerifiedFactPageCount) or 0) >= 1 then
        assertEq(pageN, tonumber(descBody.softDeleteVerifiedFactPageCount),
            "465-cap: page bodies match pageCount")
    end
    local sourceDataset = record.datasetId
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-cap: begin adoption")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-cap: transfer ready")
    local commitSt, commitErr = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while commitSt == "pending" and gAdopt < 512 do
        runOneDueTimer()
        commitSt, commitErr = GS:CommitDatasetAdoption()
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(commitSt, "accepted",
        "465-cap: commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
    local adopted = GS:GetCurrentRecord()
    local aDurable = adopted and adopted.accounting and adopted.accounting._consumables
        and adopted.accounting._consumables.softDeleteVerifiedFacts
    local installed = 0
    if type(aDurable) == "table" then
        for _ in pairs(aDurable) do installed = installed + 1 end
    end
    assertTrue(installed >= N,
        "465-cap: adopted facts n=" .. tostring(installed))
end

do
    -- #465 r4529162877: unbound fact must reach the binding check with a
    -- consistent op-count manifest (no extra gs-op that fails earlier counts).
    local itemId = 9271
    local record = seedLiveCampaignWithItem(itemId, 80)
    injectProductionDonation(record, {
        id = "bind-stock", itemId = itemId, quantity = 20,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionDonation(record, {
        id = "bind-ok-don", itemId = itemId, quantity = 5,
        actor = "Bob-Garona", actorGuid = "Player-1-Bob",
    })
    local okDel = select(1, GS:NewSoftDeleteOperation("bind-ok-don"))
    assertEq(GS:ApplyStagedConfigOperation(okDel), "accepted", "465-bind: ok delete")
    -- Source-legal negative adj included in the export so the transfer still
    -- carries an adjustment without inventing an extra op at buffer time.
    local negAdj = select(1, GS:NewAdjustmentOperation(itemId, -3, "Alice-Garona"))
    assertTrue(negAdj ~= nil, "465-bind: prepare source-legal negative adj")
    assertEq(GS:ApplyStagedConfigOperation(negAdj), "accepted", "465-bind: apply source adj")
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    local exportBodies = collectAllExportBodies()
    local sourceDataset = record.datasetId
    local forgedFact = {
        verified = true,
        eventId = "bind-stock",
        eventKind = "donation",
        itemId = itemId,
        quantity = 20,
        campaignId = record.currentCampaignId,
        attributed = "Alice-Garona",
        attributedGuid = "Player-1-Alice",
        gsProductionCredit = true,
    }
    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-bind: begin")
    local descPatched = false
    for i = 1, #exportBodies do
        local id, body = exportBodies[i].id, exportBodies[i].body
        if body and body.kind == "dataset-desc" then
            local patched = {}
            for k, v in pairs(body) do patched[k] = v end
            local facts = {}
            for k, v in pairs(body.softDeleteVerifiedFacts or {}) do
                facts[k] = v
            end
            facts["bind-stock"] = forgedFact
            patched.softDeleteVerifiedFacts = facts
            patched.softDeleteVerifiedFactCount =
                (tonumber(body.softDeleteVerifiedFactCount) or 0) + 1
            -- Keep acceptedOpCount / other pins unchanged; only forge the fact.
            patched.softDeleteVerifiedFactPageCount = 0
            GS:BufferAdoptionRecord(id, patched)
            descPatched = true
        elseif body and body.kind == "gs-soft-delete-facts-page" then
            -- Drop pages so inline forged map is authoritative.
        else
            GS:BufferAdoptionRecord(id, body)
        end
    end
    assertTrue(descPatched, "465-bind: descriptor patched")
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-bind: transfer ready with consistent counts")
    local commitSt, commitErr = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while commitSt == "pending" and gAdopt < 128 do
        runOneDueTimer()
        commitSt, commitErr = GS:CommitDatasetAdoption()
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(commitSt, "rejected",
        "465-bind: forged fact rejected st=" .. tostring(commitSt))
    assertEq(commitErr, "soft_delete_fact_unbound",
        "465-bind: binding-specific reason got " .. tostring(commitErr))
    SpectrumFederationDB = {}
    switchPlayer("Alice", "Player-1-Alice", 1)
    settleRoster()
    initGS()
    local localRec = seedLiveCampaignWithItem(itemId, 80)
    injectProductionDonation(localRec, {
        id = "bind-local-stock", itemId = itemId, quantity = 20,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local badAdj, _, badReason = GS:NewAdjustmentOperation(itemId, -21, "Alice-Garona")
    if badAdj then
        local st = GS:ApplyStagedConfigOperation(badAdj)
        assertTrue(st ~= "accepted",
            "465-bind: local apply rejects unbound debt st=" .. tostring(st))
    else
        assertTrue(badReason == "item_negative" or badReason == "player_negative",
            "465-bind: local prepare rejects got " .. tostring(badReason))
    end
end

do
    -- #465 r4529162884 + r4529162895: REAL multi-delete + mixed-adjustment
    -- adoption replay with large retained history. Measure cumulative callback
    -- work across scheduled Commit timer yields (sync drain disabled;
    -- runOneDueTimer so chained After(0) are not coalesced into one flush).
    local itemId = 9272
    local record = seedLiveCampaignWithItem(itemId, 400)
    local noiseN, deleteN, adjN = 160, 40, 20
    for i = 1, noiseN do
        injectProductionDonation(record, {
            id = string.format("rw-noise-%03d", i), itemId = itemId, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
    end
    local deleteIds = {}
    for i = 1, deleteN do
        local id = string.format("rw-del-%02d", i)
        deleteIds[i] = id
        injectProductionDonation(record, {
            id = id, itemId = itemId, quantity = 2,
            actor = "Bob-Garona", actorGuid = "Player-1-Bob",
            timestamp = world.time + 1000 + i,
        })
        local del = select(1, GS:NewSoftDeleteOperation(id))
        assertEq(GS:ApplyStagedConfigOperation(del), "accepted",
            "465-rw: source delete " .. id)
    end
    injectProductionDonation(record, {
        id = "rw-stock", itemId = itemId, quantity = 120,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    for i = 1, adjN do
        local adj = select(1, GS:NewAdjustmentOperation(itemId, -1, "Alice-Garona"))
        assertTrue(adj ~= nil, "465-rw: source adj " .. tostring(i))
        assertEq(GS:ApplyStagedConfigOperation(adj), "accepted",
            "465-rw: source apply adj " .. tostring(i))
    end
    -- Warm-ledger bounds (source side): retain targets first, one cold scan of
    -- the full ledger, then a delete wave that must stay incremental.
    local warmExtra = 24
    local warmIds = {}
    for i = 1, warmExtra do
        local id = string.format("rw-warm-%02d", i)
        warmIds[i] = id
        deleteIds[#deleteIds + 1] = id
        injectProductionDonation(record, {
            id = id, itemId = itemId, quantity = 1,
            actor = "Bob-Garona", actorGuid = "Player-1-Bob",
            timestamp = world.time + 2000 + i,
        })
    end
    deleteN = deleteN + warmExtra
    GS.InvalidateSoftDeleteLedgerIndexes(record)
    GS._softDeleteCumulativeEventVisits = 0
    GS._softDeleteCumulativeHistVisits = 0
    GS._softDeleteCumulativeHeadVisits = 0
    GS._softDeleteColdLedgerBuilds = 0
    GS._softDeleteIncrementalApplies = 0
    assertTrue(GS.EnsureEventDeletionProjection(record, nil),
        "465-rw: warm ensure rebuild")
    local warmCold = tonumber(GS._softDeleteColdLedgerBuilds) or 0
    local warmScan = tonumber(GS._softDeleteCumulativeEventVisits) or 0
    assertTrue(warmCold >= 1, "465-rw: warm cold build observed")
    assertTrue(warmScan >= noiseN + deleteN - warmExtra,
        "465-rw: warm cold scans retained ledger got " .. tostring(warmScan))
    local warmHeadsBefore = tonumber(GS._softDeleteCumulativeHeadVisits) or 0
    for i = 1, warmExtra do
        local del = select(1, GS:NewSoftDeleteOperation(warmIds[i]))
        assertEq(GS:ApplyStagedConfigOperation(del), "accepted",
            "465-rw: warm delete " .. warmIds[i])
    end
    local warmInc = tonumber(GS._softDeleteIncrementalApplies) or 0
    local warmScanAfter = tonumber(GS._softDeleteCumulativeEventVisits) or 0
    local warmHeads = tonumber(GS._softDeleteCumulativeHeadVisits) or 0
    assertTrue(warmInc >= warmExtra - 2,
        "465-rw: warm incremental deletes got " .. tostring(warmInc))
    assertTrue(warmScanAfter - warmScan < warmExtra * (noiseN / 2),
        "465-rw: warm deletes avoid per-delete full ledger rescans delta="
            .. tostring(warmScanAfter - warmScan))
    assertTrue(warmHeads - warmHeadsBefore <= warmExtra + 2,
        "465-rw: warm head visits near-incremental got "
            .. tostring(warmHeads - warmHeadsBefore))
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(256)
    local exportBodies = collectAllExportBodies()
    local sourceDataset = record.datasetId

    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    -- Real scheduled slices — not the default in-process sync drain.
    GS._adoptionReplaySyncDrain = false
    local savedSlice = GS.MAX_ADMISSION_WORK_PER_SLICE
    GS.MAX_ADMISSION_WORK_PER_SLICE = 8
    GS:CreateStagedRecord()
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "465-rw: begin adoption")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "465-rw: transfer ready")

    GS._softDeleteCumulativeEventVisits = 0
    GS._softDeleteCumulativeHistVisits = 0
    GS._softDeleteCumulativeHeadVisits = 0
    GS._softDeleteColdLedgerBuilds = 0
    GS._softDeleteIncrementalApplies = 0
    local totalFloorBuild, totalFloorQuery, stampVisits = 0, 0, 0
    local function noteFloorCounters()
        totalFloorBuild = totalFloorBuild
            + (tonumber(GS._softDeleteDebtFloorBuildVisits) or 0)
        totalFloorQuery = totalFloorQuery
            + (tonumber(GS._softDeleteDebtFloorQueryVisits) or 0)
        stampVisits = stampVisits
            + (tonumber(GS._softDeleteDebtFloorStampVisits) or 0)
        GS._softDeleteDebtFloorBuildVisits = 0
        GS._softDeleteDebtFloorQueryVisits = 0
        GS._softDeleteDebtFloorStampVisits = 0
    end

    local commitSt, commitErr = GS:CommitDatasetAdoption()
    assertTrue(commitSt == "pending" or commitSt == "accepted",
        "465-rw: commit starts got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
    local timerSlices = 0
    while GS._adoption and GS._adoption.replayTemp and timerSlices < 8000 do
        noteFloorCounters()
        if not runOneDueTimer() then
            world.time = world.time + 1
            if not runOneDueTimer() then
                break
            end
        end
        timerSlices = timerSlices + 1
    end
    noteFloorCounters()
    if GS:GetPendingAdoption() then
        commitSt, commitErr = GS:CommitDatasetAdoption()
        local guard = 0
        while commitSt == "pending" and guard < 256 do
            if not runOneDueTimer() then
                world.time = world.time + 1
                if not runOneDueTimer() then
                    commitSt, commitErr = GS:CommitDatasetAdoption()
                end
            end
            guard = guard + 1
        end
    else
        commitSt, commitErr = "accepted", nil
    end
    GS.MAX_ADMISSION_WORK_PER_SLICE = savedSlice
    GS._adoptionReplaySyncDrain = true
    local totalEventVisits = tonumber(GS._softDeleteCumulativeEventVisits) or 0
    local totalHistVisits = tonumber(GS._softDeleteCumulativeHistVisits) or 0
    local totalHeadVisits = tonumber(GS._softDeleteCumulativeHeadVisits) or 0
    local coldBuilds = tonumber(GS._softDeleteColdLedgerBuilds) or 0
    local incremental = tonumber(GS._softDeleteIncrementalApplies) or 0
    assertEq(commitSt, "accepted",
        "465-rw: adopt commit got " .. tostring(commitSt) .. "/" .. tostring(commitErr))
    assertTrue(timerSlices >= 8,
        "465-rw: scheduled timer slices observed n=" .. tostring(timerSlices))
    assertTrue(coldBuilds <= 6,
        "465-rw: few cold ledger builds during adopt got " .. tostring(coldBuilds))
    assertTrue(incremental >= deleteN - coldBuilds,
        "465-rw: incremental delete applies got " .. tostring(incremental)
            .. " cold=" .. tostring(coldBuilds))
    local liveN = noiseN + deleteN + 1 + adjN
    assertTrue(totalEventVisits < deleteN * liveN,
        "465-rw: cumulative ledger visits below per-delete full scans ("
            .. tostring(totalEventVisits) .. " < " .. tostring(deleteN * liveN) .. ")")
    assertTrue(totalHeadVisits < deleteN * deleteN,
        "465-rw: head visits below quadratic fold ("
            .. tostring(totalHeadVisits) .. " < " .. tostring(deleteN * deleteN) .. ")")
    assertTrue(totalHistVisits < deleteN * (liveN + deleteN + 8),
        "465-rw: hist visits bounded got " .. tostring(totalHistVisits))
    assertEq(stampVisits, 0, "465-rw: debt-floor stamps stay O(1)/no map scans")
    assertTrue(totalFloorQuery <= adjN + deleteN + 16,
        "465-rw: floor queries O(1) per adj got " .. tostring(totalFloorQuery))
    assertTrue(totalFloorBuild < deleteN * adjN,
        "465-rw: floor builds amortized got " .. tostring(totalFloorBuild))

    local adopted = GS:GetCurrentRecord()
    assertTrue(type(adopted) == "table", "465-rw: adopted record")
    assertEq(adopted.datasetId, sourceDataset, "465-rw: adopted dataset")
    local projected = 0
    for i = 1, deleteN do
        if GS.IsEventSoftDeleted(adopted, deleteIds[i]) then
            projected = projected + 1
        end
    end
    assertEq(projected, deleteN, "465-rw: adopted projects all deletes")

    -- Dependency invalidation: deletion-gen bump forces floor rebuild; then
    -- an ordinary adjustment query reuses the aggregate (no stamp map scans).
    GS._softDeleteDebtFloorIndexReuse = true
    GS._softDeleteDebtFloorBuildVisits = 0
    GS._softDeleteDebtFloorStampVisits = 0
    if GS.InvalidateEventDeletionProjection then
        GS.InvalidateEventDeletionProjection(adopted)
    end
    local okProbe, probeErr = GS.AdjustmentFloorOk(
        adopted, itemId, -1, "Alice-Garona", adopted.currentCampaignId, {
            respectSoftDeleteDebt = true,
            attributedGuid = "Player-1-Alice",
        })
    assertTrue(okProbe,
        "465-rw: post-invalidate floor ok err=" .. tostring(probeErr))
    assertEq(GS._softDeleteDebtFloorIndexReuse, false,
        "465-rw: floor rebuilt after real invalidation")
    assertTrue((tonumber(GS._softDeleteDebtFloorBuildVisits) or 0) > 0,
        "465-rw: invalidate forced aggregate rebuild")
    GS._softDeleteDebtFloorBuildVisits = 0
    GS._softDeleteDebtFloorStampVisits = 0
    local okReuse = GS.AdjustmentFloorOk(
        adopted, itemId, -1, "Alice-Garona", adopted.currentCampaignId, {
            respectSoftDeleteDebt = true,
            attributedGuid = "Player-1-Alice",
        })
    assertTrue(okReuse, "465-rw: reuse floor query ok")
    assertEq(GS._softDeleteDebtFloorIndexReuse, true,
        "465-rw: unchanged deps reuse floor aggregate")
    assertEq(tonumber(GS._softDeleteDebtFloorStampVisits) or 0, 0,
        "465-rw: reuse stamp stays O(1)")

    assertEq(GS._softDeleteRedriveAdmitActive, false, "465-rw: redrive idle before replace")
    if GS:GetPendingAdoption() then
        GS:CancelDatasetAdoption()
    end
    SpectrumFederationDB = {}
    switchPlayer("Alice", "Player-1-Alice", 1)
    settleRoster()
    initGS()
    GS:CreateStagedRecord()
    flushTimers()
    assertEq(GS._softDeleteRedriveAdmitActive, false, "465-rw: idle after dataset replace")
end

io.stdout:write(string.format("\nguild_supplies_465_tests: %d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
