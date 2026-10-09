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

-- Evidence-stable transaction identity shared across observers/stores.
-- Uses only fields every observer reconstructs identically for the same bank row:
-- core signature, guild/tab/generation, and occurrence index. Reconstructed
-- approxTxnTime and neighbor windows vary by observer and must not participate.
function V.TxnIdFromEvidence(profileId, evidence)
    if type(evidence) ~= "table" then return nil end
    local pid = tostring(profileId or "profile")
    if #pid > 40 then pid = pid:sub(1, 40) end
    local donor = Norm(evidence.donor) or ""
    local hash = 0
    hash = MixText(hash, evidence.coreSignature or "")
    hash = MixText(hash, evidence.guildGuid or "")
    hash = MixText(hash, tostring(tonumber(evidence.bankTab) or 0))
    hash = MixText(hash, tostring(tonumber(evidence.generation) or 0))
    hash = MixText(hash, donor)
    hash = MixText(hash, tostring(tonumber(evidence.itemId) or 0))
    hash = MixText(hash, tostring(FloorNonNeg(evidence.quantity)))
    -- Occurrence distinguishes two identical deposits; same bank row shares it.
    hash = MixText(hash, tostring(tonumber(evidence.occurrenceIndex) or 0))
    local txnId = string.format("ctx:%s:%x", pid, hash)
    return V.ValidTxnId(txnId)
end

function V.NextTxnId(store, profileId, evidence)
    if type(evidence) == "table" then
        local derived = V.TxnIdFromEvidence(profileId, evidence)
        if derived then return derived end
    end
    if type(store) ~= "table" then return nil end
    store.txnSeq = FloorNonNeg(store.txnSeq) + 1
    local pid = tostring(profileId or "profile")
    if #pid > 40 then pid = pid:sub(1, 40) end
    local writer = ""
    if SF.NameUtil and SF.NameUtil.GetSelfId then
        writer = Norm(SF.NameUtil.GetSelfId()) or ""
    end
    if #writer > 32 then writer = writer:sub(1, 32) end
    -- Writer-namespaced fallback prevents cross-client sequence collisions.
    return string.format("ctx:%s:%s:%d", pid, writer ~= "" and writer or "local", store.txnSeq)
end

-- Strict ledger identity only. Donor/item/qty + time proximity alone is never enough
-- (two legitimate identical deposits within 3h must both credit).
function V.FindEquivalentLedgerDonation(profile, profileId, evidence)
    if not C or type(profile) ~= "table" or type(evidence) ~= "table" then
        return nil
    end
    local expectedTxn = V.TxnIdFromEvidence(profileId, evidence)
    local core = type(evidence.coreSignature) == "string" and evidence.coreSignature or nil
    local occ = tonumber(evidence.occurrenceIndex)
    if not expectedTxn and not (core and occ) then
        return nil
    end
    local lists = { profile._consumableEvents, profile._consumableEventArchive }
    for li = 1, #lists do
        local list = lists[li]
        if type(list) == "table" then
            for i = 1, #list do
                local event = list[i]
                if type(event) == "table"
                    and event.type == (C.EVENT and C.EVENT.DONATION or "CONSUMABLE_DONATION")
                    and event.source == "guildbank"
                then
                    if expectedTxn and V.ValidTxnId(event.txnId) == expectedTxn then
                        return event
                    end
                    if core and occ
                        and event.coreSignature == core
                        and tonumber(event.occurrenceIndex) == occ
                    then
                        return event
                    end
                end
            end
        end
    end
    return nil
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
        -- Reserved for a future monetary feature; leave unset (nil), never 0.
        goldValueCopper = V.ValidGoldValueCopper(opts.goldValueCopper),
    }
    return event
end

function V.RejectionRecord(evidence, decidedBy, now, reason)
    return {
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

function V.IngestReport(profile, profileId, submittedBy, observations, opts)
    opts = opts or {}
    submittedBy = Norm(submittedBy)
    if not submittedBy or type(observations) ~= "table" then
        return { accepted = 0, verified = 0, rejected = 0 }
    end
    local store = V.EnsureClusterStore(profileId)
    local stats = { accepted = 0, verified = 0, rejected = 0, pending = 0, skipped = 0 }
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
                    if rejected then
                        stats.rejected = stats.rejected + 1
                        Debug("Info", "report suppressed by prior rejection donor=%s item=%s",
                            tostring(evidence.donor), tostring(evidence.itemId))
                    else
                        local cluster, how = V.MatchCluster(store, evidence)
                        if how ~= "verified" then
                            local ledgerHit = V.FindEquivalentLedgerDonation(profile, profileId, evidence)
                            if not cluster and ledgerHit and V.ValidTxnId(ledgerHit.txnId) then
                                -- Strict identity hit only: never absorb a distinct deposit.
                                cluster = NewCluster(store, evidence)
                                cluster.status = "verified"
                                cluster.verification = ledgerHit.verification or V.VERIFICATION.MANUAL
                                cluster.txnId = ledgerHit.txnId
                                cluster._committed = true
                                cluster.decidedBy = Norm(ledgerHit.writer) or submittedBy
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

                        AddWitness(cluster, submittedBy, evidence, profile)
                        cluster.updatedAt = Now()
                        stats.accepted = stats.accepted + 1

                        if how == "verified" or cluster.status == "verified" or cluster.status == "rejected" then
                            -- Already terminal: rematch only records the witness.
                        elseif isAdmin and cluster.status ~= "ambiguous" then
                            -- Ambiguous rows require manual review; never auto-trust them.
                            cluster.status = "verified"
                            cluster.verification = V.VERIFICATION.ADMIN_TRUST
                            cluster.decidedBy = submittedBy
                            cluster.txnId = cluster.txnId
                                or V.NextTxnId(opts.obsStore or store, profileId, evidence)
                            stats.verified = stats.verified + 1
                            Debug("Info", "admin-trusted verification txn=%s donor=%s",
                                tostring(cluster.txnId), tostring(evidence.donor))
                        elseif cluster.status ~= "ambiguous" then
                            local witnesses = V.CountIndependentWitnesses(cluster.witnesses, profile)
                            if witnesses >= V.WITNESS_THRESHOLD then
                                cluster.status = "verified"
                                cluster.verification = V.VERIFICATION.WITNESSES
                                cluster.decidedBy = submittedBy
                                cluster.txnId = cluster.txnId
                                    or V.NextTxnId(opts.obsStore or store, profileId, evidence)
                                stats.verified = stats.verified + 1
                                Debug("Info", "three-witness verification txn=%s witnesses=%s",
                                    tostring(cluster.txnId), tostring(witnesses))
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
            local ok = V.ValidateObservationPayload(decision.evidence)
            if ok then
                cluster = NewCluster(store, V.SerializeObservation(decision.evidence))
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
        Debug("Info", "admin rejected cluster=%s donor=%s", tostring(cluster.clusterId), tostring(cluster.evidence and cluster.evidence.donor))
        return true, "rejected", cluster
    end

    if action == "correct" then
        if opts.scope then
            V.ClearMatchingRejection(opts.scope, cluster.evidence)
        end
        if opts.clearDurableRejection and type(opts.clearDurableRejection) == "function" then
            opts.clearDurableRejection(cluster.evidence)
        end
        -- Fall through to approve after clearing rejection.
    end

    cluster.status = "verified"
    cluster.verification = V.VERIFICATION.MANUAL
    cluster.decidedBy = decidedBy
    cluster.updatedAt = Now()
    cluster.txnId = cluster.txnId
        or V.NextTxnId(opts.obsStore or store, profileId, cluster.evidence)
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
    local out = {}
    local limit = tonumber(opts.limit) or V.MAX_REVIEW_SUMMARY
    if limit > V.MAX_REVIEW_SUMMARY then limit = V.MAX_REVIEW_SUMMARY end
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
            if #out >= limit then break end
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
        Debug("Info", "committed verified donation txn=%s donor=%s item=%s qty=%s",
            tostring(cluster.txnId), tostring(event.actor), tostring(event.itemId), tostring(event.quantity))
    end
    return ok, err
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
    local stats = { trusted = 0, suppressed = 0, deferred = 0 }
    for i = 1, #(scope.observations or {}) do
        local obs = scope.observations[i]
        if type(obs) == "table" and (obs.status == "pending" or obs.status == "ambiguous") then
            if V.IsRejected(scope, obs) then
                obs.status = "rejected"
                stats.suppressed = stats.suppressed + 1
            elseif obs.status == "ambiguous" then
                -- Ambiguous matches stay pending review; never auto-trust.
                stats.deferred = stats.deferred + 1
            elseif deferToCoordinator then
                stats.deferred = stats.deferred + 1
            elseif effectiveAdmin and selfId then
                -- Offline/local admin trust: authenticated local admin character only.
                local txnId = obs.txnId or V.NextTxnId(store, profileId, obs)
                local prior = V.FindEquivalentLedgerDonation(profile, profileId, obs)
                if prior and V.ValidTxnId(prior.txnId) then
                    -- Another offline admin already credited this bank row.
                    V.MarkLocalObservationVerified(obs, prior.txnId, prior.verification or V.VERIFICATION.ADMIN_TRUST)
                    scope.verifiedTxnIds[prior.txnId] = true
                    stats.trusted = stats.trusted + 1
                    Debug("Info", "local admin trust converges on existing txn=%s", tostring(prior.txnId))
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
    return stats
end

function V.CollectUnresolvedForSubmit(store, guildGuid, bankTab, opts)
    opts = opts or {}
    if not O or not O.EnsureScope then return {}, 0, 0 end
    local scope = O.EnsureScope(store, guildGuid, bankTab)
    if not scope then return {}, 0, 0 end
    V.EnsureScopeExtras(scope)
    local offset = FloorNonNeg(opts.offset)
    local candidates = {}
    for i = 1, #(scope.observations or {}) do
        local obs = scope.observations[i]
        local status = obs and obs.status or ""
        if status == "pending" or status == "ambiguous" then
            if not V.IsRejected(scope, obs) then
                local wire = V.SerializeObservation(obs)
                if wire then
                    candidates[#candidates + 1] = wire
                end
            end
        end
    end
    local total = #candidates
    local out = {}
    for i = offset + 1, total do
        out[#out + 1] = candidates[i]
        if #out >= V.MAX_OBS_BATCH then
            break
        end
    end
    local nextOffset = offset + #out
    if nextOffset >= total then
        nextOffset = 0
    end
    return out, nextOffset, total
end

function V.ApplyRemoteDecisionToLocal(store, guildGuid, bankTab, decision)
    if type(decision) ~= "table" or not O then return false end
    local scope = O.EnsureScope(store, guildGuid, bankTab)
    if not scope then return false end
    V.EnsureScopeExtras(scope)
    local evidence = decision.evidence or decision
    if decision.action == "reject" then
        V.RecordRejection(scope, evidence, decision.decidedBy, decision.decidedAt or Now(), decision.reason)
        for i = 1, #(scope.observations or {}) do
            local obs = scope.observations[i]
            if obs and (obs.status == "pending" or obs.status == "ambiguous") and V.RejectionMatches(scope.rejections[#scope.rejections], obs) then
                obs.status = "rejected"
            end
        end
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
        end
        return true
    end
    return false
end
