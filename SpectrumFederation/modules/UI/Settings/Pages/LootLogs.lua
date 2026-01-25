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

-- Format a log entry for display
-- @param log LootLog Log entry
-- @return string Formatted log text
local function FormatLogEntry(log)
	if type(log.GetTimestamp) ~= "function" then
		return "Invalid log entry"
	end
	
	local timestamp = log:GetTimestamp()
	local author = log:GetAuthor() or "Unknown"
	local eventType = log:GetEventType() or "Unknown"
	local data = log:GetEventData() or {}
	
	local timeStr = type(SF.FormatTimestampForUser) == "function" 
		and SF:FormatTimestampForUser(timestamp) 
		or tostring(timestamp)
	
	local details = ""
	if eventType == "POINT_CHANGE" then
		details = string.format("Member: %s, Change: %s", data.member or "?", data.change or "?")
	elseif eventType == "ARMOR_CHANGE" then
		details = string.format("Member: %s, Slot: %s, Action: %s", 
			data.member or "?", data.slot or "?", data.action or "?")
	elseif eventType == "ROLE_CHANGE" then
		details = string.format("Member: %s, New Role: %s", data.member or "?", data.newRole or "?")
	elseif eventType == "PROFILE_CREATION" then
		details = string.format("Profile ID: %s", data.profileId or "?")
	end
	
	return string.format("[%s] %s by %s - %s", timeStr, eventType, author, details)
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
						label = "Logs",
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
