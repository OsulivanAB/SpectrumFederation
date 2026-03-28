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
local INFO_BUTTON_SIZE       = S.infoButtonSize or 14
local INFO_BUTTON_GAP        = S.infoButtonGap or 2
local INFO_BUTTON_OFFSET_Y   = S.infoButtonOffsetY or 4

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

local function NormalizeSectionOptions(titleOrOptions, tooltipText)
	if type(titleOrOptions) == "table" then
		return {
			title = titleOrOptions.title,
			tooltip = titleOrOptions.tooltip,
		}
	end

	return {
		title = titleOrOptions,
		tooltip = tooltipText,
	}
end

local function SetTooltipHandlers(region, title, text)
	if not region then return end

	if not text or text == "" then
		region:SetScript("OnEnter", nil)
		region:SetScript("OnLeave", nil)
		return
	end

	region:EnableMouse(true)
	region:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title or "", 1, 1, 1)
		GameTooltip:AddLine(text, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	region:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

-- Create a new Section frame widget
-- @param parent Frame Parent frame to attach section to
-- @param title string|nil Section title text
-- @return Frame Section frame with mixin methods
function UI.Section:Create(parent, titleOrOptions, tooltipText)
	local options = NormalizeSectionOptions(titleOrOptions, tooltipText)
	local frame = CreateFrame("Frame", nil, parent)
	Mix(frame, SectionMixin)
	frame:Init(options)
	return frame
end

-- Initialize the section frame layout and header
-- @param title string|nil Section title text
-- @return nil
function SectionMixin:Init(titleOrOptions)
	local options = NormalizeSectionOptions(titleOrOptions)
	self.title = options.title or ""
	self.tooltipText = options.tooltip or ""
	self._rows = {}
	self._contentHeight = 0

	-- Header frame
	local header = CreateFrame("Frame", nil, self)
	self.Header = header
	header:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
	header:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
	header:SetHeight(HEADER_HEIGHT)

	local titleContainer = CreateFrame("Frame", nil, header)
	self.HeaderTitleContainer = titleContainer
	titleContainer:SetPoint("CENTER", header, "CENTER", 0, 0)
	titleContainer:SetHeight(HEADER_HEIGHT)
	titleContainer:SetWidth(1)

	-- Header label and info icon container
	local label = header:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	self.HeaderLabel = label
	label:SetPoint("LEFT", titleContainer, "LEFT", 0, 0)
	label:SetJustifyH("LEFT")
	label:SetText(self.title)

	local infoButton = CreateFrame("Button", nil, titleContainer)
	self.HeaderInfoButton = infoButton
	infoButton:SetSize(INFO_BUTTON_SIZE, INFO_BUTTON_SIZE)
	infoButton:SetPoint("TOPLEFT", label, "TOPRIGHT", INFO_BUTTON_GAP, INFO_BUTTON_OFFSET_Y)
	infoButton:SetHitRectInsets(-4, -4, -4, -4)
	infoButton:Hide()

	local icon = infoButton:CreateTexture(nil, "ARTWORK")
	self.HeaderInfoIcon = icon
	icon:SetAllPoints(infoButton)
	icon:SetTexture("Interface\\Common\\help-i")
	icon:SetVertexColor(1, 0.82, 0.18, 0.95)

	local highlight = infoButton:CreateTexture(nil, "HIGHLIGHT")
	self.HeaderInfoHighlight = highlight
	highlight:SetAllPoints(infoButton)
	highlight:SetTexture("Interface\\Common\\help-i")
	highlight:SetBlendMode("ADD")
	highlight:SetVertexColor(1, 1, 1, 0.35)

	-- Left line segment
	local leftLine = header:CreateTexture(nil, "ARTWORK")
	self.LeftLine = leftLine
	leftLine:SetColorTexture(1, 1, 1, LINE_ALPHA)
	leftLine:SetHeight(LINE_THICKNESS)
	leftLine:SetPoint("LEFT", header, "LEFT", 0, 0)
	leftLine:SetPoint("RIGHT", titleContainer, "LEFT", -TITLE_GAP, 0)

	-- Right line segment
	local rightLine = header:CreateTexture(nil, "ARTWORK")
	self.RightLine = rightLine
	rightLine:SetColorTexture(1, 1, 1, LINE_ALPHA)
	rightLine:SetHeight(LINE_THICKNESS)
	rightLine:SetPoint("LEFT", titleContainer, "RIGHT", TITLE_GAP, 0)
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

	self:_UpdateHeaderLayout()
	
	self:ReflowRows()
end

function SectionMixin:_UpdateHeaderLayout()
	local titleWidth = math.max(1, self.HeaderLabel:GetStringWidth() or 0)
	local hasTooltip = self.tooltipText and self.tooltipText ~= ""
	local buttonWidth = 0

	if hasTooltip then
		self.HeaderInfoButton:Show()
		buttonWidth = INFO_BUTTON_SIZE + INFO_BUTTON_GAP
	else
		self.HeaderInfoButton:Hide()
	end

	self.HeaderTitleContainer:SetWidth(titleWidth + buttonWidth)
	SetTooltipHandlers(self.HeaderInfoButton, self.title, self.tooltipText)
end

-- Set the section title text
-- @param title string|nil New title text
-- @return nil
function SectionMixin:SetTitle(title)
	self.title = title or ""
	self.HeaderLabel:SetText(self.title)
	self:_UpdateHeaderLayout()
end

-- Set the section header tooltip text
-- @param text string|nil Tooltip text shown from header info icon
-- @return nil
function SectionMixin:SetTooltipText(text)
	self.tooltipText = text or ""
	self:_UpdateHeaderLayout()
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
	return self:AddRow(20, function(row)
		local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		fs:SetPoint("LEFT", row, "LEFT", 0, 0)
		fs:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		fs:SetJustifyH("LEFT")
		fs:SetText(text or "")
	end)
end

-- Heading helper for emphasized labels
function SectionMixin:AddHeading(text)
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
