local addonName, SF = ...

-- Message color constants
local COLOR_INFO = "|cFFFFFFFF"     -- White
local COLOR_PREFIX = "|cFF40C7FF"   -- Accent blue
local COLOR_RESET = "|r"

local function colorMessageWhite(message)
    if not message or message == "" then return nil end
    local colored = tostring(message):gsub("|r", "|r" .. COLOR_INFO)
    return COLOR_INFO .. colored .. COLOR_RESET
end

local function printWithPrefix(message)
    local colored = colorMessageWhite(message)
    if not colored then return end
    print(string.format("%s%s%s: %s", COLOR_PREFIX, addonName, COLOR_RESET, colored))
end

-- Helper function to print a success message
-- @param message: The message to display
-- @return: none
function SF:PrintSuccess(message)
    printWithPrefix(message)
end

-- Helper function to print an info message
-- @param message: The info message to display
-- @return: none
function SF:PrintInfo(message)
    printWithPrefix(message)
end

-- Helper function to print a warning message
-- @param message: The warning message to display
-- @return: none
function SF:PrintWarning(message)
    printWithPrefix(message)
end

-- Helper function to print an error message
-- @param message: The error message to display
-- @return: none
function SF:PrintError(message)
    printWithPrefix(message)
end

-- Helper function to print a system-style message with colored prefix
-- @param message: The message to display in white
-- @return: none
function SF:SystemMessage(message)
    local colored = colorMessageWhite(message)
    if not colored then return end
    print(string.format("%sSpectrum Federation:%s %s", COLOR_PREFIX, COLOR_RESET, colored))
end
