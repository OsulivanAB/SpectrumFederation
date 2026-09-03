-- Production-Lua tests for Settings window content layout.
-- Catches the hidden-impersonation-banner collapse that blanks every page.
-- Run from the repository root: lua5.1 tests/lua/settings_window_layout_tests.lua

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

UIParent = { name = "UIParent" }

local function makeRegion(kind, name, parent)
    local region = {
        kind = kind,
        name = name,
        parent = parent,
        shown = true,
        height = 0,
        width = 0,
        points = {},
        scripts = {},
    }

    function region:SetPoint(point, relativeTo, relativePoint, x, y)
        if type(relativeTo) == "number" then
            x, y = relativeTo, relativePoint
            relativeTo, relativePoint = nil, point
        elseif type(relativePoint) == "number" then
            x, y = relativePoint, x
            relativePoint = point
        end
        table.insert(self.points, {
            point = point,
            relativeTo = relativeTo,
            relativePoint = relativePoint,
            x = x or 0,
            y = y or 0,
        })
    end

    function region:ClearAllPoints()
        self.points = {}
    end

    function region:SetHeight(height)
        self.height = height
    end

    function region:GetHeight()
        return self.height
    end

    function region:SetWidth(width)
        self.width = width
    end

    function region:SetSize(width, height)
        self.width = width
        self.height = height
    end

    function region:Show()
        self.shown = true
    end

    function region:Hide()
        self.shown = false
    end

    function region:IsShown()
        return self.shown and true or false
    end

    function region:SetAllPoints(target)
        self.allPoints = target or self.parent
    end

    function region:SetColorTexture()
    end

    function region:SetTexture()
    end

    function region:SetTexCoord()
    end

    function region:SetText(text)
        self.text = text
    end

    function region:SetTextColor()
    end

    function region:SetJustifyH()
    end

    function region:SetJustifyV()
    end

    function region:SetWordWrap()
    end

    function region:SetFontObject()
    end

    function region:SetScript(event, fn)
        self.scripts[event] = fn
    end

    function region:HookScript(event, fn)
        self.scripts["hook:" .. event] = fn
    end

    function region:SetFrameStrata()
    end

    function region:SetBackdrop()
    end

    function region:SetBackdropColor()
    end

    function region:SetBackdropBorderColor()
    end

    function region:SetMovable()
    end

    function region:EnableMouse()
    end

    function region:RegisterForDrag()
    end

    function region:SetClampedToScreen()
    end

    function region:SetNormalTexture()
    end

    function region:SetHighlightTexture()
    end

    function region:SetPushedTexture()
    end

    function region:CreateTexture()
        return makeRegion("Texture", nil, self)
    end

    function region:CreateFontString()
        return makeRegion("FontString", nil, self)
    end

    return region
end

function CreateFrame(frameType, name, parent)
    return makeRegion(frameType or "Frame", name, parent)
end

local function isAnchoredTo(frame, relativeTo)
    for _, point in ipairs(frame.points or {}) do
        if point.relativeTo == relativeTo then
            return true
        end
    end
    return false
end

local function headerAnchoredToHiddenBanner(window)
    local header = window.contentHeader
    local banner = window.impersonationBanner
    return header and banner and (not banner.shown) and isAnchoredTo(header, banner)
end

local SF = {}
local chunk = assert(loadfile("SpectrumFederation/modules/UI/Settings/StandaloneWindow.lua"))
chunk("SpectrumFederation", SF)

local SettingsWindow = SF.SettingsWindow
SettingsWindow.BuildNavPanel = function() end
SettingsWindow.ApplyPreferredWindowMin = function() end

local function resetWindow()
    SettingsWindow.frame = nil
    SettingsWindow.contentPanel = nil
    SettingsWindow.contentHeader = nil
    SettingsWindow.contentHost = nil
    SettingsWindow.impersonationBanner = nil
    SettingsWindow.impersonationBannerText = nil
    SettingsWindow.pagePanels = {}
    SettingsWindow.currentCategoryId = nil
    SettingsWindow.currentPageId = nil
    SF.LootHelperImpersonation = nil
end

resetWindow()
SettingsWindow:CreateWindow()

assertTrue(SettingsWindow.contentHeader ~= nil, "CreateWindow creates contentHeader")
assertTrue(SettingsWindow.contentHost ~= nil, "CreateWindow creates contentHost")
assertTrue(SettingsWindow.impersonationBanner ~= nil, "CreateWindow creates impersonationBanner")
assertTrue(SettingsWindow.contentPanel ~= nil, "CreateWindow creates contentPanel")

assertTrue(
    isAnchoredTo(SettingsWindow.contentHeader, SettingsWindow.contentPanel),
    "inactive contentHeader is anchored to contentPanel"
)
assertFalse(
    headerAnchoredToHiddenBanner(SettingsWindow),
    "inactive contentHeader is not anchored to a hidden impersonation banner"
)
assertTrue(
    isAnchoredTo(SettingsWindow.contentHost, SettingsWindow.contentHeader),
    "contentHost is anchored to contentHeader"
)
assertFalse(SettingsWindow.impersonationBanner.shown, "impersonation banner starts hidden")

SettingsWindow:UpdateImpersonationBanner()
assertFalse(
    headerAnchoredToHiddenBanner(SettingsWindow),
    "UpdateImpersonationBanner while inactive keeps header off the hidden banner"
)
assertTrue(
    isAnchoredTo(SettingsWindow.contentHeader, SettingsWindow.contentPanel),
    "UpdateImpersonationBanner while inactive anchors header to contentPanel"
)

SF.LootHelperImpersonation = {
    IsActive = function()
        return true
    end,
    GetBannerText = function()
        return "IMPERSONATION MODE — test"
    end,
}
SettingsWindow:UpdateImpersonationBanner()
assertTrue(SettingsWindow.impersonationBanner.shown, "active impersonation shows the banner")
assertEq(SettingsWindow.impersonationBanner.height, 36, "active impersonation uses banner height")
assertTrue(
    isAnchoredTo(SettingsWindow.contentHeader, SettingsWindow.impersonationBanner),
    "active impersonation anchors contentHeader below the shown banner"
)
assertEq(SettingsWindow.impersonationBannerText.text, "IMPERSONATION MODE — test", "banner text is applied")

SF.LootHelperImpersonation.IsActive = function()
    return false
end
SettingsWindow:UpdateImpersonationBanner()
assertFalse(SettingsWindow.impersonationBanner.shown, "inactive impersonation hides the banner")
assertFalse(
    headerAnchoredToHiddenBanner(SettingsWindow),
    "turning impersonation off does not leave contentHeader on the hidden banner"
)
assertTrue(
    isAnchoredTo(SettingsWindow.contentHeader, SettingsWindow.contentPanel),
    "turning impersonation off re-anchors contentHeader to contentPanel"
)
assertTrue(
    isAnchoredTo(SettingsWindow.contentHost, SettingsWindow.contentHeader),
    "contentHost remains anchored to contentHeader after banner toggle"
)

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
