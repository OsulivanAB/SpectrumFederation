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

-- Remote catch-up coalescing: mark dirty during ValidateAndApply batches and
-- rebuild/bump once on the next export/index read (not per accepted record).
local exportDirty = false
local exportDirtyNeedsBump = false
local exportRebuildCount = 0
local exportBumpCount = 0

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

local function MemberVersionFp(m, gen)
    return HashParts(
        tostring(m.guid or ""),
        tostring(m.groupId == false and "U" or m.groupId or ""),
        tostring(m.ver and m.ver.n or 0),
        tostring(m.ver and m.ver.w or ""),
        tostring(m.at or 0),
        tostring(m.nameRealm or ""),
        tostring(m.classFile or ""),
        tostring(gen and gen.n or 0),
        tostring(gen and gen.w or "")
    )
end

local function GroupVersionFp(g, gen)
    return HashParts(
        tostring(g.groupId or ""),
        tostring(g.mainGuid or ""),
        tostring(g.ver and g.ver.n or 0),
        tostring(g.ver and g.ver.w or ""),
        tostring(g.at or 0),
        g.dissolved and "1" or "0",
        tostring(g.forwardTo or ""),
        tostring(gen and gen.n or 0),
        tostring(gen and gen.w or "")
    )
end

local function EpochVersionFp(body)
    local seal = body and body.sealRev
    return HashParts(
        "epoch",
        tostring(body.gen and body.gen.n or 0),
        tostring(body.gen and body.gen.w or ""),
        tostring(body.memberCount or 0),
        tostring(body.groupCount or 0),
        tostring(body.contentFp or ""),
        tostring(seal and seal.n or 0),
        tostring(seal and seal.w or "")
    )
end

local function WireForEpoch(body)
    if type(body) ~= "table" or type(body.gen) ~= "table" then
        return nil
    end
    local seal = body.sealRev
    local wireBody = {
        kind = "guildinfo-epoch",
        schema = GI.PROVIDER_SCHEMA,
        gen = { n = body.gen.n, w = body.gen.w },
        memberCount = tonumber(body.memberCount) or 0,
        groupCount = tonumber(body.groupCount) or 0,
        contentFp = tostring(body.contentFp or ""),
    }
    if type(seal) == "table" and seal.n ~= nil and type(seal.w) == "string" then
        wireBody.sealRev = { n = seal.n, w = seal.w }
    end
    return {
        id = GI.EpochRecordId and GI.EpochRecordId() or "gi-e:current",
        versionFp = EpochVersionFp(body),
        body = wireBody,
    }
end

local function WireForMember(m, gen)
    if type(m) ~= "table" or type(m.guid) ~= "string" then
        return nil
    end
    return {
        id = MemberRecordId(m.guid),
        versionFp = MemberVersionFp(m, gen),
        body = {
            kind = "guildinfo-member",
            schema = GI.PROVIDER_SCHEMA,
            gen = gen and { n = gen.n, w = gen.w } or nil,
            member = m,
        },
    }
end

local function WireForGroup(g, gen)
    if type(g) ~= "table" or type(g.groupId) ~= "string" then
        return nil
    end
    return {
        id = GroupRecordId(g.groupId),
        versionFp = GroupVersionFp(g, gen),
        body = {
            kind = "guildinfo-group",
            schema = GI.PROVIDER_SCHEMA,
            gen = gen and { n = gen.n, w = gen.w } or nil,
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
    exportDirty = false
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
        local b = bodies[i]
        if b.kind == "guildinfo-epoch" then
            wire = WireForEpoch(b)
        elseif b.kind == "guildinfo-member" then
            wire = WireForMember(b.member, b.gen)
        else
            wire = WireForGroup(b.group, b.gen)
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
    exportRebuildCount = exportRebuildCount + 1
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

--- Materialize a dirty export before serving/indexing. One rebuild+bump covers an
-- entire remote admission batch instead of O(N) synchronous full resets.
local function EnsureExportFresh()
    if not exportDirty then
        return false
    end
    local needBump = exportDirtyNeedsBump
    RebuildExportIndex()
    if needBump then
        exportDirtyNeedsBump = false
        if BumpPhysicalIndex(nil) then
            exportBumpCount = exportBumpCount + 1
        end
    else
        exportDirtyNeedsBump = false
    end
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
        exportDirty = false
        exportDirtyNeedsBump = false
        RebuildExportIndex()
        if BumpPhysicalIndex(index) then
            exportBumpCount = exportBumpCount + 1
        end
        exportState.enumPos = 1
    else
        EnsureExportFresh()
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
                exportBumpCount = exportBumpCount + 1
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
        exportDirty = false
        exportDirtyNeedsBump = false
        RebuildExportIndex()
        if BumpPhysicalIndex(nil) then
            exportBumpCount = exportBumpCount + 1
        end
    else
        EnsureExportFresh()
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
        exportDirty = false
        exportDirtyNeedsBump = false
        RebuildExportIndex()
        if BumpPhysicalIndex(nil) then
            exportBumpCount = exportBumpCount + 1
        end
    else
        EnsureExportFresh()
    end
    local r = exportState.byId[tostring(recordId)]
    return r and r.versionFp or nil
end

local function GetRecordBody(recordId)
    local guildKey = CurrentGuildKey()
    if exportState.guildKey ~= guildKey then
        exportDirty = false
        exportDirtyNeedsBump = false
        RebuildExportIndex()
        if BumpPhysicalIndex(nil) then
            exportBumpCount = exportBumpCount + 1
        end
    else
        EnsureExportFresh()
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
    if kind ~= "guildinfo-member" and kind ~= "guildinfo-group" and kind ~= "guildinfo-epoch" then
        return "rejected", "unsupported_kind"
    end
    -- Schema 2 (pre-epoch) wires are rejected once the provider speaks schema 3.
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

    -- Duplicate/stale admits can still complete an incomplete baseline via
    -- NoteIncompleteAdmit tip windows; export must refresh on that transition.
    local beforeComplete = GI.IsBaselineComplete and GI.IsBaselineComplete(guildRec)

    local status, detail
    if kind == "guildinfo-epoch" then
        local okAdopt, adoptDetail = GI.AdoptSyncGeneration(guildRec, body)
        if not okAdopt then
            return "rejected", adoptDetail or "stale_generation"
        end
        status = adoptDetail == "duplicate" and "duplicate" or "accepted"
        detail = adoptDetail
    elseif kind == "guildinfo-member" then
        local m = body.member
        if type(m) ~= "table" then
            return "rejected", "malformed"
        end
        status, detail = GI.MergeMember(guildRec, m, { remote = true, gen = body.gen, sender = sender })
    else
        local g = body.group
        if type(g) ~= "table" then
            return "rejected", "malformed"
        end
        status, detail = GI.MergeGroup(guildRec, g, { remote = true, gen = body.gen, sender = sender })
    end

    local afterComplete = GI.IsBaselineComplete and GI.IsBaselineComplete(guildRec)
    local becameComplete = (not beforeComplete) and afterComplete and true or false
    if status == "accepted" or becameComplete then
        -- Rebuild export + invalidate the completed physical index so peers can
        -- discover new/updated fingerprints via this editor's provider index.
        -- Also drops reclaimed group record IDs from the physical index.
        -- Harmless duplicates on an already-complete baseline do not notify.
        if GI.NotifyLocalDurableChange then
            GI.NotifyLocalDurableChange("remote")
        else
            RebuildExportIndex()
            BumpPhysicalIndex(nil)
            local g = Gossip()
            if g and g.NotifyProviderChanged then
                g.NotifyProviderChanged(GI.PROVIDER_ID)
            end
            if GI.NotifyUI then
                GI.NotifyUI("remote")
            end
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
        if reason == "remote" then
            -- Coalesce: accept durable state immediately, defer full export rebuild
            -- and physical-index reset until the next index/export read.
            exportDirty = true
            exportDirtyNeedsBump = true
            local g = Gossip()
            if g and g.NotifyProviderChanged then
                g.NotifyProviderChanged(GI.PROVIDER_ID)
            end
        else
            exportDirty = false
            exportDirtyNeedsBump = false
            local needEpoch = reason == "local" or exportState.guildKey ~= guildKey
            RebuildExportIndex()
            if needEpoch then
                if BumpPhysicalIndex(nil) then
                    exportBumpCount = exportBumpCount + 1
                end
            end
            local g = Gossip()
            if g and g.NotifyProviderChanged then
                g.NotifyProviderChanged(GI.PROVIDER_ID)
            end
        end
    end
    GI.NotifyUI(reason)
end

function GI.ResetExportPerfCounters()
    exportRebuildCount = 0
    exportBumpCount = 0
end

function GI.GetExportPerfCounters()
    return {
        rebuilds = exportRebuildCount,
        bumps = exportBumpCount,
        dirty = exportDirty and true or false,
    }
end

--- Test/helper: force any coalesced remote export flush now.
function GI.FlushPendingExport()
    return EnsureExportFresh()
end

GI._NotifyLocalDurableChange = GI.NotifyLocalDurableChange
GI._RebuildExportIndex = RebuildExportIndex
GI._BumpPhysicalIndex = BumpPhysicalIndex
GI._EnsureExportFresh = EnsureExportFresh

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
