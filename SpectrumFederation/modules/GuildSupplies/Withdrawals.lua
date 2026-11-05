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
    if type(event.datasetId) == "string" and datasetId and event.datasetId ~= datasetId then
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
    local ts = tonumber(event.timestamp)
    if not ts or ts ~= math.floor(ts) or ts < 0 then
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

local function FindLedgerEventById(record, id)
    if type(record) ~= "table" or type(id) ~= "string" or id == "" then
        return nil
    end
    local function scan(list)
        if type(list) ~= "table" then
            return nil
        end
        for i = 1, #list do
            local event = list[i]
            if type(event) == "table" and event.id == id then
                return event
            end
        end
        return nil
    end
    return scan(record.accounting and record.accounting._consumableEvents)
        or scan(record.accounting and record.accounting._consumableEventArchive)
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
        -- Protect total archive array bound as well.
        if #archive >= (GS.MAX_ARCHIVED_EVENTS or 4096) then
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
    -- Protect shared array ceiling: withdrawals may use leftover slots beyond
    -- donation occupancy up to MAX_LEDGER_EVENTS + reserved withdrawal headroom
    -- is not available; instead require both the withdrawal count and the
    -- combined list length stay within MAX_LEDGER_EVENTS + MAX_WITHDRAWAL_EVENTS.
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
    -- Bind actor to the actual local player; UI cannot nominate another character.
    local ctx = GS:GetCurrentContext()
    if not ctx or not ctx.ready then
        return "rejected", (ctx and ctx.reason) or "not_ready"
    end
    meta.actorGuid = ctx.actorGuid
    meta.actor = ctx.actorName or meta.actor
    meta.guildKey = ctx.guildKey
    meta.datasetId = record.datasetId
    if type(record.currentCampaignId) == "string" then
        -- Prefer captured original campaign from the withdrawal operation.
        meta.campaignId = meta.campaignId or record.currentCampaignId
    end
    local events, buildErr = GS.BuildWithdrawalReceipts(amounts, meta)
    if not events then
        return "rejected", buildErr or "invalid_amounts"
    end
    -- Capacity preflight before mutating.
    local need = #events
    local liveOk, _, liveCount = WithdrawalCapacityAvailable(record)
    if (not liveOk) or ((liveCount or 0) + need > (GS.MAX_WITHDRAWAL_EVENTS or 1024)) then
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
            local existingCanon = GS.CanonicalWithdrawalEvent(existing)
            if existingCanon and GS._DeepEqualOps and GS._DeepEqualOps(existingCanon, event) then
                -- duplicate ok
            elseif existingCanon then
                return "rejected", "id_conflict"
            else
                return "rejected", "id_conflict"
            end
        else
            local ok, err = AppendWithdrawalEvent(record, event)
            if not ok then
                return "rejected", err or "full"
            end
            accepted = accepted + 1
            if GS.ExportLedgerEvent then
                -- Optional paced export hook shared with donations.
                pcall(GS.ExportLedgerEvent, record, event)
            end
        end
    end
    if accepted > 0 and GS.NotifyLocalDurableChange then
        GS.NotifyLocalDurableChange("withdrawal-receipt")
    end
    if GS.NotifyProviderChanged then
        GS.NotifyProviderChanged("withdrawal-receipt")
    end
    return "accepted", accepted
end

--- Admit a remote/relayed withdrawal receipt at informational trust.
-- Requires authenticated same-guild sender. Does not require editor authority.
-- Origin path: sender GUID must equal actorGuid. Relay path: any authenticated
-- same-guild member may forward an already-formed origin/relay body without
-- rewriting actor fields.
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
    if canon.provenance == GS.WITHDRAWAL_PROVENANCE.ORIGIN then
        if sender ~= canon.actorGuid and not opts.allowRelayOfOrigin then
            -- Treat mismatched origin claims as relay only when explicitly allowed;
            -- otherwise reject spoofed origin attribution.
            if opts.forceRelay then
                canon.provenance = GS.WITHDRAWAL_PROVENANCE.RELAY
            else
                return "rejected", "actor_mismatch"
            end
        end
    end

    local existing = FindLedgerEventById(record, canon.id)
    if existing then
        local existingCanon = GS.CanonicalWithdrawalEvent(existing)
        if existingCanon and GS._DeepEqualOps and GS._DeepEqualOps(existingCanon, canon) then
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
    return "accepted", nil
end

--- True when withdrawal history still has room for `need` new live receipts.
function GS.WithdrawalReceiptCapacityOk(record, need)
    need = tonumber(need) or 1
    if need < 1 then
        return true
    end
    local liveOk, _, liveCount = WithdrawalCapacityAvailable(record)
    if not liveOk then
        return false
    end
    return (liveCount or 0) + need <= (GS.MAX_WITHDRAWAL_EVENTS or 1024)
end
