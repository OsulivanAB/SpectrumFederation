-- Guild Supplies campaign lifecycle, archives, bank-context capture (#386 Part 2B).
-- Live bank observer / donation writer remains legacy Consumables until #389.
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

GS.MAX_CAMPAIGNS = 64
GS.MAX_CONTEXT_ANCHORS = 16
GS.CAMPAIGN_TARGET_KEY = "campaign:lifecycle"
GS.KIND = GS.KIND or {}
GS.KIND.START_CAMPAIGN = "start-campaign"

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

local function Loc(key, default)
    if SF.LocaleText then
        return SF.LocaleText(key, default)
    end
    return default or key
end

local function ServerTime()
    if GetServerTime then
        local t = GetServerTime()
        if type(t) == "number" and t == t and t >= 0 then
            return math.floor(t)
        end
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

local function CopyRequestedItems(items)
    local out = {}
    if type(items) ~= "table" then
        return out
    end
    local C = SF.Consumables
    local maxItems = (C and C.MAX_REQUESTED_ITEMS) or 256
    local n = 0
    for key, row in pairs(items) do
        if n >= maxItems then
            break
        end
        if type(row) == "table" then
            local itemId = tonumber(row.itemId) or tonumber(key)
            local goal = tonumber(row.goal) or 0
            if itemId and itemId == math.floor(itemId) and itemId >= 1
                and goal == math.floor(goal) and goal >= 0 then
                out[tostring(itemId)] = { itemId = itemId, goal = goal }
                n = n + 1
            end
        end
    end
    return out
end

--- Ensure eligibility table shape without repairing unrelated corruption.
local function EnsureEligibility(cfg)
    if type(cfg.eligibility) ~= "table" then
        cfg.eligibility = { items = {}, tabEligibleFrom = nil }
    end
    if type(cfg.eligibility.items) ~= "table" then
        cfg.eligibility.items = {}
    end
    return cfg.eligibility
end

function GS.EnsureEligibility(cfg)
    if type(cfg) ~= "table" then
        return nil
    end
    return EnsureEligibility(cfg)
end

--- Tab change establishes a campaign-local cutoff when a baseline exists.
function GS.NoteTabEligibilityCutoff(cfg, timestamp)
    if type(cfg) ~= "table" then
        return false
    end
    local eligibility = EnsureEligibility(cfg)
    local ts = tonumber(timestamp)
    if not ts or ts ~= math.floor(ts) or ts < 0 or ts ~= ts then
        return false
    end
    if eligibility.baselineEstablished == true then
        eligibility.tabEligibleFrom = ts
        return true
    end
    return false
end

--- Item add/re-add establishes a cutoff after the campaign baseline exists.
-- Ordinary goal edits must not call this.
function GS.NoteItemEligibilityCutoff(cfg, itemId, timestamp)
    if type(cfg) ~= "table" then
        return false
    end
    local id = tonumber(itemId)
    if not id or id ~= math.floor(id) or id < 1 then
        return false
    end
    local eligibility = EnsureEligibility(cfg)
    local ts = tonumber(timestamp)
    if not ts or ts ~= math.floor(ts) or ts < 0 or ts ~= ts then
        return false
    end
    if eligibility.baselineEstablished == true then
        eligibility.items[tostring(id)] = ts
        return true
    end
    return false
end

--- Establish the observation baseline for a newly started campaign.
-- Does not credit bank history; documents that future evidence needs cutoffs.
function GS.EstablishCampaignBaseline(cfg, timestamp)
    if type(cfg) ~= "table" then
        return false
    end
    local eligibility = EnsureEligibility(cfg)
    local ts = tonumber(timestamp)
    if not ts or ts ~= math.floor(ts) or ts < 0 or ts ~= ts then
        return false
    end
    eligibility.baselineEstablished = true
    eligibility.baselineAt = ts
    -- New campaign starts empty: no tab/item backfill from prior visible history
    -- until the live cutover context from #389 is applied.
    eligibility.tabEligibleFrom = ts
    eligibility.items = {}
    return true
end

---------------------------------------------------------------------------
-- Bank context capture (non-crediting; never invokes verification)
---------------------------------------------------------------------------

local function CaptureAnchorFromRow(row, index)
    if type(row) ~= "table" then
        return nil
    end
    -- Preserve original relative-age fields; do not invent absolute wall times.
    return {
        index = tonumber(index) or tonumber(row.index),
        type = type(row.type) == "string" and row.type or nil,
        year = tonumber(row.year),
        month = tonumber(row.month),
        day = tonumber(row.day),
        hour = tonumber(row.hour),
        itemLink = type(row.itemLink) == "string" and row.itemLink or nil,
        count = tonumber(row.count),
        name = type(row.name) == "string" and row.name or nil,
    }
end

--- Read bounded bank context without verification/crediting.
-- Distinguishes unavailable (API/open/tab failure) from genuinely empty.
-- @return context table { status, observedAt, recordCount, anchors?, bankTab?, reason? }
function GS.CaptureBankContext(bankTab)
    local observedAt = ServerTime()
    local tab = tonumber(bankTab)
    if tab == nil then
        return {
            status = "unavailable",
            observedAt = observedAt,
            recordCount = nil,
            reason = "bank_tab_unset",
        }
    end
    if tab ~= math.floor(tab) or tab < 1 or tab > GS.MAX_BANK_TAB then
        return {
            status = "unavailable",
            observedAt = observedAt,
            recordCount = nil,
            reason = "invalid_bank_tab",
        }
    end

    if type(GetNumGuildBankTransactions) ~= "function"
        or type(GetGuildBankTransaction) ~= "function" then
        return {
            status = "unavailable",
            observedAt = observedAt,
            recordCount = nil,
            bankTab = tab,
            reason = "api_unavailable",
        }
    end

    local okCount, count = pcall(GetNumGuildBankTransactions, tab)
    if not okCount or type(count) ~= "number" or count < 0 or count ~= count then
        return {
            status = "unavailable",
            observedAt = observedAt,
            recordCount = nil,
            bankTab = tab,
            reason = "read_failed",
        }
    end
    count = math.floor(count)

    if count == 0 then
        return {
            status = "empty",
            observedAt = observedAt,
            recordCount = 0,
            bankTab = tab,
            anchors = {},
        }
    end

    local anchors = {}
    local limit = count
    if limit > GS.MAX_CONTEXT_ANCHORS then
        limit = GS.MAX_CONTEXT_ANCHORS
    end
    -- Prefer newest rows (highest indices) as supporting anchors.
    local startIndex = count - limit + 1
    for index = startIndex, count do
        local ok, txnType, name, itemLink, txnCount, _tab1, _tab2, year, month, day, hour =
            pcall(GetGuildBankTransaction, tab, index)
        if not ok then
            -- Partial/failed read is never "empty" or trustworthy captured evidence.
            return {
                status = "unavailable",
                observedAt = observedAt,
                recordCount = nil,
                bankTab = tab,
                reason = "partial_read",
            }
        end
        local anchor = CaptureAnchorFromRow({
            type = txnType,
            name = name,
            itemLink = itemLink,
            count = txnCount,
            year = year,
            month = month,
            day = day,
            hour = hour,
            index = index,
        }, index)
        if anchor then
            anchors[#anchors + 1] = anchor
        end
    end

    return {
        status = "captured",
        observedAt = observedAt,
        recordCount = count,
        bankTab = tab,
        anchors = anchors,
    }
end

---------------------------------------------------------------------------
-- Campaign archives (configuration snapshots for inspection)
---------------------------------------------------------------------------

function GS.ValidateCampaignArchive(archive, campaignId, record)
    if type(archive) ~= "table" then
        return false, "invalid_campaign_archive"
    end
    if tonumber(archive.schemaVersion) ~= GS.SCHEMA_VERSION then
        return false, "unsupported_schema"
    end
    if type(archive.campaignId) ~= "string" or archive.campaignId == "" then
        return false, "invalid_campaign_id"
    end
    if campaignId ~= nil and archive.campaignId ~= campaignId then
        return false, "campaign_id_mismatch"
    end
    if record and type(record.datasetId) == "string" then
        if archive.datasetId ~= record.datasetId then
            return false, "dataset_mismatch"
        end
    end
    if type(archive.requestedItems) ~= "table" then
        return false, "invalid_campaign_archive"
    end
    local gen = tonumber(archive.generation)
    if not gen or gen ~= math.floor(gen) or gen < 1 then
        return false, "invalid_generation"
    end
    if archive.archivedAt ~= nil and not GS.IsFiniteNonnegInt(archive.archivedAt) then
        return false, "invalid_archived_at"
    end
    return true
end

local function EnsureCampaignArchives(record)
    if type(record.campaignArchives) ~= "table" then
        record.campaignArchives = {}
    end
    return record.campaignArchives
end

local function EnsureContextRecords(record)
    if type(record.campaignContext) ~= "table" then
        record.campaignContext = {}
    end
    return record.campaignContext
end

function GS.CountCampaignHeaders(record)
    if type(record) ~= "table" or type(record.campaigns) ~= "table" then
        return 0
    end
    return CountMap(record.campaigns)
end

--- Snapshot current requested items into an archive for an ending campaign.
-- Leaves prior state untouched on capacity failure (caller must check first).
local function ArchiveCurrentCampaignConfig(record, campaignId, timestamp)
    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" then
        return false, "invalid_accounting"
    end
    local archives = EnsureCampaignArchives(record)
    if archives[campaignId] ~= nil then
        -- Idempotent: archive already retained for this campaign.
        return true
    end
    if CountMap(archives) >= GS.MAX_CAMPAIGNS then
        return false, "full"
    end
    local generation = tonumber(cfg.generation) or 0
    if generation < 1 then
        generation = 1
    end
    archives[campaignId] = {
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = campaignId,
        datasetId = record.datasetId,
        requestedItems = CopyRequestedItems(cfg.requestedItems),
        generation = generation,
        archivedAt = timestamp,
    }
    return true
end

local function StoreContextRecords(record, campaignId, context)
    if type(context) ~= "table" or context.status ~= "captured" then
        return
    end
    if type(context.anchors) ~= "table" or #context.anchors < 1 then
        return
    end
    local store = EnsureContextRecords(record)
    -- Bounded separate records; never embed giant snapshots in operation bodies.
    store[campaignId] = {
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = campaignId,
        observedAt = context.observedAt,
        recordCount = context.recordCount,
        bankTab = context.bankTab,
        anchors = context.anchors,
    }
end

---------------------------------------------------------------------------
-- Listing / inspection (validated views; malformed retained but not exposed)
---------------------------------------------------------------------------

--- Build a sorted list of inspectable campaigns without mutating storage.
-- Malformed/foreign headers stay in SavedVariables but are omitted here.
function GS:ListInspectableCampaigns()
    local record, reason, ident = GS:GetCurrentRecord()
    if not record then
        return nil, reason or "not_ready"
    end
    local guildKey = ident and ident.guildKey or nil
    local list = {}
    for campaignId, header in pairs(record.campaigns) do
        if type(campaignId) == "string" and type(header) == "table" then
            local ok = GS.ValidateCampaignBoundary(header, record, guildKey)
            if ok and header.campaignId == campaignId then
                local archived = record.campaignArchives and record.campaignArchives[campaignId]
                local archiveOk = archived == nil
                    or GS.ValidateCampaignArchive(archived, campaignId, record)
                if archiveOk then
                    list[#list + 1] = {
                        campaignId = campaignId,
                        startedAt = header.startedAt,
                        boundaryKind = header.boundaryKind,
                        contextStatus = header.contextStatus,
                        parentCampaignId = header.parentCampaignId,
                        isCurrent = (record.currentCampaignId == campaignId),
                        bankTabAtStart = header.bankTabAtStart,
                    }
                end
            end
        end
    end
    table.sort(list, function(a, b)
        local ta = tonumber(a.startedAt) or 0
        local tb = tonumber(b.startedAt) or 0
        if ta ~= tb then
            return ta > tb
        end
        return tostring(a.campaignId) > tostring(b.campaignId)
    end)
    return list
end

--- Read-only view of a campaign's requested items (current live or archived).
-- Never returns the live mutable table.
function GS:GetCampaignRequestedItems(campaignId)
    local record, reason = GS:GetCurrentRecord()
    if not record then
        return nil, reason or "not_ready"
    end
    if type(campaignId) ~= "string" or campaignId == "" then
        return nil, "invalid_campaign"
    end
    local _, _, ident = GS:GetCurrentRecord()
    local header = record.campaigns[campaignId]
    if type(header) ~= "table" then
        return nil, "missing_campaign"
    end
    local ok, err = GS.ValidateCampaignBoundary(header, record, ident and ident.guildKey)
    if not ok then
        return nil, err or "invalid_campaign"
    end

    if record.currentCampaignId == campaignId then
        local cfg = record.accounting._consumables
        return CopyRequestedItems(cfg and cfg.requestedItems), nil, true
    end

    local archive = record.campaignArchives and record.campaignArchives[campaignId]
    if type(archive) ~= "table" then
        return CopyRequestedItems(nil), nil, false
    end
    local aok, aerr = GS.ValidateCampaignArchive(archive, campaignId, record)
    if not aok then
        return nil, aerr or "invalid_campaign_archive"
    end
    return CopyRequestedItems(archive.requestedItems), nil, false
end

--- Bounded progress projection for a campaign generation (read-only copies).
function GS:ProjectCampaignProgress(campaignId)
    local record, reason = GS:GetCurrentRecord()
    if not record then
        return nil, reason or "not_ready"
    end
    if type(campaignId) ~= "string" or campaignId == "" then
        return nil, "invalid_campaign"
    end

    local generation
    if record.currentCampaignId == campaignId then
        local cfg = record.accounting._consumables
        generation = tonumber(cfg and cfg.generation) or 0
    else
        local archive = record.campaignArchives and record.campaignArchives[campaignId]
        if type(archive) == "table" and GS.ValidateCampaignArchive(archive, campaignId, record) then
            generation = tonumber(archive.generation)
        else
            return nil, "missing_campaign_archive"
        end
    end
    if not generation or generation < 1 then
        return { itemTotals = {}, contributions = {}, generation = generation or 0 }
    end

    local itemTotals = {}
    local contributions = {}
    local events = record.accounting._consumableEvents
    if type(events) == "table" then
        local limit = #events
        if limit > 4096 then
            limit = 4096
        end
        for i = 1, limit do
            local event = events[i]
            if type(event) == "table" and tonumber(event.generation) == generation then
                local itemId = tonumber(event.itemId)
                local qty = tonumber(event.quantity) or 0
                if itemId and qty ~= 0 then
                    if event.type == "donation" or event.type == "CONSUMABLE_DONATION" then
                        if qty > 0 then
                            itemTotals[itemId] = (itemTotals[itemId] or 0) + qty
                            if type(event.actor) == "string" and event.actor ~= "" then
                                contributions[event.actor] = contributions[event.actor] or {}
                                contributions[event.actor][itemId] =
                                    (contributions[event.actor][itemId] or 0) + qty
                            end
                        end
                    elseif event.type == "adjustment" or event.type == "CONSUMABLE_ADJUSTMENT" then
                        itemTotals[itemId] = (itemTotals[itemId] or 0) + qty
                    end
                end
            end
        end
    end
    return {
        itemTotals = itemTotals,
        contributions = contributions,
        generation = generation,
    }
end

---------------------------------------------------------------------------
-- Mutation status feedback (never treat rejection as Saved)
---------------------------------------------------------------------------

--- Translate staged mutation statuses for Settings banners.
-- @return message string, severity ("success"|"info"|"warn"|"error")
function GS.FormatMutationFeedback(status, reason)
    if status == "accepted" then
        return Loc("GUILD_SUPPLIES_STATUS_ACCEPTED",
            "Staged change admitted. Live bank accounting still uses Raid Consumables until activation."),
            "success"
    end
    if status == "duplicate" then
        return Loc("GUILD_SUPPLIES_STATUS_DUPLICATE",
            "No new effect — that change was already admitted."),
            "info"
    end
    if status == "pending" then
        local detail = reason and tostring(reason) or "stale_base"
        return Loc("GUILD_SUPPLIES_STATUS_PENDING",
            "Change is pending and was not applied yet (%s)."):format(detail),
            "warn"
    end
    -- rejected or unknown
    local detail = reason and tostring(reason) or "rejected"
    return Loc("GUILD_SUPPLIES_STATUS_REJECTED",
        "Change was not applied (%s)."):format(detail),
        "error"
end

---------------------------------------------------------------------------
-- Production New Campaign operation API
---------------------------------------------------------------------------

local function CurrentCampaignRevision(record)
    local head = record.operations and record.operations.heads
        and record.operations.heads[GS.CAMPAIGN_TARGET_KEY]
    if type(head) == "string" and head ~= "" then
        return head
    end
    return record.datasetId
end

local function ValidateCampaignOpShape(op)
    if type(op) ~= "table" then
        return false, "invalid_operation"
    end
    if tonumber(op.schemaVersion) ~= GS.OP_SCHEMA_VERSION then
        return false, "unsupported_schema"
    end
    if op.kind ~= GS.KIND.START_CAMPAIGN then
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
    if type(op.target) ~= "string" or op.target ~= "campaign" then
        return false, "invalid_target"
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
    -- value is reserved for future metadata; must be nil or empty table when present.
    if op.value ~= nil and type(op.value) ~= "table" then
        return false, "invalid_value"
    end
    return true
end

function GS.ValidateCampaignOperationBody(body, guildKey, datasetId)
    local ok, err = ValidateCampaignOpShape(body)
    if not ok then
        return false, err or "invalid_operations"
    end
    if guildKey ~= nil and body.guildKey ~= guildKey then
        return false, "wrong_guild"
    end
    if datasetId ~= nil and body.datasetId ~= datasetId then
        return false, "dataset_mismatch"
    end
    return true
end

function GS:NewCampaignOperation()
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
    local ts = ServerTime()
    if not ts then
        return nil, "rejected", "server_time_unavailable"
    end
    local id, idErr = GS:_AllocateOperationId(ctx.actorGuid)
    if not id then
        return nil, "rejected", idErr or "id_failed"
    end

    local policyRev = (type(record.permission) == "table"
        and record.permission.revisionId) or record.datasetId

    local op = {
        schemaVersion = GS.OP_SCHEMA_VERSION,
        id = id,
        guildKey = ctx.guildKey,
        datasetId = record.datasetId,
        campaignId = record.currentCampaignId,
        kind = GS.KIND.START_CAMPAIGN,
        target = "campaign",
        value = {},
        actorGuid = ctx.actorGuid,
        actorName = ctx.actorName,
        timestamp = ts,
        baseTargetRevision = CurrentCampaignRevision(record),
        basePolicyRevision = policyRev,
        baseCampaignId = record.currentCampaignId,
        _preparedHandleGeneration = ctx.handleGeneration,
    }
    local shapeOk, shapeErr = ValidateCampaignOpShape(op)
    if not shapeOk then
        return nil, "rejected", shapeErr
    end
    return op, "accepted", nil
end

function GS:ValidateCampaignOperation(op, context)
    local ok, err = ValidateCampaignOpShape(op)
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
    if op.actorGuid ~= context.actorGuid or op.actorName ~= context.actorName then
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
    if op.basePolicyRevision ~= ((type(record.permission) == "table"
        and record.permission.revisionId) or record.datasetId) then
        return false, "stale_base"
    end
    if (op.baseCampaignId or nil) ~= (record.currentCampaignId or nil) then
        return false, "stale_base"
    end
    if (op.campaignId or nil) ~= (record.currentCampaignId or nil) then
        return false, "stale_base"
    end
    if op.baseTargetRevision ~= CurrentCampaignRevision(record) then
        return false, "stale_base"
    end
    return true
end

--- Apply New Campaign atomically. Capacity / validation failure leaves prior state.
function GS:ApplyStagedCampaignOperation(op, context)
    if type(op) ~= "table" then
        return "rejected", "invalid_operation"
    end
    local shapeOk, shapeErr = ValidateCampaignOpShape(op)
    if not shapeOk then
        return "rejected", shapeErr
    end

    -- SnapshotPublicOp lives on Operations; use the shared GS path via apply helper.
    local stored, snapErr
    if GS._SnapshotPublicOp then
        stored, snapErr = GS._SnapshotPublicOp(op)
    else
        -- Fallback: shallow public fields only (tests / load-order edge).
        stored = {
            schemaVersion = op.schemaVersion,
            id = op.id,
            guildKey = op.guildKey,
            datasetId = op.datasetId,
            campaignId = op.campaignId,
            kind = op.kind,
            target = op.target,
            value = type(op.value) == "table" and {} or op.value,
            actorGuid = op.actorGuid,
            actorName = op.actorName,
            timestamp = op.timestamp,
            baseTargetRevision = op.baseTargetRevision,
            basePolicyRevision = op.basePolicyRevision,
            baseCampaignId = op.baseCampaignId,
        }
    end
    if not stored then
        return "rejected", snapErr or "invalid_operation"
    end

    if GS._RecognizeExactAcceptedDuplicate then
        local dupStatus, dupReason = GS._RecognizeExactAcceptedDuplicate(op, stored)
        if dupStatus then
            return dupStatus, dupReason
        end
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
    context = fresh or context or GS:GetCurrentContext()
    if op.actorName ~= (context and context.actorName) then
        return "rejected", "unauthorized"
    end

    if not GS:IsRootReady() then
        return "rejected", GS:GetRootReason() or "not_ready"
    end
    local record = GS:GetCurrentRecord()
    if type(record) ~= "table" then
        return "rejected", "not_configured"
    end
    if record.activation ~= GS.ACTIVATION_STAGED then
        return "rejected", "unsupported_activation"
    end

    local ops = record.operations
    local existing = ops.records[op.id]
    if existing then
        -- Deep equal via Operations helper when available.
        if GS._DeepEqualOps and GS._DeepEqualOps(existing, stored) then
            return "duplicate", "duplicate"
        end
        if existing.id == stored.id and existing.kind == stored.kind
            and existing.timestamp == stored.timestamp
            and existing.baseCampaignId == stored.baseCampaignId then
            return "duplicate", "duplicate"
        end
        if GS._RetainConflict and not GS._RetainConflict(ops, stored) then
            return "rejected", "full"
        end
        return "rejected", "id_conflict"
    end

    if ops.pending and ops.pending[op.id] then
        local pendingBody = ops.pending[op.id].body
        local same = (GS._DeepEqualOps and GS._DeepEqualOps(pendingBody, stored))
            or (pendingBody and pendingBody.id == stored.id and pendingBody.kind == stored.kind)
        if same then
            local validRetry, verrRetry = GS:ValidateCampaignOperation(op, context)
            if not validRetry then
                if verrRetry == "stale_base" then
                    return "pending", verrRetry
                end
                return "rejected", verrRetry or "unauthorized"
            end
            -- Fall through to accept.
        else
            if GS._RetainConflict and not GS._RetainConflict(ops, stored) then
                return "rejected", "full"
            end
            return "rejected", "id_conflict"
        end
    elseif ops.conflicts and ops.conflicts[op.id] then
        return "rejected", "id_conflict"
    end

    local valid, verr = GS:ValidateCampaignOperation(op, context)
    if not valid then
        if verr == "stale_base" and GS._AdmitPendingOrConflict then
            local status, reason = GS._AdmitPendingOrConflict(ops, stored, verr)
            return status, reason
        end
        return "rejected", verr or "unauthorized"
    end

    -- Capacity checks BEFORE any mutation.
    local acceptedCount = CountMap(ops.records)
    if acceptedCount >= GS.MAX_ACCEPTED_OPERATIONS then
        return "rejected", "full"
    end
    if GS.CountCampaignHeaders(record) >= GS.MAX_CAMPAIGNS then
        return "rejected", "full"
    end
    if record.campaigns[op.id] ~= nil then
        -- Distinct logical reset must not collide with an existing campaign id.
        return "rejected", "id_conflict"
    end

    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" or type(cfg.requestedItems) ~= "table" then
        return "rejected", "invalid_accounting"
    end

    local parentId = record.currentCampaignId
    if parentId then
        local archiveOk, archiveErr = ArchiveCurrentCampaignConfig(record, parentId, op.timestamp)
        if not archiveOk then
            return "rejected", archiveErr or "full"
        end
    end

    -- Capture bank context without verification (may be unavailable).
    local contextCapture = GS.CaptureBankContext(cfg.bankTab)
    local contextStatus = contextCapture.status or "unavailable"
    local contextObservedAt = contextCapture.observedAt
    local contextRecordCount = contextCapture.recordCount
    if contextStatus == "unavailable" then
        -- Honest omission of observation evidence for unavailable.
        contextObservedAt = contextCapture.observedAt
        contextRecordCount = nil
    end

    local header = {
        schemaVersion = GS.SCHEMA_VERSION,
        campaignId = op.id,
        datasetId = record.datasetId,
        guildKey = op.guildKey,
        parentCampaignId = parentId,
        resetOperationId = op.id,
        createdByGuid = op.actorGuid,
        createdByName = op.actorName,
        startedAt = op.timestamp,
        bankTabAtStart = cfg.bankTab,
        boundaryVersion = 1,
        boundaryKind = "new-goal",
        contextStatus = contextStatus,
        contextObservedAt = contextObservedAt,
        contextRecordCount = contextRecordCount,
    }
    local headerOk, headerErr = GS.ValidateCampaignBoundary(header, record, op.guildKey)
    if not headerOk then
        -- Roll back archive insert if we just created it for a failed header.
        if parentId and record.campaignArchives and record.campaignArchives[parentId]
            and record.campaignArchives[parentId].archivedAt == op.timestamp
            and record.currentCampaignId == parentId then
            -- Only remove if this apply created it in this attempt and parent is still current.
            -- Safer: leave archive — but then retry would see existing archive (idempotent).
            -- Header failure before pointer swap: remove the just-written archive for this parent
            -- only when it matches this timestamp and campaigns[parent] still current.
            local justArchived = record.campaignArchives[parentId]
            if justArchived and justArchived.archivedAt == op.timestamp then
                record.campaignArchives[parentId] = nil
            end
        end
        return "rejected", headerErr or "invalid_campaign"
    end

    -- Mutate: empty items, bump generation, install header, select current.
    local previousItems = cfg.requestedItems
    local previousGeneration = cfg.generation
    local previousEligibility = cfg.eligibility
    local previousCurrent = record.currentCampaignId

    cfg.requestedItems = {}
    local nextGen = (tonumber(cfg.generation) or 0) + 1
    if nextGen < 1 then
        nextGen = 1
    end
    cfg.generation = nextGen
    GS.EstablishCampaignBaseline(cfg, op.timestamp)
    -- configSeq bump for projection invalidation without gossip.
    cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1

    record.campaigns[op.id] = header
    record.currentCampaignId = op.id
    if record.observations.byCampaign[op.id] == nil then
        record.observations.byCampaign[op.id] = {
            schemaVersion = 1,
            seq = 0,
            scopes = {},
        }
    end
    StoreContextRecords(record, op.id, contextCapture)

    if GS._StoreAccepted then
        GS._StoreAccepted(ops, stored, GS.CAMPAIGN_TARGET_KEY)
    else
        ops.records[stored.id] = stored
        ops.order[#ops.order + 1] = stored.id
        ops.heads[GS.CAMPAIGN_TARGET_KEY] = stored.id
        if ops.pending then
            ops.pending[stored.id] = nil
        end
    end

    -- Post-condition validation: if the guild record would become unusable, roll back.
    local postOk, postErr = GS._ValidateGuildRecordStructure(op.guildKey, record)
    if not postOk then
        cfg.requestedItems = previousItems
        cfg.generation = previousGeneration
        cfg.eligibility = previousEligibility
        record.currentCampaignId = previousCurrent
        record.campaigns[op.id] = nil
        record.observations.byCampaign[op.id] = nil
        if record.campaignContext then
            record.campaignContext[op.id] = nil
        end
        ops.records[stored.id] = nil
        -- Remove trailing order entry if we appended it.
        if ops.order[#ops.order] == stored.id then
            ops.order[#ops.order] = nil
        end
        if ops.heads[GS.CAMPAIGN_TARGET_KEY] == stored.id then
            ops.heads[GS.CAMPAIGN_TARGET_KEY] = nil
        end
        if parentId and record.campaignArchives then
            local justArchived = record.campaignArchives[parentId]
            if justArchived and justArchived.archivedAt == op.timestamp then
                record.campaignArchives[parentId] = nil
            end
        end
        DebugWarn("campaign apply rolled back: %s", tostring(postErr))
        return "rejected", postErr or "invalid_record"
    end

    DebugInfo("started campaign id=%s parent=%s context=%s",
        tostring(op.id), tostring(parentId), tostring(contextStatus))
    return "accepted", nil
end
