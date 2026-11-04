-- Production-Lua tests for Guild Supplies Raid Supply UI (#453).
-- Run from repository root: lua5.1 tests/lua/guild_supplies_453_tests.lua

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

function CreateFrame(frameType, name, parent, template)
    local f = {
        name = name,
        kind = frameType or "Frame",
        parent = parent,
        events = {},
        children = {},
        shown = true,
        visible = true,
        width = 600,
        height = 40,
        points = {},
        scripts = {},
        text = "",
        RegisterEvent = function(self, e) self.events[e] = true end,
        UnregisterAllEvents = function(self) self.events = {} end,
        UnregisterEvent = function(self, e) self.events[e] = nil end,
        SetScript = function(self, ev, fn)
            if ev == "OnEvent" then self._onEvent = fn end
            self.scripts[ev] = fn
        end,
        GetScript = function(self, ev) return self.scripts[ev] end,
        SetSize = function(self, w, h) self.width, self.height = w, h end,
        SetWidth = function(self, w) self.width = tonumber(w) or 0 end,
        SetHeight = function(self, h) self.height = tonumber(h) or 0 end,
        GetWidth = function(self) return self.width or 0 end,
        GetHeight = function(self) return self.height or 0 end,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        IsShown = function(self) return self.shown and true or false end,
        IsVisible = function(self) return self.visible ~= false and self.shown ~= false end,
        SetShown = function(self, v) self.shown = v and true or false end,
        SetParent = function(self, p) self.parent = p end,
        GetParent = function(self) return self.parent end,
        SetPoint = function(self, ...) self.points[#self.points + 1] = {...} end,
        ClearAllPoints = function(self) self.points = {} end,
        SetAllPoints = function() end,
        CreateFontString = function(self)
            local fs = CreateFrame("FontString")
            fs.SetText = function(s, t) s.text = t end
            fs.GetText = function(s) return s.text end
            fs.SetFontObject = function() end
            fs.SetJustifyH = function() end
            fs.SetTextColor = function() end
            fs.SetWordWrap = function() end
            self.children[#self.children + 1] = fs
            return fs
        end,
        CreateTexture = function(self)
            local t = CreateFrame("Texture")
            t.SetTexture = function() end
            t.SetColorTexture = function() end
            t.SetTexCoord = function() end
            t.SetVertexColor = function() end
            self.children[#self.children + 1] = t
            return t
        end,
        EnableMouse = function() end,
        EnableMouseWheel = function() end,
        RegisterForDrag = function() end,
        SetMovable = function() end,
        SetResizable = function() end,
        SetClipsChildren = function() end,
        SetFrameStrata = function() end,
        SetFrameLevel = function() end,
        SetDrawLayer = function() end,
        SetAlpha = function() end,
        SetScale = function() end,
        SetHitRectInsets = function() end,
        SetText = function(self, t) self.text = t end,
        GetText = function(self) return self.text end,
        SetEnabled = function(self, v) self.enabled = v and true or false end,
        Disable = function(self) self.enabled = false end,
        Enable = function(self) self.enabled = true end,
        SetNormalFontObject = function() end,
        SetHighlightFontObject = function() end,
        SetDisabledFontObject = function() end,
        SetNormalTexture = function() end,
        SetPushedTexture = function() end,
        SetHighlightTexture = function() end,
        SetDisabledTexture = function() end,
        SetChecked = function() end,
        SetMinMaxValues = function() end,
        SetValue = function() end,
        SetValueStep = function() end,
        SetOrientation = function() end,
        SetStatusBarTexture = function() end,
        SetStatusBarColor = function() end,
        SetScrollChild = function() end,
        UpdateScrollChildRect = function() end,
        SetVerticalScroll = function() end,
        SetHorizontalScroll = function() end,
        GetObjectType = function(self) return self.kind or "Frame" end,
        GetName = function(self) return self.name end,
        HookScript = function() end,
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
    GUILD_SUPPLIES_CAMPAIGN_UNNAMED = "Unnamed campaign",
    GUILD_SUPPLIES_CAMPAIGN_DROPDOWN_CURRENT = "%s (Current)",
    GUILD_SUPPLIES_CAMPAIGN_TOOLTIP_STARTED = "Started: %s",
    GUILD_SUPPLIES_ADJUST_UNASSIGNED = "Unassigned",
    GUILD_SUPPLIES_LOGS_ADJUST_MARK = "Adjustment",
    GUILD_SUPPLIES_LOGS_ADJUST_CONTRIBUTOR = "%s · %s",
    GUILD_SUPPLIES_LOGS_ADJUST_OFFICER = "Adjusted by %s.",
    GUILD_SUPPLIES_LOGS_QTY_SIGNED = "%+d",
    GUILD_SUPPLIES_LOGS_QTY_PLAIN = "%d",
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
-- Load Settings pages (registration + __sfTest hooks; no full Build harness)
---------------------------------------------------------------------------

GameTooltip = GameTooltip or {
    Hide = function() end, SetOwner = function() end, SetText = function() end,
    AddLine = function() end, Show = function() end,
}
OKAY = OKAY or "OK"
CANCEL = CANCEL or "Cancel"
StaticPopupDialogs = StaticPopupDialogs or {}
function StaticPopup_Show() return {} end
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
SF.SettingsStore = { Get = function() return true end, Set = function() end }

-- Lightweight stubs so page modules load without pulling the full Settings chrome.
SF.SettingsUI.Style = SF.SettingsUI.Style or {}
SF.SettingsUI.Controls = SF.SettingsUI.Controls or {}
SF.SettingsUI.DefinitionRenderer = SF.SettingsUI.DefinitionRenderer or {}
SF.ItemDisplay = SF.ItemDisplay or {
    RegisterRefresh = function() end,
    ResetSession = function() end,
    QUESTION_MARK = "Interface/Icons/INV_Misc_QuestionMark",
}

loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesConfiguration.lua")
loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesManage.lua")
loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesLogs.lua")

local configPage = SF.SettingsUI.pagesById.guildSuppliesConfiguration
local managePage = SF.SettingsUI.pagesById.guildSuppliesManage
local logsPage = SF.SettingsUI.pagesById.guildSuppliesLogs
assertTrue(configPage ~= nil, "453: Configuration registered")
assertTrue(managePage ~= nil, "453: Manage registered")
assertTrue(logsPage ~= nil, "453: Logs registered")
assertTrue(type(managePage.available) == "function", "453: Manage.available")
assertTrue(type(configPage.__sfTest) == "table", "453: Configuration __sfTest")
assertTrue(type(logsPage.__sfTest) == "table", "453: Logs __sfTest")

local function sectionIds(def)
    local ids = {}
    for _, sec in ipairs((def and def.sections) or {}) do
        ids[sec.id] = true
    end
    return ids
end

---------------------------------------------------------------------------
-- #453) Setup buttons, Manage access, campaign naming, Logs table/filters
---------------------------------------------------------------------------

do
    resetDb()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    initGS()
    local hooks = configPage.__sfTest
    assertEq(hooks.InitializeButtonVisible(), true, "453: Initialize on first-time setup")
    assertEq(hooks.ActivateButtonVisible(), false, "453: Activate hidden before staged dataset")

    assertEq(select(2, GS:CreateStagedRecord()), "accepted", "453: stage dataset")
    assertEq(hooks.InitializeButtonVisible(), false, "453: Initialize hidden after setup")
    assertEq(hooks.ActivateButtonVisible(), true, "453: Activate while staged")

    startCampaign()
    local tabOp = select(1, GS:NewConfigOperation("set-bank-tab", "bankTab", 2))
    assertEq(GS:ApplyStagedConfigOperation(tabOp), "accepted", "453: bank tab")
    GetNumGuildBankTransactions = function() return 0 end
    GetGuildBankTransaction = function()
        return "deposit", "Donor-Garona", "|Hitem:9100::::::::|h[Flask]|h", 2,
            1, 1, 2026, 10, 19, 12
    end
    GS._BankContextReadinessProbe = function() return true end
    local _, actSt = GS:ActivateCanonicalDataset()
    assertEq(actSt, "accepted", "453: activate")
    assertEq(hooks.InitializeButtonVisible(), false, "453: Initialize hidden after activation")
    assertEq(hooks.ActivateButtonVisible(), false, "453: Activate hidden after activation")
    GetNumGuildBankTransactions = nil
    GetGuildBankTransaction = nil
    GS._BankContextReadinessProbe = nil

    local cfgIds = sectionIds(hooks.Definition())
    assertEq(cfgIds.gsProgress == true, true, "453: Configuration hosts gsProgress")
    assertEq(cfgIds.gsItems == true, false, "453: Configuration no longer hosts gsItems")
    assertEq(cfgIds.gsAdjust == true, false, "453: Configuration no longer hosts gsAdjust")

    local manageIds = sectionIds(managePage.__sfTest.Definition())
    assertEq(manageIds.gsItems == true, true, "453: Manage hosts gsItems")
    assertEq(manageIds.gsAdjust == true, true, "453: Manage hosts gsAdjust")
end

do
    resetDb()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    startCampaign()
    assertEq(managePage.available(), true, "453: officer Manage available")

    setPlayer("Dave-Garona", "Player-1-Dave", 4)
    settleRoster()
    assertEq(managePage.available(), false, "453: member Manage unavailable")

    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    settleRoster()
    world.impersonationActive = true
    assertEq(managePage.available(), false, "453: Preview as Non-Admin hides Manage")
    world.impersonationActive = false
    assertEq(managePage.available(), true, "453: Manage returns after Preview ends")
end

do
    resetDb()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    local first = startCampaign()
    local rec = GS:GetCurrentRecord()
    assertEq(GS.GetCampaignFriendlyName(rec, first.id), "Unnamed campaign",
        "453: unnamed friendly fallback")
    assertEq(GS.GetCampaignDisplayName(rec, first.id), first.id,
        "453: internal display name keeps ID fallback")
    local list = GS:ListInspectableCampaigns()
    local curEntry
    for i = 1, #list do
        if list[i].campaignId == first.id then curEntry = list[i] end
    end
    assertTrue(curEntry ~= nil, "453: current inspectable")
    assertEq(GS.FormatCampaignDropdownLabel(curEntry), "Unnamed campaign (Current)",
        "453: dropdown appends (Current)")
    local tip = GS.FormatCampaignDisambiguationTooltip(curEntry)
    assertTrue(type(tip) == "string" and tip:find("Started:", 1, true),
        "453: disambiguation tooltip has start date got=" .. tostring(tip))

    local renameOp = select(1, GS:NewRenameCampaignOperation(first.id, "Alpha Raid"))
    assertTrue(renameOp ~= nil, "453: rename prepare")
    assertEq(GS:ApplyStagedConfigOperation(renameOp), "accepted", "453: rename applied")
    rec = GS:GetCurrentRecord()
    assertEq(GS.GetCampaignFriendlyName(rec, first.id), "Alpha Raid", "453: friendly custom name")
    list = GS:ListInspectableCampaigns()
    for i = 1, #list do
        if list[i].campaignId == first.id then curEntry = list[i] end
    end
    assertEq(GS.FormatCampaignDropdownLabel(curEntry), "Alpha Raid (Current)",
        "453: named current dropdown label")

    local second = startCampaign()
    rec = GS:GetCurrentRecord()
    list = GS:ListInspectableCampaigns()
    local archivedEntry, currentEntry
    for i = 1, #list do
        if list[i].campaignId == first.id then archivedEntry = list[i] end
        if list[i].campaignId == second.id then currentEntry = list[i] end
    end
    assertEq(GS.FormatCampaignDropdownLabel(archivedEntry), "Alpha Raid",
        "453: non-current dropdown has no (Current) suffix")
    assertTrue(GS.FormatCampaignDropdownLabel(currentEntry):find("(Current)", 1, true),
        "453: new current keeps (Current)")
    assertEq(GS.GetCampaignFriendlyName(rec, first.id), "Alpha Raid",
        "453: outside dropdowns name alone")
end

do
    resetDb()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    startCampaign()
    local seed = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 10 }, {
        itemId = 10, goal = 5, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(seed), "accepted", "453: seed item")
    local rec = GS:GetCurrentRecord()
    local gen = rec.accounting._consumables.generation
    for i = 1, 30 do
        rec.accounting._consumableEvents[#rec.accounting._consumableEvents + 1] = {
            id = "hist-" .. i,
            type = "donation",
            itemId = 10,
            quantity = 1,
            actor = "Bob-Garona",
            generation = gen,
            timestamp = world.time + i,
            source = "guildbank",
            gsProductionCredit = true,
        }
    end
    rec.accounting._consumableEvents[#rec.accounting._consumableEvents + 1] = {
        id = "hist-adj-credit",
        type = "adjustment",
        itemId = 10,
        quantity = 5,
        actor = "Alice-Garona",
        attributed = "Carol-Garona",
        generation = gen,
        timestamp = world.time + 40,
    }
    rec.accounting._consumableEvents[#rec.accounting._consumableEvents + 1] = {
        id = "hist-adj-unassigned",
        type = "adjustment",
        itemId = 10,
        quantity = -2,
        actor = "Alice-Garona",
        generation = gen,
        timestamp = world.time + 41,
    }
    local removeOp = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 10 }, {
        removed = true,
    }))
    assertEq(GS:ApplyStagedConfigOperation(removeOp), "accepted", "453: remove requested item")

    -- Structural: Logs definition virtualizes and omits pager/campaign selector.
    local logsSrc = assert(io.open("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesLogs.lua", "r"))
    local logsBody = logsSrc:read("*a")
    logsSrc:close()
    assertTrue(logsBody:find("virtualize = true", 1, true), "453: Logs virtualize=true in source")
    assertTrue(not logsBody:find("historyTotal", 1, true), "453: no historyTotal pager state")
    assertTrue(not logsBody:find("HISTORY_PREV", 1, true), "453: no Newer control locale usage")
    assertTrue(logsBody:find("GUILD_SUPPLIES_LOGS_FILTER_CLEAR", 1, true), "453: Clear filter present")

    local hooks = logsPage.__sfTest
    local rows = hooks.BuildProjectedRows()
    assertTrue(#rows >= 32, "453: all retained entries projected (>25)")
    assertEq(rows[1].id, "hist-adj-unassigned", "453: newest first")
    assertTrue((rows[1].contributor or ""):find("Unassigned", 1, true),
        "453: unassigned adjustment contributor")
    assertTrue((rows[1].quantity or ""):find("-2", 1, true), "453: signed adjustment qty")
    assertTrue((rows[1].tooltip or ""):find("Alice-Garona", 1, true),
        "453: officer in adjustment tooltip")
    assertTrue((rows[2].contributor or ""):find("Carol-Garona", 1, true),
        "453: credited adjustment contributor")
    assertTrue((rows[2].contributor or ""):find("Adjustment", 1, true),
        "453: adjustment distinguished in contributor cell")

    hooks.SetFilters("Bob-Garona", 10)
    assertEq(#hooks.FilteredRows(), 30, "453: combined filters cover removed-item donations")
    hooks.ClearFilters()
    assertEq(#hooks.FilteredRows(), #hooks.BuildProjectedRows(), "453: Clear resets filters")

    hooks.SetFilters("Bob-Garona", 10)
    startCampaign()
    hooks.SyncFilterContext()
    assertEq(#hooks.BuildProjectedRows(), 0, "453: new campaign empty history")
    assertEq(#hooks.FilteredRows(), 0, "453: stale filters cleared on rollover")
    assertTrue((hooks.EmptyLogsText() or ""):find("No donations or adjustments", 1, true),
        "453: empty current-campaign emptyText guidance")

    -- Hidden page must not drive renderer work; open/close cycles settle.
    local panel = CreateFrame("Frame")
    panel.shown = false
    panel.visible = false
    logsPage.panel = panel
    local rendererWork = 0
    SF.SettingsUI.DefinitionRenderer.Refresh = function()
        rendererWork = rendererWork + 1
    end
    logsPage:Refresh(panel)
    assertEq(rendererWork, 0, "453: hidden Logs page skips renderer Refresh work")
    panel.shown = true
    panel.visible = true
    for _ = 1, 5 do
        local projected = hooks.BuildProjectedRows()
        assertEq(#projected, 0, "453: open/close projection stays empty for new campaign")
        assertEq(#hooks.FilteredRows(), 0, "453: open/close filtered rows stay empty")
        logsPage:Refresh(panel)
        if logsPage.OnHide then logsPage:OnHide() end
    end
    SF.SettingsUI.DefinitionRenderer.Refresh = nil
    local afterHide = hooks.BuildProjectedRows()
    assertEq(#afterHide, 0, "453: post-hide projection for empty campaign stays empty")
    assertEq(rendererWork, 5, "453: visible Logs Refresh runs each open cycle")
end

do
    -- Class colors: one GuildInfo:GetCurrentRecord validation per projection pass.
    resetDb()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    startCampaign()
    local seed = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 20 }, {
        itemId = 20, goal = 10, removed = false,
    }))
    assertEq(GS:ApplyStagedConfigOperation(seed), "accepted", "453: class-color seed item")
    local rec = GS:GetCurrentRecord()
    local gen = rec.accounting._consumables.generation
    for i = 1, 12 do
        rec.accounting._consumableEvents[#rec.accounting._consumableEvents + 1] = {
            id = "class-hist-" .. i,
            type = "donation",
            itemId = 20,
            quantity = 1,
            actor = "Bob-Garona",
            actorGuid = "Player-1-Bob",
            generation = gen,
            timestamp = world.time + i,
            source = "guildbank",
            gsProductionCredit = true,
        }
    end

    local giCalls = 0
    SF.GuildInfo = {
        GetCurrentRecord = function()
            giCalls = giCalls + 1
            -- Simulate ValidateGuildRecord cost by scanning a members table.
            local members = world.guild.members
            for _ = 1, #members do
            end
            return {
                characters = {
                    ["Player-1-Bob"] = { nameRealm = "Bob-Garona", classFile = "MAGE" },
                    ["Player-1-Carol"] = { nameRealm = "Carol-Garona", classFile = "PRIEST" },
                },
            }
        end,
        ColorizeName = function(name, classFile)
            if type(classFile) == "string" and classFile ~= "" then
                return "[" .. classFile .. "]" .. name
            end
            return name
        end,
    }

    local hooks = logsPage.__sfTest
    local rows, lookupCalls = hooks.ProjectWithGuildLookupStats()
    assertTrue(#rows >= 12, "453: class-color projection covers repeated donors")
    assertEq(lookupCalls, 1, "453: one GuildInfo:GetCurrentRecord per projection pass")
    assertEq(giCalls, 1, "453: repeated history rows do not each validate guild")
    local colored = 0
    for i = 1, #rows do
        if type(rows[i].contributor) == "string"
            and rows[i].contributor:find("%[MAGE%]", 1) then
            colored = colored + 1
        end
    end
    assertTrue(colored >= 12, "453: class colors apply without Loot Helper profiles")
    -- Independence from Loot Helper: no LH profile lookup in the path.
    assertTrue(SF.LootHelper == nil or SF.LootHelper.GetProfile == nil,
        "453: class colors do not require Loot Helper profiles")

    -- Second projection with warm cache still only one GI call for a fresh pass.
    giCalls = 0
    rows, lookupCalls = hooks.ProjectWithGuildLookupStats()
    assertEq(lookupCalls, 1, "453: fresh projection pass still one lookup")
    assertEq(giCalls, 1, "453: second pass still one GI validation")
    SF.GuildInfo = nil
end

do
    -- Manage mutation-time authorization (production NewConfigOperation path).
    resetDb()
    setPlayer("Alice-Garona", "Player-1-Alice", 1)
    initGS()
    GS:CreateStagedRecord()
    startCampaign()
    assertEq(managePage.available(), true, "453: officer can open Manage before mutation")
    local okOp = select(1, GS:NewConfigOperation("set-requested-item", { itemId = 99 }, {
        itemId = 99, goal = 3, removed = false,
    }))
    assertTrue(okOp ~= nil, "453: officer prepares requested-item mutation")
    assertEq(GS:ApplyStagedConfigOperation(okOp), "accepted", "453: officer mutation accepted")

    setPlayer("Dave-Garona", "Player-1-Dave", 4)
    settleRoster()
    assertEq(managePage.available(), false, "453: member Manage nav closed")
    local denied, status, reason = GS:NewConfigOperation("set-requested-item", { itemId = 100 }, {
        itemId = 100, goal = 1, removed = false,
    })
    assertTrue(denied == nil, "453: member mutation prepare fails closed")
    assertTrue(status == "rejected" or reason ~= nil,
        "453: member mutation returns rejection status got="
            .. tostring(status) .. "/" .. tostring(reason))
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
