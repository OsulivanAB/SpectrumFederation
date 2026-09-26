-- Loot Helper → Consumables. Profile configuration is edited through the domain.
local _, SF = ...

local Page = {
	id = "lootHelperConsumables",
	parentId = "lootHelper",
	name = "Raid Consumables",
	navLabel = "Consumables",
	description = "Choose the guild bank, Crafters, and exact items requested for raid supplies.",
	order = 23.6,
}

local function ActiveProfile()
	if SF.GetActiveProfile then
		return SF:GetActiveProfile()
	end
	return SF.lootHelperDB and SF.lootHelperDB.activeProfile or nil
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

local function AssignmentItems()
	local model = Model()
	local items = {}
	if not model then return items end
	for i = 1, #model.assignments do
		local row = model.assignments[i]
		items[i] = {
			text = string.format("%s → %s", ItemLabel(row.itemId), tostring(row.crafter)),
			canRemove = row.canRemove,
			itemId = row.itemId,
			crafter = row.crafter,
		}
	end
	return items
end

local function CrafterItems()
	local model = Model()
	return (model and model.crafters) or {}
end

local function CustodyItems()
	local model = Model()
	local items = {}
	if not model then return items end
	for i = 1, #model.custody do
		local row = model.custody[i]
		items[i] = {
			text = string.format("%s · %s · %d%s", row.holder, ItemLabel(row.itemId), row.quantity, row.retired and " · retired" or ""),
			canRemove = false,
			holder = row.holder,
			itemId = row.itemId,
		}
	end
	return items
end

local function SelectedCrafter(panel)
	local model = Model()
	if model and model.selfCrafter and not model.isAdmin then
		return model.selfCrafter
	end
	local name = panel and panel.__sfConsumableCrafter
	if type(name) == "string" then
		name = name:match("^%s*(.-)%s*$")
	end
	if name == "" then return nil end
	return name
end

local function AddItem(ctx, itemId)
	local C = SF.Consumables
	itemId = C and C.ItemIdFromText and C.ItemIdFromText(itemId) or tonumber(itemId)
	if not itemId then
		ctx.section:SetMessage("Enter an item ID, paste an item link, or pick up an item.", "error")
		return
	end
	local runtime = SF.ConsumablesRuntime
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
	end
	local crafter = SelectedCrafter(ctx.panel)
	if not crafter then
		ctx.section:SetMessage("Choose the Crafter this item is for.", "error")
		return
	end
	Commit(ctx, { name = "add_assignment", itemId = itemId, crafter = crafter })
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
					{ type = "help", indent = "label", text = "Assignments request one exact item. Re-adding an item starts a new routing epoch. Historical receipts stay in Raid Consumable Logs." },
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
							if not tab then
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
							dialogs:Confirm(model.clearWarning, "Clear", function()
								panel.__sfConsumableTab = nil
								Commit(ctx, { name = "clear" })
							end)
						end,
					},
					{
						type = "editboxButton",
						label = "Add Crafter",
						adminOnly = true,
						hint = "Name-Realm",
						buttonText = "Add",
						buttonWidth = 80,
						onSubmit = function(ctx, text, editBox)
							Commit(ctx, { name = "add_crafter", crafter = text })
							if editBox then editBox:SetText("") end
						end,
					},
					{
						type = "scrollList",
						label = "Crafters",
						adminOnly = true,
						height = 120,
						getItems = CrafterItems,
						onRemove = function(ctx, item)
							Commit(ctx, { name = "remove_crafter", crafter = item.crafter or item.text })
						end,
					},
					{
						type = "editbox",
						label = "Crafter",
						adminOnly = true,
						hint = "Name-Realm",
						get = function() return panel.__sfConsumableCrafter or "" end,
						set = function(value) panel.__sfConsumableCrafter = value end,
					},
					{
						type = "editboxButton",
						label = "Add Item",
						hint = "Item ID or link",
						buttonText = "Add",
						buttonWidth = 80,
						visible = function()
							local model = Model()
							return model and (model.isAdmin or model.isCrafter)
						end,
						onSubmit = function(ctx, text, editBox)
							AddItem(ctx, text)
							if editBox then editBox:SetText("") end
						end,
					},
					{
						type = "button",
						label = "Cursor Item",
						buttonText = "Add Item on Cursor",
						width = 180,
						visible = function()
							local model = Model()
							return model and (model.isAdmin or model.isCrafter)
						end,
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
						type = "scrollList",
						label = "Assignments",
						height = 180,
						visible = function()
							local model = Model()
							return model and (model.isAdmin or model.isCrafter)
						end,
						getItems = AssignmentItems,
						onRemove = function(ctx, item)
							Commit(ctx, { name = "remove_assignment", itemId = item.itemId, crafter = item.crafter })
						end,
					},
					{
						type = "help",
						adminOnly = true,
						indent = "label",
						text = "Resolve removes one whole custody entry. It does not create a contribution or a Crafter receipt.",
					},
					{
						type = "scrollList",
						label = "Custody",
						adminOnly = true,
						height = 140,
						getItems = CustodyItems,
					},
					{
						type = "dropdown",
						label = "Custody Entry",
						adminOnly = true,
						defaultText = "Select custody",
						options = function()
							local options = {}
							for _, item in ipairs(CustodyItems()) do
								options[#options + 1] = {
									value = tostring(item.holder) .. "|" .. tostring(item.itemId),
									label = item.text,
								}
							end
							return options
						end,
						get = function() return panel.__sfCustodyEntry end,
						set = function(value) panel.__sfCustodyEntry = value end,
					},
					{
						type = "dropdown",
						label = "Resolve Reason",
						adminOnly = true,
						defaultText = "Other",
						options = function()
							local options = {}
							local reasons = (SF.Consumables and SF.Consumables.RESOLVE_REASONS) or {}
							for i = 1, #reasons do
								options[i] = { value = reasons[i], label = reasons[i] }
							end
							return options
						end,
						get = function() return panel.__sfCustodyReason or "Other" end,
						set = function(value) panel.__sfCustodyReason = value end,
					},
					{
						type = "button",
						label = "Resolve Custody",
						adminOnly = true,
						buttonText = "Resolve",
						width = 120,
						onClick = function(ctx)
							local value = panel.__sfCustodyEntry
							local holder, itemId = nil, nil
							if type(value) == "string" then
								holder, itemId = value:match("^(.-)|(%d+)$")
							end
							if not holder or not itemId then
								ctx.section:SetMessage("Select a custody entry.", "error")
								return
							end
							local profile = ActiveProfile()
							local sync = SF.LootHelperSync
							local ok, err
							local reason = panel.__sfCustodyReason or "Other"
							if sync and sync.PublishConsumablesResolve then
								ok, err = sync:PublishConsumablesResolve(profile, Actor(), holder, tonumber(itemId), reason, { asAdmin = IsEffectiveAdmin(profile) })
							elseif SF.Consumables then
								ok, err = SF.Consumables.ResolveCustody(profile, Actor(), holder, tonumber(itemId), reason, { asAdmin = IsEffectiveAdmin(profile) })
							end
							Report(ctx, ok, err)
						end,
					},
					{
						type = "button",
						label = "Copy Configuration",
						adminOnly = true,
						buttonText = "Copy to New Profile",
						width = 180,
						tooltip = "Creates a new profile with this guild, tab, Crafters, and current assignments. Receipts, custody, and logs are not copied.",
						onClick = function(ctx)
							local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
							if not (dialogs and dialogs.Prompt and SF.DuplicateLootHelperProfile) then
								ctx.section:SetMessage("Copy is unavailable.", "error")
								return
							end
							dialogs:Prompt("Name for the new profile. Only the current Raid Consumables configuration is copied.", "Copy", "", function(name)
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

if SF.Consumables and SF.Consumables.RegisterUIListener then
	SF.Consumables.RegisterUIListener(function()
		if Page.panel and Page.Refresh then
			Page:Refresh(Page.panel)
		end
	end)
end

SF.SettingsUI:RegisterPage(Page)
