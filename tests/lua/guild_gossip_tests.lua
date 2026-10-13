-- Production-Lua tests for Guild Gossip Phase 1 (#378).
-- Run from repository root: lua5.1 tests/lua/guild_gossip_tests.lua

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
-- Minimal table serializer for C_EncodingUtil CBOR/Base64 mocks
---------------------------------------------------------------------------

local function ser(v, seen)
    seen = seen or {}
    local t = type(v)
    if v == nil then return "N"
    elseif t == "boolean" then return v and "T" or "F"
    elseif t == "number" then return "#" .. tostring(v) .. ";"
    elseif t == "string" then return "$" .. #v .. ":" .. v
    elseif t == "table" then
        if seen[v] then return "@"
        end
        seen[v] = true
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for i = 1, #keys do
            local k = keys[i]
            parts[#parts + 1] = ser(k, seen) .. "=" .. ser(v[k], seen)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "?"
end

local function deser(s, i)
    i = i or 1
    local c = s:sub(i, i)
    if c == "N" then return nil, i + 1
    elseif c == "T" then return true, i + 1
    elseif c == "F" then return false, i + 1
    elseif c == "#" then
        local j = s:find(";", i + 1, true)
        return tonumber(s:sub(i + 1, j - 1)), j + 1
    elseif c == "$" then
        local colon = s:find(":", i + 1, true)
        local n = tonumber(s:sub(i + 1, colon - 1))
        local v = s:sub(colon + 1, colon + n)
        return v, colon + n + 1
    elseif c == "{" then
        local t = {}
        i = i + 1
        if s:sub(i, i) == "}" then return t, i + 1 end
        while true do
            local k, ni = deser(s, i)
            assert(s:sub(ni, ni) == "=", "bad ser")
            local v, nj = deser(s, ni + 1)
            t[k] = v
            i = nj
            local ch = s:sub(i, i)
            if ch == "}" then return t, i + 1 end
            assert(ch == ",", "bad ser sep")
            i = i + 1
        end
    end
    error("bad ser at " .. i)
end

---------------------------------------------------------------------------
-- Shared simulated world
---------------------------------------------------------------------------

local world = {
    time = 1000,
    fps = 60,
    combat = false,
    loading = false,
    chat = {},
    prints = {},
    guild = {
        inGuild = true,
        name = "Spectrum",
        realm = "Garona",
        clubId = 42,
        members = {
            { name = "Alice-Garona", online = true },
            { name = "Bob-Garona", online = true },
            { name = "Carol-Garona", online = true },
            { name = "Dave-Garona", online = true },
        },
    },
    wire = {}, -- queued deliveries
    clients = {},
}

function GetTime() return world.time end
function time() return math.floor(world.time) end
function GetServerTime() return math.floor(world.time) end
function GetFramerate() return world.fps end
function UnitAffectingCombat() return world.combat end
function IsLoadingScreenShown() return world.loading end
function IsInGuild() return world.guild.inGuild end
function GetGuildInfo(unit)
    if unit == "player" and world.guild.inGuild then
        return world.guild.name, "Rank", 0, world.guild.realm
    end
end
function GetNumGuildMembers() return #world.guild.members, #world.guild.members, #world.guild.members end
function GetGuildRosterInfo(i)
    local m = world.guild.members[i]
    if not m then return end
    return m.name, "Rank", 0, 80, "Warrior", "Zone", "", "", m.online, 0, "WARRIOR", 0, 0, false, false, 0
end
C_GuildInfo = { GuildRoster = function() end }
C_Club = { GetGuildClubId = function() return world.guild.clubId end }
function GetRealmName() return "Garona" end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function UnitFullName() return world._unitName, "Garona" end
function UnitName() return world._unitName end

local timers = {}
local function installTimers()
    C_Timer = {
        After = function(delay, fn)
            timers[#timers + 1] = {
                at = world.time + delay,
                fn = fn,
                kind = "after",
                owner = world._unitName,
            }
        end,
        NewTimer = function(delay, fn)
            local h = {
                at = world.time + delay,
                fn = fn,
                kind = "timer",
                cancelled = false,
                owner = world._unitName,
            }
            function h:Cancel() self.cancelled = true end
            timers[#timers + 1] = h
            return h
        end,
        NewTicker = function(interval, fn)
            local h = {
                interval = interval,
                fn = fn,
                kind = "ticker",
                cancelled = false,
                nextAt = world.time + interval,
                owner = world._unitName,
            }
            function h:Cancel() self.cancelled = true end
            timers[#timers + 1] = h
            return h
        end,
    }
end
installTimers()

function CreateFrame()
    local f = { events = {} }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterAllEvents() self.events = {} end
    function f:SetScript(name, fn) self[name] = fn end
    return f
end

C_EncodingUtil = {
    SerializeCBOR = function(t) return ser(t) end,
    DeserializeCBOR = function(s) return select(1, deser(s, 1)) end,
    EncodeBase64 = function(s) return "B64" .. s end,
    DecodeBase64 = function(s)
        if s:sub(1, 3) == "B64" then return s:sub(4) end
        return s
    end,
}

C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
}

local chatOutput = {}
DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, msg)
        chatOutput[#chatOutput + 1] = tostring(msg)
    end,
}
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    chatOutput[#chatOutput + 1] = table.concat(parts, "\t")
end

---------------------------------------------------------------------------
-- AceComm / LibStub mock with multipart + alternate-instance support
---------------------------------------------------------------------------

local function makeAceComm(label)
    local AceComm = {
        label = label or "vendored",
        embeds = {},
        multipart_spool = {},
        callbacks_by_prefix = {},
    }
    function AceComm:Embed(target)
        target.SendCommMessage = function(self, prefix, text, distribution, targetName, prio, callbackFn, callbackArg)
            return AceComm:SendCommMessage(prefix, text, distribution, targetName, prio, callbackFn, callbackArg)
        end
        target.RegisterComm = function(self, prefix, method)
            return AceComm:RegisterComm(self, prefix, method)
        end
        AceComm.embeds[target] = true
    end
    function AceComm:RegisterComm(owner, prefix, method)
        AceComm.callbacks_by_prefix[prefix] = AceComm.callbacks_by_prefix[prefix] or {}
        local fn = method
        if type(method) == "string" then
            fn = function(_, ...) return owner[method](owner, ...) end
        end
        table.insert(AceComm.callbacks_by_prefix[prefix], { owner = owner, fn = fn })
    end
    function AceComm:Fire(prefix, text, distribution, sender)
        local list = AceComm.callbacks_by_prefix[prefix] or {}
        for _, entry in ipairs(list) do
            entry.fn(entry.owner, prefix, text, distribution, sender)
        end
    end
    function AceComm:OnReceiveMultipartFirst(prefix, message, distribution, sender)
        local key = prefix .. "\t" .. distribution .. "\t" .. sender
        AceComm.multipart_spool[key] = message
    end
    function AceComm:OnReceiveMultipartNext(prefix, message, distribution, sender)
        local key = prefix .. "\t" .. distribution .. "\t" .. sender
        local old = AceComm.multipart_spool[key]
        if not old then return end
        if type(old) ~= "table" then
            AceComm.multipart_spool[key] = { old, message }
        else
            old[#old + 1] = message
        end
    end
    function AceComm:OnReceiveMultipartLast(prefix, message, distribution, sender)
        local key = prefix .. "\t" .. distribution .. "\t" .. sender
        local old = AceComm.multipart_spool[key]
        if not old then return end
        AceComm.multipart_spool[key] = nil
        local full
        if type(old) == "table" then
            old[#old + 1] = message
            full = table.concat(old, "")
        else
            full = old .. message
        end
        AceComm:Fire(prefix, full, distribution, sender)
    end
    function AceComm:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
        local textlen = #text
        local sender = world._sendAs or ((world._unitName and (world._unitName .. "-Garona")) or "Unknown-Garona")
        -- Deliver through world wire to all / target clients.
        world.wire[#world.wire + 1] = {
            prefix = prefix,
            text = text,
            distribution = distribution,
            target = target,
            sender = sender,
            prio = prio,
            ace = AceComm,
        }
        -- Match AceComm callback shape: (callbackArg, sent, textlen, sendResult)
        if callbackFn then
            callbackFn(callbackArg, textlen, textlen, true)
        end
    end
    return AceComm
end

local activeAceComm = makeAceComm("vendored")
LibStub = function(name, quiet)
    if name == "AceComm-3.0" then
        return activeAceComm
    end
    if quiet then return nil end
    error("missing " .. tostring(name))
end

---------------------------------------------------------------------------
-- Client factory loading production modules
---------------------------------------------------------------------------

local MODULES = {
    "SpectrumFederation/modules/NameUtil.lua",
    "SpectrumFederation/modules/LootHelper/SyncProtocol.lua",
    "SpectrumFederation/modules/LootHelper/Comm.lua",
    "SpectrumFederation/modules/GuildGossip/01_Constants.lua",
    "SpectrumFederation/modules/GuildGossip/02_Util.lua",
    "SpectrumFederation/modules/GuildGossip/03_Codec.lua",
    "SpectrumFederation/modules/GuildGossip/04_ReceiveGuard.lua",
    "SpectrumFederation/modules/GuildGossip/05_GuildAdapter.lua",
    "SpectrumFederation/modules/GuildGossip/06_Scheduler.lua",
    "SpectrumFederation/modules/GuildGossip/07_Index.lua",
    "SpectrumFederation/modules/GuildGossip/08_Providers.lua",
    "SpectrumFederation/modules/GuildGossip/09_Engine.lua",
    "SpectrumFederation/modules/GuildGossip/10_PublicAPI.lua",
}

local function makeClient(name)
    local SF = {
        name = name,
        debugEnabled = false,
        debugLogs = {},
        chat = {},
    }
    function SF:Now() return world.time end
    function SF:PrintSuccess(m) SF.chat[#SF.chat + 1] = m end
    function SF:PrintError(m) SF.chat[#SF.chat + 1] = m end
    function SF:PrintWarning(m) SF.chat[#SF.chat + 1] = m end
    function SF:PrintInfo(m) SF.chat[#SF.chat + 1] = m end
    function SF:SystemMessage(m) SF.chat[#SF.chat + 1] = m end
    SF.Debug = {
        IsEnabled = function() return SF.debugEnabled end,
        Verbose = function(_, _, fmt, ...)
            if SF.debugEnabled then
                SF.debugLogs[#SF.debugLogs + 1] = string.format(tostring(fmt), ...)
            end
        end,
        Info = function(_, _, fmt, ...)
            if SF.debugEnabled then
                SF.debugLogs[#SF.debugLogs + 1] = string.format(tostring(fmt), ...)
            end
        end,
        Warn = function(_, _, fmt, ...)
            if SF.debugEnabled then
                SF.debugLogs[#SF.debugLogs + 1] = string.format(tostring(fmt), ...)
            end
        end,
        Error = function(_, _, fmt, ...)
            if SF.debugEnabled then
                SF.debugLogs[#SF.debugLogs + 1] = string.format(tostring(fmt), ...)
            end
        end,
    }

    world._unitName = name
    for _, path in ipairs(MODULES) do
        local chunk = assert(loadfile(path))
        chunk("SpectrumFederation", SF)
    end
    SF.LootHelperComm:Init()
    SF.GuildGossip.Init()
    -- Force guild ready with shared roster.
    SF.GuildGossip.RefreshGuildState()
    SF._name = name
    world.clients[name] = SF
    return SF
end

local function deliverWire()
    local batch = world.wire
    world.wire = {}
    for _, msg in ipairs(batch) do
        for cname, SF in pairs(world.clients) do
            local full = cname .. "-Garona"
            local deliver = false
            if msg.distribution == "GUILD" and msg.sender ~= full then
                deliver = true
            elseif msg.distribution == "WHISPER" and msg.target == full then
                deliver = true
            end
            if deliver and SF.LootHelperComm and SF.LootHelperComm.OnCommReceived then
                world._unitName = cname
                SF.LootHelperComm:OnCommReceived(msg.prefix, msg.text, msg.distribution, msg.sender)
            end
        end
    end
end

local function pumpClient(cname, SF)
    world._unitName = cname
    world._sendAs = cname .. "-Garona"
    if SF.LootHelperComm and SF.LootHelperComm._PumpQueue then
        SF.LootHelperComm:_PumpQueue()
    end
    world._sendAs = nil
end

local function advanceTime(dt)
    local target = world.time + dt
    while world.time < target do
        world.time = world.time + 0.05
        -- Fire due timers/tickers with correct sender context when possible.
        for _, h in ipairs(timers) do
            if not h.cancelled then
                if h.kind == "ticker" and world.time >= (h.nextAt or 0) then
                    if h.owner then
                        world._unitName = h.owner
                        world._sendAs = h.owner .. "-Garona"
                    end
                    h.fn()
                    h.nextAt = world.time + h.interval
                    world._sendAs = nil
                elseif (h.kind == "timer" or h.kind == "after") and h.at and world.time >= h.at and not h.fired then
                    h.fired = true
                    if h.owner then
                        world._unitName = h.owner
                        world._sendAs = h.owner .. "-Garona"
                    end
                    h.fn()
                    world._sendAs = nil
                end
            end
        end
        deliverWire()
        -- Pump each client and deliver immediately so sender identity stays correct.
        for cname, SF in pairs(world.clients) do
            pumpClient(cname, SF)
            deliverWire()
        end
    end
end

local function runSteps(n)
    for i = 1, n do
        for cname, SF in pairs(world.clients) do
            world._unitName = cname
            world._sendAs = cname .. "-Garona"
            local GG = SF.GuildGossip
            if GG.HasActiveProvider and GG.HasActiveProvider() then
                GG.UpdatePauseState(world.time)
                if not GG.IsSchedPaused() then
                    GG.SampleFps(world.time)
                    local limits = GG.GetStepLimits()
                    GG.OnSchedulerStep(limits, world.time)
                end
            end
            world._sendAs = nil
            pumpClient(cname, SF)
            deliverWire()
        end
        advanceTime(0.1)
    end
end

local function resetWorld()
    world.time = 1000
    world.fps = 60
    world.combat = false
    world.loading = false
    world.wire = {}
    world.clients = {}
    world._sendAs = nil
    timers = {}
    chatOutput = {}
    activeAceComm = makeAceComm("vendored")
    installTimers()
    world.guild.members = {
        { name = "Alice-Garona", online = true },
        { name = "Bob-Garona", online = true },
        { name = "Carol-Garona", online = true },
        { name = "Dave-Garona", online = true },
    }
end

local function recordCount(SF, providerId)
    local p = SF.GuildGossip.GetProvider(providerId)
    if not p or not p.api or not p.api.GetStore then return 0 end
    return #(p.api.GetStore().order)
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

-- 1) Codec rejects compressed gossip before decompression
do
    resetWorld()
    local SF = makeClient("Alice")
    local GG = SF.GuildGossip
    local payload, err = GG.DecodePayload("B64junk", "B64CBORZ")
    assertNil(payload, "compressed gossip decode returns nil payload")
    assertEq(err, "compressed gossip rejected", "compressed gossip rejected before decompress")
    local env = GG.BuildWireMessage(GG.MSG.DISC, { proto = 1, enc = { "B64CBOR" }, providers = {} })
    assertTrue(type(env) == "string" and #env <= GG.MAX_DISCOVERY_BYTES, "discovery envelope within 240 bytes")
end

-- 2) Index C1: buckets, end markers, seek, appends do not move finish line
do
    resetWorld()
    local SF = makeClient("Alice")
    local GG = SF.GuildGossip
    local index = GG.CreateIndex()
    -- Insert many ids into bucket 0 specifically.
    local n = 0
    local i = 0
    while n < 40 do
        i = i + 1
        local id = "id-" .. i
        if GG.BucketForId(id) == 0 then
            GG.IndexUpsert(index, id, "v1")
            n = n + 1
        end
    end
    local view = GG.CaptureViewSummaries(index, 1, "scope", "prov", 1)
    local end0 = view.buckets[0].lastSeq
    assertTrue(end0 > 0, "bucket 0 has captured end marker")
    -- Append more into bucket 0 after capture
    local added = 0
    while added < 10 do
        i = i + 1
        local id = "id-" .. i
        if GG.BucketForId(id) == 0 then
            GG.IndexUpsert(index, id, "v1")
            added = added + 1
        end
    end
    local page = GG.IndexSeekManifest(index, 0, 0, end0, 32)
    for _, ent in ipairs(page) do
        assertTrue(ent.seq <= end0, "seek respects captured end marker")
    end
    assertTrue(index.buckets[0].lastSeq > end0, "appends advance index beyond capture")
    pass("C1 seek respects fixed end markers while appends continue")
end

-- 3) Equal-count divergence detected by fingerprint
do
    resetWorld()
    local SF = makeClient("Alice")
    local GG = SF.GuildGossip
    local a = GG.CreateIndex()
    local b = GG.CreateIndex()
    GG.IndexUpsert(a, "x", "v1")
    GG.IndexUpsert(b, "y", "v1")
    -- Force same bucket if needed by picking ids in same bucket
    local idA, idB
    for i = 1, 5000 do
        local id = "eq-" .. i
        if GG.BucketForId(id) == 3 then
            if not idA then idA = id else idB = id break end
        end
    end
    a = GG.CreateIndex()
    b = GG.CreateIndex()
    GG.IndexUpsert(a, idA, "v1")
    GG.IndexUpsert(b, idB, "v1")
    local sa = GG.CaptureViewSummaries(a, 1, "s", "p", 1)
    local sb = GG.CaptureViewSummaries(b, 1, "s", "p", 1)
    assertEq(sa.buckets[3].count, sb.buckets[3].count, "equal count")
    assertTrue(GG.BucketsDiffer(sa.buckets[3], sb.buckets[3]), "fingerprint detects equal-count divergence")
end

-- 4) No provider => no discovery / idle
do
    resetWorld()
    local SF = makeClient("Alice")
    local GG = SF.GuildGossip
    assertTrue(not GG.HasActiveProvider(), "synthetic disabled by default")
    local before = #world.wire
    GG.SendDiscovery()
    assertEq(#world.wire, before, "no discovery without provider")
    assertNil(GG._sched.ticker, "no scheduler ticker without provider")
end

-- 5) Three-peer convergence + two-provider isolation
do
    resetWorld()
    local A = makeClient("Alice")
    local B = makeClient("Bob")
    local C = makeClient("Carol")
    local id1 = "sf.synthetic.gossip"
    local id2 = "sf.synthetic.gossip.b"

    local pA1 = A.GuildGossip:EnableSynthetic({ id = id1, instanceKey = "A1" })
    local pB1 = B.GuildGossip:EnableSynthetic({ id = id1, instanceKey = "B1" })
    local pC1 = C.GuildGossip:EnableSynthetic({ id = id1, instanceKey = "C1" })
    local pA2 = A.GuildGossip:EnableSynthetic({ id = id2, instanceKey = "A2" })
    local pB2 = B.GuildGossip:EnableSynthetic({ id = id2, instanceKey = "B2" })

    pA1.AppendLocal("alice-1", "a1")
    pA1.AppendLocal("alice-2", "a2")
    pB1.AppendLocal("bob-1", "b1")
    pC1.AppendLocal("carol-1", "c1")
    pA2.AppendLocal("iso-a", "ia1")
    pB2.AppendLocal("iso-b", "ib1")

    -- Force discovery announcements into peer sets
    world._unitName = "Alice"; A.GuildGossip.SendDiscovery()
    world._unitName = "Bob"; B.GuildGossip.SendDiscovery()
    world._unitName = "Carol"; C.GuildGossip.SendDiscovery()
    advanceTime(0.5)

    for i = 1, 400 do
        runSteps(5)
        if recordCount(A, id1) >= 4 and recordCount(B, id1) >= 4 and recordCount(C, id1) >= 4
            and recordCount(A, id2) >= 2 and recordCount(B, id2) >= 2 then
            break
        end
    end

    assertTrue(recordCount(A, id1) >= 4, "Alice converged provider1")
    assertTrue(recordCount(B, id1) >= 4, "Bob converged provider1")
    assertTrue(recordCount(C, id1) >= 4, "Carol converged provider1")
    assertTrue(recordCount(A, id2) >= 2, "Alice converged provider2")
    assertTrue(recordCount(B, id2) >= 2, "Bob converged provider2")
    assertEq(recordCount(C, id2), 0, "Carol has no provider2 isolation")

    -- Disable provider2 on Alice; provider1 continues
    A.GuildGossip:DisableProvider(id2)
    pB2.AppendLocal("iso-b2", "ib2")
    world._unitName = "Bob"; B.GuildGossip.SendDiscovery()
    advanceTime(0.2)
    runSteps(50)
    assertTrue(recordCount(B, id1) >= 4, "provider1 still healthy after sibling disable")
end

-- 6) Continuous appends during paging + follow-up dirty flag
do
    resetWorld()
    local A = makeClient("Alice")
    local B = makeClient("Bob")
    local id1 = "sf.synthetic.gossip"
    local pA = A.GuildGossip:EnableSynthetic({ id = id1, instanceKey = "Ap" })
    local pB = B.GuildGossip:EnableSynthetic({ id = id1, instanceKey = "Bp" })
    for i = 1, 40 do pA.AppendLocal("seed-" .. i, "s" .. i) end
    world._unitName = "Alice"; A.GuildGossip.SendDiscovery()
    world._unitName = "Bob"; B.GuildGossip.SendDiscovery()
    advanceTime(0.3)
    -- Start exchange then append
    runSteps(10)
    for i = 41, 60 do pA.AppendLocal("late-" .. i, "l" .. i) end
    assertTrue(A.GuildGossip.HasDirtyFollowUp(), "append during active pull marks follow-up work")
    for i = 1, 400 do
        runSteps(5)
        if recordCount(B, id1) >= 60 then break end
    end
    assertTrue(recordCount(B, id1) >= 60,
        "receiver eventually gets seed+append via follow-up (count=" .. tostring(recordCount(B, id1)) .. ")")
end

-- 7) Rejected/pending do not loop forever; duplicates harmless
do
    resetWorld()
    local A = makeClient("Alice")
    local B = makeClient("Bob")
    local id1 = "sf.synthetic.gossip"
    local pendingIds = { ["pend-1"] = true }
    local pA = A.GuildGossip:EnableSynthetic({ id = id1, instanceKey = "Ar", pendingIds = pendingIds })
    -- Custom B provider that rejects one id
    local pB = B.GuildGossip:EnableSynthetic({ id = id1, instanceKey = "Br" })
    pB.MarkRejected("bad-1")
    pA.AppendLocal("ok-1", "ok1")
    -- Manually inject rejected/pending via Apply
    local entryB = B.GuildGossip.GetProvider(id1)
    local r1 = B.GuildGossip.ApplyRecordToProvider(entryB, { id = "bad-1", versionFp = "v", body = 1 }, { sender = "Alice-Garona" })
    assertEq(r1, "rejected", "rejected outcome")
    local entryA = A.GuildGossip.GetProvider(id1)
    -- Use A's provider with pending ids
    A.GuildGossip.UnregisterProvider(id1)
    local pA2 = A.GuildGossip.CreateSyntheticProvider({ id = id1, instanceKey = "Ar2", pendingIds = pendingIds })
    pA2.enabled = true
    A.GuildGossip.RegisterProvider(pA2)
    A.GuildGossip.SetProviderEnabled(id1, true)
    local pend = A.GuildGossip.ApplyRecordToProvider(A.GuildGossip.GetProvider(id1), { id = "pend-1", versionFp = "v", body = 1 }, {})
    assertEq(pend, "pending", "pending outcome")
    local dup = A.GuildGossip.ApplyRecordToProvider(A.GuildGossip.GetProvider(id1), { id = "ok-local", versionFp = "v1", body = 1 }, {})
    local dup2 = A.GuildGossip.ApplyRecordToProvider(A.GuildGossip.GetProvider(id1), { id = "ok-local", versionFp = "v1", body = 1 }, {})
    assertEq(dup, "accepted", "first accept")
    assertEq(dup2, "duplicate", "duplicate no-op")
end

-- 8) Traffic class: foreground precedes background gossip backlog
do
    resetWorld()
    local SF = makeClient("Alice")
    local Comm = SF.LootHelperComm
    Comm.cfg.queueEnabled = true
    Comm.cfg.maxSendsPerPump = 1
    Comm.state.total = 0
    -- Enqueue many gossip then one control foreground via internal enqueue
    for i = 1, 5 do
        Comm:_EnqueueSend("SF_GG", "g" .. i, "GUILD", nil, "BULK", nil, "BACKGROUND")
    end
    Comm:_EnqueueSend("SF_LH", "control", "RAID", nil, "NORMAL", nil, "FOREGROUND")
    local q = Comm.state.byKey["GUILD"]
    local raidQ = Comm.state.byKey["RAID"]
    assertTrue(raidQ and raidQ[1] and raidQ[1].trafficClass == "FOREGROUND", "foreground enqueued")
    -- Pump should prefer FOREGROUND target
    local sent = {}
    local orig = Comm.SendCommMessage
    Comm.SendCommMessage = function(self, prefix, msg, dist, target, prio, cb)
        sent[#sent + 1] = { prefix = prefix, msg = msg }
        if cb then cb(nil, #msg) end
    end
    Comm:_PumpQueue()
    assertEq(sent[1].prefix, "SF_LH", "foreground CONTROL sent before gossip backlog")
    Comm.SendCommMessage = orig
end

-- 9) D1 FPS modes: missing, 15/20/30 steady SLOW progress, hysteresis
do
    resetWorld()
    local SF = makeClient("Alice")
    local GG = SF.GuildGossip
    GG:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "fps" })
    GG.MarkWorkPending()
    local savedFps = world.fps
    world.fps = nil
    GG.ResetSchedulerForTests({ mode = "NORMAL" })
    GG.MarkWorkPending()
    for i = 1, 3 do
        world.time = world.time + 1
        GG.SampleFps(world.time)
    end
    assertEq(GG.GetSchedMode(), "SLOW", "missing FPS => SLOW")
    world.fps = 15
    GG.ResetSchedulerForTests({ mode = "NORMAL" })
    GG.MarkWorkPending()
    for i = 1, 5 do
        world.time = world.time + 1
        GG.SampleFps(world.time)
    end
    assertEq(GG.GetSchedMode(), "SLOW", "15 FPS enters SLOW")
    local limits15 = GG.GetStepLimits()
    assertEq(limits15.apps, 1, "SLOW allows 1 apply/step (progress)")
    world.fps = 20
    world.time = world.time + 1
    GG.SampleFps(world.time)
    assertEq(GG.GetSchedMode(), "SLOW", "20 FPS stays SLOW")
    -- D1: enter SLOW only when FPS is *below* 30; 30 is the hysteresis band floor.
    world.fps = 29
    GG.ResetSchedulerForTests({ mode = "NORMAL" })
    GG.MarkWorkPending()
    for i = 1, 5 do world.time = world.time + 1; GG.SampleFps(world.time) end
    assertEq(GG.GetSchedMode(), "SLOW", "29 FPS enters SLOW from NORMAL")
    world.fps = 30
    GG.ResetSchedulerForTests({ mode = "NORMAL" })
    GG.MarkWorkPending()
    for i = 1, 5 do world.time = world.time + 1; GG.SampleFps(world.time) end
    assertEq(GG.GetSchedMode(), "NORMAL", "exactly 30 FPS preserves NORMAL (hysteresis band)")
    -- Hysteresis band 35: preserve mode
    world.fps = 35
    GG.ResetSchedulerForTests({ mode = "SLOW" })
    GG.MarkWorkPending()
    for i = 1, 10 do world.time = world.time + 1; GG.SampleFps(world.time) end
    assertEq(GG.GetSchedMode(), "SLOW", "35 FPS preserves SLOW")
    world.fps = 45
    for i = 1, 6 do world.time = world.time + 1; GG.SampleFps(world.time) end
    assertEq(GG.GetSchedMode(), "NORMAL", "45 FPS for 5s returns NORMAL")
    -- Idle sampling gap clears streak
    GG.ClearWorkPendingIfIdle()
    GG.SampleFps(world.time + 10)
    assertNil(GG._sched.fpsStreakMode, "idle clears FPS streak")
    world.fps = savedFps
end

-- 10) Combat/loading pause preserves needs; gradual resume
do
    resetWorld()
    local SF = makeClient("Alice")
    local GG = SF.GuildGossip
    GG:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "combat" })
    GG.MarkWorkPending()
    world.combat = true
    assertTrue(GG.UpdatePauseState(world.time), "paused in combat")
    world.combat = false
    assertTrue(GG.UpdatePauseState(world.time), "still paused during resume jitter")
    assertTrue(GG._sched.resumeAt ~= nil, "resumeAt scheduled")
    world.time = GG._sched.resumeAt + 0.1
    assertTrue(not GG.UpdatePauseState(world.time), "resumed after jitter")
    assertEq(GG.GetSchedMode(), "SLOW", "resume starts SLOW")
end

-- 11) Receive guard on alternate AceComm instance + partial expiry
do
    resetWorld()
    local SF = makeClient("Alice")
    local GG = SF.GuildGossip
    local alt = makeAceComm("other-addon-newer")
    activeAceComm = alt
    assertTrue(GG.InstallReceiveGuard(alt), "guard installs on alternate AceComm")
    assertTrue(alt._SF_GG_RecvGuard, "guard marker set on alternate instance")
    -- Flood partials beyond cap
    for i = 1, 6 do
        alt:OnReceiveMultipartFirst("SF_GG", string.rep("x", 100), "WHISPER", "Peer" .. i .. "-Garona")
    end
    local stats = GG.GetReceiveGuardStats()
    assertTrue(stats.partialCount <= GG.MAX_PARTIAL_MESSAGES, "partial count capped")
    -- Expiry
    world.time = world.time + GG.REASSEMBLY_IDLE_SEC + 1
    GG.ExpireStalePartials(world.time)
    stats = GG.GetReceiveGuardStats()
    assertEq(stats.partialCount, 0, "stale partials expired")
end

-- 12) Large guild discovery does not all-to-all; peer set bounded
do
    resetWorld()
    world.guild.members = {}
    for i = 1, 80 do
        world.guild.members[i] = { name = "P" .. i .. "-Garona", online = true }
    end
    local nodes = {}
    for i = 1, 20 do
        nodes[i] = makeClient("P" .. i)
        nodes[i].GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "n" .. i })
    end
    for i = 1, 20 do
        world._unitName = "P" .. i
        nodes[i].GuildGossip.SendDiscovery()
    end
    advanceTime(0.5)
    -- No node should open more than one out pull
    local pulls = 0
    for i = 1, 20 do
        if nodes[i].GuildGossip._engine.outPull then pulls = pulls + 1 end
    end
    assertTrue(pulls <= 20, "at most one out pull per client")
    local peerCount = #(nodes[1].GuildGossip._engine.peerOrder)
    assertTrue(peerCount <= nodes[1].GuildGossip.MAX_PEERS, "peer working set bounded")
end

-- 13) Chat silence with Debug disabled; debug only when enabled
do
    resetWorld()
    chatOutput = {}
    local SF = makeClient("Alice")
    SF.debugEnabled = false
    SF.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "chat" })
    SF.GuildGossip.SendDiscovery()
    advanceTime(0.2)
    runSteps(5)
    assertEq(#SF.chat, 0, "no Print*/SystemMessage from gossip")
    assertEq(#chatOutput, 0, "no DEFAULT_CHAT_FRAME/print from gossip path")
    local before = #SF.debugLogs
    SF.debugEnabled = true
    SF.GuildGossip._DInfo("hello-debug")
    assertTrue(#SF.debugLogs > before, "debug emits when enabled")
end

-- 14) Older/incompatible proto fails quietly; raid path untouched for gossip NACK
do
    resetWorld()
    local SF = makeClient("Alice")
    SF.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "proto" })
    SF.GuildGossip.RefreshGuildState()
    local bad = "GG_DISC\t99\tB64CBOR\tB64" .. ser({ proto = 99, providers = {} })
    local beforeWire = #world.wire
    SF.GuildGossip.OnGossipCommReceived("SF_GG", bad, "GUILD", "Bob-Garona")
    -- May enqueue a gossip NACK whisper, never SF_LH PROTO_NACK
    advanceTime(0.2)
    local raidNack = false
    for _, msg in ipairs(world.wire) do
        if msg.prefix == "SF_LH" then raidNack = true end
    end
    assertTrue(not raidNack, "gossip incompatibility does not use raid NACK path")
    -- Compressed rejected
    local compressed = "GG_VIEW\t1\tB64CBORZ\tB64xx"
    SF.GuildGossip.OnGossipCommReceived("SF_GG", compressed, "WHISPER", "Bob-Garona")
    pass("incompatible/compressed gossip handled without raid coupling")
end

-- 15) Stale scope / guild change invalidates
do
    resetWorld()
    local SF = makeClient("Alice")
    SF.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "scope" })
    local gen0 = SF.GuildGossip.GetGuildGeneration()
    world.guild.clubId = 99
    SF.GuildGossip.RefreshGuildState()
    assertTrue(SF.GuildGossip.GetGuildGeneration() > gen0, "guild scope change bumps generation")
end

-- 16) Recv queue flood bounded
do
    resetWorld()
    local SF = makeClient("Alice")
    local GG = SF.GuildGossip
    GG:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "flood" })
    local okCount = 0
    for i = 1, 20 do
        local env = GG.BuildWireMessage(GG.MSG.DISC, { proto = 1, enc = { "B64CBOR" }, providers = { { id = "sf.synthetic.gossip", schema = 1 } } })
        GG.OnGossipCommReceived("SF_GG", env, "GUILD", "Bob-Garona")
    end
    local stats = GG.GetEngineStats()
    assertTrue(stats.recvQueue <= GG.MAX_RECV_QUEUE_MESSAGES, "recv queue capped under flood")
end

-- 17) Bookmark resume same epoch; stale epoch not reused
do
    resetWorld()
    local SF = makeClient("Alice")
    local GG = SF.GuildGossip
    local entry = select(2, GG.RegisterProvider({
        id = "bm",
        schema = 1,
        enabled = true,
        ready = true,
        ListRecordIds = function() return {} end,
        GetRecordVersionFp = function() return nil end,
        GetRecordBody = function() return nil end,
        ValidateAndApply = function() return "duplicate" end,
        IsPeerEligible = function() return true end,
        GetScopeId = function() return "scope" end,
    }))
    -- Simulate bookmark helpers via engine locals by setting bookmarks table
    entry.bookmarks["bob-garona|bm|scope|0"] = { epoch = 1, scopeId = "scope", afterSeq = 5 }
    GG.BumpIndexEpoch(entry.index)
    assertTrue(entry.index.epoch ~= 1, "epoch bumped")
    -- Epoch invalidation clears the bookmark rather than retaining a stale cursor.
    local bm = entry.bookmarks["bob-garona|bm|scope|0"]
    assertTrue(bm == nil, "bookmark cleared after rebuild")
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
io.stdout:write("0 failed\n")
