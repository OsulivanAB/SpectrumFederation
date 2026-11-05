-- Guild Supplies donation evidence, ledger, and identity links (#388, #411).
-- One current officer's direct Guild Bank observation verifies a donation.
-- Otherwise three independent witnesses do. Accepted officer provenance is
-- durable guild history and may be relayed by a later guildmate (#411).
-- Reuses ConsumablesObservation matching; does not call profile AreSameIdentity or
-- ConsumablesVerification admin/session commit paths as guild authority.
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies
local O = SF.ConsumablesObservation

GS.WITNESS_THRESHOLD = 3
GS.MAX_WITNESSES_PER_CLUSTER = 16
GS.MAX_PENDING_EVIDENCE = 128
-- Aggregate unfinished pending across all campaign buckets (not per arbitrary key).
GS.MAX_PENDING_EVIDENCE_TOTAL = 256
-- Per authenticated witness: max unfinished clusters they already appear in when
-- opening a *new* cluster. Joining existing clusters is unaffected.
GS.MAX_PENDING_EVIDENCE_PER_WITNESS = 32
-- Headroom reserved for local bank observations under the per-campaign/total caps.
GS.RESERVED_LOCAL_PENDING_EVIDENCE = 16
-- Event-driven stale unfinished pending reclaim (align with ConsumablesObservation).
GS.PENDING_EVIDENCE_TTL_SECONDS = 14 * 24 * 60 * 60
GS.MAX_IDENTITY_LINK_GROUPS = 64
GS.MAX_GUIDS_PER_LINK_GROUP = 16
GS.MAX_LEDGER_EVENTS = 4096
-- Prior-generation rows shelved out of the live list (projection + gossip).
GS.MAX_ARCHIVED_EVENTS = 4096
GS.MAX_TXN_REGISTRY = 512
GS.MAX_TXN_ID = 160
-- Trusted alias→canonical credit bindings that must outlive txn-registry eviction (#459).
GS.MAX_CREDIT_EVENT_ALIASES = 2048
GS.MAX_OBS_QUANTITY = 100000
GS.MAX_PENDING_ADJUSTMENTS = 32
GS.MAX_PENDING_DONATION_CANDIDATES = 256
GS.MAX_DIRECT_EVIDENCE_EXPORTS = 256
GS.MAX_TXN_CONFLICT_KEYS = 64
GS.MAX_TXN_CONFLICT_BODIES = 8
--- Max seconds a correction timestamp may exceed GetServerTime() at admission (#459).
-- Wall-clock skew is an acceptance check only — never part of saved-body shape validation.
-- Small production clock-skew ceiling (not fixture chronology). Catch-up makes authored
-- timestamps older at the receiver, not hours ahead; synthetic tests must use realistic clocks.
GS.CORRECT_CONTRIBUTOR_TIMESTAMP_SKEW = 600

GS.LEDGER_EVENT = {
    DONATION = "donation",
    ADJUSTMENT = "adjustment",
    -- #457 informational Quick Withdraw receipts (never production credit).
    WITHDRAWAL = "withdrawal",
}

GS.VERIFICATION = {
    WITNESSES = "witnesses",
    OFFICER = "officer",
}

--- Distinct from legitimate Unassigned (nil attribution) and ordinary zero totals.
GS.CREDIT_UNAVAILABLE = "credit_unavailable"

--- Independent per-callback work ceiling for credit projection rebuild/redrive (#459).
-- Not derived from measured fixture cost. Ordinary small histories finish in one
-- slice; conflict-heavy prune and multi-admit catch-up yield via C_Timer.
-- Sized so a typical maxAttempts=32 wave of light rebuilds fits; tests may lower
-- via GS._creditProjectionWorkBudgetOverride.
GS.CREDIT_PROJECTION_WORK_BUDGET = 16384
--- Max measured work a single atomic prune/baseline step may exceed the soft
-- callback ceiling by before yielding (#459). Not an exemption for a full rebuild.
GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT = 512

--- Durable verification label. Unknown values stay on the three-witness mode.
function GS.CanonicalVerificationMode(mode)
    if mode == GS.VERIFICATION.OFFICER then
        return GS.VERIFICATION.OFFICER
    end
    return GS.VERIFICATION.WITNESSES
end

local function Loc(key, default)
    if SF.LocaleText then
        return SF.LocaleText(key, default)
    end
    return default or key
end

local function Debug(level, message, ...)
    if SF.Debug and SF.Debug[level] then
        SF.Debug[level](SF.Debug, "GUILD_SUPPLIES", message, ...)
    end
end

local function Now()
    if GetServerTime then
        local t = GetServerTime()
        if type(t) == "number" and t == t and t >= 0 then
            return math.floor(t)
        end
    end
    return math.floor(time() or 0)
end

local function IsWithdrawalLedgerEvent(event)
    if type(event) ~= "table" then
        return false
    end
    local t = event.type
    return t == GS.LEDGER_EVENT.WITHDRAWAL or t == "withdrawal"
end

local function CountNonWithdrawalEvents(list)
    local n = 0
    if type(list) ~= "table" then
        return 0
    end
    for i = 1, #list do
        if not IsWithdrawalLedgerEvent(list[i]) then
            n = n + 1
        end
    end
    return n
end

local function MaxLiveLedgerScan()
    return (GS.MAX_LEDGER_EVENTS or 4096) + (GS.MAX_WITHDRAWAL_EVENTS or 1024)
end

local function MaxArchivedLedgerScan()
    return (GS.MAX_ARCHIVED_EVENTS or 4096) + (GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024)
end

local function FloorNonNeg(n)
    n = tonumber(n) or 0
    if n < 0 then return 0 end
    return math.floor(n)
end

local function NormName(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(name) or name
    end
    return name
end

local function ValidGuid(guid)
    if type(guid) ~= "string" or guid == "" or #guid > 64 then
        return nil
    end
    return guid
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

local function IsItemId(itemId)
    return type(itemId) == "number" and itemId > 0 and itemId == math.floor(itemId)
end

local function CopyStringList(list, limit)
    local out = {}
    if type(list) ~= "table" then return out end
    local n = #list
    if type(limit) == "number" and n > limit then n = limit end
    for i = 1, n do
        if type(list[i]) == "string" and list[i] ~= "" then
            out[#out + 1] = list[i]
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Legacy identityLinks storage (inert; Guild Info owns witness identity #427)
-- Retained only so existing SavedVariables / historical link ops still load.
---------------------------------------------------------------------------

function GS.EmptyIdentityLinks()
    return {
        schemaVersion = 1,
        groups = {},
        byGuid = {},
        revisionId = nil,
    }
end

local function EnsureIdentityLinks(record)
    if type(record.identityLinks) ~= "table" then
        record.identityLinks = GS.EmptyIdentityLinks()
    end
    local links = record.identityLinks
    if type(links.groups) ~= "table" then links.groups = {} end
    if type(links.byGuid) ~= "table" then links.byGuid = {} end
    return links
end

function GS.ValidateIdentityLinks(links)
    if links == nil then
        return true
    end
    if type(links) ~= "table" then
        return false, "invalid_identity_links"
    end
    if type(links.groups) ~= "table" or type(links.byGuid) ~= "table" then
        return false, "invalid_identity_links"
    end
    local maxGroups = GS.MAX_IDENTITY_LINK_GROUPS or 64
    local maxPerGroup = GS.MAX_GUIDS_PER_LINK_GROUP or 16
    local groupCount = 0
    local expectedByGuid = {}
    local guidCount = 0
    for gid, group in pairs(links.groups) do
        groupCount = groupCount + 1
        if groupCount > maxGroups then
            return false, "full"
        end
        if type(gid) ~= "string" or gid == "" or #gid > (GS.MAX_OPERATION_ID or 192) then
            return false, "invalid_identity_links"
        end
        if type(group) ~= "table" or type(group.guids) ~= "table" then
            return false, "invalid_identity_links"
        end
        if #group.guids > maxPerGroup then
            return false, "full"
        end
        local seenInGroup = {}
        for i = 1, #group.guids do
            local g = ValidGuid(group.guids[i])
            if not g then
                return false, "invalid_identity_links"
            end
            if seenInGroup[g] then
                return false, "invalid_identity_links"
            end
            seenInGroup[g] = true
            if expectedByGuid[g] and expectedByGuid[g] ~= gid then
                return false, "invalid_identity_links"
            end
            expectedByGuid[g] = gid
            guidCount = guidCount + 1
            if guidCount > maxGroups * maxPerGroup then
                return false, "full"
            end
        end
    end
    -- Derived index must be bounded and exactly agree with canonical groups.
    local byCount = 0
    for g, gid in pairs(links.byGuid) do
        byCount = byCount + 1
        if byCount > guidCount then
            return false, "invalid_identity_links"
        end
        if not ValidGuid(g) or expectedByGuid[g] ~= gid then
            return false, "invalid_identity_links"
        end
    end
    if byCount ~= guidCount then
        return false, "invalid_identity_links"
    end
    return true
end

local function GuildKeyForRecord(record)
    if type(record) ~= "table" then
        return nil
    end
    if type(record._guildKey) == "string" and record._guildKey ~= "" then
        return record._guildKey
    end
    if type(record.guildKey) == "string" and record.guildKey ~= "" then
        return record.guildKey
    end
    return nil
end

--- True when Guild Info relationships are authoritative for this guild.
-- Incomplete / synchronizing / unavailable baselines must not invent independence.
function GS.WitnessRelationshipsReady(record)
    local GI = SF.GuildInfo
    if not GI or type(GI.GetRelationshipReadiness) ~= "function" then
        return false, "unavailable"
    end
    local status = GI:GetRelationshipReadiness(GuildKeyForRecord(record))
    return status == "ready", status
end

--- same | different | unknown for authenticated witness GUIDs via Guild Info.
function GS.CompareWitnessIdentities(record, guidA, guidB)
    guidA, guidB = ValidGuid(guidA), ValidGuid(guidB)
    if not guidA or not guidB then
        return "unknown"
    end
    if guidA == guidB then
        return "same"
    end
    local GI = SF.GuildInfo
    if not GI or type(GI.CompareWitnessIdentities) ~= "function" then
        return "unknown"
    end
    local cmp = GI:CompareWitnessIdentities(guidA, guidB, GuildKeyForRecord(record))
    if cmp == "same" or cmp == "different" or cmp == "unknown" then
        return cmp
    end
    return "unknown"
end

--- Known-same only. Unknown relationship state is not "same".
function GS.AreSameWitnessIdentity(record, guidA, guidB)
    return GS.CompareWitnessIdentities(record, guidA, guidB) == "same"
end

function GS.WitnessAlreadyCounted(record, witnessMap, witnessGuid)
    witnessGuid = ValidGuid(witnessGuid)
    if not witnessGuid or type(witnessMap) ~= "table" then
        return true
    end
    for key, row in pairs(witnessMap) do
        local prior = type(row) == "table" and ValidGuid(row.guid or row.witnessGuid) or ValidGuid(key)
        if prior and GS.AreSameWitnessIdentity(record, prior, witnessGuid) then
            return true
        end
    end
    return false
end

--- Independent witness count under current Guild Info relationships.
-- Returns 0 when relationships are unavailable/syncing so quorum stays pending.
-- Witnesses whose contributor identity is unknown (e.g. unresolved group) are
-- excluded so they cannot satisfy three-independent-witness quorum.
function GS.CountIndependentWitnesses(record, witnessMap)
    if type(witnessMap) ~= "table" then return 0 end
    local ready = GS.WitnessRelationshipsReady(record)
    if not ready then
        return 0
    end
    local GI = SF.GuildInfo
    local guildKey = GuildKeyForRecord(record)
    local keys = {}
    for key, row in pairs(witnessMap) do
        local guid = type(row) == "table" and ValidGuid(row.guid or row.witnessGuid) or ValidGuid(key)
        if guid then
            local usable = true
            if GI and type(GI.ResolveContributorIdentity) == "function" then
                local info = GI:ResolveContributorIdentity(guid, guildKey)
                if type(info) ~= "table" or info.status == "unknown" then
                    usable = false
                end
            end
            if usable then
                keys[#keys + 1] = guid
            end
        end
    end
    table.sort(keys)
    local counted = {}
    local n = 0
    for i = 1, #keys do
        local guid = keys[i]
        local skip = false
        for j = 1, #counted do
            local cmp = GS.CompareWitnessIdentities(record, counted[j], guid)
            if cmp == "same" then
                skip = true
                break
            elseif cmp == "unknown" then
                -- Fail closed: unresolved pairwise relationship cannot grow quorum.
                return 0
            end
        end
        if not skip then
            counted[#counted + 1] = guid
            n = n + 1
        end
    end
    return n
end

---------------------------------------------------------------------------
-- Donation / adjustment display attribution via Guild Info (#427)
-- Durable actor/attributed strings stay immutable; projection is read-only.
---------------------------------------------------------------------------

--- Bounded read-only resolution context for one projection/history pass.
-- Validates Guild Info readiness once and reuses name/GUID mappings. Not a
-- second identity authority and not a persistent cache across operations.
-- @return table ctx
function GS.BeginContributorProjectionContext(record)
    local guildKey = GuildKeyForRecord(record)
    local ready, status = false, "unavailable"
    local GI = SF.GuildInfo
    if GI and type(GI.GetRelationshipReadiness) == "function" then
        status = select(1, GI:GetRelationshipReadiness(guildKey))
        ready = status == "ready"
    end
    return {
        record = record,
        guildKey = guildKey,
        ready = ready and true or false,
        status = status,
        readinessChecked = true,
        nameToGuid = {},
        nameErr = {},
        byGuid = {},
        byKey = {},
        readinessChecks = 1,
        nameResolves = 0,
        identityResolves = 0,
    }
end

local function ContextResolveGuidByName(ctx, original)
    if type(original) ~= "string" or original == "" then
        return nil, "identity_unavailable"
    end
    if ctx.nameToGuid[original] ~= nil then
        local cached = ctx.nameToGuid[original]
        if cached == false then
            return nil, ctx.nameErr[original]
        end
        return cached, nil
    end
    local GI = SF.GuildInfo
    if not GI or type(GI.ResolveCharacterGuidByName) ~= "function" then
        ctx.nameToGuid[original] = false
        ctx.nameErr[original] = "unavailable"
        return nil, "unavailable"
    end
    ctx.nameResolves = (ctx.nameResolves or 0) + 1
    local resolved, err = GI:ResolveCharacterGuidByName(original, ctx.guildKey)
    if type(resolved) == "string" then
        local guid = ValidGuid(resolved)
        ctx.nameToGuid[original] = guid or false
        if not guid then
            ctx.nameErr[original] = "invalid_guid"
            return nil, "invalid_guid"
        end
        return guid, nil
    end
    ctx.nameToGuid[original] = false
    ctx.nameErr[original] = err or "not_a_member"
    return nil, err
end

local function ContextResolveIdentity(ctx, guid)
    guid = ValidGuid(guid)
    if not guid then
        return nil
    end
    local cached = ctx.byGuid[guid]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    local GI = SF.GuildInfo
    if not GI or type(GI.ResolveContributorIdentity) ~= "function" then
        ctx.byGuid[guid] = false
        return nil
    end
    ctx.identityResolves = (ctx.identityResolves or 0) + 1
    local info = GI:ResolveContributorIdentity(guid, ctx.guildKey)
    if type(info) ~= "table" or info.status == "unknown" then
        ctx.byGuid[guid] = false
        return nil
    end
    ctx.byGuid[guid] = info
    return info
end

--- Unique donor/attributed GUID when relationships are ready. Never guesses.
-- @return string|nil guid
function GS.ResolveUniqueCharacterGuid(record, name, hintGuid)
    local guid = ValidGuid(hintGuid)
    if guid then
        return guid
    end
    name = NormName(name)
    if not name then
        return nil
    end
    if not GS.WitnessRelationshipsReady(record) then
        return nil
    end
    local GI = SF.GuildInfo
    if not GI or type(GI.ResolveCharacterGuidByName) ~= "function" then
        return nil
    end
    local resolved, err = GI:ResolveCharacterGuidByName(name, GuildKeyForRecord(record))
    if type(resolved) == "string" and err == nil then
        return ValidGuid(resolved)
    end
    return nil
end

--- True when Guild Info currently displays `name` for `guid` (ready baseline).
-- Membership alone is insufficient; the GUID's current nameRealm must match.
local function GuidCurrentNameMatches(record, guid, name)
    guid = ValidGuid(guid)
    name = NormName(name)
    if not guid or not name or not GS.WitnessRelationshipsReady(record) then
        return false
    end
    local GI = SF.GuildInfo
    if not GI or type(GI.GetRelationshipReadiness) ~= "function" then
        return false
    end
    local readiness, giRec = GI:GetRelationshipReadiness(GuildKeyForRecord(record))
    if readiness ~= "ready" or type(giRec) ~= "table" then
        return false
    end
    local char = giRec.characters and giRec.characters[guid]
    if type(char) == "table" and NormName(char.nameRealm) == name then
        return true
    end
    local member = giRec.members and giRec.members[guid]
    if type(member) == "table" and NormName(member.nameRealm) == name then
        return true
    end
    return false
end

-- Ephemeral name↔GUID provenance index for paced BindCharacterIdentity (#459).
-- Built once per dependency stamp (or during credit baseline) and consulted
-- instead of rescanning up to 10,240 rows per unresolved identity.
local creditProvenanceIndexCache = setmetatable({}, { __mode = "k" })
local creditProvenanceIndexActive = setmetatable({}, { __mode = "k" })

local function ProvenancePairKey(name, guid)
    return tostring(name) .. "\0" .. tostring(guid)
end

local function NoteCreditProvenancePair(map, name, guid)
    name = NormName(name)
    guid = ValidGuid(guid)
    if name and guid and type(map) == "table" then
        map[ProvenancePairKey(name, guid)] = true
    end
end

local function NoteCreditProvenanceFromEvent(map, ev)
    if type(ev) ~= "table" or type(map) ~= "table" then
        return
    end
    -- Informational withdrawal receipts must not establish donor/attributed
    -- name↔GUID provenance (live or archived).
    if IsWithdrawalLedgerEvent(ev) then
        return
    end
    NoteCreditProvenancePair(map, ev.actor, ev.actorGuid)
    NoteCreditProvenancePair(map, ev.donor, ev.donorGuid or ev.actorGuid)
    NoteCreditProvenancePair(map, ev.attributed, ev.attributedGuid)
end

local function CreditProvenanceDependencyStamp(record)
    -- Ledger provenance depends on accounting rows, not ops generation. Including
    -- opsGen would rebuild the index after every accepted correction and exhaust
    -- the shared callback budget during multi-admit catch-up (#459).
    local acctMut = GS.GetAccountingMutationSeq and GS.GetAccountingMutationSeq(record) or 0
    return tostring(acctMut) .. ":" .. tostring(record and record.datasetId or "")
end

--- Shared soft-limit check for cold provenance construction under an outer
-- callback allowance. Uses globals so this early helper can pace before the
-- later CreditProjectionWorkNow locals are in scope (#459 G2).
local function CreditProvenanceSharedSoftExceeded()
    if not GS._creditProjectionAccumulating then
        return false
    end
    local soft = tonumber(GS._creditProjectionCallbackLimit)
        or (tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384)
    local base = tonumber(GS._creditProjectionCallbackWork) or 0
    local localNow = (tonumber(GS._creditProjectionProvenanceVisits) or 0)
        + (tonumber(GS._creditProjectionRowVisits) or 0)
        + (tonumber(GS._creditProjectionBucketVisits) or 0)
        + (tonumber(GS._creditProjectionFloorVisits) or 0)
        + (tonumber(GS._creditProjectionCandidateTrials) or 0)
        + (tonumber(GS._creditProjectionStructureCopyVisits) or 0)
        + (tonumber(GS._creditProjectionTraversalVisits) or 0)
    return (base + localNow) >= soft
end

--- Build a trusted ephemeral name↔GUID provenance index once per accounting
-- stamp. Distinct pairs are indexed once; each row visit is charged to the
-- shared callback counters. Under an outer allowance, construction is paced and
-- resumable so cold Bind/Admit cannot overrun soft+atomic; when no shared
-- budget is open the index still completes synchronously for ordinary reads
-- (#459 G2 / discussion_r4485438881).
-- @return map|nil, string|nil err ("work_budget" when paced incomplete)
local function EnsureCreditProvenanceIndex(record)
    if type(record) ~= "table" or type(record.accounting) ~= "table" then
        return nil, nil
    end
    local active = creditProvenanceIndexActive[record]
    if type(active) == "table" and active.complete and type(active.map) == "table" then
        return active.map, nil
    end
    local stamp = CreditProvenanceDependencyStamp(record)
    local cached = creditProvenanceIndexCache[record]
    if type(cached) == "table" and cached.stamp == stamp and cached.complete
        and type(cached.map) == "table" then
        return cached.map, nil
    end
    local map = {}
    local phase = "live"
    local index = 1
    if type(cached) == "table" and cached.stamp == stamp and cached.complete == false
        and type(cached.map) == "table" then
        map = cached.map
        phase = cached.phase == "archive" and "archive" or "live"
        index = math.max(1, tonumber(cached.index) or 1)
    end
    local lists = {
        live = { record.accounting._consumableEvents, MaxLiveLedgerScan() },
        archive = { record.accounting._consumableEventArchive, MaxArchivedLedgerScan() },
    }
    local function persistIncomplete(nextPhase, nextIndex)
        creditProvenanceIndexCache[record] = {
            stamp = stamp,
            map = map,
            complete = false,
            phase = nextPhase,
            index = nextIndex,
        }
    end
    local order = { "live", "archive" }
    local startLi = (phase == "archive") and 2 or 1
    for li = startLi, #order do
        local key = order[li]
        local list, maxLen = lists[key][1], lists[key][2]
        local startAt = (li == startLi) and index or 1
        if type(list) == "table" then
            local limit = math.min(#list, maxLen)
            for i = startAt, limit do
                if CreditProvenanceSharedSoftExceeded() then
                    persistIncomplete(key, i)
                    return nil, "work_budget"
                end
                GS._creditProjectionProvenanceVisits =
                    (tonumber(GS._creditProjectionProvenanceVisits) or 0) + 1
                NoteCreditProvenanceFromEvent(map, list[i])
            end
        end
    end
    creditProvenanceIndexCache[record] = {
        stamp = stamp,
        map = map,
        complete = true,
    }
    return map, nil
end

--- True when an already-accepted local ledger row links this durable name to GUID.
-- Authenticated history is provenance; a bare remote claim is not. Bounded scan.
-- Prefers a paced ephemeral index so distinct unresolved identities do not each
-- rescan the full live+archive history (#459 / discussion_r4484522633).
-- @return boolean established, string|nil err
local function LedgerEstablishesNameGuid(record, name, guid)
    name = NormName(name)
    guid = ValidGuid(guid)
    if not name or not guid or type(record) ~= "table" or type(record.accounting) ~= "table" then
        return false, nil
    end
    local pair = ProvenancePairKey(name, guid)
    local active = creditProvenanceIndexActive[record]
    if type(active) == "table" and type(active.map) == "table" and active.complete then
        GS._creditProjectionProvenanceVisits =
            (tonumber(GS._creditProjectionProvenanceVisits) or 0) + 1
        return active.map[pair] == true, nil
    end
    local map, ensureErr = EnsureCreditProvenanceIndex(record)
    if ensureErr == "work_budget" then
        return false, "work_budget"
    end
    if type(map) == "table" then
        GS._creditProjectionProvenanceVisits =
            (tonumber(GS._creditProjectionProvenanceVisits) or 0) + 1
        return map[pair] == true, nil
    end
    return false, nil
end

--- Bind a durable character name to an optional claimed GUID.
-- Trust rule:
--   1) Name uniquely resolves to claimed GUID → accept.
--   2) Name uniquely resolves to a different GUID → hard mismatch (or soft
--      replace with the name-bound GUID for donations).
--   3) Name does not uniquely resolve → accept claimed GUID only with
--      verifiable provenance: Guild Info currently displays that name for the
--      GUID, or an accepted local ledger row already links the same name↔GUID.
--   4) Otherwise discard the claimed GUID and keep the immutable name.
-- Membership alone never establishes name↔GUID binding. Incomplete
-- relationships drop claimed GUIDs rather than storing them.
-- @param opts optional { softMismatch = boolean }
-- @return string|nil name, string|nil guid, string|nil err
function GS.BindCharacterIdentity(record, characterName, claimedGuid, opts)
    opts = opts or {}
    local name = NormName(characterName)
    local guid = ValidGuid(claimedGuid)
    if not name then
        if guid then
            return nil, nil, "invalid_attribution"
        end
        return nil, nil, nil
    end
    if not guid then
        return name, GS.ResolveUniqueCharacterGuid(record, name, nil), nil
    end
    if not GS.WitnessRelationshipsReady(record) then
        return name, nil, nil
    end
    local resolved = GS.ResolveUniqueCharacterGuid(record, name, nil)
    if resolved then
        if resolved ~= guid then
            if opts.softMismatch then
                -- Donation credit is already witness/officer authenticated by name;
                -- keep the name-bound GUID and drop the conflicting claim.
                return name, resolved, nil
            end
            return nil, nil, "attribution_mismatch"
        end
        return name, guid, nil
    end
    -- Unresolved name: require verifiable name↔GUID provenance, not membership.
    if GuidCurrentNameMatches(record, guid, name) then
        return name, guid, nil
    end
    local established, estErr = LedgerEstablishesNameGuid(record, name, guid)
    if estErr == "work_budget" then
        return nil, nil, "work_budget"
    end
    if established then
        return name, guid, nil
    end
    -- Unverifiable claimed GUID: omit rather than redirect credit.
    return name, nil, nil
end

--- Canonical attributed identity for floor checks and durable storage.
-- @return string|nil name, string|nil guid, string|nil err
function GS.ResolveAttributedIdentity(record, attributedName, attributedGuid)
    return GS.BindCharacterIdentity(record, attributedName, attributedGuid, nil)
end

--- Donor identity for donation persistence. Mismatched claimed GUIDs are dropped
-- (donation credit itself is already witness/officer authenticated).
-- @return string|nil name, string|nil guid
function GS.ResolveDonorIdentity(record, donorName, claimedGuid)
    local name, guid = GS.BindCharacterIdentity(
        record, donorName, claimedGuid, { softMismatch = true })
    return name, guid
end

--- Resolve a ledger actor/attributed name (optional GUID) to the current
-- contributor display identity. Never guesses from ambiguous names.
-- Optional ctx from BeginContributorProjectionContext reuses readiness/mappings.
-- @return string displayName, table meta
function GS.ResolveDisplayContributor(record, actorName, actorGuid, ctx)
    local original = NormName(actorName)
    local meta = {
        original = original,
        guid = ValidGuid(actorGuid),
        status = "provisional",
        mainGuid = nil,
        provisional = true,
    }
    if not original and not meta.guid then
        return nil, meta
    end
    local cacheKey = (meta.guid or "") .. "\0" .. (original or "")
    if type(ctx) == "table" and ctx.byKey and ctx.byKey[cacheKey] then
        local hit = ctx.byKey[cacheKey]
        return hit[1], hit[2]
    end
    local function finish(display, outMeta)
        if type(ctx) == "table" and ctx.byKey then
            ctx.byKey[cacheKey] = { display, outMeta }
        end
        return display, outMeta
    end
    local GI = SF.GuildInfo
    if not GI then
        return finish(original, meta)
    end
    local ready
    if type(ctx) == "table" and ctx.readinessChecked ~= false and ctx.ready ~= nil then
        ready = ctx.ready and true or false
    else
        ready = GS.WitnessRelationshipsReady(record)
        if type(ctx) == "table" then
            ctx.readinessChecks = (ctx.readinessChecks or 0) + 1
            ctx.ready = ready
        end
    end
    if not ready then
        -- Provisional fallback: show the original donor without rewriting history.
        return finish(original, meta)
    end
    local guid = meta.guid
    if not guid and original then
        if type(ctx) == "table" then
            local resolved, err = ContextResolveGuidByName(ctx, original)
            if type(resolved) == "string" then
                guid = resolved
                meta.guid = guid
            elseif err == "ambiguous_name" then
                meta.status = "ambiguous"
                return finish(original, meta)
            end
        elseif type(GI.ResolveCharacterGuidByName) == "function" then
            local resolved, err = GI:ResolveCharacterGuidByName(original, GuildKeyForRecord(record))
            if type(resolved) == "string" then
                guid = resolved
                meta.guid = guid
            elseif err == "ambiguous_name" then
                meta.status = "ambiguous"
                return finish(original, meta)
            end
        end
    end
    if not guid then
        return finish(original, meta)
    end
    local info
    if type(ctx) == "table" then
        info = ContextResolveIdentity(ctx, guid)
    elseif type(GI.ResolveContributorIdentity) == "function" then
        info = GI:ResolveContributorIdentity(guid, GuildKeyForRecord(record))
        if type(info) == "table" and info.status == "unknown" then
            info = nil
        end
    end
    if type(info) ~= "table" then
        return finish(original, meta)
    end
    meta.status = info.status
    meta.mainGuid = info.mainGuid
    meta.provisional = false
    local display = NormName(info.displayName) or original
    if info.status == "unassigned" then
        display = original or display
    elseif type(display) ~= "string" or display == "" then
        display = original
    end
    return finish(display, meta)
end

--- Personal (non-projected) item total for one durable identity.
-- Used for attributed negative-adjustment floors so linked balances cannot be
-- spent against another character and then go negative after unassign/move.
-- GUID-first when present; exact normalized name fallback for legacy rows.
--- Personal credited total for one actor/item (#459).
-- When credit projection reconstruction is failed/blocked, returns
-- nil, GS.CREDIT_UNAVAILABLE — not the ordinary number 0 (which means a
-- legitimate empty balance) and not durable-only identities.
function GS.PersonalContributorItemTotal(record, actorName, actorGuid, itemId, campaignId)
    itemId = tonumber(itemId)
    if type(record) ~= "table" or not IsItemId(itemId) then
        return 0
    end
    campaignId = campaignId or record.currentCampaignId
    if type(campaignId) ~= "string" or campaignId == "" then
        return 0
    end
    local identityName = NormName(actorName)
    local identityGuid = ValidGuid(actorGuid)
    if not identityName and not identityGuid then
        return 0
    end
    if GS.EnsureCreditCorrectionProjection then
        local ok = GS.EnsureCreditCorrectionProjection(record, nil)
        if ok == false then
            return nil, GS.CREDIT_UNAVAILABLE
        end
    end
    local generation = nil
    if record.currentCampaignId == campaignId then
        local cfg = record.accounting and record.accounting._consumables
        generation = cfg and tonumber(cfg.generation)
    end
    if not generation then
        local archive = record.campaignArchives and record.campaignArchives[campaignId]
        generation = archive and tonumber(archive.generation)
    end
    if not generation or generation < 1 then
        return 0
    end
    local function sideMatches(sideName, sideGuid)
        local g = ValidGuid(sideGuid)
        if identityGuid and g then
            return g == identityGuid
        end
        local side = NormName(sideName)
        if identityGuid and not g then
            if side and identityName and side == identityName then
                return true
            end
            -- Legacy name-only rows: match when the durable name uniquely
            -- resolves to this GUID (identity established without a stored GUID).
            if side then
                local resolved = GS.ResolveUniqueCharacterGuid(record, side, nil)
                if resolved and resolved == identityGuid then
                    return true
                end
            end
            return false
        end
        return side ~= nil and identityName ~= nil and side == identityName
    end
    local total = 0
    local function consider(event)
        if type(event) ~= "table" then
            return
        end
        if tonumber(event.generation) ~= generation then
            return
        end
        if GS.EventCountsTowardLiveProgress
            and not GS.EventCountsTowardLiveProgress(record, event) then
            return
        end
        if tonumber(event.itemId) ~= itemId then
            return
        end
        local qty = tonumber(event.quantity) or 0
        if qty == 0 then
            return
        end
        local typ = event.type
        local isDonation = typ == GS.LEDGER_EVENT.DONATION or typ == "CONSUMABLE_DONATION"
        local isAdjustment = typ == GS.LEDGER_EVENT.ADJUSTMENT or typ == "CONSUMABLE_ADJUSTMENT"
        if not isDonation and not isAdjustment then
            return
        end
        -- #459: personal floors follow effective credited identity, not durable
        -- donor/attributed fields alone. Projection already ensured available.
        local creditName, creditGuid, _, status
        if GS.ResolveEffectiveCreditIdentity then
            creditName, creditGuid, _, status = GS.ResolveEffectiveCreditIdentity(record, event)
            if status == GS.CREDIT_UNAVAILABLE then
                return "unavailable"
            end
        elseif isDonation then
            creditName, creditGuid = event.actor, event.actorGuid or event.donorGuid
        else
            creditName, creditGuid = event.attributed, event.attributedGuid
        end
        if isDonation then
            if qty > 0 and sideMatches(creditName, creditGuid) then
                total = total + qty
            end
        elseif creditName or creditGuid then
            if sideMatches(creditName, creditGuid) then
                total = total + qty
            end
        end
    end
    local live = record.accounting and record.accounting._consumableEvents
    local archived = record.accounting and record.accounting._consumableEventArchive
    if type(live) == "table" then
        for i = 1, #live do
            if consider(live[i]) == "unavailable" then
                return nil, GS.CREDIT_UNAVAILABLE
            end
        end
    end
    if type(archived) == "table" then
        for i = 1, #archived do
            if consider(archived[i]) == "unavailable" then
                return nil, GS.CREDIT_UNAVAILABLE
            end
        end
    end
    return total
end

local function CountLinkGroups(links)
    local n = 0
    if type(links) ~= "table" or type(links.groups) ~= "table" then
        return 0
    end
    for _ in pairs(links.groups) do
        n = n + 1
    end
    return n
end

local function RebuildByGuid(links)
    links.byGuid = {}
    for gid, group in pairs(links.groups) do
        if type(group) == "table" and type(group.guids) == "table" then
            for i = 1, #group.guids do
                local g = ValidGuid(group.guids[i])
                if g then
                    links.byGuid[g] = gid
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Pending evidence clusters (automatic three-witness; no manual review)
---------------------------------------------------------------------------

--- Current/archived campaign only — never allocate durable buckets for spoofed ids.
local function IsValidPendingCampaign(record, campaignId)
    if type(record) ~= "table" or type(campaignId) ~= "string" or campaignId == "" then
        return false, "invalid_campaign"
    end
    if record.currentCampaignId == campaignId then
        return true
    end
    local header = record.campaigns and record.campaigns[campaignId]
    if type(header) ~= "table" then
        return false, "unknown_campaign"
    end
    local archive = record.campaignArchives and record.campaignArchives[campaignId]
    if type(archive) == "table" then
        if GS.ValidateCampaignArchive then
            local ok = GS.ValidateCampaignArchive(archive, campaignId, record)
            if not ok then
                return false, "invalid_campaign_archive"
            end
        end
        return true
    end
    -- Non-current without archive: retain only when the boundary allows missing
    -- archives (legacy/other); otherwise fail closed.
    if header.boundaryKind == "new-goal" then
        return false, "missing_campaign_archive"
    end
    return true
end

local function CountTotalUnfinishedPending(record)
    local total = 0
    local byCampaign = record and record.observations and record.observations.byCampaign
    if type(byCampaign) ~= "table" then
        return 0
    end
    local cap = (GS.MAX_PENDING_EVIDENCE_TOTAL or 256) + 1
    for _, camp in pairs(byCampaign) do
        if type(camp) == "table" and type(camp.pending) == "table" then
            for i = 1, #camp.pending do
                local cluster = camp.pending[i]
                if type(cluster) == "table" and cluster.status ~= "verified" then
                    total = total + 1
                    if total >= cap then
                        return total
                    end
                end
            end
        end
    end
    return total
end

local function EnsureCampaignPending(record, campaignId)
    local ok, err = IsValidPendingCampaign(record, campaignId)
    if not ok then
        return nil, err or "invalid_campaign"
    end
    if type(record.observations) ~= "table" then
        record.observations = { byCampaign = {} }
    end
    if type(record.observations.byCampaign) ~= "table" then
        record.observations.byCampaign = {}
    end
    local camp = record.observations.byCampaign[campaignId]
    if type(camp) ~= "table" then
        camp = { schemaVersion = 1, seq = 0, scopes = {}, pending = {} }
        record.observations.byCampaign[campaignId] = camp
    end
    if type(camp.pending) ~= "table" then
        camp.pending = {}
    end
    return camp
end

local function LocalPlayerGuid()
    if UnitGUID then
        local guid = UnitGUID("player")
        if type(guid) == "string" and guid ~= "" then
            return guid
        end
    end
    return nil
end

--- Fail closed before ledger mutation when the staged record shape is unusable.
local function RequireUsableAccountingRecord(record)
    if type(record) ~= "table" then
        return false, "invalid_record"
    end
    if type(record.datasetId) ~= "string" or record.datasetId == "" then
        return false, "invalid_dataset"
    end
    if type(record.accounting) ~= "table" then
        return false, "invalid_accounting"
    end
    if type(record.accounting._consumables) ~= "table" then
        return false, "invalid_accounting"
    end
    if record.accounting._consumableEvents ~= nil
        and type(record.accounting._consumableEvents) ~= "table" then
        return false, "invalid_accounting"
    end
    return true
end

--- Verified clusters no longer consume pending capacity; reclaim after commit.
local function CompactVerifiedPending(pending)
    if type(pending) ~= "table" then
        return 0
    end
    local write = 1
    for read = 1, #pending do
        local cluster = pending[read]
        if type(cluster) == "table" and cluster.status ~= "verified" then
            pending[write] = cluster
            write = write + 1
        end
    end
    for i = write, #pending do
        pending[i] = nil
    end
    return write - 1
end

local function UnfinishedPendingCount(pending)
    if type(pending) ~= "table" then
        return 0
    end
    local n = 0
    for i = 1, #pending do
        local cluster = pending[i]
        if type(cluster) == "table" and cluster.status ~= "verified" then
            n = n + 1
        end
    end
    return n
end

--- Drop unfinished pending clusters whose lastSeen exceeds the TTL.
-- Event-driven reclaim only (no polling). Never touches verified ledger rows.
local function ReclaimStaleUnfinishedPending(pending, now)
    if type(pending) ~= "table" then
        return 0
    end
    local ttl = tonumber(GS.PENDING_EVIDENCE_TTL_SECONDS) or (14 * 24 * 60 * 60)
    now = tonumber(now) or Now()
    local write = 1
    local removed = 0
    for read = 1, #pending do
        local cluster = pending[read]
        local keep = true
        if type(cluster) == "table" and cluster.status ~= "verified" then
            local lastSeen = tonumber(cluster.lastSeen) or tonumber(cluster.firstSeen) or 0
            if lastSeen > 0 and (now - lastSeen) > ttl then
                keep = false
                removed = removed + 1
            end
        end
        if keep then
            pending[write] = cluster
            write = write + 1
        end
    end
    for i = write, #pending do
        pending[i] = nil
    end
    return removed
end

local function CountWitnessUnfinishedClusters(pending, witnessGuid)
    if type(pending) ~= "table" or type(witnessGuid) ~= "string" or witnessGuid == "" then
        return 0
    end
    local n = 0
    for i = 1, #pending do
        local cluster = pending[i]
        if type(cluster) == "table" and cluster.status ~= "verified"
            and type(cluster.witnesses) == "table"
            and cluster.witnesses[witnessGuid] ~= nil then
            n = n + 1
        end
    end
    return n
end

--- Whether a new unfinished cluster may be opened for this witness.
-- Local bank observations keep reserved headroom; remote live gossip evidence is
-- capped per witness and cannot consume the reserved local slots. Authenticated
-- adoption replay uses the full campaign/total caps (source-authoritative transfer).
local function CanOpenNewPendingCluster(record, pending, witnessGuid, admissionCtx)
    local perCap = tonumber(GS.MAX_PENDING_EVIDENCE) or 128
    local totalCap = tonumber(GS.MAX_PENDING_EVIDENCE_TOTAL) or 256
    local reserved = tonumber(GS.RESERVED_LOCAL_PENDING_EVIDENCE) or 16
    local perWitness = tonumber(GS.MAX_PENDING_EVIDENCE_PER_WITNESS) or 32
    local unfinished = UnfinishedPendingCount(pending)
    local totalUnfinished = CountTotalUnfinishedPending(record)
    local isLocal = admissionCtx and (admissionCtx.localWrite or admissionCtx.exportEvidence)
    local isAdoption = admissionCtx and admissionCtx.adoptionReplay
    if not isLocal and not isAdoption then
        local remotePerCap = perCap - reserved
        if remotePerCap < 1 then
            remotePerCap = 1
        end
        local remoteTotalCap = totalCap - reserved
        if remoteTotalCap < 1 then
            remoteTotalCap = 1
        end
        if unfinished >= remotePerCap or totalUnfinished >= remoteTotalCap then
            return false, "full"
        end
        if CountWitnessUnfinishedClusters(pending, witnessGuid) >= perWitness then
            return false, "witness_quota"
        end
        return true
    end
    if unfinished >= perCap or totalUnfinished >= totalCap then
        return false, "full"
    end
    return true
end

local function EvidenceView(row)
    if type(row) ~= "table" then return nil end
    return {
        coreSignature = row.coreSignature,
        type = row.type or "deposit",
        donor = row.donor,
        itemId = row.itemId,
        quantity = row.quantity,
        guildGuid = row.guildGuid,
        bankTab = row.bankTab,
        generation = row.generation,
        approxTxnTime = row.approxTxnTime,
        ageHours = row.ageHours,
        occurrenceIndex = row.occurrenceIndex,
        neighborsOlder = row.neighborsOlder,
        neighborsNewer = row.neighborsNewer,
        firstSeen = row.firstSeen,
        lastSeen = row.lastSeen,
        status = row.status or "pending",
    }
end

local function MatchScore(existing, evidence)
    if not O or not O.MatchScore then
        return nil
    end
    return O.MatchScore(EvidenceView(existing), evidence)
end

--- Occurrence match for adoption/completeness (not coreSignature alone).
function GS.EvidenceOccurrenceMatches(existing, evidence)
    if type(existing) ~= "table" or type(evidence) ~= "table" then
        return false
    end
    local view = type(existing.evidence) == "table" and existing.evidence or existing
    local score = MatchScore(view, evidence)
    if score and score >= ((O and O.MIN_MATCH_SCORE) or 100) then
        return true
    end
    return false
end

local function AmbiguousBest(pendingList, evidence)
    local best, bestScore, second = nil, nil, nil
    local margin = (O and O.AMBIGUITY_MARGIN) or 15
    local minScore = (O and O.MIN_MATCH_SCORE) or 100
    for i = 1, #pendingList do
        local row = pendingList[i]
        if type(row) == "table" and (row.status == nil or row.status == "pending" or row.status == "ambiguous") then
            -- Clusters store payload under .evidence; bare evidence rows match directly.
            local view = type(row.evidence) == "table" and row.evidence or row
            local score = MatchScore(view, evidence)
            if score and score >= minScore then
                if not bestScore or score > bestScore then
                    second = bestScore
                    best, bestScore = row, score
                elseif not second or score > second then
                    second = score
                end
            end
        end
    end
    if best and second and (bestScore - second) < margin then
        return nil, "ambiguous", bestScore
    end
    if best then
        return best, "match", bestScore
    end
    return nil, "none", nil
end

function GS.SerializeEvidence(evidence)
    if type(evidence) ~= "table" then return nil end
    local donor = NormName(evidence.donor)
    local itemId = tonumber(evidence.itemId)
    local quantity = FloorNonNeg(evidence.quantity)
    if not donor or not IsItemId(itemId) or quantity < 1 then return nil end
    local guildGuid = type(evidence.guildGuid) == "string" and evidence.guildGuid or nil
    local bankTab = tonumber(evidence.bankTab)
    if not guildGuid or not bankTab or bankTab < 1 or bankTab > 8 then return nil end
    -- Always recompute from normalized credited fields. A nonempty claimed
    -- signature that disagrees is rejected (never silently rewritten), so one
    -- forged witness cannot inflate quantity while matching honest votes.
    local core = nil
    if O and O.CoreSignature then
        core = O.CoreSignature("deposit", donor, itemId, quantity)
    end
    if type(core) ~= "string" or core == "" then return nil end
    local claimed = evidence.coreSignature
    if type(claimed) == "string" and claimed ~= "" and claimed ~= core then
        return nil
    end
    return {
        coreSignature = core,
        type = "deposit",
        donor = donor,
        itemId = itemId,
        quantity = quantity,
        guildGuid = guildGuid,
        bankTab = bankTab,
        generation = tonumber(evidence.generation) or 0,
        approxTxnTime = tonumber(evidence.approxTxnTime),
        ageHours = tonumber(evidence.ageHours),
        occurrenceIndex = tonumber(evidence.occurrenceIndex) or 1,
        neighborsOlder = CopyStringList(evidence.neighborsOlder, (O and O.MAX_NEIGHBORS) or 3),
        neighborsNewer = CopyStringList(evidence.neighborsNewer, (O and O.MAX_NEIGHBORS) or 3),
        observedAt = tonumber(evidence.observedAt) or Now(),
        campaignId = type(evidence.campaignId) == "string" and evidence.campaignId or nil,
    }
end

function GS.ValidateEvidencePayload(evidence)
    local row = GS.SerializeEvidence(evidence)
    if not row then return false, "invalid_evidence" end
    if row.quantity > (GS.MAX_OBS_QUANTITY or 100000) then
        return false, "invalid_quantity"
    end
    if not tonumber(row.approxTxnTime) then
        return false, "invalid_evidence"
    end
    return true, nil, row
end

local function EnsureTxnRegistry(cfg)
    if type(cfg.txnRegistry) ~= "table" then
        cfg.txnRegistry = {}
    end
    return cfg.txnRegistry
end

local function FindRegistryByTxnExact(cfg, txnId)
    txnId = ValidTxnId(txnId)
    if not txnId then return nil end
    local list = EnsureTxnRegistry(cfg)
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" and row.txnId == txnId then
            return row, i
        end
    end
    return nil
end

local function FindRegistryByTxn(cfg, txnId)
    txnId = ValidTxnId(txnId)
    if not txnId then return nil end
    local list = EnsureTxnRegistry(cfg)
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" then
            if row.txnId == txnId then
                return row, i
            end
            if type(row.aliases) == "table" then
                for j = 1, #row.aliases do
                    if row.aliases[j] == txnId then
                        return row, i
                    end
                end
            end
        end
    end
    return nil
end

local function RegistryMatchOccurrence(cfg, evidence)
    local list = EnsureTxnRegistry(cfg)
    local best, bestScore, second = nil, nil, nil
    local margin = (O and O.AMBIGUITY_MARGIN) or 15
    local minScore = (O and O.MIN_MATCH_SCORE) or 100
    local scan = math.min(#list, GS.MAX_TXN_REGISTRY or 512)
    for i = 1, scan do
        local row = list[i]
        if type(row) == "table" and row.status == "verified" then
            local score = MatchScore(row, evidence)
            if score and score >= minScore then
                if not bestScore or score > bestScore then
                    second = bestScore
                    best, bestScore = row, score
                elseif not second or score > second then
                    second = score
                end
            end
        end
    end
    if best and second and (bestScore - second) < margin then
        return nil, "ambiguous"
    end
    if best then
        return best, "match"
    end
    return nil, "none"
end

local function FindLedgerDonationOccurrence(record, evidence)
    local lists = {
        record.accounting and record.accounting._consumableEvents,
        record.accounting and record.accounting._consumableEventArchive,
    }
    local best, bestScore, second = nil, nil, nil
    local margin = (O and O.AMBIGUITY_MARGIN) or 15
    local minScore = (O and O.MIN_MATCH_SCORE) or 100
    for li = 1, #lists do
        local list = lists[li]
        if type(list) == "table" then
            local maxScan = (li == 1) and MaxLiveLedgerScan() or MaxArchivedLedgerScan()
            local limit = math.min(#list, maxScan)
            for i = 1, limit do
                local event = list[i]
                if type(event) == "table"
                    and (event.type == GS.LEDGER_EVENT.DONATION or event.type == "CONSUMABLE_DONATION")
                    and event.source == "guildbank"
                then
                    local score = MatchScore({
                        coreSignature = event.coreSignature,
                        guildGuid = event.guildGuid,
                        bankTab = event.bankTab,
                        generation = event.generation,
                        approxTxnTime = event.timestamp or event.approxTxnTime,
                        occurrenceIndex = event.occurrenceIndex,
                        neighborsOlder = event.neighborsOlder,
                        neighborsNewer = event.neighborsNewer,
                        status = "verified",
                    }, evidence)
                    if score and score >= minScore then
                        if not bestScore or score > bestScore then
                            second = bestScore
                            best, bestScore = event, score
                        elseif not second or score > second then
                            second = score
                        end
                    end
                end
            end
        end
    end
    if best and second and (bestScore - second) < margin then
        return nil, "ambiguous"
    end
    if best then
        return best, "match"
    end
    return nil, "none"
end

--- Stable occurrence fingerprint so independent verifiers mint the same txnId
-- when matching fields agree. Hour buckets are intentionally omitted: observers
-- of the same still-visible deposit can reconstruct different approxTxnTime
-- hours as ageHours advances. MatchScore (3h tolerance) remains the occurrence
-- matcher; neighbors + occurrenceIndex keep legitimately repeated deposits
-- distinct when context differs. Exact-ID collisions that MatchScore rejects
-- (temporally separated identical empty-context deposits) are reminted or held
-- ambiguous in CommitVerifiedCluster — never silently merged as duplicates.
-- Residual neighbor/index disagreements still converge via MatchScore aliasing.
function GS.OccurrenceFingerprint(evidence)
    if type(evidence) ~= "table" then
        return nil
    end
    if type(evidence.coreSignature) ~= "string" or evidence.coreSignature == "" then
        return nil
    end
    local older = CopyStringList(evidence.neighborsOlder, 3)
    local newer = CopyStringList(evidence.neighborsNewer, 3)
    table.sort(older)
    table.sort(newer)
    local body = {
        kind = "gs-occ-v2",
        core = evidence.coreSignature,
        guild = tostring(evidence.guildGuid or ""),
        tab = tonumber(evidence.bankTab) or 0,
        gen = tonumber(evidence.generation) or 0,
        occ = tonumber(evidence.occurrenceIndex) or 1,
        older = older,
        newer = newer,
    }
    local fp = nil
    if GS.ContentFingerprint then
        fp = GS.ContentFingerprint(body)
    end
    if type(fp) ~= "string" or fp == "" then
        -- Fail closed to seq mint when Hash32 is unavailable.
        return nil
    end
    if #fp > 120 then
        fp = fp:sub(1, 120)
    end
    return fp
end

function GS.AllocateCanonicalTxnId(record, writerGuid, evidence)
    local occ = evidence and GS.OccurrenceFingerprint(evidence)
    if occ then
        local txnId = "ctx:gs:" .. occ
        if ValidTxnId(txnId) then
            return txnId
        end
    end
    local cfg = record and record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" then return nil end
    cfg.txnAllocSeq = (tonumber(cfg.txnAllocSeq) or 0) + 1
    local dataset = tostring(record.datasetId or "gs")
    if #dataset > 40 then dataset = dataset:sub(1, 40) end
    local w = ValidGuid(writerGuid) or "local"
    if #w > 32 then w = w:sub(1, 32) end
    local entropy = Now() + cfg.txnAllocSeq * 17
    local txnId = string.format("ctx:%s:%s:%d:%x", dataset, w, cfg.txnAllocSeq, entropy)
    return ValidTxnId(txnId)
end

local function DonationBodiesConflict(existing, incoming)
    if type(existing) ~= "table" or type(incoming) ~= "table" then
        return true
    end
    -- Compare occurrence identity fields only. Writer/verification/source/timestamps
    -- may differ across independent verifiers of the same deposit and must not
    -- quarantine a matching body during ledger catch-up.
    local fields = {
        "coreSignature", "itemId", "quantity", "generation", "guildGuid", "bankTab",
        "occurrenceIndex", "actor", "donor",
    }
    for i = 1, #fields do
        local f = fields[i]
        local a, b = existing[f], incoming[f]
        if f == "actor" or f == "donor" then
            a = NormName(existing.actor or existing.donor)
            b = NormName(incoming.actor or incoming.donor)
        elseif f == "itemId" or f == "quantity" or f == "generation" or f == "bankTab"
            or f == "occurrenceIndex" then
            a, b = tonumber(a), tonumber(b)
        else
            a, b = tostring(a or ""), tostring(b or "")
        end
        if a ~= b then
            return true
        end
    end
    return false
end

--- Immutable adjustment payload equivalence (ledger event or staged op shape).
-- Same operation id with divergent item/quantity/attribution/campaign/generation/
-- actor is a conflicting body, not a harmless duplicate.
local function AdjustmentBodiesEquivalent(existing, incoming)
    if type(existing) ~= "table" or type(incoming) ~= "table" then
        return false
    end
    local inItem = tonumber(incoming.itemId)
        or tonumber(incoming.value and incoming.value.itemId)
        or tonumber(incoming.target and incoming.target.itemId)
    local inQty = tonumber(incoming.quantity)
        or tonumber(incoming.value and incoming.value.quantity)
    local inAttr = NormName(incoming.attributed
        or (incoming.value and incoming.value.attributed))
    local inCamp = incoming.campaignId
    local inGen = tonumber(incoming.generation)
    local inActor = NormName(incoming.actor or incoming.actorName)
    local exItem = tonumber(existing.itemId)
    local exQty = tonumber(existing.quantity)
    local exAttr = NormName(existing.attributed)
    local exCamp = existing.campaignId
    local exGen = tonumber(existing.generation)
    local exActor = NormName(existing.actor)
    if exItem ~= inItem or exQty ~= inQty then
        return false
    end
    if (exAttr or nil) ~= (inAttr or nil) then
        return false
    end
    if inCamp ~= nil and exCamp ~= nil and exCamp ~= inCamp then
        return false
    end
    if inGen ~= nil and exGen ~= nil and exGen ~= inGen then
        return false
    end
    if inActor ~= nil and exActor ~= nil and exActor ~= inActor then
        return false
    end
    return true
end

--- Seq-based txn id used when a fingerprint collides with a distinct occurrence.
local function AllocateCollisionRemintTxnId(record, writerGuid)
    local cfgAlloc = record and record.accounting and record.accounting._consumables
    if type(cfgAlloc) ~= "table" then
        return nil
    end
    cfgAlloc.txnAllocSeq = (tonumber(cfgAlloc.txnAllocSeq) or 0) + 1
    local dataset = tostring(record.datasetId or "gs")
    if #dataset > 40 then dataset = dataset:sub(1, 40) end
    local w = ValidGuid(writerGuid) or "local"
    if #w > 32 then w = w:sub(1, 32) end
    local entropy = Now() + cfgAlloc.txnAllocSeq * 17
    local reminted = string.format(
        "ctx:%s:%s:%d:%x", dataset, w, cfgAlloc.txnAllocSeq, entropy)
    return ValidTxnId(reminted)
end

--- MatchScore agreement for an exact-ID registry/candidate hit.
-- Returns "same", "distinct", or "uncertain".
local function ExactIdOccurrenceRelation(existing, evidence)
    if type(existing) ~= "table" or type(evidence) ~= "table" then
        return "uncertain"
    end
    local score = MatchScore(existing, evidence)
    local minScore = (O and O.MIN_MATCH_SCORE) or 100
    if score and score >= minScore then
        return "same"
    end
    local tExisting = tonumber(existing.approxTxnTime or existing.timestamp)
    local tEvidence = tonumber(evidence.approxTxnTime or evidence.timestamp)
    local tol = (O and O.TIME_TOLERANCE_SECONDS) or (3 * 60 * 60)
    if tExisting and tEvidence and math.abs(tExisting - tEvidence) > tol then
        return "distinct"
    end
    return "uncertain"
end

local function EnsureDirectEvidenceExports(record)
    if type(record.observations) ~= "table" then
        record.observations = { byCampaign = {} }
    end
    if type(record.observations.directExports) ~= "table" then
        record.observations.directExports = {}
    end
    return record.observations.directExports
end

local function EnsurePendingDonationCandidates(record)
    if type(record.accounting) ~= "table" then
        return nil
    end
    if type(record.accounting._pendingDonationCandidates) ~= "table" then
        record.accounting._pendingDonationCandidates = {}
    end
    return record.accounting._pendingDonationCandidates
end

local function EnsureTxnConflicts(cfg)
    if type(cfg.txnConflicts) ~= "table" then
        cfg.txnConflicts = {}
    end
    return cfg.txnConflicts
end

local function CountTxnConflictKeys(conflicts)
    local n = 0
    if type(conflicts) ~= "table" then
        return 0
    end
    local cap = (GS.MAX_TXN_CONFLICT_KEYS or 64) + 1
    for _ in pairs(conflicts) do
        n = n + 1
        if n >= cap then
            return n
        end
    end
    return n
end

local function BoundScalarString(value, maxLen)
    if type(value) ~= "string" then
        return nil
    end
    maxLen = tonumber(maxLen) or 64
    if value == "" then
        return nil
    end
    if #value > maxLen then
        return value:sub(1, maxLen)
    end
    return value
end

--- Bounded diagnostic quarantine body (never persist raw peer tables).
-- Only finite scalars / length-capped strings; nested tables are dropped.
local function CanonicalConflictSnapshot(body)
    if type(body) ~= "table" then
        return nil
    end
    local typ = body.type
    if typ ~= nil and type(typ) ~= "string" then
        typ = nil
    elseif type(typ) == "string" and #typ > 32 then
        typ = typ:sub(1, 32)
    end
    local itemId = tonumber(body.itemId)
    if itemId and (itemId ~= itemId or itemId == math.huge or itemId ~= math.floor(itemId)) then
        itemId = nil
    end
    local quantity = tonumber(body.quantity)
    if quantity and (quantity ~= quantity or quantity == math.huge or quantity ~= math.floor(quantity)) then
        quantity = nil
    end
    local generation = tonumber(body.generation)
    if generation and (generation ~= generation or generation == math.huge
        or generation ~= math.floor(generation) or generation < 0) then
        generation = nil
    end
    local timestamp = tonumber(body.timestamp) or tonumber(body.approxTxnTime)
    if timestamp and (timestamp ~= timestamp or timestamp == math.huge
        or timestamp ~= math.floor(timestamp) or timestamp < 0) then
        timestamp = nil
    end
    return {
        type = typ,
        id = BoundScalarString(body.id, GS.MAX_OPERATION_ID or 192),
        txnId = BoundScalarString(body.txnId, GS.MAX_TXN_ID or 160),
        opId = BoundScalarString(body.opId, GS.MAX_OPERATION_ID or 192),
        itemId = itemId,
        quantity = quantity,
        attributed = BoundScalarString(body.attributed, 96),
        actor = BoundScalarString(body.actor or body.donor, 96),
        writer = BoundScalarString(body.writer, 64),
        campaignId = BoundScalarString(body.campaignId, 96),
        generation = generation,
        coreSignature = BoundScalarString(body.coreSignature, 160),
        timestamp = timestamp,
    }
end

local function QuarantineConflictBody(cfg, qid, body)
    if type(qid) ~= "string" or qid == "" or type(cfg) ~= "table" then
        return false
    end
    local snap = CanonicalConflictSnapshot(body)
    if not snap then
        return false
    end
    local conflicts = EnsureTxnConflicts(cfg)
    local entry = conflicts[qid]
    if type(entry) ~= "table" then
        if CountTxnConflictKeys(conflicts) >= (GS.MAX_TXN_CONFLICT_KEYS or 64) then
            return false
        end
        entry = { bodies = {} }
        conflicts[qid] = entry
    end
    if type(entry.bodies) ~= "table" then
        entry.bodies = {}
    end
    local maxBodies = GS.MAX_TXN_CONFLICT_BODIES or 8
    if #entry.bodies >= maxBodies then
        return false
    end
    entry.bodies[#entry.bodies + 1] = snap
    return true
end

local function CountDirectExports(exports)
    local n = 0
    if type(exports) ~= "table" then
        return 0
    end
    local cap = (GS.MAX_DIRECT_EVIDENCE_EXPORTS or 256) + 1
    for _ in pairs(exports) do
        n = n + 1
        if n >= cap then
            return n
        end
    end
    return n
end

--- Evict oldest exports that are not still referenced by unfinished pending.
-- @return removedIds dense list of evicted export ids (for Gossip index sync)
local function EvictDirectEvidenceExports(record, exports, needSlots)
    needSlots = tonumber(needSlots) or 1
    local removedIds = {}
    if needSlots < 1 then
        return removedIds
    end
    local pendingFingerprints = {}
    local byCampaign = record.observations and record.observations.byCampaign
    if type(byCampaign) == "table" then
        for _, camp in pairs(byCampaign) do
            if type(camp) == "table" and type(camp.pending) == "table" then
                for i = 1, #camp.pending do
                    local cluster = camp.pending[i]
                    if type(cluster) == "table" and cluster.status ~= "verified"
                        and type(cluster.evidence) == "table" then
                        local fp = GS.OccurrenceFingerprint(cluster.evidence)
                        if type(fp) == "string" then
                            pendingFingerprints[fp] = true
                        end
                    end
                end
            end
        end
    end
    local ranked = {}
    for exportId, row in pairs(exports) do
        if type(row) == "table" then
            local fp = row.evidence and GS.OccurrenceFingerprint(row.evidence)
            local required = type(fp) == "string" and pendingFingerprints[fp]
            ranked[#ranked + 1] = {
                id = exportId,
                at = tonumber(row.at) or 0,
                required = required and true or false,
            }
        end
    end
    table.sort(ranked, function(a, b)
        if a.required ~= b.required then
            return not a.required and b.required
        end
        if a.at ~= b.at then
            return a.at < b.at
        end
        return tostring(a.id) < tostring(b.id)
    end)
    for i = 1, #ranked do
        if #removedIds >= needSlots then
            break
        end
        if not ranked[i].required then
            exports[ranked[i].id] = nil
            removedIds[#removedIds + 1] = ranked[i].id
        end
    end
    return removedIds
end

--- Record a direct local observation for gossip export (never re-export relays).
function GS.RecordDirectEvidenceExport(record, witnessGuid, evidence)
    witnessGuid = ValidGuid(witnessGuid)
    local row = GS.SerializeEvidence(evidence)
    if not witnessGuid or not row then
        return nil
    end
    local exports = EnsureDirectEvidenceExports(record)
    local occ = GS.OccurrenceFingerprint(row) or tostring(row.coreSignature)
    -- Coarse time bucket (MatchScore TIME_TOLERANCE) keeps temporally separated
    -- identical deposits from overwriting each other under the same fingerprint,
    -- while still-visible deposits within tolerance share an export identity.
    local tol = (O and O.TIME_TOLERANCE_SECONDS) or (3 * 60 * 60)
    local bucket = math.floor((tonumber(row.approxTxnTime) or 0) / tol)
    local exportId = "gs:ev:" .. witnessGuid .. ":" .. occ .. ":t" .. tostring(bucket)
    if #exportId > 190 then
        exportId = exportId:sub(1, 190)
    end
    if exports[exportId] == nil then
        local count = CountDirectExports(exports)
        local maxExports = GS.MAX_DIRECT_EVIDENCE_EXPORTS or 256
        if count >= maxExports then
            local removedIds = EvictDirectEvidenceExports(
                record, exports, (count - maxExports) + 1)
            if type(removedIds) == "table" and #removedIds > 0
                and GS.RemoveGossipExportBodies then
                GS.RemoveGossipExportBodies(removedIds)
            end
            if CountDirectExports(exports) >= maxExports then
                -- Still full of required quorum/recovery evidence: refuse growth.
                return nil
            end
        end
    end
    exports[exportId] = {
        witnessGuid = witnessGuid,
        evidence = row,
        campaignId = row.campaignId,
        datasetId = record.datasetId,
        at = Now(),
    }
    return exportId
end

--- List direct exports; when witnessGuid is set, only that character's rows.
function GS.ListDirectEvidenceExports(record, witnessGuid)
    if type(record) ~= "table" or type(record.observations) ~= "table" then
        return {}
    end
    local exports = record.observations.directExports or {}
    witnessGuid = ValidGuid(witnessGuid)
    if not witnessGuid then
        return exports
    end
    local filtered = {}
    for exportId, row in pairs(exports) do
        if type(row) == "table" and row.witnessGuid == witnessGuid then
            filtered[exportId] = row
        end
    end
    return filtered
end

function GS.GetLocalPlayerGuid()
    return LocalPlayerGuid()
end

local function RegisterTxn(cfg, entry)
    if type(entry) ~= "table" or not ValidTxnId(entry.txnId) then
        return false
    end
    local list = EnsureTxnRegistry(cfg)
    -- Exact txnId only: alias-aware lookup would find the primary row after
    -- aliases[] was updated and overwrite it when registering the alias entry.
    local existing = FindRegistryByTxnExact(cfg, entry.txnId)
    if existing then
        if existing.committed then entry.committed = true end
        for k, v in pairs(entry) do
            existing[k] = v
        end
        return true
    end
    list[#list + 1] = entry
    while #list > (GS.MAX_TXN_REGISTRY or 512) do
        table.remove(list, 1)
    end
    return true
end

local function AddTxnAlias(cfg, primaryTxnId, aliasTxnId, record, knownEvent)
    primaryTxnId, aliasTxnId = ValidTxnId(primaryTxnId), ValidTxnId(aliasTxnId)
    if not primaryTxnId or not aliasTxnId or primaryTxnId == aliasTxnId then
        return false
    end
    local row = FindRegistryByTxn(cfg, primaryTxnId)
    if not row and type(knownEvent) == "table" then
        -- Registry eviction can drop the verified primary while the ledger still
        -- holds the accepted donation. Re-anchor A from that known event so the
        -- A→X alias survives /reload and a later gs:val:X can ResolveCanonical.
        RegisterTxn(cfg, {
            txnId = primaryTxnId,
            status = "verified",
            committed = true,
            coreSignature = knownEvent.coreSignature,
            approxTxnTime = knownEvent.approxTxnTime or knownEvent.timestamp,
            donor = knownEvent.actor or knownEvent.donor,
            itemId = knownEvent.itemId,
            quantity = knownEvent.quantity,
            guildGuid = knownEvent.guildGuid,
            bankTab = knownEvent.bankTab,
            generation = knownEvent.generation,
            occurrenceIndex = knownEvent.occurrenceIndex,
            neighborsOlder = knownEvent.neighborsOlder,
            neighborsNewer = knownEvent.neighborsNewer,
            verification = GS.CanonicalVerificationMode(knownEvent.verification),
            decidedBy = ValidGuid(knownEvent.writer) or ValidGuid(knownEvent.verifierGuid),
        })
        row = FindRegistryByTxn(cfg, primaryTxnId)
    end
    if not row then
        -- No durable primary to attach; still attempt a one-shot valuation fold
        -- when a known accepted donation is supplied.
        if type(record) == "table" and GS.OnDonationTxnAlias and type(knownEvent) == "table" then
            GS.OnDonationTxnAlias(record, primaryTxnId, aliasTxnId, knownEvent)
            if GS.WakePendingCorrectionsAfterAlias then
                GS.WakePendingCorrectionsAfterAlias(
                    record, primaryTxnId, aliasTxnId, knownEvent.itemId)
            end
        end
        return false
    end
    if type(row.aliases) ~= "table" then
        row.aliases = {}
    end
    for i = 1, #row.aliases do
        if row.aliases[i] == aliasTxnId then
            -- Re-confirm durable credit alias binding (invalidates stale ops
            -- validation cache after registry churn /reload) (#459).
            if type(record) == "table" and GS.RememberCreditEventAlias then
                GS.RememberCreditEventAlias(record, aliasTxnId, primaryTxnId)
            end
            -- Alias already registered; still reconcile valuations when a known
            -- accepted donation is supplied (cold competing-ID convergence).
            if type(record) == "table" and GS.OnDonationTxnAlias and type(knownEvent) == "table" then
                GS.OnDonationTxnAlias(record, primaryTxnId, aliasTxnId, knownEvent)
            end
            -- #459: re-confirming a trusted alias must still wake pending corrections.
            if type(record) == "table" and GS.WakePendingCorrectionsAfterAlias then
                GS.WakePendingCorrectionsAfterAlias(
                    record, primaryTxnId, aliasTxnId, row.itemId)
            end
            return true
        end
    end
    if #row.aliases >= 8 then
        return false
    end
    row.aliases[#row.aliases + 1] = aliasTxnId
    -- Also index alias as a lightweight pointer entry for FindRegistryByTxn.
    RegisterTxn(cfg, {
        txnId = aliasTxnId,
        status = "alias",
        aliasOf = primaryTxnId,
        committed = row.committed and true or false,
        coreSignature = row.coreSignature,
        approxTxnTime = row.approxTxnTime,
        donor = row.donor,
        itemId = row.itemId,
        quantity = row.quantity,
        guildGuid = row.guildGuid,
        bankTab = row.bankTab,
        generation = row.generation,
        occurrenceIndex = row.occurrenceIndex,
        neighborsOlder = row.neighborsOlder,
        neighborsNewer = row.neighborsNewer,
    })
    -- Durable correction/credit alias binding survives later registry eviction (#459).
    if type(record) == "table" and GS.RememberCreditEventAlias then
        GS.RememberCreditEventAlias(record, aliasTxnId, primaryTxnId)
    end
    if type(record) == "table" and GS.OnDonationTxnAlias then
        GS.OnDonationTxnAlias(record, primaryTxnId, aliasTxnId, knownEvent)
    end
    -- #459: alias discovery can unblock corrections pending on either txn id.
    if type(record) == "table" and GS.WakePendingCorrectionsAfterAlias then
        GS.WakePendingCorrectionsAfterAlias(
            record, primaryTxnId, aliasTxnId, row.itemId)
    end
    return true
end

--- Test/harness: register a trusted donation txn alias and wake corrections.
function GS._AddTxnAlias(record, primaryTxnId, aliasTxnId, knownEvent)
    if type(record) ~= "table" or type(record.accounting) ~= "table" then
        return false
    end
    local cfg = record.accounting._consumables
    if type(cfg) ~= "table" then
        return false
    end
    return AddTxnAlias(cfg, primaryTxnId, aliasTxnId, record, knownEvent)
end

local function EnsureEventArchive(record)
    if type(record.accounting) ~= "table" then
        return nil
    end
    if type(record.accounting._consumableEventArchive) ~= "table" then
        record.accounting._consumableEventArchive = {}
    end
    return record.accounting._consumableEventArchive
end

-- Ephemeral density-validation cache keyed by accounting table (not SavedVariables).
-- Avoids rescanning up to 8K rows on every GetCurrentRecord after the first check
-- for an unchanged mutation revision. Declared before BumpAccountingMutation so the
-- local upvalue resolves correctly under Lua 5.1.
local ledgerListShapeCache = setmetatable({}, { __mode = "k" })

--- Monotonic local ledger/evidence mutation counter (adoption stale-base pin).
-- Cheap O(1) bump; never scans ledger arrays. Controlled append/shelve/trim
-- paths keep dense shape, so advance a prior ok cache entry without rescanning.
local function BumpAccountingMutation(record)
    if type(record) ~= "table" or type(record.accounting) ~= "table" then
        return
    end
    local n = tonumber(record.accounting._mutationSeq) or 0
    record.accounting._mutationSeq = n + 1
    local cached = ledgerListShapeCache[record.accounting]
    if cached and cached.ok then
        -- Controlled append/shelve paths only add ValidateLedgerEventBody-valid
        -- rows; advance the cache watermark without a full body rescan.
        cached.mut = record.accounting._mutationSeq
    end
end

GS._BumpAccountingMutation = BumpAccountingMutation

function GS.GetAccountingMutationSeq(record)
    if type(record) ~= "table" or type(record.accounting) ~= "table" then
        return 0
    end
    return tonumber(record.accounting._mutationSeq) or 0
end

--- Enrich an op-first equivalent adjustment with a later ledger attributedGuid.
-- Does not rewrite attributed name, quantity, or other immutable fields.
-- Caller refreshes the affected export after all allowed enrichment (#447).
local function ReconcileAdjustmentAttributedGuid(record, existing, incoming)
    if type(existing) ~= "table" or type(incoming) ~= "table" then
        return false
    end
    if ValidGuid(existing.attributedGuid) then
        return false
    end
    local incomingGuid = ValidGuid(incoming.attributedGuid)
    if not incomingGuid then
        return false
    end
    local name = NormName(existing.attributed) or NormName(incoming.attributed)
    local canonName, canonGuid, err = GS.ResolveAttributedIdentity(record, name, incomingGuid)
    if err or not canonGuid then
        return false
    end
    if canonName and existing.attributed and NormName(existing.attributed) ~= canonName then
        return false
    end
    existing.attributedGuid = canonGuid
    BumpAccountingMutation(record)
    return true
end

--- Attach authenticated active-exporter cutover provenance to an already-retained
-- immutable-equivalent adjustment without reapplying quantity (#389 A2).
-- Never trusts self-declared event.gsProductionCredit / event.gsSourceCutoverMarker.
-- Caller refreshes the affected export from the final accepted state (#447).
local function ReconcileAdjustmentCutoverProvenance(record, existing, admissionCtx)
    if type(existing) ~= "table" or type(admissionCtx) ~= "table" then
        return false
    end
    local marker = admissionCtx.sourceCutoverMarker
    if type(marker) ~= "string" or marker == "" then
        return false
    end
    -- Live receivers only accept the installed canonical cutover marker.
    if GS.IsLiveActive and GS.IsLiveActive(record)
        and type(record.liveCutover) == "table"
        and marker ~= record.liveCutover.cutoverMarker then
        return false
    end
    local prior = existing.gsSourceCutoverMarker
    if type(prior) == "string" and prior ~= "" and prior ~= marker then
        -- Divergent authenticated markers: leave fail-closed.
        return false
    end
    local changed = false
    if prior ~= marker then
        existing.gsSourceCutoverMarker = marker
        changed = true
    end
    if GS.IsLiveActive and GS.IsLiveActive(record)
        and type(record.liveCutover) == "table"
        and existing.gsSourceCutoverMarker == record.liveCutover.cutoverMarker then
        local approx = tonumber(existing.approxTxnTime) or tonumber(existing.timestamp)
        local afterOk = true
        if GS.IsEvidenceAfterLiveCutover then
            afterOk = select(1, GS.IsEvidenceAfterLiveCutover(record, {
                approxTxnTime = approx,
            }))
        end
        local credit = afterOk and true or false
        if existing.gsProductionCredit ~= credit then
            existing.gsProductionCredit = credit
            changed = true
        end
    end
    if changed then
        BumpAccountingMutation(record)
    end
    return changed
end

--- True when both sides already carry conflicting non-nil unitCopper snapshots.
-- Non-mutating probe so rejectable conflicts are caught before accepted-state
-- enrichment (#447).
local function AdjustmentUnitCopperConflicts(existing, incoming)
    if type(existing) ~= "table" or type(incoming) ~= "table" then
        return false
    end
    if existing.unitCopper == nil or incoming.unitCopper == nil then
        return false
    end
    if type(GS.NormalizeAdjustmentUnitCopper) ~= "function" then
        return false
    end
    local qty = tonumber(existing.quantity)
    local existingUnit = GS.NormalizeAdjustmentUnitCopper(existing.unitCopper, qty)
    local incomingUnit = GS.NormalizeAdjustmentUnitCopper(incoming.unitCopper, qty)
    return existingUnit ~= nil and incomingUnit ~= nil and existingUnit ~= incomingUnit
end

local function FindLedgerEventByTxnId(record, txnId)
    txnId = ValidTxnId(txnId)
    if not txnId or type(record) ~= "table" or type(record.accounting) ~= "table" then
        return nil
    end
    local lists = {
        record.accounting._consumableEvents,
        record.accounting._consumableEventArchive,
    }
    for li = 1, #lists do
        local list = lists[li]
        if type(list) == "table" then
            local maxScan = (li == 1) and MaxLiveLedgerScan() or MaxArchivedLedgerScan()
            local limit = math.min(#list, maxScan)
            for i = 1, limit do
                local event = list[i]
                if type(event) == "table"
                    and (event.txnId == txnId or event.id == txnId) then
                    return event
                end
            end
        end
    end
    return nil
end

--- Complete officer-history shape for catch-up / duplicate provenance repair.
-- Same rule as OfficerHistoryWriter: explicit verifierGuid == writer.
local function IsCompleteOfficerHistoryEvent(event)
    if type(event) ~= "table" or event.verification ~= GS.VERIFICATION.OFFICER then
        return false
    end
    local writer = ValidGuid(event.writer)
    local verifier = ValidGuid(event.verifierGuid)
    return writer and verifier and verifier == writer and true or false
end

--- Collapse retained staged marker candidates onto the established canonical marker.
local function CollapseDonationCutoverMarkers(existing, canonical)
    if type(existing) ~= "table" or type(canonical) ~= "string" or canonical == "" then
        return false
    end
    local changed = false
    if existing.gsSourceCutoverMarker ~= canonical then
        existing.gsSourceCutoverMarker = canonical
        changed = true
    end
    if existing.gsAltSourceCutoverMarker ~= nil then
        existing.gsAltSourceCutoverMarker = nil
        changed = true
    end
    return changed
end

--- Attach authenticated cutover provenance to an already-retained immutable
-- donation without a second credit. Staged peers retain up to two competing
-- authenticated markers without last-writer-wins; the installed cutover later
-- selects the canonical one. Live peers only accept that installed marker and
-- may then classify production credit. Never trusts self-declared credit flags.
local function ReconcileDonationCutoverProvenance(record, existing, admissionCtx)
    if type(existing) ~= "table" or type(admissionCtx) ~= "table" then
        return false
    end
    local marker = admissionCtx.sourceCutoverMarker
    if type(marker) ~= "string" or marker == "" then
        return false
    end
    local live = GS.IsLiveActive and GS.IsLiveActive(record) and true or false
    local liveMarker = nil
    if live and type(record.liveCutover) == "table" then
        liveMarker = record.liveCutover.cutoverMarker
    end
    if live then
        if type(liveMarker) ~= "string" or liveMarker == "" or marker ~= liveMarker then
            return false
        end
    end
    local wasCredited = existing.gsProductionCredit == true
    local changed = false
    if live then
        if CollapseDonationCutoverMarkers(existing, liveMarker) then
            changed = true
        end
        local approx = tonumber(existing.approxTxnTime) or tonumber(existing.timestamp)
        local afterOk = true
        if GS.IsEvidenceAfterLiveCutover then
            afterOk = select(1, GS.IsEvidenceAfterLiveCutover(record, {
                approxTxnTime = approx,
            }))
        end
        local credit = afterOk and true or false
        if existing.gsProductionCredit ~= credit then
            existing.gsProductionCredit = credit
            changed = true
        end
    else
        -- Staged: never mint live credit. Missing primary attaches; a different
        -- authenticated marker is retained as one bounded alternate so M→D and
        -- D→M both survive until the established cutover chooses.
        if existing.gsProductionCredit == true then
            existing.gsProductionCredit = false
            changed = true
        end
        local prior = existing.gsSourceCutoverMarker
        if type(prior) ~= "string" or prior == "" then
            existing.gsSourceCutoverMarker = marker
            changed = true
        elseif prior ~= marker then
            local alt = existing.gsAltSourceCutoverMarker
            if type(alt) ~= "string" or alt == "" then
                existing.gsAltSourceCutoverMarker = marker
                changed = true
            end
            -- A third distinct marker is ignored while staged (bounded).
        end
    end
    if changed then
        BumpAccountingMutation(record)
        if GS._NotifyLocalDurableChange then
            GS._NotifyLocalDurableChange("ledger")
        end
        -- Late authenticated marker repair: promote a preserved pending price,
        -- or mint once when an eligible officer still has no assignment.
        if not wasCredited and existing.gsProductionCredit == true then
            local txnId = ValidTxnId(existing.txnId) or ValidTxnId(existing.id)
            if txnId and GS.ReconcilePendingValuations then
                GS.ReconcilePendingValuations(record, txnId, existing)
            end
            if GS.TryAssignDonationValuation then
                GS.TryAssignDonationValuation(record, existing, nil)
            end
            -- #459: late production credit can unblock pending/not_credited corrections.
            if GS.InvalidateCreditCorrectionProjection then
                GS.InvalidateCreditCorrectionProjection(record)
            end
            if GS.EnsureThenRedriveCreditCorrections then
                GS.EnsureThenRedriveCreditCorrections(record, {
                    eventId = existing.id,
                    itemId = existing.itemId,
                })
            end
        end
    end
    return changed
end

--- Same-occurrence verified donation duplicate: repair cutover provenance when a
-- later complete officer-history marked export arrives. Never appends a second
-- credit. Witness-only or incomplete officer claims cannot attach markers.
local function ReconcileVerifiedDonationDuplicate(record, existing, candidate, admissionCtx, event)
    if type(existing) ~= "table" or type(candidate) ~= "table" or type(event) ~= "table" then
        return false
    end
    if DonationBodiesConflict(existing, candidate) then
        return false
    end
    if not IsCompleteOfficerHistoryEvent(event) then
        return false
    end
    return ReconcileDonationCutoverProvenance(record, existing, admissionCtx)
end

local function ValidateDenseLedgerList(list, maxLen, datasetId)
    if type(list) ~= "table" then
        return false, "invalid_accounting"
    end
    local n = #list
    if n > maxLen then
        return false, "ledger_overflow"
    end
    local counted = 0
    local maxIndex = 0
    for k, v in pairs(list) do
        counted = counted + 1
        if counted > maxLen then
            return false, "ledger_overflow"
        end
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
            return false, "ledger_malformed"
        end
        if k > maxIndex then
            maxIndex = k
        end
        if type(v) ~= "table" then
            return false, "ledger_malformed"
        end
        -- Dense table rows must also be exportable ledger bodies. Empty `{}` or
        -- id-only stubs pass type(table) but Gossip skips/mis-exports them,
        -- leaving descriptor counts permanently incomplete for peers.
        if GS.ValidateLedgerEventBody then
            local bodyOk, bodyErr = GS.ValidateLedgerEventBody(v, nil, datasetId)
            if not bodyOk then
                return false, bodyErr or "ledger_malformed"
            end
        elseif type(v.id) ~= "string" or v.id == "" then
            return false, "invalid_id"
        end
    end
    -- Sparse or holey arrays: #list disagrees with dense 1..n occupancy.
    if counted ~= n or (n > 0 and maxIndex ~= n) then
        return false, "ledger_sparse"
    end
    return true
end

--- Fail-closed shape/bounds check for live + archived ledger arrays.
-- Cheap length overflow always; deep sparse/malformed/body scan cached per mutation.
-- @param accounting table
-- @param datasetId string|nil optional dataset scope for ValidateLedgerEventBody
function GS.ValidateLedgerEventLists(accounting, datasetId)
    if type(accounting) ~= "table" then
        return false, "invalid_accounting"
    end
    local live = accounting._consumableEvents
    local archive = accounting._consumableEventArchive
    if type(live) ~= "table" or type(archive) ~= "table" then
        return false, "invalid_accounting"
    end
    -- #457: informational withdrawals share these arrays under a separate count
    -- cap, so the array-length ceiling includes MAX_WITHDRAWAL_EVENTS headroom.
    local maxLive = (GS.MAX_LEDGER_EVENTS or 4096) + (GS.MAX_WITHDRAWAL_EVENTS or 1024)
    local maxArch = (GS.MAX_ARCHIVED_EVENTS or 4096) + (GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024)
    -- Always-cheap overflow gate (no pairs walk).
    if #live > maxLive or #archive > maxArch then
        return false, "ledger_overflow"
    end
    local mut = tonumber(accounting._mutationSeq) or 0
    local cached = ledgerListShapeCache[accounting]
    if cached and cached.mut == mut and cached.datasetId == (datasetId or false) then
        if cached.ok then
            return true
        end
        return false, cached.err or "invalid_accounting"
    end
    local ok, err = ValidateDenseLedgerList(live, maxLive, datasetId)
    if not ok then
        ledgerListShapeCache[accounting] = {
            mut = mut, ok = false, err = err, datasetId = datasetId or false,
        }
        return false, err
    end
    ok, err = ValidateDenseLedgerList(archive, maxArch, datasetId)
    if not ok then
        ledgerListShapeCache[accounting] = {
            mut = mut, ok = false, err = err, datasetId = datasetId or false,
        }
        return false, err
    end
    ledgerListShapeCache[accounting] = {
        mut = mut, ok = true, datasetId = datasetId or false,
    }
    return true
end

local function RemoveEvictedLedgerExportIds(removedIds, opts)
    if type(removedIds) ~= "table" or #removedIds < 1 or not GS.RemoveGossipExportBodies then
        return
    end
    opts = opts or {}
    if opts.bulk == true then
        -- Trusted archive trim: one pass over the full eviction set.
        GS.RemoveGossipExportBodies(removedIds, { bulk = true })
        return
    end
    local offset = 1
    while offset <= #removedIds do
        local chunk = {}
        local last = math.min(offset + 63, #removedIds)
        for i = offset, last do
            chunk[#chunk + 1] = removedIds[i]
        end
        GS.RemoveGossipExportBodies(chunk)
        offset = last + 1
    end
end

local function TrimEventArchive(record)
    local archive = EnsureEventArchive(record)
    if type(archive) ~= "table" then
        return false
    end
    local maxDon = GS.MAX_ARCHIVED_EVENTS or 4096
    local maxWd = GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024
    local removedIds = {}
    local removedTxn = {}
    local function noteRemoved(ev)
        if type(ev) ~= "table" then
            return
        end
        if type(ev.id) == "string" and ev.id ~= "" then
            removedIds[#removedIds + 1] = "gs:le:" .. ev.id
        end
        local txn = ev.txnId or ev.id
        if type(txn) == "string" and txn ~= "" then
            removedTxn[#removedTxn + 1] = txn
        end
    end
    -- Count once per kind, then compact linearly. Evict only the oldest excess
    -- rows of the kind that exceeds its independent cap (donation overflow must
    -- not remove below-cap receipts, and vice versa).
    local total = #archive
    local nonWithdraw = CountNonWithdrawalEvents(archive)
    local withdrawals = total - nonWithdraw
    local excessDon = nonWithdraw - maxDon
    if excessDon < 0 then excessDon = 0 end
    local excessWd = withdrawals - maxWd
    if excessWd < 0 then excessWd = 0 end
    if excessDon < 1 and excessWd < 1 then
        return false
    end
    local kept = {}
    local dropDon = excessDon
    local dropWd = excessWd
    for i = 1, total do
        local ev = archive[i]
        local isWd = IsWithdrawalLedgerEvent(ev)
        if isWd then
            if dropWd > 0 then
                noteRemoved(ev)
                dropWd = dropWd - 1
            else
                kept[#kept + 1] = ev
            end
        else
            if dropDon > 0 then
                noteRemoved(ev)
                dropDon = dropDon - 1
            else
                kept[#kept + 1] = ev
            end
        end
    end
    record.accounting._consumableEventArchive = kept
    archive = kept
    BumpAccountingMutation(record)
    -- Coalesce ledger + valuation export drops into one order compaction and
    -- one provider/manifest notification for this trusted retention trim.
    local beganRemovalBatch = false
    if GS.BeginGossipExportBodyRemovalBatch then
        GS.BeginGossipExportBodyRemovalBatch()
        beganRemovalBatch = true
    end
    RemoveEvictedLedgerExportIds(removedIds, { bulk = true })
    if GS.ForgetDonationValuations then
        GS.ForgetDonationValuations(record, removedTxn, { bulkExport = true })
    end
    if beganRemovalBatch and GS.EndGossipExportBodyRemovalBatch then
        GS.EndGossipExportBodyRemovalBatch()
    end
    -- Length may match the prior warm watermark after shelve+trim; still force
    -- archive paced rebuild so newly retained rows are exported and descriptor
    -- counts cannot exceed GetRecord coverage.
    if GS.MarkLedgerArchiveExportStale then
        GS.MarkLedgerArchiveExportStale()
    end
    return true
end

--- Move prior-generation live ledger rows into the bounded archive list.
-- Mirrors legacy Consumables.ShelvePriorGenerations so campaign rollover and
-- capacity pressure cannot permanently block new current-generation commits.
function GS.ShelvePriorGenerationsOnRecord(record)
    if type(record) ~= "table" or type(record.accounting) ~= "table" then
        return false
    end
    local cfg = record.accounting._consumables
    local generation = tonumber(cfg and cfg.generation) or 1
    local events = record.accounting._consumableEvents
    if type(events) ~= "table" or #events < 1 then
        return false
    end
    local archive = EnsureEventArchive(record)
    local kept = {}
    local moved = false
    for i = 1, #events do
        local event = events[i]
        local eventGen = type(event) == "table" and tonumber(event.generation) or nil
        if eventGen and eventGen < generation then
            archive[#archive + 1] = event
            moved = true
        else
            kept[#kept + 1] = event
        end
    end
    if not moved then
        return false
    end
    record.accounting._consumableEvents = kept
    TrimEventArchive(record)
    -- Shelve mutates live+archive occupancy even when trim is a no-op.
    BumpAccountingMutation(record)
    return true
end

local function AppendArchivedLedgerEvent(record, event)
    local archive = EnsureEventArchive(record)
    if type(archive) ~= "table" then
        return false, "invalid_accounting"
    end
    local maxDon = GS.MAX_ARCHIVED_EVENTS or 4096
    local maxTotal = maxDon + (GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024)
    if IsWithdrawalLedgerEvent(event) then
        if #archive >= maxTotal then
            return false, "full"
        end
    else
        if CountNonWithdrawalEvents(archive) >= maxDon then
            return false, "full"
        end
        if #archive >= maxTotal then
            return false, "full"
        end
    end
    archive[#archive + 1] = event
    BumpAccountingMutation(record)
    return true
end

--- Retry trusted pending correct-contributor ops through authenticated admission (#459).
-- Skips untrusted_relay/evidence. Bounds attempted work (including failures).
-- opts.eventId / opts.itemId wake related deps with OR matching when both set.
-- Non-reentrant: nested accepts coalesce into one continuation with a saved cursor.
-- @return promotedCount, attemptCount
local creditRedriveDepth = 0
local creditRedriveContinuation = setmetatable({}, { __mode = "k" })

local function CreditRedriveMatch(record, body, opts)
    local eventIdFilter = opts.eventId
    local itemIdFilter = tonumber(opts.itemId)
    if (type(eventIdFilter) ~= "string" or eventIdFilter == "") and not itemIdFilter then
        return true
    end
    local matchEvent = false
    if type(eventIdFilter) == "string" and eventIdFilter ~= "" then
        local canonical = GS.CanonicalCreditEventId
            and GS.CanonicalCreditEventId(record, body.target) or body.target
        local filterCanon = GS.CanonicalCreditEventId
            and GS.CanonicalCreditEventId(record, eventIdFilter) or eventIdFilter
        matchEvent = (canonical == filterCanon or body.target == eventIdFilter)
        -- Alias of either side also matches.
        if not matchEvent and type(body.target) == "string" then
            local bodyCanon = canonical
            local filterPrimary = filterCanon
            matchEvent = bodyCanon ~= nil and filterPrimary ~= nil and bodyCanon == filterPrimary
        end
    end
    local matchItem = false
    if itemIdFilter then
        local bodyItem = tonumber(body.value and body.value.itemId)
        if bodyItem and bodyItem == itemIdFilter then
            matchItem = true
        else
            local ev = GS.FindLedgerEventById and GS.FindLedgerEventById(record, body.target)
            if ev and tonumber(ev.itemId) == itemIdFilter then
                matchItem = true
            end
        end
    end
    if type(eventIdFilter) == "string" and eventIdFilter ~= "" and itemIdFilter then
        return matchEvent or matchItem
    end
    if type(eventIdFilter) == "string" and eventIdFilter ~= "" then
        return matchEvent
    end
    return matchItem
end

--- True when opts is an explicit full dependency wake (no item/event filter).
-- Distinct from nil timer-resume continuation (#459 cutover `{}` wake).
local function IsFullCreditRedriveWake(opts)
    return type(opts) == "table" and opts.eventId == nil and opts.itemId == nil
end

--- Merge an incoming redrive wake into continuation filters (#459).
-- nil opts = timer resume (keep filters). Explicit `{}` / unfiltered table = full
-- wake that clears item/event filters and dominates later narrow wakes until a
-- full snapshot drains. Broader filters clear any mid-wave snapshot.
-- @return table cont, boolean broadened
local function MergeCreditRedriveWake(record, opts)
    local cont = creditRedriveContinuation[record]
    if type(cont) ~= "table" then
        cont = {
            opts = opts or {},
            scheduled = false,
            followUpWake = false,
            fullWake = IsFullCreditRedriveWake(opts),
        }
        if cont.fullWake then
            cont.opts = {
                maxAttempts = opts and opts.maxAttempts or nil,
            }
        end
        creditRedriveContinuation[record] = cont
        return cont, cont.fullWake
    end
    local prev = cont.opts or {}
    local merged = {}
    for k, v in pairs(prev) do
        merged[k] = v
    end
    local broadened = false
    local externalWake = type(opts) == "table"
    if externalWake then
        if IsFullCreditRedriveWake(opts) then
            -- Explicit full wake dominates narrower retained filters.
            if merged.eventId ~= nil or merged.itemId ~= nil or not cont.fullWake then
                broadened = true
            end
            merged.eventId = nil
            merged.itemId = nil
            cont.fullWake = true
        elseif cont.fullWake then
            -- Outstanding full wake must not be narrowed by a later item wake.
            merged.eventId = nil
            merged.itemId = nil
        else
            if opts.eventId and prev.eventId and opts.eventId ~= prev.eventId then
                merged.eventId = nil
                broadened = true
            elseif opts.eventId and not prev.eventId and not prev.itemId then
                merged.eventId = opts.eventId
            elseif opts.eventId and prev.itemId and not prev.eventId then
                merged.eventId = opts.eventId
            end
            if opts.itemId and prev.itemId and tonumber(opts.itemId) ~= tonumber(prev.itemId) then
                merged.itemId = nil
                merged.eventId = nil
                broadened = true
            elseif opts.itemId and not (prev.eventId or prev.itemId) then
                merged.itemId = opts.itemId
            elseif opts.itemId then
                if prev.itemId or prev.eventId then
                    merged.itemId = opts.itemId
                end
            end
        end
        if opts.maxAttempts then
            merged.maxAttempts = opts.maxAttempts
        end
    end
    cont.opts = merged
    if broadened then
        cont.snapshot = nil
        cont.index = nil
    end
    if externalWake and (type(cont.snapshot) == "table" or creditRedriveDepth > 0
        or cont.scheduled) then
        cont.followUpWake = true
    end
    return cont, broadened
end

local function ScheduleCreditRedriveContinuation(record, opts)
    if type(record) ~= "table" then
        return
    end
    local cont = MergeCreditRedriveWake(record, opts)
    if cont.scheduled then
        return
    end
    cont.scheduled = true
    local function run()
        local state = creditRedriveContinuation[record]
        if type(state) ~= "table" then
            return
        end
        state.scheduled = false
        if GS.RedrivePendingContributorCorrections then
            -- Pass nil so Redrive merges against current cont.opts (preserves
            -- wakes coalesced while this timer was queued) without treating
            -- the timer itself as a new dependency wake.
            GS.RedrivePendingContributorCorrections(record, nil)
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, run)
    else
        run()
    end
end

function GS.RedrivePendingContributorCorrections(record, opts)
    if type(opts) == "string" then
        opts = { eventId = opts }
    end
    if type(record) ~= "table" or type(record.operations) ~= "table" then
        return 0, 0
    end
    if creditRedriveDepth > 0 then
        ScheduleCreditRedriveContinuation(record, opts)
        return 0, 0
    end
    local ops = record.operations
    if type(ops.pending) ~= "table" then
        return 0, 0
    end
    -- Accumulate rebuild work across nested AdmitRemoteOperation callbacks.
    -- Nested callers (projection continuation / Ensure-then-redrive wake) share
    -- the remaining allowance and must not reset an already-consumed counter.
    local nested = GS._creditProjectionAccumulating == true
    local shareBudget = nested
        or (type(opts) == "table" and opts._shareCallbackBudget == true)
    if not shareBudget then
        local budget = tonumber(opts and opts.workBudget)
            or tonumber(GS._creditProjectionWorkBudgetOverride)
            or tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET)
            or 16384
        GS._creditProjectionCallbackWork = 0
        GS._creditProjectionCallbackLimit = budget
        local overshoot = tonumber(GS._creditProjectionAtomicOvershootOverride)
            or tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT)
            or 512
        GS._creditProjectionCallbackHardLimit = budget + overshoot
    end
    GS._creditProjectionAccumulating = true
    -- Always merge the incoming wake; never overwrite cont.opts with a narrow
    -- filter while an existing snapshot drains (A/B/C interleaving).
    local cont = MergeCreditRedriveWake(record, opts)
    local waveOpts = cont.opts or opts or {}
    -- Deletion-safe wave: snapshot eligible ids once; resume by index into that
    -- snapshot (skip entries already removed by successful admission).
    local snapshot = cont.snapshot
    local startIndex = tonumber(cont.index) or 1
    if type(snapshot) ~= "table" then
        local ids = {}
        for id, entry in pairs(ops.pending) do
            local body = entry and entry.body
            if type(body) == "table"
                and body.kind == (GS.KIND and GS.KIND.CORRECT_CONTRIBUTOR)
                and type(body.target) == "string" then
                local reason = entry.reason
                if reason ~= "untrusted_relay" and reason ~= "evidence" then
                    if CreditRedriveMatch(record, body, waveOpts) then
                        ids[#ids + 1] = id
                    end
                end
            end
        end
        table.sort(ids)
        snapshot = ids
        startIndex = 1
        cont.snapshot = snapshot
        cont.index = 1
        -- Starting a fresh snapshot consumes the follow-up request that caused it.
        cont.followUpWake = false
    end
    local promoted = 0
    local attempts = 0
    local maxAttempts = tonumber(waveOpts.maxAttempts) or 32
    -- Independent callback work ceiling (not derived from measured history cost).
    local workBudget = tonumber(waveOpts.workBudget)
        or tonumber(GS._creditProjectionWorkBudgetOverride)
        or tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET)
        or 16384
    creditRedriveDepth = creditRedriveDepth + 1
    local i = startIndex
    while i <= #snapshot do
        if attempts >= maxAttempts then
            break
        end
        local softLimit = tonumber(GS._creditProjectionCallbackLimit) or workBudget
        if (tonumber(GS._creditProjectionCallbackWork) or 0) >= softLimit then
            break
        end
        attempts = attempts + 1
        local id = snapshot[i]
        i = i + 1
        local entry = ops.pending[id]
        local body = entry and entry.body
        if type(body) ~= "table" then
            -- Already removed or malformed; attempt still counts toward budget.
        elseif type(entry.sender) ~= "string" or entry.sender == "" then
            -- leave pending until authenticated sender is known
        else
            local alreadyAccepted = ops.records and ops.records[id]
            if not alreadyAccepted and GS._AcceptedCount
                and GS._AcceptedCount(ops) >= (GS.MAX_ACCEPTED_OPERATIONS or 0) then
                -- Capacity full: leave pending; do not mutate credit.
            elseif type(GS.AdmitRemoteOperation) == "function" then
                local status, reason = GS:AdmitRemoteOperation(body, {
                    sender = entry.sender,
                    offlineRecord = record,
                    preserveAttribution = true,
                    _creditRedrive = true,
                })
                if status == "accepted" or status == "duplicate" then
                    promoted = promoted + 1
                elseif status == "pending" and reason == "work_budget" then
                    -- Paced rebuild deferred mid-unit; retry this id next slice.
                    i = i - 1
                    break
                end
            end
        end
    end
    creditRedriveDepth = creditRedriveDepth - 1
    if i <= #snapshot then
        cont.snapshot = snapshot
        cont.index = i
        cont.opts = waveOpts
        cont.scheduled = false
        ScheduleCreditRedriveContinuation(record, nil)
    else
        -- Wave complete: become idle unless a real dependency wake arrived
        -- during this drain (followUpWake). Full-wake filter clearance sticks
        -- so a later cutover `{}` is not required to fight stale item filters.
        local followUp = cont.followUpWake == true
        local wasFull = cont.fullWake == true
        local retainedOpts = waveOpts
        if wasFull and not followUp then
            retainedOpts = { maxAttempts = waveOpts and waveOpts.maxAttempts or nil }
        end
        creditRedriveContinuation[record] = {
            opts = retainedOpts,
            scheduled = false,
            followUpWake = false,
            -- Keep fullWake through a follow-up so narrow wakes cannot re-narrow.
            fullWake = followUp and wasFull or false,
        }
        if followUp then
            ScheduleCreditRedriveContinuation(record, wasFull and {} or nil)
        end
    end
    -- Only the budget owner closes the allowance; nested share leaves it open.
    if not nested then
        GS._creditProjectionAccumulating = false
    end
    return promoted, attempts, tonumber(GS._creditProjectionCallbackWork) or 0
end

local function AppendLedgerEvent(record, event)
    local cfg = record.accounting and record.accounting._consumables
    local curGen = tonumber(cfg and cfg.generation)
    local eventGen = type(event) == "table" and tonumber(event.generation) or nil
    -- Recompute durable production-credit classification; never trust a remote
    -- self-declared flag to bypass the live cutover boundary.
    if GS.AssignProductionCredit then
        GS.AssignProductionCredit(record, event)
    end
    -- Historical rows belong in the archive list once the live generation advanced.
    if eventGen and curGen and eventGen < curGen then
        local ok, err = AppendArchivedLedgerEvent(record, event)
        if ok and type(event) == "table" then
            if GS.InvalidateCreditCorrectionProjection then
                GS.InvalidateCreditCorrectionProjection(record)
            end
            GS.EnsureThenRedriveCreditCorrections(record, {
                eventId = event.id,
                itemId = event.itemId,
            })
        end
        return ok, err
    end
    local list = record.accounting._consumableEvents
    if type(list) ~= "table" then
        record.accounting._consumableEvents = {}
        list = record.accounting._consumableEvents
    end
    local maxDonLive = GS.MAX_LEDGER_EVENTS or 4096
    if CountNonWithdrawalEvents(list) >= maxDonLive then
        if GS.ShelvePriorGenerationsOnRecord(record)
            and CountNonWithdrawalEvents(record.accounting._consumableEvents or {}) < maxDonLive then
            list = record.accounting._consumableEvents
        else
            return false, "full"
        end
    end
    list[#list + 1] = event
    if type(cfg) == "table" then
        cfg.eventSeq = (tonumber(cfg.eventSeq) or 0) + 1
    end
    BumpAccountingMutation(record)
    if type(event) == "table" then
        -- Balance/credit changes can activate previously floor-held accepted heads
        -- and redrive trusted pending corrections for related events/items.
        -- One shared callback allowance across Ensure + redrive (#459).
        if GS.InvalidateCreditCorrectionProjection then
            GS.InvalidateCreditCorrectionProjection(record)
        end
        GS.EnsureThenRedriveCreditCorrections(record, {
            eventId = event.id,
            itemId = event.itemId,
        })
    end
    return true
end

--- Total transferable accepted ledger rows (live + archived).
function GS.CountAcceptedLedgerEvents(record)
    if type(record) ~= "table" or type(record.accounting) ~= "table" then
        return 0
    end
    local n = 0
    local live = record.accounting._consumableEvents
    local archive = record.accounting._consumableEventArchive
    if type(live) == "table" then
        n = n + #live
    end
    if type(archive) == "table" then
        n = n + #archive
    end
    return n
end

local function BuildDonationEvent(evidence, writerGuid, txnId, verification, record)
    txnId = ValidTxnId(txnId)
    writerGuid = ValidGuid(writerGuid)
    local donor = NormName(evidence.donor)
    local itemId = tonumber(evidence.itemId)
    local quantity = FloorNonNeg(evidence.quantity)
    if not txnId or not writerGuid or not donor or not IsItemId(itemId) or quantity < 1 then
        return nil
    end
    local event = {
        type = GS.LEDGER_EVENT.DONATION,
        id = txnId,
        txnId = txnId,
        generation = tonumber(evidence.generation) or 1,
        timestamp = tonumber(evidence.approxTxnTime) or tonumber(evidence.observedAt) or Now(),
        actor = donor,
        itemId = itemId,
        quantity = quantity,
        source = "guildbank",
        writer = writerGuid,
        verification = verification or GS.VERIFICATION.WITNESSES,
        coreSignature = evidence.coreSignature,
        occurrenceIndex = tonumber(evidence.occurrenceIndex),
        guildGuid = evidence.guildGuid,
        bankTab = tonumber(evidence.bankTab),
        neighborsOlder = CopyStringList(evidence.neighborsOlder, 3),
        neighborsNewer = CopyStringList(evidence.neighborsNewer, 3),
        campaignId = evidence.campaignId,
        ageHours = tonumber(evidence.ageHours),
    }
    -- Persist a uniquely known original donor GUID without rewriting actor name.
    -- Relayed claimed GUIDs must bind to the donor name (soft-drop on mismatch).
    if type(record) == "table" then
        local claimed = ValidGuid(evidence.donorGuid) or ValidGuid(evidence.actorGuid)
        local _, donorGuid = GS.ResolveDonorIdentity(record, donor, claimed)
        if donorGuid then
            event.actorGuid = donorGuid
        end
    end
    return event
end

--- Read-only eligibility view floored to the immutable live cutover.
-- Does not mutate archived or live SavedVariables maps.
local function EligibilityFlooredToLiveCutover(eligibility, record)
    if not (GS.IsLiveActive and GS.IsLiveActive(record)) or type(record.liveCutover) ~= "table" then
        return eligibility
    end
    local cutTs = tonumber(record.liveCutover.contextObservedAt)
        or tonumber(record.liveCutover.eligibilityBoundary
            and record.liveCutover.eligibilityBoundary.tabEligibleFrom)
    if not cutTs then
        return eligibility
    end
    if type(eligibility) ~= "table" then
        return eligibility
    end
    local floored = {
        baselineEstablished = true,
        baselineAt = cutTs,
        tabEligibleFrom = cutTs,
        items = {},
        liveCutoverAt = cutTs,
        liveCutoverMarker = record.liveCutover.cutoverMarker
            or eligibility.liveCutoverMarker,
    }
    local baselineAt = tonumber(eligibility.baselineAt)
    if baselineAt and baselineAt > cutTs then
        floored.baselineAt = baselineAt
    end
    local tabFrom = tonumber(eligibility.tabEligibleFrom)
    if tabFrom and tabFrom > cutTs then
        floored.tabEligibleFrom = tabFrom
    end
    if type(eligibility.items) == "table" then
        for key, value in pairs(eligibility.items) do
            local itemFrom = tonumber(value)
            if itemFrom then
                floored.items[key] = itemFrom < cutTs and cutTs or itemFrom
            end
        end
    end
    return floored
end

--- Resolve generation/items/tab/eligibility for the evidence's campaign.
-- Historical rows use archived campaign context, never the live campaign alone.
-- When the dataset is live, archived/live eligibility views are floored to the
-- canonical cutover so hour-span ambiguity cannot be bypassed (#389).
local function ResolveEvidenceCampaignContext(record, evidence)
    local live = record.accounting and record.accounting._consumables
    if type(live) ~= "table" then
        return nil, "invalid_accounting"
    end
    local campaignId = evidence and evidence.campaignId
    if type(campaignId) ~= "string" or campaignId == "" then
        campaignId = record.currentCampaignId
    end
    if campaignId == record.currentCampaignId then
        return {
            generation = live.generation,
            requestedItems = live.requestedItems,
            bankTab = live.bankTab,
            guild = live.guild,
            eligibility = EligibilityFlooredToLiveCutover(live.eligibility, record),
            historical = false,
        }
    end
    local archive = record.campaignArchives and record.campaignArchives[campaignId]
    if type(archive) ~= "table" then
        return nil, "missing_campaign_archive"
    end
    if GS.ValidateCampaignArchive then
        local ok, err = GS.ValidateCampaignArchive(archive, campaignId, record)
        if not ok then
            return nil, err or "invalid_campaign_archive"
        end
    end
    local header = record.campaigns and record.campaigns[campaignId]
    local ctx = record.campaignContext and record.campaignContext[campaignId]
    local bankTab = tonumber(archive.bankTab)
        or tonumber(header and header.bankTabAtStart)
        or tonumber(ctx and ctx.bankTab)
        or tonumber(live.bankTab)
    -- Prefer archived eligibility when present; otherwise fail closed for credit.
    local eligibility = archive.eligibility
    if eligibility == nil and type(ctx) == "table" and type(ctx.eligibility) == "table" then
        eligibility = ctx.eligibility
    end
    local hasProof = type(eligibility) == "table"
    return {
        generation = archive.generation,
        requestedItems = archive.requestedItems,
        bankTab = bankTab,
        guild = live.guild,
        eligibility = EligibilityFlooredToLiveCutover(eligibility, record),
        historical = true,
        hasEligibilityProof = hasProof,
    }
end

local function IsEvidenceEligible(record, evidence)
    local ctx, ctxErr = ResolveEvidenceCampaignContext(record, evidence)
    if not ctx then
        return false, ctxErr or "invalid_accounting"
    end
    if tonumber(evidence.generation) ~= tonumber(ctx.generation) then
        return false, "generation_mismatch"
    end
    local clubId = ctx.guild and tostring(ctx.guild.guid or "")
    if clubId == "" or tostring(evidence.guildGuid or "") ~= clubId then
        return false, "guild_mismatch"
    end
    local tab = tonumber(ctx.bankTab)
    if not tab or tonumber(evidence.bankTab) ~= tab then
        return false, "bank_tab_mismatch"
    end
    -- Requested item required for the evidence's campaign credit.
    local items = ctx.requestedItems
    if type(items) ~= "table" or type(items[tostring(evidence.itemId)] or items[evidence.itemId]) ~= "table" then
        local found = false
        for _, row in pairs(items or {}) do
            if type(row) == "table" and tonumber(row.itemId) == tonumber(evidence.itemId) then
                found = true
                break
            end
        end
        if not found then
            return false, "item_not_requested"
        end
    end
    -- Historical campaigns without recoverable cutoffs cannot prove eligibility.
    if ctx.historical and not ctx.hasEligibilityProof then
        return false, "missing_eligibility_context"
    end
    if O and O.IsEvidenceEligible and ctx.eligibility then
        if not O.IsEvidenceEligible(evidence, ctx.eligibility) then
            return false, "not_eligible"
        end
    elseif ctx.eligibility then
        local elig = ctx.eligibility
        local approx = tonumber(evidence.approxTxnTime)
        if elig.baselineEstablished and approx then
            local tabFrom = tonumber(elig.tabEligibleFrom)
            if tabFrom and approx < tabFrom then
                return false, "not_eligible"
            end
            local itemFrom = elig.items and (elig.items[tostring(evidence.itemId)] or elig.items[evidence.itemId])
            itemFrom = tonumber(itemFrom)
            if itemFrom and approx < itemFrom then
                return false, "not_eligible"
            end
        end
    end
    -- Hour-granular bank evidence that could fall on either side of a cutoff
    -- must stay pending/ambiguous. Aging cannot prove post-cutover timing:
    -- approxTxnTime = observedAt - ageHours*3600 stays in the same hour bucket
    -- while the real deposit may still predate activation (#389).
    if O and O.EvidenceSpansEligibilityBoundary and ctx.eligibility then
        if O.EvidenceSpansEligibilityBoundary(evidence, ctx.eligibility) then
            return false, "ambiguous_boundary"
        end
    end
    return true
end

local function CommitVerifiedCluster(record, cluster, writerGuid, verificationMode, provenance)
    local cfg = record.accounting._consumables
    local evidence = cluster.evidence
    if type(evidence) ~= "table" then
        return false, "invalid_evidence"
    end

    -- Already credited for this occurrence?
    local regHit, regHow = RegistryMatchOccurrence(cfg, evidence)
    if regHow == "ambiguous" then
        cluster.status = "ambiguous"
        return false, "ambiguous"
    end
    if regHit and regHit.status == "verified" and ValidTxnId(regHit.txnId) then
        cluster.status = "verified"
        cluster.txnId = regHit.txnId
        return true, "duplicate"
    end
    local ledHit, ledHow = FindLedgerDonationOccurrence(record, evidence)
    if ledHow == "ambiguous" then
        cluster.status = "ambiguous"
        return false, "ambiguous"
    end
    if ledHit and ValidTxnId(ledHit.txnId) then
        local ledRelation = ExactIdOccurrenceRelation({
            coreSignature = ledHit.coreSignature,
            guildGuid = ledHit.guildGuid,
            bankTab = ledHit.bankTab,
            generation = ledHit.generation,
            approxTxnTime = ledHit.timestamp or ledHit.approxTxnTime,
            occurrenceIndex = ledHit.occurrenceIndex,
            neighborsOlder = ledHit.neighborsOlder,
            neighborsNewer = ledHit.neighborsNewer,
            status = "verified",
        }, evidence)
        if ledRelation == "same" then
            cluster.status = "verified"
            cluster.txnId = ledHit.txnId
            RegisterTxn(cfg, {
                txnId = ledHit.txnId,
                status = "verified",
                committed = true,
                coreSignature = evidence.coreSignature,
                approxTxnTime = evidence.approxTxnTime,
                donor = evidence.donor,
                itemId = evidence.itemId,
                quantity = evidence.quantity,
                guildGuid = evidence.guildGuid,
                bankTab = evidence.bankTab,
                generation = evidence.generation,
                occurrenceIndex = evidence.occurrenceIndex,
                neighborsOlder = evidence.neighborsOlder,
                neighborsNewer = evidence.neighborsNewer,
                verification = GS.CanonicalVerificationMode(ledHit.verification),
            })
            return true, "duplicate"
        elseif ledRelation == "uncertain" then
            cluster.status = "ambiguous"
            return false, "ambiguous"
        end
        -- Distinct ledger row matched by residual scoring: fall through and remint.
    end

    -- Re-check boundary uncertainty immediately before credit.
    local eligOk, eligErr = IsEvidenceEligible(record, evidence)
    if not eligOk then
        if eligErr == "ambiguous_boundary" then
            cluster.status = "ambiguous"
            return false, "ambiguous_boundary"
        end
        return false, eligErr or "not_eligible"
    end

    local txnId = cluster.txnId
    if not ValidTxnId(txnId) then
        txnId = GS.AllocateCanonicalTxnId(record, writerGuid, evidence)
        cluster.txnId = txnId
    end
    if not ValidTxnId(txnId) then
        return false, "id_failed"
    end

    local function ResolveExactIdCollision(candidateId)
        local existing = FindRegistryByTxn(cfg, candidateId)
        if not existing then
            return candidateId, nil
        end
        if existing.status == "alias" and type(existing.aliasOf) == "string" then
            existing = FindRegistryByTxn(cfg, existing.aliasOf) or existing
        end
        if existing.status ~= "verified" then
            return candidateId, nil
        end
        local relation = ExactIdOccurrenceRelation(existing, evidence)
        if relation == "same" then
            return existing.txnId, "duplicate"
        elseif relation == "distinct" then
            local reminted = AllocateCollisionRemintTxnId(record, writerGuid)
            if not ValidTxnId(reminted) then
                return nil, "ambiguous"
            end
            return reminted, nil
        end
        return nil, "ambiguous"
    end

    -- Competing candidate IDs: only treat exact-ID hits as duplicates when
    -- MatchScore agrees they are the same occurrence. Fingerprint collisions
    -- (identical core/neighbors/index, temporally separated deposits) must not
    -- silently merge. Clear temporal separation remints a seq ID; uncertain
    -- evidence stays ambiguous rather than inventing uniqueness.
    do
        local resolved, how = ResolveExactIdCollision(txnId)
        if how == "duplicate" then
            cluster.status = "verified"
            cluster.txnId = resolved
            return true, "duplicate"
        elseif how == "ambiguous" then
            cluster.status = "ambiguous"
            return false, "ambiguous"
        end
        txnId = resolved
        cluster.txnId = txnId
    end

    -- Prefer lexicographically smaller ID when a pending candidate already used one.
    -- Never reclaim an ID already owned by a verified distinct occurrence.
    local pendingCands = EnsurePendingDonationCandidates(record)
    if type(pendingCands) == "table" then
        for candId, cand in pairs(pendingCands) do
            if type(cand) == "table" and ValidTxnId(candId) then
                local score = MatchScore({
                    coreSignature = cand.coreSignature,
                    guildGuid = cand.guildGuid,
                    bankTab = cand.bankTab,
                    generation = cand.generation,
                    approxTxnTime = cand.timestamp or cand.approxTxnTime,
                    occurrenceIndex = cand.occurrenceIndex,
                    neighborsOlder = cand.neighborsOlder,
                    neighborsNewer = cand.neighborsNewer,
                    status = "pending",
                }, evidence)
                if score and score >= ((O and O.MIN_MATCH_SCORE) or 100) then
                    if candId < txnId then
                        local resolved, how = ResolveExactIdCollision(candId)
                        if how == nil and ValidTxnId(resolved) then
                            txnId = resolved
                            cluster.txnId = txnId
                        end
                    end
                end
            end
        end
    end

    -- Final exact-ID guard after pending preference (prevents reclaiming a
    -- colliding fingerprint that a peer ledger retained as a pending candidate).
    do
        local resolved, how = ResolveExactIdCollision(txnId)
        if how == "duplicate" then
            cluster.status = "verified"
            cluster.txnId = resolved
            return true, "duplicate"
        elseif how == "ambiguous" then
            cluster.status = "ambiguous"
            return false, "ambiguous"
        end
        txnId = resolved
        cluster.txnId = txnId
    end

    local mode = GS.CanonicalVerificationMode(verificationMode)
    local event = BuildDonationEvent(evidence, writerGuid, txnId, mode, record)
    if not event then
        return false, "invalid_event"
    end
    if mode == GS.VERIFICATION.OFFICER then
        event.verifierGuid = writerGuid
        local rankSnap = provenance and tonumber(provenance.rankOrder)
        if rankSnap and rankSnap >= 1 and rankSnap <= 20 and rankSnap == math.floor(rankSnap) then
            event.verifierRankOrder = rankSnap
        end
    end
    -- Preserve validated evidence campaign provenance (historical late quorum
    -- must not rewrite archived campaignId onto the current campaign).
    if type(event.campaignId) ~= "string" or event.campaignId == "" then
        event.campaignId = record.currentCampaignId
    end
    event.datasetId = record.datasetId
    local ok, err = AppendLedgerEvent(record, event)
    if not ok then
        return false, err or "full"
    end
    RegisterTxn(cfg, {
        txnId = txnId,
        status = "verified",
        committed = true,
        coreSignature = evidence.coreSignature,
        approxTxnTime = evidence.approxTxnTime,
        donor = evidence.donor,
        itemId = evidence.itemId,
        quantity = evidence.quantity,
        guildGuid = evidence.guildGuid,
        bankTab = evidence.bankTab,
        generation = evidence.generation,
        occurrenceIndex = evidence.occurrenceIndex,
        neighborsOlder = evidence.neighborsOlder,
        neighborsNewer = evidence.neighborsNewer,
        verification = mode,
        decidedBy = writerGuid,
        decidedAt = Now(),
    })
    -- Alias any pending relayed donation candidates for this occurrence.
    if type(pendingCands) == "table" then
        for candId, cand in pairs(pendingCands) do
            if type(cand) == "table" and ValidTxnId(candId) and candId ~= txnId then
                local score = MatchScore({
                    coreSignature = cand.coreSignature,
                    guildGuid = cand.guildGuid,
                    bankTab = cand.bankTab,
                    generation = cand.generation,
                    approxTxnTime = cand.timestamp or cand.approxTxnTime,
                    occurrenceIndex = cand.occurrenceIndex,
                    neighborsOlder = cand.neighborsOlder,
                    neighborsNewer = cand.neighborsNewer,
                    status = "pending",
                }, evidence)
                if score and score >= ((O and O.MIN_MATCH_SCORE) or 100) then
                    AddTxnAlias(cfg, txnId, candId, record, event)
                    pendingCands[candId] = nil
                end
            elseif candId == txnId then
                pendingCands[candId] = nil
            end
        end
    end
    cluster.status = "verified"
    cluster.txnId = txnId
    -- Reclaim verified rows so pending capacity tracks unfinished work only.
    local campId = evidence.campaignId or record.currentCampaignId
    if type(campId) == "string" and campId ~= "" then
        local camp = record.observations and record.observations.byCampaign
            and record.observations.byCampaign[campId]
        if type(camp) == "table" then
            CompactVerifiedPending(camp.pending)
        end
    end
    Debug("Info", "donation committed txn=%s mode=%s witnesses=%s",
        tostring(txnId), tostring(mode),
        tostring(GS.CountIndependentWitnesses(record, cluster.witnesses)))
    if GS.ReconcilePendingValuations then
        GS.ReconcilePendingValuations(record, txnId, event)
    end
    if GS.TryAssignDonationValuation then
        GS.TryAssignDonationValuation(record, event, evidence)
    end
    return true, "accepted"
end

--- Three-witness quorum only. Rank changes do not upgrade pending reports here.
local function TryAutoVerify(record, cluster)
    if type(cluster) ~= "table" or cluster.status == "verified" then
        return false
    end
    if cluster.status == "ambiguous" then
        return false
    end
    local n = GS.CountIndependentWitnesses(record, cluster.witnesses)
    if n < (GS.WITNESS_THRESHOLD or 3) then
        return false
    end
    -- Prefer a stable writer: first sorted independent witness GUID.
    local writer = nil
    local keys = {}
    for key, row in pairs(cluster.witnesses or {}) do
        local g = type(row) == "table" and ValidGuid(row.guid) or ValidGuid(key)
        if g then keys[#keys + 1] = g end
    end
    table.sort(keys)
    writer = keys[1]
    local ok, err = CommitVerifiedCluster(record, cluster, writer)
    if not ok and err == "ambiguous_boundary" then
        cluster.status = "ambiguous"
        return false
    end
    return ok and true or false
end

--- Roster member for this sender. Payload rank/isAdmin/verification are ignored.
local function FreshRosterMember(name, expectedGuid)
    local gossip = SF.GuildGossip
    if not gossip or type(gossip.GetGuildMember) ~= "function" then
        return nil
    end
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local roster = gossip.GetGuildMember(name)
    if type(roster) ~= "table" or type(roster.guid) ~= "string" or roster.guid == "" then
        return nil
    end
    if expectedGuid and roster.guid ~= expectedGuid then
        return nil
    end
    return roster
end

--- Current shared Guild Info threshold, evaluated at observation admission.
-- Unknown policy, rank, or guild fails closed (no officer fast path).
local function ObserverQualifiesForOfficerCredit(rosterMember)
    if type(rosterMember) ~= "table" or type(rosterMember.rankOrder) ~= "number" then
        return false
    end
    local gossip = SF.GuildGossip
    local identity = gossip and gossip.GetGuildIdentity and gossip.GetGuildIdentity()
    if not identity or rosterMember.guildKey ~= identity.guildKey then
        return false
    end
    local GO = SF.GuildOfficer
    if not GO or type(GO.RankMeetsThreshold) ~= "function" then
        return false
    end
    local ranks = gossip.GetGuildRanks and gossip.GetGuildRanks()
    local rankCount = type(ranks) == "table" and tonumber(ranks.count) or nil
    return GO:RankMeetsThreshold(rosterMember.rankOrder, rankCount) and true or false
end

--- Admit one directly authenticated Guild Bank observation as a witness vote.
-- A qualifying officer's new local bank snapshot verifies immediately (#411).
-- Remote gs-evidence stays a witness. Relayed witness maps are not identity.
-- @param evidence table deposit evidence (SerializeEvidence shape)
-- @param admissionCtx { sender, member?, localWrite?, campaignId? }
-- @return status, reason, cluster|nil
function GS:AdmitDirectObservation(evidence, admissionCtx)
    admissionCtx = admissionCtx or {}
    local member = admissionCtx.member
    if not member then
        local m, mReason = GS.AuthenticateTransportSender(admissionCtx.sender)
        if not m then
            return "rejected", mReason or "unauthorized"
        end
        member = m
    end
    local witnessGuid = ValidGuid(member.guid)
    if not witnessGuid then
        return "pending", "sender_guid_unavailable"
    end

    local shapeOk, shapeErr, row = GS.ValidateEvidencePayload(evidence)
    if not shapeOk then
        return "rejected", shapeErr or "invalid_evidence"
    end

    local record, recReason
    if admissionCtx.offlineRecord then
        record = admissionCtx.offlineRecord
    else
        record, recReason = GS:GetCurrentRecord()
        if not record and member.guildKey then
            -- Remote path: resolve via guild key when local player differs.
            local root = GS._root
            record = root and root.guilds and root.guilds[member.guildKey]
            if record and not GS._ValidateGuildRecordForKey then
                -- fall through
            elseif record and GS.ValidateGuildRecord then
                -- use as-is; ValidateAndApply already gated dataset
            end
        end
    end
    if type(record) ~= "table" then
        return "pending", recReason or "awaiting_dataset"
    end
    -- Fail closed before any accounting dereference (guild meta / generation).
    local usable, usableErr = RequireUsableAccountingRecord(record)
    if not usable then
        return "rejected", usableErr or "invalid_record"
    end
    if record.datasetId and evidence.datasetId and evidence.datasetId ~= record.datasetId then
        return "rejected", "dataset_mismatch"
    end
    if member.guildKey and record then
        local cfgGuid = record.accounting and record.accounting._consumables
            and record.accounting._consumables.guild
            and tostring(record.accounting._consumables.guild.guid or "")
        local _, clubId = GS.ParseGuildKey(member.guildKey)
        if clubId and cfgGuid ~= "" and cfgGuid ~= clubId then
            return "rejected", "wrong_guild"
        end
    end

    local campaignId = admissionCtx.campaignId or row.campaignId or record.currentCampaignId
    if type(campaignId) ~= "string" or campaignId == "" then
        return "pending", "no_campaign"
    end
    row.campaignId = campaignId
    if tonumber(row.generation) == 0 then
        local cfg = record.accounting._consumables
        row.generation = tonumber(cfg and cfg.generation) or 0
    end

    -- Authenticated live cutover conflict: fail closed on production credits.
    -- Bank-snapshot admission may supply a one-shot cached probe for the same
    -- record/actor so a full log does not re-walk roster per row.
    if admissionCtx.liveWritesBlockedCached then
        if admissionCtx.liveWritesBlocked then
            return "pending", admissionCtx.liveWritesBlockReason or "live_activation_conflict"
        end
    elseif GS.LiveAccountingWritesBlocked then
        local blocked, blockReason = GS.LiveAccountingWritesBlocked(record, admissionCtx)
        if blocked then
            return "pending", blockReason or "live_activation_conflict"
        end
    end

    -- Live cutover: refuse pre-activation bank rows even if campaign eligibility
    -- was established earlier during staged development (#389).
    if GS.IsLiveActive and GS.IsLiveActive(record) and GS.IsEvidenceAfterLiveCutover then
        local afterOk, afterErr = GS.IsEvidenceAfterLiveCutover(record, row)
        if not afterOk then
            return "pending", afterErr or "not_eligible"
        end
    end

    local eligOk, eligErr = IsEvidenceEligible(record, row)
    local boundaryAmbiguous = (eligErr == "ambiguous_boundary"
        or eligErr == "missing_eligibility_context")
    if not eligOk and not boundaryAmbiguous then
        if eligErr == "not_eligible" or eligErr == "item_not_requested" then
            return "pending", eligErr
        end
        return "rejected", eligErr or "not_eligible"
    end

    -- Occurrence already credited → duplicate no-op (still record witness silently).
    local cfg = record.accounting._consumables
    local regHit, regHow = RegistryMatchOccurrence(cfg, row)
    if regHow == "ambiguous" then
        return "pending", "ambiguous"
    end
    if regHit and regHit.status == "verified" then
        return "duplicate", "duplicate"
    end
    local ledHit, ledHow = FindLedgerDonationOccurrence(record, row)
    if ledHow == "ambiguous" then
        return "pending", "ambiguous"
    end
    if ledHit then
        return "duplicate", "duplicate"
    end

    local camp, campErr = EnsureCampaignPending(record, campaignId)
    if not camp then
        return "rejected", campErr or "invalid_campaign"
    end
    local pending = camp.pending
    CompactVerifiedPending(pending)
    -- Near capacity: reclaim stale unfinished clusters before admitting new ones.
    local nearFull = UnfinishedPendingCount(pending)
        >= ((GS.MAX_PENDING_EVIDENCE or 128) - (GS.RESERVED_LOCAL_PENDING_EVIDENCE or 16))
        or CountTotalUnfinishedPending(record)
        >= ((GS.MAX_PENDING_EVIDENCE_TOTAL or 256) - (GS.RESERVED_LOCAL_PENDING_EVIDENCE or 16))
    if nearFull then
        if ReclaimStaleUnfinishedPending(pending, Now()) > 0 then
            BumpAccountingMutation(record)
        end
    end
    local match, how = AmbiguousBest(pending, row)
    if how == "ambiguous" then
        -- Relays/replays must not mint unlimited zero-witness ambiguous clusters.
        -- Local writers may retain one ambiguous cluster for recovery export only
        -- when capacity remains; never count the replay as a vote.
        if admissionCtx.localWrite or admissionCtx.exportEvidence then
            if select(1, CanOpenNewPendingCluster(record, pending, witnessGuid, admissionCtx)) then
                pending[#pending + 1] = {
                    schemaVersion = 1,
                    status = "ambiguous",
                    evidence = row,
                    witnesses = {},
                    firstSeen = Now(),
                    lastSeen = Now(),
                }
                BumpAccountingMutation(record)
            end
            GS.RecordDirectEvidenceExport(record, witnessGuid, row)
            if GS._NotifyLocalDurableChange then
                GS._NotifyLocalDurableChange("evidence")
            end
        end
        return "pending", "ambiguous"
    end

    local cluster = match
    if not cluster then
        local openOk, openErr = CanOpenNewPendingCluster(
            record, pending, witnessGuid, admissionCtx)
        if not openOk then
            -- Last-chance stale reclaim then retry capacity once.
            if ReclaimStaleUnfinishedPending(pending, Now()) > 0 then
                BumpAccountingMutation(record)
                openOk, openErr = CanOpenNewPendingCluster(
                    record, pending, witnessGuid, admissionCtx)
            end
        end
        if not openOk then
            return "rejected", openErr or "full"
        end
        cluster = {
            schemaVersion = 1,
            status = boundaryAmbiguous and "ambiguous" or "pending",
            evidence = row,
            witnesses = {},
            firstSeen = Now(),
            lastSeen = Now(),
        }
        pending[#pending + 1] = cluster
    else
        -- Refresh evidence fields conservatively (neighbors may strengthen).
        -- Boundary-spanning clusters stay ambiguous forever: Retail hour buckets
        -- and activation samples (count/status only, no per-txn identities) cannot
        -- prove the deposit occurred after cutover. Do not promote on age, a
        -- mutable reconcile flag, or a later MatchScore hit within TIME_TOLERANCE
        -- that claims a non-spanning approx (#389).
        cluster.lastSeen = Now()
        if cluster.status == "ambiguous" or boundaryAmbiguous then
            cluster.status = "ambiguous"
        end
        if type(cluster.evidence) == "table" and cluster.evidence ~= row then
            local older = cluster.evidence.neighborsOlder or {}
            local newer = cluster.evidence.neighborsNewer or {}
            if #(row.neighborsOlder or {}) > #older then
                cluster.evidence.neighborsOlder = row.neighborsOlder
            end
            if #(row.neighborsNewer or {}) > #newer then
                cluster.evidence.neighborsNewer = row.neighborsNewer
            end
            if cluster.status == "pending" then
                local prevAge = tonumber(cluster.evidence.ageHours)
                local newAge = tonumber(row.ageHours)
                if newAge and (not prevAge or newAge > prevAge) then
                    cluster.evidence.ageHours = row.ageHours
                    cluster.evidence.approxTxnTime = row.approxTxnTime
                    cluster.evidence.observedAt = row.observedAt
                end
            end
        end
    end

    if type(cluster.witnesses) ~= "table" then
        cluster.witnesses = {}
    end
    -- Rank is the authenticated roster at admission, not a stored witness claim.
    -- Promotion does not upgrade an old report until this character observes again.
    local rosterMember = FreshRosterMember(admissionCtx.sender or member.name, witnessGuid)
    -- Officer fast-path origination is a new local completed bank snapshot only.
    -- Remote gs-evidence and adoption replay stay ordinary witnesses. Accepted
    -- officer history reaches peers through gs-ledger-event, not by replaying
    -- an old vote after rank or threshold changes.
    local function TryOfficerCredit(requireNewerObservation)
        if admissionCtx.adoptionReplay or not admissionCtx.localWrite then
            return false
        end
        if cluster.status == "verified" or cluster.status == "ambiguous" then
            return false
        end
        if not ObserverQualifiesForOfficerCredit(rosterMember) then
            return false
        end
        if requireNewerObservation then
            local prior = cluster.witnesses[witnessGuid]
            if type(prior) == "table" then
                local incoming = tonumber(row.observedAt)
                local priorAt = tonumber(prior.observedAt)
                -- Same body as the witness already stored is not a new scan.
                if not incoming or not priorAt or incoming <= priorAt then
                    return false
                end
            end
        end
        local ok, err = CommitVerifiedCluster(record, cluster, witnessGuid,
            GS.VERIFICATION.OFFICER, { rankOrder = rosterMember.rankOrder })
        if not ok and (err == "ambiguous" or err == "ambiguous_boundary") then
            cluster.status = "ambiguous"
        end
        return cluster.status == "verified"
    end
    if GS.WitnessAlreadyCounted(record, cluster.witnesses, witnessGuid) then
        local creditedNow = false
        if cluster.status ~= "verified" and cluster.status ~= "ambiguous" then
            creditedNow = TryOfficerCredit(true)
            if not creditedNow and cluster.status ~= "ambiguous" then
                local n = GS.CountIndependentWitnesses(record, cluster.witnesses)
                if n >= (GS.WITNESS_THRESHOLD or 3) then
                    creditedNow = TryAutoVerify(record, cluster) and true or false
                end
            end
        end
        if creditedNow then
            if GS._NotifyLocalDurableChange then
                GS._NotifyLocalDurableChange("ledger")
            end
            return "accepted", nil, cluster
        end
        if cluster.status == "verified" then
            return "duplicate", "duplicate"
        end
        return "duplicate", "duplicate_witness"
    end

    local witnessCount = 0
    for _ in pairs(cluster.witnesses) do
        witnessCount = witnessCount + 1
    end
    if witnessCount >= (GS.MAX_WITNESSES_PER_CLUSTER or 16) then
        return "rejected", "full"
    end

    cluster.witnesses[witnessGuid] = {
        guid = witnessGuid,
        name = member.name,
        at = Now(),
        observedAt = row.observedAt,
    }
    -- Retained witness / pending evidence is local accounting work that adoption
    -- must not silently discard (stale-base pin uses _mutationSeq).
    BumpAccountingMutation(record)

    -- Only the originating observer exports this evidence body. Relays must not
    -- re-publish it under a different authenticated sender.
    if admissionCtx.localWrite or admissionCtx.exportEvidence then
        GS.RecordDirectEvidenceExport(record, witnessGuid, row)
    end

    local verified = false
    if cluster.status ~= "ambiguous" then
        verified = TryOfficerCredit(false)
        if not verified and cluster.status ~= "ambiguous" then
            verified = TryAutoVerify(record, cluster) and true or false
        end
    end
    if GS._NotifyLocalDurableChange then
        GS._NotifyLocalDurableChange(verified and "ledger" or "evidence")
    end
    if verified then
        return "accepted", nil, cluster
    end
    if cluster.status == "ambiguous" or boundaryAmbiguous then
        return "pending", "ambiguous_boundary", cluster
    end
    return "pending", "awaiting_witnesses", cluster
end

--- Cheap presence check for unfinished pending clusters (no verification work).
function GS.HasUnfinishedPendingEvidence(record)
    return CountTotalUnfinishedPending(record) > 0
end

--- Reevaluate unfinished evidence after Guild Info relationship changes
-- (or inert legacy link-op replay). Compaction may remove the current index;
-- do not skip the shifted cluster. Bounded by MAX_PENDING_EVIDENCE_TOTAL.
function GS.ReevaluatePendingEvidence(record)
    if type(record) ~= "table" or type(record.observations) ~= "table" then
        return 0
    end
    local byCampaign = record.observations.byCampaign
    if type(byCampaign) ~= "table" then return 0 end
    local verified = 0
    local guard = 0
    local maxGuard = (GS.MAX_PENDING_EVIDENCE_TOTAL or 256) + 8
    for _, camp in pairs(byCampaign) do
        if type(camp) == "table" and type(camp.pending) == "table" then
            local i = 1
            while i <= #camp.pending do
                guard = guard + 1
                if guard > maxGuard then
                    return verified
                end
                local cluster = camp.pending[i]
                local beforeLen = #camp.pending
                if type(cluster) == "table" and cluster.status ~= "verified" then
                    if TryAutoVerify(record, cluster) then
                        verified = verified + 1
                        -- CompactVerifiedPending shifts later entries into i.
                        if #camp.pending < beforeLen then
                            -- stay on i
                        else
                            i = i + 1
                        end
                    else
                        i = i + 1
                    end
                else
                    i = i + 1
                end
            end
        end
    end
    return verified
end

function GS:ListPendingEvidence(campaignId, limit)
    local record, reason = GS:GetCurrentRecord()
    if not record then
        return nil, reason or "not_ready"
    end
    campaignId = campaignId or record.currentCampaignId
    if type(campaignId) ~= "string" or campaignId == "" then
        return {}, nil
    end
    local camp = record.observations and record.observations.byCampaign
        and record.observations.byCampaign[campaignId]
    local pending = camp and camp.pending
    if type(pending) ~= "table" then
        return {}, nil
    end
    limit = math.floor(tonumber(limit) or 40)
    if limit < 0 then limit = 0 end
    if limit > 64 then limit = 64 end
    local rows = {}
    for i = 1, #pending do
        local c = pending[i]
        if type(c) == "table" and c.status ~= "verified" then
            rows[#rows + 1] = {
                status = c.status or "pending",
                witnessCount = GS.CountIndependentWitnesses(record, c.witnesses),
                threshold = GS.WITNESS_THRESHOLD or 3,
                donor = c.evidence and c.evidence.donor,
                itemId = c.evidence and c.evidence.itemId,
                quantity = c.evidence and c.evidence.quantity,
                firstSeen = c.firstSeen,
                lastSeen = c.lastSeen,
                txnId = c.txnId,
            }
            if #rows >= limit then break end
        end
    end
    return rows
end

---------------------------------------------------------------------------
-- Ledger event admission (donations / adjustments) with occurrence dedupe
---------------------------------------------------------------------------

function GS.ValidateLedgerEventBody(event, guildKey, datasetId)
    if type(event) ~= "table" then
        return false, "invalid_event"
    end
    local typ = event.type
    if typ == GS.LEDGER_EVENT.WITHDRAWAL or typ == "withdrawal" then
        if GS.ValidateWithdrawalEventBody then
            return GS.ValidateWithdrawalEventBody(event, datasetId)
        end
        return false, "unsupported_kind"
    end
    if typ ~= GS.LEDGER_EVENT.DONATION and typ ~= GS.LEDGER_EVENT.ADJUSTMENT
        and typ ~= "CONSUMABLE_DONATION" and typ ~= "CONSUMABLE_ADJUSTMENT" then
        return false, "invalid_kind"
    end
    -- Persisted accepted rows must carry event.id. Gossip ledger export upserts
    -- only when type(event.id)=="string"; accepting ValidTxnId(txnId) alone left
    -- SV rows advertised in acceptedLedgerCount but never exported.
    if type(event.id) ~= "string" or event.id == ""
        or #event.id > (GS.MAX_OPERATION_ID or 192) then
        return false, "invalid_id"
    end
    if datasetId and event.datasetId and event.datasetId ~= datasetId then
        return false, "dataset_mismatch"
    end
    if not IsItemId(tonumber(event.itemId)) then
        return false, "invalid_item"
    end
    local qty = tonumber(event.quantity)
    local isDonation = typ == GS.LEDGER_EVENT.DONATION or typ == "CONSUMABLE_DONATION"
    -- Donations: finite strictly positive integers only (FloorNonNeg must not
    -- convert authenticated negatives into zero-quantity accepted credits).
    -- Adjustments: signed nonzero integers within the existing max abs bound.
    if not qty or qty ~= qty or qty == math.huge or qty == -math.huge
        or qty ~= math.floor(qty) then
        return false, "invalid_quantity"
    end
    if isDonation then
        if qty < 1 then
            return false, "invalid_quantity"
        end
    elseif qty == 0 then
        return false, "invalid_quantity"
    end
    if math.abs(qty) > (GS.MAX_OBS_QUANTITY or 100000) then
        return false, "invalid_quantity"
    end
    if not GS.IsFiniteNonnegInt(event.timestamp) then
        return false, "invalid_event"
    end
    if not tonumber(event.generation) or tonumber(event.generation) < 1 then
        return false, "invalid_generation"
    end
    -- Optional create-time DBMarket unit snapshot on attributed adjustments (#447).
    -- Donation valuation admission is unchanged; this field is ledger-local.
    if event.unitCopper ~= nil then
        if isDonation then
            return false, "invalid_event"
        end
        if type(GS.NormalizeAdjustmentUnitCopper) ~= "function"
            or GS.NormalizeAdjustmentUnitCopper(event.unitCopper, qty) == nil then
            return false, "invalid_unit_copper"
        end
    end
    return true
end

--- Writer GUID for an officer-trusted accepted row. Payload rank is not read.
-- verifierGuid must be present and equal the writer. Absent provenance is not
-- synthesized from writer during catch-up or adoption.
local function OfficerHistoryWriter(event)
    if not IsCompleteOfficerHistoryEvent(event) then
        return nil
    end
    return ValidGuid(event.writer), ValidGuid(event.verifierGuid)
end

--- Drop the pending cluster and unverified candidates for one accepted occurrence.
-- Ambiguous clusters and non-matching deposits stay in place.
local function SettleAcceptedOfficerOccurrence(record, cfg, txnId, evidence)
    local changed = false
    local pendingCands = record.accounting and record.accounting._pendingDonationCandidates
    if type(pendingCands) == "table" then
        for candId, cand in pairs(pendingCands) do
            local clear = candId == txnId
            if not clear and type(cand) == "table" and ValidTxnId(candId) then
                clear = GS.EvidenceOccurrenceMatches(cand, evidence) and true or false
            end
            if clear then
                if candId ~= txnId and ValidTxnId(candId) then
                    AddTxnAlias(cfg, txnId, candId, record)
                end
                pendingCands[candId] = nil
                changed = true
            end
        end
    end
    local byCampaign = record.observations and record.observations.byCampaign
    if type(byCampaign) == "table" then
        for _, camp in pairs(byCampaign) do
            local pending = type(camp) == "table" and camp.pending
            if type(pending) == "table" then
                local marked = false
                for i = 1, #pending do
                    local cluster = pending[i]
                    if type(cluster) == "table"
                        and cluster.status ~= "verified"
                        and cluster.status ~= "ambiguous"
                        and GS.EvidenceOccurrenceMatches(cluster, evidence) then
                        cluster.status = "verified"
                        cluster.txnId = txnId
                        marked = true
                    end
                end
                if marked then
                    CompactVerifiedPending(pending)
                    changed = true
                end
            end
        end
    end
    if changed then
        BumpAccountingMutation(record)
    end
end

--- Non-mutating accepted officer-history preflight.
-- Shared by catch-up credit and competing-ID alias authorization so valuation
-- side effects cannot run when credit/provenance would refuse the same row.
-- Returns writer, verifier, validated evidence row, sourceMarker, authedMember
-- on success; otherwise nil. Does not mutate ledger, registry, or valuations.
local function OfficerTrustedHistoryPreflight(record, event, candidate, txnId, senderName, admissionCtx)
    local writer, verifier = OfficerHistoryWriter(event)
    if not writer or not verifier or not ValidTxnId(txnId) or type(candidate) ~= "table" then
        return nil
    end
    if type(GS.AuthenticateTransportSender) ~= "function" then
        return nil
    end
    local authed = GS.AuthenticateTransportSender(senderName)
    if type(authed) ~= "table" or not ValidGuid(authed.guid) then
        return nil
    end
    local gossip = SF.GuildGossip
    local identity = gossip and gossip.GetGuildIdentity and gossip.GetGuildIdentity()
    if not identity or authed.guildKey ~= identity.guildKey then
        return nil
    end
    local shapeOk, _, row = GS.ValidateEvidencePayload({
        donor = candidate.donor or candidate.actor,
        itemId = candidate.itemId,
        quantity = candidate.quantity,
        guildGuid = candidate.guildGuid,
        bankTab = candidate.bankTab,
        generation = candidate.generation,
        approxTxnTime = candidate.approxTxnTime or candidate.timestamp,
        ageHours = event.ageHours,
        coreSignature = candidate.coreSignature,
        occurrenceIndex = candidate.occurrenceIndex,
        neighborsOlder = candidate.neighborsOlder,
        neighborsNewer = candidate.neighborsNewer,
        observedAt = candidate.timestamp,
        campaignId = candidate.campaignId,
    })
    if not shapeOk or type(row) ~= "table" or tonumber(row.ageHours) == nil then
        return nil
    end
    local sourceMarker = nil
    if type(admissionCtx) == "table"
        and type(admissionCtx.sourceCutoverMarker) == "string"
        and admissionCtx.sourceCutoverMarker ~= "" then
        sourceMarker = admissionCtx.sourceCutoverMarker
    end
    -- Live credit requires the installed canonical marker. A post-boundary
    -- timestamp alone must not promote relayed officer history. Staged peers
    -- retain a presented marker so a later remote install can classify it;
    -- they do not require one, and an absent marker cannot be promoted later.
    if GS.IsLiveActive and GS.IsLiveActive(record) then
        local liveMarker = type(record.liveCutover) == "table"
            and record.liveCutover.cutoverMarker or nil
        if type(sourceMarker) ~= "string" or type(liveMarker) ~= "string"
            or sourceMarker ~= liveMarker then
            return nil
        end
        if GS.IsEvidenceAfterLiveCutover then
            local afterOk = select(1, GS.IsEvidenceAfterLiveCutover(record, row))
            if not afterOk then
                return nil
            end
        end
    end
    if not IsEvidenceEligible(record, row) then
        return nil
    end
    return writer, verifier, row, sourceMarker, authed
end

--- Ordinary Guild Gossip catch-up of an already accepted officer-trusted donation.
-- The transport sender must be an authenticated same-guild member. The verification
-- field, writer, rank, or isAdmin claim is not authority by itself: occurrence,
-- eligibility, dataset, an explicit verifierGuid, and (when live) the canonical
-- cutover marker are required. v1 cannot prove the named writer saw Blizzard's
-- bank log. That limit is documented in GuildSupplies/AGENTS.md. Returns nil when
-- the row must stay an unverified candidate.
local function TryAdmitOfficerTrustedHistory(record, event, candidate, txnId, cfg, senderName, admissionCtx)
    if type(cfg) ~= "table" then
        return nil
    end
    local writer, verifier, row, sourceMarker, authed = OfficerTrustedHistoryPreflight(
        record, event, candidate, txnId, senderName, admissionCtx)
    if not writer or not verifier or type(row) ~= "table" then
        return nil
    end
    local stored = {
        type = GS.LEDGER_EVENT.DONATION,
        id = txnId,
        txnId = txnId,
        generation = tonumber(row.generation),
        timestamp = tonumber(row.approxTxnTime) or Now(),
        actor = row.donor,
        itemId = row.itemId,
        quantity = row.quantity,
        source = "guildbank",
        writer = writer,
        verifierGuid = verifier,
        verification = GS.VERIFICATION.OFFICER,
        coreSignature = row.coreSignature,
        occurrenceIndex = row.occurrenceIndex,
        guildGuid = row.guildGuid,
        bankTab = row.bankTab,
        neighborsOlder = row.neighborsOlder,
        neighborsNewer = row.neighborsNewer,
        campaignId = row.campaignId or candidate.campaignId or record.currentCampaignId,
        datasetId = record.datasetId,
        ageHours = tonumber(row.ageHours),
    }
    do
        local claimed = ValidGuid(event.actorGuid) or ValidGuid(event.donorGuid)
            or ValidGuid(candidate.actorGuid) or ValidGuid(candidate.donorGuid)
        local _, donorGuid = GS.ResolveDonorIdentity(record, row.donor, claimed)
        if donorGuid then
            stored.actorGuid = donorGuid
        end
    end
    if sourceMarker then
        stored.gsSourceCutoverMarker = sourceMarker
    end
    local rankSnap = tonumber(event.verifierRankOrder)
    if rankSnap and rankSnap >= 1 and rankSnap <= 20 and rankSnap == math.floor(rankSnap) then
        stored.verifierRankOrder = rankSnap
    end
    local appendOk = AppendLedgerEvent(record, stored)
    if not appendOk then
        return nil
    end
    RegisterTxn(cfg, {
        txnId = txnId,
        status = "verified",
        committed = true,
        coreSignature = stored.coreSignature,
        approxTxnTime = stored.timestamp,
        donor = stored.actor,
        itemId = stored.itemId,
        quantity = stored.quantity,
        guildGuid = stored.guildGuid,
        bankTab = stored.bankTab,
        generation = stored.generation,
        occurrenceIndex = stored.occurrenceIndex,
        neighborsOlder = stored.neighborsOlder,
        neighborsNewer = stored.neighborsNewer,
        verification = stored.verification,
        decidedBy = writer,
    })
    SettleAcceptedOfficerOccurrence(record, cfg, txnId, row)
    if GS._NotifyLocalDurableChange then
        GS._NotifyLocalDurableChange("ledger")
    end
    Debug("Info", "officer-trusted history accepted txn=%s writer=%s sender=%s",
        tostring(txnId), tostring(writer), tostring(authed and authed.name or senderName))
    if GS.ReconcilePendingValuations then
        GS.ReconcilePendingValuations(record, txnId, stored)
    end
    if GS.TryAssignDonationValuation then
        GS.TryAssignDonationValuation(record, stored, row)
    end
    return "accepted", "officer_history"
end

--- Admit an already-minted ledger event (gossip catch-up). Occurrence-aware dedupe.
function GS:AdmitLedgerEvent(event, admissionCtx)
    admissionCtx = admissionCtx or {}
    local member = admissionCtx.member
    if not member and admissionCtx.sender then
        local m, mReason = GS.AuthenticateTransportSender(admissionCtx.sender)
        if not m then
            return "rejected", mReason or "unauthorized"
        end
        member = m
    end

    local record = admissionCtx.offlineRecord
    if not record then
        record = select(1, GS:GetCurrentRecord())
        if not record and member and member.guildKey and GS._root and GS._root.guilds then
            record = GS._root.guilds[member.guildKey]
        end
    end
    if type(record) ~= "table" then
        return "pending", "awaiting_dataset"
    end
    local usable, usableErr = RequireUsableAccountingRecord(record)
    if not usable then
        return "rejected", usableErr or "invalid_record"
    end
    if event.datasetId and event.datasetId ~= record.datasetId then
        return "rejected", "dataset_mismatch"
    end

    -- #457 informational withdrawals: separate admission path (no editor gate,
    -- no donation credit). Still requires authenticated same-guild membership.
    if event.type == GS.LEDGER_EVENT.WITHDRAWAL or event.type == "withdrawal" then
        if not GS.AdmitWithdrawalEvent then
            return "rejected", "unsupported_kind"
        end
        local senderGuid = member and member.guid
            or (admissionCtx.sender and tostring(admissionCtx.sender))
        -- Informational trust: same-guild authenticated relay is allowed; actor
        -- mismatch is relabeled RELAY inside AdmitWithdrawalEvent (not ORIGIN).
        -- Pass adoptionReplay so temporary offline adoption writes do not
        -- notify/update the live export index before atomic publish.
        return GS.AdmitWithdrawalEvent(record, event, {
            senderGuid = senderGuid,
            memberAuthenticated = member ~= nil,
            allowRelayOfOrigin = true,
            adoptionReplay = admissionCtx.adoptionReplay == true,
        })
    end

    -- Authenticated live cutover conflict blocks unsafe canonical writes.
    if GS.LiveAccountingWritesBlocked then
        local blocked, blockReason = GS.LiveAccountingWritesBlocked(record, admissionCtx)
        if blocked then
            return "pending", blockReason or "live_activation_conflict"
        end
    end

    local ok, err = GS.ValidateLedgerEventBody(event, nil, record.datasetId)
    if not ok then
        return "rejected", err or "invalid_event"
    end

    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" then
        return "rejected", "invalid_accounting"
    end

    local txnId = ValidTxnId(event.txnId) or event.id
    txnId = ValidTxnId(txnId) or txnId

    local isDonation = event.type == GS.LEDGER_EVENT.DONATION or event.type == "CONSUMABLE_DONATION"
    local isAdjustment = event.type == GS.LEDGER_EVENT.ADJUSTMENT or event.type == "CONSUMABLE_ADJUSTMENT"

    -- Adjustment idempotency uses the original operation id when present.
    local adjustmentEventId = nil
    if isAdjustment then
        if type(event.opId) == "string" and event.opId ~= "" then
            adjustmentEventId = event.opId
        elseif type(event.id) == "string" and event.id ~= "" then
            adjustmentEventId = event.id
        end
        -- Authenticate editor rank before any durable quarantine writes.
        if not admissionCtx.preserveAttribution and not admissionCtx.localWrite then
            local editorOk, editorReason = GS.SenderHasEditorAuthority(member, {})
            if not editorOk then
                return "pending", editorReason or "untrusted_relay"
            end
        end
    end

    -- Exact ID duplicate for non-donation kinds. Adjustments require exact
    -- immutable-body equivalence; divergent same-ID bodies quarantine.
    -- Live list is always searched. Adoption also searches the archive so
    -- transferred history is idempotent. Ordinary gossip additionally searches
    -- the archive for adjustments only so an already-retained shelved row can
    -- still receive nil→priced enrichment after op-first → rollover (#447);
    -- genuinely new stale-campaign/generation ids fall through to rejection.
    if not isDonation then
        local lists = {
            record.accounting._consumableEvents,
        }
        if admissionCtx.adoptionReplay or isAdjustment then
            lists[#lists + 1] = record.accounting._consumableEventArchive
        end
        for li = 1, #lists do
            local events = lists[li]
            if type(events) == "table" then
                for i = 1, #events do
                    local e = events[i]
                    if type(e) == "table" then
                        local idHit = (e.id == txnId or e.txnId == txnId)
                            or (adjustmentEventId
                                and (e.id == adjustmentEventId or e.opId == adjustmentEventId))
                        if idHit then
                            if isAdjustment then
                                if AdjustmentBodiesEquivalent(e, event) then
                                    -- Rejectable duplicate fields first: a conflicting
                                    -- price may quarantine, but must not mutate accepted
                                    -- price/attribution/cutover/credit or the export (#447).
                                    if AdjustmentUnitCopperConflicts(e, event) then
                                        QuarantineConflictBody(
                                            cfg, adjustmentEventId or txnId, event)
                                        return "rejected", "id_conflict"
                                    end
                                    -- Allowed enrichment against the retained row, then
                                    -- one export refresh from the final accepted state.
                                    local exportRelevant = false
                                    if ReconcileAdjustmentCutoverProvenance(
                                        record, e, admissionCtx) then
                                        exportRelevant = true
                                    end
                                    if ReconcileAdjustmentAttributedGuid(record, e, event) then
                                        exportRelevant = true
                                    end
                                    if GS.ReconcileAdjustmentUnitCopper then
                                        local enriched, enrichErr =
                                            GS.ReconcileAdjustmentUnitCopper(e, event)
                                        if enrichErr == "price_conflict" then
                                            -- Defense in depth; probe above should catch.
                                            QuarantineConflictBody(
                                                cfg, adjustmentEventId or txnId, event)
                                            return "rejected", "id_conflict"
                                        end
                                        if enriched then
                                            BumpAccountingMutation(record)
                                            exportRelevant = true
                                        end
                                    end
                                    if exportRelevant then
                                        if GS.RefreshLedgerEventExport then
                                            GS.RefreshLedgerEventExport(record, e)
                                        elseif GS._NotifyLocalDurableChange then
                                            GS._NotifyLocalDurableChange("ledger")
                                        end
                                    end
                                    return "duplicate", "duplicate"
                                end
                                QuarantineConflictBody(cfg, adjustmentEventId or txnId, event)
                                return "rejected", "id_conflict"
                            end
                            return "duplicate", "duplicate"
                        end
                    end
                end
            end
        end
        local aliasHit = FindRegistryByTxn(cfg, txnId)
        if aliasHit and (aliasHit.status == "verified" or aliasHit.status == "alias") then
            return "duplicate", "duplicate"
        end
    end

    if isDonation then
        -- Live gossip: catch-up candidates only (no invented quorum).
        -- Authenticated dataset adoption may transfer source-accepted donations
        -- with preserveAttribution without bypassing live witness rules.
        local candidate = {
            type = GS.LEDGER_EVENT.DONATION,
            id = txnId,
            txnId = txnId,
            generation = tonumber(event.generation),
            timestamp = tonumber(event.timestamp) or Now(),
            actor = NormName(event.actor or event.donor),
            itemId = tonumber(event.itemId),
            quantity = FloorNonNeg(event.quantity),
            source = "guildbank",
            writer = ValidGuid(event.writer) or (member and member.guid) or "remote",
            verification = event.verification, -- retained for diagnostics; not authority
            coreSignature = event.coreSignature,
            occurrenceIndex = event.occurrenceIndex,
            guildGuid = event.guildGuid,
            bankTab = event.bankTab,
            neighborsOlder = CopyStringList(event.neighborsOlder, 3),
            neighborsNewer = CopyStringList(event.neighborsNewer, 3),
            campaignId = event.campaignId or record.currentCampaignId,
            datasetId = record.datasetId,
            approxTxnTime = tonumber(event.timestamp) or tonumber(event.approxTxnTime),
            donor = NormName(event.actor or event.donor),
        }
        do
            local claimed = ValidGuid(event.actorGuid) or ValidGuid(event.donorGuid)
            local _, donorGuid = GS.ResolveDonorIdentity(
                record, candidate.actor or candidate.donor, claimed)
            if donorGuid then
                candidate.actorGuid = donorGuid
            end
        end

        -- Exact fingerprint ID may be shared by temporally distinct deposits.
        -- Only treat as duplicate when MatchScore agrees; otherwise remint the
        -- candidate identity (distinct) or hold ambiguous (uncertain).
        local existingReg = FindRegistryByTxn(cfg, txnId)
        if existingReg and existingReg.status == "verified" then
            local relation = ExactIdOccurrenceRelation(existingReg, candidate)
            if relation == "same" then
                if DonationBodiesConflict(existingReg, candidate) then
                    QuarantineConflictBody(cfg, txnId, candidate)
                    return "rejected", "id_conflict"
                end
                local led = FindLedgerEventByTxnId(record, txnId)
                if led then
                    ReconcileVerifiedDonationDuplicate(
                        record, led, candidate, admissionCtx, event)
                end
                return "duplicate", "duplicate"
            elseif relation == "distinct" then
                local reminted = AllocateCollisionRemintTxnId(
                    record, candidate.writer or (member and member.guid))
                if not ValidTxnId(reminted) then
                    return "pending", "ambiguous"
                end
                candidate.id = reminted
                candidate.txnId = reminted
                txnId = reminted
            else
                return "pending", "ambiguous"
            end
        elseif existingReg and existingReg.status == "alias" then
            local relation = ExactIdOccurrenceRelation(existingReg, candidate)
            if relation == "same" then
                local primaryId = ValidTxnId(existingReg.aliasOf) or txnId
                local led = FindLedgerEventByTxnId(record, primaryId)
                if led then
                    ReconcileVerifiedDonationDuplicate(
                        record, led, candidate, admissionCtx, event)
                end
                return "duplicate", "duplicate"
            elseif relation == "distinct" then
                local reminted = AllocateCollisionRemintTxnId(
                    record, candidate.writer or (member and member.guid))
                if not ValidTxnId(reminted) then
                    return "pending", "ambiguous"
                end
                candidate.id = reminted
                candidate.txnId = reminted
                txnId = reminted
            else
                return "pending", "ambiguous"
            end
        end

        -- Pending candidate with same ID: conflict, officer-history upgrade, or remint.
        -- An unverified candidate is not a terminal duplicate. A later valid
        -- officer-trusted row for that occurrence may still be admitted once.
        local pendingCands = EnsurePendingDonationCandidates(record)
        local priorCand = pendingCands and pendingCands[txnId]
        if type(priorCand) == "table" then
            local relation = ExactIdOccurrenceRelation(priorCand, candidate)
            if relation == "same" then
                if DonationBodiesConflict(priorCand, candidate) then
                    QuarantineConflictBody(cfg, txnId, candidate)
                    return "rejected", "id_conflict"
                end
                local histStatus, histReason = TryAdmitOfficerTrustedHistory(
                    record, event, candidate, txnId, cfg, admissionCtx.sender, admissionCtx)
                if histStatus then
                    return histStatus, histReason
                end
                return "duplicate", "duplicate"
            elseif relation == "distinct" then
                local reminted = AllocateCollisionRemintTxnId(
                    record, candidate.writer or (member and member.guid))
                if not ValidTxnId(reminted) then
                    return "pending", "ambiguous"
                end
                candidate.id = reminted
                candidate.txnId = reminted
                txnId = reminted
            else
                return "pending", "ambiguous"
            end
        end

        if type(candidate.coreSignature) == "string" and candidate.coreSignature ~= "" then
            local regHit, regHow = RegistryMatchOccurrence(cfg, candidate)
            if regHow == "ambiguous" then
                return "pending", "ambiguous"
            end
            if regHit and ValidTxnId(regHit.txnId) and regHit.txnId ~= txnId then
                -- Same occurrence, competing ID: alias without second credit.
                -- Only officer-history that would pass catch-up credit preflight
                -- (live canonical marker + eligibility) may create A→X aliases
                -- that move valuation state. Shape-only officer claims with a
                -- missing/divergent marker must not redirect pending[X].
                if regHit.status == "verified" then
                    if OfficerTrustedHistoryPreflight(
                        record, event, candidate, txnId, admissionCtx.sender, admissionCtx) then
                        -- Pass the accepted primary donation so cold-index alias
                        -- reconcile can promote pending[X] without redelivery.
                        local led = FindLedgerEventByTxnId(record, regHit.txnId)
                        AddTxnAlias(cfg, regHit.txnId, txnId, record, led)
                        if led then
                            ReconcileVerifiedDonationDuplicate(
                                record, led, candidate, admissionCtx, event)
                        end
                    end
                    return "duplicate", "occurrence_duplicate"
                end
            end
            local ledHit, ledHow = FindLedgerDonationOccurrence(record, candidate)
            if ledHow == "ambiguous" then
                return "pending", "ambiguous"
            end
            if ledHit and (ledHit.txnId or ledHit.id) ~= txnId then
                if OfficerTrustedHistoryPreflight(
                    record, event, candidate, txnId, admissionCtx.sender, admissionCtx) then
                    AddTxnAlias(cfg, ledHit.txnId or ledHit.id, txnId, record, ledHit)
                    ReconcileVerifiedDonationDuplicate(
                        record, ledHit, candidate, admissionCtx, event)
                end
                return "duplicate", "occurrence_duplicate"
            end
            if ledHit and (ledHit.txnId or ledHit.id) == txnId then
                local relation = ExactIdOccurrenceRelation({
                    coreSignature = ledHit.coreSignature,
                    guildGuid = ledHit.guildGuid,
                    bankTab = ledHit.bankTab,
                    generation = ledHit.generation,
                    approxTxnTime = ledHit.timestamp or ledHit.approxTxnTime,
                    occurrenceIndex = ledHit.occurrenceIndex,
                    neighborsOlder = ledHit.neighborsOlder,
                    neighborsNewer = ledHit.neighborsNewer,
                    status = "verified",
                }, candidate)
                if relation == "same" then
                    if DonationBodiesConflict(ledHit, candidate) then
                        QuarantineConflictBody(cfg, txnId, candidate)
                        return "rejected", "id_conflict"
                    end
                    ReconcileVerifiedDonationDuplicate(
                        record, ledHit, candidate, admissionCtx, event)
                    return "duplicate", "duplicate"
                elseif relation == "distinct" then
                    local reminted = AllocateCollisionRemintTxnId(
                        record, candidate.writer or (member and member.guid))
                    if not ValidTxnId(reminted) then
                        return "pending", "ambiguous"
                    end
                    candidate.id = reminted
                    candidate.txnId = reminted
                    txnId = reminted
                else
                    return "pending", "ambiguous"
                end
            end
        end

        -- Authenticated adoption transfers source-accepted donations into the
        -- temporary record. Live gossip never takes this branch.
        if admissionCtx.adoptionReplay and admissionCtx.preserveAttribution then
            -- Resolve campaign/header/archive generation before preserving.
            -- Missing archive context waits (out-of-order transfer); wrong
            -- generation fails closed so projections cannot misattribute.
            local campId = candidate.campaignId
            if type(campId) ~= "string" or campId == "" then
                return "rejected", "invalid_campaign"
            end
            local campCtx, campErr = ResolveEvidenceCampaignContext(record, candidate)
            if not campCtx then
                if campErr == "missing_campaign_archive" then
                    return "pending", "awaiting_campaign_context"
                end
                return "rejected", campErr or "invalid_campaign"
            end
            if tonumber(candidate.generation) ~= tonumber(campCtx.generation) then
                return "rejected", "generation_mismatch"
            end
            local writerGuid = ValidGuid(candidate.writer)
            local explicitVerifier = ValidGuid(event.verifierGuid)
            local officerComplete = event.verification == GS.VERIFICATION.OFFICER
                and writerGuid and explicitVerifier and explicitVerifier == writerGuid
            local stored = {
                type = GS.LEDGER_EVENT.DONATION,
                id = txnId,
                txnId = txnId,
                generation = tonumber(candidate.generation),
                timestamp = tonumber(candidate.timestamp) or Now(),
                actor = candidate.actor,
                itemId = candidate.itemId,
                quantity = candidate.quantity,
                source = "guildbank",
                writer = candidate.writer,
                verification = officerComplete and GS.VERIFICATION.OFFICER
                    or GS.VERIFICATION.WITNESSES,
                coreSignature = candidate.coreSignature,
                occurrenceIndex = candidate.occurrenceIndex,
                guildGuid = candidate.guildGuid,
                bankTab = candidate.bankTab,
                neighborsOlder = candidate.neighborsOlder,
                neighborsNewer = candidate.neighborsNewer,
                campaignId = campId,
                datasetId = record.datasetId,
                ageHours = tonumber(event.ageHours),
            }
            do
                local claimed = ValidGuid(candidate.actorGuid) or ValidGuid(candidate.donorGuid)
                    or ValidGuid(event.actorGuid) or ValidGuid(event.donorGuid)
                local _, donorGuid = GS.ResolveDonorIdentity(
                    record, candidate.actor or candidate.donor, claimed)
                if donorGuid then
                    stored.actorGuid = donorGuid
                end
            end
            if officerComplete then
                stored.verifierGuid = explicitVerifier
                local rankSnap = tonumber(event.verifierRankOrder)
                if rankSnap and rankSnap >= 1 and rankSnap <= 20
                    and rankSnap == math.floor(rankSnap) then
                    stored.verifierRankOrder = rankSnap
                end
            end
            if type(admissionCtx.sourceCutoverMarker) == "string"
                and admissionCtx.sourceCutoverMarker ~= "" then
                stored.gsSourceCutoverMarker = admissionCtx.sourceCutoverMarker
            end
            local appendOk, appendErr = AppendLedgerEvent(record, stored)
            if not appendOk then
                return "rejected", appendErr or "full"
            end
            RegisterTxn(cfg, {
                txnId = txnId,
                status = "verified",
                committed = true,
                coreSignature = stored.coreSignature,
                approxTxnTime = stored.timestamp,
                donor = stored.actor,
                itemId = stored.itemId,
                quantity = stored.quantity,
                guildGuid = stored.guildGuid,
                bankTab = stored.bankTab,
                generation = stored.generation,
                occurrenceIndex = stored.occurrenceIndex,
                neighborsOlder = stored.neighborsOlder,
                neighborsNewer = stored.neighborsNewer,
                verification = stored.verification,
            })
            if GS.ReconcilePendingValuations then
                GS.ReconcilePendingValuations(record, txnId, stored)
            end
            return "accepted", "adoption_transfer"
        end

        -- Accepted officer-trusted history may propagate through any authenticated
        -- guildmate. Incomplete or ineligible officer claims stay candidates.
        local histStatus, histReason = TryAdmitOfficerTrustedHistory(
            record, event, candidate, txnId, cfg, admissionCtx.sender, admissionCtx)
        if histStatus then
            return histStatus, histReason
        end

        -- Retain as unverified candidate for ID convergence; do not credit.
        if type(pendingCands) ~= "table" then
            return "rejected", "invalid_accounting"
        end
        local candCount = 0
        for _ in pairs(pendingCands) do
            candCount = candCount + 1
        end
        if candCount >= (GS.MAX_PENDING_DONATION_CANDIDATES or 256) then
            return "rejected", "full"
        end
        pendingCands[txnId] = candidate
        return "accepted", "awaiting_local_quorum"
    end

    if isAdjustment then
        -- Editor authority already checked before duplicate/quarantine writes.
        local eventCampaign = event.campaignId or record.currentCampaignId
        if type(eventCampaign) ~= "string" or eventCampaign == "" then
            return "rejected", "invalid_campaign"
        end
        local eventGen = tonumber(event.generation)
        local curGen = tonumber(cfg.generation)
        local attributed, attrGuid, attrErr = GS.ResolveAttributedIdentity(
            record, event.attributed, event.attributedGuid)
        if attrErr then
            return "rejected", attrErr
        end
        local qty = tonumber(event.quantity)
        local historicalAdoption = admissionCtx.adoptionReplay
            and admissionCtx.preserveAttribution
            and eventCampaign ~= record.currentCampaignId
        if historicalAdoption then
            -- Authenticated source adoption restores original accepted history
            -- (including archived-campaign adjustments) without live floor replay.
            local archive = record.campaignArchives and record.campaignArchives[eventCampaign]
            if type(archive) ~= "table" then
                return "rejected", "stale_campaign"
            end
            if eventGen and tonumber(archive.generation) and eventGen ~= tonumber(archive.generation) then
                return "rejected", "stale_generation"
            end
        else
            -- Live gossip/local writes: reject foreign campaign/generation packets.
            if eventCampaign ~= record.currentCampaignId then
                return "rejected", "stale_campaign"
            end
            if eventGen and curGen and eventGen ~= curGen then
                return "rejected", "stale_generation"
            end
            -- Floor and stored GUID share one authenticated attributed identity.
            local floorOk, floorErr = GS.AdjustmentFloorOk(
                record, tonumber(event.itemId), qty, attributed, eventCampaign,
                { attributedGuid = attrGuid })
            if not floorOk then
                return "pending", floorErr or "adjustment_floor"
            end
        end
        local eventId = adjustmentEventId or txnId
        local stored = {
            type = GS.LEDGER_EVENT.ADJUSTMENT,
            id = eventId,
            txnId = ValidTxnId(event.txnId) or eventId,
            opId = (type(event.opId) == "string" and event.opId) or eventId,
            generation = eventGen or curGen,
            timestamp = tonumber(event.timestamp) or Now(),
            actor = NormName(event.actor) or (member and member.name),
            writer = ValidGuid(event.writer) or (member and member.guid),
            itemId = tonumber(event.itemId),
            quantity = qty,
            attributed = attributed,
            campaignId = eventCampaign,
            datasetId = record.datasetId,
        }
        if attrGuid then
            stored.attributedGuid = attrGuid
        end
        -- Retain create-time DBMarket unit snapshot when present and attributed (#447).
        if attributed and event.unitCopper ~= nil
            and GS.NormalizeAdjustmentUnitCopper then
            local unit = GS.NormalizeAdjustmentUnitCopper(event.unitCopper, qty)
            if unit ~= nil then
                stored.unitCopper = unit
            end
        end
        -- Authenticated active-exporter marker from transport body (never the
        -- self-declared event field). When already live, only the matching
        -- canonical marker is retained; divergent markers stay fail-closed.
        if type(admissionCtx.sourceCutoverMarker) == "string"
            and admissionCtx.sourceCutoverMarker ~= "" then
            local liveMarker = record.liveCutover and record.liveCutover.cutoverMarker
            if not (GS.IsLiveActive and GS.IsLiveActive(record))
                or liveMarker == admissionCtx.sourceCutoverMarker then
                stored.gsSourceCutoverMarker = admissionCtx.sourceCutoverMarker
            end
        end
        local appendOk, appendErr = AppendLedgerEvent(record, stored)
        if not appendOk then
            return "rejected", appendErr or "full"
        end
        if GS._NotifyLocalDurableChange and not admissionCtx.adoptionReplay then
            GS._NotifyLocalDurableChange("ledger")
        end
        return "accepted"
    end

    return "rejected", "invalid_kind"
end

---------------------------------------------------------------------------
-- Adjustment floor + staged local API
---------------------------------------------------------------------------

local function ProgressOnRecord(record, campaignId)
    campaignId = campaignId or (record and record.currentCampaignId)
    if GS.ProjectCampaignProgressOnRecord then
        return GS.ProjectCampaignProgressOnRecord(record, campaignId)
    end
    return GS:ProjectCampaignProgress(campaignId)
end

local function ActorItemTotal(record, actorName, itemId, campaignId)
    local progress = ProgressOnRecord(record, campaignId)
    if not progress then return 0 end
    -- Floors use the same projected contributor key as progress totals (#427).
    local key = actorName
    if GS.ResolveDisplayContributor then
        key = select(1, GS.ResolveDisplayContributor(record, actorName, nil)) or actorName
    end
    local contrib = progress.contributions and progress.contributions[key]
    return (contrib and tonumber(contrib[itemId])) or 0
end

local function ItemTotal(record, itemId, campaignId)
    local progress = ProgressOnRecord(record, campaignId)
    if not progress then return 0 end
    return tonumber(progress.itemTotals and progress.itemTotals[itemId]) or 0
end

--- Strict signed-integer parse for Settings quantity input (#426).
-- Accepts "10" and "-10". Rejects "+10", zero, decimals, whitespace-only,
-- non-integers, and magnitudes above MAX_OBS_QUANTITY. Does not round.
-- @return number|nil quantity, string|nil err
function GS.ParseAdjustmentQuantity(text)
    if type(text) ~= "string" then
        return nil, "invalid_quantity"
    end
    local trimmed = text:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then
        return nil, "invalid_quantity"
    end
    -- Explicit leading '+' is rejected even though tonumber would accept it.
    if trimmed:sub(1, 1) == "+" then
        return nil, "invalid_quantity"
    end
    local whole = trimmed:match("^(%-?%d+)$")
    if not whole then
        return nil, "invalid_quantity"
    end
    local quantity = tonumber(whole)
    if not quantity or quantity ~= quantity or quantity ~= math.floor(quantity) or quantity == 0 then
        return nil, "invalid_quantity"
    end
    if math.abs(quantity) > (GS.MAX_OBS_QUANTITY or 100000) then
        return nil, "invalid_quantity"
    end
    return quantity
end

--- True when itemId is a configured requested item on the current campaign.
function GS.IsCurrentRequestedItem(record, itemId)
    itemId = tonumber(itemId)
    if not IsItemId(itemId) or type(record) ~= "table" then
        return false
    end
    if type(record.currentCampaignId) ~= "string" or record.currentCampaignId == "" then
        return false
    end
    local items = record.accounting and record.accounting._consumables
        and record.accounting._consumables.requestedItems
    if type(items) ~= "table" then
        return false
    end
    local row = items[tostring(itemId)]
    return type(row) == "table" and tonumber(row.itemId) == itemId
end

local function CurrentItemGoal(record, itemId)
    local items = record and record.accounting and record.accounting._consumables
        and record.accounting._consumables.requestedItems
    if type(items) ~= "table" then
        return nil
    end
    local row = items[tostring(itemId)]
    if type(row) ~= "table" then
        return nil
    end
    local goal = tonumber(row.goal)
    if not goal or goal ~= goal or goal ~= math.floor(goal) or goal < 0 then
        return nil
    end
    return goal
end

--- Floor (and optional positive-goal ceiling) against accepted projection.
-- Negative corrections of an already over-goal total remain allowed subject to
-- existing floors. The goal ceiling is opt-in via opts.enforceGoalCeiling and is
-- intended for new local preparation/commit only. Authenticated remote replay of
-- previously accepted adjustments must not pass that flag: a peer that receives
-- a later donation or lowered goal before the earlier adjustment would otherwise
-- diverge permanently (#426 / #430).
-- @param campaignId optional; defaults to record.currentCampaignId. Callers that
--   cannot prove historical campaign provenance should reject before calling.
-- @param opts optional { enforceGoalCeiling = boolean }
function GS.AdjustmentFloorOk(record, itemId, quantity, attributed, campaignId, opts)
    itemId = tonumber(itemId)
    quantity = tonumber(quantity)
    if not IsItemId(itemId) then
        return false, "invalid_item"
    end
    if not quantity or quantity ~= quantity or quantity ~= math.floor(quantity) or quantity == 0 then
        return false, "invalid_quantity"
    end
    if math.abs(quantity) > (GS.MAX_OBS_QUANTITY or 100000) then
        return false, "invalid_quantity"
    end
    if attributed ~= nil and attributed ~= "" then
        attributed = NormName(attributed)
        if not attributed then
            return false, "invalid_attribution"
        end
    else
        attributed = nil
    end
    if not record then
        return false, "no_campaign"
    end
    campaignId = campaignId or record.currentCampaignId
    if type(campaignId) ~= "string" or campaignId == "" then
        return false, "no_campaign"
    end
    if campaignId ~= record.currentCampaignId then
        return false, "stale_campaign"
    end
    opts = opts or {}
    local currentItem = ItemTotal(record, itemId, campaignId)
    local nextItem = currentItem + quantity
    if nextItem < 0 then
        return false, "item_negative"
    end
    -- Attributed negative floors use personal durable identity totals, not the
    -- projected main aggregate. Grouped projection remains for display/logs;
    -- personal floors prevent admitting corrections that go negative after an
    -- alt moves or unassigns (#427 repair).
    if attributed and quantity < 0 then
        local attrGuid = GS.ResolveUniqueCharacterGuid and GS.ResolveUniqueCharacterGuid(
            record, attributed, opts.attributedGuid) or nil
        local personal, personalErr = nil, nil
        if GS.PersonalContributorItemTotal then
            personal, personalErr = GS.PersonalContributorItemTotal(
                record, attributed, attrGuid, itemId, campaignId)
        else
            personal = ActorItemTotal(record, attributed, itemId, campaignId)
        end
        if personalErr == GS.CREDIT_UNAVAILABLE or personal == nil and personalErr then
            return false, GS.CREDIT_UNAVAILABLE
        end
        personal = tonumber(personal) or 0
        if personal + quantity < 0 then
            return false, "player_negative"
        end
    end
    if opts.enforceGoalCeiling and quantity > 0 then
        local goal = CurrentItemGoal(record, itemId)
        if goal ~= nil and nextItem > goal then
            return false, "item_over_goal"
        end
    end
    return true, nil, attributed
end

function GS:PreviewAdjustment(itemId, quantity, attributed)
    local record, reason = GS:GetCurrentRecord()
    if not record then
        return nil, reason or "not_ready"
    end
    itemId = tonumber(itemId)
    if not GS.IsCurrentRequestedItem(record, itemId) then
        return nil, "item_not_requested"
    end
    local floorOk, floorErr, normAttr = GS.AdjustmentFloorOk(
        record, itemId, quantity, attributed, nil, { enforceGoalCeiling = true })
    if not floorOk then
        return nil, floorErr
    end
    quantity = tonumber(quantity)
    local currentItem = ItemTotal(record, itemId)
    local currentPlayer = normAttr and ActorItemTotal(record, normAttr, itemId) or nil
    local goal = CurrentItemGoal(record, itemId)
    return {
        itemId = itemId,
        quantity = quantity,
        attributed = normAttr,
        currentItem = currentItem,
        nextItem = currentItem + quantity,
        currentPlayer = currentPlayer,
        nextPlayer = currentPlayer and (currentPlayer + quantity) or nil,
        goal = goal,
    }
end

--- Settings confirmation copy for a prepared adjustment preview (#426).
-- Positive changes may show a leading '+' here; input parsing still rejects '+'.
function GS.FormatAdjustmentConfirmation(preview, itemName)
    if type(preview) ~= "table" then
        return ""
    end
    local name = itemName
    if type(name) ~= "string" or name == "" then
        name = Loc("GUILD_SUPPLIES_ITEM_FALLBACK", "item %s")
            :format(tostring(preview.itemId or "?"))
    end
    local qty = tonumber(preview.quantity) or 0
    local credit
    if preview.attributed then
        credit = tostring(preview.attributed)
    else
        credit = Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
    end
    local lines = {
        Loc("GUILD_SUPPLIES_ADJUST_CONFIRM_HEADER", "Adjust %s by %+d?")
            :format(name, qty),
        Loc("GUILD_SUPPLIES_ADJUST_CONFIRM_TOTAL", "Item total: %d → %d")
            :format(tonumber(preview.currentItem) or 0, tonumber(preview.nextItem) or 0),
    }
    if preview.attributed then
        lines[#lines + 1] = Loc("GUILD_SUPPLIES_ADJUST_CONFIRM_PLAYER",
            "Character contribution: %d → %d")
            :format(tonumber(preview.currentPlayer) or 0, tonumber(preview.nextPlayer) or 0)
    end
    lines[#lines + 1] = Loc("GUILD_SUPPLIES_ADJUST_CONFIRM_CREDIT", "Attribution: %s")
        :format(credit)
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Link / unlink / adjust operation shapes (kinds registered in Operations.lua)
---------------------------------------------------------------------------

function GS:NewLinkCharactersOperation(guidA, guidB)
    guidA, guidB = ValidGuid(guidA), ValidGuid(guidB)
    if not guidA or not guidB or guidA == guidB then
        return nil, "rejected", "invalid_guid"
    end
    local op, status, reason = GS:NewConfigOperation(GS.KIND.LINK_CHARACTERS, "identity-links", {
        guids = { guidA, guidB },
    })
    return op, status, reason
end

function GS:NewUnlinkCharacterOperation(guid)
    guid = ValidGuid(guid)
    if not guid then
        return nil, "rejected", "invalid_guid"
    end
    local op, status, reason = GS:NewConfigOperation(GS.KIND.UNLINK_CHARACTERS, "identity-links", {
        guid = guid,
    })
    return op, status, reason
end

function GS:NewAdjustmentOperation(itemId, quantity, attributed)
    local preview, err = GS:PreviewAdjustment(itemId, quantity, attributed)
    if not preview then
        return nil, "rejected", err or "invalid_adjustment"
    end
    local op, status, reason = GS:NewConfigOperation(GS.KIND.ADJUST_QUANTITY, {
        itemId = preview.itemId,
    }, {
        itemId = preview.itemId,
        quantity = preview.quantity,
        attributed = preview.attributed,
    })
    return op, status, reason
end

function GS.ApplyIdentityLinkMutation(record, op)
    local links = EnsureIdentityLinks(record)
    if op.kind == GS.KIND.LINK_CHARACTERS then
        local guids = op.value and op.value.guids
        if type(guids) ~= "table" or #guids < 2 then
            return false, "invalid_guid"
        end
        local a, b = ValidGuid(guids[1]), ValidGuid(guids[2])
        if not a or not b or a == b then
            return false, "invalid_guid"
        end
        local ga, gb = links.byGuid[a], links.byGuid[b]
        if ga and gb and ga == gb then
            return true, "duplicate"
        end
        if ga and gb and ga ~= gb then
            -- Merge groups into the lexicographically smaller group id (deterministic).
            local keep, drop = ga, gb
            if drop < keep then
                keep, drop = drop, keep
            end
            local keepGroup = links.groups[keep]
            local dropGroup = links.groups[drop]
            if type(keepGroup) ~= "table" or type(dropGroup) ~= "table" then
                return false, "invalid_identity_links"
            end
            -- Precompute the merged set so a capacity rejection leaves prior state intact.
            local merged = {}
            local seen = {}
            for i = 1, #(keepGroup.guids or {}) do
                local g = ValidGuid(keepGroup.guids[i])
                if g and not seen[g] then
                    seen[g] = true
                    merged[#merged + 1] = g
                end
            end
            for i = 1, #(dropGroup.guids or {}) do
                local g = ValidGuid(dropGroup.guids[i])
                if g and not seen[g] then
                    seen[g] = true
                    merged[#merged + 1] = g
                end
            end
            if #merged > (GS.MAX_GUIDS_PER_LINK_GROUP or 16) then
                return false, "full"
            end
            keepGroup.guids = merged
            links.groups[drop] = nil
            RebuildByGuid(links)
            links.revisionId = op.id
            GS.ReevaluatePendingEvidence(record)
            return true, "accepted"
        end
        if ga or gb then
            local gid = ga or gb
            local group = links.groups[gid]
            if type(group) ~= "table" then
                return false, "invalid_identity_links"
            end
            local add = ga and b or a
            for i = 1, #group.guids do
                if group.guids[i] == add then
                    links.revisionId = op.id
                    return true, "duplicate"
                end
            end
            if #group.guids >= (GS.MAX_GUIDS_PER_LINK_GROUP or 16) then
                return false, "full"
            end
            group.guids[#group.guids + 1] = add
            links.byGuid[add] = gid
            links.revisionId = op.id
            GS.ReevaluatePendingEvidence(record)
            return true, "accepted"
        end
        if CountLinkGroups(links) >= (GS.MAX_IDENTITY_LINK_GROUPS or 64) then
            return false, "full"
        end
        local gid = op.id
        links.groups[gid] = {
            id = gid,
            guids = { a, b },
            createdAt = op.timestamp or Now(),
            createdBy = op.actorGuid,
        }
        links.byGuid[a] = gid
        links.byGuid[b] = gid
        links.revisionId = op.id
        GS.ReevaluatePendingEvidence(record)
        return true, "accepted"
    end

    if op.kind == GS.KIND.UNLINK_CHARACTERS then
        local guid = ValidGuid(op.value and op.value.guid)
        if not guid then
            return false, "invalid_guid"
        end
        local gid = links.byGuid[guid]
        if not gid then
            return true, "duplicate"
        end
        local group = links.groups[gid]
        if type(group) ~= "table" or type(group.guids) ~= "table" then
            links.byGuid[guid] = nil
            links.revisionId = op.id
            return true, "accepted"
        end
        local kept = {}
        for i = 1, #group.guids do
            if group.guids[i] ~= guid then
                kept[#kept + 1] = group.guids[i]
            end
        end
        if #kept < 2 then
            links.groups[gid] = nil
        else
            group.guids = kept
        end
        RebuildByGuid(links)
        links.revisionId = op.id
        GS.ReevaluatePendingEvidence(record)
        return true, "accepted"
    end

    return false, "invalid_kind"
end

---------------------------------------------------------------------------
local function IsDonationLedgerEvent(event)
    local typ = event and event.type
    return typ == GS.LEDGER_EVENT.DONATION or typ == "CONSUMABLE_DONATION"
end

local function IsAdjustmentLedgerEvent(event)
    local typ = event and event.type
    return typ == GS.LEDGER_EVENT.ADJUSTMENT or typ == "CONSUMABLE_ADJUSTMENT"
end

-- Officer contributor credit corrections (#459)
-- Durable donation actor / adjustment attributed fields stay intact. Accepted
-- correct-contributor ops project an effective credited identity used by
-- personal floors, progress, rankings, Logs, and history audit. Cross-entry
-- convergence uses a deterministic active-head rebuild: LWW winner per
-- canonical event, then greedy activation in ascending (timestamp, id) under
-- personal nonnegative floors. Inactive accepted heads remain for audit/LWW
-- but do not move credit until floors allow.

local function CreditEventLists(record)
    return {
        record.accounting and record.accounting._consumableEvents,
        record.accounting and record.accounting._consumableEventArchive,
    }
end

local function EnsureCreditEventAliases(record)
    local cfg = record and record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" then
        return nil
    end
    if type(cfg.creditEventAliases) ~= "table" then
        cfg.creditEventAliases = {}
    end
    return cfg.creditEventAliases
end

local function CountCreditEventAliasKeys(map)
    local n = 0
    if type(map) ~= "table" then
        return 0
    end
    for _ in pairs(map) do
        n = n + 1
        if n > (GS.MAX_CREDIT_EVENT_ALIASES or 2048) then
            return n
        end
    end
    return n
end

--- Collect alias→canonical bindings required by retained accepted corrections.
-- Prefers head keys (credit:<canon>) and registry/map-backed accepted bodies so
-- reclaim never drops a binding still needed after registry eviction (#459 G1).
local function CollectRequiredCreditEventAliases(record)
    local required = {}
    if type(record) ~= "table" or type(record.operations) ~= "table" then
        return required
    end
    local ops = record.operations
    local kindCorrect = GS.KIND and GS.KIND.CORRECT_CONTRIBUTOR
    local map = record.accounting and record.accounting._consumables
        and record.accounting._consumables.creditEventAliases
    local cfg = record.accounting and record.accounting._consumables
    local function note(alias, canon)
        alias = ValidTxnId(alias)
        canon = ValidTxnId(canon)
        if alias and canon and alias ~= canon then
            required[alias] = canon
        end
    end
    local function resolvePrimary(txnId)
        if type(txnId) ~= "string" or txnId == "" then
            return nil
        end
        if type(FindRegistryByTxn) == "function" and type(cfg) == "table" then
            local reg = FindRegistryByTxn(cfg, txnId)
            if type(reg) == "table" then
                if reg.status == "alias" and type(reg.aliasOf) == "string" and reg.aliasOf ~= "" then
                    return ValidTxnId(reg.aliasOf) or reg.aliasOf
                end
                return ValidTxnId(reg.txnId) or txnId
            end
        end
        if type(map) == "table" and type(map[txnId]) == "string" and map[txnId] ~= "" then
            return ValidTxnId(map[txnId]) or map[txnId]
        end
        return txnId
    end
    if type(ops.heads) == "table" and type(ops.records) == "table" then
        local prefix = "credit:"
        for targetKey, headId in pairs(ops.heads) do
            if type(targetKey) == "string" and type(headId) == "string" then
                local body = ops.records[headId]
                if type(body) == "table" and body.kind == kindCorrect then
                    local canon = nil
                    if targetKey:sub(1, #prefix) == prefix then
                        canon = targetKey:sub(#prefix + 1)
                    end
                    if type(canon) == "string" and canon ~= "" then
                        note(body.target, canon)
                        if type(body.value) == "table" then
                            note(body.value.eventId, canon)
                        end
                    end
                end
            end
        end
    end
    if type(ops.records) == "table" then
        for _, body in pairs(ops.records) do
            if type(body) == "table" and body.kind == kindCorrect then
                local tid = body.target
                local primary = resolvePrimary(tid)
                if type(primary) == "string" and type(tid) == "string" and primary ~= tid then
                    note(tid, primary)
                end
                local ve = body.value and body.value.eventId
                if type(ve) == "string" and ve ~= "" then
                    local p2 = resolvePrimary(ve)
                    if type(p2) == "string" and p2 ~= ve then
                        note(ve, p2)
                    elseif type(primary) == "string" and ve ~= primary then
                        note(ve, primary)
                    end
                end
            end
        end
    end
    return required
end

--- Drop durable alias bindings not required by retained accepted corrections.
-- Optional protectKeys keeps in-flight writes. Returns number of reclaimed keys.
local function PruneUnusedCreditEventAliases(record, protectKeys)
    local map = EnsureCreditEventAliases(record)
    if not map then
        return 0
    end
    local required = CollectRequiredCreditEventAliases(record)
    local removed = 0
    local victims = {}
    for alias, canon in pairs(map) do
        if required[alias] == nil
            and not (type(protectKeys) == "table" and protectKeys[alias]) then
            victims[#victims + 1] = alias
        elseif type(required[alias]) == "string" and required[alias] ~= canon
            and not (type(protectKeys) == "table" and protectKeys[alias]) then
            -- Stale divergent binding for a still-required alias: refresh below.
            victims[#victims + 1] = alias
        end
    end
    for i = 1, #victims do
        map[victims[i]] = nil
        removed = removed + 1
    end
    for alias, canon in pairs(required) do
        if map[alias] ~= canon then
            if map[alias] ~= nil
                or CountCreditEventAliasKeys(map) < (GS.MAX_CREDIT_EVENT_ALIASES or 2048) then
                map[alias] = canon
            end
        end
    end
    return removed
end

--- Write alias→canonical into the durable map without touching ops generation.
-- Reclaims unused bindings at capacity before failing so retained corrections
-- keep durable alias ownership (#459 G1).
-- @return boolean writtenOrPresent, boolean changed
local function WriteCreditEventAlias(record, aliasId, canonicalId)
    aliasId = ValidTxnId(aliasId)
    canonicalId = ValidTxnId(canonicalId)
    if not aliasId or not canonicalId or aliasId == canonicalId then
        return false, false
    end
    if type(record) ~= "table" then
        return false, false
    end
    local map = EnsureCreditEventAliases(record)
    if not map then
        return false, false
    end
    local prior = map[aliasId]
    if prior == canonicalId then
        return true, false
    end
    if prior == nil and CountCreditEventAliasKeys(map) >= (GS.MAX_CREDIT_EVENT_ALIASES or 2048) then
        PruneUnusedCreditEventAliases(record, { [aliasId] = true })
        prior = map[aliasId]
        if prior == canonicalId then
            return true, false
        end
        if prior == nil and CountCreditEventAliasKeys(map) >= (GS.MAX_CREDIT_EVENT_ALIASES or 2048) then
            return false, false
        end
    end
    map[aliasId] = canonicalId
    return true, true
end

--- Ensure durable alias→canonical bindings required to retain/accept a
-- correction that may target alias ids. Reclaims unused map entries first; if
-- capacity is still exhausted by bindings required by already-retained
-- corrections, refuse without mutating other retained bindings (#459 G1).
-- @param event table resolved canonical ledger event
-- @return boolean ok, string|nil err
function GS.EnsureContributorCorrectionDurableAliases(record, op, event)
    if type(event) ~= "table" or type(event.id) ~= "string" or event.id == "" then
        return true
    end
    if type(op) ~= "table" then
        return true
    end
    local function requireAlias(aliasId)
        if type(aliasId) ~= "string" or aliasId == "" or aliasId == event.id then
            return true
        end
        local wrote = WriteCreditEventAlias(record, aliasId, event.id)
        return wrote and true or false
    end
    local targetId = op.target
    if not requireAlias(targetId) then
        return false, "full"
    end
    local valueEventId = op.value and op.value.eventId
    if not requireAlias(valueEventId) then
        return false, "full"
    end
    return true
end

--- Persist a trusted alias→canonical credit-event binding that outlives the
-- bounded txn registry (#459). Re-confirm clears a cached ops validation miss
-- without requiring a manual ops-generation bump when the binding is unchanged.
-- @return boolean changedOrPresent
function GS.RememberCreditEventAlias(record, aliasId, canonicalId)
    local ok, changed = WriteCreditEventAlias(record, aliasId, canonicalId)
    if not ok then
        return false
    end
    if not changed then
        -- Binding already known: drop a stale negative ops-validation cache entry
        -- so cold/warm re-validate can succeed after registry restore (#459).
        if type(record.operations) == "table" and GS._ClearOpsValidationCache then
            GS._ClearOpsValidationCache(record.operations)
        end
        return true
    end
    -- New/changed binding: advance ops generation so projection stamps and
    -- validation caches observe the mapping change. Do not Invalidate here —
    -- callers mid-accept still Seal; WakePending / Ensure observe the new gen.
    if type(record.operations) == "table" and GS._BumpOpsValidationGen then
        GS._BumpOpsValidationGen(record.operations)
    end
    return true
end

--- Rebuild durable alias bindings from retained correction heads when the
-- txn registry no longer carries X→Y but the canonical donation still exists.
-- One shared bounded ledger-id pass; skip heads whose map entry already matches.
-- Silent map writes only; does not bump ops generation mid-validation (#459 G1).
function GS.ReconstructCreditEventAliasesFromOps(record)
    if type(record) ~= "table" or type(record.operations) ~= "table" then
        return
    end
    local ops = record.operations
    if type(ops.heads) ~= "table" or type(ops.records) ~= "table" then
        return
    end
    local map = EnsureCreditEventAliases(record)
    if not map then
        return
    end
    local kindCorrect = GS.KIND and GS.KIND.CORRECT_CONTRIBUTOR
    local needed = {}
    local prefix = "credit:"
    for targetKey, headId in pairs(ops.heads) do
        if type(targetKey) == "string" and type(headId) == "string" then
            local body = ops.records[headId]
            if type(body) == "table" and body.kind == kindCorrect
                and type(body.target) == "string" and body.target ~= "" then
                local canon = nil
                if targetKey:sub(1, #prefix) == prefix then
                    canon = targetKey:sub(#prefix + 1)
                end
                if type(canon) == "string" and canon ~= "" and canon ~= body.target then
                    if map[body.target] ~= canon then
                        needed[canon] = needed[canon] or {}
                        needed[canon][#needed[canon] + 1] = body.target
                    end
                    local ve = body.value and body.value.eventId
                    if type(ve) == "string" and ve ~= "" and ve ~= canon
                        and map[ve] ~= canon then
                        needed[canon] = needed[canon] or {}
                        needed[canon][#needed[canon] + 1] = ve
                    end
                end
            end
        end
    end
    local needAny = false
    for _ in pairs(needed) do
        needAny = true
        break
    end
    if not needAny then
        -- Existing map entries already match heads — no ledger walk (#459 G1).
        GS._creditEventAliasReconstructLedgerVisits = 0
        return
    end
    -- Shared exact-id presence set (one live + one archive bounded pass).
    local present = {}
    local ledgerVisits = 0
    local lists = CreditEventLists(record)
    for li = 1, #lists do
        local list = lists[li]
        if type(list) == "table" then
            local limit = math.min(#list, (li == 1 and (GS.MAX_LEDGER_EVENTS or 4096))
                or (GS.MAX_ARCHIVED_EVENTS or 4096))
            for i = 1, limit do
                ledgerVisits = ledgerVisits + 1
                local event = list[i]
                if type(event) == "table" and type(event.id) == "string"
                    and needed[event.id] then
                    present[event.id] = true
                end
            end
        end
    end
    GS._creditEventAliasReconstructLedgerVisits = ledgerVisits
    local protect = {}
    for canon, aliases in pairs(needed) do
        if present[canon] then
            for ai = 1, #aliases do
                protect[aliases[ai]] = true
            end
        end
    end
    for canon, aliases in pairs(needed) do
        if present[canon] then
            for ai = 1, #aliases do
                local alias = aliases[ai]
                if map[alias] ~= canon then
                    if map[alias] ~= nil
                        or CountCreditEventAliasKeys(map) < (GS.MAX_CREDIT_EVENT_ALIASES or 2048) then
                        map[alias] = canon
                    else
                        PruneUnusedCreditEventAliases(record, protect)
                        if map[alias] ~= nil
                            or CountCreditEventAliasKeys(map) < (GS.MAX_CREDIT_EVENT_ALIASES or 2048) then
                            map[alias] = canon
                        end
                    end
                end
            end
        end
    end
end

--- Resolve a correction/donation target id through the trusted txn alias registry
-- and durable credit-event alias map (survives registry eviction) (#459).
-- @return primaryTxnId|nil
local function ResolveCreditTxnPrimary(record, eventId)
    if type(eventId) ~= "string" or eventId == "" then
        return nil
    end
    local cfg = record and record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" then
        return eventId
    end
    local current = eventId
    for _ = 1, 8 do
        local reg = type(FindRegistryByTxn) == "function" and FindRegistryByTxn(cfg, current)
        if type(reg) == "table" then
            if reg.status == "alias" and type(reg.aliasOf) == "string" and reg.aliasOf ~= ""
                and reg.aliasOf ~= current then
                current = reg.aliasOf
            else
                return ValidTxnId(reg.txnId) or current
            end
        else
            local map = cfg.creditEventAliases
            local mapped = type(map) == "table" and map[current]
            if type(mapped) == "string" and mapped ~= "" and mapped ~= current then
                current = mapped
            else
                return current
            end
        end
    end
    return current
end

--- Locate a durable ledger event by id across live + archive lists.
-- Also resolves trusted donation txn aliases onto the canonical ledger row.
-- @return event|nil
function GS.FindLedgerEventById(record, eventId)
    if type(record) ~= "table" or type(eventId) ~= "string" or eventId == "" then
        return nil
    end
    local lists = CreditEventLists(record)
    for li = 1, #lists do
        local list = lists[li]
        if type(list) == "table" then
            local limit = math.min(#list, (li == 1 and (GS.MAX_LEDGER_EVENTS or 4096))
                or (GS.MAX_ARCHIVED_EVENTS or 4096))
            for i = 1, limit do
                local event = list[i]
                if type(event) == "table" and event.id == eventId then
                    return event
                end
            end
        end
    end
    -- Exact id miss: try txnId equality, then alias → primary → ledger.
    local byTxn = FindLedgerEventByTxnId(record, eventId)
    if byTxn then
        return byTxn
    end
    local primary = ResolveCreditTxnPrimary(record, eventId)
    if primary and primary ~= eventId then
        byTxn = FindLedgerEventByTxnId(record, primary)
        if byTxn then
            return byTxn
        end
        for li = 1, #lists do
            local list = lists[li]
            if type(list) == "table" then
                local limit = math.min(#list, (li == 1 and (GS.MAX_LEDGER_EVENTS or 4096))
                    or (GS.MAX_ARCHIVED_EVENTS or 4096))
                for i = 1, limit do
                    local event = list[i]
                    if type(event) == "table" and event.id == primary then
                        return event
                    end
                end
            end
        end
    end
    return nil
end

--- Canonical ledger event id for correction targets (alias-aware).
function GS.CanonicalCreditEventId(record, eventId)
    local event = GS.FindLedgerEventById(record, eventId)
    if type(event) == "table" and type(event.id) == "string" and event.id ~= "" then
        return event.id
    end
    local primary = ResolveCreditTxnPrimary(record, eventId)
    return primary or eventId
end

--- Operation-head key for correct-contributor, bound to the canonical event id.
-- Admission, apply, and prepare must share this key so alias-targeted ops
-- LWW against the same head as locally prepared canonical corrections (#459).
function GS.CorrectionTargetKey(record, target)
    if type(target) ~= "string" or target == "" then
        return nil
    end
    local canonical = GS.CanonicalCreditEventId(record, target) or target
    if not GS.ComputeTargetKey then
        return "credit:" .. canonical
    end
    return GS.ComputeTargetKey(
        GS.KIND and GS.KIND.CORRECT_CONTRIBUTOR, canonical)
end

--- Fold alias-keyed correction heads onto the canonical primary after trusted
-- A→X discovery so obsolete/LWW classification sees one head (#459).
function GS.MigrateCorrectionHeadsForAlias(record, primaryTxnId, aliasTxnId)
    if type(record) ~= "table" or type(record.operations) ~= "table" then
        return
    end
    local ops = record.operations
    if type(ops.heads) ~= "table" then
        return
    end
    local primaryKey = GS.CorrectionTargetKey
        and GS.CorrectionTargetKey(record, primaryTxnId)
        or ("credit:" .. tostring(primaryTxnId))
    local aliasKey = "credit:" .. tostring(aliasTxnId)
    if primaryKey == aliasKey then
        return
    end
    local aliasHeadId = ops.heads[aliasKey]
    if type(aliasHeadId) ~= "string" then
        return
    end
    local primaryHeadId = ops.heads[primaryKey]
    if type(primaryHeadId) ~= "string" then
        ops.heads[primaryKey] = aliasHeadId
        ops.heads[aliasKey] = nil
        return
    end
    if primaryHeadId == aliasHeadId then
        ops.heads[aliasKey] = nil
        return
    end
    local primaryBody = ops.records and ops.records[primaryHeadId]
    local aliasBody = ops.records and ops.records[aliasHeadId]
    if type(aliasBody) == "table" and type(primaryBody) == "table"
        and GS.CreditCorrectionRevisionWins
        and GS.CreditCorrectionRevisionWins(aliasBody, primaryBody) then
        ops.heads[primaryKey] = aliasHeadId
    end
    ops.heads[aliasKey] = nil
end

--- After trusted alias discovery: migrate heads, rebuild projection, redrive (#459).
function GS.WakePendingCorrectionsAfterAlias(record, primaryTxnId, aliasTxnId, itemId)
    if type(record) ~= "table" then
        return
    end
    GS.MigrateCorrectionHeadsForAlias(record, primaryTxnId, aliasTxnId)
    if GS.InvalidateCreditCorrectionProjection then
        GS.InvalidateCreditCorrectionProjection(record)
    end
    -- One shared allowance; item filter covers primary and alias txn targets.
    if GS.EnsureThenRedriveCreditCorrections then
        GS.EnsureThenRedriveCreditCorrections(record, {
            itemId = itemId,
        })
    end
end

local function DurableCreditIdentity(event)
    if IsDonationLedgerEvent(event) then
        return NormName(event.actor), ValidGuid(event.actorGuid or event.donorGuid)
    end
    if IsAdjustmentLedgerEvent(event) then
        return NormName(event.attributed), ValidGuid(event.attributedGuid)
    end
    return nil, nil
end

local function CreditIdentitiesEqual(aName, aGuid, bName, bGuid)
    local ag = ValidGuid(aGuid)
    local bg = ValidGuid(bGuid)
    if ag and bg then
        return ag == bg
    end
    local an = NormName(aName)
    local bn = NormName(bName)
    if an and bn then
        return an == bn
    end
    return an == nil and bn == nil and ag == nil and bg == nil
end

--- Public identity equality for prepare/UI unchanged checks (#459).
function GS.CreditIdentitiesEqual(aName, aGuid, bName, bGuid)
    return CreditIdentitiesEqual(aName, aGuid, bName, bGuid)
end

--- True when the credit correction projection is verified for ordinary reads.
-- Distinct from Ensure's rebuild details; false means credit_unavailable.
function GS.IsCreditCorrectionProjectionAvailable(record)
    if type(record) ~= "table" then
        return false
    end
    if not GS.EnsureCreditCorrectionProjection then
        return true
    end
    return GS.EnsureCreditCorrectionProjection(record, nil) ~= false
end

--- Effective credited identity for one ledger event (#459).
-- When projection reconstruction is failed/blocked, returns
-- nil, nil, nil, GS.CREDIT_UNAVAILABLE — never durable fallback.
-- Legitimate Unassigned adjustments still return nil, nil, nil, nil while
-- the projection is available.
-- @return name|nil, guid|nil, correctionHead|nil, status|nil
function GS.ResolveEffectiveCreditIdentity(record, event)
    if type(event) ~= "table" or type(event.id) ~= "string" or event.id == "" then
        return nil, nil, nil, nil
    end
    if type(record) == "table" and GS.EnsureCreditCorrectionProjection then
        local ok = GS.EnsureCreditCorrectionProjection(record, nil)
        if ok == false then
            return nil, nil, nil, GS.CREDIT_UNAVAILABLE
        end
    end
    local map = type(record) == "table" and record.creditCorrections or nil
    local head = nil
    if type(map) == "table" then
        head = map[event.id]
        if type(head) ~= "table" then
            local canonical = GS.CanonicalCreditEventId(record, event.id)
            if canonical and canonical ~= event.id then
                head = map[canonical]
            end
        end
    end
    if type(head) == "table" then
        return NormName(head.attributed), ValidGuid(head.attributedGuid), head, nil
    end
    local name, guid = DurableCreditIdentity(event)
    return name, guid, nil, nil
end

--- Count retained correction projection heads (capacity guard).
local function CountCreditCorrections(record)
    local map = record and record.creditCorrections
    if type(map) ~= "table" then
        return 0
    end
    local n = 0
    for _ in pairs(map) do
        n = n + 1
    end
    return n
end

--- Personal total using an override map of active correction heads (by event.id).
-- Does not read record.creditCorrections so rebuild stays self-contained.
local function PersonalTotalWithActive(record, actorName, actorGuid, itemId, campaignId, activeMap)
    itemId = tonumber(itemId)
    if type(record) ~= "table" or not IsItemId(itemId) then
        return 0
    end
    campaignId = campaignId or record.currentCampaignId
    if type(campaignId) ~= "string" or campaignId == "" then
        return 0
    end
    local identityName = NormName(actorName)
    local identityGuid = ValidGuid(actorGuid)
    if not identityName and not identityGuid then
        return 0
    end
    local generation = nil
    if record.currentCampaignId == campaignId then
        local cfg = record.accounting and record.accounting._consumables
        generation = cfg and tonumber(cfg.generation)
    end
    if not generation then
        local archive = record.campaignArchives and record.campaignArchives[campaignId]
        generation = archive and tonumber(archive.generation)
    end
    if not generation or generation < 1 then
        return 0
    end
    local function sideMatches(sideName, sideGuid)
        local g = ValidGuid(sideGuid)
        if identityGuid and g then
            return g == identityGuid
        end
        local side = NormName(sideName)
        if identityGuid and not g then
            if side and identityName and side == identityName then
                return true
            end
            if side then
                local resolved = GS.ResolveUniqueCharacterGuid(record, side, nil)
                if resolved and resolved == identityGuid then
                    return true
                end
            end
            return false
        end
        return side ~= nil and identityName ~= nil and side == identityName
    end
    local total = 0
    local function consider(event)
        if type(event) ~= "table" then
            return
        end
        if tonumber(event.generation) ~= generation then
            return
        end
        if GS.EventCountsTowardLiveProgress
            and not GS.EventCountsTowardLiveProgress(record, event) then
            return
        end
        if tonumber(event.itemId) ~= itemId then
            return
        end
        local qty = tonumber(event.quantity) or 0
        if qty == 0 then
            return
        end
        local typ = event.type
        local isDonation = typ == GS.LEDGER_EVENT.DONATION or typ == "CONSUMABLE_DONATION"
        local isAdjustment = typ == GS.LEDGER_EVENT.ADJUSTMENT or typ == "CONSUMABLE_ADJUSTMENT"
        if not isDonation and not isAdjustment then
            return
        end
        local creditName, creditGuid
        local override = type(activeMap) == "table" and type(event.id) == "string"
            and activeMap[event.id] or nil
        if type(override) == "table" then
            creditName, creditGuid = NormName(override.attributed), ValidGuid(override.attributedGuid)
        else
            creditName, creditGuid = DurableCreditIdentity(event)
        end
        if isDonation then
            if qty > 0 and sideMatches(creditName, creditGuid) then
                total = total + qty
            end
        elseif creditName or creditGuid then
            if sideMatches(creditName, creditGuid) then
                total = total + qty
            end
        end
    end
    local live = record.accounting and record.accounting._consumableEvents
    local archived = record.accounting and record.accounting._consumableEventArchive
    if type(live) == "table" then
        for i = 1, #live do
            consider(live[i])
        end
    end
    if type(archived) == "table" then
        for i = 1, #archived do
            consider(archived[i])
        end
    end
    return total
end

local function FloorOkWithActive(record, event, newName, newGuid, activeMap)
    if type(record) ~= "table" or type(event) ~= "table" then
        return false, "invalid_event"
    end
    local itemId = tonumber(event.itemId)
    local qty = tonumber(event.quantity)
    if not IsItemId(itemId) or not qty or qty ~= qty or qty ~= math.floor(qty) or qty == 0 then
        return false, "invalid_event"
    end
    local campaignId = event.campaignId or record.currentCampaignId
    if type(campaignId) ~= "string" or campaignId == "" then
        return false, "no_campaign"
    end
    local curName, curGuid
    local override = type(activeMap) == "table" and activeMap[event.id]
    if type(override) == "table" then
        curName, curGuid = NormName(override.attributed), ValidGuid(override.attributedGuid)
    else
        curName, curGuid = DurableCreditIdentity(event)
    end
    newName = NormName(newName)
    newGuid = ValidGuid(newGuid)
    if CreditIdentitiesEqual(curName, curGuid, newName, newGuid) then
        return true
    end
    if curName or curGuid then
        local personal = PersonalTotalWithActive(
            record, curName, curGuid, itemId, campaignId, activeMap)
        if personal - qty < 0 then
            return false, "player_negative"
        end
    end
    if newName or newGuid then
        local personal = PersonalTotalWithActive(
            record, newName, newGuid, itemId, campaignId, activeMap)
        if personal + qty < 0 then
            return false, "player_negative"
        end
    end
    return true
end

--- Personal floor check against the live effective projection (#459).
function GS.ContributorCorrectionFloorOk(record, event, newName, newGuid)
    if type(record) == "table" and GS.EnsureCreditCorrectionProjection then
        local ok = GS.EnsureCreditCorrectionProjection(record, nil)
        if ok == false then
            return false, GS.CREDIT_UNAVAILABLE
        end
    end
    -- Use current creditCorrections as the active map.
    local activeMap = nil
    if type(record) == "table" and type(record.creditCorrections) == "table" then
        activeMap = record.creditCorrections
    end
    return FloorOkWithActive(record, event, newName, newGuid, activeMap)
end

local function CorrectionHeadFromOp(op, event, newName, newGuid, prior)
    local durableName, durableGuid = DurableCreditIdentity(event)
    local originalName = (type(prior) == "table" and (prior.originalAttributed or prior.originalName))
        or durableName
    local originalGuid = (type(prior) == "table" and (prior.originalAttributedGuid or prior.originalGuid))
        or durableGuid
    -- Authored previous credit (durable on the op). Never derive from receiver
    -- projection so reversed delivery preserves audit.
    local previousName = NormName(op.value and op.value.baseAttributed)
    local previousGuid = ValidGuid(op.value and op.value.baseAttributedGuid)
    local isDonation = IsDonationLedgerEvent(event)
    return {
        attributed = newName,
        attributedGuid = newGuid,
        revisionId = op.id,
        correctedAt = tonumber(op.timestamp) or Now(),
        actorName = NormName(op.actorName),
        actorGuid = ValidGuid(op.actorGuid),
        originalAttributed = originalName,
        originalAttributedGuid = originalGuid,
        previousAttributed = previousName,
        previousAttributedGuid = previousGuid,
        eventKind = isDonation and "donation" or "adjustment",
    }
end

local function BindCorrectionNewIdentity(record, event, attributed, attributedGuid)
    local isDonation = IsDonationLedgerEvent(event)
    local isAdjustment = IsAdjustmentLedgerEvent(event)
    if not isDonation and not isAdjustment then
        return nil, nil, "invalid_event"
    end
    local newName = NormName(attributed)
    local newGuid = ValidGuid(attributedGuid)
    if isDonation then
        if not newName then
            return nil, nil, "invalid_attribution"
        end
        local boundName, boundGuid, bindErr = GS.ResolveAttributedIdentity(
            record, newName, newGuid)
        if bindErr then
            return nil, nil, bindErr
        end
        return boundName, boundGuid, nil
    end
    if newName then
        local boundName, boundGuid, bindErr = GS.ResolveAttributedIdentity(
            record, newName, newGuid)
        if bindErr then
            return nil, nil, bindErr
        end
        return boundName, boundGuid, nil
    end
    return nil, nil, nil
end

local function IdentityBucketKey(name, guid, itemId, campaignId)
    local g = ValidGuid(guid)
    local n = NormName(name)
    if not g and not n then
        return nil
    end
    itemId = tonumber(itemId)
    if not itemId then
        return nil
    end
    if type(campaignId) ~= "string" or campaignId == "" then
        return nil
    end
    if g then
        return "g:" .. g .. "\0" .. tostring(itemId) .. "\0" .. campaignId
    end
    return "n:" .. n .. "\0" .. tostring(itemId) .. "\0" .. campaignId
end

--- Identity bucket for correction floor aggregates (#459).
-- GUID-first when Guild Info relationships are ready; when they are not,
-- BindCharacterIdentity may strip claimed GUIDs from correction heads while
-- durable adjustments still carry GUIDs — prefer name keys in that state.
-- resolveCache: optional per-rebuild name→guid memo so readiness is not
-- revalidated once per ledger row.
local function CreditFloorBucketKey(record, name, guid, itemId, campaignId, relationshipsReady, resolveCache)
    local g = ValidGuid(guid)
    local n = NormName(name)
    -- Name-only buckets when relationships are not ready — skip unique-GUID
    -- resolve so projection/readiness stays O(1) in relationship checks.
    if n and not relationshipsReady then
        return IdentityBucketKey(n, nil, itemId, campaignId)
    end
    if not g and n and GS.ResolveUniqueCharacterGuid then
        if type(resolveCache) == "table" and resolveCache[n] ~= nil then
            g = ValidGuid(resolveCache[n])
        else
            g = ValidGuid(GS.ResolveUniqueCharacterGuid(record, n, nil))
            if type(resolveCache) == "table" then
                resolveCache[n] = g or false
            end
        end
    end
    return IdentityBucketKey(n, g, itemId, campaignId)
end

local function NegContribution(value)
    value = tonumber(value) or 0
    if value < 0 then
        return value
    end
    return 0
end

--- Add qty to a floor bucket. Optional scoreBox={score} updates TotalsNegScore in O(1).
local function TotalsAdd(totals, key, qty, scoreBox)
    if not key or not qty or qty == 0 then
        return
    end
    local old = totals[key] or 0
    local new = old + qty
    totals[key] = new
    if type(scoreBox) == "table" then
        scoreBox[1] = (tonumber(scoreBox[1]) or 0)
            + (NegContribution(new) - NegContribution(old))
        GS._creditProjectionBucketVisits =
            (tonumber(GS._creditProjectionBucketVisits) or 0) + 1
    end
end

local function TotalsAllNonNegative(totals)
    for _, total in pairs(totals) do
        GS._creditProjectionFloorVisits =
            (tonumber(GS._creditProjectionFloorVisits) or 0) + 1
        if total < 0 then
            return false
        end
    end
    return true
end

--- Sum of negative totals (0 when all nonnegative). Higher is better when pruning.
-- Prefer maintaining score via TotalsAdd(..., scoreBox) during conflict trials.
local function TotalsNegScore(totals)
    local score = 0
    for _, total in pairs(totals) do
        GS._creditProjectionBucketVisits =
            (tonumber(GS._creditProjectionBucketVisits) or 0) + 1
        if total < 0 then
            score = score + total
        end
    end
    return score
end

--- Item ids that currently have any negative personal floor bucket.
-- Keys are "g:guid\0itemId\0campaign" or "n:name\0itemId\0campaign".
-- Lua 5.1 patterns cannot match embedded NULs — use plain find/sub.
local function ItemIdsWithNegativeTotals(totals)
    local bad = {}
    for key, total in pairs(totals) do
        if total < 0 and type(key) == "string" then
            local first = key:find("\0", 1, true)
            if first then
                local second = key:find("\0", first + 1, true)
                if second then
                    local itemId = tonumber(key:sub(first + 1, second - 1))
                    if itemId then
                        bad[itemId] = true
                    end
                end
            end
        end
    end
    return bad
end

--- Index a ledger event under id and txnId only (#459).
-- Trusted aliases are folded in one separate registry pass — never call
-- FindRegistryByTxn per ledger row (that is O(ledger×registry)).
local function IndexCreditEventKeys(byId, event)
    if type(byId) ~= "table" or type(event) ~= "table" then
        return
    end
    if type(event.id) == "string" and event.id ~= "" then
        byId[event.id] = event
    end
    local txnId = type(event.txnId) == "string" and event.txnId or nil
    if txnId and txnId ~= "" then
        byId[txnId] = event
    end
end

--- Scan live+archive once into durable baseline totals and an id/alias index.
-- Returns totals, byId, rowVisits, relationshipsReady. Callers apply correction
-- deltas in O(1). Alias mapping is one linear registry pass.
local function BuildDurableCreditFloorBaseline(record)
    local relationshipsReady = GS.WitnessRelationshipsReady
        and select(1, GS.WitnessRelationshipsReady(record))
    local totals = {}
    local byId = {}
    local visits = 0
    local resolveCache = {}
    local function consider(event)
        if type(event) ~= "table" then
            return
        end
        visits = visits + 1
        IndexCreditEventKeys(byId, event)
        if GS.EventCountsTowardLiveProgress
            and not GS.EventCountsTowardLiveProgress(record, event) then
            return
        end
        local itemId = tonumber(event.itemId)
        local qty = tonumber(event.quantity) or 0
        if not itemId or qty == 0 then
            return
        end
        local campaignId = event.campaignId or record.currentCampaignId
        local creditName, creditGuid = DurableCreditIdentity(event)
        local isDonation = IsDonationLedgerEvent(event)
        local isAdjustment = IsAdjustmentLedgerEvent(event)
        if isDonation then
            if qty > 0 then
                TotalsAdd(totals, CreditFloorBucketKey(
                    record, creditName, creditGuid, itemId, campaignId,
                    relationshipsReady, resolveCache), qty)
            end
        elseif isAdjustment then
            if creditName or creditGuid then
                TotalsAdd(totals, CreditFloorBucketKey(
                    record, creditName, creditGuid, itemId, campaignId,
                    relationshipsReady, resolveCache), qty)
            end
        end
    end
    local live = record.accounting and record.accounting._consumableEvents
    local archived = record.accounting and record.accounting._consumableEventArchive
    if type(live) == "table" then
        for i = 1, #live do
            consider(live[i])
        end
    end
    if type(archived) == "table" then
        for i = 1, #archived do
            consider(archived[i])
        end
    end
    -- One linear registry pass: map verified primary aliases + alias pointers.
    local cfg = record.accounting and record.accounting._consumables
    local registry = cfg and cfg.txnRegistry
    if type(registry) == "table" then
        for i = 1, #registry do
            local row = registry[i]
            visits = visits + 1
            if type(row) == "table" then
                if type(row.txnId) == "string" and row.txnId ~= ""
                    and type(row.aliases) == "table" then
                    local primary = byId[row.txnId]
                    if primary then
                        for j = 1, #row.aliases do
                            local alias = row.aliases[j]
                            if type(alias) == "string" and alias ~= "" then
                                byId[alias] = primary
                                visits = visits + 1
                            end
                        end
                    end
                end
                if row.status == "alias"
                    and type(row.txnId) == "string" and type(row.aliasOf) == "string" then
                    local primary = byId[row.aliasOf]
                    if primary then
                        byId[row.txnId] = primary
                    end
                end
            end
        end
    end
    return totals, byId, visits, relationshipsReady
end

--- Paced durable baseline: retain partial totals/byId across slices when the
-- shared callback allowance is exhausted mid-ledger / mid-registry.
-- scratch fields: baselineReady, baselinePhase ("live"|"archive"|"registry"),
-- baselineIndex, baselineTotals, baselineById, baselineVisits,
-- baselineRelationshipsReady, baselineResolveCache.
local function ContinueDurableCreditFloorBaseline(record, scratch, shouldYieldFn)
    local relationshipsReady = scratch and scratch.baselineRelationshipsReady
    if relationshipsReady == nil then
        relationshipsReady = GS.WitnessRelationshipsReady
            and select(1, GS.WitnessRelationshipsReady(record))
    end
    local totals = scratch and scratch.baselineTotals or {}
    local byId = scratch and scratch.baselineById or {}
    local provenance = scratch and scratch.baselineProvenance or {}
    local visits = tonumber(scratch and scratch.baselineVisits) or 0
    local resolveCache = scratch and scratch.baselineResolveCache or {}
    local phase = (scratch and scratch.baselinePhase) or "live"
    local index = tonumber(scratch and scratch.baselineIndex) or 1

    local function consider(event)
        if type(event) ~= "table" then
            return
        end
        visits = visits + 1
        IndexCreditEventKeys(byId, event)
        -- Index name↔GUID provenance once during the paced baseline so activation
        -- BindCharacterIdentity does not rescan the ledger per head (#459).
        NoteCreditProvenanceFromEvent(provenance, event)
        if GS.EventCountsTowardLiveProgress
            and not GS.EventCountsTowardLiveProgress(record, event) then
            return
        end
        local itemId = tonumber(event.itemId)
        local qty = tonumber(event.quantity) or 0
        if not itemId or qty == 0 then
            return
        end
        local campaignId = event.campaignId or record.currentCampaignId
        local creditName, creditGuid = DurableCreditIdentity(event)
        local isDonation = IsDonationLedgerEvent(event)
        local isAdjustment = IsAdjustmentLedgerEvent(event)
        if isDonation then
            if qty > 0 then
                TotalsAdd(totals, CreditFloorBucketKey(
                    record, creditName, creditGuid, itemId, campaignId,
                    relationshipsReady, resolveCache), qty)
            end
        elseif isAdjustment then
            if creditName or creditGuid then
                TotalsAdd(totals, CreditFloorBucketKey(
                    record, creditName, creditGuid, itemId, campaignId,
                    relationshipsReady, resolveCache), qty)
            end
        end
    end

    local function snapshot(nextPhase, nextIndex)
        return {
            baselineReady = false,
            baselinePhase = nextPhase,
            baselineIndex = nextIndex,
            baselineTotals = totals,
            baselineById = byId,
            baselineProvenance = provenance,
            baselineVisits = visits,
            baselineRelationshipsReady = relationshipsReady,
            baselineResolveCache = resolveCache,
        }, visits
    end

    local live = record.accounting and record.accounting._consumableEvents
    local archived = record.accounting and record.accounting._consumableEventArchive
    if phase == "live" and type(live) == "table" then
        while index <= #live do
            consider(live[index])
            index = index + 1
            if shouldYieldFn and shouldYieldFn(visits) then
                return false, snapshot("live", index)
            end
        end
        phase = "archive"
        index = 1
    elseif phase == "live" then
        phase = "archive"
        index = 1
    end
    if phase == "archive" and type(archived) == "table" then
        while index <= #archived do
            consider(archived[index])
            index = index + 1
            if shouldYieldFn and shouldYieldFn(visits) then
                return false, snapshot("archive", index)
            end
        end
        phase = "registry"
        index = 1
    elseif phase == "archive" then
        phase = "registry"
        index = 1
    end
    if phase == "registry" then
        local cfg = record.accounting and record.accounting._consumables
        local registry = cfg and cfg.txnRegistry
        if type(registry) == "table" then
            while index <= #registry do
                local row = registry[index]
                visits = visits + 1
                index = index + 1
                if type(row) == "table" then
                    if type(row.txnId) == "string" and row.txnId ~= ""
                        and type(row.aliases) == "table" then
                        local primary = byId[row.txnId]
                        if primary then
                            for j = 1, #row.aliases do
                                local alias = row.aliases[j]
                                if type(alias) == "string" and alias ~= "" then
                                    byId[alias] = primary
                                    visits = visits + 1
                                end
                            end
                        end
                    end
                    if row.status == "alias"
                        and type(row.txnId) == "string" and type(row.aliasOf) == "string" then
                        local primary = byId[row.aliasOf]
                        if primary then
                            byId[row.txnId] = primary
                        end
                    end
                end
                if shouldYieldFn and shouldYieldFn(visits) then
                    return false, snapshot("registry", index)
                end
            end
        end
    end
    return true, {
        baselineReady = true,
        baselineTotals = totals,
        baselineById = byId,
        baselineProvenance = provenance,
        baselineVisits = visits,
        baselineRelationshipsReady = relationshipsReady,
    }, visits
end

--- Apply or reverse one donation/adjustment correction delta on floor totals.
-- Optional scoreBox={score} keeps TotalsNegScore in O(1) per touched bucket.
local function ApplyCorrectionFloorDelta(record, totals, event, newName, newGuid, relationshipsReady, sign, scoreBox)
    sign = sign or 1
    if type(event) ~= "table" then
        return
    end
    if GS.EventCountsTowardLiveProgress
        and not GS.EventCountsTowardLiveProgress(record, event) then
        return
    end
    local itemId = tonumber(event.itemId)
    local qty = tonumber(event.quantity) or 0
    if not itemId or qty == 0 then
        return
    end
    local campaignId = event.campaignId or record.currentCampaignId
    local oldName, oldGuid = DurableCreditIdentity(event)
    local isDonation = IsDonationLedgerEvent(event)
    local isAdjustment = IsAdjustmentLedgerEvent(event)
    if isDonation and qty > 0 then
        TotalsAdd(totals, CreditFloorBucketKey(
            record, oldName, oldGuid, itemId, campaignId, relationshipsReady),
            -sign * qty, scoreBox)
        TotalsAdd(totals, CreditFloorBucketKey(
            record, newName, newGuid, itemId, campaignId, relationshipsReady),
            sign * qty, scoreBox)
    elseif isAdjustment and (oldName or oldGuid or newName or newGuid) then
        if oldName or oldGuid then
            TotalsAdd(totals, CreditFloorBucketKey(
                record, oldName, oldGuid, itemId, campaignId, relationshipsReady),
                -sign * qty, scoreBox)
        end
        if newName or newGuid then
            TotalsAdd(totals, CreditFloorBucketKey(
                record, newName, newGuid, itemId, campaignId, relationshipsReady),
                sign * qty, scoreBox)
        end
    end
end

--- True when every personal total is nonnegative under activeMap (#459).
-- Prefer BuildDurableCreditFloorBaseline + ApplyCorrectionFloorDelta for rebuilds.
local function AllPersonalNonNegative(record, activeMap)
    if type(record) ~= "table" then
        return false
    end
    local totals, _, _, relationshipsReady = BuildDurableCreditFloorBaseline(record)
    if type(activeMap) == "table" then
        for eventId, head in pairs(activeMap) do
            if type(head) == "table" and type(eventId) == "string" then
                local event = GS.FindLedgerEventById(record, eventId)
                if event then
                    ApplyCorrectionFloorDelta(
                        record, totals, event,
                        NormName(head.attributed), ValidGuid(head.attributedGuid),
                        relationshipsReady, 1)
                end
            end
        end
    end
    return TotalsAllNonNegative(totals)
end

local creditProjectionCache = setmetatable({}, { __mode = "k" })
local creditProjectionContinuation = setmetatable({}, { __mode = "k" })

local function CreditProjectionDependencyStamp(record)
    local opsGen = 0
    if GS.GetOpsValidationGen then
        opsGen = GS.GetOpsValidationGen(record.operations) or 0
    end
    local acctMut = GS.GetAccountingMutationSeq and GS.GetAccountingMutationSeq(record) or 0
    return tostring(opsGen) .. ":" .. tostring(acctMut) .. ":" .. tostring(record.datasetId or "")
end

--- Effective per-callback work ceiling (#459). Override is test-only.
local function CreditProjectionSliceBudget()
    local override = tonumber(GS._creditProjectionWorkBudgetOverride)
    if override and override > 0 then
        return override
    end
    return tonumber(GS.CREDIT_PROJECTION_WORK_BUDGET) or 16384
end

local function CreditProjectionAtomicOvershoot()
    local override = tonumber(GS._creditProjectionAtomicOvershootOverride)
    if override and override >= 0 then
        return override
    end
    return tonumber(GS.CREDIT_PROJECTION_ATOMIC_OVERSHOOT) or 512
end

local function CreditProjectionWorkNow(rowVisits)
    return (tonumber(rowVisits) or 0)
        + (tonumber(GS._creditProjectionBucketVisits) or 0)
        + (tonumber(GS._creditProjectionFloorVisits) or 0)
        + (tonumber(GS._creditProjectionCandidateTrials) or 0)
        + (tonumber(GS._creditProjectionStructureCopyVisits) or 0)
        + (tonumber(GS._creditProjectionTraversalVisits) or 0)
        + (tonumber(GS._creditProjectionProvenanceVisits) or 0)
end

--- Begin a fresh callback budget, or keep nesting under the parent allowance.
local function BeginCreditProjectionCallbackBudget(share)
    if not share then
        local budget = CreditProjectionSliceBudget()
        GS._creditProjectionCallbackWork = 0
        GS._creditProjectionCallbackLimit = budget
        GS._creditProjectionCallbackHardLimit = budget + CreditProjectionAtomicOvershoot()
    end
    GS._creditProjectionAccumulating = true
end

local function EndCreditProjectionCallbackBudget()
    GS._creditProjectionAccumulating = false
end

--- Open an outer callback allowance when none is active (#459).
-- @return boolean owned true when this caller must EndOuter later
function GS.BeginOuterCreditProjectionCallbackBudget()
    if GS._creditProjectionAccumulating then
        return false
    end
    BeginCreditProjectionCallbackBudget(false)
    return true
end

--- Close an outer allowance only when BeginOuter returned owned=true.
function GS.EndOuterCreditProjectionCallbackBudget(owned)
    if owned then
        EndCreditProjectionCallbackBudget()
    end
end

--- One outer callback allowance for accepted-history Ensure then pending redrive.
-- Production wakes must not open a second full slice after Ensure returns.
-- Nested callers share the caller's already-consumed allowance; only this
-- boundary closes a budget it opened. Exhausted soft limit merges/schedules
-- remaining redrive work rather than resetting the counter.
-- @param record table
-- @param redriveOpts table|nil filters for RedrivePendingContributorCorrections
function GS.EnsureThenRedriveCreditCorrections(record, redriveOpts)
    if type(record) ~= "table" then
        return
    end
    local owned = false
    if not GS._creditProjectionAccumulating then
        BeginCreditProjectionCallbackBudget(false)
        owned = true
    end
    if GS.EnsureCreditCorrectionProjection then
        GS.EnsureCreditCorrectionProjection(record, nil)
    end
    if GS.RedrivePendingContributorCorrections then
        local opts = type(redriveOpts) == "table" and redriveOpts or {}
        if opts._shareCallbackBudget ~= true then
            local shared = {}
            for k, v in pairs(opts) do
                shared[k] = v
            end
            shared._shareCallbackBudget = true
            opts = shared
        end
        GS.RedrivePendingContributorCorrections(record, opts)
    end
    if owned then
        EndCreditProjectionCallbackBudget()
    end
end

--- Work already charged this callback plus in-progress local rebuild units.
local function CreditProjectionCallbackWorkTotal(localWork)
    local base = 0
    if GS._creditProjectionAccumulating then
        base = tonumber(GS._creditProjectionCallbackWork) or 0
    end
    return base + (tonumber(localWork) or 0)
end

local function CreditProjectionSoftLimit()
    return tonumber(GS._creditProjectionCallbackLimit) or CreditProjectionSliceBudget()
end

local function CreditProjectionHardLimit()
    return tonumber(GS._creditProjectionCallbackHardLimit)
        or (CreditProjectionSoftLimit() + CreditProjectionAtomicOvershoot())
end

local function AccumulateCreditProjectionCallbackWork(workUnits)
    if not GS._creditProjectionAccumulating then
        return
    end
    GS._creditProjectionCallbackWork =
        (tonumber(GS._creditProjectionCallbackWork) or 0) + (tonumber(workUnits) or 0)
end

--- Fold a finished rebuild slice into the shared callback total and clear local
-- visit counters so a later fold/observe cannot double-count (#459 G2).
local function AccumulateCreditProjectionSliceWork(workUnits)
    AccumulateCreditProjectionCallbackWork(workUnits)
    GS._creditProjectionRowVisits = 0
    GS._creditProjectionBucketVisits = 0
    GS._creditProjectionFloorVisits = 0
    GS._creditProjectionCandidateTrials = 0
    GS._creditProjectionStructureCopyVisits = 0
    GS._creditProjectionTraversalVisits = 0
    GS._creditProjectionProvenanceVisits = 0
end

-- Ephemeral paced-rebuild scratch (not durable / not another ledger authority).
-- Scratch is ownership-keyed: accepted-history and each speculative extraOp
-- keep private paused state so admission previews cannot clobber a pause.
local creditProjectionScratchAccepted = setmetatable({}, { __mode = "k" })
local creditProjectionScratchSpeculative = setmetatable({}, { __mode = "k" })
-- Accepted published map validity for the current dependency stamp. Distinct
-- from "creditCorrections is a table": Invalidate / incomplete accepted rebuild
-- clear this so speculative pauses cannot resurrect stale readable credit (#459).
local acceptedCreditValidStamp = setmetatable({}, { __mode = "k" })

local function MarkAcceptedCreditInvalid(record)
    if type(record) ~= "table" then
        return
    end
    acceptedCreditValidStamp[record] = nil
    record.creditCorrections = nil
end

local function MarkAcceptedCreditValid(record, stamp)
    if type(record) ~= "table" then
        return
    end
    acceptedCreditValidStamp[record] = stamp or CreditProjectionDependencyStamp(record)
end

local function IsSpeculativeCreditProjectionOp(ops, extraOp)
    return type(extraOp) == "table"
        and not (type(ops) == "table" and type(ops.records) == "table"
            and ops.records[extraOp.id])
end

local function ReadCreditProjectionScratch(record, speculative, extraOp)
    if type(record) ~= "table" then
        return nil
    end
    if speculative and type(extraOp) == "table" and type(extraOp.id) == "string" then
        local bag = creditProjectionScratchSpeculative[record]
        if type(bag) == "table" then
            return bag[extraOp.id]
        end
        return nil
    end
    return creditProjectionScratchAccepted[record]
end

local function WriteCreditProjectionScratch(record, speculative, extraOp, value)
    if type(record) ~= "table" then
        return
    end
    if speculative and type(extraOp) == "table" and type(extraOp.id) == "string" then
        local bag = creditProjectionScratchSpeculative[record]
        if type(bag) ~= "table" then
            bag = {}
            creditProjectionScratchSpeculative[record] = bag
        end
        bag[extraOp.id] = value
        return
    end
    creditProjectionScratchAccepted[record] = value
end

local function ClearCreditProjectionScratch(record)
    if type(record) == "table" then
        creditProjectionScratchAccepted[record] = nil
        creditProjectionScratchSpeculative[record] = nil
    end
end

local function ClearSpeculativeCreditProjectionScratch(record, op)
    if type(record) ~= "table" then
        return
    end
    local bag = creditProjectionScratchSpeculative[record]
    if type(bag) ~= "table" then
        return
    end
    local opId = type(op) == "table" and op.id or nil
    if type(opId) == "string" then
        bag[opId] = nil
    else
        creditProjectionScratchSpeculative[record] = nil
    end
end

local function CloneCreditProjectionTotals(totals)
    local copy = {}
    if type(totals) ~= "table" then
        return copy
    end
    local n = 0
    for k, v in pairs(totals) do
        copy[k] = v
        n = n + 1
    end
    if n > 0 then
        GS._creditProjectionStructureCopyVisits =
            (tonumber(GS._creditProjectionStructureCopyVisits) or 0) + n
    end
    return copy
end

--- Drop a speculative preview resume so timers cannot publish a rejected edit.
local function DiscardSpeculativeCreditProjectionResume(record, op)
    if type(record) ~= "table" then
        return
    end
    local cached = creditProjectionCache[record]
    if type(cached) == "table" and type(cached.resume) == "table" then
        local resume = cached.resume
        if resume.speculative then
            local opId = type(op) == "table" and op.id or nil
            if not (type(resume.extraOpId) == "string"
                and type(opId) == "string"
                and resume.extraOpId ~= opId) then
                creditProjectionCache[record] = nil
                local cont = creditProjectionContinuation[record]
                if type(cont) == "table" then
                    cont.scheduled = false
                end
            end
        end
    end
    -- Never clear accepted-history scratch when discarding a speculative preview.
    ClearSpeculativeCreditProjectionScratch(record, op)
end

local ScheduleCreditProjectionContinuation

ScheduleCreditProjectionContinuation = function(record)
    if type(record) ~= "table" then
        return
    end
    -- Without a timer, finish inline on the next Rebuild caller instead of
    -- recursively draining here (keeps one unit of work per callback).
    if not (C_Timer and C_Timer.After) then
        return
    end
    -- Never background-resume a speculative preview op; only accepted history.
    local cached = creditProjectionCache[record]
    if type(cached) == "table" and type(cached.resume) == "table"
        and cached.resume.speculative then
        return
    end
    -- Scheduling accepted-history continuation means reconstruction is incomplete:
    -- clear published validity so Ensure cannot serve a stale map (#459 B3).
    MarkAcceptedCreditInvalid(record)
    local cont = creditProjectionContinuation[record]
    if type(cont) ~= "table" then
        cont = {}
        creditProjectionContinuation[record] = cont
    end
    if cont.scheduled then
        return
    end
    cont.scheduled = true
    local function run()
        local state = creditProjectionContinuation[record]
        if type(state) ~= "table" then
            return
        end
        state.scheduled = false
        local prior = creditProjectionCache[record]
        local fromAcceptedBudget = type(prior) == "table"
            and prior.err == "work_budget"
            and not (type(prior.resume) == "table" and prior.resume.speculative)
        BeginCreditProjectionCallbackBudget(false)
        local ok, err = false, nil
        if GS.RebuildCreditCorrectionProjection then
            -- Accepted-history only — never pass resume.extraOp here.
            ok, err = GS.RebuildCreditCorrectionProjection(record, nil)
        end
        if (ok or err ~= "work_budget")
            and GS.RedrivePendingContributorCorrections then
            -- Share remaining callback allowance with nested redrive.
            GS.RedrivePendingContributorCorrections(record, {
                _shareCallbackBudget = true,
            })
        end
        EndCreditProjectionCallbackBudget()
        -- One coalesced UI-only notify for accepted-history work_budget→terminal
        -- after publication/budget cleanup (#459 / discussion_r4480421491).
        -- No per-slice notifies; do not invalidate the just-completed projection.
        if fromAcceptedBudget and (ok or err ~= "work_budget") then
            if GS.NotifyUI then
                GS.NotifyUI("credit-projection-ready")
            end
        end
    end
    C_Timer.After(0, run)
end

---------------------------------------------------------------------------
-- Authorized local correction save resume (#459 / discussion_r4480434323)
--
-- Owner: one private pending entry per record (immutable op body + captured
--        recipient/head/context). Never ops.pending / AdmitRemote.
-- Lifetime: first local work_budget → accept | cancel | context invalidation.
-- Cancellation: ClearEditSession / OpenEdit replacement / GI invalidation /
--               Continue detecting stale authority, guild, dataset, campaign,
--               expected head, or captured recipient. No later mutation.
-- Preserve approved accounting/floor policy; complete via LOCAL commit path.
---------------------------------------------------------------------------
local localCorrectionSavePending = setmetatable({}, { __mode = "k" })
local localCorrectionSaveContinuation = setmetatable({}, { __mode = "k" })

local ScheduleLocalContributorCorrectionSaveContinuation

function GS.CancelLocalContributorCorrectionSave(record, reason, opts)
    if type(record) ~= "table" then
        return
    end
    local entry = localCorrectionSavePending[record]
    localCorrectionSavePending[record] = nil
    local cont = localCorrectionSaveContinuation[record]
    if type(cont) == "table" then
        cont.scheduled = false
    end
    if type(entry) == "table" and type(entry.op) == "table" then
        DiscardSpeculativeCreditProjectionResume(record, entry.op)
    end
    -- Timer-driven terminal cancel only: publish one coalesced UI-only notify so
    -- Logs can clear pendingLocal and report cancellation (#459 / discussion_r4484516439).
    -- Skip invalidate/session_cleared/recipient_changed to avoid notify loops.
    opts = opts or {}
    if type(entry) == "table" and (opts.notifyUI == true) and GS.NotifyUI then
        GS.NotifyUI("local-correction-cancelled")
    end
    reason = reason -- keep reason available for callers/diagnostics
end

--- Drop the retain slot after a successful local accept without discarding the
-- speculative scratch that Seal/StoreAccepted is about to promote.
function GS._ClearLocalContributorCorrectionSaveRetain(record)
    if type(record) ~= "table" then
        return
    end
    localCorrectionSavePending[record] = nil
    local cont = localCorrectionSaveContinuation[record]
    if type(cont) == "table" then
        cont.scheduled = false
    end
end

function GS.GetLocalContributorCorrectionSave(record)
    local entry = type(record) == "table" and localCorrectionSavePending[record]
    if type(entry) ~= "table" or type(entry.op) ~= "table" then
        return nil
    end
    return entry
end

local function RetainLocalContributorCorrectionSave(record, op, meta)
    if type(record) ~= "table" or type(op) ~= "table" or type(op.id) ~= "string" then
        return false
    end
    local prior = localCorrectionSavePending[record]
    if type(prior) == "table" and type(prior.op) == "table" and prior.op.id ~= op.id then
        DiscardSpeculativeCreditProjectionResume(record, prior.op)
    end
    localCorrectionSavePending[record] = {
        op = op,
        guildKey = meta and meta.guildKey or op.guildKey,
        datasetId = meta and meta.datasetId or op.datasetId,
        campaignId = meta and meta.campaignId or op.campaignId,
        eventId = op.target,
        baseTargetRevision = op.baseTargetRevision,
        baseAttributed = op.value and op.value.baseAttributed,
        baseAttributedGuid = op.value and op.value.baseAttributedGuid,
        attributed = op.value and op.value.attributed,
        attributedGuid = op.value and op.value.attributedGuid,
    }
    return true
end

local function LocalContributorCorrectionSaveStillValid(record, entry)
    if type(record) ~= "table" or type(entry) ~= "table" or type(entry.op) ~= "table" then
        return false, "invalid_operation"
    end
    local op = entry.op
    local caps = GS.GetCapabilities and GS:GetCapabilities() or nil
    if not (caps and caps.canEdit) then
        return false, (caps and caps.reason) or "unauthorized"
    end
    local ctx = GS.GetCurrentContext and GS:GetCurrentContext() or nil
    if type(ctx) ~= "table" or ctx.guildKey ~= entry.guildKey then
        return false, "stale_guild"
    end
    local live, liveReason = GS.GetCurrentRecord and GS:GetCurrentRecord() or nil, nil
    if live ~= record then
        return false, liveReason or "not_configured"
    end
    if record.datasetId ~= entry.datasetId then
        return false, "dataset_mismatch"
    end
    if record.currentCampaignId ~= entry.campaignId then
        return false, "stale_campaign"
    end
    if op.datasetId ~= record.datasetId or op.campaignId ~= record.currentCampaignId then
        return false, "stale_campaign"
    end
    local event = GS.FindLedgerEventById and GS.FindLedgerEventById(record, entry.eventId)
    if not event then
        return false, "missing_event"
    end
    local curName, curGuid, _, creditStatus = nil, nil, nil, nil
    if GS.ResolveEffectiveCreditIdentity then
        curName, curGuid, _, creditStatus = GS.ResolveEffectiveCreditIdentity(record, event)
    end
    if creditStatus == GS.CREDIT_UNAVAILABLE then
        return false, GS.CREDIT_UNAVAILABLE
    end
    if GS.CreditIdentities and GS.CreditIdentities.equal then
        if not GS.CreditIdentities.equal(
            curName, curGuid, entry.baseAttributed, entry.baseAttributedGuid) then
            return false, "stale_credit"
        end
    end
    local tKey = GS.CorrectionTargetKey and GS.CorrectionTargetKey(record, entry.eventId)
        or (GS.ComputeTargetKey and GS.ComputeTargetKey(
            GS.KIND and GS.KIND.CORRECT_CONTRIBUTOR, entry.eventId))
    local headId = tKey and record.operations and record.operations.heads
        and record.operations.heads[tKey]
    local expected = entry.baseTargetRevision
    local noPriorHead = expected == nil or expected == record.datasetId
    if noPriorHead then
        if headId ~= nil then
            return false, "stale_credit"
        end
    elseif expected ~= headId then
        return false, "stale_credit"
    end
    return true, nil, op
end

function GS.ContinueLocalContributorCorrectionSave(record)
    local entry = type(record) == "table" and localCorrectionSavePending[record]
    local cont = localCorrectionSaveContinuation[record]
    if type(cont) == "table" then
        cont.scheduled = false
    end
    if type(entry) ~= "table" then
        return false, "missing"
    end
    local okValid, validErr, op = LocalContributorCorrectionSaveStillValid(record, entry)
    if not okValid then
        GS.CancelLocalContributorCorrectionSave(record, validErr or "stale_credit", {
            notifyUI = true,
        })
        return false, validErr or "stale_credit"
    end
    if type(GS.ApplyStagedConfigOperation) ~= "function" then
        GS.CancelLocalContributorCorrectionSave(record, "unsupported_kind", {
            notifyUI = true,
        })
        return false, "unsupported_kind"
    end
    local status, reason = GS:ApplyStagedConfigOperation(op)
    if status == "pending" and reason == "work_budget" then
        ScheduleLocalContributorCorrectionSaveContinuation(record)
        return false, "work_budget"
    end
    if status == "accepted" or status == "duplicate" then
        localCorrectionSavePending[record] = nil
        return true, status
    end
    GS.CancelLocalContributorCorrectionSave(record, reason or status or "rejected", {
        notifyUI = true,
    })
    return false, reason or status or "rejected"
end

ScheduleLocalContributorCorrectionSaveContinuation = function(record)
    if type(record) ~= "table" then
        return
    end
    if not (C_Timer and C_Timer.After) then
        return
    end
    if type(localCorrectionSavePending[record]) ~= "table" then
        return
    end
    local cont = localCorrectionSaveContinuation[record]
    if type(cont) ~= "table" then
        cont = {}
        localCorrectionSaveContinuation[record] = cont
    end
    if cont.scheduled then
        return
    end
    cont.scheduled = true
    C_Timer.After(0, function()
        local state = localCorrectionSaveContinuation[record]
        if type(state) ~= "table" or state.scheduled ~= true then
            -- Cancelled while queued.
            if type(state) == "table" then
                state.scheduled = false
            end
            return
        end
        state.scheduled = false
        if GS.ContinueLocalContributorCorrectionSave then
            GS.ContinueLocalContributorCorrectionSave(record)
        end
    end)
end

function GS.RetainLocalContributorCorrectionSave(record, op, meta)
    return RetainLocalContributorCorrectionSave(record, op, meta)
end

function GS.ScheduleLocalContributorCorrectionSaveContinuation(record)
    return ScheduleLocalContributorCorrectionSaveContinuation(record)
end

--- Invalidate cached credit projection after dependency mutations (#459).
function GS.InvalidateCreditCorrectionProjection(record)
    if type(record) == "table" then
        -- Drop in-flight authorized local save with the projection it depends on.
        if GS.CancelLocalContributorCorrectionSave then
            GS.CancelLocalContributorCorrectionSave(record, "invalidate")
        end
        creditProjectionCache[record] = nil
        ClearCreditProjectionScratch(record)
        -- Clear published accepted credit so Invalidate cannot leave a readable
        -- stale map for Ensure's speculative shortcut or Resolve (#459 B3).
        MarkAcceptedCreditInvalid(record)
        local cont = creditProjectionContinuation[record]
        if type(cont) == "table" then
            cont.scheduled = false
        end
    end
end

--- Rebuild creditCorrections from accepted correct-contributor ops (#459).
-- Deterministic active-head policy:
--   1) LWW winner per canonical event
--   2) Activate *all* production-credited winners that bind
--   3) While floors fail, deactivate the head whose removal maximizes
--      TotalsNegScore (O(1) bucket deltas); ties drop older.
--   4) If prune stalls, empty only item groups that still have negative
--      floors — independent items keep deduction-supporting heads.
--   5) Never leave a stale active map; never mark a negative projection ok.
--      Failed reconstructions cache under the stamp; Resolve returns nil
--      (unavailable) rather than durable fallback.
-- Conflict prune yields when projection work reaches CREDIT_PROJECTION_WORK_BUDGET
-- (independent of fixture cost); resume continues via C_Timer.After(0).
-- Floor checks use one durable ledger baseline plus O(1) deltas per head.
-- Alias targets resolve through the baseline id/txn + one linear registry pass.
-- @param extraOp table|nil op not yet in ops.records (apply-time preview)
-- @return boolean ok, string|nil err, table|nil details
function GS.RebuildCreditCorrectionProjection(record, extraOp)
    if type(record) ~= "table" then
        return false, "invalid_value"
    end
    local ops = record.operations
    local stampEarly = CreditProjectionDependencyStamp(record)
    local priorCache = creditProjectionCache[record]
    -- Fresh entry (not a work_budget resume): fold cold Bind/Ensure provenance
    -- into the shared callback total before resetting counters. Resume paths
    -- already Accumulated their slice — folding again would double-count (#459 G2).
    local resumingBudget = type(priorCache) == "table" and priorCache.stamp == stampEarly
        and priorCache.err == "work_budget" and type(priorCache.resume) == "table"
    if not resumingBudget and GS._creditProjectionAccumulating then
        local priorProv = tonumber(GS._creditProjectionProvenanceVisits) or 0
        if priorProv > 0 then
            AccumulateCreditProjectionCallbackWork(priorProv)
        end
    end
    GS._creditProjectionRowVisits = 0
    GS._creditProjectionLookupMisses = 0
    GS._creditProjectionDeactivations = 0
    GS._creditProjectionBucketVisits = 0
    GS._creditProjectionFloorVisits = 0
    GS._creditProjectionCandidateTrials = 0
    GS._creditProjectionStructureCopyVisits = 0
    GS._creditProjectionTraversalVisits = 0
    GS._creditProjectionProvenanceVisits = 0
    -- Drop a prior active provenance view; baseline republishes when ready (#459).
    creditProvenanceIndexActive[record] = nil
    local resumeDeactivated = nil
    local resumePhase = nil
    local resumeScan = nil
    -- Resume an interrupted paced rebuild (same dependency stamp).
    -- Speculative extraOp resumes only when the caller re-supplies that exact op
    -- (Apply/Admit). Accepted-history Rebuild(nil) never adopts a preview op.
    if type(priorCache) == "table" and priorCache.stamp == stampEarly
        and priorCache.err == "work_budget"
        and type(priorCache.resume) == "table" then
        local resume = priorCache.resume
        resumePhase = resume.phase
        if type(extraOp) == "table" and resume.speculative
            and type(resume.extraOp) == "table"
            and resume.extraOp.id == extraOp.id then
            resumeDeactivated = resume.deactivatedEventIds
            resumeScan = resume.scan
        elseif type(extraOp) ~= "table" and not resume.speculative then
            resumeDeactivated = resume.deactivatedEventIds
            resumeScan = resume.scan
        elseif type(extraOp) ~= "table" and resume.speculative then
            -- Stale speculative pause must not affect accepted-history rebuild.
            resumeDeactivated = nil
            resumePhase = nil
            resumeScan = nil
        end
    end
    -- Top-level Rebuild/Ensure opens a callback budget when not nested.
    if not GS._creditProjectionAccumulating then
        BeginCreditProjectionCallbackBudget(false)
        GS._creditProjectionOwnedCallbackBudget = true
    else
        GS._creditProjectionOwnedCallbackBudget = false
    end
    local speculative = IsSpeculativeCreditProjectionOp(ops, extraOp)
    local function readScratch()
        return ReadCreditProjectionScratch(record, speculative, extraOp)
    end
    local function writeScratch(value)
        WriteCreditProjectionScratch(record, speculative, extraOp, value)
    end
    local scratch = readScratch()
    -- Dependency generation gate: never reuse candidates/cursors/phase from a
    -- prior stamp (Seal/admission can advance the generation while owner scratch
    -- and timers still linger).
    if type(scratch) == "table" and scratch.stamp ~= stampEarly then
        writeScratch(nil)
        scratch = nil
    end
    -- Speculative callers must not adopt or mutate accepted-history pauses.
    if type(scratch) == "table" and scratch.stamp == stampEarly then
        if speculative and scratch.ownerSpeculative ~= true then
            scratch = nil
        elseif (not speculative) and scratch.ownerSpeculative == true then
            scratch = nil
        end
    end
    local skipToPrune = type(scratch) == "table" and scratch.stamp == stampEarly
        and scratch.pruneReady == true
        and type(scratch.pruneTotals) == "table"
        and type(scratch.pruneBound) == "table"
        and type(scratch.pruneActiveMap) == "table"
        and type(scratch.pruneActiveIds) == "table"
    local skipToActivate = type(scratch) == "table" and scratch.stamp == stampEarly
        and scratch.activateReady == true
        and type(scratch.ordered) == "table"
        and type(scratch.pruneTotals) == "table"
        and type(scratch.pruneBound) == "table"
        and type(scratch.pruneActiveMap) == "table"
        and type(scratch.pruneActiveIds) == "table"
    local skipToRestore = type(scratch) == "table" and scratch.stamp == stampEarly
        and scratch.restoreReady == true
        and type(scratch.ordered) == "table"
        and type(scratch.pruneTotals) == "table"
        and type(scratch.pruneBound) == "table"
        and type(scratch.pruneActiveMap) == "table"
        and type(scratch.pruneActiveIds) == "table"
    local skipToFallback = type(scratch) == "table" and scratch.stamp == stampEarly
        and scratch.fallbackReady == true
        and type(scratch.ordered) == "table"
        and type(scratch.pruneTotals) == "table"
        and type(scratch.pruneBound) == "table"
        and type(scratch.pruneActiveMap) == "table"
        and type(scratch.pruneActiveIds) == "table"
    local skipToBaseline = type(scratch) == "table" and scratch.stamp == stampEarly
        and scratch.baselineReady == false
        and type(scratch.baselineTotals) == "table"
        and type(scratch.baselineById) == "table"
    local haveOrderedScratch = type(scratch) == "table" and scratch.stamp == stampEarly
        and type(scratch.ordered) == "table"
        and type(scratch.baselineTotals) == "table"
    local skipToCollect = type(scratch) == "table" and scratch.stamp == stampEarly
        and type(scratch.candidates) == "table"
        and tonumber(scratch.collectIndex) ~= nil
        and not (skipToPrune or skipToActivate or skipToRestore or skipToFallback or skipToBaseline
            or haveOrderedScratch)
    -- Owner-keyed prune comparison progress (cursor / best-so-far).
    if type(scratch) == "table" and scratch.stamp == stampEarly
        and type(scratch.pruneScan) == "table" then
        resumeScan = scratch.pruneScan
    end
    if type(scratch) == "table" and scratch.stamp == stampEarly
        and type(scratch.deactivatedEventIds) == "table" then
        resumeDeactivated = scratch.deactivatedEventIds
    end
    -- Skip ops.records walks when ordered/working state is already retained.
    -- Candidates only from current-stamp scratch (stamp gate above).
    local candidates = scratch and scratch.candidates or nil
    if type(candidates) ~= "table" then
        candidates = {}
    end
    local function considerOp(op)
        GS._creditProjectionTraversalVisits =
            (tonumber(GS._creditProjectionTraversalVisits) or 0) + 1
        if type(op) ~= "table" or op.kind ~= (GS.KIND and GS.KIND.CORRECT_CONTRIBUTOR) then
            return
        end
        if type(op.id) ~= "string" or op.id == "" then
            return
        end
        if type(op.target) ~= "string" or op.target == "" then
            return
        end
        if type(op.value) ~= "table" then
            return
        end
        candidates[#candidates + 1] = op
    end
    local function deferCandidates(collectIndex, collectIds, collectOrderIndex, collectIdsReady)
        writeScratch({
            stamp = stampEarly,
            candidates = candidates,
            collectIndex = collectIndex,
            collectIds = collectIds,
            collectOrderIndex = collectOrderIndex,
            collectIdsReady = collectIdsReady and true or false,
            ownerSpeculative = speculative and true or false,
            ownerOpId = speculative and extraOp.id or nil,
        })
        creditProjectionCache[record] = {
            stamp = stampEarly,
            ok = false,
            err = "work_budget",
            resume = {
                deactivatedEventIds = {},
                phase = "collect",
                speculative = speculative and true or false,
                extraOp = speculative and extraOp or nil,
                extraOpId = speculative and extraOp.id or nil,
            },
        }
        -- Incomplete accepted reconstruction is not readable (#459 B3).
        if not speculative then
            MarkAcceptedCreditInvalid(record)
        end
        local workUnits = CreditProjectionWorkNow(0)
        AccumulateCreditProjectionSliceWork(workUnits)
        if not speculative then
            ScheduleCreditProjectionContinuation(record)
        end
        if GS._creditProjectionOwnedCallbackBudget then
            EndCreditProjectionCallbackBudget()
            GS._creditProjectionOwnedCallbackBudget = false
        end
        return false, "work_budget", {
            traversalVisits = tonumber(GS._creditProjectionTraversalVisits) or 0,
            workUnits = workUnits,
            deferred = true,
            phase = "collect",
            speculative = speculative and true or false,
            callbackWork = CreditProjectionCallbackWorkTotal(0),
        }
    end
    if not (skipToPrune or skipToActivate or skipToRestore or skipToFallback or skipToBaseline
        or haveOrderedScratch or (#candidates > 0 and not skipToCollect)) then
        candidates = {}
        local softLimitEarly = CreditProjectionSoftLimit()
        local hardLimitEarly = CreditProjectionHardLimit()
        local allowDeferEarly = (C_Timer and C_Timer.After) and true or false
        -- Stable paced collection via ops.order when present; else id snapshot.
        local collectIds = scratch and scratch.collectIds or nil
        local collectIndex = 1
        local collectOrderIndex = 1
        local collectIdsReady = false
        if skipToCollect then
            collectIds = scratch.collectIds
            collectIndex = tonumber(scratch.collectIndex) or 1
            collectOrderIndex = tonumber(scratch.collectOrderIndex) or 1
            collectIdsReady = scratch.collectIdsReady == true
            candidates = scratch.candidates or {}
        end
        if type(collectIds) ~= "table" then
            collectIds = {}
        end
        if not collectIdsReady then
            if type(ops) == "table" and type(ops.order) == "table" then
                for oi = collectOrderIndex, #ops.order do
                    GS._creditProjectionTraversalVisits =
                        (tonumber(GS._creditProjectionTraversalVisits) or 0) + 1
                    collectIds[#collectIds + 1] = ops.order[oi]
                    local now = CreditProjectionWorkNow(0)
                    if allowDeferEarly and (CreditProjectionCallbackWorkTotal(now) >= softLimitEarly
                        or CreditProjectionCallbackWorkTotal(now) >= hardLimitEarly) then
                        return deferCandidates(1, collectIds, oi + 1, false)
                    end
                end
                collectIdsReady = true
            elseif type(ops) == "table" and type(ops.records) == "table" then
                -- Unordered snapshot: finish id list without mid-pairs yield
                -- (pairs order is not stable); pace considerOp via collectIndex.
                if #collectIds == 0 then
                    for id, _ in pairs(ops.records) do
                        GS._creditProjectionTraversalVisits =
                            (tonumber(GS._creditProjectionTraversalVisits) or 0) + 1
                        collectIds[#collectIds + 1] = id
                    end
                end
                collectIdsReady = true
            else
                collectIdsReady = true
            end
        end
        local records = type(ops) == "table" and ops.records or nil
        for ci = collectIndex, #collectIds do
            local id = collectIds[ci]
            local op = type(records) == "table" and records[id] or nil
            considerOp(op)
            local now = CreditProjectionWorkNow(0)
            if allowDeferEarly and (CreditProjectionCallbackWorkTotal(now) >= softLimitEarly
                or CreditProjectionCallbackWorkTotal(now) >= hardLimitEarly) then
                return deferCandidates(ci + 1, collectIds, collectOrderIndex, true)
            end
        end
        if type(extraOp) == "table" then
            -- Pace dedup under the shared remainder; a full unpaced scan of
            -- thousands of candidates can exceed soft+atomic in one step.
            local seen = scratch and scratch.extraOpSeen == true
            local extraScanIndex = 1
            if skipToCollect and tonumber(scratch and scratch.extraScanIndex) then
                extraScanIndex = tonumber(scratch.extraScanIndex)
                seen = scratch.extraOpSeen == true
            end
            if not seen then
                for i = extraScanIndex, #candidates do
                    GS._creditProjectionTraversalVisits =
                        (tonumber(GS._creditProjectionTraversalVisits) or 0) + 1
                    if candidates[i].id == extraOp.id then
                        seen = true
                        break
                    end
                    local now = CreditProjectionWorkNow(0)
                    if allowDeferEarly and (CreditProjectionCallbackWorkTotal(now) >= softLimitEarly
                        or CreditProjectionCallbackWorkTotal(now) >= hardLimitEarly) then
                        writeScratch({
                            stamp = stampEarly,
                            candidates = candidates,
                            collectIndex = #collectIds + 1,
                            collectIds = collectIds,
                            collectOrderIndex = collectOrderIndex,
                            collectIdsReady = true,
                            extraScanIndex = i + 1,
                            extraOpSeen = false,
                            ownerSpeculative = speculative and true or false,
                            ownerOpId = speculative and extraOp.id or nil,
                        })
                        creditProjectionCache[record] = {
                            stamp = stampEarly,
                            ok = false,
                            err = "work_budget",
                            resume = {
                                deactivatedEventIds = {},
                                phase = "collect",
                                speculative = speculative and true or false,
                                extraOp = speculative and extraOp or nil,
                                extraOpId = speculative and extraOp.id or nil,
                            },
                        }
                        local workUnits = CreditProjectionWorkNow(0)
                        AccumulateCreditProjectionSliceWork(workUnits)
                        if not speculative then
                            ScheduleCreditProjectionContinuation(record)
                        end
                        if GS._creditProjectionOwnedCallbackBudget then
                            EndCreditProjectionCallbackBudget()
                            GS._creditProjectionOwnedCallbackBudget = false
                        end
                        return false, "work_budget", {
                            traversalVisits = tonumber(GS._creditProjectionTraversalVisits) or 0,
                            workUnits = workUnits,
                            deferred = true,
                            phase = "collect",
                            speculative = speculative and true or false,
                            callbackWork = CreditProjectionCallbackWorkTotal(0),
                        }
                    end
                end
            end
            if not seen then
                considerOp(extraOp)
            end
            local now = CreditProjectionWorkNow(0)
            if allowDeferEarly and (CreditProjectionCallbackWorkTotal(now) >= softLimitEarly
                or CreditProjectionCallbackWorkTotal(now) >= hardLimitEarly) then
                return deferCandidates(#collectIds + 1, collectIds, collectOrderIndex, true)
            end
        end
    elseif type(extraOp) == "table" and not (skipToPrune or skipToActivate)
        and haveOrderedScratch then
        -- Ordered already built; extraOp speculative path uses ordered+extra separately.
    end
    -- No correction ops: publish empty active set without scanning the ledger
    -- (keeps ordinary progress projection readiness-bounded — #427 / #459).
    if not (skipToPrune or skipToActivate or skipToRestore or skipToFallback or skipToBaseline or haveOrderedScratch) and #candidates == 0 then
        local emptyStamp = CreditProjectionDependencyStamp(record)
        record.creditCorrections = {}
        creditProjectionCache[record] = {
            stamp = emptyStamp,
            ok = true,
        }
        MarkAcceptedCreditValid(record, emptyStamp)
        writeScratch(nil)
        if GS._creditProjectionOwnedCallbackBudget then
            EndCreditProjectionCallbackBudget()
            GS._creditProjectionOwnedCallbackBudget = false
        end
        return true, nil, {
            activeIds = {},
            rowVisits = 0,
            bucketVisits = 0,
            deactivations = 0,
            lookupMisses = 0,
        }
    end
    -- Soft yield after charged candidate collection when allowance already spent.
    do
        local softLimit = CreditProjectionSoftLimit()
        local allowDefer = (C_Timer and C_Timer.After) and true or false
        if allowDefer and not (skipToPrune or skipToActivate or skipToRestore or skipToFallback or skipToBaseline or haveOrderedScratch)
            and CreditProjectionCallbackWorkTotal(CreditProjectionWorkNow(0)) >= softLimit then
            writeScratch({
                stamp = stampEarly,
                candidates = candidates,
                ownerSpeculative = speculative and true or false,
                ownerOpId = speculative and extraOp.id or nil,
            })
            creditProjectionCache[record] = {
                stamp = stampEarly,
                ok = false,
                err = "work_budget",
                resume = {
                    deactivatedEventIds = {},
                    phase = "post_candidates",
                    speculative = speculative and true or false,
                    extraOp = speculative and extraOp or nil,
                    extraOpId = speculative and extraOp.id or nil,
                },
            }
            local workUnits = CreditProjectionWorkNow(0)
            AccumulateCreditProjectionSliceWork(workUnits)
            if not speculative then
                ScheduleCreditProjectionContinuation(record)
            end
            if GS._creditProjectionOwnedCallbackBudget then
                EndCreditProjectionCallbackBudget()
                GS._creditProjectionOwnedCallbackBudget = false
            end
            return false, "work_budget", {
                traversalVisits = tonumber(GS._creditProjectionTraversalVisits) or 0,
                workUnits = workUnits,
                deferred = true,
                phase = "post_candidates",
                speculative = speculative and true or false,
            }
        end
    end
    -- Reuse scratch baseline/ordered when resuming the same dependency stamp.
    -- When prune/activate working tables are retained, skip baseline cloning.
    local totals, byId, rowVisits, relationshipsReady, ordered, lookupMisses
    local baselineTotals
    local resumeActivateIndex = nil
    local resumeRestoreIndex = nil
    if skipToPrune then
        -- Adopt retained private working state below; keep metadata from scratch.
        baselineTotals = scratch.baselineTotals
        byId = scratch.byId
        rowVisits = 0
        relationshipsReady = scratch.relationshipsReady
        ordered = scratch.ordered
        lookupMisses = scratch.lookupMisses or 0
        totals = scratch.pruneTotals
        GS._creditProjectionRowVisits = 0
    elseif skipToActivate then
        baselineTotals = scratch.baselineTotals
        byId = scratch.byId
        rowVisits = 0
        relationshipsReady = scratch.relationshipsReady
        ordered = scratch.ordered
        lookupMisses = scratch.lookupMisses or 0
        totals = scratch.pruneTotals
        resumeActivateIndex = tonumber(scratch.activateIndex) or 1
        GS._creditProjectionRowVisits = 0
    elseif skipToRestore then
        baselineTotals = scratch.baselineTotals
        byId = scratch.byId
        rowVisits = 0
        relationshipsReady = scratch.relationshipsReady
        ordered = scratch.ordered
        lookupMisses = scratch.lookupMisses or 0
        totals = scratch.pruneTotals
        resumeRestoreIndex = tonumber(scratch.restoreIndex) or 1
        GS._creditProjectionRowVisits = 0
    elseif skipToFallback then
        baselineTotals = scratch.baselineTotals
        byId = scratch.byId
        rowVisits = 0
        relationshipsReady = scratch.relationshipsReady
        ordered = scratch.ordered
        lookupMisses = scratch.lookupMisses or 0
        totals = scratch.pruneTotals
        GS._creditProjectionRowVisits = 0
    elseif haveOrderedScratch then
        -- Resume after post_baseline: one charged working clone from baseline.
        baselineTotals = scratch.baselineTotals
        totals = CloneCreditProjectionTotals(scratch.baselineTotals)
        byId = scratch.byId
        rowVisits = 0
        relationshipsReady = scratch.relationshipsReady
        ordered = scratch.ordered
        lookupMisses = scratch.lookupMisses or 0
        GS._creditProjectionRowVisits = 0
    elseif type(scratch) == "table" and scratch.stamp == stampEarly
        and type(scratch.winners) == "table"
        and tonumber(scratch.winnersIndex)
        and type(scratch.baselineTotals) == "table"
        and type(scratch.ordered) ~= "table" then
        -- Resume paced winner indexing; keep baseline immutable.
        baselineTotals = scratch.baselineTotals
        totals = CloneCreditProjectionTotals(baselineTotals)
        byId = scratch.byId
        rowVisits = tonumber(scratch.rowVisits) or 0
        relationshipsReady = scratch.relationshipsReady
        lookupMisses = scratch.lookupMisses or 0
        if type(scratch.candidates) == "table" then
            candidates = scratch.candidates
        end
        GS._creditProjectionRowVisits = rowVisits
        -- ordered remains nil → winners loop below runs.
    else
        -- Paced durable baseline (fresh or mid-baseline resume).
        local softLimitEarly = CreditProjectionSoftLimit()
        local allowDeferEarly = (C_Timer and C_Timer.After) and true or false
        local function baselineShouldYield(visits)
            if not allowDeferEarly then
                return false
            end
            return CreditProjectionCallbackWorkTotal(
                CreditProjectionWorkNow(visits or 0)) >= softLimitEarly
        end
        local baselineIn = nil
        if skipToBaseline then
            baselineIn = scratch
        end
        local baselineDone, baselineSnap, baselineVisits =
            ContinueDurableCreditFloorBaseline(record, baselineIn, baselineShouldYield)
        if not baselineDone then
            -- snapshot() returns snap, visits — capture both.
            if type(baselineSnap) ~= "table" then
                baselineSnap = {}
            end
            writeScratch({
                stamp = stampEarly,
                candidates = scratch and scratch.candidates or candidates,
                baselineReady = false,
                baselinePhase = baselineSnap.baselinePhase,
                baselineIndex = baselineSnap.baselineIndex,
                baselineTotals = baselineSnap.baselineTotals,
                baselineById = baselineSnap.baselineById,
                baselineProvenance = baselineSnap.baselineProvenance,
                baselineVisits = baselineSnap.baselineVisits,
                baselineRelationshipsReady = baselineSnap.baselineRelationshipsReady,
                baselineResolveCache = baselineSnap.baselineResolveCache,
                ownerSpeculative = speculative and true or false,
                ownerOpId = speculative and extraOp and extraOp.id or nil,
            })
            creditProjectionCache[record] = {
                stamp = stampEarly,
                ok = false,
                err = "work_budget",
                resume = {
                    deactivatedEventIds = {},
                    phase = "baseline",
                    speculative = speculative and true or false,
                    extraOp = speculative and extraOp or nil,
                    extraOpId = speculative and extraOp.id or nil,
                },
            }
            rowVisits = tonumber(baselineSnap.baselineVisits) or tonumber(baselineVisits) or 0
            GS._creditProjectionRowVisits = rowVisits
            local workUnits = CreditProjectionWorkNow(rowVisits)
            AccumulateCreditProjectionSliceWork(workUnits)
            if not speculative then
                ScheduleCreditProjectionContinuation(record)
            end
            if GS._creditProjectionOwnedCallbackBudget then
                EndCreditProjectionCallbackBudget()
                GS._creditProjectionOwnedCallbackBudget = false
            end
            return false, "work_budget", {
                rowVisits = rowVisits,
                traversalVisits = tonumber(GS._creditProjectionTraversalVisits) or 0,
                structureCopyVisits = tonumber(GS._creditProjectionStructureCopyVisits) or 0,
                workUnits = workUnits,
                deferred = true,
                phase = "baseline",
                speculative = speculative and true or false,
            }
        end
        -- Keep baseline immutable; working totals are a charged clone.
        baselineTotals = baselineSnap.baselineTotals
        totals = CloneCreditProjectionTotals(baselineTotals)
        byId = baselineSnap.baselineById
        local baselineProvenance = baselineSnap.baselineProvenance
        rowVisits = tonumber(baselineSnap.baselineVisits) or tonumber(baselineVisits) or 0
        relationshipsReady = baselineSnap.baselineRelationshipsReady
        GS._creditProjectionRowVisits = rowVisits
        -- Publish paced provenance index for activation / BindCharacterIdentity (#459).
        if type(baselineProvenance) == "table" then
            creditProvenanceIndexActive[record] = {
                map = baselineProvenance,
                complete = true,
            }
            creditProvenanceIndexCache[record] = {
                stamp = CreditProvenanceDependencyStamp(record),
                map = baselineProvenance,
                complete = true,
            }
        end
        -- Yield after baseline before winner indexing when allowance spent.
        do
            local softLimit = CreditProjectionSoftLimit()
            local allowDefer = (C_Timer and C_Timer.After) and true or false
            if allowDefer and CreditProjectionCallbackWorkTotal(
                CreditProjectionWorkNow(rowVisits or 0)) >= softLimit then
                writeScratch({
                    stamp = stampEarly,
                    candidates = scratch and scratch.candidates or candidates,
                    baselineTotals = baselineTotals,
                    baselineProvenance = baselineProvenance,
                    byId = byId,
                    rowVisits = rowVisits,
                    relationshipsReady = relationshipsReady,
                    -- ordered filled after winners; mark baseline-only resume
                    ordered = scratch and scratch.ordered or nil,
                    lookupMisses = scratch and scratch.lookupMisses or 0,
                    winnersIndex = 1,
                    winners = {},
                    ownerSpeculative = speculative and true or false,
                    ownerOpId = speculative and extraOp and extraOp.id or nil,
                })
                -- If ordered already absent, resume via winnersIndex path below.
                creditProjectionCache[record] = {
                    stamp = stampEarly,
                    ok = false,
                    err = "work_budget",
                    resume = {
                        deactivatedEventIds = {},
                        phase = "post_baseline",
                        speculative = speculative and true or false,
                        extraOp = speculative and extraOp or nil,
                        extraOpId = speculative and extraOp.id or nil,
                    },
                }
                local workUnits = CreditProjectionWorkNow(rowVisits or 0)
                AccumulateCreditProjectionSliceWork(workUnits)
                if not speculative then
                    ScheduleCreditProjectionContinuation(record)
                end
                if GS._creditProjectionOwnedCallbackBudget then
                    EndCreditProjectionCallbackBudget()
                    GS._creditProjectionOwnedCallbackBudget = false
                end
                return false, "work_budget", {
                    rowVisits = rowVisits,
                    traversalVisits = tonumber(GS._creditProjectionTraversalVisits) or 0,
                    structureCopyVisits = tonumber(GS._creditProjectionStructureCopyVisits) or 0,
                    workUnits = workUnits,
                    deferred = true,
                    phase = "post_baseline",
                    speculative = speculative and true or false,
                }
            end
        end
    end -- baseline build / prune-activate resume branches

    -- Winner indexing (fresh after baseline, or winners-resume). Skipped when
    -- ordered was retained from a later phase.
    if ordered == nil then
    -- Group by canonical event id; keep LWW winner. Resolve via baseline index
    -- (id + txnId + trusted aliases). Fall back to FindLedgerEventById only on
    -- true miss, caching both canonical and the immutable alias target.
    local winners = (type(scratch) == "table" and type(scratch.winners) == "table"
        and scratch.stamp == stampEarly) and scratch.winners or {}
    lookupMisses = (type(scratch) == "table" and scratch.stamp == stampEarly
        and tonumber(scratch.lookupMisses)) or 0
    local winnersStart = 1
    if type(scratch) == "table" and scratch.stamp == stampEarly
        and tonumber(scratch.winnersIndex) then
        winnersStart = tonumber(scratch.winnersIndex)
    end
    for i = winnersStart, #candidates do
        GS._creditProjectionTraversalVisits =
            (tonumber(GS._creditProjectionTraversalVisits) or 0) + 1
        local op = candidates[i]
        local event = byId[op.target]
        if event == false then
            event = nil
        elseif not event then
            -- True miss: trusted index lacked the target. Count the miss and the
            -- full-list scan cost so production measurements include alias gaps.
            lookupMisses = lookupMisses + 1
            local lists = CreditEventLists(record)
            for li = 1, #lists do
                local list = lists[li]
                if type(list) == "table" then
                    rowVisits = rowVisits + #list
                end
            end
            GS._creditProjectionRowVisits = rowVisits
            event = GS.FindLedgerEventById(record, op.target)
            if event then
                IndexCreditEventKeys(byId, event)
                byId[op.target] = event
            else
                byId[op.target] = false
            end
        end
        if event then
            local canonical = event.id
            local cur = winners[canonical]
            if not cur then
                winners[canonical] = { op = op, event = event }
            elseif GS.CreditCorrectionRevisionWins
                and GS.CreditCorrectionRevisionWins(op, cur.op) then
                winners[canonical] = { op = op, event = event }
            elseif not GS.CreditCorrectionRevisionWins
                and (tonumber(op.timestamp) or 0) >= (tonumber(cur.op.timestamp) or 0)
                and tostring(op.id) > tostring(cur.op.id) then
                winners[canonical] = { op = op, event = event }
            end
        end
        -- Pace after each candidate so shared remainder is respected.
        local softLimit = CreditProjectionSoftLimit()
        local hardLimit = CreditProjectionHardLimit()
        local allowDefer = (C_Timer and C_Timer.After) and true or false
        local now = CreditProjectionWorkNow(rowVisits or 0)
        if allowDefer and (CreditProjectionCallbackWorkTotal(now) >= softLimit
            or CreditProjectionCallbackWorkTotal(now) >= hardLimit) then
            writeScratch({
                stamp = stampEarly,
                candidates = candidates,
                baselineTotals = baselineTotals or totals,
                byId = byId,
                rowVisits = rowVisits,
                relationshipsReady = relationshipsReady,
                winners = winners,
                winnersIndex = i + 1,
                lookupMisses = lookupMisses,
                ownerSpeculative = speculative and true or false,
                ownerOpId = speculative and extraOp and extraOp.id or nil,
            })
            creditProjectionCache[record] = {
                stamp = stampEarly,
                ok = false,
                err = "work_budget",
                resume = {
                    deactivatedEventIds = {},
                    phase = "winners",
                    speculative = speculative and true or false,
                    extraOp = speculative and extraOp or nil,
                    extraOpId = speculative and extraOp.id or nil,
                },
            }
            local workUnits = now
            AccumulateCreditProjectionSliceWork(workUnits)
            if not speculative then
                ScheduleCreditProjectionContinuation(record)
            end
            if GS._creditProjectionOwnedCallbackBudget then
                EndCreditProjectionCallbackBudget()
                GS._creditProjectionOwnedCallbackBudget = false
            end
            return false, "work_budget", {
                rowVisits = rowVisits,
                traversalVisits = tonumber(GS._creditProjectionTraversalVisits) or 0,
                structureCopyVisits = tonumber(GS._creditProjectionStructureCopyVisits) or 0,
                workUnits = workUnits,
                deferred = true,
                phase = "winners",
                speculative = speculative and true or false,
            }
        end
    end
    GS._creditProjectionLookupMisses = lookupMisses
    ordered = {}
    for canonical, entry in pairs(winners) do
        ordered[#ordered + 1] = {
            canonical = canonical,
            op = entry.op,
            event = entry.event,
        }
    end
    table.sort(ordered, function(a, b)
        local ta = tonumber(a.op.timestamp) or 0
        local tb = tonumber(b.op.timestamp) or 0
        if ta ~= tb then
            return ta < tb
        end
        return tostring(a.op.id) < tostring(b.op.id)
    end)
    end -- winner indexing built ordered
    if not baselineTotals then
        -- Freeze immutable baseline; working totals are a charged clone.
        baselineTotals = totals
        totals = CloneCreditProjectionTotals(baselineTotals)
    end
    -- Soft yield after baseline/indexing before activation when allowance spent.
    -- Never run this when resuming activate/prune — it would wipe working state.
    do
        local softLimit = CreditProjectionSoftLimit()
        local allowDefer = (C_Timer and C_Timer.After) and true or false
        if allowDefer
            and not (skipToActivate or skipToPrune or skipToRestore or skipToFallback)
            and CreditProjectionCallbackWorkTotal(
            CreditProjectionWorkNow(rowVisits or 0)) >= softLimit then
            writeScratch({
                stamp = stampEarly,
                baselineTotals = baselineTotals,
                byId = byId,
                rowVisits = rowVisits,
                relationshipsReady = relationshipsReady,
                ordered = ordered,
                lookupMisses = lookupMisses,
                ownerSpeculative = speculative and true or false,
                ownerOpId = speculative and extraOp and extraOp.id or nil,
            })
            creditProjectionCache[record] = {
                stamp = stampEarly,
                ok = false,
                err = "work_budget",
                resume = {
                    deactivatedEventIds = {},
                    phase = "post_baseline",
                    speculative = speculative and true or false,
                    extraOp = speculative and extraOp or nil,
                    extraOpId = speculative and extraOp.id or nil,
                },
            }
            local workUnits = CreditProjectionWorkNow(rowVisits or 0)
            AccumulateCreditProjectionSliceWork(workUnits)
            if not speculative then
                ScheduleCreditProjectionContinuation(record)
            end
            if GS._creditProjectionOwnedCallbackBudget then
                EndCreditProjectionCallbackBudget()
                GS._creditProjectionOwnedCallbackBudget = false
            end
            return false, "work_budget", {
                rowVisits = rowVisits,
                structureCopyVisits = tonumber(GS._creditProjectionStructureCopyVisits) or 0,
                workUnits = workUnits,
                deferred = true,
                phase = "post_baseline",
                speculative = speculative and true or false,
            }
        end
    end
    local activeMap = {}
    local activeIds = {}
    local bound = {}
    local scoreBox
    -- Private working tables are retained by reference across slices (O(1)
    -- save/resume). Do not history-copy bound/map/ids/totals on each yield.
    local deactivatedEventIds = resumeDeactivated
    if type(deactivatedEventIds) ~= "table" then
        deactivatedEventIds = {}
    end
    local stamp = stampEarly
    local softLimit = CreditProjectionSoftLimit()
    local hardLimit = CreditProjectionHardLimit()
    local allowDefer = (C_Timer and C_Timer.After) and true or false
    -- `speculative` was resolved at rebuild entry for scratch ownership.
    local function finishOwnedBudget()
        if GS._creditProjectionOwnedCallbackBudget then
            EndCreditProjectionCallbackBudget()
            GS._creditProjectionOwnedCallbackBudget = false
        end
    end
    local scanState = nil
    if type(resumeScan) == "table" then
        scanState = {
            index = tonumber(resumeScan.index) or 1,
            bestEventId = resumeScan.bestEventId,
            bestIdx = resumeScan.bestIdx,
            bestScore = resumeScan.bestScore,
            bestTs = resumeScan.bestTs,
            bestId = resumeScan.bestId,
            currentScore = resumeScan.currentScore,
        }
    end
    local function savePruneScratch(opts)
        opts = opts or {}
        local priorScratch = readScratch()
        local baseSnap = baselineTotals
        if type(priorScratch) == "table" and type(priorScratch.baselineTotals) == "table" then
            baseSnap = priorScratch.baselineTotals
        end
        local activateIdx = opts.activateIndex
        local restoreIdx = opts.restoreIndex
        local fallbackIdx = opts.fallbackIndex
        local activating = activateIdx ~= nil
        local restoring = restoreIdx ~= nil
        local fallingBack = fallbackIdx ~= nil
        -- O(1) retain owned private working state; no history-sized copies.
        writeScratch({
            stamp = stamp,
            baselineTotals = baseSnap,
            byId = byId,
            rowVisits = rowVisits,
            relationshipsReady = relationshipsReady,
            ordered = ordered,
            lookupMisses = lookupMisses,
            candidates = priorScratch and priorScratch.candidates or nil,
            pruneReady = not activating and not restoring and not fallingBack,
            activateReady = activating and true or false,
            activateIndex = activateIdx,
            restoreReady = restoring and true or false,
            restoreIndex = restoreIdx,
            fallbackReady = fallingBack and true or false,
            fallbackIndex = fallbackIdx,
            fallbackBadItems = opts.fallbackBadItems,
            pruneTotals = totals,
            pruneBound = bound,
            pruneActiveMap = activeMap,
            pruneActiveIds = activeIds,
            pruneScoreBox = scoreBox,
            deactivatedEventIds = deactivatedEventIds,
            pruneScan = scanState,
            ownerSpeculative = speculative and true or false,
            ownerOpId = speculative and extraOp and extraOp.id or nil,
        })
    end
    local function deferProjection(phase, activateIndex, restoreIndex, fallbackIndex, fallbackBadItems)
        -- Retain working state first (O(1)), then charge this callback's work
        -- including anything performed after the yield decision.
        if activateIndex ~= nil or restoreIndex ~= nil or fallbackIndex ~= nil then
            savePruneScratch({
                activateIndex = activateIndex,
                restoreIndex = restoreIndex,
                fallbackIndex = fallbackIndex,
                fallbackBadItems = fallbackBadItems,
            })
        else
            savePruneScratch()
        end
        local workUnits = CreditProjectionWorkNow(rowVisits)
        AccumulateCreditProjectionSliceWork(workUnits)
        -- Do not publish a partial prune. Accepted-history pauses clear published
        -- validity so unfinished reconstruction cannot be read as current (#459 B3).
        -- Speculative pauses keep any independently valid accepted map intact.
        creditProjectionCache[record] = {
            stamp = stamp,
            ok = false,
            err = "work_budget",
            resume = {
                deactivatedEventIds = deactivatedEventIds,
                phase = phase,
                scan = scanState,
                speculative = speculative and true or false,
                extraOp = speculative and extraOp or nil,
                extraOpId = speculative and extraOp.id or nil,
            },
        }
        if not speculative then
            MarkAcceptedCreditInvalid(record)
        end
        -- Accepted-history always owns its successor timer while unfinished.
        if not speculative then
            ScheduleCreditProjectionContinuation(record)
        end
        finishOwnedBudget()
        return false, "work_budget", {
            activeIds = activeIds,
            rowVisits = rowVisits,
            bucketVisits = tonumber(GS._creditProjectionBucketVisits) or 0,
            floorVisits = tonumber(GS._creditProjectionFloorVisits) or 0,
            candidateTrials = tonumber(GS._creditProjectionCandidateTrials) or 0,
            structureCopyVisits = tonumber(GS._creditProjectionStructureCopyVisits) or 0,
            traversalVisits = tonumber(GS._creditProjectionTraversalVisits) or 0,
            workUnits = workUnits,
            callbackWork = CreditProjectionCallbackWorkTotal(0),
            deactivations = GS._creditProjectionDeactivations,
            lookupMisses = lookupMisses,
            deferred = true,
            phase = phase,
            speculative = speculative and true or false,
        }
    end
    local function shouldYield(localWork)
        return allowDefer
            and CreditProjectionCallbackWorkTotal(localWork) >= softLimit
    end
    -- Adopt retained private working tables (no copy) when stamp matches.
    local reusedPrune = false
    local reusedActivate = false
    local reusedRestore = false
    local reusedFallback = false
    if skipToPrune then
        totals = scratch.pruneTotals
        bound = scratch.pruneBound
        activeMap = scratch.pruneActiveMap
        activeIds = scratch.pruneActiveIds
        if type(scratch.pruneScoreBox) == "table" then
            scoreBox = scratch.pruneScoreBox
        else
            scoreBox = { tonumber(scratch.pruneScore) or TotalsNegScore(totals) }
        end
        if type(scratch.deactivatedEventIds) == "table" then
            deactivatedEventIds = scratch.deactivatedEventIds
        end
        reusedPrune = true
    elseif skipToActivate then
        totals = scratch.pruneTotals
        bound = scratch.pruneBound
        activeMap = scratch.pruneActiveMap
        activeIds = scratch.pruneActiveIds
        if type(scratch.pruneScoreBox) == "table" then
            scoreBox = scratch.pruneScoreBox
        else
            scoreBox = { TotalsNegScore(totals) }
        end
        if type(scratch.deactivatedEventIds) == "table" then
            deactivatedEventIds = scratch.deactivatedEventIds
        end
        reusedActivate = true
    elseif skipToRestore then
        totals = scratch.pruneTotals
        bound = scratch.pruneBound
        activeMap = scratch.pruneActiveMap
        activeIds = scratch.pruneActiveIds
        if type(scratch.pruneScoreBox) == "table" then
            scoreBox = scratch.pruneScoreBox
        else
            scoreBox = { TotalsNegScore(totals) }
        end
        if type(scratch.deactivatedEventIds) == "table" then
            deactivatedEventIds = scratch.deactivatedEventIds
        end
        reusedRestore = true
    elseif skipToFallback then
        totals = scratch.pruneTotals
        bound = scratch.pruneBound
        activeMap = scratch.pruneActiveMap
        activeIds = scratch.pruneActiveIds
        if type(scratch.pruneScoreBox) == "table" then
            scoreBox = scratch.pruneScoreBox
        else
            scoreBox = { TotalsNegScore(totals) }
        end
        if type(scratch.deactivatedEventIds) == "table" then
            deactivatedEventIds = scratch.deactivatedEventIds
        end
        reusedFallback = true
    end
    if not reusedPrune and not reusedFallback then
        if not reusedActivate and not reusedRestore then
            scoreBox = { TotalsNegScore(totals) }
        end
        if not reusedRestore then
            -- Activate every bindable production-credited winner, paced under the
            -- remaining shared callback allowance (including partially consumed).
            local activateStart = 1
            if reusedActivate and resumeActivateIndex then
                activateStart = resumeActivateIndex
            end
            -- Prefer baseline-built provenance; fall back to scratch / Ensure (#459).
            if not (type(creditProvenanceIndexActive[record]) == "table"
                and creditProvenanceIndexActive[record].complete)
                and type(scratch) == "table" and type(scratch.baselineProvenance) == "table" then
                creditProvenanceIndexActive[record] = {
                    map = scratch.baselineProvenance,
                    complete = true,
                }
            end
            for i = activateStart, #ordered do
                GS._creditProjectionTraversalVisits =
                    (tonumber(GS._creditProjectionTraversalVisits) or 0) + 1
                local entry = ordered[i]
                local op = entry.op
                local event = entry.event
                if event.gsProductionCredit == true then
                    local newName, newGuid, bindErr = BindCorrectionNewIdentity(
                        record, event, op.value.attributed, op.value.attributedGuid)
                    if bindErr == "work_budget" then
                        -- Cold paced provenance incomplete: pause activation and
                        -- resume via the shared continuation (#459 G2).
                        return deferProjection("activate", i)
                    end
                    if not bindErr then
                        local head = CorrectionHeadFromOp(op, event, newName, newGuid, nil)
                        activeMap[event.id] = head
                        activeIds[op.id] = true
                        bound[#bound + 1] = {
                            event = event,
                            op = op,
                            newName = newName,
                            newGuid = newGuid,
                        }
                        ApplyCorrectionFloorDelta(
                            record, totals, event, newName, newGuid, relationshipsReady, 1, scoreBox)
                    end
                end
                local now = CreditProjectionWorkNow(rowVisits)
                if shouldYield(now)
                    or CreditProjectionCallbackWorkTotal(now) >= hardLimit then
                    return deferProjection("activate", i + 1)
                end
            end
        end
        -- Legacy safety: resume.deactivated without retained prune scratch.
        -- Normal paced path keeps removals in retained working tables.
        if (not reusedActivate or reusedRestore) and #deactivatedEventIds > 0 then
            local boundByEventId = {}
            for i = 1, #bound do
                GS._creditProjectionTraversalVisits =
                    (tonumber(GS._creditProjectionTraversalVisits) or 0) + 1
                if bound[i] then
                    boundByEventId[bound[i].event.id] = i
                end
            end
            local restoreStart = 1
            if reusedRestore and resumeRestoreIndex then
                restoreStart = resumeRestoreIndex
            end
            for ri = restoreStart, #deactivatedEventIds do
                GS._creditProjectionTraversalVisits =
                    (tonumber(GS._creditProjectionTraversalVisits) or 0) + 1
                local eid = deactivatedEventIds[ri]
                local bi = boundByEventId[eid]
                local entry = bi and bound[bi]
                if entry and activeMap[eid] then
                    ApplyCorrectionFloorDelta(
                        record, totals, entry.event, entry.newName, entry.newGuid,
                        relationshipsReady, -1, scoreBox)
                    activeMap[eid] = nil
                    activeIds[entry.op.id] = nil
                    local last = #bound
                    bound[bi] = bound[last]
                    bound[last] = nil
                    if bound[bi] then
                        boundByEventId[bound[bi].event.id] = bi
                    end
                    boundByEventId[eid] = nil
                    GS._creditProjectionDeactivations =
                        (tonumber(GS._creditProjectionDeactivations) or 0) + 1
                end
                local now = CreditProjectionWorkNow(rowVisits)
                if shouldYield(now)
                    or CreditProjectionCallbackWorkTotal(now) >= hardLimit then
                    return deferProjection("activate_restore", nil, ri + 1)
                end
            end
        end
    end
    -- Soft yield before prune when baseline/activate already spent the allowance.
    if (not reusedFallback) and shouldYield(CreditProjectionWorkNow(rowVisits))
        and not TotalsAllNonNegative(totals) then
        return deferProjection("pre_prune")
    end
    -- Conflict rule: drop the head whose removal most improves personal floors.
    -- Score updates are O(touched buckets) via scoreBox — not a full rescan.
    -- A yield mid-scan preserves scan progress; never commit a prefix winner.
    while (not reusedFallback) and not TotalsAllNonNegative(totals) do
        if not scanState then
            if shouldYield(CreditProjectionWorkNow(rowVisits)) then
                return deferProjection("prune")
            end
            scanState = {
                index = 1,
                bestEventId = nil,
                bestIdx = nil,
                bestScore = nil,
                bestTs = nil,
                bestId = nil,
                currentScore = scoreBox[1],
            }
        end
        local currentScore = tonumber(scanState.currentScore) or scoreBox[1]
        local bestEventId = scanState.bestEventId
        local bestIdx = scanState.bestIdx
        local bestScore = scanState.bestScore
        local bestTs = scanState.bestTs
        local bestId = scanState.bestId
        local i = tonumber(scanState.index) or 1
        local yieldedMidScan = false
        while i <= #bound do
            local entry = bound[i]
            local entryIdx = i
            i = i + 1
            if entry and activeMap[entry.event.id] then
                if shouldYield(CreditProjectionWorkNow(rowVisits)) then
                    -- Preserve scan cursor before this untried candidate.
                    scanState = {
                        index = entryIdx,
                        bestEventId = bestEventId,
                        bestIdx = bestIdx,
                        bestScore = bestScore,
                        bestTs = bestTs,
                        bestId = bestId,
                        currentScore = currentScore,
                    }
                    yieldedMidScan = true
                    break
                end
                GS._creditProjectionCandidateTrials =
                    (tonumber(GS._creditProjectionCandidateTrials) or 0) + 1
                ApplyCorrectionFloorDelta(
                    record, totals, entry.event, entry.newName, entry.newGuid,
                    relationshipsReady, -1, scoreBox)
                local score = scoreBox[1]
                ApplyCorrectionFloorDelta(
                    record, totals, entry.event, entry.newName, entry.newGuid,
                    relationshipsReady, 1, scoreBox)
                if score > currentScore then
                    local ts = tonumber(entry.op.timestamp) or 0
                    local id = tostring(entry.op.id)
                    local take = false
                    if not bestEventId then
                        take = true
                    elseif score > bestScore then
                        take = true
                    elseif score == bestScore then
                        if ts < bestTs or (ts == bestTs and id < bestId) then
                            take = true
                        end
                    end
                    if take then
                        bestEventId, bestScore, bestTs, bestId =
                            entry.event.id, score, ts, id
                        bestIdx = entryIdx
                    end
                end
                if CreditProjectionCallbackWorkTotal(CreditProjectionWorkNow(rowVisits))
                    >= hardLimit then
                    -- Atomic trial finished; yield before the next candidate.
                    scanState = {
                        index = i,
                        bestEventId = bestEventId,
                        bestIdx = bestIdx,
                        bestScore = bestScore,
                        bestTs = bestTs,
                        bestId = bestId,
                        currentScore = currentScore,
                    }
                    yieldedMidScan = true
                    break
                end
            end
        end
        if yieldedMidScan then
            return deferProjection("prune_scan")
        end
        -- Full comparison complete for this pass.
        scanState = nil
        if not bestEventId or not bestIdx or not bound[bestIdx] then
            break
        end
        local entry = bound[bestIdx]
        if entry.event.id ~= bestEventId then
            -- Index invalidated (should not happen with dense swap-remove); abort pass.
            break
        end
        ApplyCorrectionFloorDelta(
            record, totals, entry.event, entry.newName, entry.newGuid,
            relationshipsReady, -1, scoreBox)
        activeMap[entry.event.id] = nil
        activeIds[entry.op.id] = nil
        -- O(1) dense removal — no history-sized compaction copy.
        local last = #bound
        bound[bestIdx] = bound[last]
        bound[last] = nil
        deactivatedEventIds[#deactivatedEventIds + 1] = entry.event.id
        GS._creditProjectionDeactivations =
            (tonumber(GS._creditProjectionDeactivations) or 0) + 1
        GS._creditProjectionTraversalVisits =
            (tonumber(GS._creditProjectionTraversalVisits) or 0) + 1
        if shouldYield(CreditProjectionWorkNow(rowVisits)) then
            return deferProjection("prune")
        end
    end
    -- Local empty-set fallback: when single-head prune stalls, drop remaining
    -- heads only for item groups that still have negative floors. Independent
    -- deduction-supporting corrections on other items are preserved.
    if not TotalsAllNonNegative(totals) then
        local badItems = ItemIdsWithNegativeTotals(totals)
        if type(scratch) == "table" and scratch.fallbackReady == true
            and type(scratch.fallbackBadItems) == "table" then
            badItems = scratch.fallbackBadItems
        end
        local i = 1
        if type(scratch) == "table" and scratch.fallbackReady == true
            and tonumber(scratch.fallbackIndex) then
            i = tonumber(scratch.fallbackIndex)
        elseif resumePhase == "empty_fallback" and type(scratch) == "table"
            and tonumber(scratch.fallbackIndex) then
            i = tonumber(scratch.fallbackIndex)
        end
        while i <= #bound do
            GS._creditProjectionTraversalVisits =
                (tonumber(GS._creditProjectionTraversalVisits) or 0) + 1
            local now = CreditProjectionWorkNow(rowVisits)
            -- Check every traversed entry (including non-removals).
            if shouldYield(now) or CreditProjectionCallbackWorkTotal(now) >= hardLimit then
                return deferProjection("empty_fallback", nil, nil, i, badItems)
            end
            local entry = bound[i]
            if entry and activeMap[entry.event.id] then
                local itemId = tonumber(entry.event.itemId)
                if itemId and badItems[itemId] then
                    ApplyCorrectionFloorDelta(
                        record, totals, entry.event, entry.newName, entry.newGuid,
                        relationshipsReady, -1, scoreBox)
                    activeMap[entry.event.id] = nil
                    activeIds[entry.op.id] = nil
                    local last = #bound
                    bound[i] = bound[last]
                    bound[last] = nil
                    deactivatedEventIds[#deactivatedEventIds + 1] = entry.event.id
                    GS._creditProjectionDeactivations =
                        (tonumber(GS._creditProjectionDeactivations) or 0) + 1
                    -- Do not advance i: swapped-in entry must be considered.
                    now = CreditProjectionWorkNow(rowVisits)
                    if shouldYield(now) or CreditProjectionCallbackWorkTotal(now) >= hardLimit then
                        return deferProjection("empty_fallback", nil, nil, i, badItems)
                    end
                else
                    i = i + 1
                end
            else
                i = i + 1
            end
        end
    end
    local bucketVisits = tonumber(GS._creditProjectionBucketVisits) or 0
    local floorVisits = tonumber(GS._creditProjectionFloorVisits) or 0
    local candidateTrials = tonumber(GS._creditProjectionCandidateTrials) or 0
    local traversalVisits = tonumber(GS._creditProjectionTraversalVisits) or 0
    local structureCopyVisits = tonumber(GS._creditProjectionStructureCopyVisits) or 0
    local workUnits = CreditProjectionWorkNow(rowVisits)
    AccumulateCreditProjectionSliceWork(workUnits)
    writeScratch(nil)
    finishOwnedBudget()
    -- Final invariant: never leave a stale active map and never mark a negative
    -- projection verified. On failure, clear heads and cache under the stamp;
    -- ResolveEffectiveCreditIdentity returns CREDIT_UNAVAILABLE (not durable).
    -- Bounded selector may leave a conflict unresolved even when some subset
    -- would verify — consumers must treat failure as unavailable, not as proof
    -- that no valid set exists.
    if not TotalsAllNonNegative(totals) then
        MarkAcceptedCreditInvalid(record)
        record.creditCorrections = {}
        creditProjectionCache[record] = {
            stamp = stamp,
            ok = false,
            err = "player_negative",
        }
        return false, "player_negative", {
            activeIds = {},
            rowVisits = rowVisits,
            bucketVisits = bucketVisits,
            floorVisits = floorVisits,
            candidateTrials = candidateTrials,
            traversalVisits = traversalVisits,
            structureCopyVisits = structureCopyVisits,
            workUnits = workUnits,
            deactivations = GS._creditProjectionDeactivations,
            lookupMisses = lookupMisses,
        }
    end
    local nActive = 0
    for _ in pairs(activeMap) do
        nActive = nActive + 1
    end
    if nActive > (GS.MAX_LEDGER_EVENTS or 4096) then
        return false, "full"
    end
    record.creditCorrections = activeMap
    creditProjectionCache[record] = {
        stamp = stamp,
        ok = true,
    }
    MarkAcceptedCreditValid(record, stamp)
    return true, nil, {
        activeIds = activeIds,
        rowVisits = rowVisits,
        bucketVisits = bucketVisits,
        floorVisits = floorVisits,
        candidateTrials = candidateTrials,
        traversalVisits = traversalVisits,
        structureCopyVisits = structureCopyVisits,
        workUnits = workUnits,
        deactivations = GS._creditProjectionDeactivations,
        lookupMisses = lookupMisses,
    }
end

--- After Apply already published a coherent projection (e.g. extraOp preview)
-- and the matching op was stored, adopt the current dependency stamp without a
-- second full rebuild (#459 redrive callback budget).
-- Only call after a completed coherent publication — never to certify an
-- unfinished accepted reconstruction (e.g. local ADJUST_QUANTITY).
function GS.SealCreditCorrectionProjection(record, ok)
    if type(record) ~= "table" then
        return
    end
    local stamp = CreditProjectionDependencyStamp(record)
    creditProjectionCache[record] = {
        stamp = stamp,
        ok = ok ~= false,
        err = (ok == false) and "player_negative" or nil,
    }
    -- Sealed generation must not leave prior-stamp owner pauses/candidates that
    -- a queued accepted-history timer could certify as current.
    ClearCreditProjectionScratch(record)
    if ok ~= false and type(record.creditCorrections) == "table" then
        MarkAcceptedCreditValid(record, stamp)
    else
        MarkAcceptedCreditInvalid(record)
        if ok == false then
            record.creditCorrections = {}
        end
    end
    local cont = creditProjectionContinuation[record]
    if type(cont) == "table" then
        cont.scheduled = false
    end
end

--- Ensure the credit projection matches current ops/ledger dependency stamps.
-- Unchanged reads reuse the last verified *or failed* stamp (#459) so a
-- failed reconstruction does not rebuild on every ResolveEffectiveCreditIdentity.
-- Incomplete paced rebuilds (work_budget) stay unavailable and resume via timer.
function GS.EnsureCreditCorrectionProjection(record, extraOp)
    if type(record) ~= "table" then
        return false, "invalid_value"
    end
    if extraOp ~= nil then
        return GS.RebuildCreditCorrectionProjection(record, extraOp)
    end
    local stamp = CreditProjectionDependencyStamp(record)
    local cached = creditProjectionCache[record]
    if cached and cached.stamp == stamp then
        if cached.ok then
            -- Published ok must still have independent accepted validity.
            if acceptedCreditValidStamp[record] == stamp
                and type(record.creditCorrections) == "table" then
                return true
            end
            -- Stale ok without a valid map: rebuild.
            return GS.RebuildCreditCorrectionProjection(record, nil)
        end
        if cached.err == "work_budget" then
            -- Speculative local/remote preview pauses must not Schedule an
            -- accepted-history continuation that would wipe private scratch.
            -- Serve accepted credit only when it still has current-stamp validity
            -- (#459 B3) — never merely because creditCorrections is a table.
            if type(cached.resume) == "table" and cached.resume.speculative then
                if acceptedCreditValidStamp[record] == stamp
                    and type(record.creditCorrections) == "table" then
                    return true
                end
                return false, "work_budget"
            end
            ScheduleCreditProjectionContinuation(record)
            return false, "work_budget"
        end
        return false, cached.err or "player_negative"
    end
    return GS.RebuildCreditCorrectionProjection(record, nil)
end

--- Shared acceptance-boundary checks before any path retains a correction as
-- accepted history (ordinary apply, LWW-loser retention, adoption) (#459 G3/G4).
-- Does not require local editor freshness, floors, or activation.
-- opts.allowMissingEvent / opts.remoteAdmit: missing target → pending_event.
-- @return boolean ok, string|nil err, table|nil event
function GS.ValidateContributorCorrectionScope(record, op, opts)
    opts = opts or {}
    if type(record) ~= "table" or type(op) ~= "table" then
        return false, "invalid_value"
    end
    local eventId = op.target or (op.value and op.value.eventId)
    if type(eventId) ~= "string" or eventId == "" then
        return false, "invalid_target"
    end
    -- Acceptance wall-clock skew: reject implausibly future timestamps before
    -- durable retention/head changes. Not part of saved-body shape validation.
    do
        local skew = tonumber(GS.CORRECT_CONTRIBUTOR_TIMESTAMP_SKEW) or 600
        local now = (GetServerTime and GetServerTime()) or nil
        local ts = tonumber(op.timestamp)
        if now and ts and ts == ts and ts >= 0 and skew >= 0 then
            if ts > now + skew then
                return false, "invalid_timestamp"
            end
        end
    end
    local authoredCampaign = op.campaignId
    local authoredBase = op.baseCampaignId
    if type(authoredCampaign) ~= "string" or authoredCampaign == ""
        or type(authoredBase) ~= "string" or authoredBase == "" then
        return false, "stale_campaign"
    end
    if authoredCampaign ~= authoredBase then
        return false, "stale_campaign"
    end
    local event = GS.FindLedgerEventById(record, eventId)
    if not event then
        if opts.allowMissingEvent or opts.remoteAdmit then
            return false, "pending_event"
        end
        return false, "missing_event"
    end
    if type(event.campaignId) ~= "string" or event.campaignId == ""
        or authoredCampaign ~= event.campaignId then
        return false, "stale_campaign"
    end
    return true, nil, event
end

-- opts.localPrepare: require current campaign + production credit + expected match.
-- opts.skipExpected: remote LWW apply (still checks floors against current→new).
-- opts.allowMissingEvent: return pending_event instead of missing_event.
-- opts.skipFloor: remote apply defers floors to RebuildCreditCorrectionProjection.
-- @return boolean ok, string|nil err, table|nil details
function GS.ValidateContributorCorrectionPrepare(record, op, opts)
    opts = opts or {}
    if type(record) ~= "table" or type(op) ~= "table" or type(op.value) ~= "table" then
        return false, "invalid_value"
    end
    local scopeOk, scopeErr, event = GS.ValidateContributorCorrectionScope(record, op, opts)
    if not scopeOk then
        return false, scopeErr or "invalid_value"
    end
    local eventKind = op.value.eventKind
    local isDonation = IsDonationLedgerEvent(event)
    local isAdjustment = IsAdjustmentLedgerEvent(event)
    if eventKind == "donation" and not isDonation then
        return false, "invalid_event"
    end
    if eventKind == "adjustment" and not isAdjustment then
        return false, "invalid_event"
    end
    if not isDonation and not isAdjustment then
        return false, "invalid_event"
    end
    -- Corrections never grant production credit to pending/uncredited/staged rows.
    if event.gsProductionCredit ~= true then
        return false, "not_credited"
    end
    -- Local authoring/commit is current-campaign-only; remote historical replay
    -- uses Scope event-campaign match without this guard (#459 G4).
    if opts.localPrepare then
        if type(record.currentCampaignId) ~= "string"
            or event.campaignId ~= record.currentCampaignId then
            return false, "stale_campaign"
        end
    end
    local curName, curGuid, _, creditStatus = GS.ResolveEffectiveCreditIdentity(record, event)
    -- Remote/skipFloor apply rebuilds projection itself; do not reject while a
    -- paced work_budget slice has left credit temporarily unavailable (#459).
    if creditStatus == GS.CREDIT_UNAVAILABLE and not opts.skipFloor then
        return false, GS.CREDIT_UNAVAILABLE
    end
    if opts.localPrepare and not opts.skipExpected then
        local baseName = NormName(op.value.baseAttributed)
        local baseGuid = ValidGuid(op.value.baseAttributedGuid)
        if not CreditIdentitiesEqual(curName, curGuid, baseName, baseGuid) then
            return false, "stale_credit"
        end
        -- Open-time head freshness. CurrentTargetRevision falls back to
        -- datasetId when no correction head exists yet — treat that as "no head".
        do
            local tKey = GS.ComputeTargetKey and GS.ComputeTargetKey(op.kind, event.id) or nil
            local headId = tKey and record.operations and record.operations.heads
                and record.operations.heads[tKey]
            local expected = op.baseTargetRevision
            local noPriorHead = expected == nil or expected == record.datasetId
            if noPriorHead then
                if headId ~= nil then
                    return false, "stale_credit"
                end
            elseif expected ~= headId then
                return false, "stale_credit"
            end
        end
    end
    local newName, newGuid, bindErr = BindCorrectionNewIdentity(
        record, event, op.value.attributed, op.value.attributedGuid)
    if bindErr then
        return false, bindErr
    end
    if not opts.skipFloor then
        local floorOk, floorErr = GS.ContributorCorrectionFloorOk(
            record, event, newName, newGuid)
        if not floorOk then
            return false, floorErr or "player_negative"
        end
    end
    return true, nil, {
        event = event,
        eventKind = isDonation and "donation" or "adjustment",
        currentName = curName,
        currentGuid = curGuid,
        newName = newName,
        newGuid = newGuid,
    }
end

--- Build the public op value for a local correction prepare.
-- @return value|nil, err|nil
function GS.BuildContributorCorrectionValue(record, eventId, attributed, attributedGuid, opts)
    opts = opts or {}
    if type(record) ~= "table" or type(eventId) ~= "string" or eventId == "" then
        return nil, "invalid_target"
    end
    local event = GS.FindLedgerEventById(record, eventId)
    if not event then
        return nil, "missing_event"
    end
    local isDonation = IsDonationLedgerEvent(event)
    local isAdjustment = IsAdjustmentLedgerEvent(event)
    if not isDonation and not isAdjustment then
        return nil, "invalid_event"
    end
    if event.gsProductionCredit ~= true then
        return nil, "not_credited"
    end
    if opts.localPrepare then
        if type(record.currentCampaignId) ~= "string"
            or event.campaignId ~= record.currentCampaignId then
            return nil, "stale_campaign"
        end
    end
    local curName, curGuid, _, creditStatus = GS.ResolveEffectiveCreditIdentity(record, event)
    if creditStatus == GS.CREDIT_UNAVAILABLE then
        return nil, GS.CREDIT_UNAVAILABLE
    end
    local newName, newGuid, bindErr = BindCorrectionNewIdentity(
        record, event, attributed, attributedGuid)
    if bindErr then
        return nil, bindErr
    end
    local floorOk, floorErr = GS.ContributorCorrectionFloorOk(
        record, event, newName, newGuid)
    if not floorOk then
        return nil, floorErr or "player_negative"
    end
    local value = {
        eventId = event.id,
        eventKind = isDonation and "donation" or "adjustment",
        attributed = newName,
        attributedGuid = newGuid,
        baseAttributed = curName,
        baseAttributedGuid = curGuid,
        itemId = tonumber(event.itemId),
    }
    return value
end

--- Apply an accepted correct-contributor mutation (#459).
-- Leaves ledger evidence intact; rebuilds the active creditCorrections projection.
function GS.ApplyContributorCorrectionMutation(record, op, opts)
    opts = opts or {}
    if type(record) ~= "table" or type(op) ~= "table" then
        return false, "invalid_value"
    end
    local eventId = op.target or (op.value and op.value.eventId)
    local canonical = GS.CanonicalCreditEventId(record, eventId)
    local tKey = GS.CorrectionTargetKey and GS.CorrectionTargetKey(record, eventId)
        or (GS.ComputeTargetKey and GS.ComputeTargetKey(op.kind, canonical or eventId))
    -- Also accept heads keyed by the raw target string for pre-migration peers.
    local ops = record.operations
    local headId = ops and ops.heads and tKey and ops.heads[tKey]
    if not headId and type(eventId) == "string" and GS.ComputeTargetKey then
        local rawKey = GS.ComputeTargetKey(op.kind, eventId)
        headId = rawKey and ops and ops.heads and ops.heads[rawKey]
    end
    if not headId and type(canonical) == "string" and canonical ~= eventId
        and GS.ComputeTargetKey then
        local canonRaw = GS.ComputeTargetKey(op.kind, canonical)
        headId = canonRaw and ops and ops.heads and ops.heads[canonRaw]
    end
    local headBody = headId and ops.records and ops.records[headId]
    if type(headBody) == "table" and headBody.id ~= op.id
        and GS.CreditCorrectionRevisionWins
        and not GS.CreditCorrectionRevisionWins(op, headBody) then
        return false, "stale_credit"
    end
    local isLocal = opts.localProductionAuthority or opts.localWrite or false
    local ok, err, details = GS.ValidateContributorCorrectionPrepare(record, op, {
        localPrepare = isLocal,
        -- Remote/adoption: expected base is local editor freshness only.
        -- Floors are enforced by the deterministic rebuild (active heads).
        skipExpected = not isLocal,
        skipFloor = not isLocal,
        remoteAdmit = not isLocal,
        allowMissingEvent = not isLocal,
    })
    if not ok then
        return false, err or "invalid_value"
    end
    local event = details.event
    -- Preview rebuild including this op; local prepare must activate.
    local rebuilt, rebuildErr, rebuildDetails = GS.RebuildCreditCorrectionProjection(record, op)
    if not rebuilt then
        -- Local work_budget keeps private speculative scratch for the authorized
        -- resumable local save path (#459 / discussion_r4480434323). Other local
        -- failures still discard so timers cannot publish an unaccepted preview.
        -- Remote redrive keeps speculative resume so the next Admit can continue.
        if rebuildErr == "work_budget" and isLocal then
            return false, "work_budget"
        end
        if isLocal then
            DiscardSpeculativeCreditProjectionResume(record, op)
        end
        return false, rebuildErr or "invalid_value"
    end
    if isLocal then
        local activeIds = rebuildDetails and rebuildDetails.activeIds
        if type(activeIds) ~= "table" or not activeIds[op.id] then
            DiscardSpeculativeCreditProjectionResume(record, op)
            -- Roll back projection without this op.
            GS.RebuildCreditCorrectionProjection(record, nil)
            return false, "player_negative"
        end
    end
    -- Capacity guard for brand-new projection keys is inside rebuild.
    if CountCreditCorrections(record) > (GS.MAX_LEDGER_EVENTS or 4096) then
        return false, "full"
    end
    -- Durable alias binding required for alias-targeted acceptance; refuse when
    -- the binding cannot be retained under the bounded map (#459 G1).
    local aliasOk, aliasErr = GS.EnsureContributorCorrectionDurableAliases(record, op, event)
    if not aliasOk then
        if isLocal then
            DiscardSpeculativeCreditProjectionResume(record, op)
        end
        GS.RebuildCreditCorrectionProjection(record, nil)
        return false, aliasErr or "full"
    end
    return true, "accepted"
end

function GS.ApplyAdjustmentMutation(record, op, opts)
    opts = opts or {}
    local itemId = tonumber(op.value and op.value.itemId) or tonumber(op.target and op.target.itemId)
    local quantity = tonumber(op.value and op.value.quantity)
    local attributed = op.value and op.value.attributed
    local cfg = record.accounting._consumables
    -- Operation id is the durable idempotency key across ledger-before-op and
    -- op-before-ledger delivery orders (event.id / event.opId). Exact-id
    -- duplicate detection must run before the floor check so a ledger-first
    -- adjustment that already exhausted the balance replays as duplicate
    -- rather than item_negative. Divergent same-ID bodies quarantine.
    local eventId = op.id
    local incomingView = {
        itemId = itemId,
        quantity = quantity,
        attributed = attributed,
        campaignId = record.currentCampaignId,
        generation = tonumber(cfg.generation) or 1,
        actor = NormName(op.actorName) or op.actorGuid,
    }
    local events = record.accounting._consumableEvents
    if type(events) == "table" then
        for i = 1, #events do
            local e = events[i]
            if e and (e.id == eventId or e.opId == eventId) then
                if AdjustmentBodiesEquivalent(e, incomingView) then
                    return true, "duplicate"
                end
                QuarantineConflictBody(cfg, eventId, incomingView)
                return false, "id_conflict"
            end
        end
    end
    -- Local editor commits re-check current campaign membership so an item
    -- removed while confirmation is open cannot apply. Remote admission of
    -- already-authored ops must not fail solely because the item was later
    -- removed (#426 / historical catch-up).
    local isLocalCommit = opts.localProductionAuthority or opts.localWrite
    if isLocalCommit then
        if not GS.IsCurrentRequestedItem(record, itemId) then
            return false, "item_not_requested"
        end
    end
    -- Goal ceiling is local-authoring only. Remote/authenticated catch-up keeps
    -- floors and campaign checks without replaying the authoring-time ceiling
    -- against a peer's later donation or goal state (#430).
    local normAttr, attrGuid, attrErr = GS.ResolveAttributedIdentity(
        record, attributed, op.value and op.value.attributedGuid)
    if attrErr then
        return false, attrErr
    end
    local floorOpts = { attributedGuid = attrGuid }
    if isLocalCommit then
        floorOpts.enforceGoalCeiling = true
    end
    local floorOk, floorErr = GS.AdjustmentFloorOk(
        record, itemId, quantity, normAttr, record.currentCampaignId, floorOpts)
    if not floorOk then
        return false, floorErr or "adjustment_floor"
    end
    local event = {
        type = GS.LEDGER_EVENT.ADJUSTMENT,
        id = eventId,
        txnId = eventId,
        generation = tonumber(cfg.generation) or 1,
        timestamp = tonumber(op.timestamp) or Now(),
        actor = NormName(op.actorName) or op.actorGuid,
        writer = op.actorGuid,
        itemId = itemId,
        quantity = quantity,
        attributed = normAttr,
        campaignId = record.currentCampaignId,
        datasetId = record.datasetId,
        opId = op.id,
    }
    if attrGuid then
        event.attributedGuid = attrGuid
    end
    -- Only the local authenticated editor path may mint live cutover provenance
    -- when this client is already active. Remote gs-op admission stays unmarked
    -- until a matching authenticated marked ledger event reconciles (#389 A2).
    if opts.localProductionAuthority
        and GS.IsLiveActive and GS.IsLiveActive(record)
        and type(record.liveCutover) == "table"
        and type(record.liveCutover.cutoverMarker) == "string"
        and record.liveCutover.cutoverMarker ~= "" then
        event.gsSourceCutoverMarker = record.liveCutover.cutoverMarker
    end
    -- #447: local attributed adjustments may capture an immutable DBMarket unit
    -- snapshot. Missing TSM / ineligible clients leave the row unpriced (zero
    -- ranking value) without blocking the quantity adjustment. Donation
    -- gs-valuation admission is not used here.
    if isLocalCommit and normAttr and GS.AttachAdjustmentUnitCopperSnapshot then
        GS.AttachAdjustmentUnitCopperSnapshot(event, event.itemId)
    end
    local ok, err = AppendLedgerEvent(record, event)
    if not ok then
        return false, err or "full"
    end
    return true, "accepted"
end

-- Test helper: inject a direct observation without bank scanning (#388 staged only).
function GS:_AdmitObservationForTests(evidence, witnessGuid, witnessName)
    local record, reason = GS:GetCurrentRecord()
    if not record then
        return "rejected", reason or "not_ready"
    end
    local member = {
        guid = witnessGuid,
        name = witnessName or "Test-Garona",
        guildKey = select(1, GS:GetCurrentContext()).guildKey,
        rankOrder = 1,
    }
    return GS:AdmitDirectObservation(evidence, {
        member = member,
        sender = member.name,
        localWrite = true,
        offlineRecord = record,
    })
end
