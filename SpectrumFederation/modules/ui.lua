local addonName, ns = ...

-- Local reference to UI module
local UI = ns.UI or {}
ns.UI = UI

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
    
    -- Initially hide the frame
    frame:Hide()
    
    -- Store reference
    self.lootPointFrame = frame
    
    -- Debug log
    if ns.Debug then
        ns.Debug:Info("UI", "Loot Point frame created")
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
