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
    gearBtn:SetNormalTexture("Interface\\Buttons\\UI-GearButton-Up")
    gearBtn:SetHighlightTexture("Interface\\Buttons\\UI-GearButton-Highlight")
    gearBtn:SetPushedTexture("Interface\\Buttons\\UI-GearButton-Down")
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

-- Helper function to create the title bar for the Loot Helper window
-- @param frame: The parent frame
-- @return: The created title bar frame
local function CreateTitleBar(frame)
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(14)
    titleBar:SetPoint("TOPLEFT", 6, -6)
    titleBar:SetPoint("TOPRIGHT", -6, -6)
    titleBar:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-Tooltip-Background",
        title = true,
        titleSize = 16
    })
    titleBar:SetBackdropColor(0.12, 0.12, 0.16, 0.95)

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalMed1")
    titleText:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    titleText:SetText("Spectrum Loot Helper")

    -- Close Button
    local closeButton = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    closeButton:SetSize(16, 16)
    closeButton:SetPoint("TOPRIGHT", -3, -3)
    closeButton:SetScript("OnClick", function()
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

    return titleBar
end

-- Helper function to create resize grip for the window
-- @param frame: The parent frame
-- @return: The created resize grip button
local function CreateResizeGrip(frame)
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

    return resizeGrip
end

-- Helper function to create the disabled overlay
-- @param frame: The parent frame
-- @param content: The content frame to cover
-- @return: The created overlay frame
local function CreateDisabledOverlay(frame, content)
    local overlay = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    overlay:SetAllPoints(content)
    overlay:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        title = true,
        titleSize = 16
    })
    overlay:SetBackdropColor(0, 0, 0, 0.35)
    overlay:Hide()

    local disabledText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    disabledText:SetPoint("CENTER")
    disabledText:SetText("Loot Helper Disabled")

    return overlay
end

-- Helper function to setup scroll frame and row pool
-- @param self: The LootWindow object
-- @param content: The content frame
-- @param constants: Table of layout constants
-- @return: none
local function SetupScrollFrameAndRows(self, content, constants)
    -- Create Scroll Frame for member list
    local scrollFrame = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", content, "TOPLEFT", constants.CONTENT_PADDING, -constants.CONTENT_PADDING)
    scrollFrame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -25, constants.CONTENT_PADDING)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(scrollFrame:GetWidth() or 1, 1)
    scrollFrame:SetScrollChild(scrollChild)

    self.memberScrollFrame = scrollFrame
    self.memberScrollChild = scrollChild

    -- Create row pool (40 rows for large raids)
    self.memberRows = {}
    for i = 1, 40 do
        local row = self:CreateMemberRow(i)
        row:SetParent(scrollChild)
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(i - 1) * constants.ROW_HEIGHT)
        row:SetSize(scrollChild:GetWidth() or 1, constants.ROW_HEIGHT)
        row:Hide()
        table.insert(self.memberRows, row)
    end
end

-- Helper function to setup event handlers for the window
-- @param self: The LootWindow object
-- @param frame: The window frame
-- @return: none
local function SetupEventHandlers(self, frame)
    -- Throttled resize handler
    frame.resizeTimer = nil
    frame:SetScript("OnSizeChanged", function()
        if frame.resizeTimer then
            frame.resizeTimer:Cancel()
        end
        frame.resizeTimer = C_Timer.After(0.1, function()
            self:PopulateContent(self.testModeActive)
        end)
    end)
    
    -- Update row widths when scroll frame resizes
    if self.memberScrollFrame and self.memberRows then
        self.memberScrollFrame:SetScript("OnSizeChanged", function(scrollFrame, width, height)
            if SF.Debug then
                SF.Debug:Verbose("LOOT_HELPER", "Scroll frame resized to %.0f x %.0f, updating row widths", width or 0, height or 0)
            end
            
            -- Update scroll child width
            if self.memberScrollChild then
                self.memberScrollChild:SetWidth(width or 1)
            end
            
            -- Update all row widths
            for _, row in ipairs(self.memberRows) do
                row:SetWidth(width or 1)
                -- Trigger row layout update
                if row.UpdateLayout then
                    row:UpdateLayout()
                end
            end
        end)
    end

    -- Group roster update event
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:SetScript("OnEvent", function(_, event)
        if event == "GROUP_ROSTER_UPDATE" then
            if not self.testModeActive then
                if SF.Debug then
                    SF.Debug:Info("LOOT_HELPER", "Group roster updated, refreshing member list")
                end
                self:PopulateContent(false)
            end
        end
    end)
    frame.eventFrame = eventFrame

    -- Save visibility changes
    frame:SetScript("OnShow", function()
        SaveFrameState(frame)
    end)
    frame:SetScript("OnHide", function()
        SaveFrameState(frame)
    end)
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

    -- Create title bar with close button and drag functionality
    local titleBar = CreateTitleBar(frame)

    -- Enable resizing with grip
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(400, 280, 900, 700)
    else
        frame:SetMinResize(400, 280)
    end
    CreateResizeGrip(frame)

    -- Content Area
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -6)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.content = content

    -- Layout Constants for member rows
    local constants = {
        ROW_HEIGHT = 30,
        CLASS_ICON_SIZE_PERCENT = 0.65,
        NAME_COLUMN_WIDTH_PERCENT = 0.45,
        POINTS_COLUMN_WIDTH = 50,
        BUTTON_SIZE_PERCENT = 0.90,
        BUTTON_SPACING = 4,
        CONTENT_PADDING = 5,
        FONT_SIZE = "GameFontNormal"  -- TODO: Make this configurable in settings
    }

    -- Store constants for use by other functions
    self.ROW_HEIGHT = constants.ROW_HEIGHT
    self.CLASS_ICON_SIZE_PERCENT = constants.CLASS_ICON_SIZE_PERCENT
    self.NAME_COLUMN_WIDTH_PERCENT = constants.NAME_COLUMN_WIDTH_PERCENT
    self.POINTS_COLUMN_WIDTH = constants.POINTS_COLUMN_WIDTH
    self.BUTTON_SIZE_PERCENT = constants.BUTTON_SIZE_PERCENT
    self.BUTTON_SPACING = constants.BUTTON_SPACING
    self.FONT_SIZE = constants.FONT_SIZE

    -- Initialize test mode flag (resets on reload)
    self.testModeActive = false

    -- Setup scroll frame and member rows
    SetupScrollFrameAndRows(self, content, constants)

    -- Create disabled overlay
    local overlay = CreateDisabledOverlay(frame, content)
    frame.disabledOverlay = overlay

    -- Setup event handlers
    SetupEventHandlers(self, frame)

    -- Apply saved state and initialize
    ApplyFrameState(frame)
    SetEnabledVisuals(frame, db.enabled)
    self:PopulateContent(false)

    self.frame = frame
    return frame
end

-- Local helper function to update row UI elements with member data
-- @param rows: Array of row frames from the row pool
-- @param members: Array of member data to display
-- @param scrollChild: The scroll frame's child to set height on
-- @param rowHeight: Height of each row
-- @return: none
local function UpdateRowsWithMembers(rows, members, scrollChild, rowHeight)
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "UpdateRowsWithMembers called with %d members, %d rows available", #members, #rows)
    end
    
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
            if SF.Debug then
                SF.Debug:Info("LOOT_HELPER", "Showing row %d for %s-%s", i, member.name, member.realm)
            end
            row:Show()
            
            if SF.Debug then
                SF.Debug:Verbose("LOOT_HELPER", "Row %d: %s-%s (%s, %d points) - IsShown=%s", 
                    i, member.name, member.realm, member.classFilename, member.points, tostring(row:IsShown()))
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
        SF.Debug:Info("LOOT_HELPER", "PopulateContent called - testMode=%s, IsInRaid=%s, IsInGroup=%s", 
            tostring(testMode), tostring(IsInRaid()), tostring(IsInGroup()))
    end
    
    -- Ensure frame and rows exist
    if not self.memberRows or not self.memberScrollChild then
        if SF.Debug then
            SF.Debug:Error("LOOT_HELPER", "PopulateContent called before frame creation - memberRows=%s, memberScrollChild=%s",
                tostring(self.memberRows ~= nil), tostring(self.memberScrollChild ~= nil))
        end
        return
    end
    
    -- Get member data based on current context
    local members = {}
    if testMode then
        if SF.Debug then SF.Debug:Info("LOOT_HELPER", "Using test members") end
        members = SF:GetTestMembers()
    elseif IsInRaid() then
        if SF.Debug then SF.Debug:Info("LOOT_HELPER", "Querying raid members") end
        members = SF:GetRaidMembers()
    elseif IsInGroup() then
        if SF.Debug then SF.Debug:Info("LOOT_HELPER", "Querying party members") end
        members = SF:GetPartyMembers()
    else
        if SF.Debug then SF.Debug:Info("LOOT_HELPER", "Getting solo player") end
        members = SF:GetSoloPlayer()
    end
    
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Got %d members to display", #members)
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
    
    -- Ensure Loot Helper is enabled (content visible)
    if SF.lootHelperDB and SF.lootHelperDB.windowSettings then
        if not SF.lootHelperDB.windowSettings.enabled then
            if SF.Debug then
                SF.Debug:Warn("LOOT_HELPER", "Test mode toggled but Loot Helper was disabled, enabling it")
            end
            self:SetEnabled(true)
        end
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
    SF:PrintSuccess(string.format("Loot Helper test mode %s", status))
    
    -- Log the change
    if SF.Debug then
        SF.Debug:Info("LOOT_HELPER", "Test mode %s", status)
    end
end