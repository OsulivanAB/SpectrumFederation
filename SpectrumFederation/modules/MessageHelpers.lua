-- Grab the namespace
local addonName, SF = ...

-- Message color constants
local COLOR_SUCCESS = "|cFF00FF00"  -- Green
local COLOR_ERROR = "|cFFFF0000"    -- Red
local COLOR_WARNING = "|cFFFFA500"  -- Orange
local COLOR_INFO = "|cFFFFFFFF"     -- White
local COLOR_PREFIX = "|cFF40C7FF"   -- Accent blue
local COLOR_RESET = "|r"

-- Helper function to print a success message
-- @param message: The message to display
-- @return: none
function SF:PrintSuccess(message)
    print(string.format("%s%s%s: %s%s%s", COLOR_PREFIX, addonName, COLOR_RESET, COLOR_SUCCESS, message, COLOR_RESET))
end

-- Helper function to print an error message
-- @param message: The error message to display
-- @return: none
function SF:PrintError(message)
    print(string.format("%s%s%s: %s%s%s", COLOR_PREFIX, addonName, COLOR_RESET, COLOR_ERROR, message, COLOR_RESET))
end

-- Helper function to print a warning message
-- @param message: The warning message to display
-- @return: none
function SF:PrintWarning(message)
    print(string.format("%s%s%s: %s%s%s", COLOR_PREFIX, addonName, COLOR_RESET, COLOR_WARNING, message, COLOR_RESET))
end

-- Helper function to print an info message
-- @param message: The info message to display
-- @return: none
function SF:PrintInfo(message)
    print(string.format("%s%s%s: %s%s%s", COLOR_PREFIX, addonName, COLOR_RESET, COLOR_INFO, message, COLOR_RESET))
end

-- Helper function to print a system-style message with colored prefix
-- @param message: The message to display in white
-- @return: none
function SF:SystemMessage(message)
    if not message or message == "" then return end
    print(string.format("%sSpectrum Federation:%s %s%s%s", COLOR_PREFIX, COLOR_RESET, COLOR_INFO, message, COLOR_RESET))
end
