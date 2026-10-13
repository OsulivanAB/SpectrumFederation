-- C1 runtime read index: 64 deterministic ID buckets with source-local sequences.
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

-- index = {
--   epoch = n,
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
    if GG._epochBase then
        return GG._epochBase
    end
    local now = (GetTime and GetTime()) or 0
    -- A process-local sequence alone restarts after /reload. Mix a high-resolution
    -- session value with entropy so a receiver never treats a reloaded source's
    -- cursors as the same source incarnation.
    GG._epochBase = math.floor(now * 1000000) * 1000000 + math.random(1, 999999)
    return GG._epochBase
end

local function nextEpoch()
    GG.InitEpochIncarnation()
    GG._epochSeq = (tonumber(GG._epochSeq) or 0) + 1
    return GG._epochBase + GG._epochSeq
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

function GG.BumpIndexEpoch(index)
    if type(index) ~= "table" then
        return
    end
    if GG._providers and GG._providers.byId and GG.InvalidateProviderBookmarks then
        for _, entry in pairs(GG._providers.byId) do
            if entry and entry.index == index then
                GG.InvalidateProviderBookmarks(entry)
                entry._buildList = nil
                entry._buildPos = nil
                break
            end
        end
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

function GG.CaptureViewSummaries(index, eligibilityGen, scopeId, providerId, schema, exportable)
    if type(index) ~= "table" then
        return nil
    end
    local buckets = {}
    for i = 0, GG.BUCKET_COUNT - 1 do
        local b = index.buckets[i]
        local summary = { lastSeq = 0, count = 0, fingerprint = 0 }
        for _, seq in ipairs(b.order or {}) do
            local entry = b.bySeq[seq]
            if entry and (not exportable or exportable(entry.id, entry)) then
                summary.lastSeq = math.max(summary.lastSeq, entry.seq or 0)
                summary.count = summary.count + 1
                summary.fingerprint = GG.CombineFingerprint(summary.fingerprint, entry.id, entry.versionFp)
            end
        end
        buckets[i] = summary
    end
    return {
        providerId = providerId,
        schema = schema,
        scopeId = scopeId,
        eligibilityGen = eligibilityGen,
        epoch = index.epoch,
        buckets = buckets,
        packedBuckets = GG.PackBucketSummaries(buckets),
        viewId = string.format("%s:%d:%d", tostring(providerId), tonumber(index.epoch) or 0, math.random(1, 1e9)),
    }
end

-- Seek manifest entries: afterSeq < sequence <= endSeq in increasing order.
-- Starts at the order position after afterSeq (direct seek); returns examined count.
function GG.IndexSeekManifest(index, bucketId, afterSeq, endSeq, limit, exportable)
    local out = {}
    local examined = 0
    if type(index) ~= "table" then
        return out, { examined = 0, done = true }
    end
    bucketId = tonumber(bucketId)
    afterSeq = tonumber(afterSeq) or 0
    endSeq = tonumber(endSeq) or 0
    limit = tonumber(limit) or 1
    local bucket = index.buckets[bucketId]
    if not bucket then
        return out, { examined = 0, done = true }
    end
    local startPos = 1
    if afterSeq > 0 and bucket.posBySeq and bucket.posBySeq[afterSeq] then
        startPos = bucket.posBySeq[afterSeq] + 1
    elseif afterSeq > 0 then
        -- afterSeq missing (hole): binary-ish scan for first seq > afterSeq without
        -- walking the entire prefix when posBySeq is available for nearby seqs.
        local guess = afterSeq
        while guess > 0 and not (bucket.posBySeq and bucket.posBySeq[guess]) do
            guess = guess - 1
            examined = examined + 1
            if examined > 8 then
                break
            end
        end
        if guess > 0 and bucket.posBySeq and bucket.posBySeq[guess] then
            startPos = bucket.posBySeq[guess] + 1
        end
    end
    examined = 0
    local done = true
    for i = startPos, #bucket.order do
        local seq = bucket.order[i]
        examined = examined + 1
        if seq > afterSeq and seq <= endSeq then
            local entry = bucket.bySeq[seq]
            if entry and (not exportable or exportable(entry.id, entry)) then
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
        elseif seq > endSeq then
            break
        end
    end
    return out, { examined = examined, done = done }
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
