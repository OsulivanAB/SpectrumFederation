-- Guild Officer policy provider. One current-state record per guild (#405).
local addonName, SF = ...

SF.GuildOfficer = SF.GuildOfficer or {}
local GO = SF.GuildOfficer

local GG = nil

local function Gossip()
    if not GG then
        GG = SF.GuildGossip
    end
    return GG
end

local function DebugWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Warn("GUILD_OFFICER", fmt, ...)
    end
end

local providerRegistered = false
local exportState = {
    guildKey = nil,
    record = nil,
}
local exportDirty = false
local uiListeners = {}
local uiNotifying = false
local uiNotifyQueued = false

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

local function IsPeerEligible(peerName)
    local g = Gossip()
    if not g or type(g.IsGuildMember) ~= "function" then
        return false
    end
    return g.IsGuildMember(peerName) and true or false
end

local function GetCapabilities()
    return { guildOfficer = true }
end

local function MaxRecordCbor()
    local g = Gossip()
    return tonumber(g and g.MAX_RECORD_CBOR) or 2048
end

local function HashParts(text)
    local g = Gossip()
    if not g or not g.Hash32 then
        return tostring(text or "")
    end
    return string.format("%08x", g.Hash32(tostring(text or "")))
end

function GO.PolicyVersionFp(policy)
    if type(policy) ~= "table" then
        return nil
    end
    return HashParts(table.concat({
        tostring(policy.guildKey or ""),
        tostring(policy.threshold or ""),
        tostring(policy.baseThreshold or ""),
        tostring(policy.revN or ""),
        tostring(policy.revW or ""),
    }, "\0"))
end

local function WireForPolicy(policy)
    if type(policy) ~= "table" then
        return nil
    end
    return {
        id = GO.RECORD_ID,
        versionFp = GO.PolicyVersionFp(policy),
        body = {
            kind = "guild-officer-policy",
            schema = GO.PROVIDER_SCHEMA,
            guildKey = policy.guildKey,
            threshold = policy.threshold,
            baseThreshold = policy.baseThreshold,
            revN = policy.revN,
            revW = policy.revW,
            at = policy.at or 0,
        },
    }
end

function GO.RecordWithinGossipCap(record)
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
    return #raw <= MaxRecordCbor()
end

local function RebuildExport()
    exportDirty = false
    exportState.record = nil
    local guildKey = CurrentGuildKey()
    exportState.guildKey = guildKey
    if not guildKey or not GO:IsRootReady() then
        return
    end
    local policy = select(1, GO:GetStoredPolicy(guildKey))
    if not policy then
        return
    end
    local wire = WireForPolicy(policy)
    if wire and GO.RecordWithinGossipCap(wire) then
        exportState.record = wire
    elseif wire then
        DebugWarn("officer policy record exceeds gossip cap")
    end
end

local function OnIndexInvalidated()
end

-- One current policy row. IndexUpsert refuses a fingerprint replacement and
-- tells the caller to bump. BumpIndexEpoch clears the index, so the current
-- row is inserted on the following pass. A guild-scope change clears first,
-- then inserts only the new guild's current record.
local function EnsureIndex(index, limits)
    limits = limits or {}
    if type(index) ~= "table" then
        return false, 0
    end
    local guildKey = CurrentGuildKey()
    local scopeChanged = exportState.guildKey ~= guildKey
    local refreshed = false
    if scopeChanged or exportDirty then
        RebuildExport()
        refreshed = true
    end
    local g = Gossip()
    if scopeChanged and g and g.BumpIndexEpoch then
        g.BumpIndexEpoch(index)
    end
    if not refreshed and index.buildComplete and not index.dirty then
        return false, 0
    end
    local budget = math.max(1, tonumber(limits.indexEntries) or 8)
    local examined = 0
    if exportState.record and g and g.IndexUpsert then
        local wire = exportState.record
        local _, detail = g.IndexUpsert(index, wire.id, wire.versionFp, wire)
        examined = 1
        if detail == "replaced" then
            if g.BumpIndexEpoch then
                g.BumpIndexEpoch(index)
            end
            return true, examined
        end
    elseif g and g.IndexRemove and index.byId and index.byId[GO.RECORD_ID] then
        g.IndexRemove(index, GO.RECORD_ID)
        examined = 1
    end
    index.buildComplete = true
    index.dirty = false
    if examined > budget then
        return true, budget
    end
    return false, examined
end

local function ListRecordIds(cursor, limit)
    cursor = math.max(1, tonumber(cursor) or 1)
    limit = math.max(1, tonumber(limit) or 32)
    if exportDirty or exportState.guildKey ~= CurrentGuildKey() then
        RebuildExport()
    end
    if not exportState.record or cursor > 1 or limit < 1 then
        return {}, nil
    end
    return { exportState.record.id }, nil
end

local function GetRecordVersionFp(recordId)
    if exportDirty or exportState.guildKey ~= CurrentGuildKey() then
        RebuildExport()
    end
    if exportState.record and exportState.record.id == tostring(recordId) then
        return exportState.record.versionFp
    end
    return nil
end

local function GetRecordBody(recordId)
    if exportDirty or exportState.guildKey ~= CurrentGuildKey() then
        RebuildExport()
    end
    local wire = exportState.record
    if not wire or wire.id ~= tostring(recordId) then
        return nil
    end
    if not GO.RecordWithinGossipCap(wire) then
        return nil
    end
    return wire
end

local function ValidateAndApply(record, ctx)
    if type(record) ~= "table" or type(record.body) ~= "table" then
        return "rejected", "malformed"
    end
    if ctx and ctx.localWrite then
        return "rejected", "use_local_api"
    end
    if tostring(record.id) ~= tostring(GO.RECORD_ID) then
        return "rejected", "invalid_record_id"
    end
    if not GO.RecordWithinGossipCap(record) then
        return "rejected", "record_too_large"
    end
    local body = record.body
    if body.kind ~= "guild-officer-policy" then
        return "rejected", "unsupported_kind"
    end
    if tonumber(body.schema) and tonumber(body.schema) ~= GO.PROVIDER_SCHEMA then
        return "rejected", "unsupported_schema"
    end
    local normalized, normErr = GO.NormalizePolicy(body)
    if not normalized then
        return "rejected", normErr or "malformed"
    end
    local expectedFp = GO.PolicyVersionFp(normalized)
    if type(expectedFp) ~= "string" or expectedFp == ""
        or tostring(record.versionFp or "") ~= expectedFp then
        return "rejected", "invalid_version_fp"
    end
    local g = Gossip()
    if not g or type(g.GetGuildMember) ~= "function" then
        return "rejected", "not_ready"
    end
    local sender = ctx and ctx.sender
    if type(sender) ~= "string" or sender == "" then
        return "rejected", "invalid_sender"
    end
    local member, authReason = g.GetGuildMember(sender)
    if not member then
        return "rejected", authReason or "unauthorized"
    end
    if type(member.guid) ~= "string" or member.guid == "" then
        return "rejected", "sender_guid_unavailable"
    end
    if type(member.rankOrder) ~= "number" then
        return "rejected", "rank_unavailable"
    end
    local status, detail = GO:ApplyRemotePolicy(body, member)
    if status == "accepted" then
        exportDirty = true
    end
    return status, detail
end

local function BuildProviderSpec()
    return {
        id = GO.PROVIDER_ID,
        schema = GO.PROVIDER_SCHEMA,
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

function GO:EnsureGossipProvider()
    local g = Gossip()
    if not g or not g.RegisterProvider then
        return false, "gossip_unavailable"
    end
    if providerRegistered and g.GetProvider and g.GetProvider(GO.PROVIDER_ID) then
        return true
    end
    if g.Init then
        g.Init()
    end
    local ok, err = g.RegisterProvider(BuildProviderSpec())
    if not ok then
        if g.GetProvider and g.GetProvider(GO.PROVIDER_ID) then
            providerRegistered = true
            return true
        end
        DebugWarn("officer provider register failed: %s", tostring(err))
        return false, err
    end
    if g.SetProviderEnabled then
        g.SetProviderEnabled(GO.PROVIDER_ID, true)
    end
    providerRegistered = true
    RebuildExport()
    return true
end

function GO.RegisterUIListener(fn)
    if type(fn) ~= "function" then
        return nil
    end
    uiListeners[#uiListeners + 1] = fn
    return fn
end

local function DeliverUINotify(reason)
    if uiNotifying then
        uiNotifyQueued = true
        return
    end
    uiNotifying = true
    local firstErr = nil
    for i = 1, #uiListeners do
        local fn = uiListeners[i]
        if type(fn) == "function" then
            local ok, err = pcall(fn, reason)
            if not ok and firstErr == nil then
                firstErr = err
            end
        end
    end
    uiNotifying = false
    if firstErr ~= nil and geterrorhandler then
        pcall(geterrorhandler(), firstErr)
    end
    if uiNotifyQueued then
        uiNotifyQueued = false
        DeliverUINotify(reason)
    end
end

function GO.NotifyUI(reason)
    DeliverUINotify(reason)
end

function GO.NotifyLocalChange(reason)
    exportDirty = true
    local g = Gossip()
    if g and g.NotifyProviderChanged then
        g.NotifyProviderChanged(GO.PROVIDER_ID)
    end
    GO.NotifyUI(reason)
end

-- Test aid: repeated reads must not schedule work.
function GO.ResetIdleCounters()
    GO._readCount = 0
end

local _getView = GO.GetView
function GO:GetView()
    GO._readCount = (tonumber(GO._readCount) or 0) + 1
    return _getView(self)
end
