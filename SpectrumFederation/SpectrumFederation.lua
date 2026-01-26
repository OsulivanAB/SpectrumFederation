-- Grab the namespace
local addonName, SF = ...

-- Create an Event Frame for Addon Initialization
local EventFrame = CreateFrame("Frame")

-- Register the Player Login Event
EventFrame:RegisterEvent("PLAYER_LOGIN")

-- Script to run when Player Login Event fires
EventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        
        -- Initialize DebugDB
        if not SpectrumFederationDebugDB then
            SpectrumFederationDebugDB = {
                enabled = false,
                logs = {},
                maxEntries = 500
            }
        end
        SF.debugDB = SpectrumFederationDebugDB
        
        -- Initialize Debug System
        if SF.Debug then
            SF.Debug:Initialize()
            SF.Debug:Info("ADDON", "SpectrumFederation addon loaded")
        end

        -- Initialize Loot Helper Database
        if SF.InitializeLootHelperDatabase then
            SF:InitializeLootHelperDatabase()
        end

        -- Enable Loot Helper Sync system (registers slash commands and event handlers)
        if SF.LootHelperSync and SF.LootHelperSync.Enable then
            SF.LootHelperSync:Enable()
            if SF.Debug then SF.Debug:Info("SYNC", "LootHelper Sync system enabled") end
        end

        -- Register Loot Helper slash commands
        if SF.RegisterLootHelperSlashCommands then
            SF:RegisterLootHelperSlashCommands()
        end

        -- Send a quick message saying that Addon is Initialized
        SF:PrintSuccess("Online. Type /sf to open settings.")

        -- Initialize Slash Commands
        if SF.InitializeSlashCommands then
            SF:InitializeSlashCommands()
            
            -- Register debug commands
            SF:RegisterSlashCommand("debug", function(args)
                args = args:trim():lower()
                
                if args == "on" or args == "enable" then
                    SF.Debug:SetEnabled(true)
                    SF:PrintSuccess("Debug logging enabled. Use '/sf debug show' to view logs.")
                elseif args == "off" or args == "disable" then
                    SF.Debug:SetEnabled(false)
                    SF:PrintInfo("Debug logging disabled")
                elseif args == "show" or args == "logs" or args == "" then
                    -- Open the settings window to the Debugging page
                    if SF.SettingsWindow and SF.SettingsWindow.ShowPage then
                        SF.SettingsWindow:ShowPage("debugging")
                    else
                        SF:PrintError("Settings Window is not available.")
                    end
                elseif args == "clear" then
                    if SF.debugDB and SF.debugDB.logs then
                        SF.debugDB.logs = {}
                        SF:PrintSuccess("Debug logs cleared")
                    end
                else
                    SF:PrintError("Unknown debug command. Use: on, off, show, clear")
                end
            end, "Debug logging controls (on/off/show/clear)")
        else
            if SF.Debug then SF.Debug:Warn("SLASH", "InitializeSlashCommands function not found") end
        end

        -- Unregister the Event after initialization
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)