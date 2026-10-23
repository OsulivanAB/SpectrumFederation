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

local function NoteValuationStoreMutation(store, record)
    if type(store) ~= "table" then
        return
    end
    local rev = (valuationStoreRev[store] or 0) + 1
    if rev > 4294967295 then
        rev = 1
    end
    valuationStoreRev[store] = rev
    local cached = valuationValidationCache[store]
    local datasetId = type(record) == "table" and record.datasetId or nil
    if cached and cached.ok and type(datasetId) == "string" and cached.datasetId == datasetId then
        cached.rev = rev
    else
        valuationValidationCache[store] = nil
    end
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
                if fn(list[i]) then
                    return list[i]
                end
            end
        end
    end
    return nil
end

local function FindEventForIds(record, ids)
    if type(ids) ~= "table" then
        return nil
    end
    return VisitEvents(record, function(event)
        local txn = EventTxn(event)
        return txn and ids[txn] == true
    end)
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

local function ValidAssignmentId(id)
    return type(id) == "string"
        and id ~= ""
        and #id <= (GS.MAX_OPERATION_ID or 192)
        and id:match("^gsv1:[0-9a-fA-F]+:[0-9a-fA-F]+$") ~= nil
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

--- Install or reject one normalized assignment into a byTxn/pending bucket.
-- @return status string, changed bool, reason string|nil
local function ApplyIncoming(bucket, key, incoming)
    local snap = bucket[key]
    local fp = Fingerprint(incoming)
    if type(snap) ~= "table" then
        bucket[key] = CopySnap(incoming, key)
        return "accepted", true, nil, true
    end
    local winnerFp = Fingerprint(snap)
    if incoming.assignmentId == snap.assignmentId then
        if fp == winnerFp then
            return "duplicate", false, "duplicate", false
        end
        return "rejected", false, "id_conflict", false
    end
    local seenRow = SeenHas(snap.seen, incoming.assignmentId)
    if seenRow then
        if seenRow.fp == fp then
            return "duplicate", false, "duplicate", false
        end
        return "rejected", false, "id_conflict", false
    end
    local earlier = incoming.assignedAt < snap.assignedAt
        or (incoming.assignedAt == snap.assignedAt and incoming.assignmentId < snap.assignmentId)
    if earlier then
        local oldId = snap.assignmentId
        local seen = snap.seen
        local replacement = CopySnap(incoming, key)
        replacement.seen = type(seen) == "table" and seen or {}
        RememberLoser(replacement, oldId, winnerFp)
        bucket[key] = replacement
        return "accepted", true, "earlier_assignment", true
    end
    if type(snap.seen) ~= "table" then
        snap.seen = {}
    end
    if #snap.seen < MAX_SEEN then
        snap.seen[#snap.seen + 1] = { id = incoming.assignmentId, fp = fp }
        return "duplicate", false, "later_assignment", true
    end
    return "duplicate", false, "later_assignment", false
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

local function RemoveValuationExports(record, ids)
    -- Temporary adoption records must not edit the active dataset's exports.
    if not ShouldPublish(record) then
        return
    end
    if not GS.RemoveGossipExportBodies then
        return
    end
    local list = {}
    for key in pairs(ids) do
        list[#list + 1] = "gs:val:" .. tostring(key)
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

function GS.ForgetDonationValuations(record, txnIds)
    if type(record) ~= "table" or type(txnIds) ~= "table" then
        return
    end
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
        for key, snap in pairs(bucket) do
            local snapTxn = type(snap) == "table" and snap.txnId or nil
            local canonical = type(snap) == "table" and snap.canonicalTxnId or nil
            if drop[key] or (snapTxn and drop[snapTxn]) or (canonical and drop[canonical]) then
                remove[#remove + 1] = key
                drop[key] = true
            end
        end
        for i = 1, #remove do
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
    RemoveValuationExports(record, drop)
end

local function MergeOntoCanonical(record, canonical, incoming, changed)
    if type(incoming) ~= "table" then
        return changed
    end
    local eventIds = AliasSet(record, canonical)
    local event = FindEventForIds(record, eventIds)
    if not event or not PriceableDonation(record, event) or not DonationMatches(incoming, event) then
        return changed
    end
    local store = EnsureStore(record)
    local _, did, _, wrote = ApplyIncoming(store.byTxn, canonical, incoming)
    if wrote then
        NoteValuationStoreMutation(store, record)
    end
    return changed or did == true
end

function GS.ReconcilePendingValuations(record, txnId)
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
    local event = FindEventForIds(record, ids)
    if event and not PriceableDonation(record, event) then
        if CreditStillUnresolved(record, event) then
            return false
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
                store.byTxn[key] = nil
                removed = true
            end
        end
        local fromPending = type(store.pending) == "table" and store.pending[key] or nil
        if fromPending ~= nil and type(store.pending) == "table" then
            store.pending[key] = nil
            removed = true
        end
        changed = MergeOntoCanonical(record, canonical, fromWinner, changed)
        changed = MergeOntoCanonical(record, canonical, fromPending, changed)
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

--- After a cutover classifies retained rows, fold still-pending assignments.
-- One bounded pass. Priceable rows merge with earliest-wins. Rows that are
-- now definitively unpriceable are discarded. Not a timer.
function GS.ReconcileValuationsAfterCreditChange(record)
    if type(record) ~= "table" then
        return
    end
    local store = record.valuations
    local pending = type(store) == "table" and store.pending or nil
    if type(pending) ~= "table" then
        return
    end
    local keys = {}
    for key in pairs(pending) do
        if #keys >= MAX_PENDING then
            break
        end
        keys[#keys + 1] = key
    end
    for i = 1, #keys do
        if type(store.pending) == "table" and store.pending[keys[i]] ~= nil then
            GS.ReconcilePendingValuations(record, keys[i])
        end
    end
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
                    wrote = true
                end
            end
        end
    end
    return wrote
end

function GS.OnDonationTxnAlias(record, primaryTxnId, aliasTxnId)
    if type(record) ~= "table" then
        return
    end
    local canonical = ResolveCanonical(record, primaryTxnId) or ValidTxnId(primaryTxnId)
    local alias = ValidTxnId(aliasTxnId)
    if not canonical or not alias or canonical == alias then
        return
    end
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
        store.byTxn[alias] = nil
        removed = true
    end
    if type(store.pending) == "table" then
        if store.pending[alias] ~= nil then
            store.pending[alias] = nil
            removed = true
        end
        if store.pending[canonical] ~= nil then
            store.pending[canonical] = nil
            removed = true
        end
    end
    local ids = AliasSet(record, canonical)
    local event = FindEventForIds(record, ids)
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
        changed = MergeOntoCanonical(record, canonical, candidates[i].snap, changed)
    end
    RemoveValuationExports(record, { [alias] = true })
    if changed and ShouldPublish(record) then
        PublishWinner(record, canonical)
        DebugInfo("valuation alias txn=%s alias=%s", tostring(canonical), tostring(alias))
    end
end

--- Admit one gossip or adoption valuation body.
-- Transport sender authority is opts.member. Actor fields are stored, not trusted.
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
    local ids, canonical = AliasSet(record, assignment.txnId)
    if not canonical then
        return "rejected", "invalid_txn"
    end
    local event = FindEventForIds(record, ids)
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
        -- Alias fold may already keep the earliest pending row under the
        -- canonical lookup key while the assignment body still names its
        -- original transaction id. Prefer that key so redelivery stays a
        -- fingerprint duplicate instead of a second pending row.
        local pendingKey = assignment.txnId
        if type(store.pending) == "table" then
            if store.pending[canonical] ~= nil then
                pendingKey = canonical
            elseif store.pending[assignment.txnId] == nil then
                for key in pairs(ids) do
                    if store.pending[key] ~= nil then
                        pendingKey = key
                        break
                    end
                end
            end
        end
        local pendingCount = CountKeys(store.pending)
        local existing = store.pending[pendingKey]
        if not existing and pendingCount >= MAX_PENDING then
            return "rejected", "full"
        end
        local status, _, detail, wrote = ApplyIncoming(store.pending, pendingKey, assignment)
        if wrote then
            NoteValuationStoreMutation(store, record)
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
    local status, changed, detail, wrote = ApplyIncoming(store.byTxn, canonical, assignment)
    local clearedPending = false
    if type(store.pending) == "table" then
        for key in pairs(ids) do
            if store.pending[key] ~= nil then
                store.pending[key] = nil
                clearedPending = true
            end
        end
        if store.pending[assignment.txnId] ~= nil then
            store.pending[assignment.txnId] = nil
            clearedPending = true
        end
        if store.pending[canonical] ~= nil then
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
    local copper = QueryMarket(PriceQueryItem(evidence, event))
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

local function CacheKey(item)
    if type(item) == "number" then
        return "n:" .. tostring(item)
    end
    return "s:" .. tostring(item)
end

local function CachedCopper(item)
    if type(catchup.cache) ~= "table" then
        catchup.cache = {}
    end
    local key = CacheKey(item)
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
            local event = FindEventForIds(record, ids)
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
