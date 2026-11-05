-- Guild Supplies → Logs (#453). Current-campaign contribution table.
-- Member-readable. Goals/progress live on Configuration. Archived history retained.
local _, SF = ...

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

local Page = {
	id = "guildSuppliesLogs",
	categoryId = "guildSupplies",
	name = Loc("GUILD_SUPPLIES_LOGS_NAME", "Logs"),
	navLabel = Loc("GUILD_SUPPLIES_LOGS_NAV", "Logs"),
	contentHeading = Loc("GUILD_SUPPLIES_LOGS_HEADING", "Raid Supplies Logs"),
	group = "Raid Tools",
	description = Loc("GUILD_SUPPLIES_LOGS_DESC",
		"Review current-campaign donations and quantity adjustments."),
	order = 19.2,
	layout = {
		disablePageScroll = true,
	},
}

local function GS()
	return SF.GuildSupplies
end

-- Ephemeral filter / scroll identity only; never persisted.
local FILTER_ALL = false
local filterContributor = FILTER_ALL
local filterItemId = FILTER_ALL
local filterContextKey = nil
local cachedProjectedRows = nil
local cachedProjectionKey = nil
local refreshQueued = false
local rosterFrame = nil
local passCache = nil

local function BeginRenderPass()
	passCache = {}
end

local function EndRenderPass()
	passCache = nil
end

local function Caps()
	if passCache and passCache.caps then
		return passCache.caps
	end
	local g = GS()
	local caps
	if not g or not g.GetCapabilities then
		caps = { canRead = false, reason = "not_ready" }
	else
		caps = g:GetCapabilities()
	end
	if passCache then
		passCache.caps = caps
	end
	return caps
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

--- Always the guild record's active campaign; follows rollover automatically (#453).
local function ActiveCampaignId()
	if not Caps().canRead then
		return nil
	end
	local record = CurrentRecord()
	if not record then
		return nil
	end
	local id = record.currentCampaignId
	if type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

local function FilterContextKey()
	local rec = CurrentRecord()
	if not rec then
		return "none"
	end
	return tostring(rec.datasetId or "") .. "|" .. tostring(rec.currentCampaignId or "")
end

local function SyncFilterContext()
	local key = FilterContextKey()
	if key == filterContextKey then
		return
	end
	filterContextKey = key
	filterContributor = FILTER_ALL
	filterItemId = FILTER_ALL
	cachedProjectedRows = nil
	cachedProjectionKey = nil
end

--- Scroll identity includes campaign/dataset plus active filters (#453).
local function ScrollContextKey()
	SyncFilterContext()
	return FilterContextKey()
		.. "|" .. tostring(filterContributor)
		.. "|" .. tostring(filterItemId)
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

local function ItemNameForHistory(itemId)
	local described = DescribeItem(itemId)
	if type(described.name) == "string" and described.name ~= "" then
		return described.name
	end
	return nil
end

--- One validated Guild Info record + name index per projection pass (#453).
-- Avoids calling GI:GetCurrentRecord (full validation) once per history row.
local function GuildClassLookup()
	if passCache and passCache.guildClassLookupChecked then
		return passCache.guildClassLookup
	end
	local lookup = {
		byGuid = nil,
		byName = nil,
		getCurrentRecordCalls = 0,
	}
	local GI = SF.GuildInfo
	if GI and type(GI.GetCurrentRecord) == "function" then
		lookup.getCurrentRecordCalls = lookup.getCurrentRecordCalls + 1
		local record = GI:GetCurrentRecord()
		if type(record) == "table" and type(record.characters) == "table" then
			lookup.byGuid = record.characters
			local byName = {}
			for _, row in pairs(record.characters) do
				if type(row) == "table"
					and type(row.nameRealm) == "string" and row.nameRealm ~= ""
					and type(row.classFile) == "string" and row.classFile ~= "" then
					byName[string.lower(row.nameRealm)] = row.classFile
				end
			end
			lookup.byName = byName
		end
	end
	if passCache then
		passCache.guildClassLookupChecked = true
		passCache.guildClassLookup = lookup
	end
	return lookup
end

local function LookupClassFile(guid, nameRealm)
	local lookup = GuildClassLookup()
	if type(guid) == "string" and guid ~= "" and type(lookup.byGuid) == "table" then
		local row = lookup.byGuid[guid]
		if type(row) == "table" and type(row.classFile) == "string" and row.classFile ~= "" then
			return row.classFile
		end
	end
	if type(nameRealm) == "string" and nameRealm ~= "" and type(lookup.byName) == "table" then
		return lookup.byName[string.lower(nameRealm)]
	end
	return nil
end

--- Color the displayed contributor identity (#453).
-- Class must belong to the same identity as the displayed name. Prefer the
-- resolved display name; allow a GUID fallback only when that GUID's character
-- row is the displayed name (never a linked alt's class for a main name).
local function ColorizeContributor(name, guid)
	if type(name) ~= "string" or name == "" then
		return name
	end
	local classFile = LookupClassFile(nil, name)
	if not classFile and type(guid) == "string" and guid ~= "" then
		local lookup = GuildClassLookup()
		local row = type(lookup.byGuid) == "table" and lookup.byGuid[guid] or nil
		if type(row) == "table"
			and type(row.nameRealm) == "string" and row.nameRealm ~= ""
			and string.lower(row.nameRealm) == string.lower(name)
			and type(row.classFile) == "string" and row.classFile ~= "" then
			classFile = row.classFile
		end
	end
	local GI = SF.GuildInfo
	if GI and type(GI.ColorizeName) == "function" then
		return GI.ColorizeName(name, classFile)
	end
	local C = SF.Consumables
	if C and type(C.ColorizeCharacterName) == "function" then
		return C.ColorizeCharacterName(name, classFile)
	end
	return name
end

local function ClassifyHistoryRow(row)
	if type(row) ~= "table" then
		return nil
	end
	local t = row.type
	-- #457: withdrawals must be explicit before the donation fallback.
	if t == "withdrawal" then
		return "withdrawal"
	end
	local GS = SF.GuildSupplies
	if GS and GS.LEDGER_EVENT and t == GS.LEDGER_EVENT.WITHDRAWAL then
		return "withdrawal"
	end
	if t == "adjustment" or t == "CONSUMABLE_ADJUSTMENT" then
		return "adjustment"
	end
	if t == "donation" or t == "CONSUMABLE_DONATION" then
		return "donation"
	end
	-- History projection only emits donation/adjustment/withdrawal rows; prefer
	-- attribution and verification hints when type is unexpectedly missing.
	if row.attributed ~= nil or row.displayAttributed ~= nil then
		return "adjustment"
	end
	if type(row.verification) == "string" then
		return "donation"
	end
	local qty = tonumber(row.quantity)
	if qty and qty < 0 then
		return "adjustment"
	end
	return "donation"
end

local function GoalRowIcon(described)
	if type(described) == "table" then
		local icon = described.icon
		if icon ~= nil and icon ~= false and icon ~= "" then
			return icon
		end
	end
	local display = SF.ItemDisplay
	if display and display.QUESTION_MARK then
		return display.QUESTION_MARK
	end
	return nil
end

local function FormatItemCell(itemId)
	local described = DescribeItem(itemId)
	local name = described.name or Loc("GUILD_SUPPLIES_ITEM_UNKNOWN", "Unknown item")
	local g = GS()
	if g and g.FormatHistoryInlineIcon then
		local markup = g.FormatHistoryInlineIcon(GoalRowIcon(described))
		if type(markup) == "string" and markup ~= "" then
			return markup .. " " .. name
		end
	end
	return name
end

local function BuildProjectedRows()
	SyncFilterContext()
	local key = FilterContextKey()
	if cachedProjectedRows and cachedProjectionKey == key then
		return cachedProjectedRows
	end
	-- Own a render pass only when called outside Page Build/Refresh (tests).
	-- Nested BeginRenderPass would wipe the page's Caps/record cache mid-refresh.
	local ownedPass = false
	if not passCache then
		BeginRenderPass()
		ownedPass = true
	end
	local function finish(rows)
		cachedProjectedRows = rows
		cachedProjectionKey = key
		if ownedPass then
			EndRenderPass()
		end
		return rows
	end
	local rows = {}
	if not Caps().canRead then
		return finish(rows)
	end
	local campaignId = ActiveCampaignId()
	local g = GS()
	if not campaignId or not g or not g.ListCampaignHistory then
		return finish(rows)
	end
	-- No limit: every retained current-campaign entry must remain reachable (#453).
	local history = g:ListCampaignHistory(campaignId, nil, 0, ItemNameForHistory)
	if type(history) ~= "table" then
		return finish(rows)
	end
	local unassigned = Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
	local adjustPrefix = Loc("GUILD_SUPPLIES_LOGS_ADJUST_MARK", "Adjustment")
	local withdrawPrefix = Loc("GUILD_SUPPLIES_LOGS_WITHDRAW_MARK", "Withdrawal")
	-- Warm the pass-scoped guild class lookup once before coloring rows.
	GuildClassLookup()
	for i = 1, #history do
		local event = history[i]
		local kind = ClassifyHistoryRow(event)
		local contributorName
		local contributorGuid
		local quantityText
		if kind == "adjustment" then
			local credited = event.displayAttributed or event.attributed
			if type(credited) == "string" and credited ~= "" then
				contributorName = credited
				contributorGuid = event.attributedGuid
			else
				contributorName = unassigned
				contributorGuid = nil
			end
			local qty = tonumber(event.quantity) or 0
			quantityText = Loc("GUILD_SUPPLIES_LOGS_QTY_SIGNED", "%+d"):format(qty)
		else
			contributorName = event.displayActor or event.actor
				or Loc("GUILD_SUPPLIES_HISTORY_SOMEONE", "Someone")
			contributorGuid = event.actorGuid or event.donorGuid
			local qty = math.abs(tonumber(event.quantity) or 0)
			quantityText = Loc("GUILD_SUPPLIES_LOGS_QTY_PLAIN", "%d"):format(qty)
		end
		local contributorDisplay = ColorizeContributor(contributorName, contributorGuid)
		if kind == "adjustment" then
			contributorDisplay = Loc("GUILD_SUPPLIES_LOGS_ADJUST_CONTRIBUTOR", "%s · %s")
				:format(adjustPrefix, contributorDisplay)
		elseif kind == "withdrawal" then
			contributorDisplay = Loc("GUILD_SUPPLIES_LOGS_WITHDRAW_CONTRIBUTOR", "%s · %s")
				:format(withdrawPrefix, contributorDisplay)
		end
		local itemId = tonumber(event.itemId)
		local itemText = FormatItemCell(itemId)
		local detail = g.FormatCampaignHistoryDetail
			and g.FormatCampaignHistoryDetail(event, ItemNameForHistory(itemId))
		if kind == "adjustment" then
			local officer = event.actor
			if type(officer) == "string" and officer ~= "" then
				local officerLine = Loc("GUILD_SUPPLIES_LOGS_ADJUST_OFFICER",
					"Adjusted by %s."):format(officer)
				if type(detail) == "string" and detail ~= "" then
					detail = detail .. "\n" .. officerLine
				else
					detail = officerLine
				end
			end
		end
		rows[#rows + 1] = {
			contributor = contributorDisplay,
			contributorKey = contributorName,
			quantity = quantityText,
			item = itemText,
			itemId = itemId,
			tooltip = detail,
			id = event.id,
			kind = kind,
			timestamp = event.timestamp,
		}
	end
	return finish(rows)
end

local function FilteredRows()
	local all = BuildProjectedRows()
	local out = {}
	for i = 1, #all do
		local row = all[i]
		if (filterContributor == FILTER_ALL or row.contributorKey == filterContributor)
			and (filterItemId == FILTER_ALL or row.itemId == filterItemId) then
			out[#out + 1] = row
		end
	end
	return out
end

local function ContributorFilterOptions()
	SyncFilterContext()
	local opts = {
		{
			value = FILTER_ALL,
			label = Loc("GUILD_SUPPLIES_LOGS_FILTER_ALL_CONTRIBUTORS", "All contributors"),
		},
	}
	if not Caps().canRead then
		return opts
	end
	local seen = {}
	local names = {}
	local rows = BuildProjectedRows()
	for i = 1, #rows do
		local key = rows[i].contributorKey
		if type(key) == "string" and key ~= "" and not seen[key] then
			seen[key] = true
			names[#names + 1] = key
		end
	end
	table.sort(names)
	for i = 1, #names do
		opts[#opts + 1] = { value = names[i], label = names[i] }
	end
	return opts
end

local function ItemFilterOptions()
	SyncFilterContext()
	local opts = {
		{
			value = FILTER_ALL,
			label = Loc("GUILD_SUPPLIES_LOGS_FILTER_ALL_ITEMS", "All items"),
		},
	}
	if not Caps().canRead then
		return opts
	end
	local seen = {}
	local items = {}
	local rows = BuildProjectedRows()
	for i = 1, #rows do
		local itemId = tonumber(rows[i].itemId)
		if itemId and not seen[itemId] then
			seen[itemId] = true
			items[#items + 1] = itemId
		end
	end
	table.sort(items)
	-- Distinct IDs can share a display name or unresolved placeholder; keep the
	-- filter value as itemId and disambiguate via localized ID tooltip (#453).
	local nameCounts = {}
	local labels = {}
	for i = 1, #items do
		local itemId = items[i]
		local described = DescribeItem(itemId)
		local name = described.name
		if type(name) ~= "string" or name == "" then
			name = Loc("GUILD_SUPPLIES_ITEM_UNKNOWN", "Unknown item")
		end
		labels[itemId] = name
		nameCounts[name] = (nameCounts[name] or 0) + 1
	end
	for i = 1, #items do
		local itemId = items[i]
		local name = labels[itemId]
		local label = name
		if nameCounts[name] > 1 then
			label = Loc("GUILD_SUPPLIES_LOGS_FILTER_ITEM_LABEL_ID", "%s (%d)")
				:format(name, itemId)
		end
		opts[#opts + 1] = {
			value = itemId,
			label = label,
			tooltip = Loc("GUILD_SUPPLIES_LOGS_FILTER_ITEM_ID_TIP", "Item ID: %d")
				:format(itemId),
		}
	end
	return opts
end

local function EmptyLogsText()
	if not Caps().canRead then
		return Loc("GUILD_SUPPLIES_LOGS_NO_READ",
			"Join a guild with a verified membership to inspect Guild Supplies logs.")
	end
	if not ActiveCampaignId() then
		return Loc("GUILD_SUPPLIES_LOGS_EMPTY_NO_CAMPAIGN",
			"No current campaign is available yet.")
	end
	local all = BuildProjectedRows()
	if #all == 0 then
		return Loc("GUILD_SUPPLIES_LOGS_EMPTY_HISTORY",
			"No donations or adjustments are recorded for the current campaign yet.")
	end
	return Loc("GUILD_SUPPLIES_LOGS_EMPTY_FILTERED",
		"No logs match the selected contributor and item filters.")
end

local function Definition()
	return {
		sections = {
			{
				id = "gsLogsTable",
				title = Loc("GUILD_SUPPLIES_LOGS_TITLE", "Campaign history"),
				fillHeight = true,
				items = {
					{
						type = "inlineControls",
						spacing = 10,
						items = {
							{
								type = "dropdown",
								tooltip = Loc("GUILD_SUPPLIES_LOGS_FILTER_CONTRIBUTOR_TIP",
									"Show only entries for one contributor. Applies together with the item filter."),
								defaultText = Loc("GUILD_SUPPLIES_LOGS_FILTER_ALL_CONTRIBUTORS", "All contributors"),
								width = 200,
								options = ContributorFilterOptions,
								get = function()
									SyncFilterContext()
									return filterContributor
								end,
								set = function(value)
									SyncFilterContext()
									filterContributor = value
								end,
								enabled = function()
									return Caps().canRead
								end,
								onValueChanged = function()
									if Page.Refresh and Page.panel then
										Page:Refresh(Page.panel)
									end
								end,
							},
							{
								type = "dropdown",
								tooltip = Loc("GUILD_SUPPLIES_LOGS_FILTER_ITEM_TIP",
									"Show only entries for one item, including items later removed from Requested Items."),
								defaultText = Loc("GUILD_SUPPLIES_LOGS_FILTER_ALL_ITEMS", "All items"),
								width = 200,
								options = ItemFilterOptions,
								get = function()
									SyncFilterContext()
									return filterItemId
								end,
								set = function(value)
									SyncFilterContext()
									filterItemId = value
								end,
								enabled = function()
									return Caps().canRead
								end,
								onValueChanged = function()
									if Page.Refresh and Page.panel then
										Page:Refresh(Page.panel)
									end
								end,
							},
							{
								type = "button",
								buttonText = Loc("GUILD_SUPPLIES_LOGS_FILTER_CLEAR", "Clear"),
								tooltip = Loc("GUILD_SUPPLIES_LOGS_FILTER_CLEAR_TIP",
									"Clear contributor and item filters."),
								width = 90,
								onClick = function()
									SyncFilterContext()
									filterContributor = FILTER_ALL
									filterItemId = FILTER_ALL
									if Page.Refresh and Page.panel then
										Page:Refresh(Page.panel)
									end
								end,
							},
						},
					},
					{
						type = "logTable",
						fillHeight = true,
						minHeight = 280,
						rowHeight = 22,
						virtualize = true,
						columns = {
							{
								key = "contributor",
								label = Loc("GUILD_SUPPLIES_LOGS_COL_CONTRIBUTOR", "Contributor"),
								width = 200,
							},
							{
								key = "quantity",
								label = Loc("GUILD_SUPPLIES_LOGS_COL_QUANTITY", "Quantity"),
								width = 90,
								justifyH = "RIGHT",
							},
							{
								key = "item",
								label = Loc("GUILD_SUPPLIES_LOGS_COL_ITEM", "Item"),
							},
						},
						emptyText = EmptyLogsText,
						getScrollContextKey = ScrollContextKey,
						getRows = function()
							if not Caps().canRead then
								return {}
							end
							return FilteredRows()
						end,
					},
				},
			},
		},
	}
end

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

local function MaybeStartValuationCatchup(panel)
	if not PanelVisible(panel) then
		return
	end
	local supplies = GS()
	if supplies and supplies.StartValuationCatchup then
		supplies.StartValuationCatchup("logs-show")
	end
end

local function CancelValuationCatchup()
	local supplies = GS()
	if supplies and supplies.CancelValuationCatchup then
		supplies.CancelValuationCatchup("logs-hide")
	end
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
	display.RegisterRefresh("guildSuppliesLogs", function()
		cachedProjectedRows = nil
		cachedProjectionKey = nil
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
		cachedProjectedRows = nil
		cachedProjectionKey = nil
		QueueRefresh()
	end)
end

local durableListenerRegistered = false
local function EnsureDurableListener()
	if durableListenerRegistered then
		return
	end
	local supplies = SF.GuildSupplies
	if not supplies or type(supplies.RegisterUIListener) ~= "function" then
		return
	end
	supplies.RegisterUIListener(function()
		cachedProjectedRows = nil
		cachedProjectionKey = nil
		QueueRefresh()
	end)
	durableListenerRegistered = true
end

function Page:Build(panel)
	EnsureRosterListener()
	EnsureDurableListener()
	EnsureItemDisplayListener()
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if not renderer or not renderer.Build then
		self.panel = panel
		return
	end
	BeginRenderPass()
	SyncFilterContext()
	cachedProjectedRows = nil
	renderer:Build(panel, Definition())
	EndRenderPass()
	self.panel = panel
	if panel.HookScript and not panel.__sfGuildSuppliesLogsHook then
		panel.__sfGuildSuppliesLogsHook = true
		panel:HookScript("OnShow", function()
			QueueRefresh()
			MaybeStartValuationCatchup(panel)
		end)
		panel:HookScript("OnHide", function()
			CancelValuationCatchup()
		end)
	end
	MaybeStartValuationCatchup(panel)
end

function Page:Refresh(panel)
	panel = panel or self.panel
	if not PanelVisible(panel) then
		return
	end
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if renderer and renderer.Refresh then
		BeginRenderPass()
		SyncFilterContext()
		-- Rebuild projection when refresh is requested; durable hooks clear the cache.
		renderer:Refresh(panel)
		EndRenderPass()
	end
end

function Page:OnHide()
	refreshQueued = false
	cachedProjectedRows = nil
	cachedProjectionKey = nil
	CancelValuationCatchup()
end

-- Test hooks for behavioral coverage (#453).
Page.__sfTest = {
	ActiveCampaignId = function()
		return ActiveCampaignId()
	end,
	BuildProjectedRows = function()
		cachedProjectedRows = nil
		cachedProjectionKey = nil
		return BuildProjectedRows()
	end,
	FilteredRows = function()
		return FilteredRows()
	end,
	SetFilters = function(contributor, itemId)
		SyncFilterContext()
		filterContributor = contributor == nil and FILTER_ALL or contributor
		filterItemId = itemId == nil and FILTER_ALL or itemId
	end,
	ClearFilters = function()
		SyncFilterContext()
		filterContributor = FILTER_ALL
		filterItemId = FILTER_ALL
	end,
	FilterAll = FILTER_ALL,
	SyncFilterContext = SyncFilterContext,
	ClassifyHistoryRow = ClassifyHistoryRow,
	ScrollContextKey = ScrollContextKey,
	EmptyLogsText = EmptyLogsText,
	ItemFilterOptions = ItemFilterOptions,
	--- Project rows and return (rows, guildInfoGetCurrentRecordCalls) for #453.
	ProjectWithGuildLookupStats = function()
		cachedProjectedRows = nil
		cachedProjectionKey = nil
		BeginRenderPass()
		local rows = BuildProjectedRows()
		local lookup = passCache and passCache.guildClassLookup
		local calls = lookup and tonumber(lookup.getCurrentRecordCalls) or 0
		EndRenderPass()
		return rows, calls
	end,
}

EnsureRosterListener()
EnsureDurableListener()
EnsureItemDisplayListener()

SF.SettingsUI:RegisterPage(Page)
