local addonName, ns = ...

-- Initialize SavedVariables references and namespace structure
local function InitializeNamespace()
    -- Ensure SpectrumFederationDB exists with default structure
    if not SpectrumFederationDB then
        SpectrumFederationDB = {
            schemaVersion = 1,
            currentTier = "0.0.0",
            tiers = {}
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
        
        -- Call Core module's login handler (to be implemented)
        if ns.Core and ns.Core.OnPlayerLogin then
            ns.Core:OnPlayerLogin()
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
    if ns.UI and ns.UI.Toggle then
        ns.UI:Toggle()
    else
        print("[Spectrum Federation] UI not initialized yet.")
    end
end

SLASH_SF1 = "/sf"
SlashCmdList["SF"] = HandleMainCommand
