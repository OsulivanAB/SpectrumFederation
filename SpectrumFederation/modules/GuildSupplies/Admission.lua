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
GS.MAX_ARCHIVE_PAGE_BUFFER_PAGES = 64
---------------------------------------------------------------------------
-- Concrete transfer / work limits derived from existing supported maxima.
-- Wrapper-inclusive wire budget equals Guild Gossip MAX_RECORD_CBOR (2048).
-- Ask the owner only if supporting these maxima needs a product scope change.
---------------------------------------------------------------------------
GS.MAX_WIRE_RECORD_BYTES = 2048
-- Campaign archive pages: ceil(MAX_REQUESTED_ITEMS / ARCHIVE_PAGE_ITEMS).
-- MAX_REQUESTED_ITEMS defaults to 256; ARCHIVE_PAGE_ITEMS is 12 in Gossip.lua.
GS.MAX_ARCHIVE_PAGE_COUNT = 22
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
-- Logical adoption buffer: accepted/evidence history + campaigns/archives + headroom.
-- Wire pages for incomplete paged manifests live in a separate assembly arena so
-- interleaved pages-first delivery cannot fill this ceiling before shells arrive.
GS.MAX_ADOPTION_PENDING_RECORDS = (GS.MAX_ACCEPTED_OPERATIONS or 4096)
    + ((GS.MAX_CAMPAIGNS or 64) * 24)
    + 512
-- Concurrent incomplete paged-op assemblies during transfer (not logical history).
GS.MAX_ADOPTION_ASSEMBLY_OPS = 24
GS.MAX_ADOPTION_ASSEMBLY_PAGES = (GS.MAX_MANIFEST_PAGES or 64) * (GS.MAX_ADOPTION_ASSEMBLY_OPS or 24)
-- Assembled fragment byte budget matches snapshot string budget.
GS.MAX_FRAGMENT_ASSEMBLY_BYTES = GS.MAX_SNAPSHOT_STRING_BYTES or 49152
GS.MAX_FRAGMENT_BUFFER_ASSEMBLIES = GS.MAX_ARCHIVE_PAGE_BUFFER_CAMPAIGNS or 16
-- Buffer must retain a full paged confirm/resolve (body pages + id-list pages).
GS.MAX_FRAGMENT_BUFFER_PAGES = math.max(
    GS.MAX_ARCHIVE_PAGE_BUFFER_PAGES or 64,
    GS.MAX_MANIFEST_PAGES or 64
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
-- Confirmation redrive cursor across scheduled slices.
GS._confirmationRedrivePos = 1
GS._confirmationRedriveScheduled = false

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

    if type(record) ~= "table" or record.activation ~= GS.ACTIVATION_STAGED then
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
            GS._pendingRelay[id] = nil
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
        -- Capacity recovery: drop oldest untrusted entry, then retry slot.
        if oldestId then
            GS._pendingRelay[oldestId] = nil
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

local function NotifyAdoptionStateChanged(reason)
    if GS.OnAdoptionStateChanged then
        pcall(GS.OnAdoptionStateChanged, reason)
    end
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

    local record = {
        schemaVersion = GS.SCHEMA_VERSION,
        activation = GS.ACTIVATION_STAGED,
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
    DebugInfo("installed remote staged dataset key=%s dataset=%s from=%s",
        guildKey, descriptor.datasetId, tostring(member.name))
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

local function CountBufferedKinds(adop)
    -- acceptedOps: non-evidenceOnly gs-op bodies (selected accepted history).
    -- transferOps: all gs-op bodies including conflict/pending evidence.
    -- Incomplete paged manifests live in adop._assemblies until finalized.
    local acceptedOps, transferOps, headers, archives, desc = 0, 0, 0, 0, nil
    local archivePages = {} -- campaignId → { meta, pages = {}, pageCount }
    local opPages = {} -- opId → { shell, pages = {}, pageCount }
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
                local cid = body.campaignId
                if type(cid) == "string" then
                    archivePages[cid] = archivePages[cid] or { pages = {}, pageCount = tonumber(body.pageCount) or 1 }
                    archivePages[cid].meta = body
                    archivePages[cid].pageCount = tonumber(body.pageCount) or 1
                end
            elseif body.kind == "campaign-archive-page" then
                local cid = body.campaignId
                if type(cid) == "string" then
                    archivePages[cid] = archivePages[cid] or { pages = {}, pageCount = tonumber(body.pageCount) or 1 }
                    archivePages[cid].pages[tonumber(body.page) or 0] = body
                    if tonumber(body.pageCount) then
                        archivePages[cid].pageCount = tonumber(body.pageCount)
                    end
                end
            end
        end
    end
    if type(adop._archiveIndex) == "table" then
        for cid, info in pairs(adop._archiveIndex) do
            archivePages[cid] = archivePages[cid] or { pages = {}, pageCount = info.pageCount or 1 }
            if info.meta then
                archivePages[cid].meta = info.meta
            end
            if type(info.pages) == "table" then
                for p, pb in pairs(info.pages) do
                    archivePages[cid].pages[p] = pb
                end
            end
            if info.pageCount then
                archivePages[cid].pageCount = info.pageCount
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
    return desc, acceptedOps, transferOps, headers, archives, archivePages, opPages
end

--- Assemble paged archive bodies into a single canonical archive table.
local function AssemblePagedArchive(meta, pagesByIndex)
    if type(meta) ~= "table" then
        return nil, "invalid_campaign_archive"
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
        }, nil
    end
    local pageCount = tonumber(meta.pageCount) or 1
    local merged = {}
    local got = 0
    for page = 1, pageCount do
        local p = pagesByIndex and pagesByIndex[page]
        if type(p) ~= "table" or type(p.requestedItems) ~= "table" then
            return nil, "incomplete_archive_pages"
        end
        for k, v in pairs(p.requestedItems) do
            merged[k] = v
            got = got + 1
        end
    end
    -- Page presence already checked; count mismatch is malformed input, not "wait".
    if type(meta.itemCount) == "number" and got ~= meta.itemCount then
        return nil, "invalid_campaign_archive"
    end
    return {
        schemaVersion = meta.schemaVersion or GS.SCHEMA_VERSION,
        campaignId = meta.campaignId,
        datasetId = meta.datasetId,
        requestedItems = merged,
        generation = meta.generation,
        archivedAt = meta.archivedAt,
    }, nil
end

--- True when buffered records match the authenticated source descriptor contract.
function GS:IsAdoptionTransferComplete()
    local adop = GS._adoption
    if type(adop) ~= "table" or adop.committed then
        return false, "no_adoption"
    end
    local desc, acceptedOps, transferOps, headers, archives, archivePages, opPages =
        CountBufferedKinds(adop)
    if not desc then
        return false, "incomplete_transfer"
    end
    -- Descriptor counts must be present and exact (no silent zero-default extras).
    -- acceptedOpCount = accepted history; transferOpCount = accepted + evidenceOnly.
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
    if not expectAccepted or not expectTransfer or not expectHeaders or not expectArchives
        or expectAccepted ~= math.floor(expectAccepted) or expectAccepted < 0
        or expectTransfer ~= math.floor(expectTransfer) or expectTransfer < 0
        or expectTransfer < expectAccepted
        or expectHeaders ~= math.floor(expectHeaders) or expectHeaders < 0
        or expectArchives ~= math.floor(expectArchives) or expectArchives < 0 then
        return false, "incomplete_transfer"
    end
    if acceptedOps ~= expectAccepted or transferOps ~= expectTransfer
        or headers ~= expectHeaders or archives ~= expectArchives then
        return false, "incomplete_transfer"
    end
    -- Exact accepted snapshot size must match descriptor (evidenceOnly excluded).
    if adop.pinnedAcceptedOpCount ~= nil and adop.pinnedAcceptedOpCount ~= expectAccepted then
        return false, "source_changed"
    end
    if adop.pinnedTransferOpCount ~= nil and adop.pinnedTransferOpCount ~= expectTransfer then
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
        }
    end
    adop.replayTemp = nil
    adop.replayState = nil
    adop.replayMember = nil
    adop._replaySessionRelay = nil
    adop._replaySessionBoundaries = nil
    adop._replayScheduled = false
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
    if localRecord and localRecord.datasetId == sourceDatasetId then
        return nil, "rejected", "same_dataset"
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
    local previous = GS._adoption
        if type(previous) == "table" then
        AbortAdoptionReplay(previous, "replaced")
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
        _workStats = {
            confirmVisited = 0,
            confirmComparisons = 0,
            completenessVisited = 0,
            indexVisited = 0,
            assemblyVisited = 0,
            archiveVisited = 0,
        },
        -- Exact source accepted snapshot (non-evidenceOnly gs-op ids) pinned during transfer.
        sourceAcceptedIds = {},
        sourceAcceptedSet = {},
        pinnedPermissionRevisionId = nil,
        pinnedAcceptedOpCount = nil,
        pinnedTransferOpCount = nil,
        pinnedCampaignCount = nil,
        pinnedArchiveCount = nil,
        startedAt = GetServerTime and GetServerTime() or nil,
        committed = false,
        ready = false,
    }
    DebugInfo("began dataset adoption source=%s dataset=%s", member.name, sourceDatasetId)
    if previous ~= GS._adoption then
        NotifyAdoptionStateChanged("begin")
    end
    return GS._adoption, "accepted", nil
end

function GS:CancelDatasetAdoption()
    if GS._adoption then
        DebugInfo("cancelled dataset adoption dataset=%s", tostring(GS._adoption.sourceDatasetId))
        AbortAdoptionReplay(GS._adoption, "cancel")
        GS._adoption = nil
        NotifyAdoptionStateChanged("cancel")
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

-- When arena capacity frees, reopen engine unresolved obligations for this
-- provider and clear scoped pull backoff so suppressed assembly_full revisions
-- can be re-enumerated promptly. Reopen is synchronous (idempotent). The
-- meaningful-change notification is coalesced to once per apply burst via
-- FlushAdoptionAssemblyRecovery (and After(0) as a safety net). Uses existing
-- GG.ReopenUnresolvedEnumeration + GG.NotifyMeaningfulChange (not polling, not
-- global TTL shortening, not NotifyProviderChanged index rebuild).
local _assemblyRecoveryNotifyPending = false
local _assemblyRecoveryNotifyScheduled = false
local function FlushAdoptionAssemblyRecovery()
    if not _assemblyRecoveryNotifyPending then
        return
    end
    _assemblyRecoveryNotifyPending = false
    _assemblyRecoveryNotifyScheduled = false
    local live = GS._adoption
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

local function ScheduleAdoptionAssemblyRecovery()
    if type(GS.PROVIDER_ID) ~= "string" then
        return
    end
    local adop = GS._adoption
    if type(adop) == "table" and adop.committed then
        return
    end
    if type(GS._onAssemblyRecovery) == "function" then
        pcall(GS._onAssemblyRecovery)
    end
    local gossip = SF.GuildGossip
    if type(gossip) == "table" and type(gossip.ReopenUnresolvedEnumeration) == "function" then
        gossip.ReopenUnresolvedEnumeration(GS.PROVIDER_ID)
    end
    _assemblyRecoveryNotifyPending = true
    if _assemblyRecoveryNotifyScheduled then
        return
    end
    _assemblyRecoveryNotifyScheduled = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0, FlushAdoptionAssemblyRecovery)
    else
        FlushAdoptionAssemblyRecovery()
    end
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
    adop._assembledByOpId = adop._assembledByOpId or {}
    local rid = adop._assembledByOpId[opId]
    if type(rid) == "string" and type(adop.records[rid]) == "table" then
        return rid, adop.records[rid]
    end
    for i = 1, #(adop.order or {}) do
        local id = adop.order[i]
        local body = adop.records[id]
        if type(body) == "table" and body.kind == "gs-op" and type(body.op) == "table"
            and body.op.id == opId
            and not tonumber(body.pageCount)
            and not (body.op and tonumber(body.op.pageCount)) then
            adop._assembledByOpId[opId] = id
            return id, body
        end
    end
    return nil, nil
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
    adop._assembledByOpId = adop._assembledByOpId or {}
    adop._assembledByOpId[opId] = logicalId
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
    adop._redeliveryAssemblies = adop._redeliveryAssemblies or {}
    local asm = adop._redeliveryAssemblies[opId]
    if not asm then
        asm = { pages = {}, pageCount = pageCount, _countsTowardArena = false }
        adop._redeliveryAssemblies[opId] = asm
    end
    if pageCount and (not asm.pageCount or asm.pageCount < pageCount) then
        asm.pageCount = pageCount
    end
    if isShell then
        if asm.shell and not DeepEqual(asm.shell, body) then
            return "rejected", "id_conflict"
        end
        asm.shell = body
        asm.shellRecordId = recordId
    else
        local p = tonumber(body.page) or 0
        if p < 1 then
            return "rejected", "invalid_record"
        end
        if asm.pages[p] then
            if DeepEqual(asm.pages[p], body) then
                local complete = select(1, GS:IsAdoptionTransferComplete())
                return complete and "accepted" or "duplicate", complete and "ready" or "duplicate"
            end
            return "rejected", "id_conflict"
        end
        asm.pages[p] = body
        if tonumber(body.pageCount) then
            asm.pageCount = asm.pageCount or tonumber(body.pageCount)
        end
    end
    local ok, detail = FinalizeAdoptionAssembly(adop, opId)
    local complete = select(1, GS:IsAdoptionTransferComplete())
    adop.ready = complete and true or false
    if complete then
        NotifyAdoptionStateChanged("ready")
    end
    if ok and detail == "duplicate" then
        return complete and "accepted" or "duplicate", complete and "ready" or "duplicate"
    end
    if not ok and detail == "id_conflict" then
        return "rejected", "id_conflict"
    end
    if ok then
        -- Unexpected: finalized a new logical row for an already-assembled opId.
        return "accepted", complete and "ready" or nil
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
    local opId, pageCount
    local isShell = body.kind == "gs-op"
    if isShell then
        if type(body.op) ~= "table" or type(body.op.id) ~= "string" then
            return finish("rejected", "invalid_record")
        end
        opId = body.op.id
        pageCount = tonumber(body.pageCount) or tonumber(body.op.pageCount)
        if not pageCount or pageCount < 1 then
            return nil -- not a paged shell; caller handles as logical
        end
    else
        opId = body.opId
        pageCount = tonumber(body.pageCount)
        if type(opId) ~= "string" then
            return finish("rejected", "invalid_record")
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
    end
    if pageCount and (not asm.pageCount or asm.pageCount < pageCount) then
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
        local p = tonumber(body.page) or 0
        if p < 1 then
            return finish("rejected", "invalid_record")
        end
        if asm.pages[p] then
            if DeepEqual(asm.pages[p], body) then
                local complete = select(1, GS:IsAdoptionTransferComplete())
                return finish(
                    complete and "accepted" or "duplicate",
                    complete and "ready" or "duplicate")
            end
            return finish("rejected", "id_conflict")
        end
        if adop._assemblyPageCount >= (GS.MAX_ADOPTION_ASSEMBLY_PAGES or 0) then
            return finish("pending", "assembly_full")
        end
        asm.pages[p] = body
        adop._assemblyPageCount = adop._assemblyPageCount + 1
        if tonumber(body.pageCount) then
            asm.pageCount = asm.pageCount or tonumber(body.pageCount)
        end
    end
    local finalized, finDetail = FinalizeAdoptionAssembly(adop, opId)
    local complete = select(1, GS:IsAdoptionTransferComplete())
    adop.ready = complete and true or false
    if complete then
        NotifyAdoptionStateChanged("ready")
    end
    if finalized and finDetail == "duplicate" then
        return finish(
            complete and "accepted" or "duplicate",
            complete and "ready" or "duplicate")
    end
    if not finalized and finDetail == "id_conflict" then
        return finish("rejected", "id_conflict")
    end
    if finalized then
        return finish("accepted", complete and "ready" or nil)
    end
    return finish("accepted", complete and "ready" or nil)
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
        local pc = tonumber(body.pageCount) or tonumber(body.op.pageCount)
        if pc and pc >= 1 then
            return BufferAdoptionAssembly(adop, recordId, body)
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
            return "rejected", "source_changed"
        end
        local rev = descBody.permissionRevisionId
        local count = tonumber(descBody.acceptedOpCount)
        local transfer = tonumber(descBody.transferOpCount)
        local camp = tonumber(descBody.campaignCount)
        local arch = tonumber(descBody.archiveCount)
        if adop.pinnedPermissionRevisionId == nil and type(rev) == "string" then
            adop.pinnedPermissionRevisionId = rev
        elseif type(rev) == "string" and adop.pinnedPermissionRevisionId ~= nil
            and rev ~= adop.pinnedPermissionRevisionId then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            return "rejected", "source_changed"
        end
        if adop.pinnedAcceptedOpCount == nil and count ~= nil then
            adop.pinnedAcceptedOpCount = count
        elseif count ~= nil and adop.pinnedAcceptedOpCount ~= nil
            and count ~= adop.pinnedAcceptedOpCount then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            return "rejected", "source_changed"
        end
        if adop.pinnedTransferOpCount == nil and transfer ~= nil then
            adop.pinnedTransferOpCount = transfer
        elseif transfer ~= nil and adop.pinnedTransferOpCount ~= nil
            and transfer ~= adop.pinnedTransferOpCount then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            return "rejected", "source_changed"
        end
        if adop.pinnedCampaignCount == nil and camp ~= nil then
            adop.pinnedCampaignCount = camp
        elseif camp ~= nil and adop.pinnedCampaignCount ~= nil and camp ~= adop.pinnedCampaignCount then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            return "rejected", "source_changed"
        end
        if adop.pinnedArchiveCount == nil and arch ~= nil then
            adop.pinnedArchiveCount = arch
        elseif arch ~= nil and adop.pinnedArchiveCount ~= nil and arch ~= adop.pinnedArchiveCount then
            GS._adoption = nil
            NotifyAdoptionStateChanged("source_changed")
            return "rejected", "source_changed"
        end
        return nil
    end

    -- Assembly duplicate/conflict check for ids still parked in the arena.
    if adop._assemblies then
        for oid, asm in pairs(adop._assemblies) do
            if asm.shellRecordId == recordId then
                if DeepEqual(asm.shell, body) then
                    local complete = select(1, GS:IsAdoptionTransferComplete())
                    return complete and "accepted" or "duplicate", complete and "ready" or "duplicate"
                end
                return "rejected", "id_conflict"
            end
        end
    end

    if adop.records[recordId] then
        if DeepEqual(adop.records[recordId], body) then
            local complete = select(1, GS:IsAdoptionTransferComplete())
            return complete and "accepted" or "duplicate", complete and "ready" or "duplicate"
        end
        if body.kind == "dataset-desc" and adop.records[recordId].kind == "dataset-desc" then
            local invSt, invReason = InvalidatePinnedDescriptor(body)
            if invSt then
                return invSt, invReason
            end
            -- Same pinned fields: replace descriptor content in place.
            adop.records[recordId] = body
            local complete = select(1, GS:IsAdoptionTransferComplete())
            adop.ready = complete and true or false
            return "accepted", complete and "ready" or "updated"
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
    if body.kind == "campaign-archive" and type(body.campaignId) == "string" then
        adop._archiveIndex = adop._archiveIndex or {}
        adop._archiveIndex[body.campaignId] = adop._archiveIndex[body.campaignId]
            or { meta = nil, pages = {} }
        adop._archiveIndex[body.campaignId].meta = body
        adop._archiveIndex[body.campaignId].pageCount = tonumber(body.pageCount) or 1
    elseif body.kind == "campaign-archive-page" and type(body.campaignId) == "string" then
        adop._archiveIndex = adop._archiveIndex or {}
        local info = adop._archiveIndex[body.campaignId]
            or { meta = nil, pages = {} }
        info.pages[tonumber(body.page) or 0] = body
        if tonumber(body.pageCount) then
            info.pageCount = tonumber(body.pageCount)
        end
        adop._archiveIndex[body.campaignId] = info
    end

    local wasReady = adop.ready == true
    adop.records[recordId] = body
    adop.order[#adop.order + 1] = recordId
    local complete = select(1, GS:IsAdoptionTransferComplete())
    adop.ready = complete and true or false
    if adop.ready and not wasReady then
        NotifyAdoptionStateChanged("ready")
    end
    return "accepted", complete and "ready" or nil
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

    -- Policy-deferral scan: O(buffer) once per policy epoch. Charged as a single
    -- unit so it cannot consume the entire admit budget after every progress.
    local deferRank = state.deferRankCached
    local policyNow = temp.permission and temp.permission.revisionId or temp.datasetId
    if deferRank == nil or state.deferRankPolicy ~= policyNow then
        sliceUsed = sliceUsed + 1
        local found = false
        for scanAt = 1, #adop.order do
            local b = adop.records[adop.order[scanAt]]
            if type(b) == "table" and b.kind == "gs-op" and type(b.op) == "table" then
                local o = b.op
                -- Defer rank only while same-policy config mutations remain. Campaign
                -- starts are not rank-gated and must not sticky-defer SET_EDITOR_RANK.
                if o.kind ~= GS.KIND.SET_EDITOR_RANK
                    and o.kind ~= GS.KIND.CONFIRM_CANDIDATE
                    and o.kind ~= GS.KIND.RESOLVE_CONFLICT
                    and o.kind ~= GS.KIND.START_CAMPAIGN
                    and not (temp.operations.records and temp.operations.records[o.id])
                    and not (temp.operations.conflicts and temp.operations.conflicts[o.id]) then
                    if o.basePolicyRevision == policyNow
                        or o.basePolicyRevision == temp.datasetId then
                        local src = ActorMatchesMember(o, member)
                        local conf = false
                        if not src then
                            conf = AdoptionHasConfirmationFor(
                                adop, o.id, o, member, temp.operations,
                                { budget = math.max(1, sliceBudget - sliceUsed) })
                        end
                        if src or conf then
                            found = true
                            break
                        end
                    end
                end
            end
        end
        deferRank = found
        state.deferRankCached = found
        state.deferRankPolicy = policyNow
        state.deferRankScan = nil
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
                    local searchOpts = {
                        budget = math.max(1, sliceBudget - sliceUsed),
                        cursor = state.confirmCursor and state.confirmCursor[op.id] or nil,
                    }
                    confirmed = AdoptionHasConfirmationFor(
                        adop, op.id, op, member, temp.operations, searchOpts)
                    if searchOpts.budgetExhausted then
                        state.confirmCursor = state.confirmCursor or {}
                        state.confirmCursor[op.id] = searchOpts.cursor
                        -- Charge visited work; resume next slice.
                        sliceUsed = sliceBudget
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
                    -- Account confirmation visits toward the slice budget.
                    local v = tonumber(searchOpts.visited) or 0
                    if v > 1 then
                        sliceUsed = sliceUsed + (v - 1)
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
                    adop._headerByCampaignId = adop._headerByCampaignId or {}
                    adop._headerByCampaignId[h.campaignId] = h
                    GS._pendingCampaignBoundaries[h.campaignId] = h
                    if startPresent then
                        temp.campaigns[h.campaignId] = h
                    end
                    progress = true
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
                elseif not DeepEqual(temp.campaignArchives[body.campaignId], archive) then
                    state.cursor, state.admissions = i, admissions
                    return false, "archive_conflict", progress
                else
                    if state.archiveNeedsPages then
                        state.archiveNeedsPages[body.campaignId] = nil
                    end
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

    -- Confirmation redrive counts toward the slice (uses cached deferRank).
    if sliceUsed < sliceBudget then
        GS.RedriveExactContentConfirmations(temp, {
            adoptionReplay = true,
            offlineRecord = temp,
            sender = adop.sourcePeer,
            member = member,
            deferRank = deferRank,
        })
        sliceUsed = sliceUsed + 1
        admissions = admissions + 1
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
        -- Worklist waits are not stalls. Budget-exhausted retry slices are still
        -- productive work and must not accumulate toward the noProgress abort.
        local hasWorklist = false
        if type(state.worklist) == "table" then
            for _ in pairs(state.worklist) do
                hasWorklist = true
                break
            end
        end
        local budgetExhausted = sliceUsed >= sliceBudget
        if not hasWorklist and not budgetExhausted then
            state.noProgressSlices = (tonumber(state.noProgressSlices) or 0) + 1
        end
    end

    state.admissions = (tonumber(state.admissions) or 0) + admissions
    state.sliceUsed = sliceUsed
    state.cursor = i
    local budgetHit = sliceUsed >= sliceBudget
    local moreWork = progress or budgetHit or (state.deferRankScan ~= nil)
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
                if not DeepEqual(temp.campaignArchives[body.campaignId], archive) then
                    opts.cursor = nil
                    publishCompletenessStats()
                    return false, "archive_conflict"
                end
            end
        end
    end
    opts.cursor = nil
    opts.budgetExhausted = false
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
        if adop.localDatasetId and live.datasetId ~= adop.localDatasetId then
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
    local compOpts = state.completenessOpts or {
        budget = compBudget,
        cursor = 1,
    }
    compOpts.budget = compBudget
    local okComp, compErr
    local guard = 0
    local maxGuard = math.max(8, math.ceil((#adop.order or 0) / compBudget) * 2 + 8)
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
    if GS._NotifyLocalDurableChange then
        GS._NotifyLocalDurableChange("adoption")
    end
    NotifyAdoptionStateChanged("commit")
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
    local compOpts = state.completenessOpts or {
        budget = compBudget,
        cursor = 1,
    }
    compOpts.budget = compBudget
    local okComp, compErr = ValidateAdoptionCompleteness(temp, adop, member, compOpts)
    if not okComp and compErr == "budget" then
        state.completenessOpts = compOpts
        if GS._adoptionReplaySyncDrain then
            local guard = 0
            local maxGuard = math.max(8, math.ceil((#adop.order or 0) / compBudget) * 2 + 8)
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
    if type(opts.offlineRecord) == "table" then
        if opts.offlineRecord.activation ~= GS.ACTIVATION_STAGED then
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
    if raw.activation ~= GS.ACTIVATION_STAGED then
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
    if type(ops.pending) == "table" then
        for id, entry in pairs(ops.pending) do
            local op = entry and entry.body
            if IsChosenConfigMutation(op) and not (ops.records and ops.records[op.id]) then
                if RecordHasConfirmationFor(record, op.id, op) then
                    local authBody = op
                    if type(ops.order) == "table" then
                        for j = 1, #ops.order do
                            local embedded = AuthoritativeBodyFromEnvelope(
                                ops.records[ops.order[j]], id)
                            if type(embedded) == "table" then
                                authBody = embedded
                                break
                            end
                        end
                    end
                    promoteOps[#promoteOps + 1] = authBody
                end
            end
        end
    end
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
                -- Restore original pending reason when known.
                local prior = previousPending[pid]
                if ops.pending then
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

    for i = 1, #(plan.promoteOps or {}) do
        local pop = plan.promoteOps[i]
        local targetKey = GS._TargetKey and GS._TargetKey(pop.kind, pop.target)
        if GS._StoreAccepted then
            GS._StoreAccepted(ops, pop, targetKey)
            promotedIds[#promotedIds + 1] = pop.id
        end
        if ops.pending then
            ops.pending[pop.id] = nil
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
    if GS._AcceptedCount and GS._AcceptedCount(ops) >= GS.MAX_ACCEPTED_OPERATIONS then
        return "rejected", "full"
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

--- Shared exact-content confirmation apply: promote matching retained candidates.
-- Preserves original attribution; does not synthesize approvals.
-- During adoptionReplay, SET_EDITOR_RANK promotions are deferred while same-base
-- acceptable non-rank history remains unsettled (matches direct rank Admit gate).
function GS.ApplyExactContentConfirmation(record, storedConfirm, admissionCtx)
    admissionCtx = admissionCtx or {}
    if type(record) ~= "table" or type(storedConfirm) ~= "table" then
        return false, "invalid_operation"
    end
    -- Bind retained candidates to authoritative bodies embedded in the
    -- authenticated confirmation envelope. Fingerprint equality is never sufficient.
    local ids = {}
    local ref = storedConfirm.candidateRef
    if type(ref) == "table" then
        if type(ref.recordId) == "string" then
            ids[1] = ref.recordId
        end
        if type(ref.records) == "table" then
            for i = 1, #ref.records do
                local row = ref.records[i]
                if type(row) == "table" and type(row.id) == "string" then
                    ids[#ids + 1] = row.id
                end
            end
        end
        if type(ref.originalIds) == "table" then
            for i = 1, #ref.originalIds do
                if type(ref.originalIds[i]) == "string" then
                    ids[#ids + 1] = ref.originalIds[i]
                end
            end
        end
    end
    local seen = {}
    for i = 1, #ids do
        local rid = ids[i]
        if type(rid) == "string" and not seen[rid] then
            seen[rid] = true
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
                        GS._pendingRelay[rid] = nil
                        if GS._pendingCampaignBoundaries then
                            GS._pendingCampaignBoundaries[rid] = nil
                        end
                        if source == "pending" and record.operations.pending then
                            record.operations.pending[rid] = nil
                        end
                    elseif st == "pending" then
                        -- Keep unfinished siblings; confirmation envelope still accepted.
                    else
                        DebugWarn("confirm apply skipped id=%s status=%s reason=%s",
                            rid, tostring(st), tostring(reason))
                    end
                end
                end -- deferRank else
            end
        end
    end
    return true
end

--- Re-apply accepted confirmation envelopes against newly retained candidates
-- (confirm-first / predecessor-late). Scans the full confirmationRefs list using
-- a bounded per-call slice so correctness is not truncated at index 32.
-- When more refs remain after a live slice, schedules a continuation so a
-- relevant confirmation beyond the first slice still applies without traffic.
function GS.RedriveExactContentConfirmations(record, admissionCtx)
    if type(record) ~= "table" or type(record.confirmationRefs) ~= "table" then
        return
    end
    local ops = record.operations
    if type(ops) ~= "table" or type(ops.records) ~= "table" then
        return
    end
    local total = #record.confirmationRefs
    if total < 1 then
        return
    end
    local slice = GS.MAX_CONFIRMATION_REDRIVE_PER_SLICE or 32
    -- During adoption replay, drain the full list in this call (offline).
    if admissionCtx and admissionCtx.adoptionReplay then
        slice = total
    end
    local start = tonumber(GS._confirmationRedrivePos) or 1
    if start > total then
        start = 1
    end
    local processed = 0
    local i = start
    while processed < slice and processed < total do
        local cid = record.confirmationRefs[i]
        local conf = ops.records[cid]
        if type(conf) == "table" and conf.kind == GS.KIND.CONFIRM_CANDIDATE then
            GS.ApplyExactContentConfirmation(record, conf, admissionCtx or {})
        end
        processed = processed + 1
        i = i + 1
        if i > total then
            i = 1
        end
    end
    GS._confirmationRedrivePos = i
    -- Live path: guarantee continuation until one full pass over confirmationRefs
    -- completes. Do not reschedule forever — drain remaining then clear.
    if not (admissionCtx and admissionCtx.adoptionReplay) and total > slice then
        local remaining = tonumber(GS._confirmationRedriveRemaining)
        if remaining == nil then
            remaining = total
        end
        remaining = math.max(0, remaining - processed)
        GS._confirmationRedriveRemaining = remaining
        if remaining > 0 and not GS._confirmationRedriveScheduled then
            GS._confirmationRedriveScheduled = true
            local function continueRedrive()
                GS._confirmationRedriveScheduled = false
                if type(record) == "table" and type(record.confirmationRefs) == "table"
                    and #record.confirmationRefs > 0
                    and (tonumber(GS._confirmationRedriveRemaining) or 0) > 0 then
                    GS.RedriveExactContentConfirmations(record, admissionCtx or {})
                else
                    GS._confirmationRedriveRemaining = nil
                end
            end
            if C_Timer and C_Timer.After then
                C_Timer.After(0, continueRedrive)
            else
                -- Harness without C_Timer: continue synchronously so correctness
                -- does not depend on manually invoking redrive.
                continueRedrive()
            end
        elseif remaining <= 0 then
            GS._confirmationRedriveRemaining = nil
        end
    end
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
    local editorOk, editorReason = GS.SenderHasEditorAuthority(member, {
        requireRecoverPolicy = requireRecover,
        allowPolicyCatchUp = isPolicyCatchUp,
    })

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
        GS.RedriveExactContentConfirmations(record, admissionCtx)
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
                GS.RedriveExactContentConfirmations(record, admissionCtx)
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
        GS.ApplyExactContentConfirmation(record, stored, admissionCtx)
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
                return "rejected", err or "apply_failed"
            end
        end
        if GS._StoreAccepted then
            GS._StoreAccepted(ops, stored, targetKey)
        end
    end

    -- Predecessor-late: ordinary accepts must redrive pending confirmations.
    GS.RedriveExactContentConfirmations(record, admissionCtx)
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
