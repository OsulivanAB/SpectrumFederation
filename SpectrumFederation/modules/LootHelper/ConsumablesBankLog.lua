-- Guild Bank transaction-log observer host for Raid Consumables / Guild Supplies.
-- After #389 live activation, observations feed Guild Supplies three-witness ledger.
local _, SF = ...

SF.ConsumablesBankLog = SF.ConsumablesBankLog or {}
local BankLog = SF.ConsumablesBankLog

local QUERY_RETRY_DELAY = 1.0
local MAX_QUERY_RETRIES = 5
local SLOTS_THROTTLE_SECONDS = 1

local function Debug(level, message, ...)
    if SF.Debug and SF.Debug[level] then
        SF.Debug[level](SF.Debug, "CONSUMABLES_BANKLOG", message, ...)
    end
end

local function TryRegister(frame, event)
    if not frame or not frame.RegisterEvent then return end
    pcall(frame.RegisterEvent, frame, event)
end

local function WallNow()
    local O = SF.ConsumablesObservation
    if O and O.Now then return O.Now() end
    return time()
end

function BankLog:ObservationDB()
    local db = SF.lootHelperDB
    if type(db) ~= "table" then
        if type(SpectrumFederationDB) == "table" then
            SpectrumFederationDB.lootHelper = SpectrumFederationDB.lootHelper or {}
            db = SpectrumFederationDB.lootHelper
            SF.lootHelperDB = db
        end
    end
    return db
end

function BankLog:AccountingProfile()
    local Runtime = SF.ConsumablesRuntime
    if Runtime and Runtime.AccountingProfile then
        return Runtime:AccountingProfile()
    end
    return SF.GetActiveProfile and SF:GetActiveProfile() or nil
end

function BankLog:ProfileId(profile)
    if type(profile) ~= "table" then return nil end
    if profile.GetProfileId then
        return profile:GetProfileId()
    end
    return profile._profileId
end

function BankLog:CurrentGuildGuid()
    local Runtime = SF.ConsumablesRuntime
    if Runtime and Runtime.CurrentGuild then
        local guild = Runtime:CurrentGuild()
        if guild and guild.guid then return tostring(guild.guid) end
        return nil
    end
    if C_Club and C_Club.GetGuildClubId then
        local clubId = C_Club.GetGuildClubId()
        if clubId ~= nil and clubId ~= 0 and clubId ~= "0" and clubId ~= "" then
            return tostring(clubId)
        end
    end
    return nil
end

function BankLog:ObserverId()
    if SF.NameUtil and SF.NameUtil.GetSelfId then
        return SF.NameUtil.GetSelfId()
    end
    return nil
end

--- Shared Guild Supplies bank-tab context (live admission or staged sample-only).
-- @param opts { sampleOnly?: boolean }
function BankLog:BuildGuildSuppliesContext(record, opts)
    opts = opts or {}
    local GS = SF.GuildSupplies
    local O = SF.ConsumablesObservation
    if not GS or not O or type(record) ~= "table" then
        return nil
    end
    local cfg = record.accounting and record.accounting._consumables
    if type(cfg) ~= "table" then return nil end
    if type(cfg.guild) ~= "table" or type(cfg.guild.guid) ~= "string" or cfg.guild.guid == "" then
        return nil
    end
    local tab = tonumber(cfg.bankTab)
    if not tab or tab < 1 or tab > 8 then return nil end
    local guildGuid = self:CurrentGuildGuid()
    if not guildGuid or guildGuid ~= tostring(cfg.guild.guid) then
        return nil
    end
    if type(record.currentCampaignId) ~= "string" or record.currentCampaignId == "" then
        return nil
    end
    local sampleOnly = opts.sampleOnly == true
    local requestedSet = O.RequestedSetFromConfig(cfg)
    local hasRequested = false
    for _ in pairs(requestedSet) do
        hasRequested = true
        break
    end
    -- Sample-only staged activation may query an empty requested-item campaign;
    -- live donation observation still requires at least one requested item.
    if not hasRequested and not sampleOnly then return nil end
    return {
        source = "guildSupplies",
        sampleOnly = sampleOnly,
        record = record,
        profile = nil,
        profileId = (sampleOnly and "guildSuppliesSample:" or "guildSupplies:")
            .. tostring(record.datasetId),
        cfg = cfg,
        guildGuid = guildGuid,
        bankTab = tab,
        generation = tonumber(cfg.generation) or 0,
        campaignId = record.currentCampaignId,
        datasetId = record.datasetId,
        requestedSet = requestedSet,
        observedBy = self:ObserverId(),
        eligibility = cfg.eligibility,
    }
end

function BankLog:GuildSuppliesEligibleContext()
    local GS = SF.GuildSupplies
    local O = SF.ConsumablesObservation
    if not GS or not O or not GS.IsLiveActiveForCurrentGuild then
        return nil
    end
    if not GS:IsLiveActiveForCurrentGuild() then
        return nil
    end
    local record, reason = GS:GetCurrentRecord()
    if not record then
        Debug("Verbose", "guild supplies observation idle: %s", tostring(reason))
        return nil
    end
    return self:BuildGuildSuppliesContext(record, { sampleOnly = false })
end

--- Staged sample-only observation: query/stamp the configured GS tab without
-- admitting donations or mutating staged production accounting (#389 repair).
function BankLog:GuildSuppliesSampleOnlyContext()
    local GS = SF.GuildSupplies
    local O = SF.ConsumablesObservation
    if not GS or not O or not GS.GetCurrentRecord then
        return nil
    end
    if GS.IsLiveActiveForCurrentGuild and GS:IsLiveActiveForCurrentGuild() then
        return nil
    end
    local record = select(1, GS:GetCurrentRecord())
    if not record or record.activation ~= GS.ACTIVATION_STAGED then
        return nil
    end
    -- Only authorized editors need the pre-activation bank sample path.
    local caps = GS.GetCapabilities and GS:GetCapabilities()
    if not caps or not caps.canEdit then
        return nil
    end
    return self:BuildGuildSuppliesContext(record, { sampleOnly = true })
end

--- Eligible legacy (Loot Helper profile) bank observation context, or nil.
-- Used before Guild Supplies activation while legacy remains the production writer.
function BankLog:LegacyEligibleContext()
    local C = SF.Consumables
    local O = SF.ConsumablesObservation
    local GS = SF.GuildSupplies
    if not C or not O then return nil end
    local profile = self:AccountingProfile()
    if type(profile) ~= "table" then return nil end
    if GS and type(C.LegacyWritersAllowed) == "function" and not C.LegacyWritersAllowed(profile) then
        -- Live Guild Supplies for this profile's guild: do not fall back to
        -- profile writers for that guild (#389).
        return nil
    end
    local cfg = C.Ensure(profile)
    if type(cfg) ~= "table" then return nil end
    if type(cfg.guild) ~= "table" or type(cfg.guild.guid) ~= "string" or cfg.guild.guid == "" then
        return nil
    end
    local tab = tonumber(cfg.bankTab)
    if not tab or tab < 1 or tab > 8 then return nil end
    local guildGuid = self:CurrentGuildGuid()
    if not guildGuid or guildGuid ~= cfg.guild.guid then
        return nil
    end
    local requestedSet = O.RequestedSetFromConfig(cfg)
    local hasRequested = false
    for _ in pairs(requestedSet) do
        hasRequested = true
        break
    end
    if not hasRequested then return nil end
    return {
        source = "legacyProfile",
        profile = profile,
        profileId = self:ProfileId(profile),
        cfg = cfg,
        guildGuid = guildGuid,
        bankTab = tab,
        generation = tonumber(cfg.generation) or 0,
        requestedSet = requestedSet,
        observedBy = self:ObserverId(),
    }
end

function BankLog:EligibleContext()
    -- Live Guild Supplies is the sole production observer after activation.
    local gsCtx = self:GuildSuppliesEligibleContext()
    if gsCtx then
        return gsCtx
    end
    local sampleCtx = self:GuildSuppliesSampleOnlyContext()
    local legacyCtx = self:LegacyEligibleContext()
    if sampleCtx and legacyCtx then
        if sampleCtx.bankTab == legacyCtx.bankTab then
            -- Same tab: one QueryGuildBankLog serves GS freshness + legacy reconcile.
            sampleCtx.legacy = legacyCtx
            return sampleCtx
        end
        -- Different tabs: never issue overlapping uncorrelated queries. Prefer
        -- the tab the player currently has selected so an editor can take the
        -- GS activation sample by opening that tab (legacy stays primary on its
        -- own tab). Unknown current tab → legacy production writer.
        local currentTab = nil
        if type(GetCurrentGuildBankTab) == "function" then
            currentTab = tonumber(GetCurrentGuildBankTab())
        end
        if currentTab and currentTab == sampleCtx.bankTab then
            return sampleCtx
        end
        return legacyCtx
    end
    if sampleCtx then
        return sampleCtx
    end
    return legacyCtx
end

--- Independent legacy view over the same authenticated raw bank rows.
-- Reuses rows/provenance from a completed query but never inherits Guild Supplies
-- requestedSet / generation / eligibility / observer identity.
function BankLog:BuildLegacySnapshotView(legacyCtx, rawSnapshot)
    if type(legacyCtx) ~= "table" or legacyCtx.source ~= "legacyProfile"
        or type(rawSnapshot) ~= "table" then
        return nil
    end
    if tonumber(legacyCtx.bankTab) ~= tonumber(rawSnapshot.bankTab) then
        return nil
    end
    if tostring(legacyCtx.guildGuid or "") ~= tostring(rawSnapshot.guildGuid or "") then
        return nil
    end
    local C = SF.Consumables
    local eligibility = nil
    if C and C.EligibilitySnapshot and legacyCtx.profile then
        eligibility = C.EligibilitySnapshot(legacyCtx.profile)
    end
    return {
        authoritative = rawSnapshot.authoritative ~= false,
        guildGuid = legacyCtx.guildGuid,
        bankTab = legacyCtx.bankTab,
        generation = legacyCtx.generation,
        observedBy = legacyCtx.observedBy,
        observedAt = rawSnapshot.observedAt,
        requestedSet = legacyCtx.requestedSet,
        eligibility = eligibility,
        rows = rawSnapshot.rows,
    }
end

--- Live companion legacy context for a completed GS sample query, or nil.
-- Never falls back to a pending/stale legacy identity after profile/guild/tab
-- or writer eligibility changes mid-query.
function BankLog:LiveLegacyCompanionForQuery(pendingCtx, liveCtx)
    if type(pendingCtx) ~= "table" or type(liveCtx) ~= "table" then
        return nil
    end
    if pendingCtx.source ~= "guildSupplies" or pendingCtx.sampleOnly ~= true then
        return nil
    end
    local legacy = liveCtx.legacy
    if type(legacy) ~= "table" or legacy.source ~= "legacyProfile" then
        return nil
    end
    if tonumber(legacy.bankTab) ~= tonumber(pendingCtx.bankTab) then
        return nil
    end
    if tostring(legacy.guildGuid or "") ~= tostring(pendingCtx.guildGuid or "") then
        return nil
    end
    local C = SF.Consumables
    if C and type(C.LegacyWritersAllowed) == "function"
        and not C.LegacyWritersAllowed(legacy.profile) then
        return nil
    end
    -- Require the live EligibleContext still author the same companion profile.
    local fresh = self:LegacyEligibleContext()
    if type(fresh) ~= "table" then
        return nil
    end
    if tostring(fresh.profileId or "") ~= tostring(legacy.profileId or "") then
        return nil
    end
    if tonumber(fresh.bankTab) ~= tonumber(legacy.bankTab) then
        return nil
    end
    if tostring(fresh.guildGuid or "") ~= tostring(legacy.guildGuid or "") then
        return nil
    end
    return fresh
end

function BankLog:AdmitGuildSuppliesSnapshot(ctx, snapshot)
    local GS = SF.GuildSupplies
    local O = SF.ConsumablesObservation
    if not GS or not O or type(ctx) ~= "table" or type(snapshot) ~= "table" then
        return { admitted = 0, pending = 0, rejected = 0 }
    end
    local evidenceRows = O.ListEligibleEvidenceFromSnapshot(snapshot)
    local stats = { admitted = 0, pending = 0, rejected = 0, duplicate = 0 }
    local ctxAuth = GS:GetCurrentContext()
    if not ctxAuth or not ctxAuth.ready or type(ctxAuth.actorGuid) ~= "string" then
        -- Roster/identity not ready yet: defer this complete snapshot for a
        -- single event-driven re-evaluation (do not treat as permanent reject).
        stats.deferred = true
        stats.deferReason = (ctxAuth and ctxAuth.reason) or "roster_incomplete"
        Debug("Warn", "guild supplies admit deferred: local actor not ready reason=%s",
            tostring(stats.deferReason))
        return stats
    end
    local member = {
        guid = ctxAuth.actorGuid,
        name = ctxAuth.actorName or self:ObserverId(),
        guildKey = ctxAuth.guildKey,
        rankOrder = ctxAuth.rankOrder,
    }
    -- One completed bank snapshot: probe live-write conflict once (same record
    -- and local actor for every row) and coalesce durable/export notifications
    -- so nested evidence/ledger notifies do not each rescan roster/exports.
    local record = select(1, GS:GetCurrentRecord())
    local liveBlocked, liveBlockReason = false, nil
    if type(record) == "table" and GS.LiveAccountingWritesBlocked then
        liveBlocked, liveBlockReason = GS.LiveAccountingWritesBlocked(record, {
            member = member,
            sender = member.name,
            localWrite = true,
        })
    end
    local beganBatch = false
    local beganMarket = false
    -- One completed snapshot: reuse DBMarket reads for identical price-query
    -- keys while still minting a separate immutable assignment per donation.
    if GS.BeginValuationSnapshotMarketCache then
        GS.BeginValuationSnapshotMarketCache()
        beganMarket = true
    end
    if GS.BeginLocalDurableNotifyBatch then
        GS.BeginLocalDurableNotifyBatch()
        beganBatch = true
    end
    for i = 1, #evidenceRows do
        local evidence = evidenceRows[i]
        if type(evidence) == "table" then
            evidence.campaignId = evidence.campaignId or ctx.campaignId
            evidence.datasetId = evidence.datasetId or ctx.datasetId
            local st, reason = GS:AdmitDirectObservation(evidence, {
                member = member,
                sender = member.name,
                localWrite = true,
                campaignId = ctx.campaignId,
                liveWritesBlockedCached = true,
                liveWritesBlocked = liveBlocked and true or false,
                liveWritesBlockReason = liveBlockReason,
            })
            if st == "accepted" then
                stats.admitted = stats.admitted + 1
            elseif st == "duplicate" then
                stats.duplicate = stats.duplicate + 1
            elseif st == "pending" then
                stats.pending = stats.pending + 1
            else
                stats.rejected = stats.rejected + 1
                Debug("Verbose", "guild supplies evidence rejected reason=%s", tostring(reason))
            end
        end
    end
    if beganBatch and GS.EndLocalDurableNotifyBatch then
        GS.EndLocalDurableNotifyBatch()
    end
    if beganMarket and GS.EndValuationSnapshotMarketCache then
        GS.EndValuationSnapshotMarketCache()
    end
    return stats
end

local function ClearFreshLogStamp(self)
    self.lastFreshLogAt = nil
    self.lastFreshLogTab = nil
    self.lastFreshLogGuild = nil
end

local function ClearPendingQuery(self)
    self.pendingQuery = nil
end

local function ClearPendingAdmit(self)
    self.pendingAdmit = nil
end

local function ClearFreshnessGate(self)
    self.requireBankReopenForFreshness = false
end

local function SnapshotQueryContext(ctx)
    if type(ctx) ~= "table" then
        return nil
    end
    return {
        source = ctx.source,
        sampleOnly = ctx.sampleOnly == true,
        profileId = ctx.profileId,
        guildGuid = ctx.guildGuid,
        bankTab = ctx.bankTab,
        generation = ctx.generation,
        campaignId = ctx.campaignId,
        datasetId = ctx.datasetId,
        requestedSet = ctx.requestedSet,
        observedBy = ctx.observedBy,
        eligibility = ctx.eligibility,
        profile = ctx.profile,
        record = ctx.record,
        cfg = ctx.cfg,
        -- Legacy companion is resolved live at ProcessLogUpdate time (never
        -- snapshotted onto pending query identity).
    }
end

local function QueryContextMatchesLive(pending, live)
    if type(pending) ~= "table" or type(live) ~= "table" then
        return false
    end
    return pending.bankTab == live.bankTab
        and tostring(pending.guildGuid or "") == tostring(live.guildGuid or "")
        and tostring(pending.profileId or "") == tostring(live.profileId or "")
        and tostring(pending.datasetId or "") == tostring(live.datasetId or "")
        and tostring(pending.campaignId or "") == tostring(live.campaignId or "")
        and tonumber(pending.generation) == tonumber(live.generation)
end

function BankLog:CancelTimers(reason)
    self.queryToken = (self.queryToken or 0) + 1
    self.queryRetries = 0
    self.awaitingLogUpdate = false
    ClearPendingQuery(self)
    -- A cancelled/invalidated query cycle must not keep an older successful stamp.
    ClearFreshLogStamp(self)
    if reason then
        Debug("Verbose", "cancelled bank-log timers reason=%s", tostring(reason))
    end
end

function BankLog:ScheduleAfter(delay, tokenField, fn)
    if not (C_Timer and C_Timer.After) then return end
    local token = (self[tokenField] or 0)
    C_Timer.After(delay, function()
        if self[tokenField] ~= token then return end
        if not self.active then return end
        fn()
    end)
end

function BankLog:RequestLog(reason)
    local ctx = self.activeContext
    if not self.active or type(ctx) ~= "table" then return end
    if type(QueryGuildBankLog) ~= "function" then
        Debug("Warn", "QueryGuildBankLog unavailable")
        return
    end
    -- Overlapping tab/guild queries cannot be correlated to GUILDBANKLOG_UPDATE.
    -- Fail closed: abandon the outstanding query and require a clean bank
    -- close/reopen before any freshness stamp may be established.
    if self.requireBankReopenForFreshness then
        ClearFreshLogStamp(self)
        ClearPendingQuery(self)
        self.awaitingLogUpdate = false
        Debug("Info", "bank-log query suppressed: reopen required for freshness")
        return
    end
    local now = WallNow()
    -- Slot churn can be frequent; coalesce while a query is already outstanding
    -- or a recent query just completed successfully. Invalidate the prior
    -- successful stamp immediately so readiness cannot reuse a pre-change
    -- sample while the replacement query is throttled or already in flight.
    if reason == "slots_changed" then
        ClearFreshLogStamp(self)
        if self.awaitingLogUpdate then return end
        if self.lastQueryAt and (now - self.lastQueryAt) < SLOTS_THROTTLE_SECONDS then
            return
        end
    end
    if reason ~= "retry" then
        self.queryRetries = 0
    end
    -- Starting a new sample invalidates any prior successful freshness stamp.
    ClearFreshLogStamp(self)
    local prev = self.pendingQuery
    if self.awaitingLogUpdate and type(prev) == "table" then
        local same = QueryContextMatchesLive(prev, ctx)
        if not same then
            -- A response for the old query may still arrive and would otherwise
            -- match the new pending identity. Retail events carry no query id.
            self.requireBankReopenForFreshness = true
            ClearPendingQuery(self)
            ClearPendingAdmit(self)
            self.awaitingLogUpdate = false
            self.queryToken = (self.queryToken or 0) + 1
            Debug("Warn",
                "bank-log query overlap tab %s→%s; require bank reopen for freshness",
                tostring(prev.bankTab), tostring(ctx.bankTab))
            return
        end
    end
    -- Bind the outstanding query to this context. GUILDBANKLOG_UPDATE does not
    -- identify which tab answered; ProcessLogUpdate must not stamp a different
    -- live tab from this response.
    self.pendingQuery = SnapshotQueryContext(ctx)
    self.awaitingLogUpdate = true
    self.lastQueryAt = now
    self.lastQueryReason = reason
    -- New query attempt invalidates any prior retry callback.
    self.queryToken = (self.queryToken or 0) + 1
    Debug("Info", "query guild bank log tab=%s reason=%s", tostring(ctx.bankTab), tostring(reason or "scan"))
    pcall(QueryGuildBankLog, ctx.bankTab)

    local tokenField = "queryToken"
    local retries = self.queryRetries or 0
    if retries < MAX_QUERY_RETRIES then
        self:ScheduleAfter(QUERY_RETRY_DELAY, tokenField, function()
            if not self.awaitingLogUpdate then return end
            self.queryRetries = (self.queryRetries or 0) + 1
            Debug("Info", "retry guild bank log query attempt=%s", tostring(self.queryRetries))
            self:RequestLog("retry")
        end)
    else
        -- Final attempt already issued above. Clear awaiting so a later genuine
        -- bank-change event can start a new bounded cycle without reopen.
        self:ScheduleAfter(QUERY_RETRY_DELAY, tokenField, function()
            if not self.awaitingLogUpdate then return end
            self.awaitingLogUpdate = false
            self.queryRetries = 0
            ClearFreshLogStamp(self)
            Debug("Warn", "guild bank log query retries exhausted; idle until next event")
        end)
    end
end

function BankLog:ReadSnapshot(ctx)
    if type(GetNumGuildBankTransactions) ~= "function" or type(GetGuildBankTransaction) ~= "function" then
        Debug("Warn", "guild bank transaction APIs unavailable")
        return nil
    end
    local tab = ctx.bankTab
    local okCount, count = pcall(GetNumGuildBankTransactions, tab)
    if not okCount or type(count) ~= "number" or count < 0 then
        Debug("Warn", "GetNumGuildBankTransactions failed for tab=%s", tostring(tab))
        return nil
    end
    count = math.floor(count)
    local rows = {}
    for index = 1, count do
        local ok, txnType, name, itemLink, txnCount, tab1, tab2, year, month, day, hour =
            pcall(GetGuildBankTransaction, tab, index)
        if ok then
            rows[#rows + 1] = {
                type = txnType,
                name = name,
                itemLink = itemLink,
                count = txnCount,
                tab1 = tab1,
                tab2 = tab2,
                year = year,
                month = month,
                day = day,
                hour = hour,
                index = index,
            }
        else
            Debug("Warn", "GetGuildBankTransaction failed tab=%s index=%s", tostring(tab), tostring(index))
            -- Never treat a partial failed read as authoritative fresh evidence.
            return nil
        end
    end
    return {
        authoritative = true,
        guildGuid = ctx.guildGuid,
        bankTab = tab,
        generation = ctx.generation,
        observedBy = ctx.observedBy,
        observedAt = WallNow(),
        requestedSet = ctx.requestedSet,
        rows = rows,
    }
end

function BankLog:ProcessLogUpdate(reason)
    if not self.active then return end
    local live = self:EligibleContext()
    if not live or not live.profileId then
        self.awaitingLogUpdate = false
        ClearPendingQuery(self)
        ClearFreshLogStamp(self)
        Debug("Info", "log update ignored: no eligible consumables context")
        return
    end

    -- Unsolicited or post-overlap updates must never establish activation freshness.
    -- GUILDBANKLOG_UPDATE does not identify which QueryGuildBankLog completed.
    if self.requireBankReopenForFreshness then
        ClearFreshLogStamp(self)
        Debug("Info", "log update discarded: bank reopen required for freshness")
        return
    end
    local pending = self.pendingQuery
    if not (self.awaitingLogUpdate and type(pending) == "table") then
        ClearFreshLogStamp(self)
        Debug("Info", "log update discarded: no outstanding query provenance")
        return
    end
    if not QueryContextMatchesLive(pending, live) then
        -- Late/uncorrelated update after tab/guild/dataset change: never stamp
        -- the new live tab from a query started for a different context.
        -- GUILDBANKLOG_UPDATE carries no query identity, so starting a
        -- replacement B query in the same open session is not trustworthy —
        -- same fail-closed reopen gate as RequestLog overlap.
        Debug("Info",
            "log update discarded: query context mismatch pendingTab=%s liveTab=%s; require bank reopen",
            tostring(pending.bankTab), tostring(live.bankTab))
        self.requireBankReopenForFreshness = true
        self.awaitingLogUpdate = false
        ClearPendingQuery(self)
        ClearPendingAdmit(self)
        ClearFreshLogStamp(self)
        self.queryRetries = 0
        self.queryToken = (self.queryToken or 0) + 1
        self.activeContext = live
        return
    end
    -- Read and stamp the queried identity (pending), not a rebuilt live table.
    local ctx = pending
    -- Keep live eligibility/requestedSet when the identity still matches.
    ctx.eligibility = live.eligibility or ctx.eligibility
    ctx.requestedSet = live.requestedSet or ctx.requestedSet
    ctx.record = live.record or ctx.record
    ctx.cfg = live.cfg or ctx.cfg
    ctx.profile = live.profile or ctx.profile
    -- Companion legacy is live-only (never pending fallback — avoids stale writes).
    ctx.legacy = nil

    self.activeContext = live
    self.queryRetries = 0
    -- Cancel outstanding retry callbacks for this update attempt.
    self.queryToken = (self.queryToken or 0) + 1

    local snapshot = self:ReadSnapshot(ctx)
    if not snapshot then
        -- Failed refresh must not keep awaiting=false with an older successful stamp.
        self.awaitingLogUpdate = false
        ClearPendingQuery(self)
        ClearFreshLogStamp(self)
        Debug("Warn", "log update skipped: incomplete snapshot reason=%s", tostring(reason))
        return
    end
    self.awaitingLogUpdate = false
    ClearPendingQuery(self)
    -- Freshness stamp for read-only bank-context adapters (Guild Supplies #386).
    -- Restored only after a complete successful update for the queried tab.
    self.lastFreshLogAt = WallNow()
    self.lastFreshLogTab = ctx.bankTab
    self.lastFreshLogGuild = ctx.guildGuid

    -- Guild Supplies paths: no Loot Helper profile / raid session required.
    if ctx.source == "guildSupplies" then
        self.lastVerifyStats = nil
        if ctx.sampleOnly then
            -- Staged preparation: freshness stamp only; never admit donations.
            ClearPendingAdmit(self)
            self.lastStats = {
                admitted = 0, pending = 0, rejected = 0, duplicate = 0, sampleOnly = true,
            }
            Debug("Info",
                "guild supplies sample-only stamp reason=%s tab=%s rows=%s",
                tostring(reason or "update"),
                tostring(ctx.bankTab),
                tostring(#(snapshot.rows or {})))
            -- Same-tab live legacy companion: independent snapshot view over the
            -- same authenticated rows (GS requestedSet/generation never applied).
            local legacy = self:LiveLegacyCompanionForQuery(ctx, live)
            if legacy then
                local legacySnap = self:BuildLegacySnapshotView(legacy, snapshot)
                if legacySnap then
                    self:ProcessLegacySnapshot(legacy, legacySnap, reason)
                end
            end
            return
        end
        snapshot.eligibility = ctx.eligibility
        local admitStats = self:AdmitGuildSuppliesSnapshot(ctx, snapshot)
        self.lastStats = admitStats
        if admitStats and admitStats.deferred then
            -- Retain one complete snapshot for roster-ready re-evaluation.
            self.pendingAdmit = {
                ctx = SnapshotQueryContext(ctx),
                snapshot = snapshot,
            }
            self:EnsureRosterAdmitListener()
        else
            ClearPendingAdmit(self)
        end
        Debug("Info",
            "guild supplies bank admit reason=%s accepted=%s pending=%s duplicate=%s rejected=%s deferred=%s rows=%s",
            tostring(reason or "update"),
            tostring(admitStats.admitted),
            tostring(admitStats.pending),
            tostring(admitStats.duplicate),
            tostring(admitStats.rejected),
            tostring(admitStats.deferred and true or false),
            tostring(#(snapshot.rows or {})))
        return
    end

    self:ProcessLegacySnapshot(ctx, snapshot, reason)
end

--- Reconcile a legacy profile bank snapshot (pre-activation production writer).
function BankLog:ProcessLegacySnapshot(ctx, snapshot, reason)
    if type(ctx) ~= "table" or ctx.source ~= "legacyProfile" or type(snapshot) ~= "table" then
        return
    end
    local C = SF.Consumables
    -- Prefer a caller-built legacy view; otherwise stamp eligibility onto the
    -- dedicated legacy snapshot (never mutate a shared GS sample table in place).
    if snapshot.eligibility == nil and C and C.EligibilitySnapshot and ctx.profile then
        snapshot.eligibility = C.EligibilitySnapshot(ctx.profile)
    end

    local db = self:ObservationDB()
    local O = SF.ConsumablesObservation
    if not db or not O then return end
    local store = O.EnsureProfileStore(db, ctx.profileId)
    if not store then return end

    local stats = O.ReconcileSnapshot(store, ctx.profileId, snapshot)
    -- Preserve sampleOnly lastStats when this is a companion pass.
    if not (self.lastStats and self.lastStats.sampleOnly) then
        self.lastStats = stats
    else
        self.lastLegacyStats = stats
    end
    Debug("Info",
        "reconcile reason=%s created=%s updated=%s ambiguous=%s suppressed=%s rows=%s",
        tostring(reason or "update"),
        tostring(stats.created),
        tostring(stats.updated),
        tostring(stats.ambiguous),
        tostring(stats.suppressed),
        tostring(#snapshot.rows))

    if C and C.NoteObservationBaseline and ctx.profile then
        C.NoteObservationBaseline(ctx.profile)
    end

    local V = SF.ConsumablesVerification
    local scope = O.EnsureScope(store, ctx.guildGuid, ctx.bankTab)
    local Sync = SF.LootHelperSync
    local sessionActive = Sync and Sync.state and Sync.state.active
        and Sync.state.profileId == ctx.profileId
    if V and V.ProcessLocalAfterReconcile and scope and ctx.profile then
        local historyReady = true
        local historyBaselineAt = nil
        if sessionActive and Sync._ConsumablesHistoryReady then
            historyReady = Sync:_ConsumablesHistoryReady(ctx.profile) ~= false
            historyBaselineAt = tonumber(ctx.profile._consumablesHistoryBaselineAt)
        end
        local verifyStats = V.ProcessLocalAfterReconcile(ctx.profile, ctx.profileId, store, scope, {
            selfId = ctx.observedBy,
            -- During a live session the coordinator owns verification/txn minting.
            deferToCoordinator = sessionActive and true or false,
            historyComplete = historyReady,
            historyBaselineAt = historyBaselineAt,
        })
        self.lastVerifyStats = verifyStats
        if verifyStats and (verifyStats.trusted or 0) > 0 then
            Debug("Info", "local admin trust committed=%s", tostring(verifyStats.trusted))
            if Sync and Sync._FlushUnsentConsumablesEvents then
                Sync:_FlushUnsentConsumablesEvents(ctx.profile)
            end
        end
    end
    -- Non-admin (and deferred admin) observations must reach the coordinator while
    -- a session is active; do not wait for a local trust commit.
    if sessionActive and Sync and Sync._FlushPendingConsumableObservations and ctx.profile then
        Sync:_FlushPendingConsumableObservations(ctx.profile)
    end
end

function BankLog:BeginObservation(reason)
    local ctx = self:EligibleContext()
    if not ctx then
        self.active = false
        self.activeContext = nil
        self:CancelTimers(reason or "ineligible")
        return false
    end
    local prev = self.activeContext
    local changed = not self.active
        or not prev
        or prev.profileId ~= ctx.profileId
        or prev.guildGuid ~= ctx.guildGuid
        or prev.bankTab ~= ctx.bankTab
        or tonumber(prev.generation) ~= tonumber(ctx.generation)
    self.active = true
    self.activeContext = ctx
    if changed then
        self.queryRetries = 0
        self:RequestLog(reason or "start")
    end
    return true
end

function BankLog:OnBankOpened()
    self.bankOpen = true
    if not self:BeginObservation("open") then
        Debug("Info", "bank open: observation idle (no eligible profile/config)")
        return
    end
    Debug("Info", "bank open: start observation profile=%s tab=%s",
        tostring(self.activeContext.profileId), tostring(self.activeContext.bankTab))
end

--- Re-evaluate a snapshot that completed before demand-driven roster readiness.
-- Event-driven only (GUILD_ROSTER_UPDATE); never polls. Revalidates live
-- guild/tab/dataset/campaign before admission.
function BankLog:TryAdmitPendingSnapshot()
    local pending = self.pendingAdmit
    if type(pending) ~= "table" or type(pending.ctx) ~= "table" or type(pending.snapshot) ~= "table" then
        return false
    end
    if not self.bankOpen or not self.active then
        ClearPendingAdmit(self)
        return false
    end
    local live = self:EligibleContext()
    if not live or live.source ~= "guildSupplies" or live.sampleOnly then
        ClearPendingAdmit(self)
        return false
    end
    if not QueryContextMatchesLive(pending.ctx, live) then
        ClearPendingAdmit(self)
        Debug("Info", "pending admit discarded: live context no longer matches snapshot")
        return false
    end
    local admitStats = self:AdmitGuildSuppliesSnapshot(live, pending.snapshot)
    self.lastStats = admitStats
    if admitStats and admitStats.deferred then
        -- Still not ready; keep the same snapshot for a later roster event.
        return false
    end
    ClearPendingAdmit(self)
    Debug("Info",
        "guild supplies deferred admit recovered accepted=%s pending=%s duplicate=%s rejected=%s",
        tostring(admitStats and admitStats.admitted),
        tostring(admitStats and admitStats.pending),
        tostring(admitStats and admitStats.duplicate),
        tostring(admitStats and admitStats.rejected))
    return true
end

function BankLog:EnsureRosterAdmitListener()
    if self.rosterAdmitFrame or type(CreateFrame) ~= "function" then
        return
    end
    if type(self.pendingAdmit) ~= "table" then
        return
    end
    local frame = CreateFrame("Frame")
    self.rosterAdmitFrame = frame
    TryRegister(frame, "GUILD_ROSTER_UPDATE")
    TryRegister(frame, "PLAYER_GUILD_UPDATE")
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_GUILD_UPDATE" then
            -- Guild identity may have changed; drop deferred evidence.
            ClearPendingAdmit(self)
            self:ReleaseRosterAdmitListener()
            return
        end
        if type(self.pendingAdmit) ~= "table" then
            self:ReleaseRosterAdmitListener()
            return
        end
        -- Defer past other GUILD_ROSTER_UPDATE handlers (Guild Gossip demand bind)
        -- so GetCurrentContext can observe the settled roster. Bounded: one
        -- After(0) per event generation; still-deferred snapshots wait for the
        -- next roster event (no polling).
        self.rosterAdmitGen = (tonumber(self.rosterAdmitGen) or 0) + 1
        local gen = self.rosterAdmitGen
        local function evaluate()
            if (tonumber(self.rosterAdmitGen) or 0) ~= gen then
                return
            end
            if type(self.pendingAdmit) ~= "table" then
                self:ReleaseRosterAdmitListener()
                return
            end
            self:TryAdmitPendingSnapshot()
            if type(self.pendingAdmit) ~= "table" then
                self:ReleaseRosterAdmitListener()
            end
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(0, evaluate)
        else
            evaluate()
        end
    end)
end

function BankLog:ReleaseRosterAdmitListener()
    local frame = self.rosterAdmitFrame
    if not frame then
        return
    end
    if frame.UnregisterAllEvents then
        frame:UnregisterAllEvents()
    end
    if frame.SetScript then
        frame:SetScript("OnEvent", nil)
    end
    self.rosterAdmitFrame = nil
end

function BankLog:OnBankClosed()
    self.bankOpen = false
    self.active = false
    self.activeContext = nil
    ClearPendingAdmit(self)
    ClearPendingQuery(self)
    ClearFreshnessGate(self)
    self:ReleaseRosterAdmitListener()
    ClearFreshLogStamp(self)
    self:CancelTimers("bank_closed")
    Debug("Info", "bank closed: observation idle")
end

function BankLog:OnProfileMaybeChanged()
    if not self.bankOpen then return end
    if not self:BeginObservation("profile_ready") then
        if self.active then
            self.active = false
            self.activeContext = nil
            self:CancelTimers("profile_ineligible")
        end
        Debug("Info", "profile change: stop observation while bank open")
        return
    end
    Debug("Info", "profile/config eligible while bank open; observation armed")
end

function BankLog:OnEvent(event, arg1)
    if event == "GUILDBANKFRAME_OPENED" then
        self:OnBankOpened()
    elseif event == "GUILDBANKFRAME_CLOSED" then
        self:OnBankClosed()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if Enum and Enum.PlayerInteractionType and arg1 == Enum.PlayerInteractionType.GuildBanker then
            self:OnBankOpened()
        end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if Enum and Enum.PlayerInteractionType and arg1 == Enum.PlayerInteractionType.GuildBanker then
            self:OnBankClosed()
        end
    elseif event == "GUILDBANKLOG_UPDATE" then
        if self.active then
            self:ProcessLogUpdate("event")
        end
    elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
        -- Retail GuildBankTab_OnClick selects a tab via SetCurrentGuildBankTab
        -- then QueryGuildBankTab; the response fires GUILDBANKBAGSLOTS_CHANGED.
        -- There is no dedicated Guild Bank tab-selection event. Re-evaluate the
        -- eligible observation context so a deliberate switch onto the Guild
        -- Supplies tab can retarget sampling. Overlapping uncorrelated queries
        -- still fail closed and require a clean bank reopen.
        if not self.bankOpen then
            return
        end
        local prev = self.activeContext
        if not self:BeginObservation("tab_selected") then
            return
        end
        -- BeginObservation RequestLogs only when identity changes (non-throttled
        -- "tab_selected"). Same-tab slot churn still needs the throttled path.
        local cur = self.activeContext
        local sameIdentity = type(prev) == "table" and type(cur) == "table"
            and prev.profileId == cur.profileId
            and prev.guildGuid == cur.guildGuid
            and prev.bankTab == cur.bankTab
            and tonumber(prev.generation) == tonumber(cur.generation)
        if sameIdentity then
            self:RequestLog("slots_changed")
        end
    end
end

function BankLog:Init()
    if self.frame then return end
    self.active = false
    self.bankOpen = false
    self.queryToken = 0
    self.queryRetries = 0
    local frame = CreateFrame("Frame")
    self.frame = frame
    frame:SetScript("OnEvent", function(_, event, ...)
        self:OnEvent(event, ...)
    end)
    TryRegister(frame, "GUILDBANKFRAME_OPENED")
    TryRegister(frame, "GUILDBANKFRAME_CLOSED")
    TryRegister(frame, "GUILDBANKLOG_UPDATE")
    TryRegister(frame, "GUILDBANKBAGSLOTS_CHANGED")
    TryRegister(frame, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    TryRegister(frame, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE")

    if SF.Consumables and SF.Consumables.RegisterUIListener then
        SF.Consumables.RegisterUIListener(function()
            self:OnProfileMaybeChanged()
        end)
    end

    Debug("Info", "Raid Consumables bank-log observer initialized")
end
