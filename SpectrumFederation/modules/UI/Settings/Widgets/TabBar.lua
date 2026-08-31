-- Grab the namespace
local addonName, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI
UI.TabBar = UI.TabBar or {}

local TAB_HEIGHT = 28
local TAB_GAP = 4
local TAB_PADDING_X = 12
local ACCENT = {0.45, 0.72, 1, 1}
local SELECTED_BG = {1, 1, 1, 0.08}
local HOVER_BG = {1, 1, 1, 0.04}
local TRANSPARENT = {0, 0, 0, 0}

local TabBarMixin = {}

local function ApplyMixin(obj, mixin)
	for k, v in pairs(mixin) do
		obj[k] = v
	end
	return obj
end
local Mix = _G.Mixin or ApplyMixin

local function CreateTabButton(parent, tab)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetHeight(TAB_HEIGHT)
	btn.tabId = tab.id

	btn.bg = btn:CreateTexture(nil, "BACKGROUND")
	btn.bg:SetAllPoints()
	btn.bg:SetColorTexture(unpack(TRANSPARENT))

	btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	btn.text:SetPoint("LEFT", btn, "LEFT", TAB_PADDING_X, 0)
	btn.text:SetPoint("RIGHT", btn, "RIGHT", -TAB_PADDING_X, 0)
	btn.text:SetJustifyH("CENTER")
	btn.text:SetText(tab.label or tab.id)

	btn.accent = btn:CreateTexture(nil, "ARTWORK")
	btn.accent:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 4, 1)
	btn.accent:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -4, 1)
	btn.accent:SetHeight(2)
	btn.accent:SetColorTexture(unpack(ACCENT))
	btn.accent:Hide()

	local textWidth = btn.text:GetStringWidth() or 0
	btn:SetWidth(math.max(72, textWidth + TAB_PADDING_X * 2))
	return btn
end

function UI.TabBar:Create(parent)
	local frame = CreateFrame("Frame", nil, parent)
	Mix(frame, TabBarMixin)
	frame:Init()
	return frame
end

function TabBarMixin:Init()
	self.tabs = {}
	self.buttons = {}
	self.selectedId = nil
	self.onSelect = nil

	self.scroll = CreateFrame("ScrollFrame", nil, self)
	self.scroll:SetAllPoints(self)
	self.scroll:EnableMouseWheel(true)

	self.child = CreateFrame("Frame", nil, self.scroll)
	self.child:SetHeight(TAB_HEIGHT)
	self.child:SetWidth(1)
	self.scroll:SetScrollChild(self.child)

	self.scroll:SetScript("OnMouseWheel", function(scroll, delta)
		local current = scroll:GetHorizontalScroll() or 0
		local maxScroll = math.max(0, (self.child:GetWidth() or 0) - (scroll:GetWidth() or 0))
		local nextScroll = math.max(0, math.min(maxScroll, current - (delta * 40)))
		scroll:SetHorizontalScroll(nextScroll)
	end)
end

function TabBarMixin:SetOnSelect(callback)
	self.onSelect = callback
end

function TabBarMixin:SetTabs(tabs)
	self.tabs = tabs or {}
	for _, btn in ipairs(self.buttons) do
		btn:Hide()
		btn:SetParent(nil)
	end
	self.buttons = {}

	local x = 0
	for _, tab in ipairs(self.tabs) do
		local btn = CreateTabButton(self.child, tab)
		btn:SetPoint("TOPLEFT", self.child, "TOPLEFT", x, 0)
		btn:SetScript("OnEnter", function(button)
			if button.tabId ~= self.selectedId then
				button.bg:SetColorTexture(unpack(HOVER_BG))
			end
		end)
		btn:SetScript("OnLeave", function()
			self:UpdateVisuals()
		end)
		btn:SetScript("OnClick", function(button)
			if self.onSelect then
				self.onSelect(button.tabId)
			end
		end)
		table.insert(self.buttons, btn)
		x = x + btn:GetWidth() + TAB_GAP
	end
	self.child:SetWidth(math.max(1, x - TAB_GAP))
	self:Layout()
	self:UpdateVisuals()
end

function TabBarMixin:SetSelected(tabId)
	self.selectedId = tabId
	self:UpdateVisuals()
end

function TabBarMixin:UpdateVisuals()
	for _, btn in ipairs(self.buttons) do
		local selected = btn.tabId == self.selectedId
		if selected then
			btn.bg:SetColorTexture(unpack(SELECTED_BG))
			btn.text:SetTextColor(1, 1, 1, 1)
			btn.accent:Show()
		else
			btn.bg:SetColorTexture(unpack(TRANSPARENT))
			btn.text:SetTextColor(0.82, 0.82, 0.82, 1)
			btn.accent:Hide()
		end
	end
end

function TabBarMixin:Layout()
	self.scroll:SetAllPoints(self)
	local maxScroll = math.max(0, (self.child:GetWidth() or 0) - (self.scroll:GetWidth() or 0))
	local current = self.scroll:GetHorizontalScroll() or 0
	if current > maxScroll then
		self.scroll:SetHorizontalScroll(maxScroll)
	end
end

function TabBarMixin:GetPreferredHeight()
	return TAB_HEIGHT
end
