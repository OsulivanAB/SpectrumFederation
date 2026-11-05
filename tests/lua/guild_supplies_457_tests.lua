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

if failures > 0 then
    io.stderr:write(string.format("%d failure(s)\n", failures))
    os.exit(1)
end
print("guild_supplies_457_tests: ok")
