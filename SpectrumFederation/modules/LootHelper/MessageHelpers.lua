-- Grab the namespace
local addonName, SF = ...

-- Message color constants
local COLOR_SUCCESS = "|cFF00FF00"  -- Green
local COLOR_ERROR = "|cFFFF0000"    -- Red
local COLOR_WARNING = "|cFFFFA500"  -- Orange
local COLOR_INFO = "|cFFFFFFFF"     -- White
local COLOR_RESET = "|r"
local ADDON_PREFIX = "|cFF00FF00Spectrum Federation:|r "

-- Helper function to print a success message
-- @param message: The message to display
-- @return: none
function SF:PrintSuccess(message)
    print(ADDON_PREFIX .. message)
end

-- Helper function to print an error message
-- @param message: The error message to display
-- @return: none
function SF:PrintError(message)
    print(COLOR_ERROR .. addonName .. COLOR_RESET .. ": " .. message)
end

-- Helper function to print a warning message
-- @param message: The warning message to display
-- @return: none
function SF:PrintWarning(message)
    print(COLOR_WARNING .. addonName .. COLOR_RESET .. ": " .. message)
end

-- Helper function to print an info message
-- @param message: The info message to display
-- @return: none
function SF:PrintInfo(message)
    print(COLOR_INFO .. addonName .. COLOR_RESET .. ": " .. message)
end
