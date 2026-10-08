-- Production-Lua tests for Loot Helper window minimize/expand anchoring.
-- Run from the repository root: lua5.1 tests/lua/loot_helper_window_tests.lua

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

local function assertAlmost(actual, expected, epsilon, message)
    if type(actual) ~= "number" or type(expected) ~= "number" then
        fail(message .. " (non-numeric)")
        return
    end
    if math.abs(actual - expected) <= epsilon then
        pass(message)
    else
        fail(string.format("%s (expected %s ± %s, got %s)", message, tostring(expected), tostring(epsilon), tostring(actual)))
    end
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

SpectrumFederationDB = {
    lootHelper = {
        window = {
            width = 480,
            height = 520,
            expandedHeight = 520,
        },
    },
}

local function makeFrame(width, height)
    local frame = {
        width = width,
        height = height,
        left = 0,
        bottom = 0,
        point = "CENTER",
        relativeTo = UIParent,
        relativePoint = "CENTER",
        x = 0,
        y = 0,
        alpha = 1,
        __sfMinimized = false,
        __sfLocked = false,
    }

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
    function frame:SetAlpha(alpha)
        self.alpha = alpha
    end
    function frame:GetAlpha()
        return self.alpha
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
            return
        end

        if point == "CENTER" and relativePoint == "CENTER" then
            local parent = relativeTo or UIParent
            local parentW = parent:GetWidth()
            local parentH = parent:GetHeight()
            local cx = (parentW / 2) + (x or 0)
            local cy = (parentH / 2) + (y or 0)
            self.left = cx - (self.width / 2)
            self.bottom = cy - (self.height / 2)
        end
    end

    function frame:SetSize(width, height)
        local oldWidth, oldHeight = self.width, self.height
        if self.point == "CENTER" then
            local cx = self.left + (oldWidth / 2)
            local cy = self.bottom + (oldHeight / 2)
            self.width = width
            self.height = height
            self.left = cx - (width / 2)
            self.bottom = cy - (height / 2)
            return
        end

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

    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    return frame
end

local SF = { LootHelperWindow = {} }
local constChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/Constants.lua"))
constChunk("SpectrumFederation", SF)
local windowChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/Window.lua"))
windowChunk("SpectrumFederation", SF)

local Window = SF.LootHelperWindow.Window
local C = SF.LootHelperWindow.Constants

local function resetWindowState()
    SpectrumFederationDB.lootHelper.window = {
        width = 480,
        height = 520,
        expandedHeight = 520,
    }
    SpectrumFederationDB.lootHelper.minimizedHeaderOpacity = nil
    SF.SettingsStore = nil
end

local function setMinimizedOpacitySetting(value)
    SpectrumFederationDB.lootHelper.minimizedHeaderOpacity = value
end

-- Sanity-check the mock: a CENTER-anchored SetSize grows from the middle.
do
    local frame = makeFrame(480, 520)
    local topBefore = frame:GetTop()
    local leftBefore = frame:GetLeft()
    frame:SetSize(480, 40)
    assertTrue(frame:GetTop() ~= topBefore, "CENTER mock SetSize moves the top edge")
    assertEq(frame:GetLeft(), leftBefore, "CENTER mock SetSize keeps width-centered left edge")
end

resetWindowState()
Window._frame = makeFrame(480, 520)
local expandedTop = Window._frame:GetTop()
local expandedLeft = Window._frame:GetLeft()

Window:_AnchorToCurrentTopLeft()
assertEq(Window._frame.point, "TOPLEFT", "pin uses TOPLEFT")
assertEq(Window._frame.relativePoint, "BOTTOMLEFT", "pin is relative to UIParent BOTTOMLEFT")
assertAlmost(Window._frame.x, expandedLeft, 1e-6, "pin x is the current left edge")
assertAlmost(Window._frame.y, expandedTop, 1e-6, "pin y is the current top edge")
assertAlmost(Window._frame:GetTop(), expandedTop, 1e-6, "pin does not move the top edge")
assertAlmost(Window._frame:GetLeft(), expandedLeft, 1e-6, "pin does not move the left edge")

Window._frame:SetSize(480, 40)
assertAlmost(Window._frame:GetTop(), expandedTop, 1e-6, "TOPLEFT SetSize keeps the title-bar top edge")
assertAlmost(Window._frame:GetLeft(), expandedLeft, 1e-6, "TOPLEFT SetSize keeps the left edge")
assertAlmost(Window._frame:GetHeight(), 40, 1e-6, "TOPLEFT SetSize shrinks height downward")

resetWindowState()
Window._frame = makeFrame(480, 520)
local startTop = Window._frame:GetTop()
local startLeft = Window._frame:GetLeft()
Window._frame.__sfMinimized = true
Window:_ApplyMinimizedState()
assertAlmost(Window._frame:GetTop(), startTop, 1e-6, "minimize keeps the original top edge")
assertAlmost(Window._frame:GetLeft(), startLeft, 1e-6, "minimize keeps the original left edge")
assertEq(Window._frame:GetHeight(), C.MINIMIZED_HEIGHT, "minimize uses MINIMIZED_HEIGHT")
assertEq(Window._frame.point, "TOPLEFT", "minimize re-anchors to TOPLEFT before shrinking")

local minimizedTop = Window._frame:GetTop()
local minimizedLeft = Window._frame:GetLeft()
Window._frame.__sfMinimized = false
Window:_ApplyMinimizedState()
assertAlmost(Window._frame:GetTop(), minimizedTop, 1e-6, "restore keeps the minimized title-bar top edge")
assertAlmost(Window._frame:GetLeft(), minimizedLeft, 1e-6, "restore keeps the left edge")
assertEq(Window._frame:GetHeight(), 520, "restore returns to the saved expanded height")
assertTrue(Window._frame:GetBottom() < minimizedTop - 100, "restore grows downward rather than around center")

resetWindowState()
SpectrumFederationDB.lootHelper.window = {
    width = 480,
    height = 520,
    expandedHeight = 520,
    minimized = true,
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
}
Window._frame = makeFrame(480, 520)
Window:LoadState()
assertEq(Window._frame:GetHeight(), C.MINIMIZED_HEIGHT, "LoadState uses minimized height before positioning")
assertAlmost(Window._frame:GetTop(), (UIParent.height / 2) + (C.MINIMIZED_HEIGHT / 2), 1e-6, "saved CENTER minimized window stays visually centered as the title bar")
assertAlmost(Window._frame:GetLeft(), (UIParent.width - 480) / 2, 1e-6, "saved CENTER minimized window keeps its horizontal position")

local loadedTop = Window._frame:GetTop()
local loadedLeft = Window._frame:GetLeft()
Window._frame.__sfMinimized = false
Window:_ApplyMinimizedState()
assertAlmost(Window._frame:GetTop(), loadedTop, 1e-6, "expand after load keeps the loaded title-bar top edge")
assertAlmost(Window._frame:GetLeft(), loadedLeft, 1e-6, "expand after load keeps the loaded left edge")
assertEq(Window._frame:GetHeight(), 520, "expand after load restores saved height")

resetWindowState()
Window._frame = makeFrame(480, 1000)
Window._frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
local clampTop = Window._frame:GetTop()
local clampLeft = Window._frame:GetLeft()
Window:ClampSizeToBounds()
assertEq(Window._frame:GetHeight(), C.MAX_HEIGHT, "ClampSizeToBounds enforces MAX_HEIGHT")
assertAlmost(Window._frame:GetTop(), clampTop, 1e-6, "ClampSizeToBounds keeps the top edge")
assertAlmost(Window._frame:GetLeft(), clampLeft, 1e-6, "ClampSizeToBounds keeps the left edge")
assertEq(Window._frame.point, "TOPLEFT", "ClampSizeToBounds re-anchors to TOPLEFT before SetSize")

resetWindowState()
Window._frame = makeFrame(480, 520)
Window:SaveState()
local saved = SpectrumFederationDB.lootHelper.window
assertTrue(saved.hidden == nil, "SaveState does not persist a hidden flag")
assertTrue(saved.manuallyHidden == nil, "SaveState does not persist manuallyHidden")
assertEq(saved.minimized, false, "SaveState keeps minimized=false for an expanded frame")

-- Minimized opacity: defaults, lifecycle, live updates, invalid values.
resetWindowState()
Window._frame = makeFrame(480, 520)
assertEq(Window:_NormalizeMinimizedOpacity(nil), 100, "missing opacity normalizes to 100")
assertEq(Window:_NormalizeMinimizedOpacity("nope"), 100, "nonnumeric opacity normalizes to 100")
assertEq(Window:_NormalizeMinimizedOpacity(0), 5, "opacity below 5 clamps to 5")
assertEq(Window:_NormalizeMinimizedOpacity(150), 100, "opacity above 100 clamps to 100")
assertEq(Window:_NormalizeMinimizedOpacity(55), 55, "in-range opacity is preserved")
assertEq(Window:_ReadMinimizedOpacitySetting(), 100, "missing saved opacity reads as 100")

Window:_ApplyMinimizedState()
assertAlmost(Window._frame:GetAlpha(), 1, 1e-6, "expanded window keeps overall alpha at 100%")

setMinimizedOpacitySetting(50)
Window:ApplyMinimizedOpacity()
assertAlmost(Window._frame:GetAlpha(), 1, 1e-6, "slider change while expanded does not alter frame alpha")

Window._frame.__sfMinimized = true
Window:_ApplyMinimizedState()
assertAlmost(Window._frame:GetAlpha(), 0.5, 1e-6, "minimize applies configured opacity to the main frame")
assertEq(Window._frame:GetHeight(), C.MINIMIZED_HEIGHT, "opacity apply does not change minimized height")

setMinimizedOpacitySetting(5)
Window:ApplyMinimizedOpacity()
assertAlmost(Window._frame:GetAlpha(), 0.05, 1e-6, "live setting change updates a minimized window immediately")

setMinimizedOpacitySetting(100)
Window:ApplyMinimizedOpacity()
assertAlmost(Window._frame:GetAlpha(), 1, 1e-6, "100% minimized opacity preserves full overall alpha")

Window._frame.__sfMinimized = false
Window:_ApplyMinimizedState()
assertAlmost(Window._frame:GetAlpha(), 1, 1e-6, "restore always returns overall frame alpha to 100%")

resetWindowState()
setMinimizedOpacitySetting(25)
SpectrumFederationDB.lootHelper.window = {
    width = 480,
    height = 520,
    expandedHeight = 520,
    minimized = true,
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
}
Window._frame = makeFrame(480, 520)
Window:LoadState()
assertAlmost(Window._frame:GetAlpha(), 0.25, 1e-6, "LoadState applies opacity for a saved minimized window")
assertEq(Window._frame:GetHeight(), C.MINIMIZED_HEIGHT, "LoadState minimized height is unchanged by opacity")

Window._frame.__sfMinimized = false
Window:_ApplyMinimizedState()
assertAlmost(Window._frame:GetAlpha(), 1, 1e-6, "expand after load restores overall alpha to 100%")

resetWindowState()
setMinimizedOpacitySetting("bad")
Window._frame = makeFrame(480, 520)
Window._frame.__sfMinimized = true
Window:ApplyMinimizedOpacity()
assertAlmost(Window._frame:GetAlpha(), 1, 1e-6, "invalid saved opacity falls back to 100% while minimized")

setMinimizedOpacitySetting(1)
Window:ApplyMinimizedOpacity()
assertAlmost(Window._frame:GetAlpha(), 0.05, 1e-6, "out-of-range low opacity clamps to 5% while minimized")

setMinimizedOpacitySetting(250)
Window:ApplyMinimizedOpacity()
assertAlmost(Window._frame:GetAlpha(), 1, 1e-6, "out-of-range high opacity clamps to 100% while minimized")

-- SettingsStore path is preferred when present.
resetWindowState()
setMinimizedOpacitySetting(40)
SF.SettingsStore = {
    Get = function(_, path)
        if path == "lootHelper.minimizedHeaderOpacity" then
            return 70
        end
        return nil
    end,
}
Window._frame = makeFrame(480, 520)
Window._frame.__sfMinimized = true
Window:ApplyMinimizedOpacity()
assertAlmost(Window._frame:GetAlpha(), 0.7, 1e-6, "SettingsStore opacity is used when available")

-- Reset All restores opacity default and refreshes a live minimized window.
local lootHelperChunk = assert(loadfile("SpectrumFederation/modules/LootHelper/LootHelper.lua"))
lootHelperChunk("SpectrumFederation", SF)

resetWindowState()
setMinimizedOpacitySetting(25)
SpectrumFederationDB.lootHelper.profiles = { ["p1"] = { id = "p1", name = "Test" } }
SpectrumFederationDB.lootHelper.activeProfileId = "p1"
SF.lootHelperDB = SpectrumFederationDB.lootHelper
SF.SettingsStore = nil
SF.SettingsSchema = {
    DEFAULTS = {
        lootHelper = {
            minimizedHeaderOpacity = 100,
        },
    },
}
Window._frame = makeFrame(480, 520)
Window._frame.__sfMinimized = true
Window:ApplyMinimizedOpacity()
assertAlmost(Window._frame:GetAlpha(), 0.25, 1e-6, "precondition: non-default minimized opacity applied")

local resetOk = SF:ResetAllLootHelperSettings()
assertTrue(resetOk, "ResetAllLootHelperSettings succeeds")
assertEq(SpectrumFederationDB.lootHelper.minimizedHeaderOpacity, 100, "Reset All restores minimizedHeaderOpacity default")
assertEq(SpectrumFederationDB.lootHelper.activeProfileId, nil, "Reset All still clears activeProfileId")
assertTrue(next(SpectrumFederationDB.lootHelper.profiles) == nil, "Reset All still clears profiles")
assertAlmost(Window._frame:GetAlpha(), 1, 1e-6, "Reset All reapplies default opacity to a minimized window")

-- SettingsStore:Set path also restores opacity and notifies listeners.
resetWindowState()
setMinimizedOpacitySetting(40)
SF.lootHelperDB = SpectrumFederationDB.lootHelper
local setCalls = {}
SF.SettingsStore = {
    Set = function(_, path, value)
        table.insert(setCalls, { path = path, value = value })
        if path == "lootHelper.minimizedHeaderOpacity" then
            SpectrumFederationDB.lootHelper.minimizedHeaderOpacity = value
            Window:ApplyMinimizedOpacity()
        end
    end,
}
Window._frame = makeFrame(480, 520)
Window._frame.__sfMinimized = true
Window:ApplyMinimizedOpacity()
assertAlmost(Window._frame:GetAlpha(), 0.4, 1e-6, "precondition: SettingsStore reset path starts at 40%")

resetOk = SF:ResetAllLootHelperSettings()
assertTrue(resetOk, "ResetAllLootHelperSettings succeeds with SettingsStore")
assertEq(#setCalls, 1, "Reset All writes opacity once through SettingsStore:Set")
assertEq(setCalls[1].path, "lootHelper.minimizedHeaderOpacity", "Reset All Sets the opacity path")
assertEq(setCalls[1].value, 100, "Reset All Sets opacity to the schema default")
assertAlmost(Window._frame:GetAlpha(), 1, 1e-6, "SettingsStore reset path restores full overall alpha")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
