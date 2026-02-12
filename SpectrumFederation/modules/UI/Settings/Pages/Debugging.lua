-- modules/UI/Settings/Pages/Debugging.lua
local _, SF = ...

local Page = {
	id = "debugging",
	name = "Debugging",
	order = 40,
}

-- ==================================================================
-- Helpers
-- ==================================================================

-- Get debug logs filtered by enabled log levels
-- @param enabledLevels table Set of enabled log level names
-- @return table Array of log entries
local function GetFilteredDebugLogs(enabledLevels)
	if not SF.debugDB or not SF.debugDB.logs then
		return {}
	end
	
	local logs = SF.debugDB.logs
	local filtered = {}
	
	for _, log in ipairs(logs) do
		-- Explicitly check if level is enabled (true), not just if key exists
		if enabledLevels[log.level] == true then
			table.insert(filtered, log)
		end
	end
	
	return filtered
end

-- Format debug logs as copyable text with color coding
-- @param logs table Array of log entries
-- @return string Formatted log text
local function FormatDebugLogsText(logs)
	if #logs == 0 then
		return "No debug logs available.\n\nEnable debugging and perform actions to see logs here."
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
	
	-- Define colors for log levels
	local LEVEL_COLORS = {
		VERBOSE = "|cff888888",  -- Gray
		INFO    = "|cff00ccff",  -- Cyan
		WARN    = "|cffffa500",  -- Orange
		ERROR   = "|cffff0000",  -- Red
	}
	local TIMESTAMP_COLOR = "|cffffffff"  -- White
	local CATEGORY_COLOR = "|cffffff00"   -- Yellow
	local RESET = "|r"
	
	local lines = {}
	table.insert(lines, string.format("Showing %d log(s):\n", #logs))
	
	for _, log in ipairs(logs) do
		local timestamp = type(SF.FormatTimestampForUser) == "function" 
			and SF:FormatTimestampForUser(log.timestamp) 
			or tostring(log.timestamp)
		
		local levelColor = LEVEL_COLORS[log.level] or "|cffffffff"
		
		table.insert(lines, string.format("%s[%s]%s %s[%s]%s %s%s:%s %s", 
			TIMESTAMP_COLOR, timestamp, RESET,
			levelColor, log.level, RESET,
			CATEGORY_COLOR, log.category, RESET,
			log.message))
	end
	
	return table.concat(lines, "\n")
end

-- ==================================================================
-- Page Definition
-- ==================================================================

function Page:Build(panel)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Building Debugging settings page")
	end

	local renderer = SF.SettingsUI.DefinitionRenderer
	local store = SF.SettingsStore

	-- UI state (not persisted) - track which log levels are enabled for display
	panel.__sfLogLevels = panel.__sfLogLevels or {
		VERBOSE = true,
		INFO = true,
		WARN = true,
		ERROR = true,
	}

	local function GetDebugLogsText()
		return FormatDebugLogsText(GetFilteredDebugLogs(panel.__sfLogLevels))
	end

	local def = {
		sections = {
			{
				id = "controls",
				title = "Debug Controls",
				items = {
					{
						type = "display",
						label = "Debug Status",
						get = function()
							if SF.Debug and SF.Debug:IsEnabled() then
								return "|cff00ff00Enabled|r"
							else
								return "|cffff0000Disabled|r"
							end
						end,
					},
					
					{
						type = "button",
						label = "Start Debugging",
						buttonText = "Start",
						width = 100,
						enabled = function()
							return SF.Debug and not SF.Debug:IsEnabled()
						end,
						onClick = function(ctx)
							if SF.Debug then
								SF.Debug:SetEnabled(true)
								SF:PrintSuccess("Debug logging enabled")
								ctx.pageBuilder:Refresh()
							end
						end,
					},
					
					{
						type = "button",
						label = "Stop Debugging",
						buttonText = "Stop",
						width = 100,
						enabled = function()
							return SF.Debug and SF.Debug:IsEnabled()
						end,
						onClick = function(ctx)
							if SF.Debug then
								SF.Debug:SetEnabled(false)
								SF:PrintInfo("Debug logging disabled")
								ctx.pageBuilder:Refresh()
							end
						end,
					},
					
					{
						type = "button",
						label = "Clear Logs",
						buttonText = "Clear",
						width = 100,
						onClick = function(ctx)
							if SF.debugDB and SF.debugDB.logs then
								SF.debugDB.logs = {}
								SF:PrintSuccess("Debug logs cleared")
								ctx.pageBuilder:Refresh()
							end
						end,
					},
				},
			},
			
			{
				id = "filters",
				title = "Log Level Filters",
				items = {
					{
						type = "checkbox",
						label = "Show VERBOSE",
						tooltip = "Display verbose-level debug messages",
						get = function()
							return panel.__sfLogLevels.VERBOSE
						end,
						set = function(value)
							panel.__sfLogLevels.VERBOSE = value
						end,
					},
					
					{
						type = "checkbox",
						label = "Show INFO",
						tooltip = "Display info-level debug messages",
						get = function()
							return panel.__sfLogLevels.INFO
						end,
						set = function(value)
							panel.__sfLogLevels.INFO = value
						end,
					},
					
					{
						type = "checkbox",
						label = "Show WARN",
						tooltip = "Display warning-level debug messages",
						get = function()
							return panel.__sfLogLevels.WARN
						end,
						set = function(value)
							panel.__sfLogLevels.WARN = value
						end,
					},
					
					{
						type = "checkbox",
						label = "Show ERROR",
						tooltip = "Display error-level debug messages",
						get = function()
							return panel.__sfLogLevels.ERROR
						end,
						set = function(value)
							panel.__sfLogLevels.ERROR = value
						end,
					},
				},
			},
			
			{
				id = "logs",
				title = "Debug Logs",
				items = {
					{
						type = "help",
						text = "Use Ctrl+A to select all, Ctrl+C to copy",
						indent = "label",
					},
					{
						type = "scrollableText",
						label = "",
						height = 300,
						get = function()
							return GetDebugLogsText()
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
