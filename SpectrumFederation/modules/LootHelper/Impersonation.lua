-- modules/LootHelper/Impersonation.lua
-- Runtime-only "Preview as Non-Admin" local capability overlay.
-- Does not persist, does not change canonical admin/owner data, and does not
-- alter sync/protocol identity.

local addonName, SF = ...

-- luacheck: globals hooksecurefunc

SF.LootHelperImpersonation = SF.LootHelperImpersonation or {}
local Imp = SF.LootHelperImpersonation

local CATEGORY = "IMPERSONATION"
local USAGE = "Usage: /sf impersonate on|off|status"
local BANNER_TEXT = "IMPERSONATION MODE — Viewing the active profile as a non-admin. Your real profile role and sync identity are unchanged."

Imp._active = false
Imp._profileId = nil
Imp._listeners = {}
Imp._hooksInstalled = false
Imp._slashRegistered = false
Imp._inited = false

local function DebugInfo(message, ...)
	if SF.Debug and SF.Debug.Info then
		SF.Debug:Info(CATEGORY, message, ...)
	end
end

local function DebugWarn(message, ...)
	if SF.Debug and SF.Debug.Warn then
		SF.Debug:Warn(CATEGORY, message, ...)
	end
end

local function PrintInfo(message)
	if SF.PrintInfo then
		SF:PrintInfo(message)
	end
end

local function PrintSuccess(message)
	if SF.PrintSuccess then
		SF:PrintSuccess(message)
	end
end

local function PrintError(message)
	if SF.PrintError then
		SF:PrintError(message)
	end
end

local function GetActiveProfile()
	if SF.GetActiveProfile then
		return SF:GetActiveProfile()
	end
	return SF.lootHelperDB and SF.lootHelperDB.activeProfile or nil
end

local function GetProfileId(profile)
	if profile and type(profile.GetProfileId) == "function" then
		return profile:GetProfileId()
	end
	return SF.lootHelperDB and SF.lootHelperDB.activeProfileId or nil
end

local function ResolveProfile(profile)
	if profile ~= nil then
		return profile
	end
	return GetActiveProfile()
end

local function ClearRecord()
	Imp._active = false
	Imp._profileId = nil
end

local function NotifyListeners()
	local list = Imp._listeners
	if not list then
		return
	end
	for i = 1, #list do
		local fn = list[i]
		if type(fn) == "function" then
			pcall(fn)
		end
	end
end

local function RefreshSurfaces()
	if SF.SettingsWindow and type(SF.SettingsWindow.OnImpersonationChanged) == "function" then
		SF.SettingsWindow:OnImpersonationChanged()
	end
	local controller = SF.LootHelperWindow and SF.LootHelperWindow.Controller
	if controller and type(controller.RequestRefresh) == "function" then
		controller:RequestRefresh("ImpersonationChanged")
	end
	local equipment = SF.LootHelperWindow and SF.LootHelperWindow.EquipmentWindow
	if equipment and equipment.IsShown and equipment:IsShown() and type(equipment.Refresh) == "function" then
		equipment:Refresh()
	end
end

local function EmitTransition()
	NotifyListeners()
	RefreshSurfaces()
end

function Imp:GetBannerText()
	return BANNER_TEXT
end

-- Raw runtime record for tests and invalidation. Not a capability query.
-- @return table { active = boolean, profileId = string|nil }
function Imp:GetRuntimeState()
	return {
		active = self._active and true or false,
		profileId = self._profileId,
	}
end

function Imp:GetBoundProfileId()
	if not self._active then
		return nil
	end
	return self._profileId
end

-- True only while previewing the currently active profile.
-- @return boolean
function Imp:IsActive()
	if not self._active or type(self._profileId) ~= "string" or self._profileId == "" then
		return false
	end
	local currentId = GetProfileId(GetActiveProfile())
	return currentId ~= nil and currentId == self._profileId
end

function Imp:IsCanonicalAdmin(profile)
	profile = ResolveProfile(profile)
	if not profile or type(profile.IsCurrentUserAdmin) ~= "function" then
		return false
	end
	return profile:IsCurrentUserAdmin() and true or false
end

function Imp:IsCanonicalOwner(profile)
	profile = ResolveProfile(profile)
	if not profile or type(profile.IsCurrentUserOwner) ~= "function" then
		return false
	end
	return profile:IsCurrentUserOwner() and true or false
end

function Imp:IsEffectiveLocalAdmin(profile)
	profile = ResolveProfile(profile)
	if not self:IsCanonicalAdmin(profile) then
		return false
	end
	local profileId = GetProfileId(profile)
	if self._active and self._profileId and profileId and profileId == self._profileId then
		return false
	end
	return true
end

function Imp:IsEffectiveLocalOwner(profile)
	profile = ResolveProfile(profile)
	if not self:IsCanonicalOwner(profile) then
		return false
	end
	local profileId = GetProfileId(profile)
	if self._active and self._profileId and profileId and profileId == self._profileId then
		return false
	end
	return true
end

function Imp:CanEnable()
	local profile = GetActiveProfile()
	if not profile then
		return false, "No active Loot Helper profile."
	end
	if not self:IsCanonicalAdmin(profile) then
		return false, "You must be an admin of the active Loot Helper profile to preview as a non-admin."
	end
	return true, nil
end

function Imp:CanShowToggle()
	local profile = GetActiveProfile()
	if not profile then
		return false
	end
	return self:IsCanonicalAdmin(profile) or self:IsActive()
end

function Imp:RegisterCallback(fn)
	if type(fn) ~= "function" then
		return
	end
	self._listeners = self._listeners or {}
	table.insert(self._listeners, fn)
end

function Imp:Enable()
	local ok, err = self:CanEnable()
	if not ok then
		DebugWarn("Enable denied: %s", tostring(err))
		return false, err
	end

	local profile = GetActiveProfile()
	local profileId = GetProfileId(profile)
	if type(profileId) ~= "string" or profileId == "" then
		DebugWarn("Enable denied: active profile has no id")
		return false, "No active Loot Helper profile."
	end

	if self._active and self._profileId == profileId then
		return true, nil
	end

	self._active = true
	self._profileId = profileId
	local name = (profile.GetProfileName and profile:GetProfileName()) or profileId
	DebugInfo("Enabled for profile %s (%s)", tostring(name), tostring(profileId))
	EmitTransition()
	return true, nil
end

function Imp:Disable(reason)
	if not self._active and self._profileId == nil then
		return false, nil
	end
	local wasActive = self._active and true or false
	ClearRecord()
	if wasActive then
		DebugInfo("Disabled (reason=%s)", tostring(reason or "manual"))
		EmitTransition()
		return true, nil
	end
	return false, nil
end

function Imp:Invalidate(reason)
	return self:Disable(reason or "invalidate")
end

function Imp:ValidateBoundState(reason)
	if not self._active and self._profileId == nil then
		return
	end
	if not self._active then
		self._profileId = nil
		return
	end

	local profile = GetActiveProfile()
	local currentId = GetProfileId(profile)
	if not profile or type(currentId) ~= "string" or currentId ~= self._profileId then
		self:Invalidate(reason or "profile-switch")
		if reason == "reset-all" then
			PrintInfo("Impersonation mode ended because Loot Helper settings were reset.")
		elseif reason == "lost-admin" then
			PrintInfo("Impersonation mode ended because you are no longer an admin of this profile.")
		else
			PrintInfo("Impersonation mode ended because the active profile changed.")
		end
		return
	end

	if not self:IsCanonicalAdmin(profile) then
		self:Invalidate("lost-admin")
		PrintInfo("Impersonation mode ended because you are no longer an admin of this profile.")
	end
end

local function FormatStatus()
	if not Imp._active then
		return "Impersonation mode is off."
	end
	local profile = GetActiveProfile()
	local name = (profile and profile.GetProfileName and profile:GetProfileName()) or Imp._profileId or "unknown"
	local id = Imp._profileId or "unknown"
	local canonical = Imp:IsCanonicalAdmin(profile) and "yes" or "no"
	local effective = Imp:IsEffectiveLocalAdmin(profile) and "yes" or "no"
	return string.format(
		"Impersonation mode is on for profile %s (%s). Canonical admin: %s. Effective local admin: %s.",
		tostring(name),
		tostring(id),
		canonical,
		effective
	)
end

function Imp:HandleSlash(args)
	args = tostring(args or ""):match("^%s*(.-)%s*$") or ""
	if args == "" then
		PrintInfo(FormatStatus())
		PrintInfo(USAGE)
		return
	end
	if args == "status" then
		PrintInfo(FormatStatus())
		return
	end
	if args == "on" then
		local alreadyOn = self:IsActive()
		local ok, err = self:Enable()
		if not ok then
			PrintError(err or "Cannot enable impersonation mode.")
		elseif alreadyOn then
			PrintInfo("Impersonation mode is already on.")
		else
			PrintSuccess("Impersonation mode enabled. Local UI now matches a non-admin. Sync identity is unchanged.")
		end
		return
	end
	if args == "off" then
		local changed = self:Disable("slash")
		if changed then
			PrintSuccess("Impersonation mode disabled.")
		else
			PrintInfo("Impersonation mode is already off.")
		end
		return
	end
	DebugWarn("Unsupported impersonate argument: %s", tostring(args))
	PrintError(USAGE)
end

local function HookAfter(tbl, methodName, hookFn)
	if type(tbl) ~= "table" or type(tbl[methodName]) ~= "function" then
		return false
	end
	if hooksecurefunc then
		hooksecurefunc(tbl, methodName, hookFn)
		return true
	end
	local original = tbl[methodName]
	tbl[methodName] = function(...)
		local results = { original(...) }
		hookFn(...)
		return unpack(results)
	end
	return true
end

function Imp:InstallHooks()
	if self._hooksInstalled then
		return
	end
	self._hooksInstalled = true

	HookAfter(SF, "SetActiveProfileById", function()
		Imp:ValidateBoundState("active-profile")
	end)
	HookAfter(SF, "ClearActiveProfile", function()
		Imp:ValidateBoundState("clear-active-profile")
	end)
	HookAfter(SF, "ResetAllLootHelperSettings", function()
		if Imp._active or Imp._profileId ~= nil then
			Imp:Invalidate("reset-all")
			PrintInfo("Impersonation mode ended because Loot Helper settings were reset.")
		end
	end)

	local LP = SF.LootProfile
	if type(LP) == "table" then
		HookAfter(LP, "RemoveAdminMemberId", function()
			Imp:ValidateBoundState("admin-removed")
		end)
		HookAfter(LP, "ImportSnapshot", function()
			Imp:ValidateBoundState("import-snapshot")
		end)
	end

	local Store = SF.SettingsStore
	if type(Store) == "table" then
		HookAfter(Store, "SetActiveLootHelperProfileId", function()
			Imp:ValidateBoundState("store-active-profile")
		end)
		HookAfter(Store, "Set", function(_, path)
			if path == "lootHelper.activeProfileId" then
				Imp:ValidateBoundState("store-set-active-profile-id")
			end
		end)
		HookAfter(Store, "ResetAll", function()
			if Imp._active or Imp._profileId ~= nil then
				Imp:Invalidate("store-reset-all")
				PrintInfo("Impersonation mode ended because Loot Helper settings were reset.")
			end
		end)
	end

	local Sync = SF.LootHelperSync
	if type(Sync) == "table" then
		HookAfter(Sync, "RebuildProfile", function()
			Imp:ValidateBoundState("sync-rebuild")
		end)
	end
end

function Imp:Init()
	if self._inited then
		return
	end
	self._inited = true
	self:InstallHooks()

	if not self._slashRegistered and SF.RegisterSlashCommand then
		SF:RegisterSlashCommand("impersonate", function(args)
			Imp:HandleSlash(args)
		end, "Preview the active profile as a non-admin (on|off|status)")
		self._slashRegistered = true
	end
end
