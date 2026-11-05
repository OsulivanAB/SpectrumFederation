-- Runtime-only Quick Withdraw → trade handoff (#457 D3).
-- Never SavedVariables / Gossip. Reload/logout clears. Each batch expires
-- independently one hour after confirmation.
local addonName, SF = ...

SF.ConsumablesTradeHandoff = SF.ConsumablesTradeHandoff or {}
local H = SF.ConsumablesTradeHandoff
local W = SF.ConsumablesWithdrawWorkflow

H.BATCH_TTL_SECONDS = 60 * 60
H.MAX_BATCHES = 32
H.MAX_PENDING_UNITS = 100000
H.TRADE_SLOTS = 6 -- normal transferable slots; enchanting slot unused

local state = {
    batches = {}, -- oldest first
    ambiguous = {}, -- {[itemId]=qty} paused from auto re-offer
    status = nil, -- player-visible status string key/detail
    statusDetail = nil,
    tradeLifecycleId = 0,
    prefillAttemptedFor = nil, -- lifecycle id
    prefillActive = false,
    listenersAttached = false,
    frame = nil,
    statusFrame = nil,
}

local function Loc(key, default)
    if SF.LocaleText then
        return SF.LocaleText(key, default)
    end
    return default or key
end

local function Debug(level, message, ...)
    if SF.Debug and SF.Debug[level] then
        SF.Debug[level](SF.Debug, "RAID_SUPPLIES", message, ...)
    end
end

local function Now()
    if GetServerTime then
        local t = GetServerTime()
        if type(t) == "number" and t == t and t >= 0 then
            return math.floor(t)
        end
    end
    return math.floor(time() or 0)
end

local function FloorQty(n)
    n = tonumber(n) or 0
    if n ~= n or n < 0 then return 0 end
    return math.floor(n)
end

local function CountPendingUnits(batches)
    local n = 0
    if type(batches) ~= "table" then return 0 end
    for i = 1, #batches do
        local amounts = batches[i] and batches[i].amounts
        if type(amounts) == "table" then
            for _, qty in pairs(amounts) do
                n = n + FloorQty(qty)
            end
        end
    end
    return n
end

function H.Reset()
    state.batches = {}
    state.ambiguous = {}
    state.status = nil
    state.statusDetail = nil
    state.tradeLifecycleId = 0
    state.prefillAttemptedFor = nil
    state.prefillActive = false
    H.RefreshStatusUI()
end

function H.GetState()
    return state
end

function H.PendingSnapshot()
    local now = Now()
    local alive = {}
    for i = 1, #state.batches do
        local b = state.batches[i]
        if type(b) == "table" and (not b.expiresAt or now < b.expiresAt) then
            alive[#alive + 1] = b
        end
    end
    state.batches = alive
    local totals = {}
    for i = 1, #alive do
        local amounts = alive[i].amounts
        if type(amounts) == "table" then
            for k, v in pairs(amounts) do
                local key = tostring(k)
                totals[key] = (totals[key] or 0) + FloorQty(v)
            end
        end
    end
    return totals, alive
end

--- Capacity check before starting a withdrawal that will enqueue `units`.
function H.CanAcceptUnits(units)
    units = FloorQty(units)
    if units < 1 then return true end
    if #state.batches >= (H.MAX_BATCHES or 32) then
        return false, "handoff_batches_full"
    end
    local pending = CountPendingUnits(state.batches)
    if pending + units > (H.MAX_PENDING_UNITS or 100000) then
        return false, "handoff_units_full"
    end
    return true
end

function H.EnqueueConfirmed(amounts, meta)
    if type(amounts) ~= "table" then
        return nil, "invalid_amounts"
    end
    local cleaned = {}
    local units = 0
    for k, v in pairs(amounts) do
        local qty = FloorQty(v)
        if qty > 0 then
            cleaned[tostring(k)] = qty
            units = units + qty
        end
    end
    if units < 1 then
        return nil, "empty"
    end
    local ok, err = H.CanAcceptUnits(units)
    if not ok then
        return nil, err
    end
    local completedAt = Now()
    local batch = {
        id = (meta and meta.operationId) or ("tw:" .. tostring(completedAt) .. ":" .. tostring(#state.batches + 1)),
        completedAt = completedAt,
        expiresAt = completedAt + (H.BATCH_TTL_SECONDS or 3600),
        amounts = cleaned,
    }
    local nextBatches, appendErr = W.AppendTradeBatch(state.batches, batch, H.MAX_BATCHES)
    if not nextBatches then
        return nil, appendErr or "full"
    end
    state.batches = nextBatches
    state.status = "pending"
    state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_PENDING",
        "Pending trade handoff ready. Open a trade to offer withdrawn reagents.")
    H.EnsureListeners()
    H.RefreshStatusUI()
    Debug("Info", "trade handoff enqueued units=%d batches=%d", units, #state.batches)
    return batch
end

function H.ClearPending()
    state.batches = {}
    state.ambiguous = {}
    state.status = "cleared"
    state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_CLEARED",
        "Pending trade handoff cleared. Withdrawal history was not changed.")
    H.RefreshStatusUI()
end

local function AggregatePending()
    local totals = H.PendingSnapshot()
    -- Exclude ambiguous quantities from automatic re-offer.
    if type(state.ambiguous) == "table" then
        for k, v in pairs(state.ambiguous) do
            local key = tostring(k)
            local left = FloorQty(totals[key]) - FloorQty(v)
            if left > 0 then
                totals[key] = left
            else
                totals[key] = nil
            end
        end
    end
    return totals
end

local function CursorBusy()
    if not GetCursorInfo then return false end
    return GetCursorInfo() ~= nil
end

local function PlayerBagCount(itemId)
    itemId = tonumber(itemId)
    if not itemId or not GetItemCount then return 0 end
    return FloorQty(GetItemCount(itemId, false, false, false))
end

local function TradeSlotItemId(slot)
    if not GetTradePlayerItemInfo then return nil, 0 end
    local name, texture, count = GetTradePlayerItemInfo(slot)
    if not name then return nil, 0 end
    -- Prefer link parse when available.
    local link = GetTradePlayerItemLink and GetTradePlayerItemLink(slot)
    local id = nil
    if type(link) == "string" then
        id = tonumber(link:match("item:(%d+)"))
    end
    return id, FloorQty(count)
end

local function AlreadyOfferedCounts()
    local offered = {}
    for slot = 1, (H.TRADE_SLOTS or 6) do
        local itemId, count = TradeSlotItemId(slot)
        if itemId and count > 0 then
            local key = tostring(itemId)
            offered[key] = (offered[key] or 0) + count
        end
    end
    return offered
end

local function CountFreeTradeSlots()
    local free = 0
    for slot = 1, (H.TRADE_SLOTS or 6) do
        local name = GetTradePlayerItemInfo and select(1, GetTradePlayerItemInfo(slot))
        if not name then
            free = free + 1
        end
    end
    return free
end

local function FindBagItemLocation(itemId, need)
    -- Prefer containers that can supply `need` without locked items.
    if not C_Container or not C_Container.GetContainerNumSlots then
        return nil
    end
    itemId = tonumber(itemId)
    need = FloorQty(need)
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and tonumber(info.itemID) == itemId and not info.isLocked then
                local count = FloorQty(info.stackCount)
                if count > 0 then
                    return bag, slot, count
                end
            end
        end
    end
    return nil
end

local function PlaceOneOffer(itemId, qty)
    if CursorBusy() then
        return false, "cursor_busy"
    end
    local bag, slot, have = FindBagItemLocation(itemId, qty)
    if not bag then
        return false, "not_carried"
    end
    local take = math.min(FloorQty(qty), FloorQty(have))
    if take < 1 then
        return false, "not_carried"
    end
    if take < have and C_Container.SplitContainerItem then
        C_Container.SplitContainerItem(bag, slot, take)
    elseif C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bag, slot)
    else
        return false, "unsupported"
    end
    -- Click first free trade slot.
    if not ClickTradeButton then
        ClearCursor()
        return false, "unsupported"
    end
    for tradeSlot = 1, (H.TRADE_SLOTS or 6) do
        local name = GetTradePlayerItemInfo and select(1, GetTradePlayerItemInfo(tradeSlot))
        if not name then
            ClickTradeButton(tradeSlot)
            if CursorBusy() then
                ClearCursor()
                return false, "place_failed"
            end
            return true, take
        end
    end
    ClearCursor()
    return false, "no_slot"
end

function H.TryPrefillTrade()
    local totals = AggregatePending()
    local any = false
    for _ in pairs(totals) do any = true break end
    if not any then
        return
    end
    if state.prefillAttemptedFor == state.tradeLifecycleId then
        return -- one bounded attempt per trade lifecycle
    end
    if CursorBusy() then
        state.status = "blocked"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_CURSOR",
            "Clear the cursor before automatic trade offering can continue.")
        H.RefreshStatusUI()
        return
    end
    -- Deposit/withdraw mutual exclusion: if a bank movement owns the cursor path.
    local Runtime = SF.ConsumablesRuntime
    if Runtime and (Runtime._depositWork or Runtime._withdrawWork) then
        state.status = "blocked"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_BUSY",
            "Finish the bank movement before trade offering can continue.")
        H.RefreshStatusUI()
        return
    end
    state.prefillAttemptedFor = state.tradeLifecycleId
    state.prefillActive = true
    local offered = AlreadyOfferedCounts()
    local carried = {}
    for itemKey, qty in pairs(totals) do
        carried[itemKey] = PlayerBagCount(tonumber(itemKey))
    end
    local free = CountFreeTradeSlots()
    local toOffer, deferred = W.PlanTradePrefill(totals, offered, carried, free, H.TRADE_SLOTS)
    local placed = 0
    local keys = {}
    for k in pairs(toOffer) do keys[#keys + 1] = k end
    table.sort(keys)
    for i = 1, #keys do
        local key = keys[i]
        local ok, result = PlaceOneOffer(tonumber(key), toOffer[key])
        if ok then
            placed = placed + (tonumber(result) or 0)
        else
            deferred[key] = (deferred[key] or 0) + FloorQty(toOffer[key])
            if result == "cursor_busy" then
                break
            end
        end
    end
    state.prefillActive = false
    if placed > 0 then
        state.status = "offered"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_OFFERED",
            "Offered pending reagents in the trade window. Accept/cancel remains a player action.")
    elseif next(deferred) then
        state.status = "partial"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_PARTIAL",
            "Some pending reagents could not be offered yet (slots, locks, or inventory).")
    else
        state.status = "blocked"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_BLOCKED",
            "Pending reagents are not currently offerable.")
    end
    H.RefreshStatusUI()
end

--- Verify successful trade delivery and consume oldest matching batches.
-- Acceptance flags / TRADE_CLOSED alone are insufficient — require observed
-- outgoing quantities that left the player's bags.
function H.OnTradeCompleted(deliveredAmounts, ambiguous)
    if ambiguous then
        -- Pause automatic re-offer of the affected portion.
        deliveredAmounts = type(deliveredAmounts) == "table" and deliveredAmounts or {}
        for k, v in pairs(deliveredAmounts) do
            local key = tostring(k)
            state.ambiguous[key] = (state.ambiguous[key] or 0) + FloorQty(v)
        end
        state.status = "unresolved"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_UNRESOLVED",
            "Trade completion is unresolved. Automatic re-offering is paused for the affected items.")
        H.RefreshStatusUI()
        return
    end
    if type(deliveredAmounts) ~= "table" then
        return
    end
    local nextBatches = W.ConsumeTradeBatches(state.batches, deliveredAmounts, Now())
    state.batches = nextBatches
    local remaining = AggregatePending()
    local any = false
    for _ in pairs(remaining) do any = true break end
    if any then
        state.status = "pending"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_REMAINING",
            "Some pending reagents remain for a later trade.")
    else
        state.status = "complete"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_COMPLETE",
            "Pending trade handoff complete.")
    end
    H.RefreshStatusUI()
end

function H.OnTradeCancelled()
    -- Retain unexpired quantities; do not consume.
    state.status = "pending"
    state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_CANCELLED",
        "Trade cancelled. Pending reagents remain available until they expire.")
    H.RefreshStatusUI()
end

local function EnsureStatusFrame()
    if state.statusFrame then return state.statusFrame end
    if not CreateFrame then return nil end
    local f = CreateFrame("Frame", "SpectrumFederationTradeHandoffStatus", UIParent, "BackdropTemplate")
    f:SetSize(280, 72)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:Hide()
    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", 10, -10)
    text:SetPoint("TOPRIGHT", -10, -10)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    f.text = text
    local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clear:SetSize(80, 22)
    clear:SetPoint("BOTTOMLEFT", 10, 8)
    clear:SetText(Loc("GUILD_SUPPLIES_TRADE_CLEAR", "Clear"))
    clear:SetScript("OnClick", function()
        H.ClearPending()
    end)
    f.clear = clear
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function()
        f:Hide()
    end)
    state.statusFrame = f
    return f
end

function H.RefreshStatusUI()
    local totals = select(1, H.PendingSnapshot())
    local any = false
    for _ in pairs(totals) do any = true break end
    local ambiguousAny = false
    if type(state.ambiguous) == "table" then
        for _ in pairs(state.ambiguous) do ambiguousAny = true break end
    end
    if not any and not ambiguousAny and state.status ~= "unresolved" then
        if state.statusFrame then state.statusFrame:Hide() end
        return
    end
    local f = EnsureStatusFrame()
    if not f then return end
    local detail = state.statusDetail
        or Loc("GUILD_SUPPLIES_TRADE_PENDING",
            "Pending trade handoff ready. Open a trade to offer withdrawn reagents.")
    f.text:SetText(detail)
    f:Show()
end

function H.EnsureListeners()
    if state.listenersAttached then return end
    if not CreateFrame then return end
    local frame = CreateFrame("Frame", "SpectrumFederationTradeHandoff")
    state.frame = frame
    frame:RegisterEvent("TRADE_SHOW")
    frame:RegisterEvent("TRADE_CLOSED")
    frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    local acceptSnapshot = { player = false, target = false, bagBefore = nil }

    local function SnapshotPendingBags()
        local totals = AggregatePending()
        local snap = {}
        for k in pairs(totals) do
            snap[k] = PlayerBagCount(tonumber(k))
        end
        return snap
    end

    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_LOGOUT" or event == "PLAYER_ENTERING_WORLD" then
            -- Reload/logout clears runtime handoff.
            if event == "PLAYER_LOGOUT" then
                H.Reset()
            end
            return
        end
        if event == "TRADE_SHOW" then
            state.tradeLifecycleId = state.tradeLifecycleId + 1
            state.prefillAttemptedFor = nil
            acceptSnapshot.player = false
            acceptSnapshot.target = false
            acceptSnapshot.bagBefore = SnapshotPendingBags()
            -- Expiry while trade is open stops further automatic additions.
            local totals = AggregatePending()
            local any = false
            for _ in pairs(totals) do any = true break end
            if any then
                H.TryPrefillTrade()
            end
            return
        end
        if event == "TRADE_ACCEPT_UPDATE" then
            local player, target = GetTradePlayerSelected and GetTradePlayerSelected() or nil, nil
            -- Retail: GetTradePlayerSelected may not exist; use events' args when present.
            local a1, a2 = ...
            if a1 ~= nil then acceptSnapshot.player = a1 and true or false end
            if a2 ~= nil then acceptSnapshot.target = a2 and true or false end
            return
        end
        if event == "TRADE_CLOSED" then
            -- TRADE_CLOSED alone is not success. Compare bag counts for pending items.
            local before = acceptSnapshot.bagBefore or {}
            local delivered = {}
            local anyDelivered = false
            local ambiguous = false
            for k, beforeCount in pairs(before) do
                local afterCount = PlayerBagCount(tonumber(k))
                local lost = FloorQty(beforeCount) - FloorQty(afterCount)
                if lost > 0 then
                    delivered[k] = lost
                    anyDelivered = true
                end
            end
            -- If both accepted and bags decreased, treat as success.
            -- If bags decreased without clear accept state, still consume (items left).
            -- If accept was true for both but bags did not decrease, ambiguous.
            local bothAccepted = acceptSnapshot.player and acceptSnapshot.target
            if bothAccepted and not anyDelivered then
                ambiguous = true
                -- Pause the amounts that were offered.
                delivered = AlreadyOfferedCounts()
            elseif not anyDelivered then
                H.OnTradeCancelled()
                return
            end
            H.OnTradeCompleted(delivered, ambiguous)
            acceptSnapshot.bagBefore = nil
            return
        end
    end)
    state.listenersAttached = true
end

-- Test hooks
H._state = state
H._AggregatePending = AggregatePending
