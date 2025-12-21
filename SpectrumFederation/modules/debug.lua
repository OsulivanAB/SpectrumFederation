local addonName, SF = ...

-- Local reference to Debug module
local Debug = SF.Debug or {}
SF.Debug = Debug

-- In-memory enabled state (synced with SavedVariables)
Debug.enabled = false

-- Log levels
Debug.LEVELS = {
    VERBOSE = "VERBOSE",
    INFO = "INFO",
    WARN = "WARN",
    ERROR = "ERROR"
}

-- SetEnabled: Enable or disable debug logging
function Debug:SetEnabled(enabled)
    self.enabled = enabled
    if SF.debugDB then
        SF.debugDB.enabled = enabled
    end
end

-- IsEnabled: Check if debug logging is enabled
function Debug:IsEnabled()
    return self.enabled
end

-- Log: Main logging function
-- @param level: Log level (VERBOSE, INFO, WARN, ERROR)
-- @param category: Category/context of the log
-- @param message: Message to log
-- @param ...: Additional arguments to format into the message
function Debug:Log(level, category, message, ...)
    if not self:IsEnabled() then
        return
    end
    
    -- Format the message with any additional arguments
    local formattedMessage = message
    if select("#", ...) > 0 then
        formattedMessage = string.format(message, ...)
    end
    
    -- Create log entry
    local entry = {
        timestamp = time(),
        level = level,
        category = category,
        message = formattedMessage
    }
    
    -- Append to debugDB
    if SF.debugDB and SF.debugDB.logs then
        table.insert(SF.debugDB.logs, entry)
        
        -- Trim old entries if above maxEntries
        local maxEntries = SF.debugDB.maxEntries or 500
        while #SF.debugDB.logs > maxEntries do
            table.remove(SF.debugDB.logs, 1)
        end
    end
end

-- Helper method: Log verbose message
function Debug:Verbose(category, message, ...)
    self:Log(self.LEVELS.VERBOSE, category, message, ...)
end

-- Helper method: Log info message
function Debug:Info(category, message, ...)
    self:Log(self.LEVELS.INFO, category, message, ...)
end

-- Helper method: Log warning message
function Debug:Warn(category, message, ...)
    self:Log(self.LEVELS.WARN, category, message, ...)
end

-- Helper method: Log error message
function Debug:Error(category, message, ...)
    self:Log(self.LEVELS.ERROR, category, message, ...)
end

-- GetRecentLogs: Get the most recent log entries
-- @param count: Number of entries to retrieve (default 10)
-- @return: Table of log entries
function Debug:GetRecentLogs(count)
    count = count or 10
    
    if not SF.debugDB or not SF.debugDB.logs then
        return {}
    end
    
    local logs = SF.debugDB.logs
    local totalLogs = #logs
    local startIndex = math.max(1, totalLogs - count + 1)
    
    local recentLogs = {}
    for i = startIndex, totalLogs do
        table.insert(recentLogs, logs[i])
    end
    
    return recentLogs
end

-- Initialize debug state from SavedVariables
function Debug:Initialize()
    if SF.debugDB then
        self.enabled = SF.debugDB.enabled or false
    end
end
