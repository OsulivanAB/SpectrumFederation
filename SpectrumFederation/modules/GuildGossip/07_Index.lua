-- C1 runtime read index: 64 deterministic ID buckets with source-local sequences.
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

-- index = {
--   epoch = string, -- exactly-representable "incarnation.seq"
--   buckets = { [0..63] = { lastSeq, count, fingerprint, bySeq = {seq->entry}, order = {seq...} } },
--   byId = { [id] = entry },
--   dirty = bool,
-- }

local function newBucket()
    return {
        lastSeq = 0,
        count = 0,
        fingerprint = 0,
        bySeq = {},
        order = {},
        posBySeq = {}, -- seq -> order index for O(1) seek start
    }
end

function GG.InitEpochIncarnation()
    if GG._epochIncarnation then
        return GG._epochIncarnation
    end
    local now = (GetTime and GetTime()) or 0
    -- Keep both parts well under 2^53 so consecutive seq increments stay distinct
    -- even after long sessions. String form avoids double-precision +1 collisions.
    local seconds = math.floor(tonumber(now) or 0)
    if seconds < 0 then
        seconds = 0
    end
    GG._epochIncarnation = string.format("%d-%d", seconds, math.random(1, 1000000000))
    GG._epochSeq = 0
    return GG._epochIncarnation
end

local function nextEpoch()
    GG.InitEpochIncarnation()
    GG._epochSeq = (tonumber(GG._epochSeq) or 0) + 1
    return string.format("%s.%d", GG._epochIncarnation, GG._epochSeq)
end

function GG.CreateIndex()
    local index = {
        epoch = nextEpoch(),
        buckets = {},
        byId = {},
        pendingBuild = {},
        buildCursor = 1,
        buildComplete = false,
        dirty = true,
    }
    for i = 0, GG.BUCKET_COUNT - 1 do
        index.buckets[i] = newBucket()
    end
    return index
end

local function invalidateProviderBookmarksForIndex(index)
    if not (GG._providers and GG._providers.byId and GG.InvalidateProviderBookmarks) then
        return nil
    end
    for _, entry in pairs(GG._providers.byId) do
        if entry and entry.index == index then
            GG.InvalidateProviderBookmarks(entry)
            return entry
        end
    end
    return nil
end

local function notifyIndexEpochChanged(entry)
    if entry and type(GG.OnProviderIndexEpochChanged) == "function" then
        pcall(GG.OnProviderIndexEpochChanged, entry.id)
    end
end

function GG.BumpIndexEpoch(index)
    if type(index) ~= "table" then
        return
    end
    local entry = invalidateProviderBookmarksForIndex(index)
    if entry then
        entry._listCursor = nil
        entry._reconcileSeen = nil
        entry._reconciling = nil
        entry._reconcileFollowUp = nil
    end
    index.epoch = nextEpoch()
    index.buckets = {}
    index.byId = {}
    index.pendingBuild = {}
    index.buildCursor = 1
    index.buildComplete = false
    index.dirty = true
    for i = 0, GG.BUCKET_COUNT - 1 do
        index.buckets[i] = newBucket()
    end
    notifyIndexEpochChanged(entry)
end

-- Bump the view epoch and invalidate bookmarks while preserving index rows.
-- Used after a successful dirty rebuild removes disappeared records.
function GG.TouchIndexEpoch(index)
    if type(index) ~= "table" then
        return
    end
    local entry = invalidateProviderBookmarksForIndex(index)
    index.epoch = nextEpoch()
    notifyIndexEpochChanged(entry)
end

local function recomputeBucketFingerprint(bucket)
    local fp = 0
    for _, entry in pairs(bucket.bySeq) do
        fp = GG.CombineFingerprint(fp, entry.id, entry.versionFp)
    end
    bucket.fingerprint = fp
    bucket.count = 0
    for _ in pairs(bucket.bySeq) do
        bucket.count = bucket.count + 1
    end
end

-- Insert or replace an immutable record version into the read index.
-- Ordinary appends assign a new source-local sequence; same id+version is a no-op.
-- Physical replacement of a different version invalidates by bumping epoch (caller).
function GG.IndexUpsert(index, recordId, versionFp, meta)
    if type(index) ~= "table" or recordId == nil then
        return false, "bad_args"
    end
    recordId = tostring(recordId)
    versionFp = tostring(versionFp or "")
    local existing = index.byId[recordId]
    if existing and existing.versionFp == versionFp then
        return false, "duplicate"
    end
    if existing and existing.versionFp ~= versionFp then
        -- Content replacement requires view invalidation — bump epoch and re-add.
        return false, "replaced"
    end

    local bucketId = GG.BucketForId(recordId)
    local bucket = index.buckets[bucketId]
    local seq = (bucket.lastSeq or 0) + 1
    local entry = {
        id = recordId,
        versionFp = versionFp,
        seq = seq,
        bucket = bucketId,
        meta = meta,
    }
    bucket.bySeq[seq] = entry
    local pos = #bucket.order + 1
    bucket.order[pos] = seq
    bucket.posBySeq[seq] = pos
    bucket.lastSeq = seq
    bucket.count = (bucket.count or 0) + 1
    bucket.fingerprint = GG.CombineFingerprint(bucket.fingerprint, recordId, versionFp)
    index.byId[recordId] = entry
    -- Ordinary appends update the live index in place. Only incomplete cold builds
    -- remain dirty; completed indexes must not re-list history every step.
    if not index.buildComplete then
        index.dirty = true
    end
    return true, entry
end

function GG.IndexRemove(index, recordId)
    if type(index) ~= "table" or recordId == nil then
        return false
    end
    recordId = tostring(recordId)
    local existing = index.byId[recordId]
    if not existing then
        return false
    end
    local bucket = index.buckets[existing.bucket]
    if bucket and bucket.bySeq[existing.seq] then
        bucket.bySeq[existing.seq] = nil
        -- order list retains holes; seekers skip missing seqs
        recomputeBucketFingerprint(bucket)
    end
    index.byId[recordId] = nil
    return true
end

-- Pack 64 bucket summaries as a dense array:
-- { lastSeq0, count0, fp0, lastSeq1, count1, fp1, ... } (length 192)
-- Keeps VIEW whispers well under the 4 KiB envelope cap with CBOR/Base64.
function GG.PackBucketSummaries(bucketsById)
    local packed = {}
    for i = 0, GG.BUCKET_COUNT - 1 do
        local b = bucketsById and bucketsById[i] or {}
        local base = i * 3
        packed[base + 1] = tonumber(b.lastSeq) or 0
        packed[base + 2] = tonumber(b.count) or 0
        packed[base + 3] = tonumber(b.fingerprint) or 0
    end
    return packed
end

function GG.UnpackBucketSummaries(packed)
    local buckets = {}
    if type(packed) ~= "table" then
        for i = 0, GG.BUCKET_COUNT - 1 do
            buckets[i] = { lastSeq = 0, count = 0, fingerprint = 0 }
        end
        return buckets
    end
    for i = 0, GG.BUCKET_COUNT - 1 do
        local base = i * 3
        buckets[i] = {
            lastSeq = tonumber(packed[base + 1]) or 0,
            count = tonumber(packed[base + 2]) or 0,
            fingerprint = tonumber(packed[base + 3]) or 0,
        }
    end
    return buckets
end

local function finishViewCapture(state)
    local buckets = state.buckets
    return {
        providerId = state.providerId,
        schema = state.schema,
        scopeId = state.scopeId,
        eligibilityGen = state.eligibilityGen,
        epoch = state.epoch,
        buckets = buckets,
        packedBuckets = GG.PackBucketSummaries(buckets),
        viewId = string.format("%s:%s:%d", tostring(state.providerId), tostring(state.epoch), math.random(1, 1e9)),
        examined = state.examinedTotal or 0,
    }
end

-- Capture fixed-end-marker bucket summaries. Without an export filter this is O(64)
-- from maintained bucket stats. With a filter, work continues under limits across
-- calls via the returned resume state (cancellation when epoch/eligibility changes).
-- Returns: view|nil, resumeState|nil, examinedThisCall
function GG.CaptureViewSummaries(index, eligibilityGen, scopeId, providerId, schema, exportable, limits, resume)
    if type(index) ~= "table" then
        return nil, nil, 0
    end

    if not exportable then
        local buckets = {}
        for i = 0, GG.BUCKET_COUNT - 1 do
            local b = index.buckets[i] or {}
            buckets[i] = {
                lastSeq = tonumber(b.lastSeq) or 0,
                count = tonumber(b.count) or 0,
                fingerprint = tonumber(b.fingerprint) or 0,
            }
        end
        local view = {
            providerId = providerId,
            schema = schema,
            scopeId = scopeId,
            eligibilityGen = eligibilityGen,
            epoch = index.epoch,
            buckets = buckets,
            packedBuckets = GG.PackBucketSummaries(buckets),
            viewId = string.format("%s:%s:%d", tostring(providerId), tostring(index.epoch), math.random(1, 1e9)),
            examined = GG.BUCKET_COUNT,
        }
        return view, nil, GG.BUCKET_COUNT
    end

    local state = resume
    if state then
        if state.epoch ~= index.epoch
            or state.eligibilityGen ~= eligibilityGen
            or state.scopeId ~= scopeId
            or state.providerId ~= providerId then
            state = nil
        end
    end
    if not state then
        local endMarkers = {}
        local buckets = {}
        for i = 0, GG.BUCKET_COUNT - 1 do
            local b = index.buckets[i] or {}
            endMarkers[i] = tonumber(b.lastSeq) or 0
            buckets[i] = { lastSeq = 0, count = 0, fingerprint = 0 }
        end
        state = {
            epoch = index.epoch,
            eligibilityGen = eligibilityGen,
            scopeId = scopeId,
            providerId = providerId,
            schema = schema,
            endMarkers = endMarkers,
            buckets = buckets,
            bucketId = 0,
            orderPos = 1,
            examinedTotal = 0,
        }
    end

    local budget = math.max(1, tonumber(limits and limits.indexEntries) or GG.INDEX_ENTRIES_PER_STEP.SLOW)
    local examined = 0
    while state.bucketId < GG.BUCKET_COUNT and examined < budget do
        local bucketId = state.bucketId
        local bucket = index.buckets[bucketId]
        local endSeq = state.endMarkers[bucketId] or 0
        local summary = state.buckets[bucketId]
        local order = bucket and bucket.order or {}
        local pos = state.orderPos
        while pos <= #order and examined < budget do
            local seq = order[pos]
            pos = pos + 1
            examined = examined + 1
            state.examinedTotal = (state.examinedTotal or 0) + 1
            if type(seq) == "number" and seq > 0 and seq <= endSeq then
                local entry = bucket.bySeq[seq]
                if entry then
                    local allowed = true
                    if exportable then
                        allowed = exportable(entry.id, entry)
                        -- nil means unexpected filter failure: abort without a
                        -- successful incomplete view the peer could cover.
                        if allowed == nil then
                            return nil, nil, examined
                        end
                    end
                    if allowed then
                        summary.lastSeq = math.max(summary.lastSeq, entry.seq or 0)
                        summary.count = summary.count + 1
                        summary.fingerprint = GG.CombineFingerprint(
                            summary.fingerprint, entry.id, entry.versionFp)
                    end
                end
            elseif type(seq) == "number" and seq > endSeq then
                -- Fixed end marker reached for this bucket.
                pos = #order + 1
                break
            end
        end
        state.orderPos = pos
        if pos > #order then
            state.bucketId = bucketId + 1
            state.orderPos = 1
        end
    end

    if state.bucketId >= GG.BUCKET_COUNT then
        return finishViewCapture(state), nil, examined
    end
    return nil, state, examined
end

-- Seek manifest entries: afterSeq < sequence <= endSeq in increasing order.
-- Starts at the order position after afterSeq (direct seek). Bounds both returned
-- entries (limit) and examined order slots / filter callbacks (examineLimit).
-- When a budget slice yields no exportable entries, lastExaminedSeq is the scan
-- continuation cursor the requester must advance to (not the original afterSeq).
function GG.IndexSeekManifest(index, bucketId, afterSeq, endSeq, limit, exportable, examineLimit)
    local out = {}
    local examined = 0
    if type(index) ~= "table" then
        return out, { examined = 0, done = true, lastExaminedSeq = nil }
    end
    bucketId = tonumber(bucketId)
    afterSeq = tonumber(afterSeq) or 0
    endSeq = tonumber(endSeq) or 0
    limit = tonumber(limit) or 1
    examineLimit = math.max(1, tonumber(examineLimit) or limit)
    local bucket = index.buckets[bucketId]
    if not bucket then
        return out, { examined = 0, done = true, lastExaminedSeq = nil }
    end
    local startPos = 1
    if afterSeq > 0 and bucket.posBySeq and bucket.posBySeq[afterSeq] then
        startPos = bucket.posBySeq[afterSeq] + 1
    elseif afterSeq > 0 then
        -- afterSeq missing (hole): bounded probe for a nearby posBySeq anchor.
        local guess = afterSeq
        while guess > 0 and not (bucket.posBySeq and bucket.posBySeq[guess]) do
            guess = guess - 1
            examined = examined + 1
            if examined >= examineLimit then
                return out, { examined = examined, done = false, lastExaminedSeq = afterSeq }
            end
        end
        if guess > 0 and bucket.posBySeq and bucket.posBySeq[guess] then
            startPos = bucket.posBySeq[guess] + 1
        end
    end
    examined = 0
    local done = true
    local lastExaminedSeq = nil
    for i = startPos, #bucket.order do
        if examined >= examineLimit then
            done = false
            break
        end
        local seq = bucket.order[i]
        examined = examined + 1
        if seq > afterSeq and seq <= endSeq then
            lastExaminedSeq = seq
            local entry = bucket.bySeq[seq]
            if entry then
                local allowed = true
                if exportable then
                    allowed = exportable(entry.id, entry)
                    if allowed == nil then
                        return out, {
                            examined = examined,
                            done = false,
                            lastExaminedSeq = lastExaminedSeq,
                            error = "export_filter",
                        }
                    end
                end
                if allowed then
                    out[#out + 1] = {
                        seq = entry.seq,
                        id = entry.id,
                        versionFp = entry.versionFp,
                    }
                    if #out >= limit then
                        done = false
                        break
                    end
                end
            end
        elseif seq > endSeq then
            break
        end
    end
    return out, { examined = examined, done = done, lastExaminedSeq = lastExaminedSeq }
end

function GG.IndexGetEntry(index, recordId)
    if type(index) ~= "table" then
        return nil
    end
    return index.byId[tostring(recordId)]
end

function GG.BucketsDiffer(localBucket, remoteBucket)
    localBucket = localBucket or {}
    remoteBucket = remoteBucket or {}
    if (tonumber(localBucket.count) or 0) ~= (tonumber(remoteBucket.count) or 0) then
        return true
    end
    if (tonumber(localBucket.fingerprint) or 0) ~= (tonumber(remoteBucket.fingerprint) or 0) then
        return true
    end
    if (tonumber(localBucket.lastSeq) or 0) ~= (tonumber(remoteBucket.lastSeq) or 0) then
        -- Equal count+fp with different lastSeq can still be equal content after
        -- rebuilds; treat as advisory difference only when count/fp also differ.
        -- When count and fp match, do not differ solely on lastSeq.
        return false
    end
    return false
end
