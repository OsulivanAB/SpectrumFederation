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
local ctx = {
    section = {
        SetMessage = function(_, text, kind)
            messages[#messages + 1] = { tostring(text), kind }
        end,
        ClearMessage = function() end,
    },
}

local origRunRaidCheck = RC.RunRaidCheck
function RC:RunRaidCheck()
    -- Emulate the race: caller still sees "started", but completion already wrote lastUiStatus.
    local state = self:_GetInspectState()
    state.lastUiStatus = {
        status = "completed",
        message = "[Raid Check] Complete: 2 Prepared · 0 Unprepared · 1 Inspection Failed",
        kind = "success",
    }
    return "started"
end
messages = {}
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
    state.lastUiStatus = {
        status = "started",
        message = "Raid Check started.",
        kind = "info",
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
assertEq(immediateStatus, "completed", "_StartAdhocRun reports completed when consequences already applied")
assertEq(countPrinted("success", "Complete:"), 1, "immediate completion prints one summary")
assertTrue(
    countPrinted("success", "Inspection Failed") == 1 or countPrinted("success", "Prepared") == 1,
    "immediate completion names Prepared/Unprepared/Inspection Failed outcomes"
)
local immediateUi = RC:GetLastUiStatus()
assertEq(immediateUi.status, "completed", "immediate completion overwrites started UI status")

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

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
