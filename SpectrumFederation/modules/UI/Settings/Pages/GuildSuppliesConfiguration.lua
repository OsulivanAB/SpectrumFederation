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

-- Per build/refresh pass only: reuse validated read context across controls.
-- Cleared after the pass so mutations always recheck authority/base freshly.
local passCache = nil

local function BeginRenderPass()
	passCache = {}
end

local function EndRenderPass()
	passCache = nil
end

local function CurrentRecord()
	if passCache and passCache.recordChecked then
		return passCache.record, passCache.recordReason
	end
	local g = GS()
	local record, reason
	if g and g.GetCurrentRecord then
		record, reason = g:GetCurrentRecord()
	else
		reason = "not_ready"
	end
	if passCache then
		passCache.recordChecked = true
		passCache.record = record
		passCache.recordReason = reason
	end
	return record, reason
end

local function Caps()
	if passCache and passCache.caps then
		return passCache.caps
	end
	local g = GS()
	local caps
	if not g or not g.GetCapabilities then
		caps = { canEdit = false, canRead = false, canRecoverPolicy = false, reason = "not_ready" }
	else
		caps = g:GetCapabilities()
	end
	if passCache then
		passCache.caps = caps
	end
	return caps
end

-- Ephemeral small-guild threshold choice for Initialize; never persisted.
-- Bound to the originating guild/rank-count context (not a bare scalar).
local pendingInitRank = nil
local pendingInitGuildKey = nil
local pendingInitRankCount = nil
local refreshQueued = false
local rosterFrame = nil

--- Refresh controls through Page:Refresh so passCache bounds the render.
local function RefreshPageControls()
	if Page.Refresh and Page.panel then
		Page:Refresh(Page.panel)
	end
end

local function ClearPendingInitRank()
	pendingInitRank = nil
	pendingInitGuildKey = nil
	pendingInitRankCount = nil
end

--- Drop a stale initialization choice only when guild/rank context actually changes.
local function SyncPendingInitContext()
	if pendingInitRank == nil then
		return
	end
	local g = GS()
	local ctx = g and g.GetCurrentContext and g:GetCurrentContext() or nil
	if not ctx or type(ctx.guildKey) ~= "string" or ctx.guildKey == "" then
		ClearPendingInitRank()
		return
	end
	local count = tonumber(ctx.rankCount) or 0
	if ctx.guildKey ~= pendingInitGuildKey or count ~= pendingInitRankCount then
		ClearPendingInitRank()
	end
end

local function SetPendingInitRank(value)
	local g = GS()
	local ctx = g and g.GetCurrentContext and g:GetCurrentContext() or nil
	local pos = tonumber(value)
	if not pos or not ctx or type(ctx.guildKey) ~= "string" then
		ClearPendingInitRank()
		return
	end
	pendingInitRank = pos
	pendingInitGuildKey = ctx.guildKey
	pendingInitRankCount = tonumber(ctx.rankCount) or 0
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
	RefreshPageControls()
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

--- True only for first-time setup (no dataset). Permission-only nil records are recovery.
local function IsNotConfigured()
	local _, reason = CurrentRecord()
	return reason == "not_configured"
end

local function NeedsExplicitInitThreshold()
	SyncPendingInitContext()
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
	return IsNotConfigured()
end

local function CurrentBankTab()
	if not Caps().canRead then
		return nil
	end
	local rec = CurrentRecord()
	local tab = rec and rec.accounting and rec.accounting._consumables
		and rec.accounting._consumables.bankTab
	return tab ~= nil and tonumber(tab) or nil
end

local function RequestedItemRows()
	local rows = {}
	-- Shared campaign/item data stays redacted until membership canRead is verified.
	if not Caps().canRead then
		return rows
	end
	local record = CurrentRecord()
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
	local caps = Caps()
	if not caps.canRead then
		return Loc("GUILD_SUPPLIES_STATUS_MEMBERSHIP_PENDING",
			"Guild membership is still being verified. Shared Guild Supplies details stay hidden until then.")
	end
	local g = GS()
	local record, recReason = CurrentRecord()
	local formatReason = g and g.FormatReasonText or function(r)
		return tostring(r or "unknown")
	end
	if not record then
		if caps.reason == "not_configured" or recReason == "not_configured" then
			return Loc("GUILD_SUPPLIES_STATUS_NOT_CONFIGURED",
				"No staged Guild Supplies dataset for this guild yet. Use Initialize Guild Supplies.")
		end
		return Loc("GUILD_SUPPLIES_STATUS_UNAVAILABLE",
			"Guild Supplies data is unavailable (%s)."):format(formatReason(caps.reason or recReason or "unknown"))
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
	if not Caps().canRead then
		return Loc("GUILD_SUPPLIES_STATUS_MEMBERSHIP_PENDING",
			"Guild membership is still being verified. Shared Guild Supplies details stay hidden until then.")
	end
	local record = CurrentRecord()
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
		-- Finalize startedAt once at confirmation accept; keep bound scope/bases.
		if g.FinalizeCampaignStartTime then
			local okFinal, finalReason = g:FinalizeCampaignStartTime(boundOp)
			if not okFinal then
				ReportStatus(ctx, "rejected", finalReason or "server_time_unavailable")
				return
			end
		end
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
							SyncPendingInitContext()
							if NeedsExplicitInitThreshold() then
								return pendingInitRank
							end
							-- Redact shared policy display until membership canRead; recovery
							-- enablement still uses Caps().canRecoverPolicy below.
							if not Caps().canRead and not Caps().canRecoverPolicy then
								return nil
							end
							return Caps().editorRankPosition
						end,
						set = function(value)
							if NeedsExplicitInitThreshold() then
								SetPendingInitRank(value)
							end
						end,
						enabled = function()
							local c = Caps()
							if NeedsExplicitInitThreshold() then
								return c.canRecoverPolicy == true
							end
							-- Permission-only recovery: GetCurrentRecord may be nil while
							-- canRecoverPolicy is true; NewConfigOperation still resolves it.
							if c.canRecoverPolicy then
								return true
							end
							local rec = CurrentRecord()
							return rec ~= nil and c.canEdit == true
						end,
						onValueChanged = function(ctx, value)
							if NeedsExplicitInitThreshold() then
								SetPendingInitRank(value)
								RefreshPageControls()
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
							-- Only true first-time setup; existing unusable records use recovery.
							if not IsNotConfigured() then
								return false
							end
							SyncPendingInitContext()
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
							if not IsNotConfigured() then
								ReportStatus(ctx, "rejected", "already_configured")
								return
							end
							local threshold = nil
							SyncPendingInitContext()
							if NeedsExplicitInitThreshold() then
								threshold = pendingInitRank
								if threshold == nil then
									ReportStatus(ctx, "rejected", "threshold_unselected")
									return
								end
							end
							local _, status, reason = mod:CreateStagedRecord(threshold)
							if status == "accepted" then
								ClearPendingInitRank()
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
							local tab = CurrentBankTab()
							return tab ~= nil and tostring(tab) or ""
						end,
						set = function() end,
						enabled = function()
							return Caps().canEdit and CurrentRecord() ~= nil
						end,
						onCommit = function(ctx, text)
							-- Enter then ClearFocus both fire Commit; skip unchanged values
							-- so one Enter admits one operation and idle focus loss admits none.
							local current = CurrentBankTab()
							if text == nil or text == "" then
								if current == nil then
									return
								end
								CommitConfig(ctx, "set-bank-tab", "bankTab", nil)
								return
							end
							local tab = tonumber(text)
							if not tab or tab < 1 or tab > 8 or tab ~= math.floor(tab) then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_BANK_TAB", "Enter a bank tab from 1 to 8, or clear the field."),
									"error")
								return
							end
							if current == tab then
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
							return Caps().canEdit and CurrentRecord() ~= nil
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
							local rec = CurrentRecord()
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
							-- Fresh mutation-time read (not the render pass cache).
							local g = GS()
							local live = g and select(1, g:GetCurrentRecord())
							local items = live and live.accounting and live.accounting._consumables
								and live.accounting._consumables.requestedItems
							if type(items) == "table" and type(items[tostring(itemId)]) == "table" then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ITEM_EXISTS",
										"That item is already requested. Change its goal in the list instead of adding it again."),
									"warn")
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
							local rec = CurrentRecord()
							return Caps().canEdit and rec and type(rec.currentCampaignId) == "string"
						end,
						onRemove = function(ctx, item)
							if not item or not item.itemId then return end
							CommitConfig(ctx, "set-requested-item", { itemId = item.itemId }, { removed = true })
						end,
						onGoalCommit = function(ctx, item, goal)
							if not item or not item.itemId then return end
							local C = SF.Consumables
							local gnum = C and C.ValidGoal and C.ValidGoal(goal) or nil
							if gnum == nil then
								local maxGoal = (C and tonumber(C.MAX_GOAL)) or 100000
								local raw = tonumber(goal)
								if raw and raw == math.floor(raw) and raw >= 0 and raw > maxGoal then
									ctx.section:SetMessage(
										Loc("GUILD_SUPPLIES_ERR_GOAL_RANGE",
											"Enter a whole-number goal from 0 to %d."):format(maxGoal),
										"error")
								else
									ctx.section:SetMessage(
										Loc("GUILD_SUPPLIES_ERR_GOAL", "Enter a non-negative whole-number goal."),
										"error")
								end
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

-- Standalone Settings can hide the parent while the page panel stays IsShown.
-- Prefer IsVisible so roster-driven work does not run against a closed window.
local function PanelVisible(panel)
	if not panel then return false end
	if panel.IsVisible then
		return panel:IsVisible() and true or false
	end
	if panel.IsShown then
		return panel:IsShown() and true or false
	end
	return false
end

local function QueueRefresh()
	local panel = Page.panel
	if not panel or not Page.Refresh then return end
	if not PanelVisible(panel) then return end
	if refreshQueued then return end
	refreshQueued = true
	local function run()
		refreshQueued = false
		if not Page.panel or not Page.Refresh then return end
		if not PanelVisible(Page.panel) then return end
		SyncPendingInitContext()
		Page:Refresh(Page.panel)
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0, run)
	else
		run()
	end
end

local function EnsureRosterListener()
	if rosterFrame or type(CreateFrame) ~= "function" then
		return
	end
	local frame = CreateFrame("Frame")
	rosterFrame = frame
	frame:RegisterEvent("GUILD_ROSTER_UPDATE")
	if frame.RegisterEvent then
		pcall(frame.RegisterEvent, frame, "PLAYER_GUILD_UPDATE")
	end
	frame:SetScript("OnEvent", function()
		SyncPendingInitContext()
		QueueRefresh()
	end)
end

function Page:Build(panel)
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if not renderer or not renderer.Build then
		return
	end
	EnsureRosterListener()
	BeginRenderPass()
	renderer:Build(panel, Definition())
	EndRenderPass()
	self.panel = panel
	if panel.HookScript and not panel.__sfGuildSuppliesConfigHook then
		panel.__sfGuildSuppliesConfigHook = true
		panel:HookScript("OnShow", function()
			QueueRefresh()
		end)
	end
end

function Page:Refresh(panel)
	panel = panel or self.panel
	if not PanelVisible(panel) then
		return
	end
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if renderer and renderer.Refresh then
		BeginRenderPass()
		renderer:Refresh(panel)
		EndRenderPass()
	end
end

function Page:OnHide()
	refreshQueued = false
	-- Do not rely on OnHide for visibility gating; PanelVisible uses IsVisible.
end

EnsureRosterListener()

SF.SettingsUI:RegisterPage(Page)
