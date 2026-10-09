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

local function ReviewSummaryItems()
	local Sync = SF.LootHelperSync
	local summary = Sync and Sync._consumablesReviewSummary
	if type(summary) ~= "table" then return {} end
	local C = SF.Consumables
	local items = {}
	for i = 1, #summary do
		local row = summary[i]
		if type(row) == "table" then
			local name = ItemName(row.itemId) or ("item " .. tostring(row.itemId or "?"))
			local qty = tonumber(row.quantity) or 0
			local witnesses = tonumber(row.witnessCount) or 0
			local status = row.status == "ambiguous" and "Needs review" or "Pending"
			items[#items + 1] = {
				text = string.format(
					"%s donated %d %s — %s (%d witnesses)",
					tostring(row.donor or "Someone"),
					qty,
					name,
					status,
					witnesses
				),
				canRemove = false,
				clusterId = row.clusterId,
				evidence = row,
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

local function Decide(action, row)
	local profile = ActiveProfile()
	local Sync = SF.LootHelperSync
	if not profile or not Sync or not Sync.SubmitConsumablesObsDecision then return end
	if not IsEffectiveAdmin(profile) then return end
	local decision = {
		action = action,
		clusterId = row and row.clusterId or nil,
		evidence = row and row.evidence or nil,
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
	local sections = {
		{
			id = "consumableLogs",
			title = "Raid Consumable Logs",
			items = {
				{ type = "help", indent = "label", text = HistoryHelp() },
				{
					type = "consumableGoalSummary",
					label = "Goal Progress",
					getProgress = GoalProgressModel,
				},
				{
					type = "button",
					label = "Newer entries",
					buttonText = "Newer",
					width = 100,
					enabled = function() return historyOffset > 0 end,
					onClick = function()
						ShiftHistory(-1)
					end,
				},
				{
					type = "button",
					label = "Older entries",
					buttonText = "Older",
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
					label = "History",
					height = 280,
					getItems = LogItems,
				},
			},
		},
	}
	if admin then
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
				label = "Request pending review",
				buttonText = "Refresh pending",
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
				label = "Pending review",
				height = 160,
				getItems = ReviewSummaryItems,
			},
		}
		-- Batch approve all currently summarized pending (non-ambiguous) rows.
		reviewItems[#reviewItems + 1] = {
			type = "button",
			label = "Approve all pending",
			buttonText = "Approve all",
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
					if type(row) == "table" and row.status ~= "ambiguous" then
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
		-- Per-row approve/reject for the first summarized entry (minimal workflow).
		reviewItems[#reviewItems + 1] = {
			type = "button",
			label = "Approve selected",
			buttonText = "Approve first",
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
				if type(summary) == "table" and summary[1] then
					Decide("approve", { clusterId = summary[1].clusterId, evidence = summary[1] })
				end
			end,
		}
		reviewItems[#reviewItems + 1] = {
			type = "button",
			label = "Reject selected",
			buttonText = "Reject first",
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
				if type(summary) == "table" and summary[1] then
					Decide("reject", { clusterId = summary[1].clusterId, evidence = summary[1] })
				end
			end,
		}
		reviewItems[#reviewItems + 1] = {
			type = "button",
			label = "Correct rejection",
			buttonText = "Override reject",
			width = 130,
			enabled = function()
				local Sync = SF.LootHelperSync
				local summary = Sync and Sync._consumablesReviewSummary
				return InActiveSession(ActiveProfile()) and IsEffectiveAdmin(ActiveProfile())
					and type(summary) == "table" and #summary > 0
			end,
			onClick = function()
				local Sync = SF.LootHelperSync
				local summary = Sync and Sync._consumablesReviewSummary
				if type(summary) == "table" and summary[1] then
					Decide("correct", { clusterId = summary[1].clusterId, evidence = summary[1] })
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
