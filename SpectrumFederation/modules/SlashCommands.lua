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

-- Register Loot Helper slash commands
-- @return: none
function SF:RegisterLootHelperSlashCommands()
    
    -- List all profiles
    SF:RegisterSlashCommand("profiles", function()
        if not SF.lootHelperDB or not SF.lootHelperDB.profiles then
            SF:PrintError("No profiles found!")
            return
        end
        
        local count = 0
        SF:PrintInfo("Available Loot Profiles:")
        
        for profileId, profile in pairs(SF.lootHelperDB.profiles) do
            count = count + 1
            local name = profile:GetProfileName() or "Unknown"
            local isActive = (SF.lootHelperDB.activeProfileId == profileId)
            local marker = isActive and " [ACTIVE]" or ""
            
            SF:PrintInfo(string.format("  %d. %s (ID: %s)%s", count, name, profileId, marker))
        end
        
        if count == 0 then
            SF:PrintWarning("No profiles found. Create one with /sf createprofile <name>")
        end
    end, "List all loot profiles")
    
    -- Get active profile info
    SF:RegisterSlashCommand("activeprofile", function()
        local profile = SF:GetActiveProfile()
        
        if not profile then
            SF:PrintWarning("No active profile set")
            return
        end
        
        local name = profile:GetProfileName()
        local profileId = profile:GetProfileId()
        local author = profile:GetAuthor()
        local owner = profile:GetOwner()
        local created = profile:GetCreationTime()
        local modified = profile:GetLastModifiedTime()
        local members = profile:GetMemberList()
        local logs = profile:GetLootLogs()
        
        SF:PrintInfo("Active Profile:")
        SF:PrintInfo(string.format("  Name: %s", name))
        SF:PrintInfo(string.format("  ID: %s", profileId))
        SF:PrintInfo(string.format("  Author: %s", author))
        SF:PrintInfo(string.format("  Owner: %s", owner))
        SF:PrintInfo(string.format("  Created: %s", SF:FormatTimestampForUser(created)))
        SF:PrintInfo(string.format("  Modified: %s", SF:FormatTimestampForUser(modified)))
        SF:PrintInfo(string.format("  Members: %d", #members))
        SF:PrintInfo(string.format("  Logs: %d", #logs))
    end, "Show active profile information")
    
    -- Create new profile
    SF:RegisterSlashCommand("createprofile", function(args)
        if not args or args == "" then
            SF:PrintError("Usage: /sf createprofile <name>")
            return
        end
        
        local profile = SF.LootProfile.new(args)
        if not profile then
            SF:PrintError("Failed to create profile")
            return
        end
        
        if SF:AddLootProfileToDatabase(profile) then
            SF:PrintSuccess(string.format("Created and activated profile: %s (ID: %s)", 
                args, profile:GetProfileId()))
        else
            SF:PrintError("Failed to add profile to database")
        end
    end, "Create a new loot profile")
    
    -- Switch active profile (supports both name and ID)
    SF:RegisterSlashCommand("switchprofile", function(args)
        if not args or args == "" then
            SF:PrintError("Usage: /sf switchprofile <name or ID>")
            return
        end
        
        -- Try as profileId first
        if SF.lootHelperDB.profiles[args] then
            if SF:SetActiveProfileById(args) then
                local profile = SF.lootHelperDB.profiles[args]
                SF:PrintSuccess(string.format("Switched to profile: %s", profile:GetProfileName()))
            else
                SF:PrintError("Failed to switch profile")
            end
            return
        end
        
        -- Try as profile name
        local found = false
        for profileId, profile in pairs(SF.lootHelperDB.profiles) do
            if profile:GetProfileName() == args then
                if SF:SetActiveProfileById(profileId) then
                    SF:PrintSuccess(string.format("Switched to profile: %s (ID: %s)", args, profileId))
                else
                    SF:PrintError("Failed to switch profile")
                end
                found = true
                break
            end
        end
        
        if not found then
            SF:PrintError(string.format("Profile not found: %s", args))
            SF:PrintInfo("Use /sf profiles to see available profiles")
        end
    end, "Switch active profile (by name or ID)")
    
    -- Delete profile
    SF:RegisterSlashCommand("deleteprofile", function(args)
        if not args or args == "" then
            SF:PrintError("Usage: /sf deleteprofile <name or ID>")
            return
        end
        
        local profileToDelete = nil
        local profileId = nil
        
        -- Try as profileId first
        if SF.lootHelperDB.profiles[args] then
            profileId = args
            profileToDelete = SF.lootHelperDB.profiles[args]
        else
            -- Try as profile name
            for pid, profile in pairs(SF.lootHelperDB.profiles) do
                if profile:GetProfileName() == args then
                    profileId = pid
                    profileToDelete = profile
                    break
                end
            end
        end
        
        if not profileToDelete then
            SF:PrintError(string.format("Profile not found: %s", args))
            return
        end
        
        local profileName = profileToDelete:GetProfileName()
        
        -- Clear if active
        if SF.lootHelperDB.activeProfileId == profileId then
            SF.lootHelperDB.activeProfileId = nil
            SF:PrintWarning("Cleared active profile (deleted)")
        end
        
        -- Delete
        SF.lootHelperDB.profiles[profileId] = nil
        SF:PrintSuccess(string.format("Deleted profile: %s (ID: %s)", profileName, profileId))
        
    end, "Delete a loot profile (by name or ID)")
end
