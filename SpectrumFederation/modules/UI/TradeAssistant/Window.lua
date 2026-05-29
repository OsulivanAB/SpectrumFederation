-- modules/UI/TradeAssistant/Window.lua
-- Trade Assistant pending-trades UI window
local addonName, SF = ...

SF.TradeAssistantWindow = SF.TradeAssistantWindow or {}
local TAW = SF.TradeAssistantWindow

-- ============================================================================
-- Constants
-- ============================================================================

local WINDOW_WIDTH = 260
local WINDOW_HEIGHT = 320
local TITLE_HEIGHT = 24
local ROW_HEIGHT = 22
local PADDING = 8
local FRAME_NAME = "SpectrumFederationTradeAssistantWindow"

local COLOR_GREEN = { r = 0.2, g = 1.0, b = 0.2 }
local COLOR_RED = { r = 1.0, g = 0.2, b = 0.2 }

-- ============================================================================
-- Window Creation
-- ============================================================================

function TAW:_CreateFrame()
    if self._frame then return end

    local frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
    self._frame = frame

    frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(50)
    frame:Hide()

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.85)
    frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)

    -- Drag handling
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    frame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)

    -- Title bar
    self:_CreateTitleBar(frame)

    -- Scroll area
    self:_CreateScrollArea(frame)

    -- Range update ticker
    self:_StartRangeUpdater()
end

function TAW:_CreateTitleBar(parent)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING + 2, -6)
    title:SetText("Pending Trades")
    self._titleText = title

    -- Close button
    local close = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        self:Hide()
    end)
end

function TAW:_CreateScrollArea(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING, -(TITLE_HEIGHT + PADDING))
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -(PADDING + 20), PADDING)
    self._scrollFrame = scrollFrame

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(WINDOW_WIDTH - (PADDING * 2) - 20, 1) -- height will expand
    scrollFrame:SetScrollChild(content)
    self._contentFrame = content

    -- Empty state text
    local emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("TOP", content, "TOP", 0, -20)
    emptyText:SetText("No pending trades.")
    emptyText:Hide()
    self._emptyText = emptyText
end

-- ============================================================================
-- Row Management
-- ============================================================================

function TAW:_ClearRows()
    if self._rows then
        for _, row in ipairs(self._rows) do
            row.frame:Hide()
            row.frame:SetParent(nil)
        end
    end
    self._rows = {}
end

function TAW:_CreateRow(parent, index, playerId, items)
    local TA = SF.TradeAssistant

    local row = CreateFrame("Button", nil, parent)
    row:SetSize(parent:GetWidth(), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))

    -- Highlight on hover
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.1)

    -- Player name
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
    nameText:SetJustifyH("LEFT")

    -- Display name (strip realm for brevity)
    local displayName = playerId:match("^([^%-]+)") or playerId
    nameText:SetText(displayName)

    -- Item summary
    local itemCount = 0
    for _, item in ipairs(items) do
        itemCount = itemCount + (item.quantity or 1)
    end
    local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    itemText:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    itemText:SetJustifyH("RIGHT")
    itemText:SetText("|cFF888888" .. itemCount .. " item" .. (itemCount ~= 1 and "s" or "") .. "|r")

    -- Remove button (X)
    local removeBtn = CreateFrame("Button", nil, row)
    removeBtn:SetSize(16, 16)
    removeBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

    local removeText = removeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    removeText:SetPoint("CENTER")
    removeText:SetText("|cFFFF4444x|r")
    removeBtn:SetScript("OnClick", function()
        TA:RemovePlayer(playerId)
    end)

    -- Color by range
    local inRange = TA:IsPlayerInRange(playerId)
    local color = inRange and COLOR_GREEN or COLOR_RED
    nameText:SetTextColor(color.r, color.g, color.b)

    -- Click to trade
    row:SetScript("OnClick", function()
        TA:InitiateTrade(playerId)
    end)

    -- Tooltip
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(displayName, color.r, color.g, color.b)
        for _, item in ipairs(items) do
            GameTooltip:AddLine(string.format("  %dx %s", item.quantity or 1, item.itemLink or "Unknown"), 1, 1, 1)
        end
        if inRange then
            GameTooltip:AddLine("\nClick to trade", 0.5, 1.0, 0.5)
        else
            GameTooltip:AddLine("\nOut of trade range", 1.0, 0.5, 0.5)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return {
        frame = row,
        nameText = nameText,
        playerId = playerId,
    }
end

-- ============================================================================
-- Refresh
-- ============================================================================

function TAW:Refresh()
    if not self._frame or not self._frame:IsShown() then return end

    local TA = SF.TradeAssistant
    if not TA then return end

    self:_ClearRows()

    local players = TA:GetPendingPlayerList()

    if #players == 0 then
        self._emptyText:Show()
        self._contentFrame:SetHeight(60)
        return
    end

    self._emptyText:Hide()

    for i, playerId in ipairs(players) do
        local items = TA:GetPlayerItems(playerId)
        if items then
            local row = self:_CreateRow(self._contentFrame, i, playerId, items)
            table.insert(self._rows, row)
        end
    end

    -- Adjust content height
    self._contentFrame:SetHeight(#players * ROW_HEIGHT + 10)
end

-- ============================================================================
-- Range Updater
-- ============================================================================

function TAW:_StartRangeUpdater()
    if self._rangeTimer then return end
    if not C_Timer or not C_Timer.NewTicker then return end

    self._rangeTimer = C_Timer.NewTicker(1.0, function()
        if self._frame and self._frame:IsShown() then
            self:_UpdateRangeColors()
        end
    end)
end

function TAW:_UpdateRangeColors()
    if not self._rows then return end
    local TA = SF.TradeAssistant
    if not TA then return end

    for _, row in ipairs(self._rows) do
        local inRange = TA:IsPlayerInRange(row.playerId)
        local color = inRange and COLOR_GREEN or COLOR_RED
        if row.nameText then
            row.nameText:SetTextColor(color.r, color.g, color.b)
        end
    end
end

-- ============================================================================
-- Show / Hide
-- ============================================================================

function TAW:Show()
    self:_CreateFrame()
    self._frame:Show()
    self:Refresh()
end

function TAW:Hide()
    if self._frame then
        self._frame:Hide()
    end
end

function TAW:IsShown()
    return self._frame and self._frame:IsShown() or false
end

function TAW:Toggle()
    if self:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

-- ============================================================================
-- Wire refresh callback
-- ============================================================================

if SF.TradeAssistant then
    SF.TradeAssistant.OnRefresh = function()
        if TAW:IsShown() then
            TAW:Refresh()
        end
    end
end
