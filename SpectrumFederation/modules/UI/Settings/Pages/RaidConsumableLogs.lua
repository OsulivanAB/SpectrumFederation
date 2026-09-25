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
	if C_Item and C_Item.GetItemInfo then
		local info = C_Item.GetItemInfo(itemId)
		if type(info) == "table" and type(info.itemName or info.name) == "string" then
			return info.itemName or info.name
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

local function LogItems()
	local C = SF.Consumables
	local profile = SF.GetActiveProfile and SF:GetActiveProfile() or nil
	if not C or not profile or not C.HistoryRows then
		return {}
	end
	local rows = C.HistoryRows(profile, ItemName)
	local items = {}
	for i = 1, #rows do
		items[i] = { text = rows[i].text, canRemove = false }
	end
	return items
end

local function Definition()
	return {
		sections = {
			{
				id = "consumableLogs",
				title = "Raid Consumable Logs",
				items = {
					{ type = "help", indent = "label", text = "Newest entries are first. This list is read-only and includes every generation. Clearing the configuration keeps these entries." },
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
