local _, SF = ...

SF.SpellBookPingButtons = SF.SpellBookPingButtons or {}

local SpellBookPingButtons = SF.SpellBookPingButtons

local BLIZZARD_MACRO_UI = "Blizzard_MacroUI"
local PING_ATLASES = {
	"ping_chat_attack",
	"ping_chat_assist",
	"ping_chat_onmyway",
	"ping_chat_warning",
	"ping_chat_nonthreat",
}
local ATLAS_INFO_CACHE = {}

local function IsAddOnLoadedSafe(addOnName)
	if C_AddOns and C_AddOns.IsAddOnLoaded then
		return C_AddOns.IsAddOnLoaded(addOnName)
	end

	return false
end

local function HasAtlasInfo(asset)
	if type(asset) ~= "string" or not C_Texture or not C_Texture.GetAtlasInfo then
		return false
	end

	local cached = ATLAS_INFO_CACHE[asset]
	if cached ~= nil then
		return cached
	end

	cached = C_Texture.GetAtlasInfo(asset) ~= nil
	ATLAS_INFO_CACHE[asset] = cached
	return cached
end

local function ShouldShowPingIcons(provider)
	if not provider or provider.extraIconType ~= IconDataProviderExtraType.Spellbook then
		return false
	end

	if not provider.requestedIconTypes or not IconDataProviderIconType then
		return false
	end

	return tContains(provider.requestedIconTypes, IconDataProviderIconType.Spell)
end

local function ClearCustomIcon(button)
	if not button or not button.Icon then
		return
	end

	button.SFCustomIconAsset = nil
	button.Icon:SetTexCoord(0, 1, 0, 1)
end

function SpellBookPingButtons:Debug(level, message, ...)
	if not SF.Debug or not SF.Debug[level] then
		return
	end

	SF.Debug[level](SF.Debug, "MACRO_PING_ICONS", message, ...)
end

function SpellBookPingButtons:PatchIconDataProvider(provider)
	if not provider or provider.SFPingIconsPatched then
		return
	end

	local originalGetNumIcons = provider.GetNumIcons
	local originalGetIconByIndex = provider.GetIconByIndex

	provider.GetNumIcons = function(selfProvider)
		local numIcons = originalGetNumIcons(selfProvider)
		if ShouldShowPingIcons(selfProvider) then
			numIcons = numIcons + #PING_ATLASES
		end
		return numIcons
	end

	provider.GetIconByIndex = function(selfProvider, index)
		local baseCount = originalGetNumIcons(selfProvider)
		if index <= baseCount then
			return originalGetIconByIndex(selfProvider, index)
		end

		if ShouldShowPingIcons(selfProvider) then
			local offset = index - baseCount
			if offset >= 1 and offset <= #PING_ATLASES then
				return PING_ATLASES[offset]
			end
		end

		return originalGetIconByIndex(selfProvider, index)
	end

	provider.SFPingIconsPatched = true
	self:Debug("Info", "Patched Macro UI icon data provider with %d ping atlas icons", #PING_ATLASES)
end

function SpellBookPingButtons:InstallTextureHooks()
	if self.textureHooksInstalled then
		return true
	end

	if not SelectorButtonMixin or not SelectedIconButtonMixin then
		self:Debug("Warn", "Selector button mixins unavailable for ping icon hooks")
		return false
	end

	local originalSelectorSetIconTexture = SelectorButtonMixin.SetIconTexture
	local originalSelectorGetIconTexture = SelectorButtonMixin.GetIconTexture
	local originalSelectedSetIconTexture = SelectedIconButtonMixin.SetIconTexture
	local originalSelectedGetIconTexture = SelectedIconButtonMixin.GetIconTexture

	SelectorButtonMixin.SetIconTexture = function(button, iconTexture)
		if HasAtlasInfo(iconTexture) then
			button.SFCustomIconAsset = iconTexture
			button.Icon:SetAtlas(iconTexture, false)
			return
		end

		ClearCustomIcon(button)
		originalSelectorSetIconTexture(button, iconTexture)
	end

	SelectorButtonMixin.GetIconTexture = function(button)
		return button.SFCustomIconAsset or originalSelectorGetIconTexture(button)
	end

	SelectedIconButtonMixin.SetIconTexture = function(button, iconTexture)
		if HasAtlasInfo(iconTexture) then
			button.SFCustomIconAsset = iconTexture
			button.Icon:SetAtlas(iconTexture, false)
			return
		end

		ClearCustomIcon(button)
		originalSelectedSetIconTexture(button, iconTexture)
	end

	SelectedIconButtonMixin.GetIconTexture = function(button)
		return button.SFCustomIconAsset or originalSelectedGetIconTexture(button)
	end

	self.textureHooksInstalled = true
	self:Debug("Info", "Installed macro icon texture hooks for atlas rendering")
	return true
end

function SpellBookPingButtons:InstallMacroHooks()
	if self.macroHooksInstalled then
		return true
	end

	if not MacroFrameMixin or not MacroFrameMixin.RefreshIconDataProvider then
		self:Debug("Warn", "MacroFrameMixin unavailable for ping icon hooks")
		return false
	end

	local originalRefreshIconDataProvider = MacroFrameMixin.RefreshIconDataProvider
	MacroFrameMixin.RefreshIconDataProvider = function(frame, ...)
		local provider = originalRefreshIconDataProvider(frame, ...)
		SpellBookPingButtons:PatchIconDataProvider(provider)
		return provider
	end

	if MacroFrame and MacroFrame.RefreshIconDataProvider then
		local provider = MacroFrame:RefreshIconDataProvider()
		if provider then
			self:PatchIconDataProvider(provider)
		else
			self:Debug("Warn", "MacroFrame returned no icon data provider during ping icon hook install")
		end
	end

	self.macroHooksInstalled = true
	self:Debug("Info", "Installed Macro UI ping icon hooks")
	return true
end

function SpellBookPingButtons:TryInstallHooks()
	if not self:InstallTextureHooks() then
		return false
	end

	if not self:InstallMacroHooks() then
		return false
	end

	return true
end

function SpellBookPingButtons:OnEvent(event, ...)
	if event ~= "ADDON_LOADED" then
		return
	end

	local loadedAddonName = ...
	if loadedAddonName ~= BLIZZARD_MACRO_UI then
		return
	end

	if self:TryInstallHooks() then
		self.eventFrame:UnregisterEvent("ADDON_LOADED")
	end
end

function SpellBookPingButtons:Initialize()
	if self.initialized then
		return
	end

	self.initialized = true
	self.eventFrame = CreateFrame("Frame")
	self.eventFrame:SetScript("OnEvent", function(_, event, ...)
		self:OnEvent(event, ...)
	end)

	if IsAddOnLoadedSafe(BLIZZARD_MACRO_UI) and self:TryInstallHooks() then
		return
	end

	self.eventFrame:RegisterEvent("ADDON_LOADED")
end
