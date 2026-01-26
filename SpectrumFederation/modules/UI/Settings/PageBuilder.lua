-- modules/UI/Settings/PageBuilder.lua
local _, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

local PageBuilder = {}
PageBuilder.__index = PageBuilder
UI.PageBuilder = PageBuilder

local Style = UI.Style or {}
local P = Style.Page or {}

local PAGE_PADDING_TOP     = P.paddingTop or 12
local PAGE_PADDING_BOTTOM  = P.paddingBottom or 16
local PAGE_PADDING_X       = P.paddingX or 16
local SECTION_SPACING      = P.sectionSpacing or 18
-- Create a new page builder instance for a settings panel
-- @param panel Frame The panel frame to build page into
-- @return PageBuilder A new PageBuilder instance
function UI:CreatePage(panel)
	local obj = setmetatable({}, PageBuilder)
	obj:Init(panel)
	return obj
end

-- Initialize a page builder with scroll frame and content area
-- @param panel Frame The panel frame to initialize
-- @return nil
function PageBuilder:Init(panel)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Creating new settings page")
	end

	self.panel = panel
	self.sections = {}
	self.refreshCallbacks = {}

	local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	self.scrollFrame = scroll
	scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	-- Subtract scrollbar width from right edge to keep scrollbar visible
	local SCROLLBAR_WIDTH = 24  -- Standard WoW scrollbar width
	scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -SCROLLBAR_WIDTH, 0)

	local content = CreateFrame("Frame", nil, scroll)
	self.content = content
	content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
	content:SetHeight(1)
	scroll:SetScrollChild(content)

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

-- Register a callback to be called when page is refreshed
-- @param fn function Callback to call on refresh
-- @return nil
function PageBuilder:RegisterRefresh(fn)
	table.insert(self.refreshCallbacks, fn)
end

-- Trigger all registered refresh callbacks
-- @return nil
function PageBuilder:Refresh()
	for _, fn in ipairs(self.refreshCallbacks) do
		pcall(fn)
	end
end

-- Add a new section to the page
-- @param title string Section title/header
-- @return Section The created section object
function PageBuilder:AddSection(title)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Adding section '%s' to page", tostring(title))
	end
	local section = UI.Section:Create(self.content, title)
	section.__sfPageBuilder = self
	table.insert(self.sections, section)
	return section
end

-- Finalize page layout and perform initial reflow
-- @return nil
function PageBuilder:Finalize()
	self:Reflow()
end

-- Reflow section layout based on visibility and sizing
-- @return nil
function PageBuilder:Reflow()
	local prevShown
	local total = PAGE_PADDING_TOP + PAGE_PADDING_BOTTOM

	for _, sec in ipairs(self.sections) do
		sec:ClearAllPoints()

		if sec:IsShown() then
			if not prevShown then
				sec:SetPoint("TOPLEFT", self.content, "TOPLEFT", PAGE_PADDING_X, -PAGE_PADDING_TOP)
				sec:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", -PAGE_PADDING_X, -PAGE_PADDING_TOP)
			else
				sec:SetPoint("TOPLEFT", prevShown, "BOTTOMLEFT", 0, -SECTION_SPACING)
				sec:SetPoint("TOPRIGHT", prevShown, "BOTTOMRIGHT", 0, -SECTION_SPACING)
				total = total + SECTION_SPACING
			end

			total = total + (sec:GetHeight() or 0)
			prevShown = sec
		end
	end

	local viewH = self.scrollFrame:GetHeight() or 0
	total = math.max(total, viewH - 1)

	self.content:SetHeight(total)
end


