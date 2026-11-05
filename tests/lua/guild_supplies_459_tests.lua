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
    -- #459 dependency policy: when an older D1→Bob supports Bob−10, a newer
    -- conflicting D2→Carol must stay inactive (impact prune, not oldest-first).
    -- Opposite timestamp ordering and jointly required heads are covered below.
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
            "459: " .. label .. " Alice nonnegative got "
                .. tostring(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9301)))
        assertTrue(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9301) >= 0,
            "459: " .. label .. " Bob nonnegative got "
                .. tostring(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9301)))
        assertTrue(GS.PersonalContributorItemTotal(record, "Carol-Garona", "Player-1-Carol", 9301) >= 0,
            "459: " .. label .. " Carol nonnegative got "
                .. tostring(GS.PersonalContributorItemTotal(record, "Carol-Garona", "Player-1-Carol", 9301)))
    end

    -- Peer1: older D1→Bob + production Bob−10, then admit newer D2→Carol.
    local peer1 = seedDepPeers()
    world.time = 9000
    local moveD1 = select(1, GS:NewContributorCorrectionOperation(
        "dep-don-1", "Bob-Garona", "Player-1-Bob"))
    assertTrue(moveD1 ~= nil, "459: dep peer1 prepare D1→B")
    assertEq(GS:ApplyStagedConfigOperation(moveD1), "accepted", "459: dep peer1 apply D1→B")
    local cut1 = peer1.liveCutover
    local boundary1 = tonumber(cut1 and cut1.eligibilityBoundary
            and cut1.eligibilityBoundary.tabEligibleFrom)
        or tonumber(cut1 and cut1.contextObservedAt) or world.time
    world.time = math.max(world.time, boundary1) + 50
    local bobAdj, bobAdjSt, bobAdjReason = GS:NewAdjustmentOperation(9301, -10, "Bob-Garona")
    assertTrue(bobAdj ~= nil,
        "459: dep peer1 NewAdjustmentOperation Bob−10 got "
            .. tostring(bobAdjSt) .. "/" .. tostring(bobAdjReason))
    assertEq(GS:ApplyStagedConfigOperation(bobAdj), "accepted",
        "459: dep peer1 apply Bob−10 via production path")
    assertEq(GS.PersonalContributorItemTotal(peer1, "Bob-Garona", "Player-1-Bob", 9301), 0,
        "459: Bob spent corrected credit to zero")
    local snapD1 = select(1, GS._SnapshotPublicOp(moveD1))
    local snapBobAdj = select(1, GS._SnapshotPublicOp(bobAdj))

    local peer2 = seedDepPeers()
    world.time = 9500 -- newer than D1→Bob
    local moveD2 = select(1, GS:NewContributorCorrectionOperation(
        "dep-don-2", "Carol-Garona", "Player-1-Carol"))
    assertTrue(moveD2 ~= nil, "459: dep peer2 prepare D2→C")
    assertEq(GS:ApplyStagedConfigOperation(moveD2), "accepted", "459: dep peer2 apply D2→C")
    local snapD2 = select(1, GS._SnapshotPublicOp(moveD2))
    assertTrue((tonumber(snapD2.timestamp) or 0) > (tonumber(snapD1.timestamp) or 0),
        "459: D2→C is newer than D1→B")

    local bodyD2 = rebase(snapD2, peer1)
    assertEq(select(1, GS:AdmitRemoteOperation(bodyD2, {
        sender = "Alice-Garona", offlineRecord = peer1, preserveAttribution = true,
    })), "accepted", "459: peer1 admits newer D2→C")
    GS.EnsureCreditCorrectionProjection(peer1, nil)
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peer1, GS.FindLedgerEventById(peer1, "dep-don-1"))), "Bob-Garona",
        "459: D1→B stays active after newer D2→C")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peer1, GS.FindLedgerEventById(peer1, "dep-don-2"))), "Alice-Garona",
        "459: newer D2→C inactive when it would break Bob floor")
    assertAllNonNeg(peer1, "peer1-after-newer-D2")
    assertEq(GS.PersonalContributorItemTotal(peer1, "Bob-Garona", "Player-1-Bob", 9301), 0,
        "459: Bob stays 0 (not −10) after newer D2→C")
    assertTrue(peer1.operations.records[snapD2.id] ~= nil,
        "459: newer D2 evidence retained accepted")
    -- Reload / cold rebuild preserves the same active set.
    GS.InvalidateCreditCorrectionProjection(peer1)
    assertTrue(select(1, GS.RebuildCreditCorrectionProjection(peer1, nil)),
        "459: peer1 cold rebuild succeeds (nonnegative)")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peer1, GS.FindLedgerEventById(peer1, "dep-don-1"))), "Bob-Garona",
        "459: cold rebuild keeps D1→B")
    assertAllNonNeg(peer1, "peer1-cold")

    -- Opposite ordering: older D2→C first, then admit D1→B; prune leaves D1
    -- active; production Bob−10 (same qty/attribution history) keeps floors.
    local peer2b = seedDepPeers()
    world.time = 8500
    local moveD2old = select(1, GS:NewContributorCorrectionOperation(
        "dep-don-2", "Carol-Garona", "Player-1-Carol"))
    assertEq(GS:ApplyStagedConfigOperation(moveD2old), "accepted",
        "459: peer2b apply older D2→C")
    local snapD2old = select(1, GS._SnapshotPublicOp(moveD2old))
    local bodyD1b = rebase(snapD1, peer2b)
    assertEq(select(1, GS:AdmitRemoteOperation(bodyD1b, {
        sender = "Alice-Garona", offlineRecord = peer2b, preserveAttribution = true,
    })), "accepted", "459: peer2b admits D1→B")
    GS.EnsureCreditCorrectionProjection(peer2b, nil)
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peer2b, GS.FindLedgerEventById(peer2b, "dep-don-1"))), "Bob-Garona",
        "459: reverse order keeps D1→B active before Bob−10")
    local cut2 = peer2b.liveCutover
    local boundary2 = tonumber(cut2 and cut2.eligibilityBoundary
            and cut2.eligibilityBoundary.tabEligibleFrom)
        or tonumber(cut2 and cut2.contextObservedAt) or world.time
    world.time = math.max(world.time, boundary2) + 50
    local bobAdj2 = select(1, GS:NewAdjustmentOperation(9301, -10, "Bob-Garona"))
    assertTrue(bobAdj2 ~= nil, "459: peer2b prepares Bob−10")
    assertEq(GS:ApplyStagedConfigOperation(bobAdj2), "accepted",
        "459: peer2b applies Bob−10 via production path")
    assertAllNonNeg(peer2b, "peer2b-reverse")
    assertEq(GS.PersonalContributorItemTotal(peer2b, "Bob-Garona", "Player-1-Bob", 9301), 0,
        "459: peer2b Bob 0 after same transferred history")
    assertTrue(peer2b.operations.records[snapD2old.id] ~= nil,
        "459: peer2b retains older D2 accepted")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peer2b, GS.FindLedgerEventById(peer2b, "dep-don-2"))), "Alice-Garona",
        "459: older D2 inactive under Bob deduction dependency")
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
    -- Deletion-safe continuation: 64 eligible pending with budget 32 must all be
    -- attempted across scheduled slices (no stranded middle when accepts shrink).
    local function seedPendingWave(count, itemId)
        local record = seedLiveCampaignWithItem(itemId, 500)
        record.operations.pending = record.operations.pending or {}
        local ctx = select(1, GS:GetCurrentContext())
        for i = 1, count do
            local donId = string.format("budget-don-%03d", i)
            injectProductionDonation(record, {
                id = donId, itemId = itemId, quantity = 2,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
                timestamp = world.time + i,
            })
            local id = string.format("budget-corr-%03d", i)
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
                    kind = GS.KIND.CORRECT_CONTRIBUTOR,
                    target = donId,
                    value = {
                        eventId = donId,
                        eventKind = "donation",
                        attributed = "Bob-Garona",
                        attributedGuid = "Player-1-Bob",
                        baseAttributed = "Alice-Garona",
                        baseAttributedGuid = "Player-1-Alice",
                        itemId = itemId,
                    },
                    actorGuid = "Player-1-Alice",
                    actorName = "Alice-Garona",
                    timestamp = world.time + 1000 + i,
                    baseTargetRevision = record.datasetId,
                    basePolicyRevision = record.permission and record.permission.revisionId,
                    baseCampaignId = record.currentCampaignId,
                },
            }
        end
        return record
    end
    local function countEligiblePending(record)
        local n = 0
        for _, entry in pairs(record.operations.pending or {}) do
            local body = entry and entry.body
            if type(body) == "table"
                and body.kind == GS.KIND.CORRECT_CONTRIBUTOR
                and entry.reason ~= "untrusted_relay"
                and entry.reason ~= "evidence"
                and type(entry.sender) == "string" then
                n = n + 1
            end
        end
        return n
    end
    local record64 = seedPendingWave(64, 9304)
    local _, attempts64 = GS.RedrivePendingContributorCorrections(record64, {
        maxAttempts = 32,
        workBudget = 1000000,
    })
    assertEq(attempts64, 32, "459: 64-wave first slice attempts=32 got " .. tostring(attempts64))
    assertTrue(#timers >= 1, "459: 64-wave schedules continuation")
    flushTimers()
    assertEq(countEligiblePending(record64), 0,
        "459: 64 eligible pending all settled after slices got "
            .. tostring(countEligiblePending(record64)))

    -- 80 entries: middle slice must not be skipped after first 32 accepts.
    local record80 = seedPendingWave(80, 9307)
    GS.RedrivePendingContributorCorrections(record80, { maxAttempts = 32, workBudget = 1000000 })
    flushTimers()
    assertEq(countEligiblePending(record80), 0,
        "459: 80 eligible pending all settled after slices got "
            .. tostring(countEligiblePending(record80)))

    -- Mixed outcomes: failures stay until wave completes; successes remove mid-wave.
    local recordMix = seedPendingWave(40, 9308)
    -- Poison half with missing sender so attempts count but leave pending.
    local mixIds = {}
    for id in pairs(recordMix.operations.pending) do
        mixIds[#mixIds + 1] = id
    end
    table.sort(mixIds)
    for i = 1, 20 do
        recordMix.operations.pending[mixIds[i]].sender = nil
    end
    GS.RedrivePendingContributorCorrections(recordMix, { maxAttempts = 32 })
    flushTimers()
    local left = countEligiblePending(recordMix)
    -- Entries without sender are not "eligible" under countEligiblePending.
    assertEq(left, 0, "459: mixed wave settles sender-bearing entries got " .. tostring(left))
    local noSenderLeft = 0
    for _, entry in pairs(recordMix.operations.pending or {}) do
        if entry and entry.sender == nil then
            noSenderLeft = noSenderLeft + 1
        end
    end
    assertEq(noSenderLeft, 20, "459: mixed wave retains no-sender pending for later wake")
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

do
    -- Joint-activation: two +10→Bob then production Bob −15 keeps Bob at 5.
    local record = seedLiveCampaignWithItem(9310, 100)
    local cut = record.liveCutover
    local boundary = tonumber(cut and cut.eligibilityBoundary and cut.eligibilityBoundary.tabEligibleFrom)
        or tonumber(cut and cut.contextObservedAt) or world.time
    local t0 = boundary + 100
    injectProductionDonation(record, {
        id = "joint-don-1", itemId = 9310, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = t0,
    })
    injectProductionDonation(record, {
        id = "joint-don-2", itemId = 9310, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = t0 + 1,
    })
    world.time = t0 + 10
    local c1 = select(1, GS:NewContributorCorrectionOperation(
        "joint-don-1", "Bob-Garona", "Player-1-Bob"))
    local c2 = select(1, GS:NewContributorCorrectionOperation(
        "joint-don-2", "Bob-Garona", "Player-1-Bob"))
    assertTrue(c1 and c2, "459: joint prepare both corrections")
    assertEq(GS:ApplyStagedConfigOperation(c1), "accepted", "459: joint apply don1→Bob")
    assertEq(GS:ApplyStagedConfigOperation(c2), "accepted", "459: joint apply don2→Bob")
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9310), 20,
        "459: Bob has 20 before adjustment")
    local itemBefore = 0
    if GS.ProjectCampaignProgressOnRecord then
        local prog = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
        itemBefore = tonumber(prog and prog.itemTotals and prog.itemTotals[9310]) or 0
    end
    world.time = t0 + 20
    local adjOp, adjSt, adjReason = GS:NewAdjustmentOperation(9310, -15, "Bob-Garona")
    assertTrue(adjOp ~= nil,
        "459: joint NewAdjustmentOperation prepared got " .. tostring(adjSt) .. "/" .. tostring(adjReason))
    assertEq(GS:ApplyStagedConfigOperation(adjOp), "accepted",
        "459: joint Bob −15 via production ApplyStagedConfigOperation")
    do
        local adjEv = GS.FindLedgerEventById(record, adjOp.id)
        assertTrue(adjEv ~= nil, "459: joint adjustment ledger row present")
        assertEq(adjEv.gsProductionCredit, true, "459: joint adjustment production-credited")
    end
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9310), 5,
        "459: Bob personal 5 after joint reconstruction")
    assertEq(GS.PersonalContributorItemTotal(record, "Alice-Garona", "Player-1-Alice", 9310), 0,
        "459: Alice personal 0 after joint reconstruction")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "joint-don-1"))), "Bob-Garona",
        "459: joint don1 stays Bob")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "joint-don-2"))), "Bob-Garona",
        "459: joint don2 stays Bob")
    if GS.ProjectCampaignProgressOnRecord then
        local prog = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
        local itemAfter = tonumber(prog and prog.itemTotals and prog.itemTotals[9310]) or 0
        assertEq(itemAfter, itemBefore - 15, "459: campaign item total moves only by adjustment qty")
    end
    -- Durable evidence unchanged.
    local d1 = GS.FindLedgerEventById(record, "joint-don-1")
    assertEq(d1.actor, "Alice-Garona", "459: joint durable actor unchanged")
    assertEq(tonumber(d1.quantity), 10, "459: joint durable qty unchanged")

    -- Reload-style: wipe projection and rebuild from accepted ops alone.
    record.creditCorrections = nil
    GS.InvalidateCreditCorrectionProjection(record)
    GS.EnsureCreditCorrectionProjection(record, nil)
    assertEq(GS.PersonalContributorItemTotal(record, "Bob-Garona", "Player-1-Bob", 9310), 5,
        "459: joint Bob 5 after cold rebuild")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, d1)), "Bob-Garona",
        "459: joint cold rebuild keeps Bob")

    -- Peer delivery: apply corrections then remote-admit the adjustment snapshot.
    local peer = seedLiveCampaignWithItem(9310, 100)
    injectProductionDonation(peer, {
        id = "joint-don-1", itemId = 9310, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = t0,
    })
    injectProductionDonation(peer, {
        id = "joint-don-2", itemId = 9310, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = t0 + 1,
    })
    local snapC1 = select(1, GS._SnapshotPublicOp(c1))
    local snapC2 = select(1, GS._SnapshotPublicOp(c2))
    local snapAdj = select(1, GS._SnapshotPublicOp(adjOp))
    local function rebaseJoint(snap, rec)
        local body = {}
        for k, v in pairs(snap) do body[k] = v end
        body.guildKey = select(1, GS:GetCurrentContext()).guildKey
        body.datasetId = rec.datasetId
        body.campaignId = rec.currentCampaignId
        body.baseCampaignId = rec.currentCampaignId
        body.basePolicyRevision = rec.permission and rec.permission.revisionId
        if body.kind == GS.KIND.CORRECT_CONTRIBUTOR then
            body.baseTargetRevision = rec.datasetId
        end
        return body
    end
    assertEq(select(1, GS:AdmitRemoteOperation(rebaseJoint(snapC1, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })), "accepted", "459: peer admits joint c1")
    assertEq(select(1, GS:AdmitRemoteOperation(rebaseJoint(snapC2, peer), {
        sender = "Alice-Garona", offlineRecord = peer, preserveAttribution = true,
    })), "accepted", "459: peer admits joint c2")
    -- Deliver the same durable adjustment ledger event under matching cutover
    -- provenance (#389 A2). Remote unmarked gs-op bodies do not self-credit.
    local authorAdjEv = GS.FindLedgerEventById(record, adjOp.id)
    assertTrue(authorAdjEv ~= nil and authorAdjEv.gsProductionCredit == true,
        "459: author adjustment ledger row credited")
    assertTrue(type(record.liveCutover) == "table"
        and type(record.liveCutover.cutoverMarker) == "string",
        "459: author cutover marker present")
    -- Same-dataset peer: share the author cutover marker + boundary so the
    -- marked ledger event classifies as production credit.
    peer.liveCutover = peer.liveCutover or {}
    for k, v in pairs(record.liveCutover) do
        peer.liveCutover[k] = v
    end
    local adjWire = {}
    for k, v in pairs(authorAdjEv) do
        adjWire[k] = v
    end
    adjWire.campaignId = peer.currentCampaignId
    adjWire.datasetId = peer.datasetId
    local stLe, rLe = GS:AdmitLedgerEvent(adjWire, {
        member = { guid = "Player-1-Alice", name = "Alice-Garona",
            guildKey = select(1, GS:GetCurrentContext()).guildKey, rankOrder = 1 },
        offlineRecord = peer,
        localWrite = false,
        preserveAttribution = true,
        sourceCutoverMarker = record.liveCutover.cutoverMarker,
    })
    assertEq(stLe, "accepted",
        "459: peer admits same Bob −15 ledger history got "
            .. tostring(stLe) .. "/" .. tostring(rLe))
    local peerAdjEv = GS.FindLedgerEventById(peer, adjOp.id)
    assertTrue(peerAdjEv ~= nil, "459: peer retained same adjustment event id")
    assertEq(peerAdjEv.gsProductionCredit, true,
        "459: peer adjustment production-credited under shared cutover")
    assertEq(tonumber(peerAdjEv.quantity), -15, "459: peer adjustment qty −15")
    assertEq(peerAdjEv.attributed, "Bob-Garona", "459: peer adjustment attributed Bob")
    assertEq(GS.PersonalContributorItemTotal(peer, "Bob-Garona", "Player-1-Bob", 9310), 5,
        "459: peer Bob 5 after same transferred joint history")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peer, GS.FindLedgerEventById(peer, "joint-don-1"))), "Bob-Garona",
        "459: peer joint don1 stays Bob")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peer, GS.FindLedgerEventById(peer, "joint-don-2"))), "Bob-Garona",
        "459: peer joint don2 stays Bob")
end

do
    -- Remote cutover classification wakes pending not_credited corrections.
    local record = seedLiveCampaignWithItem(9311, 40)
    local cutover = record.liveCutover
    assertTrue(type(cutover) == "table" and type(cutover.cutoverMarker) == "string",
        "459: cutover fixture present")
    local boundary = tonumber(cutover.eligibilityBoundary and cutover.eligibilityBoundary.tabEligibleFrom)
        or tonumber(cutover.contextObservedAt) or world.time
    local don = injectProductionDonation(record, {
        id = "cutover-don", itemId = 9311, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        timestamp = boundary + 50,
    })
    don.approxTxnTime = boundary + 50
    don.gsProductionCredit = false
    don.gsSourceCutoverMarker = cutover.cutoverMarker
    local pendingOp = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "cutover-corr",
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "cutover-don",
        value = {
            eventId = "cutover-don",
            eventKind = "donation",
            attributed = "Bob-Garona",
            attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona",
            baseAttributedGuid = "Player-1-Alice",
            itemId = 9311,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    local stP = select(1, GS:AdmitRemoteOperation(pendingOp, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    }))
    assertEq(stP, "pending", "459: cutover correction pending before credit got " .. tostring(stP))
    -- Demote to staged so InstallRemoteLiveCutover reclassifies.
    local savedCutover = {}
    for k, v in pairs(cutover) do
        savedCutover[k] = v
    end
    record.activation = GS.ACTIVATION_STAGED
    record.liveCutover = nil
    local stCut = GS.InstallRemoteLiveCutover(record, savedCutover, select(1, GS:GetCurrentContext()).guildKey, {
        quarantinePending = false,
        forceActive = true,
    })
    assertTrue(stCut == "accepted" or stCut == "duplicate",
        "459: InstallRemoteLiveCutover status " .. tostring(stCut))
    flushTimers()
    assertEq(don.gsProductionCredit, true, "459: cutover classified donation credited")
    assertTrue(record.operations.records["cutover-corr"] ~= nil,
        "459: cutover wake promoted pending correction")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Bob-Garona",
        "459: credit after cutover wake")
end

do
    -- Bounded projection work: row visits stay O(ledger + corrections), not product.
    local record = seedLiveCampaignWithItem(9312, 200)
    local nDon = 120
    local nCorr = 40
    for i = 1, nDon do
        injectProductionDonation(record, {
            id = string.format("bound-don-%03d", i),
            itemId = 9312, quantity = 2,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
    end
    for i = 1, nCorr do
        local donId = string.format("bound-don-%03d", i)
        local op = select(1, GS:NewContributorCorrectionOperation(
            donId, "Bob-Garona", "Player-1-Bob"))
        assertTrue(op ~= nil, "459: bound prepare corr " .. tostring(i))
        assertEq(GS:ApplyStagedConfigOperation(op), "accepted",
            "459: bound apply corr " .. tostring(i))
    end
    GS.InvalidateCreditCorrectionProjection(record)
    local ok, err, details = GS.RebuildCreditCorrectionProjection(record, nil)
    assertTrue(ok, "459: bound rebuild ok got " .. tostring(err))
    local visits = tonumber(details and details.rowVisits) or tonumber(GS._creditProjectionRowVisits) or 0
    -- One baseline scan of live(+archive) rows (+ registry); must not approach
    -- corrections×ledger.
    local ledgerRows = #(record.accounting._consumableEvents or {})
    local registryRows = #(record.accounting._consumables.txnRegistry or {})
    assertTrue(visits <= ledgerRows + registryRows + 8,
        "459: rebuild row visits near ledger+registry size visits=" .. tostring(visits)
            .. " ledger=" .. tostring(ledgerRows))
    local product = nCorr * ledgerRows
    assertTrue(visits * 20 < product,
        "459: visits far below corrections×ledger product=" .. tostring(product)
            .. " visits=" .. tostring(visits))
    assertEq(tonumber(details and details.lookupMisses) or 0, 0,
        "459: exact-id rebuild has zero alias lookup misses")
end

do
    -- Interleaved A/B/C wakes while A's snapshot drains: B must settle.
    local itemA, itemB, itemC = 9313, 9314, 9315
    local record = seedLiveCampaignWithItem(itemA, 500)
    -- Add B and C campaign items so donations can credit.
    local camp = record.campaigns and record.campaigns[record.currentCampaignId]
    if type(camp) == "table" and type(camp.items) == "table" then
        camp.items[itemB] = { itemId = itemB, needed = 500, received = 0 }
        camp.items[itemC] = { itemId = itemC, needed = 500, received = 0 }
    end
    record.operations.pending = record.operations.pending or {}
    local ctx = select(1, GS:GetCurrentContext())
    local function plantPending(itemId, count, prefix)
        for i = 1, count do
            local donId = string.format("%s-don-%03d", prefix, i)
            injectProductionDonation(record, {
                id = donId, itemId = itemId, quantity = 1,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
                timestamp = world.time + i,
            })
            local id = string.format("%s-corr-%03d", prefix, i)
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
                    kind = GS.KIND.CORRECT_CONTRIBUTOR,
                    target = donId,
                    value = {
                        eventId = donId,
                        eventKind = "donation",
                        attributed = "Bob-Garona",
                        attributedGuid = "Player-1-Bob",
                        baseAttributed = "Alice-Garona",
                        baseAttributedGuid = "Player-1-Alice",
                        itemId = itemId,
                    },
                    actorGuid = "Player-1-Alice",
                    actorName = "Alice-Garona",
                    timestamp = world.time + 2000 + i,
                    baseTargetRevision = record.datasetId,
                    basePolicyRevision = record.permission and record.permission.revisionId,
                    baseCampaignId = record.currentCampaignId,
                },
            }
        end
    end
    plantPending(itemA, 64, "ia")
    -- B held: donation missing until mid-wave.
    local bDonId = "ib-don-001"
    local bCorrId = "ib-corr-001"
    record.operations.pending[bCorrId] = {
        id = bCorrId,
        sender = "Alice-Garona",
        reason = "pending_event",
        body = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = bCorrId,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = bDonId,
            value = {
                eventId = bDonId,
                eventKind = "donation",
                attributed = "Bob-Garona",
                attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona",
                baseAttributedGuid = "Player-1-Alice",
                itemId = itemB,
            },
            actorGuid = "Player-1-Alice",
            actorName = "Alice-Garona",
            timestamp = world.time + 3000,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        },
    }
    plantPending(itemC, 1, "ic")

    -- (1) Item-A wake processes 32 and schedules continuation.
    local _, attemptsA = GS.RedrivePendingContributorCorrections(record, {
        itemId = itemA, maxAttempts = 32, workBudget = 1000000,
    })
    assertEq(attemptsA, 32, "459: A/B/C first A slice attempts=32")
    assertTrue(#timers >= 1, "459: A/B/C schedules continuation after A slice")

    -- (2) Missing B donation arrives; production-style append wake while A drains.
    -- (Missing-event block below also exercises AdmitLedgerEvent recovery.)
    injectProductionDonation(record, {
        id = bDonId, itemId = itemB, quantity = 1,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        timestamp = world.time + 4000,
    })
    GS.RedrivePendingContributorCorrections(record, {
        itemId = itemB, eventId = bDonId, maxAttempts = 32,
    })

    -- (3) Unrelated C append wake before the queued timer.
    GS.RedrivePendingContributorCorrections(record, {
        itemId = itemC, maxAttempts = 32,
    })

    flushTimers()
    assertTrue(record.operations.records[bCorrId] ~= nil,
        "459: A/B/C interleaved wake accepts B correction")
    assertTrue(record.operations.pending[bCorrId] == nil,
        "459: A/B/C B not left pending after drain")
    -- No redelivery: B accepted exactly once.
    assertEq(record.operations.heads[GS.CorrectionTargetKey(record, bDonId)], bCorrId,
        "459: A/B/C B head bound once")
end

do
    -- Alias-heavy retained history: rebuild via production append/retry must not
    -- pay corrections×ledger FindLedgerEventById scans.
    local record = seedLiveCampaignWithItem(9316, 300)
    local n = 50
    local cfg = record.accounting._consumables
    cfg.txnRegistry = cfg.txnRegistry or {}
    for i = 1, n do
        local canon = string.format("ctx:alias-canon-%03d", i)
        local alias = string.format("ctx:alias-peer-%03d", i)
        local don = injectProductionDonation(record, {
            id = canon, itemId = 9316, quantity = 2,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
        don.txnId = canon
        cfg.txnRegistry[#cfg.txnRegistry + 1] = {
            txnId = canon,
            status = "verified",
            committed = true,
            aliases = { alias },
            itemId = 9316,
            quantity = 2,
            donor = "Alice-Garona",
            approxTxnTime = world.time + i,
        }
        cfg.txnRegistry[#cfg.txnRegistry + 1] = {
            txnId = alias,
            status = "alias",
            aliasOf = canon,
            committed = true,
            itemId = 9316,
            quantity = 2,
        }
        -- Retain a losing revision targeted at the immutable alias id, then the
        -- winning correction also targeted at the alias (two-peer catch-up path).
        local loseId = string.format("alias-lose-%03d", i)
        local winId = string.format("alias-win-%03d", i)
        local ctx = select(1, GS:GetCurrentContext())
        local function makeCorr(id, ts, attributed)
            return {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = id,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = alias,
                value = {
                    eventId = alias,
                    eventKind = "donation",
                    attributed = attributed,
                    attributedGuid = attributed == "Bob-Garona" and "Player-1-Bob" or "Player-1-Carol",
                    baseAttributed = "Alice-Garona",
                    baseAttributedGuid = "Player-1-Alice",
                    itemId = 9316,
                },
                actorGuid = "Player-1-Alice",
                actorName = "Alice-Garona",
                timestamp = ts,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
        end
        assertEq(select(1, GS:AdmitRemoteOperation(makeCorr(loseId, world.time + 100 + i, "Carol-Garona"), {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })), "accepted", "459: alias lose admit " .. tostring(i))
        assertEq(select(1, GS:AdmitRemoteOperation(makeCorr(winId, world.time + 500 + i, "Bob-Garona"), {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })), "accepted", "459: alias win admit " .. tostring(i))
    end
    -- Production append callback: measure visits across Invalidate+Ensure+Redrive.
    GS._creditProjectionRowVisits = 0
    GS._creditProjectionLookupMisses = 0
    local beforeTimers = #timers
    injectProductionDonation(record, {
        id = "alias-measure-extra", itemId = 9316, quantity = 1,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        timestamp = world.time + 9000,
    })
    -- inject bypasses AppendLedgerEvent; exercise the same Invalidate/Ensure/Redrive chain.
    if GS.InvalidateCreditCorrectionProjection then
        GS.InvalidateCreditCorrectionProjection(record)
    end
    local okA, errA, detA = GS.EnsureCreditCorrectionProjection(record, nil)
    assertTrue(okA, "459: alias-heavy ensure ok got " .. tostring(errA))
    GS.RedrivePendingContributorCorrections(record, { itemId = 9316, maxAttempts = 32 })
    flushTimers()
    local visits = tonumber(detA and detA.rowVisits) or tonumber(GS._creditProjectionRowVisits) or 0
    local misses = tonumber(detA and detA.lookupMisses) or tonumber(GS._creditProjectionLookupMisses) or 0
    local ledgerRows = #(record.accounting._consumableEvents or {})
    local registryRows = #(cfg.txnRegistry or {})
    local corrCount = 0
    for _ in pairs(record.operations.records or {}) do
        corrCount = corrCount + 1
    end
    assertEq(misses, 0,
        "459: alias-heavy lookupMisses=0 got " .. tostring(misses))
    -- Ledger rows + registry rows + alias slot visits (still linear, not N²).
    assertTrue(visits <= ledgerRows + registryRows + n + 16,
        "459: alias-heavy visits O(ledger+registry+aliases) visits=" .. tostring(visits)
            .. " ledger=" .. tostring(ledgerRows) .. " reg=" .. tostring(registryRows))
    local product = corrCount * ledgerRows
    assertTrue(product > 0 and visits * 10 < product,
        "459: alias-heavy visits far below corrections×ledger product="
            .. tostring(product) .. " visits=" .. tostring(visits))
    -- Nested registry probes must not approach ledger×registry comparisons.
    local nestedProduct = ledgerRows * registryRows
    assertTrue(visits * 20 < nestedProduct,
        "459: visits far below ledger×registry nestedProduct="
            .. tostring(nestedProduct) .. " visits=" .. tostring(visits))
    assertTrue(beforeTimers >= 0, "459: alias-heavy measured production ensure/redrive path")
end

do
    -- Delayed marked-ledger duplicate on item X, plus independent item-Y
    -- deduction-supporting correction that must survive X's empty-set fallback.
    local ITEM_X, ITEM_Y = 9320, 9325
    local function seedMutualBase()
        local record = seedLiveCampaignWithItem(ITEM_X, 200)
        local yOp = select(1, GS:NewConfigOperation("set-requested-item", { itemId = ITEM_Y }, {
            itemId = ITEM_Y, goal = 100, removed = false,
        }))
        assertEq(GS:ApplyStagedConfigOperation(yOp), "accepted", "459: mutual add item Y")
        injectProductionDonation(record, {
            id = "mut-don-alice", itemId = ITEM_X, quantity = 10,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = 10000,
        })
        injectProductionDonation(record, {
            id = "mut-don-bob", itemId = ITEM_X, quantity = 20,
            actor = "Bob-Garona", actorGuid = "Player-1-Bob", timestamp = 10001,
        })
        return record
    end
    local function rebaseMut(snap, rec)
        local body = {}
        for k, v in pairs(snap) do body[k] = v end
        body.guildKey = select(1, GS:GetCurrentContext()).guildKey
        body.datasetId = rec.datasetId
        body.campaignId = rec.currentCampaignId
        body.baseCampaignId = rec.currentCampaignId
        body.basePolicyRevision = rec.permission and rec.permission.revisionId
        if body.kind == GS.KIND.CORRECT_CONTRIBUTOR then
            body.baseTargetRevision = rec.datasetId
        end
        return body
    end

    -- Peer Q: Bob→Alice then Alice −10 on X.
    local peerQ = seedMutualBase()
    world.time = 11000
    local qCorr = select(1, GS:NewContributorCorrectionOperation(
        "mut-don-bob", "Alice-Garona", "Player-1-Alice"))
    assertTrue(qCorr ~= nil, "459: mutual Q prepare Bob→Alice")
    assertEq(GS:ApplyStagedConfigOperation(qCorr), "accepted", "459: mutual Q apply Bob→Alice")
    local qCut = peerQ.liveCutover
    local qBound = tonumber(qCut and qCut.eligibilityBoundary
            and qCut.eligibilityBoundary.tabEligibleFrom)
        or tonumber(qCut and qCut.contextObservedAt) or world.time
    world.time = math.max(world.time, qBound) + 40
    local qAdj = select(1, GS:NewAdjustmentOperation(ITEM_X, -10, "Alice-Garona"))
    assertTrue(qAdj ~= nil, "459: mutual Q prepare Alice−10")
    assertEq(GS:ApplyStagedConfigOperation(qAdj), "accepted", "459: mutual Q apply Alice−10")
    local snapQCorr = select(1, GS._SnapshotPublicOp(qCorr))
    local snapQAdj = select(1, GS._SnapshotPublicOp(qAdj))
    local qAdjEv = GS.FindLedgerEventById(peerQ, qAdj.id)
    assertTrue(qAdjEv and qAdjEv.gsProductionCredit == true, "459: mutual Q adj credited")

    -- Peer P: independent Y history (Alice→Carol + Carol−10) before X conflict.
    local peerP = seedMutualBase()
    injectProductionDonation(peerP, {
        id = "mut-don-y", itemId = ITEM_Y, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice", timestamp = 10002,
    })
    world.time = 10500
    local yCorr = select(1, GS:NewContributorCorrectionOperation(
        "mut-don-y", "Carol-Garona", "Player-1-Carol"))
    assertTrue(yCorr ~= nil, "459: mutual P prepare Y Alice→Carol")
    assertEq(GS:ApplyStagedConfigOperation(yCorr), "accepted", "459: mutual P apply Y Alice→Carol")
    local yCut = peerP.liveCutover
    local yBound = tonumber(yCut and yCut.eligibilityBoundary
            and yCut.eligibilityBoundary.tabEligibleFrom)
        or tonumber(yCut and yCut.contextObservedAt) or world.time
    world.time = math.max(world.time, yBound) + 40
    local yAdj = select(1, GS:NewAdjustmentOperation(ITEM_Y, -10, "Carol-Garona"))
    assertTrue(yAdj ~= nil, "459: mutual P prepare Carol−10")
    assertEq(GS:ApplyStagedConfigOperation(yAdj), "accepted", "459: mutual P apply Carol−10")
    assertEq(GS.PersonalContributorItemTotal(peerP, "Alice-Garona", "Player-1-Alice", ITEM_Y), 0,
        "459: mutual Y Alice 0 after Carol correction")
    assertEq(GS.PersonalContributorItemTotal(peerP, "Carol-Garona", "Player-1-Carol", ITEM_Y), 0,
        "459: mutual Y Carol 0 after Carol−10")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peerP, GS.FindLedgerEventById(peerP, "mut-don-y"))), "Carol-Garona",
        "459: mutual Y head active before X conflict")

    local stQAdjOp = select(1, GS:AdmitRemoteOperation(rebaseMut(snapQAdj, peerP), {
        sender = "Alice-Garona", offlineRecord = peerP, preserveAttribution = true,
    }))
    assertTrue(stQAdjOp == "accepted" or stQAdjOp == "pending" or stQAdjOp == "duplicate",
        "459: mutual P admits unmarked Alice−10 op got " .. tostring(stQAdjOp))
    local earlyAdj = GS.FindLedgerEventById(peerP, qAdj.id)
    if earlyAdj then
        assertTrue(earlyAdj.gsProductionCredit ~= true,
            "459: mutual P Alice−10 stays uncredited before marked ledger")
    end
    world.time = 12000
    local pCorr = select(1, GS:NewContributorCorrectionOperation(
        "mut-don-alice", "Bob-Garona", "Player-1-Bob"))
    assertTrue(pCorr ~= nil, "459: mutual P prepare Alice→Bob")
    assertEq(GS:ApplyStagedConfigOperation(pCorr), "accepted", "459: mutual P apply Alice→Bob")
    local pCut = peerP.liveCutover
    local pBound = tonumber(pCut and pCut.eligibilityBoundary
            and pCut.eligibilityBoundary.tabEligibleFrom)
        or tonumber(pCut and pCut.contextObservedAt) or world.time
    world.time = math.max(world.time, pBound) + 40
    local pAdj = select(1, GS:NewAdjustmentOperation(ITEM_X, -20, "Bob-Garona"))
    assertTrue(pAdj ~= nil, "459: mutual P prepare Bob−20")
    assertEq(GS:ApplyStagedConfigOperation(pAdj), "accepted", "459: mutual P apply Bob−20")
    assertEq(GS.PersonalContributorItemTotal(peerP, "Alice-Garona", "Player-1-Alice", ITEM_X), 0,
        "459: mutual P Alice 0 before Q correction")
    assertEq(GS.PersonalContributorItemTotal(peerP, "Bob-Garona", "Player-1-Bob", ITEM_X), 10,
        "459: mutual P Bob 10 before Q correction")

    assertEq(select(1, GS:AdmitRemoteOperation(rebaseMut(snapQCorr, peerP), {
        sender = "Alice-Garona", offlineRecord = peerP, preserveAttribution = true,
    })), "accepted", "459: mutual P admits Bob→Alice correction")

    assertTrue(type(peerP.liveCutover) == "table", "459: mutual P has liveCutover")
    peerP.liveCutover.cutoverMarker = peerQ.liveCutover.cutoverMarker
    if type(peerQ.liveCutover.eligibilityBoundary) == "table" then
        peerP.liveCutover.eligibilityBoundary = peerP.liveCutover.eligibilityBoundary or {}
        for k, v in pairs(peerQ.liveCutover.eligibilityBoundary) do
            peerP.liveCutover.eligibilityBoundary[k] = v
        end
    end
    local adjWire = {}
    for k, v in pairs(qAdjEv) do
        adjWire[k] = v
    end
    adjWire.campaignId = peerP.currentCampaignId
    adjWire.datasetId = peerP.datasetId
    local stLe, rLe = GS:AdmitLedgerEvent(adjWire, {
        member = { guid = "Player-1-Alice", name = "Alice-Garona",
            guildKey = select(1, GS:GetCurrentContext()).guildKey, rankOrder = 1 },
        offlineRecord = peerP,
        localWrite = false,
        preserveAttribution = true,
        sourceCutoverMarker = peerQ.liveCutover.cutoverMarker,
    })
    assertTrue(stLe == "accepted" or stLe == "duplicate",
        "459: mutual P marked Alice−10 ledger got " .. tostring(stLe) .. "/" .. tostring(rLe))
    local creditedAdj = GS.FindLedgerEventById(peerP, qAdj.id)
    assertTrue(creditedAdj and creditedAdj.gsProductionCredit == true,
        "459: mutual P Alice−10 production-credited after marked duplicate")

    GS.InvalidateCreditCorrectionProjection(peerP)
    local okMut, errMut = GS.RebuildCreditCorrectionProjection(peerP, nil)
    assertTrue(okMut, "459: mutual rebuild succeeds got " .. tostring(errMut))
    assertEq(GS.PersonalContributorItemTotal(peerP, "Alice-Garona", "Player-1-Alice", ITEM_X), 0,
        "459: mutual final Alice 0 on X")
    assertEq(GS.PersonalContributorItemTotal(peerP, "Bob-Garona", "Player-1-Bob", ITEM_X), 0,
        "459: mutual final Bob 0 on X")
    -- X heads inactive; independent Y deduction-supporting head preserved.
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peerP, GS.FindLedgerEventById(peerP, "mut-don-alice"))), "Alice-Garona",
        "459: mutual Alice donation durable after X empty")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peerP, GS.FindLedgerEventById(peerP, "mut-don-bob"))), "Bob-Garona",
        "459: mutual Bob donation durable after X empty")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peerP, GS.FindLedgerEventById(peerP, "mut-don-y"))), "Carol-Garona",
        "459: mutual Y Carol head kept after X empty-set")
    assertEq(GS.PersonalContributorItemTotal(peerP, "Alice-Garona", "Player-1-Alice", ITEM_Y), 0,
        "459: mutual Y Alice 0 after X conflict")
    assertEq(GS.PersonalContributorItemTotal(peerP, "Carol-Garona", "Player-1-Carol", ITEM_Y), 0,
        "459: mutual Y Carol 0 — not durable −10")
    GS._creditProjectionRowVisits = 0
    for _ = 1, 5 do
        GS.EnsureCreditCorrectionProjection(peerP, nil)
        GS.ResolveEffectiveCreditIdentity(peerP, GS.FindLedgerEventById(peerP, "mut-don-alice"))
    end
    assertTrue((tonumber(GS._creditProjectionRowVisits) or 0) == 0,
        "459: mutual unchanged reads skip rebuild visits="
            .. tostring(GS._creditProjectionRowVisits))
    assertEq(GS.FindLedgerEventById(peerP, "mut-don-alice").actor, "Alice-Garona",
        "459: mutual durable actor preserved")
    assertEq(tonumber(GS.FindLedgerEventById(peerP, "mut-don-alice").quantity), 10,
        "459: mutual durable qty preserved")
    assertEq(GS.FindLedgerEventById(peerP, "mut-don-y").actor, "Alice-Garona",
        "459: mutual Y durable actor preserved")
end

do
    -- No-progress idle: missing event / not-credited / capacity-full stop timers.
    local function plantOnePending(record, donId, corrId, itemId, reason)
        record.operations.pending = record.operations.pending or {}
        local ctx = select(1, GS:GetCurrentContext())
        record.operations.pending[corrId] = {
            id = corrId,
            sender = "Alice-Garona",
            reason = reason or "pending_event",
            body = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = corrId,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = donId,
                value = {
                    eventId = donId,
                    eventKind = "donation",
                    attributed = "Bob-Garona",
                    attributedGuid = "Player-1-Bob",
                    baseAttributed = "Alice-Garona",
                    baseAttributedGuid = "Player-1-Alice",
                    itemId = itemId,
                },
                actorGuid = "Player-1-Alice",
                actorName = "Alice-Garona",
                timestamp = world.time + 1,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            },
        }
    end
    local function assertIdleAfterDrain(record, label)
        local t0 = #timers
        flushTimers()
        local afterFlush = #timers
        -- Extra flush cycles must not enqueue more work.
        for _ = 1, 5 do
            flushTimers()
        end
        assertEq(#timers, afterFlush,
            "459: " .. label .. " idle — no further timers got "
                .. tostring(#timers) .. " after " .. tostring(afterFlush)
                .. " (pre-flush " .. tostring(t0) .. ")")
    end

    -- Missing donation: one wake, then idle until real AdmitLedgerEvent append.
    local miss = seedLiveCampaignWithItem(9321, 50)
    plantOnePending(miss, "miss-don", "miss-corr", 9321, "pending_event")
    GS.RedrivePendingContributorCorrections(miss, { itemId = 9321, maxAttempts = 8 })
    assertIdleAfterDrain(miss, "missing-event")
    assertTrue(miss.operations.pending["miss-corr"] ~= nil,
        "459: missing-event remains pending while blocked")
    local cfgMiss = miss.accounting._consumables
    local missEv = {
        type = GS.LEDGER_EVENT.DONATION,
        id = "miss-don",
        txnId = "miss-don",
        itemId = 9321,
        quantity = 5,
        generation = tonumber(cfgMiss.generation) or 1,
        timestamp = world.time,
        actor = "Alice-Garona",
        actorGuid = "Player-1-Alice",
        writer = "Player-1-Alice",
        verification = GS.VERIFICATION.OFFICER,
        verifierGuid = "Player-1-Alice",
        coreSignature = "miss|don",
        campaignId = miss.currentCampaignId,
        datasetId = miss.datasetId,
        guildGuid = cfgMiss.guild and tostring(cfgMiss.guild.guid),
        bankTab = tonumber(cfgMiss.bankTab),
    }
    local stMiss, rMiss = GS:AdmitLedgerEvent(missEv, {
        sender = "Alice-Garona",
        member = { guid = "Player-1-Alice", name = "Alice-Garona",
            guildKey = select(1, GS:GetCurrentContext()).guildKey, rankOrder = 1 },
        offlineRecord = miss,
        adoptionReplay = true,
        preserveAttribution = true,
        localWrite = false,
    })
    assertTrue(stMiss == "accepted" or stMiss == "duplicate",
        "459: missing-event AdmitLedgerEvent got " .. tostring(stMiss) .. "/" .. tostring(rMiss))
    flushTimers()
    assertTrue(miss.operations.records["miss-corr"] ~= nil,
        "459: missing-event settles after AdmitLedgerEvent append wake")
    assertNil(miss.operations.pending["miss-corr"],
        "459: missing-event pending cleared once")
    assertIdleAfterDrain(miss, "missing-event-recovered")

    -- Not-credited existing row: donation present but gsProductionCredit false.
    local nocred = seedLiveCampaignWithItem(9322, 50)
    local nocredDon = injectProductionDonation(nocred, {
        id = "nocred-don", itemId = 9322, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    nocredDon.gsProductionCredit = false
    plantOnePending(nocred, "nocred-don", "nocred-corr", 9322, "pending_event")
    GS.RedrivePendingContributorCorrections(nocred, { itemId = 9322, maxAttempts = 8 })
    assertIdleAfterDrain(nocred, "not-credited")
    assertTrue(nocred.operations.pending["nocred-corr"] ~= nil,
        "459: not-credited remains pending")
    nocredDon.gsProductionCredit = true
    if GS.InvalidateCreditCorrectionProjection then
        GS.InvalidateCreditCorrectionProjection(nocred)
    end
    GS.RedrivePendingContributorCorrections(nocred, {
        eventId = "nocred-don", itemId = 9322, maxAttempts = 8,
    })
    flushTimers()
    assertTrue(nocred.operations.records["nocred-corr"] ~= nil,
        "459: not-credited settles after production credit")

    -- Capacity-full: blocked pending goes idle; freeing capacity + wake settles.
    local cap = seedLiveCampaignWithItem(9323, 50)
    injectProductionDonation(cap, {
        id = "cap-don", itemId = 9323, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    plantOnePending(cap, "cap-don", "cap-corr", 9323, "pending_event")
    local prevMax = GS.MAX_ACCEPTED_OPERATIONS
    GS.MAX_ACCEPTED_OPERATIONS = GS._AcceptedCount(cap.operations) or 0
    GS.RedrivePendingContributorCorrections(cap, { itemId = 9323, maxAttempts = 8 })
    assertIdleAfterDrain(cap, "capacity-full")
    assertTrue(cap.operations.pending["cap-corr"] ~= nil,
        "459: capacity-full remains pending")
    GS.MAX_ACCEPTED_OPERATIONS = prevMax
    GS.RedrivePendingContributorCorrections(cap, { itemId = 9323, maxAttempts = 8 })
    flushTimers()
    assertTrue(cap.operations.records["cap-corr"] ~= nil,
        "459: capacity-full settles after capacity restored")
end

do
    -- Explicit full wake `{}` from InstallRemoteLiveCutover must dominate a
    -- prior filtered wave so item-B pending settles without manual Redrive.
    local record = seedLiveCampaignWithItem(9330, 80)
    local itemBOp = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 9331 }, {
        itemId = 9331, goal = 80, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(itemBOp), "accepted", "459: full-wake add item B")
    local cutover = record.liveCutover
    local boundary = tonumber(cutover.eligibilityBoundary and cutover.eligibilityBoundary.tabEligibleFrom)
        or tonumber(cutover.contextObservedAt) or world.time
    -- Item A: credited donation + pending already settled idle filter retained.
    injectProductionDonation(record, {
        id = "fw-don-a", itemId = 9330, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        timestamp = boundary + 10,
    })
    local pendingA = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "fw-corr-a",
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "fw-don-a",
        value = {
            eventId = "fw-don-a", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9330,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    assertEq(select(1, GS:AdmitRemoteOperation(pendingA, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })), "accepted", "459: full-wake item-A correction accepted")
    -- Leave a filtered idle continuation as if an A-wave just finished.
    GS.RedrivePendingContributorCorrections(record, { itemId = 9330, maxAttempts = 8 })
    flushTimers()

    -- Item B: marked donation not yet production-credited + pending correction.
    local donB = injectProductionDonation(record, {
        id = "fw-don-b", itemId = 9331, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        timestamp = boundary + 50,
    })
    donB.approxTxnTime = boundary + 50
    donB.gsProductionCredit = false
    donB.gsSourceCutoverMarker = cutover.cutoverMarker
    local pendingB = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "fw-corr-b",
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "fw-don-b",
        value = {
            eventId = "fw-don-b", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9331,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 2,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    assertEq(select(1, GS:AdmitRemoteOperation(pendingB, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })), "pending", "459: full-wake item-B pending before cutover")

    local savedCutover = {}
    for k, v in pairs(cutover) do
        savedCutover[k] = v
    end
    record.activation = GS.ACTIVATION_STAGED
    record.liveCutover = nil
    local stCut = GS.InstallRemoteLiveCutover(record, savedCutover,
        select(1, GS:GetCurrentContext()).guildKey, {
            quarantinePending = false,
            forceActive = true,
        })
    assertTrue(stCut == "accepted" or stCut == "duplicate",
        "459: full-wake InstallRemoteLiveCutover " .. tostring(stCut))
    flushTimers()
    assertEq(donB.gsProductionCredit, true, "459: full-wake B donation credited")
    assertTrue(record.operations.records["fw-corr-b"] ~= nil,
        "459: full-wake cutover `{}` promotes item-B without manual Redrive")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, donB)), "Bob-Garona",
        "459: full-wake B credit after cutover")
    local tAfter = #timers
    for _ = 1, 5 do flushTimers() end
    assertEq(#timers, tAfter, "459: full-wake idles after cutover drain")
end

do
    -- Conflict-heavy callback budget (#459 / discussion_r4476449746):
    -- independent CREDIT_PROJECTION_WORK_BUDGET, multi-slice redrive backlog,
    -- and ordinary Invalidate/Ensure pacing for a single expensive rebuild.
    local record = seedLiveCampaignWithItem(9340, 400)
    local donors = {
        { name = "Alice-Garona", guid = "Player-1-Alice" },
        { name = "Bob-Garona", guid = "Player-1-Bob" },
        { name = "Carol-Garona", guid = "Player-1-Carol" },
        { name = "Dave-Garona", guid = "Player-1-Dave" },
    }
    -- 40 Alice +1 donations and Alice −20 ⇒ floor 20. Accepting 24 corrections
    -- overdraws Alice (−4) so impact prune must run; 16 remain pending for redrive.
    local nDon = 40
    for i = 1, nDon do
        injectProductionDonation(record, {
            id = "score-don-" .. i, itemId = 9340, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = 20000 + i,
        })
    end
    injectProductionAdjustment(record, {
        id = "score-adj-alice", itemId = 9340, quantity = -20,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
        timestamp = 20100,
    })
    for di = 2, #donors do
        local d = donors[di]
        injectProductionDonation(record, {
            id = "score-seed-" .. di, itemId = 9340, quantity = 3,
            actor = d.name, actorGuid = d.guid,
            timestamp = 20110 + di,
        })
    end
    local pendingN = 16
    local acceptedN = nDon - pendingN
    local ctx = select(1, GS:GetCurrentContext())
    for i = 1, acceptedN do
        local target = donors[(i % (#donors - 1)) + 2] -- Bob/Carol/Dave
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "score-corr-" .. i,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "score-don-" .. i,
            value = {
                eventId = "score-don-" .. i,
                eventKind = "donation",
                attributed = target.name,
                attributedGuid = target.guid,
                baseAttributed = "Alice-Garona",
                baseAttributedGuid = "Player-1-Alice",
                itemId = 9340,
            },
            actorGuid = "Player-1-Alice",
            actorName = "Alice-Garona",
            timestamp = 20200 + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        record.operations.records[op.id] = op
        record.operations.order[#record.operations.order + 1] = op.id
    end

    local independentBudget = tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET)
    assertTrue(independentBudget ~= nil and independentBudget > 0,
        "459: CREDIT_PROJECTION_WORK_BUDGET defined independently")
    -- Tight ceiling so prune cannot finish in one callback (not derived from work1).
    local tightBudget = 80
    GS._creditProjectionWorkBudgetOverride = tightBudget

    -- Ordinary Invalidate/Ensure path before pending exists.
    GS.InvalidateCreditCorrectionProjection(record)
    local timersBeforeEnsure = #timers
    local ok1, err1, det1 = GS.EnsureCreditCorrectionProjection(record, nil)
    assertTrue(ok1 == false, "459: paced Ensure first slice incomplete")
    assertEq(err1, "work_budget", "459: paced Ensure yields work_budget")
    assertTrue(det1 and det1.deferred == true, "459: paced Ensure deferred flag")
    assertTrue((tonumber(det1 and det1.workUnits) or 0) >= tightBudget,
        "459: paced Ensure slice reached independent budget")
    assertTrue(#timers > timersBeforeEnsure,
        "459: paced Ensure scheduled continuation (control returns)")
    local ensureSlices = 1
    local maxEnsureSlices = 80
    while ensureSlices < maxEnsureSlices do
        assertTrue(runOneDueTimer(),
            "459: paced Ensure continuation callback " .. tostring(ensureSlices + 1))
        ensureSlices = ensureSlices + 1
        local okE, errE = GS.EnsureCreditCorrectionProjection(record, nil)
        if okE then
            break
        end
        assertEq(errE, "work_budget",
            "459: paced Ensure intermediate still work_budget got " .. tostring(errE))
    end
    assertTrue(ensureSlices > 1, "459: paced Ensure used multiple slices got="
        .. tostring(ensureSlices))
    assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
        "459: paced Ensure eventually available")
    flushTimers()

    -- O(1) scoreBox on a completed unlimited rebuild.
    GS._creditProjectionWorkBudgetOverride = nil
    GS.InvalidateCreditCorrectionProjection(record)
    local okScore, errScore, detScore = GS.RebuildCreditCorrectionProjection(record, nil)
    assertTrue(okScore, "459: conflict-heavy full rebuild ok got " .. tostring(errScore))
    local actualBuckets = #donors
    local bucketVisits = tonumber(detScore and detScore.bucketVisits) or 0
    local trials = tonumber(detScore and detScore.candidateTrials) or 0
    local deacts = tonumber(detScore and detScore.deactivations) or 0
    assertTrue(bucketVisits > 0, "459: conflict-heavy measured bucketVisits")
    assertTrue(trials > 0, "459: conflict-heavy candidateTrials got=" .. tostring(trials))
    assertTrue(deacts > 0, "459: conflict-heavy deactivations got=" .. tostring(deacts))
    local perTrial = bucketVisits / trials
    assertTrue(perTrial <= 8,
        "459: conflict-heavy bucketVisits/trial O(1) got="
            .. tostring(perTrial) .. " visits=" .. tostring(bucketVisits)
            .. " trials=" .. tostring(trials) .. " buckets=" .. tostring(actualBuckets))

    -- Install pending backlog larger than one work-limited redrive slice.
    record.operations.pending = record.operations.pending or {}
    local pendingIds = {}
    for i = acceptedN + 1, nDon do
        local target = donors[(i % (#donors - 1)) + 2]
        local id = "score-pend-" .. i
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
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = "score-don-" .. i,
                value = {
                    eventId = "score-don-" .. i,
                    eventKind = "donation",
                    attributed = target.name,
                    attributedGuid = target.guid,
                    baseAttributed = "Alice-Garona",
                    baseAttributedGuid = "Player-1-Alice",
                    itemId = 9340,
                },
                actorGuid = "Player-1-Alice",
                actorName = "Alice-Garona",
                timestamp = 20300 + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            },
        }
    end

    GS._creditProjectionWorkBudgetOverride = tightBudget
    local sliceWorks = {}
    local realRedrive = GS.RedrivePendingContributorCorrections
    GS.RedrivePendingContributorCorrections = function(...)
        local promoted, attempts, work = realRedrive(...)
        sliceWorks[#sliceWorks + 1] = {
            promoted = tonumber(promoted) or 0,
            attempts = tonumber(attempts) or 0,
            work = tonumber(work) or 0,
        }
        return promoted, attempts, work
    end
    local pendingBefore = 0
    for _ in pairs(record.operations.pending or {}) do
        pendingBefore = pendingBefore + 1
    end
    assertTrue(pendingBefore > 1,
        "459: conflict-heavy pending backlog > 1 got=" .. tostring(pendingBefore))
    assertEq(pendingBefore, #pendingIds, "459: conflict-heavy pending count matches")
    realRedrive(record, { itemId = 9340, maxAttempts = 64 })
    local drainGuard = 0
    while #timers > 0 and drainGuard < 400 do
        assertTrue(runOneDueTimer(), "459: redrive slice timer fired")
        drainGuard = drainGuard + 1
    end
    GS.RedrivePendingContributorCorrections = realRedrive
    GS._creditProjectionWorkBudgetOverride = nil
    assertTrue(#sliceWorks >= 2,
        "459: redrive used multiple callbacks got=" .. tostring(#sliceWorks))
    local productive = 0
    for si = 1, #sliceWorks do
        local sw = sliceWorks[si]
        if sw.work > 0 or sw.attempts > 0 then
            productive = productive + 1
            -- Within budget, or a single unit that crossed while making progress.
            assertTrue(sw.work <= tightBudget or sw.attempts <= 1,
                "459: redrive slice respects independent budget si="
                    .. tostring(si) .. " work=" .. tostring(sw.work)
                    .. " attempts=" .. tostring(sw.attempts)
                    .. " budget=" .. tostring(tightBudget))
        end
    end
    assertTrue(productive >= 2,
        "459: redrive had >=2 productive slices got=" .. tostring(productive))
    for pi = 1, #pendingIds do
        local id = pendingIds[pi]
        assertTrue(record.operations.records[id] ~= nil,
            "459: pending " .. id .. " eventually accepted")
        assertTrue(record.operations.pending[id] == nil,
            "459: pending " .. id .. " cleared from pending")
    end
    local okFinal, errFinal = GS.EnsureCreditCorrectionProjection(record, nil)
    assertTrue(okFinal, "459: conflict-heavy converges coherent got " .. tostring(errFinal))
    assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
        "459: conflict-heavy projection available after converge")

    -- Small non-conflict case stays synchronous (no timer).
    local small = seedLiveCampaignWithItem(9342, 20)
    injectProductionDonation(small, {
        id = "small-don", itemId = 9342, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local tSmall = #timers
    GS.InvalidateCreditCorrectionProjection(small)
    local okSmall = GS.EnsureCreditCorrectionProjection(small, nil)
    assertTrue(okSmall, "459: small Ensure completes synchronously")
    assertEq(#timers, tSmall, "459: small Ensure did not schedule continuation")
end

do
    -- Genuine reconstruction failure: durable Bob −20 with only Alice→Bob +10.
    -- Public consumers must surface credit_unavailable (not zero / durable names).
    local record = seedLiveCampaignWithItem(9350, 50)
    injectProductionDonation(record, {
        id = "fail-don", itemId = 9350, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "fail-don", "Bob-Garona", "Player-1-Bob"))
    assertTrue(corr ~= nil, "459: fail prepare Alice→Bob")
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "459: fail apply Alice→Bob")
    injectProductionAdjustment(record, {
        id = "fail-adj", itemId = 9350, quantity = -20,
        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
    })
    -- Legitimate Unassigned adjustment must stay distinct while available — seed
    -- one on a second item before forcing failure, then assert after recovery.
    local uOp = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 9351 }, {
        itemId = 9351, goal = 20, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(uOp), "accepted", "459: fail add Unassigned item")
    injectProductionDonation(record, {
        id = "fail-un-don", itemId = 9351, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(record, {
        id = "fail-un-adj", itemId = 9351, quantity = -2,
        attributed = nil, attributedGuid = nil,
    })

    GS.InvalidateCreditCorrectionProjection(record)
    local okFail, errFail = GS.RebuildCreditCorrectionProjection(record, nil)
    assertTrue(okFail == false, "459: fail rebuild returns false")
    assertEq(errFail, "player_negative", "459: fail reason player_negative")
    local name, guid, head, status = GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "fail-don"))
    assertNil(name, "459: fail Resolve name unavailable (not durable Alice)")
    assertNil(guid, "459: fail Resolve guid unavailable")
    assertNil(head, "459: fail Resolve head unavailable")
    assertEq(status, GS.CREDIT_UNAVAILABLE, "459: fail Resolve status credit_unavailable")
    local bobTotal, bobErr = GS.PersonalContributorItemTotal(
        record, "Bob-Garona", "Player-1-Bob", 9350)
    assertNil(bobTotal, "459: fail Bob total nil (not ordinary 0)")
    assertEq(bobErr, GS.CREDIT_UNAVAILABLE, "459: fail Bob err credit_unavailable")
    -- Use an item whose quantity floor still passes so personal-credit
    -- unavailability is the rejecting reason (not item_negative).
    local floorOk, floorErr = GS.AdjustmentFloorOk(
        record, 9351, -1, "Alice-Garona", nil, { attributedGuid = "Player-1-Alice" })
    assertTrue(floorOk == false, "459: fail floor rejects while unavailable")
    assertEq(floorErr, GS.CREDIT_UNAVAILABLE, "459: fail floor err credit_unavailable")
    local corrFloorOk, corrFloorErr = GS.ContributorCorrectionFloorOk(
        record, GS.FindLedgerEventById(record, "fail-don"),
        "Carol-Garona", "Player-1-Carol")
    assertTrue(corrFloorOk == false, "459: fail correction floor rejects")
    assertEq(corrFloorErr, GS.CREDIT_UNAVAILABLE,
        "459: fail correction floor err credit_unavailable")
    local progress = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    assertTrue(type(progress) == "table", "459: fail progress table")
    assertTrue(progress.creditUnavailable == true, "459: fail progress creditUnavailable")
    assertTrue(type(progress.itemTotals) == "table"
        and (tonumber(progress.itemTotals[9350]) or 0) ~= 0,
        "459: fail progress keeps item totals")
    local contribCount = 0
    for _ in pairs(progress.contributions or {}) do
        contribCount = contribCount + 1
    end
    assertEq(contribCount, 0, "459: fail progress contributions empty while unavailable")
    local rankings = GS.ProjectCampaignRankingsOnRecord(record, record.currentCampaignId)
    assertEq(rankings.emptyReason, GS.CREDIT_UNAVAILABLE,
        "459: fail rankings emptyReason credit_unavailable")
    assertTrue(rankings.creditUnavailable == true, "459: fail rankings flag")
    assertEq(#(rankings.rows or {}), 0, "459: fail rankings rows empty")
    local donEv = GS.FindLedgerEventById(record, "fail-don")
    local _, _, _, st2 = GS.ResolveEffectiveCreditIdentity(record, donEv)
    assertEq(st2, GS.CREDIT_UNAVAILABLE, "459: fail Logs path Resolve unavailable")
    -- History rows must carry creditUnavailable and omit durable display names.
    do
        local gk = select(1, GS:GetCurrentContext()).guildKey
        local saved = GS._root and GS._root.guilds and GS._root.guilds[gk]
        if type(GS._root) == "table" and type(GS._root.guilds) == "table" then
            GS._root.guilds[gk] = record
        end
        local hist = select(1, GS:ListCampaignHistory(record.currentCampaignId, nil, 0))
        assertTrue(type(hist) == "table" and #hist > 0, "459: fail history rows present")
        local sawUnavailable, sawDurableDonor = false, false
        for i = 1, #hist do
            local row = hist[i]
            if row and row.id == "fail-don" then
                if row.creditUnavailable then
                    sawUnavailable = true
                end
                if row.displayActor == "Alice-Garona"
                    or row.effectiveAttributed == "Alice-Garona" then
                    sawDurableDonor = true
                end
            end
        end
        assertTrue(sawUnavailable, "459: fail Logs row creditUnavailable")
        assertTrue(not sawDurableDonor, "459: fail Logs omits durable donor name")
        if saved and type(GS._root) == "table" and type(GS._root.guilds) == "table" then
            GS._root.guilds[gk] = saved
        end
    end

    GS._creditProjectionRowVisits = 0
    for _ = 1, 5 do
        local okCached = GS.EnsureCreditCorrectionProjection(record, nil)
        assertTrue(okCached == false, "459: fail cached Ensure stays false")
        GS.ResolveEffectiveCreditIdentity(record, donEv)
    end
    assertTrue((tonumber(GS._creditProjectionRowVisits) or 0) == 0,
        "459: fail unchanged reads skip rebuild visits="
            .. tostring(GS._creditProjectionRowVisits))

    -- Supported recovery: remove the overspend dependency and rebuild.
    local list = record.accounting._consumableEvents
    for i = #list, 1, -1 do
        if list[i] and list[i].id == "fail-adj" then
            table.remove(list, i)
            break
        end
    end
    GS.InvalidateCreditCorrectionProjection(record)
    local okRec, errRec = GS.EnsureCreditCorrectionProjection(record, nil)
    assertTrue(okRec, "459: fail recovers after dependency change got " .. tostring(errRec))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "fail-don"))), "Bob-Garona",
        "459: fail recovery restores Bob credit")
    local bobAfter, bobAfterErr = GS.PersonalContributorItemTotal(
        record, "Bob-Garona", "Player-1-Bob", 9350)
    assertEq(bobAfterErr, nil, "459: fail recovery personal err cleared")
    assertEq(bobAfter, 10, "459: fail recovery Bob total 10")
    -- Unassigned adjustment remains nil attribution while available (not unavailable).
    local unName, unGuid, unHead, unStatus = GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "fail-un-adj"))
    assertNil(unName, "459: Unassigned name nil while available")
    assertNil(unGuid, "459: Unassigned guid nil while available")
    assertNil(unHead, "459: Unassigned no correction head")
    assertNil(unStatus, "459: Unassigned status nil (not credit_unavailable)")
    local progressOk = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    assertTrue(not progressOk.creditUnavailable, "459: fail recovery progress available")
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
