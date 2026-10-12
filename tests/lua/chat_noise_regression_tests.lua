-- Regression tests: player-facing chat stays quiet for background / offline paths,
-- and session-start failures do not double-print across entry points.
-- Run: lua5.1 tests/lua/chat_noise_regression_tests.lua

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

local PLAYER = "Owner-Garona"

function strtrim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

function string.trim(s)
    return strtrim(s)
end

function GetRealmName()
    return "Garona"
end

function UnitName(unit)
    if unit == "player" then
        return PLAYER:match("^([^%-]+)")
    end
    return "Unknown"
end

function UnitFullName(unit)
    if unit == "player" then
        return PLAYER:match("^([^%-]+)"), "Garona"
    end
    return "Unknown", "Garona"
end

function UnitClass()
    return "Warrior", "WARRIOR"
end

function GetServerTime()
    return 1700001000
end

function GetTime()
    return 0
end

function IsInRaid()
    return false
end

function IsInGroup()
    return false
end

function GetNumGroupMembers()
    return 0
end

function strsplit(delim, text)
    local left, right = string.match(text, "^(.-)" .. delim .. "(.*)$")
    return left, right
end

C_Timer = {
    NewTimer = function(_, fn)
        local handle = { cancelled = false, fn = fn }
        function handle:Cancel()
            self.cancelled = true
        end
        return handle
    end,
    NewTicker = function()
        local handle = { cancelled = false }
        function handle:Cancel()
            self.cancelled = true
        end
        return handle
    end,
}

SpectrumFederationDB = { lootHelper = { profiles = {}, syncSession = {}, window = {} } }
SpectrumFederationDebugDB = { enabled = false, logs = {} }

local SF = {}
local printed = {}
local debugLogs = {}

local function loadModule(relative)
    local chunk = assert(loadfile(relative))
    chunk("SpectrumFederation", SF)
end

loadModule("SpectrumFederation/modules/NameUtil.lua")
loadModule("SpectrumFederation/modules/core.lua")
loadModule("SpectrumFederation/modules/MessageHelpers.lua")
loadModule("SpectrumFederation/modules/LootHelper/Members.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootLogValidators.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootLogs.lua")
loadModule("SpectrumFederation/modules/LootHelper/Identity.lua")
loadModule("SpectrumFederation/modules/LootHelper/SpecWeapons.lua")
loadModule("SpectrumFederation/modules/LootHelper/Bis.lua")
loadModule("SpectrumFederation/modules/LootHelper/Profiles.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootHelper.lua")
loadModule("SpectrumFederation/modules/LootHelper/Impersonation.lua")
loadModule("SpectrumFederation/modules/LootHelper/SyncProtocol.lua")
loadModule("SpectrumFederation/modules/Settings/Store.lua")
loadModule("SpectrumFederation/modules/SlashCommands.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/01_Constants.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/02_State.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/07_Validation.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/12_LiveUpdates.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/18_PublicAPI.lua")
loadModule("SpectrumFederation/modules/UI/LootHelper/Controller.lua")

function SF:GetPlayerFullIdentifier()
    return PLAYER
end

function SF:GetPlayerClass()
    return "WARRIOR"
end

function SF:PrintInfo(message)
    printed[#printed + 1] = { "info", tostring(message) }
end

function SF:PrintSuccess(message)
    printed[#printed + 1] = { "success", tostring(message) }
end

function SF:PrintError(message)
    printed[#printed + 1] = { "error", tostring(message) }
end

function SF:PrintWarning(message)
    printed[#printed + 1] = { "warn", tostring(message) }
end

local function recordDebug(level, category, fmt, ...)
    local message = tostring(fmt or "")
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, message, ...)
        if ok then
            message = formatted
        else
            message = message .. " " .. table.concat({ ... }, " ")
        end
    end
    debugLogs[#debugLogs + 1] = {
        level = level,
        category = tostring(category),
        message = message,
    }
end

SF.Debug = setmetatable({
    Info = function(_, category, fmt, ...)
        recordDebug("info", category, fmt, ...)
    end,
    Warn = function(_, category, fmt, ...)
        recordDebug("warn", category, fmt, ...)
    end,
    Error = function(_, category, fmt, ...)
        recordDebug("error", category, fmt, ...)
    end,
    Verbose = function() end,
}, {
    -- Profiles.lua still has a few legacy SF.Debug(category, msg) call sites.
    __call = function(_, category, fmt, ...)
        recordDebug("info", category, fmt, ...)
    end,
})

local Sync = SF.LootHelperSync
local Controller = SF.LootHelperWindow.Controller
local Imp = SF.LootHelperImpersonation

if SF.SettingsStore and SF.SettingsStore.Init then
    SF.SettingsStore:Init()
end

function SF.SettingsStore:GetActiveLootHelperProfileId()
    return SF.lootHelperDB and SF.lootHelperDB.activeProfileId or nil
end

Sync.state = Sync.state or {
    active = false,
    requests = {},
    helpers = {},
    adminStatuses = {},
}

function Sync:_SelfId()
    return PLAYER
end

function Sync:_Now()
    return 1
end

function Sync:FindLocalProfileById(profileId)
    return SF.lootHelperDB and SF.lootHelperDB.profiles and SF.lootHelperDB.profiles[profileId]
end

function Sync:_GetProfileAdminUsers(profile)
    if profile and profile.GetAdminUsers then
        return profile:GetAdminUsers()
    end
    return profile and profile._adminUsers
end

function Sync:_PersistSessionState() end
function Sync:_ResetSessionSafeMode() end
function Sync:_ResetLocalSafeMode() end
function Sync:RebuildProfile() end
function Sync:UpdatePeersFromRoster() end
function Sync:TouchPeer() end
function Sync:LogSessionPointsSummary() end
function Sync:BeginAdminConvergence() end
function Sync:_NextNonce()
    return "SES1"
end
function Sync:_ResetSessionState()
    self.state.active = false
    self.state.sessionId = nil
    self.state.profileId = nil
    self.state.isCoordinator = false
end

if type(Sync.IsSessionActive) ~= "function" then
    function Sync:IsSessionActive()
        return self.state and self.state.active and true or false
    end
end

local function countPrinted(kind, needle)
    local n = 0
    for i = 1, #printed do
        if (not kind or printed[i][1] == kind) and printed[i][2]:find(needle, 1, true) then
            n = n + 1
        end
    end
    return n
end

local function countDebug(needle)
    local n = 0
    for i = 1, #debugLogs do
        if debugLogs[i].message:find(needle, 1, true) then
            n = n + 1
        end
    end
    return n
end

local function resetDB()
    SF.lootHelperDB = {
        enabled = true,
        profiles = {},
        activeProfileId = nil,
        activeProfile = nil,
        window = {},
        syncSession = {},
    }
    SpectrumFederationDB.lootHelper = SF.lootHelperDB
    Sync.state.active = false
    Sync.state.sessionId = nil
    Sync.state.profileId = nil
    Sync.state.isCoordinator = false
    Sync.state.requests = {}
    Sync.state.helpers = {}
    Sync.state.adminStatuses = {}
    Imp._active = false
    Imp._profileId = nil
    Imp._listeners = {}
    Imp._hooksInstalled = false
    Imp._inited = false
    Imp._slashRegistered = false
    printed = {}
    debugLogs = {}
    Imp:Init()
end

local function makeProfile(name)
    local profile = SF.LootProfile.new(name)
    assert(profile, "failed to create profile " .. tostring(name))
    SF.lootHelperDB.profiles[profile:GetProfileId()] = profile
    return profile
end

local function setActive(profile)
    SF:SetActiveProfileById(profile:GetProfileId())
end

local function readFile(path)
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    return text
end

-- ---------------------------------------------------------------------------
-- Source guards: callers must not re-print generic StartSession failures
-- ---------------------------------------------------------------------------
local controllerSrc = readFile("SpectrumFederation/modules/UI/LootHelper/Controller.lua")
local slashSrc = readFile("SpectrumFederation/modules/SlashCommands.lua")
local raidCheckSrc = readFile("SpectrumFederation/modules/RaidCheck.lua")

assertEq(
    controllerSrc:find('SF:PrintError("Failed to start session (not in a group/raid?)")', 1, true),
    nil,
    "controller does not PrintError the generic StartSession fallback"
)
assertEq(
    slashSrc:find('SF:PrintError("Failed to start session (not in a group/raid?)")', 1, true),
    nil,
    "slash session start does not PrintError the generic StartSession fallback"
)
assertEq(
    raidCheckSrc:find('SF:PrintError("Failed to start a Loot Helper session. The check was not started.")', 1, true),
    nil,
    "Raid Check Yes-path does not PrintError a second StartSession failure"
)

-- ---------------------------------------------------------------------------
-- Duplicate session-start errors: one specific chat error per attempt
-- ---------------------------------------------------------------------------
resetDB()
local profile = makeProfile("ChatNoise")
setActive(profile)

-- Ungrouped StartSession prints the specific error once.
function Sync:_EnforceGroupedSessionActive()
    return nil
end
printed = {}
debugLogs = {}
local sessionId = Sync:StartSession(profile:GetProfileId())
assertEq(sessionId, nil, "StartSession fails when not grouped")
assertEq(countPrinted("error", "Cannot start session: not in a group/raid."), 1,
    "StartSession emits one specific not-in-group error")
assertEq(countPrinted("error", "Failed to start session"), 0,
    "StartSession does not emit the generic caller fallback")

-- Play-button path: callee prints once; caller must not add a second chat error.
printed = {}
debugLogs = {}
local capturedAccept
SF.SettingsUI = SF.SettingsUI or {}
SF.SettingsUI.Dialogs = {
    Confirm = function(_, _message, _acceptText, onAccept)
        capturedAccept = onAccept
    end,
}
Controller:OnPlayClicked()
assertTrue(type(capturedAccept) == "function", "play-button start opened a confirmation")
capturedAccept()
assertEq(countPrinted("error", "Cannot start session: not in a group/raid."), 1,
    "play-button StartSession failure prints exactly one specific error")
assertEq(countPrinted("error", "Failed to start session"), 0,
    "play-button does not add a generic StartSession PrintError")
assertTrue(countDebug("Play-button StartSession returned nil") >= 1,
    "play-button records the nil result in Debug")

-- Slash path: same single-error guarantee.
printed = {}
debugLogs = {}
SF:RegisterLootHelperSlashCommands()
SF.SlashCommands.loot.handler("session start")
assertEq(countPrinted("error", "Cannot start session: not in a group/raid."), 1,
    "slash session start failure prints exactly one specific error")
assertEq(countPrinted("error", "Failed to start session"), 0,
    "slash session start does not add a generic StartSession PrintError")
assertTrue(countDebug("loot session start returned nil") >= 1,
    "slash session start records the nil result in Debug")

-- ---------------------------------------------------------------------------
-- Offline profile log writes: no sync-failure chat when no active session
-- ---------------------------------------------------------------------------
resetDB()
profile = makeProfile("OfflineLogs")
setActive(profile)
Sync.state.active = false
Sync.state.sessionId = nil

-- Restore BroadcastNewLog production behavior (no active session => fail reason).
assertTrue(type(Sync.BroadcastNewLog) == "function", "BroadcastNewLog is available")

local function makePointLog(profileObj, counter)
    local eventType = SF.LootLogEventTypes.POINT_CHANGE
    local eventData = SF.LootLog.GetEventDataTemplate(eventType)
    eventData.member = PLAYER
    eventData.change = SF.LootLogPointChangeTypes.INCREMENT
    local logEntry = SF.LootLog.new(eventType, eventData, {
        profile = profileObj,
        author = PLAYER,
        counter = counter,
        timestamp = GetServerTime() + counter,
        skipPermission = true,
    })
    assert(logEntry, "failed to create POINT_CHANGE log " .. tostring(counter))
    assert(getmetatable(logEntry) == SF.LootLog, "log metatable is LootLog")
    return logEntry
end

printed = {}
debugLogs = {}
local ok, err = profile:AddLootLog(makePointLog(profile, 1), { skipPermission = true })
assertTrue(ok, "offline AddLootLog persists locally: " .. tostring(err))
assertEq(countPrinted("warn", "Change saved locally, but it could not be synchronized to the raid."), 0,
    "no-active-session broadcast does not warn in chat")
assertTrue(countDebug("no active session") >= 1 or countDebug("expected offline") >= 1,
    "offline broadcast failure is recorded in Debug")

-- Repeated offline writes still stay silent in chat.
for i = 2, 5 do
    assertTrue(
        profile:AddLootLog(makePointLog(profile, i), { skipPermission = true }),
        "repeated offline AddLootLog " .. tostring(i)
    )
end
assertEq(countPrinted(nil, "could not be synchronized to the raid"), 0,
    "repeated offline writes do not chat-spam synchronization warnings")

-- Genuine in-session broadcast failure still warns once (deduped).
Sync.state.active = true
Sync.state.sessionId = "SES-ACTIVE"
Sync.state.profileId = profile:GetProfileId()
function Sync:BroadcastNewLog()
    return false, "comm send dropped"
end
printed = {}
debugLogs = {}
assertTrue(
    profile:AddLootLog(makePointLog(profile, 10), { skipPermission = true }),
    "in-session AddLootLog still inserts locally"
)
assertEq(countPrinted("warn", "Change saved locally, but it could not be synchronized to the raid."), 1,
    "unexpected in-session broadcast failure warns once")
assertTrue(
    profile:AddLootLog(makePointLog(profile, 11), { skipPermission = true }),
    "second in-session failure still inserts"
)
assertEq(countPrinted("warn", "Change saved locally, but it could not be synchronized to the raid."), 1,
    "unsyncedChangeNoted dedupes repeated in-session sync warnings")

-- ---------------------------------------------------------------------------
-- Protocol / background-style silence: repeated incompatible traffic stays quiet
-- ---------------------------------------------------------------------------
printed = {}
debugLogs = {}
local P = SF.SyncProtocol
assertTrue(P ~= nil, "SyncProtocol loaded")
local nackPayload = {
    seenProto = 2,
    supportedMin = 1,
    supportedMax = 1,
    addonVersion = "1.4.1",
}
for _ = 1, 15 do
    P.OnProtoNack("Peer-Garona", nackPayload)
end
assertEq(countPrinted(nil, "incompatible"), 0, "repeated PROTO_NACK never prints to chat")
assertEq(#printed, 0, "protocol incompatibility path produces no player chat")

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
io.stdout:write("0 failed\n")
