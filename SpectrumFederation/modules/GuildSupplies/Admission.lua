-- Guild Supplies authenticated remote admission and staged dataset adoption (#387).
-- Local-action ApplyStaged* APIs remain bound to the local player; this module
-- authenticates the transport sender and never bypasses those local checks.
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

GS.PROVIDER_ID = "sf.guildsupplies.config"
GS.PROVIDER_SCHEMA = 1
GS.MAX_OPEN_CONFLICTS = 32
-- Must match State.lua openConflicts candidateIds upper bound.
GS.MAX_CONFLICT_CANDIDATES = 16
-- Abandoned adoption sessions expire so they cannot suppress peer traffic forever.
GS.MAX_ADOPTION_SECONDS = 600
-- Bounded untrusted historical relay retention (runtime-only).
GS.MAX_PENDING_RELAY = 64
-- Per-commit confirmation redrive slice (full refs scanned across slices).
GS.MAX_CONFIRMATION_REDRIVE_PER_SLICE = 32
-- Aggregate archive / operation-manifest reassembly buffer.
GS.MAX_ARCHIVE_PAGE_BUFFER_CAMPAIGNS = 16
---------------------------------------------------------------------------
-- Concrete transfer / work limits derived from existing supported maxima.
-- Wrapper-inclusive wire budget equals Guild Gossip MAX_RECORD_CBOR (2048).
-- Ask the owner only if supporting these maxima needs a product scope change.
---------------------------------------------------------------------------
GS.MAX_WIRE_RECORD_BYTES = 2048
-- Campaign archive item/eligibility pages. Cumulative eligibility cutoff keys
-- survive item remove/re-add beyond MAX_REQUESTED_ITEMS (live map only); byte-
-- aware packing emits one key per page in the worst case, so the page ceiling
-- must cover large historical cutoff maps without silent prune.
GS.MAX_ARCHIVE_PAGE_ITEMS = 64
GS.MAX_ARCHIVE_PAGE_COUNT = 512
GS.MAX_ARCHIVE_PAGE_BUFFER_PAGES = 512
-- Operation-manifest pages: one page per confirmed/resolved body in the worst
-- case, plus headroom for page-carried originalIds / competingOpIds lists that
-- shells strip (those lists may need additional pages when record pages are full).
GS.MAX_MANIFEST_PAGES = math.max(
    ((GS.MAX_CONFIRMATION_BATCH or 64) * 2),
    ((GS.MAX_CONFLICT_CANDIDATES or 16) * 2)
)
-- Must fit a full legal accepted export: ops + headers + archive meta/pages +
-- conflict evidence + operation-manifest pages + descriptor. Archive and
-- confirm/resolve paging multiply bodies beyond logical operation counts.
-- Logical adoption buffer: accepted ops + live/archived ledger + donation
-- evidence + campaigns/archives + headroom. Ledger and ops are independently
-- capped; the shared buffer must hold both at once.
-- Wire pages for incomplete paged manifests live in a separate assembly arena so
-- interleaved pages-first delivery cannot fill this ceiling before shells arrive.
GS.MAX_ADOPTION_PENDING_RECORDS = (GS.MAX_ACCEPTED_OPERATIONS or 4096)
    + (GS.MAX_LEDGER_EVENTS or 4096)
    + (GS.MAX_ARCHIVED_EVENTS or 4096)
    + (GS.MAX_DIRECT_EVIDENCE_EXPORTS or 256)
    + ((GS.MAX_CAMPAIGNS or 64) * 24)
    + 512
-- Concurrent incomplete paged-op assemblies during transfer (not logical history).
GS.MAX_ADOPTION_ASSEMBLY_OPS = 24
GS.MAX_ADOPTION_ASSEMBLY_PAGES = (GS.MAX_MANIFEST_PAGES or 64) * (GS.MAX_ADOPTION_ASSEMBLY_OPS or 24)
-- Assembled fragment byte budget matches snapshot string budget.
GS.MAX_FRAGMENT_ASSEMBLY_BYTES = GS.MAX_SNAPSHOT_STRING_BYTES or 49152
GS.MAX_FRAGMENT_BUFFER_ASSEMBLIES = GS.MAX_ARCHIVE_PAGE_BUFFER_CAMPAIGNS or 16
-- Operation-manifest FragmentBuffer (confirm/resolve pages). Kept independent of
-- the raised campaign-archive page ceiling so assembly_full / recovery tests and
-- live confirm paging remain within the supported manifest bound.
GS.MAX_FRAGMENT_BUFFER_PAGES = math.max(
    64,
    (GS.MAX_MANIFEST_PAGES or 64) * 2
)
GS.FRAGMENT_BUFFER_TTL_SECONDS = GS.MAX_ADOPTION_SECONDS or 600
-- Per-slice admission / export maintenance (same order as confirmation redrive).
GS.MAX_ADMISSION_WORK_PER_SLICE = GS.MAX_CONFIRMATION_REDRIVE_PER_SLICE or 32
GS.MAX_EXPORT_MAINT_PER_SLICE = GS.MAX_CONFIRMATION_REDRIVE_PER_SLICE or 32
-- Aggregate adoption admissions bounded by buffered body count (no silent truncate).
GS.MAX_ADOPTION_AGGREGATE_ADMISSIONS = GS.MAX_ADOPTION_PENDING_RECORDS
    + (GS.MAX_ADOPTION_ASSEMBLY_PAGES or 0)

-- Runtime-only: adoption / peer discovery / epoch. Not SavedVariables.
GS._adoptionEpoch = 0
GS._adoption = nil -- pending adoption session
GS._peerDatasets = {} -- [normalizedPeer] = { datasetId, peerName, at, editor = bool }
GS._pendingRelay = {} -- [recordId] = { body, sender, at, fingerprint, boundary? }
-- Pending campaign boundaries retained with conflicting start-campaign candidates.
GS._pendingCampaignBoundaries = {} -- [opId] = header
-- After descriptor-first install: block local edits until advertised policy lands.
-- Durable mirror: permission.pendingPolicyRevisionId (survives /reload).
GS._bootstrapEditLock = {} -- [guildKey] = advertisedPermissionRevisionId
-- Confirmation redrive state keyed by guild+dataset generation (not global).
GS._confirmationRedriveByKey = GS._confirmationRedriveByKey or {}
-- Forward-declared: install/publish paths clear live redrive pins on replacement.
local ClearConfirmationRedriveForRecord
local ClearConfirmationRedriveForGuild

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

local function CanonicalContentParts(body)
    local parts = {}
    local function walk(v, depth)
        depth = (depth or 0) + 1
        if depth > 12 then
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
            parts[#parts + 1] = "$" .. tostring(#v) .. ":" .. v
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
    return parts
end

--- Advisory export/cache digest only. NEVER confirmation or resolution authority.
-- Exact-content authority uses AuthoritativeBodiesEqual against envelope-embedded
-- bodies from an authenticated confirm/resolve. Hash32 remains non-cryptographic.
local function ContentFingerprint(body)
    local gossip = GG()
    if not (gossip and gossip.Hash32) then
        return nil
    end
    local canon = table.concat(CanonicalContentParts(body))
    local mix = gossip.Hash32("gs-fp-v2:len:" .. tostring(#canon))
    local digests = {}
    digests[#digests + 1] = string.format("%08x", mix)
    local win = 256
    if #canon == 0 then
        mix = gossip.Hash32(string.format("%08x|empty", mix))
        digests[#digests + 1] = string.format("%08x", mix)
    else
        local idx = 0
        for i = 1, #canon, win do
            idx = idx + 1
            local chunk = canon:sub(i, i + win - 1)
            mix = gossip.Hash32(string.format("%08x|%d|%d|", mix, idx, #chunk) .. chunk)
            digests[#digests + 1] = string.format("%08x", mix)
        end
    end
    mix = gossip.Hash32(string.format("%08x|full|", mix) .. canon)
    digests[#digests + 1] = string.format("%08x", mix)
    local maxLen = GS.MAX_OPERATION_ID or 192
    while #digests > 1 and (#digests * 8) > maxLen do
        local a = table.remove(digests, 1)
        local b = table.remove(digests, 1)
        table.insert(digests, 1, string.format("%08x", gossip.Hash32(a .. "|" .. b)))
    end
    return table.concat(digests, "")
end

GS.ContentFingerprint = ContentFingerprint

--- Compare authoritative public operation bodies, excluding transport metadata.
-- Equality of two untrusted relay copies is not authority; callers must bind one
-- side to an authenticated confirmation/resolution envelope's embedded body.
local function AuthoritativeBodiesEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    local sa, sb = a, b
    if GS._SnapshotPublicOp then
        sa = select(1, GS._SnapshotPublicOp(a)) or a
        sb = select(1, GS._SnapshotPublicOp(b)) or b
    end
    return DeepEqual(sa, sb)
end

GS.AuthoritativeBodiesEqual = AuthoritativeBodiesEqual

--- Extract authoritative candidate body for `opId` from an accepted confirm/resolve.
local function AuthoritativeBodyFromEnvelope(envelope, opId)
    if type(envelope) ~= "table" or type(opId) ~= "string" then
        return nil
    end
    if envelope.kind == GS.KIND.CONFIRM_CANDIDATE then
        local ref = envelope.candidateRef
        if type(ref) ~= "table" then
            return nil
        end
        if ref.recordId == opId and type(ref.body) == "table" then
            return ref.body
        end
        if type(ref.records) == "table" then
            for i = 1, #ref.records do
                local row = ref.records[i]
                if type(row) == "table" and row.id == opId and type(row.body) == "table" then
                    return row.body
                end
            end
        end
        return nil
    end
    if envelope.kind == GS.KIND.RESOLVE_CONFLICT then
        local value = envelope.value
        if type(value) == "table" and type(value.contentBodies) == "table" then
            local body = value.contentBodies[opId]
            if type(body) == "table" then
                return body
            end
        end
    end
    return nil
end

local function ValidateEditorRankValue(pos)
    local ranks = GG() and GG().GetGuildRanks and GG().GetGuildRanks()
    local rankCount = type(ranks) == "table" and tonumber(ranks.count) or nil
    if not rankCount or rankCount < 1 then
        return false, "rank_unavailable"
    end
    pos = tonumber(pos)
    if not pos or pos ~= math.floor(pos) or pos < 1 or pos > rankCount then
        return false, "invalid_editor_rank_position"
    end
    return true, nil, pos
end

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

    if type(record) ~= "table"
        or not (GS.IsSupportedActivation and GS.IsSupportedActivation(record.activation)) then
        return false, "unsupported_activation"
    end
    local perm = record.permission
    -- Fractional / non-integral retained policy is not ordinary editor authority.
    -- Reuse positive-integral validation when ranks are available; always reject
    -- non-integral thresholds. GM recovery remains verified-GM-only.
    local rawPos = type(perm) == "table" and tonumber(perm.editorRankPosition) or nil
    local integralPos = rawPos and rawPos == math.floor(rawPos) and rawPos >= 1
    local policyPos = nil
    local policyOk = false
    if type(perm) == "table" and type(perm.revisionId) == "string" and perm.revisionId ~= "" then
        if rankCount and rankCount >= 1 then
            local rankOk, _, policyNorm = ValidateEditorRankValue(rawPos)
            if rankOk then
                policyOk = true
                policyPos = policyNorm
            end
        elseif integralPos then
            policyOk = true
            policyPos = rawPos
        end
    end

    -- Incomplete descriptor-first catch-up: provisional bootstrap threshold is not
    -- ordinary edit authority (local or remote) until advertised policy lands.
    if not opts.allowPolicyCatchUp and GS.IsBootstrapEditLocked
        and GS.IsBootstrapEditLocked(member.guildKey, record) then
        return false, "awaiting_policy"
    end

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
-- Enforces State.lua's 16-candidate bound before mutation (no oversize persist).
function GS._MarkTargetConflict(ops, targetKey, candidateIds, at, meta)
    if type(ops) ~= "table" or type(targetKey) ~= "string" or targetKey == "" then
        return false, "invalid_target"
    end
    if type(candidateIds) ~= "table" or #candidateIds < 2 then
        return false, "invalid_candidates"
    end
    local maxCand = GS.MAX_CONFLICT_CANDIDATES or 16
    local open = EnsureOpenConflicts(ops)
    local existing = open[targetKey]
    local seen = {}
    local merged = {}
    local function pushId(id)
        if type(id) ~= "string" or id == "" or seen[id] then
            return true
        end
        if #merged >= maxCand then
            return false
        end
        seen[id] = true
        merged[#merged + 1] = id
        return true
    end
    if type(existing) == "table" and type(existing.candidateIds) == "table" then
        for i = 1, #existing.candidateIds do
            if not pushId(existing.candidateIds[i]) then
                return false, "full"
            end
        end
    else
        if CountOpenConflicts(ops) >= GS.MAX_OPEN_CONFLICTS then
            return false, "full"
        end
    end
    for i = 1, #candidateIds do
        if not pushId(candidateIds[i]) then
            return false, "full"
        end
    end
    if #merged < 2 then
        return false, "invalid_candidates"
    end
    if type(existing) ~= "table" then
        open[targetKey] = {
            targetKey = targetKey,
            candidateIds = merged,
            at = at,
            boundaries = (meta and meta.boundaries) or nil,
        }
    else
        existing.candidateIds = merged
        existing.at = at or existing.at
        if meta and meta.boundaries then
            existing.boundaries = existing.boundaries or {}
            for id, header in pairs(meta.boundaries) do
                existing.boundaries[id] = header
            end
        end
    end
    return true
end

--- Reclaim stale untrusted relay entries (TTL / guild-dataset scope).
--- True when durable pending/conflict/open-conflict evidence still owns a
-- campaign boundary for `id` (must survive relay TTL/eviction reclaim).
local function DurableBoundaryStillNeeded(id)
    if type(id) ~= "string" or id == "" then
        return false
    end
    local function opsNeed(ops)
        if type(ops) ~= "table" then
            return false
        end
        if ops.pending and ops.pending[id] then
            return true
        end
        if ops.conflicts and ops.conflicts[id] then
            return true
        end
        if type(ops.openConflicts) == "table" then
            for _, open in pairs(ops.openConflicts) do
                if type(open) == "table" and type(open.boundaries) == "table"
                    and open.boundaries[id] ~= nil then
                    return true
                end
            end
        end
        return false
    end
    local root = GS._root
    if type(root) == "table" and type(root.guilds) == "table" then
        for _, rec in pairs(root.guilds) do
            if type(rec) == "table" and opsNeed(rec.operations) then
                return true
            end
        end
    end
    local adop = GS._adoption
    if type(adop) == "table" and type(adop.replayTemp) == "table"
        and opsNeed(adop.replayTemp.operations) then
        return true
    end
    return false
end

--- Drop a relay entry and reclaim its campaign boundary when nothing durable owns it.
local function DropPendingRelayEntry(id)
    if type(id) ~= "string" then
        return
    end
    if GS._pendingRelay then
        GS._pendingRelay[id] = nil
    end
    if GS._pendingCampaignBoundaries and GS._pendingCampaignBoundaries[id] ~= nil
        and not DurableBoundaryStillNeeded(id) then
        GS._pendingCampaignBoundaries[id] = nil
    end
end

local function ReclaimStalePendingRelay(opts)
    opts = opts or {}
    local now = GetServerTime and GetServerTime() or 0
    local ttl = GS.FRAGMENT_BUFFER_TTL_SECONDS or GS.MAX_ADOPTION_SECONDS or 600
    local wantGuild = opts.guildKey
    local wantDataset = opts.datasetId
    local removed = 0
    for id, entry in pairs(GS._pendingRelay or {}) do
        local stale = false
        if type(entry) ~= "table" then
            stale = true
        elseif now > 0 and ttl > 0 and entry.at and (now - (tonumber(entry.at) or 0)) > ttl then
            stale = true
        elseif wantGuild and entry.guildKey and entry.guildKey ~= wantGuild then
            stale = true
        elseif wantDataset and entry.datasetId and entry.datasetId ~= wantDataset then
            stale = true
        end
        if stale then
            DropPendingRelayEntry(id)
            removed = removed + 1
        end
    end
    return removed
end

--- Retain an untrusted historical candidate under a hard bound.
-- Validates/snapshots before consuming a retention slot so malformed bodies
-- cannot exhaust capacity. Scoped by guild/dataset; reclaim stale before full.
local function RetainPendingRelay(recordId, entry)
    if type(recordId) ~= "string" or recordId == "" or type(entry) ~= "table" then
        return false, "invalid_record"
    end
    if type(entry.body) ~= "table" then
        return false, "invalid_operation"
    end
    local snap = entry.body
    if GS._SnapshotPublicOp then
        local stored, snapErr = GS._SnapshotPublicOp(entry.body)
        if not stored then
            return false, snapErr or "invalid_operation"
        end
        snap = stored
    end
    if GS.ValidateAcceptedOperationBody then
        local shapeOk, shapeErr = GS.ValidateAcceptedOperationBody(snap, nil, nil)
        if not shapeOk then
            return false, shapeErr or "invalid_operation"
        end
    end
    local fp = entry.fingerprint or ContentFingerprint(snap)
    if GS._pendingRelay[recordId] then
        if DeepEqual(GS._pendingRelay[recordId].body, snap)
            and GS._pendingRelay[recordId].fingerprint == fp then
            return true, "duplicate"
        end
        return false, "id_conflict"
    end
    local guildKey = entry.guildKey or snap.guildKey
    local datasetId = entry.datasetId or snap.datasetId
    ReclaimStalePendingRelay({ guildKey = guildKey, datasetId = datasetId })
    local n = 0
    local oldestId, oldestAt = nil, nil
    for id, e in pairs(GS._pendingRelay) do
        n = n + 1
        local at = e and tonumber(e.at) or 0
        if not oldestAt or at < oldestAt then
            oldestAt = at
            oldestId = id
        end
    end
    local cap = GS.MAX_PENDING_RELAY or 64
    if n >= cap then
        -- Capacity recovery: drop oldest untrusted entry (+ orphan boundary), then retry.
        if oldestId then
            DropPendingRelayEntry(oldestId)
            n = n - 1
        end
        if n >= cap then
            return false, "full"
        end
    end
    GS._pendingRelay[recordId] = {
        body = snap,
        sender = entry.sender,
        at = entry.at or (GetServerTime and GetServerTime()) or 0,
        fingerprint = fp,
        boundary = entry.boundary,
        guildKey = guildKey,
        datasetId = datasetId,
    }
    return true
end

GS._ReclaimStalePendingRelay = ReclaimStalePendingRelay

local ActorMatchesMember -- forward decl; defined below

--- True when an *accepted* source-authored confirmation/resolution envelope
-- embeds authoritative content that exactly matches `candidateBody` for `opId`.
-- Buffered-only envelopes are not authority. Fingerprints are never used.
-- Selecting an adoption source alone does not confirm unknown authors.
local function EnsureAdoptionWorkStats(adop)
    if type(adop) ~= "table" then
        return nil
    end
    adop._workStats = adop._workStats or {
        confirmVisited = 0,
        confirmComparisons = 0,
        completenessVisited = 0,
        indexVisited = 0,
        assemblyVisited = 0,
        archiveVisited = 0,
        receiveVisited = 0,
        confirmRedriveVisited = 0,
    }
    return adop._workStats
end

--- Incremental confirm/resolve target index for an adoption session.
-- Maps target opId → envelope op ids; envelope bodies live in _confirmEnvelopes.
-- Built on buffer/compaction; never full-scans adop.order on cache hits.
local function IndexAdoptionEnvelope(adop, op)
    if type(adop) ~= "table" or type(op) ~= "table" or type(op.id) ~= "string" then
        return
    end
    local isEnv = op.kind == GS.KIND.CONFIRM_CANDIDATE or op.kind == GS.KIND.RESOLVE_CONFLICT
    if not isEnv then
        return
    end
    local stats = EnsureAdoptionWorkStats(adop)
    adop._confirmEnvelopes = adop._confirmEnvelopes or {}
    adop._confirmByTarget = adop._confirmByTarget or {}
    if adop._confirmEnvelopes[op.id] == nil then
        stats.indexVisited = (stats.indexVisited or 0) + 1
    end
    adop._confirmEnvelopes[op.id] = op
    local function noteTarget(tid)
        if type(tid) ~= "string" then
            return
        end
        local list = adop._confirmByTarget[tid]
        if not list then
            list = {}
            adop._confirmByTarget[tid] = list
        end
        for i = 1, #list do
            if list[i] == op.id then
                return
            end
        end
        list[#list + 1] = op.id
        stats.indexVisited = (stats.indexVisited or 0) + 1
    end
    if op.kind == GS.KIND.CONFIRM_CANDIDATE and type(op.candidateRef) == "table" then
        local ref = op.candidateRef
        if type(ref.recordId) == "string" then
            noteTarget(ref.recordId)
        end
        if type(ref.records) == "table" then
            for i = 1, #ref.records do
                local row = ref.records[i]
                if type(row) == "table" then
                    noteTarget(row.id)
                end
            end
        end
    elseif op.kind == GS.KIND.RESOLVE_CONFLICT and type(op.value) == "table" then
        local ids = op.value.competingOpIds
        if type(ids) == "table" then
            for i = 1, #ids do
                noteTarget(ids[i])
            end
        end
        if type(op.value.contentBodies) == "table" then
            for tid in pairs(op.value.contentBodies) do
                noteTarget(tid)
            end
        end
    end
end

--- Search indexed confirm/resolve envelopes for exact-content auth of opId.
-- opts.budget / opts.visited charge each visited envelope; resumes via opts.cursor.
-- opts.skipSearch=true forces a negative result without scanning (source-authored).
-- Only walks byTarget[opId]; does not scan adop.order or recount accepted history.
local function AdoptionHasConfirmationFor(adop, opId, candidateBody, member, acceptedOps, opts)
    if type(adop) ~= "table" or type(opId) ~= "string" or type(candidateBody) ~= "table" then
        return false
    end
    opts = opts or {}
    if opts.skipSearch == true then
        return false
    end
    local stats = EnsureAdoptionWorkStats(adop)
    local budget = tonumber(opts.budget)
    local visited = 0
    local start = tonumber(opts.cursor) or 1
    if start < 1 then
        start = 1
    end
    local accepted = acceptedOps and acceptedOps.records
    local targets = adop._confirmByTarget and adop._confirmByTarget[opId]
    if type(targets) ~= "table" or #targets < 1 then
        opts.cursor = nil
        opts.visited = (tonumber(opts.visited) or 0)
        opts.budgetExhausted = false
        return false
    end
    local i = start
    while i <= #targets do
        if budget and visited >= budget then
            opts.cursor = i
            opts.visited = (tonumber(opts.visited) or 0) + visited
            opts.budgetExhausted = true
            return false, "budget"
        end
        visited = visited + 1
        stats.confirmVisited = (stats.confirmVisited or 0) + 1
        local envId = targets[i]
        local op = adop._confirmEnvelopes and adop._confirmEnvelopes[envId]
        if type(op) == "table"
            and ActorMatchesMember(op, member)
            and (type(accepted) ~= "table" or type(accepted[op.id]) == "table") then
            local authBody = AuthoritativeBodyFromEnvelope(op, opId)
            if type(authBody) == "table" then
                stats.confirmComparisons = (stats.confirmComparisons or 0) + 1
                if AuthoritativeBodiesEqual(authBody, candidateBody) then
                    opts.cursor = nil
                    opts.visited = (tonumber(opts.visited) or 0) + visited
                    opts.budgetExhausted = false
                    return true
                end
            end
        end
        i = i + 1
    end
    opts.cursor = nil
    opts.visited = (tonumber(opts.visited) or 0) + visited
    opts.budgetExhausted = false
    return false
end

--- True when any accepted confirm/resolve on `record` binds exact content for opId.
local function RecordHasConfirmationFor(record, opId, candidateBody)
    if type(record) ~= "table" or type(opId) ~= "string" or type(candidateBody) ~= "table" then
        return false
    end
    local ops = record.operations
    if type(ops) ~= "table" or type(ops.records) ~= "table" then
        return false
    end
    if type(record.confirmationRefs) == "table" then
        for i = 1, #record.confirmationRefs do
            local cid = record.confirmationRefs[i]
            local conf = ops.records[cid]
            if type(conf) == "table" then
                local authBody = AuthoritativeBodyFromEnvelope(conf, opId)
                if type(authBody) == "table" and AuthoritativeBodiesEqual(authBody, candidateBody) then
                    return true
                end
            end
        end
    end
    -- Also scan accepted resolutions (not listed in confirmationRefs).
    if type(ops.order) == "table" then
        for i = 1, #ops.order do
            local op = ops.records[ops.order[i]]
            if type(op) == "table" and op.kind == GS.KIND.RESOLVE_CONFLICT then
                local authBody = AuthoritativeBodyFromEnvelope(op, opId)
                if type(authBody) == "table" and AuthoritativeBodiesEqual(authBody, candidateBody) then
                    return true
                end
            end
        end
    end
    return false
end

--- Reconstruction-scoped lookup of authoritative bodies from accepted confirm/
-- resolve envelopes. Built once per reconstruction: retains distinct bodies that
-- share an ID (first/last-wins maps are insufficient). Not a persistent cache.
local function BuildReconstructionAuthLookup(record)
    -- Retain envelope body references without eager pairwise dedup (that costs
    -- N*(N-1)/2 deep equals during indexing). Exact matching happens in findExact.
    local byId = {} -- opId → { body, ... }
    local envelopeVisits = 0
    local rowVisits = 0
    local comparisons = 0
    local function noteBody(opId, body)
        if type(opId) ~= "string" or type(body) ~= "table" then
            return
        end
        local list = byId[opId]
        if not list then
            byId[opId] = { body }
            return
        end
        list[#list + 1] = body
    end
    local function indexEnvelope(envelope)
        if type(envelope) ~= "table" then
            return
        end
        envelopeVisits = envelopeVisits + 1
        if envelope.kind == GS.KIND.CONFIRM_CANDIDATE then
            local ref = envelope.candidateRef
            if type(ref) ~= "table" then
                return
            end
            if type(ref.recordId) == "string" and type(ref.body) == "table" then
                rowVisits = rowVisits + 1
                noteBody(ref.recordId, ref.body)
            end
            if type(ref.records) == "table" then
                for i = 1, #ref.records do
                    rowVisits = rowVisits + 1
                    local row = ref.records[i]
                    if type(row) == "table" and type(row.id) == "string" and type(row.body) == "table" then
                        noteBody(row.id, row.body)
                    end
                end
            end
        elseif envelope.kind == GS.KIND.RESOLVE_CONFLICT then
            local value = envelope.value
            if type(value) == "table" and type(value.contentBodies) == "table" then
                for opId, body in pairs(value.contentBodies) do
                    rowVisits = rowVisits + 1
                    if type(opId) == "string" and type(body) == "table" then
                        noteBody(opId, body)
                    end
                end
            end
        end
    end
    local ops = record and record.operations
    if type(ops) == "table" and type(ops.records) == "table" then
        if type(record.confirmationRefs) == "table" then
            for i = 1, #record.confirmationRefs do
                indexEnvelope(ops.records[record.confirmationRefs[i]])
            end
        end
        if type(ops.order) == "table" then
            for i = 1, #ops.order do
                local op = ops.records[ops.order[i]]
                if type(op) == "table" and op.kind == GS.KIND.RESOLVE_CONFLICT then
                    indexEnvelope(op)
                end
            end
        end
    end
    return {
        findExact = function(opId, candidateBody)
            local list = byId[opId]
            if type(list) ~= "table" or type(candidateBody) ~= "table" then
                return nil
            end
            for i = 1, #list do
                comparisons = comparisons + 1
                if AuthoritativeBodiesEqual(list[i], candidateBody) then
                    return list[i]
                end
            end
            return nil
        end,
        envelopeVisits = function()
            return envelopeVisits
        end,
        rowVisits = function()
            return rowVisits
        end,
        comparisons = function()
            return comparisons
        end,
    }
end

ActorMatchesMember = function(op, member)
    if type(op) ~= "table" or type(member) ~= "table" then
        return false
    end
    if type(op.actorGuid) == "string" and op.actorGuid ~= "" then
        return op.actorGuid == member.guid
    end
    if type(op.actorName) == "string" and op.actorName ~= "" then
        local gossip = GG()
        local want = gossip and gossip.NormalizePlayer and gossip.NormalizePlayer(op.actorName)
        local have = gossip and gossip.NormalizePlayer and gossip.NormalizePlayer(member.name)
        if want and have then
            return want == have
        end
        return false
    end
    -- Missing actor fields are not proof of source authorship.
    return false
end

--- Follow resolve-conflict envelopes to the underlying chosen value (bounded).
local function UnderlyingConflictValueId(ops, id)
    if type(ops) ~= "table" or type(id) ~= "string" then
        return id
    end
    local seen = {}
    local cur = id
    for _ = 1, 8 do
        if not cur or seen[cur] then
            return nil
        end
        seen[cur] = true
        local body = ops.records and ops.records[cur]
        if not body and ops.pending and ops.pending[cur] then
            body = ops.pending[cur].body
        end
        if not body and ops.conflicts and ops.conflicts[cur] then
            body = ops.conflicts[cur].body
        end
        if type(body) ~= "table" then
            return cur
        end
        if body.kind ~= GS.KIND.RESOLVE_CONFLICT then
            return cur
        end
        local value = body.value
        if type(value) ~= "table" or type(value.chosenOpId) ~= "string" then
            return nil
        end
        cur = value.chosenOpId
    end
    return nil
end

-- Forward declarations: Notify may invalidate delivery outcomes on failure.
local InvalidateAdoptionDeliveryOutcomes

local function NotifyAdoptionStateChanged(reason)
    if GS.OnAdoptionStateChanged then
        pcall(GS.OnAdoptionStateChanged, reason)
    end
    -- Fail paths historically only notified UI; also reopen/clear soft-acks.
    if reason == "failed" and InvalidateAdoptionDeliveryOutcomes then
        InvalidateAdoptionDeliveryOutcomes("failed")
    end
end

-- Clear soft-acked adoption deliveries from the provider entry so cancel/expire/
-- commit cannot leave phantom acknowledgments that suppress legitimate pulls.
-- Soft-acked bodies were ACCEPTED/DUPLICATE and are absent from unresolved; also
-- reopen provider bookmarks/coverage so a later re-adopt of the same source is
-- not skipped by an advanced pull cursor.
local function ClearAdoptionTransientAcks()
    local gossip = SF.GuildGossip
    if type(gossip) ~= "table" or type(gossip.GetProvider) ~= "function" then
        return
    end
    if type(GS.PROVIDER_ID) ~= "string" then
        return
    end
    local entry = gossip.GetProvider(GS.PROVIDER_ID)
    if type(gossip.ClearTransientDeliveryAcks) == "function" then
        gossip.ClearTransientDeliveryAcks(entry)
    elseif type(entry) == "table" then
        entry._transientDeliveryAck = nil
    end
    if type(gossip.ReopenProviderCoverage) == "function" then
        gossip.ReopenProviderCoverage(GS.PROVIDER_ID)
    end
end

-- Shared scoped recovery for adoption-state transitions and arena capacity free:
-- reopen provider unresolved/bookmarks and coalesce NotifyMeaningfulChange.
-- Session/generation guards prevent stale After(0) callbacks from reviving work
-- for a replaced or terminated adoption.
local _adoptionRecoveryNotifyPending = false
local _adoptionRecoveryNotifyScheduled = false
local _adoptionRecoveryEpoch = 0
local function FlushAdoptionDeliveryRecovery(expectedEpoch)
    -- Stale generations leave pending for the latest callback. Do not clear the
    -- scheduled latch here: begin→cancel/switch bumps the epoch and queues a
    -- newer After(0); clearing on the old fire would strand that newer work if
    -- the harness (or a lost timer) never delivers it.
    if expectedEpoch ~= nil and expectedEpoch ~= _adoptionRecoveryEpoch then
        return
    end
    _adoptionRecoveryNotifyScheduled = false
    if not _adoptionRecoveryNotifyPending then
        return
    end
    _adoptionRecoveryNotifyPending = false
    local live = GS._adoption
    -- Termination (cancel/expire) still needs the notify to clear backoff; only
    -- skip when a committed session is lingering mid-cleanup.
    if type(live) == "table" and live.committed then
        return
    end
    local gg = SF.GuildGossip
    if type(gg) == "table" and type(gg.NotifyMeaningfulChange) == "function" then
        gg.NotifyMeaningfulChange()
    elseif type(gg) == "table" and type(gg.MarkWorkPending) == "function" then
        gg.MarkWorkPending()
    end
end

local function ScheduleAdoptionDeliveryRecovery(opts)
    opts = type(opts) == "table" and opts or {}
    if type(GS.PROVIDER_ID) ~= "string" then
        return
    end
    local adop = GS._adoption
    if opts.requireOpenSession and (type(adop) ~= "table" or adop.committed) then
        return
    end
    if type(GS._onAssemblyRecovery) == "function" then
        pcall(GS._onAssemblyRecovery)
    end
    local gossip = SF.GuildGossip
    if type(gossip) == "table" and type(gossip.ReopenUnresolvedEnumeration) == "function" then
        gossip.ReopenUnresolvedEnumeration(GS.PROVIDER_ID)
    end
    -- Always bump generation and queue a callback for that generation. Coalescing
    -- onto a single latch without a new timer strands recovery when begin is
    -- followed by cancel/switch before the first After(0) runs (or when a prior
    -- abandoned timer left the latch set). Stale callbacks become no-ops via epoch.
    _adoptionRecoveryEpoch = (tonumber(_adoptionRecoveryEpoch) or 0) + 1
    local epoch = _adoptionRecoveryEpoch
    _adoptionRecoveryNotifyPending = true
    _adoptionRecoveryNotifyScheduled = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            FlushAdoptionDeliveryRecovery(epoch)
        end)
    else
        FlushAdoptionDeliveryRecovery(epoch)
    end
end

-- Legacy names used by arena-slot recovery.
local function FlushAdoptionAssemblyRecovery()
    FlushAdoptionDeliveryRecovery(_adoptionRecoveryEpoch)
end

local function ScheduleAdoptionAssemblyRecovery()
    ScheduleAdoptionDeliveryRecovery({ requireOpenSession = true })
end

InvalidateAdoptionDeliveryOutcomes = function(reason)
    -- Begin/switch: reopen suppressed mismatch outcomes so the selected source
    -- can be pulled again. Cancel/expire/fail: reopen + clear soft-acks so the
    -- prior durable index remains the only advertised set.
    if reason == "cancel" or reason == "expire" or reason == "failed"
        or reason == "source_changed" or reason == "replaced" or reason == "commit" then
        ClearAdoptionTransientAcks()
    end
    if reason == "commit" then
        -- Successful swap publishes via NotifyLocalDurableChange; no reopen storm.
        return
    end
    ScheduleAdoptionDeliveryRecovery({
        requireOpenSession = (reason == "begin" or reason == "assembly_free"),
    })
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

--- True when an open-conflict candidate set shares ancestry with `op`.
local function OpenConflictSharesAncestry(ops, targetKey, op)
    local open = ops and ops.openConflicts and ops.openConflicts[targetKey]
    if type(open) ~= "table" or type(open.candidateIds) ~= "table" or type(op) ~= "table" then
        return false
    end
    local sharedPolicy, sharedCampaign, sharedTarget = true, true, true
    local saw = false
    for i = 1, #open.candidateIds do
        local cid = open.candidateIds[i]
        local body = ops.records and ops.records[cid]
            or (ops.pending and ops.pending[cid] and ops.pending[cid].body)
            or (ops.conflicts and ops.conflicts[cid] and ops.conflicts[cid].body)
        if type(body) == "table" then
            saw = true
            if body.basePolicyRevision ~= op.basePolicyRevision then
                sharedPolicy = false
            end
            if (body.baseCampaignId or nil) ~= (op.baseCampaignId or nil) then
                sharedCampaign = false
            end
            if body.baseTargetRevision ~= op.baseTargetRevision then
                sharedTarget = false
            end
        end
    end
    return saw and sharedPolicy and sharedCampaign and sharedTarget
end

--- Classify a stale base for remote admission.
-- Sibling candidates that share conflict ancestry are retained as conflicts;
-- truly superseded bases (post-reset / advanced along another lineage) obsolete.
-- @return "apply"|"pending"|"conflict"|"obsolete", reason
local function ClassifyStaleBase(record, op, targetKey)
    local ops = record.operations
    local currentRev = CurrentTargetRevision(record, targetKey)
    local base = op.baseTargetRevision
    local policyNow = CurrentPolicyRevision(record)
    local campaignNow = record.currentCampaignId

    -- Open conflict already holds this target with shared ancestry.
    if type(ops.openConflicts) == "table" and ops.openConflicts[targetKey]
        and OpenConflictSharesAncestry(ops, targetKey, op) then
        return "conflict", "open_conflict"
    end

    -- Policy / campaign supersession takes precedence.
    if op.basePolicyRevision ~= policyNow then
        -- Concurrent same-base rank siblings: conflict, do not let arrival order
        -- supersede the other candidate as obsolete.
        if op.kind == GS.KIND.SET_EDITOR_RANK then
            local rankKey = GS._TargetKey and GS._TargetKey(op.kind, op.target)
                or "permission:editorRankPosition"
            local headId = ops.heads and ops.heads[rankKey]
            local headBody = headId and ops.records[headId]
            if type(headBody) == "table"
                and headBody.kind == GS.KIND.SET_EDITOR_RANK
                and headBody.basePolicyRevision == op.basePolicyRevision then
                return "conflict", "divergent_edit"
            end
            if OpenConflictSharesAncestry(ops, rankKey, op) then
                return "conflict", "open_conflict"
            end
        end
        -- Head advanced to a sibling that shares this op's policy base → conflict.
        local headId = ops.heads and ops.heads[targetKey]
        local headBody = headId and ops.records[headId]
        if type(headBody) == "table"
            and headBody.basePolicyRevision == op.basePolicyRevision
            and headBody.id == policyNow then
            return "conflict", "divergent_edit"
        end
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
        or (op.kind ~= GS.KIND.START_CAMPAIGN
            and (op.campaignId or nil) ~= (campaignNow or nil)) then
        if op.kind == GS.KIND.START_CAMPAIGN then
            -- Concurrent campaign starts from the same *known* parent: explicit conflict.
            local campKey = GS.CAMPAIGN_TARGET_KEY or "campaign:current"
            local headId = ops.heads and ops.heads[campKey]
            local headBody = headId and ops.records[headId]
            if type(headBody) == "table"
                and headBody.kind == GS.KIND.START_CAMPAIGN
                and (headBody.baseCampaignId or nil) == (op.baseCampaignId or nil) then
                return "conflict", "campaign_conflict"
            end
            if OpenConflictSharesAncestry(ops, campKey, op) then
                return "conflict", "campaign_conflict"
            end
            -- Unknown named parent: wait for predecessor; do not open phantom conflict.
            if type(op.baseCampaignId) == "string" and not HasAcceptedId(ops, op.baseCampaignId) then
                return "pending", "missing_campaign_predecessor"
            end
            return "conflict", "campaign_conflict"
        end
        -- Sibling campaign head that shares the same parent base → conflict, not obsolete.
        local headId = ops.heads and (ops.heads[GS.CAMPAIGN_TARGET_KEY] or ops.heads[targetKey])
        local headBody = headId and ops.records[headId]
        if type(headBody) == "table"
            and headBody.kind == GS.KIND.START_CAMPAIGN
            and (headBody.baseCampaignId or nil) == (op.baseCampaignId or nil)
            and headBody.id == campaignNow then
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

    -- #388 adjustments: append-only with commit-time floor checks. Do not open
    -- config-style divergent conflicts; incompatible negatives stay pending.
    if op.kind == GS.KIND.ADJUST_QUANTITY then
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

--- True when a resolution's declared bases match open-conflict shared ancestry
-- even if the provisional current head is one of the conflicted siblings.
local function ResolutionMatchesOpenConflictAncestry(record, stored, targetKey)
    local ops = record.operations
    local open = ops and ops.openConflicts and ops.openConflicts[targetKey]
    if type(open) ~= "table" or type(stored) ~= "table" then
        return false
    end
    if not OpenConflictSharesAncestry(ops, targetKey, {
        basePolicyRevision = stored.basePolicyRevision,
        baseCampaignId = stored.baseCampaignId,
        baseTargetRevision = stored.baseTargetRevision,
    }) then
        return false
    end
    -- Chosen must be listed among open candidates.
    local chosen = stored.value and stored.value.chosenOpId
    if type(chosen) ~= "string" or type(open.candidateIds) ~= "table" then
        return false
    end
    for i = 1, #open.candidateIds do
        if open.candidateIds[i] == chosen then
            return true
        end
    end
    return false
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
    -- Bootstrap must keep revisionId == datasetId with an empty operation store so
    -- later set-editor-rank history can replay. Advertised current policy revisions
    -- are not copied onto an empty record (State head/revision invariant).
    local ranks = GG() and GG().GetGuildRanks and GG().GetGuildRanks()
    local rankCount = type(ranks) == "table" and tonumber(ranks.count) or 0
    local defaultPos = GS.DEFAULT_EDITOR_RANK_POSITION or 3
    local editorPos = defaultPos
    if rankCount > 0 and rankCount < defaultPos then
        -- Small-guild bootstrap: reuse complete positive-integral verified-rank validation.
        local advertised = tonumber(descriptor.bootstrapEditorRankPosition)
            or tonumber(descriptor.editorRankPosition)
        local bootOk, bootErr, bootNorm = ValidateEditorRankValue(advertised)
        if not bootOk then
            return "rejected", bootErr or "invalid_editor_rank_position"
        end
        editorPos = bootNorm
    elseif descriptor.bootstrapEditorRankPosition ~= nil
        or descriptor.editorRankPosition ~= nil then
        -- Ordinary guilds: when a threshold is advertised, require integrality too.
        local advertised = tonumber(descriptor.bootstrapEditorRankPosition)
            or tonumber(descriptor.editorRankPosition)
        if advertised ~= nil then
            local bootOk, bootErr, bootNorm = ValidateEditorRankValue(advertised)
            if not bootOk then
                return "rejected", bootErr or "invalid_editor_rank_position"
            end
            editorPos = bootNorm
        end
    end

    local installActivation = GS.ACTIVATION_STAGED
    if descriptor.activation == GS.ACTIVATION_ACTIVE
        and type(descriptor.liveCutover) == "table" then
        installActivation = GS.ACTIVATION_ACTIVE
    elseif GS.IsSupportedActivation and GS.IsSupportedActivation(descriptor.activation) then
        installActivation = descriptor.activation
    end
    local record = {
        schemaVersion = GS.SCHEMA_VERSION,
        activation = installActivation,
        datasetId = descriptor.datasetId,
        permission = {
            editorRankPosition = editorPos,
            bootstrapEditorRankPosition = editorPos,
            revisionId = descriptor.datasetId,
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
        identityLinks = GS.EmptyIdentityLinks and GS.EmptyIdentityLinks() or {
            schemaVersion = 1, groups = {}, byGuid = {}, revisionId = nil,
        },
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
        liveCutover = nil,
    }

    -- Active remote datasets install with the authenticated cutover marker so
    -- joining clients adopt live authority without a local bank sample (#389).
    if installActivation == GS.ACTIVATION_ACTIVE then
        if type(descriptor.liveCutover) ~= "table" then
            return "rejected", "missing_live_cutover"
        end
        local stCut, cutReason = GS.InstallRemoteLiveCutover(record, descriptor.liveCutover, guildKey, {
            quarantinePending = false,
            forceActive = true,
            member = member,
            requireEditorAuthority = true,
            -- Empty-client active bootstrap: actor may be the original activator
            -- while the installing peer is any verified editor distributor.
            bindActorToSender = false,
            authOpts = { allowBootstrapInstall = true },
        })
        if stCut ~= "accepted" and stCut ~= "duplicate" then
            return "rejected", cutReason or "invalid_live_cutover"
        end
    end

    if GS._ValidateGuildRecordStructure then
        local ok, err = GS._ValidateGuildRecordStructure(guildKey, record)
        if not ok then
            return "rejected", err or "invalid_record"
        end
    end

    ClearConfirmationRedriveForGuild(guildKey)
    GS._root.guilds[guildKey] = record
    GS._adoptionEpoch = (tonumber(GS._adoptionEpoch) or 0) + 1
    -- Descriptor-first install: keep revisionId == datasetId (empty store). When
    -- the source advertises a different current policy, lock edits until that
    -- authenticated policy revision is reconstructed. Persist on the record so
    -- /reload cannot drop the incomplete-catch-up restriction.
    local advertised = descriptor.permissionRevisionId
    if type(advertised) == "string" and advertised ~= "" and advertised ~= descriptor.datasetId then
        record.permission.pendingPolicyRevisionId = advertised
        GS._bootstrapEditLock[guildKey] = advertised
    else
        record.permission.pendingPolicyRevisionId = nil
        GS._bootstrapEditLock[guildKey] = nil
    end
    DebugInfo("installed remote dataset key=%s dataset=%s activation=%s from=%s",
        guildKey, descriptor.datasetId, tostring(record.activation), tostring(member.name))
    if GS._NotifyLocalDurableChange then
        GS._NotifyLocalDurableChange("install")
    end
    return "accepted", nil
end

--- Clear bootstrap edit lock once the advertised policy revision is accepted.
function GS.ClearBootstrapEditLockIfCaughtUp(record, guildKey)
    if type(record) ~= "table" or type(guildKey) ~= "string" then
        return
    end
    local want = GS._bootstrapEditLock[guildKey]
    if type(want) ~= "string" and type(record.permission) == "table" then
        want = record.permission.pendingPolicyRevisionId
    end
    if type(want) ~= "string" then
        return
    end
    local have = record.permission and record.permission.revisionId
    if have == want then
        GS._bootstrapEditLock[guildKey] = nil
        if type(record.permission) == "table" then
            record.permission.pendingPolicyRevisionId = nil
        end
    end
end

--- True when descriptor-first catch-up is incomplete. Reconstructs from durable
-- permission.pendingPolicyRevisionId after reload when the runtime cache is empty.
-- @param guildKey string
-- @param record table|nil optional record (avoids re-lookup)
function GS.IsBootstrapEditLocked(guildKey, record)
    if type(guildKey) ~= "string" then
        return false
    end
    local want = GS._bootstrapEditLock[guildKey]
    if type(want) == "string" and want ~= "" then
        return true
    end
    if type(record) ~= "table" then
        record = GS._root and GS._root.guilds and GS._root.guilds[guildKey]
    end
    if type(record) == "table" and type(record.permission) == "table" then
        local pending = record.permission.pendingPolicyRevisionId
        if type(pending) == "string" and pending ~= ""
            and pending ~= record.permission.revisionId then
            GS._bootstrapEditLock[guildKey] = pending
            return true
        end
    end
    return false
end

local function NoteBufferedKindInsert(adop, body)
    if type(adop) ~= "table" or type(body) ~= "table" then
        return
    end
    local c = adop._bufCounts
    if type(c) ~= "table" then
        c = {
            acceptedOps = 0,
            transferOps = 0,
            headers = 0,
            archives = 0,
            ledgerEvents = 0,
            donationEvidence = 0,
            descId = nil,
        }
        adop._bufCounts = c
    end
    if body.kind == "dataset-desc" and body.datasetId == adop.sourceDatasetId then
        -- Descriptor replaces in place; counts stay singular.
        return
    elseif body.kind == "gs-op" then
        c.transferOps = (tonumber(c.transferOps) or 0) + 1
        if body.evidenceOnly ~= true then
            c.acceptedOps = (tonumber(c.acceptedOps) or 0) + 1
        end
    elseif body.kind == "campaign-header" then
        c.headers = (tonumber(c.headers) or 0) + 1
    elseif body.kind == "campaign-archive" then
        c.archives = (tonumber(c.archives) or 0) + 1
    elseif body.kind == "gs-ledger-event" then
        c.ledgerEvents = (tonumber(c.ledgerEvents) or 0) + 1
    elseif body.kind == "gs-evidence" then
        c.donationEvidence = (tonumber(c.donationEvidence) or 0) + 1
    end
end

local function CountBufferedKinds(adop)
    -- Prefer session-owned incremental counters; fall back to a one-shot recount
    -- only when legacy sessions lack _bufCounts (should not happen after begin).
    local acceptedOps, transferOps, headers, archives, desc = 0, 0, 0, 0, nil
    local ledgerEvents, donationEvidence = 0, 0
    local archivePages = {} -- campaignId → { meta, pages = {}, pageCount }
    local opPages = {} -- opId → { shell, pages = {}, pageCount }
    local c = adop._bufCounts
    if type(c) == "table" then
        acceptedOps = tonumber(c.acceptedOps) or 0
        transferOps = tonumber(c.transferOps) or 0
        headers = tonumber(c.headers) or 0
        archives = tonumber(c.archives) or 0
        ledgerEvents = tonumber(c.ledgerEvents) or 0
        donationEvidence = tonumber(c.donationEvidence) or 0
        if type(c.descId) == "string" then
            desc = adop.records and adop.records[c.descId]
        end
        if not desc then
            -- Descriptor id may use the stable gs:desc:<dataset> form.
            local want = "gs:desc:" .. tostring(adop.sourceDatasetId)
            desc = adop.records and adop.records[want]
            if type(desc) == "table" then
                c.descId = want
            end
        end
    else
        for i = 1, #adop.order do
            local body = adop.records[adop.order[i]]
            if type(body) == "table" then
                if body.kind == "dataset-desc" and body.datasetId == adop.sourceDatasetId then
                    desc = body
                elseif body.kind == "gs-op" then
                    transferOps = transferOps + 1
                    if body.evidenceOnly ~= true then
                        acceptedOps = acceptedOps + 1
                    end
                elseif body.kind == "campaign-header" then
                    headers = headers + 1
                elseif body.kind == "campaign-archive" then
                    archives = archives + 1
                elseif body.kind == "gs-ledger-event" then
                    ledgerEvents = ledgerEvents + 1
                elseif body.kind == "gs-evidence" then
                    donationEvidence = donationEvidence + 1
                end
            end
        end
    end
    -- Page completeness uses the incremental archive/assembly indexes only —
    -- not a full logical-order walk.
    if type(adop._archiveIndex) == "table" then
        for cid, info in pairs(adop._archiveIndex) do
            archivePages[cid] = {
                meta = info.meta,
                pages = info.pages or {},
                pageCount = info.pageCount or 1,
            }
            if type(info.meta) == "table" and not desc and info.meta.kind == "dataset-desc" then
                -- no-op; archives are not descriptors
            end
        end
    end
    if type(adop._assemblies) == "table" then
        for oid, asm in pairs(adop._assemblies) do
            opPages[oid] = {
                shell = asm.shell,
                pages = asm.pages or {},
                pageCount = asm.pageCount,
            }
        end
    end
    return desc, acceptedOps, transferOps, headers, archives, archivePages, opPages,
        ledgerEvents, donationEvidence
end

--- Assemble paged archive bodies into a single canonical archive table.
local function AssemblePagedArchive(meta, pagesByIndex)
    if type(meta) ~= "table" then
        return nil, "invalid_campaign_archive"
    end
    local function CopyArchiveEligibility(src)
        if type(src) ~= "table" then
            return nil
        end
        local eligibility = {
            baselineEstablished = src.baselineEstablished,
            baselineAt = src.baselineAt,
            tabEligibleFrom = src.tabEligibleFrom,
            items = {},
        }
        if type(src.items) == "table" then
            -- Preserve original item-id key types for Deep.equal with stored archives.
            for k, v in pairs(src.items) do
                eligibility.items[k] = v
            end
        end
        return eligibility
    end
    if type(meta.requestedItems) == "table" then
        -- Inline small archive (no pages required).
        return {
            schemaVersion = meta.schemaVersion or GS.SCHEMA_VERSION,
            campaignId = meta.campaignId,
            datasetId = meta.datasetId,
            requestedItems = meta.requestedItems,
            generation = meta.generation,
            archivedAt = meta.archivedAt,
            bankTab = tonumber(meta.bankTab),
            eligibility = CopyArchiveEligibility(meta.eligibility),
        }, nil
    end
    local pageCount = tonumber(meta.pageCount) or 1
    local merged = {}
    local got = 0
    local eligMerged = {}
    local eligGot = 0
    for page = 1, pageCount do
        local p = pagesByIndex and pagesByIndex[page]
        if type(p) ~= "table" or type(p.requestedItems) ~= "table" then
            return nil, "incomplete_archive_pages"
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
    -- Page presence already checked; count mismatch is malformed input, not "wait".
    if type(meta.itemCount) == "number" and got ~= meta.itemCount then
        return nil, "invalid_campaign_archive"
    end
    local wantElig = tonumber(meta.eligibilityItemCount)
    if wantElig ~= nil and eligGot ~= wantElig then
        return nil, "incomplete_archive_pages"
    end
    local eligibility = CopyArchiveEligibility(meta.eligibility)
    if eligibility then
        eligibility.items = eligMerged
    elseif eligGot > 0 then
        eligibility = {
            items = eligMerged,
        }
    end
    return {
        schemaVersion = meta.schemaVersion or GS.SCHEMA_VERSION,
        campaignId = meta.campaignId,
        datasetId = meta.datasetId,
        requestedItems = merged,
        generation = meta.generation,
        archivedAt = meta.archivedAt,
        bankTab = tonumber(meta.bankTab),
        eligibility = eligibility,
    }, nil
end

--- Core archive identity (items/generation/ids), ignoring eligibility/bankTab.
local function ArchiveCoreEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if a.schemaVersion ~= b.schemaVersion then
        return false
    end
    if a.campaignId ~= b.campaignId or a.datasetId ~= b.datasetId then
        return false
    end
    if a.generation ~= b.generation or a.archivedAt ~= b.archivedAt then
        return false
    end
    return DeepEqual(a.requestedItems, b.requestedItems)
end

--- When core archive identity matches, prefer the gossip-assembled body so
-- eligibility/bankTab historical proof from export replaces an op-replay snapshot
-- that omitted those fields (or diverged only on that context).
local function PreferArchiveHistoricalContext(existing, assembled)
    return ArchiveCoreEqual(existing, assembled)
end


--- True when buffered records match the authenticated source descriptor contract.
function GS:IsAdoptionTransferComplete()
    local adop = GS._adoption
    if type(adop) ~= "table" or adop.committed then
        return false, "no_adoption"
    end
    local desc, acceptedOps, transferOps, headers, archives, archivePages, opPages,
        ledgerEvents, donationEvidence =
        CountBufferedKinds(adop)
    if not desc then
        return false, "incomplete_transfer"
    end
    -- Descriptor counts must be present and exact (no silent zero-default extras).
    -- acceptedOpCount = accepted history; transferOpCount = accepted + evidenceOnly.
    -- acceptedLedgerCount / donationEvidenceCount bind staged accounting into the
    -- immutable adoption snapshot so a transfer missing advertised ledger bodies
    -- cannot complete. Production RebuildExportIndex always emits these counts.
    if desc.acceptedOpCount == nil or desc.campaignCount == nil or desc.archiveCount == nil then
        return false, "incomplete_transfer"
    end
    local expectAccepted = tonumber(desc.acceptedOpCount)
    local expectTransfer = tonumber(desc.transferOpCount)
    if expectTransfer == nil then
        -- Backward-compatible descriptor: transfer equals accepted when omitted.
        expectTransfer = expectAccepted
    end
    local expectHeaders = tonumber(desc.campaignCount)
    local expectArchives = tonumber(desc.archiveCount)
    -- Accounting manifest: enforce only when the source advertises the count.
    local hasLedgerManifest = desc.acceptedLedgerCount ~= nil
    local expectLedger = tonumber(desc.acceptedLedgerCount)
    local hasEvidenceManifest = desc.donationEvidenceCount ~= nil
    local expectDonationEvidence = tonumber(desc.donationEvidenceCount)
    if not expectAccepted or not expectTransfer or not expectHeaders or not expectArchives
        or expectAccepted ~= math.floor(expectAccepted) or expectAccepted < 0
        or expectTransfer ~= math.floor(expectTransfer) or expectTransfer < 0
        or expectTransfer < expectAccepted
        or expectHeaders ~= math.floor(expectHeaders) or expectHeaders < 0
        or expectArchives ~= math.floor(expectArchives) or expectArchives < 0 then
        return false, "incomplete_transfer"
    end
    if hasLedgerManifest then
        if expectLedger == nil or expectLedger ~= math.floor(expectLedger) or expectLedger < 0 then
            return false, "incomplete_transfer"
        end
    end
    if hasEvidenceManifest then
        if expectDonationEvidence == nil
            or expectDonationEvidence ~= math.floor(expectDonationEvidence)
            or expectDonationEvidence < 0 then
            return false, "incomplete_transfer"
        end
    end
    if acceptedOps ~= expectAccepted or transferOps ~= expectTransfer
        or headers ~= expectHeaders or archives ~= expectArchives then
        return false, "incomplete_transfer"
    end
    if hasLedgerManifest and ledgerEvents ~= expectLedger then
        return false, "incomplete_transfer"
    end
    if hasEvidenceManifest and donationEvidence ~= expectDonationEvidence then
        return false, "incomplete_transfer"
    end
    -- Exact accepted snapshot size must match descriptor (evidenceOnly excluded).
    if adop.pinnedAcceptedOpCount ~= nil and adop.pinnedAcceptedOpCount ~= expectAccepted then
        return false, "source_changed"
    end
    if adop.pinnedTransferOpCount ~= nil and adop.pinnedTransferOpCount ~= expectTransfer then
        return false, "source_changed"
    end
    if hasLedgerManifest and adop.pinnedAcceptedLedgerCount ~= nil
        and adop.pinnedAcceptedLedgerCount ~= expectLedger then
        return false, "source_changed"
    end
    if hasEvidenceManifest and adop.pinnedDonationEvidenceCount ~= nil
        and adop.pinnedDonationEvidenceCount ~= expectDonationEvidence then
        return false, "source_changed"
    end
    if #(adop.sourceAcceptedIds or {}) ~= expectAccepted then
        return false, "incomplete_transfer"
    end
    -- Paged archives must include every page referenced by meta.
    if type(archivePages) == "table" then
        for _, info in pairs(archivePages) do
            if type(info.meta) == "table" and not info.meta.requestedItems then
                local pc = tonumber(info.pageCount) or 1
                for page = 1, pc do
                    if type(info.pages[page]) ~= "table" then
                        return false, "incomplete_transfer"
                    end
                end
            end
        end
    end
    -- Paged operation manifests must include every page referenced by shell.
    if type(opPages) == "table" then
        for _, info in pairs(opPages) do
            if type(info.shell) == "table" then
                local pc = tonumber(info.pageCount) or 1
                for page = 1, pc do
                    if type(info.pages[page]) ~= "table" then
                        return false, "incomplete_transfer"
                    end
                end
            end
        end
    end
    if desc.datasetId ~= adop.sourceDatasetId then
        return false, "source_changed"
    end
    -- Source must still advertise the selected dataset/revision.
    local peer = GS._peerDatasets[adop.sourcePeer]
    if type(peer) ~= "table" or peer.datasetId ~= adop.sourceDatasetId then
        return false, "source_changed"
    end
    if type(desc.permissionRevisionId) == "string" and desc.permissionRevisionId ~= ""
        and type(peer.permissionRevisionId) == "string" and peer.permissionRevisionId ~= ""
        and desc.permissionRevisionId ~= peer.permissionRevisionId then
        return false, "source_changed"
    end
    return true, nil, desc
end

--- Abort in-progress replay session caches without touching live globals.
-- Forward-declared: BeginDatasetAdoption may replace a prior session mid-replay.
local function AbortAdoptionReplay(adop, reason)
    if type(adop) ~= "table" then
        return
    end
    if type(adop._workStats) == "table" then
        GS._lastAdoptionWorkStats = {
            confirmVisited = tonumber(adop._workStats.confirmVisited) or 0,
            confirmComparisons = tonumber(adop._workStats.confirmComparisons) or 0,
            completenessVisited = tonumber(adop._workStats.completenessVisited) or 0,
            indexVisited = tonumber(adop._workStats.indexVisited) or 0,
            assemblyVisited = tonumber(adop._workStats.assemblyVisited) or 0,
            archiveVisited = tonumber(adop._workStats.archiveVisited) or 0,
            receiveVisited = tonumber(adop._workStats.receiveVisited) or 0,
            confirmRedriveVisited = tonumber(adop._workStats.confirmRedriveVisited) or 0,
        }
    end
    -- Drop session-owned confirmation redrive state so abandoned offline records
    -- are not pinned after cancel/fail/replace. Also drop any global keyed entry
    -- that still captures the offline temp pointer.
    if type(adop.replayState) == "table" then
        adop.replayState.confirmRedrive = nil
    end
    if type(adop.replayTemp) == "table" and type(GS._confirmationRedriveByKey) == "table" then
        local temp = adop.replayTemp
        for k, st in pairs(GS._confirmationRedriveByKey) do
            if type(st) == "table" and st.record == temp then
                GS._confirmationRedriveByKey[k] = nil
            end
        end
    end
    adop.replayTemp = nil
    adop.replayState = nil
    adop.replayMember = nil
    adop._replaySessionRelay = nil
    adop._replaySessionBoundaries = nil
    adop._replayScheduled = false
    GS._lastAdoptionAbortReason = reason
    DebugWarn("adoption replay aborted: %s", tostring(reason))
end

--- Begin explicit staged dataset adoption (authorized editor). Runtime-only until commit.
-- Reuses an in-progress buffer for the same source/dataset; switching sources cancels first.
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
    local cutoverResolution = false
    if localRecord and localRecord.datasetId == sourceDatasetId then
        -- Same dataset ID is normally rejected, except authenticated live
        -- cutover-marker conflicts where adopting one complete canonical source
        -- is the explicit recovery path (#389).
        local peerEntry = GS._peerDatasets and GS._peerDatasets[member.name]
        local conflict = GS.GetLiveActivationConflictState
            and GS:GetLiveActivationConflictState() or nil
        local localMarker = localRecord.liveCutover
            and localRecord.liveCutover.cutoverMarker or nil
        if GS.IsLiveActive(localRecord) and conflict and conflict.blocked
            and type(peerEntry) == "table"
            and peerEntry.datasetId == sourceDatasetId
            and type(peerEntry.cutoverMarker) == "string"
            and peerEntry.cutoverMarker ~= ""
            and type(localMarker) == "string"
            and peerEntry.cutoverMarker ~= localMarker then
            for i = 1, #(conflict.peers or {}) do
                local p = conflict.peers[i]
                if p and p.peerName == member.name
                    and p.cutoverMarker == peerEntry.cutoverMarker then
                    cutoverResolution = true
                    break
                end
            end
        end
        if not cutoverResolution then
            return nil, "rejected", "same_dataset"
        end
    end

    local existing = GS._adoption
    if type(existing) == "table" and not existing.committed
        and existing.sourcePeer == member.name
        and existing.sourceDatasetId == sourceDatasetId
        and existing.guildKey == ctx.guildKey then
        -- Refresh freshness metadata; keep buffered transfer.
        existing.handleGeneration = ctx.handleGeneration
        existing.actorGuid = ctx.actorGuid
        existing.sourceGuid = member.guid
        return existing, "accepted", "already_pending"
    end

    local localPolicy = localRecord and localRecord.permission and localRecord.permission.revisionId
    local localCampaign = localRecord and localRecord.currentCampaignId or nil
    local localConfigSeq = localRecord
        and localRecord.accounting
        and localRecord.accounting._consumables
        and tonumber(localRecord.accounting._consumables.configSeq)
        or nil
    local localAcceptedCount = 0
    if localRecord and localRecord.operations and type(localRecord.operations.order) == "table" then
        localAcceptedCount = #localRecord.operations.order
    end
    local localAccountingMutation = 0
    if GS.GetAccountingMutationSeq then
        localAccountingMutation = GS.GetAccountingMutationSeq(localRecord)
    end
    -- Pin activation / cutover so a mid-replay local activation cannot be
    -- overwritten by publishing a staged adoption temp (#389 repair).
    local localActivation = localRecord and localRecord.activation or nil
    local localCutoverMarker = nil
    if localRecord and type(localRecord.liveCutover) == "table" then
        localCutoverMarker = localRecord.liveCutover.cutoverMarker
    end
    local previous = GS._adoption
    local switching = type(previous) == "table"
    if switching then
        AbortAdoptionReplay(previous, "replaced")
        ClearAdoptionTransientAcks()
    end
    GS._adoption = {
        epoch = (tonumber(GS._adoptionEpoch) or 0) + 1,
        sourcePeer = member.name,
        sourceGuid = member.guid,
        sourceDatasetId = sourceDatasetId,
        guildKey = ctx.guildKey,
        localDatasetId = localRecord and localRecord.datasetId or nil,
        localPolicyRevision = localPolicy,
        localCampaignId = localCampaign,
        localConfigSeq = localConfigSeq,
        localAcceptedCount = localAcceptedCount,
        localAccountingMutation = localAccountingMutation,
        localActivation = localActivation,
        localCutoverMarker = localCutoverMarker,
        cutoverResolution = cutoverResolution and true or false,
        handleGeneration = ctx.handleGeneration,
        actorGuid = ctx.actorGuid,
        records = {},
        order = {},
        _assemblies = {},
        _assemblyPageCount = 0,
        _assemblyOpCount = 0,
        _assembledByOpId = {},
        _redeliveryAssemblies = {},
        _confirmEnvelopes = {},
        _confirmByTarget = {},
        _archiveIndex = {},
        -- Incremental receive-stage completeness (avoids full-history recounts).
        _bufCounts = {
            acceptedOps = 0,
            transferOps = 0,
            headers = 0,
            archives = 0,
            ledgerEvents = 0,
            donationEvidence = 0,
            descId = nil,
        },
        _workStats = {
            confirmVisited = 0,
            confirmComparisons = 0,
            completenessVisited = 0,
            indexVisited = 0,
            assemblyVisited = 0,
            archiveVisited = 0,
            receiveVisited = 0,
            confirmRedriveVisited = 0,
        },
        -- Exact source accepted snapshot (non-evidenceOnly gs-op ids) pinned during transfer.
        sourceAcceptedIds = {},
        sourceAcceptedSet = {},
        pinnedPermissionRevisionId = nil,
        pinnedAcceptedOpCount = nil,
        pinnedTransferOpCount = nil,
        pinnedCampaignCount = nil,
        pinnedArchiveCount = nil,
        pinnedAcceptedLedgerCount = nil,
        pinnedDonationEvidenceCount = nil,
        startedAt = GetServerTime and GetServerTime() or nil,
        committed = false,
        ready = false,
    }
    DebugInfo("began dataset adoption source=%s dataset=%s", member.name, sourceDatasetId)
    if previous ~= GS._adoption then
        NotifyAdoptionStateChanged("begin")
        -- Reopen engine-suppressed mismatch outcomes for this selected source.
        InvalidateAdoptionDeliveryOutcomes("begin")
    end
    return GS._adoption, "accepted", nil
end

function GS:CancelDatasetAdoption()
    if GS._adoption then
        DebugInfo("cancelled dataset adoption dataset=%s", tostring(GS._adoption.sourceDatasetId))
        AbortAdoptionReplay(GS._adoption, "cancel")
        GS._adoption = nil
        NotifyAdoptionStateChanged("cancel")
        InvalidateAdoptionDeliveryOutcomes("cancel")
    end
    return "accepted", nil
end

local function ExpireStaleAdoption()
    local adop = GS._adoption
    if type(adop) ~= "table" or adop.committed then
        return
    end
    local now = GetServerTime and GetServerTime() or nil
    local started = tonumber(adop.startedAt)
    local maxAge = GS.MAX_ADOPTION_SECONDS or 600
    if now and started and maxAge > 0 and (now - started) > maxAge then
        DebugInfo("expired dataset adoption dataset=%s age=%s",
            tostring(adop.sourceDatasetId), tostring(now - started))
        AbortAdoptionReplay(adop, "expire")
        GS._adoption = nil
        NotifyAdoptionStateChanged("expire")
        InvalidateAdoptionDeliveryOutcomes("expire")
    end
end

GS._ExpireStaleAdoption = ExpireStaleAdoption

function GS:GetPendingAdoption()
    ExpireStaleAdoption()
    local adop = GS._adoption
    if type(adop) == "table" and not adop.committed then
        local complete = select(1, GS:IsAdoptionTransferComplete())
        adop.ready = complete and true or false
    end
    return GS._adoption
end

local function ClearAdoptionAssemblySlot(adop, opId, asm)
    if type(adop) ~= "table" or type(opId) ~= "string" or type(asm) ~= "table" then
        return
    end
    local pageN = 0
    for _ in pairs(asm.pages or {}) do
        pageN = pageN + 1
    end
    local freedArena = false
    if asm._countsTowardArena ~= false then
        local beforeOps = tonumber(adop._assemblyOpCount) or 0
        local beforePages = tonumber(adop._assemblyPageCount) or 0
        adop._assemblyPageCount = math.max(0, beforePages - pageN)
        if adop._assemblies and adop._assemblies[opId] then
            adop._assemblyOpCount = math.max(0, beforeOps - 1)
            adop._assemblies[opId] = nil
        end
        freedArena = (adop._assemblyOpCount or 0) < beforeOps
            or (adop._assemblyPageCount or 0) < beforePages
    elseif adop._redeliveryAssemblies then
        adop._redeliveryAssemblies[opId] = nil
    end
    if freedArena then
        ScheduleAdoptionAssemblyRecovery()
    end
end

local function FindAssembledLogicalRecord(adop, opId)
    if type(adop) ~= "table" or type(opId) ~= "string" then
        return nil, nil
    end
    -- Session-owned opId → logical recordId map is authoritative. Direct inserts
    -- and assembly finalization both populate it; do not rescan adop.order per
    -- fragment on cache miss.
    adop._assembledByOpId = adop._assembledByOpId or {}
    local rid = adop._assembledByOpId[opId]
    if type(rid) == "string" and type(adop.records[rid]) == "table" then
        return rid, adop.records[rid]
    end
    if type(rid) == "string" then
        adop._assembledByOpId[opId] = nil
    end
    return nil, nil
end

--- Bounded finite-integer pageCount for adoption manifests/archives.
-- Returns validated count, or nil + reason. Absent pageCount returns nil, nil.
local function ValidateAdoptionPageCount(pageCount, maxPages)
    if pageCount == nil then
        return nil, nil
    end
    pageCount = tonumber(pageCount)
    maxPages = tonumber(maxPages) or 1
    if not pageCount or pageCount ~= math.floor(pageCount)
        or pageCount < 1 or pageCount > maxPages then
        return nil, "invalid_operation"
    end
    return pageCount, nil
end

--- Coalesce outer/inner advertised pageCount values. Both may be present on a
-- gs-op shell (body.pageCount vs body.op.pageCount); conflicts reject before
-- arena mutation. Either alone is validated against maxPages.
local function CoalesceAdvertisedPageCounts(outer, inner, maxPages)
    if outer == nil and inner == nil then
        return nil, nil
    end
    local a, errA = ValidateAdoptionPageCount(outer, maxPages)
    if errA then
        return nil, errA
    end
    local b, errB = ValidateAdoptionPageCount(inner, maxPages)
    if errB then
        return nil, errB
    end
    if a ~= nil and b ~= nil and a ~= b then
        return nil, "invalid_operation"
    end
    return a or b, nil
end

local function ValidateAdoptionPageIndex(page, pageCount)
    page = tonumber(page)
    if not page or page ~= math.floor(page) or page < 1 then
        return nil, "invalid_operation"
    end
    if pageCount ~= nil and page > pageCount then
        return nil, "invalid_operation"
    end
    return page, nil
end

--- Finalize a completed assembly into one logical gs-op in adop.order.
-- Idempotent for exact redelivery of an already-finalized manifest.
local function FinalizeAdoptionAssembly(adop, opId)
    if type(adop) ~= "table" or type(opId) ~= "string" or not GS.AssembleOpFromPages then
        return false
    end
    local stats = EnsureAdoptionWorkStats(adop)
    local asm = (adop._assemblies and adop._assemblies[opId])
        or (adop._redeliveryAssemblies and adop._redeliveryAssemblies[opId])
    if type(asm) ~= "table" or type(asm.shell) ~= "table" then
        return false
    end
    local pageCount = tonumber(asm.pageCount)
    if not pageCount then
        return false
    end
    -- Guard: never iterate an unvalidated advertised count (buffer path must reject).
    local maxPages = GS.MAX_MANIFEST_PAGES or 64
    if pageCount ~= math.floor(pageCount) or pageCount < 1 or pageCount > maxPages then
        return false, "invalid_operation"
    end
    stats.assemblyVisited = (stats.assemblyVisited or 0) + 1
    for p = 1, pageCount do
        stats.assemblyVisited = (stats.assemblyVisited or 0) + 1
        if type(asm.pages[p]) ~= "table" then
            return false
        end
    end
    local existingRid, existingBody = FindAssembledLogicalRecord(adop, opId)
    local assembled, aerr = GS.AssembleOpFromPages(asm.shell, asm.pages)
    if not assembled then
        -- Complete page set that cannot assemble is a conflict when a logical
        -- manifest already exists; leave that record untouched.
        if existingRid then
            ClearAdoptionAssemblySlot(adop, opId, asm)
            return false, "id_conflict"
        end
        return false, aerr
    end
    if existingRid and existingBody then
        if DeepEqual(existingBody, assembled) then
            ClearAdoptionAssemblySlot(adop, opId, asm)
            return true, "duplicate"
        end
        -- Conflict: leave the logical record untouched.
        ClearAdoptionAssemblySlot(adop, opId, asm)
        return false, "id_conflict"
    end
    if #adop.order >= GS.MAX_ADOPTION_PENDING_RECORDS then
        return false, "full"
    end
    local logicalId = asm.shellRecordId or ("gs:op:" .. opId)
    if adop.records[logicalId] then
        -- Distinct body already occupies the shell id; do not invent a second logical op.
        ClearAdoptionAssemblySlot(adop, opId, asm)
        return false, "id_conflict"
    end
    adop.records[logicalId] = assembled
    adop.order[#adop.order + 1] = logicalId
    NoteBufferedKindInsert(adop, assembled)
    adop._assembledByOpId = adop._assembledByOpId or {}
    adop._assembledByOpId[opId] = logicalId
    -- Session-bounded exact fragment identity for independent shell/page redelivery
    -- after arena/scratch clear. Bound by assembled op count (cleared with session).
    adop._assembledFragments = adop._assembledFragments or {}
    local fragPages = {}
    for p, page in pairs(asm.pages or {}) do
        fragPages[p] = page
    end
    adop._assembledFragments[opId] = {
        shell = asm.shell,
        shellRecordId = asm.shellRecordId,
        pages = fragPages,
        pageCount = pageCount,
    }
    if assembled.evidenceOnly ~= true and type(assembled.op) == "table"
        and type(assembled.op.id) == "string" then
        local oid = assembled.op.id
        if not adop.sourceAcceptedSet[oid] then
            adop.sourceAcceptedSet[oid] = true
            adop.sourceAcceptedIds[#adop.sourceAcceptedIds + 1] = oid
        end
        IndexAdoptionEnvelope(adop, assembled.op)
    elseif type(assembled.op) == "table" then
        IndexAdoptionEnvelope(adop, assembled.op)
    end
    ClearAdoptionAssemblySlot(adop, opId, asm)
    return true
end

--- Redelivery of an already-finalized manifest: assemble in a scratch slot and
-- compare without consuming arena capacity or appending another logical record.
local function BufferAssembledRedelivery(adop, recordId, body, opId, isShell, pageCount)
    local maxPages = GS.MAX_MANIFEST_PAGES or 64
    local validatedCount, countErr = ValidateAdoptionPageCount(pageCount, maxPages)
    if countErr then
        return "rejected", countErr
    end
    pageCount = validatedCount
    -- Exact single-fragment redelivery after logical assembly: recognize each
    -- shell/page independently without requiring soft-acked siblings to replay.
    local existingRid = select(1, FindAssembledLogicalRecord(adop, opId))
    local frag = adop._assembledFragments and adop._assembledFragments[opId]
    if existingRid and type(frag) == "table" then
        if pageCount and frag.pageCount and pageCount ~= frag.pageCount then
            return "rejected", "invalid_operation"
        end
        if isShell then
            if type(frag.shell) == "table" and DeepEqual(frag.shell, body) then
                return "duplicate", "adoption_buffer"
            end
            if type(frag.shell) == "table" then
                return "rejected", "id_conflict"
            end
        else
            local p, pageErr = ValidateAdoptionPageIndex(body.page, pageCount or frag.pageCount)
            if pageErr then
                return "rejected", pageErr
            end
            if type(frag.pages) == "table" and type(frag.pages[p]) == "table" then
                if DeepEqual(frag.pages[p], body) then
                    return "duplicate", "adoption_buffer"
                end
                return "rejected", "id_conflict"
            end
        end
    end
    adop._redeliveryAssemblies = adop._redeliveryAssemblies or {}
    local asm = adop._redeliveryAssemblies[opId]
    if not asm then
        asm = { pages = {}, pageCount = pageCount, _countsTowardArena = false }
        adop._redeliveryAssemblies[opId] = asm
    elseif pageCount and asm.pageCount and asm.pageCount ~= pageCount then
        return "rejected", "invalid_operation"
    elseif pageCount and not asm.pageCount then
        asm.pageCount = pageCount
    end
    if isShell then
        if asm.shell and not DeepEqual(asm.shell, body) then
            return "rejected", "id_conflict"
        end
        asm.shell = body
        asm.shellRecordId = recordId
    else
        local p, pageErr = ValidateAdoptionPageIndex(body.page, pageCount or asm.pageCount)
        if pageErr then
            return "rejected", pageErr
        end
        if asm.pages[p] then
            if DeepEqual(asm.pages[p], body) then
                return "duplicate", "adoption_buffer"
            end
            return "rejected", "id_conflict"
        end
        asm.pages[p] = body
        if pageCount then
            asm.pageCount = asm.pageCount or pageCount
        end
    end
    local ok, detail = FinalizeAdoptionAssembly(adop, opId)
    local complete = select(1, GS:IsAdoptionTransferComplete())
    adop.ready = complete and true or false
    if complete then
        NotifyAdoptionStateChanged("ready")
    end
    if ok and detail == "duplicate" then
        return "duplicate", "adoption_buffer"
    end
    if not ok and detail == "id_conflict" then
        return "rejected", "id_conflict"
    end
    if ok then
        -- Unexpected: finalized a new logical row for an already-assembled opId.
        return "accepted", "adoption_buffer"
    end
    -- Scratch is incomplete until shell+pages arrive; do not claim a new accept.
    return "pending", "incomplete_redelivery"
end

--- Park paged op shells/pages in a bounded assembly arena (not logical order).
-- Arena-full returns pending/assembly_full so provider/transport can retry after
-- in-flight manifests finalize and free slots (no silent 24-op history cap).
local function BufferAdoptionAssembly(adop, recordId, body)
    local function finish(st, reason)
        FlushAdoptionAssemblyRecovery()
        return st, reason
    end
    local stats = EnsureAdoptionWorkStats(adop)
    stats.assemblyVisited = (stats.assemblyVisited or 0) + 1
    adop._assemblies = adop._assemblies or {}
    adop._assemblyPageCount = tonumber(adop._assemblyPageCount) or 0
    adop._assemblyOpCount = tonumber(adop._assemblyOpCount) or 0
    local maxPages = GS.MAX_MANIFEST_PAGES or 64
    local opId, pageCount
    local isShell = body.kind == "gs-op"
    if isShell then
        if type(body.op) ~= "table" or type(body.op.id) ~= "string" then
            return finish("rejected", "invalid_record")
        end
        opId = body.op.id
        if body.pageCount == nil and (type(body.op) ~= "table" or body.op.pageCount == nil) then
            return nil -- not a paged shell; caller handles as logical
        end
        local validated, countErr = CoalesceAdvertisedPageCounts(
            body.pageCount, body.op.pageCount, maxPages)
        if countErr then
            return finish("rejected", countErr)
        end
        if not validated then
            return nil
        end
        pageCount = validated
    else
        opId = body.opId
        if type(opId) ~= "string" then
            return finish("rejected", "invalid_record")
        end
        local validated, countErr = ValidateAdoptionPageCount(body.pageCount, maxPages)
        if countErr then
            return finish("rejected", countErr)
        end
        if not validated then
            return finish("rejected", "invalid_operation")
        end
        pageCount = validated
        local _, pageErr = ValidateAdoptionPageIndex(body.page, pageCount)
        if pageErr then
            return finish("rejected", pageErr)
        end
    end
    -- Exact redelivery of a completed logical manifest must not append another row.
    local existingRid = select(1, FindAssembledLogicalRecord(adop, opId))
    if existingRid then
        local st, reason = BufferAssembledRedelivery(
            adop, recordId, body, opId, isShell, pageCount)
        return finish(st, reason)
    end
    local asm = adop._assemblies[opId]
    if not asm then
        if adop._assemblyOpCount >= (GS.MAX_ADOPTION_ASSEMBLY_OPS or 24) then
            return finish("pending", "assembly_full")
        end
        asm = { pages = {}, pageCount = pageCount, _countsTowardArena = true }
        adop._assemblies[opId] = asm
        adop._assemblyOpCount = adop._assemblyOpCount + 1
    elseif pageCount and asm.pageCount and asm.pageCount ~= pageCount then
        return finish("rejected", "invalid_operation")
    elseif pageCount and not asm.pageCount then
        asm.pageCount = pageCount
    end
    if isShell then
        if asm.shell and not DeepEqual(asm.shell, body) then
            return finish("rejected", "id_conflict")
        end
        if not asm.shell then
            asm.shell = body
            asm.shellRecordId = recordId
        end
    else
        local p = select(1, ValidateAdoptionPageIndex(body.page, pageCount or asm.pageCount))
        if asm.pages[p] then
            if DeepEqual(asm.pages[p], body) then
                return finish("duplicate", "adoption_buffer")
            end
            return finish("rejected", "id_conflict")
        end
        if adop._assemblyPageCount >= (GS.MAX_ADOPTION_ASSEMBLY_PAGES or 0) then
            return finish("pending", "assembly_full")
        end
        asm.pages[p] = body
        adop._assemblyPageCount = adop._assemblyPageCount + 1
        if pageCount then
            asm.pageCount = asm.pageCount or pageCount
        end
    end
    local finalized, finDetail = FinalizeAdoptionAssembly(adop, opId)
    local complete = select(1, GS:IsAdoptionTransferComplete())
    adop.ready = complete and true or false
    if complete then
        NotifyAdoptionStateChanged("ready")
    end
    if finalized and finDetail == "duplicate" then
        return finish("duplicate", "adoption_buffer")
    end
    if not finalized and finDetail == "id_conflict" then
        return finish("rejected", "id_conflict")
    end
    -- Runtime buffering only; ApplyRecordToProvider must not IndexUpsert.
    return finish("accepted", "adoption_buffer")
end

--- Legacy name: finalize assembly for opId when shell+pages are complete.
local function CompactAdoptionOpManifest(adop, opId)
    return FinalizeAdoptionAssembly(adop, opId)
end

--- Buffer a validated gossip body into the pending adoption session.
function GS:BufferAdoptionRecord(recordId, body)
    ExpireStaleAdoption()
    local adop = GS._adoption
    if type(adop) ~= "table" or adop.committed then
        return "rejected", "no_adoption"
    end
    if type(recordId) ~= "string" or recordId == "" or type(body) ~= "table" then
        return "rejected", "invalid_record"
    end
    EnsureAdoptionWorkStats(adop)

    -- Paged op shells/pages: bounded assembly arena (not logical pending slots).
    if body.kind == "gs-op-page" then
        return BufferAdoptionAssembly(adop, recordId, body)
    end
    if body.kind == "gs-op" and type(body.op) == "table" then
        if body.pageCount ~= nil or body.op.pageCount ~= nil then
            local pc, pcErr = CoalesceAdvertisedPageCounts(
                body.pageCount, body.op.pageCount, GS.MAX_MANIFEST_PAGES or 64)
            if pcErr then
                return "rejected", pcErr
            end
            if pc then
                return BufferAdoptionAssembly(adop, recordId, body)
            end
        end
    end

    if #adop.order >= GS.MAX_ADOPTION_PENDING_RECORDS then
        return "rejected", "full"
    end

    -- Descriptor revision invalidation runs before generic same-ID handling so
    -- the production gs:desc:<dataset> id can replace content under a pinned
    -- policy or abort when accepted snapshot / pinned fields diverge.
    local function InvalidatePinnedDescriptor(descBody)
        if type(descBody) ~= "table" or descBody.datasetId ~= adop.sourceDatasetId then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            InvalidateAdoptionDeliveryOutcomes("source_changed")
            return "rejected", "source_changed"
        end
        local rev = descBody.permissionRevisionId
        local count = tonumber(descBody.acceptedOpCount)
        local transfer = tonumber(descBody.transferOpCount)
        local camp = tonumber(descBody.campaignCount)
        local arch = tonumber(descBody.archiveCount)
        local ledger = tonumber(descBody.acceptedLedgerCount)
        local donEv = tonumber(descBody.donationEvidenceCount)
        if adop.pinnedPermissionRevisionId == nil and type(rev) == "string" then
            adop.pinnedPermissionRevisionId = rev
        elseif type(rev) == "string" and adop.pinnedPermissionRevisionId ~= nil
            and rev ~= adop.pinnedPermissionRevisionId then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            InvalidateAdoptionDeliveryOutcomes("source_changed")
            return "rejected", "source_changed"
        end
        if adop.pinnedAcceptedOpCount == nil and count ~= nil then
            adop.pinnedAcceptedOpCount = count
        elseif count ~= nil and adop.pinnedAcceptedOpCount ~= nil
            and count ~= adop.pinnedAcceptedOpCount then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            InvalidateAdoptionDeliveryOutcomes("source_changed")
            return "rejected", "source_changed"
        end
        if adop.pinnedTransferOpCount == nil and transfer ~= nil then
            adop.pinnedTransferOpCount = transfer
        elseif transfer ~= nil and adop.pinnedTransferOpCount ~= nil
            and transfer ~= adop.pinnedTransferOpCount then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            InvalidateAdoptionDeliveryOutcomes("source_changed")
            return "rejected", "source_changed"
        end
        if adop.pinnedCampaignCount == nil and camp ~= nil then
            adop.pinnedCampaignCount = camp
        elseif camp ~= nil and adop.pinnedCampaignCount ~= nil and camp ~= adop.pinnedCampaignCount then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            InvalidateAdoptionDeliveryOutcomes("source_changed")
            return "rejected", "source_changed"
        end
        if adop.pinnedArchiveCount == nil and arch ~= nil then
            adop.pinnedArchiveCount = arch
        elseif arch ~= nil and adop.pinnedArchiveCount ~= nil and arch ~= adop.pinnedArchiveCount then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            InvalidateAdoptionDeliveryOutcomes("source_changed")
            return "rejected", "source_changed"
        end
        if adop.pinnedAcceptedLedgerCount == nil and ledger ~= nil then
            adop.pinnedAcceptedLedgerCount = ledger
        elseif ledger ~= nil and adop.pinnedAcceptedLedgerCount ~= nil
            and ledger ~= adop.pinnedAcceptedLedgerCount then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            InvalidateAdoptionDeliveryOutcomes("source_changed")
            return "rejected", "source_changed"
        end
        if adop.pinnedDonationEvidenceCount == nil and donEv ~= nil then
            adop.pinnedDonationEvidenceCount = donEv
        elseif donEv ~= nil and adop.pinnedDonationEvidenceCount ~= nil
            and donEv ~= adop.pinnedDonationEvidenceCount then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            InvalidateAdoptionDeliveryOutcomes("source_changed")
            return "rejected", "source_changed"
        end
        return nil
    end

    local stats = EnsureAdoptionWorkStats(adop)
    stats.receiveVisited = (tonumber(stats.receiveVisited) or 0) + 1

    -- Assembly duplicate/conflict check for ids still parked in the arena.
    if adop._assemblies then
        for oid, asm in pairs(adop._assemblies) do
            if asm.shellRecordId == recordId then
                if DeepEqual(asm.shell, body) then
                    return "duplicate", "adoption_buffer"
                end
                return "rejected", "id_conflict"
            end
        end
    end

    if adop.records[recordId] then
        if DeepEqual(adop.records[recordId], body) then
            return "duplicate", "adoption_buffer"
        end
        if body.kind == "dataset-desc" and adop.records[recordId].kind == "dataset-desc" then
            local invSt, invReason = InvalidatePinnedDescriptor(body)
            if invSt then
                return invSt, invReason
            end
            -- Same pinned fields: replace descriptor content in place.
            adop.records[recordId] = body
            if type(adop._bufCounts) == "table" then
                adop._bufCounts.descId = recordId
            end
            local complete = select(1, GS:IsAdoptionTransferComplete())
            adop.ready = complete and true or false
            if adop.ready then
                NotifyAdoptionStateChanged("ready")
            end
            return "accepted", "adoption_buffer"
        end
        return "rejected", "id_conflict"
    end

    -- Source descriptor changes during transfer invalidate the selection.
    if body.kind == "dataset-desc" then
        local invSt, invReason = InvalidatePinnedDescriptor(body)
        if invSt then
            return invSt, invReason
        end
    end

    -- Exact accepted snapshot: only non-evidence bodies count as source-accepted.
    if body.kind == "gs-op" and type(body.op) == "table" and body.evidenceOnly ~= true then
        local oid = body.op.id
        if type(oid) == "string" and not adop.sourceAcceptedSet[oid] then
            adop.sourceAcceptedSet[oid] = true
            adop.sourceAcceptedIds[#adop.sourceAcceptedIds + 1] = oid
        end
        IndexAdoptionEnvelope(adop, body.op)
    elseif body.kind == "gs-op" and type(body.op) == "table" then
        IndexAdoptionEnvelope(adop, body.op)
    end

    -- Incremental archive-page index for bounded completeness checks.
    -- Validate counts/indices before mutating the arena or logical buffer.
    -- Page-first and meta-first must reject conflicting pageCount equally.
    local maxArchivePages = GS.MAX_ARCHIVE_PAGE_COUNT or 22
    if body.kind == "campaign-archive" and type(body.campaignId) == "string" then
        local archivePc = body.pageCount
        if archivePc == nil and type(body.requestedItems) ~= "table" then
            archivePc = 1
        end
        if archivePc ~= nil then
            local pc, pcErr = ValidateAdoptionPageCount(archivePc, maxArchivePages)
            if pcErr then
                return "rejected", pcErr
            end
            archivePc = pc
        end
        adop._archiveIndex = adop._archiveIndex or {}
        local info = adop._archiveIndex[body.campaignId]
            or { meta = nil, pages = {} }
        if info.pageCount and archivePc and info.pageCount ~= archivePc then
            return "rejected", "invalid_operation"
        end
        info.meta = body
        if archivePc then
            info.pageCount = info.pageCount or archivePc
        elseif not info.pageCount then
            info.pageCount = 1
        end
        adop._archiveIndex[body.campaignId] = info
    elseif body.kind == "campaign-archive-page" and type(body.campaignId) == "string" then
        local pc, pcErr = ValidateAdoptionPageCount(body.pageCount, maxArchivePages)
        if pcErr then
            return "rejected", pcErr
        end
        if not pc then
            return "rejected", "invalid_operation"
        end
        local page, pageErr = ValidateAdoptionPageIndex(body.page, pc)
        if pageErr then
            return "rejected", pageErr
        end
        adop._archiveIndex = adop._archiveIndex or {}
        local info = adop._archiveIndex[body.campaignId]
            or { meta = nil, pages = {} }
        if info.pageCount and info.pageCount ~= pc then
            return "rejected", "invalid_operation"
        end
        -- Also reject against meta.pageCount when meta arrived first.
        if type(info.meta) == "table" and info.meta.pageCount ~= nil then
            local metaPc = tonumber(info.meta.pageCount)
            if metaPc and metaPc ~= pc then
                return "rejected", "invalid_operation"
            end
        end
        info.pages[page] = body
        info.pageCount = info.pageCount or pc
        adop._archiveIndex[body.campaignId] = info
    end

    local wasReady = adop.ready == true
    adop.records[recordId] = body
    adop.order[#adop.order + 1] = recordId
    NoteBufferedKindInsert(adop, body)
    if body.kind == "dataset-desc" and type(adop._bufCounts) == "table" then
        adop._bufCounts.descId = recordId
    end
    -- Non-paged complete ops populate the opId map so later paged redelivery
    -- does not need a full-history scan.
    if body.kind == "gs-op" and type(body.op) == "table" and type(body.op.id) == "string"
        and not tonumber(body.pageCount) and not tonumber(body.op.pageCount) then
        adop._assembledByOpId = adop._assembledByOpId or {}
        adop._assembledByOpId[body.op.id] = recordId
    end
    local complete = select(1, GS:IsAdoptionTransferComplete())
    adop.ready = complete and true or false
    if adop.ready and not wasReady then
        NotifyAdoptionStateChanged("ready")
    end
    return "accepted", "adoption_buffer"
end

--- Adoption-session work instrumentation (visited confirm/completeness records).
-- Returns the active session stats, or the last completed/aborted session stats.
function GS.GetAdoptionWorkStats()
    local adop = GS._adoption
    local stats = (type(adop) == "table" and adop._workStats) or GS._lastAdoptionWorkStats
    if type(stats) ~= "table" then
        return nil
    end
    return {
        confirmVisited = tonumber(stats.confirmVisited) or 0,
        confirmComparisons = tonumber(stats.confirmComparisons) or 0,
        completenessVisited = tonumber(stats.completenessVisited) or 0,
        indexVisited = tonumber(stats.indexVisited) or 0,
        assemblyVisited = tonumber(stats.assemblyVisited) or 0,
        archiveVisited = tonumber(stats.archiveVisited) or 0,
        receiveVisited = tonumber(stats.receiveVisited) or 0,
        confirmRedriveVisited = tonumber(stats.confirmRedriveVisited) or 0,
    }
end

--- Per-callback final-completeness stats (not replay GS._lastAdoptionSliceStats).
function GS.GetAdoptionCompletenessStats()
    local stats = GS._lastAdoptionCompletenessStats
    if type(stats) ~= "table" then
        return nil
    end
    return {
        used = tonumber(stats.used) or 0,
        budget = stats.budget,
        archiveVisited = tonumber(stats.archiveVisited) or 0,
        completenessVisited = tonumber(stats.completenessVisited) or 0,
        budgetExhausted = stats.budgetExhausted == true,
    }
end

local function NewBootstrapRecord(datasetId, guildKey, identity, bootstrapEditorPos)
    local clubId = identity and identity.clubId
    local bootPos = bootstrapEditorPos or GS.DEFAULT_EDITOR_RANK_POSITION
    return {
        schemaVersion = GS.SCHEMA_VERSION,
        activation = GS.ACTIVATION_STAGED,
        datasetId = datasetId,
        permission = {
            editorRankPosition = bootPos,
            bootstrapEditorRankPosition = bootPos,
            revisionId = datasetId,
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
        identityLinks = GS.EmptyIdentityLinks and GS.EmptyIdentityLinks() or {
            schemaVersion = 1, groups = {}, byGuid = {}, revisionId = nil,
        },
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
end

--- Persist untrusted/evidence bodies into the offline record so Commit's
-- restoreCaches(true) cannot wipe unresolved conflict evidence.
-- Reclassifies against the current head even when the body was retained earlier
-- as non-conflicting pending (arrival-independent open-conflict reconstruction).
local function DurableRetainOnRecord(record, op, reason, boundary, opts)
    opts = opts or {}
    if type(record) ~= "table" or type(op) ~= "table" or type(record.operations) ~= "table" then
        return "rejected", "invalid_record"
    end
    local ops = record.operations
    if type(boundary) == "table" and op.kind == GS.KIND.START_CAMPAIGN then
        GS._pendingCampaignBoundaries[op.id] = boundary
    end
    local st, rsn = "pending", reason or "untrusted_relay"
    local newlyRetained = false
    if GS._AdmitPendingOrConflict then
        -- Idempotent retain when already pending/conflict with equal body.
        local already = (ops.pending and ops.pending[op.id])
            or (ops.conflicts and ops.conflicts[op.id])
        if not already then
            st, rsn = GS._AdmitPendingOrConflict(ops, op, reason or "untrusted_relay")
            if st == "rejected" then
                return st, rsn
            end
            newlyRetained = (st == "pending" or st == "accepted")
        elseif already.body and not DeepEqual(already.body, op) then
            return "rejected", "id_conflict"
        end
    end
    -- Evidence-only export bodies reconstruct durable pending/conflict retention
    -- without expanding openConflicts. Bulk fill evidence (rf-*) would otherwise
    -- exhaust MAX_CONFLICT_CANDIDATES and block the real competing set / resolution.
    if opts.evidenceOnly == true or opts.skipOpenConflict == true then
        if newlyRetained and GS._NotifyLocalDurableChange
            and not (record and record._adoptionOffline) then
            GS._NotifyLocalDurableChange("remote-evidence")
        end
        return st, rsn
    end
    -- Always classify: foreign evidence that shares ancestry with the current
    -- head must open an explicit conflict, including when it arrived before the
    -- accepted sibling and was initially stored as plain pending.
    local targetKey = GS._TargetKey and GS._TargetKey(op.kind, op.target)
    if op.kind == GS.KIND.START_CAMPAIGN then
        targetKey = GS.CAMPAIGN_TARGET_KEY
    end
    if targetKey then
        local class, classReason = ClassifyStaleBase(record, op, targetKey)
        if class == "conflict" or (ops.openConflicts and ops.openConflicts[targetKey]) then
            local headId = ops.heads and ops.heads[targetKey]
            if type(headId) == "string" then
                headId = UnderlyingConflictValueId(ops, headId) or headId
            end
            local candidates = {}
            if type(headId) == "string" then
                candidates[#candidates + 1] = headId
            end
            candidates[#candidates + 1] = op.id
            local meta = nil
            if op.kind == GS.KIND.START_CAMPAIGN and type(boundary) == "table" then
                meta = { boundaries = { [op.id] = boundary } }
            end
            local mok, merr = GS._MarkTargetConflict(
                ops, targetKey, candidates, op.timestamp, meta)
            if not mok and merr == "full" then
                -- Atomic: do not leave retained candidate without conflict slot.
                if newlyRetained then
                    if ops.pending then
                        ops.pending[op.id] = nil
                    end
                    if ops.conflicts then
                        ops.conflicts[op.id] = nil
                    end
                end
                return "rejected", "full"
            end
            rsn = classReason or rsn
        end
    end
    if newlyRetained and GS._NotifyLocalDurableChange
        and not (record and record._adoptionOffline) then
        -- Schedule export for newly retained evidence (skip offline adoption temp).
        GS._NotifyLocalDurableChange("remote-evidence")
    end
    return st, rsn
end

--- Replay buffered bodies into an offline temp record (dependency-frontier waves).
-- Does not publish temp into the live guild slot until the caller swaps atomically.
-- Unknown-author history requires exact-content confirmation; source authorship or
-- a buffered confirm/resolve that binds the body is required for promotion.
--- One bounded admission/export-style slice of adoption replay.
-- Returns: moreWork (bool), err (string|nil), progress (bool)
-- Settled/deferred scans are free; Admit/retry/redrive consume slice budget.
-- Caller yields via C_Timer between slices when moreWork and no fatal err.
local function ReplayAdoptionSlice(temp, adop, member, state)
    state = state or {}
    local sliceBudget = GS.MAX_ADMISSION_WORK_PER_SLICE or 32
    local sliceUsed = 0
    local progress = false
    -- Per-slice work only. A cumulative admission counter must not reject a
    -- legal reverse-order history that retries dependents before predecessors.
    local admissions = 0
    state.dependencyWaits = 0

    -- Policy-deferral scan: resumable across callbacks. Charge every order visit
    -- and nested confirmation-search visit against the shared slice budget.
    -- Incomplete classification yields (treat as defer) rather than caching false.
    local deferRank = state.deferRankCached
    local policyNow = temp.permission and temp.permission.revisionId or temp.datasetId
    if deferRank == nil or state.deferRankPolicy ~= policyNow then
        local scan = state.deferRankScan
        if type(scan) ~= "table" or scan.policy ~= policyNow then
            scan = { pos = 1, policy = policyNow, found = false }
            state.deferRankScan = scan
        end
        local found = scan.found == true
        local scanAt = tonumber(scan.pos) or 1
        if scanAt < 1 then
            scanAt = 1
        end
        local scanComplete = false
        while scanAt <= #adop.order and sliceUsed < sliceBudget do
            local b = adop.records[adop.order[scanAt]]
            local o = (type(b) == "table" and b.kind == "gs-op" and type(b.op) == "table")
                and b.op or nil
            -- Resuming a nested confirmation search must not re-charge the order
            -- entry or starve/restart the search after a prior yield.
            local resumingSearch = scan.awaitingSearch == true or scan.confirmCursor ~= nil
            if not resumingSearch then
                sliceUsed = sliceUsed + 1
            end
            if type(o) == "table"
                and o.kind ~= GS.KIND.SET_EDITOR_RANK
                and o.kind ~= GS.KIND.CONFIRM_CANDIDATE
                and o.kind ~= GS.KIND.RESOLVE_CONFLICT
                and o.kind ~= GS.KIND.START_CAMPAIGN
                and not (temp.operations.records and temp.operations.records[o.id])
                and not (temp.operations.conflicts and temp.operations.conflicts[o.id])
                and (o.basePolicyRevision == policyNow
                    or o.basePolicyRevision == temp.datasetId) then
                -- Defer rank only while same-policy config mutations remain.
                local src = ActorMatchesMember(o, member)
                local conf = false
                if not src then
                    local remaining = sliceBudget - sliceUsed
                    if remaining < 1 then
                        -- Order-entry visit used the last unit: yield before nested
                        -- confirmation search; resume this entry without restarting.
                        scan.pos = scanAt
                        scan.awaitingSearch = true
                        scan.found = found
                        state.deferRankScan = scan
                        state.sliceUsed = sliceUsed
                        state.cursor = tonumber(state.cursor) or 1
                        state.admissions = (tonumber(state.admissions) or 0) + admissions
                        return true, nil, progress
                    end
                    local searchOpts = {
                        budget = remaining,
                        cursor = scan.confirmCursor,
                    }
                    conf = AdoptionHasConfirmationFor(
                        adop, o.id, o, member, temp.operations, searchOpts)
                    local v = tonumber(searchOpts.visited) or 0
                    if v > 0 then
                        sliceUsed = sliceUsed + v
                    end
                    if searchOpts.budgetExhausted then
                        -- Resume the same order entry; do not treat incomplete search as false.
                        scan.pos = scanAt
                        scan.confirmCursor = searchOpts.cursor
                        scan.awaitingSearch = true
                        scan.found = found
                        state.deferRankScan = scan
                        state.sliceUsed = sliceUsed
                        state.cursor = tonumber(state.cursor) or 1
                        state.admissions = (tonumber(state.admissions) or 0) + admissions
                        return true, nil, progress
                    end
                    scan.confirmCursor = nil
                    scan.awaitingSearch = nil
                else
                    scan.confirmCursor = nil
                    scan.awaitingSearch = nil
                end
                if src or conf then
                    found = true
                    scanComplete = true
                    scanAt = scanAt + 1
                    break
                end
            else
                scan.confirmCursor = nil
                scan.awaitingSearch = nil
            end
            scanAt = scanAt + 1
        end
        if not scanComplete and scanAt > #adop.order then
            scanComplete = true
        end
        if scanComplete then
            deferRank = found
            state.deferRankCached = found
            state.deferRankPolicy = policyNow
            state.deferRankScan = nil
        else
            -- Budget exhausted mid-scan: park cursor; conservative defer until done.
            scan.pos = scanAt
            scan.found = found
            state.deferRankScan = scan
            deferRank = true
        end
    end
    deferRank = deferRank == true

    local start = tonumber(state.cursor) or 1
    if start < 1 then
        start = 1
    end
    local i = start
    local scanned = 0
    local unsettledSeen = false
    while scanned < #adop.order and sliceUsed < sliceBudget do
        scanned = scanned + 1
        local body = adop.records[adop.order[i]]
        i = i + 1
        if i > #adop.order then
            i = 1
        end
        if type(body) ~= "table" then
            -- free skip
        elseif body.kind == "gs-op-page" then
            -- Pages alone do not settle; shell assembly consumes them.
        elseif body.kind == "gs-op" and type(body.op) == "table" then
            local opBody = body
            local pageCount = tonumber(body.pageCount) or tonumber(body.op.pageCount)
            if pageCount and pageCount >= 1 and GS.AssembleOpFromPages then
                -- One unit for page membership gather + assemble validation.
                sliceUsed = sliceUsed + 1
                if sliceUsed > sliceBudget then
                    state.cursor = (i - 1)
                    if state.cursor < 1 then
                        state.cursor = #adop.order
                    end
                    state.admissions = (tonumber(state.admissions) or 0) + admissions
                    state.sliceUsed = sliceUsed
                    return true, nil, progress
                end
                local pages = {}
                for j = 1, #adop.order do
                    local pb = adop.records[adop.order[j]]
                    if type(pb) == "table" and pb.kind == "gs-op-page"
                        and pb.opId == body.op.id then
                        pages[tonumber(pb.page) or 0] = pb
                    end
                end
                local assembled, aerr = GS.AssembleOpFromPages(body, pages)
                if not assembled then
                    if aerr ~= "incomplete_manifest_pages" then
                        state.cursor, state.admissions = i, admissions
                        return false, aerr or "invalid_operation", progress
                    end
                    -- wait for pages
                    unsettledSeen = true
                    opBody = nil
                else
                    opBody = assembled
                end
            end
            if type(opBody) ~= "table" or type(opBody.op) ~= "table" then
                -- incomplete paged manifest
            else
            local op = opBody.op
            local alreadyAccepted = temp.operations.records and temp.operations.records[op.id]
            local alreadyConflict = temp.operations.conflicts and temp.operations.conflicts[op.id]
            local alreadyPending = temp.operations.pending and temp.operations.pending[op.id]
            local isAuthEnvelopeEarly = op.kind == GS.KIND.CONFIRM_CANDIDATE
                or op.kind == GS.KIND.RESOLVE_CONFLICT
            -- Auth envelopes parked only in conflicts are not a finished adoption result.
            if alreadyConflict and isAuthEnvelopeEarly and not alreadyAccepted then
                temp.operations.conflicts[op.id] = nil
                alreadyConflict = nil
            end
            if alreadyAccepted or alreadyConflict then
                -- settled: free
            elseif alreadyPending then
                -- Durable evidence already retained. Catch-up admits run in the
                -- pending-retry pass below; re-admitting every scan would never
                -- go idle under a full retention history (noProgress abort).
            elseif deferRank and op.kind == GS.KIND.SET_EDITOR_RANK then
                -- deferred: free scan, but still unfinished work
                unsettledSeen = true
            else
                unsettledSeen = true
                local sourceAuthored = ActorMatchesMember(op, member)
                -- Source-authored bodies need no confirmation search.
                local confirmed = false
                if not sourceAuthored then
                    local remaining = sliceBudget - sliceUsed
                    if remaining < 1 then
                        -- Yield before nested confirmation search when the slice
                        -- has no search budget left; resume this cursor next slice.
                        state.cursor = (i - 1)
                        if state.cursor < 1 then
                            state.cursor = #adop.order
                        end
                        state.admissions = (tonumber(state.admissions) or 0) + admissions
                        state.sliceUsed = sliceUsed
                        return true, nil, progress
                    end
                    local searchOpts = {
                        budget = remaining,
                        cursor = state.confirmCursor and state.confirmCursor[op.id] or nil,
                    }
                    confirmed = AdoptionHasConfirmationFor(
                        adop, op.id, op, member, temp.operations, searchOpts)
                    local v = tonumber(searchOpts.visited) or 0
                    if v > 0 then
                        sliceUsed = sliceUsed + v
                    end
                    if searchOpts.budgetExhausted then
                        state.confirmCursor = state.confirmCursor or {}
                        state.confirmCursor[op.id] = searchOpts.cursor
                        state.cursor = (i - 1)
                        if state.cursor < 1 then
                            state.cursor = #adop.order
                        end
                        state.admissions = (tonumber(state.admissions) or 0) + admissions
                        state.sliceUsed = sliceUsed
                        return true, nil, progress
                    elseif state.confirmCursor then
                        state.confirmCursor[op.id] = nil
                    end
                end
                local isAuthEnvelope = op.kind == GS.KIND.CONFIRM_CANDIDATE
                    or op.kind == GS.KIND.RESOLVE_CONFLICT
                local hadPending = alreadyPending ~= nil
                local hadRelay = GS._pendingRelay[op.id] ~= nil
                local status, reason
                local boundary = opBody.boundary or body.boundary
                if type(boundary) ~= "table" and op.kind == GS.KIND.START_CAMPAIGN then
                    boundary = (temp.campaigns and temp.campaigns[op.id])
                        or (adop._headerByCampaignId and adop._headerByCampaignId[op.id])
                        or (GS._pendingCampaignBoundaries and GS._pendingCampaignBoundaries[op.id])
                    if type(boundary) ~= "table" then
                        for j = 1, #adop.order do
                            local pb = adop.records[adop.order[j]]
                            if type(pb) == "table" and pb.kind == "campaign-header"
                                and type(pb.header) == "table"
                                and pb.header.campaignId == op.id then
                                boundary = pb.header
                                break
                            end
                        end
                    end
                end
                local admitCtx = {
                    sender = adop.sourcePeer,
                    member = member,
                    boundary = boundary,
                    localWrite = false,
                    adoptionReplay = true,
                    offlineRecord = temp,
                    sourceAcceptedSet = adop.sourceAcceptedSet,
                    deferRank = deferRank,
                }
                if sourceAuthored then
                    admitCtx.preserveAttribution = true
                    status, reason = GS:AdmitRemoteOperation(op, admitCtx)
                elseif confirmed and not isAuthEnvelope then
                    admitCtx.preserveAttribution = true
                    status, reason = GS:AdmitRemoteOperation(op, admitCtx)
                    if status == "pending" then
                        DurableRetainOnRecord(temp, op, reason or "stale_base",
                            opBody.boundary or body.boundary)
                    end
                elseif isAuthEnvelope then
                    status, reason = DurableRetainOnRecord(
                        temp, op, "untrusted_relay", opBody.boundary or body.boundary)
                    RetainPendingRelay(op.id, {
                        body = op,
                        sender = adop.sourcePeer,
                        at = op.timestamp,
                        boundary = opBody.boundary or body.boundary,
                    })
                else
                    -- Evidence-only and other unconfirmed foreign bodies must remain in
                    -- durable retention for third-peer reconstruction even when live
                    -- classification would reject them as obsolete/unauthorized.
                    if opBody.evidenceOnly == true then
                        status, reason = DurableRetainOnRecord(
                            temp, op, "untrusted_relay", opBody.boundary or body.boundary,
                            { evidenceOnly = true })
                    else
                        admitCtx.relay = true
                        status, reason = GS:AdmitRemoteOperation(op, admitCtx)
                        if status == "pending" or status == "duplicate" then
                            DurableRetainOnRecord(temp, op, reason or "untrusted_relay",
                                opBody.boundary or body.boundary)
                        elseif status == "rejected" then
                            -- Still retain divergent evidence when capacity allows,
                            -- without auto-expanding openConflicts (candidate cap).
                            local stR, rsR = DurableRetainOnRecord(
                                temp, op, reason or "untrusted_relay",
                                opBody.boundary or body.boundary,
                                { skipOpenConflict = true })
                            if stR == "pending" or stR == "duplicate" or stR == "accepted" then
                                status, reason = stR, rsR
                            end
                        end
                    end
                end
                admissions = admissions + 1
                sliceUsed = sliceUsed + 1
                if status == "accepted" or status == "duplicate" then
                    progress = true
                    if state.worklist then state.worklist[op.id] = nil end
                    if type(op) == "table" then
                        IndexAdoptionEnvelope(adop, op)
                    end
                elseif status == "pending" then
                    local nowPending = temp.operations.pending and temp.operations.pending[op.id] ~= nil
                    local nowRelay = GS._pendingRelay[op.id] ~= nil
                    local nowConflict = temp.operations.conflicts and temp.operations.conflicts[op.id] ~= nil
                    if (nowPending and not hadPending) or (nowRelay and not hadRelay)
                        or (nowConflict and not alreadyConflict) then
                        progress = true
                        if state.worklist then state.worklist[op.id] = nil end
                    elseif reason == "missing_predecessor" or reason == "stale_base" then
                        if sourceAuthored
                            or (adop.sourceAcceptedSet and adop.sourceAcceptedSet[op.id]) then
                            -- Worklist wait: dependency may still be later in the buffer.
                            -- Persist across slices so a budget window that misses this
                            -- op cannot conclude the transfer is idle.
                            state.dependencyWaits = (state.dependencyWaits or 0) + 1
                            state.worklist = state.worklist or {}
                            state.worklist[op.id] = reason or "missing_predecessor"
                        end
                    end
                elseif status == "rejected" then
                    adop._replayRejectCounts = adop._replayRejectCounts or {}
                    adop._replayRejectCounts[reason or "rejected"] =
                        (adop._replayRejectCounts[reason or "rejected"] or 0) + 1
                end
            end
            end -- opBody valid
        elseif body.kind == "campaign-header" and type(body.header) == "table" then
            local h = body.header
            if type(h.campaignId) == "string" and temp.campaigns[h.campaignId] == nil then
                local startPresent = (temp.operations.records and temp.operations.records[h.campaignId])
                    or (temp.operations.pending and temp.operations.pending[h.campaignId])
                    or (temp.operations.conflicts and temp.operations.conflicts[h.campaignId])
                local boundaryOk = GS.ValidateCampaignBoundary
                    and GS.ValidateCampaignBoundary(h, temp, adop.guildKey)
                if boundaryOk then
                    -- Park on the adoption session (not live GS._pendingCampaignBoundaries):
                    -- replay swaps that global per slice, and final completeness runs outside.
                    -- Only count progress when newly parking or installing; re-parking an
                    -- already-known header must not reset idle detection forever.
                    local alreadyParked = adop._headerByCampaignId
                        and adop._headerByCampaignId[h.campaignId] ~= nil
                    adop._headerByCampaignId = adop._headerByCampaignId or {}
                    adop._headerByCampaignId[h.campaignId] = h
                    GS._pendingCampaignBoundaries[h.campaignId] = h
                    if startPresent then
                        temp.campaigns[h.campaignId] = h
                        progress = true
                    elseif not alreadyParked then
                        progress = true
                    else
                        unsettledSeen = true
                    end
                elseif not startPresent then
                    unsettledSeen = true
                end
            end
        elseif body.kind == "campaign-archive" and type(body.campaignId) == "string" then
            local pageCount = tonumber(body.pageCount) or 1
            local needsPages = (not body.requestedItems) and pageCount >= 1
            if temp.campaignArchives[body.campaignId] == nil then
                if temp.currentCampaignId ~= body.campaignId and temp.campaigns[body.campaignId] then
                    local pages = {}
                    if needsPages then
                        sliceUsed = sliceUsed + 1
                        local info = adop._archiveIndex and adop._archiveIndex[body.campaignId]
                        if type(info) == "table" and type(info.pages) == "table" then
                            for p, pb in pairs(info.pages) do
                                pages[p] = pb
                                EnsureAdoptionWorkStats(adop).archiveVisited =
                                    (adop._workStats.archiveVisited or 0) + 1
                            end
                        end
                    end
                    local archive, aerr = AssemblePagedArchive(body, pages)
                    if not archive then
                        if aerr == "incomplete_archive_pages" then
                            unsettledSeen = true
                        else
                            state.cursor, state.admissions = i, admissions
                            return false, aerr or "invalid_campaign_archive", progress
                        end
                    elseif not (GS.ValidateCampaignArchive
                        and GS.ValidateCampaignArchive(archive, body.campaignId, temp)) then
                        state.cursor, state.admissions = i, admissions
                        return false, "invalid_campaign_archive", progress
                    else
                        temp.campaignArchives[body.campaignId] = archive
                        progress = true
                        sliceUsed = sliceUsed + 1
                    end
                end
            else
                local pages = {}
                if needsPages then
                    sliceUsed = sliceUsed + 1
                    local info = adop._archiveIndex and adop._archiveIndex[body.campaignId]
                    if type(info) == "table" and type(info.pages) == "table" then
                        for p, pb in pairs(info.pages) do
                            pages[p] = pb
                            EnsureAdoptionWorkStats(adop).archiveVisited =
                                (adop._workStats.archiveVisited or 0) + 1
                        end
                    end
                end
                local archive, aerr = AssemblePagedArchive(body, pages)
                if not archive then
                    if aerr == "incomplete_archive_pages" then
                        -- Generated presence alone is insufficient for advertised pages.
                        unsettledSeen = true
                        state.archiveNeedsPages = state.archiveNeedsPages or {}
                        state.archiveNeedsPages[body.campaignId] = true
                    else
                        state.cursor, state.admissions = i, admissions
                        return false, aerr or "invalid_campaign_archive", progress
                    end
                elseif PreferArchiveHistoricalContext(
                    temp.campaignArchives[body.campaignId], archive) then
                    temp.campaignArchives[body.campaignId] = archive
                elseif not DeepEqual(temp.campaignArchives[body.campaignId], archive) then
                    state.cursor, state.admissions = i, admissions
                    return false, "archive_conflict", progress
                else
                    if state.archiveNeedsPages then
                        state.archiveNeedsPages[body.campaignId] = nil
                    end
                end
            end
        elseif body.kind == "gs-evidence" and type(body.evidence) == "table" then
            -- Transfer source direct observations. Votes use the authenticated
            -- source peer only; verified totals come from gs-ledger-event transfer.
            local evidence = body.evidence
            local campId = evidence.campaignId or body.campaignId or temp.currentCampaignId
            local orderId = adop.order[i]
            -- Session-owned occurrence buckets: fingerprint groups candidates;
            -- MatchScore decides same-occurrence (fp alone is not identity).
            -- Index the accepted ledger tail once per session (byId + byOcc) so
            -- unmatched bodies do not rescan O(events) work per body.
            state.acctIndex = state.acctIndex or { byId = {}, byOcc = {}, pendingOcc = {} }
            local function occurrenceFp(row)
                if type(row) ~= "table" then return nil end
                local fp = GS.OccurrenceFingerprint and GS.OccurrenceFingerprint(row)
                if type(fp) == "string" and fp ~= "" then
                    return fp
                end
                return tostring(row.coreSignature or "") .. "|"
                    .. tostring(row.itemId or "") .. "|"
                    .. tostring(row.quantity or "")
            end
            local function bucketHasMatch(bucket, row)
                if type(bucket) ~= "table" then return false end
                for bi = 1, #bucket do
                    if GS.EvidenceOccurrenceMatches
                        and GS.EvidenceOccurrenceMatches(bucket[bi], row) then
                        return true
                    end
                end
                return false
            end
            local function rememberOcc(map, row)
                local fp = occurrenceFp(row)
                if not fp then return end
                local bucket = map[fp]
                if type(bucket) ~= "table" then
                    bucket = {}
                    map[fp] = bucket
                end
                if not bucketHasMatch(bucket, row) and #bucket < 8 then
                    bucket[#bucket + 1] = {
                        coreSignature = row.coreSignature,
                        itemId = row.itemId,
                        quantity = row.quantity,
                        approxTxnTime = row.approxTxnTime or row.timestamp,
                        occurrenceIndex = row.occurrenceIndex,
                        neighborsOlder = row.neighborsOlder,
                        neighborsNewer = row.neighborsNewer,
                        guildGuid = row.guildGuid,
                        bankTab = row.bankTab,
                        generation = row.generation,
                    }
                end
            end
            local function indexLedgerRow(e)
                if type(e) ~= "table" then return end
                if type(e.id) == "string" and e.id ~= "" then
                    state.acctIndex.byId[e.id] = true
                end
                if type(e.txnId) == "string" and e.txnId ~= "" then
                    state.acctIndex.byId[e.txnId] = true
                end
                if type(e.opId) == "string" and e.opId ~= "" then
                    state.acctIndex.byId[e.opId] = true
                end
                rememberOcc(state.acctIndex.byOcc, e)
            end
            local function catchUpAcctIndex()
                local archive = temp.accounting and temp.accounting._consumableEventArchive
                local events = temp.accounting and temp.accounting._consumableEvents
                local archTail = tonumber(state.acctIndexArchiveTail) or 0
                local liveTail = tonumber(state.acctIndexLiveTail) or 0
                if type(archive) == "table" then
                    for j = archTail + 1, #archive do
                        if sliceUsed >= sliceBudget then
                            state.acctIndexArchiveTail = j - 1
                            return false
                        end
                        sliceUsed = sliceUsed + 1
                        indexLedgerRow(archive[j])
                        state.acctIndexArchiveTail = j
                    end
                end
                if type(events) == "table" then
                    for j = liveTail + 1, #events do
                        if sliceUsed >= sliceBudget then
                            state.acctIndexLiveTail = j - 1
                            return false
                        end
                        sliceUsed = sliceUsed + 1
                        indexLedgerRow(events[j])
                        state.acctIndexLiveTail = j
                    end
                end
                return true
            end
            local function yieldReplayCursor()
                unsettledSeen = true
                state.cursor = (i - 1)
                if state.cursor < 1 then
                    state.cursor = #adop.order
                end
                state.admissions = (tonumber(state.admissions) or 0) + admissions
                state.sliceUsed = sliceUsed
                return true, nil, progress
            end
            local alreadyEv = false
            local evFp = occurrenceFp(evidence)
            if evFp and bucketHasMatch(state.acctIndex.pendingOcc[evFp], evidence) then
                alreadyEv = true
            elseif evFp and bucketHasMatch(state.acctIndex.byOcc[evFp], evidence) then
                alreadyEv = true
            elseif state.skipEvidence and state.skipEvidence[orderId] then
                -- Terminally classified non-retained evidence: do not re-admit.
                unsettledSeen = true
                alreadyEv = true
            else
                if not catchUpAcctIndex() then
                    return yieldReplayCursor()
                end
                if evFp and bucketHasMatch(state.acctIndex.byOcc[evFp], evidence) then
                    alreadyEv = true
                else
                    -- Pending observations are not part of the ledger index; scan
                    -- the campaign pending list under the shared slice budget.
                    state.evidenceScanCursor = state.evidenceScanCursor or {}
                    local nest = state.evidenceScanCursor[orderId]
                    if type(nest) ~= "table" then
                        nest = { phase = "pending", pos = 1 }
                    end
                    local byCampaign = temp.observations and temp.observations.byCampaign
                    local pending = byCampaign and byCampaign[campId] and byCampaign[campId].pending
                    if type(pending) == "table" then
                        for pi = nest.pos, #pending do
                            if sliceUsed >= sliceBudget then
                                state.evidenceScanCursor[orderId] = { phase = "pending", pos = pi }
                                return yieldReplayCursor()
                            end
                            sliceUsed = sliceUsed + 1
                            local c = pending[pi]
                            if type(c) == "table" and type(c.evidence) == "table"
                                and GS.EvidenceOccurrenceMatches
                                and GS.EvidenceOccurrenceMatches(c.evidence, evidence) then
                                alreadyEv = true
                                rememberOcc(state.acctIndex.pendingOcc, c.evidence)
                                break
                            end
                        end
                    end
                    if state.evidenceScanCursor then
                        state.evidenceScanCursor[orderId] = nil
                    end
                end
            end
            if alreadyEv then
                -- settled or terminally skipped
            else
                if sliceUsed >= sliceBudget then
                    return yieldReplayCursor()
                end
                local beforePending = 0
                local byCampPre = temp.observations and temp.observations.byCampaign
                local pendPre = byCampPre and byCampPre[campId] and byCampPre[campId].pending
                if type(pendPre) == "table" then
                    beforePending = #pendPre
                end
                evidence.datasetId = body.datasetId or temp.datasetId
                evidence.campaignId = campId
                local stEv = GS:AdmitDirectObservation(evidence, {
                    sender = adop.sourcePeer,
                    member = member,
                    offlineRecord = temp,
                    campaignId = campId,
                    adoptionReplay = true,
                    localWrite = false,
                })
                admissions = admissions + 1
                sliceUsed = sliceUsed + 1
                if stEv == "accepted" or stEv == "duplicate" then
                    progress = true
                    rememberOcc(state.acctIndex.pendingOcc, evidence)
                elseif stEv == "pending" then
                    local afterPending = 0
                    local byCampPost = temp.observations and temp.observations.byCampaign
                    local pendPost = byCampPost and byCampPost[campId] and byCampPost[campId].pending
                    if type(pendPost) == "table" then
                        afterPending = #pendPost
                    end
                    if afterPending ~= beforePending then
                        progress = true
                        rememberOcc(state.acctIndex.pendingOcc, evidence)
                    else
                        -- No durable cluster stored: classify terminal for this
                        -- transfer so async replay cannot requeue forever.
                        state.skipEvidence = state.skipEvidence or {}
                        state.skipEvidence[orderId] = true
                        unsettledSeen = true
                    end
                else
                    unsettledSeen = true
                end
            end
        elseif body.kind == "gs-ledger-event" and type(body.event) == "table" then
            local event = body.event
            local eid = event.id or event.opId or event.txnId
            state.acctIndex = state.acctIndex or { byId = {}, byOcc = {}, pendingOcc = {} }
            local function occurrenceFpLe(row)
                if type(row) ~= "table" then return nil end
                local fp = GS.OccurrenceFingerprint and GS.OccurrenceFingerprint(row)
                if type(fp) == "string" and fp ~= "" then
                    return fp
                end
                return tostring(row.coreSignature or "") .. "|"
                    .. tostring(row.itemId or "") .. "|"
                    .. tostring(row.quantity or "")
            end
            local function bucketHasMatchLe(bucket, row)
                if type(bucket) ~= "table" then return false end
                for bi = 1, #bucket do
                    if GS.EvidenceOccurrenceMatches
                        and GS.EvidenceOccurrenceMatches(bucket[bi], row) then
                        return true
                    end
                end
                return false
            end
            local function rememberOccLe(map, row)
                local fp = occurrenceFpLe(row)
                if not fp then return end
                local bucket = map[fp]
                if type(bucket) ~= "table" then
                    bucket = {}
                    map[fp] = bucket
                end
                if not bucketHasMatchLe(bucket, row) and #bucket < 8 then
                    bucket[#bucket + 1] = {
                        coreSignature = row.coreSignature,
                        itemId = row.itemId,
                        quantity = row.quantity,
                        approxTxnTime = row.approxTxnTime or row.timestamp,
                        occurrenceIndex = row.occurrenceIndex,
                        neighborsOlder = row.neighborsOlder,
                        neighborsNewer = row.neighborsNewer,
                        guildGuid = row.guildGuid,
                        bankTab = row.bankTab,
                        generation = row.generation,
                    }
                end
            end
            local function indexLedgerRowLe(e)
                if type(e) ~= "table" then return end
                if type(e.id) == "string" and e.id ~= "" then
                    state.acctIndex.byId[e.id] = true
                end
                if type(e.txnId) == "string" and e.txnId ~= "" then
                    state.acctIndex.byId[e.txnId] = true
                end
                if type(e.opId) == "string" and e.opId ~= "" then
                    state.acctIndex.byId[e.opId] = true
                end
                rememberOccLe(state.acctIndex.byOcc, e)
            end
            local function catchUpAcctIndexLe()
                local archive = temp.accounting and temp.accounting._consumableEventArchive
                local events = temp.accounting and temp.accounting._consumableEvents
                local archTail = tonumber(state.acctIndexArchiveTail) or 0
                local liveTail = tonumber(state.acctIndexLiveTail) or 0
                if type(archive) == "table" then
                    for j = archTail + 1, #archive do
                        if sliceUsed >= sliceBudget then
                            state.acctIndexArchiveTail = j - 1
                            return false
                        end
                        sliceUsed = sliceUsed + 1
                        indexLedgerRowLe(archive[j])
                        state.acctIndexArchiveTail = j
                    end
                end
                if type(events) == "table" then
                    for j = liveTail + 1, #events do
                        if sliceUsed >= sliceBudget then
                            state.acctIndexLiveTail = j - 1
                            return false
                        end
                        sliceUsed = sliceUsed + 1
                        indexLedgerRowLe(events[j])
                        state.acctIndexLiveTail = j
                    end
                end
                return true
            end
            local function yieldReplayCursorLe()
                unsettledSeen = true
                state.cursor = (i - 1)
                if state.cursor < 1 then
                    state.cursor = #adop.order
                end
                state.admissions = (tonumber(state.admissions) or 0) + admissions
                state.sliceUsed = sliceUsed
                return true, nil, progress
            end
            local alreadyLe = false
            -- byId is exact-ID only (never collapses distinct reminted txn ids).
            if type(eid) == "string" and eid ~= "" and state.acctIndex.byId[eid] then
                alreadyLe = true
            elseif type(event.txnId) == "string" and event.txnId ~= ""
                and state.acctIndex.byId[event.txnId] then
                alreadyLe = true
            elseif type(event.opId) == "string" and event.opId ~= ""
                and state.acctIndex.byId[event.opId] then
                alreadyLe = true
            else
                if not catchUpAcctIndexLe() then
                    return yieldReplayCursorLe()
                end
                if type(eid) == "string" and eid ~= "" and state.acctIndex.byId[eid] then
                    alreadyLe = true
                elseif type(event.txnId) == "string" and event.txnId ~= ""
                    and state.acctIndex.byId[event.txnId] then
                    alreadyLe = true
                elseif type(event.opId) == "string" and event.opId ~= ""
                    and state.acctIndex.byId[event.opId] then
                    alreadyLe = true
                end
            end
            if alreadyLe then
                -- settled
            else
                if sliceUsed >= sliceBudget then
                    return yieldReplayCursorLe()
                end
                event.datasetId = body.datasetId or temp.datasetId
                local stLe = GS:AdmitLedgerEvent(event, {
                    sender = adop.sourcePeer,
                    member = member,
                    offlineRecord = temp,
                    adoptionReplay = true,
                    preserveAttribution = true,
                    localWrite = false,
                })
                admissions = admissions + 1
                sliceUsed = sliceUsed + 1
                if stLe == "accepted" or stLe == "duplicate" then
                    progress = true
                    indexLedgerRowLe(event)
                    -- Keep tails consistent with lists that grew via Admit.
                    local live = temp.accounting and temp.accounting._consumableEvents
                    local arch = temp.accounting and temp.accounting._consumableEventArchive
                    if type(live) == "table" then
                        state.acctIndexLiveTail = #live
                    end
                    if type(arch) == "table" then
                        state.acctIndexArchiveTail = #arch
                    end
                else
                    -- Floor-held adjustments / rejected bodies remain unsettled.
                    unsettledSeen = true
                end
            end
        end
    end
    state.cursor = i

    -- Pending retries: one unit to collect eligible retries, then admit under budget.
    if sliceUsed < sliceBudget and temp.operations.pending then
        sliceUsed = sliceUsed + 1
        local retryIds = {}
        for pid, pend in pairs(temp.operations.pending) do
            local pob = pend and pend.body
            if type(pob) == "table"
                and not (temp.operations.records and temp.operations.records[pid]) then
                -- Adoption transfer order may park dependents before predecessors.
                -- Skip stable evidence-only retention (untrusted_relay/evidence): re-admitting
                -- the full 128-cap set every slice never progresses and never goes idle.
                local pr = pend.reason
                if pr ~= "untrusted_relay" and pr ~= "evidence" then
                    retryIds[#retryIds + 1] = pid
                end
            end
        end
        table.sort(retryIds)
        for ri = 1, #retryIds do
            if sliceUsed >= sliceBudget then
                break
            end
            local pid = retryIds[ri]
            local pend = temp.operations.pending[pid]
            local pob = pend and pend.body
            if type(pob) == "table" then
                -- Remove only for the admit attempt; restore evidence if rejected so
                -- bulk evidenceOnly history cannot be dropped as obsolete on retry.
                temp.operations.pending[pid] = nil
                local st2, rs2 = GS:AdmitRemoteOperation(pob, {
                    sender = adop.sourcePeer,
                    member = member,
                    localWrite = false,
                    adoptionReplay = true,
                    offlineRecord = temp,
                    preserveAttribution = true,
                    sourceAcceptedSet = adop.sourceAcceptedSet,
                })
                admissions = admissions + 1
                sliceUsed = sliceUsed + 1
                if st2 == "accepted" or st2 == "duplicate" then
                    progress = true
                elseif st2 == "pending" then
                    DurableRetainOnRecord(temp, pob, rs2 or "stale_base", nil,
                        { skipOpenConflict = true })
                    if temp.operations.records and temp.operations.records[pid] then
                        progress = true
                    end
                else
                    DurableRetainOnRecord(temp, pob, rs2 or "untrusted_relay", nil,
                        { skipOpenConflict = true })
                end
            end
        end
    end

    -- Confirmation redrive: session-owned cursor charged against remaining budget.
    -- A completed pass stays done until new admits or promotions require another
    -- predecessor-late pass. Mid-pass admit progress must not wipe the cursor.
    local redriveIncomplete = false
    local admitProgress = progress
    local hasConfirmRefs = type(temp.confirmationRefs) == "table" and #temp.confirmationRefs > 0
    if admitProgress then
        if state.confirmRedriveComplete then
            state.confirmRedriveComplete = false
            state.confirmRedrive = { pos = 1, remaining = nil }
            state.confirmRedriveAgain = nil
        elseif type(state.confirmRedrive) == "table" then
            -- Pass in flight: finish current remaining, then run another full pass.
            state.confirmRedriveAgain = true
        else
            state.confirmRedriveComplete = false
            state.confirmRedrive = { pos = 1, remaining = nil }
        end
    end
    if hasConfirmRefs and not state.confirmRedriveComplete then
        if sliceUsed < sliceBudget then
            state.confirmRedrive = state.confirmRedrive or { pos = 1, remaining = nil }
            local budgetLeft = sliceBudget - sliceUsed
            local done, visited, promoted, redriveErr = GS.RedriveExactContentConfirmations(temp, {
                adoptionReplay = true,
                offlineRecord = temp,
                sender = adop.sourcePeer,
                member = member,
                deferRank = deferRank,
                redriveBudget = budgetLeft,
                redriveState = state.confirmRedrive,
            })
            -- Capacity-blocked confirmation apply: fail closed without publish.
            if redriveErr == "full" then
                return false, "full", progress
            end
            visited = tonumber(visited) or 0
            promoted = tonumber(promoted) or 0
            if visited > 0 then
                sliceUsed = sliceUsed + visited
                admissions = admissions + 1
            end
            if promoted > 0 then
                progress = true
                -- Promotions advance heads; envelopes earlier in this pass may
                -- still need another full scan (predecessor-late confirms).
                state.confirmRedriveAgain = true
            end
            if done then
                state.confirmRedrive = nil
                if state.confirmRedriveAgain then
                    state.confirmRedriveAgain = nil
                    state.confirmRedriveComplete = false
                    state.confirmRedrive = { pos = 1, remaining = nil }
                    redriveIncomplete = true
                else
                    state.confirmRedriveComplete = true
                end
            else
                redriveIncomplete = true
            end
        else
            redriveIncomplete = true
        end
    end

    if progress then
        state.idlePasses = 0
        state.noProgressSlices = 0
        -- Rescan deferral when policy moved; otherwise keep the cached frontier.
        local policyAfter = temp.permission and temp.permission.revisionId or temp.datasetId
        if state.deferRankPolicy ~= policyAfter then
            state.deferRankCached = nil
            state.deferRankScan = nil
            state.deferRankPolicy = policyAfter
        elseif deferRank then
            -- A non-rank settle may have cleared the deferral reason.
            state.deferRankCached = nil
        end
    else
        -- Worklist waits are not stalls. Budget-exhausted slices that made no
        -- durable progress (e.g. ≥32 pending-without-store bodies) still count
        -- toward termination so async ContinueAdoptionReplay cannot requeue forever.
        local hasWorklist = false
        if type(state.worklist) == "table" then
            for _ in pairs(state.worklist) do
                hasWorklist = true
                break
            end
        end
        if not hasWorklist then
            state.noProgressSlices = (tonumber(state.noProgressSlices) or 0) + 1
        end
    end

    state.admissions = (tonumber(state.admissions) or 0) + admissions
    state.sliceUsed = sliceUsed
    state.cursor = i
    local budgetHit = sliceUsed >= sliceBudget
    local moreWork = progress or budgetHit or redriveIncomplete or (state.deferRankScan ~= nil)
    -- Persistent worklist counts as unsettled even when this slice missed those ids.
    local worklistPending = false
    if type(state.worklist) == "table" then
        for wid, _ in pairs(state.worklist) do
            if not (temp.operations.records and temp.operations.records[wid])
                and not (temp.operations.conflicts and temp.operations.conflicts[wid])
                and not (temp.operations.pending and temp.operations.pending[wid]) then
                worklistPending = true
                state.dependencyWaits = (state.dependencyWaits or 0) + 1
            else
                state.worklist[wid] = nil
            end
        end
    end
    if worklistPending then
        unsettledSeen = true
    end
    local maxNoProgress = math.max(8, (#adop.order * 2) + 8)
    if (tonumber(state.noProgressSlices) or 0) > maxNoProgress and not worklistPending then
        return false, "incomplete_transfer", progress
    end
    if not progress and not budgetHit and unsettledSeen then
        if (tonumber(state.dependencyWaits) or 0) > 0 or worklistPending then
            -- Source-accepted envelopes waiting on later buffer deps: keep scanning
            -- for a finite number of slices (not an unbounded timer loop).
            state.idlePasses = 0
            state.dependencyWaitSlices = (tonumber(state.dependencyWaitSlices) or 0) + 1
            local maxDep = math.max(8, (#adop.order * 2) + 8)
            if state.dependencyWaitSlices > maxDep then
                return false, "incomplete_transfer", progress
            end
            moreWork = true
        else
            state.dependencyWaitSlices = 0
            -- Full scan found dependents waiting with no progress: finite stall.
            state.idlePasses = (tonumber(state.idlePasses) or 0) + 1
            local maxIdle = math.max(4, #adop.order + 2)
            if state.idlePasses > maxIdle then
                return false, "incomplete_transfer", progress
            end
            moreWork = false
        end
    elseif not progress and not budgetHit and not unsettledSeen then
        moreWork = state.deferRankScan ~= nil
    end
    if progress then
        state.dependencyWaitSlices = 0
        state.quietScanned = 0
    elseif unsettledSeen or budgetHit then
        state.quietScanned = 0
    end
    -- A quiet slice that only saw already-retained bodies must not go idle until
    -- it has revolutioned the full buffer (later evidenceOnly rows may remain).
    if moreWork == false and not progress and not budgetHit and not unsettledSeen
        and state.deferRankScan == nil then
        state.quietScanned = (tonumber(state.quietScanned) or 0) + scanned
        if state.quietScanned < #adop.order then
            moreWork = true
        else
            state.quietScanned = 0
        end
    end
    -- Unfinished confirmation redrive is a hard completion gate: idle/quiet
    -- branches above must not clear moreWork while envelopes remain.
    if redriveIncomplete then
        moreWork = true
    end
    local ws = EnsureAdoptionWorkStats(adop)
    GS._lastAdoptionSliceStats = {
        used = sliceUsed,
        budget = sliceBudget,
        scanned = scanned,
        confirmVisited = tonumber(ws.confirmVisited) or 0,
        completenessVisited = tonumber(ws.completenessVisited) or 0,
        indexVisited = tonumber(ws.indexVisited) or 0,
        assemblyVisited = tonumber(ws.assemblyVisited) or 0,
        archiveVisited = tonumber(ws.archiveVisited) or 0,
    }
    return moreWork, nil, progress
end

--- Run fn with adoption session relay/boundary caches swapped in.
-- Live globals stay untouched across timer yields; cancel/expire discard the session.
local function WithAdoptionSessionCaches(adop, fn)
    local savedRelay = GS._pendingRelay
    local savedBoundaries = GS._pendingCampaignBoundaries
    adop._replaySessionRelay = adop._replaySessionRelay or {}
    adop._replaySessionBoundaries = adop._replaySessionBoundaries or {}
    GS._pendingRelay = adop._replaySessionRelay
    GS._pendingCampaignBoundaries = adop._replaySessionBoundaries
    local ok, a, b, c = pcall(fn)
    adop._replaySessionRelay = GS._pendingRelay
    adop._replaySessionBoundaries = GS._pendingCampaignBoundaries
    GS._pendingRelay = savedRelay
    GS._pendingCampaignBoundaries = savedBoundaries
    if not ok then
        error(a)
    end
    return a, b, c
end

--- Shared completeness: operations settled AND advertised headers/archives present.
-- opts.budget / opts.cursor resume foreign-confirmation and archive checks so the
-- final publish gate cannot synchronously cross-product a full legal history.
-- Source-authored bodies skip confirmation search entirely.
-- Per-callback work is published on GS._lastAdoptionCompletenessStats (separate
-- from replay GS._lastAdoptionSliceStats).
local function ValidateAdoptionCompleteness(temp, adop, member, opts)
    opts = opts or {}
    adop._workStats = adop._workStats or {
        confirmVisited = 0,
        confirmComparisons = 0,
        completenessVisited = 0,
    }
    local budget = tonumber(opts.budget) or math.huge
    -- Per-call visit budget; resume position lives in opts.cursor only.
    local visited = 0
    local archiveVisitedCall = 0
    local start = tonumber(opts.cursor) or 1
    if start < 1 then
        start = 1
    end
    local function publishCompletenessStats()
        local finiteBudget = budget
        if finiteBudget == math.huge then
            finiteBudget = nil
        end
        GS._lastAdoptionCompletenessStats = {
            used = visited,
            budget = finiteBudget,
            archiveVisited = archiveVisitedCall,
            completenessVisited = visited,
            budgetExhausted = opts.budgetExhausted == true,
        }
    end
    for i = start, #adop.order do
        if visited >= budget then
            opts.cursor = i
            opts.budgetExhausted = true
            publishCompletenessStats()
            return false, "budget"
        end
        local body = adop.records[adop.order[i]]
        visited = visited + 1
        adop._workStats.completenessVisited = (adop._workStats.completenessVisited or 0) + 1
        if type(body) == "table" and body.kind == "gs-op" and type(body.op) == "table" then
            local oid = body.op.id
            local sourceAuthored = ActorMatchesMember(body.op, member)
            local confirmed = false
            if not sourceAuthored then
                local searchOpts = {
                    budget = math.max(1, budget - visited),
                    cursor = opts.confirmCursor and opts.confirmCursor[oid] or nil,
                }
                confirmed = AdoptionHasConfirmationFor(
                    adop, oid, body.op, member, temp.operations, searchOpts)
                visited = visited + (tonumber(searchOpts.visited) or 0)
                if searchOpts.budgetExhausted then
                    opts.confirmCursor = opts.confirmCursor or {}
                    opts.confirmCursor[oid] = searchOpts.cursor
                    opts.cursor = i
                    opts.budgetExhausted = true
                    publishCompletenessStats()
                    return false, "budget"
                elseif opts.confirmCursor then
                    opts.confirmCursor[oid] = nil
                end
            end
            local inRecords = temp.operations.records and temp.operations.records[oid]
            local inConflicts = temp.operations.conflicts and temp.operations.conflicts[oid]
            local inPending = temp.operations.pending and temp.operations.pending[oid]
            local settled = false
            if sourceAuthored or confirmed then
                local isEnvelope = body.op.kind == GS.KIND.CONFIRM_CANDIDATE
                    or body.op.kind == GS.KIND.RESOLVE_CONFLICT
                settled = inRecords or (inConflicts and not isEnvelope)
            else
                settled = inRecords or inConflicts or inPending
            end
            if not settled then
                opts.cursor = nil
                opts.budgetExhausted = false
                publishCompletenessStats()
                return false, "incomplete_transfer"
            end
        elseif type(body) == "table" and body.kind == "campaign-header" then
            local h = body.header
            if type(h) == "table" and type(h.campaignId) == "string" then
                -- Prefer temp.campaigns (applied), then adoption-session parking
                -- (survives replay boundary restore), then live pending map.
                local have = temp.campaigns[h.campaignId]
                    or (adop._headerByCampaignId and adop._headerByCampaignId[h.campaignId])
                    or (adop._replaySessionBoundaries
                        and adop._replaySessionBoundaries[h.campaignId])
                    or (GS._pendingCampaignBoundaries and GS._pendingCampaignBoundaries[h.campaignId])
                if have == nil then
                    opts.cursor = nil
                    publishCompletenessStats()
                    return false, "missing_campaign_header"
                end
            end
        elseif type(body) == "table" and body.kind == "campaign-archive" then
            if body.campaignId and temp.currentCampaignId == body.campaignId then
                opts.cursor = nil
                publishCompletenessStats()
                return false, "invalid_campaign_archive"
            end
            if body.campaignId and temp.campaignArchives[body.campaignId] == nil then
                opts.cursor = nil
                publishCompletenessStats()
                return false, "invalid_campaign_archive"
            end
            local pageCount = tonumber(body.pageCount) or 1
            if (not body.requestedItems) and pageCount >= 1 then
                local info = adop._archiveIndex and adop._archiveIndex[body.campaignId]
                if type(info) ~= "table" or type(info.pages) ~= "table" then
                    opts.cursor = nil
                    publishCompletenessStats()
                    return false, "incomplete_archive_pages"
                end
                -- Bounded presence validation only. Resume charges remaining pages;
                -- assemble always uses the immutable indexed page set so a yield
                -- mid-archive cannot drop pages 1..p-1 from a fresh local table.
                local startPage = tonumber(opts.archivePageCursor and opts.archivePageCursor[body.campaignId]) or 1
                for p = startPage, pageCount do
                    if visited >= budget then
                        opts.archivePageCursor = opts.archivePageCursor or {}
                        opts.archivePageCursor[body.campaignId] = p
                        opts.cursor = i
                        opts.budgetExhausted = true
                        publishCompletenessStats()
                        return false, "budget"
                    end
                    visited = visited + 1
                    archiveVisitedCall = archiveVisitedCall + 1
                    adop._workStats.completenessVisited =
                        (adop._workStats.completenessVisited or 0) + 1
                    adop._workStats.archiveVisited =
                        (adop._workStats.archiveVisited or 0) + 1
                    if type(info.pages[p]) ~= "table" then
                        opts.cursor = nil
                        publishCompletenessStats()
                        return false, "incomplete_archive_pages"
                    end
                end
                if opts.archivePageCursor then
                    opts.archivePageCursor[body.campaignId] = nil
                end
                local archive, aerr = AssemblePagedArchive(body, info.pages)
                if not archive then
                    opts.cursor = nil
                    publishCompletenessStats()
                    return false, aerr or "incomplete_archive_pages"
                end
                if PreferArchiveHistoricalContext(
                    temp.campaignArchives[body.campaignId], archive) then
                    temp.campaignArchives[body.campaignId] = archive
                elseif not DeepEqual(temp.campaignArchives[body.campaignId], archive) then
                    opts.cursor = nil
                    publishCompletenessStats()
                    return false, "archive_conflict"
                end
            end
        elseif type(body) == "table" and body.kind == "gs-ledger-event"
            and type(body.event) == "table" then
            local ev = body.event
            local eid = ev.id or ev.opId or ev.txnId
            -- Incremental once-per-session ledger index (archive + live tails).
            opts.acctIndex = opts.acctIndex or { byId = {}, byOcc = {}, pendingOcc = {} }
            local function occurrenceFpLe(row)
                if type(row) ~= "table" then return nil end
                local fp = GS.OccurrenceFingerprint and GS.OccurrenceFingerprint(row)
                if type(fp) == "string" and fp ~= "" then
                    return fp
                end
                return tostring(row.coreSignature or "") .. "|"
                    .. tostring(row.itemId or "") .. "|"
                    .. tostring(row.quantity or "")
            end
            local function bucketHasMatchLe(bucket, row)
                if type(bucket) ~= "table" then return false end
                for bi = 1, #bucket do
                    if GS.EvidenceOccurrenceMatches
                        and GS.EvidenceOccurrenceMatches(bucket[bi], row) then
                        return true
                    end
                end
                return false
            end
            local function rememberOccLe(map, row)
                local fp = occurrenceFpLe(row)
                if not fp then return end
                local bucket = map[fp]
                if type(bucket) ~= "table" then
                    bucket = {}
                    map[fp] = bucket
                end
                if not bucketHasMatchLe(bucket, row) and #bucket < 8 then
                    bucket[#bucket + 1] = {
                        coreSignature = row.coreSignature,
                        itemId = row.itemId,
                        quantity = row.quantity,
                        approxTxnTime = row.approxTxnTime or row.timestamp,
                        occurrenceIndex = row.occurrenceIndex,
                        neighborsOlder = row.neighborsOlder,
                        neighborsNewer = row.neighborsNewer,
                        guildGuid = row.guildGuid,
                        bankTab = row.bankTab,
                        generation = row.generation,
                    }
                end
            end
            local function indexLedgerRowLe(e)
                if type(e) ~= "table" then return end
                if type(e.id) == "string" and e.id ~= "" then
                    opts.acctIndex.byId[e.id] = true
                end
                if type(e.txnId) == "string" and e.txnId ~= "" then
                    opts.acctIndex.byId[e.txnId] = true
                end
                if type(e.opId) == "string" and e.opId ~= "" then
                    opts.acctIndex.byId[e.opId] = true
                end
                rememberOccLe(opts.acctIndex.byOcc, e)
            end
            local function catchUpAcctIndexLe()
                local archive = temp.accounting and temp.accounting._consumableEventArchive
                local events = temp.accounting and temp.accounting._consumableEvents
                local archTail = tonumber(opts.acctIndexArchiveTail) or 0
                local liveTail = tonumber(opts.acctIndexLiveTail) or 0
                if type(archive) == "table" then
                    for j = archTail + 1, #archive do
                        if visited >= budget then
                            opts.acctIndexArchiveTail = j - 1
                            opts.cursor = i
                            opts.budgetExhausted = true
                            publishCompletenessStats()
                            return false
                        end
                        visited = visited + 1
                        adop._workStats.completenessVisited =
                            (adop._workStats.completenessVisited or 0) + 1
                        indexLedgerRowLe(archive[j])
                        opts.acctIndexArchiveTail = j
                    end
                end
                if type(events) == "table" then
                    for j = liveTail + 1, #events do
                        if visited >= budget then
                            opts.acctIndexLiveTail = j - 1
                            opts.cursor = i
                            opts.budgetExhausted = true
                            publishCompletenessStats()
                            return false
                        end
                        visited = visited + 1
                        adop._workStats.completenessVisited =
                            (adop._workStats.completenessVisited or 0) + 1
                        indexLedgerRowLe(events[j])
                        opts.acctIndexLiveTail = j
                    end
                end
                return true
            end
            local found = false
            if type(eid) == "string" and eid ~= "" and opts.acctIndex.byId[eid] then
                found = true
            elseif type(ev.txnId) == "string" and ev.txnId ~= ""
                and opts.acctIndex.byId[ev.txnId] then
                found = true
            elseif type(ev.opId) == "string" and ev.opId ~= ""
                and opts.acctIndex.byId[ev.opId] then
                found = true
            else
                if not catchUpAcctIndexLe() then
                    return false, "budget"
                end
                if type(eid) == "string" and eid ~= "" and opts.acctIndex.byId[eid] then
                    found = true
                elseif type(ev.txnId) == "string" and ev.txnId ~= ""
                    and opts.acctIndex.byId[ev.txnId] then
                    found = true
                elseif type(ev.opId) == "string" and ev.opId ~= ""
                    and opts.acctIndex.byId[ev.opId] then
                    found = true
                end
            end
            if not found then
                opts.cursor = nil
                opts.budgetExhausted = false
                publishCompletenessStats()
                return false, "incomplete_transfer"
            end
        elseif type(body) == "table" and body.kind == "gs-evidence"
            and type(body.evidence) == "table" then
            local ev = body.evidence
            opts.acctIndex = opts.acctIndex or { byId = {}, byOcc = {}, pendingOcc = {} }
            local function occurrenceFp(row)
                if type(row) ~= "table" then return nil end
                local fp = GS.OccurrenceFingerprint and GS.OccurrenceFingerprint(row)
                if type(fp) == "string" and fp ~= "" then
                    return fp
                end
                return tostring(row.coreSignature or "") .. "|"
                    .. tostring(row.itemId or "") .. "|"
                    .. tostring(row.quantity or "")
            end
            local function bucketHasMatch(bucket, row)
                if type(bucket) ~= "table" then return false end
                for bi = 1, #bucket do
                    if GS.EvidenceOccurrenceMatches
                        and GS.EvidenceOccurrenceMatches(bucket[bi], row) then
                        return true
                    end
                end
                return false
            end
            local function rememberOcc(map, row)
                local fp = occurrenceFp(row)
                if not fp then return end
                local bucket = map[fp]
                if type(bucket) ~= "table" then
                    bucket = {}
                    map[fp] = bucket
                end
                if not bucketHasMatch(bucket, row) and #bucket < 8 then
                    bucket[#bucket + 1] = {
                        coreSignature = row.coreSignature,
                        itemId = row.itemId,
                        quantity = row.quantity,
                        approxTxnTime = row.approxTxnTime or row.timestamp,
                        occurrenceIndex = row.occurrenceIndex,
                        neighborsOlder = row.neighborsOlder,
                        neighborsNewer = row.neighborsNewer,
                        guildGuid = row.guildGuid,
                        bankTab = row.bankTab,
                        generation = row.generation,
                    }
                end
            end
            local function indexLedgerRow(e)
                if type(e) ~= "table" then return end
                if type(e.id) == "string" and e.id ~= "" then
                    opts.acctIndex.byId[e.id] = true
                end
                if type(e.txnId) == "string" and e.txnId ~= "" then
                    opts.acctIndex.byId[e.txnId] = true
                end
                if type(e.opId) == "string" and e.opId ~= "" then
                    opts.acctIndex.byId[e.opId] = true
                end
                rememberOcc(opts.acctIndex.byOcc, e)
            end
            local function catchUpAcctIndex()
                local archive = temp.accounting and temp.accounting._consumableEventArchive
                local events = temp.accounting and temp.accounting._consumableEvents
                local archTail = tonumber(opts.acctIndexArchiveTail) or 0
                local liveTail = tonumber(opts.acctIndexLiveTail) or 0
                if type(archive) == "table" then
                    for j = archTail + 1, #archive do
                        if visited >= budget then
                            opts.acctIndexArchiveTail = j - 1
                            opts.cursor = i
                            opts.budgetExhausted = true
                            publishCompletenessStats()
                            return false
                        end
                        visited = visited + 1
                        adop._workStats.completenessVisited =
                            (adop._workStats.completenessVisited or 0) + 1
                        indexLedgerRow(archive[j])
                        opts.acctIndexArchiveTail = j
                    end
                end
                if type(events) == "table" then
                    for j = liveTail + 1, #events do
                        if visited >= budget then
                            opts.acctIndexLiveTail = j - 1
                            opts.cursor = i
                            opts.budgetExhausted = true
                            publishCompletenessStats()
                            return false
                        end
                        visited = visited + 1
                        adop._workStats.completenessVisited =
                            (adop._workStats.completenessVisited or 0) + 1
                        indexLedgerRow(events[j])
                        opts.acctIndexLiveTail = j
                    end
                end
                return true
            end
            local settled = false
            local evFp = occurrenceFp(ev)
            if evFp and bucketHasMatch(opts.acctIndex.pendingOcc[evFp], ev) then
                settled = true
            elseif evFp and bucketHasMatch(opts.acctIndex.byOcc[evFp], ev) then
                settled = true
            else
                if not catchUpAcctIndex() then
                    return false, "budget"
                end
                if evFp and bucketHasMatch(opts.acctIndex.byOcc[evFp], ev) then
                    settled = true
                else
                    local nest = opts.evidenceScanCursor and opts.evidenceScanCursor[i]
                    if type(nest) ~= "table" then
                        nest = { phase = "pending", pos = 1 }
                    end
                    local byCampaign = temp.observations and temp.observations.byCampaign
                    local campId = ev.campaignId or body.campaignId or temp.currentCampaignId
                    local pending = byCampaign and byCampaign[campId] and byCampaign[campId].pending
                    if type(pending) == "table" then
                        for pi = nest.pos, #pending do
                            if visited >= budget then
                                opts.evidenceScanCursor = opts.evidenceScanCursor or {}
                                opts.evidenceScanCursor[i] = { phase = "pending", pos = pi }
                                opts.cursor = i
                                opts.budgetExhausted = true
                                publishCompletenessStats()
                                return false, "budget"
                            end
                            visited = visited + 1
                            adop._workStats.completenessVisited =
                                (adop._workStats.completenessVisited or 0) + 1
                            local c = pending[pi]
                            if type(c) == "table" and type(c.evidence) == "table"
                                and GS.EvidenceOccurrenceMatches
                                and GS.EvidenceOccurrenceMatches(c.evidence, ev) then
                                settled = true
                                rememberOcc(opts.acctIndex.pendingOcc, c.evidence)
                                break
                            end
                        end
                    end
                    if settled and opts.evidenceScanCursor then
                        opts.evidenceScanCursor[i] = nil
                    end
                end
            end
            if not settled then
                opts.cursor = nil
                opts.budgetExhausted = false
                publishCompletenessStats()
                return false, "incomplete_transfer"
            end
        end
    end
    opts.cursor = nil
    opts.budgetExhausted = false
    if opts.evidenceScanCursor then
        opts.evidenceScanCursor = nil
    end
    publishCompletenessStats()
    return true, nil
end

--- Selected-source effective state: accepted membership + descriptor heads/config.
local function ValidateAdoptionEffectiveState(temp, adop, desc)
    for i = 1, #(adop.sourceAcceptedIds or {}) do
        local oid = adop.sourceAcceptedIds[i]
        if not (temp.operations.records and temp.operations.records[oid]) then
            return false, "incomplete_transfer"
        end
        -- Conflict-only retention of a source-accepted id is not the selected result.
        if temp.operations.conflicts and temp.operations.conflicts[oid]
            and not (temp.operations.records and temp.operations.records[oid]) then
            return false, "incomplete_transfer"
        end
    end
    if type(desc) == "table" then
        if type(desc.permissionRevisionId) == "string" and desc.permissionRevisionId ~= "" then
            local livePol = temp.permission and temp.permission.revisionId
            if livePol ~= desc.permissionRevisionId then
                return false, "incomplete_transfer"
            end
        end
        if desc.currentCampaignId ~= nil then
            if (temp.currentCampaignId or nil) ~= (desc.currentCampaignId or nil) then
                return false, "incomplete_transfer"
            end
        end
        local acceptedCount = 0
        if temp.operations and type(temp.operations.order) == "table" then
            acceptedCount = #temp.operations.order
        end
        local wantAccepted = tonumber(desc.acceptedOpCount)
        if wantAccepted and acceptedCount ~= wantAccepted then
            return false, "incomplete_transfer"
        end
        local wantLedger = tonumber(desc.acceptedLedgerCount)
        if wantLedger ~= nil then
            local liveLedger = 0
            if GS.CountAcceptedLedgerEvents then
                liveLedger = GS.CountAcceptedLedgerEvents(temp)
            else
                local events = temp.accounting and temp.accounting._consumableEvents
                local archive = temp.accounting and temp.accounting._consumableEventArchive
                if type(events) == "table" then
                    liveLedger = liveLedger + #events
                end
                if type(archive) == "table" then
                    liveLedger = liveLedger + #archive
                end
            end
            if liveLedger ~= wantLedger then
                return false, "incomplete_transfer"
            end
        end
        -- Effective configuration head: bank tab must match the selected source
        -- when the descriptor advertises one (including explicit nil via flag).
        if desc.bankTab ~= nil or desc.hasBankTab == true then
            local liveTab = temp.accounting and temp.accounting._consumables
                and temp.accounting._consumables.bankTab
            if (liveTab or nil) ~= (desc.bankTab or nil) then
                return false, "incomplete_transfer"
            end
        end
        local wantEditor = tonumber(desc.editorRankPosition)
        if wantEditor then
            local liveRank = temp.permission and tonumber(temp.permission.editorRankPosition)
            if liveRank ~= wantEditor then
                return false, "incomplete_transfer"
            end
        end
        -- Active sources must publish with the authenticated cutover installed;
        -- never accept a staged publish of an already-live canonical dataset (#389).
        if desc.activation == GS.ACTIVATION_ACTIVE then
            if temp.activation ~= GS.ACTIVATION_ACTIVE then
                return false, "incomplete_transfer"
            end
            local wantMarker = nil
            if type(desc.liveCutover) == "table" then
                wantMarker = desc.liveCutover.cutoverMarker
            end
            wantMarker = wantMarker or desc.cutoverMarker
            local haveMarker = temp.liveCutover and temp.liveCutover.cutoverMarker or nil
            if type(wantMarker) ~= "string" or wantMarker == ""
                or haveMarker ~= wantMarker then
                return false, "incomplete_transfer"
            end
        end
    end
    return true, nil
end

--- Revalidate local authority, source identity, and pinned transfer before publish/resume.
local function ValidateAdoptionCommitContext(adop)
    if type(adop) ~= "table" or adop.committed then
        return false, "no_adoption"
    end
    local prepared = {
        guildKey = adop.guildKey,
        actorGuid = adop.actorGuid,
        handleGeneration = adop.handleGeneration,
    }
    local authOk, authReason = GS:_AuthorizeCommit(prepared, { allowRecoverPolicy = true })
    if not authOk then
        return false, authReason or "unauthorized"
    end
    local member, mReason = GS.AuthenticateTransportSender(adop.sourcePeer)
    if not member or member.guid ~= adop.sourceGuid then
        return false, mReason or "source_changed"
    end
    local editorOk, editorReason = GS.SenderHasEditorAuthority(member, { allowBootstrapInstall = true })
    if not editorOk then
        return false, editorReason or "unauthorized"
    end
    if member.guildKey ~= adop.guildKey then
        return false, "wrong_guild"
    end
    local live = GS._root.guilds[adop.guildKey]
    if type(live) == "table" then
        -- Compare full optional dataset identity, including nil vs non-nil.
        -- Begin-with-no-record pins localDatasetId=nil; an editor CreateStagedRecord
        -- mid-replay must abort rather than overwrite that newly created dataset.
        -- Legitimate bootstrap (still no local record) never enters this branch.
        if (adop.localDatasetId or nil) ~= (live.datasetId or nil) then
            return false, "source_changed"
        end
        local livePolicy = live.permission and live.permission.revisionId
        if adop.localPolicyRevision and livePolicy ~= adop.localPolicyRevision then
            return false, "stale_base"
        end
        if (adop.localCampaignId or nil) ~= (live.currentCampaignId or nil) then
            return false, "stale_base"
        end
        local liveSeq = live.accounting and live.accounting._consumables
            and tonumber(live.accounting._consumables.configSeq)
        if adop.localConfigSeq ~= nil and liveSeq ~= adop.localConfigSeq then
            return false, "stale_base"
        end
        local liveAccepted = 0
        if live.operations and type(live.operations.order) == "table" then
            liveAccepted = #live.operations.order
        end
        if adop.localAcceptedCount ~= nil and liveAccepted ~= adop.localAcceptedCount then
            return false, "stale_base"
        end
        -- Ledger/evidence mutations do not advance configSeq or accepted-op
        -- count; pin a cheap monotonic revision so async publication cannot
        -- discard local donations or retained witnesses accepted mid-replay.
        if adop.localAccountingMutation ~= nil and GS.GetAccountingMutationSeq then
            local liveMut = GS.GetAccountingMutationSeq(live)
            if liveMut ~= adop.localAccountingMutation then
                return false, "stale_base"
            end
        end
        -- Activation / cutover identity: abort when the live record activates
        -- (or changes marker) while a replacement adoption is still replaying.
        if (adop.localActivation or nil) ~= (live.activation or nil) then
            return false, "stale_base"
        end
        local liveMarker = nil
        if type(live.liveCutover) == "table" then
            liveMarker = live.liveCutover.cutoverMarker
        end
        if (adop.localCutoverMarker or nil) ~= (liveMarker or nil) then
            return false, "stale_base"
        end
    end
    if type(adop.pinnedPermissionRevisionId) == "string" then
        local peer = GS._peerDatasets[adop.sourcePeer]
        if type(peer) ~= "table" or peer.datasetId ~= adop.sourceDatasetId then
            return false, "source_changed"
        end
        if type(peer.permissionRevisionId) == "string"
            and peer.permissionRevisionId ~= ""
            and peer.permissionRevisionId ~= adop.pinnedPermissionRevisionId then
            return false, "source_changed"
        end
    end
    return true, nil, member
end

local function ReplayAdoptionIntoTemp(temp, adop, member, opts)
    opts = opts or {}
    local state = opts.state or { cursor = 1, admissions = 0 }
    -- Bounded slices charge searches/assembly; allow enough waves for reverse
    -- histories under MAX_ADMISSION_WORK_PER_SLICE without raising the slice size.
    local sliceBudget = GS.MAX_ADMISSION_WORK_PER_SLICE or 32
    local maxWaves = math.max(64, (#adop.order * sliceBudget) + 16)
    local wave = tonumber(state.wave) or 0
    local syncDrain = opts.syncDrain == true
        or not (C_Timer and C_Timer.After)
        or opts.adoptionReplaySync == true
        or GS._adoptionReplaySyncDrain == true

    local function runOne()
        wave = wave + 1
        state.wave = wave
        if wave > maxWaves then
            return false, "incomplete_transfer"
        end
        local moreWork, err, progress = WithAdoptionSessionCaches(adop, function()
            return ReplayAdoptionSlice(temp, adop, member, state)
        end)
        if err then
            return false, err
        end
        if moreWork then
            return "continue", nil, progress
        end
        return "done", nil, progress
    end

    if not syncDrain then
        local status, err = runOne()
        if status == false then
            return false, err or "incomplete_transfer", state
        end
        if status == "continue" then
            return "continue", nil, state
        end
    else
        local status, err
        repeat
            status, err = runOne()
            if status == false then
                return false, err or "incomplete_transfer", state
            end
        until status == "done"
    end

    local compBudget = tonumber(GS._adoptionCompletenessBudgetForTest)
        or GS.MAX_ADMISSION_WORK_PER_SLICE or 32
    local seedIndex = state.acctIndex
    local seedArchTail = state.acctIndexArchiveTail
    local seedLiveTail = state.acctIndexLiveTail
    if GS._adoptionCompletenessColdIndexForTest then
        -- Force a cold rebuild: empty index AND zero tails so catch-up work is charged.
        seedIndex = nil
        seedArchTail = nil
        seedLiveTail = nil
    end
    local compOpts = state.completenessOpts or {
        budget = compBudget,
        cursor = 1,
        acctIndex = seedIndex,
        acctIndexArchiveTail = seedArchTail,
        acctIndexLiveTail = seedLiveTail,
    }
    compOpts.budget = compBudget
    if not compOpts.acctIndex and not GS._adoptionCompletenessColdIndexForTest then
        compOpts.acctIndex = state.acctIndex
        compOpts.acctIndexArchiveTail = state.acctIndexArchiveTail
        compOpts.acctIndexLiveTail = state.acctIndexLiveTail
    end
    local okComp, compErr
    local guard = 0
    -- Nested ledger/evidence scan resumes can exceed top-level body count.
    local maxGuard = math.max(
        8,
        math.ceil((#adop.order or 0) / math.max(1, compBudget)) * 2 + 8,
        (#adop.order or 0) * 4 + 64
    )
    repeat
        guard = guard + 1
        okComp, compErr = ValidateAdoptionCompleteness(temp, adop, member, compOpts)
        if okComp then
            break
        end
        if compErr ~= "budget" then
            return false, compErr or "incomplete_transfer"
        end
        -- Resumable completeness: keep draining under sync; async caller yields.
        if not syncDrain then
            state.completenessOpts = compOpts
            return "continue", nil, state
        end
    until guard >= maxGuard
    state.completenessOpts = nil
    if not okComp then
        return false, (compErr == "budget" and "incomplete_transfer") or compErr or "incomplete_transfer"
    end
    return true, nil, state
end

local function PublishAdoptionTemp(adop, temp, desc)
    -- After replay, campaign ops may have rebuilt eligibility maps. Restore the
    -- authenticated source cutover boundary before structure validation/publish.
    if GS.IsLiveActive(temp) and type(temp.liveCutover) == "table"
        and GS.InstallRemoteLiveCutover then
        GS.InstallRemoteLiveCutover(temp, temp.liveCutover, adop.guildKey, {
            refreshEligibility = true,
            quarantinePending = false,
            classifyPreActivation = false,
        })
    end
    local okEff, effErr = ValidateAdoptionEffectiveState(temp, adop, desc)
    if not okEff then
        return false, effErr or "incomplete_transfer"
    end
    if GS._ValidateGuildRecordStructure then
        local ok, err = GS._ValidateGuildRecordStructure(adop.guildKey, temp)
        if not ok then
            return false, err or "invalid_record"
        end
    end
    -- Drop live redrive pins for the replaced guild record before publish.
    local priorLive = GS._root and GS._root.guilds and GS._root.guilds[adop.guildKey]
    ClearConfirmationRedriveForRecord(priorLive)
    ClearConfirmationRedriveForGuild(adop.guildKey)
    GS._root.guilds[adop.guildKey] = temp
    GS._adoptionEpoch = (tonumber(GS._adoptionEpoch) or 0) + 1
    adop.committed = true
    if type(adop._workStats) == "table" then
        GS._lastAdoptionWorkStats = {
            confirmVisited = tonumber(adop._workStats.confirmVisited) or 0,
            confirmComparisons = tonumber(adop._workStats.confirmComparisons) or 0,
            completenessVisited = tonumber(adop._workStats.completenessVisited) or 0,
            indexVisited = tonumber(adop._workStats.indexVisited) or 0,
            assemblyVisited = tonumber(adop._workStats.assemblyVisited) or 0,
            archiveVisited = tonumber(adop._workStats.archiveVisited) or 0,
            receiveVisited = tonumber(adop._workStats.receiveVisited) or 0,
            confirmRedriveVisited = tonumber(adop._workStats.confirmRedriveVisited) or 0,
        }
    end
    -- Discard session caches only; live globals were never replaced.
    adop._replaySessionRelay = nil
    adop._replaySessionBoundaries = nil
    adop.replayTemp = nil
    adop.replayState = nil
    adop.replayMember = nil
    GS._adoption = nil
    DebugInfo("committed dataset adoption dataset=%s epoch=%s",
        adop.sourceDatasetId, tostring(GS._adoptionEpoch))
    ClearAdoptionTransientAcks()
    if GS._NotifyLocalDurableChange then
        GS._NotifyLocalDurableChange("adoption")
    end
    NotifyAdoptionStateChanged("commit")
    InvalidateAdoptionDeliveryOutcomes("commit")
    return true
end

--- Continue a yieldable adoption replay until idle, then publish.
local function ContinueAdoptionReplay(adop)
    if type(adop) ~= "table" or type(adop.replayTemp) ~= "table" then
        return "rejected", "no_adoption"
    end
    -- Revalidate authority/baseline/source before each resume and before publish.
    local ctxOk, ctxErr, member = ValidateAdoptionCommitContext(adop)
    if not ctxOk then
        AbortAdoptionReplay(adop, ctxErr)
        GS._adoption = nil
        NotifyAdoptionStateChanged("failed")
        return "rejected", ctxErr or "unauthorized"
    end
    local temp = adop.replayTemp
    member = member or adop.replayMember
    adop.replayMember = member
    local state = adop.replayState or { cursor = 1, admissions = 0, wave = 0 }
    adop.replayState = state
    adop._replayScheduled = false
    state.wave = (tonumber(state.wave) or 0) + 1
    -- Stall detection lives in ReplayAdoptionSlice (idlePasses). Do not reject a
    -- legal reverse-order history merely because search/assembly charged many
    -- budgeted continuation slices.

    local moreWork, err, progress = WithAdoptionSessionCaches(adop, function()
        return ReplayAdoptionSlice(temp, adop, member, state)
    end)
    if err then
        AbortAdoptionReplay(adop, err)
        GS._adoption = nil
        NotifyAdoptionStateChanged("failed")
        return "rejected", err
    end
    if moreWork then
        if GS._adoptionReplaySyncDrain then
            -- Iterate rather than recurse; charge-heavy reverse histories can
            -- need many budget slices. Finite idlePasses still terminate stalls.
            local guard = 0
            -- Retention-capacity reverse histories can require many more slices than
            -- buffer length (dependency retries + confirmation searches). Idle/stall
            -- detectors in ReplayAdoptionSlice still terminate non-progressing work.
            local maxGuard = math.max(
                256,
                (#(adop.order or {}) * ((GS.MAX_ADMISSION_WORK_PER_SLICE or 32) + 2) * 8) + 128
            )
            while moreWork and guard < maxGuard do
                guard = guard + 1
                moreWork, err, progress = WithAdoptionSessionCaches(adop, function()
                    return ReplayAdoptionSlice(temp, adop, member, state)
                end)
                if err then
                    AbortAdoptionReplay(adop, err)
                    GS._adoption = nil
                    NotifyAdoptionStateChanged("failed")
                    return "rejected", err
                end
                local ctxOk2, ctxErr2, member2 = ValidateAdoptionCommitContext(adop)
                if not ctxOk2 then
                    AbortAdoptionReplay(adop, ctxErr2)
                    GS._adoption = nil
                    NotifyAdoptionStateChanged("failed")
                    return "rejected", ctxErr2 or "unauthorized"
                end
                member = member2 or member
                adop.replayMember = member
            end
            if moreWork then
                AbortAdoptionReplay(adop, "incomplete_transfer")
                GS._adoption = nil
                NotifyAdoptionStateChanged("failed")
                return "rejected", "incomplete_transfer"
            end
            -- moreWork cleared: fall through to completeness/publish.
        else
            if not adop._replayScheduled then
                adop._replayScheduled = true
                local function cont()
                    if GS._adoption ~= adop or adop.committed then
                        return
                    end
                    ContinueAdoptionReplay(adop)
                end
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, cont)
                else
                    cont()
                end
            end
            NotifyAdoptionStateChanged("replay")
            return "pending", "replay_in_progress"
        end
    end

    -- Final completeness is indexed/resumable; source-authored ops skip searches.
    -- Optional test override keeps replay slice size unchanged while forcing
    -- mid-archive completeness yields (GS._adoptionCompletenessBudgetForTest).
    local compBudget = tonumber(GS._adoptionCompletenessBudgetForTest)
        or GS.MAX_ADMISSION_WORK_PER_SLICE or 32
    local seedIndex = state.acctIndex
    local seedArchTail = state.acctIndexArchiveTail
    local seedLiveTail = state.acctIndexLiveTail
    if GS._adoptionCompletenessColdIndexForTest then
        seedIndex = nil
        seedArchTail = nil
        seedLiveTail = nil
    end
    local compOpts = state.completenessOpts or {
        budget = compBudget,
        cursor = 1,
        acctIndex = seedIndex,
        acctIndexArchiveTail = seedArchTail,
        acctIndexLiveTail = seedLiveTail,
    }
    compOpts.budget = compBudget
    if not compOpts.acctIndex and not GS._adoptionCompletenessColdIndexForTest then
        compOpts.acctIndex = state.acctIndex
        compOpts.acctIndexArchiveTail = state.acctIndexArchiveTail
        compOpts.acctIndexLiveTail = state.acctIndexLiveTail
    end
    local okComp, compErr = ValidateAdoptionCompleteness(temp, adop, member, compOpts)
    if not okComp and compErr == "budget" then
        state.completenessOpts = compOpts
        if GS._adoptionReplaySyncDrain then
            local guard = 0
            local maxGuard = math.max(
                8,
                math.ceil((#adop.order or 0) / math.max(1, compBudget)) * 2 + 8,
                (#adop.order or 0) * 4 + 64
            )
            while not okComp and compErr == "budget" and guard < maxGuard do
                guard = guard + 1
                local ctxOk3, ctxErr3, member3 = ValidateAdoptionCommitContext(adop)
                if not ctxOk3 then
                    AbortAdoptionReplay(adop, ctxErr3)
                    GS._adoption = nil
                    NotifyAdoptionStateChanged("failed")
                    return "rejected", ctxErr3 or "unauthorized"
                end
                member = member3 or member
                adop.replayMember = member
                okComp, compErr = ValidateAdoptionCompleteness(temp, adop, member, compOpts)
            end
            state.completenessOpts = nil
        else
            if not adop._replayScheduled then
                adop._replayScheduled = true
                local function contComp()
                    if GS._adoption ~= adop or adop.committed then
                        return
                    end
                    ContinueAdoptionReplay(adop)
                end
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, contComp)
                else
                    contComp()
                end
            end
            NotifyAdoptionStateChanged("replay")
            return "pending", "replay_in_progress"
        end
    else
        state.completenessOpts = nil
    end
    if not okComp then
        local failReason = compErr
        if failReason == "budget" then
            failReason = "incomplete_transfer"
        end
        AbortAdoptionReplay(adop, failReason)
        GS._adoption = nil
        NotifyAdoptionStateChanged("failed")
        return "rejected", failReason or "incomplete_transfer"
    end
    -- Revalidate authority/baseline after completeness, before atomic publish.
    local ctxOkPub, ctxErrPub, memberPub = ValidateAdoptionCommitContext(adop)
    if not ctxOkPub then
        AbortAdoptionReplay(adop, ctxErrPub)
        GS._adoption = nil
        NotifyAdoptionStateChanged("failed")
        return "rejected", ctxErrPub or "unauthorized"
    end
    member = memberPub or member
    adop.replayMember = member
    local complete, completeReason, desc = GS:IsAdoptionTransferComplete()
    if not complete then
        AbortAdoptionReplay(adop, completeReason)
        GS._adoption = nil
        NotifyAdoptionStateChanged("failed")
        return "rejected", completeReason or "incomplete_transfer"
    end
    local okPub, pubErr = PublishAdoptionTemp(adop, temp, desc)
    if not okPub then
        AbortAdoptionReplay(adop, pubErr)
        GS._adoption = nil
        NotifyAdoptionStateChanged("failed")
        return "rejected", pubErr or "incomplete_transfer"
    end
    return "accepted", nil
end

--- Commit adoption: replace local staged guild record with the assembled source dataset.
-- Failure / incomplete / stale authority leaves the previous dataset intact.
-- Large transfers yield between admission slices via C_Timer; callers observe
-- pending/replay_in_progress then accepted (or flush timers in harnesses).
function GS:CommitDatasetAdoption()
    -- Expiry must run on the commit path itself (Settings may call Commit after
    -- async transfer without touching GetPendingAdoption/Buffer accessors).
    ExpireStaleAdoption()
    local adop = GS._adoption
    if type(adop) ~= "table" or adop.committed then
        return "rejected", "no_adoption"
    end

    -- Resume an in-flight yieldable replay.
    if type(adop.replayTemp) == "table" then
        return ContinueAdoptionReplay(adop)
    end

    local ctxOk, ctxErr, member = ValidateAdoptionCommitContext(adop)
    if not ctxOk then
        return "rejected", ctxErr or "unauthorized"
    end

    local complete, completeReason, desc = GS:IsAdoptionTransferComplete()
    if not complete then
        return "rejected", completeReason or "incomplete_transfer"
    end

    local identity = GG().GetGuildIdentity()
    local ranks = GG() and GG().GetGuildRanks and GG().GetGuildRanks()
    local rankCount = type(ranks) == "table" and tonumber(ranks.count) or 0
    local defaultPos = GS.DEFAULT_EDITOR_RANK_POSITION or 3
    -- Prefer immutable bootstrap threshold from the source descriptor.
    -- Validate positive integrality for ordinary guilds (not only small-guild
    -- upper-bound checks) so -1 / 2.5 cannot become live policy.
    local bootstrapPos = tonumber(desc.bootstrapEditorRankPosition)
        or tonumber(desc.editorRankPosition)
        or defaultPos
    local bootOk, bootErr, bootNorm = ValidateEditorRankValue(bootstrapPos)
    if not bootOk then
        -- When guild ranks are unavailable, still reject non-integral/non-positive.
        bootstrapPos = tonumber(bootstrapPos)
        if not bootstrapPos or bootstrapPos ~= math.floor(bootstrapPos) or bootstrapPos < 1 then
            return "rejected", bootErr or "invalid_editor_rank_position"
        end
        if rankCount and rankCount > 0 and bootstrapPos > rankCount then
            return "rejected", "invalid_editor_rank_position"
        end
    else
        bootstrapPos = bootNorm
    end

    local temp = NewBootstrapRecord(adop.sourceDatasetId, adop.guildKey, identity, bootstrapPos)
    -- Active source descriptors install their authenticated liveCutover onto the
    -- temporary record before replay/publish so ledger admissions classify against
    -- the original eligibility boundary and atomic publish cannot demote live
    -- authority to staged (#389).
    if desc.activation == GS.ACTIVATION_ACTIVE then
        if type(desc.liveCutover) ~= "table" then
            return "rejected", "missing_live_cutover"
        end
        local stCut, cutReason = GS.InstallRemoteLiveCutover(temp, desc.liveCutover, adop.guildKey, {
            quarantinePending = false,
            forceActive = true,
            classifyPreActivation = false,
            member = member,
            requireEditorAuthority = true,
            bindActorToSender = false,
            authOpts = { allowBootstrapInstall = true },
        })
        if stCut ~= "accepted" and stCut ~= "duplicate" then
            return "rejected", cutReason or "invalid_live_cutover"
        end
    end
    -- Offline replay: never publish temp until fully validated. Live guild slot
    -- stays untouched; AdmitRemoteOperation uses offlineRecord=temp only.
    -- Session-local relay/boundary caches; live globals stay in place across yields.
    adop._replaySessionRelay = {}
    adop._replaySessionBoundaries = {}
    adop.replayTemp = temp
    adop.replayMember = member
    adop.replayState = { cursor = 1, admissions = 0, wave = 0 }
    return ContinueAdoptionReplay(adop)
end

local function ResolutionBodiesMatch(value, ops, ids)
    if type(value.contentBodies) ~= "table" then
        return false, "invalid_resolution"
    end
    local seenDep = {}
    for i = 1, #ids do
        local id = ids[i]
        if type(id) ~= "string" or id == "" or seenDep[id] then
            return false, "invalid_resolution"
        end
        seenDep[id] = true
        local auth = value.contentBodies[id]
        local body = ops.records[id]
            or (ops.pending[id] and ops.pending[id].body)
            or (ops.conflicts[id] and ops.conflicts[id].body)
        if type(auth) ~= "table" or type(body) ~= "table"
            or not AuthoritativeBodiesEqual(auth, body) then
            return false, "content_mismatch"
        end
    end
    if not seenDep[value.chosenOpId] then
        return false, "invalid_resolution"
    end
    return true
end

---------------------------------------------------------------------------
-- Remote operation admission
---------------------------------------------------------------------------

local function EnsureRecordForRemote(guildKey, opts)
    opts = opts or {}
    local function supported(rec)
        return type(rec) == "table"
            and GS.IsSupportedActivation
            and GS.IsSupportedActivation(rec.activation)
    end
    if type(opts.offlineRecord) == "table" then
        if not supported(opts.offlineRecord) then
            return nil, "unsupported_activation"
        end
        return opts.offlineRecord
    end
    if not GS:IsRootReady() then
        return nil, GS:GetRootReason() or "not_ready"
    end
    local raw = GS._root.guilds[guildKey]
    if type(raw) ~= "table" then
        return nil, "not_configured"
    end
    if not supported(raw) then
        return nil, "unsupported_activation"
    end
    return raw
end

--- Stage a canonical parent-campaign archive without publishing yet.
local function StageParentArchive(record, parentId, timestamp)
    if not parentId then
        return nil, nil
    end
    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" or type(cfg.requestedItems) ~= "table" then
        return nil, "invalid_accounting"
    end
    if not record.campaignArchives then
        record.campaignArchives = {}
    end
    if record.campaignArchives[parentId] ~= nil then
        return nil, "campaign_archive_exists"
    end
    local n = 0
    for _ in pairs(record.campaignArchives) do
        n = n + 1
        if n >= (GS.MAX_CAMPAIGNS or 64) then
            return nil, "full"
        end
    end
    local generation = tonumber(cfg.generation)
    if not generation or generation ~= math.floor(generation) or generation < 1
        or generation ~= generation or generation == math.huge then
        return nil, "invalid_generation"
    end
    local itemsCopy = {}
    for k, v in pairs(cfg.requestedItems) do
        if type(v) == "table" then
            itemsCopy[k] = {
                itemId = v.itemId,
                goal = v.goal,
            }
        end
    end
    return {
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = parentId,
        datasetId = record.datasetId,
        requestedItems = itemsCopy,
        generation = generation,
        archivedAt = timestamp,
    }, nil
end

--- Reconstruct live campaign projection for a chosen sibling from shared history.
-- Builds the item/eligibility projection off-record. Pending bodies under the
-- chosen campaign are included only when an accepted confirmation/resolution
-- envelope embeds their exact authoritative content; unconfirmed foreign edits
-- remain durable pending evidence. Mutation storage (StoreAccepted) is deferred
-- to the caller so capacity failure can abort without partial promotion.
-- @return ok, err, plan { promoteOps = {op...}, slotsNeeded }
--- Build an off-record campaign projection. Never mutates live cfg/heads.
-- Confirmed pending promotions are ordered by causal frontier (baseTargetRevision),
-- not lexicographic ID, and unconfirmed foreign pending bodies are excluded.
local function ReconstructChosenCampaignProjection(record, chosenId, header, admissionCtx)
    local cfg = record.accounting and record.accounting._consumables
    local ops = record.operations
    if type(cfg) ~= "table" or type(ops) ~= "table" then
        return false, "invalid_accounting"
    end
    admissionCtx = admissionCtx or {}
    local function IsChosenConfigMutation(op)
        return type(op) == "table"
            and op.campaignId == chosenId
            and op.kind ~= GS.KIND.START_CAMPAIGN
            and op.kind ~= GS.KIND.RESOLVE_CONFLICT
            and op.kind ~= GS.KIND.CONFIRM_CANDIDATE
            and op.kind ~= GS.KIND.SET_EDITOR_RANK
    end

    local promoteOps = {}
    -- One reconstruction-scoped exact-content index: O(history + matches), not
    -- O(candidates × history). Distinct bodies sharing an ID stay distinct.
    local authLookup = BuildReconstructionAuthLookup(record)
    local promoteSeen = {}
    local function considerRetained(op)
        if not IsChosenConfigMutation(op) or (ops.records and ops.records[op.id]) then
            return
        end
        if promoteSeen[op.id] then
            return
        end
        local authBody = authLookup.findExact(op.id, op)
        if type(authBody) == "table" then
            promoteSeen[op.id] = true
            promoteOps[#promoteOps + 1] = authBody
        end
    end
    -- Retained candidates live in durable pending/conflict or session relay.
    if type(ops.pending) == "table" then
        for _, entry in pairs(ops.pending) do
            considerRetained(entry and entry.body)
        end
    end
    if type(ops.conflicts) == "table" then
        for _, entry in pairs(ops.conflicts) do
            considerRetained(entry and entry.body)
        end
    end
    if type(GS._pendingRelay) == "table" then
        for _, entry in pairs(GS._pendingRelay) do
            considerRetained(entry and entry.body)
        end
    end
    -- Expose visit counts for harness measurement (reconstruction-scoped only).
    GS._lastReconstructionLookupStats = {
        envelopeVisits = authLookup.envelopeVisits(),
        rowVisits = authLookup.rowVisits(),
        comparisons = authLookup.comparisons(),
        promoteCount = #promoteOps,
    }
    local slotsNeeded = #promoteOps
    if slotsNeeded > 0 and GS._AcceptedCount
        and GS._AcceptedCount(ops) + slotsNeeded > (GS.MAX_ACCEPTED_OPERATIONS or 4096) then
        return false, "full"
    end

    -- Off-record shadow record: mutations apply only to projected cfg tables.
    -- Seed bank tab from the CHOSEN immutable boundary (explicit nil clears the
    -- provisional sibling's live tab). Target heads start empty except
    -- campaign-independent policy heads — do not retain losing-campaign heads
    -- that would mis-classify confirmed chosen-campaign edits as conflicts.
    local projItems = {}
    local projElig = {}
    local shadowHeads = {}
    if type(ops.heads) == "table" then
        local rankKey = GS._TargetKey and GS._TargetKey(GS.KIND.SET_EDITOR_RANK, "editorRankPosition")
            or "permission:editorRankPosition"
        if ops.heads[rankKey] then
            shadowHeads[rankKey] = ops.heads[rankKey]
        end
    end
    local shadowOps = {
        records = ops.records,
        pending = ops.pending,
        conflicts = ops.conflicts,
        openConflicts = {},
        heads = shadowHeads,
        order = ops.order,
    }
    local shadow = {
        datasetId = record.datasetId,
        currentCampaignId = chosenId,
        permission = record.permission,
        accounting = {
            _consumables = {
                requestedItems = projItems,
                eligibility = projElig,
                bankTab = header and header.bankTabAtStart,
                configSeq = tonumber(cfg.configSeq) or 0,
            },
        },
        operations = shadowOps,
        campaigns = record.campaigns,
    }
    if GS.EstablishCampaignBaseline then
        GS.EstablishCampaignBaseline(shadow.accounting._consumables, header and header.startedAt or nil)
    end
    local function targetKeyOf(op)
        if GS._TargetKey then
            return GS._TargetKey(op.kind, op.target)
        end
        return tostring(op.kind) .. ":" .. tostring(op.target)
    end
    local function applyMut(op)
        if GS._ApplyMutations then
            local ok = GS._ApplyMutations(shadow, op)
            if ok then
                shadowHeads[targetKeyOf(op)] = op.id
            end
            return ok
        end
        shadowHeads[targetKeyOf(op)] = op.id
        return true
    end
    -- Accepted history in durable order (already causal).
    if type(ops.order) == "table" and type(ops.records) == "table" then
        for i = 1, #ops.order do
            local op = ops.records[ops.order[i]]
            if IsChosenConfigMutation(op) then
                local okMut = applyMut(op)
                if not okMut then
                    return false, "projection_failed"
                end
            end
        end
    end
    -- Confirmed promotions: dependency-frontier waves with shared causal rules.
    -- Confirmation authorizes content; same-base siblings remain conflicts.
    local remaining = {}
    for i = 1, #promoteOps do
        remaining[i] = promoteOps[i]
    end
    local orderedPromote = {}
    local settled = {}
    if type(ops.records) == "table" then
        for id in pairs(ops.records) do
            settled[id] = true
        end
    end
    local guard = #remaining + 2
    while #remaining > 0 and guard > 0 do
        guard = guard - 1
        local progressed = false
        local nextRound = {}
        -- Group by target so same-base siblings can be detected before apply.
        local byTarget = {}
        for i = 1, #remaining do
            local op = remaining[i]
            local tk = targetKeyOf(op)
            byTarget[tk] = byTarget[tk] or {}
            byTarget[tk][#byTarget[tk] + 1] = op
        end
        local deferred = {}
        for tk, group in pairs(byTarget) do
            -- Same-base siblings among confirmed promotions stay conflicts.
            local byBase = {}
            for i = 1, #group do
                local op = group[i]
                local base = op.baseTargetRevision or ""
                byBase[base] = byBase[base] or {}
                byBase[base][#byBase[base] + 1] = op
            end
            for base, siblings in pairs(byBase) do
                if #siblings > 1 and base ~= "" then
                    for i = 1, #siblings do
                        deferred[siblings[i].id] = true
                    end
                end
            end
        end
        for i = 1, #remaining do
            local op = remaining[i]
            if deferred[op.id] then
                nextRound[#nextRound + 1] = op
            else
                local base = op.baseTargetRevision
                local tk = targetKeyOf(op)
                local head = shadowHeads[tk]
                local ready = (base == nil) or (base == record.datasetId)
                    or settled[base] == true
                    or head == base
                if ready then
                    -- Shared causal classification against the shadow projection.
                    local class = "apply"
                    if ClassifyStaleBase then
                        class = select(1, ClassifyStaleBase(shadow, op, tk))
                    end
                    if class == "apply" or class == nil then
                        -- Head must still match the declared base (no silent sibling apply).
                        if base ~= nil and base ~= record.datasetId and head ~= base
                            and settled[base] ~= true then
                            nextRound[#nextRound + 1] = op
                        else
                            local okMut = applyMut(op)
                            if not okMut then
                                return false, "projection_failed"
                            end
                            orderedPromote[#orderedPromote + 1] = op
                            settled[op.id] = true
                            progressed = true
                        end
                    elseif class == "pending" then
                        nextRound[#nextRound + 1] = op
                    else
                        -- conflict / obsolete: leave as pending evidence
                        nextRound[#nextRound + 1] = op
                    end
                else
                    nextRound[#nextRound + 1] = op
                end
            end
        end
        if not progressed then
            -- Missing predecessors or preserved conflicts among confirmed set.
            break
        end
        remaining = nextRound
    end

    return true, nil, {
        promoteOps = orderedPromote,
        slotsNeeded = #orderedPromote,
        projectedItems = projItems,
        projectedEligibility = projElig,
        projectedBankTab = shadow.accounting._consumables.bankTab,
        hasProjectedBankTab = true,
    }
end

--- Apply an original campaign boundary without recapturing the receiver's bank.
-- Switch current campaign to a chosen sibling without treating the provisional
-- current sibling as a sequential New Campaign parent (no archive / gen bump).
local function ActivateChosenCampaignProjection(record, chosen, boundary)
    if type(record) ~= "table" or type(chosen) ~= "table" then
        return false, "invalid_operation"
    end
    local ops = record.operations
    local header = record.campaigns and record.campaigns[chosen.id]
    local insertingHeader = false
    if type(header) ~= "table" then
        if type(boundary) ~= "table" then
            return false, "missing_campaign"
        end
        if boundary.campaignId ~= chosen.id or boundary.resetOperationId ~= chosen.id then
            return false, "boundary_mismatch"
        end
        if boundary.datasetId ~= record.datasetId then
            return false, "dataset_mismatch"
        end
        local headerOk, headerErr = GS.ValidateCampaignBoundary(boundary, record, chosen.guildKey)
        if not headerOk then
            return false, headerErr or "invalid_campaign"
        end
        insertingHeader = true
        header = boundary
    end

    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" then
        return false, "invalid_accounting"
    end

    -- Already current: ensure head points at chosen; never clear live projection.
    if record.currentCampaignId == chosen.id then
        if not (ops.records and ops.records[chosen.id]) and GS._StoreAccepted then
            GS._StoreAccepted(ops, chosen, GS.CAMPAIGN_TARGET_KEY)
        elseif ops.heads then
            ops.heads[GS.CAMPAIGN_TARGET_KEY] = chosen.id
        end
        return true
    end

    -- Baseline for concurrent-change detection during off-record construction.
    local baseline = {
        datasetId = record.datasetId,
        currentCampaignId = record.currentCampaignId,
        policyRevision = record.permission and record.permission.revisionId,
        configSeq = cfg.configSeq,
        acceptedCount = GS._AcceptedCount and GS._AcceptedCount(ops) or 0,
    }

    -- Sibling switch: keep generation; reconstruct off-record then publish atomically.
    local previousItems = cfg.requestedItems
    local previousEligibility = cfg.eligibility
    local previousBankTab = cfg.bankTab
    local previousConfigSeq = cfg.configSeq
    local previousCurrent = record.currentCampaignId
    local previousHeads = {}
    if type(ops.heads) == "table" then
        for k, v in pairs(ops.heads) do
            previousHeads[k] = v
        end
    end
    local previousPending = {}
    if type(ops.pending) == "table" then
        for k, v in pairs(ops.pending) do
            previousPending[k] = v
        end
    end
    local insertedObs = false
    local insertedHeader = false
    local insertedAccepted = false
    local promotedIds = {}

    local function rollbackActivation()
        cfg.requestedItems = previousItems
        cfg.eligibility = previousEligibility
        cfg.bankTab = previousBankTab
        cfg.configSeq = previousConfigSeq
        record.currentCampaignId = previousCurrent
        if type(ops.heads) == "table" then
            for k in pairs(ops.heads) do
                ops.heads[k] = nil
            end
            for k, v in pairs(previousHeads) do
                ops.heads[k] = v
            end
        end
        if type(ops.pending) == "table" then
            for k in pairs(ops.pending) do
                ops.pending[k] = nil
            end
            for k, v in pairs(previousPending) do
                ops.pending[k] = v
            end
        end
        if insertedHeader then
            record.campaigns[chosen.id] = nil
        end
        if insertedObs and record.observations and record.observations.byCampaign then
            record.observations.byCampaign[chosen.id] = nil
        end
        if insertedAccepted and ops.records then
            ops.records[chosen.id] = nil
            if type(ops.order) == "table" then
                for i = #ops.order, 1, -1 do
                    if ops.order[i] == chosen.id then
                        table.remove(ops.order, i)
                        break
                    end
                end
            end
        end
        for i = 1, #promotedIds do
            local pid = promotedIds[i]
            if ops.records and ops.records[pid] then
                local body = ops.records[pid]
                ops.records[pid] = nil
                if type(ops.order) == "table" then
                    for j = #ops.order, 1, -1 do
                        if ops.order[j] == pid then
                            table.remove(ops.order, j)
                            break
                        end
                    end
                end
                -- Retention cleanup is deferred until post-validation success, so
                -- conflict/relay/pending sources normally still hold the body.
                -- Only synthesize pending when no retention source remains.
                local stillRetained = (ops.pending and ops.pending[pid])
                    or (ops.conflicts and ops.conflicts[pid])
                    or (GS._pendingRelay and GS._pendingRelay[pid])
                if not stillRetained and ops.pending then
                    local prior = previousPending[pid]
                    ops.pending[pid] = prior or {
                        body = body,
                        reason = (prior and prior.reason) or "stale_base",
                    }
                end
            end
        end
    end

    -- Preflight headers before any durable writes.
    if insertingHeader and GS.CountCampaignHeaders
        and GS.CountCampaignHeaders(record) >= (GS.MAX_CAMPAIGNS or 64) then
        return false, "full"
    end

    -- Fully off-record reconstruct (live cfg untouched until publish).
    local okRecon, reconErr, plan = ReconstructChosenCampaignProjection(
        record, chosen.id, header, {})
    if not okRecon then
        return false, reconErr or "projection_failed"
    end
    plan = plan or { promoteOps = {}, slotsNeeded = 0 }

    local slotsNeeded = plan.slotsNeeded or 0
    if not (ops.records and ops.records[chosen.id]) then
        slotsNeeded = slotsNeeded + 1
    end
    if slotsNeeded > 0 and GS._AcceptedCount
        and GS._AcceptedCount(ops) + slotsNeeded > (GS.MAX_ACCEPTED_OPERATIONS or 4096) then
        return false, "full"
    end

    -- Live state must still match construction baseline before publish.
    if record.datasetId ~= baseline.datasetId
        or record.currentCampaignId ~= baseline.currentCampaignId
        or (record.permission and record.permission.revisionId) ~= baseline.policyRevision
        or cfg.configSeq ~= baseline.configSeq
        or ((GS._AcceptedCount and GS._AcceptedCount(ops)) or 0) ~= baseline.acceptedCount then
        return false, "stale_base"
    end

    -- Atomic publish: swap projected tables + store accepted promotions together.
    if insertingHeader then
        record.campaigns[chosen.id] = header
        insertedHeader = true
    end

    cfg.requestedItems = plan.projectedItems or {}
    cfg.eligibility = plan.projectedEligibility or {}
    -- Always publish the projected tab, including an explicitly captured nil
    -- from the chosen campaign's bankTabAtStart.
    if plan.hasProjectedBankTab then
        cfg.bankTab = plan.projectedBankTab
    elseif plan.projectedBankTab ~= nil then
        cfg.bankTab = plan.projectedBankTab
    end
    if GS.EstablishCampaignBaseline and (not cfg.eligibility or cfg.eligibility.baselineEstablished ~= true) then
        GS.EstablishCampaignBaseline(cfg, header.startedAt or chosen.timestamp)
    end
    cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1
    record.currentCampaignId = chosen.id
    if record.observations and record.observations.byCampaign
        and record.observations.byCampaign[chosen.id] == nil then
        record.observations.byCampaign[chosen.id] = {
            schemaVersion = 1,
            seq = 0,
            scopes = {},
        }
        insertedObs = true
    end
    if not (ops.records and ops.records[chosen.id]) then
        if GS._StoreAccepted then
            GS._StoreAccepted(ops, chosen, GS.CAMPAIGN_TARGET_KEY)
            insertedAccepted = true
        end
    elseif ops.heads then
        ops.heads[GS.CAMPAIGN_TARGET_KEY] = chosen.id
    end

    -- Store promotions first; defer retention cleanup until post-validation
    -- succeeds so rollback can restore exact prior conflict/relay/boundary state.
    for i = 1, #(plan.promoteOps or {}) do
        local pop = plan.promoteOps[i]
        local targetKey = GS._TargetKey and GS._TargetKey(pop.kind, pop.target)
        if GS._StoreAccepted then
            GS._StoreAccepted(ops, pop, targetKey)
            promotedIds[#promotedIds + 1] = pop.id
        end
    end

    if GS._ValidateGuildRecordStructure then
        local postOk, postErr = GS._ValidateGuildRecordStructure(
            chosen.guildKey or record._guildKey, record)
        if not postOk then
            rollbackActivation()
            return false, postErr or "invalid_record"
        end
    end
    -- Post-validation succeeded: drop retained copies now that accepted history
    -- owns the promoted bodies.
    for i = 1, #promotedIds do
        local pid = promotedIds[i]
        if ops.pending then
            ops.pending[pid] = nil
        end
        if ops.conflicts then
            ops.conflicts[pid] = nil
        end
        if GS._pendingRelay then
            GS._pendingRelay[pid] = nil
        end
        if GS._pendingCampaignBoundaries then
            GS._pendingCampaignBoundaries[pid] = nil
        end
    end
    return true
end

-- Validates first; commits archive + boundary + config reset atomically.
local function ApplyRemoteCampaignMutation(record, stored, boundary)
    if type(boundary) ~= "table" then
        -- Oversized max-id headers may travel only as campaign-header records.
        boundary = (record.campaigns and record.campaigns[stored.id])
            or (GS._pendingCampaignBoundaries and GS._pendingCampaignBoundaries[stored.id])
    end
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

    local headerOk, headerErr = GS.ValidateCampaignBoundary(boundary, record, stored.guildKey)
    if not headerOk then
        return false, headerErr or "invalid_campaign"
    end

    local parentId = record.currentCampaignId
    local stagedArchive, archiveErr = StageParentArchive(record, parentId, stored.timestamp)
    if archiveErr then
        return false, archiveErr
    end
    if stagedArchive then
        local aok, aerr = GS.ValidateCampaignArchive(stagedArchive, parentId, record)
        if not aok then
            return false, aerr or "invalid_campaign_archive"
        end
    end

    local currentGen = tonumber(cfg.generation)
    if parentId then
        if not currentGen or currentGen ~= math.floor(currentGen) or currentGen < 1
            or currentGen ~= currentGen or currentGen == math.huge then
            return false, "invalid_generation"
        end
    else
        if currentGen == nil then
            currentGen = 0
        end
        if currentGen ~= math.floor(currentGen) or currentGen < 0
            or currentGen ~= currentGen or currentGen == math.huge then
            return false, "invalid_generation"
        end
    end

    -- Commit: prior validations passed; mutate together.
    if stagedArchive then
        record.campaignArchives[parentId] = stagedArchive
    end

    local previousItems = cfg.requestedItems
    local previousGeneration = cfg.generation
    local previousEligibility = cfg.eligibility
    local previousConfigSeq = cfg.configSeq
    local previousCurrent = record.currentCampaignId

    cfg.requestedItems = {}
    cfg.generation = currentGen + 1
    cfg.eligibility = {}
    -- Original startedAt / boundary timestamps — never receipt time.
    GS.EstablishCampaignBaseline(cfg, boundary.startedAt or stored.timestamp)
    -- Descriptor-first active bootstrap installs liveCutover before historical
    -- start-campaign replay; re-floor eligibility so campaign startedAt cannot
    -- regress the immutable cutover (#389). Adoption PublishAdoptionTemp also
    -- refreshes; this covers live gossip catch-up without waiting for publish.
    if GS.RefreshLiveEligibilityFloor then
        GS.RefreshLiveEligibilityFloor(record)
    end
    cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1
    if GS.ShelvePriorGenerationsOnRecord then
        GS.ShelvePriorGenerationsOnRecord(record)
    end

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

    if GS._ValidateGuildRecordStructure then
        local postOk, postErr = GS._ValidateGuildRecordStructure(stored.guildKey, record)
        if not postOk then
            cfg.requestedItems = previousItems
            cfg.generation = previousGeneration
            cfg.eligibility = previousEligibility
            cfg.configSeq = previousConfigSeq
            record.currentCampaignId = previousCurrent
            record.campaigns[stored.id] = nil
            if stagedArchive and record.campaignArchives then
                record.campaignArchives[parentId] = nil
            end
            if ops.records then
                ops.records[stored.id] = nil
            end
            return false, postErr or "invalid_record"
        end
    end
    return true
end

--- Apply a retained historical candidate under confirmer authority without
-- restamping original attribution. Confirmer transport auth is already proven.
local function ApplyPreservedAttributionCandidate(record, candidate, boundary, admissionCtx)
    if type(candidate) ~= "table" or type(record) ~= "table" then
        return "rejected", "invalid_operation"
    end
    local stored, snapErr
    if GS._SnapshotPublicOp then
        stored, snapErr = GS._SnapshotPublicOp(candidate)
    else
        stored = candidate
    end
    if not stored then
        return "rejected", snapErr or "invalid_operation"
    end
    if GS.ValidateAcceptedOperationBody then
        local shapeOk, shapeErr = GS.ValidateAcceptedOperationBody(
            stored, record._guildKey or stored.guildKey, record.datasetId)
        if not shapeOk then
            return "rejected", shapeErr or "invalid_operation"
        end
    end
    if stored.guildKey and record._guildKey and stored.guildKey ~= record._guildKey then
        return "rejected", "wrong_guild"
    end
    if stored.datasetId ~= record.datasetId then
        return "rejected", "dataset_mismatch"
    end

    local ops = record.operations
    local existing = ops.records[stored.id]
    if existing then
        if DeepEqual(existing, stored) then
            return "duplicate", "duplicate"
        end
        return "rejected", "id_conflict"
    end
    if ops.conflicts and ops.conflicts[stored.id] then
        return "rejected", "id_conflict"
    end

    -- Confirmations never synthesize START_CAMPAIGN / RESOLVE / CONFIRM envelopes.
    if stored.kind == GS.KIND.CONFIRM_CANDIDATE
        or stored.kind == GS.KIND.RESOLVE_CONFLICT then
        return "rejected", "unsupported_kind"
    end

    if stored.kind == GS.KIND.SET_EDITOR_RANK then
        local rankOk, rankErr = ValidateEditorRankValue(stored.value)
        if not rankOk then
            return "rejected", rankErr or "invalid_editor_rank_position"
        end
    end

    local targetKey = GS._TargetKey and GS._TargetKey(stored.kind, stored.target)
    if stored.kind == GS.KIND.START_CAMPAIGN then
        targetKey = GS.CAMPAIGN_TARGET_KEY
    end
    if not targetKey then
        return "rejected", "invalid_target"
    end

    local class = "apply"
    local classReason = nil
    if stored.basePolicyRevision ~= CurrentPolicyRevision(record)
        or (stored.baseCampaignId or nil) ~= (record.currentCampaignId or nil)
        or (stored.kind ~= GS.KIND.START_CAMPAIGN
            and (stored.campaignId or nil) ~= (record.currentCampaignId or nil))
        or stored.baseTargetRevision ~= CurrentTargetRevision(record, targetKey) then
        class, classReason = ClassifyStaleBase(record, stored, targetKey)
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
        local headId = ops.heads and ops.heads[targetKey]
        if type(headId) == "string" then
            headId = UnderlyingConflictValueId(ops, headId) or headId
        end
        local candidates = {}
        if type(headId) == "string" then
            candidates[#candidates + 1] = headId
        end
        candidates[#candidates + 1] = stored.id
        local meta = nil
        if stored.kind == GS.KIND.START_CAMPAIGN and type(boundary) == "table" then
            GS._pendingCampaignBoundaries[stored.id] = boundary
            meta = { boundaries = { [stored.id] = boundary } }
        end
        if GS._AdmitPendingOrConflict then
            local st, reason = GS._AdmitPendingOrConflict(ops, stored, classReason or "divergent_edit")
            if st == "rejected" then
                return st, reason
            end
            local mok, merr = GS._MarkTargetConflict(ops, targetKey, candidates, stored.timestamp, meta)
            if not mok and merr == "full" then
                if ops.pending then
                    ops.pending[stored.id] = nil
                end
                if ops.conflicts then
                    ops.conflicts[stored.id] = nil
                end
                return "rejected", "full"
            end
            if not admissionCtx.adoptionReplay and GS._NotifyLocalDurableChange then
                GS._NotifyLocalDurableChange("remote-conflict")
            end
            return st, reason
        end
        local mok, merr = GS._MarkTargetConflict(ops, targetKey, candidates, stored.timestamp, meta)
        if not mok and merr == "full" then
            return "rejected", "full"
        end
        if not admissionCtx.adoptionReplay and GS._NotifyLocalDurableChange then
            GS._NotifyLocalDurableChange("remote-conflict")
        end
        return "pending", classReason or "divergent_edit"
    end

    -- Accepted-ops capacity applies only to apply-class promotions. Conflict /
    -- pending retention must not be blocked merely because the accepted store
    -- is full (exact-fit confirmation batches include non-promoting siblings).
    if GS._AcceptedCount and GS._AcceptedCount(ops) >= GS.MAX_ACCEPTED_OPERATIONS then
        return "rejected", "full"
    end

    if stored.kind == GS.KIND.START_CAMPAIGN then
        local ok, err = ApplyRemoteCampaignMutation(record, stored, boundary)
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
    local guildKey = record._guildKey or stored.guildKey
    if guildKey then
        GS.ClearBootstrapEditLockIfCaughtUp(record, guildKey)
    end
    return "accepted", nil
end

--- Locate a retained candidate body for exact-content confirmation.
local function LookupRetainedCandidate(record, rid)
    local pending = GS._pendingRelay[rid]
    if type(pending) == "table" and type(pending.body) == "table" then
        return pending.body, pending.boundary, pending.fingerprint, "relay"
    end
    local ops = record and record.operations
    if type(ops) ~= "table" then
        return nil
    end
    if ops.pending and ops.pending[rid] and type(ops.pending[rid].body) == "table" then
        local entry = ops.pending[rid]
        return entry.body, GS._pendingCampaignBoundaries[rid], ContentFingerprint(entry.body), "pending"
    end
    if ops.conflicts and ops.conflicts[rid] and type(ops.conflicts[rid].body) == "table" then
        local entry = ops.conflicts[rid]
        return entry.body, GS._pendingCampaignBoundaries[rid], ContentFingerprint(entry.body), "conflict"
    end
    return nil
end

--- Collect distinct candidate ids embedded in a confirmation envelope.
local function ConfirmationCandidateIds(storedConfirm)
    local ids = {}
    local seen = {}
    local ref = storedConfirm and storedConfirm.candidateRef
    if type(ref) ~= "table" then
        return ids
    end
    local function note(id)
        if type(id) == "string" and id ~= "" and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    note(ref.recordId)
    if type(ref.records) == "table" then
        for i = 1, #ref.records do
            local row = ref.records[i]
            if type(row) == "table" then
                note(row.id)
            end
        end
    end
    if type(ref.originalIds) == "table" then
        for i = 1, #ref.originalIds do
            note(ref.originalIds[i])
        end
    end
    return ids
end

--- Classify whether a retained confirmation candidate would promote now.
-- Reuses ApplyPreservedAttributionCandidate admission gates (policy/campaign/
-- ClassifyStaleBase) against a temporary projection record. Does not mutate
-- durable live state.
-- @return "apply"|"pending"|"conflict"|"obsolete"|"skip"|"duplicate"
local function ClassifyConfirmationPromotion(record, authBody, admissionCtx)
    if type(record) ~= "table" or type(authBody) ~= "table" then
        return "skip"
    end
    admissionCtx = admissionCtx or {}
    if admissionCtx.adoptionReplay and admissionCtx.deferRank
        and authBody.kind == GS.KIND.SET_EDITOR_RANK then
        return "pending"
    end
    local ops = record.operations
    if type(ops) ~= "table" then
        return "skip"
    end
    if ops.records and ops.records[authBody.id] then
        return "duplicate"
    end
    if authBody.kind == GS.KIND.CONFIRM_CANDIDATE
        or authBody.kind == GS.KIND.RESOLVE_CONFLICT then
        return "skip"
    end
    local targetKey = GS._TargetKey and GS._TargetKey(authBody.kind, authBody.target)
    if authBody.kind == GS.KIND.START_CAMPAIGN then
        targetKey = GS.CAMPAIGN_TARGET_KEY
    end
    if not targetKey then
        return "skip"
    end
    local class = "apply"
    if authBody.basePolicyRevision ~= CurrentPolicyRevision(record)
        or (authBody.baseCampaignId or nil) ~= (record.currentCampaignId or nil)
        or (authBody.kind ~= GS.KIND.START_CAMPAIGN
            and (authBody.campaignId or nil) ~= (record.currentCampaignId or nil))
        or authBody.baseTargetRevision ~= CurrentTargetRevision(record, targetKey) then
        class = select(1, ClassifyStaleBase(record, authBody, targetKey))
    end
    return class or "apply"
end

--- Project an apply-eligible promotion onto a temporary admission shadow.
-- Reuses GS._ApplyMutations for policy/config transitions and updates campaign
-- current id / accepted membership so within-batch dependents classify correctly.
-- Honors mutation outcomes: failure does not advance projected membership/heads.
-- @return ok, err
local function ProjectConfirmationPromotion(shadow, projectedRecords, authBody, boundary)
    if type(shadow) ~= "table" or type(authBody) ~= "table" then
        return false, "invalid_operation"
    end
    local targetKey = GS._TargetKey and GS._TargetKey(authBody.kind, authBody.target)
    if authBody.kind == GS.KIND.START_CAMPAIGN then
        targetKey = GS.CAMPAIGN_TARGET_KEY
        shadow.currentCampaignId = authBody.id
        if type(shadow.campaigns) == "table" then
            local hdr = boundary
            if type(hdr) ~= "table" then
                hdr = shadow.campaigns[authBody.id]
            end
            if type(hdr) == "table" then
                shadow.campaigns[authBody.id] = hdr
            end
        end
    elseif authBody.kind == GS.KIND.SET_EDITOR_RANK
        or authBody.kind == GS.KIND.SET_BANK_TAB
        or authBody.kind == GS.KIND.SET_REQUESTED_ITEM then
        if GS._ApplyMutations then
            local ok, err = GS._ApplyMutations(shadow, authBody)
            if not ok then
                return false, err or "apply_failed"
            end
        end
    end
    projectedRecords[authBody.id] = authBody
    if targetKey and type(shadow.operations) == "table"
        and type(shadow.operations.heads) == "table" then
        shadow.operations.heads[targetKey] = authBody.id
    end
    return true
end

--- Count distinct not-yet-accepted candidates that admission would promote now.
-- Uses a bounded temporary projection that reuses admission classification and
-- mutation semantics (policy revision, accepted predecessor membership, campaign
-- current id) so within-batch dependents are charged. Not a parallel eligibility
-- definition. Confirm-first/body-late ids are skipped until retained. Optional
-- startIdx limits to a resume window (paced apply).
-- Second return is a mutation-capacity failure (e.g. requestedItems full) distinct
-- from accepted-operation slot accounting in PreflightConfirmationCapacity.
local function CountEligibleConfirmationPromotions(record, storedConfirm, admissionCtx, startIdx)
    admissionCtx = admissionCtx or {}
    local ops = record and record.operations
    if type(ops) ~= "table" or type(storedConfirm) ~= "table" then
        return 0
    end
    local ids = ConfirmationCandidateIds(storedConfirm)
    startIdx = tonumber(startIdx) or 1
    if startIdx < 1 then
        startIdx = 1
    end
    local projectedRecords = {}
    local shadowHeads = {}
    if type(ops.heads) == "table" then
        for k, v in pairs(ops.heads) do
            shadowHeads[k] = v
        end
    end
    local shadowPermission = {}
    if type(record.permission) == "table" then
        for k, v in pairs(record.permission) do
            shadowPermission[k] = v
        end
    end
    -- Campaign map: copy-on-write only when a projected start inserts a header.
    local shadowCampaigns = record.campaigns
    local campaignsCopied = false
    local shadowRecords = setmetatable({}, {
        __index = function(_, k)
            return projectedRecords[k] or (ops.records and ops.records[k])
        end,
    })
    local shadowOps = {
        records = shadowRecords,
        pending = ops.pending,
        conflicts = ops.conflicts,
        openConflicts = ops.openConflicts,
        heads = shadowHeads,
        order = ops.order,
    }
    -- Accounting is shared read-only for classification; SET_BANK_TAB projection
    -- may write bankTab on a shallow consumables copy when needed.
    local shadowConsumables = nil
    local shadowAccounting = record.accounting
    local shadow = {
        datasetId = record.datasetId,
        currentCampaignId = record.currentCampaignId,
        permission = shadowPermission,
        accounting = shadowAccounting,
        operations = shadowOps,
        campaigns = shadowCampaigns,
        _guildKey = record._guildKey,
    }
    local count = 0
    local counted = {}
    for i = startIdx, #ids do
        local rid = ids[i]
        if type(rid) == "string" and not counted[rid] then
            counted[rid] = true
            if not (ops.records and ops.records[rid]) and not projectedRecords[rid] then
                local authBody = AuthoritativeBodyFromEnvelope(storedConfirm, rid)
                if type(authBody) == "table" then
                    local body, boundary = LookupRetainedCandidate(record, rid)
                    if type(body) == "table" and AuthoritativeBodiesEqual(authBody, body) then
                        local class = ClassifyConfirmationPromotion(
                            shadow, authBody, admissionCtx)
                        if class == "apply" then
                            count = count + 1
                            if authBody.kind == GS.KIND.SET_BANK_TAB
                                or authBody.kind == GS.KIND.SET_REQUESTED_ITEM then
                                if not shadowConsumables
                                    and type(record.accounting) == "table"
                                    and type(record.accounting._consumables) == "table" then
                                    local liveCfg = record.accounting._consumables
                                    shadowConsumables = {}
                                    for k, v in pairs(liveCfg) do
                                        shadowConsumables[k] = v
                                    end
                                    -- Isolate nested tables that reused _ApplyMutations /
                                    -- Note*EligibilityCutoff helpers may write. A shallow
                                    -- eligibility copy alone still shares eligibility.items
                                    -- with live durable state.
                                    if type(liveCfg.requestedItems) == "table" then
                                        local items = {}
                                        for ik, iv in pairs(liveCfg.requestedItems) do
                                            if type(iv) == "table" then
                                                local copy = {}
                                                for fk, fv in pairs(iv) do
                                                    copy[fk] = fv
                                                end
                                                items[ik] = copy
                                            else
                                                items[ik] = iv
                                            end
                                        end
                                        shadowConsumables.requestedItems = items
                                    end
                                    if type(liveCfg.eligibility) == "table" then
                                        local elig = {}
                                        for ek, ev in pairs(liveCfg.eligibility) do
                                            elig[ek] = ev
                                        end
                                        if type(liveCfg.eligibility.items) == "table" then
                                            local eligItems = {}
                                            for ik, iv in pairs(liveCfg.eligibility.items) do
                                                eligItems[ik] = iv
                                            end
                                            elig.items = eligItems
                                        end
                                        shadowConsumables.eligibility = elig
                                    end
                                    shadow.accounting = { _consumables = shadowConsumables }
                                end
                            end
                            if authBody.kind == GS.KIND.START_CAMPAIGN
                                and not campaignsCopied then
                                local copy = {}
                                if type(record.campaigns) == "table" then
                                    for ck, cv in pairs(record.campaigns) do
                                        copy[ck] = cv
                                    end
                                end
                                shadow.campaigns = copy
                                campaignsCopied = true
                            end
                            local pok, perr = ProjectConfirmationPromotion(
                                shadow, projectedRecords, authBody, boundary)
                            if not pok then
                                -- Requested-item (and other mutation) capacity must
                                -- fail closed before envelope persistence.
                                return count, perr or "full"
                            end
                        end
                    end
                end
            end
        end
    end
    return count
end

--- Drop live confirmation-redrive scheduling state for a replaced/obsolete record.
-- Durable confirmationRefs / relay evidence are not touched.
ClearConfirmationRedriveForRecord = function(record)
    if type(GS._confirmationRedriveByKey) ~= "table" or type(record) ~= "table" then
        return
    end
    for k, st in pairs(GS._confirmationRedriveByKey) do
        if type(st) == "table" and st.record == record then
            GS._confirmationRedriveByKey[k] = nil
        end
    end
end

ClearConfirmationRedriveForGuild = function(guildKey)
    if type(GS._confirmationRedriveByKey) ~= "table" or type(guildKey) ~= "string" then
        return
    end
    local prefix = tostring(guildKey) .. "\0"
    for k, st in pairs(GS._confirmationRedriveByKey) do
        if type(k) == "string" and string.sub(k, 1, #prefix) == prefix then
            GS._confirmationRedriveByKey[k] = nil
        elseif type(st) == "table" and type(st.record) == "table"
            and st.record._guildKey == guildKey then
            GS._confirmationRedriveByKey[k] = nil
        end
    end
end

--- Shared capacity preflight for local/remote confirmation commit.
-- Accounts for the envelope slot (when not yet accepted) plus distinct eligible
-- promotions. Rejects before any envelope/ref/head/config/retention mutation.
-- During adoptionReplay, promotions are deferred to paced redrive — only the
-- envelope slot is charged here; redrive rechecks when candidates become eligible.
function GS.PreflightConfirmationCapacity(record, storedConfirm, admissionCtx)
    admissionCtx = admissionCtx or {}
    if type(record) ~= "table" or type(storedConfirm) ~= "table" then
        return false, "invalid_operation"
    end
    local ops = record.operations
    if type(ops) ~= "table" then
        return false, "invalid_operations"
    end
    local slotsNeeded = 0
    if not (ops.records and ops.records[storedConfirm.id]) then
        slotsNeeded = slotsNeeded + 1
    end
    if not admissionCtx.adoptionReplay then
        local eligible, mutErr = CountEligibleConfirmationPromotions(
            record, storedConfirm, admissionCtx, 1)
        -- Mutation capacity (requestedItems full, etc.) is distinct from
        -- accepted-operation slot counting but shares the "full" reject reason.
        if mutErr == "full" then
            return false, "full"
        end
        if mutErr then
            return false, mutErr
        end
        slotsNeeded = slotsNeeded + (tonumber(eligible) or 0)
    end
    if slotsNeeded > 0 and GS._AcceptedCount then
        if GS._AcceptedCount(ops) + slotsNeeded > (GS.MAX_ACCEPTED_OPERATIONS or 4096) then
            return false, "full"
        end
    end
    return true, nil
end

--- Shared exact-content confirmation apply: promote matching retained candidates.
-- Preserves original attribution; does not synthesize approvals.
-- During adoptionReplay, SET_EDITOR_RANK promotions are deferred while same-base
-- acceptable non-rank history remains unsettled (matches direct rank Admit gate).
-- Optional pacing via admissionCtx:
--   confirmApplyBudget (number) — max candidate-row work units this call
--   confirmApplyStartIdx (number) — 1-based resume index into the id list
-- Returns ok, err, promoted, visited, nextIdx (nextIdx nil when envelope done).
function GS.ApplyExactContentConfirmation(record, storedConfirm, admissionCtx)
    admissionCtx = admissionCtx or {}
    if type(record) ~= "table" or type(storedConfirm) ~= "table" then
        return false, "invalid_operation", 0, 0, nil
    end
    -- Bind retained candidates to authoritative bodies embedded in the
    -- authenticated confirmation envelope. Fingerprint equality is never sufficient.
    local ids = ConfirmationCandidateIds(storedConfirm)
    local budget = tonumber(admissionCtx.confirmApplyBudget)
    if not budget or budget ~= budget or budget < 1 then
        budget = math.huge
    end
    local startIdx = tonumber(admissionCtx.confirmApplyStartIdx) or 1
    if startIdx < 1 then
        startIdx = 1
    end
    -- Fail closed: when eligible promotions in this resume window cannot all fit,
    -- do not partially apply the batch. Envelope storage is the caller's concern.
    -- nextIdx is nil on capacity failure (distinct from budget-yield resume).
    local eligible, mutErr = CountEligibleConfirmationPromotions(
        record, storedConfirm, admissionCtx, startIdx)
    if mutErr == "full" or mutErr then
        return false, mutErr or "full", 0, 0, nil
    end
    eligible = tonumber(eligible) or 0
    if eligible > 0 and GS._AcceptedCount and record.operations then
        if GS._AcceptedCount(record.operations) + eligible
            > (GS.MAX_ACCEPTED_OPERATIONS or 4096) then
            return false, "full", 0, 0, nil
        end
    end
    local seen = {}
    -- Skip ids already handled before startIdx so resume does not re-promote.
    for i = 1, startIdx - 1 do
        local rid = ids[i]
        if type(rid) == "string" then
            seen[rid] = true
        end
    end
    local promoted = 0
    local visited = 0
    local i = startIdx
    while i <= #ids do
        if visited >= budget then
            return true, nil, promoted, visited, i
        end
        local rid = ids[i]
        i = i + 1
        if type(rid) == "string" and not seen[rid] then
            seen[rid] = true
            visited = visited + 1
            local authBody = AuthoritativeBodyFromEnvelope(storedConfirm, rid)
            if type(authBody) ~= "table" then
                DebugWarn("confirm missing authoritative body id=%s", rid)
            else
                if admissionCtx.adoptionReplay and admissionCtx.deferRank
                    and authBody.kind == GS.KIND.SET_EDITOR_RANK then
                    -- Park rank promotion until bootstrap-base non-rank history drains.
                else
                local body, boundary, _, source = LookupRetainedCandidate(record, rid)
                if type(body) == "table" and AuthoritativeBodiesEqual(authBody, body) then
                    -- Promote the envelope's authoritative content (not an untrusted copy).
                    local st, reason = ApplyPreservedAttributionCandidate(
                        record, authBody, boundary, admissionCtx)
                    if st == "accepted" or st == "duplicate" then
                        promoted = promoted + 1
                        GS._pendingRelay[rid] = nil
                        if GS._pendingCampaignBoundaries then
                            GS._pendingCampaignBoundaries[rid] = nil
                        end
                        if source == "pending" and record.operations.pending then
                            record.operations.pending[rid] = nil
                        end
                        if source == "conflict" and record.operations.conflicts then
                            record.operations.conflicts[rid] = nil
                        end
                    elseif st == "pending" then
                        -- Keep unfinished siblings; confirmation envelope still accepted.
                    elseif reason == "full" then
                        -- Fail closed only when an apply-class promotion still cannot
                        -- fit. Conflict/pending retention full must not abort the
                        -- envelope (exact-fit batches keep non-promoting siblings).
                        local classNow = ClassifyConfirmationPromotion(
                            record, authBody, admissionCtx)
                        if classNow == "apply" then
                            return false, "full", promoted, visited, nil
                        end
                        DebugWarn("confirm apply skipped id=%s status=%s reason=%s",
                            rid, tostring(st), tostring(reason))
                    else
                        DebugWarn("confirm apply skipped id=%s status=%s reason=%s",
                            rid, tostring(st), tostring(reason))
                    end
                end
                end -- deferRank else
            end
        end
    end
    return true, nil, promoted, visited, nil
end

--- Guild key helper for live confirmation-redrive continuation ownership.
local function ConfirmationRedriveGuildKey(record)
    if type(record) ~= "table" then
        return nil
    end
    if type(record._guildKey) == "string" and record._guildKey ~= "" then
        return record._guildKey
    end
    -- Fall back to the live guild handle when the record pointer is installed.
    local root = GS._root
    if type(root) == "table" and type(root.guilds) == "table" then
        for gk, rec in pairs(root.guilds) do
            if rec == record then
                return gk
            end
        end
    end
    return nil
end

local function ConfirmationRedriveKey(record)
    if type(record) ~= "table" then
        return nil
    end
    local guildKey = ConfirmationRedriveGuildKey(record) or ""
    local datasetId = record.datasetId or ""
    -- Pointer identity distinguishes replacement records that reuse dataset ids.
    return tostring(guildKey) .. "\0" .. tostring(datasetId) .. "\0" .. tostring(record)
end

--- Re-apply accepted confirmation envelopes against newly retained candidates.
-- Returns done (bool), visited, promoted, err.
-- err == "full" means capacity-blocked (not a budget yield): live path does not
-- schedule After(0) retries against an unchanged full store; adoption propagates
-- the failure. Meaningful retain/accept re-enters and clears capacityBlocked.
-- Adoption replay uses session-owned state + callback budget (never expands to
-- the full confirmationRefs length). Live short passes clear keyed state too.
function GS.RedriveExactContentConfirmations(record, admissionCtx)
    if type(record) ~= "table" or type(record.confirmationRefs) ~= "table" then
        return true, 0
    end
    local ops = record.operations
    if type(ops) ~= "table" or type(ops.records) ~= "table" then
        return true, 0
    end
    local total = #record.confirmationRefs
    if total < 1 then
        return true, 0
    end
    admissionCtx = admissionCtx or {}
    local adoptionReplay = admissionCtx.adoptionReplay == true
    -- Adoption owns continuation on the replay state; live uses the keyed table.
    local key = nil
    local state = nil
    if adoptionReplay and type(admissionCtx.redriveState) == "table" then
        state = admissionCtx.redriveState
        if state.pos == nil then
            state.pos = 1
            state.remaining = nil
        end
        state.record = record
    else
        key = ConfirmationRedriveKey(record)
        GS._confirmationRedriveByKey = GS._confirmationRedriveByKey or {}
        state = GS._confirmationRedriveByKey[key]
        if type(state) ~= "table" then
            state = { pos = 1, remaining = nil, scheduled = false, record = record }
            GS._confirmationRedriveByKey[key] = state
        else
            state.record = record
        end
    end
    -- A new call is a meaningful recheck opportunity (retain/accept/capacity change).
    state.capacityBlocked = nil
    local defaultSlice = GS.MAX_CONFIRMATION_REDRIVE_PER_SLICE or 32
    local slice = defaultSlice
    if adoptionReplay then
        -- Charge against the available callback budget; never drain the full list.
        slice = math.max(1, tonumber(admissionCtx.redriveBudget) or defaultSlice)
    end
    local start = tonumber(state.pos) or 1
    if start > total then
        start = 1
    end
    local processed = 0
    local envelopesCompleted = 0
    local promoted = 0
    local i = start
    local visitBudget = slice
    -- Candidate-level resume within a large multirow envelope.
    local candRow = tonumber(state.candRow)
    -- Mid-envelope exits must still run remaining accounting + live scheduling.
    local midEnvelope = false
    local capacityBlocked = false
    -- Pass goal is envelopes still owed this circular pass (not a fresh total).
    -- Bound the loop by passGoal so completing the last owed envelope cannot
    -- wrap into already-completed work and revive remaining.
    local passGoal = tonumber(state.remaining)
    if passGoal == nil then
        passGoal = total
    end
    if passGoal < 1 then
        passGoal = total
    end
    while envelopesCompleted < passGoal and processed < visitBudget do
        local cid = record.confirmationRefs[i]
        local conf = ops.records[cid]
        if type(conf) == "table" and conf.kind == GS.KIND.CONFIRM_CANDIDATE then
            local budgetLeft = visitBudget - processed
            local startIdx = candRow or 1
            local startingEnvelope = startIdx <= 1
            -- Envelope meta costs 1; remaining budget pays for candidate rows.
            -- Never start a new envelope when only a leftover non-divisible unit
            -- remains and another envelope was already completed this call.
            local applyBudget = budgetLeft
            if startingEnvelope then
                if budgetLeft < 2 and envelopesCompleted > 0 then
                    break
                end
                applyBudget = math.max(1, budgetLeft - 1)
            end
            local applyCtx = {}
            for k, v in pairs(admissionCtx) do
                applyCtx[k] = v
            end
            applyCtx.confirmApplyBudget = applyBudget
            applyCtx.confirmApplyStartIdx = startIdx
            local okApply, errApply, promo, visitedRows, nextIdx =
                GS.ApplyExactContentConfirmation(record, conf, applyCtx)
            promo = tonumber(promo) or 0
            visitedRows = tonumber(visitedRows) or 0
            local charged = visitedRows + (startingEnvelope and 1 or 0)
            if charged < 1 then
                charged = 1
            end
            processed = processed + charged
            promoted = promoted + promo
            -- Capacity failure is not a budget yield: do not treat nextIdx as
            -- unfinished mid-envelope work and do not schedule After(0) spins.
            if okApply == false and errApply == "full" then
                state.pos = i
                state.candRow = startIdx
                state.capacityBlocked = true
                capacityBlocked = true
                break
            end
            if nextIdx ~= nil then
                -- Mid-envelope budget yield: keep position/candRow; do not count
                -- complete. Fall through to shared remaining + scheduling.
                state.pos = i
                state.candRow = nextIdx
                midEnvelope = true
                break
            end
            state.candRow = nil
            candRow = nil
        else
            processed = processed + 1
            state.candRow = nil
            candRow = nil
        end
        envelopesCompleted = envelopesCompleted + 1
        i = i + 1
        if i > total then
            i = 1
        end
        candRow = nil
    end
    if adoptionReplay and processed > 0 then
        local adop = GS._adoption
        if type(adop) == "table" then
            local stats = EnsureAdoptionWorkStats(adop)
            stats.confirmRedriveVisited = (tonumber(stats.confirmRedriveVisited) or 0) + processed
        end
    end
    if capacityBlocked then
        if adoptionReplay then
            -- Session-owned cursor stays for abort/fail-closed; no live timer.
            local remaining = math.max(1, passGoal - envelopesCompleted)
            state.remaining = remaining
            state.scheduled = false
            state.done = false
            return false, processed, promoted, "full"
        end
        -- Live: drop scheduling state so replacement cannot pin stale records.
        -- Durable confirmationRefs / relay evidence remain for later recheck.
        if key then
            GS._confirmationRedriveByKey[key] = nil
        end
        return false, processed, promoted, "full"
    end
    if not midEnvelope then
        state.pos = i
        state.candRow = nil
    end
    -- Credit only fully completed envelopes; mid-envelope keeps work outstanding.
    local remaining = math.max(0, passGoal - envelopesCompleted)
    if midEnvelope then
        -- Still inside an owed envelope; never treat the pass as finished.
        remaining = math.max(remaining, 1)
    end
    state.remaining = remaining
    local finished = (not midEnvelope) and remaining <= 0
    if finished then
        state.remaining = nil
        state.pos = 1
        state.candRow = nil
        state.capacityBlocked = nil
        if adoptionReplay then
            -- Session-owned state cleared by caller / next begin; mark complete.
            state.done = true
        elseif key then
            GS._confirmationRedriveByKey[key] = nil
        end
        return true, processed, promoted
    end
    if adoptionReplay then
        state.done = false
        return false, processed, promoted
    end
    -- Live path: schedule continuation until one full pass completes.
    -- Mid-envelope budget yields use the same scheduler (candRow preserved above).
    -- Capacity-blocked exits above never reach this scheduler.
    if not state.scheduled then
        state.scheduled = true
        local expectedKey = key
        local expectedRecord = record
        local expectedDataset = record.datasetId
        local expectedGuild = ConfirmationRedriveGuildKey(record)
        local function continueRedrive()
            local st = GS._confirmationRedriveByKey and GS._confirmationRedriveByKey[expectedKey]
            if type(st) ~= "table" then
                return
            end
            st.scheduled = false
            -- Ownership / replacement first — never pin obsolete records.
            local live = nil
            if type(expectedGuild) == "string" and GS._root and type(GS._root.guilds) == "table" then
                live = GS._root.guilds[expectedGuild]
            else
                live = expectedRecord
            end
            if live ~= expectedRecord
                or (type(live) == "table" and live.datasetId ~= expectedDataset) then
                GS._confirmationRedriveByKey[expectedKey] = nil
                return
            end
            -- Do not timer-spin an unchanged capacity-blocked store.
            if st.capacityBlocked then
                GS._confirmationRedriveByKey[expectedKey] = nil
                return
            end
            -- Continue while envelopes remain or a mid-envelope candRow is parked.
            local stillOpen = (tonumber(st.remaining) or 0) > 0 or st.candRow ~= nil
            if type(expectedRecord.confirmationRefs) == "table"
                and #expectedRecord.confirmationRefs > 0
                and stillOpen then
                GS.RedriveExactContentConfirmations(expectedRecord, admissionCtx or {})
            else
                st.remaining = nil
                st.candRow = nil
                GS._confirmationRedriveByKey[expectedKey] = nil
            end
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(0, continueRedrive)
        else
            continueRedrive()
        end
    end
    return false, processed, promoted
end

--- Authenticated remote admission for a durable operation body.
-- @param op table public operation
-- @param admissionCtx { sender, member?, boundary?, relay?, localWrite?,
--   adoptionReplay?, offlineRecord?, confirmAuthority? }
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

    local record, recReason = EnsureRecordForRemote(member.guildKey, admissionCtx)
    if not record then
        if recReason == "not_configured" then
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
    -- Shared remote mutation boundary: authenticated live cutover conflict
    -- fail-closes production config/campaign/ledger-adjacent ops. Adoption
    -- replay onto a temporary record remains exempt (#389).
    if GS.LiveAccountingWritesBlocked then
        local blocked, blockReason = GS.LiveAccountingWritesBlocked(record, admissionCtx)
        if blocked then
            return "rejected", blockReason or "live_activation_conflict"
        end
    end

    -- Valid-policy rank changes replicate from ordinary authenticated editors.
    -- GM recovery is required only when the current policy is incoherent.
    local requireRecover = false
    if op.kind == GS.KIND.SET_EDITOR_RANK then
        local perm = record.permission
        local policyPos = type(perm) == "table" and tonumber(perm.editorRankPosition) or nil
        local ranks = GG() and GG().GetGuildRanks and GG().GetGuildRanks()
        local rankCount = type(ranks) == "table" and tonumber(ranks.count) or nil
        local policyOk = policyPos and policyPos >= 1
            and (not rankCount or policyPos <= rankCount)
            and type(perm) == "table"
            and type(perm.revisionId) == "string" and perm.revisionId ~= ""
        requireRecover = not policyOk
    end

    -- Descriptor-first catch-up: while bootstrap-locked, a SET_EDITOR_RANK whose
    -- basePolicyRevision equals the current predecessor policy may admit under
    -- allowPolicyCatchUp. Matching the final advertised ID alone is not authority;
    -- SenderHasEditorAuthority still validates the sender under the predecessor
    -- policy position. Ordinary non-rank mutations stay locked / relay-retained.
    local bootstrapLocked = GS.IsBootstrapEditLocked
        and GS.IsBootstrapEditLocked(member.guildKey, record)
    local currentPolicy = record.permission and record.permission.revisionId
    local isPolicyCatchUp = bootstrapLocked
        and op.kind == GS.KIND.SET_EDITOR_RANK
        and type(op.basePolicyRevision) == "string"
        and op.basePolicyRevision == currentPolicy
    -- Offline adoption onto an empty client: SenderHasEditorAuthority looks up the
    -- live guild slot (not offlineRecord). Without allowBootstrapInstall it returns
    -- not_configured and every source-authored body becomes untrusted_relay, so
    -- START_CAMPAIGN never lands and replay cannot converge. Begin already gated
    -- the source under allowBootstrapInstall; reuse that while live is absent.
    local authOpts = {
        requireRecoverPolicy = requireRecover,
        allowPolicyCatchUp = isPolicyCatchUp,
    }
    if admissionCtx.adoptionReplay and type(admissionCtx.offlineRecord) == "table" then
        local liveGuild = GS._root and GS._root.guilds and GS._root.guilds[member.guildKey]
        if type(liveGuild) ~= "table" then
            authOpts.allowBootstrapInstall = true
        end
    end
    local editorOk, editorReason = GS.SenderHasEditorAuthority(member, authOpts)

    -- Policy catch-up must not be forced into the relay branch by Gossip's
    -- pre-admit relay flag; catch-up context overrides relay for this body only.
    local treatAsRelay = admissionCtx.relay == true
    if isPolicyCatchUp and editorOk then
        treatAsRelay = false
    end

    -- Untrusted relay: retain historical candidates without rebinding attribution.
    -- A forwarded author field is not authentication, even if that GUID is currently
    -- an editor. Explicit exact-content confirmation is the only promotion path.
    if treatAsRelay or not editorOk then
        local rid = op.id
        if type(rid) ~= "string" or rid == "" then
            return "rejected", "invalid_operation"
        end
        local entry = {
            body = op,
            sender = member.name,
            at = GetServerTime and GetServerTime() or op.timestamp,
            fingerprint = ContentFingerprint(op),
            boundary = admissionCtx.boundary,
        }
        local okRetain, retainErr = RetainPendingRelay(rid, entry)
        if not okRetain then
            return "rejected", retainErr or "full"
        end
        if type(admissionCtx.boundary) == "table" and op.kind == GS.KIND.START_CAMPAIGN then
            GS._pendingCampaignBoundaries[rid] = admissionCtx.boundary
        end
        -- Candidate may unlock a confirm-first envelope already accepted.
        -- Adoption replay owns paced redrive at the slice boundary; nested full
        -- scans must not restart here.
        if not admissionCtx.adoptionReplay then
            GS.RedriveExactContentConfirmations(record, admissionCtx)
        end
        return "pending", "untrusted_relay"
    end

    -- Authenticated editor path: bind durable attribution to the transport sender.
    -- Skip rebinding when adoption/confirm applies a preserved historical body.
    -- Actor mismatch on an otherwise-authenticated editor carrier is untrusted
    -- relay (retain for exact-content confirmation), never silent apply.
    if not admissionCtx.preserveAttribution then
        local bindOk, bindErr = BindActorFromSender(op, member)
        if not bindOk then
            if bindErr == "actor_mismatch" then
                local rid = op.id
                if type(rid) ~= "string" or rid == "" then
                    return "rejected", "invalid_operation"
                end
                local entry = {
                    body = op,
                    sender = member.name,
                    at = GetServerTime and GetServerTime() or op.timestamp,
                    fingerprint = ContentFingerprint(op),
                    boundary = admissionCtx.boundary,
                }
                local okRetain, retainErr = RetainPendingRelay(rid, entry)
                if not okRetain then
                    return "rejected", retainErr or "full"
                end
                if type(admissionCtx.boundary) == "table" and op.kind == GS.KIND.START_CAMPAIGN then
                    GS._pendingCampaignBoundaries[rid] = admissionCtx.boundary
                end
                if not admissionCtx.adoptionReplay then
                    GS.RedriveExactContentConfirmations(record, admissionCtx)
                end
                return "pending", "untrusted_relay"
            end
            return "rejected", bindErr or "actor_mismatch"
        end
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

    if GS.ValidateAcceptedOperationBody then
        local shapeOk, shapeErr = GS.ValidateAcceptedOperationBody(
            stored, member.guildKey, record.datasetId)
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
        local policyNow = CurrentPolicyRevision(record)
        local policyOk = stored.basePolicyRevision == policyNow
        -- Adoption chicken-egg: a confirm prepared after a rank change pins
        -- basePolicyRevision to that rank id. Allow the envelope when it binds
        -- that same rank (or any listed) so reverse-order peers can promote it.
        if not policyOk and admissionCtx.adoptionReplay then
            local ref = stored.candidateRef
            local function bindsId(id)
                if type(ref) ~= "table" or type(id) ~= "string" then
                    return false
                end
                if ref.recordId == id then
                    return true
                end
                if type(ref.originalIds) == "table" then
                    for j = 1, #ref.originalIds do
                        if ref.originalIds[j] == id then
                            return true
                        end
                    end
                end
                if type(ref.records) == "table" then
                    for j = 1, #ref.records do
                        local row = ref.records[j]
                        if type(row) == "table" and row.id == id then
                            return true
                        end
                    end
                end
                return false
            end
            if bindsId(stored.basePolicyRevision) then
                policyOk = true
            end
        end
        if not policyOk then
            if GS._AdmitPendingOrConflict then
                return GS._AdmitPendingOrConflict(ops, stored, "stale_base")
            end
            return "pending", "stale_base"
        end
        if (stored.campaignId or nil) ~= (record.currentCampaignId or nil) then
            if GS._AdmitPendingOrConflict then
                return GS._AdmitPendingOrConflict(ops, stored, "stale_base")
            end
            return "pending", "stale_base"
        end
        -- Atomic capacity: envelope + currently eligible promotions (shared with local).
        local capOk, capErr = GS.PreflightConfirmationCapacity(record, stored, admissionCtx)
        if not capOk then
            return "rejected", capErr or "full"
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
        -- Adoption replay applies candidates via paced session redrive; do not
        -- synchronously drain multirow manifests on the admit path.
        if not admissionCtx.adoptionReplay then
            -- Preflight already required capacity for the eligible batch; Apply
            -- fail-closes without partial promotions if eligibility raced.
            local okApply, errApply = GS.ApplyExactContentConfirmation(
                record, stored, admissionCtx)
            if okApply == false and errApply == "full" then
                return "rejected", "full"
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
        local ancestryOk = ResolutionMatchesOpenConflictAncestry(record, stored, targetKey)
        -- Stale resolutions cannot cross policy/campaign resets, but sibling
        -- open-conflict ancestry sharing the resolution bases is allowed.
        if stored.basePolicyRevision ~= CurrentPolicyRevision(record) and not ancestryOk then
            if admissionCtx.adoptionReplay then
                -- Source-accepted envelopes wait on the worklist; do not park them
                -- in durable conflict retention (replay would treat that as settled).
                return "pending", "stale_base"
            end
            return "rejected", "stale_base"
        end
        if (stored.baseCampaignId or nil) ~= (record.currentCampaignId or nil) and not ancestryOk then
            if admissionCtx.adoptionReplay then
                return "pending", "stale_base"
            end
            return "rejected", "stale_base"
        end
        -- Resolutions always require a non-empty competingOpIds dependency set.
        if type(value.competingOpIds) ~= "table" or #value.competingOpIds < 1 then
            return "rejected", "invalid_resolution"
        end
        if type(open) ~= "table" then
            -- Fast path: chosen already current head — still require complete
            -- dependency fingerprints for every competing id (no chosen-only fallback).
            local headNow = ops.heads and ops.heads[targetKey]
            if type(headNow) == "string" then
                headNow = UnderlyingConflictValueId(ops, headNow) or headNow
            end
            local chosenNow = UnderlyingConflictValueId(ops, value.chosenOpId) or value.chosenOpId
            if headNow == value.chosenOpId or headNow == chosenNow then
                local matchOk, matchErr = ResolutionBodiesMatch(value, ops, value.competingOpIds)
                if not matchOk then
                    if matchErr == "content_mismatch" and admissionCtx.adoptionReplay then
                        -- Dependency not ready: stay on the adoption worklist without
                        -- charging the shared durable pending/conflict retention pool.
                        return "pending", "missing_predecessor"
                    end
                    return "rejected", matchErr or "invalid_resolution"
                end
                -- Relocate competing losers into conflict retention (same as open path).
                local retainPlan = {}
                local newConflictSlots = 0
                if type(value.competingOpIds) == "table" then
                    for i = 1, #value.competingOpIds do
                        local cid = value.competingOpIds[i]
                        if cid ~= value.chosenOpId then
                            if ops.conflicts and ops.conflicts[cid] then
                                retainPlan[#retainPlan + 1] = { cid = cid, mode = "present" }
                            elseif ops.pending and ops.pending[cid] and ops.pending[cid].body then
                                retainPlan[#retainPlan + 1] = {
                                    cid = cid,
                                    mode = "relocate",
                                    body = ops.pending[cid].body,
                                }
                            elseif type(value.contentBodies) == "table"
                                and type(value.contentBodies[cid]) == "table" then
                                retainPlan[#retainPlan + 1] = {
                                    cid = cid,
                                    mode = "insert",
                                    body = value.contentBodies[cid],
                                }
                                newConflictSlots = newConflictSlots + 1
                            else
                                if admissionCtx.adoptionReplay then
                                    return "pending", "missing_predecessor"
                                end
                                return "rejected", "invalid_resolution"
                            end
                        end
                    end
                end
                local slotsNeeded = 0
                if not ops.records[stored.id] then
                    slotsNeeded = slotsNeeded + 1
                end
                if slotsNeeded > 0 and GS._AcceptedCount
                    and GS._AcceptedCount(ops) + slotsNeeded > GS.MAX_ACCEPTED_OPERATIONS then
                    return "rejected", "full"
                end
                if newConflictSlots > 0 and GS._RetentionBodyCount and GS.MAX_PENDING_OPERATIONS then
                    if GS._RetentionBodyCount(ops) + newConflictSlots > GS.MAX_PENDING_OPERATIONS then
                        return "rejected", "full"
                    end
                end
                if not ops.records[stored.id] then
                    if GS._StoreAccepted then
                        GS._StoreAccepted(ops, stored, nil)
                    end
                end
                if ops.heads then
                    ops.heads[targetKey] = value.chosenOpId
                end
                for i = 1, #retainPlan do
                    local step = retainPlan[i]
                    if step.mode == "relocate" or step.mode == "insert" then
                        if not (GS._RetainConflict and GS._RetainConflict(ops, step.body)) then
                            return "rejected", "full"
                        end
                    end
                end
                -- Fast-path still mutates durable history (envelope + losers).
                if GS._NotifyLocalDurableChange and not admissionCtx.adoptionReplay then
                    GS._NotifyLocalDurableChange("remote-resolve")
                end
                return "accepted", nil
            end
            -- During adoption replay, competing candidates may arrive later.
            -- Do not consume a durable retention slot merely because transfer
            -- order delivered the resolution before its losing candidate.
            if admissionCtx.adoptionReplay then
                return "pending", "missing_predecessor"
            end
            return "rejected", "no_open_conflict"
        end
        -- Chosen ID must be one of the open conflict candidates.
        local chosenInOpen = false
        if type(open.candidateIds) == "table" then
            for i = 1, #open.candidateIds do
                if open.candidateIds[i] == value.chosenOpId then
                    chosenInOpen = true
                    break
                end
            end
        end
        if not chosenInOpen then
            return "rejected", "invalid_resolution"
        end
        -- Exact competing set: every open candidate must be listed (required).
        if type(open.candidateIds) ~= "table"
            or #value.competingOpIds ~= #open.candidateIds then
            return "rejected", "invalid_resolution"
        end
        do
            local openSeen, listed = {}, {}
            for i = 1, #open.candidateIds do
                openSeen[open.candidateIds[i]] = true
            end
            for i = 1, #value.competingOpIds do
                local cid = value.competingOpIds[i]
                if not openSeen[cid] or listed[cid] then
                    return "rejected", "invalid_resolution"
                end
                listed[cid] = true
            end
            for id in pairs(openSeen) do
                if not listed[id] then
                    return "rejected", "invalid_resolution"
                end
            end
        end
        do
            local matchOk, matchErr = ResolutionBodiesMatch(value, ops, open.candidateIds)
            if not matchOk then
                return "rejected", matchErr or "invalid_resolution"
            end
        end
        local chosen = ops.records[value.chosenOpId]
            or (ops.pending[value.chosenOpId] and ops.pending[value.chosenOpId].body)
            or (ops.conflicts[value.chosenOpId] and ops.conflicts[value.chosenOpId].body)
        if type(chosen) ~= "table" then
            return "pending", "missing_predecessor"
        end
        -- Unwrap resolve envelopes so repeated conflicts target the live value.
        local applyId = UnderlyingConflictValueId(ops, value.chosenOpId) or value.chosenOpId
        if applyId ~= value.chosenOpId then
            chosen = ops.records[applyId]
                or (ops.pending[applyId] and ops.pending[applyId].body)
                or (ops.conflicts[applyId] and ops.conflicts[applyId].body)
            if type(chosen) ~= "table" then
                return "pending", "missing_predecessor"
            end
        end
        -- Atomic capacity preflight: chosen promotion + resolution store.
        local slotsNeeded = 0
        if not ops.records[stored.id] then
            slotsNeeded = slotsNeeded + 1
        end
        if not ops.records[applyId] then
            slotsNeeded = slotsNeeded + 1
        end
        if slotsNeeded > 0 and GS._AcceptedCount
            and GS._AcceptedCount(ops) + slotsNeeded > GS.MAX_ACCEPTED_OPERATIONS then
            return "rejected", "full"
        end
        -- Preflight the COMPLETE loser retention set before any projection/head
        -- mutation. Relocates are free; count only brand-new conflict slots once.
        local retainPlan = {}
        local newConflictSlots = 0
        if type(value.competingOpIds) == "table" then
            for i = 1, #value.competingOpIds do
                local cid = value.competingOpIds[i]
                if cid ~= value.chosenOpId then
                    if ops.conflicts and ops.conflicts[cid] then
                        retainPlan[#retainPlan + 1] = { cid = cid, mode = "present" }
                    elseif ops.pending and ops.pending[cid] and ops.pending[cid].body then
                        retainPlan[#retainPlan + 1] = {
                            cid = cid,
                            mode = "relocate",
                            body = ops.pending[cid].body,
                        }
                    elseif type(value.contentBodies) == "table"
                        and type(value.contentBodies[cid]) == "table" then
                        retainPlan[#retainPlan + 1] = {
                            cid = cid,
                            mode = "insert",
                            body = value.contentBodies[cid],
                        }
                        newConflictSlots = newConflictSlots + 1
                    else
                        return "pending", "missing_predecessor"
                    end
                end
            end
        end
        if newConflictSlots > 0 and GS._RetentionBodyCount and GS.MAX_PENDING_OPERATIONS then
            if GS._RetentionBodyCount(ops) + newConflictSlots > GS.MAX_PENDING_OPERATIONS then
                return "rejected", "full"
            end
        end
        if chosen.kind == GS.KIND.START_CAMPAIGN then
            local boundary = (open.boundaries and open.boundaries[applyId])
                or (open.boundaries and open.boundaries[value.chosenOpId])
                or GS._pendingCampaignBoundaries[applyId]
                or GS._pendingCampaignBoundaries[value.chosenOpId]
                or admissionCtx.boundary
            local parentId = chosen.baseCampaignId
            local ok, err
            if type(record.campaigns[applyId]) ~= "table"
                and (record.currentCampaignId == parentId or record.currentCampaignId == nil) then
                -- First activation from the shared parent — normal campaign transition.
                ok, err = ApplyRemoteCampaignMutation(record, chosen, boundary)
            else
                -- Sibling resolution: restore chosen projection without archiving
                -- the provisional current sibling or bumping generation again.
                ok, err = ActivateChosenCampaignProjection(record, chosen, boundary)
            end
            if not ok then
                if err == "missing_campaign" or err == "missing_boundary" then
                    return "pending", err
                end
                return "rejected", err or "apply_failed"
            end
        else
            if chosen.kind == GS.KIND.SET_EDITOR_RANK then
                local rankOk, rankErr = ValidateEditorRankValue(chosen.value)
                if not rankOk then
                    return "rejected", rankErr or "invalid_editor_rank_position"
                end
            end
            if GS._ApplyMutations then
                local ok, err = GS._ApplyMutations(record, chosen)
                if not ok then
                    return "rejected", err or "apply_failed"
                end
            end
            if not ops.records[applyId] then
                if GS._StoreAccepted then
                    GS._StoreAccepted(ops, chosen, targetKey)
                end
            elseif ops.heads then
                ops.heads[targetKey] = applyId
            end
        end
        -- Retain resolution identity/causal ancestry without making the envelope
        -- the mutable field head (repeated conflicts must target the live value).
        if GS._StoreAccepted then
            GS._StoreAccepted(ops, stored, nil)
        end
        if ops.heads then
            if chosen.kind == GS.KIND.START_CAMPAIGN then
                ops.heads[GS.CAMPAIGN_TARGET_KEY] = applyId
                ops.heads[targetKey] = applyId
            else
                ops.heads[targetKey] = applyId
            end
        end
        if ops.openConflicts then
            ops.openConflicts[targetKey] = nil
        end
        for i = 1, #retainPlan do
            local step = retainPlan[i]
            if step.mode == "relocate" or step.mode == "insert" then
                if not (GS._RetainConflict and GS._RetainConflict(ops, step.body)) then
                    -- Preflight should have guaranteed capacity; treat as hard reject.
                    return "rejected", "full"
                end
            end
            if GS._pendingCampaignBoundaries then
                GS._pendingCampaignBoundaries[step.cid] = nil
            end
        end
        if GS._NotifyLocalDurableChange and not admissionCtx.adoptionReplay then
            GS._NotifyLocalDurableChange("remote-resolve")
        end
        return "accepted", nil
    end

    -- Causality classification for config / campaign.
    local class, classReason = ClassifyStaleBase(record, stored, targetKey)
    if stored.basePolicyRevision == CurrentPolicyRevision(record)
        and (stored.baseCampaignId or nil) == (record.currentCampaignId or nil)
        and (stored.kind == GS.KIND.START_CAMPAIGN
            or (stored.campaignId or nil) == (record.currentCampaignId or nil))
        and stored.baseTargetRevision == CurrentTargetRevision(record, targetKey) then
        class = "apply"
        classReason = nil
    end

    if class == "pending" then
        if stored.kind == GS.KIND.START_CAMPAIGN and type(admissionCtx.boundary) == "table" then
            GS._pendingCampaignBoundaries[stored.id] = admissionCtx.boundary
        end
        -- Source-accepted bodies waiting on dependencies stay on the adoption
        -- worklist; they must not burn durable pending/conflict slots.
        local sourceAccepted = admissionCtx.adoptionReplay
            and type(admissionCtx.sourceAcceptedSet) == "table"
            and admissionCtx.sourceAcceptedSet[stored.id] == true
        if sourceAccepted then
            return "pending", classReason or "missing_predecessor"
        end
        local stPend, reasonPend = "pending", classReason or "stale_base"
        if GS._AdmitPendingOrConflict then
            stPend, reasonPend = GS._AdmitPendingOrConflict(ops, stored, classReason or "stale_base")
        end
        -- Successful durable missing-predecessor / pending evidence must notify
        -- provider maintenance so peers can discover it without a later edit.
        if (stPend == "pending" or stPend == "duplicate")
            and not admissionCtx.adoptionReplay
            and GS._NotifyLocalDurableChange then
            if ops.pending and ops.pending[stored.id] then
                GS._NotifyLocalDurableChange("remote-evidence")
            end
        end
        return stPend, reasonPend
    end
    if class == "obsolete" then
        return "rejected", classReason or "stale_base"
    end
    if class == "conflict" then
        local headId = ops.heads and ops.heads[targetKey]
        if stored.kind == GS.KIND.START_CAMPAIGN then
            headId = ops.heads and ops.heads[GS.CAMPAIGN_TARGET_KEY]
        end
        if type(headId) == "string" then
            headId = UnderlyingConflictValueId(ops, headId) or headId
        end
        local candidates = {}
        if type(headId) == "string" then
            candidates[#candidates + 1] = headId
        end
        candidates[#candidates + 1] = stored.id
        local meta = nil
        if stored.kind == GS.KIND.START_CAMPAIGN and type(admissionCtx.boundary) == "table" then
            GS._pendingCampaignBoundaries[stored.id] = admissionCtx.boundary
            meta = { boundaries = { [stored.id] = admissionCtx.boundary } }
        end
        -- Adoption must reproduce the source accepted snapshot: buffer order
        -- cannot demote a source-accepted body into pending/conflict-only while
        -- an open conflict is still marked for resolution.
        local historicalAccepted = admissionCtx.adoptionReplay
            and type(admissionCtx.sourceAcceptedSet) == "table"
            and admissionCtx.sourceAcceptedSet[stored.id] == true
        if historicalAccepted then
            if not ops.records[stored.id] then
                if GS._AcceptedCount
                    and GS._AcceptedCount(ops) >= GS.MAX_ACCEPTED_OPERATIONS then
                    return "rejected", "full"
                end
                if GS._StoreAccepted then
                    -- nil targetKey: keep current head; resolve selects the winner.
                    GS._StoreAccepted(ops, stored, nil)
                end
            end
            local mok, merr = GS._MarkTargetConflict(
                ops, targetKey, candidates, stored.timestamp, meta)
            if not mok and merr == "full" then
                return "rejected", "full"
            end
            return "accepted", nil
        end
        if GS._AdmitPendingOrConflict then
            local st, reason = GS._AdmitPendingOrConflict(ops, stored, classReason or "divergent_edit")
            if st == "rejected" then
                -- Do not open a conflict slot referencing a body that was not retained.
                return st, reason
            end
            local mok, merr = GS._MarkTargetConflict(ops, targetKey, candidates, stored.timestamp, meta)
            if not mok and merr == "full" then
                if ops.pending then
                    ops.pending[stored.id] = nil
                end
                if ops.conflicts then
                    ops.conflicts[stored.id] = nil
                end
                return "rejected", "full"
            end
            if GS._NotifyLocalDurableChange and not admissionCtx.adoptionReplay
                and not (record and record._adoptionOffline) then
                GS._NotifyLocalDurableChange("remote-conflict")
            end
            return st, reason
        end
        local mok, merr = GS._MarkTargetConflict(ops, targetKey, candidates, stored.timestamp, meta)
        if not mok and merr == "full" then
            return "rejected", "full"
        end
        return "pending", classReason or "divergent_edit"
    end

    -- Apply path.
    if stored.kind == GS.KIND.SET_EDITOR_RANK then
        local rankOk, rankErr = ValidateEditorRankValue(stored.value)
        if not rankOk then
            return "rejected", rankErr or "invalid_editor_rank_position"
        end
    end
    if stored.kind == GS.KIND.START_CAMPAIGN then
        local boundary = admissionCtx.boundary or GS._pendingCampaignBoundaries[stored.id]
        local ok, err = ApplyRemoteCampaignMutation(record, stored, boundary)
        if not ok then
            if err == "missing_boundary" then
                if type(admissionCtx.boundary) == "table" then
                    GS._pendingCampaignBoundaries[stored.id] = admissionCtx.boundary
                end
                return "pending", err
            end
            return "rejected", err or "apply_failed"
        end
        GS._pendingCampaignBoundaries[stored.id] = nil
    else
        if GS._ApplyMutations then
            local ok, err = GS._ApplyMutations(record, stored)
            if not ok then
                if stored.kind == GS.KIND.ADJUST_QUANTITY
                    and (err == "item_negative" or err == "player_negative"
                        or err == "adjustment_floor") then
                    local stPend, reasonPend = "pending", err
                    if GS._AdmitPendingOrConflict then
                        stPend, reasonPend = GS._AdmitPendingOrConflict(ops, stored, err)
                    end
                    if (stPend == "pending" or stPend == "duplicate")
                        and not admissionCtx.adoptionReplay
                        and GS._NotifyLocalDurableChange then
                        GS._NotifyLocalDurableChange("remote-pending")
                    end
                    return stPend, reasonPend
                end
                return "rejected", err or "apply_failed"
            end
        end
        if GS._StoreAccepted then
            GS._StoreAccepted(ops, stored, targetKey)
        end
    end

    -- Predecessor-late: ordinary accepts must redrive pending confirmations.
    -- Adoption replay performs paced redrive once per slice (session-owned).
    if not admissionCtx.adoptionReplay then
        GS.RedriveExactContentConfirmations(record, admissionCtx)
    end
    -- Policy catch-up: accepting a predecessor redrives authenticated successors
    -- that arrived early into the untrusted relay cache (B-before-A).
    if stored.kind == GS.KIND.SET_EDITOR_RANK and not admissionCtx.adoptionReplay then
        local newPolicy = stored.id
        local relayIds = {}
        for rid, entry in pairs(GS._pendingRelay or {}) do
            local body = entry and entry.body
            if type(body) == "table" and body.kind == GS.KIND.SET_EDITOR_RANK
                and body.basePolicyRevision == newPolicy then
                relayIds[#relayIds + 1] = rid
            end
        end
        for i = 1, #relayIds do
            local rid = relayIds[i]
            local entry = GS._pendingRelay[rid]
            if type(entry) == "table" and type(entry.body) == "table" then
                -- Re-authenticate the retained successor's actual sender. Never
                -- inherit the predecessor admitter's member/credentials, and do
                -- not fall back to the predecessor's transport sender.
                local successorSender = entry.sender
                if type(successorSender) ~= "string" or successorSender == "" then
                    -- Keep the entry for a later authenticated redelivery.
                else
                    GS._pendingRelay[rid] = nil
                    GS:AdmitRemoteOperation(entry.body, {
                        sender = successorSender,
                        boundary = entry.boundary,
                        localWrite = false,
                    })
                end
            end
        end
    end
    local guildKey = member.guildKey or (record and record._guildKey)
    if guildKey then
        GS.ClearBootstrapEditLockIfCaughtUp(record, guildKey)
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
    if type(competingOpIds) ~= "table" or #competingOpIds < 1 then
        return nil, "rejected", "invalid_resolution"
    end
    -- Stamp shared candidate ancestry (not provisional local heads) so a
    -- resolution prepared on peer A admits on peer B whose head is the sibling.
    local sharedPolicy, sharedCampaign, sharedTarget
    local contentBodies = {}
    local ops = record.operations
    for i = 1, #competingOpIds do
        local cid = competingOpIds[i]
        local body = ops.records[cid]
            or (ops.pending[cid] and ops.pending[cid].body)
            or (ops.conflicts[cid] and ops.conflicts[cid].body)
        if type(body) ~= "table" then
            return nil, "rejected", "missing_predecessor"
        end
        local snapBody = body
        if GS._SnapshotPublicOp then
            snapBody = select(1, GS._SnapshotPublicOp(body)) or body
        end
        contentBodies[cid] = snapBody
        if i == 1 then
            sharedPolicy = body.basePolicyRevision
            sharedCampaign = body.baseCampaignId
            sharedTarget = body.baseTargetRevision
        else
            if body.basePolicyRevision ~= sharedPolicy
                or (body.baseCampaignId or nil) ~= (sharedCampaign or nil)
                or body.baseTargetRevision ~= sharedTarget then
                return nil, "rejected", "ancestry_mismatch"
            end
        end
    end
    local chosenListed = false
    for i = 1, #competingOpIds do
        if competingOpIds[i] == chosenOpId then
            chosenListed = true
            break
        end
    end
    if not chosenListed then
        return nil, "rejected", "invalid_resolution"
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
        campaignId = sharedCampaign,
        kind = GS.KIND.RESOLVE_CONFLICT,
        target = targetKey,
        value = {
            chosenOpId = chosenOpId,
            competingOpIds = competingOpIds,
            contentBodies = contentBodies,
        },
        actorGuid = ctx.actorGuid,
        actorName = ctx.actorName,
        timestamp = ts,
        baseTargetRevision = sharedTarget,
        basePolicyRevision = sharedPolicy,
        baseCampaignId = sharedCampaign,
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
        activation = caps and caps.activation or nil,
        cutoverMarker = caps and caps.cutoverMarker or nil,
        liveCutover = caps and caps.liveCutover or nil,
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
                    activation = entry.activation,
                    cutoverMarker = entry.cutoverMarker,
                    liveCutover = entry.liveCutover,
                }
            elseif editorOk and entry.datasetId == localId then
                out[#out + 1] = {
                    peerName = entry.peerName,
                    datasetId = entry.datasetId,
                    sameAsLocal = true,
                    editorVerified = true,
                    activation = entry.activation,
                    cutoverMarker = entry.cutoverMarker,
                    liveCutover = entry.liveCutover,
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
