-- Runtime-only Trade Assistant window for /sf trade (#269).
-- The window is presentation-only; queue state lives in SF.TradeAssistant.
local addonName, SF = ...
-- luacheck: globals CreateFrame UIParent BackdropTemplate UIPanelCloseButton UIPanelScrollFrameTemplate GameTooltip C_Timer

SF.TradeAssistantWindow = SF.TradeAssistantWindow or {}
local Window = SF.TradeAssistantWindow

local ROW_HEIGHT = 26
local ROW_SPACING = 4
local RANGE_TICK_SECONDS = 1.0

local rangeTicker = nil

local function Loc(key, default)
    if SF.LocaleText then
        return SF.LocaleText(key, default)
    end
    return default or key
end

local function Debug(level, message, ...)
    if SF.Debug and SF.Debug[level] then
        SF.Debug[level](SF.Debug, "TRADE_ASSISTANT", message, ...)
    end
end

local function TradeAssistant()
    return SF.TradeAssistant
end

local function StopRangeTicker()
    if rangeTicker then
        if rangeTicker.Cancel then
            rangeTicker:Cancel()
        end
        rangeTicker = nil
    end
end

local function StartRangeTicker()
    if rangeTicker or not C_Timer or not C_Timer.NewTicker then
        return
    end
    local assistant = TradeAssistant()
    if not assistant or not assistant.GetPlayerCount or assistant:GetPlayerCount() < 1 then
        return
    end
    rangeTicker = C_Timer.NewTicker(RANGE_TICK_SECONDS, function()
        Window:UpdateRangeColors()
    end)
end

local function RangeColor(inRange)
    if inRange == true then
        return 0.25, 0.85, 0.30, 1
    end
    if inRange == false then
        return 0.90, 0.25, 0.25, 1
    end
    return 0.65, 0.65, 0.65, 1
end

local function ApplyRowRangeColor(row, inRange)
    if not row or not row.Name then
        return
    end
    local r, g, b, a = RangeColor(inRange)
    row.Name:SetTextColor(r, g, b, a)
end

local function ItemSummaryText(itemCount)
    if itemCount == 1 then
        return Loc("TRADE_ASSISTANT_ONE_ITEM", "1 item")
    end
    return string.format(Loc("TRADE_ASSISTANT_ITEMS", "%d items"), itemCount or 0)
end

local function EnsureRow(index)
    local rows = Window._rows
    local row = rows[index]
    if row then
        return row
    end

    local child = Window._child
    row = CreateFrame("Button", nil, child)
    row:SetHeight(ROW_HEIGHT)
    row:SetScript("OnClick", function(self)
        local assistant = TradeAssistant()
        if assistant and assistant.TradeWithPlayer and self.playerKey then
            assistant:TradeWithPlayer(self.playerKey)
        end
    end)
    row:SetScript("OnEnter", function(self)
        if not GameTooltip then
            return
        end
        local assistant = TradeAssistant()
        local model = nil
        if assistant and assistant.GetQueueSnapshot then
            for _, candidate in ipairs(assistant:GetQueueSnapshot()) do
                if candidate.key == self.playerKey then
                    model = candidate
                    break
                end
            end
        end
        if not model then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(model.name or model.playerId or "Player")
        local rangeKey = "TRADE_ASSISTANT_RANGE_UNKNOWN"
        local rangeDefault = "Range unavailable"
        if model.inRange == true then
            rangeKey = "TRADE_ASSISTANT_RANGE_IN"
            rangeDefault = "In trade range"
        elseif model.inRange == false then
            rangeKey = "TRADE_ASSISTANT_RANGE_OUT"
            rangeDefault = "Out of trade range"
        end
        GameTooltip:AddLine(Loc(rangeKey, rangeDefault))
        for _, item in ipairs(model.items or {}) do
            GameTooltip:AddLine(string.format("%dx %s", item.quantity or 0, item.displayName or item.itemLink or "item"))
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        if GameTooltip and GameTooltip.Hide then
            GameTooltip:Hide()
        end
    end)

    row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.Name:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.Name:SetPoint("RIGHT", row, "RIGHT", -58, 0)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetJustifyV("MIDDLE")

    row.Count = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.Count:SetPoint("RIGHT", row, "RIGHT", -28, 0)
    row.Count:SetJustifyH("RIGHT")
    row.Count:SetJustifyV("MIDDLE")
    row.Count:SetTextColor(0.75, 0.75, 0.75, 1)

    row.Remove = CreateFrame("Button", nil, row)
    row.Remove:SetSize(18, 18)
    row.Remove:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.Remove:SetScript("OnClick", function(self)
        local assistant = TradeAssistant()
        local key = self.playerKey
        if assistant and assistant.RemovePlayer and key then
            assistant:RemovePlayer(key)
        end
        Window:Refresh()
    end)
    row.Remove.Text = row.Remove:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.Remove.Text:SetPoint("CENTER", row.Remove, "CENTER", 0, 0)
    row.Remove.Text:SetText("x")
    row.Remove.Text:SetTextColor(0.9, 0.25, 0.25, 1)

    rows[index] = row
    return row
end

function Window:Refresh()
    local frame = Window._frame
    local child = Window._child
    if not frame or not child then
        return
    end
    local assistant = TradeAssistant()
    if assistant and assistant.RefreshRangeStates then
        assistant:RefreshRangeStates()
    end
    local snapshot = {}
    if assistant and assistant.GetQueueSnapshot then
        snapshot = assistant:GetQueueSnapshot() or {}
    end

    if Window._emptyText then
        if #snapshot == 0 then
            Window._emptyText:SetText(Loc("TRADE_ASSISTANT_EMPTY", "No pending trades."))
            Window._emptyText:Show()
        else
            Window._emptyText:Hide()
        end
    end

    local y = -2
    for index, model in ipairs(snapshot) do
        local row = EnsureRow(index)
        row.playerKey = model.key
        row.playerName = model.name or model.playerId
        if row.Remove then
            row.Remove.playerKey = model.key
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
        row:SetHeight(ROW_HEIGHT)
        row:Show()
        if row.Name then
            row.Name:SetText(model.name or model.playerId or "Unknown")
        end
        if row.Count then
            row.Count:SetText(ItemSummaryText(model.itemCount))
        end
        ApplyRowRangeColor(row, model.inRange)
        y = y - ROW_HEIGHT - ROW_SPACING
    end
    for index = #snapshot + 1, #(Window._rows or {}) do
        Window._rows[index]:Hide()
    end

    local width = 1
    local scroll = Window._scroll
    if scroll and scroll.GetWidth then
        width = scroll:GetWidth() or 1
    end
    child:SetSize(math.max(1, width), math.max(1, (#snapshot * (ROW_HEIGHT + ROW_SPACING)) + 4))

    local shown = frame.IsShown ~= nil and frame:IsShown() or false
    if #snapshot == 0 or not shown then
        StopRangeTicker()
    else
        StartRangeTicker()
    end
end

function Window:UpdateRangeColors()
    local frame = Window._frame
    if not frame then
        return
    end
    if frame.IsShown and not frame:IsShown() then
        StopRangeTicker()
        return
    end
    local assistant = TradeAssistant()
    if not assistant then
        return
    end
    if assistant.RefreshRangeStates then
        assistant:RefreshRangeStates()
    end
    for _, row in ipairs(Window._rows or {}) do
        if row.playerKey and row:IsShown() then
            ApplyRowRangeColor(row, assistant.GetPlayerRange and assistant:GetPlayerRange(row.playerKey) or nil)
        end
    end
end

local function EnsureFrame()
    if Window._frame then
        return Window._frame
    end
    if not CreateFrame then
        return nil
    end

    local frame = CreateFrame("Frame", "SpectrumFederationTradeAssistantWindow", UIParent, "BackdropTemplate")
    frame:SetSize(320, 380)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    local titleBar = CreateFrame("Frame", nil, frame)
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
    titleBar:SetHeight(22)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
    end)
    frame.TitleBar = titleBar

    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("LEFT", titleBar, "LEFT", 4, 0)
    title:SetPoint("RIGHT", titleBar, "RIGHT", -28, 0)
    title:SetJustifyH("LEFT")
    title:SetJustifyV("MIDDLE")
    title:SetText(Loc("TRADE_ASSISTANT_TITLE", "Trade Assistant"))
    frame.TitleText = title

    local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        Window:Hide()
    end)

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -6)
    content:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 34)
    content:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, -6)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 34)
    frame.Content = content

    local scroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    frame.Scroll = scroll
    Window._scroll = scroll

    local child = CreateFrame("Frame", nil, scroll)
    child:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    Window._child = child

    local emptyText = child:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("TOPLEFT", child, "TOPLEFT", 10, -10)
    emptyText:SetPoint("RIGHT", child, "RIGHT", -10, 0)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetJustifyV("TOP")
    emptyText:SetWordWrap(true)
    emptyText:Hide()
    Window._emptyText = emptyText

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 10)
    hint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 10)
    hint:SetJustifyH("LEFT")
    hint:SetText(Loc("TRADE_ASSISTANT_HINT", "Click a player to trade. Use the X to remove them."))

    Window._frame = frame
    Window._rows = {}
    frame:Hide()
    return frame
end

function Window:Show()
    local frame = EnsureFrame()
    if not frame then
        Debug("Warn", "Trade Assistant window unavailable")
        return false
    end
    if frame.Show then
        frame:Show()
    end
    Window:Refresh()
    StartRangeTicker()
    Debug("Info", "Trade Assistant window shown")
    return true
end

function Window:Hide()
    local frame = Window._frame
    if frame and frame.Hide then
        frame:Hide()
    end
    StopRangeTicker()
    Debug("Info", "Trade Assistant window hidden")
end

function Window:IsShown()
    local frame = Window._frame
    return frame ~= nil and frame.IsShown ~= nil and frame:IsShown() or false
end

return Window
