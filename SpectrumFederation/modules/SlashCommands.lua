-- Grab the namespace
local addonName, SF = ...

-- Slash command registry
SF.SlashCommands = SF.SlashCommands or {}

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
-- @return nil
local function ShowHelp()
    SF:PrintSuccess("Commands:")
    SF:PrintInfo("|cFFFFFF00/sf|r - Toggle settings window")
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

-- Main slash command handler for /sf
-- @param msg string Raw message after /sf
-- @return nil
local function SlashCommandHandler(msg)
    -- Trim whitespace and convert to lowercase
    msg = msg:trim():lower()
    
    -- Empty command or no arguments - open settings
    if msg == "" then
        -- Toggle standalone settings window
        if SF.SettingsWindow and SF.SettingsWindow.Toggle then
            SF.SettingsWindow:Toggle()
        else
            SF:PrintError("Settings Window is not available.")
            if SF.Debug then SF.Debug:Warn("SLASH", "SettingsWindow not found") end
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

-- Initialize slash commands system and register /sf
-- @return nil
function SF:InitializeSlashCommands()
    -- Register the main /sf command
    SLASH_SPECFED1 = "/sf"
    SlashCmdList["SPECFED"] = SlashCommandHandler
    
    -- Register built-in help command
    self:RegisterSlashCommand("help", ShowHelp, "Show this help message")
    
    if SF.Debug then SF.Debug:Info("SLASH", "Slash command system initialized") end
end

-- Register Loot Helper slash commands
-- @return nil
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
        local owner = profile:GetOwnerId()
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
            SF:ClearActiveProfile()
            SF:PrintWarning("Cleared active profile (deleted)")
        end
        
        -- Delete
        SF.lootHelperDB.profiles[profileId] = nil
        SF:PrintSuccess(string.format("Deleted profile: %s (ID: %s)", profileName, profileId))
        
    end, "Delete a loot profile (by name or ID)")

    SF:RegisterSlashCommand("loot", function(args)
        -- Parse subcommands
        args = args:trim():lower()
        
        -- Handle "session start" subcommand
        if args == "session start" then
            -- Check if sync system is available
            if not (SF.LootHelperSync and SF.LootHelperSync.StartSession) then
                SF:PrintError("Loot Helper Sync system not available")
                return
            end
            
            -- Get the active profile ID
            local profileId = SF.lootHelperDB and SF.lootHelperDB.activeProfileId
            if not profileId then
                SF:PrintError("No active profile selected. Use /sf switchprofile <name> or /sf createprofile <name>")
                return
            end
            
            -- Start the session
            local sessionId = SF.LootHelperSync:StartSession(profileId)
            if sessionId then
                SF:PrintSuccess("Session started successfully")
            else
                SF:PrintError("Failed to start session (not in a group/raid?)")
            end
            return
        end
        
        -- Handle "session end" subcommand
        if args == "session end" then
            -- Check if sync system is available
            if not (SF.LootHelperSync and SF.LootHelperSync.EndSession) then
                SF:PrintError("Loot Helper Sync system not available")
                return
            end
            
            -- End the session
            local ok = SF.LootHelperSync:EndSession("manual")
            if ok then
                SF:PrintSuccess("Session ended successfully")
            else
                SF:PrintError("Failed to end session (no active session?)")
            end
            return
        end
        
        -- Default behavior: enable loot helper (when no subcommand or just "loot")
        local store = SF.SettingsStore

        local alreadyEnabled = false
        if store and store.Get then
            alreadyEnabled = store:Get("lootHelper.enabled") and true or false
        elseif SF.lootHelperDB then
            alreadyEnabled = SF.lootHelperDB.enabled and true or false
        end

        if alreadyEnabled then
            if SF.PrintInfo then
                SF:PrintInfo("Loot Helper is already enabled.")
            else
                print("SpectrumFederation: Loot Helper is already enabled.")
            end
        else
            if store and store.Set then
                store:Set("lootHelper.enabled", true)
            else
                SpectrumFederationDB = SpectrumFederationDB or {}
                SpectrumFederationDB.lootHelper = SpectrumFederationDB.lootHelper or {}
                SpectrumFederationDB.lootHelper.enabled = true
            end

            if SF.PrintSuccess then
                SF:PrintSuccess("Loot Helper enabled.")
            else
                print("SpectrumFederation: Loot Helper enabled.")
            end
        end

        local c = SF.LootHelperWindow and SF.LootHelperWindow.Controller
        if c and c.Init then
            c:Init()
        end
        if c and c.EvaluateVisibility then
            c:EvaluateVisibility("Slash:/sf loot")

            if c.ShouldBeVisible then
                local ok, why = c:ShouldBeVisible()
                if not ok then
                    if why == "no_active_profile" then
                        if SF.PrintWarning then
                            SF:PrintWarning("Cannot show Loot Helper window: No active profile set.")
                        else
                            print("SpectrumFederation: Cannot show Loot Helper window: No active profile set.")
                        end
                    elseif why == "not_in_raid" then
                        if SF.PrintWarning then
                            SF:PrintWarning("Cannot show Loot Helper window: You are not in a raid.")
                        else
                            print("SpectrumFederation: Cannot show Loot Helper window: You are not in a raid.")
                        end
                    end
                end
            end
        end
    end, "Enable Loot Helper or manage sessions (/sf loot session start|end)")
end
