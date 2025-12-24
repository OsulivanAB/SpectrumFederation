-- Grab the namespace
local addonName, SF = ...

local LootWindow = {}
SF.LootWindow = LootWindow

-- Function to load the Loot Helper UI window state from the database
-- @param frame: The UI frame to apply the settings to.
-- @return: none
local function SaveFrameState(frame)

    if not SF.lootHelperDB or not SF.lootHelperDB.windowSettings then
        if SF.Debug then SF.Debug:Warn("LOOT_UI", "No lootHelperDB found to save frame state") end
        return
    end
    
    local db = SF.lootHelperDB.windowSettings
    
    -- Size
    db.width = frame:GetWidth()
    db.height = frame:GetHeight()

    -- Position
    local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint(1)
    db.point = point
    db.relativePoint = relativePoint
    db.x = xOfs
    db.y = yOfs

    -- Visibility
    db.shown = frame:IsShown()

    if SF.Debug then SF.Debug:Info("LOOT_UI", "Saved Loot Helper window state") end

end

-- Function to apply the Loot Helper UI window state from the database
-- @param frame: The UI frame to apply the settings to.
-- @return: none
local function ApplyFrameState(frame)

    if not SF.lootHelperDB or not SF.lootHelperDB.windowSettings then
        if SF.Debug then SF.Debug:Warn("LOOT_UI", "No lootHelperDB found to apply frame state") end
        return
    end

    local db = SF.lootHelperDB.windowSettings

    frame:ClearAllPoints()
    frame:SetPoint(
        db.point,
        UIParent,
        db.relativePoint,
        db.x,
        db.y
    )
    frame:SetSize(
        db.width,
        db.height
    )

    if db.shown then
        frame:Show()
    else
        frame:Hide()
    end
end

-- Function to set enabled/disabled visuals on a frame
-- @param frame: The UI frame to modify.
-- @param enabled: Boolean indicating whether the frame is enabled or disabled.
-- @return: none
local function SetEnabledVisuals(frame, enabled)
    frame.content:SetShown(enabled)
    frame.disabledOverlay:SetShown(not enabled)
end

-- Public method to set the enabled state of the Loot Helper
-- @param enabled: Boolean indicating whether to enable or disable the Loot Helper
-- @return: none
function LootWindow:SetEnabled(enabled)
    -- Update database
    if SF.lootHelperDB and SF.lootHelperDB.windowSettings then
        SF.lootHelperDB.windowSettings.enabled = enabled
    end
    
    -- Update frame visuals if frame exists
    if self.frame then
        SetEnabledVisuals(self.frame, enabled)
        
        -- Show or hide the window based on enabled state
        if enabled then
            self.frame:Show()
        else
            self.frame:Hide()
        end
    end
    
    -- Log the change
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Loot Helper %s", enabled and "enabled" or "disabled")
    end
end

-- Function to create a single member row for the member list
-- @param index: The index of the row in the pool
-- @return: The created row button frame
function LootWindow:CreateMemberRow(index)
    local row = CreateFrame("Button", nil, nil)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    
    -- Store class filename for later color updates
    row.classFilename = nil
    
    -- Class Icon (left-aligned, sized dynamically based on row height)
    local classIcon = row:CreateTexture(nil, "ARTWORK")
    classIcon:SetPoint("LEFT", row, "LEFT", 5, 0)
    -- Size will be set dynamically: ROW_HEIGHT * CLASS_ICON_SIZE_PERCENT
    classIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")  -- Default fallback will assign class icon later
    row.classIcon = classIcon
    
    -- Name - Server text
    local nameText = row:CreateFontString(nil, "OVERLAY", self.FONT_SIZE or "GameFontNormal")
    nameText:SetPoint("LEFT", classIcon, "RIGHT", 5, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetText("Player - Server")
    -- TODO: Font size should be configurable via settings
    row.nameText = nameText
    
    -- Points text (center-aligned)
    local pointsText = row:CreateFontString(nil, "OVERLAY", self.FONT_SIZE or "GameFontNormal")
    pointsText:SetJustifyH("CENTER")
    pointsText:SetText("0")
    -- TODO: Font size should be configurable via settings
    -- TODO: Load actual points value from database when implemented
    row.pointsText = pointsText
    
    -- Up Arrow Button (increase priority)
    local upBtn = CreateFrame("Button", nil, row)
    upBtn:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up")
    upBtn:SetHighlightTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Highlight")
    upBtn:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down")
    upBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Increase Points", 1, 1, 1)
        GameTooltip:Show()
    end)
    upBtn:SetScript("OnLeave", GameTooltip_Hide)
    upBtn:SetScript("OnClick", function()
        -- TODO: Implement priority increase functionality
        if SF.Debug then
            SF.Debug:Verbose("LOOT_HELPER", "Up button clicked for row %d", index)
        end
    end)
    row.upBtn = upBtn
    
    -- Down Arrow Button (decrease priority)
    local downBtn = CreateFrame("Button", nil, row)
    downBtn:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
    downBtn:SetHighlightTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Highlight")
    downBtn:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down")
    downBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Decrease Points", 1, 1, 1)
        GameTooltip:Show()
    end)
    downBtn:SetScript("OnLeave", GameTooltip_Hide)
    downBtn:SetScript("OnClick", function()
        -- TODO: Implement priority decrease functionality
        if SF.Debug then
            SF.Debug:Verbose("LOOT_HELPER", "Down button clicked for row %d", index)
        end
    end)
    row.downBtn = downBtn
    
    -- Gear Button (member settings/gear)
    local gearBtn = CreateFrame("Button", nil, row)
    gearBtn:SetNormalTexture("Interface\\PaperDollInfoFrame\\Character-Plus")
    gearBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
    gearBtn:SetPushedTexture("Interface\\PaperDollInfoFrame\\Character-Plus")
    gearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Gear Settings", 1, 1, 1)
        GameTooltip:Show()
    end)
    gearBtn:SetScript("OnLeave", GameTooltip_Hide)
    gearBtn:SetScript("OnClick", function()
        -- TODO: Implement gear settings functionality
        if SF.Debug then
            SF.Debug:Verbose("LOOT_HELPER", "Gear button clicked for row %d", index)
        end
    end)
    row.gearBtn = gearBtn
    
    -- Function to update row layout when row size changes
    function row:UpdateLayout()
        local rowHeight = self:GetHeight()
        local rowWidth = self:GetWidth()
        
        if not rowHeight or not rowWidth or rowHeight <= 0 or rowWidth <= 0 then
            return
        end
        
        -- Get constants from LootWindow
        local iconSizePercent = SF.LootWindow.CLASS_ICON_SIZE_PERCENT or 0.65
        local btnSizePercent = SF.LootWindow.BUTTON_SIZE_PERCENT or 0.75
        local btnSpacing = SF.LootWindow.BUTTON_SPACING or 4
        local pointsWidth = SF.LootWindow.POINTS_COLUMN_WIDTH or 50
        
        -- Calculate dynamic sizes
        local iconSize = rowHeight * iconSizePercent
        local btnSize = rowHeight * btnSizePercent
        
        -- Update class icon size
        classIcon:SetSize(iconSize, iconSize)
        
        -- Update button sizes and positions (right-aligned)
        gearBtn:SetSize(btnSize, btnSize)
        gearBtn:SetPoint("RIGHT", self, "RIGHT", -5, 0)
        
        downBtn:SetSize(btnSize, btnSize)
        downBtn:SetPoint("RIGHT", gearBtn, "LEFT", -btnSpacing, 0)
        
        upBtn:SetSize(btnSize, btnSize)
        upBtn:SetPoint("RIGHT", downBtn, "LEFT", -btnSpacing, 0)
        
        -- Update points text position and width
        pointsText:SetWidth(pointsWidth)
        pointsText:SetPoint("RIGHT", upBtn, "LEFT", -btnSpacing * 2, 0)
        
        -- Update name text width (fill remaining space)
        local nameWidth = rowWidth - iconSize - pointsWidth - (btnSize * 3) - (btnSpacing * 5) - 20
        nameText:SetWidth(nameWidth)
    end
    
    return row
end

-- Function to create the Loot Helper UI window
-- @return: The created frame
function LootWindow:Create()

    -- Check if frame already exists
    if self.frame then
        return self.frame
    end

    if not SF.lootHelperDB or not SF.lootHelperDB.windowSettings then
        if SF.Debug then SF.Debug:Warn("LOOT_UI", "No lootHelperDB found to create frame") end
        return
    end

    local db = SF.lootHelperDB.windowSettings

    -- Create Main Window
    local frame = CreateFrame("Frame", "SpectrumFederationLootHelperWindow", UIParent, "BackdropTemplate")
    frame:SetSize(db.width, db.height)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("DIALOG")

    -- Backdrop
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0.05, 0.05, 0.07, 0.95)  -- Dark background

    -- Title bar (drag handle)
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(14)
    titleBar:SetPoint("TOPLEFT", 6, -6)
    titleBar:SetPoint("TOPRIGHT", -6, -6)
    titleBar:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-Tooltip-Background",
        title = true,
        titleSize = 16
    })
    titleBar:SetBackdropColor(0.12, 0.12, 0.16, 0.95)   -- Slightly lighter for title bar

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalMed1")
    titleText:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    titleText:SetText("Spectrum Loot Helper")

    -- Close Button
    local CloseButton = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    CloseButton:SetSize(16, 16)
    CloseButton:SetPoint("TOPRIGHT", -3, -3)
    CloseButton:SetScript("OnClick", function()
        frame:Hide()
        SaveFrameState(frame)
    end)

    -- Enable Dragging
    frame:SetMovable(true)
    frame:EnableMouse(true)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        SaveFrameState(frame)
    end)

    -- Resizable
    frame:SetResizable(true)
    -- Prefer SetResizeBounds if available; fallback to SetMinResize for older builds
    if frame.SetResizeBounds then
        frame:SetResizeBounds(400, 280, 900, 700)  -- minWidth, minHeight, maxWidth, maxHeight
    else
        frame:SetMinResize(400, 280)
    end

    -- Reesize grip (bottom-right corner)
    local resizeGrip = CreateFrame("Button", nil, frame)
    resizeGrip:SetSize(18, 18)
    resizeGrip:SetPoint("BOTTOMRIGHT", -2, 2)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

    resizeGrip:SetScript("OnMouseDown", function()
        frame:StartSizing("BOTTOMRIGHT")
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        SaveFrameState(frame)
    end)

    -- Content Area
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -6)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.content = content

    -- Layout Constants for member rows
    local ROW_HEIGHT = 30
    local CLASS_ICON_SIZE_PERCENT = 0.65
    local NAME_COLUMN_WIDTH_PERCENT = 0.45
    local POINTS_COLUMN_WIDTH = 50
    local BUTTON_SIZE_PERCENT = 0.75
    local BUTTON_SPACING = 4
    local CONTENT_PADDING = 5
    local FONT_SIZE = "GameFontNormal"  -- TODO: Make this configurable in settings

    -- Initialize test mode flag (resets on reload)
    self.testModeActive = false

    -- Create Scroll Frame for member list
    local scrollFrame = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", content, "TOPLEFT", CONTENT_PADDING, -CONTENT_PADDING)
    scrollFrame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -25, CONTENT_PADDING)  -- Offset for scrollbar
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(scrollFrame:GetWidth() or 1, 1)  -- Height set dynamically by PopulateContent
    scrollFrame:SetScrollChild(scrollChild)

    -- Store scroll frame references
    self.memberScrollFrame = scrollFrame
    self.memberScrollChild = scrollChild

    -- Create row pool (40 rows for large raids)
    self.memberRows = {}
    for i = 1, 40 do
        local row = self:CreateMemberRow(i)
        row:SetParent(scrollChild)
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetSize(scrollChild:GetWidth() or 1, ROW_HEIGHT)
        row:Hide()  -- Hidden by default, shown by PopulateContent
        table.insert(self.memberRows, row)
    end

    -- Store constants for use by other functions
    self.ROW_HEIGHT = ROW_HEIGHT
    self.CLASS_ICON_SIZE_PERCENT = CLASS_ICON_SIZE_PERCENT
    self.NAME_COLUMN_WIDTH_PERCENT = NAME_COLUMN_WIDTH_PERCENT
    self.POINTS_COLUMN_WIDTH = POINTS_COLUMN_WIDTH
    self.BUTTON_SIZE_PERCENT = BUTTON_SIZE_PERCENT
    self.BUTTON_SPACING = BUTTON_SPACING
    self.FONT_SIZE = FONT_SIZE

    -- Throttled resize handler (prevents lag during window resizing)
    frame.resizeTimer = nil
    frame:SetScript("OnSizeChanged", function()
        if frame.resizeTimer then
            frame.resizeTimer:Cancel()
        end
        frame.resizeTimer = C_Timer.After(0.1, function()
            self:PopulateContent(self.testModeActive)
        end)
    end)

    -- Event frame for group roster updates
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:SetScript("OnEvent", function(_, event)
        if event == "GROUP_ROSTER_UPDATE" then
            -- Only update if not in test mode
            if not self.testModeActive then
                if SF.Debug then
                    SF.Debug:Info("LOOT_HELPER", "Group roster updated, refreshing member list")
                end
                self:PopulateContent(false)
            end
        end
    end)
    frame.eventFrame = eventFrame

    -- Disabled Overlay
    local overlay = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    overlay:SetAllPoints(content)
    overlay:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        title = true,
        titleSize = 16
    })
    overlay:SetBackdropColor(0, 0, 0, 0.35)  -- Semi-transparent dark overlay
    overlay:Hide()
    frame.disabledOverlay = overlay

    local disabledText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    disabledText:SetPoint("CENTER")
    disabledText:SetText("Loot Helper Disabled")

    -- Save Visibility Changes
    frame:SetScript("OnShow", function()
        SaveFrameState(frame)
    end)
    frame:SetScript("OnHide", function()
        SaveFrameState(frame)
    end)

    -- Apply saved state
    ApplyFrameState(frame)
    SetEnabledVisuals(frame, db.enabled)

    -- Initial population of member list
    self:PopulateContent(false)

    self.frame = frame
    return frame
end

-- Local helper function to get test members
-- @return: Array of test member data
local function GetTestMembers()
    -- TODO: Expand test data with more varied members for thorough testing
    local members = {
        {name = "Tankmaster", realm = "Garona", classFilename = "WARRIOR", points = 0},
        {name = "Holybringer", realm = "Garona", classFilename = "PALADIN", points = 0},
        {name = "Beastlord", realm = "Stormrage", classFilename = "HUNTER", points = 0},
        {name = "Shadowstrike", realm = "Garona", classFilename = "ROGUE", points = 0},
        {name = "Lightweaver", realm = "Stormrage", classFilename = "PRIEST", points = 0},
        {name = "Earthshaker", realm = "Garona", classFilename = "SHAMAN", points = 0},
        {name = "Frostcaller", realm = "Stormrage", classFilename = "MAGE", points = 0},
        {name = "Soulreaper", realm = "Garona", classFilename = "WARLOCK", points = 0},
        {name = "Brewmaster", realm = "Stormrage", classFilename = "MONK", points = 0},
        {name = "Wildheart", realm = "Garona", classFilename = "DRUID", points = 0},
        {name = "Chaosreaver", realm = "Stormrage", classFilename = "DEMONHUNTER", points = 0},
        {name = "Frostblade", realm = "Garona", classFilename = "DEATHKNIGHT", points = 0},
        {name = "Dreamweaver", realm = "Stormrage", classFilename = "EVOKER", points = 0},
        {name = "Shieldbash", realm = "Garona", classFilename = "WARRIOR", points = 0},
        {name = "Arcanewiz", realm = "Stormrage", classFilename = "MAGE", points = 0},
    }
    
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Generated %d test members", #members)
    end
    
    return members
end

-- Local helper function to get raid members
-- @return: Array of raid member data
local function GetRaidMembers()
    local members = {}
    local numMembers = GetNumGroupMembers()
    
    for i = 1, numMembers do
        local name, _, _, _, classFilename, _, _, _, _, _, _ = GetRaidRosterInfo(i)
        if name then
            -- GetRaidRosterInfo returns name without realm, need to get realm separately
            local unitToken = "raid" .. i
            local fullName = UnitName(unitToken)
            local realm = GetRealmName()
            
            -- If name has a realm attached (from another server), parse it
            if fullName and fullName:find("-") then
                local namePart, realmPart = fullName:match("^(.+)-(.+)$")
                if namePart and realmPart then
                    name = namePart
                    realm = realmPart
                end
            end
            
            table.insert(members, {
                name = name,
                realm = realm,
                classFilename = classFilename,
                points = 0  -- TODO: Load from database when points system implemented
            })
        end
    end
    
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Found %d raid members", #members)
    end
    
    return members
end

-- Local helper function to get party members (including player)
-- @return: Array of party member data
local function GetPartyMembers()
    local members = {}
    
    -- Add player first
    local playerName = UnitName("player")
    local _, playerClass = UnitClass("player")
    local playerRealm = GetRealmName()
    
    table.insert(members, {
        name = playerName,
        realm = playerRealm,
        classFilename = playerClass,
        points = 0  -- TODO: Load from database
    })
    
    -- Add party members
    local numParty = GetNumSubgroupMembers()
    for i = 1, numParty do
        local unitToken = "party" .. i
        if UnitExists(unitToken) then
            local name = UnitName(unitToken)
            local _, classFilename = UnitClass(unitToken)
            local realm = GetRealmName()  -- Assumes same realm for party members
            
            table.insert(members, {
                name = name,
                realm = realm,
                classFilename = classFilename,
                points = 0  -- TODO: Load from database
            })
        end
    end
    
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Found %d party members (including player)", #members)
    end
    
    return members
end

-- Local helper function to get solo player data
-- @return: Array with single player member data
local function GetSoloPlayer()
    local playerName = UnitName("player")
    local _, playerClass = UnitClass("player")
    local playerRealm = GetRealmName()
    
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Solo mode: showing player only")
    end
    
    return {
        {
            name = playerName,
            realm = playerRealm,
            classFilename = playerClass,
            points = 0  -- TODO: Load from database
        }
    }
end

-- Local helper function to update row UI elements with member data
-- @param rows: Array of row frames from the row pool
-- @param members: Array of member data to display
-- @param scrollChild: The scroll frame's child to set height on
-- @param rowHeight: Height of each row
-- @return: none
local function UpdateRowsWithMembers(rows, members, scrollChild, rowHeight)
    for i, row in ipairs(rows) do
        if i <= #members then
            local member = members[i]
            
            -- Update class icon
            local classIconPath = "Interface\\Icons\\ClassIcon_" .. member.classFilename
            row.classIcon:SetTexture(classIconPath)
            
            -- If texture failed to load, it will show the default question mark we set in CreateMemberRow
            -- We could verify with GetTexture() but WoW handles missing textures gracefully
            
            -- Update name with class color
            local nameRealm = member.name .. " - " .. member.realm
            if RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.classFilename] then
                local color = RAID_CLASS_COLORS[member.classFilename]
                row.nameText:SetTextColor(color.r, color.g, color.b, 1)
            else
                -- Fallback to white if class color not found
                row.nameText:SetTextColor(1, 1, 1, 1)
                if SF.Debug then
                    SF.Debug:Warn("LOOT_HELPER", "Class color not found for '%s', using white", member.classFilename)
                end
            end
            row.nameText:SetText(nameRealm)
            
            -- Update points
            row.pointsText:SetText(tostring(member.points))
            
            -- Store class filename for reference
            row.classFilename = member.classFilename
            
            -- Update layout and show row
            row:UpdateLayout()
            row:Show()
            
            if SF.Debug then
                SF.Debug:Verbose("LOOT_HELPER", "Row %d: %s-%s (%s, %d points)", 
                    i, member.name, member.realm, member.classFilename, member.points)
            end
        else
            -- Hide unused rows
            row:Hide()
            row.classFilename = nil
        end
    end
    
    -- Update scroll child height based on number of members
    local scrollHeight = #members * rowHeight
    scrollChild:SetHeight(scrollHeight)
    
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Scroll child height set to %d for %d members", scrollHeight, #members)
    end
end

-- Function to populate the content area with member list
-- @param testMode: Boolean indicating whether to use test data or query real group members
-- @return: none
function LootWindow:PopulateContent(testMode)
    if SF.Debug then
        SF.Debug:Verbose("LOOT_HELPER", "Populating member list")
        if testMode then
            SF.Debug:Info("LOOT_HELPER", "Test mode enabled")
        end
    end
    
    -- Ensure frame and rows exist
    if not self.memberRows or not self.memberScrollChild then
        if SF.Debug then
            SF.Debug:Warn("LOOT_HELPER", "PopulateContent called before frame creation")
        end
        return
    end
    
    -- Get member data based on current context
    local members = {}
    if testMode then
        members = GetTestMembers()
    elseif IsInRaid() then
        members = GetRaidMembers()
    elseif IsInGroup() then
        members = GetPartyMembers()
    else
        members = GetSoloPlayer()
    end
    
    -- Update UI rows with member data
    UpdateRowsWithMembers(self.memberRows, members, self.memberScrollChild, self.ROW_HEIGHT)
end

-- Function to toggle test mode on/off
-- @return: none
function LootWindow:ToggleTestMode()
    -- Toggle the flag
    self.testModeActive = not self.testModeActive
    
    -- Create window if it doesn't exist
    if not self.frame then
        self:Create()
    end
    
    -- Show window if hidden
    if self.frame and not self.frame:IsShown() then
        self.frame:Show()
    end
    
    -- TODO: Once we implement a setting for only showing in Raid, will need to update this to identify if we're in a raid and act accordingly.

    -- Repopulate with new mode
    self:PopulateContent(self.testModeActive)
    
    -- Update settings button text if it exists
    if SF.LootHelperTestModeButton then
        local buttonText = self.testModeActive and "Test Mode: ON" or "Test Mode: OFF"
        SF.LootHelperTestModeButton:SetText(buttonText)
    else
        if SF.Debug then
            SF.Debug:Warn("LOOT_HELPER", "Test Mode button not found to update text")
        end
    end
    
    -- Print status message to chat
    local status = self.testModeActive and "enabled" or "disabled"
    print(string.format("|cff00ff00Spectrum Federation:|r Loot Helper test mode %s", status))
    
    -- Log the change
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Test mode %s", status)
    end
end