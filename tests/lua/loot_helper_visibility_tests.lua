-- Production-Lua tests for Loot Helper close / manual-hidden visibility.
-- Run from the repository root: lua5.1 tests/lua/loot_helper_visibility_tests.lua

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

function string.trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

UIParent = {
    width = 1920,
    height = 1080,
}
function UIParent:GetWidth()
    return self.width
end
function UIParent:GetHeight()
    return self.height
end

local inRaid = true
function IsInRaid()
    return inRaid
end

C_Timer = {
    After = function(_, fn)
        fn()
    end,
}

local prints = {}
local sessionEndCount = 0
local sessionStartCount = 0
local manualSyncCount = 0
local equipmentHideCount = 0
local equipmentShown = false
local listenerCount = 0
local refreshCount = 0

local function resetPrints()
    prints = {}
end

SpectrumFederationDB = {
    lootHelper = {
        enabled = true,
        showWindowOutsideRaid = false,
        activeProfileId = "profile-1",
        profiles = {
            ["profile-1"] = { name = "Test" },
        },
        window = {
            width = 480,
            height = 520,
            expandedHeight = 520,
            minimized = false,
        },
    },
}

local SF = {
    lootHelperDB = SpectrumFederationDB.lootHelper,
    LootHelperWindow = {},
    SettingsStore = {
        Get = function(_, path)
            if path == "lootHelper.enabled" then
                return SpectrumFederationDB.lootHelper.enabled
            end
            if path == "lootHelper.showWindowOutsideRaid" then
                return SpectrumFederationDB.lootHelper.showWindowOutsideRaid
            end
            if path == "lootHelper.lockLootWindow" then
                return SpectrumFederationDB.lootHelper.lockLootWindow
            end
            return nil
        end,
        Set = function(_, path, value)
            if path == "lootHelper.enabled" then
                SpectrumFederationDB.lootHelper.enabled = value and true or false
                SF.lootHelperDB.enabled = SpectrumFederationDB.lootHelper.enabled
            end
        end,
        GetActiveLootHelperProfileId = function()
            return SpectrumFederationDB.lootHelper.activeProfileId
        end,
    },
    Debug = {
        Verbose = function() end,
        Info = function() end,
        Warn = function() end,
        Error = function() end,
    },
}

function SF:GetActiveProfile()
    if not SpectrumFederationDB.lootHelper.activeProfileId then
        return nil
    end
    return {
        GetPointName = function()
            return "Points"
        end,
        IsCurrentUserAdmin = function()
            return true
        end,
        IsRewardPotMode = function()
            return false
        end,
    }
end

function SF:PrintInfo(msg)
    prints[#prints + 1] = { "info", tostring(msg) }
end

function SF:PrintSuccess(msg)
    prints[#prints + 1] = { "success", tostring(msg) }
end

function SF:PrintWarning(msg)
    prints[#prints + 1] = { "warn", tostring(msg) }
end

function SF:PrintError(msg)
    prints[#prints + 1] = { "error", tostring(msg) }
end

SF.LootHelperSync = {
    IsSessionActive = function()
        return true
    end,
    StartSession = function()
        sessionStartCount = sessionStartCount + 1
        return "session-1"
    end,
    EndSession = function()
        sessionEndCount = sessionEndCount + 1
        return true
    end,
    RequestManualSync = function()
        manualSyncCount = manualSyncCount + 1
        return true, "already_in_sync"
    end,
}

SF.RaidCheck = {
    RegisterTroubleshootingListener = function()
        listenerCount = listenerCount + 1
    end,
    UnregisterTroubleshootingListener = function()
        if listenerCount > 0 then
            listenerCount = listenerCount - 1
        end
    end,
}

local constChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/Constants.lua"))
constChunk("SpectrumFederation", SF)
local windowChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/Window.lua"))
windowChunk("SpectrumFederation", SF)
local controllerChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/Controller.lua"))
controllerChunk("SpectrumFederation", SF)

local slashChunk = assert(loadfile("SpectrumFederation/modules/SlashCommands.lua"))
slashChunk("SpectrumFederation", SF)

local LH = SF.LootHelperWindow
local Window = LH.Window
local Controller = LH.Controller
local C = LH.Constants

LH.RosterModel = {
    Build = function()
        return {}, {}
    end,
}

LH.EquipmentWindow = {
    Hide = function()
        equipmentShown = false
        equipmentHideCount = equipmentHideCount + 1
    end,
    IsShown = function()
        return equipmentShown
    end,
}

LH.Style = {
    Apply = function() end,
}

local originalRequestRefresh = Controller.RequestRefresh
function Controller:RequestRefresh(reason)
    refreshCount = refreshCount + 1
    return originalRequestRefresh(self, reason)
end

local originalInit = Controller.Init
function Controller:Init()
    -- Tests install a mock frame; skip CreateFrame-based construction.
    self._inited = true
end

local function makeFrame(width, height)
    local frame = {
        width = width or 480,
        height = height or 520,
        left = 720,
        bottom = 280,
        point = "CENTER",
        relativeTo = UIParent,
        relativePoint = "CENTER",
        x = 0,
        y = 0,
        shown = false,
        __sfMinimized = false,
        __sfLocked = false,
        Content = {
            shown = true,
        },
    }

    function frame.Content:IsShown()
        return self.shown
    end

    function frame.Content:SetShown(value)
        self.shown = value and true or false
    end

    function frame:IsShown()
        return self.shown
    end

    function frame:Show()
        self.shown = true
    end

    function frame:Hide()
        self.shown = false
    end

    function frame:GetLeft()
        return self.left
    end

    function frame:GetRight()
        return self.left + self.width
    end

    function frame:GetBottom()
        return self.bottom
    end

    function frame:GetTop()
        return self.bottom + self.height
    end

    function frame:GetWidth()
        return self.width
    end

    function frame:GetHeight()
        return self.height
    end

    function frame:GetSize()
        return self.width, self.height
    end

    function frame:GetPoint()
        return self.point, self.relativeTo, self.relativePoint, self.x, self.y
    end

    function frame:ClearAllPoints()
        self.point = nil
        self.relativeTo = nil
        self.relativePoint = nil
        self.x = nil
        self.y = nil
    end

    function frame:SetResizable()
    end

    function frame:SetResizeBounds()
    end

    function frame:SetPoint(point, relativeTo, relativePoint, x, y)
        self.point = point
        self.relativeTo = relativeTo
        self.relativePoint = relativePoint
        self.x = x
        self.y = y
        if point == "TOPLEFT" and relativePoint == "BOTTOMLEFT" then
            self.left = x
            self.bottom = y - self.height
        end
    end

    function frame:SetSize(width, height)
        local oldHeight = self.height
        if self.point == "TOPLEFT" then
            local top = self.bottom + oldHeight
            self.width = width
            self.height = height
            self.bottom = top - height
            return
        end
        self.width = width
        self.height = height
    end

    return frame
end

local function resetState()
    inRaid = true
    SpectrumFederationDB.lootHelper.enabled = true
    SpectrumFederationDB.lootHelper.showWindowOutsideRaid = false
    SpectrumFederationDB.lootHelper.activeProfileId = "profile-1"
    SpectrumFederationDB.lootHelper.lockLootWindow = false
    SpectrumFederationDB.lootHelper.window = {
        width = 480,
        height = 520,
        expandedHeight = 520,
        minimized = false,
    }
    SF.lootHelperDB = SpectrumFederationDB.lootHelper
    Controller._manuallyHidden = false
    Controller._inited = true
    Controller._refreshScheduled = false
    Controller._readinessListenerBound = false
    Controller._rosterView = nil
    refreshCount = 0
    equipmentHideCount = 0
    equipmentShown = true
    listenerCount = 0
    sessionEndCount = 0
    sessionStartCount = 0
    manualSyncCount = 0
    resetPrints()
    Window._frame = makeFrame(480, 520)
    Window._frame.shown = true
    Window._frame.__sfMinimized = false
end

local function printedLevel(level)
    local count = 0
    for i = 1, #prints do
        if prints[i][1] == level then
            count = count + 1
        end
    end
    return count
end

local function printedContains(level, snippet)
    for i = 1, #prints do
        if prints[i][1] == level and tostring(prints[i][2]):find(snippet, 1, true) then
            return true
        end
    end
    return false
end

resetState()
Controller:EvaluateVisibility("test-initial")
assertTrue(Controller:IsWindowShown(), "eligible window is shown")
assertEq(Controller:GetWindowVisibilityActionText(), "Hide Loot Window", "settings text is Hide when shown")

-- Close hides the main window and equipment, without disabling LH or ending sessions.
resetState()
local enabledBefore = SpectrumFederationDB.lootHelper.enabled
Window._frame.__sfMinimized = false
Controller:OnCloseClicked()
assertFalse(Controller:IsWindowShown(), "X hides the main window")
assertTrue(Controller:IsManuallyHidden(), "X sets runtime manual-hidden")
assertFalse(equipmentShown, "X hides the equipment window")
assertTrue(equipmentHideCount >= 1, "equipment Hide is invoked")
assertEq(SpectrumFederationDB.lootHelper.enabled, enabledBefore, "X does not change lootHelper.enabled")
assertEq(sessionEndCount, 0, "X does not end an active session")
assertEq(Controller:GetWindowVisibilityActionText(), "Show Loot Window", "settings text is Show when hidden")

-- GROUP_ROSTER_UPDATE and other automatic reevaluation must not reopen.
resetState()
Controller:HideWindow("CloseButton")
assertFalse(Controller:IsWindowShown(), "HideWindow hides the frame")
Controller:OnEvent("GROUP_ROSTER_UPDATE")
assertFalse(Controller:IsWindowShown(), "GROUP_ROSTER_UPDATE does not reopen a manually hidden window")
Controller:OnEvent("PLAYER_ENTERING_WORLD")
assertFalse(Controller:IsWindowShown(), "PLAYER_ENTERING_WORLD does not reopen a manually hidden window")
Controller:EvaluateVisibility("SettingsChanged:lootHelper.showWindowOutsideRaid")
assertFalse(Controller:IsWindowShown(), "settings visibility reevaluation respects manual-hidden")
assertTrue(SpectrumFederationDB.lootHelper.enabled, "automatic reevaluation does not disable Loot Helper")

-- Explicit Show via controller API (slash / settings) clears suppression.
resetState()
Controller:HideWindow("CloseButton")
local ok, why = Controller:ShowWindow("Slash:/sf loot")
assertTrue(ok, "ShowWindow reports eligibility")
assertEq(why, "in_raid", "ShowWindow keeps raid eligibility")
assertFalse(Controller:IsManuallyHidden(), "ShowWindow clears manual-hidden")
assertTrue(Controller:IsWindowShown(), "/sf loot show path reopens when eligible")

resetState()
Controller:HideWindow("CloseButton")
ok, why = Controller:ShowWindow("Settings:LootWindow")
assertTrue(ok, "settings ShowWindow is eligible")
assertTrue(Controller:IsWindowShown(), "settings Show reopens when eligible")
assertEq(Controller:GetWindowVisibilityActionText(), "Hide Loot Window", "settings text updates after Show")

-- Explicit Show does not toggle an already-visible window off.
resetState()
Controller:EvaluateVisibility("shown")
assertTrue(Controller:IsWindowShown(), "window starts shown")
Controller:ShowWindow("Slash:/sf loot")
assertTrue(Controller:IsWindowShown(), "ShowWindow leaves an already-visible window shown")

-- Eligibility is still authoritative for explicit Show.
resetState()
SpectrumFederationDB.lootHelper.activeProfileId = nil
SF.GetActiveProfile = function()
    return nil
end
ok, why = Controller:ShowWindow("Slash:/sf loot")
assertFalse(ok, "ShowWindow fails without an active profile")
assertEq(why, "no_active_profile", "missing profile reason is preserved")
assertFalse(Controller:IsWindowShown(), "Show does not bypass the active-profile rule")
assertFalse(Controller:IsManuallyHidden(), "failed Show still clears manual-hidden")

resetState()
function SF:GetActiveProfile()
    if not SpectrumFederationDB.lootHelper.activeProfileId then
        return nil
    end
    return {
        GetPointName = function()
            return "Points"
        end,
        IsCurrentUserAdmin = function()
            return true
        end,
        IsRewardPotMode = function()
            return false
        end,
    }
end

resetState()
inRaid = false
ok, why = Controller:ShowWindow("Settings:LootWindow")
assertFalse(ok, "ShowWindow fails outside raid when the setting is off")
assertEq(why, "not_in_raid", "outside-raid reason is preserved")
assertFalse(Controller:IsWindowShown(), "Show does not bypass the raid rule")

resetState()
inRaid = false
SpectrumFederationDB.lootHelper.showWindowOutsideRaid = true
ok, why = Controller:ShowWindow("Settings:LootWindow")
assertTrue(ok, "ShowWindow succeeds outside raid when allowed")
assertEq(why, "outside_raid_allowed", "outside-raid-allowed reason is preserved")
assertTrue(Controller:IsWindowShown(), "Show honors showWindowOutsideRaid")

resetState()
SpectrumFederationDB.lootHelper.enabled = false
ok, why = Controller:ShowWindow("Settings:LootWindow")
assertFalse(ok, "ShowWindow fails when Loot Helper is disabled")
assertEq(why, "disabled", "disabled reason is preserved")
assertFalse(Controller:IsWindowShown(), "Show does not bypass lootHelper.enabled")

-- Minimize/expanded state is independent of close.
resetState()
Window._frame.__sfMinimized = true
SpectrumFederationDB.lootHelper.window.minimized = true
Controller:HideWindow("CloseButton")
Controller:ShowWindow("Slash:/sf loot")
assertTrue(Controller:IsWindowShown(), "reopen after minimize+close shows the window")
assertTrue(Window._frame.__sfMinimized, "minimize -> close -> reopen keeps minimized")
assertTrue(SpectrumFederationDB.lootHelper.window.minimized, "persisted minimized flag is unchanged")

resetState()
Window._frame.__sfMinimized = false
SpectrumFederationDB.lootHelper.window.minimized = false
Controller:HideWindow("CloseButton")
Controller:ShowWindow("Slash:/sf loot")
assertFalse(Window._frame.__sfMinimized, "expanded -> close -> reopen keeps expanded")
assertFalse(SpectrumFederationDB.lootHelper.window.minimized, "persisted expanded flag is unchanged")

-- Runtime-only: persisted window state has no hidden flag; reload clears override.
resetState()
Controller:HideWindow("CloseButton")
Window:SaveState()
local st = SpectrumFederationDB.lootHelper.window
assertTrue(st.hidden == nil, "SaveState does not persist hidden")
assertTrue(st.manuallyHidden == nil, "SaveState does not persist manuallyHidden")
assertEq(st.width, 480, "close does not change saved width")
assertEq(st.height, 520, "close does not change saved height")
assertEq(st.minimized, false, "close does not change saved minimized")

Controller._manuallyHidden = nil
inRaid = true
Controller:EvaluateVisibility("InitImmediate")
assertTrue(Controller:IsWindowShown(), "fresh init / reload returns to automatic visibility")
assertFalse(Controller:IsManuallyHidden(), "reload does not keep manual-hidden")

-- Locked windows can still close.
resetState()
Window._frame.__sfLocked = true
Controller:OnCloseClicked()
assertFalse(Controller:IsWindowShown(), "close works while the window is locked")
assertTrue(Window._frame.__sfLocked, "close does not clear lock state")

-- Hide/show cycles converge: readiness listeners do not grow, and idle hide stays idle.
resetState()
Controller:EvaluateVisibility("cycle-start")
local shownListeners = listenerCount
for _ = 1, 50 do
    Controller:HideWindow("cycle")
    Controller:ShowWindow("cycle")
end
assertEq(listenerCount, shownListeners, "50 hide/show cycles do not accumulate readiness listeners")
refreshCount = 0
Controller:HideWindow("idle")
local hiddenRefresh = refreshCount
Controller:EvaluateVisibility("Event:GROUP_ROSTER_UPDATE")
Controller:EvaluateVisibility("Event:PLAYER_ENTERING_WORLD")
assertEq(refreshCount, hiddenRefresh, "hidden reevaluation does not schedule extra roster refreshes")
assertEq(listenerCount, 0, "hidden window unbinds the readiness listener")

-- Slash: /sf loot is Show, not toggle; subcommands stay independent.
SF:RegisterLootHelperSlashCommands()
local lootHandler = SF.SlashCommands.loot.handler
assertTrue(type(lootHandler) == "function", "loot slash command is registered")

resetState()
Controller:HideWindow("CloseButton")
lootHandler("")
assertTrue(Controller:IsWindowShown(), "bare /sf loot reopens a manually hidden window")
assertFalse(Controller:IsManuallyHidden(), "bare /sf loot clears manual-hidden")
assertEq(sessionStartCount, 0, "bare /sf loot does not start a session")
assertEq(sessionEndCount, 0, "bare /sf loot does not end a session")
assertEq(manualSyncCount, 0, "bare /sf loot does not request sync")

resetState()
Controller:EvaluateVisibility("slash-already-shown")
lootHandler("")
assertTrue(Controller:IsWindowShown(), "bare /sf loot does not hide an already-visible window")
assertTrue(printedContains("info", "already enabled"), "already-enabled message is preserved")

resetState()
inRaid = false
lootHandler("")
assertFalse(Controller:IsWindowShown(), "bare /sf loot still respects the raid rule")
assertTrue(printedContains("warn", "You are not in a raid"), "slash keeps the outside-raid warning")

resetState()
SpectrumFederationDB.lootHelper.activeProfileId = nil
function SF:GetActiveProfile()
    return nil
end
lootHandler("")
assertFalse(Controller:IsWindowShown(), "bare /sf loot still requires an active profile")
assertTrue(printedContains("warn", "No active profile set"), "slash keeps the no-profile warning")

function SF:GetActiveProfile()
    if not SpectrumFederationDB.lootHelper.activeProfileId then
        return nil
    end
    return {
        GetPointName = function()
            return "Points"
        end,
        IsCurrentUserAdmin = function()
            return true
        end,
        IsRewardPotMode = function()
            return false
        end,
    }
end

resetState()
Controller:HideWindow("CloseButton")
local shownBeforeSync = Controller:IsWindowShown()
lootHandler("sync")
assertEq(manualSyncCount, 1, "/sf loot sync still requests manual sync")
assertEq(Controller:IsWindowShown(), shownBeforeSync, "/sf loot sync does not change window visibility")
assertTrue(Controller:IsManuallyHidden(), "/sf loot sync does not clear manual-hidden")

resetState()
Controller:HideWindow("CloseButton")
lootHandler("session start")
assertEq(sessionStartCount, 1, "/sf loot session start still starts a session")
assertFalse(Controller:IsWindowShown(), "/sf loot session start does not show the window")
assertEq(sessionEndCount, 0, "/sf loot session start does not end a session")

resetState()
Controller:HideWindow("CloseButton")
lootHandler("session end")
assertEq(sessionEndCount, 1, "/sf loot session end still ends a session")
assertFalse(Controller:IsWindowShown(), "/sf loot session end does not show the window")

-- Settings action uses the same controller API (Hide then Show updates text).
resetState()
assertEq(Controller:GetWindowVisibilityActionText(), "Hide Loot Window", "settings Hide label while shown")
Controller:ToggleWindow("Settings:LootWindow")
assertFalse(Controller:IsWindowShown(), "settings toggle hides a visible window")
assertEq(Controller:GetWindowVisibilityActionText(), "Show Loot Window", "settings Show label while hidden")
Controller:ToggleWindow("Settings:LootWindow")
assertTrue(Controller:IsWindowShown(), "settings toggle shows a hidden eligible window")

assertTrue(originalInit ~= nil, "production Controller:Init remains loaded")
assertEq(C.MINIMIZED_HEIGHT, 40, "constants still load with visibility tests")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
