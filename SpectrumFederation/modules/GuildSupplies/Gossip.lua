-- Guild Supplies staged configuration gossip provider (#387).
-- Registers through the production Guild Gossip API. Does not activate live
-- bank/accounting writers (#389) and does not carry donation evidence (#388).
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies
local GG = SF.GuildGossip

GS.PROVIDER_ID = GS.PROVIDER_ID or "sf.guildsupplies.config"
GS.PROVIDER_SCHEMA = GS.PROVIDER_SCHEMA or 1

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
    openConflictCursor = nil,
    maintScheduled = false,
    archiveBuildCursor = nil,
    -- Cold accepted-op construction cursor (BuildOpExportBodies is paced).
    opBuildCursor = nil,
    opBuildNeeded = false,
    evidenceBuildNeeded = false,
    -- Invalidates queued maint closures after disable/replacement.
    maintGeneration = 0,
}

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

-- Conservative wire budget under GG.MAX_RECORD_CBOR (2048) for archive pages.
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
local function BuildArchiveExportBodies(campaignId, archive, record)
    local out = {}
    local items = archive.requestedItems or {}
    local ids = SortedItemIds(items)
    local pageCount = math.max(1, math.ceil(math.max(#ids, 1) / ARCHIVE_PAGE_ITEMS))
    if #ids == 0 then
        pageCount = 1
    end
    local itemsFp = FingerprintBody(items)
    out[#out + 1] = {
        id = "gs:ca:" .. campaignId,
        body = {
            kind = "campaign-archive",
            campaignId = campaignId,
            datasetId = archive.datasetId or record.datasetId,
            generation = archive.generation,
            archivedAt = archive.archivedAt,
            schemaVersion = archive.schemaVersion or GS.SCHEMA_VERSION,
            itemCount = #ids,
            pageCount = pageCount,
            itemsFingerprint = itemsFp,
            -- Small archives still include items inline for compatibility.
            requestedItems = (#ids <= ARCHIVE_PAGE_ITEMS) and items or nil,
        },
    }
    if #ids > ARCHIVE_PAGE_ITEMS then
        for page = 1, pageCount do
            local slice = {}
            local start = (page - 1) * ARCHIVE_PAGE_ITEMS + 1
            local finish = math.min(#ids, page * ARCHIVE_PAGE_ITEMS)
            for i = start, finish do
                local iid = ids[i]
                slice[iid] = items[iid]
            end
            out[#out + 1] = {
                id = "gs:ca:" .. campaignId .. ":p" .. tostring(page),
                body = {
                    kind = "campaign-archive-page",
                    campaignId = campaignId,
                    datasetId = archive.datasetId or record.datasetId,
                    page = page,
                    pageCount = pageCount,
                    requestedItems = slice,
                },
            }
        end
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
        -- Ordinary oversized op: page only the large mutable payload.
        rows[1] = {
            id = op.id,
            body = {
                id = op.id,
                value = op.value,
                target = op.target,
            },
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
        local trialPage = {
            kind = "gs-op-page",
            opId = op.id,
            datasetId = op.datasetId,
            page = #pages + 1,
            pageCount = maxPages, -- reserve final pageCount wire space
            records = trialRecords,
        }
        if EstimateWireRecordBytes(exportId .. ":p" .. tostring(#pages + 1), trialPage) > budget then
            if #(cur.records) == 0 then
                DebugWarn("op export %s: row exceeds wire budget alone", tostring(op.id))
                return {}
            end
            flush()
            if #pages >= maxPages then
                DebugWarn("op export %s: exceeds max manifest pages", tostring(op.id))
                return {}
            end
            cur.records[1] = rows[i]
            local alone = {
                kind = "gs-op-page",
                opId = op.id,
                datasetId = op.datasetId,
                page = #pages + 1,
                pageCount = maxPages,
                records = cur.records,
            }
            if EstimateWireRecordBytes(exportId .. ":p" .. tostring(#pages + 1), alone) > budget then
                DebugWarn("op export %s: row exceeds wire budget alone", tostring(op.id))
                return {}
            end
        else
            cur.records[#cur.records + 1] = rows[i]
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
        shellOp.value = nil
        shellOp.target = nil
    end
    shellOp.pageCount = pageCount
    shellOp.recordCount = #rows

    local shellBody = {
        kind = "gs-op",
        op = shellOp,
        pageCount = pageCount,
        recordCount = #rows,
        evidenceOnly = evidenceOnly and true or nil,
        boundary = boundary,
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
    local rows = {}
    local seenIds = {}
    local pageOriginalIds = {}
    local pageCompetingOpIds = {}
    local totalBytes = 0
    local maxBytes = GS.MAX_FRAGMENT_ASSEMBLY_BYTES or 49152
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
            if type(row) ~= "table" or type(row.id) ~= "string" or row.id == ""
                or type(row.body) ~= "table" then
                return nil, "invalid_operation"
            end
            if seenIds[row.id] then
                return nil, "invalid_operation"
            end
            seenIds[row.id] = true
            rows[#rows + 1] = row
            -- Bound assembled payload by actual body bytes + id length.
            totalBytes = totalBytes + #row.id + EstimateBodyBytes(row.body)
            if totalBytes > maxBytes then
                return nil, "invalid_operation"
            end
        end
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
    return {
        kind = "gs-op",
        op = op,
        evidenceOnly = shellBody.evidenceOnly,
        boundary = shellBody.boundary,
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
    if type(raw) ~= "table" or raw.activation ~= GS.ACTIVATION_STAGED then
        return nil
    end
    return raw, ctx.guildKey
end

-- Forward-declared: cold registration and Notify both schedule archive drain.
local ScheduleExportMaintContinuation

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
        return
    end
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
        acceptedOpCount = 0,
        transferOpCount = 0,
        campaignCount = 0,
        archiveCount = 0,
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
    exportState.resolveScanPos = 0

    local descId = "gs:desc:" .. record.datasetId
    local descEntry = exportState.byId[descId]
    if type(descEntry) == "table" and type(descEntry.body) == "table" then
        descEntry.body.acceptedOpCount = acceptedOpCount
        descEntry.body.transferOpCount = transferOpCount
        descEntry.body.campaignCount = headerExportCount
        descEntry.body.archiveCount = archiveExportCount
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
    exportState.countsDirty = false
    exportState.appendPos = 0
    local needsMaint = exportState.archiveBuildNeeded
        or exportState.opBuildNeeded
        or exportState.evidenceBuildNeeded
    exportState.maintIdle = not needsMaint
    exportState.maintScheduled = false
    -- Cold registration /reload must drain deferred construction without an
    -- unrelated durable write (NotifyLocalDurableChange also schedules).
    if needsMaint and ScheduleExportMaintContinuation then
        ScheduleExportMaintContinuation()
    end
end

local function EnsureExportFresh()
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
        local maxPageCount = GS.MAX_ARCHIVE_PAGE_COUNT or 22
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
                    if n > (ARCHIVE_PAGE_ITEMS or 12) then
                        return "rejected", "invalid_campaign_archive"
                    end
                end
            end
        end
        local maxCamps = GS.MAX_FRAGMENT_BUFFER_ASSEMBLIES
            or GS.MAX_ARCHIVE_PAGE_BUFFER_CAMPAIGNS or 16
        local maxPages = GS.MAX_FRAGMENT_BUFFER_PAGES
            or GS.MAX_ARCHIVE_PAGE_BUFFER_PAGES or 64
        local now = GetServerTime and GetServerTime() or 0
        -- Reclaim expired assemblies across the whole pool before capacity checks.
        ReclaimExpiredFragmentBuffers({
            datasetId = body.datasetId,
            guildKey = localRecord and localRecord._guildKey,
        })
        local buf = archivePageBuffer[body.campaignId]
        if not buf then
            if (archivePageBufferCount or 0) >= maxCamps then
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
        if type(meta.requestedItems) == "table" then
            archive = {
                schemaVersion = meta.schemaVersion or GS.SCHEMA_VERSION,
                campaignId = meta.campaignId,
                datasetId = meta.datasetId,
                requestedItems = meta.requestedItems,
                generation = meta.generation,
                archivedAt = meta.archivedAt,
            }
        else
            local pageCount = tonumber(meta.pageCount) or tonumber(buf.pageCount) or 1
            if pageCount < 1 or pageCount ~= math.floor(pageCount) then
                ClearArchivePageBuffer(body.campaignId)
                return "rejected", "invalid_campaign_archive"
            end
            local merged, got = {}, 0
            for page = 1, pageCount do
                local p = buf.pages[page]
                if type(p) ~= "table" or type(p.requestedItems) ~= "table" then
                    return "pending", "missing_predecessor"
                end
                for k, v in pairs(p.requestedItems) do
                    merged[k] = v
                    got = got + 1
                end
            end
            if type(meta.itemCount) == "number" and got ~= meta.itemCount then
                return "pending", "missing_predecessor"
            end
            archive = {
                schemaVersion = meta.schemaVersion or GS.SCHEMA_VERSION,
                campaignId = meta.campaignId,
                datasetId = meta.datasetId,
                requestedItems = merged,
                generation = meta.generation,
                archivedAt = meta.archivedAt,
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
        if not buf then
            if (opManifestBufferCount or 0) >= maxCamps then
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
        if buf.pages[page] then
            if GS._DeepEqualOps and not GS._DeepEqualOps(buf.pages[page], body) then
                ClearOpManifestBuffer(opId)
                return "rejected", "id_conflict"
            end
        else
            if (opManifestBufferPages or 0) >= maxPagesBuf then
                return "rejected", "full"
            end
            opManifestBufferPages = (opManifestBufferPages or 0) + 1
            buf.pages[page] = body
        end
        buf.at = now
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
        -- Paged shell: retain fragment buffer until pages arrive.
        local pageCount = tonumber(body.pageCount) or tonumber(op.pageCount)
        if pageCount and pageCount >= 1 and (
            (op.kind == GS.KIND.CONFIRM_CANDIDATE
                and (not op.candidateRef or not op.candidateRef.body)
                and not (op.candidateRef and op.candidateRef.records
                    and op.candidateRef.records[1] and op.candidateRef.records[1].body))
            or (op.kind == GS.KIND.RESOLVE_CONFLICT
                and (not op.value or type(op.value.contentBodies) ~= "table"))
        ) then
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
                if (opManifestBufferCount or 0) >= maxCamps then
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
            buf.shell = body
            buf.pageCount = pageCount
            buf.at = now
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
            local ranks = GG and GG.GetGuildRanks and GG.GetGuildRanks()
            local rankCount = type(ranks) == "table" and tonumber(ranks.count) or nil
            local policyOk = type(perm) == "table"
                and type(perm.revisionId) == "string" and perm.revisionId ~= ""
                and integralPos
                and (not rankCount or rawPos <= rankCount)
            requireRecover = not policyOk
        end
        -- Policy catch-up: while bootstrap-locked, evaluate authority with
        -- allowPolicyCatchUp when the body is a causal policy successor under
        -- the current predecessor policy. Do not mark those as relay — Admit
        -- validates each transition under the predecessor policy.
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
        return GS:AdmitRemoteOperation(op, {
            sender = sender,
            member = member,
            boundary = body.boundary,
            relay = relay,
        })
    end

    return "rejected", "unsupported_kind"
end

---------------------------------------------------------------------------
-- Registration / notification
---------------------------------------------------------------------------

local providerRegistered = false

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
    exportState.opBuildCursor = nil
    exportState.archiveBuildCursor = nil
    exportState.pendingCursor = nil
    exportState.conflictCursor = nil
    exportState.openConflictCursor = nil
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

--- Required after provider-owned durable storage changes outside engine append.
-- Adoption / dataset replacement rebuilds the full export index and drops stale
-- IDs. Ordinary accepted ops upsert incrementally so catch-up stays bounded.
function GS.NotifyLocalDurableChange(reason)
    reason = tostring(reason or "local")
    -- Disabled / unregistered providers must not rebuild export state from
    -- stale Notify calls (queued maint is invalidated via maintGeneration).
    if not providerRegistered then
        return
    end
    local record, guildKey = CurrentGuildRecord()
    local fullRebuild = reason == "adoption"
        or reason == "install"
        or reason == "dataset"
        or not record
        or exportState.guildKey ~= guildKey
        or exportState.datasetId ~= (record and record.datasetId)
        or exportState.epoch ~= (tonumber(GS._adoptionEpoch) or 0)

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
        -- Pace deferred accepted-op / evidence / archive construction after cold rebuild.
        if exportState.archiveBuildNeeded
            or exportState.opBuildNeeded
            or exportState.evidenceBuildNeeded then
            exportState.maintIdle = false
            ScheduleExportMaintContinuation()
        end
    elseif record then
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
                local ocStart = tonumber(exportState.openConflictCursor) or 1
                for ki = ocStart, #ocKeys do
                    if used >= slice then
                        exportState.openConflictCursor = ki
                        exportState.evidenceBuildNeeded = true
                        break
                    end
                    local entry = ops.openConflicts[ocKeys[ki]]
                    if type(entry) == "table" and type(entry.candidateIds) == "table" then
                        for i = 1, #entry.candidateIds do
                            if used >= slice then
                                exportState.openConflictCursor = ki
                                exportState.evidenceBuildNeeded = true
                                break
                            end
                            upsertEvidence(entry.candidateIds[i],
                                entry.boundaries and entry.boundaries[entry.candidateIds[i]])
                            used = used + 1
                        end
                    else
                        used = used + 1
                    end
                    if used < slice then
                        exportState.openConflictCursor = ki + 1
                    end
                end
                if used < slice then
                    exportState.openConflictCursor = nil
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
                local startK = tonumber(exportState.pendingCursor) or 1
                for ki = startK, #keys do
                    if used >= slice then
                        exportState.pendingCursor = ki
                        exportState.evidenceBuildNeeded = true
                        break
                    end
                    upsertEvidence(keys[ki], nil)
                    used = used + 1
                    exportState.pendingCursor = ki + 1
                end
                if used < slice then
                    exportState.pendingCursor = nil
                end
            end
            if used < slice and type(ops.conflicts) == "table" then
                local keys = sortedKeys(ops.conflicts)
                local startK = tonumber(exportState.conflictCursor) or 1
                for ki = startK, #keys do
                    if used >= slice then
                        exportState.conflictCursor = ki
                        exportState.evidenceBuildNeeded = true
                        break
                    end
                    upsertEvidence(keys[ki], nil)
                    used = used + 1
                    exportState.conflictCursor = ki + 1
                end
                if used < slice then
                    exportState.conflictCursor = nil
                end
            end
            if used < slice
                and exportState.pendingCursor == nil
                and exportState.conflictCursor == nil
                and exportState.openConflictCursor == nil then
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
            local startK = tonumber(exportState.archiveBuildCursor) or 1
            for ki = startK, #keys do
                if used >= slice then
                    exportState.archiveBuildCursor = ki
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
                exportState.archiveBuildCursor = ki + 1
            end
            if used < slice then
                exportState.archiveBuildCursor = nil
                exportState.archiveBuildNeeded = false
            end
        end

        exportState.maintIdle = used < slice
            and not exportState.opBuildNeeded
            and not exportState.evidenceBuildNeeded
            and not exportState.archiveBuildNeeded
            and exportState.pendingCursor == nil
            and exportState.conflictCursor == nil
            and exportState.openConflictCursor == nil
            and exportState.opBuildCursor == nil
            and exportState.archiveBuildCursor == nil

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
        exportState.cachedOpCount = acceptedOpCount
        exportState.cachedTransferOpCount = transferOpCount
        exportState.cachedCampaignCount = campaignCount
        exportState.cachedArchiveCount = archiveCount
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
            acceptedOpCount = acceptedOpCount,
            transferOpCount = transferOpCount,
            campaignCount = campaignCount,
            archiveCount = archiveCount,
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
