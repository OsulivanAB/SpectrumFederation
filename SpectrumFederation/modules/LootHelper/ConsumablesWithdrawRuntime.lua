-- Quick Withdraw bank helper executor (#457).
-- Exact bank→bag movements with attempted vs confirmed evidence, shortage
-- dialog, receipt commit, and trade-handoff enqueue. Deposits remain separate.
local addonName, SF = ...

SF.ConsumablesWithdrawRuntime = SF.ConsumablesWithdrawRuntime or {}
local WR = SF.ConsumablesWithdrawRuntime
local Workflow = nil -- resolved lazily

local MAX_LOCK_WAITS = 20
local SETTLE_SECONDS = 1.5

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

local function FloorQty(n)
    n = tonumber(n) or 0
    if n ~= n or n < 0 then return 0 end
    return math.floor(n)
end

local function Host()
    return SF.ConsumablesRuntime
end

function WR.ResolveWorkflow()
    Workflow = SF.ConsumablesWithdrawWorkflow
    return Workflow
end

--- Blizzard withdraw access for the configured tab (independent of deposit).
-- GetGuildBankTabInfo returns name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals, filtered, ...
function WR.WithdrawAccess(bankTab)
    local Runtime = Host()
    if not Runtime or not Runtime.BankIsOpen or not Runtime:BankIsOpen() then
        return {
            bankOpen = false,
            canWithdraw = false,
            remaining = nil,
            unlimited = false,
            reason = "bank_closed",
        }
    end
    bankTab = tonumber(bankTab)
    if not bankTab then
        return { bankOpen = true, canWithdraw = false, reason = "unconfigured" }
    end
    if not GetGuildBankTabInfo then
        return { bankOpen = true, canWithdraw = false, reason = "unsupported" }
    end
    local name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals =
        GetGuildBankTabInfo(bankTab)
    -- View permission is required to see stock; withdraw uses remainingWithdrawals.
    -- remainingWithdrawals: -1 often means unlimited on Retail.
    local unlimited = remainingWithdrawals == nil or remainingWithdrawals < 0
    local remaining = unlimited and nil or FloorQty(remainingWithdrawals)
    local canWithdraw = false
    if isViewable then
        if unlimited then
            canWithdraw = true
        elseif remaining and remaining > 0 then
            canWithdraw = true
        end
    end
    local reason = nil
    if not isViewable then
        reason = "no_view"
    elseif not canWithdraw then
        reason = unlimited and "no_withdraw" or "allowance_exhausted"
    end
    return {
        bankOpen = true,
        tab = bankTab,
        isViewable = isViewable and true or false,
        canDeposit = canDeposit and true or false,
        canWithdraw = canWithdraw,
        remaining = remaining,
        unlimited = unlimited,
        reason = reason,
        name = name,
    }
end

function WR.CurrentContext()
    local GS = SF.GuildSupplies
    if not GS or not GS.IsLiveActiveForCurrentGuild or not GS:IsLiveActiveForCurrentGuild() then
        return nil, "not_live"
    end
    local record = select(1, GS:GetCurrentRecord())
    if type(record) ~= "table" then
        return nil, "not_ready"
    end
    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" then
        return nil, "invalid_accounting"
    end
    local campaignId = record.currentCampaignId
    if type(campaignId) ~= "string" or campaignId == "" then
        return nil, "no_campaign"
    end
    local bankTab = tonumber(cfg.bankTab)
    if not bankTab then
        return nil, "no_bank_tab"
    end
    local recipes = type(cfg.recipes) == "table" and cfg.recipes or {}
    local anyRecipe = false
    for _ in pairs(recipes) do anyRecipe = true break end
    if not anyRecipe then
        return nil, "no_recipes"
    end
    return {
        record = record,
        cfg = cfg,
        campaignId = campaignId,
        datasetId = record.datasetId,
        bankTab = bankTab,
        recipes = recipes,
        generation = tonumber(cfg.generation),
        configSeq = tonumber(cfg.configSeq),
        guildKey = record._guildKey,
    }
end

function WR.ShouldShowHelper()
    local ctx, err = WR.CurrentContext()
    if not ctx then return false, err end
    local access = WR.WithdrawAccess(ctx.bankTab)
    if not access.bankOpen then return false, "bank_closed" end
    local Runtime = Host()
    if Runtime and Runtime.ConfiguredBankTabReady then
        local profile = nil
        if Runtime.AccountingProfile then
            profile = Runtime:AccountingProfile()
        end
        local readyCfg = { bankTab = ctx.bankTab }
        if profile and SF.Consumables and SF.Consumables.Ensure then
            readyCfg = SF.Consumables.Ensure(profile) or readyCfg
        end
        if profile and not Runtime:ConfiguredBankTabReady(readyCfg) then
            -- Fall back: compare current tab.
            if GetCurrentGuildBankTab and GetCurrentGuildBankTab() ~= ctx.bankTab then
                return false, "wrong_tab"
            end
        end
    elseif GetCurrentGuildBankTab and GetCurrentGuildBankTab() ~= ctx.bankTab then
        return false, "wrong_tab"
    end
    -- Withdrawal can show without deposit permission / carried items / free bank slots.
    if not access.canWithdraw and access.reason == "allowance_exhausted" then
        return true, "allowance_exhausted", ctx, access
    end
    if not access.canWithdraw then
        return false, access.reason or "no_withdraw", ctx, access
    end
    return true, nil, ctx, access
end

function WR.ScanBankStock(bankTab, itemIds)
    local stock = {}
    if not GetGuildBankItemInfo or not GetGuildBankItemLink then
        return stock
    end
    bankTab = tonumber(bankTab)
    local wanted = {}
    if type(itemIds) == "table" then
        for _, id in pairs(itemIds) do
            local n = tonumber(id)
            if n then wanted[n] = true end
        end
    end
    local Runtime = Host()
    local slots = 98
    if Runtime and Runtime.GuildBankSlotCount then
        slots = Runtime:GuildBankSlotCount(bankTab) or slots
    end
    for slot = 1, slots do
        local texture, count, locked = GetGuildBankItemInfo(bankTab, slot)
        if texture and FloorQty(count) > 0 then
            local link = GetGuildBankItemLink(bankTab, slot)
            local itemId = link and SF.Consumables and SF.Consumables.ItemIdFromText
                and SF.Consumables.ItemIdFromText(link) or nil
            itemId = tonumber(itemId)
            if itemId and (next(wanted) == nil or wanted[itemId]) then
                local key = tostring(itemId)
                stock[key] = (stock[key] or 0) + FloorQty(count)
            end
        end
    end
    return stock
end

function WR.ListSourceStacks(bankTab, itemId)
    local stacks = {}
    itemId = tonumber(itemId)
    bankTab = tonumber(bankTab)
    if not itemId or not GetGuildBankItemInfo then return stacks end
    local Runtime = Host()
    local slots = 98
    if Runtime and Runtime.GuildBankSlotCount then
        slots = Runtime:GuildBankSlotCount(bankTab) or slots
    end
    for slot = 1, slots do
        local texture, count, locked = GetGuildBankItemInfo(bankTab, slot)
        if texture and FloorQty(count) > 0 then
            local link = GetGuildBankItemLink(bankTab, slot)
            local sid = link and SF.Consumables and SF.Consumables.ItemIdFromText
                and SF.Consumables.ItemIdFromText(link) or nil
            if tonumber(sid) == itemId then
                stacks[#stacks + 1] = {
                    slot = slot,
                    count = FloorQty(count),
                    locked = locked and true or false,
                }
            end
        end
    end
    return stacks
end

function WR.BagCount(itemId)
    if not GetItemCount then return 0 end
    return FloorQty(GetItemCount(itemId, false, false, false))
end

function WR.EstimateBagCapacity(itemId, qty)
    -- Conservative: count free bag slots that can hold the item + partial merge room.
    itemId = tonumber(itemId)
    qty = FloorQty(qty)
    if qty < 1 then return true, 0 end
    local maxStack = 1000
    if C_Item and C_Item.GetItemInfo then
        -- stack size may be unavailable; keep conservative.
    end
    local Runtime = Host()
    if Runtime and Runtime.ItemStackLimit then
        maxStack = Runtime:ItemStackLimit(itemId) or maxStack
    end
    local mergeRoom = 0
    local freeSlots = 0
    if C_Container and C_Container.GetContainerNumSlots then
        for bag = 0, NUM_BAG_SLOTS or 4 do
            local slots = C_Container.GetContainerNumSlots(bag) or 0
            for slot = 1, slots do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if not info then
                    freeSlots = freeSlots + 1
                elseif tonumber(info.itemID) == itemId and not info.isLocked then
                    local room = maxStack - FloorQty(info.stackCount)
                    if room > 0 then mergeRoom = mergeRoom + room end
                end
            end
        end
    end
    local afterMerge = math.max(0, qty - mergeRoom)
    local stacksNeeded = 0
    if afterMerge > 0 then
        stacksNeeded = math.ceil(afterMerge / maxStack)
    end
    return stacksNeeded <= freeSlots, stacksNeeded, freeSlots, mergeRoom
end

--- Session craft-count drafts keyed by output item id (cleared on bank close).
WR.craftDrafts = WR.craftDrafts or {}
WR.work = nil

function WR.ClearDrafts()
    for k in pairs(WR.craftDrafts) do
        WR.craftDrafts[k] = nil
    end
end

function WR.IsBusy()
    return WR.work ~= nil
end

local function CursorEmpty()
    return not GetCursorInfo or GetCursorInfo() == nil
end

local function RecipeUnavailable(record, recipe)
    local GS = SF.GuildSupplies
    if not recipe then return true end
    if GS and GS.RecipeAvailability then
        local ok = GS.RecipeAvailability(record, recipe)
        return not ok
    end
    return false
end

local function ReceiptCapacityBlocked(record, take)
    local GS = SF.GuildSupplies
    if not GS or not GS.WithdrawalReceiptCapacityOk then return false end
    local need = 0
    for _ in pairs(take or {}) do need = need + 1 end
    return not GS.WithdrawalReceiptCapacityOk(record, need)
end

local function AllocateOpId()
    local GS = SF.GuildSupplies
    if GS and GS._AllocateOperationId and GS.GetCurrentContext then
        local ctx = GS:GetCurrentContext()
        if ctx and ctx.actorGuid then
            local id = GS:_AllocateOperationId(ctx.actorGuid)
            if id then return id end
        end
    end
    return nil
end

local function StopWork(reason, partial)
    local work = WR.work
    WR.work = nil
    if work and work.timer and work.timer.Cancel then
        work.timer:Cancel()
    end
    Debug("Info", "withdraw stop reason=%s confirmed=%s",
        tostring(reason), tostring(work and work.confirmedTotal or 0))
    if work and type(work.onSettle) == "function" then
        pcall(work.onSettle, {
            reason = reason,
            confirmed = work.confirmed or {},
            requested = work.requested or {},
            partial = partial,
        })
    end
    local Runtime = Host()
    if Runtime and Runtime.RebuildReview then
        Runtime:RebuildReview()
    end
end

local function CommitConfirmed(work)
    local confirmed = work.confirmed or {}
    local any = false
    for _, qty in pairs(confirmed) do
        if FloorQty(qty) > 0 then any = true break end
    end
    if not any then return true end
    local GS = SF.GuildSupplies
    local meta = {
        operationId = work.operationId,
        campaignId = work.campaignId,
        generation = work.generation,
        bankTab = work.bankTab,
        datasetId = work.datasetId,
        guildKey = work.guildKey,
        timestamp = work.startedAt,
    }
    if GS and GS.CommitLocalWithdrawalReceipts then
        local status, detail = GS:CommitLocalWithdrawalReceipts(confirmed, meta)
        if status ~= "accepted" and status ~= "duplicate" then
            Debug("Warn", "withdrawal receipt failed: %s %s", tostring(status), tostring(detail))
            work.receiptError = detail or status
            -- Do not retry bank movement to repair logging.
        end
    end
    local H = SF.ConsumablesTradeHandoff
    if H and H.EnqueueConfirmed then
        H.EnqueueConfirmed(confirmed, { operationId = work.operationId })
    end
    return true
end

function WR.BeginWithdraw(selections, opts)
    opts = opts or {}
    if WR.IsBusy() then
        return false, "busy"
    end
    local Runtime = Host()
    if Runtime and (Runtime.depositWork or Runtime.depositIntent) then
        return false, "deposit_busy"
    end
    local H = SF.ConsumablesTradeHandoff
    if H and H.GetState and H.GetState().prefillActive then
        return false, "trade_busy"
    end
    if InCombatLockdown and InCombatLockdown() then
        return false, "combat"
    end
    if not CursorEmpty() then
        return false, "cursor_busy"
    end
    local ctx, err = WR.CurrentContext()
    if not ctx then return false, err end
    local access = WR.WithdrawAccess(ctx.bankTab)
    if not access.canWithdraw then
        return false, access.reason or "no_withdraw"
    end
    Workflow = WR.ResolveWorkflow()
    local requested, aggErr = Workflow.AggregateCrafts(selections, ctx.recipes)
    if not requested then return false, aggErr end

    -- Validate recipe availability.
    for outputKey, crafts in pairs(selections) do
        if FloorQty(crafts) > 0 then
            local recipe = ctx.recipes[tostring(outputKey)]
            if RecipeUnavailable(ctx.record, recipe) then
                return false, "recipe_unavailable"
            end
        end
    end

    local stock = WR.ScanBankStock(ctx.bankTab, requested)
    local plan = Workflow.BuildStockPlan(requested, stock)
    if not plan.fullySatisfiable and not opts.allowPartial then
        return false, "shortage", plan
    end
    local authorized = plan
    if not plan.fullySatisfiable then
        authorized = Workflow.AuthorizePartialPlan(plan)
        if not authorized then return false, "nothing_available", plan end
    else
        authorized = { take = plan.take, partial = false }
    end

    -- Capacity / allowance preflight before first move.
    local plannedStacks = 0
    local units = 0
    for itemKey, qty in pairs(authorized.take) do
        qty = FloorQty(qty)
        units = units + qty
        local stacks = WR.ListSourceStacks(ctx.bankTab, tonumber(itemKey))
        local moves = Workflow.PlanSourceMoves(stacks, qty)
        plannedStacks = plannedStacks + #moves
        local okCap = WR.EstimateBagCapacity(tonumber(itemKey), qty)
        if not okCap then
            return false, "bag_capacity", plan
        end
    end
    if Workflow.AllowanceBlocksPlan(access.remaining, plannedStacks) then
        return false, "allowance", plan
    end
    if H and H.CanAcceptUnits then
        local okH, hErr = H.CanAcceptUnits(units)
        if not okH then return false, hErr or "handoff_full", plan end
    end
    if ReceiptCapacityBlocked(ctx.record, authorized.take) then
        return false, "receipt_full", plan
    end

    local operationId = AllocateOpId()
        or string.format("qw:%d:%d", GetServerTime and GetServerTime() or time(), math.random(1, 1e6))

    local queue = {}
    for itemKey, qty in pairs(authorized.take) do
        local stacks = WR.ListSourceStacks(ctx.bankTab, tonumber(itemKey))
        local moves = Workflow.PlanSourceMoves(stacks, FloorQty(qty))
        for i = 1, #moves do
            queue[#queue + 1] = {
                itemId = tonumber(itemKey),
                slot = moves[i].slot,
                count = moves[i].count,
                split = moves[i].split,
            }
        end
    end
    if #queue < 1 then
        return false, "nothing_available", plan
    end

    WR.work = {
        operationId = operationId,
        campaignId = ctx.campaignId,
        datasetId = ctx.datasetId,
        generation = ctx.generation,
        configSeq = ctx.configSeq,
        bankTab = ctx.bankTab,
        guildKey = ctx.guildKey,
        requested = requested,
        take = authorized.take,
        confirmed = {},
        confirmedTotal = 0,
        queue = queue,
        index = 1,
        lockWaits = 0,
        startedAt = GetServerTime and GetServerTime() or time(),
        places = {},
        onSettle = opts.onSettle,
    }
    Debug("Info", "withdraw begin op=%s moves=%d", operationId, #queue)
    WR.PlaceNext()
    return true, nil, plan
end

function WR.ContextStillValid(work)
    local ctx = WR.CurrentContext()
    if not ctx then return false, "context_lost" end
    if ctx.datasetId ~= work.datasetId then return false, "dataset_changed" end
    if ctx.campaignId ~= work.campaignId then return false, "campaign_changed" end
    if ctx.generation ~= work.generation then return false, "generation_changed" end
    if ctx.bankTab ~= work.bankTab then return false, "tab_changed" end
    if GetCurrentGuildBankTab and GetCurrentGuildBankTab() ~= work.bankTab then
        return false, "wrong_tab"
    end
    local access = WR.WithdrawAccess(work.bankTab)
    if not access.canWithdraw then return false, access.reason or "no_withdraw" end
    if InCombatLockdown and InCombatLockdown() then return false, "combat" end
    return true
end

function WR.PlaceNext()
    local work = WR.work
    if not work then return end
    local okCtx, why = WR.ContextStillValid(work)
    if not okCtx then
        CommitConfirmed(work)
        StopWork(why, true)
        return
    end
    if work.index > #work.queue then
        WR.FinalizeWork()
        return
    end
    if not CursorEmpty() then
        -- Foreign cursor: stop without clearing.
        CommitConfirmed(work)
        StopWork("foreign_cursor", true)
        return
    end
    local step = work.queue[work.index]
    local stacks = WR.ListSourceStacks(work.bankTab, step.itemId)
    local found = nil
    for i = 1, #stacks do
        if stacks[i].slot == step.slot then
            found = stacks[i]
            break
        end
    end
    if not found then
        work.index = work.index + 1
        WR.PlaceNext()
        return
    end
    if found.locked then
        work.lockWaits = (work.lockWaits or 0) + 1
        if work.lockWaits > MAX_LOCK_WAITS then
            CommitConfirmed(work)
            StopWork("locked", true)
            return
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(0.1, function()
                if WR.work == work then WR.PlaceNext() end
            end)
        end
        return
    end
    work.lockWaits = 0
    local beforeBags = WR.BagCount(step.itemId)
    local beforeSlot = found.count
    local take = math.min(step.count, found.count)
    if take < 1 then
        work.index = work.index + 1
        WR.PlaceNext()
        return
    end
    -- Exact split when needed.
    if take < found.count then
        if SplitGuildBankItem then
            SplitGuildBankItem(work.bankTab, step.slot, take)
        else
            CommitConfirmed(work)
            StopWork("split_unsupported", true)
            return
        end
    else
        if PickupGuildBankItem then
            PickupGuildBankItem(work.bankTab, step.slot)
        else
            CommitConfirmed(work)
            StopWork("unsupported", true)
            return
        end
    end
    -- Cursor should now hold our item.
    local cursorType, itemIdOrLink = GetCursorInfo and GetCursorInfo()
    local cursorId = nil
    if cursorType == "item" then
        cursorId = tonumber(itemIdOrLink) or (type(itemIdOrLink) == "string"
            and tonumber(itemIdOrLink:match("item:(%d+)")))
    end
    if cursorId ~= step.itemId then
        if ClearCursor and cursorType then
            -- Only clear if we own it; if foreign, stop without clearing.
            if cursorId == nil or cursorId == step.itemId then
                ClearCursor()
            end
        end
        CommitConfirmed(work)
        StopWork("cursor_mismatch", true)
        return
    end
    -- Auto-store into bags.
    if AutoStoreGuildBankItem and take == found.count and not step.split then
        -- Already picked up; use PutItemInBackpack / Deposit.
    end
    if PutItemInBackpack then
        PutItemInBackpack()
    elseif C_Container and C_Container.PickupContainerItem then
        -- Try first free bag slot via UseContainerItem pattern — PutItemInBag preferred.
        for bag = 0, NUM_BAG_SLOTS or 4 do
            -- PutItemInBag(bagIndex) exists on Retail.
            if PutItemInBag then
                PutItemInBag(bag)
                break
            end
        end
    end
    if not CursorEmpty() then
        -- Placement failed; recover owned cursor.
        if ClearCursor then ClearCursor() end
        CommitConfirmed(work)
        StopWork("bag_place_failed", true)
        return
    end
    work.places[#work.places + 1] = {
        itemId = step.itemId,
        slot = step.slot,
        intended = take,
        beforeBags = beforeBags,
        beforeSlot = beforeSlot,
    }
    work.pendingStep = step
    work.pendingBeforeBags = beforeBags
    work.index = work.index + 1
    -- Observe via bag/bank events; also schedule settle continuation.
    if C_Timer and C_Timer.After then
        C_Timer.After(0.05, function()
            if WR.work == work then
                WR.ObservePending()
                WR.PlaceNext()
            end
        end)
    else
        WR.ObservePending()
        WR.PlaceNext()
    end
end

function WR.ObservePending()
    local work = WR.work
    if not work or not work.pendingStep then return end
    local step = work.pendingStep
    local afterBags = WR.BagCount(step.itemId)
    local gain = math.max(0, afterBags - FloorQty(work.pendingBeforeBags))
    if gain > 0 then
        local key = tostring(step.itemId)
        local add = math.min(gain, FloorQty(step.count))
        work.confirmed[key] = (work.confirmed[key] or 0) + add
        work.confirmedTotal = (work.confirmedTotal or 0) + add
        work.pendingStep = nil
    end
end

function WR.FinalizeWork()
    local work = WR.work
    if not work then return end
    WR.ObservePending()
    -- Short settle window for late bag events.
    if work.settling then return end
    work.settling = true
    local function finish()
        if WR.work ~= work then return end
        WR.ObservePending()
        CommitConfirmed(work)
        -- Reset craft drafts for processed recipes on settlement.
        WR.ClearDrafts()
        local partial = false
        for k, want in pairs(work.take or {}) do
            if FloorQty(work.confirmed[k]) < FloorQty(want) then
                partial = true
                break
            end
        end
        StopWork(partial and "partial" or "complete", partial)
    end
    if C_Timer and C_Timer.After then
        work.timer = C_Timer.After(SETTLE_SECONDS, finish)
    else
        finish()
    end
end

function WR.OnBankClosed()
    local work = WR.work
    if work then
        WR.ObservePending()
        CommitConfirmed(work)
        StopWork("bank_closed", true)
    end
    WR.ClearDrafts()
end

function WR.OnBagOrBankUpdate()
    if WR.work then
        WR.ObservePending()
    end
end

-- Expose for Runtime integration / tests.
WR.StopWork = StopWork
WR.CommitConfirmed = CommitConfirmed
