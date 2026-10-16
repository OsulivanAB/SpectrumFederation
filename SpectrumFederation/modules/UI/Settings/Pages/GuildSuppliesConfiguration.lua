-- Guild Supplies → Configuration (#386). Staged guild setup and campaign editors.
-- Live bank helper / donation writer remains legacy Consumables until #389.
local _, SF = ...

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

SF.SettingsUI:RegisterCategory({
	id = "guildSupplies",
	name = Loc("GUILD_SUPPLIES_CATEGORY_NAME", "Guild Supplies"),
	navLabel = Loc("GUILD_SUPPLIES_CATEGORY_NAV", "Guild Supplies"),
	group = "Loot Tools", -- stable navigation group id (display owned by chrome)
	description = Loc("GUILD_SUPPLIES_CATEGORY_DESC",
		"Guild-owned raid supply campaigns, configuration, and logs."),
	order = 19,
})

local Page = {
	id = "guildSuppliesConfiguration",
	categoryId = "guildSupplies",
	name = Loc("GUILD_SUPPLIES_CONFIG_NAME", "Configuration"),
	navLabel = Loc("GUILD_SUPPLIES_CONFIG_NAV", "Configuration"),
	contentHeading = Loc("GUILD_SUPPLIES_CONFIG_HEADING", "Guild Supplies Configuration"),
	group = "Loot Tools",
	description = Loc("GUILD_SUPPLIES_CONFIG_DESC",
		"Fresh guild setup, bank tab, editor ranks, requested items, and New Campaign."),
	order = 19.1,
}

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

-- Ephemeral small-guild threshold choice for Initialize; never persisted.
local pendingInitRank = nil

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
	return Loc("GUILD_SUPPLIES_ITEM_FALLBACK", "item %s"):format(tostring(itemId))
end

local function RankOptions()
	local g = GS()
	local ctx = g and g.GetCurrentContext and g:GetCurrentContext() or nil
	local opts = {}
	if not ctx or type(ctx.ranks) ~= "table" then
		return opts
	end
	local count = tonumber(ctx.rankCount) or 0
	for i = 1, count do
		local name = ctx.ranks[i]
		if type(name) == "string" and name ~= "" then
			opts[#opts + 1] = { value = i, label = name }
		end
	end
	return opts
end

local function NeedsExplicitInitThreshold()
	local g = GS()
	local ctx = g and g.GetCurrentContext and g:GetCurrentContext() or nil
	if not ctx or not ctx.ready then
		return false
	end
	local count = tonumber(ctx.rankCount) or 0
	local defaultPos = (g and g.DEFAULT_EDITOR_RANK_POSITION) or 3
	if count <= 0 or count >= defaultPos then
		return false
	end
	local rec = g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
	return rec == nil
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
	local formatReason = g and g.FormatReasonText or function(r)
		return tostring(r or "unknown")
	end
	if not record then
		local caps = Caps()
		local recReason = g and g.GetCurrentRecord and select(2, g:GetCurrentRecord()) or nil
		if caps.reason == "not_configured" or recReason == "not_configured" then
			return Loc("GUILD_SUPPLIES_STATUS_NOT_CONFIGURED",
				"No staged Guild Supplies dataset for this guild yet. Use Initialize Guild Supplies.")
		end
		return Loc("GUILD_SUPPLIES_STATUS_UNAVAILABLE",
			"Guild Supplies data is unavailable (%s)."):format(formatReason(caps.reason or "unknown"))
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

local function ItemsHelpText()
	local g = GS()
	local record = g and g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
	local hasCampaign = record and type(record.currentCampaignId) == "string" and record.currentCampaignId ~= ""
	if hasCampaign then
		return Loc("GUILD_SUPPLIES_ITEMS_HELP",
			"Add exact item IDs for the current campaign. Goal edits keep contribution history.")
	end
	return Loc("GUILD_SUPPLIES_ITEMS_NEED_CAMPAIGN",
		"Start a New Campaign before adding requested items.")
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

local function CommitEditorRank(ctx, position)
	local g = GS()
	local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
	local caps = Caps()
	local pos = tonumber(position)
	if not g or not pos then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	if not caps.canEdit and not caps.canRecoverPolicy then
		ReportStatus(ctx, "rejected", caps.reason or "unauthorized")
		return
	end
	if caps.editorRankPosition and tonumber(caps.editorRankPosition) == pos then
		return
	end

	local ctxNow = g.GetCurrentContext and g:GetCurrentContext() or nil
	local selfRestricts = ctxNow and type(ctxNow.rankOrder) == "number" and ctxNow.rankOrder > pos
	local confirmMsg = Loc("GUILD_SUPPLIES_EDITOR_RANK_CONFIRM",
		"Change the editor rank threshold to this rank and higher?")
	if selfRestricts then
		confirmMsg = Loc("GUILD_SUPPLIES_EDITOR_RANK_CONFIRM_SELF",
			"Change the editor rank threshold? Your character would no longer meet it and would lose edit rights.")
	end

	-- Bind the intended operation before confirmation so guild/policy churn cannot
	-- silently rebuild against a different context on accept.
	local op, prepStatus, prepReason = g:NewConfigOperation("set-editor-rank", "editorRankPosition", pos)
	if not op then
		ReportStatus(ctx, prepStatus or "rejected", prepReason)
		return
	end
	local boundOp = op
	local accept = function()
		ctx.section:ClearMessage()
		local status, reason = g:ApplyStagedConfigOperation(boundOp)
		ReportStatus(ctx, status, reason)
	end
	if dialogs and dialogs.Confirm then
		dialogs:Confirm(confirmMsg, Loc("GUILD_SUPPLIES_EDITOR_RANK_APPLY", "Change rank"), accept)
	else
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_CONFIRM_UNAVAILABLE",
				"Confirmation is required and is unavailable right now."),
			"error")
	end
end

local function CommitNewCampaign(ctx)
	local g = GS()
	local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
	if not g or not g.NewCampaignOperation then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	-- Bind the intended operation to the original guild/campaign/policy context
	-- before showing confirmation. Do not rebuild on accept.
	local op, prepStatus, prepReason = g:NewCampaignOperation()
	if not op then
		ReportStatus(ctx, prepStatus or "rejected", prepReason)
		return
	end
	local boundOp = op
	local accept = function()
		ctx.section:ClearMessage()
		local status, reason = g:ApplyStagedCampaignOperation(boundOp)
		ReportStatus(ctx, status, reason)
	end
	if dialogs and dialogs.Confirm then
		dialogs:Confirm(
			Loc("GUILD_SUPPLIES_NEW_CAMPAIGN_CONFIRM",
				"Start a New Campaign? The current campaign keeps its items, goals, and history for Logs inspection. The new campaign starts empty."),
			Loc("GUILD_SUPPLIES_NEW_CAMPAIGN_BUTTON", "New Campaign"),
			accept
		)
	else
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_CONFIRM_UNAVAILABLE",
				"Confirmation is required and is unavailable right now."),
			"error")
	end
end

local function Definition()
	return {
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
						getText = StagedStatusText,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_SUPPLIES_EDITOR_RANK", "Editor ranks"),
						tooltip = Loc("GUILD_SUPPLIES_EDITOR_RANK_TIP",
							"Native guild ranks at or above this threshold may edit. Guild Masters can recover an invalid policy."),
						adminOnly = true,
						defaultText = Loc("GUILD_SUPPLIES_EDITOR_RANK_UNKNOWN", "Unavailable"),
						options = RankOptions,
						get = function()
							if NeedsExplicitInitThreshold() then
								return pendingInitRank
							end
							return Caps().editorRankPosition
						end,
						set = function(value)
							if NeedsExplicitInitThreshold() then
								pendingInitRank = tonumber(value)
							end
						end,
						enabled = function()
							local c = Caps()
							if NeedsExplicitInitThreshold() then
								return c.canRecoverPolicy == true
							end
							local mod = GS()
							local rec = mod and select(1, mod:GetCurrentRecord())
							return rec ~= nil and (c.canEdit or c.canRecoverPolicy)
						end,
						onValueChanged = function(ctx, value)
							if NeedsExplicitInitThreshold() then
								pendingInitRank = tonumber(value)
								if ctx.pageBuilder and ctx.pageBuilder.Refresh then
									ctx.pageBuilder:Refresh()
								end
								return
							end
							CommitEditorRank(ctx, value)
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
							if rec ~= nil then
								return false
							end
							if NeedsExplicitInitThreshold() then
								return pendingInitRank ~= nil
							end
							return true
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
							local threshold = nil
							if NeedsExplicitInitThreshold() then
								threshold = pendingInitRank
								if threshold == nil then
									ReportStatus(ctx, "rejected", "threshold_unselected")
									return
								end
							end
							local _, status, reason = mod:CreateStagedRecord(threshold)
							if status == "accepted" then
								pendingInitRank = nil
							end
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
						onCommit = function(ctx, text)
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
						getText = ItemsHelpText,
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
						onGoalCommit = function(ctx, item, goal)
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
end

function Page:Build(panel)
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if not renderer or not renderer.Build then
		return
	end
	renderer:Build(panel, Definition())
	self.panel = panel
end

function Page:Refresh(panel)
	panel = panel or self.panel
	if panel and panel.IsShown and not panel:IsShown() then
		return
	end
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if renderer and renderer.Refresh then
		renderer:Refresh(panel)
	end
end

-- Lifecycle: no permanent frames/timers; PageBuilder owns refresh registration.
function Page:OnHide()
end

SF.SettingsUI:RegisterPage(Page)
