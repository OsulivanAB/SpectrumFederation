-- Guild Supplies → Logs (#386). Member-readable goals/progress and campaign inspection.
-- No privileged mutation controls. Live verification remains #388/#389.
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
	contentHeading = Loc("GUILD_SUPPLIES_LOGS_HEADING", "Guild Supplies Logs"),
	group = "Loot Tools",
	description = Loc("GUILD_SUPPLIES_LOGS_DESC",
		"Inspect current and archived campaign goals, progress, and history."),
	order = 19.2,
}

local function GS()
	return SF.GuildSupplies
end

-- Ephemeral UI selection / history pagination only; never persisted.
local selectedCampaignId = nil
local historyOffset = 0
local historyCampaignId = nil
local HISTORY_PAGE_SIZE = 25

local function Caps()
	local g = GS()
	if not g or not g.GetCapabilities then
		return { canRead = false, reason = "not_ready" }
	end
	return g:GetCapabilities()
end

local function FormatCampaignLabel(entry)
	if type(entry) ~= "table" then
		return "?"
	end
	local started = tonumber(entry.startedAt)
	local when = started and date and date("%Y-%m-%d %H:%M", started) or tostring(entry.startedAt or "?")
	local status = entry.isCurrent
		and Loc("GUILD_SUPPLIES_CAMPAIGN_CURRENT", "Current")
		or Loc("GUILD_SUPPLIES_CAMPAIGN_ARCHIVED", "Archived")
	local shortId = tostring(entry.campaignId or "")
	if #shortId > 24 then
		shortId = shortId:sub(1, 21) .. "..."
	end
	return string.format("%s — %s (%s)", when, status, shortId)
end

local function CampaignOptions()
	local g = GS()
	local opts = {}
	if not g or not g.ListInspectableCampaigns then
		return opts
	end
	local list = g:ListInspectableCampaigns()
	if type(list) ~= "table" then
		return opts
	end
	for i = 1, #list do
		local entry = list[i]
		opts[#opts + 1] = {
			value = entry.campaignId,
			label = FormatCampaignLabel(entry),
		}
	end
	return opts
end

local function ResolveSelectedCampaign()
	local g = GS()
	local record = g and select(1, g:GetCurrentRecord()) or nil
	if not record then
		selectedCampaignId = nil
		return nil
	end
	local list = g:ListInspectableCampaigns()
	if type(list) ~= "table" or #list == 0 then
		selectedCampaignId = nil
		return nil
	end
	if selectedCampaignId then
		for i = 1, #list do
			if list[i].campaignId == selectedCampaignId then
				return selectedCampaignId
			end
		end
	end
	-- Default to current, else newest inspectable.
	if type(record.currentCampaignId) == "string" then
		selectedCampaignId = record.currentCampaignId
		return selectedCampaignId
	end
	selectedCampaignId = list[1].campaignId
	return selectedCampaignId
end

local function MembershipHelpText()
	local caps = Caps()
	local g = GS()
	local formatReason = g and g.FormatReasonText or function(r)
		return tostring(r or "unknown")
	end
	if caps.canRead then
		return Loc("GUILD_SUPPLIES_LOGS_HELP",
			"Members can inspect current and archived campaign goals and progress. Privileged edits live on Configuration. Live donation verification is not active on this staged branch.")
	end
	return Loc("GUILD_SUPPLIES_LOGS_NO_READ",
		"Join a guild with a verified membership to inspect Guild Supplies logs.")
		.. " (" .. formatReason(caps.reason or "not_ready") .. ")"
end

local function ItemRowsForSelected()
	local g = GS()
	local campaignId = ResolveSelectedCampaign()
	local rows = {}
	if not g or not campaignId then
		return rows
	end
	local items = g:GetCampaignRequestedItems(campaignId)
	local progress = g:ProjectCampaignProgress(campaignId)
	local totals = progress and progress.itemTotals or {}
	if type(items) ~= "table" then
		return rows
	end
	for _, row in pairs(items) do
		if type(row) == "table" and tonumber(row.itemId) then
			local itemId = row.itemId
			local goal = tonumber(row.goal) or 0
			local got = tonumber(totals[itemId]) or 0
			local name = nil
			if C_Item and C_Item.GetItemInfo then
				name = C_Item.GetItemInfo(itemId)
			end
			if type(name) ~= "string" and GetItemInfo then
				name = GetItemInfo(itemId)
			end
			local label = (type(name) == "string" and name ~= "" and name)
				or Loc("GUILD_SUPPLIES_ITEM_FALLBACK", "item %s"):format(tostring(itemId))
			rows[#rows + 1] = {
				text = string.format("%s — %d / %s", label, got, goal > 0 and tostring(goal) or "—"),
				itemId = itemId,
				goal = goal,
				progress = got,
			}
		end
	end
	table.sort(rows, function(a, b)
		return (a.itemId or 0) < (b.itemId or 0)
	end)
	return rows
end

local function ItemNameForHistory(itemId)
	local name = nil
	if C_Item and C_Item.GetItemInfo then
		name = C_Item.GetItemInfo(itemId)
	end
	if type(name) ~= "string" and GetItemInfo then
		name = GetItemInfo(itemId)
	end
	if type(name) == "string" and name ~= "" then
		return name
	end
	return nil
end

local function HistoryRowsForSelected()
	local g = GS()
	local campaignId = ResolveSelectedCampaign()
	if not g or not campaignId or not g.ListCampaignHistory then
		Page.historyTotal = 0
		return {}
	end
	if campaignId ~= historyCampaignId then
		historyCampaignId = campaignId
		historyOffset = 0
	end
	local rows, total = g:ListCampaignHistory(campaignId, HISTORY_PAGE_SIZE, historyOffset, ItemNameForHistory)
	total = tonumber(total) or (rows and #rows) or 0
	if historyOffset > 0 and historyOffset >= total then
		historyOffset = 0
		rows, total = g:ListCampaignHistory(campaignId, HISTORY_PAGE_SIZE, 0, ItemNameForHistory)
		total = tonumber(total) or (rows and #rows) or 0
	end
	Page.historyTotal = total
	local items = {}
	if type(rows) == "table" then
		for i = 1, #rows do
			items[#items + 1] = { text = rows[i].text, canRemove = false }
		end
	end
	return items
end

local function ShiftHistory(delta)
	local total = Page.historyTotal or 0
	local nextOffset = historyOffset + (delta * HISTORY_PAGE_SIZE)
	if nextOffset < 0 then nextOffset = 0 end
	if nextOffset > 0 and nextOffset >= total then return end
	historyOffset = nextOffset
	if Page.Refresh and Page.panel then
		Page:Refresh(Page.panel)
	end
end

local function HistoryHelpText()
	return Loc("GUILD_SUPPLIES_LOGS_HISTORY_HELP",
		"Newest donation and adjustment entries for the selected campaign are first. Each page shows up to %d entries. Live bank verification is not active on this staged branch.")
		:format(HISTORY_PAGE_SIZE)
end

local function Definition()
	return {
		sections = {
			{
				id = "gsLogsStatus",
				title = Loc("GUILD_SUPPLIES_LOGS_TITLE", "Campaign inspection"),
				items = {
					{
						type = "help",
						indent = "label",
						getText = MembershipHelpText,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_SUPPLIES_CAMPAIGN_SELECT", "Campaign"),
						defaultText = Loc("GUILD_SUPPLIES_CAMPAIGN_NONE", "No campaigns"),
						options = function()
							return CampaignOptions()
						end,
						get = function()
							return ResolveSelectedCampaign()
						end,
						set = function(value)
							selectedCampaignId = value
							historyOffset = 0
							historyCampaignId = value
						end,
						enabled = function()
							return Caps().canRead and #CampaignOptions() > 0
						end,
						onValueChanged = function(ctx)
							historyOffset = 0
							if ctx.pageBuilder and ctx.pageBuilder.Refresh then
								ctx.pageBuilder:Refresh()
							end
						end,
					},
					{
						type = "display",
						label = Loc("GUILD_SUPPLIES_CAMPAIGN_DETAIL", "Selection"),
						get = function()
							local id = ResolveSelectedCampaign()
							if not id then
								return Loc("GUILD_SUPPLIES_CAMPAIGN_NONE", "No campaigns")
							end
							local g = GS()
							local list = g and g:ListInspectableCampaigns() or {}
							for i = 1, #list do
								if list[i].campaignId == id then
									return FormatCampaignLabel(list[i])
								end
							end
							return id
						end,
					},
					{
						type = "scrollList",
						label = Loc("GUILD_SUPPLIES_LOGS_ITEMS", "Goals and progress"),
						height = 160,
						rowHeight = 20,
						getItems = function()
							if not Caps().canRead then
								return {}
							end
							return ItemRowsForSelected()
						end,
						enabled = function()
							return Caps().canRead
						end,
					},
					{
						type = "help",
						indent = "label",
						getText = HistoryHelpText,
					},
					{
						type = "button",
						label = Loc("GUILD_SUPPLIES_LOGS_HISTORY_PREV", "Newer"),
						buttonText = Loc("GUILD_SUPPLIES_LOGS_HISTORY_PREV", "Newer"),
						width = 90,
						enabled = function()
							return Caps().canRead and historyOffset > 0
						end,
						onClick = function()
							ShiftHistory(-1)
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_SUPPLIES_LOGS_HISTORY_NEXT", "Older"),
						buttonText = Loc("GUILD_SUPPLIES_LOGS_HISTORY_NEXT", "Older"),
						width = 90,
						enabled = function()
							return Caps().canRead
								and historyOffset + HISTORY_PAGE_SIZE < (Page.historyTotal or 0)
						end,
						onClick = function()
							ShiftHistory(1)
						end,
					},
					{
						type = "scrollList",
						label = Loc("GUILD_SUPPLIES_LOGS_HISTORY", "Campaign history"),
						height = 180,
						rowHeight = 20,
						getItems = function()
							if not Caps().canRead then
								return {}
							end
							return HistoryRowsForSelected()
						end,
						enabled = function()
							return Caps().canRead
						end,
					},
					{
						type = "help",
						indent = "label",
						text = Loc("GUILD_SUPPLIES_LOGS_EMPTY_NOTE",
							"A New Campaign starts with zero progress. Archived campaigns keep their own configuration and history."),
					},
				},
			},
			{
				id = "gsLogsPersonal",
				title = Loc("GUILD_SUPPLIES_PERSONAL_TITLE", "Personal preferences"),
				items = {
					{
						type = "checkbox",
						label = Loc("GUILD_SUPPLIES_REMINDERS", "Show raid supply reminders"),
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

-- Lifecycle: selection is ephemeral; repeated open must not accumulate listeners.
-- PageBuilder owns refresh; this module registers no permanent frames/timers.
function Page:OnHide()
	-- Keep selectedCampaignId for the session; do not grow resources.
end

SF.SettingsUI:RegisterPage(Page)
