-- Guild Supplies authenticated remote admission and staged dataset adoption (#387).
-- Local-action ApplyStaged* APIs remain bound to the local player; this module
-- authenticates the transport sender and never bypasses those local checks.
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

GS.PROVIDER_ID = "sf.guildsupplies.config"
GS.PROVIDER_SCHEMA = 1
GS.MAX_OPEN_CONFLICTS = 32
GS.MAX_ADOPTION_PENDING_RECORDS = 512

-- Runtime-only: adoption / peer discovery / epoch. Not SavedVariables.
GS._adoptionEpoch = 0
GS._adoption = nil -- pending adoption session
GS._peerDatasets = {} -- [normalizedPeer] = { datasetId, peerName, at, editor = bool }
GS._pendingRelay = {} -- [recordId] = { body, sender, at } untrusted historical candidates

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

local function GG()
    return SF.GuildGossip
end

local function DeepEqual(a, b)
    if GS._DeepEqualOps then
        return GS._DeepEqualOps(a, b)
    end
    return a == b
end

local function ContentFingerprint(body)
    local gossip = GG()
    if gossip and gossip.Hash32 then
        -- Stable enough for confirmation binding within a session/store.
        local parts = {}
        local function walk(v, depth)
            depth = (depth or 0) + 1
            if depth > 8 then
                parts[#parts + 1] = "?"
                return
            end
            local t = type(v)
            if t == "nil" then
                parts[#parts + 1] = "N"
            elseif t == "boolean" then
                parts[#parts + 1] = v and "T" or "F"
            elseif t == "number" then
                parts[#parts + 1] = "#" .. tostring(v)
            elseif t == "string" then
                parts[#parts + 1] = "$" .. v
            elseif t == "table" then
                local keys = {}
                for k in pairs(v) do
                    keys[#keys + 1] = k
                end
                table.sort(keys, function(x, y)
                    return tostring(x) < tostring(y)
                end)
                parts[#parts + 1] = "{"
                for i = 1, #keys do
                    local k = keys[i]
                    parts[#parts + 1] = tostring(k) .. "="
                    walk(v[k], depth)
                    parts[#parts + 1] = ";"
                end
                parts[#parts + 1] = "}"
            else
                parts[#parts + 1] = "?"
            end
        end
        walk(body)
        return string.format("%08x", gossip.Hash32(table.concat(parts)))
    end
    return tostring(body and body.id or "?")
end

GS.ContentFingerprint = ContentFingerprint

---------------------------------------------------------------------------
-- Sender authentication (transport name → verified roster member + rank)
---------------------------------------------------------------------------

--- Resolve the transport-authenticated sender to a verified guild member.
-- Payload actorGuid/actorName/rank are never treated as authentication.
-- @param senderName string normalized transport peer
-- @return table|nil member, string|nil reason
function GS.AuthenticateTransportSender(senderName)
    local gossip = GG()
    if not gossip or not gossip.GetGuildMember then
        return nil, "not_ready"
    end
    if type(senderName) ~= "string" or senderName == "" then
        return nil, "invalid_sender"
    end
    local member, reason = gossip.GetGuildMember(senderName)
    if not member then
        return nil, reason or "unknown_sender"
    end
    if type(member.guid) ~= "string" or member.guid == "" then
        return nil, "sender_guid_unavailable"
    end
    if type(member.rankOrder) ~= "number" then
        return nil, "rank_unavailable"
    end
    if type(member.guildKey) ~= "string" or not GS.ParseGuildKey(member.guildKey) then
        return nil, "wrong_guild"
    end
    return member, nil
end

--- Whether a verified member currently meets editor (or GM recovery) policy.
-- Rechecks durable policy; does not trust advertised peer capabilities.
function GS.SenderHasEditorAuthority(member, opts)
    opts = opts or {}
    if type(member) ~= "table" or type(member.rankOrder) ~= "number" then
        return false, "unauthorized"
    end
    local identity = GG() and GG().GetGuildIdentity and GG().GetGuildIdentity()
    if not identity or member.guildKey ~= identity.guildKey then
        return false, "wrong_guild"
    end
    local record, recordReason = nil, nil
    if GS.GetRecordForGuildKey then
        record, recordReason = GS:GetRecordForGuildKey(member.guildKey)
    else
        if not GS:IsRootReady() then
            return false, GS:GetRootReason() or "not_ready"
        end
        local raw = GS._root and GS._root.guilds and GS._root.guilds[member.guildKey]
        if type(raw) ~= "table" then
            recordReason = "not_configured"
        else
            record = raw
        end
    end

    local rankCount = nil
    local ranks = GG() and GG().GetGuildRanks and GG().GetGuildRanks()
    if type(ranks) == "table" then
        rankCount = tonumber(ranks.count)
    end

    if recordReason == "not_configured" or record == nil then
        -- Empty client: only a verified member at default (or GM) threshold may
        -- originate the first staged dataset; receivers still accept replication.
        if opts.allowBootstrapInstall then
            local defaultPos = GS.DEFAULT_EDITOR_RANK_POSITION or 3
            if rankCount and rankCount > 0 and rankCount < defaultPos then
                return member.rankOrder == 1, (member.rankOrder == 1) and nil or "unauthorized"
            end
            return member.rankOrder <= defaultPos, nil
        end
        return false, "not_configured"
    end

    if type(record) ~= "table" or record.activation ~= GS.ACTIVATION_STAGED then
        return false, "unsupported_activation"
    end
    local perm = record.permission
    local policyPos = type(perm) == "table" and tonumber(perm.editorRankPosition) or nil
    local policyOk = policyPos and policyPos >= 1
        and (not rankCount or policyPos <= rankCount)
        and type(perm.revisionId) == "string" and perm.revisionId ~= ""

    if opts.requireRecoverPolicy or (not policyOk) then
        if member.rankOrder == 1 then
            return true, nil
        end
        return false, "policy_requires_gm"
    end
    if member.rankOrder <= policyPos then
        return true, nil
    end
    return false, "unauthorized"
end

--- Bind durable attribution to the verified sender (not payload claims).
local function BindActorFromSender(op, member)
    if type(op) ~= "table" or type(member) ~= "table" then
        return false, "invalid_actor"
    end
    -- Spoofed payload actor fields fail closed when they disagree with transport.
    if type(op.actorGuid) == "string" and op.actorGuid ~= "" and op.actorGuid ~= member.guid then
        return false, "actor_mismatch"
    end
    if type(op.actorName) == "string" and op.actorName ~= "" then
        local gossip = GG()
        local want = gossip and gossip.NormalizePlayer and gossip.NormalizePlayer(op.actorName)
        local have = gossip and gossip.NormalizePlayer and gossip.NormalizePlayer(member.name)
        if want and have and want ~= have then
            return false, "actor_mismatch"
        end
    end
    op.actorGuid = member.guid
    op.actorName = member.name
    return true
end

---------------------------------------------------------------------------
-- Open target conflicts (same-field divergent candidates)
---------------------------------------------------------------------------

local function EnsureOpenConflicts(ops)
    if type(ops.openConflicts) ~= "table" then
        ops.openConflicts = {}
    end
    return ops.openConflicts
end

local function CountOpenConflicts(ops)
    local n = 0
    if type(ops) ~= "table" or type(ops.openConflicts) ~= "table" then
        return 0
    end
    for _ in pairs(ops.openConflicts) do
        n = n + 1
    end
    return n
end

--- Mark a target as conflicted while preserving both candidate operation IDs.
function GS._MarkTargetConflict(ops, targetKey, candidateIds, at)
    if type(ops) ~= "table" or type(targetKey) ~= "string" or targetKey == "" then
        return false, "invalid_target"
    end
    if type(candidateIds) ~= "table" or #candidateIds < 2 then
        return false, "invalid_candidates"
    end
    local open = EnsureOpenConflicts(ops)
    local existing = open[targetKey]
    if type(existing) ~= "table" then
        if CountOpenConflicts(ops) >= GS.MAX_OPEN_CONFLICTS then
            return false, "full"
        end
        open[targetKey] = {
            targetKey = targetKey,
            candidateIds = candidateIds,
            at = at,
        }
        return true
    end
    -- Merge new candidate IDs without dropping prior ones.
    local seen = {}
    local merged = {}
    for i = 1, #existing.candidateIds do
        local id = existing.candidateIds[i]
        if type(id) == "string" and not seen[id] then
            seen[id] = true
            merged[#merged + 1] = id
        end
    end
    for i = 1, #candidateIds do
        local id = candidateIds[i]
        if type(id) == "string" and not seen[id] then
            seen[id] = true
            merged[#merged + 1] = id
        end
    end
    existing.candidateIds = merged
    existing.at = at or existing.at
    return true
end

function GS:ListOpenConflicts()
    local record = select(1, GS:GetCurrentRecord())
    if type(record) ~= "table" or type(record.operations) ~= "table" then
        return {}
    end
    local open = record.operations.openConflicts
    if type(open) ~= "table" then
        return {}
    end
    local out = {}
    for targetKey, entry in pairs(open) do
        if type(entry) == "table" and type(entry.candidateIds) == "table" then
            local candidates = {}
            for i = 1, #entry.candidateIds do
                local id = entry.candidateIds[i]
                local body = record.operations.records[id]
                    or (record.operations.pending[id] and record.operations.pending[id].body)
                    or (record.operations.conflicts[id] and record.operations.conflicts[id].body)
                candidates[#candidates + 1] = {
                    id = id,
                    body = body,
                    fingerprint = body and ContentFingerprint(body) or nil,
                }
            end
            out[#out + 1] = {
                targetKey = targetKey,
                candidates = candidates,
                at = entry.at,
            }
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.targetKey) < tostring(b.targetKey)
    end)
    return out
end

---------------------------------------------------------------------------
-- Causality helpers
---------------------------------------------------------------------------

local function CurrentPolicyRevision(record)
    if type(record.permission) == "table" and type(record.permission.revisionId) == "string" then
        return record.permission.revisionId
    end
    return record.datasetId
end

local function CurrentTargetRevision(record, targetKey)
    local head = record.operations and record.operations.heads and record.operations.heads[targetKey]
    if type(head) == "string" and head ~= "" then
        return head
    end
    return record.datasetId
end

local function HasAcceptedId(ops, id)
    return type(ops.records) == "table" and type(ops.records[id]) == "table"
end

--- Classify a stale base for remote admission.
-- @return "apply"|"pending"|"conflict"|"obsolete", reason
local function ClassifyStaleBase(record, op, targetKey)
    local ops = record.operations
    local currentRev = CurrentTargetRevision(record, targetKey)
    local base = op.baseTargetRevision
    local policyNow = CurrentPolicyRevision(record)
    local campaignNow = record.currentCampaignId

    -- Policy / campaign supersession takes precedence.
    if op.basePolicyRevision ~= policyNow then
        -- Missing policy predecessor → wait; superseded by newer rank op → obsolete.
        if HasAcceptedId(ops, op.basePolicyRevision) then
            return "obsolete", "stale_policy"
        end
        if op.basePolicyRevision == record.datasetId then
            return "obsolete", "stale_policy"
        end
        return "pending", "missing_policy_predecessor"
    end
    if (op.baseCampaignId or nil) ~= (campaignNow or nil)
        or (op.campaignId or nil) ~= (campaignNow or nil) then
        if op.kind == GS.KIND.START_CAMPAIGN then
            -- Concurrent campaign starts: explicit lifecycle conflict.
            return "conflict", "campaign_conflict"
        end
        if type(op.baseCampaignId) == "string" and HasAcceptedId(ops, op.baseCampaignId) then
            return "obsolete", "stale_campaign"
        end
        if op.baseCampaignId == nil and campaignNow ~= nil then
            return "obsolete", "stale_campaign"
        end
        return "pending", "missing_campaign_predecessor"
    end

    if base == currentRev then
        return "apply", nil
    end

    -- Open conflict already holds this target: retain as additional candidate.
    if type(ops.openConflicts) == "table" and ops.openConflicts[targetKey] then
        return "conflict", "open_conflict"
    end

    local headId = ops.heads and ops.heads[targetKey]
    local headBody = headId and ops.records[headId]
    if type(headBody) == "table" and headBody.baseTargetRevision == base then
        -- Divergent siblings from the same base → explicit conflict.
        return "conflict", "divergent_edit"
    end

    if type(base) == "string" and (HasAcceptedId(ops, base) or base == record.datasetId) then
        -- Base known but head advanced along another lineage.
        if type(headBody) == "table" then
            return "conflict", "divergent_edit"
        end
        return "obsolete", "stale_base"
    end

    -- Predecessor not yet present: wait/retry after catch-up.
    return "pending", "missing_predecessor"
end

---------------------------------------------------------------------------
-- Install / adopt staged datasets
---------------------------------------------------------------------------

--- Install a remote staged dataset onto an empty client (replication, not edit grant).
function GS:InstallStagedDatasetFromRemote(descriptor, member)
    if type(descriptor) ~= "table" then
        return "rejected", "invalid_descriptor"
    end
    if type(member) ~= "table" then
        return "rejected", "unauthorized"
    end
    if not GS:IsRootReady() then
        return "rejected", GS:GetRootReason() or "not_ready"
    end
    local guildKey = descriptor.guildKey or member.guildKey
    if not GS.ParseGuildKey(guildKey) or guildKey ~= member.guildKey then
        return "rejected", "wrong_guild"
    end
    if type(descriptor.datasetId) ~= "string" or descriptor.datasetId == "" then
        return "rejected", "invalid_dataset_id"
    end
    local existing = GS._root.guilds[guildKey]
    if existing ~= nil then
        return "rejected", "already_configured"
    end

    local editorOk, editorReason = GS.SenderHasEditorAuthority(member, { allowBootstrapInstall = true })
    if not editorOk then
        return "rejected", editorReason or "unauthorized"
    end

    local identity = GG().GetGuildIdentity()
    local clubId = identity and identity.clubId
    local editorPos = tonumber(descriptor.editorRankPosition) or GS.DEFAULT_EDITOR_RANK_POSITION
    local revisionId = descriptor.permissionRevisionId or descriptor.datasetId
    if type(revisionId) ~= "string" or revisionId == "" then
        revisionId = descriptor.datasetId
    end

    local record = {
        schemaVersion = GS.SCHEMA_VERSION,
        activation = GS.ACTIVATION_STAGED,
        datasetId = descriptor.datasetId,
        permission = {
            editorRankPosition = editorPos,
            revisionId = revisionId,
        },
        currentCampaignId = nil,
        campaigns = {},
        campaignArchives = {},
        campaignContext = {},
        accounting = {
            _consumables = {
                guild = {
                    guid = tostring(clubId or ""),
                    name = (identity and identity.guildName) or "",
                    realm = (identity and identity.guildRealm) or "",
                },
                bankTab = nil,
                requestedItems = {},
                generation = 0,
                configSeq = 0,
                eventSeq = 0,
                eligibility = {
                    items = {},
                    tabEligibleFrom = nil,
                    baselineEstablished = false,
                },
                txnRegistry = {},
            },
            _consumableEvents = {},
            _consumableEventArchive = {},
        },
        observations = { byCampaign = {} },
        operations = {
            records = {},
            order = {},
            heads = {},
            pending = {},
            conflicts = {},
            openConflicts = {},
        },
        confirmationRefs = {},
        migration = nil,
    }

    if GS._ValidateGuildRecordStructure then
        local ok, err = GS._ValidateGuildRecordStructure(guildKey, record)
        if not ok then
            return "rejected", err or "invalid_record"
        end
    end

    GS._root.guilds[guildKey] = record
    GS._adoptionEpoch = (tonumber(GS._adoptionEpoch) or 0) + 1
    DebugInfo("installed remote staged dataset key=%s dataset=%s from=%s",
        guildKey, descriptor.datasetId, tostring(member.name))
    if GS._NotifyLocalDurableChange then
        GS._NotifyLocalDurableChange("install")
    end
    return "accepted", nil
end

--- Begin explicit staged dataset adoption (authorized editor). Runtime-only until commit.
function GS:BeginDatasetAdoption(sourcePeer, sourceDatasetId)
    local ctx = GS:GetCurrentContext()
    if not ctx or not ctx.ready then
        return nil, "rejected", (ctx and ctx.reason) or "not_ready"
    end
    local caps = GS:GetCapabilities()
    if not caps.canEdit and not caps.canRecoverPolicy then
        return nil, "rejected", caps.reason or "unauthorized"
    end
    local member, mReason = GS.AuthenticateTransportSender(sourcePeer)
    if not member then
        return nil, "rejected", mReason or "unknown_sender"
    end
    if member.guildKey ~= ctx.guildKey then
        return nil, "rejected", "wrong_guild"
    end
    local editorOk, editorReason = GS.SenderHasEditorAuthority(member, { allowBootstrapInstall = true })
    if not editorOk then
        return nil, "rejected", editorReason or "unauthorized"
    end
    if type(sourceDatasetId) ~= "string" or sourceDatasetId == "" then
        return nil, "rejected", "invalid_dataset_id"
    end
    local localRecord = select(1, GS:GetCurrentRecord())
    if localRecord and localRecord.datasetId == sourceDatasetId then
        return nil, "rejected", "same_dataset"
    end

    GS._adoption = {
        epoch = (tonumber(GS._adoptionEpoch) or 0) + 1,
        sourcePeer = member.name,
        sourceGuid = member.guid,
        sourceDatasetId = sourceDatasetId,
        guildKey = ctx.guildKey,
        localDatasetId = localRecord and localRecord.datasetId or nil,
        handleGeneration = ctx.handleGeneration,
        actorGuid = ctx.actorGuid,
        records = {},
        order = {},
        startedAt = GetServerTime and GetServerTime() or nil,
        committed = false,
    }
    DebugInfo("began dataset adoption source=%s dataset=%s", member.name, sourceDatasetId)
    return GS._adoption, "accepted", nil
end

function GS:CancelDatasetAdoption()
    if GS._adoption then
        DebugInfo("cancelled dataset adoption dataset=%s", tostring(GS._adoption.sourceDatasetId))
    end
    GS._adoption = nil
    return "accepted", nil
end

function GS:GetPendingAdoption()
    return GS._adoption
end

--- Buffer a validated gossip body into the pending adoption session.
function GS:BufferAdoptionRecord(recordId, body)
    local adop = GS._adoption
    if type(adop) ~= "table" or adop.committed then
        return "rejected", "no_adoption"
    end
    if type(recordId) ~= "string" or recordId == "" or type(body) ~= "table" then
        return "rejected", "invalid_record"
    end
    if #adop.order >= GS.MAX_ADOPTION_PENDING_RECORDS then
        return "rejected", "full"
    end
    if adop.records[recordId] then
        if DeepEqual(adop.records[recordId], body) then
            return "duplicate", "duplicate"
        end
        return "rejected", "id_conflict"
    end
    adop.records[recordId] = body
    adop.order[#adop.order + 1] = recordId
    return "accepted", nil
end

--- Commit adoption: replace local staged guild record with the assembled source dataset.
-- Failure / incomplete / stale authority leaves the previous dataset intact.
function GS:CommitDatasetAdoption()
    local adop = GS._adoption
    if type(adop) ~= "table" or adop.committed then
        return "rejected", "no_adoption"
    end

    -- Revalidate local editor authority and source context after confirmation.
    local prepared = {
        guildKey = adop.guildKey,
        actorGuid = adop.actorGuid,
        handleGeneration = adop.handleGeneration,
    }
    local authOk, authReason = GS:_AuthorizeCommit(prepared, { allowRecoverPolicy = true })
    if not authOk then
        return "rejected", authReason or "unauthorized"
    end
    local member, mReason = GS.AuthenticateTransportSender(adop.sourcePeer)
    if not member or member.guid ~= adop.sourceGuid then
        return "rejected", mReason or "source_changed"
    end
    local editorOk, editorReason = GS.SenderHasEditorAuthority(member, { allowBootstrapInstall = true })
    if not editorOk then
        return "rejected", editorReason or "unauthorized"
    end
    if member.guildKey ~= adop.guildKey then
        return "rejected", "wrong_guild"
    end

    -- Require a complete descriptor + at least the empty operations skeleton.
    local desc = nil
    for i = 1, #adop.order do
        local body = adop.records[adop.order[i]]
        if type(body) == "table" and body.kind == "dataset-desc"
            and body.datasetId == adop.sourceDatasetId then
            desc = body
            break
        end
    end
    if not desc then
        return "rejected", "incomplete_transfer"
    end

    -- Build a replacement record from buffered ops (bounded). Partial apply is forbidden:
    -- assemble into a temporary record, validate, then swap atomically.
    local identity = GG().GetGuildIdentity()
    local clubId = identity and identity.clubId
    local temp = {
        schemaVersion = GS.SCHEMA_VERSION,
        activation = GS.ACTIVATION_STAGED,
        datasetId = adop.sourceDatasetId,
        permission = {
            editorRankPosition = tonumber(desc.editorRankPosition) or GS.DEFAULT_EDITOR_RANK_POSITION,
            revisionId = desc.permissionRevisionId or adop.sourceDatasetId,
        },
        currentCampaignId = nil,
        campaigns = {},
        campaignArchives = {},
        campaignContext = {},
        accounting = {
            _consumables = {
                guild = {
                    guid = tostring(clubId or ""),
                    name = (identity and identity.guildName) or "",
                    realm = (identity and identity.guildRealm) or "",
                },
                bankTab = nil,
                requestedItems = {},
                generation = 0,
                configSeq = 0,
                eventSeq = 0,
                eligibility = {
                    items = {},
                    tabEligibleFrom = nil,
                    baselineEstablished = false,
                },
                txnRegistry = {},
            },
            _consumableEvents = {},
            _consumableEventArchive = {},
        },
        observations = { byCampaign = {} },
        operations = {
            records = {},
            order = {},
            heads = {},
            pending = {},
            conflicts = {},
            openConflicts = {},
        },
        confirmationRefs = {},
        migration = nil,
    }

    -- Replay buffered operation bodies through remote admission against temp by
    -- temporarily swapping the guild slot, then validating before epoch bump.
    local previous = GS._root.guilds[adop.guildKey]
    GS._root.guilds[adop.guildKey] = temp

    local replayFailed = nil
    for i = 1, #adop.order do
        local body = adop.records[adop.order[i]]
        if type(body) == "table" and body.kind == "gs-op" and type(body.op) == "table" then
            local status, reason = GS:AdmitRemoteOperation(body.op, {
                sender = adop.sourcePeer,
                member = member,
                boundary = body.boundary,
                localWrite = false,
                adoptionReplay = true,
            })
            -- At commit time every op must settle to accepted/duplicate.
            if status ~= "accepted" and status ~= "duplicate" then
                replayFailed = reason or status or "incomplete_transfer"
                break
            end
        elseif type(body) == "table" and body.kind == "campaign-header" and type(body.header) == "table" then
            local h = body.header
            if type(h.campaignId) == "string" then
                temp.campaigns[h.campaignId] = h
            end
        elseif type(body) == "table" and body.kind == "campaign-archive" and type(body.campaignId) == "string" then
            temp.campaignArchives[body.campaignId] = {
                datasetId = adop.sourceDatasetId,
                requestedItems = body.requestedItems or {},
                generation = body.generation,
                archivedAt = body.archivedAt,
            }
        end
    end

    if replayFailed then
        GS._root.guilds[adop.guildKey] = previous
        return "rejected", replayFailed
    end

    if GS._ValidateGuildRecordStructure then
        local ok, err = GS._ValidateGuildRecordStructure(adop.guildKey, temp)
        if not ok then
            GS._root.guilds[adop.guildKey] = previous
            return "rejected", err or "invalid_record"
        end
    end

    -- Atomic swap + epoch bump so delayed old-dataset work cannot restore state.
    GS._root.guilds[adop.guildKey] = temp
    GS._adoptionEpoch = (tonumber(GS._adoptionEpoch) or 0) + 1
    adop.committed = true
    GS._adoption = nil
    -- Drop pending relay candidates belonging to the displaced dataset.
    GS._pendingRelay = {}
    DebugInfo("committed dataset adoption dataset=%s epoch=%s",
        adop.sourceDatasetId, tostring(GS._adoptionEpoch))
    if GS._NotifyLocalDurableChange then
        GS._NotifyLocalDurableChange("adoption")
    end
    return "accepted", nil
end

---------------------------------------------------------------------------
-- Remote operation admission
---------------------------------------------------------------------------

local function EnsureRecordForRemote(guildKey)
    if not GS:IsRootReady() then
        return nil, GS:GetRootReason() or "not_ready"
    end
    local raw = GS._root.guilds[guildKey]
    if type(raw) ~= "table" then
        return nil, "not_configured"
    end
    if raw.activation ~= GS.ACTIVATION_STAGED then
        return nil, "unsupported_activation"
    end
    return raw
end

--- Apply an original campaign boundary without recapturing the receiver's bank.
local function ApplyRemoteCampaignMutation(record, stored, boundary)
    if type(boundary) ~= "table" then
        return false, "missing_boundary"
    end
    if boundary.campaignId ~= stored.id or boundary.resetOperationId ~= stored.id then
        return false, "boundary_mismatch"
    end
    if boundary.datasetId ~= record.datasetId then
        return false, "dataset_mismatch"
    end
    local ops = record.operations
    if GS.CountCampaignHeaders and GS.CountCampaignHeaders(record) >= GS.MAX_CAMPAIGNS then
        return false, "full"
    end
    if record.campaigns[stored.id] ~= nil then
        return false, "id_conflict"
    end
    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" or type(cfg.requestedItems) ~= "table" then
        return false, "invalid_accounting"
    end

    local parentId = record.currentCampaignId
    if parentId and GS.ArchiveCurrentCampaignConfig then
        -- Prefer Campaigns helper when exposed; otherwise shallow archive.
    end
    if parentId then
        if not record.campaignArchives then
            record.campaignArchives = {}
        end
        if record.campaignArchives[parentId] == nil then
            local itemsCopy = {}
            for k, v in pairs(cfg.requestedItems) do
                if type(v) == "table" then
                    itemsCopy[k] = {
                        itemId = v.itemId,
                        goal = v.goal,
                    }
                end
            end
            record.campaignArchives[parentId] = {
                datasetId = record.datasetId,
                requestedItems = itemsCopy,
                generation = cfg.generation,
                archivedAt = stored.timestamp,
            }
        end
    end

    local headerOk, headerErr = GS.ValidateCampaignBoundary(boundary, record, stored.guildKey)
    if not headerOk then
        return false, headerErr or "invalid_campaign"
    end

    cfg.requestedItems = {}
    local currentGen = tonumber(cfg.generation) or 0
    cfg.generation = currentGen + 1
    cfg.eligibility = {}
    -- Original startedAt / boundary timestamps — never receipt time.
    GS.EstablishCampaignBaseline(cfg, boundary.startedAt or stored.timestamp)
    cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1

    record.campaigns[stored.id] = boundary
    record.currentCampaignId = stored.id
    if record.observations and record.observations.byCampaign
        and record.observations.byCampaign[stored.id] == nil then
        record.observations.byCampaign[stored.id] = {
            schemaVersion = 1,
            seq = 0,
            scopes = {},
        }
    end
    if GS._StoreAccepted then
        GS._StoreAccepted(ops, stored, GS.CAMPAIGN_TARGET_KEY)
    end
    return true
end

--- Authenticated remote admission for a durable operation body.
-- @param op table public operation
-- @param admissionCtx { sender, member?, boundary?, relay?, localWrite? }
function GS:AdmitRemoteOperation(op, admissionCtx)
    admissionCtx = admissionCtx or {}
    if type(op) ~= "table" then
        return "rejected", "invalid_operation"
    end

    local member = admissionCtx.member
    if not member then
        local m, mReason = GS.AuthenticateTransportSender(admissionCtx.sender)
        if not m then
            return "rejected", mReason or "unauthorized"
        end
        member = m
    end

    -- Dataset mismatch while a local dataset exists: never silent overwrite.
    local record, recReason = EnsureRecordForRemote(member.guildKey)
    if not record then
        if recReason == "not_configured" then
            -- Empty clients only install via dataset-desc + InstallStagedDatasetFromRemote.
            return "pending", "awaiting_dataset"
        end
        return "rejected", recReason or "not_configured"
    end
    if op.guildKey ~= member.guildKey then
        return "rejected", "wrong_guild"
    end
    if op.datasetId ~= record.datasetId then
        return "rejected", "dataset_mismatch"
    end

    local editorOk, editorReason = GS.SenderHasEditorAuthority(member, {
        requireRecoverPolicy = (op.kind == GS.KIND.SET_EDITOR_RANK) or false,
    })

    -- Untrusted relay: retain historical candidates without rebinding attribution to
    -- the relay carrier. A forwarded author field is not authentication.
    if admissionCtx.relay == true or not editorOk then
        if not editorOk then
            local rid = op.id
            if type(rid) == "string" then
                GS._pendingRelay[rid] = {
                    body = op,
                    sender = member.name,
                    at = GetServerTime and GetServerTime() or op.timestamp,
                    fingerprint = ContentFingerprint(op),
                }
            end
            return "pending", "untrusted_relay"
        end
    end

    -- Authenticated editor path: bind durable attribution to the transport sender.
    local bindOk, bindErr = BindActorFromSender(op, member)
    if not bindOk then
        return "rejected", bindErr or "actor_mismatch"
    end

    local stored, snapErr
    if GS._SnapshotPublicOp then
        stored, snapErr = GS._SnapshotPublicOp(op)
    else
        stored = op
    end
    if not stored then
        return "rejected", snapErr or "invalid_operation"
    end

    -- Historical shape validation (not authorization).
    if GS.ValidateAcceptedOperationBody then
        local shapeOk, shapeErr = GS.ValidateAcceptedOperationBody(stored, member.guildKey, record.datasetId)
        if not shapeOk then
            return "rejected", shapeErr or "invalid_operation"
        end
    end

    local ops = record.operations
    local existing = ops.records[stored.id]
    if existing then
        if DeepEqual(existing, stored) then
            return "duplicate", "duplicate"
        end
        if GS._RetainConflict and not GS._RetainConflict(ops, stored) then
            return "rejected", "full"
        end
        return "rejected", "id_conflict"
    end
    if ops.conflicts and ops.conflicts[stored.id] then
        return "rejected", "id_conflict"
    end
    if ops.pending and ops.pending[stored.id] then
        if not DeepEqual(ops.pending[stored.id].body, stored) then
            if GS._RetainConflict and not GS._RetainConflict(ops, stored) then
                return "rejected", "full"
            end
            return "rejected", "id_conflict"
        end
    end

    if GS._AcceptedCount and GS._AcceptedCount(ops) >= GS.MAX_ACCEPTED_OPERATIONS then
        return "rejected", "full"
    end

    local targetKey = GS._TargetKey and GS._TargetKey(stored.kind, stored.target)
    if not targetKey and stored.kind ~= GS.KIND.CONFIRM_CANDIDATE then
        return "rejected", "invalid_target"
    end

    -- Confirmations: authenticated editor confirming exact historical candidates.
    if stored.kind == GS.KIND.CONFIRM_CANDIDATE then
        if stored.basePolicyRevision ~= CurrentPolicyRevision(record) then
            if GS._AdmitPendingOrConflict then
                return GS._AdmitPendingOrConflict(ops, stored, "stale_base")
            end
            return "pending", "stale_base"
        end
        if GS._StoreAccepted then
            GS._StoreAccepted(ops, stored, nil)
        end
        local refs = record.confirmationRefs
        local already = false
        for i = 1, #refs do
            if refs[i] == stored.id then
                already = true
                break
            end
        end
        if not already then
            refs[#refs + 1] = stored.id
        end
        -- Promote matching pending relay candidates referenced by this confirmation.
        local ref = stored.candidateRef
        if type(ref) == "table" then
            local ids = {}
            if type(ref.recordId) == "string" then
                ids[1] = ref.recordId
            elseif type(ref.records) == "table" then
                for i = 1, #ref.records do
                    if type(ref.records[i]) == "table" then
                        ids[#ids + 1] = ref.records[i].id
                    end
                end
            end
            for i = 1, #ids do
                local pending = GS._pendingRelay[ids[i]]
                if pending and pending.fingerprint == (ref.contentFingerprint or pending.fingerprint) then
                    GS._pendingRelay[ids[i]] = nil
                end
            end
        end
        if GS._NotifyLocalDurableChange and not admissionCtx.adoptionReplay then
            GS._NotifyLocalDurableChange("remote-confirm")
        end
        return "accepted", nil
    end

    -- Conflict resolution.
    if stored.kind == GS.KIND.RESOLVE_CONFLICT then
        local value = stored.value
        if type(value) ~= "table" or type(value.chosenOpId) ~= "string" then
            return "rejected", "invalid_resolution"
        end
        local open = ops.openConflicts and ops.openConflicts[targetKey]
        if type(open) ~= "table" then
            -- Resolution for a target that is already converged with matching head is duplicate-ish.
            if ops.heads and ops.heads[targetKey] == value.chosenOpId then
                if GS._StoreAccepted then
                    GS._StoreAccepted(ops, stored, targetKey)
                end
                return "accepted", nil
            end
            return "rejected", "no_open_conflict"
        end
        -- Bind to exact competing content fingerprints when provided.
        if type(value.contentFingerprints) == "table" then
            for id, fp in pairs(value.contentFingerprints) do
                local body = ops.records[id]
                    or (ops.pending[id] and ops.pending[id].body)
                    or (ops.conflicts[id] and ops.conflicts[id].body)
                if not body or ContentFingerprint(body) ~= fp then
                    return "rejected", "fingerprint_mismatch"
                end
            end
        end
        local chosen = ops.records[value.chosenOpId]
            or (ops.pending[value.chosenOpId] and ops.pending[value.chosenOpId].body)
            or (ops.conflicts[value.chosenOpId] and ops.conflicts[value.chosenOpId].body)
        if type(chosen) ~= "table" then
            return "pending", "missing_predecessor"
        end
        -- Apply chosen mutation value under the resolution identity for the head.
        local applyOp = {
            kind = chosen.kind,
            target = chosen.target,
            value = chosen.value,
            timestamp = chosen.timestamp,
            id = chosen.id,
        }
        if chosen.kind == GS.KIND.START_CAMPAIGN then
            -- Lifecycle resolution selects which campaign is current; do not re-run start.
            if type(record.campaigns[value.chosenOpId]) == "table" then
                record.currentCampaignId = value.chosenOpId
            else
                return "pending", "missing_campaign"
            end
        else
            if GS._ApplyMutations then
                local ok, err = GS._ApplyMutations(record, applyOp)
                if not ok then
                    return "rejected", err or "apply_failed"
                end
            end
        end
        if GS._StoreAccepted then
            GS._StoreAccepted(ops, stored, targetKey)
        end
        if ops.openConflicts then
            ops.openConflicts[targetKey] = nil
        end
        -- Drop losing pending siblings for this target when fingerprints were checked.
        if type(value.competingOpIds) == "table" then
            for i = 1, #value.competingOpIds do
                local cid = value.competingOpIds[i]
                if cid ~= value.chosenOpId and ops.pending and ops.pending[cid] then
                    ops.pending[cid] = nil
                end
            end
        end
        if GS._NotifyLocalDurableChange and not admissionCtx.adoptionReplay then
            GS._NotifyLocalDurableChange("remote-resolve")
        end
        return "accepted", nil
    end

    -- Causality classification for config / campaign.
    local class, classReason = ClassifyStaleBase(record, stored, targetKey)
    -- Linear apply when bases match.
    if stored.basePolicyRevision == CurrentPolicyRevision(record)
        and (stored.baseCampaignId or nil) == (record.currentCampaignId or nil)
        and (stored.kind == GS.KIND.START_CAMPAIGN
            or (stored.campaignId or nil) == (record.currentCampaignId or nil))
        and stored.baseTargetRevision == CurrentTargetRevision(record, targetKey) then
        class = "apply"
        classReason = nil
    end

    if class == "pending" then
        if GS._AdmitPendingOrConflict then
            return GS._AdmitPendingOrConflict(ops, stored, classReason or "stale_base")
        end
        return "pending", classReason or "stale_base"
    end
    if class == "obsolete" then
        return "rejected", classReason or "stale_base"
    end
    if class == "conflict" then
        -- Retain candidate body and mark target conflicted.
        local headId = ops.heads and ops.heads[targetKey]
        if stored.kind == GS.KIND.START_CAMPAIGN then
            headId = ops.heads and ops.heads[GS.CAMPAIGN_TARGET_KEY]
        end
        local candidates = {}
        if type(headId) == "string" then
            candidates[#candidates + 1] = headId
        end
        candidates[#candidates + 1] = stored.id
        -- Keep the incoming body as pending evidence (not applied).
        if GS._AdmitPendingOrConflict then
            local st, reason = GS._AdmitPendingOrConflict(ops, stored, classReason or "divergent_edit")
            GS._MarkTargetConflict(ops, targetKey, candidates, stored.timestamp)
            return st, reason
        end
        GS._MarkTargetConflict(ops, targetKey, candidates, stored.timestamp)
        return "pending", classReason or "divergent_edit"
    end

    -- Apply path.
    if stored.kind == GS.KIND.START_CAMPAIGN then
        local ok, err = ApplyRemoteCampaignMutation(record, stored, admissionCtx.boundary)
        if not ok then
            if err == "missing_boundary" then
                return "pending", err
            end
            return "rejected", err or "apply_failed"
        end
    else
        if GS._ApplyMutations then
            local ok, err = GS._ApplyMutations(record, stored)
            if not ok then
                return "rejected", err or "apply_failed"
            end
        end
        if GS._StoreAccepted then
            GS._StoreAccepted(ops, stored, targetKey)
        end
    end

    if GS._NotifyLocalDurableChange and not admissionCtx.adoptionReplay then
        GS._NotifyLocalDurableChange("remote-op")
    end
    return "accepted", nil
end

---------------------------------------------------------------------------
-- Local conflict resolution prepare/apply (authorized editor)
---------------------------------------------------------------------------

function GS:NewConflictResolutionOperation(targetKey, chosenOpId, competingOpIds)
    local ctx = GS:GetCurrentContext()
    if not ctx or not ctx.ready then
        return nil, "rejected", (ctx and ctx.reason) or "not_ready"
    end
    local caps = GS:GetCapabilities()
    if not caps.canEdit then
        return nil, "rejected", caps.reason or "unauthorized"
    end
    local record, recordReason = GS:GetCurrentRecord()
    if not record then
        return nil, "rejected", recordReason or "not_configured"
    end
    if type(targetKey) ~= "string" or targetKey == "" then
        return nil, "rejected", "invalid_target"
    end
    if type(chosenOpId) ~= "string" or chosenOpId == "" then
        return nil, "rejected", "invalid_resolution"
    end
    local open = record.operations.openConflicts and record.operations.openConflicts[targetKey]
    if type(open) ~= "table" then
        return nil, "rejected", "no_open_conflict"
    end
    competingOpIds = competingOpIds or open.candidateIds
    local fingerprints = {}
    for i = 1, #competingOpIds do
        local id = competingOpIds[i]
        local body = record.operations.records[id]
            or (record.operations.pending[id] and record.operations.pending[id].body)
            or (record.operations.conflicts[id] and record.operations.conflicts[id].body)
        if type(body) == "table" then
            fingerprints[id] = ContentFingerprint(body)
        end
    end
    local ts = GetServerTime and GetServerTime() or nil
    if not ts then
        return nil, "rejected", "server_time_unavailable"
    end
    local id, idErr = GS:_AllocateOperationId(ctx.actorGuid)
    if not id then
        return nil, "rejected", idErr or "id_failed"
    end
    local op = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = id,
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.RESOLVE_CONFLICT,
        target = targetKey,
        value = {
            chosenOpId = chosenOpId,
            competingOpIds = competingOpIds,
            contentFingerprints = fingerprints,
        },
        actorGuid = ctx.actorGuid,
        actorName = ctx.actorName,
        timestamp = ts,
        baseTargetRevision = CurrentTargetRevision(record, targetKey),
        basePolicyRevision = CurrentPolicyRevision(record),
        baseCampaignId = record.currentCampaignId,
        _preparedHandleGeneration = ctx.handleGeneration,
    }
    return op, "accepted", nil
end

function GS:ApplyStagedConflictResolution(op, context)
    if type(op) ~= "table" or op.kind ~= GS.KIND.RESOLVE_CONFLICT then
        return "rejected", "invalid_operation"
    end
    local prepared = {
        guildKey = op.guildKey,
        actorGuid = op.actorGuid,
        handleGeneration = op._preparedHandleGeneration,
    }
    local authOk, authReason, fresh = GS:_AuthorizeCommit(prepared)
    if not authOk then
        return "rejected", authReason or "unauthorized"
    end
    context = fresh or context
    if op.actorName ~= (context and context.actorName) then
        return "rejected", "unauthorized"
    end
    -- Local resolution reuses remote apply logic with the local player as sender.
    return GS:AdmitRemoteOperation(op, {
        sender = context.actorName,
        member = {
            name = context.actorName,
            guid = context.actorGuid,
            rankOrder = context.rankOrder,
            guildKey = context.guildKey,
        },
        localWrite = true,
    })
end

---------------------------------------------------------------------------
-- Peer dataset advertisements (runtime discovery cache)
---------------------------------------------------------------------------

function GS.NotePeerDataset(peerName, datasetId, caps)
    if type(peerName) ~= "string" or type(datasetId) ~= "string" or datasetId == "" then
        return
    end
    local gossip = GG()
    local norm = gossip and gossip.NormalizePlayer and gossip.NormalizePlayer(peerName) or peerName
    GS._peerDatasets[norm] = {
        peerName = norm,
        datasetId = datasetId,
        editorRankPosition = caps and caps.editorRankPosition or nil,
        permissionRevisionId = caps and caps.permissionRevisionId or nil,
        at = GetServerTime and GetServerTime() or nil,
    }
end

function GS:ListPeerDatasets()
    local ctx = GS:GetCurrentContext()
    local localRecord = select(1, GS:GetCurrentRecord())
    local localId = localRecord and localRecord.datasetId or nil
    local out = {}
    for _, entry in pairs(GS._peerDatasets) do
        local member = GS.AuthenticateTransportSender(entry.peerName)
        if member and ctx and member.guildKey == ctx.guildKey then
            local editorOk = select(1, GS.SenderHasEditorAuthority(member, { allowBootstrapInstall = true }))
            if editorOk and entry.datasetId ~= localId then
                out[#out + 1] = {
                    peerName = entry.peerName,
                    datasetId = entry.datasetId,
                    sameAsLocal = false,
                    editorVerified = true,
                }
            elseif editorOk and entry.datasetId == localId then
                out[#out + 1] = {
                    peerName = entry.peerName,
                    datasetId = entry.datasetId,
                    sameAsLocal = true,
                    editorVerified = true,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.peerName) < tostring(b.peerName)
    end)
    return out
end

function GS:GetDatasetMismatchState()
    local localRecord = select(1, GS:GetCurrentRecord())
    local peers = GS:ListPeerDatasets()
    local foreign = {}
    for i = 1, #peers do
        if not peers[i].sameAsLocal then
            foreign[#foreign + 1] = peers[i]
        end
    end
    if localRecord and #foreign > 0 then
        return {
            blocked = true,
            localDatasetId = localRecord.datasetId,
            peers = foreign,
        }
    end
    return {
        blocked = false,
        localDatasetId = localRecord and localRecord.datasetId or nil,
        peers = peers,
    }
end
