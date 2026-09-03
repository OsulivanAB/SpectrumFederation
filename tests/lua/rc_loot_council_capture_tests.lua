-- Production-Lua tests for SpectrumFederation_RCLootCouncilCapture/Capture.lua
-- Run from the repository root: lua5.1 tests/lua/rc_loot_council_capture_tests.lua

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
    if cond then
        pass(message)
    else
        fail(message)
    end
end

local function assertFalse(cond, message)
    assertTrue(not cond, message)
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local function resetGlobals()
    _G.SpectrumFederationRCLootCouncilCaptureDB = nil
    _G.SpectrumFederation = nil
    _G.LibStub = nil
    _G.hooksecurefunc = nil
    _G.GetServerTime = function()
        return 1700000000
    end
    _G.GetTime = function()
        return 12.5
    end
    _G.time = function()
        return 1700000000
    end
end

local function loadCapture()
    resetGlobals()
    local ns = {}
    local chunk = assert(loadfile("SpectrumFederation_RCLootCouncilCapture/Capture.lua"))
    chunk("SpectrumFederation_RCLootCouncilCapture", ns)
    return ns.RCLootCouncilCapture
end

-- ---------------------------------------------------------------------------
-- Database preserve / monotonic sequence / append-only
-- ---------------------------------------------------------------------------

local Capture = loadCapture()

local existing = {
    schemaVersion = 1,
    nextSequence = 4,
    entries = {
        { kind = "capture_start", sequence = 1, timestamp = 100 },
        { kind = "message", sequence = 2, timestamp = 101, raw = "one" },
        { kind = "message", sequence = 3, timestamp = 102, raw = "two" },
    },
}

local db = Capture.EnsureDatabase(existing)
assertTrue(db == existing, "EnsureDatabase reuses the existing table")
assertEq(db.nextSequence, 4, "valid nextSequence is preserved")
assertEq(#db.entries, 3, "existing entries are preserved")
assertEq(db.entries[1].raw, nil, "first marker remains first")
assertEq(db.entries[2].raw, "one", "first message remains second")

local appended = Capture.AppendEntry(db, { kind = "message", raw = "three" })
assertEq(appended.sequence, 4, "new entry uses current nextSequence")
assertEq(db.nextSequence, 5, "nextSequence increments after append")
assertEq(#db.entries, 4, "append grows history")
assertEq(db.entries[2].raw, "one", "older entries are not replaced")
assertEq(db.entries[4].raw, "three", "new entry is appended")

for i = 1, 10 do
    Capture.AppendEntry(db, { kind = "message", raw = "bulk-" .. i })
end
assertEq(#db.entries, 14, "history is not capped or pruned")
assertEq(db.entries[1].sequence, 1, "first historical sequence remains 1")
assertEq(db.nextSequence, 15, "nextSequence stays monotonic after many appends")

local recovered = Capture.EnsureDatabase({
    entries = {
        { kind = "message", sequence = 8 },
        { kind = "message", sequence = 11 },
    },
    nextSequence = "nope",
})
assertEq(recovered.nextSequence, 12, "malformed nextSequence recovers from max historical sequence")
assertEq(#recovered.entries, 2, "recoverable entries survive malformed nextSequence")

local fresh = Capture.EnsureDatabase("not-a-table")
assertEq(type(fresh), "table", "non-table database is replaced with a new table")
assertEq(fresh.nextSequence, 1, "replacement database starts at sequence 1")
assertEq(#fresh.entries, 0, "replacement database has empty entries")

-- ---------------------------------------------------------------------------
-- Listener registration is session-gated and idempotent
-- ---------------------------------------------------------------------------

Capture = loadCapture()

local registerCalls = {}
local unregisterCalls = 0
local aceComm = {
    Embed = function(_, target)
        function target:RegisterComm(prefix, method)
            registerCalls[#registerCalls + 1] = { prefix = prefix, method = method }
        end
        function target:UnregisterAllComm()
            unregisterCalls = unregisterCalls + 1
        end
    end,
}

_G.LibStub = function(name)
    if name == "AceComm-3.0" then
        return aceComm
    end
    return nil
end

_G.SpectrumFederation = {
    LootHelperSync = {
        state = { active = false },
        IsSessionActive = function(self)
            return self.state.active == true
        end,
        GetSessionId = function(self)
            return self.state.active and self.state.sessionId or nil
        end,
        GetSessionProfileId = function(self)
            return self.state.active and self.state.profileId or nil
        end,
        GetCoordinator = function(self)
            return self.state.active and self.state.coordinator or nil
        end,
    },
}

assertEq(Capture.ReconcileListener("boot"), "already_inactive", "inactive session does not start capture")
assertFalse(Capture.IsListenerRegistered(), "listener stays unregistered without a session")
assertEq(#registerCalls, 0, "no AceComm registrations while inactive")

_G.SpectrumFederation.LootHelperSync.state = {
    active = true,
    sessionId = "SES-1",
    profileId = "P1",
    coordinator = "Admin-Realm",
}
assertEq(Capture.ReconcileListener("StartSession"), "started", "active session starts capture")
assertTrue(Capture.IsListenerRegistered(), "listener registers when session becomes active")
assertEq(#registerCalls, 3, "all verified RC prefixes are registered once")
assertEq(registerCalls[1].prefix, "RCLC", "registers RCLC")
assertEq(registerCalls[2].prefix, "RCLCv", "registers RCLCv")
assertEq(registerCalls[3].prefix, "RCLCs", "registers RCLCs")

local firstStartCount = 0
local dbAfterStart = Capture.GetDatabase()
for i = 1, #dbAfterStart.entries do
    if dbAfterStart.entries[i].kind == "capture_start" then
        firstStartCount = firstStartCount + 1
    end
end
assertEq(firstStartCount, 1, "first activation writes one capture_start marker")

assertEq(Capture.ReconcileListener("StartSession"), "already_active", "duplicate activation is idempotent")
assertEq(#registerCalls, 3, "duplicate activation does not register again")
firstStartCount = 0
dbAfterStart = Capture.GetDatabase()
for i = 1, #dbAfterStart.entries do
    if dbAfterStart.entries[i].kind == "capture_start" then
        firstStartCount = firstStartCount + 1
    end
end
assertEq(firstStartCount, 1, "duplicate activation does not add another start marker")

local counts = Capture.GetRegisterCounts()
assertEq(counts.RCLC, 1, "RCLC registered once")
assertEq(counts.RCLCv, 1, "RCLCv registered once")
assertEq(counts.RCLCs, 1, "RCLCs registered once")

-- ---------------------------------------------------------------------------
-- Restore / remote activation use the same reconcile path
-- ---------------------------------------------------------------------------

Capture = loadCapture()
registerCalls = {}
unregisterCalls = 0
_G.LibStub = function(name)
    if name == "AceComm-3.0" then
        return aceComm
    end
    return nil
end
_G.SpectrumFederation = {
    LootHelperSync = {
        state = { active = false },
        IsSessionActive = function(self)
            return self.state.active == true
        end,
        GetSessionId = function(self)
            return self.state.sessionId
        end,
        GetSessionProfileId = function(self)
            return self.state.profileId
        end,
        GetCoordinator = function(self)
            return self.state.coordinator
        end,
        TryRestorePersistedSession = function(self)
            self.state.active = true
            self.state.sessionId = "SES-RESTORE"
            self.state.profileId = "P-RESTORE"
            self.state.coordinator = "Coord-Realm"
        end,
        HandleSessionStart = function(self)
            self.state.active = true
            self.state.sessionId = "SES-REMOTE"
            self.state.profileId = "P-REMOTE"
            self.state.coordinator = "Remote-Realm"
        end,
        _ResetSessionState = function(self)
            self.state.active = false
            self.state.sessionId = nil
        end,
        EndSession = function(self)
            self:_ResetSessionState()
        end,
    },
}

_G.hooksecurefunc = function(tbl, name, hook)
    local original = tbl[name]
    tbl[name] = function(self, ...)
        local a, b, c = original(self, ...)
        hook(self, ...)
        return a, b, c
    end
end

assertTrue(Capture.InstallSessionHooks(), "session hooks install once")
assertFalse(Capture.InstallSessionHooks(), "hook install is idempotent")

_G.SpectrumFederation.LootHelperSync:TryRestorePersistedSession()
assertTrue(Capture.IsListenerRegistered(), "restored session activates capture")
assertEq(Capture.GetDatabase().entries[1].kind, "capture_start", "restore writes capture_start")
assertEq(Capture.GetDatabase().entries[1].reason, "TryRestorePersistedSession", "restore marker records the source")

_G.SpectrumFederation.LootHelperSync:_ResetSessionState()
assertFalse(Capture.IsListenerRegistered(), "reset unregisters this addon's listener")
assertEq(unregisterCalls, 1, "reset calls UnregisterAllComm on this receiver only")
assertEq(Capture.GetDatabase().entries[#Capture.GetDatabase().entries].kind, "capture_stop", "reset writes capture_stop")

_G.SpectrumFederation.LootHelperSync:HandleSessionStart()
assertTrue(Capture.IsListenerRegistered(), "remote session start activates capture")
assertEq(Capture.GetSessionContext().sessionId, "SES-REMOTE", "remote session id is visible to capture")

_G.SpectrumFederation.LootHelperSync:EndSession()
assertFalse(Capture.IsListenerRegistered(), "session end unregisters the listener")

-- ---------------------------------------------------------------------------
-- Heartbeat-driven session activation reconciles the listener
-- ---------------------------------------------------------------------------

Capture = loadCapture()
registerCalls = {}
unregisterCalls = 0
_G.LibStub = function(name)
    if name == "AceComm-3.0" then
        return aceComm
    end
    return nil
end
_G.SpectrumFederation = {
    LootHelperSync = {
        state = { active = false },
        IsSessionActive = function(self)
            return self.state.active == true
        end,
        GetSessionId = function(self)
            return self.state.active and self.state.sessionId or nil
        end,
        GetSessionProfileId = function(self)
            return self.state.active and self.state.profileId or nil
        end,
        GetCoordinator = function(self)
            return self.state.active and self.state.coordinator or nil
        end,
        -- Mirrors production HandleSessionHeartbeat applying a valid descriptor:
        -- SpectrumFederation/modules/LootHelperSync/14_HandlersControl.lua
        -- sets state.active = true after validation.
        HandleSessionHeartbeat = function(self, _sender, payload)
            if type(payload) ~= "table" then
                return
            end
            if type(payload.sessionId) ~= "string" or payload.sessionId == "" then
                return
            end
            if type(payload.profileId) ~= "string" or payload.profileId == "" then
                return
            end
            if type(payload.coordinator) ~= "string" or payload.coordinator == "" then
                return
            end
            self.state.active = true
            self.state.sessionId = payload.sessionId
            self.state.profileId = payload.profileId
            self.state.coordinator = payload.coordinator
            self.state.coordEpoch = payload.coordEpoch
        end,
    },
}
_G.hooksecurefunc = function(tbl, name, hook)
    local original = tbl[name]
    tbl[name] = function(self, ...)
        local a, b, c = original(self, ...)
        hook(self, ...)
        return a, b, c
    end
end

assertTrue(Capture.InstallSessionHooks(), "heartbeat hooks install")
assertFalse(Capture.IsListenerRegistered(), "listener is inactive before heartbeat activation")
assertEq(#registerCalls, 0, "no prefix registrations before heartbeat")

_G.SpectrumFederation.LootHelperSync:HandleSessionHeartbeat("Coord-Realm", {
    sessionId = "SES-HB",
    profileId = "P-HB",
    coordinator = "Coord-Realm",
    coordEpoch = 7,
})

assertTrue(Capture.IsListenerRegistered(), "heartbeat activation registers the listener")
assertEq(#registerCalls, 3, "heartbeat activation registers all RC prefixes once")
assertEq(registerCalls[1].prefix, "RCLC", "heartbeat registers RCLC")
assertEq(registerCalls[2].prefix, "RCLCv", "heartbeat registers RCLCv")
assertEq(registerCalls[3].prefix, "RCLCs", "heartbeat registers RCLCs")

local heartbeatStarts = 0
local heartbeatDb = Capture.GetDatabase()
for i = 1, #heartbeatDb.entries do
    if heartbeatDb.entries[i].kind == "capture_start" then
        heartbeatStarts = heartbeatStarts + 1
        assertEq(heartbeatDb.entries[i].reason, "HandleSessionHeartbeat", "start marker records heartbeat reason")
    end
end
assertEq(heartbeatStarts, 1, "heartbeat activation writes exactly one capture_start marker")

_G.SpectrumFederation.LootHelperSync:HandleSessionHeartbeat("Coord-Realm", {
    sessionId = "SES-HB",
    profileId = "P-HB",
    coordinator = "Coord-Realm",
    coordEpoch = 7,
})
assertEq(#registerCalls, 3, "repeat heartbeat does not register prefixes again")
heartbeatStarts = 0
heartbeatDb = Capture.GetDatabase()
for i = 1, #heartbeatDb.entries do
    if heartbeatDb.entries[i].kind == "capture_start" then
        heartbeatStarts = heartbeatStarts + 1
    end
end
assertEq(heartbeatStarts, 1, "repeat heartbeat does not write another start marker")
local hbCounts = Capture.GetRegisterCounts()
assertEq(hbCounts.RCLC, 1, "heartbeat path registers RCLC once")
assertEq(hbCounts.RCLCv, 1, "heartbeat path registers RCLCv once")
assertEq(hbCounts.RCLCs, 1, "heartbeat path registers RCLCs once")

-- ---------------------------------------------------------------------------
-- Incoming messages persist raw data even when decoders are missing
-- ---------------------------------------------------------------------------

Capture = loadCapture()
registerCalls = {}
_G.LibStub = function(name)
    if name == "AceComm-3.0" then
        return aceComm
    end
    return nil
end
_G.SpectrumFederation = {
    LootHelperSync = {
        IsSessionActive = function()
            return true
        end,
        GetSessionId = function()
            return "SES-LIVE"
        end,
        GetSessionProfileId = function()
            return "P-LIVE"
        end,
        GetCoordinator = function()
            return "Coord-Realm"
        end,
    },
    lootHelperDB = {},
    LootLogs = {
        AddLog = function()
            error("RC capture must not write Loot Logs")
        end,
    },
    LootHelper = {
        AwardItem = function()
            error("RC capture must not award items")
        end,
    },
}

assertEq(Capture.ReconcileListener("test"), "started", "listener starts for incoming-message tests")

local stored = Capture.HandleIncomingMessage("RCLC", "raw-logical-payload", "RAID", "Sender-Realm")
assertTrue(stored ~= nil, "incoming message is persisted")
assertEq(stored.kind, "message", "persisted comms use kind=message")
assertEq(stored.direction, "received", "direction is received")
assertEq(stored.raw, "raw-logical-payload", "raw logical payload is stored complete")
assertEq(stored.rawByteLength, #"raw-logical-payload", "raw byte length is stored")
assertEq(stored.decodeStatus, "unavailable", "missing decoders are recorded as unavailable")
assertEq(stored.sessionId, "SES-LIVE", "session id is stored on the message")
assertTrue(stored.decodeError ~= nil, "unavailable decode records a reason")

-- ---------------------------------------------------------------------------
-- Malformed compressed/serialized data cannot throw through the listener
-- ---------------------------------------------------------------------------

local exploding = {
    DecodeForWoWAddonChannel = function()
        error("bad deflate")
    end,
    DecompressDeflate = function()
        error("should not reach decompress")
    end,
}
local serializerOk = {
    Deserialize = function()
        error("should not reach deserialize")
    end,
}

local decoded = Capture.DecodeLogicalPayload("!!!", {
    LibDeflate = exploding,
    AceSerializer = serializerOk,
})
assertEq(decoded.decodeStatus, "error", "decoder exceptions become decode errors")
assertTrue(type(decoded.decodeError) == "string", "decode error text is stored")

local ok, err = pcall(Capture.HandleIncomingMessage, "RCLC", "!!!", "RAID", "Sender-Realm")
assertTrue(ok, "listener does not throw on malformed payload")
assertTrue(err ~= nil, "malformed payload still persists an entry")
assertEq(err.decodeStatus, "unavailable", "runtime handle still uses live library resolution")

-- Force the exploding libs through BuildMessageEntry
local forced = Capture.BuildMessageEntry("RCLC", "!!!", "RAID", "Sender-Realm", {
    LibDeflate = exploding,
    AceSerializer = serializerOk,
})
assertEq(forced.decodeStatus, "error", "injected exploding decoder is caught")
assertTrue(forced.raw == "!!!", "raw payload survives exploding decoder")

-- ---------------------------------------------------------------------------
-- Incoming messages drop and reconcile if the session is no longer active
-- ---------------------------------------------------------------------------

_G.SpectrumFederation.LootHelperSync.IsSessionActive = function()
    return false
end
assertTrue(Capture.IsListenerRegistered(), "listener is still registered after session becomes inactive")
local beforeStale = #Capture.GetDatabase().entries
local stale = Capture.HandleIncomingMessage("RCLC", "stale-after-inactive", "RAID", "Sender-Realm")
assertTrue(stale == nil, "inactive-session inbound message is not persisted")
assertFalse(Capture.IsListenerRegistered(), "inbound guard unregisters the stale listener")
local afterStale = Capture.GetDatabase().entries
assertTrue(#afterStale >= beforeStale, "inbound guard may append a stop marker")
assertTrue(afterStale[#afterStale].raw ~= "stale-after-inactive", "stale payload is not stored")
local foundStale = false
for i = 1, #afterStale do
    if afterStale[i].kind == "message" and afterStale[i].raw == "stale-after-inactive" then
        foundStale = true
    end
end
assertFalse(foundStale, "stale inbound RC payload is absent from history")
assertEq(afterStale[#afterStale].kind, "capture_stop", "inbound guard writes capture_stop")
assertEq(afterStale[#afterStale].reason, "incoming_inactive", "stop marker records incoming_inactive")

-- ---------------------------------------------------------------------------
-- Successful semantic decode and xrealm preservation
-- ---------------------------------------------------------------------------

local fakeLd = {
    DecodeForWoWAddonChannel = function(_, raw)
        return "decoded:" .. raw
    end,
    DecompressDeflate = function(_, decoded)
        return "inflated:" .. decoded
    end,
}
local fakeSerializer = {
    Deserialize = function(_, inflated)
        if inflated == "inflated:decoded:award" then
            return true, "award", { "Winner-Realm", "|cffa335ee|Hitem:1|h[Sword]|h|r" }
        end
        if inflated == "inflated:decoded:xrealm" then
            return true, "xrealm", { "Target-Realm", "vote", { item = "link", response = 1 } }
        end
        return false, "unexpected"
    end,
}

local award = Capture.DecodeLogicalPayload("award", {
    LibDeflate = fakeLd,
    AceSerializer = fakeSerializer,
})
assertEq(award.decodeStatus, "ok", "successful decode is marked ok")
assertEq(award.wireCommand, "award", "wire command is stored")
assertEq(award.effectiveCommand, "award", "non-xrealm effective command matches wire command")
assertEq(award.decodedData[1], "Winner-Realm", "decoded data is preserved")
assertEq(award.effectiveTarget, nil, "non-xrealm messages have no derived target")

local xrealm = Capture.DecodeLogicalPayload("xrealm", {
    LibDeflate = fakeLd,
    AceSerializer = fakeSerializer,
}, "Target-Realm")
assertEq(xrealm.decodeStatus, "ok", "xrealm decode succeeds")
assertEq(xrealm.wireCommand, "xrealm", "original wire command remains xrealm")
assertEq(xrealm.effectiveCommand, "vote", "derived xrealm command is vote")
assertEq(xrealm.effectiveTarget, "Target-Realm", "derived xrealm target is preserved")
assertEq(xrealm.decodedData[1], "Target-Realm", "original decoded data still contains the envelope target")
assertEq(xrealm.decodedData[2], "vote", "original decoded data still contains the inner command")
assertEq(xrealm.effectiveData[1].item, "link", "derived xrealm data is the remaining payload")
assertTrue(xrealm.xrealmForLocalPlayer == true, "xrealm target matching the local player is recorded")

-- ---------------------------------------------------------------------------
-- Recent view does not prune persistent history
-- ---------------------------------------------------------------------------

Capture = loadCapture()
_G.SpectrumFederation = {
    LootHelperSync = {
        IsSessionActive = function()
            return false
        end,
    },
}
local historyDb = Capture.GetDatabase()
for i = 1, 300 do
    Capture.PersistEntry({ kind = "message", raw = "n" .. i })
end
assertEq(#historyDb.entries, 300, "persistent history stays unbounded")
assertEq(#Capture.GetRecentView(), 250, "recent view is bounded")
assertEq(Capture.GetRecentView()[1].raw, "n51", "recent view keeps the newest 250")
assertEq(historyDb.entries[1].raw, "n1", "oldest persistent entry remains")

Capture.SetShowFullHistory(true)
assertEq(#Capture.GetVisibleEntries(), 300, "full-history view can show every persisted entry")
Capture.SetShowFullHistory(false)
assertEq(#Capture.GetVisibleEntries(), 250, "default view returns to the recent cache")

-- ---------------------------------------------------------------------------
-- Settings page registration uses the Loot Helper parent
-- ---------------------------------------------------------------------------

Capture = loadCapture()
local registeredPage
_G.SpectrumFederation = {
    LootHelperSync = {
        IsSessionActive = function()
            return false
        end,
    },
    SettingsUI = {
        RegisterPage = function(_, page)
            registeredPage = page
        end,
    },
}

assertTrue(Capture.RegisterSettingsPage(), "settings page registers once")
assertFalse(Capture.RegisterSettingsPage(), "settings page registration is idempotent")
assertEq(registeredPage.id, "lootHelperRCLootCouncilCapture", "page id is lootHelperRCLootCouncilCapture")
assertEq(registeredPage.categoryId, "lootHelper", "page uses canonical categoryId lootHelper")
assertTrue(registeredPage.parentId == nil, "new page does not set legacy parentId")
assertEq(registeredPage.name, "RC Loot Council", "user-visible page name is RC Loot Council")
assertTrue(registeredPage.contentHeading == nil, "page does not set conflicting heading metadata")
assertTrue(type(registeredPage.Build) == "function", "page provides Build")

-- ---------------------------------------------------------------------------
-- Init / lifecycle idempotence and isolation
-- ---------------------------------------------------------------------------

Capture = loadCapture()
local lootLogCalls = 0
registerCalls = {}
_G.LibStub = function(name)
    if name == "AceComm-3.0" then
        return aceComm
    end
    return nil
end
_G.SpectrumFederation = {
    LootHelperSync = {
        state = { active = false },
        IsSessionActive = function(self)
            return self.state.active == true
        end,
        GetSessionId = function()
            return "SES-INIT"
        end,
        GetSessionProfileId = function()
            return "P-INIT"
        end,
        GetCoordinator = function()
            return "Coord-Realm"
        end,
        StartSession = function(self)
            self.state.active = true
        end,
        _ResetSessionState = function(self)
            self.state.active = false
        end,
    },
    SettingsUI = {
        RegisterPage = function()
        end,
    },
    LootLogs = {
        CreateLootLog = function()
            lootLogCalls = lootLogCalls + 1
        end,
    },
}
_G.hooksecurefunc = function(tbl, name, hook)
    local original = tbl[name]
    tbl[name] = function(self, ...)
        local a, b, c = original(self, ...)
        hook(self, ...)
        return a, b, c
    end
end

_G.SpectrumFederationRCLootCouncilCaptureDB = {
    schemaVersion = 1,
    nextSequence = 3,
    entries = {
        { kind = "capture_start", sequence = 1, timestamp = 1 },
        { kind = "message", sequence = 2, timestamp = 2, raw = "kept" },
    },
}

assertTrue(Capture.Init("first"), "first init returns true")
assertFalse(Capture.Init("second"), "second init is idempotent")
assertFalse(Capture.IsListenerRegistered(), "init without a session does not register")
assertEq(#Capture.GetDatabase().entries, 2, "Init preserves an existing capture database")
assertEq(Capture.GetDatabase().entries[2].raw, "kept", "Init does not replace historical entries")
assertEq(Capture.GetDatabase().nextSequence, 3, "Init keeps nextSequence monotonic")

_G.SpectrumFederation.LootHelperSync:StartSession()
assertTrue(Capture.IsListenerRegistered(), "StartSession hook reconciles capture on")

Capture.HandleIncomingMessage("RCLC", "payload", "RAID", "Sender-Realm")
assertEq(lootLogCalls, 0, "RC messages never call Loot Log creation")

_G.SpectrumFederation.LootHelperSync:_ResetSessionState()
assertFalse(Capture.IsListenerRegistered(), "reset hook reconciles capture off")

local ignored = Capture.HandleIncomingMessage("RCLC", "after-stop", "RAID", "Sender-Realm")
assertTrue(ignored == nil, "inactive listener stores no further RC messages")
local total = #Capture.GetDatabase().entries
local last = Capture.GetDatabase().entries[total]
assertTrue(last.kind ~= "message" or last.raw ~= "after-stop", "post-stop RC traffic is not appended")

-- ---------------------------------------------------------------------------
-- Settings status counters initialize from history and stay O(1)
-- ---------------------------------------------------------------------------

Capture = loadCapture()
_G.SpectrumFederation = {
    LootHelperSync = {
        IsSessionActive = function()
            return false
        end,
    },
    SettingsUI = {
        RegisterPage = function()
        end,
    },
}
_G.SpectrumFederationRCLootCouncilCaptureDB = {
    schemaVersion = 1,
    nextSequence = 5,
    entries = {
        { kind = "capture_start", sequence = 1, timestamp = 100 },
        { kind = "message", sequence = 2, timestamp = 200, raw = "old-a" },
        { kind = "message", sequence = 3, timestamp = 300, raw = "old-b" },
        { kind = "capture_stop", sequence = 4, timestamp = 400 },
    },
}

assertTrue(Capture.Init("summary"), "init seeds summary from existing history")
local seeded = Capture.GetSummary()
assertEq(seeded.totalEntries, 4, "summary total entries initialize from history")
assertEq(seeded.messageCount, 2, "summary message count initializes from history")
assertEq(seeded.latestTimestamp, 400, "summary latest timestamp initializes from history")

local status = Capture.GetStatusLines()
assertEq(status.entryCount, "4", "status entry count uses seeded summary")
assertEq(status.messageCount, "2", "status message count uses seeded summary")

local scanCalls = 0
local originalCount = Capture.CountEntries
function Capture.CountEntries(...)
    scanCalls = scanCalls + 1
    return originalCount(...)
end
local originalLatest = Capture.GetLatestTimestamp
function Capture.GetLatestTimestamp(...)
    scanCalls = scanCalls + 1
    return originalLatest(...)
end
local originalCompute = Capture.ComputeSummaryFromEntries
function Capture.ComputeSummaryFromEntries(...)
    scanCalls = scanCalls + 1
    return originalCompute(...)
end

status = Capture.GetStatusLines()
assertEq(status.entryCount, "4", "repeat status read still reports seeded totals")
assertEq(scanCalls, 0, "normal status reads do not walk persisted history")

local afterMessage = Capture.PersistEntry({ kind = "message", timestamp = 500, raw = "new-msg" })
assertTrue(afterMessage ~= nil, "message append succeeds after seeded init")
local afterMessageSummary = Capture.GetSummary()
assertEq(afterMessageSummary.totalEntries, 5, "appending a message increments total entries")
assertEq(afterMessageSummary.messageCount, 3, "appending a message increments message count")
assertEq(afterMessageSummary.latestTimestamp, 500, "appending a message updates latest timestamp")

local afterMarker = Capture.PersistEntry({ kind = "capture_start", timestamp = 600, reason = "manual" })
assertTrue(afterMarker ~= nil, "marker append succeeds")
local afterMarkerSummary = Capture.GetSummary()
assertEq(afterMarkerSummary.totalEntries, 6, "appending a lifecycle marker increments total entries")
assertEq(afterMarkerSummary.messageCount, 3, "appending a lifecycle marker does not increment message count")
assertEq(afterMarkerSummary.latestTimestamp, 600, "appending a marker updates latest timestamp")

scanCalls = 0
status = Capture.GetStatusLines()
assertEq(status.entryCount, "6", "status entry count follows incremental updates")
assertEq(status.messageCount, "3", "status message count follows incremental updates")
assertEq(scanCalls, 0, "incremental status updates do not rescan history")
assertEq(#Capture.GetDatabase().entries, 6, "persistent history still contains every appended entry")

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
