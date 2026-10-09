-- Verification, trust, and canonical contribution generation for Guild Bank observations.
-- Issue #366 PR2: admin trust, three-witness verification, admin decisions, txn identities.
local _, SF = ...

SF.ConsumablesVerification = SF.ConsumablesVerification or {}
local V = SF.ConsumablesVerification
local O = SF.ConsumablesObservation
local C = SF.Consumables

V.WITNESS_THRESHOLD = 3
V.MAX_WITNESSES_PER_CLUSTER = 16
V.MAX_REJECTIONS_PER_SCOPE = 128
V.MAX_PENDING_WITNESS_AGGREGATES = 128
V.MAX_TXN_REGISTRY_SCAN = 256
V.MAX_OBS_BATCH = 32
V.MAX_CLUSTERS = 256
V.MAX_REVIEW_SUMMARY = 40
V.MAX_TXN_ID = 160
V.MAX_OBS_QUANTITY = 100000
V.VERIFICATION = {
    ADMIN_TRUST = "admin_trust",
    WITNESSES = "witnesses",
    MANUAL = "manual",
}

local function Debug(level, message, ...)
    if SF.Debug and SF.Debug[level] then
        SF.Debug[level](SF.Debug, "CONSUMABLES_VERIFY", message, ...)
    end
end

local function Now()
    if type(V._clock) == "function" then
        return V._clock()
    end
    if O and O.Now then
        return O.Now()
    end
    if C and C.Now then
        return C.Now()
    end
    return time()
end

V.Now = Now

local function Norm(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(name) or name
    end
    return name
end

local function Same(a, b)
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b) and true or false
    end
    return a ~= nil and a == b
end

local function FloorNonNeg(n)
    n = tonumber(n) or 0
    if n < 0 then return 0 end
    return math.floor(n)
end

function V.ValidTxnId(txnId)
    if type(txnId) ~= "string" or txnId == "" or #txnId > V.MAX_TXN_ID then
        return nil
    end
    if not txnId:match("^ctx:") then
        return nil
    end
    return txnId
end

function V.ValidGoldValueCopper(value)
    if value == nil then return nil end
    local n = tonumber(value)
    if not n or n ~= math.floor(n) or n < 0 then
        return nil
    end
    return n
end

local function LinkedSame(profile, a, b)
    a, b = Norm(a), Norm(b)
    if not a or not b then return false end
    if Same(a, b) then return true end
    if type(profile) == "table" and type(profile.AreSameIdentity) == "function" then
        local ok, res = pcall(profile.AreSameIdentity, profile, a, b)
        if ok and res then return true end
    end
    return false
end

function V.WitnessAlreadyCounted(witnessMap, submittedBy, profile)
    submittedBy = Norm(submittedBy)
    if not submittedBy or type(witnessMap) ~= "table" then return true end
    for key, row in pairs(witnessMap) do
        if type(row) == "table" then
            local prior = Norm(row.submittedBy) or Norm(key)
            if prior and LinkedSame(profile, prior, submittedBy) then
                return true
            end
        elseif LinkedSame(profile, key, submittedBy) then
            return true
        end
    end
    return false
end

function V.CountIndependentWitnesses(witnessMap, profile)
    if type(witnessMap) ~= "table" then return 0 end
    local keys = {}
    for key, row in pairs(witnessMap) do
        local name = type(row) == "table" and (Norm(row.submittedBy) or Norm(key)) or Norm(key)
        if name then
            keys[#keys + 1] = name
        end
    end
    table.sort(keys)
    local counted = {}
    local n = 0
    for i = 1, #keys do
        local name = keys[i]
        local skip = false
        for j = 1, #counted do
            if LinkedSame(profile, counted[j], name) then
                skip = true
                break
            end
        end
        if not skip then
            counted[#counted + 1] = name
            n = n + 1
        end
    end
    return n
end

function V.SerializeObservation(obs)
    if type(obs) ~= "table" then return nil end
    local donor = Norm(obs.donor)
    local itemId = tonumber(obs.itemId)
    local quantity = FloorNonNeg(obs.quantity)
    if not donor or not itemId or quantity < 1 then return nil end
    return {
        localId = type(obs.localId) == "string" and obs.localId or nil,
        coreSignature = type(obs.coreSignature) == "string" and obs.coreSignature or nil,
        type = obs.type == "deposit" and "deposit" or nil,
        donor = donor,
        itemId = itemId,
        quantity = quantity,
        guildGuid = type(obs.guildGuid) == "string" and obs.guildGuid or nil,
        bankTab = tonumber(obs.bankTab),
        generation = tonumber(obs.generation),
        approxTxnTime = tonumber(obs.approxTxnTime),
        ageHours = tonumber(obs.ageHours),
        occurrenceIndex = tonumber(obs.occurrenceIndex),
        neighborsOlder = type(obs.neighborsOlder) == "table" and obs.neighborsOlder or nil,
        neighborsNewer = type(obs.neighborsNewer) == "table" and obs.neighborsNewer or nil,
        observedBy = Norm(obs.observedBy),
        firstSeen = tonumber(obs.firstSeen),
        status = obs.status,
        txnId = V.ValidTxnId(obs.txnId),
    }
end

function V.ValidateObservationPayload(obs)
    if type(obs) ~= "table" then return false, "invalid" end
    if obs.type ~= "deposit" then return false, "invalid" end
    if type(obs.donor) ~= "string" or obs.donor == "" then return false, "invalid" end
    if type(obs.guildGuid) ~= "string" or obs.guildGuid == "" then return false, "invalid" end
    local tab = tonumber(obs.bankTab)
    if not tab or tab < 1 or tab > 8 or tab ~= math.floor(tab) then return false, "invalid" end
    local itemId = tonumber(obs.itemId)
    if not itemId or itemId < 1 or itemId ~= math.floor(itemId) then return false, "invalid" end
    local qty = tonumber(obs.quantity)
    local maxQty = V.MAX_OBS_QUANTITY
    if SF.ConsumablesSync and tonumber(SF.ConsumablesSync.MAX_EVENT_QUANTITY) then
        maxQty = tonumber(SF.ConsumablesSync.MAX_EVENT_QUANTITY)
    end
    if not qty or qty < 1 or qty ~= math.floor(qty) or qty > maxQty then
        return false, "invalid"
    end
    if type(obs.coreSignature) ~= "string" or obs.coreSignature == "" then return false, "invalid" end
    return true
end

local function MixText(hash, text)
    text = tostring(text or "")
    local h = FloorNonNeg(hash)
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 2147483647
    end
    return h
end

-- Neighbor / continuity context used for conservative matching only.
-- Not used to mint canonical Spectrum transaction IDs.
function V.HasStrongIdentityContext(evidence)
    if type(evidence) ~= "table" then return false end
    local older = evidence.neighborsOlder
    local newer = evidence.neighborsNewer
    if type(older) == "table" and #older > 0 then return true end
    if type(newer) == "table" and #newer > 0 then return true end
    return false
end

-- Deprecated: Blizzard-derived IDs are not used. Kept as a nil stub for older tests/callers.
function V.TxnIdFromEvidence(_profileId, _evidence)
    return nil
end

local function RegistryMatchView(entry)
    return {
        coreSignature = entry.coreSignature,
        guildGuid = entry.guildGuid,
        bankTab = entry.bankTab,
        generation = entry.generation,
        approxTxnTime = tonumber(entry.approxTxnTime),
        occurrenceIndex = entry.occurrenceIndex,
        neighborsOlder = entry.neighborsOlder,
        neighborsNewer = entry.neighborsNewer,
        firstSeen = entry.approxTxnTime,
        lastSeen = entry.approxTxnTime,
        status = "pending",
    }
end

local function LedgerEvidenceView(event)
    return {
        coreSignature = event.coreSignature,
        guildGuid = event.guildGuid,
        bankTab = event.bankTab,
        generation = event.generation,
        approxTxnTime = tonumber(event.timestamp) or tonumber(event.approxTxnTime),
        occurrenceIndex = event.occurrenceIndex,
        neighborsOlder = event.neighborsOlder,
        neighborsNewer = event.neighborsNewer,
        firstSeen = event.timestamp,
        lastSeen = event.timestamp,
        ageHours = event.ageHours,
        status = "pending",
    }
end

-- Conservative reconciliation against the synchronized canonical registry.
-- Returns how ("verified"|"rejected"|"ambiguous"|"none"), entry, score.
function V.ReconcileAgainstRegistry(profile, evidence)
    if not C or not C.TxnRegistry or type(profile) ~= "table" or type(evidence) ~= "table" then
        return "none", nil, nil
    end
    if not (O and O.MatchScore) then
        return "none", nil, nil
    end
    local list = C.TxnRegistry(profile)
    local bestVerified, bestVerifiedScore = nil, nil
    local secondVerifiedScore = nil
    local bestRejected, bestRejectedScore = nil, nil
    local scanned = 0
    local start = #list
    for i = start, 1, -1 do
        scanned = scanned + 1
        if scanned > V.MAX_TXN_REGISTRY_SCAN then break end
        local entry = list[i]
        if type(entry) == "table"
            and tonumber(entry.generation) == tonumber(evidence.generation)
            and tostring(entry.guildGuid or "") == tostring(evidence.guildGuid or "")
            and tonumber(entry.bankTab) == tonumber(evidence.bankTab)
        then
            local score = O.MatchScore(RegistryMatchView(entry), evidence)
            if score and score >= (O.MIN_MATCH_SCORE or 100) then
                if entry.status == "rejected" then
                    if not bestRejectedScore or score > bestRejectedScore then
                        bestRejected, bestRejectedScore = entry, score
                    end
                else
                    if not bestVerifiedScore or score > bestVerifiedScore then
                        secondVerifiedScore = bestVerifiedScore
                        bestVerified, bestVerifiedScore = entry, score
                    elseif not secondVerifiedScore or score > secondVerifiedScore then
                        secondVerifiedScore = score
                    end
                end
            end
        end
    end
    if bestVerified and secondVerifiedScore
        and (bestVerifiedScore - secondVerifiedScore) < (O.AMBIGUITY_MARGIN or 15)
    then
        return "ambiguous", bestVerified, bestVerifiedScore
    end
    if bestVerified then
        return "verified", bestVerified, bestVerifiedScore
    end
    if bestRejected then
        return "rejected", bestRejected, bestRejectedScore
    end
    return "none", nil, nil
end

function V.RegistryEntryFromEvidence(evidence, txnId, status, writer, verification, opts)
    opts = opts or {}
    if type(evidence) ~= "table" then return nil end
    txnId = V.ValidTxnId(txnId)
    if not txnId then return nil end
    return {
        txnId = txnId,
        status = status == "rejected" and "rejected" or "verified",
        committed = opts.committed == true,
        coreSignature = evidence.coreSignature,
        approxTxnTime = tonumber(evidence.approxTxnTime),
        donor = Norm(evidence.donor),
        itemId = tonumber(evidence.itemId),
        quantity = FloorNonNeg(evidence.quantity),
        guildGuid = evidence.guildGuid,
        bankTab = tonumber(evidence.bankTab),
        generation = tonumber(evidence.generation),
        occurrenceIndex = tonumber(evidence.occurrenceIndex),
        neighborsOlder = evidence.neighborsOlder,
        neighborsNewer = evidence.neighborsNewer,
        verification = verification,
        decidedBy = Norm(writer),
        decidedAt = Now(),
        reason = opts.reason,
    }
end

-- Mint a Spectrum-owned ID and register evidence for future reconciliation.
function V.AllocateCanonicalTxn(profile, evidence, writer, verification, opts)
    opts = opts or {}
    if not C or not C.AllocateCanonicalTxnId or type(profile) ~= "table" then
        return nil
    end
    local txnId = C.AllocateCanonicalTxnId(profile, writer)
    if not txnId then return nil end
    local entry = V.RegistryEntryFromEvidence(evidence, txnId, "verified", writer, verification, opts)
    if entry then
        C.RegisterCanonicalTxn(profile, entry, { bumpSeq = opts.bumpSeq })
    end
    return txnId
end

-- Compatibility wrapper: prefer registry allocation when a profile is supplied.
function V.NextTxnId(store, profileId, evidence, opts)
    opts = opts or {}
    local profile = opts.profile
    local writer = opts.writer
    if profile and C and C.AllocateCanonicalTxnId then
        return V.AllocateCanonicalTxn(profile, evidence, writer or (SF.NameUtil and SF.NameUtil.GetSelfId and SF.NameUtil.GetSelfId()), opts.verification, {
            bumpSeq = opts.bumpSeq,
            committed = false,
        })
    end
    -- Last-resort local mint when no profile is available (tests / early boot).
    if type(store) ~= "table" then return nil end
    store.txnSeq = FloorNonNeg(store.txnSeq) + 1
    local pid = tostring(profileId or "profile")
    if #pid > 40 then pid = pid:sub(1, 40) end
    writer = Norm(writer)
    if not writer and SF.NameUtil and SF.NameUtil.GetSelfId then
        writer = Norm(SF.NameUtil.GetSelfId())
    end
    if writer and #writer > 32 then writer = writer:sub(1, 32) end
    return string.format("ctx:%s:%s:%d", pid, writer or "local", store.txnSeq)
end

-- Match an existing guildbank donation via registry first, then ledger MatchScore.
function V.FindEquivalentLedgerDonation(profile, profileId, evidence)
    if not C or type(profile) ~= "table" or type(evidence) ~= "table" then
        return nil
    end
    local how, entry = V.ReconcileAgainstRegistry(profile, evidence)
    if how == "verified" and entry and V.ValidTxnId(entry.txnId) then
        if C.HasTxnId and C.HasTxnId(profile, entry.txnId) then
            local lists = { profile._consumableEvents, profile._consumableEventArchive }
            for li = 1, #lists do
                local list = lists[li]
                if type(list) == "table" then
                    for i = 1, #list do
                        local event = list[i]
                        if type(event) == "table" and V.ValidTxnId(event.txnId) == entry.txnId then
                            return event
                        end
                    end
                end
            end
        end
        -- Registry hit without ledger row yet: synthesize a continuity view.
        return {
            txnId = entry.txnId,
            verification = entry.verification,
            writer = entry.decidedBy,
            generation = entry.generation,
            guildGuid = entry.guildGuid,
            bankTab = entry.bankTab,
            coreSignature = entry.coreSignature,
            occurrenceIndex = entry.occurrenceIndex,
            neighborsOlder = entry.neighborsOlder,
            neighborsNewer = entry.neighborsNewer,
            timestamp = entry.approxTxnTime,
            source = "guildbank",
            type = C.EVENT and C.EVENT.DONATION or "CONSUMABLE_DONATION",
            _registryOnly = true,
        }
    end
    if how == "ambiguous" then
        return nil
    end
    local lists = { profile._consumableEvents, profile._consumableEventArchive }
    local best, bestScore = nil, nil
    for li = 1, #lists do
        local list = lists[li]
        if type(list) == "table" then
            for i = 1, #list do
                local event = list[i]
                if type(event) == "table"
                    and event.type == (C.EVENT and C.EVENT.DONATION or "CONSUMABLE_DONATION")
                    and event.source == "guildbank"
                then
                    if tonumber(event.generation) == tonumber(evidence.generation)
                        and tostring(event.guildGuid or "") == tostring(evidence.guildGuid or "")
                        and tonumber(event.bankTab) == tonumber(evidence.bankTab)
                        and O and O.MatchScore
                    then
                        local score = O.MatchScore(LedgerEvidenceView(event), evidence)
                        if score and (not bestScore or score > bestScore) then
                            best, bestScore = event, score
                        end
                    end
                end
            end
        end
    end
    return best
end

function V.BuildDonationEvent(evidence, writer, txnId, verification, opts)
    opts = opts or {}
    if type(evidence) ~= "table" then return nil end
    txnId = V.ValidTxnId(txnId)
    writer = Norm(writer)
    local donor = Norm(evidence.donor)
    local itemId = tonumber(evidence.itemId)
    local quantity = FloorNonNeg(evidence.quantity)
    if not txnId or not writer or not donor or not itemId or quantity < 1 then
        return nil
    end
    local event = {
        type = C and C.EVENT and C.EVENT.DONATION or "CONSUMABLE_DONATION",
        generation = tonumber(evidence.generation) or 1,
        timestamp = tonumber(evidence.approxTxnTime) or tonumber(evidence.firstSeen) or Now(),
        actor = donor,
        itemId = itemId,
        quantity = quantity,
        source = "guildbank",
        writer = writer,
        txnId = txnId,
        verification = verification,
        -- Durable identity context for cross-observer ledger matching.
        coreSignature = type(evidence.coreSignature) == "string" and evidence.coreSignature or nil,
        occurrenceIndex = tonumber(evidence.occurrenceIndex),
        guildGuid = type(evidence.guildGuid) == "string" and evidence.guildGuid or nil,
        bankTab = tonumber(evidence.bankTab),
        neighborsOlder = type(evidence.neighborsOlder) == "table" and evidence.neighborsOlder or nil,
        neighborsNewer = type(evidence.neighborsNewer) == "table" and evidence.neighborsNewer or nil,
        -- Reserved for a future monetary feature; leave unset (nil), never 0.
        goldValueCopper = V.ValidGoldValueCopper(opts.goldValueCopper),
    }
    return event
end

function V.RejectionRecord(evidence, decidedBy, now, reason)
    return {
        type = "deposit",
        coreSignature = evidence.coreSignature,
        approxTxnTime = tonumber(evidence.approxTxnTime),
        donor = Norm(evidence.donor),
        itemId = tonumber(evidence.itemId),
        quantity = FloorNonNeg(evidence.quantity),
        guildGuid = evidence.guildGuid,
        bankTab = tonumber(evidence.bankTab),
        generation = tonumber(evidence.generation),
        occurrenceIndex = tonumber(evidence.occurrenceIndex),
        neighborsOlder = evidence.neighborsOlder,
        neighborsNewer = evidence.neighborsNewer,
        decidedBy = Norm(decidedBy),
        decidedAt = tonumber(now) or Now(),
        reason = type(reason) == "string" and reason or "rejected",
        txnId = V.ValidTxnId(evidence.txnId),
        observedBy = evidence.observedBy,
        firstSeen = tonumber(evidence.firstSeen) or tonumber(now) or Now(),
        status = "rejected",
    }
end

local function NeighborOverlap(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a == 0 or #b == 0 then
        return nil
    end
    for i = 1, #a do
        for j = 1, #b do
            if a[i] == b[j] then return true end
        end
    end
    return false
end

function V.RejectionMatches(rejection, evidence)
    if type(rejection) ~= "table" or type(evidence) ~= "table" then return false end
    if not (O and O.SuppressionMatches and O.SuppressionMatches(rejection, evidence)) then
        return false
    end
    -- Distinct deposits that share donor/item/qty inside the time window must not
    -- collapse onto one rejection. Prefer occurrence index and neighbor context.
    local rOcc = tonumber(rejection.occurrenceIndex)
    local eOcc = tonumber(evidence.occurrenceIndex)
    if rOcc and eOcc and rOcc ~= eOcc then
        return false
    end
    local olderHit = NeighborOverlap(rejection.neighborsOlder, evidence.neighborsOlder)
    if olderHit == false then return false end
    local newerHit = NeighborOverlap(rejection.neighborsNewer, evidence.neighborsNewer)
    if newerHit == false then return false end
    return true
end

function V.EnsureScopeExtras(scope)
    if type(scope) ~= "table" then return nil end
    if type(scope.rejections) ~= "table" then scope.rejections = {} end
    if type(scope.verifiedTxnIds) ~= "table" then scope.verifiedTxnIds = {} end
    return scope
end

function V.IsRejected(scope, evidence)
    scope = V.EnsureScopeExtras(scope)
    if not scope then return false end
    for i = 1, #scope.rejections do
        if V.RejectionMatches(scope.rejections[i], evidence) then
            return true, scope.rejections[i]
        end
    end
    return false
end

function V.RecordRejection(scope, evidence, decidedBy, now, reason)
    scope = V.EnsureScopeExtras(scope)
    if not scope then return false end
    if V.IsRejected(scope, evidence) then return true end
    local list = scope.rejections
    list[#list + 1] = V.RejectionRecord(evidence, decidedBy, now, reason)
    while #list > V.MAX_REJECTIONS_PER_SCOPE do
        table.remove(list, 1)
    end
    -- Also suppress rediscovery through the observation suppression list.
    if type(scope.suppressions) == "table" then
        scope.suppressions[#scope.suppressions + 1] = {
            coreSignature = evidence.coreSignature,
            approxTxnTime = evidence.approxTxnTime,
            firstSeen = tonumber(evidence.firstSeen) or now,
            reason = "rejected",
            expiredAt = tonumber(now) or Now(),
        }
    end
    return true
end

function V.ClearMatchingRejection(scope, evidence)
    scope = V.EnsureScopeExtras(scope)
    if not scope then return false end
    local kept = {}
    local cleared = false
    for i = 1, #scope.rejections do
        if V.RejectionMatches(scope.rejections[i], evidence) then
            cleared = true
        else
            kept[#kept + 1] = scope.rejections[i]
        end
    end
    scope.rejections = kept
    return cleared
end

function V.FindMatchingObservation(scope, evidence)
    if type(scope) ~= "table" or type(evidence) ~= "table" or not O or not O.MatchScore then
        return nil, nil
    end
    local best, bestScore, second = nil, nil, nil
    for i = 1, #(scope.observations or {}) do
        local obs = scope.observations[i]
        local score = O.MatchScore(obs, evidence)
        if score and score >= (O.MIN_MATCH_SCORE or 100) then
            if not bestScore or score > bestScore then
                second = bestScore
                best, bestScore = obs, score
            elseif not second or score > second then
                second = score
            end
        end
    end
    if best and second and (bestScore - second) < (O.AMBIGUITY_MARGIN or 15) then
        return best, "ambiguous"
    end
    return best, best and "match" or nil
end

-- Coordinator in-memory pending clusters (rebuilt each session from reports).
local sessionClusters = {}

function V.ClearSessionClusters()
    sessionClusters = {}
end

local function ClusterKey(profileId)
    return tostring(profileId or "")
end

function V.EnsureClusterStore(profileId)
    local key = ClusterKey(profileId)
    local store = sessionClusters[key]
    if type(store) ~= "table" then
        store = { clusters = {}, seq = 0 }
        sessionClusters[key] = store
    end
    if type(store.clusters) ~= "table" then store.clusters = {} end
    return store
end

local function PruneClusters(store)
    local clusters = store.clusters
    if type(clusters) ~= "table" or #clusters <= V.MAX_CLUSTERS then return end
    -- Drop oldest terminal clusters first, then oldest pending.
    local function rank(c)
        if c.status == "rejected" then return 0 end
        if c.status == "verified" and c._committed then return 1 end
        if c.status == "verified" then return 2 end
        return 3
    end
    table.sort(clusters, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return FloorNonNeg(a.updatedAt) < FloorNonNeg(b.updatedAt)
    end)
    while #clusters > V.MAX_CLUSTERS do
        table.remove(clusters, 1)
    end
end

local function NewCluster(store, evidence)
    store.seq = FloorNonNeg(store.seq) + 1
    local cluster = {
        clusterId = string.format("cl:%d", store.seq),
        evidence = evidence,
        witnesses = {},
        status = evidence.status == "ambiguous" and "ambiguous" or "pending",
        verification = nil,
        txnId = V.ValidTxnId(evidence.txnId),
        decidedBy = nil,
        updatedAt = Now(),
    }
    store.clusters[#store.clusters + 1] = cluster
    PruneClusters(store)
    return cluster
end

function V.MatchCluster(store, evidence)
    if type(store) ~= "table" or type(evidence) ~= "table" or not O or not O.MatchScore then
        return nil, nil
    end
    local best, bestScore, second = nil, nil, nil
    local bestVerified, bestVerifiedScore = nil, nil
    for i = 1, #store.clusters do
        local cluster = store.clusters[i]
        if cluster.status ~= "rejected" then
            local score = O.MatchScore(cluster.evidence, evidence)
            if score and score >= (O.MIN_MATCH_SCORE or 100) then
                if cluster.status == "verified" then
                    if not bestVerifiedScore or score > bestVerifiedScore then
                        bestVerified, bestVerifiedScore = cluster, score
                    end
                else
                    if not bestScore or score > bestScore then
                        second = bestScore
                        best, bestScore = cluster, score
                    elseif not second or score > second then
                        second = score
                    end
                end
            end
        end
    end
    -- Prefer an already-verified match so rematches never mint a second txnId.
    if bestVerified then
        return bestVerified, "verified"
    end
    if best and second and (bestScore - second) < (O.AMBIGUITY_MARGIN or 15) then
        best.status = "ambiguous"
        return best, "ambiguous"
    end
    return best, best and "match" or nil
end

local function AddWitness(cluster, submittedBy, evidence, profile)
    if V.WitnessAlreadyCounted(cluster.witnesses, submittedBy, profile) then
        return
    end
    local count = 0
    for _ in pairs(cluster.witnesses) do count = count + 1 end
    if count >= V.MAX_WITNESSES_PER_CLUSTER then return end
    cluster.witnesses[submittedBy] = {
        submittedBy = submittedBy,
        observedBy = evidence.observedBy,
        firstReported = Now(),
    }
end

-- Rebuild in-memory clusters from durable pending-witness aggregates so staggered
-- session reporters and coordinator handoffs keep authenticated witness progress.
function V.HydrateClustersFromDurable(profile, profileId)
    if not C or not C.PendingWitnesses or type(profile) ~= "table" then
        return 0
    end
    local durable = C.PendingWitnesses(profile)
    if type(durable) ~= "table" or #durable == 0 then return 0 end
    local store = V.EnsureClusterStore(profileId)
    local added = 0
    for i = 1, #durable do
        local agg = durable[i]
        if type(agg) == "table" and type(agg.evidence) == "table" then
            local cluster = select(1, V.MatchCluster(store, agg.evidence))
            if not cluster then
                cluster = NewCluster(store, agg.evidence)
                added = added + 1
            end
            if type(agg.witnesses) == "table" then
                for submittedBy, meta in pairs(agg.witnesses) do
                    if type(submittedBy) == "string" then
                        local evidence = agg.evidence
                        if type(meta) == "table" and meta.observedBy then
                            evidence = {
                                coreSignature = agg.evidence.coreSignature,
                                observedBy = meta.observedBy,
                                donor = agg.evidence.donor,
                                itemId = agg.evidence.itemId,
                                quantity = agg.evidence.quantity,
                            }
                        end
                        AddWitness(cluster, submittedBy, evidence, profile)
                    end
                end
            end
            cluster.updatedAt = Now()
        end
    end
    return added
end

-- Floored whole-hour Guild Bank ages can place the real deposit up to ~1h earlier
-- than approxTxnTime. Only treat evidence as clearly post-baseline when that
-- earliest bound is still at/after the baseline; missing age stays held.
local function EvidenceClearlyNew(evidence, baselineAt)
    local baseline = tonumber(baselineAt)
    if not baseline or type(evidence) ~= "table" then return false end
    local approx = tonumber(evidence.approxTxnTime)
    local ageHours = tonumber(evidence.ageHours)
    if not approx or ageHours == nil then return false end
    return (approx - 3600) >= baseline
end

local function HasRecoveredVerifiedIdentity(profile, cluster)
    if type(cluster) ~= "table" or not C then return false end
    local txnId = V.ValidTxnId(cluster.txnId)
    if not txnId then return false end
    if C.HasTxnId and C.HasTxnId(profile, txnId) then return true end
    local entry = C.FindRegistryTxn and C.FindRegistryTxn(profile, txnId)
    return type(entry) == "table" and entry.status == "verified"
end

-- Preserve recovered decision provenance without treating it as the commit writer.
local function ApplyRecoveredProvenance(cluster, writer, verification)
    if type(cluster) ~= "table" then return end
    if verification then
        cluster.verification = verification
    elseif not cluster.verification then
        cluster.verification = V.VERIFICATION.MANUAL
    end
    if not Norm(cluster.decidedBy) then
        cluster.decidedBy = Norm(writer)
    end
end

-- Authorized writer for a newly emitted ledger event. Prefer the current self
-- when they are a canonical admin; otherwise fall back to recovered decidedBy.
local function CommitWriterForCluster(profile, cluster)
    local selfId = SF.NameUtil and SF.NameUtil.GetSelfId and Norm(SF.NameUtil.GetSelfId()) or nil
    if selfId and C and C.IsCanonicalAdmin and C.IsCanonicalAdmin(profile, selfId) then
        return selfId
    end
    return Norm(cluster and cluster.decidedBy) or selfId
end

-- Adopt a recovered verified ledger/registry identity onto the cluster.
-- Local rejection IDs do not count as recovered; evidence match can replace them.
local function AdoptRecoveredTxnId(profile, profileId, cluster)
    if not cluster or type(cluster.evidence) ~= "table" then return false end
    if HasRecoveredVerifiedIdentity(profile, cluster) then
        if not Norm(cluster.decidedBy) and C and C.FindRegistryTxn then
            local entry = C.FindRegistryTxn(profile, cluster.txnId)
            if type(entry) == "table" then
                ApplyRecoveredProvenance(cluster, entry.decidedBy, entry.verification)
            end
        end
        return true
    end
    local ledgerHit = V.FindEquivalentLedgerDonation and V.FindEquivalentLedgerDonation(
        profile, profileId, cluster.evidence)
    if ledgerHit and V.ValidTxnId(ledgerHit.txnId) then
        cluster.txnId = ledgerHit.txnId
        ApplyRecoveredProvenance(
            cluster,
            ledgerHit.writer or ledgerHit.decidedBy,
            ledgerHit.verification
        )
        return true
    end
    local regHow, regEntry = V.ReconcileAgainstRegistry(profile, cluster.evidence)
    if regHow == "verified" and regEntry and V.ValidTxnId(regEntry.txnId) then
        cluster.txnId = regEntry.txnId
        ApplyRecoveredProvenance(cluster, regEntry.decidedBy, regEntry.verification)
        return true
    end
    return false
end

function V.IngestReport(profile, profileId, submittedBy, observations, opts)
    opts = opts or {}
    submittedBy = Norm(submittedBy)
    if not submittedBy or type(observations) ~= "table" then
        return { accepted = 0, verified = 0, rejected = 0 }
    end
    local store = V.EnsureClusterStore(profileId)
    V.HydrateClustersFromDurable(profile, profileId)
    local stats = {
        accepted = 0, verified = 0, rejected = 0, pending = 0, skipped = 0, witnessChanged = 0,
    }
    local isAdmin = opts.isAdmin == true
    local limit = #observations
    if limit > V.MAX_OBS_BATCH then limit = V.MAX_OBS_BATCH end
    local eligibility = opts.eligibility
    local requiredGuild = opts.guildGuid
    local requiredTab = tonumber(opts.bankTab)
    local isRequested = opts.isRequested

    for i = 1, limit do
        local raw = observations[i]
        if V.ValidateObservationPayload(raw) then
            local evidence = V.SerializeObservation(raw)
            if evidence then
                local inScope = true
                if type(requiredGuild) == "string" and evidence.guildGuid ~= requiredGuild then
                    inScope = false
                end
                if requiredTab and tonumber(evidence.bankTab) ~= requiredTab then
                    inScope = false
                end
                if inScope and type(isRequested) == "function" and not isRequested(evidence.itemId) then
                    inScope = false
                end
                if inScope and eligibility and O and O.IsEvidenceEligible
                    and not O.IsEvidenceEligible(evidence, eligibility) then
                    inScope = false
                end
                if not inScope then
                    stats.skipped = stats.skipped + 1
                else
                    -- Authenticated sender is the witness; never trust client isAdmin.
                    evidence.submittedBy = submittedBy
                    local rejected = false
                    if opts.scope and V.IsRejected(opts.scope, evidence) then
                        rejected = true
                    elseif opts.durableRejections
                        and V.IsRejected({ rejections = opts.durableRejections }, evidence) then
                        rejected = true
                    end
                    local regHow, regEntry = V.ReconcileAgainstRegistry(profile, evidence)
                    if rejected or regHow == "rejected" then
                        stats.rejected = stats.rejected + 1
                        Debug("Info", "report suppressed by prior rejection donor=%s item=%s",
                            tostring(evidence.donor), tostring(evidence.itemId))
                    else
                        local cluster, how = V.MatchCluster(store, evidence)
                        if regHow == "ambiguous" then
                            if not cluster then
                                cluster = NewCluster(store, evidence)
                            end
                            cluster.status = "ambiguous"
                            cluster.evidence = evidence
                            how = "ambiguous"
                        elseif how ~= "verified" then
                            local ledgerHit = V.FindEquivalentLedgerDonation(profile, profileId, evidence)
                            -- Adopt recovered ledger/registry identity onto an
                            -- unambiguous pending cluster that still lacks txnId.
                            -- Competing ambiguous matches must stay for review:
                            -- attaching a recovered ID could verify the wrong deposit.
                            local canAdopt = how ~= "ambiguous"
                                and (not cluster or (
                                    not V.ValidTxnId(cluster.txnId)
                                    and cluster.status ~= "ambiguous"
                                ))
                            if ledgerHit and V.ValidTxnId(ledgerHit.txnId) and canAdopt then
                                if not cluster then
                                    cluster = NewCluster(store, evidence)
                                end
                                cluster.status = "verified"
                                cluster.verification = ledgerHit.verification or V.VERIFICATION.MANUAL
                                cluster.txnId = ledgerHit.txnId
                                cluster._committed = (not ledgerHit._registryOnly)
                                    and C.HasTxnId and C.HasTxnId(profile, ledgerHit.txnId)
                                cluster.decidedBy = Norm(ledgerHit.writer) or submittedBy
                                cluster.evidence = evidence
                                how = "verified"
                            elseif regHow == "verified" and regEntry and canAdopt then
                                if not cluster then
                                    cluster = NewCluster(store, evidence)
                                end
                                cluster.status = "verified"
                                cluster.verification = regEntry.verification or V.VERIFICATION.MANUAL
                                cluster.txnId = regEntry.txnId
                                cluster._committed = regEntry.committed == true
                                    or (C.HasTxnId and C.HasTxnId(profile, regEntry.txnId))
                                cluster.decidedBy = Norm(regEntry.decidedBy) or submittedBy
                                cluster.evidence = evidence
                                how = "verified"
                            elseif not cluster then
                                cluster = NewCluster(store, evidence)
                            else
                                cluster.evidence = evidence
                                if how == "ambiguous" then
                                    cluster.status = "ambiguous"
                                end
                            end
                        end

                        local before = V.CountIndependentWitnesses(cluster.witnesses, profile)
                        AddWitness(cluster, submittedBy, evidence, profile)
                        local after = V.CountIndependentWitnesses(cluster.witnesses, profile)
                        cluster.updatedAt = Now()
                        stats.accepted = stats.accepted + 1
                        if after > before then
                            stats.witnessChanged = stats.witnessChanged + 1
                            if opts.recordPendingWitness and type(opts.recordPendingWitness) == "function" then
                                opts.recordPendingWitness(evidence, submittedBy, cluster.witnesses)
                            end
                        end

                        local historyReady = opts.historyComplete ~= false
                        local clearlyNew = EvidenceClearlyNew(evidence, opts.historyBaselineAt)
                        if how == "verified" or cluster.status == "verified" or cluster.status == "rejected" then
                            if opts.clearPendingWitness and type(opts.clearPendingWitness) == "function" then
                                opts.clearPendingWitness(evidence)
                            end
                        elseif cluster.status == "ambiguous" then
                            stats.pending = stats.pending + 1
                        elseif not historyReady and not cluster.txnId and not clearlyNew then
                            -- Incomplete synchronized history: never mint overlapping credits.
                            -- Clearly-new requires earliest-possible time at/after baseline.
                            stats.pending = stats.pending + 1
                            Debug("Info", "holding uncertain credit until history converges donor=%s",
                                tostring(evidence.donor))
                        elseif isAdmin and cluster.status ~= "ambiguous" then
                            cluster.status = "verified"
                            cluster.verification = V.VERIFICATION.ADMIN_TRUST
                            cluster.decidedBy = submittedBy
                            cluster.txnId = cluster.txnId or V.AllocateCanonicalTxn(
                                profile, evidence, submittedBy, V.VERIFICATION.ADMIN_TRUST)
                            stats.verified = stats.verified + 1
                            if opts.clearPendingWitness and type(opts.clearPendingWitness) == "function" then
                                opts.clearPendingWitness(evidence)
                            end
                            Debug("Info", "admin-trusted verification txn=%s donor=%s",
                                tostring(cluster.txnId), tostring(evidence.donor))
                        elseif cluster.status ~= "ambiguous" then
                            local witnesses = after
                            if witnesses >= V.WITNESS_THRESHOLD then
                                if not historyReady and not cluster.txnId and not clearlyNew then
                                    stats.pending = stats.pending + 1
                                else
                                    cluster.status = "verified"
                                    cluster.verification = V.VERIFICATION.WITNESSES
                                    cluster.decidedBy = submittedBy
                                    cluster.txnId = cluster.txnId or V.AllocateCanonicalTxn(
                                        profile, evidence, submittedBy, V.VERIFICATION.WITNESSES)
                                    stats.verified = stats.verified + 1
                                    if opts.clearPendingWitness and type(opts.clearPendingWitness) == "function" then
                                        opts.clearPendingWitness(evidence)
                                    end
                                    Debug("Info", "three-witness verification txn=%s witnesses=%s",
                                        tostring(cluster.txnId), tostring(witnesses))
                                end
                            else
                                stats.pending = stats.pending + 1
                            end
                        else
                            stats.pending = stats.pending + 1
                        end
                    end
                end
            end
        end
    end
    return stats
end

function V.ApplyDecision(profile, profileId, decidedBy, decision, opts)
    opts = opts or {}
    decidedBy = Norm(decidedBy)
    if not decidedBy or type(decision) ~= "table" then
        return false, "invalid"
    end
    if not opts.isAdmin then
        return false, "unauthorized"
    end
    local action = decision.action
    if action ~= "approve" and action ~= "reject" and action ~= "correct" then
        return false, "invalid"
    end
    local store = V.EnsureClusterStore(profileId)
    local cluster = nil
    if type(decision.clusterId) == "string" then
        for i = 1, #store.clusters do
            if store.clusters[i].clusterId == decision.clusterId then
                cluster = store.clusters[i]
                break
            end
        end
        -- Durable rejection rows use synthetic rej:N ids after session reset.
        if not cluster and decision.clusterId:match("^rej:%d+$") and C and C.DurableRejections then
            local idx = tonumber(decision.clusterId:match("^rej:(%d+)$"))
            local durable = C.DurableRejections(profile)
            local rej = idx and durable and durable[idx] or nil
            if type(rej) == "table" then
                local evidence = decision.evidence or rej
                if type(evidence) == "table" and not evidence.type then
                    evidence = {}
                    for k, v in pairs(rej) do evidence[k] = v end
                    evidence.type = "deposit"
                    evidence.status = "rejected"
                end
                if V.ValidateObservationPayload(evidence) then
                    cluster = NewCluster(store, V.SerializeObservation(evidence) or evidence)
                    cluster.status = "rejected"
                end
            end
        end
    end
    if not cluster and type(decision.evidence) == "table" then
        cluster = select(1, V.MatchCluster(store, decision.evidence))
        -- MatchCluster skips rejected rows; correction/reject-by-evidence must still find them.
        if not cluster and O and O.MatchScore then
            local best, bestScore = nil, nil
            for i = 1, #store.clusters do
                local candidate = store.clusters[i]
                if candidate.status == "rejected" then
                    local score = O.MatchScore(candidate.evidence, decision.evidence)
                    if score and score >= (O.MIN_MATCH_SCORE or 100) then
                        if not bestScore or score > bestScore then
                            best, bestScore = candidate, score
                        end
                    end
                end
            end
            cluster = best
        end
        if not cluster then
            local evidence = decision.evidence
            if type(evidence) == "table" and not evidence.type then
                local copy = {}
                for k, v in pairs(evidence) do copy[k] = v end
                copy.type = "deposit"
                evidence = copy
            end
            local ok = V.ValidateObservationPayload(evidence)
            if ok then
                cluster = NewCluster(store, V.SerializeObservation(evidence))
                if decision.action == "correct" or decision.action == "reject" then
                    cluster.status = "rejected"
                end
            end
        end
    end
    if not cluster then
        return false, "missing"
    end

    if action == "reject" then
        -- Do not un-credit a donation already committed to the canonical ledger.
        if cluster.status == "verified" and cluster.txnId and C and C.HasTxnId
            and C.HasTxnId(profile, cluster.txnId) then
            return false, "committed", cluster
        end
        if cluster._committed and cluster.txnId then
            return false, "committed", cluster
        end
        cluster.status = "rejected"
        cluster.verification = nil
        cluster.decidedBy = decidedBy
        cluster.updatedAt = Now()
        if opts.scope then
            V.RecordRejection(opts.scope, cluster.evidence, decidedBy, Now(), decision.reason)
        end
        if opts.recordDurableRejection and type(opts.recordDurableRejection) == "function" then
            opts.recordDurableRejection(cluster.evidence, decidedBy, decision.reason)
        end
        if C and C.RegisterCanonicalTxn and cluster.evidence then
            local rejTxn = V.ValidTxnId(cluster.txnId)
                or (C.AllocateCanonicalTxnId and C.AllocateCanonicalTxnId(profile, decidedBy))
            local entry = V.RegistryEntryFromEvidence(
                cluster.evidence, rejTxn, "rejected", decidedBy, nil, { reason = decision.reason })
            if entry then
                C.RegisterCanonicalTxn(profile, entry)
            end
            cluster.txnId = rejTxn
        end
        if opts.clearPendingWitness and type(opts.clearPendingWitness) == "function" then
            opts.clearPendingWitness(cluster.evidence)
        end
        Debug("Info", "admin rejected cluster=%s donor=%s", tostring(cluster.clusterId), tostring(cluster.evidence and cluster.evidence.donor))
        return true, "rejected", cluster
    end

    -- Prefer a recovered verified ledger/registry identity over a local rejection ID.
    if not HasRecoveredVerifiedIdentity(profile, cluster) then
        AdoptRecoveredTxnId(profile, profileId, cluster)
    end

    -- Incomplete history: do not commit unless identity is recovered verified or
    -- evidence is conservatively clearly-new. A local rejection txnId alone is not enough.
    local historyReady = opts.historyComplete ~= false
    if not historyReady then
        if not HasRecoveredVerifiedIdentity(profile, cluster)
            and not EvidenceClearlyNew(cluster.evidence, opts.historyBaselineAt) then
            Debug("Info", "approve/correct held until history converges cluster=%s",
                tostring(cluster.clusterId))
            return false, "history_incomplete", cluster
        end
    end

    -- Clear rejection only after history/identity validation succeeds.
    if action == "correct" then
        if opts.scope then
            V.ClearMatchingRejection(opts.scope, cluster.evidence)
        end
        if opts.clearDurableRejection and type(opts.clearDurableRejection) == "function" then
            opts.clearDurableRejection(cluster.evidence)
        end
    end

    cluster.status = "verified"
    cluster.verification = V.VERIFICATION.MANUAL
    cluster.decidedBy = decidedBy
    cluster.updatedAt = Now()
    if not V.ValidTxnId(cluster.txnId) then
        cluster.txnId = V.AllocateCanonicalTxn(
            profile, cluster.evidence, decidedBy, V.VERIFICATION.MANUAL)
    elseif C and C.RegisterCanonicalTxn and cluster.evidence then
        -- Correction/approve flips registry status (same ID when correcting a rejection
        -- with no recovered alternate, or the adopted recovered verified ID).
        local entry = V.RegistryEntryFromEvidence(
            cluster.evidence, cluster.txnId, "verified", decidedBy, V.VERIFICATION.MANUAL, {
                committed = C.HasTxnId and C.HasTxnId(profile, cluster.txnId) or false,
            })
        if entry then
            C.RegisterCanonicalTxn(profile, entry)
        end
    end
    if opts.clearPendingWitness and type(opts.clearPendingWitness) == "function" then
        opts.clearPendingWitness(cluster.evidence)
    end
    Debug("Info", "admin approved cluster=%s txn=%s", tostring(cluster.clusterId), tostring(cluster.txnId))
    return true, "verified", cluster
end

local function SummaryRow(cluster, profile)
    local evidence = cluster.evidence or {}
    return {
        clusterId = cluster.clusterId,
        status = cluster.status,
        donor = evidence.donor,
        itemId = evidence.itemId,
        quantity = evidence.quantity,
        approxTxnTime = evidence.approxTxnTime,
        generation = evidence.generation,
        witnessCount = V.CountIndependentWitnesses(cluster.witnesses, profile),
        coreSignature = evidence.coreSignature,
        guildGuid = evidence.guildGuid,
        bankTab = evidence.bankTab,
        occurrenceIndex = evidence.occurrenceIndex,
        neighborsOlder = evidence.neighborsOlder,
        neighborsNewer = evidence.neighborsNewer,
        observedBy = evidence.observedBy,
        firstSeen = evidence.firstSeen,
        type = evidence.type or "deposit",
        txnId = V.ValidTxnId(cluster.txnId),
    }
end

function V.ReviewSummary(profileId, opts)
    opts = opts or {}
    local store = V.EnsureClusterStore(profileId)
    if opts.profile then
        V.HydrateClustersFromDurable(opts.profile, profileId)
    end
    local out = {}
    local limit = tonumber(opts.limit) or V.MAX_REVIEW_SUMMARY
    if limit > V.MAX_REVIEW_SUMMARY then limit = V.MAX_REVIEW_SUMMARY end
    local seenReject = {}
    -- Pending/ambiguous first for approve/reject; rejected rows follow for correction.
    for i = 1, #store.clusters do
        local cluster = store.clusters[i]
        if cluster.status == "pending" or cluster.status == "ambiguous" then
            out[#out + 1] = SummaryRow(cluster, opts.profile)
            if #out >= limit then return out end
        end
    end
    for i = 1, #store.clusters do
        local cluster = store.clusters[i]
        if cluster.status == "rejected" then
            out[#out + 1] = SummaryRow(cluster, opts.profile)
            local key = cluster.evidence and cluster.evidence.coreSignature
            if key then seenReject[key] = true end
            if #out >= limit then return out end
        end
    end
    -- Durable profile rejections survive session reset; surface them for correction.
    if opts.profile and C and C.DurableRejections then
        local durable = C.DurableRejections(opts.profile)
        for i = 1, #durable do
            if #out >= limit then break end
            local rej = durable[i]
            if type(rej) == "table" and type(rej.coreSignature) == "string"
                and not seenReject[rej.coreSignature]
            then
                out[#out + 1] = {
                    clusterId = string.format("rej:%d", i),
                    status = "rejected",
                    donor = rej.donor,
                    itemId = rej.itemId,
                    quantity = rej.quantity,
                    approxTxnTime = rej.approxTxnTime,
                    generation = rej.generation,
                    witnessCount = 0,
                    coreSignature = rej.coreSignature,
                    guildGuid = rej.guildGuid,
                    bankTab = rej.bankTab,
                    occurrenceIndex = rej.occurrenceIndex,
                    neighborsOlder = rej.neighborsOlder,
                    neighborsNewer = rej.neighborsNewer,
                    observedBy = rej.decidedBy,
                    firstSeen = rej.decidedAt,
                    type = "deposit",
                    txnId = V.ValidTxnId(rej.txnId),
                    evidence = rej,
                }
            end
        end
    end
    return out
end

function V.ListVerifiedClusters(profileId)
    local store = V.EnsureClusterStore(profileId)
    local out = {}
    for i = 1, #store.clusters do
        if store.clusters[i].status == "verified" then
            out[#out + 1] = store.clusters[i]
        end
    end
    return out
end

function V.IsEffectiveLocalAdmin(profile)
    local Imp = SF.LootHelperImpersonation
    if Imp and Imp.IsEffectiveLocalAdmin then
        local ok, res = pcall(Imp.IsEffectiveLocalAdmin, Imp, profile)
        if ok then return res and true or false end
    end
    if C and C.IsCanonicalAdmin then
        local selfId = SF.NameUtil and SF.NameUtil.GetSelfId and SF.NameUtil.GetSelfId()
        return C.IsCanonicalAdmin(profile, selfId)
    end
    return false
end

function V.CommitVerifiedCluster(profile, cluster, writer)
    if not C or not C.CommitEvents or type(cluster) ~= "table" or cluster.status ~= "verified" then
        return false, "invalid"
    end
    if type(cluster.txnId) ~= "string" then return false, "invalid" end
    if C.HasTxnId and C.HasTxnId(profile, cluster.txnId) then
        return true, "duplicate"
    end
    writer = Norm(writer or cluster.decidedBy)
    local event = V.BuildDonationEvent(cluster.evidence, writer, cluster.txnId, cluster.verification)
    if not event then return false, "invalid" end
    -- Embed writer in the commit token so RemoteEventIdOk/RelayWriter accept relays.
    local token = string.format("%s:%s", tostring(writer), tostring(cluster.txnId))
    local Sync = SF.LootHelperSync
    local ok, err
    if Sync and Sync.CommitConsumablesEvents then
        ok, err = Sync:CommitConsumablesEvents(profile, token, { event })
    else
        ok, err = C.CommitEvents(profile, token, { event }, { writer = event.writer })
    end
    if ok then
        if C.MarkRegistryCommitted then
            C.MarkRegistryCommitted(profile, cluster.txnId, { bumpSeq = false })
        elseif C.RegisterCanonicalTxn then
            local entry = V.RegistryEntryFromEvidence(
                cluster.evidence, cluster.txnId, "verified", writer, cluster.verification, { committed = true })
            if entry then
                C.RegisterCanonicalTxn(profile, entry, { bumpSeq = false })
            end
        end
        Debug("Info", "committed verified donation txn=%s donor=%s item=%s qty=%s",
            tostring(cluster.txnId), tostring(event.actor), tostring(event.itemId), tostring(event.quantity))
    end
    return ok, err
end

-- Reconsider pending clusters after history becomes ready (peer absorb / grace).
-- Prefers recovered verified identities; may complete admin/witness quorum without
-- minting duplicates. Ambiguous rows stay for manual review.
function V.ReevaluateHeldClusters(profile, profileId, opts)
    opts = opts or {}
    local stats = { verified = 0, pending = 0, adopted = 0, committed = 0 }
    if type(profile) ~= "table" or type(profileId) ~= "string" then return stats end
    if opts.historyComplete == false then return stats end
    local store = V.EnsureClusterStore(profileId)
    local baselineAt = opts.historyBaselineAt
    for i = 1, #store.clusters do
        local cluster = store.clusters[i]
        if type(cluster) == "table"
            and (cluster.status == "pending" or cluster.status == "ambiguous")
        then
            if cluster.status == "ambiguous" then
                stats.pending = stats.pending + 1
            elseif AdoptRecoveredTxnId(profile, profileId, cluster) then
                cluster.status = "verified"
                cluster.verification = cluster.verification or V.VERIFICATION.MANUAL
                -- decidedBy holds recovered provenance; commit writer is chosen below.
                cluster.updatedAt = Now()
                stats.adopted = stats.adopted + 1
                stats.verified = stats.verified + 1
            else
                local witnesses = V.CountIndependentWitnesses(cluster.witnesses, profile)
                local adminReporter = nil
                if type(cluster.witnesses) == "table" and C and C.IsCanonicalAdmin then
                    for name in pairs(cluster.witnesses) do
                        if type(name) == "string" and C.IsCanonicalAdmin(profile, name) then
                            adminReporter = name
                            break
                        end
                    end
                end
                -- After readiness, complete held admin/witness quorums only when
                -- evidence is conservatively post-baseline (or no baseline remains
                -- after peer recovery cleared it). Otherwise keep pending for review.
                local mayMint = EvidenceClearlyNew(cluster.evidence, baselineAt)
                    or baselineAt == nil
                if mayMint and adminReporter then
                    cluster.status = "verified"
                    cluster.verification = V.VERIFICATION.ADMIN_TRUST
                    cluster.decidedBy = adminReporter
                    cluster.txnId = cluster.txnId or V.AllocateCanonicalTxn(
                        profile, cluster.evidence, adminReporter, V.VERIFICATION.ADMIN_TRUST)
                    cluster.updatedAt = Now()
                    stats.verified = stats.verified + 1
                elseif mayMint and witnesses >= V.WITNESS_THRESHOLD then
                    local decidedBy = cluster.decidedBy
                    if type(cluster.witnesses) == "table" then
                        for name in pairs(cluster.witnesses) do
                            decidedBy = name
                        end
                    end
                    decidedBy = Norm(decidedBy) or "local"
                    cluster.status = "verified"
                    cluster.verification = V.VERIFICATION.WITNESSES
                    cluster.decidedBy = decidedBy
                    cluster.txnId = cluster.txnId or V.AllocateCanonicalTxn(
                        profile, cluster.evidence, decidedBy, V.VERIFICATION.WITNESSES)
                    cluster.updatedAt = Now()
                    stats.verified = stats.verified + 1
                else
                    stats.pending = stats.pending + 1
                end
            end
        end
    end
    for i = 1, #store.clusters do
        local cluster = store.clusters[i]
        if cluster and cluster.status == "verified" and not cluster._committed
            and V.ValidTxnId(cluster.txnId) then
            -- Emit under an authorized current writer so event.id is syncable;
            -- cluster.decidedBy retains recovered decision provenance.
            local writer = CommitWriterForCluster(profile, cluster)
            local ok = V.CommitVerifiedCluster(profile, cluster, writer)
            if ok then
                cluster._committed = true
                stats.committed = stats.committed + 1
                if opts.clearPendingWitness and type(opts.clearPendingWitness) == "function"
                    and cluster.evidence then
                    opts.clearPendingWitness(cluster.evidence)
                end
            end
        end
    end
    return stats
end

function V.MarkLocalObservationVerified(obs, txnId, verification)
    if type(obs) ~= "table" then return end
    obs.status = "verified"
    obs.txnId = V.ValidTxnId(txnId) or obs.txnId
    obs.verification = verification
    obs.verifiedAt = Now()
end

function V.ProcessLocalAfterReconcile(profile, profileId, store, scope, opts)
    opts = opts or {}
    if type(profile) ~= "table" or type(scope) ~= "table" or not C then
        return { trusted = 0 }
    end
    V.EnsureScopeExtras(scope)
    local selfId = Norm(opts.selfId) or (SF.NameUtil and SF.NameUtil.GetSelfId and Norm(SF.NameUtil.GetSelfId()))
    local effectiveAdmin = opts.asAdmin
    if effectiveAdmin == nil then
        effectiveAdmin = V.IsEffectiveLocalAdmin(profile)
    end
    -- During an active sync session, verification ownership is the coordinator.
    -- Local admins report observations instead of minting competing txnIds.
    local deferToCoordinator = opts.deferToCoordinator == true
    local durableRejections = C.DurableRejections and C.DurableRejections(profile) or nil
    local historyReady = opts.historyComplete ~= false
    local historyBaselineAt = opts.historyBaselineAt
    local stats = { trusted = 0, suppressed = 0, deferred = 0 }
    for i = 1, #(scope.observations or {}) do
        local obs = scope.observations[i]
        if type(obs) == "table" and (obs.status == "pending" or obs.status == "ambiguous") then
            local durableRejected = durableRejections
                and V.IsRejected({ rejections = durableRejections }, obs)
            local regHow = select(1, V.ReconcileAgainstRegistry(profile, obs))
            if V.IsRejected(scope, obs) or durableRejected or regHow == "rejected" then
                obs.status = "rejected"
                stats.suppressed = stats.suppressed + 1
            elseif obs.status == "ambiguous" or regHow == "ambiguous" then
                -- Ambiguous matches stay pending review; never auto-trust.
                if obs.status ~= "ambiguous" then obs.status = "ambiguous" end
                stats.deferred = stats.deferred + 1
            elseif deferToCoordinator then
                stats.deferred = stats.deferred + 1
            elseif effectiveAdmin and selfId then
                local prior = V.FindEquivalentLedgerDonation(profile, profileId, obs)
                if prior and V.ValidTxnId(prior.txnId) then
                    if prior._registryOnly and not (C.HasTxnId and C.HasTxnId(profile, prior.txnId)) then
                        -- Registry knows the identity but ledger credit is missing: commit once.
                        local cluster = {
                            status = "verified",
                            txnId = prior.txnId,
                            evidence = obs,
                            verification = prior.verification or V.VERIFICATION.ADMIN_TRUST,
                            decidedBy = selfId,
                        }
                        local ok = V.CommitVerifiedCluster(profile, cluster, selfId)
                        if ok then
                            V.MarkLocalObservationVerified(obs, prior.txnId, cluster.verification)
                            scope.verifiedTxnIds[prior.txnId] = true
                            stats.trusted = stats.trusted + 1
                        else
                            stats.deferred = stats.deferred + 1
                        end
                    else
                        V.MarkLocalObservationVerified(obs, prior.txnId, prior.verification or V.VERIFICATION.ADMIN_TRUST)
                        scope.verifiedTxnIds[prior.txnId] = true
                        stats.trusted = stats.trusted + 1
                        Debug("Info", "local admin trust converges on existing txn=%s", tostring(prior.txnId))
                    end
                elseif not historyReady and not EvidenceClearlyNew(obs, historyBaselineAt) then
                    -- Incomplete synchronized history: do not mint potentially overlapping credits.
                    stats.deferred = stats.deferred + 1
                elseif not V.HasStrongIdentityContext(obs) then
                    -- Uncertain empty-window evidence waits for session/admin review.
                    stats.deferred = stats.deferred + 1
                else
                    local txnId = V.ValidTxnId(obs.txnId)
                        or V.AllocateCanonicalTxn(profile, obs, selfId, V.VERIFICATION.ADMIN_TRUST)
                    if not txnId then
                        stats.deferred = stats.deferred + 1
                    else
                        local cluster = {
                            status = "verified",
                            txnId = txnId,
                            evidence = obs,
                            verification = V.VERIFICATION.ADMIN_TRUST,
                            decidedBy = selfId,
                        }
                        local ok, status = V.CommitVerifiedCluster(profile, cluster, selfId)
                        if ok then
                            V.MarkLocalObservationVerified(obs, txnId, V.VERIFICATION.ADMIN_TRUST)
                            scope.verifiedTxnIds[txnId] = true
                            stats.trusted = stats.trusted + 1
                            if status ~= "duplicate" then
                                Debug("Info", "local admin trust committed txn=%s", tostring(txnId))
                            end
                        end
                    end
                end
            end
        end
    end
    return stats
end

function V.ObservationSubmitKey(obs, profileId)
    if type(obs) ~= "table" then return nil end
    if V.ValidTxnId(obs.txnId) then
        return obs.txnId
    end
    if type(obs.localId) == "string" and obs.localId ~= "" then
        return "local:" .. obs.localId
    end
    local donor = Norm(obs.donor) or ""
    return string.format(
        "fp:%s:%s:%s:%s:%s:%s",
        tostring(obs.coreSignature or ""),
        tostring(obs.guildGuid or ""),
        tostring(tonumber(obs.bankTab) or 0),
        tostring(tonumber(obs.generation) or 0),
        donor,
        tostring(tonumber(obs.approxTxnTime) or 0)
    )
end

function V.EnsureSubmittedKeys(store)
    if type(store) ~= "table" then return nil end
    if type(store.submittedKeys) ~= "table" then
        store.submittedKeys = {}
    end
    return store.submittedKeys
end

function V.MarkObservationsSubmitted(store, batch, profileId)
    local keys = V.EnsureSubmittedKeys(store)
    if not keys or type(batch) ~= "table" then return end
    for i = 1, #batch do
        local key = V.ObservationSubmitKey(batch[i], profileId)
        if key then keys[key] = true end
    end
end

function V.RetireSubmittedForEvidence(store, evidence, profileId)
    local keys = V.EnsureSubmittedKeys(store)
    if not keys or type(evidence) ~= "table" then return end
    local key = V.ObservationSubmitKey(evidence, profileId)
    if key then keys[key] = nil end
    if type(evidence.localId) == "string" then
        keys["local:" .. evidence.localId] = nil
    end
end

-- Key-set pagination: never use a positional offset into a shrinking unresolved list.
function V.CollectUnresolvedForSubmit(store, guildGuid, bankTab, opts)
    opts = opts or {}
    if not O or not O.EnsureScope then return {}, false, 0 end
    local scope = O.EnsureScope(store, guildGuid, bankTab)
    if not scope then return {}, false, 0 end
    V.EnsureScopeExtras(scope)
    local submitted = V.EnsureSubmittedKeys(store)
    local profileId = opts.profileId
    local out = {}
    local remaining = 0
    for i = 1, #(scope.observations or {}) do
        local obs = scope.observations[i]
        local status = obs and obs.status or ""
        if status == "pending" or status == "ambiguous" then
            if not V.IsRejected(scope, obs) then
                local wire = V.SerializeObservation(obs)
                if wire then
                    local key = V.ObservationSubmitKey(wire, profileId)
                    if key and submitted[key] then
                        -- Already queued/accepted for this unresolved row.
                    else
                        remaining = remaining + 1
                        if #out < V.MAX_OBS_BATCH then
                            out[#out + 1] = wire
                        end
                    end
                end
            end
        end
    end
    local hasMore = remaining > #out
    return out, hasMore, remaining
end

function V.ApplyRemoteDecisionToLocal(store, guildGuid, bankTab, decision)
    if type(decision) ~= "table" or not O then return false end
    local scope = O.EnsureScope(store, guildGuid, bankTab)
    if not scope then return false end
    V.EnsureScopeExtras(scope)
    local evidence = decision.evidence or decision
    local profileId = decision.profileId
    if decision.action == "reject" then
        V.RecordRejection(scope, evidence, decision.decidedBy, decision.decidedAt or Now(), decision.reason)
        for i = 1, #(scope.observations or {}) do
            local obs = scope.observations[i]
            if obs and (obs.status == "pending" or obs.status == "ambiguous") and V.RejectionMatches(scope.rejections[#scope.rejections], obs) then
                obs.status = "rejected"
                V.RetireSubmittedForEvidence(store, obs, profileId)
            end
        end
        V.RetireSubmittedForEvidence(store, evidence, profileId)
        return true
    end
    if decision.action == "approve" or decision.action == "correct" or decision.action == "verified" then
        if decision.action == "correct" then
            V.ClearMatchingRejection(scope, evidence)
        end
        local txnId = V.ValidTxnId(decision.txnId)
        if txnId then
            scope.verifiedTxnIds[txnId] = true
        end
        local matched = select(1, V.FindMatchingObservation(scope, evidence))
        if matched then
            V.MarkLocalObservationVerified(matched, txnId, decision.verification or V.VERIFICATION.MANUAL)
            V.RetireSubmittedForEvidence(store, matched, profileId)
        end
        V.RetireSubmittedForEvidence(store, evidence, profileId)
        return true
    end
    return false
end
