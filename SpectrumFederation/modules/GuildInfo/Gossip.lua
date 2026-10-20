-- Guild Info Guild Gossip provider (#402).
-- Exchanges versioned membership/group current-state records.
local addonName, SF = ...

SF.GuildInfo = SF.GuildInfo or {}
local GI = SF.GuildInfo

local GG = nil

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

local function MaxRecordCbor()
    local g = Gossip()
    return tonumber(g and g.MAX_RECORD_CBOR) or 2048
end

local function HashParts(...)
    local g = Gossip()
    if not g or not g.Hash32 then
        return table.concat({ ... }, "\0")
    end
    return string.format("%08x", g.Hash32(table.concat({ ... }, "\0")))
end

local function MemberRecordId(guid)
    return "gi-m:" .. tostring(guid)
end

local function GroupRecordId(groupId)
    return "gi-g:" .. tostring(groupId)
end

local function MemberVersionFp(m)
    return HashParts(
        tostring(m.guid or ""),
        tostring(m.groupId == false and "U" or m.groupId or ""),
        tostring(m.ver and m.ver.n or 0),
        tostring(m.ver and m.ver.w or ""),
        tostring(m.at or 0),
        tostring(m.nameRealm or ""),
        tostring(m.classFile or "")
    )
end

local function GroupVersionFp(g)
    return HashParts(
        tostring(g.groupId or ""),
        tostring(g.mainGuid or ""),
        tostring(g.ver and g.ver.n or 0),
        tostring(g.ver and g.ver.w or ""),
        tostring(g.at or 0),
        g.dissolved and "1" or "0"
    )
end

local function WireForMember(m)
    if type(m) ~= "table" or type(m.guid) ~= "string" then
        return nil
    end
    return {
        id = MemberRecordId(m.guid),
        versionFp = MemberVersionFp(m),
        body = {
            kind = "guildinfo-member",
            schema = GI.PROVIDER_SCHEMA,
            member = m,
        },
    }
end

local function WireForGroup(g)
    if type(g) ~= "table" or type(g.groupId) ~= "string" then
        return nil
    end
    return {
        id = GroupRecordId(g.groupId),
        versionFp = GroupVersionFp(g),
        body = {
            kind = "guildinfo-group",
            schema = GI.PROVIDER_SCHEMA,
            group = g,
        },
    }
end

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
    if not record then
        return
    end
    local bodies = GI.ListStateBodies(record)
    for i = 1, #bodies do
        local wire
        if bodies[i].kind == "guildinfo-member" then
            wire = WireForMember(bodies[i].member)
        else
            wire = WireForGroup(bodies[i].group)
        end
        if wire and GI.RecordWithinGossipCap(wire) then
            exportState.byId[wire.id] = {
                id = wire.id,
                versionFp = wire.versionFp,
                body = wire.body,
            }
            exportState.order[#exportState.order + 1] = wire.id
        else
            DebugWarn("skipping oversize guildInfo export id=%s", wire and wire.id or "?")
        end
    end
end

local function UpsertExportWire(wire)
    if not wire or not GI.RecordWithinGossipCap(wire) then
        if wire then
            DebugWarn("refusing oversize guildInfo export id=%s", tostring(wire.id))
        end
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

--- Admit a remote gossip record. Only authenticated editor senders may introduce state.
local function ValidateAndApply(record, ctx)
    if type(record) ~= "table" or type(record.body) ~= "table" then
        return "rejected", "malformed"
    end
    if ctx and ctx.localWrite then
        return "rejected", "use_local_api"
    end
    if not GI.RecordWithinGossipCap(record) then
        return "rejected", "record_too_large"
    end
    local body = record.body
    local kind = body.kind
    if kind ~= "guildinfo-member" and kind ~= "guildinfo-group" then
        return "rejected", "unsupported_kind"
    end
    if tonumber(body.schema) and tonumber(body.schema) ~= GI.PROVIDER_SCHEMA then
        return "rejected", "unsupported_schema"
    end

    local sender = ctx and ctx.sender
    local member, authReason = GI.AuthenticateTransportSender(sender)
    if not member then
        return "rejected", authReason or "unauthorized"
    end
    local mayEdit, editReason = GI.SenderHasEditorAuthority(member)
    if not mayEdit then
        return "rejected", editReason or "unauthorized"
    end

    local guildRec = select(1, GI:EnsureGuildRecord(member.guildKey))
    if not guildRec then
        return "rejected", "not_ready"
    end

    local status, detail
    if kind == "guildinfo-member" then
        local m = body.member
        if type(m) ~= "table" then
            return "rejected", "malformed"
        end
        status, detail = GI.MergeMember(guildRec, m, { remote = true })
        if status == "accepted" then
            UpsertExportWire(WireForMember(guildRec.members[m.guid]))
        end
    else
        local g = body.group
        if type(g) ~= "table" then
            return "rejected", "malformed"
        end
        status, detail = GI.MergeGroup(guildRec, g, { remote = true })
        if status == "accepted" then
            local live = guildRec.groups[g.groupId]
            if live then
                UpsertExportWire(WireForGroup(live))
            end
            -- Dissolved groups still export so peers learn the tombstone.
            if live and live.dissolved then
                BumpPhysicalIndex(nil)
            end
        end
    end

    if status == "accepted" then
        if GI.NotifyUI then
            GI.NotifyUI("remote")
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
        local needEpoch = reason == "local" or reason == "remote" or exportState.guildKey ~= guildKey
        RebuildExportIndex()
        if needEpoch or reason == "remote" then
            BumpPhysicalIndex(nil)
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

local _previousInitialize = GI.Initialize
function GI:Initialize(db)
    local ok, reason = true, nil
    if _previousInitialize then
        ok, reason = _previousInitialize(self, db)
    end
    if ok then
        GI:EnsureGossipProvider()
    end
    return ok, reason
end
