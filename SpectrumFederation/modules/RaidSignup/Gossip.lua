-- Raid Signup Guild Gossip provider (#404).
local addonName, SF = ...

SF.RaidSignup = SF.RaidSignup or {}
local RS = SF.RaidSignup

local GG = nil

local function Gossip()
    if not GG then
        GG = SF.GuildGossip
    end
    return GG
end

local function DebugInfo(fmt, ...)
    if SF.Debug and SF.Debug.Info and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Info("RAID_SIGNUP", fmt, ...)
    end
end

local function DebugWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Warn("RAID_SIGNUP", fmt, ...)
    end
end

local providerRegistered = false
local exportState = {
    order = {},
    byId = {},
    enumPos = nil,
    guildKey = nil,
}
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
    return { raidSignup = true }
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

local function PlanVersionFp(plan)
    return HashParts(
        tostring(plan.planId or ""),
        tostring(plan.name or ""),
        plan.archived and "1" or "0",
        tostring(plan.createdBy or ""),
        tostring(plan.ver and plan.ver.n or 0),
        tostring(plan.ver and plan.ver.w or ""),
        tostring(plan.at or 0)
    )
end

local function EntryVersionFp(entry)
    return HashParts(
        tostring(entry.entryId or ""),
        tostring(entry.planId or ""),
        tostring(entry.nickname or ""),
        tostring(entry.mainClass or ""),
        tostring(entry.mainSpec or ""),
        tostring(entry.altClass or ""),
        tostring(entry.altSpec or ""),
        tostring(entry.notes or ""),
        tostring(entry.creatorGuid or ""),
        entry.deleted and "1" or "0",
        tostring(entry.ver and entry.ver.n or 0),
        tostring(entry.ver and entry.ver.w or ""),
        tostring(entry.at or 0)
    )
end

local function WireForPlan(plan)
    if type(plan) ~= "table" or type(plan.planId) ~= "string" then
        return nil
    end
    return {
        id = RS.PlanRecordId(plan.planId),
        versionFp = PlanVersionFp(plan),
        body = {
            kind = "raidsignup-plan",
            schema = RS.PROVIDER_SCHEMA,
            plan = RS.ClonePlan(plan),
        },
    }
end

local function WireForEntry(entry)
    if type(entry) ~= "table" or type(entry.entryId) ~= "string" then
        return nil
    end
    return {
        id = RS.EntryRecordId(entry.entryId),
        versionFp = EntryVersionFp(entry),
        body = {
            kind = "raidsignup-entry",
            schema = RS.PROVIDER_SCHEMA,
            entry = RS.CloneEntry(entry),
        },
    }
end

function RS.RecordWithinGossipCap(record)
    if type(record) ~= "table" then
        return false
    end
    local enc = C_EncodingUtil
    if enc and enc.SerializeCBOR then
        local ok, payload = pcall(enc.SerializeCBOR, record)
        if ok and type(payload) == "string" then
            return #payload <= MaxRecordCbor()
        end
    end
    return true
end

local function RebuildExportIndex()
    exportRebuildCount = exportRebuildCount + 1
    exportState.order = {}
    exportState.byId = {}
    exportState.enumPos = nil
    local guildKey = CurrentGuildKey()
    exportState.guildKey = guildKey
    exportDirty = false
    if not guildKey then
        return
    end
    local record = select(1, RS:EnsureGuildRecord(guildKey))
    if not record then
        return
    end

    local plans = {}
    for _, plan in pairs(record.plans or {}) do
        if type(plan) == "table" then
            plans[#plans + 1] = plan
        end
    end
    table.sort(plans, function(a, b)
        return tostring(a.planId) < tostring(b.planId)
    end)
    for i = 1, #plans do
        local wire = WireForPlan(plans[i])
        if wire and RS.RecordWithinGossipCap(wire) then
            exportState.order[#exportState.order + 1] = wire.id
            exportState.byId[wire.id] = wire
        end
    end

    local entries = {}
    for _, entry in pairs(record.entries or {}) do
        if type(entry) == "table" then
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries, function(a, b)
        return tostring(a.entryId) < tostring(b.entryId)
    end)
    for i = 1, #entries do
        local wire = WireForEntry(entries[i])
        if wire and RS.RecordWithinGossipCap(wire) then
            exportState.order[#exportState.order + 1] = wire.id
            exportState.byId[wire.id] = wire
        end
    end
end

local function ProviderEntry()
    local g = Gossip()
    if not g or type(g.GetProvider) ~= "function" then
        return nil
    end
    return g.GetProvider(RS.PROVIDER_ID)
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

--- Budgeted physical-index build. Returns moreWork[, examined].
-- moreWork=true while records remain; false when complete (buildComplete, not dirty).
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
    if type(index) ~= "table" then
        return false, 0
    end
    if index.buildComplete and not index.dirty then
        return false, 0
    end
    if not exportState.enumPos then
        exportState.enumPos = 1
    end
    if not g or type(g.IndexUpsert) ~= "function" then
        exportState.enumPos = nil
        index.buildComplete = true
        index.dirty = false
        return false, 0
    end
    local n = 0
    while exportState.enumPos <= #exportState.order and n < budget do
        local rid = exportState.order[exportState.enumPos]
        exportState.enumPos = exportState.enumPos + 1
        local r = exportState.byId[rid]
        if r then
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
    EnsureExportFresh()
    cursor = tonumber(cursor) or 1
    limit = math.max(1, tonumber(limit) or 8)
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
    EnsureExportFresh()
    local r = exportState.byId[tostring(recordId)]
    return r and r.versionFp or nil
end

local function GetRecordBody(recordId)
    local guildKey = CurrentGuildKey()
    if exportState.guildKey ~= guildKey then
        exportDirty = false
        exportDirtyNeedsBump = false
        RebuildExportIndex()
        BumpPhysicalIndex(nil)
    else
        EnsureExportFresh()
    end
    local r = exportState.byId[tostring(recordId)]
    if not r then
        return nil
    end
    local wire = { id = r.id, versionFp = r.versionFp, body = r.body }
    if not RS.RecordWithinGossipCap(wire) then
        return nil
    end
    return wire
end

local function ValidVerSafe(ver)
    return type(ver) == "table" and RS.IsFiniteNonnegInt(ver.n) and type(ver.w) == "string" and ver.w ~= ""
end

local function ValidateAndApply(record, ctx)
    if type(record) ~= "table" or type(record.body) ~= "table" then
        return "rejected", "malformed"
    end
    if ctx and ctx.localWrite then
        return "rejected", "use_local_api"
    end
    if not RS.RecordWithinGossipCap(record) then
        return "rejected", "record_too_large"
    end
    local body = record.body
    local kind = body.kind
    if kind ~= "raidsignup-plan" and kind ~= "raidsignup-entry" then
        return "rejected", "unsupported_kind"
    end
    if tonumber(body.schema) and tonumber(body.schema) ~= RS.PROVIDER_SCHEMA then
        return "rejected", "unsupported_schema"
    end

    local sender = ctx and ctx.sender
    local member, authReason = RS.AuthenticateTransportSender(sender)
    if not member then
        return "rejected", authReason or "unauthorized"
    end

    local guildRec = select(1, RS:EnsureGuildRecord(member.guildKey))
    if not guildRec then
        return "rejected", "not_ready"
    end

    local status, detail
    if kind == "raidsignup-plan" then
        local mayOfficer, officerReason = RS.SenderHasOfficerAuthority(member)
        if not mayOfficer then
            -- Stale/duplicate plan catch-up: if we already hold equal/newer, membership is enough.
            local incoming = body.plan
            local prev = incoming and guildRec.plans[incoming.planId]
            if type(prev) == "table" and type(incoming) == "table"
                and RS.CompareVer(incoming.ver, prev.ver) <= 0 then
                return "duplicate", "stale_or_same"
            end
            return "rejected", officerReason or "unauthorized"
        end
        status, detail = RS.MergePlan(guildRec, body.plan, { remote = true })
    else
        local entry = body.entry
        if type(entry) ~= "table" then
            return "rejected", "malformed"
        end
        local prev = guildRec.entries[entry.entryId]
        -- Do not short-circuit live↔tombstone conflicts as stale: deletion finality
        -- is enforced inside MergeEntry for both delivery orders.
        local liveTombstoneConflict = type(prev) == "table"
            and ((prev.deleted and not entry.deleted) or (entry.deleted and not prev.deleted))
        if type(prev) == "table" and ValidVerSafe(prev.ver) and ValidVerSafe(entry.ver)
            and not liveTombstoneConflict
            and RS.CompareVer(entry.ver, prev.ver) <= 0 then
            return "duplicate", "stale_or_same"
        end
        local creatorGuid = (prev and prev.creatorGuid) or entry.creatorGuid
        local mayMutate, mutateReason = RS.SenderMayMutateEntry(member, creatorGuid)
        if not mayMutate then
            return "rejected", mutateReason or "relay_lacks_authority"
        end
        -- Non-creators who are not officers cannot mint a new creator identity.
        if not prev and member.guid ~= entry.creatorGuid then
            local officer = RS.SenderHasOfficerAuthority(member)
            if not officer then
                return "rejected", "relay_lacks_authority"
            end
        end
        status, detail = RS.MergeEntry(guildRec, entry, { remote = true })
    end

    if status == "accepted" then
        if RS.NotifyLocalDurableChange then
            RS.NotifyLocalDurableChange("remote")
        end
    end
    return status, detail
end

local function BuildProviderSpec()
    return {
        id = RS.PROVIDER_ID,
        schema = RS.PROVIDER_SCHEMA,
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

function RS:EnsureGossipProvider()
    local g = Gossip()
    if not g or not g.RegisterProvider then
        return false, "gossip_unavailable"
    end
    if providerRegistered and g.GetProvider and g.GetProvider(RS.PROVIDER_ID) then
        return true
    end
    if g.Init then
        g.Init()
    end
    local ok, err = g.RegisterProvider(BuildProviderSpec())
    if not ok and err and err ~= "already_registered" then
        if g.GetProvider and g.GetProvider(RS.PROVIDER_ID) then
            providerRegistered = true
            return true
        end
        DebugWarn("provider register failed: %s", tostring(err))
        return false, err
    end
    if g.SetProviderEnabled then
        g.SetProviderEnabled(RS.PROVIDER_ID, true)
    end
    providerRegistered = true
    RebuildExportIndex()
    DebugInfo("registered raid signup provider id=%s", RS.PROVIDER_ID)
    return true
end

function RS.RegisterUIListener(fn)
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

function RS.NotifyUI(reason)
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

function RS.NotifyLocalDurableChange(reason)
    reason = tostring(reason or "local")
    if providerRegistered then
        local guildKey = CurrentGuildKey()
        if reason == "remote" then
            exportDirty = true
            exportDirtyNeedsBump = true
            local g = Gossip()
            if g and g.NotifyProviderChanged then
                g.NotifyProviderChanged(RS.PROVIDER_ID)
            end
        else
            exportDirty = false
            exportDirtyNeedsBump = false
            RebuildExportIndex()
            if exportState.guildKey ~= guildKey or reason == "local" then
                if BumpPhysicalIndex(nil) then
                    exportBumpCount = exportBumpCount + 1
                end
            end
            local g = Gossip()
            if g and g.NotifyProviderChanged then
                g.NotifyProviderChanged(RS.PROVIDER_ID)
            end
        end
    end
    RS.NotifyUI(reason)
end

function RS.ResetExportPerfCounters()
    exportRebuildCount = 0
    exportBumpCount = 0
end

function RS.GetExportPerfCounters()
    return {
        rebuilds = exportRebuildCount,
        bumps = exportBumpCount,
        dirty = exportDirty and true or false,
        listenerCount = #uiListeners,
    }
end

function RS.FlushPendingExport()
    return EnsureExportFresh()
end

-- Test helper: clear UI listeners without leaking across cases.
function RS._ResetUIListenersForTests()
    uiListeners = {}
    uiNotifying = false
    uiNotifyQueued = false
    uiNotifyQueuedReason = nil
end

local _previousInitialize = RS.Initialize
function RS:Initialize(db)
    local ok, reason = true, nil
    if _previousInitialize then
        ok, reason = _previousInitialize(self, db)
    end
    if ok then
        RS:EnsureGossipProvider()
    end
    return ok, reason
end
