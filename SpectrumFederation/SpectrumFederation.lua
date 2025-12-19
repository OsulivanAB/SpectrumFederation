local addonName, ns = ...

-- Initialize SavedVariables references and namespace structure
local function InitializeNamespace()
    -- Ensure SpectrumFederationDB exists with default structure
    if not SpectrumFederationDB then
        SpectrumFederationDB = {
            schemaVersion = 2,
            profiles = {
                ["Default"] = {
                    points = {},
                    logs = {},
                    nextLogId = 1,
                    createdAt = time(),
                    createdBy = "System"
                }
            },
            activeProfile = "Default",
            settings = {
                lootWindowEnabled = true,
                lastSyncCoordinator = nil,
                backdropStyle = "Default"
            },
            ui = {
                lootFrame = {
                    position = nil,
                    isShown = false
                },
                settingsFrame = {
                    position = nil,
                    isShown = false,
                    activeTab = 1
                }
            }
        }
    end
    
    -- Ensure SpectrumFederationDebugDB exists with default structure
    if not SpectrumFederationDebugDB then
        SpectrumFederationDebugDB = {
            enabled = false,
            logs = {},
            maxEntries = 500
        }
    end
    
    -- Reference SavedVariables in namespace
    ns.db = SpectrumFederationDB
    ns.debugDB = SpectrumFederationDebugDB
    
    -- Create module sub-tables
    ns.Core = ns.Core or {}
    ns.UI = ns.UI or {}
    ns.Debug = ns.Debug or {}
    ns.Log = ns.Log or {}
end

-- Create event frame for addon initialization
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        -- Initialize namespace and SavedVariables
        InitializeNamespace()
        
        -- Initialize debug system
        if ns.Debug and ns.Debug.Initialize then
            ns.Debug:Initialize()
        end
        
        -- Log addon initialization
        if ns.Debug then
            ns.Debug:Info("ADDON_INIT", "SpectrumFederation initializing...")
        end
        
        -- Initialize sync module
        if ns.Sync and ns.Sync.Initialize then
            ns.Sync:Initialize()
        end
        
        -- Call Core module's login handler (to be implemented)
        if ns.Core and ns.Core.OnPlayerLogin then
            ns.Core:OnPlayerLogin()
        end
        
        -- Initialize settings UI
        if ns.Settings and ns.Settings.Initialize then
            ns.Settings:Initialize()
        end
    elseif event == "CHAT_MSG_ADDON" then
        -- Handle addon messages for sync
        local prefix, message, channel, sender = ...
        
        -- Validate parameters before passing to sync module
        if prefix and message and channel and sender then
            if ns.Sync and ns.Sync.OnAddonMessage then
                ns.Sync:OnAddonMessage(prefix, message, channel, sender)
            end
        elseif ns.Debug then
            ns.Debug:Warn("ADDON_MSG", "Received CHAT_MSG_ADDON with missing parameters")
        end
    end
end)

-- Slash command handler for /sfdebug
local function HandleDebugCommand(msg)
    local command = string.lower(msg or "")
    
    if command == "on" then
        if ns.Debug then
            ns.Debug:SetEnabled(true)
            print("[Spectrum Federation] Debug logging |cff00ff00enabled|r")
            ns.Debug:Info("DEBUG_CMD", "Debug logging enabled via slash command")
        end
    elseif command == "off" then
        if ns.Debug then
            ns.Debug:Info("DEBUG_CMD", "Debug logging disabled via slash command")
            ns.Debug:SetEnabled(false)
            print("[Spectrum Federation] Debug logging |cffff0000disabled|r")
        end
    elseif command == "show" then
        if ns.Debug then
            local logs = ns.Debug:GetRecentLogs(10)
            
            if #logs == 0 then
                print("[Spectrum Federation] No debug logs to display.")
            else
                print("[Spectrum Federation] Recent debug logs:")
                for _, entry in ipairs(logs) do
                    local timestamp = date("%H:%M:%S", entry.timestamp)
                    local levelColor = "ffffff"
                    if entry.level == "ERROR" then
                        levelColor = "ff0000"
                    elseif entry.level == "WARN" then
                        levelColor = "ffff00"
                    elseif entry.level == "INFO" then
                        levelColor = "00ff00"
                    end
                    print(string.format("|cff888888%s|r [|cff%s%s|r] |cffaaaaaa%s|r: %s", 
                        timestamp, levelColor, entry.level, entry.category, entry.message))
                end
            end
        end
    else
        print("[Spectrum Federation] Debug commands:")
        print("  /sfdebug on  - Enable debug logging")
        print("  /sfdebug off - Disable debug logging")
        print("  /sfdebug show - Show recent debug logs")
    end
end

-- Register slash commands
SLASH_SFDEBUG1 = "/sfdebug"
SlashCmdList["SFDEBUG"] = HandleDebugCommand

-- Slash command handler for /sf
local function HandleMainCommand(msg)
    -- Trim and convert to lowercase
    msg = (msg or ""):lower():trim()
    
    if msg == "" then
        -- No arguments - open settings window
        if ns.Settings and ns.Settings.Toggle then
            ns.Settings:Toggle()
        else
            print("[Spectrum Federation] Settings UI not initialized yet.")
        end
    elseif msg == "loot" then
        -- Toggle loot window
        if ns.UI and ns.UI.Toggle then
            ns.UI:Toggle()
        else
            print("[Spectrum Federation] Loot window not initialized yet.")
        end
    elseif msg == "debug" then
        -- Toggle debug logging
        if ns.Debug then
            local newState = not ns.Debug:IsEnabled()
            ns.Debug:SetEnabled(newState)
            print(newState and "[Spectrum Federation] Debug logging enabled" or "[Spectrum Federation] Debug logging disabled")
        else
            print("[Spectrum Federation] Debug module not initialized yet.")
        end
    elseif msg == "help" then
        -- Show help message
        print("|cFF00FF00Spectrum Federation Commands:|r")
        print("  |cFFFFFF00/sf|r - Open settings window")
        print("  |cFFFFFF00/sf loot|r - Toggle loot window visibility")
        print("  |cFFFFFF00/sf debug|r - Toggle debug logging on/off")
        print("  |cFFFFFF00/sf help|r - Show this help message")
    else
        print("[Spectrum Federation] Unknown command. Type |cFFFFFF00/sf help|r for usage.")
    end
end

SLASH_SF1 = "/sf"
SlashCmdList["SF"] = HandleMainCommand
