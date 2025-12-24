-- Grab the namespace
local addonName, SF = ...

-- Slash command registry
SF.SlashCommands = SF.SlashCommands or {}

-- Register a new slash command
-- @param command: The command keyword (e.g., "loot", "debug")
-- @param handler: Function to execute when command is called
-- @param description: Help text for the command
function SF:RegisterSlashCommand(command, handler, description)
    if type(command) ~= "string" or command == "" then
        if SF.Debug then SF.Debug:Error("SLASH", "RegisterSlashCommand failed: Invalid command name") end
        return false
    end
    
    if type(handler) ~= "function" then
        if SF.Debug then SF.Debug:Error("SLASH", "RegisterSlashCommand failed: Handler must be a function") end
        return false
    end
    
    -- Store command in registry
    SF.SlashCommands[command:lower()] = {
        handler = handler,
        description = description or "No description available."
    }
    
    if SF.Debug then SF.Debug:Info("SLASH", "Registered command: /sf %s", command:lower()) end
    return true
end

-- Show help message with all registered commands
local function ShowHelp()
    SF:PrintSuccess("Commands:")
    SF:PrintInfo("|cFFFFFF00/sf|r - Open settings panel")
    SF:PrintInfo("|cFFFFFF00/sf help|r - Show this help message")
    
    -- Sort commands alphabetically
    local sortedCommands = {}
    for cmd in pairs(SF.SlashCommands) do
        if cmd ~= "help" then  -- Don't duplicate help
            table.insert(sortedCommands, cmd)
        end
    end
    table.sort(sortedCommands)
    
    -- Display each command
    for _, cmd in ipairs(sortedCommands) do
        local cmdData = SF.SlashCommands[cmd]
        SF:PrintInfo(string.format("|cFFFFFF00/sf %s|r - %s", cmd, cmdData.description))
    end
end

-- Main slash command handler
local function SlashCommandHandler(msg)
    -- Trim whitespace and convert to lowercase
    msg = msg:trim():lower()
    
    -- Empty command or no arguments - open settings
    if msg == "" then
        if SF.SettingsCategory and SF.SettingsPanel then
            local categoryID = SF.SettingsCategory:GetID()
            Settings.OpenToCategory(categoryID)
        else
            SF:PrintError("Settings UI is not available.")
            if SF.Debug then SF.Debug:Warn("SLASH", "SettingsCategory or SettingsPanel not found") end
        end
        return
    end
    
    -- Split command and arguments
    local command, args = msg:match("^(%S+)%s*(.*)")
    command = command or msg
    args = args or ""
    
    -- Check for help command
    if command == "help" then
        ShowHelp()
        return
    end
    
    -- Look up command in registry
    local cmdData = SF.SlashCommands[command]
    if cmdData and cmdData.handler then
        -- Execute the command handler
        local success, err = pcall(cmdData.handler, args)
        if not success then
            SF:PrintError("Error executing command: " .. tostring(err))
            if SF.Debug then SF.Debug:Error("SLASH", "Command '%s' failed: %s", command, tostring(err)) end
        end
    else
        -- Unknown command
        SF:PrintError("Unknown command '" .. command .. "'. Type |cFFFFFF00/sf help|r for a list of commands.")
        if SF.Debug then SF.Debug:Warn("SLASH", "Unknown command: %s", command) end
    end
end

-- Initialize slash commands system
function SF:InitializeSlashCommands()
    -- Register the main /sf command
    SLASH_SPECFED1 = "/sf"
    SlashCmdList["SPECFED"] = SlashCommandHandler
    
    -- Register built-in help command
    self:RegisterSlashCommand("help", ShowHelp, "Show this help message")
    
    if SF.Debug then SF.Debug:Info("SLASH", "Slash command system initialized") end
end
