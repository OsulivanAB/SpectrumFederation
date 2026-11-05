-- Quick Withdraw bank helper executor (#457).
-- Exact bank→bag movements with attempted vs confirmed evidence, shortage
-- dialog, receipt commit, and trade-handoff enqueue. Deposits remain separate.
local addonName, SF = ...

SF.ConsumablesWithdrawRuntime = SF.ConsumablesWithdrawRuntime or {}
local WR = SF.ConsumablesWithdrawRuntime
local Workflow = nil -- resolved lazily

local MAX_LOCK_WAITS = 20
local SETTLE_SECONDS = 1.5
local OBSERVE_INITIAL = 0.05
local OBSERVE_MAX = 0.25

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
    -- remainingWithdrawals: -1 = unlimited; nil = unknown; >=0 finite allowance.
    local unlimited = remainingWithdrawals == -1
    local remaining = nil
    if remainingWithdrawals ~= nil and remainingWithdrawals >= 0 then
        remaining = FloorQty(remainingWithdrawals)
    end
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
        if remainingWithdrawals == nil then
            reason = "unknown_allowance"
        elseif remaining == 0 then
            reason = "allowance_exhausted"
        else
            reason = "no_withdraw"
        end
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
        -- Quantity maps use itemId keys; array lists use numeric values.
        -- Prefer keys for maps so quantities are never mistaken for item IDs.
        local arrayLen = #itemIds
        if arrayLen > 0 then
            for i = 1, arrayLen do
                local n = tonumber(itemIds[i])
                if n then wanted[n] = true end
            end
        else
            for k in pairs(itemIds) do
                local n = tonumber(k)
                if n then wanted[n] = true end
            end
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

local function BagSlotFamily(bag)
    bag = tonumber(bag)
    if bag == nil then return 0 end
    if C_Container and C_Container.GetBagSlotFlag then
        return tonumber(C_Container.GetBagSlotFlag(bag)) or 0
    end
    return 0
end

function WR.ItemFamily(itemId)
    itemId = tonumber(itemId)
    if not itemId then return 0 end
    if C_Container and C_Container.GetItemFamily then
        return tonumber(C_Container.GetItemFamily(itemId)) or 0
    end
    return 0
end

function WR.ReadCarriedSlot(bag, slot)
    bag = tonumber(bag)
    slot = tonumber(slot)
    if bag == nil or slot == nil or not C_Container or not C_Container.GetContainerItemInfo then
        return nil
    end
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then
        local family = BagSlotFamily(bag)
        if C_Container.GetBagFreeSlotInfo then
            local ok, slotFamily = C_Container.GetBagFreeSlotInfo(bag, slot)
            if ok and slotFamily then
                family = tonumber(slotFamily) or family
            end
        end
        return { empty = true, family = family }
    end
    return {
        itemId = tonumber(info.itemID),
        count = FloorQty(info.stackCount),
        locked = info.isLocked and true or false,
        family = BagSlotFamily(bag),
    }
end

function WR.RevalidateStepDestination(step)
    Workflow = WR.ResolveWorkflow()
    if not Workflow or type(step) ~= "table" then
        return false, "invalid"
    end
    local itemId = tonumber(step.itemId)
    local bag = tonumber(step.destBag)
    local slot = tonumber(step.destSlot)
    if not itemId or bag == nil or slot == nil then
        return false, "invalid"
    end
    local slotState = WR.ReadCarriedSlot(bag, slot)
    if not slotState then return false, "invalid" end
    local Runtime = Host()
    local stackLimit = 1000
    if Runtime and Runtime.ItemStackLimit then
        stackLimit = Runtime:ItemStackLimit(itemId) or stackLimit
    end
    local dest = {
        count = step.count,
        merge = step.destMerge,
        itemFamily = WR.ItemFamily(itemId),
    }
    return Workflow.DestinationStillValid(slotState, dest, itemId, stackLimit)
end

function WR.BuildCarriedBagSnapshot()
    local Routing = SF.ConsumablesRouting
    local Runtime = Host()
    local rows = {}
    if not C_Container or not C_Container.GetContainerNumSlots then
        return rows
    end
    for bag = 0, 5 do
        if not Routing or Routing.IsCarriedBag(bag) then
            local slots = C_Container.GetContainerNumSlots(bag) or 0
            local bagRow = { bag = bag, slots = {} }
            for slot = 1, slots do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if not info then
                    local family = BagSlotFamily(bag)
                    if C_Container.GetBagFreeSlotInfo then
                        local ok, slotFamily = C_Container.GetBagFreeSlotInfo(bag, slot)
                        if ok and slotFamily then
                            family = tonumber(slotFamily) or family
                        end
                    end
                    bagRow.slots[#bagRow.slots + 1] = { slot = slot, empty = true, family = family }
                else
                    bagRow.slots[#bagRow.slots + 1] = {
                        slot = slot,
                        itemId = tonumber(info.itemID),
                        count = FloorQty(info.stackCount),
                        locked = info.isLocked and true or false,
                        family = BagSlotFamily(bag),
                    }
                end
            end
            rows[#rows + 1] = bagRow
        end
    end
    return rows
end

function WR.EstimateBagCapacity(itemId, qty)
    itemId = tonumber(itemId)
    qty = FloorQty(qty)
    if qty < 1 then return true, 0, 0, 0 end
    Workflow = WR.ResolveWorkflow()
    local Runtime = Host()
    local take = { [tostring(itemId)] = qty }
    local ok, err, plan = Workflow.PlanMultiItemBagDestinations(
        WR.BuildCarriedBagSnapshot(),
        take,
        function(id)
            if Runtime and Runtime.ItemStackLimit then
                return Runtime:ItemStackLimit(id)
            end
            return 1000
        end,
        function(id)
            return WR.ItemFamily(id)
        end
    )
    if not ok then
        return false, plan and plan.requiredNewStacks or 0,
            plan and plan.freeCompatibleSlots or 0, 0
    end
    return true, plan.requiredNewStacks, plan.freeCompatibleSlots, qty
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
    return type(GetCursorInfo) == "function" and GetCursorInfo() == nil
end

local function CursorItemId()
    if type(GetCursorInfo) ~= "function" then return nil end
    local kind, itemId, link = GetCursorInfo()
    if kind ~= "item" then return nil end
    local C = SF.Consumables
    return tonumber(itemId) or (C and C.ItemIdFromText and C.ItemIdFromText(link))
end

local function RecipeFingerprint(recipe)
    local GS = SF.GuildSupplies
    if not GS or not GS.CanonicalRecipeValue then return nil end
    local canon = GS.CanonicalRecipeValue(recipe)
    if not canon then return nil end
    local keys = {}
    for k in pairs(canon.reagents or {}) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    local parts = { tostring(canon.itemId or "") }
    for i = 1, #keys do
        parts[#parts + 1] = keys[i] .. "=" .. tostring(canon.reagents[keys[i]])
    end
    return table.concat(parts, ";")
end

WR.RecipeFingerprint = RecipeFingerprint

local function CopyStringKeyQtyMap(src)
    local out = {}
    if type(src) ~= "table" then return out end
    for k, v in pairs(src) do
        out[tostring(k)] = FloorQty(v)
    end
    return out
end

local function CopyCraftSelections(selections)
    local out = {}
    if type(selections) ~= "table" then return out end
    for k, v in pairs(selections) do
        out[tostring(k)] = tonumber(v) or 0
    end
    return out
end

function WR.TakeMapsEqual(a, b)
    local seen = {}
    for k, v in pairs(a or {}) do
        local key = tostring(k)
        seen[key] = true
        local left = FloorQty(v)
        local right = FloorQty((b or {})[key] or (b or {})[tonumber(key)])
        if left ~= right then return false end
    end
    for k, v in pairs(b or {}) do
        local key = tostring(k)
        if FloorQty(v) > 0 or seen[key] then
            local left = FloorQty((a or {})[key] or (a or {})[tonumber(key)])
            if left ~= FloorQty(v) then return false end
        end
    end
    return true
end

function WR.RequestedMapsEqual(a, b)
    local seen = {}
    for k, v in pairs(a or {}) do
        local key = tostring(k)
        seen[key] = true
        local left = FloorQty(v)
        local right = FloorQty((b or {})[key] or (b or {})[tonumber(key)])
        if left ~= right then return false end
    end
    for k, v in pairs(b or {}) do
        local key = tostring(k)
        if FloorQty(v) > 0 or seen[key] then
            local left = FloorQty((a or {})[key] or (a or {})[tonumber(key)])
            if left ~= FloorQty(v) then return false end
        end
    end
    return true
end

function WR.RecipeFingerprintsEqual(a, b)
    for k, fp in pairs(a or {}) do
        if (b or {})[k] ~= fp then return false end
    end
    for k in pairs(b or {}) do
        if (a or {})[k] == nil then return false end
    end
    return true
end

function WR.WithdrawContextMatchesBound(ctx, bound)
    if type(ctx) ~= "table" or type(bound) ~= "table" then return false end
    return ctx.guildKey == bound.guildKey
        and ctx.datasetId == bound.datasetId
        and ctx.campaignId == bound.campaignId
        and ctx.bankTab == bound.bankTab
        and ctx.generation == bound.generation
end

local function RecipeFingerprintsForSelections(selections, ctx)
    local recipeFingerprints = {}
    if type(selections) ~= "table" or type(ctx) ~= "table" then return recipeFingerprints end
    for outputKey, crafts in pairs(selections) do
        if FloorQty(crafts) > 0 then
            local recipe = ctx.recipes[tostring(outputKey)]
            recipeFingerprints[tostring(outputKey)] = RecipeFingerprint(recipe)
        end
    end
    return recipeFingerprints
end

local function EnforceAcceptedTakeCeiling(authorized, acceptedTake)
    if type(authorized) ~= "table" or type(acceptedTake) ~= "table" then
        return true
    end
    local take = authorized.take
    if type(take) ~= "table" then return true end
    for itemKey, qty in pairs(take) do
        local key = tostring(itemKey)
        local authQty = FloorQty(qty)
        if authQty < 1 then
            take[itemKey] = nil
        else
            local cap = acceptedTake[key]
            if cap == nil then cap = acceptedTake[tonumber(key)] end
            if cap == nil then
                return false, "accepted_take_exceeded"
            end
            local capQty = FloorQty(cap)
            if authQty > capQty then
                return false, "accepted_take_exceeded"
            end
            take[itemKey] = math.min(authQty, capQty)
        end
    end
    return true
end

WR.EnforceAcceptedTakeCeiling = EnforceAcceptedTakeCeiling
WR.CopyStringKeyQtyMap = CopyStringKeyQtyMap
WR.CopyCraftSelections = CopyCraftSelections

local function BuildWithdrawPreview(selections, opts)
    opts = opts or {}
    local ctx, err = WR.CurrentContext()
    if not ctx then return nil, err end
    local access = WR.WithdrawAccess(ctx.bankTab)
    if not access.canWithdraw then
        return nil, access.reason or "no_withdraw"
    end
    Workflow = WR.ResolveWorkflow()
    local requested, aggErr = Workflow.AggregateCrafts(selections, ctx.recipes)
    if not requested then return nil, aggErr end

    for outputKey, crafts in pairs(selections) do
        if FloorQty(crafts) > 0 then
            local recipe = ctx.recipes[tostring(outputKey)]
            if RecipeUnavailable(ctx.record, recipe) then
                return nil, "recipe_unavailable"
            end
        end
    end

    local recipeFingerprints = RecipeFingerprintsForSelections(selections, ctx)
    local stock = WR.ScanBankStock(ctx.bankTab, requested)
    local plan = Workflow.BuildStockPlan(requested, stock)
    if not plan.fullySatisfiable and not opts.allowPartial then
        return {
            err = "shortage",
            plan = plan,
            requested = requested,
            ctx = ctx,
            recipeFingerprints = recipeFingerprints,
        }
    end

    local authorized
    if not plan.fullySatisfiable then
        authorized = Workflow.AuthorizePartialPlan(plan)
        if not authorized then
            return {
                err = "nothing_available",
                plan = plan,
                requested = requested,
                ctx = ctx,
                recipeFingerprints = recipeFingerprints,
            }
        end
    else
        authorized = { take = plan.take, partial = false }
    end

    if opts.acceptedTake then
        local ok, capErr = EnforceAcceptedTakeCeiling(authorized, opts.acceptedTake)
        if not ok then
            return {
                err = capErr or "accepted_take_exceeded",
                plan = plan,
                authorized = authorized,
                requested = requested,
                ctx = ctx,
                recipeFingerprints = recipeFingerprints,
            }
        end
    end

    return {
        authorized = authorized,
        plan = plan,
        requested = requested,
        ctx = ctx,
        recipeFingerprints = recipeFingerprints,
    }
end

function WR.PreviewWithdrawPlan(selections, opts)
    local preview, err = BuildWithdrawPreview(selections, opts)
    if not preview then
        return false, err
    end
    if preview.err == "shortage" then
        return false, "shortage", preview
    end
    if preview.err then
        return false, preview.err, preview
    end
    return true, nil, preview
end

function WR.QuickWithdrawConfirmationStillValid(bound)
    if type(bound) ~= "table" then return false, "invalid_bound" end
    local ok, err, preview = WR.PreviewWithdrawPlan(bound.selections, { allowPartial = true })
    if not ok then
        return false, err or "preview_failed", preview
    end
    local ctx = preview.ctx
    if not WR.WithdrawContextMatchesBound(ctx, bound) then
        return false, "stale", preview
    end
    if not WR.RecipeFingerprintsEqual(bound.recipeFingerprints, preview.recipeFingerprints) then
        return false, "stale", preview
    end
    if not WR.RequestedMapsEqual(bound.requested, preview.requested) then
        return false, "stale", preview
    end
    local freshTake = preview.authorized and preview.authorized.take or preview.plan.take
    if not WR.TakeMapsEqual(bound.take, freshTake) then
        return false, "stale", preview
    end
    return true, nil, preview
end

local function BankSlotCount(bankTab, slot)
    if not GetGuildBankItemInfo then return 0 end
    local texture, count = GetGuildBankItemInfo(bankTab, slot)
    if not texture then return 0 end
    return FloorQty(count)
end

local function AttachWithdrawWork(work)
    WR.work = work
    local Runtime = Host()
    if Runtime then Runtime._withdrawWork = work end
end

local function DetachWithdrawWork()
    local Runtime = Host()
    if Runtime then Runtime._withdrawWork = nil end
    WR.work = nil
end

local function CancelObserveTimer(work)
    if work and work.observeTimer and work.observeTimer.Cancel then
        work.observeTimer:Cancel()
        work.observeTimer = nil
    end
end

local function ScheduleObserve(work, delay)
    if not work or not C_Timer or not C_Timer.After then return end
    CancelObserveTimer(work)
    delay = tonumber(delay) or OBSERVE_INITIAL
    work.observeTimer = C_Timer.After(delay, function()
        if WR.work == work then
            WR.ObservePending()
        end
    end)
end

local function PlaceCursorToDestination(dest)
    if type(dest) ~= "table" then return false end
    local bag = tonumber(dest.bag)
    local slot = tonumber(dest.slot)
    if bag == 0 then
        if dest.merge and C_Container and C_Container.PickupContainerItem and slot then
            C_Container.PickupContainerItem(0, slot)
        elseif PutItemInBackpack then
            PutItemInBackpack()
        else
            return false
        end
    elseif C_Container and C_Container.PickupContainerItem and bag and slot then
        C_Container.PickupContainerItem(bag, slot)
    else
        return false
    end
    return CursorEmpty()
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
    if not work then return end
    if work.settled then return end
    work.settled = true
    DetachWithdrawWork()
    CancelObserveTimer(work)
    if work and work.timer and work.timer.Cancel then
        work.timer:Cancel()
    end
    Debug("Info", "withdraw stop reason=%s confirmed=%s",
        tostring(reason), tostring(work and work.confirmedTotal or 0))
    if work and work.movementStarted then
        WR.ClearDrafts()
    end
    if work and type(work.onSettle) == "function" then
        local remaining = {}
        for k, want in pairs(work.take or {}) do
            local got = FloorQty((work.confirmed or {})[k])
            local left = FloorQty(want) - got
            if left > 0 then
                remaining[k] = left
            end
        end
        pcall(work.onSettle, {
            reason = reason,
            confirmed = work.confirmed or {},
            requested = work.requested or {},
            remaining = remaining,
            unresolved = work.unresolved,
            receiptError = work.receiptError,
            partial = partial,
        })
    end
    local Runtime = Host()
    if Runtime and Runtime.RebuildReview then
        Runtime:RebuildReview()
    end
end

local function CommitConfirmed(work)
    if type(work) ~= "table" then return true end
    if work.receiptCommitted and work.handoffCommitted then return true end
    local confirmed = work.confirmed or {}
    local any = false
    for _, qty in pairs(confirmed) do
        if FloorQty(qty) > 0 then any = true break end
    end
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
    if not work.receiptCommitted then
        if any and GS and GS.CommitLocalWithdrawalReceipts then
            local status, detail = GS:CommitLocalWithdrawalReceipts(confirmed, meta)
            if status ~= "accepted" and status ~= "duplicate" then
                Debug("Warn", "withdrawal receipt failed: %s %s", tostring(status), tostring(detail))
                work.receiptError = detail or status
                -- Do not retry bank movement to repair logging.
            end
        end
        work.receiptCommitted = true
    end
    local H = SF.ConsumablesTradeHandoff
    if not work.handoffCommitted then
        if any and H and H.EnqueueConfirmed then
            H.EnqueueConfirmed(confirmed, { operationId = work.operationId })
        end
        work.handoffCommitted = true
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
    local preview, previewErr = BuildWithdrawPreview(selections, opts)
    if not preview then return false, previewErr end
    if preview.err == "shortage" then
        return false, "shortage", preview.plan
    end
    if preview.err then
        return false, preview.err, preview.plan
    end
    local plan = preview.plan
    local authorized = preview.authorized
    local requested = preview.requested
    local recipeFingerprints = preview.recipeFingerprints

    -- Capacity / allowance preflight before first move.
    local units = 0
    for itemKey, qty in pairs(authorized.take) do
        qty = FloorQty(qty)
        units = units + qty
        local stacks = WR.ListSourceStacks(ctx.bankTab, tonumber(itemKey))
        local moves, unfilled = Workflow.PlanSourceMoves(stacks, qty)
        if Workflow.SourcePlanIncomplete(unfilled) then
            return false, "source_blocked", plan
        end
    end
    local okDest, destErr, destPlan = Workflow.PlanMultiItemBagDestinations(
        WR.BuildCarriedBagSnapshot(),
        authorized.take,
        function(id)
            if Runtime and Runtime.ItemStackLimit then
                return Runtime:ItemStackLimit(id)
            end
            return 1000
        end,
        function(id)
            return WR.ItemFamily(id)
        end
    )
    if not okDest then
        return false, destErr or "bag_capacity", plan
    end
    if H and H.PendingSnapshot then
        H.PendingSnapshot()
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

    local destRows = {}
    for i = 1, #(destPlan.destinations or {}) do
        local row = destPlan.destinations[i]
        destRows[#destRows + 1] = {
            itemId = row.itemId,
            bag = row.bag,
            slot = row.slot,
            count = row.count,
            merge = row.merge,
        }
    end
    local destByItem = {}
    for i = 1, #destRows do
        local row = destRows[i]
        local key = tostring(row.itemId)
        destByItem[key] = destByItem[key] or {}
        destByItem[key][#destByItem[key] + 1] = row
    end

    local queue = {}
    for itemKey, qty in pairs(authorized.take) do
        local itemId = tonumber(itemKey)
        local stacks = WR.ListSourceStacks(ctx.bankTab, itemId)
        local moves, unfilled = Workflow.PlanSourceMoves(stacks, FloorQty(qty))
        if Workflow.SourcePlanIncomplete(unfilled) then
            return false, "source_blocked", plan
        end
        local itemDests = destByItem[tostring(itemId)] or {}
        local di = 1
        for mi = 1, #moves do
            local move = moves[mi]
            local remaining = FloorQty(move.count)
            while remaining > 0 do
                local dest = itemDests[di]
                if not dest or FloorQty(dest.count) < 1 then
                    return false, "destination_plan", plan
                end
                local chunk = math.min(remaining, FloorQty(dest.count))
                local splitPick = chunk < remaining or move.split or chunk < FloorQty(move.count)
                queue[#queue + 1] = {
                    itemId = itemId,
                    slot = move.slot,
                    count = chunk,
                    split = splitPick,
                    destBag = dest.bag,
                    destSlot = dest.slot,
                    destMerge = dest.merge,
                }
                dest.count = FloorQty(dest.count) - chunk
                if dest.count < 1 then
                    di = di + 1
                end
                remaining = remaining - chunk
            end
        end
        if di <= #itemDests then
            return false, "destination_plan", plan
        end
    end
    if #queue < 1 then
        return false, "nothing_available", plan
    end
    if Workflow.AllowanceBlocksPlan(access.remaining, #queue) then
        return false, "allowance", plan
    end

    AttachWithdrawWork({
        operationId = operationId,
        campaignId = ctx.campaignId,
        datasetId = ctx.datasetId,
        generation = ctx.generation,
        configSeq = ctx.configSeq,
        bankTab = ctx.bankTab,
        guildKey = ctx.guildKey,
        requested = requested,
        take = authorized.take,
        selections = selections,
        recipeFingerprints = recipeFingerprints,
        confirmed = {},
        confirmedTotal = 0,
        queue = queue,
        index = 1,
        lockWaits = 0,
        movementStarted = false,
        startedAt = GetServerTime and GetServerTime() or time(),
        places = {},
        onSettle = opts.onSettle,
    })
    Debug("Info", "withdraw begin op=%s moves=%d", operationId, #queue)
    WR.PlaceNext()
    return true, nil, plan
end

function WR.ContextStillValid(work)
    local ctx = WR.CurrentContext()
    if not ctx then return false, "context_lost" end
    if ctx.guildKey ~= work.guildKey then return false, "guild_changed" end
    if ctx.datasetId ~= work.datasetId then return false, "dataset_changed" end
    if ctx.campaignId ~= work.campaignId then return false, "campaign_changed" end
    if ctx.generation ~= work.generation then return false, "generation_changed" end
    if ctx.configSeq ~= work.configSeq then return false, "config_changed" end
    if ctx.bankTab ~= work.bankTab then return false, "tab_changed" end
    if GetCurrentGuildBankTab and GetCurrentGuildBankTab() ~= work.bankTab then
        return false, "wrong_tab"
    end
    Workflow = WR.ResolveWorkflow()
    for outputKey, fp in pairs(work.recipeFingerprints or {}) do
        local recipe = ctx.recipes[outputKey]
        if not recipe or RecipeFingerprint(recipe) ~= fp then
            return false, "recipe_changed"
        end
        if RecipeUnavailable(ctx.record, recipe) then
            return false, "recipe_unavailable"
        end
    end
    if work.selections and Workflow.AggregateCrafts then
        local requested2, aggErr = Workflow.AggregateCrafts(work.selections, ctx.recipes)
        if not requested2 then return false, aggErr or "request_invalid" end
        for k, qty in pairs(work.requested or {}) do
            local key = tostring(k)
            local want = FloorQty(qty)
            local have = FloorQty(requested2[key] or requested2[tonumber(key)])
            if have ~= want then
                return false, "request_changed"
            end
        end
    end
    local access = WR.WithdrawAccess(work.bankTab)
    if not access.canWithdraw then return false, access.reason or "no_withdraw" end
    if InCombatLockdown and InCombatLockdown() then return false, "combat" end
    return true
end

function WR.PlaceNext()
    local work = WR.work
    if not work then return end
    if work.pendingStep then return end
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
        CommitConfirmed(work)
        StopWork("source_missing", true)
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
                if WR.work == work and not work.pendingStep then WR.PlaceNext() end
            end)
        end
        return
    end
    work.lockWaits = 0
    local beforeBags = WR.BagCount(step.itemId)
    local beforeSlot = found.count
    local take = math.min(step.count, found.count)
    if take < 1 then
        CommitConfirmed(work)
        StopWork("source_empty", true)
        return
    end
    local destOk, destWhy = WR.RevalidateStepDestination(step)
    if not destOk then
        CommitConfirmed(work)
        StopWork(destWhy or "destination_invalid", true)
        return
    end
    work.movementStarted = true
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
    local cursorId = CursorItemId()
    if cursorId ~= step.itemId then
        CommitConfirmed(work)
        StopWork((cursorId and cursorId ~= step.itemId) and "foreign_cursor" or "cursor_mismatch", true)
        return
    end
    local dest = {
        bag = step.destBag,
        slot = step.destSlot,
        merge = step.destMerge,
    }
    if not PlaceCursorToDestination(dest) then
        Workflow = WR.ResolveWorkflow()
        local afterBags = WR.BagCount(step.itemId)
        local afterSlot = BankSlotCount(work.bankTab, step.slot)
        if Workflow and Workflow.InterpretWithdrawal then
            local actual = Workflow.InterpretWithdrawal({
                guildOk = true,
                observedTab = work.bankTab,
                configuredTab = work.bankTab,
                intendedQty = take,
                beforeBags = beforeBags,
                afterBags = afterBags,
                placedSlots = { { before = beforeSlot, after = afterSlot } },
            })
            if FloorQty(actual) > 0 then
                local key = tostring(step.itemId)
                work.confirmed[key] = (work.confirmed[key] or 0) + actual
                work.confirmedTotal = (work.confirmedTotal or 0) + actual
            end
        end
        if ClearCursor and CursorItemId() == step.itemId then
            ClearCursor()
        end
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
    work.pendingStep = {
        itemId = step.itemId,
        slot = step.slot,
        count = take,
        beforeBags = beforeBags,
        beforeSlot = beforeSlot,
        observeStartedAt = GetServerTime and GetServerTime() or time(),
        observeDelay = OBSERVE_INITIAL,
    }
    work.index = work.index + 1
    ScheduleObserve(work, OBSERVE_INITIAL)
end

function WR.ObservePending()
    local work = WR.work
    if not work or not work.pendingStep then return end
    Workflow = WR.ResolveWorkflow()
    local pending = work.pendingStep
    local step = pending
    local afterBags = WR.BagCount(step.itemId)
    local afterSlot = BankSlotCount(work.bankTab, step.slot)
    local actual = Workflow.InterpretWithdrawal({
        guildOk = true,
        observedTab = work.bankTab,
        configuredTab = work.bankTab,
        intendedQty = step.count,
        beforeBags = pending.beforeBags,
        afterBags = afterBags,
        placedSlots = { { before = pending.beforeSlot, after = afterSlot } },
    })
    local now = GetServerTime and GetServerTime() or time()
    local elapsed = now - (pending.observeStartedAt or now)
    local fromTimer = elapsed >= SETTLE_SECONDS
    local uncertain = fromTimer and actual < FloorQty(step.count)
    local disposition = Workflow.WithdrawalDisposition(actual, step.count, fromTimer, uncertain)
    if disposition == "commit" and actual >= FloorQty(step.count) then
        CancelObserveTimer(work)
        local key = tostring(step.itemId)
        work.confirmed[key] = (work.confirmed[key] or 0) + actual
        work.confirmedTotal = (work.confirmedTotal or 0) + actual
        work.pendingStep = nil
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if WR.work == work then WR.PlaceNext() end
            end)
        else
            WR.PlaceNext()
        end
        return
    end
    if disposition == "unresolved" or (fromTimer and actual <= 0) then
        CancelObserveTimer(work)
        work.unresolved = {
            itemId = step.itemId,
            slot = step.slot,
            intended = step.count,
            actual = actual,
        }
        work.pendingStep = nil
        CommitConfirmed(work)
        StopWork("unresolved", true)
        return
    end
    if disposition == "drop" and fromTimer then
        CancelObserveTimer(work)
        work.pendingStep = nil
        CommitConfirmed(work)
        StopWork("unresolved", true)
        return
    end
    local nextDelay = math.min(OBSERVE_MAX, (pending.observeDelay or OBSERVE_INITIAL) * 2)
    pending.observeDelay = nextDelay
    ScheduleObserve(work, nextDelay)
end

function WR.FinalizeWork()
    local work = WR.work
    if not work then return end
    if work.pendingStep then return end
    WR.ObservePending()
    if work.pendingStep then return end
    if work.settling then return end
    work.settling = true
    local function finish()
        if WR.work ~= work then return end
        if work.pendingStep then
            work.settling = nil
            return
        end
        WR.ObservePending()
        if work.pendingStep then
            work.settling = nil
            return
        end
        CommitConfirmed(work)
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
        if WR.work then
            CommitConfirmed(work)
            StopWork("bank_closed", true)
        end
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
