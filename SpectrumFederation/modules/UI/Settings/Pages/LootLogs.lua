-- modules/UI/Settings/Pages/LootLogs.lua
local _, SF = ...

local Page = {
	id = "lootLogs",
	parentId = "main",
	name = "Loot Logs",
	order = 30,
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

-- Format a log entry for display with color coding
-- @param log LootLog Log entry
-- @return string Formatted log text
local function FormatLogEntry(log)
	if type(log.GetTimestamp) ~= "function" then
		return "Invalid log entry"
	end
	
	-- Helper function to convert RGB color table to WoW hex color
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
	
	-- Get class color for a player name
	local function GetPlayerClassColor(playerName)
		if not playerName or playerName == "Unknown" or playerName == "?" then
			return "|cffffffff"  -- White for unknown
		end
		
		-- Try to get member from active profile
		local profile = SF:GetActiveProfile()
		if profile and type(profile.GetMemberByID) == "function" then
			local member = profile:GetMemberByID(playerName)
			if member and member.class and SF.WOW_CLASSES and SF.WOW_CLASSES[member.class] then
				return ToWoWHexColor(SF.WOW_CLASSES[member.class].colorCode)
			end
		end
		
		return "|cffffff00"  -- Yellow as fallback
	end
	
	-- Define colors
	local EVENT_TYPE_COLORS = {
		PROFILE_CREATION           = "|cff00ff00",  -- Green
		POINT_CHANGE               = "|cff00ccff",  -- Cyan
		ARMOR_CHANGE               = "|cffffa500",  -- Orange
		ROLE_CHANGE                = "|cffff00ff",  -- Magenta
		POINT_NAME_CHANGE          = "|cffffcc00",  -- Gold
		PROFILE_NAME_CHANGE        = "|cff00ff00",  -- Green
		SAFEMODE_CHANGE            = "|cffff6600",  -- Red-Orange
		SAFEMODE_ON_COMBAT_CHANGE  = "|cffff6600",  -- Red-Orange
		ADMIN_ADDED                = "|cff66ff66",  -- Light Green
		ADMIN_REMOVED              = "|cffff6666",  -- Light Red
	}
	local TIMESTAMP_COLOR = "|cffffffff"  -- White
	local RESET = "|r"
	
	local timestamp = log:GetTimestamp()
	local author = log:GetAuthor() or "Unknown"
	local eventType = log:GetEventType() or "Unknown"
	local data = log:GetEventData() or {}
	
	local timeStr = type(SF.FormatTimestampForUser) == "function" 
		and SF:FormatTimestampForUser(timestamp) 
		or tostring(timestamp)
	
	local eventTypeColor = EVENT_TYPE_COLORS[eventType] or "|cffffffff"
	local authorColor = GetPlayerClassColor(author)
	
	local details = ""
	if eventType == "POINT_CHANGE" then
		local memberColor = GetPlayerClassColor(data.member)
		details = string.format("Member: %s%s%s, Change: %s", 
			memberColor, data.member or "?", RESET, data.change or "?")
	elseif eventType == "ARMOR_CHANGE" then
		local memberColor = GetPlayerClassColor(data.member)
		details = string.format("Member: %s%s%s, Slot: %s, Action: %s", 
			memberColor, data.member or "?", RESET, data.slot or "?", data.action or "?")
	elseif eventType == "ROLE_CHANGE" then
		local memberColor = GetPlayerClassColor(data.member)
		details = string.format("Member: %s%s%s, New Role: %s", 
			memberColor, data.member or "?", RESET, data.newRole or "?")
	elseif eventType == "PROFILE_CREATION" then
		details = string.format("Profile ID: %s", data.profileId or "?")
	elseif eventType == "POINT_NAME_CHANGE" then
		details = string.format("Changed from '%s' to '%s'", 
			data.oldName or "?", data.newName or "?")
	elseif eventType == "PROFILE_NAME_CHANGE" then
		details = string.format("Renamed from '%s' to '%s'", 
			data.oldName or "?", data.newName or "?")
	elseif eventType == "SAFEMODE_CHANGE" then
		local status = data.enabled and "Enabled" or "Disabled"
		details = string.format("Raid-wide Safemode: %s", status)
	elseif eventType == "SAFEMODE_ON_COMBAT_CHANGE" then
		local status = data.enabled and "Enabled" or "Disabled"
		details = string.format("Safemode on Combat: %s", status)
	elseif eventType == "ADMIN_ADDED" then
		local memberColor = GetPlayerClassColor(data.member)
		details = string.format("Added %s%s%s as admin", 
			memberColor, data.member or "?", RESET)
	elseif eventType == "ADMIN_REMOVED" then
		local memberColor = GetPlayerClassColor(data.member)
		details = string.format("Removed %s%s%s from admins", 
			memberColor, data.member or "?", RESET)
	end
	
	return string.format("%s[%s]%s %s%s%s by %s%s%s - %s", 
		TIMESTAMP_COLOR, timeStr, RESET,
		eventTypeColor, eventType, RESET,
		authorColor, author, RESET,
		details)
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

	local function BuildLogText()
		local logs = GetFilteredLogs()
		
		if #logs == 0 then
			return "No logs found matching the selected filters.\n\nCreate a profile and perform actions to see logs here."
		end
		
		local lines = {}
		table.insert(lines, string.format("Showing %d log(s):\n", #logs))
		
		for i, log in ipairs(logs) do
			table.insert(lines, FormatLogEntry(log))
		end
		
		return table.concat(lines, "\n")
	end

	local def = {
		sections = {
			{
				id = "filters",
				title = "Filters",
				items = {
					{
						type = "dropdown",
						label = "Log Type",
						tooltip = "Filter logs by event type",
						defaultText = "All Types",
						options = function()
							return GetEventTypeOptions()
						end,
						get = function()
							return panel.__sfSelectedEventType
						end,
						set = function(value)
							panel.__sfSelectedEventType = value
						end,
						onValueChanged = function(ctx)
							ctx.pageBuilder:Refresh()
						end,
					},
					
					{
						type = "dropdown",
						label = "Author",
						tooltip = "Filter logs by author (who created the log)",
						defaultText = "All Authors",
						options = function()
							return GetUniqueAuthors(GetAllLogs())
						end,
						get = function()
							return panel.__sfSelectedAuthor
						end,
						set = function(value)
							panel.__sfSelectedAuthor = value
						end,
						onValueChanged = function(ctx)
							ctx.pageBuilder:Refresh()
						end,
					},
					
					{
						type = "dropdown",
						label = "Member",
						tooltip = "Filter logs by member name (may not apply to all log types)",
						defaultText = "All Members",
						options = function()
							return GetUniqueMembers(GetAllLogs())
						end,
						get = function()
							return panel.__sfSelectedMember
						end,
						set = function(value)
							panel.__sfSelectedMember = value
						end,
						onValueChanged = function(ctx)
							ctx.pageBuilder:Refresh()
						end,
					},
					
					{
						type = "button",
						label = "Clear Filters",
						buttonText = "Clear",
						width = 100,
						onClick = function(ctx)
							panel.__sfSelectedEventType = nil
							panel.__sfSelectedAuthor = nil
							panel.__sfSelectedMember = nil
							ctx.pageBuilder:Refresh()
						end,
					},
				},
			},
			
			{
				id = "logs",
				title = "Log Entries",
				items = {
					{
						type = "scrollableText",
						label = "",
						height = 300,
						get = function()
							return BuildLogText()
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
