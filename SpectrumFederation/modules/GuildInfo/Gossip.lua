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
            local rid = RecordIdForOp(opId)
            local vfp = OpVersionFp(op)
            exportState.byId[rid] = {
                id = rid,
                versionFp = vfp,
                body = {
                    kind = "guildinfo-op",
                    op = op,
                },
            }
            exportState.order[#exportState.order + 1] = rid
        end
    end
end

local function UpsertExportOp(op)
    if type(op) ~= "table" or type(op.id) ~= "string" then
        return
    end
    local rid = RecordIdForOp(op.id)
    local vfp = OpVersionFp(op)
    local existing = exportState.byId[rid]
    exportState.byId[rid] = {
        id = rid,
        versionFp = vfp,
        body = {
            kind = "guildinfo-op",
            op = op,
        },
    }
    if not existing then
        exportState.order[#exportState.order + 1] = rid
    end
end

local function OnIndexInvalidated()
    exportState.enumPos = nil
end

local function EnsureIndex(index, limits)
    local g = Gossip()
    local budget = math.max(1, tonumber(limits and limits.indexEntries) or 8)
    if index.buildComplete and not index.dirty then
        return false, 0
    end
    if exportState.guildKey ~= CurrentGuildKey() then
        RebuildExportIndex()
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
    if exportState.guildKey ~= CurrentGuildKey() then
        RebuildExportIndex()
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
    local r = exportState.byId[tostring(recordId)]
    return r and r.versionFp or nil
end

local function GetRecordBody(recordId)
    local r = exportState.byId[tostring(recordId)]
    if not r then
        return nil
    end
    return { id = r.id, versionFp = r.versionFp, body = r.body }
end

--- Admit a remote gossip record. Only authenticated editor senders may introduce ops.
local function ValidateAndApply(record, ctx)
    if type(record) ~= "table" or type(record.body) ~= "table" then
        return "rejected", "malformed"
    end
    if ctx and ctx.localWrite then
        return "rejected", "use_local_api"
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
    -- Bind actor from authenticated sender; reject laundering via payload claims.
    if type(op.actorGuid) == "string" and op.actorGuid ~= "" and op.actorGuid ~= member.guid then
        return "rejected", "actor_mismatch"
    end
    if type(op.guildKey) ~= "string" or op.guildKey ~= member.guildKey then
        return "rejected", "wrong_guild"
    end
    -- Ensure actor fields reflect authenticated sender for durable storage.
    op.actorGuid = member.guid
    op.actorName = member.name

    local status, detail = GI:AdmitOperation(op, { remote = true })
    if status == "accepted" then
        UpsertExportOp(op)
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
        if exportState.guildKey ~= guildKey then
            RebuildExportIndex()
        else
            -- Incremental: re-read record and upsert missing ops.
            local record = guildKey and select(1, GI:GetRecordForGuildKey(guildKey)) or nil
            if record and type(record.order) == "table" then
                for i = 1, #record.order do
                    local op = record.ops[record.order[i]]
                    if op then
                        UpsertExportOp(op)
                    end
                end
            else
                RebuildExportIndex()
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
