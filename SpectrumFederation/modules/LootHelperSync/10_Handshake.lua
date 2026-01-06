local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync


-- Function Broadcast a lightweight session heartbeat
-- Coordinator-only. Does NOT restart handshake bookkeeping
-- @param none
-- @return boolean ok True if sent, false otherwise
function Sync:BroadcastSessionHeartbeat()
    if not (self.state and self.state.active and self.state.isCoordinator) then return false end
    if not SF.LootHelperComm then return false end

    local dist = self:_EnforceGroupedSessionActive("BroadcastSessionHeartbeat")
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
        sentAt      = self:_Now(),
        safeMode    = self:_GetSessionSafeModePayload(),
    }

    local sendOk = SF.LootHelperComm:Send("CONTROL", self.MSG.SES_HEARTBEAT, payload, dist, nil, "NORMAL")
    
    if SF.Debug then
        local helpersCount = type(self.state.helpers) == "table" and #self.state.helpers or 0
        local authorMaxCount = 0
        if type(self.state.authorMax) == "table" then
            for _ in pairs(self.state.authorMax) do authorMaxCount = authorMaxCount + 1 end
        end
        SF.Debug:Verbose("SYNC", "Heartbeat sent (sessionId=%s, profileId=%s, epoch=%s, helpers=%d, authorMaxAuthors=%d, sendOk=%s)",
            tostring(sid), tostring(profileId), tostring(self.state.coordEpoch), helpersCount, authorMaxCount, tostring(sendOk))
    end
    
    -- Metrics: increment heartbeat sent counter
    self:_MInc("sync.heartbeat.sent", 1)
    
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
    if not self:_EnforceGroupedSessionActive("ShouldRunHeartbeatSender") then return false end

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

-- Function Determine whether heartbeat monitor should run (member only).
-- @param none
-- @return boolean True if should run, false otherwise
function Sync:_ShouldRunHeartbeatMonitor()
    if not (self.state and self.state.active) then return false end
    if self.state.isCoordinator then return false end
    if not self:_EnforceGroupedSessionActive("ShouldRunHeartbeatMonitor") then return false end

    if type(self.state.sessionId) ~= "string" or self.state.sessionId == "" then return false end
    if type(self.state.profileId) ~= "string" or self.state.profileId == "" then return false end
    if type(self.state.coordinator) ~= "string" or self.state.coordinator == "" then return false end
    if type(self.state.coordEpoch) ~= "number" then return false end

    -- Must be an authorized admin of the session profile
    local ok = self:CanSelfCoordinate(self.state.profileId)
    if not ok then return false end

    return true
end

-- Function Determine whether heartbeat monitor is currently running.
-- @param none
-- @return boolean True if running, false otherwise
function Sync:IsHeartbeatMonitorRunning()
    local hb = self.state and self.state.heartbeat
    return (type(hb) == "table") and (hb.monitorTimerHandle ~= nil)
end

-- Function Start heartbeat monitor (member only).
-- @param none
-- @return boolean True if started or already running, false otherwise
function Sync:StopHeartbeatMonitor(reason)
    local hb = self.state and self.state.heartbeat
    if type(hb) ~= "table" then return end

    local h = hb.monitorTimerHandle
    hb.monitorTimerHandle = nil

    if h and h.Cancel then
        pcall(function() h:Cancel() end)
    end

    if SF.Debug then
        SF.Debug:Info("SYNC", "Heartbeat monitor stopped (reason: %s)", tostring(reason or "unknown"))
    end
end

-- Function Start heartbeat monitor (member only).
-- @param reason string|nil Reason for starting (for logging)
-- @return boolean True if started or already running, false otherwise
function Sync:_ComputeTakeoverCandidates(profileId)
    if type(profileId) ~= "string" or profileId == "" then return {} end

    local profile = self:FindLocalProfileById(profileId)
    if not profile then return {} end

    local admins = self:_GetProfileAdminUsers(profile)

    -- map normalizedKey -> canonicalName
    -- TODO: It'd nice to have this determined by performance or something. Whoever's system is currently best equipped.
    local adminSet = {}
    for _, a in ipairs(admins) do
        if type(a) == "string" and a ~= "" then
            local full = NormalizeNameRealm(a) or a
            local key = self:_NormalizeNameRealmForCompare(full) or full
            if key and key ~= "" then
                adminSet[key] = full
            end
        end
    end

    self:UpdatePeersFromRoster()

    local coordKey = self:_NormalizeNameRealmForCompare(self.state.coordinator) or ""
    local candidates, seen = {}, {}

    for name, peer in pairs(self.state.peers or {}) do
        if peer and peer.inGroup then
            if peer.online ~= false then
                local full = NormalizeNameRealm(name) or name
                local key = self:_NormalizeNameRealmForCompare(full) or full

                if key and key ~= "" and key ~= coordKey and adminSet[key] then
                    if not seen[key] then
                        seen[key] = true
                        table.insert(candidates, adminSet[key])
                    end                    
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        local ka = self:_NormalizeNameRealmForCompare(a) or a
        local kb = self:_NormalizeNameRealmForCompare(b) or b
        return ka < kb
    end)

    return candidates
end

-- Function Start heartbeat monitor (member only).
-- @param none 
-- @return nil
function Sync:_HeartbeatMonitorTick()
    if not self:_ShouldRunHeartbeatMonitor() then return end

    self.state.heartbeat = self.state.heartbeat or {}
    local hb = self.state.heartbeat

    local interval = tonumber(self.cfg.heartbeatIntervalSec) or 30
    if interval < 5 then interval = 5 end

    local missThreshold = tonumber(self.cfg.heartbeatMissThreshold) or 3
    if missThreshold < 1 then missThreshold = 1 end

    local grace = tonumber(self.cfg.heartbeatGraceSec or self.cfg.heartbeatMissGrace) or 0
    if grace < 0 then grace = 0 end

    local lastSeen = math.max(tonumber(hb.lastHeartbeatAt) or 0, tonumber(hb.lastCoordMessageAt) or 0)
    local now = self:_Now()

    -- If we just joined via SES_START/REANNOUNCE and haven't recorded seenAt yet, baseline to now so we don't instantly "timeout"
    if lastSeen <= 0 then
        hb.lastCoordMessageAt = now
        hb.missedHeartbeats = 0
        return
    end

    local elapsed = now - lastSeen
    hb.missedHeartbeats = math.floor(elapsed / interval)

    local thresholdSec = (missThreshold * interval) + grace
    if elapsed <= thresholdSec then
        return
    end

    -- round=1 for (thresholdSec .. thresholdSec+interval)
    -- round=2 for (thresholdSec+interval .. thresholdSec2*interval), etc.
    local round = math.floor((elapsed - thresholdSec) / interval) + 1

    local candidates = self:_ComputeTakeoverCandidates(self.state.profileId)
    if not candidates or #candidates == 0 then
        return
    end

    local idx = ((round - 1) % #candidates) + 1
    local winner = candidates[idx]

    if SF.Debug then
        local candidateList = table.concat(candidates, ",")
        if #candidateList > 150 then candidateList = candidateList:sub(1, 147) .. "..." end
        SF.Debug:Verbose("SYNC", "Heartbeat threshold exceeded (elapsed=%.1fs, threshold=%.1fs, round=%d, candidates=%d, winner=%s, me=%s)",
            elapsed, thresholdSec, round, #candidates, tostring(winner), tostring(self:_SelfId()))
    end

    local me = self:_SelfId()
    if not self:_SamePlayer(winner, me) then
        return
    end

    -- Only attempt once per round (prevents retry spam if monitor ticks more than once/round)
    if hb.lastTakeoverRound == round then
        return
    end
    hb.lastTakeoverRound = round
    hb.takeoverAttemptedAt = now

    local sid = self.state.sessionId
    local pid = self.state.profileId
    local expectedCoord = self.state.coordinator
    local expectedEpoch = self.state.coordEpoch
    local lastSeenSnapshot = lastSeen

    -- Small jitter to help avoid rare edge cases where two admins disagree on roster order
    self:RunWithJitter(0, 500, function()
        if not self:_ShouldRunHeartbeatMonitor() then return end
        if self.state.sessionId ~= sid or self.state.profileId ~= pid then return end
        if not self:_SamePlayer(self.state.coordinator, expectedCoord) then return end
        if self.state.coordEpoch ~= expectedEpoch then return end

        -- Abort if we saw coordinator activity since we decided
        local hb2 = self.state.heartbeat or {}
        local last2 = math.max(tonumber(hb2.lastHeartbeatAt) or 0, tonumber(hb2.lastCoordMessageAt) or 0)
        if last2 > lastSeenSnapshot then return end

        if SF.Debug then
            SF.Debug:Info("SYNC",
                "Heartbeat timeout takeover: round=%d/%d winner=%s (self). Taking over session %s profileId=%s",
                tonumber(round) or 0, #candidates, tostring(me), tostring(sid), tostring(pid))
        end

        -- Metrics: increment takeover attempt
        self:_MInc("sync.heartbeat.takeover_attempt", 1)

        local takeoverResult = self:TakeoverSession(sid, pid, "heartbeat-timeout", { rerunAdminConvergence = true })
        
        -- Metrics: increment takeover win if successful
        if takeoverResult == true then
            self:_MInc("sync.heartbeat.takeover_win", 1)
        end
    end)
end

-- Function Start heartbeat monitor (member only).
-- @param reason string|nil Reason for starting (for logging)
-- @return boolean True if started or already running, false otherwise
function Sync:StartHeartbeatMonitor(reason)
    if not self:_ShouldRunHeartbeatMonitor() then
        self:StopHeartbeatMonitor("start_denied:" .. tostring(reason or "unknown"))
        return false
    end

    if self:IsHeartbeatMonitorRunning() then return true end

    self.state.heartbeat = self.state.heartbeat or {}
    local hb = self.state.heartbeat

    local interval = tonumber(self.cfg.heartbeatIntervalSec) or 30
    if interval < 5 then interval = 5 end

    -- Check more frequently than the heartbeat interval to reduce takeover delay,
    -- but still "round" progresses on heartbeatIntervalSec.
    local monitorInterval = math.min(interval, math.max(5, math.floor(interval / 2)))

    -- Capture identity so this monitor instance self-terminates cleanly if session change
    local sid = self.state.sessionId
    local epoch = tonumber(self.state.coordEpoch) or 0
    local coord = self.state.coordinator
    local pid = self.state.profileId

    local function tick()
        if not self:_ShouldRunHeartbeatMonitor() then
            self:StopHeartbeatMonitor("tick_conditions_failed")
            return
        end
        if self.state.sessionId ~= sid then
            self:StopHeartbeatMonitor("tick_session_changed")
            return
        end
        if (tonumber(self.state.coordEpoch) or 0) ~= epoch then
            self:StopHeartbeatMonitor("tick_epoch_changed")
            return
        end
        if self.state.coordinator ~= coord then
            self:StopHeartbeatMonitor("tick_coordinator_changed")
            return
        end
        if self.state.profileId ~= pid then
            self:StopHeartbeatMonitor("tick_profile_changed")
            return
        end

        self:_HeartbeatMonitorTick()
    end

    if C_Timer and C_Timer.NewTicker then
        hb.monitorTimerHandle = C_Timer.NewTicker(monitorInterval, tick)
    else
        -- Fallback (rare): emulate ticker with recurring timers
        local cancelled = false
        local handle = {}
        function handle:Cancel() cancelled = true end
        hb.monitorTimerHandle = handle

        local function loop()
            if cancelled then return end
            tick()
            if cancelled then return end
            self:RunAfter(monitorInterval, loop)
        end

        self:RunAfter(monitorInterval, loop)
    end

    -- Run one immediate evaluation so we don't wait a whole monitorInterval to react
    tick()

    if SF.Debug then
        SF.Debug:Info("SYNC", "Heartbeat monitor started (monitorInterval=%ss, reason=%s)", tostring(monitorInterval), tostring(reason or "unknown"))
    end

    return true
end

-- Backwards-compatible alias (older call sites may use this casing)
function Sync:StartheartbeatMonitor(reason)
    return self:StartHeartbeatMonitor(reason)
end

-- Function Ensure heartbeat monitor is running or stopped as appropriate.
-- @param reason string|nil Reason for starting/stopping (for logging)
-- @return boolean True if running, false otherwise
function Sync:EnsureHeartbeatMonitor(reason)
    if self:_ShouldRunHeartbeatMonitor() then
        return self:StartHeartbeatMonitor(reason)
    end
    self:StopHeartbeatMonitor(reason)
    return false
end

-- Function Broadcast coordinator takeover message (COORD_TAKEOVER).
-- @param none
-- @return nil
function Sync:BroadcastCoordinatorTakeover()
    if not self.state.active or not self.state.isCoordinator then return end

    local dist = self:_EnforceGroupedSessionActive("BroadcastCoordinatorTakeover")
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

    if SF.Debug then
        SF.Debug:Info("SYNC", "Finalized handshake window (sessionId=%s, profileId=%s, have=%d, needProfile=%d, needLogs=%d, noResponse=%d)",
            tostring(self.state.sessionId), tostring(self.state.profileId), have, needProf, needLogs, noResp)
    end
end

