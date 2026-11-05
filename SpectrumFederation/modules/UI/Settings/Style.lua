-- Grab the namespace
local addonName, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

UI.Style = {
    Page = {
        paddingTop      = 12,
        paddingBottom   = 16,
        paddingX        = 16,
        sectionSpacing  = 14,
    },
        
    Section = {
        headerHeight = 22,
        lineThickness = 1,
        lineAlpha = 0.28,
        titleGap = 10,
        infoButtonSize = 28,
        infoButtonGap = 2,
        infoButtonOffsetY = 0,

        contentInsetX = 12,
        paddingTop = 10,
        paddingBottom = 12,
        rowSpacing = 8,

        messagePaddingX = 10,
        messagePaddingY = 6,
        messageBgAlpha = 0.18,
    },

    Row = {
        labelWidth = 220,
        gutter = 16,
        controlWidth = 240,
    },
}

-- ---------------------------------------------------------------------------
-- Opaque opened-menu surfaces (fixed visual rule; not a user preference).
-- Covers SpectrumFederation-owned Blizzard_Menu dropdowns and the Settings
-- autocomplete suggestion popup. Intentionally independent of
-- settingsWindowOpacity and never registered as an opacity target.
-- ---------------------------------------------------------------------------
UI.OpaqueMenu = UI.OpaqueMenu or {}

-- Autocomplete suggestion list: WHITE8X8 is genuinely opaque; dialog-box
-- textures remain translucent even at high vertex alpha.
UI.OpaqueMenu.AUTOCOMPLETE_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 8,
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local opaqueDropdownMenuStyleMixin

-- Retail MenuStyle1Mixin draws common-dropdown-bg at alpha 0.925. That atlas
-- also has translucent pixels, so scenery and underlying controls show
-- through. Prefer Blizzard's per-dropdown menuMixin override (read by
-- DropdownButtonMixin:CreateDefaultRootMenuDescription) instead of mutating
-- MenuVariants / shared MenuStyle1Mixin.
local function GetOpaqueDropdownMenuStyleMixin()
    if opaqueDropdownMenuStyleMixin then
        return opaqueDropdownMenuStyleMixin
    end

    local base = rawget(_G, "MenuStyle1Mixin")
    if type(base) == "table" and type(CreateFromMixins) == "function" then
        opaqueDropdownMenuStyleMixin = CreateFromMixins(base)
    else
        opaqueDropdownMenuStyleMixin = {}
    end

    function opaqueDropdownMenuStyleMixin:Generate()
        local background = self:AttachTexture()
        background:SetAtlas("common-dropdown-bg")

        -- Match MenuStyle1Mixin geometry so borders/layout stay familiar.
        local x, y = 10, 3
        background:SetPoint("TOPLEFT", -x, y)
        background:SetPoint("BOTTOMRIGHT", x, -y)
        if background.SetAlpha then
            background:SetAlpha(1)
        end

        -- Solid fill under the decorative atlas. Raising atlas alpha alone does
        -- not guarantee opacity when the texture itself is translucent.
        local fill = self:AttachTexture()
        fill:SetColorTexture(0, 0, 0, 1)
        fill:SetAllPoints(self)
        if background.GetDrawLayer and fill.SetDrawLayer then
            local layer, subLevel = background:GetDrawLayer()
            fill:SetDrawLayer(layer, (subLevel or 0) - 1)
        end
    end

    if type(opaqueDropdownMenuStyleMixin.GetInset) ~= "function" then
        local inset = { left = 8, top = 8, right = 8, bottom = 15 }
        function opaqueDropdownMenuStyleMixin:GetInset()
            return inset
        end
    end

    if type(opaqueDropdownMenuStyleMixin.GetChildExtentPadding) ~= "function" then
        local padding = { width = 20, height = 0 }
        function opaqueDropdownMenuStyleMixin:GetChildExtentPadding()
            return padding
        end
    end

    return opaqueDropdownMenuStyleMixin
end

-- Apply the opaque Blizzard_Menu style to one SpectrumFederation DropdownButton.
-- Safe to call before SetupMenu; Blizzard rematerializes style on each open via
-- the dropdown's menuMixin, so pooled/regenerated menus stay opaque without
-- leaking into unrelated Blizzard menus.
function UI.OpaqueMenu.ApplyDropdownMenuStyle(dropdown)
    if type(dropdown) ~= "table" then
        return
    end
    dropdown.menuMixin = GetOpaqueDropdownMenuStyleMixin()
end

-- Apply the opaque autocomplete suggestion-list backdrop.
function UI.OpaqueMenu.ApplyAutocompleteBackdrop(frame)
    if type(frame) ~= "table" or type(frame.SetBackdrop) ~= "function" then
        return
    end
    frame:SetBackdrop(UI.OpaqueMenu.AUTOCOMPLETE_BACKDROP)
    if frame.SetBackdropColor then
        frame:SetBackdropColor(0, 0, 0, 1)
    end
    if frame.SetBackdropBorderColor then
        frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    end
end