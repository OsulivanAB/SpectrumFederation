-- Production-Lua tests for Raid Equipment Policy.
-- Run from the repository root: lua5.1 tests/lua/raid_equipment_policy_tests.lua

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. message .. "\n")
end

local function assertTrue(cond, message)
    if cond then
        pass(message)
    else
        fail(message)
    end
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local function assertHas(list, value, message)
    for i = 1, #(list or {}) do
        if list[i] == value then
            pass(message)
            return
        end
    end
    fail(message .. " (missing " .. tostring(value) .. ")")
end

local function assertNotHas(list, value, message)
    for i = 1, #(list or {}) do
        if list[i] == value then
            fail(message .. " (unexpected " .. tostring(value) .. ")")
            return
        end
    end
    pass(message)
end

local SF = {}
local chunk = assert(loadfile("SpectrumFederation/modules/RaidEquipment/Policy.lua"))
chunk("SpectrumFederation", SF)
local Policy = SF.RaidEquipment.Policy

local function equipped(opts)
    opts = opts or {}
    local slot = {
        empty = false,
        itemId = opts.itemId or 200000,
        link = opts.link or "|cffa335ee|Hitem:200000:1:0:0:0:0:0:0:80:::|h[Item]|h|r",
        texture = "tex",
        equipLoc = opts.equipLoc,
        hasEnchant = opts.hasEnchant,
        enchantId = opts.enchantId,
        sockets = opts.sockets or {},
        linkComplete = opts.linkComplete,
    }
    if opts.hasEnchant == nil and opts.enchantId == nil then
        slot.hasEnchant = true
        slot.enchantId = 1
    end
    return slot
end

local function emptySlot()
    return { empty = true, sockets = {} }
end

local function gem(filled, gemId, uniqueness)
    return {
        filled = filled,
        gemId = gemId,
        uniqueness = uniqueness,
    }
end

local function completeSlots(overrides)
    local slots = {
        [1] = equipped({ equipLoc = "INVTYPE_HEAD" }),
        [2] = equipped({ equipLoc = "INVTYPE_NECK", hasEnchant = false, enchantId = 0 }),
        [3] = equipped({ equipLoc = "INVTYPE_SHOULDER" }),
        [15] = equipped({ equipLoc = "INVTYPE_CLOAK", hasEnchant = false, enchantId = 0 }),
        [5] = equipped({ equipLoc = "INVTYPE_CHEST" }),
        [9] = equipped({ equipLoc = "INVTYPE_WRIST", hasEnchant = false, enchantId = 0 }),
        [10] = equipped({ equipLoc = "INVTYPE_HAND", hasEnchant = false, enchantId = 0 }),
        [6] = equipped({ equipLoc = "INVTYPE_WAIST", hasEnchant = false, enchantId = 0 }),
        [7] = equipped({ equipLoc = "INVTYPE_LEGS" }),
        [8] = equipped({ equipLoc = "INVTYPE_FEET" }),
        [11] = equipped({ equipLoc = "INVTYPE_FINGER" }),
        [12] = equipped({ equipLoc = "INVTYPE_FINGER" }),
        [13] = equipped({ equipLoc = "INVTYPE_TRINKET", hasEnchant = false, enchantId = 0 }),
        [14] = equipped({ equipLoc = "INVTYPE_TRINKET", hasEnchant = false, enchantId = 0 }),
        [16] = equipped({ equipLoc = "INVTYPE_WEAPON" }),
        [17] = equipped({ equipLoc = "INVTYPE_WEAPONOFFHAND" }),
    }
    for k, v in pairs(overrides or {}) do
        slots[k] = v
    end
    return slots
end

local function eval(slots)
    return Policy.EvaluateObservation({ slotsByInventory = slots })
end

-- Required enchant slots
local missingHead = eval(completeSlots({ [1] = equipped({ equipLoc = "INVTYPE_HEAD", hasEnchant = false, enchantId = 0 }) }))
assertTrue(missingHead.complete, "missing head enchant is still a complete observation")
assertHas(missingHead.missing, "Head Enchant", "Head requires an enchant")

for _, pair in ipairs({
    { 3, "Shoulders Enchant" },
    { 5, "Chest Enchant" },
    { 7, "Legs Enchant" },
    { 8, "Boots Enchant" },
    { 11, "Ring 1 Enchant" },
    { 12, "Ring 2 Enchant" },
    { 16, "Main Hand Enchant" },
}) do
    local result = eval(completeSlots({ [pair[1]] = equipped({ hasEnchant = false, enchantId = 0, equipLoc = "INVTYPE_WEAPON" }) }))
    assertHas(result.missing, pair[2], pair[2] .. " is required")
end

local prepared = eval(completeSlots())
assertTrue(prepared.complete and prepared.prepared, "fully enchanted loadout with no sockets is prepared")

-- Offhand weapon vs shield vs holdable
local ohWeapon = eval(completeSlots({
    [17] = equipped({ equipLoc = "INVTYPE_WEAPONOFFHAND", hasEnchant = false, enchantId = 0 }),
}))
assertHas(ohWeapon.missing, "Off Hand Enchant", "offhand weapon requires an enchant")

local ohShield = eval(completeSlots({
    [17] = equipped({ equipLoc = "INVTYPE_SHIELD", hasEnchant = false, enchantId = 0 }),
}))
assertTrue(ohShield.prepared, "shield offhand does not require an enchant")
assertNotHas(ohShield.missing, "Off Hand Enchant", "shield is not a weapon enchant slot")

local ohHoldable = eval(completeSlots({
    [17] = equipped({ equipLoc = "INVTYPE_HOLDABLE", hasEnchant = false, enchantId = 0 }),
}))
assertTrue(ohHoldable.prepared, "holdable offhand does not require an enchant")

-- Empty normal slot
local emptyHead = eval(completeSlots({ [1] = emptySlot() }))
assertHas(emptyHead.missing, "Head Item", "empty head is Unprepared")
assertTrue(emptyHead.complete, "known empty slot is complete")

-- Legitimate empty 2H offhand
local twoHand = eval(completeSlots({
    [16] = equipped({ equipLoc = "INVTYPE_2HWEAPON" }),
    [17] = emptySlot(),
}))
assertTrue(twoHand.prepared, "empty offhand with 2H main hand is prepared")
assertNotHas(twoHand.missing, "Off Hand Item", "2H empty offhand is not a missing item")

-- Sockets
local emptySocket = eval(completeSlots({
    [5] = equipped({
        equipLoc = "INVTYPE_CHEST",
        sockets = { gem(false) },
    }),
}))
assertHas(emptySocket.missing, "Chest Gem", "empty socket is Unprepared")
assertHas(emptySocket.missing, "Limited Gem", "usable sockets require a limited gem")

local zeroSockets = eval(completeSlots())
assertEq(zeroSockets.usableSockets, 0, "zero sockets requires zero limited gems")
assertTrue(zeroSockets.prepared, "zero sockets with required enchants is prepared")

local qualifying = eval(completeSlots({
    [5] = equipped({
        equipLoc = "INVTYPE_CHEST",
        sockets = { gem(true, 240967, { resolved = true, category = "Thalassian Diamond" }) },
    }),
}))
assertTrue(qualifying.prepared, "allowlisted Eversong Diamond satisfies limited gem")
assertEq(qualifying.limitedGems, 1, "one qualifying limited gem counted")

local ordinary = eval(completeSlots({
    [5] = equipped({
        equipLoc = "INVTYPE_CHEST",
        sockets = { gem(true, 12345, { resolved = true, category = "Something Else" }) },
    }),
}))
assertHas(ordinary.missing, "Limited Gem", "ordinary gem does not satisfy limited gem")
assertNotHas(ordinary.missing, "Chest Gem", "ordinary filled gem still fills the socket")
assertTrue(ordinary.complete, "ordinary gem with a resolved non-family category is complete")

local ordinaryNoCategory = eval(completeSlots({
    [5] = equipped({
        equipLoc = "INVTYPE_CHEST",
        sockets = { gem(true, 12345, { resolved = false }) },
    }),
}))
assertTrue(ordinaryNoCategory.complete, "successful uniqueness lookup with no category is complete")
assertHas(ordinaryNoCategory.missing, "Limited Gem", "ordinary gem without uniqueness is not a limited gem")
assertNotHas(ordinaryNoCategory.missing, "Chest Gem", "ordinary gem without uniqueness still fills the socket")
assertEq(select(1, Policy.IsQualifyingLimitedGem(12345, { resolved = false })), false, "resolved=false uniqueness is not-family")

local missingGemId = eval(completeSlots({
    [5] = equipped({
        equipLoc = "INVTYPE_CHEST",
        sockets = { gem(true, nil) },
    }),
}))
assertTrue(not missingGemId.complete, "filled socket with no gem id is incomplete")
assertEq(missingGemId.incompleteReason, "unresolved", "missing gem id does not guess not-limited")

local zeroGemId = eval(completeSlots({
    [5] = equipped({
        equipLoc = "INVTYPE_CHEST",
        sockets = { gem(true, 0) },
    }),
}))
assertTrue(not zeroGemId.complete, "filled socket with gem id 0 is incomplete")
assertEq(select(1, Policy.IsQualifyingLimitedGem(0)), nil, "zero gem id is unresolved rather than not-limited")

local reagent = Policy.IsQualifyingLimitedGem(242712, { resolved = true, category = "Thalassian Diamond" })
assertEq(reagent, false, "raw Eversong Diamond reagent is excluded even if uniqueness matches")

local unresolved = eval(completeSlots({
    [5] = equipped({
        equipLoc = "INVTYPE_CHEST",
        sockets = { gem(true, 999999, nil) },
    }),
}))
assertTrue(not unresolved.complete, "unresolved limited-gem identity is incomplete")
assertEq(unresolved.incompleteReason, "unresolved_identity", "incomplete reason is unresolved identity")

local pendingLink = eval(completeSlots({
    [1] = {
        empty = false,
        itemId = 200000,
        texture = "tex",
        link = nil,
    },
}))
assertTrue(not pendingLink.complete, "item evidence without a link is incomplete")
assertTrue(not pendingLink.prepared, "incomplete observations are not prepared")

local incompleteLink = eval(completeSlots({
    [1] = equipped({ linkComplete = false }),
}))
assertTrue(not incompleteLink.complete, "explicit incomplete link cannot be policy-evaluated")

assertEq(Policy.RequiresOffHandEnchant("INVTYPE_SHIELD"), false, "RequiresOffHandEnchant is false for shields")
assertEq(Policy.RequiresOffHandEnchant("INVTYPE_WEAPONOFFHAND"), true, "RequiresOffHandEnchant is true for offhand weapons")
assertEq(Policy.RequiresOffHandEnchant(nil), nil, "unresolved offhand type is nil")

local completeness = Policy.EvaluateCompleteness({ slotsByInventory = completeSlots() })
assertTrue(completeness.complete, "EvaluateCompleteness reports complete for a full observation")

local ready = Policy.ReadinessFromObservation({ slotsByInventory = completeSlots() })
assertEq(ready.state, "ready", "complete prepared observation is Ready")
assertEq(#ready.missing, 0, "ready observations have no missing list")

local missingChest = completeSlots({
    [5] = {
        empty = false,
        itemId = 200000,
        link = "|cffa335ee|Hitem:200000:0:0:0:0:0:0:0:80:::|h[Item]|h|r",
        texture = "tex",
        equipLoc = "INVTYPE_CHEST",
        hasEnchant = false,
        enchantId = 0,
        sockets = {},
    },
})
local notReady = Policy.ReadinessFromObservation({ slotsByInventory = missingChest })
assertEq(notReady.state, "not_ready", "complete unprepared observation is Not Ready")
assertHas(notReady.missing, "Chest Enchant", "not-ready missing list reuses Policy reasons")

local unknownMissing = Policy.ReadinessFromObservation(nil)
assertEq(unknownMissing.state, "unknown", "missing observation is Unknown")

local unknownIncomplete = Policy.ReadinessFromObservation({ slotsByInventory = completeSlots({
    [1] = { empty = false, itemId = 200000, texture = "tex" },
}) })
assertEq(unknownIncomplete.state, "unknown", "incomplete observation is Unknown rather than Not Ready")

local function itemLevelConfig(minimum, enabled)
    return {
        requireMinimumItemLevel = enabled ~= false,
        minimumItemLevel = minimum,
    }
end

local function observe(slots, itemLevel)
    local copied = slots
    for _, slot in pairs(copied) do
        if type(slot) == "table" then
            slot.itemLevel = 1
        end
    end
    return {
        slotsByInventory = copied,
        overallEquippedItemLevel = itemLevel,
    }
end

assertEq(Policy.CanonicalOverallItemLevel(649.94), 649.9, "649.94 canonicalizes to 649.9")
assertEq(Policy.CanonicalOverallItemLevel(649.95), 650, "649.95 canonicalizes to 650")
assertEq(Policy.FormatOverallItemLevel(649.94), "649.9", "display uses the same 649.9 canonical value")
assertEq(Policy.FormatOverallItemLevel(649.95), "650", "display uses the same 650 canonical value")
assertEq(Policy.CanonicalOverallItemLevel(0), nil, "API zero is not a usable item level")
assertEq(Policy.CanonicalOverallItemLevel(nil), nil, "missing item level stays nil")
assertEq(Policy.NormalizeMinimumItemLevel("650"), 650, "numeric strings normalize")
assertEq(Policy.NormalizeMinimumItemLevel(-4), 0, "negative thresholds clamp to zero")
assertEq(Policy.NormalizeMinimumItemLevel("nope"), nil, "invalid thresholds become nil")
assertTrue(not Policy.ItemLevelRequirementActive({ requireMinimumItemLevel = false, minimumItemLevel = 650 }), "disabled requirement is inactive")
assertTrue(not Policy.ItemLevelRequirementActive({ requireMinimumItemLevel = true }), "enabled requirement without a threshold is inactive")

local below = Policy.EvaluateObservation(observe(completeSlots(), 649.9), itemLevelConfig(650))
assertTrue(below.complete, "known low item level is a complete observation")
assertTrue(not below.prepared, "649.9 is Unprepared against 650")
assertHas(below.missing, "Item Level 649.9 (650 required)", "failure text includes both values")

local exact = Policy.EvaluateObservation(observe(completeSlots(), 650.0), itemLevelConfig(650))
assertTrue(exact.prepared, "650.0 meets a 650 minimum")
assertNotHas(exact.missing, "Item Level 650 (650 required)", "equal item level is not a failure")

local above = Policy.EvaluateObservation(observe(completeSlots(), 650.1), itemLevelConfig(650))
assertTrue(above.prepared, "650.1 meets a 650 minimum")

local roundedPass = Policy.EvaluateObservation(observe(completeSlots(), 649.95), itemLevelConfig(650))
assertTrue(roundedPass.prepared, "649.95 canonicalizes to 650 and passes")
local roundedFail = Policy.EvaluateObservation(observe(completeSlots(), 649.94), itemLevelConfig(650))
assertHas(roundedFail.missing, "Item Level 649.9 (650 required)", "649.94 canonicalizes to 649.9 and fails")

local disabled = Policy.EvaluateObservation(observe(completeSlots(), 100), itemLevelConfig(650, false))
assertTrue(disabled.prepared, "disabled requirement ignores a stored threshold")
assertNotHas(disabled.missing, "Item Level 100 (650 required)", "disabled requirement emits no item-level reason")

local unknownLevel = Policy.EvaluateObservation(observe(completeSlots(), nil), itemLevelConfig(650))
assertTrue(not unknownLevel.complete, "missing item level is incomplete while required")
assertEq(unknownLevel.incompleteReason, "unresolved_item_level", "missing item level has its own incomplete reason")
assertNotHas(unknownLevel.missing, "Item Level 0 (650 required)", "missing item level is not invented as zero")
local unknownReady = Policy.ReadinessFromObservation(observe(completeSlots(), nil), itemLevelConfig(650))
assertEq(unknownReady.state, "unknown", "missing item level stays Unknown")

local enchantAndLevel = completeSlots({
    [5] = {
        empty = false,
        itemId = 200000,
        link = "|cffa335ee|Hitem:200000:0:0:0:0:0:0:0:80:::|h[Item]|h|r",
        texture = "tex",
        equipLoc = "INVTYPE_CHEST",
        hasEnchant = false,
        enchantId = 0,
        sockets = {},
        itemLevel = 900,
    },
})
local both = Policy.EvaluateObservation({
    slotsByInventory = enchantAndLevel,
    overallEquippedItemLevel = 642.3,
}, itemLevelConfig(650))
assertHas(both.missing, "Chest Enchant", "item level does not hide another known failure")
assertHas(both.missing, "Item Level 642.3 (650 required)", "item level is reported with the other failure")

local highWithEnchant = Policy.EvaluateObservation({
    slotsByInventory = enchantAndLevel,
    overallEquippedItemLevel = 680,
}, itemLevelConfig(650))
assertHas(highWithEnchant.missing, "Chest Enchant", "meeting item level does not clear a missing enchant")
assertTrue(not highWithEnchant.prepared, "a missing enchant stays Unprepared")

local ignoredSlots = Policy.EvaluateObservation({
    slotsByInventory = enchantAndLevel,
    overallEquippedItemLevel = 680,
}, itemLevelConfig(650, false))
assertTrue(not ignoredSlots.prepared, "slot item levels are not an alternate overall item level")

local readyLevel = Policy.ReadinessFromObservation(observe(completeSlots(), 651.2), itemLevelConfig(650))
assertEq(readyLevel.state, "ready", "readiness is Ready when item level and other rules pass")
local notReadyLevel = Policy.ReadinessFromObservation(observe(completeSlots(), 642.3), itemLevelConfig(650))
assertEq(notReadyLevel.state, "not_ready", "readiness is Not Ready for a known low item level")
assertHas(notReadyLevel.missing, "Item Level 642.3 (650 required)", "readiness tooltip source includes the item-level reason")
assertTrue(not Policy.ShouldWarnItemLevel(650, itemLevelConfig(650)), "equal item level does not warn")
assertTrue(Policy.ShouldWarnItemLevel(649.9, itemLevelConfig(650)), "known low item level warns")
assertTrue(not Policy.ShouldWarnItemLevel(100, itemLevelConfig(650, false)), "disabled requirement does not warn")
assertTrue(not Policy.ShouldWarnItemLevel(100, nil), "no profile config does not warn")
assertTrue(not Policy.ShouldWarnItemLevel(nil, itemLevelConfig(650)), "unknown item level does not warn")
assertTrue(Policy.IsLegacyEnchantGemWhisper("Spectrum Federation: You're missing the following enchants/gems: {missing}.", "pre"), "legacy pre-raid default is recognized")
assertTrue(not Policy.IsLegacyEnchantGemWhisper("Custom whisper {missing}", "pre"), "custom whispers are not legacy defaults")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
