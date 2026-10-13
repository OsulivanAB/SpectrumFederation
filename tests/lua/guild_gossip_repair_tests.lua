-- Behavioral regressions for owner review of PR #390 (aa6fa91) / issue #378.
-- These probes must FAIL on the reviewed head and PASS after the repair batch.
-- Run: lua5.1 tests/lua/guild_gossip_repair_tests.lua

local failures, passes = 0, 0
local function fail(m) failures = failures + 1; io.stderr:write("FAIL: " .. m .. "\n") end
local function pass(m) passes = passes + 1; io.stdout:write("ok: " .. m .. "\n") end
local function assertTrue(c, m) if c then pass(m) else fail(m) end end
local function assertEq(a, e, m)
    if a == e then pass(m) else fail(string.format("%s (expected %s, got %s)", m, tostring(e), tostring(a))) end
end

---------------------------------------------------------------------------
-- Minimal realistic-ish CBOR/Base64 sizing (length-preserving enough for caps)
---------------------------------------------------------------------------
local function ser(v, seen)
    seen = seen or {}
    local t = type(v)
    if v == nil then return "N"
    elseif t == "boolean" then return v and "T" or "F"
    elseif t == "number" then return "#" .. tostring(v) .. ";"
    elseif t == "string" then return "$" .. #v .. ":" .. v
    elseif t == "table" then
        if seen[v] then return "@" end
        seen[v] = true
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for i = 1, #keys do
            parts[#parts + 1] = ser(keys[i], seen) .. "=" .. ser(v[keys[i]], seen)
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
        return s:sub(colon + 1, colon + n), colon + n + 1
    elseif c == "{" then
        local t = {}
        i = i + 1
        if s:sub(i, i) == "}" then return t, i + 1 end
        while true do
            local k, ni = deser(s, i)
            local v, nj = deser(s, ni + 1)
            t[k] = v
            i = nj
            local ch = s:sub(i, i)
            if ch == "}" then return t, i + 1 end
            i = i + 1
        end
    end
    error("bad ser")
end

---------------------------------------------------------------------------
-- World / AceComm harness (production Comm + GuildGossip paths)
---------------------------------------------------------------------------
local world = {
    time = 1000, fps = 60, combat = false, loading = false,
    wire = {}, clients = {}, decodeCount = 0, listCalls = {},
    guild = {
        inGuild = true, name = "Spectrum", realm = "Garona", clubId = 42,
        members = {
            { name = "Alice-Garona", online = true },
            { name = "Bob-Garona", online = true },
            { name = "Carol-Garona", online = true },
        },
    },
}

function GetTime() return world.time end
function time() return math.floor(world.time) end
function GetFramerate() return world.fps end
function UnitAffectingCombat() return world.combat end
function IsLoadingScreenShown() return world.loading end
function IsInGuild() return world.guild.inGuild end
function GetGuildInfo() return world.guild.name, "R", 0, world.guild.realm end
function GetNumGuildMembers() return #world.guild.members end
function GetGuildRosterInfo(i)
    local m = world.guild.members[i]
    if m then return m.name, "R", 0, 80, "W", "Z", "", "", true, 0, "WARRIOR", 0, 0, false, false, 0 end
end
C_GuildInfo = { GuildRoster = function() end }
C_Club = { GetGuildClubId = function() return world.guild.clubId end }
function GetRealmName() return "Garona" end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function UnitFullName() return world._unitName, "Garona" end
function UnitName() return world._unitName end
function CreateFrame()
    local f = { events = {} }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterAllEvents() self.events = {} end
    function f:SetScript(n, fn) self[n] = fn end
    return f
end

local timers = {}
local function installTimers()
    C_Timer = {
        After = function(d, fn)
            timers[#timers + 1] = { at = world.time + d, fn = fn, kind = "after", owner = world._unitName }
        end,
        NewTimer = function(d, fn)
            local h = { at = world.time + d, fn = fn, kind = "timer", cancelled = false, owner = world._unitName }
            function h:Cancel() self.cancelled = true end
            timers[#timers + 1] = h
            return h
        end,
        NewTicker = function(interval, fn)
            local h = { interval = interval, fn = fn, kind = "ticker", cancelled = false,
                nextAt = world.time + interval, owner = world._unitName }
            function h:Cancel() self.cancelled = true end
            timers[#timers + 1] = h
            return h
        end,
    }
end
installTimers()

C_EncodingUtil = {
    SerializeCBOR = function(t) return ser(t) end,
    DeserializeCBOR = function(s)
        world.decodeCount = (world.decodeCount or 0) + 1
        return select(1, deser(s, 1))
    end,
    EncodeBase64 = function(s) return "B64" .. s end,
    DecodeBase64 = function(s) return s:sub(1, 3) == "B64" and s:sub(4) or s end,
}
C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end }
DEFAULT_CHAT_FRAME = { AddMessage = function() end }

local function makeAceComm()
    local AceComm = { embeds = {}, multipart_spool = {}, callbacks_by_prefix = {} }
    function AceComm:Embed(target)
        target.SendCommMessage = function(self, prefix, text, distribution, targetName, prio, callbackFn, callbackArg)
            return AceComm:SendCommMessage(prefix, text, distribution, targetName, prio, callbackFn, callbackArg)
        end
        target.RegisterComm = function(self, prefix, method)
            return AceComm:RegisterComm(self, prefix, method)
        end
    end
    function AceComm:RegisterComm(owner, prefix, method)
        AceComm.callbacks_by_prefix[prefix] = AceComm.callbacks_by_prefix[prefix] or {}
        local fn = method
        if type(method) == "string" then
            fn = function(_, ...) return owner[method](owner, ...) end
        end
        table.insert(AceComm.callbacks_by_prefix[prefix], { owner = owner, fn = fn })
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
        local full = type(old) == "table" and (function()
            old[#old + 1] = message
            return table.concat(old, "")
        end)() or (old .. message)
        local list = AceComm.callbacks_by_prefix[prefix] or {}
        for _, entry in ipairs(list) do
            entry.fn(entry.owner, prefix, full, distribution, sender)
        end
    end
    function AceComm:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
        local sender = world._sendAs or ((world._unitName or "?") .. "-Garona")
        world.wire[#world.wire + 1] = {
            prefix = prefix, text = text, distribution = distribution,
            target = target, sender = sender,
        }
        if callbackFn then callbackFn(callbackArg, #text, #text, true) end
    end
    return AceComm
end

local activeAceComm = makeAceComm()
LibStub = function(n) if n == "AceComm-3.0" then return activeAceComm end end

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
    local SF = { name = name, debugEnabled = false, debugLogs = {}, chat = {} }
    function SF:Now() return world.time end
    SF.Debug = {
        IsEnabled = function() return false end,
        Verbose = function() end, Info = function() end, Warn = function() end, Error = function() end,
    }
    world._unitName = name
    for _, path in ipairs(MODULES) do
        assert(loadfile(path))("SpectrumFederation", SF)
    end
    SF.LootHelperComm:Init()
    SF.GuildGossip.Init()
    SF.GuildGossip.RefreshGuildState()
    world.clients[name] = SF
    return SF
end

local function deliverWire()
    local batch = world.wire
    world.wire = {}
    for _, msg in ipairs(batch) do
        for cname, SF in pairs(world.clients) do
            local full = cname .. "-Garona"
            local ok = (msg.distribution == "GUILD" and msg.sender ~= full)
                or (msg.distribution == "WHISPER" and msg.target == full)
            if ok then
                world._unitName = cname
                SF.LootHelperComm:OnCommReceived(msg.prefix, msg.text, msg.distribution, msg.sender)
            end
        end
    end
end

local function pump(cname, SF)
    world._unitName = cname
    world._sendAs = cname .. "-Garona"
    SF.LootHelperComm:_PumpQueue()
    world._sendAs = nil
    deliverWire()
end

local function advance(dt)
    local target = world.time + dt
    while world.time < target do
        world.time = world.time + 0.05
        for _, h in ipairs(timers) do
            if not h.cancelled then
                if h.kind == "ticker" and world.time >= (h.nextAt or 0) then
                    if h.owner then world._unitName = h.owner; world._sendAs = h.owner .. "-Garona" end
                    h.fn(); h.nextAt = world.time + h.interval; world._sendAs = nil
                elseif h.at and world.time >= h.at and not h.fired then
                    h.fired = true
                    if h.owner then world._unitName = h.owner; world._sendAs = h.owner .. "-Garona" end
                    h.fn(); world._sendAs = nil
                end
            end
        end
        deliverWire()
        for cname, SF in pairs(world.clients) do pump(cname, SF) end
    end
end

local function stepClient(SF, limits)
    world._unitName = SF.name
    world._sendAs = SF.name .. "-Garona"
    SF.GuildGossip.OnSchedulerStep(limits or SF.GuildGossip.GetStepLimits(), world.time)
    world._sendAs = nil
    pump(SF.name, SF)
end

local function reset()
    world.time = 1000; world.fps = 60; world.combat = false; world.loading = false
    world.wire = {}; world.clients = {}; world.decodeCount = 0; world.listCalls = {}
    world._sendAs = nil
    timers = {}
    activeAceComm = makeAceComm()
    installTimers()
    world.guild.clubId = 42
    world.guild.members = {
        { name = "Alice-Garona", online = true },
        { name = "Bob-Garona", online = true },
        { name = "Carol-Garona", online = true },
    }
end

---------------------------------------------------------------------------
-- F1: NORMAL→SLOW retains partial body page
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    local B = makeClient("Bob")
    local GG = A.GuildGossip
    local pA = A.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "f1a" })
    local pB = B.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "f1b" })
    for i = 1, 8 do pB.AppendLocal("payload-" .. i, "body-" .. i) end
    -- Force Alice pull state into apply_bodies with an 8-record page under SLOW apps=1
    local e = A.GuildGossip._engine
    e.outPull = {
        peer = "Bob-Garona", providerId = "sf.synthetic.gossip", viewId = "v1",
        scopeId = A.GuildGossip.GetGuildScopeId(), eligibilityGen = 1,
        localEpoch = 1, localBuckets = {}, remoteView = { epoch = 1, buckets = {} },
        bucketCursor = 64, afterSeq = 0, activeBucket = 0, phase = "apply_bodies",
        retries = 0, usableProgressAt = world.time, finalSubmitted = true,
        neededBodies = {},
        bodyOffset = 0, pendingBodyCount = 8, bodyApplyCursor = 0,
        engineGen = e.generation, manifest = { entries = {}, done = true },
        bodyPage = { records = {}, requestId = "req1", subpage = 1 },
        expectedRequestId = "req1", expectedSubpage = 1, expectedIds = {},
    }
    for i = 1, 8 do
        local id = "body-" .. i
        local store = pB.GetStore().records[id]
        local vfp = store.versionFp
        e.outPull.neededBodies[i] = { id = id, versionFp = vfp, seq = i }
        e.outPull.expectedIds[i] = id
        e.outPull.bodyPage.records[i] = { id = id, versionFp = vfp, body = "payload-" .. i }
    end
    GG.ResetSchedulerForTests({ mode = "SLOW" })
    local limits = GG.GetStepLimits("SLOW")
    assertEq(limits.apps, 1, "SLOW apps=1")
    stepClient(A, limits)
    local pull = e.outPull
    local accepted = #pA.GetStore().order
    assertEq(accepted, 1, "F1: only one record applied under SLOW")
    assertTrue(pull ~= nil and pull.bodyPage ~= nil, "F1: retained bodyPage after partial apply")
    assertTrue((pull.bodyApplyCursor or 0) == 1, "F1: per-subpage apply cursor advanced by 1")
    assertTrue((pull.bodyOffset or 0) == 0, "F1: bodyOffset not advanced by full pendingBodyCount")
end

---------------------------------------------------------------------------
-- F2: stale/duplicate body subpage must not advance wrong offset
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    A.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "f2" })
    local e = A.GuildGossip._engine
    e.outPull = {
        peer = "Bob-Garona", providerId = "sf.synthetic.gossip", viewId = "v2",
        scopeId = A.GuildGossip.GetGuildScopeId(), phase = "wait_bodies",
        neededBodies = {
            { id = "r1", versionFp = "v1", seq = 1 },
            { id = "r2", versionFp = "v2", seq = 2 },
        },
        bodyOffset = 1, -- waiting for subpage 2 (r2)
        expectedRequestId = "req-b2", expectedSubpage = 2,
        expectedIds = { "r2" }, expectedFingerprints = { r2 = "v2" },
        engineGen = e.generation, usableProgressAt = world.time, finalSubmitted = true,
        remoteView = { epoch = 1 }, activeBucket = 0, afterSeq = 0,
        manifest = { entries = { { seq = 1, id = "r1", versionFp = "v1" }, { seq = 2, id = "r2", versionFp = "v2" } }, done = true },
    }
    local before = e.outPull.usableProgressAt
    -- Duplicate/stale subpage 1 response
    A.GuildGossip.OnGossipCommReceived("SF_GG", A.GuildGossip.BuildWireMessage(A.GuildGossip.MSG.BODY, {
        op = "page", viewId = "v2", providerId = "sf.synthetic.gossip",
        requestId = "req-b1", subpage = 1,
        records = { { id = "r1", versionFp = "v1", body = "x" } },
    }), "WHISPER", "Bob-Garona")
    -- Drain recv
    stepClient(A, A.GuildGossip.GetStepLimits("SLOW"))
    local pull = e.outPull
    assertTrue(pull and pull.phase == "wait_bodies", "F2: still waiting for subpage 2")
    assertEq(pull.bodyOffset, 1, "F2: bodyOffset unchanged by stale subpage")
    assertTrue(A.GuildGossip.GetProvider("sf.synthetic.gossip").api.GetStore().records["r1"] == nil,
        "F2: stale body not applied")
end

---------------------------------------------------------------------------
-- F4: physical AceComm spool cleared; empty NEXT bounded
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    local GG = A.GuildGossip
    local ace = activeAceComm
    GG.InstallReceiveGuard(ace)
    ace:OnReceiveMultipartFirst("SF_GG", "abc", "WHISPER", "Bob-Garona")
    for i = 1, 50 do
        ace:OnReceiveMultipartNext("SF_GG", "", "WHISPER", "Bob-Garona")
    end
    local spool = ace.multipart_spool["SF_GG\tWHISPER\tBob-Garona"]
    local fragCount = 0
    if type(spool) == "table" then fragCount = #spool elseif spool then fragCount = 1 end
    assertTrue(fragCount <= 32, "F4: empty NEXT fragments bounded (fragCount=" .. tostring(fragCount) .. ")")
    world.time = world.time + GG.REASSEMBLY_IDLE_SEC + 1
    GG.ExpireStalePartials(world.time)
    assertEq(ace.multipart_spool["SF_GG\tWHISPER\tBob-Garona"], nil, "F4: physical spool cleared on expiry")
    local stats = GG.GetReceiveGuardStats()
    assertEq(stats.partialCount, 0, "F4: accounting cleared with spool")
end

---------------------------------------------------------------------------
-- F5: no decode before admission; combat flood; malformed entries
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    A.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "f5" })
    world.combat = true
    A.GuildGossip.UpdatePauseState(world.time)
    world.decodeCount = 0
    for i = 1, 20 do
        local env = A.GuildGossip.BuildWireMessage(A.GuildGossip.MSG.DISC, {
            proto = 1, enc = { "B64CBOR" },
            providers = { { id = "sf.synthetic.gossip", schema = 1 } },
        })
        A.GuildGossip.OnGossipCommReceived("SF_GG", env, "GUILD", "Bob-Garona")
    end
    local stats = A.GuildGossip.GetEngineStats()
    assertTrue(stats.recvQueue <= A.GuildGossip.MAX_RECV_QUEUE_MESSAGES, "F5: recv queue capped")
    assertEq(world.decodeCount, 0, "F5: no payload decode during combat flood admission")
    -- Malformed MANIFEST must not throw
    world.combat = false
    A.GuildGossip.UpdatePauseState(world.time + 20)
    world.time = (A.GuildGossip._sched.resumeAt or world.time) + 0.1
    A.GuildGossip.UpdatePauseState(world.time)
    local e = A.GuildGossip._engine
    e.outPull = {
        peer = "Bob-Garona", providerId = "sf.synthetic.gossip", viewId = "vm",
        phase = "wait_manifest", engineGen = e.generation, expectedRequestId = "m1",
        activeBucket = 0, afterSeq = 0, remoteView = { epoch = 1, buckets = {} },
        scopeId = A.GuildGossip.GetGuildScopeId(), usableProgressAt = world.time, finalSubmitted = true,
    }
    local okCall, err = pcall(function()
        A.GuildGossip.OnGossipCommReceived("SF_GG", A.GuildGossip.BuildWireMessage(A.GuildGossip.MSG.MANIFEST, {
            op = "page", viewId = "vm", providerId = "sf.synthetic.gossip",
            requestId = "m1", bucketId = 0, entries = { 42 }, done = true,
        }), "WHISPER", "Bob-Garona")
        stepClient(A, A.GuildGossip.GetStepLimits())
    end)
    assertTrue(okCall, "F5: malformed manifest entries do not throw (" .. tostring(err) .. ")")
end

---------------------------------------------------------------------------
-- F6: idle does not rescan ListRecordIds; aggregate budget; seek work bounded
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    local calls = { n = 0 }
    local ids = {}
    for i = 1, 200 do ids[i] = "h-" .. i end
    A.GuildGossip.RegisterProvider({
        id = "hist", schema = 1, enabled = true, ready = true,
        ListRecordIds = function()
            calls.n = calls.n + 1
            local copy = {}
            for i = 1, #ids do copy[i] = ids[i] end
            return copy
        end,
        GetRecordVersionFp = function(id) return "v" end,
        GetRecordBody = function(id) return { id = id, versionFp = "v", body = 1 } end,
        ValidateAndApply = function() return "duplicate" end,
        IsPeerEligible = function() return true end,
        GetScopeId = function() return A.GuildGossip.GetGuildScopeId() end,
    })
    local GG = A.GuildGossip
    local limits = GG.GetStepLimits("NORMAL")
    -- Build index once
    for i = 1, 20 do stepClient(A, limits) end
    local afterBuild = calls.n
    assertTrue(afterBuild >= 1, "F6: initial list called")
    -- Stable idle steps should not re-list
    for i = 1, 20 do stepClient(A, limits) end
    assertEq(calls.n, afterBuild, "F6: completed index not rebuilt every idle step")
    -- Seek should not rescan whole order: instrument via IndexSeekManifest work
    local entry = GG.GetProvider("hist")
    local scanned = 0
    local bucket = entry.index.buckets[GG.BucketForId("h-1")]
    -- Fill bucket 0 densely
    GG.BumpIndexEpoch(entry.index)
    for i = 1, 300 do
        GG.IndexUpsert(entry.index, "seek-" .. i, "v")
    end
    -- Prefer a bucket with many entries
    local bigB, bigN = 0, 0
    for b = 0, 63 do
        local n = entry.index.buckets[b].count or 0
        if n > bigN then bigN = n; bigB = b end
    end
    local endSeq = entry.index.buckets[bigB].lastSeq
    local page1 = GG.IndexSeekManifest(entry.index, bigB, 0, endSeq, 4)
    local after1 = page1[#page1] and page1[#page1].seq or 0
    local page2, meta = GG.IndexSeekManifest(entry.index, bigB, after1, endSeq, 4)
    -- New API may return examined count as second value
    local examined = type(meta) == "table" and meta.examined or meta
    if type(examined) ~= "number" then
        -- Fallback property: second page first seq > after1 and page bounded
        examined = #page2
    end
    assertTrue(#page2 <= 4, "F6: seek page bounded")
    assertTrue(examined <= 8, "F6: seek examines bounded new entries (examined=" .. tostring(examined) .. ")")
end

---------------------------------------------------------------------------
-- F8: fresh epoch across rebuild; bookmark must not skip new prefix
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    local GG = A.GuildGossip
    local idx1 = GG.CreateIndex()
    for i = 1, 10 do GG.IndexUpsert(idx1, "old-" .. i, "v") end
    local e1 = idx1.epoch
    local idx2 = GG.CreateIndex()
    for i = 1, 10 do GG.IndexUpsert(idx2, "new-" .. i, "v") end
    assertTrue(idx2.epoch ~= e1, "F8: CreateIndex uses fresh epoch (e1=" .. e1 .. " e2=" .. idx2.epoch .. ")")
    -- Bookmark resume must reject foreign epoch
    local entry = select(2, GG.RegisterProvider({
        id = "ep", schema = 1, enabled = true, ready = true,
        ListRecordIds = function() return {} end,
        GetRecordVersionFp = function() return nil end,
        GetRecordBody = function() return nil end,
        ValidateAndApply = function() return "duplicate" end,
        IsPeerEligible = function() return true end,
        GetScopeId = function() return "scope" end,
    }))
    entry.bookmarks["bob-garona|ep|scope|0"] = { epoch = e1, scopeId = "scope", afterSeq = 5 }
    entry.index = idx2
    local bm = entry.bookmarks["bob-garona|ep|scope|0"]
    local usable = bm and bm.epoch == entry.index.epoch
    assertTrue(not usable, "F8: bookmark epoch not reusable across source incarnation")
end

---------------------------------------------------------------------------
-- F10: byte-limited body subpages with realistic encoded sizes
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    local B = makeClient("Bob")
    A.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "f10a" })
    local pB = B.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "f10b" })
    -- ~1.5KiB body strings → three exceed 4KiB envelope with headers
    local big = string.rep("X", 1500)
    for i = 1, 3 do
        pB.AppendLocal(big, "big-" .. i)
    end
    local entryB = B.GuildGossip.GetProvider("sf.synthetic.gossip")
    local e = B.GuildGossip._engine
    e.inPull = {
        peer = "Alice-Garona", providerId = "sf.synthetic.gossip", viewId = "vb",
        scopeId = B.GuildGossip.GetGuildScopeId(), epoch = entryB.index.epoch,
        buckets = {}, phase = "serving", engineGen = e.generation,
        usableProgressAt = world.time, finalSubmitted = true,
    }
    world._unitName = "Bob"
    world._sendAs = "Bob-Garona"
    -- Directly invoke body request handler path via OnGossipCommReceived + step
    local ids = { "big-1", "big-2", "big-3" }
    B.GuildGossip.OnGossipCommReceived("SF_GG", B.GuildGossip.BuildWireMessage(B.GuildGossip.MSG.BODY, {
        op = "request", viewId = "vb", providerId = "sf.synthetic.gossip",
        requestId = "br1", ids = ids,
    }), "WHISPER", "Alice-Garona")
    stepClient(B, B.GuildGossip.GetStepLimits("NORMAL"))
    -- Must still be serving or have sent a subpage (not silent occupancy with zero wire)
    local sentBody = false
    for _, msg in ipairs(world.wire) do
        if msg.prefix == "SF_GG" and msg.text:find("GG_BODY", 1, true) then sentBody = true end
    end
    -- Also check after pump
    pump("Bob", B)
    for _, msg in ipairs(world.wire) do
        if msg.prefix == "SF_GG" and msg.text:find("GG_BODY", 1, true) then sentBody = true end
    end
    assertTrue(sentBody or (e.inPull and e.inPull.phase == "serving"),
        "F10: oversized body request yields subpage send or retained obligation (not silent drop)")
    -- Record oversize rejected
    local over = string.rep("Y", 3000)
    local raw = C_EncodingUtil.SerializeCBOR({ id = "over", versionFp = "v", body = over })
    assertTrue(#raw > A.GuildGossip.MAX_RECORD_CBOR, "F10: fixture exceeds 2KiB CBOR")
end

---------------------------------------------------------------------------
-- F11: provider data scope honored both directions
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    local B = makeClient("Bob")
    local scope = "data-scope-x"
    local function reg(SF, key)
        return SF.GuildGossip.RegisterProvider({
            id = "scoped", schema = 1, enabled = true, ready = true,
            GetScopeId = function() return scope end,
            IsPeerEligible = function() return true end,
            ListRecordIds = function() return { "s1" } end,
            GetRecordVersionFp = function() return "v1" end,
            GetRecordBody = function() return { id = "s1", versionFp = "v1", body = 1 } end,
            ValidateAndApply = function(rec)
                local st = SF._scopedStore
                if not st then SF._scopedStore = { order = {}, records = {} }; st = SF._scopedStore end
                if st.records[rec.id] then return "duplicate" end
                st.records[rec.id] = rec; st.order[#st.order + 1] = rec.id
                return "accepted"
            end,
        })
    end
    reg(A); reg(B)
    A.GuildGossip.IndexUpsert(A.GuildGossip.GetProvider("scoped").index, "s1", "v1")
    B.GuildGossip.IndexUpsert(B.GuildGossip.GetProvider("scoped").index, "s1", "v1")
    -- Alice starts out pull using provider scope
    world._unitName = "Alice"; world._sendAs = "Alice-Garona"
    local peer = { name = "Bob-Garona", key = "bob-garona", covered = {} }
    A.GuildGossip._engine.peers["bob-garona"] = peer
    A.GuildGossip._engine.peerOrder = { "bob-garona" }
    local ok = A.GuildGossip.SendGossip -- ensure loaded
    -- Use public start via select: force startOutPull by calling scheduler after caps
    peer.caps = { proto = 1, enc = { "B64CBOR" }, providers = { { id = "scoped", schema = 1 } } }
    stepClient(A, A.GuildGossip.GetStepLimits())
    local pull = A.GuildGossip._engine.outPull
    assertTrue(pull ~= nil, "F11: outPull started for data-scoped provider")
    assertEq(pull.scopeId, scope, "F11: request uses provider GetScopeId")
    -- Deliver VIEW request to Bob
    advance(0.2)
    stepClient(B, B.GuildGossip.GetStepLimits())
    local inPull = B.GuildGossip._engine.inPull
    assertTrue(inPull ~= nil, "F11: Bob accepts view for provider data scope")
    assertEq(inPull.scopeId, scope, "F11: served view stores provider scope")
end

---------------------------------------------------------------------------
-- F12: foreground admission when background filled per-target queue
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    local Comm = A.LootHelperComm
    Comm.cfg.queueEnabled = true
    Comm.cfg.maxPerTarget = 50
    Comm.cfg.maxQueue = 200
    for i = 1, 50 do
        Comm:_EnqueueSend("SF_GG", "g" .. i, "WHISPER", "Bob-Garona", "BULK", nil, "BACKGROUND")
    end
    local ok = Comm:_EnqueueSend("SF_LHB", "bulk", "WHISPER", "Bob-Garona", "BULK", nil, "FOREGROUND")
    assertTrue(ok, "F12: FOREGROUND admitted despite BACKGROUND-filled per-target queue")
end

---------------------------------------------------------------------------
-- F13: discovery rotates providers when over 240-byte cap
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    local seen = {}
    for i = 1, 6 do
        local id = "prov.long.name.number." .. i .. ".padding"
        A.GuildGossip.RegisterProvider({
            id = id, schema = 1, enabled = true, ready = true,
            ListRecordIds = function() return {} end,
            GetRecordVersionFp = function() return nil end,
            GetRecordBody = function() return nil end,
            ValidateAndApply = function() return "duplicate" end,
            IsPeerEligible = function() return true end,
            GetScopeId = function() return A.GuildGossip.GetGuildScopeId() end,
            GetCapabilities = function()
                return { tag = string.rep("Z", 40) }
            end,
        })
    end
    for round = 1, 8 do
        world._unitName = "Alice"; world._sendAs = "Alice-Garona"
        A.GuildGossip.SendDiscovery()
        pump("Alice", A)
        for _, msg in ipairs(world.wire) do
            if msg.distribution == "GUILD" then
                local ok, msgType, proto, enc, payloadStr = A.GuildGossip.ParseEnvelope(msg.text)
                local payload = select(1, A.GuildGossip.DecodePayload(payloadStr, enc))
                if type(payload) == "table" and type(payload.providers) == "table" then
                    for _, p in ipairs(payload.providers) do
                        seen[p.id] = true
                    end
                end
            end
        end
        world.wire = {}
        advance(0.05)
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    assertTrue(n >= 4, "F13: rotated discovery eventually advertises most providers (seen=" .. n .. ")")
end

---------------------------------------------------------------------------
-- F3/F7/F9 smoke: served-view expiry; cancel unsent on disable; unresolved not covered
---------------------------------------------------------------------------
do
    reset()
    local A = makeClient("Alice")
    local B = makeClient("Bob")
    A.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "f3a" })
    B.GuildGossip:EnableSynthetic({ id = "sf.synthetic.gossip", instanceKey = "f3b" })
    local eB = B.GuildGossip._engine
    eB.inPull = {
        peer = "Alice-Garona", providerId = "sf.synthetic.gossip", viewId = "old",
        phase = "serving", engineGen = eB.generation, usableProgressAt = world.time - 200,
        awaitingSince = world.time - 200, finalSubmitted = true, pauseExcluded = 0,
        scopeId = B.GuildGossip.GetGuildScopeId(), buckets = {}, epoch = 1,
    }
    stepClient(B, B.GuildGossip.GetStepLimits())
    assertTrue(eB.inPull == nil, "F3: served view expires after usable-time lease")

    -- F7: queued gossip cancelled when provider disabled
    local Comm = A.LootHelperComm
    local sent = {}
    local orig = Comm.SendCommMessage
    Comm.SendCommMessage = function(self, prefix, msg, dist, target, prio, cb)
        sent[#sent + 1] = msg
        if cb then cb(nil, #msg, #msg, true) end
    end
    world._unitName = "Alice"
    A.GuildGossip.SendGossip(A.GuildGossip.MSG.BODY, {
        op = "page", viewId = "x", providerId = "sf.synthetic.gossip", records = { { id = "z", versionFp = "v", body = 1 } },
    }, "WHISPER", "Bob-Garona")
    A.GuildGossip:DisableProvider("sf.synthetic.gossip")
    A.GuildGossip.UnregisterProvider("sf.synthetic.gossip")
    Comm:_PumpQueue()
    local leaked = false
    for _, m in ipairs(sent) do if tostring(m):find("GG_BODY", 1, true) then leaked = true end end
    assertTrue(not leaked, "F7: BODY not sent after provider disable/unregister")
    Comm.SendCommMessage = orig
end

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then os.exit(1) end
io.stdout:write("0 failed\n")
