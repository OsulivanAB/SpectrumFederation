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
	self.layout = panel.__sfPageLayout or {}
	self.sections = {}
	self.refreshCallbacks = {}

	if self.layout.disablePageScroll then
		local host = CreateFrame("Frame", nil, panel)
		self.scrollFrame = host
		host:SetAllPoints(panel)

		local content = CreateFrame("Frame", nil, host)
		self.content = content
		content:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
		content:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
		content:SetHeight(1)

		local function UpdateContentWidth()
			local w = host:GetWidth() or 0
			content:SetWidth(math.max(1, w))
		end

		host:HookScript("OnSizeChanged", function()
			UpdateContentWidth()
			self:Reflow()
		end)

		UpdateContentWidth()
		return
	end

	local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	self.scrollFrame = scroll
	
	local SCROLLBAR_INSET = 24
	local SCROLLBAR_RIGHT_OFFSET = -2
	local SCROLLBAR_BUTTON_CLEARANCE = 8
	scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -SCROLLBAR_INSET, 0)

	if scroll.ScrollBar then
		scroll.ScrollBar:ClearAllPoints()
		scroll.ScrollBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", SCROLLBAR_RIGHT_OFFSET, -(16 + SCROLLBAR_BUTTON_CLEARANCE))
		scroll.ScrollBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", SCROLLBAR_RIGHT_OFFSET, 16 + SCROLLBAR_BUTTON_CLEARANCE)
	end

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

function PageBuilder:AddSection(titleOrOptions)
	local title = titleOrOptions
	if type(titleOrOptions) == "table" then
		title = titleOrOptions.title
	end
	if SF.Debug then
		SF.Debug:Verbose("UI", "Adding section '%s' to page", tostring(title))
	end
	local section = UI.Section:Create(self.content, titleOrOptions)
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
	local visibleSections = {}
	local fillSections = {}

	for _, sec in ipairs(self.sections) do
		if sec.ClearAssignedHeight then
			sec:ClearAssignedHeight()
		end
		if sec:IsShown() then
			table.insert(visibleSections, sec)
			if sec.__sfFillHeight then
				table.insert(fillSections, sec)
			end
		end
	end

	local naturalTotal = PAGE_PADDING_TOP + PAGE_PADDING_BOTTOM
	for index, sec in ipairs(visibleSections) do
		if index > 1 then
			naturalTotal = naturalTotal + SECTION_SPACING
		end
		naturalTotal = naturalTotal + (sec:GetHeight() or 0)
	end

	local prevShown
	local total = PAGE_PADDING_TOP + PAGE_PADDING_BOTTOM
	local viewH = self.scrollFrame:GetHeight() or 0
	local extra = math.max(0, (viewH - 1) - naturalTotal)

	if #fillSections > 0 and extra > 0 then
		local extraPerSection = extra / #fillSections
		for _, sec in ipairs(fillSections) do
			if sec.SetAssignedHeight then
				sec:SetAssignedHeight((sec:GetHeight() or 0) + extraPerSection)
			end
		end
	end

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

	total = math.max(total, viewH - 1)

	self.content:SetHeight(total)
end


