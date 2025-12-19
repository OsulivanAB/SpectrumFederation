--[[
    Settings Module
    Manages the tabbed settings window interface
]]--

local addonName, ns = ...

local Settings = ns.Settings or {}
ns.Settings = Settings

-- Module state
local settingsFrame = nil
local tabContents = {} -- Holds references to tab content frames

-- Constants
local FRAME_WIDTH = 600
local FRAME_HEIGHT = 500
local FRAME_TITLE = "Spectrum Federation Settings"
local NUM_TABS = 3
local TAB_NAMES = {"Main", "Loot", "Debug"}

-- Backdrop style presets
local BACKDROP_STYLES = {
    ["Default"] = {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
        backdropColor = {0, 0, 0, 1},
        backdropBorderColor = {1, 1, 1, 1},
    },
    ["Dark"] = {
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
        backdropColor = {0, 0, 0, 0.9},
        backdropBorderColor = {0.3, 0.3, 0.3, 1},
    },
    ["Light"] = {
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
        backdropColor = {1, 1, 1, 0.8},
        backdropBorderColor = {0.7, 0.7, 0.7, 1},
    },
    ["Transparent"] = {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
        backdropColor = {0, 0, 0, 0.5},
        backdropBorderColor = {1, 1, 1, 0.7},
    },
    ["Solid"] = {
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = false, tileSize = 0, edgeSize = 2,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
        backdropColor = {0.1, 0.1, 0.1, 1},
        backdropBorderColor = {0.5, 0.5, 0.5, 1},
    },
}

--[[
    Create the main settings window frame
    @return Frame - The created settings frame
]]--
function Settings:CreateSettingsFrame()
    if settingsFrame then
        return settingsFrame
    end

    -- Create main frame with BasicFrameTemplateWithInset
    local frame = CreateFrame("Frame", "SpectrumFederationSettingsFrame", UIParent, "BasicFrameTemplateWithInset")
    
    -- Add backdrop mixin for WoW 9.0+ compatibility
    Mixin(frame, BackdropTemplateMixin)
    
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)

    -- Set title
    if frame.TitleText then
        frame.TitleText:SetText(FRAME_TITLE)
    end

    -- Make draggable
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        Settings:SavePosition()
    end)

    -- Close button handler
    if frame.CloseButton then
        frame.CloseButton:SetScript("OnClick", function()
            Settings:Hide()
        end)
    end

    -- Register for ESC key
    tinsert(UISpecialFrames, "SpectrumFederationSettingsFrame")

    -- Initially hide
    frame:Hide()

    settingsFrame = frame

    -- Load saved position
    self:LoadPosition()
    
    -- Apply saved backdrop style
    if ns.db.settings and ns.db.settings.backdropStyle then
        self:ApplyBackdropToFrame(frame, ns.db.settings.backdropStyle)
    end

    -- Create tabs and tab content
    self:CreateTabs(frame)
    self:CreateTabContents(frame)

    -- Select the saved active tab (default to Main)
    local activeTab = 1
    if ns.db.ui.settingsFrame and ns.db.ui.settingsFrame.activeTab then
        activeTab = ns.db.ui.settingsFrame.activeTab
    end
    self:SelectTab(activeTab)

    if ns.Debug then
        ns.Debug:Info("SETTINGS", "Settings frame created with %d tabs", NUM_TABS)
    end

    return frame
end

--[[
    Save the current window position to database
]]--
function Settings:SavePosition()
    if not settingsFrame then return end

    local x, y = settingsFrame:GetLeft(), settingsFrame:GetTop()
    if x and y then
        if not ns.db.ui.settingsFrame then
            ns.db.ui.settingsFrame = {}
        end
        ns.db.ui.settingsFrame.position = {x = x, y = y}

        if ns.Debug then
            ns.Debug:Verbose("SETTINGS", "Saved position: x=%.1f, y=%.1f", x, y)
        end
    end
end

--[[
    Load saved window position from database
]]--
function Settings:LoadPosition()
    if not settingsFrame then return end

    if ns.db.ui.settingsFrame and ns.db.ui.settingsFrame.position then
        local pos = ns.db.ui.settingsFrame.position
        if pos.x and pos.y then
            settingsFrame:ClearAllPoints()
            settingsFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)

            if ns.Debug then
                ns.Debug:Verbose("SETTINGS", "Loaded position: x=%.1f, y=%.1f", pos.x, pos.y)
            end
        end
    end
end

--[[
    Toggle the settings window visibility
]]--
function Settings:Toggle()
    if not settingsFrame then
        self:CreateSettingsFrame()
    end

    if settingsFrame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

--[[
    Show the settings window
]]--
function Settings:Show()
    if not settingsFrame then
        self:CreateSettingsFrame()
    end

    settingsFrame:Show()

    -- Save visibility state
    if ns.db.ui.settingsFrame then
        ns.db.ui.settingsFrame.isShown = true
    end

    if ns.Debug then
        ns.Debug:Info("SETTINGS", "Settings window shown")
    end
end

--[[
    Hide the settings window
]]--
function Settings:Hide()
    if not settingsFrame then return end

    settingsFrame:Hide()

    -- Save visibility state
    if ns.db.ui.settingsFrame then
        ns.db.ui.settingsFrame.isShown = false
    end

    if ns.Debug then
        ns.Debug:Info("SETTINGS", "Settings window hidden")
    end
end

--[[
    Create tab buttons for the settings window
    @param parentFrame Frame - The parent settings frame
]]--
function Settings:CreateTabs(parentFrame)
    if not parentFrame then return end

    -- Store tab buttons
    local tabs = {}

    for i = 1, NUM_TABS do
        local tab = CreateFrame("Button", "$parentTab" .. i, parentFrame, "PanelTabButtonTemplate")
        tab:SetID(i)
        tab:SetText(TAB_NAMES[i])

        -- Position tabs horizontally
        if i == 1 then
            tab:SetPoint("TOPLEFT", parentFrame, "BOTTOMLEFT", 12, 2)
        else
            tab:SetPoint("LEFT", tabs[i-1], "RIGHT", -15, 0)
        end

        -- Tab click handler
        tab:SetScript("OnClick", function(self)
            Settings:SelectTab(self:GetID())
        end)

        tabs[i] = tab
    end

    -- Set up PanelTemplates
    PanelTemplates_SetNumTabs(parentFrame, NUM_TABS)
    parentFrame.tabs = tabs

    if ns.Debug then
        ns.Debug:Verbose("SETTINGS", "Created %d tab buttons", NUM_TABS)
    end
end

--[[
    Create content frames for each tab
    @param parentFrame Frame - The parent settings frame
]]--
function Settings:CreateTabContents(parentFrame)
    if not parentFrame then return end

    -- Create content frames for each tab (anchored to Inset)
    local inset = parentFrame.Inset
    if not inset then
        if ns.Debug then
            ns.Debug:Error("SETTINGS", "Inset frame not found, cannot create tab contents")
        end
        return
    end

    for i = 1, NUM_TABS do
        local contentFrame = CreateFrame("Frame", "$parent" .. TAB_NAMES[i] .. "Content", inset)
        contentFrame:SetAllPoints(inset)
        contentFrame:Hide() -- Initially hide all tabs

        tabContents[i] = contentFrame

        if ns.Debug then
            ns.Debug:Verbose("SETTINGS", "Created content frame for %s tab", TAB_NAMES[i])
        end
    end

    -- Store references for easy access
    Settings.mainTab = tabContents[1]
    Settings.lootTab = tabContents[2]
    Settings.debugTab = tabContents[3]
    
    -- Populate tab contents
    self:PopulateMainTab()
    self:PopulateLootTab()
    self:PopulateDebugTab()
end

--[[
    Populate the Main tab with roster and settings
]]--
function Settings:PopulateMainTab()
    local mainTab = self.mainTab
    if not mainTab then return end

    -- Create scroll frame for roster
    local scrollFrame = CreateFrame("ScrollFrame", "$parentRosterScroll", mainTab, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", mainTab, "TOPLEFT", 10, -10)
    scrollFrame:SetSize(560, 375) -- 15 rows * 25px height
    
    -- Create scroll child
    local scrollChild = CreateFrame("Frame", "$parentScrollChild", scrollFrame)
    scrollChild:SetSize(560, 375)
    scrollFrame:SetScrollChild(scrollChild)
    
    -- Store references
    self.mainScrollFrame = scrollFrame
    self.mainScrollChild = scrollChild
    self.mainRosterRows = {}
    
    -- Create roster rows (15 visible rows)
    local rowHeight = 25
    local maxRows = 15
    
    for i = 1, maxRows do
        local row = CreateFrame("Frame", "$parentRow" .. i, scrollChild)
        row:SetSize(540, rowHeight)
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 5, -(i-1) * rowHeight)
        
        -- Name label (300px wide)
        local nameLabel = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        nameLabel:SetPoint("LEFT", row, "LEFT", 5, 0)
        nameLabel:SetWidth(300)
        nameLabel:SetJustifyH("LEFT")
        row.name = nameLabel
        
        -- Points label (100px wide)
        local pointsLabel = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        pointsLabel:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
        pointsLabel:SetWidth(100)
        pointsLabel:SetJustifyH("RIGHT")
        row.points = pointsLabel
        
        row:Hide() -- Initially hide
        self.mainRosterRows[i] = row
    end
    
    -- Add settings section below roster
    local settingsHeader = mainTab:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    settingsHeader:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT", 5, -10)
    settingsHeader:SetText("Settings")
    
    -- Add version string
    local versionText = mainTab:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    versionText:SetPoint("TOPLEFT", settingsHeader, "BOTTOMLEFT", 10, -5)
    
    -- Get version from TOC metadata
    local version = C_AddOns.GetAddOnMetadata("SpectrumFederation", "Version") or "Unknown"
    versionText:SetText("Version: " .. version)
    
    -- Add backdrop selector
    self:CreateBackdropSelector(mainTab)
    
    -- Initial roster refresh
    self:RefreshMainRoster()
    
    if ns.Debug then
        ns.Debug:Info("SETTINGS", "Main tab populated with %d roster rows", maxRows)
    end
end

--[[
    Refresh the roster display in Main tab
]]--
function Settings:RefreshMainRoster()
    if not self.mainRosterRows or not ns.Core then return end
    
    -- Get active profile roster
    local profile = ns.Core:GetActiveProfile()
    if not profile then
        if ns.Debug then
            ns.Debug:Warn("SETTINGS", "No active profile found for roster refresh")
        end
        return
    end
    
    -- Get roster entries
    local roster = ns.Core:GetRoster()
    
    -- Sort roster by character key
    local sortedRoster = {}
    for charKey, _ in pairs(roster) do
        table.insert(sortedRoster, charKey)
    end
    table.sort(sortedRoster)
    
    -- Update rows
    for i, row in ipairs(self.mainRosterRows) do
        if sortedRoster[i] then
            local charKey = sortedRoster[i]
            local points = ns.Core:GetPoints(charKey) or 0
            
            row.name:SetText(charKey)
            row.points:SetText(tostring(points))
            row:Show()
        else
            row:Hide()
        end
    end
    
    if ns.Debug then
        ns.Debug:Verbose("SETTINGS", "Refreshed main roster with %d entries", #sortedRoster)
    end
end

--[[
    Populate the Loot tab with log viewer
]]--
function Settings:PopulateLootTab()
    local lootTab = self.lootTab
    if not lootTab then return end
    
    -- Initialize filter state
    self.lootFilters = {
        character = "",
        profile = "current", -- "current" or "all"
    }
    
    -- Create filter controls at top
    self:CreateLootLogFilters(lootTab)
    
    -- Column headers (moved down to make room for filters)
    local headers = {"Timestamp", "Character", "Change", "Reason", "Profile"}
    local widths = {120, 140, 60, 140, 100} -- Total: 560px
    
    local xOffset = 10
    for i, headerText in ipairs(headers) do
        local header = lootTab:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        header:SetPoint("TOPLEFT", lootTab, "TOPLEFT", xOffset, -40) -- Moved down from -10
        header:SetText(headerText)
        header:SetWidth(widths[i])
        header:SetJustifyH("LEFT")
        xOffset = xOffset + widths[i]
    end
    
    -- Create scroll frame for logs (moved down to make room for filters)
    local scrollFrame = CreateFrame("ScrollFrame", "$parentLogScroll", lootTab, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", lootTab, "TOPLEFT", 10, -65) -- Moved down from -35
    scrollFrame:SetSize(560, 330) -- Reduced height from 360 to make room for filters
    
    -- Create scroll child
    local scrollChild = CreateFrame("Frame", "$parentScrollChild", scrollFrame)
    scrollChild:SetSize(560, 360)
    scrollFrame:SetScrollChild(scrollChild)
    
    -- Store references
    self.lootScrollFrame = scrollFrame
    self.lootScrollChild = scrollChild
    self.logRows = {}
    
    -- Create log rows (12 visible rows)
    local rowHeight = 30
    local maxRows = 12
    
    for i = 1, maxRows do
        local row = self:CreateLogRow(scrollChild, i, widths, rowHeight)
        self.logRows[i] = row
    end
    
    -- Create profile management section below log viewer
    self:CreateProfileSection(lootTab, scrollFrame)
    
    -- Create loot window controls section
    self:CreateLootWindowSection(lootTab)
    
    -- Initial log refresh
    self:RefreshLootLog()
    
    if ns.Debug then
        ns.Debug:Info("SETTINGS", "Loot tab populated with %d log rows", maxRows)
    end
end

--[[
    Create filter controls for loot log
    @param lootTab Frame - The loot tab frame
]]--
function Settings:CreateLootLogFilters(lootTab)
    local filterFrame = CreateFrame("Frame", "$parentFilters", lootTab)
    filterFrame:SetPoint("TOPLEFT", lootTab, "TOPLEFT", 10, -5)
    filterFrame:SetSize(560, 30)
    
    -- Character filter label
    local charLabel = filterFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    charLabel:SetPoint("LEFT", filterFrame, "LEFT", 0, 0)
    charLabel:SetText("Character:")
    
    -- Character filter EditBox
    local charEdit = CreateFrame("EditBox", "$parentCharFilter", filterFrame, "InputBoxTemplate")
    charEdit:SetPoint("LEFT", charLabel, "RIGHT", 5, 0)
    charEdit:SetSize(120, 20)
    charEdit:SetAutoFocus(false)
    charEdit:SetScript("OnTextChanged", function(self)
        Settings.lootFilters.character = self:GetText():lower()
        Settings:ApplyLootLogFilters()
    end)
    charEdit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    self.lootCharFilter = charEdit
    
    -- Profile filter label
    local profileLabel = filterFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    profileLabel:SetPoint("LEFT", charEdit, "RIGHT", 15, 0)
    profileLabel:SetText("Profile:")
    
    -- Profile filter dropdown
    local profileDropdown = CreateFrame("Frame", "$parentProfileFilter", filterFrame, "UIDropDownMenuTemplate")
    profileDropdown:SetPoint("LEFT", profileLabel, "RIGHT", -10, -2)
    UIDropDownMenu_SetWidth(profileDropdown, 100)
    
    UIDropDownMenu_Initialize(profileDropdown, function(self, level)
        -- Current profile option
        local info = UIDropDownMenu_CreateInfo()
        info.text = "Current"
        info.checked = (Settings.lootFilters.profile == "current")
        info.func = function()
            Settings.lootFilters.profile = "current"
            UIDropDownMenu_SetText(profileDropdown, "Current")
            Settings:ApplyLootLogFilters()
        end
        UIDropDownMenu_AddButton(info)
        
        -- All profiles option
        info = UIDropDownMenu_CreateInfo()
        info.text = "All Profiles"
        info.checked = (Settings.lootFilters.profile == "all")
        info.func = function()
            Settings.lootFilters.profile = "all"
            UIDropDownMenu_SetText(profileDropdown, "All Profiles")
            Settings:ApplyLootLogFilters()
        end
        UIDropDownMenu_AddButton(info)
    end)
    
    UIDropDownMenu_SetText(profileDropdown, "Current")
    self.lootProfileFilter = profileDropdown
end

--[[
    Apply filters to loot log display
]]--
function Settings:ApplyLootLogFilters()
    -- Just refresh with current filter settings
    self:RefreshLootLog()
end

--[[
    Create profile management section in Loot tab
    @param lootTab Frame - The loot tab frame
    @param scrollFrame Frame - The log scroll frame (for positioning)
]]--
function Settings:CreateProfileSection(lootTab, scrollFrame)
    local profileHeader = lootTab:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    profileHeader:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT", 0, -15)
    profileHeader:SetText("Profile Management")
    
    -- Profile dropdown
    local profileDropdown = CreateFrame("Frame", "$parentProfileDropdown", lootTab, "UIDropDownMenuTemplate")
    profileDropdown:SetPoint("TOPLEFT", profileHeader, "BOTTOMLEFT", -15, -5)
    UIDropDownMenu_SetWidth(profileDropdown, 150)
    
    UIDropDownMenu_Initialize(profileDropdown, function(self, level)
        if not ns.Core then return end
        
        local profiles = ns.Core:GetProfileList()
        local activeProfile = ns.Core:GetActiveProfile()
        local activeName = activeProfile and activeProfile.name or "Default"
        
        for _, name in ipairs(profiles) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = name
            info.checked = (name == activeName)
            info.func = function()
                Settings:SwitchProfile(name)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    
    -- Set initial dropdown text
    if ns.Core then
        local activeProfile = ns.Core:GetActiveProfile()
        if activeProfile then
            UIDropDownMenu_SetText(profileDropdown, activeProfile.name)
        end
    end
    
    self.profileDropdown = profileDropdown
    
    -- Create Profile button
    local createBtn = CreateFrame("Button", "$parentCreateProfile", lootTab, "UIPanelButtonTemplate")
    createBtn:SetPoint("LEFT", profileDropdown, "RIGHT", 10, 2)
    createBtn:SetSize(100, 22)
    createBtn:SetText("Create Profile")
    createBtn:SetScript("OnClick", function()
        Settings:ShowCreateProfileDialog()
    end)
    
    -- Delete Profile button
    local deleteBtn = CreateFrame("Button", "$parentDeleteProfile", lootTab, "UIPanelButtonTemplate")
    deleteBtn:SetPoint("LEFT", createBtn, "RIGHT", 5, 0)
    deleteBtn:SetSize(100, 22)
    deleteBtn:SetText("Delete Profile")
    deleteBtn:SetScript("OnClick", function()
        Settings:ShowDeleteProfileDialog()
    end)
    
    self.profileSection = profileHeader
end

--[[
    Create loot window controls section in Loot tab
    @param lootTab Frame - The loot tab frame
]]--
function Settings:CreateLootWindowSection(lootTab)
    local lootHeader = lootTab:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    lootHeader:SetPoint("BOTTOMLEFT", lootTab, "BOTTOMLEFT", 10, 40)
    lootHeader:SetText("Loot Window")
    
    -- Show Loot Window checkbox
    local showCheckbox = CreateFrame("CheckButton", "$parentShowLoot", lootTab, "UICheckButtonTemplate")
    showCheckbox:SetPoint("TOPLEFT", lootHeader, "BOTTOMLEFT", 5, -5)
    showCheckbox.text = showCheckbox:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    showCheckbox.text:SetPoint("LEFT", showCheckbox, "RIGHT", 5, 0)
    showCheckbox.text:SetText("Show Loot Window")
    
    if ns.db and ns.db.ui and ns.db.ui.lootFrame then
        showCheckbox:SetChecked(ns.db.ui.lootFrame.isShown)
    end
    
    showCheckbox:SetScript("OnClick", function(self)
        if ns.UI then
            if self:GetChecked() then
                ns.UI:Show()
            else
                ns.UI:Hide()
            end
        end
    end)
    
    self.lootWindowCheckbox = showCheckbox
    
    -- Manual Sync button
    local syncBtn = CreateFrame("Button", "$parentManualSync", lootTab, "UIPanelButtonTemplate")
    syncBtn:SetPoint("LEFT", showCheckbox, "RIGHT", 150, 0)
    syncBtn:SetSize(120, 22)
    syncBtn:SetText("Manual Sync")
    syncBtn:SetScript("OnClick", function()
        if ns.Sync and ns.Sync.StartManualSync then
            ns.Sync:StartManualSync()
        else
            print("[Spectrum Federation] Manual sync not yet implemented")
        end
    end)
end

--[[
    Switch to a different profile
    @param profileName string - Name of profile to switch to
]]--
function Settings:SwitchProfile(profileName)
    if not ns.Core then return end
    
    -- Switch the active profile
    local success = ns.Core:SetActiveProfile(profileName)
    
    if success then
        -- Update dropdown text
        if self.profileDropdown then
            UIDropDownMenu_SetText(self.profileDropdown, profileName)
        end
        
        -- Refresh all displays
        self:RefreshMainRoster()
        self:RefreshLootLog()
        
        print("[Spectrum Federation] Switched to profile: " .. profileName)
    else
        print("[Spectrum Federation] Failed to switch profile")
    end
end

--[[
    Show dialog to create a new profile
]]--
function Settings:ShowCreateProfileDialog()
    StaticPopup_Show("SPECTRUM_CREATE_PROFILE")
end

--[[
    Show dialog to delete the current profile
]]--
function Settings:ShowDeleteProfileDialog()
    if not ns.Core then return end
    
    local activeProfile = ns.Core:GetActiveProfile()
    if activeProfile then
        StaticPopupDialogs["SPECTRUM_DELETE_PROFILE"].text = "Delete profile '" .. activeProfile.name .. "'? This cannot be undone."
        StaticPopup_Show("SPECTRUM_DELETE_PROFILE")
    end
end

--[[
    Get a backdrop style preset
    @param styleName string - Name of the style preset
    @return table - Backdrop style configuration
]]--
function Settings:GetBackdropStyle(styleName)
    return BACKDROP_STYLES[styleName or "Default"]
end

--[[
    Apply backdrop to a specific frame
    @param frame Frame - The frame to apply backdrop to
    @param styleName string - Name of the style preset (optional)
]]--
function Settings:ApplyBackdropToFrame(frame, styleName)
    if not frame then return end
    
    styleName = styleName or (ns.db.settings and ns.db.settings.backdropStyle) or "Default"
    local style = self:GetBackdropStyle(styleName)
    
    if not style then
        if ns.Debug then
            ns.Debug:Warn("SETTINGS", "Backdrop style not found: %s", styleName)
        end
        return
    end
    
    -- Set backdrop
    frame:SetBackdrop({
        bgFile = style.bgFile,
        edgeFile = style.edgeFile,
        tile = style.tile,
        tileSize = style.tileSize,
        edgeSize = style.edgeSize,
        insets = style.insets,
    })
    
    -- Set colors
    frame:SetBackdropColor(unpack(style.backdropColor))
    frame:SetBackdropBorderColor(unpack(style.backdropBorderColor))
    
    if ns.Debug then
        ns.Debug:Verbose("SETTINGS", "Applied backdrop style '%s' to frame", styleName)
    end
end

--[[
    Apply backdrop to all addon frames
    @param styleName string - Name of the style preset
]]--
function Settings:ApplyBackdropToAllFrames(styleName)
    -- Save preference
    if not ns.db.settings then
        ns.db.settings = {}
    end
    ns.db.settings.backdropStyle = styleName
    
    -- Apply to settings window
    if settingsFrame then
        self:ApplyBackdropToFrame(settingsFrame, styleName)
    end
    
    -- Apply to loot window (if exists)
    if ns.UI and ns.UI.lootFrame then
        self:ApplyBackdropToFrame(ns.UI.lootFrame, styleName)
    end
    
    if ns.Debug then
        ns.Debug:Info("SETTINGS", "Applied backdrop style '%s' to all frames", styleName)
    end
    
    print("[Spectrum Federation] Window style changed to: " .. styleName)
end

--[[
    Create backdrop selector in Main tab
    @param mainTab Frame - The main tab frame
]]--
function Settings:CreateBackdropSelector(mainTab)
    local styleHeader = mainTab:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    styleHeader:SetPoint("BOTTOMLEFT", mainTab, "BOTTOMLEFT", 10, 10)
    styleHeader:SetText("Window Style")
    
    local styleDropdown = CreateFrame("Frame", "$parentStyleDropdown", mainTab, "UIDropDownMenuTemplate")
    styleDropdown:SetPoint("TOPLEFT", styleHeader, "BOTTOMLEFT", -15, -5)
    UIDropDownMenu_SetWidth(styleDropdown, 150)
    
    UIDropDownMenu_Initialize(styleDropdown, function(self, level)
        local currentStyle = (ns.db.settings and ns.db.settings.backdropStyle) or "Default"
        
        -- Create sorted list of style names
        local styleNames = {}
        for styleName, _ in pairs(BACKDROP_STYLES) do
            table.insert(styleNames, styleName)
        end
        table.sort(styleNames)
        
        for _, styleName in ipairs(styleNames) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = styleName
            info.checked = (styleName == currentStyle)
            info.func = function()
                Settings:ApplyBackdropToAllFrames(styleName)
                UIDropDownMenu_SetText(styleDropdown, styleName)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    
    -- Set initial dropdown text
    local currentStyle = (ns.db.settings and ns.db.settings.backdropStyle) or "Default"
    UIDropDownMenu_SetText(styleDropdown, currentStyle)
    
    self.backdropDropdown = styleDropdown
end

--[[
    Create a single log row frame
    @param parent Frame - Parent frame
    @param index number - Row index
    @param widths table - Column widths
    @param height number - Row height
    @return Frame - Created row frame
]]--
function Settings:CreateLogRow(parent, index, widths, height)
    local row = CreateFrame("Frame", "$parentRow" .. index, parent)
    row:SetSize(560, height)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index-1) * height)
    
    local xOffset = 5
    
    -- Timestamp
    local timestamp = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    timestamp:SetPoint("LEFT", row, "LEFT", xOffset, 0)
    timestamp:SetWidth(widths[1])
    timestamp:SetJustifyH("LEFT")
    row.timestamp = timestamp
    xOffset = xOffset + widths[1]
    
    -- Character
    local character = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    character:SetPoint("LEFT", row, "LEFT", xOffset, 0)
    character:SetWidth(widths[2])
    character:SetJustifyH("LEFT")
    row.character = character
    xOffset = xOffset + widths[2]
    
    -- Change
    local change = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    change:SetPoint("LEFT", row, "LEFT", xOffset, 0)
    change:SetWidth(widths[3])
    change:SetJustifyH("RIGHT")
    row.change = change
    xOffset = xOffset + widths[3]
    
    -- Reason
    local reason = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    reason:SetPoint("LEFT", row, "LEFT", xOffset, 0)
    reason:SetWidth(widths[4])
    reason:SetJustifyH("LEFT")
    row.reason = reason
    xOffset = xOffset + widths[4]
    
    -- Profile
    local profile = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    profile:SetPoint("LEFT", row, "LEFT", xOffset, 0)
    profile:SetWidth(widths[5])
    profile:SetJustifyH("LEFT")
    row.profile = profile
    
    row:Hide() -- Initially hidden
    return row
end

--[[
    Refresh the loot log display
]]--
function Settings:RefreshLootLog()
    if not self.logRows or not ns.LootLog or not ns.Core then return end
    
    -- Get active profile
    local profile = ns.Core:GetActiveProfile()
    if not profile then
        if ns.Debug then
            ns.Debug:Warn("SETTINGS", "No active profile found for log refresh")
        end
        return
    end
    
    -- Get logs based on profile filter
    local logs = {}
    if self.lootFilters and self.lootFilters.profile == "all" then
        -- Get logs from all profiles
        if ns.db and ns.db.profiles then
            for profileName, profileData in pairs(ns.db.profiles) do
                if profileData.logs then
                    for _, log in pairs(profileData.logs) do
                        table.insert(logs, log)
                    end
                end
            end
        end
    else
        -- Get logs for current profile only
        logs = ns.LootLog:GetEntriesForProfile(profile.name) or {}
    end
    
    -- Apply character filter
    if self.lootFilters and self.lootFilters.character ~= "" then
        local filtered = {}
        local filterText = self.lootFilters.character
        for _, log in ipairs(logs) do
            if log.charKey and log.charKey:lower():find(filterText, 1, true) then
                table.insert(filtered, log)
            end
        end
        logs = filtered
    end
    
    -- Sort by ID descending (newest first)
    table.sort(logs, function(a, b) return a.id > b.id end)
    
    -- Populate rows
    for i, row in ipairs(self.logRows) do
        local log = logs[i]
        
        if log then
            -- Format timestamp
            row.timestamp:SetText(date("%Y-%m-%d %H:%M:%S", log.timestamp))
            
            -- Character name
            row.character:SetText(log.charKey)
            
            -- Format change with color
            local changeText = (log.change >= 0) and ("+" .. log.change) or tostring(log.change)
            row.change:SetText(changeText)
            if log.change >= 0 then
                row.change:SetTextColor(0, 1, 0) -- Green for positive
            else
                row.change:SetTextColor(1, 0, 0) -- Red for negative
            end
            
            -- Truncate reason if too long
            local reasonText = log.reason or ""
            if #reasonText > 20 then
                reasonText = reasonText:sub(1, 17) .. "..."
            end
            row.reason:SetText(reasonText)
            
            -- Profile name
            row.profile:SetText(log.profile or profile.name)
            
            row:Show()
        else
            row:Hide()
        end
    end
    
    if ns.Debug then
        ns.Debug:Verbose("SETTINGS", "Refreshed loot log with %d entries", math.min(#logs, #self.logRows))
    end
end

--[[
    Create filter controls for debug log
    @param debugTab Frame - The debug tab frame
]]--
function Settings:CreateDebugLogFilters(debugTab)
    local filterFrame = CreateFrame("Frame", "$parentFilters", debugTab)
    filterFrame:SetPoint("TOPLEFT", debugTab, "TOPLEFT", 10, -5)
    filterFrame:SetSize(560, 30)
    
    -- Level filter label
    local levelLabel = filterFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    levelLabel:SetPoint("LEFT", filterFrame, "LEFT", 0, 0)
    levelLabel:SetText("Level:")
    
    -- Level filter dropdown
    local levelDropdown = CreateFrame("Frame", "$parentLevelFilter", filterFrame, "UIDropDownMenuTemplate")
    levelDropdown:SetPoint("LEFT", levelLabel, "RIGHT", -10, -2)
    UIDropDownMenu_SetWidth(levelDropdown, 100)
    
    UIDropDownMenu_Initialize(levelDropdown, function(self, level)
        local levels = {"All", "VERBOSE", "INFO", "WARN", "ERROR"}
        for _, lvl in ipairs(levels) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = lvl
            info.checked = (Settings.debugFilters.level == lvl)
            info.func = function()
                Settings.debugFilters.level = lvl
                UIDropDownMenu_SetText(levelDropdown, lvl)
                Settings:ApplyDebugLogFilters()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    
    UIDropDownMenu_SetText(levelDropdown, "All")
    self.debugLevelFilter = levelDropdown
    
    -- Category filter label
    local catLabel = filterFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    catLabel:SetPoint("LEFT", levelDropdown, "RIGHT", 10, 2)
    catLabel:SetText("Category:")
    
    -- Category filter EditBox
    local catEdit = CreateFrame("EditBox", "$parentCatFilter", filterFrame, "InputBoxTemplate")
    catEdit:SetPoint("LEFT", catLabel, "RIGHT", 5, 0)
    catEdit:SetSize(120, 20)
    catEdit:SetAutoFocus(false)
    catEdit:SetScript("OnTextChanged", function(self)
        Settings.debugFilters.category = self:GetText():lower()
        Settings:ApplyDebugLogFilters()
    end)
    catEdit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    self.debugCatFilter = catEdit
end

--[[
    Apply filters to debug log display
]]--
function Settings:ApplyDebugLogFilters()
    -- Just refresh with current filter settings
    self:RefreshDebugLog()
end

--[[
    Populate the Debug tab with log viewer and controls
]]--
function Settings:PopulateDebugTab()
    local debugTab = self.debugTab
    if not debugTab then return end
    
    -- Initialize filter state
    self.debugFilters = {
        level = "All",
        category = "",
    }
    
    -- Create filter controls at top
    self:CreateDebugLogFilters(debugTab)
    
    -- Create scrolling text frame for debug logs (moved down for filters)
    local scrollFrame = CreateFrame("ScrollFrame", "$parentDebugScroll", debugTab, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", debugTab, "TOPLEFT", 10, -40) -- Moved down from -10
    scrollFrame:SetSize(560, 330) -- Reduced height from 360
    
    -- Create EditBox (read-only, multi-line)
    local logText = CreateFrame("EditBox", "$parentLogText", scrollFrame)
    logText:SetMultiLine(true)
    logText:SetAutoFocus(false)
    logText:SetFontObject(ChatFontNormal)
    logText:SetWidth(540)
    logText:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    scrollFrame:SetScrollChild(logText)
    
    self.debugScrollFrame = scrollFrame
    self.debugLogText = logText
    
    -- Create controls section below log viewer
    local controlFrame = CreateFrame("Frame", "$parentControls", debugTab)
    controlFrame:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT", 0, -10)
    controlFrame:SetSize(560, 60)
    
    -- Enable Debug checkbox
    local enableCheckbox = CreateFrame("CheckButton", "$parentEnableDebug", controlFrame, "UICheckButtonTemplate")
    enableCheckbox:SetPoint("TOPLEFT", controlFrame, "TOPLEFT", 5, 0)
    enableCheckbox.text = enableCheckbox:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    enableCheckbox.text:SetPoint("LEFT", enableCheckbox, "RIGHT", 5, 0)
    enableCheckbox.text:SetText("Enable Debug Logging")
    
    if ns.Debug then
        enableCheckbox:SetChecked(ns.Debug:IsEnabled())
    end
    
    enableCheckbox:SetScript("OnClick", function(self)
        if ns.Debug then
            ns.Debug:SetEnabled(self:GetChecked())
            print(self:GetChecked() and "[Spectrum Federation] Debug logging enabled" or "[Spectrum Federation] Debug logging disabled")
            Settings:RefreshDebugLog()
        end
    end)
    
    -- Clear Logs button
    local clearBtn = CreateFrame("Button", "$parentClearLogs", controlFrame, "UIPanelButtonTemplate")
    clearBtn:SetPoint("TOPLEFT", enableCheckbox, "BOTTOMLEFT", 0, -10)
    clearBtn:SetSize(100, 22)
    clearBtn:SetText("Clear Logs")
    clearBtn:SetScript("OnClick", function()
        Settings:ShowClearLogsDialog()
    end)
    
    -- Refresh button
    local refreshBtn = CreateFrame("Button", "$parentRefreshLogs", controlFrame, "UIPanelButtonTemplate")
    refreshBtn:SetPoint("LEFT", clearBtn, "RIGHT", 5, 0)
    refreshBtn:SetSize(100, 22)
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", function()
        Settings:RefreshDebugLog()
    end)
    
    -- Initial refresh
    self:RefreshDebugLog()
    
    if ns.Debug then
        ns.Debug:Info("SETTINGS", "Debug tab populated")
    end
end

--[[
    Refresh the debug log display
]]--
function Settings:RefreshDebugLog()
    if not self.debugLogText or not ns.Debug then return end
    
    -- Get all debug logs (max 500)
    local logs = ns.Debug:GetRecentLogs(500)
    
    if not logs or #logs == 0 then
        self.debugLogText:SetText("No debug logs available.")
        return
    end
    
    -- Apply filters
    if self.debugFilters then
        local filtered = {}
        for _, log in ipairs(logs) do
            local levelMatch = (self.debugFilters.level == "All" or log.level == self.debugFilters.level)
            local catMatch = (self.debugFilters.category == "" or 
                            (log.category and log.category:lower():find(self.debugFilters.category, 1, true)))
            
            if levelMatch and catMatch then
                table.insert(filtered, log)
            end
        end
        logs = filtered
    end
    
    if #logs == 0 then
        self.debugLogText:SetText("No logs match the current filters.")
        return
    end
    
    -- Format logs in reverse order (newest first)
    local lines = {}
    for i = #logs, 1, -1 do
        local log = logs[i]
        local timestamp = date("%H:%M:%S", log.timestamp)
        local line = string.format("[%s] [%s] [%s] %s", 
            timestamp, log.level, log.category, log.message)
        table.insert(lines, line)
    end
    
    self.debugLogText:SetText(table.concat(lines, "\n"))
    self.debugLogText:SetCursorPosition(0) -- Scroll to top
    
    if ns.Debug then
        ns.Debug:Verbose("SETTINGS", "Refreshed debug log with %d entries", #logs)
    end
end

--[[
    Show confirmation dialog for clearing debug logs
]]--
function Settings:ShowClearLogsDialog()
    StaticPopup_Show("SPECTRUM_CLEAR_DEBUG_LOGS")
end

--[[
    Select and display a specific tab
    @param tabNum number - The tab number to select (1-3)
]]--
function Settings:SelectTab(tabNum)
    if not settingsFrame or not tabContents then return end

    -- Validate tab number
    if tabNum < 1 or tabNum > NUM_TABS then
        if ns.Debug then
            ns.Debug:Warn("SETTINGS", "Invalid tab number: %d", tabNum)
        end
        return
    end

    -- Hide all tab contents
    for i = 1, NUM_TABS do
        if tabContents[i] then
            tabContents[i]:Hide()
        end
    end

    -- Show selected tab content
    if tabContents[tabNum] then
        tabContents[tabNum]:Show()
    end

    -- Update tab button states
    PanelTemplates_SetTab(settingsFrame, tabNum)

    -- Save active tab to database
    if ns.db.ui.settingsFrame then
        ns.db.ui.settingsFrame.activeTab = tabNum
    end

    if ns.Debug then
        ns.Debug:Verbose("SETTINGS", "Selected tab %d (%s)", tabNum, TAB_NAMES[tabNum])
    end
end

--[[
    Initialize the settings module
    Called during addon initialization
]]--
function Settings:Initialize()
    -- Ensure database structure exists
    if not ns.db.ui.settingsFrame then
        ns.db.ui.settingsFrame = {
            position = nil,
            isShown = false,
            activeTab = 1,
        }
    end

    -- Create the frame
    self:CreateSettingsFrame()

    -- Register StaticPopup dialogs
    self:RegisterStaticPopups()
    
    if ns.Debug then
        ns.Debug:Info("SETTINGS", "Settings module initialized")
    end
end

--[[
    Register StaticPopup dialogs for settings UI
]]--
function Settings:RegisterStaticPopups()
    -- Clear Debug Logs confirmation
    StaticPopupDialogs["SPECTRUM_CLEAR_DEBUG_LOGS"] = {
        text = "Clear all debug logs? This cannot be undone.",
        button1 = "Clear",
        button2 = "Cancel",
        OnAccept = function()
            if ns.debugDB and ns.debugDB.logs then
                ns.debugDB.logs = {}
                Settings:RefreshDebugLog()
                print("[Spectrum Federation] Debug logs cleared")
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    
    -- Create Profile dialog
    StaticPopupDialogs["SPECTRUM_CREATE_PROFILE"] = {
        text = "Enter a name for the new profile:",
        button1 = "Create",
        button2 = "Cancel",
        hasEditBox = true,
        OnAccept = function(self)
            local profileName = self.editBox:GetText()
            if profileName and profileName ~= "" then
                if ns.Core then
                    local success, err = ns.Core:CreateProfile(profileName)
                    if success then
                        print("[Spectrum Federation] Created profile: " .. profileName)
                        -- Refresh dropdown
                        if Settings.profileDropdown then
                            UIDropDownMenu_Initialize(Settings.profileDropdown, function(dropdown, level)
                                local profiles = ns.Core:GetProfileList()
                                local activeProfile = ns.Core:GetActiveProfile()
                                local activeName = activeProfile and activeProfile.name or "Default"
                                
                                for _, name in ipairs(profiles) do
                                    local info = UIDropDownMenu_CreateInfo()
                                    info.text = name
                                    info.checked = (name == activeName)
                                    info.func = function()
                                        Settings:SwitchProfile(name)
                                    end
                                    UIDropDownMenu_AddButton(info)
                                end
                            end)
                        end
                    else
                        print("[Spectrum Federation] Failed to create profile: " .. (err or "unknown error"))
                    end
                end
            end
        end,
        OnShow = function(self)
            self.editBox:SetFocus()
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            StaticPopup_OnClick(parent, 1)
        end,
        EditBoxOnEscapePressed = function(self)
            self:GetParent():Hide()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    
    -- Delete Profile confirmation
    StaticPopupDialogs["SPECTRUM_DELETE_PROFILE"] = {
        text = "Delete profile? This cannot be undone.",
        button1 = "Delete",
        button2 = "Cancel",
        OnAccept = function()
            if ns.Core then
                local activeProfile = ns.Core:GetActiveProfile()
                if activeProfile then
                    local success, err = ns.Core:DeleteProfile(activeProfile.name)
                    if success then
                        print("[Spectrum Federation] Deleted profile: " .. activeProfile.name)
                        -- Refresh displays
                        Settings:RefreshMainRoster()
                        Settings:RefreshLootLog()
                        -- Update dropdown
                        if Settings.profileDropdown then
                            local newActive = ns.Core:GetActiveProfile()
                            if newActive then
                                UIDropDownMenu_SetText(Settings.profileDropdown, newActive.name)
                            end
                        end
                    else
                        print("[Spectrum Federation] Failed to delete profile: " .. (err or "unknown error"))
                    end
                end
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
end
