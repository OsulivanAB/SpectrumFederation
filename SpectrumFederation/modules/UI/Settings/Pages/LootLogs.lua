-- modules/UI/Settings/Pages/LootLogs.lua
local _, SF = ...

local Page = {
	id = "lootLogs",
	name = "Loot Logs",
	order = 30,
	layout = {
		windowWidth = 1350,
		disablePageScroll = true,
	},
}

-- ==================================================================
-- Helpers
-- ==================================================================

-- Get all loot logs from the active profile
-- @return table Array of LootLog objects
local function GetAllLogs()
	local profile = SF:GetActiveProfile()
	if not profile or type(profile.GetLootLogs) ~= "function" then
		return {}
	end
	return profile:GetLootLogs() or {}
end

-- Get unique authors from logs
-- @param logs table Array of LootLog objects
-- @return table Array of {value, label} for dropdown
local function GetUniqueAuthors(logs)
	local authorsSet = {}
	for _, log in ipairs(logs) do
		if type(log.GetAuthor) == "function" then
			local author = log:GetAuthor()
			if author then
				authorsSet[author] = true
			end
		end
	end
	
	local options = {}
	for author in pairs(authorsSet) do
		table.insert(options, { value = author, label = author })
	end
	
	table.sort(options, function(a, b) return a.label < b.label end)
	return options
end

-- Get unique member names from logs
-- @param logs table Array of LootLog objects
-- @return table Array of {value, label} for dropdown
local function GetUniqueMembers(logs)
	local membersSet = {}
	for _, log in ipairs(logs) do
		if type(log.GetEventData) == "function" then
			local data = log:GetEventData()
			if data and data.member then
				membersSet[data.member] = true
			end
		end
	end
	
	local options = {}
	for member in pairs(membersSet) do
		table.insert(options, { value = member, label = member })
	end
	
	table.sort(options, function(a, b) return a.label < b.label end)
	return options
end

-- Get event type options for dropdown
-- @return table Array of {value, label} for dropdown
local function GetEventTypeOptions()
	if not SF.LootLogEventTypes then
		return {}
	end
	
	local options = {}
	for _, eventType in pairs(SF.LootLogEventTypes) do
		table.insert(options, { value = eventType, label = eventType })
	end
	
	table.sort(options, function(a, b) return a.label < b.label end)
	return options
end

local function ToWoWHexColor(color)
	if type(color) == "string" then
		return color
	end
	if type(color) == "table" then
		local r = tonumber(color.r or color[1] or 1) or 1
		local g = tonumber(color.g or color[2] or 1) or 1
		local b = tonumber(color.b or color[3] or 1) or 1
		r = math.min(math.max(r, 0), 1)
		g = math.min(math.max(g, 0), 1)
		b = math.min(math.max(b, 0), 1)
		return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
	end
	return "|cffffffff"
end

local function GetPlayerClassColor(playerName)
	if not playerName or playerName == "Unknown" or playerName == "?" then
		return "|cffffffff"
	end

	local profile = SF:GetActiveProfile()
	if profile and type(profile.GetMemberByID) == "function" then
		local member = profile:GetMemberByID(playerName)
		if member and member.class and SF.WOW_CLASSES and SF.WOW_CLASSES[member.class] then
			return ToWoWHexColor(SF.WOW_CLASSES[member.class].colorCode)
		end
	end

	return "|cffffff00"
end

local EVENT_TYPE_COLORS = {
	PROFILE_CREATION = "|cff00ff00",
	POINT_CHANGE = "|cff00ccff",
	ARMOR_CHANGE = "|cffffa500",
	ROLE_CHANGE = "|cffff00ff",
	POINT_NAME_CHANGE = "|cffffcc00",
	PROFILE_NAME_CHANGE = "|cff00ff00",
	SAFEMODE_CHANGE = "|cffff6600",
	SAFEMODE_ON_COMBAT_CHANGE = "|cffff6600",
	ADMIN_ADDED = "|cff66ff66",
	ADMIN_REMOVED = "|cffff6666",
}

local EVENT_TYPE_LABELS = {
	PROFILE_CREATION = "Profile Creation",
	POINT_CHANGE = "Point Change",
	ARMOR_CHANGE = "Armor Change",
	ROLE_CHANGE = "Role Change",
	POINT_NAME_CHANGE = "Point Name Change",
	PROFILE_NAME_CHANGE = "Profile Name Change",
	SAFEMODE_CHANGE = "Raid Safe Mode",
	SAFEMODE_ON_COMBAT_CHANGE = "Combat Safe Mode",
	ADMIN_ADDED = "Admin Added",
	ADMIN_REMOVED = "Admin Removed",
}

local function GetEventTypeLabel(eventType)
	return EVENT_TYPE_LABELS[eventType] or tostring(eventType or "Unknown")
end

local function ColorizeName(name)
	if not name or name == "" then
		return ""
	end
	local reset = "|r"
	return string.format("%s%s%s", GetPlayerClassColor(name), name, reset)
end

local function BuildActionText(eventType, data, author)
	data = data or {}

	if eventType == "POINT_CHANGE" then
		local isRaidCheck = (data.reason == "RAID_CHECK") or (author == "Raid Check")
		if isRaidCheck and data.change == (SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.INCREMENT) then
			return "Raid Check prepared (+1)"
		elseif isRaidCheck then
			return string.format("Raid Check change (%s)", tostring(data.change or "?"))
		end
		return tostring(data.change or "?")
	elseif eventType == "ARMOR_CHANGE" then
		return tostring(data.action or "")
	elseif eventType == "ROLE_CHANGE" then
		return string.format("Role -> %s", tostring(data.newRole or "?"))
	elseif eventType == "PROFILE_CREATION" then
		return string.format("Created profile %s", tostring(data.profileId or "?"))
	elseif eventType == "POINT_NAME_CHANGE" then
		return string.format("%s -> %s", tostring(data.oldName or "?"), tostring(data.newName or "?"))
	elseif eventType == "PROFILE_NAME_CHANGE" then
		return string.format("%s -> %s", tostring(data.oldName or "?"), tostring(data.newName or "?"))
	elseif eventType == "SAFEMODE_CHANGE" then
		return data.enabled and "Enabled" or "Disabled"
	elseif eventType == "SAFEMODE_ON_COMBAT_CHANGE" then
		return data.enabled and "Enabled" or "Disabled"
	elseif eventType == "ADMIN_ADDED" then
		return "Added as admin"
	elseif eventType == "ADMIN_REMOVED" then
		return "Removed from admins"
	end

	return ""
end

local function BuildLogRow(log)
	if type(log) ~= "table" or type(log.GetTimestamp) ~= "function" then
		return nil
	end

	local timestamp = log:GetTimestamp()
	local author = log:GetAuthor() or "Unknown"
	local eventType = log:GetEventType() or "Unknown"
	local data = type(log.GetEventData) == "function" and (log:GetEventData() or {}) or {}
	local eventColor = EVENT_TYPE_COLORS[eventType] or "|cffffffff"
	local reset = "|r"

	local dateText = type(SF.FormatTimestampForUser) == "function"
		and SF:FormatTimestampForUser(timestamp)
		or tostring(timestamp)

	return {
		date = dateText,
		changeType = string.format("%s%s%s", eventColor, GetEventTypeLabel(eventType), reset),
		author = ColorizeName(author),
		member = ColorizeName(data.member),
		slot = data.slot or "",
		action = BuildActionText(eventType, data, author),
		item = "",
	}
end

-- ==================================================================
-- Page Definition
-- ==================================================================

function Page:Build(panel)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Building LootLogs settings page")
	end

	local renderer = SF.SettingsUI.DefinitionRenderer
	local store = SF.SettingsStore

	-- UI state (not persisted)
	panel.__sfSelectedEventType = panel.__sfSelectedEventType or nil
	panel.__sfSelectedAuthor = panel.__sfSelectedAuthor or nil
	panel.__sfSelectedMember = panel.__sfSelectedMember or nil

	local function GetFilteredLogs()
		local logs = GetAllLogs()
		local filtered = {}
		
		for _, log in ipairs(logs) do
			-- Safety check: ensure log is a valid object with required methods
			if type(log) == "table" and 
			   type(log.GetEventType) == "function" and
			   type(log.GetAuthor) == "function" and
			   type(log.GetTimestamp) == "function" then
				
				local include = true
				
				-- Filter by event type
				if panel.__sfSelectedEventType and log:GetEventType() ~= panel.__sfSelectedEventType then
					include = false
				end
				
				-- Filter by author
				if panel.__sfSelectedAuthor and log:GetAuthor() ~= panel.__sfSelectedAuthor then
					include = false
				end
				
				-- Filter by member
				if panel.__sfSelectedMember then
					local data = type(log.GetEventData) == "function" and log:GetEventData()
					if not data or data.member ~= panel.__sfSelectedMember then
						include = false
					end
				end
				
				if include then
					table.insert(filtered, log)
				end
			else
				-- Skip malformed log entry
				if SF.Debug then
					SF.Debug:Warn("LOOTLOGS", "Skipping malformed log entry")
				end
			end
		end
		
		-- Sort by timestamp (newest first)
		table.sort(filtered, function(a, b)
			local aTime = type(a.GetTimestamp) == "function" and a:GetTimestamp() or 0
			local bTime = type(b.GetTimestamp) == "function" and b:GetTimestamp() or 0
			return aTime > bTime
		end)
		
		return filtered
	end

	local function BuildLogRows()
		local rows = {}
		for _, log in ipairs(GetFilteredLogs()) do
			local row = BuildLogRow(log)
			if row then
				table.insert(rows, row)
			end
		end
		return rows
	end

	local def = {
		sections = {
			{
				id = "logs",
				title = "Loot Logs",
				tooltip = "Audit trail for Loot Helper profile changes, session actions, and admin updates.",
				fillHeight = true,
				items = {
					{
						type = "inlineControls",
						spacing = 10,
						items = {
							{
								type = "dropdown",
								tooltip = "Filter logs by event type",
								defaultText = "All Types",
								width = 190,
								options = function()
									return GetEventTypeOptions()
								end,
								get = function()
									return panel.__sfSelectedEventType
								end,
								set = function(value)
									panel.__sfSelectedEventType = value
								end,
								onValueChanged = function()
									if panel.__sfPageBuilder then
										panel.__sfPageBuilder:Refresh()
									end
								end,
							},
							{
								type = "dropdown",
								tooltip = "Filter logs by author (who created the log)",
								defaultText = "All Authors",
								width = 190,
								options = function()
									return GetUniqueAuthors(GetAllLogs())
								end,
								get = function()
									return panel.__sfSelectedAuthor
								end,
								set = function(value)
									panel.__sfSelectedAuthor = value
								end,
								onValueChanged = function()
									if panel.__sfPageBuilder then
										panel.__sfPageBuilder:Refresh()
									end
								end,
							},
							{
								type = "dropdown",
								tooltip = "Filter logs by member name when the event includes a member",
								defaultText = "All Members",
								width = 190,
								options = function()
									return GetUniqueMembers(GetAllLogs())
								end,
								get = function()
									return panel.__sfSelectedMember
								end,
								set = function(value)
									panel.__sfSelectedMember = value
								end,
								onValueChanged = function()
									if panel.__sfPageBuilder then
										panel.__sfPageBuilder:Refresh()
									end
								end,
							},
							{
								type = "button",
								buttonText = "Clear",
								tooltip = "Clear all Loot Log filters",
								width = 100,
								onClick = function()
									panel.__sfSelectedEventType = nil
									panel.__sfSelectedAuthor = nil
									panel.__sfSelectedMember = nil
									if panel.__sfPageBuilder then
										panel.__sfPageBuilder:Refresh()
									end
								end,
							},
						},
					},
					{
						type = "logTable",
						fillHeight = true,
						minHeight = 320,
						rowHeight = 22,
						columns = {
							{ key = "date", label = "Date", width = 170 },
							{ key = "changeType", label = "Type of Change", width = 170 },
							{ key = "member", label = "Member", width = 135 },
							{ key = "slot", label = "Slot", width = 90 },
							{ key = "action", label = "Action", width = 240 },
							{ key = "item", label = "Item", width = 120 },
							{ key = "author", label = "Author" },
						},
						emptyText = "No logs found matching the selected filters.\n\nCreate a profile and perform actions to see logs here.",
						getRows = function()
							return BuildLogRows()
						end,
					},
				},
			},
		},
	}

	renderer:Build(panel, def)
end

function Page:Refresh(panel)
	SF.SettingsUI.DefinitionRenderer:Refresh(panel)
end

SF.SettingsUI:RegisterPage(Page)
