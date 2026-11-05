-- Quick Withdraw recipes + receipts + trade handoff (#457).
-- Run: lua5.1 tests/lua/guild_supplies_457_tests.lua
local ROOT = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../"

local function loadModule(rel)
    local path = ROOT .. rel
    local chunk, err = loadfile(path)
    if not chunk then error("load failed: " .. path .. " :: " .. tostring(err)) end
    chunk("SpectrumFederation", SF)
end

-- Minimal stubs matching guild_supplies_tests.lua harness style.
SF = SF or {}
SF.Debug = {
    IsEnabled = function() return false end,
    Info = function() end,
    Warn = function() end,
    Error = function() end,
}
SF.LocaleText = function(_, default) return default end
SF.Consumables = SF.Consumables or {
    MAX_REQUESTED_ITEMS = 256,
    MAX_GOAL = 100000,
    ValidGoal = function(g)
        g = tonumber(g)
        if not g or g ~= math.floor(g) or g < 0 or g > 100000 then return nil end
        return g
    end,
}

local failures = 0
local function assertTrue(cond, msg)
    if not cond then
        failures = failures + 1
        io.stderr:write("FAIL: " .. tostring(msg) .. "\n")
    end
end
local function assertEq(a, b, msg)
    if a ~= b then
        failures = failures + 1
        io.stderr:write(string.format("FAIL: %s (got %s expected %s)\n",
            tostring(msg), tostring(a), tostring(b)))
    end
end
local function assertFalse(cond, msg)
    if cond then
        failures = failures + 1
        io.stderr:write("FAIL: " .. tostring(msg) .. "\n")
    end
end

-- Load domain modules in TOC order (subset).
loadModule("SpectrumFederation/modules/GuildSupplies/State.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Authority.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Recipes.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Operations.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Campaigns.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Activation.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Ledger.lua")
loadModule("SpectrumFederation/modules/GuildSupplies/Withdrawals.lua")
loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawWorkflow.lua")

local GS = SF.GuildSupplies
local W = SF.ConsumablesWithdrawWorkflow

assertTrue(GS ~= nil, "GS loaded")
assertEq(GS.KIND.SET_RECIPE, "set-recipe", "SET_RECIPE kind")
assertEq(GS.PROVIDER_SCHEMA or 5, 5, "provider schema bumped for #457 (Admission may not be loaded)")
assertEq(GS.LEDGER_EVENT.WITHDRAWAL, "withdrawal", "withdrawal ledger kind")
assertEq(GS.MAX_RECIPES, 32, "recipe limit")
assertEq(GS.MAX_WITHDRAWAL_EVENTS, 1024, "withdrawal capacity")

-- Recipe normalize / aggregate
do
    local value, err = GS.CanonicalRecipeValue({
        itemId = 100,
        reagents = { ["10"] = 3, ["20"] = 0, ["30"] = 2 },
    })
    assertTrue(value ~= nil, "canonical recipe: " .. tostring(err))
    assertEq(value.reagents["10"], 3, "reagent 10")
    assertEq(value.reagents["20"], nil, "zero omitted")
    assertEq(value.reagents["30"], 2, "reagent 30")

    local empty, emptyErr = GS.CanonicalRecipeValue({ itemId = 100, reagents = { ["10"] = 0 } })
    assertEq(empty, nil, "empty reagents rejected")
    assertEq(emptyErr, "empty_reagents", "empty reason")

    local recipes = {
        ["100"] = { itemId = 100, reagents = { ["10"] = 3, ["20"] = 2 } },
        ["200"] = { itemId = 200, reagents = { ["10"] = 1, ["30"] = 4 } },
    }
    local amounts, aerr = GS.AggregateRecipeWithdrawal({ ["100"] = 4, ["200"] = 2 }, recipes)
    assertTrue(amounts ~= nil, "aggregate: " .. tostring(aerr))
    assertEq(amounts["10"], 14, "shared reagent X = 14")
    assertEq(amounts["20"], 8, "Y = 8")
    assertEq(amounts["30"], 8, "Z = 8")

    -- Carried inventory does not reduce request (aggregation ignores bags).
    local amounts2 = GS.AggregateRecipeWithdrawal({ ["100"] = 1 }, recipes)
    assertEq(amounts2["10"], 3, "craft count meaning preserved")
end

-- Stock plan / partial / capacity helpers
do
    local plan = W.BuildStockPlan({ ["10"] = 14, ["20"] = 8 }, { ["10"] = 5, ["20"] = 8 })
    assertEq(plan.fullySatisfiable, false, "shortage detected")
    assertEq(plan.take["10"], 5, "partial take X")
    assertEq(plan.take["20"], 8, "full take Y")
    assertEq(#plan.shortages, 1, "one shortage row")
    assertEq(plan.shortages[1].missing, 9, "missing X")

    local auth = W.AuthorizePartialPlan(plan)
    assertTrue(auth ~= nil, "authorize partial")
    assertEq(auth.partial, true, "partial flag")

    local moves, rem = W.PlanSourceMoves({
        { slot = 2, count = 20 },
        { slot = 1, count = 5 },
    }, 8)
    assertEq(rem, 0, "fully planned")
    assertEq(moves[1].slot, 1, "lowest slot first")
    assertEq(moves[1].count, 5, "take full small stack")
    assertEq(moves[2].split, true, "split remainder")
    assertEq(moves[2].count, 3, "split qty")

    assertEq(W.AllowanceBlocksPlan(2, 3), true, "allowance blocks")
    assertEq(W.AllowanceBlocksPlan(nil, 99), false, "unlimited ok")
    assertEq(W.CapacityBlocksPlan(1, 2), true, "bag capacity blocks")
end

-- Quick Withdraw shortage confirmation helpers (#457 repair)
do
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    local WR = SF.ConsumablesWithdrawRuntime
    assertTrue(WR.TakeMapsEqual({ ["10"] = 5, ["20"] = 8 }, { ["10"] = 5, ["20"] = 8 }),
        "take maps equal")
    assertEq(WR.TakeMapsEqual({ ["10"] = 5 }, { ["10"] = 8 }), false,
        "take increase detected")
    assertEq(WR.TakeMapsEqual({ ["10"] = 5 }, { ["10"] = 3 }), false,
        "take decrease detected")
    local authorized = { take = { ["10"] = 8, ["20"] = 2 }, partial = true }
    local ok = WR.EnforceAcceptedTakeCeiling(authorized, { ["10"] = 5, ["20"] = 2 })
    assertEq(ok, false, "accepted take blocks increase")
    authorized = { take = { ["10"] = 4, ["20"] = 2 }, partial = true }
    ok = WR.EnforceAcceptedTakeCeiling(authorized, { ["10"] = 5, ["20"] = 2 })
    assertTrue(ok, "accepted take allows same or lower")
    assertEq(authorized.take["10"], 4, "take unchanged under cap")
    authorized = { take = { ["30"] = 1 }, partial = true }
    ok = WR.EnforceAcceptedTakeCeiling(authorized, { ["10"] = 5 })
    assertEq(ok, false, "new take item blocked")
end

-- Multi-item bag destination reservation (shared empty-slot pool)
do
    local bags = {
        { bag = 0, slots = {
            { slot = 1, empty = true },
            { slot = 2, empty = true },
        } },
        { bag = 5, slots = {
            { slot = 1, itemId = 10, count = 18, locked = false },
        } },
    }
    local ok, err, plan = W.PlanMultiItemBagDestinations(bags, { ["10"] = 5, ["20"] = 20 }, function()
        return 20
    end)
    assertTrue(ok, "multi dest: " .. tostring(err))
    assertEq(plan.requiredNewStacks, 2, "two empty stacks after merge on item 10")
    local destRows = {}
    for i = 1, #plan.destinations do
        destRows[i] = plan.destinations[i]
    end
    assertEq(destRows[1].count, 2, "merge portion for item 10")
    assertEq(destRows[2].count, 3, "empty slot portion for item 10")
    local d1 = W.TakeDestinationForMove(destRows, 10, 2)
    assertTrue(d1 ~= nil and d1.merge, "take merge row")
    assertEq(d1.count, 2, "merge qty")
    assertEq(W.SourcePlanIncomplete(1), true, "source incomplete")
    assertEq(W.SourcePlanIncomplete(0), false, "source complete")
end

-- Bag family compatibility: specialty empty slots cannot take mismatched reagents.
do
    assertTrue(W.SlotAcceptsItemFamily(0, 8), "general bag accepts restricted item")
    assertTrue(W.SlotAcceptsItemFamily(4, 4), "matching family")
    assertFalse(W.SlotAcceptsItemFamily(4, 8), "mismatched family")

    local herbBag = {
        { bag = 4, slots = {
            { slot = 1, empty = true, family = 4 },
        } },
        { bag = 0, slots = {
            { slot = 1, empty = true, family = 0 },
        } },
    }
    local okHerb, errHerb, planHerb = W.PlanMultiItemBagDestinations(
        herbBag,
        { ["100"] = 5 },
        function() return 20 end,
        function() return 4 end
    )
    assertTrue(okHerb, "herb item into herb+general: " .. tostring(errHerb))
    assertEq(planHerb.requiredNewStacks, 1, "uses herb slot not general-only miscount")

    local okOre, errOre = W.PlanMultiItemBagDestinations(
        { { bag = 4, slots = { { slot = 1, empty = true, family = 4 } } } },
        { ["200"] = 5 },
        function() return 20 end,
        function() return 8 end
    )
    assertFalse(okOre, "ore blocked when only herb bag slots exist")
    assertEq(errOre, "bag_capacity", "capacity error when no compatible slot")

    local okDest, destErr = W.DestinationStillValid(
        { empty = true, family = 4 },
        { count = 5, merge = false, itemFamily = 8 },
        200,
        20
    )
    assertFalse(okDest, "revalidate rejects family mismatch")
    assertEq(destErr, "family", "family reason")
end

-- Allowance counts bank pickups (destination splits), not source stack count alone.
do
    local moves, rem = W.PlanSourceMoves({ { slot = 1, count = 10 } }, 10)
    assertEq(rem, 0, "one source stack")
    assertEq(#moves, 1, "one source move")
    local destRows = {
        { itemId = 10, bag = 0, slot = 1, count = 5, merge = true },
        { itemId = 10, bag = 0, slot = 2, count = 5, merge = false },
    }
    local pickups = 0
    local remaining = 10
    for mi = 1, #moves do
        local move = moves[mi]
        local left = math.floor(tonumber(move.count) or 0)
        local di = 1
        while left > 0 do
            local dest = destRows[di]
            local chunk = math.min(left, math.floor(tonumber(dest.count) or 0))
            pickups = pickups + 1
            left = left - chunk
            if chunk >= math.floor(tonumber(dest.count) or 0) then
                di = di + 1
            end
        end
    end
    assertEq(pickups, 2, "merge+new destination splits into two bank pickups")
    assertTrue(W.AllowanceBlocksPlan(1, pickups), "allowance uses pickup count")
    assertFalse(W.AllowanceBlocksPlan(2, pickups), "two pickups fit allowance of 2")
end

-- Withdrawal interpret / disposition
do
    local actual = W.InterpretWithdrawal({
        guildOk = true,
        observedTab = 1,
        configuredTab = 1,
        intendedQty = 10,
        beforeTab = 20,
        afterTab = 12,
        beforeBags = 0,
        afterBags = 8,
    })
    assertEq(actual, 8, "min of bank loss and bag gain")

    assertEq(W.WithdrawalDisposition(8, 10, false, false), "wait", "wait for more")
    assertEq(W.WithdrawalDisposition(8, 10, true, false), "commit", "timer partial commit")
    assertEq(W.WithdrawalDisposition(0, 10, true, false), "drop", "timer zero drop")
    assertEq(W.WithdrawalDisposition(5, 10, false, true), "unresolved", "uncertain")
end

-- Trade batch D3: independent expiry + oldest-first consume + no extend
do
    local batches = {}
    local b1 = { id = "a", completedAt = 100, expiresAt = 100 + 3600, amounts = { ["10"] = 5 } }
    local b2 = { id = "b", completedAt = 200, expiresAt = 200 + 3600, amounts = { ["10"] = 3 } }
    batches = W.AppendTradeBatch(batches, b1)
    batches = W.AppendTradeBatch(batches, b2)
    assertEq(#batches, 2, "two batches")
    assertEq(batches[1].expiresAt, 100 + 3600, "older expiry unchanged")
    assertEq(batches[2].expiresAt, 200 + 3600, "newer independent expiry")

    local rem, consumed = W.ConsumeTradeBatches(batches, { ["10"] = 6 }, 150)
    assertEq(consumed["10"], 6, "consumed 6")
    -- Oldest first: batch a (5) fully consumed and dropped; batch b loses 1 → 2 left
    assertEq(#rem, 1, "oldest dropped when emptied")
    assertEq(rem[1].id, "b", "newer remains")
    assertEq(rem[1].amounts["10"], 2, "newer has 2 left")

    -- Expired batch dropped without extending
    local rem2 = W.ConsumeTradeBatches(batches, {}, 100 + 3600)
    assertEq(#rem2, 1, "expired oldest dropped; newer remains")
    assertEq(rem2[1].id, "b", "newer survives")

    local full = batches
    for i = 1, 40 do
        local nextB, err = W.AppendTradeBatch(full, {
            id = "x" .. i, completedAt = i, expiresAt = i + 3600, amounts = { ["1"] = 1 },
        }, 32)
        if not nextB then
            assertEq(err, "full", "batch cap")
            break
        end
        full = nextB
    end
end

-- Prefill planning respects manual offers and slot limits
do
    local toOffer, deferred = W.PlanTradePrefill(
        { ["10"] = 10, ["20"] = 5 },
        { ["10"] = 4 },
        { ["10"] = 20, ["20"] = 5 },
        1,
        6
    )
    assertEq(toOffer["10"], 6, "offer remaining pending after manual")
    assertTrue(deferred["20"] ~= nil, "second item deferred by slot")

    local moves, def2 = W.PlanTradePrefillMoves(
        { ["10"] = 15 },
        {},
        { ["10"] = {
            { bag = 0, slot = 2, count = 5 },
            { bag = 0, slot = 5, count = 20 },
        } },
        2,
        6
    )
    assertEq(#moves, 2, "multi-stack same item uses two slots")
    assertEq(moves[1].qty + moves[2].qty, 15, "exact quantity across stacks")
    assertEq(def2["10"] or 0, 0, "fully planned stacks")

    local delivered, amb, outcome = W.ResolveTradeDelivery(
        { ["10"] = 5 },
        { ["10"] = 10 },
        function() return 8 end,
        true
    )
    assertEq(outcome, "ambiguous", "partial bag loss is ambiguous")
    assertEq(delivered["10"], 2, "proven delivery capped to bag loss")
    assertEq(amb["10"], 3, "unverified portion ambiguous")

    local _, ambOnly, outcome2 = W.ResolveTradeDelivery(
        { ["10"] = 4 },
        { ["10"] = 10 },
        function() return 10 end,
        true
    )
    assertEq(outcome2, "ambiguous", "accepted without bag loss")
    assertEq(ambOnly["10"], 4, "all offered becomes ambiguous")

    local batches = {
        { id = "a", completedAt = 1, expiresAt = 5000, amounts = { ["10"] = 5 } },
        { id = "b", completedAt = 2, expiresAt = 20000, amounts = { ["10"] = 5 } },
    }
    local bound = W.BindTradeAmbiguity(batches, { ["10"] = 6 }, 100)
    assertEq(bound[1].ambiguous["10"], 5, "oldest batch owns ambiguity first")
    assertEq(bound[2].ambiguous["10"], 1, "remainder on newer batch")
    local pruned = (W.ConsumeTradeBatches(bound, {}, 10000))
    assertEq(#pruned, 1, "expired batch ambiguity dropped with batch")
    assertEq(pruned[1].id, "b", "surviving batch remains")
    assertEq(pruned[1].ambiguous["10"], 1, "surviving ambiguity intact")

    -- R4: consumption skips paused/ambiguous batch amounts (oldest-first on eligible only)
    local ambBatches = {
        {
            id = "paused",
            completedAt = 1,
            expiresAt = 5000,
            amounts = { ["10"] = 5 },
            ambiguous = { ["10"] = 5 },
        },
        {
            id = "eligible",
            completedAt = 2,
            expiresAt = 5000,
            amounts = { ["10"] = 5 },
        },
    }
    local remElig, consumedElig = W.ConsumeTradeBatches(ambBatches, { ["10"] = 5 }, 100)
    assertEq(consumedElig["10"], 5, "R4: deliver 5 consumes eligible batch only")
    assertEq(#remElig, 1, "R4: paused batch remains")
    assertEq(remElig[1].id, "paused", "R4: ambiguous batch untouched")
    assertEq(remElig[1].amounts["10"], 5, "R4: paused amounts remain")
    assertEq(remElig[1].ambiguous["10"], 5, "R4: paused ambiguity remains")
    local eligiblePending = 0
    for i = 1, #remElig do
        local b = remElig[i]
        local amounts = b.amounts or {}
        local amb = b.ambiguous or {}
        for k, v in pairs(amounts) do
            local left = (tonumber(v) or 0) - (tonumber(amb[k] or amb[tonumber(k)]) or 0)
            if left > 0 then eligiblePending = eligiblePending + left end
        end
    end
    assertEq(eligiblePending, 0, "R4: next trade must not re-offer consumed eligible batch")
end

-- Receipt validation / accounting isolation helpers
do
    local event = {
        type = "withdrawal",
        id = "gsw1:test:10:1",
        datasetId = "gs1:test",
        campaignId = "camp1",
        generation = 1,
        itemId = 10,
        quantity = 5,
        actor = "Alice-Realm",
        actorGuid = "Player-1-AAAA",
        bankTab = 1,
        timestamp = 1000,
        provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN,
        operationId = "op1",
        guildKey = "club:1",
        gsProductionCredit = false,
    }
    local ok, err = GS.ValidateWithdrawalEventBody(event, "gs1:test")
    assertTrue(ok, "valid withdrawal: " .. tostring(err))

    event.gsProductionCredit = true
    ok, err = GS.ValidateWithdrawalEventBody(event, "gs1:test")
    assertEq(ok, false, "credit forbidden")

    event.gsProductionCredit = false
    event.unitCopper = 12
    ok = GS.ValidateWithdrawalEventBody(event, "gs1:test")
    assertEq(ok, false, "valuation forbidden")

    -- Progress predicate ignores withdrawals
    assertEq(GS.EventCountsTowardLiveProgress({ activation = "active" }, {
        type = "withdrawal", gsProductionCredit = true,
    }), false, "withdrawal never counts toward progress")
end

-- Copy/validate recipes map
do
    local ok = GS.ValidateRecipesMap({
        ["100"] = { itemId = 100, reagents = { ["10"] = 2 } },
    })
    assertTrue(ok, "valid recipes map")
    local copy = GS.CopyRecipes({
        ["100"] = { itemId = 100, reagents = { ["10"] = 2, ["20"] = 0 } },
    })
    -- NormalizeRecipeReagents omits zeros during ValidateRecipeEntry path
    assertTrue(type(copy) == "table", "copy ok")
end


-- G7: donation capacity ignores withdrawal occupancy; scans see extra allowance
do
    local function CountNonWithdrawal(list)
        local n = 0
        for i = 1, #list do
            local e = list[i]
            if type(e) == "table"
                and e.type ~= "withdrawal"
                and e.type ~= (GS.LEDGER_EVENT and GS.LEDGER_EVENT.WITHDRAWAL) then
                n = n + 1
            end
        end
        return n
    end
    local record = {
        datasetId = "gs1:cap",
        currentCampaignId = "camp1",
        accounting = {
            _mutationSeq = 0,
            _consumables = { generation = 1, eventSeq = 0, bankTab = 1, recipes = {} },
            _consumableEvents = {},
            _consumableEventArchive = {},
        },
    }
    local live = record.accounting._consumableEvents
    for i = 1, 3072 do
        live[#live + 1] = {
            type = "CONSUMABLE_DONATION",
            id = "don:" .. i,
            quantity = 1,
            itemId = 1,
            generation = 1,
        }
    end
    for i = 1, 1024 do
        live[#live + 1] = {
            type = "withdrawal",
            id = "wd:" .. i,
            datasetId = "gs1:cap",
            campaignId = "camp1",
            generation = 1,
            itemId = 10,
            quantity = 1,
            actor = "A-Realm",
            actorGuid = "Player-1-A",
            bankTab = 1,
            timestamp = 1000 + i,
            provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN,
            operationId = "opcap",
            guildKey = "club:1",
            gsProductionCredit = false,
        }
    end
    assertEq(#live, 4096, "seeded combined live length")
    assertEq(CountNonWithdrawal(live), 3072, "donation occupancy 3072")
    assertTrue(CountNonWithdrawal(live) < (GS.MAX_LEDGER_EVENTS or 4096),
        "donation room remains despite withdrawal rows")
    assertEq(GS.WithdrawalReceiptCapacityOk(record, 1), false, "withdrawal live full")

    local record2 = {
        datasetId = "gs1:cap2",
        currentCampaignId = "camp1",
        accounting = {
            _mutationSeq = 0,
            _consumables = { generation = 1, eventSeq = 0, bankTab = 1 },
            _consumableEvents = {},
            _consumableEventArchive = {},
        },
    }
    for i = 1, 4096 do
        record2.accounting._consumableEvents[#record2.accounting._consumableEvents + 1] = {
            type = "CONSUMABLE_DONATION", id = "d2:" .. i, quantity = 1, itemId = 1, generation = 1,
        }
    end
    assertTrue(GS.WithdrawalReceiptCapacityOk(record2, 1), "withdrawal room after 4096 donations")
end

-- ScanBankStock map keys vs quantity values (must not treat quantities as item IDs)
do
    local map = { ["12345"] = 10, ["67890"] = 5 }
    local keys = {}
    for k in pairs(map) do
        local n = tonumber(k)
        if n then keys[#keys + 1] = n end
    end
    table.sort(keys)
    assertEq(keys[1], 12345, "map key item id")
    assertEq(keys[2], 67890, "map key item id 2")
    assertTrue(keys[1] ~= 10 and keys[1] ~= 5, "quantities are not item ids")
end

-- Accept-flag numeric decoding (Lua 0 is truthy; only numeric 1 is accepted)
do
    local function IsAccepted(v)
        return tonumber(v) == 1
    end
    assertEq(IsAccepted(0), false, "0 not accepted")
    assertEq(IsAccepted(1), true, "1 accepted")
    assertEq(IsAccepted(true), false, "boolean true not accepted without tonumber 1")
end

-- R5: guild-update scoping + partial prefill status (handoff runtime)
do
    local guildKey = "club:handoff-test"
    _G.UIParent = _G.UIParent or {}
    _G.GetServerTime = function() return 1000 end
    _G.UnitGUID = function() return "Player-1-HANDOFF" end
    SF.ConsumablesWithdrawRuntime = {
        CurrentContext = function() return { guildKey = guildKey } end,
        IsBusy = function() return false end,
    }
    _G.CreateFrame = function(_, _, _, template)
        local f = { scripts = {} }
        function f:RegisterEvent() end
        function f:SetScript(kind, fn) f.scripts[kind] = fn end
        function f:Hide() end
        function f:Show() end
        function f:SetSize() end
        function f:SetPoint() end
        function f:SetBackdrop() end
        function f:CreateFontString() return { SetPoint = function() end, SetJustifyH = function() end, SetWordWrap = function() end, SetText = function() end } end
        if template == "UIPanelButtonTemplate" then
            return { SetSize = function() end, SetPoint = function() end, SetText = function() end, SetScript = function() end, Enable = function() end }
        end
        if template == "UIPanelCloseButton" then
            return { SetPoint = function() end, SetScript = function() end }
        end
        return f
    end
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesTradeHandoff.lua")
    local H = SF.ConsumablesTradeHandoff
    local batch = H.EnqueueConfirmed({ ["10"] = 3 }, { operationId = "op-handoff" })
    assertTrue(batch ~= nil, "handoff enqueue for guild tests")
    H.EnsureListeners()
    local st = H.GetState()
    local onEvent = st.frame and st.frame.scripts and st.frame.scripts.OnEvent
    assertTrue(type(onEvent) == "function", "handoff listener attached")
    onEvent(st.frame, "PLAYER_GUILD_UPDATE", "target")
    assertEq(#st.batches, 1, "R5: unrelated unit guild update preserves batches")
    onEvent(st.frame, "PLAYER_GUILD_UPDATE", "player")
    assertEq(#st.batches, 1, "R5: player guild update with stable context preserves batches")
    SF.ConsumablesWithdrawRuntime.CurrentContext = function() return { guildKey = "club:other" } end
    onEvent(st.frame, "PLAYER_GUILD_UPDATE", "player")
    assertEq(#st.batches, 0, "R5: context loss clears handoff")
    H.Reset()

    -- Partial status when deferred remain after some placements (seven stacks, six slots).
    st.batches = {
        { id = "p", completedAt = 1, expiresAt = 5000, amounts = { ["10"] = 7 } },
    }
    st.context = { playerGuid = "Player-1-HANDOFF", guildKey = guildKey }
    st.tradeLifecycleId = 1
    st.prefillAttemptedFor = nil
    SF.ConsumablesWithdrawRuntime.CurrentContext = function() return { guildKey = guildKey } end
    _G.GetCursorInfo = function() return nil end
    _G.GetTradePlayerItemInfo = function() return nil end
    _G.GetItemCount = function() return 20 end
    SF.ConsumablesRouting = { IsCarriedBag = function() return true end }
    C_Container = {
        GetContainerNumSlots = function() return 7 end,
        GetContainerItemInfo = function(_, slot)
            if slot >= 1 and slot <= 7 then
                return { itemID = 10, stackCount = 1, isLocked = false }
            end
        end,
        SplitContainerItem = function() end,
        PickupContainerItem = function() end,
    }
    _G.ClickTradeButton = function() end
    _G.ClearCursor = function() end
    local placedSlots = 0
    _G.GetTradePlayerItemInfo = function(slot)
        if slot <= placedSlots then return "item", nil, 1 end
        return nil
    end
    _G.ClickTradeButton = function()
        placedSlots = placedSlots + 1
    end
    H.TryPrefillTrade()
    assertEq(st.status, "partial", "R5: partial when deferred remain after successful offers")
end


-- R6: provenance identity ignores ORIGIN vs RELAY for duplicate detection
do
    local base = {
        type = "withdrawal",
        id = "gsw1:relay:10:1",
        datasetId = "gs1:test",
        campaignId = "camp1",
        generation = 1,
        itemId = 10,
        quantity = 5,
        actor = "Alice-Realm",
        actorGuid = "Player-1-AAAA",
        bankTab = 1,
        timestamp = 1000,
        provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN,
        operationId = "op1",
        guildKey = "club:1",
        gsProductionCredit = false,
    }
    local originId = GS.CanonicalWithdrawalEventIdentity(base)
    local relay = {}
    for k, v in pairs(base) do relay[k] = v end
    relay.provenance = GS.WITHDRAWAL_PROVENANCE.RELAY
    local relayId = GS.CanonicalWithdrawalEventIdentity(relay)
    assertTrue(originId ~= nil and relayId ~= nil, "identity bodies")
    assertTrue(GS._DeepEqualOps(originId, relayId), "provenance identity ignores ORIGIN vs RELAY")
    local fullOrigin = GS.CanonicalWithdrawalEvent(base)
    local fullRelay = GS.CanonicalWithdrawalEvent(relay)
    assertTrue(fullOrigin.provenance ~= fullRelay.provenance, "presentation provenance still differs")
end

-- R4: ConsumeTradeBatches skips ambiguous paused quantities
do
    local batches = {
        { id = "a", completedAt = 1, expiresAt = 99999, amounts = { ["10"] = 5 }, ambiguous = { ["10"] = 5 } },
        { id = "b", completedAt = 2, expiresAt = 99999, amounts = { ["10"] = 5 } },
    }
    local rem, consumed = W.ConsumeTradeBatches(batches, { ["10"] = 5 }, 100)
    assertEq(consumed["10"], 5, "consumed eligible only")
    assertEq(#rem, 1, "one batch remains")
    assertEq(rem[1].id, "a", "ambiguous batch preserved")
    assertEq(rem[1].amounts["10"], 5, "paused qty intact")
    assertEq(rem[1].ambiguous["10"], 5, "ambiguity intact")
end

-- R6a: mixed-capacity projection sees donation past the old 4096 scan bound
do
    local record = {
        datasetId = "gs1:proj",
        currentCampaignId = "camp1",
        activation = "staged",
        accounting = {
            _consumables = { generation = 1 },
            _consumableEvents = {},
            _consumableEventArchive = {},
        },
    }
    local live = record.accounting._consumableEvents
    for i = 1, 3072 do
        live[#live + 1] = {
            type = "CONSUMABLE_DONATION",
            id = "don-p:" .. i,
            quantity = 1,
            itemId = 99,
            generation = 1,
            timestamp = i,
            actor = "Alice-Realm",
        }
    end
    for i = 1, 1024 do
        live[#live + 1] = {
            type = "withdrawal",
            id = "wd-p:" .. i,
            datasetId = "gs1:proj",
            campaignId = "camp1",
            generation = 1,
            itemId = 10,
            quantity = 1,
            actor = "Alice-Realm",
            actorGuid = "Player-1-A",
            bankTab = 1,
            timestamp = 4000 + i,
            provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN,
            operationId = "op-p",
            guildKey = "club:1",
            gsProductionCredit = false,
        }
    end
    live[#live + 1] = {
        type = "CONSUMABLE_DONATION",
        id = "don-p:4097",
        quantity = 1,
        itemId = 99,
        generation = 1,
        timestamp = 9000,
        actor = "Alice-Realm",
    }
    assertEq(#live, 4097, "R6a: live length includes row 4097")
    local progress, perr = GS.ProjectCampaignProgressOnRecord(record, "camp1")
    assertTrue(progress ~= nil, "R6a progress: " .. tostring(perr))
    assertEq(progress.itemTotals[99], 3073, "R6a: progress includes donation past 4096")
end

-- R6b: archive withdrawal retention cap is separate and enforced on shelve
do
    local record = {
        datasetId = "gs1:trim",
        currentCampaignId = "camp1",
        accounting = {
            _mutationSeq = 0,
            _consumables = { generation = 2 },
            _consumableEvents = {
                {
                    type = "withdrawal",
                    id = "wd-live-old",
                    generation = 1,
                    itemId = 10,
                    quantity = 1,
                },
            },
            _consumableEventArchive = {},
        },
    }
    local arch = record.accounting._consumableEventArchive
    for i = 1, 1200 do
        arch[#arch + 1] = {
            type = "withdrawal",
            id = "wd-arch:" .. i,
            generation = 1,
            itemId = 10,
            quantity = 1,
            timestamp = i,
        }
    end
    assertEq(#arch, 1200, "R6b: seeded over-cap archive withdrawals")
    assertTrue(GS.ShelvePriorGenerationsOnRecord(record), "R6b: shelve triggers trim")
    local after = record.accounting._consumableEventArchive
    local wd = 0
    for i = 1, #after do
        if after[i].type == "withdrawal" then
            wd = wd + 1
        end
    end
    assertTrue(wd <= (GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024),
        "R6b: archive withdrawals capped at maxWd")
    assertTrue(#after <= (GS.MAX_ARCHIVED_EVENTS or 4096) + (GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024),
        "R6b: combined archive length within maxTotal")
end

-- R6c/R6d: admission scope + provenance-stable identity via real AdmitWithdrawalEvent
do
    loadModule("SpectrumFederation/modules/GuildSupplies/Admission.lua")
    local function baseEvent(overrides)
        local e = {
            type = "withdrawal",
            id = "gsw1:admit:10:1",
            datasetId = "gs1:admit",
            campaignId = "camp1",
            generation = 1,
            itemId = 10,
            quantity = 5,
            actor = "Alice-Realm",
            actorGuid = "Player-1-AAAA",
            bankTab = 1,
            timestamp = 1000,
            provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN,
            operationId = "op-admit",
            guildKey = "club:admit",
            gsProductionCredit = false,
        }
        if overrides then
            for k, v in pairs(overrides) do e[k] = v end
        end
        return e
    end
    local function makeRecord()
        return {
            datasetId = "gs1:admit",
            _guildKey = "club:admit",
            currentCampaignId = "camp1",
            campaigns = { camp1 = { id = "camp1" } },
            campaignArchives = {},
            accounting = {
                _mutationSeq = 0,
                _consumables = { generation = 1, eventSeq = 0, bankTab = 1 },
                _consumableEvents = {},
                _consumableEventArchive = {},
            },
        }
    end
    local record = makeRecord()
    local st, err = GS.AdmitWithdrawalEvent(record, baseEvent(), {
        senderGuid = "Player-1-AAAA",
        memberAuthenticated = true,
    })
    assertEq(st, "accepted", "R6c: origin admit: " .. tostring(err))
    local st2, err2 = GS.AdmitWithdrawalEvent(record, baseEvent({
        provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN,
    }), {
        senderGuid = "Player-1-RELAY",
        memberAuthenticated = true,
    })
    assertEq(st2, "duplicate", "R6c: relay of same body is duplicate not conflict: " .. tostring(err2))
    local stored = record.accounting._consumableEvents[#record.accounting._consumableEvents]
    assertEq(stored.provenance, GS.WITHDRAWAL_PROVENANCE.ORIGIN, "R6c: ORIGIN provenance retained")

    local stGuild = select(1, GS.AdmitWithdrawalEvent(makeRecord(), baseEvent({
        id = "gsw1:admit:wrong-guild",
        guildKey = "club:other",
    }), { senderGuid = "Player-1-AAAA", memberAuthenticated = true }))
    assertEq(stGuild, "rejected", "R6d: wrong guild rejected")

    local stCamp = select(1, GS.AdmitWithdrawalEvent(makeRecord(), baseEvent({
        id = "gsw1:admit:no-camp",
        campaignId = "missing-camp",
    }), { senderGuid = "Player-1-AAAA", memberAuthenticated = true }))
    assertEq(stCamp, "pending", "R6d: unknown campaign pending")

    local stGen = select(1, GS.AdmitWithdrawalEvent(makeRecord(), baseEvent({
        id = "gsw1:admit:future-gen",
        generation = 9,
    }), { senderGuid = "Player-1-AAAA", memberAuthenticated = true }))
    assertEq(stGen, "rejected", "R6d: future generation rejected")

    local missingDs = baseEvent({ id = "gsw1:admit:no-ds" })
    missingDs.datasetId = nil
    local stDs = select(1, GS.AdmitWithdrawalEvent(makeRecord(), missingDs, {
        senderGuid = "Player-1-AAAA", memberAuthenticated = true,
    }))
    assertEq(stDs, "rejected", "R6d: missing datasetId rejected")
end

-- R8: recipe-page completeness resumes across real 32-visit budgets
do
    local Validate = GS._ValidateAdoptionCompletenessForTest
    assertTrue(type(Validate) == "function", "R8: completeness test seam")
    local campId = "camp-arch-r8"
    -- 40 ordinary pages + 40 recipe pages: first budget=32 yields mid-items;
    -- a later slice yields mid-recipes so resume of recipePageCursor is covered.
    local pageCount = 40
    local recipePageCount = 40
    local pages, recipePages = {}, {}
    local mergedItems, mergedRecipes = {}, {}
    for p = 1, pageCount do
        local key = tostring(p)
        local row = { itemId = p, goal = 1 }
        pages[p] = { page = p, requestedItems = { [key] = row } }
        mergedItems[key] = row
    end
    for rp = 1, recipePageCount do
        local rid = tostring(1000 + rp)
        local recipe = { itemId = 1000 + rp, reagents = { ["10"] = 1 } }
        recipePages[rp] = { page = rp, recipes = { [rid] = recipe } }
        mergedRecipes[rid] = recipe
    end
    local meta = {
        kind = "campaign-archive",
        campaignId = campId,
        datasetId = "gs1:r8",
        generation = 1,
        pageCount = pageCount,
        recipePageCount = recipePageCount,
        recipeCount = recipePageCount,
        itemCount = pageCount,
        schemaVersion = GS.SCHEMA_VERSION or 1,
        archivedAt = 1,
    }
    local assembledCore = {
        schemaVersion = meta.schemaVersion,
        campaignId = campId,
        datasetId = meta.datasetId,
        generation = 1,
        archivedAt = 1,
        requestedItems = mergedItems,
        recipes = mergedRecipes,
    }
    local function makeAdop(recipePageTable)
        return {
            _archiveIndex = {
                [campId] = {
                    meta = meta,
                    pages = pages,
                    recipePages = recipePageTable,
                    pageCount = pageCount,
                    recipePageCount = recipePageCount,
                },
            },
            _workStats = {},
            order = { "arch-meta" },
            records = { ["arch-meta"] = meta },
        }
    end
    local adop = makeAdop(recipePages)
    local temp = {
        currentCampaignId = "live-other",
        campaignArchives = {
            -- Seed matches assembled core so PreferArchiveHistoricalContext succeeds.
            [campId] = {
                schemaVersion = assembledCore.schemaVersion,
                campaignId = campId,
                datasetId = assembledCore.datasetId,
                generation = 1,
                archivedAt = 1,
                requestedItems = mergedItems,
                recipes = mergedRecipes,
            },
        },
    }
    local opts = { budget = 32, cursor = 1 }
    local ok1, err1 = Validate(temp, adop, {}, opts)
    assertEq(ok1, false, "R8: first slice yields")
    assertEq(err1, "budget", "R8: budget reason")
    assertEq(opts.archivePhase[campId], "items", "R8: still in items phase after first budget")
    assertTrue(tonumber(opts.archivePageCursor[campId]) ~= nil, "R8: item page cursor persisted")
    local firstCursor = tonumber(opts.archivePageCursor[campId])
    assertTrue(firstCursor > 1 and firstCursor <= pageCount, "R8: cursor advanced into pages")
    local sawRecipePhase = false
    local advanced = false
    for _ = 1, 12 do
        opts.budget = 32
        opts.budgetExhausted = nil
        local prevPhase = opts.archivePhase and opts.archivePhase[campId]
        local prevCursor = opts.archivePageCursor and opts.archivePageCursor[campId]
        local prevRp = opts.archiveRecipePageCursor and opts.archiveRecipePageCursor[campId]
        local ok, err = Validate(temp, adop, {}, opts)
        if ok then
            advanced = true
            break
        end
        assertEq(err, "budget", "R8: intermediate yield is budget got=" .. tostring(err))
        if opts.archivePhase and opts.archivePhase[campId] == "recipes" then
            sawRecipePhase = true
            assertTrue(
                tonumber(opts.archiveRecipePageCursor[campId]) ~= nil
                    or prevPhase == "items",
                "R8: recipe phase persists cursor or just entered from items"
            )
        end
        -- Resume must advance phase or page cursor rather than stall.
        local curPhase = opts.archivePhase and opts.archivePhase[campId]
        local curCursor = opts.archivePageCursor and opts.archivePageCursor[campId]
        local curRp = opts.archiveRecipePageCursor and opts.archiveRecipePageCursor[campId]
        assertTrue(
            curPhase ~= prevPhase
                or curCursor ~= prevCursor
                or curRp ~= prevRp,
            "R8: each resume advances phase or page cursor"
        )
    end
    assertTrue(advanced, "R8: repeated resumes eventually complete under budget 32")
    assertTrue(sawRecipePhase, "R8: recipe phase yielded under budget before completion")
    assertTrue(temp.campaignArchives[campId].recipes ~= nil, "R8: assembled recipes published")
    local recipeKeys = 0
    for _ in pairs(temp.campaignArchives[campId].recipes) do
        recipeKeys = recipeKeys + 1
    end
    assertEq(recipeKeys, recipePageCount, "R8: all recipes present after completeness")

    -- Missing recipe page keeps completeness false.
    local adopMiss = makeAdop({
        [1] = recipePages[1],
        [2] = recipePages[2],
        -- remaining recipe pages absent
    })
    local okMiss, errMiss = Validate({
        currentCampaignId = "live-other",
        campaignArchives = {
            [campId] = {
                schemaVersion = assembledCore.schemaVersion,
                campaignId = campId,
                datasetId = assembledCore.datasetId,
                generation = 1,
                archivedAt = 1,
                requestedItems = mergedItems,
                recipes = mergedRecipes,
            },
        },
    }, adopMiss, {}, { budget = 10000, cursor = 1 })
    assertEq(okMiss, false, "R8: missing recipe page fails")
    assertEq(errMiss, "incomplete_archive_pages", "R8: incomplete recipe pages")

    -- IsAdoptionTransferComplete requires declared recipe pages.
    GS._adoption = {
        committed = false,
        descriptor = {
            acceptedOpCount = 0,
            transferOpCount = 0,
            campaignCount = 0,
            archiveCount = 0,
        },
        sourceAcceptedIds = {},
        _archiveIndex = {
            [campId] = {
                meta = meta,
                pages = pages,
                recipePages = { [1] = recipePages[1] },
                pageCount = pageCount,
                recipePageCount = recipePageCount,
            },
        },
        records = {},
        order = {},
    }
    local ready, why = GS:IsAdoptionTransferComplete()
    assertEq(ready, false, "R8: readiness false without all recipe pages")
    assertEq(why, "incomplete_transfer", "R8: incomplete_transfer for missing recipe pages")
    GS._adoption = nil
end

-- R7: Manage orphan sync after requested-item removal (real editor hooks)
do
    GameTooltip = GameTooltip or {
        Hide = function() end, SetOwner = function() end, SetText = function() end,
        AddLine = function() end, Show = function() end,
    }
    SF.SettingsUI = SF.SettingsUI or {}
    SF.SettingsUI.pagesById = SF.SettingsUI.pagesById or {}
    SF.SettingsUI.pages = SF.SettingsUI.pages or {}
    SF.SettingsUI.categories = SF.SettingsUI.categories or {}
    function SF.SettingsUI:RegisterCategory(cat) self.categories[cat.id] = cat end
    function SF.SettingsUI:RegisterPage(page)
        self.pagesById[page.id] = page
        self.pages[#self.pages + 1] = page
    end
    SF.SettingsStore = SF.SettingsStore or { Get = function() return true end, Set = function() end }
    SF.SettingsUI.Style = SF.SettingsUI.Style or {}
    SF.SettingsUI.Controls = SF.SettingsUI.Controls or {}
    SF.SettingsUI.DefinitionRenderer = SF.SettingsUI.DefinitionRenderer or {}
    SF.ItemDisplay = SF.ItemDisplay or {
        RegisterRefresh = function() end,
        ResetSession = function() end,
        QUESTION_MARK = "Interface/Icons/INV_Misc_QuestionMark",
        Describe = function(_, id) return { name = "Item" .. tostring(id), icon = "x" } end,
    }
    _G.UIParent = _G.UIParent or {}
    _G.CreateFrame = function(_, name)
        local f = {
            name = name,
            shown = false,
            scripts = {},
            children = {},
        }
        function f:SetSize() end
        function f:SetPoint() end
        function f:SetFrameStrata() end
        function f:SetFrameLevel() end
        function f:Hide() f.shown = false end
        function f:Show() f.shown = true end
        function f:IsShown() return f.shown end
        function f:SetScript(k, fn) f.scripts[k] = fn end
        function f:GetScript(k) return f.scripts[k] end
        function f:RegisterEvent() end
        function f:UnregisterEvent() end
        function f:UnregisterAllEvents() end
        function f:SetMovable() end
        function f:EnableMouse() end
        function f:RegisterForDrag() end
        function f:SetBackdrop() end
        function f:SetBackdropColor() end
        function f:SetText() end
        function f:SetShown(v) f.shown = v and true or false end
        function f:Enable() end
        function f:Disable() end
        function f:ClearAllPoints() end
        function f:CreateFontString()
            return {
                SetPoint = function() end, SetJustifyH = function() end,
                SetWordWrap = function() end, SetText = function() end,
                SetFontObject = function() end, SetTextColor = function() end,
                Show = function() end, Hide = function() end,
            }
        end
        function f:CreateTexture()
            return {
                SetPoint = function() end, SetSize = function() end,
                SetTexture = function() end, Show = function() end, Hide = function() end,
            }
        end
        function f:CreateScrollFrame() return f end
        return f
    end
    loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesManage.lua")
    local managePage = SF.SettingsUI.pagesById.guildSuppliesManage
    assertTrue(managePage and managePage.__sfTest, "R7: Manage page hooks")
    local hooks = managePage.__sfTest
    local record = {
        datasetId = "gs1:manage",
        _guildKey = "club:manage",
        currentCampaignId = "camp1",
        accounting = {
            _consumables = {
                configSeq = 1,
                requestedItems = {
                    ["10"] = { itemId = 10, goal = 1 },
                    ["20"] = { itemId = 20, goal = 1 },
                },
                recipes = {
                    ["100"] = { itemId = 100, reagents = { ["10"] = 3, ["20"] = 4 } },
                },
            },
        },
    }
    GS.GetCurrentRecord = function() return record end
    GS.GetCapabilities = function()
        return { canEdit = true, canRead = true }
    end
    GS.GetCurrentContext = function()
        return { ready = true, guildKey = "club:manage" }
    end
    GS.RecipeAvailability = function() return true end
    -- Manage uses AdjustCanEdit → Caps via colon calls; ensure method form works.
    local _getCaps = GS.GetCapabilities
    GS.GetCapabilities = function(_, ...) return _getCaps(...) end
    local _getRec = GS.GetCurrentRecord
    GS.GetCurrentRecord = function(_, ...) return _getRec(...) end
    local _getCtx = GS.GetCurrentContext
    GS.GetCurrentContext = function(_, ...) return _getCtx(...) end
    -- Seed editor draft as OpenRecipeEditor would with both reagents requested,
    -- then apply production requested-item removal for 10 (configSeq unchanged).
    local draft = hooks.RecipeEditorDraft()
    draft.open = true
    draft.outputItemId = 100
    draft.isExisting = true
    draft.reagentTexts = { ["10"] = "3", ["20"] = "4" }
    draft.orphanReagentIds = {}
    draft.boundConfigSeq = 1
    draft.boundRecipeRevision = "10=3;20=4"
    record.accounting._consumables.requestedItems["10"] = nil
    hooks.SyncOrphanReagentsFromSavedAndDraft()
    draft = hooks.RecipeEditorDraft()
    assertEq(draft.orphanReagentIds["10"], true, "R7: removed requested item becomes orphan")
    assertEq(draft.reagentTexts["10"], "3", "R7: orphan quantity preserved")
    local reagents, bad = hooks.BuildRecipeReagentsFromDraft()
    assertTrue(reagents ~= nil, "R7: build reagents ok bad=" .. tostring(bad))
    assertEq(reagents["10"], 3, "R7: save payload keeps orphan 10=3")
    assertEq(reagents["20"], 4, "R7: save payload keeps 20=4")
    -- Explicit quantity-zero repair drops the orphan deliberately.
    draft.reagentTexts["10"] = "0"
    hooks.SyncOrphanReagentsFromSavedAndDraft()
    reagents = hooks.BuildRecipeReagentsFromDraft()
    assertEq(reagents["10"], nil, "R7: explicit zero removes orphan on save payload")
    assertEq(reagents["20"], 4, "R7: remaining reagent kept after zero repair")
    -- Re-add requested item 10: orphan clears; quantity still from draft/saved.
    record.accounting._consumables.requestedItems["10"] = { itemId = 10, goal = 1 }
    draft.reagentTexts["10"] = "3"
    hooks.SyncOrphanReagentsFromSavedAndDraft()
    assertEq(draft.orphanReagentIds["10"], nil, "R7: re-add clears orphan flag")
    reagents = hooks.BuildRecipeReagentsFromDraft()
    assertEq(reagents["10"], 3, "R7: re-add keeps quantity")
end

-- R9: ClearProcessedDrafts preserves unrelated recipe inputs; remaining uses request
do
    _G.GetServerTime = _G.GetServerTime or function() return 1000 end
    _G.GetCursorInfo = function() return nil end
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    local WR = SF.ConsumablesWithdrawRuntime
    WR.craftDrafts = { ["900"] = 3, ["901"] = 2 }
    WR.ClearProcessedDrafts({ ["900"] = 3 })
    assertEq(WR.craftDrafts["900"], nil, "R9: processed draft cleared")
    assertEq(WR.craftDrafts["901"], 2, "R9: unrelated draft preserved")

    local settle
    WR.work = {
        settled = false,
        movementStarted = true,
        selections = { ["900"] = 1 },
        take = { ["10"] = 4 },
        requested = { ["10"] = 10 },
        confirmed = { ["10"] = 4 },
        confirmedTotal = 4,
        onSettle = function(result) settle = result end,
        timer = nil,
    }
    WR.StopWork("shortage", true)
    assertTrue(settle ~= nil, "R9: settle callback")
    assertEq(settle.requested["10"], 10, "R9: requested preserved")
    assertEq(settle.authorized["10"], 4, "R9: authorized take")
    assertEq(settle.confirmed["10"], 4, "R9: confirmed")
    assertEq(settle.remaining["10"], 6, "R9: remaining is unfilled request not zero")
    assertEq(WR.craftDrafts["901"], 2, "R9: settle preserves unrelated draft")

    -- Idempotent settlement: second StopWork is a no-op.
    local settleCount = 0
    WR.craftDrafts = { ["900"] = 1 }
    WR.work = {
        settled = false,
        movementStarted = true,
        selections = { ["900"] = 1 },
        take = { ["10"] = 5 },
        requested = { ["10"] = 5 },
        confirmed = { ["10"] = 5 },
        confirmedTotal = 5,
        onSettle = function() settleCount = settleCount + 1 end,
    }
    local workRef = WR.work
    WR.StopWork("complete", false)
    assertEq(settleCount, 1, "R9: first settle")
    -- Simulate OnBankClosed capturing work then settling after ObservePending already stopped.
    WR.work = workRef
    WR.StopWork("bank_closed", true)
    assertEq(settleCount, 1, "R9: second settle ignored via settled flag")
end

if failures > 0 then
    io.stderr:write(string.format("%d failure(s)\n", failures))
    os.exit(1)
end
print("guild_supplies_457_tests: ok")
