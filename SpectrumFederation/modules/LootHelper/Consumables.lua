-- Raid Consumables domain, ledger, and projections.
-- Configuration lives on the LootProfile. Accounting is append-only events.
local _, SF = ...

SF.Consumables = SF.Consumables or {}
local C = SF.Consumables

local function Loc(key, default)
    if SF.LocaleText then
        return SF.LocaleText(key, default)
    end
    return default or key
end

C.EVENT = {
    DONATION = "CONSUMABLE_DONATION",
    RESET = "CONSUMABLE_CONFIG_RESET",
    -- Legacy event type strings may still appear in archived development data.
    RECEIPT = "CONSUMABLE_CRAFTER_RECEIPT",
    CUSTODY = "CONSUMABLE_CUSTODY",
    RESOLVE = "CONSUMABLE_CUSTODY_RESOLVE",
}

C.MAX_REQUESTED_ITEMS = 256
C.MAX_ASSIGNMENT_PAIRS = C.MAX_REQUESTED_ITEMS -- alias for older callers/tests
C.MAX_LEDGER_EVENTS = 4096
C.MAX_ARCHIVED_EVENTS = 4096
C.MAX_VISIBLE_HISTORY = 200
C.MAX_EVENTS_PER_ACTOR = 512
C.MAX_EVENT_SEQ = 2147483647
C.MAX_EVENT_ID = 192
C.MAX_EVENT_NAME = 64
C.MAX_GOAL = 100000
C.MAX_TXN_ID = 160
C.MAX_TXN_REGISTRY = 512
-- One-time migration marker for Guild Bank observation accounting (Issue #366 PR2).
C.OBS_ACCOUNTING_SCHEMA = 1

local projectionCache = setmetatable({}, { __mode = "k" })
local listeners = {}
local notifying = false

local function Debug(level, message, ...)
    if SF.Debug and SF.Debug[level] then
        SF.Debug[level](SF.Debug, "CONSUMABLES", message, ...)
    end
end

local function Now()
    if type(C._clock) == "function" then
        return C._clock()
    end
    return time()
end

C.Now = Now

local function Same(a, b)
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b) and true or false
    end
    return a ~= nil and a == b
end

local function Norm(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(name) or name
    end
    return name
end

local function IsItemId(itemId)
    return type(itemId) == "number" and itemId > 0 and itemId == math.floor(itemId)
end

local function IsBankTab(tab)
    return type(tab) == "number" and tab >= 1 and tab <= 8 and tab == math.floor(tab)
end

local function ItemKey(itemId)
    return tostring(itemId)
end

local function SortedCopy(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, #list do
        local name = Norm(list[i])
        if name then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end

local function SameSet(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function Contains(list, name)
    for i = 1, #list do
        if Same(list[i], name) then return true end
    end
    return false
end

local function Without(list, name)
    local out = {}
    for i = 1, #list do
        if not Same(list[i], name) then
            out[#out + 1] = list[i]
        end
    end
    return out
end

local function Notify()
    if notifying then return end
    notifying = true
    for i = 1, #listeners do
        local fn = listeners[i]
        if type(fn) == "function" then
            local ok, err = pcall(fn)
            if not ok then
                Debug("Error", "UI listener failed: %s", tostring(err))
            end
        end
    end
    notifying = false
end

function C.RegisterUIListener(fn)
    if type(fn) ~= "function" then return nil end
    listeners[#listeners + 1] = fn
    return fn
end

-- Explicit UI poke for sync-driven refreshes (review summaries, remote decisions).
function C.NotifyUI()
    Notify()
end

local function Invalidate(profile)
    projectionCache[profile] = nil
end

local FINGERPRINT_MOD = 1000000007

local function Xor32(a, b)
    a = math.floor((tonumber(a) or 0) % 4294967296)
    b = math.floor((tonumber(b) or 0) % 4294967296)
    local result = 0
    local bitValue = 1
    for _ = 1, 32 do
        if (a % 2) ~= (b % 2) then
            result = result + bitValue
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bitValue = bitValue * 2
    end
    return result
end

local HASH_BYTES = 256
local BODY_HASH_BYTES = 1024
local CopyEvent

local function HashText(text, limit)
    if type(text) ~= "string" or text == "" then return 0 end
    local hash = 2166136261 % FINGERPRINT_MOD
    local size = #text
    if size > limit then size = limit end
    for i = 1, size do
        hash = (hash * 131 + string.byte(text, i)) % FINGERPRINT_MOD
    end
    return hash
end

local function IdHash(id)
    return HashText(id, HASH_BYTES)
end

local function MixConfigText(hash, text)
    return Xor32(hash, IdHash(text))
end

local function FingerprintToken(id, order)
    if type(id) ~= "string" or id == "" then return nil end
    order = tonumber(order)
    if order and order > 0 then
        return id .. "\0" .. tostring(math.floor(order))
    end
    return id
end

local function BodyText(value)
    if value == nil then return "" end
    return tostring(value)
end

local function BodyNumber(value)
    local number = tonumber(value)
    if not number then return "" end
    return tostring(number)
end

-- Accounting fields only. Order and timestamp stay out so a stamp or a clock
-- does not look like a different event, and a changed quantity does.
local function BodyToken(event)
    if type(event) ~= "table" then return nil end
    local copy = CopyEvent(event)
    return table.concat({
        BodyText(copy.type),
        BodyNumber(copy.generation),
        BodyText(copy.actor),
        BodyNumber(copy.itemId),
        BodyNumber(copy.quantity),
        BodyText(copy.source),
        BodyText(copy.crafter),
        BodyNumber(copy.epoch),
        BodyText(copy.action),
        BodyText(copy.holder),
        BodyText(copy.fromHolder),
        BodyText(copy.toHolder),
        BodyText(copy.writer),
        BodyText(copy.tradeToken),
        BodyText(copy.withdrawToken),
        BodyText(copy.reason),
        BodyText(copy.txnId),
        BodyText(copy.verification),
        BodyNumber(copy.goldValueCopper),
    }, "\0")
end

local function MixFingerprint(current, id, order, event)
    local token = FingerprintToken(id, order)
    if not token then return tonumber(current) or 0 end
    local mixed = Xor32(current or 0, IdHash(token))
    local body = BodyToken(event)
    if body then
        mixed = Xor32(mixed, HashText(body, BODY_HASH_BYTES))
    end
    return mixed
end

local function RetargetFingerprint(cfg, id, oldOrder, newOrder)
    if type(cfg) ~= "table" then return end
    local oldToken = FingerprintToken(id, oldOrder)
    local newToken = FingerprintToken(id, newOrder)
    if oldToken == newToken then return end
    local fingerprint = tonumber(cfg.eventFingerprint) or 0
    if oldToken then fingerprint = Xor32(fingerprint, IdHash(oldToken)) end
    if newToken then fingerprint = Xor32(fingerprint, IdHash(newToken)) end
    cfg.eventFingerprint = fingerprint
end

local function AdoptedEventSeq(id)
    if type(id) ~= "string" then return nil end
    local digits = id:match(":(%d+)$")
    if not digits then return nil end
    local seq = tonumber(digits)
    if not seq or seq ~= math.floor(seq) or seq < 1 or seq > C.MAX_EVENT_SEQ then
        return nil
    end
    return seq
end

local function ArchiveStats(profile)
    local archive = profile._consumableEventArchive
    local fingerprint = 0
    local count = 0
    if type(archive) == "table" then
        count = #archive
        for i = 1, count do
            local archived = archive[i]
            if type(archived) == "table" then
                fingerprint = MixFingerprint(fingerprint, archived.id, archived.order, archived)
            end
        end
    end
    return count, fingerprint
end

local function StoreArchiveStats(profile)
    local cfg = profile._consumables
    if type(cfg) ~= "table" then return end
    local count, fingerprint = ArchiveStats(profile)
    cfg.archiveCount = count
    cfg.archiveFingerprint = fingerprint
end

local function RetargetArchiveFingerprint(cfg, id, oldOrder, newOrder)
    if type(cfg) ~= "table" then return end
    local oldToken = FingerprintToken(id, oldOrder)
    local newToken = FingerprintToken(id, newOrder)
    if oldToken == newToken then return end
    local fingerprint = tonumber(cfg.archiveFingerprint) or 0
    if oldToken then fingerprint = Xor32(fingerprint, IdHash(oldToken)) end
    if newToken then fingerprint = Xor32(fingerprint, IdHash(newToken)) end
    cfg.archiveFingerprint = fingerprint
end

local function IsArchivedRecord(profile, stored)
    if type(profile) ~= "table" or type(stored) ~= "table" then return false end
    local archive = profile._consumableEventArchive
    if type(archive) ~= "table" then return false end
    for i = 1, #archive do
        if archive[i] == stored then return true end
    end
    return false
end

local function EventQuotaKey(event)
    if type(event) ~= "table" then return nil end
    local key = Norm(event.writer)
    if not key then key = Norm(event.actor) end
    if key and #key > C.MAX_EVENT_NAME then return nil end
    return key
end

local ANON_QUOTA = {}

local function QuotaBucket(event)
    return EventQuotaKey(event) or ANON_QUOTA
end

local function ArchiveQuotaExempt(event)
    return type(event) == "table" and event.type == C.EVENT.RESET
end

local function NoteArchiveQuota(counts, event)
    if ArchiveQuotaExempt(event) then return end
    local key = QuotaBucket(event)
    counts[key] = (counts[key] or 0) + 1
end

local function NoteQuota(counts, event)
    if type(event) ~= "table" then return end
    local gen = tonumber(event.generation)
    if not gen then return end
    local row = counts[gen]
    if not row then
        row = {}
        counts[gen] = row
    end
    local key = QuotaBucket(event)
    row[key] = (row[key] or 0) + 1
end

local function IsLiveRecord(profile, stored)
    if type(profile) ~= "table" or type(stored) ~= "table" then return false end
    local events = profile._consumableEvents
    if type(events) ~= "table" then return false end
    for i = 1, #events do
        if events[i] == stored then return true end
    end
    return false
end

-- The index is rebuilt once per login and kept beside the profile. Saving it on
-- the profile would write a second copy of every ledger record.
local eventIndexes = setmetatable({}, { __mode = "k" })
local indexBound = setmetatable({}, { __mode = "k" })

local function EventIds(profile)
    local bound = eventIndexes[profile]
    if not bound then
        bound = { ids = {}, count = 0 }
        eventIndexes[profile] = bound
    end
    return bound
end

function C.EventIndex(profile)
    if type(profile) ~= "table" then return {} end
    C.Ensure(profile)
    return EventIds(profile).ids
end

function C.InvalidateEventIndex(profile)
    if type(profile) == "table" then
        indexBound[profile] = nil
        eventIndexes[profile] = nil
    end
end

local function ValidTxnId(txnId)
    if type(txnId) ~= "string" or txnId == "" or #txnId > C.MAX_TXN_ID then
        return nil
    end
    if not txnId:match("^ctx:") then
        return nil
    end
    return txnId
end

C.ValidTxnId = ValidTxnId

local function ValidGoldValueCopper(value)
    if value == nil then return nil end
    local n = tonumber(value)
    if not n or n ~= math.floor(n) or n < 0 then
        return nil
    end
    return n
end

local function RebuildIndex(profile)
    local index = {}
    local txnIds = {}
    local actorCounts = {}
    local events = profile._consumableEvents or {}
    local maxSeq = 0
    local maxOrder = 0
    local fingerprint = 0
    for i = 1, #events do
        local event = events[i]
        if type(event) == "table" and type(event.id) == "string" then
            index[event.id] = event
            local txnId = ValidTxnId(event.txnId)
            if txnId then txnIds[txnId] = event end
            NoteQuota(actorCounts, event)
            local seq = AdoptedEventSeq(event.id)
            if seq and seq > maxSeq then maxSeq = seq end
            local order = tonumber(event.order)
            if order and order > maxOrder then maxOrder = order end
            fingerprint = MixFingerprint(fingerprint, event.id, event.order, event)
        end
    end
    local archiveCounts = {}
    local archive = profile._consumableEventArchive
    if type(archive) == "table" then
        for i = 1, #archive do
            local archived = archive[i]
            if type(archived) == "table" and type(archived.id) == "string" then
                index[archived.id] = archived
                local txnId = ValidTxnId(archived.txnId)
                if txnId and not txnIds[txnId] then txnIds[txnId] = archived end
                local seq = AdoptedEventSeq(archived.id)
                if seq and seq > maxSeq then maxSeq = seq end
                NoteArchiveQuota(archiveCounts, archived)
            end
        end
    end
    local bound = EventIds(profile)
    bound.ids = index
    bound.txnIds = txnIds
    bound.actorCounts = actorCounts
    bound.archiveCounts = archiveCounts
    bound.count = #events
    profile._consumableEventIds = nil
    profile._consumableIndexCount = nil
    local cfg = profile._consumables
    if cfg then
        if maxSeq > (tonumber(cfg.eventSeq) or 0) then
            cfg.eventSeq = maxSeq
        end
        if maxOrder > (tonumber(cfg.ledgerSeq) or 0) then
            cfg.ledgerSeq = maxOrder
        end
        cfg.eventFingerprint = fingerprint
        StoreArchiveStats(profile)
    end
end

-- Non-negative whole-number goal. Missing/nil is not valid here; callers that
-- migrate legacy rows supply 0 explicitly. Explicit malformed values return nil.
function C.ValidGoal(value)
    local goal = tonumber(value)
    if not goal or goal ~= goal or goal == math.huge or goal == -math.huge then
        return nil
    end
    if goal ~= math.floor(goal) or goal < 0 or goal > C.MAX_GOAL then
        return nil
    end
    return goal
end

local function GoalFromRow(row)
    if type(row) ~= "table" or row.goal == nil then
        return 0
    end
    return C.ValidGoal(row.goal)
end

local function CopyRequestedMap(source)
    local out = {}
    if type(source) ~= "table" then return out end
    local count = 0
    local keys = {}
    for key, row in pairs(source) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for i = 1, #keys do
        if count >= C.MAX_REQUESTED_ITEMS then break end
        local key = keys[i]
        local row = source[key]
        local itemId = nil
        if type(row) == "table" then
            itemId = tonumber(row.itemId) or tonumber(key)
        else
            itemId = tonumber(key) or tonumber(row)
        end
        if IsItemId(itemId) then
            -- Legacy rows without goal migrate to 0 / No Goal. Corrupt local
            -- goals also normalize to 0 here; sync/config input is validated
            -- separately and rejects explicit malformed goals.
            local goal = GoalFromRow(row)
            if goal == nil then
                goal = 0
            end
            out[ItemKey(itemId)] = { itemId = itemId, goal = goal }
            count = count + 1
        end
    end
    return out
end

function C.ValidateRequestedItems(map)
    if map == nil then return true end
    if type(map) ~= "table" then
        return false, "snapshot.consumables.requestedItems must be a table"
    end
    for key, row in pairs(map) do
        if type(row) == "table" and row.goal ~= nil then
            if C.ValidGoal(row.goal) == nil then
                return false, "snapshot.consumables.requestedItems.goal must be a non-negative whole number"
            end
        end
        local itemId = nil
        if type(row) == "table" then
            itemId = tonumber(row.itemId) or tonumber(key)
        else
            itemId = tonumber(key) or tonumber(row)
        end
        if itemId ~= nil and not IsItemId(itemId) then
            -- Invalid item ids are dropped by CopyRequestedMap; do not fail the
            -- whole payload for legacy junk keys.
        end
    end
    return true
end

local function NormalizeRequestedItems(cfg)
    if type(cfg.requestedItems) == "table" then
        cfg.requestedItems = CopyRequestedMap(cfg.requestedItems)
    else
        local migrated = {}
        -- Development-era Crafter assignments: union of assigned exact items.
        if type(cfg.assignments) == "table" then
            for key, row in pairs(cfg.assignments) do
                if type(row) == "table" then
                    local crafters = row.crafters
                    local itemId = tonumber(row.itemId) or tonumber(key)
                    if IsItemId(itemId) and type(crafters) == "table" and #crafters > 0 then
                        migrated[ItemKey(itemId)] = { itemId = itemId, goal = 0 }
                    elseif IsItemId(itemId) and crafters == nil and row.itemId then
                        -- Already a flat requested row under the old key name.
                        local goal = GoalFromRow(row)
                        if goal == nil then goal = 0 end
                        migrated[ItemKey(itemId)] = { itemId = itemId, goal = goal }
                    end
                end
            end
        end
        cfg.requestedItems = CopyRequestedMap(migrated)
    end
    -- Discard obsolete Crafter-era persisted fields.
    cfg.crafters = nil
    cfg.assignments = nil
    cfg.itemEpochs = nil
    -- Also drop development-era freeze grants persisted beside the profile.
end

local function EnsureEligibility(cfg)
    if type(cfg.eligibility) ~= "table" then
        cfg.eligibility = { items = {}, tabEligibleFrom = nil }
    end
    if type(cfg.eligibility.items) ~= "table" then
        cfg.eligibility.items = {}
    end
    return cfg.eligibility
end

local function EnsureRejections(cfg)
    if type(cfg.rejections) ~= "table" then
        cfg.rejections = {}
    end
    return cfg.rejections
end

local function EnsurePendingWitnesses(cfg)
    if type(cfg.pendingWitnesses) ~= "table" then
        cfg.pendingWitnesses = {}
    end
    return cfg.pendingWitnesses
end

-- Forward-declared: C.Ensure calls this before the full registry helpers load.
local function EnsureTxnRegistry(cfg)
    if type(cfg.txnRegistry) ~= "table" then
        cfg.txnRegistry = {}
    end
    local seq = tonumber(cfg.txnAllocSeq)
    if not seq or seq ~= seq or seq ~= math.floor(seq) or seq < 0 then
        cfg.txnAllocSeq = 0
    else
        cfg.txnAllocSeq = seq
    end
    return cfg.txnRegistry
end

local function CopyWitnessMap(witnesses)
    local out = {}
    if type(witnesses) ~= "table" then return out end
    local count = 0
    for key, meta in pairs(witnesses) do
        if type(key) == "string" and key ~= "" and count < 16 then
            if type(meta) == "table" then
                out[key] = {
                    submittedBy = type(meta.submittedBy) == "string" and meta.submittedBy or key,
                    observedBy = type(meta.observedBy) == "string" and meta.observedBy or nil,
                    firstReported = tonumber(meta.firstReported),
                }
            else
                out[key] = { submittedBy = key }
            end
            count = count + 1
        end
    end
    return out
end

local function CopyPendingWitnessList(list)
    local out = {}
    if type(list) ~= "table" then return out end
    local V = SF.ConsumablesVerification
    local maxN = (V and V.MAX_PENDING_WITNESS_AGGREGATES) or 128
    local limit = #list
    if limit > maxN then limit = maxN end
    for i = 1, limit do
        local row = list[i]
        if type(row) == "table" and type(row.evidence) == "table"
            and type(row.evidence.coreSignature) == "string"
        then
            out[#out + 1] = {
                evidence = {
                    coreSignature = row.evidence.coreSignature,
                    approxTxnTime = tonumber(row.evidence.approxTxnTime),
                    donor = type(row.evidence.donor) == "string" and row.evidence.donor or nil,
                    itemId = tonumber(row.evidence.itemId),
                    quantity = tonumber(row.evidence.quantity),
                    guildGuid = type(row.evidence.guildGuid) == "string" and row.evidence.guildGuid or nil,
                    bankTab = tonumber(row.evidence.bankTab),
                    generation = tonumber(row.evidence.generation),
                    occurrenceIndex = tonumber(row.evidence.occurrenceIndex),
                    neighborsOlder = type(row.evidence.neighborsOlder) == "table" and row.evidence.neighborsOlder or nil,
                    neighborsNewer = type(row.evidence.neighborsNewer) == "table" and row.evidence.neighborsNewer or nil,
                    type = type(row.evidence.type) == "string" and row.evidence.type or "deposit",
                },
                witnesses = CopyWitnessMap(row.witnesses),
                updatedAt = tonumber(row.updatedAt),
            }
        end
    end
    return out
end

-- Forward decl: used by peer-path witness merge before the full definition.
local PendingWitnessMatches

local function ReplacePendingWitnessesFromPayload(cfg, payload, opts)
    opts = opts or {}
    if type(payload) ~= "table" or type(payload.pendingWitnesses) ~= "table" then
        return EnsurePendingWitnesses(cfg)
    end
    -- Authoritative snapshots replace. Peer recovery must not wipe coordinator-
    -- authenticated aggregates and must not import peer-asserted witness names
    -- into quorum (witnesses are authenticated only on the coordinator path).
    if opts.forceReplace == true then
        cfg.pendingWitnesses = CopyPendingWitnessList(payload.pendingWitnesses)
        return cfg.pendingWitnesses
    end
    return EnsurePendingWitnesses(cfg)
end

local function CopyEligibility(eligibility)
    if type(eligibility) ~= "table" then
        return { items = {}, tabEligibleFrom = nil, baselineEstablished = false }
    end
    local items = {}
    if type(eligibility.items) == "table" then
        for key, value in pairs(eligibility.items) do
            local ts = tonumber(value)
            if ts then
                items[tostring(key)] = ts
            end
        end
    end
    return {
        items = items,
        tabEligibleFrom = tonumber(eligibility.tabEligibleFrom),
        baselineEstablished = eligibility.baselineEstablished == true,
        baselineAt = tonumber(eligibility.baselineAt),
    }
end

-- Later cutover timestamps win so followers never loosen an established boundary.
local function MergeEligibilityInto(cfg, remote)
    local localElig = EnsureEligibility(cfg)
    if type(remote) ~= "table" then return localElig end
    if remote.baselineEstablished == true then
        localElig.baselineEstablished = true
        local remoteAt = tonumber(remote.baselineAt)
        local localAt = tonumber(localElig.baselineAt)
        if remoteAt and (not localAt or remoteAt < localAt) then
            localElig.baselineAt = remoteAt
        elseif not localAt and remoteAt then
            localElig.baselineAt = remoteAt
        end
    end
    local remoteTab = tonumber(remote.tabEligibleFrom)
    local localTab = tonumber(localElig.tabEligibleFrom)
    if remoteTab and (not localTab or remoteTab > localTab) then
        localElig.tabEligibleFrom = remoteTab
    end
    if type(remote.items) == "table" then
        for key, value in pairs(remote.items) do
            local remoteTs = tonumber(value)
            if remoteTs then
                local itemKey = tostring(key)
                local localTs = tonumber(localElig.items[itemKey])
                if not localTs or remoteTs > localTs then
                    localElig.items[itemKey] = remoteTs
                end
            end
        end
    end
    return localElig
end

local function CopyRejectionList(list)
    local out = {}
    if type(list) ~= "table" then return out end
    local V = SF.ConsumablesVerification
    local limit = #list
    local maxN = (V and V.MAX_REJECTIONS_PER_SCOPE) or 128
    if limit > maxN then limit = maxN end
    for i = 1, limit do
        local row = list[i]
        if type(row) == "table" and type(row.coreSignature) == "string" then
            out[#out + 1] = {
                type = "deposit",
                coreSignature = row.coreSignature,
                approxTxnTime = tonumber(row.approxTxnTime),
                donor = type(row.donor) == "string" and row.donor or nil,
                itemId = tonumber(row.itemId),
                quantity = tonumber(row.quantity),
                guildGuid = type(row.guildGuid) == "string" and row.guildGuid or nil,
                bankTab = tonumber(row.bankTab),
                generation = tonumber(row.generation),
                occurrenceIndex = tonumber(row.occurrenceIndex),
                neighborsOlder = type(row.neighborsOlder) == "table" and row.neighborsOlder or nil,
                neighborsNewer = type(row.neighborsNewer) == "table" and row.neighborsNewer or nil,
                decidedBy = type(row.decidedBy) == "string" and row.decidedBy or nil,
                decidedAt = tonumber(row.decidedAt),
                reason = type(row.reason) == "string" and row.reason or nil,
                txnId = type(row.txnId) == "string" and row.txnId or nil,
                observedBy = type(row.observedBy) == "string" and row.observedBy or nil,
                firstSeen = tonumber(row.firstSeen),
                status = "rejected",
            }
        end
    end
    return out
end

local function BumpRejectionSeq(cfg, opts)
    opts = opts or {}
    local seq = tonumber(cfg.rejectionSeq) or 0
    if seq < 0 or seq ~= math.floor(seq) then seq = 0 end
    cfg.rejectionSeq = seq + 1
    -- Rejection-only updates must advance the admitted config watermark so
    -- ApplyRemoteConfig / catch-up cannot treat the snapshot as stale.
    -- Callers that already bump configSeq (for example Clear) pass bumpConfig=false.
    if opts.bumpConfig ~= false then
        cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1
    end
    return cfg.rejectionSeq
end

-- Authoritative replace. Scope transitions always replace; otherwise seq wins.
local function ReplaceRejectionsFromPayload(cfg, payload, opts)
    opts = opts or {}
    if type(payload) ~= "table" or type(payload.rejections) ~= "table" then
        return EnsureRejections(cfg)
    end
    local remoteSeq = tonumber(payload.rejectionSeq) or 0
    local localSeq = tonumber(cfg.rejectionSeq) or 0
    if not opts.forceReplace and remoteSeq < localSeq then
        return EnsureRejections(cfg)
    end
    cfg.rejections = CopyRejectionList(payload.rejections)
    cfg.rejectionSeq = remoteSeq
    return cfg.rejections
end

local function MigrateObservationAccountingOnce(profile, cfg)
    if tonumber(cfg.obsAccountingSchema) == C.OBS_ACCOUNTING_SCHEMA then
        return false
    end
    -- Unreleased feature: discard legacy donation accounting once; keep config.
    local kept = {}
    local live = profile._consumableEvents
    if type(live) == "table" then
        for i = 1, #live do
            local event = live[i]
            if type(event) == "table" and event.type == C.EVENT.RESET then
                kept[#kept + 1] = event
            end
        end
    end
    profile._consumableEvents = kept
    local archiveKept = {}
    local archive = profile._consumableEventArchive
    if type(archive) == "table" then
        for i = 1, #archive do
            local event = archive[i]
            if type(event) == "table" and event.type == C.EVENT.RESET then
                archiveKept[#archiveKept + 1] = event
            end
        end
    end
    profile._consumableEventArchive = archiveKept
    profile._consumablesUnsent = nil
    profile._consumablesPendingFreezes = nil
    cfg.eventFingerprint = 0
    cfg.archiveFingerprint = 0
    cfg.archiveCount = #archiveKept
    cfg.obsAccountingSchema = C.OBS_ACCOUNTING_SCHEMA
    EnsureEligibility(cfg)
    Debug("Info", "migrated consumables ledger to observation accounting schema %s", tostring(C.OBS_ACCOUNTING_SCHEMA))
    return true
end

function C.Ensure(profile)
    if type(profile) ~= "table" then return nil end
    if type(profile._consumables) ~= "table" then
        profile._consumables = {
            generation = 1,
            configSeq = 0,
            eventSeq = 0,
            guild = nil,
            bankTab = nil,
            requestedItems = {},
            obsAccountingSchema = C.OBS_ACCOUNTING_SCHEMA,
            eligibility = { items = {}, tabEligibleFrom = nil },
            rejections = {},
            rejectionSeq = 0,
            pendingWitnesses = {},
            txnRegistry = {},
            txnAllocSeq = 0,
        }
    end
    local cfg = profile._consumables
    if type(cfg.generation) ~= "number" or cfg.generation < 1
        or cfg.generation ~= math.floor(cfg.generation) or cfg.generation > C.MAX_EVENT_SEQ then
        cfg.generation = 1
    end
    do
        local seq = tonumber(cfg.configSeq)
        if not seq or seq ~= seq or seq ~= math.floor(seq) or seq < 0 or seq > C.MAX_EVENT_SEQ then
            cfg.configSeq = 0
        else
            cfg.configSeq = seq
        end
    end
    if type(cfg.eventSeq) ~= "number" or cfg.eventSeq < 0 or cfg.eventSeq ~= math.floor(cfg.eventSeq) then
        cfg.eventSeq = 0
    elseif cfg.eventSeq >= 9007199254740992 then
        cfg.eventSeq = C.MAX_EVENT_SEQ
    end
    do
        local ledger = C.ValidLedgerSeq(cfg.ledgerSeq)
        if not ledger then
            cfg.ledgerSeq = 0
        else
            cfg.ledgerSeq = ledger
        end
    end
    -- Saved data is normalized once per bind. Later writers store normalized rows.
    if not indexBound[profile] then
        NormalizeRequestedItems(cfg)
    end
    if type(profile._consumablesPendingFreezes) == "table" then
        profile._consumablesPendingFreezes = nil
    end
    if cfg.guild ~= nil and type(cfg.guild) ~= "table" then cfg.guild = nil end
    if type(profile._consumableEvents) ~= "table" then
        profile._consumableEvents = {}
    end
    local migrated = MigrateObservationAccountingOnce(profile, cfg)
    EnsureEligibility(cfg)
    EnsureRejections(cfg)
    EnsurePendingWitnesses(cfg)
    EnsureTxnRegistry(cfg)
    if not cfg._txnRegistrySeeded then
        cfg._txnRegistrySeeded = true
        C.SeedTxnRegistryFromLedger(profile)
    end
    do
        local seq = tonumber(cfg.rejectionSeq)
        if not seq or seq ~= seq or seq ~= math.floor(seq) or seq < 0 then
            cfg.rejectionSeq = 0
        else
            cfg.rejectionSeq = seq
        end
    end
    profile._consumableEventIds = nil
    profile._consumableIndexCount = nil
    local bound = eventIndexes[profile]
    if migrated or not indexBound[profile] or not bound or bound.count ~= #profile._consumableEvents then
        RebuildIndex(profile)
    end
    indexBound[profile] = true
    return cfg
end

function C.HasTxnId(profile, txnId)
    txnId = ValidTxnId(txnId)
    if not txnId or type(profile) ~= "table" then return false end
    C.Ensure(profile)
    local bound = EventIds(profile)
    return bound.txnIds and bound.txnIds[txnId] ~= nil
end

function C.EligibilitySnapshot(profile)
    local cfg = C.Ensure(profile)
    local eligibility = EnsureEligibility(cfg)
    local items = {}
    for key, value in pairs(eligibility.items or {}) do
        items[tostring(key)] = tonumber(value)
    end
    return {
        items = items,
        tabEligibleFrom = tonumber(eligibility.tabEligibleFrom),
        baselineEstablished = eligibility.baselineEstablished == true,
        baselineAt = tonumber(eligibility.baselineAt),
    }
end

function C.DurableRejections(profile)
    local cfg = C.Ensure(profile)
    return EnsureRejections(cfg)
end

function C.RecordDurableRejection(profile, evidence, decidedBy, reason, opts)
    opts = opts or {}
    if type(profile) ~= "table" or type(evidence) ~= "table" then return false end
    local cfg = C.Ensure(profile)
    local list = EnsureRejections(cfg)
    local V = SF.ConsumablesVerification
    if V and V.IsRejected and V.IsRejected({ rejections = list }, evidence) then
        return true
    end
    local record
    if V and V.RejectionRecord then
        record = V.RejectionRecord(evidence, decidedBy, Now(), reason)
    else
        record = {
            coreSignature = evidence.coreSignature,
            approxTxnTime = tonumber(evidence.approxTxnTime),
            donor = evidence.donor,
            itemId = tonumber(evidence.itemId),
            quantity = tonumber(evidence.quantity),
            guildGuid = evidence.guildGuid,
            bankTab = tonumber(evidence.bankTab),
            occurrenceIndex = tonumber(evidence.occurrenceIndex),
            neighborsOlder = evidence.neighborsOlder,
            neighborsNewer = evidence.neighborsNewer,
            decidedBy = decidedBy,
            decidedAt = Now(),
            reason = reason or "rejected",
        }
    end
    list[#list + 1] = record
    local maxN = (V and V.MAX_REJECTIONS_PER_SCOPE) or 128
    while #list > maxN do
        table.remove(list, 1)
    end
    -- Coordinator/local authority bumps seq; follower notice apply does not.
    if opts.bumpSeq ~= false then
        BumpRejectionSeq(cfg)
    end
    return true
end

function C.ClearDurableRejection(profile, evidence, opts)
    opts = opts or {}
    if type(profile) ~= "table" or type(evidence) ~= "table" then return false end
    local cfg = C.Ensure(profile)
    local list = EnsureRejections(cfg)
    local V = SF.ConsumablesVerification
    if not (V and V.RejectionMatches) then return false end
    local kept = {}
    local cleared = false
    for i = 1, #list do
        if V.RejectionMatches(list[i], evidence) then
            cleared = true
        else
            kept[#kept + 1] = list[i]
        end
    end
    if not cleared then return false end
    cfg.rejections = kept
    if opts.bumpSeq ~= false then
        BumpRejectionSeq(cfg)
    end
    return true
end

function C.PendingWitnesses(profile)
    local cfg = C.Ensure(profile)
    return EnsurePendingWitnesses(cfg)
end

PendingWitnessMatches = function(agg, evidence)
    if type(agg) ~= "table" or type(agg.evidence) ~= "table" or type(evidence) ~= "table" then
        return false
    end
    -- Require positively supported continuity. Do not fall back to bare
    -- coreSignature identity: identical deposits at different times must stay
    -- separate when MatchScore rejects contextual continuity.
    local O = SF.ConsumablesObservation
    if not (O and O.MatchScore) then
        return false
    end
    local score = O.MatchScore(agg.evidence, evidence)
    return score and score >= (O.MIN_MATCH_SCORE or 100) and true or false
end

-- Authenticated coordinator-side witness persistence. Never trusts client counts.
function C.UpsertPendingWitness(profile, evidence, submittedBy, witnessMap, opts)
    opts = opts or {}
    if type(profile) ~= "table" or type(evidence) ~= "table" then return false end
    submittedBy = type(submittedBy) == "string" and submittedBy or nil
    if not submittedBy then return false end
    local cfg = C.Ensure(profile)
    local list = EnsurePendingWitnesses(cfg)
    local V = SF.ConsumablesVerification
    local agg = nil
    for i = 1, #list do
        if PendingWitnessMatches(list[i], evidence) then
            agg = list[i]
            break
        end
    end
    if not agg then
        agg = {
            evidence = {
                coreSignature = evidence.coreSignature,
                approxTxnTime = tonumber(evidence.approxTxnTime),
                donor = evidence.donor,
                itemId = tonumber(evidence.itemId),
                quantity = tonumber(evidence.quantity),
                guildGuid = evidence.guildGuid,
                bankTab = tonumber(evidence.bankTab),
                generation = tonumber(evidence.generation),
                occurrenceIndex = tonumber(evidence.occurrenceIndex),
                neighborsOlder = evidence.neighborsOlder,
                neighborsNewer = evidence.neighborsNewer,
                type = evidence.type or "deposit",
            },
            witnesses = {},
            updatedAt = Now(),
        }
        list[#list + 1] = agg
    end
    if type(witnessMap) == "table" then
        agg.witnesses = CopyWitnessMap(witnessMap)
    else
        agg.witnesses = agg.witnesses or {}
        agg.witnesses[submittedBy] = {
            submittedBy = submittedBy,
            observedBy = type(evidence.observedBy) == "string" and evidence.observedBy or nil,
            firstReported = Now(),
        }
    end
    agg.updatedAt = Now()
    local maxN = (V and V.MAX_PENDING_WITNESS_AGGREGATES) or 128
    while #list > maxN do
        table.remove(list, 1)
    end
    if opts.bumpSeq ~= false then
        -- Advance admitted config watermark so catch-up carries witness progress.
        cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1
    end
    return true
end

function C.ClearPendingWitness(profile, evidence, opts)
    opts = opts or {}
    if type(profile) ~= "table" or type(evidence) ~= "table" then return false end
    local cfg = C.Ensure(profile)
    local list = EnsurePendingWitnesses(cfg)
    local kept = {}
    local cleared = false
    for i = 1, #list do
        if PendingWitnessMatches(list[i], evidence) then
            cleared = true
        else
            kept[#kept + 1] = list[i]
        end
    end
    if not cleared then return false end
    cfg.pendingWitnesses = kept
    if opts.bumpSeq ~= false then
        cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Canonical transaction registry (Issue #366): Spectrum-owned identities.
-- Blizzard Guild Bank fields are evidence for matching only — never ID sources.
-- ---------------------------------------------------------------------------

local function CopyNeighborList(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    local limit = #list
    if limit > 4 then limit = 4 end
    for i = 1, limit do
        if type(list[i]) == "string" then
            out[#out + 1] = list[i]
        end
    end
    if #out == 0 then return nil end
    return out
end

local function CopyTxnRegistryEntry(row)
    if type(row) ~= "table" then return nil end
    local txnId = ValidTxnId(row.txnId)
    if not txnId then return nil end
    local status = row.status
    if status ~= "verified" and status ~= "rejected" then
        status = "verified"
    end
    return {
        txnId = txnId,
        status = status,
        committed = row.committed == true,
        coreSignature = type(row.coreSignature) == "string" and row.coreSignature or nil,
        approxTxnTime = tonumber(row.approxTxnTime),
        donor = type(row.donor) == "string" and row.donor or nil,
        itemId = tonumber(row.itemId),
        quantity = tonumber(row.quantity),
        guildGuid = type(row.guildGuid) == "string" and row.guildGuid or nil,
        bankTab = tonumber(row.bankTab),
        generation = tonumber(row.generation),
        occurrenceIndex = tonumber(row.occurrenceIndex),
        neighborsOlder = CopyNeighborList(row.neighborsOlder),
        neighborsNewer = CopyNeighborList(row.neighborsNewer),
        verification = type(row.verification) == "string" and row.verification or nil,
        decidedBy = type(row.decidedBy) == "string" and row.decidedBy or nil,
        decidedAt = tonumber(row.decidedAt),
        reason = type(row.reason) == "string" and row.reason or nil,
    }
end

local function CopyTxnRegistry(list)
    local out = {}
    if type(list) ~= "table" then return out end
    local limit = #list
    if limit > C.MAX_TXN_REGISTRY then limit = C.MAX_TXN_REGISTRY end
    -- Prefer newest entries when truncating.
    local start = #list - limit + 1
    if start < 1 then start = 1 end
    for i = start, #list do
        local copy = CopyTxnRegistryEntry(list[i])
        if copy then
            out[#out + 1] = copy
        end
    end
    return out
end

local function PreferRegistryEntry(localEntry, remoteEntry)
    if not localEntry then return remoteEntry end
    if not remoteEntry then return localEntry end
    local localAt = tonumber(localEntry.decidedAt)
    local remoteAt = tonumber(remoteEntry.decidedAt)
    local decisionSide = nil
    if localAt and remoteAt then
        if remoteAt > localAt then
            decisionSide = "remote"
        elseif localAt > remoteAt then
            decisionSide = "local"
        end
    elseif remoteAt and not localAt then
        decisionSide = "remote"
    elseif localAt and not remoteAt then
        decisionSide = "local"
    end

    local decision = remoteEntry
    if decisionSide == "local" then
        decision = localEntry
    elseif decisionSide == "remote" then
        decision = remoteEntry
    else
        -- No comparable newer decision: protect committed credits, then use a
        -- commutative status tie-break so merge order cannot diverge.
        if localEntry.committed and localEntry.status == "verified" then
            decision = localEntry
        elseif remoteEntry.committed and remoteEntry.status == "verified" then
            decision = remoteEntry
        elseif localEntry.status == remoteEntry.status then
            decision = localEntry
        elseif localEntry.status == "verified" and remoteEntry.status ~= "verified" then
            -- Equal/missing decidedAt: prefer verified (reject→correct same tick).
            decision = localEntry
        elseif remoteEntry.status == "verified" and localEntry.status ~= "verified" then
            decision = remoteEntry
        else
            decision = localEntry
        end
    end

    local out = CopyTxnRegistryEntry(decision)
    if not out then
        out = CopyTxnRegistryEntry(localEntry) or CopyTxnRegistryEntry(remoteEntry)
    end
    if not out then return nil end

    -- Committed credit is sticky across merges once either side recorded it.
    if localEntry.committed or remoteEntry.committed then
        out.committed = true
        if out.status ~= "rejected" then
            out.status = "verified"
        elseif decisionSide == "remote" and remoteEntry.status == "rejected"
            and not remoteEntry.committed and localEntry.committed then
            -- An uncommitted remote rejection cannot un-credit a committed donation.
            out.status = "verified"
            out.verification = localEntry.verification or out.verification
            out.decidedBy = localEntry.decidedBy or out.decidedBy
            out.decidedAt = localAt or out.decidedAt
            out.reason = nil
        end
    end

    local other = decision == localEntry and remoteEntry or localEntry
    out.neighborsOlder = out.neighborsOlder or other.neighborsOlder
    out.neighborsNewer = out.neighborsNewer or other.neighborsNewer
    out.coreSignature = out.coreSignature or other.coreSignature
    out.approxTxnTime = out.approxTxnTime or other.approxTxnTime
    out.verification = out.verification or other.verification
    out.decidedBy = out.decidedBy or other.decidedBy
    if out.status == "rejected" then
        out.reason = out.reason or other.reason
    else
        out.reason = decision.reason
    end
    return out
end

-- Union-merge registries. Blind replace would let an incomplete new coordinator
-- wipe richer peer history before Tuesday credits are recovered.
local function ReplaceTxnRegistryFromPayload(cfg, payload)
    if type(payload) ~= "table" or type(payload.txnRegistry) ~= "table" then
        return EnsureTxnRegistry(cfg)
    end
    local localList = EnsureTxnRegistry(cfg)
    local byId = {}
    local order = {}
    for i = 1, #localList do
        local row = localList[i]
        if type(row) == "table" and ValidTxnId(row.txnId) and not byId[row.txnId] then
            byId[row.txnId] = CopyTxnRegistryEntry(row)
            order[#order + 1] = row.txnId
        end
    end
    local remote = CopyTxnRegistry(payload.txnRegistry)
    for i = 1, #remote do
        local row = remote[i]
        local txnId = row and row.txnId
        if txnId then
            if byId[txnId] then
                byId[txnId] = PreferRegistryEntry(byId[txnId], row)
            else
                byId[txnId] = row
                order[#order + 1] = txnId
            end
        end
    end
    local merged = {}
    for i = 1, #order do
        local copy = byId[order[i]]
        if copy then
            merged[#merged + 1] = copy
        end
    end
    while #merged > C.MAX_TXN_REGISTRY do
        table.remove(merged, 1)
    end
    cfg.txnRegistry = merged
    local remoteAlloc = tonumber(payload.txnAllocSeq)
    if remoteAlloc and remoteAlloc == math.floor(remoteAlloc) and remoteAlloc >= 0 then
        local localAlloc = tonumber(cfg.txnAllocSeq) or 0
        if remoteAlloc > localAlloc then
            cfg.txnAllocSeq = remoteAlloc
        end
    end
    return cfg.txnRegistry
end

local function ShortWriterToken(writer)
    writer = Norm(writer) or "local"
    writer = writer:gsub("[^%w%-]", "")
    if writer == "" then writer = "local" end
    if #writer > 24 then writer = writer:sub(1, 24) end
    return writer
end

function C.TxnRegistry(profile)
    local cfg = C.Ensure(profile)
    return EnsureTxnRegistry(cfg)
end

function C.FindRegistryTxn(profile, txnId)
    txnId = ValidTxnId(txnId)
    if not txnId or type(profile) ~= "table" then return nil end
    local list = EnsureTxnRegistry(C.Ensure(profile))
    for i = 1, #list do
        if list[i].txnId == txnId then
            return list[i]
        end
    end
    return nil
end

-- Collision-resistant Spectrum-owned ID. Never derived from Blizzard evidence.
function C.AllocateCanonicalTxnId(profile, writer)
    if type(profile) ~= "table" then return nil end
    local cfg = C.Ensure(profile)
    EnsureTxnRegistry(cfg)
    cfg.txnAllocSeq = (tonumber(cfg.txnAllocSeq) or 0) + 1
    local profileId = tostring(profile._profileId or "profile")
    if type(profile.GetProfileId) == "function" then
        local ok, id = pcall(profile.GetProfileId, profile)
        if ok and type(id) == "string" and id ~= "" then
            profileId = id
        end
    end
    if #profileId > 40 then profileId = profileId:sub(1, 40) end
    local w = ShortWriterToken(writer)
    local entropy = 0
    entropy = MixConfigText(entropy, w)
    entropy = MixConfigText(entropy, tostring(Now()))
    local gt = 0
    if type(GetTime) == "function" then
        gt = tonumber(GetTime()) or 0
    end
    entropy = MixConfigText(entropy, tostring(gt))
    entropy = MixConfigText(entropy, tostring(cfg.txnAllocSeq))
    local txnId = string.format("ctx:%s:%s:%d:%x", profileId, w, cfg.txnAllocSeq, entropy)
    return ValidTxnId(txnId)
end

function C.RegisterCanonicalTxn(profile, entry, opts)
    opts = opts or {}
    if type(profile) ~= "table" or type(entry) ~= "table" then return false end
    local copy = CopyTxnRegistryEntry(entry)
    if not copy then return false end
    -- Prefer the live cfg table: C.Ensure/RebuildIndex mid-AppendEvent would
    -- fingerprint the new row twice and XOR the eventFingerprint back to 0.
    local cfg = profile._consumables
    if type(cfg) ~= "table" then
        cfg = C.Ensure(profile)
    end
    if type(cfg) ~= "table" then return false end
    local list = EnsureTxnRegistry(cfg)
    for i = 1, #list do
        if list[i].txnId == copy.txnId then
            -- Preserve committed once set; allow status/evidence refresh.
            if list[i].committed then copy.committed = true end
            list[i] = copy
            if opts.bumpSeq ~= false then
                cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1
            end
            return true
        end
    end
    list[#list + 1] = copy
    while #list > C.MAX_TXN_REGISTRY do
        table.remove(list, 1)
    end
    if opts.bumpSeq ~= false then
        cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1
    end
    return true
end

function C.MarkRegistryCommitted(profile, txnId, opts)
    opts = opts or {}
    local entry = C.FindRegistryTxn(profile, txnId)
    if not entry then return false end
    if entry.committed then return true end
    entry.committed = true
    if opts.bumpSeq ~= false then
        local cfg = C.Ensure(profile)
        cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1
    end
    return true
end

local function RegistryEntryFromEvent(event)
    if type(event) ~= "table" then return nil end
    local txnId = ValidTxnId(event.txnId)
    if not txnId then return nil end
    return {
        txnId = txnId,
        status = "verified",
        committed = true,
        coreSignature = event.coreSignature,
        approxTxnTime = tonumber(event.timestamp) or tonumber(event.approxTxnTime),
        donor = event.actor or event.donor,
        itemId = event.itemId,
        quantity = event.quantity,
        guildGuid = event.guildGuid,
        bankTab = event.bankTab,
        generation = event.generation,
        occurrenceIndex = event.occurrenceIndex,
        neighborsOlder = event.neighborsOlder,
        neighborsNewer = event.neighborsNewer,
        verification = event.verification,
        decidedBy = event.writer,
        decidedAt = tonumber(event.timestamp),
    }
end

function C.SeedTxnRegistryFromLedger(profile)
    if type(profile) ~= "table" then return 0 end
    local cfg = C.Ensure(profile)
    EnsureTxnRegistry(cfg)
    local added = 0
    local lists = { profile._consumableEventArchive, profile._consumableEvents }
    for li = 1, #lists do
        local list = lists[li]
        if type(list) == "table" then
            for i = 1, #list do
                local event = list[i]
                if type(event) == "table"
                    and event.type == C.EVENT.DONATION
                    and event.source == "guildbank"
                    and ValidTxnId(event.txnId)
                    and not C.FindRegistryTxn(profile, event.txnId)
                then
                    local entry = RegistryEntryFromEvent(event)
                    if entry and C.RegisterCanonicalTxn(profile, entry, { bumpSeq = false }) then
                        added = added + 1
                    end
                end
            end
        end
    end
    return added
end

function C.NoteObservationBaseline(profile)
    if type(profile) ~= "table" then return false end
    local cfg = C.Ensure(profile)
    local eligibility = EnsureEligibility(cfg)
    if eligibility.baselineEstablished then return false end
    eligibility.baselineEstablished = true
    eligibility.baselineAt = Now()
    Debug("Info", "observation eligibility baseline established")
    return true
end

local function ArchiveList(profile)
    if type(profile._consumableEventArchive) ~= "table" then
        profile._consumableEventArchive = {}
    end
    return profile._consumableEventArchive
end

-- XOR is its own inverse, so mixing a stored row again removes it.
local function ReleaseArchivedRecord(profile, evicted)
    if type(evicted) ~= "table" then return end
    local cfg = profile._consumables
    if type(cfg) == "table" then
        cfg.archiveFingerprint = MixFingerprint(cfg.archiveFingerprint, evicted.id, evicted.order, evicted)
    end
    local bound = EventIds(profile)
    if type(evicted.id) == "string" and bound.ids[evicted.id] == evicted then
        bound.ids[evicted.id] = nil
    end
    if not ArchiveQuotaExempt(evicted) and type(bound.archiveCounts) == "table" then
        local key = QuotaBucket(evicted)
        bound.archiveCounts[key] = math.max(0, (bound.archiveCounts[key] or 1) - 1)
    end
end

local function EvictArchivedAt(profile, index)
    local archive = ArchiveList(profile)
    if type(index) ~= "number" or index < 1 or index > #archive then return nil end
    local evicted = table.remove(archive, index)
    ReleaseArchivedRecord(profile, evicted)
    return evicted
end

local function TrimArchive(profile)
    local archive = ArchiveList(profile)
    local overflow = #archive - C.MAX_ARCHIVED_EVENTS
    if overflow <= 0 then return false end
    local bound = EventIds(profile)
    for i = 1, overflow do
        local evicted = archive[i]
        if type(evicted) == "table" and type(evicted.id) == "string" and bound.ids[evicted.id] == evicted then
            bound.ids[evicted.id] = nil
        end
    end
    local kept = {}
    for i = overflow + 1, #archive do
        kept[#kept + 1] = archive[i]
    end
    profile._consumableEventArchive = kept
    StoreArchiveStats(profile)
    local counts = {}
    for i = 1, #kept do
        local archived = kept[i]
        if type(archived) == "table" then
            NoteArchiveQuota(counts, archived)
        end
    end
    EventIds(profile).archiveCounts = counts
    return true
end

local function ShelveEvents(profile, shouldArchive)
    local kept = {}
    local archive = ArchiveList(profile)
    local moved = false
    local events = profile._consumableEvents
    local bound = EventIds(profile)
    local counts = bound.archiveCounts
    if type(counts) ~= "table" then
        counts = {}
        bound.archiveCounts = counts
    end
    for i = 1, #events do
        local event = events[i]
        local eventGen = type(event) == "table" and tonumber(event.generation) or nil
        if shouldArchive(eventGen) then
            local archiveIt = true
            if type(event) == "table" and not ArchiveQuotaExempt(event) then
                local key = QuotaBucket(event)
                local used = counts[key] or 0
                if used >= C.MAX_EVENTS_PER_ACTOR then
                    archiveIt = false
                else
                    counts[key] = used + 1
                end
            end
            if archiveIt then
                archive[#archive + 1] = event
            end
            moved = true
        else
            kept[#kept + 1] = event
        end
    end
    if not moved then return false end
    profile._consumableEvents = kept
    TrimArchive(profile)
    RebuildIndex(profile)
    return true
end

function C.ShelvePriorGenerations(profile)
    local cfg = C.Ensure(profile)
    local generation = tonumber(cfg.generation) or 1
    return ShelveEvents(profile, function(eventGen)
        return eventGen and eventGen < generation
    end)
end

function C.RetainCurrentGeneration(profile)
    local cfg = C.Ensure(profile)
    local generation = tonumber(cfg.generation) or 1
    return ShelveEvents(profile, function(eventGen)
        return eventGen ~= generation
    end)
end

local function RestoreAdoptedGeneration(profile)
    local archive = profile._consumableEventArchive
    if type(archive) ~= "table" or #archive == 0 then return false end
    local generation = tonumber(profile._consumables.generation) or 1
    local live = profile._consumableEvents
    if type(live) ~= "table" then
        live = {}
        profile._consumableEvents = live
    end
    local kept = {}
    local moved = false
    for i = 1, #archive do
        local event = archive[i]
        local eventGen = type(event) == "table" and tonumber(event.generation) or nil
        if type(event) == "table" and eventGen == generation and event.type ~= C.EVENT.RESET
            and #live < C.MAX_LEDGER_EVENTS then
            live[#live + 1] = event
            moved = true
        else
            kept[#kept + 1] = event
        end
    end
    if not moved then return false end
    profile._consumableEventArchive = kept
    RebuildIndex(profile)
    return true
end

local function ConfigFingerprint(cfg)
    local guid = ""
    if type(cfg.guild) == "table" and type(cfg.guild.guid) == "string" then
        guid = cfg.guild.guid
    end
    local hash = MixConfigText(0, "g:" .. guid)
    hash = MixConfigText(hash, "t:" .. tostring(tonumber(cfg.bankTab) or 0))
    local rows = {}
    for key, row in pairs(cfg.requestedItems or {}) do
        local itemId = type(row) == "table" and tonumber(row.itemId) or tonumber(key)
        if IsItemId(itemId) then
            local goal = 0
            if type(row) == "table" then
                goal = C.ValidGoal(row.goal) or 0
            end
            rows[#rows + 1] = { itemId = itemId, goal = goal }
        end
    end
    table.sort(rows, function(a, b) return a.itemId < b.itemId end)
    local limit = #rows
    if limit > C.MAX_REQUESTED_ITEMS then limit = C.MAX_REQUESTED_ITEMS end
    hash = MixConfigText(hash, "r:" .. tostring(#rows))
    for i = 1, limit do
        hash = MixConfigText(hash, "i:" .. tostring(rows[i].itemId) .. ":g:" .. tostring(rows[i].goal))
    end
    -- Eligibility cutovers are part of the effective configuration contract.
    local eligibility = EnsureEligibility(cfg)
    hash = MixConfigText(hash, "eb:" .. tostring(eligibility.baselineEstablished and 1 or 0))
    hash = MixConfigText(hash, "et:" .. tostring(tonumber(eligibility.tabEligibleFrom) or 0))
    local eligRows = {}
    for key, value in pairs(eligibility.items or {}) do
        local itemId = tonumber(key)
        local ts = tonumber(value)
        if itemId and ts then
            eligRows[#eligRows + 1] = { itemId = itemId, ts = ts }
        end
    end
    table.sort(eligRows, function(a, b) return a.itemId < b.itemId end)
    local eligLimit = #eligRows
    if eligLimit > C.MAX_REQUESTED_ITEMS then eligLimit = C.MAX_REQUESTED_ITEMS end
    hash = MixConfigText(hash, "ei:" .. tostring(#eligRows))
    for i = 1, eligLimit do
        hash = MixConfigText(hash, "e:" .. tostring(eligRows[i].itemId) .. ":" .. tostring(eligRows[i].ts))
    end
    hash = MixConfigText(hash, "rj:" .. tostring(tonumber(cfg.rejectionSeq) or 0))
    -- Hash pending witnesses and registry as order-independent sets so merge
    -- order and local txnAllocSeq cannot keep CoordinatorConfigDiffers true.
    local pending = EnsurePendingWitnesses(cfg)
    local pendingKeys = {}
    for i = 1, #pending do
        local agg = pending[i]
        if type(agg) == "table" and type(agg.evidence) == "table" then
            local wcount = 0
            if type(agg.witnesses) == "table" then
                for _ in pairs(agg.witnesses) do wcount = wcount + 1 end
            end
            pendingKeys[#pendingKeys + 1] = table.concat({
                tostring(agg.evidence.coreSignature or ""),
                tostring(tonumber(agg.evidence.approxTxnTime) or 0),
                tostring(tonumber(agg.evidence.occurrenceIndex) or 0),
                tostring(wcount),
            }, ":")
        end
    end
    table.sort(pendingKeys)
    hash = MixConfigText(hash, "pw:" .. tostring(#pendingKeys))
    for i = 1, #pendingKeys do
        hash = MixConfigText(hash, "p:" .. pendingKeys[i])
    end
    local registry = EnsureTxnRegistry(cfg)
    local regKeys = {}
    for i = 1, #registry do
        local row = registry[i]
        if type(row) == "table" and type(row.txnId) == "string" and row.txnId ~= "" then
            regKeys[#regKeys + 1] = tostring(row.txnId) .. ":" .. tostring(row.status or "")
        end
    end
    table.sort(regKeys)
    hash = MixConfigText(hash, "tr:" .. tostring(#regKeys))
    local regLimit = #regKeys
    if regLimit > 32 then regLimit = 32 end
    -- Stable prefix of sorted ids (not merge-order tail).
    for i = 1, regLimit do
        hash = MixConfigText(hash, "t:" .. regKeys[i])
    end
    return hash
end

function C.Descriptor(profile)
    local cfg = C.Ensure(profile)
    return {
        generation = cfg.generation,
        configSeq = cfg.configSeq,
        rejectionSeq = tonumber(cfg.rejectionSeq) or 0,
        txnAllocSeq = tonumber(cfg.txnAllocSeq) or 0,
        configFingerprint = ConfigFingerprint(cfg),
        eventCount = #(profile._consumableEvents or {}),
        eventFingerprint = tonumber(cfg.eventFingerprint) or 0,
        archiveCount = tonumber(cfg.archiveCount) or #(profile._consumableEventArchive or {}),
        archiveFingerprint = tonumber(cfg.archiveFingerprint) or 0,
    }
end

function C.IsCanonicalAdmin(profile, actor)
    actor = Norm(actor)
    if not actor or type(profile) ~= "table" then return false end
    if type(profile.IsAdminMemberId) == "function" then
        return profile:IsAdminMemberId(actor) and true or false
    end
    for _, id in ipairs(profile._adminUsers or {}) do
        if Same(id, actor) then return true end
    end
    return false
end

local function AllowAdmin(profile, actor, opts)
    opts = opts or {}
    if opts.asAdmin ~= nil then
        return opts.asAdmin and true or false
    end
    return C.IsCanonicalAdmin(profile, actor)
end

function C.IsRequested(profile, itemId)
    itemId = tonumber(itemId)
    if not IsItemId(itemId) then return false end
    local row = C.Ensure(profile).requestedItems[ItemKey(itemId)]
    return type(row) == "table" and IsItemId(tonumber(row.itemId))
end

function C.RequestedItemIds(profile)
    local cfg = C.Ensure(profile)
    local ids = {}
    for _, row in pairs(cfg.requestedItems or {}) do
        local itemId = type(row) == "table" and tonumber(row.itemId) or nil
        if IsItemId(itemId) then
            ids[#ids + 1] = itemId
        end
    end
    table.sort(ids)
    return ids
end

local function BumpConfig(profile)
    local cfg = C.Ensure(profile)
    cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1
    Invalidate(profile)
end

function C.AddRequestedItem(profile, actor, itemId, opts)
    opts = opts or {}
    itemId = tonumber(itemId)
    actor = Norm(actor)
    if not IsItemId(itemId) then
        return false, "Enter a valid item ID."
    end
    if not actor then
        return false, "Only a profile admin can add requested items."
    end
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can add requested items."
    end
    if opts.transferable == false or (opts.requireTransferable and opts.transferable ~= true) then
        return false, "That item cannot be deposited into the guild bank."
    end
    local cfg = C.Ensure(profile)
    if C.IsRequested(profile, itemId) then
        return false, "That exact item is already requested."
    end
    local count = 0
    for _ in pairs(cfg.requestedItems) do
        count = count + 1
        if count >= C.MAX_REQUESTED_ITEMS then
            return false, "Raid Consumables already has the maximum number of requested items."
        end
    end
    cfg.requestedItems[ItemKey(itemId)] = { itemId = itemId, goal = 0 }
    local eligibility = EnsureEligibility(cfg)
    -- After the initial observation baseline, newly requested items must not
    -- back-credit earlier Guild Bank history. Pre-baseline adds stay eligible
    -- for the first authoritative scan's historical import.
    if eligibility.baselineEstablished then
        eligibility.items[ItemKey(itemId)] = Now()
    end
    BumpConfig(profile)
    Debug("Info", "Requested item %s", tostring(itemId))
    Notify()
    return true
end

function C.SetRequestedGoal(profile, actor, itemId, goal, opts)
    opts = opts or {}
    itemId = tonumber(itemId)
    actor = Norm(actor)
    goal = C.ValidGoal(goal)
    if goal == nil then
        return false, "Enter a non-negative whole-number goal."
    end
    if not IsItemId(itemId) or not actor then
        return false, "Choose a requested material."
    end
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can change requested-item goals."
    end
    if not C.IsRequested(profile, itemId) then
        return false, "That material is not currently requested."
    end
    local cfg = C.Ensure(profile)
    local row = cfg.requestedItems[ItemKey(itemId)]
    if type(row) ~= "table" then
        return false, "That material is not currently requested."
    end
    if (C.ValidGoal(row.goal) or 0) == goal then
        return true
    end
    row.goal = goal
    BumpConfig(profile)
    Debug("Info", "Requested item %s goal %s", tostring(itemId), tostring(goal))
    Notify()
    return true
end

function C.RemoveRequestedItem(profile, actor, itemId, opts)
    opts = opts or {}
    itemId = tonumber(itemId)
    actor = Norm(actor)
    if not IsItemId(itemId) or not actor then
        return false, "Choose a requested material."
    end
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can remove requested items."
    end
    if not C.IsRequested(profile, itemId) then
        return false, "That material is not currently requested."
    end
    local cfg = C.Ensure(profile)
    cfg.requestedItems[ItemKey(itemId)] = nil
    BumpConfig(profile)
    Debug("Info", "Removed requested item %s", tostring(itemId))
    Notify()
    return true
end

function C.SetGuild(profile, actor, guild, bankTab, opts)
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can set the guild."
    end
    if type(guild) ~= "table" or type(guild.guid) ~= "string" or guild.guid == "" then
        return false, "A stable guild id is required."
    end
    bankTab = tonumber(bankTab)
    if not IsBankTab(bankTab) then
        return false, "Choose a guild bank tab from 1 to 8."
    end
    local cfg = C.Ensure(profile)
    if cfg.guild and type(cfg.guild.guid) == "string" and cfg.guild.guid ~= "" then
        return false, "Guild configuration is locked. Clear Guild Configuration to change it."
    end
    cfg.guild = {
        guid = guild.guid,
        name = type(guild.name) == "string" and guild.name or "",
        realm = type(guild.realm) == "string" and guild.realm or "",
    }
    cfg.bankTab = bankTab
    local eligibility = EnsureEligibility(cfg)
    -- Initial guild/tab setup (never cleared): first scan may backfill history.
    -- After Clear, baselineEstablished stays true with a post-clear floor — keep it.
    if not eligibility.baselineEstablished then
        eligibility.tabEligibleFrom = nil
    end
    BumpConfig(profile)
    Debug("Info", "Set guild %s tab %s", cfg.guild.guid, tostring(bankTab))
    Notify()
    return true
end

function C.SetBankTab(profile, actor, bankTab, opts)
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can change the guild bank tab."
    end
    local cfg = C.Ensure(profile)
    if not cfg.guild or type(cfg.guild.guid) ~= "string" or cfg.guild.guid == "" then
        return false, "Set the guild first."
    end
    bankTab = tonumber(bankTab)
    if not IsBankTab(bankTab) then
        return false, "Choose a guild bank tab from 1 to 8."
    end
    if cfg.bankTab == bankTab then
        return true
    end
    cfg.bankTab = bankTab
    local eligibility = EnsureEligibility(cfg)
    if eligibility.baselineEstablished then
        eligibility.tabEligibleFrom = Now()
    end
    BumpConfig(profile)
    Debug("Info", "Set guild bank tab %s", tostring(bankTab))
    Notify()
    return true
end

local function BoundedName(value)
    value = Norm(value)
    if type(value) ~= "string" or #value > C.MAX_EVENT_NAME then
        return nil
    end
    return value
end

function CopyEvent(event)
    local source = event.source
    if source ~= "guildbank" then
        -- Preserve archived development-era trade donations without new writers.
        if source ~= "trade" then
            source = nil
        end
    end
    local verification = event.verification
    if verification ~= "admin_trust" and verification ~= "witnesses" and verification ~= "manual" then
        verification = nil
    end
    return {
        id = event.id,
        type = event.type,
        generation = tonumber(event.generation),
        timestamp = tonumber(event.timestamp),
        actor = BoundedName(event.actor),
        itemId = tonumber(event.itemId),
        quantity = tonumber(event.quantity),
        source = source,
        order = tonumber(event.order),
        writer = type(event.writer) == "string" and event.writer ~= "" and #event.writer <= C.MAX_EVENT_NAME and event.writer or nil,
        txnId = ValidTxnId(event.txnId),
        verification = verification,
        coreSignature = type(event.coreSignature) == "string" and event.coreSignature or nil,
        occurrenceIndex = tonumber(event.occurrenceIndex),
        guildGuid = type(event.guildGuid) == "string" and event.guildGuid or nil,
        bankTab = tonumber(event.bankTab),
        neighborsOlder = type(event.neighborsOlder) == "table" and event.neighborsOlder or nil,
        neighborsNewer = type(event.neighborsNewer) == "table" and event.neighborsNewer or nil,
        -- Optional future monetary field: preserve when valid; leave unset when nil.
        goldValueCopper = ValidGoldValueCopper(event.goldValueCopper),
    }
end

function C.AppendArchivedEvent(profile, event, opts)
    C.Ensure(profile)
    if type(event) ~= "table" or type(event.type) ~= "string" then
        return false, "Invalid accounting event."
    end
    if type(event.id) == "string" and #event.id > C.MAX_EVENT_ID then
        return false, "invalid"
    end
    if type(event.id) ~= "string" or event.id == "" then
        event.id = C.NextEventId(profile, event.actor)
    end
    local bound = EventIds(profile)
    if bound.ids[event.id] then
        return true, "duplicate"
    end
    local generation = tonumber(event.generation)
    if not generation or generation ~= math.floor(generation) or generation < 1 then
        return false, "invalid"
    end
    local record = CopyEvent(event)
    local quotaKey = QuotaBucket(record)
    local exempt = ArchiveQuotaExempt(record)
    bound.archiveCounts = bound.archiveCounts or {}
    if not exempt and (bound.archiveCounts[quotaKey] or 0) >= C.MAX_EVENTS_PER_ACTOR then
        return false, "quota"
    end
    local archive = ArchiveList(profile)
    archive[#archive + 1] = record
    bound.ids[record.id] = record
    local cfg = profile._consumables
    cfg.archiveFingerprint = MixFingerprint(cfg.archiveFingerprint, record.id, record.order, record)
    if not exempt then
        bound.archiveCounts[quotaKey] = (bound.archiveCounts[quotaKey] or 0) + 1
    end
    local evicted = nil
    while #archive > C.MAX_ARCHIVED_EVENTS do
        local dropped = EvictArchivedAt(profile, 1)
        if not dropped then break end
        if opts and opts.collectEvicted then
            evicted = evicted or {}
            evicted[#evicted + 1] = dropped
        end
    end
    cfg.archiveCount = #archive
    if not (opts and opts.silent) then
        Notify()
    end
    return true, "archived", evicted
end

local function RestoreArchivedFront(profile, record)
    if type(record) ~= "table" or type(record.id) ~= "string" or record.id == "" then
        return false
    end
    local bound = EventIds(profile)
    if bound.ids[record.id] then
        return false
    end
    local archive = ArchiveList(profile)
    table.insert(archive, 1, record)
    bound.ids[record.id] = record
    local cfg = profile._consumables
    if type(cfg) == "table" then
        cfg.archiveFingerprint = MixFingerprint(cfg.archiveFingerprint, record.id, record.order, record)
        cfg.archiveCount = #archive
    end
    if not ArchiveQuotaExempt(record) then
        bound.archiveCounts = bound.archiveCounts or {}
        local key = QuotaBucket(record)
        bound.archiveCounts[key] = (bound.archiveCounts[key] or 0) + 1
    end
    return true
end

local function NoteCollectedEvictions(into, dropped)
    if type(dropped) ~= "table" or type(into) ~= "table" then return end
    for i = 1, #dropped do
        into[#into + 1] = dropped[i]
    end
end

function C.StampOrder(profile, event)
    if type(event) ~= "table" then return nil end
    local cfg = C.Ensure(profile)
    local existing = C.ValidOrder(event.order)
    if existing then
        if existing > (tonumber(cfg.ledgerSeq) or 0) then
            cfg.ledgerSeq = existing
        end
        return existing
    end
    local bound = EventIds(profile)
    local stored = type(event.id) == "string" and bound.ids[event.id] or nil
    local previous = type(stored) == "table" and C.ValidOrder(stored.order) or nil
    if previous then
        event.order = previous
        if previous > (tonumber(cfg.ledgerSeq) or 0) then
            cfg.ledgerSeq = previous
        end
        return previous
    end
    local nextOrder = (tonumber(cfg.ledgerSeq) or 0) + 1
    if not C.ValidOrder(nextOrder) then return nil end
    cfg.ledgerSeq = nextOrder
    event.order = cfg.ledgerSeq
    if type(stored) == "table" and stored ~= event then
        stored.order = event.order
    end
    local live = type(stored) == "table" and stored or event
    if IsLiveRecord(profile, live) then
        RetargetFingerprint(cfg, event.id, nil, event.order)
    elseif IsArchivedRecord(profile, live) then
        RetargetArchiveFingerprint(cfg, event.id, nil, event.order)
    end
    Invalidate(profile)
    return event.order
end

function C.NoteStoredWriter(profile, event, writer)
    if type(profile) ~= "table" or type(event) ~= "table" then return false end
    if type(writer) ~= "string" or writer == "" or #writer > C.MAX_EVENT_NAME then return false end
    if type(event.writer) == "string" and event.writer ~= "" then return false end
    local before = BodyToken(event)
    event.writer = writer
    local after = BodyToken(event)
    if before == after then return true end
    local cfg = profile._consumables
    if type(cfg) ~= "table" then return true end
    local oldHash = before and HashText(before, BODY_HASH_BYTES) or 0
    local newHash = after and HashText(after, BODY_HASH_BYTES) or 0
    local function remix(field)
        cfg[field] = Xor32(Xor32(tonumber(cfg[field]) or 0, oldHash), newHash)
    end
    if IsLiveRecord(profile, event) then
        remix("eventFingerprint")
    elseif IsArchivedRecord(profile, event) then
        remix("archiveFingerprint")
    end
    return true
end

function C.NextEventId(profile, actor)
    local cfg = C.Ensure(profile)
    cfg.eventSeq = (tonumber(cfg.eventSeq) or 0) + 1
    actor = Norm(actor) or "unknown"
    if #actor > C.MAX_EVENT_NAME then
        actor = actor:sub(1, C.MAX_EVENT_NAME)
    end
    local profileId = tostring(profile._profileId or "profile")
    if #profileId > C.MAX_EVENT_NAME then
        profileId = profileId:sub(1, C.MAX_EVENT_NAME)
    end
    return string.format("ce:%s:%s:%d", profileId, actor, cfg.eventSeq)
end

local function AssignStoredBody(stored, event)
    if type(stored) ~= "table" or type(event) ~= "table" then return false end
    if BodyToken(stored) == BodyToken(event) then return false end
    local incoming = CopyEvent(event)
    stored.type = incoming.type
    stored.generation = incoming.generation
    stored.timestamp = incoming.timestamp
    stored.actor = incoming.actor
    stored.itemId = incoming.itemId
    stored.quantity = incoming.quantity
    stored.source = incoming.source
    stored.crafter = incoming.crafter
    stored.epoch = incoming.epoch
    stored.action = incoming.action
    stored.holder = incoming.holder
    stored.fromHolder = incoming.fromHolder
    stored.toHolder = incoming.toHolder
    stored.reason = incoming.reason
    stored.tradeToken = incoming.tradeToken
    stored.withdrawToken = incoming.withdrawToken
    stored.writer = incoming.writer
    stored.txnId = incoming.txnId
    stored.verification = incoming.verification
    stored.goldValueCopper = incoming.goldValueCopper
    if incoming.order ~= nil then
        stored.order = incoming.order
    end
    return true
end

function C.AppendEvent(profile, event, opts)
    opts = opts or {}
    if type(event) ~= "table" or type(event.type) ~= "string" then
        return false, "Invalid accounting event."
    end
    C.Ensure(profile)
    if event.order ~= nil and not C.ValidOrder(event.order) then
        return false, "invalid"
    end
    if type(event.id) == "string" and #event.id > C.MAX_EVENT_ID then
        return false, "invalid"
    end
    if type(event.id) ~= "string" or event.id == "" then
        event.id = C.NextEventId(profile, event.actor)
    end
    local bound = EventIds(profile)
    local stored = bound.ids[event.id]
    if stored then
        local incoming = C.ValidOrder(event.order)
        local storedOrder = type(stored) == "table" and C.ValidOrder(stored.order) or nil
        local replaceOrder = opts.replaceOrder and incoming and storedOrder and storedOrder ~= incoming
        if incoming and type(stored) == "table" and (storedOrder == nil or replaceOrder) then
            if IsLiveRecord(profile, stored) then
                RetargetFingerprint(profile._consumables, event.id, storedOrder, incoming)
            else
                RetargetArchiveFingerprint(profile._consumables, event.id, storedOrder, incoming)
            end
            stored.order = incoming
            local cfg = profile._consumables
            if incoming > (tonumber(cfg.ledgerSeq) or 0) then
                cfg.ledgerSeq = incoming
            end
            Invalidate(profile)
        end
        if opts.replaceBody and type(stored) == "table" and AssignStoredBody(stored, event) then
            Invalidate(profile)
            return true, "replaced"
        end
        return true, "duplicate"
    end
    local eventGen = tonumber(event.generation)
    local currentGen = tonumber(profile._consumables.generation) or 1
    if eventGen and (eventGen ~= math.floor(eventGen) or eventGen < 1) then
        return false, "invalid"
    end
    if eventGen and eventGen > currentGen then
        return false, "future"
    end
    if eventGen and eventGen < currentGen then
        return C.AppendArchivedEvent(profile, event, opts)
    end
    if #profile._consumableEvents >= C.MAX_LEDGER_EVENTS then
        local madeRoom = C.ShelvePriorGenerations(profile) and #profile._consumableEvents < C.MAX_LEDGER_EVENTS
        if not madeRoom then
            return false, "full"
        end
    end
    local actorKey = EventQuotaKey(event)
    local quotaKey = actorKey or ANON_QUOTA
    local quotaRow = bound.actorCounts and bound.actorCounts[currentGen]
    if (quotaRow and quotaRow[quotaKey] or 0) >= C.MAX_EVENTS_PER_ACTOR then
        return false, "quota"
    end
    event.timestamp = tonumber(event.timestamp) or Now()
    event.generation = tonumber(event.generation) or C.Ensure(profile).generation
    if event.actor then event.actor = Norm(event.actor) or event.actor end
    -- Local/test commits may omit txnId; assign a stable identity so exactly-once
    -- accounting and snapshot admission stay consistent after migration.
    if event.type == C.EVENT.DONATION and not ValidTxnId(event.txnId) then
        local cfg = profile._consumables
        cfg.txnSeq = (tonumber(cfg.txnSeq) or 0) + 1
        local profileId = tostring(profile._profileId or "profile")
        if #profileId > 48 then profileId = profileId:sub(1, 48) end
        event.txnId = string.format("ctx:%s:local:%d", profileId, cfg.txnSeq)
    end
    local txnId = ValidTxnId(event.txnId)
    if txnId then
        bound.txnIds = bound.txnIds or {}
        if bound.txnIds[txnId] then
            return true, "duplicate"
        end
    end
    local record = CopyEvent(event)
    profile._consumableEvents[#profile._consumableEvents + 1] = record
    bound.ids[event.id] = record
    if txnId then
        bound.txnIds[txnId] = record
    end
    bound.count = #profile._consumableEvents
    bound.actorCounts = bound.actorCounts or {}
    local storedGen = tonumber(record.generation) or currentGen
    local storedRow = bound.actorCounts[storedGen]
    if not storedRow then
        storedRow = {}
        bound.actorCounts[storedGen] = storedRow
    end
    storedRow[quotaKey] = (storedRow[quotaKey] or 0) + 1
    local cfg = profile._consumables
    cfg.eventFingerprint = MixFingerprint(cfg.eventFingerprint, event.id, record.order, record)
    local order = tonumber(record.order)
    if order and order > (tonumber(cfg.ledgerSeq) or 0) then
        cfg.ledgerSeq = order
    end
    local seq = AdoptedEventSeq(event.id)
    if seq and seq > (tonumber(cfg.eventSeq) or 0) then
        cfg.eventSeq = seq
    end
    -- Registry alignment after bound.count/fingerprint so Ensure cannot rebuild
    -- mid-append and double-mix the new event into eventFingerprint.
    if txnId and record.source == "guildbank" then
        local entry = RegistryEntryFromEvent(record)
        if entry then
            C.RegisterCanonicalTxn(profile, entry, { bumpSeq = false })
        end
    end
    Invalidate(profile)
    if not opts.silent then
        Debug("Info", "Recorded %s %s", event.type, event.id)
        Notify()
    end
    return true
end

function C.Clear(profile, actor, opts)
    actor = Norm(actor)
    if not actor then
        return false, "Only a profile admin can clear Raid Consumables."
    end
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can clear Raid Consumables."
    end
    local cfg = C.Ensure(profile)
    local generation = cfg.generation
    local reset = {
        type = C.EVENT.RESET,
        generation = generation,
        actor = actor,
        timestamp = Now(),
    }
    local resetOk = C.AppendEvent(profile, reset, { silent = true })
    cfg.generation = generation + 1
    C.ShelvePriorGenerations(profile)
    if not resetOk and not EventIds(profile).ids[reset.id] then
        C.AppendArchivedEvent(profile, reset)
    end
    cfg.guild = nil
    cfg.bankTab = nil
    cfg.requestedItems = {}
    -- Post-clear floor: subsequent reconfiguration must not back-credit older
    -- still-visible Guild Bank history. First-ever installs keep baseline unset
    -- until NoteObservationBaseline so initial migration backfill still works.
    local clearAt = Now()
    cfg.eligibility = {
        items = {},
        tabEligibleFrom = clearAt,
        baselineEstablished = true,
        baselineAt = clearAt,
    }
    cfg.rejections = {}
    cfg.pendingWitnesses = {}
    -- Keep prior-generation registry rows for rematch against archived ledger
    -- identities; new evidence is stamped with the new generation.
    EnsureTxnRegistry(cfg)
    BumpRejectionSeq(cfg, { bumpConfig = false })
    BumpConfig(profile)
    Debug("Info", "%s cleared Raid Consumables", actor)
    Notify()
    return true
end

local function EventLess(a, b)
    local oa = tonumber(a.order)
    local ob = tonumber(b.order)
    if oa and ob then
        if oa ~= ob then return oa < ob end
    elseif oa or ob then
        return oa ~= nil
    end
    local ta = tonumber(a.timestamp) or 0
    local tb = tonumber(b.timestamp) or 0
    if ta ~= tb then return ta < tb end
    return tostring(a.id) < tostring(b.id)
end

local function BuildProjection(profile, cfg)
    local ordered = {}
    for i = 1, #profile._consumableEvents do
        ordered[i] = profile._consumableEvents[i]
    end
    table.sort(ordered, EventLess)

    -- One bounded pass over current-generation donation events feeds both
    -- raw per-actor contributions and raw per-item totals. Item totals are
    -- accounting totals (one add per accepted event), not identity totals.
    local contributions = {}
    local itemTotals = {}
    for i = 1, #ordered do
        local event = ordered[i]
        if tonumber(event.generation) == cfg.generation then
            local itemId = tonumber(event.itemId)
            local qty = tonumber(event.quantity) or 0
            if event.type == C.EVENT.DONATION and event.actor and itemId and qty > 0 then
                contributions[event.actor] = contributions[event.actor] or {}
                contributions[event.actor][itemId] = (contributions[event.actor][itemId] or 0) + qty
                itemTotals[itemId] = (itemTotals[itemId] or 0) + qty
            end
        end
    end

    return {
        contributions = contributions,
        itemTotals = itemTotals,
    }
end

function C.Project(profile)
    local cfg = C.Ensure(profile)
    local cached = projectionCache[profile]
    local key = tostring(cfg.generation) .. ":" .. tostring(cfg.configSeq) .. ":" .. tostring(#profile._consumableEvents)
    if cached and cached.key == key then
        return cached.value
    end
    local value = BuildProjection(profile, cfg)
    projectionCache[profile] = { key = key, value = value }
    return value
end

function C.ContributionTotal(profile, memberId, itemId)
    memberId = Norm(memberId)
    if not memberId then return 0 end
    local members = { memberId }
    if type(profile.GetIdentityMembers) == "function" then
        local ids = profile:GetIdentityMembers(memberId)
        if type(ids) == "table" and #ids > 0 then
            members = ids
        end
    end
    local contributions = C.Project(profile).contributions
    local total = 0
    itemId = tonumber(itemId)
    for i = 1, #members do
        local name = Norm(members[i]) or members[i]
        local byItem = contributions[name]
        if byItem then
            if itemId then
                total = total + (byItem[itemId] or 0)
            else
                for _, qty in pairs(byItem) do
                    total = total + qty
                end
            end
        end
    end
    return total
end

-- Raw current-generation donated total for an exact item id. Does not apply
-- linked-character identity grouping; goal math must use this view.
function C.ItemDonatedTotal(profile, itemId)
    itemId = tonumber(itemId)
    if not IsItemId(itemId) then return 0 end
    local totals = C.Project(profile).itemTotals
    return (totals and totals[itemId]) or 0
end

-- Reusable per-item / overall goal progress for Settings, Logs, and #352.
-- Individual positive-goal percents may exceed 100. Overall progress caps each
-- positive-goal item at its own goal and excludes goal-0 items entirely.
function C.GoalProgress(profile)
    local cfg = C.Ensure(profile)
    local totals = C.Project(profile).itemTotals or {}
    local items = {}
    local sumCapped = 0
    local sumGoal = 0
    for _, row in pairs(cfg.requestedItems or {}) do
        local itemId = type(row) == "table" and tonumber(row.itemId) or nil
        if IsItemId(itemId) then
            local goal = C.ValidGoal(row.goal) or 0
            local donated = totals[itemId] or 0
            local entry = {
                itemId = itemId,
                goal = goal,
                donated = donated,
                noGoal = goal == 0,
                percent = nil,
            }
            if goal > 0 then
                entry.percent = math.floor((100 * donated) / goal)
                sumCapped = sumCapped + math.min(donated, goal)
                sumGoal = sumGoal + goal
            end
            items[#items + 1] = entry
        end
    end
    table.sort(items, function(a, b) return a.itemId < b.itemId end)
    local hasPositiveGoal = sumGoal > 0
    local overallPercent = nil
    if hasPositiveGoal then
        overallPercent = math.floor((100 * sumCapped) / sumGoal)
    end
    return {
        items = items,
        hasPositiveGoal = hasPositiveGoal,
        overallPercent = overallPercent,
        overallEmptyText = Loc("RAID_SUPPLIES_NO_GOALS_CONFIGURED", "No goals configured."),
        sumCapped = sumCapped,
        sumGoal = sumGoal,
    }
end

function C.ItemName(itemId, itemName)
    if type(itemName) == "string" and itemName ~= "" then return itemName end
    return "item " .. tostring(itemId or "")
end

function C.FormatEvent(event, itemName)
    if type(event) ~= "table" then return "" end
    local name = C.ItemName(event.itemId, itemName)
    local qty = tonumber(event.quantity) or 0
    if event.type == C.EVENT.DONATION then
        if event.source ~= "guildbank" then
            return ""
        end
        return string.format("%s donated %d %s to the guild bank.", tostring(event.actor or "Someone"), qty, name)
    elseif event.type == C.EVENT.RESET then
        return string.format("%s cleared the Raid Consumables configuration.", tostring(event.actor or "An admin"))
    end
    return ""
end

function C.FormatObservation(obs, itemName, statusOverride)
    if type(obs) ~= "table" then return "" end
    local name = C.ItemName(obs.itemId, itemName)
    local qty = tonumber(obs.quantity) or 0
    local donor = tostring(obs.donor or "Someone")
    local status = statusOverride or obs.status or "pending"
    if status == "verified" then
        return string.format("%s donated %d %s — Verified", donor, qty, name)
    end
    if status == "ambiguous" then
        return string.format("%s donated %d %s — Needs review", donor, qty, name)
    end
    return string.format("%s donated %d %s — Pending verification", donor, qty, name)
end

function C.HistoryRows(profile, nameForItem, limit, offset)
    C.Ensure(profile)
    local ordered = {}
    local archive = profile._consumableEventArchive
    if type(archive) == "table" then
        for i = 1, #archive do
            ordered[#ordered + 1] = archive[i]
        end
    end
    for i = 1, #profile._consumableEvents do
        ordered[#ordered + 1] = profile._consumableEvents[i]
    end
    table.sort(ordered, function(a, b) return EventLess(b, a) end)
    -- Cheap displayability filter first so pagination does not format the full
    -- ledger. Format and name lookup run only for the selected page.
    local displayable = {}
    for i = 1, #ordered do
        local event = ordered[i]
        if type(event) == "table" and (event.type == C.EVENT.RESET
            or (event.type == C.EVENT.DONATION and event.source == "guildbank")) then
            displayable[#displayable + 1] = event
        end
    end
    local total = #displayable
    offset = math.floor(tonumber(offset) or 0)
    if offset < 0 then offset = 0 end
    if offset > total then offset = total end
    local last = total
    limit = tonumber(limit)
    if limit and limit >= 0 then
        last = offset + math.floor(limit)
        if last > total then last = total end
    end
    local rows = {}
    for i = offset + 1, last do
        local event = displayable[i]
        local itemName = nil
        if type(nameForItem) == "function" then
            itemName = nameForItem(event.itemId)
        end
        rows[#rows + 1] = {
            text = C.FormatEvent(event, itemName),
            timestamp = event.timestamp,
            generation = event.generation,
        }
    end
    return rows, total
end

function C.ClearConfirmation(profile)
    return "Clear Raid Consumables configuration? Guild, Guild Bank tab, and requested items will be removed. Historical Raid Consumable Logs are kept."
end

local function CopyGuild(guild)
    if type(guild) ~= "table" or type(guild.guid) ~= "string" or guild.guid == "" then
        return nil
    end
    return {
        guid = guild.guid,
        name = type(guild.name) == "string" and guild.name or "",
        realm = type(guild.realm) == "string" and guild.realm or "",
    }
end

function C.ExportSnapshot(profile, opts)
    local cfg = C.Ensure(profile)
    opts = opts or {}
    local requestedItems = CopyRequestedMap(cfg.requestedItems)
    local events = nil
    if not opts.omitEvents then
        events = {}
        local archive = profile._consumableEventArchive
        if type(archive) == "table" then
            for i = 1, #archive do
                events[#events + 1] = CopyEvent(archive[i])
            end
        end
        for i = 1, #profile._consumableEvents do
            events[#events + 1] = CopyEvent(profile._consumableEvents[i])
        end
    end
    return {
        generation = cfg.generation,
        configSeq = cfg.configSeq,
        eventSeq = cfg.eventSeq,
        ledgerSeq = tonumber(cfg.ledgerSeq) or 0,
        guild = CopyGuild(cfg.guild),
        bankTab = cfg.bankTab,
        requestedItems = requestedItems,
        eligibility = CopyEligibility(EnsureEligibility(cfg)),
        rejections = CopyRejectionList(EnsureRejections(cfg)),
        rejectionSeq = tonumber(cfg.rejectionSeq) or 0,
        pendingWitnesses = CopyPendingWitnessList(EnsurePendingWitnesses(cfg)),
        txnRegistry = CopyTxnRegistry(EnsureTxnRegistry(cfg)),
        txnAllocSeq = tonumber(cfg.txnAllocSeq) or 0,
        events = events,
    }
end

function C.ValidateSnapshot(data)
    if data == nil then return true end
    if type(data) ~= "table" then
        return false, "snapshot.consumables must be a table or nil"
    end
    if data.generation ~= nil and type(data.generation) ~= "number" then
        return false, "snapshot.consumables.generation must be a number"
    end
    if data.configSeq ~= nil and type(data.configSeq) ~= "number" then
        return false, "snapshot.consumables.configSeq must be a number"
    end
    if data.requestedItems ~= nil and type(data.requestedItems) ~= "table" then
        return false, "snapshot.consumables.requestedItems must be a table"
    end
    local okRequested, errRequested = C.ValidateRequestedItems(data.requestedItems)
    if not okRequested then
        return false, errRequested
    end
    -- Legacy development snapshots may still carry crafters/assignments.
    if data.crafters ~= nil and type(data.crafters) ~= "table" then
        return false, "snapshot.consumables.crafters must be a table"
    end
    if data.assignments ~= nil and type(data.assignments) ~= "table" then
        return false, "snapshot.consumables.assignments must be a table"
    end
    if data.events ~= nil and type(data.events) ~= "table" then
        return false, "snapshot.consumables.events must be a table"
    end
    if type(data.events) == "table" then
        for i = 1, #data.events do
            local event = data.events[i]
            if type(event) ~= "table" or type(event.id) ~= "string" or type(event.type) ~= "string" then
                return false, "snapshot.consumables.events contains an invalid event"
            end
            if event.order ~= nil and not C.ValidOrder(event.order) then
                return false, "snapshot.consumables.events contains an invalid order"
            end
        end
    end
    return true
end

function C.ValidGeneration(value)
    local generation = tonumber(value)
    if not generation or generation ~= math.floor(generation) or generation < 1 or generation > C.MAX_EVENT_SEQ then
        return nil
    end
    return generation
end

function C.ValidConfigSeq(value)
    local seq = tonumber(value)
    if not seq or seq ~= seq or seq == math.huge or seq == -math.huge then
        return nil
    end
    if seq ~= math.floor(seq) or seq < 0 or seq > C.MAX_EVENT_SEQ then
        return nil
    end
    return seq
end

function C.ValidOrder(value)
    local order = tonumber(value)
    if not order or order ~= order or order == math.huge or order == -math.huge then
        return nil
    end
    if order ~= math.floor(order) or order < 1 or order > C.MAX_EVENT_SEQ then
        return nil
    end
    return order
end

function C.ValidLedgerSeq(value)
    local seq = tonumber(value)
    if not seq or seq ~= seq or seq == math.huge or seq == -math.huge then
        return nil
    end
    if seq ~= math.floor(seq) or seq < 0 or seq > C.MAX_EVENT_SEQ then
        return nil
    end
    return seq
end

local function RequestedFromPayload(payload)
    if type(payload) ~= "table" then return {} end
    if type(payload.requestedItems) == "table" then
        return CopyRequestedMap(payload.requestedItems)
    end
    -- Migrate legacy assignment snapshots into a flat requested-item list.
    local migrated = {}
    if type(payload.assignments) == "table" then
        for key, row in pairs(payload.assignments) do
            if type(row) == "table" then
                local itemId = tonumber(row.itemId) or tonumber(key)
                local crafters = row.crafters
                if IsItemId(itemId) and (crafters == nil or (type(crafters) == "table" and #crafters > 0)) then
                    migrated[ItemKey(itemId)] = { itemId = itemId, goal = 0 }
                end
            end
        end
    end
    return CopyRequestedMap(migrated)
end

function C.ReplaceConfig(profile, payload)
    if type(payload) ~= "table" then
        return false, "invalid"
    end
    if type(payload.requestedItems) == "table" then
        local okRequested, errRequested = C.ValidateRequestedItems(payload.requestedItems)
        if not okRequested then
            return false, errRequested or "invalid"
        end
    end
    local cfg = C.Ensure(profile)
    local priorGeneration = tonumber(cfg.generation) or 1
    local priorGuid = type(cfg.guild) == "table" and cfg.guild.guid or nil
    local priorTab = tonumber(cfg.bankTab)
    local generation = C.ValidGeneration(payload.generation)
    if generation then
        cfg.generation = generation
    end
    local configSeq = C.ValidConfigSeq(payload.configSeq)
    if configSeq then
        cfg.configSeq = configSeq
    end
    local remoteEventSeq = tonumber(payload.eventSeq)
    if remoteEventSeq and remoteEventSeq == math.floor(remoteEventSeq)
        and remoteEventSeq > (tonumber(cfg.eventSeq) or 0) and remoteEventSeq <= C.MAX_EVENT_SEQ then
        cfg.eventSeq = remoteEventSeq
    end
    local remoteLedger = C.ValidLedgerSeq(payload.ledgerSeq)
    if remoteLedger then
        cfg.ledgerSeq = math.max(tonumber(cfg.ledgerSeq) or 0, remoteLedger)
    end
    cfg.guild = CopyGuild(payload.guild)
    cfg.bankTab = tonumber(payload.bankTab)
    if not IsBankTab(cfg.bankTab) then cfg.bankTab = nil end
    cfg.requestedItems = RequestedFromPayload(payload)
    local incomingGen = tonumber(cfg.generation) or priorGeneration
    local incomingGuid = type(cfg.guild) == "table" and cfg.guild.guid or nil
    local incomingTab = tonumber(cfg.bankTab)
    -- Same generation/guild/tab: merge cutovers conservatively (later wins).
    -- Generation/guild/tab change (Clear, reconfigure): take authoritative eligibility.
    local scopeChanged = incomingGen ~= priorGeneration
        or incomingGuid ~= priorGuid
        or incomingTab ~= priorTab
    if scopeChanged then
        cfg.eligibility = CopyEligibility(payload.eligibility)
    else
        MergeEligibilityInto(cfg, payload.eligibility)
    end
    ReplaceRejectionsFromPayload(cfg, payload, { forceReplace = scopeChanged })
    ReplacePendingWitnessesFromPayload(cfg, payload, { forceReplace = true })
    ReplaceTxnRegistryFromPayload(cfg, payload)
    cfg.crafters = nil
    cfg.assignments = nil
    cfg.itemEpochs = nil
    Invalidate(profile)
    RestoreAdoptedGeneration(profile)
    C.RetainCurrentGeneration(profile)
    Notify()
    return true
end

local function ReconcileAuthoritativeEvents(profile, events)
    local keep = {}
    local accepted = {}
    local Rules = SF.ConsumablesSync
    local limit = #events
    local maxEvents = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
    if limit > maxEvents then limit = maxEvents end
    for i = 1, limit do
        local event = events[i]
        if type(event) == "table" and type(event.id) == "string" and event.id ~= "" then
            keep[event.id] = true
            if C.ValidOrder(event.order) and Rules and Rules.AuthoritativeEventBodyOk
                and Rules.AuthoritativeEventBodyOk(event) then
                accepted[event.id] = true
            end
        end
    end
    -- Only coordinator-stamped valid snapshot rows acknowledge pending sends.
    local queue = profile._consumablesUnsent
    if type(queue) == "table" then
        local pending = {}
        for i = 1, math.min(#queue, maxEvents) do
            if not accepted[queue[i]] then pending[#pending + 1] = queue[i] end
        end
        profile._consumablesUnsent = pending
        queue = pending
    end
    local unsent = {}
    if type(queue) == "table" then
        local queued = #queue
        if queued > maxEvents then queued = maxEvents end
        for i = 1, queued do
            if type(queue[i]) == "string" then
                unsent[queue[i]] = true
            end
        end
    end
    local selfId = SF.NameUtil and SF.NameUtil.GetSelfId and SF.NameUtil.GetSelfId() or nil
    local function authoredUnacked(event)
        if type(event) ~= "table" or type(event.id) ~= "string" then return false end
        if tonumber(event.order) ~= nil then return false end
        if keep[event.id] or unsent[event.id] then return false end
        if type(selfId) ~= "string" or selfId == "" then return false end
        return Rules and Rules.RemoteEventIdOk and Rules.RemoteEventIdOk(event.id, selfId) and true or false
    end
    local function canonicalCredit(event)
        return type(event) == "table"
            and event.type == C.EVENT.DONATION
            and event.source == "guildbank"
            and ValidTxnId(event.txnId) ~= nil
    end
    local function keepEvent(event)
        if type(event) ~= "table" or type(event.id) ~= "string" then return false end
        if keep[event.id] or unsent[event.id] then return true end
        -- Sent, then dropped before the coordinator stamped it. The id still names this client.
        if authoredUnacked(event) then return true end
        -- Incomplete coordinator snapshots must not erase Spectrum-owned credits.
        return canonicalCredit(event)
    end
    local function filterList(list)
        local keptRows = {}
        local removed = false
        if type(list) ~= "table" then return keptRows, false end
        for i = 1, #list do
            if keepEvent(list[i]) then
                keptRows[#keptRows + 1] = list[i]
            else
                removed = true
            end
        end
        return keptRows, removed
    end
    local live, liveRemoved = filterList(profile._consumableEvents)
    local archive, archiveRemoved = filterList(profile._consumableEventArchive)
    local requeued = false
    for i = 1, #live do
        local event = live[i]
        local shouldResend = authoredUnacked(event)
            or (canonicalCredit(event) and not keep[event.id] and not unsent[event.id])
        if shouldResend then
            if type(queue) ~= "table" then
                queue = {}
                profile._consumablesUnsent = queue
            end
            if #queue >= maxEvents then break end
            if not unsent[event.id] then
                queue[#queue + 1] = event.id
                unsent[event.id] = true
                requeued = true
            end
        end
    end
    if not liveRemoved and not archiveRemoved then return requeued end
    profile._consumableEvents = live
    profile._consumableEventArchive = archive
    RebuildIndex(profile)
    Invalidate(profile)
    Notify()
    return true
end

local function PreferEvictableArchiveRows(profile, preserveIds)
    if type(preserveIds) ~= "table" then return end
    local archive = ArchiveList(profile)
    local count = #archive
    if count == 0 then return end
    local maxScan = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
    local limit = count
    if limit > maxScan then limit = maxScan end
    local evictable = {}
    local kept = {}
    for i = 1, limit do
        local row = archive[i]
        local id = type(row) == "table" and row.id or nil
        if type(id) == "string" and preserveIds[id] then
            kept[#kept + 1] = row
        else
            evictable[#evictable + 1] = row
        end
    end
    if #evictable == 0 then return end
    local ordered = {}
    for i = 1, #evictable do
        ordered[#ordered + 1] = evictable[i]
    end
    for i = 1, #kept do
        ordered[#ordered + 1] = kept[i]
    end
    for i = limit + 1, count do
        ordered[#ordered + 1] = archive[i]
    end
    profile._consumableEventArchive = ordered
end

function C.MergeSnapshot(profile, data, opts)
    C.Ensure(profile)
    if data == nil then return true end
    local ok, err = C.ValidateSnapshot(data)
    if not ok then return false, err end
    local localDesc = C.Descriptor(profile)
    local remoteGen = C.ValidGeneration(data.generation)
    if not remoteGen then
        if data.generation == nil then
            remoteGen = 1
        else
            remoteGen = tonumber(profile._consumables.generation) or 1
        end
    end
    local remoteSeq = C.ValidConfigSeq(data.configSeq) or 0
    opts = type(opts) == "table" and opts or {}
    local fromCoordinator = opts.consumablesFromCoordinator == true
    local adoptSession = profile._consumablesAdoptNextSnapshot
    local epoch = 0
    local syncState = SF.LootHelperSync and SF.LootHelperSync.state
    local sessionActive = type(syncState) == "table" and syncState.active == true
    if opts.consumablesFromCoordinator == false then
        local Rules = SF.ConsumablesSync
        local cfg = profile._consumables
        if type(data.events) == "table" and Rules and Rules.ApplyRemoteEvent and Rules.RelayWriter then
            local limit = #data.events
            local maxEvents = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
            if limit > maxEvents then limit = maxEvents end
            for i = 1, limit do
                local event = data.events[i]
                -- RelayWriter binds event.id to event.writer. Local commits may lack
                -- order until a coordinator flush; do not require order up front.
                local writer = Rules.RelayWriter and Rules.RelayWriter(event) or nil
                if writer then
                    -- Accept previously stamped, writer-bound rows. Admin-authored
                    -- rows always qualify. Stamped guildbank donations with a
                    -- Spectrum txnId also qualify so three-witness credits
                    -- (writer may be a non-admin witness) survive peer recovery.
                    local stampedDonation = type(event) == "table"
                        and event.type == C.EVENT.DONATION
                        and ValidTxnId(event.txnId)
                        and (not Rules.AuthoritativeEventBodyOk
                            or Rules.AuthoritativeEventBodyOk(event))
                    if C.IsCanonicalAdmin(profile, writer) or stampedDonation then
                        Rules.ApplyRemoteEvent(profile, event, nil, {
                            coordinatorRelay = true,
                            silent = true,
                            skipGrantUse = true,
                        })
                    end
                end
            end
        end
        -- Peer snapshots do not replace full config, but must union-merge the
        -- canonical registry so recovery does not depend on re-authoring events.
        -- Peers are not authorities for durable rejection lists: PreferRegistryEntry
        -- already reconciles registry rejection↔approval by decidedAt.
        if type(cfg) == "table" then
            if type(data.txnRegistry) == "table" then
                local filtered = {
                    txnAllocSeq = data.txnAllocSeq,
                    txnRegistry = {},
                }
                for i = 1, #data.txnRegistry do
                    local row = data.txnRegistry[i]
                    if type(row) == "table" and ValidTxnId(row.txnId) then
                        local known = C.FindRegistryTxn(profile, row.txnId) ~= nil
                            or (C.HasTxnId and C.HasTxnId(profile, row.txnId))
                        local adminDecision = type(row.decidedBy) == "string"
                            and row.decidedBy ~= ""
                            and C.IsCanonicalAdmin(profile, row.decidedBy)
                        -- After stamped events apply above, matching ledger txnIds
                        -- authorize the registry row even when decidedBy was a witness.
                        local hasLedger = C.HasTxnId and C.HasTxnId(profile, row.txnId)
                        if known or adminDecision or hasLedger then
                            filtered.txnRegistry[#filtered.txnRegistry + 1] = row
                        end
                    end
                end
                ReplaceTxnRegistryFromPayload(cfg, filtered)
            end
            if type(data.pendingWitnesses) == "table" then
                ReplacePendingWitnessesFromPayload(cfg, data, { forceReplace = false })
            end
        end
        Notify()
        return true
    end
    if fromCoordinator and sessionActive then
        epoch = tonumber(syncState.coordEpoch) or 0
    end
    local snapshotCurrent = true
    if SF.ConsumablesSync and SF.ConsumablesSync.WatermarkAdmits then
        snapshotCurrent = SF.ConsumablesSync.WatermarkAdmits(profile, remoteGen, remoteSeq, epoch)
    end
    local replace
    if fromCoordinator then
        replace = snapshotCurrent
    else
        replace = remoteGen > localDesc.generation
            or (remoteGen == localDesc.generation and remoteSeq >= localDesc.configSeq)
            or (adoptSession and remoteGen >= localDesc.generation and snapshotCurrent)
    end
    if replace and remoteGen ~= (tonumber(profile._consumables.generation) or 1) then
        profile._consumables.generation = remoteGen
        C.RetainCurrentGeneration(profile)
    end
    local replacedBody = false
    if fromCoordinator and replace and type(data.events) == "table" then
        local preserveIds = {}
        local preserveLimit = #data.events
        local maxEvents = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
        if preserveLimit > maxEvents then preserveLimit = maxEvents end
        for i = 1, preserveLimit do
            local event = data.events[i]
            if type(event) == "table" and type(event.id) == "string" and event.id ~= "" then
                preserveIds[event.id] = true
            end
        end
        PreferEvictableArchiveRows(profile, preserveIds)
    end
    local deferred = nil
    if type(data.events) == "table" then
        local limit = #data.events
        local maxEvents = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
        if limit > maxEvents then limit = maxEvents end
        local Rules = SF.ConsumablesSync
        for i = 1, limit do
            local event = data.events[i]
            if fromCoordinator and replace and Rules and Rules.AuthoritativeEventBodyOk
                and not Rules.AuthoritativeEventBodyOk(event) then
                -- Skip invalid donation/reset bodies that live ApplyRemoteEvent would reject.
            else
                local _, status = C.AppendEvent(profile, event, {
                    silent = true,
                    replaceBody = fromCoordinator and replace,
                })
                if status == "replaced" then replacedBody = true end
                if fromCoordinator and replace and (status == "full" or status == "quota") then
                    deferred = deferred or {}
                    local deferredCap = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
                    if #deferred < deferredCap then
                        deferred[#deferred + 1] = event
                    end
                end
            end
        end
    end
    if replacedBody then RebuildIndex(profile) end
    profile._consumablesAdoptNextSnapshot = nil
    if replace then
        C.ReplaceConfig(profile, data)
        if fromCoordinator and type(data.events) == "table" then
            ReconcileAuthoritativeEvents(profile, data.events)
        end
        if fromCoordinator and type(deferred) == "table" then
            local retryLimit = #deferred
            local deferredCap = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
            if retryLimit > deferredCap then retryLimit = deferredCap end
            for i = 1, retryLimit do
                local event = deferred[i]
                local Rules = SF.ConsumablesSync
                if Rules and Rules.AuthoritativeEventBodyOk and not Rules.AuthoritativeEventBodyOk(event) then
                    -- Skip invalid deferred bodies.
                else
                    local _, status = C.AppendEvent(profile, event, {
                        silent = true,
                        replaceBody = true,
                    })
                    if status == "replaced" then replacedBody = true end
                end
            end
            if replacedBody then RebuildIndex(profile) end
        end
        if adoptSession then
            profile._consumablesConfigAdoptedSession = adoptSession
        end
        if SF.ConsumablesSync and SF.ConsumablesSync.NoteCoordinatorWatermark then
            SF.ConsumablesSync.NoteCoordinatorWatermark(profile, remoteGen, remoteSeq, epoch)
        end
    else
        Notify()
    end
    return true
end

function C.CopyConfiguration(source, dest)
    local src = C.Ensure(source)
    C.Ensure(dest)
    dest._consumableEvents = {}
    dest._consumableEventArchive = {}
    dest._consumableEventIds = nil
    dest._consumableIndexCount = nil
    dest._consumablesPendingFreezes = nil
    C.InvalidateEventIndex(dest)
    dest._consumables = {
        generation = 1,
        configSeq = 0,
        eventSeq = 0,
        ledgerSeq = 0,
        guild = CopyGuild(src.guild),
        bankTab = src.bankTab,
        requestedItems = CopyRequestedMap(src.requestedItems),
        eligibility = CopyEligibility(EnsureEligibility(src)),
        rejections = CopyRejectionList(EnsureRejections(src)),
        rejectionSeq = tonumber(src.rejectionSeq) or 0,
        pendingWitnesses = CopyPendingWitnessList(EnsurePendingWitnesses(src)),
        -- Fresh ledger on the destination: do not copy canonical txn identities
        -- without their donation events (would invite registry-only double credit).
        txnRegistry = {},
        txnAllocSeq = 0,
        obsAccountingSchema = C.OBS_ACCOUNTING_SCHEMA,
    }
    Invalidate(dest)
    Invalidate(source)
    return true
end

function C.ApplyOp(profile, op, actor, opts)
    if type(op) ~= "table" or type(op.name) ~= "string" then
        return false, "Unknown configuration change."
    end
    if op.name == "add_item" then
        return C.AddRequestedItem(profile, actor, op.itemId, opts)
    elseif op.name == "remove_item" then
        return C.RemoveRequestedItem(profile, actor, op.itemId, opts)
    elseif op.name == "set_goal" then
        return C.SetRequestedGoal(profile, actor, op.itemId, op.goal, opts)
    elseif op.name == "set_guild" then
        return C.SetGuild(profile, actor, op.guild, op.bankTab, opts)
    elseif op.name == "set_bank_tab" then
        return C.SetBankTab(profile, actor, op.bankTab, opts)
    elseif op.name == "clear" then
        return C.Clear(profile, actor, opts)
    end
    return false, "Unknown configuration change."
end

function C.CommitEvents(profile, token, events, opts)
    if type(token) ~= "string" or token == "" then
        return false, "Missing transaction id."
    end
    opts = type(opts) == "table" and opts or {}
    local writer = opts.writer
    local Rules = SF.ConsumablesSync
    local wrote = false
    local failed = nil
    local added = {}
    local evicted = {}
    for i = 1, #(events or {}) do
        local event = events[i]
        if type(event) == "table" then
            event.id = string.format("ce:%s:%s:%d", tostring(profile._profileId or "profile"), token, i)
            if type(writer) == "string" and writer ~= "" and type(event.writer) ~= "string" then
                if Rules and Rules.RemoteEventIdOk and Rules.RemoteEventIdOk(event.id, writer) then
                    event.writer = writer
                end
            end
            local ok, status, dropped = C.AppendEvent(profile, event, {
                silent = true,
                collectEvicted = true,
            })
            NoteCollectedEvictions(evicted, dropped)
            if not ok then
                failed = status or "Could not record that raid supplies change."
                break
            elseif status ~= "duplicate" then
                wrote = true
                added[#added + 1] = event.id
            end
        end
    end
    if failed and (#added > 0 or #evicted > 0) then
        local drop = {}
        for i = 1, #added do
            drop[added[i]] = true
        end
        local function keepRows(list)
            local kept = {}
            if type(list) ~= "table" then return kept end
            for i = 1, #list do
                local row = list[i]
                if not (type(row) == "table" and drop[row.id]) then
                    kept[#kept + 1] = row
                end
            end
            return kept
        end
        profile._consumableEvents = keepRows(profile._consumableEvents)
        profile._consumableEventArchive = keepRows(profile._consumableEventArchive)
        for i = #evicted, 1, -1 do
            RestoreArchivedFront(profile, evicted[i])
        end
        RebuildIndex(profile)
        Invalidate(profile)
        wrote = false
    end
    if wrote then
        Debug("Info", "Committed transaction %s", token)
        Notify()
    end
    if failed == "full" then
        return false, "The raid supplies ledger is full. Older entries stay in the log."
    end
    if failed == "quota" then
        return false, "That character has reached the raid-supply event limit for this configuration."
    end
    if failed then
        return false, failed
    end
    return true
end

function C.SettingsModel(profile, actor, asAdmin)
    local cfg = C.Ensure(profile)
    local rows = {}
    for _, row in pairs(cfg.requestedItems or {}) do
        local itemId = type(row) == "table" and tonumber(row.itemId) or nil
        if IsItemId(itemId) then
            rows[#rows + 1] = {
                itemId = itemId,
                text = tostring(itemId),
                goal = C.ValidGoal(row.goal) or 0,
                canRemove = asAdmin and true or false,
                canEditGoal = asAdmin and true or false,
            }
        end
    end
    table.sort(rows, function(a, b) return a.itemId < b.itemId end)
    local guildText = "No guild configured."
    if cfg.guild and cfg.guild.guid then
        guildText = string.format("%s (%s) · tab %s", cfg.guild.name ~= "" and cfg.guild.name or cfg.guild.guid, cfg.guild.guid, tostring(cfg.bankTab or ""))
    end
    return {
        isAdmin = asAdmin and true or false,
        canEditGuild = asAdmin and true or false,
        guildLocked = cfg.guild ~= nil and cfg.guild.guid ~= nil,
        canClear = asAdmin and true or false,
        canManageItems = asAdmin and true or false,
        guildText = guildText,
        bankTab = cfg.bankTab,
        requestedItems = rows,
        clearWarning = C.ClearConfirmation(profile),
    }
end

-- Suggested donation quantity for the Guild Bank helper. Finite goals guide the
-- default amount; goal 0 stays unlimited. A completed finite goal suggests 0 and
-- is reported as goalComplete so the UI can hide deposit controls.
function C.SuggestedDonationQuantity(available, goal, donated)
    available = math.floor(tonumber(available) or 0)
    if available < 0 then available = 0 end
    goal = C.ValidGoal(goal)
    if goal == nil then goal = 0 end
    donated = math.floor(tonumber(donated) or 0)
    if donated < 0 then donated = 0 end
    if goal == 0 then
        return available, false
    end
    if donated >= goal then
        return 0, true
    end
    local remaining = goal - donated
    if remaining > available then remaining = available end
    return remaining, false
end

function C.BuildDonationPlan(profile, carried, ctx)
    ctx = ctx or {}
    local cfg = C.Ensure(profile)
    local progress = C.GoalProgress(profile)
    local byItem = {}
    for i = 1, #(progress.items or {}) do
        local entry = progress.items[i]
        if entry and entry.itemId then
            byItem[entry.itemId] = entry
        end
    end
    local lines = {}
    for i = 1, #(carried or {}) do
        local row = carried[i]
        local itemId = tonumber(row.itemId)
        local available = math.floor(tonumber(row.available ~= nil and row.available or row.quantity) or 0)
        if C.IsRequested(profile, itemId) and available > 0 and ctx.guildBankUsable then
            local entry = byItem[itemId]
            local goal = entry and entry.goal or 0
            local donated = entry and entry.donated or 0
            local suggested, goalComplete = C.SuggestedDonationQuantity(available, goal, donated)
            local noGoal = goal == 0
            lines[#lines + 1] = {
                itemId = itemId,
                available = available,
                quantity = suggested,
                suggested = suggested,
                goal = goal,
                donated = donated,
                percent = entry and entry.percent or nil,
                noGoal = noGoal,
                goalComplete = goalComplete and true or false,
                quality = row.quality,
                name = row.name,
                generation = cfg.generation,
                guildBank = true,
            }
        end
    end
    table.sort(lines, function(a, b) return a.itemId < b.itemId end)
    return {
        lines = lines,
        groups = { { key = "Guild Bank", lines = lines } },
        progress = progress,
    }
end

function C.RevalidateDonation(profile, line, ctx, inventoryQty)
    if type(line) ~= "table" then
        return false, "Review the donation again."
    end
    local cfg = C.Ensure(profile)
    if tonumber(line.generation) ~= cfg.generation then
        return false, "The active profile configuration changed. Review the donation again."
    end
    if not C.IsRequested(profile, line.itemId) then
        return false, "That item is no longer requested."
    end
    inventoryQty = math.floor(tonumber(inventoryQty) or 0)
    if inventoryQty < math.floor(tonumber(line.quantity) or 0) then
        return false, "You no longer have that many."
    end
    if not (ctx and ctx.guildBankUsable) then
        return false, "No Guild Bank donation path is available."
    end
    -- Completed finite goals must not start a new deposit, including stale clicks.
    -- Incomplete goals may still intentionally over-donate within inventory limits.
    local progress = C.GoalProgress(profile)
    for i = 1, #(progress.items or {}) do
        local entry = progress.items[i]
        if entry and entry.itemId == tonumber(line.itemId) and not entry.noGoal then
            if (tonumber(entry.donated) or 0) >= (tonumber(entry.goal) or 0) then
                return false, Loc("RAID_SUPPLIES_GOAL_ALREADY_MET", "That item's donation goal is already met.")
            end
            break
        end
    end
    return true
end

function C.ItemIdFromText(text)
    local id = nil
    if type(text) == "number" then
        id = text
    elseif type(text) == "string" then
        id = tonumber(text)
        if not IsItemId(id) then
            id = tonumber(text:match("item:(%d+)"))
        end
    end
    if not IsItemId(id) then return nil end
    return id
end

if SF.LootProfile then
    function SF.LootProfile:EnsureConsumables()
        return C.Ensure(self)
    end
end
