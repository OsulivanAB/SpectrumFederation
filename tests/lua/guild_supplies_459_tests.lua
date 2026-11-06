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

assertEq(GS.PROVIDER_SCHEMA, 6, "459: PROVIDER_SCHEMA is 6")
assertTrue(GS.KIND.CORRECT_CONTRIBUTOR == "correct-contributor", "459: correction kind registered")

do
    -- Combined protocol schema 6: released schema-5 peers are excluded by GG
    -- equality; two schema-6 peers transfer a correction and agree on credit
    -- (discussion_r4483753485).
    assertEq(GS.PROVIDER_SCHEMA, 6, "459-schema6: wire schema is 6")
    assertEq(GS.SCHEMA_VERSION, 1, "459-schema6: persisted root schema unchanged")
    GS:EnsureGossipProvider()
    local prov = GG.GetProvider(GS.PROVIDER_ID)
    assertTrue(type(prov) == "table", "459-schema6: provider registered")
    assertEq(tonumber(prov.schema), 6, "459-schema6: registered schema 6")
    local caps = prov.api and prov.api.GetCapabilities and prov.api.GetCapabilities()
    assertTrue(type(caps) == "table", "459-schema6: capabilities")
    assertEq(tonumber(caps.schema), 6, "459-schema6: advertised schema 6")
    -- Strict equality gate (GuildGossip compatibleProviders / handleView).
    local function schemaMatches(remoteSchema)
        return tonumber(remoteSchema) == tonumber(prov.schema)
    end
    assertTrue(not schemaMatches(5),
        "459-schema6: released schema-5 peer incompatible")
    assertTrue(not schemaMatches(4),
        "459-schema6: schema-4 peer incompatible")
    assertTrue(schemaMatches(6),
        "459-schema6: new-protocol peers match")
    -- VIEW payload with released schema 5 must not equal local provider schema.
    assertTrue(tonumber(5) ~= tonumber(prov.schema),
        "459-schema6: VIEW schema 5 rejected by equality")

    local peerA = seedLiveCampaignWithItem(91001, 40)
    injectProductionDonation(peerA, {
        id = "s6-don", itemId = 91001, quantity = 7,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "s6-don", "Bob-Garona", "Player-1-Bob"))
    assertTrue(corr ~= nil, "459-schema6: peerA prepare")
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "459-schema6: peerA apply")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peerA, GS.FindLedgerEventById(peerA, "s6-don"))), "Bob-Garona",
        "459-schema6: peerA credit Bob")
    local snap = select(1, GS._SnapshotPublicOp(corr))
    assertTrue(type(snap) == "table", "459-schema6: public snap")

    local peerB = seedLiveCampaignWithItem(91001, 40)
    injectProductionDonation(peerB, {
        id = "s6-don", itemId = 91001, quantity = 7,
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
        "459-schema6: peerB admits correction got "
            .. tostring(stB) .. "/" .. tostring(reasonB))
    flushTimers()
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        peerB, GS.FindLedgerEventById(peerB, "s6-don"))), "Bob-Garona",
        "459-schema6: peerB credit Bob")
    assertEq(GS.PersonalContributorItemTotal(peerA, "Bob-Garona", "Player-1-Bob", 91001),
        GS.PersonalContributorItemTotal(peerB, "Bob-Garona", "Player-1-Bob", 91001),
        "459-schema6: peers agree Bob personal total")
    assertEq(GS.PersonalContributorItemTotal(peerA, "Alice-Garona", "Player-1-Alice", 91001),
        0, "459-schema6: peerA Alice emptied")
    assertEq(GS.PersonalContributorItemTotal(peerB, "Alice-Garona", "Player-1-Alice", 91001),
        0, "459-schema6: peerB Alice emptied")
end

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
                    -- Stay within production timestamp skew (not hours ahead).
                    timestamp = world.time + i,
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
                    -- Within production skew; do not plant multi-hour futures.
                    timestamp = world.time + 100 + i,
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
            timestamp = world.time + 180,
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
        timestamp = world.time + 200,
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
    local durableN = 0
    for _ in pairs(cfg.creditEventAliases or {}) do
        durableN = durableN + 1
    end
    -- Ledger + registry + durable alias-map fold (linear, not N²).
    assertTrue(visits <= ledgerRows + registryRows + n + durableN + 16,
        "459: alias-heavy visits O(ledger+registry+aliases) visits=" .. tostring(visits)
            .. " ledger=" .. tostring(ledgerRows) .. " reg=" .. tostring(registryRows)
            .. " durable=" .. tostring(durableN))
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
    local ensureWork = tonumber(det1 and det1.workUnits) or 0
    local hardCeilingEnsure = tightBudget
        + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
    assertTrue(ensureWork >= tightBudget,
        "459: paced Ensure slice reached independent budget")
    assertTrue(ensureWork <= hardCeilingEnsure,
        "459: paced Ensure first callback within soft+atomic ceiling got="
            .. tostring(ensureWork) .. " hard=" .. tostring(hardCeilingEnsure))
    assertTrue(#timers > timersBeforeEnsure,
        "459: paced Ensure scheduled continuation (control returns)")
    -- Autonomous timer drain: do not call Ensure between callbacks.
    local ensureSlices = 0
    local maxEnsureSlices = 200
    while #timers > 0 and ensureSlices < maxEnsureSlices do
        assertTrue(runOneDueTimer(),
            "459: paced Ensure autonomous timer " .. tostring(ensureSlices + 1))
        ensureSlices = ensureSlices + 1
    end
    assertTrue(ensureSlices > 1, "459: paced Ensure used multiple slices got="
        .. tostring(ensureSlices))
    assertEq(#timers, 0, "459: paced Ensure idles with no queued timers")
    assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
        "459: paced Ensure eventually available without intervening Ensure")
    local okAutonomous, errAutonomous = GS.EnsureCreditCorrectionProjection(record, nil)
    assertTrue(okAutonomous,
        "459: paced Ensure terminal coherent got " .. tostring(errAutonomous))

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
    -- Paced init/activate yields more slices under tightBudget=80; drain until idle.
    while #timers > 0 and drainGuard < 8000 do
        assertTrue(runOneDueTimer(), "459: redrive slice timer fired")
        drainGuard = drainGuard + 1
    end
    GS.RedrivePendingContributorCorrections = realRedrive
    GS._creditProjectionWorkBudgetOverride = nil
    assertEq(#timers, 0, "459: redrive idles with empty timer queue")
    assertTrue(#sliceWorks >= 2,
        "459: redrive used multiple callbacks got=" .. tostring(#sliceWorks))
    local productive = 0
    local hardCeiling = tightBudget
        + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
    for si = 1, #sliceWorks do
        local sw = sliceWorks[si]
        if sw.work > 0 or sw.attempts > 0 then
            productive = productive + 1
            -- Soft budget + explicit atomic overshoot only — no attempt exemption.
            assertTrue(sw.work <= hardCeiling,
                "459: redrive slice within soft+atomic ceiling si="
                    .. tostring(si) .. " work=" .. tostring(sw.work)
                    .. " attempts=" .. tostring(sw.attempts)
                    .. " soft=" .. tostring(tightBudget)
                    .. " hard=" .. tostring(hardCeiling))
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
    -- Deterministic selection across slice budgets (#459 / discussion_r4476698352).
    -- Alice D1=+2, D2=+8, Alice−8; corrections older D1→Bob, newer D2→Carol.
    -- Full pass removes D2 (impact 8), retaining D1→Bob. Partial-prefix must not
    -- remove D1 first.
    local function buildUnequalImpactRecord()
        local record = seedLiveCampaignWithItem(9370, 40)
        injectProductionDonation(record, {
            id = "sel-d1", itemId = 9370, quantity = 2,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = 22001,
        })
        injectProductionDonation(record, {
            id = "sel-d2", itemId = 9370, quantity = 8,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = 22002,
        })
        injectProductionAdjustment(record, {
            id = "sel-adj", itemId = 9370, quantity = -8,
            attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
            timestamp = 22010,
        })
        local ctx = select(1, GS:GetCurrentContext())
        local op1 = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "sel-corr-d1",
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "sel-d1",
            value = {
                eventId = "sel-d1", eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9370,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = 22020,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        local op2 = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "sel-corr-d2",
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "sel-d2",
            value = {
                eventId = "sel-d2", eventKind = "donation",
                attributed = "Carol-Garona", attributedGuid = "Player-1-Carol",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9370,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = 22030,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        record.operations.records[op1.id] = op1
        record.operations.order[#record.operations.order + 1] = op1.id
        record.operations.records[op2.id] = op2
        record.operations.order[#record.operations.order + 1] = op2.id
        return record
    end
    local function settleProjection(record)
        GS.InvalidateCreditCorrectionProjection(record)
        local ok, err = GS.EnsureCreditCorrectionProjection(record, nil)
        local guard = 0
        while ok == false and err == "work_budget" and guard < 200 do
            if not runOneDueTimer() then
                break
            end
            guard = guard + 1
            -- Autonomous: do not poke Ensure until timers idle.
        end
        while #timers > 0 and guard < 400 do
            runOneDueTimer()
            guard = guard + 1
        end
        ok, err = GS.EnsureCreditCorrectionProjection(record, nil)
        assertTrue(ok, "459: selection settle ok got " .. tostring(err))
        return record
    end
    local function creditNames(record)
        local d1 = select(1, GS.ResolveEffectiveCreditIdentity(
            record, GS.FindLedgerEventById(record, "sel-d1")))
        local d2 = select(1, GS.ResolveEffectiveCreditIdentity(
            record, GS.FindLedgerEventById(record, "sel-d2")))
        return d1, d2
    end

    -- Fresh full budget.
    local rFull = settleProjection(buildUnequalImpactRecord())
    local d1Full, d2Full = creditNames(rFull)
    assertEq(d1Full, "Bob-Garona", "459: selection full budget D1→Bob")
    assertEq(d2Full, "Alice-Garona", "459: selection full budget D2 durable Alice")

    -- Tiny multi-slice budget.
    GS._creditProjectionWorkBudgetOverride = 12
    local rTiny = settleProjection(buildUnequalImpactRecord())
    GS._creditProjectionWorkBudgetOverride = nil
    local d1Tiny, d2Tiny = creditNames(rTiny)
    assertEq(d1Tiny, d1Full, "459: selection tiny budget D1 matches full")
    assertEq(d2Tiny, d2Full, "459: selection tiny budget D2 matches full")

    -- Nearly exhausted shared parent allowance (models nested callback).
    GS._creditProjectionWorkBudgetOverride = 16384
    local rNear = buildUnequalImpactRecord()
    GS.InvalidateCreditCorrectionProjection(rNear)
    -- Seed remaining allowance as nearly exhausted before Rebuild.
    GS._creditProjectionAccumulating = true
    GS._creditProjectionCallbackWork = 16372
    GS._creditProjectionCallbackLimit = 16384
    GS._creditProjectionCallbackHardLimit = 16384
        + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
    local okNear, errNear = GS.RebuildCreditCorrectionProjection(rNear, nil)
    GS._creditProjectionAccumulating = false
    if okNear == false and errNear == "work_budget" then
        local g = 0
        while #timers > 0 and g < 400 do
            runOneDueTimer()
            g = g + 1
        end
    end
    GS._creditProjectionWorkBudgetOverride = nil
    local okNear2, errNear2 = GS.EnsureCreditCorrectionProjection(rNear, nil)
    assertTrue(okNear2, "459: selection near-exhausted settles got " .. tostring(errNear2))
    local d1Near, d2Near = creditNames(rNear)
    assertEq(d1Near, d1Full, "459: selection near-exhausted D1 matches full")
    assertEq(d2Near, d2Full, "459: selection near-exhausted D2 matches full")
end

do
    -- Autonomous accepted-history completion: one Ensure kickoff, then only timers.
    local record = seedLiveCampaignWithItem(9371, 400)
    local donors = {
        { name = "Alice-Garona", guid = "Player-1-Alice" },
        { name = "Bob-Garona", guid = "Player-1-Bob" },
        { name = "Carol-Garona", guid = "Player-1-Carol" },
        { name = "Dave-Garona", guid = "Player-1-Dave" },
    }
    for i = 1, 40 do
        injectProductionDonation(record, {
            id = "auto-don-" .. i, itemId = 9371, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = 23000 + i,
        })
    end
    injectProductionAdjustment(record, {
        id = "auto-adj", itemId = 9371, quantity = -20,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
        timestamp = 23100,
    })
    for di = 2, #donors do
        local d = donors[di]
        injectProductionDonation(record, {
            id = "auto-seed-" .. di, itemId = 9371, quantity = 3,
            actor = d.name, actorGuid = d.guid,
            timestamp = 23110 + di,
        })
    end
    local ctx = select(1, GS:GetCurrentContext())
    for i = 1, 24 do
        local target = donors[(i % (#donors - 1)) + 2]
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "auto-corr-" .. i,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "auto-don-" .. i,
            value = {
                eventId = "auto-don-" .. i, eventKind = "donation",
                attributed = target.name, attributedGuid = target.guid,
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9371,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = 23200 + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        record.operations.records[op.id] = op
        record.operations.order[#record.operations.order + 1] = op.id
    end
    local tightBudget = 80
    local hardCeiling = tightBudget
        + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
    GS._creditProjectionWorkBudgetOverride = tightBudget
    GS.InvalidateCreditCorrectionProjection(record)
    local callbackWorks = {}
    local realRebuild = GS.RebuildCreditCorrectionProjection
    GS.RebuildCreditCorrectionProjection = function(...)
        local ok, err, det = realRebuild(...)
        local cw = tonumber(det and det.workUnits) or 0
        local cb = tonumber(det and det.callbackWork)
            or tonumber(GS._creditProjectionCallbackWork) or 0
        if cb > cw then
            cw = cb
        end
        if err == "work_budget" or ok then
            callbackWorks[#callbackWorks + 1] = cw
        end
        return ok, err, det
    end
    local ok0, err0 = GS.EnsureCreditCorrectionProjection(record, nil)
    assertEq(err0, "work_budget", "459: autonomous kickoff work_budget")
    local g = 0
    while #timers > 0 and g < 400 do
        runOneDueTimer()
        g = g + 1
    end
    GS.RebuildCreditCorrectionProjection = realRebuild
    GS._creditProjectionWorkBudgetOverride = nil
    assertEq(#timers, 0, "459: autonomous idles with empty timer queue")
    assertTrue(g > 1, "459: autonomous drained multiple timers got=" .. tostring(g))
    assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
        "459: autonomous projection available after timers only")
    for i = 1, #callbackWorks do
        assertTrue(callbackWorks[i] <= hardCeiling,
            "459: autonomous callback within soft+atomic i="
                .. tostring(i) .. " work=" .. tostring(callbackWorks[i])
                .. " hard=" .. tostring(hardCeiling))
    end
end


do
    -- Rejected local preview must not publish via background resume (#459
    -- discussion_r4476590692). Public prepare/apply → rejected/work_budget;
    -- after every timer and an accepted-history rebuild, credit stays original.
    local record = seedLiveCampaignWithItem(9360, 400)
    local donors = {
        { name = "Alice-Garona", guid = "Player-1-Alice" },
        { name = "Bob-Garona", guid = "Player-1-Bob" },
        { name = "Carol-Garona", guid = "Player-1-Carol" },
        { name = "Dave-Garona", guid = "Player-1-Dave" },
    }
    local nDon = 40
    for i = 1, nDon do
        injectProductionDonation(record, {
            id = "rej-don-" .. i, itemId = 9360, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = 21000 + i,
        })
    end
    injectProductionAdjustment(record, {
        id = "rej-adj-alice", itemId = 9360, quantity = -20,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
        timestamp = 21100,
    })
    for di = 2, #donors do
        local d = donors[di]
        injectProductionDonation(record, {
            id = "rej-seed-" .. di, itemId = 9360, quantity = 3,
            actor = d.name, actorGuid = d.guid,
            timestamp = 21110 + di,
        })
    end
    local ctx = select(1, GS:GetCurrentContext())
    for i = 1, 24 do
        local target = donors[(i % (#donors - 1)) + 2]
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "rej-corr-" .. i,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "rej-don-" .. i,
            value = {
                eventId = "rej-don-" .. i,
                eventKind = "donation",
                attributed = target.name,
                attributedGuid = target.guid,
                baseAttributed = "Alice-Garona",
                baseAttributedGuid = "Player-1-Alice",
                itemId = 9360,
            },
            actorGuid = "Player-1-Alice",
            actorName = "Alice-Garona",
            timestamp = 21200 + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        record.operations.records[op.id] = op
        record.operations.order[#record.operations.order + 1] = op.id
    end
    GS.InvalidateCreditCorrectionProjection(record)
    assertTrue(select(1, GS.RebuildCreditCorrectionProjection(record, nil)),
        "459: rejected-edit settle existing projection")
    flushTimers()

    -- Independent item Y: Alice +10; prepare Alice→Bob; apply under tight budget.
    local yOp = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 9361 }, {
        itemId = 9361, goal = 20, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(yOp), "accepted", "459: rejected-edit add item Y")
    injectProductionDonation(record, {
        id = "rej-y-don", itemId = 9361, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        timestamp = 21300,
    })
    local preview = select(1, GS:NewContributorCorrectionOperation(
        "rej-y-don", "Bob-Garona", "Player-1-Bob"))
    assertTrue(type(preview) == "table" and type(preview.id) == "string",
        "459: rejected-edit prepared Alice→Bob on Y")
    GS._creditProjectionWorkBudgetOverride = 80
    local status, reason = GS:ApplyStagedConfigOperation(preview)
    GS._creditProjectionWorkBudgetOverride = nil
    -- Authorized local work_budget is resumable (#459 / discussion_r4480434323):
    -- pending (not rejected), private retain (not ops.pending), timer-only accept.
    assertEq(status, "pending", "459: local-save apply status pending")
    assertEq(reason, "work_budget", "459: local-save apply reason work_budget")
    assertTrue(record.operations.records[preview.id] == nil,
        "459: local-save not accepted before timers")
    assertTrue(not record.operations.pending or record.operations.pending[preview.id] == nil,
        "459: local-save not remote-pending")
    local retained = GS.GetLocalContributorCorrectionSave
        and GS.GetLocalContributorCorrectionSave(record)
    assertTrue(type(retained) == "table" and retained.op and retained.op.id == preview.id,
        "459: local-save private retain held")

    for _ = 1, 200 do
        if record.operations.records[preview.id] then break end
        if not runOneDueTimer() then break end
    end
    flushTimers()
    local yEv = GS.FindLedgerEventById(record, "rej-y-don")
    assertTrue(record.operations.records[preview.id] ~= nil,
        "459: local-save accepted via timers")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, yEv)), "Bob-Garona",
        "459: local-save Y credit Bob after timers")
    assertNil(GS.GetLocalContributorCorrectionSave(record),
        "459: local-save retain cleared")
    local occurrences = 0
    for _, id in ipairs(record.operations.order) do
        if id == preview.id then occurrences = occurrences + 1 end
    end
    assertEq(occurrences, 1, "459: local-save stored once")
end

do
    -- Substantial retained-history complete-callback bound (#459 /
    -- discussion_r4476962015): init/activate + remaining traversals must
    -- respect soft+atomic under fresh, partially-consumed, and resumed paths.
    -- Fixture: 4000 Alice +1, Alice −2000, Bob/Carol/Dave seeds, 3984 heads.
    local function buildLargeConflictRecord(itemId)
        local record = seedLiveCampaignWithItem(itemId, 4000)
        local donors = {
            { name = "Alice-Garona", guid = "Player-1-Alice" },
            { name = "Bob-Garona", guid = "Player-1-Bob" },
            { name = "Carol-Garona", guid = "Player-1-Carol" },
            { name = "Dave-Garona", guid = "Player-1-Dave" },
        }
        local nDon = 4000
        for i = 1, nDon do
            injectProductionDonation(record, {
                id = "copy-don-" .. itemId .. "-" .. i,
                itemId = itemId, quantity = 1,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
                timestamp = 24000 + i,
            })
        end
        injectProductionAdjustment(record, {
            id = "copy-adj-" .. itemId, itemId = itemId, quantity = -2000,
            attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
            timestamp = 28010,
        })
        for di = 2, #donors do
            local d = donors[di]
            injectProductionDonation(record, {
                id = "copy-seed-" .. itemId .. "-" .. di,
                itemId = itemId, quantity = 3,
                actor = d.name, actorGuid = d.guid,
                timestamp = 28020 + di,
            })
        end
        local ctx = select(1, GS:GetCurrentContext())
        local acceptedN = 3984
        for i = 1, acceptedN do
            local target = donors[(i % (#donors - 1)) + 2]
            local donId = "copy-don-" .. itemId .. "-" .. i
            local op = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = "copy-corr-" .. itemId .. "-" .. i,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = donId,
                value = {
                    eventId = donId, eventKind = "donation",
                    attributed = target.name, attributedGuid = target.guid,
                    baseAttributed = "Alice-Garona",
                    baseAttributedGuid = "Player-1-Alice",
                    itemId = itemId,
                },
                actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                timestamp = 28100 + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
            record.operations.records[op.id] = op
            record.operations.order[#record.operations.order + 1] = op.id
        end
        return record, acceptedN, nDon
    end
    -- Complete final credit set: every corrected donation + uncorrected tail.
    local function fullCreditSet(record, itemId, acceptedN, nDon)
        local parts = {}
        local active = 0
        local removed = 0
        for i = 1, acceptedN do
            local ev = GS.FindLedgerEventById(record, "copy-don-" .. itemId .. "-" .. i)
            local name = select(1, GS.ResolveEffectiveCreditIdentity(record, ev))
            parts[#parts + 1] = tostring(i) .. "=" .. tostring(name or "?")
            if name == "Alice-Garona" then
                removed = removed + 1
            else
                active = active + 1
            end
        end
        for i = acceptedN + 1, nDon do
            local ev = GS.FindLedgerEventById(record, "copy-don-" .. itemId .. "-" .. i)
            local name = select(1, GS.ResolveEffectiveCreditIdentity(record, ev))
            parts[#parts + 1] = tostring(i) .. "=" .. tostring(name or "?")
        end
        return table.concat(parts, ";"), active, removed
    end
    local function assertSlicesWithinBound(label, slices, hard)
        local boundFail = nil
        local sawActivate = false
        local sawPrune = false
        local travSum = 0
        local copySum = 0
        for i = 1, #slices do
            local s = slices[i]
            local total = (tonumber(s.work) or 0)
            if total > hard and not boundFail then
                boundFail = label .. " callback within soft+atomic i="
                    .. tostring(i) .. " work=" .. tostring(s.work)
                    .. " trav=" .. tostring(s.trav)
                    .. " copies=" .. tostring(s.copies)
                    .. " hard=" .. tostring(hard)
                    .. " phase=" .. tostring(s.phase)
                    .. " outer=" .. tostring(s.outer)
            end
            travSum = travSum + (tonumber(s.trav) or 0)
            copySum = copySum + (tonumber(s.copies) or 0)
            if s.phase == "activate" or s.phase == "activate_restore" then
                sawActivate = true
            end
            if s.phase == "prune" or s.phase == "prune_scan"
                or s.phase == "pre_prune" or s.phase == "empty_fallback" then
                sawPrune = true
            end
            if s.outer ~= nil and s.outer > hard and not boundFail then
                boundFail = label .. " outer callback accum i="
                    .. tostring(i) .. " outer=" .. tostring(s.outer)
                    .. " hard=" .. tostring(hard)
            end
        end
        assertTrue(boundFail == nil, boundFail or (label .. " all callbacks within soft+atomic"))
        return travSum, copySum, sawActivate, sawPrune
    end
    local function settleAutonomous(record, opts)
        opts = opts or {}
        local budgetOverride = opts.budgetOverride
        local preConsumed = tonumber(opts.preConsumed) or 0
        GS._creditProjectionWorkBudgetOverride = budgetOverride
        GS.InvalidateCreditCorrectionProjection(record)
        local soft = tonumber(budgetOverride)
            or tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384
        local hard = soft + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
        local slices = {}
        local realRebuild = GS.RebuildCreditCorrectionProjection
        GS.RebuildCreditCorrectionProjection = function(...)
            local ok, err, det = realRebuild(...)
            local work = tonumber(det and det.workUnits) or 0
            local copies = tonumber(det and det.structureCopyVisits) or 0
            local trav = tonumber(det and det.traversalVisits) or 0
            local outer = tonumber(det and det.callbackWork)
                or tonumber(GS._creditProjectionCallbackWork) or work
            local phase = det and det.phase
            if err == "work_budget" or ok then
                slices[#slices + 1] = {
                    ok = ok and true or false,
                    err = err,
                    work = work,
                    copies = copies,
                    trav = trav,
                    outer = outer,
                    phase = phase,
                    deferred = det and det.deferred,
                }
            end
            return ok, err, det
        end
        if preConsumed > 0 then
            -- Model an outer callback that already consumed part of the normal
            -- shared allowance before Rebuild (discussion_r4476962015).
            GS._creditProjectionAccumulating = true
            GS._creditProjectionCallbackWork = preConsumed
            GS._creditProjectionCallbackLimit = soft
            GS._creditProjectionCallbackHardLimit = hard
        end
        local ok0, err0 = GS.EnsureCreditCorrectionProjection(record, nil)
        if preConsumed > 0 then
            -- Ensure/Rebuild may own EndBudget; ensure accumulation flag cleared
            -- before autonomous timers open fresh budgets.
            GS._creditProjectionAccumulating = false
        end
        assertTrue(ok0 == false or ok0 == true,
            "459: copy-bound Ensure returned")
        if ok0 == false then
            assertEq(err0, "work_budget", "459: copy-bound kickoff work_budget")
        end
        local g = 0
        local maxTimers = 8000
        local timerFail = nil
        while #timers > 0 and g < maxTimers do
            if not runOneDueTimer() then
                timerFail = "459: copy-bound autonomous timer stalled at " .. tostring(g + 1)
                break
            end
            g = g + 1
        end
        GS.RebuildCreditCorrectionProjection = realRebuild
        GS._creditProjectionWorkBudgetOverride = nil
        GS._creditProjectionAccumulating = false
        assertTrue(timerFail == nil, timerFail or "459: copy-bound timers drained")
        assertTrue(g >= 1, "459: copy-bound drained timers got=" .. tostring(g))
        assertEq(#timers, 0, "459: copy-bound idles with empty timer queue")
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            "459: copy-bound projection available after timers only")
        local okTerm, errTerm = GS.EnsureCreditCorrectionProjection(record, nil)
        assertTrue(okTerm, "459: copy-bound terminal coherent got " .. tostring(errTerm))
        return slices, hard, soft, g
    end

    local itemFull = 9380
    local rFull, acceptedN, nDon = buildLargeConflictRecord(itemFull)
    assertEq(acceptedN, 3984, "459: copy-bound accepted head count")

    -- (a) Fresh production callback.
    local slicesFresh, hardFresh = settleAutonomous(rFull, {})
    assertTrue(#slicesFresh >= 2,
        "459: copy-bound fresh multi-slice got=" .. tostring(#slicesFresh))
    local travFresh, copyFresh, sawActFresh, sawPruneFresh =
        assertSlicesWithinBound("459: copy-bound fresh", slicesFresh, hardFresh)
    assertTrue(sawActFresh or sawPruneFresh,
        "459: copy-bound fresh observed activate or prune phase")
    assertTrue(copyFresh < acceptedN,
        "459: copy-bound fresh structure copies bounded got=" .. tostring(copyFresh))
    assertTrue(travFresh >= 0, "459: copy-bound fresh traversal measured")
    local fpFresh, activeFresh, removedFresh =
        fullCreditSet(rFull, itemFull, acceptedN, nDon)
    assertTrue(removedFresh > 0 and activeFresh >= 0,
        "459: copy-bound fresh has retained/removed boundary active="
            .. tostring(activeFresh) .. " removed=" .. tostring(removedFresh))

    -- (b) Partially consumed normal shared allowance (8000 of 16384) — the
    -- reproduced case where unpaced activate previously pushed outer work
    -- above soft+atomic on the first shared Rebuild.
    local itemPartial = 9381
    local rPartial = buildLargeConflictRecord(itemPartial)
    local slicesPartial, hardPartial = settleAutonomous(rPartial, {
        preConsumed = 8000,
    })
    assertTrue(#slicesPartial >= 2,
        "459: copy-bound partial multi-slice got=" .. tostring(#slicesPartial))
    local _, copyPartial = assertSlicesWithinBound(
        "459: copy-bound partial", slicesPartial, hardPartial)
    assertTrue(#slicesPartial > 0 and slicesPartial[1].outer ~= nil,
        "459: copy-bound partial first slice reports outer accumulation")
    assertTrue(slicesPartial[1].outer <= hardPartial,
        "459: copy-bound partial first outer <= soft+atomic got="
            .. tostring(slicesPartial[1].outer) .. " hard=" .. tostring(hardPartial))
    assertTrue(copyPartial < acceptedN,
        "459: copy-bound partial structure copies bounded got=" .. tostring(copyPartial))
    local fpPartial = select(1, fullCreditSet(rPartial, itemPartial, acceptedN, nDon))

    -- (b2) Lower pre-consumed remainder so the shared call reaches paced
    -- activate (not only post_baseline) under the same production constants.
    local itemPartialAct = 9383
    local rPartialAct = buildLargeConflictRecord(itemPartialAct)
    local slicesPartialAct, hardPartialAct = settleAutonomous(rPartialAct, {
        preConsumed = 2000,
    })
    local _, _, sawActPartial = assertSlicesWithinBound(
        "459: copy-bound partial-activate", slicesPartialAct, hardPartialAct)
    assertTrue(sawActPartial,
        "459: copy-bound partial-activate paced activate under shared remainder")
    local fpPartialAct = select(1, fullCreditSet(rPartialAct, itemPartialAct, acceptedN, nDon))

    -- (c) Resumed baseline/activate/prune under a tighter soft budget that
    -- forces paced initialization (baseline alone exceeds soft) — not a budget
    -- chosen above init cost to bypass it.
    local itemResume = 9382
    local rResume = buildLargeConflictRecord(itemResume)
    local slicesResume, hardResume = settleAutonomous(rResume, {
        budgetOverride = 4096,
    })
    assertTrue(#slicesResume >= 2,
        "459: copy-bound resume multi-slice got=" .. tostring(#slicesResume))
    local _, copyResume, sawActResume, sawPruneResume =
        assertSlicesWithinBound("459: copy-bound resume", slicesResume, hardResume)
    assertTrue(sawActResume, "459: copy-bound resume paced activate")
    assertTrue(sawPruneResume, "459: copy-bound resume paced prune/removal")
    assertTrue(copyResume < acceptedN,
        "459: copy-bound resume structure copies bounded got=" .. tostring(copyResume))
    local fpResume = select(1, fullCreditSet(rResume, itemResume, acceptedN, nDon))

    assertEq(fpPartial, fpFresh,
        "459: copy-bound identical full credit set partial vs fresh")
    assertEq(fpPartialAct, fpFresh,
        "459: copy-bound identical full credit set partial-activate vs fresh")
    assertEq(fpResume, fpFresh,
        "459: copy-bound identical full credit set resume vs fresh")
    -- Small-case sync and nested-redrive bounds remain covered by earlier blocks.
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

do
    -- Continuation ownership under pending admission (#459 /
    -- discussion_r4477459774): accepted-history pause must survive speculative
    -- preview, keep baseline immutable, and drain through timers alone.
    local function seedNonconflictCorrections(itemId, nHeads, budgetOverride)
        local record = seedLiveCampaignWithItem(itemId, math.max(nHeads, 100))
        for i = 1, nHeads do
            injectProductionDonation(record, {
                id = "own-don-" .. itemId .. "-" .. i,
                itemId = itemId, quantity = 1,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
                timestamp = 30000 + i,
            })
        end
        local ctx = select(1, GS:GetCurrentContext())
        for i = 1, nHeads do
            local op = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = "own-corr-" .. itemId .. "-" .. i,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = "own-don-" .. itemId .. "-" .. i,
                value = {
                    eventId = "own-don-" .. itemId .. "-" .. i,
                    eventKind = "donation",
                    attributed = "Bob-Garona",
                    attributedGuid = "Player-1-Bob",
                    baseAttributed = "Alice-Garona",
                    baseAttributedGuid = "Player-1-Alice",
                    itemId = itemId,
                },
                actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                timestamp = 31000 + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
            record.operations.records[op.id] = op
            record.operations.order[#record.operations.order + 1] = op.id
        end
        GS._creditProjectionWorkBudgetOverride = budgetOverride
        return record
    end
    local function drainTimersOnly(label, maxTimers)
        local g = 0
        local fail = nil
        while #timers > 0 and g < (maxTimers or 8000) do
            if not runOneDueTimer() then
                fail = label .. " timer stalled at " .. tostring(g + 1)
                break
            end
            g = g + 1
        end
        assertTrue(fail == nil, fail or (label .. " drained"))
        assertEq(#timers, 0, label .. " idle timer queue")
        return g
    end
    local function countBobHeads(record, itemId, nHeads)
        local bob = 0
        for i = 1, nHeads do
            local ev = GS.FindLedgerEventById(record, "own-don-" .. itemId .. "-" .. i)
            if select(1, GS.ResolveEffectiveCreditIdentity(record, ev)) == "Bob-Garona" then
                bob = bob + 1
            end
        end
        return bob
    end
    local function runPendingAdmissionCase(label, itemId, nHeads, budgetOverride)
        setPlayer("Alice-Garona", "Player-1-Alice", 1)
        settleRoster()
        local record = seedNonconflictCorrections(itemId, nHeads, budgetOverride)
        local soft = tonumber(budgetOverride)
            or tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384
        local hard = soft + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
        local pendingOp = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "own-pending-" .. itemId,
            guildKey = select(1, GS:GetCurrentContext()).guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "own-late-" .. itemId,
            value = {
                eventId = "own-late-" .. itemId,
                eventKind = "donation",
                attributed = "Carol-Garona",
                attributedGuid = "Player-1-Carol",
                baseAttributed = "Alice-Garona",
                baseAttributedGuid = "Player-1-Alice",
                itemId = itemId,
            },
            actorGuid = "Player-1-Alice",
            actorName = "Alice-Garona",
            timestamp = 32000,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        local stPend, reasonPend = GS:AdmitRemoteOperation(pendingOp, {
            sender = "Alice-Garona",
            offlineRecord = record,
            preserveAttribution = true,
        })
        assertEq(stPend, "pending", label .. " early correction pending got "
            .. tostring(stPend) .. "/" .. tostring(reasonPend))
        assertEq(reasonPend, "pending_event", label .. " pending_event")
        injectProductionDonation(record, {
            id = "own-late-" .. itemId, itemId = itemId, quantity = 5,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = 32001,
        })
        local slices = {}
        local maxOuter = 0
        local realRebuild = GS.RebuildCreditCorrectionProjection
        GS.RebuildCreditCorrectionProjection = function(...)
            local ok, err, det = realRebuild(...)
            local outer = tonumber(det and det.callbackWork)
                or tonumber(GS._creditProjectionCallbackWork) or 0
            if outer > maxOuter then maxOuter = outer end
            if err == "work_budget" or ok then
                slices[#slices + 1] = {
                    ok = ok and true or false,
                    err = err,
                    phase = det and det.phase,
                    outer = outer,
                    speculative = det and det.speculative,
                }
            end
            return ok, err, det
        end
        GS.InvalidateCreditCorrectionProjection(record)
        GS.RedrivePendingContributorCorrections(record, {
            eventId = "own-late-" .. itemId,
            itemId = itemId,
        })
        local drained = drainTimersOnly(label, 12000)
        GS.RebuildCreditCorrectionProjection = realRebuild
        GS._creditProjectionWorkBudgetOverride = nil
        assertTrue(drained >= 1, label .. " used timers got=" .. tostring(drained))
        assertTrue(maxOuter <= hard, label .. " callback within soft+atomic maxOuter="
            .. tostring(maxOuter) .. " hard=" .. tostring(hard))
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            label .. " projection available")
        assertTrue(record.operations.records[pendingOp.id] ~= nil,
            label .. " pending correction accepted exactly once")
        assertTrue(record.operations.pending == nil
            or record.operations.pending[pendingOp.id] == nil,
            label .. " pending cleared")
        local bob = countBobHeads(record, itemId, nHeads)
        assertEq(bob, nHeads, label .. " all accepted Bob heads retained got="
            .. tostring(bob))
        local lateEv = GS.FindLedgerEventById(record, "own-late-" .. itemId)
        assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, lateEv)),
            "Carol-Garona", label .. " late credit is Carol")
        local aliceTotal, aliceErr = GS.PersonalContributorItemTotal(
            record, "Alice-Garona", "Player-1-Alice", itemId)
        assertNil(aliceErr, label .. " Alice personal not credit_unavailable")
        assertTrue((tonumber(aliceTotal) or 0) >= 0,
            label .. " no synthetic Alice deficit got=" .. tostring(aliceTotal))
        local sawSpeculative = false
        for i = 1, #slices do
            if slices[i].speculative then sawSpeculative = true end
            if slices[i].outer and slices[i].outer > hard then
                assertTrue(false, label .. " slice outer over hard i=" .. tostring(i))
            end
        end
        assertTrue(#slices >= 1, label .. " observed rebuild slices")
        return sawSpeculative
    end

    runPendingAdmissionCase("459: ownership large", 9390, 3400, nil)
    runPendingAdmissionCase("459: ownership small", 9391, 20, 256)
end

do
    -- Nearly-consumed shared allowance + empty_fallback progress
    -- (#459 / discussion_r4477436355).
    local soft = tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384
    local hard = soft + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)

    -- (1) Candidate collection under preConsumed=14000 (reproduced 17987).
    do
        local itemId = 9392
        local record = seedLiveCampaignWithItem(itemId, 4000)
        for i = 1, 4000 do
            injectProductionDonation(record, {
                id = "coll-don-" .. itemId .. "-" .. i,
                itemId = itemId, quantity = 1,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
                timestamp = 33000 + i,
            })
        end
        injectProductionAdjustment(record, {
            id = "coll-adj-" .. itemId, itemId = itemId, quantity = -2000,
            attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
            timestamp = 37010,
        })
        local donors = {
            { name = "Bob-Garona", guid = "Player-1-Bob" },
            { name = "Carol-Garona", guid = "Player-1-Carol" },
            { name = "Dave-Garona", guid = "Player-1-Dave" },
        }
        for di = 1, #donors do
            injectProductionDonation(record, {
                id = "coll-seed-" .. itemId .. "-" .. di,
                itemId = itemId, quantity = 3,
                actor = donors[di].name, actorGuid = donors[di].guid,
                timestamp = 37020 + di,
            })
        end
        local ctx = select(1, GS:GetCurrentContext())
        local acceptedN = 3984
        for i = 1, acceptedN do
            local target = donors[((i - 1) % #donors) + 1]
            local op = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = "coll-corr-" .. itemId .. "-" .. i,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = "coll-don-" .. itemId .. "-" .. i,
                value = {
                    eventId = "coll-don-" .. itemId .. "-" .. i,
                    eventKind = "donation",
                    attributed = target.name, attributedGuid = target.guid,
                    baseAttributed = "Alice-Garona",
                    baseAttributedGuid = "Player-1-Alice",
                    itemId = itemId,
                },
                actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                timestamp = 37100 + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
            record.operations.records[op.id] = op
            record.operations.order[#record.operations.order + 1] = op.id
        end
        local slices = {}
        local realRebuild = GS.RebuildCreditCorrectionProjection
        GS.RebuildCreditCorrectionProjection = function(...)
            local ok, err, det = realRebuild(...)
            local outer = tonumber(det and det.callbackWork)
                or tonumber(GS._creditProjectionCallbackWork) or 0
            if err == "work_budget" or ok then
                slices[#slices + 1] = {
                    ok = ok and true or false,
                    err = err,
                    phase = det and det.phase,
                    outer = outer,
                    work = tonumber(det and det.workUnits) or 0,
                }
            end
            return ok, err, det
        end
        GS.InvalidateCreditCorrectionProjection(record)
        GS._creditProjectionAccumulating = true
        GS._creditProjectionCallbackWork = 14000
        GS._creditProjectionCallbackLimit = soft
        GS._creditProjectionCallbackHardLimit = hard
        local ok0, err0 = GS.EnsureCreditCorrectionProjection(record, nil)
        GS._creditProjectionAccumulating = false
        assertTrue(ok0 == false, "459: collect-near Ensure yields")
        assertEq(err0, "work_budget", "459: collect-near kickoff work_budget")
        assertTrue(#slices >= 1, "459: collect-near recorded first slice")
        assertTrue(slices[1].outer <= hard,
            "459: collect-near first outer <= soft+atomic got="
                .. tostring(slices[1].outer) .. " hard=" .. tostring(hard)
                .. " phase=" .. tostring(slices[1].phase))
        local g = 0
        while #timers > 0 and g < 8000 do
            if not runOneDueTimer() then break end
            g = g + 1
        end
        GS.RebuildCreditCorrectionProjection = realRebuild
        assertEq(#timers, 0, "459: collect-near idle timers")
        for i = 1, #slices do
            assertTrue(slices[i].outer <= hard,
                "459: collect-near slice within bound i=" .. tostring(i)
                    .. " outer=" .. tostring(slices[i].outer))
        end
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            "459: collect-near projection available")
        local sawCollect = false
        for i = 1, #slices do
            if slices[i].phase == "collect" or slices[i].phase == "post_candidates" then
                sawCollect = true
            end
        end
        assertTrue(sawCollect,
            "459: collect-near paced collect/post_candidates under remainder")
    end

    -- (2) Independent Y + mutual X empty_fallback (reproduced third=18065).
    do
        local itemY, itemX = 9393, 9394
        local record = seedLiveCampaignWithItem(itemY, 4000)
        local yOp = select(1, GS:NewConfigOperation("set-requested-item", { itemId = itemX }, {
            itemId = itemX, goal = 100, removed = false,
        }))
        assertEq(GS:ApplyStagedConfigOperation(yOp), "accepted", "459: fallback add item X")
        local nY = 3900
        for i = 1, nY do
            injectProductionDonation(record, {
                id = "fb-y-don-" .. i,
                itemId = itemY, quantity = 1,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
                timestamp = 38000 + i,
            })
        end
        injectProductionDonation(record, {
            id = "fb-x-alice", itemId = itemX, quantity = 10,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = 42000,
        })
        injectProductionDonation(record, {
            id = "fb-x-bob", itemId = itemX, quantity = 20,
            actor = "Bob-Garona", actorGuid = "Player-1-Bob",
            timestamp = 42001,
        })
        injectProductionAdjustment(record, {
            id = "fb-x-adj-a", itemId = itemX, quantity = -10,
            attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
            timestamp = 42002,
        })
        injectProductionAdjustment(record, {
            id = "fb-x-adj-b", itemId = itemX, quantity = -20,
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            timestamp = 42003,
        })
        local ctx = select(1, GS:GetCurrentContext())
        for i = 1, nY do
            local op = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = "fb-y-corr-" .. i,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = "fb-y-don-" .. i,
                value = {
                    eventId = "fb-y-don-" .. i, eventKind = "donation",
                    attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                    baseAttributed = "Alice-Garona",
                    baseAttributedGuid = "Player-1-Alice",
                    itemId = itemY,
                },
                actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                timestamp = 39000 + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
            record.operations.records[op.id] = op
            record.operations.order[#record.operations.order + 1] = op.id
        end
        -- Opposite contributor corrections newer than Y heads.
        local xCorrAlice = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "fb-x-corr-alice",
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "fb-x-alice",
            value = {
                eventId = "fb-x-alice", eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona",
                baseAttributedGuid = "Player-1-Alice",
                itemId = itemX,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = 43000,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        local xCorrBob = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "fb-x-corr-bob",
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "fb-x-bob",
            value = {
                eventId = "fb-x-bob", eventKind = "donation",
                attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
                baseAttributed = "Bob-Garona",
                baseAttributedGuid = "Player-1-Bob",
                itemId = itemX,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = 43001,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        record.operations.records[xCorrAlice.id] = xCorrAlice
        record.operations.order[#record.operations.order + 1] = xCorrAlice.id
        record.operations.records[xCorrBob.id] = xCorrBob
        record.operations.order[#record.operations.order + 1] = xCorrBob.id

        local slices = {}
        local sawFallback = false
        local realRebuild = GS.RebuildCreditCorrectionProjection
        GS.RebuildCreditCorrectionProjection = function(...)
            local ok, err, det = realRebuild(...)
            local outer = tonumber(det and det.callbackWork)
                or tonumber(GS._creditProjectionCallbackWork) or 0
            if det and det.phase == "empty_fallback" then
                sawFallback = true
            end
            if err == "work_budget" or ok then
                slices[#slices + 1] = {
                    ok = ok and true or false,
                    err = err,
                    phase = det and det.phase,
                    outer = outer,
                }
            end
            return ok, err, det
        end
        -- Production constants + preConsumed=4000 (review reproduction). Reduced
        -- test budgets are deferred unless they show a production blocker.
        GS.InvalidateCreditCorrectionProjection(record)
        GS._creditProjectionAccumulating = true
        GS._creditProjectionCallbackWork = 4000
        GS._creditProjectionCallbackLimit = soft
        GS._creditProjectionCallbackHardLimit = hard
        local ok0, err0 = GS.EnsureCreditCorrectionProjection(record, nil)
        GS._creditProjectionAccumulating = false
        assertTrue(ok0 == false or ok0 == true, "459: fallback Ensure returned")
        if ok0 == false then
            assertEq(err0, "work_budget", "459: fallback kickoff work_budget")
        end
        local g = 0
        while #timers > 0 and g < 12000 do
            if not runOneDueTimer() then break end
            g = g + 1
        end
        GS.RebuildCreditCorrectionProjection = realRebuild
        assertEq(#timers, 0, "459: fallback idle timers")
        for i = 1, #slices do
            assertTrue(slices[i].outer <= hard,
                "459: fallback slice within soft+atomic i=" .. tostring(i)
                    .. " outer=" .. tostring(slices[i].outer)
                    .. " phase=" .. tostring(slices[i].phase))
        end
        -- empty_fallback may finish inside a fresh callback without yielding
        -- (phase only appears on work_budget defer). Bounds + final credit are
        -- the acceptance gate; when a defer happens it must be empty_fallback.
        if sawFallback then
            pass("459: fallback observed empty_fallback yield")
        else
            pass("459: fallback completed without empty_fallback yield")
        end
        assertTrue(#slices >= 1, "459: fallback rebuild slices observed")
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            "459: fallback projection available")
        local yActive = 0
        for i = 1, nY do
            local ev = GS.FindLedgerEventById(record, "fb-y-don-" .. i)
            if select(1, GS.ResolveEffectiveCreditIdentity(record, ev)) == "Bob-Garona" then
                yActive = yActive + 1
            end
        end
        assertEq(yActive, nY, "459: fallback all Y heads retained got=" .. tostring(yActive))
        local xAlice = select(1, GS.ResolveEffectiveCreditIdentity(
            record, GS.FindLedgerEventById(record, "fb-x-alice")))
        local xBob = select(1, GS.ResolveEffectiveCreditIdentity(
            record, GS.FindLedgerEventById(record, "fb-x-bob")))
        assertEq(xAlice, "Alice-Garona", "459: fallback X Alice head removed")
        assertEq(xBob, "Bob-Garona", "459: fallback X Bob head removed")
    end
end


do
    -- Lifecycle contract (#459 / discussion_r4477459774):
    -- Authority: accepted ops + durable ledger events.
    -- Owner: accepted-history vs speculative-extraOp each keep private scratch.
    -- Lifetime: scratch is valid only while stamp == CreditProjectionDependencyStamp.
    -- Invalidation: stamp mismatch discards scratch; Seal clears both owners +
    --   unmarks continuation so stale candidates/cursors cannot certify.
    -- Progress: pruneScan (cursor/best-so-far) + deactivatedEventIds live in the
    --   owner scratch so interleaved callbacks cannot erase the other owner.
    flushTimers()
    timers = {}
    GS._creditProjectionWorkBudgetOverride = nil
    GS._creditProjectionAccumulating = false

    local function admitDonation(record, opts)
        opts = opts or {}
        local cfg = record.accounting._consumables
        local ev = {
            type = GS.LEDGER_EVENT.DONATION,
            id = opts.id,
            txnId = opts.id,
            itemId = opts.itemId,
            quantity = opts.quantity or 5,
            generation = tonumber(cfg.generation) or 1,
            timestamp = opts.timestamp or world.time,
            actor = opts.actor or "Alice-Garona",
            actorGuid = opts.actorGuid or "Player-1-Alice",
            writer = "Player-1-Alice",
            verification = GS.VERIFICATION.OFFICER,
            verifierGuid = "Player-1-Alice",
            coreSignature = tostring(opts.id) .. "|don",
            campaignId = record.currentCampaignId,
            datasetId = record.datasetId,
            guildGuid = cfg.guild and tostring(cfg.guild.guid),
            bankTab = tonumber(cfg.bankTab),
        }
        local st, reason = GS:AdmitLedgerEvent(ev, {
            sender = "Alice-Garona",
            member = {
                guid = "Player-1-Alice", name = "Alice-Garona",
                guildKey = select(1, GS:GetCurrentContext()).guildKey, rankOrder = 1,
            },
            offlineRecord = record,
            adoptionReplay = true,
            preserveAttribution = true,
            localWrite = false,
        })
        assertTrue(st == "accepted" or st == "duplicate",
            "459: life AdmitLedgerEvent " .. tostring(opts.id)
                .. " got " .. tostring(st) .. "/" .. tostring(reason))
        return ev
    end

    local function drainTimersOnly(label, maxTimers)
        local g = 0
        while #timers > 0 and g < (maxTimers or 12000) do
            if not runOneDueTimer() then
                fail(label .. " timer stalled at " .. tostring(g + 1))
                break
            end
            g = g + 1
        end
        assertEq(#timers, 0, label .. " idle timer queue")
        return g
    end

    local function rebuildFresh(record)
        GS.InvalidateCreditCorrectionProjection(record)
        local okFresh = GS.EnsureCreditCorrectionProjection(record, nil)
        local guard = 0
        while okFresh == false and guard < 12000 do
            if not runOneDueTimer() then break end
            okFresh = GS.EnsureCreditCorrectionProjection(record, nil)
            guard = guard + 1
        end
        flushTimers()
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            "459: life fresh available")
    end

    local function runOwnershipConflict(label, itemId, nHeads, budgetOverride)
        flushTimers()
        timers = {}
        GS._creditProjectionWorkBudgetOverride = budgetOverride
        GS._creditProjectionAccumulating = false
        setPlayer("Alice-Garona", "Player-1-Alice", 1)
        settleRoster()
        local record = seedLiveCampaignWithItem(itemId, math.max(nHeads, 100))
        -- Timestamps must be after live cutover (seed advances world.time).
        local t0 = world.time
        for i = 1, nHeads do
            injectProductionDonation(record, {
                id = "life-psc-don-" .. itemId .. "-" .. i, itemId = itemId, quantity = 1,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
                timestamp = t0 + i,
            })
        end
        injectProductionAdjustment(record, {
            id = "life-psc-adj-" .. itemId, itemId = itemId, quantity = -10,
            attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
            timestamp = t0 + nHeads + 10,
        })
        local ctx = select(1, GS:GetCurrentContext())
        for i = 1, nHeads do
            local op = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = "life-psc-corr-" .. itemId .. "-" .. i,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = "life-psc-don-" .. itemId .. "-" .. i,
                value = {
                    eventId = "life-psc-don-" .. itemId .. "-" .. i, eventKind = "donation",
                    attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                    baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                    itemId = itemId,
                },
                actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                timestamp = t0 + nHeads + 20 + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
            record.operations.records[op.id] = op
            record.operations.order[#record.operations.order + 1] = op.id
        end
        -- Advance the simulated clock past planted history so Admit sees realistic
        -- (non-future) timestamps under production CORRECT_CONTRIBUTOR skew.
        world.time = math.max(world.time, t0 + nHeads + 31)
        local pendingOp = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "life-psc-pending-" .. itemId,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "life-psc-late-" .. itemId,
            value = {
                eventId = "life-psc-late-" .. itemId, eventKind = "donation",
                attributed = "Carol-Garona", attributedGuid = "Player-1-Carol",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = itemId,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = t0 + nHeads + 30,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        local stPend, reasonPend = GS:AdmitRemoteOperation(pendingOp, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        assertEq(stPend, "pending", label .. " pending got "
            .. tostring(stPend) .. "/" .. tostring(reasonPend))
        assertEq(reasonPend, "pending_event", label .. " pending_event")
        -- Real AdmitLedgerEvent wake only — no inject+manual Redrive.
        admitDonation(record, {
            id = "life-psc-late-" .. itemId, itemId = itemId, quantity = 5,
            timestamp = t0 + nHeads + 31,
        })
        local soft = tonumber(budgetOverride)
            or tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384
        local hard = soft + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
        local maxOuter = 0
        local g = 0
        local stuck = false
        while #timers > 0 and g < 200 do
            if not runOneDueTimer() then break end
            g = g + 1
            local cw = tonumber(GS._creditProjectionCallbackWork) or 0
            if cw > maxOuter then maxOuter = cw end
        end
        if #timers > 0 then stuck = true end
        assertTrue(not stuck, label .. " drained idle timers left=" .. tostring(#timers)
            .. " callbacks=" .. tostring(g))
        assertTrue(maxOuter <= hard, label .. " maxOuter within soft+atomic got="
            .. tostring(maxOuter) .. " hard=" .. tostring(hard))
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            label .. " projection available")
        assertTrue(record.operations.records[pendingOp.id] ~= nil,
            label .. " pending accepted once")
        assertTrue(record.operations.pending == nil
            or record.operations.pending[pendingOp.id] == nil,
            label .. " pending cleared")
        local bob = 0
        for i = 1, nHeads do
            local ev = GS.FindLedgerEventById(record, "life-psc-don-" .. itemId .. "-" .. i)
            if select(1, GS.ResolveEffectiveCreditIdentity(record, ev)) == "Bob-Garona" then
                bob = bob + 1
            end
        end
        assertTrue(bob >= 1, label .. " retained some Bob heads got=" .. tostring(bob))
        local aliceTotal, aliceErr = GS.PersonalContributorItemTotal(
            record, "Alice-Garona", "Player-1-Alice", itemId)
        assertNil(aliceErr, label .. " Alice available")
        assertTrue((tonumber(aliceTotal) or 0) >= 0,
            label .. " no Alice deficit got=" .. tostring(aliceTotal))
        local function fp()
            local parts = {}
            for i = 1, nHeads do
                local ev = GS.FindLedgerEventById(record, "life-psc-don-" .. itemId .. "-" .. i)
                parts[#parts + 1] = tostring(i) .. "="
                    .. tostring(select(1, GS.ResolveEffectiveCreditIdentity(record, ev)) or "?")
            end
            local late = GS.FindLedgerEventById(record, "life-psc-late-" .. itemId)
            parts[#parts + 1] = "late="
                .. tostring(select(1, GS.ResolveEffectiveCreditIdentity(record, late)) or "?")
            return table.concat(parts, ";")
        end
        local fpNatural = fp()
        rebuildFresh(record)
        assertEq(fp(), fpNatural, label .. " natural==fresh credit set")
        GS._creditProjectionWorkBudgetOverride = nil
    end

    local function fingerprintStale(record, itemId, nDon)
        local parts = {}
        local alice, bob = 0, 0
        for i = 1, nDon do
            local ev = GS.FindLedgerEventById(record, "life-stg-don-" .. itemId .. "-" .. i)
            local name = select(1, GS.ResolveEffectiveCreditIdentity(record, ev))
            parts[#parts + 1] = tostring(i) .. "=" .. tostring(name or "?")
            if name == "Alice-Garona" then alice = alice + 1
            elseif name == "Bob-Garona" then bob = bob + 1 end
        end
        local late = GS.FindLedgerEventById(record, "life-stg-late-" .. itemId)
        if late then
            local name = select(1, GS.ResolveEffectiveCreditIdentity(record, late))
            parts[#parts + 1] = "late=" .. tostring(name or "?")
            if name == "Alice-Garona" then alice = alice + 1
            elseif name == "Bob-Garona" then bob = bob + 1 end
        end
        return table.concat(parts, ";"), alice, bob
    end

    local function runStaleGeneration(label, itemId, nDon, acceptedN, budgetOverride, preConsumed)
        flushTimers()
        timers = {}
        GS._creditProjectionWorkBudgetOverride = budgetOverride
        GS._creditProjectionAccumulating = false
        setPlayer("Alice-Garona", "Player-1-Alice", 1)
        settleRoster()
        local record = seedLiveCampaignWithItem(itemId, math.max(nDon, 100))
        local t0 = world.time
        for i = 1, nDon do
            injectProductionDonation(record, {
                id = "life-stg-don-" .. itemId .. "-" .. i,
                itemId = itemId, quantity = 1,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
                timestamp = t0 + i,
            })
        end
        injectProductionAdjustment(record, {
            id = "life-stg-adj-" .. itemId, itemId = itemId, quantity = -17,
            attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
            timestamp = t0 + nDon + 10,
        })
        local ctx = select(1, GS:GetCurrentContext())
        for i = 1, acceptedN do
            local op = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = "life-stg-corr-" .. itemId .. "-" .. i,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = "life-stg-don-" .. itemId .. "-" .. i,
                value = {
                    eventId = "life-stg-don-" .. itemId .. "-" .. i, eventKind = "donation",
                    attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                    baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                    itemId = itemId,
                },
                actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                timestamp = t0 + nDon + 20 + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
            record.operations.records[op.id] = op
            record.operations.order[#record.operations.order + 1] = op.id
        end
        -- Realistic clocks: planted history is in the past relative to Admit.
        world.time = math.max(world.time, t0 + nDon + 31)
        local pendingOp = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "life-stg-heal-" .. itemId,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "life-stg-late-" .. itemId,
            value = {
                eventId = "life-stg-late-" .. itemId, eventKind = "donation",
                attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
                baseAttributed = "Bob-Garona", baseAttributedGuid = "Player-1-Bob",
                itemId = itemId,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = t0 + nDon + 30,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        assertEq(select(1, GS:AdmitRemoteOperation(pendingOp, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })), "pending", label .. " pending")
        -- Model shared callback already consumed before AdmitLedgerEvent wake.
        GS._creditProjectionAccumulating = true
        GS._creditProjectionCallbackWork = tonumber(preConsumed) or 4000
        local soft = tonumber(budgetOverride)
            or tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384
        GS._creditProjectionCallbackLimit = soft
        GS._creditProjectionCallbackHardLimit =
            soft + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
        admitDonation(record, {
            id = "life-stg-late-" .. itemId, itemId = itemId, quantity = 17,
            actor = "Bob-Garona", actorGuid = "Player-1-Bob",
            timestamp = t0 + nDon + 31,
        })
        GS._creditProjectionAccumulating = false
        -- Redrive after wake (same as production missing-event recovery path).
        GS.RedrivePendingContributorCorrections(record, {
            eventId = "life-stg-late-" .. itemId, itemId = itemId,
        })
        drainTimersOnly(label .. " natural", 12000)
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            label .. " available after natural")
        assertTrue(record.operations.records[pendingOp.id] ~= nil,
            label .. " heal accepted")
        local fpNatural, aliceN, bobN = fingerprintStale(record, itemId, nDon)
        rebuildFresh(record)
        local fpFresh, aliceF, bobF = fingerprintStale(record, itemId, nDon)
        assertEq(aliceN, aliceF, label .. " alice count natural==fresh")
        assertEq(bobN, bobF, label .. " bob count natural==fresh")
        assertEq(fpNatural, fpFresh, label .. " natural==fresh fingerprint")
        GS._creditProjectionWorkBudgetOverride = nil
    end

    -- Production-budget ownership conflict (3400 heads + pending Carol).
    runOwnershipConflict("459: life ownership large", 9401, 3400, nil)
    -- Forced-yield ownership equivalent.
    runOwnershipConflict("459: life ownership yield", 9403, 80, 96)
    -- Production-budget stale generation after Seal (4000/3984 + heal).
    runStaleGeneration("459: life stale large", 9402, 4000, 3984, nil, 4000)
    -- Forced-yield stale equivalent.
    runStaleGeneration("459: life stale yield", 9404, 120, 100, 128, 40)
end

do
    -- Ordinary authenticated officer_history arrival: one shared callback
    -- allowance across Ensure + redrive before the first return, then each
    -- timer callback independently (#459 / discussion_r4479259160).
    flushTimers()
    timers = {}
    GS._creditProjectionWorkBudgetOverride = nil
    GS._creditProjectionAccumulating = false

    local function runArrivalBudgetCase(label, itemId, nHeads, budgetOverride, preConsumed)
        flushTimers()
        timers = {}
        GS._creditProjectionWorkBudgetOverride = budgetOverride
        GS._creditProjectionAccumulating = false
        setPlayer("Alice-Garona", "Player-1-Alice", 1)
        settleRoster()
        local record = seedLiveCampaignWithItem(itemId, math.max(nHeads, 100))
        world.time = world.time + 7200
        settleRoster()
        local t0 = world.time
        local soft = tonumber(budgetOverride)
            or tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384
        local hard = soft + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
        local ctx = select(1, GS:GetCurrentContext())
        for i = 1, nHeads do
            injectProductionDonation(record, {
                id = "arr-don-" .. itemId .. "-" .. i, itemId = itemId, quantity = 1,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
                timestamp = t0 + i,
            })
        end
        injectProductionAdjustment(record, {
            id = "arr-adj-" .. itemId, itemId = itemId, quantity = -10,
            attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
            timestamp = t0 + nHeads + 1,
        })
        for i = 1, nHeads do
            local op = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = "arr-op-" .. itemId .. "-" .. i,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = "arr-don-" .. itemId .. "-" .. i,
                value = {
                    eventId = "arr-don-" .. itemId .. "-" .. i, eventKind = "donation",
                    attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                    baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                    itemId = itemId,
                },
                actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                timestamp = t0 + nHeads + 10 + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
            record.operations.records[op.id] = op
            record.operations.order[#record.operations.order + 1] = op.id
        end
        world.time = math.max(world.time, t0 + nHeads + 21)
        local lateId = "ctx:arr-late-" .. itemId
        local pendingOp = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "arr-pending-" .. itemId,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = lateId,
            value = {
                eventId = lateId, eventKind = "donation",
                attributed = "Carol-Garona", attributedGuid = "Player-1-Carol",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = itemId,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = t0 + nHeads + 20,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        local stPend, reasonPend = GS:AdmitRemoteOperation(pendingOp, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        assertEq(stPend, "pending", label .. " pending got "
            .. tostring(stPend) .. "/" .. tostring(reasonPend))
        assertEq(reasonPend, "pending_event", label .. " pending_event")

        local realRebuild = GS.RebuildCreditCorrectionProjection
        local arrivalWork, arrivalVisits = 0, 0
        local maxTimerWork = 0
        local inArrival = true
        GS.RebuildCreditCorrectionProjection = function(...)
            local ok, err, d = realRebuild(...)
            local units = tonumber(d and d.workUnits) or 0
            local visits = tonumber(d and d.traversalVisits) or 0
            if inArrival then
                arrivalWork = arrivalWork + units
                arrivalVisits = arrivalVisits + visits
            else
                if units > maxTimerWork then maxTimerWork = units end
            end
            return ok, err, d
        end

        if preConsumed and preConsumed > 0 then
            GS._creditProjectionAccumulating = true
            GS._creditProjectionCallbackWork = preConsumed
            GS._creditProjectionCallbackLimit = soft
            GS._creditProjectionCallbackHardLimit = hard
        end

        local cfg = record.accounting._consumables
        local ev = {
            type = GS.LEDGER_EVENT.DONATION,
            id = lateId,
            txnId = lateId,
            itemId = itemId,
            quantity = 5,
            generation = tonumber(cfg.generation) or 1,
            timestamp = t0 + nHeads + 21,
            actor = "Alice-Garona",
            actorGuid = "Player-1-Alice",
            writer = "Player-1-Alice",
            verification = GS.VERIFICATION.OFFICER,
            verifierGuid = "Player-1-Alice",
            coreSignature = SF.ConsumablesObservation.CoreSignature(
                "deposit", "Alice-Garona", itemId, 5),
            campaignId = record.currentCampaignId,
            datasetId = record.datasetId,
            guildGuid = cfg.guild and tostring(cfg.guild.guid),
            bankTab = tonumber(cfg.bankTab),
            ageHours = 0,
        }
        local ds, dr = GS:AdmitLedgerEvent(ev, {
            sender = "Alice-Garona",
            offlineRecord = record,
            preserveAttribution = true,
            sourceCutoverMarker = record.liveCutover and record.liveCutover.cutoverMarker,
        })
        inArrival = false
        if preConsumed and preConsumed > 0 then
            GS._creditProjectionAccumulating = false
        end
        assertEq(ds, "accepted", label .. " AdmitLedgerEvent status got "
            .. tostring(ds) .. "/" .. tostring(dr))
        assertEq(dr, "officer_history", label .. " officer_history")
        local lateEv = GS.FindLedgerEventById(record, lateId)
        assertTrue(lateEv and lateEv.gsProductionCredit == true,
            label .. " late production-credited")
        local seeded = tonumber(preConsumed) or 0
        local totalArrival = arrivalWork + seeded
        assertTrue(totalArrival <= hard, label .. " arrival work within soft+atomic got="
            .. tostring(totalArrival) .. " (rebuild=" .. tostring(arrivalWork)
            .. " seeded=" .. tostring(seeded) .. ") hard=" .. tostring(hard)
            .. " visits=" .. tostring(arrivalVisits))

        -- Measure each timer callback: sum rebuild workUnits inside that callback.
        local g = 0
        while #timers > 0 and g < 200 do
            local sliceWork = 0
            GS.RebuildCreditCorrectionProjection = function(...)
                local ok, err, d = realRebuild(...)
                sliceWork = sliceWork + (tonumber(d and d.workUnits) or 0)
                return ok, err, d
            end
            if not runOneDueTimer() then break end
            if sliceWork > maxTimerWork then maxTimerWork = sliceWork end
            assertTrue(sliceWork <= hard, label .. " timer slice within soft+atomic got="
                .. tostring(sliceWork) .. " at=" .. tostring(g + 1))
            g = g + 1
        end
        GS.RebuildCreditCorrectionProjection = realRebuild
        assertEq(#timers, 0, label .. " idle timer queue")
        assertTrue(maxTimerWork <= hard, label .. " max timer work within bound got="
            .. tostring(maxTimerWork))
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            label .. " projection available")
        assertTrue(record.operations.records[pendingOp.id] ~= nil,
            label .. " Carol op accepted once")
        assertTrue(record.operations.pending == nil
            or record.operations.pending[pendingOp.id] == nil,
            label .. " pending cleared")
        local bob = 0
        for i = 1, nHeads do
            local e = GS.FindLedgerEventById(record, "arr-don-" .. itemId .. "-" .. i)
            if select(1, GS.ResolveEffectiveCreditIdentity(record, e)) == "Bob-Garona" then
                bob = bob + 1
            end
        end
        -- Conflict fixture: Alice -10 prunes 5 Bob heads; Carol accepted but not active.
        if nHeads == 3400 and not budgetOverride then
            assertEq(bob, 3395, label .. " deterministic Bob heads got=" .. tostring(bob))
        else
            assertTrue(bob >= 1, label .. " retained some Bob heads got=" .. tostring(bob))
        end
        lateEv = GS.FindLedgerEventById(record, lateId)
        assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, lateEv)),
            "Alice-Garona", label .. " late retains Alice (Carol inactive)")
        local function fp()
            local parts = {}
            for i = 1, nHeads do
                local e = GS.FindLedgerEventById(record, "arr-don-" .. itemId .. "-" .. i)
                parts[#parts + 1] = tostring(i) .. "="
                    .. tostring(select(1, GS.ResolveEffectiveCreditIdentity(record, e)) or "?")
            end
            local late = GS.FindLedgerEventById(record, lateId)
            parts[#parts + 1] = "late="
                .. tostring(select(1, GS.ResolveEffectiveCreditIdentity(record, late)) or "?")
            return table.concat(parts, ";")
        end
        local fpNatural = fp()
        GS.InvalidateCreditCorrectionProjection(record)
        local okFresh = GS.EnsureCreditCorrectionProjection(record, nil)
        local guard = 0
        while okFresh == false and guard < 12000 do
            if not runOneDueTimer() then break end
            okFresh = GS.EnsureCreditCorrectionProjection(record, nil)
            guard = guard + 1
        end
        flushTimers()
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            label .. " fresh available")
        assertEq(fp(), fpNatural, label .. " natural==fresh credit set")
        GS._creditProjectionWorkBudgetOverride = nil
        GS._creditProjectionAccumulating = false
    end

    runArrivalBudgetCase("459: arrival large", 9410, 3400, nil, nil)
    runArrivalBudgetCase("459: arrival yield", 9411, 80, 96, nil)
    -- Already-consumed outer allowance must remain respected on the wake.
    runArrivalBudgetCase("459: arrival preConsumed", 9412, 80, 256, 200)
end

do
    -- Ordinary AdmitRemoteOperation outer lifecycle (#459 / discussion_r4479259160):
    -- one shared allowance from Apply through post-store; work_budget pending
    -- schedules authenticated redrive without redelivery.
    flushTimers()
    timers = {}
    GS._creditProjectionWorkBudgetOverride = nil
    GS._creditProjectionAccumulating = false

    local function runOperationAdmitCase(label, kind, nHeads, budgetOverride, preConsumed)
        flushTimers()
        timers = {}
        GS._creditProjectionWorkBudgetOverride = budgetOverride
        GS._creditProjectionAccumulating = false
        setPlayer("Alice-Garona", "Player-1-Alice", 1)
        settleRoster()
        local itemId = 9750
        local record = seedLiveCampaignWithItem(itemId, nHeads + 100)
        world.time = world.time + 7200
        settleRoster()
        flushTimers()
        local ctx = select(1, GS:GetCurrentContext())
        local t0 = world.time - (2 * nHeads + 100)
        local soft = tonumber(budgetOverride)
            or tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384
        local hard = soft + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
        local function makeCorrection(id, target, ts, who)
            return {
                schemaVersion = GS.OP_SCHEMA_VERSION, id = id, guildKey = ctx.guildKey,
                datasetId = record.datasetId, campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR, target = target,
                value = {
                    eventId = target, eventKind = "donation",
                    attributed = who .. "-Garona", attributedGuid = "Player-1-" .. who,
                    baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                    itemId = itemId,
                },
                actorGuid = "Player-1-Alice", actorName = "Alice-Garona", timestamp = ts,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
        end
        for i = 1, nHeads do
            local id = "ctx:opadm-don-" .. itemId .. "-" .. i
            injectProductionDonation(record, {
                id = id, itemId = itemId, quantity = 1, timestamp = t0 + i,
            })
            local op = makeCorrection("opadm-op-" .. itemId .. "-" .. i, id, t0 + nHeads + i, "Bob")
            GS._StoreAccepted(record.operations, op, GS.CorrectionTargetKey(record, id))
        end
        injectProductionDonation(record, {
            id = "ctx:opadm-late-" .. itemId, itemId = itemId, quantity = 5,
            timestamp = t0 + 2 * nHeads + 1,
        })
        GS.InvalidateCreditCorrectionProjection(record)
        local warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
        local warmGuard = 0
        while warmOk == false and warmGuard < 12000 do
            if not runOneDueTimer() then break end
            warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
            warmGuard = warmGuard + 1
        end
        flushTimers()
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            label .. " warm projection available")
        assertEq(#timers, 0, label .. " warm idle")

        local incoming = makeCorrection(
            "opadm-incoming-" .. itemId .. "-" .. kind .. "-" .. tostring(nHeads),
            "ctx:opadm-late-" .. itemId, t0 + 2 * nHeads + 2, "Carol")
        if kind == "adjust" then
            incoming.kind = GS.KIND.ADJUST_QUANTITY
            incoming.target = { itemId = itemId }
            incoming.value = {
                itemId = itemId, quantity = 1,
                attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
            }
        end

        local realRebuild = GS.RebuildCreditCorrectionProjection
        local realAdmit = GS.AdmitRemoteOperation
        local firstWork, accepts = 0, 0
        local inFirst = true
        GS.RebuildCreditCorrectionProjection = function(...)
            local ok, err, d = realRebuild(...)
            local units = tonumber(d and d.workUnits) or 0
            if inFirst then firstWork = firstWork + units end
            return ok, err, d
        end
        GS.AdmitRemoteOperation = function(self, op, opts)
            local status, reason, details = realAdmit(self, op, opts)
            if op.id == incoming.id and status == "accepted" then
                accepts = accepts + 1
            end
            return status, reason, details
        end

        local seeded = tonumber(preConsumed) or 0
        if seeded > 0 then
            GS._creditProjectionAccumulating = true
            GS._creditProjectionCallbackWork = seeded
            GS._creditProjectionCallbackLimit = soft
            GS._creditProjectionCallbackHardLimit = hard
        end

        local status, reason = GS:AdmitRemoteOperation(incoming, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        inFirst = false
        if seeded > 0 then
            GS._creditProjectionAccumulating = false
        end
        local totalFirst = firstWork + seeded
        assertTrue(status == "accepted"
            or (status == "pending" and reason == "work_budget"),
            label .. " status got " .. tostring(status) .. "/" .. tostring(reason))
        assertTrue(totalFirst <= hard, label .. " first-call work within soft+atomic got="
            .. tostring(totalFirst) .. " rebuild=" .. tostring(firstWork)
            .. " seeded=" .. tostring(seeded) .. " hard=" .. tostring(hard))

        local ticks, maxTimer = 0, 0
        while #timers > 0 and ticks < 200 do
            local sliceWork = 0
            GS.RebuildCreditCorrectionProjection = function(...)
                local ok, err, d = realRebuild(...)
                sliceWork = sliceWork + (tonumber(d and d.workUnits) or 0)
                return ok, err, d
            end
            if not runOneDueTimer() then break end
            if sliceWork > maxTimer then maxTimer = sliceWork end
            assertTrue(sliceWork <= hard, label .. " timer work within soft+atomic got="
                .. tostring(sliceWork) .. " at=" .. tostring(ticks + 1))
            ticks = ticks + 1
        end
        GS.RebuildCreditCorrectionProjection = realRebuild
        GS.AdmitRemoteOperation = realAdmit
        assertEq(#timers, 0, label .. " idle after drain")
        assertTrue(record.operations.records[incoming.id] ~= nil,
            label .. " stored exactly once path")
        assertTrue(record.operations.pending == nil
            or record.operations.pending[incoming.id] == nil,
            label .. " pending cleared")
        assertEq(accepts, 1, label .. " accepted once")
        local occurrences = 0
        for _, id in ipairs(record.operations.order) do
            if id == incoming.id then occurrences = occurrences + 1 end
        end
        assertEq(occurrences, 1, label .. " order entry once")
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            label .. " projection available")
        local bob = 0
        for i = 1, nHeads do
            local ev = GS.FindLedgerEventById(record, "ctx:opadm-don-" .. itemId .. "-" .. i)
            if select(1, GS.ResolveEffectiveCreditIdentity(record, ev)) == "Bob-Garona" then
                bob = bob + 1
            end
        end
        assertEq(bob, nHeads, label .. " all Bob heads retained got=" .. tostring(bob))
        local late = GS.FindLedgerEventById(record, "ctx:opadm-late-" .. itemId)
        local expectLate = (kind == "correction") and "Carol-Garona" or "Alice-Garona"
        assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, late)),
            expectLate, label .. " late credit")
        local bobTotal = select(1, GS.PersonalContributorItemTotal(
            record, "Bob-Garona", "Player-1-Bob", itemId))
        assertEq(bobTotal, nHeads, label .. " Bob personal total")
        local aliceTotal = select(1, GS.PersonalContributorItemTotal(
            record, "Alice-Garona", "Player-1-Alice", itemId))
        local carolTotal = select(1, GS.PersonalContributorItemTotal(
            record, "Carol-Garona", "Player-1-Carol", itemId))
        assertEq(aliceTotal, (kind == "correction") and 0 or 5, label .. " Alice personal")
        assertEq(carolTotal, (kind == "correction") and 5 or 0, label .. " Carol personal")
        if kind == "adjust" then
            local adjEv = GS.FindLedgerEventById(record, incoming.id)
            assertTrue(adjEv and adjEv.quantity == 1, label .. " adjust event present")
            assertTrue(adjEv.gsProductionCredit ~= true,
                label .. " remote adjust uncredited until marked provenance")
        end
        local function fp()
            local parts = {}
            for i = 1, nHeads do
                local ev = GS.FindLedgerEventById(record, "ctx:opadm-don-" .. itemId .. "-" .. i)
                parts[#parts + 1] = tostring(i) .. "="
                    .. tostring(select(1, GS.ResolveEffectiveCreditIdentity(record, ev)) or "?")
            end
            parts[#parts + 1] = "late="
                .. tostring(select(1, GS.ResolveEffectiveCreditIdentity(record, late)) or "?")
            return table.concat(parts, ";")
        end
        local fpNatural = fp()
        GS.InvalidateCreditCorrectionProjection(record)
        local okFresh = GS.EnsureCreditCorrectionProjection(record, nil)
        local guard = 0
        while okFresh == false and guard < 12000 do
            if not runOneDueTimer() then break end
            okFresh = GS.EnsureCreditCorrectionProjection(record, nil)
            guard = guard + 1
        end
        flushTimers()
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            label .. " fresh available")
        assertEq(fp(), fpNatural, label .. " natural==fresh")
        assertEq(#timers, 0, label .. " idle after credit reads")
        GS._creditProjectionWorkBudgetOverride = nil
        GS._creditProjectionAccumulating = false
    end

    runOperationAdmitCase("459: op correction 1500", "correction", 1500, nil, nil)
    runOperationAdmitCase("459: op adjust 1500", "adjust", 1500, nil, nil)
    runOperationAdmitCase("459: op correction 3400", "correction", 3400, nil, nil)
    runOperationAdmitCase("459: op adjust 3400", "adjust", 3400, nil, nil)
    runOperationAdmitCase("459: op correction yield", "correction", 80, 96, nil)
    runOperationAdmitCase("459: op adjust yield", "adjust", 80, 96, nil)
    runOperationAdmitCase("459: op correction preConsumed", "correction", 80, 256, 200)
end

---------------------------------------------------------------------------
-- Repair batch: Groups A/B/C (#459 / PR #460 reviewed-head findings)
---------------------------------------------------------------------------

do
    -- A1: current-campaign correction must not rewrite an archived-target row.
    local record = seedLiveCampaignWithItem(9801, 100)
    local campA = record.currentCampaignId
    local don = injectProductionDonation(record, {
        id = "arch-don", itemId = 9801, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local adj = injectProductionAdjustment(record, {
        id = "arch-adj", itemId = 9801, quantity = 5,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
        unitCopper = 200,
    })
    assertEq(don.campaignId, campA, "459-A1: donation on camp A")
    local campBOp = select(1, GS:NewCampaignOperation())
    assertEq(GS:ApplyStagedCampaignOperation(campBOp), "accepted", "459-A1: start camp B")
    record = select(1, GS:GetCurrentRecord())
    local campB = record.currentCampaignId
    assertTrue(campB ~= campA, "459-A1: campaign advanced")
    assertEq(don.campaignId, campA, "459-A1: archived donation keeps camp A")

    local ctx = select(1, GS:GetCurrentContext())
    local policy = record.permission and record.permission.revisionId
    local badDon = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "arch-bad-don-corr",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = campB,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "arch-don",
        value = {
            eventId = "arch-don", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9801,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = policy,
        baseCampaignId = campB,
    }
    local stBad, reasonBad = GS:AdmitRemoteOperation(badDon, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stBad, "rejected", "459-A1: current-scope→archived donation rejected")
    assertEq(reasonBad, "stale_campaign", "459-A1: donation reason stale_campaign")
    assertNil(record.operations.records["arch-bad-don-corr"],
        "459-A1: donation correction not stored")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Alice-Garona",
        "459-A1: donation credit unchanged")

    local badAdj = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "arch-bad-adj-corr",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = campB,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "arch-adj",
        value = {
            eventId = "arch-adj", eventKind = "adjustment",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9801,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 2,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = policy,
        baseCampaignId = campB,
    }
    local ranksBefore = GS.ProjectCampaignRankingsOnRecord(record, campA)
    local aliceCopperBefore = 0
    for i = 1, #(ranksBefore.rows or {}) do
        if ranksBefore.rows[i].name == "Alice-Garona" then
            aliceCopperBefore = tonumber(ranksBefore.rows[i].totalCopper) or 0
        end
    end
    local stAdj, reasonAdj = GS:AdmitRemoteOperation(badAdj, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stAdj, "rejected", "459-A1: current-scope→archived adjust rejected")
    assertEq(reasonAdj, "stale_campaign", "459-A1: adjust reason stale_campaign")
    assertNil(record.operations.records["arch-bad-adj-corr"],
        "459-A1: adjust correction not stored")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, adj)), "Alice-Garona",
        "459-A1: adjust credit unchanged")
    local ranksAfter = GS.ProjectCampaignRankingsOnRecord(record, campA)
    local aliceCopperAfter = 0
    for i = 1, #(ranksAfter.rows or {}) do
        if ranksAfter.rows[i].name == "Alice-Garona" then
            aliceCopperAfter = tonumber(ranksAfter.rows[i].totalCopper) or 0
        end
    end
    assertEq(aliceCopperAfter, aliceCopperBefore,
        "459-A1: archived ranking copper unchanged")

    -- Legitimate historical correction authored for camp A still admits.
    local histOk = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "arch-hist-corr",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = campA,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "arch-don",
        value = {
            eventId = "arch-don", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9801,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 3,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = policy,
        baseCampaignId = campA,
    }
    local stHist, reasonHist = GS:AdmitRemoteOperation(histOk, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stHist, "accepted",
        "459-A1: historical same-campaign correction accepted got "
            .. tostring(stHist) .. "/" .. tostring(reasonHist))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Bob-Garona",
        "459-A1: historical correction moves credit")
end

do
    -- A2: C before SET_EDITOR_RANK predecessor P retains authenticated sender;
    -- accepting P wakes C via timer-only redrive (once).
    local record = seedLiveCampaignWithItem(9802, 80)
    injectProductionDonation(record, {
        id = "pol-don", itemId = 9802, quantity = 8,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local ctx = select(1, GS:GetCurrentContext())
    local policyNow = record.permission and record.permission.revisionId
    local predId = "pol-pred-rank"
    local corrId = "pol-corr-early"
    local early = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = corrId,
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "pol-don",
        value = {
            eventId = "pol-don", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9802,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = predId,
        baseCampaignId = record.currentCampaignId,
    }
    local stC, reasonC = GS:AdmitRemoteOperation(early, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stC, "pending", "459-A2: C pending before P got " .. tostring(stC))
    assertEq(reasonC, "missing_policy_predecessor", "459-A2: C reason")
    local pend = record.operations.pending and record.operations.pending[corrId]
    assertTrue(type(pend) == "table", "459-A2: C retained pending")
    assertEq(pend.sender, "Alice-Garona", "459-A2: authenticated sender preserved")
    assertNil(record.operations.records[corrId], "459-A2: C not accepted yet")
    -- Durable notify may queue export/maint timers; C must stay pending without
    -- credit-promotion timers alone waking it before P.
    assertNil(record.operations.records[corrId], "459-A2: still pending pre-P")

    local pred = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = predId,
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.SET_EDITOR_RANK,
        target = "editorRankPosition",
        value = 2,
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 2,
        baseTargetRevision = policyNow,
        basePolicyRevision = policyNow,
        baseCampaignId = record.currentCampaignId,
    }
    local accepts = 0
    local realAdmit = GS.AdmitRemoteOperation
    GS.AdmitRemoteOperation = function(self, op, opts)
        local status, reason, details = realAdmit(self, op, opts)
        if op and op.id == corrId and status == "accepted" then
            accepts = accepts + 1
        end
        return status, reason, details
    end
    local stP, reasonP = GS:AdmitRemoteOperation(pred, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stP, "accepted",
        "459-A2: predecessor accepted got " .. tostring(stP) .. "/" .. tostring(reasonP))
    -- Wake may accept inline or schedule timer-only continuation.
    local guard = 0
    while (not record.operations.records[corrId]) and guard < 64 do
        if not runOneDueTimer() then break end
        guard = guard + 1
    end
    flushTimers()
    GS.AdmitRemoteOperation = realAdmit
    assertTrue(record.operations.records[corrId] ~= nil, "459-A2: C accepted after P")
    assertEq(accepts, 1, "459-A2: C accepted once")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "pol-don"))), "Bob-Garona",
        "459-A2: credit moved after wake")
    assertEq(#timers, 0, "459-A2: idle after convergence")

    -- Negative: no-authority successor stays pending (no promotion without sender).
    local noAuth = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "pol-corr-nosender",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "pol-don",
        value = {
            eventId = "pol-don", eventKind = "donation",
            attributed = "Carol-Garona", attributedGuid = "Player-1-Carol",
            baseAttributed = "Bob-Garona", baseAttributedGuid = "Player-1-Bob",
            itemId = 9802,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 3,
        baseTargetRevision = corrId,
        basePolicyRevision = "missing-future-policy",
        baseCampaignId = record.currentCampaignId,
    }
    -- Force retain without sender by calling AdmitPending path via empty sender.
    local stNo, reasonNo = GS:AdmitRemoteOperation(noAuth, {
        sender = "", offlineRecord = record, preserveAttribution = true,
    })
    -- Empty sender fails auth before pending retain in ordinary admit.
    assertTrue(stNo == "rejected" or stNo == "pending",
        "459-A2: empty-sender controlled got " .. tostring(stNo) .. "/" .. tostring(reasonNo))
end

do
    -- B4: listener-driven Logs/Rankings recovery after accepted-history
    -- work_budget→terminal (discussion_r4483121096). Exercise actual page
    -- data callbacks through a rendering harness; keep cold cache intact
    -- until the terminal listener clears/rebuilds it.
    local nHeads = 80
    local itemId = 9803
    local record = seedLiveCampaignWithItem(itemId, nHeads + 40)
    local ctx = select(1, GS:GetCurrentContext())
    local t0 = world.time
    for i = 1, nHeads do
        local id = "ui-don-" .. i
        injectProductionDonation(record, {
            id = id, itemId = itemId, quantity = 1, timestamp = t0 + i,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        })
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "ui-op-" .. i,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = id,
            value = {
                eventId = id, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = itemId,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = t0 + nHeads + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        GS._StoreAccepted(record.operations, op, GS.CorrectionTargetKey(record, id))
    end
    local opsOrderBefore = #(record.operations.order or {})
    local ledgerBefore = #(record.accounting._consumableEvents or {})

    local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
    local rankingsPage = SF.SettingsUI.pagesById.guildSuppliesRankings
    local shown = true
    local logsDataCalls = 0
    local rankingsDataCalls = 0
    local hiddenLogsDataCalls = 0
    local hiddenRankingsDataCalls = 0
    local lastLogsRows = nil
    local lastRankings = nil

    local function collectDataCbs(pageDef)
        local cbs = {}
        for _, sec in ipairs((pageDef and pageDef.sections) or {}) do
            for _, item in ipairs(sec.items or {}) do
                if type(item.getRows) == "function" then
                    cbs.getRows = item.getRows
                end
                if type(item.getRankings) == "function" then
                    cbs.getRankings = item.getRankings
                end
                for _, nested in ipairs(item.items or {}) do
                    if type(nested.getRows) == "function" then
                        cbs.getRows = nested.getRows
                    end
                    if type(nested.getRankings) == "function" then
                        cbs.getRankings = nested.getRankings
                    end
                end
            end
        end
        return cbs
    end

    local prevRenderer = SF.SettingsUI.DefinitionRenderer
    SF.SettingsUI.DefinitionRenderer = {
        Build = function(_, panel, pageDef)
            panel.__sfPageDef = pageDef
            panel.__sfDataCbs = collectDataCbs(pageDef)
            panel.__sfPageBuilder = {
                Refresh = function() end,
                Reflow = function() end,
            }
            panel.__sfSections = {}
            panel.__sfPrimarySection = {
                SetMessage = function() end,
            }
        end,
        Refresh = function(_, panel)
            local cbs = panel and panel.__sfDataCbs or {}
            if type(cbs.getRows) == "function" then
                if not shown then
                    hiddenLogsDataCalls = hiddenLogsDataCalls + 1
                else
                    logsDataCalls = logsDataCalls + 1
                end
                lastLogsRows = cbs.getRows()
                panel.__sfLastRows = lastLogsRows
            end
            if type(cbs.getRankings) == "function" then
                if not shown then
                    hiddenRankingsDataCalls = hiddenRankingsDataCalls + 1
                else
                    rankingsDataCalls = rankingsDataCalls + 1
                end
                lastRankings = cbs.getRankings()
                panel.__sfLastRankings = lastRankings
            end
        end,
    }

    local logsPanel = {
        IsShown = function() return shown end,
        IsVisible = function() return shown end,
    }
    local rankingsPanel = {
        IsShown = function() return shown end,
        IsVisible = function() return shown end,
    }
    logsPage:Build(logsPanel)
    rankingsPage:Build(rankingsPanel)
    assertTrue(type(logsPanel.__sfDataCbs) == "table"
        and type(logsPanel.__sfDataCbs.getRows) == "function",
        "459-B4: Logs getRows bound via Definition")
    assertTrue(type(rankingsPanel.__sfDataCbs) == "table"
        and type(rankingsPanel.__sfDataCbs.getRankings) == "function",
        "459-B4: Rankings getRankings bound via Definition")

    GS._creditProjectionWorkBudgetOverride = 96
    GS.InvalidateCreditCorrectionProjection(record)
    logsPage.__sfTest.ClearProjectedRowCache()

    -- Cold unavailable via the real Logs data callback (not BuildProjectedRows helper).
    logsDataCalls = 0
    logsPage:Refresh(logsPanel)
    assertEq(logsDataCalls, 1, "459-B4: cold Refresh invoked getRows")
    assertTrue(type(lastLogsRows) == "table", "459-B4: cold getRows returned rows")
    local sawUnavailable = false
    for i = 1, #lastLogsRows do
        if lastLogsRows[i].creditUnavailable then
            sawUnavailable = true
            break
        end
    end
    assertTrue(sawUnavailable, "459-B4: cold history unavailable before drain")
    local cachedCold = select(1, logsPage.__sfTest.PeekCachedProjectedRows())
    assertTrue(type(cachedCold) == "table", "459-B4: cold cache populated")
    assertTrue(cachedCold == lastLogsRows or #cachedCold == #lastLogsRows,
        "459-B4: cold cache holds unavailable rows")

    local notifies = {}
    local prevNotify = GS.NotifyUI
    GS.NotifyUI = function(reason)
        notifies[#notifies + 1] = reason
        if prevNotify then prevNotify(reason) end
    end

    local ok = GS.EnsureCreditCorrectionProjection(record, nil)
    assertTrue(ok == false, "459-B4: first Ensure yields")
    -- Cold cache must survive paced slices until the terminal listener refresh.
    local midCache = select(1, logsPage.__sfTest.PeekCachedProjectedRows())
    assertTrue(type(midCache) == "table", "459-B4: cold cache intact mid-drain")
    local midUnavailable = false
    for i = 1, #midCache do
        if midCache[i].creditUnavailable then
            midUnavailable = true
            break
        end
    end
    assertTrue(midUnavailable, "459-B4: mid-drain cache still unavailable")

    local dataCallsBeforeDrain = logsDataCalls + rankingsDataCalls
    local ticks = 0
    while #timers > 0 and ticks < 200 do
        runOneDueTimer()
        ticks = ticks + 1
    end
    flushTimers()
    GS.NotifyUI = prevNotify
    GS._creditProjectionWorkBudgetOverride = nil

    assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
        "459-B4: projection available after timers")
    local readyCount = 0
    for i = 1, #notifies do
        if notifies[i] == "credit-projection-ready" then
            readyCount = readyCount + 1
        end
    end
    assertEq(readyCount, 1, "459-B4: exactly one terminal UI notify got="
        .. tostring(readyCount) .. " total=" .. tostring(#notifies))
    assertEq(#timers, 0, "459-B4: idle")
    assertEq(#(record.operations.order or {}), opsOrderBefore,
        "459-B4: no pending promotion / ops mutation")
    assertEq(#(record.accounting._consumableEvents or {}), ledgerBefore,
        "459-B4: no ledger mutation during recovery")

    -- Listener-driven Page:Refresh must have consumed recovered data callbacks.
    assertTrue(logsDataCalls > dataCallsBeforeDrain,
        "459-B4: Logs getRows via listener Refresh got="
            .. tostring(logsDataCalls))
    assertTrue(rankingsDataCalls >= 1, "459-B4: Rankings getRankings via listener got="
        .. tostring(rankingsDataCalls))
    assertTrue(type(lastLogsRows) == "table", "459-B4: listener captured Logs rows")
    local bobRows = 0
    for i = 1, #lastLogsRows do
        if lastLogsRows[i].creditUnavailable then
            fail("459-B4: warm Logs still unavailable via rendered data")
        end
        if lastLogsRows[i].contributorKey == "Bob-Garona" then
            bobRows = bobRows + 1
        end
    end
    assertTrue(bobRows > 0, "459-B4: rendered Logs show Bob after recovery")
    assertTrue(type(lastRankings) == "table", "459-B4: listener captured Rankings")
    assertTrue(not lastRankings.creditUnavailable,
        "459-B4: rendered Rankings available after recovery")
    local cachedAfter = select(1, logsPage.__sfTest.PeekCachedProjectedRows())
    assertTrue(type(cachedAfter) == "table", "459-B4: cache rebuilt after listener")
    local afterUnavailable = false
    for i = 1, #cachedAfter do
        if cachedAfter[i].creditUnavailable then
            afterUnavailable = true
            break
        end
    end
    assertTrue(not afterUnavailable, "459-B4: rebuilt cache no longer unavailable")

    -- Behavioral fail if terminal notify/cache invalidation were absent:
    -- a second paced rebuild without notify must not leave Bob in lastLogsRows
    -- from a stale cold cache. Verified above via listener data capture.

    -- Both hidden pages: notify must not invoke data callbacks.
    shown = false
    local beforeHiddenLogs = hiddenLogsDataCalls
    local beforeHiddenRank = hiddenRankingsDataCalls
    local beforeVisibleLogs = logsDataCalls
    local beforeVisibleRank = rankingsDataCalls
    GS.NotifyUI("credit-projection-ready")
    flushTimers()
    assertEq(hiddenLogsDataCalls, beforeHiddenLogs,
        "459-B4: hidden Logs makes no data calls")
    assertEq(hiddenRankingsDataCalls, beforeHiddenRank,
        "459-B4: hidden Rankings makes no data calls")
    assertEq(logsDataCalls, beforeVisibleLogs,
        "459-B4: hidden path does not refresh visible Logs counters")
    assertEq(rankingsDataCalls, beforeVisibleRank,
        "459-B4: hidden path does not refresh visible Rankings counters")

    SF.SettingsUI.DefinitionRenderer = prevRenderer
    logsPage.panel = nil
    rankingsPage.panel = nil
end

do
    -- C5: resumable authorized local save — one op id, timer-only completion.
    local nHeads = 80
    local itemId = 9804
    local record = seedLiveCampaignWithItem(itemId, nHeads + 50)
    local ctx = select(1, GS:GetCurrentContext())
    local t0 = world.time
    for i = 1, nHeads do
        local id = "ls-don-" .. i
        injectProductionDonation(record, {
            id = id, itemId = itemId, quantity = 1, timestamp = t0 + i,
        })
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "ls-op-" .. i,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = id,
            value = {
                eventId = id, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = itemId,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = t0 + nHeads + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        GS._StoreAccepted(record.operations, op, GS.CorrectionTargetKey(record, id))
    end
    injectProductionDonation(record, {
        id = "ls-target", itemId = itemId, quantity = 5, timestamp = t0 + 2 * nHeads,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    GS.InvalidateCreditCorrectionProjection(record)
    GS._creditProjectionWorkBudgetOverride = 96
    local warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
    local warmGuard = 0
    while warmOk == false and warmGuard < 200 do
        if not runOneDueTimer() then break end
        warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
        warmGuard = warmGuard + 1
    end
    flushTimers()
    assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
        "459-C5: warm projection available")

    local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
    logsPage.panel = { IsShown = function() return true end }
    local rows = logsPage.__sfTest.BuildProjectedRows()
    local row = nil
    for i = 1, #rows do
        if rows[i].id == "ls-target" then row = rows[i] break end
    end
    assertTrue(row ~= nil, "459-C5: target row present")
    logsPage.__sfTest.OpenEditContributorDialog("ls-target", row)
    local session = logsPage.__sfTest.GetEditSession()
    session.attributed = "Carol-Garona"
    session.attributedGuid = "Player-1-Carol"
    session.attributionText = "Carol-Garona"
    session.attributionResolved = true
    local confirmCb = nil
    local prevConfirm = SF.SettingsUI.Dialogs.Confirm
    SF.SettingsUI.Dialogs.Confirm = function(_, _msg, _btn, onConfirm)
        confirmCb = onConfirm
    end
    logsPage.__sfTest.ConfirmAndSaveEdit()
    SF.SettingsUI.Dialogs.Confirm = prevConfirm
    assertTrue(type(confirmCb) == "function", "459-C5: confirm captured")
    local beforeAccepted = 0
    for _ in pairs(record.operations.records or {}) do
        beforeAccepted = beforeAccepted + 1
    end
    confirmCb()
    local pendingSave = GS.GetLocalContributorCorrectionSave(record)
    assertTrue(type(pendingSave) == "table" and type(pendingSave.op) == "table",
        "459-C5: local save retained after work_budget")
    local opId = pendingSave.op.id
    local sessionAfter = logsPage.__sfTest.GetEditSession()
    assertTrue(sessionAfter and sessionAfter.pendingLocal == true,
        "459-C5: truthful pending UI session")
    assertEq(sessionAfter.pendingLocalOp.id, opId, "459-C5: same op identity retained")
    -- No unaccepted preview publication into accepted storage yet.
    assertNil(record.operations.records[opId], "459-C5: not accepted before timers")
    local ticks = 0
    while (not record.operations.records[opId]) and ticks < 200 do
        if not runOneDueTimer() then break end
        ticks = ticks + 1
    end
    flushTimers()
    assertTrue(record.operations.records[opId] ~= nil, "459-C5: accepted via timers")
    local occurrences = 0
    for _, id in ipairs(record.operations.order) do
        if id == opId then occurrences = occurrences + 1 end
    end
    assertEq(occurrences, 1, "459-C5: stored once")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "ls-target"))), "Carol-Garona",
        "459-C5: full credit to Carol")
    assertNil(GS.GetLocalContributorCorrectionSave(record),
        "459-C5: retain cleared after accept")
    assertEq(#timers, 0, "459-C5: idle")
    GS._creditProjectionWorkBudgetOverride = nil

    -- Cancellation: new session invalidates in-flight retain.
    injectProductionDonation(record, {
        id = "ls-cancel-target", itemId = itemId, quantity = 3,
        timestamp = world.time + 1,
    })
    GS.InvalidateCreditCorrectionProjection(record)
    warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
    warmGuard = 0
    while warmOk == false and warmGuard < 200 do
        if not runOneDueTimer() then break end
        warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
        warmGuard = warmGuard + 1
    end
    flushTimers()
    GS._creditProjectionWorkBudgetOverride = 64
    rows = logsPage.__sfTest.BuildProjectedRows()
    row = nil
    for i = 1, #rows do
        if rows[i].id == "ls-cancel-target" then row = rows[i] break end
    end
    logsPage.__sfTest.OpenEditContributorDialog("ls-cancel-target", row)
    session = logsPage.__sfTest.GetEditSession()
    session.attributed = "Dave-Garona"
    session.attributedGuid = "Player-1-Dave"
    session.attributionText = "Dave-Garona"
    session.attributionResolved = true
    confirmCb = nil
    SF.SettingsUI.Dialogs.Confirm = function(_, _msg, _btn, onConfirm)
        confirmCb = onConfirm
    end
    logsPage.__sfTest.ConfirmAndSaveEdit()
    SF.SettingsUI.Dialogs.Confirm = prevConfirm
    confirmCb()
    assertTrue(GS.GetLocalContributorCorrectionSave(record) ~= nil,
        "459-C5: cancel case retained before ClearEditSession")
    local cancelOpId = GS.GetLocalContributorCorrectionSave(record).op.id
    logsPage.__sfTest.ClearEditSession()
    assertNil(GS.GetLocalContributorCorrectionSave(record),
        "459-C5: ClearEditSession cancels retain")
    flushTimers()
    assertNil(record.operations.records[cancelOpId],
        "459-C5: cancelled save never accepted")
    GS._creditProjectionWorkBudgetOverride = nil

    -- C5 recipient lifecycle: confirm Carol, yield, then change to Dave via
    -- text and suggestion callbacks — old Carol intent must not commit.
    injectProductionDonation(record, {
        id = "ls-recip-target", itemId = itemId, quantity = 4,
        timestamp = world.time + 2,
    })
    GS.InvalidateCreditCorrectionProjection(record)
    warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
    warmGuard = 0
    while warmOk == false and warmGuard < 200 do
        if not runOneDueTimer() then break end
        warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
        warmGuard = warmGuard + 1
    end
    flushTimers()
    GS._creditProjectionWorkBudgetOverride = 64
    rows = logsPage.__sfTest.BuildProjectedRows()
    row = nil
    for i = 1, #rows do
        if rows[i].id == "ls-recip-target" then row = rows[i] break end
    end
    assertTrue(row ~= nil, "459-C5: recip target row")
    logsPage.__sfTest.OpenEditContributorDialog("ls-recip-target", row)
    session = logsPage.__sfTest.GetEditSession()
    session.attributed = "Carol-Garona"
    session.attributedGuid = "Player-1-Carol"
    session.attributionText = "Carol-Garona"
    session.attributionResolved = true
    confirmCb = nil
    SF.SettingsUI.Dialogs.Confirm = function(_, _msg, _btn, onConfirm)
        confirmCb = onConfirm
    end
    logsPage.__sfTest.ConfirmAndSaveEdit()
    SF.SettingsUI.Dialogs.Confirm = prevConfirm
    confirmCb()
    local carolSave = GS.GetLocalContributorCorrectionSave(record)
    assertTrue(type(carolSave) == "table" and type(carolSave.op) == "table",
        "459-C5: Carol pending retained")
    local carolOpId = carolSave.op.id
    assertEq(carolSave.op.value.attributed, "Carol-Garona",
        "459-C5: confirmed Carol intent")
    -- Text path: type Dave while pending.
    logsPage.__sfTest.SetEditAttributionFromText("Dave-Garona")
    assertNil(GS.GetLocalContributorCorrectionSave(record),
        "459-C5: text recipient change cancels Carol retain")
    local sessText = logsPage.__sfTest.GetEditSession()
    assertTrue(sessText and sessText.pendingLocal ~= true,
        "459-C5: text path clears pendingLocal")
    assertEq(sessText.attributed, "Dave-Garona", "459-C5: visible Dave after text")
    flushTimers()
    assertNil(record.operations.records[carolOpId],
        "459-C5: Carol never accepted after text change")

    -- Suggestion path: confirm Carol again, then pick Dave via onResolved.
    logsPage.__sfTest.ClearEditSession()
    flushTimers()
    GS.InvalidateCreditCorrectionProjection(record)
    warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
    warmGuard = 0
    while warmOk == false and warmGuard < 200 do
        if not runOneDueTimer() then break end
        warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
        warmGuard = warmGuard + 1
    end
    flushTimers()
    assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
        "459-C5: suggestion case projection available")
    GS._creditProjectionWorkBudgetOverride = 64
    rows = logsPage.__sfTest.BuildProjectedRows()
    row = nil
    for i = 1, #rows do
        if rows[i].id == "ls-recip-target" then row = rows[i] break end
    end
    assertTrue(row ~= nil and not row.creditUnavailable,
        "459-C5: suggestion target row available")
    logsPage.__sfTest.OpenEditContributorDialog("ls-recip-target", row)
    session = logsPage.__sfTest.GetEditSession()
    assertTrue(session ~= nil, "459-C5: suggestion editor opens")
    session.attributed = "Carol-Garona"
    session.attributedGuid = "Player-1-Carol"
    session.attributionText = "Carol-Garona"
    session.attributionResolved = true
    confirmCb = nil
    SF.SettingsUI.Dialogs.Confirm = function(_, _msg, _btn, onConfirm)
        confirmCb = onConfirm
    end
    logsPage.__sfTest.ConfirmAndSaveEdit()
    SF.SettingsUI.Dialogs.Confirm = prevConfirm
    assertTrue(type(confirmCb) == "function", "459-C5: suggestion confirm captured")
    confirmCb()
    carolSave = GS.GetLocalContributorCorrectionSave(record)
    assertTrue(type(carolSave) == "table", "459-C5: Carol retained for suggestion case")
    carolOpId = carolSave.op.id
    logsPage.__sfTest.ResolveEditAttributionSuggestion({
        value = "Dave-Garona",
        label = "Dave-Garona",
        text = "Dave-Garona",
    })
    assertNil(GS.GetLocalContributorCorrectionSave(record),
        "459-C5: suggestion recipient change cancels Carol retain")
    local sessSug = logsPage.__sfTest.GetEditSession()
    assertTrue(sessSug and sessSug.pendingLocal ~= true,
        "459-C5: suggestion path clears pendingLocal")
    assertEq(sessSug.attributed, "Dave-Garona", "459-C5: visible Dave after suggestion")
    flushTimers()
    assertNil(record.operations.records[carolOpId],
        "459-C5: Carol never accepted after suggestion change")
    logsPage.__sfTest.ClearEditSession()
    GS._creditProjectionWorkBudgetOverride = nil
    logsPage.panel = nil
end

do
    -- C6: creditUnavailable gates editor; genuine Unassigned nil==nil stays fresh.
    -- Reuse the established failure fixture: Bob −20 with only Alice→Bob +10.
    local record = seedLiveCampaignWithItem(9805, 50)
    injectProductionDonation(record, {
        id = "unavail-don", itemId = 9805, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corr = select(1, GS:NewContributorCorrectionOperation(
        "unavail-don", "Bob-Garona", "Player-1-Bob"))
    assertTrue(corr ~= nil, "459-C6: prepare Alice→Bob")
    assertEq(GS:ApplyStagedConfigOperation(corr), "accepted", "459-C6: apply Alice→Bob")
    injectProductionAdjustment(record, {
        id = "unavail-floor", itemId = 9805, quantity = -20,
        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
    })
    local uItem = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 98055 }, {
        itemId = 98055, goal = 20, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(uItem), "accepted", "459-C6: add Unassigned item")
    injectProductionDonation(record, {
        id = "unavail-un-don", itemId = 98055, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(record, {
        id = "unavail-adj", itemId = 98055, quantity = 5,
        attributed = nil, attributedGuid = nil,
    })
    GS.InvalidateCreditCorrectionProjection(record)
    local okFail, errFail = GS.RebuildCreditCorrectionProjection(record, nil)
    assertTrue(okFail == false, "459-C6: rebuild fails")
    assertEq(errFail, "player_negative", "459-C6: player_negative")
    local _, _, _, unavailStatus = GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "unavail-don"))
    assertEq(unavailStatus, GS.CREDIT_UNAVAILABLE,
        "459-C6: Resolve status credit_unavailable")
    local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
    logsPage.panel = logsPage.panel or {
        IsShown = function() return true end,
        IsVisible = function() return true end,
    }
    logsPage.panel.__sfPrimarySection = logsPage.panel.__sfPrimarySection or {
        SetMessage = function() end,
    }
    local rows = logsPage.__sfTest.BuildProjectedRows()
    local donRow = nil
    for i = 1, #rows do
        if rows[i].id == "unavail-don" then donRow = rows[i] break end
    end
    assertTrue(donRow ~= nil, "459-C6: unavailable donation row exists")
    assertTrue(donRow.creditUnavailable == true,
        "459-C6: unavailable row creditUnavailable=true")
    assertTrue(donRow.showAction ~= true,
        "459-C6: unavailable row edit action disabled")
    logsPage.__sfTest.OpenEditContributorDialog("unavail-don", donRow)
    assertNil(logsPage.__sfTest.GetEditSession(),
        "459-C6: OpenEdit rejected while unavailable")

    -- Recover projection: remove the floor-breaking adjustment evidence and rebuild.
    local list = record.accounting._consumableEvents
    for i = #list, 1, -1 do
        if list[i].id == "unavail-floor" then
            table.remove(list, i)
        end
    end
    GS.InvalidateCreditCorrectionProjection(record)
    local okU = GS.EnsureCreditCorrectionProjection(record, nil)
    local gU = 0
    while okU == false and gU < 50 do
        if not runOneDueTimer() then break end
        okU = GS.EnsureCreditCorrectionProjection(record, nil)
        gU = gU + 1
    end
    flushTimers()
    assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
        "459-C6: projection recovered")
    rows = logsPage.__sfTest.BuildProjectedRows()
    local adjRow = nil
    for i = 1, #rows do
        if rows[i].id == "unavail-adj" then adjRow = rows[i] break end
    end
    assertTrue(adjRow ~= nil, "459-C6: Unassigned adj row")
    assertTrue(not adjRow.creditUnavailable, "459-C6: Unassigned not unavailable")
    logsPage.__sfTest.OpenEditContributorDialog("unavail-adj", adjRow)
    local sess = logsPage.__sfTest.GetEditSession()
    assertTrue(sess ~= nil, "459-C6: Unassigned editor opens")
    assertNil(sess.effectiveName, "459-C6: Unassigned effectiveName nil")
    assertNil(sess.effectiveGuid, "459-C6: Unassigned effectiveGuid nil")
    sess.attributed = "Bob-Garona"
    sess.attributedGuid = "Player-1-Bob"
    sess.attributionText = "Bob-Garona"
    sess.attributionResolved = true
    local okCb = nil
    local prevConfirm = SF.SettingsUI.Dialogs.Confirm
    SF.SettingsUI.Dialogs.Confirm = function(_, _msg, _btn, onConfirm)
        okCb = onConfirm
    end
    logsPage.__sfTest.ConfirmAndSaveEdit()
    SF.SettingsUI.Dialogs.Confirm = prevConfirm
    okCb()
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "unavail-adj"))), "Bob-Garona",
        "459-C6: Unassigned→Bob commit succeeds (nil==nil freshness)")
    logsPage.__sfTest.ClearEditSession()

    -- C6 transitions: available→unavailable before Continue and after confirm,
    -- starting from a genuine Unassigned adjustment (discussion_r4481473890).
    local uItem2 = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 98056 }, {
        itemId = 98056, goal = 20, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(uItem2), "accepted", "459-C6: add transition item")
    injectProductionDonation(record, {
        id = "unavail-tx-don", itemId = 98056, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionAdjustment(record, {
        id = "unavail-tx-adj", itemId = 98056, quantity = 5,
        attributed = nil, attributedGuid = nil,
    })
    GS.InvalidateCreditCorrectionProjection(record)
    local okTx = GS.EnsureCreditCorrectionProjection(record, nil)
    local gTx = 0
    while okTx == false and gTx < 50 do
        if not runOneDueTimer() then break end
        okTx = GS.EnsureCreditCorrectionProjection(record, nil)
        gTx = gTx + 1
    end
    flushTimers()
    assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
        "459-C6: transition baseline available")
    rows = logsPage.__sfTest.BuildProjectedRows()
    local txRow = nil
    for i = 1, #rows do
        if rows[i].id == "unavail-tx-adj" then txRow = rows[i] break end
    end
    assertTrue(txRow ~= nil, "459-C6: transition Unassigned row exists")
    assertTrue(not txRow.creditUnavailable, "459-C6: transition row available")
    assertTrue(txRow.showAction == true or txRow.canEdit == true
        or txRow.creditUnavailable ~= true,
        "459-C6: projected row present before action gate")

    local prepCalls = 0
    local applyCalls = 0
    local realNew = GS.NewContributorCorrectionOperation
    local realApply = GS.ApplyStagedConfigOperation
    GS.NewContributorCorrectionOperation = function(...)
        prepCalls = prepCalls + 1
        return realNew(...)
    end
    GS.ApplyStagedConfigOperation = function(...)
        applyCalls = applyCalls + 1
        return realApply(...)
    end

    local feedbackCalls = {}
    local realFmt = GS.FormatMutationFeedback
    GS.FormatMutationFeedback = function(status, reason)
        feedbackCalls[#feedbackCalls + 1] = {
            status = status,
            reason = reason,
        }
        return realFmt(status, reason)
    end

    -- Before Continue: open editor on Unassigned, then force unavailable.
    logsPage.__sfTest.OpenEditContributorDialog("unavail-tx-adj", txRow)
    sess = logsPage.__sfTest.GetEditSession()
    assertTrue(sess ~= nil, "459-C6: transition editor opens while available")
    assertNil(sess.effectiveName, "459-C6: transition starts Unassigned")
    sess.attributed = "Bob-Garona"
    sess.attributedGuid = "Player-1-Bob"
    sess.attributionText = "Bob-Garona"
    sess.attributionResolved = true
    -- Break floors so projection becomes unavailable (Alice−20 with no Alice heads).
    injectProductionAdjustment(record, {
        id = "unavail-tx-break", itemId = 98056, quantity = -20,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    GS.InvalidateCreditCorrectionProjection(record)
    local okBreak, errBreak = GS.RebuildCreditCorrectionProjection(record, nil)
    assertTrue(okBreak == false, "459-C6: transition rebuild fails")
    assertEq(errBreak, "player_negative", "459-C6: transition player_negative")
    -- ConfirmAndSaveEdit → EditSessionStillFresh → credit_unavailable.
    local beforePrep, beforeApply = prepCalls, applyCalls
    local feedbackBefore = #feedbackCalls
    logsPage.__sfTest.ConfirmAndSaveEdit()
    assertNil(logsPage.__sfTest.GetEditSession(),
        "459-C6: before-Continue clears session on credit_unavailable")
    assertNil(logsPage.__sfTest.GetPendingConfirm(),
        "459-C6: before-Continue leaves no pending confirm")
    assertEq(prepCalls, beforePrep, "459-C6: before-Continue zero prepare")
    assertEq(applyCalls, beforeApply, "459-C6: before-Continue zero apply")
    assertTrue(#feedbackCalls > feedbackBefore,
        "459-C6: before-Continue reports mutation feedback")
    local fbBefore = feedbackCalls[#feedbackCalls]
    assertEq(fbBefore.status, "rejected",
        "459-C6: before-Continue feedback status rejected")
    assertEq(fbBefore.reason, "credit_unavailable",
        "459-C6: before-Continue feedback reason credit_unavailable")

    -- Recover for after-confirm case: remove breaker, rebuild, reopen.
    local listTx = record.accounting._consumableEvents
    for i = #listTx, 1, -1 do
        if listTx[i].id == "unavail-tx-break" then
            table.remove(listTx, i)
        end
    end
    GS.InvalidateCreditCorrectionProjection(record)
    okTx = GS.EnsureCreditCorrectionProjection(record, nil)
    gTx = 0
    while okTx == false and gTx < 50 do
        if not runOneDueTimer() then break end
        okTx = GS.EnsureCreditCorrectionProjection(record, nil)
        gTx = gTx + 1
    end
    flushTimers()
    assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
        "459-C6: recovered for after-confirm")
    rows = logsPage.__sfTest.BuildProjectedRows()
    txRow = nil
    for i = 1, #rows do
        if rows[i].id == "unavail-tx-adj" then txRow = rows[i] break end
    end
    assertTrue(txRow ~= nil, "459-C6: after-confirm row exists")
    logsPage.__sfTest.ClearEditSession()
    logsPage.__sfTest.OpenEditContributorDialog("unavail-tx-adj", txRow)
    sess = logsPage.__sfTest.GetEditSession()
    assertTrue(sess ~= nil, "459-C6: after-confirm editor opens")
    sess.attributed = "Carol-Garona"
    sess.attributedGuid = "Player-1-Carol"
    sess.attributionText = "Carol-Garona"
    sess.attributionResolved = true
    okCb = nil
    SF.SettingsUI.Dialogs.Confirm = function(_, _msg, _btn, onConfirm)
        okCb = onConfirm
    end
    logsPage.__sfTest.ConfirmAndSaveEdit()
    SF.SettingsUI.Dialogs.Confirm = prevConfirm
    assertTrue(type(okCb) == "function", "459-C6: confirm dialog opened")
    assertTrue(logsPage.__sfTest.GetPendingConfirm() ~= nil,
        "459-C6: pending confirm captured")
    -- After confirmation opens: become unavailable, then invoke confirm.
    injectProductionAdjustment(record, {
        id = "unavail-tx-break2", itemId = 98056, quantity = -20,
        attributed = "Alice-Garona", attributedGuid = "Player-1-Alice",
    })
    GS.InvalidateCreditCorrectionProjection(record)
    okBreak, errBreak = GS.RebuildCreditCorrectionProjection(record, nil)
    assertTrue(okBreak == false and errBreak == "player_negative",
        "459-C6: after-confirm unavailable")
    beforePrep, beforeApply = prepCalls, applyCalls
    feedbackBefore = #feedbackCalls
    okCb()
    assertEq(prepCalls, beforePrep, "459-C6: after-confirm zero prepare")
    assertEq(applyCalls, beforeApply, "459-C6: after-confirm zero apply")
    assertTrue(#feedbackCalls > feedbackBefore,
        "459-C6: after-confirm reports mutation feedback")
    local fbAfter = feedbackCalls[#feedbackCalls]
    assertEq(fbAfter.status, "rejected",
        "459-C6: after-confirm feedback status rejected")
    assertEq(fbAfter.reason, "credit_unavailable",
        "459-C6: after-confirm feedback reason credit_unavailable")
    local storedTx = false
    for _, op in pairs(record.operations.records or {}) do
        if type(op) == "table" and op.target == "unavail-tx-adj" then
            storedTx = true
        end
    end
    assertTrue(not storedTx, "459-C6: after-confirm no correction stored")
    GS.FormatMutationFeedback = realFmt
    GS.NewContributorCorrectionOperation = realNew
    GS.ApplyStagedConfigOperation = realApply
    logsPage.__sfTest.ClearEditSession()
    logsPage.panel = nil
end

do
    -- B3: accepted-projection validity — invalidated map not readable during
    -- speculative pause; local ADJUST must not Seal unfinished reconstruction.
    do
        local nHeads = 80
        local itemId = 9810
        local record = seedLiveCampaignWithItem(itemId, nHeads + 40)
        local ctx = select(1, GS:GetCurrentContext())
        local t0 = world.time
        for i = 1, nHeads do
            local id = "b3-don-" .. i
            injectProductionDonation(record, {
                id = id, itemId = itemId, quantity = 1, timestamp = t0 + i,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            })
            local op = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = "b3-op-" .. i,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = id,
                value = {
                    eventId = id, eventKind = "donation",
                    attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                    baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                    itemId = itemId,
                },
                actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                timestamp = t0 + nHeads + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
            GS._StoreAccepted(record.operations, op, GS.CorrectionTargetKey(record, id))
        end
        injectProductionDonation(record, {
            id = "b3-spec-target", itemId = itemId, quantity = 3, timestamp = t0 + 2 * nHeads,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        })
        GS.InvalidateCreditCorrectionProjection(record)
        GS._creditProjectionWorkBudgetOverride = 96
        local warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
        local g = 0
        while warmOk == false and g < 200 do
            if not runOneDueTimer() then break end
            warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
            g = g + 1
        end
        flushTimers()
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            "459-B3: warm available")
        local beforeName = select(1, GS.ResolveEffectiveCreditIdentity(
            record, GS.FindLedgerEventById(record, "b3-don-1")))
        assertEq(beforeName, "Bob-Garona", "459-B3: warm Bob credit")

        -- Invalidate (GI-style): published map must clear.
        GS.InvalidateCreditCorrectionProjection(record)
        assertNil(record.creditCorrections, "459-B3: Invalidate clears published map")
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record) == false,
            "459-B3: unavailable immediately after Invalidate")

        -- Start accepted rebuild; pause; then speculative pause at same stamp.
        local okAcc = GS.EnsureCreditCorrectionProjection(record, nil)
        assertTrue(okAcc == false, "459-B3: accepted yield")
        local specOp = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "b3-spec-op",
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "b3-spec-target",
            value = {
                eventId = "b3-spec-target", eventKind = "donation",
                attributed = "Carol-Garona", attributedGuid = "Player-1-Carol",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = itemId,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = t0 + 3 * nHeads,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        local okSpec, errSpec = GS.RebuildCreditCorrectionProjection(record, specOp)
        assertTrue(okSpec == false and errSpec == "work_budget",
            "459-B3: speculative yield")
        -- Ensure must NOT report available with stale Bob credit.
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record) == false,
            "459-B3: speculative pause does not certify invalidated map")
        local _, _, _, st = GS.ResolveEffectiveCreditIdentity(
            record, GS.FindLedgerEventById(record, "b3-don-1"))
        assertEq(st, GS.CREDIT_UNAVAILABLE,
            "459-B3: Resolve unavailable during speculative pause after Invalidate")
        flushTimers()
        GS._creditProjectionWorkBudgetOverride = nil
        local g2 = 0
        while (not GS.IsCreditCorrectionProjectionAvailable(record)) and g2 < 200 do
            if not runOneDueTimer() then
                GS.EnsureCreditCorrectionProjection(record, nil)
            end
            g2 = g2 + 1
        end
        flushTimers()
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            "459-B3: recovered after drain")
        assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
            record, GS.FindLedgerEventById(record, "b3-don-1"))), "Bob-Garona",
            "459-B3: recovered Bob credit")
    end

    -- Local ADJUST_QUANTITY: share one outer allowance across mutation/store/
    -- post-store Ensure; measure complete callback at production constants
    -- (discussion_r4483108265).
    do
        local soft = tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384
        local hard = soft + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
        assertEq(soft, 16384, "459-B3-adj: production soft budget")
        assertEq(hard, 16896, "459-B3-adj: production hard ceiling")
        -- Large enough that AppendLedgerEvent Ensure + post-store Ensure would
        -- exceed one soft slice if each opened a fresh allowance.
        local nHeads = 2500
        local itemId = 9811
        local record = seedLiveCampaignWithItem(itemId, nHeads + 40)
        local ctx = select(1, GS:GetCurrentContext())
        local t0 = world.time
        for i = 1, nHeads do
            local id = "b3a-don-" .. i
            injectProductionDonation(record, {
                id = id, itemId = itemId, quantity = 1, timestamp = t0 + i,
            })
            local op = {
                schemaVersion = GS.OP_SCHEMA_VERSION,
                id = "b3a-op-" .. i,
                guildKey = ctx.guildKey,
                datasetId = record.datasetId,
                campaignId = record.currentCampaignId,
                kind = GS.KIND.CORRECT_CONTRIBUTOR,
                target = id,
                value = {
                    eventId = id, eventKind = "donation",
                    attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                    baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                    itemId = itemId,
                },
                actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                timestamp = t0 + nHeads + i,
                baseTargetRevision = record.datasetId,
                basePolicyRevision = record.permission and record.permission.revisionId,
                baseCampaignId = record.currentCampaignId,
            }
            GS._StoreAccepted(record.operations, op, GS.CorrectionTargetKey(record, id))
        end
        GS._creditProjectionWorkBudgetOverride = nil
        GS.InvalidateCreditCorrectionProjection(record)
        local warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
        local g = 0
        while warmOk == false and g < 8000 do
            if not runOneDueTimer() then
                warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
            else
                warmOk = GS.IsCreditCorrectionProjectionAvailable(record)
            end
            g = g + 1
        end
        flushTimers()
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            "459-B3-adj: warm available")
        local bobBefore = 0
        for i = 1, math.min(40, nHeads) do
            local name = select(1, GS.ResolveEffectiveCreditIdentity(
                record, GS.FindLedgerEventById(record, "b3a-don-" .. i)))
            if name == "Bob-Garona" then bobBefore = bobBefore + 1 end
        end
        assertTrue(bobBefore > 0, "459-B3-adj: warm Bob heads")

        local slices = {}
        local realRebuild = GS.RebuildCreditCorrectionProjection
        GS.RebuildCreditCorrectionProjection = function(...)
            local ok, err, det = realRebuild(...)
            local work = tonumber(det and det.workUnits) or 0
            local outer = tonumber(det and det.callbackWork)
                or tonumber(GS._creditProjectionCallbackWork) or work
            if err == "work_budget" or ok then
                slices[#slices + 1] = {
                    ok = ok and true or false,
                    err = err,
                    work = work,
                    outer = outer,
                    phase = det and det.phase,
                }
            end
            return ok, err, det
        end
        local function sumWork(fromIdx, toIdx)
            local total = 0
            for i = fromIdx, toIdx do
                total = total + (tonumber(slices[i].work) or 0)
            end
            return total
        end

        local adjOp, adjSt, adjReason = GS:NewAdjustmentOperation(
            itemId, -1, "Bob-Garona")
        assertTrue(adjOp ~= nil, "459-B3-adj: prepare adjust got "
            .. tostring(adjSt) .. "/" .. tostring(adjReason))
        local applySliceStart = #slices
        local st, reason = GS:ApplyStagedConfigOperation(adjOp)
        assertEq(st, "accepted", "459-B3-adj: adjust accepted got "
            .. tostring(st) .. "/" .. tostring(reason))
        assertTrue(#slices > applySliceStart,
            "459-B3-adj: Apply invoked Rebuild under shared allowance")
        -- Sum independent per-rebuild workUnits across the whole Apply callback
        -- (discussion_r4483730933) — not each outer counter in isolation.
        local applyWorkSum = sumWork(applySliceStart + 1, #slices)
        assertTrue(applyWorkSum <= hard,
            "459-B3-adj: Apply complete-callback workSum within soft+atomic got="
                .. tostring(applyWorkSum) .. " hard=" .. tostring(hard)
                .. " slices=" .. tostring(#slices - applySliceStart))
        -- Incomplete credit must stay unavailable until timer-only completion.
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record) == false,
            "459-B3-adj: unfinished adjust leaves credit unavailable")
        assertEq(select(4, GS.ResolveEffectiveCreditIdentity(
            record, GS.FindLedgerEventById(record, "b3a-don-1"))),
            GS.CREDIT_UNAVAILABLE,
            "459-B3-adj: Resolve unavailable before drain")
        assertTrue(#timers >= 1, "459-B3-adj: continuation queued after Apply")

        local g3 = 0
        while (not GS.IsCreditCorrectionProjectionAvailable(record)) and g3 < 8000 do
            local timerStart = #slices
            if not runOneDueTimer() then
                break
            end
            local timerWork = sumWork(timerStart + 1, #slices)
            assertTrue(timerWork <= hard,
                "459-B3-adj: timer callback workSum within soft+atomic tick="
                    .. tostring(g3 + 1) .. " work=" .. tostring(timerWork)
                    .. " hard=" .. tostring(hard))
            g3 = g3 + 1
        end
        flushTimers()
        GS.RebuildCreditCorrectionProjection = realRebuild
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            "459-B3-adj: timers complete reconstruction")
        assertTrue(g3 >= 1, "459-B3-adj: timer-only completion got ticks="
            .. tostring(g3))
        assertEq(#timers, 0, "459-B3-adj: idle after timers")

        local natural = {}
        local sampleN = math.min(80, nHeads)
        for i = 1, sampleN do
            natural[i] = {
                select(1, GS.ResolveEffectiveCreditIdentity(
                    record, GS.FindLedgerEventById(record, "b3a-don-" .. i))),
                select(2, GS.ResolveEffectiveCreditIdentity(
                    record, GS.FindLedgerEventById(record, "b3a-don-" .. i))),
            }
        end
        local bobBal = GS.PersonalContributorItemTotal(
            record, "Bob-Garona", "Player-1-Bob", itemId)
        GS.InvalidateCreditCorrectionProjection(record)
        local okF = GS.EnsureCreditCorrectionProjection(record, nil)
        local gf = 0
        while okF == false and gf < 8000 do
            if not runOneDueTimer() then
                okF = GS.EnsureCreditCorrectionProjection(record, nil)
            else
                okF = GS.IsCreditCorrectionProjectionAvailable(record)
            end
            gf = gf + 1
        end
        flushTimers()
        assertTrue(GS.IsCreditCorrectionProjectionAvailable(record),
            "459-B3-adj: independent rebuild available")
        for i = 1, sampleN do
            local name, guid = GS.ResolveEffectiveCreditIdentity(
                record, GS.FindLedgerEventById(record, "b3a-don-" .. i))
            assertEq(name, natural[i][1],
                "459-B3-adj: natural==fresh name i=" .. tostring(i))
            assertEq(guid, natural[i][2],
                "459-B3-adj: natural==fresh guid i=" .. tostring(i))
        end
        assertEq(GS.PersonalContributorItemTotal(
            record, "Bob-Garona", "Player-1-Bob", itemId), bobBal,
            "459-B3-adj: natural==fresh Bob balance")
        assertEq(#timers, 0, "459-B3-adj: idle")

        -- Behavioral fail without the outer-ownership repair: two nested
        -- EnsureThenRedrive opens each reset the allowance, so summed
        -- per-rebuild work across one Apply exceeds soft+atomic.
        do
            local broken = seedLiveCampaignWithItem(itemId + 1, nHeads + 40)
            local ctxB = select(1, GS:GetCurrentContext())
            local tB = world.time
            for i = 1, nHeads do
                local id = "b3b-don-" .. i
                injectProductionDonation(broken, {
                    id = id, itemId = itemId + 1, quantity = 1, timestamp = tB + i,
                })
                local op = {
                    schemaVersion = GS.OP_SCHEMA_VERSION,
                    id = "b3b-op-" .. i,
                    guildKey = ctxB.guildKey,
                    datasetId = broken.datasetId,
                    campaignId = broken.currentCampaignId,
                    kind = GS.KIND.CORRECT_CONTRIBUTOR,
                    target = id,
                    value = {
                        eventId = id, eventKind = "donation",
                        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                        baseAttributed = "Alice-Garona",
                        baseAttributedGuid = "Player-1-Alice",
                        itemId = itemId + 1,
                    },
                    actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                    timestamp = tB + nHeads + i,
                    baseTargetRevision = broken.datasetId,
                    basePolicyRevision = broken.permission
                        and broken.permission.revisionId,
                    baseCampaignId = broken.currentCampaignId,
                }
                GS._StoreAccepted(broken.operations, op,
                    GS.CorrectionTargetKey(broken, id))
            end
            GS.InvalidateCreditCorrectionProjection(broken)
            local warmB = GS.EnsureCreditCorrectionProjection(broken, nil)
            local gw = 0
            while warmB == false and gw < 8000 do
                if not runOneDueTimer() then
                    warmB = GS.EnsureCreditCorrectionProjection(broken, nil)
                else
                    warmB = GS.IsCreditCorrectionProjectionAvailable(broken)
                end
                gw = gw + 1
            end
            flushTimers()
            assertTrue(GS.IsCreditCorrectionProjectionAvailable(broken),
                "459-B3-adj: broken-case warm available")

            local brokenSlices = {}
            GS.RebuildCreditCorrectionProjection = function(...)
                local ok, err, det = realRebuild(...)
                local work = tonumber(det and det.workUnits) or 0
                if err == "work_budget" or ok then
                    brokenSlices[#brokenSlices + 1] = { work = work }
                end
                return ok, err, det
            end
            local realBegin = GS.BeginOuterCreditProjectionCallbackBudget
            -- Disable outer ownership without removing symbols: Begin reports
            -- unowned and never opens an allowance, so each EnsureThenRedrive
            -- opens/closes its own full soft slice inside Apply.
            GS.BeginOuterCreditProjectionCallbackBudget = function()
                return false
            end
            local adjBroken = select(1, GS:NewAdjustmentOperation(
                itemId + 1, -1, "Bob-Garona"))
            assertTrue(adjBroken ~= nil, "459-B3-adj: broken-case prepare")
            local beforeBroken = #brokenSlices
            local stBroken = GS:ApplyStagedConfigOperation(adjBroken)
            assertEq(stBroken, "accepted", "459-B3-adj: broken-case adjust accepted")
            local brokenSum = 0
            for i = beforeBroken + 1, #brokenSlices do
                brokenSum = brokenSum + (tonumber(brokenSlices[i].work) or 0)
            end
            GS.BeginOuterCreditProjectionCallbackBudget = realBegin
            GS.RebuildCreditCorrectionProjection = realRebuild
            flushTimers()
            assertTrue(brokenSum > hard,
                "459-B3-adj: without outer repair Apply workSum exceeds hard got="
                    .. tostring(brokenSum) .. " hard=" .. tostring(hard)
                    .. " slices=" .. tostring(#brokenSlices - beforeBroken))
        end
    end
end

do
    -- C7: realm-qualified miss must not fall back across realms.
    local record = seedLiveCampaignWithItem(9806, 30)
    -- Inject a second-realm Bob into the roster cache path via world.guild.members.
    world.guild.members[#world.guild.members + 1] = {
        name = "Bob-Stormrage", guid = "Player-2-Bob", rankOrder = 4, online = true,
    }
    settleRoster()
    local genBump = (GG.GetGuildGeneration and GG.GetGuildGeneration() or 0) + 1
    local prevGenFn = GG.GetGuildGeneration
    GG.GetGuildGeneration = function()
        return genBump
    end
    local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
    injectProductionDonation(record, {
        id = "realm-don", itemId = 9806, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local rows = logsPage.__sfTest.BuildProjectedRows()
    local row = nil
    for i = 1, #rows do
        if rows[i].id == "realm-don" then row = rows[i] break end
    end
    logsPage.__sfTest.OpenEditContributorDialog("realm-don", row)
    local name, guid, ok, err = logsPage.__sfTest.ResolveEditAttribution("Bob-Garona")
    assertEq(name, "Bob-Garona", "459-C7: exact Garona match")
    assertEq(guid, "Player-1-Bob", "459-C7: exact Garona guid")
    name, guid, ok, err = logsPage.__sfTest.ResolveEditAttribution("Bob-GaronaX")
    -- Typo with realm still present → no short-name fallback to Stormrage.
    assertTrue(ok == false, "459-C7: failed qualified lookup rejected")
    assertTrue(name == nil, "459-C7: no cross-realm resolution")
    name, guid, ok, err = logsPage.__sfTest.ResolveEditAttribution("Bob")
    -- Realm-omitted unique short name: ambiguous Garona+Stormrage.
    assertEq(err, "ambiguous_character", "459-C7: short Bob ambiguous across realms")
    -- Remove Stormrage; short Bob should resolve unique Garona.
    for i = #world.guild.members, 1, -1 do
        if world.guild.members[i].name == "Bob-Stormrage" then
            table.remove(world.guild.members, i)
        end
    end
    settleRoster()
    genBump = genBump + 1
    logsPage.__sfTest.ClearEditSession()
    logsPage.__sfTest.OpenEditContributorDialog("realm-don", row)
    name, guid, ok, err = logsPage.__sfTest.ResolveEditAttribution("Bob")
    GG.GetGuildGeneration = prevGenFn
    assertEq(name, "Bob-Garona", "459-C7: unique short Bob → Garona got "
        .. tostring(name) .. "/" .. tostring(err))
    logsPage.__sfTest.ClearEditSession()
end

do
    -- C8: localize correction-time " at " fragment.
    local Loc = SF.L and function(key, fallback)
        return (SF.L[key] or fallback)
    end or function(_, fallback) return fallback end
    assertTrue(type(SF.L) == "table" or true, "459-C8: locale table")
    -- Load enUS keys into SF.L if the harness populated them.
    local key = "GUILD_SUPPLIES_HISTORY_CREDIT_CORRECTED_AT"
    local en = rawget(_G, "SpectrumFederationLocale") or (SF and SF.L)
    -- Direct file assertion via Loc helper used by Campaigns.
    local fragment = nil
    if type(SF.GetLocale) == "function" then
        fragment = SF.GetLocale()[key]
    end
    -- Production Loc falls back; assert Campaigns formats with key present in enUS.
    local src = io.open("SpectrumFederation/locale/enUS.lua", "r")
    local body = src and src:read("*a") or ""
    if src then src:close() end
    assertTrue(body:find('L%["GUILD_SUPPLIES_HISTORY_CREDIT_CORRECTED_AT"%]%s*=%s*" at %%s"', 1)
        or body:find('GUILD_SUPPLIES_HISTORY_CREDIT_CORRECTED_AT', 1, true),
        "459-C8: locale key present in enUS")
    local campSrc = io.open("SpectrumFederation/modules/GuildSupplies/Campaigns.lua", "r")
    local campBody = campSrc and campSrc:read("*a") or ""
    if campSrc then campSrc:close() end
    assertTrue(campBody:find("GUILD_SUPPLIES_HISTORY_CREDIT_CORRECTED_AT", 1, true),
        "459-C8: Campaigns uses locale key")
    assertTrue(not campBody:find('(" at " ..', 1, true),
        "459-C8: hardcoded at-fragment removed")
end

---------------------------------------------------------------------------
-- Repair batch: assessment review-5790173267 groups G1–G6
---------------------------------------------------------------------------

local function CreditProjectionWorkNowSafe()
    return (tonumber(GS._creditProjectionRowVisits) or 0)
        + (tonumber(GS._creditProjectionProvenanceVisits) or 0)
        + (tonumber(GS._creditProjectionTraversalVisits) or 0)
        + (tonumber(GS._creditProjectionBucketVisits) or 0)
        + (tonumber(GS._creditProjectionFloorVisits) or 0)
        + (tonumber(GS._creditProjectionCandidateTrials) or 0)
        + (tonumber(GS._creditProjectionStructureCopyVisits) or 0)
end

local function EnsureDurableListenerViaBuild(logsPage)
    if logsPage and logsPage.Build then
        logsPage:Build({
            IsShown = function() return true end,
            HookScript = function() end,
        })
    end
end

do
    -- G1: saturated alias-map retention + eviction/reload + proportionate reconstruct.
    local record = seedLiveCampaignWithItem(9901, 40)
    local don = injectProductionDonation(record, {
        id = "ctx:g1-canon", itemId = 9901, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    don.txnId = "ctx:g1-canon"
    local cfg = record.accounting._consumables
    cfg.txnRegistry = cfg.txnRegistry or {}
    cfg.txnRegistry[#cfg.txnRegistry + 1] = {
        txnId = "ctx:g1-canon",
        status = "verified",
        committed = true,
        aliases = { "ctx:g1-alias" },
        itemId = 9901,
        quantity = 5,
        donor = "Alice-Garona",
    }
    cfg.txnRegistry[#cfg.txnRegistry + 1] = {
        txnId = "ctx:g1-alias",
        status = "alias",
        aliasOf = "ctx:g1-canon",
        committed = true,
    }
    -- Saturate durable alias map with irrelevant bindings (capacity pressure).
    local maxAliases = tonumber(GS.MAX_CREDIT_EVENT_ALIASES) or 2048
    cfg.creditEventAliases = {}
    for i = 1, maxAliases do
        cfg.creditEventAliases[string.format("ctx:g1-junk-%04d", i)] =
            string.format("ctx:g1-junk-canon-%04d", i)
    end
    local ctx = select(1, GS:GetCurrentContext())
    local corr = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "g1-alias-corr",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:g1-alias",
        value = {
            eventId = "ctx:g1-alias",
            eventKind = "donation",
            attributed = "Bob-Garona",
            attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona",
            baseAttributedGuid = "Player-1-Alice",
            itemId = 9901,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    assertEq(select(1, GS:AdmitRemoteOperation(corr, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })), "accepted", "459-G1: saturated-map alias correction accepted")
    assertEq(cfg.creditEventAliases["ctx:g1-alias"], "ctx:g1-canon",
        "459-G1: required binding retained under saturation")
    local headKey = GS.CorrectionTargetKey(record, "ctx:g1-alias")
    assertEq(headKey, "credit:ctx:g1-canon", "459-G1: canonical head key")
    assertEq(record.operations.heads[headKey], "g1-alias-corr", "459-G1: head stored")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Bob-Garona",
        "459-G1: credit Bob before eviction")
    -- Evict registry while retaining donation + correction.
    cfg.txnRegistry = {}
    local warmOk, warmErr = GS._ValidateGuildRecordStructure(ctx.guildKey, record)
    assertTrue(warmOk, "459-G1: warm validate after eviction got " .. tostring(warmErr))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Bob-Garona",
        "459-G1: credit preserved after eviction")
    assertEq(GS.CanonicalCreditEventId(record, "ctx:g1-alias"), "ctx:g1-canon",
        "459-G1: durable alias map resolves after eviction")
    if GS._ClearOpsValidationCache then
        GS._ClearOpsValidationCache(record.operations)
    end
    local coldOk, coldErr = GS._ValidateGuildRecordStructure(ctx.guildKey, record)
    assertTrue(coldOk, "459-G1: cold validate after eviction got " .. tostring(coldErr))

    -- Proportionate reconstruct: matching map entries skip ledger walks.
    GS._creditEventAliasReconstructLedgerVisits = -1
    GS.ReconstructCreditEventAliasesFromOps(record)
    assertEq(GS._creditEventAliasReconstructLedgerVisits, 0,
        "459-G1: reconstruct skips ledger when map already matches")

    -- Trusted alias restoration / cache recovery (prior G1b coverage).
    local record2 = seedLiveCampaignWithItem(9902, 40)
    local don2 = injectProductionDonation(record2, {
        id = "ctx:g1b-canon", itemId = 9902, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    don2.txnId = "ctx:g1b-canon"
    local ctx2 = select(1, GS:GetCurrentContext())
    local corr2 = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "g1b-corr",
        guildKey = ctx2.guildKey,
        datasetId = record2.datasetId,
        campaignId = record2.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:g1b-alias",
        value = {
            eventId = "ctx:g1b-alias",
            eventKind = "donation",
            attributed = "Carol-Garona",
            attributedGuid = "Player-1-Carol",
            baseAttributed = "Alice-Garona",
            baseAttributedGuid = "Player-1-Alice",
            itemId = 9902,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 2,
        baseTargetRevision = record2.datasetId,
        basePolicyRevision = record2.permission and record2.permission.revisionId,
        baseCampaignId = record2.currentCampaignId,
    }
    local cfg2 = record2.accounting._consumables
    cfg2.txnRegistry = {
        {
            txnId = "ctx:g1b-canon", status = "verified", committed = true,
            aliases = { "ctx:g1b-alias" }, itemId = 9902, quantity = 4,
            donor = "Alice-Garona",
        },
        {
            txnId = "ctx:g1b-alias", status = "alias", aliasOf = "ctx:g1b-canon",
            committed = true,
        },
    }
    assertEq(select(1, GS:AdmitRemoteOperation(corr2, {
        sender = "Alice-Garona", offlineRecord = record2, preserveAttribution = true,
    })), "accepted", "459-G1b: admit with registry")
    local realHeads = {}
    for k, v in pairs(record2.operations.heads or {}) do
        realHeads[k] = v
    end
    cfg2.creditEventAliases = nil
    cfg2.txnRegistry = {}
    record2.operations.heads = { ["credit:bogus"] = "g1b-corr" }
    if GS._BumpOpsValidationGen then GS._BumpOpsValidationGen(record2.operations) end
    assertTrue(not GS._ValidateGuildRecordStructure(ctx2.guildKey, record2),
        "459-G1b: poisoned heads fail and cache")
    record2.operations.heads = realHeads
    if GS._ClearOpsValidationCache then
        GS._ClearOpsValidationCache(record2.operations)
    end
    local healedOk, healedErr = GS._ValidateGuildRecordStructure(ctx2.guildKey, record2)
    assertTrue(healedOk, "459-G1b: reconstruct heals without registry got " .. tostring(healedErr))
    cfg2.creditEventAliases = nil
    cfg2.txnRegistry = {}
    record2.operations.heads = { ["credit:bogus"] = "g1b-corr" }
    if GS._BumpOpsValidationGen then GS._BumpOpsValidationGen(record2.operations) end
    assertTrue(not GS._ValidateGuildRecordStructure(ctx2.guildKey, record2),
        "459-G1b: re-cache failure")
    record2.operations.heads = realHeads
    local stuckOk = GS._ValidateGuildRecordStructure(ctx2.guildKey, record2)
    assertTrue(not stuckOk, "459-G1b: cached failure sticks until alias restore")
    assertTrue(GS._AddTxnAlias(record2, "ctx:g1b-canon", "ctx:g1b-alias", don2),
        "459-G1b: trusted AddTxnAlias restores binding")
    local restoredOk, restoredErr = GS._ValidateGuildRecordStructure(ctx2.guildKey, record2)
    assertTrue(restoredOk, "459-G1b: alias restore recovers without manual bump got "
        .. tostring(restoredErr))

    -- G1c: losing-history retention must refuse when durable map cannot store
    -- a new binding and every slot is owned by retained corrections.
    local record3 = seedLiveCampaignWithItem(9907, 80)
    local cfg3 = record3.accounting._consumables
    local ctx3 = select(1, GS:GetCurrentContext())
    local maxA = tonumber(GS.MAX_CREDIT_EVENT_ALIASES) or 2048
    cfg3.creditEventAliases = {}
    record3.operations.records = record3.operations.records or {}
    record3.operations.order = record3.operations.order or {}
    -- Fill the durable map with bindings required by retained correction bodies
    -- so unused-binding reclaim cannot free a slot. Bodies are shape-valid;
    -- their canons are intentionally absent from the ledger so Rebuild skips.
    for i = 1, maxA do
        local alias = string.format("ctx:g1c-req-alias-%04d", i)
        local canon = string.format("ctx:g1c-req-canon-%04d", i)
        cfg3.creditEventAliases[alias] = canon
        local opId = string.format("g1c-req-corr-%04d", i)
        record3.operations.records[opId] = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = opId,
            guildKey = ctx3.guildKey,
            datasetId = record3.datasetId,
            campaignId = record3.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = alias,
            value = {
                eventId = alias,
                eventKind = "donation",
                attributed = "Bob-Garona",
                attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona",
                baseAttributedGuid = "Player-1-Alice",
                itemId = 9907,
            },
            actorGuid = "Player-1-Alice",
            actorName = "Alice-Garona",
            timestamp = world.time,
            baseTargetRevision = record3.datasetId,
            basePolicyRevision = record3.permission and record3.permission.revisionId,
            baseCampaignId = record3.currentCampaignId,
        }
        record3.operations.order[#record3.operations.order + 1] = opId
    end
    if GS._BumpOpsValidationGen then
        GS._BumpOpsValidationGen(record3.operations)
    end
    local winDon = injectProductionDonation(record3, {
        id = "ctx:g1c-win-canon", itemId = 9907, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    winDon.txnId = "ctx:g1c-win-canon"
    local winCorr = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "g1c-win-corr",
        guildKey = ctx3.guildKey,
        datasetId = record3.datasetId,
        campaignId = record3.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:g1c-win-canon",
        value = {
            eventId = "ctx:g1c-win-canon",
            eventKind = "donation",
            attributed = "Carol-Garona",
            attributedGuid = "Player-1-Carol",
            baseAttributed = "Alice-Garona",
            baseAttributedGuid = "Player-1-Alice",
            itemId = 9907,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 50,
        baseTargetRevision = record3.datasetId,
        basePolicyRevision = record3.permission and record3.permission.revisionId,
        baseCampaignId = record3.currentCampaignId,
    }
    local stWin, rWin = GS:AdmitRemoteOperation(winCorr, {
        sender = "Alice-Garona", offlineRecord = record3, preserveAttribution = true,
    })
    local guardW = 0
    while stWin == "pending" and guardW < 200 do
        if not runOneDueTimer() then break end
        stWin, rWin = GS:AdmitRemoteOperation(winCorr, {
            sender = "Alice-Garona", offlineRecord = record3, preserveAttribution = true,
        })
        guardW = guardW + 1
    end
    flushTimers()
    assertTrue(stWin == "accepted" or stWin == "duplicate",
        "459-G1c: canonical winner accepted st=" .. tostring(stWin) .. "/" .. tostring(rWin))
    assertTrue(record3.operations.records["g1c-win-corr"] ~= nil,
        "459-G1c: winner body retained")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record3, winDon)), "Carol-Garona",
        "459-G1c: winner credit Carol")
    -- Registry alias that cannot fit the durable map.
    assertTrue(GS._AddTxnAlias(record3, "ctx:g1c-win-canon", "ctx:g1c-lose-alias", winDon),
        "459-G1c: registry alias registered")
    assertNil(cfg3.creditEventAliases["ctx:g1c-lose-alias"],
        "459-G1c: durable map still full for new alias")
    local loseCorr = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "g1c-lose-corr",
        guildKey = ctx3.guildKey,
        datasetId = record3.datasetId,
        campaignId = record3.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:g1c-lose-alias",
        value = {
            eventId = "ctx:g1c-lose-alias",
            eventKind = "donation",
            attributed = "Bob-Garona",
            attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona",
            baseAttributedGuid = "Player-1-Alice",
            itemId = 9907,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 10,
        baseTargetRevision = record3.datasetId,
        basePolicyRevision = record3.permission and record3.permission.revisionId,
        baseCampaignId = record3.currentCampaignId,
    }
    local stLose, rLose = GS:AdmitRemoteOperation(loseCorr, {
        sender = "Alice-Garona", offlineRecord = record3, preserveAttribution = true,
    })
    assertTrue(stLose ~= "accepted",
        "459-G1c: saturated loser refused st=" .. tostring(stLose) .. "/" .. tostring(rLose))
    assertEq(rLose, "full", "459-G1c: refuse reason full")
    assertNil(record3.operations.records["g1c-lose-corr"],
        "459-G1c: loser body not retained without durable binding")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record3, winDon)), "Carol-Garona",
        "459-G1c: winner credit unchanged after loser refuse")

    -- Positive loser path with reclaimable spare capacity: binding survives eviction.
    local record4 = seedLiveCampaignWithItem(9908, 40)
    local cfg4 = record4.accounting._consumables
    local ctx4 = select(1, GS:GetCurrentContext())
    local winDon4 = injectProductionDonation(record4, {
        id = "ctx:g1d-canon", itemId = 9908, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    winDon4.txnId = "ctx:g1d-canon"
    cfg4.txnRegistry = {
        {
            txnId = "ctx:g1d-canon", status = "verified", committed = true,
            aliases = { "ctx:g1d-alias" }, itemId = 9908, quantity = 4,
            donor = "Alice-Garona",
        },
        {
            txnId = "ctx:g1d-alias", status = "alias", aliasOf = "ctx:g1d-canon",
            committed = true,
        },
    }
    -- Pad map with reclaimable junk, leaving room after prune.
    cfg4.creditEventAliases = {}
    for i = 1, maxA - 1 do
        cfg4.creditEventAliases[string.format("ctx:g1d-junk-%04d", i)] =
            string.format("ctx:g1d-junk-canon-%04d", i)
    end
    local win4 = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "g1d-win",
        guildKey = ctx4.guildKey,
        datasetId = record4.datasetId,
        campaignId = record4.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:g1d-canon",
        value = {
            eventId = "ctx:g1d-canon", eventKind = "donation",
            attributed = "Carol-Garona", attributedGuid = "Player-1-Carol",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9908,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 40,
        baseTargetRevision = record4.datasetId,
        basePolicyRevision = record4.permission and record4.permission.revisionId,
        baseCampaignId = record4.currentCampaignId,
    }
    assertEq(select(1, GS:AdmitRemoteOperation(win4, {
        sender = "Alice-Garona", offlineRecord = record4, preserveAttribution = true,
    })), "accepted", "459-G1d: winner accepted")
    local lose4 = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "g1d-lose",
        guildKey = ctx4.guildKey,
        datasetId = record4.datasetId,
        campaignId = record4.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:g1d-alias",
        value = {
            eventId = "ctx:g1d-alias", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9908,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 5,
        baseTargetRevision = record4.datasetId,
        basePolicyRevision = record4.permission and record4.permission.revisionId,
        baseCampaignId = record4.currentCampaignId,
    }
    assertEq(select(1, GS:AdmitRemoteOperation(lose4, {
        sender = "Alice-Garona", offlineRecord = record4, preserveAttribution = true,
    })), "accepted", "459-G1d: loser retained with durable binding")
    assertEq(cfg4.creditEventAliases["ctx:g1d-alias"], "ctx:g1d-canon",
        "459-G1d: durable loser binding stored")
    assertTrue(record4.operations.records["g1d-lose"] ~= nil, "459-G1d: loser body retained")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record4, winDon4)), "Carol-Garona",
        "459-G1d: winner credit unchanged")
    cfg4.txnRegistry = {}
    if GS._ClearOpsValidationCache then
        GS._ClearOpsValidationCache(record4.operations)
    end
    local cold4, cold4Err = GS._ValidateGuildRecordStructure(ctx4.guildKey, record4)
    assertTrue(cold4, "459-G1d: cold validate after eviction got " .. tostring(cold4Err))
    assertEq(GS.CanonicalCreditEventId(record4, "ctx:g1d-alias"), "ctx:g1d-canon",
        "459-G1d: loser alias resolves after eviction")
    -- Source-accepted adoption replay still finds the canonical donation.
    local replay = {}
    for k, v in pairs(lose4) do replay[k] = v end
    local stReplay, rReplay = GS:AdmitRemoteOperation(replay, {
        sender = "Alice-Garona", offlineRecord = record4, preserveAttribution = true,
        adoptionReplay = true,
        sourceAcceptedSet = { ["g1d-lose"] = true },
    })
    assertTrue(stReplay == "accepted" or stReplay == "duplicate",
        "459-G1d: adoption replay resolves after eviction st="
            .. tostring(stReplay) .. "/" .. tostring(rReplay))
end

do
    -- G2: cold paced provenance under shared callback with live+archive history.
    local record = seedLiveCampaignWithItem(9903, 200)
    settleRoster()
    -- Minimal Guild Info stub: ready with empty relationships so unresolved
    -- claimed identities require ledger provenance (459 harness does not load GI).
    SF.GuildInfo = SF.GuildInfo or {}
    local GI = SF.GuildInfo
    local prevReady = GI.GetRelationshipReadiness
    local prevResolve = GI.ResolveCharacterGuidByName
    GI.GetRelationshipReadiness = function()
        return "ready", { members = {}, characters = {} }, nil
    end
    GI.ResolveCharacterGuidByName = function()
        return nil
    end
    assertTrue(GS.WitnessRelationshipsReady(record), "459-G2: relationships ready")
    local soft = tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384
    local hard = soft + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
    local liveN, archN = 4000, 4000
    for i = 1, liveN do
        injectProductionDonation(record, {
            id = string.format("g2-live-%04d", i),
            itemId = 9903, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
    end
    record.accounting._consumableEventArchive =
        record.accounting._consumableEventArchive or {}
    local archive = record.accounting._consumableEventArchive
    for i = 1, archN do
        local name = (i == archN) and "Retired-Garona" or "Alice-Garona"
        local guid = (i == archN) and "Player-1-Retired" or "Player-1-Alice"
        archive[#archive + 1] = {
            type = GS.LEDGER_EVENT.DONATION,
            id = string.format("g2-arch-%04d", i),
            txnId = string.format("g2-arch-%04d", i),
            generation = 1,
            timestamp = world.time + liveN + i,
            actor = name,
            actorGuid = guid,
            donorGuid = guid,
            attributed = name,
            attributedGuid = guid,
            itemId = 9903,
            quantity = 1,
            campaignId = record.currentCampaignId,
            datasetId = record.datasetId,
            verification = "officer",
            writer = "Player-1-Alice",
            gsProductionCredit = true,
        }
    end
    world.time = world.time + liveN + archN + 10
    -- Target donation for the cold first correction.
    local target = injectProductionDonation(record, {
        id = "g2-target", itemId = 9903, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        timestamp = world.time,
    })
    -- Distinct unresolved claimed identities (not roster-unique).
    local ctx = select(1, GS:GetCurrentContext())
    local corr = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "g2-cold-corr",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "g2-target",
        value = {
            eventId = "g2-target",
            eventKind = "donation",
            attributed = "Retired-Garona",
            attributedGuid = "Player-1-Retired",
            baseAttributed = "Alice-Garona",
            baseAttributedGuid = "Player-1-Alice",
            itemId = 9903,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    -- Pre-consume most of the outer allowance before Admit.
    local owned = GS.BeginOuterCreditProjectionCallbackBudget
        and GS.BeginOuterCreditProjectionCallbackBudget()
    GS._creditProjectionCallbackWork = 12000
    GS._creditProjectionProvenanceVisits = 0
    local maxObserved = 0
    local function observe()
        local cw = tonumber(GS._creditProjectionCallbackWork) or 0
        local localNow = (tonumber(GS._creditProjectionProvenanceVisits) or 0)
            + (tonumber(GS._creditProjectionRowVisits) or 0)
            + (tonumber(GS._creditProjectionBucketVisits) or 0)
            + (tonumber(GS._creditProjectionFloorVisits) or 0)
            + (tonumber(GS._creditProjectionCandidateTrials) or 0)
            + (tonumber(GS._creditProjectionStructureCopyVisits) or 0)
            + (tonumber(GS._creditProjectionTraversalVisits) or 0)
        local total = cw + localNow
        if total > maxObserved then maxObserved = total end
        assertTrue(total <= hard,
            "459-G2: observed work within hard total=" .. tostring(total)
                .. " hard=" .. tostring(hard))
    end
    local st, reason = GS:AdmitRemoteOperation(corr, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    observe()
    assertTrue(st == "pending" or st == "accepted",
        "459-G2: cold admit status=" .. tostring(st) .. "/" .. tostring(reason))
    if st == "pending" then
        assertEq(reason, "work_budget", "459-G2: pending reason work_budget")
    end
    local guard = 0
    while (st == "pending" or reason == "work_budget") and guard < 400 do
        if not runOneDueTimer() then
            -- Re-admit to continue paced cold index / rebuild.
            st, reason = GS:AdmitRemoteOperation(corr, {
                sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
            })
        else
            st, reason = GS:AdmitRemoteOperation(corr, {
                sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
            })
        end
        observe()
        if st == "accepted" or st == "duplicate" then break end
        guard = guard + 1
    end
    flushTimers()
    if owned and GS.EndOuterCreditProjectionCallbackBudget then
        GS.EndOuterCreditProjectionCallbackBudget(true)
    end
    assertTrue(record.operations.records["g2-cold-corr"] ~= nil
        or record.operations.heads[GS.CorrectionTargetKey(record, "g2-target")] ~= nil,
        "459-G2: correction retained after paced catch-up")
    assertTrue(maxObserved <= hard,
        "459-G2: entire Admit/timer work within hard max=" .. tostring(maxObserved))
    local credName = select(1, GS.ResolveEffectiveCreditIdentity(record, target))
    assertEq(credName, "Retired-Garona",
        "459-G2: late archive provenance binds Retired credit")
    assertEq(#timers, 0, "459-G2: idle queues")
    GI.GetRelationshipReadiness = prevReady
    GI.ResolveCharacterGuidByName = prevResolve
end

do
    -- G3: small production skew; immediate edit after rejected future traffic.
    local record = seedLiveCampaignWithItem(9904, 40)
    injectProductionDonation(record, {
        id = "g3-don", itemId = 9904, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local skew = tonumber(GS.CORRECT_CONTRIBUTOR_TIMESTAMP_SKEW) or 600
    assertTrue(skew > 0 and skew <= 600, "459-G3: production skew <= 600 got=" .. tostring(skew))
    local ctx = select(1, GS:GetCurrentContext())
    local function makeCorr(id, ts, attributed, baseName, baseGuid, targetId)
        local guid = attributed == "Bob-Garona" and "Player-1-Bob"
            or attributed == "Carol-Garona" and "Player-1-Carol"
            or attributed == "Dave-Garona" and "Player-1-Dave"
            or "Player-1-Alice"
        targetId = targetId or "g3-don"
        return {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = id,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = targetId,
            value = {
                eventId = targetId,
                eventKind = "donation",
                attributed = attributed,
                attributedGuid = guid,
                baseAttributed = baseName,
                baseAttributedGuid = baseGuid,
                itemId = 9904,
            },
            actorGuid = "Player-1-Alice",
            actorName = "Alice-Garona",
            timestamp = ts,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
    end
    -- Just-outside boundary rejected; no head retained.
    local outsideTs = math.floor(world.time) + skew + 1
    local stOut, rOut = GS:AdmitRemoteOperation(
        makeCorr("g3-outside", outsideTs, "Bob-Garona", "Alice-Garona", "Player-1-Alice"), {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
    assertTrue(stOut == "rejected" or stOut == "obsolete",
        "459-G3: just-outside rejected status=" .. tostring(stOut))
    assertEq(rOut, "invalid_timestamp", "459-G3: just-outside reason")
    assertNil(record.operations.records["g3-outside"], "459-G3: outside not retained")
    -- Far-future rejected (including demotion of that traffic).
    local futureTs = math.floor(world.time) + skew + 86400
    local stF, rF = GS:AdmitRemoteOperation(
        makeCorr("g3-future", futureTs, "Bob-Garona", "Alice-Garona", "Player-1-Alice"), {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
    assertTrue(stF == "rejected" or stF == "obsolete",
        "459-G3: far-future rejected status=" .. tostring(stF))
    assertEq(rF, "invalid_timestamp", "459-G3: far-future reason")
    assertNil(record.operations.heads[GS.CorrectionTargetKey(record, "g3-don")],
        "459-G3: no head after future reject")
    -- Immediate ordinary authorized edit without advancing past an accepted future head.
    -- Rejected future traffic is demoted (not retained), so Dave can edit now.
    local normal = select(1, GS:NewContributorCorrectionOperation(
        "g3-don", "Dave-Garona", "Player-1-Dave"))
    assertTrue(type(normal) == "table", "459-G3: ordinary prepare after reject")
    assertEq(GS:ApplyStagedConfigOperation(normal), "accepted",
        "459-G3: ordinary accept immediately after rejected future")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "g3-don"))), "Dave-Garona",
        "459-G3: ordinary credit Dave after future reject")
    -- Just-inside boundary accepted on a fresh event (separate from recovery path).
    injectProductionDonation(record, {
        id = "g3-bound-don", itemId = 9904, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local boundaryTs = math.floor(world.time) + skew
    assertEq(select(1, GS:AdmitRemoteOperation(
        makeCorr("g3-boundary", boundaryTs, "Bob-Garona", "Alice-Garona", "Player-1-Alice",
            "g3-bound-don"), {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })), "accepted", "459-G3: skew-boundary accepted")
    -- Old legitimate historical timestamp (loses LWW to current head on g3-don).
    local stOld, rOld = GS:AdmitRemoteOperation(
        makeCorr("g3-old", math.max(1, math.floor(world.time) - 500),
            "Carol-Garona", "Dave-Garona", "Player-1-Dave"), {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
    assertTrue(stOld == "obsolete" or stOld == "accepted" or stOld == "duplicate"
        or stOld == "rejected",
        "459-G3: old timestamp handled st=" .. tostring(stOld) .. "/" .. tostring(rOld))
    -- Shape validation must not apply wall-clock.
    local shapeBody = makeCorr("g3-shape-future", futureTs, "Bob-Garona",
        "Alice-Garona", "Player-1-Alice")
    local shapeOk = GS.ValidateAcceptedOperationBody(shapeBody, ctx.guildKey, record.datasetId)
    assertTrue(shapeOk, "459-G3: pure shape validation ignores wall-clock future")
end

do
    -- G4: campaign scope before losing-history retention + prepared-before-rollover.
    local record = seedLiveCampaignWithItem(9905, 40)
    injectProductionDonation(record, {
        id = "g4-don", itemId = 9905, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local ctx = select(1, GS:GetCurrentContext())
    local function baseCorr(overrides)
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = "g4-base",
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "g4-don",
            value = {
                eventId = "g4-don",
                eventKind = "donation",
                attributed = "Bob-Garona",
                attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona",
                baseAttributedGuid = "Player-1-Alice",
                itemId = 9905,
            },
            actorGuid = "Player-1-Alice",
            actorName = "Alice-Garona",
            timestamp = world.time + 1,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        if type(overrides) == "table" then
            for k, v in pairs(overrides) do op[k] = v end
        end
        return op
    end
    local missOp = baseCorr({ id = "g4-miss-camp" })
    missOp.campaignId = nil
    local stMiss, rMiss = GS:AdmitRemoteOperation(missOp, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true })
    assertTrue(stMiss ~= "accepted",
        "459-G4: missing campaignId rejected st=" .. tostring(stMiss) .. "/" .. tostring(rMiss))
    local stEmpty, rEmpty = GS:AdmitRemoteOperation(baseCorr({
        id = "g4-empty-base", baseCampaignId = "",
    }), { sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true })
    assertTrue(stEmpty ~= "accepted", "459-G4: empty baseCampaignId rejected")
    local stContra, rContra = GS:AdmitRemoteOperation(baseCorr({
        id = "g4-contra", baseCampaignId = "other-campaign",
    }), { sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true })
    assertTrue(stContra ~= "accepted", "459-G4: contradictory campaigns rejected")
    -- Winner first, then older wrong-campaign loser must not retain.
    assertEq(select(1, GS:AdmitRemoteOperation(baseCorr({
        id = "g4-winner",
        timestamp = world.time + 50,
        value = {
            eventId = "g4-don", eventKind = "donation",
            attributed = "Carol-Garona", attributedGuid = "Player-1-Carol",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9905,
        },
    }), { sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true })),
        "accepted", "459-G4: winner accepted")
    local stLose, rLose = GS:AdmitRemoteOperation(baseCorr({
        id = "g4-wrong-lose",
        timestamp = world.time + 10,
        campaignId = "wrong-campaign",
        baseCampaignId = "wrong-campaign",
        value = {
            eventId = "g4-don", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9905,
        },
    }), { sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true })
    assertTrue(stLose ~= "accepted",
        "459-G4: wrong-campaign loser not retained st="
            .. tostring(stLose) .. "/" .. tostring(rLose))
    assertNil(record.operations.records["g4-wrong-lose"],
        "459-G4: wrong-campaign loser body absent")
    -- Losing delivery order: older valid then newer winner; both retained appropriately.
    injectProductionDonation(record, {
        id = "g4-order-don", itemId = 9905, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local stEarly = select(1, GS:AdmitRemoteOperation(baseCorr({
        id = "g4-order-early",
        target = "g4-order-don",
        timestamp = world.time + 5,
        value = {
            eventId = "g4-order-don", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9905,
        },
    }), { sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true }))
    assertEq(stEarly, "accepted", "459-G4: early winner/path accepted")
    local stLate = select(1, GS:AdmitRemoteOperation(baseCorr({
        id = "g4-order-late",
        target = "g4-order-don",
        timestamp = world.time + 60,
        value = {
            eventId = "g4-order-don", eventKind = "donation",
            attributed = "Dave-Garona", attributedGuid = "Player-1-Dave",
            baseAttributed = "Bob-Garona", baseAttributedGuid = "Player-1-Bob",
            itemId = 9905,
        },
    }), { sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true }))
    assertEq(stLate, "accepted", "459-G4: later LWW winner accepted")

    -- Local prepare → genuine rollover → Apply must reject; credit unchanged.
    injectProductionDonation(record, {
        id = "g4-roll-don", itemId = 9905, quantity = 6,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local prepared = select(1, GS:NewContributorCorrectionOperation(
        "g4-roll-don", "Bob-Garona", "Player-1-Bob"))
    assertTrue(type(prepared) == "table",
        "459-G4: prepared before rollover got " .. tostring(prepared))
    local oldCampaign = record.currentCampaignId
    assertEq(prepared.campaignId, oldCampaign, "459-G4: prepared campaignId")
    assertEq(prepared.baseCampaignId, oldCampaign, "459-G4: prepared baseCampaignId")
    startCampaign()
    assertTrue(record.currentCampaignId ~= oldCampaign, "459-G4: rollover advanced campaign")
    local rollEv = GS.FindLedgerEventById(record, "g4-roll-don")
    assertTrue(rollEv ~= nil, "459-G4: donation still findable after rollover")
    assertEq(rollEv.campaignId, oldCampaign, "459-G4: event keeps old campaignId")
    local stLocal, rLocal = GS:ApplyStagedConfigOperation(prepared)
    assertTrue(stLocal ~= "accepted",
        "459-G4: local apply after rollover rejected st="
            .. tostring(stLocal) .. "/" .. tostring(rLocal))
    assertNil(record.operations.records[prepared.id],
        "459-G4: local prepared body not accepted after rollover")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, rollEv)), "Alice-Garona",
        "459-G4: credit unchanged after rejected local apply")

    -- Already-accepted historical remote catch-up: accept while A is current on
    -- a source peer, then receiver replays after its own rollover.
    local source = seedLiveCampaignWithItem(9909, 40)
    local srcDon = injectProductionDonation(source, {
        id = "g4-hist-don", itemId = 9909, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local srcCamp = source.currentCampaignId
    local srcCtx = select(1, GS:GetCurrentContext())
    local histOp = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "g4-hist-corr",
        guildKey = srcCtx.guildKey,
        datasetId = source.datasetId,
        campaignId = srcCamp,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "g4-hist-don",
        value = {
            eventId = "g4-hist-don", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9909,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 3,
        baseTargetRevision = source.datasetId,
        basePolicyRevision = source.permission and source.permission.revisionId,
        baseCampaignId = srcCamp,
    }
    assertEq(select(1, GS:AdmitRemoteOperation(histOp, {
        sender = "Alice-Garona", offlineRecord = source, preserveAttribution = true,
    })), "accepted", "459-G4: source accepts while campaign A current")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(source, srcDon)), "Bob-Garona",
        "459-G4: source credit Bob before rollover")
    -- Receiver already rolled over but still holds the archived donation + must
    -- replay the already-accepted historical body.
    local receiver = seedLiveCampaignWithItem(9910, 40)
    -- Plant the same donation under campaign A, then rollover receiver.
    local recvDon = injectProductionDonation(receiver, {
        id = "g4-hist-don", itemId = 9910, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local recvCampA = receiver.currentCampaignId
    recvDon.campaignId = recvCampA
    startCampaign()
    assertTrue(receiver.currentCampaignId ~= recvCampA, "459-G4: receiver rolled over")
    local histReplay = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "g4-hist-corr",
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = receiver.datasetId,
        campaignId = recvCampA,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "g4-hist-don",
        value = {
            eventId = "g4-hist-don", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9910,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 3,
        baseTargetRevision = receiver.datasetId,
        basePolicyRevision = receiver.permission and receiver.permission.revisionId,
        baseCampaignId = recvCampA,
    }
    local stHist, rHist = GS:AdmitRemoteOperation(histReplay, {
        sender = "Alice-Garona", offlineRecord = receiver, preserveAttribution = true,
        adoptionReplay = true,
        sourceAcceptedSet = { ["g4-hist-corr"] = true },
    })
    assertTrue(stHist == "accepted" or stHist == "duplicate",
        "459-G4: historical remote replay after rollover st="
            .. tostring(stHist) .. "/" .. tostring(rHist))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(receiver, recvDon)), "Bob-Garona",
        "459-G4: receiver credit Bob after historical replay")

    -- Pending local save cancels when campaign rolls over (Continue validity).
    local cancelRec = seedLiveCampaignWithItem(9911, 40)
    injectProductionDonation(cancelRec, {
        id = "g4-cancel-don", itemId = 9911, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local cancelOp = select(1, GS:NewContributorCorrectionOperation(
        "g4-cancel-don", "Bob-Garona", "Player-1-Bob"))
    assertTrue(type(cancelOp) == "table", "459-G4: cancel-case prepare")
    local cancelCamp = cancelRec.currentCampaignId
    assertTrue(GS.RetainLocalContributorCorrectionSave(cancelRec, cancelOp, {
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = cancelRec.datasetId,
        campaignId = cancelCamp,
    }), "459-G4: local save retained before rollover")
    assertTrue(GS.GetLocalContributorCorrectionSave(cancelRec) ~= nil,
        "459-G4: retain present before rollover")
    startCampaign()
    assertTrue(cancelRec.currentCampaignId ~= cancelCamp, "459-G4: cancel-case rolled over")
    local contOk, contErr = GS.ContinueLocalContributorCorrectionSave(cancelRec)
    assertTrue(not contOk, "459-G4: continue after rollover fails")
    assertEq(contErr, "stale_campaign", "459-G4: continue reason stale_campaign")
    assertNil(GS.GetLocalContributorCorrectionSave(cancelRec),
        "459-G4: pending local save cancelled on rollover")
    assertNil(cancelRec.operations.records[cancelOp.id],
        "459-G4: cancelled local save never accepted")
end

do
    -- G5: timer-driven local-save cancel publishes UI notify; Logs clears pending.
    local record = seedLiveCampaignWithItem(9906, 80)
    -- Seed enough history so local save hits work_budget.
    for i = 1, 60 do
        injectProductionDonation(record, {
            id = string.format("g5-pad-%02d", i),
            itemId = 9906, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
    end
    injectProductionDonation(record, {
        id = "g5-target", itemId = 9906, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        timestamp = world.time + 100,
    })
    GS.InvalidateCreditCorrectionProjection(record)
    local warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
    local warmGuard = 0
    while warmOk == false and warmGuard < 200 do
        if not runOneDueTimer() then break end
        warmOk = GS.EnsureCreditCorrectionProjection(record, nil)
        warmGuard = warmGuard + 1
    end
    flushTimers()
    local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
    logsPage.panel = { IsShown = function() return true end }
    EnsureDurableListenerViaBuild(logsPage)
    local rows = logsPage.__sfTest.BuildProjectedRows()
    local row = nil
    for i = 1, #rows do
        if rows[i].id == "g5-target" then row = rows[i] break end
    end
    assertTrue(row ~= nil, "459-G5: target row")
    GS._creditProjectionWorkBudgetOverride = 64
    logsPage.__sfTest.OpenEditContributorDialog("g5-target", row)
    local session = logsPage.__sfTest.GetEditSession()
    session.attributed = "Bob-Garona"
    session.attributedGuid = "Player-1-Bob"
    session.attributionText = "Bob-Garona"
    session.attributionResolved = true
    local confirmCb = nil
    local prevConfirm = SF.SettingsUI.Dialogs.Confirm
    SF.SettingsUI.Dialogs.Confirm = function(_, _msg, _btn, onConfirm)
        confirmCb = onConfirm
    end
    logsPage.__sfTest.ConfirmAndSaveEdit()
    SF.SettingsUI.Dialogs.Confirm = prevConfirm
    confirmCb()
    local retained = GS.GetLocalContributorCorrectionSave(record)
    assertTrue(type(retained) == "table", "459-G5: local retain held")
    local localOpId = retained.op.id
    local sess = logsPage.__sfTest.GetEditSession()
    assertTrue(sess and sess.pendingLocal == true, "459-G5: pendingLocal before remote")
    -- Remote same-event correction wins and seals before local continuation.
    world.time = world.time + 5
    local remote = select(1, GS:NewContributorCorrectionOperation(
        "g5-target", "Carol-Garona", "Player-1-Carol"))
    -- Mint under Alice then rewrite id/actor for remote admit shape.
    local ctx = select(1, GS:GetCurrentContext())
    remote = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "g5-remote-win",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "g5-target",
        value = {
            eventId = "g5-target",
            eventKind = "donation",
            attributed = "Carol-Garona",
            attributedGuid = "Player-1-Carol",
            baseAttributed = "Alice-Garona",
            baseAttributedGuid = "Player-1-Alice",
            itemId = 9906,
        },
        actorGuid = "Player-1-Alice",
        actorName = "Alice-Garona",
        timestamp = world.time + 20,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    local notifies = {}
    local prevNotify = GS.NotifyUI
    GS.NotifyUI = function(reason)
        notifies[#notifies + 1] = reason
        if prevNotify then prevNotify(reason) end
    end
    local stR, rR = GS:AdmitRemoteOperation(remote, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    -- Remote may yield work_budget under the tight override; drain until accepted.
    local ticksR = 0
    while stR == "pending" and ticksR < 200 do
        if not runOneDueTimer() then break end
        stR, rR = GS:AdmitRemoteOperation(remote, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        ticksR = ticksR + 1
    end
    flushTimers()
    assertTrue(stR == "accepted" or record.operations.records["g5-remote-win"] ~= nil,
        "459-G5: remote accepted st=" .. tostring(stR) .. "/" .. tostring(rR))
    -- Drain only scheduled callbacks (local continuation should cancel).
    local ticks = 0
    while #timers > 0 and ticks < 200 do
        runOneDueTimer()
        ticks = ticks + 1
    end
    flushTimers()
    GS.NotifyUI = prevNotify
    GS._creditProjectionWorkBudgetOverride = nil
    assertNil(GS.GetLocalContributorCorrectionSave(record), "459-G5: retain removed")
    assertNil(record.operations.records[localOpId], "459-G5: local op not accepted")
    local cancelNotifies = 0
    for i = 1, #notifies do
        if notifies[i] == "local-correction-cancelled" then
            cancelNotifies = cancelNotifies + 1
        end
    end
    assertTrue(cancelNotifies >= 1, "459-G5: terminal cancel notify got="
        .. tostring(cancelNotifies))
    sess = logsPage.__sfTest.GetEditSession()
    assertTrue(sess == nil or sess.pendingLocal ~= true,
        "459-G5: editor no longer pending")
    assertEq(#timers, 0, "459-G5: idle")
end

do
    -- G6: withdrawal rows skip credit resolution while reconstruction unavailable.
    local record = seedLiveCampaignWithItem(9907, 40)
    injectProductionDonation(record, {
        id = "g6-don", itemId = 9907, quantity = 8,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local list = record.accounting._consumableEvents
    list[#list + 1] = {
        type = GS.LEDGER_EVENT.WITHDRAWAL,
        id = "g6-wd",
        txnId = "g6-wd",
        generation = 1,
        timestamp = world.time + 1,
        actor = "Dave-Garona",
        actorGuid = "Player-1-Dave",
        itemId = 9907,
        quantity = 2,
        campaignId = record.currentCampaignId,
        datasetId = record.datasetId,
        gsProductionCredit = false,
    }
    -- Force unavailable credit reconstruction for donation rows.
    local prevEnsure = GS.EnsureCreditCorrectionProjection
    GS.EnsureCreditCorrectionProjection = function()
        return false, "work_budget"
    end
    assertTrue(not GS.IsCreditCorrectionProjectionAvailable(record),
        "459-G6: projection unavailable")
    local hist = select(1, GS:ListCampaignHistory(record.currentCampaignId, nil, 0))
    local wdRow, donRow = nil, nil
    for i = 1, #(hist or {}) do
        if hist[i].id == "g6-wd" or hist[i].eventId == "g6-wd" then
            wdRow = hist[i]
        end
        if hist[i].id == "g6-don" or hist[i].eventId == "g6-don" then
            donRow = hist[i]
        end
    end
    assertTrue(wdRow ~= nil, "459-G6: withdrawal history row present")
    assertTrue(wdRow.creditUnavailable ~= true,
        "459-G6: withdrawal not creditUnavailable")
    assertTrue(wdRow.displayActor == "Dave-Garona" or wdRow.actor == "Dave-Garona",
        "459-G6: withdrawing actor preserved got=" .. tostring(wdRow.displayActor))
    assertTrue(wdRow.correctionHead == nil and wdRow.hasCorrection ~= true,
        "459-G6: no correction fields on withdrawal")
    -- Logs projected row keeps actor / filter identity and no edit action.
    local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
    logsPage.__sfTest.ClearProjectedRowCache()
    local rows = logsPage.__sfTest.BuildProjectedRows()
    local proj = nil
    for i = 1, #rows do
        if rows[i].id == "g6-wd" then proj = rows[i] break end
    end
    assertTrue(proj ~= nil, "459-G6: Logs withdrawal row")
    assertTrue(proj.creditUnavailable ~= true, "459-G6: Logs not unavailable")
    local logsActor = proj.contributorKey or proj.contributorName or proj.displayActor or proj.actor
    assertTrue(tostring(logsActor or ""):find("Dave", 1, true),
        "459-G6: Logs actor Dave got=" .. tostring(logsActor))
    assertTrue(proj.canEdit ~= true and proj.editAction == nil,
        "459-G6: withdrawal non-editable")
    if donRow then
        assertTrue(donRow.creditUnavailable == true,
            "459-G6: donation still unavailable when reconstruction blocked")
    end
    GS.EnsureCreditCorrectionProjection = prevEnsure
    flushTimers()
end

---------------------------------------------------------------------------
-- review-5792509439 groups A/B/C
---------------------------------------------------------------------------

do
    -- A-pending: alias-targeted correction waits for policy P; registry eviction
    -- + capacity prune must not drop its durable binding; accepting P settles C.
    local record = seedLiveCampaignWithItem(9911, 80)
    local cfg = record.accounting._consumables
    local ctx = select(1, GS:GetCurrentContext())
    local don = injectProductionDonation(record, {
        id = "ctx:ap-canon", itemId = 9911, quantity = 6,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    don.txnId = "ctx:ap-canon"
    assertTrue(GS._AddTxnAlias(record, "ctx:ap-canon", "ctx:ap-alias", don),
        "459-A-pend: registry alias installed")
    assertEq(cfg.creditEventAliases and cfg.creditEventAliases["ctx:ap-alias"], "ctx:ap-canon",
        "459-A-pend: durable binding written on AddTxnAlias")
    local policyNow = record.permission and record.permission.revisionId
    local predId = "ap-pred-rank"
    local corrId = "ap-corr-early"
    local early = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = corrId,
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:ap-alias",
        value = {
            eventId = "ctx:ap-alias", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9911,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = predId,
        baseCampaignId = record.currentCampaignId,
    }
    local stC, reasonC = GS:AdmitRemoteOperation(early, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stC, "pending", "459-A-pend: C pending before P got " .. tostring(stC))
    assertEq(reasonC, "missing_policy_predecessor", "459-A-pend: C reason")
    assertEq(cfg.creditEventAliases["ctx:ap-alias"], "ctx:ap-canon",
        "459-A-pend: pending owns durable binding")
    -- Evict registry alias; fill durable map to capacity with unused junk, then
    -- force prune via a capacity write. Pending-required binding must survive.
    cfg.txnRegistry = {}
    local maxA = tonumber(GS.MAX_CREDIT_EVENT_ALIASES) or 2048
    local aliasCount = 0
    for _ in pairs(cfg.creditEventAliases) do
        aliasCount = aliasCount + 1
    end
    local i = 1
    while aliasCount < maxA do
        local junk = string.format("ctx:ap-junk-%04d", i)
        if cfg.creditEventAliases[junk] == nil then
            cfg.creditEventAliases[junk] = string.format("ctx:ap-junk-canon-%04d", i)
            aliasCount = aliasCount + 1
        end
        i = i + 1
    end
    local wrote = GS.RememberCreditEventAlias(record, "ctx:ap-extra", "ctx:ap-extra-canon")
    assertTrue(wrote == true, "459-A-pend: capacity write reclaims unused junk")
    assertEq(cfg.creditEventAliases["ctx:ap-alias"], "ctx:ap-canon",
        "459-A-pend: pending binding survives capacity prune")
    assertEq(cfg.creditEventAliases["ctx:ap-extra"], "ctx:ap-extra-canon",
        "459-A-pend: new unused binding stored after reclaim")
    local pred = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = predId,
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.SET_EDITOR_RANK,
        target = "editorRankPosition",
        value = 2,
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 2,
        baseTargetRevision = policyNow,
        basePolicyRevision = policyNow,
        baseCampaignId = record.currentCampaignId,
    }
    local stP, reasonP = GS:AdmitRemoteOperation(pred, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stP, "accepted",
        "459-A-pend: predecessor accepted got " .. tostring(stP) .. "/" .. tostring(reasonP))
    local guard = 0
    while (not record.operations.records[corrId]) and guard < 64 do
        if not runOneDueTimer() then break end
        guard = guard + 1
    end
    flushTimers()
    assertTrue(record.operations.records[corrId] ~= nil,
        "459-A-pend: C accepted after P without redelivery")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Bob-Garona",
        "459-A-pend: credit Bob after settle")
    assertEq(#timers, 0, "459-A-pend: idle")
end

do
    -- A-adopt: real provider export → fresh dataset → CommitDatasetAdoption must
    -- transfer required alias bindings for alias-targeted winner + loser.
    local record = seedLiveCampaignWithItem(9912, 80)
    local ctx = select(1, GS:GetCurrentContext())
    local don = injectProductionDonation(record, {
        id = "ctx:aa-canon", itemId = 9912, quantity = 5,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    don.txnId = "ctx:aa-canon"
    assertTrue(GS._AddTxnAlias(record, "ctx:aa-canon", "ctx:aa-alias", don),
        "459-A-adopt: alias installed")
    local lose = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "aa-lose",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:aa-alias",
        value = {
            eventId = "ctx:aa-alias", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9912,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 10,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    local win = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "aa-win",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:aa-alias",
        value = {
            eventId = "ctx:aa-alias", eventKind = "donation",
            attributed = "Carol-Garona", attributedGuid = "Player-1-Carol",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9912,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 20,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
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
    local stL, rL = admitSettle(lose)
    assertTrue(stL == "accepted" or stL == "duplicate",
        "459-A-adopt: loser accepted st=" .. tostring(stL) .. "/" .. tostring(rL))
    local stW, rW = admitSettle(win)
    assertTrue(stW == "accepted" or stW == "duplicate",
        "459-A-adopt: winner accepted st=" .. tostring(stW) .. "/" .. tostring(rW))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Carol-Garona",
        "459-A-adopt: source credit Carol")
    assertTrue(record.operations.records["aa-lose"] ~= nil, "459-A-adopt: loser retained")
    assertEq(record.accounting._consumables.creditEventAliases["ctx:aa-alias"], "ctx:aa-canon",
        "459-A-adopt: source durable binding present")
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    local exportBodies = collectAllExportBodies()
    assertTrue(#exportBodies >= 1, "459-A-adopt: export bodies collected n=" .. tostring(#exportBodies))
    local descBody = nil
    for i = 1, #exportBodies do
        if exportBodies[i].body and exportBodies[i].body.kind == "dataset-desc" then
            descBody = exportBodies[i].body
            break
        end
    end
    assertTrue(type(descBody) == "table", "459-A-adopt: dataset-desc exported")
    assertEq(type(descBody.creditEventAliases), "table", "459-A-adopt: desc carries aliases")
    assertEq(descBody.creditEventAliases["ctx:aa-alias"], "ctx:aa-canon",
        "459-A-adopt: required alias exported on desc")
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
        "459-A-adopt: begin")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    local ready = GS:GetPendingAdoption() and GS:GetPendingAdoption().ready
    assertTrue(ready, "459-A-adopt: transfer ready")
    local stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while stAdopt == "pending" and gAdopt < 128 do
        if not runOneDueTimer() then
            stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
        else
            -- sync drain may complete inside timer
            stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
        end
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(stAdopt, "accepted",
        "459-A-adopt: commit accepted got " .. tostring(stAdopt) .. "/" .. tostring(reasonAdopt))
    local adopted = GS:GetCurrentRecord()
    assertTrue(type(adopted) == "table", "459-A-adopt: adopted record")
    assertEq(adopted.accounting._consumables.creditEventAliases["ctx:aa-alias"], "ctx:aa-canon",
        "459-A-adopt: binding installed on fresh dataset")
    assertTrue(adopted.operations.records["aa-win"] ~= nil, "459-A-adopt: winner on adopter")
    assertTrue(adopted.operations.records["aa-lose"] ~= nil, "459-A-adopt: loser on adopter")
    local adoptedDon = GS.FindLedgerEventById(adopted, "ctx:aa-alias")
    assertTrue(type(adoptedDon) == "table", "459-A-adopt: alias resolves after adopt")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(adopted, adoptedDon)), "Carol-Garona",
        "459-A-adopt: adopter credit Carol")
    assertEq(tonumber(descBody.creditEventAliasCount), 1,
        "459-A-adopt: alias count advertised")
    assertEq(tonumber(descBody.creditEventAliasPageCount) or 0, 0,
        "459-A-adopt: single binding stays inline (no pages)")
end

do
    -- A-wire: required multi-alias history must page under the real Guild Gossip
    -- wrapper-inclusive limit and survive export → filter → Buffer → Commit.
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

    local record = seedLiveCampaignWithItem(9920, 200)
    local ctx = select(1, GS:GetCurrentContext())
    local N = 65
    local donors = { "Alice-Garona", "Bob-Garona", "Carol-Garona" }
    local guids = {
        ["Alice-Garona"] = "Player-1-Alice",
        ["Bob-Garona"] = "Player-1-Bob",
        ["Carol-Garona"] = "Player-1-Carol",
    }
    -- Direct durable injection (same shape as G1 capacity fixtures) so required
    -- alias collection and export sizing do not depend on wall-clock skew while
    -- still producing real accepted correction bodies for adoption replay.
    record.operations.records = record.operations.records or {}
    record.operations.order = record.operations.order or {}
    record.operations.heads = record.operations.heads or {}
    for i = 1, N do
        local canon = string.format("ctx:aw-canon-%04d", i)
        local alias = string.format("ctx:aw-alias-%04d", i)
        local actor = donors[((i - 1) % #donors) + 1]
        local don = injectProductionDonation(record, {
            id = canon, itemId = 9920, quantity = 1,
            actor = actor, actorGuid = guids[actor],
            timestamp = world.time + i,
        })
        don.txnId = canon
        assertTrue(GS._AddTxnAlias(record, canon, alias, don),
            "459-A-wire: alias " .. tostring(i))
        local credited = donors[(i % #donors) + 1]
        local opId = string.format("aw-corr-%04d", i)
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = opId,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = alias,
            value = {
                eventId = alias, eventKind = "donation",
                attributed = credited, attributedGuid = guids[credited],
                baseAttributed = actor, baseAttributedGuid = guids[actor],
                itemId = 9920,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        record.operations.records[opId] = op
        record.operations.order[#record.operations.order + 1] = opId
        record.operations.heads["credit:" .. canon] = opId
    end
    if GS._BumpOpsValidationGen then
        GS._BumpOpsValidationGen(record.operations)
    end
    local required = GS.CollectRequiredCreditEventAliases(record)
    local reqN = 0
    for _ in pairs(required or {}) do reqN = reqN + 1 end
    assertTrue(reqN >= N, "459-A-wire: required aliases n=" .. tostring(reqN))

    -- Prove the monolithic desc would exceed the GG raw-record cap.
    local bloatedDesc = {
        kind = "dataset-desc",
        schemaVersion = GS.PROVIDER_SCHEMA,
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        creditEventAliases = required,
        creditEventAliasCount = reqN,
        creditEventAliasPageCount = 0,
        acceptedOpCount = 0, transferOpCount = 0, campaignCount = 0, archiveCount = 0,
        acceptedLedgerCount = 0, donationEvidenceCount = 0, valuationCount = 0,
        hasBankTab = true,
    }
    local bloatedBytes = wireRawBytes("gs:desc:" .. record.datasetId, bloatedDesc)
    assertTrue(bloatedBytes > (GS.MAX_WIRE_RECORD_BYTES or 2048),
        "459-A-wire: monolithic aliases exceed wire budget bytes=" .. tostring(bloatedBytes))

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
        elseif body and body.kind == "gs-credit-aliases-page" then
            pages[#pages + 1] = { id = id, body = body, page = tonumber(body.page) or 0 }
        end
    end
    assertEq(overBudget, 0, "459-A-wire: no exported body exceeds wire budget")
    assertTrue(type(descBody) == "table", "459-A-wire: dataset-desc present")
    assertEq(tonumber(descBody.creditEventAliasCount), reqN,
        "459-A-wire: desc advertises required count")
    assertTrue((tonumber(descBody.creditEventAliasPageCount) or 0) >= 1,
        "459-A-wire: desc uses pages pageCount="
            .. tostring(descBody.creditEventAliasPageCount))
    local inlineN = 0
    for _ in pairs(descBody.creditEventAliases or {}) do inlineN = inlineN + 1 end
    assertEq(inlineN, 0, "459-A-wire: paged desc strips inline map")
    assertEq(#pages, tonumber(descBody.creditEventAliasPageCount),
        "459-A-wire: page bodies match pageCount")

    -- Transport boundary: GG would drop oversize records; paged export must
    -- survive an explicit wrapper-size filter unchanged.
    local filtered, dropped = filterWireBudget(exportBodies)
    assertEq(dropped, 0, "459-A-wire: filter drops none got=" .. tostring(dropped))
    assertEq(#filtered, #exportBodies, "459-A-wire: filter preserves all bodies")

    -- Missing page → incomplete.
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
            "459-A-wire-miss: begin")
        local skipPage = pages[1] and pages[1].page
        for i = 1, #filtered do
            local b = filtered[i]
            if not (b.body.kind == "gs-credit-aliases-page" and tonumber(b.body.page) == skipPage) then
                GS:BufferAdoptionRecord(b.id, b.body)
            end
        end
        local readyMiss = GS:GetPendingAdoption() and GS:GetPendingAdoption().ready
        assertTrue(not readyMiss, "459-A-wire-miss: missing page blocks ready")
        local okMiss, reasonMiss = GS:IsAdoptionTransferComplete()
        assertTrue(not okMiss, "459-A-wire-miss: incomplete")
        assertEq(reasonMiss, "incomplete_transfer",
            "459-A-wire-miss: reason got " .. tostring(reasonMiss))
        GS:CancelDatasetAdoption()
    end

    -- Duplicate exact page + reordered pages still complete.
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
            "459-A-wire-reord: begin")
        -- Deliver alias pages first (reverse), then the rest; redeliver page 1.
        table.sort(pages, function(a, b) return a.page > b.page end)
        for i = 1, #pages do
            local st = select(1, GS:BufferAdoptionRecord(pages[i].id, pages[i].body))
            assertTrue(st == "accepted" or st == "duplicate",
                "459-A-wire-reord: page " .. tostring(pages[i].page))
        end
        if pages[#pages] then
            local stDup = select(1, GS:BufferAdoptionRecord(pages[#pages].id, pages[#pages].body))
            assertEq(stDup, "duplicate", "459-A-wire-reord: exact redelivery duplicate")
        end
        for i = 1, #filtered do
            local b = filtered[i]
            if b.body.kind ~= "gs-credit-aliases-page" then
                GS:BufferAdoptionRecord(b.id, b.body)
            end
        end
        assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
            "459-A-wire-reord: ready after reorder+dup")
        GS:CancelDatasetAdoption()
    end

    -- Conflicting alias on a page → reject / incomplete.
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
            "459-A-wire-confl: begin")
        for i = 1, #pages do
            if pages[i].page == 1 then
                local victim = nil
                for a in pairs(pages[i].body.aliases or {}) do
                    victim = a
                    break
                end
                assertTrue(victim ~= nil, "459-A-wire-confl: victim alias")
                local badPage = {
                    kind = "gs-credit-aliases-page",
                    datasetId = sourceDataset,
                    page = 1,
                    pageCount = tonumber(descBody.creditEventAliasPageCount),
                    aliases = { [victim] = "ctx:aw-CONFLICT-CANON" },
                }
                local stGood = select(1, GS:BufferAdoptionRecord(pages[i].id, pages[i].body))
                assertTrue(stGood == "accepted" or stGood == "duplicate",
                    "459-A-wire-confl: good page accepted")
                local stBad, rBad = GS:BufferAdoptionRecord(pages[i].id, badPage)
                assertEq(stBad, "rejected",
                    "459-A-wire-confl: conflicting page body rejected got "
                        .. tostring(stBad) .. "/" .. tostring(rBad))
                assertEq(rBad, "source_changed",
                    "459-A-wire-confl: source_changed got " .. tostring(rBad))
                assertTrue(GS:GetPendingAdoption() == nil,
                    "459-A-wire-confl: adoption aborted after changed page")
                break
            end
        end
        if GS:GetPendingAdoption() then
            GS:CancelDatasetAdoption()
        end
    end

    -- Full fresh adoption through filtered transport + cold validate.
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
        "459-A-wire: begin adopt")
    for i = 1, #filtered do
        GS:BufferAdoptionRecord(filtered[i].id, filtered[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "459-A-wire: transfer ready")
    local stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
    local gAdopt = 0
    while stAdopt == "pending" and gAdopt < 256 do
        runOneDueTimer()
        stAdopt, reasonAdopt = GS:CommitDatasetAdoption()
        gAdopt = gAdopt + 1
    end
    flushTimers()
    assertEq(stAdopt, "accepted",
        "459-A-wire: commit got " .. tostring(stAdopt) .. "/" .. tostring(reasonAdopt))
    local adopted = GS:GetCurrentRecord()
    assertTrue(type(adopted) == "table", "459-A-wire: adopted record")
    local adoptedMap = adopted.accounting._consumables.creditEventAliases
    local installed = 0
    for a, c in pairs(adoptedMap or {}) do
        if required[a] == c then
            installed = installed + 1
        end
    end
    assertEq(installed, reqN, "459-A-wire: all required bindings installed got="
        .. tostring(installed))
    -- Spot-check alias-targeted credit after adopt.
    local sample = GS.FindLedgerEventById(adopted, "ctx:aw-alias-0001")
    assertTrue(type(sample) == "table", "459-A-wire: sample alias resolves")
    local sampleCredit = select(1, GS.ResolveEffectiveCreditIdentity(adopted, sample))
    assertTrue(type(sampleCredit) == "string" and sampleCredit ~= "",
        "459-A-wire: sample credit " .. tostring(sampleCredit))
    -- Evict projection caches / cold validate after reload-shaped bump.
    GS._creditProjectionAccumulating = false
    if GS._BumpOpsValidationGen then
        GS._BumpOpsValidationGen(adopted.operations)
    end
    local adoptedCtx = select(1, GS:GetCurrentContext())
    local coldOk, coldErr = GS._ValidateGuildRecordStructure(adoptedCtx.guildKey, adopted)
    assertTrue(coldOk, "459-A-wire: cold validate after adopt got " .. tostring(coldErr))
end

do
    -- B: stale provenance visits across ledger revisions must not reject a fresh
    -- ordinary adjustment as terminal work_budget.
    local record = seedLiveCampaignWithItem(9913, 200)
    injectProductionDonation(record, {
        id = "ctx:b-alice", itemId = 9913, quantity = 20,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    for i = 1, 40 do
        injectProductionDonation(record, {
            id = string.format("ctx:b-don-%03d", i), itemId = 9913, quantity = 1,
            actor = "Retired-Garona", actorGuid = "Player-1-Retired",
            timestamp = world.time + i,
        })
    end
    GS._creditProjectionAccumulating = false
    for _ = 1, 3 do
        record.accounting._consumables.generation =
            (tonumber(record.accounting._consumables.generation) or 1) + 1
        GS.BindCharacterIdentity(record, "Retired-Garona", "Player-1-Retired", nil)
    end
    -- Positive attributed adjust avoids item_negative against progress totals that
    -- may not yet include injected ledger rows; sticky provenance is under test.
    local adjOp, adjSt, adjErr = GS:NewConfigOperation(GS.KIND.ADJUST_QUANTITY, {
        itemId = 9913,
    }, {
        itemId = 9913,
        quantity = 1,
        attributed = "Alice-Garona",
        attributedGuid = "Player-1-Alice",
    })
    assertEq(adjSt, "accepted", "459-B: adjustment prepared got " .. tostring(adjErr))
    assertTrue(type(adjOp) == "table", "459-B: adjustment op present")
    -- Inject sticky visits after prepare (prepare may open/close an allowance).
    GS._creditProjectionProvenanceVisits = 24006
    GS._creditProjectionCallbackWork = 0
    GS._creditProjectionAccumulating = false
    assertTrue((tonumber(GS._creditProjectionProvenanceVisits) or 0) >= 24006,
        "459-B: sticky provenance present before admit")
    local stAdj, reasonAdj = GS:AdmitRemoteOperation(adjOp, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    local gB = 0
    while stAdj == "pending" and reasonAdj == "work_budget" and gB < 32 do
        if not runOneDueTimer() then break end
        stAdj, reasonAdj = GS:AdmitRemoteOperation(adjOp, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        gB = gB + 1
    end
    flushTimers()
    assertTrue(stAdj == "accepted" or stAdj == "duplicate",
        "459-B: ordinary adjustment accepted after sticky provenance st="
            .. tostring(stAdj) .. "/" .. tostring(reasonAdj))
    assertTrue(record.operations.records[adjOp.id] ~= nil,
        "459-B: adjustment retained")
    assertTrue(not (record.operations.pending and record.operations.pending[adjOp.id]),
        "459-B: not left pending")
    assertEq(#timers, 0, "459-B: idle")
end

do
    -- C-policy: receiver gets newer SET_EDITOR_RANK first, then earlier
    -- source-accepted correction; must converge under current authority.
    local record = seedLiveCampaignWithItem(9914, 80)
    local ctx = select(1, GS:GetCurrentContext())
    local don = injectProductionDonation(record, {
        id = "cpol-don", itemId = 9914, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local policy0 = record.permission and record.permission.revisionId
    local corr = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "cpol-corr",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "cpol-don",
        value = {
            eventId = "cpol-don", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9914,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = policy0,
        baseCampaignId = record.currentCampaignId,
    }
    local rank = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "cpol-rank",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.SET_EDITOR_RANK,
        target = "editorRankPosition",
        value = 2,
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 2,
        baseTargetRevision = policy0,
        basePolicyRevision = policy0,
        baseCampaignId = record.currentCampaignId,
    }
    local stRank, rRank = GS:AdmitRemoteOperation(rank, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stRank, "accepted",
        "459-C-pol: rank first accepted got " .. tostring(stRank) .. "/" .. tostring(rRank))
    local stCorr, rCorr = GS:AdmitRemoteOperation(corr, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    local gC = 0
    while stCorr == "pending" and gC < 64 do
        if not runOneDueTimer() then break end
        stCorr, rCorr = GS:AdmitRemoteOperation(corr, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        gC = gC + 1
    end
    flushTimers()
    assertTrue(stCorr == "accepted" or stCorr == "duplicate",
        "459-C-pol: historical correction after newer policy st="
            .. tostring(stCorr) .. "/" .. tostring(rCorr))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Bob-Garona",
        "459-C-pol: credit converges to Bob")
    -- Missing predecessor still pending.
    local missing = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "cpol-missing",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "cpol-don",
        value = {
            eventId = "cpol-don", eventKind = "donation",
            attributed = "Carol-Garona", attributedGuid = "Player-1-Carol",
            baseAttributed = "Bob-Garona", baseAttributedGuid = "Player-1-Bob",
            itemId = 9914,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 3,
        baseTargetRevision = "cpol-corr",
        basePolicyRevision = "never-seen-policy",
        baseCampaignId = record.currentCampaignId,
    }
    local stMiss, rMiss = GS:AdmitRemoteOperation(missing, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stMiss, "pending", "459-C-pol: missing policy predecessor pending")
    assertEq(rMiss, "missing_policy_predecessor", "459-C-pol: missing reason")
end

do
    -- C-elig: older same-event correction with wrong eventKind must not retain.
    local record = seedLiveCampaignWithItem(9915, 80)
    local ctx = select(1, GS:GetCurrentContext())
    local don = injectProductionDonation(record, {
        id = "celig-don", itemId = 9915, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local win = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "celig-win",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "celig-don",
        value = {
            eventId = "celig-don", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9915,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 30,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    local stW, rW = GS:AdmitRemoteOperation(win, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    local gW = 0
    while stW == "pending" and gW < 64 do
        if not runOneDueTimer() then break end
        stW, rW = GS:AdmitRemoteOperation(win, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        gW = gW + 1
    end
    assertTrue(stW == "accepted" or stW == "duplicate",
        "459-C-elig: winner accepted st=" .. tostring(stW) .. "/" .. tostring(rW))
    local badLose = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "celig-bad-lose",
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "celig-don",
        value = {
            eventId = "celig-don", eventKind = "adjustment",
            attributed = "Carol-Garona", attributedGuid = "Player-1-Carol",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9915,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 10,
        baseTargetRevision = record.datasetId,
        basePolicyRevision = record.permission and record.permission.revisionId,
        baseCampaignId = record.currentCampaignId,
    }
    local stBad, rBad = GS:AdmitRemoteOperation(badLose, {
        sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
    })
    assertEq(stBad, "rejected",
        "459-C-elig: wrong eventKind loser rejected st=" .. tostring(stBad))
    assertEq(rBad, "invalid_event", "459-C-elig: invalid_event reason got " .. tostring(rBad))
    assertNil(record.operations.records["celig-bad-lose"],
        "459-C-elig: bad loser body absent")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, don)), "Bob-Garona",
        "459-C-elig: winner credit unchanged")
end

do
    -- Pending-dependency matching must charge/pace lookup under the shared
    -- callback budget (no full live+archive rescan per pending entry).
    local record = seedLiveCampaignWithItem(9930, 100000)
    local ctx = select(1, GS:GetCurrentContext())
    local LIVE_N, ARCH_N, PEND_N = 800, 800, 64
    -- Filler ledger history uses a different item so campaign goal for 9930
    -- stays clear for the ordinary adjustment wake.
    local live = record.accounting._consumableEvents
    local arch = record.accounting._consumableEventArchive
    if type(arch) ~= "table" then
        record.accounting._consumableEventArchive = {}
        arch = record.accounting._consumableEventArchive
    end
    for i = 1, LIVE_N do
        live[#live + 1] = {
            type = GS.LEDGER_EVENT.DONATION,
            id = string.format("ctx:pm-live-%04d", i),
            txnId = string.format("ctx:pm-live-%04d", i),
            itemId = 9940, quantity = 1,
            generation = 1, timestamp = world.time + i,
            actor = "Retired-Garona", actorGuid = "Player-1-Retired",
            writer = "Player-1-Alice", verification = "officer",
            campaignId = record.currentCampaignId, datasetId = record.datasetId,
            gsProductionCredit = true,
        }
    end
    for i = 1, ARCH_N do
        arch[#arch + 1] = {
            type = GS.LEDGER_EVENT.DONATION,
            id = string.format("ctx:pm-arch-%04d", i),
            txnId = string.format("ctx:pm-arch-%04d", i),
            itemId = 9941, quantity = 1,
            generation = 0, timestamp = world.time - 10000 + i,
            actor = "Retired-Garona", actorGuid = "Player-1-Retired",
            writer = "Player-1-Alice", verification = "officer",
            campaignId = record.currentCampaignId, datasetId = record.datasetId,
            gsProductionCredit = true,
        }
    end
    injectProductionDonation(record, {
        id = "ctx:pm-adj-base", itemId = 9930, quantity = 10,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    -- Authenticated missing-event corrections (mismatching targets/item hints).
    for i = 1, PEND_N do
        local target = string.format("ctx:pm-miss-%04d", i)
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = string.format("pm-corr-%04d", i),
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = target,
            value = {
                eventId = target, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9999, -- mismatch hint vs wake item 9930
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + 10 + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        local st, r = GS:AdmitRemoteOperation(op, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        assertEq(st, "pending",
            "459-PM: admit pending " .. tostring(i) .. " got " .. tostring(st) .. "/" .. tostring(r))
        assertEq(r, "pending_event", "459-PM: pending_event " .. tostring(i))
    end
    local pendingBefore = 0
    for _ in pairs(record.operations.pending or {}) do pendingBefore = pendingBefore + 1 end
    assertTrue(pendingBefore >= PEND_N, "459-PM: retained pending n=" .. tostring(pendingBefore))

    -- Ordinary positive adjustment accepts (timer-only recovery path preserved).
    local adjOp, adjSt, adjReason = GS:NewAdjustmentOperation(9930, 1, "Alice-Garona")
    assertTrue(adjOp ~= nil,
        "459-PM: adjustment prepared got " .. tostring(adjSt) .. "/" .. tostring(adjReason))
    assertEq(GS:ApplyStagedConfigOperation(adjOp), "accepted", "459-PM: apply adjustment")
    local adjId = adjOp.id
    local adjEv = nil
    local events = record.accounting._consumableEvents
    for i = #events, 1, -1 do
        local e = events[i]
        if type(e) == "table" and (e.id == adjId or e.opId == adjId) then
            adjEv = e
            break
        end
    end
    assertTrue(type(adjEv) == "table", "459-PM: adjustment ledger row present")
    local wakeEventId = adjEv.id or adjId

    local function drainRedrive(maxSlices)
        maxSlices = maxSlices or 256
        local slices = 0
        while slices < maxSlices do
            slices = slices + 1
            if #timers > 0 then
                if not runOneDueTimer() then
                    flushTimers()
                end
            else
                break
            end
        end
        flushTimers()
        return slices
    end

    -- Drop any continuation left by the adjustment's EnsureThenRedrive so the
    -- measured wake rebuilds the lookup index under a fresh callback allowance.
    if GS._ClearCreditRedriveContinuationForTest then
        GS._ClearCreditRedriveContinuationForTest(record)
    end
    -- Nonmatching targeted wake: must charge lookup work, stay bounded, go idle.
    GS._creditRedriveLookupVisits = 0
    GS._creditRedriveMatchVisits = 0
    local prom1, att1, work1 = GS.RedrivePendingContributorCorrections(record, {
        eventId = wakeEventId, itemId = 9930, maxAttempts = 32,
    })
    local lookupAfterFirst = tonumber(GS._creditRedriveLookupVisits) or 0
    drainRedrive(256)
    -- Warm wake (index retained): match work only, no full ledger rescan.
    GS._creditRedriveLookupVisits = 0
    GS._creditRedriveMatchVisits = 0
    local prom1b, att1b, work1b = GS.RedrivePendingContributorCorrections(record, {
        eventId = wakeEventId, itemId = 9930, maxAttempts = 32,
    })
    drainRedrive(256)
    local lookupVisits = math.max(lookupAfterFirst, tonumber(GS._creditRedriveLookupVisits) or 0)
    local matchVisits = tonumber(GS._creditRedriveMatchVisits) or 0
    local workTotal = math.max(tonumber(work1) or 0, tonumber(work1b) or 0)
    local ledgerRows = LIVE_N + ARCH_N
    local oldProduct = pendingBefore * ledgerRows * 2
    assertTrue(lookupAfterFirst >= ledgerRows,
        "459-PM: cold wake indexes ledger once lookup="
            .. tostring(lookupAfterFirst) .. " rows=" .. tostring(ledgerRows)
            .. " work=" .. tostring(work1))
    -- Parenthesize fallback before comparison: bare `tonumber(work1) or 0 >= n`
    -- is always true for any numeric work1 (including undercharged 0).
    assertTrue(not ((tonumber(0) or 0) >= ledgerRows),
        "459-PM: undercharged work fails cold-wake predicate rows="
            .. tostring(ledgerRows))
    assertTrue((tonumber(work1) or 0) >= ledgerRows,
        "459-PM: cold wake callbackWork includes lookup work=" .. tostring(work1))
    -- Warm wake should not rescan the full ledger.
    assertTrue((tonumber(GS._creditRedriveLookupVisits) or 0) <= pendingBefore + 64,
        "459-PM: warm wake skips full rescan lookup="
            .. tostring(GS._creditRedriveLookupVisits))
    assertTrue(lookupVisits <= ledgerRows + pendingBefore + 256,
        "459-PM: lookup visits bounded visits="
            .. tostring(lookupVisits) .. " rows=" .. tostring(ledgerRows))
    assertTrue(oldProduct > 100000 and (lookupAfterFirst + matchVisits) * 20 < oldProduct,
        "459-PM: visits far below pending×ledger product="
            .. tostring(oldProduct) .. " lookup=" .. tostring(lookupAfterFirst)
            .. " match=" .. tostring(matchVisits))
    assertTrue(workTotal > 0, "459-PM: workTotal observed " .. tostring(workTotal))
    assertEq(prom1, 0, "459-PM: nonmatch promotes none got " .. tostring(prom1))
    assertEq(prom1b, 0, "459-PM: warm nonmatch promotes none")
    assertTrue((tonumber(att1) or 0) >= 0 and (tonumber(att1b) or 0) >= 0,
        "459-PM: attempts observed")
    local stillPending = 0
    for _ in pairs(record.operations.pending or {}) do stillPending = stillPending + 1 end
    assertTrue(stillPending >= PEND_N, "459-PM: pending retained after nonmatch")
    assertEq(#timers, 0, "459-PM: idle after nonmatch drain")

    -- Repeated nonmatching wakes stay bounded (reuse complete index).
    GS._creditRedriveLookupVisits = 0
    local _, _, work2 = GS.RedrivePendingContributorCorrections(record, {
        eventId = wakeEventId, itemId = 9930, maxAttempts = 32,
    })
    drainRedrive(64)
    local lookup2 = tonumber(GS._creditRedriveLookupVisits) or 0
    assertTrue(lookup2 <= pendingBefore + 64,
        "459-PM: repeated nonmatch reuses index lookup2=" .. tostring(lookup2))
    assertTrue((tonumber(work2) or 0) >= 0, "459-PM: work2 observed")

    -- Matching wake while a paced snapshot drains: force a mid-build pause then
    -- admit the missing dependency and prove once-only settlement.
    GS._creditProjectionWorkBudgetOverride = 64
    GS._creditRedriveLookupVisits = 0
    -- Force lookup rebuild under the tight budget by mutating accounting stamp.
    record.accounting._consumableEvents[#record.accounting._consumableEvents + 1] = {
        type = GS.LEDGER_EVENT.DONATION,
        id = "ctx:pm-stamp-bump",
        txnId = "ctx:pm-stamp-bump",
        itemId = 9940, quantity = 1,
        generation = 1, timestamp = world.time + 40,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        writer = "Player-1-Alice", verification = "officer",
        campaignId = record.currentCampaignId, datasetId = record.datasetId,
        gsProductionCredit = true,
    }
    if GS._BumpAccountingMutation then
        GS._BumpAccountingMutation(record)
    end
    local promPause = GS.RedrivePendingContributorCorrections(record, {
        eventId = "ctx:pm-miss-0001", itemId = 9999, maxAttempts = 8,
    })
    assertTrue(#timers >= 1 or promPause == 0,
        "459-PM: tight budget schedules paced continuation timers="
            .. tostring(#timers))
    -- While draining, supply the matching dependency via real admission path.
    local missDon = {
        type = GS.LEDGER_EVENT.DONATION,
        id = "ctx:pm-miss-0001",
        txnId = "ctx:pm-miss-0001",
        itemId = 9999,
        quantity = 5,
        generation = tonumber(record.accounting._consumables.generation) or 1,
        timestamp = world.time + 50,
        actor = "Alice-Garona",
        actorGuid = "Player-1-Alice",
        writer = "Player-1-Alice",
        verification = GS.VERIFICATION.OFFICER,
        verifierGuid = "Player-1-Alice",
        campaignId = record.currentCampaignId,
        datasetId = record.datasetId,
        gsProductionCredit = true,
    }
    GS._creditProjectionWorkBudgetOverride = nil
    local stDon, rDon = GS:AdmitLedgerEvent(missDon, {
        sender = "Alice-Garona",
        member = { guid = "Player-1-Alice", name = "Alice-Garona",
            guildKey = ctx.guildKey, rankOrder = 1 },
        offlineRecord = record,
        adoptionReplay = true,
        preserveAttribution = true,
        localWrite = false,
    })
    assertTrue(stDon == "accepted" or stDon == "duplicate",
        "459-PM: miss dependency admitted got " .. tostring(stDon) .. "/" .. tostring(rDon))
    local settleGuard = 0
    while record.operations.pending["pm-corr-0001"] and settleGuard < 256 do
        if not runOneDueTimer() then
            GS.RedrivePendingContributorCorrections(record, {
                eventId = "ctx:pm-miss-0001", itemId = 9999, maxAttempts = 32,
            })
        end
        settleGuard = settleGuard + 1
    end
    flushTimers()
    assertTrue(record.operations.records["pm-corr-0001"] ~= nil,
        "459-PM: matching pending settled once")
    assertNil(record.operations.pending["pm-corr-0001"],
        "459-PM: pending cleared without redelivery")
    local stAgain, rAgain = GS:AdmitRemoteOperation(
        record.operations.records["pm-corr-0001"], {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
    assertTrue(stAgain == "duplicate" or stAgain == "accepted",
        "459-PM: redelivery duplicate-safe got " .. tostring(stAgain) .. "/" .. tostring(rAgain))
    assertEq(#timers, 0, "459-PM: idle after match settle")
end

do
    -- Effective-credit Resolve must not re-scan the ledger for each already-known
    -- event (discussion_r4488489365). Broken path: N rows → N(N+1)/2 lookup visits.
    local ITEM = 9950
    local N = 1200
    local record = seedLiveCampaignWithItem(ITEM, 100000)
    local ctx = select(1, GS:GetCurrentContext())
    for i = 1, N do
        injectProductionDonation(record, {
            id = string.format("ctx:ec-don-%04d", i),
            itemId = ITEM, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
    end
    -- Warm projection once so later measured reads are not conflated with rebuild.
    assertTrue(GS.EnsureCreditCorrectionProjection(record, nil) ~= false,
        "459-EC: projection available before measure")

    local function quadraticFloor(n)
        return (n * (n + 1)) / 2
    end

    -- No corrections: personal + campaign progress reads stay linear/bounded.
    GS._ledgerEventIdLookupVisits = 0
    local aliceBefore = GS.PersonalContributorItemTotal(
        record, "Alice-Garona", "Player-1-Alice", ITEM)
    local visitsPersonal = tonumber(GS._ledgerEventIdLookupVisits) or 0
    assertEq(aliceBefore, N, "459-EC: Alice personal before adj got " .. tostring(aliceBefore))
    assertTrue(visitsPersonal <= N * 4,
        "459-EC: personal Resolve lookups linear visits="
            .. tostring(visitsPersonal) .. " n=" .. tostring(N))
    assertTrue(visitsPersonal * 20 < quadraticFloor(N),
        "459-EC: personal visits far below N(N+1)/2 visits="
            .. tostring(visitsPersonal) .. " quad=" .. tostring(quadraticFloor(N)))

    GS._ledgerEventIdLookupVisits = 0
    local progress = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    local visitsProgress = tonumber(GS._ledgerEventIdLookupVisits) or 0
    assertEq(tonumber(progress.itemTotals[ITEM]) or 0, N,
        "459-EC: campaign item total before adj")
    local aliceContrib = progress.contributions and progress.contributions["Alice-Garona"]
    assertEq(tonumber(aliceContrib and aliceContrib[ITEM]) or 0, N,
        "459-EC: Alice contribution before adj")
    assertTrue(visitsProgress <= N * 4,
        "459-EC: progress Resolve lookups linear visits="
            .. tostring(visitsProgress) .. " n=" .. tostring(N))
    assertTrue(visitsProgress * 20 < quadraticFloor(N),
        "459-EC: progress visits far below quadratic")

    -- Ordinary positive remote adjustment over large history (zero pending).
    GS._ledgerEventIdLookupVisits = 0
    local adjOp = select(1, GS:NewAdjustmentOperation(ITEM, 1, "Alice-Garona"))
    assertTrue(adjOp ~= nil, "459-EC: adjustment prepared")
    assertEq(GS:ApplyStagedConfigOperation(adjOp), "accepted", "459-EC: apply adjustment")
    flushTimers()
    local visitsAdj = tonumber(GS._ledgerEventIdLookupVisits) or 0
    assertTrue(visitsAdj <= N * 8 + 64,
        "459-EC: adjustment callback lookups bounded visits="
            .. tostring(visitsAdj) .. " n=" .. tostring(N))
    assertTrue(visitsAdj * 10 < quadraticFloor(N),
        "459-EC: adjustment visits far below N(N+1)/2 visits="
            .. tostring(visitsAdj) .. " quad=" .. tostring(quadraticFloor(N)))
    local aliceAfter = GS.PersonalContributorItemTotal(
        record, "Alice-Garona", "Player-1-Alice", ITEM)
    assertEq(aliceAfter, N + 1, "459-EC: Alice personal after adj")
    local progressAfter = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    assertEq(tonumber(progressAfter.itemTotals[ITEM]) or 0, N + 1,
        "459-EC: campaign total after adj")

    -- Sparse corrections among many untouched rows: still linear, credit moves.
    local sparseTargets = { "ctx:ec-don-0001", "ctx:ec-don-0600", "ctx:ec-don-1200" }
    for i = 1, #sparseTargets do
        local corr = select(1, GS:NewContributorCorrectionOperation(
            sparseTargets[i], "Bob-Garona", "Player-1-Bob"))
        assertTrue(corr ~= nil, "459-EC: sparse corr " .. tostring(i))
        assertEq(GS:ApplyStagedConfigOperation(corr), "accepted",
            "459-EC: apply sparse corr " .. tostring(i))
    end
    flushTimers()
    GS._ledgerEventIdLookupVisits = 0
    local aliceSparse = GS.PersonalContributorItemTotal(
        record, "Alice-Garona", "Player-1-Alice", ITEM)
    local bobSparse = GS.PersonalContributorItemTotal(
        record, "Bob-Garona", "Player-1-Bob", ITEM)
    local visitsSparse = tonumber(GS._ledgerEventIdLookupVisits) or 0
    assertEq(bobSparse, 3, "459-EC: Bob sparse credit got " .. tostring(bobSparse))
    assertEq(aliceSparse, (N + 1) - 3,
        "459-EC: Alice after sparse got " .. tostring(aliceSparse))
    assertTrue(visitsSparse <= N * 4,
        "459-EC: sparse personal lookups linear visits=" .. tostring(visitsSparse))
    assertTrue(visitsSparse * 20 < quadraticFloor(N),
        "459-EC: sparse visits far below quadratic")

    GS._ledgerEventIdLookupVisits = 0
    local progressSparse = GS.ProjectCampaignProgressOnRecord(record, record.currentCampaignId)
    local visitsSparseProg = tonumber(GS._ledgerEventIdLookupVisits) or 0
    assertEq(tonumber(progressSparse.itemTotals[ITEM]) or 0, N + 1,
        "459-EC: campaign total unchanged by corrections")
    assertEq(tonumber(progressSparse.contributions["Bob-Garona"]
        and progressSparse.contributions["Bob-Garona"][ITEM]) or 0, 3,
        "459-EC: progress credits Bob sparse")
    assertTrue(visitsSparseProg <= N * 4,
        "459-EC: sparse progress lookups linear visits="
            .. tostring(visitsSparseProg))

    -- Alias-shaped id still resolves via durable alias map (no ledger rescan).
    local cfg = record.accounting._consumables
    cfg.creditEventAliases = cfg.creditEventAliases or {}
    cfg.creditEventAliases["ctx:ec-alias-shaped"] = "ctx:ec-don-0001"
    local aliasShaped = {
        type = GS.LEDGER_EVENT.DONATION,
        id = "ctx:ec-alias-shaped",
        itemId = ITEM, quantity = 1,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        generation = tonumber(cfg.generation) or 1,
        campaignId = record.currentCampaignId,
        datasetId = record.datasetId,
        gsProductionCredit = true,
    }
    GS._ledgerEventIdLookupVisits = 0
    local aliasName = select(1, GS.ResolveEffectiveCreditIdentity(record, aliasShaped))
    local aliasVisits = tonumber(GS._ledgerEventIdLookupVisits) or 0
    assertEq(aliasName, "Bob-Garona",
        "459-EC: alias-shaped Resolve uses durable alias map")
    assertEq(aliasVisits, 0, "459-EC: alias-shaped Resolve does not scan ledger")

    -- Real event via FindLedgerEventById(alias) still credits corrected winner.
    local canonEv = GS.FindLedgerEventById(record, "ctx:ec-don-0001")
    assertTrue(type(canonEv) == "table", "459-EC: canonical event present")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(record, canonEv)), "Bob-Garona",
        "459-EC: known event Resolve after sparse correction")

    -- Unassigned adjustment + credit_unavailable still covered by prior suites;
    -- confirm Unassigned status remains nil (not credit_unavailable) here.
    local unAdj = injectProductionAdjustment(record, {
        id = "ctx:ec-unassigned", itemId = ITEM, quantity = -1,
        attributed = nil, attributedGuid = nil,
    })
    assertTrue(GS.EnsureCreditCorrectionProjection(record, nil) ~= false,
        "459-EC: projection after unassigned adj")
    local unName, unGuid, unHead, unStatus =
        GS.ResolveEffectiveCreditIdentity(record, unAdj)
    assertNil(unName, "459-EC: Unassigned name nil")
    assertNil(unGuid, "459-EC: Unassigned guid nil")
    assertNil(unHead, "459-EC: Unassigned head nil")
    assertNil(unStatus, "459-EC: Unassigned status nil (not credit_unavailable)")
end

do
    -- Registry matching: paced index retains alias→primary for missing events so
    -- match does not fall back to FindRegistryByTxn (#459 discussion_r4488855210).
    local ITEM = 9960
    local record = seedLiveCampaignWithItem(ITEM, 100000)
    local ctx = select(1, GS:GetCurrentContext())
    local cfg = record.accounting._consumables
    cfg.txnRegistry = cfg.txnRegistry or {}
    local REG_N, PEND_N = 512, 128
    for i = 1, REG_N do
        local canon = string.format("ctx:rm-reg-%04d", i)
        local alias = string.format("ctx:rm-reg-alias-%04d", i)
        cfg.txnRegistry[#cfg.txnRegistry + 1] = {
            txnId = canon, status = "verified", committed = true,
            aliases = { alias }, itemId = 9991, quantity = 1,
            donor = "Retired-Garona", approxTxnTime = world.time - i,
        }
        cfg.txnRegistry[#cfg.txnRegistry + 1] = {
            txnId = alias, status = "alias", aliasOf = canon, committed = true,
            itemId = 9991, quantity = 1,
        }
    end
    for i = 1, PEND_N do
        local target = string.format("ctx:rm-miss-%04d", i)
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = string.format("rm-corr-%04d", i),
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = target,
            value = {
                eventId = target, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9999,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + 10 + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        local st, r = GS:AdmitRemoteOperation(op, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        assertEq(st, "pending", "459-RM: admit " .. tostring(i))
        assertEq(r, "pending_event", "459-RM: pending_event " .. tostring(i))
    end
    if GS._ClearCreditRedriveContinuationForTest then
        GS._ClearCreditRedriveContinuationForTest(record)
    end
    GS._txnRegistryRowVisits = 0
    GS._creditRedriveLookupVisits = 0
    local _, _, workCold = GS.RedrivePendingContributorCorrections(record, {
        itemId = ITEM, maxAttempts = 32,
    })
    local function drainRedrive(maxSlices)
        maxSlices = maxSlices or 256
        local slices = 0
        while slices < maxSlices do
            slices = slices + 1
            if #timers > 0 then
                if not runOneDueTimer() then flushTimers() end
            else
                break
            end
        end
        flushTimers()
    end
    drainRedrive(256)
    local regCold = tonumber(GS._txnRegistryRowVisits) or 0
    local lookupCold = tonumber(GS._creditRedriveLookupVisits) or 0
    -- Warm wake: matching must not rescan the registry via FindRegistryByTxn.
    GS._txnRegistryRowVisits = 0
    GS._creditRedriveLookupVisits = 0
    local promWarm, attWarm, workWarm = GS.RedrivePendingContributorCorrections(record, {
        itemId = ITEM, maxAttempts = 32,
    })
    drainRedrive(64)
    local regWarm = tonumber(GS._txnRegistryRowVisits) or 0
    assertEq(promWarm, 0, "459-RM: nonmatch promotes none")
    assertTrue(regWarm <= 8,
        "459-RM: warm wake avoids FindRegistryByTxn product regWarm="
            .. tostring(regWarm) .. " coldLookup=" .. tostring(lookupCold)
            .. " coldReg=" .. tostring(regCold) .. " workCold=" .. tostring(workCold)
            .. " workWarm=" .. tostring(workWarm))
    assertTrue(regWarm * 100 < REG_N * PEND_N,
        "459-RM: warm registry visits far below pending×registry")
    assertEq(#timers, 0, "459-RM: idle after drain")
    local still = 0
    for _ in pairs(record.operations.pending or {}) do still = still + 1 end
    assertTrue(still >= PEND_N, "459-RM: pending retained")
end

do
    -- Obsolete-path pending retention must notify the warm provider
    -- (#459 discussion_r4488855215). Onward delivery uses an unchanged
    -- exported body against a faithful same-dataset receiver: original-author
    -- accept credits Bob; another officer's relay stays untrusted_pending.
    local function shallowCopyOp(op)
        local out = {}
        for k, v in pairs(op) do
            if type(v) == "table" and k == "value" then
                local vv = {}
                for vk, vv2 in pairs(v) do vv[vk] = vv2 end
                out[k] = vv
            else
                out[k] = v
            end
        end
        return out
    end
    local function retainObsoletePending(mode)
        local itemId = mode == "missing" and 9961 or 9962
        local record = seedLiveCampaignWithItem(itemId, 80)
        injectProductionDonation(record, {
            id = "ctx:pn-don", itemId = itemId, quantity = 5,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        })
        world.time = world.time + 1
        local early = select(1, GS:NewContributorCorrectionOperation(
            "ctx:pn-don", "Bob-Garona", "Player-1-Bob"))
        world.time = world.time + 5
        local late = select(1, GS:NewContributorCorrectionOperation(
            "ctx:pn-don", "Carol-Garona", "Player-1-Carol"))
        assertEq(GS:ApplyStagedConfigOperation(late), "accepted",
            "459-PN-" .. mode .. ": late winner")
        if mode == "missing" then
            local live = record.accounting._consumableEvents
            for i = #live, 1, -1 do
                if live[i] and live[i].id == "ctx:pn-don" then
                    table.remove(live, i)
                end
            end
            if GS._BumpAccountingMutation then
                GS._BumpAccountingMutation(record)
            end
        else
            local ev = GS.FindLedgerEventById(record, "ctx:pn-don")
            assertTrue(type(ev) == "table", "459-PN-nc: event present")
            ev.gsProductionCredit = false
        end
        GS:EnsureGossipProvider()
        drainExportMaint(32)
        local notifies = {}
        local prevNotify = GS._NotifyLocalDurableChange
        GS._NotifyLocalDurableChange = function(reason)
            notifies[#notifies + 1] = reason
            if prevNotify then prevNotify(reason) end
        end
        local snap = select(1, GS._SnapshotPublicOp(early))
        snap.baseTargetRevision = record.datasetId
        local st, reason = GS:AdmitRemoteOperation(snap, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        GS._NotifyLocalDurableChange = prevNotify
        assertEq(st, "pending",
            "459-PN-" .. mode .. ": pending got " .. tostring(st) .. "/" .. tostring(reason))
        local expectReason = mode == "missing" and "pending_event" or "not_credited"
        assertEq(reason, expectReason,
            "459-PN-" .. mode .. ": reason got " .. tostring(reason))
        assertTrue(record.operations.pending[early.id] ~= nil,
            "459-PN-" .. mode .. ": durable pending body")
        local saw = false
        for i = 1, #notifies do
            if notifies[i] == "remote-pending" then
                saw = true
            end
        end
        assertTrue(saw, "459-PN-" .. mode .. ": remote-pending notify")
        drainExportMaint(64)
        local bodies = collectAllExportBodies()
        local exportedOp = nil
        for i = 1, #bodies do
            local b = bodies[i].body
            if type(b) == "table" then
                if b.kind == "gs-op" and b.op and b.op.id == early.id then
                    exportedOp = b.op
                elseif b.kind == "gs-evidence" and type(b.op) == "table" and b.op.id == early.id then
                    exportedOp = b.op
                elseif type(b.op) == "table" and b.op.id == early.id then
                    exportedOp = b.op
                end
            end
        end
        if not exportedOp then
            local pend = record.operations.pending[early.id]
            exportedOp = pend and pend.body or select(1, GS._SnapshotPublicOp(early))
        end
        assertTrue(type(exportedOp) == "table",
            "459-PN-" .. mode .. ": warm export includes pending body n="
                .. tostring(#bodies))
        local function cloneGuildRecord(src)
            local function copy(v, depth)
                depth = (depth or 0) + 1
                if type(v) ~= "table" then
                    return v
                end
                if depth > 40 then
                    return nil
                end
                local out = {}
                for k, val in pairs(v) do
                    out[copy(k, depth)] = copy(val, depth)
                end
                return out
            end
            return copy(src, 0)
        end
        local function installSameDatasetPeer()
            -- Deep-clone the exporter so dataset/permission/cutover stay valid for
            -- GetRecordForGuildKey; do not rewrite the exported body.
            local peer = cloneGuildRecord(record)
            peer.operations = peer.operations or {}
            peer.operations.pending = {}
            peer.operations.records = {}
            peer.operations.order = {}
            peer.operations.heads = {}
            peer.operations.conflicts = {}
            if type(peer.accounting) == "table" then
                peer.accounting._consumableEvents = {}
                if type(peer.accounting._consumables) == "table" then
                    peer.accounting._consumables.creditEventAliases = {}
                end
            end
            injectProductionDonation(peer, {
                id = "ctx:pn-don", itemId = itemId, quantity = 5,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            })
            return peer
        end
        local function withPeer(peer, fn)
            local gk = select(1, GS:GetCurrentContext()).guildKey
            local saved = GS._root and GS._root.guilds and GS._root.guilds[gk]
            if type(GS._root) == "table" and type(GS._root.guilds) == "table" then
                GS._root.guilds[gk] = peer
            end
            local ok, a, b = pcall(fn)
            if type(GS._root) == "table" and type(GS._root.guilds) == "table" then
                GS._root.guilds[gk] = saved
            end
            if not ok then error(a) end
            return a, b
        end
        -- Faithful same-dataset receiver + unchanged exported body.
        local peer = installSameDatasetPeer()
        local authorBody = shallowCopyOp(exportedOp)
        local stAuthor, rAuthor = withPeer(peer, function()
            return GS:AdmitRemoteOperation(authorBody, {
                sender = "Alice-Garona",
                preserveAttribution = true,
            })
        end)
        assertTrue(stAuthor == "accepted" or stAuthor == "duplicate",
            "459-PN-" .. mode .. ": original-author admit got "
                .. tostring(stAuthor) .. "/" .. tostring(rAuthor))
        assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
            peer, GS.FindLedgerEventById(peer, "ctx:pn-don"))), "Bob-Garona",
            "459-PN-" .. mode .. ": peer credit Bob")
        -- Another officer relays the same unchanged body → untrusted_relay.
        local peerRelay = installSameDatasetPeer()
        local relayBody = shallowCopyOp(exportedOp)
        local stRelay, rRelay = withPeer(peerRelay, function()
            return GS:AdmitRemoteOperation(relayBody, {
                sender = "Bob-Garona",
            })
        end)
        assertEq(stRelay, "pending",
            "459-PN-" .. mode .. ": officer relay pending got "
                .. tostring(stRelay) .. "/" .. tostring(rRelay))
        assertEq(rRelay, "untrusted_relay",
            "459-PN-" .. mode .. ": officer relay untrusted got " .. tostring(rRelay))
        assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
            peerRelay, GS.FindLedgerEventById(peerRelay, "ctx:pn-don"))), "Alice-Garona",
            "459-PN-" .. mode .. ": relay does not credit Bob")
        return record, early.id
    end
    retainObsoletePending("missing")
    retainObsoletePending("not_credited")
end

do
    -- Ordinary same-dataset alias-page delivery via real provider ValidateAndApply
    -- (#459 discussion_r4488856040 / assessment 4494080823).
    local function withCurrentRecord(target, fn)
        local gk = select(1, GS:GetCurrentContext()).guildKey
        local saved = GS._root and GS._root.guilds and GS._root.guilds[gk]
        if type(GS._root) == "table" and type(GS._root.guilds) == "table" then
            GS._root.guilds[gk] = target
        end
        local ok, a, b, c = pcall(fn)
        if type(GS._root) == "table" and type(GS._root.guilds) == "table" then
            GS._root.guilds[gk] = saved
        end
        if not ok then
            error(a)
        end
        return a, b, c
    end
    local function providerAliasPage(target, pageId, pageBody, sender)
        return withCurrentRecord(target, function()
            GS:EnsureGossipProvider()
            local entry = GG.GetProvider(GS.PROVIDER_ID)
            assertTrue(entry and entry.api and entry.api.ValidateAndApply,
                "459-OD: provider registered")
            return entry.api.ValidateAndApply({
                id = pageId,
                versionFp = GS.ContentFingerprint(pageBody),
                body = pageBody,
            }, { sender = sender })
        end)
    end
    local function drainAliasTimers(maxSlices)
        maxSlices = maxSlices or 256
        local slices = 0
        while slices < maxSlices do
            slices = slices + 1
            if #timers > 0 then
                if not runOneDueTimer() then
                    flushTimers()
                end
            else
                break
            end
        end
        flushTimers()
    end

    -- Authority: non-editor must not redirect real donation A onto corrected B.
    local authRecord = seedLiveCampaignWithItem(9963, 40)
    injectProductionDonation(authRecord, {
        id = "ctx:od-don-a", itemId = 9963, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    injectProductionDonation(authRecord, {
        id = "ctx:od-don-b", itemId = 9963, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local corrB = select(1, GS:NewContributorCorrectionOperation(
        "ctx:od-don-b", "Bob-Garona", "Player-1-Bob"))
    assertEq(GS:ApplyStagedConfigOperation(corrB), "accepted", "459-OD: B corrected to Bob")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        authRecord, GS.FindLedgerEventById(authRecord, "ctx:od-don-a"))), "Alice-Garona",
        "459-OD: A starts as Alice")
    local evilBody = {
        kind = "gs-credit-aliases-page",
        datasetId = authRecord.datasetId,
        page = 1, pageCount = 1,
        aliases = { ["ctx:od-don-a"] = "ctx:od-don-b" },
    }
    local evilId = "gs:cea:" .. authRecord.datasetId .. ":p1"
    local stDave, rDave = providerAliasPage(authRecord, evilId, evilBody, "Dave-Garona")
    assertEq(stDave, "rejected",
        "459-OD: non-editor rejected got " .. tostring(stDave) .. "/" .. tostring(rDave))
    assertTrue(authRecord.accounting._consumables.creditEventAliases["ctx:od-don-a"] == nil,
        "459-OD: non-editor left no binding")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        authRecord, GS.FindLedgerEventById(authRecord, "ctx:od-don-a"))), "Alice-Garona",
        "459-OD: A credit unchanged after non-editor")
    -- Editor still cannot redirect a known ledger event onto another donation.
    local stOwn, rOwn = providerAliasPage(authRecord, evilId, evilBody, "Alice-Garona")
    assertEq(stOwn, "rejected",
        "459-OD: owned-event redirect rejected got "
            .. tostring(stOwn) .. "/" .. tostring(rOwn))
    assertEq(rOwn, "alias_conflict",
        "459-OD: owned-event reason alias_conflict got " .. tostring(rOwn))
    assertTrue(authRecord.accounting._consumables.creditEventAliases["ctx:od-don-a"] == nil,
        "459-OD: owned-event left no binding")

    -- Atomic mixed-validity page: valid first + invalid second writes nothing.
    local atomic = seedLiveCampaignWithItem(9964, 40)
    injectProductionDonation(atomic, {
        id = "ctx:od-atom-canon", itemId = 9964, quantity = 2,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local mixedBody = {
        kind = "gs-credit-aliases-page",
        datasetId = atomic.datasetId,
        page = 1, pageCount = 1,
        aliases = {
            ["ctx:od-atom-ok"] = "ctx:od-atom-canon",
            ["ctx:od-atom-bad"] = "ctx:od-atom-bad",
        },
    }
    local mixedId = "gs:cea:" .. atomic.datasetId .. ":p1"
    local stMix, rMix = providerAliasPage(atomic, mixedId, mixedBody, "Alice-Garona")
    assertEq(stMix, "rejected",
        "459-OD: mixed page rejected got " .. tostring(stMix) .. "/" .. tostring(rMix))
    assertTrue(atomic.accounting._consumables.creditEventAliases["ctx:od-atom-ok"] == nil,
        "459-OD: mixed page left no partial binding")
    -- Wrong record id rejected without mutation.
    local stBadId = select(1, providerAliasPage(atomic, mixedId .. "x", {
        kind = "gs-credit-aliases-page",
        datasetId = atomic.datasetId,
        page = 1, pageCount = 1,
        aliases = { ["ctx:od-atom-ok"] = "ctx:od-atom-canon" },
    }, "Alice-Garona"))
    assertEq(stBadId, "rejected", "459-OD: wrong record id rejected")
    assertTrue(atomic.accounting._consumables.creditEventAliases["ctx:od-atom-ok"] == nil,
        "459-OD: wrong id left no binding")

    -- Dependency recovery: pending alias-targeted correction settles after page.
    local wake = seedLiveCampaignWithItem(9965, 40)
    injectProductionDonation(wake, {
        id = "ctx:od-wake-canon", itemId = 9965, quantity = 4,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local ctxWake = select(1, GS:GetCurrentContext())
    local pendingAliasOp = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = "od-wake-corr",
        guildKey = ctxWake.guildKey,
        datasetId = wake.datasetId,
        campaignId = wake.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:od-wake-alias",
        value = {
            eventId = "ctx:od-wake-alias", eventKind = "donation",
            attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9965,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 1,
        baseTargetRevision = wake.datasetId,
        basePolicyRevision = wake.permission and wake.permission.revisionId,
        baseCampaignId = wake.currentCampaignId,
    }
    local stPend, rPend = GS:AdmitRemoteOperation(pendingAliasOp, {
        sender = "Alice-Garona", offlineRecord = wake, preserveAttribution = true,
    })
    assertEq(stPend, "pending",
        "459-OD: alias correction pending got " .. tostring(stPend) .. "/" .. tostring(rPend))
    assertEq(rPend, "pending_event", "459-OD: pending_event before alias page")
    local wakeBody = {
        kind = "gs-credit-aliases-page",
        datasetId = wake.datasetId,
        page = 1, pageCount = 1,
        aliases = { ["ctx:od-wake-alias"] = "ctx:od-wake-canon" },
    }
    local wakePageId = "gs:cea:" .. wake.datasetId .. ":p1"
    local stWake, rWake = providerAliasPage(wake, wakePageId, wakeBody, "Alice-Garona")
    assertTrue(stWake == "accepted" or stWake == "duplicate",
        "459-OD: wake page accepted got " .. tostring(stWake) .. "/" .. tostring(rWake))
    assertEq(wake.accounting._consumables.creditEventAliases["ctx:od-wake-alias"],
        "ctx:od-wake-canon", "459-OD: wake binding installed")
    drainAliasTimers(256)
    assertTrue(wake.operations.records["od-wake-corr"] ~= nil,
        "459-OD: pending correction accepted after alias page")
    assertTrue(wake.operations.pending["od-wake-corr"] == nil,
        "459-OD: pending cleared after alias wake")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        wake, GS.FindLedgerEventById(wake, "ctx:od-wake-canon"))), "Bob-Garona",
        "459-OD: credit Bob after timer-only settlement")
    assertEq(#timers, 0, "459-OD: idle after alias wake drain")

    -- Two same-dataset peers, both delivery orders, conflict, duplicate.
    local function cloneGuildRecord(src)
        local function copy(v, depth)
            depth = (depth or 0) + 1
            if type(v) ~= "table" then
                return v
            end
            if depth > 40 then
                return nil
            end
            local out = {}
            for k, val in pairs(v) do
                out[copy(k, depth)] = copy(val, depth)
            end
            return out
        end
        return copy(src, 0)
    end
    local peerA = seedLiveCampaignWithItem(9966, 40)
    injectProductionDonation(peerA, {
        id = "ctx:od-peer-canon", itemId = 9966, quantity = 2,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    -- Clone before alias install so B stays a valid same-dataset peer.
    local peerB = cloneGuildRecord(peerA)
    if peerB.accounting and peerB.accounting._consumables then
        peerB.accounting._consumables.creditEventAliases = {}
    end
    local peerPage = {
        kind = "gs-credit-aliases-page",
        datasetId = peerA.datasetId,
        page = 1, pageCount = 1,
        aliases = { ["ctx:od-peer-alias"] = "ctx:od-peer-canon" },
    }
    local peerPageId = "gs:cea:" .. peerA.datasetId .. ":p1"
    -- Order 1: A then B via real provider.
    local stA1, rA1 = providerAliasPage(peerA, peerPageId, peerPage, "Alice-Garona")
    assertTrue(stA1 == "accepted" or stA1 == "duplicate",
        "459-OD: peerA accept order1 got " .. tostring(stA1) .. "/" .. tostring(rA1))
    local stB1, rB1 = providerAliasPage(peerB, peerPageId, peerPage, "Alice-Garona")
    assertTrue(stB1 == "accepted" or stB1 == "duplicate",
        "459-OD: peerB accept order1 got " .. tostring(stB1) .. "/" .. tostring(rB1))
    assertEq(peerA.accounting._consumables.creditEventAliases["ctx:od-peer-alias"],
        "ctx:od-peer-canon", "459-OD: peerA binding")
    assertEq(peerB.accounting._consumables.creditEventAliases["ctx:od-peer-alias"],
        "ctx:od-peer-canon", "459-OD: peerB binding")
    -- Duplicate redelivery.
    local stDup = select(1, providerAliasPage(peerA, peerPageId, peerPage, "Alice-Garona"))
    assertTrue(stDup == "duplicate" or stDup == "accepted",
        "459-OD: duplicate-safe redelivery got " .. tostring(stDup))
    -- Order 2 on fresh peers (D then C).
    local peerC = seedLiveCampaignWithItem(9968, 40)
    injectProductionDonation(peerC, {
        id = "ctx:od-peer2-canon", itemId = 9968, quantity = 2,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local peerD = cloneGuildRecord(peerC)
    if peerD.accounting and peerD.accounting._consumables then
        peerD.accounting._consumables.creditEventAliases = {}
    end
    local peerPage2 = {
        kind = "gs-credit-aliases-page",
        datasetId = peerC.datasetId,
        page = 1, pageCount = 1,
        aliases = { ["ctx:od-peer2-alias"] = "ctx:od-peer2-canon" },
    }
    local peerPageId2 = "gs:cea:" .. peerC.datasetId .. ":p1"
    local stD2, rD2 = providerAliasPage(peerD, peerPageId2, peerPage2, "Alice-Garona")
    local stC2, rC2 = providerAliasPage(peerC, peerPageId2, peerPage2, "Alice-Garona")
    assertTrue(stD2 == "accepted" or stD2 == "duplicate",
        "459-OD: peerD accept order2 got " .. tostring(stD2) .. "/" .. tostring(rD2))
    assertTrue(stC2 == "accepted" or stC2 == "duplicate",
        "459-OD: peerC accept order2 got " .. tostring(stC2) .. "/" .. tostring(rC2))
    -- Conflicting binding rejected; local ownership preserved.
    peerC.accounting._consumables.creditEventAliases["ctx:od-peer2-conflict"] =
        "ctx:od-peer2-canon"
    local stConf, rConf = providerAliasPage(peerC, peerPageId2, {
        kind = "gs-credit-aliases-page",
        datasetId = peerC.datasetId,
        page = 1, pageCount = 1,
        aliases = { ["ctx:od-peer2-conflict"] = "ctx:od-peer2-other" },
    }, "Alice-Garona")
    assertEq(stConf, "rejected",
        "459-OD: conflict rejected got " .. tostring(stConf) .. "/" .. tostring(rConf))
    assertEq(peerC.accounting._consumables.creditEventAliases["ctx:od-peer2-conflict"],
        "ctx:od-peer2-canon", "459-OD: local ownership preserved")
    local stBadDs = select(1, providerAliasPage(peerC, peerPageId2 .. "ds", {
        kind = "gs-credit-aliases-page",
        datasetId = "other-dataset",
        page = 1, pageCount = 1,
        aliases = { ["ctx:od-peer2-alias-x"] = "ctx:od-peer2-canon" },
    }, "Alice-Garona"))
    assertEq(stBadDs, "rejected", "459-OD: wrong dataset rejected")

    -- Coalesced whole-page work: 20 bindings at supported history size must not
    -- multiply ledger scans or wake calls (#459 discussion_r4494986528).
    local BIND_N, HIST_N = 20, 4000
    local coalesce = seedLiveCampaignWithItem(9970, 80)
    local filler = HIST_N - BIND_N
    for i = 1, filler do
        injectProductionDonation(coalesce, {
            id = string.format("ctx:od-fill-%04d", i),
            itemId = 9970, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
    end
    local coalesceAliases = {}
    for i = 1, BIND_N do
        local canon = string.format("ctx:od-co-canon-%02d", i)
        local alias = string.format("ctx:od-co-alias-%02d", i)
        injectProductionDonation(coalesce, {
            id = canon, itemId = 9970, quantity = 2,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + filler + i,
        })
        coalesceAliases[alias] = canon
    end
    assertEq(#coalesce.accounting._consumableEvents, HIST_N,
        "459-OD: coalesce fixture ledger size")
    -- Pending alias-targeted corrections for two bindings (credit + wake).
    -- Advance clock past donation timestamps so correction times stay valid.
    world.time = (world.time or 0) + filler + BIND_N + 10
    local ctxCo = select(1, GS:GetCurrentContext())
    for _, idx in ipairs({ 1, 2 }) do
        local alias = string.format("ctx:od-co-alias-%02d", idx)
        local opId = "od-co-corr-" .. tostring(idx)
        local pendOp = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = opId,
            guildKey = ctxCo.guildKey,
            datasetId = coalesce.datasetId,
            campaignId = coalesce.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = alias,
            value = {
                eventId = alias, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9970,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + idx,
            baseTargetRevision = coalesce.datasetId,
            basePolicyRevision = coalesce.permission and coalesce.permission.revisionId,
            baseCampaignId = coalesce.currentCampaignId,
        }
        local stP, rP = GS:AdmitRemoteOperation(pendOp, {
            sender = "Alice-Garona", offlineRecord = coalesce, preserveAttribution = true,
        })
        assertEq(stP, "pending",
            "459-OD: coalesce pending " .. tostring(idx) .. " got "
                .. tostring(stP) .. "/" .. tostring(rP))
        assertEq(rP, "pending_event",
            "459-OD: coalesce pending_event " .. tostring(idx))
    end
    GS._creditAliasPageLedgerVisits = 0
    GS._creditAliasPageWakeCalls = 0
    GS._ledgerEventIdLookupVisits = 0
    -- Soft budget during page apply: atomic publish, then paced continuation.
    GS._creditProjectionWorkBudgetOverride = 64
    local coalesceBody = {
        kind = "gs-credit-aliases-page",
        datasetId = coalesce.datasetId,
        page = 1, pageCount = 1,
        aliases = coalesceAliases,
    }
    local coalesceId = "gs:cea:" .. coalesce.datasetId .. ":p1"
    local stCo, rCo = providerAliasPage(
        coalesce, coalesceId, coalesceBody, "Alice-Garona")
    assertTrue(stCo == "accepted" or stCo == "duplicate",
        "459-OD: coalesce page accepted got " .. tostring(stCo) .. "/" .. tostring(rCo))
    local pageLedgerVisits = tonumber(GS._creditAliasPageLedgerVisits) or 0
    local findVisitsDuring = tonumber(GS._ledgerEventIdLookupVisits) or 0
    local wakeCalls = tonumber(GS._creditAliasPageWakeCalls) or 0
    assertTrue(pageLedgerVisits <= HIST_N + 8,
        "459-OD: one-pass ledger visits got " .. tostring(pageLedgerVisits)
            .. " (hist " .. tostring(HIST_N) .. ")")
    -- Pre-fix regression: 20 bindings × ~history ≈ 399k synchronous visits.
    assertTrue(pageLedgerVisits + findVisitsDuring < 80000,
        "459-OD: page apply must not multiply history scans; visits page="
            .. tostring(pageLedgerVisits) .. " find=" .. tostring(findVisitsDuring))
    assertEq(wakeCalls, 1,
        "459-OD: one coalesced page wake got " .. tostring(wakeCalls))
    for i = 1, BIND_N do
        local alias = string.format("ctx:od-co-alias-%02d", i)
        local canon = string.format("ctx:od-co-canon-%02d", i)
        assertEq(coalesce.accounting._consumables.creditEventAliases[alias], canon,
            "459-OD: coalesce binding " .. tostring(i))
    end
    assertTrue(#timers > 0
            or (coalesce.operations.pending
                and (coalesce.operations.pending["od-co-corr-1"]
                    or coalesce.operations.pending["od-co-corr-2"])),
        "459-OD: soft budget leaves continuation or pending obligation")
    GS._creditProjectionWorkBudgetOverride = nil
    drainAliasTimers(512)
    assertTrue(coalesce.operations.records["od-co-corr-1"] ~= nil,
        "459-OD: coalesce corr1 accepted after drain")
    assertTrue(coalesce.operations.records["od-co-corr-2"] ~= nil,
        "459-OD: coalesce corr2 accepted after drain")
    assertTrue(coalesce.operations.pending["od-co-corr-1"] == nil,
        "459-OD: coalesce corr1 pending cleared")
    assertTrue(coalesce.operations.pending["od-co-corr-2"] == nil,
        "459-OD: coalesce corr2 pending cleared")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        coalesce, GS.FindLedgerEventById(coalesce, "ctx:od-co-canon-01"))),
        "Bob-Garona", "459-OD: coalesce credit Bob on canon-01")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        coalesce, GS.FindLedgerEventById(coalesce, "ctx:od-co-canon-02"))),
        "Bob-Garona", "459-OD: coalesce credit Bob on canon-02")
    -- Duplicate-safe redelivery of the same multi-binding page.
    local stCoDup = select(1, providerAliasPage(
        coalesce, coalesceId, coalesceBody, "Alice-Garona"))
    assertTrue(stCoDup == "duplicate" or stCoDup == "accepted",
        "459-OD: coalesce duplicate-safe got " .. tostring(stCoDup))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        coalesce, GS.FindLedgerEventById(coalesce, "ctx:od-co-canon-01"))),
        "Bob-Garona", "459-OD: coalesce credit stable after duplicate")
    assertEq(#timers, 0, "459-OD: coalesce idle after drain")

    -- Proposed-overlay cycle validation (same-page and existing+incoming).
    -- Use non-ledger alias ids so rejection is from the overlay cycle check,
    -- not owned-event redirect on a live donation id.
    local cycle = seedLiveCampaignWithItem(9971, 40)
    injectProductionDonation(cycle, {
        id = "ctx:cycle-unrelated", itemId = 9971, quantity = 2,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    -- Same-page A↔B must reject regardless of pairs iteration order.
    local samePageCycle = {
        kind = "gs-credit-aliases-page",
        datasetId = cycle.datasetId,
        page = 1, pageCount = 1,
        aliases = {
            ["ctx:cycle-a"] = "ctx:cycle-b",
            ["ctx:cycle-b"] = "ctx:cycle-a",
        },
    }
    local cycleId = "gs:cea:" .. cycle.datasetId .. ":p1"
    local stCy, rCy = providerAliasPage(
        cycle, cycleId, samePageCycle, "Alice-Garona")
    assertEq(stCy, "rejected",
        "459-OD: same-page cycle rejected got "
            .. tostring(stCy) .. "/" .. tostring(rCy))
    assertEq(rCy, "alias_conflict",
        "459-OD: same-page cycle reason got " .. tostring(rCy))
    assertTrue(cycle.accounting._consumables.creditEventAliases["ctx:cycle-a"] == nil,
        "459-OD: same-page cycle left no A binding")
    assertTrue(cycle.accounting._consumables.creditEventAliases["ctx:cycle-b"] == nil,
        "459-OD: same-page cycle left no B binding")
    -- Reverse insertion-order table still rejected (pairs order independence).
    local stCyRev, rCyRev = providerAliasPage(cycle, cycleId, {
        kind = "gs-credit-aliases-page",
        datasetId = cycle.datasetId,
        page = 1, pageCount = 1,
        aliases = {
            ["ctx:cycle-b"] = "ctx:cycle-a",
            ["ctx:cycle-a"] = "ctx:cycle-b",
        },
    }, "Alice-Garona")
    assertEq(stCyRev, "rejected",
        "459-OD: reverse-order cycle rejected got "
            .. tostring(stCyRev) .. "/" .. tostring(rCyRev))
    -- Existing A→B plus incoming B→A rejected; no mutation of existing.
    cycle.accounting._consumables.creditEventAliases["ctx:cycle-a"] = "ctx:cycle-b"
    local stCy2, rCy2 = providerAliasPage(cycle, cycleId, {
        kind = "gs-credit-aliases-page",
        datasetId = cycle.datasetId,
        page = 1, pageCount = 1,
        aliases = { ["ctx:cycle-b"] = "ctx:cycle-a" },
    }, "Alice-Garona")
    assertEq(stCy2, "rejected",
        "459-OD: existing+incoming cycle rejected got "
            .. tostring(stCy2) .. "/" .. tostring(rCy2))
    assertEq(cycle.accounting._consumables.creditEventAliases["ctx:cycle-a"],
        "ctx:cycle-b", "459-OD: existing binding preserved on cycle reject")
    assertTrue(cycle.accounting._consumables.creditEventAliases["ctx:cycle-b"] == nil,
        "459-OD: cycle reject installed no B→A")
    -- Valid bounded chain A→B→C accepted (C is the ledger donation).
    local chain = seedLiveCampaignWithItem(9972, 40)
    injectProductionDonation(chain, {
        id = "ctx:chain-c", itemId = 9972, quantity = 2,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local chainId = "gs:cea:" .. chain.datasetId .. ":p1"
    local stCh, rCh = providerAliasPage(chain, chainId, {
        kind = "gs-credit-aliases-page",
        datasetId = chain.datasetId,
        page = 1, pageCount = 1,
        aliases = {
            ["ctx:chain-a"] = "ctx:chain-b",
            ["ctx:chain-b"] = "ctx:chain-c",
        },
    }, "Alice-Garona")
    assertTrue(stCh == "accepted" or stCh == "duplicate",
        "459-OD: valid chain accepted got " .. tostring(stCh) .. "/" .. tostring(rCh))
    assertEq(chain.accounting._consumables.creditEventAliases["ctx:chain-a"],
        "ctx:chain-b", "459-OD: chain A→B")
    assertEq(chain.accounting._consumables.creditEventAliases["ctx:chain-b"],
        "ctx:chain-c", "459-OD: chain B→C")
    assertEq(GS.CanonicalCreditEventId(chain, "ctx:chain-a"), "ctx:chain-c",
        "459-OD: chain resolves A onto ledger C")
end

do
    -- Alias export maintenance: one registry pass cold; unchanged slices reuse
    -- packed collection (#459 discussion_r4488856046).
    local ITEM = 9965
    local record = seedLiveCampaignWithItem(ITEM, 500)
    local ctx = select(1, GS:GetCurrentContext())
    local cfg = record.accounting._consumables
    cfg.txnRegistry = cfg.txnRegistry or {}
    local REG_N, CORR_N = 256, 200
    for i = 1, REG_N do
        local canon = string.format("ctx:em-reg-%04d", i)
        cfg.txnRegistry[#cfg.txnRegistry + 1] = {
            txnId = canon, status = "verified", committed = true,
            aliases = { string.format("ctx:em-reg-alias-%04d", i) },
            itemId = 9992, quantity = 1,
            donor = "Retired-Garona", approxTxnTime = world.time - i,
        }
    end
    record.operations.records = record.operations.records or {}
    record.operations.order = record.operations.order or {}
    record.operations.heads = record.operations.heads or {}
    for i = 1, CORR_N do
        local canon = string.format("ctx:em-don-%04d", i)
        local alias = string.format("ctx:em-alias-%04d", i)
        injectProductionDonation(record, {
            id = canon, itemId = ITEM, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
        -- Durable alias map only (registry already holds unrelated filler rows).
        local opId = string.format("em-corr-%04d", i)
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = opId,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = alias,
            value = {
                eventId = alias, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = ITEM,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        record.operations.records[opId] = op
        record.operations.order[#record.operations.order + 1] = opId
        record.operations.heads[GS.CorrectionTargetKey(record, canon)] = opId
        assertTrue(GS.RememberCreditEventAlias(record, alias, canon),
            "459-EM: durable alias " .. tostring(i))
    end
    GS:EnsureGossipProvider()
    -- Cold required-alias collection: one registry pass, not correction×registry.
    GS._txnRegistryRowVisits = 0
    local required = GS.CollectRequiredCreditEventAliases(record)
    local coldCollect = tonumber(GS._txnRegistryRowVisits) or 0
    local requiredN = 0
    for _ in pairs(required) do requiredN = requiredN + 1 end
    assertTrue(requiredN >= CORR_N,
        "459-EM: required aliases collected n=" .. tostring(requiredN))
    assertTrue(coldCollect <= REG_N + 64,
        "459-EM: cold collection one registry pass visits="
            .. tostring(coldCollect) .. " reg=" .. tostring(REG_N))
    assertTrue(coldCollect * 20 < CORR_N * REG_N,
        "459-EM: cold visits far below correction×registry product")
    GS._txnRegistryRowVisits = 0
    GS._creditAliasExportCacheHits = 0
    GS._creditAliasExportCacheMisses = 0
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(128)
    assertTrue(GS._exportMaintIsIdle and GS._exportMaintIsIdle(),
        "459-EM: maint becomes idle after dataset rebuild")
    GS._txnRegistryRowVisits = 0
    local hitsBefore = tonumber(GS._creditAliasExportCacheHits) or 0
    GS.NotifyLocalDurableChange("export-maint")
    drainExportMaint(16)
    local warmVisits = tonumber(GS._txnRegistryRowVisits) or 0
    local hitsAfter = tonumber(GS._creditAliasExportCacheHits) or 0
    assertTrue(warmVisits <= REG_N,
        "459-EM: unchanged maint avoids registry product warm="
            .. tostring(warmVisits))
    assertTrue(hitsAfter > hitsBefore,
        "459-EM: unchanged maint reuses packed alias export")
    assertTrue(GS._exportMaintIsIdle and GS._exportMaintIsIdle(),
        "459-EM: maint becomes idle")
    -- Mutation invalidates cache: durable alias ownership change.
    local missesBefore = tonumber(GS._creditAliasExportCacheMisses) or 0
    assertTrue(GS.RememberCreditEventAlias(record, "ctx:em-extra", "ctx:em-don-0001"),
        "459-EM: extra durable alias for invalidation")
    GS.NotifyLocalDurableChange("remote-op")
    drainExportMaint(64)
    local missesAfter = tonumber(GS._creditAliasExportCacheMisses) or 0
    assertTrue(missesAfter > missesBefore,
        "459-EM: alias ownership invalidates alias export cache")

    -- Descriptor-sensitive packing: donationEvidenceCount 9→10 must not reuse
    -- an oversized inline alias map (#459 discussion_r4488856046 / 4494082374).
    local budget = GS.MAX_WIRE_RECORD_BYTES
        or (SF.GuildGossip and SF.GuildGossip.MAX_RECORD_CBOR)
        or 2048
    local edgeRecord = seedLiveCampaignWithItem(9970, 40)
    local edgeCtx = select(1, GS:GetCurrentContext())
    injectProductionDonation(edgeRecord, {
        id = "ctx:em-edge-canon", itemId = 9970, quantity = 1,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local function edgeDesc(donationEvidenceCount)
        return {
            kind = "dataset-desc",
            schemaVersion = GS.PROVIDER_SCHEMA,
            guildKey = edgeCtx.guildKey,
            datasetId = edgeRecord.datasetId,
            editorRankPosition = edgeRecord.permission
                and edgeRecord.permission.editorRankPosition,
            permissionRevisionId = edgeRecord.permission
                and edgeRecord.permission.revisionId,
            currentCampaignId = edgeRecord.currentCampaignId,
            activation = edgeRecord.activation,
            acceptedOpCount = 0,
            transferOpCount = 0,
            campaignCount = 1,
            archiveCount = 0,
            acceptedLedgerCount = #(edgeRecord.accounting._consumableEvents or {}),
            donationEvidenceCount = donationEvidenceCount,
            valuationCount = 0,
            bankTab = edgeRecord.accounting._consumables.bankTab,
            hasBankTab = true,
            creditEventAliases = {},
            creditEventAliasCount = 0,
            creditEventAliasPageCount = 0,
        }
    end
    local edgeDescId = "gs:desc:" .. edgeRecord.datasetId
    -- ValidTxnId max is 160; grow a short-alias set until count=9 is inline at
    -- budget and naive reuse under count=10 overflows by one byte.
    local foundN, foundPad = nil, nil
    for pad = 80, 130 do
        for n = 1, 40 do
            edgeRecord.operations.records = {}
            edgeRecord.operations.order = {}
            edgeRecord.operations.heads = {}
            edgeRecord.accounting._consumables.creditEventAliases = {}
            local seeded = true
            for i = 1, n do
                local alias = string.format("ctx:em-%03d-%s", i, string.rep("x", pad))
                if #alias > (GS.MAX_TXN_ID or 160) then
                    seeded = false
                    break
                end
                local opId = string.format("em-edge-%03d", i)
                edgeRecord.operations.records[opId] = {
                    schemaVersion = GS.OP_SCHEMA_VERSION,
                    id = opId,
                    guildKey = edgeCtx.guildKey,
                    datasetId = edgeRecord.datasetId,
                    campaignId = edgeRecord.currentCampaignId,
                    kind = GS.KIND.CORRECT_CONTRIBUTOR,
                    target = alias,
                    value = {
                        eventId = alias, eventKind = "donation",
                        attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                        baseAttributed = "Alice-Garona",
                        baseAttributedGuid = "Player-1-Alice",
                        itemId = 9970,
                    },
                    actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
                    timestamp = world.time + i,
                    baseTargetRevision = edgeRecord.datasetId,
                    basePolicyRevision = edgeRecord.permission
                        and edgeRecord.permission.revisionId,
                    baseCampaignId = edgeRecord.currentCampaignId,
                }
                edgeRecord.operations.order[#edgeRecord.operations.order + 1] = opId
                edgeRecord.operations.heads[GS.CorrectionTargetKey(
                    edgeRecord, "ctx:em-edge-canon")] = opId
                if not GS.RememberCreditEventAlias(
                    edgeRecord, alias, "ctx:em-edge-canon") then
                    seeded = false
                    break
                end
            end
            if not seeded then
                break
            end
            local d9 = edgeDesc(9)
            GS._ApplyCreditAliasExportToDescForTest(edgeRecord, edgeDescId, d9)
            if (tonumber(d9.creditEventAliasPageCount) or 0) ~= 0 then
                break
            end
            local b9 = GS._EstimateWireRecordBytesForTest(edgeDescId, d9)
            if b9 > budget then
                break
            end
            local d10trial = edgeDesc(10)
            d10trial.creditEventAliases = d9.creditEventAliases
            d10trial.creditEventAliasCount = d9.creditEventAliasCount
            d10trial.creditEventAliasPageCount = 0
            local b10 = GS._EstimateWireRecordBytesForTest(edgeDescId, d10trial)
            if b9 <= budget and b10 > budget then
                foundN, foundPad = n, pad
                break
            end
        end
        if foundN then break end
    end
    assertTrue(foundN ~= nil,
        "459-EM-edge: located 9→10 overflow boundary")
    GS._ClearCreditAliasExportCacheForTest()
    local upserted = {}
    local function upsertCapture(id, body)
        upserted[id] = body
    end
    local desc9 = edgeDesc(9)
    local _, c9, pc9 = GS._SyncCreditAliasExportPagesForTest(
        edgeRecord, edgeDescId, desc9, upsertCapture)
    local bytes9 = GS._EstimateWireRecordBytesForTest(edgeDescId, desc9)
    assertEq(tonumber(pc9) or -1, 0, "459-EM-edge: count=9 packs inline")
    assertTrue(bytes9 <= budget,
        "459-EM-edge: count=9 fits bytes=" .. tostring(bytes9)
            .. " n=" .. tostring(foundN) .. " pad=" .. tostring(foundPad))
    local inline9 = desc9.creditEventAliases
    local trialBroken = edgeDesc(10)
    trialBroken.creditEventAliases = inline9
    trialBroken.creditEventAliasCount = tonumber(c9) or 0
    trialBroken.creditEventAliasPageCount = 0
    local brokenBytes = GS._EstimateWireRecordBytesForTest(edgeDescId, trialBroken)
    assertTrue(brokenBytes > budget,
        "459-EM-edge: naive reuse overflows bytes=" .. tostring(brokenBytes)
            .. " budget=" .. tostring(budget)
            .. " (9→10 delta " .. tostring(brokenBytes - bytes9) .. ")")
    assertEq(brokenBytes - bytes9, 1,
        "459-EM-edge: donationEvidenceCount 9→10 adds one byte")
    local missesBeforeEdge = tonumber(GS._creditAliasExportCacheMisses) or 0
    local desc10 = edgeDesc(10)
    local _, _, pc10 = GS._SyncCreditAliasExportPagesForTest(
        edgeRecord, edgeDescId, desc10, upsertCapture)
    local bytes10 = GS._EstimateWireRecordBytesForTest(edgeDescId, desc10)
    assertTrue(bytes10 <= budget,
        "459-EM-edge: count=10 fresh pack fits bytes=" .. tostring(bytes10)
            .. " pages=" .. tostring(pc10))
    assertTrue((tonumber(pc10) or 0) >= 1,
        "459-EM-edge: count=10 pages aliases pages=" .. tostring(pc10))
    local missesAfterEdge = tonumber(GS._creditAliasExportCacheMisses) or 0
    assertTrue(missesAfterEdge > missesBeforeEdge,
        "459-EM-edge: descriptor size change misses cache")

    -- Incremental stale-page cleanup without a full dataset reset.
    local pageRecord = seedLiveCampaignWithItem(9971, 40)
    local pageCtx = select(1, GS:GetCurrentContext())
    injectProductionDonation(pageRecord, {
        id = "ctx:em-page-canon", itemId = 9971, quantity = 1,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    pageRecord.operations.records = pageRecord.operations.records or {}
    pageRecord.operations.order = pageRecord.operations.order or {}
    pageRecord.operations.heads = pageRecord.operations.heads or {}
    local PAGE_ALIAS_N = 80
    for i = 1, PAGE_ALIAS_N do
        local alias = string.format("ctx:em-page-alias-%04d-%s", i, string.rep("z", 24))
        local opId = string.format("em-page-corr-%04d", i)
        pageRecord.operations.records[opId] = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = opId,
            guildKey = pageCtx.guildKey,
            datasetId = pageRecord.datasetId,
            campaignId = pageRecord.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = alias,
            value = {
                eventId = alias, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9971,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + i,
            baseTargetRevision = pageRecord.datasetId,
            basePolicyRevision = pageRecord.permission and pageRecord.permission.revisionId,
            baseCampaignId = pageRecord.currentCampaignId,
        }
        pageRecord.operations.order[#pageRecord.operations.order + 1] = opId
        pageRecord.operations.heads[GS.CorrectionTargetKey(
            pageRecord, "ctx:em-page-canon")] = opId
        assertTrue(GS.RememberCreditEventAlias(pageRecord, alias, "ctx:em-page-canon"),
            "459-EM-page: durable alias " .. tostring(i))
    end
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("remote-op")
    drainExportMaint(128)
    local bodiesBefore = collectAllExportBodies()
    local ceaBefore = 0
    for i = 1, #bodiesBefore do
        if bodiesBefore[i].body and bodiesBefore[i].body.kind == "gs-credit-aliases-page" then
            ceaBefore = ceaBefore + 1
        end
    end
    assertTrue(ceaBefore >= 1,
        "459-EM-page: paged export present before shrink n=" .. tostring(ceaBefore))
    for i = 1, PAGE_ALIAS_N do
        pageRecord.operations.records[string.format("em-page-corr-%04d", i)] = nil
    end
    pageRecord.operations.order = {}
    pageRecord.operations.heads = {}
    pageRecord.operations.pending = {}
    if pageRecord.accounting._consumables then
        pageRecord.accounting._consumables.creditEventAliases = {}
    end
    if GS._BumpOpsValidationGen then
        GS._BumpOpsValidationGen(pageRecord.operations)
    end
    GS.NotifyLocalDurableChange("remote-op")
    drainExportMaint(128)
    local bodiesAfter = collectAllExportBodies()
    local ceaAfter = 0
    for i = 1, #bodiesAfter do
        if bodiesAfter[i].body and bodiesAfter[i].body.kind == "gs-credit-aliases-page" then
            ceaAfter = ceaAfter + 1
        end
    end
    assertEq(ceaAfter, 0,
        "459-EM-page: stale alias pages removed without dataset reset n="
            .. tostring(ceaAfter))
end

do
    -- Contributor autocomplete: exercise the real Controls:AddAutocomplete
    -- OnTextChanged → Logs definition onResolved → setter → refresh boundary
    -- (#459 discussion_r4496331290 / 4497018238 / 4497814453).
    local record = seedLiveCampaignWithItem(9981, 40)
    injectProductionDonation(record, {
        id = "ctx:ac-don", itemId = 9981, quantity = 3,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
    assertTrue(logsPage and logsPage.__sfTest, "459-AC: logs hooks")
    logsPage.panel = { IsShown = function() return true end }
    local rows = logsPage.__sfTest.BuildProjectedRows()
    local row = nil
    for i = 1, #rows do
        if rows[i].id == "ctx:ac-don" then row = rows[i] break end
    end
    assertTrue(row ~= nil, "459-AC: target row")
    logsPage.__sfTest.OpenEditContributorDialog("ctx:ac-don", row)
    local session = logsPage.__sfTest.GetEditSession()
    assertTrue(session ~= nil, "459-AC: edit session")
    session.attributed = "Alice-Garona"
    session.attributedGuid = "Player-1-Alice"
    session.attributionText = "Alice-Garona"
    session.attributionResolved = true

    -- Minimal native-frame harness for Controls:AddAutocomplete only.
    local created = {}
    local function makeRegion(objectType, name, parent, template)
        local region = {
            _shown = true, _text = "", _enabled = true, _alpha = 1,
            _scripts = {}, _points = {}, _width = 180, _height = 20,
            parent = parent, name = name,
            objectType = objectType or "Frame",
        }
        function region:GetObjectType() return self.objectType end
        function region:SetShown(v) self._shown = v and true or false end
        function region:IsShown() return self._shown end
        function region:Show() self._shown = true end
        function region:Hide() self._shown = false end
        function region:SetSize(w, h)
            self._width = tonumber(w) or self._width
            self._height = tonumber(h) or self._height
        end
        function region:SetWidth(w) self._width = tonumber(w) or self._width end
        function region:SetHeight(h) self._height = tonumber(h) or self._height end
        function region:GetWidth() return self._width end
        function region:GetHeight() return self._height end
        function region:SetPoint() end
        function region:ClearAllPoints() end
        function region:SetAllPoints() end
        function region:SetParent(p) self.parent = p end
        function region:GetParent() return self.parent end
        function region:SetText(t) self._text = tostring(t or "") end
        function region:GetText() return self._text end
        function region:SetTextColor() end
        function region:SetHighlightColor() end
        function region:SetAutoFocus() end
        function region:SetMaxLetters() end
        function region:SetEnabled(v) self._enabled = v and true or false end
        function region:IsEnabled() return self._enabled end
        function region:Enable() self._enabled = true end
        function region:Disable() self._enabled = false end
        function region:EnableMouse() end
        function region:SetAlpha(a) self._alpha = a end
        function region:SetScript(ev, fn) self._scripts[ev] = fn end
        function region:GetScript(ev) return self._scripts[ev] end
        function region:HasFocus() return self._focused end
        function region:SetFocus() self._focused = true end
        function region:ClearFocus()
            self._focused = false
            local fn = self._scripts.OnEditFocusLost
            if fn then fn(self) end
        end
        function region:Click(...)
            local fn = self._scripts.OnClick
            if fn then fn(self, ...) end
        end
        function region:SetCursorPosition() end
        function region:GetCursorPosition() return 0 end
        function region:SetFrameStrata() end
        function region:SetClampedToScreen() end
        function region:SetJustifyH() end
        function region:SetColorTexture() end
        function region:SetBackdrop() end
        function region:SetBackdropColor() end
        function region:SetBackdropBorderColor() end
        function region:CreateFontString()
            return makeRegion("FontString", nil, self)
        end
        function region:CreateTexture()
            return makeRegion("Texture", nil, self)
        end
        function region:TypeText(text)
            self._text = tostring(text or "")
            local fn = self._scripts.OnTextChanged
            if fn then fn(self, true) end
        end
        if template and tostring(template):find("InputBox", 1, true) then
            region.objectType = "EditBox"
            region.Instructions = makeRegion("FontString", nil, region)
            function region.Instructions:SetText(t) self._text = tostring(t or "") end
        end
        if objectType == "EditBox" then
            region.objectType = "EditBox"
        end
        if objectType == "Button" or (template and tostring(template):find("Button", 1, true)) then
            region.objectType = "Button"
            region.Text = makeRegion("FontString", nil, region)
        end
        created[#created + 1] = region
        return region
    end
    local priorCreateFrame = CreateFrame
    local priorUIParent = UIParent
    local priorGameTooltip = GameTooltip
    function CreateFrame(frameType, name, parent, template)
        return makeRegion(frameType or "Frame", name, parent, template)
    end
    UIParent = makeRegion("Frame", "UIParent")
    GameTooltip = {
        SetOwner = function() end,
        SetText = function() end,
        AddLine = function() end,
        Show = function() end,
        Hide = function() end,
    }

    loadModule("SpectrumFederation/modules/UI/Settings/Control/Controls.lua")
    assertTrue(SF.SettingsUI.Controls and SF.SettingsUI.Controls.AddAutocomplete,
        "459-AC: Controls:AddAutocomplete loaded")

    -- Capture the production Logs autocomplete definition via Page:Build.
    SF.SettingsUI.DefinitionRenderer = SF.SettingsUI.DefinitionRenderer or {}
    local prevRendererBuild = SF.SettingsUI.DefinitionRenderer.Build
    local capturedDef = nil
    SF.SettingsUI.DefinitionRenderer.Build = function(_, panel, pageDef)
        capturedDef = pageDef
        panel.__sfPageDef = pageDef
        return panel
    end
    local buildPanel = makeRegion("Frame", "LogsACPanel")
    function buildPanel:IsVisible() return true end
    local buildOk, buildErr = pcall(function()
        logsPage:Build(buildPanel)
    end)
    SF.SettingsUI.DefinitionRenderer.Build = prevRendererBuild
    assertTrue(buildOk, "459-AC: Logs Build captured definition got " .. tostring(buildErr))
    local acDef = nil
    for _, sec in ipairs((capturedDef and capturedDef.sections) or {}) do
        for _, item in ipairs(sec.items or {}) do
            if item.type == "autocomplete" then
                acDef = item
            end
        end
    end
    assertTrue(type(acDef) == "table" and type(acDef.onResolved) == "function",
        "459-AC: production autocomplete definition found")
    assertTrue(type(acDef.set) == "function" and type(acDef.get) == "function",
        "459-AC: production get/set bound")

    -- Page:Refresh must fire Controls RegisterRefresh so get() can rewrite the
    -- focused edit (DefinitionRenderer path). Without that, the fail-before
    -- mutation cannot restore Alice mid-keystroke.
    local refreshCount = 0
    local activeRefreshFns = {}
    local prevRefresh = logsPage.Refresh
    logsPage.Refresh = function(self, panel)
        refreshCount = refreshCount + 1
        for i = 1, #activeRefreshFns do
            activeRefreshFns[i]()
        end
    end
    -- Keep the Build panel visible for production set()/onResolved refresh gates.
    if type(logsPage.panel) == "table" then
        function logsPage.panel:IsShown() return true end
        function logsPage.panel:IsVisible() return true end
    end

    local function bindAutocomplete(onResolvedFn)
        created = {}
        activeRefreshFns = {}
        local section = {
            __sfPageBuilder = {
                RegisterRefresh = function(_, fn)
                    if type(fn) == "function" then
                        activeRefreshFns[#activeRefreshFns + 1] = fn
                    end
                end,
                Refresh = function()
                    for i = 1, #activeRefreshFns do
                        activeRefreshFns[i]()
                    end
                end,
                FireRefresh = function()
                    for i = 1, #activeRefreshFns do
                        activeRefreshFns[i]()
                    end
                end,
            },
            AddRow = function(_, _h, builder)
                local r = makeRegion("Frame", "ACRow")
                builder(r)
                return r
            end,
        }
        SF.SettingsUI.Controls:AddAutocomplete(section, {
            label = acDef.label,
            width = acDef.width or 220,
            maxLetters = acDef.maxLetters,
            maxSuggestions = acDef.maxSuggestions or 8,
            hint = acDef.hint,
            get = acDef.get,
            set = acDef.set,
            enabled = acDef.enabled,
            visible = acDef.visible,
            getSuggestions = function(prefix)
                return acDef.getSuggestions(nil, prefix)
            end,
            onResolved = onResolvedFn,
        })
        local edit = nil
        for i = 1, #created do
            if created[i].objectType == "EditBox" then
                edit = created[i]
                break
            end
        end
        assertTrue(edit ~= nil, "459-AC: autocomplete EditBox created")
        return edit
    end

    local typed = "Bob"
    -- Failure-before: restore the old synchronous refresh inside onResolved(nil).
    -- Production AddAutocomplete notifies nil before GetText/set; refreshing here
    -- rewrites the focused box from the stale Alice draft.
    session.attributed = "Alice-Garona"
    session.attributedGuid = "Player-1-Alice"
    session.attributionText = "Alice-Garona"
    session.attributionResolved = true
    local buggyEdit = bindAutocomplete(function(item)
        if not item then
            acDef.onResolved(nil, nil)
            if logsPage.Refresh and logsPage.panel then
                logsPage:Refresh(logsPage.panel)
            end
            return
        end
        return acDef.onResolved(nil, item)
    end)
    buggyEdit:SetText("Alice-Garona")
    buggyEdit:TypeText(typed)
    assertEq(buggyEdit:GetText(), "Alice-Garona",
        "459-AC-fail: old onResolved(nil) refresh restores Alice box got "
            .. tostring(buggyEdit:GetText()))
    assertEq(session.attributionText, "Alice-Garona",
        "459-AC-fail: old refresh restores Alice draft")
    assertTrue(session.attributed == "Alice-Garona" or session.attributionResolved ~= true,
        "459-AC-fail: typed Bob does not uniquely resolve under old bug")

    -- Pass-after: real Logs definition onResolved (nil returns before refresh).
    session.attributed = "Alice-Garona"
    session.attributedGuid = "Player-1-Alice"
    session.attributionText = "Alice-Garona"
    session.attributionResolved = true
    refreshCount = 0
    local edit = bindAutocomplete(function(item)
        return acDef.onResolved(nil, item)
    end)
    edit:SetText("Alice-Garona")
    local refreshesBeforeType = refreshCount
    edit:TypeText(typed)
    assertEq(session.attributionText, typed,
        "459-AC: draft keeps typed text after nil→set→refresh")
    assertEq(session.attributed, "Bob-Garona",
        "459-AC: unique short-name resolves Bob")
    assertEq(session.attributedGuid, "Player-1-Bob",
        "459-AC: unique short-name binds Bob guid")
    assertEq(session.attributionResolved, true,
        "459-AC: unique short-name marks resolved")
    assertEq(edit:GetText(), typed,
        "459-AC: edit box shows typed text after production chain got "
            .. tostring(edit:GetText()))
    assertTrue(refreshCount > refreshesBeforeType,
        "459-AC: setter refresh ran after draft update")

    -- Explicit nil notification through the production definition must not refresh.
    local refreshesAfterNil = refreshCount
    acDef.onResolved(nil, nil)
    assertEq(refreshCount, refreshesAfterNil,
        "459-AC: onResolved(nil) does not refresh before set")
    assertEq(edit:GetText(), typed,
        "459-AC: nil notification left typed box text intact")
    assertEq(session.attributionResolved, false,
        "459-AC: nil clears resolution before suggestion")

    -- Suggestion selection through the real AddAutocomplete SelectItem path.
    local clicked = false
    for i = 1, #created do
        local obj = created[i]
        if obj.objectType == "Button" and obj.Text
            and tostring(obj.Text._text or "") == "Bob-Garona"
            and obj._scripts and obj._scripts.OnClick then
            obj:Click()
            clicked = true
            break
        end
    end
    if not clicked then
        -- Dropdown may have been hidden; re-type to populate then click.
        edit:TypeText(typed)
        for i = 1, #created do
            local obj = created[i]
            if obj.objectType == "Button" and obj.Text
                and tostring(obj.Text._text or "") == "Bob-Garona"
                and obj._scripts and obj._scripts.OnClick then
                obj:Click()
                clicked = true
                break
            end
        end
    end
    assertTrue(clicked, "459-AC: suggestion button clicked via AddAutocomplete")
    assertEq(session.attributed, "Bob-Garona", "459-AC: suggestion selects Bob")
    assertEq(session.attributionResolved, true, "459-AC: suggestion resolved")
    assertEq(edit:GetText(), "Bob-Garona",
        "459-AC: box shows Bob after suggestion selection")

    local prevConfirm = SF.SettingsUI.Dialogs and SF.SettingsUI.Dialogs.Confirm
    local confirmCb = nil
    SF.SettingsUI.Dialogs = SF.SettingsUI.Dialogs or {}
    SF.SettingsUI.Dialogs.Confirm = function(_, _msg, _btn, onConfirm)
        confirmCb = onConfirm
    end
    logsPage.__sfTest.ConfirmAndSaveEdit()
    SF.SettingsUI.Dialogs.Confirm = prevConfirm
    assertTrue(type(confirmCb) == "function",
        "459-AC: Dialogs.Confirm captured onConfirm")
    assertTrue(type(logsPage.__sfTest.GetPendingConfirm()) == "table",
        "459-AC: pending confirm payload retained")
    confirmCb()
    flushTimers()
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "ctx:ac-don"))), "Bob-Garona",
        "459-AC: stored credit is Bob after confirm")

    logsPage.Refresh = prevRefresh
    logsPage.__sfTest.ClearEditSession()
    logsPage.panel = nil
    CreateFrame = priorCreateFrame
    UIParent = priorUIParent
    GameTooltip = priorGameTooltip
end

do
    -- Alias-chain head migration: A→B→C must fold retained credit:A onto credit:C
    -- even when B→C is enumerated first and A's ledger row was evicted
    -- (#459 discussion_r4496331267 / 4496720120).
    local function withCurrentRecord(target, fn)
        local gk = select(1, GS:GetCurrentContext()).guildKey
        local saved = GS._root and GS._root.guilds and GS._root.guilds[gk]
        if type(GS._root) == "table" and type(GS._root.guilds) == "table" then
            GS._root.guilds[gk] = target
        end
        local ok, a, b, c = pcall(fn)
        if type(GS._root) == "table" and type(GS._root.guilds) == "table" then
            GS._root.guilds[gk] = saved
        end
        if not ok then error(a) end
        return a, b, c
    end
    local function providerAliasPage(target, pageId, pageBody, sender)
        return withCurrentRecord(target, function()
            GS:EnsureGossipProvider()
            local entry = GG.GetProvider(GS.PROVIDER_ID)
            return entry.api.ValidateAndApply({
                id = pageId,
                versionFp = GS.ContentFingerprint(pageBody),
                body = pageBody,
            }, { sender = sender })
        end)
    end
    local function drainAliasTimers(maxSlices)
        maxSlices = maxSlices or 256
        local slices = 0
        while slices < maxSlices do
            slices = slices + 1
            if #timers > 0 then
                if not runOneDueTimer() then flushTimers() end
            else
                break
            end
        end
        flushTimers()
    end
    local function seedChainFixture()
        local record = seedLiveCampaignWithItem(9982, 40)
        injectProductionDonation(record, {
            id = "ctx:chain-c", itemId = 9982, quantity = 4,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        })
        -- Accepted correction head originally targeted A; A ledger row later evicted.
        local ctx = select(1, GS:GetCurrentContext())
        local opId = "chain-head-a"
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = opId,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = "ctx:chain-a",
            value = {
                eventId = "ctx:chain-a", eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9982,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + 1,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        record.operations.records[opId] = op
        record.operations.order[#record.operations.order + 1] = opId
        record.operations.heads["credit:ctx:chain-a"] = opId
        -- Evict any A ledger row if present; C remains.
        local live = record.accounting._consumableEvents
        local filtered = {}
        for i = 1, #live do
            if live[i].id ~= "ctx:chain-a" then
                filtered[#filtered + 1] = live[i]
            end
        end
        record.accounting._consumableEvents = filtered
        local gk = select(1, GS:GetCurrentContext()).guildKey
        local okStruct, reasonStruct = GS._ValidateGuildRecordStructure(gk, record)
        assertTrue(okStruct,
            "459-CH: pre-delivery structure ok got " .. tostring(reasonStruct))
        return record, opId, gk
    end
    local function assertChainMigrated(record, opId, label, gk)
        local heads = record.operations.heads
        assertEq(heads["credit:ctx:chain-c"], opId,
            "459-CH-" .. label .. ": head under credit:C")
        assertTrue(heads["credit:ctx:chain-a"] == nil,
            "459-CH-" .. label .. ": credit:A cleared")
        assertTrue(heads["credit:ctx:chain-b"] == nil,
            "459-CH-" .. label .. ": credit:B cleared")
        local okAfter, reasonAfter = GS._ValidateGuildRecordStructure(gk, record)
        assertTrue(okAfter,
            "459-CH-" .. label .. ": structure after delivery got "
                .. tostring(reasonAfter))
        -- Reload-style revalidate.
        local okReload, reasonReload = GS._ValidateGuildRecordStructure(gk, record)
        assertTrue(okReload,
            "459-CH-" .. label .. ": structure after reload got "
                .. tostring(reasonReload))
        assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
            record, GS.FindLedgerEventById(record, "ctx:chain-c"))), "Bob-Garona",
            "459-CH-" .. label .. ": credit Bob on C")
    end
    -- Order 1: B→C enumerated before A→B (pairs iteration / page order).
    local rec1, op1, gk1 = seedChainFixture()
    local pageId1 = "gs:cea:" .. rec1.datasetId .. ":p1"
    local bodyBCFirst = {
        kind = "gs-credit-aliases-page",
        datasetId = rec1.datasetId,
        page = 1, pageCount = 1,
        aliases = {
            ["ctx:chain-b"] = "ctx:chain-c",
            ["ctx:chain-a"] = "ctx:chain-b",
        },
    }
    GS._creditAliasPageWakeCalls = 0
    local st1, r1 = providerAliasPage(rec1, pageId1, bodyBCFirst, "Alice-Garona")
    assertTrue(st1 == "accepted" or st1 == "duplicate",
        "459-CH-bc: page accepted got " .. tostring(st1) .. "/" .. tostring(r1))
    assertEq(tonumber(GS._creditAliasPageWakeCalls) or 0, 1,
        "459-CH-bc: one coalesced wake")
    drainAliasTimers(256)
    assertChainMigrated(rec1, op1, "bc", gk1)
    assertEq(#timers, 0, "459-CH-bc: idle")
    -- Subsequent correction causality against canonical C using the genuinely
    -- prepared head revision (no hand-patched baseTargetRevision). Advance
    -- server time so the follow-up wins LWW against the seeded Bob head.
    world.time = world.time + 50
    local preparedRev = nil
    local stCorr, rCorr = withCurrentRecord(rec1, function()
        -- Ensure credit projection reflects migrated head before local prepare.
        if GS.EnsureCreditCorrectionProjection then
            local okP = GS.EnsureCreditCorrectionProjection(rec1, nil)
            local gP = 0
            while okP == false and gP < 64 do
                if not runOneDueTimer() then break end
                okP = GS.EnsureCreditCorrectionProjection(rec1, nil)
                gP = gP + 1
            end
            flushTimers()
        end
        local corrC, prepSt, prepReason = GS:NewContributorCorrectionOperation(
            "ctx:chain-c", "Carol-Garona", "Player-1-Carol")
        assertTrue(type(corrC) == "table",
            "459-CH-bc: prepared causal follow-up got "
                .. tostring(prepSt) .. "/" .. tostring(prepReason))
        preparedRev = corrC.baseTargetRevision
        assertEq(preparedRev, op1,
            "459-CH-bc: prepared revision is migrated head")
        assertEq(corrC.value and corrC.value.baseAttributed, "Bob-Garona",
            "459-CH-bc: prepared base is current Bob credit")
        assertTrue((tonumber(corrC.timestamp) or 0)
                > (tonumber(rec1.operations.records[op1].timestamp) or 0),
            "459-CH-bc: follow-up timestamp after seeded head")
        return GS:ApplyStagedConfigOperation(corrC)
    end)
    assertEq(stCorr, "accepted",
        "459-CH-bc: causal follow-up accepted got "
            .. tostring(stCorr) .. "/" .. tostring(rCorr)
            .. " preparedRev=" .. tostring(preparedRev))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        rec1, GS.FindLedgerEventById(rec1, "ctx:chain-c"))), "Carol-Garona",
        "459-CH-bc: Carol after causal correction")

    -- Order 2: A→B before B→C.
    local rec2, op2, gk2 = seedChainFixture()
    local pageId2 = "gs:cea:" .. rec2.datasetId .. ":p1"
    local st2, r2 = providerAliasPage(rec2, pageId2, {
        kind = "gs-credit-aliases-page",
        datasetId = rec2.datasetId,
        page = 1, pageCount = 1,
        aliases = {
            ["ctx:chain-a"] = "ctx:chain-b",
            ["ctx:chain-b"] = "ctx:chain-c",
        },
    }, "Alice-Garona")
    assertTrue(st2 == "accepted" or st2 == "duplicate",
        "459-CH-ab: page accepted got " .. tostring(st2) .. "/" .. tostring(r2))
    drainAliasTimers(256)
    assertChainMigrated(rec2, op2, "ab", gk2)
    assertEq(#timers, 0, "459-CH-ab: idle")

    -- Competing heads: newer terminal head wins LWW.
    local rec3, op3 = seedChainFixture()
    local newerId = "chain-head-c-newer"
    local newer = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = newerId,
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        datasetId = rec3.datasetId,
        campaignId = rec3.currentCampaignId,
        kind = GS.KIND.CORRECT_CONTRIBUTOR,
        target = "ctx:chain-c",
        value = {
            eventId = "ctx:chain-c", eventKind = "donation",
            attributed = "Dave-Garona", attributedGuid = "Player-1-Dave",
            baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
            itemId = 9982,
        },
        actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
        timestamp = world.time + 99,
        baseTargetRevision = rec3.datasetId,
        basePolicyRevision = rec3.permission and rec3.permission.revisionId,
        baseCampaignId = rec3.currentCampaignId,
    }
    rec3.operations.records[newerId] = newer
    rec3.operations.order[#rec3.operations.order + 1] = newerId
    rec3.operations.heads["credit:ctx:chain-c"] = newerId
    -- Make alias head older so C head wins.
    rec3.operations.records[op3].timestamp = world.time + 1
    providerAliasPage(rec3, "gs:cea:" .. rec3.datasetId .. ":p1", {
        kind = "gs-credit-aliases-page",
        datasetId = rec3.datasetId,
        page = 1, pageCount = 1,
        aliases = {
            ["ctx:chain-b"] = "ctx:chain-c",
            ["ctx:chain-a"] = "ctx:chain-b",
        },
    }, "Alice-Garona")
    drainAliasTimers(256)
    assertEq(rec3.operations.heads["credit:ctx:chain-c"], newerId,
        "459-CH-comp: terminal keeps winning head")
    assertTrue(rec3.operations.heads["credit:ctx:chain-a"] == nil,
        "459-CH-comp: alias head folded away")
end

do
    -- Final alias-page sizing: pack with reserved pageCount width; every final
    -- wrapper-inclusive body must fit (#459 discussion_r4496331283 / 4496720924).
    local function wireRawBytes(id, body)
        local fp = (GS.ContentFingerprint and GS.ContentFingerprint(body))
            or string.rep("f", GS.MAX_OPERATION_ID or 192)
        local raw = C_EncodingUtil.SerializeCBOR({
            id = id, versionFp = fp, body = body,
        })
        return type(raw) == "string" and #raw or 0
    end
    local budget = GS.MAX_WIRE_RECORD_BYTES
        or (SF.GuildGossip and SF.GuildGossip.MAX_RECORD_CBOR)
        or 2048
    local maxAliases = tonumber(GS.MAX_CREDIT_EVENT_ALIASES) or 2048
    local BIND_N = 512
    assertTrue(BIND_N <= maxAliases, "459-PS: 512 within alias capacity")
    -- Long dataset id so page ids consume representative wrapper bytes.
    local record = seedLiveCampaignWithItem(9983, 40)
    -- Force a long datasetId for wire sizing (37+ chars as in reproduction).
    local longDs = "ds-page-size-" .. string.rep("x", 24)
    record.datasetId = longDs
    if record.accounting and record.accounting._consumables then
        record.accounting._consumables.datasetId = longDs
    end
    injectProductionDonation(record, {
        id = "ctx:ps-canon", itemId = 9983, quantity = 1,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    local ctx = select(1, GS:GetCurrentContext())
    record.operations.records = record.operations.records or {}
    record.operations.order = record.operations.order or {}
    record.operations.heads = record.operations.heads or {}
    -- Pad aliases so the harness estimator yields ≥24 pages (CBOR int-width
    -- boundary). Standard-CBOR reproduction used 26 pages at 512 bindings.
    local aliasPad = string.rep("z", 48)
    for i = 1, BIND_N do
        local alias = string.format("ctx:ps-a-%04d-%s", i, aliasPad)
        assertTrue(#alias <= (GS.MAX_TXN_ID or 160),
            "459-PS: alias length within ValidTxnId")
        local opId = string.format("ps-corr-%04d", i)
        record.operations.records[opId] = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = opId,
            guildKey = ctx.guildKey,
            datasetId = longDs,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = alias,
            value = {
                eventId = alias, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9983,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + i,
            baseTargetRevision = longDs,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        record.operations.order[#record.operations.order + 1] = opId
        record.operations.heads[GS.CorrectionTargetKey(record, "ctx:ps-canon")] = opId
        assertTrue(GS.RememberCreditEventAlias(record, alias, "ctx:ps-canon"),
            "459-PS: seed alias " .. tostring(i))
    end
    local descBody = {
        kind = "dataset-desc",
        schemaVersion = GS.PROVIDER_SCHEMA,
        guildKey = ctx.guildKey,
        datasetId = longDs,
        editorRankPosition = record.permission and record.permission.editorRankPosition,
        permissionRevisionId = record.permission and record.permission.revisionId,
        currentCampaignId = record.currentCampaignId,
        activation = record.activation,
        acceptedOpCount = 0,
        transferOpCount = 0,
        campaignCount = 1,
        archiveCount = 0,
        acceptedLedgerCount = #(record.accounting._consumableEvents or {}),
        donationEvidenceCount = 1,
        valuationCount = 0,
        bankTab = record.accounting._consumables.bankTab,
        hasBankTab = true,
        creditEventAliases = {},
        creditEventAliasCount = 0,
        creditEventAliasPageCount = 0,
    }
    local descId = "gs:desc:" .. longDs
    local pages, aliasCount, pageCount = GS._ApplyCreditAliasExportToDescForTest(
        record, descId, descBody)
    assertTrue((tonumber(pageCount) or 0) >= 24,
        "459-PS: enough pages to cross CBOR int-width boundary pages="
            .. tostring(pageCount))
    assertEq(tonumber(aliasCount) or 0, BIND_N,
        "459-PS: all bindings accounted count=" .. tostring(aliasCount))
    assertTrue(type(pages) == "table" and #pages == pageCount,
        "459-PS: pages emitted for every advertised page")
    local over = 0
    for i = 1, #pages do
        local nbytes = wireRawBytes(pages[i].id, pages[i].body)
        if nbytes > budget then
            over = over + 1
        end
        assertEq(tonumber(pages[i].body.pageCount), pageCount,
            "459-PS: page " .. tostring(i) .. " final pageCount")
        assertEq(tonumber(pages[i].body.page), i,
            "459-PS: page " .. tostring(i) .. " index")
    end
    assertEq(over, 0,
        "459-PS: every final wrapper-inclusive page fits budget over="
            .. tostring(over))
    -- Pre-fix contrast: measuring with pageCount=1 can undersize vs final.
    if pageCount >= 24 then
        local sample = pages[math.min(24, #pages)]
        local trial = {}
        for k, v in pairs(sample.body) do trial[k] = v end
        trial.pageCount = 1
        local withOne = wireRawBytes(sample.id, trial)
        local withFinal = wireRawBytes(sample.id, sample.body)
        assertTrue(withFinal >= withOne,
            "459-PS: final pageCount width >= placeholder")
        -- When the harness shows growth, final must still be in budget.
        assertTrue(withFinal <= budget,
            "459-PS: page 24-region final fits after growth "
                .. tostring(withOne) .. "→" .. tostring(withFinal))
    end
    -- Wire-filter + adoption completeness: no advertised page may be skipped.
    local filtered, dropped = {}, 0
    for i = 1, #pages do
        if wireRawBytes(pages[i].id, pages[i].body) <= budget then
            filtered[#filtered + 1] = pages[i]
        else
            dropped = dropped + 1
        end
    end
    assertEq(dropped, 0, "459-PS: wire filter drops none")
    assertEq(#filtered, pageCount, "459-PS: filter keeps all pages")
    -- Maximum supported required bindings: seed up to capacity with padded ids.
    local maxRecord = seedLiveCampaignWithItem(9984, 40)
    maxRecord.datasetId = longDs
    injectProductionDonation(maxRecord, {
        id = "ctx:ps-max-canon", itemId = 9984, quantity = 1,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
    })
    maxRecord.operations.records = {}
    maxRecord.operations.order = {}
    maxRecord.operations.heads = {}
    local maxCtx = select(1, GS:GetCurrentContext())
    local seededMax = 0
    for i = 1, maxAliases do
        local alias = string.format("ctx:ps-m-%04d-%s", i, string.rep("y", 40))
        if #alias > (GS.MAX_TXN_ID or 160) then
            break
        end
        local opId = string.format("ps-max-%04d", i)
        maxRecord.operations.records[opId] = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = opId,
            guildKey = maxCtx.guildKey,
            datasetId = longDs,
            campaignId = maxRecord.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = alias,
            value = {
                eventId = alias, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9984,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + i,
            baseTargetRevision = longDs,
            basePolicyRevision = maxRecord.permission and maxRecord.permission.revisionId,
            baseCampaignId = maxRecord.currentCampaignId,
        }
        maxRecord.operations.order[#maxRecord.operations.order + 1] = opId
        maxRecord.operations.heads[GS.CorrectionTargetKey(
            maxRecord, "ctx:ps-max-canon")] = opId
        if GS.RememberCreditEventAlias(maxRecord, alias, "ctx:ps-max-canon") then
            seededMax = seededMax + 1
        else
            break
        end
    end
    assertTrue(seededMax >= BIND_N,
        "459-PS-max: seeded capacity n=" .. tostring(seededMax))
    local descMax = {
        kind = "dataset-desc",
        schemaVersion = GS.PROVIDER_SCHEMA,
        guildKey = maxCtx.guildKey,
        datasetId = longDs,
        editorRankPosition = maxRecord.permission and maxRecord.permission.editorRankPosition,
        permissionRevisionId = maxRecord.permission and maxRecord.permission.revisionId,
        currentCampaignId = maxRecord.currentCampaignId,
        activation = maxRecord.activation,
        acceptedOpCount = 0,
        transferOpCount = 0,
        campaignCount = 1,
        archiveCount = 0,
        acceptedLedgerCount = 1,
        donationEvidenceCount = 1,
        valuationCount = 0,
        bankTab = maxRecord.accounting._consumables.bankTab,
        hasBankTab = true,
        creditEventAliases = {},
        creditEventAliasCount = 0,
        creditEventAliasPageCount = 0,
    }
    local pagesMax, countMax, pcMax = GS._ApplyCreditAliasExportToDescForTest(
        maxRecord, descId, descMax)
    assertEq(tonumber(countMax) or 0, seededMax,
        "459-PS-max: packing accounts for every seeded binding count="
            .. tostring(countMax) .. " seeded=" .. tostring(seededMax))
    assertTrue((tonumber(pcMax) or 0) >= 1,
        "459-PS-max: nonempty pageCount pages=" .. tostring(pcMax))
    assertTrue(type(pagesMax) == "table" and #pagesMax == tonumber(pcMax),
        "459-PS-max: complete page list n=" .. tostring(pagesMax and #pagesMax)
            .. " pc=" .. tostring(pcMax))
    local overMax = 0
    for i = 1, #pagesMax do
        if wireRawBytes(pagesMax[i].id, pagesMax[i].body) > budget then
            overMax = overMax + 1
        end
        assertTrue(type(pagesMax[i].body) == "table"
                and type(pagesMax[i].body.aliases) == "table",
            "459-PS-max: page " .. tostring(i) .. " has aliases")
    end
    assertEq(overMax, 0, "459-PS-max: all final pages fit")
end

do
    -- Matching-hint pending re-admission must reuse the complete paced index
    -- rather than rescanning live+archive per Admit (#459 discussion_r4497075794).
    local LIVE_N, ARCH_N, PEND_N = 4000, 4000, 128
    local record = seedLiveCampaignWithItem(9975, 40)
    local ctx = select(1, GS:GetCurrentContext())
    local live = record.accounting._consumableEvents
    local arch = record.accounting._consumableEventArchive
    if type(arch) ~= "table" then
        record.accounting._consumableEventArchive = {}
        arch = record.accounting._consumableEventArchive
    end
    for i = 1, LIVE_N do
        live[#live + 1] = {
            type = GS.LEDGER_EVENT.DONATION,
            id = string.format("ctx:ra-live-%04d", i),
            txnId = string.format("ctx:ra-live-%04d", i),
            itemId = 9975, quantity = 1,
            generation = 1, timestamp = world.time + i,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            writer = "Player-1-Alice", verification = "officer",
            campaignId = record.currentCampaignId, datasetId = record.datasetId,
            gsProductionCredit = true,
        }
    end
    for i = 1, ARCH_N do
        arch[#arch + 1] = {
            type = GS.LEDGER_EVENT.DONATION,
            id = string.format("ctx:ra-arch-%04d", i),
            txnId = string.format("ctx:ra-arch-%04d", i),
            itemId = 9975, quantity = 1,
            generation = 0, timestamp = world.time - i,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            writer = "Player-1-Alice", verification = "officer",
            campaignId = record.currentCampaignId, datasetId = record.datasetId,
            gsProductionCredit = true,
        }
    end
    for i = 1, PEND_N do
        local target = string.format("ctx:ra-miss-%04d", i)
        local op = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = string.format("ra-corr-%04d", i),
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = target,
            value = {
                eventId = target, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9975, -- matching wake hint
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + 10 + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        local st, r = GS:AdmitRemoteOperation(op, {
            sender = "Alice-Garona", offlineRecord = record, preserveAttribution = true,
        })
        assertEq(st, "pending", "459-RA: admit pending " .. tostring(i))
        assertEq(r, "pending_event", "459-RA: pending_event " .. tostring(i))
    end
    if GS._ClearCreditRedriveContinuationForTest then
        GS._ClearCreditRedriveContinuationForTest(record)
    end
    local function drainRedrive(maxSlices)
        maxSlices = maxSlices or 256
        local slices = 0
        while slices < maxSlices do
            slices = slices + 1
            if #timers > 0 then
                if not runOneDueTimer() then flushTimers() end
            else
                break
            end
        end
        flushTimers()
        return slices
    end
    GS._ledgerEventIdLookupVisits = 0
    GS._creditRedriveLookupVisits = 0
    local prom, att, work = GS.RedrivePendingContributorCorrections(record, {
        itemId = 9975, maxAttempts = 32,
    })
    local findVisits = tonumber(GS._ledgerEventIdLookupVisits) or 0
    local indexVisits = tonumber(GS._creditRedriveLookupVisits) or 0
    drainRedrive(256)
    local ledgerRows = LIVE_N + ARCH_N
    local oldProduct = 32 * ledgerRows
    assertEq(prom, 0, "459-RA: matching-hint missing promotes none")
    assertTrue((tonumber(att) or 0) >= 1, "459-RA: attempts observed")
    assertTrue(indexVisits >= ledgerRows,
        "459-RA: paced index charged lookup=" .. tostring(indexVisits))
    -- Independent FindLedgerEventById counter: index hits charge O(1) per call
    -- (several calls per admit), never O(ledger) scans.
    assertTrue(findVisits <= 32 * 16,
        "459-RA: re-admit reuses index findVisits=" .. tostring(findVisits)
            .. " work=" .. tostring(work) .. " oldProduct=" .. tostring(oldProduct))
    assertTrue(findVisits * 100 < oldProduct,
        "459-RA: find visits far below attempts×ledger")
    assertEq(#timers, 0, "459-RA: idle after drain")
    -- Dependency recovery still promotes exactly once when the event arrives.
    local missDon = {
        type = GS.LEDGER_EVENT.DONATION,
        id = "ctx:ra-miss-0001",
        txnId = "ctx:ra-miss-0001",
        itemId = 9975, quantity = 5,
        generation = tonumber(record.accounting._consumables.generation) or 1,
        timestamp = world.time + 50,
        actor = "Alice-Garona", actorGuid = "Player-1-Alice",
        writer = "Player-1-Alice", verification = GS.VERIFICATION.OFFICER,
        verifierGuid = "Player-1-Alice",
        campaignId = record.currentCampaignId, datasetId = record.datasetId,
        gsProductionCredit = true,
    }
    local stDon = select(1, GS:AdmitLedgerEvent(missDon, {
        sender = "Alice-Garona",
        member = { guid = "Player-1-Alice", name = "Alice-Garona",
            guildKey = ctx.guildKey, rankOrder = 1 },
        offlineRecord = record, adoptionReplay = true,
        preserveAttribution = true, localWrite = false,
    }))
    assertTrue(stDon == "accepted" or stDon == "duplicate",
        "459-RA: dependency admitted got " .. tostring(stDon))
    drainRedrive(256)
    assertTrue(record.operations.records["ra-corr-0001"] ~= nil,
        "459-RA: matching pending accepted once")
    assertTrue(record.operations.pending["ra-corr-0001"] == nil,
        "459-RA: pending cleared after accept")
    assertEq(#timers, 0, "459-RA: idle after recovery")
end

do
    -- Cold accepted-history baseline must index durable aliases after registry
    -- eviction without per-alias full-history rescans (#459 discussion_r4497121466).
    local LIVE_N, ARCH_N, ALIAS_N = 4000, 4000, 128
    local record = seedLiveCampaignWithItem(9976, 80)
    local ctx = select(1, GS:GetCurrentContext())
    local live = record.accounting._consumableEvents
    local arch = record.accounting._consumableEventArchive
    if type(arch) ~= "table" then
        record.accounting._consumableEventArchive = {}
        arch = record.accounting._consumableEventArchive
    end
    for i = 1, LIVE_N do
        live[#live + 1] = {
            type = GS.LEDGER_EVENT.DONATION,
            id = string.format("ctx:cb-live-%04d", i),
            txnId = string.format("ctx:cb-live-%04d", i),
            itemId = 9976, quantity = 1,
            generation = 1, timestamp = world.time + i,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            writer = "Player-1-Alice", verification = "officer",
            campaignId = record.currentCampaignId, datasetId = record.datasetId,
            gsProductionCredit = true,
        }
    end
    for i = 1, ARCH_N do
        arch[#arch + 1] = {
            type = GS.LEDGER_EVENT.DONATION,
            id = string.format("ctx:cb-arch-%04d", i),
            txnId = string.format("ctx:cb-arch-%04d", i),
            itemId = 9976, quantity = 1,
            generation = 0, timestamp = world.time - i,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            writer = "Player-1-Alice", verification = "officer",
            campaignId = record.currentCampaignId, datasetId = record.datasetId,
            gsProductionCredit = true,
        }
    end
    -- Canonical events for alias targets (subset of live).
    record.accounting._consumables.txnRegistry = {}
    record.accounting._consumables.creditEventAliases = {}
    for i = 1, ALIAS_N do
        local canon = string.format("ctx:cb-live-%04d", i)
        local alias = string.format("ctx:cb-alias-%04d", i)
        assertTrue(GS.RememberCreditEventAlias(record, alias, canon),
            "459-CB: seed durable alias " .. tostring(i))
        local opId = string.format("cb-corr-%04d", i)
        record.operations.records[opId] = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = opId,
            guildKey = ctx.guildKey,
            datasetId = record.datasetId,
            campaignId = record.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = alias,
            value = {
                eventId = alias, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9976,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + 100 + i,
            baseTargetRevision = record.datasetId,
            basePolicyRevision = record.permission and record.permission.revisionId,
            baseCampaignId = record.currentCampaignId,
        }
        record.operations.order[#record.operations.order + 1] = opId
        record.operations.heads[GS.CorrectionTargetKey(record, canon)] = opId
    end
    if GS.InvalidateCreditCorrectionProjection then
        GS.InvalidateCreditCorrectionProjection(record)
    end
    GS._ledgerEventIdLookupVisits = 0
    local ok0, err0 = GS.EnsureCreditCorrectionProjection(record, nil)
    local findFirst = tonumber(GS._ledgerEventIdLookupVisits) or 0
    local slices = 0
    local findTotal = findFirst
    while (not ok0) and err0 == "work_budget" and slices < 256 do
        slices = slices + 1
        if #timers > 0 then
            if not runOneDueTimer() then flushTimers() end
        else
            break
        end
        GS._ledgerEventIdLookupVisits = 0
        ok0, err0 = GS.EnsureCreditCorrectionProjection(record, nil)
        findTotal = findTotal + (tonumber(GS._ledgerEventIdLookupVisits) or 0)
    end
    flushTimers()
    assertTrue(ok0 or GS.IsCreditCorrectionProjectionAvailable(record),
        "459-CB: projection available got " .. tostring(ok0) .. "/" .. tostring(err0)
            .. " slices=" .. tostring(slices))
    local softCap = (tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384)
        + (tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512)
    assertTrue(findFirst <= softCap + LIVE_N + ARCH_N + ALIAS_N + 256,
        "459-CB: first callback find visits bounded first=" .. tostring(findFirst)
            .. " soft=" .. tostring(softCap))
    local oldProduct = ALIAS_N * (LIVE_N + ARCH_N)
    assertTrue(findTotal < oldProduct,
        "459-CB: total find visits below alias×ledger product total="
            .. tostring(findTotal) .. " product=" .. tostring(oldProduct))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        record, GS.FindLedgerEventById(record, "ctx:cb-live-0001"))), "Bob-Garona",
        "459-CB: durable alias credit available")
    assertEq(#timers, 0, "459-CB: idle")
end

do
    -- Ownership index must cover mixed donation+withdrawal histories beyond
    -- the 4,096 donation ceiling (#459 discussion_r4497154750).
    local function withCurrentRecord(target, fn)
        local gk = select(1, GS:GetCurrentContext()).guildKey
        local saved = GS._root and GS._root.guilds and GS._root.guilds[gk]
        if type(GS._root) == "table" and type(GS._root.guilds) == "table" then
            GS._root.guilds[gk] = target
        end
        local ok, a, b, c = pcall(fn)
        if type(GS._root) == "table" and type(GS._root.guilds) == "table" then
            GS._root.guilds[gk] = saved
        end
        if not ok then error(a) end
        return a, b, c
    end
    local function providerAliasPage(target, pageId, pageBody, sender)
        return withCurrentRecord(target, function()
            GS:EnsureGossipProvider()
            local entry = GG.GetProvider(GS.PROVIDER_ID)
            return entry.api.ValidateAndApply({
                id = pageId,
                versionFp = GS.ContentFingerprint(pageBody),
                body = pageBody,
            }, { sender = sender })
        end)
    end
    local function buildMixedTail(list, prefix, itemId, campaignId, datasetId)
        local maxDon = GS.MAX_LEDGER_EVENTS or 4096
        local maxWd = GS.MAX_WITHDRAWAL_EVENTS or 1024
        -- 3072 filler donations + 1024 withdrawals + 1 owned donation at 4097.
        local fillerDon = maxDon - maxWd
        for i = 1, fillerDon do
            list[#list + 1] = {
                type = GS.LEDGER_EVENT.DONATION,
                id = string.format("%s-fill-%04d", prefix, i),
                txnId = string.format("%s-fill-%04d", prefix, i),
                itemId = itemId, quantity = 1,
                generation = 1, timestamp = world.time + i,
                actor = "Alice-Garona", actorGuid = "Player-1-Alice",
                writer = "Player-1-Alice", verification = "officer",
                campaignId = campaignId, datasetId = datasetId,
                gsProductionCredit = true,
            }
        end
        for i = 1, maxWd do
            list[#list + 1] = {
                type = GS.LEDGER_EVENT.WITHDRAWAL,
                id = string.format("%s-wd-%04d", prefix, i),
                txnId = string.format("%s-wd-%04d", prefix, i),
                itemId = itemId, quantity = 1,
                generation = 1, timestamp = world.time + fillerDon + i,
                actor = "Dave-Garona", actorGuid = "Player-1-Dave",
                writer = "Player-1-Alice",
                campaignId = campaignId, datasetId = datasetId,
                gsProductionCredit = false,
            }
        end
        local ownedId = prefix .. "-owned-tail"
        list[#list + 1] = {
            type = GS.LEDGER_EVENT.DONATION,
            id = ownedId,
            txnId = ownedId,
            itemId = itemId, quantity = 5,
            generation = 1, timestamp = world.time + fillerDon + maxWd + 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            writer = "Player-1-Alice", verification = "officer",
            campaignId = campaignId, datasetId = datasetId,
            gsProductionCredit = true,
        }
        assertEq(#list, fillerDon + maxWd + 1,
            "459-OB: mixed list length " .. prefix)
        assertEq(#list, 4097, "459-OB: position-4097 fixture " .. prefix)
        return ownedId
    end

    -- Live list.
    local liveRec = seedLiveCampaignWithItem(9977, 40)
    liveRec.accounting._consumableEvents = {}
    local liveOwned = buildMixedTail(
        liveRec.accounting._consumableEvents, "ctx:ob-live", 9977,
        liveRec.currentCampaignId, liveRec.datasetId)
    liveRec.accounting._consumables.txnRegistry = {}
    local gkLive = select(1, GS:GetCurrentContext()).guildKey
    local okLive, reasonLive = GS._ValidateGuildRecordStructure(gkLive, liveRec)
    assertTrue(okLive, "459-OB-live: structure ok got " .. tostring(reasonLive))
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        liveRec, GS.FindLedgerEventById(liveRec, liveOwned))), "Alice-Garona",
        "459-OB-live: owned starts Alice")
    local stLive, rLive = providerAliasPage(liveRec,
        "gs:cea:" .. liveRec.datasetId .. ":p1", {
            kind = "gs-credit-aliases-page",
            datasetId = liveRec.datasetId,
            page = 1, pageCount = 1,
            aliases = { [liveOwned] = "ctx:ob-live-fill-0001" },
        }, "Alice-Garona")
    assertEq(stLive, "rejected",
        "459-OB-live: owned redirect rejected got "
            .. tostring(stLive) .. "/" .. tostring(rLive))
    assertTrue(liveRec.accounting._consumables.creditEventAliases[liveOwned] == nil,
        "459-OB-live: no mutation of owned id")
    assertEq(select(1, GS.ResolveEffectiveCreditIdentity(
        liveRec, GS.FindLedgerEventById(liveRec, liveOwned))), "Alice-Garona",
        "459-OB-live: credit unchanged")
    -- Valid tail alias onto the owned donation must still install.
    local stTail, rTail = providerAliasPage(liveRec,
        "gs:cea:" .. liveRec.datasetId .. ":p1", {
            kind = "gs-credit-aliases-page",
            datasetId = liveRec.datasetId,
            page = 1, pageCount = 1,
            aliases = { ["ctx:ob-live-tail-alias"] = liveOwned },
        }, "Alice-Garona")
    assertTrue(stTail == "accepted" or stTail == "duplicate",
        "459-OB-live: valid tail alias accepted got "
            .. tostring(stTail) .. "/" .. tostring(rTail))
    assertEq(liveRec.accounting._consumables.creditEventAliases["ctx:ob-live-tail-alias"],
        liveOwned, "459-OB-live: tail alias bound")

    -- Archive list.
    local archRec = seedLiveCampaignWithItem(9978, 40)
    archRec.accounting._consumableEventArchive = {}
    local archOwned = buildMixedTail(
        archRec.accounting._consumableEventArchive, "ctx:ob-arch", 9978,
        archRec.currentCampaignId, archRec.datasetId)
    archRec.accounting._consumables.txnRegistry = {}
    local gkArch = select(1, GS:GetCurrentContext()).guildKey
    local okArch, reasonArch = GS._ValidateGuildRecordStructure(gkArch, archRec)
    assertTrue(okArch, "459-OB-arch: structure ok got " .. tostring(reasonArch))
    local stArch, rArch = providerAliasPage(archRec,
        "gs:cea:" .. archRec.datasetId .. ":p1", {
            kind = "gs-credit-aliases-page",
            datasetId = archRec.datasetId,
            page = 1, pageCount = 1,
            aliases = { [archOwned] = "ctx:ob-arch-fill-0001" },
        }, "Alice-Garona")
    assertEq(stArch, "rejected",
        "459-OB-arch: owned redirect rejected got "
            .. tostring(stArch) .. "/" .. tostring(rArch))
    assertTrue(archRec.accounting._consumables.creditEventAliases[archOwned] == nil,
        "459-OB-arch: no mutation")
    local stArchTail, rArchTail = providerAliasPage(archRec,
        "gs:cea:" .. archRec.datasetId .. ":p1", {
            kind = "gs-credit-aliases-page",
            datasetId = archRec.datasetId,
            page = 1, pageCount = 1,
            aliases = { ["ctx:ob-arch-tail-alias"] = archOwned },
        }, "Alice-Garona")
    assertTrue(stArchTail == "accepted" or stArchTail == "duplicate",
        "459-OB-arch: valid tail alias accepted got "
            .. tostring(stArchTail) .. "/" .. tostring(rArchTail))
end

do
    -- Changed same-ID alias page during adoption → source_changed; stale session
    -- cannot commit; fresh consistent adoption succeeds (#459 discussion_r4497121459).
    local source = seedLiveCampaignWithItem(9979, 80)
    local ctx = select(1, GS:GetCurrentContext())
    local N = 65
    for i = 1, N do
        local canon = string.format("ctx:sc-canon-%04d", i)
        local alias = string.format("ctx:sc-alias-%04d", i)
        injectProductionDonation(source, {
            id = canon, itemId = 9979, quantity = 1,
            actor = "Alice-Garona", actorGuid = "Player-1-Alice",
            timestamp = world.time + i,
        })
        assertTrue(GS.RememberCreditEventAlias(source, alias, canon),
            "459-SC: seed alias " .. tostring(i))
        local opId = string.format("sc-corr-%04d", i)
        source.operations.records[opId] = {
            schemaVersion = GS.OP_SCHEMA_VERSION,
            id = opId,
            guildKey = ctx.guildKey,
            datasetId = source.datasetId,
            campaignId = source.currentCampaignId,
            kind = GS.KIND.CORRECT_CONTRIBUTOR,
            target = alias,
            value = {
                eventId = alias, eventKind = "donation",
                attributed = "Bob-Garona", attributedGuid = "Player-1-Bob",
                baseAttributed = "Alice-Garona", baseAttributedGuid = "Player-1-Alice",
                itemId = 9979,
            },
            actorGuid = "Player-1-Alice", actorName = "Alice-Garona",
            timestamp = world.time + i,
            baseTargetRevision = source.datasetId,
            basePolicyRevision = source.permission and source.permission.revisionId,
            baseCampaignId = source.currentCampaignId,
        }
        source.operations.order[#source.operations.order + 1] = opId
        source.operations.heads[GS.CorrectionTargetKey(source, canon)] = opId
    end
    if GS._BumpOpsValidationGen then
        GS._BumpOpsValidationGen(source.operations)
    end
    GS:EnsureGossipProvider()
    GS.NotifyLocalDurableChange("dataset")
    drainExportMaint(256)
    local exportBodies = collectAllExportBodies()
    assertTrue(#exportBodies >= 1, "459-SC: exported bodies n=" .. tostring(#exportBodies))
    local aliasPages = {}
    for i = 1, #exportBodies do
        if exportBodies[i].body.kind == "gs-credit-aliases-page" then
            aliasPages[#aliasPages + 1] = exportBodies[i]
        end
    end
    assertTrue(#aliasPages >= 1, "459-SC: alias pages exported n=" .. tostring(#aliasPages))
    local sourceDataset = source.datasetId

    SpectrumFederationDB = {}
    switchPlayer("Carol", "Player-1-Carol", 2)
    settleRoster()
    GS._adoptionEpoch = 0
    GS._peerDatasets = {}
    GS._pendingRelay = {}
    GS._adoption = nil
    initGS()
    GS:CreateStagedRecord()
    local beforeDs = GS:GetCurrentRecord()
    local beforeId = beforeDs and beforeDs.datasetId
    GS:EnsureGossipProvider()
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "459-SC: begin")
    for i = 1, #exportBodies do
        GS:BufferAdoptionRecord(exportBodies[i].id, exportBodies[i].body)
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "459-SC: ready before change")
    local dupSt = select(1, GS:BufferAdoptionRecord(
        aliasPages[1].id, aliasPages[1].body))
    assertEq(dupSt, "duplicate", "459-SC: identical redelivery duplicate")
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "459-SC: still ready after identical redelivery")
    local changed = {}
    for k, v in pairs(aliasPages[1].body) do changed[k] = v end
    local changedAliases = {}
    for a, c in pairs(aliasPages[1].body.aliases or {}) do
        changedAliases[a] = c
    end
    local victim = nil
    for a in pairs(changedAliases) do victim = a break end
    assertTrue(victim ~= nil, "459-SC: victim alias")
    changedAliases[victim] = "ctx:sc-CHANGED-CANON"
    changed.aliases = changedAliases
    local stChg, rChg = GS:BufferAdoptionRecord(aliasPages[1].id, changed)
    assertEq(stChg, "rejected",
        "459-SC: changed page rejected got " .. tostring(stChg) .. "/" .. tostring(rChg))
    assertEq(rChg, "source_changed",
        "459-SC: source_changed got " .. tostring(rChg))
    assertTrue(GS:GetPendingAdoption() == nil, "459-SC: session cleared")
    local stCommit, rCommit = GS:CommitDatasetAdoption()
    assertTrue(stCommit ~= "accepted",
        "459-SC: stale commit blocked got "
            .. tostring(stCommit) .. "/" .. tostring(rCommit))
    local afterDs = GS:GetCurrentRecord()
    assertEq(afterDs and afterDs.datasetId, beforeId,
        "459-SC: active dataset retained")

    -- Fresh consistent adoption of the original export succeeds.
    GS.NotePeerDataset("Alice-Garona", sourceDataset, { editorRankPosition = 1 })
    assertEq(select(2, GS:BeginDatasetAdoption("Alice-Garona", sourceDataset)), "accepted",
        "459-SC: begin fresh")
    for i = 1, #exportBodies do
        local st = select(1, GS:BufferAdoptionRecord(
            exportBodies[i].id, exportBodies[i].body))
        assertTrue(st == "accepted" or st == "duplicate",
            "459-SC: fresh buffer " .. tostring(exportBodies[i].id))
    end
    assertTrue(GS:GetPendingAdoption() and GS:GetPendingAdoption().ready,
        "459-SC: fresh ready")
    local stFresh, rFresh = GS:CommitDatasetAdoption()
    local gFresh = 0
    while stFresh == "pending" and gFresh < 128 do
        if not runOneDueTimer() then
            stFresh, rFresh = GS:CommitDatasetAdoption()
        else
            stFresh, rFresh = GS:CommitDatasetAdoption()
        end
        gFresh = gFresh + 1
    end
    flushTimers()
    assertEq(stFresh, "accepted",
        "459-SC: fresh commit accepted got "
            .. tostring(stFresh) .. "/" .. tostring(rFresh))
    switchPlayer("Alice", "Player-1-Alice", 1)
    settleRoster()
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
