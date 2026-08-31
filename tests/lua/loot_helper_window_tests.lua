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

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
