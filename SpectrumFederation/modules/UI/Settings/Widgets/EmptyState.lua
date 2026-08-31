-- Grab the namespace
local addonName, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI
UI.EmptyState = UI.EmptyState or {}

local TEXTURE_CANDIDATES = {
	[[Interface\HelpFrame\HelpIcon-CharacterStuck]],
	[[Interface\HelpFrame\HelpIcon-Bug]],
	[[Interface\TutorialFrame\TutorialFrame-QuestionMark]],
	[[Interface\Icons\INV_Misc_QuestionMark]],
}

local EmptyStateMixin = {}

local function ApplyMixin(obj, mixin)
	for k, v in pairs(mixin) do
		obj[k] = v
	end
	return obj
end
local Mix = _G.Mixin or ApplyMixin

local function TextureLooksLoaded(texture)
	if not texture or not texture.GetTexture then
		return false
	end
	local ok, value = pcall(function()
		return texture:GetTexture()
	end)
	if not ok or value == nil or value == "" or value == 0 then
		return false
	end
	return true
end

local function TryApplyTexture(texture, path)
	if not texture or not path then
		return false
	end
	local ok = pcall(function()
		texture:SetTexture(path)
	end)
	if not ok then
		return false
	end
	return TextureLooksLoaded(texture)
end

function UI.EmptyState:Create(parent)
	local frame = CreateFrame("Frame", nil, parent)
	Mix(frame, EmptyStateMixin)
	frame:Init()
	return frame
end

function EmptyStateMixin:Init()
	self:Hide()

	self.art = self:CreateTexture(nil, "ARTWORK")
	self.art:SetSize(64, 64)
	self.art:SetPoint("CENTER", self, "CENTER", 0, 36)

	self.title = self:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	self.title:SetPoint("TOP", self.art, "BOTTOM", 0, -16)
	self.title:SetJustifyH("CENTER")
	self.title:SetTextColor(1, 1, 1, 1)

	self.body = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	self.body:SetPoint("TOP", self.title, "BOTTOM", 0, -10)
	self.body:SetWidth(420)
	self.body:SetJustifyH("CENTER")
	self.body:SetJustifyV("TOP")
	self.body:SetTextColor(0.82, 0.82, 0.82, 0.95)

	self:ApplyArt()
	self:SetCategory(nil)
end

function EmptyStateMixin:ApplyArt()
	local loaded = false
	for _, path in ipairs(TEXTURE_CANDIDATES) do
		if TryApplyTexture(self.art, path) then
			loaded = true
			break
		end
	end
	if loaded then
		self.art:Show()
	else
		self.art:SetTexture(nil)
		self.art:Hide()
	end
end

function EmptyStateMixin:SetCategory(category)
	local label = "This category"
	if type(category) == "table" then
		label = category.navLabel or category.name or label
	elseif type(category) == "string" and category ~= "" then
		label = category
	end

	self.title:SetText("Nothing to configure")
	self.body:SetText(
		label
			.. " doesn't have any settings pages yet.\n"
			.. "That's not a bug — it's just a very tidy category.\n"
			.. "When pages are added, they'll show up here."
	)
end
