local addonName, ns = ...

-- Local reference to UI module
local UI = ns.UI or {}
ns.UI = UI

-- UI Constants
local ROW_HEIGHT = 30
local MAX_VISIBLE_ROWS = 13

-- Row storage
UI.rows = {}

-- CreateRow: Creates a single roster row with name, points, and buttons
-- @param parent: Parent frame
-- @param index: Row index
-- @return: Row frame
local function CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(360, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 10, -(index - 1) * ROW_HEIGHT)
    
    -- Name text (left)
    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.nameText:SetPoint("LEFT", 5, 0)
    row.nameText:SetWidth(180)
    row.nameText:SetJustifyH("LEFT")
    
    -- Points text (center-right)
    row.pointsText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.pointsText:SetPoint("LEFT", row.nameText, "RIGHT", 10, 0)
    row.pointsText:SetWidth(50)
    row.pointsText:SetJustifyH("CENTER")
    
    -- Up button
    row.upButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.upButton:SetSize(30, 24)
    row.upButton:SetPoint("LEFT", row.pointsText, "RIGHT", 10, 0)
    row.upButton:SetText("▲")
    row.upButton:Hide()
    
    -- Down button
    row.downButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.downButton:SetSize(30, 24)
    row.downButton:SetPoint("LEFT", row.upButton, "RIGHT", 5, 0)
    row.downButton:SetText("▼")
    row.downButton:Hide()
    
    -- Plus button (for new entries)
    row.plusButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.plusButton:SetSize(65, 24)
    row.plusButton:SetPoint("LEFT", row.pointsText, "RIGHT", 10, 0)
    row.plusButton:SetText("+")
    row.plusButton:Hide()
    
    -- Attach click handlers
    row.upButton:SetScript("OnClick", function(self)
        local charKey = row.charKey
        if not charKey or not ns.Core then
            return
        end
        
        local playerCharKey = ns.Core:GetCharacterKey("player")
        if not playerCharKey then
            if ns.Debug then
                ns.Debug:Error("POINTS_BUTTON", "Could not determine player character key")
            end
            return
        end
        
        local currentTotal = ns.Core:GetPoints(charKey)
        local success = ns.Core:SetPoints(charKey, currentTotal + 1, playerCharKey, "Manual increase via UI", 1)
        
        if success then
            if ns.Debug then
                ns.Debug:Info("POINTS_BUTTON", "Up button clicked for %s (new total: %d)", charKey, currentTotal + 1)
            end
            UI:RefreshRosterList()
        else
            if ns.Debug then
                ns.Debug:Error("POINTS_BUTTON", "Failed to increase points for %s", charKey)
            end
        end
    end)
    
    row.downButton:SetScript("OnClick", function(self)
        local charKey = row.charKey
        if not charKey or not ns.Core then
            return
        end
        
        local playerCharKey = ns.Core:GetCharacterKey("player")
        if not playerCharKey then
            if ns.Debug then
                ns.Debug:Error("POINTS_BUTTON", "Could not determine player character key")
            end
            return
        end
        
        local currentTotal = ns.Core:GetPoints(charKey)
        local success = ns.Core:SetPoints(charKey, currentTotal - 1, playerCharKey, "Manual decrease via UI", -1)
        
        if success then
            if ns.Debug then
                ns.Debug:Info("POINTS_BUTTON", "Down button clicked for %s (new total: %d)", charKey, currentTotal - 1)
            end
            UI:RefreshRosterList()
        else
            if ns.Debug then
                ns.Debug:Error("POINTS_BUTTON", "Failed to decrease points for %s", charKey)
            end
        end
    end)
    
    row.plusButton:SetScript("OnClick", function(self)
        local charKey = row.charKey
        if not charKey or not ns.Core then
            return
        end
        
        local playerCharKey = ns.Core:GetCharacterKey("player")
        if not playerCharKey then
            if ns.Debug then
                ns.Debug:Error("POINTS_BUTTON", "Could not determine player character key")
            end
            return
        end
        
        -- Create new entry with starting total of 0
        local success = ns.Core:SetPoints(charKey, 0, playerCharKey, "Initial points entry via UI", 0)
        
        if success then
            if ns.Debug then
                ns.Debug:Info("POINTS_BUTTON", "Plus button clicked for %s (new entry created)", charKey)
            end
            UI:RefreshRosterList()
        else
            if ns.Debug then
                ns.Debug:Error("POINTS_BUTTON", "Failed to create points entry for %s", charKey)
            end
        end
    end)
    
    return row
end

-- CreateLootPointFrame: Creates the main UI window for managing loot points
function UI:CreateLootPointFrame()
    if self.lootPointFrame then
        -- Already created
        return
    end
    
    -- Create main frame using Blizzard's BasicFrameTemplateWithInset
    local frame = CreateFrame("Frame", "SpectrumFederationPointsFrame", UIParent, "BasicFrameTemplateWithInset")
    
    -- Set size
    frame:SetSize(400, 500)
    
    -- Set position (center of screen initially)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    
    -- Make it movable
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    
    -- Clamp to screen
    frame:SetClampedToScreen(true)

    -- Set title
    if frame.TitleText then
        frame.TitleText:SetText("Spectrum Federation Points")
    elseif frame.title then
        frame.title:SetText("Spectrum Federation Points")
    end
    
    -- Create scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame.Inset or frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame.Inset or frame, "TOPLEFT", 0, -22)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame.Inset or frame, "BOTTOMRIGHT", -26, 4)
    
    -- Create scroll child (content frame)
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(360, MAX_VISIBLE_ROWS * ROW_HEIGHT)
    scrollFrame:SetScrollChild(scrollChild)

    -- Create rows
    self.rows = {}
    for i = 1, MAX_VISIBLE_ROWS do
        self.rows[i] = CreateRow(scrollChild, i)
    end
    
    -- Store references
    self.lootPointFrame = frame
    self.scrollFrame = scrollFrame
    self.scrollChild = scrollChild
    
    -- Hook show event to refresh list
    frame:SetScript("OnShow", function()
        UI:RefreshRosterList()
    end)
    
    -- Register callback for roster updates
    if ns.Core and ns.Core.RegisterCallback then
        ns.Core:RegisterCallback("ROSTER_UPDATED", function()
            if frame:IsShown() then
                UI:RefreshRosterList()
            end
        end)
    end
    
    -- Initially hide the frame
    frame:Hide()
    
    -- Debug log
    if ns.Debug then
        ns.Debug:Info("UI", "Loot Point frame created with %d rows", MAX_VISIBLE_ROWS)
    end
end

-- RefreshRosterList: Updates the roster list display
function UI:RefreshRosterList()
    if not self.lootPointFrame or not ns.Core then
        return
    end
    
    -- Get roster data
    local roster = ns.Core:GetRoster()
    
    -- Convert to sorted array
    local sortedRoster = {}
    for charKey, data in pairs(roster) do
        table.insert(sortedRoster, data)
    end
    
    -- Sort by name
    table.sort(sortedRoster, function(a, b)
        return a.name < b.name
    end)
    
    -- Update visible rows
    local visibleCount = 0
    for i = 1, MAX_VISIBLE_ROWS do
        local row = self.rows[i]
        local data = sortedRoster[i]
        
        if data then
            visibleCount = visibleCount + 1
            
            -- Get points for this character
            local points = ns.Core:GetPoints(data.charKey)
            local tierData = ns.Core:GetCurrentTierData()
            local hasPoints = tierData and tierData.points[data.charKey] ~= nil
            
            -- Set name (with class color if available)
            if data.class then
                local classColor = RAID_CLASS_COLORS[data.class]
                if classColor then
                    row.nameText:SetText(string.format("|cff%02x%02x%02x%s|r", 
                        classColor.r * 255, classColor.g * 255, classColor.b * 255, data.name))
                else
                    row.nameText:SetText(data.name)
                end
            else
                row.nameText:SetText(data.name)
            end
            
            -- Set points display
            if hasPoints then
                row.pointsText:SetText(tostring(points))
                -- Show up/down buttons, hide plus
                row.upButton:Show()
                row.downButton:Show()
                row.plusButton:Hide()
            else
                row.pointsText:SetText("--")
                -- Hide up/down buttons, show plus
                row.upButton:Hide()
                row.downButton:Hide()
                row.plusButton:Show()
            end
            
            -- Store charKey in row for button handlers (future use)
            row.charKey = data.charKey
            
            row:Show()
        else
            -- Hide unused rows
            row:Hide()
        end
    end
    
    -- Adjust scroll child height if needed
    local totalRows = #sortedRoster
    if totalRows > MAX_VISIBLE_ROWS then
        self.scrollChild:SetHeight(totalRows * ROW_HEIGHT)
    else
        self.scrollChild:SetHeight(MAX_VISIBLE_ROWS * ROW_HEIGHT)
    end
    
    -- Debug log
    if ns.Debug then
        ns.Debug:Info("UI", "Roster list refreshed: %d visible, %d total", visibleCount, totalRows)
    end
end

-- Show: Shows the loot point frame
function UI:Show()
    if self.lootPointFrame then
        self.lootPointFrame:Show()
        
        if ns.Debug then
            ns.Debug:Info("UI", "Loot Point frame shown")
        end
    end
end

-- Hide: Hides the loot point frame
function UI:Hide()
    if self.lootPointFrame then
        self.lootPointFrame:Hide()
        
        if ns.Debug then
            ns.Debug:Info("UI", "Loot Point frame hidden")
        end
    end
end

-- Toggle: Toggles the loot point frame visibility
function UI:Toggle()
    if self.lootPointFrame then
        if self.lootPointFrame:IsShown() then
            self:Hide()
        else
            self:Show()
        end
    end
end
