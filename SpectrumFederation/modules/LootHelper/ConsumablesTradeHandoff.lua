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
    batches = {}, -- oldest first; optional per-batch ambiguous map
    status = nil, -- player-visible status string key/detail
    statusDetail = nil,
    context = nil, -- { playerGuid, guildKey }
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

local function CaptureContext()
    local guid = UnitGUID and UnitGUID("player")
    local guildKey = nil
    local WR = SF.ConsumablesWithdrawRuntime
    if WR and WR.CurrentContext then
        local ctx = WR.CurrentContext()
        if type(ctx) == "table" then
            guildKey = ctx.guildKey
        end
    end
    if not guildKey then
        local GS = SF.GuildSupplies
        local record = GS and GS.GetCurrentRecord and select(1, GS:GetCurrentRecord())
        if type(record) == "table" then
            guildKey = record._guildKey
        end
    end
    return {
        playerGuid = guid,
        guildKey = guildKey,
    }
end

local function ContextMatches()
    if type(state.context) ~= "table" then
        return true
    end
    local cur = CaptureContext()
    -- Loss of a previously established identity is invalid (nil must not match).
    local boundGuid = state.context.playerGuid
    if boundGuid ~= nil and boundGuid ~= "" then
        if cur.playerGuid == nil or cur.playerGuid == "" then
            return false
        end
        if tostring(boundGuid) ~= tostring(cur.playerGuid) then
            return false
        end
    end
    local boundGuild = state.context.guildKey
    if boundGuild ~= nil and boundGuild ~= "" then
        if cur.guildKey == nil or cur.guildKey == "" then
            return false
        end
        if tostring(boundGuild) ~= tostring(cur.guildKey) then
            return false
        end
    end
    return true
end

local function EnsureContextOrClear()
    if not ContextMatches() then
        H.Reset()
        return false
    end
    return true
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

local function AnyBatchAmbiguous(batches)
    if type(batches) ~= "table" then return false end
    for i = 1, #batches do
        local amb = batches[i] and batches[i].ambiguous
        if type(amb) == "table" then
            for _, qty in pairs(amb) do
                if FloorQty(qty) > 0 then
                    return true
                end
            end
        end
    end
    return false
end

function H.Reset()
    state.batches = {}
    state.status = nil
    state.statusDetail = nil
    state.context = nil
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
    H.PendingSnapshot()
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
    if not EnsureContextOrClear() then
        return nil, "context_mismatch"
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
    state.context = CaptureContext()
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
    state.status = "cleared"
    state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_CLEARED",
        "Pending trade handoff cleared. Withdrawal history was not changed.")
    H.RefreshStatusUI()
end

local function AggregatePending()
    local _, alive = H.PendingSnapshot()
    local totals = {}
    for i = 1, #alive do
        local b = alive[i]
        local amounts = type(b.amounts) == "table" and b.amounts or {}
        local amb = type(b.ambiguous) == "table" and b.ambiguous or {}
        for k, v in pairs(amounts) do
            local key = tostring(k)
            local left = FloorQty(v) - FloorQty(amb[key] or amb[tonumber(key)])
            if left > 0 then
                totals[key] = (totals[key] or 0) + left
            end
        end
    end
    return totals
end

local function CursorBusy()
    if not GetCursorInfo then return false end
    return GetCursorInfo() ~= nil
end

local function CarriedBagIds()
    local R = SF.ConsumablesRouting
    local bags = {}
    for bag = 0, 5 do
        if not R or not R.IsCarriedBag or R.IsCarriedBag(bag) then
            bags[#bags + 1] = bag
        end
    end
    return bags
end

local function PlayerBagCount(itemId)
    itemId = tonumber(itemId)
    if not itemId or not GetItemCount then return 0 end
    return FloorQty(GetItemCount(itemId, false, false, false))
end

local function TradeSlotItemId(slot)
    if slot == 7 then return nil, 0 end
    if not GetTradePlayerItemInfo then return nil, 0 end
    local name, texture, count = GetTradePlayerItemInfo(slot)
    if not name then return nil, 0 end
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

local function CollectCarriedStacks(itemId)
    itemId = tonumber(itemId)
    if not itemId or not C_Container or not C_Container.GetContainerNumSlots then
        return {}
    end
    local stacks = {}
    local bags = CarriedBagIds()
    for bi = 1, #bags do
        local bag = bags[bi]
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and tonumber(info.itemID) == itemId then
                local count = FloorQty(info.stackCount)
                if count > 0 then
                    stacks[#stacks + 1] = {
                        bag = bag,
                        slot = slot,
                        count = count,
                        locked = info.isLocked and true or false,
                    }
                end
            end
        end
    end
    table.sort(stacks, function(a, b)
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end)
    return stacks
end

local function CollectStacksByItemKeys(totals)
    local byItem = {}
    for key in pairs(totals) do
        byItem[key] = CollectCarriedStacks(tonumber(key))
    end
    return byItem
end

local function PlaceOfferFromStack(bag, slot, qty)
    if CursorBusy() then
        return false, "cursor_busy"
    end
    bag = tonumber(bag)
    slot = tonumber(slot)
    qty = FloorQty(qty)
    if not bag or not slot or qty < 1 then
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
    local take = math.min(qty, have)
    if take < have and C_Container.SplitContainerItem then
        C_Container.SplitContainerItem(bag, slot, take)
    elseif C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bag, slot)
    else
        return false, "unsupported"
    end
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

local function DepositOrWithdrawBusy()
    local Runtime = SF.ConsumablesRuntime
    if Runtime and (Runtime.depositWork or Runtime.depositIntent) then
        return true
    end
    local WR = SF.ConsumablesWithdrawRuntime
    if WR and WR.IsBusy and WR.IsBusy() then
        return true
    end
    return false
end

function H.TryPrefillTrade()
    if not EnsureContextOrClear() then
        return
    end
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
    if DepositOrWithdrawBusy() then
        state.status = "blocked"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_BUSY",
            "Finish the bank movement before trade offering can continue.")
        H.RefreshStatusUI()
        return
    end
    state.prefillAttemptedFor = state.tradeLifecycleId
    state.prefillActive = true
    local offered = AlreadyOfferedCounts()
    local stacksByItem = CollectStacksByItemKeys(totals)
    local free = CountFreeTradeSlots()
    local moves, deferred = W.PlanTradePrefillMoves(totals, offered, stacksByItem, free, H.TRADE_SLOTS)
    local placed = 0
    for i = 1, #moves do
        local mv = moves[i]
        local ok, result = PlaceOfferFromStack(mv.bag, mv.slot, mv.qty)
        if ok then
            placed = placed + (tonumber(result) or 0)
        else
            local key = tostring(mv.itemKey)
            deferred[key] = (deferred[key] or 0) + FloorQty(mv.qty)
            if result == "cursor_busy" then
                break
            end
        end
    end
    state.prefillActive = false
    if next(deferred) then
        state.status = "partial"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_PARTIAL",
            "Some pending reagents could not be offered yet (slots, locks, or inventory).")
    elseif placed > 0 then
        state.status = "offered"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_OFFERED",
            "Offered pending reagents in the trade window. Accept/cancel remains a player action.")
    else
        state.status = "blocked"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_BLOCKED",
            "Pending reagents are not currently offerable.")
    end
    H.RefreshStatusUI()
end

--- Verify successful trade delivery and consume oldest matching batches.
function H.OnTradeCompleted(deliveredAmounts, ambiguousAmounts)
    deliveredAmounts = type(deliveredAmounts) == "table" and deliveredAmounts or {}
    ambiguousAmounts = type(ambiguousAmounts) == "table" and ambiguousAmounts or {}
    local now = Now()
    if next(deliveredAmounts) then
        state.batches = (W.ConsumeTradeBatches(state.batches, deliveredAmounts, now))
    end
    if next(ambiguousAmounts) then
        state.batches = W.BindTradeAmbiguity(state.batches, ambiguousAmounts, now)
        state.status = "unresolved"
        state.statusDetail = Loc("GUILD_SUPPLIES_TRADE_UNRESOLVED",
            "Trade completion is unresolved. Automatic re-offering is paused for the affected items.")
        H.RefreshStatusUI()
        return
    end
    local remaining = AggregatePending()
    local anyLeft = false
    for _ in pairs(remaining) do anyLeft = true break end
    if anyLeft then
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
    local ambiguousAny = AnyBatchAmbiguous(state.batches)
    if not any and not ambiguousAny and state.status ~= "unresolved" and state.status ~= "cleared" then
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

local function TradeAcceptFlag(v)
    return tonumber(v) == 1
end

function H.EnsureListeners()
    if state.listenersAttached then return end
    if not CreateFrame then return end
    if #state.batches > 0 and not state.context then
        state.context = CaptureContext()
    end
    local frame = CreateFrame("Frame", "SpectrumFederationTradeHandoff")
    state.frame = frame
    frame:RegisterEvent("TRADE_SHOW")
    frame:RegisterEvent("TRADE_CLOSED")
    frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:RegisterEvent("PLAYER_GUILD_UPDATE")

    local tradeSession = {
        bagBefore = nil,
        offeredSnapshot = nil,
        playerAccepted = false,
        targetAccepted = false,
        closedHandled = false,
        active = false,
    }

    local function SnapshotPendingBags()
        local totals = AggregatePending()
        local snap = {}
        for k in pairs(totals) do
            snap[k] = PlayerBagCount(tonumber(k))
        end
        return snap
    end

    local function CaptureOfferSnapshot()
        local snap = AlreadyOfferedCounts()
        if tradeSession.active then
            local copy = {}
            for k, v in pairs(snap) do
                copy[tostring(k)] = FloorQty(v)
            end
            tradeSession.offeredSnapshot = copy
            return
        end
        if next(snap) then
            tradeSession.offeredSnapshot = snap
        end
    end

    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_LOGOUT" then
            H.Reset()
            return
        end
        if event == "PLAYER_GUILD_UPDATE" then
            local unit = ...
            if unit and unit ~= "player" then
                return
            end
            if not ContextMatches() then
                H.Reset()
            end
            return
        end
        if not EnsureContextOrClear() then
            return
        end
        if event == "TRADE_SHOW" then
            state.tradeLifecycleId = state.tradeLifecycleId + 1
            state.prefillAttemptedFor = nil
            tradeSession.closedHandled = false
            tradeSession.playerAccepted = false
            tradeSession.targetAccepted = false
            tradeSession.offeredSnapshot = nil
            tradeSession.active = true
            tradeSession.bagBefore = SnapshotPendingBags()
            local totals = AggregatePending()
            local anyPending = false
            for _ in pairs(totals) do anyPending = true break end
            if anyPending then
                H.TryPrefillTrade()
                CaptureOfferSnapshot()
            end
            return
        end
        if event == "TRADE_ACCEPT_UPDATE" then
            local a1, a2 = ...
            if a1 ~= nil then
                tradeSession.playerAccepted = TradeAcceptFlag(a1)
            end
            if a2 ~= nil then
                tradeSession.targetAccepted = TradeAcceptFlag(a2)
            end
            CaptureOfferSnapshot()
            return
        end
        if event == "TRADE_CLOSED" then
            if tradeSession.closedHandled then
                tradeSession.bagBefore = nil
                tradeSession.offeredSnapshot = nil
                return
            end
            tradeSession.closedHandled = true
            tradeSession.active = false
            local offered = tradeSession.offeredSnapshot
            if type(offered) ~= "table" then
                local live = AlreadyOfferedCounts()
                if next(live) then
                    offered = live
                else
                    offered = {}
                end
            end
            -- Keep explicit {} from an active trade (player cleared all offers).
            -- Do not replace a prior non-empty snapshot with empty live reads after slots clear.
            offered = type(offered) == "table" and offered or {}
            local before = tradeSession.bagBefore or {}
            local bothAccepted = tradeSession.playerAccepted and tradeSession.targetAccepted
            local delivered, ambiguousAmounts, outcome = W.ResolveTradeDelivery(
                offered,
                before,
                function(key) return PlayerBagCount(tonumber(key)) end,
                bothAccepted
            )
            tradeSession.bagBefore = nil
            tradeSession.offeredSnapshot = nil
            tradeSession.playerAccepted = false
            tradeSession.targetAccepted = false
            if outcome == "cancelled" then
                H.OnTradeCancelled()
                return
            end
            H.OnTradeCompleted(delivered, ambiguousAmounts)
            return
        end
    end)
    state.listenersAttached = true
end

-- Test hooks
H._state = state
H._AggregatePending = AggregatePending
H._TradeAcceptFlag = TradeAcceptFlag
