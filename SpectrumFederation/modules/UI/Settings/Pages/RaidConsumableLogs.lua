-- Read-only Raid Consumable Logs for the active profile.
local _, SF = ...

local Page = {
	id = "lootHelperConsumableLogs",
	parentId = "lootHelper",
	name = "Raid Consumable Logs",
	navLabel = "Consumable Logs",
	description = "Review raid-supply donations, receipts, custody, and configuration clears.",
	order = 23.7,
}

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

local function PageSize()
	return (SF.Consumables and SF.Consumables.MAX_VISIBLE_HISTORY) or 200
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
	for i = 1, #rows do
		items[i] = { text = rows[i].text, canRemove = false }
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
		"Newest entries are first. Each page shows up to %d entries, including custody and configuration clears from every generation. Older pages stay available.",
		limit
	)
end

local function Definition()
	return {
		sections = {
			{
				id = "consumableLogs",
				title = "Raid Consumable Logs",
				items = {
					{ type = "help", indent = "label", text = HistoryHelp() },
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
						height = 360,
						getItems = LogItems,
					},
				},
			},
		},
	}
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
