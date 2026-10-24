-- Guild Supplies donation valuation (#397).
-- One immutable DBMarket snapshot per canonical production donation.
--
-- Authority: SF.GuildSupplies valuations on the guild record (byTxn winner +
-- bounded pending). The Guild Supplies gossip provider transports immutable
-- assignment bodies. Local mint requires current canEdit plus an exact guild
-- home-realm match. Ingress trusts the authenticated transport sender's current
-- editor authority, never payload actorGuid/actorName. Ordinary members cannot
-- mint. An editor may relay an already accepted assignment (offline author).
-- There is no cryptographic attestation; a remembered assignment id is a local
-- conflict guard, not a proof other peers can verify.
--
-- Guarantee: earliest (assignedAt, assignmentId) wins independent of receipt
-- order. Donation evidence stays immutable. Missing or invalid TSM leaves the
-- row unpriced. A stored winner is not refreshed when the market moves.
--
-- Dependencies: dataset replacement, ledger eviction, alias merge, and a
-- strictly earlier valid assignment change the effective snapshot. Losing
-- officer or realm eligibility stops new mint and catch-up only.
--
-- Lifecycle: one-shot when a live production donation is newly credited;
-- incremental catch-up when an eligible officer opens Logs; pending held until
-- the donation verifies or the cap rejects; reload restores durable winners;
-- adoption replays source assignments onto the replacement record.
--
-- TSM: read-only SF.TSM.GetMarketValue (DBMarket) only. The accepted snapshot
-- is the narrow SavedVariables exception. No general price cache.

local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

GS.VALUATION_SCHEMA = 1
GS.MAX_PENDING_VALUATIONS = 256
GS.MAX_VALUATION_SEEN = 16
GS.VALUATION_CATCHUP_BATCH = 8
GS.VALUATION_CATCHUP_SCAN = 32

local MAX_EXACT = 9007199254740992 -- 2^53; totals must stay strictly below this
local MAX_QTY = GS.MAX_OBS_QUANTITY or 100000
local MAX_UNIT = math.floor((MAX_EXACT - 1) / MAX_QTY)
local MAX_SEEN = GS.MAX_VALUATION_SEEN
local MAX_PENDING = GS.MAX_PENDING_VALUATIONS
local BATCH = GS.VALUATION_CATCHUP_BATCH
local SCAN = GS.VALUATION_CATCHUP_SCAN or 32
local MAX_ALIAS_HOPS = 8

local catchup = {
    generation = 0,
    active = false,
    scheduled = false,
    datasetId = nil,
    backlog = nil,
    index = 1,
    cache = nil,
}

-- Ephemeral validation cache keyed by the valuation store table (not SavedVariables).
-- Declared before the writers so Lua 5.1 closures see the upvalue. Controlled
-- writes advance an already-ok entry. A new store, a dataset/guild miss, or a
-- prior failure deep-scans. GS._onValuationDeepValidation is nil in production.
local valuationStoreRev = setmetatable({}, { __mode = "k" })
local valuationValidationCache = setmetatable({}, { __mode = "k" })

function GS.ValuationStoreRevision(store)
    if type(store) ~= "table" then
        return 0
    end
    return valuationStoreRev[store] or 0
end

-- Ephemeral assignmentId → storage-key map. Maintained incrementally across
-- controlled admits/forget/alias; cold-rebuilt once after load/store replace.
-- Never consulted from render paths. Not persisted.
local assignmentBindingCache = setmetatable({}, { __mode = "k" })

local function NoteValuationStoreMutation(store, record)
    if type(store) ~= "table" then
        return
    end
    local oldRev = valuationStoreRev[store] or 0
    local rev = oldRev + 1
    if rev > 4294967295 then
        rev = 1
    end
    valuationStoreRev[store] = rev
    -- Keep an incrementally maintained map when it matched the prior revision.
    -- Missing/stale caches fall back to one bounded cold rebuild on next read.
    local bindCached = assignmentBindingCache[store]
    if bindCached and bindCached.rev == oldRev and type(bindCached.map) == "table" then
        bindCached.rev = rev
    else
        assignmentBindingCache[store] = nil
    end
    local cached = valuationValidationCache[store]
    local datasetId = type(record) == "table" and record.datasetId or nil
    if cached and cached.ok and type(datasetId) == "string" and cached.datasetId == datasetId then
        cached.rev = rev
    else
        valuationValidationCache[store] = nil
    end
end

local function BindingMapForPatch(store)
    local cached = assignmentBindingCache[store]
    if cached and type(cached.map) == "table" then
        return cached.map
    end
    return nil
end

local function BindAssignmentId(map, id, key)
    if type(map) ~= "table" or type(id) ~= "string" or id == "" or type(key) ~= "string" then
        return
    end
    map[id] = key
end

local function UnbindAssignmentId(map, id, key)
    if type(map) ~= "table" or type(id) ~= "string" then
        return
    end
    if map[id] == key then
        map[id] = nil
    end
end

local function UnbindSnapAssignments(map, snap, key)
    if type(map) ~= "table" or type(snap) ~= "table" or type(key) ~= "string" then
        return
    end
    UnbindAssignmentId(map, snap.assignmentId, key)
    if type(snap.seen) == "table" then
        local last = #snap.seen
        if last > MAX_SEEN then
            last = MAX_SEEN
        end
        for i = 1, last do
            local row = snap.seen[i]
            if type(row) == "table" then
                UnbindAssignmentId(map, row.id, key)
            end
        end
    end
end

local function BindSnapAssignments(map, snap, key)
    if type(map) ~= "table" or type(snap) ~= "table" or type(key) ~= "string" then
        return
    end
    BindAssignmentId(map, snap.assignmentId, key)
    if type(snap.seen) == "table" then
        local last = #snap.seen
        if last > MAX_SEEN then
            last = MAX_SEEN
        end
        for i = 1, last do
            local row = snap.seen[i]
            if type(row) == "table" then
                BindAssignmentId(map, row.id, key)
            end
        end
    end
end

--- Patch the ephemeral binding map after a successful ApplyIncoming write.
local function PatchBindingsAfterApply(store, bucket, key, priorSnap, wrote)
    if not wrote or type(store) ~= "table" or type(key) ~= "string" then
        return
    end
    local map = BindingMapForPatch(store)
    if not map then
        return
    end
    local snap = type(bucket) == "table" and bucket[key] or nil
    if priorSnap and priorSnap ~= snap then
        -- Winner replacement retains old id in seen; rebinding the new snap
        -- covers winner + losers. Clear stale ids that no longer appear.
        UnbindSnapAssignments(map, priorSnap, key)
    end
    BindSnapAssignments(map, snap, key)
end

local function PatchBindingsRemoveSnap(store, snap, key)
    local map = BindingMapForPatch(store)
    if not map then
        return
    end
    UnbindSnapAssignments(map, snap, key)
end

local function DebugInfo(fmt, ...)
    if SF.Debug and SF.Debug.Info and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Info("GUILD_SUPPLIES", fmt, ...)
    end
end

local function IsDonationEvent(event)
    if type(event) ~= "table" then
        return false
    end
    local kind = event.type
    return kind == "donation"
        or (GS.LEDGER_EVENT and kind == GS.LEDGER_EVENT.DONATION)
end

local function EventTxn(event)
    if type(event) ~= "table" then
        return nil
    end
    if type(event.txnId) == "string" and event.txnId ~= "" then
        return event.txnId
    end
    if type(event.id) == "string" and event.id ~= "" then
        return event.id
    end
    return nil
end

local function ValidTxnId(txnId)
    if type(txnId) ~= "string" or txnId == "" or #txnId > (GS.MAX_TXN_ID or 160) then
        return nil
    end
    if not txnId:match("^ctx:") then
        return nil
    end
    return txnId
end

local function NormalizeInteger(value, minValue, maxValue)
    if type(value) ~= "number" then
        return nil
    end
    if value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    -- Exact integers must not go through the +0.5 tolerance. At 2^52 and above
    -- that addition is not representable and would reject the legal maximum.
    if value == math.floor(value) then
        if value < minValue or value > maxValue then
            return nil
        end
        return value
    end
    local nearest = math.floor(value + 0.5)
    if math.abs(value - nearest) > 1e-6 then
        return nil
    end
    if nearest < minValue or nearest > maxValue then
        return nil
    end
    return nearest
end

local function NormalizeCopper(value, maxValue)
    return NormalizeInteger(value, 0, maxValue)
end

--- Largest unit whose total with this quantity stays strictly below 2^53.
local function MaxUnitForQuantity(qty)
    qty = NormalizeInteger(qty, 1, MAX_QTY)
    if not qty then
        return nil
    end
    return math.floor((MAX_EXACT - 1) / qty)
end

local function SafeTotal(unit, qty)
    qty = NormalizeInteger(qty, 1, MAX_QTY)
    local maxUnit = qty and MaxUnitForQuantity(qty)
    unit = maxUnit and NormalizeCopper(unit, maxUnit) or nil
    if not unit or not qty then
        return nil
    end
    local total = unit * qty
    if type(total) ~= "number" or total ~= math.floor(total) or total < 0 or total >= MAX_EXACT then
        return nil
    end
    return total
end

--- Strip spacing and case only. Connected-realm names stay distinct.
function GS.NormalizeRealmToken(realm)
    if type(realm) ~= "string" then
        return nil
    end
    local stripped = realm:gsub("%s+", "")
    if stripped == "" then
        return nil
    end
    return string.lower(stripped)
end

function GS.CurrentCharacterRealm()
    local realm = nil
    if UnitFullName then
        local _, fullRealm = UnitFullName("player")
        if type(fullRealm) == "string" and fullRealm ~= "" then
            realm = fullRealm
        end
    end
    if not realm and GetRealmName then
        local named = GetRealmName()
        if type(named) == "string" and named ~= "" then
            realm = named
        end
    end
    return realm
end

--- Exact guild-home match. Empty native guild realm means "this character's realm".
function GS.GuildHomeRealmMatchesCharacter()
    local GG = SF.GuildGossip
    if not GG or type(GG.GetGuildIdentity) ~= "function" then
        return false
    end
    local identity = GG.GetGuildIdentity()
    if type(identity) ~= "table" or type(identity.guildKey) ~= "string" or identity.guildKey == "" then
        return false
    end
    local charRealm = GS.CurrentCharacterRealm()
    if not charRealm then
        return false
    end
    local guildRealm = identity.guildRealm
    if guildRealm == nil or guildRealm == "" then
        return true
    end
    local guildToken = GS.NormalizeRealmToken(guildRealm)
    local charToken = GS.NormalizeRealmToken(charRealm)
    if not guildToken or not charToken then
        return false
    end
    return guildToken == charToken
end

function GS.ValuationOfficerEligible()
    if type(GS.GetCapabilities) ~= "function" then
        return false
    end
    local caps = GS:GetCapabilities()
    if type(caps) ~= "table" or caps.canEdit ~= true then
        return false
    end
    return GS.GuildHomeRealmMatchesCharacter()
end

local function CurrentGuildKey()
    if type(GS.GetCurrentContext) == "function" then
        local ctx = GS:GetCurrentContext()
        if type(ctx) == "table" and type(ctx.guildKey) == "string" and ctx.guildKey ~= "" then
            return ctx.guildKey
        end
    end
    local GG = SF.GuildGossip
    if GG and type(GG.GetGuildIdentity) == "function" then
        local identity = GG.GetGuildIdentity()
        if type(identity) == "table" and type(identity.guildKey) == "string" then
            return identity.guildKey
        end
    end
    return nil
end

local function AccountingCfg(record)
    local accounting = record and record.accounting
    if type(accounting) ~= "table" then
        return nil
    end
    if type(accounting._consumables) ~= "table" then
        return nil
    end
    return accounting._consumables
end

local function ResolveCanonical(record, txnId)
    txnId = ValidTxnId(txnId)
    if not txnId then
        return nil
    end
    local cfg = AccountingCfg(record)
    local list = cfg and cfg.txnRegistry
    local current = txnId
    for _ = 1, MAX_ALIAS_HOPS do
        if type(list) ~= "table" then
            return current
        end
        local found = nil
        local limit = math.min(#list, GS.MAX_TXN_REGISTRY or 512)
        for i = 1, limit do
            local row = list[i]
            if type(row) == "table" and row.txnId == current then
                found = row
                break
            end
        end
        if not found then
            for i = 1, limit do
                local row = list[i]
                if type(row) == "table" and type(row.aliases) == "table" then
                    local aliasCount = math.min(#row.aliases, MAX_ALIAS_HOPS)
                    for j = 1, aliasCount do
                        if row.aliases[j] == current and ValidTxnId(row.txnId) then
                            return row.txnId
                        end
                    end
                end
            end
            return current
        end
        if type(found.aliasOf) == "string" and found.aliasOf ~= "" and found.aliasOf ~= current
            and ValidTxnId(found.aliasOf) then
            current = found.aliasOf
        else
            return ValidTxnId(found.txnId) or current
        end
    end
    return nil
end

local function AliasSet(record, txnId)
    local set = {}
    local canonical = ResolveCanonical(record, txnId)
    if canonical then
        set[canonical] = true
    end
    if ValidTxnId(txnId) then
        set[txnId] = true
    end
    local cfg = AccountingCfg(record)
    local list = cfg and cfg.txnRegistry
    if canonical and type(list) == "table" then
        local limit = math.min(#list, GS.MAX_TXN_REGISTRY or 512)
        for i = 1, limit do
            local row = list[i]
            if type(row) == "table" and row.txnId == canonical and type(row.aliases) == "table" then
                local aliasCount = math.min(#row.aliases, MAX_ALIAS_HOPS)
                for j = 1, aliasCount do
                    local alias = row.aliases[j]
                    if type(alias) == "string" and alias ~= "" then
                        set[alias] = true
                    end
                end
            end
        end
    end
    return set, canonical
end

local function VisitEvents(record, fn)
    local accounting = record and record.accounting
    if type(accounting) ~= "table" then
        return nil
    end
    local lists = { accounting._consumableEvents, accounting._consumableEventArchive }
    for li = 1, #lists do
        local list = lists[li]
        if type(list) == "table" then
            for i = 1, #list do
                if type(GS._onDonationEventFallbackVisit) == "function" then
                    GS._onDonationEventFallbackVisit(list[i])
                end
                if fn(list[i]) then
                    return list[i]
                end
            end
        end
    end
    return nil
end

-- Ephemeral txnId/id → event pointer for valuation admission. Keyed by the
-- accounting table; invalidated on shelve/trim (array identity change) and
-- extended incrementally on append-only mutation bumps. Never persisted.
-- Cold rebuild and large append tails are budgeted per callback so adoption
-- slices / Gossip deferral can yield instead of draining 8k rows synchronously.
local donationEventIndex = setmetatable({}, { __mode = "k" })
-- Max ledger rows indexed in one Ensure/Warm/FindEvent callback.
GS.DONATION_EVENT_INDEX_BUDGET = GS.DONATION_EVENT_INDEX_BUDGET or 512
-- Max deferred ordinary-Gossip valuation admits attempted per After(0) drain.
-- Matches the adoption admission slice unit so one UI callback cannot re-admit
-- an entire catch-up queue while the index is still warming.
GS.DEFERRED_VALUATION_ADMIT_BUDGET = GS.DEFERRED_VALUATION_ADMIT_BUDGET
    or GS.MAX_ADMISSION_WORK_PER_SLICE
    or 32
local function IndexBudget(budget)
    -- Explicit 0 = peek-only (no row visits this call).
    if budget == 0 then
        return 0
    end
    local limit = tonumber(budget)
    if limit == math.huge then
        return math.huge
    end
    if not limit or limit < 1 then
        return GS.DONATION_EVENT_INDEX_BUDGET or 512
    end
    return limit
end

local indexCallbackVisits = 0

local function IndexDonationEvent(byTxn, event)
    if type(byTxn) ~= "table" or type(event) ~= "table" then
        return 0
    end
    local txn = EventTxn(event)
    if type(txn) == "string" and txn ~= "" then
        byTxn[txn] = event
    end
    if type(event.id) == "string" and event.id ~= "" and event.id ~= txn then
        byTxn[event.id] = event
    end
    indexCallbackVisits = indexCallbackVisits + 1
    if type(GS._onDonationEventIndexVisit) == "function" then
        GS._onDonationEventIndexVisit(event)
    end
    return 1
end

local function ContinueDonationEventIndex(cached, live, arch, liveN, archN, budget)
    local byTxn = cached.byTxn
    local spent = 0
    local limit = IndexBudget(budget)
    -- Archive first, then live, so live overwrites win on collisions (matches
    -- VisitEvents live-then-archive first-match preference on lookup ties).
    local archPos = tonumber(cached.archPos) or 0
    while archPos < archN and spent < limit do
        archPos = archPos + 1
        spent = spent + IndexDonationEvent(byTxn, arch[archPos])
    end
    cached.archPos = archPos
    local livePos = tonumber(cached.livePos) or 0
    while livePos < liveN and spent < limit do
        livePos = livePos + 1
        spent = spent + IndexDonationEvent(byTxn, live[livePos])
    end
    cached.livePos = livePos
    -- Watermarks track how far the index covers; incomplete cold/append leaves
    -- building=true so the next callback resumes instead of restarting.
    if archPos >= archN and livePos >= liveN then
        cached.liveN = liveN
        cached.archN = archN
        cached.building = false
        cached.archPos = nil
        cached.livePos = nil
        return spent, true
    end
    cached.liveN = livePos
    cached.archN = archPos
    cached.building = true
    return spent, false
end

local function PublishIndexCallbackStats(complete)
    if type(GS._onDonationEventIndexCallback) == "function" then
        GS._onDonationEventIndexCallback(indexCallbackVisits, complete and true or false)
    end
end

--- Ensure / advance the donation event index. Returns byTxn, complete, visited.
-- budget: max events to visit this call (nil = GS.DONATION_EVENT_INDEX_BUDGET;
-- 0 = peek current coverage without indexing rows).
-- Never drains beyond that budget inside one callback.
local function EnsureDonationEventIndex(record, budget)
    indexCallbackVisits = 0
    local accounting = record and record.accounting
    if type(accounting) ~= "table" then
        PublishIndexCallbackStats(true)
        return nil, true, 0
    end
    local mut = tonumber(accounting._mutationSeq) or 0
    local live = accounting._consumableEvents
    local arch = accounting._consumableEventArchive
    local liveN = type(live) == "table" and #live or 0
    local archN = type(arch) == "table" and #arch or 0
    local limit = IndexBudget(budget)
    local cached = donationEventIndex[accounting]
    local function coverageComplete(c)
        return c and not c.building and c.mut == mut and type(c.byTxn) == "table"
            and c.live == live and c.arch == arch
            and (c.liveN or 0) >= liveN and (c.archN or 0) >= archN
    end
    if coverageComplete(cached) then
        PublishIndexCallbackStats(true)
        return cached.byTxn, true, 0
    end
    -- Peek-only: expose current partial map without spending the visit budget.
    if limit == 0 then
        if cached and type(cached.byTxn) == "table"
            and cached.live == live and cached.arch == arch then
            PublishIndexCallbackStats(false)
            return cached.byTxn, false, 0
        end
        if type(GS._onDonationEventIndexRebuild) == "function" then
            GS._onDonationEventIndexRebuild(accounting, liveN + archN)
        end
        cached = {
            mut = mut,
            byTxn = {},
            live = live,
            arch = arch,
            liveN = 0,
            archN = 0,
            archPos = 0,
            livePos = 0,
            building = true,
        }
        donationEventIndex[accounting] = cached
        PublishIndexCallbackStats(false)
        return cached.byTxn, false, 0
    end
    -- Resume cold rebuild or budgeted append for the same array identities.
    if cached and type(cached.byTxn) == "table"
        and cached.live == live and cached.arch == arch then
        if cached.building
            or liveN > (cached.liveN or 0) or archN > (cached.archN or 0)
            or mut > (cached.mut or 0) then
            if not cached.building then
                cached.archPos = cached.archN or 0
                cached.livePos = cached.liveN or 0
                cached.building = true
            end
            local spent, complete = ContinueDonationEventIndex(
                cached, live, arch, liveN, archN, limit)
            if complete then
                cached.mut = mut
            end
            PublishIndexCallbackStats(complete)
            return cached.byTxn, complete, spent
        end
    end
    -- Cold rebuild (dataset replace, shelve/trim, first use). Resumable.
    if type(GS._onDonationEventIndexRebuild) == "function" then
        GS._onDonationEventIndexRebuild(accounting, liveN + archN)
    end
    cached = {
        mut = mut,
        byTxn = {},
        live = live,
        arch = arch,
        liveN = 0,
        archN = 0,
        archPos = 0,
        livePos = 0,
        building = true,
    }
    donationEventIndex[accounting] = cached
    local spent, complete = ContinueDonationEventIndex(cached, live, arch, liveN, archN, limit)
    if complete then
        cached.mut = mut
    end
    PublishIndexCallbackStats(complete)
    return cached.byTxn, complete, spent
end

--- Map an alias onto an already-indexed canonical donation event (O(1)).
function GS.NoteDonationEventTxnAlias(record, primaryTxnId, aliasTxnId)
    local accounting = record and record.accounting
    local cached = type(accounting) == "table" and donationEventIndex[accounting] or nil
    if type(cached) ~= "table" or type(cached.byTxn) ~= "table" then
        return
    end
    if type(primaryTxnId) ~= "string" or type(aliasTxnId) ~= "string" then
        return
    end
    local ev = cached.byTxn[primaryTxnId]
    if type(ev) == "table" then
        cached.byTxn[aliasTxnId] = ev
    end
end

--- Advance a resumable cold/append index build.
-- @return complete bool, visited number
function GS.WarmDonationEventIndex(record, budget)
    local byTxn, complete, visited = EnsureDonationEventIndex(record, budget)
    if type(byTxn) ~= "table" then
        return true, 0
    end
    return complete and true or false, tonumber(visited) or 0
end

--- True when the donation-event index fully covers the current ledger arrays.
function GS.DonationEventIndexReady(record)
    local accounting = record and record.accounting
    if type(accounting) ~= "table" then
        return true
    end
    local cached = donationEventIndex[accounting]
    if type(cached) ~= "table" or type(cached.byTxn) ~= "table" or cached.building then
        return false
    end
    local live = accounting._consumableEvents
    local arch = accounting._consumableEventArchive
    local liveN = type(live) == "table" and #live or 0
    local archN = type(arch) == "table" and #arch or 0
    if cached.live ~= live or cached.arch ~= arch then
        return false
    end
    local mut = tonumber(accounting._mutationSeq) or 0
    return cached.mut == mut
        and (cached.liveN or 0) >= liveN
        and (cached.archN or 0) >= archN
end

-- Ordinary Gossip: retain authorized bodies locally while the index warms.
-- One-shot After(0) drain (same pattern as Logs catch-up); not a poller.
-- Each tick warms ≤ DONATION_EVENT_INDEX_BUDGET rows and attempts at most
-- DEFERRED_VALUATION_ADMIT_BUDGET admissions from the front of the queue;
-- awaiting_index rows and the unprocessed tail stay queued for the next tick.
local deferredValuationIngress = {}
local deferredValuationScheduled = false

local function ScheduleDeferredValuationDrain()
    if deferredValuationScheduled then
        return
    end
    deferredValuationScheduled = true
    local function drain()
        deferredValuationScheduled = false
        if #deferredValuationIngress < 1 then
            return
        end
        if type(GS._onDeferredValuationDrainCallback) == "function" then
            GS._onDeferredValuationDrainCallback(#deferredValuationIngress)
        end
        local record = nil
        if type(GS.GetCurrentRecord) == "function" then
            record = select(1, GS:GetCurrentRecord())
        end
        if type(record) == "table" then
            GS.WarmDonationEventIndex(record, GS.DONATION_EVENT_INDEX_BUDGET)
        end
        local admitBudget = tonumber(GS.DEFERRED_VALUATION_ADMIT_BUDGET)
            or GS.MAX_ADMISSION_WORK_PER_SLICE
            or 32
        if admitBudget < 1 then
            admitBudget = 1
        end
        local remain = {}
        local admits = 0
        local queueVisits = 0
        local i = 1
        local n = #deferredValuationIngress
        while i <= n do
            local row = deferredValuationIngress[i]
            if admits >= admitBudget then
                -- Preserve the unprocessed tail (and any prior awaiting rows).
                for j = i, n do
                    remain[#remain + 1] = deferredValuationIngress[j]
                end
                break
            end
            queueVisits = queueVisits + 1
            if type(row) == "table" and type(row.body) == "table" then
                admits = admits + 1
                if type(GS._onDeferredValuationAdmit) == "function" then
                    GS._onDeferredValuationAdmit(row, admits, queueVisits)
                end
                local live = row.record
                if type(GS.GetCurrentRecord) == "function" then
                    local cur = select(1, GS:GetCurrentRecord())
                    if cur ~= nil then
                        live = cur
                    end
                end
                local opts = row.opts or {}
                opts.offlineRecord = live
                opts._indexDeferAttempt = true
                local st, reason = GS:AdmitValuationAssignment(row.body, opts)
                if st == "pending" and reason == "awaiting_index" then
                    remain[#remain + 1] = row
                end
                -- accepted / duplicate / rejected / other pending: drop from
                -- deferral; durable store or reject already recorded the body.
            end
            i = i + 1
        end
        deferredValuationIngress = remain
        if #deferredValuationIngress > 0 then
            ScheduleDeferredValuationDrain()
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, drain)
    else
        drain()
    end
end

--- True when two assignment tables match the immutable fingerprint fields.
-- Local to deferral so it does not depend on Fingerprint's later definition.
local function SameImmutableAssignment(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    return a.assignmentId == b.assignmentId
        and a.assignedAt == b.assignedAt
        and a.unitCopper == b.unitCopper
        and a.quantity == b.quantity
        and a.totalCopper == b.totalCopper
        and a.itemId == b.itemId
        and a.txnId == b.txnId
        and a.datasetId == b.datasetId
        and a.guildKey == b.guildKey
        and (a.actorGuid or "") == (b.actorGuid or "")
        and (a.actorName or "") == (b.actorName or "")
end

--- Queue an authorized valuation while the donation index warms.
-- Same export/assignment/txn key: keep the first authenticated body. Identical
-- redelivery is a no-op; divergent immutable contents reject as id_conflict so
-- cold-index timing cannot overwrite the first candidate before ApplyIncoming.
-- @return status, reason — "pending","awaiting_index" or "rejected","id_conflict"
local function DeferValuationIngress(body, opts)
    opts = opts or {}
    local key = tostring(opts.exportRecordId or "")
        .. "\0" .. tostring(body and body.assignment and body.assignment.assignmentId or "")
        .. "\0" .. tostring(body and body.assignment and body.assignment.txnId or "")
    local incomingAssign = body and body.assignment
    for i = 1, #deferredValuationIngress do
        local row = deferredValuationIngress[i]
        if row and row.key == key then
            local priorAssign = row.body and row.body.assignment
            if SameImmutableAssignment(priorAssign, incomingAssign) then
                -- Identical redelivery: preserve the first authenticated context.
                ScheduleDeferredValuationDrain()
                return "pending", "awaiting_index"
            end
            -- Conflicting immutable payload under the same id: keep the first.
            ScheduleDeferredValuationDrain()
            return "rejected", "id_conflict"
        end
    end
    deferredValuationIngress[#deferredValuationIngress + 1] = {
        key = key,
        body = body,
        opts = opts,
        record = opts.offlineRecord,
    }
    ScheduleDeferredValuationDrain()
    return "pending", "awaiting_index"
end

--- Lookup donation event by txn/alias ids.
-- Peek-only against the ephemeral index. Advancement is owned by
-- WarmDonationEventIndex (adoption slices, catch-up slices, Gossip deferral)
-- so a single callback never indexes more than DONATION_EVENT_INDEX_BUDGET rows.
-- @return event|nil, ready bool — ready=false means the index still needs work
--         and a nil event must not be treated as a definitive miss.
local function FindEventForIds(record, ids)
    if type(ids) ~= "table" then
        return nil, true
    end
    local byTxn, complete = EnsureDonationEventIndex(record, 0)
    if type(byTxn) == "table" then
        local hit = nil
        for txn in pairs(ids) do
            if type(txn) == "string" then
                local ev = byTxn[txn]
                if type(ev) == "table" then
                    if hit == nil then
                        hit = ev
                    elseif hit ~= ev then
                        -- Rare multi-donation id set: preserve VisitEvents order.
                        return VisitEvents(record, function(event)
                            local t = EventTxn(event)
                            return t and ids[t] == true
                        end), true
                    end
                end
            end
        end
        if hit ~= nil then
            return hit, true
        end
        if not complete then
            return nil, false
        end
        return nil, true
    end
    return VisitEvents(record, function(event)
        local txn = EventTxn(event)
        return txn and ids[txn] == true
    end), true
end

--- Remember a just-admitted donation on the ephemeral index without a scan.
local function RememberDonationEvent(record, event)
    local accounting = record and record.accounting
    local cached = type(accounting) == "table" and donationEventIndex[accounting] or nil
    if type(cached) ~= "table" or type(cached.byTxn) ~= "table" or type(event) ~= "table" then
        return
    end
    local txn = EventTxn(event)
    if type(txn) == "string" and txn ~= "" then
        cached.byTxn[txn] = event
    end
    if type(event.id) == "string" and event.id ~= "" and event.id ~= txn then
        cached.byTxn[event.id] = event
    end
end

--- Resolve a donation for local reconcile helpers (not Gossip admission).
-- Prefers a caller-supplied known event, then the ephemeral index. Advances at
-- most one budgeted warm unless peekOnly (cutover continuation already warmed).
-- Never falls back to a full ledger VisitEvents scan: an incomplete index
-- returns ready=false so pending winners are not cleared.
-- @return event|nil, ready bool
local function ResolveEventForIds(record, ids, knownEvent, peekOnly)
    if type(knownEvent) == "table" and type(ids) == "table" then
        local txn = EventTxn(knownEvent)
        if (type(txn) == "string" and ids[txn] == true)
            or (type(knownEvent.id) == "string" and ids[knownEvent.id] == true) then
            -- Peek creates/resumes the ephemeral map so the known pointer sticks.
            EnsureDonationEventIndex(record, 0)
            RememberDonationEvent(record, knownEvent)
            return knownEvent, true
        end
    end
    local event, ready = FindEventForIds(record, ids)
    if event ~= nil or ready then
        return event, ready and true or false
    end
    if peekOnly then
        return nil, false
    end
    GS.WarmDonationEventIndex(record, GS.DONATION_EVENT_INDEX_BUDGET)
    event, ready = FindEventForIds(record, ids)
    if event ~= nil then
        return event, true
    end
    return nil, ready and true or false
end

local function PriceableDonation(record, event)
    if not (GS.IsLiveActive and GS.IsLiveActive(record)) then
        return false
    end
    if not IsDonationEvent(event) then
        return false
    end
    if event.gsProductionCredit ~= true then
        return false
    end
    if not NormalizeInteger(tonumber(event.quantity), 1, MAX_QTY) then
        return false
    end
    if not NormalizeInteger(tonumber(event.itemId), 1, MAX_EXACT - 1) then
        return false
    end
    return true
end

--- Whether a matching pending valuation should stay unpublished.
-- Staged well-formed donations stay open until cutover classification. A live
-- uncredited donation that is still after the cutover floor can receive late
-- authenticated canonical-marker provenance; keep its pending price. Rows that
-- are already credited, malformed, or permanently before the cutover floor are
-- resolved and must not hold a pending assignment.
local function CreditStillUnresolved(record, event)
    if not IsDonationEvent(event) then
        return false
    end
    if not NormalizeInteger(tonumber(event.quantity), 1, MAX_QTY) then
        return false
    end
    if not NormalizeInteger(tonumber(event.itemId), 1, MAX_EXACT - 1) then
        return false
    end
    if event.gsProductionCredit == true then
        return false
    end
    if not (GS.IsLiveActive and GS.IsLiveActive(record)) then
        return true
    end
    if GS.IsEvidenceAfterLiveCutover then
        local approx = tonumber(event.approxTxnTime) or tonumber(event.timestamp)
        local afterOk = select(1, GS.IsEvidenceAfterLiveCutover(record, {
            approxTxnTime = approx,
        }))
        if not afterOk then
            return false
        end
    end
    return true
end

local function DonationMatches(assignment, event)
    local qty = NormalizeInteger(tonumber(event.quantity), 1, MAX_QTY)
    local itemId = NormalizeInteger(tonumber(event.itemId), 1, MAX_EXACT - 1)
    return qty and itemId and assignment.quantity == qty and assignment.itemId == itemId
end

local function EnsureStore(record)
    if type(record.valuations) ~= "table" then
        record.valuations = {
            schemaVersion = GS.VALUATION_SCHEMA,
            nextSeq = 1,
            byTxn = {},
            pending = {},
        }
    end
    local store = record.valuations
    if type(store.byTxn) ~= "table" then
        store.byTxn = {}
    end
    if type(store.pending) ~= "table" then
        store.pending = {}
    end
    if store.schemaVersion == nil then
        store.schemaVersion = GS.VALUATION_SCHEMA
    end
    return store
end

local function CountKeys(map)
    local n = 0
    if type(map) ~= "table" then
        return 0
    end
    for _ in pairs(map) do
        n = n + 1
    end
    return n
end

--- Map each remembered assignmentId (winner or bounded loser) to its donation
-- storage key. Built from the current byTxn/pending tables only after a store
-- mutation; hot UI/catch-up reads must not call this.
local function BuildAssignmentBindingMap(store)
    local map = {}
    local conflict = false
    local function ingest(bucket)
        if type(bucket) ~= "table" then
            return
        end
        for key, snap in pairs(bucket) do
            if type(snap) == "table" and type(key) == "string" then
                local function bind(id)
                    if type(id) ~= "string" or id == "" then
                        return
                    end
                    local prior = map[id]
                    if prior and prior ~= key then
                        conflict = true
                    else
                        map[id] = key
                    end
                end
                bind(snap.assignmentId)
                if type(snap.seen) == "table" then
                    local last = #snap.seen
                    if last > MAX_SEEN then
                        last = MAX_SEEN
                    end
                    for i = 1, last do
                        local row = snap.seen[i]
                        if type(row) == "table" then
                            bind(row.id)
                        end
                    end
                end
            end
        end
    end
    ingest(store.byTxn)
    ingest(store.pending)
    return map, conflict
end

local function AssignmentBindingMap(store)
    if type(store) ~= "table" then
        return {}
    end
    local rev = valuationStoreRev[store] or 0
    local cached = assignmentBindingCache[store]
    if cached and cached.rev == rev and type(cached.map) == "table" then
        return cached.map
    end
    -- GS._onAssignmentBindingRebuild is nil in production; tests count cold builds.
    if type(GS._onAssignmentBindingRebuild) == "function" then
        GS._onAssignmentBindingRebuild(store)
    end
    local map = BuildAssignmentBindingMap(store)
    assignmentBindingCache[store] = { rev = rev, map = map }
    return map
end

--- True when assignmentId is already bound to a genuinely different donation.
-- Allows same-donation alias keys and pending[A]→pending[C] fold for the same
-- immutable assignment under a validated export binding.
local function AssignmentBoundElsewhere(record, store, assignmentId, targetKey, exportCanonical, assignmentTxnId)
    if type(assignmentId) ~= "string" or type(targetKey) ~= "string" then
        return false
    end
    local bound = AssignmentBindingMap(store)[assignmentId]
    if type(bound) ~= "string" or bound == targetKey then
        return false
    end
    local boundResolved = ResolveCanonical(record, bound) or bound
    local targetResolved = ResolveCanonical(record, targetKey) or targetKey
    if boundResolved == targetResolved then
        return false
    end
    if exportCanonical and targetKey == exportCanonical and bound == assignmentTxnId then
        return false
    end
    return true
end

local function ValidAssignmentId(id)
    return type(id) == "string"
        and id ~= ""
        and #id <= (GS.MAX_OPERATION_ID or 192)
        and id:match("^gsv1:[0-9a-fA-F]+:[0-9a-fA-F]+$") ~= nil
end

--- Raise store.nextSeq past a same-nonce locally minted assignment id.
-- Cheap O(1) parse; no history scan. Exhaustion pins nextSeq at max.
local function ObserveAssignmentIdSeq(store, assignmentId)
    if type(store) ~= "table" or not ValidAssignmentId(assignmentId) then
        return
    end
    local root = GS._root
    local writer = root and root.localWriter
    if type(writer) ~= "table" or type(writer.nonce) ~= "string"
        or not writer.nonce:match("^[0-9a-fA-F]+$") or #writer.nonce ~= 24 then
        return
    end
    local prefix = "gsv1:" .. writer.nonce .. ":"
    if assignmentId:sub(1, #prefix) ~= prefix then
        return
    end
    local hex = assignmentId:sub(#prefix + 1)
    if type(hex) ~= "string" or not hex:match("^[0-9a-fA-F]+$") then
        return
    end
    local seq = tonumber(hex, 16)
    if not seq or seq ~= math.floor(seq) or seq < 1 then
        return
    end
    local nextSeq = tonumber(store.nextSeq) or 1
    if seq < nextSeq then
        return
    end
    if seq >= 4294967295 then
        store.nextSeq = 4294967295
        return
    end
    store.nextSeq = seq + 1
end

local function ObserveSnapSeqs(store, snap)
    if type(store) ~= "table" or type(snap) ~= "table" then
        return
    end
    ObserveAssignmentIdSeq(store, snap.assignmentId)
    if type(snap.seen) ~= "table" then
        return
    end
    local last = #snap.seen
    if last > MAX_SEEN then
        last = MAX_SEEN
    end
    for i = 1, last do
        local row = snap.seen[i]
        if type(row) == "table" then
            ObserveAssignmentIdSeq(store, row.id)
        end
    end
end

--- Advance nextSeq from all retained same-nonce ids (winners, pending, losers).
-- Bounded by current valuation cardinality; used at adoption publish.
function GS.AdvanceValuationSeqForLocalWriter(record)
    if type(record) ~= "table" then
        return
    end
    local store = record.valuations
    if type(store) ~= "table" then
        return
    end
    local function ingest(bucket)
        if type(bucket) ~= "table" then
            return
        end
        for _, snap in pairs(bucket) do
            ObserveSnapSeqs(store, snap)
        end
    end
    ingest(store.byTxn)
    ingest(store.pending)
end

local function ValidActorGuid(guid)
    if guid == nil then
        return true
    end
    return type(guid) == "string" and guid ~= "" and #guid <= 64
end

local function ValidActorName(name)
    if name == nil then
        return true
    end
    return type(name) == "string" and name ~= "" and #name <= 64
end

local function Fingerprint(assignment)
    local canon = table.concat({
        tostring(assignment.assignmentId),
        tostring(assignment.assignedAt),
        tostring(assignment.unitCopper),
        tostring(assignment.quantity),
        tostring(assignment.totalCopper),
        tostring(assignment.itemId),
        tostring(assignment.txnId),
        tostring(assignment.datasetId),
        tostring(assignment.guildKey),
        tostring(assignment.actorGuid or ""),
        tostring(assignment.actorName or ""),
    }, "|")
    if GS.ContentFingerprint then
        local fp = GS.ContentFingerprint({ canon = canon })
        if type(fp) == "string" and fp ~= "" and #fp <= (GS.MAX_OPERATION_ID or 192) then
            return fp
        end
    end
    local hash = 5381
    for i = 1, #canon do
        hash = (hash * 33 + canon:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function CopySnap(assignment, canonical)
    return {
        assignmentId = assignment.assignmentId,
        assignedAt = assignment.assignedAt,
        unitCopper = assignment.unitCopper,
        quantity = assignment.quantity,
        totalCopper = assignment.totalCopper,
        itemId = assignment.itemId,
        txnId = assignment.txnId,
        canonicalTxnId = canonical,
        datasetId = assignment.datasetId,
        guildKey = assignment.guildKey,
        actorGuid = assignment.actorGuid,
        actorName = assignment.actorName,
        seen = {},
    }
end

local function SeenHas(seen, id)
    if type(seen) ~= "table" then
        return nil
    end
    for i = 1, #seen do
        local row = seen[i]
        if type(row) == "table" and row.id == id then
            return row
        end
    end
    return nil
end

local function RememberLoser(snap, id, fp)
    if type(snap.seen) ~= "table" then
        snap.seen = {}
    end
    if SeenHas(snap.seen, id) then
        return
    end
    if #snap.seen >= MAX_SEEN then
        table.remove(snap.seen, 1)
    end
    snap.seen[#snap.seen + 1] = { id = id, fp = fp }
end

local function CopySeenList(seen)
    if type(seen) ~= "table" then
        return {}
    end
    local out = {}
    local last = #seen
    if last > MAX_SEEN then
        last = MAX_SEEN
    end
    for i = 1, last do
        local row = seen[i]
        if type(row) == "table" then
            out[#out + 1] = { id = row.id, fp = row.fp }
        end
    end
    return out
end

--- Pure classify of incoming against an existing snap (no bucket writes).
-- @return status, changed, detail, wouldWrite, projectedSnap
local function ClassifyIncomingAgainst(snap, incoming, key)
    local fp = Fingerprint(incoming)
    local storageKey = key
    if type(storageKey) ~= "string" or storageKey == "" then
        storageKey = ValidTxnId(incoming.txnId) or incoming.txnId
    end
    if type(snap) ~= "table" then
        return "accepted", true, nil, true, CopySnap(incoming, storageKey)
    end
    local winnerFp = Fingerprint(snap)
    if incoming.assignmentId == snap.assignmentId then
        if fp == winnerFp then
            return "duplicate", false, "duplicate", false, snap
        end
        return "rejected", false, "id_conflict", false, snap
    end
    local seenRow = SeenHas(snap.seen, incoming.assignmentId)
    if seenRow then
        if seenRow.fp == fp then
            return "duplicate", false, "duplicate", false, snap
        end
        return "rejected", false, "id_conflict", false, snap
    end
    local earlier = incoming.assignedAt < snap.assignedAt
        or (incoming.assignedAt == snap.assignedAt and incoming.assignmentId < snap.assignmentId)
    if earlier then
        local replacement = CopySnap(incoming, storageKey)
        replacement.seen = CopySeenList(snap.seen)
        RememberLoser(replacement, snap.assignmentId, winnerFp)
        return "accepted", true, "earlier_assignment", true, replacement
    end
    local projected = {
        assignmentId = snap.assignmentId,
        assignedAt = snap.assignedAt,
        unitCopper = snap.unitCopper,
        quantity = snap.quantity,
        totalCopper = snap.totalCopper,
        itemId = snap.itemId,
        txnId = snap.txnId,
        canonicalTxnId = snap.canonicalTxnId or storageKey,
        datasetId = snap.datasetId,
        guildKey = snap.guildKey,
        actorGuid = snap.actorGuid,
        actorName = snap.actorName,
        seen = CopySeenList(snap.seen),
    }
    if #projected.seen < MAX_SEEN then
        projected.seen[#projected.seen + 1] = { id = incoming.assignmentId, fp = fp }
        return "duplicate", false, "later_assignment", true, projected
    end
    return "duplicate", false, "later_assignment", false, projected
end

--- Install or reject one normalized assignment into a byTxn/pending bucket.
-- @return status string, changed bool, reason string|nil, wrote bool
local function ApplyIncoming(bucket, key, incoming)
    local snap = bucket[key]
    local status, changed, detail, wouldWrite, projected = ClassifyIncomingAgainst(snap, incoming, key)
    if status == "rejected" or not wouldWrite then
        return status, changed, detail, false
    end
    if status == "accepted" then
        bucket[key] = projected
        return status, true, detail, true
    end
    -- later_assignment with room in seen: mutate the live snap in place so
    -- identity of the winner row is preserved for callers holding references.
    if detail == "later_assignment" and type(snap) == "table" then
        if type(snap.seen) ~= "table" then
            snap.seen = {}
        end
        local fp = Fingerprint(incoming)
        if not SeenHas(snap.seen, incoming.assignmentId) and #snap.seen < MAX_SEEN then
            snap.seen[#snap.seen + 1] = { id = incoming.assignmentId, fp = fp }
            return status, false, detail, true
        end
        return status, false, detail, false
    end
    if status == "duplicate" and detail == "duplicate" then
        return status, false, detail, false
    end
    if wouldWrite and type(projected) == "table" then
        bucket[key] = projected
        return status, changed, detail, true
    end
    return status, changed, detail, false
end

local function LookupSnap(record, txnId)
    local store = record and record.valuations
    if type(store) ~= "table" or type(store.byTxn) ~= "table" then
        return nil, nil
    end
    local _, canonical = AliasSet(record, txnId)
    if not canonical then
        canonical = ValidTxnId(txnId)
    end
    if not canonical then
        return nil, nil
    end
    local snap = store.byTxn[canonical]
    if type(snap) == "table" then
        return snap, canonical
    end
    return nil, canonical
end

local function PublishWinner(record, canonical)
    if GS.NoteValuationExported then
        GS.NoteValuationExported(record, canonical)
    elseif GS.NotifyUI then
        GS.NotifyUI("valuation")
    end
end

local function ShouldPublish(record)
    if type(GS.GetCurrentRecord) ~= "function" then
        return true
    end
    local current = select(1, GS:GetCurrentRecord())
    return current == record
end

local function NormalizeAssignment(body, record)
    if type(body) ~= "table" or type(body.assignment) ~= "table" then
        return nil, "malformed"
    end
    if body.schemaVersion ~= nil and tonumber(body.schemaVersion) ~= GS.VALUATION_SCHEMA then
        return nil, "unsupported_schema"
    end
    local raw = body.assignment
    local assignmentId = raw.assignmentId
    if not ValidAssignmentId(assignmentId) then
        return nil, "invalid_assignment"
    end
    local assignedAt = NormalizeInteger(raw.assignedAt, 0, MAX_EXACT - 1)
    local qty = NormalizeInteger(raw.quantity, 1, MAX_QTY)
    local maxUnit = qty and MaxUnitForQuantity(qty)
    local unit = maxUnit and NormalizeCopper(raw.unitCopper, maxUnit) or nil
    local itemId = NormalizeInteger(raw.itemId, 1, MAX_EXACT - 1)
    local total = NormalizeCopper(raw.totalCopper, MAX_EXACT - 1)
    if not assignedAt or not unit or not qty or not itemId or not total then
        return nil, "invalid_assignment"
    end
    local expected = SafeTotal(unit, qty)
    if not expected or expected ~= total then
        return nil, "invalid_assignment"
    end
    local txnId = ValidTxnId(raw.txnId)
    if not txnId then
        return nil, "invalid_txn"
    end
    local datasetId = raw.datasetId or body.datasetId
    if type(datasetId) ~= "string" or datasetId == "" or #datasetId > (GS.MAX_OPERATION_ID or 192) then
        return nil, "dataset_mismatch"
    end
    if type(body.datasetId) == "string" and body.datasetId ~= datasetId then
        return nil, "dataset_mismatch"
    end
    if record and datasetId ~= record.datasetId then
        return nil, "dataset_mismatch"
    end
    local guildKey = raw.guildKey or body.guildKey
    if type(guildKey) ~= "string" or not (GS.ParseGuildKey and select(1, GS.ParseGuildKey(guildKey))) then
        return nil, "invalid_guild_key"
    end
    if type(body.guildKey) == "string" and body.guildKey ~= guildKey then
        return nil, "wrong_guild"
    end
    if not ValidActorGuid(raw.actorGuid) or not ValidActorName(raw.actorName) then
        return nil, "invalid_assignment"
    end
    return {
        assignmentId = assignmentId,
        assignedAt = assignedAt,
        unitCopper = unit,
        quantity = qty,
        totalCopper = total,
        itemId = itemId,
        txnId = txnId,
        datasetId = datasetId,
        guildKey = guildKey,
        actorGuid = raw.actorGuid,
        actorName = raw.actorName,
    }, nil
end

local function ValidateSnapFields(snap, key, pending)
    if type(snap) ~= "table" then
        return false
    end
    if not ValidAssignmentId(snap.assignmentId) then
        return false
    end
    if not NormalizeInteger(snap.assignedAt, 0, MAX_EXACT - 1) then
        return false
    end
    local qty = NormalizeInteger(snap.quantity, 1, MAX_QTY)
    local maxUnit = qty and MaxUnitForQuantity(qty)
    if not qty or not maxUnit or not NormalizeCopper(snap.unitCopper, maxUnit) then
        return false
    end
    if not NormalizeInteger(snap.itemId, 1, MAX_EXACT - 1) then
        return false
    end
    if not NormalizeCopper(snap.totalCopper, MAX_EXACT - 1) then
        return false
    end
    if SafeTotal(snap.unitCopper, qty) ~= snap.totalCopper then
        return false
    end
    if not ValidTxnId(snap.txnId) then
        return false
    end
    if type(snap.datasetId) ~= "string" or snap.datasetId == "" then
        return false
    end
    if type(snap.guildKey) ~= "string" or snap.guildKey == "" then
        return false
    end
    if not ValidActorGuid(snap.actorGuid) or not ValidActorName(snap.actorName) then
        return false
    end
    if snap.canonicalTxnId ~= nil and snap.canonicalTxnId ~= key then
        return false
    end
    if pending and snap.txnId ~= key then
        -- Alias fold may keep the row under the canonical lookup key while the
        -- immutable assignment still carries its original transaction id.
        if snap.canonicalTxnId ~= key or not ValidTxnId(snap.txnId) then
            return false
        end
    end
    if snap.seen ~= nil then
        if type(snap.seen) ~= "table" or #snap.seen > MAX_SEEN then
            return false
        end
        for i = 1, #snap.seen do
            local row = snap.seen[i]
            if type(row) ~= "table" or not ValidAssignmentId(row.id) then
                return false
            end
            if type(row.fp) ~= "string" or row.fp == "" or #row.fp > (GS.MAX_OPERATION_ID or 192) then
                return false
            end
        end
    end
    return true
end

function GS.ValidateValuationStore(store, record, guildKey)
    if store == nil then
        return true
    end
    if type(store) ~= "table" then
        return false, "invalid_valuations"
    end
    if type(record) ~= "table" or type(record.datasetId) ~= "string" or record.datasetId == "" then
        return false, "invalid_valuations"
    end
    if type(guildKey) ~= "string" or guildKey == "" then
        return false, "invalid_valuations"
    end
    if store.schemaVersion ~= nil and tonumber(store.schemaVersion) ~= GS.VALUATION_SCHEMA then
        return false, "invalid_valuations"
    end
    if store.nextSeq ~= nil then
        local seq = tonumber(store.nextSeq)
        if not seq or seq ~= math.floor(seq) or seq < 1 or seq > 4294967295 then
            return false, "invalid_valuations"
        end
    end
    if store.byTxn ~= nil and type(store.byTxn) ~= "table" then
        return false, "invalid_valuations"
    end
    if store.pending ~= nil and type(store.pending) ~= "table" then
        return false, "invalid_valuations"
    end
    local rev = valuationStoreRev[store] or 0
    local cached = valuationValidationCache[store]
    if cached and cached.rev == rev and cached.datasetId == record.datasetId
        and cached.guildKey == guildKey then
        if cached.ok then
            return true
        end
        return false, cached.err or "invalid_valuations"
    end
    if type(GS._onValuationDeepValidation) == "function" then
        GS._onValuationDeepValidation(store)
    end
    local maxEvents = (GS.MAX_LEDGER_EVENTS or 4096) + (GS.MAX_ARCHIVED_EVENTS or 4096)
    if CountKeys(store.byTxn) > maxEvents or CountKeys(store.pending) > MAX_PENDING then
        valuationValidationCache[store] = {
            rev = rev, ok = false, err = "invalid_valuations",
            datasetId = record.datasetId, guildKey = guildKey,
        }
        return false, "invalid_valuations"
    end
    if type(store.byTxn) == "table" then
        for key, snap in pairs(store.byTxn) do
            if not ValidTxnId(key) or not ValidateSnapFields(snap, key, false) then
                valuationValidationCache[store] = {
                    rev = rev, ok = false, err = "invalid_valuations",
                    datasetId = record.datasetId, guildKey = guildKey,
                }
                return false, "invalid_valuations"
            end
            if snap.datasetId ~= record.datasetId or snap.guildKey ~= guildKey then
                valuationValidationCache[store] = {
                    rev = rev, ok = false, err = "invalid_valuations",
                    datasetId = record.datasetId, guildKey = guildKey,
                }
                return false, "invalid_valuations"
            end
        end
    end
    if type(store.pending) == "table" then
        for key, snap in pairs(store.pending) do
            if not ValidTxnId(key) or not ValidateSnapFields(snap, key, true) then
                valuationValidationCache[store] = {
                    rev = rev, ok = false, err = "invalid_valuations",
                    datasetId = record.datasetId, guildKey = guildKey,
                }
                return false, "invalid_valuations"
            end
            if snap.datasetId ~= record.datasetId or snap.guildKey ~= guildKey then
                valuationValidationCache[store] = {
                    rev = rev, ok = false, err = "invalid_valuations",
                    datasetId = record.datasetId, guildKey = guildKey,
                }
                return false, "invalid_valuations"
            end
        end
    end
    -- One logical assignment id may bind to only one donation key. Checked only
    -- on the deep-validation path already walking every snap.
    local _, assignmentConflict = BuildAssignmentBindingMap(store)
    if assignmentConflict then
        valuationValidationCache[store] = {
            rev = rev, ok = false, err = "invalid_valuations",
            datasetId = record.datasetId, guildKey = guildKey,
        }
        return false, "invalid_valuations"
    end
    valuationValidationCache[store] = {
        rev = rev, ok = true, datasetId = record.datasetId, guildKey = guildKey,
    }
    return true
end

local function DropKeys(bucket, ids)
    local removed = false
    if type(bucket) ~= "table" then
        return false
    end
    for key in pairs(ids) do
        if bucket[key] ~= nil then
            bucket[key] = nil
            removed = true
        end
    end
    return removed
end

local function RemoveValuationExports(record, ids, opts)
    -- Temporary adoption records must not edit the active dataset's exports.
    if not ShouldPublish(record) then
        return
    end
    if not GS.RemoveGossipExportBodies then
        return
    end
    opts = opts or {}
    local list = {}
    for key in pairs(ids) do
        list[#list + 1] = "gs:val:" .. tostring(key)
    end
    if #list < 1 then
        return
    end
    if opts.bulk == true then
        GS.RemoveGossipExportBodies(list, { bulk = true })
        return
    end
    local offset = 1
    while offset <= #list do
        local chunk = {}
        local last = math.min(offset + 63, #list)
        for i = offset, last do
            chunk[#chunk + 1] = list[i]
        end
        GS.RemoveGossipExportBodies(chunk)
        offset = last + 1
    end
end

function GS.ForgetDonationValuations(record, txnIds, opts)
    if type(record) ~= "table" or type(txnIds) ~= "table" then
        return
    end
    opts = opts or {}
    local store = record.valuations
    if type(store) ~= "table" then
        return
    end
    local drop = {}
    for i = 1, #txnIds do
        local txn = txnIds[i]
        if type(txn) == "string" and txn ~= "" then
            drop[txn] = true
            local canonical = ResolveCanonical(record, txn)
            if canonical then
                drop[canonical] = true
            end
        end
    end
    local removedAny = false
    local function consider(bucket)
        if type(bucket) ~= "table" then
            return
        end
        local remove = {}
        local removeSnaps = {}
        for key, snap in pairs(bucket) do
            local snapTxn = type(snap) == "table" and snap.txnId or nil
            local canonical = type(snap) == "table" and snap.canonicalTxnId or nil
            if drop[key] or (snapTxn and drop[snapTxn]) or (canonical and drop[canonical]) then
                remove[#remove + 1] = key
                removeSnaps[#removeSnaps + 1] = snap
                drop[key] = true
            end
        end
        for i = 1, #remove do
            PatchBindingsRemoveSnap(store, removeSnaps[i], remove[i])
            bucket[remove[i]] = nil
        end
        if #remove > 0 then
            removedAny = true
        end
    end
    consider(store.byTxn)
    consider(store.pending)
    if removedAny then
        NoteValuationStoreMutation(store, record)
    end
    RemoveValuationExports(record, drop, {
        bulk = opts.bulkExport == true or opts.bulk == true,
    })
end

local function MergeOntoCanonical(record, canonical, incoming, changed, knownEvent)
    if type(incoming) ~= "table" then
        return changed
    end
    local eventIds = AliasSet(record, canonical)
    local event, ready = ResolveEventForIds(record, eventIds, knownEvent)
    if not ready and not event then
        -- Index still warming: leave pending/winners untouched.
        return changed
    end
    if not event or not PriceableDonation(record, event) or not DonationMatches(incoming, event) then
        return changed
    end
    local store = EnsureStore(record)
    local prior = type(store.byTxn) == "table" and store.byTxn[canonical] or nil
    local _, did, _, wrote = ApplyIncoming(store.byTxn, canonical, incoming)
    if wrote then
        PatchBindingsAfterApply(store, store.byTxn, canonical, prior, true)
        NoteValuationStoreMutation(store, record)
    end
    return changed or did == true
end

--- Promote/drop pending valuations for one donation txn.
-- knownEvent: optional just-admitted ledger row (avoids cold full-history scans).
-- opts.peekOnly: skip the nested warm (caller already spent the callback budget).
function GS.ReconcilePendingValuations(record, txnId, knownEvent, opts)
    if type(record) ~= "table" then
        return false
    end
    local ids, canonical = AliasSet(record, txnId)
    if not canonical then
        return false
    end
    local store = record.valuations
    if type(store) ~= "table" then
        return false
    end
    local peekOnly = type(opts) == "table" and opts.peekOnly and true or false
    local event, ready = ResolveEventForIds(record, ids, knownEvent, peekOnly)
    if not ready and not event then
        -- Incomplete index without a known event: not a definitive miss.
        return false
    end
    if event and not PriceableDonation(record, event) then
        if CreditStillUnresolved(record, event) then
            return false
        end
        if type(store.pending) == "table" then
            for key in pairs(ids) do
                local snap = store.pending[key]
                if snap ~= nil then
                    PatchBindingsRemoveSnap(store, snap, key)
                end
            end
        end
        if DropKeys(store.pending, ids) then
            NoteValuationStoreMutation(store, record)
        end
        return false
    end
    if not event then
        return false
    end
    local changed = false
    local removed = false
    for key in pairs(ids) do
        local fromWinner = nil
        if key ~= canonical and type(store.byTxn) == "table" then
            fromWinner = store.byTxn[key]
            if fromWinner ~= nil then
                PatchBindingsRemoveSnap(store, fromWinner, key)
                store.byTxn[key] = nil
                removed = true
            end
        end
        local fromPending = type(store.pending) == "table" and store.pending[key] or nil
        if fromPending ~= nil and type(store.pending) == "table" then
            PatchBindingsRemoveSnap(store, fromPending, key)
            store.pending[key] = nil
            removed = true
        end
        changed = MergeOntoCanonical(record, canonical, fromWinner, changed, event)
        changed = MergeOntoCanonical(record, canonical, fromPending, changed, event)
    end
    if removed then
        NoteValuationStoreMutation(store, record)
    end
    if changed and ShouldPublish(record) then
        PublishWinner(record, canonical)
        DebugInfo("valuation reconciled txn=%s", tostring(canonical))
    end
    return changed
end

-- Cutover / credit-change reconcile: dataset-scoped After(0) continuation.
-- Each tick warms ≤ DONATION_EVENT_INDEX_BUDGET once, then peeks up to
-- DEFERRED_VALUATION_ADMIT_BUDGET pending keys. Cancels on dataset/store
-- replacement. Idle when the index is complete and one full pending walk has
-- finished (remaining pending rows are legitimately awaiting credit/donation).
local creditReconcile = {
    scheduled = false,
    datasetId = nil,
    store = nil,
    keys = nil,
    cursor = 1,
    completePass = false,
}

local function CollectPendingValuationKeys(store)
    local pending = type(store) == "table" and store.pending or nil
    local keys = {}
    if type(pending) ~= "table" then
        return keys
    end
    for key in pairs(pending) do
        if type(key) == "string" and key ~= "" then
            keys[#keys + 1] = key
            if #keys >= MAX_PENDING then
                break
            end
        end
    end
    table.sort(keys)
    return keys
end

local ScheduleCreditReconcileContinuation

local function CreditReconcileDrain()
    creditReconcile.scheduled = false
    local record = nil
    if type(GS.GetCurrentRecord) == "function" then
        record = select(1, GS:GetCurrentRecord())
    end
    if type(record) ~= "table"
        or record.datasetId ~= creditReconcile.datasetId
        or record.valuations ~= creditReconcile.store then
        creditReconcile.keys = nil
        creditReconcile.datasetId = nil
        creditReconcile.store = nil
        creditReconcile.completePass = false
        return
    end
    local store = creditReconcile.store
    if GS.WarmDonationEventIndex then
        GS.WarmDonationEventIndex(record, GS.DONATION_EVENT_INDEX_BUDGET)
    end
    local indexReady = GS.DonationEventIndexReady
        and GS.DonationEventIndexReady(record) and true or false
    if type(creditReconcile.keys) ~= "table" then
        creditReconcile.keys = CollectPendingValuationKeys(store)
        creditReconcile.cursor = 1
    end
    -- A walk that begins against a ready index is the completion pass.
    if indexReady and (tonumber(creditReconcile.cursor) or 1) == 1 then
        creditReconcile.completePass = true
    end
    local keys = creditReconcile.keys
    local admitBudget = tonumber(GS.DEFERRED_VALUATION_ADMIT_BUDGET)
        or GS.MAX_ADMISSION_WORK_PER_SLICE
        or 32
    if admitBudget < 1 then
        admitBudget = 1
    end
    local processed = 0
    local i = tonumber(creditReconcile.cursor) or 1
    while i <= #keys and processed < admitBudget do
        local key = keys[i]
        i = i + 1
        if type(store.pending) == "table" and store.pending[key] ~= nil then
            processed = processed + 1
            GS.ReconcilePendingValuations(record, key, nil, { peekOnly = true })
        end
    end
    creditReconcile.cursor = i
    if type(GS._onCreditReconcileCallback) == "function" then
        GS._onCreditReconcileCallback({
            processed = processed,
            indexReady = indexReady,
            pendingKeys = #keys,
            cursor = creditReconcile.cursor,
            completePass = creditReconcile.completePass and true or false,
        })
    end
    local function needMore()
        if creditReconcile.cursor <= #keys then
            return true
        end
        if not indexReady then
            creditReconcile.keys = nil
            creditReconcile.completePass = false
            return #(CollectPendingValuationKeys(store)) > 0
        end
        if not creditReconcile.completePass then
            creditReconcile.keys = nil
            creditReconcile.completePass = true
            return #(CollectPendingValuationKeys(store)) > 0
        end
        creditReconcile.keys = nil
        creditReconcile.datasetId = nil
        creditReconcile.store = nil
        creditReconcile.completePass = false
        return false
    end
    if needMore() then
        ScheduleCreditReconcileContinuation()
    end
end

-- Further chunks use After(0); the kickoff runs the first chunk inline.
ScheduleCreditReconcileContinuation = function()
    if creditReconcile.scheduled then
        return
    end
    creditReconcile.scheduled = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0, CreditReconcileDrain)
    else
        CreditReconcileDrain()
    end
end

--- After a cutover classifies retained rows, fold still-pending assignments.
-- First chunk is inline (one warm + peek batch). Further work continues via
-- After(0) until the index is complete and pending have been walked. Cancels
-- when the live dataset/store is replaced. Priceable rows merge with
-- earliest-wins; rows that stay unpriceable remain pending without looping.
function GS.ReconcileValuationsAfterCreditChange(record)
    if type(record) ~= "table" then
        return
    end
    local store = record.valuations
    local pending = type(store) == "table" and store.pending or nil
    if type(pending) ~= "table" then
        return
    end
    local keys = CollectPendingValuationKeys(store)
    if #keys == 0 then
        return
    end
    creditReconcile.datasetId = record.datasetId
    creditReconcile.store = store
    creditReconcile.keys = keys
    creditReconcile.cursor = 1
    creditReconcile.completePass = false
    if creditReconcile.scheduled then
        return
    end
    CreditReconcileDrain()
end

function GS._creditReconcileIsIdle()
    return not creditReconcile.scheduled
        and (creditReconcile.keys == nil or #(creditReconcile.keys) == 0)
end

--- Fold alias candidates into pending[canonical] while credit is still open.
-- Does not publish. Same assignment id keeps the first body (id conflict).
-- Different ids use earliest (assignedAt, assignmentId). The original
-- assignment txnId stays on the immutable body; canonical is only the key.
local function HoldAliasPending(record, store, canonical, event, candidates)
    if type(store.pending) ~= "table" then
        store.pending = {}
    end
    local wrote = false
    local guildKey = CurrentGuildKey()
    for i = 1, #candidates do
        local row = candidates[i]
        local snap = row.snap
        local scoped = type(snap) == "table"
            and snap.datasetId == record.datasetId
            and (not guildKey or snap.guildKey == guildKey)
        local originalTxn = type(snap) == "table" and ValidTxnId(snap.txnId) or nil
        if scoped and originalTxn and ValidateSnapFields(snap, row.key, row.pending)
            and (not event or DonationMatches(snap, event)) then
            if store.pending[canonical] == nil and CountKeys(store.pending) >= MAX_PENDING then
                -- Pending storage stays capped. A full map cannot take a new key.
            else
                local prior = store.pending[canonical]
                local _, _, _, didWrite = ApplyIncoming(store.pending, canonical, {
                    assignmentId = snap.assignmentId,
                    assignedAt = snap.assignedAt,
                    unitCopper = snap.unitCopper,
                    quantity = snap.quantity,
                    totalCopper = snap.totalCopper,
                    itemId = snap.itemId,
                    txnId = originalTxn,
                    datasetId = snap.datasetId,
                    guildKey = snap.guildKey,
                    actorGuid = snap.actorGuid,
                    actorName = snap.actorName,
                })
                if didWrite then
                    PatchBindingsAfterApply(store, store.pending, canonical, prior, true)
                    wrote = true
                end
            end
        end
    end
    return wrote
end

function GS.OnDonationTxnAlias(record, primaryTxnId, aliasTxnId, knownEvent)
    if type(record) ~= "table" then
        return
    end
    local canonical = ResolveCanonical(record, primaryTxnId) or ValidTxnId(primaryTxnId)
    local alias = ValidTxnId(aliasTxnId)
    if not canonical or not alias or canonical == alias then
        return
    end
    -- Keep the ephemeral donation-event index aligned with the registry alias.
    GS.NoteDonationEventTxnAlias(record, canonical, alias)
    local store = record.valuations
    if type(store) ~= "table" then
        return
    end
    -- Read every candidate before deleting a key. The earlier assignment may
    -- already sit on the canonical id while a later one sits on the alias.
    local candidates = {}
    local function push(bucket, key, pending)
        local snap = type(bucket) == "table" and bucket[key] or nil
        if type(snap) == "table" then
            candidates[#candidates + 1] = { snap = snap, key = key, pending = pending and true or false }
        end
    end
    push(store.byTxn, canonical, false)
    push(store.byTxn, alias, false)
    push(store.pending, canonical, true)
    push(store.pending, alias, true)
    local removed = false
    if type(store.byTxn) == "table" and store.byTxn[alias] ~= nil then
        PatchBindingsRemoveSnap(store, store.byTxn[alias], alias)
        store.byTxn[alias] = nil
        removed = true
    end
    if type(store.pending) == "table" then
        if store.pending[alias] ~= nil then
            PatchBindingsRemoveSnap(store, store.pending[alias], alias)
            store.pending[alias] = nil
            removed = true
        end
        if store.pending[canonical] ~= nil then
            PatchBindingsRemoveSnap(store, store.pending[canonical], canonical)
            store.pending[canonical] = nil
            removed = true
        end
    end
    local ids = AliasSet(record, canonical)
    -- Prefer a caller-supplied accepted donation (competing-ID alias paths) so a
    -- cold index cannot strand pending[X] after HoldAliasPending.
    local event, ready = ResolveEventForIds(record, ids, knownEvent)
    -- Incomplete index: keep candidates under pending[canonical]; do not treat
    -- as a definitive miss or clear pending winners. Schedule the shared
    -- credit-reconcile continuation so promotion converges without redelivery.
    if not ready and not event then
        local wrote = HoldAliasPending(record, store, canonical, nil, candidates)
        if removed or wrote then
            NoteValuationStoreMutation(store, record)
        end
        RemoveValuationExports(record, { [alias] = true })
        if GS.ReconcileValuationsAfterCreditChange then
            GS.ReconcileValuationsAfterCreditChange(record)
        end
        return
    end
    local priceable = event and PriceableDonation(record, event) and true or false
    -- No donation yet, or a staged donation whose cutover credit is still open.
    -- Keep one pending row on the canonical id. Do not publish it.
    local hold = (not event) or (event and not priceable and CreditStillUnresolved(record, event))
    if hold then
        local wrote = HoldAliasPending(record, store, canonical, event, candidates)
        if removed or wrote then
            NoteValuationStoreMutation(store, record)
        end
        RemoveValuationExports(record, { [alias] = true })
        return
    end
    if removed then
        NoteValuationStoreMutation(store, record)
    end
    local changed = false
    for i = 1, #candidates do
        changed = MergeOntoCanonical(record, canonical, candidates[i].snap, changed, event)
    end
    RemoveValuationExports(record, { [alias] = true })
    if changed and ShouldPublish(record) then
        PublishWinner(record, canonical)
        DebugInfo("valuation alias txn=%s alias=%s", tostring(canonical), tostring(alias))
    end
end

--- Parse provider/adoption record id `gs:val:<canonicalTxnId>`.
-- Returns the validated canonical txn id, or nil when the id is absent /
-- synthetic (tests) / not a valuation export binding.
local function ParseValuationExportCanonical(recordId)
    if type(recordId) ~= "string" or recordId == "" then
        return nil, false
    end
    if recordId:sub(1, 7) ~= "gs:val:" then
        -- Non-export ids (including synthetic test ids) carry no binding.
        return nil, false
    end
    local canonical = ValidTxnId(recordId:sub(8))
    if not canonical then
        return nil, true
    end
    return canonical, true
end

function GS.ParseValuationExportCanonical(recordId)
    return ParseValuationExportCanonical(recordId)
end

--- Admit one gossip or adoption valuation body.
-- Transport sender authority is opts.member. Actor fields are stored, not trusted.
-- opts.exportRecordId / opts.exportCanonicalTxnId carry the provider binding
-- `gs:val:<canonical>` without rewriting the immutable assignment.txnId.
function GS:AdmitValuationAssignment(body, opts)
    opts = opts or {}
    local record = opts.offlineRecord
    if type(record) ~= "table" then
        record = select(1, GS:GetCurrentRecord())
    end
    if type(record) ~= "table" then
        return "pending", "awaiting_dataset"
    end
    local member = opts.member
    if opts.localMint then
        -- Realm and officer checks already ran for this client. Do not invent a
        -- transport sender, and do not trust the assignment's actor fields.
        if not GS.ValuationOfficerEligible() then
            return "rejected", "unauthorized"
        end
    else
        if type(member) ~= "table" then
            return "rejected", "unauthorized"
        end
        -- Fresh-client adoption replay: the live guild slot is absent, so the
        -- ordinary editor lookup returns not_configured. Reuse the guarded
        -- allowBootstrapInstall path already used by AdmitRemoteOperation.
        local authOpts = {}
        if opts.adoptionReplay and type(opts.offlineRecord) == "table"
            and type(member.guildKey) == "string" and member.guildKey ~= "" then
            local liveGuild = GS._root and GS._root.guilds and GS._root.guilds[member.guildKey]
            if type(liveGuild) ~= "table" then
                authOpts.allowBootstrapInstall = true
            end
        end
        local editorOk = GS.SenderHasEditorAuthority
            and select(1, GS.SenderHasEditorAuthority(member, authOpts))
        if not editorOk then
            return "rejected", "unauthorized"
        end
    end
    local assignment, reason = NormalizeAssignment(body, record)
    if not assignment then
        return "rejected", reason or "malformed"
    end
    if opts.adoptionReplay then
        local adop = GS._adoption
        if type(adop) ~= "table" or adop.guildKey ~= assignment.guildKey then
            return "rejected", "wrong_guild"
        end
    else
        local guildKey = CurrentGuildKey()
        if not guildKey or guildKey ~= assignment.guildKey then
            return "rejected", "wrong_guild"
        end
    end
    -- Canonical binding from the provider record id. Aliases are local-only, so
    -- a fresh peer that only has donation C must still accept gs:val:C whose
    -- immutable assignment.txnId is the source alias A.
    local exportCanonical = nil
    if type(opts.exportCanonicalTxnId) == "string" and opts.exportCanonicalTxnId ~= "" then
        exportCanonical = ValidTxnId(opts.exportCanonicalTxnId)
        if not exportCanonical then
            return "rejected", "invalid_export_id"
        end
    else
        local parsed, isValExport = ParseValuationExportCanonical(opts.exportRecordId)
        if isValExport and not parsed then
            return "rejected", "invalid_export_id"
        end
        exportCanonical = parsed
    end
    local ids, canonical = AliasSet(record, assignment.txnId)
    if not canonical then
        return "rejected", "invalid_txn"
    end
    if exportCanonical then
        -- Resolve wire ids through the local txn registry.
        -- 1) Same local primary (gs:val:X with X→A): store/lookup under that
        --    primary so ledger-first competing-ID valuations converge.
        -- 2) Classic cross-client bind (gs:val:C with unbound source alias A):
        --    keep the export id as the storage key; dual-event checks below
        --    prove A is not a distinct credited donation.
        -- Unrelated resolved primaries stay rejected.
        local resolvedAssignment = ResolveCanonical(record, assignment.txnId)
            or assignment.txnId
        local resolvedExport = ResolveCanonical(record, exportCanonical)
            or exportCanonical
        local storageCanonical
        if resolvedAssignment == resolvedExport then
            storageCanonical = resolvedExport
        elseif resolvedExport == exportCanonical
            and (resolvedAssignment == assignment.txnId
                or resolvedAssignment == exportCanonical) then
            storageCanonical = exportCanonical
        else
            return "rejected", "canonical_conflict"
        end
        -- Keep assignment.txnId immutable (fingerprint / earliest-wins).
        local exportIds = AliasSet(record, storageCanonical)
        if exportCanonical ~= assignment.txnId then
            -- Distinct wire ids (gs:val:C with assignment.txnId=A): both must
            -- name the same live donation, never two distinct credited rows.
            local exportEvent, exportReady = FindEventForIds(record, exportIds)
            local originalEvent, originalReady = FindEventForIds(record, { [assignment.txnId] = true })
            if (exportReady == false or originalReady == false)
                and not opts.adoptionReplay
                and not opts._indexDeferAttempt
                and not deferredValuationScheduled then
                -- Ordinary ingress: one bounded warm (≤ DONATION_EVENT_INDEX_BUDGET)
                -- per callback. A burst that already scheduled the After(0) drain
                -- leaves further warming to that tick so 512 is not multiplied.
                GS.WarmDonationEventIndex(record, GS.DONATION_EVENT_INDEX_BUDGET)
                exportEvent, exportReady = FindEventForIds(record, exportIds)
                originalEvent, originalReady = FindEventForIds(record, { [assignment.txnId] = true })
            end
            if exportReady == false or originalReady == false then
                if not opts.adoptionReplay and not opts._indexDeferAttempt then
                    local deferSt, deferReason = DeferValuationIngress(body, opts)
                    if deferSt == "rejected" then
                        return deferSt, deferReason
                    end
                end
                return "pending", "awaiting_index"
            end
            if originalEvent and exportEvent then
                local ot, et = EventTxn(originalEvent), EventTxn(exportEvent)
                if ot and et and ot ~= et then
                    return "rejected", "canonical_conflict"
                end
            elseif originalEvent and not exportEvent then
                return "rejected", "canonical_conflict"
            end
        end
        canonical = storageCanonical
        ids = exportIds
        ids[assignment.txnId] = true
        ids[exportCanonical] = true
    end
    local event, eventReady = FindEventForIds(record, ids)
    if eventReady == false and not opts.adoptionReplay and not opts._indexDeferAttempt
        and not deferredValuationScheduled then
        -- At most one index budget per ordinary-ingress callback. Further bodies
        -- in the same burst defer; the After(0) drain owns subsequent warms.
        GS.WarmDonationEventIndex(record, GS.DONATION_EVENT_INDEX_BUDGET)
        event, eventReady = FindEventForIds(record, ids)
    end
    if eventReady == false then
        -- Index still warming: keep the authorized body without treating a miss
        -- as a definitive absence. Adoption retries; Gossip uses local After(0).
        if not opts.adoptionReplay and not opts._indexDeferAttempt then
            local deferSt, deferReason = DeferValuationIngress(body, opts)
            if deferSt == "rejected" then
                return deferSt, deferReason
            end
        end
        return "pending", "awaiting_index"
    end
    local holdForCredit = false
    if event and not PriceableDonation(record, event) then
        if not DonationMatches(assignment, event) then
            return "rejected", "inconsistent_donation"
        end
        if not CreditStillUnresolved(record, event) then
            return "rejected", "not_priceable"
        end
        -- Same-dataset staged cutover can still classify this donation. Keep the
        -- authorized assignment pending. Do not publish or export it yet.
        holdForCredit = true
    end
    if event and not holdForCredit and not DonationMatches(assignment, event) then
        return "rejected", "inconsistent_donation"
    end
    local store = EnsureStore(record)
    if not event or holdForCredit then
        -- Park under the lookup key that later donation reconcile will use.
        -- A validated gs:val:<canonical> binding must retain pending[C] even
        -- when immutable assignment.txnId is still the source alias A; a fresh
        -- peer has no A→C registry, so pending[A] would never promote.
        local pendingKey = assignment.txnId
        if exportCanonical then
            pendingKey = canonical
        end
        if type(store.pending) == "table" then
            if store.pending[canonical] ~= nil then
                pendingKey = canonical
            elseif not exportCanonical and store.pending[assignment.txnId] == nil then
                for key in pairs(ids) do
                    if store.pending[key] ~= nil then
                        pendingKey = key
                        break
                    end
                end
            end
        end
        -- Fold a previously unbound pending[A] onto export-canonical C before
        -- installing this body. Earliest (assignedAt, assignmentId) wins.
        -- Preflight ClassifyIncomingAgainst so a rejected incoming body cannot
        -- move pending[A] or patch bindings (rejected folds stay atomic).
        local folded = false
        local foldPrior = nil
        local foldPriorIncoming = nil
        if exportCanonical and type(store.pending) == "table"
            and assignment.txnId ~= canonical
            and type(store.pending[assignment.txnId]) == "table" then
            foldPrior = store.pending[assignment.txnId]
            local priorTxn = ValidTxnId(foldPrior.txnId) or assignment.txnId
            foldPriorIncoming = {
                assignmentId = foldPrior.assignmentId,
                assignedAt = foldPrior.assignedAt,
                unitCopper = foldPrior.unitCopper,
                quantity = foldPrior.quantity,
                totalCopper = foldPrior.totalCopper,
                itemId = foldPrior.itemId,
                txnId = priorTxn,
                datasetId = foldPrior.datasetId,
                guildKey = foldPrior.guildKey,
                actorGuid = foldPrior.actorGuid,
                actorName = foldPrior.actorName,
            }
            local priorAtCanonical = store.pending[canonical]
            local foldStatus, _, foldDetail, _, foldProjected =
                ClassifyIncomingAgainst(priorAtCanonical, foldPriorIncoming, canonical)
            if foldStatus == "rejected" then
                return "rejected", foldDetail or "id_conflict"
            end
            local inStatus, _, inDetail =
                ClassifyIncomingAgainst(foldProjected, assignment, canonical)
            if inStatus == "rejected" then
                return "rejected", inDetail or "id_conflict"
            end
            pendingKey = canonical
        end
        local pendingCount = CountKeys(store.pending)
        local existing = store.pending[pendingKey]
        if not existing and pendingCount >= MAX_PENDING then
            -- Folding A→C removes A before installing C, so net capacity is unchanged.
            local foldingFreesSlot = foldPrior ~= nil and store.pending[assignment.txnId] ~= nil
                and pendingKey == canonical and assignment.txnId ~= canonical
            if not foldingFreesSlot then
                return "rejected", "full"
            end
        end
        if AssignmentBoundElsewhere(record, store, assignment.assignmentId, pendingKey,
            exportCanonical, assignment.txnId) then
            return "rejected", "assignment_bound"
        end
        if foldPrior and foldPriorIncoming then
            local priorAtCanonical = store.pending[canonical]
            PatchBindingsRemoveSnap(store, foldPrior, assignment.txnId)
            store.pending[assignment.txnId] = nil
            local _, _, _, priorWrote = ApplyIncoming(store.pending, canonical, foldPriorIncoming)
            if priorWrote then
                PatchBindingsAfterApply(store, store.pending, canonical, priorAtCanonical, true)
                folded = true
            end
            pendingKey = canonical
        end
        local priorPending = store.pending[pendingKey]
        local status, _, detail, wrote = ApplyIncoming(store.pending, pendingKey, assignment)
        if wrote then
            PatchBindingsAfterApply(store, store.pending, pendingKey, priorPending, true)
        end
        if wrote or folded then
            NoteValuationStoreMutation(store, record)
            ObserveSnapSeqs(store, store.pending[pendingKey])
        end
        if status == "rejected" then
            return "rejected", detail or "id_conflict"
        end
        if status == "duplicate" then
            return "duplicate", detail or "duplicate"
        end
        if holdForCredit then
            return "pending", "awaiting_credit"
        end
        return "pending", "awaiting_donation"
    end
    if AssignmentBoundElsewhere(record, store, assignment.assignmentId, canonical,
        exportCanonical, assignment.txnId) then
        return "rejected", "assignment_bound"
    end
    local priorWinner = type(store.byTxn) == "table" and store.byTxn[canonical] or nil
    local status, changed, detail, wrote = ApplyIncoming(store.byTxn, canonical, assignment)
    if wrote then
        PatchBindingsAfterApply(store, store.byTxn, canonical, priorWinner, true)
        ObserveSnapSeqs(store, store.byTxn[canonical])
    end
    local clearedPending = false
    if type(store.pending) == "table" then
        for key in pairs(ids) do
            if store.pending[key] ~= nil then
                PatchBindingsRemoveSnap(store, store.pending[key], key)
                store.pending[key] = nil
                clearedPending = true
            end
        end
        if store.pending[assignment.txnId] ~= nil then
            PatchBindingsRemoveSnap(store, store.pending[assignment.txnId], assignment.txnId)
            store.pending[assignment.txnId] = nil
            clearedPending = true
        end
        if store.pending[canonical] ~= nil then
            PatchBindingsRemoveSnap(store, store.pending[canonical], canonical)
            store.pending[canonical] = nil
            clearedPending = true
        end
    end
    if wrote or clearedPending then
        NoteValuationStoreMutation(store, record)
    end
    if status == "rejected" then
        return "rejected", detail or "id_conflict"
    end
    if changed and ShouldPublish(record) then
        PublishWinner(record, canonical)
        DebugInfo("valuation winner txn=%s id=%s at=%s total=%s",
            tostring(canonical), tostring(assignment.assignmentId),
            tostring(assignment.assignedAt), tostring(assignment.totalCopper))
    end
    if status == "accepted" then
        return "accepted", detail or "assigned"
    end
    return "duplicate", detail or "duplicate"
end

local function ServerTime()
    if type(GetServerTime) ~= "function" then
        return nil
    end
    return NormalizeInteger(GetServerTime(), 0, MAX_EXACT - 1)
end

local function LocalActor()
    local guid = nil
    if UnitGUID then
        local raw = UnitGUID("player")
        if ValidActorGuid(raw) and raw ~= nil then
            guid = raw
        end
    end
    local name = nil
    if UnitFullName then
        local fullName = UnitFullName("player")
        if ValidActorName(fullName) and fullName ~= nil then
            name = fullName
        end
    end
    if not name and UnitName then
        local shortName = UnitName("player")
        if ValidActorName(shortName) and shortName ~= nil then
            name = shortName
        end
    end
    return guid, name
end

local function AllocateAssignmentId(record)
    local root = GS._root
    local writer = root and root.localWriter
    if type(writer) ~= "table" or type(writer.nonce) ~= "string" or not writer.nonce:match("^[0-9a-fA-F]+$")
        or #writer.nonce ~= 24 then
        return nil
    end
    local store = EnsureStore(record)
    local seq = tonumber(store.nextSeq) or 1
    if seq ~= math.floor(seq) or seq < 1 or seq > 4294967295 then
        return nil
    end
    local id = string.format("gsv1:%s:%08x", writer.nonce, seq)
    if not ValidAssignmentId(id) then
        return nil
    end
    if seq == 4294967295 then
        store.nextSeq = 4294967295
        return nil
    end
    store.nextSeq = seq + 1
    return id
end

local function QueryMarket(item)
    local TSM = SF.TSM
    if not TSM or type(TSM.GetMarketValue) ~= "function" then
        return nil
    end
    local ok, value = pcall(TSM.GetMarketValue, item)
    if not ok then
        if SF.Debug and SF.Debug.Error then
            SF.Debug:Error("GUILD_SUPPLIES", "TSM market value failed: %s", tostring(value))
        end
        return nil
    end
    -- Qty 1 is the widest legal unit. MintWithCopper rejects a total that the
    -- actual donation quantity cannot represent exactly.
    return NormalizeCopper(value, MAX_EXACT - 1)
end

-- Runtime-only DBMarket cache for one completed bank-snapshot admission.
-- Nested Begin/End; cleared at the outermost End. Not SavedVariables.
local snapshotMarketDepth = 0
local snapshotMarketCache = nil

local function MarketCacheKey(item)
    if type(item) == "number" then
        return "n:" .. tostring(item)
    end
    return "s:" .. tostring(item)
end

function GS.BeginValuationSnapshotMarketCache()
    snapshotMarketDepth = (tonumber(snapshotMarketDepth) or 0) + 1
    if snapshotMarketDepth == 1 then
        snapshotMarketCache = {}
    end
end

function GS.EndValuationSnapshotMarketCache()
    local depth = tonumber(snapshotMarketDepth) or 0
    if depth <= 0 then
        snapshotMarketDepth = 0
        snapshotMarketCache = nil
        return
    end
    depth = depth - 1
    snapshotMarketDepth = depth
    if depth == 0 then
        snapshotMarketCache = nil
    end
end

--- Query DBMarket, reusing results only while a snapshot market cache is open.
-- Ordinary mint and Logs catch-up call QueryMarket / CachedCopper directly.
local function QueryMarketForSnapshotMint(item)
    if type(snapshotMarketCache) ~= "table" then
        return QueryMarket(item)
    end
    local key = MarketCacheKey(item)
    local cached = snapshotMarketCache[key]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached
    end
    local copper = QueryMarket(item)
    if copper == nil then
        snapshotMarketCache[key] = false
        return nil
    end
    snapshotMarketCache[key] = copper
    return copper
end

local function PriceQueryItem(evidence, event)
    if type(evidence) == "table" then
        if type(evidence.itemLink) == "string" and evidence.itemLink ~= "" then
            return evidence.itemLink
        end
        if type(evidence.itemString) == "string" and evidence.itemString ~= "" then
            return evidence.itemString
        end
    end
    if type(event.itemLink) == "string" and event.itemLink ~= "" then
        return event.itemLink
    end
    if type(event.itemString) == "string" and event.itemString ~= "" then
        return event.itemString
    end
    return event.itemId
end

local function MintWithCopper(record, event, unitCopper, evidence)
    if LookupSnap(record, EventTxn(event)) then
        return false
    end
    local qty = NormalizeInteger(tonumber(event.quantity), 1, MAX_QTY)
    local itemId = NormalizeInteger(tonumber(event.itemId), 1, MAX_EXACT - 1)
    local total = qty and SafeTotal(unitCopper, qty) or nil
    if not qty or not itemId or not total then
        return false
    end
    local assignedAt = ServerTime()
    local guildKey = CurrentGuildKey()
    local txnId = ValidTxnId(EventTxn(event))
    if not assignedAt or not guildKey or not txnId then
        return false
    end
    local assignmentId = AllocateAssignmentId(record)
    if not assignmentId then
        return false
    end
    if type(record.datasetId) ~= "string" or record.datasetId == "" then
        return false
    end
    local actorGuid, actorName = LocalActor()
    local body = {
        kind = "gs-valuation",
        schemaVersion = GS.VALUATION_SCHEMA,
        datasetId = record.datasetId,
        guildKey = guildKey,
        assignment = {
            assignmentId = assignmentId,
            assignedAt = assignedAt,
            unitCopper = unitCopper,
            quantity = qty,
            totalCopper = total,
            itemId = itemId,
            txnId = txnId,
            datasetId = record.datasetId,
            guildKey = guildKey,
            actorGuid = actorGuid,
            actorName = actorName,
        },
    }
    local member = {
        guid = actorGuid,
        name = actorName,
        guildKey = guildKey,
        rankOrder = nil,
    }
    if type(GS.GetCurrentContext) == "function" then
        local ctx = GS:GetCurrentContext()
        if type(ctx) == "table" then
            member.rankOrder = ctx.rankOrder
            member.guid = ctx.actorGuid or member.guid
            member.name = ctx.actorName or member.name
        end
    end
    -- Local mint still passes through admission so realm/officer checks and
    -- the earliest-wins rule share one install path. Sender authority for a
    -- local mint is the current editor context, not the stored actor fields.
    if not GS.ValuationOfficerEligible() then
        return false
    end
    local status = select(1, GS:AdmitValuationAssignment(body, {
        member = member,
        offlineRecord = record,
        localMint = true,
    }))
    if status ~= "accepted" and status ~= "duplicate" then
        return false
    end
    return LookupSnap(record, txnId) ~= nil
end

function GS.TryAssignDonationValuation(record, event, evidence)
    if type(record) ~= "table" or type(event) ~= "table" then
        return false
    end
    if not PriceableDonation(record, event) then
        return false
    end
    if not GS.ValuationOfficerEligible() then
        return false
    end
    local current = select(1, GS:GetCurrentRecord())
    if current ~= record then
        return false
    end
    if LookupSnap(record, EventTxn(event)) then
        return false
    end
    -- Snapshot admission may reuse per-item DBMarket results for this batch.
    -- Outside Begin/EndValuationSnapshotMarketCache this is a direct query.
    local copper = QueryMarketForSnapshotMint(PriceQueryItem(evidence, event))
    if copper == nil then
        return false
    end
    return MintWithCopper(record, event, copper, evidence)
end

function GS.BuildValuationExportBody(record, canonicalTxnId)
    local snap = LookupSnap(record, canonicalTxnId)
    if type(snap) ~= "table" then
        return nil
    end
    local assignment = {
        assignmentId = snap.assignmentId,
        assignedAt = snap.assignedAt,
        unitCopper = snap.unitCopper,
        quantity = snap.quantity,
        totalCopper = snap.totalCopper,
        itemId = snap.itemId,
        txnId = snap.txnId,
        datasetId = snap.datasetId,
        guildKey = snap.guildKey,
        actorGuid = snap.actorGuid,
        actorName = snap.actorName,
    }
    return {
        kind = "gs-valuation",
        schemaVersion = GS.VALUATION_SCHEMA,
        datasetId = snap.datasetId,
        guildKey = snap.guildKey,
        assignment = assignment,
    }
end

local function FormatCopperText(copper)
    if type(copper) ~= "number" then
        return nil
    end
    if SF.FormatMoney then
        return SF.FormatMoney(copper)
    end
    copper = math.floor(copper)
    if copper < 0 then
        copper = 0
    end
    local gold = math.floor(copper / 10000)
    local remain = copper - (gold * 10000)
    local silver = math.floor(remain / 100)
    remain = remain - (silver * 100)
    return string.format("%dg %ds %dc", gold, silver, remain)
end

function GS.DescribeDonationValuation(record, event)
    local result = { priced = false }
    if not PriceableDonation(record, event) then
        return result
    end
    local snap = LookupSnap(record, EventTxn(event))
    if type(snap) ~= "table" then
        return result
    end
    local totalText = FormatCopperText(snap.totalCopper)
    local unitText = FormatCopperText(snap.unitCopper)
    if not totalText or not unitText then
        return result
    end
    result.priced = true
    result.totalCopper = snap.totalCopper
    result.unitCopper = snap.unitCopper
    result.quantity = snap.quantity
    result.totalText = totalText
    result.unitText = unitText
    result.assignmentId = snap.assignmentId
    result.assignedAt = snap.assignedAt
    return result
end

local function RetainedEventCount(record)
    local accounting = record and record.accounting
    if type(accounting) ~= "table" then
        return 0
    end
    local n = 0
    if type(accounting._consumableEvents) == "table" then
        n = n + #accounting._consumableEvents
    end
    if type(accounting._consumableEventArchive) == "table" then
        n = n + #accounting._consumableEventArchive
    end
    return n
end

local function ResetCatchupWork()
    catchup.queue = {}
    catchup.queued = {}
    catchup.scanPhase = "live"
    catchup.scanIndex = 1
    catchup.scanDone = false
    catchup.lastVisits = 0
    catchup.cache = {}
end

--- One forward step across the live list, then the archive. Nil means the
-- scan is exhausted. Index movement is O(1); callers bound how many steps run.
local function NextScanEvent(record)
    while true do
        local accounting = record and record.accounting
        local list = nil
        if type(accounting) == "table" then
            if catchup.scanPhase == "archive" then
                list = accounting._consumableEventArchive
            else
                list = accounting._consumableEvents
            end
        end
        if type(list) ~= "table" then
            if catchup.scanPhase ~= "archive" then
                catchup.scanPhase = "archive"
                catchup.scanIndex = 1
            else
                catchup.scanDone = true
                return nil
            end
        else
            local index = tonumber(catchup.scanIndex) or 1
            if index < 1 then
                index = 1
            end
            if index > #list then
                if catchup.scanPhase ~= "archive" then
                    catchup.scanPhase = "archive"
                    catchup.scanIndex = 1
                else
                    catchup.scanDone = true
                    return nil
                end
            else
                local event = list[index]
                catchup.scanIndex = index + 1
                return event
            end
        end
    end
end

local function DiscoverUnpriced(record, gen)
    local visits = 0
    local queue = catchup.queue or {}
    local queued = catchup.queued or {}
    catchup.queue = queue
    catchup.queued = queued
    while visits < SCAN do
        if gen ~= catchup.generation then
            break
        end
        local event = NextScanEvent(record)
        if not event then
            break
        end
        visits = visits + 1
        if PriceableDonation(record, event) then
            local txn = EventTxn(event)
            local _, canonical = AliasSet(record, txn)
            canonical = canonical or txn
            if canonical and not queued[canonical] and not LookupSnap(record, canonical) then
                queued[canonical] = true
                queue[#queue + 1] = canonical
            end
        end
    end
    catchup.lastVisits = visits
    return visits
end

local function CachedCopper(item)
    if type(catchup.cache) ~= "table" then
        catchup.cache = {}
    end
    local key = MarketCacheKey(item)
    local cached = catchup.cache[key]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached
    end
    local copper = QueryMarket(item)
    if copper == nil then
        catchup.cache[key] = false
        return nil
    end
    catchup.cache[key] = copper
    return copper
end

local function PriceQueued(record, gen)
    local queue = catchup.queue or {}
    local pos = 1
    local attempts = 0
    while attempts < BATCH and pos <= #queue do
        if gen ~= catchup.generation then
            return
        end
        local txnId = queue[pos]
        pos = pos + 1
        attempts = attempts + 1
        if not LookupSnap(record, txnId) then
            local ids = AliasSet(record, txnId)
            -- Caller (ProcessCatchupSlice) warms the index to completion first.
            local event = select(1, FindEventForIds(record, ids))
            if event and PriceableDonation(record, event) then
                local copper = CachedCopper(PriceQueryItem(nil, event))
                if copper ~= nil then
                    MintWithCopper(record, event, copper, nil)
                end
            end
        end
    end
    if pos > 1 then
        local rest = {}
        for i = pos, #queue do
            rest[#rest + 1] = queue[i]
        end
        catchup.queue = rest
    end
end

local function ProcessCatchupSlice(gen)
    if gen ~= catchup.generation then
        return false
    end
    if not GS.ValuationOfficerEligible() then
        return false
    end
    local record = select(1, GS:GetCurrentRecord())
    if type(record) ~= "table" or record.datasetId ~= catchup.datasetId
        or not (GS.IsLiveActive and GS.IsLiveActive(record)) then
        return false
    end
    catchup.lastVisits = 0
    -- Budgeted index warm shares the catch-up After(0) continuation so pricing
    -- never peeks an empty cold index and drops queued donations.
    if GS.WarmDonationEventIndex then
        local idxComplete = select(1, GS.WarmDonationEventIndex(
            record, GS.DONATION_EVENT_INDEX_BUDGET))
        if not idxComplete then
            return true
        end
    end
    local queued = #(catchup.queue or {})
    if queued < BATCH and not catchup.scanDone then
        DiscoverUnpriced(record, gen)
    end
    if gen ~= catchup.generation then
        return false
    end
    PriceQueued(record, gen)
    if gen ~= catchup.generation then
        return false
    end
    return #(catchup.queue or {}) > 0 or catchup.scanDone ~= true
end

local function IdleCatchup()
    catchup.active = false
    catchup.scheduled = false
    catchup.queue = nil
    catchup.queued = nil
    catchup.cache = nil
end

local function ScheduleCatchup(gen)
    if gen ~= catchup.generation then
        return
    end
    if not (C_Timer and C_Timer.After) then
        ProcessCatchupSlice(gen)
        IdleCatchup()
        return
    end
    catchup.scheduled = true
    C_Timer.After(0, function()
        if gen ~= catchup.generation then
            return
        end
        catchup.scheduled = false
        local more = ProcessCatchupSlice(gen)
        if more and gen == catchup.generation then
            ScheduleCatchup(gen)
        elseif gen == catchup.generation then
            IdleCatchup()
        end
    end)
end

function GS.CancelValuationCatchup(reason)
    catchup.generation = (tonumber(catchup.generation) or 0) + 1
    catchup.datasetId = nil
    catchup.scanPhase = "live"
    catchup.scanIndex = 1
    catchup.scanDone = true
    catchup.lastVisits = 0
    IdleCatchup()
    if reason and reason ~= "restart" then
        DebugInfo("valuation catch-up cancelled reason=%s", tostring(reason))
    end
end

function GS.StartValuationCatchup(reason)
    GS.CancelValuationCatchup("restart")
    local gen = catchup.generation
    if not GS.ValuationOfficerEligible() then
        return false
    end
    local record = select(1, GS:GetCurrentRecord())
    if type(record) ~= "table" or not (GS.IsLiveActive and GS.IsLiveActive(record)) then
        return false
    end
    -- Counting retained rows is O(1). Discovering which of them are unpriced
    -- walks the ledger and resolves aliases, so that work stays on the timer.
    if RetainedEventCount(record) < 1 then
        return false
    end
    catchup.active = true
    catchup.datasetId = record.datasetId
    ResetCatchupWork()
    DebugInfo("valuation catch-up start reason=%s", tostring(reason or "logs"))
    ScheduleCatchup(gen)
    return true
end

function GS.GetValuationCatchupState()
    return {
        active = catchup.active and true or false,
        scheduled = catchup.scheduled and true or false,
        generation = catchup.generation,
        datasetId = catchup.datasetId,
        index = tonumber(catchup.scanIndex) or 1,
        backlog = catchup.queue and #catchup.queue or 0,
        lastVisits = tonumber(catchup.lastVisits) or 0,
        scanDone = catchup.scanDone == true,
    }
end
