-- Production-Lua tests for opaque opened-menu styling helpers.
-- Covers per-dropdown menuMixin assignment and opaque autocomplete backdrop.
-- Run from the repository root:
--   lua5.1 tests/lua/opaque_menu_style_tests.lua

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

-- Minimal Blizzard stubs used by Style.lua OpaqueMenu helpers.
_G = _G or {}
CreateFromMixins = function(base)
    local copy = {}
    if type(base) == "table" then
        for k, v in pairs(base) do
            copy[k] = v
        end
    end
    return copy
end

MenuStyle1Mixin = {
    GetInset = function()
        return { left = 8, top = 8, right = 8, bottom = 15 }
    end,
    GetChildExtentPadding = function()
        return { width = 20, height = 0 }
    end,
    Generate = function()
        error("MenuStyle1Mixin.Generate should be overridden")
    end,
}

local SF = {}
local chunk, loadErr = loadfile("SpectrumFederation/modules/UI/Settings/Style.lua")
assertTrue(type(chunk) == "function", "Style.lua loads: " .. tostring(loadErr))
if type(chunk) == "function" then
    chunk("SpectrumFederation", SF)
end

local OpaqueMenu = SF.SettingsUI and SF.SettingsUI.OpaqueMenu
assertTrue(type(OpaqueMenu) == "table", "OpaqueMenu helpers are exported")
assertTrue(type(OpaqueMenu.ApplyDropdownMenuStyle) == "function", "ApplyDropdownMenuStyle exists")
assertTrue(type(OpaqueMenu.ApplyAutocompleteBackdrop) == "function", "ApplyAutocompleteBackdrop exists")
assertEq(
    OpaqueMenu.AUTOCOMPLETE_BACKDROP and OpaqueMenu.AUTOCOMPLETE_BACKDROP.bgFile,
    "Interface\\Buttons\\WHITE8X8",
    "autocomplete uses opaque WHITE8X8 backdrop"
)

local dropdown = {}
OpaqueMenu.ApplyDropdownMenuStyle(dropdown)
assertTrue(type(dropdown.menuMixin) == "table", "dropdown receives menuMixin override")
assertTrue(dropdown.menuMixin ~= MenuStyle1Mixin, "override is not the shared MenuStyle1Mixin table")
assertTrue(type(dropdown.menuMixin.Generate) == "function", "opaque style provides Generate")
assertTrue(type(dropdown.menuMixin.GetInset) == "function", "opaque style preserves GetInset")

-- Second apply reuses the same mixin instance (stable across reopen/regeneration).
local dropdown2 = {}
OpaqueMenu.ApplyDropdownMenuStyle(dropdown2)
assertTrue(dropdown2.menuMixin == dropdown.menuMixin, "style mixin is shared across SF dropdowns")

-- Simulate Blizzard rematerializing the menu style on open.
local attached = {}
local menuProxy = {}
function menuProxy:AttachTexture()
    local tex = {
        points = {},
        atlas = nil,
        alpha = nil,
        color = nil,
        layer = "BACKGROUND",
        subLevel = 0,
    }
    function tex:SetAtlas(name)
        self.atlas = name
    end
    function tex:SetPoint()
        -- Geometry is asserted via allPoints / color, not point tables.
    end
    function tex:SetAllPoints(relative)
        self.allPoints = relative or self
    end
    function tex:SetAlpha(a)
        self.alpha = a
    end
    function tex:SetColorTexture(r, g, b, a)
        self.color = { r = r, g = g, b = b, a = a }
    end
    function tex:GetDrawLayer()
        return self.layer, self.subLevel
    end
    function tex:SetDrawLayer(layer, subLevel)
        self.layer = layer
        self.subLevel = subLevel
    end
    table.insert(attached, tex)
    return tex
end

dropdown.menuMixin.Generate(menuProxy)

assertEq(#attached, 2, "Generate attaches decorative atlas plus opaque fill")
assertEq(attached[1].atlas, "common-dropdown-bg", "decorative atlas preserved")
assertEq(attached[1].alpha, 1, "decorative atlas uses full texture alpha")
assertTrue(attached[2].color ~= nil, "opaque fill uses SetColorTexture")
assertEq(attached[2].color.a, 1, "fill alpha is fully opaque")
assertEq(attached[2].color.r, 0, "fill is black")
assertTrue(attached[2].allPoints == menuProxy, "fill covers the menu content frame")
assertTrue(
    attached[2].subLevel < (attached[1].subLevel or 0),
    "fill draws behind the decorative atlas"
)

-- Autocomplete backdrop application.
local frame = {
    backdrop = nil,
    backdropColor = nil,
    backdropBorderColor = nil,
}
function frame:SetBackdrop(info)
    self.backdrop = info
end
function frame:SetBackdropColor(r, g, b, a)
    self.backdropColor = { r = r, g = g, b = b, a = a }
end
function frame:SetBackdropBorderColor(r, g, b, a)
    self.backdropBorderColor = { r = r, g = g, b = b, a = a }
end

OpaqueMenu.ApplyAutocompleteBackdrop(frame)
assertEq(frame.backdrop.bgFile, "Interface\\Buttons\\WHITE8X8", "autocomplete backdrop file is WHITE8X8")
assertEq(frame.backdropColor.a, 1, "autocomplete backdrop color alpha is opaque")

-- Unrelated Blizzard default mixin remains untouched.
assertTrue(
    MenuStyle1Mixin.Generate ~= dropdown.menuMixin.Generate,
    "does not replace MenuStyle1Mixin.Generate globally"
)

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
