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
            eligibility = {},
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

local function ValidateOperationsStore(ops)
    if type(ops) ~= "table" then
        return false, "invalid_operations"
    end
    if type(ops.records) ~= "table" or type(ops.order) ~= "table"
        or type(ops.heads) ~= "table" or type(ops.pending) ~= "table"
        or type(ops.conflicts) ~= "table" then
        return false, "invalid_operations"
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
    if type(accounting._consumableEvents) ~= "table"
        or type(accounting._consumableEventArchive) ~= "table" then
        return false, "invalid_accounting"
    end
    if not IsValidBankTabValue(cfg.bankTab) then
        return false, "invalid_accounting"
    end
    if type(record.campaigns) ~= "table" or type(record.observations) ~= "table"
        or type(record.observations.byCampaign) ~= "table"
        or type(record.confirmationRefs) ~= "table" then
        return false, "invalid_record_shape"
    end
    local ok, err = ValidateOperationsStore(record.operations)
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
    return ValidatePermission(record.permission)
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
    local permOk, permErr = ValidatePermission(record.permission)
    if permOk then
        return nil, "policy_valid"
    end
    return record, permErr or "invalid_permission", clubId
end

local function ValidateRoot(root)
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
    local writer = root.localWriter
    if type(writer) ~= "table" or type(writer.nonce) ~= "string" or writer.nonce == "" then
        return false, "invalid_local_writer"
    end
    local seq = tonumber(writer.nextSeq)
    if not seq or seq ~= math.floor(seq) or seq < 1 or seq > GS.MAX_EVENT_SEQ then
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
        -- Preserve unsupported/malformed saved data; do not normalize.
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
    local writer = root.localWriter
    if type(writer) ~= "table" or type(writer.nonce) ~= "string" or writer.nonce == "" then
        return nil, "invalid_local_writer"
    end
    local seq = tonumber(writer.nextSeq)
    if not seq or seq ~= math.floor(seq) or seq < 1 then
        return nil, "invalid_local_writer"
    end
    return writer
end

--- Rotate writer nonce when sequence is exhausted or writer state is unusable.
function GS:_EnsureWritableWriter()
    local root, reason = GS:_GetRoot()
    if not root then
        return nil, reason
    end
    local writer = root.localWriter
    local seq = writer and tonumber(writer.nextSeq)
    local nonceOk = type(writer) == "table" and type(writer.nonce) == "string" and writer.nonce ~= ""
    if not nonceOk or not seq or seq ~= math.floor(seq) or seq < 1 or seq > GS.MAX_EVENT_SEQ then
        -- Preserve old records; establish a fresh nonce before new IDs.
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

--- Explicit local staged creation. Requires verified current guild + default rank authority.
function GS:CreateStagedRecord()
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
    if rankCount > 0 and rankCount < GS.DEFAULT_EDITOR_RANK_POSITION then
        -- Fresh guild with fewer than three ranks requires GM selection later;
        -- do not invent a default position that does not exist.
        if ctx.rankOrder ~= 1 then
            return nil, "rejected", "policy_requires_gm"
        end
        return nil, "rejected", "threshold_unselected"
    end

    local caps = GS:GetCapabilities()
    if not caps or not caps.canEdit then
        return nil, "rejected", (caps and caps.reason) or "unauthorized"
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
            revisionId = datasetId,
        },
        currentCampaignId = nil,
        campaigns = {},
        accounting = EmptyAccounting(clubId, ctx.guildName, ctx.guildRealm),
        observations = { byCampaign = {} },
        operations = EmptyOperations(),
        confirmationRefs = {},
        migration = nil,
    }

    local ok, err = ValidateGuildRecord(ctx.guildKey, record)
    if not ok then
        return nil, "rejected", err or "invalid_record"
    end

    GS._root.guilds[ctx.guildKey] = record
    DebugInfo("created staged guild record key=%s dataset=%s", ctx.guildKey, datasetId)
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
    if header.resetOperationId ~= nil and header.resetOperationId ~= header.campaignId then
        -- For new-goal campaigns, campaignId = resetOperationId.
        if header.boundaryKind == "new-goal" then
            return false, "campaign_id_mismatch"
        end
    end
    if header.boundaryKind ~= "new-goal" and header.boundaryKind ~= "legacy-preserved" then
        return false, "invalid_boundary_kind"
    end
    if header.contextStatus ~= "captured" and header.contextStatus ~= "empty"
        and header.contextStatus ~= "unavailable" then
        return false, "invalid_context_status"
    end
    if tonumber(header.boundaryVersion) ~= 1 then
        return false, "unsupported_boundary_version"
    end
    if header.boundaryKind == "new-goal" then
        local startedAt = tonumber(header.startedAt)
        if not startedAt or startedAt ~= math.floor(startedAt) or startedAt < 0 then
            return false, "invalid_started_at"
        end
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
    if record.observations.byCampaign[header.campaignId] == nil then
        record.observations.byCampaign[header.campaignId] = {
            schemaVersion = 1,
            seq = 0,
            scopes = {},
        }
    end
    return true
end
