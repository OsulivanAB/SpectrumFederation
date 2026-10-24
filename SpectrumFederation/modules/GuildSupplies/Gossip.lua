-- Guild Supplies staged configuration gossip provider (#387).
-- Registers through the production Guild Gossip API. Does not activate live
-- Live bank/accounting writers remain inactive until #389. Phase 3B (#388) adds
-- staged donation evidence, identity links, and ledger gossip on this provider.
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies
local GG = SF.GuildGossip

GS.PROVIDER_ID = GS.PROVIDER_ID or "sf.guildsupplies.config"
-- Wire schema for sf.guildsupplies.config. #397 valuations require schema 2;
-- Guild Gossip matches provider schemas by strict equality.
GS.PROVIDER_SCHEMA = GS.PROVIDER_SCHEMA or 2

local function DebugInfo(fmt, ...)
    if SF.Debug and SF.Debug.Info and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Info("GUILD_SUPPLIES", fmt, ...)
    end
end

local function DebugWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Warn("GUILD_SUPPLIES", fmt, ...)
    end
end

-- Export index: dense record ids rebuilt from the current staged guild record.
local exportState = {
    order = {},
    byId = {},
    enumPos = nil,
    guildKey = nil,
    datasetId = nil,
    epoch = 0,
    appendPos = 0,
    dirtyRebuild = false,
    resolveScanPos = 0,
    maintIdle = true,
    countsDirty = true,
    cachedOpCount = 0,
    cachedTransferOpCount = 0,
    cachedCampaignCount = 0,
    cachedArchiveCount = 0,
    pendingCursor = nil,
    conflictCursor = nil,
    -- Last fully completed open-conflict target key (resume after it).
    openConflictCursor = nil,
    -- In-progress open-conflict entry: target key + next candidate index.
    openConflictPartialKey = nil,
    openConflictCandidatePos = nil,
    maintScheduled = false,
    archiveBuildCursor = nil,
    -- Cold accepted-op construction cursor (BuildOpExportBodies is paced).
    opBuildCursor = nil,
    opBuildNeeded = false,
    evidenceBuildNeeded = false,
    -- #388 paced cold construction for donation evidence + accepted ledger.
    ledgerBuildNeeded = false,
    ledgerBuildCursor = nil,
    -- "archive" then "live": cold drain covers shelved + current-generation rows.
    ledgerBuildPhase = nil,
    -- Warm high-water for live _consumableEvents (not a fixed trailing window).
    ledgerWarmPos = 0,
    -- Warm high-water for _consumableEventArchive (late historical appends).
    ledgerArchiveWarmPos = 0,
    donationEvidenceBuildNeeded = false,
    donationEvidenceBuildCursor = nil,
    -- #397 paced cold construction for accepted donation valuations.
    valuationBuildNeeded = false,
    valuationBuildCursor = nil,
    -- Invalidates queued maint closures after disable/replacement.
    maintGeneration = 0,
}

-- Declared before the export mutators that consult it. A later `local` would
-- leave those closures bound to a nil global and skip valuation publication.
local providerRegistered = false

-- Bank-snapshot (and similar) notify batch. Forward-declared so
-- NoteValuationExported can coalesce outward notifies without a later `local`
-- shadowing the upvalue as a nil global.
local durableNotifyBatchDepth = 0
local durableNotifyBatchPending = nil
local PreferDurableNotifyReason

-- Runtime reassembly buffer for paged campaign archives and operation manifests
-- (not SavedVariables). Scoped by datasetId; aggregate caps + TTL reclaim.
local archivePageBuffer = {} -- [campaignId] = { meta, pages, datasetId, pageCount, at, sourcePeer }
local archivePageBufferCount = 0
local archivePageBufferPages = 0
-- Operation-manifest FragmentBuffer: [opId] = { shell, pages, datasetId, pageCount, at, sourcePeer }
local opManifestBuffer = {}
local opManifestBufferCount = 0
local opManifestBufferPages = 0

local function ClearArchivePageBuffer(campaignId)
    local buf = archivePageBuffer[campaignId]
    if not buf then
        return
    end
    local pages = 0
    if type(buf.pages) == "table" then
        for _ in pairs(buf.pages) do
            pages = pages + 1
        end
    end
    archivePageBuffer[campaignId] = nil
    archivePageBufferCount = math.max(0, (archivePageBufferCount or 0) - 1)
    archivePageBufferPages = math.max(0, (archivePageBufferPages or 0) - pages)
end

local function ClearOpManifestBuffer(opId)
    local buf = opManifestBuffer[opId]
    if not buf then
        return
    end
    local pages = 0
    if type(buf.pages) == "table" then
        for _ in pairs(buf.pages) do
            pages = pages + 1
        end
    end
    opManifestBuffer[opId] = nil
    opManifestBufferCount = math.max(0, (opManifestBufferCount or 0) - 1)
    opManifestBufferPages = math.max(0, (opManifestBufferPages or 0) - pages)
end

-- Per-source incomplete-assembly count for shared pool isolation. One ordinary
-- member must not consume every slot needed by a legitimate editor.
local function CountOpManifestBuffersForPeer(peerName)
    if type(peerName) ~= "string" or peerName == "" then
        return 0
    end
    local n = 0
    for _, buf in pairs(opManifestBuffer) do
        if type(buf) == "table" and buf.sourcePeer == peerName then
            n = n + 1
        end
    end
    return n
end

local function CountOpManifestPagesForPeer(peerName)
    if type(peerName) ~= "string" or peerName == "" then
        return 0
    end
    local n = 0
    for _, buf in pairs(opManifestBuffer) do
        if type(buf) == "table" and buf.sourcePeer == peerName and type(buf.pages) == "table" then
            for _ in pairs(buf.pages) do
                n = n + 1
            end
        end
    end
    return n
end

local function CanAllocateOpManifestBuffer(peerName, maxCamps)
    maxCamps = tonumber(maxCamps) or 16
    if (opManifestBufferCount or 0) >= maxCamps then
        return false
    end
    -- Reserve at least two aggregate slots for other peers / editors.
    local reserved = math.min(2, math.max(0, maxCamps - 1))
    local perPeerCap = math.max(1, maxCamps - reserved)
    if CountOpManifestBuffersForPeer(peerName) >= perPeerCap then
        return false
    end
    return true
end

-- Per-source page isolation: one shell-less manifest must not fill the shared
-- page pool. Reserve at least one full legitimate manifest for other peers.
local function CanRetainOpManifestPage(peerName, maxPagesBuf)
    maxPagesBuf = tonumber(maxPagesBuf) or 64
    if (opManifestBufferPages or 0) >= maxPagesBuf then
        return false
    end
    local oneManifest = GS.MAX_MANIFEST_PAGES or 64
    local reserved = math.min(oneManifest, math.max(0, maxPagesBuf - 1))
    local perPeerCap = math.max(1, maxPagesBuf - reserved)
    if CountOpManifestPagesForPeer(peerName) >= perPeerCap then
        return false
    end
    return true
end

local function ReclaimExpiredFragmentBuffers(opts)
    opts = opts or {}
    local now = GetServerTime and GetServerTime() or 0
    local ttl = GS.FRAGMENT_BUFFER_TTL_SECONDS or 600
    local wantGuild = opts.guildKey
    local wantDataset = opts.datasetId
    local removed = 0
    if now > 0 and ttl > 0 then
        for cid, buf in pairs(archivePageBuffer) do
            local stale = type(buf) ~= "table"
                or (buf.at and (now - (tonumber(buf.at) or 0)) > ttl)
                or (wantDataset and buf.datasetId and buf.datasetId ~= wantDataset)
                or (wantGuild and buf.guildKey and buf.guildKey ~= wantGuild)
            if stale then
                ClearArchivePageBuffer(cid)
                removed = removed + 1
            end
        end
        for oid, buf in pairs(opManifestBuffer) do
            local stale = type(buf) ~= "table"
                or (buf.at and (now - (tonumber(buf.at) or 0)) > ttl)
                or (wantDataset and buf.datasetId and buf.datasetId ~= wantDataset)
                or (wantGuild and buf.guildKey and buf.guildKey ~= wantGuild)
            if stale then
                ClearOpManifestBuffer(oid)
                removed = removed + 1
            end
        end
    end
    return removed
end

local function ResetArchivePageBuffers()
    archivePageBuffer = {}
    archivePageBufferCount = 0
    archivePageBufferPages = 0
    opManifestBuffer = {}
    opManifestBufferCount = 0
    opManifestBufferPages = 0
end

--- Observability for fragment-buffer capacity tests (not SavedVariables).
function GS.GetFragmentBufferStats()
    return {
        archiveAssemblies = archivePageBufferCount or 0,
        archivePages = archivePageBufferPages or 0,
        opAssemblies = opManifestBufferCount or 0,
        opPages = opManifestBufferPages or 0,
    }
end

-- True when a newly allocated assembly has no retained shell/meta/pages yet.
local function OpManifestBufferIsEmpty(buf)
    if type(buf) ~= "table" then
        return true
    end
    if type(buf.shell) == "table" then
        return false
    end
    if type(buf.pages) == "table" then
        for _ in pairs(buf.pages) do
            return false
        end
    end
    return true
end

local function ArchivePageBufferIsEmpty(buf)
    if type(buf) ~= "table" then
        return true
    end
    if type(buf.meta) == "table" then
        return false
    end
    if type(buf.pages) == "table" then
        for _ in pairs(buf.pages) do
            return false
        end
    end
    return true
end

--- Worst-case versionFp length used when sizing pages (ContentFingerprint ≤ MAX_OPERATION_ID).
local function EstimateVersionFp()
    local maxLen = GS.MAX_OPERATION_ID or 192
    if GS.ContentFingerprint then
        local fp = GS.ContentFingerprint({ kind = "gs-size", id = "size", pad = "x" })
        if type(fp) == "string" and #fp > 0 then
            if #fp > maxLen then
                return fp:sub(1, maxLen)
            end
            if #fp < maxLen then
                return fp .. string.rep("f", maxLen - #fp)
            end
            return fp
        end
    end
    return string.rep("f", maxLen)
end

--- Wrapper-inclusive wire size estimate (prefer real CBOR when available).
-- Uses a worst-case versionFp so packing decisions match final ID/versionFp wrappers.
local function EstimateWireRecordBytes(recordId, body)
    local envelope = {
        id = tostring(recordId or "x"),
        versionFp = EstimateVersionFp(),
        body = body,
    }
    if C_EncodingUtil and C_EncodingUtil.SerializeCBOR then
        local ok, raw = pcall(C_EncodingUtil.SerializeCBOR, envelope)
        if ok and type(raw) == "string" then
            return #raw
        end
    end
    -- Fallback: recursive approximate UTF-8 length of a stable dump.
    local parts = {}
    local function walk(v, depth)
        depth = (depth or 0) + 1
        if depth > 16 then
            parts[#parts + 1] = "?"
            return
        end
        local t = type(v)
        if t == "nil" then
            parts[#parts + 1] = "N"
        elseif t == "boolean" then
            parts[#parts + 1] = v and "T" or "F"
        elseif t == "number" then
            parts[#parts + 1] = tostring(v)
        elseif t == "string" then
            parts[#parts + 1] = v
        elseif t == "table" then
            for k, child in pairs(v) do
                parts[#parts + 1] = tostring(k)
                walk(child, depth)
            end
        end
    end
    walk(envelope, 0)
    return #table.concat(parts)
end

local function WireBudget()
    return GS.MAX_WIRE_RECORD_BYTES
        or (GG and GG.MAX_RECORD_CBOR)
        or 2048
end

local function FingerprintBody(body)
    if GS.ContentFingerprint then
        local fp = GS.ContentFingerprint(body)
        if type(fp) == "string" and fp ~= "" then
            return fp
        end
    end
    -- Advisory export version only — never used as approval authority.
    if GG and GG.Hash32 then
        return string.format("%08x", GG.Hash32(tostring(body and body.kind) .. tostring(body and body.id)))
    end
    return "v1"
end

-- Preferred inline threshold; byte-aware paging may pack more keys per page.
local ARCHIVE_PAGE_ITEMS = 12

local function SortedItemIds(requestedItems)
    local ids = {}
    if type(requestedItems) ~= "table" then
        return ids
    end
    for k in pairs(requestedItems) do
        ids[#ids + 1] = k
    end
    table.sort(ids, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return ids
end

--- Emit archive as meta + item pages so each wire body fits MAX_RECORD_CBOR.
-- Eligibility item cutoffs page with requestedItems. Cumulative cutoff keys from
-- item rotation can exceed the live requested-item cap; greedy byte-aware packing
-- preserves every cutoff without silent prune. Fail closed only when a single
-- key cannot fit or the page ceiling is exceeded.
local function BuildArchiveExportBodies(campaignId, archive, record)
    local out = {}
    local items = archive.requestedItems or {}
    local ids = SortedItemIds(items)
    local eligSrc = type(archive.eligibility) == "table" and archive.eligibility or nil
    local eligItems = eligSrc and type(eligSrc.items) == "table" and eligSrc.items or nil
    local eligIds = SortedItemIds(eligItems or {})
    local itemsFp = FingerprintBody(items)
    local budget = WireBudget()
    local exportId = "gs:ca:" .. campaignId
    local datasetId = archive.datasetId or record.datasetId
    local maxPages = GS.MAX_ARCHIVE_PAGE_COUNT or 512
    -- Prefer ARCHIVE_PAGE_ITEMS packing so ordinary archives stay multi-page under
    -- the wire budget; raise only when a single key would not fit that width.
    local packWidth = ARCHIVE_PAGE_ITEMS
    local maxItemsPerPage = GS.MAX_ARCHIVE_PAGE_ITEMS or 64

    local function EligibilityScalars(withItems)
        if not eligSrc then
            return nil
        end
        local eligibility = {
            baselineEstablished = eligSrc.baselineEstablished,
            baselineAt = eligSrc.baselineAt,
            tabEligibleFrom = eligSrc.tabEligibleFrom,
            items = {},
        }
        if withItems and eligItems then
            for k, v in pairs(eligItems) do
                eligibility.items[k] = v
            end
        end
        return eligibility
    end

    local function MetaBody(pageCount, requestedInline, eligibility)
        return {
            kind = "campaign-archive",
            campaignId = campaignId,
            datasetId = datasetId,
            generation = archive.generation,
            archivedAt = archive.archivedAt,
            schemaVersion = archive.schemaVersion or GS.SCHEMA_VERSION,
            itemCount = #ids,
            pageCount = pageCount,
            itemsFingerprint = itemsFp,
            bankTab = tonumber(archive.bankTab),
            eligibilityItemCount = #eligIds,
            eligibility = eligibility,
            requestedItems = requestedInline,
        }
    end

    -- Prefer inline when both maps are small AND the wrapped body fits wire.
    local canInline = (#ids <= ARCHIVE_PAGE_ITEMS and #eligIds <= ARCHIVE_PAGE_ITEMS)
    if canInline then
        local inlineElig = EligibilityScalars(true)
        local inlineBody = MetaBody(1, (#ids > 0) and items or {}, inlineElig)
        if EstimateWireRecordBytes(exportId, inlineBody) <= budget then
            out[#out + 1] = { id = exportId, body = inlineBody }
            return out
        end
    end

    -- Page by the union of requested + eligibility keys so cutoffs never ride
    -- solely on the meta body.
    local keySet, pageKeys = {}, {}
    for i = 1, #ids do
        local k = ids[i]
        if keySet[k] == nil then
            keySet[k] = true
            pageKeys[#pageKeys + 1] = k
        end
    end
    for i = 1, #eligIds do
        local k = eligIds[i]
        if keySet[k] == nil then
            keySet[k] = true
            pageKeys[#pageKeys + 1] = k
        end
    end
    table.sort(pageKeys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    if #pageKeys < 1 then
        local emptyElig = EligibilityScalars(false)
        local emptyBody = MetaBody(1, {}, emptyElig)
        if EstimateWireRecordBytes(exportId, emptyBody) > budget then
            DebugWarn("archive export %s: empty meta exceeds wire budget", tostring(campaignId))
            return {}
        end
        out[#out + 1] = { id = exportId, body = emptyBody }
        return out
    end

    -- Greedy byte-aware packing: fill each page until the next key would exceed
    -- the wire budget or the per-page item bound. Never shrink width when the
    -- page count is high — that only increases pageCount.
    local pageSlices = {}
    local slice, eligSlice = {}, {}
    local sliceCount = 0
    local function flushSlice()
        if sliceCount < 1 then
            return true
        end
        if #pageSlices >= maxPages then
            return false
        end
        pageSlices[#pageSlices + 1] = { items = slice, elig = eligSlice }
        slice, eligSlice, sliceCount = {}, {}, 0
        return true
    end
    for ki = 1, #pageKeys do
        local iid = pageKeys[ki]
        local trialItems, trialElig = {}, {}
        for k, v in pairs(slice) do
            trialItems[k] = v
        end
        for k, v in pairs(eligSlice) do
            trialElig[k] = v
        end
        if items[iid] ~= nil then
            trialItems[iid] = items[iid]
        end
        if eligItems and eligItems[iid] ~= nil then
            trialElig[iid] = eligItems[iid]
        end
        local trialCount = sliceCount + 1
        local trialBody = {
            kind = "campaign-archive-page",
            campaignId = campaignId,
            datasetId = datasetId,
            page = #pageSlices + 1,
            pageCount = 1, -- placeholder; rewritten after packing
            requestedItems = trialItems,
            eligibilityItems = trialElig,
        }
        local trialId = exportId .. ":p" .. tostring(#pageSlices + 1)
        local overBudget = EstimateWireRecordBytes(trialId, trialBody) > budget
        local overItems = trialCount > packWidth or trialCount > maxItemsPerPage
        if sliceCount > 0 and (overBudget or overItems) then
            if not flushSlice() then
                DebugWarn("archive export %s: eligibility/items exceed page ceiling",
                    tostring(campaignId))
                return {}
            end
            trialItems, trialElig, trialCount = {}, {}, 1
            if items[iid] ~= nil then
                trialItems[iid] = items[iid]
            end
            if eligItems and eligItems[iid] ~= nil then
                trialElig[iid] = eligItems[iid]
            end
            trialBody.requestedItems = trialItems
            trialBody.eligibilityItems = trialElig
            trialBody.page = #pageSlices + 1
            trialId = exportId .. ":p" .. tostring(#pageSlices + 1)
            if EstimateWireRecordBytes(trialId, trialBody) > budget then
                DebugWarn("archive export %s: single key exceeds wire budget",
                    tostring(campaignId))
                return {}
            end
        elseif sliceCount < 1 and overBudget then
            DebugWarn("archive export %s: single key exceeds wire budget",
                tostring(campaignId))
            return {}
        end
        slice, eligSlice, sliceCount = trialItems, trialElig, trialCount
    end
    if not flushSlice() then
        DebugWarn("archive export %s: eligibility/items exceed page ceiling",
            tostring(campaignId))
        return {}
    end
    local pageCount = #pageSlices
    if pageCount < 1 or pageCount > maxPages then
        DebugWarn("archive export %s: pageCount=%s exceeds ceiling",
            tostring(campaignId), tostring(pageCount))
        return {}
    end

    local pages = {}
    for page = 1, pageCount do
        local packed = pageSlices[page]
        local pageBody = {
            kind = "campaign-archive-page",
            campaignId = campaignId,
            datasetId = datasetId,
            page = page,
            pageCount = pageCount,
            requestedItems = packed.items,
            eligibilityItems = packed.elig,
        }
        local pageId = exportId .. ":p" .. tostring(page)
        if EstimateWireRecordBytes(pageId, pageBody) > budget then
            DebugWarn("archive export %s: page %s exceeds wire budget",
                tostring(campaignId), tostring(page))
            return {}
        end
        pages[#pages + 1] = { id = pageId, body = pageBody }
    end

    local metaElig = EligibilityScalars(false) -- scalars only; items on pages
    local metaBody = MetaBody(pageCount, nil, metaElig)
    if EstimateWireRecordBytes(exportId, metaBody) > budget then
        DebugWarn("archive export %s: meta exceeds wire budget", tostring(campaignId))
        return {}
    end
    out[#out + 1] = { id = exportId, body = metaBody }
    for i = 1, #pages do
        out[#out + 1] = pages[i]
    end
    return out
end

--- Serialized/estimated byte size of an assembled page row body (no ID wrapper).
local function EstimateBodyBytes(body)
    if type(body) ~= "table" then
        return 0
    end
    if C_EncodingUtil and C_EncodingUtil.SerializeCBOR then
        local ok, raw = pcall(C_EncodingUtil.SerializeCBOR, body)
        if ok and type(raw) == "string" then
            return #raw
        end
    end
    local parts = {}
    local function walk(v, depth)
        depth = (depth or 0) + 1
        if depth > 16 then
            parts[#parts + 1] = "?"
            return
        end
        local t = type(v)
        if t == "nil" then
            parts[#parts + 1] = "N"
        elseif t == "boolean" then
            parts[#parts + 1] = v and "T" or "F"
        elseif t == "number" then
            parts[#parts + 1] = tostring(v)
        elseif t == "string" then
            parts[#parts + 1] = v
        elseif t == "table" then
            for k, child in pairs(v) do
                parts[#parts + 1] = tostring(k)
                walk(child, depth)
            end
        end
    end
    walk(body, 0)
    return #table.concat(parts)
end

--- True when a candidate page (records + optional id lists) fits the wire budget.
local function PageRecordFits(exportId, pageIdx, opId, datasetId, maxPages, records, budget, extras)
    local trialPage = {
        kind = "gs-op-page",
        opId = opId,
        datasetId = datasetId,
        page = pageIdx,
        pageCount = maxPages,
        records = records or {},
    }
    if type(extras) == "table" then
        for k, v in pairs(extras) do
            trialPage[k] = v
        end
    end
    return EstimateWireRecordBytes(exportId .. ":p" .. tostring(pageIdx), trialPage) <= budget
end

--- Build a nested table that sets `value` at `path` (copy-on-write path nodes).
local function TableAtPath(path, value)
    if type(path) ~= "table" or #path < 1 then
        return value
    end
    local root = {}
    local cur = root
    for i = 1, #path - 1 do
        local nxt = {}
        cur[path[i]] = nxt
        cur = nxt
    end
    cur[path[#path]] = value
    return root
end

--- Split one oversized authoritative row body across field-part page records.
-- Splits top-level and nested table fields; chunks oversized scalar strings.
-- Assemble deep-merges field parts and concatenates string chunks in order.
-- Returns page tables or nil when a single supported fragment cannot fit.
local function FragmentOversizedRow(row, exportId, opId, datasetId, budget, maxPages)
    if type(row) ~= "table" or type(row.id) ~= "string" or type(row.body) ~= "table" then
        return nil
    end
    -- Reserve the full manifest pageCount field width so later sibling rows /
    -- id-list pages cannot push these fragments over budget when pageCount grows.
    local reservePages = GS.MAX_MANIFEST_PAGES or 64
    local unitCap = maxPages
    local units = {} -- { fields = table } | { chunk = { path, index, count, data } }

    local function recordFits(fields, chunk)
        local rec = {
            id = row.id,
            part = 1,
            partCount = reservePages,
            fields = fields or {},
        }
        if type(chunk) == "table" then
            rec.chunk = chunk
        end
        return PageRecordFits(exportId, 1, opId, datasetId, reservePages, { rec }, budget)
    end

    local function emitFields(fields)
        if not recordFits(fields, nil) then
            return false
        end
        units[#units + 1] = { fields = fields }
        return true
    end

    local function emitChunks(path, s)
        if type(s) ~= "string" or #s < 1 then
            return emitFields(TableAtPath(path, s))
        end
        -- Binary-search a chunk length that fits with chunk metadata.
        local lo, hi = 1, #s
        local fitLen = nil
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local trial = {
                path = path,
                index = 1,
                count = math.max(1, math.ceil(#s / mid)),
                data = string.sub(s, 1, mid),
            }
            if recordFits({}, trial) then
                fitLen = mid
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
        if not fitLen or fitLen < 1 then
            return false
        end
        local count = math.ceil(#s / fitLen)
        if count > unitCap then
            return false
        end
        for i = 1, count do
            local a = (i - 1) * fitLen + 1
            local b = math.min(#s, i * fitLen)
            units[#units + 1] = {
                chunk = {
                    path = path,
                    index = i,
                    count = count,
                    data = string.sub(s, a, b),
                },
            }
            if not recordFits({}, units[#units].chunk) then
                return false
            end
        end
        return true
    end

    -- Recursively fragment `value` rooted at `path` into fit-sized units.
    local function fragmentAt(path, value)
        local asFields = TableAtPath(path, value)
        if recordFits(asFields, nil) then
            return emitFields(asFields)
        end
        local t = type(value)
        if t == "table" then
            local keys = {}
            for k in pairs(value) do
                keys[#keys + 1] = k
            end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            if #keys < 1 then
                return false
            end
            -- Pack sibling keys into groups that fit; recurse when a key alone fails.
            local cur = {}
            local curCount = 0
            for i = 1, #keys do
                local k = keys[i]
                local trial = {}
                for ck, cv in pairs(cur) do
                    trial[ck] = cv
                end
                trial[k] = value[k]
                if recordFits(TableAtPath(path, trial), nil) then
                    cur = trial
                    curCount = curCount + 1
                else
                    if curCount > 0 then
                        if not emitFields(TableAtPath(path, cur)) then
                            return false
                        end
                        cur = {}
                        curCount = 0
                    end
                    local childPath = {}
                    for pi = 1, #path do
                        childPath[pi] = path[pi]
                    end
                    childPath[#childPath + 1] = k
                    if not fragmentAt(childPath, value[k]) then
                        return false
                    end
                end
            end
            if curCount > 0 then
                return emitFields(TableAtPath(path, cur))
            end
            return true
        elseif t == "string" then
            return emitChunks(path, value)
        end
        -- Atomic non-string scalar that cannot fit alone under the page wrapper.
        return false
    end

    if not fragmentAt({}, row.body) then
        return nil
    end
    if #units < 1 or #units > unitCap then
        return nil
    end
    local partCount = #units
    local pages = {}
    for i = 1, partCount do
        local rec = {
            id = row.id,
            part = i,
            partCount = partCount,
            fields = units[i].fields or {},
        }
        if type(units[i].chunk) == "table" then
            rec.chunk = units[i].chunk
        end
        -- Fit against reserved max pageCount (final manifest may still grow).
        if not PageRecordFits(exportId, i, opId, datasetId, reservePages, { rec }, budget) then
            return nil
        end
        pages[i] = { records = { rec } }
    end
    return pages
end

--- Pack optional identifier lists onto already-built page bodies under budget.
-- Preserves public snapshot fields (originalIds / competingOpIds) that shells strip.
local function AttachIdListToPages(pages, fieldName, ids, exportId, opId, datasetId, budget)
    if type(ids) ~= "table" or #ids < 1 or type(pages) ~= "table" or #pages < 1 then
        return true
    end
    local maxPages = GS.MAX_MANIFEST_PAGES or 64
    local cursor = 1
    local pageIdx = 1
    while cursor <= #ids do
        while pageIdx > #pages do
            if #pages >= maxPages then
                return false
            end
            pages[#pages + 1] = { records = {} }
        end
        local page = pages[pageIdx]
        local existing = page[fieldName] or {}
        local trial = {}
        for j = 1, #existing do
            trial[j] = existing[j]
        end
        trial[#trial + 1] = ids[cursor]
        local trialPage = {
            kind = "gs-op-page",
            opId = opId,
            datasetId = datasetId,
            page = pageIdx,
            -- Reserve wire space for the final pageCount field (not provisional 1).
            pageCount = maxPages,
            records = page.records or {},
        }
        trialPage[fieldName] = trial
        if EstimateWireRecordBytes(exportId .. ":p" .. tostring(pageIdx), trialPage) <= budget then
            page[fieldName] = trial
            cursor = cursor + 1
        else
            -- Advance to a fresh page; a single id must fit alone.
            if #existing > 0 or #(page.records or {}) > 0 then
                pageIdx = pageIdx + 1
            else
                return false
            end
        end
    end
    return true
end

--- Split oversized envelopes into shell + pages under wire budget.
-- Pages carry authoritative bodies, identifier membership, and stripped public
-- lists (originalIds / competingOpIds). Ordinary oversized ops page only the
-- mutable payload (value/target); the shell keeps identity/causality. Returns a
-- complete fragment set where every ID/versionFp wrapper fits, or {} only when a
-- single supported fragment cannot fit the transport budget alone.
local function BuildOpExportBodies(op, evidenceOnly, boundary)
    local fullBody = {
        kind = "gs-op",
        op = op,
        evidenceOnly = evidenceOnly and true or nil,
        boundary = boundary,
    }
    local exportId = "gs:op:" .. op.id
    local budget = WireBudget()
    if EstimateWireRecordBytes(exportId, fullBody) <= budget then
        return { { id = exportId, body = fullBody } }
    end

    local rows = {}
    local originalIds = nil
    local competingOpIds = nil
    if op.kind == GS.KIND.CONFIRM_CANDIDATE then
        local ref = op.candidateRef
        if type(ref) == "table" then
            if type(ref.originalIds) == "table" then
                originalIds = ref.originalIds
            end
            if type(ref.body) == "table" and type(ref.recordId) == "string" then
                rows[#rows + 1] = { id = ref.recordId, body = ref.body }
            end
            if type(ref.records) == "table" then
                for i = 1, #ref.records do
                    local row = ref.records[i]
                    if type(row) == "table" and type(row.id) == "string" and type(row.body) == "table" then
                        rows[#rows + 1] = { id = row.id, body = row.body }
                    end
                end
            end
        end
    elseif op.kind == GS.KIND.RESOLVE_CONFLICT then
        local bodies = op.value and op.value.contentBodies
        if type(op.value) == "table" and type(op.value.competingOpIds) == "table" then
            competingOpIds = op.value.competingOpIds
        end
        if type(bodies) == "table" then
            local ids = {}
            if type(competingOpIds) == "table" and #competingOpIds > 0 then
                for i = 1, #competingOpIds do
                    local id = competingOpIds[i]
                    if type(id) == "string" and type(bodies[id]) == "table" then
                        ids[#ids + 1] = id
                    end
                end
            end
            if #ids < 1 then
                for id in pairs(bodies) do
                    ids[#ids + 1] = id
                end
                table.sort(ids)
            end
            for i = 1, #ids do
                rows[#rows + 1] = { id = ids[i], body = bodies[ids[i]] }
            end
        end
    else
        -- Ordinary oversized op: page a snapshot of the full authoritative body
        -- via field parts. Max-length allocated ids make a value/target-stripped
        -- shell exceed the wire budget alone; AssembleOpFromPages accepts a
        -- complete page body (schemaVersion+actorGuid) as the reconstructed op.
        local snapBody = op
        if GS._SnapshotPublicOp then
            local stored = select(1, GS._SnapshotPublicOp(op))
            if type(stored) == "table" then
                snapBody = stored
            end
        end
        rows[1] = {
            id = op.id,
            body = snapBody,
        }
    end
    if #rows < 1 then
        if EstimateWireRecordBytes(exportId, fullBody) <= budget then
            return { { id = exportId, body = fullBody } }
        end
        DebugWarn("op export %s: no pageable rows under wire budget", tostring(op.id))
        return {}
    end

    local maxPages = GS.MAX_MANIFEST_PAGES or 64
    local pages = {}
    local cur = { records = {} }
    local function flush()
        if #(cur.records) > 0 then
            pages[#pages + 1] = cur
            cur = { records = {} }
        end
    end
    for i = 1, #rows do
        local trialRecords = {}
        for j = 1, #(cur.records) do
            trialRecords[j] = cur.records[j]
        end
        trialRecords[#trialRecords + 1] = rows[i]
        if PageRecordFits(
            exportId, #pages + 1, op.id, op.datasetId, maxPages, trialRecords, budget
        ) then
            cur.records[#cur.records + 1] = rows[i]
        else
            flush()
            if #pages >= maxPages then
                DebugWarn("op export %s: exceeds max manifest pages", tostring(op.id))
                return {}
            end
            -- Single complete row may still exceed budget: fragment body fields.
            if PageRecordFits(
                exportId, #pages + 1, op.id, op.datasetId, maxPages, { rows[i] }, budget
            ) then
                cur.records[1] = rows[i]
            else
                local fragPages = FragmentOversizedRow(
                    rows[i], exportId, op.id, op.datasetId, budget, maxPages - #pages)
                if not fragPages or #fragPages < 1 then
                    DebugWarn("op export %s: row exceeds wire budget alone", tostring(op.id))
                    return {}
                end
                if #pages + #fragPages > maxPages then
                    DebugWarn("op export %s: fragmented row exceeds max pages", tostring(op.id))
                    return {}
                end
                for fi = 1, #fragPages do
                    pages[#pages + 1] = fragPages[fi]
                end
            end
        end
    end
    if #(cur.records) > 0 and #pages >= maxPages then
        DebugWarn("op export %s: exceeds max manifest pages", tostring(op.id))
        return {}
    end
    flush()
    if #pages < 1 or #pages > maxPages then
        return {}
    end

    if originalIds and not AttachIdListToPages(
        pages, "originalIds", originalIds, exportId, op.id, op.datasetId, budget) then
        DebugWarn("op export %s: originalIds exceed page budget", tostring(op.id))
        return {}
    end
    if competingOpIds and not AttachIdListToPages(
        pages, "competingOpIds", competingOpIds, exportId, op.id, op.datasetId, budget) then
        DebugWarn("op export %s: competingOpIds exceed page budget", tostring(op.id))
        return {}
    end
    if #pages > maxPages then
        return {}
    end

    -- Probe whether the shell can carry the campaign boundary. Max-id headers
    -- often cannot; park the boundary on a page (or a fresh empty page).
    local shellBoundary = boundary
    if type(boundary) == "table" then
        local probeOp = {
            schemaVersion = op.schemaVersion,
            id = op.id,
            guildKey = op.guildKey,
            datasetId = op.datasetId,
            kind = op.kind,
            pageCount = #pages,
            recordCount = #rows,
        }
        if op.kind == GS.KIND.CONFIRM_CANDIDATE or op.kind == GS.KIND.RESOLVE_CONFLICT then
            probeOp = nil -- confirm/resolve keep their richer shells below
        end
        if probeOp then
            local probeShell = {
                kind = "gs-op",
                op = probeOp,
                pageCount = #pages,
                recordCount = #rows,
                evidenceOnly = evidenceOnly and true or nil,
                boundary = boundary,
            }
            if EstimateWireRecordBytes(exportId, probeShell) > budget then
                shellBoundary = nil
                local placed = false
                for p = 1, #pages do
                    if PageRecordFits(
                        exportId, p, op.id, op.datasetId, maxPages,
                        pages[p].records or {}, budget, { boundary = boundary }
                    ) then
                        pages[p].boundary = boundary
                        placed = true
                        break
                    end
                end
                if not placed then
                    if #pages < maxPages and PageRecordFits(
                        exportId, #pages + 1, op.id, op.datasetId, maxPages,
                        {}, budget, { boundary = boundary }
                    ) then
                        pages[#pages + 1] = { records = {}, boundary = boundary }
                        placed = true
                    else
                        -- Boundary alone exceeds the wire budget (max-id headers).
                        -- Export the start-campaign op without an embedded boundary;
                        -- receivers resolve it from the companion campaign-header.
                        DebugWarn(
                            "op export %s: omitting oversized boundary; use campaign-header",
                            tostring(op.id))
                    end
                end
            end
        end
    end

    local pageCount = #pages

    local shellOp = {}
    for k, v in pairs(op) do
        shellOp[k] = v
    end
    if op.kind == GS.KIND.CONFIRM_CANDIDATE and type(op.candidateRef) == "table" then
        local ref = op.candidateRef
        shellOp.candidateRef = {
            recordId = ref.recordId,
            campaignId = ref.campaignId,
        }
    elseif op.kind == GS.KIND.RESOLVE_CONFLICT and type(op.value) == "table" then
        shellOp.value = {
            chosenOpId = op.value.chosenOpId,
        }
    else
        -- Minimal ordinary shell: pages carry the full body (field parts).
        shellOp = {
            schemaVersion = op.schemaVersion,
            id = op.id,
            guildKey = op.guildKey,
            datasetId = op.datasetId,
            kind = op.kind,
        }
    end
    shellOp.pageCount = pageCount
    shellOp.recordCount = #rows

    local shellBody = {
        kind = "gs-op",
        op = shellOp,
        pageCount = pageCount,
        recordCount = #rows,
        evidenceOnly = evidenceOnly and true or nil,
        boundary = shellBoundary,
    }
    if EstimateWireRecordBytes(exportId, shellBody) > budget then
        DebugWarn("op export %s: compact shell still exceeds wire budget", tostring(op.id))
        return {}
    end

    local out = {
        {
            id = exportId,
            body = shellBody,
        },
    }
    for p = 1, pageCount do
        local pageBody = {
            kind = "gs-op-page",
            opId = op.id,
            datasetId = op.datasetId,
            page = p,
            pageCount = pageCount,
            records = pages[p].records,
        }
        if type(pages[p].originalIds) == "table" then
            pageBody.originalIds = pages[p].originalIds
        end
        if type(pages[p].competingOpIds) == "table" then
            pageBody.competingOpIds = pages[p].competingOpIds
        end
        if type(pages[p].boundary) == "table" then
            pageBody.boundary = pages[p].boundary
        end
        local pageId = exportId .. ":p" .. tostring(p)
        if EstimateWireRecordBytes(pageId, pageBody) > budget then
            return {}
        end
        out[#out + 1] = {
            id = pageId,
            body = pageBody,
        }
    end
    return out
end

local function AssembleOpFromPages(shellBody, pagesByIndex)
    if type(shellBody) ~= "table" or type(shellBody.op) ~= "table" then
        return nil, "invalid_operation"
    end
    local pageCount = tonumber(shellBody.pageCount) or tonumber(shellBody.op.pageCount)
    if not pageCount then
        -- Inline (non-paged) body.
        return shellBody, nil
    end
    local maxPages = GS.MAX_MANIFEST_PAGES or 64
    if pageCount ~= math.floor(pageCount) or pageCount < 1 or pageCount > maxPages then
        return nil, "invalid_operation"
    end
    local declaredCount = tonumber(shellBody.recordCount) or tonumber(shellBody.op.recordCount)
    if declaredCount ~= nil then
        if declaredCount ~= math.floor(declaredCount) or declaredCount < 1 then
            return nil, "invalid_operation"
        end
    end
    -- Logical rows in first-seen order. Complete bodies land immediately; field-part
    -- fragments accumulate until all parts arrive, then merge in place.
    local rows = {}
    local rowIndexById = {}
    local seenComplete = {}
    local partAccum = {} -- id → { partCount, parts, chunks, rowSlot }
    local pageOriginalIds = {}
    local pageCompetingOpIds = {}
    local pageBoundary = nil
    local totalBytes = 0
    local maxBytes = GS.MAX_FRAGMENT_ASSEMBLY_BYTES or 49152

    local function deepMergeFields(dst, src)
        for k, v in pairs(src) do
            if type(v) == "table" and type(dst[k]) == "table" then
                if not deepMergeFields(dst[k], v) then
                    return false
                end
            elseif dst[k] ~= nil then
                return false
            else
                dst[k] = v
            end
        end
        return true
    end

    local function pathKey(path)
        if type(path) ~= "table" then
            return nil
        end
        local parts = {}
        for i = 1, #path do
            parts[i] = tostring(path[i])
        end
        return table.concat(parts, "\0")
    end

    local function assignPath(dst, path, value)
        if type(path) ~= "table" or #path < 1 then
            return false
        end
        local cur = dst
        for i = 1, #path - 1 do
            local p = path[i]
            if cur[p] == nil then
                cur[p] = {}
            elseif type(cur[p]) ~= "table" then
                return false
            end
            cur = cur[p]
        end
        local leaf = path[#path]
        if cur[leaf] ~= nil then
            return false
        end
        cur[leaf] = value
        return true
    end

    for page = 1, pageCount do
        local p = pagesByIndex and pagesByIndex[page]
        if type(p) ~= "table" or type(p.records) ~= "table" then
            return nil, "incomplete_manifest_pages"
        end
        local declaredPageCount = tonumber(p.pageCount)
        if declaredPageCount and declaredPageCount ~= pageCount then
            return nil, "invalid_operation"
        end
        if type(p.opId) == "string" and type(shellBody.op.id) == "string"
            and p.opId ~= shellBody.op.id then
            return nil, "invalid_operation"
        end
        if type(p.datasetId) == "string" and type(shellBody.op.datasetId) == "string"
            and p.datasetId ~= shellBody.op.datasetId then
            return nil, "dataset_mismatch"
        end
        if type(p.boundary) == "table" then
            if pageBoundary ~= nil then
                if GS._DeepEqualOps and not GS._DeepEqualOps(pageBoundary, p.boundary) then
                    return nil, "invalid_operation"
                end
            end
            pageBoundary = p.boundary
        end
        if type(p.originalIds) == "table" then
            for i = 1, #p.originalIds do
                local oid = p.originalIds[i]
                if type(oid) == "string" then
                    pageOriginalIds[#pageOriginalIds + 1] = oid
                    totalBytes = totalBytes + #oid
                    if totalBytes > maxBytes then
                        return nil, "invalid_operation"
                    end
                end
            end
        end
        if type(p.competingOpIds) == "table" then
            for i = 1, #p.competingOpIds do
                local cid = p.competingOpIds[i]
                if type(cid) == "string" then
                    pageCompetingOpIds[#pageCompetingOpIds + 1] = cid
                    totalBytes = totalBytes + #cid
                    if totalBytes > maxBytes then
                        return nil, "invalid_operation"
                    end
                end
            end
        end
        for i = 1, #p.records do
            local row = p.records[i]
            if type(row) ~= "table" or type(row.id) ~= "string" or row.id == "" then
                return nil, "invalid_operation"
            end
            local part = tonumber(row.part)
            local partCount = tonumber(row.partCount)
            if part and partCount then
                if part ~= math.floor(part) or partCount ~= math.floor(partCount)
                    or part < 1 or partCount < 1 or part > partCount
                    or type(row.fields) ~= "table" then
                    return nil, "invalid_operation"
                end
                if seenComplete[row.id] then
                    return nil, "invalid_operation"
                end
                local acc = partAccum[row.id]
                if not acc then
                    rows[#rows + 1] = { id = row.id, body = nil, _partsPending = true }
                    rowIndexById[row.id] = #rows
                    acc = { partCount = partCount, parts = {}, chunks = {}, rowSlot = #rows }
                    partAccum[row.id] = acc
                elseif acc.partCount ~= partCount then
                    return nil, "invalid_operation"
                end
                if acc.parts[part] ~= nil then
                    return nil, "invalid_operation"
                end
                acc.parts[part] = {
                    fields = row.fields,
                    chunk = row.chunk,
                }
                totalBytes = totalBytes + #row.id + EstimateBodyBytes(row.fields)
                if type(row.chunk) == "table" and type(row.chunk.data) == "string" then
                    totalBytes = totalBytes + #row.chunk.data
                end
                if totalBytes > maxBytes then
                    return nil, "invalid_operation"
                end
            else
                if type(row.body) ~= "table" then
                    return nil, "invalid_operation"
                end
                if seenComplete[row.id] or partAccum[row.id] then
                    return nil, "invalid_operation"
                end
                seenComplete[row.id] = true
                rows[#rows + 1] = row
                rowIndexById[row.id] = #rows
                totalBytes = totalBytes + #row.id + EstimateBodyBytes(row.body)
                if totalBytes > maxBytes then
                    return nil, "invalid_operation"
                end
            end
        end
    end
    for id, acc in pairs(partAccum) do
        local merged = {}
        local chunkGroups = {}
        for part = 1, acc.partCount do
            local entry = acc.parts[part]
            if type(entry) ~= "table" or type(entry.fields) ~= "table" then
                return nil, "incomplete_manifest_pages"
            end
            if not deepMergeFields(merged, entry.fields) then
                return nil, "invalid_operation"
            end
            local ch = entry.chunk
            if type(ch) == "table" then
                if type(ch.path) ~= "table" or type(ch.data) ~= "string"
                    or type(ch.index) ~= "number" or type(ch.count) ~= "number" then
                    return nil, "invalid_operation"
                end
                local pk = pathKey(ch.path)
                if not pk then
                    return nil, "invalid_operation"
                end
                local grp = chunkGroups[pk]
                if not grp then
                    grp = { path = ch.path, count = ch.count, parts = {} }
                    chunkGroups[pk] = grp
                elseif grp.count ~= ch.count then
                    return nil, "invalid_operation"
                end
                if grp.parts[ch.index] ~= nil then
                    return nil, "invalid_operation"
                end
                grp.parts[ch.index] = ch.data
            end
        end
        for _, grp in pairs(chunkGroups) do
            local pieces = {}
            for ci = 1, grp.count do
                if type(grp.parts[ci]) ~= "string" then
                    return nil, "incomplete_manifest_pages"
                end
                pieces[ci] = grp.parts[ci]
            end
            if not assignPath(merged, grp.path, table.concat(pieces)) then
                return nil, "invalid_operation"
            end
        end
        local slot = acc.rowSlot
        rows[slot] = { id = id, body = merged }
        seenComplete[id] = true
    end
    if declaredCount ~= nil and #rows ~= declaredCount then
        return nil, "incomplete_manifest_pages"
    end
    if #rows < 1 then
        return nil, "incomplete_manifest_pages"
    end
    -- When the shell still lists expected ids, require exact membership.
    local expectedIds = nil
    if shellBody.op.kind == GS.KIND.CONFIRM_CANDIDATE
        and type(shellBody.op.candidateRef) == "table"
        and type(shellBody.op.candidateRef.records) == "table"
        and #shellBody.op.candidateRef.records > 0 then
        expectedIds = {}
        for i = 1, #shellBody.op.candidateRef.records do
            local row = shellBody.op.candidateRef.records[i]
            if type(row) == "table" and type(row.id) == "string" then
                expectedIds[#expectedIds + 1] = row.id
            end
        end
    elseif shellBody.op.kind == GS.KIND.RESOLVE_CONFLICT
        and type(shellBody.op.value) == "table"
        and type(shellBody.op.value.competingOpIds) == "table"
        and #shellBody.op.value.competingOpIds > 0 then
        expectedIds = {}
        for i = 1, #shellBody.op.value.competingOpIds do
            local id = shellBody.op.value.competingOpIds[i]
            if type(id) == "string" then
                expectedIds[#expectedIds + 1] = id
            end
        end
    end
    if expectedIds and #expectedIds > 0 then
        if #expectedIds ~= #rows then
            return nil, "incomplete_manifest_pages"
        end
        local want = {}
        for i = 1, #expectedIds do
            want[expectedIds[i]] = true
        end
        for i = 1, #rows do
            if not want[rows[i].id] then
                return nil, "invalid_operation"
            end
        end
    end
    local op = {}
    for k, v in pairs(shellBody.op) do
        op[k] = v
    end
    op.pageCount = nil
    op.recordCount = nil
    if op.kind == GS.KIND.CONFIRM_CANDIDATE then
        local ref = op.candidateRef or {}
        local originalIds = ref.originalIds
        if type(originalIds) ~= "table" or #originalIds < 1 then
            if #pageOriginalIds > 0 then
                originalIds = pageOriginalIds
            end
        end
        if #rows == 1 and type(ref.recordId) == "string" then
            op.candidateRef = {
                recordId = ref.recordId or rows[1].id,
                body = rows[1].body,
                originalIds = originalIds,
                campaignId = ref.campaignId,
            }
        else
            local recs = {}
            for i = 1, #rows do
                recs[i] = { id = rows[i].id, body = rows[i].body }
            end
            op.candidateRef = {
                records = recs,
                originalIds = originalIds,
                campaignId = ref.campaignId,
            }
        end
    elseif op.kind == GS.KIND.RESOLVE_CONFLICT then
        local contentBodies = {}
        local competingOpIds = {}
        for i = 1, #rows do
            contentBodies[rows[i].id] = rows[i].body
            competingOpIds[i] = rows[i].id
        end
        local value = op.value or {}
        -- Prefer page-carried order, then shell, then page row membership.
        if #pageCompetingOpIds > 0 then
            competingOpIds = pageCompetingOpIds
        elseif type(value.competingOpIds) == "table" and #value.competingOpIds > 0 then
            competingOpIds = value.competingOpIds
        end
        op.value = {
            chosenOpId = value.chosenOpId,
            competingOpIds = competingOpIds,
            contentBodies = contentBodies,
        }
    else
        -- Ordinary paged op: merge payload into shell identity, or accept a
        -- complete body when the page still carries one (compat).
        if #rows ~= 1 or type(rows[1].body) ~= "table" then
            return nil, "invalid_operation"
        end
        local payload = rows[1].body
        if type(payload.schemaVersion) == "number" and type(payload.actorGuid) == "string" then
            op = {}
            for k, v in pairs(payload) do
                op[k] = v
            end
        else
            if payload.value ~= nil then
                op.value = payload.value
            end
            if payload.target ~= nil then
                op.target = payload.target
            end
        end
    end
    local boundary = shellBody.boundary
    if type(boundary) ~= "table" and type(pageBoundary) == "table" then
        boundary = pageBoundary
    end
    return {
        kind = "gs-op",
        op = op,
        evidenceOnly = shellBody.evidenceOnly,
        boundary = boundary,
    }, nil
end

GS.AssembleOpFromPages = AssembleOpFromPages

local function CurrentGuildRecord()
    if not GS:IsRootReady() then
        return nil
    end
    local ctx = GS:GetCurrentContext()
    if not ctx or not ctx.guildKey then
        return nil
    end
    local raw = GS._root and GS._root.guilds and GS._root.guilds[ctx.guildKey]
    if type(raw) ~= "table"
        or not (GS.IsSupportedActivation and GS.IsSupportedActivation(raw.activation)) then
        return nil
    end
    return raw, ctx.guildKey
end

--- Cheap export-scope check: club identity + demand-roster bind + dataset/epoch.
-- Avoids GetCurrentContext / native roster scans on the per-record hot path.
-- Fails closed when demand-roster trust is unbound or guild identity changed.
local function ExportScopeStillValid()
    if not exportState.guildKey or not exportState.datasetId then
        return false
    end
    if exportState.dirtyRebuild then
        return false
    end
    local epoch = tonumber(GS._adoptionEpoch) or 0
    if exportState.epoch ~= epoch then
        return false
    end
    if not GS:IsRootReady() then
        return false
    end
    local GGAPI = GG or SF.GuildGossip
    if not GGAPI or type(GGAPI.GetGuildIdentity) ~= "function" then
        return false
    end
    local identity = select(1, GGAPI.GetGuildIdentity())
    if type(identity) ~= "table" or identity.guildKey ~= exportState.guildKey then
        return false
    end
    local clubId = identity.clubId and tostring(identity.clubId) or nil
    local dr = GGAPI._demandRoster
    if type(dr) ~= "table" or type(clubId) ~= "string" or dr.boundClubId ~= clubId then
        return false
    end
    local raw = GS._root and GS._root.guilds and GS._root.guilds[exportState.guildKey]
    if type(raw) ~= "table" or raw.datasetId ~= exportState.datasetId then
        return false
    end
    if not (GS.IsSupportedActivation and GS.IsSupportedActivation(raw.activation)) then
        return false
    end
    return true, raw
end

--- Authenticated local character only. Account-wide directExports must not vote
-- as an alt after character switch.
local function LocalExportWitnessGuid()
    if GS.GetLocalPlayerGuid then
        return GS.GetLocalPlayerGuid()
    end
    if UnitGUID then
        local guid = UnitGUID("player")
        if type(guid) == "string" and guid ~= "" then
            return guid
        end
    end
    return nil
end

local function DirectExportOwnedByLocal(row, localGuid)
    if type(row) ~= "table" or type(localGuid) ~= "string" then
        return false
    end
    return row.witnessGuid == localGuid
end

-- Forward-declared: cold registration and Notify both schedule archive drain.
local ScheduleExportMaintContinuation

--- Replace the advertised valuation set from the winner map. One pass, used by
-- cold rebuild and an already-running durable notification. Not used per price.
local function TakeValuationManifest(byTxn)
    local manifest = {}
    local count = 0
    if type(byTxn) == "table" then
        for txnId in pairs(byTxn) do
            if type(txnId) == "string" and txnId ~= "" then
                manifest[txnId] = true
                count = count + 1
            end
        end
    end
    exportState.valuationManifest = manifest
    exportState.cachedValuationCount = count
    return count
end

local function StampValuationManifest(record)
    local store = type(record) == "table" and record.valuations or nil
    exportState.valuationManifestStore = store
    exportState.valuationManifestDataset = type(record) == "table" and record.datasetId or nil
    local rev = 0
    if type(store) == "table" and GS.ValuationStoreRevision then
        rev = GS.ValuationStoreRevision(store)
    end
    exportState.valuationManifestRev = rev
end

local function ValuationManifestIsCurrent(record)
    if type(exportState.valuationManifest) ~= "table" or type(record) ~= "table" then
        return false
    end
    if exportState.valuationManifestDataset ~= record.datasetId then
        return false
    end
    local store = record.valuations
    if exportState.valuationManifestStore ~= store then
        return false
    end
    local rev = 0
    if type(store) == "table" and GS.ValuationStoreRevision then
        rev = GS.ValuationStoreRevision(store)
    end
    return exportState.valuationManifestRev == rev
end

--- Full winner-map rebuild only when the tracked manifest is stale.
-- GS._onValuationManifestRebuild is nil in production; tests count real rebuilds.
local function ResolveValuationExportCount(record)
    if ValuationManifestIsCurrent(record) then
        return tonumber(exportState.cachedValuationCount) or 0
    end
    local byTxn = record and record.valuations and record.valuations.byTxn
    local count = TakeValuationManifest(byTxn)
    StampValuationManifest(record)
    if type(GS._onValuationManifestRebuild) == "function" then
        GS._onValuationManifestRebuild(record)
    end
    return count
end

local function StampCurrentValuationManifest()
    if type(exportState.valuationManifest) ~= "table" then
        return
    end
    local record = select(1, CurrentGuildRecord())
    if type(record) ~= "table" or record.datasetId ~= exportState.datasetId then
        return
    end
    StampValuationManifest(record)
end

--- Patch the already-exported dataset descriptor. O(1); does not rebuild.
local function PublishValuationManifest()
    local count = tonumber(exportState.cachedValuationCount) or 0
    if count < 0 then
        count = 0
        exportState.cachedValuationCount = 0
    end
    local datasetId = exportState.datasetId
    if type(datasetId) ~= "string" or datasetId == "" then
        return
    end
    local entry = exportState.byId["gs:desc:" .. datasetId]
    if type(entry) ~= "table" or type(entry.body) ~= "table" then
        return
    end
    if entry.body.valuationCount == count and entry.needsFp ~= true
        and type(entry.versionFp) == "string" then
        return
    end
    entry.body.valuationCount = count
    entry.needsFp = true
    entry.versionFp = nil
end

local function NoteValuationManifestId(txnId)
    if type(txnId) ~= "string" or txnId == "" then
        return
    end
    local manifest = exportState.valuationManifest
    if type(manifest) ~= "table" then
        manifest = {}
        exportState.valuationManifest = manifest
    end
    if manifest[txnId] then
        StampCurrentValuationManifest()
        return
    end
    manifest[txnId] = true
    exportState.cachedValuationCount = (tonumber(exportState.cachedValuationCount) or 0) + 1
    PublishValuationManifest()
    StampCurrentValuationManifest()
end

local function DropValuationManifestId(txnId)
    local manifest = exportState.valuationManifest
    if type(manifest) ~= "table" or type(txnId) ~= "string" or txnId == ""
        or not manifest[txnId] then
        return false
    end
    manifest[txnId] = nil
    local count = (tonumber(exportState.cachedValuationCount) or 1) - 1
    if count < 0 then
        count = 0
    end
    exportState.cachedValuationCount = count
    StampCurrentValuationManifest()
    return true
end

local function RebuildExportIndex()
    exportState.order = {}
    exportState.byId = {}
    exportState.enumPos = nil
    exportState.appendPos = 0
    exportState.resolveScanPos = 0
    exportState.maintIdle = true
    exportState.countsDirty = true
    exportState.cachedOpCount = 0
    exportState.cachedCampaignCount = 0
    exportState.cachedArchiveCount = 0
    local record, guildKey = CurrentGuildRecord()
    if not record then
        exportState.guildKey = nil
        exportState.datasetId = nil
        exportState.localGuid = nil
        return
    end
    exportState.localGuid = LocalExportWitnessGuid()
    -- Never index/export raw invalid SavedVariables guild records.
    if GS._ValidateGuildRecordStructure then
        local ok = GS._ValidateGuildRecordStructure(guildKey, record)
        if not ok then
            exportState.guildKey = nil
            exportState.datasetId = nil
            return
        end
    end
    exportState.guildKey = guildKey
    exportState.datasetId = record.datasetId
    exportState.epoch = tonumber(GS._adoptionEpoch) or 0

    -- Structural add without fingerprinting; EnsureIndex budgets versionFp work.
    local function add(id, body)
        if type(id) ~= "string" or id == "" or exportState.byId[id] then
            return
        end
        exportState.byId[id] = {
            id = id,
            versionFp = nil, -- filled lazily under EnsureIndex budget
            body = body,
            needsFp = true,
        }
        exportState.order[#exportState.order + 1] = id
    end

    -- Compact dataset descriptor (also used for adoption assembly).
    -- Counts filled after export enumeration so conflict deps are included.
    local desc = {
        kind = "dataset-desc",
        schemaVersion = GS.PROVIDER_SCHEMA,
        guildKey = guildKey,
        datasetId = record.datasetId,
        editorRankPosition = record.permission and record.permission.editorRankPosition or nil,
        permissionRevisionId = record.permission and record.permission.revisionId or nil,
        bootstrapEditorRankPosition = (record.permission
            and record.permission.bootstrapEditorRankPosition)
            or (record.permission and record.permission.editorRankPosition)
            or nil,
        currentCampaignId = record.currentCampaignId,
        activation = record.activation,
        cutoverMarker = record.liveCutover and record.liveCutover.cutoverMarker or nil,
        liveCutover = GS.DescribeLiveCutover and GS.DescribeLiveCutover(record.liveCutover) or nil,
        acceptedOpCount = 0,
        transferOpCount = 0,
        campaignCount = 0,
        archiveCount = 0,
        -- #388: immutable accounting manifest for adoption completeness.
        acceptedLedgerCount = 0,
        donationEvidenceCount = 0,
        valuationCount = 0,
        -- Pin effective config head for adoption binding (nil is meaningful).
        bankTab = record.accounting and record.accounting._consumables
            and record.accounting._consumables.bankTab or nil,
        hasBankTab = true,
    }
    add("gs:desc:" .. record.datasetId, desc)

    local ops = record.operations

    -- Campaign headers (immutable originals for late joiners / partial catch-up).
    -- Headers are small; accepted ops / evidence / archives are paced in maint so
    -- cold RebuildExportIndex does not synchronously serialize the full history.
    local headerExportCount = 0
    if type(record.campaigns) == "table" then
        for campaignId, header in pairs(record.campaigns) do
            if type(header) == "table" and type(campaignId) == "string" then
                add("gs:ch:" .. campaignId, {
                    kind = "campaign-header",
                    header = header,
                })
                headerExportCount = headerExportCount + 1
            end
        end
    end

    -- Logical accepted count from durable order — never shrink when an individual
    -- export body is temporarily unpaged. Emitting from byId alone would advertise
    -- an incomplete source as complete when BuildOpExportBodies returns {}.
    local acceptedOpCount = 0
    if type(ops) == "table" and type(ops.order) == "table" then
        acceptedOpCount = #ops.order
    end
    local evidenceExportCount = 0
    if type(ops) == "table" then
        if type(ops.pending) == "table" then
            for id in pairs(ops.pending) do
                -- Accepted bodies are already in acceptedOpCount / accepted export.
                if not (ops.records and ops.records[id]) then
                    evidenceExportCount = evidenceExportCount + 1
                end
            end
        end
        if type(ops.conflicts) == "table" then
            for id in pairs(ops.conflicts) do
                if not (ops.pending and ops.pending[id])
                    and not (ops.records and ops.records[id]) then
                    evidenceExportCount = evidenceExportCount + 1
                end
            end
        end
    end
    local transferOpCount = acceptedOpCount + evidenceExportCount

    -- Archives are constructed under export maintenance budget (not cold-path).
    local archiveExportCount = 0
    if type(record.campaignArchives) == "table" then
        for campaignId, archive in pairs(record.campaignArchives) do
            if type(archive) == "table" and type(campaignId) == "string" then
                archiveExportCount = archiveExportCount + 1
            end
        end
    end
    exportState.archiveBuildNeeded = archiveExportCount > 0
    exportState.archiveBuildCursor = nil
    exportState.opBuildNeeded = acceptedOpCount > 0
    exportState.opBuildCursor = 1
    exportState.evidenceBuildNeeded = evidenceExportCount > 0
    exportState.pendingCursor = nil
    exportState.conflictCursor = nil
    exportState.openConflictCursor = nil
    exportState.openConflictPartialKey = nil
    exportState.openConflictCandidatePos = nil
    exportState.resolveScanPos = 0

    -- #388: pace cold export of accepted ledger events and direct observations.
    -- Relayed evidence is never stored in directExports, so re-export cannot
    -- impersonate the original witness under a different authenticated sender.
    local ledgerExportCount = 0
    if GS.CountAcceptedLedgerEvents then
        ledgerExportCount = GS.CountAcceptedLedgerEvents(record)
    else
        local events = record.accounting and record.accounting._consumableEvents
        local archive = record.accounting and record.accounting._consumableEventArchive
        if type(events) == "table" then
            ledgerExportCount = ledgerExportCount + #events
        end
        if type(archive) == "table" then
            ledgerExportCount = ledgerExportCount + #archive
        end
    end
    local donationEvidenceExportCount = 0
    local localGuid = exportState.localGuid or LocalExportWitnessGuid()
    local directExports = record.observations and record.observations.directExports
    if type(directExports) == "table" then
        for _, row in pairs(directExports) do
            if DirectExportOwnedByLocal(row, localGuid) then
                donationEvidenceExportCount = donationEvidenceExportCount + 1
            end
        end
    end
    exportState.ledgerBuildNeeded = ledgerExportCount > 0
    exportState.ledgerBuildCursor = nil
    exportState.ledgerBuildPhase = "archive"
    local liveEvents = record.accounting and record.accounting._consumableEvents
    exportState.ledgerWarmPos = type(liveEvents) == "table" and #liveEvents or 0
    -- Cold rebuild re-drains archive from the start; warm watermark advances as
    -- the paced archive phase completes (see NotifyLocalDurableChange).
    exportState.ledgerArchiveWarmPos = 0
    exportState.donationEvidenceBuildNeeded = donationEvidenceExportCount > 0
    exportState.donationEvidenceBuildCursor = nil
    local valuationExportCount = ResolveValuationExportCount(record)
    exportState.valuationBuildNeeded = valuationExportCount > 0
    exportState.valuationBuildCursor = nil

    local descId = "gs:desc:" .. record.datasetId
    local descEntry = exportState.byId[descId]
    if type(descEntry) == "table" and type(descEntry.body) == "table" then
        descEntry.body.acceptedOpCount = acceptedOpCount
        descEntry.body.transferOpCount = transferOpCount
        descEntry.body.campaignCount = headerExportCount
        descEntry.body.archiveCount = archiveExportCount
        descEntry.body.acceptedLedgerCount = ledgerExportCount
        descEntry.body.donationEvidenceCount = donationEvidenceExportCount
        descEntry.body.valuationCount = valuationExportCount
        descEntry.body.bankTab = record.accounting and record.accounting._consumables
            and record.accounting._consumables.bankTab or nil
        descEntry.body.hasBankTab = true
        descEntry.needsFp = true
        descEntry.versionFp = nil
    end
    exportState.cachedOpCount = acceptedOpCount
    exportState.cachedTransferOpCount = transferOpCount
    exportState.cachedCampaignCount = headerExportCount
    exportState.cachedArchiveCount = archiveExportCount
    exportState.cachedAcceptedLedgerCount = ledgerExportCount
    exportState.cachedDonationEvidenceCount = donationEvidenceExportCount
    exportState.cachedValuationCount = valuationExportCount
    exportState.countsDirty = false
    exportState.appendPos = 0
    local needsMaint = exportState.archiveBuildNeeded
        or exportState.opBuildNeeded
        or exportState.evidenceBuildNeeded
        or exportState.ledgerBuildNeeded
        or exportState.donationEvidenceBuildNeeded
        or exportState.valuationBuildNeeded
    exportState.maintIdle = not needsMaint
    exportState.maintScheduled = false
    -- Cold registration /reload must drain deferred construction without an
    -- unrelated durable write (NotifyLocalDurableChange also schedules).
    if needsMaint and ScheduleExportMaintContinuation then
        ScheduleExportMaintContinuation()
    end
end

local function EnsureExportFresh()
    -- Hot path: reuse already-verified export scope without rescanning the
    -- native guild roster for every GetRecordBody / GetRecordVersionFp call.
    if exportState.guildKey and not exportState.dirtyRebuild and #exportState.order > 0 then
        local ok = ExportScopeStillValid()
        if ok then
            return false
        end
        -- Scope/roster trust lost or dataset replaced: fall through to full resolve.
    end
    local record, guildKey = CurrentGuildRecord()
    local datasetId = record and record.datasetId or nil
    local epoch = tonumber(GS._adoptionEpoch) or 0
    if exportState.guildKey ~= guildKey
        or exportState.datasetId ~= datasetId
        or exportState.epoch ~= epoch
        or (#exportState.order == 0 and record ~= nil)
        or exportState.dirtyRebuild then
        -- Full rebuild remains required on dataset/epoch change; mark dirty so
        -- EnsureIndex can budget enumeration after an immediate structural rebuild.
        RebuildExportIndex()
        exportState.dirtyRebuild = false
        exportState.appendPos = (record and record.operations and record.operations.order
            and #record.operations.order) or 0
        return true
    end
    return false
end

--- Upsert one export body without rescanning the whole accepted history.
local function UpsertExportBody(id, body)
    if type(id) ~= "string" or id == "" or type(body) ~= "table" then
        return
    end
    local existing = exportState.byId[id]
    -- Defer fingerprint to EnsureIndex/GetRecord* budget; compare bodies when
    -- an existing fp is already known.
    if existing and existing.versionFp and not existing.needsFp then
        local fp = FingerprintBody(body)
        if existing.versionFp == fp then
            existing.body = body
            return
        end
    end
    if not existing then
        exportState.order[#exportState.order + 1] = id
        -- New IDs append at the end; do not restart EnsureIndex from 1.
        if not exportState.enumPos then
            exportState.enumPos = #exportState.order
        end
    end
    exportState.byId[id] = {
        id = id,
        versionFp = nil,
        body = body,
        needsFp = true,
    }
    exportState.countsDirty = true
    -- Mark index dirty so EnsureIndex budgets fingerprint work; keep enumPos.
    if GG and GG.GetProvider and providerRegistered then
        local prov = GG.GetProvider(GS.PROVIDER_ID)
        if prov and prov.index then
            prov.index.dirty = true
            prov.index.buildComplete = false
        end
    end
end

--- Publish one accepted valuation without rebuilding the whole Guild Supplies export.
-- Losers and pending rows are not exported. Cold rebuild drains any that this
-- call cannot see yet (dataset mismatch).
-- Storage, `gs:val:` upsert, and descriptor valuationCount stay immediate.
-- Outward NotifyProviderChanged / NotifyUI coalesce inside an open
-- BeginLocalDurableNotifyBatch (bank-log snapshot) and flush on End.
function GS.NoteValuationExported(record, canonicalTxnId)
    if type(record) ~= "table" or type(canonicalTxnId) ~= "string" or canonicalTxnId == "" then
        return
    end
    if not providerRegistered then
        if (tonumber(durableNotifyBatchDepth) or 0) > 0 then
            durableNotifyBatchPending = PreferDurableNotifyReason(
                durableNotifyBatchPending, "valuation")
            return
        end
        if GS.NotifyUI then
            GS.NotifyUI("valuation")
        end
        return
    end
    local body = GS.BuildValuationExportBody and GS.BuildValuationExportBody(record, canonicalTxnId)
    if type(body) ~= "table" then
        return
    end
    local exportId = "gs:val:" .. canonicalTxnId
    if exportState.datasetId ~= record.datasetId or exportState.guildKey == nil then
        exportState.valuationBuildNeeded = true
        exportState.maintIdle = false
        if ScheduleExportMaintContinuation then
            ScheduleExportMaintContinuation()
        end
    else
        local existing = exportState.byId[exportId]
        local prev = existing and existing.body and existing.body.assignment
        local nextA = body.assignment
        local unchanged = type(prev) == "table" and type(nextA) == "table"
            and prev.assignmentId == nextA.assignmentId
            and prev.assignedAt == nextA.assignedAt
            and prev.totalCopper == nextA.totalCopper
            and prev.txnId == nextA.txnId
        if not unchanged then
            UpsertExportBody(exportId, body)
        end
        -- The winner set grew or this id was not yet advertised. Replacing an
        -- existing id does not change the count. No history scan.
        NoteValuationManifestId(canonicalTxnId)
    end
    if (tonumber(durableNotifyBatchDepth) or 0) > 0 then
        durableNotifyBatchPending = PreferDurableNotifyReason(
            durableNotifyBatchPending, "valuation")
        return
    end
    if GG and GG.NotifyProviderChanged then
        GG.NotifyProviderChanged(GS.PROVIDER_ID)
    end
    if GS.NotifyUI then
        GS.NotifyUI("valuation")
    end
end

--- Transport cutoverMarker only for rows with established live production provenance.
-- Becoming active must not launder previously uncredited staged adjustments by
-- attaching the canonical marker (#389 A2).
local function ExportCutoverMarkerForEvent(event, liveMarker)
    if type(liveMarker) ~= "string" or liveMarker == "" or type(event) ~= "table" then
        return nil
    end
    if event.gsProductionCredit ~= true then
        return nil
    end
    local eventType = event.type
    local isAdjustment = eventType == "adjustment"
        or (GS.LEDGER_EVENT and eventType == GS.LEDGER_EVENT.ADJUSTMENT)
        or eventType == "CONSUMABLE_ADJUSTMENT"
    if isAdjustment and event.gsSourceCutoverMarker ~= liveMarker then
        return nil
    end
    return liveMarker
end

--- Upsert or refresh a ledger-event export. cutoverMarker is nil unless the row
-- already carries verified production provenance for the live cutover.
local function UpsertLedgerEventExport(exportId, datasetId, event, cutoverMarker)
    if type(exportId) ~= "string" or exportId == "" or type(event) ~= "table" then
        return
    end
    local existing = exportState.byId[exportId]
    local prev = existing and existing.body
    if prev and prev.kind == "gs-ledger-event"
        and prev.cutoverMarker == cutoverMarker
        and prev.datasetId == datasetId
        and prev.event == event then
        return
    end
    UpsertExportBody(exportId, {
        kind = "gs-ledger-event",
        datasetId = datasetId,
        event = event,
        cutoverMarker = cutoverMarker,
    })
end

--- Force paced archive→live ledger rebuild after TrimEventArchive removes IDs.
-- Archive length can stay unchanged across shelve+trim while export IDs were
-- dropped; warm high-water alone cannot detect that content swap.
function GS.MarkLedgerArchiveExportStale()
    exportState.ledgerArchiveWarmPos = 0
    exportState.ledgerBuildNeeded = true
    exportState.ledgerBuildPhase = "archive"
    exportState.ledgerBuildCursor = 1
    exportState.countsDirty = true
    exportState.maintIdle = false
    if providerRegistered and ScheduleExportMaintContinuation then
        ScheduleExportMaintContinuation()
    end
end

-- Coalesce trusted bulk export eviction (archive trim) into one order pass.
local exportRemovalBatchDepth = 0
local exportRemovalBatchDrop = nil
local exportRemovalBatchRemoved = 0
local exportRemovalBatchDroppedValuation = false

--- Begin coalescing RemoveGossipExportBodies compaction/notify. Nested.
function GS.BeginGossipExportBodyRemovalBatch()
    exportRemovalBatchDepth = (tonumber(exportRemovalBatchDepth) or 0) + 1
    if exportRemovalBatchDepth == 1 then
        exportRemovalBatchDrop = {}
        exportRemovalBatchRemoved = 0
        exportRemovalBatchDroppedValuation = false
    end
end

local function CompactGossipExportOrder(drop)
    if type(drop) ~= "table" then
        return
    end
    local order = exportState.order
    local scanned = #order
    local write = 1
    for read = 1, scanned do
        local id = order[read]
        if not drop[id] then
            order[write] = id
            write = write + 1
        end
    end
    for i = write, scanned do
        order[i] = nil
    end
    if exportState.enumPos and exportState.enumPos > #order then
        exportState.enumPos = #order
    end
    exportState.countsDirty = true
    exportState.maintIdle = false
    -- GS._onGossipExportOrderCompaction is nil in production; tests count passes.
    if type(GS._onGossipExportOrderCompaction) == "function" then
        GS._onGossipExportOrderCompaction(scanned)
    end
end

local function FinishGossipExportBodyRemovals(removed, droppedValuation)
    if removed > 0 or droppedValuation then
        if droppedValuation then
            PublishValuationManifest()
        end
        if GG and GG.GetProvider and providerRegistered then
            local prov = GG.GetProvider(GS.PROVIDER_ID)
            if removed > 0 and prov and prov.index then
                prov.index.dirty = true
                prov.index.buildComplete = false
            end
            if droppedValuation and GG.NotifyProviderChanged then
                GG.NotifyProviderChanged(GS.PROVIDER_ID)
            end
        end
    end
end

--- Flush one coalesced order compaction + provider notify when outermost ends.
function GS.EndGossipExportBodyRemovalBatch()
    local depth = tonumber(exportRemovalBatchDepth) or 0
    if depth <= 0 then
        exportRemovalBatchDepth = 0
        exportRemovalBatchDrop = nil
        exportRemovalBatchRemoved = 0
        exportRemovalBatchDroppedValuation = false
        return
    end
    depth = depth - 1
    exportRemovalBatchDepth = depth
    if depth > 0 then
        return
    end
    local drop = exportRemovalBatchDrop
    local removed = tonumber(exportRemovalBatchRemoved) or 0
    local droppedValuation = exportRemovalBatchDroppedValuation and true or false
    exportRemovalBatchDrop = nil
    exportRemovalBatchRemoved = 0
    exportRemovalBatchDroppedValuation = false
    if removed > 0 and type(drop) == "table" then
        CompactGossipExportOrder(drop)
    end
    FinishGossipExportBodyRemovals(removed, droppedValuation)
end

--- Drop evicted durable export ids from the warm Gossip index (bounded).
-- Ordinary callers: at most 64 ids, immediate order compaction + notify.
-- Inside Begin/EndGossipExportBodyRemovalBatch (trusted archive trim): all ids
-- in the call are applied to byId/manifest, and compaction/notify coalesce to
-- one pass at End. opts.bulk permits >64 ids in a single non-batched call.
function GS.RemoveGossipExportBodies(ids, opts)
    if type(ids) ~= "table" or #ids < 1 then
        return 0
    end
    opts = opts or {}
    local batching = (tonumber(exportRemovalBatchDepth) or 0) > 0
        and type(exportRemovalBatchDrop) == "table"
    local bulk = opts.bulk == true or batching
    local limit = bulk and #ids or math.min(#ids, 64)
    local removed = 0
    local drop = batching and exportRemovalBatchDrop or {}
    local droppedValuation = false
    for i = 1, limit do
        local id = ids[i]
        if type(id) == "string" then
            -- Cold paced rebuild can advertise winners in valuationManifest
            -- before gs:val bodies exist in byId. Drop the tracked manifest
            -- entry even when the body has not been materialized yet.
            if id:sub(1, 7) == "gs:val:" and DropValuationManifestId(id:sub(8)) then
                droppedValuation = true
            end
            if exportState.byId[id] then
                exportState.byId[id] = nil
                drop[id] = true
                removed = removed + 1
            end
        end
    end
    if batching then
        exportRemovalBatchRemoved = (tonumber(exportRemovalBatchRemoved) or 0) + removed
        if droppedValuation then
            exportRemovalBatchDroppedValuation = true
        end
        return removed
    end
    if removed < 1 and not droppedValuation then
        return 0
    end
    if removed > 0 then
        CompactGossipExportOrder(drop)
    end
    FinishGossipExportBodyRemovals(removed, droppedValuation)
    return removed
end

---------------------------------------------------------------------------
-- Provider callbacks
---------------------------------------------------------------------------

local function GetScopeId()
    if GG and GG.GetGuildScopeId then
        return GG.GetGuildScopeId()
    end
    local identity = GG and GG.GetGuildIdentity and GG.GetGuildIdentity()
    return identity and identity.guildKey or nil
end

local function IsPeerEligible(peerName, ctx)
    if not GG or not GG.IsGuildMember then
        return false
    end
    return GG.IsGuildMember(peerName) and true or false
end

local function GetCapabilities()
    local record = CurrentGuildRecord()
    local caps = {
        guildSupplies = true,
        stagedConfig = true,
        schema = GS.PROVIDER_SCHEMA,
    }
    if record then
        caps.datasetId = record.datasetId
        caps.editorRankPosition = record.permission and record.permission.editorRankPosition or nil
        caps.permissionRevisionId = record.permission and record.permission.revisionId or nil
        caps.currentCampaignId = record.currentCampaignId
    end
    return caps
end

local function OnIndexInvalidated()
    exportState.enumPos = nil
end

local function EnsureIndex(index, limits)
    EnsureExportFresh()
    local budget = math.max(1, tonumber(limits and limits.indexEntries) or (GG and GG.INDEX_ENTRIES_PER_STEP and GG.INDEX_ENTRIES_PER_STEP.SLOW) or 8)
    if index.buildComplete and not index.dirty then
        return false, 0
    end
    if not exportState.enumPos then
        exportState.enumPos = 1
    end
    local n = 0
    while exportState.enumPos <= #exportState.order and n < budget do
        local rid = exportState.order[exportState.enumPos]
        exportState.enumPos = exportState.enumPos + 1
        local r = exportState.byId[rid]
        if r then
            if r.needsFp or not r.versionFp then
                r.versionFp = FingerprintBody(r.body)
                r.needsFp = false
            end
            if GG and GG.IndexUpsert then
                local _, detail = GG.IndexUpsert(index, rid, r.versionFp, r)
                if detail == "replaced" and GG.BumpIndexEpoch then
                    GG.BumpIndexEpoch(index)
                    exportState.enumPos = 1
                    return true, n + 1
                end
            end
        end
        n = n + 1
    end
    if exportState.enumPos > #exportState.order then
        exportState.enumPos = nil
        index.buildComplete = true
        index.dirty = false
        return false, n
    end
    return true, n
end

local function ListRecordIds(cursor, limit)
    EnsureExportFresh()
    cursor = math.max(1, tonumber(cursor) or 1)
    limit = math.max(1, tonumber(limit) or 8)
    local page = {}
    local i = cursor
    while i <= #exportState.order and #page < limit do
        page[#page + 1] = exportState.order[i]
        i = i + 1
    end
    if i <= #exportState.order then
        return page, i
    end
    return page, nil
end

local function GetRecordVersionFp(recordId)
    EnsureExportFresh()
    local r = exportState.byId[tostring(recordId)]
    if not r then
        return nil
    end
    if r.needsFp or not r.versionFp then
        r.versionFp = FingerprintBody(r.body)
        r.needsFp = false
    end
    return r.versionFp
end

local function GetRecordBody(recordId)
    EnsureExportFresh()
    local r = exportState.byId[tostring(recordId)]
    if not r then
        return nil
    end
    if r.needsFp or not r.versionFp then
        r.versionFp = FingerprintBody(r.body)
        r.needsFp = false
    end
    return { id = r.id, versionFp = r.versionFp, body = r.body }
end

local function ValidateAndApply(record, ctx)
    ctx = ctx or {}
    if type(record) ~= "table" or record.id == nil or type(record.body) ~= "table" then
        return "rejected", "malformed"
    end
    local body = record.body
    local sender = ctx.sender
    if ctx.localWrite then
        -- Local durable writes go through ApplyStaged*; provider local path is not used.
        return "rejected", "use_local_api"
    end
    if type(sender) ~= "string" or sender == "" then
        return "rejected", "invalid_sender"
    end

    -- Note peer dataset advertisements from any same-guild source descriptor.
    if body.kind == "dataset-desc" and type(body.datasetId) == "string" then
        if GS.NotePeerDataset then
            GS.NotePeerDataset(sender, body.datasetId, body)
        end
    end

    -- Pending adoption buffers all bodies for the selected source dataset.
    -- Expire abandoned sessions on the gossip path so they cannot suppress forever.
    if GS.GetPendingAdoption then
        GS:GetPendingAdoption()
    end
    local adop = GS._adoption
    if type(adop) == "table" and not adop.committed then
        local member = GS.AuthenticateTransportSender(sender)
        if member and member.name == adop.sourcePeer then
            local ds = body.datasetId
                or (body.op and body.op.datasetId)
                or (body.header and body.header.datasetId)
                or (body.event and body.event.datasetId)
                or (body.evidence and body.evidence.datasetId)
                or (body.assignment and body.assignment.datasetId)
            if ds == adop.sourceDatasetId or body.kind == "dataset-desc" then
                local st, reason = GS:BufferAdoptionRecord(tostring(record.id), body)
                return st, reason
            end
        end
        -- Traffic for a different dataset during adoption is ignored (pending).
        return "pending", "adoption_in_progress"
    end

    local member, mReason = GS.AuthenticateTransportSender(sender)
    if not member then
        return "rejected", mReason or "unauthorized"
    end

    -- Epoch guard: after adoption, old-dataset traffic must not restore state.
    local localRecord = CurrentGuildRecord()
    if localRecord and body.kind == "gs-op" and type(body.op) == "table" then
        if body.op.datasetId ~= localRecord.datasetId then
            return "rejected", "dataset_mismatch"
        end
    end

    if body.kind == "dataset-desc" then
        if not localRecord then
            -- Empty client: install replication from authenticated editor.
            local st, reason = GS:InstallStagedDatasetFromRemote(body, member)
            return st, reason
        end
        if body.datasetId == localRecord.datasetId then
            -- Same dataset: verified editors may push live activation/cutover
            -- without requiring a local bank sample (#389 catch-up). Membership
            -- alone is insufficient; activatedByGuid is not proof of authority.
            if body.activation == GS.ACTIVATION_ACTIVE
                and type(body.liveCutover) == "table"
                and localRecord.activation == GS.ACTIVATION_STAGED
                and GS.InstallRemoteLiveCutover then
                local stCut, cutReason = GS.InstallRemoteLiveCutover(
                    localRecord, body.liveCutover, member.guildKey, {
                        quarantinePending = true,
                        member = member,
                        requireEditorAuthority = true,
                        -- Compatible catch-up: any current editor may relay the
                        -- already-activated cutover (actor may be the original
                        -- activator, not necessarily this sender).
                        bindActorToSender = false,
                        authOpts = {},
                    })
                if stCut == "accepted" or stCut == "duplicate" then
                    if GS._NotifyLocalDurableChange then
                        GS._NotifyLocalDurableChange("activation")
                    end
                    return stCut == "duplicate" and "duplicate" or "accepted", cutReason
                end
                return "rejected", cutReason or "live_activation_conflict"
            end
            if GS.IsLiveActive and GS.IsLiveActive(localRecord)
                and body.activation == GS.ACTIVATION_ACTIVE
                and type(body.cutoverMarker) == "string"
                and type(localRecord.liveCutover) == "table"
                and body.cutoverMarker ~= localRecord.liveCutover.cutoverMarker then
                -- Divergent live markers: only authenticated editors can surface
                -- a durable conflict advertisement (NotePeerDataset below).
                local editorOk = GS.SenderHasEditorAuthority
                    and select(1, GS.SenderHasEditorAuthority(member, {}))
                if editorOk and GS.NotePeerDataset then
                    GS.NotePeerDataset(sender, body.datasetId, body)
                end
                return "rejected", "live_activation_conflict"
            end
            return "duplicate", "duplicate"
        end
        -- Foreign dataset while local exists: surface mismatch; do not merge.
        if GS.NotePeerDataset then
            GS.NotePeerDataset(sender, body.datasetId, body)
        end
        return "pending", "dataset_mismatch"
    end

    if body.kind == "campaign-header" then
        if not localRecord then
            return "pending", "awaiting_dataset"
        end
        local header = body.header
        if type(header) ~= "table" or type(header.campaignId) ~= "string" then
            return "rejected", "invalid_campaign"
        end
        if header.datasetId ~= localRecord.datasetId then
            return "rejected", "dataset_mismatch"
        end
        if localRecord.campaigns[header.campaignId] then
            -- Exact original boundary retention; divergent headers quarantine.
            if GS._DeepEqualOps and GS._DeepEqualOps(localRecord.campaigns[header.campaignId], header) then
                return "duplicate", "duplicate"
            end
            return "rejected", "id_conflict"
        end
        -- Header without its start-campaign op stays pending (do not invent lifecycle).
        return "pending", "missing_predecessor"
    end

    if body.kind == "campaign-archive" or body.kind == "campaign-archive-page" then
        if not localRecord then
            return "pending", "awaiting_dataset"
        end
        if body.datasetId ~= localRecord.datasetId then
            return "rejected", "dataset_mismatch"
        end
        if type(body.campaignId) ~= "string" then
            return "rejected", "invalid_campaign"
        end
        -- Membership alone is not archive authority; require a verified editor.
        local editorOk, editorReason = GS.SenderHasEditorAuthority(member, {
            allowBootstrapInstall = false,
        })
        if not editorOk then
            return "rejected", editorReason or "unauthorized"
        end
        -- Never archive the still-current campaign via gossip.
        if localRecord.currentCampaignId == body.campaignId then
            return "rejected", "current_campaign"
        end
        if not localRecord.campaigns[body.campaignId] then
            return "pending", "missing_predecessor"
        end
        -- Already-stored exact archive: duplicate without recreating a buffer.
        if localRecord.campaignArchives[body.campaignId] and body.kind == "campaign-archive"
            and type(body.requestedItems) == "table" then
            local existing = localRecord.campaignArchives[body.campaignId]
            local inline = {
                schemaVersion = body.schemaVersion or GS.SCHEMA_VERSION,
                campaignId = body.campaignId,
                datasetId = body.datasetId,
                requestedItems = body.requestedItems,
                generation = body.generation,
                archivedAt = body.archivedAt,
            }
            if GS._DeepEqualOps and GS._DeepEqualOps(existing, inline) then
                ClearArchivePageBuffer(body.campaignId)
                return "duplicate", "duplicate"
            end
        end
        -- Validate page indices / mandatory pageCount upper bound before retention.
        local maxPageCount = GS.MAX_ARCHIVE_PAGE_COUNT or 512
        local maxPageItems = GS.MAX_ARCHIVE_PAGE_ITEMS or 64
        if body.kind == "campaign-archive" then
            local pageCount = tonumber(body.pageCount)
            if pageCount ~= nil then
                if pageCount ~= math.floor(pageCount) or pageCount < 1 or pageCount > maxPageCount then
                    return "rejected", "invalid_campaign_archive"
                end
            end
        end
        if body.kind == "campaign-archive-page" then
            local page = tonumber(body.page)
            local pageCount = tonumber(body.pageCount)
            if not page or page ~= math.floor(page) or page < 1 then
                return "rejected", "invalid_campaign_archive"
            end
            if not pageCount or pageCount ~= math.floor(pageCount)
                or pageCount < 1 or pageCount > maxPageCount or page > pageCount then
                return "rejected", "invalid_campaign_archive"
            end
            -- Bound page payload before retention (item map size).
            if type(body.requestedItems) == "table" then
                local n = 0
                for _ in pairs(body.requestedItems) do
                    n = n + 1
                    if n > maxPageItems then
                        return "rejected", "invalid_campaign_archive"
                    end
                end
            end
            if type(body.eligibilityItems) == "table" then
                local n = 0
                for _ in pairs(body.eligibilityItems) do
                    n = n + 1
                    if n > maxPageItems then
                        return "rejected", "invalid_campaign_archive"
                    end
                end
            end
        end
        local maxCamps = GS.MAX_FRAGMENT_BUFFER_ASSEMBLIES
            or GS.MAX_ARCHIVE_PAGE_BUFFER_CAMPAIGNS or 16
        -- Campaign-archive assembly uses the raised archive page ceiling.
        local maxPages = GS.MAX_ARCHIVE_PAGE_BUFFER_PAGES
            or GS.MAX_FRAGMENT_BUFFER_PAGES or 512
        local now = GetServerTime and GetServerTime() or 0
        -- Reclaim expired assemblies across the whole pool before capacity checks.
        ReclaimExpiredFragmentBuffers({
            datasetId = body.datasetId,
            guildKey = localRecord and localRecord._guildKey,
        })
        local buf = archivePageBuffer[body.campaignId]
        local createdEmpty = false
        if not buf then
            if (archivePageBufferCount or 0) >= maxCamps then
                return "rejected", "full"
            end
            -- Page-first: preflight page capacity before allocating an empty slot.
            if body.kind == "campaign-archive-page"
                and (archivePageBufferPages or 0) >= maxPages then
                return "rejected", "full"
            end
            buf = {
                pages = {},
                datasetId = body.datasetId,
                sourcePeer = sender,
                at = now,
                guildKey = localRecord and localRecord._guildKey,
            }
            archivePageBuffer[body.campaignId] = buf
            archivePageBufferCount = (archivePageBufferCount or 0) + 1
            createdEmpty = true
        elseif buf.datasetId and buf.datasetId ~= body.datasetId then
            ClearArchivePageBuffer(body.campaignId)
            return "rejected", "dataset_mismatch"
        elseif buf.sourcePeer and buf.sourcePeer ~= sender then
            ClearArchivePageBuffer(body.campaignId)
            return "rejected", "id_conflict"
        end
        if body.kind == "campaign-archive" then
            if buf.meta and GS._DeepEqualOps and not GS._DeepEqualOps(buf.meta, body) then
                ClearArchivePageBuffer(body.campaignId)
                return "rejected", "id_conflict"
            end
            -- Exact meta redelivery: compare without rebuilding pending state.
            if buf.meta and GS._DeepEqualOps and GS._DeepEqualOps(buf.meta, body) then
                -- fall through to assembly
            else
                buf.meta = body
            end
            buf.at = now
            if tonumber(body.pageCount) then
                buf.pageCount = tonumber(body.pageCount)
            end
        else
            local page = tonumber(body.page)
            if buf.pages[page] then
                if GS._DeepEqualOps and not GS._DeepEqualOps(buf.pages[page], body) then
                    ClearArchivePageBuffer(body.campaignId)
                    return "rejected", "id_conflict"
                end
                -- Exact page duplicate: do not recreate buffer / recount pages.
            else
                if (archivePageBufferPages or 0) >= maxPages then
                    -- Roll back only a newly created empty assembly; keep shells/pages.
                    if createdEmpty and ArchivePageBufferIsEmpty(buf) then
                        ClearArchivePageBuffer(body.campaignId)
                    end
                    return "rejected", "full"
                end
                archivePageBufferPages = (archivePageBufferPages or 0) + 1
                buf.pages[page] = body
            end
            buf.at = now
            if tonumber(body.pageCount) then
                buf.pageCount = tonumber(body.pageCount)
            end
        end
        local meta = buf.meta
        if type(meta) ~= "table" then
            return "pending", "missing_predecessor"
        end
        local archive
        local function CopyEligScalars(src, items)
            if type(src) ~= "table" and type(items) ~= "table" then
                return nil
            end
            local eligibility = {
                baselineEstablished = src and src.baselineEstablished,
                baselineAt = src and src.baselineAt,
                tabEligibleFrom = src and src.tabEligibleFrom,
                items = items or {},
            }
            if type(src) == "table" and type(src.items) == "table" then
                for k, v in pairs(src.items) do
                    eligibility.items[k] = v
                end
            end
            return eligibility
        end
        if type(meta.requestedItems) == "table" then
            archive = {
                schemaVersion = meta.schemaVersion or GS.SCHEMA_VERSION,
                campaignId = meta.campaignId,
                datasetId = meta.datasetId,
                requestedItems = meta.requestedItems,
                generation = meta.generation,
                archivedAt = meta.archivedAt,
                bankTab = tonumber(meta.bankTab),
                eligibility = CopyEligScalars(meta.eligibility, nil),
            }
        else
            local pageCount = tonumber(meta.pageCount) or tonumber(buf.pageCount) or 1
            if pageCount < 1 or pageCount ~= math.floor(pageCount) then
                ClearArchivePageBuffer(body.campaignId)
                return "rejected", "invalid_campaign_archive"
            end
            local merged, got = {}, 0
            local eligMerged, eligGot = {}, 0
            for page = 1, pageCount do
                local p = buf.pages[page]
                if type(p) ~= "table" or type(p.requestedItems) ~= "table" then
                    return "pending", "missing_predecessor"
                end
                for k, v in pairs(p.requestedItems) do
                    merged[k] = v
                    got = got + 1
                end
                if type(p.eligibilityItems) == "table" then
                    for k, v in pairs(p.eligibilityItems) do
                        eligMerged[k] = v
                        eligGot = eligGot + 1
                    end
                end
            end
            if type(meta.itemCount) == "number" and got ~= meta.itemCount then
                return "pending", "missing_predecessor"
            end
            local wantElig = tonumber(meta.eligibilityItemCount)
            if wantElig ~= nil and eligGot ~= wantElig then
                return "pending", "missing_predecessor"
            end
            archive = {
                schemaVersion = meta.schemaVersion or GS.SCHEMA_VERSION,
                campaignId = meta.campaignId,
                datasetId = meta.datasetId,
                requestedItems = merged,
                generation = meta.generation,
                archivedAt = meta.archivedAt,
                bankTab = tonumber(meta.bankTab),
                eligibility = CopyEligScalars(meta.eligibility, eligMerged),
            }
        end
        if not GS.ValidateCampaignArchive
            or not GS.ValidateCampaignArchive(archive, body.campaignId, localRecord) then
            ClearArchivePageBuffer(body.campaignId)
            return "rejected", "invalid_campaign_archive"
        end
        local existing = localRecord.campaignArchives[body.campaignId]
        if existing then
            if GS._DeepEqualOps and GS._DeepEqualOps(existing, archive) then
                ClearArchivePageBuffer(body.campaignId)
                return "duplicate", "duplicate"
            end
            ClearArchivePageBuffer(body.campaignId)
            return "rejected", "id_conflict"
        end
        localRecord.campaignArchives[body.campaignId] = archive
        ClearArchivePageBuffer(body.campaignId)
        if GS.NotifyLocalDurableChange then
            GS.NotifyLocalDurableChange("remote-archive")
        end
        return "accepted", nil
    end

    if body.kind == "gs-op-page" then
        if not localRecord then
            return "pending", "awaiting_dataset"
        end
        if body.datasetId ~= localRecord.datasetId then
            return "rejected", "dataset_mismatch"
        end
        local opId = body.opId
        if type(opId) ~= "string" or opId == "" then
            return "rejected", "invalid_operation"
        end
        local page = tonumber(body.page)
        local pageCount = tonumber(body.pageCount)
        local maxPages = GS.MAX_MANIFEST_PAGES or 64
        if not page or page ~= math.floor(page) or page < 1 then
            return "rejected", "invalid_operation"
        end
        if not pageCount or pageCount ~= math.floor(pageCount)
            or pageCount < 1 or pageCount > maxPages or page > pageCount then
            return "rejected", "invalid_operation"
        end
        ReclaimExpiredFragmentBuffers({
            datasetId = body.datasetId,
            guildKey = localRecord._guildKey,
        })
        local maxCamps = GS.MAX_FRAGMENT_BUFFER_ASSEMBLIES or 16
        local maxPagesBuf = GS.MAX_FRAGMENT_BUFFER_PAGES or 64
        local now = GetServerTime and GetServerTime() or 0
        local buf = opManifestBuffer[opId]
        local createdEmpty = false
        if not buf then
            if not CanAllocateOpManifestBuffer(sender, maxCamps) then
                return "rejected", "full"
            end
            -- First page: preflight page/per-peer capacity before empty alloc.
            if not CanRetainOpManifestPage(sender, maxPagesBuf) then
                return "rejected", "full"
            end
            buf = {
                pages = {},
                datasetId = body.datasetId,
                sourcePeer = sender,
                at = now,
                guildKey = localRecord._guildKey,
            }
            opManifestBuffer[opId] = buf
            opManifestBufferCount = (opManifestBufferCount or 0) + 1
            createdEmpty = true
        elseif buf.datasetId and buf.datasetId ~= body.datasetId then
            -- Foreign/mismatched fragment: reject without clearing a legitimate assembly.
            return "rejected", "dataset_mismatch"
        elseif buf.sourcePeer and buf.sourcePeer ~= sender then
            -- Foreign fragment: reject without clearing the original sender's buffer.
            return "rejected", "id_conflict"
        end
        if buf.pageCount and buf.pageCount ~= pageCount then
            return "rejected", "invalid_operation"
        end
        local madeProgress = false
        if buf.pages[page] then
            if GS._DeepEqualOps and not GS._DeepEqualOps(buf.pages[page], body) then
                ClearOpManifestBuffer(opId)
                return "rejected", "id_conflict"
            end
            -- Exact duplicate: do not refresh lifetime.
        else
            if not CanRetainOpManifestPage(sender, maxPagesBuf) then
                -- Roll back only a newly created empty assembly; keep shell/pages.
                if createdEmpty and OpManifestBufferIsEmpty(buf) then
                    ClearOpManifestBuffer(opId)
                end
                return "rejected", "full"
            end
            opManifestBufferPages = (opManifestBufferPages or 0) + 1
            buf.pages[page] = body
            madeProgress = true
        end
        if madeProgress then
            buf.at = now
        end
        buf.pageCount = pageCount
        if type(buf.shell) ~= "table" then
            return "pending", "missing_predecessor"
        end
        local assembled, aerr = AssembleOpFromPages(buf.shell, buf.pages)
        if not assembled then
            if aerr == "incomplete_manifest_pages" then
                return "pending", "missing_predecessor"
            end
            ClearOpManifestBuffer(opId)
            return "rejected", aerr or "invalid_operation"
        end
        ClearOpManifestBuffer(opId)
        -- Re-enter with assembled body.
        body = assembled
        -- fall through to gs-op handling below
    end

    if body.kind == "gs-op" then
        local op = body.op
        if type(op) ~= "table" then
            return "rejected", "invalid_operation"
        end
        -- Paged shell: retain fragment buffer until pages arrive. Confirm/resolve
        -- shells omit embedded bodies; ordinary shells omit value/target.
        local pageCount = tonumber(body.pageCount) or tonumber(op.pageCount)
        local isPagedShell = false
        if pageCount and pageCount >= 1 then
            if op.kind == GS.KIND.CONFIRM_CANDIDATE then
                isPagedShell = (not op.candidateRef or not op.candidateRef.body)
                    and not (op.candidateRef and op.candidateRef.records
                        and op.candidateRef.records[1] and op.candidateRef.records[1].body)
            elseif op.kind == GS.KIND.RESOLVE_CONFLICT then
                isPagedShell = (not op.value or type(op.value.contentBodies) ~= "table")
            else
                -- Ordinary oversized op: shell keeps identity; pages carry payload.
                isPagedShell = (op.value == nil and op.target == nil)
            end
        end
        if isPagedShell then
            if not localRecord then
                return "pending", "awaiting_dataset"
            end
            local maxPages = GS.MAX_MANIFEST_PAGES or 64
            if pageCount ~= math.floor(pageCount) or pageCount < 1 or pageCount > maxPages then
                return "rejected", "invalid_operation"
            end
            if op.datasetId ~= localRecord.datasetId then
                return "rejected", "dataset_mismatch"
            end
            ReclaimExpiredFragmentBuffers({
                datasetId = op.datasetId or body.datasetId,
                guildKey = localRecord._guildKey,
            })
            local maxCamps = GS.MAX_FRAGMENT_BUFFER_ASSEMBLIES or 16
            local now = GetServerTime and GetServerTime() or 0
            local buf = opManifestBuffer[op.id]
            if not buf then
                if not CanAllocateOpManifestBuffer(sender, maxCamps) then
                    return "rejected", "full"
                end
                buf = {
                    pages = {},
                    datasetId = op.datasetId,
                    sourcePeer = sender,
                    at = now,
                    guildKey = localRecord._guildKey,
                }
                opManifestBuffer[op.id] = buf
                opManifestBufferCount = (opManifestBufferCount or 0) + 1
            elseif buf.datasetId and buf.datasetId ~= op.datasetId then
                -- Reject foreign/mismatched shell without clearing another peer's pages.
                return "rejected", "dataset_mismatch"
            elseif buf.sourcePeer and buf.sourcePeer ~= sender then
                -- Pages-first from peer A must not combine with peer B's shell.
                return "rejected", "id_conflict"
            end
            if buf.pageCount and buf.pageCount ~= pageCount then
                return "rejected", "invalid_operation"
            end
            if buf.shell and GS._DeepEqualOps and not GS._DeepEqualOps(buf.shell, body) then
                ClearOpManifestBuffer(op.id)
                return "rejected", "id_conflict"
            end
            local shellProgress = false
            if not buf.shell then
                buf.shell = body
                shellProgress = true
            elseif GS._DeepEqualOps and GS._DeepEqualOps(buf.shell, body) then
                -- Exact duplicate shell: do not refresh lifetime.
            else
                buf.shell = body
                shellProgress = true
            end
            buf.pageCount = pageCount
            if shellProgress then
                buf.at = now
            end
            if not buf.sourcePeer then
                buf.sourcePeer = sender
            end
            local assembled, aerr = AssembleOpFromPages(buf.shell, buf.pages)
            if not assembled then
                if aerr == "incomplete_manifest_pages" then
                    return "pending", "missing_predecessor"
                end
                ClearOpManifestBuffer(op.id)
                return "rejected", aerr or "invalid_operation"
            end
            ClearOpManifestBuffer(op.id)
            body = assembled
            op = body.op
        end
        -- Ordinary members may carry historical candidates; only authenticated
        -- editors authorize application. Relayed author fields are not proof —
        -- even when the claimed original author currently has editor rank.
        local requireRecover = false
        if op.kind == GS.KIND.SET_EDITOR_RANK and localRecord then
            local perm = localRecord.permission
            local rawPos = type(perm) == "table" and tonumber(perm.editorRankPosition) or nil
            local integralPos = rawPos and rawPos == math.floor(rawPos) and rawPos >= 1
            -- Historical metadata above today's rankCount is not corrupt; live
            -- authorization still uses the shared officer policy.
            local policyOk = type(perm) == "table"
                and type(perm.revisionId) == "string" and perm.revisionId ~= ""
                and integralPos
            requireRecover = not policyOk
        end
        -- Policy catch-up: while bootstrap-locked, evaluate authority with
        -- allowPolicyCatchUp when the body is a causal policy successor under
        -- the current predecessor revision. Do not mark those as relay — Admit
        -- still authorizes the sender under the shared officer policy.
        local bootstrapLocked = localRecord and GS.IsBootstrapEditLocked
            and GS.IsBootstrapEditLocked(member.guildKey, localRecord)
        local currentPolicy = localRecord and localRecord.permission
            and localRecord.permission.revisionId
        local isPolicyCatchUp = bootstrapLocked
            and op.kind == GS.KIND.SET_EDITOR_RANK
            and type(op.basePolicyRevision) == "string"
            and op.basePolicyRevision == currentPolicy
        local relay = false
        local editorOk = select(1, GS.SenderHasEditorAuthority(member, {
            requireRecoverPolicy = requireRecover,
            allowBootstrapInstall = false,
            allowPolicyCatchUp = isPolicyCatchUp,
        }))
        if not editorOk then
            -- Non-editor carrier: untrusted historical relay.
            relay = true
        else
            -- Editor carrier with mismatched claimed author is still a relay.
            -- Do not apply or hard-reject; retain for exact-content confirmation.
            -- Causal policy catch-up bodies keep actor binding via Admit.
            if not isPolicyCatchUp then
                if type(op.actorGuid) == "string" and op.actorGuid ~= ""
                    and op.actorGuid ~= member.guid then
                    relay = true
                elseif type(op.actorName) == "string" and op.actorName ~= "" then
                    local want = GG.NormalizePlayer and GG.NormalizePlayer(op.actorName)
                    local have = GG.NormalizePlayer and GG.NormalizePlayer(member.name)
                    if want and have and want ~= have then
                        relay = true
                    end
                end
            end
        end
        local boundary = body.boundary
        if type(boundary) ~= "table" and op.kind == GS.KIND.START_CAMPAIGN and localRecord then
            boundary = localRecord.campaigns and localRecord.campaigns[op.id]
                or (GS._pendingCampaignBoundaries and GS._pendingCampaignBoundaries[op.id])
        end
        return GS:AdmitRemoteOperation(op, {
            sender = sender,
            member = member,
            boundary = boundary,
            relay = relay,
        })
    end

    -- #388 staged donation evidence: only the authenticated transport sender votes.
    if body.kind == "gs-evidence" then
        if not localRecord then
            return "pending", "awaiting_dataset"
        end
        if body.datasetId and body.datasetId ~= localRecord.datasetId then
            return "rejected", "dataset_mismatch"
        end
        local evidence = body.evidence
        if type(evidence) ~= "table" then
            return "rejected", "invalid_evidence"
        end
        -- Relayed witness maps / claimed observedBy are not identity proof.
        evidence.datasetId = body.datasetId or localRecord.datasetId
        evidence.campaignId = evidence.campaignId or body.campaignId
            or localRecord.currentCampaignId
        return GS:AdmitDirectObservation(evidence, {
            sender = sender,
            member = member,
            offlineRecord = localRecord,
            campaignId = evidence.campaignId,
        })
    end

    -- #388 accepted ledger events (donations / adjustments) for catch-up.
    if body.kind == "gs-ledger-event" then
        if not localRecord then
            return "pending", "awaiting_dataset"
        end
        if body.datasetId and body.datasetId ~= localRecord.datasetId then
            return "rejected", "dataset_mismatch"
        end
        local event = body.event
        if type(event) ~= "table" then
            return "rejected", "invalid_event"
        end
        event.datasetId = body.datasetId or localRecord.datasetId
        -- Never trust self-declared credit/provenance on the event payload.
        event.gsProductionCredit = nil
        event.gsSourceCutoverMarker = nil
        event.gsAltSourceCutoverMarker = nil
        -- Transport-level marker from an authenticated active exporter only.
        local sourceMarker = nil
        if type(body.cutoverMarker) == "string" and body.cutoverMarker ~= "" then
            sourceMarker = body.cutoverMarker
        end
        return GS:AdmitLedgerEvent(event, {
            sender = sender,
            member = member,
            offlineRecord = localRecord,
            sourceCutoverMarker = sourceMarker,
            -- Donation catch-up is occurrence-deduped; adjustments need editor auth
            -- unless this is a preserved historical body (handled inside Admit).
            relay = false,
        })
    end

    -- #397 immutable DBMarket assignment bound to one production donation.
    if body.kind == "gs-valuation" then
        if not localRecord then
            return "pending", "awaiting_dataset"
        end
        if body.datasetId and body.datasetId ~= localRecord.datasetId then
            return "rejected", "dataset_mismatch"
        end
        if type(body.assignment) ~= "table" then
            return "rejected", "malformed"
        end
        return GS:AdmitValuationAssignment(body, {
            sender = sender,
            member = member,
            offlineRecord = localRecord,
            -- Provider record id `gs:val:<canonical>` binds the donation key
            -- without rewriting the immutable assignment.txnId.
            exportRecordId = tostring(record.id),
        })
    end

    return "rejected", "unsupported_kind"
end

---------------------------------------------------------------------------
-- Registration / notification
---------------------------------------------------------------------------

local function BuildProviderSpec()
    return {
        id = GS.PROVIDER_ID,
        schema = GS.PROVIDER_SCHEMA,
        enabled = true,
        ready = true,
        GetScopeId = GetScopeId,
        IsPeerEligible = IsPeerEligible,
        GetCapabilities = GetCapabilities,
        EnsureIndex = EnsureIndex,
        OnIndexInvalidated = OnIndexInvalidated,
        ListRecordIds = ListRecordIds,
        GetRecordVersionFp = GetRecordVersionFp,
        GetRecordBody = GetRecordBody,
        ValidateAndApply = ValidateAndApply,
    }
end

--- Idempotent provider registration. Safe when Guild Gossip is not yet ready.
function GS:EnsureGossipProvider()
    if not GG or not GG.RegisterProvider then
        return false, "gossip_unavailable"
    end
    if providerRegistered and GG.GetProvider and GG.GetProvider(GS.PROVIDER_ID) then
        return true
    end
    if GG.Init then
        GG.Init()
    end
    local ok, err = GG.RegisterProvider(BuildProviderSpec())
    if not ok and err and err ~= "already_registered" then
        -- RegisterProvider is idempotent; treat success-ish outcomes as ok.
        if GG.GetProvider and GG.GetProvider(GS.PROVIDER_ID) then
            providerRegistered = true
            return true
        end
        DebugWarn("provider register failed: %s", tostring(err))
        return false, err
    end
    if GG.SetProviderEnabled then
        GG.SetProviderEnabled(GS.PROVIDER_ID, true)
    end
    providerRegistered = true
    RebuildExportIndex()
    DebugInfo("registered staged config provider id=%s", GS.PROVIDER_ID)
    return true
end

function GS:DisableGossipProvider()
    if GG and GG.UnregisterProvider then
        GG.UnregisterProvider(GS.PROVIDER_ID)
    end
    providerRegistered = false
    -- Invalidate any queued maint closure before clearing export arrays.
    exportState.maintGeneration = (tonumber(exportState.maintGeneration) or 0) + 1
    exportState.maintIdle = true
    exportState.maintScheduled = false
    exportState.opBuildNeeded = false
    exportState.evidenceBuildNeeded = false
    exportState.archiveBuildNeeded = false
    exportState.ledgerBuildNeeded = false
    exportState.donationEvidenceBuildNeeded = false
    exportState.valuationBuildNeeded = false
    exportState.valuationBuildCursor = nil
    exportState.opBuildCursor = nil
    exportState.archiveBuildCursor = nil
    exportState.ledgerBuildCursor = nil
    exportState.ledgerBuildPhase = nil
    exportState.ledgerWarmPos = 0
    exportState.ledgerArchiveWarmPos = 0
    exportState.donationEvidenceBuildCursor = nil
    exportState.pendingCursor = nil
    exportState.conflictCursor = nil
    exportState.openConflictCursor = nil
    exportState.openConflictPartialKey = nil
    exportState.openConflictCandidatePos = nil
    exportState.order = {}
    exportState.byId = {}
    exportState.enumPos = nil
    exportState.guildKey = nil
    exportState.datasetId = nil
    ResetArchivePageBuffers()
end

ScheduleExportMaintContinuation = function()
    if exportState.maintScheduled or exportState.maintIdle then
        return
    end
    if not providerRegistered then
        return
    end
    -- Nested schedule from Notify while sync-draining is a no-op; the outer loop continues.
    if GS._exportMaintSyncDraining then
        return
    end
    -- Harness / no-timer environments may sync-drain paced construction.
    if GS._exportMaintSyncDrain or not (C_Timer and C_Timer.After) then
        GS._exportMaintSyncDraining = true
        local guard = 0
        local maxGuard = 256
        while not exportState.maintIdle and providerRegistered and guard < maxGuard do
            guard = guard + 1
            local gen = tonumber(exportState.maintGeneration) or 0
            GS.NotifyLocalDurableChange("export-maint")
            if (tonumber(exportState.maintGeneration) or 0) ~= gen then
                break
            end
        end
        GS._exportMaintSyncDraining = false
        return
    end
    exportState.maintScheduled = true
    local gen = tonumber(exportState.maintGeneration) or 0
    local function cont()
        exportState.maintScheduled = false
        if (tonumber(exportState.maintGeneration) or 0) ~= gen then
            return
        end
        if exportState.maintIdle or not providerRegistered then
            return
        end
        GS.NotifyLocalDurableChange("export-maint")
    end
    C_Timer.After(0, cont)
end

function GS._exportMaintIsIdle()
    return exportState.maintIdle == true and not exportState.maintScheduled
end

-- Coalesce NotifyLocalDurableChange during a completed bank-log snapshot (or
-- any other short local batch). Nested ledger/evidence/valuation notifies defer
-- export rebuild + NotifyProviderChanged until EndLocalDurableNotifyBatch.
local DURABLE_NOTIFY_REASON_RANK = {
    ["export-maint"] = 0,
    evidence = 40,
    ["remote-evidence"] = 40,
    ["remote-pending"] = 40,
    ["remote-conflict"] = 45,
    ["remote-confirm"] = 45,
    ["remote-resolve"] = 45,
    config = 45,
    campaign = 45,
    ["remote-op"] = 45,
    valuation = 50,
    ledger = 50,
    create = 60,
    confirm = 60,
    activation = 100,
    adoption = 100,
    install = 100,
    dataset = 100,
}

PreferDurableNotifyReason = function(current, incoming)
    if type(current) ~= "string" or current == "" then
        return incoming
    end
    if type(incoming) ~= "string" or incoming == "" then
        return current
    end
    local cr = DURABLE_NOTIFY_REASON_RANK[current] or 10
    local ir = DURABLE_NOTIFY_REASON_RANK[incoming] or 10
    if ir >= cr then
        return incoming
    end
    return current
end

--- Begin coalescing durable/export notifications. Nested calls nest.
function GS.BeginLocalDurableNotifyBatch()
    durableNotifyBatchDepth = (tonumber(durableNotifyBatchDepth) or 0) + 1
end

--- Flush one coalesced NotifyLocalDurableChange when the outermost batch ends.
function GS.EndLocalDurableNotifyBatch()
    local depth = tonumber(durableNotifyBatchDepth) or 0
    if depth <= 0 then
        durableNotifyBatchDepth = 0
        durableNotifyBatchPending = nil
        return
    end
    depth = depth - 1
    durableNotifyBatchDepth = depth
    if depth > 0 then
        return
    end
    local pending = durableNotifyBatchPending
    durableNotifyBatchPending = nil
    if pending and GS.NotifyLocalDurableChange then
        GS.NotifyLocalDurableChange(pending)
    end
end

-- Settings / page UI listeners for authoritative durable-state changes.
-- Export-maintenance continuations must not poke the UI.
local uiListeners = {}
local uiNotifying = false
local uiNotifyQueued = false
local uiNotifyQueuedReason = nil

function GS.RegisterUIListener(fn)
    if type(fn) ~= "function" then
        return nil
    end
    uiListeners[#uiListeners + 1] = fn
    return fn
end

local function DeliverUINotify(reason)
    if uiNotifying then
        return
    end
    uiNotifying = true
    for i = 1, #uiListeners do
        local fn = uiListeners[i]
        if type(fn) == "function" then
            pcall(fn, reason)
        end
    end
    uiNotifying = false
end

--- Settings/UI poke after durable GS state changes (not export-maint).
-- Delivers synchronously with a re-entrancy follow-up (Consumables NotifyUI
-- style). Bank-snapshot Begin/End batching already coalesces export work before
-- a single NotifyUI; visible pages further coalesce via their QueueRefresh.
function GS.NotifyUI(reason)
    reason = tostring(reason or "local")
    if reason == "export-maint" then
        return
    end
    if #uiListeners == 0 then
        return
    end
    if uiNotifying then
        uiNotifyQueuedReason = PreferDurableNotifyReason(uiNotifyQueuedReason, reason)
        uiNotifyQueued = true
        return
    end
    DeliverUINotify(reason)
    while uiNotifyQueued do
        uiNotifyQueued = false
        local queued = uiNotifyQueuedReason
        uiNotifyQueuedReason = nil
        if queued then
            DeliverUINotify(queued)
        end
    end
end

--- Required after provider-owned durable storage changes outside engine append.
-- Adoption / dataset replacement rebuilds the full export index and drops stale
-- IDs. Ordinary accepted ops upsert incrementally so catch-up stays bounded.
function GS.NotifyLocalDurableChange(reason)
    reason = tostring(reason or "local")
    -- Bank-snapshot (and similar) batches coalesce redundant export work.
    if (tonumber(durableNotifyBatchDepth) or 0) > 0 then
        durableNotifyBatchPending = PreferDurableNotifyReason(durableNotifyBatchPending, reason)
        return
    end
    -- Disabled / unregistered providers must not rebuild export state from
    -- stale Notify calls (queued maint is invalidated via maintGeneration).
    if not providerRegistered then
        -- Still poke Settings when activation/config retires pages even if the
        -- gossip provider is not registered yet.
        if reason ~= "export-maint" then
            GS.NotifyUI(reason)
        end
        return
    end
    local record, guildKey = CurrentGuildRecord()
    local localGuid = LocalExportWitnessGuid()
    local fullRebuild = reason == "adoption"
        or reason == "install"
        or reason == "dataset"
        or not record
        or exportState.guildKey ~= guildKey
        or exportState.datasetId ~= (record and record.datasetId)
        or exportState.epoch ~= (tonumber(GS._adoptionEpoch) or 0)
        or exportState.localGuid ~= localGuid

    if fullRebuild then
        local prevOrder = exportState.order
        RebuildExportIndex()
        -- After dataset replacement, bump the gossip index epoch so peers drop
        -- stale record IDs that no longer exist in the rebuilt export.
        if GG and GG.GetProvider and providerRegistered then
            local prov = GG.GetProvider(GS.PROVIDER_ID)
            local index = prov and prov.index
            if index and GG.BumpIndexEpoch then
                local stale = false
                for i = 1, #prevOrder do
                    local id = prevOrder[i]
                    if not exportState.byId[id] then
                        stale = true
                        break
                    end
                end
                if stale or reason == "adoption" or reason == "install" then
                    GG.BumpIndexEpoch(index)
                    index.buildComplete = false
                    index.dirty = true
                end
            end
        end
        -- Pace deferred accepted-op / evidence / archive / ledger construction
        -- after cold rebuild.
        if exportState.archiveBuildNeeded
            or exportState.opBuildNeeded
            or exportState.evidenceBuildNeeded
            or exportState.ledgerBuildNeeded
            or exportState.donationEvidenceBuildNeeded
            or exportState.valuationBuildNeeded then
            exportState.maintIdle = false
            ScheduleExportMaintContinuation()
        end
    elseif record then
        -- Remote evidence/conflict retention can insert keys that sort before a
        -- saved cursor; force another evidence pass without a full rebuild.
        if reason == "remote-evidence" or reason == "remote-conflict"
            or reason == "remote-pending" or reason == "remote-confirm"
            or reason == "remote-resolve" then
            exportState.evidenceBuildNeeded = true
            -- Restart evidence key cursors so newly inserted earlier keys are
            -- not skipped; accepted-op / archive paced cursors are unchanged.
            exportState.pendingCursor = nil
            exportState.conflictCursor = nil
            exportState.openConflictCursor = nil
            exportState.openConflictPartialKey = nil
            exportState.openConflictCandidatePos = nil
            exportState.maintIdle = false
        end
        -- #388 staged ledger / donation evidence: upsert recent accepted events
        -- and any new direct observations (never re-export relays).
        -- Config/remote-op/campaign paths also append ledger rows (adjustments,
        -- link-triggered verification) and must advertise them for adoption.
        -- Activation revisits already-exported ledger rows so verified production
        -- rows can advertise cutoverMarker; uncredited staged rows stay unmarked.
        if reason == "activation" then
            exportState.ledgerWarmPos = 0
        end
        if reason == "activation" or reason == "ledger" or reason == "evidence"
            or reason == "config" or reason == "remote-op" or reason == "campaign" then
            local events = record.accounting and record.accounting._consumableEvents
            if type(events) ~= "table" then
                events = {}
            end
            local archive = record.accounting and record.accounting._consumableEventArchive
            if type(archive) ~= "table" then
                archive = {}
            end
            -- High-water mark: export every not-yet-seen live row. When more
            -- than 32 events arrive between notifications, hand the backlog
            -- to the paced cold builder instead of dropping older IDs.
            -- Shelving (campaign rollover / capacity) replaces the live array with
            -- a shorter kept list; hw can then exceed #events and skip new rows.
            -- Reconcile by resetting warm pos and re-running archive→live paced
            -- construction so newly shelved + new live IDs stay exportable.
            -- Late historical quorum appends grow the archive without shrinking
            -- live; restart paced archive drain from the archive high-water so
            -- descriptor acceptedLedgerCount cannot exceed exported IDs.
            local hw = tonumber(exportState.ledgerWarmPos) or 0
            local nLive = #events
            local nArch = #archive
            local archHw = tonumber(exportState.ledgerArchiveWarmPos) or 0
            if hw > nLive or nArch < archHw then
                -- Live shrink (shelve) or archive trim: rebuild archive→live.
                exportState.ledgerBuildNeeded = true
                exportState.ledgerBuildPhase = "archive"
                exportState.ledgerBuildCursor = 1
                hw = 0
                exportState.ledgerWarmPos = 0
                exportState.ledgerArchiveWarmPos = 0
                archHw = 0
            elseif nArch > archHw then
                -- Archive grew without live shrink (AppendArchivedLedgerEvent).
                exportState.ledgerBuildNeeded = true
                if exportState.ledgerBuildPhase ~= "archive" then
                    exportState.ledgerBuildPhase = "archive"
                    exportState.ledgerBuildCursor = archHw + 1
                elseif exportState.ledgerBuildCursor == nil then
                    exportState.ledgerBuildCursor = archHw + 1
                end
            end
            local start = math.max(1, nLive - 31)
            if hw + 1 < start then
                exportState.ledgerBuildNeeded = true
                if exportState.ledgerBuildCursor == nil then
                    exportState.ledgerBuildPhase = exportState.ledgerBuildPhase or "live"
                    exportState.ledgerBuildCursor = hw + 1
                elseif exportState.ledgerBuildPhase == "live"
                    and (tonumber(exportState.ledgerBuildCursor) or 1) > nLive then
                    -- Stale live cursor after shrink: restart from the backlog.
                    exportState.ledgerBuildCursor = hw + 1
                end
            else
                start = hw + 1
            end
            local liveMarker = nil
            if GS.IsLiveActive and GS.IsLiveActive(record)
                and type(record.liveCutover) == "table"
                and type(record.liveCutover.cutoverMarker) == "string" then
                liveMarker = record.liveCutover.cutoverMarker
            end
            -- Provenance reconcile can upgrade already-exported rows; revisit the
            -- recent live window so cutoverMarker tracks verified credit only.
            if liveMarker then
                start = math.min(start, math.max(1, nLive - 31))
            end
            for i = start, nLive do
                local event = events[i]
                if type(event) == "table" and type(event.id) == "string" then
                    UpsertLedgerEventExport(
                        "gs:le:" .. event.id,
                        record.datasetId,
                        event,
                        ExportCutoverMarkerForEvent(event, liveMarker))
                end
            end
            exportState.ledgerWarmPos = nLive
            local warmGuid = localGuid or LocalExportWitnessGuid()
            local directExports = record.observations and record.observations.directExports
            if type(directExports) == "table" then
                for exportId, row in pairs(directExports) do
                    if type(exportId) == "string" and type(row) == "table"
                        and type(row.evidence) == "table"
                        and DirectExportOwnedByLocal(row, warmGuid)
                        and not exportState.byId[exportId] then
                        UpsertExportBody(exportId, {
                            kind = "gs-evidence",
                            datasetId = record.datasetId,
                            campaignId = row.campaignId,
                            evidence = row.evidence,
                            -- Diagnostic only; ValidateAndApply votes the
                            -- authenticated transport sender, never this field.
                            observedBy = row.witnessGuid,
                        })
                    end
                end
            end
            exportState.maintIdle = false
            exportState.countsDirty = true
            if exportState.ledgerBuildNeeded and ScheduleExportMaintContinuation then
                ScheduleExportMaintContinuation()
            end
        end
        -- Incremental / paced cold drain. Budget covers BuildOpExportBodies work
        -- (serialization while packing) as well as index enumeration.
        local ops = record.operations
        local slice = GS.MAX_EXPORT_MAINT_PER_SLICE or 32
        local used = 0
        local function upsertEvidence(cid, boundaryHint)
            if type(cid) ~= "string" then
                return false
            end
            local exportId = "gs:op:" .. cid
            local existing = exportState.byId[exportId]
            if existing and existing.body and existing.body.evidenceOnly ~= true then
                return false
            end
            if ops.records and ops.records[cid] then
                return false
            end
            local cand = (ops.pending and ops.pending[cid] and ops.pending[cid].body)
                or (ops.conflicts and ops.conflicts[cid] and ops.conflicts[cid].body)
            if type(cand) ~= "table" then
                return false
            end
            local header = nil
            if cand.kind == GS.KIND.START_CAMPAIGN then
                header = boundaryHint
                    or (record.campaigns and record.campaigns[cid])
                    or (GS._pendingCampaignBoundaries and GS._pendingCampaignBoundaries[cid])
            end
            local parts = BuildOpExportBodies(cand, true, header)
            used = used + math.max(0, #parts - 1)
            for pi = 1, #parts do
                UpsertExportBody(parts[pi].id, parts[pi].body)
            end
            return true
        end
        local function sortedKeys(map)
            local keys = {}
            if type(map) == "table" then
                for k in pairs(map) do
                    keys[#keys + 1] = k
                end
                table.sort(keys, function(a, b)
                    return tostring(a) < tostring(b)
                end)
            end
            return keys
        end
        -- Resume after the last completed key (not a positional index). When the
        -- saved key was deleted, continue from the next surviving sorted key so
        -- newly inserted earlier keys are not permanently skipped.
        local function resumeAfterKey(keys, cursorKey, exportIdForKey)
            if cursorKey == nil or cursorKey == "" then
                return 1
            end
            cursorKey = tostring(cursorKey)
            local startK = #keys + 1
            for ki = 1, #keys do
                if tostring(keys[ki]) == cursorKey then
                    startK = ki + 1
                    break
                end
            end
            if startK > #keys then
                for ki = 1, #keys do
                    if tostring(keys[ki]) > cursorKey then
                        startK = ki
                        break
                    end
                end
            end
            -- Inserted keys that sort before the saved cursor must not be skipped.
            if type(exportIdForKey) == "function" and startK > 1 then
                for ki = 1, startK - 1 do
                    local eid = exportIdForKey(keys[ki])
                    if type(eid) == "string" and not exportState.byId[eid] then
                        return 1
                    end
                end
            end
            return startK
        end

        -- Cold / rebuild: resume accepted-op construction under slice budget.
        if type(ops) == "table" and type(ops.order) == "table" and exportState.opBuildNeeded then
            local start = math.max(1, tonumber(exportState.opBuildCursor) or 1)
            for i = start, #ops.order do
                if used >= slice then
                    exportState.opBuildCursor = i
                    break
                end
                local oid = ops.order[i]
                local exportId = "gs:op:" .. oid
                local op = ops.records and ops.records[oid]
                used = used + 1 -- charge serialization/search work even on skip
                if type(op) == "table" then
                    local existing = exportState.byId[exportId]
                    local mustReplace = existing
                        and existing.body
                        and existing.body.evidenceOnly == true
                    if not existing or mustReplace then
                        local boundary = nil
                        if op.kind == GS.KIND.START_CAMPAIGN then
                            boundary = record.campaigns and record.campaigns[op.id]
                        end
                        local parts = BuildOpExportBodies(op, false, boundary)
                        -- Charge fragment construction work, not one unit per op.
                        used = used + math.max(0, #parts - 1)
                        for pi = 1, #parts do
                            UpsertExportBody(parts[pi].id, parts[pi].body)
                        end
                    end
                end
                exportState.opBuildCursor = i + 1
                exportState.appendPos = i
            end
            if used < slice then
                exportState.opBuildCursor = nil
                exportState.opBuildNeeded = false
                exportState.appendPos = #ops.order
            end
        elseif type(ops) == "table" and type(ops.order) == "table" then
            -- Warm append: only new accepted ops after appendPos.
            local start = math.max(1, (tonumber(exportState.appendPos) or 0) + 1)
            for i = start, #ops.order do
                if used >= slice then
                    exportState.opBuildNeeded = true
                    exportState.opBuildCursor = i
                    break
                end
                local oid = ops.order[i]
                local exportId = "gs:op:" .. oid
                local op = ops.records and ops.records[oid]
                used = used + 1
                if type(op) == "table" then
                    local existing = exportState.byId[exportId]
                    local mustReplace = existing
                        and existing.body
                        and existing.body.evidenceOnly == true
                    if not existing or mustReplace then
                        local boundary = nil
                        if op.kind == GS.KIND.START_CAMPAIGN then
                            boundary = record.campaigns and record.campaigns[op.id]
                        end
                        local parts = BuildOpExportBodies(op, false, boundary)
                        -- Charge fragment construction work, not one unit per op.
                        used = used + math.max(0, #parts - 1)
                        for pi = 1, #parts do
                            UpsertExportBody(parts[pi].id, parts[pi].body)
                        end
                    end
                end
                exportState.appendPos = i
            end
            if used < slice or exportState.appendPos >= #ops.order then
                exportState.appendPos = #ops.order
                exportState.opBuildNeeded = false
                exportState.opBuildCursor = nil
            end
        end

        if used < slice and type(ops) == "table" then
            if type(ops.openConflicts) == "table" then
                local ocKeys = sortedKeys(ops.openConflicts)
                -- Completion is keyed by real exported candidate IDs, not synthetic
                -- gs:oc: tokens (those IDs are never emitted).
                local function openConflictKeyExported(targetKey)
                    local oc = ops.openConflicts[targetKey]
                    if type(oc) ~= "table" or type(oc.candidateIds) ~= "table" then
                        return true
                    end
                    for ci = 1, #oc.candidateIds do
                        local cid = oc.candidateIds[ci]
                        if type(cid) == "string" then
                            local eid = "gs:op:" .. cid
                            if exportState.byId[eid] then
                                -- exported
                            elseif ops.records and ops.records[cid] then
                                -- accepted head; no evidence body required
                            else
                                local hasBody = (ops.pending and ops.pending[cid])
                                    or (ops.conflicts and ops.conflicts[cid])
                                if hasBody then
                                    return false
                                end
                            end
                        end
                    end
                    return true
                end
                local ocStart = resumeAfterKey(ocKeys, exportState.openConflictCursor, function(k)
                    -- Drive prefix re-scan from the first missing candidate export id.
                    local oc = ops.openConflicts[k]
                    if type(oc) ~= "table" or type(oc.candidateIds) ~= "table" then
                        return nil
                    end
                    for ci = 1, #oc.candidateIds do
                        local cid = oc.candidateIds[ci]
                        if type(cid) == "string" then
                            local eid = "gs:op:" .. cid
                            if not exportState.byId[eid]
                                and not (ops.records and ops.records[cid]) then
                                local hasBody = (ops.pending and ops.pending[cid])
                                    or (ops.conflicts and ops.conflicts[cid])
                                if hasBody then
                                    return eid
                                end
                            end
                        end
                    end
                    -- Fully exported: return a present id so resumeAfterKey keeps progress.
                    for ci = #oc.candidateIds, 1, -1 do
                        local cid = oc.candidateIds[ci]
                        if type(cid) == "string" and exportState.byId["gs:op:" .. cid] then
                            return "gs:op:" .. cid
                        end
                    end
                    return nil
                end)
                -- Resume mid-entry candidate work without marking the key complete.
                local startCand = 1
                if type(exportState.openConflictPartialKey) == "string" then
                    local foundPartial = false
                    for ki = 1, #ocKeys do
                        if ocKeys[ki] == exportState.openConflictPartialKey then
                            ocStart = ki
                            startCand = math.max(1, tonumber(exportState.openConflictCandidatePos) or 1)
                            foundPartial = true
                            break
                        end
                    end
                    if not foundPartial then
                        exportState.openConflictPartialKey = nil
                        exportState.openConflictCandidatePos = nil
                        startCand = 1
                    end
                end
                for ki = ocStart, #ocKeys do
                    if used >= slice then
                        exportState.evidenceBuildNeeded = true
                        break
                    end
                    local entry = ops.openConflicts[ocKeys[ki]]
                    local entryDone = true
                    if type(entry) == "table" and type(entry.candidateIds) == "table" then
                        local candStart = (ki == ocStart) and startCand or 1
                        for i = candStart, #entry.candidateIds do
                            if used >= slice then
                                exportState.openConflictPartialKey = ocKeys[ki]
                                exportState.openConflictCandidatePos = i
                                exportState.evidenceBuildNeeded = true
                                entryDone = false
                                break
                            end
                            upsertEvidence(entry.candidateIds[i],
                                entry.boundaries and entry.boundaries[entry.candidateIds[i]])
                            used = used + 1
                        end
                    else
                        used = used + 1
                    end
                    if not entryDone then
                        break
                    end
                    -- Only advance the completed-key cursor after the full candidate list.
                    exportState.openConflictCursor = ocKeys[ki]
                    exportState.openConflictPartialKey = nil
                    exportState.openConflictCandidatePos = nil
                    if not openConflictKeyExported(ocKeys[ki]) then
                        exportState.evidenceBuildNeeded = true
                    end
                end
                if used < slice
                    and exportState.openConflictPartialKey == nil then
                    exportState.openConflictCursor = nil
                    exportState.openConflictCandidatePos = nil
                end
            end
            if used < slice and type(ops.order) == "table" then
                local resStart = math.max(1, (tonumber(exportState.resolveScanPos) or 0) + 1)
                for i = resStart, #ops.order do
                    if used >= slice then
                        exportState.evidenceBuildNeeded = true
                        break
                    end
                    local op = ops.records and ops.records[ops.order[i]]
                    exportState.resolveScanPos = i
                    used = used + 1
                    if type(op) == "table" and op.kind == GS.KIND.RESOLVE_CONFLICT
                        and type(op.value) == "table" then
                        if type(op.value.chosenOpId) == "string" then
                            upsertEvidence(op.value.chosenOpId, nil)
                        end
                        if type(op.value.competingOpIds) == "table" then
                            for j = 1, #op.value.competingOpIds do
                                if used >= slice then
                                    exportState.evidenceBuildNeeded = true
                                    break
                                end
                                upsertEvidence(op.value.competingOpIds[j], nil)
                                used = used + 1
                            end
                        end
                    end
                end
            end
            if used < slice and type(ops.pending) == "table" then
                local keys = sortedKeys(ops.pending)
                local startK = resumeAfterKey(keys, exportState.pendingCursor, function(k)
                    return "gs:op:" .. tostring(k)
                end)
                for ki = startK, #keys do
                    if used >= slice then
                        exportState.pendingCursor = keys[math.max(1, ki - 1)]
                        if ki == startK then
                            exportState.pendingCursor = keys[ki]
                        end
                        exportState.evidenceBuildNeeded = true
                        break
                    end
                    upsertEvidence(keys[ki], nil)
                    used = used + 1
                    exportState.pendingCursor = keys[ki]
                end
                if used < slice then
                    exportState.pendingCursor = nil
                end
            end
            if used < slice and type(ops.conflicts) == "table" then
                local keys = sortedKeys(ops.conflicts)
                local startK = resumeAfterKey(keys, exportState.conflictCursor, function(k)
                    return "gs:op:" .. tostring(k)
                end)
                for ki = startK, #keys do
                    if used >= slice then
                        exportState.conflictCursor = keys[math.max(1, ki - 1)]
                        if ki == startK then
                            exportState.conflictCursor = keys[ki]
                        end
                        exportState.evidenceBuildNeeded = true
                        break
                    end
                    upsertEvidence(keys[ki], nil)
                    used = used + 1
                    exportState.conflictCursor = keys[ki]
                end
                if used < slice then
                    exportState.conflictCursor = nil
                end
            end
            if used < slice
                and exportState.pendingCursor == nil
                and exportState.conflictCursor == nil
                and exportState.openConflictCursor == nil
                and exportState.openConflictPartialKey == nil then
                exportState.evidenceBuildNeeded = false
            end
        end

        if type(record.campaigns) == "table" then
            for campaignId, header in pairs(record.campaigns) do
                if type(campaignId) == "string" and type(header) == "table" then
                    local exportId = "gs:ch:" .. campaignId
                    if not exportState.byId[exportId] then
                        UpsertExportBody(exportId, {
                            kind = "campaign-header",
                            header = header,
                        })
                    end
                end
            end
        end
        -- Archives: paced construction (also drains cold-rebuild backlog).
        if type(record.campaignArchives) == "table" and used < slice then
            local keys = {}
            for campaignId, archive in pairs(record.campaignArchives) do
                if type(campaignId) == "string" and type(archive) == "table" then
                    keys[#keys + 1] = campaignId
                end
            end
            table.sort(keys)
            local startK = resumeAfterKey(keys, exportState.archiveBuildCursor, function(k)
                return "gs:ca:" .. tostring(k)
            end)
            for ki = startK, #keys do
                if used >= slice then
                    exportState.archiveBuildCursor = keys[math.max(1, ki - 1)]
                    if ki == startK then
                        exportState.archiveBuildCursor = keys[ki]
                    end
                    exportState.archiveBuildNeeded = true
                    break
                end
                local campaignId = keys[ki]
                local archive = record.campaignArchives[campaignId]
                local metaId = "gs:ca:" .. campaignId
                used = used + 1
                if not exportState.byId[metaId] then
                    local parts = BuildArchiveExportBodies(campaignId, archive, record)
                    for i = 1, #parts do
                        if not exportState.byId[parts[i].id] then
                            UpsertExportBody(parts[i].id, parts[i].body)
                        end
                    end
                end
                exportState.archiveBuildCursor = keys[ki]
            end
            if used < slice then
                exportState.archiveBuildCursor = nil
                exportState.archiveBuildNeeded = false
            end
        end

        -- #388 cold/reload: pace accepted ledger history into the export index.
        -- Archive phase first (prior generations), then live current-generation.
        if exportState.ledgerBuildNeeded and used < slice then
            local coldMarker = nil
            if GS.IsLiveActive and GS.IsLiveActive(record)
                and type(record.liveCutover) == "table"
                and type(record.liveCutover.cutoverMarker) == "string" then
                coldMarker = record.liveCutover.cutoverMarker
            end
            local function upsertLedgerList(list, startAt)
                local start = math.max(1, tonumber(startAt) or 1)
                if type(list) ~= "table" then
                    return nil, true
                end
                for i = start, #list do
                    if used >= slice then
                        return i, false
                    end
                    local event = list[i]
                    used = used + 1
                    if type(event) == "table" and type(event.id) == "string" then
                        UpsertLedgerEventExport(
                            "gs:le:" .. event.id,
                            record.datasetId,
                            event,
                            ExportCutoverMarkerForEvent(event, coldMarker))
                    end
                    exportState.ledgerBuildCursor = i + 1
                end
                return nil, true
            end
            local phase = exportState.ledgerBuildPhase or "archive"
            if phase == "archive" then
                local archive = record.accounting and record.accounting._consumableEventArchive
                local cursor, done = upsertLedgerList(archive, exportState.ledgerBuildCursor)
                if not done then
                    exportState.ledgerBuildCursor = cursor
                    exportState.ledgerBuildPhase = "archive"
                else
                    exportState.ledgerArchiveWarmPos = type(archive) == "table" and #archive or 0
                    exportState.ledgerBuildPhase = "live"
                    exportState.ledgerBuildCursor = 1
                    phase = "live"
                end
            end
            if phase == "live" and used < slice then
                local events = record.accounting and record.accounting._consumableEvents
                local liveCursor = tonumber(exportState.ledgerBuildCursor) or 1
                if type(events) ~= "table" then
                    events = {}
                end
                -- Shelving can shrink the live list under an in-flight live cursor.
                if liveCursor > #events + 1 then
                    liveCursor = 1
                    exportState.ledgerBuildCursor = 1
                end
                local cursor, done = upsertLedgerList(events, liveCursor)
                if not done then
                    exportState.ledgerBuildCursor = cursor
                    exportState.ledgerBuildPhase = "live"
                else
                    exportState.ledgerBuildCursor = nil
                    exportState.ledgerBuildPhase = nil
                    exportState.ledgerBuildNeeded = false
                    exportState.ledgerWarmPos = #events
                    local archDone = record.accounting and record.accounting._consumableEventArchive
                    exportState.ledgerArchiveWarmPos = type(archDone) == "table" and #archDone or 0
                end
            end
        end

        -- #388 cold/reload: pace direct local observations (not relays).
        -- Only the current authenticated character's rows may be cold-exported.
        if exportState.donationEvidenceBuildNeeded and used < slice then
            local coldGuid = exportState.localGuid or LocalExportWitnessGuid()
            local directExports = record.observations and record.observations.directExports
            if type(directExports) == "table" then
                local keys = sortedKeys(directExports)
                local startK = resumeAfterKey(keys, exportState.donationEvidenceBuildCursor, function(k)
                    return tostring(k)
                end)
                for ki = startK, #keys do
                    if used >= slice then
                        exportState.donationEvidenceBuildCursor = keys[math.max(1, ki - 1)]
                        if ki == startK then
                            exportState.donationEvidenceBuildCursor = keys[ki]
                        end
                        break
                    end
                    local exportId = keys[ki]
                    local row = directExports[exportId]
                    used = used + 1
                    if type(exportId) == "string" and type(row) == "table"
                        and type(row.evidence) == "table"
                        and DirectExportOwnedByLocal(row, coldGuid)
                        and not exportState.byId[exportId] then
                        UpsertExportBody(exportId, {
                            kind = "gs-evidence",
                            datasetId = record.datasetId,
                            campaignId = row.campaignId,
                            evidence = row.evidence,
                            observedBy = row.witnessGuid,
                        })
                    end
                    exportState.donationEvidenceBuildCursor = keys[ki]
                end
                if used < slice then
                    exportState.donationEvidenceBuildCursor = nil
                    exportState.donationEvidenceBuildNeeded = false
                end
            else
                exportState.donationEvidenceBuildCursor = nil
                exportState.donationEvidenceBuildNeeded = false
            end
        end

        -- #397 cold/reload: pace accepted valuation snapshots. Updates to an
        -- existing winner go through NoteValuationExported; this drain fills gaps.
        if exportState.valuationBuildNeeded and used < slice then
            local byTxn = record.valuations and record.valuations.byTxn
            if type(byTxn) == "table" then
                local keys = sortedKeys(byTxn)
                local startK = resumeAfterKey(keys, exportState.valuationBuildCursor, function(k)
                    return "gs:val:" .. tostring(k)
                end)
                for ki = startK, #keys do
                    if used >= slice then
                        exportState.valuationBuildCursor = keys[math.max(1, ki - 1)]
                        break
                    end
                    local txnId = keys[ki]
                    used = used + 1
                    local exportId = "gs:val:" .. tostring(txnId)
                    if type(txnId) == "string" and not exportState.byId[exportId]
                        and GS.BuildValuationExportBody then
                        local valBody = GS.BuildValuationExportBody(record, txnId)
                        if valBody then
                            UpsertExportBody(exportId, valBody)
                            NoteValuationManifestId(txnId)
                        end
                    end
                    exportState.valuationBuildCursor = txnId
                end
                if used < slice then
                    exportState.valuationBuildCursor = nil
                    exportState.valuationBuildNeeded = false
                end
            else
                exportState.valuationBuildCursor = nil
                exportState.valuationBuildNeeded = false
            end
        end

        exportState.maintIdle = used < slice
            and not exportState.opBuildNeeded
            and not exportState.evidenceBuildNeeded
            and not exportState.archiveBuildNeeded
            and not exportState.ledgerBuildNeeded
            and not exportState.donationEvidenceBuildNeeded
            and not exportState.valuationBuildNeeded
            and exportState.pendingCursor == nil
            and exportState.conflictCursor == nil
            and exportState.openConflictCursor == nil
            and exportState.openConflictPartialKey == nil
            and exportState.opBuildCursor == nil
            and exportState.archiveBuildCursor == nil
            and exportState.ledgerBuildCursor == nil
            and exportState.donationEvidenceBuildCursor == nil
            and exportState.valuationBuildCursor == nil

        -- Descriptor counts stay logical (durable store), not emitted-body counts.
        local acceptedOpCount = 0
        if type(ops) == "table" and type(ops.order) == "table" then
            acceptedOpCount = #ops.order
        end
        local evidenceExportCount = 0
        if type(ops) == "table" then
            if type(ops.pending) == "table" then
                for id in pairs(ops.pending) do
                    if not (ops.records and ops.records[id]) then
                        evidenceExportCount = evidenceExportCount + 1
                    end
                end
            end
            if type(ops.conflicts) == "table" then
                for id in pairs(ops.conflicts) do
                    if not (ops.pending and ops.pending[id])
                        and not (ops.records and ops.records[id]) then
                        evidenceExportCount = evidenceExportCount + 1
                    end
                end
            end
        end
        local transferOpCount = acceptedOpCount + evidenceExportCount
        local campaignCount = 0
        if type(record.campaigns) == "table" then
            for _ in pairs(record.campaigns) do
                campaignCount = campaignCount + 1
            end
        end
        local archiveCount = 0
        if type(record.campaignArchives) == "table" then
            for _ in pairs(record.campaignArchives) do
                archiveCount = archiveCount + 1
            end
        end
        local acceptedLedgerCount = 0
        if GS.CountAcceptedLedgerEvents then
            acceptedLedgerCount = GS.CountAcceptedLedgerEvents(record)
        else
            local events = record.accounting and record.accounting._consumableEvents
            local archive = record.accounting and record.accounting._consumableEventArchive
            if type(events) == "table" then
                acceptedLedgerCount = acceptedLedgerCount + #events
            end
            if type(archive) == "table" then
                acceptedLedgerCount = acceptedLedgerCount + #archive
            end
        end
        local donationEvidenceCount = 0
        local descGuid = exportState.localGuid or LocalExportWitnessGuid()
        local directExports = record.observations and record.observations.directExports
        if type(directExports) == "table" then
            for _, row in pairs(directExports) do
                if DirectExportOwnedByLocal(row, descGuid) then
                    donationEvidenceCount = donationEvidenceCount + 1
                end
            end
        end
        exportState.cachedOpCount = acceptedOpCount
        exportState.cachedTransferOpCount = transferOpCount
        exportState.cachedCampaignCount = campaignCount
        exportState.cachedArchiveCount = archiveCount
        exportState.cachedAcceptedLedgerCount = acceptedLedgerCount
        local valuationCount = ResolveValuationExportCount(record)
        exportState.cachedDonationEvidenceCount = donationEvidenceCount
        exportState.countsDirty = false
        local desc = {
            kind = "dataset-desc",
            schemaVersion = GS.PROVIDER_SCHEMA,
            guildKey = guildKey,
            datasetId = record.datasetId,
            editorRankPosition = record.permission and record.permission.editorRankPosition or nil,
            permissionRevisionId = record.permission and record.permission.revisionId or nil,
            bootstrapEditorRankPosition = (record.permission
                and record.permission.bootstrapEditorRankPosition)
                or (record.permission and record.permission.editorRankPosition)
                or nil,
            currentCampaignId = record.currentCampaignId,
            activation = record.activation,
            cutoverMarker = record.liveCutover and record.liveCutover.cutoverMarker or nil,
            liveCutover = GS.DescribeLiveCutover and GS.DescribeLiveCutover(record.liveCutover) or nil,
            acceptedOpCount = acceptedOpCount,
            transferOpCount = transferOpCount,
            campaignCount = campaignCount,
            archiveCount = archiveCount,
            acceptedLedgerCount = acceptedLedgerCount,
            donationEvidenceCount = donationEvidenceCount,
            valuationCount = valuationCount,
            bankTab = record.accounting and record.accounting._consumables
                and record.accounting._consumables.bankTab or nil,
            hasBankTab = true,
        }
        UpsertExportBody("gs:desc:" .. record.datasetId, desc)
        if not exportState.maintIdle then
            ScheduleExportMaintContinuation()
        end
    end

    if GG and GG.NotifyProviderChanged and providerRegistered then
        GG.NotifyProviderChanged(GS.PROVIDER_ID)
    end
    DebugInfo("provider changed reason=%s", reason)
    -- Visible Settings pages (and selection revalidation) listen here.
    -- Export-maintenance continuations must not drive continuous UI rebuilds.
    if reason ~= "export-maint" then
        GS.NotifyUI(reason)
    end
end

-- Hook Initialize to register the provider after the durable root is ready.
local _previousInitialize = GS.Initialize
function GS:Initialize(db)
    local ok, reason = true, nil
    if _previousInitialize then
        ok, reason = _previousInitialize(self, db)
    end
    -- Always attempt provider registration on initialize; gossip may idle with
    -- zero peers. Failure is non-fatal for local staged editing.
    GS:EnsureGossipProvider()
    return ok, reason
end
