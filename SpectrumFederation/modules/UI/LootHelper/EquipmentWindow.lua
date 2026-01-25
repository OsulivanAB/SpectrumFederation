-- modules/UI/LootHelper/EquipmentWindow.lua
local addonName, SF = ...

SF.LootHelperWindow = SF.LootHelperWindow or {}
local LH = SF.LootHelperWindow

LH.EquipmentWindow = LH.EquipmentWindow or {}
local EquipmentWindow = LH.EquipmentWindow

-- Constants
local TITLE_HEIGHT = 28
local PADDING = 8  -- Reduced from 10 to minimize extra space
local ICON_SIZE = 32
local ICON_SPACING = 4
local COL_SPACING = ICON_SIZE * 2  -- Double icon size for spacer between columns
local NUM_ROWS = 9
local NUM_COLS = 2

-- Calculate window dimensions based on content
-- Width: left padding + icon + col spacer + icon + right padding
local CONTENT_WIDTH = ICON_SIZE * NUM_COLS + COL_SPACING + (PADDING * 2)
local WINDOW_WIDTH = CONTENT_WIDTH + 8  -- Minimal backdrop insets

-- Height: title bar + top gap + padding + icons + spacing + padding
local CONTENT_HEIGHT = (ICON_SIZE * NUM_ROWS) + (ICON_SPACING * (NUM_ROWS - 1))
local WINDOW_HEIGHT = TITLE_HEIGHT + 6 + PADDING + CONTENT_HEIGHT + PADDING

-- Min/max height constraints (for dynamic sizing if needed)
local WINDOW_MIN_HEIGHT = WINDOW_HEIGHT
local WINDOW_MAX_HEIGHT = WINDOW_HEIGHT
local WINDOW_HEIGHT_RATIO = 0.5  -- 50% of main window height (used in ShowForMember)

-- Slot definitions with paperdoll textures
-- Left column slots
local LEFT_SLOTS = {
    { key = "Head",      texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Head" },
    { key = "Neck",      texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Neck" },
    { key = "Shoulder",  texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Shoulder" },
    { key = "Back",      texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest" },  -- Using Chest icon as Back doesn't exist
    { key = "Chest",     texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest" },
    { key = nil,         texture = nil },  -- EMPTY (shirt placeholder)
    { key = nil,         texture = nil },  -- EMPTY (tabard placeholder)
    { key = "Bracers",   texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Wrists" },
    { key = "Weapon",    texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-MainHand" },
}

-- Right column slots
local RIGHT_SLOTS = {
    { key = "Hands",     texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Hands" },
    { key = "Belt",      texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Waist" },
    { key = "Pants",     texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Legs" },
    { key = "Boots",     texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Feet" },
    { key = "Ring1",     texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger" },
    { key = "Ring2",     texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger" },
    { key = "Trinket1",  texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket" },
    { key = "Trinket2",  texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket" },
    { key = "OffHand",   texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-SecondaryHand" },
}

-- Helper function to get class icon
local function GetClassIcon(className)
    className = className and string.upper(className) or "UNKNOWN"
    if SF.WOW_CLASSES and SF.WOW_CLASSES[className] and SF.WOW_CLASSES[className].textureFile then
        return SF.WOW_CLASSES[className].textureFile
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Helper function to get spec icon
-- Supports both raid units and the player when not in raid
local function TryGetSpecIcon(unit, memberId)
    -- If no unit but memberId is provided, check if it's the player
    if not unit and memberId then
        if SF.NameUtil and SF.NameUtil.GetSelfId then
            local selfId = SF.NameUtil.GetSelfId()
            if selfId and SF.NameUtil.SamePlayer and SF.NameUtil.SamePlayer(memberId, selfId) then
                unit = "player"
            end
        end
    end

    if not unit then return nil end

    if UnitIsUnit(unit, "player") and GetSpecialization and GetSpecializationInfo then
        local specIndex = GetSpecialization()
        if specIndex then
            local _, _, _, icon = GetSpecializationInfo(specIndex)
            if icon then return icon end
        end
    end

    if GetInspectSpecialization and GetSpecializationInfoByID and CanInspect and CanInspect(unit) then
        local specID = GetInspectSpecialization(unit)
        if specID and specID > 0 then
            local _, _, _, icon = GetSpecializationInfoByID(specID)
            if icon then return icon end
        end
    end

    return nil
end

-- Create the equipment window frame
function EquipmentWindow:Create()
    if self._frame then
        return self._frame
    end

    if SF.Debug then
        SF.Debug:Info("LH_EQUIPMENT", "Creating equipment window frame")
    end

    local frame = CreateFrame("Frame", "SF_EquipmentWindow", UIParent, "BackdropTemplate")
    frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(100)  -- Above main window
    frame:Hide()

    -- Backdrop (match main window style)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.60)
    frame:SetBackdropBorderColor(0.65, 0.65, 0.65, 0.65)

    -- Title bar
    local title = CreateFrame("Frame", nil, frame)
    title:SetHeight(TITLE_HEIGHT)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
    frame.Title = title

    local titleBG = title:CreateTexture(nil, "BACKGROUND")
    titleBG:SetAllPoints(title)
    titleBG:SetColorTexture(0.08, 0.08, 0.08, 0.85)
    title.BG = titleBG

    -- Left icon (class/spec)
    local icon = title:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", title, "LEFT", 8, 0)
    title.Icon = icon

    -- Title text
    local titleText = title:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    titleText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    titleText:SetPoint("RIGHT", title, "RIGHT", -30, 0)
    titleText:SetJustifyH("LEFT")
    titleText:SetWordWrap(false)
    titleText:SetMaxLines(1)
    titleText:SetText("Equipment")
    title.Text = titleText

    -- Close button
    local close = CreateFrame("Button", nil, title, "UIPanelCloseButton")
    close:SetPoint("RIGHT", title, "RIGHT", -4, 0)
    close:SetSize(20, 20)
    close:SetScript("OnClick", function()
        EquipmentWindow:Hide()
    end)
    title.Close = close

    -- Content area
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -(TITLE_HEIGHT + 6 + PADDING))
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING, PADDING)
    frame.Content = content

    -- Create gear grid
    self:_CreateGearGrid(content)

    self._frame = frame
    return frame
end

-- Create the gear slot grid
function EquipmentWindow:_CreateGearGrid(content)
    local buttons = {}

    local function CreateSlotButton(parent, slotInfo, x, y)
        if not slotInfo.key then
            -- Empty placeholder
            local placeholder = CreateFrame("Frame", nil, parent)
            placeholder:SetSize(ICON_SIZE, ICON_SIZE)
            placeholder:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
            
            -- Faint border for visual alignment
            local border = placeholder:CreateTexture(nil, "BACKGROUND")
            border:SetAllPoints(placeholder)
            border:SetColorTexture(0.3, 0.3, 0.3, 0.2)
            
            return nil
        end

        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(ICON_SIZE, ICON_SIZE)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
        btn.slotKey = slotInfo.key

        -- Icon texture
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(btn)
        icon:SetTexture(slotInfo.texture)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)  -- Crop edges
        btn.Icon = icon

        -- Hover highlight (shown on mouseover)
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(btn)
        hl:SetColorTexture(1, 1, 1, 0.3)  -- Brighter white highlight for hover

        -- "Used" overlay (golden border, shown when slot is used)
        local overlay = btn:CreateTexture(nil, "OVERLAY")
        
        -- Border offset - adjust this value to change border appearance
        local borderOffset = 10
        overlay:SetPoint("TOPLEFT", btn, "TOPLEFT", -borderOffset, borderOffset)
        overlay:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", borderOffset, -borderOffset)
        
        overlay:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        overlay:SetBlendMode("ADD")
        overlay:SetVertexColor(1, 0.8, 0, 0.8)  -- Golden glow
        overlay:Hide()
        btn.UsedOverlay = overlay

        return btn
    end

    -- Create left column
    for i = 1, NUM_ROWS do
        local y = (i - 1) * (ICON_SIZE + ICON_SPACING)
        local btn = CreateSlotButton(content, LEFT_SLOTS[i], 0, y)
        if btn then
            table.insert(buttons, btn)
        end
    end

    -- Create right column with spacer
    local colGap = ICON_SIZE + COL_SPACING
    for i = 1, NUM_ROWS do
        local y = (i - 1) * (ICON_SIZE + ICON_SPACING)
        local btn = CreateSlotButton(content, RIGHT_SLOTS[i], colGap, y)
        if btn then
            table.insert(buttons, btn)
        end
    end

    content.SlotButtons = buttons
end

-- Show equipment window for a specific member
function EquipmentWindow:ShowForMember(mainFrame, rowModel, memberObj, canAdmin)
    self:Create()

    if SF.Debug then
        SF.Debug:Info("LH_EQUIPMENT", "ShowForMember: member=%s, canAdmin=%s", 
            tostring(rowModel and rowModel.memberId), tostring(canAdmin))
    end

    -- Check if we're already showing this member - if so, toggle off
    if self:IsShown() and self._rowModel and self._rowModel.memberId == rowModel.memberId then
        if SF.Debug then
            SF.Debug:Verbose("LH_EQUIPMENT", "ShowForMember: Toggling off (same member)")
        end
        self:Hide()
        return
    end

    -- If showing different member, continue to show new member
    self._mainFrame = mainFrame
    self._rowModel = rowModel
    self._memberObj = memberObj
    self._canAdmin = canAdmin

    -- Update member info
    self:SetMember(rowModel, memberObj, canAdmin)

    -- Position relative to main frame
    self:_UpdatePosition()

    -- Hook main window resize
    if mainFrame and not self._resizeHooked then
        mainFrame:HookScript("OnSizeChanged", function()
            if self:IsShown() then
                self:_UpdatePosition()
            end
        end)
        self._resizeHooked = true
    end

    self._frame:Show()
end

-- Update the position based on main window
function EquipmentWindow:_UpdatePosition()
    if not self._frame or not self._mainFrame then return end

    -- Fixed size window, just update position to stay anchored
    self._frame:ClearAllPoints()
    self._frame:SetPoint("TOPLEFT", self._mainFrame, "TOPRIGHT", 8, 0)
end

-- Hide the equipment window
function EquipmentWindow:Hide()
    if self._frame then
        self._frame:Hide()
    end
end

-- Check if window is shown
function EquipmentWindow:IsShown()
    return self._frame and self._frame:IsShown() or false
end

-- Set/update the member being displayed
function EquipmentWindow:SetMember(rowModel, memberObj, canAdmin)
    if not self._frame then return end

    self._rowModel = rowModel
    self._memberObj = memberObj
    self._canAdmin = canAdmin

    -- Update title icon (pass both unit and memberId for player detection when not in raid)
    local icon = TryGetSpecIcon(rowModel.unit, rowModel.memberId) or GetClassIcon(rowModel.class)
    self._frame.Title.Icon:SetTexture(icon)

    -- Update title text
    local displayName = rowModel.displayName or "Unknown"
    self._frame.Title.Text:SetText(displayName)

    -- Refresh armor state
    self:Refresh()
end

-- Refresh armor state display
function EquipmentWindow:Refresh()
    if not self._frame or not self._frame.Content then return end
    if not self._memberObj then return end

    local armor = nil
    if self._memberObj.GetArmorStatuses then
        armor = self._memberObj:GetArmorStatuses()
    elseif self._memberObj.armor then
        armor = self._memberObj.armor
    end

    if not armor then return end

    local buttons = self._frame.Content.SlotButtons or {}
    for _, btn in ipairs(buttons) do
        local slotKey = btn.slotKey
        if slotKey and armor[slotKey] ~= nil then
            local used = armor[slotKey] == true

            if used then
                -- Used: full color, show golden overlay
                btn.Icon:SetDesaturated(false)
                btn.Icon:SetVertexColor(1, 1, 1, 1)
                if btn.UsedOverlay then
                    btn.UsedOverlay:Show()
                end
            else
                -- Not used: desaturated, grey tone, hide overlay
                btn.Icon:SetDesaturated(true)
                btn.Icon:SetVertexColor(0.6, 0.6, 0.6, 0.8)
                if btn.UsedOverlay then
                    btn.UsedOverlay:Hide()
                end
            end

            -- Set click handler
            if self._canAdmin then
                btn:EnableMouse(true)
                btn:SetScript("OnClick", function()
                    self:_OnSlotClicked(slotKey)
                end)
            else
                btn:EnableMouse(false)
                btn:SetScript("OnClick", nil)
            end
        end
    end
end

-- Handle slot click (toggle equipment)
function EquipmentWindow:_OnSlotClicked(slotKey)
    if not self._memberObj or not self._canAdmin then return end
    if not slotKey then return end

    if SF.Debug then
        SF.Debug:Info("LH_EQUIPMENT", "ToggleSlot: member=%s, slot=%s", 
            tostring(self._rowModel and self._rowModel.memberId), tostring(slotKey))
    end

    -- Call member toggle
    if self._memberObj.ToggleEquipment then
        local ok = pcall(function()
            self._memberObj:ToggleEquipment(slotKey)
        end)

        if ok then
            -- DATA_CHANGED event is automatically fired via Events.lua hook
            -- Refresh immediately
            self:Refresh()
        end
    end
end
