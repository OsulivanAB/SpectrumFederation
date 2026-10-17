-- Guild Supplies staged operations, IDs, and confirmation contracts (#385).
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

GS.OP_SCHEMA_VERSION = 1
GS.MAX_BANK_TAB = 8
-- Node/string budgets sized for MAX_CONFIRMATION_BATCH (64) records + originalIds
-- plus the confirmation envelope. Do not raise the 2 KiB transport export cap.
GS.MAX_SNAPSHOT_DEPTH = 6
GS.MAX_SNAPSHOT_NODES = 1024
GS.MAX_SNAPSHOT_STRING_BYTES = 49152

local KIND = {
    SET_EDITOR_RANK = "set-editor-rank",
    SET_BANK_TAB = "set-bank-tab",
    SET_REQUESTED_ITEM = "set-requested-item",
    CONFIRM_CANDIDATE = "confirm-candidate",
    START_CAMPAIGN = "start-campaign",
    RESOLVE_CONFLICT = "resolve-conflict",
}

GS.KIND = KIND

-- Public durable fields only; private "_" prepare metadata is never retained.
local CONFIG_SNAPSHOT_FIELDS = {
    "schemaVersion", "id", "guildKey", "datasetId", "campaignId", "kind",
    "target", "value", "actorGuid", "actorName", "timestamp",
    "baseTargetRevision", "basePolicyRevision", "baseCampaignId",
}
-- resolve-conflict reuses CONFIG_SNAPSHOT_FIELDS; value carries competing IDs + choice.
local CONFIRM_SNAPSHOT_FIELDS = {
    "schemaVersion", "id", "guildKey", "datasetId", "kind", "candidateRef",
    "contentFingerprint", "campaignId", "basePolicyRevision",
    "actorGuid", "actorName", "timestamp",
}
local CANDIDATE_REF_FIELDS = {
    "recordId", "records", "contentFingerprint", "originalIds", "campaignId",
}
-- Documented confirmation manifest row fields only (no nested extras).
local MANIFEST_ROW_FIELDS = { "id", "contentFingerprint" }

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
    if depth > GS.MAX_SNAPSHOT_DEPTH then
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

local function ChargeSnapshot(budget, amount)
    budget.n = budget.n + (amount or 1)
    if budget.n > GS.MAX_SNAPSHOT_NODES then
        return false, "snapshot_too_large"
    end
    return true
end

local function ChargeSnapshotString(budget, s)
    local ok, err = ChargeSnapshot(budget, 1)
    if not ok then
        return false, err
    end
    budget.stringBytes = budget.stringBytes + #s
    if budget.stringBytes > GS.MAX_SNAPSHOT_STRING_BYTES then
        return false, "snapshot_string_too_large"
    end
    return true
end

--- Bounded deep snapshot. Counts tables and scalar leaves; bounds string bytes.
-- Private "_" keys are skipped. Rejects cycles / oversize without partial return.
-- @return copy|nil, err|nil
local function DeepSnapshot(value, depth, seen, budget)
    depth = depth or 0
    seen = seen or {}
    budget = budget or { n = 0, stringBytes = 0 }
    local t = type(value)
    if t == "nil" or t == "boolean" then
        local ok, err = ChargeSnapshot(budget, 1)
        if not ok then
            return nil, err
        end
        return value
    end
    if t == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return nil, "invalid_snapshot_number"
        end
        local ok, err = ChargeSnapshot(budget, 1)
        if not ok then
            return nil, err
        end
        return value
    end
    if t == "string" then
        local ok, err = ChargeSnapshotString(budget, value)
        if not ok then
            return nil, err
        end
        return value
    end
    if t ~= "table" then
        return nil, "invalid_snapshot_type"
    end
    if depth >= GS.MAX_SNAPSHOT_DEPTH then
        return nil, "snapshot_too_deep"
    end
    if seen[value] then
        return nil, "snapshot_cycle"
    end
    local ok, err = ChargeSnapshot(budget, 1)
    if not ok then
        return nil, err
    end
    seen[value] = true
    local copy = {}
    for k, v in pairs(value) do
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then
            seen[value] = nil
            return nil, "invalid_snapshot_key"
        end
        if kt == "string" and k:sub(1, 1) == "_" then
            -- Prepare-only metadata; never durable.
        else
            if kt == "string" then
                ok, err = ChargeSnapshotString(budget, k)
            else
                ok, err = ChargeSnapshot(budget, 1)
            end
            if not ok then
                seen[value] = nil
                return nil, err
            end
            local child
            child, err = DeepSnapshot(v, depth + 1, seen, budget)
            if err then
                seen[value] = nil
                return nil, err
            end
            copy[k] = child
        end
    end
    seen[value] = nil
    return copy
end

--- Canonical confirmation manifest row: only id + contentFingerprint.
local function SnapshotCanonicalRecords(records, budget)
    if type(records) ~= "table" then
        return nil, "invalid_candidate_batch"
    end
    local n = #records
    if n < 1 or n > GS.MAX_CONFIRMATION_BATCH then
        return nil, "invalid_candidate_batch"
    end
    local ok, err = ChargeSnapshot(budget, 1)
    if not ok then
        return nil, err
    end
    local copy = {}
    local counted = 0
    for k, row in pairs(records) do
        counted = counted + 1
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > n then
            return nil, "invalid_candidate_batch"
        end
        ok, err = ChargeSnapshot(budget, 1) -- numeric key
        if not ok then
            return nil, err
        end
        if type(row) ~= "table" then
            return nil, "invalid_candidate_batch"
        end
        ok, err = ChargeSnapshot(budget, 1) -- row table
        if not ok then
            return nil, err
        end
        local rowCopy = {}
        for i = 1, #MANIFEST_ROW_FIELDS do
            local rf = MANIFEST_ROW_FIELDS[i]
            local value = row[rf]
            if value == nil then
                return nil, "invalid_candidate_batch"
            end
            ok, err = ChargeSnapshotString(budget, rf)
            if not ok then
                return nil, err
            end
            local child
            child, err = DeepSnapshot(value, 1, {}, budget)
            if err then
                return nil, err
            end
            rowCopy[rf] = child
        end
        copy[k] = rowCopy
    end
    if counted ~= n then
        return nil, "invalid_candidate_batch"
    end
    return copy
end

local function SnapshotWhitelisted(source, fields)
    if type(source) ~= "table" then
        return nil, "invalid_operation"
    end
    local budget = { n = 0, stringBytes = 0 }
    local copy = {}
    local ok, err = ChargeSnapshot(budget, 1)
    if not ok then
        return nil, err
    end
    for i = 1, #fields do
        local field = fields[i]
        local value = source[field]
        if value ~= nil then
            ok, err = ChargeSnapshotString(budget, field)
            if not ok then
                return nil, err
            end
            if field == "candidateRef" and type(value) == "table" then
                local refCopy = {}
                ok, err = ChargeSnapshot(budget, 1)
                if not ok then
                    return nil, err
                end
                for j = 1, #CANDIDATE_REF_FIELDS do
                    local rf = CANDIDATE_REF_FIELDS[j]
                    if value[rf] ~= nil then
                        ok, err = ChargeSnapshotString(budget, rf)
                        if not ok then
                            return nil, err
                        end
                        local child
                        if rf == "records" then
                            child, err = SnapshotCanonicalRecords(value[rf], budget)
                        else
                            child, err = DeepSnapshot(value[rf], 1, {}, budget)
                        end
                        if err then
                            return nil, err
                        end
                        refCopy[rf] = child
                    end
                end
                copy[field] = refCopy
            else
                local child
                child, err = DeepSnapshot(value, 1, {}, budget)
                if err then
                    return nil, err
                end
                copy[field] = child
            end
        end
    end
    return copy
end

local function SnapshotPublicOp(op)
    if type(op) ~= "table" then
        return nil, "invalid_operation"
    end
    if op.kind == KIND.CONFIRM_CANDIDATE then
        return SnapshotWhitelisted(op, CONFIRM_SNAPSHOT_FIELDS)
    end
    return SnapshotWhitelisted(op, CONFIG_SNAPSHOT_FIELDS)
end

--- Canonical requested-item target: { itemId = finite positive integer }.
local function CanonicalItemTarget(target)
    local raw
    if type(target) == "table" then
        raw = target.itemId
    elseif type(target) == "number" or type(target) == "string" then
        raw = target
    else
        return nil
    end
    local itemId = tonumber(raw)
    if not itemId or itemId ~= itemId or itemId == math.huge or itemId == -math.huge then
        return nil
    end
    if itemId ~= math.floor(itemId) or itemId < 1 then
        return nil
    end
    return { itemId = itemId }
end

local function TargetKey(kind, target)
    if kind == KIND.SET_EDITOR_RANK then
        return "permission:editorRankPosition"
    elseif kind == KIND.SET_BANK_TAB then
        return "config:bankTab"
    elseif kind == KIND.SET_REQUESTED_ITEM then
        local canon = CanonicalItemTarget(target)
        if not canon then
            return nil
        end
        return "item:" .. tostring(canon.itemId)
    elseif kind == KIND.START_CAMPAIGN then
        return GS.CAMPAIGN_TARGET_KEY or "campaign:lifecycle"
    elseif kind == KIND.CONFIRM_CANDIDATE then
        return "confirm"
    elseif kind == KIND.RESOLVE_CONFLICT then
        if type(target) == "string" and target ~= "" then
            return target
        end
        if type(target) == "table" and type(target.targetKey) == "string" then
            return target.targetKey
        end
        return nil
    end
    return nil
end

--- Shared target-key helper for durable head validation (State load order is earlier).
function GS.ComputeTargetKey(kind, target)
    return TargetKey(kind, target)
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

--- Prefer records map size; structure validation keeps it consistent with order.
local function AcceptedCount(ops)
    return CountMap(ops.records)
end

local function RetentionBodyCount(ops)
    return CountMap(ops.pending) + CountMap(ops.conflicts)
end

--- Shared 128 pending/conflict-body budget. Existing ID retries reuse a slot.
local function CanRetainBody(ops, store, id)
    if type(store) == "table" and store[id] ~= nil then
        return true
    end
    return RetentionBodyCount(ops) < GS.MAX_PENDING_OPERATIONS
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
    if type(record.permission) == "table" and type(record.permission.revisionId) == "string"
        and record.permission.revisionId ~= "" then
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
    local canon = CanonicalItemTarget(value)
    if not canon then
        return nil, "invalid_item_id"
    end
    local goal = tonumber(value.goal)
    local C = SF.Consumables
    local maxGoal = (C and C.MAX_GOAL) or 100000
    local maxItems = (C and C.MAX_REQUESTED_ITEMS) or 256
    if not goal or goal ~= goal or goal ~= math.floor(goal) or goal < 0 or goal > maxGoal then
        return nil, "invalid_goal"
    end
    return {
        itemId = canon.itemId,
        goal = goal,
        removed = false,
    }, nil, maxItems
end

--- Dense-array originalIds: every entry must be a nonempty bounded string.
local function ValidateOriginalIds(originalIds)
    if originalIds == nil then
        return true
    end
    if type(originalIds) ~= "table" then
        return false, "invalid_candidate_ref"
    end
    local n = #originalIds
    if n > GS.MAX_CONFIRMATION_BATCH then
        return false, "invalid_candidate_batch"
    end
    local counted = 0
    for k, v in pairs(originalIds) do
        counted = counted + 1
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > n then
            return false, "invalid_candidate_ref"
        end
        if type(v) ~= "string" or v == "" or #v > GS.MAX_OPERATION_ID then
            return false, "invalid_candidate_ref"
        end
    end
    if counted ~= n then
        return false, "invalid_candidate_ref"
    end
    return true
end

--- Explicit nil clears; only finite integral tabs 1..MAX are otherwise valid.
-- Does not coerce non-numeric values to the clear sentinel.
local function IsValidBankTab(tab)
    if tab == nil then
        return true
    end
    if type(tab) ~= "number" then
        return false
    end
    return tab == math.floor(tab) and tab >= 1 and tab <= GS.MAX_BANK_TAB
        and tab == tab and tab ~= math.huge
end

--- Convert constructor bank-tab input. Explicit nil clears; failed conversions reject.
local function CoerceBankTabValue(value)
    if value == nil then
        return nil
    end
    local converted
    if type(value) == "number" then
        converted = value
    elseif type(value) == "string" then
        converted = tonumber(value)
        if converted == nil then
            return nil, "invalid_bank_tab"
        end
    else
        return nil, "invalid_bank_tab"
    end
    if not IsValidBankTab(converted) then
        return nil, "invalid_bank_tab"
    end
    return converted
end

local function CanonicalRequestedItemValue(value)
    local normalized, err = NormalizeRequestedItemValue(value)
    if not normalized then
        return nil, err
    end
    if normalized.removed then
        return { removed = true }
    end
    return {
        itemId = normalized.itemId,
        goal = normalized.goal,
        removed = false,
    }
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
    if not GS.IsFiniteNonnegInt(op.timestamp) then
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
        if not IsValidBankTab(op.value) then
            return false, "invalid_bank_tab"
        end
        return true
    elseif kind == KIND.SET_REQUESTED_ITEM then
        local canon = CanonicalItemTarget(op.target)
        if not canon then
            return false, "invalid_target"
        end
        -- Require canonical table shape so validate/apply agree.
        if type(op.target) ~= "table" or tonumber(op.target.itemId) ~= canon.itemId then
            return false, "invalid_target"
        end
        local normalized, err = NormalizeRequestedItemValue(op.value)
        if not normalized then
            return false, err
        end
        if normalized.removed ~= true and normalized.itemId ~= canon.itemId then
            return false, "item_id_mismatch"
        end
        return true
    elseif kind == KIND.START_CAMPAIGN then
        return false, "use_campaign_api"
    elseif kind == KIND.CONFIRM_CANDIDATE then
        return false, "use_confirmation_api"
    end
    return false, "unsupported_kind"
end

local function ResolveStagedRecord(guildKey, kind)
    local record, recordReason = GS:GetCurrentRecord()
    if record then
        return record, nil, false
    end
    if kind == KIND.SET_EDITOR_RANK and GS._IsPermissionOnlyFailure(recordReason) then
        local raw, rawReason = GS:_GetPolicyRecoveryRecord(guildKey)
        if raw then
            return raw, rawReason, true
        end
        return nil, recordReason or rawReason, false
    end
    return nil, recordReason or "not_configured", false
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

    if kind ~= KIND.SET_EDITOR_RANK and kind ~= KIND.SET_BANK_TAB and kind ~= KIND.SET_REQUESTED_ITEM then
        return nil, "rejected", "unsupported_kind"
    end

    local record, recordReason, recovery = ResolveStagedRecord(ctx.guildKey, kind)
    if not record then
        return nil, "rejected", recordReason or "not_configured"
    end

    local requireRecover = recovery and true or false
    local caps = GS:GetCapabilities()
    if kind == KIND.SET_EDITOR_RANK then
        local policyPos = type(record.permission) == "table"
            and tonumber(record.permission.editorRankPosition) or nil
        local rankCount = ctx.rankCount
        local policyOk = policyPos and rankCount and policyPos >= 1 and policyPos <= rankCount
            and type(record.permission) == "table"
            and type(record.permission.revisionId) == "string"
            and record.permission.revisionId ~= ""
        if recovery or not policyOk then
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
        -- Campaign-owned items require an active current campaign (#386).
        if type(record.currentCampaignId) ~= "string" or record.currentCampaignId == "" then
            return nil, "rejected", "no_campaign"
        end
        local canon = CanonicalItemTarget(target)
        if not canon then
            return nil, "rejected", "invalid_target"
        end
        target = canon
        local normalized, err = CanonicalRequestedItemValue(value)
        if not normalized then
            return nil, "rejected", err
        end
        value = normalized
    elseif kind == KIND.SET_EDITOR_RANK then
        target = "editorRankPosition"
        value = tonumber(value)
    elseif kind == KIND.SET_BANK_TAB then
        target = "bankTab"
        local coerced, coerceErr = CoerceBankTabValue(value)
        if coerceErr then
            return nil, "rejected", coerceErr
        end
        value = coerced
    end

    local tKey = TargetKey(kind, target)
    if not tKey then
        return nil, "rejected", "invalid_target"
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
        kind = kind,
        target = target,
        value = value,
        actorGuid = ctx.actorGuid,
        actorName = ctx.actorName,
        timestamp = ts,
        baseTargetRevision = CurrentTargetRevision(record, tKey),
        basePolicyRevision = CurrentPolicyRevision(record),
        baseCampaignId = record.currentCampaignId,
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
    -- Bind attribution to verified native context before any retention.
    if op.actorName ~= context.actorName then
        return false, "unauthorized"
    end

    local record, _, recovery = ResolveStagedRecord(op.guildKey, op.kind)
    if not record then
        return false, "not_configured"
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
    if (op.campaignId or nil) ~= (currentCampaign or nil) then
        return false, "stale_base"
    end

    local tKey = TargetKey(op.kind, op.target)
    if not tKey then
        return false, "invalid_target"
    end
    local currentRev = CurrentTargetRevision(record, tKey)
    if op.baseTargetRevision ~= currentRev then
        return false, "stale_base"
    end

    local caps = GS:GetCapabilities()
    if op.kind == KIND.SET_EDITOR_RANK then
        local pos = tonumber(op.value)
        local rankCount = context.rankCount
        if not rankCount or not pos or pos > rankCount then
            return false, "invalid_editor_rank_position"
        end
        local policyPos = type(record.permission) == "table"
            and tonumber(record.permission.editorRankPosition) or nil
        local policyOk = (not recovery) and policyPos and policyPos >= 1 and policyPos <= rankCount
            and type(record.permission.revisionId) == "string" and record.permission.revisionId ~= ""
        if recovery or not policyOk then
            if not caps.canRecoverPolicy then
                return false, caps.reason or "unauthorized"
            end
        else
            if not caps.canEdit then
                return false, caps.reason or "unauthorized"
            end
        end
    else
        if recovery then
            return false, "invalid_permission"
        end
        if not caps.canEdit then
            return false, caps.reason or "unauthorized"
        end
        if op.kind == KIND.SET_REQUESTED_ITEM then
            if type(record.currentCampaignId) ~= "string" or record.currentCampaignId == "" then
                return false, "no_campaign"
            end
        end
    end

    return true
end

--- Retain the first conflict body for an ID as immutable evidence.
-- An existing slot is never replaced by a later divergent body and does not
-- consume another retention slot. Returns false only when capacity is exhausted
-- for a new ID.
local function RetainConflict(ops, op)
    if type(ops) ~= "table" or type(op) ~= "table" or type(op.id) ~= "string" then
        return false
    end
    local existing = ops.conflicts and ops.conflicts[op.id]
    if type(existing) == "table" then
        return true
    end
    if RetentionBodyCount(ops) >= GS.MAX_PENDING_OPERATIONS then
        return false
    end
    ops.conflicts[op.id] = {
        id = op.id,
        kind = op.kind,
        targetKey = TargetKey(op.kind, op.target),
        body = op,
        at = ServerTime() or op.timestamp,
    }
    return true
end

local function RetainPending(ops, op, reason)
    if not CanRetainBody(ops, ops.pending, op.id) then
        return false
    end
    ops.pending[op.id] = {
        id = op.id,
        reason = reason,
        body = op,
        at = ServerTime() or op.timestamp,
    }
    return true
end

--- Same-ID body comparison against pending store before overwrite/accept.
-- @return status, reason  -- "ok" | "duplicate" | "id_conflict" | "full"
local function AdmitPendingOrConflict(ops, stored, reason)
    local pending = ops.pending[stored.id]
    if pending then
        if DeepEqual(pending.body, stored) then
            return "pending", reason or pending.reason or "stale_base"
        end
        -- Different body: preserve original pending; retain conflict if capacity allows.
        if ops.conflicts[stored.id] then
            if DeepEqual(ops.conflicts[stored.id].body, stored) then
                return "rejected", "id_conflict"
            end
            return "rejected", "id_conflict"
        end
        if not RetainConflict(ops, stored) then
            return "rejected", "full"
        end
        return "rejected", "id_conflict"
    end
    if ops.conflicts[stored.id] then
        if DeepEqual(ops.conflicts[stored.id].body, stored) then
            return "rejected", "id_conflict"
        end
        return "rejected", "id_conflict"
    end
    if not RetainPending(ops, stored, reason) then
        return "rejected", "full"
    end
    return "pending", reason
end

local function StoreAccepted(ops, stored, targetKey)
    ops.records[stored.id] = stored
    ops.order[#ops.order + 1] = stored.id
    if targetKey then
        ops.heads[targetKey] = stored.id
    end
    ops.pending[stored.id] = nil
end

local function ApplyMutations(record, op)
    if op.kind == KIND.SET_EDITOR_RANK then
        -- Create permission table only on explicit GM-authorized recovery apply.
        if type(record.permission) ~= "table" then
            record.permission = {}
        end
        record.permission.editorRankPosition = tonumber(op.value)
        record.permission.revisionId = op.id
        return true
    elseif op.kind == KIND.SET_BANK_TAB then
        local cfg = record.accounting._consumables
        if type(cfg.requestedItems) ~= "table" then
            return false, "invalid_accounting"
        end
        local previous = cfg.bankTab
        cfg.bankTab = op.value
        -- Tab change (including clear↔set) establishes cutoff after baseline.
        if previous ~= op.value and GS.NoteTabEligibilityCutoff then
            GS.NoteTabEligibilityCutoff(cfg, op.timestamp)
        end
        return true
    elseif op.kind == KIND.SET_REQUESTED_ITEM then
        local cfg = record.accounting._consumables
        if type(cfg.requestedItems) ~= "table" then
            return false, "invalid_accounting"
        end
        -- Campaign-owned items require an active current campaign (#386).
        if type(record.currentCampaignId) ~= "string" or record.currentCampaignId == "" then
            return false, "no_campaign"
        end
        local canon = CanonicalItemTarget(op.target)
        if not canon then
            return false, "invalid_target"
        end
        local itemId = canon.itemId
        local key = tostring(itemId)
        if type(op.value) == "table" and op.value.removed == true then
            cfg.requestedItems[key] = nil
            -- Removal preserves prior eligibility/history; no cutoff rewrite.
        else
            local C = SF.Consumables
            local maxItems = (C and C.MAX_REQUESTED_ITEMS) or 256
            local isAddOrReadd = cfg.requestedItems[key] == nil
            if isAddOrReadd then
                local count = 0
                for _ in pairs(cfg.requestedItems) do
                    count = count + 1
                    if count >= maxItems then
                        return false, "full"
                    end
                end
            end
            local previousGoal = nil
            if not isAddOrReadd and type(cfg.requestedItems[key]) == "table" then
                previousGoal = tonumber(cfg.requestedItems[key].goal)
            end
            local newGoal = tonumber(op.value.goal) or 0
            cfg.requestedItems[key] = {
                itemId = itemId,
                goal = newGoal,
            }
            -- Add/re-add establishes cutoff; ordinary goal-only edits preserve it.
            if isAddOrReadd and GS.NoteItemEligibilityCutoff then
                GS.NoteItemEligibilityCutoff(cfg, itemId, op.timestamp)
            elseif not isAddOrReadd and previousGoal == newGoal then
                -- Exact same goal: no eligibility change (idempotent field write).
            end
        end
        return true
    end
    return false, "unsupported_kind"
end

--- Exact accepted duplicate within verified current guild/dataset (no edit rank).
-- Changed bodies and pending promotion still require fresh authority.
local function RecognizeExactAcceptedDuplicate(op, stored)
    local ctx = GS:GetCurrentContext()
    if not ctx or not ctx.guildKey or not ctx.membershipReady then
        return nil
    end
    if type(op) ~= "table" or type(stored) ~= "table" or type(op.id) ~= "string" then
        return nil
    end
    if op.guildKey ~= ctx.guildKey then
        return "rejected", "wrong_guild"
    end
    if not GS:IsRootReady() then
        return nil
    end
    local record, reason = GS:GetCurrentRecord()
    if type(record) ~= "table" then
        if reason == "not_configured" then
            return nil
        end
        -- Permission-only recovery records are not exposed here; fall through.
        return nil
    end
    if op.datasetId ~= record.datasetId then
        return "rejected", "dataset_mismatch"
    end
    local existing = record.operations.records[op.id]
    if existing and DeepEqual(existing, stored) then
        return "duplicate", "duplicate"
    end
    return nil
end

function GS:ApplyStagedConfigOperation(op, context)
    if type(op) ~= "table" then
        return "rejected", "invalid_operation"
    end

    local shapeOk, shapeErr = ValidateConfigShape(op)
    if not shapeOk then
        return "rejected", shapeErr
    end

    if op.kind == KIND.SET_REQUESTED_ITEM then
        local canon = CanonicalItemTarget(op.target)
        if not canon then
            return "rejected", "invalid_target"
        end
        op.target = canon
        -- Canonicalize value before snapshot/projection/duplicate comparison so
        -- caller-added nested extras cannot poison DeepEqual vs durable bodies.
        local normalized, normErr = CanonicalRequestedItemValue(op.value)
        if not normalized then
            return "rejected", normErr or "invalid_item_value"
        end
        op.value = normalized
    elseif op.kind == KIND.SET_BANK_TAB then
        local coerced, coerceErr = CoerceBankTabValue(op.value)
        if coerceErr then
            return "rejected", coerceErr
        end
        op.value = coerced
    end

    local kindOk, kindErr = ValidateKindValue(op)
    if not kindOk then
        return "rejected", kindErr
    end

    local stored, snapErr = SnapshotPublicOp(op)
    if not stored then
        return "rejected", snapErr or "invalid_operation"
    end

    local dupStatus, dupReason = RecognizeExactAcceptedDuplicate(op, stored)
    if dupStatus then
        return dupStatus, dupReason
    end

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
    if op.actorName ~= context.actorName then
        return "rejected", "unauthorized"
    end

    if not GS:IsRootReady() then
        return "rejected", GS:GetRootReason() or "not_ready"
    end

    local record, resolveReason, recovery = ResolveStagedRecord(op.guildKey, op.kind)
    if type(record) ~= "table" then
        return "rejected", resolveReason or "not_configured"
    end
    if record.activation ~= GS.ACTIVATION_STAGED then
        return "rejected", "unsupported_activation"
    end
    if op.datasetId ~= record.datasetId then
        return "rejected", "dataset_mismatch"
    end
    if recovery and op.kind ~= KIND.SET_EDITOR_RANK then
        return "rejected", "invalid_permission"
    end

    local ops = record.operations
    local existing = ops.records[op.id]
    if existing then
        if DeepEqual(existing, stored) then
            return "duplicate", "duplicate"
        end
        if not RetainConflict(ops, stored) then
            return "rejected", "full"
        end
        return "rejected", "id_conflict"
    end

    -- Pending before conflicts: exact retry of the original pending body stays
    -- idempotent even when a divergent same-ID body was retained as a conflict.
    if ops.pending[op.id] then
        if DeepEqual(ops.pending[op.id].body, stored) then
            local validRetry, verrRetry = GS:ValidateConfigOperation(op, context)
            if validRetry then
                -- Same body, now valid: fall through to accept below.
            else
                if verrRetry == "stale_base" then
                    return "pending", verrRetry
                end
                return "rejected", verrRetry or "unauthorized"
            end
        else
            if not RetainConflict(ops, stored) then
                return "rejected", "full"
            end
            return "rejected", "id_conflict"
        end
    elseif ops.conflicts[op.id] then
        return "rejected", "id_conflict"
    end

    if AcceptedCount(ops) >= GS.MAX_ACCEPTED_OPERATIONS then
        return "rejected", "full"
    end

    local valid, verr = GS:ValidateConfigOperation(op, context)
    if not valid then
        if verr == "stale_base" then
            local status, reason = AdmitPendingOrConflict(ops, stored, verr)
            return status, reason
        end
        return "rejected", verr or "unauthorized"
    end

    local tKey = TargetKey(op.kind, stored.target)
    local applied, applyErr = ApplyMutations(record, stored)
    if not applied then
        return "rejected", applyErr or "apply_failed"
    end
    StoreAccepted(ops, stored, tKey)
    GS._NotifyLocalDurableChange("config")
    return "accepted", nil
end

---------------------------------------------------------------------------
-- Confirmation operations (local validation / staged storage only)
---------------------------------------------------------------------------

local function ValidateCandidateRef(ref)
    if type(ref) ~= "table" then
        return false, "invalid_candidate_ref"
    end
    if type(ref.contentFingerprint) ~= "string" or ref.contentFingerprint == ""
        or #ref.contentFingerprint > GS.MAX_OPERATION_ID then
        return false, "invalid_fingerprint"
    end
    -- Exactly one reference form: single recordId XOR bounded records manifest.
    local hasRecordId = ref.recordId ~= nil
    local hasRecords = ref.records ~= nil
    if hasRecordId == hasRecords then
        return false, "invalid_candidate_ref"
    end
    if ref.campaignId ~= nil then
        if type(ref.campaignId) ~= "string" or ref.campaignId == "" then
            return false, "invalid_candidate_ref"
        end
    end
    if hasRecordId then
        if type(ref.recordId) ~= "string" or ref.recordId == ""
            or #ref.recordId > GS.MAX_OPERATION_ID then
            return false, "invalid_candidate_ref"
        end
        local idsOk, idsErr = ValidateOriginalIds(ref.originalIds)
        if not idsOk then
            return false, idsErr
        end
        return true
    end
    if type(ref.records) ~= "table" then
        return false, "invalid_candidate_ref"
    end
    local n = #ref.records
    if n < 1 or n > GS.MAX_CONFIRMATION_BATCH then
        return false, "invalid_candidate_batch"
    end
    local counted = 0
    for k, row in pairs(ref.records) do
        counted = counted + 1
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > n then
            return false, "invalid_candidate_batch"
        end
        if type(row) ~= "table" or type(row.id) ~= "string" or row.id == ""
            or #row.id > GS.MAX_OPERATION_ID
            or type(row.contentFingerprint) ~= "string" or row.contentFingerprint == ""
            or #row.contentFingerprint > GS.MAX_OPERATION_ID then
            return false, "invalid_candidate_batch"
        end
    end
    if counted ~= n then
        return false, "invalid_candidate_batch"
    end
    local idsOk, idsErr = ValidateOriginalIds(ref.originalIds)
    if not idsOk then
        return false, idsErr
    end
    return true
end

local function ValidateConfirmationShape(op)
    if type(op) ~= "table" then
        return false, "invalid_operation"
    end
    if tonumber(op.schemaVersion) ~= GS.OP_SCHEMA_VERSION then
        return false, "unsupported_schema"
    end
    if op.kind ~= KIND.CONFIRM_CANDIDATE then
        return false, "invalid_kind"
    end
    if type(op.id) ~= "string" or op.id == "" or #op.id > GS.MAX_OPERATION_ID then
        return false, "invalid_id"
    end
    if not GS.ParseGuildKey(op.guildKey) then
        return false, "invalid_guild_key"
    end
    if type(op.datasetId) ~= "string" or op.datasetId == "" then
        return false, "invalid_dataset_id"
    end
    if type(op.actorGuid) ~= "string" or op.actorGuid == "" then
        return false, "invalid_actor"
    end
    if type(op.actorName) ~= "string" or op.actorName == "" then
        return false, "invalid_actor"
    end
    if not GS.IsFiniteNonnegInt(op.timestamp) then
        return false, "invalid_timestamp"
    end
    if type(op.basePolicyRevision) ~= "string" or op.basePolicyRevision == "" then
        return false, "invalid_base_policy"
    end
    if op.campaignId ~= nil and type(op.campaignId) ~= "string" then
        return false, "invalid_campaign"
    end
    if type(op.contentFingerprint) ~= "string" or op.contentFingerprint == ""
        or #op.contentFingerprint > GS.MAX_OPERATION_ID then
        return false, "invalid_fingerprint"
    end
    local ok, err = ValidateCandidateRef(op.candidateRef)
    if not ok then
        return false, err
    end
    if op.candidateRef.contentFingerprint ~= op.contentFingerprint then
        return false, "fingerprint_mismatch"
    end
    -- Nested candidate campaign ID, when present, must match the envelope.
    if op.candidateRef.campaignId ~= nil and op.candidateRef.campaignId ~= op.campaignId then
        return false, "invalid_campaign"
    end
    return true
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

    -- Preserve candidate campaign identity; do not blanket-assign current.
    local campaignId = candidateRef.campaignId
    if campaignId == nil then
        campaignId = record.currentCampaignId
    end

    local snapShell, snapErr = SnapshotWhitelisted({
        kind = KIND.CONFIRM_CANDIDATE,
        candidateRef = {
            recordId = candidateRef.recordId,
            records = candidateRef.records,
            contentFingerprint = candidateRef.contentFingerprint,
            originalIds = candidateRef.originalIds,
            campaignId = candidateRef.campaignId,
        },
    }, { "candidateRef" })
    if not snapShell or type(snapShell.candidateRef) ~= "table" then
        return nil, "rejected", snapErr or "invalid_candidate_ref"
    end
    local snapRef = snapShell.candidateRef

    local op = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = id,
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        kind = KIND.CONFIRM_CANDIDATE,
        candidateRef = snapRef,
        contentFingerprint = candidateRef.contentFingerprint,
        campaignId = campaignId,
        basePolicyRevision = CurrentPolicyRevision(record),
        actorGuid = ctx.actorGuid,
        actorName = ctx.actorName,
        timestamp = ts,
        _preparedHandleGeneration = ctx.handleGeneration,
    }
    -- Complete-envelope check at prepare (same whitelist/budgets as admission).
    local shapeOk, shapeErr = ValidateConfirmationShape(op)
    if not shapeOk then
        return nil, "rejected", shapeErr
    end
    local stored, snapErr = SnapshotPublicOp(op)
    if not stored then
        return nil, "rejected", snapErr or "invalid_operation"
    end
    return op, "accepted", nil
end

--- Pure historical shape validation for accepted SavedVariables bodies.
-- Reuses config/confirmation shape + kind-value checks without current-authority
-- or current-revision admission. Safe for ValidateGuildRecord (no GetCurrentRecord).
-- @param body table
-- @param guildKey string|nil owning guild key when known
-- @param datasetId string|nil owning dataset id when known
-- @return boolean ok, string|nil reason
function GS.ValidateAcceptedOperationBody(body, guildKey, datasetId)
    if type(body) ~= "table" then
        return false, "invalid_operations"
    end
    if type(body.id) ~= "string" or body.id == "" or #body.id > GS.MAX_OPERATION_ID then
        return false, "invalid_operations"
    end
    local kind = body.kind
    if kind == KIND.CONFIRM_CANDIDATE then
        local ok, err = ValidateConfirmationShape(body)
        if not ok then
            return false, err or "invalid_operations"
        end
    elseif kind == KIND.START_CAMPAIGN then
        if GS.ValidateCampaignOperationBody then
            local ok, err = GS.ValidateCampaignOperationBody(body, guildKey, datasetId)
            if not ok then
                return false, err or "invalid_operations"
            end
        else
            return false, "unsupported_kind"
        end
        return true
    elseif kind == KIND.SET_EDITOR_RANK or kind == KIND.SET_BANK_TAB or kind == KIND.SET_REQUESTED_ITEM then
        local ok, err = ValidateConfigShape(body)
        if not ok then
            return false, err or "invalid_operations"
        end
        ok, err = ValidateKindValue(body)
        if not ok then
            return false, err or "invalid_operations"
        end
    elseif kind == KIND.RESOLVE_CONFLICT then
        local ok, err = ValidateConfigShape(body)
        if not ok then
            return false, err or "invalid_operations"
        end
        if type(body.target) ~= "string" or body.target == "" then
            return false, "invalid_target"
        end
        if type(body.value) ~= "table" or type(body.value.chosenOpId) ~= "string"
            or body.value.chosenOpId == "" then
            return false, "invalid_resolution"
        end
    else
        return false, "unsupported_kind"
    end
    if guildKey ~= nil then
        if type(body.guildKey) ~= "string" or body.guildKey ~= guildKey then
            return false, "wrong_guild"
        end
    end
    if datasetId ~= nil then
        if type(body.datasetId) ~= "string" or body.datasetId ~= datasetId then
            return false, "dataset_mismatch"
        end
    end
    return true
end

function GS:ValidateConfirmationOperation(op, context)
    local ok, err = ValidateConfirmationShape(op)
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
    -- Caller-supplied attribution cannot replace current native authority.
    if op.actorGuid ~= context.actorGuid then
        return false, "unauthorized"
    end
    if op.actorName ~= context.actorName then
        return false, "unauthorized"
    end

    local caps = GS:GetCapabilities()
    if not caps.canEdit then
        return false, caps.reason or "unauthorized"
    end

    local record = GS:GetCurrentRecord()
    if type(record) ~= "table" then
        return false, "not_configured"
    end
    if op.datasetId ~= record.datasetId then
        return false, "dataset_mismatch"
    end
    if op.basePolicyRevision ~= CurrentPolicyRevision(record) then
        return false, "stale_base"
    end
    -- Bind confirmation to the campaign current at admission time.
    if (op.campaignId or nil) ~= (record.currentCampaignId or nil) then
        return false, "stale_base"
    end
    return true
end

--- Staged admission for a confirmation op (does not credit donations).
function GS:ApplyStagedConfirmationOperation(op, context)
    if type(op) ~= "table" then
        return "rejected", "invalid_operation"
    end

    local shapeOk, shapeErr = ValidateConfirmationShape(op)
    if not shapeOk then
        return "rejected", shapeErr
    end

    local stored, snapErr = SnapshotPublicOp(op)
    if not stored then
        return "rejected", snapErr or "invalid_operation"
    end

    local dupStatus, dupReason = RecognizeExactAcceptedDuplicate(op, stored)
    if dupStatus then
        return dupStatus, dupReason
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

    local valid, verr = GS:ValidateConfirmationOperation(op, context)
    if not valid then
        if verr == "stale_base" then
            local record = GS._root and GS._root.guilds and GS._root.guilds[op.guildKey]
            if type(record) ~= "table" then
                return "rejected", "not_configured"
            end
            local ops = record.operations
            if ops.records[op.id] then
                if DeepEqual(ops.records[op.id], stored) then
                    return "duplicate", "duplicate"
                end
                if not RetainConflict(ops, stored) then
                    return "rejected", "full"
                end
                return "rejected", "id_conflict"
            end
            local status, reason = AdmitPendingOrConflict(ops, stored, verr)
            return status, reason
        end
        return "rejected", verr
    end

    local record = GS:GetCurrentRecord()
    if type(record) ~= "table" then
        return "rejected", "not_configured"
    end
    local ops = record.operations

    if ops.records[op.id] then
        if DeepEqual(ops.records[op.id], stored) then
            return "duplicate", "duplicate"
        end
        if not RetainConflict(ops, stored) then
            return "rejected", "full"
        end
        return "rejected", "id_conflict"
    end
    if ops.pending[op.id] then
        if DeepEqual(ops.pending[op.id].body, stored) then
            -- Exact retry: fall through to accept (validation already passed).
        else
            if not RetainConflict(ops, stored) then
                return "rejected", "full"
            end
            return "rejected", "id_conflict"
        end
    elseif ops.conflicts[op.id] then
        return "rejected", "id_conflict"
    end

    if AcceptedCount(ops) >= GS.MAX_ACCEPTED_OPERATIONS then
        return "rejected", "full"
    end

    StoreAccepted(ops, stored, nil)
    -- confirmationRefs stores IDs only; do not rewrite campaign associations.
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
    GS._NotifyLocalDurableChange("confirm")
    return "accepted", nil
end

---------------------------------------------------------------------------
-- Cross-module helpers for Campaigns.lua (same GS table; no globals)
---------------------------------------------------------------------------

function GS._SnapshotPublicOp(op)
    return SnapshotPublicOp(op)
end

function GS._DeepEqualOps(a, b)
    return DeepEqual(a, b)
end

function GS._RetainConflict(ops, op)
    return RetainConflict(ops, op)
end

function GS._AdmitPendingOrConflict(ops, stored, reason)
    return AdmitPendingOrConflict(ops, stored, reason)
end

function GS._StoreAccepted(ops, stored, targetKey)
    return StoreAccepted(ops, stored, targetKey)
end

function GS._RecognizeExactAcceptedDuplicate(op, stored)
    return RecognizeExactAcceptedDuplicate(op, stored)
end

function GS._ApplyMutations(record, op)
    return ApplyMutations(record, op)
end

function GS._RetainPending(ops, op, reason)
    return RetainPending(ops, op, reason)
end

function GS._AcceptedCount(ops)
    return AcceptedCount(ops)
end

function GS._TargetKey(kind, target)
    return TargetKey(kind, target)
end

--- Notify gossip after a durable local staged write (no-op until provider registers).
function GS._NotifyLocalDurableChange(reason)
    if GS.NotifyLocalDurableChange then
        GS.NotifyLocalDurableChange(reason)
    end
end
