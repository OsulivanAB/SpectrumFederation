-- modules/UI/Settings/Pages/LootHelper.lua
local _, SF = ...

local RootPage = {
	id = "lootHelper",
	name = "Loot Helper",
	navLabel = "Loot Helper",
	group = "Loot Tools",
	description = "Configure loot profiles, sessions, raid checks, and admin workflows.",
	defaultChildId = "lootHelperGeneral",
	order = 20,
}

local GeneralPage = {
	id = "lootHelperGeneral",
	parentId = "lootHelper",
	name = "General Settings",
	navLabel = "General",
	description = "Set the default behavior used across Loot Helper features.",
	order = 20.5,
}

local ProfilePage = {
	id = "lootHelperProfile",
	parentId = "lootHelper",
	name = "Profile Settings",
	navLabel = "Profile",
	description = "Create, choose, and manage the active loot profile.",
	order = 21,
}

local SessionPage = {
	id = "lootHelperSession",
	parentId = "lootHelper",
	name = "Session Settings",
	navLabel = "Session",
	description = "Control sync sessions, member handling, and live raid activity.",
	order = 22,
}

local AdminPage = {
	id = "lootHelperAdmin",
	parentId = "lootHelper",
	name = "Admin Settings",
	navLabel = "Admin",
	description = "Manage admin-only tools and profile permissions.",
	order = 23,
}

local function GetActiveProfileObject(store)
	if store and store.GetActiveLootHelperProfileObject then
		return store:GetActiveLootHelperProfileObject()
	end
	if SF and SF.lootHelperDB then
		return SF.lootHelperDB.activeProfile
	end
	return nil
end

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

local function GetProfileOptions(store)
	if store and store.GetLootHelperProfileOptions then
		return store:GetLootHelperProfileOptions()
	end
	if store and store.GetLootHelperProfileOptionsSorted then
		return store:GetLootHelperProfileOptionsSorted()
	end
	return {}
end

local function HasAnyProfiles(store)
	if store and store.HasActiveLootHelperProfile and store:HasActiveLootHelperProfile() then
		return true
	end
	if store and store.HasLootHelperProfiles and store:HasLootHelperProfiles() then
		return true
	end
	if store and store.GetLootHelperProfiles then
		local profiles = store:GetLootHelperProfiles()
		if type(profiles) == "table" and next(profiles) ~= nil then
			return true
		end
	end
	if SF and SF.lootHelperDB and type(SF.lootHelperDB.profiles) == "table" and next(SF.lootHelperDB.profiles) ~= nil then
		return true
	end
	local opts = GetProfileOptions(store)
	return type(opts) == "table" and #opts > 0
end

local function CanShowAdminTools(ctx)
	local store = (type(ctx) == "table" and ctx.store) or SF.SettingsStore
	if not store then return false end
	return GetActiveProfileObject(store) ~= nil or GetActiveProfileId(store) ~= nil
end

local function IsSessionActive()
	return SF.LootHelperSync and SF.LootHelperSync.IsSessionActive and SF.LootHelperSync:IsSessionActive()
end

local function IsAdmin()
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.IsCurrentUserAdmin then
		local ok, res = pcall(profile.IsCurrentUserAdmin, profile)
		if ok then
			return res and true or false
		end
	end
	return false
end

local function IsOwner()
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.IsCurrentUserOwner then
		local ok, res = pcall(profile.IsCurrentUserOwner, profile)
		if ok then
			return res and true or false
		end
	end
	return false
end

local function IsRewardPotMode()
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.IsRewardPotMode then
		local ok, res = pcall(profile.IsRewardPotMode, profile)
		if ok then
			return res and true or false
		end
	end
	return false
end

local function IsPointBasedMode()
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if not profile then
		return false
	end
	if profile.IsPointBasedMode then
		local ok, res = pcall(profile.IsPointBasedMode, profile)
		if ok then
			return res and true or false
		end
	end
	return not IsRewardPotMode()
end

local function GetRewardPotConfig()
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.GetRewardPotConfig then
		return profile:GetRewardPotConfig()
	end
	return nil
end

local function GetRaidCheckConfig()
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.GetRaidCheckConfig then
		return profile:GetRaidCheckConfig()
	end
	return nil
end

local function GetRaidCheckPointsAwardPerCheck()
	local cfg = GetRaidCheckConfig()
	if cfg ~= nil then
		local amount = tonumber(cfg.pointsAwardPerRaidCheck)
		if amount ~= nil then
			return amount
		end
	end
	return 0.5
end

local function SetRaidCheckPointsAwardPerCheck(value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckPointsAwardPerCheck then
		profile:SetRaidCheckPointsAwardPerCheck(tonumber(value) or 0.5)
	end
end

local function SetRaidCheckWhispers(mode, value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckWhispers then
		profile:SetRaidCheckWhispers(mode, value and true or false)
	end
end

local function SetRaidCheckPreparedWhispers(value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckWhisperPrepared then
		profile:SetRaidCheckWhisperPrepared(value and true or false)
	end
end

local function GetRaidCheckWhisperTemplate(templateKey)
	local cfg = GetRaidCheckConfig()
	if not cfg then
		return ""
	end

	if templateKey == "pre_raid_missing" then
		return cfg.whisperTemplatePreRaidMissing or ""
	end
	if templateKey == "raid_missing" then
		return cfg.whisperTemplateRaidMissing or ""
	end
	if templateKey == "raid_prepared" then
		return cfg.whisperTemplateRaidPrepared or ""
	end

	return ""
end

local function SetRaidCheckWhisperTemplate(templateKey, template)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckWhisperTemplate then
		profile:SetRaidCheckWhisperTemplate(templateKey, template)
	end
end

local function ResetRaidCheckWhisperTemplate(templateKey)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.ResetRaidCheckWhisperTemplate then
		profile:ResetRaidCheckWhisperTemplate(templateKey)
	end
end

local function ShouldShowWhisperTemplates()
	local cfg = GetRaidCheckConfig()
	if not cfg then
		return false
	end
	return (cfg.enableWhispersPreRaid and true or false) or (cfg.enableWhispersRaid and true or false)
end

local function ToWoWHexColor(color)
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

local function BuildLootHelperDefinition(panel, sectionIds)
	local dialogs = SF.SettingsUI.Dialogs
	local store = SF.SettingsStore

	panel.__sfAddAdminSelectedId = panel.__sfAddAdminSelectedId or nil
	panel.__sfRewardPotAdjustCopper = panel.__sfRewardPotAdjustCopper or 0

	local function HasActiveProfile()
		return GetActiveProfileObject(store) ~= nil or GetActiveProfileId(store) ~= nil
	end

	local function ProfileActionsEnabled()
		return HasActiveProfile()
	end

	local function BuildOwnerDisplay()
		local profile = GetActiveProfileObject(store)
		if not profile then return "-" end

		local ownerId
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
			local member = profile:getMemberByID(ownerId)
			if type(member) == "table" then
				name = member.member_name or member.name or name
				color = GetMemberClassColor(member)
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

		local items = {}
		for _, memberId in ipairs(profile:getAdminMemberIds() or {}) do
			local member = profile:getMemberByID(memberId)
			local name = (type(member) == "table" and (member.member_name or member.name)) or tostring(memberId)
			local color = GetMemberClassColor(member)
			table.insert(items, {
				id = memberId,
				name = name,
				text = color .. name .. "|r",
				canRemove = (ownerId ~= nil) and (memberId ~= ownerId) or false,
			})
		end

		table.sort(items, function(a, b)
			return tostring(a.name) < tostring(b.name)
		end)
		return items
	end

	local function BuildSelectableMemberOptions(includeAdmins)
		local profile = GetActiveProfileObject(store)
		if not profile or type(profile.getMemberIds) ~= "function" or type(profile.getMemberByID) ~= "function" then
			return {}
		end

		local adminById = {}
		if type(profile.getAdminMemberIds) == "function" then
			for _, memberId in ipairs(profile:getAdminMemberIds() or {}) do
				adminById[memberId] = true
			end
		end

		local out = {}
		for _, memberId in ipairs(profile:getMemberIds() or {}) do
			if includeAdmins or not adminById[memberId] then
				local member = profile:getMemberByID(memberId)
				local name = (type(member) == "table" and (member.member_name or member.name)) or tostring(memberId)
				local color = GetMemberClassColor(member)
				table.insert(out, { value = memberId, label = color .. name .. "|r", _sort = name })
			end
		end

		table.sort(out, function(a, b)
			return tostring(a._sort) < tostring(b._sort)
		end)
		for _, item in ipairs(out) do
			item._sort = nil
		end
		return out
	end

	local function BuildMemberOptions()
		return BuildSelectableMemberOptions(false)
	end

	local function BuildAllMemberOptions()
		return BuildSelectableMemberOptions(true)
	end

	local sectionsById = {
		general = {
			id = "general",
			title = "General Settings",
			tooltip = "Character-level Loot Helper options for this client, plus global actions such as a full reset.",
			items = {
				{ type = "checkbox", label = "Enable LootHelper", tooltip = "Turn Loot Helper on or off for this character. When it is off, the Loot Helper window and related features stay disabled on this client.", path = "lootHelper.enabled" },
				{ type = "checkbox", label = "Lock Loot Window", tooltip = "Prevent the Loot Helper window from being moved or resized.", path = "lootHelper.lockLootWindow" },
				{ type = "checkbox", label = "Show Members not in raid", tooltip = "Show profile members even when they are not currently in your raid. Turn this off to focus only on people who are present.", path = "lootHelper.showMembersNotInRaid" },
				{ type = "checkbox", label = "Show Loot Window outside of Raid", tooltip = "Allow the Loot Helper window to appear even when you are not currently in a raid.", path = "lootHelper.showWindowOutsideRaid" },
				{ type = "checkbox", label = "Enable Local Safemode", tooltip = "Pause bulk sync and profile transfer work on your client. Use this if you want to avoid large data updates locally; it does not affect other players.", path = "lootHelper.localSafeMode" },
				{ type = "checkbox", label = "Enable Local Safemode on Combat", tooltip = "Automatically turn on local safemode when you enter combat so bulk sync and profile transfers pause on your client.", path = "lootHelper.localSafeModeOnCombat" },
				{ type = "spacer", height = 10 },
				{
					type = "button",
					label = "Reset All LootHelper Settings",
					buttonText = "Reset All",
					width = 140,
					tooltip = "Delete every Loot Helper profile and reset every Loot Helper setting saved on this client.",
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
		profile = {
			id = "profile",
			title = "Profile Settings",
			tooltip = "Manage the active Loot Helper profile: choose it, rename it, adjust point settings, and configure raid check requirements.",
			items = {
				{ type = "help", text = "You currently have no profiles. Create one in General Section", indent = "label", visible = function() return not HasAnyProfiles(store) and not HasActiveProfile() end },
				{
					type = "dropdownIconButton",
					label = "Active Profile",
					tooltip = "Choose which Loot Helper profile this character is currently viewing and editing.",
					defaultText = "Select profile",
					get = function() return GetActiveProfileId(store) end,
					set = function(value)
						if store.SetActiveLootHelperProfileId then
							store:SetActiveLootHelperProfileId(value)
						else
							store:Set("lootHelper.activeProfileId", value)
						end
					end,
					options = function() return GetProfileOptions(store) end,
					enabled = function() return HasAnyProfiles(store) end,
					iconAtlas = "common-icon-redx",
					iconTooltip = "Delete the currently active profile",
					iconEnabled = function() return ProfileActionsEnabled() end,
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
				{ type = "editboxButton", label = "Create Profile", hint = "Profile name", buttonText = "Create", buttonWidth = 90, editWidth = 170, tooltip = "Create a new Loot Helper profile and make it the active profile immediately.", onSubmit = function(ctx, text, editBox) ctx.section:ClearMessage() if type(ctx.store.CreateLootHelperProfile) ~= "function" then ctx.section:SetMessage("CreateLootHelperProfile() not implemented", "error") return end local ok, err = ctx.store:CreateLootHelperProfile(text) if not ok then ctx.section:SetMessage(err or "Failed to create profile", "error") return end editBox:SetText("") ctx.section:SetMessage("Profile created.", "success") ctx.pageBuilder:Refresh() end },
				{ type = "display", label = "Profile Owner", get = function() return BuildOwnerDisplay() end, visible = function() return HasActiveProfile() end },
				{
					type = "button",
					label = "Rename Profile",
					adminOnly = true,
					buttonText = "Rename",
					width = 120,
					tooltip = "Change the name of the active Loot Helper profile for everyone who uses it.",
					enabled = function() return ProfileActionsEnabled() end,
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
					type = "dropdown",
					label = "Loot Mode",
					ownerOnly = true,
					tooltip = "Choose how this profile tracks raid participation. Point Based uses loot points. Reward Pot uses Attendance and a shared gold pot. Only the profile owner can change this. Switching modes hides the unused counter without wiping it.",
					visible = function() return HasActiveProfile() end,
					enabled = function() return ProfileActionsEnabled() end,
					get = function()
						local profile = GetActiveProfileObject(store)
						if profile and type(profile.GetLootMode) == "function" then
							return profile:GetLootMode()
						end
						return (SF.LootModes and SF.LootModes.POINT_BASED) or "point_based"
					end,
					set = function(value)
						local profile = GetActiveProfileObject(store)
						if profile and type(profile.SetLootMode) == "function" then
							profile:SetLootMode(value)
						end
					end,
					options = function()
						local pointBased = (SF.LootModes and SF.LootModes.POINT_BASED) or "point_based"
						local rewardPot = (SF.LootModes and SF.LootModes.REWARD_POT) or "reward_pot"
						return {
							{ value = pointBased, label = "Point Based" },
							{ value = rewardPot, label = "Reward Pot" },
						}
					end,
					onValueChanged = function(ctx)
						ctx.section:ClearMessage()
						ctx.pageBuilder:Refresh()
						ctx.pageBuilder:Reflow()
					end,
				},
				{
					type = "editbox",
					label = "Point Name",
					adminOnly = true,
					tooltip = "Rename the point currency used by this profile. This changes labels like 'Points' in the Loot Helper window and related messages.",
					visible = function() return HasActiveProfile() and IsPointBasedMode() end,
					enabled = function() return ProfileActionsEnabled() end,
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
				{ type = "titleDivider", text = "Reward Pot", visible = function() return HasActiveProfile() and IsRewardPotMode() end },
				{
					type = "display",
					label = "Current Pot",
					tooltip = "The current Reward Pot is the starting amount plus every logged add and subtract. It never goes below zero. Edit the pot in Settings; the raid window only displays it.",
					visible = function() return HasActiveProfile() and IsRewardPotMode() end,
					get = function()
						local profile = GetActiveProfileObject(store)
						local copper = 0
						if profile and type(profile.GetCurrentRewardPotCopper) == "function" then
							copper = profile:GetCurrentRewardPotCopper() or 0
						end
						if SF.FormatMoney then
							return SF.FormatMoney(copper)
						end
						return tostring(copper)
					end,
				},
				{
					type = "moneyEdit",
					label = "Starting Pot",
					adminOnly = true,
					tooltip = "Set the starting gold amount used when calculating the current Reward Pot. Changing this updates the current pot immediately.",
					visible = function() return HasActiveProfile() and IsRewardPotMode() end,
					enabled = function() return ProfileActionsEnabled() end,
					get = function()
						local cfg = GetRewardPotConfig()
						return cfg and cfg.startingPotCopper or 0
					end,
					set = function(value)
						local profile = GetActiveProfileObject(store)
						if profile and type(profile.SetRewardPotConfig) == "function" then
							profile:SetRewardPotConfig({ startingPotCopper = value })
						end
					end,
					onCommit = function(ctx)
						if ctx and ctx.pageBuilder then
							ctx.pageBuilder:Refresh()
						end
					end,
				},
				{
					type = "dropdown",
					label = "Raid Check Deduction",
					adminOnly = true,
					tooltip = "Choose how Raid Check reduces the Reward Pot when any evaluated profile member is unprepared. Flat subtracts a gold amount. Percent subtracts that percent of the current pot at click time, then stores the resulting gold amount.",
					visible = function() return HasActiveProfile() and IsRewardPotMode() end,
					enabled = function() return ProfileActionsEnabled() end,
					get = function()
						local cfg = GetRewardPotConfig()
						return (cfg and cfg.deductionType) or ((SF.RewardPotDeductionTypes and SF.RewardPotDeductionTypes.FLAT) or "flat")
					end,
					set = function(value)
						local profile = GetActiveProfileObject(store)
						if not (profile and type(profile.SetRewardPotConfig) == "function") then
							return
						end
						local cfg = GetRewardPotConfig() or {}
						if cfg.deductionType == value then
							return
						end
						profile:SetRewardPotConfig({
							deductionType = value,
							deductionValue = 0,
						})
					end,
					options = function()
						local flat = (SF.RewardPotDeductionTypes and SF.RewardPotDeductionTypes.FLAT) or "flat"
						local percent = (SF.RewardPotDeductionTypes and SF.RewardPotDeductionTypes.PERCENT) or "percent"
						return {
							{ value = flat, label = "Flat Amount" },
							{ value = percent, label = "Percent of Current Pot" },
						}
					end,
					onValueChanged = function(ctx)
						ctx.pageBuilder:Refresh()
						ctx.pageBuilder:Reflow()
					end,
				},
				{
					type = "moneyEdit",
					label = "Deduction Amount",
					adminOnly = true,
					tooltip = "Gold amount subtracted from the Reward Pot when a Raid Check finds any unprepared profile member. The amount is clamped so the pot never goes below zero.",
					visible = function()
						if not (HasActiveProfile() and IsRewardPotMode()) then
							return false
						end
						local cfg = GetRewardPotConfig()
						local percent = (SF.RewardPotDeductionTypes and SF.RewardPotDeductionTypes.PERCENT) or "percent"
						return not (cfg and cfg.deductionType == percent)
					end,
					enabled = function() return ProfileActionsEnabled() end,
					get = function()
						local cfg = GetRewardPotConfig()
						return cfg and cfg.deductionValue or 0
					end,
					set = function(value)
						local profile = GetActiveProfileObject(store)
						if profile and type(profile.SetRewardPotConfig) == "function" then
							profile:SetRewardPotConfig({ deductionValue = value })
						end
					end,
				},
				{
					type = "editbox",
					label = "Deduction Percent",
					adminOnly = true,
					tooltip = "Percent of the current Reward Pot subtracted when a Raid Check finds any unprepared profile member. Partial copper is rounded down. The log stores the gold amount calculated at click time, not a live percent.",
					visible = function()
						if not (HasActiveProfile() and IsRewardPotMode()) then
							return false
						end
						local cfg = GetRewardPotConfig()
						local percent = (SF.RewardPotDeductionTypes and SF.RewardPotDeductionTypes.PERCENT) or "percent"
						return cfg and cfg.deductionType == percent or false
					end,
					enabled = function() return ProfileActionsEnabled() end,
					get = function()
						local cfg = GetRewardPotConfig()
						if not cfg then
							return "0"
						end
						return tostring(cfg.deductionValue or 0)
					end,
					set = function(value)
						local profile = GetActiveProfileObject(store)
						if not (profile and type(profile.SetRewardPotConfig) == "function") then
							return
						end
						local amount = tonumber(value)
						if amount == nil or amount < 0 then
							return
						end
						profile:SetRewardPotConfig({ deductionValue = amount })
					end,
					maxLetters = 8,
				},
				{
					type = "moneyEdit",
					label = "Add or Subtract",
					adminOnly = true,
					tooltip = "Enter an amount, then use Add or Subtract. Subtracting more than the current pot removes only what remains. These adjustments are logged.",
					visible = function() return HasActiveProfile() and IsRewardPotMode() end,
					enabled = function() return ProfileActionsEnabled() end,
					get = function()
						return panel.__sfRewardPotAdjustCopper or 0
					end,
					set = function(value)
						panel.__sfRewardPotAdjustCopper = math.floor(tonumber(value) or 0)
						if panel.__sfRewardPotAdjustCopper < 0 then
							panel.__sfRewardPotAdjustCopper = 0
						end
					end,
				},
				{
					type = "buttonRow",
					adminOnly = true,
					visible = function() return HasActiveProfile() and IsRewardPotMode() end,
					enabled = function() return ProfileActionsEnabled() end,
					{
						text = "Add to Pot",
						width = 140,
						onClick = function(ctx)
							ctx.section:ClearMessage()
							local profile = GetActiveProfileObject(ctx.store)
							if not (profile and type(profile.AdjustRewardPot) == "function") then
								ctx.section:SetMessage("Reward Pot adjustments are unavailable.", "error")
								return
							end
							local amount = math.floor(tonumber(panel.__sfRewardPotAdjustCopper) or 0)
							local ok, err = profile:AdjustRewardPot(
								(SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.INCREMENT) or "INCREMENT",
								amount,
								"MANUAL"
							)
							if not ok then
								ctx.section:SetMessage(err or "Failed to add to the Reward Pot.", "error")
								return
							end
							panel.__sfRewardPotAdjustCopper = 0
							ctx.section:SetMessage("Added to the Reward Pot.", "success")
							ctx.pageBuilder:Refresh()
							ctx.pageBuilder:Reflow()
						end,
					},
					{
						text = "Subtract from Pot",
						width = 180,
						onClick = function(ctx)
							ctx.section:ClearMessage()
							local profile = GetActiveProfileObject(ctx.store)
							if not (profile and type(profile.AdjustRewardPot) == "function") then
								ctx.section:SetMessage("Reward Pot adjustments are unavailable.", "error")
								return
							end
							local amount = math.floor(tonumber(panel.__sfRewardPotAdjustCopper) or 0)
							local ok, err = profile:AdjustRewardPot(
								(SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.DECREMENT) or "DECREMENT",
								amount,
								"MANUAL"
							)
							if not ok then
								ctx.section:SetMessage(err or "Failed to subtract from the Reward Pot.", "error")
								return
							end
							panel.__sfRewardPotAdjustCopper = 0
							ctx.section:SetMessage("Subtracted from the Reward Pot.", "success")
							ctx.pageBuilder:Refresh()
							ctx.pageBuilder:Reflow()
						end,
					},
				},
				{
					type = "button",
					label = "Reset Current Profile",
					buttonText = "Reset",
					width = 120,
					tooltip = "Reset the active profile back to its default settings without deleting the profile itself.",
					enabled = function() return ProfileActionsEnabled() end,
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
				{ type = "spacer", height = 12 },
				{ type = "help", indent = "label", text = "Equipment enchant and gem rules are addon-owned current-Retail policy. Review them on the Raid Equipment page. Raid Check awards and whispers remain on Session." },
			},
		},
		session = {
			id = "session",
			title = "Session Settings",
			tooltip = "Manage the live Loot Helper session for this profile, including session start and stop, raid-wide safemode, and raid check behavior.",
			condition = CanShowAdminTools,
			items = {
				{ type = "button", label = "Session Control", adminOnly = true, buttonText = function() if IsSessionActive() then return "End Session" end return "Start Session" end, width = 120, tooltip = "Start a Loot Helper session for the active profile, or end the current one if a session is already running.", enabled = function() return ProfileActionsEnabled() end, onClick = function(ctx) ctx.section:ClearMessage() if not (SF.LootHelperSync and SF.LootHelperSync.StartSession and SF.LootHelperSync.EndSession) then ctx.section:SetMessage("Loot Helper Sync system not available", "error") return end if IsSessionActive() then local ok = SF.LootHelperSync:EndSession("manual") if ok then ctx.section:SetMessage("Session ended successfully", "success") else ctx.section:SetMessage("Failed to end session", "error") end else local profileId = GetActiveProfileId(ctx.store) if not profileId then ctx.section:SetMessage("No active profile selected", "error") return end local sessionId = SF.LootHelperSync:StartSession(profileId) if sessionId then ctx.section:SetMessage("Session started successfully", "success") else ctx.section:SetMessage("Failed to start session (not in a group/raid?)", "error") end end ctx.pageBuilder:Refresh() end },
				{ type = "text", text = "Enable Raid Wide Safe Mode" },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Only in-combat", tooltip = "Automatically enable raid-wide safemode during combat. While active, everyone in the session pauses bulk sync and profile transfer operations.", get = function() if store.GetActiveProfileSetting then return store:GetActiveProfileSetting("raidWideSafeModeOnCombat", false) end return false end, set = function(value) if store.SetActiveProfileSetting then store:SetActiveProfileSetting("raidWideSafeModeOnCombat", value and true or false) end end }, { label = "All the Time", tooltip = "Keep raid-wide safemode enabled for the full session. While active, everyone in the session pauses bulk sync and profile transfer operations.", get = function() if store.GetActiveProfileSetting then return store:GetActiveProfileSetting("raidWideSafeMode", false) end return false end, set = function(value) if store.SetActiveProfileSetting then store:SetActiveProfileSetting("raidWideSafeMode", value and true or false) end end } } },
				{ type = "button", label = "Trigger Raid-Wide Sync", adminOnly = true, buttonText = "Sync", width = 120, tooltip = "Planned admin action: ask everyone in the active session to resend their Loot Helper data. This button is not implemented yet.", enabled = function() return ProfileActionsEnabled() end, onClick = function(ctx) ctx.section:SetMessage("Stub: Trigger Raid-Wide Sync (implement later).", "warn") end },
				{ type = "spacer", height = 12 },
				{ type = "heading", text = "Raid Check Settings" },
				{ type = "slider", label = "Points Per Raid Check", adminOnly = true, min = 0, max = 1, step = 0.5, tooltip = "Set how many points each prepared player earns when running a Raid Check. Equipment rules are addon-owned and are not configured here.", visible = function() return HasActiveProfile() and IsPointBasedMode() end, enabled = function() return ProfileActionsEnabled() end, get = function() return GetRaidCheckPointsAwardPerCheck() end, set = function(v) SetRaidCheckPointsAwardPerCheck(v) end },
				{ type = "help", indent = "label", text = "If no session is active, Pre-Raid Check and Raid Check ask whether to start one. Yes starts a session then the check. No runs the check without a session. Escape or Cancel aborts." },
				{ type = "text", text = "Raid Checks..." },
					{ type = "buttonRow", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, { text = "Pre-Raid Check", width = 180, onClick = function(ctx) if not (SF.RaidCheck and SF.RaidCheck.RunPreRaidCheck) then ctx.section:SetMessage("Raid Check is not available.", "error") return end local status = SF.RaidCheck:RunPreRaidCheck() if status == "prompt" then ctx.section:SetMessage("Choose Yes to start a session, No to run without one, or Cancel to abort.", "info") elseif status == "started" then ctx.section:SetMessage("Pre-Raid Check started.", "info") elseif status == "busy" then ctx.section:SetMessage("A Raid Check is already in progress.", "warn") end end }, { text = "Raid Check", width = 180, onClick = function(ctx) if not (SF.RaidCheck and SF.RaidCheck.RunRaidCheck) then ctx.section:SetMessage("Raid Check is not available.", "error") return end local status = SF.RaidCheck:RunRaidCheck() if status == "prompt" then ctx.section:SetMessage("Choose Yes to start a session, No to run without one, or Cancel to abort.", "info") elseif status == "started" then ctx.section:SetMessage("Raid Check started.", "info") elseif status == "busy" then ctx.section:SetMessage("A Raid Check is already in progress.", "warn") end end } },
					{ type = "text", text = "Enable Whispers During..." },
					{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Pre-Raid Check", tooltip = "Whisper players after a Pre-Raid Check if they are missing required enchants or gems.", get = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersPreRaid or false end, set = function(value) SetRaidCheckWhispers("pre", value) if panel and panel.__sfPageBuilder then panel.__sfPageBuilder:Refresh() panel.__sfPageBuilder:Reflow() end end }, { label = "Raid Check", tooltip = "Whisper each player their Raid Check result. Players who are missing requirements are told what to fix; fully prepared players are told they earned a point.", get = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersRaid or false end, set = function(value) SetRaidCheckWhispers("raid", value) if panel and panel.__sfPageBuilder then panel.__sfPageBuilder:Refresh() panel.__sfPageBuilder:Reflow() end end } } },
					{ type = "checkbox", label = "Whisper when a point is earned", adminOnly = true, tooltip = "Only applies when Raid Check whispers are enabled. When checked, prepared players are whispered that they earned a point in Point Based mode, or an Attendance point in Reward Pot mode.", visible = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersRaid or false end, enabled = function() return ProfileActionsEnabled() end, get = function() local cfg = GetRaidCheckConfig() if cfg == nil then return true end return cfg.enableWhispersRaidPrepared ~= false end, set = function(value) SetRaidCheckPreparedWhispers(value) if panel and panel.__sfPageBuilder then panel.__sfPageBuilder:Refresh() panel.__sfPageBuilder:Reflow() end end },
					{
						type = "spacer",
						adminOnly = true,
						visible = function() return ShouldShowWhisperTemplates() end,
						height = 12,
					},
					{
						type = "titleDivider",
						text = "Whisper Templates",
						tooltip = "Customize the whisper that is sent by modifying the templates below.",
						adminOnly = true,
						visible = function() return ShouldShowWhisperTemplates() end,
					},
					{ type = "help", adminOnly = true, visible = function() return ShouldShowWhisperTemplates() end, indent = "label", text = "Customize the whisper that is sent by modifying the templates below." },
					{ type = "help", adminOnly = true, visible = function() return ShouldShowWhisperTemplates() end, indent = "label", text = "Use the variables below in the template as placeholders for dynamic data:" },
					{
						type = "keyValueBox",
						adminOnly = true,
						visible = function() return ShouldShowWhisperTemplates() end,
						keyWidth = 140,
						items = {
							{ key = "{player_name}", value = "The name of the player being whispered" },
							{ key = "{missing}", value = "Comma separated list of missing enchants/gems" },
							{ key = "{point_name}", value = "The profile's point name (Raid Check only)" },
							{ key = "{points_awarded}", value = "The number of points awarded (Raid Check only)" },
						},
					},
					{ type = "templateEditor", label = "Pre-Raid Check Whisper", adminOnly = true, buttonText = "Reset to default", enabled = function() return ProfileActionsEnabled() end, visible = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersPreRaid or false end, get = function() return GetRaidCheckWhisperTemplate("pre_raid_missing") end, set = function(value) SetRaidCheckWhisperTemplate("pre_raid_missing", value) end, onReset = function(ctx) ResetRaidCheckWhisperTemplate("pre_raid_missing") ctx.pageBuilder:Refresh() ctx.pageBuilder:Reflow() end },
					{ type = "templateEditor", label = "Raid-Check Whisper (Missing something)", adminOnly = true, buttonText = "Reset to default", enabled = function() return ProfileActionsEnabled() end, visible = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersRaid or false end, get = function() return GetRaidCheckWhisperTemplate("raid_missing") end, set = function(value) SetRaidCheckWhisperTemplate("raid_missing", value) end, onReset = function(ctx) ResetRaidCheckWhisperTemplate("raid_missing") ctx.pageBuilder:Refresh() ctx.pageBuilder:Reflow() end },
					{ type = "templateEditor", label = "Raid-Check Whisper (Nothing missing)", adminOnly = true, buttonText = "Reset to default", enabled = function() return ProfileActionsEnabled() end, visible = function() local cfg = GetRaidCheckConfig() return cfg and (cfg.enableWhispersRaid and cfg.enableWhispersRaidPrepared ~= false) or false end, get = function() return GetRaidCheckWhisperTemplate("raid_prepared") end, set = function(value) SetRaidCheckWhisperTemplate("raid_prepared", value) end, onReset = function(ctx) ResetRaidCheckWhisperTemplate("raid_prepared") ctx.pageBuilder:Refresh() ctx.pageBuilder:Reflow() end },
				},
			},
			admin = {
			id = "admin",
			title = "Admin Settings",
			tooltip = "Manage who can administer the active profile and use admin-only session tools.",
			condition = CanShowAdminTools,
			items = {
				{ type = "scrollList", label = "Admins", adminOnly = true, height = 160, rowHeight = 20, removeAtlas = "common-icon-redx", compactColumns = true, removeColumnGap = 6, enabled = function() return ProfileActionsEnabled() end, getItems = function() return BuildAdminItems() end, onRemove = function(ctx, item) if type(ctx.store.RemoveAdminFromActiveProfile) ~= "function" then ctx.section:SetMessage("RemoveAdminFromActiveProfile() not implemented", "error") return end local ok, err = ctx.store:RemoveAdminFromActiveProfile(item.id) if not ok then ctx.section:SetMessage(err or "Failed to remove admin", "error") return end ctx.section:SetMessage("Admin removed.", "success") ctx.pageBuilder:Refresh() end },
				{ type = "dropdownIconButton", label = "Add Admin", adminOnly = true, defaultText = "Select member", options = function() return BuildMemberOptions() end, get = function() return panel.__sfAddAdminSelectedId end, set = function(value) panel.__sfAddAdminSelectedId = value end, enabled = function() return ProfileActionsEnabled() end, iconAtlas = "common-icon-plus", iconToolTip = "Add the selected member as an admin for the active profile", iconEnabled = function() return ProfileActionsEnabled() and panel.__sfAddAdminSelectedId ~= nil end, onIconClick = function(ctx) if SF.Debug then SF.Debug:Info("UI", "Add Admin button clicked") end ctx.section:ClearMessage() local memberId = panel.__sfAddAdminSelectedId if SF.Debug then SF.Debug:Info("UI", "Selected memberId: %s", tostring(memberId)) end if not memberId then ctx.section:SetMessage("Select a member first.", "error") return end if type(ctx.store.AddAdminToActiveProfile) ~= "function" then ctx.section:SetMessage("AddAdminToActiveProfile() not implemented", "error") return end if SF.Debug then SF.Debug:Info("UI", "Calling AddAdminToActiveProfile with memberId: %s", tostring(memberId)) end local ok, err = ctx.store:AddAdminToActiveProfile(memberId) if SF.Debug then SF.Debug:Info("UI", "AddAdminToActiveProfile returned: ok=%s, err=%s", tostring(ok), tostring(err)) end if not ok then ctx.section:SetMessage(err or "Failed to add admin", "error") return end ctx.section:SetMessage("Admin added.", "success") ctx.pageBuilder:Refresh() end },
				{ type = "button", label = "Transfer Points / Main Swap", adminOnly = true, buttonText = "Main Swap", width = 140, tooltip = "Transfer loot points, Attendance, and member-history references from one existing profile member to another existing profile member, then remove the old character from the profile.", enabled = function() return ProfileActionsEnabled() end, onClick = function(ctx) ctx.section:ClearMessage() if type(ctx.store.TransferMemberHistoryInActiveProfile) ~= "function" then ctx.section:SetMessage("TransferMemberHistoryInActiveProfile() not implemented", "error") return end local memberOptions = BuildAllMemberOptions() if #memberOptions < 2 then ctx.section:SetMessage("Add at least two profile members before using Main Swap.", "error") return end dialogs:TransferMemberHistory("Transfer all point and Attendance history from one profile member to another, then remove the old character from this profile?", "Transfer", memberOptions, memberOptions, function(sourceMemberId, targetMemberId) local ok, err = ctx.store:TransferMemberHistoryInActiveProfile(sourceMemberId, targetMemberId) if not ok then ctx.section:SetMessage(err or "Main Swap failed", "error") return end ctx.section:SetMessage("Main Swap completed.", "success") ctx.pageBuilder:Refresh() end) end },
			},
		},
	}

	local sections = {}
	for _, sectionId in ipairs(sectionIds or {}) do
		local sectionDef = sectionsById[sectionId]
		if sectionDef then
			table.insert(sections, sectionDef)
		end
	end

	return {
		isAdmin = function()
			return IsAdmin()
		end,
		isOwner = function()
			return IsOwner()
		end,
		sections = sections,
	}
end

local function BuildPage(panel, pageName, sectionIds)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Building LootHelper settings page: %s", tostring(pageName))
	end

	SF.SettingsUI.DefinitionRenderer:Build(panel, BuildLootHelperDefinition(panel, sectionIds))
end

local function RefreshPage(panel)
	SF.SettingsUI.DefinitionRenderer:Refresh(panel)
end

function RootPage:Build(panel)
	BuildPage(panel, self.id, { "general" })
end

function RootPage:Refresh(panel)
	RefreshPage(panel)
end

function GeneralPage:Build(panel)
	BuildPage(panel, self.id, { "general" })
end

function GeneralPage:Refresh(panel)
	RefreshPage(panel)
end

function ProfilePage:Build(panel)
	BuildPage(panel, self.id, { "profile" })
end

function ProfilePage:Refresh(panel)
	RefreshPage(panel)
end

function SessionPage:Build(panel)
	BuildPage(panel, self.id, { "session" })
end

function SessionPage:Refresh(panel)
	RefreshPage(panel)
end

function AdminPage:Build(panel)
	BuildPage(panel, self.id, { "admin" })
end

function AdminPage:Refresh(panel)
	RefreshPage(panel)
end

SF.SettingsUI:RegisterPage(RootPage)
SF.SettingsUI:RegisterPage(GeneralPage)
SF.SettingsUI:RegisterPage(ProfilePage)
SF.SettingsUI:RegisterPage(SessionPage)
SF.SettingsUI:RegisterPage(AdminPage)
