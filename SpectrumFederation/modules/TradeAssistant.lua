-- Runtime-only raid trade assistant for /sf trade (#269).
-- Queue state is intentionally not saved: reload or logout clears it.
local addonName, SF = ...

SF.TradeAssistant = SF.TradeAssistant or {}
local TA = SF.TradeAssistant

local NameUtil = SF.NameUtil

TA.TRADE_SLOTS = 6
TA.RANGE_CHECK_INDEX = 2 -- CheckInteractDistance trade range
TA.AUTO_FILL_WINDOW_SECONDS = 5

local state = {
    players = {}, -- lowercased Name-Realm -> entry
    order = {}, -- stable display order of player keys
    activeTrade = nil, -- { key, name, lifecycle, playerAccepted, targetAccepted, autoFill }
    tradeLifecycle = 0,
    listenersAttached = false,
    frame = nil,
    lastAutoFill = nil, -- { key, at }
}

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

local function Trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function FloorQty(value)
    value = tonumber(value) or 0
    if value ~= value or value < 0 then
        return 0
    end
    return math.floor(value)
end

local function NowSeconds()
    if GetTime then
        local ok, value = pcall(GetTime)
        if ok and type(value) == "number" and value == value then
            return value
        end
    end
    return 0
end

local function InCombat()
    if UnitAffectingCombat and UnitAffectingCombat("player") then
        return true
    end
    return InCombatLockdown and InCombatLockdown() or false
end

local function NormalizePlayerId(nameOrNameRealm, realm)
    if NameUtil and NameUtil.NormalizeNameRealm then
        return NameUtil.NormalizeNameRealm(nameOrNameRealm, realm)
    end
    return nil
end

local function PlayerKey(playerId)
    if type(playerId) ~= "string" or playerId == "" then
        return nil
    end
    local normalized = NormalizePlayerId(playerId)
    if not normalized then
        normalized = playerId
    end
    return normalized:lower()
end

local function FindPlayer(playerId)
    local key = PlayerKey(playerId)
    if not key then
        return nil, nil
    end
    return state.players[key], key
end

local function RefreshQueueUI()
    local window = SF.TradeAssistantWindow
    if window and window.Refresh then
        window:Refresh()
    end
end

local function ShowWindow()
    local window = SF.TradeAssistantWindow
    if window and window.Show then
        window:Show()
        return true
    end
    return false
end

local function ExtractItemID(linkOrId)
    if type(linkOrId) ~= "string" then
        return nil
    end
    local itemId = linkOrId:match("^%s*(%d+)%s*$")
    if itemId then
        return tonumber(itemId)
    end
    itemId = linkOrId:match("item:(%d+)")
    if itemId then
        return tonumber(itemId)
    end
    return nil
end

local function ResolveItemID(linkOrId, parsedId)
    local fn = GetItemInfoInstant
    if not fn and C_Item and C_Item.GetItemInfoInstant then
        fn = C_Item.GetItemInfoInstant
    end
    if not fn then
        return parsedId
    end
    local ok, instantId = pcall(fn, linkOrId)
    if not ok or instantId == nil then
        return nil
    end
    return tonumber(instantId) or parsedId
end

local function NormalizeLinkKey(linkOrId)
    if type(linkOrId) ~= "string" then
        return nil
    end
    if linkOrId:find("|H", 1, true) or linkOrId:find("|h", 1, true) then
        return linkOrId:lower()
    end
    return nil
end

function TA:ParseCommand(args)
    local text = Trim(args)
    if text == "" then
        return nil, "empty"
    end

    local linkPart = text
    local quantity = 1
    local beforeQty, qtyText = text:match("^(.-)%s+(%d+)%s*$")
    if beforeQty and qtyText then
        linkPart = Trim(beforeQty)
        quantity = tonumber(qtyText) or 0
    end

    if linkPart == "" then
        return nil, "invalid_item"
    end
    if quantity < 1 or quantity ~= math.floor(quantity) then
        return nil, "invalid_quantity"
    end

    local parsedId = ExtractItemID(linkPart)
    if not parsedId then
        return nil, "invalid_item"
    end

    local itemId = ResolveItemID(linkPart, parsedId)
    if not itemId then
        return nil, "invalid_item"
    end

    return {
        itemId = itemId,
        itemLink = linkPart,
        linkKey = NormalizeLinkKey(linkPart),
        quantity = quantity,
        key = NormalizeLinkKey(linkPart) or ("item:" .. tostring(itemId)),
    }
end

local function ItemDisplayName(item)
    if type(item.itemLink) == "string" then
        local name = item.itemLink:match("%[([^%]]+)%]")
        if name and name ~= "" then
            return name
        end
    end
    if GetItemInfo then
        local ok, itemName = pcall(GetItemInfo, item.itemId)
        if ok and type(itemName) == "string" and itemName ~= "" then
            return itemName
        end
    elseif C_Item and C_Item.GetItemNameByID then
        local ok, itemName = pcall(C_Item.GetItemNameByID, item.itemId)
        if ok and type(itemName) == "string" and itemName ~= "" then
            return itemName
        end
    end
    return item.itemLink or ("item:" .. tostring(item.itemId))
end
TA.ItemDisplayName = ItemDisplayName

local function SlotMatchesItem(bag, slot, item)
    if not C_Container or not C_Container.GetContainerItemInfo then
        return false
    end
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or tonumber(info.itemID) ~= tonumber(item.itemId) then
        return false
    end
    if item.linkKey and C_Container.GetContainerItemLink then
        local link = C_Container.GetContainerItemLink(bag, slot)
        if link and link:lower() ~= item.linkKey then
            return false
        end
    end
    return true
end

local function EachBagSlot(callback)
    if not C_Container or not C_Container.GetContainerNumSlots then
        return
    end
    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        numSlots = FloorQty(numSlots)
        for slot = 1, numSlots do
            callback(bag, slot)
        end
    end
end

local function CountCarriedItem(item)
    local total = 0
    EachBagSlot(function(bag, slot)
        if SlotMatchesItem(bag, slot, item) then
            local info = C_Container.GetContainerItemInfo(bag, slot)
            total = total + FloorQty(info and info.stackCount)
        end
    end)
    return total
end

local function CollectStacksForItem(item)
    local stacks = {}
    EachBagSlot(function(bag, slot)
        if SlotMatchesItem(bag, slot, item) then
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local count = FloorQty(info and info.stackCount)
            if count > 0 then
                stacks[#stacks + 1] = {
                    bag = bag,
                    slot = slot,
                    count = count,
                    locked = info.isLocked == true,
                }
            end
        end
    end)
    table.sort(stacks, function(a, b)
        if a.bag ~= b.bag then
            return a.bag < b.bag
        end
        return a.slot < b.slot
    end)
    return stacks
end

local function QueuedTotalForItem(itemKey)
    local total = 0
    for _, key in ipairs(state.order) do
        local player = state.players[key]
        local item = player and player.items[itemKey]
        if item then
            total = total + FloorQty(item.quantity)
        end
    end
    return total
end

local function BuildRaidUnitMap()
    local map = {}
    if not (IsInRaid and IsInRaid()) then
        return map
    end
    if not GetNumGroupMembers or not UnitExists then
        return map
    end
    for index = 1, GetNumGroupMembers() do
        local unit = "raid" .. index
        local connected = true
        if UnitIsConnected then
            connected = UnitIsConnected(unit) and true or false
        end
        if UnitExists(unit) and connected then
            local name, realm
            if UnitFullName then
                name, realm = UnitFullName(unit)
            elseif UnitName then
                name = UnitName(unit)
            end
            local playerId = NormalizePlayerId(name, realm)
            if playerId then
                map[playerId:lower()] = {
                    unit = unit,
                    name = name or playerId,
                    realm = realm,
                    playerId = playerId,
                    raidIndex = index,
                }
            end
        end
    end
    return map
end

local function GetRaidMembers()
    if not (IsInRaid and IsInRaid()) then
        return nil, "not_in_raid"
    end
    local unitMap = BuildRaidUnitMap()
    local selfId = NameUtil and NameUtil.GetSelfId and NameUtil.GetSelfId() or nil
    local members = {}
    for key, info in pairs(unitMap) do
        local isSelf = false
        if UnitIsUnit and info.unit and UnitIsUnit(info.unit, "player") then
            isSelf = true
        end
        if not isSelf and selfId and NameUtil and NameUtil.SamePlayer then
            isSelf = NameUtil.SamePlayer(info.playerId, selfId)
        end
        if not isSelf then
            members[#members + 1] = {
                key = key,
                unit = info.unit,
                name = info.name,
                realm = info.realm,
                playerId = info.playerId,
                raidIndex = info.raidIndex,
            }
        end
    end
    table.sort(members, function(a, b)
        if a.raidIndex ~= b.raidIndex then
            return a.raidIndex < b.raidIndex
        end
        return tostring(a.name) < tostring(b.name)
    end)
    return members
end

local function EnsurePlayerEntry(member)
    local entry = state.players[member.key]
    if not entry then
        entry = {
            key = member.key,
            playerId = member.playerId,
            name = member.name or member.playerId,
            realm = member.realm,
            raidIndex = member.raidIndex,
            items = {},
            itemOrder = {},
            inRange = nil,
        }
        state.players[member.key] = entry
        state.order[#state.order + 1] = member.key
    else
        entry.name = member.name or entry.name
        entry.realm = member.realm or entry.realm
        entry.raidIndex = member.raidIndex or entry.raidIndex
        entry.playerId = member.playerId or entry.playerId
    end
    return entry
end

local function AddItemToPlayer(entry, item)
    local existing = entry.items[item.key]
    if existing then
        existing.quantity = FloorQty(existing.quantity) + FloorQty(item.quantity)
        existing.itemLink = item.itemLink or existing.itemLink
        return existing
    end
    local stored = {
        key = item.key,
        itemId = item.itemId,
        itemLink = item.itemLink,
        linkKey = item.linkKey,
        quantity = FloorQty(item.quantity),
    }
    entry.items[item.key] = stored
    entry.itemOrder[#entry.itemOrder + 1] = item.key
    return stored
end

function TA:GetPlayerCount()
    local count = 0
    for _ in pairs(state.players) do
        count = count + 1
    end
    return count
end

function TA:GetQueueSnapshot()
    local rows = {}
    for _, key in ipairs(state.order) do
        local entry = state.players[key]
        if entry then
            local itemCount = 0
            local totalQuantity = 0
            local items = {}
            for _, itemKey in ipairs(entry.itemOrder) do
                local item = entry.items[itemKey]
                if item then
                    itemCount = itemCount + 1
                    totalQuantity = totalQuantity + FloorQty(item.quantity)
                    items[#items + 1] = {
                        key = itemKey,
                        itemId = item.itemId,
                        itemLink = item.itemLink,
                        linkKey = item.linkKey,
                        quantity = FloorQty(item.quantity),
                        displayName = ItemDisplayName(item),
                    }
                end
            end
            rows[#rows + 1] = {
                key = entry.key,
                playerId = entry.playerId,
                name = entry.name or entry.playerId,
                realm = entry.realm,
                raidIndex = entry.raidIndex,
                inRange = entry.inRange,
                itemCount = itemCount,
                totalQuantity = totalQuantity,
                items = items,
            }
        end
    end
    return rows
end

function TA:RefreshRangeStates()
    local unitMap = BuildRaidUnitMap()
    local combat = InCombat()
    for _, key in ipairs(state.order) do
        local entry = state.players[key]
        if entry then
            local info = unitMap[entry.key]
            if not info then
                entry.inRange = false
            elseif combat then
                -- CheckInteractDistance is combat-restricted; keep the last known state.
            elseif CheckInteractDistance then
                local ok, result = pcall(CheckInteractDistance, info.unit, TA.RANGE_CHECK_INDEX)
                if ok and result ~= nil then
                    entry.inRange = result and true or false
                else
                    entry.inRange = nil
                end
            else
                entry.inRange = nil
            end
        end
    end
end

function TA:GetPlayerRange(playerId)
    local entry = FindPlayer(playerId)
    return entry and entry.inRange or nil
end

function TA:GetPlayerUnit(playerId)
    local entry = FindPlayer(playerId)
    if not entry then
        return nil
    end
    local key = entry.key or PlayerKey(entry.playerId)
    local info = BuildRaidUnitMap()[key]
    return info and info.unit or nil
end

function TA:RemovePlayer(playerId)
    local entry, key = FindPlayer(playerId)
    if not entry or not key then
        return false
    end
    state.players[key] = nil
    for index = #state.order, 1, -1 do
        if state.order[index] == key then
            table.remove(state.order, index)
        end
    end
    Debug("Info", "Removed %s from trade queue", tostring(entry.name or key))
    RefreshQueueUI()
    return true
end

function TA:ClearQueue()
    state.players = {}
    state.order = {}
    state.activeTrade = nil
    state.lastAutoFill = nil
    RefreshQueueUI()
end

function TA:ResetRuntime()
    state.players = {}
    state.order = {}
    state.activeTrade = nil
    state.lastAutoFill = nil
end

function TA:HandleCommand(args)
    local text = Trim(args)
    if text == "" then
        Debug("Info", "Opening trade assistant window")
        return ShowWindow()
    end

    local item, parseError = TA:ParseCommand(text)
    if not item then
        if parseError == "invalid_quantity" then
            SF:PrintError(Loc("TRADE_ASSISTANT_ERR_QUANTITY", "SF Trade: Quantity must be a positive whole number."))
        else
            SF:PrintError(Loc("TRADE_ASSISTANT_ERR_ITEM", "SF Trade: Enter a valid item link."))
        end
        Debug("Warn", "Rejected /sf trade arguments: %s", tostring(parseError))
        return false
    end

    local members, memberError = GetRaidMembers()
    if not members then
        SF:PrintError(Loc("TRADE_ASSISTANT_ERR_NOT_IN_RAID", "SF Trade: You must be in a raid."))
        Debug("Warn", "Rejected /sf trade outside a raid: %s", tostring(memberError))
        return false
    end
    if #members == 0 then
        SF:PrintError(Loc("TRADE_ASSISTANT_ERR_NO_MEMBERS", "SF Trade: No other raid members are in the raid."))
        return false
    end

    local available = CountCarriedItem(item)
    local required = QueuedTotalForItem(item.key) + (FloorQty(item.quantity) * #members)
    if available < required then
        SF:PrintError(Loc("TRADE_ASSISTANT_ERR_INSUFFICIENT", "SF Trade failed."))
        Debug("Info", "Rejected /sf trade: available=%d required=%d item=%s", available, required, tostring(item.itemId))
        return false
    end

    TA:EnsureListeners()
    for _, member in ipairs(members) do
        AddItemToPlayer(EnsurePlayerEntry(member), item)
    end
    TA:RefreshRangeStates()
    RefreshQueueUI()
    ShowWindow()

    SF:PrintSuccess(string.format(
        Loc("TRADE_ASSISTANT_QUEUED", "SF Trade: Added %dx %s to the trade list."),
        FloorQty(item.quantity),
        ItemDisplayName(item)
    ))
    Debug("Info", "Queued %dx item %s for %d raid members", FloorQty(item.quantity), tostring(item.itemId), #members)
    return true
end

local function CursorBusy()
    if not GetCursorInfo then
        return false
    end
    local ok, info = pcall(GetCursorInfo)
    return ok and info ~= nil
end

local function CountFreeTradeSlots()
    if not GetTradePlayerItemInfo then
        return 0
    end
    local free = 0
    for slot = 1, TA.TRADE_SLOTS do
        local name = GetTradePlayerItemInfo(slot)
        if not name then
            free = free + 1
        end
    end
    return free
end

local function PlanMoves(entry, freeSlots)
    local moves = {}
    local slotsLeft = FloorQty(freeSlots)
    for _, itemKey in ipairs(entry.itemOrder) do
        local item = entry.items[itemKey]
        if item and slotsLeft > 0 then
            local remaining = FloorQty(item.quantity)
            local stacks = CollectStacksForItem(item)
            for _, stack in ipairs(stacks) do
                if remaining < 1 or slotsLeft < 1 then
                    break
                end
                if not stack.locked and stack.count > 0 then
                    local take = math.min(stack.count, remaining)
                    moves[#moves + 1] = {
                        item = item,
                        bag = stack.bag,
                        slot = stack.slot,
                        quantity = take,
                    }
                    remaining = remaining - take
                    slotsLeft = slotsLeft - 1
                end
            end
            if remaining > 0 then
                Debug("Info", "Trade prefill deferred for %s: %d units did not fit", tostring(itemKey), remaining)
            end
        end
    end
    return moves
end

local function PlaceOfferFromStack(bag, slot, quantity)
    if CursorBusy() then
        return false, "cursor_busy"
    end
    bag = tonumber(bag)
    slot = tonumber(slot)
    quantity = FloorQty(quantity)
    if not bag or not slot or quantity < 1 then
        return false, "not_carried"
    end
    if not C_Container or not C_Container.GetContainerItemInfo then
        return false, "unsupported"
    end
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or info.isLocked then
        return false, "locked"
    end
    local have = FloorQty(info.stackCount)
    if have < 1 then
        return false, "not_carried"
    end
    local take = math.min(quantity, have)
    if take < have then
        if not C_Container.SplitContainerItem then
            return false, "unsupported"
        end
        C_Container.SplitContainerItem(bag, slot, take)
    elseif C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bag, slot)
    else
        return false, "unsupported"
    end
    if not ClickTradeButton then
        if ClearCursor then
            ClearCursor()
        end
        return false, "unsupported"
    end
    for tradeSlot = 1, TA.TRADE_SLOTS do
        local itemName = GetTradePlayerItemInfo and GetTradePlayerItemInfo(tradeSlot)
        if not itemName then
            ClickTradeButton(tradeSlot)
            if CursorBusy() then
                if ClearCursor then
                    ClearCursor()
                end
                return false, "place_failed"
            end
            return true, take
        end
    end
    if ClearCursor then
        ClearCursor()
    end
    return false, "no_slot"
end

function TA:TryPrefillTrade(lifecycle, key)
    local trade = state.activeTrade
    if not trade or trade.lifecycle ~= lifecycle or trade.key ~= key then
        return false
    end
    if not trade.autoFill then
        return false
    end
    local entry = state.players[key]
    if not entry then
        return false
    end
    local unit = TA:GetPlayerUnit(entry.playerId)
    if not unit then
        Debug("Warn", "Trade prefill skipped: %s is no longer in the raid", tostring(entry.name or key))
        return false
    end

    local freeSlots = CountFreeTradeSlots()
    if freeSlots < 1 then
        Debug("Info", "Trade prefill skipped: no free trade slots")
        return false
    end

    local moves = PlanMoves(entry, freeSlots)
    local placed = 0
    local attempted = 0
    for _, move in ipairs(moves) do
        attempted = attempted + 1
        local ok, result = PlaceOfferFromStack(move.bag, move.slot, move.quantity)
        if ok then
            placed = placed + FloorQty(result)
        else
            Debug("Warn", "Trade prefill move failed for %s: %s", tostring(move.item and move.item.key or "item"), tostring(result))
            break
        end
    end
    Debug("Info", "Trade prefill lifecycle=%d player=%s moves=%d placed=%d", lifecycle, tostring(entry.name or key), attempted, placed)
    return placed > 0
end

local function TradeAcceptFlag(value)
    return tonumber(value) == 1
end

local function GetTradeTargetKey()
    if not UnitName then
        return nil, nil
    end
    local name, realm = UnitName("NPC")
    if not name or name == "" then
        return nil, nil
    end
    local playerId = NormalizePlayerId(name, realm)
    if not playerId then
        return nil, nil
    end
    return playerId:lower(), name
end

local function ShouldAutoFill(key)
    local last = state.lastAutoFill
    if not last or last.key ~= key then
        return false
    end
    local now = NowSeconds()
    return (now - last.at) <= TA.AUTO_FILL_WINDOW_SECONDS
end

local function OnTradeShow()
    state.tradeLifecycle = state.tradeLifecycle + 1
    local key, name = GetTradeTargetKey()
    local autoFill = key ~= nil and ShouldAutoFill(key)
    if autoFill then
        state.lastAutoFill = nil
    end
    state.activeTrade = {
        key = key,
        name = name,
        lifecycle = state.tradeLifecycle,
        playerAccepted = false,
        targetAccepted = false,
        autoFill = autoFill,
    }
    if autoFill then
        local lifecycle = state.tradeLifecycle
        if C_Timer and C_Timer.After then
            C_Timer.After(0.1, function()
                TA:TryPrefillTrade(lifecycle, key)
            end)
        else
            TA:TryPrefillTrade(lifecycle, key)
        end
    end
    Debug("Info", "Trade shown: target=%s autoFill=%s", tostring(name or key or "unknown"), tostring(autoFill))
end

local function OnTradeAcceptUpdate(playerAccepted, targetAccepted)
    local trade = state.activeTrade
    if not trade then
        return
    end
    if playerAccepted ~= nil then
        trade.playerAccepted = TradeAcceptFlag(playerAccepted)
    end
    if targetAccepted ~= nil then
        trade.targetAccepted = TradeAcceptFlag(targetAccepted)
    end
end

local function OnTradeClosed()
    local trade = state.activeTrade
    state.activeTrade = nil
    if not trade or not trade.key then
        return
    end
    if trade.playerAccepted and trade.targetAccepted then
        local removed = TA:RemovePlayer(trade.key)
        if removed then
            Debug("Info", "Completed trade removed %s from queue", tostring(trade.name or trade.key))
        end
    else
        Debug("Info", "Trade closed without completion for %s", tostring(trade.name or trade.key))
    end
end

function TA:TradeWithPlayer(playerId)
    local entry = FindPlayer(playerId)
    if not entry then
        return false, "not_queued"
    end
    if InCombat() then
        Debug("Info", "Trade click ignored during combat for %s", tostring(entry.name or playerId))
        return false, "combat"
    end
    local unit = TA:GetPlayerUnit(entry.playerId)
    if not unit then
        return false, "not_in_raid"
    end
    TA:RefreshRangeStates()
    if entry.inRange == false then
        return false, "out_of_range"
    end
    if not InitiateTrade then
        return false, "unsupported"
    end
    state.lastAutoFill = {
        key = entry.key,
        at = NowSeconds(),
    }
    local ok, err = pcall(InitiateTrade, unit)
    if not ok then
        Debug("Error", "InitiateTrade failed for %s: %s", tostring(entry.name or entry.key), tostring(err))
        state.lastAutoFill = nil
        return false, "failed"
    end
    Debug("Info", "Initiated trade with %s", tostring(entry.name or entry.key))
    return true
end

function TA:EnsureListeners()
    if state.listenersAttached then
        return
    end
    if not CreateFrame then
        return
    end
    state.listenersAttached = true
    local frame = CreateFrame("Frame", "SpectrumFederationTradeAssistant")
    state.frame = frame
    frame:RegisterEvent("TRADE_SHOW")
    frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
    frame:RegisterEvent("TRADE_CLOSED")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "TRADE_SHOW" then
            OnTradeShow()
        elseif event == "TRADE_ACCEPT_UPDATE" then
            OnTradeAcceptUpdate(...)
        elseif event == "TRADE_CLOSED" then
            OnTradeClosed()
        elseif event == "PLAYER_LOGOUT" then
            TA:ResetRuntime()
        end
    end)
end

if SF.RegisterSlashCommand then
    SF:RegisterSlashCommand(
        "trade",
        function(args)
            TA:HandleCommand(args)
        end,
        Loc("TRADE_ASSISTANT_SLASH_DESC", "Queue items to trade to raid members"),
        { preserveArgs = true }
    )
end
