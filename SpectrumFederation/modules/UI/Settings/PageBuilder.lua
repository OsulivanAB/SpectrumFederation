-- Grab the namespace
local addonName, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

local PageBuilder = {}
PageBuilder.__index = PageBuilder
UI.PageBuilder = PageBuilder

-- Layout constants
local PAGE_PADDING_TOP       = 12
local PAGE_PADDING_BOTTOM    = 16
local PAGE_PADDING_X         = 16
local SECTION_SPACING        = 18

function UI:CreatePage(panel)
    local obj = setmetatable({}, PageBuilder)
    obj:Init(panel)
    return obj
end

function PageBuilder:Init(panel)
    self.panel = panel
    self.sections = {}

    -- Scroll frame
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    self.scrollFrame = scroll

    -- Fill the panel; leave room for the template scroll bar
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

    -- Scroll child (content root)
    local content = CreateFrame("Frame", nil, scroll)
    self.content = content
    content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    content:SetHeight(1)
    scroll:SetScrollChild(content)

    -- Keep content width synced to scroll frame width, minus scrollbar width
    local function UpdateContentWidth()
        local w = scroll:GetWidth() or 0
        local sb = scroll.ScrollBar
        local sbw = (sb and sb:GetWidth()) or 20
        local usable = math.max(1, w - sbw - 4)
        content:SetWidth(usable)
    end

    scroll:HookScript("OnSizeChanged", function()
        UpdateContentWidth()
        self:Reflow()
    end)

    UpdateContentWidth()
end

function PageBuilder:AddSection(title)
    local section = UI.Section:Create(self.content, title)

    -- Anchor width padding and stack below previous sections
    if #self.sections == 0 then
        section:SetPoint("TOPLEFT", self.content, "TOPLEFT", PAGE_PADDING_X, -PAGE_PADDING_TOP)
        section:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", -PAGE_PADDING_X, -PAGE_PADDING_TOP)
    else
        local prev = self.sections[#self.sections]
        section:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -SECTION_SPACING)
        section:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -SECTION_SPACING)
    end

    table.insert(self.sections, section)
    return section
end

function PageBuilder:Finalize()
    self:Reflow()
end

-- Computes content height so the scroll frame knows how far it can scroll
function PageBuilder:Reflow()
    local total = PAGE_PADDING_TOP + PAGE_PADDING_BOTTOM

    for i, sec in ipairs(self.sections) do
        total = total + (sec:GetHeight() or 0)
        if i < #self.sections then
            total = total + SECTION_SPACING
        end
    end

    local viewH = self.scrollFrame:GetHeight() or 0
    total = math.max(total, viewH + 1)

    self.content:SetHeight(total)
end