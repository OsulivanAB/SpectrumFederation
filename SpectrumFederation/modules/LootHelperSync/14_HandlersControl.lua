local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync


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
    for _, log in ipairs(self:_GetProfileLootLogs(profile)) do
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
        if not conv.finalizeStarted and not conv.finished then
            self:FinalizeAdminConvergence()
        end
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
    local oldSid = self.state.sessionId

    local oldCoord = self.state.coordinator
    local oldEpoch = self.state.coordEpoch

    -- If switching to a different sessionId, wipe old session state BEFORE applying new session descriptor
    if oldSid and oldSid ~= payload.sessionId then
        self:_ResetSessionState("session_changed")
    end

    self.state.active = true
    self.state.sessionId = payload.sessionId
    self.state.profileId = payload.profileId
    self.state.coordinator = payload.coordinator
    self.state.coordEpoch = payload.coordEpoch
    self.state.isCoordinator = self:_SamePlayer(payload.coordinator, self:_SelfId())

    if type(payload.safeMode) == "table" then
        self:_ApplySessionSafeModeFromPayload(payload.safeMode, "SES_REANNOUNCE")
    end

    if wasCoordinator and not self.state.isCoordinator then
        self:StopHeartbeatSender("lost coordinator via COORD_TAKEOVER")
    end

    self.state.authorMax = (type(payload.authorMax) == "table") and payload.authorMax or {}
    self.state.helpers = (type(payload.helpers) == "table") and payload.helpers or {}

    self.state.heartbeat = self.state.heartbeat or {}
    local hb = self.state.heartbeat
    hb.lastCoordMessageAt = self:_Now()
    hb.missedHeartbeats = 0
    hb.lastTakeoverRound = nil

    self:EnsureHeartbeatMonitor("HandleSessionReannounce")

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
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Rejecting heartbeat: sender=%s != coordinator=%s (anti-spoof)",
                tostring(sender), tostring(payload.coordinator))
        end
        return
    end

    -- Epoch gating:
    -- - If different sessionId, accept only if strictly newer epoch
    -- - If same sessionId (or we have none), accept if not older.
    if self.state.active and self.state.sessionId and payload.sessionId ~= self.state.sessionId then
        if not self:IsNewerEpoch(payload.coordEpoch, payload.coordinator) then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting heartbeat: epoch not newer (sessionId changed, incomingEpoch=%s, currentEpoch=%s)",
                    tostring(payload.coordEpoch), tostring(self.state.coordEpoch))
            end
            return
        end
    else
        if not self:IsControlMessageAllowed(payload, sender) then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting heartbeat: epoch gating failed (incomingEpoch=%s, currentEpoch=%s)",
                    tostring(payload.coordEpoch), tostring(self.state.coordEpoch))
            end
            return
        end
    end

    local wasCoordinator = (self.state.isCoordinator == true)
    local oldSid = self.state.sessionId

    local oldCoord = self.state.coordinator
    local oldEpoch = self.state.coordEpoch

    if oldSid and oldSid ~= payload.sessionId then
        self:_ResetSessionState("session_changed")
    end

    if type(payload.safeMode) == "table" then
        self:_ApplySessionSafeModeFromPayload(payload.safeMode, "SES_HEARTBEAT")
    end

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
        if sameStream and last and payload.sentAt < last then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Rejecting heartbeat: older sentAt (sentAt=%s < lastSentAt=%s)",
                    tostring(payload.sentAt), tostring(last))
            end
            return
        end
        hb.lastHeartbeatSentAt = payload.sentAt
    else
        if not sameStream then
            hb.lastHeartbeatSentAt = nil
        end
    end

    if not sameStream then
        if SF.Debug then
            SF.Debug:Info("SYNC", "Heartbeat caused session/coordinator/epoch change (oldSid=%s->%s, oldCoord=%s->%s, oldEpoch=%s->%s)",
                tostring(oldSid), tostring(payload.sessionId), tostring(oldCoord), tostring(payload.coordinator),
                tostring(oldEpoch), tostring(payload.coordEpoch))
        end
    end

    -- Metrics: increment heartbeat received counter (after all validation passed)
    self:_MInc("sync.heartbeat.recv", 1)

    -- Apply session descriptor
    -- We want to keep this lightweight, so we will not touch handshake bookkeeping
    self.state.active   = true
    self.state.sessionId = payload.sessionId
    self.state.profileId = payload.profileId
    self.state.coordinator = payload.coordinator
    self.state.coordEpoch = payload.coordEpoch
    self.state.isCoordinator = self:_SamePlayer(payload.coordinator, self:_SelfId())

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
    hb.lastHeartbeatAt = self:_Now()
    hb.lastCoordMessageAt = self:_Now()
    hb.missedHeartbeats = 0

    self:EnsureHeartbeatMonitor("HandleSessionHeartbeat")

    -- If coordinator/epoch/session changed, allow a re-evaluation
    if (not self:_SamePlayer(oldCoord, self.state.coordinator))
        or (oldEpoch ~= self.state.coordEpoch)
        or (oldSid ~= self.state.sessionId)
    then
        -- Let join-status happen again if needed
        self.state._sentJoinStatusForSessionId = nil
        self.state._sentJoinStatusType = nil

        -- If you had an in-flight profile request, allow a new attempt with updated target
        self.state._profileReqInFlight = nil

        if self._RefreshOutstandingRequestTargets then
            self:_RefreshOutstandingRequestTargets()
        end
    end

    self:TouchPeer(sender, { inGroup = true })

    -- Catch-up logic:
    if not self.state.isCoordinator then
        local now = self:_Now()
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
    self.state.isCoordinator = self:_SamePlayer(payload.coordinator, self:_SelfId())

    if wasCoordinator and not self.state.isCoordinator then
        self:StopHeartbeatSender("lost coordinator via COORD_TAKEOVER")
    end

    -- Allow re-sending join status to the new coordinator
    self.state._sentJoinStatusForSessionId = nil

    self.state.heartbeat = self.state.heartbeat or {}
    local hb = self.state.heartbeat
    hb.lastCoordMessageAt = self:_Now()
    hb.missedHeartbeats = 0
    hb.lastTakeoverRound = nil

    self:EnsureHeartbeatMonitor("HandleSessionStart")

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
    local ok, err = self:ValidateSessionPayload(payload)
    if not ok then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedProfile: validation failed (sender=%s, err=%s)",
                tostring(sender), tostring(err))
        end
        return
    end

    self:_RecordHandshakeReply(sender, payload, "NEED_PROFILE")

    -- Coordinator handshake visibility without forcing a data response
    if payload.statusOnly == true then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedProfile: statusOnly, not serving data (sender=%s)", tostring(sender))
        end
        return
    end

    if not self:IsBulkTransferAllowed() then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedProfile: safe mode blocks bulk transfer (sender=%s)", tostring(sender))
        end
        return false, "safe mode (bulk disabled)"
    end

    -- Serve eligibility: coordinator OR helper
    if not self.state.active then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedProfile: no active session (sender=%s)", tostring(sender))
        end
        return
    end
    if not (self.state.isCoordinator or self:IsSelfHelper()) then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedProfile: not coordinator/helper (sender=%s)", tostring(sender))
        end
        return
    end

    -- Safety: only send to group members (prevents random whisper abuse)
    self:UpdatePeersFromRoster()
    local peer = self:GetPeer(sender)
    if not peer or not peer.inGroup then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedProfile: sender not in group (sender=%s)", tostring(sender))
        end
        return
    end

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
    local ok, err = self:ValidateSessionPayload(payload)
    if not ok then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedLogs: validation failed (sender=%s, err=%s)",
                tostring(sender), tostring(err))
        end
        return
    end

    self:_RecordHandshakeReply(sender, payload, "NEED_LOGS")

    -- Coordinator handshake visibility without forcing a data response
    if payload.statusOnly == true then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedLogs: statusOnly, not serving data (sender=%s)", tostring(sender))
        end
        return
    end

    if not self:IsBulkTransferAllowed() then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedLogs: safe mode blocks bulk transfer (sender=%s)", tostring(sender))
        end
        return false, "safe mode (bulk disabled)"
    end

    -- Serve eligibility: coordinator OR helper
    if not self.state.active then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedLogs: no active session (sender=%s)", tostring(sender))
        end
        return
    end
    if not (self.state.isCoordinator or self:IsSelfHelper()) then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedLogs: not coordinator/helper (sender=%s)", tostring(sender))
        end
        return
    end

    -- Safety: only send to group members
    self:UpdatePeersFromRoster()
    local peer = self:GetPeer(sender)
    if not peer or not peer.inGroup then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleNeedLogs: sender not in group (sender=%s)", tostring(sender))
        end
        return
    end

    if type(payload) ~= "table" or type(payload.missing) ~= "table" then return end

    local profile = self:FindLocalProfileById(self.state.profileId)
    if not profile then return end

    local serveRole = self.state.isCoordinator and "coordinator" or "helper"
    if SF.Debug then
        local rangesCount = #payload.missing
        SF.Debug:Info("SYNC", "Serving missing logs as %s to %s (rangesRequested=%d)",
            tostring(serveRole), tostring(sender), rangesCount)
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
                for _, log in ipairs(self:_GetProfileLootLogs(profile)) do
                    local a = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
                    local c = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
                    c = tonumber(c)
                    if a == author and c and c >= fromC and c <= toC then
                        if log and log.ToTable then
                            table.insert(out, log:ToTable())
                        elseif type(log) == "table" then
                            table.insert(out, log)
                        end
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

    if not self:IsBulkTransferAllowed() then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleLogRequest: safe mode blocks bulk transfer (sender=%s)", tostring(sender))
        end
        return false, "safe mode (bulk disabled)"
    end
    
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
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleLogRequest: sender not authorized (sender=%s, profileId=%s)",
                tostring(sender), tostring(payload.profileId))
        end
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring LOG_REQ from %s for profile %s: not an admin."):format(sender, payload.profileId))
        end
        return
    end

    local profile = self:FindLocalProfileById(payload.profileId)
    if not profile then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "HandleLogRequest: profile not found (sender=%s, profileId=%s)",
                tostring(sender), tostring(payload.profileId))
        end
        return
    end

    local fromC = math.max(1, math.floor(payload.fromCounter))
    local toC = (toCounter and math.floor(toCounter)) or fromC

    if SF.Debug then
        SF.Debug:Info("SYNC", "Serving logs for %s [%d-%d] to %s",
            tostring(payload.author), fromC, toC, tostring(sender))
    end

    local out = {}
    for _, log in ipairs(self:_GetProfileLootLogs(profile)) do
        local author = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
        local counter = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
        counter = tonumber(counter)
        if author == payload.author and counter and counter >= fromC and counter <= toC then
            if log and log.ToTable then
                table.insert(out, log:ToTable())
            elseif type(log) == "table" then
                table.insert(out, log)
            end
        end
    end

    local resp = {
        sessionId   = payload.sessionId,
        profileId   = payload.profileId,
        adminSyncId = payload.adminSyncId,
        requestId   = payload.requestId,
        author      = payload.author,
        fromCounter = fromC,
        toCounter   = toC,
        logs        = out,
    }

    if SF.SyncProtocol and SF.SyncProtocol.PickBestBulkEncoding and SF.LootHelperComm then
        local enc = SF.SyncProtocol.PickBestBulkEncoding(payload.supportsEnc)
        SF.LootHelperComm:Send("BULK", self.MSG.AUTH_LOGS, resp, "WHISPER", sender, "BULK", { enc = enc })
    elseif SF.LootHelperComm then
        SF.LootHelperComm:Send("BULK", self.MSG.AUTH_LOGS, resp, "WHISPER", sender, "BULK")
    end
end

-- Function Handle SAFE_MODE_REQ as coordinator: enable/disable safe mode for session.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, profileId, enabled, reason}
-- @return nil
function Sync:HandleSafeModeRequest(sender, payload)
    if not (self.state and self.state.active and self.state.isCoordinator) then return end
    if type(payload) ~= "table" then return end

    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end

    if not self:IsSenderAuthorized(self.state.profileId, sender) then
        return
    end

    self:SetSessionSafeModeEnabled(payload.enabled == true, payload.reason or "requested", sender)
end

-- Function Handle SAFE_MODE_SET as member: apply safe mode state from coordinator.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, profileId, coordinator, coordEpoch, safeMode={enabled, setBy, reason}}
-- @return nil
function Sync:HandleSafeModeSet(sender, payload)
    if type(payload) ~= "table" then return end

    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end
    
    if type(payload.coordinator) ~= "string" or payload.coordinator == "" then return end
    if type(payload.coordEpoch) ~= "number" then return end

    -- Anti-spoof: must come from coordinator
    if not self:_SamePlayer(sender, payload.coordinator) then return end

    -- Epoch gating
    if not self:IsControlMessageAllowed(payload, sender) then return end

    self:_ApplySessionSafeModeFromPayload(payload.safeMode, "SAFE_MODE_SET")

    if SF.PrintInfo and type(payload.safeMode) == "table" then
        local e = payload.safeMode.enabled == true
        SF:PrintInfo("Session safe mode %s (set by %s).", e and "ENABLED" or "DISABLED", tostring(payload.safeMode.setBy or payload.coordinator))
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
    peer.joinReportedAt = self:_Now()

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

