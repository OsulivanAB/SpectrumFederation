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

io.stdout:write(string.format("\nguild_supplies_465_tests: %d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
