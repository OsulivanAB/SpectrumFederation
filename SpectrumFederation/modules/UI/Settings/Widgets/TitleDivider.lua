-- Grab the namespace
local addonName, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

UI.TitleDivider = UI.TitleDivider or {}

local Style = UI.Style or {}
local S = Style.Section or {}

local LINE_THICKNESS = S.lineThickness or 1
local LINE_ALPHA = S.lineAlpha or 0.28
local TITLE_GAP = S.titleGap or 10
local INFO_BUTTON_SIZE = S.infoButtonSize or 14
local INFO_BUTTON_GAP = S.infoButtonGap or 2
local INFO_BUTTON_OFFSET_Y = S.infoButtonOffsetY or 4

local TitleDividerMixin = {}

local function ApplyMixin(obj, mixin)
	for k, v in pairs(mixin) do
		obj[k] = v
	end
	return obj
end
local Mix = _G.Mixin or ApplyMixin

local function SetTooltipHandlers(region, title, text)
	if not region then return end

	if not text or text == "" then
		GameTooltip:Hide()
		region:EnableMouse(false)
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

function UI.TitleDivider:Create(parent, title, tooltipText, opts)
	opts = type(opts) == "table" and opts or {}

	local frame = CreateFrame("Frame", nil, parent)
	Mix(frame, TitleDividerMixin)
	frame:Init(title, tooltipText, opts)
	return frame
end

function TitleDividerMixin:Init(title, tooltipText, opts)
	self.title = title or ""
	self.tooltipText = tooltipText or ""
	self.opts = opts or {}

	local titleContainer = CreateFrame("Frame", nil, self)
	self.TitleContainer = titleContainer
	titleContainer:SetPoint("CENTER", self, "CENTER", 0, 0)
	titleContainer:SetHeight(self:GetHeight() or 1)
	titleContainer:SetWidth(1)

	local fontObject = self.opts.fontObject or "GameFontNormal"

	local label = self:CreateFontString(nil, "ARTWORK", fontObject)
	self.Label = label
	label:SetPoint("LEFT", titleContainer, "LEFT", 0, 0)
	label:SetJustifyH("LEFT")
	label:SetText(self.title)

	local infoButton = CreateFrame("Button", nil, titleContainer)
	self.InfoButton = infoButton
	infoButton:SetSize(INFO_BUTTON_SIZE, INFO_BUTTON_SIZE)
	infoButton:SetPoint("LEFT", label, "RIGHT", INFO_BUTTON_GAP, INFO_BUTTON_OFFSET_Y)
	infoButton:SetHitRectInsets(-4, -4, -4, -4)
	infoButton:Hide()

	local icon = infoButton:CreateTexture(nil, "ARTWORK")
	self.InfoIcon = icon
	icon:SetAllPoints(infoButton)
	icon:SetTexture("Interface\\Common\\help-i")
	icon:SetVertexColor(1, 0.82, 0.18, 0.95)

	local highlight = infoButton:CreateTexture(nil, "HIGHLIGHT")
	self.InfoHighlight = highlight
	highlight:SetAllPoints(infoButton)
	highlight:SetTexture("Interface\\Common\\help-i")
	highlight:SetBlendMode("ADD")
	highlight:SetVertexColor(1, 1, 1, 0.35)

	local leftLine = self:CreateTexture(nil, "ARTWORK")
	self.LeftLine = leftLine
	leftLine:SetColorTexture(1, 1, 1, LINE_ALPHA)
	leftLine:SetHeight(LINE_THICKNESS)

	local rightLine = self:CreateTexture(nil, "ARTWORK")
	self.RightLine = rightLine
	rightLine:SetColorTexture(1, 1, 1, LINE_ALPHA)
	rightLine:SetHeight(LINE_THICKNESS)

	self:_UpdateLayout()
end

function TitleDividerMixin:_UpdateLayout()
	local titleWidth = math.max(1, self.Label:GetStringWidth() or 0)
	local hasTooltip = self.tooltipText and self.tooltipText ~= ""
	local buttonWidth = 0
	local rightAnchor = self.Label

	if hasTooltip then
		self.InfoButton:Show()
		buttonWidth = INFO_BUTTON_SIZE + INFO_BUTTON_GAP
		rightAnchor = self.InfoButton
	else
		GameTooltip:Hide()
		self.InfoButton:Hide()
	end

	self.TitleContainer:SetWidth(titleWidth + buttonWidth)

	self.LeftLine:ClearAllPoints()
	self.LeftLine:SetPoint("LEFT", self, "LEFT", 0, 0)
	self.LeftLine:SetPoint("RIGHT", self.Label, "LEFT", -TITLE_GAP, 0)

	self.RightLine:ClearAllPoints()
	self.RightLine:SetPoint("LEFT", rightAnchor, "RIGHT", TITLE_GAP, 0)
	self.RightLine:SetPoint("RIGHT", self, "RIGHT", 0, 0)

	SetTooltipHandlers(self.InfoButton, self.title, self.tooltipText)
end

function TitleDividerMixin:SetTitle(title)
	self.title = title or ""
	self.Label:SetText(self.title)
	self:_UpdateLayout()
end

function TitleDividerMixin:SetTooltipText(text)
	self.tooltipText = text or ""
	self:_UpdateLayout()
end

