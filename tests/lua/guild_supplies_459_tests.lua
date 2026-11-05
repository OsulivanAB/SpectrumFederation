-- Production-Lua tests for Guild Supplies contributor corrections (#459).
-- Run from repository root: lua5.1 tests/lua/guild_supplies_459_tests.lua

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

-- Minimal Settings UI stub so Logs page hooks can exercise Edit eligibility (#459).
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
    assertEq(select(2, GS:CreateStagedRecord()), "accepted", "459 seed: create")
    startCampaign()
    local tabOp = select(1, GS:NewConfigOperation("set-bank-tab", "bankTab", 2))
    assertEq(GS:ApplyStagedConfigOperation(tabOp), "accepted", "459 seed: tab")
    local itemOp = select(1, GS:NewConfigOperation("set-requested-item", { itemId = itemId }, {
        itemId = itemId, goal = goal or 100, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(itemOp), "accepted", "459 seed: item")
    world.time = (world.time or 0) + 7200
    GetNumGuildBankTransactions = function() return 0 end
    GetGuildBankTransaction = function()
        return "deposit", "Donor-Garona", "|Hitem:" .. tostring(itemId) .. "::::::::|h[Item]|h", 2,
            1, 1, 2026, 10, 19, 12
    end
    GS._BankContextReadinessProbe = function() return true end
    local _, actSt = GS:ActivateCanonicalDataset()
    assertEq(actSt, "accepted", "459 seed: activate")
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

assertEq(GS.PROVIDER_SCHEMA, 5, "459: PROVIDER_SCHEMA is 5")
assertTrue(GS.KIND.CORRECT_CONTRIBUTOR == "correct-contributor", "459: correction kind registered")

do
    -- Donation A → B moves credit once; durable actor unchanged; rankings follow effective.
    local record = seedLiveCampaignWithItem(9101, 100)
    local donation = injectProductionDonation(record, {
        id = "corr-don-1", itemId = 9101, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local personalA = GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9101)
    assertEq(personalA, 10, "459: Alice personal before correction")

    local op, st, reason = GS:NewContributorCorrectionOperation("corr-don-1", "Bob-Garona", "Player-1-Bob")
    assertTrue(op ~= nil, "459: prepare donation correction: " .. tostring(reason))
    assertEq(st, "accepted", "459: prepare status")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "459: apply donation correction")

    assertEq(donation.actor, "Alice-Garona", "459: durable donor unchanged")
    local effName = select(1, GS.ResolveEffectiveCreditIdentity(record, donation))
    assertEq(effName, "Bob-Garona", "459: effective credit is Bob")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9101), 0,
        "459: Alice personal after move")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9101), 10,
        "459: Bob personal after move")

    local progress = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    assertEq(tonumber(progress.itemTotals[9101]) or 0, 10, "459: campaign item total unchanged")
    local bobContrib = progress.contributions["Bob-Garona"]
    assertTrue(type(bobContrib) == "table", "459: progress credits Bob")
    assertEq(tonumber(bobContrib[9101]) or 0, 10, "459: Bob contribution qty")
    assertNil(progress.contributions["Alice-Garona"], "459: Alice no longer in contributions")

    local rankings = GS.ProjectCampaignRankingsOnRecord(record, record.currentCampaignId)
    local rankedBob = false
    for i = 1, #(rankings.rows or {}) do
        if rankings.rows[i].name == "Bob-Garona" then rankedBob = true end
        assertTrue(rankings.rows[i].name ~= "Alice-Garona", "459: Alice absent from rankings")
    end
    assertTrue(rankedBob, "459: Bob on rankings")
    assertEq(#world.chat, 0, "459: no chat after donation correction")
end

do
    -- Personal floor: A +10 then A -8; moving +10 away must reject.
    local record = seedLiveCampaignWithItem(9102, 100)
    injectProductionDonation(record, {
        id = "floor-don", itemId = 9102, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(record, {
        id = "floor-adj", itemId = 9102, quantity = -8,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9102), 2,
        "459: Alice personal 10-8=2")
    local op, st, reason = GS:NewContributorCorrectionOperation("floor-don", "Bob-Garona", nil)
    assertNil(op, "459: unsafe floor prepare rejected")
    assertEq(reason, "player_negative", "459: floor reason player_negative got " .. tostring(reason))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, GS.FindLedgerEventById(record, "floor-don"))),
        "Alice-Garona", "459: credit unchanged after rejected prepare")
end

do
    -- Unchanged attribution is a no-op; cancel-equivalent.
    local record = seedLiveCampaignWithItem(9103, 50)
    injectProductionDonation(record, {
        id = "noop-don", itemId = 9103, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local op, st, reason = GS:NewContributorCorrectionOperation("noop-don", "Alice-Garona", "Player-1-Alice")
    assertNil(op, "459: unchanged prepare rejected")
    assertEq(reason, "unchanged_attribution", "459: unchanged reason")
end

do
    -- Adjustment Unassigned → named; Unassigned excluded from rankings until attributed.
    -- Use a positive unassigned adjustment so assigning to Bob does not violate
    -- Bob's personal nonnegative floor.
    local record = seedLiveCampaignWithItem(9104, 80)
    injectProductionDonation(record, {
        id = "base-don", itemId = 9104, quantity = 20,
        actor = "Carol-Garona", actorGuid = "Player-1-Carol",
    })
    local adj = injectProductionAdjustment(record, {
        id = "unassigned-adj", itemId = 9104, quantity = 5,
        attributed = nil, unitCopper = 100,
    })
    local rankingsBefore = GS.ProjectCampaignRankingsOnRecord(record, record.currentCampaignId)
    for i = 1, #(rankingsBefore.rows or {}) do
        -- Only Carol should appear from the donation; unassigned adj omitted.
        assertTrue(rankingsBefore.rows[i].name == "Carol-Garona", "459: only Carol before assign")
    end
    local op, prepSt, prepReason = GS:NewContributorCorrectionOperation("unassigned-adj", "Bob-Garona", nil)
    assertTrue(op ~= nil, "459: prepare unassigned→Bob: " .. tostring(prepReason))
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "459: apply unassigned→Bob")
    assertNil(adj.attributed, "459: durable adjustment attribution still nil")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, adj)), "Bob-Garona",
        "459: effective adj credit Bob")
    assertEq(adj.unitCopper, 100, "459: unitCopper preserved")
    local rankingsAfter = GS.ProjectCampaignRankingsOnRecord(record, record.currentCampaignId)
    local bobSeen = false
    for i = 1, #(rankingsAfter.rows or {}) do
        if rankingsAfter.rows[i].name == "Bob-Garona" then
            bobSeen = true
            assertEq(rankingsAfter.rows[i].totalCopper, 500, "459: Bob ranking copper 100*5")
        end
    end
    assertTrue(bobSeen, "459: Bob appears on rankings after assign")
end

do
    -- Stale dialog: expected base no longer matches current effective.
    local record = seedLiveCampaignWithItem(9105, 60)
    injectProductionDonation(record, {
        id = "stale-don", itemId = 9105, quantity = 6,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local op1 = select(1, GS:NewContributorCorrectionOperation("stale-don", "Bob-Garona", nil))
    assertEq(GS:ApplyStagedConfigOperation(op1), "accepted", "459: first correction Bob")
    world.time = world.time + 10
    -- Stale op still claiming Alice as base while head is Bob.
    local stale = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "stale-op-manual",
        guildKey = record.guildKey or select(1, GS:GetCurrentContext()).guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "stale-don",
        value = {
            eventId = "stale-don",
            eventKind = "donation",
            attributed = "Carol-Garona",
            attributedGuid = "Player-1-Carol",
            baseAttributed = "Alice-Garona",
            baseAttributedGuid = "Player-1-Alice",
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
        _preparedHandleGeneration = select(1, GS:GetCurrentContext()).handleGeneration,
    }
    local ok, err = GS:ValidateConfigOperation(stale)
    assertEq(ok, false, "459: stale validate fails")
    assertEq(err, "stale_credit", "459: stale_credit reason got " .. tostring(err))
end

do
    -- LWW: later correction wins; earlier becomes obsolete on remote classify path.
    local record = seedLiveCampaignWithItem(9106, 70)
    injectProductionDonation(record, {
        id = "lww-don", itemId = 9106, quantity = 7,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    world.time = world.time + 1
    local early = select(1, GS:NewContributorCorrectionOperation("lww-don", "Bob-Garona", nil))
    assertEq(GS:ApplyStagedConfigOperation(early), "accepted", "459: early Bob")
    world.time = world.time + 5
    local late = select(1, GS:NewContributorCorrectionOperation("lww-don", "Carol-Garona", nil))
    assertEq(GS:ApplyStagedConfigOperation(late), "accepted", "459: late Carol wins")
    local event = GS.FindLedgerEventById(record, "lww-don")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, event)), "Carol-Garona",
        "459: LWW effective Carol")
    assertEq(record.creditCorrections["lww-don"].previousAttributed, "Bob-Garona",
        "459: previous credit retained for audit")
    assertEq(record.creditCorrections["lww-don"].originalAttributed, "Alice-Garona",
        "459: original donor retained for audit")
end

do
    -- Correction-before-event: remote admit stays pending until base exists, then
    -- authenticated redrive promotes through AdmitRemoteOperation (#459).
    local record = seedLiveCampaignWithItem(9107, 40)
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    settleRoster()
    local pendingOp = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "corr-before-event",
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "late-don",
        value = {
            eventId = "late-don",
            eventKind = "donation",
            attributed = "Bob-Garona",
            attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona",
            baseAttributedGuid = "Player-1-Alice",
            itemId = 9107,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 1,
        -- Match CurrentTargetRevision fallback when no correction head exists.
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    local st, reason = GS:AdmitRemoteOperation(pendingOp, {
        sender = "Alice-Garona",
        offlineRecord = record,
        preserveAttribution = true,
    })
    assertEq(st, "pending", "459: early correction pending got " .. tostring(st) .. "/" .. tostring(reason))
    assertEq(reason, "pending_event", "459: pending_event reason got " .. tostring(reason))
    local pend = record.operations.pending and record.operations.pending[pendingOp.id]
    assertTrue(type(pend) == "table", "459: pending retained")
    assertEq(pend.sender, "Alice-Garona", "459: pending keeps authenticated sender")
    record.operations.pending["untrusted-corr"] = {
        id = "untrusted-corr",
        body = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "untrusted-corr",
            guildKey = pendingOp.guildKey,
            datasetId = pendingOp.datasetId,
            campaignId = pendingOp.campaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "late-don",
            value = pendingOp.value,
            actorGuid = "Player-1-Eve",
            actorName = "Eve-Garona",
            timestamp = world.time + 2,
        },
        reason = "untrusted_relay",
        sender = "Eve-Garona",
    }
    injectProductionDonation(record, {
        id = "late-don", itemId = 9107, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    GS.RebuildCreditCorrectionProjection(record, nil)
    local promoted = GS.RedrivePendingContributorCorrections(record, {
        eventId = "late-don",
        itemId = 9107,
    })
    assertTrue(promoted >= 1, "459: pending correction promoted after event got " .. tostring(promoted))
    assertTrue(record.operations.records["corr-before-event"] ~= nil,
        "459: trusted correction accepted via redrive")
    assertTrue(record.operations.records["untrusted-corr"] == nil,
        "459: untrusted pending not promoted")
    local event = GS.FindLedgerEventById(record, "late-don")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, event)), "Bob-Garona",
        "459: credit after redrive")
end

do
    -- Unauthorized member cannot prepare.
    local record = seedLiveCampaignWithItem(9108, 30)
    injectProductionDonation(record, {
        id = "auth-don", itemId = 9108, quantity = 2,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    setPlayer("Dave-Garona", "Player-1-Dave", 4)
    settleRoster()
    local op, st, reason = GS:NewContributorCorrectionOperation("auth-don", "Bob-Garona", nil)
    assertNil(op, "459: member prepare rejected")
    assertEq(reason, "unauthorized", "459: member unauthorized got " .. tostring(reason))
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    settleRoster()
    world.impersonationActive = true
    local op2, _, reason2 = GS:NewContributorCorrectionOperation("auth-don", "Bob-Garona", nil)
    assertNil(op2, "459: preview prepare rejected")
    assertEq(reason2, "preview_non_admin", "459: preview reason got " .. tostring(reason2))
    world.impersonationActive = false
end

do
    -- Same-id retry is idempotent duplicate.
    local record = seedLiveCampaignWithItem(9109, 30)
    injectProductionDonation(record, {
        id = "dup-don", itemId = 9109, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local op = select(1, GS:NewContributorCorrectionOperation("dup-don", "Bob-Garona", nil))
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "459: first apply")
    assertEq(GS:ApplyStagedConfigOperation(op), "duplicate", "459: same-id retry duplicate")
end

do
    -- History projection exposes effective credit + correction audit fields.
    local record = seedLiveCampaignWithItem(9110, 30)
    injectProductionDonation(record, {
        id = "hist-don", itemId = 9110, quantity = 8,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local op = select(1, GS:NewContributorCorrectionOperation("hist-don", "Bob-Garona", nil))
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "459: hist correction")
    local rows = select(1, GS:ListCampaignHistory(record.currentCampaignId, nil, 0))
    local found = nil
    for i = 1, #rows do
        if rows[i].id == "hist-don" then found = rows[i] break end
    end
    assertTrue(found ~= nil, "459: history row present")
    assertEq(found.actor, "Alice-Garona", "459: history durable actor")
    assertEq(found.effectiveAttributed, "Bob-Garona", "459: history effective")
    assertEq(found.displayActor, "Bob-Garona", "459: history display uses effective")
    assertTrue(type(found.creditCorrection) == "table", "459: correction head on history row")
    local detail = GS.FormatCampaignHistoryDetail(found, "Flask")
    assertTrue(type(detail) == "string" and detail:find("corrected", 1, true),
        "459: detail mentions correction")
end


do
    -- Cross-entry convergence: A +10/+10 donations and -10 adjustment.
    -- Peer1 moves don1→Bob; peer2 moves don2→Carol. Both locally valid under
    -- per-event floors, but deterministic active-head rebuild must converge.
    local peerA = seedLiveCampaignWithItem(9201, 100)
    injectProductionDonation(peerA, {
        id = "cross-don-1", itemId = 9201, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = 6000,
    })
    injectProductionDonation(peerA, {
        id = "cross-don-2", itemId = 9201, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = 6001,
    })
    injectProductionAdjustment(peerA, {
        id = "cross-adj", itemId = 9201, quantity = -10,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice", timestamp = 6002,
    })
    assertEq(GS.PersonalContributorItemTotal(peerA, "Alice-Garona", "Player-1-Alice", 9201), 10,
        "459: Alice personal 10 before cross edits")
    world.time = 7000
    local move1 = select(1, GS:NewContributorCorrectionOperation("cross-don-1", "Bob-Garona", "Player-1-Bob"))
    assertTrue(move1 ~= nil, "459: peerA can prepare don1→Bob")
    assertEq(GS:ApplyStagedConfigOperation(move1), "accepted", "459: peerA applies don1→Bob")
    local snap1 = select(1, GS._SnapshotPublicOp(move1))

    local peerB = seedLiveCampaignWithItem(9201, 100)
    injectProductionDonation(peerB, {
        id = "cross-don-1", itemId = 9201, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = 6000,
    })
    injectProductionDonation(peerB, {
        id = "cross-don-2", itemId = 9201, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = 6001,
    })
    injectProductionAdjustment(peerB, {
        id = "cross-adj", itemId = 9201, quantity = -10,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice", timestamp = 6002,
    })
    world.time = 7001
    local move2 = select(1, GS:NewContributorCorrectionOperation("cross-don-2", "Carol-Garona", "Player-1-Carol"))
    assertTrue(move2 ~= nil, "459: peerB can prepare don2→Carol")
    assertEq(GS:ApplyStagedConfigOperation(move2), "accepted", "459: peerB applies don2→Carol")
    local snap2 = select(1, GS._SnapshotPublicOp(move2))

    local function rebaseSnap(snap, record)
        local body = {}
        for k, v in pairs(snap) do body[k] = v end
        body.guildKey = select(1, GS:GetCurrentContext()).guildKey
        body.datasetId = record.datasetId
        body.campaignId = record.currentCampaignId
        body.baseCampaignId = record.currentCampaignId
        body.basePolicyRevision = record.permission and record.permission.revisionId
        if body.baseTargetRevision == nil or body.baseTargetRevision == snap.datasetId then
            body.baseTargetRevision = record.datasetId
        end
        return body
    end

    -- Re-establish peerA with move1 only, then admit move2.
    peerA = seedLiveCampaignWithItem(9201, 100)
    injectProductionDonation(peerA, {
        id = "cross-don-1", itemId = 9201, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = 6000,
    })
    injectProductionDonation(peerA, {
        id = "cross-don-2", itemId = 9201, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = 6001,
    })
    injectProductionAdjustment(peerA, {
        id = "cross-adj", itemId = 9201, quantity = -10,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice", timestamp = 6002,
    })
    local snap1A = rebaseSnap(snap1, peerA)
    local snap2A = rebaseSnap(snap2, peerA)
    -- move1 originally targeted peerA's earlier dataset; after rebase, baseTarget
    -- for a first correction is datasetId (no head).
    snap1A.baseTargetRevision = peerA.datasetId
    snap2A.baseTargetRevision = peerA.datasetId
    assertEq(select(1, GS:AdmitRemoteOperation(snap1A, {
        sender = "Alice-Garona", offlineRecord = peerA, preserveAttribution = true,
    })), "accepted", "459: peerA accepts move1")
    local stA2, rA2 = GS:AdmitRemoteOperation(snap2A, {
        sender = "Alice-Garona", offlineRecord = peerA, preserveAttribution = true,
    })
    assertTrue(stA2 == "accepted" or stA2 == "pending",
        "459: peerA admits move2 got " .. tostring(stA2) .. "/" .. tostring(rA2))
    GS.RebuildCreditCorrectionProjection(peerA, nil)

    local snap1B = rebaseSnap(snap1, peerB)
    snap1B.baseTargetRevision = peerB.datasetId
    local stB1, rB1 = GS:AdmitRemoteOperation(snap1B, {
        sender = "Alice-Garona", offlineRecord = peerB, preserveAttribution = true,
    })
    assertTrue(stB1 == "accepted" or stB1 == "pending",
        "459: peerB admits move1 got " .. tostring(stB1) .. "/" .. tostring(rB1))
    GS.RebuildCreditCorrectionProjection(peerB, nil)

    local function creditOf(record, id)
        local ev = GS.FindLedgerEventById(record, id)
        return select(1, GS.ResolveEffectiveCreditIdentity(record, ev))
    end
    assertEq(creditOf(peerA, "cross-don-1"), creditOf(peerB, "cross-don-1"),
        "459: peers converge don1 credit")
    assertEq(creditOf(peerA, "cross-don-2"), creditOf(peerB, "cross-don-2"),
        "459: peers converge don2 credit")
    assertTrue(GS.PersonalContributorItemTotal(peerA, "Alice-Garona", "Player-1-Alice", 9201) >= 0,
        "459: Alice personal nonnegative peerA")
    assertTrue(GS.PersonalContributorItemTotal(peerB, "Alice-Garona", "Player-1-Alice", 9201) >= 0,
        "459: Alice personal nonnegative peerB")
    local activeMoves = 0
    if creditOf(peerA, "cross-don-1") == "Bob-Garona" then activeMoves = activeMoves + 1 end
    if creditOf(peerA, "cross-don-2") == "Carol-Garona" then activeMoves = activeMoves + 1 end
    assertEq(activeMoves, 1, "459: exactly one cross transfer active got " .. tostring(activeMoves))
end

do
    -- Authored previous credit survives reversed delivery order.
    local record = seedLiveCampaignWithItem(9202, 50)
    injectProductionDonation(record, {
        id = "rev-don", itemId = 9202, quantity = 9,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    world.time = world.time + 1
    local early = select(1, GS:NewContributorCorrectionOperation("rev-don", "Bob-Garona", nil))
    assertTrue(early ~= nil, "459: early prepare")
    world.time = world.time + 5
    local late = select(1, GS:NewContributorCorrectionOperation("rev-don", "Carol-Garona", nil))
    assertTrue(late ~= nil, "459: late prepare against current Alice base")
    -- late was prepared while Alice still credited; rebuild a clean peer and
    -- deliver late then early.
    record.creditCorrections = nil
    record.operations.records = {}
    record.operations.order = {}
    record.operations.heads = {}
    record.operations.pending = {}
    local snapLate = select(1, GS._SnapshotPublicOp(late))
    local snapEarly = select(1, GS._SnapshotPublicOp(early))
    assertEq(select(1, GS:AdmitRemoteOperation(snapLate, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })), "accepted", "459: late arrives first")
    assertEq(record.creditCorrections["rev-don"].previousAttributed, "Alice-Garona",
        "459: late authored previous is Alice")
    local stEarly = select(1, GS:AdmitRemoteOperation(snapEarly, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    }))
    assertTrue(stEarly == "accepted" or stEarly == "obsolete" or stEarly == "rejected",
        "459: early after late status " .. tostring(stEarly))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, GS.FindLedgerEventById(record, "rev-don"))),
        "Carol-Garona", "459: effective stays Carol")
    assertEq(record.creditCorrections["rev-don"].previousAttributed, "Alice-Garona",
        "459: audit previous stays authored Alice after reverse delivery")
end

do
    -- Unassigned correction stays Unassigned in history projection.
    local record = seedLiveCampaignWithItem(9203, 40)
    injectProductionDonation(record, {
        id = "ua-base", itemId = 9203, quantity = 12,
        actor = "Carol-Garona", actorGuid = "Player-1-Carol",
    })
    injectProductionAdjustment(record, {
        id = "ua-adj", itemId = 9203, quantity = 4,
        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
    })
    local op = select(1, GS:NewContributorCorrectionOperation("ua-adj", nil, nil))
    assertTrue(op ~= nil, "459: prepare Bob→Unassigned")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "459: apply Unassigned")
    local rows = select(1, GS:ListCampaignHistory(record.currentCampaignId, nil, 0))
    local found = nil
    for i = 1, #rows do
        if rows[i].id == "ua-adj" then found = rows[i] break end
    end
    assertTrue(found ~= nil, "459: unassigned history row")
    assertNil(found.effectiveAttributed, "459: effective Unassigned nil")
    assertNil(found.displayAttributed, "459: displayAttributed nil for Unassigned")
    assertTrue(type(found.text) == "string" and found.text:find("unattributed", 1, true),
        "459: history text uses unattributed wording")
end

do
    -- Alias-aware correction target resolves to canonical ledger event.
    local record = seedLiveCampaignWithItem(9204, 40)
    local don = injectProductionDonation(record, {
        id = "ctx:canon-don", itemId = 9204, quantity = 6,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    don.txnId = "ctx:canon-don"
    local cfg = record.accounting._consumables
    cfg.txnRegistry = cfg.txnRegistry or {}
    cfg.txnRegistry[#cfg.txnRegistry + 1] = {
        txnId = "ctx:canon-don",
        status = "committed",
        aliases = { "ctx:alias-don" },
        committed = true,
    }
    cfg.txnRegistry[#cfg.txnRegistry + 1] = {
        txnId = "ctx:alias-don",
        status = "alias",
        aliasOf = "ctx:canon-don",
        committed = true,
    }
    local found = GS.FindLedgerEventById(record, "ctx:alias-don")
    assertTrue(found ~= nil and found.id == "ctx:canon-don", "459: alias resolves to canonical event")
    local op = select(1, GS:NewContributorCorrectionOperation("ctx:alias-don", "Bob-Garona", nil))
    assertTrue(op ~= nil, "459: prepare via alias id")
    assertEq(op.target, "ctx:canon-don", "459: op targets canonical id")
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "459: apply alias correction")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Bob-Garona",
        "459: credit via alias correction")
end

do
    -- Logs UI: production credit gate, concrete prefill, GetNumGuildMembers multi-return.
    local logsPage = SF.SettingsUI and SF.SettingsUI.pagesById
        and SF.SettingsUI.pagesById.guildSuppliesLogs
    assertTrue(logsPage and logsPage.__sfTest, "459: Logs page test hooks available")
    local record = seedLiveCampaignWithItem(9205, 40)
    injectProductionDonation(record, {
        id = "ui-don", itemId = 9205, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local staged = injectProductionDonation(record, {
        id = "ui-staged", itemId = 9205, quantity = 2,
        actor = "Bob-Garona", actorGuid = "Player-1-Bob",
    })
    staged.gsProductionCredit = false
    staged.uncredited = nil
    local rows = logsPage.__sfTest.BuildProjectedRows()
    local credited, stagedRow = nil, nil
    for i = 1, #rows do
        if rows[i].id == "ui-don" then credited = rows[i] end
        if rows[i].id == "ui-staged" then stagedRow = rows[i] end
    end
    assertTrue(credited and credited.showAction == true, "459: credited row shows Edit")
    -- Live Logs omit uncredited rows (progress-aligned). Edit open still rejects.
    assertNil(stagedRow, "459: staged uncredited row omitted from live Logs")
    logsPage.__sfTest.OpenEditContributorDialog("ui-staged", {
        _eventKind = "donation",
        _contributorName = "Bob-Garona",
        _quantityText = "2",
        _itemText = "Item",
    })
    assertNil(logsPage.__sfTest.GetEditSession(),
        "459: Edit refused for non-production-credited row")
    assertEq(credited._effectiveName, "Alice-Garona", "459: prefill concrete effective name")
    local cache = logsPage.__sfTest.EnsureEditRosterCache()
    assertTrue(type(cache.names) == "table" and #cache.names >= 4,
        "459: roster cache populated despite multi-return GetNumGuildMembers")
    logsPage.__sfTest.OpenEditContributorDialog("ui-don", credited)
    local session = logsPage.__sfTest.GetEditSession()
    assertTrue(type(session) == "table", "459: edit session opened")
    assertEq(session.effectiveName, "Alice-Garona", "459: session captures effective")
    assertEq(session.attributed, "Alice-Garona", "459: prefill matches effective")
    assertEq(session.datasetId, record.datasetId, "459: session captures dataset")
    local op, st, reason = GS:NewContributorCorrectionOperation(
        session.eventId, session.attributed, session.attributedGuid)
    assertNil(op, "459: unchanged editor selection is no-op")
    assertEq(reason, "unchanged_attribution", "459: unchanged reason")
    logsPage.__sfTest.ClearEditSession()
end

do
    -- #459 dependency policy: later D1→B + B−10 must stay active when older D2→C
    -- arrives; every personal floor stays nonnegative (descending greedy).
    local function seedDepPeers()
        local record = seedLiveCampaignWithItem(9301, 100)
        injectProductionDonation(record, {
            id = "dep-don-1", itemId = 9301, quantity = 10,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = 8000,
        })
        injectProductionDonation(record, {
            id = "dep-don-2", itemId = 9301, quantity = 10,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = 8001,
        })
        injectProductionAdjustment(record, {
            id = "dep-adj-a", itemId = 9301, quantity = -10,
            attributed = "Alice-Garona", attributedGuid = "Player-1-Alice", timestamp = 8002,
        })
        return record
    end
    local peer1 = seedDepPeers()
    world.time = 9000
    local moveD1 = select(1, GS:NewContributorCorrectionOperation(
        "dep-don-1", "Bob-Garona", "Player-1-Bob"))
    assertTrue(moveD1 ~= nil, "459: dep peer1 prepare D1→B")
    assertEq(GS:ApplyStagedConfigOperation(moveD1), "accepted", "459: dep peer1 apply D1→B")
    injectProductionAdjustment(peer1, {
        id = "dep-adj-b", itemId = 9301, quantity = -10,
        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob", timestamp = 9001,
    })
    assertEq(GS.PersonalContributorItemTotal(peer1, "Bob-Garona", "Player-1-Bob", 9301), 0,
        "459: Bob spent corrected credit to zero")
    local snapD1 = select(1, GS._SnapshotPublicOp(moveD1))

    local peer2 = seedDepPeers()
    world.time = 8500
    local moveD2 = select(1, GS:NewContributorCorrectionOperation(
        "dep-don-2", "Carol-Garona", "Player-1-Carol"))
    assertTrue(moveD2 ~= nil, "459: dep peer2 prepare D2→C")
    assertEq(GS:ApplyStagedConfigOperation(moveD2), "accepted", "459: dep peer2 apply D2→C")
    local snapD2 = select(1, GS._SnapshotPublicOp(moveD2))

    local function rebase(snap, record)
        local body = {}
        for k, v in pairs(snap) do body[k] = v end
        body.guildKey = select(1, GS:GetCurrentContext()).guildKey
        body.datasetId = record.datasetId
        body.campaignId = record.currentCampaignId
        body.baseCampaignId = record.currentCampaignId
        body.basePolicyRevision = record.permission and record.permission.revisionId
        body.baseTargetRevision = record.datasetId
        return body
    end

    local function assertAllNonNeg(record, label)
        assertTrue(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9301) >= 0,
            "459: " .. label .. " Alice nonnegative")
        assertTrue(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9301) >= 0,
            "459: " .. label .. " Bob nonnegative")
        assertTrue(GS.PersonalContributorItemTotal(record, "Carol-Garona", "Player-1-Carol", 9301) >= 0,
            "459: " .. label .. " Carol nonnegative")
    end

    -- Delivery order: older D2→C after D1→B + B−10 on peer1.
    local bodyD2 = rebase(snapD2, peer1)
    local stDep, rDep = GS:AdmitRemoteOperation(bodyD2, {
        sender = "Alice-Garona", offlineRecord = peer1, preserveAttribution = true,
    })
    assertTrue(stDep == "accepted" or stDep == "pending" or stDep == "duplicate",
        "459: peer1 admits older D2→C got " .. tostring(stDep) .. "/" .. tostring(rDep))
    GS.EnsureCreditCorrectionProjection(peer1, nil)
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peer1, GS.FindLedgerEventById(peer1, "dep-don-1"))), "Bob-Garona",
        "459: D1→B stays active after older D2→C")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peer1, GS.FindLedgerEventById(peer1, "dep-don-2"))), "Alice-Garona",
        "459: older D2→C inactive when it would break Bob floor")
    assertAllNonNeg(peer1, "peer1-after-D2")
    assertTrue(peer1.operations.records[snapD2.id] ~= nil
        or (peer1.operations.pending and peer1.operations.pending[snapD2.id]),
        "459: older D2 evidence retained accepted or pending")

    -- Reverse delivery: peer2 has D2→C first, then receives D1→B (+ local B−10).
    local peer2b = seedDepPeers()
    local bodyD2b = rebase(snapD2, peer2b)
    assertEq(select(1, GS:AdmitRemoteOperation(bodyD2b, {
        sender = "Alice-Garona", offlineRecord = peer2b, preserveAttribution = true,
    })), "accepted", "459: peer2b accepts D2→C first")
    local bodyD1b = rebase(snapD1, peer2b)
    local stD1b = select(1, GS:AdmitRemoteOperation(bodyD1b, {
        sender = "Alice-Garona", offlineRecord = peer2b, preserveAttribution = true,
    }))
    assertTrue(stD1b == "accepted" or stD1b == "pending",
        "459: peer2b admits D1→B got " .. tostring(stD1b))
    injectProductionAdjustment(peer2b, {
        id = "dep-adj-b2", itemId = 9301, quantity = -10,
        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob", timestamp = 9100,
    })
    GS.EnsureCreditCorrectionProjection(peer2b, nil)
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peer2b, GS.FindLedgerEventById(peer2b, "dep-don-1"))), "Bob-Garona",
        "459: reverse order keeps D1→B active")
    assertAllNonNeg(peer2b, "peer2b-reverse")
end

do
    -- Correction-before-alias: pending on X, then trusted AddTxnAlias X→Y wakes it.
    local record = seedLiveCampaignWithItem(9302, 40)
    local don = injectProductionDonation(record, {
        id = "ctx:alias-y", itemId = 9302, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    don.txnId = "ctx:alias-y"
    local cfg = record.accounting._consumables
    cfg.txnRegistry = cfg.txnRegistry or {}
    cfg.txnRegistry[#cfg.txnRegistry + 1] = {
        txnId = "ctx:alias-y",
        status = "verified",
        committed = true,
        aliases = {},
        itemId = 9302,
        quantity = 5,
        donor = "Alice-Garona",
    }
    local pendingOp = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "corr-before-alias",
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:alias-x",
        value = {
            eventId = "ctx:alias-x",
            eventKind = "donation",
            attributed = "Bob-Garona",
            attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona",
            baseAttributedGuid = "Player-1-Alice",
            itemId = 9302,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    local stP, rP = GS:AdmitRemoteOperation(pendingOp, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stP, "pending", "459: correction-before-alias pending got " .. tostring(stP) .. "/" .. tostring(rP))
    assertEq(rP, "pending_event", "459: pending_event before alias")
    assertTrue(GS._AddTxnAlias(record, "ctx:alias-y", "ctx:alias-x", don),
        "459: trusted AddTxnAlias installs X→Y")
    flushTimers()
    assertTrue(record.operations.records["corr-before-alias"] ~= nil,
        "459: alias wake promoted correction")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Bob-Garona",
        "459: credit after alias wake")
    local headKey = GS.CorrectionTargetKey(record, "ctx:alias-x")
    assertEq(headKey, "credit:ctx:alias-y", "459: canonical head key after alias")
    assertEq(record.operations.heads[headKey], "corr-before-alias",
        "459: head stored under canonical key")
end

do
    -- Warm-provider notify when newly retaining an obsolete LWW-losing correction.
    local record = seedLiveCampaignWithItem(9303, 40)
    injectProductionDonation(record, {
        id = "hist-lww", itemId = 9303, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    world.time = world.time + 1
    local early = select(1, GS:NewContributorCorrectionOperation("hist-lww", "Bob-Garona", nil))
    world.time = world.time + 5
    local late = select(1, GS:NewContributorCorrectionOperation("hist-lww", "Carol-Garona", nil))
    assertEq(GS:ApplyStagedConfigOperation(late), "accepted", "459: late winner first")
    local notifies = {}
    local prevNotify = GS._NotifyLocalDurableChange
    GS._NotifyLocalDurableChange = function(reason)
        notifies[#notifies + 1] = reason
        if prevNotify then prevNotify(reason) end
    end
    local snapEarly = select(1, GS._SnapshotPublicOp(early))
    snapEarly.baseTargetRevision = record.datasetId
    local stE, rE = GS:AdmitRemoteOperation(snapEarly, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    GS._NotifyLocalDurableChange = prevNotify
    assertTrue(stE == "accepted" or stE == "obsolete",
        "459: losing correction retained got " .. tostring(stE) .. "/" .. tostring(rE))
    local sawHistory = false
    for i = 1, #notifies do
        if notifies[i] == "remote-correction-history" then
            sawHistory = true
        end
    end
    assertTrue(sawHistory, "459: warm provider notified for retained losing correction")
    assertTrue(record.operations.records[early.id] ~= nil,
        "459: losing body kept in accepted history")
end

do
    -- Redrive attempt budget + eventual continuation for >32 pending corrections.
    local record = seedLiveCampaignWithItem(9304, 200)
    injectProductionDonation(record, {
        id = "budget-don", itemId = 9304, quantity = 50,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    record.operations.pending = record.operations.pending or {}
    for i = 1, 40 do
        local id = string.format("budget-corr-%02d", i)
        record.operations.pending[id] = {
            id = id,
            sender = "Alice-Garona",
            reason = "pending_event",
            body = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = id,
                guildKey = select(1, GS:GetCurrentContext()).guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = "budget-don",
                value = {
                    eventId = "budget-don",
                    eventKind = "donation",
                    attributed = "Bob-Garona",
                    attributedGuid = "Player-1-Bob",
                    baseAttributed = "Alice-Garona",
                    baseAttributedGuid = "Player-1-Alice",
                    itemId = 9304,
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
    local promoted, attempts = GS.RedrivePendingContributorCorrections(record, {
        eventId = "budget-don",
        itemId = 9304,
        maxAttempts = 32,
    })
    assertEq(attempts, 32, "459: redrive stops at attempt budget got " .. tostring(attempts))
    assertTrue(#timers >= 1, "459: continuation scheduled when backlog remains")
    flushTimers()
    local remaining = 0
    for _ in pairs(record.operations.pending or {}) do
        remaining = remaining + 1
    end
    -- First promotion accepts; later same-target ops become obsolete/duplicate paths.
    assertTrue(promoted >= 1 or record.operations.records["budget-corr-01"] ~= nil
        or remaining < 40,
        "459: budget redrive made progress promoted=" .. tostring(promoted)
            .. " remaining=" .. tostring(remaining))
end

do
    -- Confirm binds to captured payload; selection/session change invalidates Save.
    local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
    local record = seedLiveCampaignWithItem(9305, 40)
    injectProductionDonation(record, {
        id = "confirm-don", itemId = 9305, quantity = 6,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local rows = logsPage.__sfTest.BuildProjectedRows()
    local row = nil
    for i = 1, #rows do
        if rows[i].id == "confirm-don" then row = rows[i] break end
    end
    assertTrue(row ~= nil, "459: confirm row projected")
    logsPage.__sfTest.OpenEditContributorDialog("confirm-don", row)
    local session = logsPage.__sfTest.GetEditSession()
    session.attributed = "Bob-Garona"
    session.attributedGuid = "Player-1-Bob"
    session.attributionText = "Bob-Garona"
    session.attributionResolved = true

    local savedCb = nil
    local prevConfirm = SF.SettingsUI.Dialogs.Confirm
    SF.SettingsUI.Dialogs.Confirm = function(_, _msg, _btn, onConfirm)
        savedCb = onConfirm
    end
    logsPage.__sfTest.ConfirmAndSaveEdit()
    assertTrue(type(savedCb) == "function", "459: confirm callback captured")
    assertTrue(type(logsPage.__sfTest.GetPendingConfirm()) == "table",
        "459: pending confirm payload set")
    -- Change selection while confirmation is open.
    session.attributed = "Carol-Garona"
    session.attributedGuid = "Player-1-Carol"
    session.attributionText = "Carol-Garona"
    logsPage.__sfTest.InvalidatePendingConfirm()
    local beforeRecords = 0
    for _ in pairs(record.operations.records or {}) do
        beforeRecords = beforeRecords + 1
    end
    savedCb()
    local afterRecords = 0
    for _ in pairs(record.operations.records or {}) do
        afterRecords = afterRecords + 1
    end
    assertEq(afterRecords, beforeRecords,
        "459: stale confirm callback did not commit")
    SF.SettingsUI.Dialogs.Confirm = prevConfirm

    -- Fresh confirm with deferred dialog then successful save.
    logsPage.__sfTest.OpenEditContributorDialog("confirm-don", row)
    session = logsPage.__sfTest.GetEditSession()
    session.attributed = "Bob-Garona"
    session.attributedGuid = "Player-1-Bob"
    session.attributionText = "Bob-Garona"
    session.attributionResolved = true
    local okCb = nil
    SF.SettingsUI.Dialogs.Confirm = function(_, _msg, _btn, onConfirm)
        okCb = onConfirm
    end
    logsPage.__sfTest.ConfirmAndSaveEdit()
    SF.SettingsUI.Dialogs.Confirm = prevConfirm
    okCb()
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "confirm-don"))), "Bob-Garona",
        "459: bound confirm committed Bob")
    logsPage.__sfTest.ClearEditSession()
end

do
    -- Projection cache: unchanged GetCurrentRecord does not rebuild; mutations do.
    local record = seedLiveCampaignWithItem(9306, 40)
    injectProductionDonation(record, {
        id = "cache-don", itemId = 9306, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local rebuilds = 0
    local realRebuild = GS.RebuildCreditCorrectionProjection
    GS.RebuildCreditCorrectionProjection = function(...)
        rebuilds = rebuilds + 1
        return realRebuild(...)
    end
    GS.EnsureCreditCorrectionProjection(record, nil)
    local afterEnsure = rebuilds
    assertTrue(afterEnsure >= 1, "459: first ensure rebuilds")
    for _ = 1, 20 do
        GS:GetCurrentRecord()
        GS.EnsureCreditCorrectionProjection(record, nil)
        GS.ResolveEffectiveCreditIdentity(record, GS.FindLedgerEventById(record, "cache-don"))
    end
    assertEq(rebuilds, afterEnsure,
        "459: unchanged reads reuse projection got rebuilds=" .. tostring(rebuilds))
    local op = select(1, GS:NewContributorCorrectionOperation("cache-don", "Bob-Garona", nil))
    assertEq(GS:ApplyStagedConfigOperation(op), "accepted", "459: mutation invalidates cache")
    local afterMut = rebuilds
    assertTrue(afterMut > afterEnsure, "459: apply rebuilt projection")
    GS.EnsureCreditCorrectionProjection(record, nil)
    assertEq(rebuilds, afterMut, "459: post-mutation ensure hits cache")
    -- Substantial retained history: Ensure remains stamp-gated (not per-read full rebuild).
    for i = 1, 80 do
        injectProductionDonation(record, {
            id = "hist-" .. i, itemId = 9306, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
    end
    GS.InvalidateCreditCorrectionProjection(record)
    local beforeHist = rebuilds
    GS.EnsureCreditCorrectionProjection(record, nil)
    local histRebuilds = rebuilds - beforeHist
    assertEq(histRebuilds, 1, "459: one rebuild after invalidation over history")
    for _ = 1, 10 do
        GS.EnsureCreditCorrectionProjection(record, nil)
    end
    assertEq(rebuilds - beforeHist, 1, "459: history ensure stays cached")
    GS.RebuildCreditCorrectionProjection = realRebuild
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
