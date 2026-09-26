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
    function frame:SetPoint() end
    function frame:SetFrameStrata() end
    function frame:EnableMouse() end
    function frame:SetMovable() end
    function frame:RegisterForDrag() end
    function frame:SetScript() end
    function frame:SetBackdrop() end
    function frame:SetText() end
    function frame:SetJustifyH() end
    function frame:Hide() end
    function frame:Show() end
    function frame:SetScrollChild() end
    function frame:SetShown() end
    function frame:SetAttribute() end
    function frame:Enable() end
    function frame:Disable() end
    function frame:IsShown() return false end
    function frame:CreateFontString() return FrameMock() end
    return frame
end
function CreateFrame(_, _, _, template)
    if type(template) == "string" and template:find("SecureActionButtonTemplate", 1, true) then
        secureTemplates[#secureTemplates + 1] = template
    end
    return FrameMock()
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
function InCombatLockdown() return false end
local mobile = RT:EnsureMobileButton()
assertTrue(mobile ~= nil, "the banking button is created once combat ends")
assertEq(#secureTemplates, 1, "the secure button is created only outside combat")

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
assertTrue(#snapshotReasons > firstCatch, "a new coordinator epoch can request config catch-up again")
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
            { id = "ce:helper:1", type = C.EVENT.DONATION, actor = admin, itemId = aqirite, quantity = 1, generation = 1, timestamp = 1 },
        },
    }, { consumablesFromCoordinator = false }), "a helper snapshot still imports")
    assertEq(helperP._consumables.configSeq, 2, "a helper snapshot does not replace coordinator config")
    assertEq(helperP._consumables.crafters[1], vann, "a helper snapshot keeps the coordinator crafters")
    assertTrue(hasEvent(helperP._consumableEvents, "ce:helper:1"), "a helper snapshot still merges events")
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
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgCalls, 1, "a config difference asks for a snapshot")
    assertEq(cfgP._consumablesConfigCatchUpSession, nil, "a snapshot request that is not registered does not latch")
    assertEq(cfgOpts and cfgOpts.coordinatorOnly, true, "the config snapshot asks only the coordinator")
    allowCfg = true
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgCalls, 2, "the next heartbeat retries the config snapshot")
    assertTrue(type(cfgP._consumablesConfigCatchUpSession) == "string", "a registered config snapshot latches that coordinator epoch")
    Sync:_ConsiderConsumablesCatchUp(cfgPayload)
    assertEq(cfgCalls, 2, "a latched config snapshot is not requested again")

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

if failures > 0 then
    io.stderr:write(string.format("%d failed, %d passed\n", failures, passes))
    os.exit(1)
end
io.stdout:write(string.format("%d passed, 0 failed\n", passes))
