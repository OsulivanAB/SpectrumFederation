-- luacheck: globals CreateFrame UIParent IsInRaid GetNumGroupMembers GetRaidRosterInfo UnitFullName CheckInteractDistance InitiateTrade C_Container GetItemInfo GetItemInfoInstant ClickTradeButton GetTradePlayerItemInfo ClearCursor CursorHasItem strtrim Ambiguate GetUnitName
local addonName, SF = ...

SF.TradeAssistant = SF.TradeAssistant or {}
local TradeAssistant = SF.TradeAssistant

local WINDOW_NAME = "SF_TradeAssistantWindow"
local WINDOW_WIDTH = 380
local WINDOW_HEIGHT = 340
local TITLE_HEIGHT = 28
local PADDING = 10
local ROW_HEIGHT = 40
local MAX_TRADE_ITEMS = 6
local RANGE_REFRESH_INTERVAL = 0.5

local function GetNormalizedPlayerId(name, realm)
    if not (SF.NameUtil and SF.NameUtil.NormalizeNameRealm) then
        return nil
    end

    if realm ~= nil then
        return SF.NameUtil.NormalizeNameRealm(name, realm)
    end

    return SF.NameUtil.NormalizeNameRealm(name)
end

local function GetTradeDB()
    SpectrumFederationTradeDB = SpectrumFederationTradeDB or {}
    SpectrumFederationTradeDB.pending = SpectrumFederationTradeDB.pending or {}
    return SpectrumFederationTradeDB
end

local function GetPendingTrades()
    local db = GetTradeDB()
    db.pending = db.pending or {}
    return db.pending
end

local function GetDisplayName(playerId)
    if type(playerId) ~= "string" or playerId == "" then
        return "Unknown"
    end

    if Ambiguate then
        return Ambiguate(playerId, "short")
    end

    return playerId
end

local function GetItemId(itemRef)
    if C_Item and C_Item.GetItemInfoInstant then
        local itemID = C_Item.GetItemInfoInstant(itemRef)
        if itemID then
            return itemID
        end
    end

    if GetItemInfoInstant then
        local itemID = GetItemInfoInstant(itemRef)
        if itemID then
            return itemID
        end
    end

    return nil
end

local function ResolveItem(itemInput)
    itemInput = strtrim(itemInput or "")
    if itemInput == "" then
        return nil
    end

    local itemID = GetItemId(itemInput)
    local itemName, itemLink = GetItemInfo(itemInput)

    if not itemID and itemLink then
        itemID = GetItemId(itemLink)
    end

    if not itemID then
        return nil
    end

    return {
        itemID = itemID,
        itemLink = itemLink or itemInput,
        itemName = itemName or itemInput,
    }
end

local function FindItemEntry(items, itemID)
    for _, item in ipairs(items) do
        if item.itemID == itemID then
            return item
        end
    end

    return nil
end

local function SummarizeItems(items)
    local parts = {}
    for _, item in ipairs(items) do
        table.insert(parts, string.format("%dx %s", item.quantity or 0, item.itemLink or item.itemName or ("item:" .. tostring(item.itemID))))
    end

    return table.concat(parts, ", ")
end

local function GetBagSlotCount()
    return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
end

function TradeAssistant:Init()
    if self._initialized then
        return
    end

    self._initialized = true
    self.db = GetTradeDB()
    self.pending = self.db.pending
    self:_InitEvents()
end

function TradeAssistant:_InitEvents()
    if self._eventFrame then
        return
    end

    local eventFrame = CreateFrame("Frame")
    self._eventFrame = eventFrame

    eventFrame:SetScript("OnEvent", function(_, event, ...)
        self:OnEvent(event, ...)
    end)

    eventFrame:RegisterEvent("TRADE_SHOW")
    eventFrame:RegisterEvent("TRADE_CLOSED")
    eventFrame:RegisterEvent("TRADE_REQUEST_CANCEL")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("UI_INFO_MESSAGE")
end

function TradeAssistant:OnEvent(event, ...)
    if event == "TRADE_SHOW" then
        self:OnTradeShow()
        return
    end

    if event == "TRADE_CLOSED" or event == "TRADE_REQUEST_CANCEL" then
        self._expectedTradePlayerId = nil
        self._activeTradePlayerId = nil
        self:RefreshWindow()
        return
    end

    if event == "GROUP_ROSTER_UPDATE" then
        self:RefreshWindow()
        return
    end

    if event == "UI_INFO_MESSAGE" then
        local _, message = ...
        local completedPlayerId = self._activeTradePlayerId or self._lastTradePlayerId
        if message == ERR_TRADE_COMPLETE and completedPlayerId and self.pending[completedPlayerId] then
            self:RemovePendingPlayer(completedPlayerId)
            self._activeTradePlayerId = nil
            self._lastTradePlayerId = nil
        end
        return
    end
end

function TradeAssistant:HandleSlashCommand(args)
    self:Init()

    args = strtrim(args or "")
    if args == "" then
        self:ShowWindow()
        return
    end

    local itemData, quantity = self:ParseCommandArguments(args)
    if not itemData then
        return
    end

    self:QueueItemForCurrentRaid(itemData, quantity)
    self:ShowWindow()
end

function TradeAssistant:ParseCommandArguments(args)
    local directItem = ResolveItem(args)
    if directItem then
        return directItem, 1
    end

    local itemPart, quantityPart = args:match("^(.-)%s+(%S+)$")
    if not itemPart or not quantityPart then
        self:PrintInvalidItemError()
        return nil
    end

    local quantity = tonumber(quantityPart)
    if not quantity or quantity < 1 or quantity ~= math.floor(quantity) then
        if args:find("|Hitem:", 1, true) then
            self:PrintInvalidQuantityError()
        else
            self:PrintInvalidItemError()
        end
        return nil
    end

    local itemData = ResolveItem(itemPart)
    if not itemData then
        self:PrintInvalidItemError()
        return nil
    end

    return itemData, quantity
end

function TradeAssistant:PrintInvalidItemError()
    SF:PrintError("Trade: Invalid item. Shift-click an item from your bags, for example: /sf trade [item] 1")
end

function TradeAssistant:PrintInvalidQuantityError()
    SF:PrintError("Trade: Invalid quantity. Quantity must be a number greater than 0.")
end

function TradeAssistant:GetPendingPlayer(playerId)
    return GetPendingTrades()[playerId]
end

function TradeAssistant:GetRaidMembers()
    local players = {}
    if not IsInRaid() then
        return players
    end

    local selfId = SF.NameUtil and SF.NameUtil.GetSelfId and SF.NameUtil.GetSelfId()

    for i = 1, GetNumGroupMembers() do
        local name = GetRaidRosterInfo(i)
        local playerId = GetNormalizedPlayerId(name)
        if playerId and (not selfId or not SF.NameUtil.SamePlayer(playerId, selfId)) then
            table.insert(players, {
                playerId = playerId,
                displayName = GetDisplayName(playerId),
            })
        end
    end

    return players
end

function TradeAssistant:QueueItemForCurrentRaid(itemData, quantity)
    local players = self:GetRaidMembers()
    local pending = GetPendingTrades()

    for _, player in ipairs(players) do
        local entry = pending[player.playerId]
        if not entry then
            entry = {
                playerId = player.playerId,
                displayName = player.displayName,
                items = {},
            }
            pending[player.playerId] = entry
        else
            entry.displayName = player.displayName or entry.displayName
            entry.items = entry.items or {}
        end

        local existingItem = FindItemEntry(entry.items, itemData.itemID)
        if existingItem then
            existingItem.quantity = existingItem.quantity + quantity
            existingItem.itemLink = itemData.itemLink or existingItem.itemLink
            existingItem.itemName = itemData.itemName or existingItem.itemName
        else
            table.insert(entry.items, {
                itemID = itemData.itemID,
                itemLink = itemData.itemLink,
                itemName = itemData.itemName,
                quantity = quantity,
            })
        end
    end

    self.pending = pending
    self:RefreshWindow()
end

function TradeAssistant:RemovePendingPlayer(playerId)
    local pending = GetPendingTrades()
    pending[playerId] = nil
    self.pending = pending
    self:RefreshWindow()
end

function TradeAssistant:GetSortedPendingPlayers()
    local players = {}
    for playerId, entry in pairs(GetPendingTrades()) do
        if entry and type(entry.items) == "table" and #entry.items > 0 then
            entry.playerId = playerId
            entry.displayName = entry.displayName or GetDisplayName(playerId)
            table.insert(players, entry)
        end
    end

    table.sort(players, function(a, b)
        return (a.displayName or a.playerId or ""):lower() < (b.displayName or b.playerId or ""):lower()
    end)

    return players
end

function TradeAssistant:GetRaidUnitForPlayer(playerId)
    if not IsInRaid() then
        return nil
    end

    for i = 1, GetNumGroupMembers() do
        local unit = "raid" .. i
        local name, realm = UnitFullName(unit)
        local unitId = GetNormalizedPlayerId(name, realm)
        if unitId and SF.NameUtil.SamePlayer(unitId, playerId) then
            return unit
        end
    end

    return nil
end

function TradeAssistant:IsPlayerInTradeRange(playerId)
    local unit = self:GetRaidUnitForPlayer(playerId)
    if not unit then
        return false
    end

    if CheckInteractDistance then
        return CheckInteractDistance(unit, 2) ~= false
    end

    return false
end

function TradeAssistant:BeginTrade(playerId)
    local entry = self:GetPendingPlayer(playerId)
    if not entry then
        return
    end

    local unit = self:GetRaidUnitForPlayer(playerId)
    if not unit or not self:IsPlayerInTradeRange(playerId) then
        SF:PrintError(string.format("Trade: %s is out of trade range.", entry.displayName or GetDisplayName(playerId)))
        return
    end

    self._expectedTradePlayerId = playerId
    local ok = InitiateTrade(unit)
    if ok == false then
        SF:PrintError(string.format("Trade: Could not open trade with %s.", entry.displayName or GetDisplayName(playerId)))
    end
end

function TradeAssistant:OnTradeShow()
    local playerId = self:_ResolveTradeTargetPlayerId()
    self._expectedTradePlayerId = nil
    self._activeTradePlayerId = playerId
    self._lastTradePlayerId = playerId

    if playerId and self.pending[playerId] then
        self:PopulateTradeWindow(playerId)
    end

    self:RefreshWindow()
end

function TradeAssistant:_ResolveTradeTargetPlayerId()
    local npcName = GetUnitName and GetUnitName("NPC", true)
    local playerId = GetNormalizedPlayerId(npcName)
    if playerId and self.pending[playerId] then
        return playerId
    end

    if self._expectedTradePlayerId and self.pending[self._expectedTradePlayerId] then
        return self._expectedTradePlayerId
    end

    return nil
end

function TradeAssistant:FindBagStacks(itemID)
    local stacks = {}

    if not C_Container then
        return stacks
    end

    for bag = 0, GetBagSlotCount() do
        local slotCount = C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slotCount do
            local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and (info.stackCount or 0) > 0 and not info.isLocked then
                table.insert(stacks, {
                    bag = bag,
                    slot = slot,
                    count = info.stackCount,
                })
            end
        end
    end

    return stacks
end

function TradeAssistant:GetNextTradeSlot()
    for slot = 1, MAX_TRADE_ITEMS do
        local name = GetTradePlayerItemInfo(slot)
        if not name then
            return slot
        end
    end

    return nil
end

function TradeAssistant:PickupBagItem(bag, slot, amount, stackCount)
    if not C_Container then
        return false
    end

    if amount < stackCount and C_Container.SplitContainerItem then
        C_Container.SplitContainerItem(bag, slot, amount)
    elseif C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bag, slot)
    end

    return CursorHasItem and CursorHasItem() or false
end

function TradeAssistant:PopulateTradeWindow(playerId)
    local entry = self.pending[playerId]
    if not entry or type(entry.items) ~= "table" then
        return
    end

    for _, item in ipairs(entry.items) do
        local stacks = self:FindBagStacks(item.itemID)
        local available = 0
        for _, stack in ipairs(stacks) do
            available = available + (stack.count or 0)
        end

        if available < item.quantity then
            SF:PrintError(string.format("Trade: Could not find %s in your bags.", item.itemLink or item.itemName or ("item:" .. tostring(item.itemID))))
        else
            local remaining = item.quantity
            for _, stack in ipairs(stacks) do
                if remaining <= 0 then
                    break
                end

                local slot = self:GetNextTradeSlot()
                if not slot then
                    SF:PrintError(string.format("Trade: Could not add %s to the trade window.", item.itemLink or item.itemName or ("item:" .. tostring(item.itemID))))
                    break
                end

                local amount = math.min(remaining, stack.count)
                local pickedUp = self:PickupBagItem(stack.bag, stack.slot, amount, stack.count)
                if not pickedUp then
                    SF:PrintError(string.format("Trade: Could not add %s to the trade window.", item.itemLink or item.itemName or ("item:" .. tostring(item.itemID))))
                    break
                end

                ClickTradeButton(slot)
                if CursorHasItem and CursorHasItem() then
                    ClearCursor()
                    SF:PrintError(string.format("Trade: Could not add %s to the trade window.", item.itemLink or item.itemName or ("item:" .. tostring(item.itemID))))
                    break
                end

                remaining = remaining - amount
            end
        end
    end
end

function TradeAssistant:CreateWindow()
    if self._frame then
        return self._frame
    end

    local frame = CreateFrame("Frame", WINDOW_NAME, UIParent, "BackdropTemplate")
    frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:Hide()

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

    local title = CreateFrame("Frame", nil, frame)
    title:SetHeight(TITLE_HEIGHT)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
    title:EnableMouse(true)
    title:SetScript("OnMouseDown", function()
        frame:StartMoving()
    end)
    title:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
    end)

    local titleBG = title:CreateTexture(nil, "BACKGROUND")
    titleBG:SetAllPoints(title)
    titleBG:SetColorTexture(0.08, 0.08, 0.08, 0.85)

    local titleText = title:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    titleText:SetPoint("LEFT", title, "LEFT", 10, 0)
    titleText:SetText("Pending Trades")
    titleText:SetJustifyH("LEFT")

    local closeButton = CreateFrame("Button", nil, title, "UIPanelCloseButton")
    closeButton:SetPoint("RIGHT", title, "RIGHT", -4, 0)
    closeButton:SetSize(20, 20)
    closeButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -(TITLE_HEIGHT + PADDING + 6))
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING, PADDING)

    local scroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -24, 0)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)

    local emptyText = child:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    emptyText:SetPoint("TOPLEFT", child, "TOPLEFT", 8, -8)
    emptyText:SetPoint("TOPRIGHT", child, "TOPRIGHT", -8, -8)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetText("No pending trades.")

    frame.Content = content
    frame.Scroll = scroll
    frame.Child = child
    frame.EmptyText = emptyText
    frame.Rows = {}

    frame:SetScript("OnShow", function()
        frame:Raise()
        self._rangeRefreshElapsed = 0
        self:RefreshWindow()
    end)

    frame:SetScript("OnUpdate", function(_, elapsed)
        self._rangeRefreshElapsed = (self._rangeRefreshElapsed or 0) + elapsed
        if self._rangeRefreshElapsed >= RANGE_REFRESH_INTERVAL then
            self._rangeRefreshElapsed = 0
            self:RefreshWindow()
        end
    end)

    self._frame = frame
    return frame
end

function TradeAssistant:GetOrCreateRow(index)
    local frame = self:CreateWindow()
    if frame.Rows[index] then
        return frame.Rows[index]
    end

    local row = CreateFrame("Button", nil, frame.Child)
    row:SetHeight(ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")

    if index == 1 then
        row:SetPoint("TOPLEFT", frame.Child, "TOPLEFT", 0, 0)
        row:SetPoint("TOPRIGHT", frame.Child, "TOPRIGHT", -6, 0)
    else
        row:SetPoint("TOPLEFT", frame.Rows[index - 1], "BOTTOMLEFT", 0, -4)
        row:SetPoint("TOPRIGHT", frame.Rows[index - 1], "BOTTOMRIGHT", 0, -4)
    end

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    bg:SetColorTexture(1, 1, 1, 0.04)
    row.Background = bg

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(row)
    highlight:SetColorTexture(1, 1, 1, 0.10)

    local nameText = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
    nameText:SetPoint("RIGHT", row, "RIGHT", -28, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    row.NameText = nameText

    local summaryText = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    summaryText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -2)
    summaryText:SetPoint("RIGHT", row, "RIGHT", -28, 0)
    summaryText:SetJustifyH("LEFT")
    summaryText:SetWordWrap(false)
    row.SummaryText = summaryText

    local removeButton = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    removeButton:SetPoint("TOPRIGHT", row, "TOPRIGHT", -2, -2)
    removeButton:SetSize(18, 18)
    removeButton:SetScript("OnClick", function()
        if row.playerId then
            self:RemovePendingPlayer(row.playerId)
        end
    end)
    row.RemoveButton = removeButton

    row:SetScript("OnClick", function()
        if row.playerId then
            self:BeginTrade(row.playerId)
        end
    end)

    frame.Rows[index] = row
    return row
end

function TradeAssistant:RefreshWindow()
    local frame = self._frame
    if not frame or not frame:IsShown() then
        return
    end

    local players = self:GetSortedPendingPlayers()
    frame.Child:SetWidth(math.max((frame.Scroll:GetWidth() or WINDOW_WIDTH) - 8, 1))
    frame.EmptyText:SetShown(#players == 0)

    for i, entry in ipairs(players) do
        local row = self:GetOrCreateRow(i)
        local inRange = self:IsPlayerInTradeRange(entry.playerId)

        row.playerId = entry.playerId
        row.NameText:SetText(entry.displayName or GetDisplayName(entry.playerId))
        row.NameText:SetTextColor(inRange and 0.25 or 1, inRange and 1 or 0.25, 0.25, 1)
        row.SummaryText:SetText(SummarizeItems(entry.items))
        row:Show()
    end

    for i = #players + 1, #frame.Rows do
        frame.Rows[i]:Hide()
        frame.Rows[i].playerId = nil
    end

    local contentHeight = math.max(#players * (ROW_HEIGHT + 4), 40)
    frame.Child:SetHeight(contentHeight)
end

function TradeAssistant:ShowWindow()
    local frame = self:CreateWindow()
    frame:Show()
    frame:Raise()
    self:RefreshWindow()
end

function SF:RegisterTradeAssistantSlashCommands()
    if self._tradeAssistantSlashRegistered then
        return
    end

    self._tradeAssistantSlashRegistered = true
    self:RegisterSlashCommand(
        "trade",
        function(args)
            if SF.TradeAssistant and SF.TradeAssistant.HandleSlashCommand then
                SF.TradeAssistant:HandleSlashCommand(args)
            end
        end,
        "Opens the raid trade assistant window. Shift-click an item: /sf trade [shift-click item] [quantity]"
    )
end
