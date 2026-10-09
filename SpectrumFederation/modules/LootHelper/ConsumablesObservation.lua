-- Pure Guild Bank transaction observation evidence and local reconciliation.
-- Ledger writes and sync live in ConsumablesVerification / ConsumablesSync (PR2).
local _, SF = ...

SF.ConsumablesObservation = SF.ConsumablesObservation or {}
local O = SF.ConsumablesObservation

O.SCHEMA_VERSION = 1
O.PENDING_TTL_SECONDS = 14 * 24 * 60 * 60
O.MAX_OBSERVATIONS_PER_SCOPE = 256
O.MAX_SUPPRESSIONS_PER_SCOPE = 128
O.MAX_NEIGHBORS = 3
O.TIME_TOLERANCE_SECONDS = 3 * 60 * 60
-- Empty-context rematches (no neighbor overlap): short wall-clock gaps can rematch
-- immediately. Longer gaps require Blizzard relative-age fields to advance
-- consistently with elapsed time so an unchanged still-visible row can reopen
-- after 30–60 minutes without treating a later disjoint identical deposit as the
-- same transaction.
O.EMPTY_CONTEXT_CONTINUITY_SECONDS = 15 * 60
O.AGE_WALL_SLACK_HOURS = 1.05
O.MIN_MATCH_SCORE = 100
O.AMBIGUITY_MARGIN = 15
-- Statuses that never expire under the 14-day pending rule.
O.NON_EXPIRING_STATUS = {
    verified = true,
    rejected = true,
    trusted = true,
}

local function Debug(level, message, ...)
    if SF.Debug and SF.Debug[level] then
        SF.Debug[level](SF.Debug, "CONSUMABLES_OBS", message, ...)
    end
end

local function Now()
    if type(O._clock) == "function" then
        return O._clock()
    end
    return time()
end

O.Now = Now

local function Norm(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(name) or name
    end
    return name
end

local function FloorNonNeg(n)
    n = tonumber(n) or 0
    if n < 0 then return 0 end
    return math.floor(n)
end

local function IsItemId(itemId)
    return type(itemId) == "number" and itemId > 0 and itemId == math.floor(itemId)
end

local function IsBankTab(tab)
    return type(tab) == "number" and tab >= 1 and tab <= 8 and tab == math.floor(tab)
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

local function NeighborOverlap(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a == 0 or #b == 0 then
        return 0
    end
    local seen = {}
    for i = 1, #b do
        seen[b[i]] = (seen[b[i]] or 0) + 1
    end
    local hits = 0
    for i = 1, #a do
        local key = a[i]
        local left = seen[key]
        if left and left > 0 then
            hits = hits + 1
            seen[key] = left - 1
        end
    end
    return hits
end

function O.CoreSignature(txnType, donor, itemId, quantity)
    donor = Norm(donor)
    itemId = tonumber(itemId)
    quantity = FloorNonNeg(quantity)
    txnType = type(txnType) == "string" and txnType or ""
    if not donor or not IsItemId(itemId) or quantity <= 0 or txnType == "" then
        return nil
    end
    return table.concat({ txnType, donor, tostring(itemId), tostring(quantity) }, "|")
end

function O.RelativeAgeHours(year, month, day, hour)
    return FloorNonNeg(year) * 8760
        + FloorNonNeg(month) * 720
        + FloorNonNeg(day) * 24
        + FloorNonNeg(hour)
end

function O.ApproxTxnTime(observedAt, ageHours)
    observedAt = tonumber(observedAt) or 0
    ageHours = tonumber(ageHours) or 0
    return observedAt - (ageHours * 3600)
end

function O.RowSignature(txnType, name, itemId, quantity)
    return O.CoreSignature(txnType, name, itemId, quantity)
end

function O.ItemIdFromLink(link)
    local C = SF.Consumables
    if C and C.ItemIdFromText then
        return C.ItemIdFromText(link)
    end
    if type(link) == "number" then
        return IsItemId(link) and link or nil
    end
    if type(link) ~= "string" then return nil end
    local id = tonumber(link:match("item:(%d+)"))
    if not IsItemId(id) then return nil end
    return id
end

function O.IsEligibleDeposit(row, requestedSet)
    if type(row) ~= "table" then return false end
    if row.type ~= "deposit" then return false end
    local qty = FloorNonNeg(row.count or row.quantity)
    if qty <= 0 then return false end
    local itemId = tonumber(row.itemId) or O.ItemIdFromLink(row.itemLink)
    if not IsItemId(itemId) then return false end
    if type(requestedSet) == "table" then
        if not requestedSet[tostring(itemId)] and not requestedSet[itemId] then
            return false
        end
    end
    if not Norm(row.name or row.donor) then return false end
    return true
end

function O.BuildEvidence(row, ctx)
    if type(row) ~= "table" or type(ctx) ~= "table" then return nil end
    local donor = Norm(row.name or row.donor)
    local itemId = tonumber(row.itemId) or O.ItemIdFromLink(row.itemLink)
    local quantity = FloorNonNeg(row.count or row.quantity)
    local txnType = row.type
    local core = O.CoreSignature(txnType, donor, itemId, quantity)
    if not core then return nil end
    local observedAt = tonumber(ctx.observedAt) or Now()
    local ageHours = O.RelativeAgeHours(row.year, row.month, row.day, row.hour)
    if row.ageHours ~= nil then
        ageHours = FloorNonNeg(row.ageHours)
    end
    return {
        coreSignature = core,
        type = txnType,
        donor = donor,
        itemId = itemId,
        quantity = quantity,
        guildGuid = tostring(ctx.guildGuid or ""),
        bankTab = tonumber(ctx.bankTab),
        generation = tonumber(ctx.generation) or 0,
        observedBy = Norm(ctx.observedBy),
        observedAt = observedAt,
        ageHours = ageHours,
        approxTxnTime = O.ApproxTxnTime(observedAt, ageHours),
        rowIndex = tonumber(row.index or row.rowIndex),
        snapshotCount = tonumber(ctx.snapshotCount) or 0,
        occurrenceIndex = tonumber(ctx.occurrenceIndex) or 1,
        neighborsOlder = CopyStringList(ctx.neighborsOlder or row.neighborsOlder, O.MAX_NEIGHBORS),
        neighborsNewer = CopyStringList(ctx.neighborsNewer or row.neighborsNewer, O.MAX_NEIGHBORS),
    }
end

local function EmptyContextContinuity(existing, evidence)
    -- Fast path: recent rescans while Blizzard's hour bucket has not moved.
    local tExisting = tonumber(existing.approxTxnTime)
    local tEvidence = tonumber(evidence.approxTxnTime)
    if tExisting and tEvidence and math.abs(tExisting - tEvidence) <= O.EMPTY_CONTEXT_CONTINUITY_SECONDS then
        return true
    end

    -- Longer gaps: require relative-age advancement to track elapsed wall time.
    -- Same still-visible row: ageHours rises with wall time (hour granularity).
    -- Distinct later deposit often reappears as ageHours == 0 after a long gap.
    local lastSeen = tonumber(existing.lastSeen) or tonumber(existing.firstSeen)
    local observedAt = tonumber(evidence.observedAt) or lastSeen
    if not lastSeen or not observedAt or observedAt < lastSeen then
        return false
    end
    local wallHours = (observedAt - lastSeen) / 3600
    local agePrev = FloorNonNeg(existing.ageHours)
    local ageNow = FloorNonNeg(evidence.ageHours)
    local ageDelta = ageNow - agePrev
    if ageDelta < 0 then
        return false
    end
    if ageDelta == 0 then
        -- Age bucket unchanged: only trust short gaps (same hour bucket).
        return wallHours < 1.0
    end
    return math.abs(ageDelta - wallHours) <= O.AGE_WALL_SLACK_HOURS
end

function O.MatchScore(existing, evidence)
    if type(existing) ~= "table" or type(evidence) ~= "table" then return nil end
    if existing.coreSignature ~= evidence.coreSignature then return nil end
    if tostring(existing.guildGuid or "") ~= tostring(evidence.guildGuid or "") then return nil end
    if tonumber(existing.bankTab) ~= tonumber(evidence.bankTab) then return nil end
    if tonumber(existing.generation) ~= tonumber(evidence.generation) then return nil end
    local status = existing.status or "pending"
    if status == "expired" or status == "rejected" then return nil end

    local tExisting = tonumber(existing.approxTxnTime)
    local tEvidence = tonumber(evidence.approxTxnTime)
    if not tExisting or not tEvidence then return nil end
    local drift = math.abs(tExisting - tEvidence)
    if drift > O.TIME_TOLERANCE_SECONDS then return nil end

    local olderHits = NeighborOverlap(existing.neighborsOlder, evidence.neighborsOlder)
    local newerHits = NeighborOverlap(existing.neighborsNewer, evidence.neighborsNewer)
    local neighborHits = olderHits + newerHits
    local sameOccurrence = tonumber(existing.occurrenceIndex) == tonumber(evidence.occurrenceIndex)

    -- Neighbor overlap is preferred continuity evidence. Empty-context rematch
    -- needs short reconstructed-time continuity or age-vs-wall consistency so
    -- reopen of an unchanged lone row works across 30–60 minutes without merging
    -- a later disjoint identical deposit.
    if neighborHits < 1 then
        if not sameOccurrence then return nil end
        if not EmptyContextContinuity(existing, evidence) then return nil end
    end

    local score = O.MIN_MATCH_SCORE
    -- Closer reconstructed times score higher (max +30).
    score = score + math.floor(30 * (1 - (drift / O.TIME_TOLERANCE_SECONDS)))
    if sameOccurrence then
        score = score + 20
    end
    score = score + (olderHits * 10) + (newerHits * 10)
    return score
end

local function ScopeKey(guildGuid, bankTab)
    return tostring(guildGuid or "") .. "|" .. tostring(bankTab or "")
end

function O.EnsureRoot(db)
    if type(db) ~= "table" then return nil end
    if type(db.consumableObservations) ~= "table" then
        db.consumableObservations = {}
    end
    return db.consumableObservations
end

function O.EnsureProfileStore(db, profileId)
    if type(profileId) ~= "string" or profileId == "" then return nil end
    local root = O.EnsureRoot(db)
    if not root then return nil end
    local store = root[profileId]
    if type(store) ~= "table" then
        store = {
            schemaVersion = O.SCHEMA_VERSION,
            seq = 0,
            scopes = {},
        }
        root[profileId] = store
    end
    if type(store.scopes) ~= "table" then store.scopes = {} end
    if type(store.seq) ~= "number" then store.seq = 0 end
    store.schemaVersion = O.SCHEMA_VERSION
    return store
end

function O.EnsureScope(store, guildGuid, bankTab)
    if type(store) ~= "table" then return nil end
    if type(guildGuid) ~= "string" or guildGuid == "" or not IsBankTab(tonumber(bankTab)) then
        return nil
    end
    local key = ScopeKey(guildGuid, bankTab)
    local scope = store.scopes[key]
    if type(scope) ~= "table" then
        scope = {
            guildGuid = guildGuid,
            bankTab = tonumber(bankTab),
            observations = {},
            suppressions = {},
            rejections = {},
            verifiedTxnIds = {},
            backfillCompleted = false,
        }
        store.scopes[key] = scope
    end
    if type(scope.observations) ~= "table" then scope.observations = {} end
    if type(scope.suppressions) ~= "table" then scope.suppressions = {} end
    if type(scope.rejections) ~= "table" then scope.rejections = {} end
    if type(scope.verifiedTxnIds) ~= "table" then scope.verifiedTxnIds = {} end
    return scope, key
end

-- Eligibility cutover: ignore transactions that predate an item/tab becoming eligible.
function O.IsEvidenceEligible(evidence, eligibility)
    if type(evidence) ~= "table" then return false end
    if type(eligibility) ~= "table" then return true end
    local txnTime = tonumber(evidence.approxTxnTime) or tonumber(evidence.observedAt)
    if not txnTime then
        -- Fail closed for unclear boundaries after a cutover exists.
        if eligibility.tabEligibleFrom or (eligibility.items and next(eligibility.items)) then
            return false
        end
        return true
    end
    local tabFrom = tonumber(eligibility.tabEligibleFrom)
    if tabFrom and txnTime < tabFrom then
        return false
    end
    local itemId = tonumber(evidence.itemId)
    if itemId and type(eligibility.items) == "table" then
        local itemFrom = tonumber(eligibility.items[tostring(itemId)] or eligibility.items[itemId])
        if itemFrom and txnTime < itemFrom then
            return false
        end
    end
    return true
end

local function NextLocalId(store, profileId)
    store.seq = FloorNonNeg(store.seq) + 1
    return string.format("co:%s:%d", tostring(profileId), store.seq)
end

local function CopyEvidenceFields(target, evidence)
    target.coreSignature = evidence.coreSignature
    target.type = evidence.type
    target.donor = evidence.donor
    target.itemId = evidence.itemId
    target.quantity = evidence.quantity
    target.guildGuid = evidence.guildGuid
    target.bankTab = evidence.bankTab
    target.generation = evidence.generation
    target.ageHours = evidence.ageHours
    target.approxTxnTime = evidence.approxTxnTime
    target.rowIndex = evidence.rowIndex
    target.snapshotCount = evidence.snapshotCount
    target.occurrenceIndex = evidence.occurrenceIndex
    target.neighborsOlder = CopyStringList(evidence.neighborsOlder, O.MAX_NEIGHBORS)
    target.neighborsNewer = CopyStringList(evidence.neighborsNewer, O.MAX_NEIGHBORS)
    if evidence.observedBy and not target.observedBy then
        target.observedBy = evidence.observedBy
    end
end

function O.SuppressionMatches(suppression, evidence)
    if type(suppression) ~= "table" or type(evidence) ~= "table" then return false end
    if suppression.coreSignature ~= evidence.coreSignature then return false end
    local tSup = tonumber(suppression.approxTxnTime)
    local tEv = tonumber(evidence.approxTxnTime)
    if not tSup or not tEv then return false end
    return math.abs(tSup - tEv) <= O.TIME_TOLERANCE_SECONDS
end

function O.PruneScope(scope, now)
    if type(scope) ~= "table" then return 0 end
    now = tonumber(now) or Now()
    local kept = {}
    local removed = 0
    local observations = scope.observations or {}
    for i = 1, #observations do
        local obs = observations[i]
        if type(obs) == "table" then
            local status = obs.status or "pending"
            local firstSeen = tonumber(obs.firstSeen) or now
            local expired = false
            -- Admin-retained and verified/rejected observations do not expire.
            if (status == "pending" or status == "ambiguous")
                and not obs.retainBeyondExpiry
                and not O.NON_EXPIRING_STATUS[status]
            then
                if (now - firstSeen) >= O.PENDING_TTL_SECONDS then
                    expired = true
                end
            end
            if expired then
                removed = removed + 1
                local suppressions = scope.suppressions
                suppressions[#suppressions + 1] = {
                    coreSignature = obs.coreSignature,
                    approxTxnTime = obs.approxTxnTime,
                    firstSeen = firstSeen,
                    reason = "expired",
                    expiredAt = now,
                }
                Debug("Info", "expired observation %s donor=%s item=%s qty=%s",
                    tostring(obs.localId), tostring(obs.donor), tostring(obs.itemId), tostring(obs.quantity))
            else
                kept[#kept + 1] = obs
            end
        end
    end
    scope.observations = kept

    -- Bound suppressions (oldest first).
    local suppressions = scope.suppressions or {}
    if #suppressions > O.MAX_SUPPRESSIONS_PER_SCOPE then
        local trimmed = {}
        local start = #suppressions - O.MAX_SUPPRESSIONS_PER_SCOPE + 1
        for i = start, #suppressions do
            trimmed[#trimmed + 1] = suppressions[i]
        end
        scope.suppressions = trimmed
    end

    -- Bound observations (prefer newest lastSeen).
    if #scope.observations > O.MAX_OBSERVATIONS_PER_SCOPE then
        table.sort(scope.observations, function(a, b)
            return (tonumber(a.lastSeen) or 0) < (tonumber(b.lastSeen) or 0)
        end)
        local overflow = #scope.observations - O.MAX_OBSERVATIONS_PER_SCOPE
        for _ = 1, overflow do
            table.remove(scope.observations, 1)
            removed = removed + 1
        end
    end
    return removed
end

local function IsSuppressed(scope, evidence)
    local suppressions = scope.suppressions or {}
    for i = 1, #suppressions do
        if O.SuppressionMatches(suppressions[i], evidence) then
            return true
        end
    end
    return false
end

local function EnrichSnapshotRows(rawRows, requestedSet, ctx)
    local rows = {}
    if type(rawRows) ~= "table" then return rows end
    for i = 1, #rawRows do
        local raw = rawRows[i]
        if type(raw) == "table" then
            local copy = {
                type = raw.type,
                name = raw.name,
                itemLink = raw.itemLink,
                itemId = raw.itemId or O.ItemIdFromLink(raw.itemLink),
                count = raw.count or raw.quantity,
                year = raw.year,
                month = raw.month,
                day = raw.day,
                hour = raw.hour,
                ageHours = raw.ageHours,
                index = raw.index or i,
            }
            rows[#rows + 1] = copy
        end
    end

    -- Neighbor signatures use all parsed rows (including ineligible) for context.
    local allSigs = {}
    for i = 1, #rows do
        local r = rows[i]
        allSigs[i] = O.RowSignature(r.type, r.name, r.itemId or O.ItemIdFromLink(r.itemLink), r.count) or ""
    end

    local eligible = {}
    local occByCore = {}
    for i = 1, #rows do
        local r = rows[i]
        if O.IsEligibleDeposit(r, requestedSet) then
            local older = {}
            local newer = {}
            for k = 1, O.MAX_NEIGHBORS do
                local oi = i - k
                if oi >= 1 and allSigs[oi] ~= "" then
                    older[#older + 1] = allSigs[oi]
                end
                local ni = i + k
                if ni <= #rows and allSigs[ni] ~= "" then
                    newer[#newer + 1] = allSigs[ni]
                end
            end
            local core = O.CoreSignature(r.type, r.name, r.itemId, r.count)
            occByCore[core] = (occByCore[core] or 0) + 1
            local evidence = O.BuildEvidence(r, {
                guildGuid = ctx.guildGuid,
                bankTab = ctx.bankTab,
                generation = ctx.generation,
                observedBy = ctx.observedBy,
                observedAt = ctx.observedAt,
                snapshotCount = #rows,
                occurrenceIndex = occByCore[core],
                neighborsOlder = older,
                neighborsNewer = newer,
            })
            if evidence then
                eligible[#eligible + 1] = evidence
            end
        end
    end
    return eligible
end

function O.ReconcileSnapshot(store, profileId, snapshot, opts)
    opts = opts or {}
    if type(store) ~= "table" or type(profileId) ~= "string" then
        return { created = 0, updated = 0, ambiguous = 0, suppressed = 0, ignored = 0 }
    end
    if type(snapshot) ~= "table" then
        return { created = 0, updated = 0, ambiguous = 0, suppressed = 0, ignored = 0 }
    end

    local guildGuid = tostring(snapshot.guildGuid or "")
    local bankTab = tonumber(snapshot.bankTab)
    local scope = O.EnsureScope(store, guildGuid, bankTab)
    if not scope then
        return { created = 0, updated = 0, ambiguous = 0, suppressed = 0, ignored = 0 }
    end

    local now = tonumber(opts.now) or Now()
    O.PruneScope(scope, now)

    -- Incomplete/stale marker: caller must not pass authoritative=false as fresh empty.
    if snapshot.authoritative == false then
        Debug("Warn", "skip reconcile: snapshot not authoritative for %s tab=%s", guildGuid, tostring(bankTab))
        return { created = 0, updated = 0, ambiguous = 0, suppressed = 0, ignored = 0, skipped = true }
    end

    local evidenceRows = EnrichSnapshotRows(snapshot.rows or snapshot.transactions, snapshot.requestedSet, {
        guildGuid = guildGuid,
        bankTab = bankTab,
        generation = snapshot.generation,
        observedBy = snapshot.observedBy,
        observedAt = tonumber(snapshot.observedAt) or now,
    })

    local eligibility = snapshot.eligibility
    if type(eligibility) == "table" then
        local filtered = {}
        for i = 1, #evidenceRows do
            if O.IsEvidenceEligible(evidenceRows[i], eligibility) then
                filtered[#filtered + 1] = evidenceRows[i]
            end
        end
        evidenceRows = filtered
    end

    local stats = { created = 0, updated = 0, ambiguous = 0, suppressed = 0, ignored = 0 }
    local observations = scope.observations
    local usedObs = {}
    local usedRow = {}
    local pairs = {}

    for r = 1, #evidenceRows do
        for o = 1, #observations do
            local score = O.MatchScore(observations[o], evidenceRows[r])
            if score and score >= O.MIN_MATCH_SCORE then
                pairs[#pairs + 1] = { row = r, obs = o, score = score }
            end
        end
    end

    table.sort(pairs, function(a, b)
        if a.score == b.score then
            if a.row == b.row then return a.obs < b.obs end
            return a.row < b.row
        end
        return a.score > b.score
    end)

    -- Detect ambiguous near-ties before greedy assignment.
    local rowBest = {}
    local rowSecond = {}
    for i = 1, #pairs do
        local p = pairs[i]
        if not rowBest[p.row] then
            rowBest[p.row] = p
        elseif not rowSecond[p.row] then
            rowSecond[p.row] = p
        end
    end

    for r = 1, #evidenceRows do
        local best = rowBest[r]
        local second = rowSecond[r]
        if best and second and (best.score - second.score) < O.AMBIGUITY_MARGIN then
            local obsA = observations[best.obs]
            local obsB = observations[second.obs]
            if obsA and obsA.status ~= "ambiguous" then
                obsA.status = "ambiguous"
                stats.ambiguous = stats.ambiguous + 1
            end
            if obsB and obsB.status ~= "ambiguous" then
                obsB.status = "ambiguous"
                stats.ambiguous = stats.ambiguous + 1
            end
            usedRow[r] = true
            Debug("Info", "ambiguous match for donor=%s item=%s qty=%s",
                tostring(evidenceRows[r].donor), tostring(evidenceRows[r].itemId), tostring(evidenceRows[r].quantity))
        end
    end

    for i = 1, #pairs do
        local p = pairs[i]
        if not usedRow[p.row] and not usedObs[p.obs] then
            local second = rowSecond[p.row]
            if second and (p.score - second.score) < O.AMBIGUITY_MARGIN then
                -- Already handled as ambiguous.
            else
                usedRow[p.row] = true
                usedObs[p.obs] = true
                local obs = observations[p.obs]
                CopyEvidenceFields(obs, evidenceRows[p.row])
                obs.lastSeen = now
                if obs.status == "verified" or obs.status == "rejected" or obs.status == "trusted" then
                    -- Keep terminal statuses; still refresh evidence timestamps.
                elseif obs.status == "ambiguous" then
                    -- Keep ambiguous until admin review; still refresh evidence.
                else
                    obs.status = "pending"
                end
                obs.seenCount = FloorNonNeg(obs.seenCount) + 1
                stats.updated = stats.updated + 1
                Debug("Verbose", "updated observation %s score=%s", tostring(obs.localId), tostring(p.score))
            end
        end
    end

    for r = 1, #evidenceRows do
        if not usedRow[r] then
            local evidence = evidenceRows[r]
            local V = SF.ConsumablesVerification
            if V and V.IsRejected and V.IsRejected(scope, evidence) then
                stats.suppressed = stats.suppressed + 1
                Debug("Info", "rejection-suppressed rediscovery donor=%s item=%s qty=%s",
                    tostring(evidence.donor), tostring(evidence.itemId), tostring(evidence.quantity))
            elseif IsSuppressed(scope, evidence) then
                stats.suppressed = stats.suppressed + 1
                Debug("Info", "suppressed rediscovery donor=%s item=%s qty=%s",
                    tostring(evidence.donor), tostring(evidence.itemId), tostring(evidence.quantity))
            else
                -- Fail-conservative: when an unmatched row could collide with an
                -- unmatched empty-context pending observation, mark ambiguity
                -- instead of leaving two confident authoritative candidates.
                local conflict = nil
                for o = 1, #observations do
                    if not usedObs[o] then
                        local prior = observations[o]
                        if prior.coreSignature == evidence.coreSignature
                            and tonumber(prior.generation) == tonumber(evidence.generation)
                            and tostring(prior.guildGuid or "") == tostring(evidence.guildGuid or "")
                            and tonumber(prior.bankTab) == tonumber(evidence.bankTab)
                            and (prior.status == "pending" or prior.status == "ambiguous")
                            and #(prior.neighborsOlder or {}) == 0
                            and #(prior.neighborsNewer or {}) == 0
                            and #(evidence.neighborsOlder or {}) == 0
                            and #(evidence.neighborsNewer or {}) == 0
                        then
                            local tPrior = tonumber(prior.approxTxnTime)
                            local tEv = tonumber(evidence.approxTxnTime)
                            if tPrior and tEv and math.abs(tPrior - tEv) <= O.TIME_TOLERANCE_SECONDS then
                                conflict = prior
                                break
                            end
                        end
                    end
                end
                local obs = {
                    localId = NextLocalId(store, profileId),
                    status = conflict and "ambiguous" or "pending",
                    firstSeen = now,
                    lastSeen = now,
                    seenCount = 1,
                    observedBy = evidence.observedBy,
                }
                CopyEvidenceFields(obs, evidence)
                observations[#observations + 1] = obs
                stats.created = stats.created + 1
                if conflict then
                    if conflict.status ~= "ambiguous" then
                        conflict.status = "ambiguous"
                        stats.ambiguous = stats.ambiguous + 1
                    end
                    stats.ambiguous = stats.ambiguous + 1
                    Debug("Info", "ambiguous empty-context collision donor=%s item=%s qty=%s",
                        tostring(evidence.donor), tostring(evidence.itemId), tostring(evidence.quantity))
                else
                    Debug("Info", "captured observation %s donor=%s item=%s qty=%s occ=%s",
                        tostring(obs.localId), tostring(obs.donor), tostring(obs.itemId),
                        tostring(obs.quantity), tostring(obs.occurrenceIndex))
                end
            end
        end
    end

    O.PruneScope(scope, now)
    if scope.backfillCompleted ~= true and snapshot.authoritative ~= false then
        scope.backfillCompleted = true
        Debug("Info", "initial observation backfill baseline set for %s tab=%s", guildGuid, tostring(bankTab))
    end
    return stats
end

function O.ListPending(store, guildGuid, bankTab, opts)
    opts = opts or {}
    local scope = O.EnsureScope(store, guildGuid, bankTab)
    if not scope then return {} end
    local now = tonumber(opts.now) or Now()
    O.PruneScope(scope, now)
    local out = {}
    for i = 1, #scope.observations do
        local obs = scope.observations[i]
        local status = obs and obs.status or ""
        if status == "pending" or status == "ambiguous" then
            out[#out + 1] = obs
        end
    end
    return out
end

function O.ListDisplayObservations(store, guildGuid, bankTab, opts)
    opts = opts or {}
    local scope = O.EnsureScope(store, guildGuid, bankTab)
    if not scope then return {} end
    local now = tonumber(opts.now) or Now()
    O.PruneScope(scope, now)
    local out = {}
    for i = 1, #scope.observations do
        local obs = scope.observations[i]
        local status = obs and obs.status or ""
        if status == "pending" or status == "ambiguous" or status == "verified" then
            out[#out + 1] = obs
        end
    end
    return out
end

function O.CountObservations(store, guildGuid, bankTab)
    local scope = store and O.EnsureScope(store, guildGuid, bankTab)
    if not scope then return 0 end
    return #(scope.observations or {})
end

function O.RequestedSetFromConfig(cfg)
    local set = {}
    if type(cfg) ~= "table" or type(cfg.requestedItems) ~= "table" then
        return set
    end
    for key, row in pairs(cfg.requestedItems) do
        local itemId = nil
        if type(row) == "table" then
            itemId = tonumber(row.itemId)
        end
        itemId = itemId or tonumber(key)
        if IsItemId(itemId) then
            set[tostring(itemId)] = true
            set[itemId] = true
        end
    end
    return set
end
