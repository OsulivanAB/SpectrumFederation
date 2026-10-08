-- Loot Helper → Consumables. Profile configuration is edited through the domain.
local _, SF = ...

local Page = {
	id = "lootHelperConsumables",
	parentId = "lootHelper",
	name = "Raid Consumables",
	navLabel = "Consumables",
	description = "Configure the guild bank and exact items members can donate as raid supplies.",
	order = 23.6,
}

local function ActiveProfile()
	if SF.GetActiveProfile then
		return SF:GetActiveProfile()
	end
	return SF.lootHelperDB and SF.lootHelperDB.activeProfile or nil
end

local function ProfileKey(profile)
	if type(profile) ~= "table" then return nil end
	if profile.GetProfileId then
		local ok, id = pcall(profile.GetProfileId, profile)
		if ok and type(id) == "string" and id ~= "" then return id end
	end
	if type(profile._profileId) == "string" and profile._profileId ~= "" then
		return profile._profileId
	end
	return nil
end

local function ProfileChanged(ctx, originId, action)
	if ProfileKey(ActiveProfile()) == originId then return false end
	if ctx and ctx.section and ctx.section.SetMessage then
		ctx.section:SetMessage("The active profile changed, so " .. action .. " was not applied.", "error")
	end
	return true
end

local function Actor()
	if SF.NameUtil and SF.NameUtil.GetSelfId then
		return SF.NameUtil.GetSelfId()
	end
	return nil
end

local function IsEffectiveAdmin(profile)
	local Imp = SF.LootHelperImpersonation
	if Imp and Imp.IsEffectiveLocalAdmin then
		local ok, res = pcall(Imp.IsEffectiveLocalAdmin, Imp, profile)
		if ok then return res and true or false end
	end
	if profile and profile.IsCurrentUserAdmin then
		local ok, res = pcall(profile.IsCurrentUserAdmin, profile)
		if ok then return res and true or false end
	end
	return false
end

local function Model()
	local C = SF.Consumables
	local profile = ActiveProfile()
	if not C or not profile then
		return nil
	end
	return C.SettingsModel(profile, Actor(), IsEffectiveAdmin(profile))
end

local function Report(ctx, ok, err)
	if ok and err == "pending" then
		ctx.section:SetMessage("Sent to the session coordinator.", "info")
		return
	end
	ctx.section:SetMessage(ok and "Saved." or (err or "Could not save that change."), ok and "success" or "error")
	if ctx.pageBuilder and ctx.pageBuilder.Refresh then
		ctx.pageBuilder:Refresh()
	end
end

local function Commit(ctx, op)
	local C = SF.Consumables
	local profile = ActiveProfile()
	if not C or not profile then
		ctx.section:SetMessage("No active profile.", "error")
		return
	end
	ctx.section:ClearMessage()
	local sync = SF.LootHelperSync
	local ok, err
	if sync and sync.CommitConsumablesOp then
		ok, err = sync:CommitConsumablesOp(profile, op, Actor(), { asAdmin = IsEffectiveAdmin(profile) })
	else
		ok, err = C.ApplyOp(profile, op, Actor(), { asAdmin = IsEffectiveAdmin(profile) })
	end
	Report(ctx, ok, err)
end

local function ItemLabel(itemId)
	local name = nil
	if C_Item and C_Item.GetItemInfo then
		name = C_Item.GetItemInfo(itemId)
		if type(name) ~= "string" then
			name = nil
		end
	end
	if type(name) ~= "string" and GetItemInfo then
		name = GetItemInfo(itemId)
	end
	if type(name) == "string" and name ~= "" then
		return string.format("%s (%d)", name, itemId)
	end
	return "item " .. tostring(itemId)
end

local function RequestedItems()
	local model = Model()
	local items = {}
	if not model then return items end
	for i = 1, #(model.requestedItems or {}) do
		local row = model.requestedItems[i]
		items[i] = {
			text = ItemLabel(row.itemId),
			canRemove = row.canRemove,
			canEditGoal = row.canEditGoal,
			itemId = row.itemId,
			goal = row.goal or 0,
		}
	end
	return items
end

local function AddItem(ctx, itemId)
	local C = SF.Consumables
	itemId = C and C.ItemIdFromText and C.ItemIdFromText(itemId) or tonumber(itemId)
	if not itemId then
		ctx.section:SetMessage("Enter an item ID, paste an item link, or pick up an item.", "error")
		return
	end
	local runtime = SF.ConsumablesRuntime
	local opts = { asAdmin = true }
	if runtime and runtime.Transferable then
		local ok, err = runtime:Transferable(itemId)
		if ok == nil then
			ctx.section:SetMessage(err or "Item data is not ready. Try again.", "warn")
			return
		end
		if not ok then
			ctx.section:SetMessage(err or "That item is not transferable.", "error")
			return
		end
		opts.transferable = true
		opts.requireTransferable = true
	end
	local profile = ActiveProfile()
	local C = SF.Consumables
	if not C or not profile then
		ctx.section:SetMessage("No active profile.", "error")
		return
	end
	ctx.section:ClearMessage()
	local sync = SF.LootHelperSync
	local applyOpts = { asAdmin = IsEffectiveAdmin(profile), transferable = opts.transferable, requireTransferable = opts.requireTransferable }
	local ok, err
	local op = { name = "add_item", itemId = itemId }
	if sync and sync.CommitConsumablesOp then
		ok, err = sync:CommitConsumablesOp(profile, op, Actor(), applyOpts)
	else
		ok, err = C.ApplyOp(profile, op, Actor(), applyOpts)
	end
	Report(ctx, ok, err)
end

local function CursorItemId()
	if not GetCursorInfo then return nil end
	local kind, itemId, link = GetCursorInfo()
	if kind ~= "item" then return nil end
	local C = SF.Consumables
	if C and C.ItemIdFromText then
		return C.ItemIdFromText(link) or C.ItemIdFromText(itemId)
	end
	return tonumber(itemId)
end

local function AcceptCursor(panel, section)
	local ctx = {
		panel = panel,
		section = section,
		pageBuilder = panel and panel.__sfPageBuilder,
	}
	if not ctx.section or not ctx.section.SetMessage then
		return
	end
	local itemId = CursorItemId()
	if not itemId then
		ctx.section:SetMessage("Pick up an item, then drop it here.", "warn")
		return
	end
	AddItem(ctx, itemId)
	if ClearCursor then
		ClearCursor()
	end
end

local function Definition(panel)
	return {
		isAdmin = function()
			local model = Model()
			return model and model.isAdmin or false
		end,
		sections = {
			{
				id = "consumables",
				title = "Raid Consumables",
				tooltip = "Exact item IDs are requested. A different quality is a different item.",
				items = {
					{ type = "help", indent = "label", text = "Members deposit requested materials into the configured Guild Bank tab. Spectrum records only successful deposits." },
					{ type = "display", label = "Guild", get = function() local model = Model() return model and model.guildText or "No active profile." end },
					{
						type = "button",
						label = "Guild Configuration",
						adminOnly = true,
						buttonText = "Set to My Guild",
						width = 160,
						enabled = function()
							local model = Model()
							return model and model.canEditGuild and not model.guildLocked
						end,
						onClick = function(ctx)
							local runtime = SF.ConsumablesRuntime
							if not runtime or not runtime.CurrentGuild then
								ctx.section:SetMessage("Could not read a stable guild id.", "error")
								return
							end
							local guild, tab, err = runtime:CurrentGuild()
							if not guild then
								ctx.section:SetMessage(err or "Could not read a stable guild id.", "error")
								return
							end
							local bankTab = tonumber(panel.__sfConsumableTab) or tab or 1
							panel.__sfConsumableTab = nil
							Commit(ctx, { name = "set_guild", guild = guild, bankTab = bankTab })
						end,
					},
					{
						type = "editbox",
						label = "Bank Tab",
						adminOnly = true,
						maxLetters = 1,
						tooltip = "The one guild bank tab used for this profile. Changing the tab does not change the locked guild.",
						get = function()
							local model = Model()
							if model and model.guildLocked and model.bankTab then
								return tostring(model.bankTab)
							end
							if panel.__sfConsumableTab ~= nil then return tostring(panel.__sfConsumableTab) end
							if model and model.bankTab then return tostring(model.bankTab) end
							return "1"
						end,
						set = function(value)
							panel.__sfConsumableTab = value
						end,
						onCommit = function(ctx, text)
							local tab = tonumber(text)
							if not tab or tab < 1 or tab > 8 or tab ~= math.floor(tab) then
								ctx.section:SetMessage("Enter a bank tab from 1 to 8.", "error")
								return
							end
							local model = Model()
							if model and model.guildLocked then
								panel.__sfConsumableTab = nil
								Commit(ctx, { name = "set_bank_tab", bankTab = tab })
							end
						end,
					},
					{
						type = "button",
						label = "Clear Guild Configuration",
						adminOnly = true,
						buttonText = "Clear",
						width = 120,
						enabled = function() local model = Model() return model and model.canClear end,
						onClick = function(ctx)
							local model = Model()
							local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
							if not (model and dialogs and dialogs.Confirm) then return end
							local originId = ProfileKey(ActiveProfile())
							dialogs:Confirm(model.clearWarning, "Clear", function()
								if ProfileChanged(ctx, originId, "Clear") then return end
								panel.__sfConsumableTab = nil
								Commit(ctx, { name = "clear" })
							end)
						end,
					},
					{
						type = "editboxButton",
						label = "Add Item",
						adminOnly = true,
						hint = "Item ID or link",
						buttonText = "Add",
						buttonWidth = 80,
						onSubmit = function(ctx, text, editBox)
							AddItem(ctx, text)
							if editBox then editBox:SetText("") end
						end,
					},
					{
						type = "button",
						label = "Cursor Item",
						adminOnly = true,
						buttonText = "Add Item on Cursor",
						width = 180,
						onClick = function(ctx)
							local itemId = CursorItemId()
							if not itemId then
								ctx.section:SetMessage("Pick up an item first.", "warn")
								return
							end
							AddItem(ctx, itemId)
							if ClearCursor then ClearCursor() end
						end,
					},
					{
						type = "consumableRequestedList",
						label = "Requested Items",
						adminOnly = false,
						height = 180,
						getItems = RequestedItems,
						onRemove = function(ctx, item)
							local model = Model()
							if not (model and model.canManageItems) then
								ctx.section:SetMessage("Only a profile admin can remove requested items.", "error")
								return
							end
							Commit(ctx, { name = "remove_item", itemId = item.itemId })
						end,
						onGoalCommit = function(ctx, item, text)
							local model = Model()
							if not (model and model.canManageItems) then
								ctx.section:SetMessage("Only a profile admin can change requested-item goals.", "error")
								return
							end
							local goal = tonumber(text)
							if goal == nil then
								ctx.section:SetMessage("Enter a non-negative whole-number goal.", "error")
								if ctx.pageBuilder and ctx.pageBuilder.Refresh then
									ctx.pageBuilder:Refresh()
								end
								return
							end
							Commit(ctx, { name = "set_goal", itemId = item.itemId, goal = goal })
						end,
					},
					{
						type = "button",
						label = "Copy Configuration",
						adminOnly = true,
						buttonText = "Copy to New Profile",
						width = 180,
						tooltip = "Creates a new profile with this guild, tab, and requested items. Contribution history and logs are not copied.",
						onClick = function(ctx)
							local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
							if not (dialogs and dialogs.Prompt and SF.DuplicateLootHelperProfile) then
								ctx.section:SetMessage("Copy is unavailable.", "error")
								return
							end
							local originId = ProfileKey(ActiveProfile())
							dialogs:Prompt("Name for the new profile. Only the current Raid Consumables configuration is copied.", "Copy", "", function(name)
								if ProfileChanged(ctx, originId, "Copy") then return end
								local ok, err = SF:DuplicateLootHelperProfile(name)
								ctx.section:SetMessage(ok and "Profile created from the current Raid Consumables configuration." or (err or "Could not copy the configuration."), ok and "success" or "error")
								if ctx.pageBuilder and ctx.pageBuilder.Refresh then
									ctx.pageBuilder:Refresh()
								end
							end)
						end,
					},
				},
			},
		},
	}
end


function Page:Build(panel)
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if not renderer then return end
	renderer:Build(panel, Definition(panel))
	panel:EnableMouse(true)
	panel:SetScript("OnReceiveDrag", function()
		local section = panel.__sfSections and panel.__sfSections.consumables
		AcceptCursor(panel, section)
	end)
	local section = panel.__sfSections and panel.__sfSections.consumables
	if section and section.EnableMouse then
		section:EnableMouse(true)
		section:SetScript("OnReceiveDrag", function()
			AcceptCursor(panel, section)
		end)
	end
	self.panel = panel
end

function Page:Refresh(panel)
	if panel and panel.IsShown and not panel:IsShown() then
		return
	end
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if renderer then
		renderer:Refresh(panel)
	end
end

local refreshQueued = false

local function QueueRefresh()
	local panel = Page.panel
	if not panel or not Page.Refresh then return end
	if panel.IsShown and not panel:IsShown() then return end
	if refreshQueued then return end
	refreshQueued = true
	local function run()
		refreshQueued = false
		if Page.panel and Page.Refresh then
			Page:Refresh(Page.panel)
		end
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0, run)
	else
		run()
	end
end

if SF.Consumables and SF.Consumables.RegisterUIListener then
	SF.Consumables.RegisterUIListener(QueueRefresh)
end

SF.SettingsUI:RegisterPage(Page)
