-- modules/UI/Settings/Pages/LootHelper.lua
local _, SF = ...

local Page = {
	id = "lootHelper",
	parentId = "main",
	name = "Loot Helper Settings",
	order = 20,
}

-- ==================================================================
-- Helpers
-- ==================================================================
-- Get the active loot helper profile runtime object
-- @param store table Settings store
-- @return table|nil Profile object or nil if unavailable
local function GetActiveProfileObject(store)
	-- TODO: Implement later
	-- Return a runtime profile object with:
	--	:IsCurrentUserAdmin()
	--	:getAdminMemberIds()
	--	:getMemberByID(id)
	--	:getMemberIds()
	-- Optional:
	--	ownerId or :GetOwnerId()
	if store and store.GetActiveLootHelperProfileObject then
		return store:GetActiveLootHelperProfileObject()
	end
	if SF and SF.lootHelperDB then
		return SF.lootHelperDB.activeProfile
	end
	return nil
end

-- Get the active loot helper profile ID (prefers new key, falls back to legacy)
-- @param store table Settings store
-- @return string|nil Active profile ID or name
local function GetActiveProfileId(store)
	if store and store.GetActiveLootHelperProfileId then
		local id = store:GetActiveLootHelperProfileId()
		if id ~= nil then return id end
	end

	local id = store:Get("lootHelper.activeProfileId")
	if id ~= nil then return id end

	if SF and SF.lootHelperDB and SF.lootHelperDB.activeProfileId then
		return SF.lootHelperDB.activeProfileId
	end

	return store:Get("lootHelper.activeProfile")
end

-- Determine if any loot helper profiles exist (placeholder)
-- @param store table Settings store
-- @return boolean,string|nil False with message until implemented
local function HasAnyProfiles(store)
	if store and store.HasActiveLootHelperProfile then
		if store:HasActiveLootHelperProfile() then
			return true
		end
	end
	if store and store.HasLootHelperProfiles then
		local hasAny = store:HasLootHelperProfiles()
		if hasAny then
			return true
		end
	end
	if store and store.GetLootHelperProfiles then
		local profiles = store:GetLootHelperProfiles()
		if type(profiles) == "table" and next(profiles) ~= nil then
			return true
		end
	end
	if SF and SF.lootHelperDB and type(SF.lootHelperDB.profiles) == "table" then
		if next(SF.lootHelperDB.profiles) ~= nil then
			return true
		end
	end
	local opts = GetProfileOptions(store)
	return type(opts) == "table" and #opts > 0
end

-- Get profile dropdown options
-- @param store table Settings store
-- @return table Array of {value,label} options
local function GetProfileOptions(store)
	if store and store.GetLootHelperProfileOptions then
		return store:GetLootHelperProfileOptions()
	end
	if store and store.GetLootHelperProfileOptionsSorted then
		return store:GetLootHelperProfileOptionsSorted()
	end
	return {}
end

-- Check whether admin tools should be visible (placeholder true)
-- @param ctx table Context table
-- @return boolean Always true until real check added
local function CanShowAdminTools(ctx)
	-- TODO: Call profiles API function to ask if current user is admin
	return true
end

-- ==================================================================
-- Page Definition
-- ==================================================================
-- Build the Loot Helper settings page UI
-- @param panel Frame Settings panel frame
-- @return nil
function Page:Build(panel)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Building LootHelper settings page")
	end

	local renderer = SF.SettingsUI.DefinitionRenderer
	local dialogs = SF.SettingsUI.Dialogs
	local store = SF.SettingsStore

	-- UI state(not persisted): selected member to add as admin
	panel.__sfAddAdmininSelectedId = panel.__sfAddAdmininSelectedId or nil

	local function HasActiveProfile()
		if GetActiveProfileObject(store) ~= nil then
			return true
		end
		return GetActiveProfileId(store) ~= nil
	end

	local function ProfileActionsEnabled()
		return HasActiveProfile()
	end

	local function ToWoWHexColor(color)
		-- Accepts either a hex color string ("|cffrrggbb") or a table {r,g,b} in 0-1 range.
		if type(color) == "string" then
			return color
		end
		if type(color) == "table" then
			local r = tonumber(color.r or color[1] or 1) or 1
			local g = tonumber(color.g or color[2] or 1) or 1
			local b = tonumber(color.b or color[3] or 1) or 1
			r = math.min(math.max(r, 0), 1)
			g = math.min(math.max(g, 0), 1)
			b = math.min(math.max(b, 0), 1)
			return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
		end
		return "|cffffffff"
	end

	local function GetMemberClassColor(member)
		if type(member) == "table" then
			if type(member.GetClassColorCode) == "function" then
				return member:GetClassColorCode()
			end

			local className
			if type(member.getClass) == "function" then
				className = member:getClass()
			else
				className = member.class
			end

			if className and SF.WOW_CLASSES and SF.WOW_CLASSES[className] and SF.WOW_CLASSES[className].colorCode then
				return ToWoWHexColor(SF.WOW_CLASSES[className].colorCode)
			end
		end

		return "|cffffffff"
	end

	local function BuildOwnerDisplay()
		local profile = GetActiveProfileObject(store)
		if not profile then return "-" end

		local ownerId = nil
		if type(profile.GetOwnerId) == "function" then
			ownerId = profile:GetOwnerId()
		else
			ownerId = profile.ownerId
		end

		if not ownerId then
			return "-"
		end

		local name = tostring(ownerId)
		local color = "|cffffffff"

		if type(profile.getMemberByID) == "function" then
			local m = profile:getMemberByID(ownerId)
			if type(m) == "table" then
				name = m.member_name or m.name or name
				color = GetMemberClassColor(m)
			end
		end

		return color .. name .. "|r"
	end

	local function BuildAdminItems()
		local profile = GetActiveProfileObject(store)
		if not profile then return {} end
		if type(profile.getAdminMemberIds) ~= "function" or type(profile.getMemberByID) ~= "function" then
			return {}
		end

		local ownerId
		if type(profile.GetOwnerId) == "function" then
			ownerId = profile:GetOwnerId()
		else
			ownerId = profile.ownerId
		end

		local ids = profile:getAdminMemberIds() or {}
		local items = {}

		for _, memberId in ipairs(ids) do
			local m = profile:getMemberByID(memberId)
			local name = (type(m) == "table" and (m.member_name or m.name)) or tostring(memberId)
			local color = GetMemberClassColor(m)

			table.insert(items, {
				id = memberId,
				text = color .. name .. "|r",
				canRemove = (ownerId ~= nil) and (memberId ~= ownerId) or false,
			})
		end

		table.sort(items, function(a, b) return tostring(a.text) < tostring(b.text) end)
		return items


	end

	local function BuildMemberOptions()
		local profile = GetActiveProfileObject(store)
		if not profile or type(profile.getMemberIds) ~= "function" or type(profile.getMemberByID) ~= "function" then
			return {}
		end

		local out = {}
		for _, memberId in ipairs(profile:getMemberIds() or {}) do
			local m = profile:getMemberByID(memberId)
			local name = (type(m) == "table" and (m.member_name or m.name)) or tostring(memberId)
			local color = GetMemberClassColor(m)
			table.insert(out, { value = memberId, label = color .. name .. "|r", _sort = name })
		end

		table.sort(out, function(a, b) return tostring(a._sort) < tostring(b._sort) end)
		for _, item in ipairs(out) do item._sort = nil end
		return out
	end

	local def = {
		sections = {
			-- ==========================================================
			-- 1) General Settings (User-Level Settings)
			-- ==========================================================
			{
				id = "general",
				title = "General Settings",
				items = {
					{
						type = "checkbox",
						label = "Enable LootHelper",
						tooltip = "Enable or disable LootHelper on this character/client.",
						path = "lootHelper.enabled"
					},
					{
						type = "checkbox",
						label = "Enable Local Safemode",
						tooltip = "Local-only safemode. Independent from raid-wide safemode.",
						path = "lootHelper.localSafeMode",
					},
					{
						type = "checkbox",
						label = "Enable Local Safemode on Combat",
						tooltip = "Local-only: enable safemode automatically when entering combat.",
						path = "lootHelper.localSafeModeOnCombat",
					},
					
					{ type = "spacer", height = 10 },

					{
						type = "editboxButton",
						label = "Create Profile",
						hint = "Profile name",
						buttonText = "Create",
						buttonWidth = 90,
						editWidth = 170,
						tooltip = "Creates a new profile. Will automatically set it to active.",

						onSubmit = function(ctx, text, editBox)
							ctx.section:ClearMessage()

							if type(ctx.store.CreateLootHelperProfile) ~= "function" then
								ctx.section:SetMessage("CreateLootHelperProfile() not implemented", "error")
								return
							end

							local ok, err = ctx.store:CreateLootHelperProfile(text)
							if not ok then
								ctx.section:SetMessage(err or "Failed to create profile", "error")
								return
							end

							editBox:SetText("")
							ctx.section:SetMessage("Profile created.", "success")
							ctx.pageBuilder:Refresh()
						end,
					},

					{
						type = "button",
						label = "Reset All LootHelper Settings",
						buttonText = "Reset All",
						width = 140,
						tooltip = "Resets ALL LootHelper settings and deletes ALL profiles.",

						onClick = function(ctx)
							ctx.section:ClearMessage()

							if not dialogs or not dialogs.Confirm then
								ctx.section:SetMessage("Dialogs.Confirm not available.", "error")
								return
							end

							dialogs:Confirm(
								"Reset ALL LootHelper settings and delete ALL profiles?",
								"Reset All",
								function()
									if type(ctx.store.ResetAllLootHelperSettings) ~= "function" then
										ctx.section:SetMessage("ResetAllLootHelperSettings() not implemented", "error")
										return
									end

									local ok, err = ctx.store:ResetAllLootHelperSettings()
									if not ok then
										ctx.section:SetMessage(err or "Reset failed", "error")
										return
									end

									ctx.section:SetMessage("LootHelper reset complete.", "success")
									ctx.pageBuilder:Refresh()
								end
							)
						end,
					},
					{
						type = "checkbox",
						label = "Show Loot Window outside of Raid",
						tooltip = "When enabled, the Loot Helper window may appear even if you are not in a raid.",
						path = "lootHelper.showWindowOutsideRaid",
					},
					{
						type = "checkbox",
						label = "Lock Loot Window",
						tooltip = "When enabled, the Loot Helper window cannot be moved or resized.",
						path = "lootHelper.lockLootWindow",
					},
					{
						type = "checkbox",
						label = "Show Members not in raid",
						tooltip = "When disabled, profile members who are not currently in your raid will be hidden in the Loot Helper window.",
						path = "lootHelper.showMembersNotInRaid",
					},
				},
			},

			-- ==========================================================
			-- 2) Profile Settings
			-- ==========================================================
			{
				id = "profile",
				title = "Profile Settings",
				items = {
					{
						type = "help",
						text = "You currently have no profiles. Create one in General Section",
						indent = "label",
						visible = function()
							return not HasAnyProfiles(store) and not HasActiveProfile()
						end
					},

					{
						type = "dropdownIconButton",
						label = "Active Profile",
						tooltip = "Select the active profile (stored by ID)",
						defaultText = "Select profile",

						get = function()
							return GetActiveProfileId(store)
						end,
						set = function(value)
							if store.SetActiveLootHelperProfileId then
								store:SetActiveLootHelperProfileId(value)
							else
								store:Set("lootHelper.activeProfileId", value)
							end
						end,

						options = function()
							return GetProfileOptions(store)
						end,

						enabled = function()
							return HasAnyProfiles(store)
						end,

						iconAtlas = "common-icon-redx",
						iconTooltip = "Delete Active Profile",
						iconEnabled = function()
							return ProfileActionsEnabled()
						end,

						onValueChanged = function(ctx)
							ctx.section:ClearMessage()
							ctx.pageBuilder:Refresh()
						end,

						onIconClick = function(ctx)
							ctx.section:ClearMessage()

							local activeId = GetActiveProfileId(ctx.store)
							if not activeId then
								ctx.section:SetMessage("No active profile to delete.", "error")
								return
							end

							dialogs:Confirm(
								"Delete the active profile?",
								"Delete",
								function()
									if type(ctx.store.DeleteLootHelperProfile) ~= "function" then
										ctx.section:SetMessage("DeleteLootHelperProfile() not implemented", "error")
										return
									end

									local ok, err = ctx.store:DeleteLootHelperProfile(activeId)
									if not ok then
										ctx.section:SetMessage(err or "Failed to delete profile", "error")
										return
									end

									ctx.section:SetMessage("Profile deleted.", "success")
									ctx.pageBuilder:Refresh()
								end
							)
						end,
					},

					{
						type = "display",
						label = "Profile Owner",
						get = function()
							return BuildOwnerDisplay()
						end,
						visible = function()
							return HasActiveProfile()
						end,
					},

					{
						type = "button",
						label = "Manually Sync My Data",
						buttonText = "Sync",
						width = 120,
						enabled = function()
							return ProfileActionsEnabled()
						end,
						onClick = function(ctx)
							-- TODO: Trigger a manual sync of current user's data
							ctx.section:SetMessage("Stub: Manually Sync My Data (implement later).", "warn")
						end,
					},

					{
						type = "button",
						label = "Reset Current Profile",
						buttonText = "Reset",
						width = 120,
						-- TODO: Add tooltip
						enabled = function()
							return ProfileActionsEnabled()
						end,
						onClick = function(ctx)
							ctx.section:ClearMessage()

							dialogs:Confirm(
								"Reset settings for the current profile?",
								"Reset",
								function()
									if type(ctx.store.ResetCurrentLootHelperProfile) ~= "function" then
										ctx.section:SetMessage("ResetCurrentLootHelperProfile() not implemented", "error")
										return
									end

									local ok, err = ctx.store:ResetCurrentLootHelperProfile()
									if not ok then
										ctx.section:SetMessage(err or "Reset failed", "error")
										return
									end

									ctx.section:SetMessage("Profile reset complete.", "success")
									ctx.pageBuilder:Refresh()
								end
							)
						end,
					},
				},
			},
			
			-- ==========================================================
			-- 3) Admin Settings
			-- ==========================================================
			{
				id = "admin",
				title = "Admin Settings",
				condition = CanShowAdminTools,
				items = {
					{
						type = "scrollList",
						label = "Admins",
						height = 160,
						rowHeight = 20,
						removeAtlas = "common-icon-redx",
						enabled = function()
							return ProfileActionsEnabled()
						end,
						getItems = function()
							return BuildAdminItems()
						end,
						onRemove = function(ctx, item)
							if type(ctx.store.RemoveAdminFromActiveProfile) ~= "function" then
								ctx.section:SetMessage("RemoveAdminFromActiveProfile() not implemented", "error")
								return
							end

							local ok, err = ctx.store:RemoveAdminFromActiveProfile(item.id)
							if not ok then
								ctx.section:SetMessage(err or "Failed to remove admin", "error")
								return
							end

							ctx.section:SetMessage("Admin removed.", "success")
							ctx.pageBuilder:Refresh()
						end,
					},

					{
						type = "dropdownIconButton",
						label = "Add Admin",
						defaultText = "Select member",
						options = function()
							return BuildMemberOptions()
						end,

						get = function()
							return panel.__sfAddAdminSelectedId
						end,
						set = function(value)
							panel.__sfAddAdminSelectedId = value
						end,

						enabled = function()
							return ProfileActionsEnabled()
						end,

						iconAtlas = "common-icon-plus",
						iconToolTip = "Add selected member as admin",
						iconEnabled = function()
							return ProfileActionsEnabled() and panel.__sfAddAdminSelectedId ~= nil
						end,

						onIconClick = function(ctx)
							ctx.section:ClearMessage()

							local memberId = panel.__sfAddAdminSelectedId
							if not memberId then
								ctx.section:SetMessage("Select a member first.", "error")
								return
							end

							if type(ctx.store.AddAdminToActiveProfile) ~= "function" then
								ctx.section:SetMessage("AddAdminToActiveProfile() not implemented", "error")
								return
							end

							local ok, err = ctx.store:AddAdminToActiveProfile(memberId)
							if not ok then
								ctx.section:SetMessage(err or "Failed to add admin", "error")
								return
							end

							ctx.section:SetMessage("Admin added.", "success")
							ctx.pageBuilder:Refresh()
						end,
					},

					{
						type = "editbox",
						label = "Point Name",
						tooltip = "Editable per profile. Default is 'Points'.",
						enabled = function()
							return ProfileActionsEnabled()
						end,

						get = function()
							local profile = GetActiveProfileObject(store)
							if profile and type(profile.GetPointName) == "function" then
								return profile:GetPointName()
							end
							return "Points"
						end,
						set = function(value)
							local profile = GetActiveProfileObject(store)
							if profile and type(profile.SetPointName) == "function" then
								profile:SetPointName(value)
							end
						end,

						maxLetters = 24,
					},

					{
						type = "button",
						label = "Rename Profile",
						buttonText = "Rename",
						width = 120,
						enabled = function()
							return ProfileActionsEnabled()
						end,
						onClick = function(ctx)
							local currentName = "(active profile)"
							if store.GetActiveProfileSettings then
								currentName = store:GetActiveProfileSetting("name", currentName)
							end

							ctx.ui.Dialogs:Prompt(
								"Enter a new profile name:",
								"Rename",
								"",
								function(newName)
									ctx.section:ClearMessage()

									if type(ctx.store.RenameActiveLootHelperProfile) ~= "function" then
										ctx.section:SetMessage("RenameActiveLootHelperProfile() not implemented", "error")
										return
									end

									local ok, err = ctx.store:RenameActiveLootHelperProfile(newName)
									if not ok then
										ctx.section:SetMessage(err or "Rename failed", "error")
										return
									end

									ctx.section:SetMessage("Profile renamed.", "success")
									ctx.pageBuilder:Refresh()
								end
							)
						end,
					},

					{
						type = "button",
						label = "Trigger Raid-Wide Sync",
						buttonText = "Sync",
						width = 120,
						enabled = function()
							return ProfileActionsEnabled()
						end,
						onClick = function(ctx)
							ctx.section:SetMessage("Stub: Trigger Raid-Wide Sync (implement later).", "warn")
						end,
					},

					{
						type = "checkbox",
						label = "Enable Raid-Wide Safemode",
						-- Bug: Should not be a persistent setting
						tooltip = "Profile-level persistent setting.",
						enabled = function()
							return ProfileActionsEnabled()
						end,
						get = function()
							if store.GetActiveProfileSetting then
								return store:GetActiveProfileSetting("raidWideSafeMode", false)
							end
							return false
						end,
						set = function(value)
							if store.SetActiveProfileSetting then
								store:SetActiveProfileSetting("raidWideSafeMode", value and true or false)
							end
						end,
					},

					{
						type = "checkbox",
						label = "Enable Raid-Wide Safemode on Combat",
						tooltip = "Profile-level persistent setting.",
						enabled = function()
							return ProfileActionsEnabled()
						end,
						get = function()
							if store.GetActiveProfileSetting then
								return store:GetActiveProfileSetting("raidWideSafeModeOnCombat", false)
							end
							return false
						end,
						set = function(value)
							if store.SetActiveProfileSetting then
								store:SetActiveProfileSetting("raidWideSafeModeOnCombat", value and true or false)
							end
						end,
					},
				},
			},
		},
	}

	renderer:Build(panel, def)
end

-- Refresh the Loot Helper settings page
-- @param panel Frame Settings panel frame
-- @return nil
function Page:Refresh(panel)
	SF.SettingsUI.DefinitionRenderer:Refresh(panel)
end

SF.SettingsUI:RegisterPage(Page)