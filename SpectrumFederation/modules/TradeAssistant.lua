-- modules/TradeAssistant.lua
-- Raid Trade Assistant: queue items to trade to raid members
local addonName, SF = ...

SF.TradeAssistant = SF.TradeAssistant or {}
local TA = SF.TradeAssistant

-- ============================================================================
-- Constants
-- ============================================================================

local TRADE_DISTANCE = 2 -- CheckInteractDistance index for trade (11 yards)
local RANGE_UPDATE_INTERVAL = 1.0 -- seconds between range checks

-- ============================================================================
-- Saved Variable Access
-- ============================================================================

local function GetDB()
    SpectrumFederationCharDB = SpectrumFederationCharDB or {}
    SpectrumFederationCharDB.tradeAssistant = SpectrumFederationCharDB.tradeAssistant or {}
    return SpectrumFederationCharDB.tradeAssistant
end

local function GetPendingTrades()
    local db = GetDB()
    db.pending = db.pending or {}
    return db.pending
end

-- ============================================================================
-- Data Helpers
-- ============================================================================

--- Get the list of pending player keys
-- @return table Array of player identifiers with pending items
function TA:GetPendingPlayerList()
    local pending = GetPendingTrades()
    local list = {}
    for playerId in pairs(pending) do
        table.insert(list, playerId)
    end
    table.sort(list)
    return list
end

--- Get queued items for a player
-- @param playerId string Player identifier (Name-Realm)
-- @return table|nil Array of item entries or nil
function TA:GetPlayerItems(playerId)
    local pending = GetPendingTrades()
    return pending[playerId]
end

--- Check if there are any pending trades
-- @return boolean
function TA:HasPendingTrades()
    local pending = GetPendingTrades()
    for _ in pairs(pending) do
        return true
    end
    return false
end

--- Remove a player from the pending list
-- @param playerId string Player identifier (Name-Realm)
function TA:RemovePlayer(playerId)
    local pending = GetPendingTrades()
    pending[playerId] = nil
    self:_NotifyRefresh()
end

--- Clear all pending trades
function TA:ClearAll()
    local db = GetDB()
    db.pending = {}
    self:_NotifyRefresh()
end

-- ============================================================================
-- Item Link Parsing
-- ============================================================================

--- Parse an item link from command args
-- Returns itemLink, itemId or nil on failure
local function ParseItemLink(text)
    -- Match a WoW item link pattern (supports both hex |cFFFFFFFF and named |cnCOLOR_NAME: color formats)
    local link = text:match("|c[^|]+|Hitem:[^|]+|h%[.-%]|h|r")
    if not link then
        return nil, nil
    end

    -- Extract item ID from the link
    local itemId = link:match("|Hitem:(%d+)")
    if itemId then
        itemId = tonumber(itemId)
    end

    return link, itemId
end

--- Parse the trade command arguments
-- @param args string The raw arguments after "/sf trade"
-- @return itemLink, itemId, quantity, errorMsg
function TA:ParseTradeArgs(args)
    if not args or args:trim() == "" then
        return nil, nil, nil, nil -- No args = just open window
    end

    local trimmed = args:trim()

    -- Try to extract item link
    local itemLink, itemId = ParseItemLink(trimmed)
    if not itemLink then
        return nil, nil, nil, "SF Trade: Invalid item. Shift-click an item from your bags, for example: /sf trade [item] 1"
    end

    -- Find the quantity after the item link
    local afterLink = trimmed:match("|r%s*(.*)$")
    local quantity = 1

    if afterLink and afterLink:trim() ~= "" then
        local qtyStr = afterLink:trim()
        local qtyNum = tonumber(qtyStr)
        if not qtyNum then
            return nil, nil, nil, "SF Trade: Invalid quantity. Quantity must be a number greater than 0."
        end
        if qtyNum < 1 then
            return nil, nil, nil, "SF Trade: Invalid quantity. Quantity must be a number greater than 0."
        end
        quantity = math.floor(qtyNum)
    end

    return itemLink, itemId, quantity, nil
end

-- ============================================================================
-- Raid Roster Helpers
-- ============================================================================

--- Get current raid members excluding self
-- @return table Array of { id = "Name-Realm", name = "Name" }
local function GetRaidMembersExceptSelf()
    local members = {}
    local selfId = SF.NameUtil and SF.NameUtil.GetSelfId and SF.NameUtil.GetSelfId()

    if not IsInRaid() then
        return members
    end

    local numMembers = GetNumGroupMembers()
    for i = 1, numMembers do
        local name, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
        if name then
            local normalized = SF.NameUtil and SF.NameUtil.NormalizeNameRealm(name) or name
            if normalized and (not selfId or normalized:lower() ~= selfId:lower()) then
                table.insert(members, {
                    id = normalized,
                    name = name,
                })
            end
        end
    end

    return members
end

-- ============================================================================
-- Queue Items for Raid
-- ============================================================================

--- Queue an item for all current raid members
-- @param itemLink string The item link
-- @param itemId number The item ID
-- @param quantity number The quantity per player
function TA:QueueForRaid(itemLink, itemId, quantity)
    local members = GetRaidMembersExceptSelf()
    if #members == 0 then
        SF:PrintError("SF Trade: You are not in a raid, or no other raid members found.")
        return false
    end

    local pending = GetPendingTrades()

    for _, member in ipairs(members) do
        local playerId = member.id
        if not pending[playerId] then
            pending[playerId] = {}
        end

        table.insert(pending[playerId], {
            itemLink = itemLink,
            itemId = itemId,
            quantity = quantity,
        })
    end

    SF:PrintSuccess(string.format("SF Trade: Queued %dx %s for %d raid members.",
        quantity, itemLink, #members))

    self:_NotifyRefresh()
    return true
end

-- ============================================================================
-- Range Check
-- ============================================================================

--- Check if a player is in trade range
-- @param playerId string Player identifier (Name-Realm)
-- @return boolean
function TA:IsPlayerInRange(playerId)
    if not IsInRaid() then return false end

    local numMembers = GetNumGroupMembers()
    for i = 1, numMembers do
        local name = GetRaidRosterInfo(i)
        if name then
            local normalized = SF.NameUtil and SF.NameUtil.NormalizeNameRealm(name) or name
            if normalized and normalized:lower() == playerId:lower() then
                local unit = "raid" .. i
                if UnitExists(unit) and CheckInteractDistance(unit, TRADE_DISTANCE) then
                    return true
                end
                return false
            end
        end
    end
    return false
end

--- Get the raid unit ID for a player
-- @param playerId string Player identifier (Name-Realm)
-- @return string|nil unit ID or nil
function TA:GetPlayerUnit(playerId)
    if not IsInRaid() then return nil end

    local numMembers = GetNumGroupMembers()
    for i = 1, numMembers do
        local name = GetRaidRosterInfo(i)
        if name then
            local normalized = SF.NameUtil and SF.NameUtil.NormalizeNameRealm(name) or name
            if normalized and normalized:lower() == playerId:lower() then
                return "raid" .. i
            end
        end
    end
    return nil
end

-- ============================================================================
-- Trade Initiation
-- ============================================================================

--- Attempt to initiate trade with a player
-- @param playerId string Player identifier (Name-Realm)
function TA:InitiateTrade(playerId)
    if not self:IsPlayerInRange(playerId) then
        local displayName = playerId:match("^([^%-]+)") or playerId
        SF:PrintError("SF Trade: " .. displayName .. " is out of trade range.")
        return
    end

    local unit = self:GetPlayerUnit(playerId)
    if not unit then
        SF:PrintError("SF Trade: Could not find player unit.")
        return
    end

    InitiateTrade(unit)
end

-- ============================================================================
-- Trade Window Event Handling
-- ============================================================================

--- Handle TRADE_SHOW event - attempt to place queued items
function TA:OnTradeShow()
    local targetName = GetUnitName("NPC", true) or TradeFrameRecipientNameText and TradeFrameRecipientNameText:GetText()
    if not targetName or targetName == "" then
        -- Try alternate method
        targetName = UnitName("NPC")
    end

    if not targetName then return end

    local targetId = SF.NameUtil and SF.NameUtil.NormalizeNameRealm(targetName) or targetName
    if not targetId then return end

    local pending = GetPendingTrades()
    local items = pending[targetId]

    -- Also try case-insensitive lookup
    if not items then
        for playerId, playerItems in pairs(pending) do
            if playerId:lower() == targetId:lower() then
                items = playerItems
                targetId = playerId
                break
            end
        end
    end

    if not items or #items == 0 then return end

    -- Store the trade target for completion handling
    self._currentTradeTarget = targetId

    -- Queue item placement (must happen over multiple frames due to WoW API)
    self:_QueueItemPlacement(items)
end

--- Handle TRADE_CLOSED event
function TA:OnTradeClosed()
    self._currentTradeTarget = nil
    self._placementQueue = nil
end

--- Handle UI_ERROR_MESSAGE for trade failures
function TA:OnTradeComplete()
    local targetId = self._currentTradeTarget
    if not targetId then return end

    -- Remove from pending list on successful trade
    local pending = GetPendingTrades()
    if pending[targetId] then
        pending[targetId] = nil
        local displayName = targetId:match("^([^%-]+)") or targetId
        SF:PrintSuccess("SF Trade: Completed trade with " .. displayName .. ".")
        self:_NotifyRefresh()
    end

    self._currentTradeTarget = nil
    self._placementQueue = nil
end

--- Handle trade failure/cancel
function TA:OnTradeFailed()
    self._currentTradeTarget = nil
    self._placementQueue = nil
    self:_NotifyRefresh()
end

-- ============================================================================
-- Item Placement (into trade window)
-- ============================================================================

--- Queue items to be placed into the trade window over successive frames
-- @param items table Array of {itemLink, itemId, quantity}
function TA:_QueueItemPlacement(items)
    self._placementQueue = {}

    for _, entry in ipairs(items) do
        for _ = 1, (entry.quantity or 1) do
            table.insert(self._placementQueue, {
                itemLink = entry.itemLink,
                itemId = entry.itemId,
            })
        end
    end

    self._placementIndex = 1
    self:_ProcessNextPlacement()
end

--- Process the next item placement from the queue
function TA:_ProcessNextPlacement()
    if not self._placementQueue then return end
    if not self._placementIndex then return end
    if self._placementIndex > #self._placementQueue then
        self._placementQueue = nil
        self._placementIndex = nil
        return
    end

    local entry = self._placementQueue[self._placementIndex]
    self._placementIndex = self._placementIndex + 1

    -- Find the item in bags
    local bagId, slotId = self:_FindItemInBags(entry.itemId)
    if not bagId then
        SF:PrintError("SF Trade: Could not find " .. (entry.itemLink or "item") .. " in your bags.")
        -- Continue with next item
        if C_Timer and C_Timer.After then
            C_Timer.After(0.1, function() self:_ProcessNextPlacement() end)
        end
        return
    end

    -- Pick up the item and place it in the trade window
    ClearCursor()
    C_Container.PickupContainerItem(bagId, slotId)

    -- Find an empty trade slot
    local tradeSlot = self:_FindEmptyTradeSlot()
    if not tradeSlot then
        SF:PrintError("SF Trade: Could not add " .. (entry.itemLink or "item") .. " to the trade window.")
        ClearCursor()
        if C_Timer and C_Timer.After then
            C_Timer.After(0.1, function() self:_ProcessNextPlacement() end)
        end
        return
    end

    ClickTradeButton(tradeSlot)

    -- Schedule next placement
    if C_Timer and C_Timer.After then
        C_Timer.After(0.1, function() self:_ProcessNextPlacement() end)
    end
end

--- Find an item in the player's bags by item ID
-- @param itemId number
-- @return bagId, slotId or nil, nil
function TA:_FindItemInBags(itemId)
    if not itemId then return nil, nil end

    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemId then
                return bag, slot
            end
        end
    end

    return nil, nil
end

--- Find an empty trade slot (player's side, slots 1-6)
-- @return number|nil slot index or nil
function TA:_FindEmptyTradeSlot()
    for i = 1, 6 do
        local _, _, _, _, _, hasItem = GetTradePlayerItemInfo(i)
        if not hasItem then
            return i
        end
    end
    return nil
end

-- ============================================================================
-- Refresh Notification
-- ============================================================================

function TA:_NotifyRefresh()
    if self.OnRefresh then
        self:OnRefresh()
    end
end

-- ============================================================================
-- Event Frame
-- ============================================================================

function TA:Init()
    if self._initialized then return end

    local ef = CreateFrame("Frame")
    self._eventFrame = ef

    ef:RegisterEvent("TRADE_SHOW")
    ef:RegisterEvent("TRADE_CLOSED")
    ef:RegisterEvent("TRADE_ACCEPT_UPDATE")
    ef:RegisterEvent("UI_INFO_MESSAGE")

    ef:SetScript("OnEvent", function(_, event, ...)
        if event == "TRADE_SHOW" then
            self:OnTradeShow()
        elseif event == "TRADE_CLOSED" then
            self:OnTradeClosed()
        elseif event == "UI_INFO_MESSAGE" then
            local _, msg = ...
            if msg and (msg == ERR_TRADE_COMPLETE or (type(msg) == "string" and msg:find("Trade complete"))) then
                self:OnTradeComplete()
            elseif msg and (msg == ERR_TRADE_CANCELLED or (type(msg) == "string" and msg:find("Trade cancelled"))) then
                self:OnTradeFailed()
            end
        end
    end)

    self._initialized = true

    if SF.Debug then
        SF.Debug:Info("TRADE", "TradeAssistant initialized")
    end
end

-- ============================================================================
-- Slash Command Handler
-- ============================================================================

--- Handle the /sf trade command
-- @param args string Raw arguments
function TA:HandleCommand(args)
    -- Initialize if not done
    self:Init()

    -- Parse arguments
    local itemLink, itemId, quantity, errMsg = self:ParseTradeArgs(args)

    if errMsg then
        SF:PrintError(errMsg)
        return
    end

    -- If an item was provided, queue it for raid
    if itemLink and itemId then
        self:QueueForRaid(itemLink, itemId, quantity)
    end

    -- Always open the window
    self:ShowWindow()
end

-- ============================================================================
-- Window Management
-- ============================================================================

function TA:ShowWindow()
    if SF.TradeAssistantWindow and SF.TradeAssistantWindow.Show then
        SF.TradeAssistantWindow:Show()
    end
end

function TA:HideWindow()
    if SF.TradeAssistantWindow and SF.TradeAssistantWindow.Hide then
        SF.TradeAssistantWindow:Hide()
    end
end
