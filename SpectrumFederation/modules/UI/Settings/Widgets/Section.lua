-- Grab the namespace
local addonName, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

UI.Section = UI.Section or {}

-- Instance methods (mixed into each section frame)
local SectionMixin = {}

-- Styling constants (centralized)
local HEADER_HEIGHT          = 22
local LINE_THICKNESS         = 1
local LINE_ALPHA             = 0.28
local TITLE_GAP              = 10

local CONTENT_INSET_X        = 12
local CONTENT_PADDING_TOP    = 10
local CONTENT_PADDING_BOTTOM = 12

local ROW_SPACING            = 8

-- Safe mixin fallback (Retail has Mixin, but this keeps it robust)
local function ApplyMixin(obj, mixin)
	for k, v in pairs(mixin) do
		obj[k] = v
	end
	return obj
end

local Mix = _G.Mixin or ApplyMixin

function UI.Section:Create(parent, title)
	local frame = CreateFrame("Frame", nil, parent)
	Mix(frame, SectionMixin)
	frame:Init(title)
	return frame
end

function SectionMixin:Init(title)
	self.title = title or ""
	self._rows = {}
	self._contentHeight = 0

	-- Header frame
	local header = CreateFrame("Frame", nil, self)
	self.Header = header
	header:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
	header:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
	header:SetHeight(HEADER_HEIGHT)

	-- Header label (centered)
	local label = header:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	self.HeaderLabel = label
	label:SetPoint("CENTER", header, "CENTER", 0, 0)
	label:SetText(self.title)

	-- Left line segment
	local leftLine = header:CreateTexture(nil, "ARTWORK")
	self.LeftLine = leftLine
	leftLine:SetColorTexture(1, 1, 1, LINE_ALPHA)
	leftLine:SetHeight(LINE_THICKNESS)
	leftLine:SetPoint("LEFT", header, "LEFT", 0, 0)
	leftLine:SetPoint("RIGHT", label, "LEFT", -TITLE_GAP, 0)

	-- Right line segment
	local rightLine = header:CreateTexture(nil, "ARTWORK")
	self.RightLine = rightLine
	rightLine:SetColorTexture(1, 1, 1, LINE_ALPHA)
	rightLine:SetHeight(LINE_THICKNESS)
	rightLine:SetPoint("LEFT", label, "RIGHT", TITLE_GAP, 0)
	rightLine:SetPoint("RIGHT", header, "RIGHT", 0, 0)

	-- Content container
	local content = CreateFrame("Frame", nil, self)
	self.Content = content
	content:SetPoint("TOPLEFT", header, "BOTTOMLEFT", CONTENT_INSET_X, -CONTENT_PADDING_TOP)
	content:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -CONTENT_INSET_X, -CONTENT_PADDING_TOP)
	content:SetHeight(1)

	-- Minimum height (header + padding)
	self:SetHeight(HEADER_HEIGHT + CONTENT_PADDING_TOP + CONTENT_PADDING_BOTTOM)
end

function SectionMixin:SetTitle(title)
	self.title = title or ""
	self.HeaderLabel:SetText(self.title)
end

-- Adds a full-width row frame stacked vertically inside Content
function SectionMixin:AddRow(height, buildFn)
	local row = CreateFrame("Frame", nil, self.Content)
	row:SetHeight(height)

	local numRows = #self._rows
	if numRows == 0 then
		row:SetPoint("TOPLEFT", self.Content, "TOPLEFT", 0, 0)
		row:SetPoint("TOPRIGHT", self.Content, "TOPRIGHT", 0, 0)
		self._contentHeight = height
	else
		local prev = self._rows[numRows]
		row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -ROW_SPACING)
		row:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -ROW_SPACING)
		self._contentHeight = self._contentHeight + ROW_SPACING + height
	end

	table.insert(self._rows, row)

	-- Update content + section height
	self.Content:SetHeight(self._contentHeight)
	self:_UpdateHeight()

	if buildFn then
		buildFn(row)
	end

	return row
end

function SectionMixin:AddSpacer(height)
	return self:AddRow(height, nil)
end

function SectionMixin:AddText(text)
	return self:AddRow(18, function(row)
		local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", row, "LEFT", 0, 0)
		fs:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		fs:SetJustifyH("LEFT")
		fs:SetText(text or "")
	end)
end

function SectionMixin:_UpdateHeight()
	local total =
		HEADER_HEIGHT
		+ CONTENT_PADDING_TOP
		+ (self._contentHeight > 0 and self._contentHeight or 0)
		+ CONTENT_PADDING_BOTTOM

	self:SetHeight(total)
end

