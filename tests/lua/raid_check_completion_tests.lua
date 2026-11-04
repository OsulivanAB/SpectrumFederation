-- Production-Lua tests for Raid Check initiating-admin completion (#449).
-- Run from the repository root: lua5.1 tests/lua/raid_check_completion_tests.lua

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

local PLAYER = "Admin-Garona"

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
        return "Admin"
    end
    return "Unknown"
end

function UnitFullName(unit)
    if unit == "player" then
        return "Admin", "Garona"
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
    return 100
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

function UnitExists()
    return false
end

function InCombatLockdown()
    return false
end

CreateFrame = function()
    return {
        RegisterEvent = function() end,
        SetScript = function() end,
        UnregisterEvent = function() end,
    }
end

C_Timer = {
    After = function() end,
}

SpectrumFederationDB = { lootHelper = { profiles = {}, syncSession = {}, window = {} } }
SpectrumFederationDebugDB = { enabled = false, logs = {} }

local SF = {}
local printed = {}
local systemMessages = {}
local debugInfos = {}

local function loadModule(relative)
    local chunk = assert(loadfile(relative))
    chunk("SpectrumFederation", SF)
end

loadModule("SpectrumFederation/locale/enUS.lua")
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
loadModule("SpectrumFederation/modules/Settings/Store.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/07_Validation.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/18_PublicAPI.lua")
loadModule("SpectrumFederation/modules/RaidEquipment/CheckRun.lua")
loadModule("SpectrumFederation/modules/RaidCheck.lua")

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

function SF:SystemMessage(message)
    systemMessages[#systemMessages + 1] = tostring(message)
end

SF.Debug = {
    Info = function(_, category, fmt, ...)
        debugInfos[#debugInfos + 1] = {
            category = tostring(category),
            message = string.format(tostring(fmt), ...),
        }
    end,
    Warn = function() end,
    Verbose = function() end,
}

local CheckRun = SF.RaidEquipment.CheckRun
local RC = SF.RaidCheck
local Sync = SF.LootHelperSync
local Imp = SF.LootHelperImpersonation

Sync.state = Sync.state or {
    active = false,
    requests = {},
    helpers = {},
}

function Sync:IsSessionActive()
    return self.state.active and true or false
end

function Sync:GetSessionId()
    return self.state.sessionId
end

function Sync:GetSessionProfileId()
    return self.state.profileId
end

function Sync:HasAnnouncedCurrentSession(sessionId)
    return self.state._sessionAnnounced == sessionId
end

function Sync:FindLocalProfileById(profileId)
    local profiles = SF.lootHelperDB and SF.lootHelperDB.profiles
    return profiles and profiles[profileId] or nil
end

local function resetPrintCapture()
    printed = {}
    systemMessages = {}
    debugInfos = {}
end

local function countPrinted(kind, needle)
    local count = 0
    for i = 1, #printed do
        if printed[i][1] == kind and printed[i][2]:find(needle, 1, true) then
            count = count + 1
        end
    end
    return count
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
-- Pure CheckRun helpers
-- ---------------------------------------------------------------------------
local prepared, unprepared, failed = CheckRun.CountClassifiedResults({
    A = { class = CheckRun.CLASS.PREPARED },
    B = { class = CheckRun.CLASS.UNPREPARED },
    C = { class = CheckRun.CLASS.UNPREPARED_AVAILABILITY },
    D = { class = CheckRun.CLASS.INSPECTION_FAILED },
    E = { class = CheckRun.CLASS.PENDING },
})
assertEq(prepared, 1, "count helper counts Prepared once")
assertEq(unprepared, 2, "count helper merges both Unprepared classes")
assertEq(failed, 1, "count helper counts Inspection Failed")
assertEq(
    CheckRun.FormatCompletionSummary("Raid Check", 5, 3, 2),
    "[Raid Check] Complete: 5 Prepared · 3 Unprepared · 2 Inspection Failed",
    "completion summary distinguishes all three outcomes"
)
assertEq(
    CheckRun.FormatCompletionSummary("Pre-Raid Check", 0, 0, 0),
    "[Pre-Raid Check] Complete: 0 Prepared · 0 Unprepared · 0 Inspection Failed",
    "zero-target completion remains honest"
)

-- ---------------------------------------------------------------------------
-- Successful Apply: one chat completion even with debug on / whispers off
-- ---------------------------------------------------------------------------
resetDB()
local profile = makeProfile("Completion Success")
setActive(profile)
assertTrue(profile:AddMember(SF.Member.new("Ready-Garona", "member", "WARRIOR")), "add Ready member")
assertTrue(profile:AddMember(SF.Member.new("Missing-Garona", "member", "WARRIOR")), "add Missing member")
assertTrue(profile:AddMember(SF.Member.new("Failed-Garona", "member", "WARRIOR")), "add Failed member")

local cfg = profile:GetRaidCheckConfig()
cfg.enableWhispersRaid = false
cfg.enableWhispersRaidPrepared = false
cfg.enableWhispersPreRaid = false

local successRun = {
    id = "100",
    profileId = profile:GetProfileId(),
    consequencesApplied = false,
    classified = true,
    classifiedResults = {
        ["Ready-Garona"] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FRESH },
        ["Missing-Garona"] = { class = CheckRun.CLASS.UNPREPARED, missing = { "Enchant" } },
        ["Failed-Garona"] = { class = CheckRun.CLASS.INSPECTION_FAILED },
    },
    targetIds = { "Ready-Garona", "Missing-Garona", "Failed-Garona" },
    groupMemberIds = { "Ready-Garona", "Missing-Garona", "Failed-Garona" },
    rosterMemberIds = profile:GetMemberIds(),
    players = {
        ["Ready-Garona"] = { guid = "g1" },
        ["Missing-Garona"] = { guid = "g2" },
        ["Failed-Garona"] = { guid = "g3" },
    },
    mode = "raid",
    cfg = cfg,
    startedSessionForCheck = false,
}

resetPrintCapture()
RC:_ApplyCheckConsequences(successRun)
assertTrue(successRun.consequencesApplied, "successful run applies consequences once")
assertEq(
    countPrinted("success", "[Raid Check] Complete: 1 Prepared · 1 Unprepared · 1 Inspection Failed"),
    1,
    "successful check prints exactly one completion with distinct outcome counts"
)
local ui = RC:GetLastUiStatus()
assertTrue(ui ~= nil, "completion records last UI status")
assertEq(ui.status, "completed", "last UI status is completed")
assertTrue(ui.message:find("1 Inspection Failed", 1, true), "UI status includes Inspection Failed")
assertEq(ui.kind, "success", "completion UI status is success")

-- Repeated Apply must not re-notify.
resetPrintCapture()
RC:_ApplyCheckConsequences(successRun)
assertEq(countPrinted("success", "Complete:"), 0, "second Apply does not repeat completion chat")
local uiAgain = RC:GetLastUiStatus()
assertEq(uiAgain.message, ui.message, "re-reading status does not invent a new completion")

-- ---------------------------------------------------------------------------
-- Immediate completion: Settings must prefer final status over late "started"
-- ---------------------------------------------------------------------------
local registeredPages = {}
local capturedDef
SF.SettingsUI = SF.SettingsUI or {}
function SF.SettingsUI:RegisterPage(page)
    registeredPages[page.id] = page
end
SF.SettingsUI.DefinitionRenderer = SF.SettingsUI.DefinitionRenderer or {}
function SF.SettingsUI.DefinitionRenderer:Build(_panel, pageDef)
    capturedDef = pageDef
end
function SF.SettingsUI.DefinitionRenderer:Refresh()
end
SF.SettingsUI.Dialogs = SF.SettingsUI.Dialogs or {}
function SF.SettingsUI.Dialogs:ConfirmChoice()
    return true
end
SF.SettingsStore = SF.SettingsStore or {}
function SF.SettingsStore:GetActiveLootHelperProfileObject()
    return SF.lootHelperDB and SF.lootHelperDB.activeProfile
end

loadModule("SpectrumFederation/modules/UI/Settings/Pages/LootHelper.lua")
assertTrue(registeredPages.lootHelperSession ~= nil, "Loot Helper Session page registered")
registeredPages.lootHelperSession:Build({})
assertTrue(capturedDef ~= nil, "session page definition captured")

local raidCheckOnClick
for _, section in ipairs(capturedDef.sections or {}) do
    for _, item in ipairs(section.items or {}) do
        if item.type == "buttonRow" then
            for _, button in ipairs(item) do
                if type(button) == "table" and button.text == "Raid Check" then
                    raidCheckOnClick = button.onClick
                end
            end
        end
    end
end
assertTrue(type(raidCheckOnClick) == "function", "Raid Check Settings button onClick exists")

local messages = {}
local cleared = 0
local ctx = {
    section = {
        SetMessage = function(_, text, kind)
            messages[#messages + 1] = { tostring(text), kind }
        end,
        ClearMessage = function()
            cleared = cleared + 1
            messages = {}
        end,
    },
}

local function activeProfileId()
    local active = SF.lootHelperDB and SF.lootHelperDB.activeProfile
    return active and active.GetProfileId and active:GetProfileId() or nil
end

local origRunRaidCheck = RC.RunRaidCheck
function RC:RunRaidCheck()
    -- Emulate the race: caller still sees "started", but completion already wrote lastUiStatus.
    local state = self:_GetInspectState()
    state.uiStatusGeneration = (state.uiStatusGeneration or 0) + 1
    state.lastUiStatus = {
        status = "completed",
        message = "[Raid Check] Complete: 2 Prepared · 0 Unprepared · 1 Inspection Failed",
        kind = "success",
        generation = state.uiStatusGeneration,
        profileId = activeProfileId(),
    }
    return "started"
end
messages = {}
cleared = 0
raidCheckOnClick(ctx)
assertEq(#messages, 1, "Settings writes one status message after Raid Check click")
assertEq(
    messages[1][1],
    "[Raid Check] Complete: 2 Prepared · 0 Unprepared · 1 Inspection Failed",
    "Settings prefers completion over a late started status"
)
assertEq(messages[1][2], "success", "Settings completion status uses success kind")
RC.RunRaidCheck = origRunRaidCheck

function RC:RunRaidCheck()
    local state = self:_GetInspectState()
    state.uiStatusGeneration = (state.uiStatusGeneration or 0) + 1
    state.lastUiStatus = {
        status = "started",
        message = "Raid Check started.",
        kind = "info",
        generation = state.uiStatusGeneration,
        profileId = activeProfileId(),
    }
    return "started"
end
messages = {}
raidCheckOnClick(ctx)
assertEq(messages[1][1], "Raid Check started.", "in-progress check still shows started")
assertEq(messages[1][2], "info", "started status uses info kind")
RC.RunRaidCheck = origRunRaidCheck

-- Production immediate settle: solo player is always a CollectUnits target, so
-- force ShouldSettle during the inline tick to exercise the completed return path.
resetPrintCapture()
local emptyProfile = makeProfile("Immediate Empty")
setActive(emptyProfile)
local origShouldSettle = CheckRun.ShouldSettle
function CheckRun.ShouldSettle(run, now)
    return true, "test_immediate"
end
local immediateStatus = RC:_StartAdhocRun("raid", emptyProfile, emptyProfile:GetRaidCheckConfig(), {
    profileId = emptyProfile:GetProfileId(),
    startedSessionForCheck = false,
})
CheckRun.ShouldSettle = origShouldSettle
local immediateExpected = "[Raid Check] Complete: 0 Prepared · 1 Unprepared · 0 Inspection Failed"
assertEq(immediateStatus, "completed", "_StartAdhocRun reports completed when consequences already applied")
assertEq(
    countPrinted("success", immediateExpected),
    1,
    "immediate completion prints the full three-count summary"
)
local immediateUi = RC:GetLastUiStatus()
assertEq(immediateUi.status, "completed", "immediate completion overwrites started UI status")
assertEq(immediateUi.message, immediateExpected, "immediate UI status stores the full three-count summary")
assertEq(immediateUi.profileId, emptyProfile:GetProfileId(), "immediate UI status stays bound to the run profile")

-- ---------------------------------------------------------------------------
-- Session-announcement failure: local warning preserved + completion still fires
-- ---------------------------------------------------------------------------
resetPrintCapture()
local announceProfile = makeProfile("Announce Fail")
setActive(announceProfile)
local announceMember = SF.Member.new("Raider-Garona", "member", "MAGE")
assertTrue(announceMember ~= nil, "announce raider member object created")
assertTrue(announceProfile:AddMember(announceMember), "add announce raider")
local failedAnnounceRun = {
    id = "200",
    profileId = announceProfile:GetProfileId(),
    consequencesApplied = false,
    classified = true,
    classifiedResults = {
        ["Raider-Garona"] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FRESH },
    },
    targetIds = { "Raider-Garona" },
    groupMemberIds = { "Raider-Garona" },
    rosterMemberIds = announceProfile:GetMemberIds(),
    players = { ["Raider-Garona"] = { guid = "g-announce" } },
    mode = "raid",
    cfg = announceProfile:GetRaidCheckConfig(),
    startedSessionForCheck = true,
    expectedSessionId = "SES-FAIL",
    expectedSessionProfileId = announceProfile:GetProfileId(),
    sessionStartFailed = true,
}
Sync.state.active = false
Sync.state.sessionId = nil
Sync.state.profileId = nil
Sync.state._sessionAnnounced = nil
RC:_ApplyCheckConsequences(failedAnnounceRun)
assertEq(
    countPrinted("warn", "Loot Helper session synchronization could not be established"),
    1,
    "announce failure keeps the local-only synchronization warning"
)
assertEq(
    countPrinted("success", "[Raid Check] Complete: 1 Prepared · 0 Unprepared · 0 Inspection Failed"),
    1,
    "announce failure still emits the completion summary"
)
assertTrue(failedAnnounceRun.consequencesApplied, "announce-failure consequences apply locally once")
resetPrintCapture()
RC:_ApplyCheckConsequences(failedAnnounceRun)
assertEq(countPrinted("success", "Complete:"), 0, "announce-failure completion is not repeated")
assertEq(countPrinted("warn", "synchronization could not be established"), 0, "announce-failure warning is not repeated")

-- ---------------------------------------------------------------------------
-- Permission abort: error status, no success completion
-- ---------------------------------------------------------------------------
resetPrintCapture()
local abortProfile = makeProfile("Abort Admin")
setActive(abortProfile)
assertTrue(Imp:Enable(), "enable impersonation for abort path")
local abortRun = {
    id = "300",
    profileId = abortProfile:GetProfileId(),
    consequencesApplied = false,
    classified = true,
    classifiedResults = {
        ["Ready-Garona"] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FRESH },
    },
    targetIds = { "Ready-Garona" },
    groupMemberIds = { "Ready-Garona" },
    rosterMemberIds = abortProfile:GetMemberIds(),
    players = { ["Ready-Garona"] = { guid = "g-abort" } },
    mode = "raid",
    cfg = abortProfile:GetRaidCheckConfig(),
}
RC:_ApplyCheckConsequences(abortRun)
assertEq(countPrinted("success", "Complete:"), 0, "impersonation abort does not print success completion")
assertEq(countPrinted("error", "viewing the profile as a non-admin"), 1, "impersonation abort prints the permission error")
local abortUi = RC:GetLastUiStatus()
assertEq(abortUi.status, "error", "impersonation abort records error UI status")
Imp:Disable("completion-tests-cleanup")

-- ---------------------------------------------------------------------------
-- Codex #458: successful check then failed new attempt must not reuse success
-- ---------------------------------------------------------------------------
resetDB()
local priorProfile = makeProfile("Prior Success")
setActive(priorProfile)
local priorRun = {
    id = "prior",
    profileId = priorProfile:GetProfileId(),
    consequencesApplied = false,
    classified = true,
    classifiedResults = {
        ["Admin-Garona"] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FRESH },
    },
    targetIds = { "Admin-Garona" },
    groupMemberIds = { "Admin-Garona" },
    rosterMemberIds = priorProfile:GetMemberIds(),
    players = { ["Admin-Garona"] = { guid = "g-prior" } },
    mode = "raid",
    cfg = priorProfile:GetRaidCheckConfig(),
}
resetPrintCapture()
RC:_ApplyCheckConsequences(priorRun)
assertEq(RC:GetLastUiStatus().status, "completed", "prior success records completed UI status")
local priorGen = RC:GetUiStatusGeneration()

SF.lootHelperDB.activeProfile = nil
SF.lootHelperDB.activeProfileId = nil
messages = {}
local failStatus = RC:BeginCheck("raid")
assertEq(failStatus, "error", "missing profile fails a new BeginCheck")
assertTrue(RC:GetUiStatusGeneration() > priorGen, "failed new attempt bumps UI status generation")
assertEq(RC:GetLastUiStatus().status, "error", "failed new attempt records error UI status")
assertTrue(not tostring(RC:GetLastUiStatus().message or ""):find("Complete:", 1, true),
    "failed new attempt does not keep the prior Complete summary")

-- Production Settings button path for Raid Check and Pre-Raid Check
local preRaidOnClick
raidCheckOnClick = nil
for _, section in ipairs(capturedDef.sections or {}) do
    for _, item in ipairs(section.items or {}) do
        if item.type == "buttonRow" then
            for _, button in ipairs(item) do
                if type(button) == "table" and button.text == "Raid Check" then
                    raidCheckOnClick = button.onClick
                elseif type(button) == "table" and button.text == "Pre-Raid Check" then
                    preRaidOnClick = button.onClick
                end
            end
        end
    end
end
assertTrue(type(raidCheckOnClick) == "function", "Raid Check onClick still available")
assertTrue(type(preRaidOnClick) == "function", "Pre-Raid Check onClick exists")

messages = {}
raidCheckOnClick(ctx)
assertEq(#messages, 1, "failed Raid Check click writes one Settings message")
assertTrue(messages[1][1]:find("could not be started", 1, true),
    "Raid Check Settings shows start failure instead of prior success")
assertEq(messages[1][2], "error", "Raid Check failure Settings kind is error")

messages = {}
preRaidOnClick(ctx)
assertEq(#messages, 1, "failed Pre-Raid Check click writes one Settings message")
assertTrue(messages[1][1]:find("could not be started", 1, true),
    "Pre-Raid Check Settings shows start failure instead of prior success")
assertEq(messages[1][2], "error", "Pre-Raid Check failure Settings kind is error")

-- ---------------------------------------------------------------------------
-- Delayed completion updates an already-open Settings page via listener
-- ---------------------------------------------------------------------------
resetDB()
local delayedProfile = makeProfile("Delayed Complete")
setActive(delayedProfile)
local sessionPanel = {
    shown = true,
    __sfSections = {
        session = {
            messages = {},
            SetMessage = function(self, text, kind)
                self.messages[#self.messages + 1] = { tostring(text), kind }
            end,
        },
    },
    IsShown = function(self) return self.shown end,
    HookScript = function(self, event, fn)
        self.hooks = self.hooks or {}
        self.hooks[event] = fn
    end,
}
local beforeListeners = RC:CountUiStatusListeners()
registeredPages.lootHelperSession:Build(sessionPanel)
assertTrue(type(sessionPanel.hooks) == "table", "Session page hooks OnShow/OnHide")
sessionPanel.hooks.OnShow()
assertEq(RC:CountUiStatusListeners(), beforeListeners + 1, "open Session page registers one UI status listener")

-- Begin a real delayed run: start without settling, then apply later.
Sync.state.active = true
Sync.state.sessionId = "SES-DELAY"
Sync.state.profileId = delayedProfile:GetProfileId()
Sync.state._sessionAnnounced = "SES-DELAY"
local origShouldSettle2 = CheckRun.ShouldSettle
function CheckRun.ShouldSettle()
    return false, "test_hold"
end
resetPrintCapture()
sessionPanel.__sfSections.session.messages = {}
local started = RC:BeginCheck("raid")
CheckRun.ShouldSettle = origShouldSettle2
assertEq(started, "started", "held check returns started")
assertEq(RC:GetLastUiStatus().status, "started", "delayed path records started UI status")
assertTrue(#sessionPanel.__sfSections.session.messages >= 1, "listener received started status")
assertTrue(sessionPanel.__sfSections.session.messages[#sessionPanel.__sfSections.session.messages][1]:find("started", 1, true),
    "open Settings shows started while check runs")

local delayedRun = RC:_GetInspectState().adhocRun
assertTrue(delayedRun ~= nil, "adhoc run remains for delayed completion")
delayedRun.classified = true
delayedRun.classifiedResults = {
    ["Admin-Garona"] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FRESH },
}
delayedRun.targetIds = { "Admin-Garona" }
delayedRun.groupMemberIds = { "Admin-Garona" }
delayedRun.rosterMemberIds = delayedProfile:GetMemberIds()
delayedRun.players = { ["Admin-Garona"] = { guid = "g-delay" } }
sessionPanel.__sfSections.session.messages = {}
resetPrintCapture()
RC:_ApplyCheckConsequences(delayedRun)
RC:_GetInspectState().adhocRun = nil
assertEq(countPrinted("success", "Complete:"), 1, "delayed completion prints one chat summary")
assertEq(RC:GetLastUiStatus().status, "completed", "delayed completion records completed UI status")
assertEq(#sessionPanel.__sfSections.session.messages, 1, "listener updates Settings once on delayed completion")
assertTrue(sessionPanel.__sfSections.session.messages[1][1]:find("Complete:", 1, true),
    "open Settings replaces started with completion summary")

-- ---------------------------------------------------------------------------
-- Session-prompt choices, cancellation, and startup failure
-- ---------------------------------------------------------------------------
resetDB()
local promptProfile = makeProfile("Prompt Flow")
setActive(promptProfile)
Sync.state.active = false
local yesCb, noCb, cancelCb
function SF.SettingsUI.Dialogs:ConfirmChoice(_msg, _yes, _no, onYes, onNo, onCancel)
    yesCb, noCb, cancelCb = onYes, onNo, onCancel
    return true
end
sessionPanel.__sfSections.session.messages = {}
local promptStatus = RC:BeginCheck("raid")
assertEq(promptStatus, "prompt", "no-session BeginCheck opens prompt")
assertEq(RC:GetLastUiStatus().status, "prompt", "prompt records prompt UI status")
assertTrue(type(cancelCb) == "function", "prompt captures Cancel callback")
cancelCb()
assertEq(RC:GetLastUiStatus().status, "cancelled", "Cancel records cancelled UI status")
assertTrue(RC:GetLastUiStatus().message:find("cancelled", 1, true), "Cancel message is localized cancelled text")

yesCb, noCb, cancelCb = nil, nil, nil
promptStatus = RC:BeginCheck("pre")
assertEq(promptStatus, "prompt", "Pre-Raid Check also opens prompt without a session")
assertTrue(type(yesCb) == "function", "prompt captures Yes callback")
function Sync:StartSession()
    return nil
end
sessionPanel.__sfSections.session.messages = {}
yesCb()
assertEq(RC:GetLastUiStatus().status, "error", "Yes-path StartSession failure records error UI status")
assertTrue(RC:GetLastUiStatus().message:find("Could not start a Loot Helper session", 1, true),
    "Yes-path failure replaces prompt text with session-start failure")

yesCb, noCb, cancelCb = nil, nil, nil
promptStatus = RC:BeginCheck("raid")
assertEq(promptStatus, "prompt", "prompt reopens after prior failure")
assertTrue(type(noCb) == "function", "prompt captures No callback")
local origShouldSettle3 = CheckRun.ShouldSettle
function CheckRun.ShouldSettle()
    return true, "test_no_path"
end
resetPrintCapture()
noCb()
CheckRun.ShouldSettle = origShouldSettle3
local noPathExpected = "[Raid Check] Complete: 0 Prepared · 1 Unprepared · 0 Inspection Failed"
assertEq(RC:GetLastUiStatus().status, "completed", "No-path settles immediately to completed")
assertEq(
    countPrinted("success", noPathExpected),
    1,
    "No-path prints exactly one expected three-count completion summary"
)
assertEq(RC:GetLastUiStatus().message, noPathExpected, "No-path UI status stores the expected completion summary")

-- ---------------------------------------------------------------------------
-- Page close/reopen: listeners converge; no duplicate completion chat
-- ---------------------------------------------------------------------------
local listenerBefore = RC:CountUiStatusListeners()
sessionPanel.hooks.OnHide()
assertEq(RC:CountUiStatusListeners(), listenerBefore - 1, "OnHide unregisters the UI status listener")
sessionPanel.hooks.OnShow()
assertEq(RC:CountUiStatusListeners(), listenerBefore, "OnShow re-registers exactly one listener")
for _ = 1, 20 do
    sessionPanel.hooks.OnHide()
    sessionPanel.hooks.OnShow()
end
assertEq(RC:CountUiStatusListeners(), listenerBefore, "repeated open/close keeps listener count converged")

resetPrintCapture()
local reopenUi = RC:GetLastUiStatus()
sessionPanel.hooks.OnHide()
sessionPanel.hooks.OnShow()
assertEq(countPrinted("success", "Complete:"), 0, "page reopen does not reprint completion chat")
assertEq(RC:GetLastUiStatus().message, reopenUi and reopenUi.message or nil,
    "page reopen does not invent a new completion status")

-- ---------------------------------------------------------------------------
-- Profile scope: complete A, switch to B, reopen Session must clear stale text
-- ---------------------------------------------------------------------------
resetDB()
local profileA = makeProfile("Scope A")
local profileB = makeProfile("Scope B")
setActive(profileA)
local scopeSection = {
    messages = {},
    cleared = 0,
    SetMessage = function(self, text, kind)
        self.messages[#self.messages + 1] = { tostring(text), kind }
    end,
    ClearMessage = function(self)
        self.cleared = self.cleared + 1
        self.messages = {}
    end,
}
sessionPanel.__sfSections.session = scopeSection
sessionPanel.shown = true
sessionPanel.hooks.OnShow()
local scopeRun = {
    id = "scope-a",
    profileId = profileA:GetProfileId(),
    consequencesApplied = false,
    classified = true,
    classifiedResults = {
        ["Admin-Garona"] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FRESH },
    },
    targetIds = { "Admin-Garona" },
    groupMemberIds = { "Admin-Garona" },
    rosterMemberIds = profileA:GetMemberIds(),
    players = { ["Admin-Garona"] = { guid = "g-scope-a" } },
    mode = "raid",
    cfg = profileA:GetRaidCheckConfig(),
}
resetPrintCapture()
RC:_ApplyCheckConsequences(scopeRun)
assertEq(RC:GetLastUiStatus().status, "completed", "profile A completion records completed UI status")
assertTrue(#scopeSection.messages >= 1, "open Session receives profile A completion")
assertTrue(scopeSection.messages[#scopeSection.messages][1]:find("Complete:", 1, true),
    "Session shows profile A completion summary")
local aSummary = scopeSection.messages[#scopeSection.messages][1]
setActive(profileB)
sessionPanel.hooks.OnHide()
scopeSection.cleared = 0
scopeSection.messages = { { aSummary, "success" } }
resetPrintCapture()
sessionPanel.hooks.OnShow()
assertTrue(scopeSection.cleared >= 1, "reopening Session under profile B clears stale Raid Check text")
assertEq(#scopeSection.messages, 0, "profile B Session does not keep profile A completion text")
assertEq(countPrinted("success", "Complete:"), 0, "profile switch reopen does not reprint completion chat")
registeredPages.lootHelperSession:Refresh(sessionPanel)
assertEq(#scopeSection.messages, 0, "Session Refresh under profile B keeps Raid Check text cleared")

-- Switch profiles before delayed completion: in-flight run stays on A; B must not show it.
resetDB()
profileA = makeProfile("Delayed Scope A")
profileB = makeProfile("Delayed Scope B")
setActive(profileA)
scopeSection.messages = {}
scopeSection.cleared = 0
sessionPanel.__sfSections.session = scopeSection
sessionPanel.shown = true
sessionPanel.hooks.OnShow()
Sync.state.active = true
Sync.state.sessionId = "SES-SCOPE"
Sync.state.profileId = profileA:GetProfileId()
Sync.state._sessionAnnounced = "SES-SCOPE"
local origShouldSettleScope = CheckRun.ShouldSettle
function CheckRun.ShouldSettle()
    return false, "test_hold_scope"
end
resetPrintCapture()
local held = RC:BeginCheck("raid")
CheckRun.ShouldSettle = origShouldSettleScope
assertEq(held, "started", "scoped delayed check starts on profile A")
assertTrue(scopeSection.messages[#scopeSection.messages][1]:find("started", 1, true),
    "open Settings shows started for profile A")
local delayedScopeRun = RC:_GetInspectState().adhocRun
assertTrue(delayedScopeRun ~= nil, "scoped delayed run remains in flight")
assertEq(delayedScopeRun.profileId, profileA:GetProfileId(), "in-flight run stays bound to profile A")
setActive(profileB)
scopeSection.cleared = 0
scopeSection.messages = { { "Raid Check started.", "info" } }
sessionPanel.hooks.OnHide()
sessionPanel.hooks.OnShow()
assertTrue(scopeSection.cleared >= 1, "switching to B before completion clears A's started text")
assertEq(#scopeSection.messages, 0, "profile B does not display A's in-flight started status")
delayedScopeRun.classified = true
delayedScopeRun.classifiedResults = {
    ["Admin-Garona"] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FRESH },
}
delayedScopeRun.targetIds = { "Admin-Garona" }
delayedScopeRun.groupMemberIds = { "Admin-Garona" }
delayedScopeRun.rosterMemberIds = profileA:GetMemberIds()
delayedScopeRun.players = { ["Admin-Garona"] = { guid = "g-scope-delay" } }
scopeSection.cleared = 0
scopeSection.messages = {}
resetPrintCapture()
RC:_ApplyCheckConsequences(delayedScopeRun)
RC:_GetInspectState().adhocRun = nil
assertEq(countPrinted("success", "[Raid Check] Complete: 1 Prepared · 0 Unprepared · 0 Inspection Failed"), 1,
    "delayed A completion still prints exactly once while B is active")
assertEq(RC:GetLastUiStatus().profileId, profileA:GetProfileId(), "delayed completion remains bound to profile A")
assertEq(#scopeSection.messages, 0, "listener under profile B does not render A's delayed completion")
assertTrue(scopeSection.cleared >= 1, "listener clears when delayed A status is rejected under B")

-- Missing-profile failure: current attempt error still displays with no active profile.
resetDB()
local priorForMissing = makeProfile("Prior For Missing")
setActive(priorForMissing)
RC:_ApplyCheckConsequences({
    id = "prior-missing",
    profileId = priorForMissing:GetProfileId(),
    consequencesApplied = false,
    classified = true,
    classifiedResults = {
        ["Admin-Garona"] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FRESH },
    },
    targetIds = { "Admin-Garona" },
    groupMemberIds = { "Admin-Garona" },
    rosterMemberIds = priorForMissing:GetMemberIds(),
    players = { ["Admin-Garona"] = { guid = "g-prior-missing" } },
    mode = "raid",
    cfg = priorForMissing:GetRaidCheckConfig(),
})
SF.lootHelperDB.activeProfile = nil
SF.lootHelperDB.activeProfileId = nil
messages = {}
cleared = 0
local missingStatus = RC:BeginCheck("raid")
assertEq(missingStatus, "error", "BeginCheck without a profile returns error")
assertEq(RC:GetLastUiStatus().status, "error", "missing-profile attempt records error UI status")
assertTrue(RC:GetLastUiStatus().profileId == nil or RC:GetLastUiStatus().profileId == "",
    "missing-profile error is not attributed to a selected profile")
raidCheckOnClick(ctx)
assertEq(#messages, 1, "missing-profile failure still writes Settings status")
assertTrue(messages[1][1]:find("could not be started", 1, true),
    "missing-profile Settings shows the current attempt failure")
assertEq(messages[1][2], "error", "missing-profile Settings kind is error")

-- Localized started status for both check modes (distinct translated values).
resetDB()
local localeProfile = makeProfile("Locale Started")
setActive(localeProfile)
local origLocaleText = SF.LocaleText
function SF.LocaleText(key, default)
    if key == "RAID_CHECK_UI_STARTED" then
        return "LOC_STARTED:%s"
    end
    if key == "RAID_CHECK_MODE_RAID" then
        return "LOC_RAID"
    end
    if key == "RAID_CHECK_MODE_PRE" then
        return "LOC_PRE"
    end
    if origLocaleText then
        return origLocaleText(key, default)
    end
    return default
end
Sync.state.active = true
Sync.state.sessionId = "SES-LOC"
Sync.state.profileId = localeProfile:GetProfileId()
Sync.state._sessionAnnounced = "SES-LOC"
local origShouldSettleLoc = CheckRun.ShouldSettle
function CheckRun.ShouldSettle()
    return false, "test_hold_locale"
end
scopeSection.messages = {}
sessionPanel.__sfSections.session = scopeSection
sessionPanel.shown = true
sessionPanel.hooks.OnShow()
resetPrintCapture()
local raidStarted = RC:BeginCheck("raid")
assertEq(raidStarted, "started", "localized raid check starts")
assertEq(RC:GetLastUiStatus().message, "LOC_STARTED:LOC_RAID",
    "stored raid started status uses localized template and mode label")
assertEq(scopeSection.messages[#scopeSection.messages][1], "LOC_STARTED:LOC_RAID",
    "listener receives localized raid started status")
RC:_GetInspectState().adhocRun = nil
scopeSection.messages = {}
local preStarted = RC:BeginCheck("pre")
assertEq(preStarted, "started", "localized pre-raid check starts")
assertEq(RC:GetLastUiStatus().message, "LOC_STARTED:LOC_PRE",
    "stored pre-raid started status uses localized template and mode label")
assertEq(scopeSection.messages[#scopeSection.messages][1], "LOC_STARTED:LOC_PRE",
    "listener receives localized pre-raid started status")
CheckRun.ShouldSettle = origShouldSettleLoc
SF.LocaleText = origLocaleText
RC:_GetInspectState().adhocRun = nil
messages = {}
function RC:RunRaidCheck()
    local state = self:_GetInspectState()
    state.uiStatusGeneration = (state.uiStatusGeneration or 0) + 1
    state.lastUiStatus = {
        status = "started",
        message = "LOC_STARTED:LOC_RAID",
        kind = "info",
        generation = state.uiStatusGeneration,
        profileId = activeProfileId(),
    }
    return "started"
end
function SF.LocaleText(key, default)
    if key == "RAID_CHECK_UI_STARTED" then
        return "LOC_STARTED:%s"
    end
    if key == "RAID_CHECK_MODE_RAID" then
        return "LOC_RAID"
    end
    if key == "RAID_CHECK_MODE_PRE" then
        return "LOC_PRE"
    end
    if origLocaleText then
        return origLocaleText(key, default)
    end
    return default
end
raidCheckOnClick(ctx)
assertEq(messages[1][1], "LOC_STARTED:LOC_RAID", "button path shows localized started status")
RC.RunRaidCheck = origRunRaidCheck
SF.LocaleText = origLocaleText

-- ---------------------------------------------------------------------------
-- Missing admin permission + completion with debug/whispers disabled
-- ---------------------------------------------------------------------------
resetDB()
local whisperProfile = makeProfile("Whisper Off")
setActive(whisperProfile)
local cfgQuiet = whisperProfile:GetRaidCheckConfig()
cfgQuiet.enableWhispersRaid = false
cfgQuiet.enableWhispersRaidPrepared = false
cfgQuiet.enableWhispersPreRaid = false
local quietRun = {
    id = "quiet",
    profileId = whisperProfile:GetProfileId(),
    consequencesApplied = false,
    classified = true,
    classifiedResults = {
        ["Admin-Garona"] = { class = CheckRun.CLASS.PREPARED, verified = CheckRun.VERIFIED.FRESH },
        ["Fail-Garona"] = { class = CheckRun.CLASS.INSPECTION_FAILED },
    },
    targetIds = { "Admin-Garona", "Fail-Garona" },
    groupMemberIds = { "Admin-Garona", "Fail-Garona" },
    rosterMemberIds = whisperProfile:GetMemberIds(),
    players = {
        ["Admin-Garona"] = { guid = "gq1" },
        ["Fail-Garona"] = { guid = "gq2" },
    },
    mode = "raid",
    cfg = cfgQuiet,
}
assertTrue(whisperProfile:AddMember(SF.Member.new("Fail-Garona", "member", "WARRIOR")), "add Fail member")
quietRun.rosterMemberIds = whisperProfile:GetMemberIds()
resetPrintCapture()
RC:_ApplyCheckConsequences(quietRun)
assertEq(
    countPrinted("success", "[Raid Check] Complete: 1 Prepared · 0 Unprepared · 1 Inspection Failed"),
    1,
    "completion prints with whispers disabled"
)
assertTrue(#debugInfos >= 1, "debug logger still receives Complete diagnostics when enabled in test harness")

resetDB()
local noAdmin = makeProfile("No Admin")
-- Remove current user from admins while keeping profile active.
noAdmin._adminUsers = { "Other-Garona" }
setActive(noAdmin)
resetPrintCapture()
local noAdminStatus = RC:BeginCheck("raid")
assertEq(noAdminStatus, "error", "non-admin BeginCheck fails")
assertEq(RC:GetLastUiStatus().status, "error", "non-admin failure records error UI status")
assertEq(countPrinted("error", "Only admins can run raid checks."), 1, "non-admin prints permission error")

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end

