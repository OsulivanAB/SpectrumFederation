-- Provider registry and synthetic append-only test provider (disabled by default).
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

GG._providers = GG._providers or {
    byId = {},
    order = {},
    activeCount = 0,
    discRotate = 0,
}

local RESULT = {
    ACCEPTED = "accepted",
    DUPLICATE = "duplicate",
    REJECTED = "rejected",
    PENDING = "pending",
}
GG.DELIVERY = RESULT

function GG.HasActiveProvider()
    return (GG._providers.activeCount or 0) > 0
end

function GG.ListActiveProviders()
    local out = {}
    for _, id in ipairs(GG._providers.order) do
        local p = GG._providers.byId[id]
        if p and p.enabled and p.ready then
            out[#out + 1] = p
        end
    end
    return out
end

function GG.GetProvider(providerId)
    return GG._providers.byId[tostring(providerId or "")]
end

--[[
Provider contract (Phase 1):
  id            string  stable provider id
  schema        number  provider schema version
  enabled       bool
  ready         bool    provider-local readiness (not raid)
  GetScopeId()  -> string|nil   data scope (often guild scope)
  IsPeerEligible(peerName, ctx) -> bool
  GetCapabilities() -> table    compact capability flags for discovery
  EnsureIndex(index, budget) -> remaining work bool
  OnIndexInvalidated()
  ValidateAndApply(record, ctx) -> "accepted"|"duplicate"|"rejected"|"pending", detail
  GetRecordBody(recordId) -> table|nil  opaque body for eligible export
  GetRecordVersionFp(recordId) -> string|nil
  ListRecordIds() -> {id...}   for cold index build (bounded by EnsureIndex)
  NotifyChange(cb) / optional; engine also exposes GG.NotifyProviderChanged(id)

Registration is idempotent. Unregister clears engine runtime state for that provider.
]]
function GG.RegisterProvider(spec)
    if type(spec) ~= "table" or type(spec.id) ~= "string" or spec.id == "" then
        return false, "invalid_spec"
    end
    local id = spec.id
    local reg = GG._providers
    local existing = reg.byId[id]
    local entry = existing or {
        id = id,
        index = GG.CreateIndex(),
        eligibilityGen = 1,
        bookmarks = {}, -- [peer|scope|bucket] = bookmark
    }
    entry.schema = tonumber(spec.schema) or 1
    entry.enabled = spec.enabled and true or false
    entry.ready = spec.ready ~= false
    entry.api = spec
    entry.synthetic = spec.synthetic == true
    if not existing then
        reg.byId[id] = entry
        reg.order[#reg.order + 1] = id
    end
    GG._RecountActiveProviders()
    if entry.enabled and entry.ready then
        GG.MarkWorkPending()
        GG._EnsureScheduler()
        if GG.ScheduleDiscovery then
            GG.ScheduleDiscovery(true)
        end
    end
    GG._DInfo("Provider registered id=%s enabled=%s", id, tostring(entry.enabled))
    return true, entry
end

function GG.UnregisterProvider(providerId)
    local id = tostring(providerId or "")
    local reg = GG._providers
    local entry = reg.byId[id]
    if not entry then
        return false
    end
    if GG.InvalidateProviderBookmarks then
        GG.InvalidateProviderBookmarks(entry)
    end
    reg.byId[id] = nil
    for i, oid in ipairs(reg.order) do
        if oid == id then
            table.remove(reg.order, i)
            break
        end
    end
    if GG.OnProviderRemoved then
        GG.OnProviderRemoved(id)
    end
    GG._RecountActiveProviders()
    if not GG.HasActiveProvider() then
        GG._StopScheduler()
        if GG.StopDiscovery then
            GG.StopDiscovery()
        end
    end
    return true
end

function GG.SetProviderEnabled(providerId, enabled)
    local entry = GG.GetProvider(providerId)
    if not entry then
        return false
    end
    entry.enabled = enabled and true or false
    if entry.api then
        entry.api.enabled = entry.enabled
    end
    GG._RecountActiveProviders()
    if entry.enabled and entry.ready then
        entry.eligibilityGen = (entry.eligibilityGen or 0) + 1
        GG.MarkWorkPending()
        GG._EnsureScheduler()
        if GG.ScheduleDiscovery then
            GG.ScheduleDiscovery(true)
        end
    else
        if GG.OnProviderRemoved then
            GG.OnProviderRemoved(entry.id)
        end
        if not GG.HasActiveProvider() then
            GG._StopScheduler()
            if GG.StopDiscovery then
                GG.StopDiscovery()
            end
        end
    end
    return true
end

function GG._RecountActiveProviders()
    local n = 0
    for _, id in ipairs(GG._providers.order) do
        local p = GG._providers.byId[id]
        if p and p.enabled and p.ready then
            n = n + 1
        end
    end
    GG._providers.activeCount = n
end

function GG.BumpProviderChangeGen(providerId)
    local entry = GG.GetProvider(providerId)
    if not entry then
        return
    end
    entry.changeGen = (tonumber(entry.changeGen) or 0) + 1
end

function GG.NotifyProviderChanged(providerId)
    local entry = GG.GetProvider(providerId)
    if not entry or not entry.enabled then
        return
    end
    -- Provider-owned storage changed outside the engine's append path. Keep the
    -- existing index usable while scheduling a bounded reconciliation pass.
    entry.index.dirty = true
    entry._buildList = nil
    entry._buildPos = nil
    GG.BumpProviderChangeGen(providerId)
    if GG.MarkWorkPending then
        GG.MarkWorkPending()
    end
    GG.NotifyMeaningfulChange()
end

function GG.ProviderIsPeerEligible(entry, peerName, ctx)
    if not entry or not entry.enabled or not entry.ready then
        return false
    end
    local api = entry.api
    if type(api.IsPeerEligible) == "function" then
        local ok, res = pcall(api.IsPeerEligible, peerName, ctx)
        return ok and res and true or false
    end
    -- Default: any verified guild member is eligible for the provider's scope.
    return GG.IsGuildMember(peerName)
end

function GG.InvalidateProviderBookmarks(entry)
    if entry then
        entry.bookmarks = {}
    end
end

function GG.BuildDiscoveryCaps()
    local caps = {}
    local active = GG.ListActiveProviders()
    local count = #active
    if count == 0 then
        return {
            proto = GG.PROTO_CURRENT,
            enc = { GG.ENC_B64CBOR },
            providers = caps,
        }
    end
    local reg = GG._providers
    local start = ((tonumber(reg.discRotate) or 0) % count) + 1
    reg.discRotate = start % count
    for offset = 0, count - 1 do
        local entry = active[((start + offset - 1) % count) + 1]
        local c = {
            id = entry.id,
            schema = entry.schema,
            -- Bounded change identity for discovery coverage. Ordinary remote
            -- appends bump changeGen; schema/id alone must not reopen pulls.
            changeGen = tonumber(entry.changeGen) or 0,
            eligibilityGen = tonumber(entry.eligibilityGen) or 0,
        }
        if entry.api and type(entry.api.GetCapabilities) == "function" then
            local ok, extra = pcall(entry.api.GetCapabilities)
            if ok and type(extra) == "table" then
                for k, v in pairs(extra) do
                    if c[k] == nil then
                        c[k] = v
                    end
                end
            end
        end
        caps[#caps + 1] = c
    end
    return {
        proto = GG.PROTO_CURRENT,
        enc = { GG.ENC_B64CBOR },
        providers = caps,
    }
end

-- Incremental index maintenance under D1 budget.
function GG.EnsureProviderIndex(entry, limits)
    if not entry or not entry.api then
        return false
    end
    local api = entry.api
    entry.lastIndexExamined = 0
    if type(api.EnsureIndex) == "function" then
        local ok, more = pcall(api.EnsureIndex, entry.index, limits)
        if ok then
            return more and true or false
        end
        GG._DError("EnsureIndex failed provider=%s err=%s", entry.id, tostring(more))
        return false
    end
    -- Default cold build from ListRecordIds + GetRecordVersionFp.
    if type(api.ListRecordIds) ~= "function" then
        return false
    end
    local index = entry.index
    if index and index.buildComplete and not index.dirty and not entry._buildList then
        return false
    end
    if not entry._buildList then
        local ok, list = pcall(api.ListRecordIds)
        if not ok or type(list) ~= "table" then
            return false
        end
        entry._buildList = list
        entry._buildPos = 1
    end
    local budget = limits and limits.indexEntries or GG.INDEX_ENTRIES_PER_STEP.SLOW
    local n = 0
    while entry._buildPos <= #entry._buildList and n < budget do
        local rid = entry._buildList[entry._buildPos]
        entry._buildPos = entry._buildPos + 1
        local vfp = nil
        if type(api.GetRecordVersionFp) == "function" then
            local ok, res = pcall(api.GetRecordVersionFp, rid)
            if ok then
                vfp = res
            end
        end
        if vfp then
            local added, detail = GG.IndexUpsert(entry.index, rid, vfp)
            if detail == "replaced" then
                GG.BumpIndexEpoch(entry.index)
                entry._buildList = nil
                return true
            end
        end
        n = n + 1
    end
    entry.lastIndexExamined = n
    if entry._buildPos > #entry._buildList then
        entry._buildList = nil
        if index then
            index.buildComplete = true
            index.dirty = false
        end
        return false
    end
    return true
end

function GG.ApplyRecordToProvider(entry, record, ctx)
    if not entry or not entry.api or type(entry.api.ValidateAndApply) ~= "function" then
        return RESULT.REJECTED, "no_provider"
    end
    local ok, result, detail = pcall(entry.api.ValidateAndApply, record, ctx)
    if not ok then
        GG._DError("ValidateAndApply error provider=%s err=%s", entry.id, tostring(result))
        -- Preserve unexpected error visibility without aborting the scheduler mid-step.
        if geterrorhandler then
            pcall(geterrorhandler(), result)
        end
        return RESULT.REJECTED, "provider_error"
    end
    result = tostring(result or RESULT.REJECTED)
    if result == RESULT.ACCEPTED then
        local id = record and (record.id or record.recordId)
        local vfp = record and (record.versionFp or record.v)
        if id and vfp then
            local added, info = GG.IndexUpsert(entry.index, id, tostring(vfp), record)
            if info == "replaced" then
                GG.BumpIndexEpoch(entry.index)
                GG.IndexUpsert(entry.index, id, tostring(vfp), record)
            end
        end
        GG.BumpProviderChangeGen(entry.id)
        GG.NotifyMeaningfulChange()
    end
    return result, detail
end

---------------------------------------------------------------------------
-- Synthetic append-only provider (disabled by default; runtime-only storage)
---------------------------------------------------------------------------

GG._syntheticStores = GG._syntheticStores or {}

local function syntheticStore(instanceKey)
    instanceKey = tostring(instanceKey or "default")
    local s = GG._syntheticStores[instanceKey]
    if not s then
        s = { records = {}, order = {}, pending = {}, rejected = {} }
        GG._syntheticStores[instanceKey] = s
    end
    return s
end

function GG.CreateSyntheticProvider(opts)
    opts = type(opts) == "table" and opts or {}
    local id = opts.id or GG.SYNTHETIC_PROVIDER_ID
    local instanceKey = opts.instanceKey or id
    local store = syntheticStore(instanceKey)
    local schema = opts.schema or GG.SYNTHETIC_SCHEMA

    local provider = {
        id = id,
        schema = schema,
        enabled = false,
        ready = true,
        synthetic = true,
        IsPeerEligible = function(peerName, ctx)
            return GG.IsGuildMember(peerName)
        end,
        GetScopeId = function()
            return GG.GetGuildScopeId()
        end,
        GetCapabilities = function()
            return { synthetic = true, appendOnly = true }
        end,
        ListRecordIds = function()
            local out = {}
            for i = 1, #store.order do
                out[i] = store.order[i]
            end
            return out
        end,
        GetRecordVersionFp = function(recordId)
            local r = store.records[tostring(recordId)]
            return r and r.versionFp or nil
        end,
        GetRecordBody = function(recordId)
            local r = store.records[tostring(recordId)]
            if not r then
                return nil
            end
            return { id = r.id, versionFp = r.versionFp, body = r.body }
        end,
        ValidateAndApply = function(record, ctx)
            if type(record) ~= "table" or record.id == nil then
                return RESULT.REJECTED, "malformed"
            end
            local rid = tostring(record.id)
            if store.rejected[rid] then
                return RESULT.REJECTED, "provider_rejected"
            end
            if opts.pendingIds and opts.pendingIds[rid] then
                store.pending[rid] = record
                return RESULT.PENDING, "deferred"
            end
            local existing = store.records[rid]
            local vfp = tostring(record.versionFp or record.v or "")
            if existing and existing.versionFp == vfp then
                return RESULT.DUPLICATE, nil
            end
            if existing and existing.versionFp ~= vfp then
                return RESULT.REJECTED, "conflict"
            end
            store.records[rid] = {
                id = rid,
                versionFp = vfp,
                body = record.body,
            }
            store.order[#store.order + 1] = rid
            return RESULT.ACCEPTED, nil
        end,
    }

    function provider.AppendLocal(body, recordId)
        local rid = tostring(recordId or ("syn-" .. tostring(#store.order + 1)))
        local vfp = tostring(GG.Hash32(rid .. "\0" .. tostring(body)))
        local record = { id = rid, versionFp = vfp, body = body }
        local result = provider.ValidateAndApply(record, { localWrite = true })
        if result == RESULT.ACCEPTED then
            local entry = GG.GetProvider(id)
            if entry then
                GG.IndexUpsert(entry.index, rid, vfp, record)
                GG.NotifyProviderChanged(id)
            end
        end
        return result, rid, vfp
    end

    function provider.MarkRejected(recordId)
        store.rejected[tostring(recordId)] = true
    end

    function provider.GetStore()
        return store
    end

    function provider.ClearStore()
        store.records = {}
        store.order = {}
        store.pending = {}
        store.rejected = {}
    end

    return provider
end

function GG.EnableSyntheticProvider(opts)
    local provider = GG.CreateSyntheticProvider(opts)
    provider.enabled = true
    GG.RegisterProvider(provider)
    GG.SetProviderEnabled(provider.id, true)
    return provider
end

function GG.DisableSyntheticProvider(providerId)
    providerId = providerId or GG.SYNTHETIC_PROVIDER_ID
    GG.SetProviderEnabled(providerId, false)
    GG.UnregisterProvider(providerId)
end
