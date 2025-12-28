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

        -- Create the Settings UI
        if SF.CreateSettingsUI then
            SF:CreateSettingsUI()
        else
            if SF.Debug then SF.Debug:Info("SETTINGS_UI", "No CreateSettingsUI function found") end
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
                    if not SF.Debug:IsEnabled() then
                        SF:PrintWarning("Debug logging is currently disabled. Enable it with '/sf debug on'")
                    end
                    
                    -- Create debug viewer window if it doesn't exist
                    -- TODO: Need to break these into smaller functions and store them in the debug file.
                    if not SF.DebugViewer then
                        SF.DebugViewer = CreateFrame("Frame", "SpectrumFederationDebugViewer", UIParent, "BackdropTemplate")
                        local viewer = SF.DebugViewer
                        
                        viewer:SetSize(600, 400)
                        viewer:SetPoint("CENTER")
                        viewer:SetBackdrop({
                            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                            tile = true, tileSize = 32, edgeSize = 32,
                            insets = { left = 8, right = 8, top = 8, bottom = 8 }
                        })
                        viewer:SetBackdropColor(0, 0, 0, 0.9)
                        viewer:EnableMouse(true)
                        viewer:SetMovable(true)
                        viewer:RegisterForDrag("LeftButton")
                        viewer:SetScript("OnDragStart", viewer.StartMoving)
                        viewer:SetScript("OnDragStop", viewer.StopMovingOrSizing)
                        
                        -- Title
                        local title = viewer:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                        title:SetPoint("TOP", 0, -16)
                        title:SetText("Debug Logs (Ctrl+A to select all, Ctrl+C to copy)")
                        
                        -- Close button
                        local closeBtn = CreateFrame("Button", nil, viewer, "UIPanelCloseButton")
                        closeBtn:SetPoint("TOPRIGHT", -5, -5)
                        
                        -- Scroll frame
                        local scrollFrame = CreateFrame("ScrollFrame", nil, viewer, "UIPanelScrollFrameTemplate")
                        scrollFrame:SetPoint("TOPLEFT", 16, -40)
                        scrollFrame:SetPoint("BOTTOMRIGHT", -32, 16)
                        
                        -- Edit box
                        local editBox = CreateFrame("EditBox", nil, scrollFrame)
                        editBox:SetMultiLine(true)
                        editBox:SetFontObject(ChatFontNormal)
                        editBox:SetWidth(scrollFrame:GetWidth())
                        editBox:SetAutoFocus(false)
                        editBox:SetScript("OnEscapePressed", function() viewer:Hide() end)
                        scrollFrame:SetScrollChild(editBox)
                        viewer.editBox = editBox
                    end
                    
                    -- Get logs and format them
                    local logs = SF.Debug:GetRecentLogs(100)
                    local logText = ""
                    if #logs == 0 then
                        logText = "No debug logs available"
                    else
                        logText = string.format("Last %d debug logs:\\n\\n", #logs)
                        for i, log in ipairs(logs) do
                            local timestamp = SF:FormatTimestampForUser(log.timestamp)
                            logText = logText .. string.format("[%s] [%s] %s: %s\\n", 
                                timestamp, log.level, log.category, log.message)
                        end
                    end
                    
                    SF.DebugViewer.editBox:SetText(logText)
                    SF.DebugViewer.editBox:HighlightText()
                    SF.DebugViewer:Show()
                    
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

-- Create an Event Frame for Addon Loaded
local AddonLoadedFrame = CreateFrame("Frame")
-- Register the ADDON_LOADED Event
AddonLoadedFrame:RegisterEvent("ADDON_LOADED")
-- Script to run when ADDON_LOADED Event fires
AddonLoadedFrame:SetScript("OnEvent", function(self, event, addonName)

    -- Ensure the loaded addon is SpectrumFederation
    if addonName ~= "SpectrumFederation" then return end

    -- Initialize Loot Helper Database before creating UI
    if SF.InitializeLootHelperDatabase then
        SF:InitializeLootHelperDatabase()
    end

    -- Create the Loot Window
    if SF.LootWindow and SF.LootWindow.Create then
        SF.LootWindow:Create()
    end
end)