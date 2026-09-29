-- Production-Lua tests for Raid Consumables domain, ledger, routing, and workflows.
-- Run from the repository root: lua5.1 tests/lua/consumables_tests.lua

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(message) .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. tostring(message) .. "\n")
end

local function assertTrue(cond, message)
    if cond then pass(message) else fail(message) end
end

local function assertFalse(cond, message)
    if cond then fail(message) else pass(message) end
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local SF = {
    Debug = {
        Info = function() end,
        Warn = function() end,
        Error = function() end,
        Verbose = function() end,
    },
}
local clock = 1000
SF.Consumables = {}
local function load(path)
    local chunk = assert(loadfile(path))
    chunk("SpectrumFederation", SF)
end
load("SpectrumFederation/modules/LootHelper/Consumables.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesRouting.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesWorkflow.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesSync.lua")

local C = SF.Consumables
local R = SF.ConsumablesRouting
local W = SF.ConsumablesWorkflow
local S = SF.ConsumablesSync
C._clock = function()
    clock = clock + 1
    return clock
end

local function profile(id, owner, admins)
    local p = {
        _profileId = id or "profile-1",
        _owner = owner or "Admin-Realm",
        _adminUsers = admins or { owner or "Admin-Realm" },
        _pointName = "Points",
        _lootLogs = { "keep-me" },
        _rewardPotStartingCopper = 42,
        _identity = {},
    }
    function p:IsAdminMemberId(memberId)
        for i = 1, #self._adminUsers do
            if self._adminUsers[i] == memberId then return true end
        end
        return false
    end
    function p:GetIdentityMembers(memberId)
        return self._identity[memberId] or { memberId }
    end
    C.Ensure(p)
    return p
end

local function unchanged(p, message)
    assertEq(p._pointName, "Points", message .. " point name")
    assertEq(p._lootLogs[1], "keep-me", message .. " loot logs")
    assertEq(p._rewardPotStartingCopper, 42, message .. " reward pot")
end

local admin = "Admin-Realm"
local vann = "Vann-Realm"
local sully = "Sully-Realm"
local donor = "Donor-Realm"
local aqirite = 190000
local aqiriteRank2 = 190001

-- Migration and permissions
local migrated = { _profileId = "old", _adminUsers = { admin }, _pointName = "Points", _lootLogs = { "keep-me" }, _rewardPotStartingCopper = 42 }
function migrated:IsAdminMemberId(memberId) return memberId == admin end
C.Ensure(migrated)
assertEq(migrated._consumables.generation, 1, "existing profile migrates to generation 1")
assertEq(#migrated._consumables.crafters, 0, "existing profile starts with no crafters")
assertEq(#migrated._consumableEvents, 0, "existing profile starts with no events")

local p = profile()
assertFalse(select(1, C.AddCrafter(p, donor, vann)), "non-admin cannot add a crafter")
assertTrue(select(1, C.AddCrafter(p, admin, vann, { asAdmin = true })), "admin can add a crafter")
assertTrue(C.IsCrafter(p, vann), "crafter designation is stored")
assertFalse(select(1, C.AddCrafter(p, admin, vann, { asAdmin = true })), "duplicate crafter is rejected")
assertTrue(select(1, C.AddCrafter(p, admin, sully, { asAdmin = true })), "admin can add a second crafter")
assertFalse(C.IsCrafter(p, donor), "another character is not a crafter")

assertFalse(select(1, C.AddAssignment(p, donor, aqirite, vann)), "non-crafter cannot assign materials")
assertFalse(select(1, C.AddAssignment(p, sully, aqirite, vann)), "crafter cannot edit another crafter")
assertTrue(select(1, C.AddAssignment(p, vann, aqirite, vann)), "crafter can add their own material")
assertFalse(select(1, C.AddAssignment(p, vann, aqirite, vann)), "duplicate crafter/item assignment is rejected")
assertTrue(select(1, C.AddAssignment(p, admin, aqirite, sully, { asAdmin = true })), "admin can assign the same item to another crafter")
assertTrue(C.IsRequested(p, aqirite), "requested supplies are the assignment union")
assertFalse(C.IsRequested(p, aqiriteRank2), "a different quality item id is not requested")
assertFalse(select(1, C.AddAssignment(p, vann, 0, vann)), "item id must be a positive integer")
assertFalse(select(1, C.AddAssignment(p, vann, aqiriteRank2, vann, { transferable = false })), "non-transferable items are rejected")
assertTrue(select(1, C.AddAssignment(p, vann, aqiriteRank2, vann, { transferable = true })), "a separate quality can be requested explicitly")

local epochAfterBoth = p._consumables.assignments[tostring(aqirite)].epoch
assertEq(epochAfterBoth, 2, "adding a second crafter starts a new routing epoch")
assertTrue(select(1, C.RemoveAssignment(p, admin, aqirite, sully, { asAdmin = true })), "admin can remove an assignment")
assertEq(p._consumables.assignments[tostring(aqirite)].epoch, epochAfterBoth + 1, "removing a crafter starts a new routing epoch")
assertTrue(select(1, C.AddAssignment(p, admin, aqirite, sully, { asAdmin = true })), "admin can add the crafter back")

-- Receipts follow the current epoch only
local frozen = C.FreezeTrade(p, donor, sully, { { itemId = aqirite } }, "trade-1")
local events = W.TradeEvents(frozen, { [aqirite] = 200 }, true)
assertTrue(C.CommitEvents(p, frozen.token, events), "trade events commit")
assertEq(C.ReceiptTotal(p, aqirite, sully), 200, "current-epoch receipt is counted")
local epochNow = p._consumables.assignments[tostring(aqirite)].epoch
assertTrue(select(1, C.RemoveAssignment(p, admin, aqirite, vann, { asAdmin = true })), "assignment set change")
assertEq(C.ReceiptTotal(p, aqirite, sully), 0, "old-epoch receipts do not affect the new epoch")
assertTrue(#p._consumableEvents > 0, "historical receipt events remain")
assertTrue(select(1, C.AddAssignment(p, admin, aqirite, vann, { asAdmin = true })), "restore vann")
local readdedEpoch = p._consumables.assignments[tostring(aqirite)].epoch
assertTrue(readdedEpoch > epochNow, "requesting an item again uses a newer epoch")

-- Routing
local function totalsFor(profileObj, itemId)
    local crafters = C.AssignedCrafters(profileObj, itemId)
    local totals = {}
    for i = 1, #crafters do
        totals[crafters[i]] = C.ReceiptTotal(profileObj, itemId, crafters[i])
    end
    return totals
end
local routeP = profile("route", admin)
assertTrue(select(1, C.AddCrafter(routeP, admin, vann, { asAdmin = true })))
assertTrue(select(1, C.AddCrafter(routeP, admin, sully, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(routeP, admin, aqirite, vann, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(routeP, admin, aqirite, sully, { asAdmin = true })))
local function seedReceipt(profileObj, crafter, qty, token)
    local context = C.FreezeTrade(profileObj, donor, crafter, { { itemId = aqirite } }, token)
    C.CommitEvents(profileObj, token, W.TradeEvents(context, { [aqirite] = qty }, true))
end
seedReceipt(routeP, vann, 600, "seed-vann")
seedReceipt(routeP, sully, 450, "seed-sully")
assertEq(C.ReceiptTotal(routeP, aqirite, vann), 600, "vann current total")
assertEq(C.ReceiptTotal(routeP, aqirite, sully), 450, "sully current total")
local chosen = R.RouteItem(C.AssignedCrafters(routeP, aqirite), totalsFor(routeP, aqirite), { [vann] = true, [sully] = true }, { [vann] = true, [sully] = true })
assertEq(chosen, sully, "lowest current-round recipient is selected")
local tied = R.Choose({
    { name = sully, inGroup = true, compatible = true },
    { name = vann, inGroup = true, compatible = true },
}, { [sully] = 10, [vann] = 10 })
assertEq(tied, sully, "tie uses the earlier character name")
local solo = R.RouteItem(C.AssignedCrafters(routeP, aqirite), totalsFor(routeP, aqirite), {}, { [vann] = true, [sully] = true })
assertEq(solo, nil, "solo or empty group has no direct recipient")
local incompatible = R.RouteItem(C.AssignedCrafters(routeP, aqirite), totalsFor(routeP, aqirite), { [vann] = true, [sully] = true }, { [vann] = true })
assertEq(incompatible, vann, "an incompatible crafter does not block the other crafter")
local action = R.TradeAction(sully, false)
assertTrue(action.visible, "out-of-range recipient stays selected")
assertFalse(action.enabled, "out-of-range trade action is disabled")
local plan = C.BuildDonationPlan(routeP, { { itemId = aqirite, quantity = 200, quality = 1 } }, {
    inGroup = { [vann] = true, [sully] = true },
    compatible = { [vann] = true, [sully] = true },
    inRange = { [sully] = false, [vann] = true },
})
assertEq(#plan.lines, 1, "one carried stack stays one donation line")
assertEq(plan.lines[1].quantity, 200, "routing does not split the donation")
assertEq(plan.lines[1].recipient, sully, "the full stack routes to the lower total")
assertEq(#plan.groups, 1, "materials group by recipient")

-- Reminder
assertFalse(R.ReminderVisible({
    isCrafter = true, remindersEnabled = true, windowAllowed = true, carriesRequested = true, hasActionablePath = true,
}), "configured crafters do not get unsolicited reminders")
assertFalse(R.ReminderVisible({
    remindersEnabled = false, windowAllowed = true, carriesRequested = true, hasActionablePath = true,
}), "personal reminder setting hides the reminder")
assertFalse(R.ReminderVisible({
    remindersEnabled = true, windowAllowed = true, carriesRequested = true, hasActionablePath = false,
}), "no destination hides the reminder")
assertTrue(R.ReminderVisible({
    remindersEnabled = true, windowAllowed = true, carriesRequested = true, hasActionablePath = true,
}), "reminder shows for a carried requested item with a path")
assertFalse(R.IsCarriedBag(-1), "character bank is excluded")
assertFalse(R.IsCarriedBag(-3), "warband bank is excluded")
assertFalse(R.IsCarriedBag(6), "bank tabs are excluded")
assertTrue(R.IsCarriedBag(0), "backpack is carried")
assertTrue(R.IsCarriedBag(4), "equipped bags are carried")
assertTrue(R.IsCarriedBag(5), "reagent bag is carried")
local ticker = R.SyncRangeTicker(false, nil)
ticker = R.SyncRangeTicker(true, ticker)
ticker = R.SyncRangeTicker(true, ticker)
assertEq(ticker.starts, 1, "range polling starts once")
ticker = R.SyncRangeTicker(false, ticker)
ticker = R.SyncRangeTicker(false, ticker)
assertEq(ticker.stops, 1, "range polling stops once and stays idle")
assertFalse(R.ShouldPollRange({ selectedRecipient = sully, inRange = true, reminderVisible = true }), "in-range selection does not poll")

-- Trade workflow
local tradeP = profile("trade", admin)
assertTrue(select(1, C.AddCrafter(tradeP, admin, sully, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(tradeP, admin, aqirite, sully, { asAdmin = true })))
local openFrozen = C.FreezeTrade(tradeP, donor, sully, { { itemId = aqirite, quantity = 200 } }, "open-trade")
assertEq(#W.TradeEvents(openFrozen, { [aqirite] = 200 }, false), 0, "cancelled trade records nothing")
local changed = W.TradeEvents(openFrozen, { [aqirite] = 40 }, true)
C.CommitEvents(tradeP, "changed", changed)
assertEq(C.ReceiptTotal(tradeP, aqirite, sully), 40, "changed trade records the actual quantity")
assertEq(C.ContributionTotal(tradeP, donor, aqirite), 40, "contribution uses the actual quantity")
C.CommitEvents(tradeP, "changed", changed)
assertEq(C.ReceiptTotal(tradeP, aqirite, sully), 40, "replaying the same trade does not double count")
local wrong = C.FreezeTrade(tradeP, donor, vann, { { itemId = aqirite } }, "wrong")
assertEq(#W.TradeEvents(wrong, { [aqirite] = 10 }, true), 0, "an item not assigned to the receiver is ignored")
local slots = W.PlanTradeSlots({
    { itemId = aqirite, quantity = 200, stacks = { { bag = 0, slot = 1, count = 200 } } },
}, 6)
assertEq(#slots.placements, 1, "one stack uses one trade slot")
assertFalse(slots.accept, "trade planning never accepts the trade")
local overflow = W.PlanTradeSlots({
    { itemId = aqirite, quantity = 700, stacks = {
        { bag = 0, slot = 1, count = 100 },
        { bag = 0, slot = 2, count = 100 },
        { bag = 0, slot = 3, count = 100 },
        { bag = 0, slot = 4, count = 100 },
        { bag = 0, slot = 5, count = 100 },
        { bag = 0, slot = 6, count = 100 },
        { bag = 0, slot = 7, count = 100 },
    } },
}, 6)
assertEq(#overflow.placements, 6, "only six trade slots are filled")
assertEq(overflow.remainder[1].quantity, 100, "overflow remains for another manual trade")
assertTrue(overflow.placements[1].split == false, "a full stack is not split")
local split = W.PlanTradeSlots({
    { itemId = aqirite, quantity = 25, stacks = { { bag = 5, slot = 1, count = 100 } } },
}, 6)
assertTrue(split.placements[1].split, "a reduced quantity splits the stack")

-- Frozen epoch survives a later assignment change
local before = C.FreezeTrade(tradeP, donor, sully, { { itemId = aqirite } }, "frozen")
assertTrue(select(1, C.AddCrafter(tradeP, admin, vann, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(tradeP, admin, aqirite, vann, { asAdmin = true })))
local beforeTotal = C.ReceiptTotal(tradeP, aqirite, sully)
C.CommitEvents(tradeP, "frozen", W.TradeEvents(before, { [aqirite] = 5 }, true))
assertEq(C.ReceiptTotal(tradeP, aqirite, sully), beforeTotal, "an open-trade receipt does not affect the newer epoch")
local history = C.HistoryRows(tradeP)
assertTrue(#history >= 1, "the historical receipt remains visible")

-- Custody, bank, resolve
local bankP = profile("bank", admin)
assertTrue(select(1, C.AddCrafter(bankP, admin, sully, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(bankP, admin, aqirite, sully, { asAdmin = true })))
local depositFrozen = {
    generation = bankP._consumables.generation,
    itemId = aqirite,
    donor = donor,
    requested = true,
    donorAssigned = false,
    custodyQty = 0,
    timestamp = C.Now(),
}
local deposited, depositErr = W.InterpretDeposit({
    guildOk = true, configuredTab = 2, observedTab = 2,
    intendedQty = 200, beforeTab = 0, afterTab = 50, beforeBags = 200, afterBags = 150,
})
assertEq(deposited, 50, "partial bank deposit records only what landed")
assertEq(depositErr, nil, "partial deposit has no hard error")
C.CommitEvents(bankP, "deposit-1", W.DepositEvents(depositFrozen, deposited))
assertEq(C.ContributionTotal(bankP, donor, aqirite), 50, "guild bank contribution matches the deposit")
local wrongGuild = W.InterpretDeposit({ guildOk = false, configuredTab = 2, observedTab = 2, intendedQty = 10, beforeTab = 0, afterTab = 10, beforeBags = 10, afterBags = 0 })
assertEq(wrongGuild, 0, "wrong guild records nothing")
local wrongTab = W.InterpretDeposit({ guildOk = true, configuredTab = 2, observedTab = 3, intendedQty = 10, beforeTab = 0, afterTab = 10, beforeBags = 10, afterBags = 0 })
assertEq(wrongTab, 0, "wrong tab records nothing")
local access = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = true, canDeposit = false, freeSlots = 4 })
assertFalse(access.enabled, "missing deposit permission disables the bank action")
local full = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = true, canDeposit = true, freeSlots = 0 })
assertEq(full.reason, "tab_full", "a full tab is reported")
local hidden = R.GuildBankAccess({ configured = true, sameGuild = false, bankOpen = true, canDeposit = true, freeSlots = 4 })
assertFalse(hidden.visible, "another guild hides bank actions")
local cooldown = R.GuildBankAccess({ configured = true, sameGuild = true, bankOpen = false, mobileKnown = true, mobileCooldown = true })
assertEq(cooldown.reason, "cooldown", "mobile banking cooldown is represented")
assertFalse(R.GuildBankUsable(cooldown), "cooldown is not an actionable bank route")
assertFalse(R.TransferableBindType(1), "soulbound items are not transferable")
assertFalse(R.TransferableBindType(4), "quest items are not transferable")
assertFalse(R.TransferableBindType(7), "account-bound items are not transferable")
assertFalse(R.TransferableBindType(8), "Battle.net-bound items are not transferable")
assertFalse(R.TransferableBindType(9), "warbound items are not transferable")
assertTrue(R.TransferableBindType(2), "bind on equip items can be traded")

local unrelated = W.InterpretWithdraw({ configuredTab = 2, observedTab = 2, beforeTab = 50, afterTab = 30, beforeBags = 0, afterBags = 20 })
assertEq(unrelated, 0, "a tab and bag delta without a local pickup records nothing")
local withdrawQty = W.InterpretWithdraw({
    localPickup = true, configuredTab = 2, observedTab = 2, intendedQty = 20,
    beforeTab = 50, afterTab = 30, beforeBags = 0, afterBags = 20,
})
assertEq(withdrawQty, 20, "a local pickup records the matching tab and bag delta")
local capped = W.InterpretWithdraw({
    localPickup = true, configuredTab = 2, observedTab = 2, intendedQty = 5,
    beforeTab = 50, afterTab = 30, beforeBags = 0, afterBags = 20,
})
assertEq(capped, 5, "a local pickup does not record more than the picked-up stack")
assertEq(W.InterpretWithdraw({
    localPickup = true, guildOk = false, configuredTab = 2, observedTab = 2, intendedQty = 20,
    beforeTab = 50, afterTab = 30, beforeBags = 0, afterBags = 20,
}), 0, "a withdrawal from another guild records nothing")
assertEq(W.DepositDisposition(4, 10, false), "wait", "a partial deposit waits for the rest")
assertEq(W.DepositDisposition(10, 10, false), "commit", "a complete deposit commits immediately")
assertEq(W.DepositDisposition(4, 10, true), "commit", "the deposit deadline commits the partial amount")
assertEq(W.DepositDisposition(0, 10, true), "drop", "an empty deposit deadline records nothing")
local epoch = bankP._consumables.assignments[tostring(aqirite)].epoch
C.CommitEvents(bankP, "withdraw-admin", W.WithdrawEvents({
    requested = true, withdrawerIsAdmin = true, withdrawer = admin, generation = bankP._consumables.generation, epoch = epoch, timestamp = C.Now(),
}, aqirite, withdrawQty))
local custody = C.CustodyFor(bankP, admin, aqirite)
assertEq(custody and custody.quantity, 20, "admin withdrawal creates custody")
assertEq(C.ContributionTotal(bankP, admin, aqirite), 0, "admin withdrawal does not create contribution")
assertEq(#W.EventsFromUnsupportedInventoryDecrease(), 0, "a generic bag decrease creates no custody event")

local crafterWithdraw = W.WithdrawEvents({
    requested = true, withdrawerIsAssignedCrafter = true, withdrawerIsAdmin = true, withdrawer = sully,
    generation = bankP._consumables.generation, epoch = epoch, timestamp = C.Now(),
}, aqirite, 5)
assertEq(crafterWithdraw[1].type, C.EVENT.RECEIPT, "assigned crafter withdrawal is a receipt")
C.CommitEvents(bankP, "withdraw-crafter", crafterWithdraw)
assertEq(C.ContributionTotal(bankP, sully), 0, "crafter withdrawal does not create contribution")

-- Custody delivery consumes custody before contribution
local deliverP = profile("deliver", admin)
assertTrue(select(1, C.AddCrafter(deliverP, admin, sully, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(deliverP, admin, aqirite, sully, { asAdmin = true })))
C.CommitEvents(deliverP, "custody-seed", W.WithdrawEvents({
    requested = true, withdrawerIsAdmin = true, withdrawer = admin,
    generation = deliverP._consumables.generation, epoch = deliverP._consumables.assignments[tostring(aqirite)].epoch, timestamp = C.Now(),
}, aqirite, 10))
local deliverFrozen = C.FreezeTrade(deliverP, admin, sully, { { itemId = aqirite } }, "deliver")
C.CommitEvents(deliverP, "deliver", W.TradeEvents(deliverFrozen, { [aqirite] = 15 }, true))
assertEq(C.CustodyFor(deliverP, admin, aqirite), nil, "delivery consumes known custody")
assertEq(C.ReceiptTotal(deliverP, aqirite, sully), 15, "crafter receipt includes custody and excess")
assertEq(C.ContributionTotal(deliverP, admin, aqirite), 5, "only quantity beyond custody is a new contribution")

-- Admin to admin transfer and return
local transferFrozen = C.FreezeTrade(deliverP, admin, "OtherAdmin-Realm", { { itemId = aqirite } }, "xfer")
-- no remaining custody, seed again
C.CommitEvents(deliverP, "custody-2", W.WithdrawEvents({
    requested = true, withdrawerIsAdmin = true, withdrawer = admin,
    generation = deliverP._consumables.generation, epoch = deliverP._consumables.assignments[tostring(aqirite)].epoch, timestamp = C.Now(),
}, aqirite, 8))
deliverP._adminUsers[#deliverP._adminUsers + 1] = "OtherAdmin-Realm"
transferFrozen = C.FreezeTrade(deliverP, admin, "OtherAdmin-Realm", { { itemId = aqirite } }, "xfer2")
-- item is not assigned to OtherAdmin, both admins, custody exists
assertFalse(transferFrozen.items[aqirite].assignedToReceiver, "admin recipient is not the assigned crafter")
C.CommitEvents(deliverP, "xfer2", W.TradeEvents(transferFrozen, { [aqirite] = 8 }, true))
assertEq(C.CustodyFor(deliverP, "OtherAdmin-Realm", aqirite).quantity, 8, "admin transfer moves custody")
assertEq(C.ContributionTotal(deliverP, admin, aqirite), 5, "admin transfer does not add contribution")
local returned = W.DepositEvents({
    generation = deliverP._consumables.generation, itemId = aqirite, donor = "OtherAdmin-Realm",
    requested = true, donorAssigned = false, custodyQty = 8, timestamp = C.Now(),
}, 8)
C.CommitEvents(deliverP, "return", returned)
assertEq(C.CustodyFor(deliverP, "OtherAdmin-Realm", aqirite), nil, "returning custody to the bank consumes it")
assertEq(C.ContributionTotal(deliverP, "OtherAdmin-Realm", aqirite), 0, "returned custody is not a new contribution")

-- Retired custody and resolve
assertTrue(select(1, C.RemoveAssignment(deliverP, admin, aqirite, sully, { asAdmin = true })))
C.CommitEvents(deliverP, "retired-custody", W.WithdrawEvents({
    requested = false, withdrawerIsAdmin = true, withdrawer = admin,
    generation = deliverP._consumables.generation, timestamp = C.Now(),
}, aqirite, 4))
assertEq(C.CustodyFor(deliverP, admin, aqirite), nil, "a retired item withdrawal does not create new custody")
-- recreate active custody then retire it
assertTrue(select(1, C.AddAssignment(deliverP, admin, aqirite, sully, { asAdmin = true })))
C.CommitEvents(deliverP, "active-again", W.WithdrawEvents({
    requested = true, withdrawerIsAdmin = true, withdrawer = admin,
    generation = deliverP._consumables.generation, epoch = deliverP._consumables.assignments[tostring(aqirite)].epoch, timestamp = C.Now(),
}, aqirite, 4))
assertTrue(select(1, C.RemoveAssignment(deliverP, admin, aqirite, sully, { asAdmin = true })))
local retired = C.CustodyFor(deliverP, admin, aqirite)
assertTrue(retired and retired.retired, "custody remains and is marked retired")
assertFalse(select(1, C.ResolveCustody(deliverP, donor, admin, aqirite, "Used")), "non-admin cannot resolve")
assertTrue(select(1, C.ResolveCustody(deliverP, admin, admin, aqirite, "Used", { asAdmin = true })), "admin resolve clears the whole entry")
assertEq(C.CustodyFor(deliverP, admin, aqirite), nil, "resolved custody is gone")
assertEq(C.ContributionTotal(deliverP, admin, aqirite), 5, "resolve does not create contribution")

-- Clear keeps logs and drops current state
local clearP = profile("clear", admin)
assertTrue(select(1, C.SetGuild(clearP, admin, { guid = "club-1", name = "Spectrum", realm = "Realm" }, 2, { asAdmin = true })))
assertFalse(select(1, C.SetGuild(clearP, admin, { guid = "club-2", name = "Other", realm = "Realm" }, 1, { asAdmin = true })), "guild identity stays locked")
assertTrue(select(1, C.AddCrafter(clearP, admin, vann, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(clearP, admin, aqirite, vann, { asAdmin = true })))
C.CommitEvents(clearP, "pre-clear", W.WithdrawEvents({
    requested = true, withdrawerIsAdmin = true, withdrawer = admin,
    generation = clearP._consumables.generation, epoch = clearP._consumables.assignments[tostring(aqirite)].epoch, timestamp = C.Now(),
}, aqirite, 3))
local warning = C.ClearConfirmation(clearP)
assertTrue(warning:find("Outstanding custody") ~= nil, "clear confirmation warns about custody")
local beforeLogs = #clearP._consumableEvents
assertTrue(select(1, C.Clear(clearP, admin, { asAdmin = true })), "admin can clear")
assertEq(clearP._consumables.guild, nil, "clear removes guild configuration")
assertEq(#clearP._consumables.crafters, 0, "clear removes crafters")
assertEq(#C.Project(clearP).custody, 0, "clear removes current custody")
assertEq(#clearP._consumableEvents, 0, "clear moves the previous generation out of the live ledger")
assertTrue(#C.HistoryRows(clearP) > beforeLogs, "clear keeps historical events and adds a reset")
local sawReset = false
for i = 1, #C.HistoryRows(clearP) do
    if C.HistoryRows(clearP)[i].text:find("cleared the Raid Consumables configuration") then
        sawReset = true
    end
end
assertTrue(sawReset, "reset history is human readable")
assertEq(C.ReceiptTotal(clearP, aqirite, vann), 0, "new generation does not keep old routing totals")
unchanged(clearP, "clear")

-- Profile copy and snapshot
local source = profile("source", admin)
assertTrue(select(1, C.SetGuild(source, admin, { guid = "club-9", name = "Spectrum", realm = "Realm" }, 4, { asAdmin = true })))
assertTrue(select(1, C.AddCrafter(source, admin, vann, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(source, admin, aqirite, vann, { asAdmin = true })))
seedReceipt(source, vann, 12, "source-receipt")
local copy = profile("copy", admin)
C.CopyConfiguration(source, copy)
assertEq(copy._consumables.guild.guid, "club-9", "copy keeps the guild")
assertEq(copy._consumables.bankTab, 4, "copy keeps the bank tab")
assertEq(copy._consumables.crafters[1], vann, "copy keeps crafters")
assertEq(copy._consumables.assignments[tostring(aqirite)].epoch, 1, "copy starts fresh routing epochs")
assertEq(#copy._consumableEvents, 0, "copy drops consumable history")
assertEq(C.ReceiptTotal(copy, aqirite, vann), 0, "copy starts at zero receipts")
assertEq(#C.Project(copy).custody, 0, "copy starts with no custody")
assertEq(copy._consumables.generation, 1, "copy starts a fresh generation")

local snap = C.ExportSnapshot(source)
local joiner = profile("joiner", admin)
assertTrue(C.MergeSnapshot(joiner, snap), "snapshot import succeeds")
assertEq(C.ReceiptTotal(joiner, aqirite, vann), 12, "joining client reconstructs receipts")
assertTrue(C.MergeSnapshot(joiner, snap), "snapshot replay is idempotent")
assertEq(#joiner._consumableEvents, #source._consumableEvents, "replay does not duplicate events")
local stale = C.ExportSnapshot(joiner)
stale.configSeq = 0
stale.generation = 1
stale.crafters = {}
assertTrue(C.MergeSnapshot(joiner, stale), "older snapshot config does not replace newer config")
assertEq(joiner._consumables.crafters[1], vann, "newer local config wins an older snapshot")

-- Sync authorization
local syncP = profile("sync", admin)
assertFalse(S.AuthorizeOp(syncP, { name = "add_crafter", crafter = vann }, donor), "remote non-admin cannot add a crafter")
assertTrue(S.AuthorizeOp(syncP, { name = "add_crafter", crafter = vann }, admin), "remote admin can add a crafter")
assertTrue(select(1, C.AddCrafter(syncP, admin, vann, { asAdmin = true })))
assertTrue(S.AuthorizeOp(syncP, { name = "add_assignment", itemId = aqirite, crafter = vann }, vann), "crafter can propose their own assignment")
assertFalse(S.AuthorizeOp(syncP, { name = "add_assignment", itemId = aqirite, crafter = sully }, vann), "crafter cannot propose another crafter's assignment")
local appliedConfig = C.ExportSnapshot(syncP)
appliedConfig.configSeq = syncP._consumables.configSeq
local peer = profile("peer", admin)
C.ReplaceConfig(peer, { generation = 1, configSeq = 0, crafters = {}, assignments = {} })
local okApply, status = S.ApplyRemoteConfig(peer, appliedConfig, donor)
assertFalse(okApply, "unauthorized config replacement is rejected")
assertEq(status, "unauthorized", "unauthorized config status")
okApply, status = S.ApplyRemoteConfig(peer, appliedConfig, admin)
assertTrue(okApply, "admin config replacement is accepted")
assertEq(status, "applied", "admin config applied")
okApply, status = S.ApplyRemoteConfig(peer, appliedConfig, admin)
assertEq(status, "stale", "equal config sequence is stale")
local gap = C.ExportSnapshot(syncP)
gap.configSeq = peer._consumables.configSeq + 5
okApply, status = S.ApplyRemoteConfig(peer, gap, admin)
assertEq(status, "gap", "a skipped config sequence requests catch-up")
local forged = {
    id = "ce:forged:" .. sully .. ":1",
    type = C.EVENT.DONATION,
    actor = donor,
    itemId = aqirite,
    quantity = 9,
    generation = peer._consumables.generation,
    source = "guildbank",
    timestamp = C.Now(),
}
assertFalse(select(1, S.ApplyRemoteEvent(peer, forged, sully)), "another player cannot forge a bank donation")
forged.actor = sully
assertTrue(select(1, S.ApplyRemoteEvent(peer, forged, sully)), "the depositor can record their donation")
assertTrue(select(2, S.ApplyRemoteEvent(peer, forged, sully)) == "duplicate", "event replay is a duplicate")
assertEq(C.ContributionTotal(peer, sully, aqirite), 9, "one donation survives replay")

local function custodyEvent(id, action, actor, extra)
    local event = {
        id = "ce:" .. actor .. ":" .. id,
        type = C.EVENT.CUSTODY,
        action = action,
        actor = actor,
        itemId = aqirite,
        quantity = 4,
        generation = peer._consumables.generation,
        timestamp = C.Now(),
    }
    for key, value in pairs(extra or {}) do
        event[key] = value
    end
    return event
end
assertFalse(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:1", C.ACTION.WITHDRAW, donor, { holder = donor }), donor)), "a non-admin cannot record custody")
assertFalse(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:2", C.ACTION.WITHDRAW, admin, { holder = donor }), admin)), "custody withdraw writer must be the holder")
assertTrue(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:3", C.ACTION.WITHDRAW, admin, { holder = admin }), admin)), "an admin can record their own withdrawal")
assertFalse(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:4", "steal", admin, { holder = admin }), admin)), "an unknown custody action is rejected")
peer._adminUsers[#peer._adminUsers + 1] = vann
assertFalse(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:5", C.ACTION.TRANSFER, admin, { fromHolder = admin, toHolder = vann }), admin)), "custody transfer is written by the receiver")
assertTrue(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:6", C.ACTION.TRANSFER, vann, { fromHolder = admin, toHolder = vann }), vann)), "the receiving admin can record a custody transfer")
assertTrue(select(1, C.AddCrafter(peer, admin, sully, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(peer, admin, aqirite, sully, { asAdmin = true })))
assertFalse(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:7", C.ACTION.DELIVER, donor, { fromHolder = admin, toHolder = donor }), donor)), "delivery requires the assigned crafter")
assertTrue(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:8", C.ACTION.DELIVER, sully, { fromHolder = admin, crafter = sully }), sully)), "the assigned crafter can record delivery")
assertFalse(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:9", C.ACTION.DELIVER, sully, { fromHolder = admin, toHolder = sully, crafter = donor }), sully)), "a delivery cannot name a different crafter")
assertFalse(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:10", C.ACTION.DELIVER, sully, { fromHolder = admin, crafter = sully, toHolder = donor }), sully)), "a delivery cannot name a different holder")
assertTrue(select(1, S.ApplyRemoteEvent(peer, custodyEvent("ce:cw:11", C.ACTION.DELIVER, sully, { fromHolder = admin, crafter = sully, toHolder = sully }), sully)), "a delivery that names the sender as crafter and holder is accepted")
local foreignReceipt = {
    id = "ce:forged:" .. donor .. ":receipt",
    type = C.EVENT.RECEIPT,
    actor = donor,
    crafter = donor,
    itemId = aqirite,
    quantity = 3,
    generation = peer._consumables.generation,
    epoch = 1,
    timestamp = C.Now(),
}
assertFalse(select(1, S.ApplyRemoteEvent(peer, foreignReceipt, donor)), "a receipt requires the assigned crafter")
local claimed = {
    id = "ce:forged:" .. vann .. ":claimed",
    type = C.EVENT.DONATION,
    actor = sully,
    itemId = aqirite,
    quantity = 1,
    generation = peer._consumables.generation,
    source = "guildbank",
    timestamp = C.Now(),
}
assertFalse(select(1, S.ApplyRemoteEvent(peer, claimed, sully)), "an event id must belong to the sending character")
local tradeDonation = {
    id = "ce:trade:" .. vann .. ":1",
    type = C.EVENT.DONATION,
    source = "trade",
    actor = donor,
    crafter = vann,
    itemId = aqirite,
    quantity = 4,
    generation = peer._consumables.generation,
    timestamp = C.Now(),
}
assertFalse(select(1, S.ApplyRemoteEvent(peer, tradeDonation, vann)), "a trade donation requires the assigned Crafter")
assertTrue(select(1, C.AddAssignment(peer, admin, aqirite, vann, { asAdmin = true })), "the attesting Crafter is assigned the item")
assertTrue(select(1, S.ApplyRemoteEvent(peer, tradeDonation, vann)), "the assigned Crafter can attest a trade donation")
local peerOrder = { id = "ce:ordered", order = 1, writer = donor }
assertTrue(select(1, S.RemoteEventAdmission(true, false, peerOrder)), "the coordinator accepts a peer event")
assertEq(peerOrder.order, nil, "the coordinator strips a peer-supplied ledger order")
assertEq(peerOrder.writer, nil, "the coordinator strips a peer-supplied writer")
assertFalse(select(1, S.RemoteEventAdmission(false, false, { order = 1 })), "a follower ignores an event that did not come from the coordinator")
local _, followerRelay = S.RemoteEventAdmission(false, true, { order = 2 })
assertTrue(followerRelay, "a follower accepts a coordinator-stamped event")
local cappedLedger = profile("ledger-cap", admin)
local previousCap = C.MAX_LEDGER_EVENTS
C.MAX_LEDGER_EVENTS = 1
assertTrue(select(1, C.AppendEvent(cappedLedger, {
    id = "ce:cap:1", type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1,
}, { silent = true })), "the first ledger event is stored")
assertFalse(select(1, C.AppendEvent(cappedLedger, {
    id = "ce:cap:2", type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1,
}, { silent = true })), "the ledger stops accepting events at its cap")
C.MAX_LEDGER_EVENTS = previousCap
local relayed = {
    id = "ce:relay:" .. sully .. ":1",
    type = C.EVENT.RECEIPT,
    actor = sully,
    crafter = sully,
    itemId = aqirite,
    quantity = 2,
    generation = peer._consumables.generation,
    epoch = peer._consumables.assignments[tostring(aqirite)].epoch,
    timestamp = C.Now(),
    order = 4,
    writer = sully,
}
assertFalse(select(1, S.ApplyRemoteEvent(peer, relayed, admin)), "a coordinator broadcast is not treated as the coordinator's own event")
assertTrue(select(1, S.ApplyRemoteEvent(peer, relayed, admin, { coordinatorRelay = true })), "a coordinator relay is authorized as the original writer")
local flags = { Vann = { consumablesCapable = true, inGroup = true } }
S.ClearCapabilityFlags(flags)
assertEq(flags.Vann.consumablesCapable, nil, "a new session forgets consumables capability")
local opBucket = {}
for _ = 1, S.MAX_REMOTE_OPS do
    assertTrue(S.AllowRemoteOp(opBucket, donor, 1000), "remote ops are allowed inside the window")
end
assertFalse(S.AllowRemoteOp(opBucket, donor, 1000), "remote ops past the window cap are throttled")
assertTrue(S.AllowRemoteOp(opBucket, donor, 1000 + S.REMOTE_OP_WINDOW), "the remote op window resets")
local capped = profile("cap", admin)
assertTrue(select(1, C.AddCrafter(capped, admin, vann, { asAdmin = true })))
C.MAX_ASSIGNMENT_PAIRS = 1
assertTrue(select(1, C.AddAssignment(capped, admin, aqirite, vann, { asAdmin = true })))
assertFalse(select(1, C.AddAssignment(capped, admin, aqiriteRank2, vann, { asAdmin = true })), "assignment growth stops at the stability cap")
C.MAX_ASSIGNMENT_PAIRS = 256
local configOnly = C.ExportSnapshot(capped, { omitEvents = true })
assertEq(configOnly.events, nil, "config broadcast export skips the event ledger")

local state = { active = true, sessionId = "session-1", profileId = "peer" }
assertFalse(S.SessionEnvelopeOk(state, { profileId = "peer" }), "a missing session id is rejected")
assertFalse(S.SessionEnvelopeOk(state, { sessionId = "other", profileId = "peer" }), "a different session id is rejected")
assertTrue(S.SessionEnvelopeOk(state, { sessionId = "session-1", profileId = "peer" }), "the current session envelope is accepted")
assertFalse(S.RemoteConfigSenderOk("Coord-Realm", donor), "config is not accepted from a non-coordinator")
assertTrue(S.RemoteConfigSenderOk("Coord-Realm", "Coord-Realm"), "config is accepted from the coordinator")
local offline = profile("offline-config", admin)
C.ReplaceConfig(offline, { generation = 1, configSeq = 7, crafters = { donor }, assignments = {} })
local coordinatorConfig = { generation = 1, configSeq = 3, crafters = { vann }, assignments = {} }
assertEq(select(2, S.ApplyRemoteConfig(offline, coordinatorConfig, admin, { coordinatorAuthoritative = true })), "applied", "a session coordinator replaces a higher local config sequence")
assertEq(offline._consumables.crafters[1], vann, "coordinator crafters replace the offline list")
assertEq(select(2, S.ApplyRemoteConfig(offline, coordinatorConfig, admin, { coordinatorAuthoritative = true })), "stale", "an older coordinator config is not applied twice")
assertEq(select(2, S.ApplyRemoteConfig(offline, { generation = 1, configSeq = 4, crafters = { sully }, assignments = {} }, admin, { coordinatorAuthoritative = true })), "applied", "a newer coordinator config still applies")
S.ClearCoordinatorWatermarks()
C.ReplaceConfig(offline, { generation = 1, configSeq = 7, crafters = { donor }, assignments = {} })
offline._consumablesAdoptNextSnapshot = "session-9"
assertTrue(select(1, C.MergeSnapshot(offline, { generation = 1, configSeq = 1, crafters = { donor }, assignments = {} })), "session snapshot adoption succeeds")
assertEq(offline._consumables.configSeq, 1, "the first session snapshot adopts the coordinator config")
assertEq(offline._consumablesConfigAdoptedSession, "session-9", "session config adoption is recorded once")
local sameLedger = { generation = 1, configSeq = 0, eventCount = 2, eventFingerprint = 11 }
assertFalse(S.NeedsCatchUp(sameLedger, sameLedger), "matching fingerprints do not catch up")
assertTrue(S.NeedsCatchUp(sameLedger, { generation = 1, configSeq = 0, eventCount = 2, eventFingerprint = 22 }), "a different fingerprint catches up")
assertEq(S.CatchUpKind(sameLedger, { generation = 1, configSeq = 0, eventCount = 2, eventFingerprint = 22 }), "fingerprint", "a fingerprint-only difference is not an ahead catch-up")
assertEq(S.CatchUpKind(sameLedger, { generation = 1, configSeq = 0, eventCount = 3, eventFingerprint = 22 }), "ahead", "a higher event count catches up immediately")
assertTrue(S.CoordinatorConfigDiffers(sameLedger, { generation = 1, configSeq = 4 }), "a different config sequence is a coordinator config difference")
assertFalse(S.NeedsCatchUp(sameLedger, { generation = 1, configSeq = 0, eventCount = 2 }), "an older client without a fingerprint stays on the count check")

assertFalse(R.PeerCompatible({ proto = 4, addonVersion = "1.5.6" }, false), "protocol and version do not make a peer consumables-capable")
assertTrue(R.PeerCompatible({ consumablesCapable = true }, false), "an explicit capability flag makes a peer compatible")
assertTrue(R.PeerCompatible(nil, true), "the local player is consumables-capable")

-- Linked identity totals stay character-specific for operations
local linkP = profile("link", admin)
linkP._identity[donor] = { donor, "Alt-Realm" }
linkP._identity["Alt-Realm"] = { donor, "Alt-Realm" }
assertTrue(select(1, C.AddCrafter(linkP, admin, vann, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(linkP, admin, aqirite, vann, { asAdmin = true })))
local linkFrozen = C.FreezeTrade(linkP, donor, vann, { { itemId = aqirite } }, "link")
C.CommitEvents(linkP, "link", W.TradeEvents(linkFrozen, { [aqirite] = 7 }, true))
local altFrozen = C.FreezeTrade(linkP, "Alt-Realm", vann, { { itemId = aqirite } }, "alt")
C.CommitEvents(linkP, "alt", W.TradeEvents(altFrozen, { [aqirite] = 4 }, true))
assertEq(C.ContributionTotal(linkP, donor, aqirite), 11, "linked characters share contribution totals")
assertFalse(C.IsCrafter(linkP, "Alt-Realm"), "crafter state is not merged across a linked identity")
assertEq(C.ReceiptTotal(linkP, aqirite, "Alt-Realm"), 0, "receipts stay on the receiving character")

-- Passive accounting ignores the reminder preference
local passive = W.TradeEvents(linkFrozen, { [aqirite] = 3 }, true)
assertTrue(#passive > 0, "passive trade accounting does not consult the reminder setting")
local model = C.SettingsModel(linkP, vann, false)
assertFalse(model.canClear, "non-admin crafter cannot clear")
assertFalse(model.canManageCrafters, "non-admin crafter cannot manage crafters")
assertTrue(model.isCrafter, "settings model recognizes the crafter")
local adminModel = C.SettingsModel(linkP, admin, true)
assertTrue(adminModel.canClear, "admin settings model can clear")
assertTrue(#adminModel.custody == 0, "admin can see the custody list")

-- History ordering, generations, and no protocol text
local rows = C.HistoryRows(source)
assertTrue(#rows >= 2, "history includes multiple events")
assertTrue((rows[1].timestamp or 0) >= (rows[#rows].timestamp or 0), "history is newest first")
for i = 1, #rows do
    assertFalse(rows[i].text:find("ce:", 1, true) ~= nil, "history omits event ids")
    assertEq(rows[i].text:find("configSeq", 1, true), nil, "history omits protocol fields")
end

-- Generation boundary: old donation does not count after clear, but the row remains
local genP = profile("gen", admin)
assertTrue(select(1, C.AddCrafter(genP, admin, vann, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(genP, admin, aqirite, vann, { asAdmin = true })))
local genFrozen = C.FreezeTrade(genP, donor, vann, { { itemId = aqirite } }, "gen")
C.CommitEvents(genP, "gen", W.TradeEvents(genFrozen, { [aqirite] = 6 }, true))
assertTrue(select(1, C.Clear(genP, admin, { asAdmin = true })))
assertEq(#genP._consumableEvents, 0, "clear moves the previous generation out of the live ledger")
assertEq(C.Descriptor(genP).eventCount, 0, "clear advertises an empty live ledger")
assertEq(C.ContributionTotal(genP, donor, aqirite), 0, "old generation contributions are not active")
local kept = false
for i = 1, #C.HistoryRows(genP) do
    if C.HistoryRows(genP)[i].text:find("donated 6") then kept = true end
end
assertTrue(kept, "old generation donations remain in the log")

unchanged(p, "domain")
assertEq(#W.EventsFromUnsupportedInventoryDecrease(), 0, "unsupported exits stay empty")

assertEq(C.ItemIdFromText(190000), 190000, "item id accepts a number")
assertEq(C.ItemIdFromText("190000"), 190000, "item id accepts digits")
assertEq(C.ItemIdFromText("|cff0070dd|Hitem:190001::::::::80:::::|h[Aqirite]|h|r"), 190001, "item id accepts an item link")
assertEq(C.ItemIdFromText("not-an-item"), nil, "item id rejects prose")

local freezeP = profile("freeze-set", admin)
assertTrue(select(1, C.AddCrafter(freezeP, admin, sully, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(freezeP, admin, aqirite, sully, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(freezeP, admin, aqiriteRank2, sully, { asAdmin = true })))
C.CommitEvents(freezeP, "freeze-custody", W.WithdrawEvents({
    requested = true, withdrawerIsAdmin = true, withdrawer = admin,
    generation = freezeP._consumables.generation,
    epoch = freezeP._consumables.assignments[tostring(aqirite)].epoch,
    timestamp = C.Now(),
}, aqirite, 4))
local wide = C.FreezeTrade(freezeP, admin, sully, { { itemId = aqirite } }, "wide")
assertTrue(wide.items[aqirite] ~= nil, "freeze includes the hinted item")
assertTrue(wide.items[aqiriteRank2] ~= nil, "freeze includes other requested items")
assertEq(wide.items[aqirite].custodyQty, 4, "freeze records donor custody")
local extra = W.TradeEvents(wide, { [aqirite] = 4 }, true)
local sawRank = false
for i = 1, #extra do
    if extra[i].itemId == aqiriteRank2 then sawRank = true end
end
assertFalse(sawRank, "frozen untraded items do not create events")

local orderP = profile("order", admin)
orderP._adminUsers = { admin, vann }
C.AppendEvent(orderP, {
    id = "ce:order:withdraw",
    type = C.EVENT.CUSTODY,
    action = C.ACTION.WITHDRAW,
    holder = admin,
    actor = admin,
    itemId = aqirite,
    quantity = 10,
    generation = 1,
    timestamp = 500,
    order = 1,
}, { silent = true })
C.AppendEvent(orderP, {
    id = "ce:order:transfer",
    type = C.EVENT.CUSTODY,
    action = C.ACTION.TRANSFER,
    fromHolder = admin,
    toHolder = vann,
    actor = vann,
    itemId = aqirite,
    quantity = 10,
    generation = 1,
    timestamp = 100,
    order = 2,
}, { silent = true })
local transferred = C.CustodyFor(orderP, vann, aqirite)
assertEq(transferred and transferred.quantity, 10, "coordinator order applies a withdrawal before a later transfer")
assertEq(C.CustodyFor(orderP, admin, aqirite), nil, "ordered transfer moves the withdrawn stack")
assertEq(orderP._consumables.ledgerSeq, 2, "appended coordinator order raises the ledger high water")
local nextEvent = { id = "ce:order:next", type = C.EVENT.RESET, actor = admin, generation = 1 }
assertEq(C.StampOrder(orderP, nextEvent), 3, "the next coordinator order follows the imported high water")
local beforePatch = C.Descriptor(orderP).eventFingerprint
C.AppendEvent(orderP, {
    id = "ce:order:withdraw",
    type = C.EVENT.CUSTODY,
    action = C.ACTION.WITHDRAW,
    holder = admin,
    actor = admin,
    itemId = aqirite,
    quantity = 10,
    generation = 1,
    timestamp = 500,
    order = 1,
}, { silent = true })
assertEq(orderP._consumableEvents[1].order, 1, "a sequenced replay keeps the stored order")
assertEq(C.Descriptor(orderP).eventFingerprint, beforePatch, "replaying an event does not change the fingerprint")
assertTrue(beforePatch ~= 0, "the ledger fingerprint changes once events exist")
local listed = orderP._consumableEvents[1]
orderP._consumableEventIds = { [listed.id] = { id = listed.id } }
C.InvalidateEventIndex(orderP)
C.Ensure(orderP)
assertTrue(C.EventIndex(orderP)[listed.id] == listed, "loading rebinds the event index to the saved ledger")
assertEq(orderP._consumableEventIds, nil, "the event index is not stored on the saved profile")

local fullP = profile("commit-full", admin)
local commitCap = C.MAX_LEDGER_EVENTS
C.MAX_LEDGER_EVENTS = 0
local fullOk, fullErr = C.CommitEvents(fullP, "full-token", {
    { type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1 },
})
assertFalse(fullOk, "a full ledger does not report a successful commit")
assertTrue(type(fullErr) == "string" and fullErr:find("full") ~= nil, "a full ledger explains why the commit failed")
assertEq(#fullP._consumableEvents, 0, "a rejected commit does not append an event")
C.MAX_LEDGER_EVENTS = commitCap

local stampP = profile("stamp-cache", admin)
stampP._adminUsers = { admin, vann }
C.AppendEvent(stampP, {
    id = "ce:stamp:withdraw",
    type = C.EVENT.CUSTODY,
    action = C.ACTION.WITHDRAW,
    holder = admin,
    actor = admin,
    itemId = aqirite,
    quantity = 10,
    generation = 1,
    timestamp = 200,
}, { silent = true })
C.AppendEvent(stampP, {
    id = "ce:stamp:transfer",
    type = C.EVENT.CUSTODY,
    action = C.ACTION.TRANSFER,
    fromHolder = admin,
    toHolder = vann,
    actor = vann,
    itemId = aqirite,
    quantity = 10,
    generation = 1,
    timestamp = 100,
}, { silent = true })
assertEq(C.CustodyFor(stampP, admin, aqirite) and C.CustodyFor(stampP, admin, aqirite).quantity, 10, "before an order, timestamp puts the withdrawal last")
assertEq(C.CustodyFor(stampP, vann, aqirite), nil, "an earlier timestamp cannot transfer stock that is not yet withdrawn")
local withdrawStored = stampP._consumableEvents[1]
local transferStored = stampP._consumableEvents[2]
assertTrue(C.EventIndex(stampP)[withdrawStored.id] == withdrawStored, "the withdrawal stamp uses the stored record")
assertEq(C.StampOrder(stampP, withdrawStored), 1, "the stored withdrawal receives the first order")
assertEq(C.StampOrder(stampP, transferStored), 2, "the stored transfer receives the next order")
assertEq(C.CustodyFor(stampP, vann, aqirite) and C.CustodyFor(stampP, vann, aqirite).quantity, 10, "assigning order rebuilds custody even when the stored table is stamped directly")
assertEq(C.CustodyFor(stampP, admin, aqirite), nil, "the rebuilt projection applies the withdrawal before the transfer")
local visible = C.HistoryRows(stampP, nil, 1)
assertEq(#visible, 1, "history display can stop after the newest rows")
assertTrue(#C.HistoryRows(stampP) >= 2, "an unlimited history request still returns the ledger")
local cycleP = profile("event-order", admin)
C.AppendEvent(cycleP, {
    id = "ce:cycle:a", type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1,
    generation = 1, timestamp = 100, order = 1,
}, { silent = true })
C.AppendEvent(cycleP, {
    id = "ce:cycle:b", type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 2,
    generation = 1, timestamp = 50,
}, { silent = true })
C.AppendEvent(cycleP, {
    id = "ce:cycle:c", type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 3,
    generation = 1, timestamp = 10, order = 2,
}, { silent = true })
local cycleRows = C.HistoryRows(cycleP)
assertEq(#cycleRows, 3, "mixed stamped and unstamped events still sort")
assertTrue(cycleRows[1].text:find("donated 2") ~= nil, "an unstamped event sorts after stamped events")
assertTrue(cycleRows[2].text:find("donated 3") ~= nil, "a later order sorts ahead of an earlier order in history")
assertTrue(cycleRows[3].text:find("donated 1") ~= nil, "the earliest order is the oldest history row")

load("SpectrumFederation/modules/LootHelperSync/19_Consumables.lua")
local Sync = SF.LootHelperSync
local safeP = profile("safe-op", admin)
Sync.state = {
    active = true,
    isCoordinator = false,
    coordinator = "Coord-Realm",
    peers = { ["Coord-Realm"] = { consumablesCapable = true } },
    sessionId = "session",
    profileId = safeP._profileId,
}
Sync.MSG = { CONSUMABLES_OP = "CONSUMABLES_OP" }
Sync.IsSafeModeEnabled = function() return true end
local opSent = false
SF.LootHelperComm = {
    Send = function()
        opSent = true
    end,
}
local safeOk, safeErr = Sync:CommitConsumablesOp(safeP, { name = "set_bank_tab", bankTab = 2 }, admin, { asAdmin = true })
assertFalse(safeOk, "a follower does not treat a safe-mode config edit as pending")
assertFalse(opSent, "a follower does not whisper a config edit while safe mode drops bulk messages")
assertTrue(type(safeErr) == "string" and safeErr:find("safe mode") ~= nil, "safe mode tells the player to retry")
assertEq(safeP._consumables.bankTab, nil, "a rejected safe-mode edit does not change the follower")
Sync.state.isCoordinator = true
local coordOk = Sync:CommitConsumablesOp(safeP, { name = "set_bank_tab", bankTab = 3 }, admin, { asAdmin = true })
assertFalse(coordOk, "the coordinator does not apply a config edit that safe mode would drop")
assertEq(safeP._consumables.bankTab, nil, "a rejected coordinator edit stays unchanged during safe mode")
Sync.state.isCoordinator = false
Sync.IsSafeModeEnabled = function() return false end
local openOk = Sync:CommitConsumablesOp(safeP, { name = "set_bank_tab", bankTab = 2 }, admin, { asAdmin = true })
assertTrue(openOk, "a follower can send a config edit after safe mode ends")
assertTrue(opSent, "the config edit is whispered once safe mode is off")

local secureTemplates = {}
local function FrameMock()
    local frame = {}
    function frame:SetSize() end
    function frame:SetPoint(point, relativeTo, relativePoint, x, y)
        self.anchorPoint = point
        self.anchorTo = relativeTo
        self.anchorRelative = relativePoint
        self.anchorX = x
        self.anchorY = y
    end
    function frame:ClearAllPoints()
        self.anchorPoint = nil
        self.anchorTo = nil
        self.anchorRelative = nil
        self.anchorX = nil
        self.anchorY = nil
    end
    function frame:SetAllPoints(relativeTo)
        self.allPointsTo = relativeTo
    end
    function frame:GetLeft()
        return self.left or 100
    end
    function frame:GetBottom()
        return self.bottom or 200
    end
    function frame:SetFrameStrata() end
    function frame:EnableMouse() end
    function frame:SetMovable() end
    function frame:RegisterForDrag() end
    function frame:SetScript(name, handler)
        self.scripts = self.scripts or {}
        self.scripts[name] = handler
    end
    function frame:StartMoving()
        self.startedMoving = (self.startedMoving or 0) + 1
    end
    function frame:StopMovingOrSizing()
        self.stoppedMoving = (self.stoppedMoving or 0) + 1
    end
    function frame:SetBackdrop() end
    function frame:SetText() end
    function frame:SetJustifyH() end
    function frame:SetWidth() end
    function frame:SetHeight() end
    function frame:SetAutoFocus() end
    function frame:SetNumeric() end
    function frame:Hide()
        self.hideCalls = (self.hideCalls or 0) + 1
        self.shown = false
    end
    function frame:Show()
        self.showCalls = (self.showCalls or 0) + 1
        self.shown = true
    end
    function frame:SetScrollChild() end
    function frame:SetShown(shown)
        self.shownCalls = (self.shownCalls or 0) + 1
        self.shown = shown and true or false
    end
    function frame:SetAttribute() end
    function frame:Enable() end
    function frame:Disable() end
    function frame:IsShown() return self.shown == true end
    function frame:CreateFontString() return FrameMock() end
    return frame
end
function CreateFrame(_, _, parent, template)
    local frame = FrameMock()
    frame.parent = parent
    if type(template) == "string" and template:find("SecureActionButtonTemplate", 1, true) then
        secureTemplates[#secureTemplates + 1] = template
    end
    return frame
end
UIParent = {}
function InCombatLockdown() return false end
load("SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua")
local RT = SF.ConsumablesRuntime
C.RevalidateDonation = function() return true end
RT.bagCounts = { [aqirite] = 5 }
RT.groupMap = { ["Crafter-Realm"] = "raid1" }
local initiated = false
function InitiateTrade()
    initiated = true
end
local tradeTimer = nil
C_Timer = {
    NewTimer = function(_, fn)
        tradeTimer = fn
        return {
            Cancel = function()
                tradeTimer = nil
            end,
        }
    end,
}
RT:BeginTrade({ itemId = aqirite, quantity = 1, recipient = "Crafter-Realm" }, {})
assertTrue(initiated, "a reviewed donation still starts the trade")
assertTrue(RT.pendingTrade ~= nil, "the donation stays pending until the trade opens or fails")
assertTrue(type(tradeTimer) == "function", "a pending donation expires if the trade window never opens")
RT:OnEvent("TRADE_REQUEST_CANCEL")
assertEq(RT.pendingTrade, nil, "cancelling the trade request drops the pending donation")
RT.openTrade = { both = true, target = { [aqirite] = 4 }, role = "receiver" }
RT:OnEvent("TRADE_REQUEST_CANCEL")
assertEq(RT.openTrade.both, false, "cancelling an open trade drops the accepted snapshot")
assertEq(RT.openTrade.target[aqirite], nil, "cancelling an open trade drops the captured target items")
RT.openTrade.both = true
RT.openTrade.target = { [aqirite] = 4 }
ERR_TRADE_BAG_FULL = "bag full"
RT:OnEvent("UI_ERROR_MESSAGE", 0, ERR_TRADE_BAG_FULL)
assertEq(RT.openTrade.both, false, "a failed accepted trade drops the accepted snapshot")
assertEq(RT.openTrade.target[aqirite], nil, "a failed accepted trade drops the captured target items")
RT.openTrade.both = true
RT:OnEvent("UI_ERROR_MESSAGE", 0, "You are too far away.")
assertEq(RT.openTrade.both, true, "an unrelated error leaves an accepted trade snapshot in place")
RT.pendingTrade = { recipient = "Crafter-Realm" }
RT.openTrade = { role = "donor" }
RT:ArmPendingTradeTimer()
assertTrue(type(tradeTimer) == "function", "the expiry timer is armed again")
tradeTimer()
assertTrue(RT.pendingTrade ~= nil, "an open trade is not cleared by the request timeout")
RT.openTrade = nil
RT:ArmPendingTradeTimer()
tradeTimer()
assertEq(RT.pendingTrade, nil, "the request timeout clears a donation that never opened")

function InCombatLockdown() return true end
RT.review = nil
RT.mobileParent = nil
RT.mobileButtonPending = nil
RT:EnsureReview()
assertEq(#secureTemplates, 0, "opening the review during combat does not create the secure banking button")
assertTrue(RT.review ~= nil, "the non-secure review frame can still be created during combat")
assertTrue(RT.mobileButtonPending == true, "the banking button waits until combat ends")
RT.review.scripts.OnDragStart(RT.review)
assertEq(RT.review.startedMoving, nil, "dragging the review during combat does not start moving")
function InCombatLockdown() return false end
RT.review.scripts.OnDragStart(RT.review)
assertEq(RT.review.startedMoving, 1, "dragging the review out of combat starts moving")
function InCombatLockdown() return true end
RT.review.scripts.OnDragStop(RT.review)
assertEq(RT.review.stoppedMoving, 1, "releasing a drag that started before combat still stops moving")
function InCombatLockdown() return false end
RT.review.scripts.OnDragStop(RT.review)
assertEq(RT.review.stoppedMoving, 2, "releasing the review out of combat stops moving")
local mobile = RT:EnsureMobileButton()
assertTrue(mobile ~= nil, "the banking button is created once combat ends")
assertEq(#secureTemplates, 1, "the secure button is created only outside combat")
assertTrue(mobile.parent ~= RT.review, "the secure banking button is not a child of the review")
assertTrue(mobile.parent == RT.mobileHolder, "the secure banking button is a child of the UIParent holder")
assertTrue(RT.mobileHolder.parent == UIParent, "the banking holder is parented to UIParent")
RT:PlaceMobileHolder()
assertEq(RT.mobileHolder.anchorTo, UIParent, "the banking holder anchors to UIParent, not the review")
assertTrue(RT.mobileHolder.anchorTo ~= RT.review, "the banking holder is not anchored to the review")
mobile.shownCalls = 0
mobile.SetShown = function(self)
    self.shownCalls = (self.shownCalls or 0) + 1
end
holderHideBefore = RT.mobileHolder.hideCalls or 0
function InCombatLockdown() return true end
RT.review.scripts.OnHide()
assertEq(mobile.shownCalls, 0, "closing the review during combat does not show or hide the secure button")
assertEq(RT.mobileHolder.hideCalls or 0, holderHideBefore, "closing the review during combat does not hide the banking holder")
function InCombatLockdown() return false end
RT.review.shown = false
RT.lastAccess = { action = "mobile" }
savedMobileSpell = RT.MobileSpell
RT.MobileSpell = function() return "Mobile Banking" end
RT:SyncMobileButton()
assertTrue((RT.mobileHolder.hideCalls or 0) > holderHideBefore, "out of combat, Sync hides the holder when the review is not shown")
RT.MobileSpell = savedMobileSpell
RT.lastAccess = nil

local archiveCap = C.MAX_LEDGER_EVENTS
C.MAX_LEDGER_EVENTS = 1
local archiveP = profile("archive", admin)
assertTrue(select(1, C.AppendEvent(archiveP, {
    id = "ce:archive:old",
    type = C.EVENT.DONATION,
    actor = admin,
    itemId = aqirite,
    quantity = 1,
    generation = 1,
    timestamp = 1,
}, { silent = true })), "the live ledger stores the current-generation event")
assertTrue(select(1, C.Clear(archiveP, admin, { asAdmin = true })), "clear still succeeds when the live ledger is full")
assertEq(archiveP._consumables.generation, 2, "clear advances the generation when history is archived")
assertTrue(select(1, C.AppendEvent(archiveP, {
    id = "ce:archive:new",
    type = C.EVENT.DONATION,
    actor = admin,
    itemId = aqirite,
    quantity = 2,
    generation = 2,
    timestamp = 2,
}, { silent = true })), "a later generation can record after prior history is archived")
assertEq(#archiveP._consumableEvents, 1, "the live ledger keeps only the current generation")
local sawClear, sawNew = false, false
local archivedRows = C.HistoryRows(archiveP)
for i = 1, #archivedRows do
    if archivedRows[i].text:find("cleared the Raid Consumables configuration") then sawClear = true end
    if archivedRows[i].text:find("donated 2") then sawNew = true end
end
assertTrue(sawClear, "the clear entry stays visible after the live ledger makes room")
assertTrue(sawNew, "the new donation stays visible with archived history")
assertFalse(select(1, C.AppendEvent(archiveP, {
    id = "ce:archive:overflow",
    type = C.EVENT.DONATION,
    actor = admin,
    itemId = aqirite,
    quantity = 1,
    generation = 2,
    timestamp = 3,
}, { silent = true })), "the current generation still stops at the live ledger cap")
C.MAX_LEDGER_EVENTS = archiveCap

local writer = "Writer-Realm"
local recoverP = profile("recover-order", admin)
C.AppendEvent(recoverP, {
    id = "ce:recover:" .. writer .. ":1",
    type = C.EVENT.DONATION,
    actor = writer,
    itemId = aqirite,
    quantity = 1,
    generation = 1,
    timestamp = 10,
    order = 4,
}, { silent = true })
C.AppendEvent(recoverP, {
    id = "ce:recover:Other-Realm:1",
    type = C.EVENT.DONATION,
    actor = "Other-Realm",
    itemId = aqirite,
    quantity = 1,
    generation = 1,
    timestamp = 11,
    order = 5,
}, { silent = true })
Sync.state = {
    active = true,
    isCoordinator = false,
    coordinator = "NewCoord-Realm",
    sessionId = "recover-session",
    profileId = recoverP._profileId,
}
Sync._SelfId = function() return writer end
Sync:_QueueAuthoredOrderedConsumablesEvents(recoverP, 1)
local recoverQueue = recoverP._consumablesUnsent or {}
local sawWriter, sawOther = false, false
for i = 1, #recoverQueue do
    if recoverQueue[i] == "ce:recover:" .. writer .. ":1" then sawWriter = true end
    if recoverQueue[i] == "ce:recover:Other-Realm:1" then sawOther = true end
end
assertTrue(sawWriter, "a writer resends an already ordered event the new coordinator lacks")
assertFalse(sawOther, "a client does not upload another writer's ordered event")
assertEq(recoverP._consumableEvents[1].order, 4, "the local ledger keeps the coordinator order it already stored")
local queuedOnce = #recoverQueue
Sync:_QueueAuthoredOrderedConsumablesEvents(recoverP, 1)
assertEq(#(recoverP._consumablesUnsent or {}), queuedOnce, "ordered recovery walks the ledger once per coordinator")

local importCap = C.MAX_LEDGER_EVENTS
local importArchiveCap = C.MAX_ARCHIVED_EVENTS
C.MAX_LEDGER_EVENTS = 2
C.MAX_ARCHIVED_EVENTS = 8
local function snapEvent(id, generation)
    return {
        id = id,
        type = C.EVENT.DONATION,
        generation = generation,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        timestamp = generation,
    }
end
local function hasEvent(list, id)
    if type(list) ~= "table" then return false end
    for i = 1, #list do
        if type(list[i]) == "table" and list[i].id == id then return true end
    end
    return false
end
local crowded = {
    generation = 2,
    configSeq = 1,
    crafters = {},
    assignments = {},
    events = {
        snapEvent("ce:snap:old1", 1),
        snapEvent("ce:snap:old2", 1),
        snapEvent("ce:snap:old3", 1),
        snapEvent("ce:snap:new", 2),
    },
}
local crowdedJoiner = profile("snapshot-full", admin)
assertTrue(C.MergeSnapshot(crowdedJoiner, crowded), "a snapshot with archived history still imports")
assertEq(crowdedJoiner._consumables.generation, 2, "snapshot import installs the remote generation")
assertTrue(hasEvent(crowdedJoiner._consumableEvents, "ce:snap:new"), "current-generation snapshot events survive a full archive import")
assertFalse(hasEvent(crowdedJoiner._consumableEvents, "ce:snap:old1"), "archived snapshot history does not fill the live ledger")
C.MAX_LEDGER_EVENTS = importCap
C.MAX_ARCHIVED_EVENTS = importArchiveCap
local roomP = profile("archive-room", admin)
roomP._consumables.generation = 2
local roomBefore = C.Descriptor(roomP)
assertTrue(select(1, C.AppendEvent(roomP, snapEvent("ce:room:old", 1), { silent = true })), "an older event is accepted while the live ledger has room")
assertFalse(hasEvent(roomP._consumableEvents, "ce:room:old"), "an older event does not enter the live ledger")
assertTrue(hasEvent(roomP._consumableEventArchive, "ce:room:old"), "an older event is archived before the capacity check")
assertEq(C.Descriptor(roomP).eventCount, roomBefore.eventCount, "an archived event does not change the live event count")
assertEq(C.Descriptor(roomP).eventFingerprint, roomBefore.eventFingerprint, "an archived event does not change the live fingerprint")
assertTrue(select(1, C.AppendEvent(roomP, snapEvent("ce:room:new", 2), { silent = true })), "the current generation still appends while the ledger has room")
assertTrue(hasEvent(roomP._consumableEvents, "ce:room:new"), "the current generation stays on the live ledger")

S.ClearCoordinatorWatermarks()
local takeoverP = profile("takeover-config", admin)
assertEq(select(2, S.ApplyRemoteConfig(takeoverP, {
    generation = 1, configSeq = 5, crafters = { vann }, assignments = {},
}, admin, { coordinatorAuthoritative = true, coordEpoch = 1 })), "applied", "the first coordinator config is applied")
assertEq(select(2, S.ApplyRemoteConfig(takeoverP, {
    generation = 1, configSeq = 4, crafters = { sully }, assignments = {},
}, admin, { coordinatorAuthoritative = true, coordEpoch = 2 })), "applied", "a new coordinator epoch applies a lower config sequence")
assertEq(takeoverP._consumables.crafters[1], sully, "the new coordinator's crafters replace the previous list")
assertEq(select(2, S.ApplyRemoteConfig(takeoverP, {
    generation = 1, configSeq = 9, crafters = { donor }, assignments = {},
}, admin, { coordinatorAuthoritative = true, coordEpoch = 1 })), "stale", "an older coordinator epoch cannot override the new one")
assertEq(takeoverP._consumables.crafters[1], sully, "the new coordinator's config stays in place")

local frozenP = profile("frozen-trade", admin)
assertTrue(select(1, C.AddCrafter(frozenP, admin, vann, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(frozenP, admin, aqirite, vann, { asAdmin = true })))
local frozenEpoch = frozenP._consumables.assignments[tostring(aqirite)].epoch
local frozenToken = "trade-" .. vann .. "-1-1"
local frozenTrade = C.FreezeTrade(frozenP, donor, vann, { { itemId = aqirite } }, frozenToken)
local frozenGrant = S.TradeFreezePayload(frozenTrade)
local frozenNow = C.Now()
assertTrue(S.RegisterTradeGrant(frozenP, frozenGrant, frozenNow), "an open trade is granted while the Crafter is still assigned")
assertTrue(select(1, C.RemoveAssignment(frozenP, admin, aqirite, vann, { asAdmin = true })))
assertFalse(C.CrafterHasItem(frozenP, vann, aqirite), "the live assignment is gone after the trade opened")
assertFalse(S.RegisterTradeGrant(frozenP, frozenGrant, C.Now()), "a removed Crafter cannot register another trade grant")
local function frozenEvent(id, typeName, extra)
    local event = {
        id = "ce:" .. frozenP._profileId .. ":" .. frozenToken .. ":" .. id,
        type = typeName,
        itemId = aqirite,
        quantity = 3,
        generation = frozenP._consumables.generation,
        epoch = frozenEpoch,
        tradeToken = frozenToken,
        timestamp = C.Now(),
    }
    for key, value in pairs(extra or {}) do
        event[key] = value
    end
    return event
end
local frozenDonation = frozenEvent("donation", C.EVENT.DONATION, {
    source = "trade", actor = donor, crafter = vann,
})
assertTrue(select(1, S.ApplyRemoteEvent(frozenP, frozenDonation, vann)), "a trade donation keeps the assignment frozen at trade open")
local reusedDonation = frozenEvent("again", C.EVENT.DONATION, {
    source = "trade", actor = donor, crafter = vann,
})
assertFalse(select(1, S.ApplyRemoteEvent(frozenP, reusedDonation, vann)), "a trade grant cannot authorize a second donation")
local victimDonation = frozenEvent("victim", C.EVENT.DONATION, {
    source = "trade", actor = sully, crafter = vann,
})
assertFalse(select(1, S.ApplyRemoteEvent(frozenP, victimDonation, vann)), "a trade grant cannot name a different donor")
local liveDonation = {
    id = "ce:frozen:" .. vann .. ":live",
    type = C.EVENT.DONATION,
    source = "trade",
    actor = donor,
    crafter = vann,
    itemId = aqirite,
    quantity = 1,
    generation = frozenP._consumables.generation,
    timestamp = C.Now(),
}
assertFalse(select(1, S.ApplyRemoteEvent(frozenP, liveDonation, vann)), "a trade donation without a frozen epoch still requires the live assignment")
local frozenReceipt = frozenEvent("receipt", C.EVENT.RECEIPT, {
    actor = vann, crafter = vann, source = "trade",
})
assertTrue(select(1, S.ApplyRemoteEvent(frozenP, frozenReceipt, vann)), "a trade receipt keeps the assignment frozen at trade open")
local frozenDeliver = frozenEvent("deliver", C.EVENT.CUSTODY, {
    action = C.ACTION.DELIVER, actor = vann, crafter = vann, fromHolder = donor, toHolder = vann, quantity = 1,
})
assertTrue(select(1, S.ApplyRemoteEvent(frozenP, frozenDeliver, vann)), "a trade delivery shares the open trade grant")
local forgedEpoch = frozenEvent("forged", C.EVENT.RECEIPT, {
    actor = vann, crafter = vann, source = "trade", epoch = 99, quantity = 1,
})
assertFalse(select(1, S.ApplyRemoteEvent(frozenP, forgedEpoch, vann)), "an unknown assignment epoch does not authorize a trade")
assertFalse(S.TradeGrantMatches(frozenP, frozenDonation, vann, frozenNow + S.TRADE_GRANT_TTL), "a trade grant expires")
local tradeEvents = W.TradeEvents(frozenTrade, { [aqirite] = 3 }, true)
local sawFrozenEpoch = false
for i = 1, #tradeEvents do
    if tradeEvents[i].type == C.EVENT.DONATION and tradeEvents[i].epoch == frozenEpoch and tradeEvents[i].tradeToken == frozenToken then
        sawFrozenEpoch = true
    end
end
assertTrue(sawFrozenEpoch, "trade donations carry the epoch captured when the trade opened")
local frozenExport = C.ExportSnapshot(frozenP, { omitEvents = true })
local frozenFollower = profile("frozen-follower", admin)
C.ReplaceConfig(frozenFollower, frozenExport)
assertTrue(C.CrafterAssignedAtEpoch(frozenFollower, vann, aqirite, frozenEpoch), "assignment history survives a config broadcast")
assertFalse(select(1, S.ApplyRemoteEvent(frozenFollower, frozenReceipt, vann)), "assignment history alone does not authorize a removed Crafter")
assertTrue(S.AcceptCoordinatorTradeGrant(frozenFollower, frozenGrant, C.Now()), "a follower stores the coordinator's trade grant")
assertTrue(select(1, S.ApplyRemoteEvent(frozenFollower, frozenReceipt, vann)), "a follower can accept a frozen trade that the coordinator granted")
local function checkTradeFreezeSync()
local savedFreezeState = Sync.state
local savedFreezeFind = Sync.FindLocalProfileById
local savedFreezeGroup = Sync.IsRequesterInGroup
local savedFreezeSame = Sync._SamePlayer
local savedFreezeEnforce = Sync._EnforceGroupedSessionActive
local savedFreezeComm = SF.LootHelperComm
Sync.MSG.CONSUMABLES_TRADE_FREEZE = "CONSUMABLES_TRADE_FREEZE"
Sync._SamePlayer = function(_, a, b) return a == b end
Sync.IsRequesterInGroup = function() return true end
Sync._EnforceGroupedSessionActive = function() return "RAID" end
local freezeSent = nil
SF.LootHelperComm = {
    Send = function(_, _, msgType, payload)
        freezeSent = { msgType = msgType, payload = payload }
    end,
}
local freezeProfile = profile("freeze-sync", admin)
assertTrue(select(1, C.AddCrafter(freezeProfile, admin, vann, { asAdmin = true })))
assertTrue(select(1, C.AddAssignment(freezeProfile, admin, aqirite, vann, { asAdmin = true })))
local freezeEpoch = freezeProfile._consumables.assignments[tostring(aqirite)].epoch
local freezeToken = "trade-" .. vann .. "-9-9"
local opened = C.FreezeTrade(freezeProfile, donor, vann, { { itemId = aqirite } }, freezeToken)
Sync.state = {
    active = true,
    isCoordinator = true,
    coordinator = admin,
    sessionId = "freeze-session",
    profileId = freezeProfile._profileId,
}
Sync.FindLocalProfileById = function(_, id)
    if id == freezeProfile._profileId then return freezeProfile end
    return nil
end
Sync:HandleConsumablesTradeFreeze(vann, {
    sessionId = "freeze-session",
    profileId = freezeProfile._profileId,
    token = freezeToken,
    donor = donor,
    receiver = vann,
    generation = freezeProfile._consumables.generation,
    items = { { itemId = aqirite, epoch = freezeEpoch } },
})
assertEq(freezeSent and freezeSent.msgType, "CONSUMABLES_TRADE_FREEZE", "the coordinator rebroadcasts one accepted trade freeze")
assertTrue(select(1, C.RemoveAssignment(freezeProfile, admin, aqirite, vann, { asAdmin = true })))
Sync:HandleConsumablesTradeFreeze(vann, {
    sessionId = "freeze-session",
    profileId = freezeProfile._profileId,
    token = "trade-" .. vann .. "-8-8",
    donor = sully,
    receiver = vann,
    generation = freezeProfile._consumables.generation,
    items = { { itemId = aqirite, epoch = freezeEpoch } },
})
assertFalse(S.TradeGrantMatches(freezeProfile, {
    id = "ce:" .. freezeProfile._profileId .. ":trade-" .. vann .. "-8-8:1",
    type = C.EVENT.DONATION,
    source = "trade",
    actor = sully,
    crafter = vann,
    itemId = aqirite,
    quantity = 1,
    generation = freezeProfile._consumables.generation,
    epoch = freezeEpoch,
    tradeToken = "trade-" .. vann .. "-8-8",
}, vann, C.Now()), "a freeze after removal does not create a grant")
assertTrue(S.TradeGrantMatches(freezeProfile, {
    id = "ce:" .. freezeProfile._profileId .. ":" .. freezeToken .. ":1",
    type = C.EVENT.DONATION,
    source = "trade",
    actor = donor,
    crafter = vann,
    itemId = aqirite,
    quantity = 1,
    generation = freezeProfile._consumables.generation,
    epoch = freezeEpoch,
    tradeToken = freezeToken,
}, vann, C.Now()), "the grant registered at trade open still matches")
assertTrue(Sync:PublishTradeFreeze(freezeProfile, opened) == false, "the coordinator does not publish a freeze after the Crafter is removed")
Sync.state = savedFreezeState
Sync.FindLocalProfileById = savedFreezeFind
Sync.IsRequesterInGroup = savedFreezeGroup
Sync._SamePlayer = savedFreezeSame
Sync._EnforceGroupedSessionActive = savedFreezeEnforce
SF.LootHelperComm = savedFreezeComm
end
checkTradeFreezeSync()

local fractional = {
    id = "ce:qty:" .. sully .. ":fraction",
    type = C.EVENT.DONATION,
    actor = sully,
    itemId = aqirite,
    quantity = 0.5,
    generation = peer._consumables.generation,
    source = "guildbank",
    timestamp = C.Now(),
}
assertFalse(select(1, S.ApplyRemoteEvent(peer, fractional, sully)), "a fractional remote quantity is rejected")
fractional.id = "ce:qty:" .. sully .. ":nan"
fractional.quantity = 0 / 0
assertFalse(select(1, S.ApplyRemoteEvent(peer, fractional, sully)), "a non-finite remote quantity is rejected")
fractional.id = "ce:qty:" .. sully .. ":huge"
fractional.quantity = S.MAX_EVENT_QUANTITY + 1
assertFalse(select(1, S.ApplyRemoteEvent(peer, fractional, sully)), "a remote quantity above the limit is rejected")
fractional.id = "ce:qty:" .. sully .. ":ok"
fractional.quantity = 2
assertTrue(select(1, S.ApplyRemoteEvent(peer, fractional, sully)), "an integer remote quantity within the limit is accepted")

local snapshotReasons = {}
local savedSyncState = Sync.state
local savedFind = Sync.FindLocalProfileById
local savedRequest = Sync.RequestProfileSnapshot
local savedGroup = Sync.IsRequesterInGroup
Sync.RequestProfileSnapshot = function(_, reason)
    snapshotReasons[#snapshotReasons + 1] = reason
    return true
end
Sync.FindLocalProfileById = function() return nil end
Sync.IsRequesterInGroup = function() return true end
Sync.state = {
    active = true,
    profileId = "missing-profile",
    sessionId = "missing-session",
    coordinator = "Coord-Realm",
    coordEpoch = 2,
}
Sync:_ConsiderConsumablesCatchUp({
    profileId = "missing-profile",
    sessionId = "missing-session",
    coordinator = "Coord-Realm",
})
assertEq(#snapshotReasons, 0, "a missing profile does not request a snapshot from consumables catch-up")

local catchP = profile("catch-epoch", admin)
Sync.FindLocalProfileById = function(_, id)
    if id == catchP._profileId then return catchP end
    return nil
end
Sync.state = {
    active = true,
    isCoordinator = false,
    profileId = catchP._profileId,
    sessionId = "catch-session",
    coordinator = "Old-Realm",
    coordEpoch = 1,
}
Sync._catchNowSaved = Sync._Now
catchNow = 2000
Sync._Now = function() return catchNow end
Sync:_ConsiderConsumablesCatchUp({
    profileId = catchP._profileId,
    sessionId = "catch-session",
    coordinator = "Old-Realm",
    consumablesGeneration = 1,
    consumablesConfigSeq = 3,
    consumablesEventCount = 0,
})
assertEq(#snapshotReasons, 0, "a new config difference waits before requesting a snapshot")
catchNow = 2015
Sync:_ConsiderConsumablesCatchUp({
    profileId = catchP._profileId,
    sessionId = "catch-session",
    coordinator = "Old-Realm",
    consumablesGeneration = 1,
    consumablesConfigSeq = 3,
    consumablesEventCount = 0,
})
local firstCatch = #snapshotReasons
assertTrue(firstCatch >= 1, "a config difference requests one snapshot")
Sync:_ConsiderConsumablesCatchUp({
    profileId = catchP._profileId,
    sessionId = "catch-session",
    coordinator = "Old-Realm",
    consumablesGeneration = 1,
    consumablesConfigSeq = 3,
    consumablesEventCount = 0,
})
assertEq(#snapshotReasons, firstCatch, "the same coordinator does not request config catch-up again")
Sync.state.coordEpoch = 2
Sync.state.coordinator = admin
Sync:_ConsiderConsumablesCatchUp({
    profileId = catchP._profileId,
    sessionId = "catch-session",
    coordinator = admin,
    consumablesGeneration = 1,
    consumablesConfigSeq = 1,
    consumablesEventCount = 0,
})
assertEq(#snapshotReasons, firstCatch, "a new coordinator epoch waits before requesting again")
catchNow = 2030
Sync:_ConsiderConsumablesCatchUp({
    profileId = catchP._profileId,
    sessionId = "catch-session",
    coordinator = admin,
    consumablesGeneration = 1,
    consumablesConfigSeq = 1,
    consumablesEventCount = 0,
})
assertTrue(#snapshotReasons > firstCatch, "a new coordinator epoch can request config catch-up again")
Sync._Now = Sync._catchNowSaved
Sync._catchNowSaved = nil
S.NoteCoordinatorWatermark(catchP, 1, 8, 1)
Sync:HandleConsumablesConfig(admin, {
    sessionId = "catch-session",
    profileId = catchP._profileId,
    generation = 1,
    configSeq = 2,
    crafters = { vann },
    assignments = {},
})
assertEq(catchP._consumables.configSeq, 2, "a later coordinator epoch applies a lower config sequence")
assertEq(catchP._consumables.crafters[1], vann, "the later coordinator's crafters are stored")
Sync.RequestProfileSnapshot = savedRequest
Sync.FindLocalProfileById = savedFind
Sync.IsRequesterInGroup = savedGroup
Sync.state = savedSyncState

local function checkSettingsRefresh()
local refreshQueued = {}
local refreshCount = 0
C_Timer = {
    After = function(_, fn)
        refreshQueued[#refreshQueued + 1] = fn
    end,
}
local capturedPage = nil
SF.SettingsUI = {
    RegisterPage = function(_, page)
        capturedPage = page
    end,
    DefinitionRenderer = {
        Refresh = function()
            refreshCount = refreshCount + 1
        end,
    },
}
load("SpectrumFederation/modules/UI/Settings/Pages/Consumables.lua")
capturedPage.panel = {
    IsShown = function() return true end,
}
local refreshProfile = profile("settings-refresh", admin)
C.AppendEvent(refreshProfile, {
    type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1,
})
C.AppendEvent(refreshProfile, {
    type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1,
})
assertEq(#refreshQueued, 1, "an open consumables page queues one refresh per frame")
assertEq(refreshCount, 0, "the queued refresh waits for the timer")
refreshQueued[1]()
assertEq(refreshCount, 1, "the timer runs one consumables page refresh")
capturedPage.panel = {
    IsShown = function() return false end,
}
local queuedBefore = #refreshQueued
C.AppendEvent(refreshProfile, {
    type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1,
})
assertEq(#refreshQueued, queuedBefore, "a hidden consumables page does not queue a refresh")
end
checkSettingsRefresh()

local function checkCoordinatorFollowups()
    local genP = profile("epoch-gen", admin)
    genP._consumables.generation = 2
    assertTrue(select(1, C.AppendEvent(genP, {
        id = "ce:epoch-gen:old", type = C.EVENT.DONATION, actor = admin, itemId = aqirite,
        quantity = 1, generation = 2, timestamp = 1,
    }, { silent = true })), "the higher generation has a live event")
    S.NoteCoordinatorWatermark(genP, 2, 4, 1)
    assertEq(select(2, S.ApplyRemoteConfig(genP, {
        generation = 1, configSeq = 1, crafters = { sully }, assignments = {},
    }, admin, { coordinatorAuthoritative = true, coordEpoch = 2 })), "applied", "a newer coordinator epoch can install a lower generation")
    assertEq(genP._consumables.generation, 1, "the new coordinator generation replaces the higher one")
    assertEq(genP._consumables.crafters[1], sully, "the new coordinator crafters replace the higher generation")
    assertFalse(hasEvent(genP._consumableEvents, "ce:epoch-gen:old"), "the previous generation leaves the live ledger")
    assertTrue(hasEvent(genP._consumableEventArchive, "ce:epoch-gen:old"), "the previous generation stays in the archive")
    local savedState = SF.LootHelperSync and SF.LootHelperSync.state
    SF.LootHelperSync.state = { active = true, coordEpoch = 2, sessionId = "helper-session", coordinator = admin }
    local helperP = profile("helper-snap", admin)
    C.ReplaceConfig(helperP, { generation = 1, configSeq = 2, crafters = { vann }, assignments = {} })
    S.NoteCoordinatorWatermark(helperP, 1, 2, 2)
    helperP._consumablesAdoptNextSnapshot = "helper-session"
    assertTrue(C.MergeSnapshot(helperP, {
        generation = 1, configSeq = 9, crafters = { donor }, assignments = {},
        events = {
            {
                id = "ce:helper:" .. admin .. ":1",
                type = C.EVENT.DONATION,
                actor = admin,
                writer = admin,
                itemId = aqirite,
                quantity = 1,
                generation = 1,
                timestamp = 1,
                order = 1,
            },
        },
    }, { consumablesFromCoordinator = false }), "a helper snapshot still imports")
    assertEq(helperP._consumables.configSeq, 2, "a helper snapshot does not replace coordinator config")
    assertEq(helperP._consumables.crafters[1], vann, "a helper snapshot keeps the coordinator crafters")
    assertTrue(hasEvent(helperP._consumableEvents, "ce:helper:" .. admin .. ":1"), "a helper snapshot still merges a stamped event")
    assertEq(helperP._consumablesAdoptNextSnapshot, "helper-session", "a helper snapshot leaves coordinator adoption pending")
    assertTrue(C.MergeSnapshot(helperP, {
        generation = 1, configSeq = 3, crafters = { sully }, assignments = {},
    }, { consumablesFromCoordinator = true }), "the coordinator snapshot imports")
    assertEq(helperP._consumables.crafters[1], sully, "the coordinator snapshot replaces config")
    assertEq(helperP._consumables.configSeq, 3, "the coordinator snapshot installs its sequence")
    local both = {
        id = "ce:both:" .. donor .. ":" .. vann .. ":1",
        type = C.EVENT.DONATION,
        source = "trade",
        actor = donor,
        crafter = vann,
        writer = vann,
        itemId = aqirite,
        quantity = 1,
        generation = peer._consumables.generation,
        timestamp = C.Now(),
    }
    assertTrue(select(1, S.ApplyRemoteEvent(peer, both, admin, { coordinatorRelay = true })), "a relay uses the stamped writer when the id names two characters")
    both.writer = nil
    both.id = "ce:both:" .. donor .. ":" .. vann .. ":2"
    assertFalse(select(1, S.ApplyRemoteEvent(peer, both, admin, { coordinatorRelay = true })), "a relay without a stamped writer is not guessed from name order")
    local busyP = profile("busy-sync", admin)
    local savedSync = Sync.state
    local savedComm = SF.LootHelperComm
    local savedSafe = Sync.IsSafeModeEnabled
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = admin,
        peers = { [admin] = { consumablesCapable = true } },
        sessionId = "busy-session",
        profileId = busyP._profileId,
    }
    Sync.IsSafeModeEnabled = function() return false end
    Sync.MSG.CONSUMABLES_EVENT = "CONSUMABLES_EVENT"
    SF.LootHelperComm = { Send = function() return false end }
    local busyOk, busyErr = Sync:CommitConsumablesOp(busyP, { name = "set_bank_tab", bankTab = 2 }, admin, { asAdmin = true })
    assertFalse(busyOk, "a full bulk queue does not report a pending config edit")
    assertTrue(type(busyErr) == "string" and busyErr:find("busy") ~= nil, "a dropped config edit tells the player to retry")
    assertEq(busyP._consumables.bankTab, nil, "a dropped config edit does not change the profile")
    assertTrue(select(1, C.AppendEvent(busyP, {
        id = "ce:busy:1", type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1,
    }, { silent = true })))
    busyP._consumablesUnsent = { "ce:busy:1" }
    Sync:_FlushUnsentConsumablesEvents(busyP)
    assertEq(busyP._consumablesUnsent[1], "ce:busy:1", "a dropped event broadcast stays queued")
    local savedSelf = Sync._SelfId
    local savedEnforce = Sync._EnforceGroupedSessionActive
    Sync.state.isCoordinator = true
    Sync._SelfId = function() return vann end
    Sync._EnforceGroupedSessionActive = function() return "RAID" end
    local stamped = nil
    SF.LootHelperComm = {
        Send = function(_, _, _, payload)
            stamped = payload
            return true
        end,
    }
    local authored = {
        id = "ce:busy:" .. vann .. ":1",
        type = C.EVENT.DONATION,
        actor = vann,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
    }
    assertTrue(Sync:BroadcastConsumablesEvent(busyP, authored), "the coordinator can broadcast an event it authored")
    assertEq(stamped and stamped.event and stamped.event.writer, vann, "a coordinator broadcast stamps the author as the relay writer")
    Sync._SelfId = savedSelf
    Sync._EnforceGroupedSessionActive = savedEnforce
    SF.LootHelperSync.state = savedState
    Sync.state = savedSync
    SF.LootHelperComm = savedComm
    Sync.IsSafeModeEnabled = savedSafe
end
checkCoordinatorFollowups()

local function checkReviewRound()
    local roundP = profile("review-round", admin)
    roundP._consumables.generation = 2
    local archiveCap = C.MAX_ARCHIVED_EVENTS
    C.MAX_ARCHIVED_EVENTS = 2
    for i = 1, 3 do
        assertTrue(select(1, C.AppendEvent(roundP, {
            id = "ce:archive-trim:" .. i,
            type = C.EVENT.DONATION,
            actor = admin,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            timestamp = i,
        }, { silent = true })), "an older event is archived")
    end
    assertEq(C.EventIndex(roundP)["ce:archive-trim:1"], nil, "trimming the archive drops the evicted id")
    assertTrue(C.EventIndex(roundP)["ce:archive-trim:3"] ~= nil, "a retained archive id stays in the index")
    C.MAX_ARCHIVED_EVENTS = archiveCap
    assertFalse(select(1, C.AppendEvent(roundP, {
        id = "ce:future:1",
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 3,
        timestamp = 4,
    }, { silent = true })), "a future generation is not stored in the live ledger")
    assertEq(C.EventIndex(roundP)["ce:future:1"], nil, "a rejected future event is not indexed")

    local restampId = "ce:restamp:" .. donor .. ":1"
    assertTrue(select(1, C.AppendEvent(roundP, {
        id = restampId,
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = aqirite,
        quantity = 1,
        generation = 2,
        timestamp = 5,
        order = 4,
        source = "guildbank",
    }, { silent = true })))
    assertTrue(select(1, S.ApplyRemoteEvent(roundP, {
        id = restampId,
        type = C.EVENT.DONATION,
        actor = donor,
        writer = donor,
        itemId = aqirite,
        quantity = 1,
        generation = 2,
        timestamp = 5,
        order = 9,
        source = "guildbank",
    }, admin, { coordinatorRelay = true })), "a coordinator relay can update an existing event")
    assertEq(C.EventIndex(roundP)[restampId].order, 9, "a coordinator relay replaces a stored order")
    assertTrue(select(1, S.ApplyRemoteEvent(roundP, {
        id = restampId,
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = aqirite,
        quantity = 1,
        generation = 2,
        timestamp = 5,
        order = 1,
        source = "guildbank",
    }, donor)), "a direct replay is still a duplicate")
    assertEq(C.EventIndex(roundP)[restampId].order, 9, "a direct replay does not replace a stored order")

    local writer = "Writer-Realm"
    local resendP = profile("resend-own", admin)
    C.AppendEvent(resendP, {
        id = "ce:resend:" .. writer .. ":1",
        type = C.EVENT.DONATION,
        actor = writer,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        timestamp = 1,
    }, { silent = true })
    C.AppendEvent(resendP, {
        id = "ce:resend:Other-Realm:1",
        type = C.EVENT.DONATION,
        actor = "Other-Realm",
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        timestamp = 2,
    }, { silent = true })
    C.AppendEvent(resendP, {
        id = "ce:resend:" .. writer .. ":2",
        type = C.EVENT.DONATION,
        actor = writer,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        timestamp = 3,
        order = 2,
    }, { silent = true })
    local savedSelf = Sync._SelfId
    local savedState = Sync.state
    Sync._SelfId = function() return writer end
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = "NewCoord-Realm",
        sessionId = "resend-session",
        profileId = resendP._profileId,
    }
    resendP._consumablesResendCursor = 1
    Sync:_QueueUnsequencedConsumablesEvents(resendP)
    local unsequenced = resendP._consumablesUnsent or {}
    local sawOwn, sawOther = false, false
    for i = 1, #unsequenced do
        if unsequenced[i] == "ce:resend:" .. writer .. ":1" then sawOwn = true end
        if unsequenced[i] == "ce:resend:Other-Realm:1" then sawOther = true end
    end
    assertTrue(sawOwn, "an unsequenced resend keeps this client's event")
    assertFalse(sawOther, "an unsequenced resend skips another client's event")
    resendP._consumablesUnsent = {}
    Sync:_QueueAuthoredOrderedConsumablesEvents(resendP, #resendP._consumableEvents)
    assertEq(#(resendP._consumablesUnsent or {}), 0, "matching counts do not upload ordered events")
    Sync:_QueueAuthoredOrderedConsumablesEvents(resendP, #resendP._consumableEvents, true)
    local sawOrdered = false
    for i = 1, #(resendP._consumablesUnsent or {}) do
        if resendP._consumablesUnsent[i] == "ce:resend:" .. writer .. ":2" then sawOrdered = true end
    end
    assertTrue(sawOrdered, "a fingerprint mismatch uploads this client's ordered event when counts match")

    local freezeP = profile("freeze-retry", admin)
    assertTrue(select(1, C.AddCrafter(freezeP, admin, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(freezeP, admin, aqirite, vann, { asAdmin = true })))
    local freezeToken = "trade-" .. vann .. "-7-7"
    local opened = C.FreezeTrade(freezeP, donor, vann, { { itemId = aqirite } }, freezeToken)
    local savedComm = SF.LootHelperComm
    local savedSafe = Sync.IsSafeModeEnabled
    local sends = 0
    local allowSend = false
    Sync.MSG.CONSUMABLES_TRADE_FREEZE = "CONSUMABLES_TRADE_FREEZE"
    Sync.IsSafeModeEnabled = function() return false end
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = admin,
        peers = { [admin] = { consumablesCapable = true } },
        sessionId = "freeze-retry",
        profileId = freezeP._profileId,
    }
    SF.LootHelperComm = {
        Send = function()
            sends = sends + 1
            if not allowSend then return false end
            return true
        end,
    }
    assertTrue(Sync:PublishTradeFreeze(freezeP, opened) == false, "a dropped trade freeze is not reported as delivered")
    assertEq(sends, 1, "the dropped trade freeze was offered to the bulk queue once")
    Sync:_FlushUnsentConsumablesEvents(freezeP)
    assertEq(sends, 2, "the next flush retries the dropped trade freeze")
    allowSend = true
    Sync:_FlushUnsentConsumablesEvents(freezeP)
    assertEq(sends, 3, "the retry sends the trade freeze once the queue accepts it")
    Sync:_FlushUnsentConsumablesEvents(freezeP)
    assertEq(sends, 3, "a delivered trade freeze is not sent again")
    Sync._SelfId = savedSelf
    Sync.state = savedState
    SF.LootHelperComm = savedComm
    Sync.IsSafeModeEnabled = savedSafe

    local savedSpell = C_Spell
    local seenSpell = nil
    C_Spell = {
        GetSpellInfo = function(spellId)
            seenSpell = spellId
            return { name = "Banque mobile" }
        end,
    }
    assertEq(RT:MobileSpell(), "Banque mobile", "mobile banking uses the localized spell name")
    assertEq(seenSpell, 83958, "mobile banking resolves spell id 83958")
    C_Spell = savedSpell
end
checkReviewRound()

local function checkConvergenceRound()
    local plainP = profile("fp-plain", admin)
    local stampedP = profile("fp-stamped", admin)
    local fpId = "ce:fp:" .. admin .. ":1"
    assertTrue(select(1, C.AppendEvent(plainP, {
        id = fpId,
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })), "an unstamped event is stored")
    local plainFp = C.Descriptor(plainP).eventFingerprint
    assertTrue(select(1, C.AppendEvent(stampedP, {
        id = fpId,
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
        order = 1,
    }, { silent = true })), "the same event can be stored with an order")
    local stampedFp = C.Descriptor(stampedP).eventFingerprint
    assertTrue(plainFp ~= stampedFp, "a stamped ledger fingerprints differently from the same ids without orders")
    local plainStored = plainP._consumableEvents[1]
    assertEq(C.StampOrder(plainP, plainStored), 1, "stamping the unstamped copy assigns the first order")
    assertEq(C.Descriptor(plainP).eventFingerprint, stampedFp, "stamping retargets the fingerprint to the ordered token")
    C.InvalidateEventIndex(plainP)
    C.Ensure(plainP)
    assertEq(C.Descriptor(plainP).eventFingerprint, stampedFp, "rebuilding the index keeps the ordered fingerprint")

    local capP = profile("id-cap", admin)
    local hugeId = string.rep("a", C.MAX_EVENT_ID + 1)
    assertFalse(select(1, C.AppendEvent(capP, {
        id = hugeId,
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        timestamp = 1,
    }, { silent = true })), "an overlong event id is rejected")
    assertEq(#capP._consumableEvents, 0, "a rejected id is not stored")
    assertEq(C.EventIndex(capP)[hugeId], nil, "a rejected id is not indexed")
    assertTrue(select(1, C.AppendEvent(capP, {
        id = "ce:source:huge",
        type = C.EVENT.DONATION,
        actor = string.rep("N", C.MAX_EVENT_NAME + 8),
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = string.rep("s", 5000),
        action = "hack",
        reason = string.rep("r", C.MAX_EVENT_REASON + 40),
        timestamp = 2,
    }, { silent = true })), "optional overlong fields do not reject the event")
    local capped = C.EventIndex(capP)["ce:source:huge"]
    assertEq(capped.source, nil, "an unknown source is not stored")
    assertEq(capped.action, nil, "an unknown action is not stored")
    assertEq(capped.actor, nil, "an overlong name is not stored")
    assertEq(#capped.reason, C.MAX_EVENT_REASON, "a reason is capped before it is stored")
    assertTrue(select(1, C.AppendEvent(capP, {
        id = "ce:source:trade",
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "trade",
        timestamp = 3,
    }, { silent = true })))
    assertEq(C.EventIndex(capP)["ce:source:trade"].source, "trade", "a trade source is stored")

    local savedRefresh = RT.RefreshReminder
    local hidden = 0
    RT.RefreshReminder = function() end
    RT.review = { Hide = function() hidden = hidden + 1 end }
    RT.openTrade = nil
    RT.qtyOverrides = { [aqirite] = 2 }
    RT._seenProfileId = nil
    RT:OnProfileChanged({ _profileId = "profile-a" })
    assertEq(hidden, 1, "the first profile selection closes an open review")
    assertEq(RT.qtyOverrides[aqirite], nil, "the first profile selection clears edited quantities")
    RT.qtyOverrides = { [aqirite] = 4 }
    RT:OnProfileChanged({ _profileId = "profile-a" })
    assertEq(hidden, 1, "selecting the same profile leaves the review open")
    assertEq(RT.qtyOverrides[aqirite], 4, "selecting the same profile keeps edited quantities")
    RT:OnProfileChanged({ _profileId = "profile-b" })
    assertEq(hidden, 2, "selecting a different profile closes the review")
    assertEq(RT.qtyOverrides[aqirite], nil, "selecting a different profile clears edited quantities")
    RT.RefreshReminder = savedRefresh
    RT.review = nil
    RT.openTrade = nil
    RT.qtyOverrides = {}
    RT._seenProfileId = nil

    local merged = R.GuildBankAccess({
        configured = true, sameGuild = true, bankOpen = true, canDeposit = true, freeSlots = 0, mergeRoom = true,
    })
    assertTrue(merged.enabled, "a full tab with stack room can still accept a deposit")
    assertEq(merged.reason, nil, "stack room is not reported as a full tab")
    local stillFull = R.GuildBankAccess({
        configured = true, sameGuild = true, bankOpen = true, canDeposit = true, freeSlots = 0,
    })
    assertEq(stillFull.reason, "tab_full", "a full tab without stack room stays closed")

    local savedNum = GetGuildBankNumSlots
    local savedLink = GetGuildBankItemLink
    local savedInfo = GetGuildBankItemInfo
    local savedItemApi = C_Item
    local savedGetItemInfo = GetItemInfo
    GetGuildBankNumSlots = function() return 3 end
    GetGuildBankItemLink = function(_, slot)
        if slot == 1 then return "item:" .. tostring(aqirite) end
        return nil
    end
    GetGuildBankItemInfo = function(_, slot)
        if slot == 1 then return nil, 4 end
        return nil, 0
    end
    C_Item = { GetItemMaxStackSizeByID = function() return 20 end }
    local targets = RT:DepositTargets(1, aqirite, 6)
    assertEq(targets[1] and targets[1].slot, 1, "a deposit prefers the partial stack")
    assertEq(targets[1] and targets[1].room, 16, "partial stack room is the unused portion of the max stack")
    assertEq(targets[2] and targets[2].slot, 2, "empty slots follow the partial stack")
    C_Item = nil
    GetItemInfo = nil
    local emptiesOnly = RT:DepositTargets(1, aqirite, 6)
    assertEq(emptiesOnly[1] and emptiesOnly[1].slot, 2, "an unknown stack size uses empty slots only")

    local bankP = profile("merge-bank", admin)
    assertTrue(select(1, C.SetGuild(bankP, admin, { guid = "club-merge", name = "Spectrum", realm = "Realm" }, 1, { asAdmin = true })))
    assertTrue(select(1, C.AddCrafter(bankP, admin, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(bankP, admin, aqirite, vann, { asAdmin = true })))
    local savedBankOpen = RT.BankIsOpen
    local savedBags = RT.bagCounts
    local savedTabInfo = GetGuildBankTabInfo
    local savedMergeGuild = RT.CurrentGuild
    RT.BankIsOpen = function() return true end
    RT.CurrentGuild = function() return { guid = "club-merge" } end
    RT.bagCounts = { [aqirite] = 3 }
    GetGuildBankNumSlots = function() return 1 end
    GetGuildBankTabInfo = function() return nil, nil, nil, true end
    C_Item = { GetItemMaxStackSizeByID = function() return 20 end }
    local access = RT:BankAccess(bankP)
    assertTrue(access.enabled, "bank access stays enabled when a carried item can merge")
    assertEq(access.reason, nil, "a mergeable tab is not marked full")
    RT.bagCounts = {}
    local blocked = RT:BankAccess(bankP)
    assertEq(blocked.reason, "tab_full", "a full tab with nothing to merge stays closed")
    RT.BankIsOpen = savedBankOpen
    RT.CurrentGuild = savedMergeGuild
    RT.bagCounts = savedBags
    GetGuildBankNumSlots = savedNum
    GetGuildBankItemLink = savedLink
    GetGuildBankItemInfo = savedInfo
    GetGuildBankTabInfo = savedTabInfo
    C_Item = savedItemApi
    GetItemInfo = savedGetItemInfo

    local withdrawP = profile("withdraw-queue", admin)
    assertTrue(select(1, C.SetGuild(withdrawP, admin, { guid = "club-w", name = "Spectrum", realm = "Realm" }, 2, { asAdmin = true })))
    assertTrue(select(1, C.AddCrafter(withdrawP, admin, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(withdrawP, admin, aqirite, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(withdrawP, admin, aqiriteRank2, vann, { asAdmin = true })))
    local savedProfileFn = RT.Profile
    local savedGuildFn = RT.CurrentGuild
    local savedScan = RT.ScanBags
    local savedTabs = RT.TabItemCounts
    local savedCapture = RT.CaptureBaseline
    local savedSelfFn = RT.SelfId
    local savedCommit = RT.Commit
    local savedFind = Sync.FindLocalProfileById
    local slotItem = aqirite
    GetGuildBankItemLink = function()
        return "item:" .. tostring(slotItem)
    end
    GetGuildBankItemInfo = function()
        return nil, 5
    end
    RT.Profile = function() return withdrawP end
    RT.CurrentGuild = function() return { guid = "club-w" } end
    RT.ScanBags = function() end
    RT.CaptureBaseline = function() end
    RT.SelfId = function() return admin end
    RT.TabItemCounts = function()
        return { [aqirite] = 20, [aqiriteRank2] = 20 }
    end
    RT.bagCounts = { [aqirite] = 0, [aqiriteRank2] = 0 }
    RT.withdrawIntent = nil
    RT.withdrawIntents = nil
    local commits = 0
    RT.Commit = function()
        commits = commits + 1
        return true
    end
    Sync.FindLocalProfileById = function(_, id)
        if id == withdrawP._profileId then return withdrawP end
        return nil
    end
    RT:NoteGuildBankPickup(2, 1, false)
    RT:NoteGuildBankPickup(2, 1, false)
    assertEq(#RT.withdrawIntents, 1, "a second pickup of the same item stays one intent")
    assertEq(RT.withdrawIntents[1].intended, 10, "a repeated pickup adds to the intended quantity")
    slotItem = aqiriteRank2
    RT:NoteGuildBankPickup(2, 1, false)
    assertEq(#RT.withdrawIntents, 2, "a second requested item is queued")
    assertEq(RT.withdrawIntents[1].itemId, aqirite, "the first withdrawal stays at the head of the queue")
    RT.bagCounts = { [aqirite] = 5, [aqiriteRank2] = 5 }
    RT.TabItemCounts = function()
        return { [aqirite] = 15, [aqiriteRank2] = 15 }
    end
    GetGuildBankItemLink = function() return nil end
    GetGuildBankItemInfo = function() return nil, 0 end
    RT:FinishWithdraw(false)
    assertEq(commits, 2, "both queued withdrawals commit")
    assertEq(RT.withdrawIntent, nil, "a finished queue clears the active withdrawal")
    RT.withdrawIntents = {}
    for i = 1, 8 do
        RT.withdrawIntents[i] = { itemId = 1000 + i, tab = 2 }
    end
    RT.withdrawIntent = RT.withdrawIntents[1]
    slotItem = aqirite
    RT:NoteGuildBankPickup(2, 1, false)
    assertEq(#RT.withdrawIntents, 8, "the withdrawal queue does not grow past eight intents")
    assertEq(RT.withdrawIntents[1].itemId, 1001, "a full queue keeps the first intent")
    RT.Profile = savedProfileFn
    RT.CurrentGuild = savedGuildFn
    RT.ScanBags = savedScan
    RT.TabItemCounts = savedTabs
    RT.CaptureBaseline = savedCapture
    RT.SelfId = savedSelfFn
    RT.Commit = savedCommit
    RT.bagCounts = savedBags
    RT.withdrawIntent = nil
    RT.withdrawIntents = nil
    Sync.FindLocalProfileById = savedFind
    GetGuildBankItemLink = savedLink
    GetGuildBankItemInfo = savedInfo

    local clearP = profile("clear-broadcast", admin)
    assertTrue(select(1, C.AppendEvent(clearP, {
        id = "ce:clear-broadcast:" .. admin .. ":1",
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })), "the clear fixture stores one donation")
    local savedState = Sync.state
    local savedComm = SF.LootHelperComm
    local savedSafe = Sync.IsSafeModeEnabled
    local savedEnforce = Sync._EnforceGroupedSessionActive
    local savedSelf = Sync._SelfId
    local messages = {}
    Sync.MSG = Sync.MSG or {}
    Sync.MSG.CONSUMABLES_EVENT = "CONSUMABLES_EVENT"
    Sync.MSG.CONSUMABLES_CONFIG = "CONSUMABLES_CONFIG"
    Sync.IsSafeModeEnabled = function() return false end
    Sync._EnforceGroupedSessionActive = function() return "RAID" end
    Sync._SelfId = function() return admin end
    Sync.state = {
        active = true,
        isCoordinator = true,
        coordinator = admin,
        sessionId = "clear-session",
        profileId = clearP._profileId,
    }
    SF.LootHelperComm = {
        Send = function(_, _, msg, payload)
            messages[#messages + 1] = { msg = msg, event = payload and payload.event }
            return true
        end,
    }
    assertTrue(select(1, Sync:CommitConsumablesOp(clearP, { name = "clear" }, admin, { asAdmin = true })), "the coordinator can clear raid supplies")
    local resetEvent = nil
    local eventMessages = 0
    for i = 1, #messages do
        if messages[i].msg == "CONSUMABLES_EVENT" then
            eventMessages = eventMessages + 1
            resetEvent = messages[i].event
        end
    end
    assertEq(eventMessages, 1, "clear broadcasts the archived reset and not the older donation")
    assertEq(resetEvent and resetEvent.type, C.EVENT.RESET, "the broadcast event is the configuration reset")
    assertTrue(resetEvent and tonumber(resetEvent.order) ~= nil and resetEvent.order > 0, "the reset carries a coordinator order")
    assertEq(#clearP._consumableEvents, 0, "the reset stays out of the live ledger")
    assertEq(C.Descriptor(clearP).eventFingerprint, 0, "stamping the archived reset does not change the live fingerprint")
    local followP = profile("clear-follow", admin)
    followP._consumables.generation = 2
    assertTrue(select(1, S.ApplyRemoteEvent(followP, resetEvent, admin, { coordinatorRelay = true })), "a follower accepts the broadcast reset")
    local sawClear = false
    local rows = C.HistoryRows(followP)
    for i = 1, #rows do
        if rows[i].text:find("cleared", 1, true) then sawClear = true end
    end
    assertTrue(sawClear, "the follower log shows who cleared")
    assertEq(#followP._consumableEvents, 0, "the follower keeps the reset in the archive")

    local tokenP = profile("token-wait", admin)
    assertTrue(select(1, C.AddCrafter(tokenP, admin, vann, { asAdmin = true })), "the trade fixture can add a crafter")
    assertTrue(select(1, C.AddAssignment(tokenP, admin, aqirite, vann, { asAdmin = true })), "the trade fixture can assign an item")
    local tradeToken = "trade-" .. vann .. "-9-9"
    local opened = C.FreezeTrade(tokenP, donor, vann, { { itemId = aqirite } }, tradeToken)
    local tokenEventId = "ce:token:" .. donor .. ":1"
    assertTrue(select(1, C.AppendEvent(tokenP, {
        id = tokenEventId,
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "trade",
        tradeToken = tradeToken,
        timestamp = 4,
    }, { silent = true })), "the trade event is stored locally")
    local allowSend = false
    local sentKinds = {}
    Sync.MSG.CONSUMABLES_TRADE_FREEZE = "CONSUMABLES_TRADE_FREEZE"
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = admin,
        peers = { [admin] = { consumablesCapable = true } },
        sessionId = "token-session",
        profileId = tokenP._profileId,
    }
    Sync._SelfId = function() return donor end
    SF.LootHelperComm = {
        Send = function(_, _, msg)
            sentKinds[#sentKinds + 1] = msg
            if not allowSend then return false end
            return true
        end,
    }
    assertTrue(Sync:PublishTradeFreeze(tokenP, opened) == false, "the trade freeze stays pending when the queue rejects it")
    local sentBefore = #sentKinds
    assertTrue(Sync:BroadcastConsumablesEvent(tokenP, C.EventIndex(tokenP)[tokenEventId]) == false, "a trade event waits while its freeze is pending")
    local sawEventEarly = false
    for i = 1, #sentKinds do
        if sentKinds[i] == "CONSUMABLES_EVENT" then sawEventEarly = true end
    end
    assertFalse(sawEventEarly, "the trade event is not sent before the freeze")
    assertTrue(#sentKinds > sentBefore, "the pending freeze is offered again before the trade event")
    allowSend = true
    Sync:_FlushUnsentConsumablesEvents(tokenP)
    local freezeAt, eventAt = nil, nil
    for i = 1, #sentKinds do
        if sentKinds[i] == "CONSUMABLES_TRADE_FREEZE" and allowSend then
            freezeAt = i
        end
        if sentKinds[i] == "CONSUMABLES_EVENT" then
            eventAt = i
        end
    end
    assertTrue(freezeAt ~= nil and eventAt ~= nil and freezeAt < eventAt, "the flush delivers the freeze before the trade event")
    Sync:_ClearPendingTradeFreezes()

    local writer = "Writer-Realm"
    local repairP = profile("order-repair", admin)
    local repairId = "ce:repair:" .. writer .. ":1"
    assertTrue(select(1, C.AppendEvent(repairP, {
        id = repairId,
        type = C.EVENT.DONATION,
        actor = writer,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 5,
        order = 4,
    }, { silent = true })), "the coordinator already stamped the writer's event")
    local repairSends = {}
    Sync.state = {
        active = true,
        isCoordinator = true,
        coordinator = admin,
        sessionId = "repair-session",
        profileId = repairP._profileId,
    }
    Sync._SamePlayer = function(_, a, b) return a == b end
    Sync.IsRequesterInGroup = function() return true end
    Sync.FindLocalProfileById = function() return repairP end
    SF.LootHelperComm = {
        Send = function(_, _, _, payload)
            repairSends[#repairSends + 1] = payload and payload.event
            return true
        end,
    }
    Sync:HandleConsumablesEvent(writer, {
        sessionId = "repair-session",
        profileId = repairP._profileId,
        event = {
            id = repairId,
            type = C.EVENT.DONATION,
            actor = writer,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            source = "guildbank",
            timestamp = 5,
        },
    })
    assertEq(#repairSends, 1, "the coordinator rebroadcasts one stored stamp to its author")
    assertEq(repairSends[1] and repairSends[1].order, 4, "the rebroadcast keeps the stored order")
    Sync:HandleConsumablesEvent("Stranger-Realm", {
        sessionId = "repair-session",
        profileId = repairP._profileId,
        event = {
            id = repairId,
            type = C.EVENT.DONATION,
            actor = writer,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            source = "guildbank",
            timestamp = 5,
        },
    })
    assertEq(#repairSends, 1, "a non-author duplicate does not rebroadcast the stamp")

    local cfgP = profile("cfg-catch", admin)
    cfgP._consumables.configSeq = 5
    local cfgCalls = 0
    local cfgOpts = nil
    local allowCfg = false
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = "Coord-Realm",
        coordEpoch = 3,
        sessionId = "cfg-session",
        profileId = cfgP._profileId,
    }
    Sync.FindLocalProfileById = function() return cfgP end
    Sync.RequestProfileSnapshot = function(_, _, opts)
        cfgCalls = cfgCalls + 1
        cfgOpts = opts
        return allowCfg
    end
    local cfgPayload = {
        coordinator = "Coord-Realm",
        profileId = cfgP._profileId,
        sessionId = "cfg-session",
        consumablesGeneration = 1,
        consumablesConfigSeq = 0,
        consumablesEventCount = 0,
        consumablesEventFingerprint = 0,
    }
    local savedNow = Sync._Now
    local nowCfg = 1000
    Sync._Now = function() return nowCfg end
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgCalls, 0, "a new config difference waits before asking for a snapshot")
    cfgP._consumables.configSeq = 4
    cfgPayload.consumablesConfigSeq = 6
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgCalls, 0, "a config-only ledger match also waits before requesting a snapshot")
    cfgP._consumables.configSeq = 5
    cfgPayload.consumablesConfigSeq = 0
    nowCfg = 1014
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgCalls, 0, "the config snapshot waits through the grace period")
    nowCfg = 1015
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgCalls, 1, "a config difference asks for a snapshot after the grace period")
    assertEq(cfgP._consumablesConfigCatchUpSession, nil, "a snapshot request that is not registered does not latch")
    assertEq(cfgP._consumablesConfigCatchUpAt, nil, "a snapshot request that is not registered does not record an attempt")
    assertEq(cfgOpts and cfgOpts.coordinatorOnly, true, "the config snapshot asks only the coordinator")
    allowCfg = true
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgCalls, 2, "the next heartbeat retries the config snapshot")
    assertTrue(type(cfgP._consumablesConfigCatchUpSession) == "string", "a registered config snapshot latches that coordinator epoch")
    assertEq(cfgP._consumablesConfigCatchUpAt, 1015, "a registered config snapshot records the attempt time")
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    nowCfg = 1134
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgCalls, 2, "a latched config snapshot is not requested again inside the cooldown")
    nowCfg = 1135
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgCalls, 3, "a latched config snapshot is requested again after 120 seconds")
    assertEq(cfgP._consumablesConfigCatchUpAt, 1135, "the retry records the new attempt time")
    cfgP._consumables.configSeq = 0
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgP._consumablesConfigCatchUpAt, nil, "a matching configuration clears the attempt time")
    assertEq(cfgP._consumablesConfigDiffSince, nil, "a matching configuration clears the grace timer")
    assertEq(cfgCalls, 3, "a matching configuration does not request another snapshot")
    Sync._Now = savedNow

    local loaded, loadErr = pcall(function()
        load("SpectrumFederation/modules/LootHelperSync/11_Heartbeat.lua")
    end)
    assertTrue(loaded, "the heartbeat snapshot request loads: " .. tostring(loadErr))
    if loaded then
        local recordedTargets = nil
        Sync.state = {
            active = true,
            sessionId = "snap-session",
            profileId = "snap-profile",
            coordinator = "Coord-Realm",
            helpers = { "Helper-Realm" },
        }
        Sync.NewRequestId = function() return "req-cfg" end
        Sync.RegisterRequest = function(_, _, _, _, meta)
            recordedTargets = meta and meta.targets
            return true
        end
        Sync._CurrentAuthorizedRoutingTargets = function()
            return { "Helper-Realm", "Coord-Realm" }
        end
        Sync._NoteMissingRoute = function() end
        Sync.FindLocalProfileById = function() return cfgP end
        assertTrue(Sync:RequestProfileSnapshot("consumables-config", { coordinatorOnly = true }), "a coordinator-only snapshot request is registered")
        assertEq(recordedTargets and recordedTargets[1], "Coord-Realm", "the config snapshot target is the coordinator")
        assertEq(recordedTargets and #recordedTargets, 1, "a coordinator-only snapshot has no helper target")
        Sync.state._profileReqInFlight = nil
        recordedTargets = nil
        assertTrue(Sync:RequestProfileSnapshot("ordinary"), "an ordinary snapshot request still registers")
        assertEq(recordedTargets and recordedTargets[1], "Helper-Realm", "an ordinary snapshot still prefers a helper")
    end

    Sync.state = savedState
    SF.LootHelperComm = savedComm
    Sync.IsSafeModeEnabled = savedSafe
    Sync._EnforceGroupedSessionActive = savedEnforce
    Sync._SelfId = savedSelf
    Sync.FindLocalProfileById = savedFind
end
checkConvergenceRound()

local function checkFollowupRound()
    local hist = profile("history-page", admin)
    for i = 1, 3 do
        assertTrue(select(1, C.AppendEvent(hist, {
            id = "ce:hist:" .. admin .. ":" .. tostring(i),
            type = C.EVENT.DONATION,
            actor = admin,
            itemId = aqirite,
            quantity = i,
            generation = 1,
            source = "guildbank",
            timestamp = i,
        }, { silent = true })), "history fixture stores event " .. tostring(i))
    end
    local newest = C.HistoryRows(hist, nil, 1)
    assertEq(#newest, 1, "a limit without an offset still returns the newest row")
    assertTrue(newest[1].text:find("donated 3", 1, true) ~= nil, "the first history page starts with the newest event")
    local older, total = C.HistoryRows(hist, nil, 1, 1)
    assertEq(total, 3, "history reports how many retained rows exist")
    assertEq(#older, 1, "an offset returns the next history page")
    assertTrue(older[1].text:find("donated 2", 1, true) ~= nil, "the next page is the next newest event")

    local plain = profile("archive-fp-plain", admin)
    local extra = profile("archive-fp-extra", admin)
    local shared = {
        id = "ce:archfp:" .. admin .. ":1",
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }
    assertTrue(select(1, C.AppendEvent(plain, shared, { silent = true })), "the plain archive fixture stores the live event")
    assertTrue(select(1, C.AppendEvent(extra, shared, { silent = true })), "the extra archive fixture stores the same live event")
    extra._consumables.generation = 2
    plain._consumables.generation = 2
    assertTrue(select(1, C.AppendEvent(extra, {
        id = "ce:archfp:" .. admin .. ":old",
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 4,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })), "an older event is archived beside the same live ledger")
    local plainDesc = C.Descriptor(plain)
    local extraDesc = C.Descriptor(extra)
    assertEq(plainDesc.eventFingerprint, extraDesc.eventFingerprint, "the same live ledger keeps the same live fingerprint")
    assertTrue(plainDesc.archiveFingerprint ~= extraDesc.archiveFingerprint, "the archive fingerprint changes when the archive differs")
    local remoteArchive = {
        generation = extraDesc.generation,
        configSeq = extraDesc.configSeq,
        eventCount = extraDesc.eventCount,
        eventFingerprint = extraDesc.eventFingerprint,
        archiveCount = extraDesc.archiveCount,
        archiveFingerprint = extraDesc.archiveFingerprint,
    }
    assertTrue(S.NeedsCatchUp(plainDesc, remoteArchive), "a different archive needs catch-up when the peer advertises it")
    assertEq(S.CatchUpKind(plainDesc, remoteArchive), "fingerprint", "an archive-only mismatch uses the fingerprint cooldown")
    local remoteWithoutArchive = {
        generation = extraDesc.generation,
        configSeq = extraDesc.configSeq,
        eventCount = extraDesc.eventCount,
        eventFingerprint = extraDesc.eventFingerprint,
    }
    assertFalse(S.NeedsCatchUp(plainDesc, remoteWithoutArchive), "a peer that omits archive fields is not an archive mismatch")

    local seqP = profile("seq-cap", admin)
    local bigId = "ce:seq:" .. admin .. ":9007199254740992"
    assertTrue(select(1, C.AppendEvent(seqP, {
        id = bigId,
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })), "a long event id is still stored for dedupe")
    assertEq(seqP._consumables.eventSeq, 0, "a remote id past 2^31-1 does not move the local sequence")
    C.InvalidateEventIndex(seqP)
    C.Ensure(seqP)
    assertEq(seqP._consumables.eventSeq, 0, "rebuilding the index does not adopt that sequence")
    local nextId = C.NextEventId(seqP, admin)
    assertTrue(nextId ~= bigId and nextId:find(":1$") ~= nil, "the next local id stays unique")
    local adoptP = profile("seq-adopt", admin)
    assertTrue(select(1, C.AppendEvent(adoptP, {
        id = "ce:seq:" .. admin .. ":10",
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })), "a normal event id suffix is stored")
    assertEq(adoptP._consumables.eventSeq, 10, "a sequence at or below 2^31-1 is adopted")
    assertTrue(C.NextEventId(adoptP, admin):find(":11$") ~= nil, "the next local id follows the adopted sequence")

    local quotaP = profile("quota", admin)
    local quotaOk = true
    for i = 1, C.MAX_EVENTS_PER_ACTOR do
        local ok = C.AppendEvent(quotaP, {
            id = "ce:quota:" .. admin .. ":" .. tostring(i),
            type = C.EVENT.DONATION,
            actor = admin,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            source = "guildbank",
            timestamp = i,
        }, { silent = true })
        if not ok then quotaOk = false end
    end
    assertTrue(quotaOk, "a character can record the per-character budget")
    C.InvalidateEventIndex(quotaP)
    C.Ensure(quotaP)
    local blocked, quotaStatus = C.AppendEvent(quotaP, {
        id = "ce:quota:" .. admin .. ":over",
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })
    assertFalse(blocked, "the next event from that character is rejected")
    assertEq(quotaStatus, "quota", "the rejection names the per-character budget")
    assertTrue(select(1, C.AppendEvent(quotaP, {
        id = "ce:quota:" .. donor .. ":1",
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })), "another character can still record an event")

    RT._seenProfileId = "profile-a"
    RT.qtyOverrides = { [aqirite] = 2 }
    RT.openTrade = nil
    RT.review = {
        shown = true,
        Hide = function(self) self.shown = false end,
        IsShown = function(self) return self.shown end,
    }
    RT:OnProfileChanged(nil)
    assertFalse(RT.review.shown, "clearing the active profile closes an open review")
    assertEq(RT._seenProfileId, nil, "the review is no longer bound to the deleted profile")

    local visible = profile("visible-profile", admin)
    local sessionP = profile("session-profile", admin)
    local savedGet = SF.GetActiveProfile
    local savedDb = SF.lootHelperDB
    local savedInfo = SF.PrintInfo
    local savedState = Sync.state
    local savedFind = Sync.FindLocalProfileById
    local savedRequest = Sync.RequestProfileSnapshot
    local savedComm = SF.LootHelperComm
    local savedSafe = Sync.IsSafeModeEnabled
    local notices = 0
    SF.GetActiveProfile = function() return visible end
    SF.lootHelperDB = { profiles = { ["session-profile"] = sessionP } }
    SF.PrintInfo = function() notices = notices + 1 end
    Sync.state = { active = true, profileId = "session-profile", sessionId = "acct-session" }
    assertTrue(RT:Profile() == visible, "the visible profile helper still returns the active profile")
    assertTrue(RT:AccountingProfile() == sessionP, "new accounting uses the session profile")
    assertEq(notices, 1, "a different visible profile is reported once")
    assertTrue(RT:AccountingProfile() == sessionP, "later accounting stays on the session profile")
    assertEq(notices, 1, "the same session does not repeat that notice")

    local catchP = profile("event-catch", admin)
    local calls = {}
    Sync._consumablesCatchUpKey = nil
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = "Coord-Realm",
        sessionId = "event-catch",
        profileId = catchP._profileId,
        coordEpoch = 1,
    }
    Sync.FindLocalProfileById = function() return catchP end
    Sync.IsSafeModeEnabled = function() return false end
    local payload = {
        coordinator = "Coord-Realm",
        profileId = catchP._profileId,
        sessionId = "event-catch",
        consumablesGeneration = 1,
        consumablesConfigSeq = 0,
        consumablesEventCount = 2,
        consumablesEventFingerprint = 9,
    }
    Sync.RequestProfileSnapshot = function(_, reason, opts)
        calls[#calls + 1] = { reason = reason, coordinatorOnly = opts and opts.coordinatorOnly or false }
        return false
    end
    Sync:_ConsiderConsumablesCatchUp(payload)
    assertEq(#calls, 1, "a ledger mismatch asks for a snapshot")
    assertEq(Sync._consumablesCatchUpKey, nil, "a snapshot request that is not registered does not latch")
    Sync.RequestProfileSnapshot = function(_, reason, opts)
        calls[#calls + 1] = { reason = reason, coordinatorOnly = opts and opts.coordinatorOnly or false }
        return true
    end
    Sync:_ConsiderConsumablesCatchUp(payload)
    assertTrue(Sync._consumablesCatchUpKey ~= nil, "a registered ledger snapshot latches that descriptor")
    assertEq(calls[#calls].coordinatorOnly, false, "the first ledger snapshot can use a helper")
    Sync:_NoteConsumablesSnapshot(catchP, false)
    assertEq(Sync._consumablesCatchUpKey, nil, "a helper snapshot that still differs clears the latch")
    assertEq(catchP._consumablesCatchUpWantCoordinator, true, "the next ledger snapshot asks the coordinator")
    Sync:_ConsiderConsumablesCatchUp(payload)
    assertEq(calls[#calls].coordinatorOnly, true, "the follow-up snapshot target is the coordinator")
    local callsBefore = #calls
    Sync:_NoteConsumablesSnapshot(catchP, true)
    Sync:_ConsiderConsumablesCatchUp(payload)
    assertEq(#calls, callsBefore, "a coordinator snapshot that still differs is not requested again")

    local freezeP = profile("freeze-queue", admin)
    assertTrue(select(1, C.AddCrafter(freezeP, admin, vann, { asAdmin = true })), "the freeze queue can add a crafter")
    assertTrue(select(1, C.AddAssignment(freezeP, admin, aqirite, vann, { asAdmin = true })), "the freeze queue can assign an item")
    local tokenA = "trade-" .. vann .. "-11-11"
    local tokenB = "trade-" .. vann .. "-12-12"
    local openedA = C.FreezeTrade(freezeP, donor, vann, { { itemId = aqirite } }, tokenA)
    local openedB = C.FreezeTrade(freezeP, donor, vann, { { itemId = aqirite } }, tokenB)
    local sentTokens = {}
    local allowSend = false
    Sync.MSG = Sync.MSG or {}
    Sync.MSG.CONSUMABLES_TRADE_FREEZE = "CONSUMABLES_TRADE_FREEZE"
    Sync.MSG.CONSUMABLES_EVENT = "CONSUMABLES_EVENT"
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = admin,
        peers = { [admin] = { consumablesCapable = true } },
        sessionId = "freeze-queue",
        profileId = freezeP._profileId,
    }
    SF.LootHelperComm = {
        Send = function(_, _, msg, body)
            if msg == "CONSUMABLES_TRADE_FREEZE" and not allowSend then return false end
            if msg == "CONSUMABLES_TRADE_FREEZE" then
                sentTokens[#sentTokens + 1] = body and body.token
            end
            return true
        end,
    }
    assertTrue(Sync:PublishTradeFreeze(freezeP, openedA) == false, "the first dropped freeze stays pending")
    assertTrue(Sync:PublishTradeFreeze(freezeP, openedB) == false, "a second dropped freeze stays pending too")
    local otherId = "ce:other-token:" .. donor .. ":1"
    local otherToken = "trade-" .. vann .. "-99-99"
    assertTrue(select(1, C.AppendEvent(freezeP, {
        id = otherId,
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "trade",
        tradeToken = otherToken,
        timestamp = 4,
    }, { silent = true })), "an unrelated trade event is stored")
    assertTrue(Sync:BroadcastConsumablesEvent(freezeP, C.EventIndex(freezeP)[otherId]) == true, "a trade event does not wait for a different freeze")
    allowSend = true
    Sync:_FlushUnsentConsumablesEvents(freezeP)
    local sawA, sawB = false, false
    for i = 1, #sentTokens do
        if sentTokens[i] == tokenA then sawA = true end
        if sentTokens[i] == tokenB then sawB = true end
    end
    assertTrue(sawA and sawB, "both dropped trade freezes are retried")

    local officer = "Officer-Realm"
    local clearP = profile("remote-clear", admin, { admin, officer })
    assertTrue(select(1, C.AppendEvent(clearP, {
        id = "ce:remote-clear:" .. admin .. ":1",
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })), "the remote clear fixture stores one donation")
    local clearSends = {}
    Sync.MSG.CONSUMABLES_EVENT = "CONSUMABLES_EVENT"
    Sync.MSG.CONSUMABLES_CONFIG = "CONSUMABLES_CONFIG"
    Sync._SamePlayer = function(_, a, b) return a == b end
    Sync.IsRequesterInGroup = function() return true end
    Sync.FindLocalProfileById = function() return clearP end
    Sync._EnforceGroupedSessionActive = function() return "RAID" end
    Sync._SelfId = function() return admin end
    Sync.state = {
        active = true,
        isCoordinator = true,
        coordinator = admin,
        sessionId = "remote-clear",
        profileId = clearP._profileId,
    }
    SF.LootHelperComm = {
        Send = function(_, _, msg, body)
            if msg == "CONSUMABLES_EVENT" then
                clearSends[#clearSends + 1] = body and body.event
            end
            return true
        end,
    }
    Sync:HandleConsumablesOp(officer, {
        sessionId = "remote-clear",
        profileId = clearP._profileId,
        actor = officer,
        op = { name = "clear" },
    })
    assertEq(#clearSends, 1, "a remote clear broadcasts the reset")
    assertEq(clearSends[1] and clearSends[1].writer, officer, "the reset names the admin who requested the clear")
    assertEq(clearSends[1] and clearSends[1].actor, officer, "the reset actor is that admin")
    local followP = profile("remote-clear-follow", admin, { admin, officer })
    followP._consumables.generation = 2
    assertTrue(select(1, S.ApplyRemoteEvent(followP, clearSends[1], admin, { coordinatorRelay = true })), "a follower accepts the other admin's reset")
    local sawOfficer = false
    local followRows = C.HistoryRows(followP)
    for i = 1, #followRows do
        if followRows[i].text:find(officer, 1, true) then sawOfficer = true end
    end
    assertTrue(sawOfficer, "the follower log names the admin who cleared")

    local archP = profile("archive-quota", admin)
    archP._consumables.generation = 3
    local archivedBudget = true
    for i = 1, C.MAX_EVENTS_PER_ACTOR do
        local ok = C.AppendEvent(archP, {
            id = "ce:aq:" .. admin .. ":" .. tostring(i),
            type = C.EVENT.DONATION,
            actor = admin,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            source = "guildbank",
            timestamp = i,
        }, { silent = true })
        if not ok then archivedBudget = false end
    end
    assertTrue(archivedBudget, "a writer can archive the per-writer budget")
    local overArchive, overStatus = C.AppendEvent(archP, {
        id = "ce:aq:" .. admin .. ":over",
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })
    assertFalse(overArchive, "another older event from that writer is rejected")
    assertEq(overStatus, "quota", "the archive rejection names the per-writer budget")
    assertTrue(select(1, C.AppendEvent(archP, {
        id = "ce:aq:" .. donor .. ":1",
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })), "another writer can still archive an older event")
    local zeroOk, zeroStatus = C.AppendEvent(archP, {
        id = "ce:aq:zero",
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 0,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })
    assertFalse(zeroOk, "generation 0 is not archived")
    assertEq(zeroStatus, "invalid", "a generation below 1 is invalid")

    SF.GetActiveProfile = savedGet
    SF.lootHelperDB = savedDb
    SF.PrintInfo = savedInfo
    Sync.state = savedState
    Sync.FindLocalProfileById = savedFind
    Sync.RequestProfileSnapshot = savedRequest
    SF.LootHelperComm = savedComm
    Sync.IsSafeModeEnabled = savedSafe
    RT.review = nil
    RT.qtyOverrides = {}
end
checkFollowupRound()

local function checkCodexRound()
    local stampP = profile("writer-stamp", admin)
    assertTrue(select(1, C.AddCrafter(stampP, admin, vann, { asAdmin = true })), "writer stamp can add a crafter")
    local token = "trade-" .. vann .. "-4-4"
    local events = {
        {
            type = C.EVENT.DONATION,
            actor = donor,
            crafter = vann,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            source = "trade",
        },
        {
            type = C.EVENT.RECEIPT,
            actor = vann,
            crafter = vann,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            epoch = 1,
        },
    }
    assertTrue(C.CommitEvents(stampP, token, events, { writer = vann }), "a local commit can name its writer")
    assertEq(events[1].writer, vann, "a donation is charged to the observing writer")
    assertEq(events[2].writer, vann, "a receipt is charged to the same observing writer")
    local unnamed = {
        {
            type = C.EVENT.DONATION,
            actor = donor,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            source = "guildbank",
        },
    }
    assertTrue(C.CommitEvents(stampP, "no-name-token", unnamed, { writer = vann }), "a commit without the writer in the id still stores")
    assertEq(unnamed[1].writer, nil, "a writer is not stamped unless the event id names them")
    local savedSelf = Sync._SelfId
    local savedState = Sync.state
    Sync._SelfId = function() return vann end
    Sync.state = nil
    local synced = {
        {
            type = C.EVENT.DONATION,
            actor = donor,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            source = "guildbank",
        },
    }
    assertTrue(Sync:CommitConsumablesEvents(stampP, "guild-" .. vann .. "-8-8", synced), "session commit stamps through sync")
    assertEq(synced[1].writer, vann, "sync uses the local character as the writer")
    Sync._SelfId = savedSelf
    Sync.state = savedState

    local quotaW = profile("writer-quota", admin)
    local filled = true
    for i = 1, C.MAX_EVENTS_PER_ACTOR do
        local ok = C.AppendEvent(quotaW, {
            id = "ce:wq:" .. admin .. ":" .. tostring(i),
            type = C.EVENT.DONATION,
            actor = donor,
            writer = admin,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            source = "guildbank",
            timestamp = i,
        }, { silent = true })
        if not ok then filled = false end
    end
    assertTrue(filled, "mixed actors still fill the observing writer's budget")
    local blocked, blockedStatus = C.AppendEvent(quotaW, {
        id = "ce:wq:" .. admin .. ":over",
        type = C.EVENT.DONATION,
        actor = "Other-Realm",
        writer = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })
    assertFalse(blocked, "the next event for that writer is rejected")
    assertEq(blockedStatus, "quota", "the writer budget does not follow the donor")
    assertTrue(select(1, C.AppendEvent(quotaW, {
        id = "ce:wq:" .. donor .. ":free",
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
        source = "guildbank",
        timestamp = 1,
    }, { silent = true })), "an unstamped donor still has a separate budget")

    local grantP = profile("grant-keep", admin)
    assertTrue(select(1, C.AddCrafter(grantP, admin, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(grantP, admin, aqirite, vann, { asAdmin = true })))
    local grantEpoch = grantP._consumables.assignments[tostring(aqirite)].epoch
    local grantNow = 5000
    local token1 = "trade-" .. vann .. "-1-1"
    local token2 = "trade-" .. vann .. "-2-2"
    local function tradeGrant(which, generation)
        return {
            token = which,
            donor = donor,
            receiver = vann,
            generation = generation or 1,
            items = { { itemId = aqirite, epoch = grantEpoch } },
        }
    end
    local function tradeEvent(which, suffix)
        return {
            id = "ce:grant-keep:" .. which .. ":" .. suffix,
            type = C.EVENT.DONATION,
            source = "trade",
            actor = donor,
            crafter = vann,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            epoch = grantEpoch,
            tradeToken = which,
        }
    end
    assertTrue(S.RegisterTradeGrant(grantP, tradeGrant(token1), grantNow), "the first trade grant is stored")
    assertTrue(S.RegisterTradeGrant(grantP, tradeGrant(token2), grantNow + 10), "a second trade grant does not replace the first")
    assertTrue(S.TradeGrantMatches(grantP, tradeEvent(token1, "1"), vann, grantNow + 10), "the earlier trade grant is still authorized")
    assertTrue(S.TradeGrantMatches(grantP, tradeEvent(token2, "1"), vann, grantNow + 10), "the later trade grant is authorized too")
    S.NoteTradeGrantUse(grantP, tradeEvent(token1, "1"))
    assertTrue(S.RegisterTradeGrant(grantP, tradeGrant(token1), grantNow + S.TRADE_GRANT_TTL - 1), "refreshing a grant keeps its original expiry")
    assertFalse(S.TradeGrantMatches(grantP, tradeEvent(token1, "2"), vann, grantNow + 10), "a used trade slot cannot authorize a second event")
    assertFalse(S.TradeGrantMatches(grantP, tradeEvent(token1, "1"), vann, grantNow + S.TRADE_GRANT_TTL + 1), "refreshing a grant does not extend its expiry")
    assertTrue(S.TradeGrantMatches(grantP, tradeEvent(token2, "1"), vann, grantNow + S.TRADE_GRANT_TTL + 1), "the later grant keeps the expiry from when it was stored")

    local left = profile("config-fp-left", admin)
    local right = profile("config-fp-right", admin)
    assertTrue(select(1, C.AddCrafter(right, admin, vann, { asAdmin = true })))
    left._consumables.configSeq = 3
    right._consumables.configSeq = 3
    local leftDesc = C.Descriptor(left)
    local rightDesc = C.Descriptor(right)
    assertTrue(leftDesc.configFingerprint ~= rightDesc.configFingerprint, "different crafters change the config fingerprint")
    assertFalse(S.CoordinatorConfigDiffers(leftDesc, {
        generation = 1,
        configSeq = 3,
    }), "a peer that omits the config fingerprint is not a fork")
    assertFalse(S.CoordinatorConfigDiffers(leftDesc, {
        generation = 1,
        configSeq = 3,
        configFingerprint = leftDesc.configFingerprint,
    }), "the same config fingerprint is not a fork")
    assertTrue(S.CoordinatorConfigDiffers(leftDesc, {
        generation = 1,
        configSeq = 3,
        configFingerprint = rightDesc.configFingerprint,
    }), "the same sequence with a different config fingerprint needs the coordinator")
    local savedFind = Sync.FindLocalProfileById
    local savedRequest = Sync.RequestProfileSnapshot
    savedState = Sync.state
    local configCalls = {}
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = "Coord-Realm",
        sessionId = "config-fp",
        profileId = left._profileId,
        coordEpoch = 1,
    }
    Sync.FindLocalProfileById = function() return left end
    Sync.RequestProfileSnapshot = function(_, reason, opts)
        configCalls[#configCalls + 1] = {
            reason = reason,
            coordinatorOnly = opts and opts.coordinatorOnly or false,
        }
        return true
    end
    Sync._consumablesCatchUpKey = nil
    left._consumablesConfigCatchUpSession = nil
    local savedFpNow = Sync._Now
    local fpNow = 50
    Sync._Now = function() return fpNow end
    local fpPayload = {
        coordinator = "Coord-Realm",
        profileId = left._profileId,
        sessionId = "config-fp",
        consumablesGeneration = 1,
        consumablesConfigSeq = 3,
        consumablesEventCount = 0,
        consumablesEventFingerprint = leftDesc.eventFingerprint,
        consumablesConfigFingerprint = rightDesc.configFingerprint,
    }
    Sync:_ConsiderConsumablesCatchUp(fpPayload)
    assertEq(#configCalls, 0, "a new config fingerprint waits before requesting a snapshot")
    fpNow = 65
    Sync:_ConsiderConsumablesCatchUp(fpPayload)
    assertEq(configCalls[1] and configCalls[1].reason, "consumables-config", "a config fingerprint fork requests configuration")
    Sync._Now = savedFpNow
    assertEq(configCalls[1] and configCalls[1].coordinatorOnly, true, "that configuration request goes to the coordinator")
    Sync.FindLocalProfileById = savedFind
    Sync.RequestProfileSnapshot = savedRequest
    Sync.state = savedState

    local retired = profile("retired-cap", admin)
    assertTrue(select(1, C.AddCrafter(retired, admin, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(retired, admin, aqirite, vann, { asAdmin = true })))
    local keptEpoch = retired._consumables.assignments[tostring(aqirite)].epoch
    assertTrue(select(1, C.RemoveAssignment(retired, admin, aqirite, vann, { asAdmin = true })))
    assertTrue(retired._consumables.assignments[tostring(aqirite)] ~= nil, "the newest empty assignment row is kept")
    assertTrue(C.CrafterAssignedAtEpoch(retired, vann, aqirite, keptEpoch), "kept rows still remember the prior epoch")
    assertTrue(select(1, C.AddAssignment(retired, admin, aqirite, vann, { asAdmin = true })))
    assertTrue(retired._consumables.assignments[tostring(aqirite)].epoch > keptEpoch, "restoring a kept row uses a newer epoch")
    for i = 1, C.MAX_ASSIGNMENT_HISTORY + 3 do
        local itemId = 210000 + i
        assertTrue(select(1, C.AddAssignment(retired, admin, itemId, vann, { asAdmin = true })))
        assertTrue(select(1, C.RemoveAssignment(retired, admin, itemId, vann, { asAdmin = true })))
    end
    local emptyRows = 0
    for _, row in pairs(retired._consumables.assignments) do
        if type(row) ~= "table" or type(row.crafters) ~= "table" or #row.crafters == 0 then
            emptyRows = emptyRows + 1
        end
    end
    assertEq(emptyRows, C.MAX_ASSIGNMENT_HISTORY, "empty assignment rows stay within the history cap")

    local withdrawP = profile("withdraw-grant", admin)
    assertTrue(select(1, C.SetGuild(withdrawP, admin, { guid = "club-grant", name = "Spectrum", realm = "Realm" }, 2, { asAdmin = true })))
    assertTrue(select(1, C.AddCrafter(withdrawP, admin, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(withdrawP, admin, aqirite, vann, { asAdmin = true })))
    local withdrawEpoch = withdrawP._consumables.assignments[tostring(aqirite)].epoch
    local savedProfileFn = RT.Profile
    local savedGuildFn = RT.CurrentGuild
    local savedScan = RT.ScanBags
    local savedTabs = RT.TabItemCounts
    local savedCapture = RT.CaptureBaseline
    local savedSelfFn = RT.SelfId
    local savedCommit = RT.Commit
    local savedBags = RT.bagCounts
    local savedLink = GetGuildBankItemLink
    local savedInfo = GetGuildBankItemInfo
    local savedWithdrawFind = Sync.FindLocalProfileById
    savedState = Sync.state
    Sync.state = nil
    Sync.FindLocalProfileById = function(_, id)
        if id == withdrawP._profileId then return withdrawP end
        return nil
    end
    GetGuildBankItemLink = function()
        return "item:" .. tostring(aqirite)
    end
    GetGuildBankItemInfo = function()
        return nil, 5
    end
    RT.Profile = function() return withdrawP end
    RT.CurrentGuild = function() return { guid = "club-grant" } end
    RT.ScanBags = function() end
    RT.CaptureBaseline = function() end
    RT.SelfId = function() return vann end
    RT.TabItemCounts = function()
        return { [aqirite] = 20 }
    end
    RT.bagCounts = { [aqirite] = 0 }
    RT.withdrawIntent = nil
    RT.withdrawIntents = nil
    local captured = nil
    RT.Commit = function(_, _, commitToken, commitEvents)
        captured = { token = commitToken, events = commitEvents }
        return true
    end
    RT:NoteGuildBankPickup(2, 1, false)
    local withdrawToken = RT.withdrawIntents[1].token
    assertTrue(select(1, C.RemoveAssignment(withdrawP, admin, aqirite, vann, { asAdmin = true })))
    RT.bagCounts = { [aqirite] = 5 }
    RT.TabItemCounts = function()
        return { [aqirite] = 15 }
    end
    GetGuildBankItemLink = function() return nil end
    GetGuildBankItemInfo = function() return nil, 0 end
    RT:FinishWithdraw(false)
    assertEq(captured and captured.token, withdrawToken, "the withdrawal still commits on its original token")
    assertEq(captured.events[1].withdrawToken, withdrawToken, "the receipt names the frozen withdrawal")
    assertEq(captured.events[1].epoch, withdrawEpoch, "the receipt keeps the epoch from the pickup")
    local receipt = {
        id = "ce:" .. withdrawP._profileId .. ":" .. withdrawToken .. ":1",
        type = C.EVENT.RECEIPT,
        source = "guildbank",
        actor = vann,
        crafter = vann,
        itemId = aqirite,
        quantity = 5,
        generation = withdrawP._consumables.generation,
        epoch = withdrawEpoch,
        withdrawToken = withdrawToken,
    }
    assertTrue(select(1, S.ApplyRemoteEvent(withdrawP, receipt, vann)), "a frozen withdrawal is accepted after the assignment changes")
    local unfrozen = {
        id = "ce:" .. withdrawP._profileId .. ":guild-" .. vann .. "-9-9:1",
        type = C.EVENT.RECEIPT,
        source = "guildbank",
        actor = vann,
        crafter = vann,
        itemId = aqirite,
        quantity = 1,
        generation = withdrawP._consumables.generation,
        epoch = withdrawEpoch,
    }
    assertFalse(select(1, S.ApplyRemoteEvent(withdrawP, unfrozen, vann)), "a withdrawal without that grant is rejected")
    RT.Profile = savedProfileFn
    RT.CurrentGuild = savedGuildFn
    RT.ScanBags = savedScan
    RT.TabItemCounts = savedTabs
    RT.CaptureBaseline = savedCapture
    RT.SelfId = savedSelfFn
    RT.Commit = savedCommit
    RT.bagCounts = savedBags
    if RT.withdrawTimer and RT.withdrawTimer.Cancel then
        RT.withdrawTimer:Cancel()
    end
    RT.withdrawTimer = nil
    RT.withdrawIntent = nil
    RT.withdrawIntents = nil
    Sync.state = savedState
    Sync.FindLocalProfileById = savedWithdrawFind
    GetGuildBankItemLink = savedLink
    GetGuildBankItemInfo = savedInfo
end
checkCodexRound()

function checkShelveAndCapability()
    local shelveP = profile("shelve-quota", admin)
    local function donate(gen, n, who)
        return {
            id = string.format("ce:shelve:%s:%d:%d", who, gen, n),
            type = C.EVENT.DONATION,
            actor = who,
            writer = who,
            itemId = aqirite,
            quantity = 1,
            generation = gen,
            timestamp = n,
        }
    end
    local function archiveCounts()
        local donations, resets = 0, 0
        local archive = shelveP._consumableEventArchive or {}
        for i = 1, #archive do
            local ev = archive[i]
            if type(ev) == "table" and ev.type == C.EVENT.RESET then
                resets = resets + 1
            elseif type(ev) == "table" and ev.type == C.EVENT.DONATION and ev.writer == admin then
                donations = donations + 1
            end
        end
        return donations, resets
    end
    for i = 1, C.MAX_EVENTS_PER_ACTOR do
        assertTrue(select(1, C.AppendEvent(shelveP, donate(1, i, admin), { silent = true })), "shelve quota fills the live ledger")
    end
    assertTrue(select(1, C.Clear(shelveP, admin, { asAdmin = true })), "the first clear archives within the writer budget")
    assertEq(#shelveP._consumableEvents, 0, "the first clear leaves the live ledger empty")
    local donations, resets = archiveCounts()
    assertEq(donations, C.MAX_EVENTS_PER_ACTOR, "the first clear archives that writer's donations")
    assertEq(resets, 1, "the first clear archives the reset")
    local generation = shelveP._consumables.generation
    for i = 1, C.MAX_EVENTS_PER_ACTOR do
        assertTrue(select(1, C.AppendEvent(shelveP, donate(generation, i, admin), { silent = true })), "the next generation can fill the live ledger again")
    end
    assertTrue(select(1, C.Clear(shelveP, admin, { asAdmin = true })), "a second clear still succeeds")
    assertEq(#shelveP._consumableEvents, 0, "the second clear leaves the live ledger empty")
    donations, resets = archiveCounts()
    assertEq(donations, C.MAX_EVENTS_PER_ACTOR, "a second clear does not archive more of that writer's donations")
    assertEq(resets, 2, "each clear still archives its reset")
    local sawReset = false
    local rows = C.HistoryRows(shelveP)
    for i = 1, #rows do
        if rows[i].text:find("cleared the Raid Consumables configuration", 1, true) then sawReset = true end
    end
    assertTrue(sawReset, "the archived reset stays in the log")
    assertTrue(select(1, C.AppendEvent(shelveP, donate(1, 1, "Other-Realm"), { silent = true })), "another writer can still archive an older donation")
    assertEq(select(1, W.InterpretDeposit({
        guildOk = true, configuredTab = 2, observedTab = 2,
        intendedQty = 20,
        beforeTab = 100, afterTab = 100,
        beforeBags = 20, afterBags = 0,
        placedSlots = { { before = 10, after = 30 } },
    })), 20, "a deposit records the slots this client filled")
    assertEq(W.InterpretWithdraw({
        localPickup = true, configuredTab = 2, observedTab = 2, intendedQty = 20,
        beforeTab = 50, afterTab = 70,
        beforeBags = 0, afterBags = 20,
        slotLoss = 20,
    }), 20, "a withdrawal records the slot this client emptied")

    local capP = profile("incapable-coord", admin)
    local savedState = Sync.state
    local savedComm = SF.LootHelperComm
    local savedSafe = Sync.IsSafeModeEnabled
    local savedMsg = Sync.MSG
    local sent = 0
    Sync.MSG = {
        CONSUMABLES_OP = "CONSUMABLES_OP",
        CONSUMABLES_EVENT = "CONSUMABLES_EVENT",
        CONSUMABLES_TRADE_FREEZE = "CONSUMABLES_TRADE_FREEZE",
    }
    Sync.IsSafeModeEnabled = function() return false end
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = "Old-Realm",
        sessionId = "old-session",
        profileId = capP._profileId,
        peers = { ["Old-Realm"] = {} },
    }
    SF.LootHelperComm = {
        Send = function()
            sent = sent + 1
            return true
        end,
    }
    local blockedOk, blockedErr = Sync:CommitConsumablesOp(capP, { name = "set_bank_tab", bankTab = 2 }, admin, { asAdmin = true })
    assertFalse(blockedOk, "an incapable coordinator does not accept a config edit")
    assertTrue(type(blockedErr) == "string" and blockedErr:find("coordinator") ~= nil, "the player is told the coordinator cannot record raid supplies")
    assertEq(sent, 0, "the config edit is not whispered")
    assertTrue(Sync:CommitConsumablesEvents(capP, "guild-" .. admin .. "-1-1", {
        {
            type = C.EVENT.DONATION,
            actor = admin,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
        },
    }), "the local ledger still records the event")
    assertEq(sent, 0, "the event is not whispered to an incapable coordinator")
    assertTrue(type(capP._consumablesUnsent) == "table" and capP._consumablesUnsent[1] ~= nil, "the event stays queued")
    Sync.state.peers["Old-Realm"].consumablesCapable = true
    Sync:_FlushUnsentConsumablesEvents(capP)
    assertEq(sent, 1, "the queued event is sent once the coordinator is capable")
    assertEq(capP._consumablesUnsent[1], nil, "a delivered event leaves the queue")

    local announceP = profile("announce-flush", admin)
    local announceId = "ce:announce:" .. admin .. ":1"
    assertTrue(select(1, C.AppendEvent(announceP, {
        id = announceId,
        type = C.EVENT.DONATION,
        actor = admin,
        itemId = aqirite,
        quantity = 1,
        generation = 1,
    }, { silent = true })), "an announcement fixture can store one donation")
    announceP._consumablesUnsent = { announceId }
    sent = 0
    local savedFind = Sync.FindLocalProfileById
    Sync.FindLocalProfileById = function(_, id)
        if id == announceP._profileId then return announceP end
        return nil
    end
    Sync.state = {
        active = true,
        isCoordinator = true,
        coordinator = admin,
        sessionId = "new-session",
        profileId = announceP._profileId,
    }
    Sync:_AttachConsumablesDescriptor({ sessionId = "new-session" }, announceP._profileId)
    assertEq(sent, 0, "building a session announcement does not send queued raid supplies")
    assertEq(announceP._consumablesUnsent[1], announceId, "the queued event stays queued until the session is announced")
    Sync.state._sessionAnnounced = "new-session"
    Sync:_FlushUnsentConsumablesEvents(announceP)
    assertEq(sent, 1, "queued raid supplies send after the session announcement is accepted")
    Sync.FindLocalProfileById = savedFind
    Sync.state = savedState
    SF.LootHelperComm = savedComm
    Sync.IsSafeModeEnabled = savedSafe
    Sync.MSG = savedMsg

    local savedReview = RT.review
    local savedButtons = RT.reviewButtons
    local savedReminder = RT.reminderShown
    local savedMap = RT.groupMap
    RT.review = { IsShown = function() return false end }
    RT.reviewButtons = { { recipient = vann, IsShown = function() return true end } }
    RT.reminderShown = true
    RT.groupMap = {}
    assertFalse(RT:ShouldPoll(), "a hidden review does not keep range polling alive")
    RT.review = { IsShown = function() return true end }
    assertTrue(RT:ShouldPoll(), "an open review polls while the selected crafter is out of range")
    RT.review = savedReview
    RT.reviewButtons = savedButtons
    RT.reminderShown = savedReminder
    RT.groupMap = savedMap

    local savedSpell = C_Spell
    local savedBook = C_SpellBook
    local savedEnum = Enum
    C_Spell = { GetSpellInfo = function() return { name = "Mobile Banking" } end }
    C_SpellBook = { IsSpellInSpellBook = function() return false end }
    Enum = { SpellBookSpellBank = { Player = 1 } }
    assertEq(RT:MobileSpell(), nil, "an unknown mobile banking spell does not expose a secure name")
    C_SpellBook = { IsSpellInSpellBook = function() return true end }
    assertEq(RT:MobileSpell(), "Mobile Banking", "a known mobile banking spell uses its spell name")
    C_Spell = savedSpell
    C_SpellBook = savedBook
    Enum = savedEnum
end
checkShelveAndCapability()

function checkAdoptedLedgerRound()
    local restoreP = profile("restore-gen", admin)
    local donationId = "ce:restore-gen:" .. admin .. ":1"
    assertTrue(select(1, C.AppendEvent(restoreP, {
        id = donationId, type = C.EVENT.DONATION, actor = admin, itemId = aqirite,
        quantity = 4, generation = 1, timestamp = 1,
    }, { silent = true })), "the generation being cleared has a donation")
    assertTrue(select(1, C.Clear(restoreP, admin, { asAdmin = true })), "clear archives that generation")
    assertEq(restoreP._consumables.generation, 2, "clear advances the generation")
    assertTrue(hasEvent(restoreP._consumableEventArchive, donationId), "the cleared donation is archived")
    local resetId = nil
    for i = 1, #restoreP._consumableEventArchive do
        local archived = restoreP._consumableEventArchive[i]
        if archived.type == C.EVENT.RESET then resetId = archived.id end
    end
    assertTrue(resetId ~= nil, "the clear reset stays in the archive")
    S.NoteCoordinatorWatermark(restoreP, 2, restoreP._consumables.configSeq, 1)
    assertEq(select(2, S.ApplyRemoteConfig(restoreP, {
        generation = 1, configSeq = 1, crafters = {}, assignments = {},
    }, admin, { coordinatorAuthoritative = true, coordEpoch = 2 })), "applied", "a coordinator can adopt generation 1 again")
    assertTrue(hasEvent(restoreP._consumableEvents, donationId), "the adopted generation returns to the live ledger")
    assertFalse(hasEvent(restoreP._consumableEvents, resetId), "the local reset does not return to the live ledger")
    assertTrue(hasEvent(restoreP._consumableEventArchive, resetId), "the local reset stays archived until a snapshot omits it")
    assertEq(C.ContributionTotal(restoreP, admin, aqirite), 4, "the restored donation is projected")
    assertEq(select(2, C.AppendEvent(restoreP, {
        id = donationId, type = C.EVENT.DONATION, actor = admin, itemId = aqirite,
        quantity = 4, generation = 1, timestamp = 1,
    }, { silent = true })), "duplicate", "restoring an archived id does not duplicate it")
    assertEq(#restoreP._consumableEvents, 1, "the restored donation is stored once")
    local savedState = Sync.state
    Sync.state = { active = true, coordEpoch = 2, sessionId = "restore", coordinator = admin, profileId = restoreP._profileId }
    assertTrue(C.MergeSnapshot(restoreP, {
        generation = 1, configSeq = 1, crafters = {}, assignments = {},
        events = {
            { id = donationId, type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 4, generation = 1, timestamp = 1 },
        },
    }, { consumablesFromCoordinator = true }), "the coordinator snapshot imports after the generation restore")
    assertFalse(hasEvent(restoreP._consumableEventArchive, resetId), "a coordinator snapshot drops a local reset it does not contain")
    assertTrue(hasEvent(restoreP._consumableEvents, donationId), "the coordinator snapshot keeps the shared donation")

    local rejectP = profile("reject-local", admin)
    local rejectedId = "ce:reject-local:local:1"
    local queuedId = "ce:reject-local:queued:1"
    assertTrue(select(1, C.AppendEvent(rejectP, {
        id = rejectedId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 1, generation = 1, timestamp = 1,
    }, { silent = true })), "a rejected local event is stored before the snapshot")
    assertTrue(select(1, C.AppendEvent(rejectP, {
        id = queuedId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 2, generation = 1, timestamp = 2,
    }, { silent = true })), "an unsent local event is stored before the snapshot")
    rejectP._consumablesUnsent = { queuedId }
    Sync.state = { active = true, coordEpoch = 1, sessionId = "reject", coordinator = admin, profileId = rejectP._profileId }
    assertTrue(C.MergeSnapshot(rejectP, {
        generation = 1, configSeq = 1, crafters = {}, assignments = {},
        events = {
            { id = "ce:reject-local:remote:1", type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 3, generation = 1, timestamp = 3 },
        },
    }, { consumablesFromCoordinator = true }), "an authoritative snapshot reconciles local rows")
    assertFalse(hasEvent(rejectP._consumableEvents, rejectedId), "a sent event the coordinator omitted is removed")
    assertTrue(hasEvent(rejectP._consumableEvents, queuedId), "an event still queued to send is kept")
    assertTrue(hasEvent(rejectP._consumableEvents, "ce:reject-local:remote:1"), "the coordinator event is stored")
    local helperExtra = "ce:reject-local:helper-extra:1"
    assertTrue(select(1, C.AppendEvent(rejectP, {
        id = helperExtra, type = C.EVENT.DONATION, actor = admin, itemId = aqirite,
        quantity = 1, generation = 1, timestamp = 4,
    }, { silent = true })), "a helper snapshot starts with a local extra event")
    assertTrue(C.MergeSnapshot(rejectP, {
        generation = 9, configSeq = 9, crafters = { donor }, assignments = {},
        events = {
            { id = "ce:reject-local:helper:1", type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1, timestamp = 5 },
        },
    }, { consumablesFromCoordinator = false }), "a helper snapshot still merges")
    assertTrue(hasEvent(rejectP._consumableEvents, helperExtra), "a helper snapshot does not drop local events")
    assertEq(rejectP._consumables.crafters[1], nil, "a helper snapshot does not replace the roster")

    local offlineP = profile("offline-q", admin)
    Sync.state = nil
    assertTrue(select(1, Sync:CommitConsumablesEvents(offlineP, "offline-1", {
        { type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1 },
    })), "an offline commit is stored")
    local offlineId = "ce:offline-q:offline-1:1"
    assertEq(offlineP._consumablesUnsent and offlineP._consumablesUnsent[1], offlineId, "an offline commit stays queued until it can be sent")
    Sync.state = savedState

    local rosterP = profile("roster-cap", admin)
    local longName = string.rep("A", 65) .. "-Realm"
    assertFalse(select(1, C.AddCrafter(rosterP, admin, longName, { asAdmin = true })), "a Crafter name longer than 64 characters is rejected")
    for i = 1, C.MAX_ASSIGNMENT_PAIRS do
        C.AddCrafter(rosterP, admin, "Crafter" .. i .. "-Realm", { asAdmin = true })
    end
    assertFalse(select(1, C.AddCrafter(rosterP, admin, "Overflow-Realm", { asAdmin = true })), "the Crafter roster stops at its cap")
    assertEq(#rosterP._consumables.crafters, C.MAX_ASSIGNMENT_PAIRS, "the stored roster stays at the cap")

    local savedNameUtil = SF.NameUtil
    SF.NameUtil = {
        NormalizeNameRealm = function(name) return name end,
        SamePlayer = function(a, b)
            if type(a) ~= "string" or type(b) ~= "string" then return false end
            return a:lower() == b:lower()
        end,
    }
    local caseP = profile("case-route", admin)
    assertTrue(select(1, C.AddCrafter(caseP, admin, "Vann-Realm", { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(caseP, admin, aqirite, "Vann-Realm", { asAdmin = true })))
    local epoch = caseP._consumables.assignments[tostring(aqirite)].epoch
    assertTrue(select(1, C.AppendEvent(caseP, {
        id = "ce:case-route:receipt:1", type = C.EVENT.RECEIPT, actor = "vann-realm", crafter = "vann-realm",
        itemId = aqirite, quantity = 9, generation = 1, epoch = epoch, timestamp = 1,
    }, { silent = true })), "a differently capitalized receipt is stored")
    assertEq(C.ReceiptTotal(caseP, aqirite, "Vann-Realm"), 9, "receipt totals match a Crafter regardless of capitalization")
    local casePlan = C.BuildDonationPlan(caseP, { { itemId = aqirite, quantity = 1 } }, {
        inGroup = { ["vann-realm"] = true },
        compatible = { ["vann-realm"] = true },
        inRange = { ["vann-realm"] = true },
        guildBankUsable = false,
    })
    assertEq(casePlan.lines[1].recipient, "Vann-Realm", "routing finds the roster entry for a differently capitalized Crafter")
    assertEq(casePlan.lines[1].inRange, true, "range follows the same Crafter despite capitalization")
    SF.NameUtil = savedNameUtil

    local mergeP = profile("merge-scan", admin)
    assertTrue(select(1, C.SetGuild(mergeP, admin, { guid = "club-merge", name = "Spectrum", realm = "Realm" }, 1, { asAdmin = true })))
    assertTrue(select(1, C.AddCrafter(mergeP, admin, vann, { asAdmin = true })))
    local carriedId = 300000 + 70
    for i = 1, 70 do
        C.AddAssignment(mergeP, admin, 300000 + i, vann, { asAdmin = true })
    end
    assertEq(#C.RequestedItemIds(mergeP), 70, "the merge scan has more requested items than the old 64-item cutoff")
    local savedBankOpen = RT.BankIsOpen
    local savedGuild = RT.CurrentGuild
    local savedBags = RT.bagCounts
    local savedNum = GetGuildBankNumSlots
    local savedLink = GetGuildBankItemLink
    local savedInfo = GetGuildBankItemInfo
    local savedTabInfo = GetGuildBankTabInfo
    local savedItemApi = C_Item
    RT.BankIsOpen = function() return true end
    RT.CurrentGuild = function() return { guid = "club-merge" } end
    RT.bagCounts = { [carriedId] = 4 }
    GetGuildBankNumSlots = function() return 98 end
    GetGuildBankTabInfo = function() return nil, nil, nil, true end
    GetGuildBankItemLink = function(_, slot)
        if slot == 1 then return "item:" .. tostring(carriedId) end
        return "item:1"
    end
    GetGuildBankItemInfo = function(_, slot)
        if slot == 1 then return nil, 5 end
        return nil, 20
    end
    C_Item = { GetItemMaxStackSizeByID = function() return 20 end }
    local mergeAccess = RT:BankAccess(mergeP)
    assertTrue(mergeAccess.enabled, "a carried item past the first 64 requested ids can still merge")
    assertEq(mergeAccess.reason, nil, "that partial stack does not report a full tab")
    RT.BankIsOpen = savedBankOpen
    RT.CurrentGuild = savedGuild
    RT.bagCounts = savedBags
    GetGuildBankNumSlots = savedNum
    GetGuildBankItemLink = savedLink
    GetGuildBankItemInfo = savedInfo
    GetGuildBankTabInfo = savedTabInfo
    C_Item = savedItemApi

    local early = profile("defer-early", admin)
    early._sfConsumablesDeleteAfter = true
    local savedDb = SF.lootHelperDB
    local savedDelete = SF.DeleteLootHelperProfile
    SF.lootHelperDB = nil
    RT:CompleteDeferredProfileDeletes()
    assertTrue(early._sfConsumablesDeleteAfter, "cleanup waits until the loot helper database exists")
    local earlyDeleted = nil
    SF.lootHelperDB = { profiles = { ["defer-early"] = early } }
    SF.DeleteLootHelperProfile = function(_, id)
        earlyDeleted = id
        SF.lootHelperDB.profiles[id] = nil
        return true
    end
    RT:CompleteDeferredProfileDeletes()
    assertEq(earlyDeleted, "defer-early", "cleanup deletes a marked profile once the database exists")
    SF.lootHelperDB = savedDb
    SF.DeleteLootHelperProfile = savedDelete

    local deferP = profile("defer-del", admin)
    savedDb = SF.lootHelperDB
    savedDelete = SF.DeleteLootHelperProfile
    local savedIntent = RT.depositIntent
    local savedScan = RT.ScanBags
    local savedTabs = RT.TabItemCounts
    local savedSlot = RT.SlotItemCount
    local savedCommit = RT.Commit
    local savedCapture = RT.CaptureBaseline
    local savedSelf = RT.SelfId
    SF.lootHelperDB = { profiles = { ["defer-del"] = deferP }, activeProfileId = "defer-del" }
    RT.depositIntent = {
        profileId = "defer-del",
        itemId = aqirite,
        tab = 1,
        guildGuid = "club-defer",
        intended = 1,
        beforeTab = 0,
        beforeBags = 1,
        places = { { slot = 1, before = 0 } },
        bestActual = 0,
        token = "dep-defer",
        generation = 1,
    }
    assertTrue(RT:DeferProfileDelete(deferP), "an in-flight deposit defers profile deletion")
    assertTrue(deferP._sfConsumablesDeleteAfter, "the deferred profile is marked")
    local deletedId = nil
    local committedProfile = nil
    SF.DeleteLootHelperProfile = function(_, id)
        deletedId = id
        SF.lootHelperDB.profiles[id] = nil
        return true
    end
    RT:CompleteDeferredProfileDeletes()
    assertEq(deletedId, nil, "the profile stays until the deposit commits")
    RT.ScanBags = function() end
    RT.CurrentGuild = function() return { guid = "club-defer" } end
    RT.TabItemCounts = function() return {} end
    RT.SlotItemCount = function() return 1 end
    RT.bagCounts = { [aqirite] = 0 }
    RT.CaptureBaseline = function() end
    RT.SelfId = function() return admin end
    RT.Commit = function(_, committed)
        committedProfile = committed
        return true
    end
    RT:FinishDeposit(true)
    assertEq(committedProfile, deferP, "the deposit commits on the profile that was being deleted")
    assertEq(deletedId, "defer-del", "the delete finishes after the deposit is recorded")
    RT.depositIntent = savedIntent
    RT.ScanBags = savedScan
    RT.TabItemCounts = savedTabs
    RT.SlotItemCount = savedSlot
    RT.Commit = savedCommit
    RT.CaptureBaseline = savedCapture
    RT.SelfId = savedSelf
    RT.CurrentGuild = savedGuild
    SF.DeleteLootHelperProfile = savedDelete
    SF.lootHelperDB = savedDb
end
checkAdoptedLedgerRound()

function checkGuildTabDraft()
    local guildP = profile("guild-tab", admin)
    function guildP:IsCurrentUserAdmin() return true end
    local savedGet = SF.GetActiveProfile
    local savedName = SF.NameUtil
    local savedGuild = RT.CurrentGuild
    local savedUI = SF.SettingsUI
    SF.GetActiveProfile = function() return guildP end
    SF.NameUtil = {
        GetSelfId = function() return admin end,
        NormalizeNameRealm = function(name) return name end,
        SamePlayer = function(a, b) return a ~= nil and a == b end,
    }
    RT.CurrentGuild = function()
        return { guid = "club-guild-tab", name = "Guild", realm = "Realm" }, 1
    end
    local captured = nil
    SF.SettingsUI = {
        RegisterPage = function(_, page)
            captured = page
        end,
        DefinitionRenderer = {
            Build = function() end,
            Refresh = function() end,
        },
    }
    load("SpectrumFederation/modules/UI/Settings/Pages/Consumables.lua")
    local built = nil
    SF.SettingsUI.DefinitionRenderer.Build = function(_, _, definition)
        built = definition
    end
    local panel = {
        IsShown = function() return false end,
        EnableMouse = function() end,
        SetScript = function() end,
    }
    captured:Build(panel)
    local click = nil
    local items = built.sections[1].items
    for i = 1, #items do
        if items[i].buttonText == "Set to My Guild" then
            click = items[i].onClick
        end
    end
    local messages = {}
    local ctx = {
        panel = panel,
        section = {
            SetMessage = function(_, text, kind)
                messages[#messages + 1] = { text = text, kind = kind }
            end,
            ClearMessage = function() end,
        },
    }
    panel.__sfConsumableTab = "9"
    click(ctx)
    assertEq(panel.__sfConsumableTab, nil, "a rejected bank tab draft is cleared")
    assertEq(guildP._consumables.guild, nil, "tab 9 does not lock the guild")
    assertTrue(messages[#messages] and messages[#messages].text:find("1 to 8", 1, true) ~= nil, "tab 9 is rejected")
    panel.__sfConsumableTab = "2"
    click(ctx)
    assertEq(guildP._consumables.bankTab, 2, "the next click uses the new bank tab")
    assertEq(panel.__sfConsumableTab, nil, "a saved bank tab draft is cleared")
    assertEq(guildP._consumables.guild.guid, "club-guild-tab", "the guild locks from the fresh tab")

    local commit = nil
    for i = 1, #items do
        if items[i].label == "Bank Tab" and items[i].onCommit then
            commit = items[i].onCommit
            break
        end
    end
    assertTrue(type(commit) == "function", "the bank tab field has an onCommit handler")
    local beforeTab = guildP._consumables.bankTab
    messages = {}
    commit(ctx, "9")
    assertEq(guildP._consumables.bankTab, beforeTab, "an out-of-range bank tab commit is rejected")
    assertTrue(messages[#messages] and messages[#messages].text:find("1 to 8", 1, true) ~= nil, "an out-of-range bank tab shows the range error")
    messages = {}
    commit(ctx, "3")
    assertEq(guildP._consumables.bankTab, 3, "a valid bank tab commit updates the locked guild tab")

    SF.GetActiveProfile = savedGet
    SF.NameUtil = savedName
    RT.CurrentGuild = savedGuild
    SF.SettingsUI = savedUI
end
checkGuildTabDraft()

function checkCodexTradeRound()
    local savedName = SF.NameUtil
    local savedProfile = RT.AccountingProfile
    local savedScan = RT.ScanBags
    local savedGroup = RT.GroupMap
    local savedCompat = RT.IsCompatible
    local savedRange = RT.IsInRange
    local review = RT:EnsureReview()
    local savedShown = review.IsShown
    SF.NameUtil = {
        GetSelfId = function() return admin end,
        NormalizeNameRealm = function(name) return name end,
        SamePlayer = function(a, b)
            return type(a) == "string" and type(b) == "string" and a:lower() == b:lower()
        end,
    }
    local rangeP = profile("range-case", admin)
    assertTrue(select(1, C.AddCrafter(rangeP, admin, sully, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(rangeP, admin, aqirite, sully, { asAdmin = true })))
    RT.AccountingProfile = function() return rangeP end
    RT.ScanBags = function()
        RT.bagCounts = { [aqirite] = 1 }
        RT.bagStacks = { [aqirite] = { { bag = 0, slot = 1, count = 1 } } }
    end
    RT.GroupMap = function()
        return { ["sully-realm"] = "raid1" }
    end
    RT.IsCompatible = function() return true end
    RT.IsInRange = function(_, unit) return unit == "raid1" end
    review.IsShown = function() return true end
    local savedAction = R.TradeAction
    local sawRange = nil
    R.TradeAction = function(recipient, inRange)
        sawRange = inRange
        return savedAction(recipient, inRange)
    end
    RT:RebuildReview()
    assertEq(sawRange, true, "the trade button uses the case-insensitive range flag")
    assertTrue(RT:RecipientInRange(sully), "later range checks find the roster despite capitalization")
    R.TradeAction = savedAction
    RT.AccountingProfile = savedProfile
    RT.ScanBags = savedScan
    RT.GroupMap = savedGroup
    RT.IsCompatible = savedCompat
    RT.IsInRange = savedRange
    review.IsShown = savedShown
    SF.NameUtil = savedName

    local savedContainer = C_Container
    local savedClick = ClickTradeButton
    local picked = nil
    C_Container = {
        GetContainerNumSlots = function() return 1 end,
        GetContainerItemInfo = function(bag, slot)
            if bag == 0 and slot == 1 then
                return { itemID = aqirite, stackCount = 5 }
            end
            return nil
        end,
        PickupContainerItem = function(bag, slot)
            picked = { bag = bag, slot = slot }
        end,
    }
    ClickTradeButton = function() end
    RT.pendingTrade = {
        line = { itemId = aqirite, quantity = 5 },
    }
    RT.bagStacks = { [aqirite] = { { bag = 4, slot = 9, count = 5 } } }
    RT:PlacePendingTrade()
    assertEq(picked and picked.bag, 0, "an opened trade scans bags before choosing a slot")
    assertEq(picked and picked.slot, 1, "an opened trade does not reuse a stale bag slot")
    picked = nil
    C_Container.GetContainerItemInfo = function() return nil end
    RT.pendingTrade = {
        line = { itemId = aqirite, quantity = 5 },
    }
    RT.bagStacks = { [aqirite] = { { bag = 4, slot = 9, count = 5 } } }
    RT:PlacePendingTrade()
    assertEq(picked, nil, "an opened trade does not pick up a slot after the item is gone")
    RT.pendingTrade = nil
    C_Container = savedContainer
    ClickTradeButton = savedClick

    local grantP = profile("grant-cap", admin)
    assertTrue(select(1, C.AddCrafter(grantP, admin, vann, { asAdmin = true })))
    local firstId = 210000
    local added = 0
    for i = 1, 33 do
        if select(1, C.AddAssignment(grantP, admin, firstId + i, vann, { asAdmin = true })) then
            added = added + 1
        end
    end
    assertEq(added, 33, "thirty-three assignments are stored before the trade opens")
    local wideToken = "trade-" .. vann .. "-wide-1"
    local wide = C.FreezeTrade(grantP, donor, vann, nil, wideToken)
    local wideGrant = S.TradeFreezePayload(wide)
    assertEq(wideGrant and #wideGrant.items, 33, "a trade freeze keeps every assigned item past the old 32-item cutoff")
    local lastId = firstId + 33
    local lastEpoch = grantP._consumables.assignments[tostring(lastId)].epoch
    assertTrue(S.RegisterTradeGrant(grantP, wideGrant, C.Now()), "the wider trade freeze can be granted")
    assertTrue(select(1, C.RemoveAssignment(grantP, admin, lastId, vann, { asAdmin = true })))
    assertTrue(select(1, S.ApplyRemoteEvent(grantP, {
        id = "ce:" .. grantP._profileId .. ":" .. wideToken .. ":late",
        type = C.EVENT.RECEIPT,
        actor = vann,
        crafter = vann,
        itemId = lastId,
        quantity = 1,
        generation = grantP._consumables.generation,
        epoch = lastEpoch,
        tradeToken = wideToken,
        source = "trade",
        timestamp = C.Now(),
    }, vann)), "an item past the old freeze cutoff still matches the open trade")

    local calls = 0
    local savedRows = C.HistoryRows
    C.HistoryRows = function(...)
        calls = calls + 1
        return savedRows(...)
    end
    local savedGet = SF.GetActiveProfile
    local savedUI = SF.SettingsUI
    local logP = profile("log-once", admin)
    SF.GetActiveProfile = function() return logP end
    local logPage = nil
    SF.SettingsUI = {
        RegisterPage = function(_, page)
            logPage = page
        end,
        DefinitionRenderer = {
            Build = function(_, panel, definition)
                panel.__sfPageDef = definition
            end,
            Refresh = function(_, panel)
                local items = panel.__sfPageDef.sections[1].items
                for i = 1, #items do
                    if items[i].getItems then
                        items[i].getItems()
                    end
                end
            end,
        },
    }
    load("SpectrumFederation/modules/UI/Settings/Pages/RaidConsumableLogs.lua")
    local panel = {
        IsShown = function() return true end,
        HookScript = function() end,
    }
    calls = 0
    logPage:Build(panel)
    logPage:Refresh(panel)
    assertEq(calls, 1, "a visible consumable log sorts its history once per refresh")
    C.HistoryRows = savedRows
    SF.GetActiveProfile = savedGet
    SF.SettingsUI = savedUI
end
checkCodexTradeRound()

function checkSnapshotTrustRound()
    local savedName = SF.NameUtil
    local savedState = Sync.state
    SF.NameUtil = {
        GetSelfId = function() return admin end,
        NormalizeNameRealm = function(name) return name end,
        SamePlayer = function(a, b)
            if type(a) ~= "string" or type(b) ~= "string" then return false end
            return a == b
        end,
    }
    local ackP = profile("unacked-self", admin)
    local selfId = "ce:unacked:trade-" .. admin .. "-1:1"
    local stampedId = "ce:unacked:trade-" .. admin .. "-2:1"
    local otherId = "ce:unacked:other:1"
    assertTrue(select(1, C.AppendEvent(ackP, {
        id = selfId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 4, generation = 1, timestamp = 1,
    }, { silent = true })), "an unstamped local donation is stored")
    assertTrue(select(1, C.AppendEvent(ackP, {
        id = stampedId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 1, generation = 1, timestamp = 2, order = 3,
    }, { silent = true })), "a stamped local donation is stored")
    assertTrue(select(1, C.AppendEvent(ackP, {
        id = otherId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 1, generation = 1, timestamp = 3,
    }, { silent = true })), "another client's unstamped donation is stored")
    ackP._consumablesUnsent = nil
    Sync.state = { active = true, coordEpoch = 1, sessionId = "unacked", coordinator = "Coord-Realm", profileId = ackP._profileId }
    assertTrue(C.MergeSnapshot(ackP, {
        generation = 1, configSeq = 1, crafters = {}, assignments = {},
        events = {
            { id = "ce:unacked:remote:1", type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1, timestamp = 4, order = 1 },
        },
    }, { consumablesFromCoordinator = true }), "the coordinator snapshot omits the local donations")
    assertTrue(hasEvent(ackP._consumableEvents, selfId), "an unstamped event this client wrote is kept")
    assertFalse(hasEvent(ackP._consumableEvents, stampedId), "a stamped event the coordinator omitted is still removed")
    assertFalse(hasEvent(ackP._consumableEvents, otherId), "an unstamped event that does not name this client is removed")
    local sawSelf = false
    for i = 1, #(ackP._consumablesUnsent or {}) do
        if ackP._consumablesUnsent[i] == selfId then sawSelf = true end
    end
    assertTrue(sawSelf, "the kept unstamped event is queued to send again")

    local forgedId = "ce:forge:" .. admin .. ":1"
    local function donation(quantity)
        return {
            id = forgedId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
            quantity = quantity, generation = 1, timestamp = 1, order = 7,
        }
    end
    local cleanP = profile("forge-clean", admin)
    assertTrue(select(1, C.AppendEvent(cleanP, donation(4), { silent = true })), "the real donation is stored on a clean ledger")
    local poisoned = profile("forge-helper", admin)
    assertTrue(C.MergeSnapshot(poisoned, {
        generation = 1, configSeq = 1, crafters = {}, assignments = {},
        events = { donation(99) },
    }, { consumablesFromCoordinator = false }), "a stamped helper event is admitted")
    assertEq(C.ContributionTotal(poisoned, admin, aqirite), 99, "the helper body is visible until the coordinator snapshot")
    assertTrue(C.Descriptor(poisoned).eventFingerprint ~= C.Descriptor(cleanP).eventFingerprint, "a different quantity does not share the coordinator fingerprint")
    assertTrue(C.MergeSnapshot(poisoned, {
        generation = 1, configSeq = 1, crafters = {}, assignments = {},
        events = { donation(4) },
    }, { consumablesFromCoordinator = true }), "the coordinator snapshot repairs the forged quantity")
    assertEq(C.ContributionTotal(poisoned, admin, aqirite), 4, "the coordinator body replaces the helper quantity")
    assertEq(C.Descriptor(poisoned).eventFingerprint, C.Descriptor(cleanP).eventFingerprint, "the repaired ledger matches the real fingerprint")

    local held = profile("forge-held", admin)
    assertTrue(select(1, C.AppendEvent(held, donation(4), { silent = true })), "the held ledger already has the real donation")
    assertTrue(C.MergeSnapshot(held, {
        generation = 1, configSeq = 1, crafters = {}, assignments = {},
        events = { donation(99), {
            id = "ce:forge:unsigned:1", type = C.EVENT.DONATION, actor = admin, itemId = aqirite,
            quantity = 1, generation = 1, timestamp = 1,
        } },
    }, { consumablesFromCoordinator = false }), "a helper snapshot with a forged copy still imports")
    assertEq(C.ContributionTotal(held, admin, aqirite), 4, "a helper snapshot does not replace a stored quantity")
    assertFalse(hasEvent(held._consumableEvents, "ce:forge:unsigned:1"), "a helper event without a writer stamp is ignored")

    load("SpectrumFederation/modules/LootHelperSync/14_HandlersControl.lua")
    local reProfile = "re-profile"
    Sync.state = {
        active = true,
        sessionId = "re-session",
        profileId = reProfile,
        coordinator = admin,
        coordEpoch = 3,
        isCoordinator = false,
        peers = {},
    }
    Sync._SamePlayer = function(_, a, b) return a == b end
    Sync._SelfId = function() return admin end
    Sync._Now = function() return 1 end
    Sync.IsControlMessageAllowed = function() return true end
    Sync._PersistSessionState = function() end
    Sync.EnsureHeartbeatMonitor = function() end
    Sync.IsRequesterInGroup = function() return true end
    Sync.TouchPeer = function(self, name, fields)
        self.state.peers[name] = self.state.peers[name] or {}
        for key, value in pairs(fields or {}) do
            self.state.peers[name][key] = value
        end
    end
    Sync:HandleSessionReannounce(admin, {
        sessionId = "re-session",
        profileId = reProfile,
        coordinator = admin,
        coordEpoch = 3,
        consumablesCapable = true,
    })
    assertEq(Sync.state.peers[admin] and Sync.state.peers[admin].consumablesCapable, true, "a session reannounce marks the coordinator ready for raid supplies")

    SF.NameUtil = savedName
    Sync.state = savedState
end
checkSnapshotTrustRound()

function checkHeadReviewRound()
    local quotaP = profile("quota-atomic", admin)
    local savedQuota = C.MAX_EVENTS_PER_ACTOR
    C.MAX_EVENTS_PER_ACTOR = 2
    local firstId = "ce:quota-atomic:trade-" .. admin .. "-0:1"
    assertTrue(select(1, C.AppendEvent(quotaP, {
        id = firstId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 1, generation = 1, timestamp = 1,
    }, { silent = true })), "the quota fixture has one stored event")
    local batchOk = C.CommitEvents(quotaP, "trade-" .. admin .. "-9", {
        { type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1 },
        { type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1 },
    }, { writer = admin })
    assertFalse(batchOk, "a batch that would pass the writer quota is rejected")
    assertEq(#quotaP._consumableEvents, 1, "a rejected batch does not keep its first event")
    assertTrue(hasEvent(quotaP._consumableEvents, firstId), "the earlier event stays after the rejected batch")
    C.MAX_EVENTS_PER_ACTOR = savedQuota

    local savedCap = C.MAX_LEDGER_EVENTS
    C.MAX_LEDGER_EVENTS = 1
    local roomP = profile("room-gen", admin)
    roomP._consumables.generation = 2
    local highId = "ce:room-gen:high:1"
    local lowId = "ce:room-gen:" .. admin .. ":1"
    assertTrue(select(1, C.AppendEvent(roomP, {
        id = highId, type = C.EVENT.DONATION, actor = admin, itemId = aqirite,
        quantity = 1, generation = 2, timestamp = 1,
    }, { silent = true })), "the full ledger holds the higher generation")
    local savedRoomState = Sync.state
    Sync.state = { active = true, coordEpoch = 2, sessionId = "room", coordinator = admin, profileId = roomP._profileId }
    assertTrue(C.MergeSnapshot(roomP, {
        generation = 1, configSeq = 1, crafters = {}, assignments = {},
        events = {
            {
                id = lowId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
                quantity = 3, generation = 1, timestamp = 2, order = 1,
            },
        },
    }, { consumablesFromCoordinator = true }), "an adopted generation imports into a full ledger")
    assertTrue(hasEvent(roomP._consumableEvents, lowId), "the adopted generation is stored after the higher generation makes room")
    assertFalse(hasEvent(roomP._consumableEvents, highId), "the higher generation leaves the live ledger")
    Sync.state = savedRoomState
    C.MAX_LEDGER_EVENTS = savedCap

    local importP = profile("import-cap", admin)
    local assignments = {}
    local longName = string.rep("N", 70) .. "-Realm"
    for i = 1, 300 do
        assignments["item-" .. i] = {
            itemId = 700000 + i,
            epoch = 1,
            crafters = { i == 1 and longName or ("Crafter" .. i .. "-Realm") },
        }
    end
    assertTrue(C.MergeSnapshot(importP, {
        generation = 1, configSeq = 4, crafters = { longName, vann }, assignments = assignments,
    }, { consumablesFromCoordinator = true }), "a large configuration snapshot still imports")
    local importedPairs = 0
    for _, row in pairs(importP._consumables.assignments) do
        importedPairs = importedPairs + #(row.crafters or {})
    end
    assertTrue(importedPairs <= C.MAX_ASSIGNMENT_PAIRS, "an imported configuration stops at the assignment cap")
    assertTrue(importedPairs > 0, "an imported configuration keeps assignments inside the cap")
    local sawLong = false
    for i = 1, #importP._consumables.crafters do
        if importP._consumables.crafters[i] == longName then sawLong = true end
    end
    assertFalse(sawLong, "an imported Crafter name longer than 64 characters is dropped")

    local epochP = profile("epoch-keep", admin)
    local epochItem = 100
    assertTrue(select(1, C.AddCrafter(epochP, admin, vann, { asAdmin = true })), "the epoch fixture has a Crafter")
    assertTrue(select(1, C.AddAssignment(epochP, admin, epochItem, vann, { asAdmin = true })), "the epoch fixture assigns the item")
    local firstEpoch = epochP._consumables.assignments[tostring(epochItem)].epoch
    assertTrue(select(1, C.AppendEvent(epochP, {
        id = "ce:epoch-keep:receipt:1", type = C.EVENT.RECEIPT, actor = vann, crafter = vann,
        itemId = epochItem, quantity = 6, generation = 1, epoch = firstEpoch, timestamp = 1,
    }, { silent = true })), "the first assignment has a receipt")
    assertEq(C.ReceiptTotal(epochP, epochItem, vann), 6, "the receipt counts for the first epoch")
    assertTrue(select(1, C.RemoveAssignment(epochP, admin, epochItem, vann, { asAdmin = true })), "removing the item leaves a retired row")
    for i = 1, C.MAX_ASSIGNMENT_HISTORY + 1 do
        local other = 200 + i
        C.AddAssignment(epochP, admin, other, vann, { asAdmin = true })
        C.RemoveAssignment(epochP, admin, other, vann, { asAdmin = true })
    end
    assertEq(epochP._consumables.assignments[tostring(epochItem)], nil, "the retired item is pruned")
    assertTrue(select(1, C.AddAssignment(epochP, admin, epochItem, vann, { asAdmin = true })), "the pruned item can be assigned again")
    local nextEpoch = epochP._consumables.assignments[tostring(epochItem)].epoch
    assertTrue(nextEpoch > firstEpoch, "assigning the pruned item again continues its epoch")
    assertEq(C.ReceiptTotal(epochP, epochItem, vann), 0, "the old receipt does not count toward the new epoch")

    local noted = 0
    local savedWatch = nil
    C.RegisterUIListener(function()
        if savedWatch then noted = noted + 1 end
    end)
    local archiveP = profile("archive-notify", admin)
    archiveP._consumables.generation = 2
    savedWatch = true
    assertEq(select(2, C.AppendEvent(archiveP, {
        id = "ce:archive-notify:1", type = C.EVENT.DONATION, actor = admin, itemId = aqirite,
        quantity = 1, generation = 1, timestamp = 1,
    })), "archived", "an older remote event is archived")
    assertEq(noted, 1, "archiving a remote event refreshes listeners")
    savedWatch = false

    local slotP = profile("empty-slot", admin)
    assertTrue(select(1, C.SetGuild(slotP, admin, { guid = "club-slot", name = "Spectrum", realm = "Realm" }, 2, { asAdmin = true })), "the slot fixture locks a guild")
    assertTrue(select(1, C.AddCrafter(slotP, admin, vann, { asAdmin = true })), "the slot fixture has a Crafter")
    assertTrue(select(1, C.AddAssignment(slotP, admin, aqirite, vann, { asAdmin = true })), "the slot fixture assigns the withdrawn item")
    local savedProfile = RT.Profile
    local savedGuild = RT.CurrentGuild
    local savedScan = RT.ScanBags
    local savedSelf = RT.SelfId
    local savedLink = GetGuildBankItemLink
    local savedInfo = GetGuildBankItemInfo
    local savedNum = GetGuildBankNumSlots
    RT.Profile = function() return slotP end
    RT.CurrentGuild = function() return { guid = "club-slot" } end
    RT.ScanBags = function() end
    RT.SelfId = function() return vann end
    RT.bagCounts = { [aqirite] = 0 }
    RT.withdrawIntents = nil
    RT.withdrawIntent = nil
    GetGuildBankNumSlots = function() return 2 end
    GetGuildBankItemLink = function(_, slot)
        if slot == 1 then return "item:" .. tostring(aqirite) end
        return nil
    end
    GetGuildBankItemInfo = function(_, slot)
        if slot == 1 then return nil, 4 end
        return nil, 0
    end
    RT:CaptureBaseline(true)
    GetGuildBankItemLink = function() return nil end
    GetGuildBankItemInfo = function() return nil, 0 end
    local savedCursor = GetCursorInfo
    GetCursorInfo = function() return "item", aqirite end
    RT.bankBaseline = { [aqirite] = 4 }
    RT:NoteGuildBankPickup(2, 1, false)
    assertEq(RT.withdrawIntents[1].slots and RT.withdrawIntents[1].slots[1].before, 4, "an emptied slot keeps its baseline count")
    slotP._consumables.generation = 2
    GetGuildBankItemLink = function() return "item:" .. tostring(aqirite) end
    GetGuildBankItemInfo = function() return nil, 5 end
    RT:NoteGuildBankPickup(2, 1, false)
    assertEq(#RT.withdrawIntents, 2, "a pickup after the generation changes stays a separate intent")
    RT.Profile = savedProfile
    RT.CurrentGuild = savedGuild
    RT.ScanBags = savedScan
    RT.SelfId = savedSelf
    GetGuildBankItemLink = savedLink
    GetGuildBankItemInfo = savedInfo
    GetGuildBankNumSlots = savedNum
    GetCursorInfo = savedCursor
    RT.withdrawIntents = nil
    RT.withdrawIntent = nil
    RT.bankSlotBaseline = nil

    local savedArchiveCap = C.MAX_ARCHIVED_EVENTS
    local savedActorCap = C.MAX_EVENTS_PER_ACTOR
    C.MAX_ARCHIVED_EVENTS = 3
    C.MAX_EVENTS_PER_ACTOR = 4
    local function archivedDonation(id, qty)
        return {
            id = id, type = C.EVENT.DONATION, actor = admin, writer = admin,
            itemId = aqirite, quantity = qty, generation = 1, timestamp = 1, order = qty,
        }
    end
    local trimP = profile("archive-trim", admin)
    local survivor = profile("archive-survivor", admin)
    trimP._consumables.generation = 2
    survivor._consumables.generation = 2
    local ids = {
        "ce:archive-trim:1",
        "ce:archive-trim:2",
        "ce:archive-trim:3",
        "ce:archive-trim:4",
    }
    for i = 1, 3 do
        assertEq(select(2, C.AppendEvent(trimP, archivedDonation(ids[i], i), { silent = true })), "archived", "the archive cap fixture stores an older event")
        assertEq(select(2, C.AppendEvent(survivor, archivedDonation(ids[i + 1], i + 1), { silent = true })), "archived", "the survivor archive stores the rows that should remain")
    end
    assertEq(select(2, C.AppendEvent(trimP, archivedDonation(ids[4], 4), { silent = true })), "archived", "one more archived event evicts the oldest")
    assertEq(#trimP._consumableEventArchive, 3, "a full archive stays at the cap")
    assertEq(C.EventIndex(trimP)[ids[1]], nil, "the evicted archive id leaves the index")
    assertEq(type(C.EventIndex(trimP)[ids[4]]), "table", "the newest archived event stays indexed")
    assertEq(trimP._consumables.archiveFingerprint, survivor._consumables.archiveFingerprint, "evicting the oldest row leaves the same archive fingerprint as storing only the survivors")
    assertEq(trimP._consumables.archiveCount, 3, "the archive count follows the capped list")
    assertEq(select(2, C.AppendEvent(trimP, archivedDonation("ce:archive-trim:5", 5), { silent = true })), "archived", "evicting the oldest row frees that writer's archive budget")
    C.MAX_ARCHIVED_EVENTS = savedArchiveCap
    C.MAX_EVENTS_PER_ACTOR = savedActorCap
end
checkHeadReviewRound()

function checkCodexHeadRound()
    local savedProfile = RT.AccountingProfile
    local savedScan = RT.ScanBags
    local savedGroup = RT.GroupMap
    local savedCompat = RT.IsCompatible
    local savedRange = RT.IsInRange
    local savedGuild = RT.CurrentGuild
    local savedSelf = RT.SelfId
    local savedLink = GetGuildBankItemLink
    local savedInfo = GetGuildBankItemInfo
    local savedState = Sync.state
    local savedComm = SF.LootHelperComm
    local savedFind = Sync.FindLocalProfileById
    local savedGroupCheck = Sync.IsRequesterInGroup
    local savedSame = Sync._SamePlayer
    local savedSelfSync = Sync._SelfId
    local hooks = {}
    function hooksecurefunc(name, fn)
        hooks[name] = fn
    end
    SplitGuildBankItem = function() end
    RT.frame = nil
    RT.pickupHooked = nil
    RT:Init()
    assertEq(type(hooks.SplitGuildBankItem), "function", "guild bank splits use the same pickup hook")

    local review = RT:EnsureReview()
    local savedShown = review.IsShown
    review.IsShown = function() return false end
    local rebuilds = 0
    local savedRebuild = RT.RebuildReview
    RT.RebuildReview = function(self, ...)
        rebuilds = rebuilds + 1
        return savedRebuild(self, ...)
    end
    local listenP = profile("review-refresh", admin)
    RT.AccountingProfile = function() return listenP end
    RT.ScanBags = function() end
    local savedTimer = C_Timer
    C_Timer = {
        After = function(_, fn) fn() end,
        NewTimer = savedTimer and savedTimer.NewTimer,
        NewTicker = savedTimer and savedTimer.NewTicker,
    }
    assertTrue(select(1, C.AddCrafter(listenP, admin, vann, { asAdmin = true })), "the review refresh fixture has a Crafter")
    review.IsShown = function() return true end
    rebuilds = 0
    assertTrue(select(1, C.AddAssignment(listenP, admin, aqirite, vann, { asAdmin = true })), "the review refresh fixture assigns an item")
    assertTrue(rebuilds >= 1, "a configuration change rebuilds a visible donation review")
    RT.RebuildReview = savedRebuild

    local many = profile("review-rows", admin)
    RT.AccountingProfile = function() return many end
    RT.GroupMap = function() return { [vann] = "raid1" } end
    RT.IsCompatible = function() return true end
    RT.IsInRange = function() return true end
    review.IsShown = function() return false end
    assertTrue(select(1, C.AddCrafter(many, admin, vann, { asAdmin = true })), "the long review has a Crafter")
    RT.bagCounts = {}
    for i = 1, 45 do
        local itemId = 810000 + i
        assertTrue(select(1, C.AddAssignment(many, admin, itemId, vann, { asAdmin = true })), "the long review assigns item " .. tostring(i))
        RT.bagCounts[itemId] = 1
    end
    local acquired = 0
    local savedAcquire = RT.AcquireRow
    RT.AcquireRow = function(self, index)
        if index > acquired then acquired = index end
        return savedAcquire(self, index)
    end
    review.IsShown = function() return true end
    RT:RebuildReview()
    assertTrue(acquired > 40, "a donation review keeps lines past the old 40-row cutoff")
    RT.AcquireRow = savedAcquire
    review.IsShown = savedShown

    local splitP = profile("split-withdraw", admin)
    assertTrue(select(1, C.SetGuild(splitP, admin, { guid = "club-split", name = "Spectrum", realm = "Realm" }, 2, { asAdmin = true })), "the split fixture locks a guild")
    assertTrue(select(1, C.AddCrafter(splitP, admin, vann, { asAdmin = true })), "the split fixture has a Crafter")
    assertTrue(select(1, C.AddAssignment(splitP, admin, aqirite, vann, { asAdmin = true })), "the split fixture assigns the item")
    RT.AccountingProfile = function() return splitP end
    RT.CurrentGuild = function() return { guid = "club-split" } end
    RT.SelfId = function() return vann end
    RT.bagCounts = { [aqirite] = 0 }
    RT.bankBaseline = { [aqirite] = 20 }
    RT.bankBaselineBags = { [aqirite] = 0 }
    RT.bankSlotBaselineTab = 2
    RT.bankSlotBaseline = { [1] = { itemId = aqirite, count = 20 } }
    RT.withdrawIntents = nil
    RT.withdrawIntent = nil
    Sync.state = { active = false }
    GetGuildBankItemLink = function() return "item:" .. tostring(aqirite) end
    GetGuildBankItemInfo = function() return nil, 20 end
    hooks.SplitGuildBankItem(2, 1, 5)
    assertEq(RT.withdrawIntents and RT.withdrawIntents[1] and RT.withdrawIntents[1].intended, 5, "a split withdrawal records the split amount")
    assertEq(RT.withdrawIntents[1].slots and RT.withdrawIntents[1].slots[1].before, 20, "a split withdrawal keeps the pre-split slot count")

    local epochP = profile("epoch-wire", admin)
    local epochItem = 4242
    assertTrue(select(1, C.AddCrafter(epochP, admin, vann, { asAdmin = true })), "the watermark fixture has a Crafter")
    assertTrue(select(1, C.AddAssignment(epochP, admin, epochItem, vann, { asAdmin = true })), "the watermark fixture assigns the item")
    local firstEpoch = epochP._consumables.assignments[tostring(epochItem)].epoch
    assertTrue(select(1, C.RemoveAssignment(epochP, admin, epochItem, vann, { asAdmin = true })), "the watermark fixture retires the item")
    for i = 1, C.MAX_ASSIGNMENT_HISTORY + 1 do
        local other = 4300 + i
        C.AddAssignment(epochP, admin, other, vann, { asAdmin = true })
        C.RemoveAssignment(epochP, admin, other, vann, { asAdmin = true })
    end
    assertEq(epochP._consumables.assignments[tostring(epochItem)], nil, "the watermark fixture prunes the retired item")
    local snap = C.ExportSnapshot(epochP, { omitEvents = true })
    local wired = nil
    for i = 1, #(snap.itemEpochs or {}) do
        if snap.itemEpochs[i].itemId == epochItem then wired = snap.itemEpochs[i].epoch end
    end
    assertTrue(wired and wired >= firstEpoch, "a configuration snapshot includes the pruned item epoch")
    local peer = profile("epoch-peer", admin)
    assertTrue(select(1, C.ReplaceConfig(peer, snap)), "a peer imports the watermark snapshot")
    assertEq(C.Descriptor(peer).configFingerprint, C.Descriptor(epochP).configFingerprint, "imported watermarks keep the configuration fingerprint")
    assertTrue(select(1, C.AddAssignment(peer, admin, epochItem, vann, { asAdmin = true })), "the peer can assign the pruned item")
    assertTrue(peer._consumables.assignments[tostring(epochItem)].epoch > firstEpoch, "the peer does not restart the pruned item at epoch 1")

    load("SpectrumFederation/modules/LootHelperSync/19_Consumables.lua")
    local freezeP = profile("freeze-ack", admin)
    assertTrue(select(1, C.AddCrafter(freezeP, admin, vann, { asAdmin = true })), "the freeze fixture has a Crafter")
    assertTrue(select(1, C.AddAssignment(freezeP, admin, aqirite, vann, { asAdmin = true })), "the freeze fixture assigns an item")
    local opened = C.FreezeTrade(freezeP, donor, vann, { { itemId = aqirite } }, "trade-" .. vann .. "-4-4")
    local sends = 0
    Sync.MSG = Sync.MSG or {}
    Sync.MSG.CONSUMABLES_TRADE_FREEZE = "CONSUMABLES_TRADE_FREEZE"
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = admin,
        coordEpoch = 1,
        sessionId = "freeze-ack",
        profileId = freezeP._profileId,
        peers = { [admin] = { consumablesCapable = true, inGroup = true } },
    }
    Sync._SelfId = function() return donor end
    Sync._SamePlayer = function(_, a, b) return a == b end
    Sync.IsRequesterInGroup = function() return true end
    Sync.FindLocalProfileById = function(_, id)
        if id == freezeP._profileId then return freezeP end
        return nil
    end
    SF.LootHelperComm = {
        Send = function()
            sends = sends + 1
            return true
        end,
    }
    assertTrue(Sync:PublishTradeFreeze(freezeP, opened) == true, "a delivered freeze whisper is accepted")
    assertEq(sends, 1, "the freeze is whispered once")
    Sync:_FlushPendingTradeFreeze(freezeP)
    assertEq(sends, 1, "the same coordinator does not receive that freeze again")
    Sync.state.coordinator = "New-Realm"
    Sync.state.coordEpoch = 2
    Sync.state.peers["New-Realm"] = { consumablesCapable = true, inGroup = true }
    Sync:_FlushPendingTradeFreeze(freezeP)
    assertEq(sends, 2, "a new coordinator receives the unacknowledged freeze")
    local epoch = freezeP._consumables.assignments[tostring(aqirite)].epoch
    Sync:HandleConsumablesTradeFreeze("New-Realm", {
        sessionId = "freeze-ack",
        profileId = freezeP._profileId,
        token = opened.token,
        receiver = vann,
        donor = donor,
        generation = freezeP._consumables.generation,
        items = { { itemId = aqirite, epoch = epoch } },
    })
    Sync:_FlushPendingTradeFreeze(freezeP)
    assertEq(sends, 2, "the coordinator relay retires the pending freeze")

    RT.AccountingProfile = savedProfile
    RT.ScanBags = savedScan
    RT.GroupMap = savedGroup
    RT.IsCompatible = savedCompat
    RT.IsInRange = savedRange
    RT.CurrentGuild = savedGuild
    RT.SelfId = savedSelf
    GetGuildBankItemLink = savedLink
    GetGuildBankItemInfo = savedInfo
    Sync.state = savedState
    SF.LootHelperComm = savedComm
    Sync.FindLocalProfileById = savedFind
    Sync.IsRequesterInGroup = savedGroupCheck
    Sync._SamePlayer = savedSame
    Sync._SelfId = savedSelfSync
    RT.withdrawIntents = nil
    RT.withdrawIntent = nil
    C_Timer = savedTimer
end
checkCodexHeadRound()

function checkA839ReviewRound()
    local savedCap = C.MAX_ARCHIVED_EVENTS
    local savedState = Sync.state
    local savedGet = SF.GetActiveProfile
    local savedDb = SF.lootHelperDB
    local savedFind = Sync.FindLocalProfileById
    local savedTimer = C_Timer
    local savedCombat = InCombatLockdown
    local savedProfile = RT.AccountingProfile
    local savedScan = RT.ScanBags
    local savedRebuild = RT.RebuildReview
    local savedComm = SF.LootHelperComm
    local savedSame = Sync._SamePlayer
    local savedSelfSync = Sync._SelfId
    local savedGroup = Sync.IsRequesterInGroup
    local savedEnforce = Sync._EnforceGroupedSessionActive
    C_Timer = {
        After = function(_, fn) fn() end,
        NewTimer = savedTimer and savedTimer.NewTimer,
        NewTicker = savedTimer and savedTimer.NewTicker,
    }

    C.MAX_ARCHIVED_EVENTS = 2
    local arch = profile("archive-repair", admin)
    arch._consumables.generation = 2
    local idA = "ce:repair:keep:1"
    local idL = "ce:repair:local:1"
    local idM = "ce:repair:missing:1"
    local function archived(id, order)
        return {
            id = id, type = C.EVENT.DONATION, actor = admin, itemId = aqirite,
            quantity = 1, generation = 1, timestamp = 1, order = order,
        }
    end
    assertTrue(select(1, C.AppendEvent(arch, archived(idA, 1), { silent = true })), "the kept archive row is stored")
    assertTrue(select(1, C.AppendEvent(arch, archived(idL, 2), { silent = true })), "the local-only archive row is stored")
    assertEq(arch._consumableEventArchive[1].id, idA, "the authoritative row starts at the front of a full archive")
    Sync.state = { active = true, coordEpoch = 4, sessionId = "repair", coordinator = "Coord-Realm", profileId = arch._profileId }
    assertTrue(C.MergeSnapshot(arch, {
        generation = 2, configSeq = 1, crafters = {}, assignments = {},
        events = { archived(idA, 1), archived(idM, 3) },
    }, { consumablesFromCoordinator = true }), "the full-archive coordinator snapshot is applied")
    assertTrue(hasEvent(arch._consumableEventArchive, idA), "a full archive keeps the authoritative row")
    assertTrue(hasEvent(arch._consumableEventArchive, idM), "a full archive stores the missing authoritative row")
    assertFalse(hasEvent(arch._consumableEventArchive, idL), "a full archive drops the row the snapshot does not contain")
    assertTrue(#arch._consumableEventArchive <= 2, "the archive cap still holds")
    C.MAX_ARCHIVED_EVENTS = savedCap

    local stamped = profile("epoch-replace", admin)
    stamped._consumables.itemEpochs = { ["999"] = 4, ["4242"] = 1 }
    assertTrue(select(1, C.ReplaceConfig(stamped, {
        generation = 1, configSeq = 1, crafters = {}, assignments = {},
        itemEpochs = { { itemId = 4242, epoch = 2 } },
    })), "an authoritative watermark array is imported")
    assertEq(stamped._consumables.itemEpochs["999"], nil, "a local-only watermark is removed")
    assertEq(stamped._consumables.itemEpochs["4242"], 2, "the snapshot watermark replaces the lower local epoch")
    local keptEpochs = profile("epoch-omit", admin)
    keptEpochs._consumables.itemEpochs = { ["999"] = 4 }
    assertTrue(select(1, C.ReplaceConfig(keptEpochs, {
        generation = 1, configSeq = 1, crafters = {}, assignments = {},
    })), "a snapshot without the watermark field is imported")
    assertEq(keptEpochs._consumables.itemEpochs["999"], 4, "a missing watermark field keeps stored watermarks")

    local review = RT:EnsureReview()
    local savedShown = review.IsShown
    local queued = {}
    local rebuilds = 0
    C_Timer = {
        After = function(_, fn) queued[#queued + 1] = fn end,
        NewTimer = savedTimer and savedTimer.NewTimer,
        NewTicker = savedTimer and savedTimer.NewTicker,
    }
    RT.RebuildReview = function(self, ...)
        rebuilds = rebuilds + 1
        return savedRebuild(self, ...)
    end
    RT.ScanBags = function() end
    local burst = profile("review-burst", admin)
    RT.AccountingProfile = function() return burst end
    review.IsShown = function() return true end
    for i = 1, 3 do
        assertTrue(select(1, C.AppendEvent(burst, {
            id = "ce:burst:" .. tostring(i),
            type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1,
            generation = 1, timestamp = i,
        })), "burst event " .. tostring(i) .. " is stored")
    end
    assertEq(#queued, 1, "a burst of ledger updates schedules one review refresh")
    queued[1]()
    assertEq(rebuilds, 1, "that refresh rebuilds the visible review once")
    InCombatLockdown = function() return true end
    local queuedBefore = #queued
    assertTrue(select(1, C.AppendEvent(burst, {
        id = "ce:burst:combat",
        type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1,
        generation = 1, timestamp = 4,
    })), "a combat ledger event is stored")
    assertEq(#queued, queuedBefore, "combat does not schedule another review refresh")
    assertEq(RT.reviewRefreshPending, true, "combat defers the review refresh")
    InCombatLockdown = savedCombat
    review.IsShown = savedShown

    RT.AccountingProfile = savedProfile
    local visible = profile("visible-wait", admin)
    SF.GetActiveProfile = function() return visible end
    SF.lootHelperDB = { profiles = {} }
    Sync.FindLocalProfileById = function() return nil end
    Sync.state = { active = true, profileId = "missing-session", sessionId = "wait" }
    assertEq(RT:AccountingProfile(), nil, "accounting waits until the session profile is loaded")
    visible._profileId = "missing-session"
    assertTrue(RT:AccountingProfile() == visible, "accounting uses the active profile when it is the session profile")

    load("SpectrumFederation/modules/LootHelperSync/19_Consumables.lua")
    local freezeP = profile("freeze-takeover", admin)
    assertTrue(select(1, C.AddCrafter(freezeP, admin, vann, { asAdmin = true })), "the takeover freeze has a Crafter")
    assertTrue(select(1, C.AddAssignment(freezeP, admin, aqirite, vann, { asAdmin = true })), "the takeover freeze assigns an item")
    local epoch = freezeP._consumables.assignments[tostring(aqirite)].epoch
    local opened = C.FreezeTrade(freezeP, donor, vann, { { itemId = aqirite } }, "trade-" .. vann .. "-9-9")
    local sends = 0
    Sync.MSG = Sync.MSG or {}
    Sync.MSG.CONSUMABLES_TRADE_FREEZE = "CONSUMABLES_TRADE_FREEZE"
    Sync.state = {
        active = true, isCoordinator = false, coordinator = admin, coordEpoch = 1,
        sessionId = "freeze-takeover", profileId = freezeP._profileId,
        peers = { [admin] = { consumablesCapable = true, inGroup = true } },
    }
    Sync._SelfId = function() return donor end
    Sync._SamePlayer = function(_, a, b) return a == b end
    Sync.IsRequesterInGroup = function() return true end
    Sync.FindLocalProfileById = function(_, id)
        if id == freezeP._profileId then return freezeP end
        return nil
    end
    Sync._EnforceGroupedSessionActive = function() return "RAID" end
    SF.LootHelperComm = { Send = function() sends = sends + 1 return true end }
    assertTrue(Sync:PublishTradeFreeze(freezeP, opened) == true, "the takeover fixture whispers the freeze")
    assertTrue(select(1, C.RemoveAssignment(freezeP, admin, aqirite, vann, { asAdmin = true })), "the assignment changes before takeover")
    local wire = S.TradeFreezePayload(opened)
    assertFalse(S.RegisterTradeGrant(freezeP, wire, C.Now()), "a new whisper still requires the live assignment")
    Sync.state.isCoordinator = true
    Sync.state.coordinator = donor
    Sync.state.coordEpoch = 2
    Sync:_FlushPendingTradeFreeze(freezeP)
    assertTrue(sends >= 1, "takeover rebroadcasts the captured freeze")
    assertTrue(S.TradeGrantMatches(freezeP, {
        tradeToken = opened.token,
        id = opened.token .. ":donation",
        type = C.EVENT.DONATION,
        source = "trade",
        actor = donor,
        crafter = vann,
        generation = freezeP._consumables.generation,
        itemId = aqirite,
        epoch = epoch,
    }, vann, C.Now()), "takeover keeps the captured trade grant")

    C.MAX_ARCHIVED_EVENTS = savedCap
    Sync.state = savedState
    SF.GetActiveProfile = savedGet
    SF.lootHelperDB = savedDb
    Sync.FindLocalProfileById = savedFind
    C_Timer = savedTimer
    InCombatLockdown = savedCombat
    RT.AccountingProfile = savedProfile
    RT.ScanBags = savedScan
    RT.RebuildReview = savedRebuild
    SF.LootHelperComm = savedComm
    Sync._SamePlayer = savedSame
    Sync._SelfId = savedSelfSync
    Sync.IsRequesterInGroup = savedGroup
    Sync._EnforceGroupedSessionActive = savedEnforce
    RT.reviewRefreshPending = nil
end
checkA839ReviewRound()

function checkWriterFingerprint()
    local savedState = Sync.state
    local savedComm = SF.LootHelperComm
    local savedEnforce = Sync._EnforceGroupedSessionActive
    local savedSelf = Sync._SelfId
    local savedSafe = Sync.IsSafeModeEnabled
    local messages = {}
    Sync.MSG = Sync.MSG or {}
    Sync.MSG.CONSUMABLES_EVENT = "CONSUMABLES_EVENT"
    Sync.MSG.CONSUMABLES_CONFIG = "CONSUMABLES_CONFIG"
    Sync.IsSafeModeEnabled = function() return false end
    Sync._EnforceGroupedSessionActive = function() return "RAID" end
    Sync._SelfId = function() return admin end
    local coord = profile("writer-fp", admin)
    Sync.state = {
        active = true,
        isCoordinator = true,
        coordinator = admin,
        sessionId = "writer-fp",
        profileId = coord._profileId,
    }
    SF.LootHelperComm = {
        Send = function(_, _, msg, payload)
            messages[#messages + 1] = { msg = msg, event = payload and payload.event }
            return true
        end,
    }
    assertTrue(select(1, Sync:CommitConsumablesOp(coord, { name = "clear" }, admin, { asAdmin = true })), "the writer fixture clears")
    local reset = nil
    for i = 1, #messages do
        if messages[i].msg == "CONSUMABLES_EVENT" then reset = messages[i].event end
    end
    assertEq(reset and reset.writer, admin, "the broadcast reset names the writer")
    local follow = profile("writer-fp-follow", admin)
    follow._consumables.generation = 2
    assertTrue(select(1, S.ApplyRemoteEvent(follow, reset, admin, {
        coordinatorRelay = true,
        silent = true,
    })), "the follower stores the broadcast reset")
    assertEq(C.Descriptor(coord).archiveFingerprint, C.Descriptor(follow).archiveFingerprint, "the archived reset fingerprint includes the writer")

    local live = profile("writer-fp-live", admin)
    local id = "ce:writer-live:" .. admin .. ":1"
    assertTrue(select(1, C.AppendEvent(live, {
        id = id, type = C.EVENT.RESOLVE, actor = admin, holder = donor, itemId = aqirite,
        quantity = 1, reason = "Other", generation = 1, timestamp = 1,
    }, { silent = true })), "a resolve is stored without a writer")
    local stored = C.EventIndex(live)[id]
    C.StampOrder(live, stored)
    assertTrue(C.NoteStoredWriter(live, stored, admin), "the resolve writer is stored after the stamp")
    local peer = profile("writer-fp-live-peer", admin)
    assertTrue(select(1, C.AppendEvent(peer, {
        id = id, type = C.EVENT.RESOLVE, actor = admin, holder = donor, itemId = aqirite,
        quantity = 1, reason = "Other", generation = 1, timestamp = 1,
        writer = admin, order = stored.order,
    }, { silent = true })), "the peer stores the same resolve with its writer")
    assertEq(C.Descriptor(live).eventFingerprint, C.Descriptor(peer).eventFingerprint, "the live resolve fingerprint includes the writer")

    Sync.state = savedState
    SF.LootHelperComm = savedComm
    Sync._EnforceGroupedSessionActive = savedEnforce
    Sync._SelfId = savedSelf
    Sync.IsSafeModeEnabled = savedSafe
end
checkWriterFingerprint()

function checkSnapshotServeLimit()
    load("SpectrumFederation/modules/LootHelperSync/07_Validation.lua")
    load("SpectrumFederation/modules/LootHelperSync/14_HandlersControl.lua")
    local savedState = Sync.state
    local savedNow = Sync._Now
    local savedBuild = Sync.BuildProfileSnapshot
    local savedValidate = Sync.ValidateSessionPayload
    local savedReply = Sync._RecordHandshakeReply
    local savedIntegrity = Sync._HandlePeerIntegrityAdvertisement
    local savedBulk = Sync.IsBulkTransferAllowed
    local savedHelper = Sync.IsSelfHelper
    local savedAuth = Sync.IsSenderAuthorized
    local savedRoster = Sync.UpdatePeersFromRoster
    local savedPeer = Sync.GetPeer
    local savedSelf = Sync._SelfId
    local savedJitter = Sync.RunWithJitter
    local savedCfg = Sync.cfg
    local now = 5000
    local builds = 0
    Sync.cfg = { requestTimeoutSec = 5 }
    Sync._Now = function() return now end
    Sync._SelfId = function() return admin end
    Sync.ValidateSessionPayload = function() return true end
    Sync._RecordHandshakeReply = function() end
    Sync._HandlePeerIntegrityAdvertisement = function() end
    Sync.IsBulkTransferAllowed = function() return true end
    Sync.IsSelfHelper = function() return false end
    Sync.IsSenderAuthorized = function() return true end
    Sync.UpdatePeersFromRoster = function() end
    Sync.GetPeer = function() return { inGroup = true } end
    Sync.RunWithJitter = function() end
    Sync.BuildProfileSnapshot = function()
        builds = builds + 1
        return { snapshot = {} }
    end
    Sync.state = {
        active = true,
        isCoordinator = true,
        sessionId = "snap-serve",
        profileId = "snap-serve-profile",
        _profileSnapshotServe = nil,
    }
    local payload = { sessionId = "snap-serve", profileId = "snap-serve-profile", requestId = "req-1" }
    Sync:HandleNeedProfile("Member-Realm", payload)
    Sync:HandleNeedProfile("Member-Realm", payload)
    assertEq(builds, 1, "a second profile request does not copy the snapshot inside the timeout")
    now = 5004
    Sync:HandleNeedProfile("Member-Realm", { sessionId = "snap-serve", profileId = "snap-serve-profile", requestId = "req-2" })
    assertEq(builds, 1, "the snapshot serve stays closed until the request timeout elapses")
    now = 5005
    Sync:HandleNeedProfile("Member-Realm", { sessionId = "snap-serve", profileId = "snap-serve-profile", requestId = "req-3" })
    assertEq(builds, 2, "a later profile request can copy the snapshot after the timeout")
    local book = {}
    for i = 1, 64 do
        book["Peer-" .. tostring(i)] = now
    end
    Sync.state._profileSnapshotServe = book
    Sync:HandleNeedProfile("New-Realm", { sessionId = "snap-serve", profileId = "snap-serve-profile", requestId = "req-full" })
    assertEq(builds, 2, "a full recent serve book does not copy another snapshot")
    Sync.state = savedState
    Sync._Now = savedNow
    Sync.BuildProfileSnapshot = savedBuild
    Sync.ValidateSessionPayload = savedValidate
    Sync._RecordHandshakeReply = savedReply
    Sync._HandlePeerIntegrityAdvertisement = savedIntegrity
    Sync.IsBulkTransferAllowed = savedBulk
    Sync.IsSelfHelper = savedHelper
    Sync.IsSenderAuthorized = savedAuth
    Sync.UpdatePeersFromRoster = savedRoster
    Sync.GetPeer = savedPeer
    Sync._SelfId = savedSelf
    Sync.RunWithJitter = savedJitter
    Sync.cfg = savedCfg
end
checkSnapshotServeLimit()

function checkCodexSnapshotRound()
    local savedCollect = RT.Collect
    local savedShow = RT.ShowReview
    local savedCrafter = C.IsCrafter
    local savedPath = R.HasActionablePath
    local savedRemind = RT.RemindersEnabled
    local shown = false
    local collects = 0
    RT.autoReviewedThisOpen = false
    RT.RemindersEnabled = function() return true end
    RT.ShowReview = function() shown = true end
    C.IsCrafter = function() return false end
    R.HasActionablePath = function() return true end
    RT.Collect = function()
        collects = collects + 1
        if collects == 1 then return nil end
        return { profile = {}, plan = { lines = { { quantity = 1 } } }, usable = true }
    end
    RT:MaybeAutoReview()
    assertFalse(RT.autoReviewedThisOpen, "a bank visit stays unreviewed until a profile can be evaluated")
    assertFalse(shown, "the review stays closed while the session profile is missing")
    RT:MaybeAutoReview()
    assertTrue(RT.autoReviewedThisOpen, "the visit is reviewed once a profile can be evaluated")
    assertTrue(shown, "the automatic review opens after the session profile arrives")
    RT.Collect = savedCollect
    RT.ShowReview = savedShow
    C.IsCrafter = savedCrafter
    R.HasActionablePath = savedPath
    RT.RemindersEnabled = savedRemind
    RT.autoReviewedThisOpen = false

    local open = { both = false, target = {} }
    RT.openTrade = open
    local savedLink = GetTradeTargetItemLink
    local savedInfo = GetTradeTargetItemInfo
    local savedAcceptTimer = C_Timer
    local acceptQueued = {}
    C_Timer = {
        After = function(_, fn) acceptQueued[#acceptQueued + 1] = fn end,
        NewTimer = savedAcceptTimer and savedAcceptTimer.NewTimer,
    }
    GetTradeTargetItemLink = function(slot)
        if slot == 1 then return "item:" .. tostring(aqirite) end
        return nil
    end
    GetTradeTargetItemInfo = function(slot)
        if slot == 1 then return nil, nil, 4 end
        return nil, nil, 0
    end
    RT:OnTradeAccept(1, 1)
    assertTrue(open.both, "both sides accepting captures the trade")
    assertEq(open.target[aqirite], 4, "the first acceptance records the offered quantity")
    RT:OnTradeAccept(0, 0)
    assertTrue(open.both, "a completion reset keeps the accepted trade")
    assertEq(open.target[aqirite], 4, "a completion reset keeps the captured offer")
    local savedCommit = RT.Commit
    local savedById = RT.ProfileById
    local commits = 0
    RT.Commit = function() commits = commits + 1 end
    RT.ProfileById = function() return {} end
    open.role = "receiver"
    open.frozen = {
        items = { [aqirite] = { assignedToReceiver = true, epoch = 1, custodyQty = 0 } },
        generation = 1,
        token = "trade-close",
        donor = admin,
        receiver = vann,
        timestamp = 1,
    }
    RT:OnTradeClosed()
    assertEq(commits, 1, "closing before the reset frame still records the accepted trade")
    assertEq(#acceptQueued, 1, "the completion reset was deferred one frame")
    acceptQueued[1]()
    open = { both = false, target = {} }
    RT.openTrade = open
    acceptQueued = {}
    RT:OnTradeAccept(1, 1)
    assertEq(open.target[aqirite], 4, "a new trade can capture an offer again")
    RT:OnTradeAccept(1, 0)
    assertTrue(open.both, "an acceptance reset keeps the offer until the trade stays open")
    assertEq(#acceptQueued, 1, "an acceptance reset is checked on the next frame")
    acceptQueued[1]()
    assertFalse(open.both, "a reset that leaves the trade open forgets that both sides accepted")
    assertEq(open.target[aqirite], nil, "that reset drops the captured offer")
    GetTradeTargetItemInfo = function(slot)
        if slot == 1 then return nil, nil, 2 end
        return nil, nil, 0
    end
    RT:OnTradeAccept(1, 1)
    assertTrue(open.both, "the next acceptance can capture the trade again")
    assertEq(open.target[aqirite], 2, "the next acceptance records the new quantity")
    RT.openTrade = nil
    RT.Commit = savedCommit
    RT.ProfileById = savedById
    C_Timer = savedAcceptTimer
    GetTradeTargetItemLink = savedLink
    GetTradeTargetItemInfo = savedInfo

    local savedLedger = C.MAX_LEDGER_EVENTS
    C.MAX_LEDGER_EVENTS = 1
    local fullP = profile("full-same-gen", admin)
    local extraId = "ce:full-extra:other:1"
    local missingId = "ce:full-missing:other:1"
    assertTrue(select(1, C.AppendEvent(fullP, {
        id = extraId, type = C.EVENT.DONATION, actor = "Other-Realm", writer = "Other-Realm",
        itemId = aqirite, quantity = 1, generation = 1, timestamp = 1, order = 1,
    }, { silent = true })), "the full ledger holds one local extra")
    assertTrue(C.MergeSnapshot(fullP, {
        generation = 1, configSeq = fullP._consumables.configSeq, crafters = {}, assignments = {},
        events = {
            { id = missingId, type = C.EVENT.DONATION, actor = "Other-Realm", writer = "Other-Realm",
              itemId = aqirite, quantity = 1, generation = 1, timestamp = 2, order = 2 },
        },
    }, { consumablesFromCoordinator = true }), "the same-generation snapshot is applied")
    assertTrue(hasEvent(fullP._consumableEvents, missingId), "reconciliation makes room for the missing authoritative row")
    assertFalse(hasEvent(fullP._consumableEvents, extraId), "the local extra is not kept after reconciliation")
    C.MAX_LEDGER_EVENTS = savedLedger

    local epochP = profile("epoch-import", admin)
    C.ReplaceConfig(epochP, {
        generation = 1,
        configSeq = 1,
        assignments = {
            ["10"] = { itemId = aqirite, epoch = 0, crafters = { vann } },
            ["11"] = { itemId = 4242, epoch = 1.5, crafters = { vann } },
            ["12"] = { itemId = 4243, epoch = 2, crafters = { vann } },
        },
    })
    assertTrue(epochP._consumables.assignments[tostring(aqirite)] == nil, "a zero assignment epoch is not stored")
    assertTrue(epochP._consumables.assignments["4242"] == nil, "a fractional assignment epoch is not stored")
    assertEq(epochP._consumables.assignments["4243"].epoch, 2, "a positive whole assignment epoch is stored")

    local savedClock = C._clock
    local now = 2000
    C._clock = function() return now end
    local freezeP = profile("freeze-unsent", admin)
    local savedState = Sync.state
    local savedComm = SF.LootHelperComm
    local sends = 0
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = nil,
        sessionId = "freeze-session",
        profileId = freezeP._profileId,
    }
    SF.LootHelperComm = { Send = function() sends = sends + 1 return true end }
    Sync.MSG = Sync.MSG or {}
    Sync.MSG.CONSUMABLES_TRADE_FREEZE = "CONSUMABLES_TRADE_FREEZE"
    local published = Sync:PublishTradeFreeze(freezeP, {
        token = "trade-" .. vann .. "-1",
        donor = admin,
        receiver = vann,
        generation = 1,
        items = { [aqirite] = { itemId = aqirite, epoch = 1, assignedToReceiver = true } },
    })
    assertFalse(published, "a freeze without a coordinator is not sent")
    now = 2120
    Sync.state.coordinator = "Coord-Realm"
    Sync.state.peers = { ["Coord-Realm"] = { consumablesCapable = true } }
    Sync:_FlushPendingTradeFreeze(freezeP)
    assertEq(sends, 0, "a freeze that was never sent expires from the time it was captured")
    C._clock = savedClock
    Sync.state = savedState
    SF.LootHelperComm = savedComm

    local archiveP = profile("archive-resend", admin)
    local archivedId = "ce:archive-resend:" .. admin .. ":1"
    archiveP._consumableEventArchive = {
        { id = archivedId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
          quantity = 1, generation = 1, timestamp = 1, order = 4 },
    }
    C.InvalidateEventIndex(archiveP)
    local localArchive = C.Descriptor(archiveP).archiveFingerprint
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = "Coord-Realm",
        sessionId = "archive-resend",
        profileId = archiveP._profileId,
        peers = { ["Coord-Realm"] = { consumablesCapable = true } },
    }
    Sync.FindLocalProfileById = function() return archiveP end
    local savedSafe = Sync.IsSafeModeEnabled
    local savedRequest = Sync.RequestProfileSnapshot
    Sync.IsSafeModeEnabled = function() return true end
    Sync.RequestProfileSnapshot = function() return false end
    Sync:_ConsiderConsumablesCatchUp({
        coordinator = "Coord-Realm",
        profileId = archiveP._profileId,
        sessionId = "archive-resend",
        consumablesGeneration = 1,
        consumablesConfigSeq = archiveP._consumables.configSeq,
        consumablesEventCount = 0,
        consumablesEventFingerprint = C.Descriptor(archiveP).eventFingerprint,
        consumablesArchiveCount = 0,
        consumablesArchiveFingerprint = (tonumber(localArchive) or 0) + 1,
    })
    local queuedArchive = false
    for i = 1, #(archiveP._consumablesUnsent or {}) do
        if archiveP._consumablesUnsent[i] == archivedId then queuedArchive = true end
    end
    assertTrue(queuedArchive, "an archive mismatch queues this client's stamped archived event")
    Sync.IsSafeModeEnabled = savedSafe
    Sync.RequestProfileSnapshot = savedRequest

    local pruneP = profile("unsent-cap", admin)
    local keptId = "ce:unsent-cap:" .. admin .. ":1"
    assertTrue(select(1, C.AppendEvent(pruneP, {
        id = keptId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 1, generation = 1, timestamp = 1,
    }, { silent = true })), "the prune fixture stores one event")
    local cap = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
    local huge = {}
    for i = 1, cap + 10 do
        huge[i] = "missing-" .. tostring(i)
    end
    huge[#huge] = keptId
    pruneP._consumablesUnsent = huge
    Sync:_PruneUnsentConsumablesEvents(pruneP)
    assertTrue(#pruneP._consumablesUnsent <= cap, "the unsent queue is cut down to the ledger plus archive cap")
    local keptQueued = false
    local staleQueued = false
    for i = 1, #pruneP._consumablesUnsent do
        if pruneP._consumablesUnsent[i] == keptId then keptQueued = true end
        if pruneP._consumablesUnsent[i] == "missing-1" then staleQueued = true end
    end
    assertTrue(keptQueued, "a stored event id is kept in the unsent queue")
    assertFalse(staleQueued, "an id that is no longer stored is removed from the unsent queue")
    Sync.state = savedState
    Sync.FindLocalProfileById = nil
end
checkCodexSnapshotRound()

function checkReviewHeadRound()
    local savedState = Sync.state
    local genP = profile("bad-gen", admin)
    local keptId = "ce:bad-gen:" .. admin .. ":1"
    assertTrue(select(1, C.AppendEvent(genP, {
        id = keptId, type = C.EVENT.DONATION, actor = admin, writer = admin,
        itemId = aqirite, quantity = 1, generation = 1, timestamp = 1, order = 1,
    }, { silent = true })), "the generation fixture stores a current event")
    Sync.state = { active = true, isCoordinator = false, coordEpoch = 1 }
    assertTrue(C.MergeSnapshot(genP, {
        generation = 1.5,
        configSeq = genP._consumables.configSeq,
        crafters = {},
        assignments = {},
    }, { consumablesFromCoordinator = true }), "a fractional generation snapshot is applied")
    assertEq(genP._consumables.generation, 1, "a fractional snapshot generation is not stored")
    assertTrue(hasEvent(genP._consumableEvents, keptId), "a fractional generation does not archive the current ledger")
    assertTrue(select(1, C.ReplaceConfig(genP, {
        generation = 0, configSeq = 1, crafters = {}, assignments = {},
    })), "generation zero is still a config payload")
    assertEq(genP._consumables.generation, 1, "generation zero is not stored")
    assertTrue(select(1, C.ReplaceConfig(genP, {
        generation = 2, configSeq = 1, crafters = {}, assignments = {},
    })), "a whole generation is a config payload")
    assertEq(genP._consumables.generation, 2, "a positive whole generation is stored")
    local rejected = S.ApplyRemoteConfig(genP, { generation = -3, configSeq = 2 }, admin, { coordinatorAuthoritative = true })
    assertFalse(rejected, "a negative coordinator generation is rejected")
    assertEq(genP._consumables.generation, 2, "a rejected generation leaves the stored generation")

    local longName = string.rep("A", 80) .. "-Realm"
    local historyNames = {}
    for i = 1, 3 do
        historyNames[i] = "Crafter" .. tostring(i) .. "-Realm"
    end
    historyNames[#historyNames + 1] = longName
    assertTrue(select(1, C.ReplaceConfig(genP, {
        generation = 2,
        configSeq = 2,
        assignments = {
            ["10"] = {
                itemId = aqirite,
                epoch = 2,
                crafters = { vann },
                history = { { epoch = 1, crafters = historyNames } },
            },
        },
    })), "assignment history is imported")
    local imported = genP._consumables.assignments[tostring(aqirite)]
    local sawLong = false
    local sawShort = false
    local prior = imported and imported.history and imported.history[1]
    if prior and type(prior.crafters) == "table" then
        for i = 1, #prior.crafters do
            if prior.crafters[i] == longName then sawLong = true end
            if prior.crafters[i] == historyNames[1] then sawShort = true end
        end
    end
    assertFalse(sawLong, "a history name past the name limit is not stored")
    assertTrue(sawShort, "a history name within the name limit is stored")

    local archiveP = profile("archive-again", admin)
    local firstId = "ce:archive-again:" .. admin .. ":1"
    local secondId = "ce:archive-again:" .. admin .. ":2"
    archiveP._consumableEventArchive = {
        { id = firstId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
          quantity = 1, generation = 1, timestamp = 1, order = 4 },
    }
    C.InvalidateEventIndex(archiveP)
    local firstFp = C.Descriptor(archiveP).archiveFingerprint
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = "Coord-Realm",
        sessionId = "archive-again",
        profileId = archiveP._profileId,
        peers = { ["Coord-Realm"] = { consumablesCapable = true } },
    }
    Sync.FindLocalProfileById = function() return archiveP end
    local savedSafe = Sync.IsSafeModeEnabled
    local savedRequest = Sync.RequestProfileSnapshot
    Sync.IsSafeModeEnabled = function() return true end
    Sync.RequestProfileSnapshot = function() return false end
    local function catchUp(count, fingerprint)
        Sync:_ConsiderConsumablesCatchUp({
            coordinator = "Coord-Realm",
            profileId = archiveP._profileId,
            sessionId = "archive-again",
            consumablesGeneration = 1,
            consumablesConfigSeq = archiveP._consumables.configSeq,
            consumablesEventCount = 0,
            consumablesEventFingerprint = C.Descriptor(archiveP).eventFingerprint,
            consumablesArchiveCount = count,
            consumablesArchiveFingerprint = fingerprint,
        })
    end
    catchUp(0, (tonumber(firstFp) or 0) + 1)
    archiveP._consumableEventArchive[#archiveP._consumableEventArchive + 1] = {
        id = secondId, type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 2, generation = 1, timestamp = 2, order = 5,
    }
    C.InvalidateEventIndex(archiveP)
    local secondFp = C.Descriptor(archiveP).archiveFingerprint
    catchUp(0, (tonumber(secondFp) or 0) + 1)
    local sawFirst, sawSecond = false, false
    for i = 1, #(archiveP._consumablesUnsent or {}) do
        if archiveP._consumablesUnsent[i] == firstId then sawFirst = true end
        if archiveP._consumablesUnsent[i] == secondId then sawSecond = true end
    end
    assertTrue(sawFirst, "the first archive mismatch queues the stamped event")
    assertTrue(sawSecond, "a later archive fingerprint queues the new stamped event")
    Sync.IsSafeModeEnabled = savedSafe
    Sync.RequestProfileSnapshot = savedRequest
    Sync.FindLocalProfileById = nil
    Sync.state = savedState

    local refreshes = 0
    local queued = {}
    local savedTimer = C_Timer
    local savedSettings = SF.SettingsUI
    local savedProfile = SF.GetActiveProfile
    C_Timer = { After = function(_, fn) queued[#queued + 1] = fn end }
    SF.GetActiveProfile = function() return genP end
    local page
    SF.SettingsUI = {
        RegisterPage = function(_, registered) page = registered end,
        DefinitionRenderer = {
            Build = function() end,
            Refresh = function() refreshes = refreshes + 1 end,
        },
    }
    load("SpectrumFederation/modules/UI/Settings/Pages/RaidConsumableLogs.lua")
    local panel = { IsShown = function() return true end }
    page:Build(panel)
    local before = #queued
    assertTrue(select(1, C.AppendEvent(genP, {
        id = "ce:log-refresh:" .. admin .. ":1",
        type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 1, generation = genP._consumables.generation, timestamp = 3,
    }, { silent = false })), "a log event notifies the visible log")
    assertTrue(select(1, C.AppendEvent(genP, {
        id = "ce:log-refresh:" .. admin .. ":2",
        type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 1, generation = genP._consumables.generation, timestamp = 4,
    }, { silent = false })), "a second log event arrives before the refresh")
    assertEq(#queued - before, 1, "two log events schedule one refresh")
    queued[#queued]()
    assertTrue(refreshes >= 1, "the deferred log refresh sorts once")
    C_Timer = savedTimer
    SF.SettingsUI = savedSettings
    SF.GetActiveProfile = savedProfile
end
checkReviewHeadRound()

function checkTradeRangeAndAnnounce()
    local seenRange = nil
    C.RevalidateDonation = function(_, line, ctx)
        seenRange = ctx and ctx.inRange and ctx.inRange[line.recipient]
        return true
    end
    RT.RecipientInRange = function() return true end
    RT.GroupUnit = function() return "raid1" end
    local started = false
    InitiateTrade = function()
        started = true
    end
    local collected = { inRange = { ["Crafter-Realm"] = false }, profile = {} }
    RT:BeginTrade({ itemId = aqirite, quantity = 1, recipient = "Crafter-Realm" }, collected)
    assertEq(seenRange, true, "a trade click revalidates the Crafter's current range")
    assertEq(collected.inRange["Crafter-Realm"], true, "the captured review range is updated before revalidation")
    assertTrue(started, "a Crafter who is in range now can be traded with")

    local order = {}
    local savedState = Sync.state
    local savedFind = Sync.FindLocalProfileById
    local savedEnforce = Sync._EnforceGroupedSessionActive
    local savedComm = SF.LootHelperComm
    local savedBroadcast = Sync.BroadcastConsumablesConfig
    local savedFlush = Sync._FlushUnsentConsumablesEvents
    load("SpectrumFederation/modules/LootHelperSync/09_AdminConvergence.lua")
    load("SpectrumFederation/modules/LootHelperSync/18_PublicAPI.lua")
    local announced = profile("announce-cfg", admin)
    Sync.state = {
        active = true,
        isCoordinator = true,
        sessionId = "announce-session",
        profileId = announced._profileId,
        coordinator = admin,
        coordEpoch = 1,
        helpers = {},
    }
    Sync.cfg = Sync.cfg or {}
    Sync.MSG = Sync.MSG or {}
    Sync.MSG.SES_START = Sync.MSG.SES_START or "SES_START"
    Sync.MSG.SES_REANNOUNCE = Sync.MSG.SES_REANNOUNCE or "SES_REANNOUNCE"
    Sync._EnforceGroupedSessionActive = function() return "RAID" end
    Sync.FindLocalProfileById = function() return announced end
    Sync._RefreshAdvertisedAuthorMax = function() end
    Sync.ComputeAuthorWindowSummary = function() return {} end
    Sync._RefreshOutstandingRequestTargets = function() end
    Sync._GetSessionSafeModePayload = function() return nil end
    Sync._MarkRosterAnnounced = function() end
    Sync._PersistSessionState = function() end
    Sync.EnsureHeartbeatSender = function() end
    Sync.RunAfter = function() end
    Sync.IsSessionSafeModeEnabled = function() return false end
    Sync._Now = function() return 10 end
    Sync._SelfId = function() return admin end
    Sync.IsSenderAuthorized = function() return true end
    Sync.BroadcastConsumablesConfig = function()
        order[#order + 1] = "config"
    end
    Sync._FlushUnsentConsumablesEvents = function()
        order[#order + 1] = "flush"
    end
    SF.LootHelperComm = {
        Send = function() return true end,
    }
    Sync:BroadcastSessionStart()
    assertEq(order[1], "config", "session start broadcasts configuration before queued events")
    assertEq(order[2], "flush", "session start still flushes queued events")
    order = {}
    Sync:ReannounceSession()
    assertEq(order[1], "config", "a reannounce broadcasts configuration before queued events")
    assertEq(order[2], "flush", "a reannounce still flushes queued events")
    Sync.state = savedState
    Sync.FindLocalProfileById = savedFind
    Sync._EnforceGroupedSessionActive = savedEnforce
    SF.LootHelperComm = savedComm
    Sync.BroadcastConsumablesConfig = savedBroadcast
    Sync._FlushUnsentConsumablesEvents = savedFlush
end
checkTradeRangeAndAnnounce()

function checkSecureAndFingerprintRound()
    -- Active assignment epochs must not XOR-cancel against itemEpochs watermarks.
    local left = profile("fp-epoch-left", admin)
    local right = profile("fp-epoch-right", admin)
    assertTrue(select(1, C.AddCrafter(left, admin, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddCrafter(right, admin, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(left, admin, aqirite, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(right, admin, aqirite, vann, { asAdmin = true })))
    left._consumables.assignments[tostring(aqirite)].epoch = 3
    right._consumables.assignments[tostring(aqirite)].epoch = 7
    left._consumables.itemEpochs = { [aqirite] = 3, [aqiriteRank2] = 5 }
    right._consumables.itemEpochs = { [aqirite] = 7, [aqiriteRank2] = 5 }
    left._consumables.configSeq = 4
    right._consumables.configSeq = 4
    local leftFp = C.Descriptor(left).configFingerprint
    local rightFp = C.Descriptor(right).configFingerprint
    assertTrue(leftFp ~= rightFp, "matching configSeq still differs when active assignment epochs differ")
    local sameActive = profile("fp-epoch-same", admin)
    assertTrue(select(1, C.AddCrafter(sameActive, admin, vann, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(sameActive, admin, aqirite, vann, { asAdmin = true })))
    sameActive._consumables.assignments[tostring(aqirite)].epoch = 3
    sameActive._consumables.itemEpochs = { [aqirite] = 3, [aqiriteRank2] = 9 }
    sameActive._consumables.configSeq = 4
    local withMark = C.Descriptor(sameActive).configFingerprint
    sameActive._consumables.itemEpochs = { [aqirite] = 3, [aqiriteRank2] = 4 }
    local otherMark = C.Descriptor(sameActive).configFingerprint
    assertTrue(withMark ~= otherMark, "a retired item watermark still changes the configuration fingerprint")

    -- Configuration-reset rows have no item id; logs must not call GetItemInfo(nil).
    local logP = profile("reset-log", admin)
    assertTrue(select(1, C.AppendEvent(logP, {
        id = "ce:reset-log:" .. admin .. ":1",
        type = C.EVENT.RESET,
        actor = admin,
        writer = admin,
        generation = 1,
        timestamp = 1,
    }, { silent = true })), "a configuration reset can be stored")
    local savedItem = C_Item
    local nilLookup = false
    C_Item = {
        GetItemInfo = function(itemId)
            if itemId == nil then
                nilLookup = true
                error("itemInfo is non-nilable")
            end
            return "Aqirite"
        end,
    }
    local rowsOk, rows = pcall(C.HistoryRows, logP)
    C_Item = savedItem
    assertTrue(rowsOk, "history rows tolerate a configuration reset with no item id")
    assertFalse(nilLookup, "configuration-reset history does not look up a nil item id")

    -- A rejected multi-event archive batch must restore rows it evicted.
    local savedArchiveCap = C.MAX_ARCHIVED_EVENTS
    local savedActorCap = C.MAX_EVENTS_PER_ACTOR
    C.MAX_ARCHIVED_EVENTS = 2
    C.MAX_EVENTS_PER_ACTOR = 2
    local rollP = profile("archive-roll", admin)
    rollP._consumables.generation = 2
    local keepId = "ce:archive-roll:keep:1"
    local otherId = "ce:archive-roll:other:1"
    assertTrue(select(1, C.AppendArchivedEvent(rollP, {
        id = keepId, type = C.EVENT.DONATION, actor = "Other-Realm", writer = "Other-Realm",
        itemId = aqirite, quantity = 1, generation = 1, timestamp = 1,
    }, { silent = true })), "the archive fixture stores an unrelated older row")
    assertTrue(select(1, C.AppendArchivedEvent(rollP, {
        id = otherId, type = C.EVENT.DONATION, actor = admin, writer = admin,
        itemId = aqirite, quantity = 1, generation = 1, timestamp = 2,
    }, { silent = true })), "the archive fixture stores one row for this writer")
    local batchOk = C.CommitEvents(rollP, "trade-" .. admin .. "-archive", {
        { type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1 },
        { type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1 },
    }, { writer = admin })
    assertFalse(batchOk, "a batch that exceeds the archive writer quota is rejected")
    assertTrue(hasEvent(rollP._consumableEventArchive, keepId), "a rejected archive batch restores the unrelated eviction")
    assertTrue(hasEvent(rollP._consumableEventArchive, otherId), "a rejected archive batch keeps the prior writer row")
    C.MAX_ARCHIVED_EVENTS = savedArchiveCap
    C.MAX_EVENTS_PER_ACTOR = savedActorCap

    -- Split deposits reuse the residual source stack across target slots, one
    -- place per frame so Retail can unlock the source after each move.
    local depositP = profile("deposit-split", admin)
    assertTrue(select(1, C.SetGuild(depositP, admin, { guid = "club-split", name = "Spectrum", realm = "Realm" }, 1, { asAdmin = true })))
    assertTrue(select(1, C.AddCrafter(depositP, admin, admin, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(depositP, admin, aqirite, admin, { asAdmin = true })))
    local savedContainer = C_Container
    local savedPickup = PickupGuildBankItem
    local savedNum = GetGuildBankNumSlots
    local savedLink = GetGuildBankItemLink
    local savedInfo = GetGuildBankItemInfo
    local savedItemApi = C_Item
    local savedBankOpen = RT.BankIsOpen
    local savedGuild = RT.CurrentGuild
    local savedBags = RT.bagCounts
    local savedStacks = RT.bagStacks
    local savedDepositTimer = C_Timer
    local splits = {}
    local places = {}
    local deferred = {}
    C_Timer = {
        After = function(_, fn) deferred[#deferred + 1] = fn end,
        NewTimer = function(_, fn) return { Cancel = function() end } end,
    }
    C_Container = {
        SplitContainerItem = function(bag, slot, take)
            splits[#splits + 1] = { bag = bag, slot = slot, take = take }
        end,
        PickupContainerItem = function() end,
    }
    PickupGuildBankItem = function(tab, slot)
        places[#places + 1] = { tab = tab, slot = slot }
    end
    GetGuildBankNumSlots = function() return 3 end
    GetGuildBankItemLink = function(_, slot)
        if slot == 1 or slot == 2 then return "item:" .. tostring(aqirite) end
        return nil
    end
    GetGuildBankItemInfo = function(_, slot)
        if slot == 1 then return nil, 18 end
        if slot == 2 then return nil, 18 end
        return nil, 0
    end
    C_Item = { GetItemMaxStackSizeByID = function() return 20 end }
    RT.BankIsOpen = function() return true end
    RT.CurrentGuild = function() return { guid = "club-split" } end
    RT.bagCounts = { [aqirite] = 5 }
    RT.bagStacks = { [aqirite] = { { bag = 0, slot = 1, count = 5 } } }
    RT:BeginDeposit({ itemId = aqirite, quantity = 5, recipient = "guildbank" }, {
        profile = depositP,
        inGroup = {},
        compatible = {},
        inRange = {},
        usable = true,
    })
    assertEq(#places, 1, "the first deposit places only one target per frame")
    local guard = 0
    while #deferred > 0 and guard < 8 do
        guard = guard + 1
        local fn = table.remove(deferred, 1)
        fn()
    end
    assertEq(#places, 3, "a large source stack continues into later deposit targets")
    assertEq(#splits, 2, "partial fills split; the final residual pickup uses the whole remainder")
    assertEq(splits[1].take, 2, "the first deposit takes only the first target's room")
    assertEq(splits[2].take, 2, "the second deposit continues with residual stack room")
    assertEq(places[3] and places[3].slot, 3, "the final residual stack fills the next empty target")
    assertTrue(type(RT.depositIntent) == "table", "deferred places still finalize a deposit intent")
    assertEq(#(RT.depositIntent.places or {}), 3, "the deposit intent records every deferred place")
    C_Container = savedContainer
    PickupGuildBankItem = savedPickup
    GetGuildBankNumSlots = savedNum
    GetGuildBankItemLink = savedLink
    GetGuildBankItemInfo = savedInfo
    C_Item = savedItemApi
    C_Timer = savedDepositTimer
    RT.BankIsOpen = savedBankOpen
    RT.CurrentGuild = savedGuild
    RT.bagCounts = savedBags
    RT.bagStacks = savedStacks
    RT.depositIntent = nil
    RT.depositWork = nil

    -- Withdrawals blocked by a deposit rearm instead of going idle.
    local rearmP = profile("withdraw-rearm", admin)
    assertTrue(select(1, C.SetGuild(rearmP, admin, { guid = "club-rearm", name = "Spectrum", realm = "Realm" }, 1, { asAdmin = true })))
    local savedRearmTimer = C_Timer
    local rearmCount = 0
    C_Timer = {
        NewTimer = function(_, fn)
            rearmCount = rearmCount + 1
            return { Cancel = function() end }
        end,
    }
    RT.withdrawIntents = {
        { itemId = aqirite, tab = 1, profileId = rearmP._profileId, intended = 1, startedAt = 0 },
    }
    RT.withdrawIntent = RT.withdrawIntents[1]
    RT.depositIntent = { profileId = rearmP._profileId, itemId = aqirite }
    local beforeRearm = rearmCount
    RT:FinishWithdraw(true)
    assertTrue(rearmCount > beforeRearm, "a deposit-blocked withdrawal rearms its timer")
    assertEq(#RT.withdrawIntents, 1, "a deposit-blocked withdrawal keeps its queued intent")
    RT.depositIntent = nil
    RT.withdrawIntents = nil
    RT.withdrawIntent = nil
    C_Timer = savedRearmTimer

    -- Unproven catch-up coordinators cannot inject stamped relays.
    local savedState = Sync.state
    local savedUnproven = Sync._UnprovenCatchUpKeepalive
    local relayP = profile("unproven-relay", admin)
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = "FakeCoord-Realm",
        sessionId = "unproven-session",
        profileId = relayP._profileId,
        peers = { ["FakeCoord-Realm"] = { consumablesCapable = true } },
    }
    Sync._UnprovenCatchUpKeepalive = function(_, name)
        return name == "FakeCoord-Realm"
    end
    Sync.FindLocalProfileById = function() return relayP end
    local savedGroup = Sync.IsRequesterInGroup
    local savedSame = Sync._SamePlayer
    Sync.IsRequesterInGroup = function() return true end
    Sync._SamePlayer = function(_, a, b) return a == b end
    local beforeCount = #(relayP._consumableEvents or {})
    Sync:HandleConsumablesEvent("FakeCoord-Realm", {
        sessionId = "unproven-session",
        profileId = relayP._profileId,
        event = {
            id = "ce:unproven:" .. admin .. ":1",
            type = C.EVENT.DONATION,
            actor = admin,
            writer = admin,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            timestamp = 1,
            order = 9,
        },
    })
    assertEq(#(relayP._consumableEvents or {}), beforeCount, "an unproven coordinator relay is not admitted")
    assertFalse(Sync:_ConsumablesCoordinatorAccepts(), "an unproven coordinator is not asked to stamp consumables")

    -- Revoked coordinators are also rejected even when catch-up is clear.
    local revokedP = profile("revoked-relay", admin)
    local savedRevoked = Sync._RouteWasRevoked
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = "RevokedCoord-Realm",
        sessionId = "revoked-session",
        profileId = revokedP._profileId,
        peers = { ["RevokedCoord-Realm"] = { consumablesCapable = true } },
        revokedRoutes = {},
    }
    Sync._UnprovenCatchUpKeepalive = function() return false end
    Sync._RouteWasRevoked = function(_, name) return name == "RevokedCoord-Realm" end
    Sync.FindLocalProfileById = function() return revokedP end
    local beforeRevoked = #(revokedP._consumableEvents or {})
    Sync:HandleConsumablesEvent("RevokedCoord-Realm", {
        sessionId = "revoked-session",
        profileId = revokedP._profileId,
        event = {
            id = "ce:revoked:" .. admin .. ":1",
            type = C.EVENT.CUSTODY,
            action = C.ACTION.RESOLVE,
            actor = admin,
            writer = admin,
            holder = admin,
            itemId = aqirite,
            quantity = 1,
            generation = 1,
            timestamp = 1,
            order = 3,
        },
    })
    assertEq(#(revokedP._consumableEvents or {}), beforeRevoked, "a revoked coordinator relay is not admitted")
    Sync._RouteWasRevoked = savedRevoked
    Sync.IsRequesterInGroup = savedGroup
    Sync._SamePlayer = savedSame
    Sync._UnprovenCatchUpKeepalive = savedUnproven
    Sync.FindLocalProfileById = nil
    Sync.state = savedState

    -- Fingerprint catch-up throttle starts only after a successful request.
    local fpP = profile("fp-throttle", admin)
    local savedFpState = Sync.state
    local savedRequest = Sync.RequestProfileSnapshot
    local savedNow = Sync._Now
    local savedFpFind = Sync.FindLocalProfileById
    local savedFpGroup = Sync.IsRequesterInGroup
    local requestCalls = 0
    Sync.state = {
        active = true,
        isCoordinator = false,
        coordinator = admin,
        sessionId = "fp-session",
        profileId = fpP._profileId,
        peers = { [admin] = { consumablesCapable = true } },
    }
    Sync._Now = function() return 1000 end
    Sync.IsRequesterInGroup = function() return true end
    Sync.RequestProfileSnapshot = function()
        requestCalls = requestCalls + 1
        return false
    end
    Sync.FindLocalProfileById = function() return fpP end
    Sync._consumablesCatchUpKey = nil
    Sync._consumablesFpSnapshotAt = nil
    Sync._consumablesFpSnapshotSession = nil
    local localDesc = C.Descriptor(fpP)
    local fpPayload = {
        sessionId = "fp-session",
        profileId = fpP._profileId,
        coordinator = admin,
        consumablesGeneration = localDesc.generation,
        consumablesConfigSeq = localDesc.configSeq,
        consumablesConfigFingerprint = localDesc.configFingerprint,
        consumablesEventCount = localDesc.eventCount,
        consumablesEventFingerprint = (tonumber(localDesc.eventFingerprint) or 0) + 99,
        consumablesArchiveCount = localDesc.archiveCount,
        consumablesArchiveFingerprint = localDesc.archiveFingerprint,
        consumablesCapable = true,
    }
    assertEq(S.CatchUpKind(localDesc, {
        generation = fpPayload.consumablesGeneration,
        configSeq = fpPayload.consumablesConfigSeq,
        eventCount = fpPayload.consumablesEventCount,
        eventFingerprint = fpPayload.consumablesEventFingerprint,
    }), "fingerprint", "the fp fixture is fingerprint-only")
    Sync:_ConsiderConsumablesCatchUp(fpPayload)
    assertEq(requestCalls, 1, "a fingerprint mismatch attempts a snapshot request")
    assertTrue(Sync._consumablesFpSnapshotAt == nil, "a failed fingerprint request does not start the throttle")
    Sync.RequestProfileSnapshot = function()
        requestCalls = requestCalls + 1
        return true
    end
    Sync:_ConsiderConsumablesCatchUp(fpPayload)
    assertEq(requestCalls, 2, "a later heartbeat retries after a failed fingerprint request")
    assertEq(Sync._consumablesFpSnapshotAt, 1000, "a successful fingerprint request starts the throttle")
    Sync.RequestProfileSnapshot = savedRequest
    Sync._Now = savedNow
    Sync.FindLocalProfileById = savedFpFind
    Sync.IsRequesterInGroup = savedFpGroup
    Sync.state = savedFpState
    Sync._consumablesFpSnapshotAt = nil
    Sync._consumablesFpSnapshotSession = nil
    Sync._consumablesCatchUpKey = nil

    -- Offline trade freezes stay queued for a later session flush.
    local offlineFreezeP = profile("offline-freeze", admin)
    assertTrue(select(1, C.AddCrafter(offlineFreezeP, admin, admin, { asAdmin = true })))
    assertTrue(select(1, C.AddAssignment(offlineFreezeP, admin, aqirite, admin, { asAdmin = true })))
    local offlineEpoch = offlineFreezeP._consumables.assignments[tostring(aqirite)].epoch
    local savedOfflineState = Sync.state
    Sync.state = { active = false }
    local offlineOk = Sync:PublishTradeFreeze(offlineFreezeP, {
        token = "trade-" .. admin .. "-offline-1",
        donor = "Donor-Realm",
        receiver = admin,
        generation = offlineFreezeP._consumables.generation,
        items = {
            [aqirite] = { itemId = aqirite, epoch = offlineEpoch, assignedToReceiver = true },
        },
    })
    assertTrue(offlineOk == true, "an offline trade freeze registers locally")
    Sync.state = {
        active = true,
        isCoordinator = true,
        coordinator = admin,
        sessionId = "offline-flush",
        profileId = offlineFreezeP._profileId,
        coordEpoch = 1,
    }
    local savedBroadcast = Sync.BroadcastTradeFreeze
    local flushed = false
    Sync.BroadcastTradeFreeze = function(_, profile, grant)
        flushed = type(grant) == "table" and grant.token == "trade-" .. admin .. "-offline-1"
        return true
    end
    Sync:_FlushPendingTradeFreeze(offlineFreezeP)
    assertTrue(flushed, "an offline trade freeze is flushed when a session starts")
    Sync.BroadcastTradeFreeze = savedBroadcast
    Sync.state = savedOfflineState

    -- Descriptor attachment flushes before copying ledger watermarks.
    local descP = profile("desc-flush", admin)
    assertTrue(select(1, C.AppendEvent(descP, {
        id = "ce:desc-flush:" .. admin .. ":1",
        type = C.EVENT.DONATION, actor = admin, writer = admin, itemId = aqirite,
        quantity = 1, generation = 1, timestamp = 1,
    }, { silent = true })), "descriptor flush fixture stores an event")
    descP._consumablesUnsent = { "ce:desc-flush:" .. admin .. ":1" }
    local savedDescState = Sync.state
    local savedBroadcastEvent = Sync.BroadcastConsumablesEvent
    local savedDescFind = Sync.FindLocalProfileById
    local ops = {}
    Sync.state = {
        active = true,
        isCoordinator = true,
        coordinator = admin,
        sessionId = "desc-session",
        profileId = descP._profileId,
        _sessionAnnounced = "desc-session",
    }
    Sync.FindLocalProfileById = function() return descP end
    Sync.BroadcastConsumablesEvent = function(_, profile, event)
        ops[#ops + 1] = "flush-broadcast"
        if C.StampOrder then
            C.StampOrder(profile, event)
        end
        return true
    end
    local realDescriptor = C.Descriptor
    C.Descriptor = function(profile)
        ops[#ops + 1] = "descriptor"
        return realDescriptor(profile)
    end
    local payload = {}
    Sync:_AttachConsumablesDescriptor(payload, descP._profileId)
    C.Descriptor = realDescriptor
    assertEq(ops[1], "flush-broadcast", "descriptor attach flushes queued events first")
    assertEq(ops[2], "descriptor", "descriptor is computed after the flush")
    assertEq(payload.consumablesEventFingerprint, realDescriptor(descP).eventFingerprint, "advertised fingerprint matches the post-flush ledger")
    Sync.BroadcastConsumablesEvent = savedBroadcastEvent
    Sync.FindLocalProfileById = savedDescFind
    Sync.state = savedDescState
end
checkSecureAndFingerprintRound()

if failures > 0 then
    io.stderr:write(string.format("%d failed, %d passed\n", failures, passes))
    os.exit(1)
end
io.stdout:write(string.format("%d passed, 0 failed\n", passes))
