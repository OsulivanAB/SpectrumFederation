-- Guild Supplies staged operations, IDs, and confirmation contracts (#385).
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

GS.OP_SCHEMA_VERSION = 1

local KIND = {
    SET_EDITOR_RANK = "set-editor-rank",
    SET_BANK_TAB = "set-bank-tab",
    SET_REQUESTED_ITEM = "set-requested-item",
    CONFIRM_CANDIDATE = "confirm-candidate",
}

GS.KIND = KIND

local function ServerTime()
    if GetServerTime then
        local t = GetServerTime()
        if type(t) == "number" and t == t and t >= 0 then
            return math.floor(t)
        end
    end
    return nil
end

local function DeepEqual(a, b, depth)
    depth = (depth or 0) + 1
    if depth > 8 then
        return false
    end
    if a == b then
        return true
    end
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return false
    end
    for k, v in pairs(a) do
        if not DeepEqual(v, b[k], depth) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

local function TargetKey(kind, target)
    if kind == KIND.SET_EDITOR_RANK then
        return "permission:editorRankPosition"
    elseif kind == KIND.SET_BANK_TAB then
        return "config:bankTab"
    elseif kind == KIND.SET_REQUESTED_ITEM then
        local itemId = type(target) == "table" and tonumber(target.itemId) or tonumber(target)
        if not itemId then
            return nil
        end
        return "item:" .. tostring(itemId)
    elseif kind == KIND.CONFIRM_CANDIDATE then
        return "confirm"
    end
    return nil
end

local function CountMap(t)
    local n = 0
    if type(t) ~= "table" then
        return 0
    end
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

local function AcceptedCount(ops)
    return #(ops.order or {})
end

local function PendingCount(ops)
    return CountMap(ops.pending)
end

local function GetHead(ops, targetKey)
    return ops.heads[targetKey]
end

local function CurrentTargetRevision(record, targetKey)
    local head = GetHead(record.operations, targetKey)
    if type(head) == "string" and head ~= "" then
        return head
    end
    return record.datasetId
end

local function CurrentPolicyRevision(record)
    if type(record.permission) == "table" and type(record.permission.revisionId) == "string" then
        return record.permission.revisionId
    end
    return record.datasetId
end

local function NormalizeRequestedItemValue(value)
    if value == nil then
        return { removed = true }
    end
    if type(value) ~= "table" then
        return nil, "invalid_item_value"
    end
    if value.removed == true then
        return { removed = true }
    end
    local itemId = tonumber(value.itemId)
    local goal = tonumber(value.goal)
    if not itemId or itemId ~= math.floor(itemId) or itemId < 1 then
        return nil, "invalid_item_id"
    end
    local C = SF.Consumables
    local maxGoal = (C and C.MAX_GOAL) or 100000
    local maxItems = (C and C.MAX_REQUESTED_ITEMS) or 256
    if not goal or goal ~= math.floor(goal) or goal < 0 or goal > maxGoal then
        return nil, "invalid_goal"
    end
    return {
        itemId = itemId,
        goal = goal,
        removed = false,
    }, nil, maxItems
end

local function ValidateConfigShape(op)
    if type(op) ~= "table" then
        return false, "invalid_operation"
    end
    if tonumber(op.schemaVersion) ~= GS.OP_SCHEMA_VERSION then
        return false, "unsupported_schema"
    end
    if type(op.id) ~= "string" or op.id == "" or #op.id > GS.MAX_OPERATION_ID then
        return false, "invalid_id"
    end
    local guildKey = GS.ParseGuildKey(op.guildKey)
    if not guildKey then
        return false, "invalid_guild_key"
    end
    if type(op.datasetId) ~= "string" or op.datasetId == "" then
        return false, "invalid_dataset_id"
    end
    if type(op.kind) ~= "string" or op.kind == "" then
        return false, "invalid_kind"
    end
    if type(op.actorGuid) ~= "string" or op.actorGuid == "" then
        return false, "invalid_actor"
    end
    if type(op.actorName) ~= "string" or op.actorName == "" then
        return false, "invalid_actor"
    end
    local ts = tonumber(op.timestamp)
    if not ts or ts ~= math.floor(ts) or ts < 0 then
        return false, "invalid_timestamp"
    end
    if type(op.baseTargetRevision) ~= "string" or op.baseTargetRevision == "" then
        return false, "invalid_base_target"
    end
    if type(op.basePolicyRevision) ~= "string" or op.basePolicyRevision == "" then
        return false, "invalid_base_policy"
    end
    if op.campaignId ~= nil and type(op.campaignId) ~= "string" then
        return false, "invalid_campaign"
    end
    if op.baseCampaignId ~= nil and type(op.baseCampaignId) ~= "string" then
        return false, "invalid_base_campaign"
    end
    return true
end

local function ValidateKindValue(op)
    local kind = op.kind
    if kind == KIND.SET_EDITOR_RANK then
        local pos = tonumber(op.value)
        if type(op.target) ~= "string" or op.target ~= "editorRankPosition" then
            return false, "invalid_target"
        end
        if not pos or pos ~= math.floor(pos) or pos < 1 then
            return false, "invalid_editor_rank_position"
        end
        return true
    elseif kind == KIND.SET_BANK_TAB then
        if type(op.target) ~= "string" or op.target ~= "bankTab" then
            return false, "invalid_target"
        end
        if op.value ~= nil then
            local tab = tonumber(op.value)
            if not tab or tab ~= math.floor(tab) or tab < 1 then
                return false, "invalid_bank_tab"
            end
        end
        return true
    elseif kind == KIND.SET_REQUESTED_ITEM then
        local itemId = type(op.target) == "table" and tonumber(op.target.itemId) or tonumber(op.target)
        if not itemId then
            return false, "invalid_target"
        end
        local normalized, err = NormalizeRequestedItemValue(op.value)
        if not normalized then
            return false, err
        end
        if normalized.removed ~= true and normalized.itemId ~= itemId then
            return false, "item_id_mismatch"
        end
        return true
    elseif kind == KIND.CONFIRM_CANDIDATE then
        return false, "use_confirmation_api"
    end
    return false, "unsupported_kind"
end

function GS:NewConfigOperation(kind, target, value)
    local ctx = GS:GetCurrentContext()
    if not ctx or not ctx.ready then
        return nil, "rejected", (ctx and ctx.reason) or "not_ready"
    end
    local ts = ServerTime()
    if not ts then
        return nil, "rejected", "server_time_unavailable"
    end

    local record, recordReason = GS:GetCurrentRecord()
    local datasetId
    local campaignId = nil
    local basePolicyRevision
    local baseCampaignId = nil
    local baseTargetRevision

    if kind == KIND.SET_EDITOR_RANK or kind == KIND.SET_BANK_TAB or kind == KIND.SET_REQUESTED_ITEM then
        if not record then
            return nil, "rejected", recordReason or "not_configured"
        end
        datasetId = record.datasetId
        campaignId = record.currentCampaignId
        baseCampaignId = record.currentCampaignId
        basePolicyRevision = CurrentPolicyRevision(record)
        local tKey = TargetKey(kind, target)
        if not tKey then
            return nil, "rejected", "invalid_target"
        end
        baseTargetRevision = CurrentTargetRevision(record, tKey)
    else
        return nil, "rejected", "unsupported_kind"
    end

    -- Authority for creating an op draft: need edit or recover for policy ops.
    local requireRecover = false
    local caps = GS:GetCapabilities()
    if kind == KIND.SET_EDITOR_RANK then
        local policyPos = record and record.permission and tonumber(record.permission.editorRankPosition)
        local rankCount = ctx.rankCount
        local policyOk = policyPos and rankCount and policyPos <= rankCount
        if not policyOk then
            if not caps.canRecoverPolicy then
                return nil, "rejected", caps.reason or "unauthorized"
            end
            requireRecover = true
        elseif not caps.canEdit then
            return nil, "rejected", caps.reason or "unauthorized"
        end
    elseif not caps.canEdit then
        return nil, "rejected", caps.reason or "unauthorized"
    end

    if kind == KIND.SET_REQUESTED_ITEM then
        local itemId = type(target) == "table" and tonumber(target.itemId) or tonumber(target)
        if not itemId then
            return nil, "rejected", "invalid_target"
        end
        target = { itemId = itemId }
        local normalized, err = NormalizeRequestedItemValue(value)
        if not normalized then
            return nil, "rejected", err
        end
        if normalized.removed then
            value = { removed = true }
        else
            value = normalized
        end
    elseif kind == KIND.SET_EDITOR_RANK then
        target = "editorRankPosition"
        value = tonumber(value)
    elseif kind == KIND.SET_BANK_TAB then
        target = "bankTab"
        if value ~= nil then
            value = tonumber(value)
        end
    end

    local id, idErr = GS:_AllocateOperationId(ctx.actorGuid)
    if not id then
        return nil, "rejected", idErr or "id_failed"
    end

    local op = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = id,
        guildKey = ctx.guildKey,
        datasetId = datasetId,
        campaignId = campaignId,
        kind = kind,
        target = target,
        value = value,
        actorGuid = ctx.actorGuid,
        actorName = ctx.actorName,
        timestamp = ts,
        baseTargetRevision = baseTargetRevision,
        basePolicyRevision = basePolicyRevision,
        baseCampaignId = baseCampaignId,
        _preparedHandleGeneration = ctx.handleGeneration,
        _requireRecoverPolicy = requireRecover and true or false,
    }
    return op, "accepted", nil
end

function GS:ValidateConfigOperation(op, context)
    local ok, err = ValidateConfigShape(op)
    if not ok then
        return false, err
    end
    ok, err = ValidateKindValue(op)
    if not ok then
        return false, err
    end

    context = context or GS:GetCurrentContext()
    if not context or not context.ready then
        return false, (context and context.reason) or "not_ready"
    end
    if op.guildKey ~= context.guildKey then
        return false, "wrong_guild"
    end
    if op.actorGuid ~= context.actorGuid then
        return false, "unauthorized"
    end

    local record, recordReason = nil, nil
    if GS:IsRootReady() and GS._root and GS._root.guilds then
        record = GS._root.guilds[op.guildKey]
        if record then
            local valid, vErr = true, nil
            -- Use local validation without requiring current identity match beyond key.
            if type(record) == "table" then
                local schema = tonumber(record.schemaVersion)
                if schema ~= GS.SCHEMA_VERSION then
                    valid, vErr = false, "unsupported_schema"
                end
            end
            if not valid then
                return false, vErr
            end
        else
            recordReason = "not_configured"
        end
    end
    if not record then
        return false, recordReason or "not_configured"
    end
    if op.datasetId ~= record.datasetId then
        return false, "dataset_mismatch"
    end

    local currentPolicy = CurrentPolicyRevision(record)
    if op.basePolicyRevision ~= currentPolicy then
        return false, "stale_base"
    end

    local currentCampaign = record.currentCampaignId
    if (op.baseCampaignId or nil) ~= (currentCampaign or nil) then
        return false, "stale_base"
    end
    if currentCampaign ~= nil then
        if op.campaignId ~= currentCampaign then
            return false, "stale_base"
        end
    else
        if op.campaignId ~= nil then
            return false, "stale_base"
        end
    end

    local tKey = TargetKey(op.kind, op.target)
    if not tKey then
        return false, "invalid_target"
    end
    local currentRev = CurrentTargetRevision(record, tKey)
    if op.baseTargetRevision ~= currentRev then
        -- Missing/unknown base is pending for remote ancestry; local staged
        -- compare treats mismatch against known head as stale_base unless the
        -- base is simply not yet present in this client (same as stale for local).
        return false, "stale_base"
    end

    if op.kind == KIND.SET_EDITOR_RANK then
        local pos = tonumber(op.value)
        local rankCount = context.rankCount
        if not rankCount or pos > rankCount then
            return false, "invalid_editor_rank_position"
        end
        local policyPos = tonumber(record.permission.editorRankPosition)
        local policyOk = policyPos and policyPos >= 1 and policyPos <= rankCount
        local caps = GS:GetCapabilities()
        if not policyOk then
            if not caps.canRecoverPolicy then
                return false, "unauthorized"
            end
        else
            -- Evaluate under currently accepted policy (old value).
            if not caps.canEdit and not caps.canRecoverPolicy then
                return false, caps.reason or "unauthorized"
            end
            if not caps.canEdit then
                return false, caps.reason or "unauthorized"
            end
        end
    else
        local caps = GS:GetCapabilities()
        if not caps.canEdit then
            return false, caps.reason or "unauthorized"
        end
    end

    return true
end

local function RetainConflict(ops, op)
    ops.conflicts[op.id] = {
        id = op.id,
        kind = op.kind,
        targetKey = TargetKey(op.kind, op.target),
        body = op,
        at = ServerTime() or op.timestamp,
    }
end

local function RetainPending(ops, op, reason)
    ops.pending[op.id] = {
        id = op.id,
        reason = reason,
        body = op,
        at = ServerTime() or op.timestamp,
    }
end

local function PublicOpCopy(op)
    local copy = {}
    for k, v in pairs(op) do
        if type(k) ~= "string" or k:sub(1, 1) ~= "_" then
            copy[k] = v
        end
    end
    return copy
end

local function StoreAccepted(ops, op, targetKey)
    local stored = PublicOpCopy(op)
    ops.records[op.id] = stored
    ops.order[#ops.order + 1] = op.id
    ops.heads[targetKey] = op.id
    ops.pending[op.id] = nil
end

local function ApplyMutations(record, op)
    if op.kind == KIND.SET_EDITOR_RANK then
        record.permission.editorRankPosition = tonumber(op.value)
        record.permission.revisionId = op.id
        return true
    elseif op.kind == KIND.SET_BANK_TAB then
        local cfg = record.accounting._consumables
        cfg.bankTab = op.value
        -- Eligibility floor for tab changes is a later projection concern; store value only.
        return true
    elseif op.kind == KIND.SET_REQUESTED_ITEM then
        local cfg = record.accounting._consumables
        cfg.requestedItems = cfg.requestedItems or {}
        local itemId = tonumber(op.target.itemId)
        local key = tostring(itemId)
        if type(op.value) == "table" and op.value.removed == true then
            cfg.requestedItems[key] = nil
            -- Tombstone retained via operation store / head pointer.
        else
            local C = SF.Consumables
            local maxItems = (C and C.MAX_REQUESTED_ITEMS) or 256
            if cfg.requestedItems[key] == nil then
                local count = 0
                for _ in pairs(cfg.requestedItems) do
                    count = count + 1
                    if count >= maxItems then
                        return false, "full"
                    end
                end
            end
            cfg.requestedItems[key] = {
                itemId = itemId,
                goal = tonumber(op.value.goal) or 0,
            }
        end
        return true
    end
    return false, "unsupported_kind"
end

function GS:ApplyStagedConfigOperation(op, context)
    if type(op) ~= "table" then
        return "rejected", "invalid_operation"
    end

    -- Recheck actual guild/rank/policy at commit (prepared context may be stale).
    local prepared = {
        guildKey = op.guildKey,
        actorGuid = op.actorGuid,
        handleGeneration = op._preparedHandleGeneration,
    }
    local authOk, authReason, fresh = GS:_AuthorizeCommit(prepared, {
        allowRecoverPolicy = (op.kind == KIND.SET_EDITOR_RANK) or false,
        requireRecoverPolicy = op._requireRecoverPolicy and true or false,
    })
    if not authOk then
        return "rejected", authReason or "unauthorized"
    end
    context = fresh or context or GS:GetCurrentContext()

    local shapeOk, shapeErr = ValidateConfigShape(op)
    if not shapeOk then
        return "rejected", shapeErr
    end
    local kindOk, kindErr = ValidateKindValue(op)
    if not kindOk then
        return "rejected", kindErr
    end

    if not GS:IsRootReady() then
        return "rejected", GS:GetRootReason() or "not_ready"
    end
    local record = GS._root.guilds[op.guildKey]
    if type(record) ~= "table" then
        return "rejected", "not_configured"
    end
    if record.activation ~= GS.ACTIVATION_STAGED then
        return "rejected", "unsupported_activation"
    end
    if op.datasetId ~= record.datasetId then
        return "rejected", "dataset_mismatch"
    end

    local ops = record.operations
    local existing = ops.records[op.id]
    if existing then
        if DeepEqual(existing, PublicOpCopy(op)) then
            return "duplicate", "duplicate"
        end
        -- Same ID, different body: retain conflict; do not replace.
        RetainConflict(ops, PublicOpCopy(op))
        return "rejected", "id_conflict"
    end
    if ops.conflicts[op.id] then
        return "rejected", "id_conflict"
    end

    -- Capacity checks before mutation.
    if AcceptedCount(ops) >= GS.MAX_ACCEPTED_OPERATIONS then
        return "rejected", "full"
    end

    local valid, verr = GS:ValidateConfigOperation(op, context)
    if not valid then
        if verr == "stale_base" then
            if PendingCount(ops) >= GS.MAX_PENDING_OPERATIONS then
                return "rejected", "full"
            end
            RetainPending(ops, PublicOpCopy(op), verr)
            return "pending", verr
        end
        return "rejected", verr or "unauthorized"
    end

    local tKey = TargetKey(op.kind, op.target)
    local applied, applyErr = ApplyMutations(record, op)
    if not applied then
        return "rejected", applyErr or "apply_failed"
    end
    StoreAccepted(ops, op, tKey)
    return "accepted", nil
end

---------------------------------------------------------------------------
-- Confirmation operations (local validation / staged storage only)
---------------------------------------------------------------------------

local function ValidateCandidateRef(ref)
    if type(ref) ~= "table" then
        return false, "invalid_candidate_ref"
    end
    if type(ref.contentFingerprint) ~= "string" or ref.contentFingerprint == "" then
        return false, "invalid_fingerprint"
    end
    if ref.recordId ~= nil then
        if type(ref.recordId) ~= "string" or ref.recordId == "" then
            return false, "invalid_candidate_ref"
        end
        return true
    end
    if type(ref.records) == "table" then
        local n = #ref.records
        if n < 1 or n > GS.MAX_CONFIRMATION_BATCH then
            return false, "invalid_candidate_batch"
        end
        for i = 1, n do
            local row = ref.records[i]
            if type(row) ~= "table" or type(row.id) ~= "string" or row.id == ""
                or type(row.contentFingerprint) ~= "string" or row.contentFingerprint == "" then
                return false, "invalid_candidate_batch"
            end
        end
        return true
    end
    return false, "invalid_candidate_ref"
end

function GS:NewConfirmationOperation(candidateRef)
    local ctx = GS:GetCurrentContext()
    if not ctx or not ctx.ready then
        return nil, "rejected", (ctx and ctx.reason) or "not_ready"
    end
    local caps = GS:GetCapabilities()
    if not caps.canEdit then
        return nil, "rejected", caps.reason or "unauthorized"
    end
    local ok, err = ValidateCandidateRef(candidateRef)
    if not ok then
        return nil, "rejected", err
    end
    -- Candidate's proposed policy cannot authorize the confirmer: confirmer
    -- authority comes from already accepted local policy (checked above).
    if type(candidateRef.proposedEditorRankPosition) == "number" then
        -- Ignored for authorization; retained only as candidate metadata.
    end

    local record, recordReason = GS:GetCurrentRecord()
    if not record then
        return nil, "rejected", recordReason or "not_configured"
    end
    local ts = ServerTime()
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
        kind = KIND.CONFIRM_CANDIDATE,
        candidateRef = {
            recordId = candidateRef.recordId,
            records = candidateRef.records,
            contentFingerprint = candidateRef.contentFingerprint,
            -- Preserve original IDs; do not restamp.
            originalIds = candidateRef.originalIds,
        },
        contentFingerprint = candidateRef.contentFingerprint,
        campaignId = candidateRef.campaignId or record.currentCampaignId,
        basePolicyRevision = CurrentPolicyRevision(record),
        actorGuid = ctx.actorGuid,
        actorName = ctx.actorName,
        timestamp = ts,
        _preparedHandleGeneration = ctx.handleGeneration,
    }
    return op, "accepted", nil
end

function GS:ValidateConfirmationOperation(op, context)
    if type(op) ~= "table" then
        return false, "invalid_operation"
    end
    if tonumber(op.schemaVersion) ~= GS.OP_SCHEMA_VERSION then
        return false, "unsupported_schema"
    end
    if op.kind ~= KIND.CONFIRM_CANDIDATE then
        return false, "invalid_kind"
    end
    if type(op.id) ~= "string" or op.id == "" then
        return false, "invalid_id"
    end
    local guildKey = GS.ParseGuildKey(op.guildKey)
    if not guildKey then
        return false, "invalid_guild_key"
    end
    local ok, err = ValidateCandidateRef(op.candidateRef or {
        recordId = op.candidateRef and op.candidateRef.recordId,
        contentFingerprint = op.contentFingerprint,
        records = op.candidateRef and op.candidateRef.records,
    })
    if not ok then
        -- Fallback: top-level fingerprint + candidateRef table
        ok, err = ValidateCandidateRef(op.candidateRef)
        if not ok then
            return false, err
        end
    end
    if type(op.contentFingerprint) ~= "string" or op.contentFingerprint == "" then
        return false, "invalid_fingerprint"
    end
    if op.candidateRef and op.candidateRef.contentFingerprint
        and op.candidateRef.contentFingerprint ~= op.contentFingerprint then
        return false, "fingerprint_mismatch"
    end

    context = context or GS:GetCurrentContext()
    if not context or not context.ready then
        return false, (context and context.reason) or "not_ready"
    end
    if op.guildKey ~= context.guildKey then
        return false, "wrong_guild"
    end
    if op.actorGuid ~= context.actorGuid then
        return false, "unauthorized"
    end

    local caps = GS:GetCapabilities()
    if not caps.canEdit then
        return false, caps.reason or "unauthorized"
    end

    local record = GS._root and GS._root.guilds and GS._root.guilds[op.guildKey]
    if type(record) ~= "table" then
        return false, "not_configured"
    end
    if op.datasetId ~= record.datasetId then
        return false, "dataset_mismatch"
    end
    if op.basePolicyRevision ~= CurrentPolicyRevision(record) then
        return false, "stale_base"
    end
    return true
end

--- Staged admission for a confirmation op (does not credit donations).
function GS:ApplyStagedConfirmationOperation(op, context)
    local prepared = {
        guildKey = op and op.guildKey,
        actorGuid = op and op.actorGuid,
        handleGeneration = op and op._preparedHandleGeneration,
    }
    local authOk, authReason, fresh = GS:_AuthorizeCommit(prepared)
    if not authOk then
        return "rejected", authReason or "unauthorized"
    end
    context = fresh or context
    local valid, verr = GS:ValidateConfirmationOperation(op, context)
    if not valid then
        return "rejected", verr
    end
    local record = GS._root.guilds[op.guildKey]
    local ops = record.operations
    local stored = PublicOpCopy(op)
    if ops.records[op.id] then
        if DeepEqual(ops.records[op.id], stored) then
            return "duplicate", "duplicate"
        end
        RetainConflict(ops, stored)
        return "rejected", "id_conflict"
    end
    if AcceptedCount(ops) >= GS.MAX_ACCEPTED_OPERATIONS then
        return "rejected", "full"
    end
    ops.records[op.id] = stored
    ops.order[#ops.order + 1] = op.id
    record.confirmationRefs[#record.confirmationRefs + 1] = op.id
    return "accepted", nil
end
