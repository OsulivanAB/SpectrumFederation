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
assertTrue(#clearP._consumableEvents > beforeLogs, "clear keeps historical events and adds a reset")
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
local sameLedger = { generation = 1, configSeq = 0, eventCount = 2, eventFingerprint = 11 }
assertFalse(S.NeedsCatchUp(sameLedger, sameLedger), "matching fingerprints do not catch up")
assertTrue(S.NeedsCatchUp(sameLedger, { generation = 1, configSeq = 0, eventCount = 2, eventFingerprint = 22 }), "a different fingerprint catches up")
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

if failures > 0 then
    io.stderr:write(string.format("%d failed, %d passed\n", failures, passes))
    os.exit(1)
end
io.stdout:write(string.format("%d passed, 0 failed\n", passes))
