-- Grab the namespace
local addonName, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

UI.Section = UI.Section or {}

local Style = UI.Style or {}
local S = Style.Section

-- Styling constants (centralized)
local HEADER_HEIGHT          = S.headerHeight or 22
local LINE_THICKNESS         = S.lineThickness or 1
local LINE_ALPHA             = S.lineAlpha or 0.28
local TITLE_GAP              = S.titleGap or 10

local CONTENT_INSET_X        = S.contentInsetX or 12
local CONTENT_PADDING_TOP    = S.paddingTop or 10
local CONTENT_PADDING_BOTTOM = S.paddingBottom or 12
local ROW_SPACING            = S.rowSpacing or 8

local MSG_PAD_X				 = S.messagePaddingX or 10
local MSG_PAD_Y				 = S.messagePaddingY or 6
local MSG_BG_ALPHA			 = S.messageBgAlpha or 0.18

-- Instance methods (mixed into each section frame)
local SectionMixin = {}

-- Safe mixin fallback (Retail has Mixin, but this keeps it robust)
local function ApplyMixin(obj, mixin)
	for k, v in pairs(mixin) do
		obj[k] = v
	end
	return obj
end
local Mix = _G.Mixin or ApplyMixin

-- Create a new Section frame widget
-- @param parent Frame Parent frame to attach section to
-- @param title string|nil Section title text
-- @return Frame Section frame with mixin methods
function UI.Section:Create(parent, title)
	local frame = CreateFrame("Frame", nil, parent)
	Mix(frame, SectionMixin)
	frame:Init(title)
	return frame
end

-- Initialize the section frame layout and header
-- @param title string|nil Section title text
-- @return nil
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

	-- Message row (hidden by default)
	local msg = CreateFrame("Frame", nil, content)
	self.MessageRow = msg
	msg:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
	msg:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
	msg:SetHeight(0)
	msg:Hide()

	local bg = msg:CreateTexture(nil, "BACKGROUND")
	self.MessageBg = bg
	bg:SetAllPoints(msg)
	bg:SetColorTexture(0, 0, 0, MSG_BG_ALPHA)

	local msgText = msg:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.MessageText = msgText
	msgText:SetPoint("TOPLEFT", msg, "TOPLEFT", MSG_PAD_X, -MSG_PAD_Y)
	msgText:SetPoint("TOPRIGHT", msg, "TOPRIGHT", -MSG_PAD_X, MSG_PAD_Y)
	msgText:SetJustifyH("LEFT")
	msgText:SetJustifyV("TOP")
	msgText:SetWordWrap(true)
	msgText:SetText("")

	-- Resize message height if the section width changes
	content:HookScript("OnSizeChanged", function()
		if self.MessageRow:IsShown() then
			self:_UpdateMessageHeight()
			self:ReflowRows()
			self:_NotifyPageReflow()
		end
	end)
	
	self:ReflowRows()
end

-- Set the section title text
-- @param title string|nil New title text
-- @return nil
function SectionMixin:SetTitle(title)
	self.title = title or ""
	self.HeaderLabel:SetText(self.title)
end

-- Adds a full-width row frame stacked vertically inside Content
-- Add a content row to the section
-- @param height number Row height in pixels
-- @param buildFn function|nil Optional builder to populate the row
-- @return Frame The created row frame
function SectionMixin:AddRow(height, buildFn)
	local row = CreateFrame("Frame", nil, self.Content)
	row:SetHeight(height)

	table.insert(self._rows, row)

	self:ReflowRows()
	self:_NotifyPageReflow()

	if buildFn then
		buildFn(row)
	end

	return row
end

-- Add an empty spacer row
-- @param height number Spacer height in pixels
-- @return Frame The created spacer row
function SectionMixin:AddSpacer(height)
	return self:AddRow(height, nil)
end

-- Add a text row with GameFontHighlightSmall
-- @param text string|nil Text to display
-- @return Frame The created text row
function SectionMixin:AddText(text)
	return self:AddRow(26, function(row)
		local fs = row:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
		fs:SetPoint("LEFT", row, "LEFT", 0, 0)
		fs:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		fs:SetJustifyH("LEFT")
		fs:SetTextColor(0.92, 0.98, 1.0)
		fs:SetText(text or "")
	end)
end

-- -------- Messages --------
local function MessageColor(kind)
	if kind == "error" then
		return 1, 0.25, 0.25
	elseif kind == "success" then
		return 0.25, 1, 0.25
	elseif kind == "warn" then
		return 1, 0.82, 0
	else
		return 1, 1, 1
	end
end

-- Internal: recalc message row height based on content width/text
-- @return nil
function SectionMixin:_UpdateMessageHeight()
	-- Compute a reasonable height for wrapped text
	local width = (self.Content:GetWidth() or 0) - (MSG_PAD_X * 2)
	if width < 60 then width = 300 end

	self.MessageText:SetWidth(width)

	local h = self.MessageText:GetStringHeight() or 0
	local howH = math.max(18 + MSG_PAD_Y * 2, h + MSG_PAD_Y * 2 + 2)
	self.MessageRow:SetHeight(howH)
end

-- Show a message row with colored text
-- @param text string Message to display
-- @param kind string|nil Kind of message (error|success|warn|info)
-- @return nil
function SectionMixin:SetMessage(text, kind)
	text = tostring(text or "")
	if text == "" then
		return self:ClearMessage()
	end

	local r, g, b = MessageColor(kind)
	self.MessageText:SetTextColor(r, g, b)
	self.MessageText:SetText(text)

	self.MessageRow:Show()
	self:_UpdateMessageHeight()
	self:ReflowRows()
	self:_NotifyPageReflow()
end

-- Clear and hide the message row
-- @return nil
function SectionMixin:ClearMessage()
	if not self.MessageRow:IsShown() then return end
	self.MessageText:SetText("")
	self.MessageRow:SetHeight(0)
	self.MessageRow:Hide()
	self:ReflowRows()
	self:_NotifyPageReflow()
end

-- -------- Layout --------
-- Reflow row positions and content height
-- @return nil
function SectionMixin:ReflowRows()
	local contentHeight = 0
	local prev

	-- Postition message (if shown)
	if self.MessageRow:IsShown() then
		self.MessageRow:ClearAllPoints()
		self.MessageRow:SetPoint("TOPLEFT", self.Content, "TOPLEFT", 0, 0)
		self.MessageRow:SetPoint("TOPRIGHT", self.Content, "TOPRIGHT", 0, 0)

		prev = self.MessageRow
		contentHeight = contentHeight + (self.MessageRow:GetHeight() or 0)
	else
		prev = nil
	end

	-- Stack visible rows
	for _, row in ipairs(self._rows) do
		row:ClearAllPoints()

		if row:IsShown() then
			if prev then
				row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -ROW_SPACING)
				row:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -ROW_SPACING)
				contentHeight = contentHeight + ROW_SPACING + (row:GetHeight() or 0)
			else
				-- First visible row: anchor to content top
				row:SetPoint("TOPLEFT", self.Content, "TOPLEFT", 0, 0)
				row:SetPoint("TOPRIGHT", self.Content, "TOPRIGHT", 0, 0)
				contentHeight = contentHeight + (row:GetHeight() or 0)
			end
			prev = row
		end
	end

	self.Content:SetHeight(math.max(1, contentHeight))
	self:_UpdateHeight()
end

-- Internal: recalc section frame height based on content
-- @return nil
function SectionMixin:_UpdateHeight()
	local contentHeight = self.Content:GetHeight() or 0
	local total =
		HEADER_HEIGHT
		+ CONTENT_PADDING_TOP
		+ contentHeight
		+ CONTENT_PADDING_BOTTOM

	self:SetHeight(total)
end

-- Notify owning PageBuilder to reflow layout
-- @return nil
function SectionMixin:_NotifyPageReflow()
	local pb = self.__sfPageBuilder
	if pb and pb.Reflow then
		pb:Reflow()
		
	end
end

-- Schedule a deferred reflow to coalesce multiple requests
-- @return nil
function SectionMixin:RequestReflow()
	-- Coalesce multiple requests into a single next-frame reflow
	if self.__sfReflowScheduled then return end
	self.__sfReflowScheduled = true

	if C_Timer and C_Timer.After then
		C_Timer.After(0, function()
			self.__sfReflowScheduled = false
			self:ReflowRows()
			self:_NotifyPageReflow()
		end)
	else
		self.__sfReflowScheduled = false
		self:ReflowRows()
		self:_NotifyPageReflow()
	end
end
