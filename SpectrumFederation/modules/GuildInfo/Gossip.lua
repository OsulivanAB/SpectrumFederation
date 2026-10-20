-- Guild Info Guild Gossip provider (#402).
-- Own provider id; sync independent of Settings visibility and Guild Supplies.
local addonName, SF = ...

SF.GuildInfo = SF.GuildInfo or {}
local GI = SF.GuildInfo

local GG = nil -- bound lazily

local function Gossip()
    if not GG then
        GG = SF.GuildGossip
    end
    return GG
end

local function DebugInfo(fmt, ...)
    if SF.Debug and SF.Debug.Info and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Info("GUILD_INFO", fmt, ...)
    end
end

local function DebugWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Warn("GUILD_INFO", fmt, ...)
    end
end

local providerRegistered = false
local exportState = {
    order = {},
    byId = {},
    enumPos = nil,
    guildKey = nil,
}

local uiListeners = {}
local uiNotifying = false
local uiNotifyQueued = false
local uiNotifyQueuedReason = nil

local function CurrentGuildKey()
    local g = Gossip()
    if not g or type(g.GetGuildIdentity) ~= "function" then
        return nil
    end
    local identity = g.GetGuildIdentity()
    return identity and identity.guildKey or nil
end

local function GetScopeId()
    local g = Gossip()
    if g and type(g.GetGuildScopeId) == "function" then
        return g.GetGuildScopeId()
    end
    return nil
end

local function IsPeerEligible(peerName, ctx)
    local g = Gossip()
    if not g or type(g.IsGuildMember) ~= "function" then
        return false
    end
    return g.IsGuildMember(peerName) and true or false
end

local function GetCapabilities()
    return { guildInfo = true }
end

local function OpVersionFp(op)
    local g = Gossip()
    if not g or not g.Hash32 then
        return tostring(op and op.id or "")
    end
    local parts = {
        tostring(op.id or ""),
        tostring(op.kind or ""),
        tostring(op.at or 0),
        tostring(op.mainGuid or ""),
        tostring(op.altGuid or ""),
        tostring(op.newMainGuid or ""),
        tostring(op.actorGuid or ""),
    }
    return string.format("%08x", g.Hash32(table.concat(parts, "\0")))
end

local function RecordIdForOp(opId)
    return "gi-op:" .. tostring(opId)
end

local function MaxRecordCbor()
    local g = Gossip()
    return tonumber(g and g.MAX_RECORD_CBOR) or 2048
end

--- Wire-shape body used by the engine (id + versionFp + body).
local function WireRecordForOp(op)
    if type(op) ~= "table" or type(op.id) ~= "string" then
        return nil
    end
    local rid = RecordIdForOp(op.id)
    local vfp = OpVersionFp(op)
    return {
        id = rid,
        versionFp = vfp,
        body = {
            kind = "guildinfo-op",
            op = op,
        },
    }
end

--- Whether a provider record fits Guild Gossip's serialized record cap.
function GI.RecordWithinGossipCap(record)
    if type(record) ~= "table" then
        return false
    end
    local enc = C_EncodingUtil
    if not enc or type(enc.SerializeCBOR) ~= "function" then
        return false
    end
    local ok, raw = pcall(enc.SerializeCBOR, record)
    if not ok or type(raw) ~= "string" then
        return false
    end
    return #raw <= MaxRecordCbor(), #raw
end

local function RebuildExportIndex()
    exportState.order = {}
    exportState.byId = {}
    exportState.enumPos = nil
    local guildKey = CurrentGuildKey()
    exportState.guildKey = guildKey
    if not guildKey or not GI:IsRootReady() then
        return
    end
    local record = select(1, GI:GetRecordForGuildKey(guildKey))
    if not record or type(record.order) ~= "table" then
        return
    end
    for i = 1, #record.order do
        local opId = record.order[i]
        local op = record.ops and record.ops[opId]
        if type(op) == "table" then
            local wire = WireRecordForOp(op)
            if wire and GI.RecordWithinGossipCap(wire) then
                exportState.byId[wire.id] = {
                    id = wire.id,
                    versionFp = wire.versionFp,
                    body = wire.body,
                }
                exportState.order[#exportState.order + 1] = wire.id
            else
                DebugWarn("skipping oversize guildInfo export id=%s", tostring(opId))
            end
        end
    end
end

local function UpsertExportOp(op)
    local wire = WireRecordForOp(op)
    if not wire then
        return
    end
    if not GI.RecordWithinGossipCap(wire) then
        DebugWarn("refusing oversize guildInfo export id=%s", tostring(op.id))
        return
    end
    local rid = wire.id
    local existing = exportState.byId[rid]
    exportState.byId[rid] = {
        id = rid,
        versionFp = wire.versionFp,
        body = wire.body,
    }
    if not existing then
        exportState.order[#exportState.order + 1] = rid
    end
end

local function ProviderEntry()
    local g = Gossip()
    if not g or type(g.GetProvider) ~= "function" then
        return nil
    end
    return g.GetProvider(GI.PROVIDER_ID)
end

--- Bump the physical Gossip index so vanished IDs and guild-scope changes
-- invalidate active views/bookmarks (not merely local exportState).
local function BumpPhysicalIndex(index)
    local g = Gossip()
    local idx = index
    if not idx then
        local entry = ProviderEntry()
        idx = entry and entry.index
    end
    if not idx or not g or type(g.BumpIndexEpoch) ~= "function" then
        return false
    end
    g.BumpIndexEpoch(idx)
    idx.buildComplete = false
    idx.dirty = true
    return true
end

local function OnIndexInvalidated()
    exportState.enumPos = nil
end

local function EnsureIndex(index, limits)
    local g = Gossip()
    local budget = math.max(1, tonumber(limits and limits.indexEntries) or 8)
    local guildKey = CurrentGuildKey()
    -- Guild-scope transitions must invalidate before any completed-index fast path
    -- so guild A bodies are never advertised under guild B's scope.
    if exportState.guildKey ~= guildKey then
        RebuildExportIndex()
        BumpPhysicalIndex(index)
        exportState.enumPos = 1
    end
    if index.buildComplete and not index.dirty then
        return false, 0
    end
    if not exportState.enumPos then
        exportState.enumPos = 1
    end
    local n = 0
    while exportState.enumPos <= #exportState.order and n < budget do
        local rid = exportState.order[exportState.enumPos]
        exportState.enumPos = exportState.enumPos + 1
        local r = exportState.byId[rid]
        if r and g and g.IndexUpsert then
            local _, detail = g.IndexUpsert(index, rid, r.versionFp, r)
            if detail == "replaced" then
                g.BumpIndexEpoch(index)
                exportState.enumPos = 1
                return true, n + 1
            end
        end
        n = n + 1
    end
    if exportState.enumPos > #exportState.order then
        exportState.enumPos = nil
        index.buildComplete = true
        index.dirty = false
        return false, n
    end
    return true, n
end

local function ListRecordIds(cursor, limit)
    cursor = math.max(1, tonumber(cursor) or 1)
    limit = math.max(1, tonumber(limit) or 32)
    local guildKey = CurrentGuildKey()
    if exportState.guildKey ~= guildKey then
        RebuildExportIndex()
        BumpPhysicalIndex(nil)
    end
    local page = {}
    local i = cursor
    while i <= #exportState.order and #page < limit do
        page[#page + 1] = exportState.order[i]
        i = i + 1
    end
    if i <= #exportState.order then
        return page, i
    end
    return page, nil
end

local function GetRecordVersionFp(recordId)
    local guildKey = CurrentGuildKey()
    if exportState.guildKey ~= guildKey then
        RebuildExportIndex()
        BumpPhysicalIndex(nil)
    end
    local r = exportState.byId[tostring(recordId)]
    return r and r.versionFp or nil
end

local function GetRecordBody(recordId)
    local guildKey = CurrentGuildKey()
    if exportState.guildKey ~= guildKey then
        RebuildExportIndex()
        BumpPhysicalIndex(nil)
    end
    local r = exportState.byId[tostring(recordId)]
    if not r then
        return nil
    end
    local wire = { id = r.id, versionFp = r.versionFp, body = r.body }
    if not GI.RecordWithinGossipCap(wire) then
        return nil
    end
    return wire
end

local function ValidProvenanceGuid(guid)
    return type(guid) == "string" and guid ~= "" and guid ~= "compact" and #guid <= (GI.MAX_GUID or 64)
end

--- Admit a remote gossip record. Only authenticated editor senders may introduce ops.
-- Authorization is solely the transport-authenticated editor sender. Payload
-- actorGuid is provenance (kept version-stable for relay/catch-up), never auth.
local function ValidateAndApply(record, ctx)
    if type(record) ~= "table" or type(record.body) ~= "table" then
        return "rejected", "malformed"
    end
    if ctx and ctx.localWrite then
        return "rejected", "use_local_api"
    end
    -- Enforce the same serialized size bound the engine uses before mutation.
    if not GI.RecordWithinGossipCap(record) then
        return "rejected", "record_too_large"
    end
    local body = record.body
    if body.kind ~= "guildinfo-op" or type(body.op) ~= "table" then
        return "rejected", "unsupported_kind"
    end
    local op = body.op
    local sender = ctx and ctx.sender
    local member, authReason = GI.AuthenticateTransportSender(sender)
    if not member then
        return "rejected", authReason or "unauthorized"
    end
    local mayEdit, editReason = GI.SenderHasEditorAuthority(member)
    if not mayEdit then
        return "rejected", editReason or "unauthorized"
    end
    if type(op.guildKey) ~= "string" or op.guildKey ~= member.guildKey then
        return "rejected", "wrong_guild"
    end

    -- Keep stable provenance when present so A→B→C catch-up does not rewrite
    -- versionFp. Missing/synthetic actors bind to the authenticated editor.
    if not ValidProvenanceGuid(op.actorGuid) then
        op.actorGuid = member.guid
        op.actorName = member.name
    elseif type(op.actorName) ~= "string" or op.actorName == "" then
        if op.actorGuid == member.guid then
            op.actorName = member.name
        end
    end

    local status, detail = GI:AdmitOperation(op, { remote = true })
    if status == "accepted" then
        -- Cutover / legacy snapshot rewrite the live set; rebuild export + bump epoch
        -- so vanished pre-cutover IDs cannot keep circulating.
        if op.kind == GI.KIND.SNAPSHOT or op.kind == GI.KIND.CUTOVER then
            RebuildExportIndex()
            BumpPhysicalIndex(nil)
        else
            UpsertExportOp(op)
        end
    end
    return status, detail
end

local function BuildProviderSpec()
    return {
        id = GI.PROVIDER_ID,
        schema = GI.PROVIDER_SCHEMA,
        enabled = true,
        ready = true,
        GetScopeId = GetScopeId,
        IsPeerEligible = IsPeerEligible,
        GetCapabilities = GetCapabilities,
        EnsureIndex = EnsureIndex,
        OnIndexInvalidated = OnIndexInvalidated,
        ListRecordIds = ListRecordIds,
        GetRecordVersionFp = GetRecordVersionFp,
        GetRecordBody = GetRecordBody,
        ValidateAndApply = ValidateAndApply,
    }
end

function GI:EnsureGossipProvider()
    local g = Gossip()
    if not g or not g.RegisterProvider then
        return false, "gossip_unavailable"
    end
    if providerRegistered and g.GetProvider and g.GetProvider(GI.PROVIDER_ID) then
        return true
    end
    if g.Init then
        g.Init()
    end
    local ok, err = g.RegisterProvider(BuildProviderSpec())
    if not ok and err and err ~= "already_registered" then
        if g.GetProvider and g.GetProvider(GI.PROVIDER_ID) then
            providerRegistered = true
            return true
        end
        DebugWarn("provider register failed: %s", tostring(err))
        return false, err
    end
    if g.SetProviderEnabled then
        g.SetProviderEnabled(GI.PROVIDER_ID, true)
    end
    providerRegistered = true
    RebuildExportIndex()
    DebugInfo("registered guild info provider id=%s", GI.PROVIDER_ID)
    return true
end

function GI.RegisterUIListener(fn)
    if type(fn) ~= "function" then
        return nil
    end
    uiListeners[#uiListeners + 1] = fn
    return fn
end

local function DeliverUINotify(reason)
    if uiNotifying then
        return
    end
    uiNotifying = true
    for i = 1, #uiListeners do
        local fn = uiListeners[i]
        if type(fn) == "function" then
            pcall(fn, reason)
        end
    end
    uiNotifying = false
end

function GI.NotifyUI(reason)
    reason = tostring(reason or "local")
    if #uiListeners == 0 then
        return
    end
    if uiNotifying then
        uiNotifyQueuedReason = reason
        uiNotifyQueued = true
        return
    end
    DeliverUINotify(reason)
    while uiNotifyQueued do
        uiNotifyQueued = false
        local queued = uiNotifyQueuedReason
        uiNotifyQueuedReason = nil
        if queued then
            DeliverUINotify(queued)
        end
    end
end

function GI.NotifyLocalDurableChange(reason)
    reason = tostring(reason or "local")
    if providerRegistered then
        local guildKey = CurrentGuildKey()
        local prevOrder = exportState.order
        local needEpoch = reason == "compact" or exportState.guildKey ~= guildKey
        if needEpoch then
            RebuildExportIndex()
        else
            local record = guildKey and select(1, GI:GetRecordForGuildKey(guildKey)) or nil
            if record and type(record.order) == "table" then
                local live = {}
                for i = 1, #record.order do
                    local op = record.ops[record.order[i]]
                    if op then
                        UpsertExportOp(op)
                        live[RecordIdForOp(op.id)] = true
                    end
                end
                local newOrder = {}
                for i = 1, #exportState.order do
                    local rid = exportState.order[i]
                    if live[rid] then
                        newOrder[#newOrder + 1] = rid
                    else
                        exportState.byId[rid] = nil
                        needEpoch = true
                    end
                end
                if #newOrder ~= #exportState.order then
                    exportState.order = newOrder
                    exportState.enumPos = nil
                    needEpoch = true
                end
            else
                RebuildExportIndex()
                needEpoch = true
            end
        end
        if needEpoch then
            -- Vanish / scope / compaction: bump physical index so reconcile cannot
            -- keep serving deleted IDs from a completed index forever.
            local stale = reason == "compact"
            if not stale then
                for i = 1, #prevOrder do
                    if not exportState.byId[prevOrder[i]] then
                        stale = true
                        break
                    end
                end
            end
            if stale or reason == "compact" or exportState.guildKey ~= guildKey then
                BumpPhysicalIndex(nil)
            end
        end
        local g = Gossip()
        if g and g.NotifyProviderChanged then
            g.NotifyProviderChanged(GI.PROVIDER_ID)
        end
    end
    GI.NotifyUI(reason)
end

GI._NotifyLocalDurableChange = GI.NotifyLocalDurableChange
GI._RebuildExportIndex = RebuildExportIndex
GI._BumpPhysicalIndex = BumpPhysicalIndex

-- Hook Initialize to register the provider after the durable root is ready.
local _previousInitialize = GI.Initialize
function GI:Initialize(db)
    local ok, reason = true, nil
    if _previousInitialize then
        ok, reason = _previousInitialize(self, db)
    end
    GI:EnsureGossipProvider()
    return ok, reason
end
