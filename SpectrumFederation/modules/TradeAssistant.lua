-- Runtime-only raid trade assistant for /sf trade (#269).
-- Queue state is intentionally not saved: reload or logout clears it.
local addonName, SF = ...

SF.TradeAssistant = SF.TradeAssistant or {}
local TA = SF.TradeAssistant

local NameUtil = SF.NameUtil

TA.TRADE_SLOTS = 6
TA.RANGE_CHECK_INDEX = 2 -- CheckInteractDistance trade range
TA.SETTLEMENT_DELAY_SECONDS = 0.2

local state = {
    players = {}, -- lowercased Name-Realm -> entry
    order = {}, -- stable display order of player keys
    activeTrade = nil, -- { key, name, lifecycle, playerAccepted, targetAccepted, autoFill, cancelled }
    pendingTrade = nil, -- accepted trade awaiting cancellation ordering before settlement
    tradeLifecycle = 0,
    listenersAttached = false,
    frame = nil,
    lastAutoFill = nil, -- { key }
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
    if not (linkOrId:find("|H", 1, true) or linkOrId:find("|h", 1, true)) then
        return nil
    end
    local itemData = linkOrId:match("item:([^|]+)")
    if not itemData then
        return nil
    end
    return ("item:" .. itemData):lower()
end

function TA:ParseCommand(args)
    local text = Trim(args)
    if text == "" then
        return nil, "empty"
    end

    local linkPart = text
    local quantity = 1
    local _, linkEnd = text:find("|h|r", 1, true)
    if linkEnd then
        linkPart = Trim(text:sub(1, linkEnd))
        local suffix = Trim(text:sub(linkEnd + 1))
        if suffix ~= "" then
            if not suffix:match("^%d+$") then
                return nil, "invalid_quantity"
            end
            quantity = tonumber(suffix) or 0
        end
    else
        local beforeQty, qtyText = text:match("^(.-)%s+(%d+)%s*$")
        if beforeQty and qtyText then
            linkPart = Trim(beforeQty)
            quantity = tonumber(qtyText) or 0
        end
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
    end
    if C_Item and C_Item.GetItemNameByID then
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
    if item.linkKey then
        if not C_Container.GetContainerItemLink then
            return false
        end
        local link = C_Container.GetContainerItemLink(bag, slot)
        if not link then
            return false
        end
        if NormalizeLinkKey(link) ~= item.linkKey then
            return false
        end
    end
    return true
end

local function EachBagSlot(callback)
    if not C_Container or not C_Container.GetContainerNumSlots then
        return
    end
    -- Carried containers are bags 0-4 plus the reagent bag at 5.
    for bag = 0, 5 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        numSlots = FloorQty(numSlots)
        for slot = 1, numSlots do
            callback(bag, slot)
        end
    end
end

local function SupplyCountsForItemId(itemId)
    local supply = {}
    local total = 0
    local wantedId = tonumber(itemId)
    if not wantedId or not C_Container.GetContainerItemInfo then
        return supply, total
    end
    EachBagSlot(function(bag, slot)
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and tonumber(info.itemID) == wantedId then
            local variant = "unknown"
            if C_Container.GetContainerItemLink then
                local link = C_Container.GetContainerItemLink(bag, slot)
                if link then
                    variant = NormalizeLinkKey(link) or "unknown"
                end
            end
            local count = FloorQty(info.stackCount)
            if count > 0 then
                supply[variant] = (supply[variant] or 0) + count
                total = total + count
            end
        end
    end)
    return supply, total
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

local function QueuedDemandForItemId(itemId)
    local exact = {}
    local bare = 0
    local wantedId = tonumber(itemId)
    if not wantedId then
        return exact, bare
    end
    for _, key in ipairs(state.order) do
        local player = state.players[key]
        if player then
            for _, itemKey in ipairs(player.itemOrder) do
                local queued = player.items[itemKey]
                if queued and tonumber(queued.itemId) == wantedId then
                    local qty = FloorQty(queued.quantity)
                    if qty > 0 then
                        if queued.linkKey then
                            exact[queued.linkKey] = (exact[queued.linkKey] or 0) + qty
                        else
                            bare = bare + qty
                        end
                    end
                end
            end
        end
    end
    return exact, bare
end

local function QueuedInventoryFeasible(item, memberCount)
    local wantedId = tonumber(item and item.itemId)
    if not wantedId then
        return false
    end
    local supply, totalSupply = SupplyCountsForItemId(wantedId)
    local exact, bare = QueuedDemandForItemId(wantedId)
    local additional = FloorQty(item.quantity) * FloorQty(memberCount)
    if item.linkKey then
        exact[item.linkKey] = (exact[item.linkKey] or 0) + additional
    else
        bare = bare + additional
    end
    local exactTotal = 0
    for linkKey, demand in pairs(exact) do
        if (supply[linkKey] or 0) < demand then
            return false
        end
        exactTotal = exactTotal + demand
    end
    return bare <= (totalSupply - exactTotal)
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

local function SettlePlayerItems(playerId, offers)
    local entry, key = FindPlayer(playerId)
    if not entry or not key or type(offers) ~= "table" then
        return false
    end
    local linkRemaining = {}
    local itemRemaining = {}
    for _, offer in ipairs(offers) do
        local id = tonumber(offer and offer.itemId)
        local qty = FloorQty(offer and offer.quantity)
        if id and qty > 0 then
            itemRemaining[id] = (itemRemaining[id] or 0) + qty
            if offer.linkKey then
                linkRemaining[offer.linkKey] = (linkRemaining[offer.linkKey] or 0) + qty
            end
        end
    end
    local changed = false
    local removeKeys = {}
    for _, itemKey in ipairs(entry.itemOrder) do
        local item = entry.items[itemKey]
        if item and item.linkKey then
            local available = linkRemaining[item.linkKey] or 0
            local settled = math.min(available, FloorQty(item.quantity))
            if settled > 0 then
                item.quantity = FloorQty(item.quantity) - settled
                linkRemaining[item.linkKey] = available - settled
                local id = tonumber(item.itemId)
                if id then
                    itemRemaining[id] = (itemRemaining[id] or 0) - settled
                end
                changed = true
                if FloorQty(item.quantity) <= 0 then
                    removeKeys[#removeKeys + 1] = itemKey
                end
            end
        end
    end
    for _, itemKey in ipairs(entry.itemOrder) do
        local item = entry.items[itemKey]
        if item and not item.linkKey then
            local id = tonumber(item.itemId)
            local available = id and itemRemaining[id] or 0
            local settled = math.min(available, FloorQty(item.quantity))
            if settled > 0 then
                item.quantity = FloorQty(item.quantity) - settled
                itemRemaining[id] = available - settled
                changed = true
                if FloorQty(item.quantity) <= 0 then
                    removeKeys[#removeKeys + 1] = itemKey
                end
            end
        end
    end
    if not changed then
        return false
    end
    for _, itemKey in ipairs(removeKeys) do
        entry.items[itemKey] = nil
        for index = #entry.itemOrder, 1, -1 do
            if entry.itemOrder[index] == itemKey then
                table.remove(entry.itemOrder, index)
            end
        end
    end
    if #entry.itemOrder == 0 then
        state.players[key] = nil
        for index = #state.order, 1, -1 do
            if state.order[index] == key then
                table.remove(state.order, index)
            end
        end
        Debug("Info", "Completed trade removed %s from queue", tostring(entry.name or key))
        RefreshQueueUI()
        return true
    end
    Debug("Info", "Completed trade settled offered items for %s; %d item entries remain", tostring(entry.name or key), #entry.itemOrder)
    RefreshQueueUI()
    return false
end

function TA:ClearQueue()
    state.players = {}
    state.order = {}
    state.activeTrade = nil
    state.pendingTrade = nil
    state.lastAutoFill = nil
    RefreshQueueUI()
end

function TA:ResetRuntime()
    state.players = {}
    state.order = {}
    state.activeTrade = nil
    state.pendingTrade = nil
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

    if not QueuedInventoryFeasible(item, #members) then
        SF:PrintError(Loc("TRADE_ASSISTANT_ERR_INSUFFICIENT", "SF Trade failed."))
        Debug("Info", "Rejected /sf trade: infeasible item=%s quantity=%d members=%d", tostring(item.itemId), FloorQty(item.quantity), #members)
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

local function CaptureCurrentOffers()
    local offers = {}
    if not GetTradePlayerItemInfo then
        return offers
    end
    for slot = 1, TA.TRADE_SLOTS do
        local itemName, _, count = GetTradePlayerItemInfo(slot)
        if itemName then
            local itemId = nil
            local linkKey = nil
            if GetTradePlayerItemLink then
                local link = GetTradePlayerItemLink(slot)
                if type(link) == "string" then
                    itemId = tonumber(link:match("item:(%d+)"))
                    linkKey = NormalizeLinkKey(link)
                end
            end
            local quantity = FloorQty(count)
            if quantity < 1 then
                quantity = 1
            end
            offers[#offers + 1] = {
                itemId = itemId,
                linkKey = linkKey,
                quantity = quantity,
                slot = slot,
                name = itemName,
            }
        end
    end
    return offers
end

local function OfferMatchesQueuedItem(offer, item)
    if not offer or not item then
        return false
    end
    local offerId = tonumber(offer.itemId)
    local itemId = tonumber(item.itemId)
    if offerId and itemId and offerId ~= itemId then
        return false
    end
    if item.linkKey then
        if offer.linkKey then
            return offer.linkKey == item.linkKey
        end
        return offer.name ~= nil and offer.name == ItemDisplayName(item)
    end
    if offerId and itemId then
        return true
    end
    return offer.name ~= nil and offer.name == ItemDisplayName(item)
end

local function ExistingOfferQuantity(existingOffers, item)
    local total = 0
    for _, offer in ipairs(existingOffers or {}) do
        if OfferMatchesQueuedItem(offer, item) then
            total = total + FloorQty(offer.quantity)
        end
    end
    return total
end

local function PlanMoves(entry, freeSlots, existingOffers)
    local moves = {}
    local slotsLeft = FloorQty(freeSlots)
    local planned = {}
    for _, itemKey in ipairs(entry.itemOrder) do
        local item = entry.items[itemKey]
        if item and slotsLeft > 0 then
            local remaining = math.max(0, FloorQty(item.quantity) - ExistingOfferQuantity(existingOffers, item))
            if remaining > 0 then
                local stacks = CollectStacksForItem(item)
                for _, stack in ipairs(stacks) do
                    if remaining < 1 or slotsLeft < 1 then
                        break
                    end
                    local stackKey = tostring(stack.bag) .. ":" .. tostring(stack.slot)
                    local availableCount = stack.count - (planned[stackKey] or 0)
                    if not stack.locked and availableCount > 0 then
                        local take = math.min(availableCount, remaining)
                        moves[#moves + 1] = {
                            item = item,
                            bag = stack.bag,
                            slot = stack.slot,
                            quantity = take,
                        }
                        planned[stackKey] = (planned[stackKey] or 0) + take
                        remaining = remaining - take
                        slotsLeft = slotsLeft - 1
                    end
                end
                if remaining > 0 then
                    Debug("Info", "Trade prefill deferred for %s: %d units did not fit", tostring(itemKey), remaining)
                end
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
            return true, take, tradeSlot
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

    local existingOffers = CaptureCurrentOffers()
    trade.offeredOffers = {}
    local moves = PlanMoves(entry, freeSlots, existingOffers)
    local placed = 0
    local attempted = 0
    for _, move in ipairs(moves) do
        attempted = attempted + 1
        local ok, result, tradeSlot = PlaceOfferFromStack(move.bag, move.slot, move.quantity)
        if ok then
            local placedQty = FloorQty(result)
            placed = placed + placedQty
            local itemId = move.item and tonumber(move.item.itemId)
            if itemId then
                trade.offeredOffers[#trade.offeredOffers + 1] = {
                    itemId = itemId,
                    linkKey = move.item and move.item.linkKey,
                    quantity = placedQty,
                    slot = tradeSlot,
                    name = ItemDisplayName(move.item),
                }
            end
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
    return last ~= nil and last.key == key
end

local function OnTradeShow()
    state.tradeLifecycle = state.tradeLifecycle + 1
    local key, name = GetTradeTargetKey()
    local autoFill = key ~= nil and ShouldAutoFill(key)
    state.lastAutoFill = nil
    state.activeTrade = {
        key = key,
        name = name,
        lifecycle = state.tradeLifecycle,
        playerAccepted = false,
        targetAccepted = false,
        autoFill = autoFill,
        cancelled = false,
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

local function CaptureAcceptedOffer()
    if not GetTradePlayerItemInfo then
        return nil
    end
    local offers = {}
    local unknown = {}
    local complete = true
    for slot = 1, TA.TRADE_SLOTS do
        local name, _, count = GetTradePlayerItemInfo(slot)
        if name then
            local itemId = nil
            local linkKey = nil
            if GetTradePlayerItemLink then
                local link = GetTradePlayerItemLink(slot)
                if type(link) == "string" then
                    itemId = tonumber(link:match("item:(%d+)"))
                    linkKey = NormalizeLinkKey(link)
                end
            end
            local qty = FloorQty(count)
            if qty < 1 then
                qty = 1
            end
            if itemId and linkKey then
                offers[#offers + 1] = {
                    itemId = itemId,
                    linkKey = linkKey,
                    quantity = qty,
                    slot = slot,
                }
            else
                complete = false
                unknown[#unknown + 1] = {
                    slot = slot,
                    quantity = qty,
                    name = name,
                }
            end
        end
    end
    return offers, unknown, complete
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
    if trade.autoFill and trade.playerAccepted then
        local offers, unknown, complete = CaptureAcceptedOffer()
        trade.acceptedOffers = offers
        trade.acceptedUnknown = unknown
        trade.acceptedComplete = complete
    end
end

local function TradeOfferNameCompatible(offerName, tradeName)
    if type(offerName) ~= "string" or offerName == "" or type(tradeName) ~= "string" or tradeName == "" then
        return true
    end
    return offerName == tradeName
end

local function TradeOfferNameEqual(offerName, tradeName)
    return type(offerName) == "string" and offerName ~= ""
        and type(tradeName) == "string" and tradeName ~= ""
        and offerName == tradeName
end

local function TradeOfferSameNameAndQuantity(a, b)
    return TradeOfferNameEqual(a and a.name, b and b.name)
        and FloorQty(a and a.quantity) == FloorQty(b and b.quantity)
end

local function TradeOfferSameIdentity(a, b)
    if not a or not b then
        return false
    end
    return tonumber(a.itemId) == tonumber(b.itemId)
        and (a.linkKey == b.linkKey)
end

local function TradeOffersInterchangeable(first, candidates)
    for index = 2, #candidates do
        if not TradeOfferSameIdentity(first, candidates[index]) then
            return false
        end
    end
    return true
end

local function ItemIdentityString(item)
    return tostring(tonumber(item and item.itemId) or "?") .. "|" .. tostring(item and item.linkKey)
end

local function IdentitySetsEqual(a, b)
    local countA = 0
    for _ in pairs(a or {}) do
        countA = countA + 1
    end
    local countB = 0
    for _ in pairs(b or {}) do
        countB = countB + 1
    end
    if countA ~= countB then
        return false
    end
    for identity in pairs(a or {}) do
        if not (b and b[identity]) then
            return false
        end
    end
    return true
end

local function MergeAcceptedOffers(accepted, unknown, offered, queuedItems)
    local merged = {}
    for _, offer in ipairs(accepted or {}) do
        merged[#merged + 1] = offer
    end
    if type(unknown) ~= "table" or #unknown == 0 then
        return merged
    end
    local offeredBySlot = {}
    local unusedOffers = {}
    for _, offer in ipairs(offered or {}) do
        local slot = tonumber(offer and offer.slot)
        if slot then
            offeredBySlot[slot] = offer
        end
        unusedOffers[#unusedOffers + 1] = offer
    end
    local ambiguousOffers = {}
    for _, offer in ipairs(offered or {}) do
        for _, other in ipairs(offered or {}) do
            if offer ~= other and TradeOfferSameNameAndQuantity(offer, other)
                and not TradeOfferSameIdentity(offer, other) then
                ambiguousOffers[offer] = true
                break
            end
        end
    end
    local ambiguousNames = {}
    local identitiesByName = {}
    local offeredIdentitiesByName = {}
    local queuedIdentitiesByName = {}
    local function AddIdentity(map, name, identity)
        if type(name) ~= "string" or name == "" then
            return
        end
        local identities = map[name]
        if not identities then
            identities = {}
            map[name] = identities
        end
        identities[identity] = true
    end
    for _, offer in ipairs(offered or {}) do
        local offerName = offer and offer.name
        local identity = ItemIdentityString(offer)
        AddIdentity(identitiesByName, offerName, identity)
        AddIdentity(offeredIdentitiesByName, offerName, identity)
    end
    for _, item in ipairs(queuedItems or {}) do
        local itemName = ItemDisplayName(item)
        local identity = ItemIdentityString(item)
        AddIdentity(identitiesByName, itemName, identity)
        AddIdentity(queuedIdentitiesByName, itemName, identity)
    end
    for offerName, identities in pairs(identitiesByName) do
        local identityCount = 0
        for _ in pairs(identities) do
            identityCount = identityCount + 1
        end
        if identityCount > 1 then
            ambiguousNames[offerName] = true
        end
    end
    local safeAmbiguousNames = {}
    local safeAmbiguousSlotOffers = {}
    for offerName in pairs(ambiguousNames) do
        local offeredKeys = {}
        local unknownKeys = {}
        for _, offer in ipairs(offered or {}) do
            if offer and offer.name == offerName then
                local key = tostring(tonumber(offer.slot) or "?") .. ":" .. tostring(FloorQty(offer.quantity))
                offeredKeys[key] = (offeredKeys[key] or 0) + 1
            end
        end
        for _, entry in ipairs(unknown or {}) do
            if entry and entry.name == offerName then
                local key = tostring(tonumber(entry.slot) or "?") .. ":" .. tostring(FloorQty(entry.quantity))
                unknownKeys[key] = (unknownKeys[key] or 0) + 1
            end
        end
        local unchanged = true
        for key, count in pairs(offeredKeys) do
            if unknownKeys[key] ~= count then
                unchanged = false
                break
            end
        end
        if unchanged then
            for key, count in pairs(unknownKeys) do
                if offeredKeys[key] ~= count then
                    unchanged = false
                    break
                end
            end
        end
        if unchanged and IdentitySetsEqual(offeredIdentitiesByName[offerName], queuedIdentitiesByName[offerName]) then
            safeAmbiguousNames[offerName] = true
            safeAmbiguousSlotOffers[offerName] = {}
            for _, offer in ipairs(offered or {}) do
                local slot = tonumber(offer and offer.slot)
                if offer and offer.name == offerName and slot then
                    safeAmbiguousSlotOffers[offerName][slot] = offer
                end
            end
        end
    end
    local usedOffers = {}
    for _, entry in ipairs(unknown) do
        local slot = tonumber(entry and entry.slot)
        local quantity = FloorQty(entry and entry.quantity)
        local tradeName = entry and entry.name
        local match = nil
        if ambiguousNames[tradeName] then
            if safeAmbiguousNames[tradeName] then
                local slotOffer = safeAmbiguousSlotOffers[tradeName] and safeAmbiguousSlotOffers[tradeName][slot] or nil
                if slotOffer and not usedOffers[slotOffer] and FloorQty(slotOffer.quantity) == quantity then
                    match = slotOffer
                end
            end
        else
            local slotOffer = slot and offeredBySlot[slot] or nil
            if slotOffer and not usedOffers[slotOffer] and not ambiguousOffers[slotOffer]
                and TradeOfferNameCompatible(slotOffer.name, tradeName)
                and FloorQty(slotOffer.quantity) == quantity then
                match = slotOffer
            end
            if not match then
                local candidates = {}
                for _, offer in ipairs(unusedOffers) do
                    if not usedOffers[offer] and TradeOfferNameEqual(offer.name, tradeName) and FloorQty(offer.quantity) == quantity then
                        candidates[#candidates + 1] = offer
                    end
                end
                if #candidates > 0 and TradeOffersInterchangeable(candidates[1], candidates) then
                    match = candidates[1]
                end
            end
            if not match then
                local nameCandidates = {}
                for _, offer in ipairs(unusedOffers) do
                    if not usedOffers[offer] and TradeOfferNameEqual(offer.name, tradeName) then
                        nameCandidates[#nameCandidates + 1] = offer
                    end
                end
                if #nameCandidates > 0 and TradeOffersInterchangeable(nameCandidates[1], nameCandidates) then
                    match = nameCandidates[1]
                end
            end
        end
        if match and quantity > 0 then
            usedOffers[match] = true
            merged[#merged + 1] = {
                itemId = match.itemId,
                linkKey = match.linkKey,
                quantity = quantity,
                slot = slot or tonumber(match.slot),
            }
        else
            Debug("Info", "Trade settlement skipped unidentified offer in slot %s", tostring(slot))
        end
    end
    return merged
end

local function SettleCompletedTrade(trade)
    if trade.autoFill then
        local settlement = trade.acceptedOffers
        local queuedItems = {}
        local entry = FindPlayer(trade.key)
        if entry then
            for _, itemKey in ipairs(entry.itemOrder) do
                local item = entry.items[itemKey]
                if item then
                    queuedItems[#queuedItems + 1] = item
                end
            end
        end
        if settlement ~= nil and trade.acceptedComplete == false then
            settlement = MergeAcceptedOffers(settlement, trade.acceptedUnknown, trade.offeredOffers, queuedItems)
        elseif settlement == nil then
            settlement = trade.offeredOffers
        end
        if settlement ~= nil then
            SettlePlayerItems(trade.key, settlement)
        else
            TA:RemovePlayer(trade.key)
        end
    else
        TA:RemovePlayer(trade.key)
    end
end

local function FinalizePendingTrade(trade)
    if state.pendingTrade ~= trade then
        return
    end
    state.pendingTrade = nil
    if not trade or not trade.key or trade.cancelled then
        Debug("Info", "Trade closed without completion for %s", tostring(trade and (trade.name or trade.key) or "unknown"))
        return
    end
    SettleCompletedTrade(trade)
end

local function ScheduleTradeSettlement(trade)
    state.pendingTrade = trade
    if C_Timer and C_Timer.After then
        C_Timer.After(TA.SETTLEMENT_DELAY_SECONDS, function()
            FinalizePendingTrade(trade)
        end)
    else
        FinalizePendingTrade(trade)
    end
end

local function OnTradeRequestCancel()
    local hadAutoFillIntent = state.lastAutoFill ~= nil
    state.lastAutoFill = nil
    if hadAutoFillIntent then
        Debug("Info", "Trade request cancelled before trade window")
        return
    end
    local trade = state.activeTrade or state.pendingTrade
    if not trade then
        return
    end
    trade.cancelled = true
    Debug("Info", "Trade cancelled for %s", tostring(trade.name or trade.key))
end

local function OnTradeClosed()
    local trade = state.activeTrade
    state.activeTrade = nil
    if not trade or not trade.key then
        return
    end
    if trade.playerAccepted and not trade.cancelled then
        ScheduleTradeSettlement(trade)
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
    frame:RegisterEvent("TRADE_REQUEST_CANCEL")
    frame:RegisterEvent("TRADE_CLOSED")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "TRADE_SHOW" then
            OnTradeShow()
        elseif event == "TRADE_ACCEPT_UPDATE" then
            OnTradeAcceptUpdate(...)
        elseif event == "TRADE_REQUEST_CANCEL" then
            OnTradeRequestCancel()
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
