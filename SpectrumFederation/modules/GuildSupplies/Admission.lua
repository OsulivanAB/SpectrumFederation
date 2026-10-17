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
-- Must fit a full legal accepted export (ops) plus descriptor/headers/archives.
GS.MAX_ADOPTION_PENDING_RECORDS = (GS.MAX_ACCEPTED_OPERATIONS or 4096) + 256
-- Abandoned adoption sessions expire so they cannot suppress peer traffic forever.
GS.MAX_ADOPTION_SECONDS = 600
-- Adoption replay wave bound is derived from buffered body count (dependency
-- frontier), not a fixed depth that silently truncates legal history.
GS.MAX_ADOPTION_REPLAY_PASSES = nil -- unused; see ReplayAdoptionIntoTemp
-- Bounded untrusted historical relay retention (runtime-only).
GS.MAX_PENDING_RELAY = 64
-- Per-commit confirmation redrive slice (full refs scanned across slices).
GS.MAX_CONFIRMATION_REDRIVE_PER_SLICE = 32

-- Runtime-only: adoption / peer discovery / epoch. Not SavedVariables.
GS._adoptionEpoch = 0
GS._adoption = nil -- pending adoption session
GS._peerDatasets = {} -- [normalizedPeer] = { datasetId, peerName, at, editor = bool }
GS._pendingRelay = {} -- [recordId] = { body, sender, at, fingerprint, boundary? }
-- Pending campaign boundaries retained with conflicting start-campaign candidates.
GS._pendingCampaignBoundaries = {} -- [opId] = header
-- After descriptor-first install: block local edits until advertised policy lands.
GS._bootstrapEditLock = {} -- [guildKey] = advertisedPermissionRevisionId
-- Confirmation redrive cursor across scheduled slices.
GS._confirmationRedrivePos = 1

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

--- Authority-binding content digest. Uses existing Hash32 over the full
-- canonical serialization in fixed-size windows so distinct bodies do not
-- share a single 32-bit advisory collision as approval authority. Index/advisory
-- hashes elsewhere remain separate. Folded to fit MAX_OPERATION_ID.
local function ContentFingerprint(body)
    local gossip = GG()
    if not (gossip and gossip.Hash32) then
        -- Fail closed for authority binding: never fall back to id-only.
        return nil
    end
    local canon = table.concat(CanonicalContentParts(body))
    local digests = {}
    digests[#digests + 1] = string.format("%08x", gossip.Hash32("len:" .. tostring(#canon)))
    local win = 256
    if #canon == 0 then
        digests[#digests + 1] = string.format("%08x", gossip.Hash32(""))
    else
        for i = 1, #canon, win do
            local chunk = canon:sub(i, i + win - 1)
            digests[#digests + 1] = string.format("%08x", gossip.Hash32(chunk))
        end
    end
    -- Mix full-string hash last so prefix-identical bodies still diverge.
    digests[#digests + 1] = string.format("%08x", gossip.Hash32(canon))
    -- Fold until the fingerprint fits confirmation/id field budgets.
    local maxLen = GS.MAX_OPERATION_ID or 192
    while #digests > 1 and (#digests * 8) > maxLen do
        local a = table.remove(digests, 1)
        local b = table.remove(digests, 1)
        table.insert(digests, 1, string.format("%08x", gossip.Hash32(a .. b)))
    end
    return table.concat(digests, "")
end

GS.ContentFingerprint = ContentFingerprint

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

--- Retain an untrusted historical candidate under a hard bound.
-- Validates/snapshots before consuming a retention slot so malformed bodies
-- cannot exhaust capacity.
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
    local n = 0
    for _ in pairs(GS._pendingRelay) do
        n = n + 1
        if n >= (GS.MAX_PENDING_RELAY or 64) then
            return false, "full"
        end
    end
    GS._pendingRelay[recordId] = {
        body = snap,
        sender = entry.sender,
        at = entry.at,
        fingerprint = fp,
        boundary = entry.boundary,
    }
    return true
end

--- True when buffered adoption transfer includes source-authenticated exact-content
-- confirmation or a source-authored resolution that chooses this operation id.
-- Selecting an adoption source alone does not confirm unknown authors.
local function AdoptionHasConfirmationFor(adop, opId, fingerprint)
    if type(adop) ~= "table" or type(opId) ~= "string" then
        return false
    end
    for i = 1, #adop.order do
        local body = adop.records[adop.order[i]]
        if type(body) == "table" and body.kind == "gs-op" and type(body.op) == "table" then
            local op = body.op
            if op.kind == GS.KIND.CONFIRM_CANDIDATE then
                local ref = op.candidateRef
                if type(ref) == "table" then
                    local matchId = false
                    if ref.recordId == opId then
                        matchId = true
                    elseif type(ref.originalIds) == "table" then
                        for j = 1, #ref.originalIds do
                            if ref.originalIds[j] == opId then
                                matchId = true
                                break
                            end
                        end
                    elseif type(ref.records) == "table" then
                        for j = 1, #ref.records do
                            local row = ref.records[j]
                            if type(row) == "table" and row.id == opId then
                                matchId = true
                                break
                            end
                        end
                    end
                    if matchId then
                        local want = ref.contentFingerprint or op.contentFingerprint
                        if not want or not fingerprint or want == fingerprint then
                            return true
                        end
                    end
                end
            elseif op.kind == GS.KIND.RESOLVE_CONFLICT then
                local value = op.value
                if type(value) == "table" and value.chosenOpId == opId then
                    if type(value.contentFingerprints) == "table"
                        and type(value.contentFingerprints[opId]) == "string"
                        and fingerprint
                        and value.contentFingerprints[opId] ~= fingerprint then
                        -- fingerprint disagreement: not a confirmation of this body
                    else
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function ActorMatchesMember(op, member)
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
            -- Concurrent campaign starts from the same parent: explicit conflict.
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
        -- Small-guild bootstrap: only an explicit in-range threshold is coherent.
        local advertised = tonumber(descriptor.bootstrapEditorRankPosition)
            or tonumber(descriptor.editorRankPosition)
        if not advertised or advertised < 1 or advertised > rankCount then
            return "rejected", "invalid_editor_rank_position"
        end
        editorPos = advertised
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
    -- the source advertises a different current policy, lock local edits until
    -- that authenticated policy revision is reconstructed via replication.
    local advertised = descriptor.permissionRevisionId
    if type(advertised) == "string" and advertised ~= "" and advertised ~= descriptor.datasetId then
        GS._bootstrapEditLock[guildKey] = advertised
    else
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
    if type(want) ~= "string" then
        return
    end
    local have = record.permission and record.permission.revisionId
    if have == want then
        GS._bootstrapEditLock[guildKey] = nil
    end
end

function GS.IsBootstrapEditLocked(guildKey)
    if type(guildKey) ~= "string" then
        return false
    end
    return type(GS._bootstrapEditLock[guildKey]) == "string"
end

local function CountBufferedKinds(adop)
    local ops, headers, archives, desc = 0, 0, 0, nil
    local archivePages = {} -- campaignId → { meta, pages = {}, pageCount }
    for i = 1, #adop.order do
        local body = adop.records[adop.order[i]]
        if type(body) == "table" then
            if body.kind == "dataset-desc" and body.datasetId == adop.sourceDatasetId then
                desc = body
            elseif body.kind == "gs-op" then
                ops = ops + 1
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
    return desc, ops, headers, archives, archivePages
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
    if type(meta.itemCount) == "number" and got ~= meta.itemCount then
        return nil, "incomplete_archive_pages"
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
    local desc, ops, headers, archives, archivePages = CountBufferedKinds(adop)
    if not desc then
        return false, "incomplete_transfer"
    end
    -- Descriptor counts must be present and exact (no silent zero-default extras).
    if desc.acceptedOpCount == nil or desc.campaignCount == nil or desc.archiveCount == nil then
        return false, "incomplete_transfer"
    end
    local expectOps = tonumber(desc.acceptedOpCount)
    local expectHeaders = tonumber(desc.campaignCount)
    local expectArchives = tonumber(desc.archiveCount)
    if not expectOps or not expectHeaders or not expectArchives
        or expectOps ~= math.floor(expectOps) or expectOps < 0
        or expectHeaders ~= math.floor(expectHeaders) or expectHeaders < 0
        or expectArchives ~= math.floor(expectArchives) or expectArchives < 0 then
        return false, "incomplete_transfer"
    end
    if ops ~= expectOps or headers ~= expectHeaders or archives ~= expectArchives then
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
        GS._adoption = nil
        NotifyAdoptionStateChanged("expire")
    end
end

function GS:GetPendingAdoption()
    ExpireStaleAdoption()
    local adop = GS._adoption
    if type(adop) == "table" and not adop.committed then
        local complete = select(1, GS:IsAdoptionTransferComplete())
        adop.ready = complete and true or false
    end
    return GS._adoption
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
    if #adop.order >= GS.MAX_ADOPTION_PENDING_RECORDS then
        return "rejected", "full"
    end
    if adop.records[recordId] then
        if DeepEqual(adop.records[recordId], body) then
            local complete = select(1, GS:IsAdoptionTransferComplete())
            return complete and "accepted" or "duplicate", complete and "ready" or "duplicate"
        end
        return "rejected", "id_conflict"
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
local function DurableRetainOnRecord(record, op, reason, boundary)
    if type(record) ~= "table" or type(op) ~= "table" or type(record.operations) ~= "table" then
        return "rejected", "invalid_record"
    end
    local ops = record.operations
    if type(boundary) == "table" and op.kind == GS.KIND.START_CAMPAIGN then
        GS._pendingCampaignBoundaries[op.id] = boundary
    end
    if GS._AdmitPendingOrConflict then
        local st, rsn = GS._AdmitPendingOrConflict(ops, op, reason or "untrusted_relay")
        -- Always classify: foreign evidence that shares ancestry with the current
        -- head must open an explicit conflict, even when the retain reason is
        -- untrusted_relay rather than divergent_edit.
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
                    return "rejected", "full"
                end
                rsn = classReason or rsn
            end
        end
        return st, rsn
    end
    return "pending", reason or "untrusted_relay"
end

--- Replay buffered bodies into an offline temp record (dependency-frontier waves).
-- Does not publish temp into the live guild slot until the caller swaps atomically.
-- Unknown-author history requires exact-content confirmation; source authorship or
-- a buffered confirm/resolve that binds the body is required for promotion.
local function ReplayAdoptionIntoTemp(temp, adop, member)
    -- Isolate runtime pending caches so failed adoption cannot leak into live state.
    local savedRelay = GS._pendingRelay
    local savedBoundaries = GS._pendingCampaignBoundaries
    GS._pendingRelay = {}
    GS._pendingCampaignBoundaries = {}

    local function restoreCaches(ok)
        if not ok then
            GS._pendingRelay = savedRelay
            GS._pendingCampaignBoundaries = savedBoundaries
        else
            -- Successful commit: durable evidence already lives on temp; clear session.
            GS._pendingRelay = {}
            GS._pendingCampaignBoundaries = {}
        end
    end

    -- Dependency-frontier waves: each wave admits ops whose bases match current
    -- authority. Bound by buffered body count so legal history depth is covered
    -- without a fixed 64-pass truncation or rank-type priority phases.
    local maxPasses = math.max(8, #adop.order + 8)
    local progress = true
    local pass = 0
    while progress and pass < maxPasses do
        progress = false
        pass = pass + 1
        for i = 1, #adop.order do
            local body = adop.records[adop.order[i]]
            if type(body) ~= "table" then
                -- skip
            elseif body.kind == "gs-op" and type(body.op) == "table" then
                local op = body.op
                local alreadyAccepted = temp.operations.records and temp.operations.records[op.id]
                local alreadyConflict = temp.operations.conflicts and temp.operations.conflicts[op.id]
                local alreadyPending = temp.operations.pending and temp.operations.pending[op.id]
                if not alreadyAccepted then
                    local sourceAuthored = ActorMatchesMember(op, member)
                    local fp = ContentFingerprint(op)
                    local confirmed = AdoptionHasConfirmationFor(adop, op.id, fp)
                    local isAuthEnvelope = op.kind == GS.KIND.CONFIRM_CANDIDATE
                        or op.kind == GS.KIND.RESOLVE_CONFLICT
                    local hadPending = alreadyPending ~= nil
                    local hadRelay = GS._pendingRelay[op.id] ~= nil
                    local status, reason
                    if sourceAuthored then
                        -- Source-authored bodies (including confirm/resolve envelopes).
                        status, reason = GS:AdmitRemoteOperation(op, {
                            sender = adop.sourcePeer,
                            member = member,
                            boundary = body.boundary,
                            localWrite = false,
                            adoptionReplay = true,
                            offlineRecord = temp,
                            preserveAttribution = true,
                        })
                    elseif confirmed and not isAuthEnvelope then
                        -- Exact-content confirmation is present in the transfer.
                        -- Retain then let the confirmer envelope promote.
                        status, reason = GS:AdmitRemoteOperation(op, {
                            sender = adop.sourcePeer,
                            member = member,
                            boundary = body.boundary,
                            localWrite = false,
                            adoptionReplay = true,
                            offlineRecord = temp,
                            relay = true,
                        })
                        if status == "pending" and GS._pendingRelay[op.id]
                            and not (temp.operations.pending and temp.operations.pending[op.id]) then
                            DurableRetainOnRecord(temp, op, reason or "untrusted_relay", body.boundary)
                        end
                    elseif isAuthEnvelope then
                        -- Foreign confirm/resolve envelopes are not actor-proof.
                        -- Retain durably until a source-authored confirmation arrives.
                        status, reason = DurableRetainOnRecord(
                            temp, op, "untrusted_relay", body.boundary)
                        RetainPendingRelay(op.id, {
                            body = op,
                            sender = adop.sourcePeer,
                            at = op.timestamp,
                            fingerprint = fp,
                            boundary = body.boundary,
                        })
                    else
                        -- Foreign history / evidenceOnly: durable pending, never accepted.
                        status, reason = GS:AdmitRemoteOperation(op, {
                            sender = adop.sourcePeer,
                            member = member,
                            boundary = body.boundary,
                            localWrite = false,
                            adoptionReplay = true,
                            offlineRecord = temp,
                            relay = true,
                        })
                        if status == "pending" then
                            if not (temp.operations.pending and temp.operations.pending[op.id])
                                and not (temp.operations.conflicts and temp.operations.conflicts[op.id]) then
                                DurableRetainOnRecord(temp, op, reason or "untrusted_relay", body.boundary)
                            end
                        end
                    end
                    if status == "accepted" or status == "duplicate" then
                        progress = true
                    elseif status == "pending" then
                        local nowPending = temp.operations.pending and temp.operations.pending[op.id] ~= nil
                        local nowRelay = GS._pendingRelay[op.id] ~= nil
                        local nowConflict = temp.operations.conflicts and temp.operations.conflicts[op.id] ~= nil
                        if (nowPending and not hadPending) or (nowRelay and not hadRelay)
                            or (nowConflict and not alreadyConflict) then
                            progress = true
                        end
                    end
                end
            elseif body.kind == "campaign-header" and type(body.header) == "table" then
                local h = body.header
                if type(h.campaignId) == "string" and temp.campaigns[h.campaignId] == nil then
                    if GS.ValidateCampaignBoundary and GS.ValidateCampaignBoundary(h, temp, adop.guildKey) then
                        if temp.operations.records[h.campaignId] then
                            temp.campaigns[h.campaignId] = h
                            progress = true
                        end
                    end
                end
            elseif body.kind == "campaign-archive" and type(body.campaignId) == "string" then
                if temp.campaignArchives[body.campaignId] == nil then
                    if temp.currentCampaignId == body.campaignId then
                        -- reject current-campaign archive during replay
                    elseif not temp.campaigns[body.campaignId] then
                        -- wait for campaign header/start
                    else
                        local pages = {}
                        if not body.requestedItems then
                            for j = 1, #adop.order do
                                local pb = adop.records[adop.order[j]]
                                if type(pb) == "table" and pb.kind == "campaign-archive-page"
                                    and pb.campaignId == body.campaignId then
                                    pages[tonumber(pb.page) or 0] = pb
                                end
                            end
                        end
                        local archive, aerr = AssemblePagedArchive(body, pages)
                        if not archive then
                            if aerr == "incomplete_archive_pages" then
                                -- wait for pages
                            else
                                restoreCaches(false)
                                return false, aerr or "invalid_campaign_archive"
                            end
                        elseif GS.ValidateCampaignArchive
                            and GS.ValidateCampaignArchive(archive, body.campaignId, temp) then
                            local existing = temp.campaignArchives[body.campaignId]
                            if existing then
                                if not DeepEqual(existing, archive) then
                                    restoreCaches(false)
                                    return false, "archive_conflict"
                                end
                            else
                                temp.campaignArchives[body.campaignId] = archive
                                progress = true
                            end
                        end
                    end
                else
                    local pages = {}
                    if not body.requestedItems then
                        for j = 1, #adop.order do
                            local pb = adop.records[adop.order[j]]
                            if type(pb) == "table" and pb.kind == "campaign-archive-page"
                                and pb.campaignId == body.campaignId then
                                pages[tonumber(pb.page) or 0] = pb
                            end
                        end
                    end
                    local archive = select(1, AssemblePagedArchive(body, pages))
                    if archive and not DeepEqual(temp.campaignArchives[body.campaignId], archive) then
                        restoreCaches(false)
                        return false, "archive_conflict"
                    end
                end
            elseif body.kind == "campaign-archive-page" then
                -- Pages alone do not settle; meta assembly above consumes them.
            end
        end
        -- Retry pending source-authored resolutions after candidates may have opened.
        if temp.operations.pending then
            for pid, pend in pairs(temp.operations.pending) do
                local pob = pend and pend.body
                if type(pob) == "table" and pob.kind == GS.KIND.RESOLVE_CONFLICT
                    and ActorMatchesMember(pob, member)
                    and not (temp.operations.records and temp.operations.records[pid]) then
                    local st2 = select(1, GS:AdmitRemoteOperation(pob, {
                        sender = adop.sourcePeer,
                        member = member,
                        localWrite = false,
                        adoptionReplay = true,
                        offlineRecord = temp,
                        preserveAttribution = true,
                    }))
                    if st2 == "accepted" or st2 == "duplicate" then
                        progress = true
                    end
                end
            end
        end
        -- Redrive confirmations against newly retained candidates each wave.
        GS.RedriveExactContentConfirmations(temp, {
            adoptionReplay = true,
            offlineRecord = temp,
            sender = adop.sourcePeer,
            member = member,
        })
    end

    -- Completeness: every buffered gs-op must be settled on the durable temp
    -- record (accepted, conflict evidence, or pending). Session-only _pendingRelay
    -- is not durable settlement.
    for i = 1, #adop.order do
        local body = adop.records[adop.order[i]]
        if type(body) == "table" and body.kind == "gs-op" and type(body.op) == "table" then
            local oid = body.op.id
            local settled = temp.operations.records and temp.operations.records[oid]
            if not settled and temp.operations.conflicts and temp.operations.conflicts[oid] then
                settled = true
            end
            if not settled and temp.operations.pending and temp.operations.pending[oid] then
                settled = true
            end
            if not settled then
                local fp = ContentFingerprint(body.op)
                local sourceAuthored = ActorMatchesMember(body.op, member)
                local confirmed = AdoptionHasConfirmationFor(adop, oid, fp)
                if body.evidenceOnly and not sourceAuthored and not confirmed then
                    -- Unretained evidence-only body is incomplete.
                    settled = false
                elseif sourceAuthored or confirmed then
                    -- Source-authored / confirmed bodies must fully apply or retain.
                    settled = false
                else
                    settled = false
                end
            end
            if not settled then
                restoreCaches(false)
                return false, "incomplete_transfer"
            end
        elseif type(body) == "table" and body.kind == "campaign-header" then
            local h = body.header
            if type(h) == "table" and type(h.campaignId) == "string" then
                if temp.campaigns[h.campaignId] == nil then
                    -- Required header missing after replay.
                    if temp.operations.records and temp.operations.records[h.campaignId] then
                        restoreCaches(false)
                        return false, "missing_campaign_header"
                    end
                end
            end
        elseif type(body) == "table" and body.kind == "campaign-archive" then
            if body.campaignId and temp.currentCampaignId == body.campaignId then
                restoreCaches(false)
                return false, "invalid_campaign_archive"
            end
            if body.campaignId and temp.campaignArchives[body.campaignId] == nil
                and temp.campaigns[body.campaignId] ~= nil then
                restoreCaches(false)
                return false, "invalid_campaign_archive"
            end
        end
    end
    restoreCaches(true)
    return true
end

--- Commit adoption: replace local staged guild record with the assembled source dataset.
-- Failure / incomplete / stale authority leaves the previous dataset intact.
function GS:CommitDatasetAdoption()
    -- Expiry must run on the commit path itself (Settings may call Commit after
    -- async transfer without touching GetPendingAdoption/Buffer accessors).
    ExpireStaleAdoption()
    local adop = GS._adoption
    if type(adop) ~= "table" or adop.committed then
        return "rejected", "no_adoption"
    end

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

    local complete, completeReason, desc = GS:IsAdoptionTransferComplete()
    if not complete then
        return "rejected", completeReason or "incomplete_transfer"
    end

    -- Local confirmation freshness: local dataset/policy/campaign/config must
    -- still match the Begin snapshot. Divergence cancels silent replacement.
    local live = GS._root.guilds[adop.guildKey]
    if type(live) == "table" then
        if adop.localDatasetId and live.datasetId ~= adop.localDatasetId then
            return "rejected", "source_changed"
        end
        local livePolicy = live.permission and live.permission.revisionId
        if adop.localPolicyRevision and livePolicy ~= adop.localPolicyRevision then
            return "rejected", "stale_base"
        end
        if (adop.localCampaignId or nil) ~= (live.currentCampaignId or nil) then
            return "rejected", "stale_base"
        end
        local liveSeq = live.accounting and live.accounting._consumables
            and tonumber(live.accounting._consumables.configSeq)
        if adop.localConfigSeq ~= nil and liveSeq ~= adop.localConfigSeq then
            return "rejected", "stale_base"
        end
        local liveAccepted = 0
        if live.operations and type(live.operations.order) == "table" then
            liveAccepted = #live.operations.order
        end
        if adop.localAcceptedCount ~= nil and liveAccepted ~= adop.localAcceptedCount then
            return "rejected", "stale_base"
        end
    end

    local identity = GG().GetGuildIdentity()
    local ranks = GG() and GG().GetGuildRanks and GG().GetGuildRanks()
    local rankCount = type(ranks) == "table" and tonumber(ranks.count) or 0
    local defaultPos = GS.DEFAULT_EDITOR_RANK_POSITION or 3
    -- Prefer immutable bootstrap threshold from the source descriptor.
    local bootstrapPos = tonumber(desc.bootstrapEditorRankPosition)
        or tonumber(desc.editorRankPosition)
        or defaultPos
    if rankCount > 0 and rankCount < defaultPos then
        if not bootstrapPos or bootstrapPos < 1 or bootstrapPos > rankCount then
            return "rejected", "invalid_editor_rank_position"
        end
    elseif rankCount and bootstrapPos and bootstrapPos > rankCount then
        return "rejected", "invalid_editor_rank_position"
    end

    local temp = NewBootstrapRecord(adop.sourceDatasetId, adop.guildKey, identity, bootstrapPos)
    -- Offline replay: never publish temp until fully validated. Live guild slot
    -- stays untouched; AdmitRemoteOperation uses offlineRecord=temp only.
    local okReplay, replayErr = ReplayAdoptionIntoTemp(temp, adop, member)
    if not okReplay then
        return "rejected", replayErr or "incomplete_transfer"
    end

    if GS._ValidateGuildRecordStructure then
        local ok, err = GS._ValidateGuildRecordStructure(adop.guildKey, temp)
        if not ok then
            return "rejected", err or "invalid_record"
        end
    end

    -- Atomic swap + epoch bump so delayed old-dataset work cannot restore state.
    GS._root.guilds[adop.guildKey] = temp
    GS._adoptionEpoch = (tonumber(GS._adoptionEpoch) or 0) + 1
    adop.committed = true
    GS._adoption = nil
    GS._pendingRelay = {}
    GS._pendingCampaignBoundaries = {}
    DebugInfo("committed dataset adoption dataset=%s epoch=%s",
        adop.sourceDatasetId, tostring(GS._adoptionEpoch))
    if GS._NotifyLocalDurableChange then
        GS._NotifyLocalDurableChange("adoption")
    end
    NotifyAdoptionStateChanged("commit")
    return "accepted", nil
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
-- Replays accepted (and chosen-lineage) config mutations under the chosen campaign
-- without archiving the provisional current sibling or bumping generation.
local function ReconstructChosenCampaignProjection(record, chosenId, header)
    local cfg = record.accounting and record.accounting._consumables
    local ops = record.operations
    if type(cfg) ~= "table" or type(ops) ~= "table" then
        return false, "invalid_accounting"
    end
    cfg.requestedItems = {}
    cfg.eligibility = {}
    if GS.EstablishCampaignBaseline then
        GS.EstablishCampaignBaseline(cfg, header and (header.startedAt) or nil)
    end
    -- Walk accepted history in order; apply config mutations belonging to chosen.
    if type(ops.order) == "table" and type(ops.records) == "table" then
        for i = 1, #ops.order do
            local op = ops.records[ops.order[i]]
            if type(op) == "table"
                and op.campaignId == chosenId
                and op.kind ~= GS.KIND.START_CAMPAIGN
                and op.kind ~= GS.KIND.RESOLVE_CONFLICT
                and op.kind ~= GS.KIND.CONFIRM_CANDIDATE
                and op.kind ~= GS.KIND.SET_EDITOR_RANK then
                if GS._ApplyMutations then
                    local ok = GS._ApplyMutations(record, op)
                    if not ok then
                        -- Skip mutations that cannot apply against reconstructed state.
                    end
                end
            end
        end
    end
    -- Also apply pending/conflict bodies that belong to the chosen campaign and
    -- are listed as the chosen lineage (already promoted separately).
    return true
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
        record.campaigns[chosen.id] = boundary
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

    -- Sibling switch: keep generation; reconstruct items/eligibility from history.
    local previousItems = cfg.requestedItems
    local previousEligibility = cfg.eligibility
    local previousConfigSeq = cfg.configSeq
    local previousCurrent = record.currentCampaignId

    local okRecon, reconErr = ReconstructChosenCampaignProjection(
        record, chosen.id, header)
    if not okRecon then
        cfg.requestedItems = previousItems
        cfg.eligibility = previousEligibility
        return false, reconErr or "projection_failed"
    end
    -- Ensure baseline timestamp from chosen boundary when reconstruction left empty eligibility.
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
    end
    if not (ops.records and ops.records[chosen.id]) then
        if GS._StoreAccepted then
            GS._StoreAccepted(ops, chosen, GS.CAMPAIGN_TARGET_KEY)
        end
    elseif ops.heads then
        ops.heads[GS.CAMPAIGN_TARGET_KEY] = chosen.id
    end

    if GS._ValidateGuildRecordStructure then
        local postOk, postErr = GS._ValidateGuildRecordStructure(
            chosen.guildKey or record._guildKey, record)
        if not postOk then
            cfg.requestedItems = previousItems
            cfg.eligibility = previousEligibility
            cfg.configSeq = previousConfigSeq
            record.currentCampaignId = previousCurrent
            return false, postErr or "invalid_record"
        end
    end
    return true
end

-- Validates first; commits archive + boundary + config reset atomically.
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
            local mok, merr = GS._MarkTargetConflict(ops, targetKey, candidates, stored.timestamp, meta)
            if not mok and merr == "full" then
                return "rejected", "full"
            end
            return st, reason
        end
        local mok, merr = GS._MarkTargetConflict(ops, targetKey, candidates, stored.timestamp, meta)
        if not mok and merr == "full" then
            return "rejected", "full"
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
function GS.ApplyExactContentConfirmation(record, storedConfirm, admissionCtx)
    admissionCtx = admissionCtx or {}
    if type(record) ~= "table" or type(storedConfirm) ~= "table" then
        return false, "invalid_operation"
    end
    local ref = storedConfirm.candidateRef
    if type(ref) ~= "table" then
        return true
    end
    local wantFp = ref.contentFingerprint or storedConfirm.contentFingerprint
    local ids = {}
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
    local seen = {}
    for i = 1, #ids do
        local rid = ids[i]
        if type(rid) == "string" and not seen[rid] then
            seen[rid] = true
            local body, boundary, fp, source = LookupRetainedCandidate(record, rid)
            if type(body) == "table" then
                fp = fp or ContentFingerprint(body)
                local rowFp = nil
                if type(ref.records) == "table" then
                    for j = 1, #ref.records do
                        local row = ref.records[j]
                        if type(row) == "table" and row.id == rid then
                            rowFp = row.contentFingerprint
                            break
                        end
                    end
                end
                local expect = rowFp or wantFp or fp
                if type(fp) == "string" and fp == expect then
                    local st, reason = ApplyPreservedAttributionCandidate(
                        record, body, boundary, admissionCtx)
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
            end
        end
    end
    return true
end

--- Re-apply accepted confirmation envelopes against newly retained candidates
-- (confirm-first / predecessor-late). Scans the full confirmationRefs list using
-- a bounded per-call slice so correctness is not truncated at index 32.
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

    local editorOk, editorReason = GS.SenderHasEditorAuthority(member, {
        requireRecoverPolicy = requireRecover,
    })

    -- Untrusted relay: retain historical candidates without rebinding attribution.
    -- A forwarded author field is not authentication, even if that GUID is currently
    -- an editor. Explicit exact-content confirmation is the only promotion path.
    if admissionCtx.relay == true or not editorOk then
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
        if stored.basePolicyRevision ~= CurrentPolicyRevision(record) then
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
                if GS._AdmitPendingOrConflict then
                    return GS._AdmitPendingOrConflict(ops, stored, "stale_base")
                end
                return "pending", "stale_base"
            end
            return "rejected", "stale_base"
        end
        if (stored.baseCampaignId or nil) ~= (record.currentCampaignId or nil) and not ancestryOk then
            if admissionCtx.adoptionReplay then
                if GS._AdmitPendingOrConflict then
                    return GS._AdmitPendingOrConflict(ops, stored, "stale_base")
                end
                return "pending", "stale_base"
            end
            return "rejected", "stale_base"
        end
        if type(open) ~= "table" then
            -- Fast path: chosen already current head — still require complete
            -- dependency fingerprints for every competing id when provided.
            local headNow = ops.heads and ops.heads[targetKey]
            if type(headNow) == "string" then
                headNow = UnderlyingConflictValueId(ops, headNow) or headNow
            end
            local chosenNow = UnderlyingConflictValueId(ops, value.chosenOpId) or value.chosenOpId
            if headNow == value.chosenOpId or headNow == chosenNow then
                if type(value.contentFingerprints) ~= "table" then
                    return "rejected", "fingerprint_mismatch"
                end
                local depIds = value.competingOpIds
                if type(depIds) ~= "table" then
                    depIds = { value.chosenOpId }
                end
                for i = 1, #depIds do
                    local id = depIds[i]
                    local fp = value.contentFingerprints[id]
                    local body = ops.records[id]
                        or (ops.pending[id] and ops.pending[id].body)
                        or (ops.conflicts[id] and ops.conflicts[id].body)
                    if type(fp) ~= "string" or not body or ContentFingerprint(body) ~= fp then
                        if admissionCtx.adoptionReplay then
                            if GS._AdmitPendingOrConflict then
                                return GS._AdmitPendingOrConflict(ops, stored, "missing_predecessor")
                            end
                            return "pending", "missing_predecessor"
                        end
                        return "rejected", "fingerprint_mismatch"
                    end
                end
                -- Atomic capacity: resolution envelope slot.
                if not ops.records[stored.id] then
                    if GS._AcceptedCount and GS._AcceptedCount(ops) >= GS.MAX_ACCEPTED_OPERATIONS then
                        return "rejected", "full"
                    end
                    if GS._StoreAccepted then
                        GS._StoreAccepted(ops, stored, nil)
                    end
                end
                if ops.heads then
                    ops.heads[targetKey] = value.chosenOpId
                end
                return "accepted", nil
            end
            -- During adoption replay, competing candidates may arrive later.
            if admissionCtx.adoptionReplay then
                if GS._AdmitPendingOrConflict then
                    return GS._AdmitPendingOrConflict(ops, stored, "missing_predecessor")
                end
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
        -- Exact competing set: every open candidate must be listed when provided.
        if type(value.competingOpIds) == "table" and type(open.candidateIds) == "table" then
            if #value.competingOpIds ~= #open.candidateIds then
                return "rejected", "invalid_resolution"
            end
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
        if type(value.contentFingerprints) ~= "table" then
            return "rejected", "fingerprint_mismatch"
        end
        for i = 1, #(open.candidateIds or {}) do
            local id = open.candidateIds[i]
            local fp = value.contentFingerprints[id]
            local body = ops.records[id]
                or (ops.pending[id] and ops.pending[id].body)
                or (ops.conflicts[id] and ops.conflicts[id].body)
            if type(fp) ~= "string" or not body or ContentFingerprint(body) ~= fp then
                return "rejected", "fingerprint_mismatch"
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
        if type(value.competingOpIds) == "table" then
            for i = 1, #value.competingOpIds do
                local cid = value.competingOpIds[i]
                if cid ~= value.chosenOpId then
                    if ops.pending and ops.pending[cid] then
                        -- Keep losing evidence in conflicts; drop pending apply slot.
                        if GS._RetainConflict and ops.pending[cid].body then
                            GS._RetainConflict(ops, ops.pending[cid].body)
                        end
                        ops.pending[cid] = nil
                    end
                    if GS._pendingCampaignBoundaries then
                        GS._pendingCampaignBoundaries[cid] = nil
                    end
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
        if GS._AdmitPendingOrConflict then
            local st, reason = GS._AdmitPendingOrConflict(ops, stored, classReason or "divergent_edit")
            local mok, merr = GS._MarkTargetConflict(ops, targetKey, candidates, stored.timestamp, meta)
            if not mok and merr == "full" then
                return "rejected", "full"
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
