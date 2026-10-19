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
    local requestedSet = O.RequestedSetFromConfig(cfg)
    local hasRequested = false
    for _ in pairs(requestedSet) do
        hasRequested = true
        break
    end
    if not hasRequested then return nil end
    local sampleOnly = opts.sampleOnly == true
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

function BankLog:EligibleContext()
    local gsCtx = self:GuildSuppliesEligibleContext()
    if gsCtx then
        return gsCtx
    end
    local sampleCtx = self:GuildSuppliesSampleOnlyContext()
    if sampleCtx then
        return sampleCtx
    end
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
        Debug("Warn", "guild supplies admit skipped: local actor not ready")
        return stats
    end
    local member = {
        guid = ctxAuth.actorGuid,
        name = ctxAuth.actorName or self:ObserverId(),
        guildKey = ctxAuth.guildKey,
        rankOrder = ctxAuth.rankOrder,
    }
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
    return stats
end

local function ClearFreshLogStamp(self)
    self.lastFreshLogAt = nil
    self.lastFreshLogTab = nil
    self.lastFreshLogGuild = nil
end

function BankLog:CancelTimers(reason)
    self.queryToken = (self.queryToken or 0) + 1
    self.queryRetries = 0
    self.awaitingLogUpdate = false
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
    local ctx = self:EligibleContext()
    if not ctx or not ctx.profileId then
        Debug("Info", "log update ignored: no eligible consumables context")
        return
    end
    self.activeContext = ctx
    self.queryRetries = 0
    -- Cancel outstanding retry callbacks for this update attempt.
    self.queryToken = (self.queryToken or 0) + 1

    local snapshot = self:ReadSnapshot(ctx)
    if not snapshot then
        -- Failed refresh must not keep awaiting=false with an older successful stamp.
        self.awaitingLogUpdate = false
        ClearFreshLogStamp(self)
        Debug("Warn", "log update skipped: incomplete snapshot reason=%s", tostring(reason))
        return
    end
    self.awaitingLogUpdate = false
    -- Freshness stamp for read-only bank-context adapters (Guild Supplies #386).
    -- Restored only after a complete successful update.
    self.lastFreshLogAt = WallNow()
    self.lastFreshLogTab = ctx.bankTab
    self.lastFreshLogGuild = ctx.guildGuid

    -- Guild Supplies paths: no Loot Helper profile / raid session required.
    if ctx.source == "guildSupplies" then
        self.lastVerifyStats = nil
        if ctx.sampleOnly then
            -- Staged preparation: freshness stamp only; never admit donations.
            self.lastStats = {
                admitted = 0, pending = 0, rejected = 0, duplicate = 0, sampleOnly = true,
            }
            Debug("Info",
                "guild supplies sample-only stamp reason=%s tab=%s rows=%s",
                tostring(reason or "update"),
                tostring(ctx.bankTab),
                tostring(#(snapshot.rows or {})))
            return
        end
        snapshot.eligibility = ctx.eligibility
        local admitStats = self:AdmitGuildSuppliesSnapshot(ctx, snapshot)
        self.lastStats = admitStats
        Debug("Info",
            "guild supplies bank admit reason=%s accepted=%s pending=%s duplicate=%s rejected=%s rows=%s",
            tostring(reason or "update"),
            tostring(admitStats.admitted),
            tostring(admitStats.pending),
            tostring(admitStats.duplicate),
            tostring(admitStats.rejected),
            tostring(#(snapshot.rows or {})))
        return
    end

    local C = SF.Consumables
    if C and C.EligibilitySnapshot and ctx.profile then
        snapshot.eligibility = C.EligibilitySnapshot(ctx.profile)
    end

    local db = self:ObservationDB()
    local O = SF.ConsumablesObservation
    if not db or not O then return end
    local store = O.EnsureProfileStore(db, ctx.profileId)
    if not store then return end

    local stats = O.ReconcileSnapshot(store, ctx.profileId, snapshot)
    self.lastStats = stats
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

function BankLog:OnBankClosed()
    self.bankOpen = false
    self.active = false
    self.activeContext = nil
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
        if self.active then
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
