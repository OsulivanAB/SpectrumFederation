-- Guild Supplies staged foundation — durable state (#385 Part 2A).
-- Live authoritative writer remains legacy profile-scoped Consumables.
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

GS.SCHEMA_VERSION = 1
GS.ACTIVATION_STAGED = "staged"
GS.DEFAULT_EDITOR_RANK_POSITION = 3
GS.MAX_ACCEPTED_OPERATIONS = 4096
GS.MAX_PENDING_OPERATIONS = 128
GS.MAX_OPERATION_ID = 192
GS.MAX_EVENT_SEQ = 2147483647
GS.MAX_CONFIRMATION_BATCH = 64

GS._db = nil
GS._root = nil
GS._rootValid = false
GS._rootReason = "not_initialized"
GS._handleGeneration = 0
GS._lastGuildKey = nil

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

local function Rand31()
    -- Three 31-bit chunks (repo short-ID pattern). Keep non-negative for %08x.
    local n = math.random(0, 0x7fffffff)
    if n < 0 then
        n = -n
    end
    return n % 0x80000000
end

local function NewWriterState()
    return {
        nonce = string.format("%08x%08x%08x", Rand31(), Rand31(), Rand31()),
        nextSeq = 1,
    }
end

--- Persisted writer nonce: exactly 24 lowercase/uppercase hex digits.
local function IsValidWriterNonce(nonce)
    return type(nonce) == "string" and #nonce == 24 and nonce:match("^[0-9a-fA-F]+$") ~= nil
end

local function IsValidWriterState(writer)
    if type(writer) ~= "table" or not IsValidWriterNonce(writer.nonce) then
        return false
    end
    local seq = tonumber(writer.nextSeq)
    return seq and seq == math.floor(seq) and seq >= 1 and seq <= GS.MAX_EVENT_SEQ
end

local function IsBoundedActorString(value)
    return type(value) == "string" and value ~= "" and #value <= GS.MAX_OPERATION_ID
end

local function IsFiniteNonnegInt(value)
    local n = tonumber(value)
    return n and n == math.floor(n) and n >= 0 and n == n and n ~= math.huge
end

--- Shared finite nonnegative-integer check (operation timestamps, campaign fields).
function GS.IsFiniteNonnegInt(value)
    return IsFiniteNonnegInt(value)
end

local function EmptyAccounting(clubId, guildName, guildRealm)
    return {
        _consumables = {
            guild = {
                guid = tostring(clubId),
                name = type(guildName) == "string" and guildName or "",
                realm = type(guildRealm) == "string" and guildRealm or "",
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
    }
end

local function EmptyOperations()
    return {
        records = {},
        order = {},
        heads = {},
        pending = {},
        conflicts = {},
        openConflicts = {}, -- target-key → candidate op ids (#387)
    }
end

function GS._BumpHandleGeneration(reason)
    GS._handleGeneration = (tonumber(GS._handleGeneration) or 0) + 1
    DebugInfo("handle generation=%d reason=%s", GS._handleGeneration, tostring(reason or "unknown"))
end

function GS.GetHandleGeneration()
    return tonumber(GS._handleGeneration) or 0
end

--- Parse and validate a durable guild key. Rejects name: transport fallbacks.
-- @return string|nil guildKey, string|nil clubId, string|nil reason
function GS.ParseGuildKey(guildKey)
    if type(guildKey) ~= "string" or guildKey == "" then
        return nil, nil, "invalid_guild_key"
    end
    local clubId = guildKey:match("^club:(.+)$")
    if not clubId or clubId == "" or clubId == "0" then
        return nil, nil, "unsupported_guild_key"
    end
    if clubId:match("^%s") or clubId:match("%s$") then
        return nil, nil, "unsupported_guild_key"
    end
    return guildKey, clubId, nil
end

local function ValidatePermission(permission)
    if type(permission) ~= "table" then
        return false, "invalid_permission"
    end
    local pos = tonumber(permission.editorRankPosition)
    if not pos or pos ~= math.floor(pos) or pos < 1 then
        return false, "invalid_editor_rank_position"
    end
    if type(permission.revisionId) ~= "string" or permission.revisionId == "" then
        return false, "invalid_permission_revision"
    end
    return true
end

--- Bind current permission to bootstrap datasetId or the accepted policy head.
-- Bootstrap (no permission head): revisionId must equal datasetId.
-- Edited policy: revisionId must be the permission head, naming an accepted
-- set-editor-rank body whose value equals editorRankPosition.
-- Does not infer original rank count from today's roster and does not walk
-- full operation history. Wrong-kind heads that fail ComputeTargetKey remain
-- structural (invalid_operations), not permission-only recovery.
-- @return boolean ok, string|nil reason
local function ValidatePermissionPolicyConsistency(record)
    if type(record) ~= "table" then
        return false, "invalid_permission"
    end
    local permission = record.permission
    local basicOk, basicErr = ValidatePermission(permission)
    if not basicOk then
        return false, basicErr
    end
    local pos = tonumber(permission.editorRankPosition)
    local rev = permission.revisionId
    local datasetId = record.datasetId
    if type(datasetId) ~= "string" or datasetId == "" then
        return false, "invalid_dataset_id"
    end
    local ops = record.operations
    if type(ops) ~= "table" or type(ops.heads) ~= "table" or type(ops.records) ~= "table" then
        return false, "invalid_operations"
    end

    local headKey = "permission:editorRankPosition"
    if type(GS.ComputeTargetKey) == "function" then
        headKey = GS.ComputeTargetKey("set-editor-rank", "editorRankPosition") or headKey
    end
    local headId = ops.heads[headKey]

    if headId == nil then
        -- Untouched bootstrap revision: datasetId is the only valid provenance.
        if rev ~= datasetId then
            return false, "invalid_permission_revision"
        end
        return true
    end

    if type(headId) ~= "string" or headId == "" then
        return false, "invalid_permission_revision"
    end
    if rev ~= headId then
        return false, "invalid_permission_revision"
    end
    local body = ops.records[headId]
    if type(body) ~= "table" then
        return false, "invalid_permission_revision"
    end
    if body.kind ~= "set-editor-rank" then
        return false, "invalid_permission_revision"
    end
    if tonumber(body.value) ~= pos then
        return false, "invalid_permission_revision"
    end
    return true
end

GS.PERMISSION_ONLY_REASONS = {
    invalid_permission = true,
    invalid_editor_rank_position = true,
    invalid_permission_revision = true,
}

local function IsValidBankTabValue(tab)
    if tab == nil then
        return true
    end
    tab = tonumber(tab)
    return tab and tab == math.floor(tab) and tab >= 1 and tab <= 8
end

--- Bounded shape/ID consistency for retained ops. Does not deep-walk bodies.
local function ValidateRetainedAdmissionEntry(id, entry)
    if type(id) ~= "string" or id == "" or #id > GS.MAX_OPERATION_ID then
        return false, "invalid_operations"
    end
    if type(entry) ~= "table" then
        return false, "invalid_operations"
    end
    if entry.id ~= id then
        return false, "invalid_operations"
    end
    if type(entry.body) ~= "table" then
        return false, "invalid_operations"
    end
    if type(entry.body.id) ~= "string" or entry.body.id ~= id then
        return false, "invalid_operations"
    end
    return true
end

local function ValidateOperationsHeads(ops)
    local headCount = 0
    for targetKey, headId in pairs(ops.heads) do
        headCount = headCount + 1
        if headCount > GS.MAX_ACCEPTED_OPERATIONS then
            return false, "invalid_operations"
        end
        if type(targetKey) ~= "string" or targetKey == "" or #targetKey > GS.MAX_OPERATION_ID then
            return false, "invalid_operations"
        end
        if type(headId) ~= "string" or headId == "" or #headId > GS.MAX_OPERATION_ID then
            return false, "invalid_operations"
        end
        local body = ops.records[headId]
        if type(body) ~= "table" then
            return false, "invalid_operations"
        end
        if type(GS.ComputeTargetKey) ~= "function" then
            return false, "invalid_operations"
        end
        local expectedKey = GS.ComputeTargetKey(body.kind, body.target)
        if expectedKey == nil or expectedKey ~= targetKey then
            return false, "invalid_operations"
        end
    end
    return true
end

--- Require ops.order to be a bounded dense array with keys exactly 1..n.
-- Inspects every key (not only 1..#order) so holes / non-integral keys cannot
-- hide ghost entries that later appends would expose. Does not rewrite SV.
-- @return boolean ok, number|nil orderCount, string|nil reason
local function ValidateOperationsOrderDense(order)
    if type(order) ~= "table" then
        return false, nil, "invalid_operations"
    end
    local counted = 0
    local maxKey = 0
    for k, _ in pairs(order) do
        counted = counted + 1
        if counted > GS.MAX_ACCEPTED_OPERATIONS then
            return false, nil, "invalid_operations"
        end
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1
            or k ~= k or k == math.huge then
            return false, nil, "invalid_operations"
        end
        if k > maxKey then
            maxKey = k
        end
    end
    -- Distinct positive integral keys form exactly {1..n} iff maxKey == counted.
    if maxKey ~= counted then
        return false, nil, "invalid_operations"
    end
    return true, counted, nil
end

--- @param ops table
-- @param guildKey string|nil owning guild key for body consistency
-- @param datasetId string|nil owning dataset id for body consistency
local function ValidateOperationsStore(ops, guildKey, datasetId)
    if type(ops) ~= "table" then
        return false, "invalid_operations"
    end
    if type(ops.records) ~= "table" or type(ops.order) ~= "table"
        or type(ops.heads) ~= "table" or type(ops.pending) ~= "table"
        or type(ops.conflicts) ~= "table" then
        return false, "invalid_operations"
    end

    local denseOk, orderCount, denseErr = ValidateOperationsOrderDense(ops.order)
    if not denseOk then
        return false, denseErr or "invalid_operations"
    end
    local seenOrder = {}
    for i = 1, orderCount do
        local id = ops.order[i]
        if type(id) ~= "string" or id == "" or #id > GS.MAX_OPERATION_ID then
            return false, "invalid_operations"
        end
        if seenOrder[id] then
            return false, "invalid_operations"
        end
        seenOrder[id] = true
        local body = ops.records[id]
        if type(body) ~= "table" then
            return false, "invalid_operations"
        end
        if type(body.id) ~= "string" or body.id ~= id then
            return false, "invalid_operations"
        end
        -- Kind-specific historical shape (Operations registers the pure validator).
        -- Avoids current-authority / current-revision admission and GetCurrentRecord.
        if type(GS.ValidateAcceptedOperationBody) == "function" then
            local bodyOk, bodyErr = GS.ValidateAcceptedOperationBody(body, guildKey, datasetId)
            if not bodyOk then
                return false, bodyErr or "invalid_operations"
            end
        end
    end

    local recordCount = 0
    for id, body in pairs(ops.records) do
        recordCount = recordCount + 1
        if recordCount > GS.MAX_ACCEPTED_OPERATIONS then
            return false, "invalid_operations"
        end
        if type(id) ~= "string" or not seenOrder[id] or type(body) ~= "table" then
            return false, "invalid_operations"
        end
    end
    if recordCount ~= orderCount then
        return false, "invalid_operations"
    end

    local pendingCount = 0
    for id, entry in pairs(ops.pending) do
        pendingCount = pendingCount + 1
        if pendingCount > GS.MAX_PENDING_OPERATIONS then
            return false, "invalid_operations"
        end
        local ok, err = ValidateRetainedAdmissionEntry(id, entry)
        if not ok then
            return false, err
        end
    end

    local conflictCount = 0
    for id, entry in pairs(ops.conflicts) do
        conflictCount = conflictCount + 1
        if conflictCount > GS.MAX_PENDING_OPERATIONS then
            return false, "invalid_operations"
        end
        local ok, err = ValidateRetainedAdmissionEntry(id, entry)
        if not ok then
            return false, err
        end
    end
    if pendingCount + conflictCount > GS.MAX_PENDING_OPERATIONS then
        return false, "invalid_operations"
    end

    local headsOk, headsErr = ValidateOperationsHeads(ops)
    if not headsOk then
        return false, headsErr
    end

    -- openConflicts is optional (#387); when present it must be a bounded map of
    -- dense unique refs to retained/accepted bodies (no invented candidates).
    if ops.openConflicts ~= nil then
        if type(ops.openConflicts) ~= "table" then
            return false, "invalid_operations"
        end
        local openCount = 0
        local maxOpen = (GS.MAX_OPEN_CONFLICTS or 32)
        for targetKey, entry in pairs(ops.openConflicts) do
            openCount = openCount + 1
            if openCount > maxOpen then
                return false, "invalid_operations"
            end
            if type(targetKey) ~= "string" or targetKey == "" or type(entry) ~= "table" then
                return false, "invalid_operations"
            end
            if type(entry.candidateIds) ~= "table" then
                return false, "invalid_operations"
            end
            local n = #entry.candidateIds
            local maxCand = GS.MAX_CONFLICT_CANDIDATES or 16
            if n < 2 or n > maxCand then
                return false, "invalid_operations"
            end
            local seen = {}
            local dense = 0
            for k, id in pairs(entry.candidateIds) do
                dense = dense + 1
                if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > n then
                    return false, "invalid_operations"
                end
                if type(id) ~= "string" or id == "" or seen[id] then
                    return false, "invalid_operations"
                end
                seen[id] = true
                local body = ops.records and ops.records[id]
                    or (ops.pending and ops.pending[id] and ops.pending[id].body)
                    or (ops.conflicts and ops.conflicts[id] and ops.conflicts[id].body)
                if type(body) ~= "table" then
                    return false, "invalid_operations"
                end
            end
            if dense ~= n then
                return false, "invalid_operations"
            end
        end
    end

    return true
end

--- confirmationRefs: dense unique IDs of accepted confirm-candidate bodies.
local function ValidateConfirmationRefs(refs, ops)
    if type(refs) ~= "table" then
        return false, "invalid_record_shape"
    end
    local n = #refs
    if n > GS.MAX_ACCEPTED_OPERATIONS then
        return false, "invalid_confirmation_refs"
    end
    local counted = 0
    local seen = {}
    for k, id in pairs(refs) do
        counted = counted + 1
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > n then
            return false, "invalid_confirmation_refs"
        end
        if type(id) ~= "string" or id == "" or #id > GS.MAX_OPERATION_ID then
            return false, "invalid_confirmation_refs"
        end
        if seen[id] then
            return false, "invalid_confirmation_refs"
        end
        seen[id] = true
        local body = ops and ops.records and ops.records[id]
        if type(body) ~= "table" or body.kind ~= "confirm-candidate" then
            return false, "invalid_confirmation_refs"
        end
        if type(body.id) ~= "string" or body.id ~= id then
            return false, "invalid_confirmation_refs"
        end
    end
    if counted ~= n then
        return false, "invalid_confirmation_refs"
    end
    return true
end

--- Non-policy structure/scope validation. Does not rewrite SavedVariables.
local function ValidateGuildRecordStructure(guildKey, record)
    if type(record) ~= "table" then
        return false, "invalid_record"
    end
    local schema = tonumber(record.schemaVersion)
    if not schema or schema ~= GS.SCHEMA_VERSION then
        return false, "unsupported_schema"
    end
    if record.activation ~= GS.ACTIVATION_STAGED then
        -- #385 never activates; unknown activation is unavailable, not rewritten.
        return false, "unsupported_activation"
    end
    if type(record.datasetId) ~= "string" or record.datasetId == "" then
        return false, "invalid_dataset_id"
    end
    local _, clubId = GS.ParseGuildKey(guildKey)
    if not clubId then
        return false, "invalid_guild_key"
    end
    local accounting = record.accounting
    if type(accounting) ~= "table" or type(accounting._consumables) ~= "table" then
        return false, "invalid_accounting"
    end
    local cfg = accounting._consumables
    local guildMeta = cfg.guild
    if type(guildMeta) ~= "table" or tostring(guildMeta.guid or "") ~= clubId then
        return false, "guild_identity_mismatch"
    end
    -- Fail closed on malformed accounting fields consumed by staged APIs.
    if type(cfg.requestedItems) ~= "table" then
        return false, "invalid_accounting"
    end
    -- Bound every raw requestedItems entry (including invalid ones). Preserve
    -- oversized retained maps unchanged/unavailable — do not silently truncate.
    if GS.ValidateRequestedItemsMap then
        local itemsOk, itemsErr = GS.ValidateRequestedItemsMap(cfg.requestedItems)
        if not itemsOk then
            return false, itemsErr or "invalid_accounting"
        end
    end
    -- Eligibility container shape: allow absent/2A {} ; reject present non-tables.
    if GS.ValidateEligibilityContainer then
        local eligOk, eligErr = GS.ValidateEligibilityContainer(cfg.eligibility)
        if not eligOk then
            return false, eligErr or "invalid_eligibility"
        end
    end
    if type(accounting._consumableEvents) ~= "table"
        or type(accounting._consumableEventArchive) ~= "table" then
        return false, "invalid_accounting"
    end
    -- Fail closed on over-cap / sparse / malformed restored ledger arrays.
    -- Cheap length checks always; deep density scan is one-time/cached per
    -- mutation revision so GetCurrentRecord hot paths stay bounded.
    if GS.ValidateLedgerEventLists then
        local listsOk, listsErr = GS.ValidateLedgerEventLists(accounting)
        if not listsOk then
            return false, listsErr or "invalid_accounting"
        end
    else
        local maxLive = GS.MAX_LEDGER_EVENTS or 4096
        local maxArch = GS.MAX_ARCHIVED_EVENTS or 4096
        if #accounting._consumableEvents > maxLive
            or #accounting._consumableEventArchive > maxArch then
            return false, "ledger_overflow"
        end
    end
    if not IsValidBankTabValue(cfg.bankTab) then
        return false, "invalid_accounting"
    end
    if type(record.campaigns) ~= "table" or type(record.observations) ~= "table"
        or type(record.observations.byCampaign) ~= "table"
        or type(record.confirmationRefs) ~= "table" then
        return false, "invalid_record_shape"
    end
    -- Optional #386 maps: absent is fine for 2A-era records; wrong types fail closed.
    if record.campaignArchives ~= nil and type(record.campaignArchives) ~= "table" then
        return false, "invalid_record_shape"
    end
    if record.campaignContext ~= nil and type(record.campaignContext) ~= "table" then
        return false, "invalid_record_shape"
    end
    -- Optional #388 identity links: absent is fine for older staged records.
    if record.identityLinks ~= nil then
        if GS.ValidateIdentityLinks then
            local linkOk, linkErr = GS.ValidateIdentityLinks(record.identityLinks)
            if not linkOk then
                return false, linkErr or "invalid_identity_links"
            end
        elseif type(record.identityLinks) ~= "table" then
            return false, "invalid_identity_links"
        end
    end
    if GS.CountCampaignHeaders and GS.CountCampaignHeaders(record) > (GS.MAX_CAMPAIGNS or 64) then
        return false, "full"
    end

    -- currentCampaignId: nil (no campaign) or nonempty key matching embedded header.
    local currentCampaignId = record.currentCampaignId
    if currentCampaignId ~= nil then
        if type(currentCampaignId) ~= "string" or currentCampaignId == "" then
            return false, "invalid_campaign"
        end
        local header = record.campaigns[currentCampaignId]
        if type(header) ~= "table" then
            return false, "dangling_campaign"
        end
        if header.campaignId ~= currentCampaignId then
            return false, "campaign_id_mismatch"
        end
        local campOk, campErr = GS.ValidateCampaignBoundary(header, record, guildKey)
        if not campOk then
            return false, campErr or "invalid_campaign"
        end
        -- Active campaign generations must be finite positive integers. Do not
        -- normalize missing/zero/nonnumeric values into generation 1 on reset.
        local gen = tonumber(cfg.generation)
        if not gen or gen ~= math.floor(gen) or gen < 1
            or gen ~= gen or gen == math.huge then
            return false, "invalid_generation"
        end
    elseif cfg.generation ~= nil then
        -- Pre-campaign setup uses generation 0; other non-finite values fail closed.
        if not IsFiniteNonnegInt(cfg.generation) then
            return false, "invalid_generation"
        end
    end
    -- Archived/other headers are retained even when malformed; ListInspectableCampaigns
    -- validates each before exposure. Do not fail the whole guild record for them.

    local ok, err = ValidateOperationsStore(record.operations, guildKey, record.datasetId)
    if not ok then
        return false, err
    end
    ok, err = ValidateConfirmationRefs(record.confirmationRefs, record.operations)
    if not ok then
        return false, err
    end
    return true
end

local function ValidateGuildRecord(guildKey, record)
    -- Structure/scope first so permission-only recovery cannot mask corruption.
    local ok, err = ValidateGuildRecordStructure(guildKey, record)
    if not ok then
        return false, err
    end
    return ValidatePermissionPolicyConsistency(record)
end

function GS._ValidateGuildRecordStructure(guildKey, record)
    return ValidateGuildRecordStructure(guildKey, record)
end

function GS._IsPermissionOnlyFailure(reason)
    return type(reason) == "string" and GS.PERMISSION_ONLY_REASONS[reason] == true
end

--- Raw retained record usable only for explicit GM policy recovery.
-- Structure/scope must validate; permission must be the sole failure.
-- Never exposed by ordinary GetCurrentRecord reads.
function GS:_GetPolicyRecoveryRecord(guildKey)
    if not GS:IsRootReady() then
        return nil, GS:GetRootReason()
    end
    local key, clubId = GS.ParseGuildKey(guildKey)
    if not key then
        return nil, "invalid_guild_key"
    end
    local record = GS._root.guilds[key]
    if record == nil then
        return nil, "not_configured"
    end
    local ok, err = ValidateGuildRecordStructure(key, record)
    if not ok then
        return nil, err or "invalid_record"
    end
    -- Permission shape or policy-revision consistency may be the sole failure.
    local permOk, permErr = ValidatePermissionPolicyConsistency(record)
    if permOk then
        return nil, "policy_valid"
    end
    if not GS._IsPermissionOnlyFailure(permErr) then
        return nil, permErr or "invalid_record"
    end
    return record, permErr or "invalid_permission", clubId
end

--- Schema/guilds only; writer recovery is handled separately under #385.
local function ValidateRootBase(root)
    if type(root) ~= "table" then
        return false, "invalid_root"
    end
    local schema = tonumber(root.schemaVersion)
    if not schema or schema ~= GS.SCHEMA_VERSION then
        return false, "unsupported_schema"
    end
    if type(root.guilds) ~= "table" then
        return false, "invalid_guilds"
    end
    return true
end

local function ValidateRoot(root)
    local ok, reason = ValidateRootBase(root)
    if not ok then
        return false, reason
    end
    if not IsValidWriterState(root.localWriter) then
        return false, "invalid_local_writer"
    end
    return true
end

local function EnsureEmptyRoot(db)
    if type(db.guildSupplies) ~= "table" then
        db.guildSupplies = {
            schemaVersion = GS.SCHEMA_VERSION,
            localWriter = NewWriterState(),
            guilds = {},
        }
        DebugInfo("created empty guildSupplies root")
    end
    return db.guildSupplies
end

--- Idempotently validate/load the separate root. No guild bootstrap or network.
function GS:Initialize(db)
    db = db or (type(SpectrumFederationDB) == "table" and SpectrumFederationDB) or nil
    if type(db) ~= "table" then
        GS._db = nil
        GS._root = nil
        GS._rootValid = false
        GS._rootReason = "db_unavailable"
        return false, GS._rootReason
    end
    GS._db = db

    local existing = db.guildSupplies
    if existing == nil then
        GS._root = EnsureEmptyRoot(db)
        GS._rootValid = true
        GS._rootReason = nil
        return true
    end

    local ok, reason = ValidateRoot(existing)
    if not ok then
        -- #385: malformed writer on an otherwise supported root gets a fresh
        -- nonce before new IDs; preserve all guild records unchanged.
        if reason == "invalid_local_writer" then
            local baseOk = ValidateRootBase(existing)
            if baseOk then
                existing.localWriter = NewWriterState()
                GS._root = existing
                GS._rootValid = true
                GS._rootReason = nil
                DebugWarn("reestablished localWriter nonce on initialize")
                return true
            end
        end
        -- Preserve unsupported/malformed saved data; do not normalize domain.
        GS._root = existing
        GS._rootValid = false
        GS._rootReason = reason or "unsupported_schema"
        DebugWarn("guildSupplies root unavailable: %s", tostring(GS._rootReason))
        return false, GS._rootReason
    end

    GS._root = existing
    GS._rootValid = true
    GS._rootReason = nil
    return true
end

function GS:IsRootReady()
    return GS._rootValid == true and type(GS._root) == "table"
end

function GS:GetRootReason()
    if GS._rootValid then
        return nil
    end
    return GS._rootReason or "not_ready"
end

function GS:_GetRoot()
    if not GS._rootValid then
        return nil, GS:GetRootReason()
    end
    return GS._root
end

function GS:_GetWriter()
    local root, reason = GS:_GetRoot()
    if not root then
        return nil, reason
    end
    if not IsValidWriterState(root.localWriter) then
        return nil, "invalid_local_writer"
    end
    return root.localWriter
end

--- Rotate writer nonce when sequence is exhausted or writer state is unusable.
function GS:_EnsureWritableWriter()
    local root, reason = GS:_GetRoot()
    if not root then
        return nil, reason
    end
    local writer = root.localWriter
    if not IsValidWriterState(writer) then
        -- Preserve old records; establish a fresh nonce before new IDs.
        -- Never reuse or continue the malformed nonce/counter.
        root.localWriter = NewWriterState()
        DebugWarn("reestablished localWriter nonce")
        return root.localWriter
    end
    return writer
end

function GS:_AllocateOperationId(actorGuid)
    if type(actorGuid) ~= "string" or actorGuid == "" then
        return nil, "missing_actor"
    end
    local writer, reason = GS:_EnsureWritableWriter()
    if not writer then
        return nil, reason
    end
    local seq = tonumber(writer.nextSeq)
    if seq > GS.MAX_EVENT_SEQ then
        writer = NewWriterState()
        local root = GS._root
        root.localWriter = writer
        seq = 1
    end
    local id = string.format("gs1:%s:%s:%d", actorGuid, writer.nonce, seq)
    if #id > GS.MAX_OPERATION_ID then
        return nil, "id_too_long"
    end
    writer.nextSeq = seq + 1
    if writer.nextSeq > GS.MAX_EVENT_SEQ then
        -- Exhaustion rotates before the next issue.
        local root = GS._root
        root.localWriter = NewWriterState()
    end
    return id
end

function GS:_NewDatasetId(actorGuid)
    return GS:_AllocateOperationId(actorGuid)
end

function GS:_TrackGuildKey(guildKey)
    if guildKey ~= GS._lastGuildKey then
        GS._lastGuildKey = guildKey
        GS._BumpHandleGeneration("guild_key_changed")
    end
end

--- Validated current-guild staged record or nil + reason. Never allocates.
function GS:GetCurrentRecord()
    if not GS:IsRootReady() then
        return nil, GS:GetRootReason()
    end
    local GG = SF.GuildGossip
    if not GG or type(GG.GetGuildIdentity) ~= "function" then
        return nil, "identity_unavailable"
    end
    local identity, reason = GG.GetGuildIdentity()
    if not identity then
        GS:_TrackGuildKey(nil)
        return nil, reason or "not_ready"
    end
    GS:_TrackGuildKey(identity.guildKey)
    local record = GS._root.guilds[identity.guildKey]
    if record == nil then
        return nil, "not_configured"
    end
    local ok, err = ValidateGuildRecord(identity.guildKey, record)
    if not ok then
        return nil, err or "unsupported_schema"
    end
    return record, nil, identity
end

--- Explicit local staged creation. Requires verified current guild + authority.
-- @param editorRankPosition number|nil GM-selected threshold when fewer than 3 ranks exist.
--   Ordinary guilds (≥3 ranks) ignore this and use default position 3.
function GS:CreateStagedRecord(editorRankPosition)
    if not GS:IsRootReady() then
        return nil, "rejected", GS:GetRootReason() or "not_ready"
    end
    local ctx = GS:GetCurrentContext()
    if not ctx or not ctx.guildKey or not ctx.ready then
        return nil, "rejected", (ctx and ctx.reason) or "not_ready"
    end
    if type(ctx.actorGuid) ~= "string" or ctx.actorGuid == "" then
        return nil, "rejected", "not_ready"
    end
    if type(ctx.rankOrder) ~= "number" then
        return nil, "rejected", "rank_unavailable"
    end

    local existing = GS._root.guilds[ctx.guildKey]
    if existing ~= nil then
        local ok = ValidateGuildRecord(ctx.guildKey, existing)
        if ok then
            return nil, "rejected", "already_configured"
        end
        -- Malformed existing record is retained; do not overwrite.
        return nil, "rejected", "unsupported_schema"
    end

    local ranks = ctx.ranks
    local rankCount = ranks and tonumber(ranks.count) or 0
    local initialPosition = GS.DEFAULT_EDITOR_RANK_POSITION
    local caps = GS:GetCapabilities()
    if not caps then
        return nil, "rejected", "unauthorized"
    end

    if rankCount > 0 and rankCount < GS.DEFAULT_EDITOR_RANK_POSITION then
        -- Fewer than three ranks: verified GM must select an existing threshold.
        -- Do not invent/widen a default position that does not exist.
        if ctx.previewNonAdmin then
            return nil, "rejected", "preview_non_admin"
        end
        if ctx.rankOrder ~= 1 then
            return nil, "rejected", "policy_requires_gm"
        end
        if editorRankPosition == nil then
            return nil, "rejected", "threshold_unselected"
        end
        local selected = tonumber(editorRankPosition)
        if not selected or selected ~= math.floor(selected) or selected < 1
            or selected > rankCount then
            return nil, "rejected", "invalid_editor_rank_position"
        end
        if not caps.canRecoverPolicy then
            return nil, "rejected", caps.reason or "policy_requires_gm"
        end
        initialPosition = selected
    else
        if not caps.canEdit then
            return nil, "rejected", caps.reason or "unauthorized"
        end
        -- Ordinary path keeps default rank 3; caller selection is not applied.
    end

    local datasetId, idErr = GS:_NewDatasetId(ctx.actorGuid)
    if not datasetId then
        return nil, "rejected", idErr or "id_failed"
    end

    local _, clubId = GS.ParseGuildKey(ctx.guildKey)
    local record = {
        schemaVersion = GS.SCHEMA_VERSION,
        activation = GS.ACTIVATION_STAGED,
        datasetId = datasetId,
        permission = {
            editorRankPosition = initialPosition,
            -- Immutable bootstrap threshold (small-guild / history reconstruction).
            bootstrapEditorRankPosition = initialPosition,
            revisionId = datasetId,
        },
        currentCampaignId = nil,
        campaigns = {},
        campaignArchives = {}, -- frozen per-campaign requested-item snapshots (#386)
        campaignContext = {}, -- bounded bank-context anchors (#386); not gossip envelopes
        accounting = EmptyAccounting(clubId, ctx.guildName, ctx.guildRealm),
        observations = { byCampaign = {} },
        identityLinks = GS.EmptyIdentityLinks and GS.EmptyIdentityLinks() or {
            schemaVersion = 1, groups = {}, byGuid = {}, revisionId = nil,
        },
        operations = EmptyOperations(),
        confirmationRefs = {},
        -- Explicitly unused: hard reset replaces legacy migration (#386).
        migration = nil,
    }

    local ok, err = ValidateGuildRecord(ctx.guildKey, record)
    if not ok then
        return nil, "rejected", err or "invalid_record"
    end

    GS._root.guilds[ctx.guildKey] = record
    DebugInfo("created staged guild record key=%s dataset=%s threshold=%s",
        ctx.guildKey, datasetId, tostring(initialPosition))
    if GS._NotifyLocalDurableChange then
        GS._NotifyLocalDurableChange("create")
    end
    return record, "accepted", nil
end

--- Campaign boundary accessor: schema/validation only (#386 creates real boundaries).
function GS:GetCurrentCampaignBoundary()
    local record, reason, identity = GS:GetCurrentRecord()
    if not record then
        return nil, reason or "not_ready"
    end
    local campaignId = record.currentCampaignId
    if campaignId == nil then
        return nil, "no_campaign"
    end
    if type(campaignId) ~= "string" or campaignId == "" then
        return nil, "invalid_campaign"
    end
    local header = record.campaigns[campaignId]
    if type(header) ~= "table" then
        return nil, "missing_campaign"
    end
    if header.campaignId ~= campaignId then
        return nil, "campaign_id_mismatch"
    end
    local expectedKey = identity and identity.guildKey or nil
    local ok, err = GS.ValidateCampaignBoundary(header, record, expectedKey)
    if not ok then
        return nil, err or "invalid_campaign"
    end
    return header
end

function GS.ValidateCampaignBoundary(header, record, expectedGuildKey)
    if type(header) ~= "table" then
        return false, "invalid_campaign"
    end
    if tonumber(header.schemaVersion) ~= GS.SCHEMA_VERSION then
        return false, "unsupported_schema"
    end
    if type(header.campaignId) ~= "string" or header.campaignId == "" then
        return false, "invalid_campaign_id"
    end
    if type(header.datasetId) ~= "string" or header.datasetId == "" then
        return false, "invalid_dataset_id"
    end
    if record and header.datasetId ~= record.datasetId then
        return false, "dataset_mismatch"
    end
    if type(header.guildKey) ~= "string" then
        return false, "invalid_guild_key"
    end
    local keyOk = GS.ParseGuildKey(header.guildKey)
    if not keyOk then
        return false, "unsupported_guild_key"
    end
    -- Campaign headers must match the owning guild record / verified accessor context.
    local ownerKey = expectedGuildKey
    if ownerKey == nil and record ~= nil then
        -- Infer from accounting guild guid when the caller supplies the record.
        local cfg = record.accounting and record.accounting._consumables
        local guid = cfg and cfg.guild and cfg.guild.guid
        if guid ~= nil then
            ownerKey = "club:" .. tostring(guid)
        end
    end
    if ownerKey ~= nil and header.guildKey ~= ownerKey then
        return false, "wrong_guild"
    end
    if header.boundaryKind ~= "new-goal" and header.boundaryKind ~= "legacy-preserved" then
        return false, "invalid_boundary_kind"
    end
    if header.boundaryKind == "new-goal" then
        -- campaignId = resetOperationId for new-goal boundaries.
        if type(header.resetOperationId) ~= "string" or header.resetOperationId == "" then
            return false, "invalid_reset_operation"
        end
        if header.resetOperationId ~= header.campaignId then
            return false, "campaign_id_mismatch"
        end
        if not IsFiniteNonnegInt(header.startedAt) then
            return false, "invalid_started_at"
        end
    elseif header.resetOperationId ~= nil then
        -- legacy-preserved may omit reset IDs; if present, keep type-safe.
        if type(header.resetOperationId) ~= "string" or header.resetOperationId == "" then
            return false, "invalid_reset_operation"
        end
    end
    if header.contextStatus ~= "captured" and header.contextStatus ~= "empty"
        and header.contextStatus ~= "unavailable" then
        return false, "invalid_context_status"
    end

    -- Attribution: new-goal requires bounded authors; legacy must not invent them.
    if header.boundaryKind == "new-goal" then
        if not IsBoundedActorString(header.createdByGuid)
            or not IsBoundedActorString(header.createdByName) then
            return false, "invalid_attribution"
        end
    else
        if header.createdByGuid ~= nil and not IsBoundedActorString(header.createdByGuid) then
            return false, "invalid_attribution"
        end
        if header.createdByName ~= nil and not IsBoundedActorString(header.createdByName) then
            return false, "invalid_attribution"
        end
        -- Absent legacy startedAt is honest; present values must be finite.
        if header.startedAt ~= nil and not IsFiniteNonnegInt(header.startedAt) then
            return false, "invalid_started_at"
        end
    end

    -- Capture metadata is status-dependent; unavailable may honestly omit evidence.
    if header.contextStatus == "captured" or header.contextStatus == "empty" then
        if not IsFiniteNonnegInt(header.contextObservedAt) then
            return false, "invalid_context_observed_at"
        end
        if not IsFiniteNonnegInt(header.contextRecordCount) then
            return false, "invalid_context_record_count"
        end
        if header.contextStatus == "empty" and tonumber(header.contextRecordCount) ~= 0 then
            return false, "invalid_context_record_count"
        end
    else
        if header.contextObservedAt ~= nil and not IsFiniteNonnegInt(header.contextObservedAt) then
            return false, "invalid_context_observed_at"
        end
        if header.contextRecordCount ~= nil and not IsFiniteNonnegInt(header.contextRecordCount) then
            return false, "invalid_context_record_count"
        end
    end

    if tonumber(header.boundaryVersion) ~= 1 then
        return false, "unsupported_boundary_version"
    end
    if not IsValidBankTabValue(header.bankTabAtStart) then
        return false, "invalid_bank_tab"
    end
    if header.parentCampaignId ~= nil and type(header.parentCampaignId) ~= "string" then
        return false, "invalid_parent_campaign"
    end
    return true
end

-- Test/helper: store a validated campaign header without performing bank capture.
function GS:_StoreCampaignBoundaryForTests(header)
    local record, reason, identity = GS:GetCurrentRecord()
    if not record then
        return false, reason or "not_ready"
    end
    if type(header) ~= "table" then
        return false, "invalid_campaign"
    end
    -- Fill missing identity fields only; never rewrite a foreign guildKey.
    if header.datasetId == nil then
        header.datasetId = record.datasetId
    end
    if header.guildKey == nil then
        header.guildKey = identity.guildKey
    end
    if header.schemaVersion == nil then
        header.schemaVersion = GS.SCHEMA_VERSION
    end
    if header.boundaryVersion == nil then
        header.boundaryVersion = 1
    end
    local ok, err = GS.ValidateCampaignBoundary(header, record, identity.guildKey)
    if not ok then
        return false, err
    end
    record.campaigns[header.campaignId] = header
    record.currentCampaignId = header.campaignId
    -- Keep test helper coherent with the production invariant: a current
    -- campaign requires a finite positive generation (fresh setup is 0).
    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) == "table" then
        local gen = tonumber(cfg.generation)
        if not gen or gen ~= math.floor(gen) or gen < 1
            or gen ~= gen or gen == math.huge then
            cfg.generation = 1
        end
    end
    if record.observations.byCampaign[header.campaignId] == nil then
        record.observations.byCampaign[header.campaignId] = {
            schemaVersion = 1,
            seq = 0,
            scopes = {},
        }
    end
    return true
end
