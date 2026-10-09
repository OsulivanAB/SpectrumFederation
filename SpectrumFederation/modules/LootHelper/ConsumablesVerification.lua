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
V.MAX_REVIEW_SUMMARY = 40
V.MAX_TXN_ID = 160
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
    if not qty or qty < 1 or qty ~= math.floor(qty) then return false, "invalid" end
    if type(obs.coreSignature) ~= "string" or obs.coreSignature == "" then return false, "invalid" end
    return true
end

function V.NextTxnId(store, profileId)
    if type(store) ~= "table" then return nil end
    store.txnSeq = FloorNonNeg(store.txnSeq) + 1
    local pid = tostring(profileId or "profile")
    if #pid > 48 then pid = pid:sub(1, 48) end
    return string.format("ctx:%s:%d", pid, store.txnSeq)
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

function V.RejectionMatches(rejection, evidence)
    if type(rejection) ~= "table" or type(evidence) ~= "table" then return false end
    if O and O.SuppressionMatches and O.SuppressionMatches(rejection, evidence) then
        -- Prefer neighbor continuity when both sides have it.
        local rOlder = rejection.neighborsOlder
        local eOlder = evidence.neighborsOlder
        if type(rOlder) == "table" and #rOlder > 0 and type(eOlder) == "table" and #eOlder > 0 then
            local hit = false
            for i = 1, #rOlder do
                for j = 1, #eOlder do
                    if rOlder[i] == eOlder[j] then hit = true break end
                end
                if hit then break end
            end
            if not hit then return false end
        end
        return true
    end
    return false
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
    return cluster
end

function V.MatchCluster(store, evidence)
    if type(store) ~= "table" or type(evidence) ~= "table" or not O or not O.MatchScore then
        return nil, nil
    end
    local best, bestScore, second = nil, nil, nil
    for i = 1, #store.clusters do
        local cluster = store.clusters[i]
        if cluster.status ~= "rejected" and cluster.status ~= "verified" then
            local score = O.MatchScore(cluster.evidence, evidence)
            if score and score >= (O.MIN_MATCH_SCORE or 100) then
                if not bestScore or score > bestScore then
                    second = bestScore
                    best, bestScore = cluster, score
                elseif not second or score > second then
                    second = score
                end
            end
        end
    end
    if best and second and (bestScore - second) < (O.AMBIGUITY_MARGIN or 15) then
        best.status = "ambiguous"
        return best, "ambiguous"
    end
    return best, best and "match" or nil
end

function V.IngestReport(profile, profileId, submittedBy, observations, opts)
    opts = opts or {}
    submittedBy = Norm(submittedBy)
    if not submittedBy or type(observations) ~= "table" then
        return { accepted = 0, verified = 0, rejected = 0 }
    end
    local store = V.EnsureClusterStore(profileId)
    local stats = { accepted = 0, verified = 0, rejected = 0, pending = 0 }
    local isAdmin = opts.isAdmin == true
    local limit = #observations
    if limit > V.MAX_OBS_BATCH then limit = V.MAX_OBS_BATCH end

    for i = 1, limit do
        local raw = observations[i]
        local ok = V.ValidateObservationPayload(raw)
        if ok then
            local evidence = V.SerializeObservation(raw)
            if evidence then
                -- Authenticated sender is the witness; never trust client isAdmin.
                evidence.submittedBy = submittedBy
                local rejected = false
                if opts.scope and V.IsRejected(opts.scope, evidence) then
                    rejected = true
                    stats.rejected = stats.rejected + 1
                    Debug("Info", "report suppressed by prior rejection donor=%s item=%s",
                        tostring(evidence.donor), tostring(evidence.itemId))
                end
                if not rejected then
                    local cluster, how = V.MatchCluster(store, evidence)
                    if not cluster then
                        cluster = NewCluster(store, evidence)
                    else
                        -- Refresh evidence with newer observation context.
                        cluster.evidence = evidence
                        if how == "ambiguous" then
                            cluster.status = "ambiguous"
                        end
                    end
                    if not V.WitnessAlreadyCounted(cluster.witnesses, submittedBy, profile) then
                        local count = 0
                        for _ in pairs(cluster.witnesses) do count = count + 1 end
                        if count < V.MAX_WITNESSES_PER_CLUSTER then
                            cluster.witnesses[submittedBy] = {
                                submittedBy = submittedBy,
                                observedBy = evidence.observedBy,
                                firstReported = Now(),
                            }
                        end
                    end
                    cluster.updatedAt = Now()
                    stats.accepted = stats.accepted + 1

                    if cluster.status ~= "verified" and cluster.status ~= "rejected" then
                        if isAdmin then
                            cluster.status = "verified"
                            cluster.verification = V.VERIFICATION.ADMIN_TRUST
                            cluster.decidedBy = submittedBy
                            if not cluster.txnId then
                                cluster.txnId = V.NextTxnId(opts.obsStore or store, profileId)
                            end
                            stats.verified = stats.verified + 1
                            Debug("Info", "admin-trusted verification txn=%s donor=%s",
                                tostring(cluster.txnId), tostring(evidence.donor))
                        elseif cluster.status ~= "ambiguous" then
                            local witnesses = V.CountIndependentWitnesses(cluster.witnesses, profile)
                            if witnesses >= V.WITNESS_THRESHOLD then
                                cluster.status = "verified"
                                cluster.verification = V.VERIFICATION.WITNESSES
                                cluster.decidedBy = submittedBy
                                if not cluster.txnId then
                                    cluster.txnId = V.NextTxnId(opts.obsStore or store, profileId)
                                end
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
        -- Authoritative rejection wins races with automatic verification.
        cluster.status = "rejected"
        cluster.verification = nil
        cluster.decidedBy = decidedBy
        cluster.updatedAt = Now()
        if opts.scope then
            V.RecordRejection(opts.scope, cluster.evidence, decidedBy, Now(), decision.reason)
        end
        Debug("Info", "admin rejected cluster=%s donor=%s", tostring(cluster.clusterId), tostring(cluster.evidence and cluster.evidence.donor))
        return true, "rejected", cluster
    end

    if action == "correct" then
        if opts.scope then
            V.ClearMatchingRejection(opts.scope, cluster.evidence)
        end
        -- Fall through to approve after clearing rejection.
    end

    cluster.status = "verified"
    cluster.verification = V.VERIFICATION.MANUAL
    cluster.decidedBy = decidedBy
    cluster.updatedAt = Now()
    if not cluster.txnId then
        cluster.txnId = V.NextTxnId(opts.obsStore or store, profileId)
    end
    Debug("Info", "admin approved cluster=%s txn=%s", tostring(cluster.clusterId), tostring(cluster.txnId))
    return true, "verified", cluster
end

function V.ReviewSummary(profileId, opts)
    opts = opts or {}
    local store = V.EnsureClusterStore(profileId)
    local out = {}
    local limit = tonumber(opts.limit) or V.MAX_REVIEW_SUMMARY
    if limit > V.MAX_REVIEW_SUMMARY then limit = V.MAX_REVIEW_SUMMARY end
    for i = 1, #store.clusters do
        local cluster = store.clusters[i]
        if cluster.status == "pending" or cluster.status == "ambiguous" then
            local evidence = cluster.evidence or {}
            out[#out + 1] = {
                clusterId = cluster.clusterId,
                status = cluster.status,
                donor = evidence.donor,
                itemId = evidence.itemId,
                quantity = evidence.quantity,
                approxTxnTime = evidence.approxTxnTime,
                generation = evidence.generation,
                witnessCount = V.CountIndependentWitnesses(cluster.witnesses, opts.profile),
                coreSignature = evidence.coreSignature,
                guildGuid = evidence.guildGuid,
                bankTab = evidence.bankTab,
                occurrenceIndex = evidence.occurrenceIndex,
                neighborsOlder = evidence.neighborsOlder,
                neighborsNewer = evidence.neighborsNewer,
                observedBy = evidence.observedBy,
                firstSeen = evidence.firstSeen,
                type = evidence.type or "deposit",
            }
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
    local stats = { trusted = 0, suppressed = 0 }
    for i = 1, #(scope.observations or {}) do
        local obs = scope.observations[i]
        if type(obs) == "table" and (obs.status == "pending" or obs.status == "ambiguous") then
            if V.IsRejected(scope, obs) then
                obs.status = "rejected"
                stats.suppressed = stats.suppressed + 1
            elseif effectiveAdmin and selfId then
                -- Admin trust is based on the authenticated local admin character,
                -- not an unverified historical observedBy flag.
                local txnId = obs.txnId or V.NextTxnId(store, profileId)
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
    return stats
end

function V.CollectUnresolvedForSubmit(store, guildGuid, bankTab, opts)
    opts = opts or {}
    if not O or not O.EnsureScope then return {} end
    local scope = O.EnsureScope(store, guildGuid, bankTab)
    if not scope then return {} end
    V.EnsureScopeExtras(scope)
    local out = {}
    for i = 1, #(scope.observations or {}) do
        local obs = scope.observations[i]
        local status = obs and obs.status or ""
        if status == "pending" or status == "ambiguous" then
            if not V.IsRejected(scope, obs) then
                local wire = V.SerializeObservation(obs)
                if wire then
                    out[#out + 1] = wire
                    if #out >= V.MAX_OBS_BATCH then break end
                end
            end
        end
    end
    return out
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
