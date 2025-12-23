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
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", 6, -6)
    titleBar:SetPoint("TOPRIGHT", -6, -6)
    titleBar:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-Tooltip-Background",
        title = true,
        titleSize = 16
    })
    titleBar:SetBackdropColor(0.12, 0.12, 0.16, 0.95)   -- Slightly lighter for title bar

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    titleText:SetText("Spectrum Loot Helper")

    -- Close Button
    local CloseButton = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    CloseButton:SetPoint("TOPRIGHT", -6, -6)
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
        frame:SetResizeBounds(320, 220, 900, 700)  -- minWidth, minHeight, maxWidth, maxHeight
    else
        frame:SetMinResize(320, 220)
    end

    -- Reesize grip (bottom-right corner)
    local resizeGrip = CreateFrame("Button", nil, frame)
    resizeGrip:SetSize(18, 18)
    resizeGrip:SetPoint("BOTTOMRIGHT", -6, -6)
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

    self.frame = frame
    return frame
end

-- Function to Toggle the Loot Helper UI window
function LootWindow:Toggle()
    if not self.frame then
        self:Create()
    end

    if self.frame:IsShown() then
        self.frame:Hide()
        self.frame.disabledOverlay:Show()
    else
        self.frame:Show()
        self.frame.disabledOverlay:Hide()
    end
end