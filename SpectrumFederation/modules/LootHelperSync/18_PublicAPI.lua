local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync


-- Function Initialize sync system (state + transport + event wiring).
-- @param cfg table|nil Optional config overrides (jitter/timeouts/retries).
-- @return nil
function Sync:Init(cfg)
    if type(cfg) == "table" then
        self:SetConfig(cfg)
    end

    self:Enable()
end

-- Function Enable syncing behavior (safe to call multiple times).
-- @param none
-- @return nil
function Sync:Enable()
    if self._enabled then
        -- Still re-evaluate scoping + timers when calle again
        self:UpdatePeersFromRoster()
        self:_EnforceGroupedSessionActive("Enable(reenter)")
        self:EnsureHeartbeatSender("Enable(reenter)")
        self:EnsureHeartbeatMonitor("Enable(reenter)")
        return
    end
    self._enabled = true

    self:_InstallMetricsSendHook()
    self:_InstallDebugSlashCommands()

    -- Create a tiny event frame for the two "reliable places"
    if not self._eventFrame then
        local frameName = (addonName and (addonName .. "_LootHelperSyncFrame")) or nil
        local f = CreateFrame("Frame", frameName)
        self._eventFrame = f

        f:SetScript("OnEvent", function(_, event, ...)
            if event == "GROUP_ROSTER_UPDATE" then
                self:OnGroupRosterUpdate()
            elseif event == "PLAYER_ENTERING_WORLD" then
                self:OnPlayerEnteringWorld(...)
            elseif event == "PLAYER_REGEN_DISABLED" then    -- Entering Combat
                self:OnPlayerRegenDisabled()
            end
        end)
    end

    self._eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    self._eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    self._eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Entering Combat

    self:UpdatePeersFromRoster()
    self:_EnforceGroupedSessionActive("Enable")
    self:EnsureHeartbeatSender("Enable")
    self:EnsureHeartbeatMonitor("Enable")
end

-- Function Disable syncing behavior; does not delete local data.
-- @param none
-- @return nil
function Sync:Disable()
    self._enabled = false

    if self._eventFrame then
        pcall(function() self._eventFrame:UnregisterEvent("GROUP_ROSTER_UPDATE") end)
        pcall(function() self._eventFrame:UnregisterEvent("PLAYER_ENTERING_WORLD") end)
        pcall(function() self._eventFrame:UnregisterEvent("PLAYER_REGEN_DISABLED") end)
    end

    -- Stop timers and clear session state locally
    self:StopHeartbeatSender("Disable")
    self:StopHeartbeatMonitor("Disable")

    if self.state and (self.state.active or self.state.sessionId) then
        self:_ResetSessionState("Disable")
    end
end

-- Function Update runtime config (jitter, timeouts, retry counts).
-- @param cfg table Config fields to override.
-- @return nil
function Sync:SetConfig(cfg)
    if type(cfg) ~= "table" then return end
    self.cfg = self.cfg or {}
    for k, v in pairs(cfg) do
        self.cfg[k] = v
    end
end

-- Function Return current runtime config.
-- @param none
-- @return table Current config.
function Sync:GetConfig()
    self.cfg = self.cfg or {}
    return self.cfg
end

-- Function Returns whether an SF Loot Helper session is currently active.
-- @param none
-- @return boolean True if active, false otherwise.
function Sync:IsSessionActive()
    if not (self.state and self.state.active) then return false end
    if GetGroupDistribution() then return true end

    -- If we aren't grouped, enforce invariant
    self:_EnforceGroupedSessionActive("IsSessionActive")
    return false
end

-- Function Returns current sessionId (or nil).
-- @param none
-- @return string|nil Current sessionId.
function Sync:GetSessionId()
    return self:IsSessionActive() and self.state.sessionId or nil
end

-- Function Returns active session profileId (or nil).
-- @param none
-- @return string|nil Current session profileId.
function Sync:GetSessionProfileId()
    return self:IsSessionActive() and self.state.profileId or nil
end

-- Function Returns current coordinator "Name-Realm" (or nil).
-- @param none
-- @return string|nil Current coordinator.
function Sync:GetCoordinator()
    return self:IsSessionActive() and self.state.coordinator or nil
end

-- Function Returns current coordinator epoch (or nil).
-- @param none
-- @return number|nil Current coordinator epoch.
function Sync:GetCoordEpoch()
    return self:IsSessionActive() and self.state.coordEpoch or nil
end

-- Function Returns helpers list (array of "Name-Realm").
-- @param none
-- @return table Helpers list.
function Sync:GetHelpers()
    if not self:IsSessionActive() then return {} end
    return self.state.helpers or {}
end

-- Function Set whether session safe mode is enabled.
-- @param enabled boolean True to enable, false to disable.
-- @param reason string|nil Human-readable reason for change.
-- @param setBy string|nil "Name-Realm" of who set it (defaults to self)
-- @return boolean success, string|nil errorReason
function Sync:SetSessionSafeModeEnabled(enabled, reason, setBy)
    if not(self.state and self.state.active and self.state.isCoordinator) then
        return false, "not coordinator"
    end

    -- Coordinator must be admin (defensive in case of future changes)
    local me = self:_SelfId()
    if not self:IsSenderAuthorized(self.state.profileId, me) then
        return false, "not authorized"
    end

    enabled = (enabled == true)

    local sm = self:_EnsureSafeModeState()
    if (sm.sessionEnabled == true) == enabled then
        return true, "no_change"
    end

    sm.sessionEnabled = enabled
    sm.sessionRev = (tonumber(sm.sessionRev) or 0) + 1
    sm.sessionSetBy = setBy or me
    sm.sessionSetAt = self:_Now()
    sm.sessionReason = reason or (enabled and "enabled" or "disabled")

    self:_RecomputeSafeMode("session_set_by_coordinator:" .. tostring(reason or "manual"))

    local dist = self:_EnforceGroupedSessionActive("SetSessionSafeModeEnabled")
    if dist and SF.LootHelperComm then
        local payload = {
            sessionId   = self.state.sessionId,
            profileId   = self.state.profileId,
            coordinator = self.state.coordinator,
            coordEpoch  = self.state.coordEpoch,
            safeMode    = self:_GetSessionSafeModePayload(),
        }
        SF.LootHelperComm:Send(
            "CONTROL",
            self.MSG.SAFE_MODE_SET,
            payload,
            dist,
            nil,
            "ALERT"
        )
    end

    return true, nil
end

-- Function Request to set session safe mode (admin entrypoint).
-- @param enabled boolean True to enable, false to disable.
-- @param reason string|nil Human-readable reason for change.
-- @return boolean success, string|nil errorReason
function Sync:RequestSessionSafeMode(enabled, reason)
    if not (self.state and self.state.active) then return false, "no active session" end
    if type(self.state.coordinator) ~= "string" or self.state.coordinator == "" then return false, "no coordinator" end

    enabled = (enabled == true)

    -- If we have the profile locally, enforce admin gate locally too.
    local me = self:_SelfId()
    if self:FindLocalProfileById(self.state.profileId) then
        if not self:IsSenderAuthorized(self.state.profileId, me) then
            return false, "not authorized"
        end
    end

    if self.state.isCoordinator then
        return self:SetSessionSafeModeEnabled(enabled, reason, me)
    end

    if not SF.LootHelperComm then return false, "comm not available" end

    local payload = {
        sessionId   = self.state.sessionId,
        profileId   = self.state.profileId,
        coordinator = self.state.coordinator,
        coordEpoch  = self.state.coordEpoch,
        
        enabled     = enabled,
        reason      = reason,
        requestedBy = me,
        requestedAt = self:_Now(),
    }

    SF.LootHelperComm:Send(
        "CONTROL",
        self.MSG.SAFE_MODE_REQ,
        payload,
        "WHISPER",
        self.state.coordinator,
        "ALERT"
    )

    return true, nil
end

-- Function Toggle session safe mode enabled state.
-- @param reason string|nil Human-readable reason for change.
-- @return boolean success, string|nil errorReason
function Sync:ToggleSessionSafeMode(reason)
    local sm = self:_EnsureSafeModeState()
    return self:RequestSessionSafeMode(not (sm.sessionEnabled == true), reason or "toggle")
end

-- Function Called when group/raid roster changes. If someone joins and a session is already started, send them the info the equivalent of SES_REANNOUNCE
-- @param none
-- @return nil
function Sync:OnGroupRosterUpdate()
    -- Always keep per roster fresh
    self:UpdatePeersFromRoster()

    if not self:_EnforceGroupedSessionActive("OnGroupRosterUpdate") then return end

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

    local me = self:_SelfId()

    -- Build a single payload to reuse
    self.state.authorMax = self:ComputeAuthorMax(profileId) or (self.state.authorMax or {})
    local payload = {
        sessionId   = sid,
        profileId   = profileId,
        coordinator = self.state.coordinator,
        coordEpoch  = self.state.coordEpoch,
        authorMax   = self.state.authorMax,
        helpers     = self.state.helpers or {},
        safeMode    = self:_GetSessionSafeModePayload(),
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
    self:EnsureHeartbeatMonitor("OnGroupRosterUpdate")
end

-- Function Called when player enters world (reload, zone change, ect.)
-- @param none
-- @return nil
function Sync:OnPlayerEnteringWorld()
    self:UpdatePeersFromRoster()

    local dist = self:_EnforceGroupedSessionActive("PLAYER_ENTERING_WORLD")
    if not dist then return end

    self:EnsureHeartbeatSender("PLAYER_ENTERING-WORLD")
    self:EnsureHeartbeatMonitor("PLAYER_ENTERING-WORLD")
end

-- Function Called when player enters combat.
-- @param none
-- @return nil
function Sync:OnPlayerRegenDisabled()
    -- Only meaningful if we are in an active session
    if not (self.state and self.state.active) then return end

    -- 1) USER-SCOPED auto LOCAL safe mode on combat
    if self:GetAutoLocalSafeModeOnCombatEnabled() then
        local sm = self:_EnsureSafeModeState()
        if sm.localEnabled ~= true then
            self:SetLocalSafeModeEnabled(true, "combat_auto_enable")
        end
    end

    -- 2) PROFILE-SCOPED auto SESSION safe mode on combat (coordinator-only)
    if not (
        self.state
        and self.state.active
        and self.state.isCoordinator
        and self.cfg
        and self.cfg.autoSessionSafeModeOnCombat == true
    ) then return end

    local sm = self:_EnsureSafeModeState()
    if sm.sessionEnabled == true then return end

    self:SetSessionSafeModeEnabled(true, "combat_auto_enable", self:_SelfId())
end

-- Function Start a new SF Loot Helper session as coordinator (Sequence 1 -> 2).
-- @param profileId string Stable profile id to use for this session
-- @param opts table|nil Optional: forceStart, skipPrompt, customHelpers, ect.
-- @return string sessionId
function Sync:StartSession(profileId, opts)
    opts = opts or {}
    local dist = self:_EnforceGroupedSessionActive("StartSession")
    if not dist then
        if SF.PrintError then SF:PrintError("Cannot start session: not in a group/raid.") end
        return nil
    end

    local ok, why = self:CanSelfCoordinate(profileId)
    if not ok then
        if SF.PrintError then SF:PrintError("Cannot start session: %s", tostring(why or "unknown reason")) end
        return nil
    end

    local me = self:_SelfId()
    local sessionId = self:_NextNonce("SES")
    local epoch = self:_Now()

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

    self:_ResetSessionSafeMode("StartSession")
    self:_ResetLocalSafeMode("StartSession")

    self:UpdatePeersFromRoster()
    self:TouchPeer(me, { inGroup = true, isAdmin = true })

    self:BeginAdminConvergence(sessionId, profileId)

    return sessionId
end

-- Function Reset all session state (called on EndSession and internal resets).
-- @param reason string|nil Human-readable reason for reset.
-- @return nil
function Sync:_ResetSessionState(reason)
    if SF.Debug then
        local outstandingReqCount = 0
        if type(self.state.requests) == "table" then
            for _ in pairs(self.state.requests) do outstandingReqCount = outstandingReqCount + 1 end
        end
        SF.Debug:Info("SYNC", "Resetting session state (reason=%s, hadSession=%s, sessionId=%s, coordinator=%s, outstandingRequests=%d)",
            tostring(reason), tostring(self.state.active), tostring(self.state.sessionId),
            tostring(self.state.coordinator), outstandingReqCount)
    end

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
    self.state._sentJoinStatusType = nil
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

    -- Reset session-wide safe mode and local (session-scoped) safe mode
    self:_ResetSessionSafeMode("ResetSessionState")
    self:_ResetLocalSafeMode("ResetSessionState")

    -- Clear heartbeat state and stop any heartbeat timer/ticker
    do
        local hb = self.state.heartbeat
        if type(hb) == "table" then
            if hb.heartbeatTimerHandle and hb.heartbeatTimerHandle.Cancel then
                pcall(function() hb.heartbeatTimerHandle:Cancel() end)
            end
            hb.heartbeatTimerHandle = nil

            if hb.monitorTimerHandle and hb.monitorTimerHandle.Cancel then
                pcall(function() hb.monitorTimerHandle:Cancel() end)
            end
            hb.monitorTimerHandle = nil

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

    if SF.Debug then
        SF.Debug:Info("SYNC", "Ending session (reason=%s, broadcast=%s, wasCoordinator=%s)",
            tostring(reason), tostring(broadcast), tostring(self.state.isCoordinator))
    end

    local dist = self:_EnforceGroupedSessionActive("EndSession")

    if broadcast and self.state.isCoordinator and dist and SF.LootHelperComm then
        local payload = {
            sessionId   = self.state.sessionId,
            profileId   = self.state.profileId,
            coordinator = self.state.coordinator,
            coordEpoch  = self.state.coordEpoch,
            reason      = reason,
            endAt       = self:_Now(),
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

    local dist = self:_EnforceGroupedSessionActive("TakeoverSession")
    if not dist then return false end
    if type(sessionId) ~= "string" or sessionId == "" then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end

    -- Clear convergence state so we don't inherit stale admin statuses / pending convergence
    self.state.adminStatuses = {}
    self.state._adminConvergence = nil
    self.state.handshake = nil
    self.state._sessionAnnounced = nil

    local me = self:_SelfId()
    local oldEpoch = tonumber(self.state.coordEpoch) or 0

    self.state.active = true
    self.state.sessionId = sessionId
    self.state.profileId = profileId
    self.state.coordinator = me
    self.state.isCoordinator = true

    -- Ensure strictly increasing epoch
    local newEpoch = self:_Now()
    if newEpoch <= oldEpoch then
        newEpoch = oldEpoch + 1
    end
    self.state.coordEpoch = newEpoch

    if SF.Debug then
        SF.Debug:Info("SYNC", "Takeover session (sessionId=%s, profileId=%s, reason=%s, oldEpoch=%s, newEpoch=%s)",
            tostring(sessionId), tostring(profileId), tostring(reason), tostring(oldEpoch), tostring(newEpoch))
    end

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

    local dist = self:_EnforceGroupedSessionActive("ReannounceSession")
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
        safeMode    = self:_GetSessionSafeModePayload(),
    }

    if SF.Debug then
        local helpersCount = type(self.state.helpers) == "table" and #self.state.helpers or 0
        local authorMaxCount = 0
        if type(self.state.authorMax) == "table" then
            for _ in pairs(self.state.authorMax) do authorMaxCount = authorMaxCount + 1 end
        end
        local safeModeEnabled = self:IsSessionSafeModeEnabled()
        SF.Debug:Info("SYNC", "Reannouncing session (sessionId=%s, profileId=%s, coordinator=%s, epoch=%s, helpers=%d, authorMaxAuthors=%d, safeMode=%s)",
            tostring(self.state.sessionId), tostring(profileId), tostring(self.state.coordinator),
            tostring(self.state.coordEpoch), helpersCount, authorMaxCount, tostring(safeModeEnabled))
    end

    -- restart handshake bookkeeping window
    self.state.handshake = {
        sessionId   = self.state.sessionId,
        startedAt   = self:_Now(),
        deadlineAt  = self:_Now() + (self.cfg.handshakeCollectSec or 3),
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

