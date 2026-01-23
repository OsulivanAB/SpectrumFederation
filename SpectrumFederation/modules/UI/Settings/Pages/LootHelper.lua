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
	return nil
end

local function GetActiveProfileId(store)
	local id = store:Get("lootHelper.activeProfileId")
	if id ~= nil then return id end

	return store:Get("lootHelper.activeProfile")
end

local function HasAnyProfiles(store)
	-- TODO: Call profiles API
	return false, "Not implemented"
end

local function GetProfileOptions(store)
	if store.GetLootHelperProfileOptionsSorted then
		return store:GetLootHelperProfileOptionsSorted()
	end
	return {}, "Not implemented"
end

local function CanShowAdminTools(ctx)
	-- TODO: Call profiles API function to ask if current user is admin
	return true
end

-- ==================================================================
-- Page Definition
-- ==================================================================
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
		return GetActiveProfileId(store) ~= nil
	end

	local function ProfileActionsEnabled()
		return HasActiveProfile()
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

		if type(profile.getMemberByID) == "function" then
			local m = profile:GetMemberByID(ownerId)
			if type(m) == "table" then
				return m.member_name or m.name or tostring(ownerId)
			end
		end

		return tostring(ownerId)
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
			
			local className
			if type(m) == "table" then
				className = m:getClass()
			else
				className = m.class
			end

			local color = "|cffffffff"
			if className and SF.WOW_CLASSES and SF.WOW_CLASSES[className] and SF.WOW_CLASSES[className].colorCode then
				color = SF.WOW_CLASSES[className].colorCode
			end

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
			table.insert(out, { value = memberId, label = name })
		end

		table.sort(out, function(a, b) return tostring(a.label) < tostring(b.label) end)
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
							return not HasAnyProfiles(store)
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
							store:Set("lootHelper.activeProfileId", value)
						end,

						options = function()
							return GetProfileOptions(store)
						end,

						enabled = function()
							return HasAnyProfiles(store)
						end,

						iconAtlas = "common-icon-trash",
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
							if store.GetActiveProfileSettings then
								return store:GetActiveProfileSetting("pointName", "Points")
							end
							return "Points"
						end,
						set = function(value)
							if store.SetActiveProfileSetting then
								store:SetActiveProfileSetting("pointName", value)
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

function Page:Refresh(panel)
	SF.SettingsUI.DefinitionRenderer:Refresh(panel)
end

SF.SettingsUI:RegisterPage(Page)