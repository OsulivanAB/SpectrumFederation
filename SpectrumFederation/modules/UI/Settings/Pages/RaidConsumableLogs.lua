-- Raid Consumable Logs: verified ledger history, pending observations, admin review.
local _, SF = ...

local Page = {
	id = "lootHelperConsumableLogs",
	parentId = "lootHelper",
	name = "Raid Consumable Logs",
	navLabel = "Consumable Logs",
	description = "Review raid-supply Guild Bank donations, pending verification, and configuration clears.",
	order = 23.7,
}

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

local function ItemName(itemId)
	if itemId == nil then return nil end
	if C_Item and C_Item.GetItemInfo then
		local name = C_Item.GetItemInfo(itemId)
		if type(name) == "string" and name ~= "" then
			return name
		end
	end
	if GetItemInfo then
		local name = GetItemInfo(itemId)
		if type(name) == "string" and name ~= "" then
			return name
		end
	end
	return nil
end

local historyOffset = 0
local historyProfileId = nil
local reuseHistory = false
local reusedHistory = nil
local selectedReviewClusterId = nil
local selectedReviewProfileId = nil

local function ActiveProfile()
	return SF.GetActiveProfile and SF:GetActiveProfile() or nil
end

local function ProfileKey(profile)
	if type(profile) ~= "table" then return nil end
	if profile.GetProfileId then
		local ok, id = pcall(profile.GetProfileId, profile)
		if ok and type(id) == "string" then return id end
	end
	return profile._profileId
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
	local C = SF.Consumables
	if C and C.IsCanonicalAdmin then
		return C.IsCanonicalAdmin(profile, Actor())
	end
	return false
end

local function PageSize()
	return (SF.Consumables and SF.Consumables.MAX_VISIBLE_HISTORY) or 200
end

local function ObservationDB()
	local db = SF.lootHelperDB
	if type(db) ~= "table" then return nil end
	return db
end

local function PendingRows(profile)
	local C = SF.Consumables
	local O = SF.ConsumablesObservation
	if not C or not O or type(profile) ~= "table" then return {} end
	local cfg = C.Ensure(profile)
	if type(cfg.guild) ~= "table" or type(cfg.guild.guid) ~= "string" then return {} end
	local tab = tonumber(cfg.bankTab)
	if not tab then return {} end
	local store = O.EnsureProfileStore(ObservationDB(), ProfileKey(profile))
	if not store then return {} end
	local pending = O.ListPending(store, cfg.guild.guid, tab)
	local items = {}
	local verifiedTxn = {}
	-- Suppress pending rows that already have a ledger txnId match.
	local bound = C.EventIndex and C.EventIndex(profile) or {}
	for _, event in pairs(bound) do
		if type(event) == "table" and type(event.txnId) == "string" then
			verifiedTxn[event.txnId] = true
		end
	end
	for i = 1, #pending do
		local obs = pending[i]
		if type(obs) == "table" and not (obs.txnId and verifiedTxn[obs.txnId]) then
			items[#items + 1] = {
				text = C.FormatObservation(obs, ItemName(obs.itemId)),
				canRemove = false,
				pending = true,
				clusterId = obs.localId,
				evidence = obs,
			}
		end
	end
	return items
end

local function LogItems()
	if reuseHistory and reusedHistory then
		return reusedHistory
	end
	local C = SF.Consumables
	local profile = ActiveProfile()
	if not C or not profile or not C.HistoryRows then
		Page.historyTotal = 0
		return {}
	end
	local profileId = ProfileKey(profile)
	if profileId ~= historyProfileId then
		historyProfileId = profileId
		historyOffset = 0
	end
	local limit = PageSize()
	local rows, total = C.HistoryRows(profile, ItemName, limit, historyOffset)
	total = tonumber(total) or #rows
	if historyOffset > 0 and historyOffset >= total then
		historyOffset = 0
		rows, total = C.HistoryRows(profile, ItemName, limit, 0)
		total = tonumber(total) or #rows
	end
	Page.historyTotal = total
	local items = {}
	-- Pending observations appear above the verified page for immediate feedback.
	if historyOffset == 0 then
		local pending = PendingRows(profile)
		for i = 1, #pending do
			items[#items + 1] = pending[i]
		end
	end
	for i = 1, #rows do
		items[#items + 1] = { text = rows[i].text, canRemove = false, verified = true }
	end
	reusedHistory = items
	return items
end

local function ShiftHistory(delta)
	local limit = PageSize()
	local total = Page.historyTotal or 0
	local nextOffset = historyOffset + (delta * limit)
	if nextOffset < 0 then nextOffset = 0 end
	if nextOffset > 0 and nextOffset >= total then return end
	historyOffset = nextOffset
	if Page.Refresh and Page.panel then
		Page:Refresh(Page.panel)
	end
end

local function HistoryHelp()
	local limit = PageSize()
	return string.format(
		Loc(
			"RAID_CONSUMABLE_LOGS_HELP",
			"Newest entries are first. Pending Guild Bank observations appear until verified. Each page shows up to %d verified entries, including configuration clears from every generation."
		),
		limit
	)
end

local function GoalProgressModel()
	local C = SF.Consumables
	local profile = ActiveProfile()
	if not C or not profile or not C.GoalProgress then
		return {
			items = {},
			hasPositiveGoal = false,
			overallEmptyText = Loc("RAID_SUPPLIES_NO_GOALS_CONFIGURED", "No goals configured."),
		}
	end
	return C.GoalProgress(profile)
end

local function ReviewStatusLabel(status)
	if status == "ambiguous" then
		return Loc("RAID_CONSUMABLE_REVIEW_STATUS_AMBIGUOUS", "Needs review")
	end
	if status == "rejected" then
		return Loc("RAID_CONSUMABLE_REVIEW_STATUS_REJECTED", "Rejected")
	end
	return Loc("RAID_CONSUMABLE_REVIEW_STATUS_PENDING", "Pending")
end

local function ReviewSummaryItems()
	local Sync = SF.LootHelperSync
	local summary = Sync and Sync._consumablesReviewSummary
	if type(summary) ~= "table" then return {} end
	local items = {}
	for i = 1, #summary do
		local row = summary[i]
		if type(row) == "table" then
			local name = ItemName(row.itemId) or ("item " .. tostring(row.itemId or "?"))
			local qty = tonumber(row.quantity) or 0
			local witnesses = tonumber(row.witnessCount) or 0
			items[#items + 1] = {
				text = string.format(
					Loc("RAID_CONSUMABLE_REVIEW_ROW", "%s donated %d %s — %s (%d witnesses)"),
					tostring(row.donor or Loc("RAID_CONSUMABLE_REVIEW_SOMEONE", "Someone")),
					qty,
					name,
					ReviewStatusLabel(row.status),
					witnesses
				),
				canRemove = false,
				clusterId = row.clusterId,
				evidence = row,
				status = row.status,
			}
		end
	end
	return items
end

local function InActiveSession(profile)
	local Sync = SF.LootHelperSync
	if not (Sync and Sync.state and Sync.state.active) then return false end
	return ProfileKey(profile) == Sync.state.profileId
end

local function SelectedReviewRow()
	local Sync = SF.LootHelperSync
	local summary = Sync and Sync._consumablesReviewSummary
	if type(summary) ~= "table" or not selectedReviewClusterId then return nil end
	for i = 1, #summary do
		local row = summary[i]
		if type(row) == "table" and row.clusterId == selectedReviewClusterId then
			return row
		end
	end
	return nil
end

local function EnsureReviewSelection(profile)
	local profileId = ProfileKey(profile)
	if profileId ~= selectedReviewProfileId then
		selectedReviewProfileId = profileId
		selectedReviewClusterId = nil
	end
	local Sync = SF.LootHelperSync
	local summary = Sync and Sync._consumablesReviewSummary
	if type(summary) ~= "table" or #summary == 0 then
		selectedReviewClusterId = nil
		return
	end
	if selectedReviewClusterId and SelectedReviewRow() then
		return
	end
	-- Default to the first pending/ambiguous row; otherwise the first rejected row.
	for i = 1, #summary do
		local row = summary[i]
		if type(row) == "table" and row.status ~= "rejected" and row.clusterId then
			selectedReviewClusterId = row.clusterId
			return
		end
	end
	if type(summary[1]) == "table" then
		selectedReviewClusterId = summary[1].clusterId
	end
end

local function Decide(action, row)
	local profile = ActiveProfile()
	local Sync = SF.LootHelperSync
	if not profile or not Sync or not Sync.SubmitConsumablesObsDecision then return end
	if not IsEffectiveAdmin(profile) then return end
	local decision = {
		action = action,
		clusterId = row and row.clusterId or nil,
		evidence = row and (row.evidence or row) or nil,
	}
	Sync:SubmitConsumablesObsDecision(profile, decision)
	if Page.Refresh and Page.panel then
		Page:Refresh(Page.panel)
	end
end

local function Definition()
	local profile = ActiveProfile()
	local admin = profile and IsEffectiveAdmin(profile)
	local inSession = profile and InActiveSession(profile)
	if admin then
		EnsureReviewSelection(profile)
	end
	local sections = {
		{
			id = "consumableLogs",
			title = Loc("RAID_CONSUMABLE_LOGS_TITLE", "Raid Consumable Logs"),
			items = {
				{ type = "help", indent = "label", text = HistoryHelp() },
				{
					type = "consumableGoalSummary",
					label = Loc("RAID_CONSUMABLE_LOGS_GOAL_PROGRESS", "Goal Progress"),
					getProgress = GoalProgressModel,
				},
				{
					type = "button",
					label = Loc("RAID_CONSUMABLE_LOGS_NEWER", "Newer entries"),
					buttonText = Loc("RAID_CONSUMABLE_LOGS_NEWER_BUTTON", "Newer"),
					width = 100,
					enabled = function() return historyOffset > 0 end,
					onClick = function()
						ShiftHistory(-1)
					end,
				},
				{
					type = "button",
					label = Loc("RAID_CONSUMABLE_LOGS_OLDER", "Older entries"),
					buttonText = Loc("RAID_CONSUMABLE_LOGS_OLDER_BUTTON", "Older"),
					width = 100,
					enabled = function()
						return historyOffset + PageSize() < (Page.historyTotal or 0)
					end,
					onClick = function()
						ShiftHistory(1)
					end,
				},
				{
					type = "scrollList",
					label = Loc("RAID_CONSUMABLE_LOGS_HISTORY", "History"),
					height = 280,
					getItems = LogItems,
				},
			},
		},
	}
	if admin then
		local selected = SelectedReviewRow()
		local selectedHelp
		if selected then
			local name = ItemName(selected.itemId) or ("item " .. tostring(selected.itemId or "?"))
			selectedHelp = string.format(
				Loc("RAID_CONSUMABLE_REVIEW_SELECTED", "Selected: %s donated %d %s"),
				tostring(selected.donor or Loc("RAID_CONSUMABLE_REVIEW_SOMEONE", "Someone")),
				tonumber(selected.quantity) or 0,
				name
			)
		else
			selectedHelp = Loc("RAID_CONSUMABLE_REVIEW_NONE_SELECTED", "Select a row to approve, reject, or correct.")
		end
		local reviewItems = {
			{
				type = "help",
				indent = "label",
				text = Loc(
					"RAID_CONSUMABLE_REVIEW_HELP",
					"During an active Loot Helper session, request the coordinator's pending observation summary. Approve or reject unresolved Guild Bank contributions. Preview as Non-Admin hides these controls."
				),
			},
			{
				type = "button",
				label = Loc("RAID_CONSUMABLE_REVIEW_REQUEST", "Request pending review"),
				buttonText = Loc("RAID_CONSUMABLE_REVIEW_REFRESH", "Refresh pending"),
				width = 140,
				enabled = function()
					return InActiveSession(ActiveProfile()) and IsEffectiveAdmin(ActiveProfile())
				end,
				onClick = function()
					local Sync = SF.LootHelperSync
					local p = ActiveProfile()
					if Sync and Sync.RequestConsumablesReviewSummary and p then
						Sync:RequestConsumablesReviewSummary(p)
					end
				end,
			},
			{
				type = "scrollList",
				label = Loc("RAID_CONSUMABLE_REVIEW_PENDING_LIST", "Pending review"),
				height = 160,
				getItems = ReviewSummaryItems,
				getSelectedKey = function()
					return selectedReviewClusterId
				end,
				onSelect = function(_ctx, item)
					if type(item) == "table" and item.clusterId then
						selectedReviewClusterId = item.clusterId
						if Page.Refresh and Page.panel then
							Page:Refresh(Page.panel)
						end
					end
				end,
			},
			{
				type = "help",
				indent = "label",
				text = selectedHelp,
			},
		}
		reviewItems[#reviewItems + 1] = {
			type = "button",
			label = Loc("RAID_CONSUMABLE_REVIEW_APPROVE_ALL", "Approve all pending"),
			buttonText = Loc("RAID_CONSUMABLE_REVIEW_APPROVE_ALL_BUTTON", "Approve all"),
			width = 120,
			enabled = function()
				local Sync = SF.LootHelperSync
				local summary = Sync and Sync._consumablesReviewSummary
				return InActiveSession(ActiveProfile()) and IsEffectiveAdmin(ActiveProfile())
					and type(summary) == "table" and #summary > 0
			end,
			onClick = function()
				local Sync = SF.LootHelperSync
				local summary = Sync and Sync._consumablesReviewSummary
				local p = ActiveProfile()
				if not (Sync and summary and p) then return end
				for i = 1, #summary do
					local row = summary[i]
					if type(row) == "table" and row.status ~= "ambiguous" and row.status ~= "rejected" then
						Sync:SubmitConsumablesObsDecision(p, {
							action = "approve",
							clusterId = row.clusterId,
							evidence = row,
						})
					end
				end
				if Page.Refresh and Page.panel then
					Page:Refresh(Page.panel)
				end
			end,
		}
		reviewItems[#reviewItems + 1] = {
			type = "button",
			label = Loc("RAID_CONSUMABLE_REVIEW_APPROVE", "Approve selected"),
			buttonText = Loc("RAID_CONSUMABLE_REVIEW_APPROVE_BUTTON", "Approve"),
			width = 120,
			enabled = function()
				local row = SelectedReviewRow()
				return InActiveSession(ActiveProfile()) and IsEffectiveAdmin(ActiveProfile())
					and row ~= nil and row.status ~= "rejected"
			end,
			onClick = function()
				local row = SelectedReviewRow()
				if row then
					Decide("approve", { clusterId = row.clusterId, evidence = row })
				end
			end,
		}
		reviewItems[#reviewItems + 1] = {
			type = "button",
			label = Loc("RAID_CONSUMABLE_REVIEW_REJECT", "Reject selected"),
			buttonText = Loc("RAID_CONSUMABLE_REVIEW_REJECT_BUTTON", "Reject"),
			width = 120,
			enabled = function()
				local row = SelectedReviewRow()
				return InActiveSession(ActiveProfile()) and IsEffectiveAdmin(ActiveProfile())
					and row ~= nil and row.status ~= "rejected"
			end,
			onClick = function()
				local row = SelectedReviewRow()
				if row then
					Decide("reject", { clusterId = row.clusterId, evidence = row })
				end
			end,
		}
		reviewItems[#reviewItems + 1] = {
			type = "button",
			label = Loc("RAID_CONSUMABLE_REVIEW_CORRECT", "Correct rejection"),
			buttonText = Loc("RAID_CONSUMABLE_REVIEW_CORRECT_BUTTON", "Override reject"),
			width = 130,
			enabled = function()
				local row = SelectedReviewRow()
				return InActiveSession(ActiveProfile()) and IsEffectiveAdmin(ActiveProfile())
					and row ~= nil and row.status == "rejected"
			end,
			onClick = function()
				local row = SelectedReviewRow()
				if row then
					Decide("correct", { clusterId = row.clusterId, evidence = row })
				end
			end,
		}
		if not inSession then
			-- Keep section visible; buttons stay disabled outside sessions.
		end
		sections[#sections + 1] = {
			id = "consumableReview",
			title = Loc("RAID_CONSUMABLE_REVIEW_TITLE", "Admin review"),
			adminOnly = true,
			items = reviewItems,
		}
	end
	return { sections = sections }
end

function Page:Build(panel)
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if not renderer then return end
	renderer:Build(panel, Definition())
	self.panel = panel
	if panel.HookScript and not panel.__sfConsumableLogsHook then
		panel.__sfConsumableLogsHook = true
		panel:HookScript("OnShow", function()
			Page:Refresh(panel)
		end)
	end
end

function Page:Refresh(panel)
	if panel and panel.IsShown and not panel:IsShown() then
		return
	end
	reuseHistory = false
	reusedHistory = nil
	LogItems()
	reuseHistory = true
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if renderer then
		renderer:Refresh(panel)
	end
	reuseHistory = false
	reusedHistory = nil
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
	-- One sort per quarter second while events arrive, not one sort per frame.
	if C_Timer and C_Timer.After then
		C_Timer.After(0.25, run)
	else
		run()
	end
end

if SF.Consumables and SF.Consumables.RegisterUIListener then
	SF.Consumables.RegisterUIListener(QueueRefresh)
end

SF.SettingsUI:RegisterPage(Page)
