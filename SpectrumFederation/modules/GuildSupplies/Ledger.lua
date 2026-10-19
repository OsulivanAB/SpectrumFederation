-- Guild Supplies Phase 3B — Donation evidence, three-witness ledger, identity links (#388).
-- Staged accounting only. Live bank/helper writers remain legacy Consumables until #389.
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
GS.MAX_IDENTITY_LINK_GROUPS = 64
GS.MAX_GUIDS_PER_LINK_GROUP = 16
GS.MAX_LEDGER_EVENTS = 4096
-- Prior-generation rows shelved out of the live list (projection + gossip).
GS.MAX_ARCHIVED_EVENTS = 4096
GS.MAX_TXN_REGISTRY = 512
GS.MAX_TXN_ID = 160
GS.MAX_OBS_QUANTITY = 100000
GS.MAX_PENDING_ADJUSTMENTS = 32
GS.MAX_PENDING_DONATION_CANDIDATES = 256
GS.MAX_DIRECT_EVIDENCE_EXPORTS = 256
GS.MAX_TXN_CONFLICT_KEYS = 64
GS.MAX_TXN_CONFLICT_BODIES = 8

GS.LEDGER_EVENT = {
    DONATION = "donation",
    ADJUSTMENT = "adjustment",
}

GS.VERIFICATION = {
    WITNESSES = "witnesses",
}

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
-- Identity links (guild-owned; GUID based; not Loot Helper profiles)
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

--- Collapse known guild-owned links: same group ⇒ same witness identity.
function GS.AreSameWitnessIdentity(record, guidA, guidB)
    guidA, guidB = ValidGuid(guidA), ValidGuid(guidB)
    if not guidA or not guidB then return false end
    if guidA == guidB then return true end
    local links = record and record.identityLinks
    if type(links) ~= "table" or type(links.byGuid) ~= "table" then
        return false
    end
    local ga = links.byGuid[guidA]
    local gb = links.byGuid[guidB]
    return type(ga) == "string" and ga ~= "" and ga == gb
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

function GS.CountIndependentWitnesses(record, witnessMap)
    if type(witnessMap) ~= "table" then return 0 end
    local keys = {}
    for key, row in pairs(witnessMap) do
        local guid = type(row) == "table" and ValidGuid(row.guid or row.witnessGuid) or ValidGuid(key)
        if guid then
            keys[#keys + 1] = guid
        end
    end
    table.sort(keys)
    local counted = {}
    local n = 0
    for i = 1, #keys do
        local guid = keys[i]
        local skip = false
        for j = 1, #counted do
            if GS.AreSameWitnessIdentity(record, counted[j], guid) then
                skip = true
                break
            end
        end
        if not skip then
            counted[#counted + 1] = guid
            n = n + 1
        end
    end
    return n
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
    local core = evidence.coreSignature
    if type(core) ~= "string" or core == "" then
        if O and O.CoreSignature then
            core = O.CoreSignature("deposit", donor, itemId, quantity)
        end
    end
    if type(core) ~= "string" or core == "" then return nil end
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
            local limit = math.min(#list, GS.MAX_LEDGER_EVENTS or 4096)
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

local function AddTxnAlias(cfg, primaryTxnId, aliasTxnId)
    primaryTxnId, aliasTxnId = ValidTxnId(primaryTxnId), ValidTxnId(aliasTxnId)
    if not primaryTxnId or not aliasTxnId or primaryTxnId == aliasTxnId then
        return false
    end
    local row = FindRegistryByTxn(cfg, primaryTxnId)
    if not row then return false end
    if type(row.aliases) ~= "table" then
        row.aliases = {}
    end
    for i = 1, #row.aliases do
        if row.aliases[i] == aliasTxnId then
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
    return true
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

local function TrimEventArchive(record)
    local archive = EnsureEventArchive(record)
    if type(archive) ~= "table" then
        return false
    end
    local maxArch = GS.MAX_ARCHIVED_EVENTS or 4096
    local overflow = #archive - maxArch
    if overflow <= 0 then
        return false
    end
    local kept = {}
    for i = overflow + 1, #archive do
        kept[#kept + 1] = archive[i]
    end
    record.accounting._consumableEventArchive = kept
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
    return true
end

local function AppendArchivedLedgerEvent(record, event)
    local archive = EnsureEventArchive(record)
    if type(archive) ~= "table" then
        return false, "invalid_accounting"
    end
    local maxArch = GS.MAX_ARCHIVED_EVENTS or 4096
    if #archive >= maxArch then
        return false, "full"
    end
    archive[#archive + 1] = event
    return true
end

local function AppendLedgerEvent(record, event)
    local cfg = record.accounting and record.accounting._consumables
    local curGen = tonumber(cfg and cfg.generation)
    local eventGen = type(event) == "table" and tonumber(event.generation) or nil
    -- Historical rows belong in the archive list once the live generation advanced.
    if eventGen and curGen and eventGen < curGen then
        return AppendArchivedLedgerEvent(record, event)
    end
    local list = record.accounting._consumableEvents
    if type(list) ~= "table" then
        record.accounting._consumableEvents = {}
        list = record.accounting._consumableEvents
    end
    if #list >= (GS.MAX_LEDGER_EVENTS or 4096) then
        if GS.ShelvePriorGenerationsOnRecord(record)
            and #(record.accounting._consumableEvents or {}) < (GS.MAX_LEDGER_EVENTS or 4096) then
            list = record.accounting._consumableEvents
        else
            return false, "full"
        end
    end
    list[#list + 1] = event
    if type(cfg) == "table" then
        cfg.eventSeq = (tonumber(cfg.eventSeq) or 0) + 1
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

local function BuildDonationEvent(evidence, writerGuid, txnId, verification)
    txnId = ValidTxnId(txnId)
    writerGuid = ValidGuid(writerGuid)
    local donor = NormName(evidence.donor)
    local itemId = tonumber(evidence.itemId)
    local quantity = FloorNonNeg(evidence.quantity)
    if not txnId or not writerGuid or not donor or not IsItemId(itemId) or quantity < 1 then
        return nil
    end
    return {
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
    }
end

--- Resolve generation/items/tab/eligibility for the evidence's campaign.
-- Historical rows use archived campaign context, never the live campaign alone.
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
            eligibility = live.eligibility,
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
    return {
        generation = archive.generation,
        requestedItems = archive.requestedItems,
        bankTab = bankTab,
        guild = live.guild,
        eligibility = eligibility,
        historical = true,
        hasEligibilityProof = type(eligibility) == "table",
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
    -- must stay pending (never auto-credit).
    if O and O.EvidenceSpansEligibilityBoundary and ctx.eligibility then
        if O.EvidenceSpansEligibilityBoundary(evidence, ctx.eligibility) then
            return false, "ambiguous_boundary"
        end
    end
    return true
end

local function CommitVerifiedCluster(record, cluster, writerGuid)
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
                verification = GS.VERIFICATION.WITNESSES,
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

    local event = BuildDonationEvent(evidence, writerGuid, txnId, GS.VERIFICATION.WITNESSES)
    if not event then
        return false, "invalid_event"
    end
    event.campaignId = record.currentCampaignId
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
        verification = GS.VERIFICATION.WITNESSES,
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
                    AddTxnAlias(cfg, txnId, candId)
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
    Debug("Info", "three-witness donation committed txn=%s witnesses=%s",
        tostring(txnId), tostring(GS.CountIndependentWitnesses(record, cluster.witnesses)))
    return true, "accepted"
end

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

--- Admit one directly authenticated Guild Bank observation as a witness vote.
-- Relayed witness maps are not accepted here; only the transport sender GUID votes.
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
    local match, how = AmbiguousBest(pending, row)
    if how == "ambiguous" then
        -- Relays/replays must not mint unlimited zero-witness ambiguous clusters.
        -- Local writers may retain one ambiguous cluster for recovery export only
        -- when capacity remains; never count the replay as a vote.
        if admissionCtx.localWrite or admissionCtx.exportEvidence then
            local perCap = UnfinishedPendingCount(pending) < (GS.MAX_PENDING_EVIDENCE or 128)
            local totalCap = CountTotalUnfinishedPending(record)
                < (GS.MAX_PENDING_EVIDENCE_TOTAL or 256)
            if perCap and totalCap then
                pending[#pending + 1] = {
                    schemaVersion = 1,
                    status = "ambiguous",
                    evidence = row,
                    witnesses = {},
                    firstSeen = Now(),
                    lastSeen = Now(),
                }
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
        if UnfinishedPendingCount(pending) >= (GS.MAX_PENDING_EVIDENCE or 128) then
            return "rejected", "full"
        end
        if CountTotalUnfinishedPending(record) >= (GS.MAX_PENDING_EVIDENCE_TOTAL or 256) then
            return "rejected", "full"
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
        cluster.lastSeen = Now()
        if boundaryAmbiguous then
            cluster.status = "ambiguous"
        end
        if type(cluster.evidence) == "table" then
            local older = cluster.evidence.neighborsOlder or {}
            local newer = cluster.evidence.neighborsNewer or {}
            if #(row.neighborsOlder or {}) > #older then
                cluster.evidence.neighborsOlder = row.neighborsOlder
            end
            if #(row.neighborsNewer or {}) > #newer then
                cluster.evidence.neighborsNewer = row.neighborsNewer
            end
        end
    end

    if type(cluster.witnesses) ~= "table" then
        cluster.witnesses = {}
    end
    if GS.WitnessAlreadyCounted(record, cluster.witnesses, witnessGuid) then
        local n = GS.CountIndependentWitnesses(record, cluster.witnesses)
        if n >= (GS.WITNESS_THRESHOLD or 3) and cluster.status ~= "verified"
            and cluster.status ~= "ambiguous" then
            TryAutoVerify(record, cluster)
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

    -- Only the originating observer exports this evidence body. Relays must not
    -- re-publish it under a different authenticated sender.
    if admissionCtx.localWrite or admissionCtx.exportEvidence then
        GS.RecordDirectEvidenceExport(record, witnessGuid, row)
    end

    local verified = false
    if cluster.status ~= "ambiguous" then
        verified = TryAutoVerify(record, cluster)
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

--- Reevaluate unfinished evidence after link-map changes (conservative).
-- Compaction may remove the current index; do not skip the shifted cluster.
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
    if typ ~= GS.LEDGER_EVENT.DONATION and typ ~= GS.LEDGER_EVENT.ADJUSTMENT
        and typ ~= "CONSUMABLE_DONATION" and typ ~= "CONSUMABLE_ADJUSTMENT" then
        return false, "invalid_kind"
    end
    local id = ValidTxnId(event.txnId) or (type(event.id) == "string" and event.id)
    if type(id) ~= "string" or id == "" or #id > (GS.MAX_OPERATION_ID or 192) then
        return false, "invalid_id"
    end
    if datasetId and event.datasetId and event.datasetId ~= datasetId then
        return false, "dataset_mismatch"
    end
    if not IsItemId(tonumber(event.itemId)) then
        return false, "invalid_item"
    end
    local qty = tonumber(event.quantity)
    if not qty or qty ~= math.floor(qty) or qty == 0 then
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
    return true
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
    if not isDonation then
        local lists = {
            record.accounting._consumableEvents,
            record.accounting._consumableEventArchive,
        }
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

        -- Pending candidate with same ID: conflict, duplicate, or remint.
        local pendingCands = EnsurePendingDonationCandidates(record)
        local priorCand = pendingCands and pendingCands[txnId]
        if type(priorCand) == "table" then
            local relation = ExactIdOccurrenceRelation(priorCand, candidate)
            if relation == "same" then
                if DonationBodiesConflict(priorCand, candidate) then
                    QuarantineConflictBody(cfg, txnId, candidate)
                    return "rejected", "id_conflict"
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
                if regHit.status == "verified" then
                    AddTxnAlias(cfg, regHit.txnId, txnId)
                    return "duplicate", "occurrence_duplicate"
                end
            end
            local ledHit, ledHow = FindLedgerDonationOccurrence(record, candidate)
            if ledHow == "ambiguous" then
                return "pending", "ambiguous"
            end
            if ledHit and (ledHit.txnId or ledHit.id) ~= txnId then
                AddTxnAlias(cfg, ledHit.txnId or ledHit.id, txnId)
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
                verification = GS.VERIFICATION.WITNESSES,
                coreSignature = candidate.coreSignature,
                occurrenceIndex = candidate.occurrenceIndex,
                guildGuid = candidate.guildGuid,
                bankTab = candidate.bankTab,
                neighborsOlder = candidate.neighborsOlder,
                neighborsNewer = candidate.neighborsNewer,
                campaignId = candidate.campaignId,
                datasetId = record.datasetId,
            }
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
            return "accepted", "adoption_transfer"
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
        local attributed = NormName(event.attributed)
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
            local floorOk, floorErr = GS.AdjustmentFloorOk(
                record, tonumber(event.itemId), qty, attributed, eventCampaign)
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
    local contrib = progress.contributions and progress.contributions[actorName]
    return (contrib and tonumber(contrib[itemId])) or 0
end

local function ItemTotal(record, itemId, campaignId)
    local progress = ProgressOnRecord(record, campaignId)
    if not progress then return 0 end
    return tonumber(progress.itemTotals and progress.itemTotals[itemId]) or 0
end

--- Floor against accepted authoritative projection at commit time.
-- @param campaignId optional; defaults to record.currentCampaignId. Callers that
--   cannot prove historical campaign provenance should reject before calling.
function GS.AdjustmentFloorOk(record, itemId, quantity, attributed, campaignId)
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
    local currentItem = ItemTotal(record, itemId, campaignId)
    if currentItem + quantity < 0 then
        return false, "item_negative"
    end
    if attributed and ActorItemTotal(record, attributed, itemId, campaignId) + quantity < 0 then
        return false, "player_negative"
    end
    return true, nil, attributed
end

function GS:PreviewAdjustment(itemId, quantity, attributed)
    local record, reason = GS:GetCurrentRecord()
    if not record then
        return nil, reason or "not_ready"
    end
    local floorOk, floorErr, normAttr = GS.AdjustmentFloorOk(record, itemId, quantity, attributed)
    if not floorOk then
        return nil, floorErr
    end
    itemId = tonumber(itemId)
    quantity = tonumber(quantity)
    local currentItem = ItemTotal(record, itemId)
    local currentPlayer = normAttr and ActorItemTotal(record, normAttr, itemId) or nil
    return {
        itemId = itemId,
        quantity = quantity,
        attributed = normAttr,
        currentItem = currentItem,
        nextItem = currentItem + quantity,
        currentPlayer = currentPlayer,
        nextPlayer = currentPlayer and (currentPlayer + quantity) or nil,
    }
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

function GS.ApplyAdjustmentMutation(record, op)
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
    local floorOk, floorErr, normAttr = GS.AdjustmentFloorOk(
        record, itemId, quantity, attributed, record.currentCampaignId)
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
