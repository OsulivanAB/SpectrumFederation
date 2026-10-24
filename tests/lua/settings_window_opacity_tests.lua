-- Production-Lua tests for Settings Window backdrop opacity (#418).
-- Covers defaults, clamping, backdrop-only updates, and store persistence/reset.
-- Run from the repository root:
--   lua5.1 tests/lua/settings_window_opacity_tests.lua

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

local function assertAlmost(actual, expected, eps, message)
    if type(actual) == "number" and type(expected) == "number" and math.abs(actual - expected) <= eps then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

UIParent = { name = "UIParent", GetWidth = function() return 1920 end, GetHeight = function() return 1080 end }

local function makeRegion(kind, name, parent)
    local region = {
        kind = kind,
        name = name,
        parent = parent,
        shown = true,
        height = 0,
        width = 0,
        alpha = 1,
        points = {},
        scripts = {},
        backdropColor = nil,
        backdropBorderColor = nil,
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

    function region:GetWidth()
        return self.width
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

    function region:SetBackdropColor(r, g, b, a)
        self.backdropColor = { r = r, g = g, b = b, a = a }
    end

    function region:SetBackdropBorderColor(r, g, b, a)
        self.backdropBorderColor = { r = r, g = g, b = b, a = a }
    end

    function region:SetAlpha(a)
        self.alpha = a
    end

    function region:GetAlpha()
        return self.alpha
    end

    function region:SetMovable()
    end

    function region:EnableMouse()
    end

    function region:RegisterForDrag()
    end

    function region:SetClampedToScreen()
    end

    function region:SetResizable()
    end

    function region:SetResizeBounds()
    end

    function region:SetMinResize()
    end

    function region:SetMaxResize()
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

SpectrumFederationDB = { version = 3, global = {}, lootHelper = { profiles = {}, activeProfileId = nil } }
SpectrumFederationCharDB = {}

local SF = {}
assert(loadfile("SpectrumFederation/modules/Settings/Schema.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/Settings/Store.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/StandaloneWindow.lua"))("SpectrumFederation", SF)

local SettingsWindow = SF.SettingsWindow
local Store = SF.SettingsStore

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
    SettingsWindow.navPanel = nil
    SF.LootHelperImpersonation = nil
end

local function resetDb()
    SpectrumFederationDB = { version = 3 }
    SpectrumFederationCharDB = {}
    Store.db = nil
    Store.charDb = nil
    Store._callbacks = nil
    Store:Init()
end

-- Localization keys for the General-page slider (#418 follow-up)
do
    local localeChunk = assert(loadfile("SpectrumFederation/locale/enUS.lua"))
    local localeNs = {}
    localeChunk("SpectrumFederation", localeNs)
    assertEq(
        localeNs.L["SETTINGS_WINDOW_OPACITY_LABEL"],
        "Settings Window Opacity",
        "enUS defines SETTINGS_WINDOW_OPACITY_LABEL"
    )
    assertTrue(
        type(localeNs.L["SETTINGS_WINDOW_OPACITY_TOOLTIP"]) == "string"
            and localeNs.L["SETTINGS_WINDOW_OPACITY_TOOLTIP"] ~= "",
        "enUS defines SETTINGS_WINDOW_OPACITY_TOOLTIP"
    )
    assertEq(
        localeNs.LocaleText("SETTINGS_WINDOW_OPACITY_LABEL", "fallback"),
        "Settings Window Opacity",
        "LocaleText resolves SETTINGS_WINDOW_OPACITY_LABEL"
    )
    assertEq(
        localeNs.LocaleText("SETTINGS_WINDOW_OPACITY_MISSING", "fallback label"),
        "fallback label",
        "LocaleText falls back when opacity key is missing"
    )

    local generalSource = assert(io.open("SpectrumFederation/modules/UI/Settings/Pages/General.lua", "r")):read("*a")
    assertTrue(
        generalSource:find('Loc("SETTINGS_WINDOW_OPACITY_LABEL"', 1, true) ~= nil,
        "General.lua uses Loc for SETTINGS_WINDOW_OPACITY_LABEL"
    )
    assertTrue(
        generalSource:find('Loc(', 1, true) ~= nil
            and generalSource:find("SETTINGS_WINDOW_OPACITY_TOOLTIP", 1, true) ~= nil,
        "General.lua uses Loc for SETTINGS_WINDOW_OPACITY_TOOLTIP"
    )
    assertTrue(
        generalSource:find("SF.LocaleText", 1, true) ~= nil,
        "General.lua Loc helper routes through SF.LocaleText"
    )

    local toc = assert(io.open("SpectrumFederation/SpectrumFederation.toc", "r")):read("*a")
    local localePos = toc:find("locale/enUS.lua", 1, true)
    local generalPos = toc:find("modules/UI/Settings/Pages/General.lua", 1, true)
    assertTrue(localePos ~= nil, "TOC lists locale/enUS.lua")
    assertTrue(generalPos ~= nil, "TOC lists General.lua")
    assertTrue(localePos < generalPos, "TOC loads locale/enUS.lua before General.lua")
end

-- Schema / window defaults: 90%; range remains 70–100 step 5
assertEq(
    SF.SettingsSchema.DEFAULTS.global.settingsWindowOpacity,
    90,
    "schema default settingsWindowOpacity is 90"
)
do
    local windowSource = assert(io.open("SpectrumFederation/modules/UI/Settings/StandaloneWindow.lua", "r")):read("*a")
    assertTrue(
        windowSource:find("SETTINGS_WINDOW_OPACITY_DEFAULT = 90", 1, true) ~= nil,
        "StandaloneWindow default opacity constant is 90"
    )
    assertTrue(
        windowSource:find("SETTINGS_WINDOW_OPACITY_MIN = 70", 1, true) ~= nil,
        "StandaloneWindow min opacity remains 70"
    )
    assertTrue(
        windowSource:find("SETTINGS_WINDOW_OPACITY_MAX = 100", 1, true) ~= nil,
        "StandaloneWindow max opacity remains 100"
    )
    assertTrue(
        windowSource:find("SETTINGS_WINDOW_OPACITY_STEP = 5", 1, true) ~= nil,
        "StandaloneWindow opacity step remains 5"
    )
    assertTrue(
        windowSource:find("BG = {0, 0, 0, 0.90}", 1, true) ~= nil,
        "StandaloneWindow BG alpha matches 90% default"
    )
end

-- Normalize: missing, invalid, clamp, step rounding
assertEq(SettingsWindow:_NormalizeSettingsWindowOpacity(nil), 90, "nil opacity normalizes to 90")
assertEq(SettingsWindow:_NormalizeSettingsWindowOpacity("nope"), 90, "nonnumeric opacity normalizes to 90")
assertEq(SettingsWindow:_NormalizeSettingsWindowOpacity(50), 70, "below-min opacity clamps to 70")
assertEq(SettingsWindow:_NormalizeSettingsWindowOpacity(150), 100, "above-max opacity clamps to 100")
assertEq(SettingsWindow:_NormalizeSettingsWindowOpacity(73), 75, "73 rounds to nearest 5% step (75)")
assertEq(SettingsWindow:_NormalizeSettingsWindowOpacity(72), 70, "72 rounds to nearest 5% step (70)")
assertEq(SettingsWindow:_NormalizeSettingsWindowOpacity(70), 70, "70% is valid minimum")
assertEq(SettingsWindow:_NormalizeSettingsWindowOpacity(90), 90, "90% default is preserved as in-range")
assertEq(SettingsWindow:_NormalizeSettingsWindowOpacity(85), 85, "in-range stepped value is preserved")
assertEq(SettingsWindow:_NormalizeSettingsWindowOpacity(100), 100, "100% is valid fully opaque")

-- Store Init fills missing default; Set persists account-wide
resetDb()
assertEq(Store:Get("global.settingsWindowOpacity"), 90, "Init merges missing opacity to default 90")
Store:Set("global.settingsWindowOpacity", 85)
assertEq(Store:Get("global.settingsWindowOpacity"), 85, "Set persists settingsWindowOpacity")
assertEq(SpectrumFederationDB.global.settingsWindowOpacity, 85, "value is account-wide in SpectrumFederationDB")

-- Explicitly stored preferences (including 70%) survive Init; no migration
SpectrumFederationDB = {
    version = 3,
    global = { settingsWindowOpacity = 70 },
    lootHelper = { profiles = {}, activeProfileId = nil },
}
SpectrumFederationCharDB = {}
Store.db = nil
Store.charDb = nil
Store._callbacks = nil
Store:Init()
assertEq(Store:Get("global.settingsWindowOpacity"), 70, "explicitly stored 70% is unchanged after Init")
assertEq(SpectrumFederationDB.global.settingsWindowOpacity, 70, "saved 70% remains in SpectrumFederationDB")

SpectrumFederationDB = {
    version = 3,
    global = { settingsWindowOpacity = 85 },
    lootHelper = { profiles = {}, activeProfileId = nil },
}
SpectrumFederationCharDB = {}
Store.db = nil
Store.charDb = nil
Store._callbacks = nil
Store:Init()
assertEq(Store:Get("global.settingsWindowOpacity"), 85, "explicitly stored 85% is unchanged after Init")

-- Reset restores 90
local resetOk = Store:ResetPath("global.settingsWindowOpacity")
assertTrue(resetOk, "ResetPath succeeds for settingsWindowOpacity")
assertEq(Store:Get("global.settingsWindowOpacity"), 90, "ResetPath restores opacity to 90")

-- Invalid window: backdrop alpha only; frame alpha unchanged
resetWindow()
resetDb()
Store:Set("global.settingsWindowOpacity", 85)
SettingsWindow:CreateWindow()

local frame = SettingsWindow.frame
assertTrue(frame ~= nil, "CreateWindow creates the settings frame")
assertAlmost(frame.backdropColor.a, 0.85, 1e-6, "CreateWindow applies stored backdrop opacity")
assertAlmost(frame.alpha, 1, 1e-6, "CreateWindow does not change overall frame alpha")
assertEq(frame.backdropColor.r, 0, "backdrop RGB red stays 0")
assertEq(frame.backdropColor.g, 0, "backdrop RGB green stays 0")
assertEq(frame.backdropColor.b, 0, "backdrop RGB blue stays 0")

local borderA = frame.backdropBorderColor and frame.backdropBorderColor.a
SettingsWindow:ApplySettingsWindowOpacity(100)
assertAlmost(frame.backdropColor.a, 1.0, 1e-6, "100% makes backdrop fully opaque")
assertAlmost(frame.alpha, 1, 1e-6, "100% still leaves frame SetAlpha untouched")
assertAlmost(frame.backdropBorderColor.a, borderA, 1e-6, "backdrop border alpha is unchanged by opacity apply")

SettingsWindow:ApplySettingsWindowOpacity(70)
assertAlmost(frame.backdropColor.a, 0.70, 1e-6, "70% applies valid minimum backdrop alpha")
assertAlmost(frame.alpha, 1, 1e-6, "70% still leaves frame SetAlpha untouched")

-- Live drag-style updates (immediate Apply without recreating the window)
SettingsWindow:ApplySettingsWindowOpacity(90)
assertAlmost(frame.backdropColor.a, 0.90, 1e-6, "live Apply updates backdrop while window exists")
SettingsWindow:ApplySettingsWindowOpacity(95)
assertAlmost(frame.backdropColor.a, 0.95, 1e-6, "second live Apply updates backdrop again")

-- Invalid/out-of-range values via Apply
SettingsWindow:ApplySettingsWindowOpacity("bad")
assertAlmost(frame.backdropColor.a, 0.90, 1e-6, "invalid Apply value falls back to 90% backdrop")
SettingsWindow:ApplySettingsWindowOpacity(10)
assertAlmost(frame.backdropColor.a, 0.70, 1e-6, "below-min Apply clamps to 70% backdrop")
SettingsWindow:ApplySettingsWindowOpacity(200)
assertAlmost(frame.backdropColor.a, 1.0, 1e-6, "above-max Apply clamps to 100% backdrop")

-- SettingsStore path preferred over raw DB when both exist
SpectrumFederationDB.global.settingsWindowOpacity = 70
SF.SettingsStore = {
    Get = function(_, path)
        if path == "global.settingsWindowOpacity" then
            return 80
        end
        return nil
    end,
}
assertEq(SettingsWindow:_ReadSettingsWindowOpacitySetting(), 80, "SettingsStore value is preferred when present")
SettingsWindow:ApplySettingsWindowOpacity()
assertAlmost(frame.backdropColor.a, 0.80, 1e-6, "Apply with nil reads SettingsStore and updates backdrop")

-- Restore real store for Apply module wiring
SF.SettingsStore = Store
resetDb()
Store:Set("global.settingsWindowOpacity", 75)

-- Apply module callback path (immediate, no debounce)
assert(loadfile("SpectrumFederation/modules/Settings/Apply.lua"))("SpectrumFederation", SF)
SF.SettingsApply.initialized = nil
SF.SettingsApply._debounce = nil
SF.SettingsApply:Init()
assertAlmost(frame.backdropColor.a, 0.75, 1e-6, "Apply:Init ApplyAll applies current opacity to existing window")

Store:Set("global.settingsWindowOpacity", 100)
assertAlmost(frame.backdropColor.a, 1.0, 1e-6, "store callback applies opacity immediately while dragging")
assertAlmost(frame.alpha, 1, 1e-6, "store callback never sets overall frame alpha")

Store:ResetPath("global.settingsWindowOpacity")
assertEq(Store:Get("global.settingsWindowOpacity"), 90, "reset after live updates restores store default")
assertAlmost(frame.backdropColor.a, 0.90, 1e-6, "reset reapplies 90% backdrop via callback")

-- Persistence across "character change": account DB survives char DB swap
local accountOpacity = Store:Get("global.settingsWindowOpacity")
SpectrumFederationCharDB = { mouseTracer = { enabled = true } }
Store.charDb = SpectrumFederationCharDB
assertEq(Store:Get("global.settingsWindowOpacity"), accountOpacity, "opacity is unchanged when character DB is replaced")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
