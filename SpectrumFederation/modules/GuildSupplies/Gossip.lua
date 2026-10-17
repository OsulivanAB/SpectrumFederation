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
}

local function FingerprintBody(body)
    if GS.ContentFingerprint then
        return GS.ContentFingerprint(body)
    end
    if GG and GG.Hash32 then
        return string.format("%08x", GG.Hash32(tostring(body and body.kind) .. tostring(body and body.id)))
    end
    return "v1"
end

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

local function RebuildExportIndex()
    exportState.order = {}
    exportState.byId = {}
    exportState.enumPos = nil
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

    local function add(id, versionFp, body)
        if type(id) ~= "string" or id == "" or exportState.byId[id] then
            return
        end
        exportState.byId[id] = {
            id = id,
            versionFp = versionFp,
            body = body,
        }
        exportState.order[#exportState.order + 1] = id
    end

    -- Compact dataset descriptor (also used for adoption assembly).
    local acceptedOpCount = 0
    local opsCountSource = record.operations
    if type(opsCountSource) == "table" and type(opsCountSource.order) == "table" then
        acceptedOpCount = #opsCountSource.order
    end
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
        campaignCount = campaignCount,
        archiveCount = archiveCount,
    }
    add("gs:desc:" .. record.datasetId, FingerprintBody(desc), desc)

    -- Accepted operations (config / campaign / confirm / resolve).
    local ops = record.operations
    if type(ops) == "table" and type(ops.order) == "table" then
        for i = 1, #ops.order do
            local oid = ops.order[i]
            local op = ops.records and ops.records[oid]
            if type(op) == "table" then
                local body = {
                    kind = "gs-op",
                    op = op,
                }
                if op.kind == GS.KIND.START_CAMPAIGN then
                    local header = record.campaigns and record.campaigns[op.id]
                    if type(header) == "table" then
                        body.boundary = header
                    end
                end
                add("gs:op:" .. op.id, FingerprintBody(body), body)
            end
        end
    end

    -- Conflict / resolution dependency bodies so late peers can reconstruct
    -- resolutions that reference non-head or losing candidates.
    do
        local exported = 0
        local maxExport = (GS.MAX_OPEN_CONFLICTS or 32) * (GS.MAX_CONFLICT_CANDIDATES or 16)
        local function exportCandidate(cid, boundaryHint)
            if exported >= maxExport then
                return
            end
            if type(cid) ~= "string" or exportState.byId["gs:op:" .. cid] then
                return
            end
            local cand = ops.records and ops.records[cid]
                or (ops.pending and ops.pending[cid] and ops.pending[cid].body)
                or (ops.conflicts and ops.conflicts[cid] and ops.conflicts[cid].body)
            if type(cand) ~= "table" then
                return
            end
            local body = { kind = "gs-op", op = cand, evidenceOnly = true }
            if cand.kind == GS.KIND.START_CAMPAIGN then
                local header = boundaryHint
                    or (record.campaigns and record.campaigns[cid])
                    or (GS._pendingCampaignBoundaries and GS._pendingCampaignBoundaries[cid])
                if type(header) == "table" then
                    body.boundary = header
                end
            end
            add("gs:op:" .. cid, FingerprintBody(body), body)
            exported = exported + 1
        end
        if type(ops) == "table" and type(ops.openConflicts) == "table" then
            for _, entry in pairs(ops.openConflicts) do
                if type(entry) == "table" and type(entry.candidateIds) == "table" then
                    for i = 1, #entry.candidateIds do
                        local cid = entry.candidateIds[i]
                        local hint = entry.boundaries and entry.boundaries[cid]
                        exportCandidate(cid, hint)
                    end
                end
            end
        end
        -- Losing evidence retained under conflicts (post-resolution).
        if type(ops) == "table" and type(ops.conflicts) == "table" then
            for cid, entry in pairs(ops.conflicts) do
                if type(entry) == "table" then
                    exportCandidate(cid, nil)
                end
            end
        end
        -- Accepted resolutions: export every competing id referenced by value.
        if type(ops) == "table" and type(ops.order) == "table" then
            for i = 1, #ops.order do
                local op = ops.records and ops.records[ops.order[i]]
                if type(op) == "table" and op.kind == GS.KIND.RESOLVE_CONFLICT then
                    local value = op.value
                    if type(value) == "table" then
                        if type(value.chosenOpId) == "string" then
                            exportCandidate(value.chosenOpId, nil)
                        end
                        if type(value.competingOpIds) == "table" then
                            for j = 1, #value.competingOpIds do
                                exportCandidate(value.competingOpIds[j], nil)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Campaign headers (immutable originals for late joiners / partial catch-up).
    if type(record.campaigns) == "table" then
        for campaignId, header in pairs(record.campaigns) do
            if type(header) == "table" and type(campaignId) == "string" then
                local body = {
                    kind = "campaign-header",
                    header = header,
                }
                add("gs:ch:" .. campaignId, FingerprintBody(body), body)
            end
        end
    end

    -- Archived campaign item snapshots (bounded; separate from op envelopes).
    if type(record.campaignArchives) == "table" then
        for campaignId, archive in pairs(record.campaignArchives) do
            if type(archive) == "table" and type(campaignId) == "string" then
                local body = {
                    kind = "campaign-archive",
                    campaignId = campaignId,
                    datasetId = archive.datasetId or record.datasetId,
                    requestedItems = archive.requestedItems,
                    generation = archive.generation,
                    archivedAt = archive.archivedAt,
                }
                add("gs:ca:" .. campaignId, FingerprintBody(body), body)
            end
        end
    end

    -- Descriptor counts must match exported bodies exactly (including conflict deps).
    local opExportCount, headerExportCount, archiveExportCount = 0, 0, 0
    for id, entry in pairs(exportState.byId) do
        if type(id) == "string" and type(entry) == "table" and type(entry.body) == "table" then
            if entry.body.kind == "gs-op" then
                opExportCount = opExportCount + 1
            elseif entry.body.kind == "campaign-header" then
                headerExportCount = headerExportCount + 1
            elseif entry.body.kind == "campaign-archive" then
                archiveExportCount = archiveExportCount + 1
            end
        end
    end
    local descId = "gs:desc:" .. record.datasetId
    local descEntry = exportState.byId[descId]
    if type(descEntry) == "table" and type(descEntry.body) == "table" then
        descEntry.body.acceptedOpCount = opExportCount
        descEntry.body.campaignCount = headerExportCount
        descEntry.body.archiveCount = archiveExportCount
        descEntry.versionFp = FingerprintBody(descEntry.body)
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
    local fp = FingerprintBody(body)
    local existing = exportState.byId[id]
    if existing and existing.versionFp == fp then
        existing.body = body
        return
    end
    if not existing then
        exportState.order[#exportState.order + 1] = id
    end
    exportState.byId[id] = {
        id = id,
        versionFp = fp,
        body = body,
    }
    exportState.enumPos = 1
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
        if r and GG and GG.IndexUpsert then
            local _, detail = GG.IndexUpsert(index, rid, r.versionFp, r)
            if detail == "replaced" and GG.BumpIndexEpoch then
                GG.BumpIndexEpoch(index)
                exportState.enumPos = 1
                return true, n + 1
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
    return r and r.versionFp or nil
end

local function GetRecordBody(recordId)
    EnsureExportFresh()
    local r = exportState.byId[tostring(recordId)]
    if not r then
        return nil
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

    if body.kind == "campaign-archive" then
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
        local archive = {
            schemaVersion = body.schemaVersion or GS.SCHEMA_VERSION,
            campaignId = body.campaignId,
            datasetId = body.datasetId,
            requestedItems = body.requestedItems or {},
            generation = body.generation,
            archivedAt = body.archivedAt,
        }
        if not GS.ValidateCampaignArchive
            or not GS.ValidateCampaignArchive(archive, body.campaignId, localRecord) then
            return "rejected", "invalid_campaign_archive"
        end
        local existing = localRecord.campaignArchives[body.campaignId]
        if existing then
            if GS._DeepEqualOps and GS._DeepEqualOps(existing, archive) then
                return "duplicate", "duplicate"
            end
            return "rejected", "id_conflict"
        end
        localRecord.campaignArchives[body.campaignId] = archive
        if GS.NotifyLocalDurableChange then
            GS.NotifyLocalDurableChange("remote-archive")
        end
        return "accepted", nil
    end

    if body.kind == "gs-op" then
        local op = body.op
        if type(op) ~= "table" then
            return "rejected", "invalid_operation"
        end
        -- Ordinary members may carry historical candidates; only authenticated
        -- editors authorize application. Relayed author fields are not proof —
        -- even when the claimed original author currently has editor rank.
        local requireRecover = false
        if op.kind == GS.KIND.SET_EDITOR_RANK and localRecord then
            local perm = localRecord.permission
            local policyPos = type(perm) == "table" and tonumber(perm.editorRankPosition) or nil
            local ranks = GG and GG.GetGuildRanks and GG.GetGuildRanks()
            local rankCount = type(ranks) == "table" and tonumber(ranks.count) or nil
            local policyOk = policyPos and policyPos >= 1
                and (not rankCount or policyPos <= rankCount)
                and type(perm) == "table"
                and type(perm.revisionId) == "string" and perm.revisionId ~= ""
            requireRecover = not policyOk
        end
        local relay = false
        local editorOk = select(1, GS.SenderHasEditorAuthority(member, {
            requireRecoverPolicy = requireRecover,
            allowBootstrapInstall = false,
        }))
        if not editorOk then
            -- Non-editor carrier: untrusted historical relay.
            relay = true
        else
            -- Editor carrier with mismatched claimed author is still a relay.
            -- Do not apply or hard-reject; retain for exact-content confirmation.
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
    exportState.order = {}
    exportState.byId = {}
    exportState.enumPos = nil
end

--- Required after provider-owned durable storage changes outside engine append.
-- Adoption / dataset replacement rebuilds the full export index and drops stale
-- IDs. Ordinary accepted ops upsert incrementally so catch-up stays bounded.
function GS.NotifyLocalDurableChange(reason)
    reason = tostring(reason or "local")
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
    elseif record then
        -- Incremental: fingerprint only new/missing export ids from appendPos.
        -- Immutable accepted bodies keep their cached versionFp.
        local ops = record.operations
        local start = math.max(1, (tonumber(exportState.appendPos) or 0) + 1)
        if type(ops) == "table" and type(ops.order) == "table" then
            for i = start, #ops.order do
                local oid = ops.order[i]
                local exportId = "gs:op:" .. oid
                if not exportState.byId[exportId] then
                    local op = ops.records and ops.records[oid]
                    if type(op) == "table" then
                        local body = { kind = "gs-op", op = op }
                        if op.kind == GS.KIND.START_CAMPAIGN then
                            local header = record.campaigns and record.campaigns[op.id]
                            if type(header) == "table" then
                                body.boundary = header
                            end
                        end
                        UpsertExportBody(exportId, body)
                    end
                end
            end
            exportState.appendPos = #ops.order
            -- Bounded export of conflict evidence referenced by resolutions.
            if type(ops.conflicts) == "table" then
                local n = 0
                for cid, entry in pairs(ops.conflicts) do
                    if n >= 64 then
                        break
                    end
                    if type(cid) == "string" and type(entry) == "table"
                        and not exportState.byId["gs:op:" .. cid] then
                        local cand = entry.body or entry
                        if type(cand) == "table" and cand.id then
                            UpsertExportBody("gs:op:" .. cid, {
                                kind = "gs-op",
                                op = cand,
                                evidenceOnly = true,
                            })
                            n = n + 1
                        end
                    end
                end
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
        if type(record.campaignArchives) == "table" then
            for campaignId, archive in pairs(record.campaignArchives) do
                if type(campaignId) == "string" and type(archive) == "table" then
                    local exportId = "gs:ca:" .. campaignId
                    if not exportState.byId[exportId] then
                        UpsertExportBody(exportId, {
                            kind = "campaign-archive",
                            campaignId = campaignId,
                            datasetId = archive.datasetId or record.datasetId,
                            requestedItems = archive.requestedItems,
                            generation = archive.generation,
                            archivedAt = archive.archivedAt,
                            schemaVersion = archive.schemaVersion,
                        })
                    end
                end
            end
        end
        local acceptedOpCount, campaignCount, archiveCount = 0, 0, 0
        for id, entry in pairs(exportState.byId) do
            if type(id) == "string" and type(entry) == "table" and type(entry.body) == "table" then
                if entry.body.kind == "gs-op" then
                    acceptedOpCount = acceptedOpCount + 1
                elseif entry.body.kind == "campaign-header" then
                    campaignCount = campaignCount + 1
                elseif entry.body.kind == "campaign-archive" then
                    archiveCount = archiveCount + 1
                end
            end
        end
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
            campaignCount = campaignCount,
            archiveCount = archiveCount,
        }
        UpsertExportBody("gs:desc:" .. record.datasetId, desc)
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
