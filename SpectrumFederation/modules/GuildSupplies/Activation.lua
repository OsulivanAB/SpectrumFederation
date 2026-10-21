-- Guild Supplies Phase 3C (#389) — guarded production activation and cutover.
-- Canonical live authority for one guild-owned dataset; retires legacy writers.
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

GS.ACTIVATION_ACTIVE = "active"
GS.LIVE_CUTOVER_SCHEMA = 1

local function DebugInfo(fmt, ...)
    if SF.Debug and SF.Debug.Info and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Info("GUILD_SUPPLIES", fmt, ...)
    end
end

local function DebugWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Warn("GUILD_SUPPLIES", fmt, ...)
    end
end

local function Loc(key, default)
    if SF.LocaleText then
        return SF.LocaleText(key, default)
    end
    return default
end

--- True for staged or active activation values this build understands.
function GS.IsSupportedActivation(activation)
    return activation == GS.ACTIVATION_STAGED or activation == GS.ACTIVATION_ACTIVE
end

--- True when the record is the canonical live Guild Supplies writer.
function GS.IsLiveActive(record)
    return type(record) == "table" and record.activation == GS.ACTIVATION_ACTIVE
end

--- Validated current-guild live record, or nil + reason.
function GS:GetLiveActiveRecord()
    local record, reason = GS:GetCurrentRecord()
    if not record then
        return nil, reason or "not_ready"
    end
    if not GS.IsLiveActive(record) then
        return nil, "not_activated"
    end
    return record, nil
end

function GS:IsLiveActiveForCurrentGuild()
    local record = select(1, GS:GetCurrentRecord())
    return GS.IsLiveActive(record)
end

--- Whether legacy profile writers may mutate accounting for a specific guild key.
-- @param guildKey string durable `club:<id>` key
-- @return boolean allowed
function GS.ShouldUseLegacyConsumablesWritersForGuildKey(guildKey)
    if not GS:IsRootReady() then
        -- Present-but-invalid saved roots (any non-nil value, including
        -- non-tables) are retained in GS._root with _rootValid=false.
        -- Fail closed so cutover cannot silently reopen legacy writers.
        -- Only a genuinely absent root (nil) keeps legacy available.
        return GS._root == nil
    end
    local key = GS.ParseGuildKey and select(1, GS.ParseGuildKey(guildKey)) or nil
    if not key then
        -- Ambiguous target: fail closed (do not allow legacy writes into an
        -- unresolvable guild identity while GS root is available).
        return false
    end
    if GS.GetRecordForGuildKey then
        local record, reason = GS:GetRecordForGuildKey(key)
        if record == nil then
            -- Only a genuinely missing guild slot permits legacy fallback.
            -- Retained malformed/unsupported (including corrupt active) records
            -- must fail closed so cutover cannot silently re-enable writers (#389).
            return reason == "not_configured"
        end
        return not GS.IsLiveActive(record)
    end
    local record = GS._root and GS._root.guilds and GS._root.guilds[key]
    if record == nil then
        return true
    end
    if GS.IsSupportedActivation and not GS.IsSupportedActivation(record.activation) then
        return false
    end
    return not GS.IsLiveActive(record)
end

--- Legacy profile Consumables may write only when the *target* guild is not live.
-- @param profileOrGuild optional profile table, club guid string, or guildKey.
--   When omitted, uses the current character's guild (Settings page visibility).
function GS:ShouldUseLegacyConsumablesWriters(profileOrGuild)
    if type(profileOrGuild) == "table" then
        local cfg = profileOrGuild._consumables
        local guid = cfg and type(cfg.guild) == "table" and cfg.guild.guid or nil
        if type(guid) ~= "string" or guid == "" then
            -- Unbound profile may still configure guild/tab via legacy writers.
            return true
        end
        return GS.ShouldUseLegacyConsumablesWritersForGuildKey("club:" .. tostring(guid))
    end
    if type(profileOrGuild) == "string" and profileOrGuild ~= "" then
        if profileOrGuild:match("^club:") then
            return GS.ShouldUseLegacyConsumablesWritersForGuildKey(profileOrGuild)
        end
        return GS.ShouldUseLegacyConsumablesWritersForGuildKey("club:" .. profileOrGuild)
    end
    if not GS:IsRootReady() then
        -- Same present-invalid vs absent distinction as the guild-key helper.
        return GS._root == nil
    end
    local record, reason = GS:GetCurrentRecord()
    if record == nil then
        -- not_configured / identity waiting: legacy remains for other profiles.
        if reason == "not_configured" or reason == "identity_unavailable"
            or reason == "not_ready" or reason == "not_a_member" then
            return true
        end
        -- Malformed/unsupported retained records fail closed for both writers.
        return false
    end
    return not GS.IsLiveActive(record)
end

local function IsFiniteNonnegInt(value)
    if GS.IsFiniteNonnegInt then
        return GS.IsFiniteNonnegInt(value)
    end
    local n = tonumber(value)
    return n and n == math.floor(n) and n >= 0 and n == n and n ~= math.huge
end

local function IsBoundedActorString(value)
    return type(value) == "string" and value ~= "" and #value <= (GS.MAX_OPERATION_ID or 192)
end

--- Build a durable cutover marker shared via gossip descriptors.
function GS.BuildCutoverMarker(datasetId, activatedAt, bankTab)
    if type(datasetId) ~= "string" or datasetId == "" then
        return nil
    end
    if not IsFiniteNonnegInt(activatedAt) then
        return nil
    end
    local tab = tonumber(bankTab)
    if not tab or tab ~= math.floor(tab) or tab < 1 or tab > (GS.MAX_BANK_TAB or 8) then
        return nil
    end
    return string.format("gsc1:%s:%d:%d", datasetId, activatedAt, tab)
end

--- Validate a persisted liveCutover block (active records only).
-- @return boolean ok, string|nil reason
function GS.ValidateLiveCutover(cutover, record, guildKey)
    if cutover == nil then
        return false, "missing_live_cutover"
    end
    if type(cutover) ~= "table" then
        return false, "invalid_live_cutover"
    end
    local schema = tonumber(cutover.schemaVersion)
    if not schema or schema ~= GS.LIVE_CUTOVER_SCHEMA then
        return false, "unsupported_cutover_schema"
    end
    if type(cutover.datasetId) ~= "string" or cutover.datasetId == "" then
        return false, "invalid_cutover_dataset"
    end
    if type(record) == "table" and type(record.datasetId) == "string"
        and cutover.datasetId ~= record.datasetId then
        return false, "cutover_dataset_mismatch"
    end
    if type(guildKey) == "string" and type(cutover.guildKey) == "string"
        and cutover.guildKey ~= "" and cutover.guildKey ~= guildKey then
        return false, "cutover_guild_mismatch"
    end
    if not IsFiniteNonnegInt(cutover.activatedAt) then
        return false, "invalid_cutover_time"
    end
    if not IsBoundedActorString(cutover.activatedByGuid) then
        return false, "invalid_cutover_actor"
    end
    local tab = tonumber(cutover.bankTab)
    if not tab or tab ~= math.floor(tab) or tab < 1 or tab > (GS.MAX_BANK_TAB or 8) then
        return false, "invalid_cutover_bank_tab"
    end
    local status = cutover.contextStatus
    if status ~= "captured" and status ~= "empty" then
        return false, "invalid_cutover_context"
    end
    if not IsFiniteNonnegInt(cutover.contextObservedAt) then
        return false, "invalid_cutover_context_time"
    end
    if status == "empty" then
        if tonumber(cutover.contextRecordCount) ~= 0 then
            return false, "invalid_cutover_context_count"
        end
    elseif not IsFiniteNonnegInt(cutover.contextRecordCount) then
        return false, "invalid_cutover_context_count"
    end
    local marker = cutover.cutoverMarker
    local expected = GS.BuildCutoverMarker(cutover.datasetId, cutover.activatedAt, tab)
    if type(marker) ~= "string" or marker == "" or marker ~= expected then
        return false, "invalid_cutover_marker"
    end
    local boundary = cutover.eligibilityBoundary
    if type(boundary) ~= "table" then
        return false, "invalid_cutover_boundary"
    end
    if boundary.baselineEstablished ~= true then
        return false, "invalid_cutover_boundary"
    end
    if not IsFiniteNonnegInt(boundary.tabEligibleFrom) then
        return false, "invalid_cutover_boundary"
    end
    -- Boundary must match the trustworthy bank sample observation time.
    if tonumber(boundary.tabEligibleFrom) ~= tonumber(cutover.contextObservedAt) then
        return false, "cutover_boundary_mismatch"
    end
    return true
end

--- Compact cutover summary for gossip descriptors (no bank anchors).
function GS.DescribeLiveCutover(cutover)
    if type(cutover) ~= "table" then
        return nil
    end
    return {
        schemaVersion = tonumber(cutover.schemaVersion) or GS.LIVE_CUTOVER_SCHEMA,
        datasetId = cutover.datasetId,
        guildKey = cutover.guildKey,
        activatedAt = cutover.activatedAt,
        activatedByGuid = cutover.activatedByGuid,
        bankTab = cutover.bankTab,
        contextStatus = cutover.contextStatus,
        contextObservedAt = cutover.contextObservedAt,
        contextRecordCount = cutover.contextRecordCount,
        cutoverMarker = cutover.cutoverMarker,
        eligibilityBoundary = type(cutover.eligibilityBoundary) == "table" and {
            baselineEstablished = cutover.eligibilityBoundary.baselineEstablished == true,
            tabEligibleFrom = cutover.eligibilityBoundary.tabEligibleFrom,
        } or nil,
    }
end

local function CopyLiveCutover(cutover)
    if type(cutover) ~= "table" then
        return nil
    end
    local copy = {
        schemaVersion = cutover.schemaVersion,
        datasetId = cutover.datasetId,
        guildKey = cutover.guildKey,
        activatedAt = cutover.activatedAt,
        activatedByGuid = cutover.activatedByGuid,
        activatedByName = cutover.activatedByName,
        bankTab = cutover.bankTab,
        contextStatus = cutover.contextStatus,
        contextObservedAt = cutover.contextObservedAt,
        contextRecordCount = cutover.contextRecordCount,
        cutoverMarker = cutover.cutoverMarker,
        eligibilityBoundary = nil,
    }
    if type(cutover.eligibilityBoundary) == "table" then
        copy.eligibilityBoundary = {
            baselineEstablished = cutover.eligibilityBoundary.baselineEstablished == true,
            tabEligibleFrom = cutover.eligibilityBoundary.tabEligibleFrom,
        }
    end
    return copy
end

--- Apply the agreed live eligibility boundary onto accounting._consumables.
-- Initial activation (opts.refreshOnly unset): replaces eligibility so only the
-- tab cutover gates post-activation deposits until new items are added.
-- Refresh (opts.refreshOnly): floors tab/item cutoffs to the immutable cutover
-- without wiping legitimate later campaign/item cutoffs rebuilt by replay.
local function ApplyLiveEligibilityBoundary(cfg, cutover, opts)
    if type(cfg) ~= "table" or type(cutover) ~= "table" then
        return false
    end
    local ts = tonumber(cutover.contextObservedAt)
    if not ts then
        return false
    end
    opts = opts or {}
    if opts.refreshOnly then
        local eligibility = cfg.eligibility
        if type(eligibility) ~= "table" then
            eligibility = {}
            cfg.eligibility = eligibility
        end
        local tabFrom = tonumber(eligibility.tabEligibleFrom)
        if not tabFrom or tabFrom < ts then
            eligibility.tabEligibleFrom = ts
        end
        local baselineAt = tonumber(eligibility.baselineAt)
        if not baselineAt or baselineAt < ts then
            eligibility.baselineAt = ts
        end
        eligibility.baselineEstablished = true
        eligibility.liveCutoverAt = ts
        eligibility.liveCutoverMarker = cutover.cutoverMarker
        if type(eligibility.items) ~= "table" then
            eligibility.items = {}
        else
            for key, value in pairs(eligibility.items) do
                local itemFrom = tonumber(value)
                if itemFrom and itemFrom < ts then
                    eligibility.items[key] = ts
                end
            end
        end
        return true
    end
    cfg.eligibility = {
        items = {},
        tabEligibleFrom = ts,
        baselineEstablished = true,
        baselineAt = ts,
        liveCutoverAt = ts,
        liveCutoverMarker = cutover.cutoverMarker,
    }
    return true
end

--- Re-floor accounting eligibility to an already-installed live cutover.
-- Used after campaign replay rebuilds eligibility from historical startedAt.
-- Preserves later item cutoffs (refreshOnly). No-op when not live.
function GS.RefreshLiveEligibilityFloor(record)
    if not GS.IsLiveActive(record) or type(record.liveCutover) ~= "table" then
        return false
    end
    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" then
        return false
    end
    return ApplyLiveEligibilityBoundary(cfg, record.liveCutover, { refreshOnly = true })
end

--- Drop unfinished pending evidence so staged/synthetic observations cannot
-- retrospectively credit after activation. Accepted ledger events stay.
local function QuarantinePreActivationPending(record)
    if type(record) ~= "table" or type(record.observations) ~= "table" then
        return
    end
    local byCampaign = record.observations.byCampaign
    if type(byCampaign) ~= "table" then
        return
    end
    for _, camp in pairs(byCampaign) do
        if type(camp) == "table" and type(camp.pending) == "table" then
            local kept = {}
            for i = 1, #camp.pending do
                local cluster = camp.pending[i]
                -- Retain only already-verified clusters (should be rare/empty).
                if type(cluster) == "table" and cluster.status == "verified" then
                    kept[#kept + 1] = cluster
                end
            end
            camp.pending = kept
        end
    end
    -- Local directExports are re-created by post-activation observation.
    if type(record.observations.directExports) == "table" then
        record.observations.directExports = {}
    end
end

local function StampLedgerListProductionCredit(list, credit)
    if type(list) ~= "table" then
        return
    end
    for i = 1, #list do
        local event = list[i]
        if type(event) == "table" then
            event.gsProductionCredit = credit and true or false
        end
    end
end

--- Durable classification: retained staged ledger rows never become live credit.
-- Does not delete history; projections skip gsProductionCredit == false when live.
function GS.ClassifyPreActivationAccounting(record)
    if type(record) ~= "table" or type(record.accounting) ~= "table" then
        return
    end
    StampLedgerListProductionCredit(record.accounting._consumableEvents, false)
    StampLedgerListProductionCredit(record.accounting._consumableEventArchive, false)
end

--- Reclassify retained rows when a remote live cutover installs on a staged peer.
-- Never trusts self-declared gsProductionCredit. Only rows admitted from an
-- authenticated active exporter (gsSourceCutoverMarker matches the installed
-- cutover) and after the cutover boundary may become production credit. All
-- other retained staged/synthetic rows stay uncredited (#389 order convergence).
function GS.ClassifyAccountingForRemoteCutover(record)
    if type(record) ~= "table" or type(record.accounting) ~= "table" then
        return
    end
    local marker = record.liveCutover and record.liveCutover.cutoverMarker
    local function classifyList(list)
        if type(list) ~= "table" then
            return
        end
        for i = 1, #list do
            local event = list[i]
            if type(event) == "table" then
                local credit = false
                if type(marker) == "string" and marker ~= ""
                    and event.gsSourceCutoverMarker == marker
                    and GS.IsEvidenceAfterLiveCutover then
                    local approx = tonumber(event.approxTxnTime) or tonumber(event.timestamp)
                    local afterOk = select(1, GS.IsEvidenceAfterLiveCutover(record, {
                        approxTxnTime = approx,
                    }))
                    credit = afterOk and true or false
                end
                event.gsProductionCredit = credit
            end
        end
    end
    classifyList(record.accounting._consumableEvents)
    classifyList(record.accounting._consumableEventArchive)
end

--- Whether an accepted ledger event counts toward live campaign totals.
-- Staged records include all accepted rows for preparation UI. Active records
-- only count production-classified rows (post-cutover admissions).
function GS.EventCountsTowardLiveProgress(record, event)
    if type(event) ~= "table" then
        return false
    end
    if not GS.IsLiveActive(record) then
        return true
    end
    return event.gsProductionCredit == true
end

--- Assign durable production-credit classification for a newly admitted event.
-- Never trusts a remote self-declared flag alone. Adjustments additionally require
-- authenticated cutover provenance (gsSourceCutoverMarker matches the installed
-- live marker); a post-cutover timestamp alone must not mint live credit (#389 A2).
function GS.AssignProductionCredit(record, event)
    if type(event) ~= "table" then
        return false
    end
    if not GS.IsLiveActive(record) then
        event.gsProductionCredit = false
        return false
    end
    local approx = tonumber(event.approxTxnTime) or tonumber(event.timestamp)
    local afterOk = true
    if GS.IsEvidenceAfterLiveCutover then
        afterOk = select(1, GS.IsEvidenceAfterLiveCutover(record, {
            approxTxnTime = approx,
        }))
    end
    if not afterOk then
        event.gsProductionCredit = false
        return false
    end
    local eventType = event.type
    local isAdjustment = eventType == "adjustment"
        or (GS.LEDGER_EVENT and eventType == GS.LEDGER_EVENT.ADJUSTMENT)
        or eventType == "CONSUMABLE_ADJUSTMENT"
    if isAdjustment then
        local marker = record.liveCutover and record.liveCutover.cutoverMarker
        if type(marker) ~= "string" or marker == ""
            or event.gsSourceCutoverMarker ~= marker then
            event.gsProductionCredit = false
            return false
        end
    end
    event.gsProductionCredit = true
    return true
end

local function OpenConflictsBlockActivation()
    if type(GS.ListOpenConflicts) ~= "function" then
        return false
    end
    local conflicts = GS:ListOpenConflicts()
    return type(conflicts) == "table" and #conflicts > 0
end

local function DatasetMismatchBlocksActivation()
    if type(GS.GetDatasetMismatchState) ~= "function" then
        return false
    end
    local state = GS:GetDatasetMismatchState()
    return type(state) == "table" and state.blocked == true
end

--- Peer live cutover that conflicts with the local active marker.
-- Only authenticated same-guild *editors* can create a blocking conflict so a
-- forged non-editor descriptor cannot indefinitely freeze production writes.
function GS:GetLiveActivationConflictState()
    local record = select(1, GS:GetCurrentRecord())
    if not GS.IsLiveActive(record) or type(record.liveCutover) ~= "table" then
        return { blocked = false, reason = nil, peers = {} }
    end
    local localMarker = record.liveCutover.cutoverMarker
    local peers = {}
    if type(GS._peerDatasets) ~= "table" then
        return { blocked = false, reason = nil, peers = peers }
    end
    local ctx = GS:GetCurrentContext()
    for _, entry in pairs(GS._peerDatasets) do
        if type(entry) == "table" and type(entry.cutoverMarker) == "string"
            and entry.cutoverMarker ~= "" and entry.cutoverMarker ~= localMarker then
            local member = GS.AuthenticateTransportSender and GS.AuthenticateTransportSender(entry.peerName)
            if member and ctx and member.guildKey == ctx.guildKey then
                local editorOk = GS.SenderHasEditorAuthority
                    and select(1, GS.SenderHasEditorAuthority(member, {}))
                if editorOk then
                    peers[#peers + 1] = {
                        peerName = entry.peerName,
                        datasetId = entry.datasetId,
                        cutoverMarker = entry.cutoverMarker,
                        activation = entry.activation,
                    }
                end
            end
        end
    end
    if #peers > 0 then
        return {
            blocked = true,
            reason = "live_activation_conflict",
            localCutoverMarker = localMarker,
            peers = peers,
        }
    end
    return { blocked = false, reason = nil, peers = peers }
end

--- True when authenticated live cutover conflict must fail-closed on writers.
-- Adoption replay onto a temporary record is exempt (not production writes).
-- offlineRecord alone is not an exemption when it is the live guild record
-- (test helpers and local writes still fail closed).
function GS.LiveAccountingWritesBlocked(record, admissionCtx)
    admissionCtx = admissionCtx or {}
    if admissionCtx.adoptionReplay then
        return false, nil
    end
    if admissionCtx.offlineRecord and type(GS.GetCurrentRecord) == "function" then
        local current = select(1, GS:GetCurrentRecord())
        if current and admissionCtx.offlineRecord ~= current then
            return false, nil
        end
    end
    if not GS.IsLiveActive(record) then
        return false, nil
    end
    if type(GS.GetLiveActivationConflictState) ~= "function" then
        return false, nil
    end
    local state = GS:GetLiveActivationConflictState()
    if type(state) == "table" and state.blocked then
        return true, state.reason or "live_activation_conflict"
    end
    return false, nil
end

--- Verified editor authority for remote live cutover install / catch-up.
-- A self-declared activatedByGuid is provenance metadata, not proof.
-- @return boolean ok, string|nil reason
function GS.AuthorizeRemoteLiveCutover(member, cutover, record, opts)
    opts = opts or {}
    if type(member) ~= "table" then
        return false, "unauthorized"
    end
    if type(GS.SenderHasEditorAuthority) ~= "function" then
        return false, "unauthorized"
    end
    local authOpts = opts.authOpts or {}
    local editorOk, editorReason = GS.SenderHasEditorAuthority(member, authOpts)
    if not editorOk then
        return false, editorReason or "unauthorized"
    end
    if type(cutover) ~= "table" then
        return false, "invalid_live_cutover"
    end
    -- Bind actor to the authenticated sender unless an editor is explicitly
    -- relaying a previously activated cutover (compatible catch-up).
    if opts.bindActorToSender ~= false then
        if type(cutover.activatedByGuid) ~= "string"
            or cutover.activatedByGuid ~= member.guid then
            return false, "cutover_actor_mismatch"
        end
    end
    if type(record) == "table" and type(cutover.datasetId) == "string"
        and type(record.datasetId) == "string"
        and cutover.datasetId ~= record.datasetId then
        return false, "cutover_dataset_mismatch"
    end
    return true, nil
end

--- Readiness probe for Settings banners (does not mutate).
function GS:GetActivationReadiness()
    local result = {
        canActivate = false,
        alreadyActive = false,
        reason = "not_ready",
        bankReady = false,
        bankReason = nil,
        bankStatus = nil,
    }
    if not GS:IsRootReady() then
        result.reason = GS:GetRootReason() or "not_ready"
        return result
    end
    local caps = GS:GetCapabilities()
    local record, recReason = GS:GetCurrentRecord()
    if GS.IsLiveActive(record) then
        result.alreadyActive = true
        result.canActivate = false
        result.reason = "already_activated"
        return result
    end
    if not record then
        result.reason = recReason or caps.reason or "not_configured"
        return result
    end
    if record.activation ~= GS.ACTIVATION_STAGED then
        result.reason = "unsupported_activation"
        return result
    end
    if not caps.canEdit then
        result.reason = caps.reason or "unauthorized"
        return result
    end
    if type(record.currentCampaignId) ~= "string" or record.currentCampaignId == "" then
        result.reason = "no_campaign"
        return result
    end
    local cfg = record.accounting and record.accounting._consumables
    local tab = cfg and tonumber(cfg.bankTab) or nil
    if not tab then
        result.reason = "bank_tab_unset"
        return result
    end
    if OpenConflictsBlockActivation() then
        result.reason = "divergent_edit"
        return result
    end
    if DatasetMismatchBlocksActivation() then
        result.reason = "dataset_mismatch"
        return result
    end
    local pendingAdoption = GS.GetPendingAdoption and GS:GetPendingAdoption()
    if type(pendingAdoption) == "table" then
        result.reason = "adoption_in_progress"
        return result
    end
    local ready, readyReason = GS.IsBankContextSampleReady(tab)
    result.bankReady = ready and true or false
    result.bankReason = readyReason
    result.configuredBankTab = tab
    if not ready then
        result.reason = readyReason or "log_not_updated"
        return result
    end
    -- Capture is non-mutating for readiness classification when APIs exist.
    local sample = GS.CaptureBankContext(tab)
    result.bankStatus = sample and sample.status or nil
    if not sample or (sample.status ~= "captured" and sample.status ~= "empty") then
        result.reason = (sample and sample.reason) or "readiness_unavailable"
        return result
    end
    result.canActivate = true
    result.reason = nil
    return result
end

--- Actionable Settings guidance while staged activation waits on a bank sample.
-- Ordinary Initialize / campaign configuration does not require an open bank;
-- only initial live activation needs a verified fresh transaction-log sample.
-- @return string|nil full sentence for status/help, or nil to use FormatReasonText
function GS.FormatActivationGuidance(readiness)
    if type(readiness) ~= "table" then
        return nil
    end
    if readiness.canActivate or readiness.alreadyActive then
        return nil
    end
    local reason = readiness.reason or readiness.bankReason
    if reason == "bank_tab_unset" then
        return Loc("GUILD_SUPPLIES_ACTIVATION_GUIDE_BANK_TAB_UNSET",
            "Configure a Guild Bank tab below before activation. Initialize and campaign setup do not require the bank to be open.")
    end
    if reason == "bank_closed" then
        return Loc("GUILD_SUPPLIES_ACTIVATION_GUIDE_BANK_CLOSED",
            "Open the Guild Bank and select the configured tab so a fresh transaction-log sample can be verified. Only live activation requires this sample.")
    end
    if reason == "not_observing" or reason == "tab_not_ready" then
        -- When an eligible legacy profile uses a different bank tab, guide the
        -- editor to open the configured Guild Supplies tab (event-driven via
        -- GetCurrentGuildBankTab); never auto-query both tabs.
        local BankLog = SF.ConsumablesBankLog
        local cfgTab = tonumber(readiness.configuredBankTab)
        if not cfgTab and type(BankLog) == "table" then
            local sample = BankLog.GuildSuppliesSampleOnlyContext
                and BankLog:GuildSuppliesSampleOnlyContext()
            cfgTab = sample and tonumber(sample.bankTab) or nil
        end
        local legacyTab = nil
        if type(BankLog) == "table" and BankLog.LegacyEligibleContext then
            local legacy = BankLog:LegacyEligibleContext()
            legacyTab = legacy and tonumber(legacy.bankTab) or nil
        end
        if cfgTab and legacyTab and cfgTab ~= legacyTab then
            local tmpl = Loc("GUILD_SUPPLIES_ACTIVATION_GUIDE_OTHER_TAB",
                "Guild Supplies uses Guild Bank tab %d, while your Raid Consumables profile uses tab %d. Select the Guild Supplies tab in the Guild Bank to take the activation sample. If a previous bank-log query was interrupted, close and reopen the bank with that tab selected. Legacy observation continues on its own tab until activation.")
            return string.format(tmpl, cfgTab, legacyTab)
        end
        if cfgTab then
            local tmpl = Loc("GUILD_SUPPLIES_ACTIVATION_GUIDE_SELECT_GS_TAB",
                "Guild Supplies uses Guild Bank tab %d. Select that tab in the Guild Bank to take the activation sample. If a previous bank-log query was interrupted, close and reopen the bank with that tab selected.")
            return string.format(tmpl, cfgTab)
        end
        return Loc("GUILD_SUPPLIES_ACTIVATION_GUIDE_NOT_OBSERVING",
            "Open the Guild Bank and select the configured tab so a fresh transaction-log sample can be taken for activation.")
    end
    if reason == "log_pending" or reason == "log_not_updated" then
        return Loc("GUILD_SUPPLIES_ACTIVATION_GUIDE_LOG_PENDING",
            "The Guild Bank is open. Activation will become available once a fresh transaction-log sample for the configured tab is verified.")
    end
    if reason == "log_stale" then
        return Loc("GUILD_SUPPLIES_ACTIVATION_GUIDE_LOG_STALE",
            "The Guild Bank log sample is stale. Select the configured tab again (or reopen the Guild Bank) so a fresh transaction-log sample can be verified before activation.")
    end
    if reason == "tab_access_denied" then
        return Loc("GUILD_SUPPLIES_ACTIVATION_GUIDE_TAB_ACCESS_DENIED",
            "This character needs permission to view the configured Guild Bank tab before activation can proceed.")
    end
    if reason == "tab_access_unknown" then
        return Loc("GUILD_SUPPLIES_ACTIVATION_GUIDE_TAB_ACCESS_UNKNOWN",
            "Bank tab access could not be verified. Open the Guild Bank on the configured tab, or check this character's bank permissions.")
    end
    return nil
end

--- Explicit authorized activation of the current staged guild dataset.
-- Idempotent when already active with a matching cutover marker.
-- @return record|nil, status ("accepted"|"duplicate"|"rejected"), reason|nil
function GS:ActivateCanonicalDataset()
    if not GS:IsRootReady() then
        return nil, "rejected", GS:GetRootReason() or "not_ready"
    end

    local prepared = {
        guildKey = nil,
        handleGeneration = GS.GetHandleGeneration(),
        actorGuid = nil,
    }
    local ctx = GS:GetCurrentContext()
    if not ctx or not ctx.ready or not ctx.guildKey then
        return nil, "rejected", (ctx and ctx.reason) or "not_ready"
    end
    prepared.guildKey = ctx.guildKey
    prepared.actorGuid = ctx.actorGuid

    local authOk, authReason, fresh = GS:_AuthorizeCommit(prepared, {})
    if not authOk then
        return nil, "rejected", authReason or "unauthorized"
    end
    ctx = fresh or ctx

    local record, recReason = GS:GetCurrentRecord()
    if not record then
        return nil, "rejected", recReason or "not_configured"
    end

    -- Idempotent success when already active with a valid cutover.
    if GS.IsLiveActive(record) then
        local cutOk, cutErr = GS.ValidateLiveCutover(record.liveCutover, record, ctx.guildKey)
        if cutOk then
            return record, "duplicate", "already_activated"
        end
        -- Active without recoverable cutover: fail closed; do not silently repair.
        DebugWarn("active record missing valid liveCutover err=%s", tostring(cutErr))
        return nil, "rejected", cutErr or "missing_live_cutover"
    end

    if record.activation ~= GS.ACTIVATION_STAGED then
        return nil, "rejected", "unsupported_activation"
    end
    if type(record.currentCampaignId) ~= "string" or record.currentCampaignId == "" then
        return nil, "rejected", "no_campaign"
    end
    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" then
        return nil, "rejected", "invalid_accounting"
    end
    local tab = tonumber(cfg.bankTab)
    if not tab then
        return nil, "rejected", "bank_tab_unset"
    end
    if OpenConflictsBlockActivation() then
        return nil, "rejected", "divergent_edit"
    end
    if DatasetMismatchBlocksActivation() then
        return nil, "rejected", "dataset_mismatch"
    end
    local pendingAdoption = GS.GetPendingAdoption and GS:GetPendingAdoption()
    if type(pendingAdoption) == "table" then
        return nil, "rejected", "adoption_in_progress"
    end

    -- Fresh bank sample required on the activating client only.
    local sample = GS.CaptureBankContext(tab)
    if type(sample) ~= "table"
        or (sample.status ~= "captured" and sample.status ~= "empty") then
        return nil, "rejected", (sample and sample.reason) or "log_not_updated"
    end
    local observedAt = tonumber(sample.observedAt)
    if not IsFiniteNonnegInt(observedAt) then
        return nil, "rejected", "server_time_unavailable"
    end

    -- Re-authorize immediately before commitment (rank/guild may have changed).
    authOk, authReason, fresh = GS:_AuthorizeCommit(prepared, {})
    if not authOk then
        return nil, "rejected", authReason or "unauthorized"
    end
    ctx = fresh or ctx
    if ctx.guildKey ~= prepared.guildKey then
        return nil, "rejected", "wrong_guild"
    end

    -- Re-read record after auth; refuse if displaced.
    local liveRecord, liveReason = GS:GetCurrentRecord()
    if not liveRecord or liveRecord ~= record then
        return nil, "rejected", liveReason or "dataset_mismatch"
    end
    if liveRecord.datasetId ~= record.datasetId then
        return nil, "rejected", "dataset_mismatch"
    end
    if liveRecord.activation ~= GS.ACTIVATION_STAGED then
        if GS.IsLiveActive(liveRecord) then
            return liveRecord, "duplicate", "already_activated"
        end
        return nil, "rejected", "unsupported_activation"
    end

    local marker = GS.BuildCutoverMarker(record.datasetId, observedAt, tab)
    if not marker then
        return nil, "rejected", "invalid_cutover_marker"
    end

    local previousActivation = record.activation
    local previousCutover = record.liveCutover
    local previousEligibility = cfg.eligibility

    local cutover = {
        schemaVersion = GS.LIVE_CUTOVER_SCHEMA,
        datasetId = record.datasetId,
        guildKey = ctx.guildKey,
        activatedAt = observedAt,
        activatedByGuid = ctx.actorGuid,
        activatedByName = ctx.actorName,
        bankTab = tab,
        contextStatus = sample.status,
        contextObservedAt = observedAt,
        contextRecordCount = tonumber(sample.recordCount) or (sample.status == "empty" and 0 or nil),
        cutoverMarker = marker,
        eligibilityBoundary = {
            baselineEstablished = true,
            tabEligibleFrom = observedAt,
        },
    }

    local cutOk, cutErr = GS.ValidateLiveCutover(cutover, record, ctx.guildKey)
    if not cutOk then
        return nil, "rejected", cutErr or "invalid_live_cutover"
    end

    -- Atomic local commitment.
    record.activation = GS.ACTIVATION_ACTIVE
    record.liveCutover = cutover
    if not ApplyLiveEligibilityBoundary(cfg, cutover) then
        record.activation = previousActivation
        record.liveCutover = previousCutover
        cfg.eligibility = previousEligibility
        return nil, "rejected", "invalid_cutover_boundary"
    end
    QuarantinePreActivationPending(record)
    GS.ClassifyPreActivationAccounting(record)

    local structOk, structErr = GS._ValidateGuildRecordStructure(ctx.guildKey, record)
    if not structOk then
        record.activation = previousActivation
        record.liveCutover = previousCutover
        cfg.eligibility = previousEligibility
        DebugWarn("activation structural rollback err=%s", tostring(structErr))
        return nil, "rejected", structErr or "invalid_record"
    end

    DebugInfo("activated canonical dataset=%s marker=%s tab=%s status=%s",
        tostring(record.datasetId), tostring(marker), tostring(tab), tostring(sample.status))
    if GS._NotifyLocalDurableChange then
        GS._NotifyLocalDurableChange("activation")
    end
    return record, "accepted", "activated"
end

--- Install an authenticated remote liveCutover onto a record (adoption / catch-up).
-- Does not require a local bank sample. Fails closed on incompatible markers.
-- When opts.member is supplied (production gossip/bootstrap), requires verified
-- current editor authority; activatedByGuid alone is never sufficient proof.
-- @return status, reason
function GS.InstallRemoteLiveCutover(record, cutover, guildKey, opts)
    opts = opts or {}
    if type(record) ~= "table" then
        return "rejected", "invalid_record"
    end
    local copy = CopyLiveCutover(cutover)
    local ok, err = GS.ValidateLiveCutover(copy, record, guildKey)
    if not ok then
        return "rejected", err or "invalid_live_cutover"
    end
    if opts.member ~= nil or opts.requireEditorAuthority then
        local authOk, authErr = GS.AuthorizeRemoteLiveCutover(
            opts.member, copy, record, {
                authOpts = opts.authOpts,
                bindActorToSender = opts.bindActorToSender,
            })
        if not authOk then
            return "rejected", authErr or "unauthorized"
        end
    end
    if GS.IsLiveActive(record) and type(record.liveCutover) == "table" then
        if record.liveCutover.cutoverMarker == copy.cutoverMarker then
            -- Adoption / campaign replay may have rebuilt eligibility; refresh the
            -- agreed live floor without wiping later item cutoffs or reclassifying.
            if opts.refreshEligibility then
                GS.RefreshLiveEligibilityFloor(record)
            end
            return "duplicate", "already_activated"
        end
        -- Divergent live markers: never silently overwrite.
        return "rejected", "live_activation_conflict"
    end
    if record.activation ~= GS.ACTIVATION_STAGED and not opts.forceActive then
        if not GS.IsSupportedActivation(record.activation) then
            return "rejected", "unsupported_activation"
        end
    end

    local cfg = record.accounting and record.accounting._consumables
    local previousActivation = record.activation
    local previousCutover = record.liveCutover
    local previousEligibility = cfg and cfg.eligibility

    record.activation = GS.ACTIVATION_ACTIVE
    record.liveCutover = copy
    if type(cfg) == "table" then
        -- Same-dataset remote catch-up: preserve staged item/tab cutoffs already
        -- rebuilt by operation replay (refreshOnly floors to the cutover). Local
        -- ActivateCanonicalDataset still uses full replacement intentionally.
        local elig = cfg.eligibility
        local refreshOnly = type(elig) == "table"
            and elig.baselineEstablished == true
            and type(elig.items) == "table"
        ApplyLiveEligibilityBoundary(cfg, copy, refreshOnly and { refreshOnly = true } or nil)
    end
    if opts.quarantinePending ~= false then
        QuarantinePreActivationPending(record)
    end
    if opts.classifyPreActivation ~= false then
        -- Same-dataset catch-up: preserve authenticated post-cutover rows that
        -- arrived while this peer was still staged (marker-bound provenance).
        if GS.ClassifyAccountingForRemoteCutover then
            GS.ClassifyAccountingForRemoteCutover(record)
        else
            GS.ClassifyPreActivationAccounting(record)
        end
    end

    if GS._ValidateGuildRecordStructure then
        local structOk, structErr = GS._ValidateGuildRecordStructure(guildKey, record)
        if not structOk then
            record.activation = previousActivation
            record.liveCutover = previousCutover
            if type(cfg) == "table" then
                cfg.eligibility = previousEligibility
            end
            return "rejected", structErr or "invalid_record"
        end
    end
    return "accepted", nil
end

--- Evidence time must be at/after the live cutover boundary when active.
function GS.IsEvidenceAfterLiveCutover(record, evidence)
    if not GS.IsLiveActive(record) then
        return true
    end
    local cutover = record.liveCutover
    if type(cutover) ~= "table" then
        return false, "missing_live_cutover"
    end
    local boundary = tonumber(cutover.eligibilityBoundary and cutover.eligibilityBoundary.tabEligibleFrom)
        or tonumber(cutover.contextObservedAt)
    if not boundary then
        return false, "missing_live_cutover"
    end
    local approx = tonumber(evidence and evidence.approxTxnTime)
    if not approx then
        return false, "not_eligible"
    end
    if approx < boundary then
        return false, "not_eligible"
    end
    return true
end
