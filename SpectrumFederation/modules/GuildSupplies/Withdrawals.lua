-- Guild Supplies Quick Withdraw informational receipts (#457).
-- Authenticated client reports of confirmed bank→bag movement. Not donation
-- evidence, not bank-log verification, and never valued or ranked.
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

GS.LEDGER_EVENT = GS.LEDGER_EVENT or {}
GS.LEDGER_EVENT.WITHDRAWAL = "withdrawal"

GS.WITHDRAWAL_PROVENANCE = {
    ORIGIN = "quick-withdraw-origin",
    RELAY = "quick-withdraw-relay",
}

local function Debug(level, message, ...)
    if SF.Debug and SF.Debug[level] then
        SF.Debug[level](SF.Debug, "GUILD_SUPPLIES", message, ...)
    end
end

local function Now()
    if GetServerTime then
        local t = GetServerTime()
        if type(t) == "number" and t == t and t >= 0 then
            return math.floor(t)
        end
    end
    return math.floor(time() or 0)
end

local function IsPositiveItemId(raw)
    local itemId = tonumber(raw)
    if not itemId or itemId ~= itemId or itemId == math.huge or itemId == -math.huge then
        return nil
    end
    if itemId ~= math.floor(itemId) or itemId < 1 then
        return nil
    end
    return itemId
end

local function BoundedString(value, maxLen)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    maxLen = maxLen or (GS.MAX_OPERATION_ID or 192)
    if #value > maxLen then
        return nil
    end
    return value
end

local function CountWithdrawals(list)
    local n = 0
    if type(list) ~= "table" then
        return 0
    end
    for i = 1, #list do
        local event = list[i]
        if type(event) == "table"
            and (event.type == GS.LEDGER_EVENT.WITHDRAWAL or event.type == "withdrawal") then
            n = n + 1
        end
    end
    return n
end

--- Validate an immutable withdrawal receipt body.
function GS.ValidateWithdrawalEventBody(event, datasetId)
    if type(event) ~= "table" then
        return false, "invalid_event"
    end
    if event.type ~= GS.LEDGER_EVENT.WITHDRAWAL and event.type ~= "withdrawal" then
        return false, "unsupported_kind"
    end
    local id = BoundedString(event.id)
    if not id then
        return false, "invalid_id"
    end
    -- Distinct receipt namespace (matches BuildWithdrawalReceipts gsw1:… IDs).
    -- Must not occupy editor adjustment / donation operation IDs (gs1:…).
    if id:sub(1, 5) ~= "gsw1:" then
        return false, "invalid_id"
    end
    local eventDataset = BoundedString(event.datasetId)
    if not eventDataset then
        return false, "invalid_dataset"
    end
    if datasetId and eventDataset ~= datasetId then
        return false, "dataset_mismatch"
    end
    local itemId = IsPositiveItemId(event.itemId)
    if not itemId then
        return false, "invalid_item_id"
    end
    local qty = tonumber(event.quantity)
    if not qty or qty ~= math.floor(qty) or qty < 1
        or qty > (GS.MAX_WITHDRAW_AGGREGATE or 100000) then
        return false, "invalid_quantity"
    end
    local actor = BoundedString(event.actor, 64)
    local actorGuid = BoundedString(event.actorGuid, 64)
    if not actor or not actorGuid then
        return false, "invalid_actor"
    end
    local campaignId = BoundedString(event.campaignId)
    if not campaignId then
        return false, "invalid_campaign"
    end
    local generation = tonumber(event.generation)
    if not generation or generation ~= math.floor(generation) or generation < 1 then
        return false, "invalid_generation"
    end
    local tab = tonumber(event.bankTab)
    if not tab or tab ~= math.floor(tab) or tab < 1 or tab > (GS.MAX_BANK_TAB or 8) then
        return false, "invalid_bank_tab"
    end
    if not (GS.IsFiniteNonnegInt and GS.IsFiniteNonnegInt(event.timestamp)) then
        return false, "invalid_timestamp"
    end
    local provenance = event.provenance
    if provenance ~= GS.WITHDRAWAL_PROVENANCE.ORIGIN
        and provenance ~= GS.WITHDRAWAL_PROVENANCE.RELAY then
        return false, "invalid_provenance"
    end
    -- Withdrawals never carry donation/valuation fields.
    if event.gsProductionCredit == true then
        return false, "invalid_credit"
    end
    if event.unitCopper ~= nil or event.valuation ~= nil then
        return false, "valuation_forbidden"
    end
    return true
end

--- Canonical public body for equality / wire export.
function GS.CanonicalWithdrawalEvent(event)
    local ok = GS.ValidateWithdrawalEventBody(event, event and event.datasetId)
    if not ok then
        return nil
    end
    return {
        type = GS.LEDGER_EVENT.WITHDRAWAL,
        id = event.id,
        datasetId = event.datasetId,
        campaignId = event.campaignId,
        generation = tonumber(event.generation),
        itemId = tonumber(event.itemId),
        quantity = tonumber(event.quantity),
        actor = event.actor,
        actorGuid = event.actorGuid,
        bankTab = tonumber(event.bankTab),
        timestamp = tonumber(event.timestamp),
        provenance = event.provenance,
        operationId = BoundedString(event.operationId),
        guildKey = BoundedString(event.guildKey),
        gsProductionCredit = false,
    }
end

--- Immutable logical body for duplicate/conflict detection.
-- Provenance (ORIGIN vs RELAY) is transport presentation, not receipt identity:
-- the same confirmed movement admitted via origin and relay must not id_conflict.
function GS.CanonicalWithdrawalEventIdentity(event)
    local canon = GS.CanonicalWithdrawalEvent(event)
    if not canon then
        return nil
    end
    return {
        type = canon.type,
        id = canon.id,
        datasetId = canon.datasetId,
        campaignId = canon.campaignId,
        generation = canon.generation,
        itemId = canon.itemId,
        quantity = canon.quantity,
        actor = canon.actor,
        actorGuid = canon.actorGuid,
        bankTab = canon.bankTab,
        timestamp = canon.timestamp,
        operationId = canon.operationId,
        guildKey = canon.guildKey,
        gsProductionCredit = false,
    }
end

--- Provider export body for withdrawals: route-independent fingerprint identity.
-- Always publishes ORIGIN as the wire provenance token; admission re-derives
-- RELAY from sender≠actor. Peers storing ORIGIN vs RELAY therefore export equal
-- versionFp values for the same logical receipt.
function GS.ExportableWithdrawalEvent(event)
    local identity = GS.CanonicalWithdrawalEventIdentity(event)
    if not identity then
        return nil
    end
    identity.provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN
    return identity
end

local function FindLedgerEventById(record, id)
    if type(record) ~= "table" or type(id) ~= "string" or id == "" then
        return nil
    end
    local maxLive = (GS.MAX_LEDGER_EVENTS or 4096) + (GS.MAX_WITHDRAWAL_EVENTS or 1024)
    local maxArch = (GS.MAX_ARCHIVED_EVENTS or 4096) + (GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024)
    local function scan(list, maxScan)
        if type(list) ~= "table" then
            return nil
        end
        local limit = math.min(#list, maxScan)
        for i = 1, limit do
            local event = list[i]
            if type(event) == "table" and event.id == id then
                return event
            end
        end
        return nil
    end
    return scan(record.accounting and record.accounting._consumableEvents, maxLive)
        or scan(record.accounting and record.accounting._consumableEventArchive, maxArch)
end

local function WithdrawalCapacityAvailable(record)
    local maxLive = GS.MAX_WITHDRAWAL_EVENTS or 1024
    local maxArch = GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024
    local live = CountWithdrawals(record.accounting and record.accounting._consumableEvents)
    local arch = CountWithdrawals(record.accounting and record.accounting._consumableEventArchive)
    return live < maxLive, arch < maxArch, live, arch
end

--- Append a withdrawal without consuming donation ledger capacity.
-- Uses the shared event lists but enforces a separate withdrawal ceiling and
-- never shelves donations to make room for informational receipts.
local function AppendWithdrawalEvent(record, event)
    local cfg = record.accounting and record.accounting._consumables
    local curGen = tonumber(cfg and cfg.generation)
    local eventGen = tonumber(event.generation)
    local liveOk, archOk = WithdrawalCapacityAvailable(record)
    if eventGen and curGen and eventGen < curGen then
        if not archOk then
            return false, "full"
        end
        local archive = record.accounting._consumableEventArchive
        if type(archive) ~= "table" then
            record.accounting._consumableEventArchive = {}
            archive = record.accounting._consumableEventArchive
        end
        local maxCombinedArch = (GS.MAX_ARCHIVED_EVENTS or 4096)
            + (GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024)
        if #archive >= maxCombinedArch then
            return false, "full"
        end
        archive[#archive + 1] = event
        if GS._BumpAccountingMutation then
            GS._BumpAccountingMutation(record)
        end
        return true
    end
    if not liveOk then
        return false, "full"
    end
    local list = record.accounting._consumableEvents
    if type(list) ~= "table" then
        record.accounting._consumableEvents = {}
        list = record.accounting._consumableEvents
    end
    local maxCombined = (GS.MAX_LEDGER_EVENTS or 4096) + (GS.MAX_WITHDRAWAL_EVENTS or 1024)
    if #list >= maxCombined then
        return false, "full"
    end
    list[#list + 1] = event
    if type(cfg) == "table" then
        cfg.eventSeq = (tonumber(cfg.eventSeq) or 0) + 1
    end
    if GS._BumpAccountingMutation then
        GS._BumpAccountingMutation(record)
    end
    return true
end

--- Build origin receipt(s) for confirmed Quick Withdraw quantities.
-- @param amounts {[itemId]=qty} confirmed only
-- @param meta {operationId, campaignId, generation, bankTab, datasetId, guildKey, actor, actorGuid, timestamp?}
-- @return events table|nil, err|nil
function GS.BuildWithdrawalReceipts(amounts, meta)
    if type(amounts) ~= "table" or type(meta) ~= "table" then
        return nil, "invalid_args"
    end
    local actor = BoundedString(meta.actor, 64)
    local actorGuid = BoundedString(meta.actorGuid, 64)
    local campaignId = BoundedString(meta.campaignId)
    local datasetId = BoundedString(meta.datasetId)
    local guildKey = BoundedString(meta.guildKey)
    local operationId = BoundedString(meta.operationId)
    local generation = tonumber(meta.generation)
    local bankTab = tonumber(meta.bankTab)
    local timestamp = tonumber(meta.timestamp) or Now()
    if not actor or not actorGuid or not campaignId or not datasetId
        or not operationId or not generation or not bankTab then
        return nil, "invalid_meta"
    end
    local events = {}
    local keys = {}
    for k in pairs(amounts) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    for i = 1, #keys do
        local key = keys[i]
        local itemId = IsPositiveItemId(key)
        local qty = tonumber(amounts[key] or amounts[itemId])
        if itemId and qty and qty == math.floor(qty) and qty > 0 then
            local id = string.format("gsw1:%s:%s:%d", operationId, tostring(itemId), i)
            if #id > (GS.MAX_OPERATION_ID or 192) then
                -- Compact fallback when operationId is already long.
                id = string.format("gsw1:%s:%d", tostring(itemId), timestamp + i)
            end
            events[#events + 1] = {
                type = GS.LEDGER_EVENT.WITHDRAWAL,
                id = id,
                datasetId = datasetId,
                campaignId = campaignId,
                generation = generation,
                itemId = itemId,
                quantity = qty,
                actor = actor,
                actorGuid = actorGuid,
                bankTab = bankTab,
                timestamp = timestamp,
                provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN,
                operationId = operationId,
                guildKey = guildKey,
                gsProductionCredit = false,
            }
        end
    end
    if #events < 1 then
        return nil, "empty_amounts"
    end
    return events
end

--- Local origin commit after confirmed movement. Does not grant donation credit.
function GS:CommitLocalWithdrawalReceipts(amounts, meta)
    local record, reason = GS:GetCurrentRecord()
    if not record then
        return "rejected", reason or "not_ready"
    end
    if not meta then
        return "rejected", "invalid_meta"
    end
    local ctx = GS:GetCurrentContext()
    if not ctx or not ctx.ready then
        return "rejected", (ctx and ctx.reason) or "not_ready"
    end
    -- Bind actor to the actual local player; UI cannot nominate another character.
    meta.actorGuid = ctx.actorGuid
    meta.actor = ctx.actorName or meta.actor
    -- Preserve captured operation scope from movement start; do not rewrite with
    -- current record context when meta already carries immutable fields.
    local capturedDataset = BoundedString(meta.datasetId)
    if capturedDataset and capturedDataset ~= record.datasetId then
        return "rejected", "dataset_mismatch"
    end
    if not capturedDataset then
        meta.datasetId = record.datasetId
    end
    if not BoundedString(meta.guildKey) then
        meta.guildKey = ctx.guildKey
    end
    if not BoundedString(meta.campaignId) and type(record.currentCampaignId) == "string" then
        meta.campaignId = record.currentCampaignId
    end
    local campaignId = BoundedString(meta.campaignId)
    if not campaignId then
        return "rejected", "invalid_campaign"
    end
    local campaignKnown = (record.currentCampaignId == campaignId)
        or (type(record.campaigns) == "table" and record.campaigns[campaignId] ~= nil)
        or (type(record.campaignArchives) == "table" and record.campaignArchives[campaignId] ~= nil)
    if not campaignKnown then
        return "rejected", "invalid_campaign"
    end
    if not tonumber(meta.generation) then
        local cfg = record.accounting and record.accounting._consumables
        meta.generation = tonumber(cfg and cfg.generation) or 1
    end
    local events, buildErr = GS.BuildWithdrawalReceipts(amounts, meta)
    if not events then
        return "rejected", buildErr or "invalid_amounts"
    end
    if not GS.WithdrawalReceiptCapacityOk(record, #events, meta) then
        return "rejected", "full"
    end
    local accepted = 0
    for i = 1, #events do
        local event = GS.CanonicalWithdrawalEvent(events[i])
        if not event then
            return "rejected", "invalid_event"
        end
        local existing = FindLedgerEventById(record, event.id)
        if existing then
            local existingId = GS.CanonicalWithdrawalEventIdentity(existing)
            local incomingId = GS.CanonicalWithdrawalEventIdentity(event)
            if existingId and incomingId and GS._DeepEqualOps
                and GS._DeepEqualOps(existingId, incomingId) then
                -- duplicate ok (provenance may differ ORIGIN vs RELAY)
            else
                return "rejected", "id_conflict"
            end
        else
            local ok, err = AppendWithdrawalEvent(record, event)
            if not ok then
                return "rejected", err or "full"
            end
            accepted = accepted + 1
            if GS.RefreshLedgerEventExport then
                pcall(GS.RefreshLedgerEventExport, record, event)
            end
        end
    end
    if accepted > 0 then
        -- RefreshLedgerEventExport upserts bodies but does not rebuild the
        -- dataset descriptor's acceptedLedgerCount. Always drive the durable
        -- notify path so exported counts stay coherent with accepted history.
        if GS._NotifyLocalDurableChange then
            GS._NotifyLocalDurableChange("ledger")
        elseif GS.NotifyLocalDurableChange then
            GS.NotifyLocalDurableChange("ledger")
        end
    end
    return "accepted", accepted
end

--- Admit a remote/relayed withdrawal receipt at informational trust.
-- Requires authenticated same-guild sender. Does not require editor authority.
-- Informational trust limit: any authenticated same-guild member may relay a
-- well-formed receipt; transport sender GUID is not cryptographic proof the
-- actor performed the bank move. When sender ~= actorGuid, provenance is RELAY.
function GS.AdmitWithdrawalEvent(record, event, opts)
    opts = opts or {}
    if type(record) ~= "table" then
        return "rejected", "not_ready"
    end
    local datasetId = record.datasetId
    local ok, err = GS.ValidateWithdrawalEventBody(event, datasetId)
    if not ok then
        return "rejected", err or "invalid_event"
    end
    local canon = GS.CanonicalWithdrawalEvent(event)
    if not canon then
        return "rejected", "invalid_event"
    end
    if canon.datasetId and canon.datasetId ~= datasetId then
        return "rejected", "dataset_mismatch"
    end
    canon.datasetId = datasetId

    local sender = opts.senderGuid or opts.sender
    if type(sender) ~= "string" or sender == "" then
        return "rejected", "unauthorized"
    end
    -- Informational trust: authenticated same-guild membership is required.
    -- Editor authority is NOT required (ordinary withdrawers may originate).
    if opts.requireGuildMember ~= false then
        if not opts.memberAuthenticated then
            return "rejected", "unauthorized"
        end
    end
    -- Scope against the bound record: guild, campaign, generation, dataset.
    if canon.guildKey and record._guildKey and canon.guildKey ~= record._guildKey then
        return "rejected", "guild_mismatch"
    end
    if not canon.guildKey and record._guildKey then
        canon.guildKey = record._guildKey
    end
    local campaignId = canon.campaignId
    local isCurrent = record.currentCampaignId == campaignId
    local archive = type(record.campaignArchives) == "table"
        and record.campaignArchives[campaignId] or nil
    if isCurrent then
        -- Live campaign is represented.
    elseif type(archive) == "table" then
        -- Represented archived campaign.
    elseif type(record.campaigns) == "table" and record.campaigns[campaignId] then
        -- Header without archive generation data: wait for represented scope.
        return "pending", "missing_campaign"
    else
        return "pending", "missing_campaign"
    end
    local cfg = record.accounting and record.accounting._consumables
    local liveGen = tonumber(cfg and cfg.generation)
    local eventGen = tonumber(canon.generation)
    if not eventGen then
        return "rejected", "invalid_generation"
    end
    if isCurrent then
        -- Live campaign receipts must match the live generation exactly.
        -- Older gens under the current ID must not transplant into another
        -- archived campaign's history projection.
        if not liveGen then
            return "pending", "missing_generation"
        end
        if eventGen ~= liveGen then
            return "rejected", "generation_mismatch"
        end
    else
        local archGen = archive and tonumber(archive.generation)
        if not archGen then
            return "pending", "missing_campaign"
        end
        if eventGen ~= archGen then
            return "rejected", "generation_mismatch"
        end
    end

    if type(sender) == "string" and sender ~= "" and sender ~= canon.actorGuid then
        canon.provenance = GS.WITHDRAWAL_PROVENANCE.RELAY
    end

    local existing = FindLedgerEventById(record, canon.id)
    if existing then
        local existingId = GS.CanonicalWithdrawalEventIdentity(existing)
        local incomingId = GS.CanonicalWithdrawalEventIdentity(canon)
        if existingId and incomingId and GS._DeepEqualOps
            and GS._DeepEqualOps(existingId, incomingId) then
            -- Same logical receipt via origin/relay: keep ORIGIN if either path
            -- established it; otherwise retain stored provenance.
            if existing.provenance ~= GS.WITHDRAWAL_PROVENANCE.ORIGIN
                and canon.provenance == GS.WITHDRAWAL_PROVENANCE.ORIGIN then
                existing.provenance = GS.WITHDRAWAL_PROVENANCE.ORIGIN
                if GS.RefreshLedgerEventExport then
                    GS.RefreshLedgerEventExport(record, existing)
                end
            end
            return "duplicate", "duplicate"
        end
        -- Conflicting same-ID body: fail closed; do not replace.
        return "rejected", "id_conflict"
    end

    local appendOk, appendErr = AppendWithdrawalEvent(record, canon)
    if not appendOk then
        return "rejected", appendErr or "full"
    end
    Debug("Info", "admitted withdrawal %s qty=%s item=%s",
        tostring(canon.id), tostring(canon.quantity), tostring(canon.itemId))
    -- Publish into the live export index when this is the durable current
    -- record. Do not equate mere offlineRecord presence with adoption —
    -- ordinary provider admission also supplies the current record that way.
    -- Suppress only for adoptionReplay or temporary non-current records.
    if not opts.adoptionReplay then
        local current = GS.GetCurrentRecord and select(1, GS:GetCurrentRecord())
        if current and record == current then
            if GS.RefreshLedgerEventExport then
                pcall(GS.RefreshLedgerEventExport, record, canon)
            end
            if GS._NotifyLocalDurableChange then
                GS._NotifyLocalDurableChange("ledger")
            elseif GS.NotifyLocalDurableChange then
                GS.NotifyLocalDurableChange("ledger")
            end
        end
    end
    return "accepted", nil
end

--- True when withdrawal history still has room for `need` new receipts at the
-- settlement destination implied by meta.generation (live vs archived).
function GS.WithdrawalReceiptCapacityOk(record, need, meta)
    need = tonumber(need) or 1
    if need < 1 then
        return true
    end
    local cfg = record.accounting and record.accounting._consumables
    local curGen = tonumber(cfg and cfg.generation) or 1
    local eventGen = meta and tonumber(meta.generation) or curGen
    local liveOk, archOk, liveCount, archCount = WithdrawalCapacityAvailable(record)
    local maxLive = GS.MAX_WITHDRAWAL_EVENTS or 1024
    local maxArch = GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS or 1024
    if eventGen and eventGen < curGen then
        if not archOk then
            return false
        end
        return (archCount or 0) + need <= maxArch
    end
    if not liveOk then
        return false
    end
    if (liveCount or 0) + need > maxLive then
        return false
    end
    local list = record.accounting and record.accounting._consumableEvents
    local total = type(list) == "table" and #list or 0
    local maxCombined = (GS.MAX_LEDGER_EVENTS or 4096) + maxLive
    return total + need <= maxCombined
end
