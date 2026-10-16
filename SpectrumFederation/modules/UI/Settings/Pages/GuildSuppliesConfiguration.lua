-- Guild Supplies → Configuration (#386). Staged guild setup and campaign editors.
-- Live bank helper / donation writer remains legacy Consumables until #389.
local _, SF = ...

SF.SettingsUI:RegisterCategory({
	id = "guildSupplies",
	name = "Guild Supplies",
	navLabel = "Guild Supplies",
	group = "Loot Tools",
	description = "Guild-owned raid supply campaigns, configuration, and logs.",
	order = 19,
})

local Page = {
	id = "guildSuppliesConfiguration",
	categoryId = "guildSupplies",
	name = "Configuration",
	navLabel = "Configuration",
	contentHeading = "Guild Supplies Configuration",
	group = "Loot Tools",
	description = "Fresh guild setup, bank tab, editor ranks, requested items, and New Campaign.",
	order = 19.1,
}

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

local function GS()
	return SF.GuildSupplies
end

local function Caps()
	local g = GS()
	if not g or not g.GetCapabilities then
		return { canEdit = false, canRead = false, canRecoverPolicy = false, reason = "not_ready" }
	end
	return g:GetCapabilities()
end

local function ReportStatus(ctx, status, reason)
	local g = GS()
	local message, severity
	if g and g.FormatMutationFeedback then
		message, severity = g.FormatMutationFeedback(status, reason)
	else
		message = tostring(status or "rejected")
		severity = (status == "accepted" and "success")
			or (status == "duplicate" and "info")
			or (status == "pending" and "warn")
			or "error"
	end
	ctx.section:SetMessage(message, severity)
	if ctx.pageBuilder and ctx.pageBuilder.Refresh then
		ctx.pageBuilder:Refresh()
	end
end

local function ItemLabel(itemId)
	local name = nil
	if C_Item and C_Item.GetItemInfo then
		name = C_Item.GetItemInfo(itemId)
	end
	if type(name) ~= "string" and GetItemInfo then
		name = GetItemInfo(itemId)
	end
	if type(name) == "string" and name ~= "" then
		return string.format("%s (%d)", name, itemId)
	end
	return "item " .. tostring(itemId)
end

local function RequestedItemRows()
	local g = GS()
	local record = g and g.GetCurrentRecord and g:GetCurrentRecord() or nil
	local rows = {}
	if not record or type(record.currentCampaignId) ~= "string" then
		return rows
	end
	local items = record.accounting and record.accounting._consumables
		and record.accounting._consumables.requestedItems
	if type(items) ~= "table" then
		return rows
	end
	local canEdit = Caps().canEdit
	for _, row in pairs(items) do
		if type(row) == "table" and tonumber(row.itemId) then
			rows[#rows + 1] = {
				text = ItemLabel(row.itemId),
				itemId = row.itemId,
				goal = tonumber(row.goal) or 0,
				canRemove = canEdit,
				canEditGoal = canEdit,
			}
		end
	end
	table.sort(rows, function(a, b)
		return (a.itemId or 0) < (b.itemId or 0)
	end)
	return rows
end

local function StagedStatusText()
	local g = GS()
	local record = g and g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
	if not record then
		local caps = Caps()
		if caps.reason == "not_configured" or (g and g.GetCurrentRecord and select(2, g:GetCurrentRecord()) == "not_configured") then
			return Loc("GUILD_SUPPLIES_STATUS_NOT_CONFIGURED",
				"No staged Guild Supplies dataset for this guild yet. Use Initialize Guild Supplies.")
		end
		return Loc("GUILD_SUPPLIES_STATUS_UNAVAILABLE",
			"Guild Supplies data is unavailable (%s)."):format(tostring(caps.reason or "unknown"))
	end
	local campaign = record.currentCampaignId
	local activation = Loc("GUILD_SUPPLIES_STATUS_STAGED",
		"Staged only — live Guild Bank accounting still uses Raid Consumables until activation (#389).")
	if type(campaign) ~= "string" or campaign == "" then
		return activation .. " "
			.. Loc("GUILD_SUPPLIES_STATUS_NO_CAMPAIGN", "No campaign yet. Start a New Campaign before adding items.")
	end
	return activation .. " "
		.. Loc("GUILD_SUPPLIES_STATUS_CURRENT_CAMPAIGN", "Current campaign: %s"):format(campaign)
end

local function CommitConfig(ctx, kind, target, value)
	local g = GS()
	if not g then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	ctx.section:ClearMessage()
	local op, prepStatus, prepReason = g:NewConfigOperation(kind, target, value)
	if not op then
		ReportStatus(ctx, prepStatus or "rejected", prepReason)
		return
	end
	local status, reason = g:ApplyStagedConfigOperation(op)
	ReportStatus(ctx, status, reason)
end

local function CommitNewCampaign(ctx)
	local g = GS()
	local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
	if not g or not g.NewCampaignOperation then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	local confirm = function()
		ctx.section:ClearMessage()
		-- Recheck authority after the confirmation dialog.
		local op, prepStatus, prepReason = g:NewCampaignOperation()
		if not op then
			ReportStatus(ctx, prepStatus or "rejected", prepReason)
			return
		end
		local status, reason = g:ApplyStagedCampaignOperation(op)
		ReportStatus(ctx, status, reason)
	end
	if dialogs and dialogs.Confirm then
		dialogs:Confirm(
			Loc("GUILD_SUPPLIES_NEW_CAMPAIGN_CONFIRM",
				"Start a New Campaign? The current campaign keeps its items, goals, and history for Logs inspection. The new campaign starts empty."),
			Loc("GUILD_SUPPLIES_NEW_CAMPAIGN_BUTTON", "New Campaign"),
			confirm
		)
	else
		confirm()
	end
end

function Page:Build(panel)
	local renderer = SF.SettingsUI.DefinitionRenderer
	local caps = Caps()
	local g = GS()
	local record = g and g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
	local hasCampaign = record and type(record.currentCampaignId) == "string" and record.currentCampaignId ~= ""

	local def = {
		isAdmin = function()
			return Caps().canEdit or Caps().canRecoverPolicy
		end,
		sections = {
			{
				id = "gsStatus",
				title = Loc("GUILD_SUPPLIES_CONFIG_TITLE", "Guild Supplies"),
				tooltip = Loc("GUILD_SUPPLIES_CONFIG_TOOLTIP",
					"Guild-keyed staged configuration. Does not depend on Loot Helper profiles."),
				items = {
					{
						type = "help",
						indent = "label",
						text = StagedStatusText(),
					},
					{
						type = "display",
						label = Loc("GUILD_SUPPLIES_EDITOR_RANK", "Editor ranks"),
						get = function()
							local c = Caps()
							if c.editorRankLabel then
								return c.editorRankLabel
							end
							if c.editorRankName then
								return Loc("GUILD_SUPPLIES_EDITOR_RANK_FMT", "%s and higher")
									:format(c.editorRankName)
							end
							return Loc("GUILD_SUPPLIES_EDITOR_RANK_UNKNOWN", "Unavailable")
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_SUPPLIES_INIT_LABEL", "Guild setup"),
						adminOnly = true,
						buttonText = Loc("GUILD_SUPPLIES_INIT_BUTTON", "Initialize Guild Supplies"),
						width = 200,
						enabled = function()
							local c = Caps()
							if not c.canEdit and not c.canRecoverPolicy then
								return false
							end
							local mod = GS()
							if not mod then return false end
							local rec = select(1, mod:GetCurrentRecord())
							return rec == nil
						end,
						onClick = function(ctx)
							local mod = GS()
							ctx.section:ClearMessage()
							if not mod or not mod.CreateStagedRecord then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."),
									"error")
								return
							end
							local _, status, reason = mod:CreateStagedRecord()
							ReportStatus(ctx, status or "rejected", reason)
						end,
					},
					{
						type = "editbox",
						label = Loc("GUILD_SUPPLIES_BANK_TAB", "Bank Tab"),
						adminOnly = true,
						maxLetters = 1,
						tooltip = Loc("GUILD_SUPPLIES_BANK_TAB_TIP",
							"Shared across campaigns. Changing the tab establishes a new eligibility cutoff."),
						get = function()
							local mod = GS()
							local rec = mod and select(1, mod:GetCurrentRecord())
							local tab = rec and rec.accounting and rec.accounting._consumables
								and rec.accounting._consumables.bankTab
							return tab ~= nil and tostring(tab) or ""
						end,
						set = function() end,
						enabled = function()
							local mod = GS()
							return Caps().canEdit and mod and select(1, mod:GetCurrentRecord()) ~= nil
						end,
						onEnterPressed = function(ctx, text)
							local tab = tonumber(text)
							if text == nil or text == "" then
								CommitConfig(ctx, "set-bank-tab", "bankTab", nil)
								return
							end
							if not tab or tab < 1 or tab > 8 then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_BANK_TAB", "Enter a bank tab from 1 to 8, or clear the field."),
									"error")
								return
							end
							CommitConfig(ctx, "set-bank-tab", "bankTab", tab)
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_SUPPLIES_NEW_CAMPAIGN_LABEL", "Campaign"),
						adminOnly = true,
						buttonText = Loc("GUILD_SUPPLIES_NEW_CAMPAIGN_BUTTON", "New Campaign"),
						width = 160,
						enabled = function()
							local mod = GS()
							return Caps().canEdit and mod and select(1, mod:GetCurrentRecord()) ~= nil
						end,
						onClick = function(ctx)
							CommitNewCampaign(ctx)
						end,
					},
				},
			},
			{
				id = "gsItems",
				title = Loc("GUILD_SUPPLIES_ITEMS_TITLE", "Requested items"),
				tooltip = Loc("GUILD_SUPPLIES_ITEMS_TIP",
					"Campaign-owned. A New Campaign starts with an empty list."),
				items = {
					{
						type = "help",
						indent = "label",
						text = hasCampaign
							and Loc("GUILD_SUPPLIES_ITEMS_HELP",
								"Add exact item IDs for the current campaign. Goal edits keep contribution history.")
							or Loc("GUILD_SUPPLIES_ITEMS_NEED_CAMPAIGN",
								"Start a New Campaign before adding requested items."),
					},
					{
						type = "editboxButton",
						label = Loc("GUILD_SUPPLIES_ADD_ITEM", "Add item"),
						adminOnly = true,
						hint = Loc("GUILD_SUPPLIES_ADD_ITEM_HINT", "Item ID or link"),
						buttonText = Loc("GUILD_SUPPLIES_ADD_ITEM_BUTTON", "Add"),
						buttonWidth = 90,
						editWidth = 170,
						enabled = function()
							local mod = GS()
							local rec = mod and select(1, mod:GetCurrentRecord())
							return Caps().canEdit and rec and type(rec.currentCampaignId) == "string"
						end,
						onSubmit = function(ctx, text)
							local C = SF.Consumables
							local itemId = C and C.ItemIdFromText and C.ItemIdFromText(text) or tonumber(text)
							if not itemId then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ITEM", "Enter an item ID or paste an item link."),
									"error")
								return
							end
							CommitConfig(ctx, "set-requested-item", { itemId = itemId }, {
								itemId = itemId,
								goal = 0,
								removed = false,
							})
						end,
					},
					{
						type = "consumableRequestedList",
						label = Loc("GUILD_SUPPLIES_ITEM_LIST", "Current campaign items"),
						adminOnly = true,
						height = 180,
						getItems = RequestedItemRows,
						enabled = function()
							local mod = GS()
							local rec = mod and select(1, mod:GetCurrentRecord())
							return Caps().canEdit and rec and type(rec.currentCampaignId) == "string"
						end,
						onRemove = function(ctx, item)
							if not item or not item.itemId then return end
							CommitConfig(ctx, "set-requested-item", { itemId = item.itemId }, { removed = true })
						end,
						onGoalChanged = function(ctx, item, goal)
							if not item or not item.itemId then return end
							local gnum = tonumber(goal)
							if not gnum or gnum < 0 or gnum ~= math.floor(gnum) then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_GOAL", "Enter a non-negative whole-number goal."),
									"error")
								return
							end
							CommitConfig(ctx, "set-requested-item", { itemId = item.itemId }, {
								itemId = item.itemId,
								goal = gnum,
								removed = false,
							})
						end,
					},
				},
			},
			{
				id = "gsPersonal",
				title = Loc("GUILD_SUPPLIES_PERSONAL_TITLE", "Personal preferences"),
				tooltip = Loc("GUILD_SUPPLIES_PERSONAL_TIP",
					"Account-local. Available to ordinary members; never guild policy."),
				items = {
					{
						type = "checkbox",
						label = Loc("GUILD_SUPPLIES_REMINDERS", "Show raid supply reminders"),
						tooltip = Loc("GUILD_SUPPLIES_REMINDERS_TIP",
							"Personal reminder preference. Live reminder wiring remains with Raid Consumables until activation."),
						get = function()
							local store = SF.SettingsStore
							if not store or not store.Get then return true end
							return store:Get("lootHelper.showRaidSupplyReminders") and true or false
						end,
						set = function(value)
							local store = SF.SettingsStore
							if store and store.Set then
								store:Set("lootHelper.showRaidSupplyReminders", value and true or false)
							end
						end,
					},
				},
			},
		},
	}

	if renderer and renderer.Render then
		renderer:Render(panel, def)
	end
end

SF.SettingsUI:RegisterPage(Page)
