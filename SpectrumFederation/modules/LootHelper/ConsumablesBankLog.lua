-- Guild Bank transaction-log observer host for Raid Consumables (Issue #366 PR1).
-- Captures local observations only; does not write canonical donation events.
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

function BankLog:EligibleContext()
    local C = SF.Consumables
    local O = SF.ConsumablesObservation
    if not C or not O then return nil end
    local profile = self:AccountingProfile()
    if type(profile) ~= "table" then return nil end
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

function BankLog:CancelTimers(reason)
    self.queryToken = (self.queryToken or 0) + 1
    self.queryRetries = 0
    self.awaitingLogUpdate = false
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
    -- or a recent query just completed successfully.
    if reason == "slots_changed" then
        if self.awaitingLogUpdate then return end
        if self.lastQueryAt and (now - self.lastQueryAt) < SLOTS_THROTTLE_SECONDS then
            return
        end
    end
    if reason ~= "retry" then
        self.queryRetries = 0
    end
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
    self.awaitingLogUpdate = false
    self.queryRetries = 0
    -- Successful update cancels outstanding retry callbacks.
    self.queryToken = (self.queryToken or 0) + 1

    local snapshot = self:ReadSnapshot(ctx)
    if not snapshot then
        Debug("Warn", "log update skipped: incomplete snapshot reason=%s", tostring(reason))
        return
    end
    local C = SF.Consumables
    if C and C.EligibilitySnapshot then
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

    if C and C.NoteObservationBaseline then
        C.NoteObservationBaseline(ctx.profile)
    end

    local V = SF.ConsumablesVerification
    local scope = O.EnsureScope(store, ctx.guildGuid, ctx.bankTab)
    local Sync = SF.LootHelperSync
    local sessionActive = Sync and Sync.state and Sync.state.active
        and Sync.state.profileId == ctx.profileId
    if V and V.ProcessLocalAfterReconcile and scope then
        local verifyStats = V.ProcessLocalAfterReconcile(ctx.profile, ctx.profileId, store, scope, {
            selfId = ctx.observedBy,
            -- During a live session the coordinator owns verification/txn minting.
            deferToCoordinator = sessionActive and true or false,
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
    if sessionActive and Sync and Sync._FlushPendingConsumableObservations then
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
