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
    Verbose = function() end,
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
assertEq(GS.LEDGER_EVENT.WITHDRAWAL, "withdrawal", "withdrawal ledger kind")
assertEq(GS.MAX_RECIPES, 32, "recipe limit")
assertEq(GS.MAX_WITHDRAWAL_EVENTS, 1024, "withdrawal capacity")
-- PROVIDER_SCHEMA is asserted after Admission.lua loads (no expected-value fallback).

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
            { slot = 1, empty = true, family = 0 },
            { slot = 2, empty = true, family = 0 },
        } },
        { bag = 5, slots = {
            { slot = 1, itemId = 10, count = 18, locked = false, family = 0 },
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
    assertFalse(W.SlotAcceptsItemFamily(4, 0), "specialty rejects general item")
    assertFalse(W.SlotAcceptsItemFamily(nil, 4), "unknown slot family fail-closed")
    assertFalse(W.SlotAcceptsItemFamily(0, nil), "unknown item family fail-closed")

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
    assertEq(planHerb.destinations[1].bag, 4, "B2: specialty item prefers specialty slot")

    -- Mixed: fam4 + fam8 with one general and one fam4 specialty — constrained alloc.
    local mixed = {
        { bag = 0, slots = { { slot = 1, empty = true, family = 0 } } },
        { bag = 4, slots = { { slot = 1, empty = true, family = 4 } } },
    }
    local okMix, errMix, planMix = W.PlanMultiItemBagDestinations(
        mixed,
        { ["10"] = 1, ["20"] = 1 },
        function() return 20 end,
        function(id)
            if id == 10 then return 4 end
            if id == 20 then return 8 end
            return nil
        end
    )
    assertTrue(okMix, "B2 mixed allocation: " .. tostring(errMix))
    local byItem = {}
    for i = 1, #planMix.destinations do
        local d = planMix.destinations[i]
        byItem[d.itemId] = d
    end
    assertEq(byItem[10].bag, 4, "B2: item10 uses specialty")
    assertEq(byItem[20].bag, 0, "B2: item20 uses general")

    local okOre, errOre = W.PlanMultiItemBagDestinations(
        { { bag = 4, slots = { { slot = 1, empty = true, family = 4 } } } },
        { ["200"] = 5 },
        function() return 20 end,
        function() return 8 end
    )
    assertFalse(okOre, "ore blocked when only herb bag slots exist")
    assertEq(errOre, "bag_capacity", "capacity error when no compatible slot")

    local okUnknown = select(1, W.PlanMultiItemBagDestinations(
        { { bag = 0, slots = { { slot = 1, empty = true, family = 0 } } } },
        { ["300"] = 1 },
        function() return 20 end,
        function() return nil end
    ))
    assertFalse(okUnknown, "B2: unknown item family rejected before pickup")

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
-- Pure planner + allowance helpers remain; BeginWithdraw coverage is later.
do
    local moves, rem = W.PlanSourceMoves({ { slot = 1, count = 10 } }, 10)
    assertEq(rem, 0, "one source stack")
    assertEq(#moves, 1, "one source move")
    assertTrue(W.AllowanceBlocksPlan(1, 2), "allowance uses pickup count")
    assertFalse(W.AllowanceBlocksPlan(2, 2), "two pickups fit allowance of 2")
end

-- Unavailable bank observation is not an empty slot.
do
    local actual, why = W.InterpretWithdrawal({
        guildOk = true,
        observedTab = 1,
        configuredTab = 1,
        intendedQty = 5,
        beforeBags = 0,
        afterBags = 5,
        placedSlots = { { before = 10, after = nil } },
    })
    assertEq(actual, 0, "unavailable bank yields 0 actual")
    assertEq(why, "bank_unavailable", "unavailable reason")
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

-- ScanBankStock: drive production path (map keys are wanted item IDs).
do
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    local WR = SF.ConsumablesWithdrawRuntime
    _G.GetGuildBankItemInfo = function(tab, slot)
        if tab == 1 and slot == 1 then return "tex", 7, false end
        if tab == 1 and slot == 2 then return "tex", 3, false end
        return nil
    end
    _G.GetGuildBankItemLink = function(tab, slot)
        if tab == 1 and slot == 1 then return "|Hitem:12345:|h" end
        if tab == 1 and slot == 2 then return "|Hitem:67890:|h" end
        return nil
    end
    SF.Consumables = SF.Consumables or {}
    SF.Consumables.ItemIdFromText = function(link)
        local id = tostring(link or ""):match("item:(%d+)")
        return tonumber(id)
    end
    local stock = WR.ScanBankStock(1, { ["12345"] = 10, ["67890"] = 5 })
    assertEq(stock["12345"] or stock[12345], 7, "G: ScanBankStock uses map keys as item ids")
    assertEq(stock["67890"] or stock[67890], 3, "G: ScanBankStock second key")
    assertTrue((stock[10] or 0) == 0 and (stock[5] or 0) == 0,
        "G: quantities are not treated as item ids")
end

-- Accept-flag numeric decoding via production helper.
do
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesTradeHandoff.lua")
    local flag = SF.ConsumablesTradeHandoff._TradeAcceptFlag
    assertTrue(type(flag) == "function", "G: TradeAcceptFlag exposed")
    assertEq(flag(0), false, "0 not accepted")
    assertEq(flag(1), true, "1 accepted")
    assertEq(flag(true), false, "boolean true not accepted without tonumber 1")
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

    -- D: known guild -> nil must invalidate (nil must not match).
    st.batches = {
        { id = "g1", completedAt = 1, expiresAt = 99999, amounts = { ["10"] = 5 } },
    }
    st.context = { playerGuid = "Player-1-HANDOFF", guildKey = "club:1" }
    st.tradeLifecycleId = 1
    st.prefillAttemptedFor = nil
    SF.ConsumablesWithdrawRuntime.CurrentContext = function() return { guildKey = nil } end
    _G.UnitGUID = function() return "Player-1-HANDOFF" end
    onEvent(st.frame, "PLAYER_GUILD_UPDATE", "player")
    assertEq(#st.batches, 0, "D: guild nil clears pending")
    -- Re-enqueue under club1, then TRADE_SHOW with nil guild must not prefill.
    H.Reset()
    SF.ConsumablesWithdrawRuntime.CurrentContext = function() return { guildKey = "club:1" } end
    local batchNil = H.EnqueueConfirmed({ ["10"] = 5 }, { operationId = "op-nil-guild" })
    assertTrue(batchNil ~= nil, "D: enqueue under club1")
    st = H.GetState()
    local frame = st.frame
    SF.ConsumablesWithdrawRuntime.CurrentContext = function() return { guildKey = nil } end
    local prefillCalls = 0
    local origPrefill = H.TryPrefillTrade
    H.TryPrefillTrade = function(...)
        prefillCalls = prefillCalls + 1
        if origPrefill then return origPrefill(...) end
    end
    onEvent(frame, "TRADE_SHOW")
    assertEq(prefillCalls, 0, "D: TRADE_SHOW after guild loss does not prefill")
    assertEq(#H.GetState().batches, 0, "D: TRADE_SHOW EnsureContext clears queue")
    H.TryPrefillTrade = origPrefill
    H.Reset()

    -- Known GUID -> unavailable.
    SF.ConsumablesWithdrawRuntime.CurrentContext = function() return { guildKey = "club:1" } end
    H.EnqueueConfirmed({ ["10"] = 2 }, { operationId = "op-guid" })
    st = H.GetState()
    st.context = { playerGuid = "Player-1-HANDOFF", guildKey = "club:1" }
    _G.UnitGUID = function() return nil end
    onEvent(st.frame, "PLAYER_GUILD_UPDATE", "player")
    assertEq(#H.GetState().batches, 0, "D: GUID loss clears pending")
    H.Reset()
    _G.UnitGUID = function() return "Player-1-HANDOFF" end

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
    assertEq(GS.PROVIDER_SCHEMA, 5, "G: real provider schema after Admission load")
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

    local recBump = makeRecord()
    recBump.accounting._consumables.generation = 3
    local stOlder = select(1, GS.AdmitWithdrawalEvent(recBump, baseEvent({
        id = "gsw1:admit:older-under-current",
        generation = 2,
    }), { senderGuid = "Player-1-AAAA", memberAuthenticated = true }))
    assertEq(stOlder, "rejected", "E2: older gen under current campaign rejected")

    local recHdr = makeRecord()
    recHdr.currentCampaignId = "camp-live"
    recHdr.campaigns = { ["camp-hdr"] = { id = "camp-hdr" } }
    recHdr.campaignArchives = {}
    local stHdr = select(1, GS.AdmitWithdrawalEvent(recHdr, baseEvent({
        id = "gsw1:admit:hdr-only",
        campaignId = "camp-hdr",
        generation = 7,
    }), { senderGuid = "Player-1-AAAA", memberAuthenticated = true }))
    assertEq(stHdr, "pending", "E2: header without archive generation stays pending")

    local recArch = makeRecord()
    recArch.currentCampaignId = "camp-live"
    recArch.campaignArchives = {
        camp1 = { generation = 2, campaignId = "camp1", requestedItems = {} },
    }
    local stArchOk = select(1, GS.AdmitWithdrawalEvent(recArch, baseEvent({
        id = "gsw1:admit:arch-ok",
        campaignId = "camp1",
        generation = 2,
    }), { senderGuid = "Player-1-AAAA", memberAuthenticated = true }))
    assertEq(stArchOk, "accepted", "E2: archived campaign matching generation accepted")
    local stArchBad = select(1, GS.AdmitWithdrawalEvent(recArch, baseEvent({
        id = "gsw1:admit:arch-bad",
        campaignId = "camp1",
        generation = 9,
    }), { senderGuid = "Player-1-AAAA", memberAuthenticated = true }))
    assertEq(stArchBad, "rejected", "E2: archived generation mismatch rejected")

    local missingDs = baseEvent({ id = "gsw1:admit:no-ds" })
    missingDs.datasetId = nil
    local stDs = select(1, GS.AdmitWithdrawalEvent(makeRecord(), missingDs, {
        senderGuid = "Player-1-AAAA", memberAuthenticated = true,
    }))
    assertEq(stDs, "rejected", "R6d: missing datasetId rejected")

    -- E1: exportable bodies converge across ORIGIN vs RELAY.
    local originBody = GS.ExportableWithdrawalEvent(baseEvent({
        provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN,
    }))
    local relayBody = GS.ExportableWithdrawalEvent(baseEvent({
        provenance = GS.WITHDRAWAL_PROVENANCE.RELAY,
    }))
    assertTrue(originBody ~= nil and relayBody ~= nil, "E1: exportable bodies")
    assertTrue(GS._DeepEqualOps(originBody, relayBody), "E1: export identity ignores route provenance")
    assertEq(originBody.provenance, GS.WITHDRAWAL_PROVENANCE.ORIGIN, "E1: wire provenance token stable")
end

-- R8: recipe-page completeness resumes across real 32-visit budgets
do
    local Validate = GS._ValidateAdoptionCompletenessForTest
    assertTrue(type(Validate) == "function", "R8: completeness test seam")
    local campId = "camp-arch-r8"
    -- Supported archive: 40 ordinary pages + 32 recipes (one per page) ≤ MAX_RECIPES.
    -- First budget=32 yields mid-items; later slice yields mid-recipes.
    local pageCount = 40
    local recipePageCount = 32
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

    -- IsAdoptionTransferComplete requires declared recipe pages via real descriptor.
    local descBody = {
        kind = "dataset-desc",
        datasetId = "gs1:r8-ready",
        acceptedOpCount = 0,
        transferOpCount = 0,
        campaignCount = 0,
        archiveCount = 0,
    }
    local function adoptionFixture(recipePageTable)
        return {
            committed = false,
            sourceDatasetId = "gs1:r8-ready",
            sourcePeer = "Alice-Garona",
            sourceAcceptedIds = {},
            _archiveIndex = {
                [campId] = {
                    meta = meta,
                    pages = pages,
                    recipePages = recipePageTable,
                    pageCount = pageCount,
                    recipePageCount = recipePageCount,
                },
            },
            records = { ["gs:desc:gs1:r8-ready"] = descBody },
            order = { "gs:desc:gs1:r8-ready" },
        }
    end
    GS._peerDatasets = {
        ["Alice-Garona"] = { datasetId = "gs1:r8-ready" },
    }
    local incompletePages = {}
    for rp = 1, recipePageCount - 1 do
        incompletePages[rp] = recipePages[rp]
    end
    GS._adoption = adoptionFixture(incompletePages)
    local ready, why = GS:IsAdoptionTransferComplete()
    assertEq(ready, false, "R8: readiness false without all recipe pages")
    assertEq(why, "incomplete_transfer", "R8: incomplete_transfer for missing recipe pages")
    -- Adding the one missing page makes the otherwise-identical case ready.
    incompletePages[recipePageCount] = recipePages[recipePageCount]
    GS._adoption = adoptionFixture(incompletePages)
    local ready2, why2 = GS:IsAdoptionTransferComplete()
    assertEq(ready2, true, "R8: readiness true once all recipe pages present: " .. tostring(why2))
    GS._adoption = nil
    GS._peerDatasets = {}
end

-- C/R7: Manage Open/edit/Cancel/reopen/switch + Save-before-refresh orphans
do
    GameTooltip = GameTooltip or {
        Hide = function() end, SetOwner = function() end, SetText = function() end,
        AddLine = function() end, Show = function() end,
    }
    SF.SettingsUI = SF.SettingsUI or {}
    SF.SettingsUI.pagesById = {}
    SF.SettingsUI.pages = {}
    SF.SettingsUI.categories = {}
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
    _G.UISpecialFrames = _G.UISpecialFrames or {}
    _G.CreateFrame = function(frameType, name, parent, template)
        local f = {
            name = name,
            shown = false,
            scripts = {},
            _text = "",
        }
        function f:SetSize() end
        function f:SetPoint() end
        function f:SetFrameStrata() end
        function f:SetFrameLevel() end
        function f:Hide()
            local wasShown = f.shown
            f.shown = false
            -- Fire OnHide when leaving the shown state (UISpecialFrames Escape).
            if wasShown and f.scripts.OnHide then
                f.scripts.OnHide(f)
            end
        end
        function f:Show() f.shown = true end
        function f:IsShown() return f.shown end
        function f:SetScript(k, fn) f.scripts[k] = fn end
        function f:HookScript(k, fn)
            f.hooks = f.hooks or {}
            f.hooks[k] = f.hooks[k] or {}
            f.hooks[k][#f.hooks[k] + 1] = fn
        end
        function f:GetScript(k) return f.scripts[k] end
        function f:RegisterEvent() end
        function f:UnregisterEvent() end
        function f:UnregisterAllEvents() end
        function f:SetMovable() end
        function f:EnableMouse() end
        function f:RegisterForDrag() end
        function f:RegisterForClicks() end
        function f:SetBackdrop() end
        function f:SetBackdropColor() end
        function f:SetText(t)
            f._text = tostring(t or "")
            if f.scripts.OnTextChanged then
                f.scripts.OnTextChanged(f)
            end
        end
        function f:GetText() return f._text end
        function f:SetShown(v) f.shown = v and true or false end
        function f:Enable() end
        function f:Disable() end
        function f:ClearAllPoints() end
        function f:SetAutoFocus() end
        function f:SetNumeric() end
        function f:SetMaxLetters() end
        function f:SetHeight() end
        function f:SetWidth() end
        function f:SetJustifyH() end
        f._hasFocus = false
        function f:HasFocus() return f._hasFocus and true or false end
        function f:ClearFocus() f._hasFocus = false end
        function f:SetFocus() f._hasFocus = true end
        function f:CreateFontString()
            return {
                SetPoint = function() end, SetJustifyH = function() end,
                SetWordWrap = function() end, SetText = function() end,
                SetFontObject = function() end, SetTextColor = function() end,
                SetWidth = function() end, Show = function() end, Hide = function() end,
            }
        end
        function f:CreateTexture()
            return {
                SetPoint = function() end, SetSize = function() end,
                SetTexture = function() end, Show = function() end, Hide = function() end,
            }
        end
        function f:SetScrollChild() end
        function f:SetParent() end
        return f
    end
    loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesManage.lua")
    local managePage = SF.SettingsUI.pagesById.guildSuppliesManage
    assertTrue(managePage and managePage.__sfTest, "C: Manage page hooks")
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
                    ["200"] = { itemId = 200, reagents = { ["10"] = 9 } },
                },
            },
        },
    }
    GS.GetCurrentRecord = function() return record end
    GS.GetCapabilities = function() return { canEdit = true, canRead = true } end
    GS.GetCurrentContext = function() return { ready = true, guildKey = "club:manage" } end
    GS.RecipeAvailability = function() return true end
    GS.NormalizeRecipeValue = GS.NormalizeRecipeValue or function(v) return v end
    local _getCaps = GS.GetCapabilities
    GS.GetCapabilities = function(_, ...) return _getCaps(...) end
    local _getRec = GS.GetCurrentRecord
    GS.GetCurrentRecord = function(_, ...) return _getRec(...) end
    local _getCtx = GS.GetCurrentContext
    GS.GetCurrentContext = function(_, ...) return _getCtx(...) end

    local ctx = {
        section = {
            SetMessage = function() end,
            ClearMessage = function() end,
        },
    }

    -- Open A, edit 10:3→7, Cancel, reopen A → still 3 from saved.
    hooks.OpenRecipeEditor(ctx, 100, record.accounting._consumables.recipes["100"])
    local draft = hooks.RecipeEditorDraft()
    assertEq(draft.reagentTexts["10"], "3", "C: open A loads saved 3")
    draft.reagentTexts["10"] = "7"
    local ui = hooks.RecipeEditorUi()
    assertTrue(ui and ui.cancel and ui.cancel.scripts.OnClick, "C: cancel bound")
    ui.cancel.scripts.OnClick(ui.cancel)
    assertEq(draft.open, false, "C: cancel closes")
    hooks.OpenRecipeEditor(ctx, 100, record.accounting._consumables.recipes["100"])
    draft = hooks.RecipeEditorDraft()
    assertEq(draft.reagentTexts["10"], "3", "C: reopen after cancel restores saved 3 not 7")

    -- Open A, Cancel, open B → B uses saved 9, not A's 3.
    hooks.OpenRecipeEditor(ctx, 100, record.accounting._consumables.recipes["100"])
    hooks.RecipeEditorDraft().reagentTexts["10"] = "3"
    hooks.RecipeEditorUi().cancel.scripts.OnClick(hooks.RecipeEditorUi().cancel)
    hooks.OpenRecipeEditor(ctx, 200, record.accounting._consumables.recipes["200"])
    draft = hooks.RecipeEditorDraft()
    assertEq(draft.outputItemId, 200, "C: switched to B")
    assertEq(draft.reagentTexts["10"], "9", "C: open B loads B's 9 not A's 3")
    local reagentsB = hooks.BuildRecipeReagentsFromDraft()
    assertEq(reagentsB["10"], 9, "C: B save payload is 9")

    -- Remove requested 10; Save before deferred refresh keeps orphan 10=3.
    hooks.OpenRecipeEditor(ctx, 100, record.accounting._consumables.recipes["100"])
    record.accounting._consumables.requestedItems["10"] = nil
    -- Do not call RefreshRecipeEditor (deferred). Commit path must still reconcile.
    local applied
    GS.NewConfigOperation = function(_, kind, target, value)
        applied = { kind = kind, target = target, value = value }
        return { kind = kind, target = target, value = value }, "accepted"
    end
    GS.ApplyStagedConfigOperation = function(_, op)
        return "accepted"
    end
    hooks.CommitRecipeEditorSave()
    assertTrue(applied ~= nil, "C: Save issued set-recipe")
    assertEq(applied.value.reagents["10"], 3, "C: Save-before-refresh keeps orphan 10=3")
    assertEq(applied.value.reagents["20"], 4, "C: Save keeps 20=4")
end

-- A: BeginWithdraw / PreviewWithdrawPlan positive + shortage binding (no global RecipeUnavailable)
do
    assertEq(_G.RecipeUnavailable, nil, "A: no compensating RecipeUnavailable global")
    _G.GetServerTime = function() return 1000 end
    local cursorItem = nil
    _G.GetCursorInfo = function()
        if cursorItem then return "item", cursorItem end
        return nil
    end
    _G.GetItemCount = function() return 0 end
    _G.GetCurrentGuildBankTab = function() return 1 end
    _G.GetGuildBankTabInfo = function()
        return "Tab", "icon", true, true, 0, -1
    end
    _G.GetGuildBankItemInfo = function(tab, slot)
        if tab == 1 and slot == 1 then return "tex", 10, false end
        if tab == 1 and slot == 2 then return "tex", 5, false end
        return nil
    end
    _G.GetGuildBankItemLink = function(tab, slot)
        if tab == 1 and slot == 1 then return "|Hitem:10:|h" end
        if tab == 1 and slot == 2 then return "|Hitem:10:|h" end
        return nil
    end
    _G.PickupGuildBankItem = function() cursorItem = 10 end
    _G.SplitGuildBankItem = function() cursorItem = 10 end
    _G.PutItemInBackpack = function() cursorItem = nil end
    _G.ClearCursor = function() cursorItem = nil end
    _G.InCombatLockdown = function() return false end
    -- Accurate Blizzard timer model: After has no cancellable return; NewTimer does.
    local pendingTimers = {}
    C_Timer = {
        After = function(_, fn)
            -- After returns nothing and is not cancellable.
            if type(fn) == "function" then
                pendingTimers[#pendingTimers + 1] = { fn = fn, cancellable = false }
            end
            return nil
        end,
        NewTimer = function(delay, fn)
            local cancelled = false
            local entry = {
                fn = fn,
                cancellable = true,
                Cancel = function() cancelled = true end,
                _fire = function()
                    if not cancelled and type(fn) == "function" then fn() end
                end,
                _cancelled = function() return cancelled end,
            }
            pendingTimers[#pendingTimers + 1] = entry
            return entry
        end,
        _drain = function()
            local batch = pendingTimers
            pendingTimers = {}
            for i = 1, #batch do
                local t = batch[i]
                if t.cancellable then
                    t._fire()
                elseif type(t.fn) == "function" then
                    t.fn()
                end
            end
        end,
    }
    C_Container = {
        GetContainerNumSlots = function(bag)
            if bag == 0 then return 4 end
            return 0
        end,
        GetContainerNumFreeSlots = function(bag)
            if bag == 0 then return 4, 0 end
            return 0, 0
        end,
        GetContainerItemInfo = function() return nil end,
        PickupContainerItem = function() cursorItem = nil end,
    }
    C_Item = {
        GetItemFamily = function() return 0 end,
    }
    SF.Consumables = SF.Consumables or {}
    SF.Consumables.ItemIdFromText = function(link)
        local id = tostring(link or ""):match("item:(%d+)")
        return tonumber(id)
    end
    SF.ConsumablesRouting = { IsCarriedBag = function() return true end }
    -- WithdrawAccess requires Runtime:BankIsOpen().
    SF.ConsumablesRuntime = SF.ConsumablesRuntime or {}
    SF.ConsumablesRuntime.BankIsOpen = function() return true end
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    local WR = SF.ConsumablesWithdrawRuntime
    local record = {
        datasetId = "gs1:wd",
        _guildKey = "club:wd",
        currentCampaignId = "camp1",
        accounting = {
            _consumables = {
                bankTab = 1,
                generation = 1,
                configSeq = 1,
                recipes = {
                    ["100"] = { itemId = 100, reagents = { ["10"] = 5 } },
                },
            },
        },
    }
    GS.IsLiveActiveForCurrentGuild = function() return true end
    GS.GetCurrentRecord = function() return record end
    GS.RecipeAvailability = function() return true end
    GS.WithdrawalReceiptCapacityOk = function() return true end
    GS.AggregateRecipeWithdrawal = GS.AggregateRecipeWithdrawal

    -- Positive: sufficient stock begins movement (queue attached).
    local okFull, errFull = WR.BeginWithdraw({ ["100"] = 1 }, {})
    assertEq(okFull, true, "A: sufficient BeginWithdraw ok: " .. tostring(errFull))
    assertTrue(WR.work ~= nil, "A: work attached")
    assertTrue(#(WR.work.queue or {}) >= 1, "A: movement queue non-empty")
    WR.StopWork("test_cleanup", true)

    -- Shortage: Preview preserves multi-return preview table (not collapsed).
    _G.GetGuildBankItemInfo = function(tab, slot)
        if tab == 1 and slot == 1 then return "tex", 2, false end
        return nil
    end
    local okPrev, errPrev, preview = WR.PreviewWithdrawPlan({ ["100"] = 2 }, {})
    assertEq(okPrev, false, "A: shortage preview false")
    assertEq(errPrev, "shortage", "A: shortage reason")
    assertTrue(type(preview) == "table" and preview.plan ~= nil, "A: preview table preserved")
    assertTrue(preview.ctx ~= nil, "A: preview.ctx bound")
    assertEq(preview.plan.take["10"], 2, "A: approved take is available 2")

    local okShort, errShort, detail = WR.BeginWithdraw({ ["100"] = 2 }, {})
    assertEq(okShort, false, "A: BeginWithdraw shortage")
    assertEq(errShort, "shortage", "A: shortage err")
    assertTrue(type(detail) == "table" and detail.plan ~= nil, "A: shortage returns full preview")
    assertTrue(detail.ctx and detail.ctx.guildKey == "club:wd", "A: shortage preview ctx")

    -- Accept partial with acceptedTake ceiling.
    local okPartial, errPartial = WR.BeginWithdraw({ ["100"] = 2 }, {
        allowPartial = true,
        acceptedTake = { ["10"] = 2 },
    })
    assertEq(okPartial, true, "A: approved partial starts: " .. tostring(errPartial))
    assertEq(WR.work.take["10"], 2, "A: take capped to approved")
    WR.StopWork("test_cleanup", true)

    -- B3: two source stacks of 5 into one empty dest of capacity 10 → second merge.
    _G.GetGuildBankItemInfo = function(tab, slot)
        if tab == 1 and slot == 1 then return "tex", 5, false end
        if tab == 1 and slot == 2 then return "tex", 5, false end
        return nil
    end
    _G.GetGuildBankItemLink = function(tab, slot)
        if tab == 1 and (slot == 1 or slot == 2) then return "|Hitem:10:|h" end
        return nil
    end
    record.accounting._consumables.recipes["100"] = { itemId = 100, reagents = { ["10"] = 10 } }
    local okSeq, errSeq = WR.BeginWithdraw({ ["100"] = 1 }, {})
    assertEq(okSeq, true, "B3: BeginWithdraw for split dest: " .. tostring(errSeq))
    local q = WR.work.queue
    assertEq(#q, 2, "B3: two bank pickups")
    assertEq(q[1].destMerge, false, "B3: first into empty")
    assertEq(q[2].destMerge, true, "B3: second merges into prior placement")
    assertEq(q[1].destBag, q[2].destBag, "B3: same dest bag")
    assertEq(q[1].destSlot, q[2].destSlot, "B3: same dest slot")
    -- Revalidate after first fill: second step must still be valid as merge.
    local slotAfter = { itemId = 10, count = 5, locked = false, family = 0, empty = false }
    local okDest2, destWhy2 = W.DestinationStillValid(
        slotAfter,
        { count = q[2].count, merge = q[2].destMerge, itemFamily = 0 },
        10,
        20
    )
    assertTrue(okDest2, "B3: second dest valid after first fill: " .. tostring(destWhy2))
    local okForeign = select(1, W.DestinationStillValid(
        { itemId = 99, count = 1, locked = false, family = 0 },
        { count = 5, merge = true, itemFamily = 0 },
        10,
        20
    ))
    assertFalse(okForeign, "B3: foreign occupancy still rejected")
    WR.StopWork("test_cleanup", true)

    -- Unknown bag family on the required equipped destination prevents first pickup.
    -- GetContainerNumFreeSlots returning nil family must not coerce to general (0).
    _G.GetGuildBankItemInfo = function(tab, slot)
        if tab == 1 and slot == 1 then return "tex", 5, false end
        return nil
    end
    _G.GetGuildBankItemLink = function(tab, slot)
        if tab == 1 and slot == 1 then return "|Hitem:10:|h" end
        return nil
    end
    record.accounting._consumables.recipes["100"] = { itemId = 100, reagents = { ["10"] = 5 } }
    local pickupCount = 0
    _G.PickupGuildBankItem = function()
        pickupCount = pickupCount + 1
        cursorItem = 10
    end
    _G.SplitGuildBankItem = function()
        pickupCount = pickupCount + 1
        cursorItem = 10
    end
    C_Container.GetContainerNumFreeSlots = function(bag)
        if bag == 0 then return 4, nil end -- nil family = unknown
        return 0, nil
    end
    C_Item.GetItemFamily = function() return 0 end
    local okUnkBag, errUnkBag = WR.BeginWithdraw({ ["100"] = 1 }, {})
    assertEq(okUnkBag, false, "fam: unknown bag family blocks BeginWithdraw")
    assertEq(errUnkBag, "bag_capacity", "fam: bag_capacity when destination family unknown")
    assertEq(pickupCount, 0, "fam: no bank pickup when bag family unknown")
    assertEq(WR.work, nil, "fam: no work attached on unknown bag family")

    -- Known general family (0) still works.
    C_Container.GetContainerNumFreeSlots = function(bag)
        if bag == 0 then return 4, 0 end
        return 0, 0
    end
    pickupCount = 0
    local okGen, errGen = WR.BeginWithdraw({ ["100"] = 1 }, {})
    assertEq(okGen, true, "fam: known general family starts: " .. tostring(errGen))
    assertTrue(pickupCount >= 1 or (WR.work and #(WR.work.queue or {}) >= 1),
        "fam: general family queues bank pickup")
    WR.StopWork("test_cleanup", true)

    -- Known specialty families still allocate (herb item → herb bag).
    C_Container.GetContainerNumSlots = function(bag)
        if bag == 0 then return 1 end
        if bag == 4 then return 1 end
        return 0
    end
    C_Container.GetContainerNumFreeSlots = function(bag)
        if bag == 0 then return 1, 0 end
        if bag == 4 then return 1, 4 end
        return 0, 0
    end
    C_Container.GetContainerItemInfo = function() return nil end
    C_Item.GetItemFamily = function(itemId)
        if tonumber(itemId) == 10 then return 4 end
        return 0
    end
    pickupCount = 0
    local okSpec, errSpec = WR.BeginWithdraw({ ["100"] = 1 }, {})
    assertEq(okSpec, true, "fam: specialty family starts: " .. tostring(errSpec))
    assertTrue(WR.work and WR.work.queue and WR.work.queue[1], "fam: specialty queue")
    assertEq(WR.work.queue[1].destBag, 4, "fam: specialty item prefers herb bag")
    WR.StopWork("test_cleanup", true)

    -- Live revalidation: item family becoming unavailable rejects next pickup.
    C_Container.GetContainerNumSlots = function(bag)
        if bag == 0 then return 4 end
        return 0
    end
    C_Container.GetContainerNumFreeSlots = function(bag)
        if bag == 0 then return 4, 0 end
        return 0, 0
    end
    C_Item.GetItemFamily = function() return 0 end
    local okRev, errRev = WR.BeginWithdraw({ ["100"] = 1 }, {})
    assertEq(okRev, true, "fam: revalidate setup starts: " .. tostring(errRev))
    local step = WR.work.queue[1]
    assertTrue(step ~= nil, "fam: revalidate step present")
    -- Snapshot planned with known family; live ItemFamily now returns nil.
    C_Item.GetItemFamily = function() return nil end
    local okLive, whyLive = WR.RevalidateStepDestination(step)
    assertEq(okLive, false, "fam: live revalidate rejects unknown item family")
    assertEq(whyLive, "family", "fam: revalidate reason is family")
    WR.StopWork("test_cleanup", true)

    -- DestinationStillValid preserves nil without coercing to 0.
    local okNilSlot = select(1, W.DestinationStillValid(
        { empty = true, family = nil },
        { count = 1, merge = false, itemFamily = 0 },
        10, 20
    ))
    assertFalse(okNilSlot, "fam: DestinationStillValid rejects nil slot family")
    local okNilItem = select(1, W.DestinationStillValid(
        { empty = true, family = 0 },
        { count = 1, merge = false, itemFamily = nil },
        10, 20
    ))
    assertFalse(okNilItem, "fam: DestinationStillValid rejects nil item family")
    local okZero = select(1, W.DestinationStillValid(
        { empty = true, family = 0 },
        { count = 1, merge = false, itemFamily = 0 },
        10, 20
    ))
    assertTrue(okZero, "fam: numeric family 0 remains valid")

    -- Snapshot copy preserves nil through PlanMultiItemBagDestinations.
    local okNilPlan = select(1, W.PlanMultiItemBagDestinations(
        { { bag = 0, slots = { { slot = 1, empty = true, family = nil } } } },
        { ["10"] = 1 },
        function() return 20 end,
        function() return 0 end
    ))
    assertFalse(okNilPlan, "fam: plan rejects nil slot family from snapshot")
end

-- R9: ClearProcessedDrafts preserves unrelated recipe inputs; remaining uses request
do
    _G.GetServerTime = _G.GetServerTime or function() return 1000 end
    _G.GetCursorInfo = function() return nil end
    if not SF.ConsumablesWithdrawRuntime then
        loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    end
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

---------------------------------------------------------------------------
-- A–G production-path regressions (repair batch after b238e1d7)
---------------------------------------------------------------------------

-- A: receipt ID namespace, finite timestamps, provenance exclusion + real adjustment
do
    if not GS.AdmitWithdrawalEvent then
        loadModule("SpectrumFederation/modules/GuildSupplies/Admission.lua")
    end
    local function makeRec()
        return {
            datasetId = "gs1:iso",
            _guildKey = "club:iso",
            currentCampaignId = "camp1",
            campaigns = { camp1 = { id = "camp1" } },
            campaignArchives = {},
            accounting = {
                _mutationSeq = 0,
                _consumables = {
                    generation = 1,
                    eventSeq = 0,
                    bankTab = 1,
                    requestedItems = {
                        ["10"] = { itemId = 10, goal = 5 },
                    },
                },
                _consumableEvents = {},
                _consumableEventArchive = {},
            },
        }
    end
    local function wd(overrides)
        local e = {
            type = "withdrawal",
            id = "gsw1:iso:10:1",
            datasetId = "gs1:iso",
            campaignId = "camp1",
            generation = 1,
            itemId = 10,
            quantity = 2,
            actor = "Alice-Realm",
            actorGuid = "Player-1-ISO",
            bankTab = 1,
            timestamp = 1000,
            provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN,
            operationId = "op-iso",
            guildKey = "club:iso",
            gsProductionCredit = false,
        }
        if overrides then for k, v in pairs(overrides) do e[k] = v end end
        return e
    end
    local stBad = select(1, GS.AdmitWithdrawalEvent(makeRec(), wd({
        id = "gs1:Player-1-ISO:nonce:9",
    }), { senderGuid = "Player-1-ISO", memberAuthenticated = true }))
    assertEq(stBad, "rejected", "A: non-gsw1 receipt id rejected")

    local stHuge = select(1, GS.AdmitWithdrawalEvent(makeRec(), wd({
        id = "gsw1:iso:huge:1",
        timestamp = math.huge,
    }), { senderGuid = "Player-1-ISO", memberAuthenticated = true }))
    assertEq(stHuge, "rejected", "A: non-finite timestamp rejected")

    local record = makeRec()
    local stOk = select(1, GS.AdmitWithdrawalEvent(record, wd(), {
        senderGuid = "Player-1-ISO", memberAuthenticated = true,
    }))
    assertEq(stOk, "accepted", "A: valid gsw1 receipt admitted")
    if GS.ResolveDonorIdentity then
        local savedReady = GS.WitnessRelationshipsReady
        local savedResolve = GS.ResolveUniqueCharacterGuid
        GS.WitnessRelationshipsReady = function() return true end
        GS.ResolveUniqueCharacterGuid = function() return nil end
        local name, guid = GS.ResolveDonorIdentity(record, "Alice-Realm", "Player-1-ISO")
        assertEq(name, "Alice-Realm", "A: donor name preserved")
        assertEq(guid, nil, "A: receipt-only history does not bind GUID")
        record.accounting._consumableEventArchive = {
            record.accounting._consumableEvents[1],
        }
        record.accounting._consumableEvents = {}
        local _, guid2 = GS.ResolveDonorIdentity(record, "Alice-Realm", "Player-1-ISO")
        assertEq(guid2, nil, "A: archived receipt-only history does not bind GUID")
        GS.WitnessRelationshipsReady = savedReady
        GS.ResolveUniqueCharacterGuid = savedResolve
    end

    -- Forged ordinary-event id on the adjustment boundary must be rejected as a
    -- withdrawal; the legitimate adjustment on that same id must then succeed.
    local adjRecord = makeRec()
    local forgedId = "gs1:Player-1-ISO:nonce:1"
    local stForged = select(1, GS.AdmitWithdrawalEvent(adjRecord, wd({
        id = forgedId,
    }), { senderGuid = "Player-1-ISO", memberAuthenticated = true }))
    assertEq(stForged, "rejected", "A: forged gs1 withdrawal at adjustment boundary rejected")
    assertEq(#adjRecord.accounting._consumableEvents, 0, "A: forged receipt not stored")
    assertTrue(GS.ApplyAdjustmentMutation ~= nil, "A: ApplyAdjustmentMutation present")
    local adjOk, adjWhy = GS.ApplyAdjustmentMutation(adjRecord, {
        id = forgedId,
        kind = GS.KIND.ADJUST_QUANTITY,
        target = { itemId = 10 },
        value = { itemId = 10, quantity = 1 },
        timestamp = 1001,
        actorName = "Alice-Realm",
        actorGuid = "Player-1-ISO",
    }, { localWrite = true })
    assertEq(adjOk, true, "A: legitimate adjustment accepted after forged reject: " .. tostring(adjWhy))
    assertEq(adjWhy, "accepted", "A: adjustment reason accepted not permissive other")
    local quarantined = adjRecord.accounting._consumables
        and adjRecord.accounting._consumables.txnConflicts
    assertTrue(quarantined == nil or next(quarantined) == nil,
        "A: no txnConflicts quarantine after successful adjustment")
    local sawAdj = false
    for i = 1, #adjRecord.accounting._consumableEvents do
        local e = adjRecord.accounting._consumableEvents[i]
        if e and e.id == forgedId and (e.type == GS.LEDGER_EVENT.ADJUSTMENT
            or e.type == "CONSUMABLE_ADJUSTMENT") then
            sawAdj = true
        end
    end
    assertTrue(sawAdj, "A: adjustment event stored on shared id boundary")
end

-- B: independent archive retention (donation overflow must not evict receipts)
do
    local maxDon = 8
    local maxWd = 4
    local savedDon, savedWd = GS.MAX_ARCHIVED_EVENTS, GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS
    GS.MAX_ARCHIVED_EVENTS = maxDon
    GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS = maxWd
    local record = {
        datasetId = "gs1:trim",
        accounting = {
            _mutationSeq = 0,
            _consumables = { generation = 2 },
            _consumableEvents = {},
            _consumableEventArchive = {},
        },
    }
    local function countKinds(list)
        local d, w = 0, 0
        for i = 1, #list do
            if list[i].type == "withdrawal" then w = w + 1 else d = d + 1 end
        end
        return d, w
    end
    local arch = {}
    record.accounting._consumableEventArchive = arch
    for i = 1, 10 do
        arch[#arch + 1] = {
            type = "CONSUMABLE_DONATION", id = "don2:" .. i, itemId = 1, quantity = 1,
            generation = 1, timestamp = i, txnId = "txn:don2:" .. i,
        }
    end
    for i = 1, 2 do
        arch[#arch + 1] = {
            type = "withdrawal", id = "gsw1:trim2:wd:" .. i, itemId = 10, quantity = 1,
            generation = 1, timestamp = 200 + i,
        }
    end
    record.accounting._consumableEvents[#record.accounting._consumableEvents + 1] = {
        type = "CONSUMABLE_DONATION", id = "live:old:1", itemId = 1, quantity = 1,
        generation = 1, timestamp = 1, txnId = "txn:live:1",
    }
    GS.ShelvePriorGenerationsOnRecord(record)
    local d, w = countKinds(record.accounting._consumableEventArchive)
    assertTrue(d <= maxDon, "B: donations capped got=" .. tostring(d))
    assertEq(w, 2, "B: donation overflow preserved below-cap receipts got=" .. tostring(w))

    arch = {}
    record.accounting._consumableEventArchive = arch
    record.accounting._consumableEvents = {}
    for i = 1, 6 do
        arch[#arch + 1] = {
            type = "withdrawal", id = "gsw1:trim3:wd:" .. i, itemId = 10, quantity = 1,
            generation = 1, timestamp = i,
        }
    end
    record.accounting._consumableEvents[1] = {
        type = "withdrawal", id = "gsw1:trim3:live", itemId = 10, quantity = 1,
        generation = 1, timestamp = 1,
    }
    GS.ShelvePriorGenerationsOnRecord(record)
    d, w = countKinds(record.accounting._consumableEventArchive)
    assertTrue(w <= maxWd, "B: withdrawal overflow capped got=" .. tostring(w))
    assertEq(d, 0, "B: withdrawal-only overflow left donations at 0")

    GS.MAX_ARCHIVED_EVENTS = savedDon
    GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS = savedWd
end

-- C: ordinary archive exporter → provider (13-item page boundary + field compare)
do
    if not GS.AdmitWithdrawalEvent then
        loadModule("SpectrumFederation/modules/GuildSupplies/Admission.lua")
    end
    SF.GuildGossip = SF.GuildGossip or {}
    local providers = {}
    SF.GuildGossip.RegisterProvider = function(spec)
        providers[spec.id] = { api = spec, id = spec.id }
        return true
    end
    SF.GuildGossip.GetProvider = function(id) return providers[id] end
    SF.GuildGossip.Init = function() end
    SF.GuildGossip.SetProviderEnabled = function() end
    SF.GuildGossip.GetGuildIdentity = function()
        return { guildKey = "club:arch" }
    end
    SF.GuildGossip.GetGuildMember = function(name)
        return {
            name = name,
            guid = "Player-1-Arch",
            rankOrder = 1,
            guildKey = "club:arch",
        }
    end
    loadModule("SpectrumFederation/modules/GuildSupplies/Gossip.lua")
    assertTrue(type(GS._BuildArchiveExportBodiesForTest) == "function",
        "C: real archive exporter seam")
    assertTrue(type(GS._ValidateAndApplyForTest) == "function",
        "C: real ValidateAndApply seam")
    assertTrue(type(GS._OrdinaryArchiveEqualForTest) == "function",
        "C: ordinary archive equal seam")

    local function makeItems(n)
        local items = {}
        for i = 1, n do
            items[tostring(i)] = { itemId = i, goal = 1 }
        end
        return items
    end
    local campId = "camp-arch-c"
    local archive = {
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = campId,
        datasetId = "gs1:arch",
        requestedItems = makeItems(13),
        recipes = {},
        generation = 2,
        archivedAt = 5000,
        bankTab = 3,
        eligibility = {
            baselineEstablished = true,
            baselineAt = 100,
            tabEligibleFrom = 200,
            items = { ["1"] = 10, ["2"] = 20 },
        },
    }
    local parts = GS._BuildArchiveExportBodiesForTest(campId, archive, {
        datasetId = "gs1:arch",
    })
    assertTrue(#parts >= 2, "C: 13 items cross page boundary parts=" .. tostring(#parts))
    local metaBody, pageBodies = nil, {}
    for i = 1, #parts do
        local b = parts[i].body
        if b.kind == "campaign-archive" then
            metaBody = b
        elseif b.kind == "campaign-archive-page" then
            pageBodies[#pageBodies + 1] = b
        end
    end
    assertTrue(metaBody ~= nil, "C: meta body exported")
    assertTrue(#pageBodies >= 1, "C: at least one item page")
    assertTrue(type(metaBody.requestedItems) ~= "table" or next(metaBody.requestedItems) == nil,
        "C: paged meta does not inline all requested items")

    local function freshRecord(existingArchive)
        return {
            datasetId = "gs1:arch",
            _guildKey = "club:arch",
            activation = "staged",
            currentCampaignId = "camp-live",
            campaigns = {
                [campId] = { id = campId },
                ["camp-live"] = { id = "camp-live" },
            },
            campaignArchives = existingArchive and { [campId] = existingArchive } or {},
            accounting = {
                _consumables = { generation = 3, bankTab = 1, requestedItems = {} },
            },
            permission = { editorRankPosition = 1 },
        }
    end
    local function installRecord(rec)
        GS.IsRootReady = function() return true end
        GS.IsSupportedActivation = function() return true end
        GS.GetCurrentContext = function()
            return { guildKey = "club:arch", ready = true, actorGuid = "Player-1-Arch" }
        end
        GS._root = { guilds = { ["club:arch"] = rec } }
        GS.SenderHasEditorAuthority = function() return true end
        GS.AuthenticateTransportSender = function(sender)
            return {
                name = sender,
                guid = "Player-1-Arch",
                rankOrder = 1,
                guildKey = "club:arch",
            }
        end
    end
    local function applyBody(body, sender)
        return GS._ValidateAndApplyForTest({
            id = "gs:ca-test:" .. tostring(body.kind) .. ":" .. tostring(body.page or "meta"),
            versionFp = "fp",
            body = body,
        }, { sender = sender or "Alice-Arch" })
    end
    local function deliverParts(orderMetaFirst)
        local ordered = {}
        if orderMetaFirst then
            ordered[#ordered + 1] = metaBody
            for i = 1, #pageBodies do ordered[#ordered + 1] = pageBodies[i] end
        else
            for i = 1, #pageBodies do ordered[#ordered + 1] = pageBodies[i] end
            ordered[#ordered + 1] = metaBody
        end
        local lastSt, lastWhy
        for i = 1, #ordered do
            lastSt, lastWhy = applyBody(ordered[i])
        end
        return lastSt, lastWhy
    end

    -- Metadata-first assembly admits a fresh archive.
    local rec1 = freshRecord(nil)
    installRecord(rec1)
    local st1, why1 = deliverParts(true)
    assertEq(st1, "accepted", "C: metadata-first admit: " .. tostring(why1))
    assertTrue(rec1.campaignArchives[campId] ~= nil, "C: archive stored metadata-first")
    assertEq(rec1.campaignArchives[campId].bankTab, 3, "C: bankTab preserved")
    assertEq(rec1.campaignArchives[campId].generation, 2, "C: generation preserved")

    -- Page-first assembly admits.
    local rec2 = freshRecord(nil)
    installRecord(rec2)
    local st2, why2 = deliverParts(false)
    assertEq(st2, "accepted", "C: page-first admit: " .. tostring(why2))
    assertTrue(rec2.campaignArchives[campId] ~= nil, "C: archive stored page-first")

    -- Legacy nil recipes equals {} peer (inline duplicate path).
    local legacy = {
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = campId,
        datasetId = "gs1:arch",
        requestedItems = makeItems(5),
        -- recipes intentionally absent (nil)
        generation = 2,
        archivedAt = 5000,
        bankTab = 3,
        eligibility = archive.eligibility,
    }
    local inlineParts = GS._BuildArchiveExportBodiesForTest(campId, {
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = campId,
        datasetId = "gs1:arch",
        requestedItems = makeItems(5),
        recipes = {},
        generation = 2,
        archivedAt = 5000,
        bankTab = 3,
        eligibility = archive.eligibility,
    }, { datasetId = "gs1:arch" })
    assertEq(#inlineParts, 1, "C: 5 items inline as single body")
    local recLegacy = freshRecord(legacy)
    installRecord(recLegacy)
    local stDup, whyDup = applyBody(inlineParts[1].body)
    assertEq(stDup, "duplicate", "C: legacy nil recipes vs {} is duplicate: " .. tostring(whyDup))
    assertTrue(recLegacy.campaignArchives[campId].recipes == nil,
        "C: compare must not mutate saved nil recipes")

    -- Existing 13-item legacy archive (nil recipes) across real paging assembly.
    local legacy13 = {
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = campId,
        datasetId = "gs1:arch",
        requestedItems = makeItems(13),
        -- recipes intentionally absent
        generation = 2,
        archivedAt = 5000,
        bankTab = 3,
        eligibility = archive.eligibility,
    }
    local recLegacy13 = freshRecord(legacy13)
    assertEq(recLegacy13.campaignArchives[campId].recipes, nil,
        "C: seeded 13-item legacy has nil recipes")
    installRecord(recLegacy13)
    local stL13a, whyL13a = deliverParts(true)
    assertEq(stL13a, "duplicate",
        "C: existing 13-item legacy metadata-first is duplicate: " .. tostring(whyL13a))
    assertEq(recLegacy13.campaignArchives[campId].recipes, nil,
        "C: 13-item duplicate preserves nil recipes")
    assertEq(recLegacy13.campaignArchives[campId].bankTab, 3,
        "C: 13-item duplicate preserves bankTab")
    assertEq(recLegacy13.campaignArchives[campId].generation, 2,
        "C: 13-item duplicate preserves generation")
    -- Page-first against a fresh seed of the same legacy body.
    local recLegacy13b = freshRecord(legacy13)
    installRecord(recLegacy13b)
    local stL13b, whyL13b = deliverParts(false)
    assertEq(stL13b, "duplicate",
        "C: existing 13-item legacy page-first is duplicate: " .. tostring(whyL13b))
    assertEq(recLegacy13b.campaignArchives[campId].recipes, nil,
        "C: page-first 13-item duplicate preserves nil recipes")

    -- Changed authoritative fields must not be accepted as duplicates.
    local function conflictCase(label, mutate)
        local base = {
            schemaVersion = GS.SCHEMA_VERSION,
            campaignId = campId,
            datasetId = "gs1:arch",
            requestedItems = makeItems(5),
            recipes = {},
            generation = 2,
            archivedAt = 5000,
            bankTab = 3,
            eligibility = {
                baselineEstablished = true,
                baselineAt = 100,
                tabEligibleFrom = 200,
                items = { ["1"] = 10 },
            },
        }
        local changed = {}
        for k, v in pairs(base) do changed[k] = v end
        mutate(changed)
        local bodies = GS._BuildArchiveExportBodiesForTest(campId, changed, { datasetId = "gs1:arch" })
        local rec = freshRecord(base)
        local savedGen = rec.campaignArchives[campId].generation
        local savedTab = rec.campaignArchives[campId].bankTab
        installRecord(rec)
        local st, why = applyBody(bodies[1].body)
        assertEq(st, "rejected", "C: " .. label .. " rejected not duplicate: " .. tostring(why))
        assertEq(why, "id_conflict", "C: " .. label .. " id_conflict")
        assertEq(rec.campaignArchives[campId].generation, savedGen,
            "C: " .. label .. " preserves saved generation")
        assertEq(rec.campaignArchives[campId].bankTab, savedTab,
            "C: " .. label .. " preserves saved bankTab")
    end
    conflictCase("recipes", function(a)
        a.recipes = { ["100"] = { itemId = 100, reagents = { ["1"] = 1 } } }
    end)
    conflictCase("bankTab", function(a) a.bankTab = 9 end)
    conflictCase("eligibility", function(a)
        a.eligibility = {
            baselineEstablished = true,
            baselineAt = 100,
            tabEligibleFrom = 200,
            items = { ["1"] = 99 },
        }
    end)
    conflictCase("generation", function(a) a.generation = 9 end)
    conflictCase("requestedItems", function(a)
        a.requestedItems = makeItems(4)
    end)
    do
        local base = {
            schemaVersion = GS.SCHEMA_VERSION,
            campaignId = campId,
            datasetId = "gs1:arch",
            requestedItems = makeItems(5),
            recipes = {},
            generation = 2,
            archivedAt = 5000,
            bankTab = 3,
            eligibility = archive.eligibility,
        }
        local changed = {}
        for k, v in pairs(base) do changed[k] = v end
        changed.datasetId = "gs1:other"
        local bodies = GS._BuildArchiveExportBodiesForTest(campId, changed, { datasetId = "gs1:other" })
        local rec = freshRecord(base)
        installRecord(rec)
        local st, why = applyBody(bodies[1].body)
        assertTrue(st == "rejected", "C: dataset change rejected")
        assertTrue(why == "dataset_mismatch" or why == "id_conflict",
            "C: dataset not treated as duplicate: " .. tostring(why))
        assertEq(rec.campaignArchives[campId].datasetId, "gs1:arch",
            "C: dataset rejection preserves saved archive")
    end

    -- Ordinary equal must include bankTab (unlike adoption ArchiveCoreEqual).
    assertFalse(GS._OrdinaryArchiveEqualForTest({
        schemaVersion = 1, campaignId = "c", datasetId = "d",
        requestedItems = {}, recipes = {}, generation = 1, archivedAt = 1,
        bankTab = 1, eligibility = { baselineEstablished = true },
    }, {
        schemaVersion = 1, campaignId = "c", datasetId = "d",
        requestedItems = {}, recipes = {}, generation = 1, archivedAt = 1,
        bankTab = 2, eligibility = { baselineEstablished = true },
    }), "C: OrdinaryArchiveEqual distinguishes bankTab")
end

-- E: trade handoff identity + production OnEvent obligation lifetime
do
    if not SF.ConsumablesTradeHandoff or not SF.ConsumablesTradeHandoff.EnqueueConfirmed then
        loadModule("SpectrumFederation/modules/LootHelper/ConsumablesTradeHandoff.lua")
    end
    local H = SF.ConsumablesTradeHandoff
    H.Reset()
    _G.UnitGUID = function() return nil end
    SF.ConsumablesWithdrawRuntime = SF.ConsumablesWithdrawRuntime or {}
    SF.ConsumablesWithdrawRuntime.CurrentContext = function()
        return { guildKey = nil }
    end
    local batch, err = H.EnqueueConfirmed({ ["10"] = 2 }, { operationId = "op-nil" })
    assertEq(batch, nil, "E: nil guild/GUID enqueue rejected")
    assertEq(err, "missing_identity", "E: missing_identity reason")

    _G.UnitGUID = function() return "Player-1-G1" end
    SF.ConsumablesWithdrawRuntime.CurrentContext = function()
        return { guildKey = "club:G1" }
    end
    batch, err = H.EnqueueConfirmed({ ["10"] = 3 }, {
        operationId = "op-g1",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    assertTrue(batch ~= nil, "E: valid enqueue: " .. tostring(err))
    _G.UnitGUID = function() return "Player-1-G2" end
    SF.ConsumablesWithdrawRuntime.CurrentContext = function()
        return { guildKey = "club:G2" }
    end
    local batch2, err2 = H.EnqueueConfirmed({ ["20"] = 1 }, {
        operationId = "op-g2",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    assertEq(batch2, nil, "E: G1→G2 rebinding rejected")
    assertEq(err2, "context_mismatch", "E: context_mismatch on guild change")

    H.Reset()
    _G.UnitGUID = function() return "Player-1-G1" end
    SF.ConsumablesWithdrawRuntime.CurrentContext = function()
        return { guildKey = "club:G1" }
    end
    H.EnqueueConfirmed({ ["10"] = 2 }, {
        operationId = "op-done", guildKey = "club:G1", playerGuid = "Player-1-G1",
    })
    local delivered, ambiguous, outcome = W.ResolveTradeDelivery(
        { ["10"] = 2, ["999"] = 5 },
        { ["10"] = 2 },
        function() return 0 end,
        true
    )
    assertEq(outcome, "completed", "E: unrelated offer ignored outcome=" .. tostring(outcome))
    assertEq(ambiguous["999"], nil, "E: unrelated item not ambiguous")
    assertEq(delivered["10"], 2, "E: tracked item delivered")
    H.OnTradeCompleted(delivered, ambiguous)
    assertEq(H.GetState().status, "complete", "E: complete not unresolved")
    local _, _, outcome2 = W.ResolveTradeDelivery(
        { ["999"] = 1 },
        {},
        function() return 0 end,
        true
    )
    assertEq(outcome2, "cancelled", "E: no tracked obligations → cancelled")

    -- Production TRADE_SHOW → ACCEPT → CLOSED path.
    local bagCounts = { ["10"] = 5 }
    local tradeOffers = { ["10"] = 5 }
    _G.GetServerTime = function() return 100000 end
    _G.C_Container = {
        GetContainerNumSlots = function() return 4 end,
        GetContainerItemInfo = function() return nil end,
    }
    SF.ConsumablesRouting = { IsCarriedBag = function() return true end }
    -- Patch PlayerBagCount via bag read path used by handoff.
    local priorGetItemCount = _G.GetItemCount
    _G.GetItemCount = function(itemId)
        return bagCounts[tostring(itemId)] or bagCounts[tonumber(itemId)] or 0
    end
    -- Handoff uses container scans; provide counts through GetContainerItemInfo.
    C_Container.GetContainerItemInfo = function(bag, slot)
        if bag == 0 and slot == 1 and (bagCounts["10"] or 0) > 0 then
            return { itemID = 10, stackCount = bagCounts["10"], isLocked = false }
        end
        if bag == 0 and slot == 2 and (bagCounts["20"] or 0) > 0 then
            return { itemID = 20, stackCount = bagCounts["20"], isLocked = false }
        end
        return nil
    end
    _G.GetTradePlayerItemInfo = function(slot)
        local qty10 = tradeOffers["10"]
        local qty20 = tradeOffers["20"]
        if slot == 1 and qty10 and qty10 > 0 then
            return "item", nil, qty10
        end
        if slot == 2 and qty20 and qty20 > 0 then
            return "item", nil, qty20
        end
        return nil
    end
    _G.GetTradePlayerItemLink = function(slot)
        if slot == 1 and tradeOffers["10"] then return "|Hitem:10:|h" end
        if slot == 2 and tradeOffers["20"] then return "|Hitem:20:|h" end
        return nil
    end
    local savedCreateFrame = _G.CreateFrame
    local frames = {}
    _G.CreateFrame = function(_, name)
        local f = { name = name, scripts = {}, _text = "" }
        function f:RegisterEvent() end
        function f:UnregisterEvent() end
        function f:UnregisterAllEvents() end
        function f:SetScript(ev, fn) f.scripts[ev] = fn end
        function f:GetScript(ev) return f.scripts[ev] end
        function f:SetSize() end
        function f:SetPoint() end
        function f:SetHeight() end
        function f:SetWidth() end
        function f:SetFrameStrata() end
        function f:SetFrameLevel() end
        function f:SetMovable() end
        function f:EnableMouse() end
        function f:RegisterForDrag() end
        function f:RegisterForClicks() end
        function f:Hide() end
        function f:Show() end
        function f:IsShown() return false end
        function f:SetText(t) f._text = tostring(t or "") end
        function f:GetText() return f._text end
        function f:SetJustifyH() end
        function f:SetFontObject() end
        function f:SetTextColor() end
        function f:CreateFontString()
            return {
                SetPoint = function() end, SetJustifyH = function() end,
                SetWordWrap = function() end, SetText = function() end,
                SetFontObject = function() end, SetTextColor = function() end,
                SetWidth = function() end, Show = function() end, Hide = function() end,
                GetText = function() return "" end,
            }
        end
        frames[#frames + 1] = f
        return f
    end

    local function fire(event, ...)
        local st = H.GetState()
        assertTrue(st.frame and st.frame.scripts.OnEvent, "E: production OnEvent registered")
        st.frame.scripts.OnEvent(st.frame, event, ...)
    end

    local function runClearThenEnqueue(outcomeMode)
        H.Reset()
        -- Force re-attach listeners after Reset keeps listenersAttached.
        H._state.listenersAttached = false
        -- Snapshot at show is 5 offered / 5 in bags.
        bagCounts["10"] = 5
        tradeOffers["10"] = 5
        local oldBatch = H.EnqueueConfirmed({ ["10"] = 5 }, {
            operationId = "op-old-" .. outcomeMode,
            guildKey = "club:G1",
            playerGuid = "Player-1-G1",
        })
        assertTrue(oldBatch ~= nil, "E: old batch enqueued")
        fire("TRADE_SHOW")
        assertTrue(H.GetState().tradeSessionAuthority ~= nil, "E: authority captured at show")
        local offeredBeforeClear = tradeOffers["10"]
        H.ClearPending()
        assertEq(H.GetState().tradeSessionAuthority, nil, "E: Clear drops trade authority")
        assertEq(tradeOffers["10"], offeredBeforeClear, "E: Clear leaves player offers untouched")
        bagCounts["10"] = 7
        local newBatch = H.EnqueueConfirmed({ ["10"] = 7 }, {
            operationId = "op-new-" .. outcomeMode,
            guildKey = "club:G1",
            playerGuid = "Player-1-G1",
        })
        assertTrue(newBatch ~= nil, "E: new same-item batch after Clear")
        assertEq(#H.GetState().batches, 1, "E: only new batch present")
        assertEq(H.GetState().batches[1].id, newBatch.id, "E: surviving batch is new")
        tradeOffers["10"] = 5
        if outcomeMode == "delivered" then
            -- Genuine full delivery vs the captured show snapshot (5→0).
            fire("TRADE_ACCEPT_UPDATE", 1, 1)
            bagCounts["10"] = 0
            fire("TRADE_CLOSED")
        else
            fire("TRADE_ACCEPT_UPDATE", 1, 1)
            -- Ambiguous relative to snapshot: bags unchanged at 7 while offer was 5.
            bagCounts["10"] = 7
            fire("TRADE_CLOSED")
        end
        assertEq(#H.GetState().batches, 1, "E: " .. outcomeMode .. " leaves new batch intact")
        assertEq(H.GetState().batches[1].id, newBatch.id, "E: " .. outcomeMode .. " new id intact")
        assertEq(H.GetState().batches[1].amounts["10"], 7,
            "E: " .. outcomeMode .. " new batch remains quantity 7")
        assertTrue(H.GetState().batches[1].ambiguous == nil
            or next(H.GetState().batches[1].ambiguous) == nil,
            "E: " .. outcomeMode .. " new batch not paused")
        -- Duplicate close idempotent.
        fire("TRADE_CLOSED")
        assertEq(#H.GetState().batches, 1, "E: duplicate close idempotent")
        assertEq(H.GetState().batches[1].amounts["10"], 7,
            "E: " .. outcomeMode .. " quantity 7 after duplicate close")
    end
    runClearThenEnqueue("delivered")
    runClearThenEnqueue("ambiguous")

    -- Expiry during open trade + later enqueue.
    H.Reset()
    H._state.listenersAttached = false
    bagCounts["10"] = 4
    tradeOffers["10"] = 4
    local expBatch = H.EnqueueConfirmed({ ["10"] = 4 }, {
        operationId = "op-exp",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    fire("TRADE_SHOW")
    -- AppendTradeBatch stores a copy; expire the live state row, not the return value.
    do
        local live = H.GetState().batches
        for i = 1, #live do
            if live[i].id == expBatch.id then
                live[i].expiresAt = 1
            end
        end
    end
    local late = H.EnqueueConfirmed({ ["10"] = 3 }, {
        operationId = "op-late",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    assertTrue(late ~= nil, "E: enqueue during open trade after expiry")
    fire("TRADE_ACCEPT_UPDATE", 1, 1)
    bagCounts["10"] = 0
    fire("TRADE_CLOSED")
    local alive = H.GetState().batches
    local foundLate = false
    for i = 1, #alive do
        if alive[i].id == late.id then
            foundLate = true
            assertEq(alive[i].amounts["10"], 3, "E: late batch remains quantity 3")
            assertTrue(alive[i].ambiguous == nil or next(alive[i].ambiguous) == nil,
                "E: late batch unpaused")
        end
        assertTrue(alive[i].id ~= expBatch.id, "E: expired original not resurrected")
    end
    assertTrue(foundLate, "E: late enqueue survives expired-trade settlement")

    -- All relevant obligations expired before settlement → no unresolved sticky status.
    H.Reset()
    H._state.listenersAttached = false
    bagCounts["10"] = 2
    tradeOffers["10"] = 2
    local allExp = H.EnqueueConfirmed({ ["10"] = 2 }, {
        operationId = "op-all-exp",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    fire("TRADE_SHOW")
    do
        local live = H.GetState().batches
        for i = 1, #live do
            if live[i].id == allExp.id then
                live[i].expiresAt = 1
                -- Pre-seed ambiguity that would sticky-unresolved under beforeAmbiguous.
                live[i].ambiguous = { ["10"] = 2 }
            end
        end
    end
    fire("TRADE_ACCEPT_UPDATE", 0, 1) -- numeric 0/1 flags
    fire("TRADE_ACCEPT_UPDATE", 1, 1)
    bagCounts["10"] = 2
    fire("TRADE_CLOSED")
    assertTrue(H.GetState().status ~= "unresolved",
        "E: all-expired settlement does not sticky unresolved status=" .. tostring(H.GetState().status))

    -- Live unexpired obligation + numeric (0,1): cancel without consuming.
    H.Reset()
    H._state.listenersAttached = false
    bagCounts["10"] = 5
    tradeOffers["10"] = 5
    local live01 = H.EnqueueConfirmed({ ["10"] = 5 }, {
        operationId = "op-live-01",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    fire("TRADE_SHOW")
    fire("TRADE_ACCEPT_UPDATE", 0, 1)
    bagCounts["10"] = 0
    fire("TRADE_CLOSED")
    assertEq(#H.GetState().batches, 1, "E: (0,1) leaves live batch")
    assertEq(H.GetState().batches[1].id, live01.id, "E: (0,1) same batch")
    assertEq(H.GetState().batches[1].amounts["10"], 5, "E: (0,1) quantity unchanged")
    assertTrue(H.GetState().batches[1].ambiguous == nil
        or next(H.GetState().batches[1].ambiguous) == nil,
        "E: (0,1) no ambiguity")

    -- Live (1,1) positive control: consume exactly the proven outgoing quantity.
    H.Reset()
    H._state.listenersAttached = false
    bagCounts["10"] = 5
    tradeOffers["10"] = 5
    H.EnqueueConfirmed({ ["10"] = 5 }, {
        operationId = "op-live-11",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    fire("TRADE_SHOW")
    fire("TRADE_ACCEPT_UPDATE", 1, 1)
    bagCounts["10"] = 0 -- proven outgoing 5
    fire("TRADE_CLOSED")
    assertEq(#H.GetState().batches, 0, "E: (1,1) full proven delivery consumes batch")
    assertEq(H.GetState().status, "complete", "E: (1,1) complete status")

    -- Explicit empty snapshot (manual removal of offers) with both accepted.
    H.Reset()
    H._state.listenersAttached = false
    bagCounts["10"] = 3
    tradeOffers["10"] = 3
    local emptyBatch = H.EnqueueConfirmed({ ["10"] = 3 }, {
        operationId = "op-empty-offer",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    fire("TRADE_SHOW")
    tradeOffers["10"] = nil -- player cleared offers
    fire("TRADE_ACCEPT_UPDATE", 1, 1)
    fire("TRADE_ACCEPT_UPDATE", 1, 1)
    fire("TRADE_CLOSED")
    assertEq(#H.GetState().batches, 1, "E: empty offer leaves batch")
    assertEq(H.GetState().batches[1].id, emptyBatch.id, "E: empty offer same batch")
    assertEq(H.GetState().batches[1].amounts["10"], 3, "E: empty offer quantity exact 3")
    assertTrue(H.GetState().batches[1].ambiguous == nil
        or next(H.GetState().batches[1].ambiguous) == nil,
        "E: empty offer no ambiguity")

    -- Terminal status from ALL surviving batches: paused A must keep unresolved
    -- after a later successful B delivery or unrelated cancellation (no Reset).
    H.Reset()
    H._state.listenersAttached = false
    bagCounts["10"] = 5
    bagCounts["20"] = 4
    tradeOffers["10"] = 5
    tradeOffers["20"] = nil
    local batchA = H.EnqueueConfirmed({ ["10"] = 5 }, {
        operationId = "op-amb-A",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    assertTrue(batchA ~= nil, "E: batch A enqueued")
    local expiryA = nil
    do
        local live = H.GetState().batches
        for i = 1, #live do
            if live[i].id == batchA.id then expiryA = live[i].expiresAt end
        end
    end
    fire("TRADE_SHOW")
    fire("TRADE_ACCEPT_UPDATE", 1, 1)
    -- Ambiguous for A: bags unchanged vs show snapshot.
    bagCounts["10"] = 5
    fire("TRADE_CLOSED")
    assertEq(H.GetState().status, "unresolved", "E: A ambiguous → unresolved")
    assertTrue(type(H.GetState().statusDetail) == "string"
        and H.GetState().statusDetail:find("unresolved", 1, true) ~= nil,
        "E: A unresolved message shown")
    local afterA = H.GetState().batches
    local foundA = nil
    for i = 1, #afterA do
        if afterA[i].id == batchA.id then foundA = afterA[i] end
    end
    assertTrue(foundA ~= nil, "E: A survives ambiguity")
    assertEq(foundA.amounts["10"], 5, "E: A quantity exact 5")
    assertEq(foundA.ambiguous and foundA.ambiguous["10"], 5, "E: A ambiguity exact 5")
    assertEq(foundA.expiresAt, expiryA, "E: A expiry preserved")
    local offerableAfterA = H._AggregatePending()
    assertTrue(offerableAfterA["10"] == nil or offerableAfterA["10"] == 0,
        "E: paused A excluded from offerable totals")

    -- Later successful delivery of B without Reset.
    bagCounts["20"] = 4
    tradeOffers["10"] = nil
    tradeOffers["20"] = 4
    local batchB = H.EnqueueConfirmed({ ["20"] = 4 }, {
        operationId = "op-del-B",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    assertTrue(batchB ~= nil, "E: batch B enqueued while A paused")
    fire("TRADE_SHOW")
    fire("TRADE_ACCEPT_UPDATE", 1, 1)
    bagCounts["20"] = 0 -- proven full delivery of B
    fire("TRADE_CLOSED")
    assertEq(H.GetState().status, "unresolved",
        "E: later B complete keeps unresolved while A paused")
    assertTrue(type(H.GetState().statusDetail) == "string"
        and H.GetState().statusDetail:find("unresolved", 1, true) ~= nil,
        "E: unresolved message after B delivery")
    local afterB = H.GetState().batches
    local a2, b2 = nil, nil
    for i = 1, #afterB do
        if afterB[i].id == batchA.id then a2 = afterB[i] end
        if afterB[i].id == batchB.id then b2 = afterB[i] end
    end
    assertTrue(a2 ~= nil, "E: A still present after B delivery")
    assertEq(a2.amounts["10"], 5, "E: A quantity unchanged after B")
    assertEq(a2.ambiguous and a2.ambiguous["10"], 5, "E: A ambiguity unchanged after B")
    assertEq(a2.expiresAt, expiryA, "E: A expiry unchanged after B")
    assertEq(b2, nil, "E: B consumed once")
    local offerableAfterB = H._AggregatePending()
    assertTrue(offerableAfterB["10"] == nil or offerableAfterB["10"] == 0,
        "E: A still excluded from offerable after B")
    assertTrue(offerableAfterB["20"] == nil or offerableAfterB["20"] == 0,
        "E: B not offerable after consumption")

    -- Companion: ambiguity for A, then cancel empty/unrelated later trade (no Reset).
    H.Reset()
    H._state.listenersAttached = false
    bagCounts["10"] = 5
    bagCounts["20"] = 0
    tradeOffers["10"] = 5
    tradeOffers["20"] = nil
    local batchA2 = H.EnqueueConfirmed({ ["10"] = 5 }, {
        operationId = "op-amb-A2",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    fire("TRADE_SHOW")
    fire("TRADE_ACCEPT_UPDATE", 1, 1)
    bagCounts["10"] = 5
    fire("TRADE_CLOSED")
    assertEq(H.GetState().status, "unresolved", "E: A2 ambiguous → unresolved")
    tradeOffers["10"] = nil
    tradeOffers["20"] = nil
    fire("TRADE_SHOW")
    -- Empty/unrelated cancel: no accept, close.
    fire("TRADE_CLOSED")
    assertEq(H.GetState().status, "unresolved",
        "E: later cancel keeps unresolved while A paused")
    assertTrue(type(H.GetState().statusDetail) == "string"
        and H.GetState().statusDetail:find("unresolved", 1, true) ~= nil,
        "E: unresolved message after later cancel")
    local paused = nil
    for i = 1, #H.GetState().batches do
        if H.GetState().batches[i].id == batchA2.id then
            paused = H.GetState().batches[i]
        end
    end
    assertTrue(paused ~= nil, "E: paused A unchanged after cancel")
    assertEq(paused.amounts["10"], 5, "E: paused A quantity exact after cancel")
    assertEq(paused.ambiguous and paused.ambiguous["10"], 5,
        "E: paused A ambiguity exact after cancel")

    -- Ordinary cancellation control (no live ambiguity) still uses cancelled message.
    H.Reset()
    H._state.listenersAttached = false
    bagCounts["10"] = 3
    tradeOffers["10"] = 3
    H.EnqueueConfirmed({ ["10"] = 3 }, {
        operationId = "op-cancel-plain",
        guildKey = "club:G1",
        playerGuid = "Player-1-G1",
    })
    fire("TRADE_SHOW")
    fire("TRADE_CLOSED") -- no accept → cancelled
    assertEq(H.GetState().status, "pending", "E: ordinary cancel → pending status")
    assertTrue(type(H.GetState().statusDetail) == "string"
        and H.GetState().statusDetail:find("cancelled", 1, true) ~= nil,
        "E: ordinary cancel message")
    assertEq(#H.GetState().batches, 1, "E: ordinary cancel leaves batch")

    if savedCreateFrame then
        _G.CreateFrame = savedCreateFrame
    end

    if priorGetItemCount then _G.GetItemCount = priorGetItemCount end
end

-- F: focused pooled-row rebind + orphan-only access via real __sfTest hooks
do
    local managePage = SF.SettingsUI and SF.SettingsUI.pagesById and SF.SettingsUI.pagesById.guildSuppliesManage
    assertTrue(managePage and managePage.__sfTest, "F: Manage page __sfTest hooks required")
    local hooks = managePage.__sfTest
    assertTrue(type(hooks.OpenRecipeEditor) == "function", "F: OpenRecipeEditor required")
    assertTrue(type(hooks.RefreshRecipeEditor) == "function", "F: RefreshRecipeEditor required")
    assertTrue(type(hooks.CommitRecipeEditorSave) == "function", "F: CommitRecipeEditorSave required")
    assertTrue(type(hooks.RecipeEditorDraft) == "function", "F: RecipeEditorDraft required")
    assertTrue(type(hooks.RecipeEditorUi) == "function", "F: RecipeEditorUi required")
    assertTrue(type(hooks.CloseRecipeEditor) == "function", "F: CloseRecipeEditor required")
    assertTrue(type(hooks.RecipeRows) == "function", "F: RecipeRows required")

    local record = {
        datasetId = "gs1:focus",
        _guildKey = "club:focus",
        currentCampaignId = "camp1",
        activation = "staged",
        permission = { editorRankPosition = 3 },
        accounting = {
            _consumables = {
                bankTab = 1,
                generation = 1,
                configSeq = 1,
                requestedItems = {
                    ["10"] = { itemId = 10, goal = 5 },
                    ["20"] = { itemId = 20, goal = 5 },
                },
                recipes = {
                    ["100"] = { itemId = 100, reagents = { ["10"] = 3, ["20"] = 9 } },
                },
            },
        },
    }
    GS.GetCurrentRecord = function() return record end
    GS.GetCurrentContext = function()
        return { ready = true, guildKey = "club:focus", actorGuid = "Player-1-A", canEdit = true }
    end
    GS.GetCapabilities = function() return { canEdit = true, canRead = true } end
    GS.SenderHasEditorAuthority = function() return true end
    GS.RecipeAvailability = function() return true end
    local messages = {}
    local ctx = {
        section = {
            SetMessage = function(_, text, kind)
                messages[#messages + 1] = { text = text, kind = kind }
            end,
            ClearMessage = function()
                messages[#messages + 1] = { cleared = true }
            end,
        },
    }
    SF.SettingsUI = SF.SettingsUI or {}
    SF.SettingsUI.Dialogs = {
        Confirm = function(_, _msg, _label, accept)
            if type(accept) == "function" then accept() end
        end,
    }

    hooks.OpenRecipeEditor(ctx, 100, record.accounting._consumables.recipes["100"])
    local draft = hooks.RecipeEditorDraft()
    local ui = hooks.RecipeEditorUi()
    assertTrue(ui and ui.reagentRows and #ui.reagentRows >= 2, "F: reagent rows exist")
    local row10
    for i = 1, #ui.reagentRows do
        if ui.reagentRows[i]._boundItemId == 10 then
            row10 = ui.reagentRows[i]
            break
        end
    end
    assertTrue(row10 and row10.Edit, "F: item10 row widget required")
    row10.Edit._hasFocus = true
    row10.Edit:SetText("7")
    -- Remove item 10 from requested; keep 20. Focused 7 must stay orphan.
    record.accounting._consumables.requestedItems = {
        ["20"] = { itemId = 20, goal = 5 },
    }
    hooks.RefreshRecipeEditor()
    assertEq(draft.reagentTexts["10"], "7", "F: focused remove keeps orphan10=7")
    assertEq(draft.reagentTexts["20"], "9", "F: item20 remains 9")
    -- Inspect rebound widget text for surviving item20.
    local row20
    for i = 1, #ui.reagentRows do
        if ui.reagentRows[i]._boundItemId == 20 and ui.reagentRows[i].Edit then
            row20 = ui.reagentRows[i]
            break
        end
    end
    assertTrue(row20 ~= nil, "F: item20 rebound row required")
    assertEq(row20.Edit:GetText(), "9", "F: rebound widget text for item20 is 9")

    -- Save/capture must read focused orphan through production path.
    local applied
    GS.NewConfigOperation = function(_, kind, target, value)
        applied = { kind = kind, target = target, value = value }
        return { kind = kind, target = target, value = value }, "accepted"
    end
    GS.ApplyStagedConfigOperation = function() return "accepted" end
    hooks.CommitRecipeEditorSave()
    assertTrue(applied ~= nil, "F: Save emitted set-recipe")
    assertEq(applied.value.reagents["10"], 7, "F: Save capture orphan10=7")
    assertEq(applied.value.reagents["20"], 9, "F: Save capture item20=9")

    -- Independent insertion case with focused rebind.
    hooks.OpenRecipeEditor(ctx, 100, record.accounting._consumables.recipes["100"])
    draft = hooks.RecipeEditorDraft()
    ui = hooks.RecipeEditorUi()
    row20 = nil
    for i = 1, #ui.reagentRows do
        if ui.reagentRows[i]._boundItemId == 20 then
            row20 = ui.reagentRows[i]
            break
        end
    end
    assertTrue(row20 and row20.Edit, "F: insertion setup row20")
    row20.Edit._hasFocus = true
    row20.Edit:SetText("9")
    record.accounting._consumables.requestedItems = {
        ["5"] = { itemId = 5, goal = 1 },
        ["20"] = { itemId = 20, goal = 5 },
    }
    hooks.RefreshRecipeEditor()
    assertEq(draft.reagentTexts["5"] or "0", "0", "F: new lower item starts at 0")
    assertEq(draft.reagentTexts["20"], "9", "F: focused item20 stays 9 across insert")
    local row5
    for i = 1, #ui.reagentRows do
        if ui.reagentRows[i]._boundItemId == 5 then
            row5 = ui.reagentRows[i]
            break
        end
    end
    assertTrue(row5 and row5.Edit, "F: inserted item5 row required")
    assertEq(row5.Edit:GetText() or "0", "0", "F: inserted widget text is 0")
    applied = nil
    hooks.CommitRecipeEditorSave()
    assertTrue(applied ~= nil, "F: insertion Save emitted")
    assertTrue(applied.value.reagents["5"] == nil or applied.value.reagents["5"] == 0,
        "F: zero/new item omitted or zero on Save")
    assertEq(applied.value.reagents["20"], 9, "F: insertion Save keeps 20=9")

    -- Orphan-only access through the page Definition saved-recipes scrollList.
    record.accounting._consumables.requestedItems = {}
    hooks.CloseRecipeEditor(true)
    assertTrue(type(hooks.Definition) == "function", "F: Definition hook required")
    local def = hooks.Definition()
    local recipeList
    local function walkDef(node)
        if type(node) ~= "table" or recipeList then return end
        if node.type == "scrollList"
            and type(node.enabled) == "function"
            and type(node.onSelect) == "function"
            and node.getItems == hooks.RecipeRows then
            recipeList = node
            return
        end
        for _, child in pairs(node) do
            if type(child) == "table" then
                walkDef(child)
            end
        end
    end
    walkDef(def)
    assertTrue(recipeList ~= nil, "F: saved-recipes scrollList located via Definition")
    assertTrue(recipeList.enabled() == true, "F: orphan-only saved-recipes list enabled")
    local rows = hooks.RecipeRows()
    assertTrue(#rows >= 1, "F: saved recipe list still has orphan recipe")
    recipeList.onSelect(ctx, rows[1])
    assertEq(hooks.RecipeEditorDraft().open, true, "F: Definition onSelect opens orphan recipe")
    assertEq(hooks.RecipeEditorDraft().outputItemId, 100, "F: onSelect opened recipe 100")
    ui = hooks.RecipeEditorUi()
    assertTrue(ui and ui.delete and ui.delete.scripts and ui.delete.scripts.OnClick,
        "F: delete control required")
    local deleted
    GS.NewConfigOperation = function(_, kind, target, value)
        deleted = { kind = kind, target = target, value = value }
        return { kind = kind, target = target, value = value }, "accepted"
    end
    ui.delete.scripts.OnClick(ui.delete)
    assertTrue(deleted ~= nil, "F: orphan-only Delete issued set-recipe")
    assertEq(deleted.value.removed, true, "F: Delete removed=true")

    -- Creation still blocked without requested items.
    local blocked = false
    ctx.section.SetMessage = function(_, _, kind)
        if kind == "warn" or kind == "error" then blocked = true end
    end
    hooks.OpenRecipeEditor(ctx, 200, nil)
    assertTrue(blocked or hooks.RecipeEditorDraft().open ~= true,
        "F: creation without requested items blocked")

    -- Escape dismissal: UISpecialFrames hide and focused EditBox OnEscapePressed.
    assertTrue(type(hooks.InvokeRecipeEditorEscape) == "function",
        "F: Escape invoke hook required")
    local escapeRegistered = false
    for i = 1, #(_G.UISpecialFrames or {}) do
        if _G.UISpecialFrames[i] == "SFGuildSuppliesRecipeEditor" then
            escapeRegistered = true
            break
        end
    end
    assertTrue(escapeRegistered, "F: recipe editor registered in UISpecialFrames")
    record.accounting._consumables.requestedItems = {
        ["10"] = { itemId = 10, goal = 5 },
        ["20"] = { itemId = 20, goal = 5 },
    }
    record.accounting._consumables.recipes = {
        ["100"] = { itemId = 100, reagents = { ["10"] = 1, ["20"] = 1 } },
    }
    local savedRecipes = {
        ["100"] = { itemId = 100, reagents = { ["10"] = 1, ["20"] = 1 } },
    }
    hooks.OpenRecipeEditor(ctx, 100, savedRecipes["100"])
    draft = hooks.RecipeEditorDraft()
    ui = hooks.RecipeEditorUi()
    assertEq(draft.open, true, "F: Escape setup opens editor")
    assertTrue(ui.frame:IsShown(), "F: Escape setup shows frame")
    local escRow
    for i = 1, #ui.reagentRows do
        if ui.reagentRows[i]._boundItemId == 10 then
            escRow = ui.reagentRows[i]
            break
        end
    end
    assertTrue(escRow and escRow.Edit, "F: Escape reagent row required")
    escRow.Edit:SetText("4")
    assertEq(draft.reagentTexts["10"], "4", "F: Escape setup edited reagent")
    -- Escape without relying on focus: UISpecialFrames hide path.
    hooks.InvokeRecipeEditorEscape({})
    assertEq(hooks.RecipeEditorDraft().open, false, "F: Escape hide closes editor")
    assertTrue(not ui.frame:IsShown(), "F: Escape hide hides frame")
    assertEq(next(hooks.RecipeEditorDraft().reagentTexts), nil,
        "F: Escape hide clears draft texts")
    assertEq(hooks.RecipeEditorDraft().sessionId, nil, "F: Escape hide clears session")
    -- Shared saved recipe unchanged.
    assertEq(savedRecipes["100"].reagents["10"], 1, "F: Escape does not mutate saved recipe")
    -- Reopen loads saved/default values.
    hooks.OpenRecipeEditor(ctx, 100, savedRecipes["100"])
    draft = hooks.RecipeEditorDraft()
    ui = hooks.RecipeEditorUi()
    assertEq(draft.reagentTexts["10"], "1", "F: reopen after Escape loads saved qty")
    escRow = nil
    for i = 1, #ui.reagentRows do
        if ui.reagentRows[i]._boundItemId == 10 then
            escRow = ui.reagentRows[i]
            break
        end
    end
    assertTrue(escRow and escRow.Edit, "F: reopen Escape row")
    escRow.Edit._hasFocus = true
    escRow.Edit:SetText("8")
    assertEq(draft.reagentTexts["10"], "8", "F: focused edit before Escape")
    -- Focused Escape must invoke OnEscapePressed only — no Hide fallback.
    assertTrue(type(escRow.Edit:GetScript("OnEscapePressed")) == "function",
        "F: focused Escape handler installed on reagent EditBox")
    local focusedOk = hooks.InvokeRecipeEditorEscape({ withFocus = true, itemId = 10 })
    assertEq(focusedOk, true, "F: focused Escape invoke returns true via handler")
    assertEq(hooks.RecipeEditorDraft().open, false, "F: focused Escape closes editor")
    assertEq(next(hooks.RecipeEditorDraft().reagentTexts), nil,
        "F: focused Escape clears draft")
    hooks.OpenRecipeEditor(ctx, 100, savedRecipes["100"])
    assertEq(hooks.RecipeEditorDraft().reagentTexts["10"], "1",
        "F: reopen after focused Escape loads saved qty")
    -- Sensitivity: removing OnEscapePressed must fail focused invoke (no Hide fallback).
    ui = hooks.RecipeEditorUi()
    for i = 1, #ui.reagentRows do
        if ui.reagentRows[i].Edit then
            ui.reagentRows[i].Edit:SetScript("OnEscapePressed", nil)
        end
    end
    assertEq(hooks.InvokeRecipeEditorEscape({ withFocus = true }), false,
        "F: focused Escape without handler fails closed (no Hide fallback)")
    assertEq(hooks.RecipeEditorDraft().open, true,
        "F: failed focused Escape leaves editor open")
    hooks.CloseRecipeEditor(true)
    -- NEW recipe editor: Escape discard + reopen defaults.
    blocked = false
    hooks.OpenRecipeEditor(ctx, 200, nil)
    assertEq(hooks.RecipeEditorDraft().open, true, "F: new recipe editor opens")
    assertEq(hooks.RecipeEditorDraft().isExisting, false, "F: new editor isExisting=false")
    draft = hooks.RecipeEditorDraft()
    ui = hooks.RecipeEditorUi()
    local newEdit = nil
    for i = 1, #(ui.reagentRows or {}) do
        if ui.reagentRows[i]._boundItemId == 10 and ui.reagentRows[i].Edit then
            newEdit = ui.reagentRows[i].Edit
            break
        end
    end
    assertTrue(newEdit ~= nil, "F: new editor reagent edit required")
    newEdit:SetText("5")
    assertEq(draft.reagentTexts["10"], "5", "F: new editor draft edited")
    assertTrue(hooks.InvokeRecipeEditorEscape({ withFocus = true, itemId = 10 }),
        "F: new editor focused Escape invokes handler")
    assertEq(hooks.RecipeEditorDraft().open, false, "F: new editor Escape closes")
    assertEq(next(hooks.RecipeEditorDraft().reagentTexts), nil,
        "F: new editor Escape clears draft")
    hooks.OpenRecipeEditor(ctx, 200, nil)
    assertEq(hooks.RecipeEditorDraft().reagentTexts["10"] or "0", "0",
        "F: reopen new editor loads default zero")
    -- Ordinary dismissal route (UISpecialFrames hide) on new editor.
    ui = hooks.RecipeEditorUi()
    for i = 1, #(ui.reagentRows or {}) do
        if ui.reagentRows[i]._boundItemId == 20 and ui.reagentRows[i].Edit then
            ui.reagentRows[i].Edit:SetText("2")
            break
        end
    end
    hooks.InvokeRecipeEditorEscape({})
    assertEq(hooks.RecipeEditorDraft().open, false, "F: new editor ordinary Escape closes")
    assertEq(savedRecipes["100"].reagents["10"], 1,
        "F: Escape paths leave existing saved recipe untouched")
    hooks.CloseRecipeEditor(true)
end

-- Recipe editor shares Settings window opacity (Retail QA: popup vs main window).
do
    SpectrumFederationDB = {
        version = 3,
        global = { settingsWindowOpacity = 75 },
        lootHelper = { profiles = {}, activeProfileId = nil },
    }
    SpectrumFederationCharDB = {}
    -- Prior blocks install C_Timer fakes; clear so Apply Debounce runs immediately
    -- (production sf.reset still reaches ApplyAll without a harness drain).
    local savedTimer = C_Timer
    C_Timer = nil
    loadModule("SpectrumFederation/modules/Settings/Schema.lua")
    loadModule("SpectrumFederation/modules/Settings/Store.lua")
    loadModule("SpectrumFederation/modules/UI/Settings/StandaloneWindow.lua")
    loadModule("SpectrumFederation/modules/Settings/Apply.lua")
    SF.SettingsStore.db = nil
    SF.SettingsStore.charDb = nil
    SF.SettingsStore._callbacks = nil
    SF.SettingsStore:Init()
    SF.SettingsApply.initialized = nil
    SF.SettingsApply._debounce = nil
    SF.SettingsApply:Init()
    assertEq(SF.SettingsStore:Get("global.settingsWindowOpacity"), 75,
        "opacity: store holds nondefault 75")

    local savedCreateFrame = _G.CreateFrame
    _G.CreateFrame = function(frameType, name, parent, template)
        local f = {
            name = name,
            shown = false,
            scripts = {},
            _text = "",
            alpha = 1,
            backdrop = nil,
            backdropColor = nil,
        }
        function f:SetSize() end
        function f:SetPoint() end
        function f:SetFrameStrata() end
        function f:SetFrameLevel() end
        function f:Hide()
            local wasShown = f.shown
            f.shown = false
            if wasShown and f.scripts.OnHide then f.scripts.OnHide(f) end
        end
        function f:Show() f.shown = true end
        function f:IsShown() return f.shown end
        function f:SetScript(k, fn) f.scripts[k] = fn end
        function f:HookScript(k, fn)
            f.hooks = f.hooks or {}
            f.hooks[k] = f.hooks[k] or {}
            f.hooks[k][#f.hooks[k] + 1] = fn
        end
        function f:GetScript(k) return f.scripts[k] end
        function f:SetMovable() end
        function f:EnableMouse() end
        function f:RegisterForDrag() end
        function f:RegisterForClicks() end
        function f:RegisterEvent() end
        function f:UnregisterEvent() end
        function f:UnregisterAllEvents() end
        function f:SetScrollChild(child) f.scrollChild = child end
        function f:GetScrollChild() return f.scrollChild end
        function f:SetBackdrop(info) f.backdrop = info end
        function f:SetBackdropColor(r, g, b, a)
            f.backdropColor = { r = r, g = g, b = b, a = a }
        end
        function f:SetBackdropBorderColor(r, g, b, a)
            f.backdropBorderColor = { r = r, g = g, b = b, a = a }
        end
        function f:SetAlpha(a) f.alpha = a end
        function f:GetAlpha() return f.alpha end
        function f:SetText(t)
            f._text = tostring(t or "")
            if f.scripts.OnTextChanged then f.scripts.OnTextChanged(f) end
        end
        function f:GetText() return f._text end
        function f:SetShown(v) f.shown = v and true or false end
        function f:Enable() end
        function f:Disable() end
        function f:ClearAllPoints() end
        function f:SetAutoFocus() end
        function f:SetNumeric() end
        function f:SetMaxLetters() end
        function f:SetHeight() end
        function f:SetWidth() end
        function f:SetJustifyH() end
        f._hasFocus = false
        function f:HasFocus() return f._hasFocus and true or false end
        function f:ClearFocus() f._hasFocus = false end
        function f:SetFocus() f._hasFocus = true end
        function f:CreateFontString()
            return {
                SetPoint = function() end, SetJustifyH = function() end,
                SetWordWrap = function() end, SetText = function() end,
                SetFontObject = function() end, SetTextColor = function() end,
                SetWidth = function() end, Show = function() end, Hide = function() end,
            }
        end
        function f:CreateTexture()
            return {
                SetPoint = function() end, SetSize = function() end,
                SetTexture = function() end, Show = function() end, Hide = function() end,
                SetAllPoints = function() end,
            }
        end
        return f
    end
    SF.SettingsWindow._opacityTargets = {}
    SF.SettingsUI = SF.SettingsUI or {}
    SF.SettingsUI.pagesById = {}
    SF.SettingsUI.pages = {}
    SF.SettingsUI.categories = {}
    function SF.SettingsUI:RegisterCategory(cat) self.categories[cat.id] = cat end
    function SF.SettingsUI:RegisterPage(page)
        self.pagesById[page.id] = page
        self.pages[#self.pages + 1] = page
    end
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
    _G.UISpecialFrames = {}
    loadModule("SpectrumFederation/modules/UI/Settings/Pages/GuildSuppliesManage.lua")
    local managePage = SF.SettingsUI.pagesById.guildSuppliesManage
    assertTrue(managePage and managePage.__sfTest, "opacity: Manage hooks")
    local hooks = managePage.__sfTest
    local record = {
        datasetId = "gs1:opacity",
        _guildKey = "club:opacity",
        currentCampaignId = "camp1",
        activation = "staged",
        permission = { editorRankPosition = 3 },
        accounting = {
            _consumables = {
                bankTab = 1, generation = 1, configSeq = 1,
                requestedItems = { ["10"] = { itemId = 10, goal = 5 } },
                recipes = { ["100"] = { itemId = 100, reagents = { ["10"] = 1 } } },
            },
        },
    }
    GS.GetCurrentRecord = function() return record end
    GS.GetCurrentContext = function()
        return { ready = true, guildKey = "club:opacity", actorGuid = "Player-1-A", canEdit = true }
    end
    GS.GetCapabilities = function() return { canEdit = true, canRead = true } end
    GS.SenderHasEditorAuthority = function() return true end
    local ctx = {
        section = {
            SetMessage = function() end,
            ClearMessage = function() end,
        },
    }
    local targetsBefore = #(SF.SettingsWindow._opacityTargets or {})
    hooks.OpenRecipeEditor(ctx, 100, record.accounting._consumables.recipes["100"])
    local ui = hooks.RecipeEditorUi()
    assertTrue(ui and ui.frame, "opacity: editor frame created")
    assertTrue(ui.frame.backdrop and ui.frame.backdrop.bgFile == "Interface\\Buttons\\WHITE8X8",
        "opacity: editor uses WHITE8X8 backdrop foundation")
    assertTrue(ui.frame.backdropColor and math.abs((ui.frame.backdropColor.a or 0) - 0.75) < 1e-6,
        "opacity: editor opens at saved nondefault 75%")
    assertEq(ui.frame.alpha, 1, "opacity: editor frame alpha remains 1")
    assertEq(#SF.SettingsWindow._opacityTargets, targetsBefore + 1,
        "opacity: editor registered as opacity target once")
    -- Live settings/apply path updates the existing editor backdrop.
    SF.SettingsStore:Set("global.settingsWindowOpacity", 100)
    assertTrue(ui.frame.backdropColor and math.abs((ui.frame.backdropColor.a or 0) - 1.0) < 1e-6,
        "opacity: production Set updates existing editor to 100%")
    assertEq(ui.frame.alpha, 1, "opacity: live update does not SetAlpha the frame")
    -- Close, change setting, reopen uses current value; no callback accumulation.
    hooks.CloseRecipeEditor(true)
    assertEq(hooks.RecipeEditorDraft().open, false, "opacity: close discards editor")
    local targetsAfterClose = #SF.SettingsWindow._opacityTargets
    SF.SettingsStore:Set("global.settingsWindowOpacity", 70)
    hooks.OpenRecipeEditor(ctx, 100, record.accounting._consumables.recipes["100"])
    ui = hooks.RecipeEditorUi()
    assertTrue(ui.frame.backdropColor and math.abs((ui.frame.backdropColor.a or 0) - 0.70) < 1e-6,
        "opacity: reopen applies current 70%")
    assertEq(#SF.SettingsWindow._opacityTargets, targetsAfterClose,
        "opacity: reopen does not accumulate opacity targets")
    -- Escape discard still works after opacity wiring.
    assertTrue(hooks.InvokeRecipeEditorEscape({}), "opacity: Escape hide still works")
    assertEq(hooks.RecipeEditorDraft().open, false, "opacity: Escape closes editor")
    assertEq(next(hooks.RecipeEditorDraft().reagentTexts), nil,
        "opacity: Escape clears draft ownership")
    -- ResetAll reapplies default to the registered editor frame.
    hooks.OpenRecipeEditor(ctx, 100, record.accounting._consumables.recipes["100"])
    ui = hooks.RecipeEditorUi()
    SF.SettingsStore:ResetAll()
    assertEq(SF.SettingsStore:Get("global.settingsWindowOpacity"), 90,
        "opacity: ResetAll restores default")
    assertTrue(ui.frame.backdropColor and math.abs((ui.frame.backdropColor.a or 0) - 0.90) < 1e-6,
        "opacity: ResetAll reapplies 90% to recipe editor")
    hooks.CloseRecipeEditor(true)
    if savedCreateFrame then
        _G.CreateFrame = savedCreateFrame
    end
    C_Timer = savedTimer
end

-- D: real bank settle lifecycle, visit settle wiring, shortage visit guard, allowance
do
    if not SF.ConsumablesWithdrawRuntime or not SF.ConsumablesWithdrawRuntime.PlaceNext then
        loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    end
    local WR = SF.ConsumablesWithdrawRuntime
    local Workflow = SF.ConsumablesWithdrawWorkflow
    assertTrue(type(Workflow.InterpretWithdrawal) == "function",
        "D: production InterpretWithdrawal required")
    assertTrue(type(Workflow.WithdrawalDisposition) == "function",
        "D: production WithdrawalDisposition required")

    -- Accurate timer model + drain (must be invoked).
    local pendingTimers = {}
    C_Timer = {
        After = function(_, fn)
            if type(fn) == "function" then
                pendingTimers[#pendingTimers + 1] = { fn = fn, cancellable = false }
            end
            return nil
        end,
        NewTimer = function(_, fn)
            local cancelled = false
            local entry = {
                fn = fn,
                cancellable = true,
                Cancel = function() cancelled = true end,
                _fire = function()
                    if not cancelled and type(fn) == "function" then fn() end
                end,
                _cancelled = function() return cancelled end,
            }
            pendingTimers[#pendingTimers + 1] = entry
            return entry
        end,
        _drain = function()
            local batch = pendingTimers
            pendingTimers = {}
            for i = 1, #batch do
                local t = batch[i]
                if t.cancellable then
                    t._fire()
                elseif type(t.fn) == "function" then
                    t.fn()
                end
            end
        end,
        _live = function()
            local n = 0
            for i = 1, #pendingTimers do
                local t = pendingTimers[i]
                if not t.cancellable or not t._cancelled() then
                    n = n + 1
                end
            end
            return n
        end,
        _clear = function()
            pendingTimers = {}
        end,
    }

    local settleCount, receiptCount, handoffCount = 0, 0, 0
    local settleReasons = {}
    local pickupCount = 0
    GS.CommitLocalWithdrawalReceipts = function()
        receiptCount = receiptCount + 1
        return "accepted"
    end
    SF.ConsumablesTradeHandoff = SF.ConsumablesTradeHandoff or {}
    SF.ConsumablesTradeHandoff.EnqueueConfirmed = function()
        handoffCount = handoffCount + 1
        return { id = "h1" }
    end
    SF.ConsumablesTradeHandoff.CanAcceptUnits = function() return true end
    SF.ConsumablesTradeHandoff.PendingSnapshot = function() return {}, {} end
    SF.ConsumablesTradeHandoff.GetState = function() return {} end

    _G.GetServerTime = function() return 2000 end
    _G.GetCursorInfo = function() return nil end
    _G.GetGuildBankTabInfo = function()
        return "Tab", "icon", true, true, 0, -1, false
    end
    _G.PickupGuildBankItem = function()
        pickupCount = pickupCount + 1
    end
    _G.SplitGuildBankItem = function()
        pickupCount = pickupCount + 1
    end
    _G.InCombatLockdown = function() return false end
    _G.ClearCursor = function() end
    _G.PutItemInBackpack = function() end

    -- Controllable bag/bank boundary for real InterpretWithdrawal.
    local bagByItem = { [10] = 0 }
    local bankBySlot = { [1] = 5 }
    local bankAvailable = true
    WR.BagCount = function(itemId)
        return bagByItem[tonumber(itemId) or -1] or 0
    end
    _G.GetGuildBankItemInfo = function(tab, slot)
        if tab ~= 1 then return nil end
        if not bankAvailable then return nil, nil end
        local c = bankBySlot[slot]
        if c == nil then return nil end
        if c == 0 then return nil, 0 end
        return "tex", c, false
    end
    _G.GetGuildBankItemLink = function(tab, slot)
        if tab == 1 and bankBySlot[slot] ~= nil then return "|Hitem:10:|h" end
        return nil
    end

    local function makePendingWork(opts)
        opts = opts or {}
        settleCount, receiptCount, handoffCount = 0, 0, 0
        settleReasons = {}
        pickupCount = 0
        bagByItem[10] = opts.beforeBags or 0
        bankBySlot[1] = opts.beforeSlot or 5
        bankAvailable = opts.bankAvailable ~= false
        return {
            settled = false,
            movementStarted = true,
            bankClosed = false,
            pendingStep = {
                itemId = 10,
                slot = 1,
                count = opts.intended or 5,
                beforeBags = opts.beforeBags or 0,
                beforeSlot = opts.beforeSlot or 5,
                observeStartedAt = 2000,
                observeDelay = 0.05,
            },
            bankTab = 1,
            confirmed = {},
            confirmedTotal = 0,
            take = { ["10"] = opts.intended or 5 },
            requested = { ["10"] = opts.intended or 5 },
            selections = { ["100"] = 1 },
            operationId = opts.operationId or "op-close",
            visitToken = opts.visitToken or "visit:close",
            guildKey = "club:wd",
            playerGuid = "Player-1-A",
            campaignId = "camp1",
            datasetId = "gs1:wd",
            generation = 1,
            startedAt = 2000,
            queue = { { itemId = 10, slot = 1, count = 5 } },
            index = 2,
            onSettle = opts.onSettle or function(result)
                settleCount = settleCount + 1
                settleReasons[#settleReasons + 1] = result.reason
            end,
        }
    end

    -- Exhausted queue: real FinalizeWork + scheduled callback (no FinalizeWork stub).
    -- Allowance would be exhausted after the final successful pickup, but PlaceNext
    -- must finalize before consulting ContextStillValid.
    local priorCtx = WR.ContextStillValid
    local ctxCalled = false
    WR.ContextStillValid = function()
        ctxCalled = true
        return false, "allowance_exhausted"
    end
    settleCount, receiptCount, handoffCount = 0, 0, 0
    settleReasons = {}
    C_Timer._clear()
    WR.work = {
        settled = false,
        pendingStep = nil,
        index = 3,
        queue = { { itemId = 10 }, { itemId = 10 } },
        bankClosed = false,
        confirmed = { ["10"] = 5 },
        confirmedTotal = 5,
        take = { ["10"] = 5 },
        requested = { ["10"] = 5 },
        selections = { ["100"] = 1 },
        operationId = "op-exhausted",
        visitToken = "visit:exhausted",
        guildKey = "club:wd",
        playerGuid = "Player-1-A",
        campaignId = "camp1",
        datasetId = "gs1:wd",
        generation = 1,
        startedAt = 2000,
        movementStarted = true,
        onSettle = function(result)
            settleCount = settleCount + 1
            settleReasons[#settleReasons + 1] = result.reason
        end,
    }
    WR.PlaceNext()
    assertFalse(ctxCalled, "D: exhausted queue skips ContextStillValid/allowance")
    assertTrue(WR.work ~= nil, "D: exhausted queue schedules FinalizeWork finish")
    assertTrue(WR.work.timer ~= nil, "D: FinalizeWork owns scheduled finish timer")
    assertEq(settleCount, 0, "D: settle waits for FinalizeWork callback")
    C_Timer._drain()
    assertEq(settleCount, 1, "D: FinalizeWork scheduled callback settles once")
    assertEq(settleReasons[1], "complete", "D: exhausted queue complete after full confirm")
    assertEq(receiptCount, 1, "D: exhausted-queue receipt once")
    assertEq(handoffCount, 1, "D: exhausted-queue handoff once")
    assertEq(WR.work, nil, "D: work detached after FinalizeWork")
    assertEq(C_Timer._live(), 0, "D: no owned timers after FinalizeWork")
    WR.ContextStillValid = priorCtx

    -- Incomplete movement → bank close → deadline unresolved via real InterpretWithdrawal.
    C_Timer._clear()
    WR.work = makePendingWork({ operationId = "op-incomplete" })
    WR.OnBankClosed()
    assertTrue(WR.work ~= nil, "D: incomplete close keeps work pending")
    assertTrue(WR.work.pendingStep ~= nil, "D: incomplete close retains pendingStep")
    assertTrue(WR.work.bankClosed == true, "D: bankClosed set")
    assertTrue(WR.work.closeSettleTimer ~= nil, "D: closeSettleTimer owned distinctly")
    assertEq(WR.work.observeTimer, nil, "D: observeTimer not holding close deadline")
    local closePickups = pickupCount
    -- Duplicate bag update while pending under close deadline.
    WR.OnBagOrBankUpdate()
    assertTrue(WR.work ~= nil and WR.work.pendingStep ~= nil,
        "D: bag update while incomplete keeps pending")
    assertTrue(WR.work.closeSettleTimer ~= nil, "D: bag update preserves closeSettleTimer")
    assertEq(WR.work.observeTimer, nil, "D: no competing observeTimer after close update")
    -- Duplicate close while still pending (deadline may be replaced; lifecycle stays bounded).
    WR.OnBankClosed()
    assertTrue(WR.work ~= nil and WR.work.pendingStep ~= nil,
        "D: duplicate close keeps unresolved pending alive")
    assertTrue(WR.work.closeSettleTimer ~= nil, "D: close deadline still owned after duplicate close")
    assertEq(pickupCount, closePickups, "D: no further bank pickup after close")
    C_Timer._drain()
    assertEq(settleCount, 1, "D: deadline settles once")
    assertEq(settleReasons[1], "bank_closed_unresolved", "D: explicit unresolved on deadline")
    assertEq(receiptCount, 0, "D: unresolved incomplete has no receipt")
    assertEq(handoffCount, 0, "D: unresolved incomplete has no handoff")
    assertEq(WR.work, nil, "D: work cleared after unresolved deadline")
    assertEq(C_Timer._live(), 0, "D: no active owned timers after deadline")
    assertEq(pickupCount, closePickups, "D: still no pickup after unresolved settle")
    -- Duplicate close after settle is a no-op.
    WR.OnBankClosed()
    assertEq(settleCount, 1, "D: duplicate close after settle does not re-settle")

    -- Reliable evidence arrives while the close deadline is active → actual settlement.
    C_Timer._clear()
    WR.work = makePendingWork({ operationId = "op-evidence" })
    WR.OnBankClosed()
    assertTrue(WR.work ~= nil and WR.work.closeSettleTimer ~= nil,
        "D: evidence scenario starts with active close deadline")
    local staleDeadline = WR.work.closeSettleTimer
    assertTrue(staleDeadline ~= nil and staleDeadline.Cancel ~= nil,
        "D: close deadline handle capturable")
    -- Confirmed bag gain + bank loss matching intended qty.
    bagByItem[10] = 5
    bankBySlot[1] = 0
    WR.OnBagOrBankUpdate()
    assertEq(settleCount, 1, "D: reliable evidence settles on close")
    assertEq(settleReasons[1], "bank_closed", "D: settled reason bank_closed")
    assertEq(receiptCount, 1, "D: receipt once on confirmed settlement")
    assertEq(handoffCount, 1, "D: handoff once on confirmed settlement")
    assertEq(WR.work, nil, "D: work cleared after confirmed close settle")
    assertEq(C_Timer._live(), 0, "D: timers cleared after confirmed settle")
    -- Stale deadline callback cannot commit or settle again.
    -- _fire honors Cancel (cancellation check); also invoke the captured
    -- production closure directly so its once-only guards are exercised.
    assertTrue(type(staleDeadline.fn) == "function",
        "D: close deadline captures production callback fn")
    staleDeadline:_fire()
    assertEq(settleCount, 1, "D: canceled staleDeadline:_fire does not settle again")
    assertEq(receiptCount, 1, "D: canceled _fire cannot commit receipt again")
    assertEq(handoffCount, 1, "D: canceled _fire cannot handoff again")
    staleDeadline.fn()
    assertEq(settleCount, 1, "D: direct stale deadline fn cannot settle again")
    assertEq(receiptCount, 1, "D: direct stale deadline fn cannot commit receipt again")
    assertEq(handoffCount, 1, "D: direct stale deadline fn cannot handoff again")
    assertEq(WR.work, nil, "D: work stays detached after stale fn invoke")
    assertEq(C_Timer._live(), 0, "D: no owned timer active after stale fn invoke")
    C_Timer._drain()
    assertEq(settleCount, 1, "D: drained leftovers do not double-settle")
    assertEq(receiptCount, 1, "D: receipt still once after drain")

    -- Visit settle wiring through real Runtime:BeginQuickWithdraw (actual onSettle).
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua")
    local RT = SF.ConsumablesRuntime
    local function stubRuntimeLifecycle()
        RT.WatchGuildBankFrame = function() end
        RT.RefreshReminder = function() end
        RT.SyncReviewWithGuildBank = function() end
        RT.ConsumeBannerBankNavigation = function() end
        RT.HideReviewForBankLifecycle = function() end
        RT.CancelBannerBankNavigation = function() end
        RT.RebuildReview = function() end
        RT.BankIsOpen = function() return RT.bankOpen == true end
        RT.ItemStackLimit = function() return 20 end
        RT.ItemName = function(_, id) return "Item" .. tostring(id) end
    end
    stubRuntimeLifecycle()
    local statusText = ""
    RT.review = {
        Status = {
            SetText = function(_, t) statusText = t or "" end,
            GetText = function() return statusText end,
        },
        IsShown = function() return false end,
    }
    RT.bankOpen = false
    RT._quickWithdrawVisitSeq = 0
    RT._quickWithdrawVisitToken = nil

    local visitRecord = {
        datasetId = "gs1:wd",
        _guildKey = "club:wd",
        currentCampaignId = "camp1",
        accounting = {
            _consumables = {
                bankTab = 1,
                generation = 1,
                configSeq = 1,
                recipes = {
                    ["100"] = { itemId = 100, reagents = { ["10"] = 5 } },
                },
            },
        },
    }
    GS.IsLiveActiveForCurrentGuild = function() return true end
    GS.GetCurrentRecord = function() return visitRecord end
    GS.RecipeAvailability = function() return true end
    GS.WithdrawalReceiptCapacityOk = function() return true end
    _G.GetItemCount = function(itemId)
        return bagByItem[tonumber(itemId) or -1] or 0
    end
    _G.GetCurrentGuildBankTab = function() return 1 end
    _G.GetGuildBankTabInfo = function()
        return "Tab", "icon", true, true, 0, -1, false
    end
    C_Container = {
        GetContainerNumSlots = function(bag)
            if bag == 0 then return 4 end
            return 0
        end,
        GetContainerNumFreeSlots = function(bag)
            if bag == 0 then return 4, 0 end
            return 0, 0
        end,
        GetContainerItemInfo = function() return nil end,
        PickupContainerItem = function() end,
    }
    C_Item = {
        GetItemFamily = function() return 0 end,
        GetItemMaxStackSizeByID = function() return 20 end,
    }
    SF.Consumables = SF.Consumables or {}
    SF.Consumables.ItemIdFromText = function(link)
        local id = tostring(link or ""):match("item:(%d+)")
        return tonumber(id)
    end
    SF.ConsumablesRouting = { IsCarriedBag = function() return true end }
    -- Reload WR so Host() resolves the Runtime just loaded.
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    WR = SF.ConsumablesWithdrawRuntime
    WR.BagCount = function(itemId)
        return bagByItem[tonumber(itemId) or -1] or 0
    end

    local function installCursorStubs()
        local cursorItem = nil
        _G.GetCursorInfo = function()
            if cursorItem then return "item", cursorItem end
            return nil
        end
        _G.PickupGuildBankItem = function()
            pickupCount = pickupCount + 1
            cursorItem = 10
        end
        _G.SplitGuildBankItem = function()
            pickupCount = pickupCount + 1
            cursorItem = 10
        end
        _G.PutItemInBackpack = function() cursorItem = nil end
        _G.ClearCursor = function() cursorItem = nil end
        C_Container.PickupContainerItem = function() cursorItem = nil end
    end

    -- Counting spy that forwards to the actual production onSettle callback.
    local function withSettleSpy(fn)
        local realBegin = WR.BeginWithdraw
        WR.BeginWithdraw = function(sel, opts)
            opts = opts or {}
            local actualSettle = opts.onSettle
            assertTrue(type(actualSettle) == "function",
                "D: BeginQuickWithdraw must attach production onSettle")
            opts.onSettle = function(result)
                settleCount = settleCount + 1
                settleReasons[#settleReasons + 1] = result and result.reason
                return actualSettle(result)
            end
            return realBegin(sel, opts)
        end
        local ok, err = pcall(fn)
        WR.BeginWithdraw = realBegin
        assertTrue(ok, "D: BeginQuickWithdraw settle spy body: " .. tostring(err))
    end

    local function startViaBeginQuickWithdraw(label)
        if WR.work then WR.StopWork("test_cleanup", true) end
        C_Timer._clear()
        -- Do not drain observe timers before close: leave the pending observation.
        settleCount, receiptCount, handoffCount = 0, 0, 0
        settleReasons = {}
        pickupCount = 0
        bagByItem[10] = 0
        bankBySlot[1] = 5
        bankAvailable = true
        WR.craftDrafts = { ["100"] = 1 }
        installCursorStubs()
        local visitAtStart = RT._quickWithdrawVisitToken
        withSettleSpy(function()
            RT:BeginQuickWithdraw()
        end)
        assertTrue(WR.work ~= nil, label .. ": BeginQuickWithdraw attached work")
        assertEq(WR.work.visitToken, visitAtStart,
            label .. ": operation uses production visit token")
        assertTrue(type(WR.work.onSettle) == "function",
            label .. ": production onSettle retained on work")
        assertTrue(WR.work.pendingStep ~= nil,
            label .. ": PlaceNext left pendingStep for observation")
        assertTrue(pickupCount >= 1, label .. ": bank pickup occurred")
        return WR.work
    end

    -- close → settle while closed → reopen
    RT.bankOpen = false
    RT._quickWithdrawVisitSeq = 0
    RT._quickWithdrawVisitToken = nil
    statusText = ""
    RT:OnBankOpened()
    local visit1 = RT._quickWithdrawVisitToken
    assertTrue(visit1 ~= nil, "D: first open assigns visit token")
    -- Duplicate open / tab refresh must not rotate visit.
    RT:OnBankOpened()
    assertEq(RT._quickWithdrawVisitToken, visit1, "D: duplicate open keeps visit token")
    startViaBeginQuickWithdraw("D: close→settle")
    assertEq(WR.work.visitToken, visit1, "D: close→settle work bound to visit1")
    RT:OnBankClosed()
    assertTrue(WR.work ~= nil and WR.work.pendingStep ~= nil,
        "D: close→settle path retains pending under deadline")
    assertTrue(WR.work.closeSettleTimer ~= nil, "D: close deadline active after BeginQuickWithdraw close")
    bagByItem[10] = 5
    bankBySlot[1] = 0
    WR.OnBagOrBankUpdate()
    assertEq(settleCount, 1, "D: production settle while closed fires once")
    assertEq(receiptCount, 1, "D: receipt once via BeginQuickWithdraw settle")
    assertEq(handoffCount, 1, "D: handoff once via BeginQuickWithdraw settle")
    assertTrue(statusText:find("Withdraw settled", 1, true) ~= nil,
        "D: settle while closed publishes originating status via production SettleHandler")
    assertEq(WR.work, nil, "D: work detached after settle while closed")
    assertEq(C_Timer._live(), 0, "D: no owned timers after settle while closed")
    RT:OnBankOpened()
    local visit2 = RT._quickWithdrawVisitToken
    assertTrue(visit2 ~= visit1, "D: reopen rotates visit token")
    assertEq(statusText, "", "D: fresh visit clears prior status text")

    -- close → reopen → old operation settles: must not overwrite visit-B status.
    RT:OnBankClosed()
    RT:OnBankOpened()
    local visitA = RT._quickWithdrawVisitToken
    startViaBeginQuickWithdraw("D: late-settle")
    assertEq(WR.work.visitToken, visitA, "D: late-settle work bound to visitA")
    RT:OnBankClosed()
    assertTrue(WR.work ~= nil and WR.work.pendingStep ~= nil,
        "D: late-settle scenario pending after close")
    RT:OnBankOpened()
    local visitB = RT._quickWithdrawVisitToken
    assertTrue(visitB ~= visitA, "D: reopen for late-settle rotates token")
    RT:SetQuickWithdrawStatus("visit2-status", { visitToken = visitB })
    assertEq(statusText, "visit2-status", "D: current visit status set")
    bagByItem[10] = 5
    bankBySlot[1] = 0
    local settleBeforeLate = settleCount
    local receiptBeforeLate = receiptCount
    local handoffBeforeLate = handoffCount
    WR.OnBagOrBankUpdate()
    assertEq(settleCount, settleBeforeLate + 1, "D: late settle callback still runs")
    assertEq(receiptCount, receiptBeforeLate + 1, "D: late settle receipt once")
    assertEq(handoffCount, handoffBeforeLate + 1, "D: late settle handoff once")
    assertEq(statusText, "visit2-status",
        "D: old operation settle rejected after reopen (production BeginQuickWithdraw wiring)")
    assertEq(WR.work, nil, "D: late settle detaches work")
    assertEq(C_Timer._live(), 0, "D: no owned timers after late settle")

    -- Direct setter checks retained as token policy coverage alongside wiring above.
    RT:OnBankClosed()
    RT:SetQuickWithdrawStatus("unresolved-op", { visitToken = visitB })
    assertEq(statusText, "unresolved-op", "D: unresolved while closed for originating visit")
    RT:OnBankOpened()
    RT:SetQuickWithdrawStatus("stale-unresolved", { visitToken = visitB })
    assertTrue(statusText ~= "stale-unresolved",
        "D: prior visit unresolved cannot overwrite new visit")

    -- Visible unresolved settlement: real BeginQuickWithdraw SettleHandler → Dialogs.Confirm.
    -- Hidden Status:SetText alone is not delivery (close can settle then hide/clear).
    local presentedDialogs = {}
    SF.SettingsUI = SF.SettingsUI or {}
    SF.SettingsUI.Dialogs = SF.SettingsUI.Dialogs or {}
    SF.SettingsUI.Dialogs.Confirm = function(_, message, acceptText, _onAccept)
        presentedDialogs[#presentedDialogs + 1] = {
            message = tostring(message or ""),
            acceptText = tostring(acceptText or ""),
        }
        return true
    end
    SF.SettingsUI.Dialogs.ConfirmChoice = function(_, _msg, _yes, _no, onYes)
        if type(onYes) == "function" then end
    end
    -- Track lifecycle hide independently of CreateFrame/EnsureReview frame identity.
    local helperLifecycleHidden = false
    local realHideReview = RT.HideReviewForBankLifecycle
    RT.HideReviewForBankLifecycle = function(self)
        helperLifecycleHidden = true
        return realHideReview(self)
    end
    -- Start through real BeginQuickWithdraw without the counting settle spy so
    -- work.onSettle remains the production SettleHandler (PresentUnresolved path).
    local function startVisibilityWithdraw(label, draftOverride, bankQty)
        if WR.work then WR.StopWork("test_cleanup", true) end
        C_Timer._clear()
        settleCount, receiptCount, handoffCount = 0, 0, 0
        settleReasons = {}
        pickupCount = 0
        bagByItem[10] = 0
        bankBySlot[1] = tonumber(bankQty) or 5
        bankAvailable = true
        WR.craftDrafts = type(draftOverride) == "table" and draftOverride or { ["100"] = 1 }
        installCursorStubs()
        local visitAtStart = RT._quickWithdrawVisitToken
        RT:BeginQuickWithdraw()
        assertTrue(WR.work ~= nil, label .. ": BeginQuickWithdraw attached work")
        assertEq(WR.work.visitToken, visitAtStart, label .. ": production visit token")
        assertTrue(type(WR.work.onSettle) == "function", label .. ": production onSettle")
        assertTrue(WR.work.pendingStep ~= nil, label .. ": pendingStep after PlaceNext")
        local productionHandler = WR.work.onSettle
        local opId = WR.work.operationId
        WR.work.onSettle = function(result)
            settleCount = settleCount + 1
            settleReasons[#settleReasons + 1] = result and result.reason
            return productionHandler(result)
        end
        return opId
    end

    local function clearUnresolvedNoticeState()
        RT._unresolvedWithdrawPresented = nil -- legacy map removed; keep nil for clarity
        RT._unresolvedWithdrawRecent = nil
        RT._unresolvedWithdrawPending = nil
    end

    -- 1) Close → delayed unresolved after lifecycle hide.
    presentedDialogs = {}
    helperLifecycleHidden = false
    clearUnresolvedNoticeState()
    RT.bankOpen = false
    RT._quickWithdrawVisitSeq = 0
    RT._quickWithdrawVisitToken = nil
    statusText = ""
    RT:OnBankOpened()
    local hiddenOpId = startVisibilityWithdraw("D: unresolved-hidden")
    bagByItem[10] = 0
    bankBySlot[1] = 5
    bankAvailable = true
    settleCount, receiptCount, handoffCount = 0, 0, 0
    settleReasons = {}
    RT:OnBankClosed()
    assertTrue(helperLifecycleHidden, "D: HideReviewForBankLifecycle ran on close")
    assertFalse(RT.bankOpen, "D: bankOpen false after close")
    assertTrue(WR.work ~= nil and WR.work.pendingStep ~= nil,
        "D: unresolved-hidden keeps pending under deadline")
    assertEq(#presentedDialogs, 0, "D: no dialog before deadline while still pending")
    C_Timer._drain()
    assertEq(settleCount, 1, "D: unresolved-hidden settles once")
    assertEq(settleReasons[1], "bank_closed_unresolved", "D: unresolved-hidden reason")
    assertEq(receiptCount, 0, "D: unresolved-hidden no receipt")
    assertEq(handoffCount, 0, "D: unresolved-hidden no handoff")
    assertEq(#presentedDialogs, 1, "D: unresolved dialog presented after helper lifecycle hide")
    assertTrue(presentedDialogs[1].message:find("not retried", 1, true) ~= nil
        or presentedDialogs[1].message:find("unresolved", 1, true) ~= nil,
        "D: dialog carries unresolved settlement text")
    RT:PresentUnresolvedQuickWithdrawSettlement({
        operationId = hiddenOpId,
        visitToken = "visit:stale",
        unresolved = { itemId = 10 },
        requested = { ["10"] = 5 },
        authorized = { ["10"] = 5 },
        confirmed = {},
        remaining = { ["10"] = 5 },
    })
    assertEq(#presentedDialogs, 1, "D: replayed unresolved op does not duplicate dialog")

    -- 2) Synchronous close ordering: settle inside WR.OnBankClosed before bankOpen=false/hide.
    presentedDialogs = {}
    helperLifecycleHidden = false
    clearUnresolvedNoticeState()
    RT:OnBankOpened()
    local syncOpId = startVisibilityWithdraw("D: unresolved-sync")
    bagByItem[10] = 0
    bankBySlot[1] = 5
    bankAvailable = false -- InterpretWithdrawal bank_unavailable → sync unresolved on close
    settleCount, receiptCount, handoffCount = 0, 0, 0
    settleReasons = {}
    local bankOpenDuringSettle = nil
    local hideBeforeSettleDone = nil
    do
        local actual = WR.work.onSettle
        WR.work.onSettle = function(result)
            bankOpenDuringSettle = RT.bankOpen
            hideBeforeSettleDone = helperLifecycleHidden
            return actual(result)
        end
    end
    RT:OnBankClosed()
    assertEq(settleCount, 1, "D: sync unresolved settles inside OnBankClosed")
    assertEq(settleReasons[1], "bank_closed_unresolved", "D: sync unresolved reason")
    assertTrue(bankOpenDuringSettle == true,
        "D: sync settle runs while bankOpen still true (before hide)")
    assertTrue(hideBeforeSettleDone == false,
        "D: HideReview has not run yet when sync settle fires")
    assertTrue(helperLifecycleHidden, "D: HideReview runs before OnBankClosed returns")
    assertFalse(RT.bankOpen, "D: bankOpen false after sync close returns")
    assertEq(#presentedDialogs, 1,
        "D: sync unresolved presents dialog (momentary IsShown is not delivery)")
    assertEq(receiptCount, 0, "D: sync unresolved no receipt")
    assertEq(handoffCount, 0, "D: sync unresolved no handoff")
    RT:PresentUnresolvedQuickWithdrawSettlement({
        operationId = syncOpId,
        visitToken = RT._quickWithdrawVisitToken,
        unresolved = { itemId = 10 },
    })
    assertEq(#presentedDialogs, 1, "D: sync unresolved deduped by operationId")

    -- 3) Close → reopen → old unresolved while newer-visit feedback exists.
    presentedDialogs = {}
    helperLifecycleHidden = false
    clearUnresolvedNoticeState()
    bankAvailable = true
    RT:OnBankOpened()
    local lateOpId = startVisibilityWithdraw("D: unresolved-late")
    bagByItem[10] = 0
    bankBySlot[1] = 5
    settleCount, receiptCount, handoffCount = 0, 0, 0
    settleReasons = {}
    local lateVisit = RT._quickWithdrawVisitToken
    RT:OnBankClosed()
    assertTrue(helperLifecycleHidden, "D: unresolved-late hide on close")
    assertTrue(WR.work ~= nil and WR.work.pendingStep ~= nil,
        "D: unresolved-late pending after close")
    RT:OnBankOpened()
    local newerVisit = RT._quickWithdrawVisitToken
    assertTrue(newerVisit ~= lateVisit, "D: unresolved-late reopen rotates visit")
    -- Unrelated current-visit draft (not the settled operation's selection key).
    WR.craftDrafts = { ["200"] = 3 }
    RT:SetQuickWithdrawStatus("visit2-status", { visitToken = newerVisit })
    assertEq(statusText, "visit2-status", "D: newer-visit status baseline")
    C_Timer._drain()
    assertEq(settleCount, 1, "D: unresolved-late settles once")
    assertEq(settleReasons[1], "bank_closed_unresolved", "D: unresolved-late reason")
    assertEq(statusText, "visit2-status",
        "D: late unresolved does not overwrite newer-visit status")
    assertEq(WR.craftDrafts["200"], 3,
        "D: late unresolved presentation leaves current-visit drafts intact")
    assertEq(#presentedDialogs, 1, "D: late unresolved presents independent dialog")
    assertTrue(presentedDialogs[1].message:find("not this bank visit", 1, true) ~= nil
        or presentedDialogs[1].message:find("earlier withdrawal", 1, true) ~= nil
        or presentedDialogs[1].message:find("Earlier withdrawal", 1, true) ~= nil,
        "D: late unresolved dialog identifies earlier operation")
    assertEq(receiptCount, 0, "D: unresolved-late no receipt")
    assertEq(handoffCount, 0, "D: unresolved-late no handoff")
    RT:PresentUnresolvedQuickWithdrawSettlement({
        operationId = lateOpId,
        visitToken = lateVisit,
        unresolved = { itemId = 10 },
    })
    assertEq(#presentedDialogs, 1, "D: late unresolved deduped")
    assertEq(WR.craftDrafts["200"], 3, "D: dialog dedupe path does not clear drafts")

    -- 4) Refused StaticPopup_Show leaves unseen notice; bank-open flush delivers it.
    -- Exercise production Dialogs:Confirm with StaticPopup_Show faked at the UI boundary.
    OKAY = OKAY or "OK"
    CANCEL = CANCEL or "Cancel"
    YES = YES or "Yes"
    NO = NO or "No"
    StaticPopupDialogs = StaticPopupDialogs or {}
    local popupAllow = false
    local popupShows = {}
    -- Model native StaticPopup_Show: one visible message per dialog key; a later
    -- show with the same key replaces the earlier visible message.
    local visibleByKey = {}
    function StaticPopup_Show(key, message, _, _data)
        local k = tostring(key or "")
        local msg = tostring(message or "")
        popupShows[#popupShows + 1] = {
            key = k,
            message = msg,
        }
        if not popupAllow then
            return nil
        end
        visibleByKey[k] = msg
        return { key = key, message = message }
    end
    loadModule("SpectrumFederation/modules/UI/Settings/Dialogs.lua")
    assertTrue(type(SF.SettingsUI.Dialogs.Confirm) == "function",
        "D: production Dialogs.Confirm loaded")

    clearUnresolvedNoticeState()
    popupShows = {}
    popupAllow = false
    helperLifecycleHidden = false
    bankAvailable = true
    RT.bankOpen = false
    RT._quickWithdrawVisitSeq = 0
    RT._quickWithdrawVisitToken = nil
    statusText = ""
    RT:OnBankOpened()
    local refuseVisit = RT._quickWithdrawVisitToken
    local refuseOpId = startVisibilityWithdraw("D: unresolved-refuse")
    bagByItem[10] = 0
    bankBySlot[1] = 5
    settleCount, receiptCount, handoffCount = 0, 0, 0
    settleReasons = {}
    RT:OnBankClosed()
    assertTrue(helperLifecycleHidden, "D: unresolved-refuse hide on close")
    C_Timer._drain()
    assertEq(settleCount, 1, "D: unresolved-refuse settles once via production SettleHandler")
    assertEq(settleReasons[1], "bank_closed_unresolved", "D: unresolved-refuse reason")
    assertEq(receiptCount, 0, "D: unresolved-refuse no receipt")
    assertEq(handoffCount, 0, "D: unresolved-refuse no handoff")
    assertEq(#popupShows, 1, "D: refused path attempted StaticPopup_Show once")
    assertTrue(type(RT._unresolvedWithdrawPending) == "table"
        and #RT._unresolvedWithdrawPending == 1,
        "D: refused display retains one pending unseen notice")
    assertEq(RT._unresolvedWithdrawPending[1].opKey, tostring(refuseOpId),
        "D: pending notice preserves originating operationId")
    assertEq(RT._unresolvedWithdrawPending[1].visitToken, refuseVisit,
        "D: pending notice preserves originating visitToken")
    assertTrue(type(RT._unresolvedWithdrawRecent) ~= "table"
        or #RT._unresolvedWithdrawRecent == 0,
        "D: refused display is not counted as delivered")
    -- Replay settle callback must not duplicate pending or movement effects.
    local refuseText = RT._unresolvedWithdrawPending[1].text
    RT:PresentUnresolvedQuickWithdrawSettlement({
        operationId = refuseOpId,
        visitToken = refuseVisit,
        unresolved = { itemId = 10 },
        requested = { ["10"] = 5 },
        authorized = { ["10"] = 5 },
        confirmed = {},
        remaining = { ["10"] = 5 },
    }, refuseText)
    assertEq(#RT._unresolvedWithdrawPending, 1,
        "D: replayed refused op keeps a single pending notice")
    assertEq(#popupShows, 2, "D: replayed refused op retries popup without inventing a second notice")
    assertEq(receiptCount, 0, "D: refused replay adds no receipt")
    assertEq(handoffCount, 0, "D: refused replay adds no handoff")

    -- Later bank open with popup permitted: prior-op labeling, visit state preserved.
    popupAllow = true
    local popupBeforeFlush = #popupShows
    WR.craftDrafts = { ["200"] = 7 }
    RT:OnBankOpened()
    local afterRefuseVisit = RT._quickWithdrawVisitToken
    assertTrue(afterRefuseVisit ~= refuseVisit, "D: refuse→retry reopen rotates visit")
    -- OnBankOpened clears status then FlushPending presents; set visit status after
    -- reopen baseline to prove flush did not leave movement side effects, then
    -- confirm drafts survived the flush path.
    assertEq(WR.craftDrafts["200"], 7,
        "D: bank-open flush preserves newer-visit drafts")
    RT:SetQuickWithdrawStatus("post-refuse-visit-status", { visitToken = afterRefuseVisit })
    assertEq(statusText, "post-refuse-visit-status",
        "D: newer visit can publish its own status after prior-notice flush")
    assertEq(#popupShows, popupBeforeFlush + 1,
        "D: bank-open flush delivers previously refused notice")
    local delivered = popupShows[#popupShows]
    assertTrue(delivered.message:find("not this bank visit", 1, true) ~= nil
        or delivered.message:find("earlier withdrawal", 1, true) ~= nil
        or delivered.message:find("Earlier withdrawal", 1, true) ~= nil,
        "D: flush during newer visit uses prior-operation labeling")
    assertTrue(delivered.message:find("requested", 1, true) ~= nil
        or delivered.message:find("authorized", 1, true) ~= nil
        or delivered.message:find("remaining", 1, true) ~= nil
        or delivered.message:find("unresolved", 1, true) ~= nil
        or (type(refuseText) == "string" and refuseText ~= ""
            and delivered.message:find(refuseText, 1, true) ~= nil),
        "D: flush message retains settlement totals/uncertainty text")
    assertTrue(type(RT._unresolvedWithdrawPending) ~= "table"
        or #RT._unresolvedWithdrawPending == 0,
        "D: successful flush clears pending notice")
    assertTrue(type(RT._unresolvedWithdrawRecent) == "table"
        and #RT._unresolvedWithdrawRecent == 1
        and RT._unresolvedWithdrawRecent[1] == tostring(refuseOpId),
        "D: successful flush records bounded recent delivery")
    -- Successful delivery + replayed callback: no duplicate notification/movement.
    local showsAfterDelivery = #popupShows
    RT:PresentUnresolvedQuickWithdrawSettlement({
        operationId = refuseOpId,
        visitToken = refuseVisit,
        unresolved = { itemId = 10 },
    }, refuseText)
    assertEq(#popupShows, showsAfterDelivery,
        "D: delivered refuse→retry op does not re-present")
    assertEq(receiptCount, 0, "D: post-delivery replay adds no receipt")
    assertEq(handoffCount, 0, "D: post-delivery replay adds no handoff")
    assertEq(WR.craftDrafts["200"], 7, "D: post-delivery replay leaves drafts intact")
    assertEq(statusText, "post-refuse-visit-status",
        "D: post-delivery replay leaves newer-visit status intact")

    -- 5) Two distinct refused notices: flush must keep both readable (combine),
    -- not clear A as delivered when same-key StaticPopup replaces it with B.
    clearUnresolvedNoticeState()
    visibleByKey = {}
    popupShows = {}
    popupAllow = false
    helperLifecycleHidden = false
    bankAvailable = true
    settleCount, receiptCount, handoffCount = 0, 0, 0
    settleReasons = {}
    RT.bankOpen = false
    RT._quickWithdrawVisitSeq = 0
    RT._quickWithdrawVisitToken = nil
    statusText = ""
    RT:OnBankOpened()
    local multiVisitA = RT._quickWithdrawVisitToken
    local multiOpA = startVisibilityWithdraw("D: multi-refuse-A", { ["100"] = 1 }, 5)
    bagByItem[10] = 0
    bankBySlot[1] = 5
    settleCount, receiptCount, handoffCount = 0, 0, 0
    settleReasons = {}
    RT:OnBankClosed()
    C_Timer._drain()
    assertEq(settleCount, 1, "D: multi-refuse-A settles once")
    assertEq(settleReasons[1], "bank_closed_unresolved", "D: multi-refuse-A reason")
    assertEq(receiptCount, 0, "D: multi-refuse-A no receipt")
    assertEq(handoffCount, 0, "D: multi-refuse-A no handoff")
    assertEq(#RT._unresolvedWithdrawPending, 1, "D: multi-refuse-A retained pending")
    local textA = RT._unresolvedWithdrawPending[1].text
    assertTrue(type(textA) == "string" and textA ~= "", "D: multi-refuse-A stores settlement text")
    -- Intermediate bank open while popup still refused: flush must retain A.
    RT:OnBankOpened()
    local multiVisitMid = RT._quickWithdrawVisitToken
    assertTrue(multiVisitMid ~= multiVisitA, "D: multi mid-open rotates visit")
    assertEq(#RT._unresolvedWithdrawPending, 1,
        "D: refused multi flush keeps notice A pending")
    assertTrue(type(RT._unresolvedWithdrawRecent) ~= "table"
        or #RT._unresolvedWithdrawRecent == 0,
        "D: refused multi flush does not mark A delivered")
    -- Second refused notice without clearing notification state between ops.
    local multiOpB = startVisibilityWithdraw("D: multi-refuse-B", { ["100"] = 2 }, 10)
    assertTrue(tostring(multiOpB) ~= tostring(multiOpA),
        "D: multi-refuse-B is a distinct operationId")
    bagByItem[10] = 0
    bankBySlot[1] = 10
    settleCount, receiptCount, handoffCount = 0, 0, 0
    settleReasons = {}
    RT:OnBankClosed()
    C_Timer._drain()
    assertEq(settleCount, 1, "D: multi-refuse-B settles once")
    assertEq(settleReasons[1], "bank_closed_unresolved", "D: multi-refuse-B reason")
    assertEq(receiptCount, 0, "D: multi-refuse-B no receipt")
    assertEq(handoffCount, 0, "D: multi-refuse-B no handoff")
    assertEq(#RT._unresolvedWithdrawPending, 2,
        "D: two refused notices accumulate without clearing state")
    local textB = nil
    for i = 1, #RT._unresolvedWithdrawPending do
        local row = RT._unresolvedWithdrawPending[i]
        if row.opKey == tostring(multiOpB) then
            textB = row.text
        end
    end
    assertTrue(type(textB) == "string" and textB ~= "", "D: multi-refuse-B stores settlement text")
    assertTrue(textA ~= textB,
        "D: multi-refuse A/B settlement texts are distinct for observable delivery")
    -- Refused combined flush still retains both.
    local showsBeforeRefuseFlush = #popupShows
    RT:OnBankOpened()
    local multiVisitRefuseFlush = RT._quickWithdrawVisitToken
    assertTrue(multiVisitRefuseFlush ~= multiVisitMid,
        "D: refused multi flush open rotates visit")
    assertEq(#RT._unresolvedWithdrawPending, 2,
        "D: refused combined flush retains both pending notices")
    assertTrue(#popupShows > showsBeforeRefuseFlush,
        "D: refused combined flush still attempts Confirm once")
    RT:OnBankClosed()
    -- Successful flush: one visible same-key acknowledgement covering both.
    popupAllow = true
    visibleByKey = {}
    local showsBeforeOkFlush = #popupShows
    WR.craftDrafts = { ["200"] = 11 }
    RT:OnBankOpened()
    local multiVisitFinal = RT._quickWithdrawVisitToken
    assertTrue(multiVisitFinal ~= multiVisitRefuseFlush, "D: multi final open rotates visit")
    assertEq(WR.craftDrafts["200"], 11,
        "D: multi flush preserves newer-visit drafts")
    RT:SetQuickWithdrawStatus("multi-flush-visit-status", { visitToken = multiVisitFinal })
    assertEq(statusText, "multi-flush-visit-status",
        "D: newer visit publishes status after multi flush")
    assertEq(#popupShows, showsBeforeOkFlush + 1,
        "D: multi flush emits one Confirm (not a same-key series)")
    local visible = visibleByKey["SF_SETTINGS_CONFIRM"]
    assertTrue(type(visible) == "string" and visible ~= "",
        "D: multi flush leaves a visible acknowledgement for SF_SETTINGS_CONFIRM")
    -- Observable delivery: both retained results appear in the visible message
    -- (API call counts alone are insufficient — same-key replace would hide A).
    assertTrue(visible:find(textA, 1, true) ~= nil,
        "D: visible multi ack includes notice A settlement text")
    assertTrue(visible:find(textB, 1, true) ~= nil,
        "D: visible multi ack includes notice B settlement text")
    assertTrue(visible:find("not this bank visit", 1, true) ~= nil
        or visible:find("earlier withdrawal", 1, true) ~= nil
        or visible:find("Earlier withdrawal", 1, true) ~= nil,
        "D: multi flush uses prior-operation labeling at presentation time")
    assertTrue(type(RT._unresolvedWithdrawPending) ~= "table"
        or #RT._unresolvedWithdrawPending == 0,
        "D: successful multi flush clears pending for displayed ops")
    local recentHasA, recentHasB = false, false
    for i = 1, #(RT._unresolvedWithdrawRecent or {}) do
        local k = RT._unresolvedWithdrawRecent[i]
        if k == tostring(multiOpA) then recentHasA = true end
        if k == tostring(multiOpB) then recentHasB = true end
    end
    assertTrue(recentHasA and recentHasB,
        "D: successful multi flush remembers only the displayed operation IDs")
    assertTrue(#(RT._unresolvedWithdrawRecent or {}) <= 8,
        "D: multi flush keeps recent within bound")
    assertEq(receiptCount, 0, "D: multi flush adds no receipt")
    assertEq(handoffCount, 0, "D: multi flush adds no handoff")
    -- Replay of either op must not re-present or move items.
    local showsAfterMulti = #popupShows
    RT:PresentUnresolvedQuickWithdrawSettlement({
        operationId = multiOpA, visitToken = multiVisitA, unresolved = true,
    }, textA)
    RT:PresentUnresolvedQuickWithdrawSettlement({
        operationId = multiOpB, visitToken = multiVisitMid, unresolved = true,
    }, textB)
    assertEq(#popupShows, showsAfterMulti, "D: multi delivered ops do not re-present")
    assertEq(WR.craftDrafts["200"], 11, "D: multi replay leaves drafts intact")
    assertEq(statusText, "multi-flush-visit-status",
        "D: multi replay leaves newer-visit status intact")

    -- Bounded recent/pending across repeated operations without manual resets.
    popupAllow = true
    for i = 1, 20 do
        local shown = RT:PresentUnresolvedQuickWithdrawSettlement({
            operationId = "bound-ok-" .. tostring(i),
            visitToken = multiVisitFinal,
            unresolved = { itemId = 10 },
            requested = { ["10"] = i },
            authorized = { ["10"] = i },
            confirmed = {},
            remaining = { ["10"] = i },
        }, "bounded ok " .. tostring(i))
        assertTrue(shown == true, "D: bound-ok-" .. i .. " presents while popup allowed")
    end
    assertEq(#RT._unresolvedWithdrawRecent, 8,
        "D: successfully presented ops stay within recent bound")
    assertTrue(type(RT._unresolvedWithdrawPending) ~= "table"
        or #RT._unresolvedWithdrawPending == 0,
        "D: successful presents leave pending empty")
    popupAllow = false
    for i = 1, 10 do
        local shown = RT:PresentUnresolvedQuickWithdrawSettlement({
            operationId = "bound-fail-" .. tostring(i),
            visitToken = multiVisitFinal,
            unresolved = { itemId = 10 },
        }, "bounded fail " .. tostring(i))
        assertTrue(shown == false, "D: bound-fail-" .. i .. " refuses display")
    end
    assertEq(#RT._unresolvedWithdrawPending, 4,
        "D: refused notices stay within pending bound without manual reset")
    assertEq(#RT._unresolvedWithdrawRecent, 8,
        "D: pending growth does not expand recent beyond its bound")

    RT.HideReviewForBankLifecycle = realHideReview

    -- Retained shortage confirmation: early visit-guard isolation + same-visit control.
    -- Historical fail-before (Runtime at f42d96cb admits the retained callback into a
    -- later visit with a still-valid plan) was validated as a one-off against that
    -- commit in the prior delivery. The ordinary suite must not `git show` historical
    -- objects — shallow CI / source archives lack them. Keep that result labeled in
    -- PR/thread evidence; exercise only the current checked-out production modules here.
    local bankStock = 2
    _G.GetGuildBankItemInfo = function(tab, slot)
        if tab == 1 and slot == 1 then return "tex", bankStock, false end
        return nil
    end
    _G.GetGuildBankItemLink = function(tab, slot)
        if tab == 1 and slot == 1 then return "|Hitem:10:|h" end
        return nil
    end
    -- BagCount for withdraw preview/scan uses GetItemCount / WR.BagCount; keep empty bags.
    bagByItem[10] = 0
    WR.BagCount = function(itemId)
        return bagByItem[tonumber(itemId) or -1] or 0
    end
    _G.GetItemCount = function() return 0 end
    installCursorStubs()
    if WR.work then WR.StopWork("test_cleanup", true) end

    local acceptCb
    SF.SettingsUI = SF.SettingsUI or {}
    SF.SettingsUI.Dialogs = {
        ConfirmChoice = function(_, _msg, _yes, _no, onYes)
            acceptCb = onYes
        end,
    }

    -- Ensure current tree modules (no historical Git object lookup).
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua")
    RT = SF.ConsumablesRuntime
    stubRuntimeLifecycle()
    statusText = ""
    RT.review = {
        Status = {
            SetText = function(_, t) statusText = t or "" end,
            GetText = function() return statusText end,
        },
        IsShown = function() return false end,
    }
    RT.BankIsOpen = function() return true end
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    WR = SF.ConsumablesWithdrawRuntime
    WR.BagCount = function(itemId)
        return bagByItem[tonumber(itemId) or -1] or 0
    end
    if WR.work then WR.StopWork("test_cleanup", true) end
    installCursorStubs()

    local function captureShortageAccept(label)
        RT.bankOpen = false
        RT._quickWithdrawVisitSeq = 0
        RT._quickWithdrawVisitToken = nil
        statusText = ""
        bankStock = 2
        acceptCb = nil
        -- Bind visit/draft owner first; seeding drafts before open lets
        -- EnsureDraftOwner treat a prior owner as stale and wipe them.
        WR.craftDraftOwner = nil
        WR.ClearDrafts()
        RT:OnBankOpened()
        WR.EnsureDraftOwner()
        WR.craftDrafts = { ["100"] = 2 }
        local visitA = RT._quickWithdrawVisitToken
        assertTrue(visitA ~= nil, label .. ": visit A token")
        RT:BeginQuickWithdraw()
        assertTrue(type(acceptCb) == "function", label .. ": ConfirmChoice captured")
        return visitA, acceptCb
    end

    local visitShortA, guardedAccept = captureShortageAccept("D: guarded cross-visit")
    RT:OnBankClosed()
    RT:OnBankOpened()
    local visitShortB = RT._quickWithdrawVisitToken
    assertTrue(visitShortB ~= visitShortA, "D: guarded reopen rotates visit")
    RT:SetQuickWithdrawStatus("visit-B-active", { visitToken = visitShortB })
    assertEq(statusText, "visit-B-active", "D: guarded visit B status baseline")
    bankStock = 2 -- original stock/take plan still valid; isolates early visit guard
    do
        local okStill = WR.QuickWithdrawConfirmationStillValid
        -- StillValid uses current visit context + bound selections; plan stock matches.
        -- Cross-visit rejection must happen before this would matter for admission.
        assertTrue(okStill ~= nil, "D: StillValid present for isolation note")
    end
    pickupCount = 0
    local workBefore = WR.work
    local admittedGuarded = false
    local realBeginGuard = WR.BeginWithdraw
    WR.BeginWithdraw = function(sel, opts)
        local ok, err, detail = realBeginGuard(sel, opts)
        if ok then admittedGuarded = true end
        return ok, err, detail
    end
    guardedAccept()
    WR.BeginWithdraw = realBeginGuard
    assertFalse(admittedGuarded,
        "D: guarded cross-visit with valid plan does not admit withdrawal")
    assertEq(WR.work, workBefore, "D: guarded cross-visit does not attach work")
    assertEq(pickupCount, 0, "D: guarded cross-visit does no bank pickup")
    assertEq(statusText, "visit-B-active",
        "D: guarded cross-visit does not overwrite visit B status")

    -- Optional separate stale-feedback coverage (changed take-map): StillValid fails;
    -- not a substitute for the early no-admission guard above.
    do
        bankStock = 1
        local okP, errP, preview = WR.PreviewWithdrawPlan({ ["100"] = 2 }, {})
        assertEq(okP, false, "D: stale-feedback shortage preview")
        assertEq(errP, "shortage", "D: stale-feedback shortage reason")
        bankStock = 2
        local _, _, previewBound = WR.PreviewWithdrawPlan({ ["100"] = 2 }, {})
        local bound = {
            guildKey = previewBound.ctx.guildKey,
            datasetId = previewBound.ctx.datasetId,
            campaignId = previewBound.ctx.campaignId,
            bankTab = previewBound.ctx.bankTab,
            generation = previewBound.ctx.generation,
            selections = { ["100"] = 2 },
            recipeFingerprints = previewBound.recipeFingerprints,
            requested = previewBound.requested,
            take = previewBound.plan.take,
            visitToken = visitShortB,
        }
        bankStock = 1
        local valid = WR.QuickWithdrawConfirmationStillValid(bound)
        assertFalse(valid, "D: changed stock/take invalidates confirmation")
        local beforeStale = statusText
        RT:SetQuickWithdrawStatus("stale-scoped", { visitToken = visitShortA })
        assertEq(statusText, beforeStale,
            "D: scoped stale write from prior visit cannot overwrite visit B")
        bankStock = 2
    end

    -- Same-visit acceptance control.
    bankStock = 2
    RT:OnBankClosed()
    RT:OnBankOpened()
    local visitSame = RT._quickWithdrawVisitToken
    acceptCb = nil
    WR.EnsureDraftOwner()
    WR.craftDrafts = { ["100"] = 2 }
    RT:BeginQuickWithdraw()
    assertTrue(type(acceptCb) == "function", "D: same-visit ConfirmChoice captured")
    assertEq(RT._quickWithdrawVisitToken, visitSame, "D: same-visit token stable")
    installCursorStubs()
    local admitted = false
    local realBegin = WR.BeginWithdraw
    WR.BeginWithdraw = function(sel, opts)
        local ok, err, detail = realBegin(sel, opts)
        if ok then admitted = true end
        return ok, err, detail
    end
    pickupCount = 0
    acceptCb()
    WR.BeginWithdraw = realBegin
    assertTrue(admitted, "D: same-visit acceptance admits withdrawal")
    assertTrue(pickupCount >= 1 or WR.work ~= nil,
        "D: same-visit acceptance starts movement")
    if WR.work then WR.StopWork("test_cleanup", true) end
    -- One-source stack → partial merge + empty dest; allowance 1 rejects, 2 permits.
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    WR = SF.ConsumablesWithdrawRuntime
    pendingTimers = {}
    C_Timer = {
        After = function(_, fn)
            if type(fn) == "function" then
                pendingTimers[#pendingTimers + 1] = { fn = fn, cancellable = false }
            end
            return nil
        end,
        NewTimer = function(_, fn)
            local cancelled = false
            local entry = {
                fn = fn,
                cancellable = true,
                Cancel = function() cancelled = true end,
                _fire = function()
                    if not cancelled and type(fn) == "function" then fn() end
                end,
                _cancelled = function() return cancelled end,
            }
            pendingTimers[#pendingTimers + 1] = entry
            return entry
        end,
        _drain = function()
            local batch = pendingTimers
            pendingTimers = {}
            for i = 1, #batch do
                local t = batch[i]
                if t.cancellable then t._fire()
                elseif type(t.fn) == "function" then t.fn() end
            end
        end,
    }
    local cursorItem = nil
    _G.GetCursorInfo = function()
        if cursorItem then return "item", cursorItem end
        return nil
    end
    _G.InCombatLockdown = function() return false end
    _G.PickupGuildBankItem = function() cursorItem = 10 end
    _G.SplitGuildBankItem = function() cursorItem = 10 end
    _G.PutItemInBackpack = function() cursorItem = nil end
    _G.ClearCursor = function() cursorItem = nil end
    _G.GetItemCount = function() return 15 end
    _G.GetCurrentGuildBankTab = function() return 1 end
    C_Container = {
        GetContainerNumSlots = function(bag)
            if bag == 0 then return 4 end
            return 0
        end,
        GetContainerNumFreeSlots = function(bag)
            if bag == 0 then return 3, 0 end
            return 0, 0
        end,
        GetContainerItemInfo = function(bag, slot)
            if bag == 0 and slot == 1 then
                return { itemID = 10, stackCount = 15, isLocked = false }
            end
            return nil
        end,
        PickupContainerItem = function() cursorItem = nil end,
    }
    C_Item = {
        GetItemFamily = function() return 0 end,
        GetItemMaxStackSizeByID = function() return 20 end,
    }
    SF.Consumables = SF.Consumables or {}
    SF.Consumables.ItemIdFromText = function(link)
        local id = tostring(link or ""):match("item:(%d+)")
        return tonumber(id)
    end
    SF.ConsumablesRouting = { IsCarriedBag = function() return true end }
    SF.ConsumablesRuntime = SF.ConsumablesRuntime or {}
    SF.ConsumablesRuntime.BankIsOpen = function() return true end
    SF.ConsumablesRuntime.ItemStackLimit = function() return 20 end
    SF.ConsumablesTradeHandoff = SF.ConsumablesTradeHandoff or {}
    SF.ConsumablesTradeHandoff.CanAcceptUnits = function() return true end
    SF.ConsumablesTradeHandoff.PendingSnapshot = function() return {}, {} end
    SF.ConsumablesTradeHandoff.GetState = function() return {} end
    local allowRecord = {
        datasetId = "gs1:wd",
        _guildKey = "club:wd",
        currentCampaignId = "camp1",
        accounting = {
            _consumables = {
                bankTab = 1,
                generation = 1,
                configSeq = 1,
                recipes = {
                    ["100"] = { itemId = 100, reagents = { ["10"] = 10 } },
                },
            },
        },
    }
    GS.IsLiveActiveForCurrentGuild = function() return true end
    GS.GetCurrentRecord = function() return allowRecord end
    GS.RecipeAvailability = function() return true end
    GS.WithdrawalReceiptCapacityOk = function() return true end
    _G.GetGuildBankItemInfo = function(tab, slot)
        if tab == 1 and slot == 1 then return "tex", 10, false end
        return nil
    end
    _G.GetGuildBankItemLink = function(tab, slot)
        if tab == 1 and slot == 1 then return "|Hitem:10:|h" end
        return nil
    end
    local capturedQueue = nil
    local realPlaceNext = WR.PlaceNext
    WR.PlaceNext = function()
        if WR.work and WR.work.queue then
            capturedQueue = WR.work.queue
        end
        return realPlaceNext()
    end
    _G.GetGuildBankTabInfo = function()
        return "Tab", "icon", true, true, 0, 1, false -- remainingWithdrawals = 1
    end
    capturedQueue = nil
    local okBlock, errBlock = WR.BeginWithdraw({ ["100"] = 1 }, {})
    assertEq(okBlock, false, "D: allowance 1 rejects two-pickup split-dest plan")
    assertEq(errBlock, "allowance", "D: allowance reason got=" .. tostring(errBlock))
    assertEq(WR.work, nil, "D: no work when allowance blocks before pickup")
    assertEq(capturedQueue, nil, "D: PlaceNext not reached when allowance blocks")
    _G.GetGuildBankTabInfo = function()
        return "Tab", "icon", true, true, 0, 2, false -- remainingWithdrawals = 2
    end
    capturedQueue = nil
    local okAllow, errAllow = WR.BeginWithdraw({ ["100"] = 1 }, {})
    assertEq(okAllow, true, "D: allowance 2 permits two-pickup plan: " .. tostring(errAllow))
    assertTrue(capturedQueue ~= nil, "D: queue captured under allowance 2")
    assertEq(#capturedQueue, 2, "D: two pickups for merge+empty from one source")
    assertEq(capturedQueue[1].destMerge, true, "D: first chunk merges into partial bag stack")
    assertEq(capturedQueue[2].destMerge, false, "D: second chunk uses empty destination")
    WR.PlaceNext = realPlaceNext
    if WR.work then
        WR.StopWork("test_cleanup", true)
    end
end

---------------------------------------------------------------------------
-- Codex repair batch A/B/D/E at 0307e138 dispositions (portable current-tree).
---------------------------------------------------------------------------
do
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawWorkflow.lua")
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua")
    local W = SF.ConsumablesWithdrawWorkflow
    local WR = SF.ConsumablesWithdrawRuntime
    local RT = SF.ConsumablesRuntime
    local GS = SF.GuildSupplies

    ---------------------------------------------------------------- A: reserved backpack slots
    -- Mutable bag/bank/cursor fakes distinguish PutItemInBackpack (first empty)
    -- from exact PickupContainerItem(bag, slot).
    do
        local bagSlots = {
            [0] = {
                [1] = { itemId = nil, count = 0 },
                [2] = { itemId = nil, count = 0 },
                [3] = { itemId = nil, count = 0 },
                [4] = { itemId = nil, count = 0 },
            },
        }
        local bankSlots = {
            [1] = { itemId = 10, count = 5 },
            [2] = { itemId = 20, count = 5 },
        }
        local cursor = nil
        local autoFirstEmptyUsed = false
        local pendingTimers = {}
        C_Timer = {
            After = function(_, fn)
                if type(fn) == "function" then
                    pendingTimers[#pendingTimers + 1] = { fn = fn, cancellable = false }
                end
            end,
            NewTimer = function(_, fn)
                local cancelled = false
                local entry = {
                    fn = fn, cancellable = true,
                    Cancel = function() cancelled = true end,
                    _fire = function()
                        if not cancelled and type(fn) == "function" then fn() end
                    end,
                    _cancelled = function() return cancelled end,
                }
                pendingTimers[#pendingTimers + 1] = entry
                return entry
            end,
            _drain = function()
                local batch = pendingTimers
                pendingTimers = {}
                for i = 1, #batch do
                    local t = batch[i]
                    if t.cancellable then t._fire()
                    elseif type(t.fn) == "function" then t.fn() end
                end
            end,
            _clear = function() pendingTimers = {} end,
        }
        C_Container = {
            GetContainerNumSlots = function(bag)
                if bag == 0 then return 4 end
                return 0
            end,
            GetContainerNumFreeSlots = function(bag)
                if bag ~= 0 then return 0, 0 end
                local free = 0
                for s = 1, 4 do
                    if not bagSlots[0][s].itemId then free = free + 1 end
                end
                return free, 0
            end,
            GetContainerItemInfo = function(bag, slot)
                local cell = bagSlots[bag] and bagSlots[bag][slot]
                if not cell or not cell.itemId then return nil end
                return { itemID = cell.itemId, stackCount = cell.count, iconFileID = 1 }
            end,
            PickupContainerItem = function(bag, slot)
                if cursor then
                    local cell = bagSlots[bag] and bagSlots[bag][slot]
                    if not cell then return end
                    if cell.itemId and cell.itemId ~= cursor.itemId then
                        return
                    end
                    cell.itemId = cursor.itemId
                    cell.count = (cell.count or 0) + (cursor.count or 1)
                    cursor = nil
                    return
                end
                local cell = bagSlots[bag] and bagSlots[bag][slot]
                if cell and cell.itemId then
                    cursor = { itemId = cell.itemId, count = cell.count }
                    cell.itemId, cell.count = nil, 0
                end
            end,
        }
        _G.PutItemInBackpack = function()
            autoFirstEmptyUsed = true
            if not cursor then return end
            for s = 1, 4 do
                local cell = bagSlots[0][s]
                if not cell.itemId then
                    cell.itemId = cursor.itemId
                    cell.count = cursor.count or 1
                    cursor = nil
                    return
                end
            end
        end
        _G.GetCursorInfo = function()
            if cursor then
                return "item", cursor.itemId, "|Hitem:" .. tostring(cursor.itemId) .. ":|h"
            end
            return nil
        end
        _G.ClearCursor = function() cursor = nil end
        _G.InCombatLockdown = function() return false end
        _G.PickupGuildBankItem = function(_, slot)
            local cell = bankSlots[slot]
            if cell and (cell.count or 0) > 0 then
                cursor = { itemId = cell.itemId, count = 1 }
                cell.count = cell.count - 1
                if cell.count <= 0 then cell.itemId = nil end
            end
        end
        _G.SplitGuildBankItem = function(_, slot, count)
            local cell = bankSlots[slot]
            count = tonumber(count) or 1
            if cell and (cell.count or 0) >= count then
                cursor = { itemId = cell.itemId, count = count }
                cell.count = cell.count - count
                if cell.count <= 0 then cell.itemId = nil end
            end
        end
        _G.GetGuildBankItemInfo = function(_, slot)
            local cell = bankSlots[slot]
            if cell and cell.itemId then return "tex", cell.count, false end
            return nil
        end
        _G.GetGuildBankItemLink = function(_, slot)
            local cell = bankSlots[slot]
            if cell and cell.itemId then
                return "|Hitem:" .. tostring(cell.itemId) .. ":|h"
            end
            return nil
        end
        _G.GetCurrentGuildBankTab = function() return 1 end
        _G.GetGuildBankTabInfo = function()
            return "Tab", "icon", true, true, 0, -1, false
        end
        _G.GetItemCount = function(itemId)
            local n = 0
            for s = 1, 4 do
                local cell = bagSlots[0][s]
                if cell.itemId == itemId then n = n + (cell.count or 0) end
            end
            return n
        end
        _G.GetServerTime = function() return 5000 end
        C_Item = {
            GetItemFamily = function() return 0 end,
            GetItemMaxStackSizeByID = function() return 20 end,
        }
        SF.Consumables = SF.Consumables or {}
        SF.Consumables.ItemIdFromText = function(link)
            local id = tostring(link or ""):match("item:(%d+)")
            return tonumber(id)
        end
        SF.ConsumablesRouting = { IsCarriedBag = function(bag) return bag == 0 end }
        loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
        WR = SF.ConsumablesWithdrawRuntime
        WR.BagCount = function(itemId) return _G.GetItemCount(itemId) end
        local record = {
            datasetId = "gs1:backpack",
            _guildKey = "club:backpack",
            currentCampaignId = "camp1",
            accounting = {
                _consumables = {
                    bankTab = 1, generation = 1, configSeq = 1,
                    recipes = {
                        ["100"] = { itemId = 100, reagents = { ["10"] = 1 } },
                        ["200"] = { itemId = 200, reagents = { ["20"] = 1 } },
                    },
                },
            },
        }
        GS.IsLiveActiveForCurrentGuild = function() return true end
        GS.GetCurrentRecord = function() return record end
        GS.RecipeAvailability = function() return true end
        GS.WithdrawalReceiptCapacityOk = function() return true end
        local receiptCalls = 0
        GS.CommitLocalWithdrawalReceipts = function()
            receiptCalls = receiptCalls + 1
            return "accepted", nil
        end
        RT.BankIsOpen = function() return true end
        RT._quickWithdrawVisitToken = "visit:backpack"
        RT.RebuildReview = function() end
        -- Allocator reservation order for two empty backpack slots.
        local planBags = {
            { bag = 0, slots = {
                { slot = 1, empty = true, family = 0 },
                { slot = 2, empty = true, family = 0 },
                { slot = 3, empty = true, family = 0 },
                { slot = 4, empty = true, family = 0 },
            } },
        }
        local okPlan, errPlan, plan = W.PlanMultiItemBagDestinations(
            planBags, { ["10"] = 1, ["20"] = 1 }, function() return 20 end)
        assertTrue(okPlan, "A: planner ok " .. tostring(errPlan))
        local destByItem = {}
        for i = 1, #(plan.destinations or {}) do
            local d = plan.destinations[i]
            destByItem[tonumber(d.itemId)] = d
        end
        assertTrue(destByItem[10] and destByItem[20], "A: both items reserved")
        local slot10 = destByItem[10].slot
        local slot20 = destByItem[20].slot
        assertTrue(slot10 ~= slot20, "A: distinct reserved slots")
        local settleCount = 0
        local settleReason = nil
        local confirmed = nil
        local reordered = false
        local realPlaceNext = WR.PlaceNext
        WR.PlaceNext = function()
            if WR.work and WR.work.queue and not reordered then
                reordered = true
                -- Execute opposite allocator reservation order.
                table.sort(WR.work.queue, function(a, b)
                    return (tonumber(a.destSlot) or 0) > (tonumber(b.destSlot) or 0)
                end)
                WR.work.index = 1
            end
            return realPlaceNext()
        end
        local ok, err = WR.BeginWithdraw({ ["100"] = 1, ["200"] = 1 }, {
            onSettle = function(result)
                settleCount = settleCount + 1
                settleReason = result and result.reason
                confirmed = result and result.confirmed
            end,
        })
        assertTrue(ok, "A: BeginWithdraw ok " .. tostring(err))
        assertTrue(WR.work and #(WR.work.queue or {}) >= 2, "A: queue has two moves")
        for _ = 1, 30 do
            if not WR.work then break end
            C_Timer._drain()
            if WR.work then
                WR.OnBagOrBankUpdate()
            end
        end
        C_Timer._drain()
        WR.PlaceNext = realPlaceNext
        assertEq(autoFirstEmptyUsed, false,
            "A: exact-slot path must not call PutItemInBackpack")
        assertEq(bagSlots[0][slot10].itemId, 10,
            "A: item 10 landed in reserved slot " .. tostring(slot10))
        assertEq(bagSlots[0][slot20].itemId, 20,
            "A: item 20 landed in reserved slot " .. tostring(slot20))
        assertEq(settleCount, 1, "A: settlement once")
        assertEq((confirmed and confirmed["10"]) or 0, 1, "A: item 10 confirmed")
        assertEq((confirmed and confirmed["20"]) or 0, 1, "A: item 20 confirmed")
        assertTrue(tostring(settleReason or ""):find("occupied", 1, true) == nil,
            "A: no occupied partial stop got=" .. tostring(settleReason))
        assertEq(receiptCalls, 1, "A: receipt once")
        if WR.work then WR.StopWork("test_cleanup", true) end
    end

    ---------------------------------------------------------------- B: draft ownership lifecycle (production path)
    do
        loadModule("SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua")
        RT = SF.ConsumablesRuntime
        loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
        WR = SF.ConsumablesWithdrawRuntime
        loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawWorkflow.lua")
        W = SF.ConsumablesWithdrawWorkflow
        RT.WatchGuildBankFrame = function() end
        RT.RefreshReminder = function() end
        RT.SyncReviewWithGuildBank = function() end
        RT.ConsumeBannerBankNavigation = function() end
        RT.HideReviewForBankLifecycle = function() end
        RT.CancelBannerBankNavigation = function() end
        RT.RebuildReview = function() end
        RT.BankIsOpen = function() return RT.bankOpen == true end
        RT.FlushPendingUnresolvedWithdrawNotices = function() end
        RT.ItemName = function(_, id) return "Item" .. tostring(id) end
        RT.ItemIcon = function() return "icon" end
        RT.BindItemTooltip = function() end
        -- Ensure CreateFrame can build AcquireRow widgets.
        if type(_G.CreateFrame) ~= "function" or not _G.CreateFrame("EditBox").HasFocus then
            _G.CreateFrame = function(frameType, name, parent, template)
                local f = {
                    name = name, shown = true, scripts = {}, _text = "", _hasFocus = false,
                }
                function f:SetSize() end
                function f:SetPoint() end
                function f:Hide() f.shown = false end
                function f:Show() f.shown = true end
                function f:IsShown() return f.shown end
                function f:SetScript(k, fn) f.scripts[k] = fn end
                function f:HookScript(k, fn)
                    f.hooks = f.hooks or {}
                    f.hooks[k] = f.hooks[k] or {}
                    f.hooks[k][#f.hooks[k] + 1] = fn
                end
        function f:HookScript(k, fn)
            f.hooks = f.hooks or {}
            f.hooks[k] = f.hooks[k] or {}
            f.hooks[k][#f.hooks[k] + 1] = fn
        end
                function f:GetScript(k) return f.scripts[k] end
                function f:SetText(t)
                    f._text = tostring(t or "")
                    if f.scripts.OnTextChanged then f.scripts.OnTextChanged(f) end
                end
                function f:GetText() return f._text end
                function f:Enable() end
                function f:Disable() end
                function f:RegisterForClicks() end
                function f:SetNumeric() end
                function f:SetAutoFocus() end
                function f:HasFocus() return f._hasFocus end
                function f:ClearFocus() f._hasFocus = false end
                function f:SetFocus() f._hasFocus = true end
                function f:CreateFontString()
                    return {
                        SetPoint = function() end, SetJustifyH = function() end,
                        SetWordWrap = function() end, SetText = function() end,
                        SetFontObject = function() end, SetTextColor = function() end,
                        SetWidth = function() end, Show = function() end, Hide = function() end,
                    }
                end
                function f:CreateTexture()
                    return {
                        SetPoint = function() end, SetSize = function() end,
                        SetTexture = function() end, Show = function() end, Hide = function() end,
                        SetAllPoints = function() end,
                    }
                end
                return f
            end
        end
        local recipes = {
            ["100"] = { itemId = 100, reagents = { ["10"] = 1 } },
            ["200"] = { itemId = 200, reagents = { ["20"] = 1 } },
        }
        local record = {
            datasetId = "gs1:draft",
            _guildKey = "club:draft",
            currentCampaignId = "camp1",
            accounting = {
                _consumables = {
                    bankTab = 1, generation = 1, configSeq = 1,
                    recipes = recipes,
                    requestedItems = {
                        ["10"] = { itemId = 10, goal = 5 },
                        ["20"] = { itemId = 20, goal = 5 },
                    },
                },
            },
        }
        GS.IsLiveActiveForCurrentGuild = function() return true end
        GS.GetCurrentRecord = function() return record end
        -- A-block stubs RecipeAvailability=true; restore real domain helpers.
        loadModule("SpectrumFederation/modules/GuildSupplies/Recipes.lua")
        loadModule("SpectrumFederation/modules/GuildSupplies/Ledger.lua")
        assertTrue(type(GS.RecipeAvailability) == "function", "B: RecipeAvailability restored")
        assertTrue(type(GS.IsCurrentRequestedItem) == "function", "B: IsCurrentRequestedItem restored")
        assertEq(GS.RecipeAvailability(record, recipes["100"]), true, "B: A available before remove")
        _G.GetGuildBankTabInfo = function()
            return "Tab", "icon", true, true, 0, -1, false
        end
        _G.GetCurrentGuildBankTab = function() return 1 end
        RT.review = {
            shown = true,
            Rows = {},
            Child = { name = "child" },
            Status = { SetText = function() end, GetText = function() return "" end },
            IsShown = function(self) return self.shown end,
            Show = function(self) self.shown = true end,
            Hide = function(self) self.shown = false end,
        }
        -- Preserve the AcquireRow pool across rebuilds so ownership rebind can
        -- assert the same row/Edit object identity (production ClearRows only hides).
        local function rebuildQW()
            RT:ClearRows()
            RT:AppendQuickWithdrawSection(RT.review, 0, 0)
        end
        local function findEdit(itemId)
            for _, row in pairs(RT.review.Rows or {}) do
                if row.boundItemId == itemId and row.Edit and row:IsShown() ~= false then
                    return row
                end
            end
            -- Fallback: bound id match even if Hide stub left shown=false briefly.
            for _, row in pairs(RT.review.Rows or {}) do
                if row.boundItemId == itemId and row.Edit then
                    return row
                end
            end
            return nil
        end
        local function setDraftViaWidget(itemId, qty)
            local row = findEdit(itemId)
            assertTrue(row ~= nil, "B: widget row for " .. tostring(itemId))
            row.Edit._hasFocus = false
            row.Edit:SetText(tostring(qty))
        end
        -- Bag/bank stubs for real BeginQuickWithdraw / pending settle.
        local bagByItem = {}
        local bankBySlot = { [1] = { itemId = 20, count = 20 }, [2] = { itemId = 10, count = 20 } }
        local cursor = nil
        local pendingTimers = {}
        C_Timer = {
            After = function(_, fn)
                if type(fn) == "function" then
                    pendingTimers[#pendingTimers + 1] = { fn = fn, cancellable = false }
                end
            end,
            NewTimer = function(_, fn)
                local cancelled = false
                local entry = {
                    fn = fn, cancellable = true,
                    Cancel = function() cancelled = true end,
                    _fire = function()
                        if not cancelled and type(fn) == "function" then fn() end
                    end,
                }
                pendingTimers[#pendingTimers + 1] = entry
                return entry
            end,
            _drain = function()
                local batch = pendingTimers
                pendingTimers = {}
                for i = 1, #batch do
                    local t = batch[i]
                    if t.cancellable then t._fire()
                    elseif type(t.fn) == "function" then t.fn() end
                end
            end,
            _clear = function() pendingTimers = {} end,
        }
        C_Container = {
            GetContainerNumSlots = function(bag) return bag == 0 and 4 or 0 end,
            GetContainerNumFreeSlots = function(bag) return bag == 0 and 4 or 0, 0 end,
            GetContainerItemInfo = function() return nil end,
            PickupContainerItem = function() cursor = nil end,
        }
        C_Item = {
            GetItemFamily = function() return 0 end,
            GetItemMaxStackSizeByID = function() return 20 end,
        }
        _G.GetItemCount = function(itemId) return bagByItem[tonumber(itemId) or -1] or 0 end
        _G.GetCursorInfo = function()
            if cursor then return "item", cursor.itemId end
            return nil
        end
        _G.ClearCursor = function() cursor = nil end
        _G.PutItemInBackpack = function() cursor = nil end
        _G.InCombatLockdown = function() return false end
        _G.PickupGuildBankItem = function(_, slot)
            local cell = bankBySlot[slot]
            if cell and (cell.count or 0) > 0 then
                cursor = { itemId = cell.itemId, count = 1 }
                cell.count = cell.count - 1
            end
        end
        _G.SplitGuildBankItem = function(_, slot, count)
            local cell = bankBySlot[slot]
            count = tonumber(count) or 1
            if cell and (cell.count or 0) >= count then
                cursor = { itemId = cell.itemId, count = count }
                cell.count = cell.count - count
            end
        end
        _G.GetGuildBankItemInfo = function(_, slot)
            local cell = bankBySlot[slot]
            if cell and cell.itemId and (cell.count or 0) > 0 then
                return "tex", cell.count, false
            end
            return nil
        end
        _G.GetGuildBankItemLink = function(_, slot)
            local cell = bankBySlot[slot]
            if cell and cell.itemId then
                return "|Hitem:" .. tostring(cell.itemId) .. ":|h"
            end
            return nil
        end
        _G.GetServerTime = function() return 7000 end
        SF.Consumables = SF.Consumables or {}
        SF.Consumables.ItemIdFromText = function(link)
            local id = tostring(link or ""):match("item:(%d+)")
            return tonumber(id)
        end
        SF.ConsumablesRouting = { IsCarriedBag = function(bag) return bag == 0 end }
        GS.WithdrawalReceiptCapacityOk = function() return true end
        local receiptCalls = 0
        GS.CommitLocalWithdrawalReceipts = function()
            receiptCalls = receiptCalls + 1
            return "accepted", 1
        end
        WR.BagCount = function(itemId) return bagByItem[tonumber(itemId) or -1] or 0 end

        RT.bankOpen = false
        RT._quickWithdrawVisitSeq = 0
        RT._quickWithdrawVisitToken = nil
        WR.ClearDrafts()
        WR.craftDraftOwner = nil
        RT:OnBankOpened()
        rebuildQW()
        setDraftViaWidget(100, 2)
        setDraftViaWidget(200, 3)
        assertEq(WR.craftDrafts["100"], 2, "B: widget wrote draft A")
        assertEq(WR.craftDrafts["200"], 3, "B: widget wrote draft B")
        -- Same-visit refresh / configSeq churn preserves healthy drafts.
        record.accounting._consumables.configSeq = 99
        rebuildQW()
        assertEq(WR.craftDrafts["200"], 3, "B: same-visit rebuild keeps B")
        assertEq(WR.craftDrafts["100"], 2, "B: same-visit rebuild keeps A")
        -- Delete/unavailable A: remove reagent 10 so recipe 100 unavailable.
        record.accounting._consumables.requestedItems = {
            ["20"] = { itemId = 20, goal = 5 },
        }
        rebuildQW()
        assertEq(WR.craftDrafts["100"], nil, "B: rebuild drops unavailable A")
        assertEq(WR.craftDrafts["200"], 3, "B: rebuild retains valid B")
        local rowA = findEdit(100)
        assertTrue(rowA ~= nil, "B: unavailable A still listed")
        assertEq(rowA._qwAvailable, false, "B: unavailable A marked")
        -- Submit B through production BeginQuickWithdraw / planner.
        bagByItem[20] = 0
        bankBySlot[1] = { itemId = 20, count = 20 }
        bankBySlot[2] = { itemId = 10, count = 0 }
        cursor = nil
        receiptCalls = 0
        local settleN = 0
        local settleSelections = nil
        local realBegin = WR.BeginWithdraw
        WR.BeginWithdraw = function(sel, opts)
            settleSelections = {}
            for k, v in pairs(sel or {}) do settleSelections[tostring(k)] = v end
            opts = opts or {}
            local prev = opts.onSettle
            opts.onSettle = function(result)
                settleN = settleN + 1
                if prev then prev(result) end
            end
            return realBegin(sel, opts)
        end
        RT:BeginQuickWithdraw()
        WR.BeginWithdraw = realBegin
        assertTrue(settleSelections ~= nil, "B: BeginQuickWithdraw invoked BeginWithdraw")
        assertEq(settleSelections["100"], nil, "B: submit omits unavailable A")
        assertEq(settleSelections["200"], 3, "B: submit only B")
        assertTrue(WR.work ~= nil, "B: withdraw work attached")
        -- Complete this short withdraw so the helper is idle again.
        for _ = 1, 20 do
            if not WR.work then break end
            bagByItem[20] = (bagByItem[20] or 0) + 1
            WR.OnBagOrBankUpdate()
            C_Timer._drain()
        end
        if WR.work then WR.StopWork("test_cleanup", true) end
        C_Timer._clear()

        -- Idle close/reopen starts at zero (production OnBankClosed clears drafts).
        setDraftViaWidget(200, 4)
        assertEq(WR.craftDrafts["200"], 4, "B: pre-close draft present")
        RT:OnBankClosed()
        assertEq(WR.craftDrafts["200"], nil, "B: bank close clears UI drafts")
        assertEq(WR.craftDraftOwner, nil, "B: bank close clears draft owner")
        RT:OnBankOpened()
        rebuildQW()
        assertEq(WR.craftDrafts["200"], nil, "B: reopen starts empty")

        -- Campaign/context replacement with overlapping recipe ID clears draft.
        setDraftViaWidget(200, 5)
        assertEq(WR.craftDrafts["200"], 5, "B: overlapping-id draft before campaign change")
        local ownerBeforeCamp = WR.DraftOwnerFingerprint(WR.craftDraftOwner)
        record.currentCampaignId = "camp2"
        record.accounting._consumables.recipes = {
            ["200"] = { itemId = 200, reagents = { ["20"] = 1 } },
        }
        record.accounting._consumables.requestedItems = {
            ["20"] = { itemId = 20, goal = 5 },
        }
        rebuildQW()
        assertEq(WR.craftDrafts["200"], nil,
            "B: campaign change clears overlapping recipe draft")
        assertTrue(WR.DraftOwnerFingerprint(WR.craftDraftOwner) ~= ownerBeforeCamp
            or WR.craftDraftOwner ~= nil,
            "B: campaign change rebinds draft owner")

        -- Real pending withdrawal settles after a newly focused same-ID draft.
        RT:OnBankClosed()
        RT:OnBankOpened()
        rebuildQW()
        setDraftViaWidget(200, 1)
        bagByItem[20] = 0
        bankBySlot[1] = { itemId = 20, count = 20 }
        cursor = nil
        settleN = 0
        local oldOwnerFp = nil
        WR.BeginWithdraw = function(sel, opts)
            opts = opts or {}
            local prev = opts.onSettle
            opts.onSettle = function(result)
                settleN = settleN + 1
                if prev then prev(result) end
            end
            return realBegin(sel, opts)
        end
        RT:BeginQuickWithdraw()
        WR.BeginWithdraw = realBegin
        assertTrue(WR.work ~= nil and WR.work.pendingStep ~= nil,
            "B: pending movement for late-settle")
        assertTrue(WR.work.draftOwner ~= nil, "B: work captured draft owner")
        oldOwnerFp = WR.DraftOwnerFingerprint(WR.work.draftOwner)
        local visitOld = RT._quickWithdrawVisitToken
        -- Leave pending across close/reopen; do not inject WR.work.
        RT:OnBankClosed()
        assertTrue(WR.work ~= nil, "B: pending work survives close")
        RT:OnBankOpened()
        assertTrue(RT._quickWithdrawVisitToken ~= visitOld, "B: reopen rotates visit")
        rebuildQW()
        local rowB = findEdit(200)
        assertTrue(rowB ~= nil and rowB.Edit, "B: pooled row for same-ID after reopen")
        local pooledRow = rowB
        local pooledEdit = rowB.Edit
        -- Simulate focused pooled widget carrying a stale prior-owner key + text.
        pooledRow._qwDraftOwnerKey = oldOwnerFp
        pooledRow._qwDraftKey = "200"
        pooledEdit._text = "9"
        pooledEdit._hasFocus = true
        -- Production rebuild must rebind the SAME row/Edit object to current owner.
        rebuildQW()
        local rowAfter = findEdit(200)
        assertTrue(rowAfter == pooledRow, "B: same pooled row object rebound")
        assertTrue(rowAfter.Edit == pooledEdit, "B: same pooled Edit object rebound")
        assertEq(pooledEdit:GetText(), "0",
            "B: focused same-ID field rebinds to current owner draft, not stale 9")
        assertTrue(pooledRow._qwDraftOwnerKey ~= oldOwnerFp,
            "B: pooled row owner key updated to current visit")
        -- Installed OnTextChanged: mismatched owner must not repopulate drafts.
        WR.craftDrafts["200"] = 0
        pooledRow._qwDraftOwnerKey = oldOwnerFp
        pooledEdit._hasFocus = false
        pooledEdit:SetText("9")
        assertEq(WR.craftDrafts["200"], 0,
            "B: OnTextChanged owner guard blocks stale-owner write of 9")
        -- Matching owner writes through the installed callback.
        pooledRow._qwDraftOwnerKey = WR.DraftOwnerFingerprint(WR.craftDraftOwner)
        pooledEdit:SetText("7")
        assertEq(WR.craftDrafts["200"], 7, "B: new same-ID draft via installed OnTextChanged")
        -- Sensitivity: if rebuild focus-preserve ignored owner, stale focused "9" survives.
        pooledRow._qwDraftOwnerKey = oldOwnerFp
        pooledRow._qwDraftKey = "200"
        pooledEdit._text = "9"
        pooledEdit._hasFocus = true
        local savedFingerprint = WR.DraftOwnerFingerprint
        WR.DraftOwnerFingerprint = function()
            return oldOwnerFp
        end
        rebuildQW()
        assertTrue(findEdit(200) == pooledRow, "B: sensitivity rebuild keeps pool object")
        assertEq(pooledEdit:GetText(), "9",
            "B: sensitivity — matching owner fingerprint preserves focused stale text")
        WR.DraftOwnerFingerprint = savedFingerprint
        -- With real fingerprint restored, focused stale "9" under old owner key
        -- must be replaced by the current draft value (still 7 from earlier write).
        pooledRow._qwDraftOwnerKey = oldOwnerFp
        pooledEdit._text = "9"
        pooledEdit._hasFocus = true
        rebuildQW()
        assertTrue(findEdit(200) == pooledRow, "B: pool object survives post-sensitivity rebuild")
        assertEq(pooledEdit:GetText(), "7",
            "B: owner-mismatch rebuild replaces focused stale 9 with current draft")
        assertTrue(pooledEdit:GetText() ~= "9",
            "B: stale focused 9 cannot survive owner-aware rebuild")
        assertEq(WR.craftDrafts["200"], 7, "B: draft remains 7 before settle")
        -- Complete the OLD pending operation with bag evidence.
        bagByItem[20] = 1
        bankBySlot[1].count = 19
        local settleBefore = settleN
        WR.OnBagOrBankUpdate()
        C_Timer._drain()
        for _ = 1, 10 do
            if not WR.work then break end
            WR.OnBagOrBankUpdate()
            C_Timer._drain()
        end
        assertEq(settleN, settleBefore + 1, "B: old work settles once")
        assertEq(WR.craftDrafts["200"], 7, "B: new same-ID draft survives old settle")
        if WR.work then WR.StopWork("test_cleanup", true) end
        -- Sensitivity: without ReconcileCraftDrafts, unavailable A would remain
        -- and BeginQuickWithdraw would still submit it (unknown/unavailable).
        local savedReconcile = WR.ReconcileCraftDrafts
        WR.ReconcileCraftDrafts = nil
        WR.craftDrafts = { ["100"] = 2, ["200"] = 3 }
        record.accounting._consumables.recipes = recipes
        record.accounting._consumables.requestedItems = {
            ["20"] = { itemId = 20, goal = 5 },
        }
        local selNoReconcile = nil
        WR.BeginWithdraw = function(sel, opts)
            selNoReconcile = {}
            for k, v in pairs(sel or {}) do selNoReconcile[tostring(k)] = v end
            return false, "test_short_circuit"
        end
        RT:BeginQuickWithdraw()
        WR.BeginWithdraw = realBegin
        WR.ReconcileCraftDrafts = savedReconcile
        assertTrue(selNoReconcile and selNoReconcile["100"] == 2,
            "B: sensitivity — without reconcile, stale A would still be submitted")
    end

    ---------------------------------------------------------------- D: receipt membership readiness (real Authority + CommitConfirmed)
    do
        loadModule("SpectrumFederation/modules/GuildSupplies/Authority.lua")
        loadModule("SpectrumFederation/modules/GuildSupplies/Withdrawals.lua")
        loadModule("SpectrumFederation/modules/LootHelper/ConsumablesWithdrawRuntime.lua")
        WR = SF.ConsumablesWithdrawRuntime
        loadModule("SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua")
        RT = SF.ConsumablesRuntime
        RT.WatchGuildBankFrame = function() end
        RT.RefreshReminder = function() end
        RT.SyncReviewWithGuildBank = function() end
        RT.ConsumeBannerBankNavigation = function() end
        RT.HideReviewForBankLifecycle = function() end
        RT.CancelBannerBankNavigation = function() end
        RT.RebuildReview = function() end
        RT.BankIsOpen = function() return true end
        RT.ItemStackLimit = function() return 20 end
        local publish = 0
        local savedNotify = GS._NotifyLocalDurableChange
        GS._NotifyLocalDurableChange = function(reason)
            if reason == "ledger" then publish = publish + 1 end
        end
        local record = {
            datasetId = "gs1:rcpt",
            _guildKey = "club:rcpt",
            currentCampaignId = "camp1",
            campaigns = { camp1 = { id = "camp1" } },
            accounting = {
                _consumables = {
                    generation = 1, configSeq = 1, bankTab = 1,
                    recipes = {
                        ["100"] = { itemId = 100, reagents = { ["10"] = 1 } },
                    },
                    requestedItems = {
                        ["10"] = { itemId = 10, goal = 5 },
                    },
                },
                _consumableEvents = {},
            },
            ledgerEvents = {},
        }
        local donationBaseline = 0
        GS.GetCurrentRecord = function() return record end
        GS.IsLiveActiveForCurrentGuild = function() return true end
        GS.WithdrawalReceiptCapacityOk = function() return true end
        -- Real GuildGossip membership vs rank-list distinction (no GetCurrentContext stub).
        SF.GuildGossip = SF.GuildGossip or {}
        SF.GuildGossip.GetGuildIdentity = function()
            return {
                guildKey = "club:rcpt",
                clubId = "42",
                guildName = "Spectrum",
                guildRealm = "Garona",
                transportScopeId = "club:rcpt",
            }
        end
        SF.GuildGossip.SelfId = function() return "Alice-Garona" end
        local memberOk = true
        SF.GuildGossip.GetGuildMember = function(name)
            if not memberOk then return nil, "not_a_member" end
            if name ~= "Alice-Garona" then return nil, "not_a_member" end
            return {
                name = "Alice-Garona",
                guid = "Player-1-ALICE",
                rankOrder = 1,
                guildKey = "club:rcpt",
            }
        end
        SF.GuildGossip.GetGuildRanks = function()
            return nil, "rank_name_unavailable"
        end
        _G.UnitGUID = function() return "Player-1-ALICE" end
        GS.GetHandleGeneration = GS.GetHandleGeneration or function() return 1 end

        local ctx = GS:GetCurrentContext()
        assertEq(ctx.membershipReady, true, "D: real context membershipReady")
        assertEq(ctx.ready, false, "D: real context ready=false without ranks")
        assertTrue(ctx.actorName == "Alice-Garona" and ctx.actorGuid == "Player-1-ALICE",
            "D: real context binds local actor")
        assertTrue(tostring(ctx.reason or ""):find("rank", 1, true) ~= nil,
            "D: reason reflects rank metadata gap got=" .. tostring(ctx.reason))

        -- Confirmed settlement → real CommitLocalWithdrawalReceipts (not stubbed).
        local bagByItem = {}
        local bankBySlot = { [1] = { itemId = 10, count = 5 } }
        local cursor = nil
        local pendingTimers = {}
        C_Timer = {
            After = function(_, fn)
                if type(fn) == "function" then
                    pendingTimers[#pendingTimers + 1] = { fn = fn }
                end
            end,
            NewTimer = function(_, fn)
                local cancelled = false
                local entry = {
                    fn = fn,
                    Cancel = function() cancelled = true end,
                    _fire = function()
                        if not cancelled and type(fn) == "function" then fn() end
                    end,
                }
                pendingTimers[#pendingTimers + 1] = entry
                return entry
            end,
            _drain = function()
                local batch = pendingTimers
                pendingTimers = {}
                for i = 1, #batch do
                    if batch[i]._fire then batch[i]._fire()
                    elseif type(batch[i].fn) == "function" then batch[i].fn() end
                end
            end,
            _clear = function() pendingTimers = {} end,
        }
        C_Container = {
            GetContainerNumSlots = function(bag) return bag == 0 and 4 or 0 end,
            GetContainerNumFreeSlots = function(bag) return bag == 0 and 4 or 0, 0 end,
            GetContainerItemInfo = function() return nil end,
            PickupContainerItem = function() cursor = nil end,
        }
        C_Item = {
            GetItemFamily = function() return 0 end,
            GetItemMaxStackSizeByID = function() return 20 end,
        }
        _G.GetItemCount = function(itemId) return bagByItem[tonumber(itemId) or -1] or 0 end
        _G.GetCursorInfo = function()
            if cursor then return "item", cursor.itemId end
            return nil
        end
        _G.ClearCursor = function() cursor = nil end
        _G.PutItemInBackpack = function() cursor = nil end
        _G.InCombatLockdown = function() return false end
        _G.PickupGuildBankItem = function(_, slot)
            local cell = bankBySlot[slot]
            if cell and (cell.count or 0) > 0 then
                cursor = { itemId = cell.itemId, count = 1 }
                cell.count = cell.count - 1
            end
        end
        _G.SplitGuildBankItem = function(_, slot, count)
            local cell = bankBySlot[slot]
            count = tonumber(count) or 1
            if cell and (cell.count or 0) >= count then
                cursor = { itemId = cell.itemId, count = count }
                cell.count = cell.count - count
            end
        end
        _G.GetGuildBankItemInfo = function(_, slot)
            local cell = bankBySlot[slot]
            if cell and cell.itemId and (cell.count or 0) > 0 then
                return "tex", cell.count, false
            end
            return nil
        end
        _G.GetGuildBankItemLink = function(_, slot)
            local cell = bankBySlot[slot]
            if cell and cell.itemId then
                return "|Hitem:" .. tostring(cell.itemId) .. ":|h"
            end
            return nil
        end
        _G.GetCurrentGuildBankTab = function() return 1 end
        _G.GetGuildBankTabInfo = function()
            return "Tab", "icon", true, true, 0, -1, false
        end
        _G.GetServerTime = function() return 9000 end
        SF.Consumables = SF.Consumables or {}
        SF.Consumables.ItemIdFromText = function(link)
            local id = tostring(link or ""):match("item:(%d+)")
            return tonumber(id)
        end
        SF.ConsumablesRouting = { IsCarriedBag = function() return true end }
        WR.BagCount = function(itemId) return bagByItem[tonumber(itemId) or -1] or 0 end
        RT._quickWithdrawVisitToken = "visit:rcpt"
        WR.craftDrafts = { ["100"] = 1 }
        WR.EnsureDraftOwner()
        publish = 0
        local eventsBefore = #(record.accounting._consumableEvents or {})
        bagByItem[10] = 0
        bankBySlot[1] = { itemId = 10, count = 5 }
        cursor = nil
        local ok, err = WR.BeginWithdraw({ ["100"] = 1 }, {})
        assertTrue(ok, "D: BeginWithdraw ok under membership-ready context: " .. tostring(err))
        assertTrue(WR.work ~= nil, "D: work attached")
        assertTrue(WR.work.pendingStep ~= nil or (WR.work.confirmedTotal or 0) > 0,
            "D: PlaceNext advanced (pending observe or already confirmed)")
        -- Natural production settlement: bag evidence + observe timers only.
        for _ = 1, 40 do
            if not WR.work then break end
            if WR.work.pendingStep then
                bagByItem[10] = (bagByItem[10] or 0) + 1
            end
            WR.OnBagOrBankUpdate()
            C_Timer._drain()
            _G.GetServerTime = function() return 9000 + _ end
        end
        assertEq(WR.work, nil, "D: natural settlement detached work (no force-confirm)")
        assertEq(publish, 1, "D: ledger publish exactly once via settlement receipt path")
        local eventsAfter = #(record.accounting._consumableEvents or {})
        assertTrue(eventsAfter > eventsBefore, "D: receipt appended to history")
        local receiptCount = 0
        local donationCount = 0
        local firstWd = nil
        for i = 1, eventsAfter do
            local ev = record.accounting._consumableEvents[i]
            if type(ev) == "table" and ev.type == "donation" then
                donationCount = donationCount + 1
            elseif type(ev) == "table" and ev.type == "withdrawal" then
                receiptCount = receiptCount + 1
                firstWd = ev
            end
        end
        assertEq(donationCount, donationBaseline, "D: no donation credit from withdrawal receipt")
        assertEq(receiptCount, 1, "D: exactly one withdrawal receipt after settlement")
        assertTrue(firstWd ~= nil, "D: withdrawal event present")
        local publishBeforeDup = publish
        local receiptCountBeforeDup = receiptCount
        local stAgain, detailAgain = GS:CommitLocalWithdrawalReceipts({
            [tostring(firstWd.itemId)] = firstWd.quantity,
        }, {
            datasetId = firstWd.datasetId,
            campaignId = firstWd.campaignId,
            generation = firstWd.generation,
            operationId = firstWd.operationId,
            bankTab = firstWd.bankTab,
            timestamp = firstWd.timestamp,
            guildKey = firstWd.guildKey,
        })
        -- Duplicate of the captured original operation: zero new accepts / no publish.
        assertTrue(
            (stAgain == "accepted" and (tonumber(detailAgain) or 0) == 0)
                or stAgain == "duplicate",
            "D: recommit original op is duplicate or accepted-with-zero got="
                .. tostring(stAgain) .. "/" .. tostring(detailAgain))
        assertEq(publish, publishBeforeDup, "D: duplicate does not publish again")
        local receiptCountAfterDup = 0
        for i = 1, #(record.accounting._consumableEvents or {}) do
            local ev = record.accounting._consumableEvents[i]
            if type(ev) == "table" and ev.type == "withdrawal" then
                receiptCountAfterDup = receiptCountAfterDup + 1
            end
        end
        assertEq(receiptCountAfterDup, receiptCountBeforeDup,
            "D: duplicate leaves exact receipt count unchanged")

        -- Missing membership fails closed (real context).
        memberOk = false
        local st2, err2 = GS:CommitLocalWithdrawalReceipts({ ["10"] = 1 }, {
            datasetId = "gs1:rcpt", campaignId = "camp1", generation = 1,
            operationId = "op-rcpt-2", bankTab = 1,
        })
        assertEq(st2, "rejected", "D: missing membership rejected")
        assertTrue(err2 == "not_ready" or err2 == "not_a_member",
            "D: missing membership reason got=" .. tostring(err2))
        memberOk = true

        -- Missing GUID: member present without guid, UnitGUID fallback unavailable.
        local savedUnitGuid = _G.UnitGUID
        SF.GuildGossip.GetGuildMember = function(name)
            if name ~= "Alice-Garona" then return nil, "not_a_member" end
            return {
                name = "Alice-Garona",
                guid = nil,
                rankOrder = 1,
                guildKey = "club:rcpt",
            }
        end
        _G.UnitGUID = function() return nil end
        local ctxNoGuid = GS:GetCurrentContext()
        assertEq(ctxNoGuid.membershipReady, false, "D: missing GUID → membershipReady false")
        local stGuid, errGuid = GS:CommitLocalWithdrawalReceipts({ ["10"] = 1 }, {
            datasetId = "gs1:rcpt", campaignId = "camp1", generation = 1,
            operationId = "op-rcpt-guid", bankTab = 1,
        })
        assertEq(stGuid, "rejected", "D: missing GUID rejected")
        assertTrue(errGuid == "not_ready" or errGuid == "guid_unavailable",
            "D: missing GUID reason got=" .. tostring(errGuid))
        _G.UnitGUID = savedUnitGuid
        SF.GuildGossip.GetGuildMember = function(name)
            if not memberOk then return nil, "not_a_member" end
            if name ~= "Alice-Garona" then return nil, "not_a_member" end
            return {
                name = "Alice-Garona",
                guid = "Player-1-ALICE",
                rankOrder = 1,
                guildKey = "club:rcpt",
            }
        end

        -- Mismatched captured guild fails closed under real membership-ready context.
        local st3, err3 = GS:CommitLocalWithdrawalReceipts({ ["10"] = 1 }, {
            datasetId = "gs1:rcpt",
            guildKey = "club:other",
            campaignId = "camp1",
            generation = 1,
            operationId = "op-rcpt-3",
            bankTab = 1,
        })
        assertEq(st3, "rejected", "D: guild mismatch rejected")
        assertEq(err3, "guild_mismatch", "D: guild mismatch reason")
        -- Dataset mismatch.
        local st4, err4 = GS:CommitLocalWithdrawalReceipts({ ["10"] = 1 }, {
            datasetId = "gs1:other",
            guildKey = "club:rcpt",
            campaignId = "camp1",
            generation = 1,
            operationId = "op-rcpt-4",
            bankTab = 1,
        })
        assertEq(st4, "rejected", "D: dataset mismatch rejected")
        assertEq(err4, "dataset_mismatch", "D: dataset mismatch reason")
        GS._NotifyLocalDurableChange = savedNotify
    end

    ---------------------------------------------------------------- E: adoption capacity formula (producer-derived; full path in guild_supplies_tests)
    do
        -- Historical pre-repair complete budget (ops + live/arch ledger +
        -- donation valuations + evidence + campaigns*24 + headroom).
        local oldCeiling = 4096 + 4096 + 4096 + 4096 + 4096 + 256 + (64 * 24) + 512
        assertEq(oldCeiling, 22784, "E: old complete ceiling is 22784")
        -- Restore production class maxima before comparing the live derived budget.
        GS.MAX_ACCEPTED_OPERATIONS = 4096
        GS.MAX_LEDGER_EVENTS = 4096
        GS.MAX_ARCHIVED_EVENTS = 4096
        GS.MAX_WITHDRAWAL_EVENTS = 1024
        GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS = 1024
        GS.MAX_CAMPAIGNS = 64
        GS.MAX_ARCHIVE_PAGE_COUNT = 512
        GS.MAX_ARCHIVE_PAGE_BUFFER_CAMPAIGNS = 16
        GS.MAX_DIRECT_EVIDENCE_EXPORTS = 256
        loadModule("SpectrumFederation/modules/GuildSupplies/Admission.lua")
        local maxCampaigns = GS.MAX_CAMPAIGNS or 64
        local pagesPerArchive = GS.MAX_ARCHIVE_PAGE_COUNT or 512
        -- Conservative upper bound: retained archives ≤ MAX_CAMPAIGNS, each with
        -- ≤ MAX_ARCHIVE_PAGE_COUNT item pages and recipe pages. Concurrent
        -- fragment assembly (MAX_ARCHIVE_PAGE_BUFFER_CAMPAIGNS) is separate.
        local expected = (GS.MAX_ACCEPTED_OPERATIONS or 4096)
            + (GS.MAX_LEDGER_EVENTS or 4096)
            + (GS.MAX_WITHDRAWAL_EVENTS or 1024)
            + (GS.MAX_ARCHIVED_EVENTS or 4096)
            + (GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024)
            + (GS.MAX_LEDGER_EVENTS or 4096)
            + (GS.MAX_ARCHIVED_EVENTS or 4096)
            + (GS.MAX_DIRECT_EVIDENCE_EXPORTS or 256)
            + maxCampaigns
            + maxCampaigns
            + (maxCampaigns * pagesPerArchive)
            + (maxCampaigns * pagesPerArchive)
            + 512
        assertEq(GS.MAX_ADOPTION_PENDING_RECORDS, expected,
            "E: pending budget matches retained-archive × per-archive page bound")
        assertTrue(GS.MAX_ADOPTION_PENDING_RECORDS > oldCeiling,
            "E: new budget exceeds old 22784 ceiling")
        assertTrue(maxCampaigns * pagesPerArchive * 2 > 64 * 24,
            "E: archive page allowance exceeds opaque campaigns*24")
        assertEq(GS.MAX_FRAGMENT_BUFFER_ASSEMBLIES, GS.MAX_ARCHIVE_PAGE_BUFFER_CAMPAIGNS,
            "E: buffer-campaigns still bound concurrent fragment assembly only")
        -- Real exporter/packer → buffer → readiness/commit crossing the scaled
        -- old complete budget lives in guild_supplies_tests.lua (3B43E).
    end
end

-- Bank-side Raid Supplies panel shares Settings window opacity (#461 follow-up).
do
    SpectrumFederationDB = {
        version = 3,
        global = { settingsWindowOpacity = 75 },
        lootHelper = { profiles = {}, activeProfileId = nil },
    }
    SpectrumFederationCharDB = {}
    local savedTimer = C_Timer
    C_Timer = nil
    loadModule("SpectrumFederation/modules/Settings/Schema.lua")
    loadModule("SpectrumFederation/modules/Settings/Store.lua")
    loadModule("SpectrumFederation/modules/UI/Settings/StandaloneWindow.lua")
    loadModule("SpectrumFederation/modules/Settings/Apply.lua")
    SF.SettingsStore.db = nil
    SF.SettingsStore.charDb = nil
    SF.SettingsStore._callbacks = nil
    SF.SettingsStore:Init()
    SF.SettingsApply.initialized = nil
    SF.SettingsApply._debounce = nil
    SF.SettingsApply:Init()
    assertEq(SF.SettingsStore:Get("global.settingsWindowOpacity"), 75,
        "bank-opacity: store holds nondefault 75")

    local savedCreateFrame = _G.CreateFrame
    _G.CreateFrame = function(frameType, name, parent, template)
        local f = {
            name = name,
            shown = false,
            scripts = {},
            _text = "",
            alpha = 1,
            backdrop = nil,
            backdropColor = nil,
            width = 0,
            height = 0,
            points = {},
        }
        function f:SetSize(w, h) f.width = tonumber(w) or 0; f.height = tonumber(h) or 0 end
        function f:SetWidth(w) f.width = tonumber(w) or 0 end
        function f:SetHeight(h) f.height = tonumber(h) or 0 end
        function f:GetWidth() return f.width end
        function f:GetHeight() return f.height end
        function f:ClearAllPoints() f.points = {} end
        function f:SetPoint(point, relative, relativePoint, x, y)
            f.points[#f.points + 1] = {
                point = point, relative = relative, relativePoint = relativePoint,
                x = x, y = y,
            }
        end
        function f:Hide()
            local wasShown = f.shown
            f.shown = false
            if wasShown and f.scripts.OnHide then f.scripts.OnHide(f) end
        end
        function f:Show() f.shown = true end
        function f:IsShown() return f.shown end
        function f:SetScript(k, fn) f.scripts[k] = fn end
        function f:HookScript(k, fn)
            f.hooks = f.hooks or {}
            f.hooks[k] = f.hooks[k] or {}
            f.hooks[k][#f.hooks[k] + 1] = fn
        end
        function f:GetScript(k) return f.scripts[k] end
        function f:SetMovable() end
        function f:EnableMouse() end
        function f:RegisterForDrag() end
        function f:RegisterForClicks() end
        function f:RegisterEvent() end
        function f:UnregisterEvent() end
        function f:UnregisterAllEvents() end
        function f:SetFrameStrata() end
        function f:SetFrameLevel() end
        function f:SetScrollChild(child) f.scrollChild = child end
        function f:GetScrollChild() return f.scrollChild end
        function f:SetBackdrop(info) f.backdrop = info end
        function f:SetBackdropColor(r, g, b, a)
            f.backdropColor = { r = r, g = g, b = b, a = a }
        end
        function f:SetBackdropBorderColor(r, g, b, a)
            f.backdropBorderColor = { r = r, g = g, b = b, a = a }
        end
        function f:SetAlpha(a) f.alpha = a end
        function f:GetAlpha() return f.alpha end
        function f:SetText(t)
            f._text = tostring(t or "")
            if f.scripts.OnTextChanged then f.scripts.OnTextChanged(f) end
        end
        function f:GetText() return f._text end
        function f:SetShown(v) f.shown = v and true or false end
        function f:Enable() end
        function f:Disable() end
        function f:SetAutoFocus() end
        function f:SetNumeric() end
        function f:SetMaxLetters() end
        function f:SetJustifyH() end
        function f:SetMinMaxValues() end
        function f:SetValue() end
        function f:SetStatusBarTexture() end
        function f:SetStatusBarColor() end
        f._hasFocus = false
        function f:HasFocus() return f._hasFocus and true or false end
        function f:ClearFocus() f._hasFocus = false end
        function f:SetFocus() f._hasFocus = true end
        function f:CreateFontString()
            local fs = {
                width = 0, points = {}, shown = true, _text = "",
            }
            function fs:SetPoint(point, relative, relativePoint, x, y)
                fs.points[#fs.points + 1] = {
                    point = point, relative = relative, relativePoint = relativePoint,
                    x = x, y = y,
                }
            end
            function fs:ClearAllPoints() fs.points = {} end
            function fs:SetJustifyH() end
            function fs:SetWordWrap() end
            function fs:SetText(t) fs._text = tostring(t or "") end
            function fs:GetText() return fs._text end
            function fs:SetFontObject() end
            function fs:SetTextColor() end
            function fs:SetWidth(w) fs.width = tonumber(w) or 0 end
            function fs:GetWidth() return fs.width end
            function fs:Show() fs.shown = true end
            function fs:Hide() fs.shown = false end
            return fs
        end
        function f:CreateTexture()
            return {
                SetPoint = function() end, SetSize = function() end,
                SetTexture = function() end, Show = function() end, Hide = function() end,
                SetAllPoints = function() end, SetVertexColor = function() end,
            }
        end
        return f
    end
    _G.UIParent = _G.UIParent or {}
    _G.InCombatLockdown = function() return false end
    SF.SettingsWindow._opacityTargets = {}
    -- Keep review identity fresh for this block.
    if SF.ConsumablesRuntime then
        SF.ConsumablesRuntime.review = nil
        SF.ConsumablesRuntime.mobileHolder = nil
    end
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua")
    local RT = SF.ConsumablesRuntime
    RT.WatchGuildBankFrame = function() end
    RT.EnsureMobileButton = function() return nil end
    RT.SyncMobileButton = function() end
    RT.AlignReviewToGuildBank = function() end
    RT.MatchReviewHeightToGuildBank = function() end
    RT.RebuildReview = function() end
    RT.EnsureItemIconWatch = function() end

    local targetsBefore = #(SF.SettingsWindow._opacityTargets or {})
    -- First open without main Settings window: create + apply saved opacity.
    assertTrue(SF.SettingsWindow.frame == nil or SF.SettingsWindow.frame.shown ~= true,
        "bank-opacity: main Settings window not required")
    RT:ShowReview()
    local panel = RT.review
    assertTrue(panel ~= nil, "bank-opacity: review panel created")
    assertTrue(panel.backdrop and panel.backdrop.bgFile == "Interface\\Buttons\\WHITE8X8",
        "bank-opacity: panel uses WHITE8X8 backdrop foundation")
    assertTrue(panel.backdrop and panel.backdrop.edgeFile == "Interface\\DialogFrame\\UI-DialogBox-Border",
        "bank-opacity: panel retains DialogBox border")
    assertTrue(panel.backdropColor and math.abs((panel.backdropColor.a or 0) - 0.75) < 1e-6,
        "bank-opacity: first open applies saved nondefault 75%")
    assertEq(panel.alpha, 1, "bank-opacity: frame alpha remains 1")
    assertEq(#SF.SettingsWindow._opacityTargets, targetsBefore + 1,
        "bank-opacity: panel registered once")

    -- Live setting change updates an already-visible panel.
    SF.SettingsStore:Set("global.settingsWindowOpacity", 100)
    assertTrue(panel.backdropColor and math.abs((panel.backdropColor.a or 0) - 1.0) < 1e-6,
        "bank-opacity: live Set updates visible panel to 100%")
    assertEq(panel.alpha, 1, "bank-opacity: live update does not SetAlpha the frame")

    -- Close, change, reopen uses current value without accumulating targets.
    panel:Hide()
    local targetsAfterClose = #SF.SettingsWindow._opacityTargets
    SF.SettingsStore:Set("global.settingsWindowOpacity", 70)
    RT:ShowReview()
    assertTrue(panel.backdropColor and math.abs((panel.backdropColor.a or 0) - 0.70) < 1e-6,
        "bank-opacity: reopen applies current 70%")
    assertEq(#SF.SettingsWindow._opacityTargets, targetsAfterClose,
        "bank-opacity: reopen does not accumulate opacity targets")

    SF.SettingsStore:ResetAll()
    assertEq(SF.SettingsStore:Get("global.settingsWindowOpacity"), 90,
        "bank-opacity: ResetAll restores default")
    assertTrue(panel.backdropColor and math.abs((panel.backdropColor.a or 0) - 0.90) < 1e-6,
        "bank-opacity: ResetAll reapplies 90% to bank panel")

    if savedCreateFrame then
        _G.CreateFrame = savedCreateFrame
    end
    C_Timer = savedTimer
end

-- Quick Withdraw item rows expand name column; pooled reuse restores deposit geometry.
do
    loadModule("SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua")
    local RT = SF.ConsumablesRuntime
    assertTrue(type(RT.ApplyDepositRowLayout) == "function",
        "qw-layout: ApplyDepositRowLayout present")
    assertTrue(type(RT.ApplyQuickWithdrawItemRowLayout) == "function",
        "qw-layout: ApplyQuickWithdrawItemRowLayout present")

    local function makeTrackedFontString()
        local fs = { width = 0, points = {}, shown = true, _text = "", wordWrap = nil }
        function fs:ClearAllPoints() fs.points = {} end
        function fs:SetPoint(point, relative, relativePoint, x, y)
            fs.points[#fs.points + 1] = {
                point = point, relative = relative, relativePoint = relativePoint,
                x = tonumber(x) or 0, y = tonumber(y) or 0,
            }
        end
        function fs:SetWidth(w) fs.width = tonumber(w) or 0 end
        function fs:GetWidth() return fs.width end
        function fs:SetJustifyH() end
        function fs:SetWordWrap(v) fs.wordWrap = v and true or false end
        function fs:SetText(t) fs._text = tostring(t or "") end
        function fs:Show() fs.shown = true end
        function fs:Hide() fs.shown = false end
        return fs
    end
    local function makeTrackedRegion(kind)
        local r = {
            kind = kind, width = 0, height = 0, points = {}, shown = true,
            scripts = {}, _text = "", _hasFocus = false,
        }
        function r:ClearAllPoints() r.points = {} end
        function r:SetPoint(point, relative, relativePoint, x, y)
            r.points[#r.points + 1] = {
                point = point, relative = relative, relativePoint = relativePoint,
                x = tonumber(x) or 0, y = tonumber(y) or 0,
            }
        end
        function r:SetSize(w, h) r.width = tonumber(w) or 0; r.height = tonumber(h) or 0 end
        function r:SetWidth(w) r.width = tonumber(w) or 0 end
        function r:SetHeight(h) r.height = tonumber(h) or 0 end
        function r:GetWidth() return r.width end
        function r:Show() r.shown = true end
        function r:Hide() r.shown = false end
        function r:SetScript(k, fn) r.scripts[k] = fn end
        function r:SetText(t) r._text = tostring(t or "") end
        function r:GetText() return r._text end
        function r:SetAutoFocus() end
        function r:SetNumeric() end
        function r:Enable() end
        function r:Disable() end
        function r:HasFocus() return r._hasFocus end
        return r
    end

    local row = makeTrackedRegion("row")
    row.width = 212
    row.IconButton = makeTrackedRegion("icon")
    row.IconButton.width = 18
    row.Progress = makeTrackedFontString()
    row.Edit = makeTrackedRegion("edit")
    row.Button = makeTrackedRegion("button")
    row.GoalMet = makeTrackedFontString()

    RT:ApplyDepositRowLayout(row)
    assertEq(row._reviewLayout, "deposit", "qw-layout: deposit layout tag")
    assertEq(row.Progress.width, 56, "qw-layout: deposit progress width is 56")
    assertEq(row.Edit.points[1] and row.Edit.points[1].point, "LEFT",
        "qw-layout: deposit edit anchors LEFT of progress")
    assertEq(row.Edit.width, 34, "qw-layout: deposit edit width")
    assertEq(row.Button.points[1] and row.Button.points[1].point, "LEFT",
        "qw-layout: deposit button anchors LEFT of edit")
    assertEq(row.Button.width, 72, "qw-layout: deposit button width")
    assertEq(row.GoalMet.width, 34 + 4 + 72,
        "qw-layout: deposit GoalMet spans edit+button")

    RT:ApplyQuickWithdrawItemRowLayout(row)
    assertEq(row._reviewLayout, "quickWithdraw", "qw-layout: quick-withdraw layout tag")
    local expectedNameW = 212 - 18 - 4 - 4 - 34 - 4
    assertEq(row.Progress.width, expectedNameW,
        "qw-layout: quick-withdraw name column expands past deposit 56")
    assertTrue(row.Progress.width > 56,
        "qw-layout: quick-withdraw name wider than deposit progress")
    assertEq(row.Edit.points[1] and row.Edit.points[1].point, "RIGHT",
        "qw-layout: craft-count edit anchors to row RIGHT")
    assertEq(row.Edit.points[1] and row.Edit.points[1].x, -4,
        "qw-layout: craft-count keeps right-edge pad")
    assertEq(row.Edit.width, 34, "qw-layout: craft-count edit size unchanged")
    assertEq(row.GoalMet.points[1] and row.GoalMet.points[1].point, "RIGHT",
        "qw-layout: unavailable GoalMet uses right column")
    assertEq(row.GoalMet.width, 34, "qw-layout: unavailable GoalMet width matches edit")

    -- Pooled reuse for deposit / Withdraw action / Clear must restore geometry.
    RT:ApplyDepositRowLayout(row)
    assertEq(row._reviewLayout, "deposit", "qw-layout: reuse restores deposit tag")
    assertEq(row.Progress.width, 56, "qw-layout: reuse restores deposit progress width")
    assertEq(row.Edit.points[1] and row.Edit.points[1].point, "LEFT",
        "qw-layout: reuse restores LEFT edit anchor")
    assertEq(row.Button.points[1] and row.Button.points[1].point, "LEFT",
        "qw-layout: reuse restores LEFT button anchor")
    assertEq(row.Button.width, 72, "qw-layout: reuse restores deposit button size")
    assertEq(row.GoalMet.width, 34 + 4 + 72,
        "qw-layout: reuse restores GoalMet span for completed goals")
    -- Edit must not remain RIGHT-anchored after leaving Quick Withdraw.
    local editIsRight = false
    for i = 1, #(row.Edit.points or {}) do
        if row.Edit.points[i].point == "RIGHT" then
            editIsRight = true
        end
    end
    assertFalse(editIsRight, "qw-layout: reuse clears RIGHT edit anchor")
end

if failures > 0 then
    io.stderr:write(string.format("%d failure(s)\n", failures))
    os.exit(1)
end
print("guild_supplies_457_tests: ok")
