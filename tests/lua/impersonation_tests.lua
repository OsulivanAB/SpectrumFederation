-- Production-Lua tests for Loot Helper impersonation (Preview as Non-Admin).
-- Run from the repository root: lua5.1 tests/lua/impersonation_tests.lua

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

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local function assertFalse(cond, message)
    assertTrue(not cond, message)
end

-- ---------------------------------------------------------------------------
-- Minimal WoW / addon environment
-- ---------------------------------------------------------------------------
local PLAYER = "Tester-Garona"

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
        return "Tester"
    end
    return "Unknown"
end

function UnitFullName(unit)
    if unit == "player" then
        return "Tester", "Garona"
    end
    return "Unknown", "Garona"
end

function UnitClass()
    return "Warrior", "WARRIOR"
end

function GetServerTime()
    return 1700000000
end

function GetTime()
    return 0
end

INVSLOT_HEAD = 1
INVSLOT_NECK = 2
INVSLOT_SHOULDER = 3
INVSLOT_BACK = 15
INVSLOT_CHEST = 5
INVSLOT_WRIST = 9
INVSLOT_HAND = 10
INVSLOT_WAIST = 6
INVSLOT_LEGS = 7
INVSLOT_FEET = 8
INVSLOT_FINGER1 = 11
INVSLOT_FINGER2 = 12
INVSLOT_TRINKET1 = 13
INVSLOT_TRINKET2 = 14
INVSLOT_MAINHAND = 16
INVSLOT_OFFHAND = 17

CreateFrame = CreateFrame or function()
    local f = {
        shown = false,
        scripts = {},
        points = {},
    }
    function f:SetScript(ev, fn) self.scripts[ev] = fn end
    function f:HookScript(ev, fn) self.scripts[ev] = fn end
    function f:RegisterEvent() end
    function f:SetPoint() end
    function f:SetAllPoints() end
    function f:SetSize() end
    function f:SetHeight(h) self.height = h end
    function f:SetWidth() end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:CreateTexture()
        return {
            SetAllPoints = function() end,
            SetColorTexture = function() end,
            SetPoint = function() end,
            SetHeight = function() end,
            SetAtlas = function() end,
        }
    end
    function f:CreateFontString()
        return {
            SetPoint = function() end,
            SetText = function() end,
            SetTextColor = function() end,
            SetJustifyH = function() end,
            SetJustifyV = function() end,
            SetWordWrap = function() end,
            SetFontObject = function() end,
        }
    end
    function f:EnableMouse() end
    function f:SetMovable() end
    function f:SetClampedToScreen() end
    function f:RegisterForDrag() end
    function f:SetFrameStrata() end
    function f:SetBackdrop() end
    function f:SetBackdropColor() end
    function f:SetBackdropBorderColor() end
    function f:SetNormalTexture() end
    function f:SetHighlightTexture() end
    function f:SetPushedTexture() end
    return f
end

SpectrumFederationDB = { lootHelper = { profiles = {}, syncSession = {}, window = {} } }
SpectrumFederationDebugDB = { enabled = false, logs = {} }

local SF = {}
local printed = {}

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
loadModule("SpectrumFederation/modules/LootHelper/Profiles.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootHelper.lua")
loadModule("SpectrumFederation/modules/LootHelper/Impersonation.lua")
loadModule("SpectrumFederation/modules/Settings/Store.lua")
loadModule("SpectrumFederation/modules/SlashCommands.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/07_Validation.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/18_PublicAPI.lua")
loadModule("SpectrumFederation/modules/RaidEquipment/CheckRun.lua")
loadModule("SpectrumFederation/modules/RaidCheck.lua")
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

local Imp = SF.LootHelperImpersonation
local Sync = SF.LootHelperSync
local Controller = SF.LootHelperWindow.Controller

Sync.state = Sync.state or {
    active = false,
    requests = {},
    helpers = {},
    adminStatuses = {},
}
function Sync:_EnforceGroupedSessionActive()
    return "RAID"
end
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
if type(Sync.IsSessionActive) ~= "function" then
    function Sync:IsSessionActive()
        return self.state and self.state.active and true or false
    end
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
    Imp._active = false
    Imp._profileId = nil
    Imp._listeners = {}
    Imp._hooksInstalled = false
    Imp._inited = false
    Imp._slashRegistered = false
    printed = {}
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

-- ---------------------------------------------------------------------------
-- Core runtime
-- ---------------------------------------------------------------------------
resetDB()
assertFalse(Imp:Enable(), "no active profile cannot enable")
assertEq(select(2, Imp:CanEnable()), "No active Loot Helper profile.", "no-profile enable error")

local p1 = makeProfile("Alpha")
local p2 = makeProfile("Beta")
setActive(p1)

assertTrue(p1:IsCurrentUserAdmin(), "creator is canonical admin")
assertTrue(p1:IsCurrentUserOwner(), "creator is canonical owner")
assertTrue(Imp:CanEnable(), "canonical admin can enable")
assertTrue(Imp:CanShowToggle(), "canonical admin can see toggle")

local savedPlayer = PLAYER
PLAYER = "Other-Garona"
assertFalse(p1:IsCurrentUserAdmin(), "other player is not canonical admin")
assertFalse(Imp:CanEnable(), "canonical non-admin cannot enable via API")
Imp:HandleSlash("on")
local deniedOn = false
for i = 1, #printed do
    if printed[i][1] == "error" then
        deniedOn = true
    end
end
assertTrue(deniedOn, "canonical non-admin cannot enable via slash")
PLAYER = savedPlayer
printed = {}

local callbacks = 0
Imp:RegisterCallback(function()
    callbacks = callbacks + 1
end)

assertTrue(Imp:Enable(), "canonical admin enable succeeds")
assertEq(callbacks, 1, "enable notifies once")
assertTrue(Imp:IsActive(), "impersonation is active")
assertTrue(p1:IsCurrentUserAdmin(), "canonical admin truth unchanged while impersonating")
assertTrue(p1:IsCurrentUserOwner(), "canonical owner truth unchanged while impersonating")
assertFalse(Imp:IsEffectiveLocalAdmin(p1), "effective admin is false while impersonating")
assertFalse(Imp:IsEffectiveLocalOwner(p1), "effective owner is false while impersonating")

assertTrue(Imp:Enable(), "enable is idempotent")
assertEq(callbacks, 1, "idempotent enable does not notify again")

assertTrue(Imp:Disable("test"), "disable restores")
assertEq(callbacks, 2, "disable notifies once")
assertTrue(Imp:IsEffectiveLocalAdmin(p1), "disable restores effective admin")
assertTrue(Imp:IsEffectiveLocalOwner(p1), "disable restores effective owner")
assertFalse(Imp:Disable("test"), "disable is idempotent")
assertEq(callbacks, 2, "idempotent disable does not notify again")
local idle = Imp:GetRuntimeState()
assertEq(idle.active, false, "inactive record active=false")
assertEq(idle.profileId, nil, "inactive record profileId is nil")

assertTrue(Imp:Enable(), "re-enable for switch tests")
assertEq(callbacks, 3, "second enable notifies")
setActive(p2)
assertFalse(Imp:IsActive(), "profile switch clears impersonation")
local afterSwitch = Imp:GetRuntimeState()
assertEq(afterSwitch.active, false, "switch clears raw active")
assertEq(afterSwitch.profileId, nil, "switch clears raw profileId")
assertEq(callbacks, 4, "profile switch notifies once")
setActive(p1)
assertFalse(Imp:IsActive(), "switching back does not reactivate")
assertEq(callbacks, 4, "switching back does not notify")

assertTrue(Imp:Enable(), "enable before admin-loss")
assertEq(callbacks, 5, "enable after switch-back notifies")
p1._adminUsers = { "Someone-Else" }
p1._owner = "Someone-Else"
Imp:ValidateBoundState("lost-admin")
assertFalse(Imp:IsActive(), "canonical admin loss clears impersonation")
assertEq(callbacks, 6, "admin loss notifies once")
p1._adminUsers = { PLAYER }
p1._owner = PLAYER

-- ---------------------------------------------------------------------------
-- Persistence / schema / serialized admin state
-- ---------------------------------------------------------------------------
local schemaFile = io.open("SpectrumFederation/modules/Settings/Schema.lua", "r")
local schemaText = schemaFile:read("*a")
schemaFile:close()
assertTrue(not schemaText:lower():find("impersonat"), "no impersonation SavedVariables/schema data")

local storeFile = io.open("SpectrumFederation/modules/Settings/Store.lua", "r")
local storeText = storeFile:read("*a")
storeFile:close()
assertTrue(not storeText:lower():find("impersonat"), "Store has no impersonation persistence")

local adminsBefore = { p1._adminUsers[1] }
local ownerBefore = p1._owner
assertTrue(Imp:Enable(), "enable for serialization check")
assertEq(p1._adminUsers[1], adminsBefore[1], "admin list unchanged while impersonating")
assertEq(p1._owner, ownerBefore, "owner unchanged while impersonating")
Imp:Disable("serialize")

-- ---------------------------------------------------------------------------
-- Slash: role-escalation rejected; status does not toggle
-- ---------------------------------------------------------------------------
printed = {}
Imp:HandleSlash("")
assertFalse(Imp:IsActive(), "bare impersonate does not toggle")
Imp:HandleSlash("status")
assertFalse(Imp:IsActive(), "status does not toggle")
printed = {}
Imp:HandleSlash("admin")
local rejectedAdmin = false
for i = 1, #printed do
    if printed[i][1] == "error" then
        rejectedAdmin = true
    end
end
assertTrue(rejectedAdmin, "slash admin is rejected")
assertFalse(Imp:IsActive(), "slash admin does not enable")
printed = {}
Imp:HandleSlash("as-admin")
local rejectedAsAdmin = false
for i = 1, #printed do
    if printed[i][1] == "error" then
        rejectedAsAdmin = true
    end
end
assertTrue(rejectedAsAdmin, "slash as-admin is rejected")
assertFalse(Imp:IsActive(), "slash as-admin does not enable")

-- ---------------------------------------------------------------------------
-- Canonical sync authorization / CanSelfCoordinate
-- ---------------------------------------------------------------------------
setActive(p1)
local canCoord, coordWhy = Sync:CanSelfCoordinate(p1:GetProfileId())
assertTrue(canCoord, "CanSelfCoordinate true before impersonation: " .. tostring(coordWhy))
assertTrue(Imp:Enable(), "enable before CanSelfCoordinate")
local canCoord2, coordWhy2 = Sync:CanSelfCoordinate(p1:GetProfileId())
assertTrue(canCoord2, "CanSelfCoordinate unaffected by impersonation: " .. tostring(coordWhy2))
assertTrue(Sync:IsSenderAuthorized(p1:GetProfileId(), PLAYER), "IsSenderAuthorized stays canonical")

-- ---------------------------------------------------------------------------
-- Rename
-- ---------------------------------------------------------------------------
local originalName = p1:GetProfileName()
local logCountBefore = #(p1._lootLogs or {})
local renameOk, renameErr = SF:RenameActiveLootHelperProfile("RenamedWhilePreviewing")
assertFalse(renameOk, "rename cannot mutate while impersonating")
assertEq(p1:GetProfileName(), originalName, "profile name unchanged while impersonating")
assertEq(#(p1._lootLogs or {}), logCountBefore, "rename while impersonating adds no log")

-- Stale Rename callback: capture like Settings Prompt, enable, then accept
Imp:Disable("rename-setup")
assertTrue(Imp:IsEffectiveLocalAdmin(p1), "effective admin restored before stale rename setup")
local staleRename = function(newName)
    return SF:RenameActiveLootHelperProfile(newName)
end
assertTrue(Imp:Enable(), "enable after opening rename")
local staleOk = staleRename("StaleName")
assertFalse(staleOk, "stale Rename callback cannot mutate")
assertEq(p1:GetProfileName(), originalName, "stale rename leaves name unchanged")
assertEq(#(p1._lootLogs or {}), logCountBefore, "stale rename adds no log")

-- ---------------------------------------------------------------------------
-- Reset All
-- ---------------------------------------------------------------------------
callbacks = 0
Imp._listeners = {}
Imp:RegisterCallback(function()
    callbacks = callbacks + 1
end)
Imp:Invalidate("reset-all-setup")
callbacks = 0
assertTrue(Imp:Enable(), "enable before reset all")
assertTrue(Imp:IsActive(), "impersonation is active before Reset All")
assertEq(callbacks, 1, "reset-all setup enable notifies")
callbacks = 0
local resetOk = SF:ResetAllLootHelperSettings()
assertTrue(resetOk, "ResetAllLootHelperSettings succeeds")
assertEq(callbacks, 1, "Reset All emits one real transition")
local raw = Imp:GetRuntimeState()
assertEq(raw.active, false, "Reset All clears raw active")
assertEq(raw.profileId, nil, "Reset All clears raw profileId")
assertFalse(Imp:IsActive(), "Reset All ends impersonation")

-- Recreate profiles after reset
p1 = makeProfile("Alpha")
p2 = makeProfile("Beta")
setActive(p1)

-- ---------------------------------------------------------------------------
-- Raid Check consequences abort
-- ---------------------------------------------------------------------------
assertTrue(Imp:Enable(), "enable before raid-check abort")
local awarded = false
local potChanged = false
local whispered = false
local completePrinted = false
local memberId = PLAYER
local fakeMember = {
    IncrementPoints = function()
        awarded = true
        return true
    end,
    IncrementAttendance = function()
        awarded = true
        return true
    end,
    GetFullIdentifier = function()
        return memberId
    end,
}
function p1.GetRaidCheckConfig()
    return {
        enableWhispersRaid = true,
        enableWhispersRaidPrepared = true,
        pointsAwardPerRaidCheck = 1,
        slots = {},
    }
end
function p1.IsRewardPotMode()
    return false
end
function p1.AdjustRewardPot()
    potChanged = true
    return true
end
function p1.GetMemberByID()
    return fakeMember
end
function p1.getMemberByID()
    return fakeMember
end

local origSend = SendChatMessage
function SendChatMessage()
    whispered = true
end

local origPrintSuccess = SF.PrintSuccess
function SF:PrintSuccess(message)
    if tostring(message):find("Complete") then
        completePrinted = true
    end
    return origPrintSuccess(self, message)
end

local CheckRun = SF.RaidEquipment.CheckRun
local run = {
    profileId = p1:GetProfileId(),
    consequencesApplied = false,
    classified = true,
    classifiedResults = {
        [memberId] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FULL },
    },
    targetIds = { memberId },
    players = { [memberId] = { guid = "Player-1", } },
    mode = "raid",
    cfg = p1:GetRaidCheckConfig(),
}
SF.RaidCheck:_ApplyCheckConsequences(run)
assertTrue(run.consequencesApplied, "in-flight Raid Check is settled so it cannot replay")
assertFalse(awarded, "abort does not award points")
assertFalse(potChanged, "abort does not change Reward Pot")
assertFalse(whispered, "abort does not send admin Raid Check whispers")
assertFalse(completePrinted, "abort does not report successful completion")
local abortMsg = false
for i = 1, #printed do
    if printed[i][2]:find("viewing the profile as a non%-admin") then
        abortMsg = true
    end
end
assertTrue(abortMsg, "abort prints impersonation error")

SF.PrintSuccess = origPrintSuccess
SendChatMessage = origSend

-- Replay after impersonation ends must not apply the aborted run.
Imp:Disable("after-raid-check")
local replayAwarded = false
fakeMember.IncrementPoints = function()
    replayAwarded = true
    return true
end
SF.RaidCheck:_ApplyCheckConsequences(run)
assertFalse(replayAwarded, "settled abort cannot replay after impersonation ends")

-- ---------------------------------------------------------------------------
-- StartSession denied; EndSession internal still works; slash session end denied
-- ---------------------------------------------------------------------------
assertTrue(Imp:Enable(), "enable before session tests")
local enforceCalled = false
local origEnforce = Sync._EnforceGroupedSessionActive
function Sync:_EnforceGroupedSessionActive(reason)
    enforceCalled = true
    if origEnforce then
        return origEnforce(self, reason)
    end
    return "RAID"
end
local sessionId = Sync:StartSession(p1:GetProfileId())
assertEq(sessionId, nil, "StartSession denied while impersonating")
assertFalse(enforceCalled, "StartSession impersonation gate runs before grouped/coord checks")
local stillCoord, stillWhy = Sync:CanSelfCoordinate(p1:GetProfileId())
assertTrue(stillCoord, "canonical coordination remains available: " .. tostring(stillWhy))

Sync.state.active = true
Sync.state.isCoordinator = true
Sync.state.sessionId = "SES-TEST"
Sync.state.profileId = p1:GetProfileId()
Sync.state.coordinator = PLAYER
Sync.state.coordEpoch = 1
Sync.state.requests = {}
Sync.state.helpers = {}
local origReset = Sync._ResetSessionState
function Sync:_ResetSessionState(reason)
    self.state.active = false
    self._endedReason = reason
end
local ended = Sync:EndSession("manual", false)
assertTrue(ended ~= false, "internal EndSession still runs while impersonating")
assertEq(Sync.state.active, false, "internal EndSession clears session")
Sync._ResetSessionState = origReset
Sync._EnforceGroupedSessionActive = origEnforce

SF:RegisterLootHelperSlashCommands()
Sync.EndSession = function()
    error("slash session end must not call EndSession while impersonating")
end
printed = {}
SF.SlashCommands.loot.handler("session end")
local slashDenied = false
for i = 1, #printed do
    if printed[i][1] == "error" and printed[i][2]:find("previewing as a non%-admin") then
        slashDenied = true
    end
end
assertTrue(slashDenied, "slash session end denied while impersonating")
printed = {}
SF.SlashCommands.loot.handler("session start")
local slashStartDenied = false
for i = 1, #printed do
    if printed[i][1] == "error" and printed[i][2]:find("previewing as a non%-admin") then
        slashStartDenied = true
    end
end
assertTrue(slashStartDenied, "slash session start denied while impersonating")

-- Restore a harmless EndSession for play-button test
function Sync:EndSession()
    self._playEndCalled = true
    return true
end
function Sync:IsSessionActive()
    return true
end

-- ---------------------------------------------------------------------------
-- Stale play-button Stop confirmation
-- ---------------------------------------------------------------------------
local capturedAccept
SF.SettingsUI = SF.SettingsUI or {}
SF.SettingsUI.Dialogs = {
    Confirm = function(_, _message, _acceptText, onAccept)
        capturedAccept = onAccept
    end,
}
Sync._playEndCalled = false
Controller:OnPlayClicked()
assertTrue(type(capturedAccept) == "function", "play-button stop opened a confirmation")
-- Dialog was opened as admin; impersonation is already on, so accept must fail closed.
capturedAccept()
assertFalse(Sync._playEndCalled, "stale play-button Stop cannot EndSession while impersonating")

Imp:Disable("cleanup")
Sync._playEndCalled = false
capturedAccept = nil
Controller:OnPlayClicked()
capturedAccept()
assertTrue(Sync._playEndCalled, "play-button Stop works again after impersonation ends")

-- ---------------------------------------------------------------------------
-- Settings page contract (source-level, production definition)
-- ---------------------------------------------------------------------------
local pageFile = io.open("SpectrumFederation/modules/UI/Settings/Pages/LootHelper.lua", "r")
local pageText = pageFile:read("*a")
pageFile:close()
local adminBlock = pageText:match("admin = {(.-)%s*},%s*%s*}%s*%s*local sections")
if not adminBlock then
    adminBlock = pageText:match('id = "admin".-items = {(.-)%s*}%s*,%s*}%s*,%s*}')
end
assertTrue(pageText:find('label = "Preview as Non%-Admin"', 1, false) ~= nil, "Preview as Non-Admin control exists")
local previewPos = pageText:find('label = "Preview as Non%-Admin"')
local adminsListPos = pageText:find('label = "Admins"')
assertTrue(previewPos ~= nil and adminsListPos ~= nil and previewPos < adminsListPos, "Preview as Non-Admin is the first Admin control")
local previewChunk = pageText:sub(previewPos, adminsListPos - 1)
assertTrue(not previewChunk:find("adminOnly"), "Preview as Non-Admin is not adminOnly")
assertTrue(previewChunk:find("CanShowImpersonationToggle") ~= nil, "toggle visibility uses CanShowImpersonationToggle")
assertTrue(not previewChunk:find("path%s*="), "toggle has no schema path")

local toc = io.open("SpectrumFederation/SpectrumFederation.toc", "r"):read("*a")
assertTrue(toc:find("modules/LootHelper/Impersonation.lua", 1, true) ~= nil, "Impersonation.lua is in parent TOC")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
