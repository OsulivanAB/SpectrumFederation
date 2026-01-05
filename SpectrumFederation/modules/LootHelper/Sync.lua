-- Grab the namespace
local addonName, SF = ...

SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

-- ============================================================================
-- Constants / Message Types
-- ============================================================================

Sync.PROTO_VERSION = 1

Sync.PREFIX = {
    CONTROL = "SF_LH",
    BULK = "SF_LHB"
}

Sync.MSG = {
    -- Admn convergence (Sequence 1)
    ADMIN_SYNC      = "ADMIN_SYNC",
    ADMIN_STATUS    = "ADMIN_STATUS",
    LOG_REQ         = "LOG_REQ",
    AUTH_LOGS       = "AUTH_LOGS",

    -- Session lifecycle (Sequence 2)
    SES_START       = "SES_START",
    SES_REANNOUNCE  = "SES_REANNOUNCE",
    SES_HEARTBEAT   = "SES_HEARTBEAT",
    SES_END         = "SES_END",
    HAVE_PROFILE    = "HAVE_PROFILE",
    NEED_PROFILE    = "NEED_PROFILE",
    NEED_LOGS       = "NEED_LOGS",
    PROFILE_SNAPSHOT= "PROFILE_SNAPSHOT",

    -- Live Updates (Sequence 3)
    NEW_LOG         = "NEW_LOG",

    -- Coordinator handoff (Sequence 4)
    COORD_TAKEOVER  = "COORD_TAKEOVER",
}

-- ============================================================================
-- Runtime State (kept in-memory; persist only what you truly need)
-- ============================================================================

Sync.cfg = Sync.cfg or {
    adminReplyJitterMsMin = 0,
    adminReplyJitterMsMax = 500,

    adminConvergenceCollectSec  = 1.5,  -- how long coordinator waits for ADMIN_STATUS
    adminLogSyncTimeoutSec      = 4.0,  -- how long coordinator waits for AUTH_LOGS

    memberReplyJitterMsMin = 0,
    memberReplyJitterMsMax = 500,

    requestTimeoutSec = 5,
    maxRetries = 2,

    handshakeCollectSec = 3,  -- how long coordinator waits for HAVE/NEED replies

    maxHelpers = 2,
    preferNoGaps = true, -- prefer helpers without log gaps when choosing helpers

    -- Request robustness
    maxOutstandingRequests  = 64,   -- hard cap to avoid unbounded memory
    requestBackoffMult      = 1.5,  -- exponential backoff multiplier
    requestRetryJitterMsMin = 100, 
    requestRetryJitterMsMax = 300,  -- TODO: Verify how this works. Admin jitter reply max is 500, so retry may happen before admin replies.

    -- Backpressure for log bursts (coordinator -> member)
    maxMissingRangesPerNeededLogs   = 8,    -- clamp abusive/huge requests
    needLogsSendSpacingMs           = 50,   -- space out AUTH_LOGS sends to avoid spikes

    gapRepairCooldownSec = 2,

    -- Heartbeat
    heartbeatIntervalSec            = 30,   -- how often to send heartbeat, in seconds
    heartbeatMissThreshold          = 3,    -- how many consecutive misses before takeover logic triggers
    heartbeatGraceSec               = 10,   -- small extra buffer to reduce false positives
    catchupOnHeartbeatCooldownSec   = 10,   -- avoid re-running catchup logic every single heartbeat if it gets noisy
}

Sync.state = Sync.state or {
    active = false,

    sessionId   = nil,  -- raid session identifier
    profileId   = nil,  -- stable stored profile id
    coordinator = nil,  -- "Name-Realm"
    coordEpoch  = nil,  -- monotonic coordinator generation/epoch

    helpers     = {},   -- array of "Name-Realm"
    authorMax   = {},   -- map: [author] = maxCounterSeen

    isCoordinator = false,

    -- Admin convergence bookkeeping
    adminStatuses = {}, -- map: [sender] = status table

    -- Outstanding requests by requestId
    requests = {},      -- map: [requestId] = requestState

    peers = {},         -- map: [nameRealm] = peerRecord
                        -- peerRecord example
                        -- {
                        --   name = "Name-Realm",
                        --   inGroup = true/false,     -- roster truth
                        --   online = true/false/nil,  -- roster truth (raid only)
                        --   lastSeen = epochSeconds,  -- comm truth
                        --   proto = 1,                -- last proto observed
                        --   supportedMin = 1,
                        --   supportedMax = 1,
                        --   addonVersion = "0.2.0-beta.3",
                        --   isAdmin = true/false/nil, -- verified admin for current session profile if we can verify
                        -- }
    heartbeat = {
        lastHeartbeatAt         = nil,  -- when we last heard a heartbeat from the coordinator
        lastCoordMessageAt      = nil,  -- last time we heard any message from the coordinator
        missedHeartbeats        = 0,    -- counter
        heartbeatTimerHandle    = nil,  -- So it can be stopped cleanly
        takeoverAttemptedAt     = nil,
        lastHeartbeatSentAt     = nil,
    }
}

-- Session Heartbeat contract:
-- {
--     sessionId   = "string",        -- current session id
--     profileId   = "string",        -- current session profile id
--     coordinator = "Name-Realm", -- current coordinator
--     coordEpoch  = number,        -- current coordinator epoch
--     helpers     = { "Name-Realm", ... }, -- current helpers list
--     authorMax   = { [author] = number, ... }, -- current author max counters
--     sentAt      = number,            -- epoch seconds when sent
-- }

Sync._nonceCounter = Sync._nonceCounter or 0

-- ============================================================================
-- Helper Functions (Local)
-- ============================================================================

-- Function Return a current epoch time in seconds.
-- @param none
-- @return number epochSeconds
local function Now()
    if SF.Now then
        return SF:Now()
    end
    return (GetServerTime and GetServerTime()) or time()
end

-- Function Return a unique identifier for the current player ("Name-Realm").
-- @param none
-- @return string playerId
local function SelfId()
    if SF.NameUtil and SF.NameUtil.GetSelfId then
        return SF.NameUtil.GetSelfId()
    end
    -- Fallback
    if SF.GetPlayerFullIdentifier then
        local ok, id = pcall(function() return SF:GetPlayerFullIdentifier() end)
        if ok and id then return id end
    end
    local name, realm = UnitFullName("player")
    realm = realm or GetRealmName()
    if realm then realm = realm:gsub("%s+", "") end
    return name and realm and (name .. "-" .. realm) or (name or "unknown")
end

-- Function Normalize a "Name" or "Name-Realm" into "Name-Realm" format.
-- @param name string Player name or "Name-Realm"
-- @return string|nil Normalized "Name-Realm" or nil if invalid
local function NormalizeNameRealm(name)
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(name)
    end
    -- Fallback
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then
        local n, r = strsplit("-", name, 2)
        if r then r = r:gsub("%s+", "") end
        return n and r and (n .. "-" .. r) or name
    end
    local realm = GetRealmName()
    if realm then realm = realm:gsub("%s+", "") end
    return realm and (name .. "-" .. realm) or name
end

-- Function Get current group distribution channel ("RAID", "PARTY", or nil).
-- @param none
-- @return string|nil distribution
local function GetGroupDistribution()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- ============================================================================
-- Public API (called by LootHelper core / UI / events)
-- ============================================================================

-- Function Initialize sync system (state + transport + event wiring).
-- @param cfg table|nil Optional config overrides (jitter/timeouts/retries).
-- @return nil
function Sync:Init(cfg)
end

-- Function Enable syncing behavior (safe to call multiple times).
-- @param none
-- @return nil
function Sync:Enable()
end

-- Function Disable syncing behavior; does not delete local data.
-- @param none
-- @return nil
function Sync:Disable()
end

-- Function Update runtime config (jitter, timeouts, retry counts).
-- @param cfg table Config fields to override.
-- @return nil
function Sync:SetConfig(cfg)
end

-- Function Return current runtime config.
-- @param none
-- @return table Current config.
function Sync:GetConfig()
end

-- Function Returns whether an SF Loot Helper session is currently active.
-- @param none
-- @return boolean True if active, false otherwise.
function Sync:IsSessionActive()
end

-- Function Returns current sessionId (or nil).
-- @param none
-- @return string|nil Current sessionId.
function Sync:GetSessionId()
end

-- Function Returns active session profileId (or nil).
-- @param none
-- @return string|nil Current session profileId.
function Sync:GetSessionProfileId()
end

-- Function Returns current coordinator "Name-Realm" (or nil).
-- @param none
-- @return string|nil Current coordinator.
function Sync:GetCoordinator()
end

-- Function Returns current coordinator epoch (or nil).
-- @param none
-- @return number|nil Current coordinator epoch.
function Sync:GetCoordEpoch()
end

-- Function Returns helpers list (array of "Name-Realm").
-- @param none
-- @return table Helpers list.
function Sync:GetHelpers()
end

-- Function Called when group/raid roster changes. If someone joins and a session is already started, send them the info the equivalent of SES_REANNOUNCE
-- @param none
-- @return nil
function Sync:OnGroupRosterUpdate()
    -- Always keep per roster fresh
    self:UpdatePeersFromRoster()

    -- Only the coordinator does late-join announcements
    if not(self.state and self.state.active and self.state.isCoordinator) then return end
    if not SF.LootHelperComm then return end

    -- Don't do anything until we've actually announced the session at least once
    if self.state._sessionAnnounced ~= self.state.sessionId then
        return
    end

    local sid = self.state.sessionId
    local profileId = self.state.profileId
    if type(sid) ~= "string" or sid == "" then return end
    if type(profileId) ~= "string" or profileId == "" then return end

    local me = SelfId()

    -- Build a single payload to reuse
    self.state.authorMax = self:ComputeAuthorMax(profileId) or (self.state.authorMax or {})
    local payload = {
        sessionId   = sid,
        profileId   = profileId,
        coordinator = self.state.coordinator,
        coordEpoch  = self.state.coordEpoch,
        authorMax   = self.state.authorMax,
        helpers     = self.state.helpers or {},
    }

    -- Find targets who are in-group but haven't been announced to for this sessionId
    local targets = {}
    for name, peer in pairs(self.state.peers or {}) do
        if peer and peer.inGroup and name ~= me then
            if peer._lastSessionAnnounced ~= sid then
                if peer.online ~= false then
                    table.insert(targets, name)
                end
            end
        end
    end

    if #targets == 0 then return end
    table.sort(targets)

    -- Send with small jitter to avoid a burst if multiple join at once
    for _, target in ipairs(targets) do
        local dest = target -- capture safely per iteration
        self:RunWithJitter(0, 250, function()
            -- Ensure still the same session and we are still coordinator
            if not (self.state.active and self.state.isCoordinator) then return end
            if self.state.sessionId ~= sid then return end
            if not SF.LootHelperComm then return end

            local okSend = SF.LootHelperComm:Send(
                "CONTROL",
                self.MSG.SES_REANNOUNCE,
                payload,
                "WHISPER",
                dest,
                "ALERT"
            )

            local peer = self:GetPeer(dest)
            if peer then
                peer._lastSessionAnnounced = sid
            end

            if SF.Debug then
                SF.Debug:Info("SYNC", "Late joiner announce: SES_REANNOUNCE -> %s (ok=%s)", tostring(target), tostring(okSend))
            end
        end)
    end

    -- Keep heartbeat sender correct based on current roster/distribution/coordinator status
    self:EnsureHeartbeatSender("OnGroupRosterUpdate")
end

-- Function Start a new SF Loot Helper session as coordinator (Sequence 1 -> 2).
-- @param profileId string Stable profile id to use for this session
-- @param opts table|nil Optional: forceStart, skipPrompt, customHelpers, ect.
-- @return string sessionId
function Sync:StartSession(profileId, opts)
    opts = opts or {}
    local dist = GetGroupDistribution()
    if not dist then
        if SF.PrintError then SF:PrintError("Cannot start session: not in a group/raid.") end
        return nil
    end

    local ok, why = self:CanSelfCoordinate(profileId)
    if not ok then
        if SF.PrintError then SF:PrintError("Cannot start session: %s", tostring(why or "unknown reason")) end
        return nil
    end

    local me = SelfId()
    local sessionId = self:_NextNonce("SES")
    local epoch = Now()

    -- Reset state
    self.state.adminStatuses = {}
    self.state._adminConvergence = nil
    self.state.handshake = nil
    self.state.helpers = {}

    self.state.active = true
    self.state.sessionId = sessionId
    self.state.profileId = profileId
    self.state.coordinator = me
    self.state.coordEpoch = epoch
    self.state.isCoordinator = true

    self:UpdatePeersFromRoster()
    self:TouchPeer(me, { inGroup = true, isAdmin = true })

    self:BeginAdminConvergence(sessionId, profileId)

    return sessionId
end

-- Function Reset all session state (called on EndSession and internal resets).
-- @param reason string|nil Human-readable reason for reset.
-- @return nil
function Sync:_ResetSessionState(reason)
    -- Cancel outstanding request timers and clear requests
    if type(self.state.requests) == "table" then
        for _, req in pairs(self.state.requests) do
            self:_CancelRequestTimer(req)
        end
    end

    self.state.requests = {}

    -- Clear convergence + handshake bookkeeping
    self.state._adminConvergence = nil
    self.state.adminStatuses = {}
    self.state.handshake = nil

    -- Clear session identity
    self.state.active = false
    self.state.sessionId = nil
    self.state.profileId = nil
    self.state.coordinator = nil
    self.state.coordEpoch = nil
    self.state.isCoordinator = false

    -- Clear session metadata
    self.state.helpers = {}
    self.state.authorMax = {}

    -- Clear dedupe/flags
    self.state._sentJoinStatusForSessionId = nil
    self.state._profileReqInFlight = nil
    self.state._sessionAnnounced = nil

    -- Clear gap repair cooldowns
    self.state.gapRepair = nil

    -- Clear per-peer "announced" marker + joinStatus (keeps peers table but removes stale session info)
    for _, peer in pairs(self.state.peers or {}) do
        peer.joinStatus = nil
        peer.joinReportedAt = nil
        peer._lastSessionAnnounced = nil
    end

    -- Clear heartbeat state and stop any heartbeat timer/ticker
    do
        local hb = self.state.heartbeat
        if type(hb) == "table" then
            if hb.heartbeatTimerHandle and hb.heartbeatTimerHandle.Cancel then
                pcall(function() hb.heartbeatTimerHandle:Cancel() end)
            end
            hb.heartbeatTimerHandle = nil
            hb.lastHeartbeatAt = nil
            hb.lastCoordMessageAt = nil
            hb.missedHeartbeats = 0
            hb.takeoverAttemptedAt = nil
            hb.lastCatchupAt = nil
        end
    end

    if SF.Debug then
        SF.Debug:Info("SYNC", "Session state reset (reason: %s)", tostring(reason or "unknown"))
    end
end

-- Function End the active session (optional broadcast).
-- @param reason string|nil Human-readable reason ("raid ended", "manual", etc.)
-- @param broadcast boolean|nil True to broadcast session end, false to skip broadcast
-- @return nil
function Sync:EndSession(reason, broadcast)
    reason = reason or "ended"
    if not self.state.active then return false end

    -- Default behavior:
    -- - Coordinator broadcasts unless explicitly disabled
    -- - Non-coordinator just clears local state
    if broadcast == nil then
        broadcast = self.state.isCoordinator == true
    end

    local dist = GetGroupDistribution()

    if broadcast and self.state.isCoordinator and dist and SF.LootHelperComm then
        local payload = {
            sessionId   = self.state.sessionId,
            profileId   = self.state.profileId,
            coordinator = self.state.coordinator,
            coordEpoch  = self.state.coordEpoch,
            reason      = reason,
            endAt       = Now(),
        }

        SF.LootHelperComm:Send("CONTROL", self.MSG.SES_END, payload, dist, nil, "ALERT")
    end

    -- Always end locally
    self:_ResetSessionState("local_end" .. tostring(reason))

    if SF.PrintInfo then
        SF:PrintInfo("Loot Helper session ended (%s).", tostring(reason))
    end

    return true
end

-- Function Take over an existing session after raid leader changes (Sequence 4).
-- @param sessionId string Current session id to take over.
-- @param profileId string Session profile id.
-- @param reason string|nil Why takeover happened (Raid leader change, old coord offline, ect.)
-- @param opts table|nil Options: { rerunAdminConvergence = true/false }
-- @return nil
function Sync:TakeoverSession(sessionId, profileId, reason, opts)
    opts = opts or {}

    local ok, why = self:CanSelfCoordinate(profileId)
    if not ok then
        if SF.PrintError then SF:PrintError("Cannot takeover session: %s", tostring(why or "unknown reason")) end
        return false
    end

    local dist = GetGroupDistribution()
    if not dist then return false end
    if type(sessionId) ~= "string" or sessionId == "" then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end

    -- Clear convergence state so we don't inherit stale admin statuses / pending convergence
    self.state.adminStatuses = {}
    self.state._adminConvergence = nil
    self.state.handshake = nil
    self.state._sessionAnnounced = nil

    local me = SelfId()
    local oldEpoch = tonumber(self.state.coordEpoch) or 0

    self.state.active = true
    self.state.sessionId = sessionId
    self.state.profileId = profileId
    self.state.coordinator = me
    self.state.isCoordinator = true

    -- Ensure strictly increasing epoch
    local newEpoch = Now()
    if newEpoch <= oldEpoch then
        newEpoch = oldEpoch + 1
    end
    self.state.coordEpoch = newEpoch

    self:UpdatePeersFromRoster()
    self:TouchPeer(me, { inGroup = true, isAdmin = true })

    self:BroadcastCoordinatorTakeover()

    if not opts.rerunAdminConvergence then
        self:ReannounceSession()
        return true
    end

    -- Rerun admin convergence, but finish with SES_REANNOUNCE instead of SES_START
    self:BeginAdminConvergence(sessionId, profileId, {
        onComplete = function()
            self:ReannounceSession()
        end
    })

    return true
end

-- Function Re-announce session state to raid (typically after takeover or helper refresh).
-- @param none
-- @return nil
function Sync:ReannounceSession()
    if not self.state.active or not self.state.isCoordinator then return end

    local dist = GetGroupDistribution()
    if not dist then return end
    if not SF.LootHelperComm then return end

    local profileId = self.state.profileId
    self.state.authorMax = self:ComputeAuthorMax(profileId) or {}

    local payload = {
        sessionId   = self.state.sessionId,
        profileId   = profileId,
        coordinator = self.state.coordinator,
        coordEpoch  = self.state.coordEpoch,
        authorMax   = self.state.authorMax,
        helpers     = self.state.helpers or {},
    }

    -- restart handshake bookkeeping window
    self.state.handshake = {
        sessionId   = self.state.sessionId,
        startedAt   = Now(),
        deadlineAt  = Now() + (self.cfg.handshakeCollectSec or 3),
        replies     = {},
    }

    SF.LootHelperComm:Send("CONTROL", self.MSG.SES_REANNOUNCE, payload, dist, nil, "ALERT")

    -- Mark that we've announced this session at least once (used by OnGroupRosterUpdate)
    self.state._sessionAnnounced = self.state.sessionId
    self:_MarkRosterAnnounced(self.state.sessionId)

    -- Start/re-ensure coordinator heartbeat sender (ticker)
    self:EnsureHeartbeatSender("ReannounceSession")

    local sid = self.state.sessionId
    self:RunAfter(self.cfg.handshakeCollectSec or 3, function()
        if not self.state.active or not self.state.isCoordinator then return end
        if self.state.sessionId ~= sid then return end
        self:FinalizeHandshakeWindow()
    end)
end

-- ============================================================================
-- Coordinator responsibilities (Sequence 1 and 2)
-- ============================================================================

-- Function Begin admin convergence by whispering ADMIN_SYNC to online admins (Sequence 1).
-- @param sessionId string Current session id.
-- @param profileId string Current session profile id.
-- @return nil
function Sync:BeginAdminConvergence(sessionId, profileId, opts)
    opts = opts or {}
    if not self.state.active or not self.state.isCoordinator then return end

    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        -- If the leader somehow doesn't have the profile, call completion hook
        local completionHook = opts.onComplete or function() self:BroadcastSessionStart() end
        completionHook()
        return
    end

    local adminSyncId = self:_NextNonce("AS")
    local mode = (opts.onComplete and "REANNOUNCE") or "START"
    
    if SF.Debug then
        SF.Debug:Info("SYNC", "Beginning admin convergence (mode: %s, adminSyncId: %s)", mode, adminSyncId)
    end

    self.state._adminConvergence = {
        adminSyncId     = adminSyncId,
        startedAt       = Now(),
        deadlineAt      = Now() + (self.cfg.adminConvergenceCollectSec or 1.5),
        expected        = {}, -- [admin] = true
        pendingReq      = {}, -- [admin] = true
        pendingCount    = 0,
        finished        = false,
        onComplete      = opts.onComplete or function() self:BroadcastSessionStart() end,
    }

    -- Who do we ask?
    local admins = profile:GetAdminUsers() or {}
    local me = SelfId()

    for _, admin in ipairs(admins) do
        if admin ~= me then
            self.state._adminConvergence.expected[admin] = true
            if SF.LootHelperComm then
                SF.LootHelperComm:Send("CONTROL", self.MSG.ADMIN_SYNC, {
                    sessionId       = sessionId,
                    profileId       = profileId,
                    adminSyncId     = adminSyncId,
                }, "WHISPER", admin, "NORMAL")
            end
        end
    end

    -- After collection window, finalize no matter what
    local sid = sessionId
    self:RunAfter(self.cfg.adminConvergenceCollectSec or 1.5, function()
        if not self.state.active or not self.state.isCoordinator then return end
        if self.state.sessionId ~= sid then return end
        self:FinalizeAdminConvergence()
    end)
end

-- Function Finish admin convergence by calling the completion hook (BroadcastSessionStart or ReannounceSession).
-- Guards against double-finish and cleans up convergence state.
-- @param reason string|nil Reason for finishing (e.g., "complete", "timeout", "no_missing")
-- @return nil
function Sync:_FinishAdminConvergence(reason)
    local conv = self.state._adminConvergence
    if not conv then return end
    
    -- Guard against double-finish
    if conv.finished then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Admin convergence already finished, skipping duplicate finish")
        end
        return
    end
    
    conv.finished = true
    local onComplete = conv.onComplete
    
    -- Clean up convergence state
    self.state._adminConvergence = nil
    
    if SF.Debug then
        SF.Debug:Info("SYNC", "Finishing admin convergence (reason: %s)", tostring(reason or "unknown"))
    end
    
    -- Call completion hook (pcall for safety)
    if type(onComplete) == "function" then
        local ok, err = pcall(onComplete)
        if not ok then
            if SF.Debug then
                SF.Debug:Error("SYNC", "Error in admin convergence completion hook: %s", tostring(err))
            end
            -- Fallback to session start on error
            self:BroadcastSessionStart()
        end
    else
        -- Fallback if no valid completion hook
        self:BroadcastSessionStart()
    end
end

-- Function Finalize admin convergence after timeouts; compute helpers and broadcast SES_START.
-- @param none
-- @return nil
function Sync:FinalizeAdminConvergence()
    if not self.state.active or not self.state.coordinator then return end
    local conv = self.state._adminConvergence
    if not conv then
        return
    end

    local profileId = self.state.profileId
    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        self:_FinishAdminConvergence("no_profile")
        return
    end

    -- 1) compute local maxima
    local localMax = profile:ComputeAuthorMax() or {}

    -- 2) compute coordinator "have" as contiguous prefix
    local localContig = self:ComputeContigAuthorMax(profileId)

    -- 3) Compute targetMax = best-known maxima across local + admin statuses
    local targetMax = {}
    for author, maxCounter in pairs (localMax) do
        if type(author) == "string" and type(maxCounter) == "number" then
            targetMax[author] = maxCounter
        end
    end

    for _, st in pairs(self.state.adminStatuses or {}) do
        if type(st) == "table" and type(st.authorMax) == "table" then
            for author, maxcounter in pairs(st.authorMax) do
                if type(author) == "string" and type(maxCounter) == "number" then
                    local prev = tonumber(targetMax[author]) or 0
                    if maxCounter > prev then
                        targetMax[author] = maxCounter
                    end
                end
            end
        end
    end

    -- 4) compute missing ranges for the coordinator
    local missing = self:ComputeMissingLogRequests(localContig, targetMax)

    -- 5) send LOG_REQs to a reasonable provider
    conv.pendingReq = {}
    conv.pendingCount = 0

    for _, req in ipairs(missing) do
        local author = req.author
        local toCounter = req.toCounter

        -- Provider selection:
        -- Prefer the author themselves if they responded and claim to have up to that counter.
        local provider = nil
        local st = self.state.adminStatuses and self.state.adminStatuses[author]
        if st and st.authorMax and (st.authorMax[author] or 0) >= toCounter then
            provider = author
        else
            -- Otherwise, pick any admin who claims to have up to that counter.
            for adminName, st2 in pairs(self.state.adminStatuses or {}) do
                if st2 and st2.authorMax and (st2.authorMax[author] or 0) >= toCounter then
                    provider = adminName
                    break
                end
            end
        end

        if provider then
            local requestId = self:NewRequestId()
            conv.pendingReq[requestId] = true
            conv.pendingCount = conv.pendingCount + 1

            local mySupportsEnc =
                (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
                and SF.SyncProtocol.GetSupportedEncodings()
                or nil

            -- Build ordered provider list: selected provider first, then any other admin who can serve
            local providers, seen = {}, {}
            local function addProvider(p)
                if type(p) == "string" and p ~= "" and not seen[p] then
                    seen[p] = true
                    table.insert(providers, p)
                end
            end

            addProvider(provider)
            for adminName, st2 in pairs(self.state.adminStatuses or {}) do
                if st2 and st2.authorMax and (st2.authorMax[author] or 0) >= toCounter then
                    addProvider(adminName)
                end
            end

            local fallback = {}
            for i = 2, #providers do fallback[#fallback + 1] = providers[i] end

            -- Register Request will immediately send attempt #1 and retry across fallback targets
            local ok = self:RegisterRequest(requestId, "ADMIN_LOG_REQ", providers[1], {
                sessionId       = self.state.sessionId,
                profileId       = profileId,
                adminSyncId     = conv.adminSyncId,
                requestId       = requestId,
                author          = author,
                fromCounter     = req.fromCounter,
                toCounter       = req.toCounter,
                supportsEnc     = mySupportsEnc,
                targets         = fallback,
            })

            -- Clean up bookkeeping if RegisterRequest failed
            if not ok then
                conv.pendingReq[requestId] = nil
                conv.pendingCount = math.max(0, conv.pendingCount - 1)
            end
        end
    end

    -- 6) choose helpers list
    self.state.helpers = self:ChooseHelpers(self.state.adminStatuses or {})

    -- If no missing logs, finish convergence immediately
    if conv.pendingCount == 0 then
        self:_FinishAdminConvergence("no_missing")
        return
    end

    -- Otherwise, wait a bit for AUTH_LOGS, then proceed even if some time out
    local sid = self.state.sessionId
    self:RunAfter(self.cfg.adminLogSyncTimeoutSec or 4.0, function()
        if not self.state.active or not self.state.isCoordinator then return end
        if self.state.sessionId ~= sid then return end
        self:_FinishAdminConvergence("timeout")
    end)
end

-- Function Choose helpers list from known admin statuses (middle-ground "helpers list" approach).
-- @param adminStatuses table Map/array of admin status payloads
-- @return table helpers Array of "Name-Realm"
function Sync:ChooseHelpers(adminStatuses)
    adminStatuses = adminStatuses or {}
    local SP = SF.SyncProtocol
    local maxHelpers = tonumber(self.cfg.maxHelpers) or 2
    if maxHelpers < 0 then maxHelpers = 0 end

    -- Update roster info so peers[] has best-known inGroup/online for raid members
    self:UpdatePeersFromRoster()

    local me = SelfId()
    local candidates = {}

    for name, st in pairs(adminStatuses) do
        if name ~= me and type(st) == "table" and st.hasProfile then
            local peer = self:GetPeer(name) -- may exist from roster or be created
            local score = 0

            -- Prefer "clean" stores
            if self.cfg.preferNoGaps and st.hasGaps == false then
                score = score + 20
            end

            -- Prefer compression-capable helpers
            local supportsZ = false
            if type(st.supportsEnc) == "table" and SP and SP.ENC_B64CBORZ then
                for _, enc in ipairs(st.supportsEnc) do
                    if enc == SP.ENC_B64CBORZ then supportsZ = true break end
                end
            end
            if supportsZ then score = score + 10 end

            -- Prefer helpers we can "see" in roster as online/in-group
            if peer and peer.inGroup then
                score = score + 5
                if peer.online == true then
                    score = score + 50
                end
            end

            table.insert(candidates, { name = name, score = score })
        end
    end
    
    table.sort(candidates, function(a, b)
        if a.score == b.score then
            return a.name < b.name
        end
        return a.score > b.score
    end)

    local helpers = {}
    for i = 1, math.min(maxHelpers, #candidates) do
        table.insert(helpers, candidates[i].name)
    end

    return helpers
end

-- Function Broadcast session start to the raid (SES_START).
-- @param none
-- @return nil
function Sync:BroadcastSessionStart()
    if not self.state.active or not self.state.isCoordinator then return end

    local dist = GetGroupDistribution()
    if not dist then return end

    local profileId = self.state.profileId
    self.state.authorMax = self:ComputeAuthorMax(profileId) or {}

    local payload = {
        sessionId   = self.state.sessionId,
        profileId   = profileId,
        coordinator = self.state.coordinator,
        coordEpoch  = self.state.coordEpoch,
        authorMax   = self.state.authorMax,
        helpers     = self.state.helpers or {},
    }

    -- reset handshake bookkeeping
    self.state.handshake = {
        sessionId = self.state.sessionId,
        startedAt = Now(),
        deadlineAt = Now() + (self.cfg.handshakeCollectSec or 3),
        replies = {},   -- [sender] = "HAVE_PROFILE"|"NEED_PROFILE"|"NEED_LOGS"
    }

    if SF.LootHelperComm then
        SF.LootHelperComm:Send("CONTROL", self.MSG.SES_START, payload, dist, nil, "ALERT")
    end

    -- Mark that we've announced this session at least once (used by OnGroupRosterUpdate)
    self.state._sessionAnnounced = self.state.sessionId
    self:_MarkRosterAnnounced(self.state.sessionId)

    -- Start coordinator heartbeat sender (ticker)
    self:EnsureHeartbeatSender("BroadcastSessionStart")

    -- timeout window: after N seconds, summarize what we heard
    local sid = self.state.sessionId
    self:RunAfter(self.cfg.handshakeCollectSec or 3, function()
        -- Only finalize if session unchanged and we are still coordinator
        if not self.state.active or not self.state.isCoordinator then return end
        if self.state.sessionId ~= sid then return end
        self:FinalizeHandshakeWindow()
    end)
end

-- Function Broadcast a lightweight session heartbeat
-- Coordinator-only. Does NOT restart handshake bookkeeping
-- @param none
-- @return boolean ok True if sent, false otherwise
function Sync:BroadcastSessionHeartbeat()
    if not (self.state and self.state.active and self.state.isCoordinator) then return false end
    if not SF.LootHelperComm then return false end

    local dist = GetGroupDistribution()
    if not dist then return false end

    local sid = self.state.sessionId
    local profileId = self.state.profileId
    if type(sid) ~= "string" or sid == "" then return false end 
    if type(profileId) ~= "string" or profileId == "" then return false end

    -- Keep authorMax fresh so reconnecting clients can catch up.
    -- Note: If performance becomes an issue, we can later switch this to reuse self.state.authorMax and only recompute periodically
    self.state.authorMax = self:ComputeAuthorMax(profileId) or (self.state.authorMax or {})

    local payload = {
        sessionId   = sid,
        profileId   = profileId,
        coordinator = self.state.coordinator,
        coordEpoch  = self.state.coordEpoch,
        helpers     = self.state.helpers or {},
        authorMax   = self.state.authorMax or {},
        sentAt      = Now(),
    }

    SF.LootHelperComm:Send("CONTROL", self.MSG.SES_HEARTBEAT, payload, dist, nil, "NORMAL")
    return true
end

-- Function Determine whether heartbeat sender should run (coordinator + active session + in group).
-- @param none
-- @return boolean True if should run, false otherwise
function Sync:_ShouldRunHeartbeatSender()
    if not (self.state and self.state.active and self.state.isCoordinator) then return false end
    if not SF.LootHelperComm then return false end

    local sid = self.state.sessionId
    local pid = self.state.profileId
    if type(sid) ~= "string" or sid == "" then return false end
    if type(pid) ~= "string" or pid == "" then return false end

    -- Gate: don't heartbeat during admin convergence before the session is announced
    if self.state._sessionAnnounced ~= sid then return false end

    -- Must still be in PARTY/RAID
    if not GetGroupDistribution() then return false end

    return true
end

-- Function Determine whether heartbeat sender is currently running.
-- @param none
-- @return boolean True if running, false otherwise
function Sync:IsHeartbeatSenderRunning()
    local hb = self.state and self.state.heartbeat
    return (type(hb) == "table") and (hb.heartbeatTimerHandle ~= nil)
end

-- Function Start heartbeat sender (coordinator only).
-- @param none
-- @return nil
function Sync:StopHeartbeatSender(reason)
    local hb = self.state and self.state.heartbeat
    if type(hb) ~= "table" then return end

    local h = hb.heartbeatTimerHandle
    hb.heartbeatTimerHandle = nil

    if h and h.Cancel then
        pcall(function() h:Cancel() end)
    end

    if SF.Debug then
        SF.Debug:Info("SYNC", "Heartbeat sender stopped (reason: %s)", tostring(reason or "unknown"))
    end
end

-- Function Start heartbeat sender (coordinator only).
-- @param reason string|nil Reason for starting (for logging)
-- @return boolean True if started or already running, false otherwise
function Sync:StartHeartbeatSender(reason)
    if not self:_ShouldRunHeartbeatSender() then
        self:StopHeartbeatSender("start_denied:" .. tostring(reason or "unknown"))
        return false
    end

    if self:IsHeartbeatSenderRunning() then return true end

    self.state.heartbeat = self.state.heartbeat or {}
    local hb = self.state.heartbeat

    local interval = tonumber(self.cfg.heartbeatIntervalSec) or 30
    if interval < 5 then interval = 5 end

    -- Capture identity for this ticker instance
    local sid = self.state.sessionId
    local epoch = tonumber(self.state.coordEpoch) or 0

    local function tick()
        -- Stop quickly if anything important changed
        if not self:_ShouldRunHeartbeatSender() then
            self:StopHeartbeatSender("tick_conditions_failed")
            return
        end
        if self.state.sessionId ~= sid then
            self:StopHeartbeatSender("tick_session_changed")
            return
        end
        if (tonumber(self.state.coordEpoch) or 0) ~= epoch then
            self:StopHeartbeatSender("tick_epoch_changed")
            return
        end

        self:BroadcastSessionHeartbeat()
    end

    -- Send one immediately so reconnecting players catch up faster
    self:BroadcastSessionHeartbeat()

    if C_Timer and C_Timer.NewTicker then
        hb.heartbeatTimerHandle = C_Timer.NewTicker(interval, tick)
    else
        -- Fallback (rare): emulate ticker with recurring timers
        local cancelled = false
        local handle = {}
        function handle:Cancel() cancelled = true end
        hb.heartbeatTimerHandle = handle

        local function loop()
            if cancelled then return end
            tick()
            if cancelled then return end
            self:RunAfter(interval, loop)
        end

        self:RunAfter(interval, loop)
    end

    if SF.Debug then
        SF.Debug:Info("SYNC", "Heartbeat sender started (interval=%ss, reason=%s)", tostring(interval), tostring(reason or "unknown"))
    end

    return true
end

-- Function Ensure heartbeat sender is running or stopped as appropriate.
-- @param reason string|nil Reason for starting/stopping (for logging)
-- @return boolean True if running, false otherwise
function Sync:EnsureHeartbeatSender(reason)
    if self:_ShouldRunHeartbeatSender() then
        return self:StartHeartbeatSender(reason)
    end
    self:StopHeartbeatSender(reason)
    return false
end

-- Function Broadcast coordinator takeover message (COORD_TAKEOVER).
-- @param none
-- @return nil
function Sync:BroadcastCoordinatorTakeover()
    if not self.state.active or not self.state.isCoordinator then return end

    local dist = GetGroupDistribution()
    if not dist then return end

    if not SF.LootHelperComm then return end

    SF.LootHelperComm:Send("CONTROL", self.MSG.COORD_TAKEOVER, {
        sessionId   = self.state.sessionId,
        profileId   = self.state.profileId,
        coordEpoch  = self.state.coordEpoch,
        coordinator = self.state.coordinator,
    }, dist, nil, "ALERT")
end

function Sync:FinalizeHandshakeWindow()
    if not self.state.isCoordinator then return end
    if not self.state.handshake then return end

    self:UpdatePeersFromRoster()

    local have, needProf, needLogs, noResp = 0, 0, 0, 0
    for name, peer in pairs(self.state.peers or {}) do
        if peer.inGroup then
            if peer.joinStatus == "HAVE_PROFILE" then have = have + 1
            elseif peer.joinStatus == "NEED_PROFILE" then needProf = needProf + 1
            elseif peer.joinStatus == "NEED_LOGS" then needLogs = needLogs + 1
            else noResp = noResp + 1 end
        end
    end

    if SF.PrintInfo then
        SF:PrintInfo(("Handshake complete: %d have, %d need profile, %d need logs, %d no response"):
            format(have, needProf, needLogs, noResp))
    end
end

-- ============================================================================
-- Member responsibilities (Sequence 2)
-- ============================================================================

-- Function Handle session start announcement (SES_START) and decide whether to request snapshot or missing logs.
-- @param sender string "Name-Realm" of sender
-- @param payload table Decoded message payload
-- @return nil
function Sync:HandleSessionStart(sender, payload)
    if type(payload) ~= "table" then return end
    if type(payload.sessionId) ~= "string" then return end
    if type(payload.profileId) ~= "string" then return end
    if type(payload.coordinator) ~= "string" then return end
    if type(payload.coordEpoch) ~= "number" then return end

    -- Anti-spoof: sender should match claimed coordinator for session announcements
    if not self:_SamePlayer(sender, payload.coordinator) then
        return
    end

    local incomingEpoch = payload.coordEpoch
    local incomingCoord = payload.coordinator

    -- If we're already in a session:
    -- - If sessionId differs, only accept strictly-newer epoch (or tie-breaker)
    -- - If sessionId is the same, accept only if NOT older (prevents old coordinator from 'winning' later)
    if self.state.active and self.state.sessionId then
        local cmp = self:_CompareEpoch(incomingEpoch, incomingCoord)
        if not cmp then return end

        if payload.sessionId ~= self.state.sessionId then
            if cmp ~= 1 then
                return
            end
        else
            if cmp == -1 then
                return
            end
        end
    end

    local wasCoordinator = (self.state.isCoordinator == true)

    self.state.active = true
    self.state.sessionId = payload.sessionId
    self.state.profileId = payload.profileId
    self.state.coordinator = payload.coordinator
    self.state.coordEpoch = payload.coordEpoch
    self.state.isCoordinator = self:_SamePlayer(payload.coordinator, SelfId())

    if wasCoordinator and not self.state.isCoordinator then
        self:StopHeartbeatSender("lost coordinator via SES_START")
    end

    if type(payload.authorMax) == "table" then
        self.state.authorMax = payload.authorMax
    else
        self.state.authorMax = {}
    end

    if type(payload.helpers) == "table" then
        self.state.helpers = payload.helpers
    else
        self.state.helpers = {}
    end

    -- Reset join status tracking for new session
    self.state._sentJoinStatusForSessionId = nil
    self.state._profileReqInFlight = nil

    -- Reply after jitter
    local sid = self.state.sessionId
    self:RunWithJitter(self.cfg.memberReplyJitterMsMin, self.cfg.memberReplyJitterMsMax, function()
        -- Ensure session didn't change during the delay
        if not self.state.active or self.state.sessionId ~= sid then return end
        self:SendJoinStatus()
    end)

    self:TouchPeer(sender, { inGroup = true })
end

-- Function Handle session end announcement (SES_END).
-- @param sender string "Name-Realm" of sender
-- @param payload table Decoded message payload
-- @return nil
function Sync:HandleSessionEnd(sender, payload)
    if type(payload) ~= "table" then return end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return end

    -- Only relevant if we are currently in that session
    if not self.state.active or type(self.state.sessionId) ~= "string" then return end
    if payload.sessionId ~= self.state.sessionId then return end

    -- Require coordinator identity and anti-spoof
    if type(payload.coordinator) ~= "string" or payload.coordinator == "" then return end
    if not self:_SamePlayer(sender, payload.coordinator) then
        return
    end

    -- Require epoch for gating
    if type(payload.coordEpoch) ~= "number" then return end
    if not self:IsControlMessageAllowed(payload, sender) then
        return        
    end

    local reason = payload.reason

    self:_ResetSessionState("remote_end:" .. tostring(reason or "unknown"))

    if SF.PrintInfo then
        SF:PrintInfo("Loot Helper session ended by coordinator (%s).", tostring(reason or "no reason given"))
    end
end

-- Function Pick helper for a given player deterministically (e.g. hash(name) % #helpers).
-- @param playerName string "Name-Realm"
-- @param helpers table Array of "Name-Realm"
-- @return string|nil Chosen helper "Name-Realm" or nil if no helpers
function Sync:PickHelperForPlayer(playerName, helpers)
    if type(playerName) ~= "string" or playerName == "" then return nil end
    if type(helpers) ~= "table" or #helpers == 0 then return nil end

    -- Stable deterministic hash function
    local h = 0
    for i = 1, #playerName do
        h = (h * 33 + playerName:byte(i)) % 2147483647
    end

    local idx = (h % #helpers) + 1
    return helpers[idx]
end

-- Function Choose the best target (helper/coordinator) for a request, with fallback ordering.
-- @param helpers table Array of helpers "Name-Realm"
-- @param coordinator string|nil Coordinator "Name-Realm"
-- @return table targets Ordered list of targets "Name-Realm" to try
function Sync:GetRequestTargets(helpers, coordinator)
    local targets, seen = {}, {}
    
    local function add(t)
        if type(t) == "string" and t ~= "" and not seen[t] then
            seen[t] = true
            table.insert(targets, t)
        end
    end

    -- Simplify: no need for redundant conditional assignment
    local me = SelfId()

    -- 1) Preferred helper for *me* (deterministic)
    local preferred = self:PickHelperForPlayer(me, helpers or {})
    if preferred and preferred ~= me then add(preferred) end

    -- 2) Coordinator fallback
    if type(coordinator) == "string" and coordinator ~= "" and coordinator ~= me then
        add(coordinator)
    end

    -- 3) Remaining helpers (stable order)
    if type(helpers) == "table" then
        local sorted = {}
        for _, h in ipairs(helpers) do
            if type(h) == "string" and h ~= "" then
                table.insert(sorted, h)
            end
        end
        table.sort(sorted)
        for _, h in ipairs(sorted) do
            if h ~= me then
                add(h)
            end
        end
    end

    return targets
end

-- Function Request profile snapshot from helpers (preferred) or coordinator (fallback).
-- @param reason string Reason for request (for logging)
-- @return boolean True if request was registered, false otherwise
function Sync:RequestProfileSnapshot(reason)
    if not self.state.active then return false end
    if not self.state.sessionId then return false end
    if type(self.state.profileId) ~= "string" or self.state.profileId == "" then return false end

    -- Lightweight dedupe: don't spam profile requests for same session
    if self.state._profileReqInFlight == self.state.sessionId then
        return false
    end

    -- Build ordered target list: helpers first, coordinator fallback
    local targets = self:GetRequestTargets(self.state.helpers, self.state.coordinator)
    if not targets or #targets == 0 then
        if SF.PrintWarning then
            SF:PrintWarning("Cannot request profile: no targets available")
        end
        return false
    end

    local requestId = self:NewRequestId()
    local ok = self:RegisterRequest(requestId, "NEED_PROFILE", targets[1], {
        sessionId   = self.state.sessionId,
        targets     = targets,  -- fallback list
    })

    if ok then
        self.state._profileReqInFlight = self.state.sessionId
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Requesting profile snapshot (reason: %s) from initial target %s (%d targets total: %s)", 
                tostring(reason), tostring(targets[1]), #targets, table.concat(targets, ", "))
        end
    end

    return ok
end

-- Function Request missing log ranges from helpers (preferred) or coordinator (fallback).
-- @param missingRanges table Array of {author, fromCounter, toCounter}
-- @param reason string Reason for request (for logging)
-- @return boolean True if any requests were registered, false otherwise
function Sync:RequestMissingLogs(missingRanges, reason)
    if not self.state.active then return false end
    if not self.state.sessionId then return false end
    if type(self.state.profileId) ~= "string" or self.state.profileId == "" then return false end
    if type(missingRanges) ~= "table" or #missingRanges == 0 then return false end

    -- Build ordered target list: helpers first, coordinator fallback
    local targets = self:GetRequestTargets(self.state.helpers, self.state.coordinator)
    if not targets or #targets == 0 then
        if SF.PrintWarning then
            SF:PrintWarning("Cannot request missing logs: no targets available")
        end
        return false
    end

    -- Cap to avoid spamming
    local maxRanges = tonumber(self.cfg.maxMissingRangesPerNeededLogs) or 8
    local count = 0

    for i, range in ipairs(missingRanges) do
        if i > maxRanges then break end

        if type(range) == "table"
            and type(range.author) == "string"
            and type(range.fromCounter) == "number"
            and type(range.toCounter) == "number"
        then
            local requestId = self:NewRequestId()
            local ok = self:RegisterRequest(requestId, "NEED_LOGS", targets[1], {
                sessionId   = self.state.sessionId,
                profileId   = self.state.profileId,
                author      = range.author,
                fromCounter = range.fromCounter,
                toCounter   = range.toCounter,
                targets     = targets,  -- fallback list
            })

            if ok then
                count = count + 1
                if SF.Debug then
                    SF.Debug:Verbose("SYNC", "Requesting logs for %s [%d-%d] from initial target %s (%d targets: %s)",
                        tostring(range.author),
                        tonumber(range.fromCounter) or 0,
                        tonumber(range.toCounter) or 0,
                        tostring(targets[1]), #targets, table.concat(targets, ", "))
                end
            end
        end
    end

    if count > 0 and SF.Debug then
        SF.Debug:Verbose("SYNC", "Requested %d missing log ranges (reason: %s)", count, tostring(reason))
    end

    return count > 0
end

-- Function Determine whether local client has the session profile and whether it's missing logs.
-- @param profileId string Session profile id
-- @param sessionAuthorMax table Map [author] = maxCounterSeen
-- @return boolean hasProfile True if local has profile, false otherwise
-- @return table missingRequests Array describing needed missing log ranges (implementation-defined)
function Sync:AssessLocalState(profileId, sessionAuthorMax)
end

-- Function Send join status (HAVE_PROFILE, NEED_PROFILE, or NEED_LOGS) to coordinator.
-- @param none
-- @return nil
function Sync:SendJoinStatus()
    if not self.state.active then return end
    if not self.state.sessionId then return end
    if not self.state.coordinator then return end
    if self.state.isCoordinator then return end

    -- Prevent duplicate replies to repeated SES_START for the same session.
    if self.state._sentJoinStatusForSessionId == self.state.sessionId then
        return
    end

    local profileId = self.state.profileId
    local payloadBase = {
        sessionId       = self.state.sessionId,
        profileId       = profileId,
        supportedMin    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MIN or nil,
        supportedMax    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MAX or nil,
        addonVersion    = self:_GetAddonVersion(),
        supportsEnc     = (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
                            and SF.SyncProtocol.GetSupportedEncodings()
                            or nil,
    }

    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        self:RequestProfileSnapshot("join-status")
        return
    end

    local localAuthorMax = profile:ComputeAuthorMax()
    payloadBase.localAuthorMax = localAuthorMax

    local localContig = self:ComputeContigAuthorMax(profileId)
    local remoteAuthorMax = self.state.authorMax or {}
    local missing = self:ComputeMissingLogRequests(localContig, remoteAuthorMax)



    if missing and #missing > 0 then
        self:RequestMissingLogs(missing, "join-status")
        return
    end

    self.state._sentJoinStatusForSessionId = self.state.sessionId

    if SF.LootHelperComm then
        SF.LootHelperComm:Send("CONTROL", self.MSG.HAVE_PROFILE, payloadBase, "WHISPER", self.state.coordinator, "NORMAL")
    end
end

-- ============================================================================
-- Live updates (Sequence 3)
-- ============================================================================

-- Function Called when a local admin creates a new log entry; broadcasts NEW_LOG to raid.
-- @param profileId string Current session profile id
-- @param logTable table A network-safe representation of the lootLog entry
-- @return nil
function Sync:BroadcastNewLog(profileId, logTable)
    if not self.state.active then return false, "no active session" end
    if not self.state.sessionId then return false, "missing sessionId" end
    if type(profileId) ~= "string" or profileId == "" then return false, "missing profileId" end
    if self.state.profileId ~= profileId then return false, "wrong profile for session" end

    local dist = GetGroupDistribution()
    if not dist then return false, "not in group/raid" end

    -- Only admins should be able to push live updates
    local me = SelfId()
    if not self:IsSenderAuthorized(profileId, me) then
        return false, "not authorized to broadcast NEW_LOG"
    end

    -- Accept either a LootLog object or an already-serialized table
    if type(logTable) == "table" and logTable.ToTable then
        logTable = logTable:ToTable()
    end
    if type(logTable) ~= "table" then
        return false, "logTable must be a table (or LootLog instance)"
    end

    local payload = {
        sessionId   = self.state.sessionId,
        profileId   = profileId,
        log         = logTable,
    }

    if not SF.LootHelperComm then
        return false, "LootHelperComm not available"
    end

    -- Broadcast encoding rule:
    -- For raid-wide broadcasts, we usually don't know every peer's supportsEnc yet.
    -- So we pick the safest encoding for now (no compression).
    local opts = nil
    if SF.SyncProtocol and SF.SyncProtocol.ENC_B64CBOR then
        opts = { enc = SF.SyncProtocol.ENC_B64CBOR }
    end

    SF.LootHelperComm:Send("BULK", self.MSG.NEW_LOG, payload, dist, nil, "NORMAL", opts)
    return true, nil
end

-- Function Handle NEW_LOG message; dedupe/apply and request gaps if needed.
-- @param sender string "Name-Realm" of sender
-- @param payload table Decoded message payload
-- @return nil
function Sync:HandleNewLog(sender, payload)
    if type(payload) ~= "table" then return end

    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end

    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.log) ~= "table" then return end

    local profileId = payload.profileId
    local logTable = payload.log

    -- If we don't have the profile yet, request snapshot
    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        if not self.state.isCoordinator then
            self:RequestProfileSnapshot("new-log")
        end
        return
    end

    -- Trust policy: accept from coordinator; otherwise require sender is an admin
    if not self:_SamePlayer(sender, self.state.coordinator) then
        if not self:IsSenderAuthorized(profileId, sender) then
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring NEW_LOG from %s for profile %s: not an admin."):format(tostring(sender), tostring(profileId)))
            end
            return
        end
    end
    
    -- Dedupe by logId
    local logId = self:_ExtractLogId(logTable)
    if logId and profile._logIndex and profile._logIndex[logId] then
        return
    end
    
    -- Gap detection BEFORE merge
    local hasGap, gapFrom, gapTo = self:DetectGap(profileId, logTable)

    -- Apply log
    local inserted = self:MergeLogs(profileId, { logTable })
    if not inserted then
        return
    end

    -- Update UI / derived state
    self:RebuildProfile(profileId)

    -- If we detected a gap, request missing logs
    if hasGap and type(gapFrom) == "number" and type(gapTo) == "number" then
        local author = (self:_ExtractAuthorCounter(logTable))
        if type(author) == "string" and author ~= "" then
            self:RequestGapRepair(profileId, author, gapFrom, gapTo, "new-log-gap")
        end
    end

    -- Keep local session authorMax fresh
    do
        local author, counter = self:_ExtractAuthorCounter(logTable)
        if type(author) == "string" and type(counter) == "number" then
            self.state.authorMax = self.state.authorMax or {}
            local prev = tonumber(self.state.authorMax[author]) or 0
            if counter > prev then
                self.state.authorMax[author] = counter
            end
        end
    end
end

-- ============================================================================
-- Incoming message routing (called by Transport)
-- ============================================================================

-- Function Route an incoming CONTROL message to the appropriate handler.
-- @param sender string "Name-Realm" of sender
-- @param msgType string Message type (from Sync.MSG)
-- @param payload table Decoded message payload
-- @param distribution string Message distribution channel ("WHISPER", "RAID", etc.)
-- @return nil
function Sync:OnControlMessage(sender, msgType, payload, distribution)
    -- Update peer registry from "any message received"
    -- Comm already validated protocol and decoded payload
    self:TouchPeer(sender, { proto = (SF.SyncProtocol and SF.SyncProtocol.PROTO_CURRENT) or nil })

    if self.state and self.state.active and self.state.coordinator and self:_SamePlayer(sender, self.state.coordinator) then
        self.state.heartbeat = self.state.heartbeat or {}
        self.state.heartbeat.lastCoordMessageAt = Now()
    end

    if msgType == self.MSG.ADMIN_SYNC then return self:HandleAdminSync(sender, payload) end
    if msgType == self.MSG.ADMIN_STATUS then return self:HandleAdminStatus(sender, payload) end
    if msgType == self.MSG.LOG_REQ then return self:HandleLogRequest(sender, payload) end

    if msgType == self.MSG.SES_START then return self:HandleSessionStart(sender, payload) end
    if msgType == self.MSG.HAVE_PROFILE then return self:HandleHaveProfile(sender, payload) end
    if msgType == self.MSG.NEED_PROFILE then return self:HandleNeedProfile(sender, payload) end
    if msgType == self.MSG.NEED_LOGS then return self:HandleNeedLogs(sender, payload) end

    if msgType == self.MSG.SES_REANNOUNCE then return self:HandleSessionReannounce(sender, payload) end
    if msgType == self.MSG.COORD_TAKEOVER then return self:HandleCoordinatorTakeover(sender, payload) end
    if msgType == self.MSG.SES_END then return self:HandleSessionEnd(sender, payload) end
    if msgType == self.MSG.SES_HEARTBEAT then return self:HandleSessionHeartbeat(sender, payload) end
end

-- Function Route an incoming BULK message to the appropriate handler.
-- @param sender string "Name-Realm" of sender
-- @param msgType string Message type (from Sync.MSG)
-- @param payload table Decoded message payload
-- @param distribution string Message distribution channel ("WHISPER", "RAID", etc.)
-- @return nil
function Sync:OnBulkMessage(sender, msgType, payload, distribution)
    self:TouchPeer(sender, { proto = (SF.SyncProtocol and SF.SyncProtocol.PROTO_CURRENT) or nil })

    if self.state and self.state.active and self.state.coordinator and self:_SamePlayer(sender, self.state.coordinator) then
        self.state.heartbeat = self.state.heartbeat or {}
        self.state.heartbeat.lastCoordMessageAt = Now()
    end

    if msgType == self.MSG.AUTH_LOGS then return self:HandleAuthLogs(sender, payload) end
    if msgType == self.MSG.PROFILE_SNAPSHOT then return self:HandleProfileSnapshot(sender, payload) end
    if msgType == self.MSG.NEW_LOG then return self:HandleNewLog(sender, payload) end
end

-- ============================================================================
-- Message Handlers (CONTROL)
-- ============================================================================

-- Function Handle ADMIN_SYNC as a recipient admin: respond with ADMIN_STATUS after jitter.
-- @param sender string Coordinator who requested sync
-- @param payload table {sessionId, profileId, ...}
-- @return nil
function Sync:HandleAdminSync(sender, payload)
    if type(payload) ~= "table" then return end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return end
    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.adminSyncId) ~= "string" or payload.adminSyncId == "" then return end

    -- Only respond to authorized admins (no leaking logs to non-admins)
    if not self:IsSenderAuthorized(payload.profileId, sender) then
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring ADMIN_SYNC from %s for profile %s: not an admin."):format(sender, payload.profileId))
        end
        return
    end

    local sid = payload.sessionId
    local pid = payload.profileId
    local asid = payload.adminSyncId

    self:RunWithJitter(self.cfg.adminReplyJitterMsMin, self.cfg.adminReplyJitterMsMax, function()
        local status = self:BuildAdminStatus(pid)
        status.sessionId = sid
        status.profileId = pid
        status.adminSyncId = asid

        if SF.LootHelperComm then
            SF.LootHelperComm:Send("CONTROL", self.MSG.ADMIN_STATUS, status, "WHISPER", sender, "NORMAL")
        end
    end)
end

-- Function Build an ADMIN_STATUS payload for the requested profileId.
-- @param profileId string Profile id to build status for
-- @return table status {sessionId, profileId, hasProfile, authorMax, hasGaps?}
function Sync:BuildAdminStatus(profileId)
    local status = {
        hasProfile = false,
        authorMax = {},
        hasGaps = false,
        addonVersion = self:_GetAddonVersion(),

        supportedMin = SF.SyncProtocol and SF.SyncProtocol.PROTO_MIN or nil,
        supportedMax = SF.SyncProtocol and SF.SyncProtocol.PROTO_MAX or nil,

        supportsEnc = (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
                            and SF.SyncProtocol.GetSupportedEncodings()
                            or nil,
    }

    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        return status
    end

    status.hasProfile = true
    status.authorMax = profile:ComputeAuthorMax() or {}

    -- hasGaps heuristic:
    -- If counters are 1..max with no missing, then count(author) == max(author).
    -- If count < max, we're missing at least one counter somewhere (gap).
    local counts = {}
    for _, log in ipairs(profile:GetLootLogs() or {}) do
        if log and log.GetAuthor then
            local a = log:GetAuthor()
            if type(a) == "string" then
                counts[a] = (counts[a] or 0) + 1
            end
        end
    end

    for author, maxCounter in pairs(status.authorMax) do
        if type(author) == "string" and type(maxCounter) == "number" then
            if (counts[author] or 0) < maxCounter then
                status.hasGaps = true
                break
            end
        end
    end

    return status
end

-- Function Handles ADMIN_STATUS as coordinator: record status and request missing logs if needed.
-- @param sender string "Name-Realm" of sender admin
-- @param payload table ADMIN_STATUS payload
-- @return nil
function Sync:HandleAdminStatus(sender, payload)
    if not self.state.active or not self.state.isCoordinator then return end
    if type(payload) ~= "table" then return end

    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end

    if SF.Debug then
        SF.Debug:Verbose("SYNC", "Incoming ADMIN_STATUS from %s", sender)
    end

    local conv = self.state._adminConvergence
    if not conv then return end
    if payload.adminSyncId ~= conv.adminSyncId then return end

    -- Only accept status from authorized admins
    if not self:IsSenderAuthorized(self.state.profileId, sender) then return end

    self.state.adminStatuses = self.state.adminStatuses or {}
    self.state.adminStatuses[sender] = payload

    -- Early finalize if all expected responded
    local all = true
    for admin, _ in pairs(conv.expected) do
        if not self.state.adminStatuses[admin] then
            all = false
            break
        end
    end
    if all then
        self:FinalizeAdminConvergence()
    end
end

-- Function Handle SES_REANNOUNCE (typically after coordinator takeover).
-- @param sender string "Name-Realm" of sender coordinator
-- @param payload table SES_REANNOUNCE payload
-- @return nil
function Sync:HandleSessionReannounce(sender, payload)
    if type(payload) ~= "table" then return end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return end
    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.coordinator) ~= "string" or payload.coordinator == "" then return end
    if type(payload.coordEpoch) ~= "number" then return end

    -- Anti-spoof: sender must equal the coordinator they claim to be
    if not self:_SamePlayer(sender, payload.coordinator) then
        return
    end

    -- If we're in a different session, require strictly newer epoch
    if self.state.active and self.state.sessionId and payload.sessionId ~= self.state.sessionId then
        if not self:IsNewerEpoch(payload.coordEpoch, payload.coordinator) then
            return
        end
    else
        -- Same session: must not be older
        if not self:IsControlMessageAllowed(payload, sender) then
            return
        end
    end

    local wasCoordinator = (self.state.isCoordinator == true)

    local oldCoord = self.state.coordinator
    local oldEpoch = self.state.coordEpoch

    self.state.active = true
    self.state.sessionId = payload.sessionId
    self.state.profileId = payload.profileId
    self.state.coordinator = payload.coordinator
    self.state.coordEpoch = payload.coordEpoch
    self.state.isCoordinator = self:_SamePlayer(payload.coordinator, SelfId())

    if wasCoordinator and not self.state.isCoordinator then
        self:StopHeartbeatSender("lost coordinator via COORD_TAKEOVER")
    end

    self.state.authorMax = (type(payload.authorMax) == "table") and payload.authorMax or {}
    self.state.helpers = (type(payload.helpers) == "table") and payload.helpers or {}

    -- If coordinator/epoch changed, allow re-sending status and refresh request targets
    if not self:_SamePlayer(oldCoord, self.state.coordinator) or oldEpoch ~= self.state.coordEpoch then
        self.state._sentJoinStatusForSessionId = nil

        if self._RefreshOutstandingRequestTargets then
            self:_RefreshOutstandingRequestTargets()
        end
    end

    -- Reply after jitter (only if not coordinator)
    if not self.state.isCoordinator then
        local sid = self.state.sessionId
        self:RunWithJitter(self.cfg.memberReplyJitterMsMin, self.cfg.memberReplyJitterMsMax, function ()
            if not self.state.active or self.state.sessionId ~= sid then return end
            self:SendJoinStatus()            
        end)
    end

    self:TouchPeer(sender, { inGroup = true })
end

-- Function Handle SES_HEARTBEAT (keepalive)
-- @param sender string "Name-Realm" of sender
-- @param payload table SES_HEARTBEAT payload
-- @return nil
function Sync:HandleSessionHeartbeat(sender, payload)
    if type(payload) ~= "table" then return end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return end
    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.coordinator) ~= "string" or payload.coordinator == "" then return end
    if type(payload.coordEpoch) ~= "number" then return end

    -- Anti-spoof: sender must be the coordinator they claim
    if not self:_SamePlayer(sender, payload.coordinator) then
        return
    end

    -- Epoch gating:
    -- - If different sessionId, accept only if strictly newer epoch
    -- - If same sessionId (or we have none), accept if not older.
    if self.state.active and self.state.sessionId and payload.sessionId ~= self.state.sessionId then
        if not self:IsNewerEpoch(payload.coordEpoch, payload.coordinator) then
            return
        end
    else
        if not self:IsControlMessageAllowed(payload, sender) then
            return
        end
    end

    local wasCoordinator = (self.state.isCoordinator == true)

    local oldCoord = self.state.coordinator
    local oldEpoch = self.state.coordEpoch
    local oldSid = self.state.sessionId

    -- Epoch gating won't prevent an older heartbeat with the same coordEpoch from arriving after a newer one and overwriting authorMax with smaller values.
    -- This would get fixed next heartbeat, but proactively we can prevent it by also storing last seen sentAt and ignoring older heartbeats
    self.state.heartbeat = self.state.heartbeat or {}
    local hb = self.state.heartbeat
    local sameStream =
        (oldSid == payload.sessionId)
        and (oldEpoch == payload.coordEpoch)
        and self:_SamePlayer(oldCoord, payload.coordinator)
    if type(payload.sentAt) == "number" then
        local last = tonumber(hb.lastHeartbeatSentAt)
        if sameStream and last and payload.sentAt < last then return end
        hb.lastheartbeatSentAt = payload.sentAt
    else
        if not sameStream then
            hb.lastHeartbeatSentAt = nil
        end
    end

    -- Apply session descriptor
    -- We want to keep this lightweight, so we will not touch handshake bookkeeping
    self.state.active   = true
    self.state.sessionId = payload.sessionId
    self.state.profileId = payload.profileId
    self.state.coordinator = payload.coordinator
    self.state.coordEpoch = payload.coordEpoch
    self.state.isCoordinator = self:_SamePlayer(payload.coordinator, SelfId())

    if wasCoordinator and not self.state.isCoordinator then
        self:StopHeartbeatSender("lost coordinator via SES_HEARTBEAT")
    end

    -- Keep helper list + authorMax current
    if type(payload.helpers) == "table" then
        self.state.helpers = payload.helpers
    end
    if type(payload.authorMax) == "table" then
        self.state.authorMax = payload.authorMax    -- Bug: NOt sure if this is a bug, but I think we should be comparing this authormax to what we have saved to see if maybe there was something we missed.
    end

    -- Heartbeat bookkeeping
    self.state.heartbeat = self.state.heartbeat or {}
    local hb = self.state.heartbeat
    hb.lastHeartbeatAt = Now()
    hb.lastCoordMessageAt = Now()
    hb.missedHeartbeats = 0

    -- If coordinator/epoch/session changed, allow a re-evaluation
    if (not self:_SamePlayer(oldCoord, self.state.coordinator))
        or (oldEpoch ~= self.state.coordEpoch)
        or (oldSid ~= self.state.sessionId)
    then
        -- Let join-status happen again if needed
        self.state._sentJoinStatusForSessionId = nil

        -- If you had an in-flight profile request, allow a new attempt with updated target
        self.state._profileReqInFlight = nil

        if self._RefreshOutstandingRequestTargets then
            self:_RefreshOutstandingRequestTargets()
        end
    end

    self:TouchPeer(sender, { inGroup = true })

    -- Catch-up logic:
    if not self.state.isCoordinator then
        local now = Now()
        local cooldown = tonumber(self.cfg.catchupOnHeartbeatCooldownSec) or 10

        if (not hb.lastCatchupAt) or ((now - hb.lastCatchupAt) >= cooldown) then
            hb.lastCatchupAt = now

            -- If we don't have the profile, bootstrap it
            local profile = self:FindLocalProfileById(self.state.profileId)
            if not profile then
                self:RequestProfileSnapshot("heartbeat")
                return
            end

            -- If we have the profile, request missing logs (if any)
            local localContig = self:ComputeContigAuthorMax(self.state.profileId)   -- Bug: Don't we have our Authormax values saved? recalculating our Authormax maps every 30 seconds seems intense
            local remoteMax = self.state.authorMax or {}
            local missing = self:ComputeMissingLogRequests(localContig, remoteMax)

            -- Filter out ranges already covered by outstanding requests
            local filtered = {}
            for _, r in ipairs(missing or {}) do
                if type(r) == "table" then
                    local a = r.author
                    local f = r.fromCounter
                    local t = r.toCounter
                    if type(a) == "string" and type(f) == "number" and type(t) == "number" then
                        if not self:_HasOutstandingLogRangeRequest(self.state.profileId, a, f, t) then
                            table.insert(filtered, r)
                        end
                    end
                end
            end

            if #filtered > 0 then
                self:RequestMissingLogs(filtered, "heartbeat-catchup")
            end
        end
    end
end

-- Function Handle COORD_TAKEOVER (Sequence 4): update coordinator if coordEpoch is newer.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, profileId, coordEpoch, coordinator}
-- @return nil
function Sync:HandleCoordinatorTakeover(sender, payload)
    if type(payload) ~= "table" then return end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return end
    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.coordinator) ~= "string" or payload.coordinator == "" then return end
    if type(payload.coordEpoch) ~= "number" then return end

    -- Anti-spoof: sender must equal the coordinator they claim to be
    if not self:_SamePlayer(sender, payload.coordinator) then
        return
    end

    -- If we're in a different active session, only accept if epoch is strictly newer
    if self.state.active and self.state.sessionId and payload.sessionId ~= self.state.sessionId then
        if not self:IsNewerEpoch(payload.coordEpoch, payload.coordinator) then
            return
        end
    end

    -- Ignore older epochs (same-session or takeover races)
    if not self:IsControlMessageAllowed(payload, sender) then
        return
    end

    local wasCoordinator = (self.state.isCoordinator == true)

    local oldCoord = self.state.coordinator
    local oldEpoch = self.state.coordEpoch

    self.state.active = true
    self.state.sessionId = payload.sessionId
    self.state.profileId = payload.profileId
    self.state.coordinator = payload.coordinator
    self.state.coordEpoch = payload.coordEpoch
    self.state.isCoordinator = self:_SamePlayer(payload.coordinator, SelfId())

    if wasCoordinator and not self.state.isCoordinator then
        self:StopHeartbeatSender("lost coordinator via COORD_TAKEOVER")
    end

    -- Allow re-sending join status to the new coordinator
    self.state._sentJoinStatusForSessionId = nil

    -- Refresh outstanding request targets so retries can reach the new coordinator
    if self._RefreshOutstandingRequestTargets then
        self:_RefreshOutstandingRequestTargets()
    end

    -- As a member, re-announce status after jitter so the new coordinator learns about us
    if self.state.active and not self.state.isCoordinator then
        local sid = self.state.sessionId
        self:RunWithJitter(self.cfg.memberReplyJitterMsMin, self.cfg.memberReplyJitterMsMax, function()
            if not self.state.active or self.state.sessionId ~= sid then return end
            self:SendJoinStatus()
        end)
    end

    self:TouchPeer(sender, { inGroup = true })
end

-- Function Handle HAVE_PROFILE as a helper/coordinator: record that peer has profile.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId}
-- @return nil
function Sync:HandleHaveProfile(sender, payload)
    self:_RecordHandshakeReply(sender, payload, "HAVE_PROFILE")
end

-- Function Handle NEED_PROFILE as a helper/coordinator: respond with PROFILE_SNAPSHOT (bulk).
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId}
-- @return nil
function Sync:HandleNeedProfile(sender, payload)
    if type(payload) ~= "table" then return end
    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end

    self:_RecordHandshakeReply(sender, payload, "NEED_PROFILE")

    -- Serve eligibility: coordinator OR helper
    if not self.state.active then return end
    if not (self.state.isCoordinator or self:IsSelfHelper()) then return end

    -- Safety: only send to group members (prevents random whisper abuse)
    self:UpdatePeersFromRoster()
    local peer = self:GetPeer(sender)
    if not peer or not peer.inGroup then return end

    local serveRole = self.state.isCoordinator and "coordinator" or "helper"
    if SF.Debug then
        SF.Debug:Info("SYNC", "Serving profile snapshot as %s to %s", serveRole, tostring(sender))
    end

    local snapPayload = self:BuildProfileSnapshot(self.state.profileId)
    if not snapPayload then
        if SF.PrintWarning then
            SF:PrintWarning(("Cannot send PROFILE_SNAPSHOT to %s: no local profile %s."):format(sender, tostring(self.state.profileId)))
        end
        return
    end

    if type(payload.requestId) == "string" and payload.requestId ~= "" then
        snapPayload.requestId = payload.requestId
    end

    local enc = nil
    if SF.SyncProtocol and SF.SyncProtocol.PickBestBulkEncoding then
        enc = SF.SyncProtocol.PickBestBulkEncoding(payload and payload.supportsEnc)
    end

    -- Small jitter in case multiple people need it at once
    self:RunWithJitter(0, 250, function()
        if not self.state.active then return end
        if not (self.state.isCoordinator or self:IsSelfHelper()) then return end
        if not SF.LootHelperComm then return end

        if enc then
            SF.LootHelperComm:Send(
                "BULK",
                self.MSG.PROFILE_SNAPSHOT,
                snapPayload,
                "WHISPER",
                sender,
                "BULK",
                { enc = enc }
            )
        else
            SF.LootHelperComm:Send(
                "BULK",
                self.MSG.PROFILE_SNAPSHOT,
                snapPayload,
                "WHISPER",
                sender,
                "BULK"
            )
        end
    end)
end

-- Function Handle NEED_LOGS as a helper/coordinator: record that peer needs logs.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId}
-- @return nil
function Sync:HandleNeedLogs(sender, payload)
    if type(payload) ~= "table" then return end
    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end

    self:_RecordHandshakeReply(sender, payload, "NEED_LOGS")

    -- Serve eligibility: coordinator OR helper
    if not self.state.active then return end
    if not (self.state.isCoordinator or self:IsSelfHelper()) then return end

    -- Safety: only send to group members
    self:UpdatePeersFromRoster()
    local peer = self:GetPeer(sender)
    if not peer or not peer.inGroup then return end

    if type(payload) ~= "table" or type(payload.missing) ~= "table" then return end

    local profile = self:FindLocalProfileById(self.state.profileId)
    if not profile then return end

    local serveRole = self.state.isCoordinator and "coordinator" or "helper"
    if SF.Debug then
        SF.Debug:Info("SYNC", "Serving missing logs as %s to %s (%d ranges requested)",
            serveRole, tostring(sender), #payload.missing)
    end

    local maxRanges = tonumber(self.cfg.maxMissingRangesPerNeedLogs or self.cfg.maxMissingRangesPerNeededLogs) or 8
    local spacingSec = (tonumber(self.cfg.needLogsSendSpacingMs) or 75) / 1000

    local enc = nil
    if SF.SyncProtocol and SF.SyncProtocol.PickBestBulkEncoding then
        enc = SF.SyncProtocol.PickBestBulkEncoding(payload.supportsEnc)
    end

    for i, req in ipairs(payload.missing) do
        if i > maxRanges then break end

        if type(req) == "table"
            and type(req.author) == "string"
            and type(req.fromCounter) == "number"
            and type(req.toCounter) == "number"
        then
            local author = req.author
            local fromC = math.max(1, math.floor(req.fromCounter))
            local toC   = math.max(fromC, math.floor(req.toCounter))
            local delay = (i - 1) * spacingSec

            self:RunAfter(delay, function()
                if not self.state.active then return end
                if not (self.state.isCoordinator or self:IsSelfHelper()) then return end
                if not SF.LootHelperComm then return end

                -- Build inside callback to spread CPU cost too
                local out = {}
                for _, log in ipairs(profile:GetLootLogs() or {}) do
                    local a = log:GetAuthor()
                    local c = log:GetCounter()
                    if a == author and type(c) == "number" and c >= fromC and c <= toC then
                        table.insert(out, log:ToTable())
                    end
                end

                local resp = {
                    sessionId   = self.state.sessionId,
                    profileId   = self.state.profileId,
                    author      = author,
                    fromCounter = fromC,
                    toCounter   = toC,
                    logs        = out,
                }

                if type(payload.requestId) == "string" and payload.requestId ~= "" then
                    resp.requestId = payload.requestId
                end

                if enc then
                    SF.LootHelperComm:Send("BULK", self.MSG.AUTH_LOGS, resp, "WHISPER", sender, "BULK", { enc = enc })
                else
                    SF.LootHelperComm:Send("BULK", self.MSG.AUTH_LOGS, resp, "WHISPER", sender, "BULK")
                end
            end)
        end
    end
end

-- Function Handle LOG_REQ as a helper/admin: respond with AUTH_LOGS (bulk).
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, author, fromCounter, toCounter?}
-- @return nil
function Sync:HandleLogRequest(sender, payload)
    if type(payload) ~= "table" then return end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return end
    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.requestId) ~= "string" or payload.requestId == "" then return end
    if type(payload.author) ~= "string" or payload.author == "" then return end
    if type(payload.fromCounter) ~= "number" then return end
    local toCounter = payload.toCounter
    if toCounter ~= nil and type(toCounter) ~= "number" then return end

    -- Only send logs to admins. Members will use the Need Logs workflow.
    if not self:IsSenderAuthorized(payload.profileId, sender) then
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring LOG_REQ from %s for profile %s: not an admin."):format(sender, payload.profileId))
        end
        return
    end

    local profile = self:FindLocalProfileById(payload.profileId)
    if not profile then return end

    local fromC = math.max(1, math.floor(payload.fromCounter))
    local toC = (toCounter and math.floor(toCounter)) or fromC

    local out = {}
    for _, log in ipairs(profile:GetLootLogs() or {}) do
        local author = log:GetAuthor()
        local counter = log:GetCounter()
        if author == payload.author and type(counter) == "number" and counter >= fromC and counter <= toC then
            table.insert(out, log:ToTable())
        end
    end

    local resp = {
        sessionId   = payload.sessionId,
        profileId   = payload.profileId,
        adminSyncId = payload.adminSyncId,
        requestId   = payload.requestId,
        author      = payload.author,
        logs        = out,
    }

    if SF.SyncProtocol and SF.SyncProtocol.PickBestBulkEncoding and SF.LootHelperComm then
        local enc = SF.SyncProtocol.PickBestBulkEncoding(payload.supportsEnc)
        SF.LootHelperComm:Send("BULK", self.MSG.AUTH_LOGS, resp, "WHISPER", sender, "BULK", { enc = enc })
    elseif SF.LootHelperComm then
        SF.LootHelperComm:Send("BULK", self.MSG.AUTH_LOGS, resp, "WHISPER", sender, "BULK")
    end
end

-- Function Record a handshake reply from a peer during the handshake collection window.
-- @param sender string "Name-Realm" of sender
-- @param payload table Handshake reply payload
-- @param status string "HAVE_PROFILE"|"NEED_PROFILE"|"NEED_LOGS"
-- @return nil
function Sync:_RecordHandshakeReply(sender, payload, status)
    if not self.state.isCoordinator then return end

    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end

    local peer = self:GetPeer(sender)
    peer.joinStatus = status
    peer.joinReportedAt = Now()

    self:SetPeerSyncState(sender, status, "handshake")

    if type(payload) == "table" then
        peer.supportedMin = payload.supportedMin
        peer.supportedMax = payload.supportedMax
        peer.addonVersion = payload.addonVersion
        peer.localAuthorMax = payload.localAuthorMax
        peer.missing = payload.missing
    end

    -- Track in handshake table too
    if self.state.handshake and self.state.handshake.replies then
        self.state.handshake.replies[sender] = status
    end
end

-- ============================================================================
-- Message Handlers (BULK)
-- ============================================================================

-- Function Handle AUTH_LOGS bulk response; merge logs and rebuild state if needed.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, author, logs =[...]}
-- @return nil
function Sync:HandleAuthLogs(sender, payload)
    if type(payload) ~= "table" then return end

    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end

    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.logs) ~= "table" then return end

    -- Trust policy: accept from coordinator or helper
    if not self.state.isCoordinator then
        if not self:IsTrustedDataSender(sender) then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: not a trusted sender", tostring(sender))
            end
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring AUTH_LOGS from %s: not a trusted sender."):format(sender))
            end
            return
        end

        if not self:IsRequesterInGroup(sender) then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: not in group", tostring(sender))
            end
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring AUTH_LOGS from %s: not in group."):format(sender))
            end
            return
        end

        -- If you keep this check, member must already have the profile/admin list.
        if not self:IsSenderAuthorized(payload.profileId, sender) then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting AUTH_LOGS from %s: not an admin of profile", tostring(sender))
            end
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring AUTH_LOGS from %s: not an admin of profile."):format(sender))
            end
            return
        end

        if SF.Debug then
            local senderRole = (sender == self.state.coordinator) and "coordinator" or (self:IsHelper(sender) and "helper" or "unknown")
            SF.Debug:Info("SYNC", "Accepting AUTH_LOGS from %s as %s (%d logs for %s [%d-%d])",
                tostring(sender), senderRole, #payload.logs, tostring(payload.author),
                tonumber(payload.fromCounter) or 0, tonumber(payload.toCounter) or 0)
        end
    end

    local changed = self:MergeLogs(payload.profileId, payload.logs)
    if changed then
        self:RebuildProfile(payload.profileId)
    end

    if type(payload.requestId) == "string" and payload.requestId ~= "" then
        self:CompleteRequest(payload.requestId)
    end

    -- If we are coordinator, this might be part of admin convergence
    if self.state.isCoordinator then
        local conv = self.state._adminConvergence
        if conv and payload.adminSyncId == conv.adminSyncId and type(payload.requestId) == "string" then
            if conv.pendingReq and conv.pendingReq[payload.requestId] then
                conv.pendingReq[payload.requestId] = nil
                conv.pendingCount = math.max(0, (conv.pendingCount or 1) - 1)

                if conv.pendingCount == 0 then
                    self:_FinishAdminConvergence("complete")
                end
            end
        end
    end
end

-- Function Handle PROFILE_SNAPSHOT; import profile + logs then rebuild derived state.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, profileMeta, logs=[...], adminUsers=[...], ...}
-- @return nil
function Sync:HandleProfileSnapshot(sender, payload)
    if type(payload) ~= "table" then return end

    -- Must be for the current session
    local ok, err = self:ValidateSessionPayload(payload)
    if not ok then return end

    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.snapshot) ~= "table" then return end

    -- Trust policy: accept from coordinator or helper
    if not self:IsTrustedDataSender(sender) then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting PROFILE_SNAPSHOT from %s: not a trusted sender", tostring(sender))
        end
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring PROFILE_SNAPSHOT from %s: not a trusted sender."):format(sender))
        end
        return
    end

    -- Safety: sender must be in group
    if not self:IsRequesterInGroup(sender) then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting PROFILE_SNAPSHOT from %s: not in group", tostring(sender))
        end
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring PROFILE_SNAPSHOT from %s: not in group."):format(sender))
        end
        return
    end

    local senderRole = self.state.isCoordinator and "coordinator" or (self:IsHelper(sender) and "helper" or "unknown")
    if SF.Debug then
        SF.Debug:Info("SYNC", "Accepting PROFILE_SNAPSHOT from %s as %s (profile: %s)",
            tostring(sender), senderRole, tostring(payload.profileId))
    end

    -- Validate snapshot
    if SF.LootProfile and SF.LootProfile.ValidateSnapshot then
        local okSnap, snapErr = SF.LootProfile.ValidateSnapshot(payload.snapshot)
        if not okSnap then
            if SF.PrintWarning then
                SF:PrintWarning(("PROFILE_SNAPSHOT invalid: %s"):format(snapErr or "unknown"))
            end
            return
        end
    end

    -- Ensure payload.profileId matches snapshot meta profileId
    local meta = payload.snapshot.meta
    if not meta or type(meta._profileId) ~= "string" then return end
    if payload.profileId ~= meta._profileId then
        if SF.PrintWarning then
            SF:PrintWarning(("PROFILE_SNAPSHOT mismatch: payload.profileId=%s meta._profileId=%s"):format(
                tostring(payload.profileId), tostring(meta._profileId)))
        end
        return
    end

    -- Ensure DB exists
    SF.lootHelperDB = SF.lootHelperDB or { profiles = {}, activeProfileId = nil }
    SF.lootHelperDB.profiles = SF.lootHelperDB.profiles or {}

    local profileId = payload.profileId
    local profile = self:FindLocalProfileById(profileId)
    local isNew = false

    if not profile then
        profile = self:CreateProfileFromMeta(meta)
        if not profile then return end
        isNew = true
    end

    -- Import snapshot (merges logs + dedup by logId)
    local okImport, inserted, importErr = profile:ImportSnapshot(payload.snapshot, { allowUnknownEventType = true })
    if not okImport then
        if SF.PrintWarning then
            SF:PrintWarning(("PROFILE_SNAPSHOT import failed: %s"):format(importErr or "unknown"))
        end
        return
    end

    -- Store new profile in canonical map (keyed by profileId)
    if isNew then
        SF.lootHelperDB.profiles[profileId] = profile
        if SF.Debug then
            SF.Debug:Info("SYNC", "Imported new profile: %s (ID: %s)", 
                profile:GetProfileName() or "Unknown", profileId)
        end
    end

    self:RebuildProfile(profileId)

    -- Set as active profile (use profileId now)
    if SF.SetActiveProfileById then
        SF:SetActiveProfileById(profileId)
    end

    if type(payload.requestId) == "string" and payload.requestId ~= "" then
        self:CompleteRequest(payload.requestId)
    end

    -- Clear profile request dedupe marker on successful import
    if self.state._profileReqInFlight == self.state.sessionId then
        self.state._profileReqInFlight = nil
    end

    if SF.PrintInfo then
        SF:PrintInfo(("Imported PROFILE_SNAPSHOT %s (%d new logs)"):format(
            profile:GetProfileName() or profileId,
            inserted or 0))
    end

    -- Now that we actually have the profile, run the normal sync assessment path:
    -- - if missing logs, it will Request MissingLogs()
    -- - if fully synced, it will whisper HAVE_PROFILE to coordinator
    self:RunAfter(0, function()
       if not self.state.active then return end
       if self.state.sessionId ~= payload.sessionId then return end
       if self.state.profileId ~= profileId then return end
       if self.state.isCoordinator then return end
       self:SendJoinStatus()
    end)
end

-- ============================================================================
-- Request lifecycle (timeouts/retries)
-- ============================================================================

-- Function Create a new requestId for correlating request/response.
-- @param none
-- @return string requestId
function Sync:NewRequestId()
    return self:_NextNonce("REQ")
end

-- Function Cancel and clear any existing timer on a request.
-- @param req table Request state table
-- @return nil
function Sync:_CancelRequestTimer(req)
    if not req then return end
    local t = req.timer
    req.timer = nil
    if t and t.Cancel then
        pcall(function() t:Cancel() end)    -- TODO: suually we catch the returns from pcall, I thought that was the whole point.
    end
end

-- Function Compute the delay (in seconds) before retrying a request.
-- @param req table Request state table
-- @return number delaySec
function Sync:_ComputeRequestDelaySec(req)
    local base = tonumber(req.timeoutSec) or tonumber(self.cfg.requestTimeoutSec) or 5
    local mult = tonumber(self.cfg.requestBackoffMult) or 1.5
    local attempt = tonumber(req.attempt) or 1

    local delay = base * (mult ^ math.max(0, attempt - 1))

    local jmin = tonumber(self.cfg.requestRetryJitterMsMin) or 0        -- TODO: Why would we wait 0 ms for a jitter before retrying, that literally gives them no time to respond right?
    local jmax = tonumber(self.cfg.requestRetryJitterMsMax) or jmin
    if jmax < jmin then jmin, jmax = jmax, jmin end
    if jmax > 0 then
        local ms = (jmax > jmin) and math.random(jmin, jmax) or jmin
        delay = delay + (ms / 1000)
    end

    return delay
end

-- Function Arm a request timer to trigger timeout handling.
-- @param req table Request state table
-- @return nil
-- TODO: If a request is timing out, should we be doing a log or something?
function Sync:_ArmRequestTimer(req)
    self:_CancelRequestTimer(req)
    local delay = self:_ComputeRequestDelaySec(req)
    req.timer = self:RunAfter(delay, function()
        self:OnRequestTimeout(req.id)
    end)
end

-- Function Normalize target list for a request (dedupe, ignore blanks).
-- @param initialTarget string "Name-Realm" of initial target
-- @param extraTargets table|nil Additional targets to include
-- @return table Array of "Name-Realm" targets
function Sync:_NormalizeTargets(initialTarget, extraTargets)
    local out, seen = {}, {}
    local function add(t)
        if type(t) == "string" and t ~= "" and not seen[t] then
            seen[t] = true
            table.insert(out, t)
        end
    end

    add(initialTarget)
    if type(extraTargets) == "table" then
        for _, t in ipairs(extraTargets) do add(t) end
    end

    return out
end

-- Function Pick the next target for a request (single target retries same, multi target walks list).
-- @param req table Request state table
-- @return string|nil "Name-Realm" of next target, or nil if none
function Sync:_PickNextTargetForRequest(req)
    if not req or type(req.targets) ~= "table" or #req.targets == 0 then
        return nil
    end

    -- Single target: keep retrying the same peer
    if #req.targets == 1 then
        req.targetIdx = 1
        return req.targets[1]
    end

    -- Multi target: walk the list once (no wrap)
    local idx = (tonumber(req.targetIdx) or 0) + 1
    if idx > #req.targets then return nil end
    req.targetIdx = idx
    return req.targets[idx]
end

-- Function Send a LOG_REQ to a target peer.
-- @param req table Request state table
-- @param target string "Name-Realm" of target peer
-- @return boolean True if sent, false otherwise
function Sync:_SendAdminLogReq(req, target)
    if not (self.state.active and self.state.isCoordinator) then return false end
    if not SF.LootHelperComm then return false end
    if type(target) ~= "string" or target == "" then return false end

    local meta = req and req.meta or nil
    if type(meta) ~= "table" then return false end

    local payload = {
        sessionId   = meta.sessionId,
        profileId   = meta.profileId,
        adminSyncId = meta.adminSyncId,
        requestId   = req.id,
        author      = meta.author,
        fromCounter = meta.fromCounter,
        toCounter   = meta.toCounter,
        supportsEnc = meta.supportsEnc,
    }

    return SF.LootHelperComm:Send("CONTROL", self.MSG.LOG_REQ, payload, "WHISPER", target, "NORMAL")
end

-- Function Send a NEED_PROFILE to a target peer.
-- @param req table Request state table
-- @param target string "Name-Realm" of target peer
-- @return boolean True if sent, false otherwise
function Sync:_SendNeedProfileReq(req, target)
    if not self.state.active then return false end
    if not SF.LootHelperComm then return false end
    if type(target) ~= "string" or target == "" then return false end

    local profileId = self.state.profileId
    -- TODO: Isn't this a profile request? Having profileId == "" might be common and need to be a parameter.
    -- Unless this serves a different use case. Perhaps we set profileId when we learn which profile to use?
    if type(profileId) ~= "string" or profileId == "" then return false end

    local payload = {
        sessionId       = self.state.sessionId,
        profileId       = profileId,
        requestId       = req.id,

        supportedMin    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MIN or nil,
        supportedMax    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MAX or nil,
        addonVersion    = self:_GetAddonVersion(),
        supportsEnc     = (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
                            and SF.SyncProtocol.GetSupportedEncodings()
                            or nil,
    }

    return SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_PROFILE, payload, "WHISPER", target, "NORMAL")
end

-- Function Send NEED_LOGS request for missing log ranges.
-- @param req table Request state table
-- @param target string Target "Name-Realm"
-- @return boolean True if sent, false otherwise
function Sync:_SendNeedLogsReq(req, target)
    if not self.state.active then return false end
    if not SF.LootHelperComm then return false end
    if type(target) ~= "string" or target == "" then return false end

    local meta = req.meta or {}
    local sessionId = meta.sessionId or self.state.sessionId
    local profileId = meta.profileId or self.state.profileId

    if type(sessionId) ~= "string" or sessionId == "" then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end

    local missing = {}
    if type(meta.author) == "string" and type(meta.fromCounter) == "number" and type(meta.toCounter) == "number" then
        table.insert(missing, {
            author      = meta.author,
            fromCounter = meta.fromCounter,
            toCounter   = meta.toCounter,
        })
    end

    if #missing == 0 then return false end

    local payload = {
        sessionId       = sessionId,
        profileId       = profileId,
        requestId       = req.id,
        missing         = missing,
        supportedMin    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MIN or nil,
        supportedMax    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MAX or nil,
        addonVersion    = self:_GetAddonVersion(),
        supportsEnc     = (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
                            and SF.SyncProtocol.GetSupportedEncodings()
                            or nil,
    }

    return SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_LOGS, payload, "WHISPER", target, "NORMAL")
end

-- Function Attempt to send a request (called initially and on timeouts).
-- @param req table Request state table
-- @return nil
function Sync:_SendRequestAttempt(req)
    if not req then return end

    -- Session ended or changed -> drop
    if not self.state.active then
        self:_FailRequest(req, "session ended")
        return
    end
    if type(req.meta) == "table" and type(req.meta.sessionId) == "string" and self.state.sessionId then
        if req.meta.sessionId ~= self.state.sessionId then
            self:_FailRequest(req, "stale session")
            return
        end
    end

    local maxAttempts = 1 + (tonumber(req.maxRetries) or tonumber(self.cfg.maxRetries) or 0)
    if (tonumber(req.attempt) or 0) >= maxAttempts then
        self:_FailRequest(req, "max attempts reached")
        return
    end

    req.attempt = (tonumber(req.attempt) or 0) + 1

    local target = self:_PickNextTargetForRequest(req)
    if not target then
        self:_FailRequest(req, "no more targets")
        return
    end

    local ok = false
    if req.kind == "ADMIN_LOG_REQ" then
        ok = self:_SendAdminLogReq(req, target)
    elseif req.kind == "LOG_REQ" then
        ok = self:_SendLogReq(req, target)
    elseif req.kind == "NEED_PROFILE" then
        ok = self:_SendNeedProfileReq(req, target)
    elseif req.kind == "NEED_LOGS" then
        ok = self:_SendNeedLogsReq(req, target)
    else
        self:_FailRequest(req, "unknown request kind: " .. tostring(req.kind))
        return
    end

    -- Even if send fails, we still arm a timer; timeout path will retry
    req.lastSentAt = Now()
    req.lastTarget = target
    self:_ArmRequestTimer(req)
end

-- Function Mark a request as failed; clean up state and handle special cases.
-- @param req table Request state table
-- @param reason string|nil Reason for failure
-- @return nil
function Sync:_FailRequest(req, reason)
    if not req then return end
    self:_CancelRequestTimer(req)
    
    if self.state.requests then
        self.state.requests[req.id] = nil
    end

    -- If this was a profile bootstrap request, allow a future retry
    if req.kind == "NEED_PROFILE" then
        if self.state._profileReqInFlight == self.state.sessionId then
            self.state._profileReqInFlight = nil
        end
        -- Also allow SendJoinStatus to re-attempt bootstrap later
        if not self:FindLocalProfileById(self.state.profileId) then
            self.state._sentJoinStatusForSessionId = nil
        end
    end

    -- If this was a profile request, schedule a retry after a delay
    if req.kind == "NEED_PROFILE" then
        self:RunAfter(2.0, function()
            if not self.state.active then return end
            if self:FindLocalProfileById(self.state.profileId) then return end
        self:RequestProfileSnapshot("retry-after-failure")
        end)
    end

    -- If this was admin convergence, decrement pending so session can proceed.
    if req.kind == "ADMIN_LOG_REQ" and self.state.isCoordinator then
        local conv = self.state._adminConvergence
        if conv and conv.pendingReq and conv.pendingReq[req.id] then
            conv.pendingReq[req.id] = nil
            conv.pendingCount = math.max(0, (conv.pendingCount or 1) - 1)

            if conv.pendingCount == 0 then
                self:_FinishAdminConvergence("complete_after_failure")
            end
        end
    end

    if SF.PrintWarning then
        SF:PrintWarning(("Request failed (%s): %s"):format(tostring(reason or "unknown"), tostring(req.id)))
    end
end

-- Function Register an outstanding request so it can timeout / retry / be matched.
-- @param requestId string Unique request identifier
-- @param kind string Request kind/type (e.g. "LOG_REQ", "NEED_PROFILE", etc.)
-- @param target string "Name-Realm" of the initial peer being contacted
-- @param meta table|nil Any metadata (author ranges, etc.)
-- @return nil
function Sync:RegisterRequest(requestId, kind, target, meta)
    if type(requestId) ~= "string" or requestId == "" then return false end
    if type(kind) ~= "string" or kind == "" then return false end
    if type(target) ~= "string" or target == "" then return false end

    self.state.requests = self.state.requests or {}
    if self.state.requests[requestId] then return false end

    -- bound outstanding requests
    local maxOut = tonumber(self.cfg.maxOutstandingRequests) or 64
    local n = 0
    for _ in pairs(self.state.requests) do n = n + 1 end
    if n >= maxOut then
        if SF.PrintWarning then
            SF:PrintWarning(("Too many outstanding requests (%d/%d); dropping %s"):format(n, maxOut, tostring(requestId)))
        end
        return false
    end

    meta = (type(meta) == "table") and meta or {}
    local extra = meta.extraTargets or meta.targets
    local targets = self:_NormalizeTargets(target, extra)

    local req = {
        id          = requestId,
        kind        = kind,
        attempt     = 0,
        maxRetries  = tonumber(meta.maxRetries) or tonumber(self.cfg.maxRetries) or 2,
        timeoutSec  = tonumber(meta.timeoutSec) or tonumber(self.cfg.requestTimeoutSec) or 5,
        createdAt   = Now(),
        lastSentAt  = nil,
        lastTarget  = nil,
        targets     = targets,
        targetIdx   = 0,
        meta        = meta,
        timer       = nil,
    }

    self.state.requests[requestId] = req
    self:_SendRequestAttempt(req)
    return true
end

-- Function Mark a request as completed (cancel timers, clear state).
-- @param requestId string
-- @return nil
function Sync:CompleteRequest(requestId)
    if type(requestId) ~= "string" or requestId == "" then return false end
    local req = self.state.requests and self.state.requests[requestId]
    if not req then return false end

    self:_CancelRequestTimer(req)
    self.state.requests[requestId] = nil
    return true
end

-- Function Handle request timeout; retry against alternate helper or coordinator.
-- @param requestId string
-- @return nil
function Sync:OnRequestTimeout(requestId)
    if type(requestId) ~= "string" or requestId == "" then return end
    local req = self.state.requests and self.state.requests[requestId]
    if not req then return end

    if SF.Debug then
        SF.Debug:Verbose("SYNC", "Request timeout: %s (attempt %d)", req.id, req.attempt or 0)
    end

    req.timer = nil
    self:_SendRequestAttempt(req)
end

-- ============================================================================
-- Validation / Epoch rules
-- ============================================================================

-- Function Normalize a "Name-Realm" for comparison (remove spaces, etc.).
-- @param nameRealm string "Name-Realm"
-- @return string|nil Normalized "Name-Realm", or nil if invalid input
function Sync:_NormalizeNameRealmForCompare(nameRealm)
    if type(nameRealm) ~= "string" or nameRealm == "" then return nil end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(nameRealm)
    end
    return (nameRealm:gsub("%s+", ""))
end

-- Function Compare two "Name-Realm" identifiers for equality.
-- @param a string "Name-Realm"
-- @param b string "Name-Realm"
-- @return boolean True if same player, false otherwise
function Sync:_SamePlayer(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    return a == b
end

-- Function Refresh outstanding request targets based on current helpers/coordinator.
-- @param none
-- @return nil
function Sync:_RefreshOutstandingRequestTargets()
    if not self.state.requests then return end

    local newTargets = self:GetRequestTargets(self.state.helpers, self.state.coordinator)
    if type(newTargets) ~= "table" or #newTargets == 0 then return end

    local function addUnique(list, t)
        if type(t) ~= "string" or t == "" then return end
        for _, existing in ipairs(list) do
            if self:_SamePlayer(existing, t) then return end
        end
        table.insert(list, t)
    end

    for _, req in pairs(self.state.requests) do
        if type(req) == "table" and (req.kind == "NEED_PROFILE" or req.kind == "NEED_LOGS") then
            req.targets = req.targets or {}
            for _, t in ipairs(newTargets) do
                addUnique(req.targets, t)
            end
        end

        -- If we lost coordinator status, stop admin convergence requests
        if type(req) == "table" and req.kind == "ADMIN_LOG_REQ" and not self.state.isCoordinator then
            self:_FailRequest(req, "no longer coordinator")
        end
    end
end

-- Function Compare an incoming epoch to our current epoch (tie-break if needed).
-- @param incomingEpoch number|string Incoming epoch value
-- @param incomingCoordinator string "Name-Realm" of incoming coordinator (for tie-break)
-- @return number|nil 1 if incoming is newer, -1 if older, 0 if equal, nil if invalid
function Sync:_CompareEpoch(incomingEpoch, incomingCoordinator)
    local inc = tonumber(incomingEpoch)
    if not inc then return nil end

    local cur = tonumber(self.state.coordEpoch) or 0
    if inc > cur then return 1 end
    if inc < cur then return -1 end

    -- tie-break on coordinator id for deterministic convergence
    local incC = self:_NormalizeNameRealmForCompare(incomingCoordinator) or ""
    local curC = self:_NormalizeNameRealmForCompare(self.state.coordinator) or ""
    if incC == curC then return 0 end
    return (incC > curC) and 1 or -1
end

-- Function Determine if an incoming control message is allowed based on coordEpoch.
-- @param payload table Must include sessionId + coordEpoch where applicable
-- @param sender string "Name-Realm" of sender
-- @return boolean True if allowed, false otherwise
function Sync:IsControlMessageAllowed(payload, sender)
    if type(payload) ~= "table" then return true end
    if type(payload.coordEpoch) ~= "number" then return true end

    local incomingCoordinator = payload.coordinator or sender
    local cmp = self:_CompareEpoch(payload.coordEpoch, incomingCoordinator)
    if cmp == nil then return false end
    return cmp >= 0
end

-- Function Determine if an epoch value is newer than our current epoch (tie-break if needed).
-- @param incomingEpoch number|string Incoming epoch value
-- @param incomingCoordinator string "Name-Realm" of incoming coordinator (for tie-break)
-- @return boolean True if incoming is newer, false otherwise
function Sync:IsNewerEpoch(incomingEpoch, incomingCoordinator)
    return self:_CompareEpoch(incomingEpoch, incomingCoordinator) == 1
end

-- Function Validate whether sender is permitted to provide data for a profile (admin check).
-- @param profileId string Profile id
-- @param sender string "Name-Realm" of sender
-- @return boolean True if sender is admin of profile, false otherwise
function Sync:IsSenderAuthorized(profileId, sender)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return false end
    local admins = profile.GetAdminUsers and profile:GetAdminUsers() or nil
    if type(admins) ~= "table" then return false end

    for _, admin in ipairs(admins) do
        if self:_SamePlayer(admin, sender) then return true end
    end
    return false
end

-- Function Check if the given profileId authorizes the sender as an admin.
-- @param profileId string Stable profile id
-- @return boolean True if sender is authorized admin, false otherwise
function Sync:CanSelfCoordinate(profileId)
    local dist = GetGroupDistribution()
    if not dist then
        return false, "Not in a group/raid"
    end

    local me = SelfId()
    if not self:IsSenderAuthorized(profileId, me)
    then
        return false, "You are not an admin for the selected profile"
    end

    return true, nil
end



-- Function Check if a given player is a helper in the current session.
-- @param nameRealm string Player identifier ("Name-Realm")
-- @return boolean True if nameRealm is in helpers list, false otherwise
function Sync:IsHelper(nameRealm)
    if type(nameRealm) ~= "string" or nameRealm == "" then return false end
    if not self.state.helpers or type(self.state.helpers) ~= "table" then return false end

    -- Normalize input
    local normalizedInput = nameRealm
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        normalizedInput = SF.NameUtil.NormalizeNameRealm(nameRealm)
        if not normalizedInput then return false end
    end

    -- Check each helper in array
    for _, helper in ipairs(self.state.helpers) do
        local normalizedHelper = helper
        if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
            normalizedHelper = SF.NameUtil.NormalizeNameRealm(helper)
        end

        -- Compare using SamePlayer when available, else string equality
        if SF.NameUtil and SF.NameUtil.SamePlayer then
            if SF.NameUtil.SamePlayer(normalizedInput, normalizedHelper) then
                return true
            end
        else
            if normalizedInput == normalizedHelper then
                return true
            end
        end
    end

    return false
end

-- Function Check if the local player is a helper in the current session.
-- @param none
-- @return boolean True if self is helper, false otherwise
function Sync:IsSelfHelper()
    local selfId = SelfId()
    if not selfId then return false end
    return self:IsHelper(selfId)
end

-- Function Check if sender is trusted to send authoritative data (coordinator or helper).
-- @param sender string Player identifier ("Name-Realm")
-- @return boolean True if sender is coordinator or helper, false otherwise
function Sync:IsTrustedDataSender(sender)
    if type(sender) ~= "string" or sender == "" then return false end

    -- Normalize sender
    local normalizedSender = sender
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        normalizedSender = SF.NameUtil.NormalizeNameRealm(sender)
        if not normalizedSender then return false end
    end

    -- Check if sender is coordinator
    if self.state.coordinator then
        local normalizedCoordinator = self.state.coordinator
        if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
            normalizedCoordinator = SF.NameUtil.NormalizeNameRealm(self.state.coordinator)
        end

        if SF.NameUtil and SF.NameUtil.SamePlayer then
            if SF.NameUtil.SamePlayer(normalizedSender, normalizedCoordinator) then
                return true
            end
        else
            if normalizedSender == normalizedCoordinator then
                return true
            end
        end
    end

    -- Check if sender is helper
    if self:IsHelper(normalizedSender) then
        return true
    end

    return false
end

-- Function Check if requester is in the current group roster.
-- @param sender string Player identifier ("Name-Realm")
-- @return boolean True if sender is in group and peer.inGroup is true, false otherwise
function Sync:IsRequesterInGroup(sender)
    if type(sender) ~= "string" or sender == "" then return false end

    -- Normalize sender
    local normalizedSender = sender
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        normalizedSender = SF.NameUtil.NormalizeNameRealm(sender)
        if not normalizedSender then return false end
    end

    -- Update roster to get current group state
    self:UpdatePeersFromRoster()

    -- Get peer record
    local peer = self:GetPeer(normalizedSender)
    if not peer then return false end

    return peer.inGroup == true
end

-- Function Validate session-related payloads for consistency with current session state.
-- @param payload table Must include sessionId and optionally profileId
-- @return boolean isValid True if valid, false otherwise
-- @return string|nil errReason If not valid, reason why
function Sync:ValidateSessionPayload(payload)
    if not self.state.active then return false, "no active session" end
    if type(payload) ~= "table" then return false, "payload not table" end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return false, "missing sessionId" end

    if self.state.active and self.state.sessionId and payload.sessionId ~= self.state.sessionId then
        return false, "stale/other sessionId"
    end

    if self.state.active and self.state.profileId and type(payload.profileId) == "string" and payload.profileId ~= self.state.profileId then
        return false, "wrong profileId for this session"
    end

    return true, nil
end

-- ============================================================================
-- Profile / Log integration helpers (high-level; class implementations can sit elsewhere)
-- ============================================================================

-- Function Find a local profile by stable profileId.
-- Uses canonical profileId-based schema (SF.lootHelperDB.profiles[profileId]).
-- @param profileId string Stable profile id
-- @return table|nil LootProfile instance or nil if not found
function Sync:FindLocalProfileById(profileId)
    if not SF.lootHelperDB then return nil end
    if type(profileId) ~= "string" or profileId == "" then return nil end

    -- Direct lookup in canonical profileId-based map (O(1))
    if SF.lootHelperDB.profiles and type(SF.lootHelperDB.profiles) == "table" then
        local profile = SF.lootHelperDB.profiles[profileId]
        if profile and type(profile) == "table" and profile.GetProfileId then
            local pid = profile:GetProfileId()
            if pid == profileId then
                return profile
            end
        end
    end

    return nil
end

-- Function Create a new empty local profile shell from snapshot metadata (no derived state yet).
-- @param profileMeta table Metadata about the profile (from snapshot)
-- @return table|nil LootProfile instance or nil if failed
function Sync:CreateProfileFromMeta(profileMeta)
    if type(profileMeta) ~= "table" then return nil end
    if not SF.LootProfile then return nil end

    -- Validate meta
    if SF.LootProfile.ValidateMeta then
        local ok, err = SF.LootProfile.ValidateMeta(profileMeta)
        if not ok then
            if SF.PrintWarning then
                SF:PrintWarning(("CreateProfileFromMeta: invalid meta: %s"):format(err or "unknown"))
            end
            return nil
        end
    end

    -- Create a blank profile object
    local profile = setmetatable({}, SF.LootProfile)

    -- Initialize tables that other code might assume exist
    profile._lootLogs = {}
    profile._logIndex = {}
    profile._authorCounters = {}
    profile._members = {}
    profile._adminUsers = {}
    profile._activeProfile = false
    profile._profileId = profileMeta._profileId
    profile._profileName = profileMeta._profileName or "Imported Profile"

    return profile
end

-- Function Export a full snapshot for a profile, suitable for PROFILE_SNAPSHOT message.
-- @param profileId string Stable profile id
-- @return table|nil Snapshot payload or nil if profile not found
function Sync:BuildProfileSnapshot(profileId)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return nil end
    if not profile.ExportSnapshot then return nil end
    
    local snapshot = profile:ExportSnapshot()

    return {
        sessionId   = self.state.sessionId,
        profileId   = profileId,
        snapshot    = snapshot,
        sentAt      = Now(),
        sender      = SelfId(),
        addonVersion= self:_GetAddonVersion(),
    }
end

-- Function Compute authorMax summary from profile's logs.
-- @param profileId string Stable profile id
-- @return table snapshotPayload Map [author] = maxCounterSeen
function Sync:ComputeAuthorMax(profileId)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return {} end
    if profile.ComputeAuthorMax then
        return profile:ComputeAuthorMax()
    end
    return {}
end

-- Function Compute missing log ranges given local authorMax and remote authorMax (or detect gaps).
-- @param localAuthorMax table Map [author] = maxCounterSeen
-- @param remoteAuthorMax table Map [author] = maxCounterSeen
-- @return table missingRequests Array describing needed author/range requests.
function Sync:ComputeMissingLogRequests(localAuthorMax, remoteAuthorMax)
    local missing = {}
    if type(remoteAuthorMax) ~= "table" then return missing end
    localAuthorMax = localAuthorMax or {}

    for author, remoteMax in pairs(remoteAuthorMax) do
        if type(author) == "string" and type(remoteMax) == "number" then
            local localMax = tonumber(localAuthorMax[author]) or 0
            if remoteMax > localMax then
                table.insert(missing, {
                    author = author,
                    fromCounter = localMax + 1,
                    toCounter = remoteMax,
                })
            end
        end
    end
    return missing
end

-- Function Merge incoming logs (net tables) into local profile; dedupe by logId; keep chronological order.
-- @param profileId string Stable profile id
-- @param logs table Array of log tables
-- @return boolean changed True if any new logs were added, false otherwise
function Sync:MergeLogs(profileId, logs)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return false end
    if type(logs) ~= "table" then return false end

    local inserted = profile:MergeLogTables(logs, { allowUnknownEventType = true })
    return inserted and inserted > 0
end

-- Function Rebuild derived state from logs (replay) for the given profile.
-- @param profileId string Stable profile id
-- @return nil
function Sync:RebuildProfile(profileId)
    if type(profileId) ~= "string" or profileId == "" then
        return false, "invalid profileId"
    end

    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        return false, "profile not found"
    end

    -- 1) Ensure deterministic log order (MergeLogTables already sorts, but safe to re-sort)
    if type(profile._lootLogs) == "table" and type(profile._CompareLogs) == "function" then
        table.sort(profile._lootLogs, function(a, b)
            return profile:_CompareLogs(a, b)
        end)
    end

    -- 2) Rebuild index + per-author max counters (critical for dedup + AllocateNextCounter)
    if type(profile.RebuildLogIndex) == "function" then
        profile:RebuildLogIndex()
    else
        -- Fallback (older profile versions)
        profile._logIndex = {}
        profile._authorCounters = {}

        for _, log in ipairs(profile._lootLogs or {}) do
            local id = (log and log.GetID and log:GetID()) or (log and log._id)
            if type(id) == "string" and id ~= "" then
                profile._logIndex[id] = true
            end

            local author = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
            local counter = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
            if type(author) == "string" and type(counter) == "number" then
                local prev = profile._authorCounters[author] or 0
                if counter > prev then
                    profile._authorCounters[author] = counter
                end
            end
        end
    end

    -- 3) If profile is active, refresh cached/UI state (if your core uses this)
    if SF and SF.lootHelperDB and SF.lootHelperDB.activeProfileId == profileId
        and type(SF.SetActiveProfileById) == "function"
    then
        pcall(function()
            SF:SetActiveProfileById(profileId)
        end)
    end

    return true, nil
end

-- Function Extract stable log id from net table (supports multiple field names)
-- @param t table Log table
-- @return string|nil logId
function Sync:_ExtractLogId(t)
    if type(t) ~= "table" then return nil end
    return t._logId or t.logId or t._id or t.id
end

-- Function Extract author and counter from net table (supports multiple field names)
-- @param t table Log table
-- @return string|nil author
function Sync:_ExtractAuthorCounter(t)
    if type(t) ~= "table" then return nil, nil end
    local author = t._author or t.author
    local counter = t._counter or t.counter
    if type(counter) == "string" then counter = tonumber(counter) end
    counter = tonumber(counter)
    if counter then counter = math.floor(counter) end
    return author, counter
end

-- Function Compute highest contiguous counter prefix we have for an author (1..N with no gaps)
-- @param profileId string Stable profile id
-- @param author string Author name
-- @return number contig Highest contiguous counter (0 if none)
function Sync:_ComputeContigCounter(profileId, author)
    if type(profileId) ~= "string" or profileId == "" then return 0 end
    if type(author) ~= "string" or author == "" then return 0 end

    local profile = self:FindLocalProfileById(profileId)
    if not profile then return 0 end

    local seen = {}

    for _, log in ipairs(profile:GetLootLogs() or {}) do
        local a = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
        if a == author then
            local c = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
            c = tonumber(c)
            if c then
                c = math.floor(c)
                if c >= 1 then
                    seen[c] = true
                end
            end
        end
    end

    local contig = 0
    while seen[contig +1] do
        contig = contig + 1
    end
    return contig
end

-- Function Compute highest contiguous counter prefix we have for all authors.
-- @param profileId string Stable profile id
-- @return table contig Map [author] = highest contiguous counter (0 if none)
function Sync:ComputeContigAuthorMax(profileId)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return {} end

    local seenByAuthor = {}

    for _, log in ipairs(profile:GetLootLogs() or {}) do
        local a = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
        local c = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
        c = tonumber(c)

        if type(a) == "string" and a ~= "" and c and c >= 1 then
            c = math.floor(c)
            local set = seenByAuthor[a]
            if not set then
                set = {}
                seenByAuthor[a] = set
            end
            set[c] = true
        end
    end

    local contig = {}
    for author, set in pairs(seenByAuthor) do
        local n = 0
        while set[n + 1] do
            n = n + 1
        end
        contig[author] = n
    end

    return contig
end

-- Function Detect whether applying a log indicates a gap in the author/counter sequence.
-- @param profileId string Stable profile id
-- @param logTable table Must include author and counter fields
-- @return boolean hasGap True if gap detected, false otherwise
-- @return number|nil gapFrom If hasGap, the starting counter of the gap
-- @return number|nil gapTo If hasGap, the ending counter of the gap
function Sync:DetectGap(profileId, logTable)
    local author, counter = self:_ExtractAuthorCounter(logTable)
    if type(author) ~= "string" or author == "" then return false end
    if type(counter) ~= "number" or counter < 1 then return false end

    local contig = self:_ComputeContigCounter(profileId, author)
    if counter <= (contig + 1) then
        return false
    end

    return true, contig + 1, counter - 1
end

-- Function Check if there is an outstanding log range request for the given profile/author/range.
-- @param profileId string Stable profile id
-- @param author string Author name
-- @param fromCounter number Starting counter of range
-- @param toCounter number Ending counter of range
-- @return boolean True if overlapping request exists, false otherwise
-- Returns true only if an existing request fully covers [fromCounter, toCounter]
function Sync:_HasOutstandingLogRangeRequest(profileId, author, fromCounter, toCounter)
    if type(self.state) ~= "table" then return false end
    if type(self.state.requests) ~= "table" then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end
    if type(author) ~= "string" or author == "" then return false end

    fromCounter = tonumber(fromCounter)
    toCounter = tonumber(toCounter)
    if not fromCounter or not toCounter then return false end

    for _, req in pairs(self.state.requests) do
        if type(req) == "table" and type(req.meta) == "table" then
            if req.kind == "NEED_LOGS" or req.kind == "LOG_REQ" or req.kind == "ADMIN_LOG_REQ" then
                local m = req.meta
                if m.profileId == profileId and m.author == author then
                    local f = tonumber(m.fromCounter)
                    local t = tonumber(m.toCounter)
                    if f and t then
                        -- Suppress only if existing request fully covers new desired range
                        if f <= fromCounter and t >= toCounter then
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

-- Function send a LOG_REQ (admin-to-admin gap repair). This is like _SendAdminLogReq, but works for any admin.
-- @param req table Request state table
-- @param target string "Name-Realm" of target admin
-- @return boolean True if send succeeded, false otherwise
function Sync:_SendLogReq(req, target)
    if not self.state.active then return false end
    if not SF.LootHelperComm then return false end
    if type(target) ~= "string" or target == "" then return false end
    if type(req) ~= "table" or type(req.meta) ~= "table" then return false end

    local meta = req.meta
    local sessionId = meta.sessionId or self.state.sessionId
    local profileId = meta.profileId or self.state.profileId
    if type(sessionId) ~= "string" or sessionId == "" then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end

    -- Only admins should send LOG_REQ (receiver enforces too, but avoid noise)
    local me = SelfId()
    if not self:IsSenderAuthorized(profileId, me) then return false end

    local payload = {
        sessionId   = sessionId,
        profileId   = profileId,
        requestId   = req.id,
        author      = meta.author,
        fromCounter = meta.fromCounter,
        toCounter   = meta.toCounter,
        supportsEnc = meta.supportsEnc,
    }

    return SF.LootHelperComm:Send(
        "CONTROL",
        self.MSG.LOG_REQ,
        payload,
        "WHISPER",
        target,
        "NORMAL"
    )
end

-- Function Spam-guarded gap repair request (used by NEW_LOG handler)
-- Chooses LOG_REQ if we're an admin; otherwise uses NEED_LOGS
-- @param profileId string Stable profile id
-- @param author string Author name
-- @param gapFrom number Starting counter of gap
-- @param gapTo number Ending counter of gap
-- @param reason string|nil Optional reason for logging
-- @return boolean True if request sent, false otherwise
function Sync:RequestGapRepair(profileId, author, gapFrom, gapTo, reason)
    if not self.state.active then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end
    if self.state.profileId and self.state.profileId ~= profileId then return false end
    if type(author) ~= "string" or author == "" then return false end

    gapFrom = tonumber(gapFrom)
    gapTo = tonumber(gapTo)
    if not gapFrom or not gapTo then return false end
    gapFrom = math.max(1, math.floor(gapFrom))
    gapTo = math.max(1, math.floor(gapTo))
    if gapFrom > gapTo then return false end

    -- Suppress only if we already have a request that fully covers this range
    if self:_HasOutstandingLogRangeRequest(profileId, author, gapFrom, gapTo) then
        return false
    end

    -- Per-author cooldown
    self.state.gapRepair = self.state.gapRepair or {}
    local key = ("%s|%s"):format(profileId, author)
    local now = Now()
    local cooldown = tonumber(self.cfg.gapRepairCooldownSec) or 2

    local rec = self.state.gapRepair[key]
    if type(rec) == "table" and type(rec.lastAt) == "number" then
        if (now - rec.lastAt) < cooldown then
            return false
        end
    end

    -- Choose targets (helpers first, coordinator fallback)
    local targets = self:GetRequestTargets(self.state.helpers, self.state.coordinator)
    if not targets or #targets == 0 then return false end

    -- Prefer LOG_REQ if we are an admin; else use NEED_LOGS
    local me = SelfId()
    local canLogReq = self:IsSenderAuthorized(profileId, me)
    local kind = canLogReq and "LOG_REQ" or "NEED_LOGS"

    local requestId = self:NewRequestId()

    local supportsEnc =
        (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
            and SF.SyncProtocol.GetSupportedEncodings()
            or nil

    -- fallback targets (exclude the first, since RegisterRequest adds it separately)
    local fallback = {}
    for i = 2, #targets do fallback[#fallback + 1] = targets[i] end

    local ok = self:RegisterRequest(requestId, kind, targets[1], {
        sessionId   = self.state.sessionId,
        profileId   = profileId,
        author      = author,
        fromCounter = gapFrom,
        toCounter   = gapTo,
        supportsEnc = supportsEnc,
        targets     = fallback,
    })

    if ok then
        self.state.gapRepair[key] = { lastAt = now, fromCounter = gapFrom, toCounter = gapTo }
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Gap repair requested via %s for %s: %s [%d-%d] (%s)",
                tostring(kind), tostring(profileId), tostring(author), gapFrom, gapTo, tostring(reason or "no reason"))
        end
    end

    return ok
end

-- ============================================================================
-- Scheduling helpers (jitter)
-- ============================================================================

-- Function Run a callback after a random jitter delay.
-- @param minMs number Minimum jitter in milliseconds
-- @param maxMs number Maximum jitter in milliseconds
-- @param fn function Callback to run after delay
-- @return any handle Optional timer handle
function Sync:RunWithJitter(minMs, maxMs, fn)
    if type(fn) ~= "function" then return nil end
    minMs = tonumber(minMs) or 0
    maxMs = tonumber(maxMs) or minMs
    if maxMs < minMs then minMs, maxMs = maxMs, minMs end   -- swap if out of order

    local ms = (maxMs > minMs) and math.random(minMs, maxMs) or minMs
    return self:RunAfter(ms / 1000, fn)
end

-- Function Run a callback after a fixed delay (seconds).
-- @param delaySec number Delay in seconds
-- @param fn function Callback to run after delay
-- @return any handle Optional timer handle
function Sync:RunAfter(delaySec, fn)
    if type(fn) ~= "function" then return nil end
    delaySec = tonumber(delaySec) or 0

    if delaySec <= 0 then
        fn()
        return nil
    end

    if C_Timer and C_Timer.NewTimer then
        return C_Timer.NewTimer(delaySec, fn)
    end

    -- Guard: ensure C_Timer.After exists before calling
    if C_Timer and C_Timer.After then
        C_Timer.After(delaySec, fn)
        return nil
    end

    -- Last resort: no timer API available, run synchronously
    fn()
    return nil
end

-- ============================================================================
-- Peer Registry / Roster Helpers
-- ============================================================================

-- Function Generate the next nonce string for messages.
-- @param tag string|nil Optional tag prefix (default: "N")
-- @return string nonce
function Sync:_NextNonce(tag)
    self._nonceCounter = (self._nonceCounter or 0) + 1
    tag = tag or "N"
    return ("%s:%s:%d:%d"):format(tag, SelfId(), Now(), self._nonceCounter)
end

-- Function Get or create a peer record for the given "Name-Realm".
-- @param nameRealm string "Name-Realm"
-- @return table peerRecord
function Sync:GetPeer(nameRealm)
    if type(nameRealm) ~= "string" or nameRealm == "" then return nil end
    self.state.peers = self.state.peers or {}

    local peer = self.state.peers[nameRealm]
    if not peer then
        peer = {
            name = nameRealm,
            inGroup = false,
            online = nil,
            lastSeen = 0,
            proto = nil,
            supportedMin = nil,
            supportedMax = nil,
            addonVersion = nil,
            isAdmin = nil,
            syncState = "UNKNOWN",
            syncStateAt = 0,
            syncStateReason = nil,
        }
        self.state.peers[nameRealm] = peer
    end
    return peer
end

-- Function Update peer record's lastSeen and optional fields.
-- @param nameRealm string "Name-Realm"
-- @param fields table|nil Optional fields to update in peer record
-- @return nil
function Sync:TouchPeer(nameRealm, fields)
    local peer = self:GetPeer(nameRealm)
    if not peer then return end

    peer.lastSeen = Now()
    if type(fields) == "table" then
        for k, v in pairs(fields) do
            peer[k] = v
        end
    end

    -- Advance from UNKNOWN or nil to SEEN, but don't overwrite meaningful states
    if not peer.syncState or peer.syncState == "UNKNOWN" then
        peer.syncState = "SEEN"
        peer.syncStateAt = Now()
    end
end

function Sync:SetPeerSyncState(nameRealm, state, reason)
    local peer = self:GetPeer(nameRealm)
    if not peer then return end

    if peer.syncState ~= state then
        peer.syncState = state
        peer.syncStateAt = Now()
        peer.syncStateReason = reason
    end
end

-- Function Update peer records from current group/raid roster.
-- @param none
-- @return nil
function Sync:UpdatePeersFromRoster()
    self.state.peers = self.state.peers or {}

    -- mark everyone "not inGroup" first; we'll re-mark those we find
    for _, peer in pairs(self.state.peers) do
        peer.inGroup = false
        peer.online = nil
    end

    if IsInRaid() then
        local n = GetNumGroupMembers() or 0
        for i = 1, n do
            local name, rank, subgroup, level, class, fileName, zone, online, isDead, role = GetRaidRosterInfo(i)
            local full = NormalizeNameRealm(name)
            if full then
                local peer = self:GetPeer(full)
                peer.inGroup = true
                peer.online = online
                peer.rank = rank
                peer.subgroup = subgroup
                peer.role = role
            end
        end
    elseif IsInGroup() then
        local function touchUnit(unit)
            local n, r = UnitFullName(unit)
            if not n then return end
            local full = NormalizeNameRealm(r and (n .. "-" .. r) or n)
            if full then
                local peer = self:GetPeer(full)
                peer.inGroup = true
                peer.online = UnitIsConnected(unit)
                peer.role = UnitGroupRolesAssigned(unit)
            end
        end

        touchUnit("player")
        for i = 1, (GetNumSubgroupMembers() or 0) do
            touchUnit("party" .. i)
        end
    end
end

-- Function Mark all in-group peers as having announced for the given sessionId.
-- @param sessionId string Session id
-- @return nil
function Sync:_MarkRosterAnnounced(sessionId)
    if type(sessionId) ~= "string" or sessionId == "" then return end
    self:UpdatePeersFromRoster()

    for _, peer in pairs(self.state.peers or {}) do
        if peer and peer.inGroup then
            peer._lastSessionAnnounced = sessionId
        end
    end
end

-- Function Get the current addon version string.
-- @param none
-- @return string version
function Sync:_GetAddonVersion()
    if SF.GetAddonVersion then
        return SF:GetAddonVersion()
    end
    return "unknown"
end