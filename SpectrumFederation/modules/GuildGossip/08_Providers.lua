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
  EnsureIndex(index, limits) -> moreWork[, examined]   preferred budgeted index path
  OnIndexInvalidated()
  ValidateAndApply(record, ctx) -> "accepted"|"duplicate"|"rejected"|"pending", detail
  GetRecordBody(recordId) -> table|nil  opaque body for eligible export
  GetRecordVersionFp(recordId) -> string|nil
  ListRecordIds(cursor, limit) -> pageIds, nextCursor|nil
      Bounded cold enumeration. pageIds MUST contain at most `limit` entries.
      Oversized pages fail the index attempt; full-history dumps are unsupported.
      Phase 1 cursors are finite increasing integers: nextCursor nil ends the walk;
      otherwise nextCursor must be a finite integer strictly greater than `cursor`.
      Opaque or non-progress tokens are rejected as an incomplete/failed build
      (no prune of already-indexed rows).

After durable storage changes outside the engine append path, call
GG.NotifyProviderChanged(id) (also SF.GuildGossip.NotifyProviderChanged(id)).
There is no subscription/callback registration API in Phase 1.

Registration is idempotent. Unregister clears engine runtime state for that provider.
Enabled providers must supply EnsureIndex or ListRecordIds+GetRecordVersionFp.
Callback work (ListRecordIds / EnsureIndex / GetRecordVersionFp) must stay within
the supplied per-step budget; the engine does not materialize unbounded snapshots.
]]
function GG.RegisterProvider(spec)
    if type(spec) ~= "table" or type(spec.id) ~= "string" or spec.id == "" then
        return false, "invalid_spec"
    end
    local hasEnsure = type(spec.EnsureIndex) == "function"
    local hasPagedList = type(spec.ListRecordIds) == "function"
        and type(spec.GetRecordVersionFp) == "function"
    if not hasEnsure and not hasPagedList then
        return false, "no_index_api"
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
    entry.indexFailed = nil
    entry.indexFailReason = nil
    entry.indexFailCount = 0
    if not existing then
        reg.byId[id] = entry
        reg.order[#reg.order + 1] = id
    end
    GG._RecountActiveProviders()
    if entry.enabled and entry.ready then
        GG.MarkWorkPending()
        -- Do not start the work ticker or discovery while guild readiness is absent.
        if GG.IsGuildReady and GG.IsGuildReady() then
            GG._EnsureScheduler()
            if GG.ScheduleDiscovery then
                GG.ScheduleDiscovery(true)
            end
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
        entry.indexFailed = nil
        entry.indexFailReason = nil
        entry.indexFailCount = 0
        -- Durable changes retained while disabled must reconcile before transport.
        if entry.index and (entry.index.dirty or not entry.index.buildComplete) then
            entry._buildList = nil
            entry._buildPos = nil
            entry._listCursor = nil
        end
        GG.MarkWorkPending()
        if GG.IsGuildReady and GG.IsGuildReady() then
            GG._EnsureScheduler()
            if GG.ScheduleDiscovery then
                GG.ScheduleDiscovery(true)
            end
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
    if not entry then
        return
    end
    -- Explicit recovery trigger for terminal index failures / scope mismatch.
    entry.indexFailed = nil
    entry.indexFailReason = nil
    entry.indexFailCount = 0
    if GG._engine and GG._engine.peers then
        for _, peer in pairs(GG._engine.peers) do
            if peer.scopeIncompat then
                peer.scopeIncompat[providerId] = nil
            end
        end
    end
    -- Reopen enumeration past advanced bookmarks for this provider's unresolved
    -- obligations so earlier rejected/pending/skipped revisions remain reachable.
    if type(GG.ReopenUnresolvedEnumeration) == "function" then
        GG.ReopenUnresolvedEnumeration(providerId)
    end
    -- Provider-owned storage changed outside the engine's append path. Retain
    -- dirty/changeGen even while disabled so re-enable reconciles durable writes
    -- without starting transport. Enabled providers keep the live index usable
    -- and schedule a bounded reconciliation pass.
    if entry.index then
        entry.index.dirty = true
        if not entry.enabled then
            entry.index.buildComplete = false
        end
    end
    entry._buildList = nil
    entry._buildPos = nil
    entry._listCursor = nil
    entry._reconcileSeen = nil
    entry._reconciling = nil
    if entry.api and type(entry.api.OnIndexInvalidated) == "function" then
        pcall(entry.api.OnIndexInvalidated)
    end
    GG.BumpProviderChangeGen(providerId)
    if not entry.enabled then
        return
    end
    if GG.MarkWorkPending then
        GG.MarkWorkPending()
    end
    GG.NotifyMeaningfulChange()
end

local INDEX_FAIL_THRESHOLD = 3

local function markIndexFailed(entry, reason)
    if not entry then
        return
    end
    entry.indexFailed = true
    entry.indexFailReason = tostring(reason or "index_failed")
    entry.indexFailCount = 0
    entry._buildList = nil
    entry._buildPos = nil
    entry._listCursor = nil
    entry._reconcileSeen = nil
    entry._reconciling = nil
    entry.lastIndexExamined = 0
    GG._DError("Index failed provider=%s reason=%s", entry.id, entry.indexFailReason)
end

local function noteIndexAttemptFailure(entry, reason)
    entry.indexFailCount = (tonumber(entry.indexFailCount) or 0) + 1
    if entry.indexFailCount >= INDEX_FAIL_THRESHOLD then
        markIndexFailed(entry, reason)
        return true
    end
    return false
end

function GG.ProviderIsPeerEligible(entry, peerName, ctx)
    if not entry or not entry.enabled or not entry.ready then
        return false
    end
    local api = entry.api
    -- Fail closed: intentional guild-wide access must supply an explicit callback
    -- (the synthetic provider does). Omitting the policy never authorizes export.
    if type(api) ~= "table" or type(api.IsPeerEligible) ~= "function" then
        return false
    end
    local ok, res = pcall(api.IsPeerEligible, peerName, ctx)
    return ok and res and true or false
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
    -- Compact 32-bit incarnation token from the existing per-load epoch
    -- machinery: full Hash32 packed as 4 bytes (not %256). Retains reload
    -- collision resistance while staying inside the 240-byte discovery envelope
    -- under rotation (far denser on-wire than a decimal integer encoding).
    local h = GG.Hash32(GG.InitEpochIncarnation and GG.InitEpochIncarnation()
        or tostring(GG._epochIncarnation or ""))
    local srcToken = string.char(
        math.floor(h / 16777216) % 256,
        math.floor(h / 65536) % 256,
        math.floor(h / 256) % 256,
        h % 256
    )
    if count == 0 then
        return {
            proto = GG.PROTO_CURRENT,
            enc = { GG.ENC_B64CBOR },
            s = srcToken,
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
            -- Per-load source incarnation distinguishes reloads whose counters
            -- restart at the same values. Scope is matched on the VIEW path
            -- (not advertised) to preserve the 240-byte discovery envelope
            -- under rotation.
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
    -- Per-load source incarnation once per discovery packet (not per provider)
    -- so reload counter collisions reopen coverage while preserving the
    -- 240-byte envelope / rotation budget.
    return {
        proto = GG.PROTO_CURRENT,
        enc = { GG.ENC_B64CBOR },
        s = srcToken,
        providers = caps,
    }
end

-- Incremental index maintenance under D1 budget.
function GG.EnsureProviderIndex(entry, limits)
    if not entry or not entry.api then
        return false
    end
    if entry.indexFailed then
        entry.lastIndexExamined = 0
        return false
    end
    local api = entry.api
    entry.lastIndexExamined = 0
    local budget = math.max(1, tonumber(limits and limits.indexEntries) or GG.INDEX_ENTRIES_PER_STEP.SLOW)

    if type(api.EnsureIndex) == "function" then
        local ok, more, examined = pcall(api.EnsureIndex, entry.index, limits)
        if not ok then
            GG._DError("EnsureIndex failed provider=%s err=%s", entry.id, tostring(more))
            if geterrorhandler then
                pcall(geterrorhandler(), more)
            end
            noteIndexAttemptFailure(entry, "ensure_index_error")
            return false
        end
        entry.lastIndexExamined = math.max(0, tonumber(examined) or 0)
        if more then
            entry.indexFailCount = 0
            return true
        end
        -- Custom EnsureIndex owns completion: no remaining work requires a usable index.
        if not entry.index or not entry.index.buildComplete or entry.index.dirty then
            markIndexFailed(entry, "ensure_index_incomplete")
            return false
        end
        entry.indexFailCount = 0
        return false
    end

    -- Bounded cold/dirty enumeration: ListRecordIds(cursor, limit) -> page, nextCursor.
    -- Full-history dumps are unsupported; pages larger than the budget fail closed.
    if type(api.ListRecordIds) ~= "function" or type(api.GetRecordVersionFp) ~= "function" then
        markIndexFailed(entry, "no_index_api")
        return false
    end
    local index = entry.index
    if index and index.buildComplete and not index.dirty and not entry._listCursor then
        return false
    end

    -- Start a dirty reconciliation walk: accumulate seen IDs across budgeted
    -- slices, and prune disappeared rows only after a successful completion.
    if index and index.dirty and not entry._listCursor and not entry._reconciling then
        entry._reconciling = true
        entry._reconcileSeen = {}
    end

    local function upsertId(rid)
        local ok, res = pcall(api.GetRecordVersionFp, rid)
        if not ok then
            -- Callback failure is distinct from legitimate absence (nil).
            GG._DError("GetRecordVersionFp failed provider=%s id=%s err=%s",
                entry.id, tostring(rid), tostring(res))
            if geterrorhandler then
                pcall(geterrorhandler(), res)
            end
            return "error"
        end
        if res == nil or res == false then
            return false
        end
        local vfp = res
        local _, detail = GG.IndexUpsert(entry.index, rid, vfp)
        if detail == "replaced" then
            GG.BumpIndexEpoch(entry.index)
            entry._listCursor = 1
            entry._reconcileSeen = {}
            entry._reconciling = true
            return "restart"
        end
        return true
    end

    local cursor = entry._listCursor or 1
    local ok, page, nextCursor = pcall(api.ListRecordIds, cursor, budget)
    if not ok then
        GG._DError("ListRecordIds failed provider=%s err=%s", entry.id, tostring(page))
        if geterrorhandler then
            pcall(geterrorhandler(), page)
        end
        noteIndexAttemptFailure(entry, "list_record_ids_error")
        return false
    end
    if type(page) ~= "table" then
        noteIndexAttemptFailure(entry, "list_record_ids_invalid")
        return false
    end
    if #page > budget then
        GG._DError("ListRecordIds oversize provider=%s page=%s budget=%s",
            entry.id, tostring(#page), tostring(budget))
        noteIndexAttemptFailure(entry, "list_record_ids_oversize")
        entry._listCursor = nil
        return false
    end

    local n = 0
    for i = 1, #page do
        local rid = page[i]
        if entry._reconcileSeen and rid ~= nil then
            entry._reconcileSeen[tostring(rid)] = true
        end
        local status = upsertId(rid)
        if status == "error" then
            -- Keep the build incomplete and the cursor on this page so recovery
            -- can retry. Do not prune on failed/incomplete walks.
            entry.lastIndexExamined = n
            entry._listCursor = cursor
            if index then
                index.buildComplete = false
                index.dirty = true
            end
            if noteIndexAttemptFailure(entry, "get_record_version_fp_error") then
                return false
            end
            return true
        end
        if status == "restart" then
            entry.lastIndexExamined = n + 1
            return true
        end
        n = n + 1
    end
    entry.lastIndexExamined = n

    -- Phase 1: only nil (EOF) or a finite integer strictly greater than the
    -- request cursor may continue. Opaque / backward / non-numeric tokens must
    -- never be treated as successful completion (that would prune valid rows).
    -- Reset failure counting only after a genuinely valid page/continuation —
    -- never before cursor validation (that would prevent terminal indexFailed).
    if nextCursor == nil then
        -- Empty page or final page with no next cursor completes the build.
        entry.indexFailCount = 0
        entry._listCursor = nil
        if index then
            if entry._reconciling and entry._reconcileSeen then
                local removed = false
                local toRemove = {}
                for id in pairs(index.byId or {}) do
                    if not entry._reconcileSeen[id] then
                        toRemove[#toRemove + 1] = id
                    end
                end
                for i = 1, #toRemove do
                    if GG.IndexRemove(index, toRemove[i]) then
                        removed = true
                    end
                end
                if removed and GG.TouchIndexEpoch then
                    -- Invalidate views after established removal; preserve rows.
                    GG.TouchIndexEpoch(index)
                end
            end
            entry._reconcileSeen = nil
            entry._reconciling = nil
            index.buildComplete = true
            index.dirty = false
        end
        return false
    end

    local nextNum = tonumber(nextCursor)
    local cursorOk = type(nextCursor) == "number"
        and nextNum == nextCursor
        and nextNum == nextNum
        and nextNum ~= math.huge
        and nextNum ~= -math.huge
        and nextNum == math.floor(nextNum)
        and nextNum > cursor
    if cursorOk then
        entry.indexFailCount = 0
        entry._listCursor = nextNum
        return true
    end

    GG._DError("ListRecordIds bad cursor provider=%s cursor=%s next=%s",
        entry.id, tostring(cursor), tostring(nextCursor))
    entry._listCursor = cursor
    if index then
        index.buildComplete = false
        index.dirty = true
    end
    -- Keep reconcile state; do not prune on a failed/incomplete walk.
    if noteIndexAttemptFailure(entry, "list_record_ids_bad_cursor") then
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
    -- Accept only the four documented string outcomes; booleans are invalid.
    if type(result) ~= "string" then
        return RESULT.REJECTED, "invalid_outcome"
    end
    if result ~= RESULT.ACCEPTED and result ~= RESULT.DUPLICATE
        and result ~= RESULT.REJECTED and result ~= RESULT.PENDING then
        GG._DVerbose("Invalid delivery outcome provider=%s result=%s", entry.id, tostring(result))
        return RESULT.REJECTED, "invalid_outcome"
    end
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
        OnIndexInvalidated = function()
            store._enumPos = nil
        end,
        -- Budget-aware index path: never materializes the full order in one step.
        EnsureIndex = function(index, limits)
            local budget = math.max(1, tonumber(limits and limits.indexEntries) or GG.INDEX_ENTRIES_PER_STEP.SLOW)
            if index.buildComplete and not index.dirty then
                return false, 0
            end
            -- Preserve continuation across ordinary dirty steps. Reset only when
            -- starting a new build (nil cursor) or after a genuine invalidation
            -- that cleared _enumPos (BumpIndexEpoch / ClearStore / Notify).
            if not store._enumPos then
                store._enumPos = 1
            end
            local n = 0
            while store._enumPos <= #store.order and n < budget do
                local rid = store.order[store._enumPos]
                store._enumPos = store._enumPos + 1
                local r = store.records[tostring(rid)]
                if r then
                    local _, detail = GG.IndexUpsert(index, rid, r.versionFp, r)
                    if detail == "replaced" then
                        GG.BumpIndexEpoch(index)
                        store._enumPos = 1
                        return true, n + 1
                    end
                end
                n = n + 1
            end
            if store._enumPos > #store.order then
                store._enumPos = nil
                index.buildComplete = true
                index.dirty = false
                return false, n
            end
            return true, n
        end,
        -- Bounded page API for callers/tests; engine prefers EnsureIndex above.
        ListRecordIds = function(cursor, limit)
            cursor = math.max(1, tonumber(cursor) or 1)
            limit = math.max(1, tonumber(limit) or #store.order)
            local page = {}
            local i = cursor
            while i <= #store.order and #page < limit do
                page[#page + 1] = store.order[i]
                i = i + 1
            end
            if i <= #store.order then
                return page, i
            end
            return page, nil
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
            -- Ordinary appends update the live index in place.
                GG.IndexUpsert(entry.index, rid, vfp, record)
                -- Synthetic EnsureIndex tracks cold enumeration with store._enumPos
                -- (not entry._listCursor). Do not declare the build complete while
                -- that walk — or a ListRecordIds cursor — is still in progress.
                local coldWalkPending = entry._listCursor ~= nil or store._enumPos ~= nil
                if not entry.index.buildComplete and not coldWalkPending then
                    entry.index.buildComplete = true
                    entry.index.dirty = false
                elseif not entry.index.buildComplete then
                    entry.index.dirty = true
                end
                GG.BumpProviderChangeGen(id)
                if entry.enabled then
                    if GG.NotifyMeaningfulChange then
                        GG.NotifyMeaningfulChange()
                    end
                else
                    -- Durable write while disabled: reconcile on re-enable.
                    if entry.index then
                        entry.index.dirty = true
                        entry.index.buildComplete = false
                    end
                    entry._listCursor = nil
                    store._enumPos = nil
                end
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
        store._enumPos = nil
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
