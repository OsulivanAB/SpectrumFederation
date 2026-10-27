-- Guild Supplies → Configuration (#386/#389). Guild setup, campaigns, and live activation.
-- Adoption and configuration-conflict controls live on Troubleshooting (#422).
local _, SF = ...

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

SF.SettingsUI:RegisterCategory({
	id = "guildSupplies",
	name = Loc("GUILD_SUPPLIES_CATEGORY_NAME", "Raid Supplies"),
	navLabel = Loc("GUILD_SUPPLIES_CATEGORY_NAV", "Raid Supplies"),
	group = "Raid Tools", -- sidebar heading; chrome displays this string
	description = Loc("GUILD_SUPPLIES_CATEGORY_DESC",
		"Guild-owned raid supply campaigns, configuration, logs, and troubleshooting."),
	order = 32,
})

local Page = {
	id = "guildSuppliesConfiguration",
	categoryId = "guildSupplies",
	name = Loc("GUILD_SUPPLIES_CONFIG_NAME", "Configuration"),
	navLabel = Loc("GUILD_SUPPLIES_CONFIG_NAV", "Configuration"),
	contentHeading = Loc("GUILD_SUPPLIES_CONFIG_HEADING", "Raid Supplies Configuration"),
	group = "Raid Tools",
	description = Loc("GUILD_SUPPLIES_CONFIG_DESC",
		"Fresh guild setup, bank tab, requested items, and New Campaign."),
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

local refreshQueued = false
local rosterFrame = nil
local bankFrame = nil

-- Session-local Guild Bank tab name catalog (never SavedVariables / Gossip).
-- Authority: Retail GetNumGuildBankTabs / GetGuildBankTabInfo while the bank is open.
-- Scope: keyed by guildKey so names never cross guilds. Not proof of a fresh log sample.
local BANK_TAB_UNSET = false -- UI-only clear sentinel; schema still stores nil.
local bankTabCatalog = {
	guildKey = nil,
	loaded = false,
	-- [tabIndex] = { name = string, viewable = boolean }
	entries = {},
}
local guildBankOpen = false

--- Refresh controls through Page:Refresh so passCache bounds the render.
local function RefreshPageControls()
	if Page.Refresh and Page.panel then
		Page:Refresh(Page.panel)
	end
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

local function DescribeItem(itemId)
	local display = SF.ItemDisplay
	if display and type(display.Describe) == "function" then
		return display.Describe(itemId)
	end
	return {
		itemId = itemId,
		status = "unknown",
		name = Loc("GUILD_SUPPLIES_ITEM_UNKNOWN", "Unknown item"),
		icon = nil,
	}
end

--- True only for first-time setup (no dataset). Permission-only nil records are recovery.
local function IsNotConfigured()
	local _, reason = CurrentRecord()
	return reason == "not_configured"
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

local function CurrentGuildKey()
	local g = GS()
	local ctx = g and g.GetCurrentContext and g:GetCurrentContext() or nil
	if ctx and type(ctx.guildKey) == "string" and ctx.guildKey ~= "" then
		return ctx.guildKey
	end
	return nil
end

local function ClearBankTabCatalog()
	bankTabCatalog.guildKey = nil
	bankTabCatalog.loaded = false
	bankTabCatalog.entries = {}
end

--- Drop catalog entries when the player changes guilds.
local function SyncBankTabCatalogGuild()
	local key = CurrentGuildKey()
	if key == nil then
		if bankTabCatalog.guildKey ~= nil or bankTabCatalog.loaded then
			ClearBankTabCatalog()
		end
		return
	end
	if bankTabCatalog.guildKey ~= nil and bankTabCatalog.guildKey ~= key then
		ClearBankTabCatalog()
	end
end

--- Read purchased, named Guild Bank tabs. Only marks loaded when the API returns
-- coherent names; never invents labels. Caches viewable names for Settings.
-- @return boolean true when the catalog was refreshed from live API data
local function ObserveGuildBankTabs()
	SyncBankTabCatalogGuild()
	local key = CurrentGuildKey()
	if key == nil then
		return false
	end
	if type(GetNumGuildBankTabs) ~= "function" or type(GetGuildBankTabInfo) ~= "function" then
		return false
	end
	local okNum, num = pcall(GetNumGuildBankTabs)
	if not okNum or type(num) ~= "number" or num ~= math.floor(num) or num < 0 then
		return false
	end
	local maxTab = 8
	local g = GS()
	if g and tonumber(g.MAX_BANK_TAB) then
		maxTab = tonumber(g.MAX_BANK_TAB)
	end
	num = math.min(num, maxTab)
	local nextEntries = {}
	for i = 1, num do
		local ok, name, _, isViewable = pcall(GetGuildBankTabInfo, i)
		if not ok then
			return false
		end
		-- Purchased tabs must expose a non-empty name; empty means data not ready.
		if type(name) ~= "string" or name == "" then
			return false
		end
		nextEntries[i] = {
			name = name,
			viewable = isViewable == true,
		}
	end
	bankTabCatalog.guildKey = key
	bankTabCatalog.entries = nextEntries
	bankTabCatalog.loaded = true
	return true
end

local function BankTabCatalogLoaded()
	SyncBankTabCatalogGuild()
	return bankTabCatalog.loaded == true
		and bankTabCatalog.guildKey ~= nil
		and bankTabCatalog.guildKey == CurrentGuildKey()
end

local function FormatBankTabLabel(index, name)
	if type(name) == "string" and name ~= "" then
		return Loc("GUILD_SUPPLIES_BANK_TAB_OPTION_FMT", "Tab %d — %s")
			:format(index, name)
	end
	return Loc("GUILD_SUPPLIES_BANK_TAB_NUMBER_FMT", "Tab %d"):format(index)
end

--- Dropdown options: clear sentinel + purchased viewable tabs only.
local function BankTabOptions()
	local opts = {}
	if not BankTabCatalogLoaded() then
		return opts
	end
	opts[#opts + 1] = {
		value = BANK_TAB_UNSET,
		label = Loc("GUILD_SUPPLIES_BANK_TAB_CLEAR", "Not configured"),
	}
	local indices = {}
	for index, entry in pairs(bankTabCatalog.entries) do
		if entry and entry.viewable and type(entry.name) == "string" and entry.name ~= "" then
			indices[#indices + 1] = index
		end
	end
	table.sort(indices)
	for i = 1, #indices do
		local index = indices[i]
		local entry = bankTabCatalog.entries[index]
		opts[#opts + 1] = {
			value = index,
			label = FormatBankTabLabel(index, entry.name),
		}
	end
	return opts
end

--- Default button text when the configured value is not among selectable options.
local function BankTabDefaultText()
	local tab = CurrentBankTab()
	if tab == nil then
		if BankTabCatalogLoaded() then
			return Loc("GUILD_SUPPLIES_BANK_TAB_CLEAR", "Not configured")
		end
		return Loc("GUILD_SUPPLIES_BANK_TAB_SELECT", "Select a bank tab")
	end
	SyncBankTabCatalogGuild()
	local entry = bankTabCatalog.entries[tab]
	if entry and type(entry.name) == "string" and entry.name ~= "" then
		if entry.viewable then
			return FormatBankTabLabel(tab, entry.name)
		end
		-- Known but not selectable for this character: show number only, no private name.
		return Loc("GUILD_SUPPLIES_BANK_TAB_UNAVAILABLE_FMT", "Tab %d — unavailable")
			:format(tab)
	end
	-- Configured value preserved without inventing a name.
	return Loc("GUILD_SUPPLIES_BANK_TAB_NUMBER_FMT", "Tab %d"):format(tab)
end

local function BankTabDropdownValue()
	local tab = CurrentBankTab()
	if tab == nil then
		return BANK_TAB_UNSET
	end
	return tab
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
	-- Cap before constructing controls. Count every raw entry, including invalid;
	-- over-cap maps stay unavailable rather than becoming a truncated UI list.
	local C = SF.Consumables
	local maxItems = (C and C.MAX_REQUESTED_ITEMS) or 256
	local inspected = 0
	local canEdit = Caps().canEdit
	for _, row in pairs(items) do
		inspected = inspected + 1
		if inspected > maxItems then
			return {}
		end
		if type(row) == "table" and tonumber(row.itemId) then
			local described = DescribeItem(row.itemId)
			rows[#rows + 1] = {
				text = described.name,
				icon = described.icon,
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

---------------------------------------------------------------------------
-- Session-local Apply Adjustment draft (#426). Never SavedVariables / Gossip.
-- Cleared when dataset or current campaign identity changes. Ordinary refreshes
-- and delayed item-name loads must not reset valid in-progress input.
---------------------------------------------------------------------------
local ADJUST_UNASSIGNED = false -- UI-only sentinel; stored attribution stays nil.
local adjustDraft = {
	itemId = nil,
	quantityText = "",
	attributed = ADJUST_UNASSIGNED,
}
local adjustDraftContextKey = nil

local function AdjustDraftContextKey()
	local rec = CurrentRecord()
	if not rec then
		return "none"
	end
	return tostring(rec.datasetId or "") .. "|" .. tostring(rec.currentCampaignId or "")
end

local function SyncAdjustDraftContext()
	local key = AdjustDraftContextKey()
	if key == adjustDraftContextKey then
		return
	end
	adjustDraftContextKey = key
	adjustDraft.itemId = nil
	adjustDraft.quantityText = ""
	adjustDraft.attributed = ADJUST_UNASSIGNED
end

local function FormatAdjustItemLabel(itemId)
	local id = tonumber(itemId)
	if not id then
		return Loc("GUILD_SUPPLIES_ITEM_UNKNOWN", "Unknown item")
	end
	local described = DescribeItem(id)
	local name = described and described.name
	if type(name) ~= "string" or name == "" then
		return Loc("GUILD_SUPPLIES_ITEM_FALLBACK", "item %s"):format(tostring(id))
	end
	-- Stable item IDs distinguish quality variants that share a display name.
	return string.format("%s (#%d)", name, id)
end

local function AdjustItemOptions()
	SyncAdjustDraftContext()
	local options = {}
	local rows = RequestedItemRows()
	local selectedStillPresent = false
	for i = 1, #rows do
		local row = rows[i]
		local itemId = tonumber(row and row.itemId)
		if itemId then
			if adjustDraft.itemId == itemId then
				selectedStillPresent = true
			end
			options[#options + 1] = {
				value = itemId,
				label = FormatAdjustItemLabel(itemId),
			}
		end
	end
	if adjustDraft.itemId ~= nil and not selectedStillPresent then
		adjustDraft.itemId = nil
	end
	return options
end

local function AdjustItemDefaultText()
	SyncAdjustDraftContext()
	local options = AdjustItemOptions()
	if #options == 0 then
		return Loc("GUILD_SUPPLIES_ADJUST_EMPTY",
			"Add requested items to the current campaign before applying an adjustment.")
	end
	if adjustDraft.itemId ~= nil then
		return FormatAdjustItemLabel(adjustDraft.itemId)
	end
	return Loc("GUILD_SUPPLIES_ADJUST_ITEM_DEFAULT", "Select a requested item")
end

local function AdjustAttributionOptions()
	SyncAdjustDraftContext()
	local options = {
		{
			value = ADJUST_UNASSIGNED,
			label = Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned"),
		},
	}
	local seen = {}
	local names = {}
	local maxNames = 256
	if type(GetNumGuildMembers) == "function" and type(GetGuildRosterInfo) == "function" then
		local total = tonumber(GetNumGuildMembers()) or 0
		if total > maxNames then
			total = maxNames
		end
		for i = 1, total do
			local rosterName = GetGuildRosterInfo(i)
			local norm = rosterName
			if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
				norm = SF.NameUtil.NormalizeNameRealm(rosterName) or rosterName
			end
			if type(norm) == "string" and norm ~= "" and not seen[norm] then
				seen[norm] = true
				names[#names + 1] = norm
			end
		end
	end
	table.sort(names)
	for i = 1, #names do
		options[#options + 1] = { value = names[i], label = names[i] }
	end
	-- Keep a previously chosen credit visible even if the roster briefly lags.
	if type(adjustDraft.attributed) == "string" and adjustDraft.attributed ~= ""
		and not seen[adjustDraft.attributed] then
		options[#options + 1] = {
			value = adjustDraft.attributed,
			label = adjustDraft.attributed,
		}
	end
	return options
end

local function AdjustAttributionDefaultText()
	SyncAdjustDraftContext()
	if type(adjustDraft.attributed) == "string" and adjustDraft.attributed ~= "" then
		return adjustDraft.attributed
	end
	return Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
end

local function AdjustCanEdit()
	local rec = CurrentRecord()
	return Caps().canEdit and rec and type(rec.currentCampaignId) == "string"
end

local function AdjustHasRequestedItems()
	return #AdjustItemOptions() > 0
end

--- Compact Configuration status area: status / campaign / next step / warnings.
-- One snapshot per render pass so display/help rows stay consistent without
-- repeating activation or campaign guidance across rows.
local function BuildStatusSnapshot()
	local snap = {
		status = "",
		showCampaign = false,
		campaign = "",
		nextStep = nil,
		warning = nil,
	}
	local caps = Caps()
	local g = GS()
	local formatReason = g and g.FormatReasonText or function(r)
		return tostring(r or "unknown")
	end

	local function SetNextStep(body)
		if type(body) ~= "string" or body == "" then
			return
		end
		snap.nextStep = Loc("GUILD_SUPPLIES_NEXT_STEP_FMT", "Next step: %s"):format(body)
	end

	local function AppendWarning(text)
		if type(text) ~= "string" or text == "" then
			return
		end
		if snap.warning and snap.warning ~= "" then
			snap.warning = snap.warning .. " " .. text
		else
			snap.warning = text
		end
	end

	if not caps.canRead then
		snap.status = Loc("GUILD_SUPPLIES_STATUS_MEMBERSHIP_PENDING",
			"Guild membership is still being verified. Shared Guild Supplies details stay hidden until then.")
		return snap
	end

	local record, recReason = CurrentRecord()
	if not record then
		if caps.reason == "not_configured" or recReason == "not_configured" then
			snap.status = Loc("GUILD_SUPPLIES_STATUS_VALUE_NOT_CONFIGURED", "Not configured")
			SetNextStep(Loc("GUILD_SUPPLIES_NEXT_STEP_INITIALIZE",
				"Use Initialize Guild Supplies to create a staged dataset for this guild."))
			return snap
		end
		snap.status = Loc("GUILD_SUPPLIES_STATUS_VALUE_UNAVAILABLE", "Unavailable (%s)")
			:format(formatReason(caps.reason or recReason or "unknown"))
		return snap
	end

	snap.showCampaign = true
	local campaignId = record.currentCampaignId
	if type(campaignId) == "string" and campaignId ~= "" then
		snap.campaign = (g and g.GetCampaignDisplayName and g.GetCampaignDisplayName(record, campaignId))
			or campaignId
	else
		snap.campaign = Loc("GUILD_SUPPLIES_CAMPAIGN_NOT_STARTED", "Not started.")
	end

	local warningCoversReason = {}
	local mismatch = g and g.GetDatasetMismatchState and g:GetDatasetMismatchState() or nil
	if mismatch and mismatch.blocked and mismatch.peers and mismatch.peers[1] then
		local p = mismatch.peers[1]
		AppendWarning(Loc("GUILD_SUPPLIES_ADOPTION_BLOCKED",
			"A different staged dataset was advertised by %s (%s). Open the Troubleshooting tab to choose a source to replace this client's local staged dataset, or cancel to keep the current one.")
			:format(tostring(p.peerName), tostring(p.datasetId)))
		warningCoversReason.dataset_mismatch = true
	end
	local adop = g and g.GetPendingAdoption and g:GetPendingAdoption() or nil
	if type(adop) == "table" then
		AppendWarning(Loc("GUILD_SUPPLIES_ADOPTION_PENDING",
			"Adoption in progress for dataset %s from %s. Waiting for a complete validated transfer before switching.")
			:format(tostring(adop.sourceDatasetId), tostring(adop.sourcePeer)))
		warningCoversReason.adoption_in_progress = true
	end

	if record.activation == (g and g.ACTIVATION_ACTIVE) then
		local marker = record.liveCutover and record.liveCutover.cutoverMarker or "?"
		snap.status = Loc("GUILD_SUPPLIES_STATUS_ACTIVE",
			"Live — Guild Supplies owns guild bank accounting for this guild (cutover %s).")
			:format(tostring(marker))
		local liveConflict = g and g.GetLiveActivationConflictState and g:GetLiveActivationConflictState() or nil
		if liveConflict and liveConflict.blocked then
			AppendWarning(Loc("GUILD_SUPPLIES_STATUS_LIVE_CONFLICT",
				"Blocked: a peer advertised a conflicting live cutover marker. Adopt one canonical source before continuing."))
			warningCoversReason.live_activation_conflict = true
			SetNextStep(Loc("GUILD_SUPPLIES_NEXT_STEP_RESOLVE_CUTOVER",
				"Open the Troubleshooting tab to adopt one canonical live source before continuing."))
		end
		return snap
	end

	snap.status = Loc("GUILD_SUPPLIES_STATUS_VALUE_STAGED", "Staged")
	local readiness = g and g.GetActivationReadiness and g:GetActivationReadiness() or nil
	if type(campaignId) ~= "string" or campaignId == "" then
		SetNextStep(Loc("GUILD_SUPPLIES_NEXT_STEP_NEW_CAMPAIGN",
			"Start a New Campaign to begin configuring Guild Supplies."))
		return snap
	end
	if readiness and readiness.canActivate then
		SetNextStep(Loc("GUILD_SUPPLIES_NEXT_STEP_ACTIVATE_READY",
			"Configuration is ready. Use Activate Guild Supplies at the Guild Bank."))
		return snap
	end
	if readiness and readiness.reason and not warningCoversReason[readiness.reason] then
		local guide = g.FormatActivationGuidance and g.FormatActivationGuidance(readiness) or nil
		if type(guide) == "string" and guide ~= "" then
			SetNextStep(guide)
		else
			SetNextStep(Loc("GUILD_SUPPLIES_NEXT_STEP_ACTIVATION_BLOCKED",
				"Activation not ready: %s."):format(formatReason(readiness.reason)))
		end
	end
	return snap
end

local function StatusSnapshot()
	if passCache and passCache.statusSnapshot then
		return passCache.statusSnapshot
	end
	local snap = BuildStatusSnapshot()
	if passCache then
		passCache.statusSnapshot = snap
	end
	return snap
end

local function StatusRowText()
	return StatusSnapshot().status
end

local function CampaignRowVisible()
	return StatusSnapshot().showCampaign == true
end

local function CampaignRowText()
	return StatusSnapshot().campaign
end

local function NextStepVisible()
	local step = StatusSnapshot().nextStep
	return type(step) == "string" and step ~= ""
end

local function NextStepText()
	return StatusSnapshot().nextStep or ""
end

local function WarningVisible()
	local warning = StatusSnapshot().warning
	return type(warning) == "string" and warning ~= ""
end

local function WarningText()
	return StatusSnapshot().warning or ""
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

local function CommitRenameCampaign(ctx, campaignId, text)
	local g = GS()
	if not g or not g.NewRenameCampaignOperation then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	ctx.section:ClearMessage()
	local op, prepStatus, prepReason = g:NewRenameCampaignOperation(campaignId, text)
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
	-- Bind the intended operation to the original guild/campaign/policy context
	-- before confirmation (or immediate apply). Do not rebuild on accept.
	local op, prepStatus, prepReason = g:NewCampaignOperation()
	if not op then
		ReportStatus(ctx, prepStatus or "rejected", prepReason)
		return
	end
	local boundOp = op
	local accept = function()
		ctx.section:ClearMessage()
		-- Finalize startedAt once at apply time; keep bound scope/bases.
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
	-- First campaign: create immediately. Subsequent campaigns archive the
	-- current one and need an explicit confirmation.
	local requiresConfirm = type(boundOp.baseCampaignId) == "string"
		and boundOp.baseCampaignId ~= ""
	if not requiresConfirm then
		accept()
		return
	end
	if dialogs and dialogs.Confirm then
		dialogs:Confirm(
			Loc("GUILD_SUPPLIES_NEW_CAMPAIGN_CONFIRM",
				"Start a new campaign? The current campaign will be archived, and the new campaign will start with empty goals and progress."),
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

--- Native rank names. Used only to repair a corrupt historical permission record.
local function RecoveryRankOptions()
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

--- Historical permission repair only. A missing officer policy is not corruption.
local function CanRepairHistoricalPermission()
	if IsNotConfigured() then
		return false
	end
	local c = Caps()
	if c.canRecoverPolicy ~= true or c.canEdit == true then
		return false
	end
	if c.reason == "policy_unknown" or c.reason == "policy_invalid" then
		return false
	end
	local g = GS()
	if not g or type(g.GetCurrentRecord) ~= "function"
		or type(g._IsPermissionOnlyFailure) ~= "function" then
		return false
	end
	local _, reason = g:GetCurrentRecord()
	return g._IsPermissionOnlyFailure(reason) and true or false
end

local function CommitEditorRank(ctx, position)
	local g = GS()
	local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
	local pos = tonumber(position)
	if not g or not pos then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	if not CanRepairHistoricalPermission() then
		ReportStatus(ctx, "rejected", "unauthorized")
		return
	end
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
		dialogs:Confirm(
			Loc("GUILD_SUPPLIES_EDITOR_RANK_RECOVER_CONFIRM",
				"Repair the stored Guild Supplies permission record to this rank? This does not change who can edit. Editing follows the shared officer rank."),
			Loc("GUILD_SUPPLIES_EDITOR_RANK_APPLY", "Repair record"),
			accept)
	else
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_CONFIRM_UNAVAILABLE",
				"Confirmation is required and is unavailable right now."),
			"error")
	end
end

-- Disabled-control tips: derive from the same Caps/record/readiness predicates
-- that gate enabled. Prefer the immediate blocker; never invent prerequisites.
-- Unverified membership must not learn guild-owned configuration details.

local function DisabledMembershipTip()
	return Loc("GUILD_SUPPLIES_DISABLED_MEMBERSHIP",
		"Join a guild with a verified membership before using Guild Supplies.")
end

local function DisabledUnauthorizedTip(action)
	return Loc("GUILD_SUPPLIES_DISABLED_UNAUTHORIZED_FMT",
		"Your guild rank does not permit %s."):format(action)
end

--- Permission/membership gate shared by privileged Configuration controls.
-- @param action string short action phrase for unauthorized copy
-- @param allowRecover boolean|nil also accept canRecoverPolicy
-- @return string|nil tip when blocked, else nil
local function DisabledAuthTip(action, allowRecover)
	local c = Caps()
	if not c.canRead then
		return DisabledMembershipTip()
	end
	if c.canEdit then
		return nil
	end
	if allowRecover and c.canRecoverPolicy then
		return nil
	end
	return DisabledUnauthorizedTip(action)
end

local function DisabledNeedRecordTip(actionNoun)
	local auth = DisabledAuthTip(actionNoun, false)
	if auth then
		return auth
	end
	if CurrentRecord() ~= nil then
		return nil
	end
	if IsNotConfigured() then
		return Loc("GUILD_SUPPLIES_DISABLED_NEED_INIT",
			"Initialize Guild Supplies for this guild first.")
	end
	-- canRead but record unavailable (permission-only / redacted): no guild detail.
	return Loc("GUILD_SUPPLIES_DISABLED_DATA_UNAVAILABLE",
		"Guild Supplies data is unavailable right now.")
end

local function DisabledNeedCampaignTip(actionNoun)
	local tip = DisabledNeedRecordTip(actionNoun)
	if tip then
		return tip
	end
	local rec = CurrentRecord()
	if rec and type(rec.currentCampaignId) == "string" then
		return nil
	end
	return Loc("GUILD_SUPPLIES_DISABLED_NEED_CAMPAIGN",
		"Start a New Campaign before continuing.")
end

local function DisabledBankTabTip()
	-- Auth / init blockers take precedence over "open the Guild Bank".
	local tip = DisabledNeedRecordTip(
		Loc("GUILD_SUPPLIES_DISABLED_ACTION_BANK_TAB", "configuring the bank tab"))
	if tip then
		return tip
	end
	if BankTabCatalogLoaded() then
		return nil
	end
	return Loc("GUILD_SUPPLIES_DISABLED_BANK_TAB_OPEN",
		"Open your Guild Bank to load the available tabs.")
end

local function DisabledInitializeTip()
	local c = Caps()
	if not c.canEdit and not c.canRecoverPolicy then
		if not c.canRead then
			return DisabledMembershipTip()
		end
		if c.reason == "policy_unknown" or c.reason == "policy_invalid" then
			return Loc("GUILD_SUPPLIES_DISABLED_POLICY_UNKNOWN",
				"Officer rank is not available yet, so Guild Supplies setup stays disabled.")
		end
		return DisabledUnauthorizedTip(
			Loc("GUILD_SUPPLIES_DISABLED_ACTION_INITIALIZE", "initializing Guild Supplies"))
	end
	if not IsNotConfigured() then
		-- Already have a dataset (or recovery path); do not claim init is incomplete.
		return Loc("GUILD_SUPPLIES_DISABLED_ALREADY_INITIALIZED",
			"Guild Supplies has already been initialized for this guild.")
	end
	return nil
end

local function DisabledActivateTip()
	local mod = GS()
	local c = Caps()
	if not c.canEdit then
		if not c.canRead then
			return DisabledMembershipTip()
		end
		return DisabledUnauthorizedTip(
			Loc("GUILD_SUPPLIES_DISABLED_ACTION_ACTIVATE", "activating Guild Supplies"))
	end
	if not mod or not mod.GetActivationReadiness then
		return Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable.")
	end
	local ready = mod:GetActivationReadiness()
	if ready and ready.canActivate then
		return nil
	end
	if ready and ready.alreadyActive then
		return Loc("GUILD_SUPPLIES_DISABLED_ALREADY_ACTIVE",
			"Guild Supplies is already active for this guild.")
	end
	local reason = ready and ready.reason or nil
	if reason == "no_campaign" then
		return Loc("GUILD_SUPPLIES_DISABLED_ACTIVATE_NEED_CAMPAIGN",
			"Start a New Campaign before activating Guild Supplies.")
	end
	if reason == "divergent_edit" then
		return Loc("GUILD_SUPPLIES_DISABLED_ACTIVATE_CONFLICTS",
			"Resolve open configuration conflicts before activating Guild Supplies.")
	end
	if reason == "dataset_mismatch" or reason == "live_activation_conflict" then
		return Loc("GUILD_SUPPLIES_DISABLED_ACTIVATE_DATASET",
			"Resolve the conflicting dataset (adoption) before activating Guild Supplies.")
	end
	if reason == "adoption_in_progress" then
		return Loc("GUILD_SUPPLIES_DISABLED_ACTIVATE_ADOPTION",
			"Finish or cancel dataset adoption before activating Guild Supplies.")
	end
	if reason == "not_configured" then
		return Loc("GUILD_SUPPLIES_DISABLED_NEED_INIT",
			"Initialize Guild Supplies for this guild first.")
	end
	local guide = mod.FormatActivationGuidance and mod.FormatActivationGuidance(ready) or nil
	if type(guide) == "string" and guide ~= "" then
		return guide
	end
	local formatReason = mod.FormatReasonText or function(r)
		return tostring(r or "unknown")
	end
	return Loc("GUILD_SUPPLIES_DISABLED_ACTIVATE_FMT",
		"Cannot activate yet: %s."):format(formatReason(reason or "not_ready"))
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
						type = "display",
						label = Loc("GUILD_SUPPLIES_STATUS_ROW_LABEL", "Current Status"),
						get = StatusRowText,
					},
					{
						type = "display",
						label = Loc("GUILD_SUPPLIES_CAMPAIGN_ROW_LABEL", "Campaign"),
						get = CampaignRowText,
						visible = CampaignRowVisible,
					},
					{
						type = "help",
						indent = "label",
						padTop = 4,
						getText = NextStepText,
						visible = NextStepVisible,
					},
					{
						type = "help",
						indent = "label",
						padTop = 2,
						getText = WarningText,
						visible = WarningVisible,
					},
					{
						type = "spacer",
						height = 4,
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
							return true
						end,
						getDisabledTooltip = DisabledInitializeTip,
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
							local _, status, reason = mod:CreateStagedRecord()
							ReportStatus(ctx, status or "rejected", reason)
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_SUPPLIES_ACTIVATE_LABEL", "Live activation"),
						adminOnly = true,
						buttonText = Loc("GUILD_SUPPLIES_ACTIVATE_BUTTON", "Activate Guild Supplies"),
						width = 200,
						tooltip = Loc("GUILD_SUPPLIES_ACTIVATE_TIP",
							"Any authorized editor may activate. Requires a fresh Guild Bank log sample for the configured tab. Idempotent after success."),
						enabled = function()
							local mod = GS()
							if not Caps().canEdit or not mod or not mod.GetActivationReadiness then
								return false
							end
							local ready = mod:GetActivationReadiness()
							return ready and ready.canActivate == true
						end,
						getDisabledTooltip = DisabledActivateTip,
						onClick = function(ctx)
							local mod = GS()
							ctx.section:ClearMessage()
							if not mod or not mod.ActivateCanonicalDataset then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."),
									"error")
								return
							end
							local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
							local function commit()
								local _, status, reason = mod:ActivateCanonicalDataset()
								ReportStatus(ctx, status or "rejected", reason)
								-- Rebuild navigation so retired Raid Consumables pages disappear.
								local win = SF.SettingsUI and SF.SettingsUI.StandaloneWindow
								if win and win.BuildNavItemsFromRegistry then
									win:BuildNavItemsFromRegistry()
								end
							end
							if dialogs and dialogs.Confirm then
								dialogs:Confirm(
									Loc("GUILD_SUPPLIES_ACTIVATE_CONFIRM",
										"Activate Guild Supplies as the live guild-owned writer? Pre-activation bank rows will not be credited. This cannot silently fall back to Raid Consumables profiles."),
									Loc("GUILD_SUPPLIES_ACTIVATE_CONFIRM_OK", "Activate"),
									commit)
							else
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_CONFIRM_UNAVAILABLE",
										"Confirmation is required and is unavailable right now."),
									"error")
							end
						end,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_SUPPLIES_PERMISSION_REPAIR", "Repair stored permission"),
						tooltip = Loc("GUILD_SUPPLIES_PERMISSION_REPAIR_TIP",
							"Repairs a corrupt historical permission record. It does not choose who can edit Guild Supplies."),
						adminOnly = true,
						visible = function()
							return CanRepairHistoricalPermission()
						end,
						defaultText = Loc("GUILD_SUPPLIES_EDITOR_RANK_UNKNOWN", "Unavailable"),
						options = RecoveryRankOptions,
						get = function()
							if not CanRepairHistoricalPermission() then
								return nil
							end
							return Caps().editorRankPosition
						end,
						set = function() end,
						enabled = function()
							return CanRepairHistoricalPermission()
						end,
						getDisabledTooltip = function()
							if CanRepairHistoricalPermission() then
								return nil
							end
							return Loc("GUILD_SUPPLIES_EDITOR_RANK_DISABLED",
								"Who can edit follows the shared officer rank. This control only repairs a corrupt stored permission record.")
						end,
						onValueChanged = function(ctx, value)
							CommitEditorRank(ctx, value)
						end,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_SUPPLIES_BANK_TAB", "Bank Tab"),
						adminOnly = true,
						width = 220,
						tooltip = Loc("GUILD_SUPPLIES_BANK_TAB_TIP",
							"Shared across campaigns. Changing the tab establishes a new eligibility cutoff."),
						defaultText = BankTabDefaultText,
						options = BankTabOptions,
						get = BankTabDropdownValue,
						set = function() end,
						enabled = function()
							return Caps().canEdit
								and CurrentRecord() ~= nil
								and BankTabCatalogLoaded()
						end,
						getDisabledTooltip = DisabledBankTabTip,
						onValueChanged = function(ctx, value)
							local current = CurrentBankTab()
							if value == BANK_TAB_UNSET or value == nil then
								if current == nil then
									return
								end
								CommitConfig(ctx, "set-bank-tab", "bankTab", nil)
								return
							end
							local tab = tonumber(value)
							if not tab or tab < 1 or tab > 8 or tab ~= math.floor(tab) then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_BANK_TAB",
										"Choose a Guild Bank tab from the list, or clear the selection."),
									"error")
								return
							end
							-- Only accept tabs currently offered as viewable; never invent.
							local entry = BankTabCatalogLoaded() and bankTabCatalog.entries[tab] or nil
							if not entry or entry.viewable ~= true then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_BANK_TAB",
										"Choose a Guild Bank tab from the list, or clear the selection."),
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
						tooltip = Loc("GUILD_SUPPLIES_NEW_CAMPAIGN_TIP",
							"Starts a fresh campaign with empty goals and progress. Previous campaigns are archived and can be viewed in Logs."),
						enabled = function()
							return Caps().canEdit and CurrentRecord() ~= nil
						end,
						getDisabledTooltip = function()
							return DisabledNeedRecordTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_NEW_CAMPAIGN", "starting a New Campaign"))
						end,
						onClick = function(ctx)
							CommitNewCampaign(ctx)
						end,
					},
					{
						type = "editboxButton",
						label = Loc("GUILD_SUPPLIES_RENAME_CAMPAIGN_LABEL", "Campaign name"),
						adminOnly = true,
						hint = Loc("GUILD_SUPPLIES_RENAME_CAMPAIGN_HINT", "Friendly name (blank clears)"),
						buttonText = Loc("GUILD_SUPPLIES_RENAME_CAMPAIGN_BUTTON", "Rename"),
						buttonWidth = 90,
						editWidth = 200,
						maxLetters = 64,
						tooltip = Loc("GUILD_SUPPLIES_RENAME_CAMPAIGN_TIP",
							"Sets a guild-wide display name for the current campaign. Clearing the name restores the campaign ID label. Accounting and campaign identity stay unchanged."),
						get = function()
							local rec = CurrentRecord()
							if not rec or type(rec.currentCampaignId) ~= "string" then
								return ""
							end
							local g = GS()
							if g and g.GetCampaignCustomName then
								return g.GetCampaignCustomName(rec, rec.currentCampaignId) or ""
							end
							return ""
						end,
						getSelectionKey = function()
							local rec = CurrentRecord()
							return rec and rec.currentCampaignId or nil
						end,
						enabled = function()
							local rec = CurrentRecord()
							return Caps().canEdit and rec and type(rec.currentCampaignId) == "string"
						end,
						getDisabledTooltip = function()
							return DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_RENAME", "renaming the campaign"))
						end,
						onSubmit = function(ctx, text)
							local rec = select(1, GS() and GS():GetCurrentRecord())
							local campaignId = rec and rec.currentCampaignId
							if type(campaignId) ~= "string" or campaignId == "" then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_REASON_NO_CAMPAIGN",
										"start a New Campaign before changing requested items"),
									"error")
								return
							end
							CommitRenameCampaign(ctx, campaignId, text)
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
						getDisabledTooltip = function()
							return DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_ITEMS", "editing requested items"))
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
						showItemIcons = true,
						getItems = RequestedItemRows,
						enabled = function()
							local rec = CurrentRecord()
							return Caps().canEdit and rec and type(rec.currentCampaignId) == "string"
						end,
						getDisabledTooltip = function()
							return DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_ITEMS", "editing requested items"))
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
				id = "gsAdjust",
				title = Loc("GUILD_SUPPLIES_ADJUST_TITLE", "Quantity adjustment"),
				tooltip = Loc("GUILD_SUPPLIES_ADJUST_TIP",
					"Authenticated editors may adjust item totals. Adjustments never verify Guild Bank deposits."),
				items = {
					{
						type = "help",
						indent = "label",
						getText = function()
							SyncAdjustDraftContext()
							if AdjustCanEdit() and not AdjustHasRequestedItems() then
								return Loc("GUILD_SUPPLIES_ADJUST_EMPTY",
									"Add requested items to the current campaign before applying an adjustment.")
							end
							return Loc("GUILD_SUPPLIES_ADJUST_HELP",
								"Choose a current campaign item, enter a whole-number change such as 10 or -10, and optionally credit a character. Leave attribution on Unassigned to change only the item total. Changes apply to the guild-owned Guild Supplies ledger and never verify Guild Bank deposits.")
						end,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_SUPPLIES_ADJUST_ITEM", "Requested item"),
						adminOnly = true,
						width = 260,
						defaultText = AdjustItemDefaultText,
						options = AdjustItemOptions,
						get = function()
							SyncAdjustDraftContext()
							return adjustDraft.itemId
						end,
						set = function() end,
						enabled = function()
							return AdjustCanEdit() and AdjustHasRequestedItems()
						end,
						getDisabledTooltip = function()
							local tip = DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_ADJUST", "adjusting quantities"))
							if tip then
								return tip
							end
							if not AdjustHasRequestedItems() then
								return Loc("GUILD_SUPPLIES_ADJUST_EMPTY",
									"Add requested items to the current campaign before applying an adjustment.")
							end
							return nil
						end,
						onValueChanged = function(ctx, value)
							SyncAdjustDraftContext()
							local itemId = tonumber(value)
							if not itemId then
								return
							end
							-- Require the choice to still be a current requested item.
							local options = AdjustItemOptions()
							local found = false
							for i = 1, #options do
								if options[i].value == itemId then
									found = true
									break
								end
							end
							if not found then
								adjustDraft.itemId = nil
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ADJUST_ITEM",
										"Select a requested campaign item before applying an adjustment."),
									"error")
								RefreshPageControls()
								return
							end
							adjustDraft.itemId = itemId
							RefreshPageControls()
						end,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_SUPPLIES_ADJUST_ATTR", "Attribution"),
						adminOnly = true,
						width = 220,
						defaultText = AdjustAttributionDefaultText,
						options = AdjustAttributionOptions,
						get = function()
							SyncAdjustDraftContext()
							return adjustDraft.attributed
						end,
						set = function() end,
						enabled = function()
							return AdjustCanEdit() and AdjustHasRequestedItems()
						end,
						getDisabledTooltip = function()
							return DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_ADJUST", "adjusting quantities"))
						end,
						onValueChanged = function(_, value)
							SyncAdjustDraftContext()
							if value == ADJUST_UNASSIGNED or value == nil then
								adjustDraft.attributed = ADJUST_UNASSIGNED
							elseif type(value) == "string" and value ~= "" then
								adjustDraft.attributed = value
							end
						end,
					},
					{
						type = "editboxButton",
						label = Loc("GUILD_SUPPLIES_ADJUST_QTY", "Quantity change"),
						adminOnly = true,
						hint = Loc("GUILD_SUPPLIES_ADJUST_QTY_HINT", "10 or -10"),
						buttonText = Loc("GUILD_SUPPLIES_ADJUST_APPLY", "Apply adjustment"),
						buttonWidth = 140,
						editWidth = 120,
						maxLetters = 8,
						get = function()
							SyncAdjustDraftContext()
							return adjustDraft.quantityText or ""
						end,
						getSelectionKey = function()
							SyncAdjustDraftContext()
							return AdjustDraftContextKey()
						end,
						enabled = function()
							return AdjustCanEdit()
								and AdjustHasRequestedItems()
								and adjustDraft.itemId ~= nil
						end,
						getDisabledTooltip = function()
							local tip = DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_ADJUST", "adjusting quantities"))
							if tip then
								return tip
							end
							if not AdjustHasRequestedItems() then
								return Loc("GUILD_SUPPLIES_ADJUST_EMPTY",
									"Add requested items to the current campaign before applying an adjustment.")
							end
							if adjustDraft.itemId == nil then
								return Loc("GUILD_SUPPLIES_ERR_ADJUST_ITEM",
									"Select a requested campaign item before applying an adjustment.")
							end
							return nil
						end,
						onSubmit = function(ctx, text)
							SyncAdjustDraftContext()
							local g = GS()
							local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
							if not g or not g.NewAdjustmentOperation or not g.ParseAdjustmentQuantity then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."),
									"error")
								return
							end
							-- Preserve typed quantity across cancel/failure.
							adjustDraft.quantityText = tostring(text or "")
							local itemId = tonumber(adjustDraft.itemId)
							if not itemId then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ADJUST_ITEM",
										"Select a requested campaign item before applying an adjustment."),
									"error")
								return
							end
							local quantity, qtyErr = g.ParseAdjustmentQuantity(adjustDraft.quantityText)
							if not quantity then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ADJUST_FORMAT",
										"Enter a whole-number quantity such as 10 or -10. Do not use a leading plus sign."),
									"error")
								return
							end
							local attributed = nil
							if type(adjustDraft.attributed) == "string" and adjustDraft.attributed ~= "" then
								attributed = adjustDraft.attributed
							end
							-- Capture draft identity so success only clears when context matches.
							local boundItemId = itemId
							local boundContext = AdjustDraftContextKey()
							local op, prepStatus, prepReason = g:NewAdjustmentOperation(
								itemId, quantity, attributed)
							if not op then
								ReportStatus(ctx, prepStatus or "rejected", prepReason or qtyErr)
								return
							end
							local preview = g.PreviewAdjustment
								and g:PreviewAdjustment(itemId, quantity, attributed) or nil
							local confirmMsg
							if preview and g.FormatAdjustmentConfirmation then
								confirmMsg = g.FormatAdjustmentConfirmation(
									preview, FormatAdjustItemLabel(itemId))
							else
								confirmMsg = Loc("GUILD_SUPPLIES_ADJUST_CONFIRM",
									"Adjust item %s by %+d on the Guild Supplies ledger?")
									:format(FormatAdjustItemLabel(itemId), quantity)
							end
							local accept = function()
								-- Revalidate permissions/context/item/totals/goal at commit.
								SyncAdjustDraftContext()
								if AdjustDraftContextKey() ~= boundContext
									or tonumber(adjustDraft.itemId) ~= boundItemId
									or not AdjustCanEdit() then
									ctx.section:SetMessage(
										Loc("GUILD_SUPPLIES_REASON_STALE_HANDLE",
											"the page is out of date — refresh and try again"),
										"error")
									RefreshPageControls()
									return
								end
								ctx.section:ClearMessage()
								local status, reason = g:ApplyStagedConfigOperation(op)
								if status == "accepted" or status == "duplicate" then
									if AdjustDraftContextKey() == boundContext
										and tonumber(adjustDraft.itemId) == boundItemId then
										adjustDraft.quantityText = ""
									end
								end
								ReportStatus(ctx, status, reason)
								RefreshPageControls()
							end
							if dialogs and dialogs.Confirm then
								dialogs:Confirm(confirmMsg,
									Loc("GUILD_SUPPLIES_ADJUST_APPLY", "Apply adjustment"), accept)
							else
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_CONFIRM_UNAVAILABLE",
										"Confirmation is required and is unavailable right now."),
									"error")
							end
						end,
					},
				},
			},
			{
				id = "gsLinks",
				title = Loc("GUILD_SUPPLIES_LINKS_TITLE", "Witness character links"),
				tooltip = Loc("GUILD_SUPPLIES_LINKS_TIP",
					"Link known alternate characters so they count as one witness identity for donation quorum."),
				items = {
					{
						type = "help",
						indent = "label",
						getText = function()
							return Loc("GUILD_SUPPLIES_LINKS_HELP",
								"Guild-owned links only. Linking does not rewrite accepted donations. Unlinked characters remain separate witnesses. Does not use Loot Helper profiles.")
						end,
					},
					{
						type = "editboxButton",
						label = Loc("GUILD_SUPPLIES_LINKS_APPLY", "Link characters"),
						adminOnly = true,
						hint = Loc("GUILD_SUPPLIES_LINKS_GUID_A", "Character GUID A")
							.. " " .. Loc("GUILD_SUPPLIES_LINKS_GUID_B", "Character GUID B"),
						buttonText = Loc("GUILD_SUPPLIES_LINKS_APPLY", "Link characters"),
						buttonWidth = 140,
						editWidth = 260,
						enabled = function()
							return Caps().canEdit and CurrentRecord() ~= nil
						end,
						getDisabledTooltip = function()
							return DisabledNeedRecordTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_LINKS", "linking characters"))
						end,
						onSubmit = function(ctx, text)
							local g = GS()
							if not g or not g.NewLinkCharactersOperation then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."),
									"error")
								return
							end
							local a, b = tostring(text or ""):match("^%s*(%S+)%s+(%S+)%s*$")
							local op, prepStatus, prepReason = g:NewLinkCharactersOperation(a, b)
							if not op then
								ReportStatus(ctx, prepStatus or "rejected", prepReason)
								return
							end
							ctx.section:ClearMessage()
							local status, reason = g:ApplyStagedConfigOperation(op)
							ReportStatus(ctx, status, reason)
							RefreshPageControls()
						end,
					},
					{
						type = "editboxButton",
						label = Loc("GUILD_SUPPLIES_LINKS_UNLINK", "Unlink character"),
						adminOnly = true,
						hint = Loc("GUILD_SUPPLIES_LINKS_UNLINK_GUID", "Character GUID to unlink"),
						buttonText = Loc("GUILD_SUPPLIES_LINKS_UNLINK", "Unlink character"),
						buttonWidth = 140,
						editWidth = 260,
						enabled = function()
							return Caps().canEdit and CurrentRecord() ~= nil
						end,
						getDisabledTooltip = function()
							return DisabledNeedRecordTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_UNLINK", "unlinking characters"))
						end,
						onSubmit = function(ctx, text)
							local g = GS()
							if not g or not g.NewUnlinkCharacterOperation then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."),
									"error")
								return
							end
							local guid = tostring(text or ""):match("^%s*(%S+)%s*$")
							local op, prepStatus, prepReason = g:NewUnlinkCharacterOperation(guid)
							if not op then
								ReportStatus(ctx, prepStatus or "rejected", prepReason)
								return
							end
							ctx.section:ClearMessage()
							local status, reason = g:ApplyStagedConfigOperation(op)
							ReportStatus(ctx, status, reason)
							RefreshPageControls()
						end,
					},
					{
						type = "display",
						label = Loc("GUILD_SUPPLIES_LINKS_TITLE", "Witness character links"),
						get = function()
							local rec = CurrentRecord()
							local links = rec and rec.identityLinks
							if type(links) ~= "table" or type(links.groups) ~= "table" then
								return Loc("GUILD_SUPPLIES_LINKS_EMPTY", "No character links yet.")
							end
							local n = 0
							for _ in pairs(links.groups) do n = n + 1 end
							if n == 0 then
								return Loc("GUILD_SUPPLIES_LINKS_EMPTY", "No character links yet.")
							end
							return Loc("GUILD_SUPPLIES_LINKS_COUNT", "%d link group(s)"):format(n)
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
							"Personal reminder preference for raid supply deposits."),
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
		SyncBankTabCatalogGuild()
		-- Re-read names while the bank is open so delayed API responses surface Settings.
		if guildBankOpen then
			ObserveGuildBankTabs()
		end
		Page:Refresh(Page.panel)
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0, run)
	else
		run()
	end
end

local function EnsureItemDisplayListener()
	local display = SF.ItemDisplay
	if not display or type(display.RegisterRefresh) ~= "function" then
		return
	end
	display.RegisterRefresh("guildSuppliesConfiguration", function()
		QueueRefresh()
	end)
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
		SyncBankTabCatalogGuild()
		QueueRefresh()
	end)
end

--- Event-driven refresh when bank open/close/log/tab updates change readiness or names.
-- No continuous polling; coalesced via QueueRefresh while the page is visible.
local function EnsureBankListener()
	if bankFrame or type(CreateFrame) ~= "function" then
		return
	end
	local frame = CreateFrame("Frame")
	bankFrame = frame
	local events = {
		"GUILDBANKFRAME_OPENED",
		"GUILDBANKFRAME_CLOSED",
		"GUILDBANKLOG_UPDATE",
		"GUILDBANK_UPDATE_TABS",
		"PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
		"PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
	}
	for i = 1, #events do
		if frame.RegisterEvent then
			pcall(frame.RegisterEvent, frame, events[i])
		end
	end
	frame:SetScript("OnEvent", function(_, event, arg1)
		if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW"
			or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
			if not (Enum and Enum.PlayerInteractionType
				and arg1 == Enum.PlayerInteractionType.GuildBanker) then
				return
			end
			if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
				guildBankOpen = true
				ObserveGuildBankTabs()
			else
				guildBankOpen = false
			end
		elseif event == "GUILDBANKFRAME_OPENED" then
			guildBankOpen = true
			ObserveGuildBankTabs()
		elseif event == "GUILDBANKFRAME_CLOSED" then
			guildBankOpen = false
		elseif event == "GUILDBANK_UPDATE_TABS" then
			-- Renames / newly purchased tabs; keep session cache fresh while open.
			if guildBankOpen then
				ObserveGuildBankTabs()
			end
		end
		-- GUILDBANKLOG_UPDATE only drives activation-readiness refresh (not names).
		QueueRefresh()
	end)
end

--- Coalesced refresh when adoption ready/expiry flips asynchronously (Settings open).
local adoptionHooked = false
local function EnsureAdoptionListener()
	if adoptionHooked then
		return
	end
	local g = GS()
	if not g then
		return
	end
	adoptionHooked = true
	local previous = g.OnAdoptionStateChanged
	g.OnAdoptionStateChanged = function(reason)
		if previous then
			pcall(previous, reason)
		end
		QueueRefresh()
	end
end

--- Shared officer-policy changes can grant or revoke edit rights without roster events.
local officerHooked = false
local function EnsureOfficerListener()
	if officerHooked or Page.__sfOfficerHook then
		return
	end
	local GO = SF.GuildOfficer
	if not GO or type(GO.RegisterUIListener) ~= "function" then
		return
	end
	officerHooked = true
	Page.__sfOfficerHook = true
	GO.RegisterUIListener(function()
		QueueRefresh()
	end)
end

function Page:Build(panel)
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if not renderer or not renderer.Build then
		return
	end
	EnsureRosterListener()
	EnsureBankListener()
	EnsureAdoptionListener()
	EnsureOfficerListener()
	EnsureItemDisplayListener()
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
EnsureBankListener()
EnsureAdoptionListener()
EnsureItemDisplayListener()

SF.SettingsUI:RegisterPage(Page)
