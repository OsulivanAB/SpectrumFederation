-- modules/UI/Settings/Pages/LootHelper.lua
local _, SF = ...

local RootPage = {
	id = "lootHelper",
	name = "Loot Helper Settings",
	navLabel = "Loot Helper",
	defaultChildId = "lootHelperGeneral",
	order = 20,
}

local GeneralPage = {
	id = "lootHelperGeneral",
	parentId = "lootHelper",
	name = "General Settings",
	navLabel = "General",
	order = 20.5,
}

local ProfilePage = {
	id = "lootHelperProfile",
	parentId = "lootHelper",
	name = "Profile Settings",
	navLabel = "Profile",
	order = 21,
}

local SessionPage = {
	id = "lootHelperSession",
	parentId = "lootHelper",
	name = "Session Settings",
	navLabel = "Session",
	order = 22,
}

local AdminPage = {
	id = "lootHelperAdmin",
	parentId = "lootHelper",
	name = "Admin Settings",
	navLabel = "Admin",
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

local function GetRaidCheckConfig()
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.GetRaidCheckConfig then
		return profile:GetRaidCheckConfig()
	end
	return nil
end

local function IsRaidCheckSlotEnabled(slotKey)
	local cfg = GetRaidCheckConfig()
	if cfg and cfg.slots then
		return cfg.slots[slotKey] and true or false
	end
	return false
end

local function IsRaidCheckGemSocketsEnabled()
	local cfg = GetRaidCheckConfig()
	if cfg ~= nil then
		return cfg.checkGemsInSockets ~= false
	end
	return true
end

local function IsRaidCheckMetaGemRequired()
	local cfg = GetRaidCheckConfig()
	if cfg ~= nil then
		return cfg.requireMetaGem and true or false
	end
	return false
end

local function SetRaidCheckSlot(slotKey, value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckSlotEnabled then
		profile:SetRaidCheckSlotEnabled(slotKey, value and true or false)
	end
end

local function SetRaidCheckGemSockets(value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckGemSocketsEnabled then
		profile:SetRaidCheckGemSocketsEnabled(value and true or false)
	end
end

local function SetRaidCheckMetaGemRequired(value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckMetaGemRequired then
		profile:SetRaidCheckMetaGemRequired(value and true or false)
	end
end

local function SetRaidCheckWhispers(mode, value)
	local profile = GetActiveProfileObject(SF.SettingsStore)
	if profile and profile.SetRaidCheckWhispers then
		profile:SetRaidCheckWhispers(mode, value and true or false)
	end
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

	local function BuildMemberOptions()
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
			if not adminById[memberId] then
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

	local sectionsById = {
		general = {
			id = "general",
			title = "General Settings",
			tooltip = "Character-level Loot Helper settings and global actions such as creating or resetting profiles.",
			items = {
				{ type = "checkbox", label = "Enable LootHelper", tooltip = "Enable or disable LootHelper on this character/client.", path = "lootHelper.enabled" },
				{ type = "checkbox", label = "Lock Loot Window", tooltip = "When enabled, the Loot Helper window cannot be moved or resized.", path = "lootHelper.lockLootWindow" },
				{ type = "checkbox", label = "Show Members not in raid", tooltip = "When disabled, profile members who are not currently in your raid will be hidden in the Loot Helper window.", path = "lootHelper.showMembersNotInRaid" },
				{ type = "checkbox", label = "Show Loot Window outside of Raid", tooltip = "When enabled, the Loot Helper window may appear even if you are not in a raid.", path = "lootHelper.showWindowOutsideRaid" },
				{ type = "checkbox", label = "Enable Local Safemode", tooltip = "Local-only safemode. Independent from raid-wide safemode.", path = "lootHelper.localSafeMode" },
				{ type = "checkbox", label = "Enable Local Safemode on Combat", tooltip = "Local-only: enable safemode automatically when entering combat.", path = "lootHelper.localSafeModeOnCombat" },
				{ type = "spacer", height = 10 },
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
		profile = {
			id = "profile",
			title = "Profile Settings",
			tooltip = "Settings and actions for the currently active Loot Helper profile, including membership, scoring rules, and raid check enchant requirements.",
			items = {
				{ type = "help", text = "You currently have no profiles. Create one in General Section", indent = "label", visible = function() return not HasAnyProfiles(store) and not HasActiveProfile() end },
				{
					type = "dropdownIconButton",
					label = "Active Profile",
					tooltip = "Select the active profile (stored by ID)",
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
					iconTooltip = "Delete Active Profile",
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
				{ type = "editboxButton", label = "Create Profile", hint = "Profile name", buttonText = "Create", buttonWidth = 90, editWidth = 170, tooltip = "Creates a new profile. Will automatically set it to active.", onSubmit = function(ctx, text, editBox) ctx.section:ClearMessage() if type(ctx.store.CreateLootHelperProfile) ~= "function" then ctx.section:SetMessage("CreateLootHelperProfile() not implemented", "error") return end local ok, err = ctx.store:CreateLootHelperProfile(text) if not ok then ctx.section:SetMessage(err or "Failed to create profile", "error") return end editBox:SetText("") ctx.section:SetMessage("Profile created.", "success") ctx.pageBuilder:Refresh() end },
				{ type = "display", label = "Profile Owner", get = function() return BuildOwnerDisplay() end, visible = function() return HasActiveProfile() end },
				{
					type = "button",
					label = "Rename Profile",
					adminOnly = true,
					buttonText = "Rename",
					width = 120,
					tooltip = "Rename the active Loot Helper profile for everyone using it.",
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
					type = "editbox",
					label = "Point Name",
					adminOnly = true,
					tooltip = "Editable per profile. Default is 'Points'.",
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
				{ type = "button", label = "Manually Sync My Data", buttonText = "Sync", width = 120, tooltip = "Send your current Loot Helper data to the active session. Requires an active Loot Helper session.", enabled = function() return ProfileActionsEnabled() and IsSessionActive() end, onClick = function(ctx) ctx.section:SetMessage("Stub: Manually Sync My Data (implement later).", "warn") end },
				{
					type = "button",
					label = "Reset Current Profile",
					buttonText = "Reset",
					width = 120,
					tooltip = "Reset the active Loot Helper profile back to its default settings.",
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
				{ type = "heading", text = "Raid Check Profile Settings" },
				{ type = "text", text = "Requirements to look for" },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Gem in Sockets", tooltip = "When enabled, raid checks require equipped items with gem sockets to have gems inserted.", get = function() return IsRaidCheckGemSocketsEnabled() end, set = function(v) SetRaidCheckGemSockets(v) end }, { label = "At Least One Meta Gem", tooltip = "When enabled, raid checks require at least one purple-quality meta gem to be socketed in any equipped item.", get = function() return IsRaidCheckMetaGemRequired() end, set = function(v) SetRaidCheckMetaGemRequired(v) end } } },
				{ type = "text", text = "Enchants to look for" },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Head", get = function() return IsRaidCheckSlotEnabled("head") end, set = function(v) SetRaidCheckSlot("head", v) end }, { label = "Gloves", get = function() return IsRaidCheckSlotEnabled("hands") end, set = function(v) SetRaidCheckSlot("hands", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Neck", get = function() return IsRaidCheckSlotEnabled("neck") end, set = function(v) SetRaidCheckSlot("neck", v) end }, { label = "Belt", get = function() return IsRaidCheckSlotEnabled("belt") end, set = function(v) SetRaidCheckSlot("belt", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Shoulders", get = function() return IsRaidCheckSlotEnabled("shoulders") end, set = function(v) SetRaidCheckSlot("shoulders", v) end }, { label = "Legs", get = function() return IsRaidCheckSlotEnabled("legs") end, set = function(v) SetRaidCheckSlot("legs", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Back", get = function() return IsRaidCheckSlotEnabled("back") end, set = function(v) SetRaidCheckSlot("back", v) end }, { label = "Boots", get = function() return IsRaidCheckSlotEnabled("boots") end, set = function(v) SetRaidCheckSlot("boots", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Chest", get = function() return IsRaidCheckSlotEnabled("chest") end, set = function(v) SetRaidCheckSlot("chest", v) end }, { label = "Rings", get = function() return IsRaidCheckSlotEnabled("rings") end, set = function(v) SetRaidCheckSlot("rings", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Wrist", get = function() return IsRaidCheckSlotEnabled("wrist") end, set = function(v) SetRaidCheckSlot("wrist", v) end }, { label = "Trinkets", get = function() return IsRaidCheckSlotEnabled("trinkets") end, set = function(v) SetRaidCheckSlot("trinkets", v) end } } },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Weapon", get = function() return IsRaidCheckSlotEnabled("weapon") end, set = function(v) SetRaidCheckSlot("weapon", v) end }, { label = "Off Hand", get = function() return IsRaidCheckSlotEnabled("offHand") end, set = function(v) SetRaidCheckSlot("offHand", v) end } } },
			},
		},
		session = {
			id = "session",
			title = "Session Settings",
			tooltip = "Session-level controls for raid-wide sync, safemode, and raid check execution for the active profile.",
			condition = CanShowAdminTools,
			items = {
				{ type = "button", label = "Session Control", adminOnly = true, buttonText = function() if IsSessionActive() then return "End Session" end return "Start Session" end, width = 120, tooltip = "Start or end a Loot Helper sync session", enabled = function() return ProfileActionsEnabled() end, onClick = function(ctx) ctx.section:ClearMessage() if not (SF.LootHelperSync and SF.LootHelperSync.StartSession and SF.LootHelperSync.EndSession) then ctx.section:SetMessage("Loot Helper Sync system not available", "error") return end if IsSessionActive() then local ok = SF.LootHelperSync:EndSession("manual") if ok then ctx.section:SetMessage("Session ended successfully", "success") else ctx.section:SetMessage("Failed to end session", "error") end else local profileId = GetActiveProfileId(ctx.store) if not profileId then ctx.section:SetMessage("No active profile selected", "error") return end local sessionId = SF.LootHelperSync:StartSession(profileId) if sessionId then ctx.section:SetMessage("Session started successfully", "success") else ctx.section:SetMessage("Failed to start session (not in a group/raid?)", "error") end end ctx.pageBuilder:Refresh() end },
				{ type = "text", text = "Enable Raid Wide Safe Mode" },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Only in-combat", tooltip = "Enable raid-wide safemode only during combat.", get = function() if store.GetActiveProfileSetting then return store:GetActiveProfileSetting("raidWideSafeModeOnCombat", false) end return false end, set = function(value) if store.SetActiveProfileSetting then store:SetActiveProfileSetting("raidWideSafeModeOnCombat", value and true or false) end end }, { label = "All the Time", tooltip = "Keep raid-wide safemode active at all times.", get = function() if store.GetActiveProfileSetting then return store:GetActiveProfileSetting("raidWideSafeMode", false) end return false end, set = function(value) if store.SetActiveProfileSetting then store:SetActiveProfileSetting("raidWideSafeMode", value and true or false) end end } } },
				{ type = "spacer", height = 12 },
				{ type = "heading", text = "Raid Check Settings" },
				{ type = "text", text = "Raid Checks..." },
				{ type = "buttonRow", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, { text = "Pre-Raid Check", width = 180, onClick = function(ctx) if SF.RaidCheck and SF.RaidCheck.RunPreRaidCheck then SF.RaidCheck:RunPreRaidCheck() ctx.section:SetMessage("Pre-Raid Check started.", "info") else ctx.section:SetMessage("Raid Check is not available.", "error") end end }, { text = "Raid Check", width = 180, onClick = function(ctx) if SF.RaidCheck and SF.RaidCheck.RunRaidCheck then SF.RaidCheck:RunRaidCheck() ctx.section:SetMessage("Raid Check started.", "info") else ctx.section:SetMessage("Raid Check is not available.", "error") end end } },
				{ type = "text", text = "Enable Whispers During..." },
				{ type = "checkboxGrid", adminOnly = true, enabled = function() return ProfileActionsEnabled() end, items = { { label = "Pre-Raid Check", tooltip = "When enabled, whisper players who are missing required enchants or gems during a Pre-Raid Check.", get = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersPreRaid or false end, set = function(value) SetRaidCheckWhispers("pre", value) end }, { label = "Raid Check", tooltip = "When enabled, whisper players their Raid Check result. Missing players should be told what they are missing. Fully prepared players should be told they received a point.", get = function() local cfg = GetRaidCheckConfig() return cfg and cfg.enableWhispersRaid or false end, set = function(value) SetRaidCheckWhispers("raid", value) end } } },
			},
		},
		admin = {
			id = "admin",
			title = "Admin Settings",
			tooltip = "Administrative tools for managing profile ownership, profile creation, and admin membership.",
			condition = CanShowAdminTools,
			items = {
				{ type = "scrollList", label = "Admins", adminOnly = true, height = 160, rowHeight = 20, removeAtlas = "common-icon-redx", compactColumns = true, removeColumnGap = 6, enabled = function() return ProfileActionsEnabled() end, getItems = function() return BuildAdminItems() end, onRemove = function(ctx, item) if type(ctx.store.RemoveAdminFromActiveProfile) ~= "function" then ctx.section:SetMessage("RemoveAdminFromActiveProfile() not implemented", "error") return end local ok, err = ctx.store:RemoveAdminFromActiveProfile(item.id) if not ok then ctx.section:SetMessage(err or "Failed to remove admin", "error") return end ctx.section:SetMessage("Admin removed.", "success") ctx.pageBuilder:Refresh() end },
				{ type = "dropdownIconButton", label = "Add Admin", adminOnly = true, defaultText = "Select member", options = function() return BuildMemberOptions() end, get = function() return panel.__sfAddAdminSelectedId end, set = function(value) panel.__sfAddAdminSelectedId = value end, enabled = function() return ProfileActionsEnabled() end, iconAtlas = "common-icon-plus", iconToolTip = "Add selected member as admin", iconEnabled = function() return ProfileActionsEnabled() and panel.__sfAddAdminSelectedId ~= nil end, onIconClick = function(ctx) if SF.Debug then SF.Debug:Info("UI", "Add Admin button clicked") end ctx.section:ClearMessage() local memberId = panel.__sfAddAdminSelectedId if SF.Debug then SF.Debug:Info("UI", "Selected memberId: %s", tostring(memberId)) end if not memberId then ctx.section:SetMessage("Select a member first.", "error") return end if type(ctx.store.AddAdminToActiveProfile) ~= "function" then ctx.section:SetMessage("AddAdminToActiveProfile() not implemented", "error") return end if SF.Debug then SF.Debug:Info("UI", "Calling AddAdminToActiveProfile with memberId: %s", tostring(memberId)) end local ok, err = ctx.store:AddAdminToActiveProfile(memberId) if SF.Debug then SF.Debug:Info("UI", "AddAdminToActiveProfile returned: ok=%s, err=%s", tostring(ok), tostring(err)) end if not ok then ctx.section:SetMessage(err or "Failed to add admin", "error") return end ctx.section:SetMessage("Admin added.", "success") ctx.pageBuilder:Refresh() end },
				{ type = "button", label = "Trigger Raid-Wide Sync", adminOnly = true, buttonText = "Sync", width = 120, enabled = function() return ProfileActionsEnabled() end, onClick = function(ctx) ctx.section:SetMessage("Stub: Trigger Raid-Wide Sync (implement later).", "warn") end },
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
