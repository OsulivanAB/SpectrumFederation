local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

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
    if self._RevokedRouteBlocksIncomingSession and self:_RevokedRouteBlocksIncomingSession(payload) then
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

    -- Same-profile history that ends in removal rejects the new session id
    -- before reset. Reset would drop the tombstone and then rebuild.
    if self._IncomingSameProfileHistoryRevoked and self:_IncomingSameProfileHistoryRevoked(payload) then
        return
    end
    if self._UnprovenCatchUpBlocksNewSession and self:_UnprovenCatchUpBlocksNewSession(payload) then
        return
    end
    if self._FailedCatchUpBlocks and self:_FailedCatchUpBlocks(payload.coordinator, payload.profileId) then
        return
    end

    local wasCoordinator = (self.state.isCoordinator == true)
    local oldSid = self.state.sessionId
    local oldCoord = self.state.coordinator

    -- If switching to a different sessionId, wipe old session state BEFORE applying new session descriptor.
    -- A profile change inside that reset, or without a session-id change, drops the old revocation scope.
    if oldSid and oldSid ~= payload.sessionId then
        if self._RememberUnprovenCatchUpRelease then
            self:_RememberUnprovenCatchUpRelease(oldCoord, payload.coordinator)
        end
        self:_ResetSessionState("session_changed")
    elseif self._ClearRevocationForIncomingScope then
        self:_ClearRevocationForIncomingScope(payload.sessionId, payload.profileId)
    end

    self.state.active = true
    self.state.sessionId = payload.sessionId
    if self._RememberUnprovenCatchUpRelease then
        self:_RememberUnprovenCatchUpRelease(oldCoord, payload.coordinator)
    end
    self.state.profileId = payload.profileId
    self.state.coordinator = payload.coordinator
    self.state.coordEpoch = payload.coordEpoch
    self.state.isCoordinator = self:_SamePlayer(payload.coordinator, self:_SelfId())
    self.state._sessionDescriptorAt = self:_Now()
    if self._NoteAdvertisedCoordinator then
        self:_NoteAdvertisedCoordinator(payload.coordinator)
    end
    self:_PersistSessionState("HandleSessionStart")

    if type(payload.safeMode) == "table" then
        self:_ApplySessionSafeModeFromPayload(payload.safeMode, "SES_START")
    end

    if wasCoordinator and not self.state.isCoordinator then
        self:StopHeartbeatSender("lost coordinator via SES_START")
    end

    if self._MergeAuthorMaxFrontier then
        self:_MergeAuthorMaxFrontier(payload.authorMax)
    elseif type(payload.authorMax) == "table" then
        self.state.authorMax = payload.authorMax
    else
        self.state.authorMax = {}
    end
    if type(payload.authorWindowSummary) == "table" then
        self.state.authorWindowSummary = payload.authorWindowSummary
    else
        self.state.authorWindowSummary = {}
    end

    if type(payload.helpers) == "table" then
        if self.ApplyAdvertisedHelpers then
            self:ApplyAdvertisedHelpers(payload.helpers, "session_start")
        else
            self.state.helpers = payload.helpers
        end
    else
        self.state.helpers = {}
    end

    if self._RememberAdvertisedRCConfigGeneration then
        self:_RememberAdvertisedRCConfigGeneration(payload)
    end
    if self._ApplyAdvertisedRCConfig then
        self:_ApplyAdvertisedRCConfig(payload)
    end

    -- Rebuild immediately when we already have the profile to avoid stale point/member UI.
    local profile = self:FindLocalProfileById(payload.profileId)
    if profile then
        self:RebuildProfile(payload.profileId, "session_start_member")
        if profile.NormalizePersistedLegacyBonusRolls then
            profile:NormalizePersistedLegacyBonusRolls()
        end
    end
    if self.BackfillAutomaticBisOnPromotion then
        self:BackfillAutomaticBisOnPromotion(wasCoordinator, "HandleSessionStart")
    end

    if SF.Debug then
        SF.Debug:Info("SYNC_SESSION", "Session start (role=%s sessionId=%s profileId=%s coordinator=%s pointsSource=derived_logs)",
            self.state.isCoordinator and "coordinator" or "member",
            tostring(payload.sessionId), tostring(payload.profileId), tostring(payload.coordinator))
    end
    self:LogSessionPointsSummary(payload.profileId, "session_start_received")

    -- Reset join status tracking for new session
    self.state._sentJoinStatusForSessionId = nil
    self.state._profileReqInFlight = nil

    self.state.heartbeat = self.state.heartbeat or {}
    local hb = self.state.heartbeat
    if self._RememberCoordinatorKeepalive then
        self:_RememberCoordinatorKeepalive(
            self.state.coordinator,
            self:_CoordinatorKeepaliveBaseline(oldSid, payload.sessionId, oldCoord, self.state.coordinator)
        )
    else
        hb.lastCoordMessageAt = self:_Now()
        hb.missedHeartbeats = 0
    end
    hb.lastTakeoverRound = nil

    self:EnsureHeartbeatMonitor("HandleSessionStart")

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
    if self._IgnoreRevokedCoordinatorControl
        and not (self._OwnerlessRevokedCoordinatorEnd and self:_OwnerlessRevokedCoordinatorEnd(sender, payload.coordinator))
        and self:_IgnoreRevokedCoordinatorControl(sender, payload.coordinator)
    then
        return
    end

    local reason = payload.reason

    self:_ResetSessionState("remote_end:" .. tostring(reason or "unknown"))

    if SF.PrintInfo then
        SF:PrintInfo(("Loot Helper session ended by coordinator (%s)."):format(tostring(reason or "no reason given")))
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
-- @param opts table|nil { preferCoordinatorFirst=bool, preferredTarget=string }
-- @return table targets Ordered list of targets "Name-Realm" to try
function Sync:GetRequestTargets(helpers, coordinator, opts)
    if self._CapUniqueHelpers then
        helpers = self:_CapUniqueHelpers(helpers)
    end
    local targets, seen = {}, {}
    
    local function add(t)
        if type(t) ~= "string" or t == "" then return end
        local key = (self._PlayerIdentityKey and self:_PlayerIdentityKey(t)) or t
        if seen[key] then return end
        seen[key] = true
        table.insert(targets, t)
    end

    -- Simplify: no need for redundant conditional assignment
    local me = self:_SelfId()
    opts = type(opts) == "table" and opts or {}
    local preferCoordinatorFirst = opts.preferCoordinatorFirst == true
    if not preferCoordinatorFirst then
        local warmupSec = tonumber(self.cfg.helperWarmupSec) or 0
        if warmupSec > 0 and type(self.state._sessionDescriptorAt) == "number" then
            preferCoordinatorFirst = (self:_Now() - self.state._sessionDescriptorAt) <= warmupSec
        end
    end

    if type(opts.preferredTarget) == "string" and opts.preferredTarget ~= "" then
        add(opts.preferredTarget)
    end

    if preferCoordinatorFirst then
        if type(coordinator) == "string" and coordinator ~= "" and coordinator ~= me then
            add(coordinator)
        end
    else
        -- 1) Preferred helper for *me* (deterministic)
        local preferred = self:PickHelperForPlayer(me, helpers or {})
        if preferred and preferred ~= me then add(preferred) end

        -- 2) Coordinator fallback
        if type(coordinator) == "string" and coordinator ~= "" and coordinator ~= me then
            add(coordinator)
        end
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

-- Function Record once per session that profile or log sync has no route.
-- Retries keep running. Only the diagnostic is deduplicated, and it stays in debug.
-- @param flag string State field holding the session id already recorded
-- @param message string
-- @param reason string|nil Caller reason
-- @return nil
function Sync:_NoteMissingRoute(flag, message, reason)
    local sessionId = self.state and self.state.sessionId
    local detail = tostring(message)
        .. " (sessionId=" .. tostring(sessionId)
        .. " profileId=" .. tostring(self.state and self.state.profileId)
        .. " reason=" .. tostring(reason) .. ")"
    if type(flag) ~= "string" or type(sessionId) ~= "string" or sessionId == "" then
        if SF.Debug then
            SF.Debug:Warn("SYNC", "%s", detail)
        end
        return
    end
    if self.state[flag] == sessionId then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Suppressed repeat missing-route diagnostic: %s", tostring(message))
        end
        return
    end
    self.state[flag] = sessionId
    if SF.Debug then
        SF.Debug:Warn("SYNC", "%s", detail)
    end
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

    -- Build ordered target list: helpers first, coordinator fallback.
    -- Once the profile is local, drop targets who are no longer canonical admins.
    local targets = (self._CurrentAuthorizedRoutingTargets and self:_CurrentAuthorizedRoutingTargets())
        or self:GetRequestTargets(self.state.helpers, self.state.coordinator)
    if not targets or #targets == 0 then
        self:_NoteMissingRoute("_noProfileTargetWarnedFor", "Cannot request profile: no targets available", reason)
        local profileMissing = not (self.FindLocalProfileById and self:FindLocalProfileById(self.state.profileId))
        if profileMissing and self._RememberPendingProfileSnapshot then
            self:_RememberPendingProfileSnapshot(reason)
        end
        return false
    end
    self.state._noProfileTargetWarnedFor = nil
    self.state.pendingProfileSnapshot = nil

    local requestId = self:NewRequestId()
    local profileMeta = {
        sessionId   = self.state.sessionId,
        targets     = targets,  -- fallback list
        reason      = reason,
    }
    if self._StampUserInitiatedRequest then
        self:_StampUserInitiatedRequest(profileMeta)
    end
    local ok = self:RegisterRequest(requestId, "NEED_PROFILE", targets[1], profileMeta)

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
-- @param opts table|nil Optional metadata for queued/background dispatch
-- @return boolean True if any requests were registered, false otherwise
function Sync:RequestMissingLogs(missingRanges, reason, opts)
    if not self.state.active then return false end
    if not self.state.sessionId then return false end
    if type(self.state.profileId) ~= "string" or self.state.profileId == "" then return false end
    if type(missingRanges) ~= "table" or #missingRanges == 0 then return false end

    opts = type(opts) == "table" and opts or {}
    self:_BindSessionWindowEvidence(missingRanges)

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
            local exactAuthor = range.exactAuthor == true or opts.exactAuthor == true
            self:_UpgradeOutstandingLogRangeEvidence(
                self.state.profileId,
                range.author,
                range.fromCounter,
                range.toCounter,
                range
            )
            if self:_HasOutstandingLogRangeRequest(
                self.state.profileId,
                range.author,
                range.fromCounter,
                range.toCounter,
                exactAuthor
            ) then
                count = count + 1
            else
            local preferredTarget = range.preferredTarget or opts.preferredTarget
            local targetOpts = nil
            if exactAuthor then
                targetOpts = {
                    preferCoordinatorFirst = true,
                    preferredTarget = preferredTarget,
                }
            end
            local targets = (self._CurrentAuthorizedRoutingTargets and self:_CurrentAuthorizedRoutingTargets(targetOpts))
                or self:GetRequestTargets(self.state.helpers, self.state.coordinator, targetOpts)
            if not targets or #targets == 0 then
                self:_NoteMissingRoute("_noLogTargetWarnedFor", "Cannot request missing logs: no targets available", reason)
                if opts.backgroundRepair == true then
                    return false, "no_targets"
                end
                if self.QueueRepairRanges then
                    local rest = {}
                    for j = i, #missingRanges do
                        local candidate = missingRanges[j]
                        if type(candidate) == "table"
                            and type(candidate.author) == "string"
                            and type(candidate.fromCounter) == "number"
                            and type(candidate.toCounter) == "number"
                        then
                            rest[#rest + 1] = candidate
                        end
                        if #rest >= maxRanges then break end
                    end
                    if #rest > 0 then
                        local queued, dropped, retained = self:QueueRepairRanges(self.state.profileId, rest, {
                            mode = "missing",
                            reason = reason or "no-route",
                            preferredTarget = preferredTarget,
                        })
                        if self.state._userInitiatedSync == true
                            and (tonumber(dropped) or 0) > 0
                            and not queued
                            and (tonumber(retained) or 0) == 0
                        then
                            self.state._userSyncRegisterRejected = true
                        end
                    end
                end
                return count > 0
            end
            self.state._noLogTargetWarnedFor = nil

            local requestId = self:NewRequestId()
            local logMeta = self:_CopyExpectedWindowEvidence(range, {
                sessionId   = self.state.sessionId,
                profileId   = self.state.profileId,
                author      = range.author,
                fromCounter = range.fromCounter,
                toCounter   = range.toCounter,
                targets     = targets,  -- fallback list
                backgroundRepair = opts.backgroundRepair == true,
                queueAttempts = tonumber(opts.queueAttempts) or 0,
                reason = reason,
                exactAuthor = exactAuthor,
                preferredTarget = preferredTarget,
            })
            if self._StampUserInitiatedRequest then
                self:_StampUserInitiatedRequest(logMeta)
            end
            local ok = self:RegisterRequest(requestId, "NEED_LOGS", targets[1], logMeta)

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
    -- Return hasProfile, missingRequests table
    if not profileId or type(sessionAuthorMax) ~= "table" then
        return false, {}
    end

    local profile = self:_GetProfile(profileId)
    if not profile then
        return false, {}
    end

    -- Compute local contiguous author max
    local localContig = self:ComputeContigAuthorMax(profileId)
    if not localContig then
        localContig = {}
    end

    -- Compute missing log requests
    local missingRanges = self:ComputeMissingLogRequests(localContig, sessionAuthorMax, self:ComputeAuthorMax(profileId))
    if not missingRanges then
        missingRanges = {}
    end

    return true, missingRanges
end

-- Function Send join status (HAVE_PROFILE, NEED_PROFILE, or NEED_LOGS) to coordinator.
-- @param none
-- @return nil
function Sync:SendJoinStatus()
    if not self.state.active then return end
    if not self.state.sessionId then return end
    if not self.state.coordinator then return end
    if self.state.isCoordinator then return end

    local sid = self.state.sessionId
    local coord = self.state.coordinator
    local profileId = self.state.profileId
    if type(profileId) ~= "string" or profileId == "" then return end
    if type(coord) ~= "string" or coord == "" then return end

    local payloadBase = {
        sessionId       = sid,
        profileId       = profileId,
        supportedMin    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MIN or nil,
        supportedMax    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MAX or nil,
        addonVersion    = self:_GetAddonVersion(),
        supportsEnc     = (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
                            and SF.SyncProtocol.GetSupportedEncodings()
                            or nil,
        localWindowSummary = self:ComputeAuthorWindowSummary(profileId),
    }
    local pendingMutation = self.state._pendingMutationAdvertisement
    if type(pendingMutation) == "table" and pendingMutation.profileId == profileId then
        payloadBase.integrityHint = "mutation"
        payloadBase.mutationRanges = pendingMutation.ranges
        payloadBase.mutationReason = pendingMutation.reason
    end

    local function alreadySent(status)
        return (self.state._sentJoinStatusForSessionId == sid) and (self.state._sentJoinStatusType == status)
    end

    local function markSent(status)
        self.state._sentJoinStatusForSessionId = sid
        self.state._sentJoinStatusType = status
    end

    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        -- Bootstrap from helpers (preferred) or coordinator (fallback)
        self:RequestProfileSnapshot("join-status")

        if SF.Debug then
            SF.Debug:Verbose("SYNC", "SendJoinStatus: no local profile, requesting snapshot (statusOnly=true)", tostring(profileId))
        end

        -- Also tell the coordinator our handshake status, without forcing them to serve data
        if not alreadySent("NEED_PROFILE") then
            markSent("NEED_PROFILE")
            local payload = {}
            for k, v in pairs(payloadBase) do payload[k] = v end
            payload.statusOnly = true
            if SF.LootHelperComm then
                SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_PROFILE, payload, "WHISPER", coord, "NORMAL")
            end
        end
        return
    end

    local localAuthorMax = profile:ComputeAuthorMax() or {}
    payloadBase.localAuthorMax = localAuthorMax
    if self._AttachRCConfigGeneration then
        self:_AttachRCConfigGeneration(payloadBase, profileId)
    end
    payloadBase.rcConfigDirty = profile._rcConfigDirty == true

    local localContig = self:ComputeContigAuthorMax(profileId)
    local remoteAuthorMax = self.state.authorMax or {}
    local missing = self:ComputeMissingLogRequests(localContig, remoteAuthorMax, localAuthorMax)
    self:_AttachExactWindowEvidence(missing, self.state.authorWindowSummary or {})
    local integrityRanges = self:ComputeWindowMismatchRequests(profileId, self.state.authorWindowSummary or {}, localContig)

    if missing and #missing > 0 then
        local filtered = {}
        for _, range in ipairs(missing) do
            if type(range) == "table" then
                local author = range.author
                local fromCounter = range.fromCounter
                local toCounter = range.toCounter
                if type(author) == "string"
                    and type(fromCounter) == "number"
                    and type(toCounter) == "number"
                then
                    self:_UpgradeOutstandingLogRangeEvidence(profileId, author, fromCounter, toCounter, range)
                    if not self:_HasOutstandingLogRangeRequest(profileId, author, fromCounter, toCounter, range.exactAuthor == true) then
                        table.insert(filtered, range)
                    end
                end
            end
        end

        if #filtered > 0 then
            -- Fetch missing logs (helpers preferred for logical catch-up;
            -- exact raw-author ranges prefer the advertising coordinator)
            self:RequestMissingLogs(filtered, "join-status")
        end

        if SF.Debug then
            SF.Debug:Verbose("SYNC", "SendJoinStatus: missing logs detected (count=%d, requested=%d, statusOnly=true)", #missing, #filtered)
        end

        -- Also tell the coordinator our handshake status, without forcing them to serve data
        if not alreadySent("NEED_LOGS") then
            markSent("NEED_LOGS")

            local maxRanges = tonumber(self.cfg.maxMissingRangesPerNeededLogs) or 8
            local capped = {}
            for i, r in ipairs(missing) do
                if i > maxRanges then break end
                if type(r) == "table" then
                    capped[#capped + 1] = r
                end
            end

            local payload = {}
            for k, v in pairs(payloadBase) do payload[k] = v end
            payload.missing = capped
            payload.statusOnly = true

            if SF.LootHelperComm then
                SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_LOGS, payload, "WHISPER", coord, "NORMAL")
            end
        end
        if type(pendingMutation) == "table" and pendingMutation.profileId == profileId then
            self.state._pendingMutationAdvertisement = nil
        end
    end

    if integrityRanges and #integrityRanges > 0 then
        self:RequestIntegrityRepairRanges(profileId, integrityRanges, "join-status")

        if SF.Debug then
            SF.Debug:Verbose("SYNC", "SendJoinStatus: integrity repair requested (count=%d)", #integrityRanges)
        end

        if not alreadySent("NEED_LOGS") then
            markSent("NEED_LOGS")
            local payload = {}
            for k, v in pairs(payloadBase) do payload[k] = v end
            payload.missing = integrityRanges
            payload.statusOnly = true

            if SF.LootHelperComm then
                SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_LOGS, payload, "WHISPER", coord, "NORMAL")
            end
        end
        if type(pendingMutation) == "table" and pendingMutation.profileId == profileId then
            self.state._pendingMutationAdvertisement = nil
        end
    end

    if (missing and #missing > 0) or (integrityRanges and #integrityRanges > 0) then
        return
    end

    if self._CatchUpRCConfigIfNeeded then
        self:_CatchUpRCConfigIfNeeded(profile, "join-status-rc-config")
    end

    if alreadySent("HAVE_PROFILE") then return end
    markSent("HAVE_PROFILE")

    if SF.Debug then
        SF.Debug:Verbose("SYNC", "SendJoinStatus: fully synced, sending HAVE_PROFILE")
    end

    if SF.LootHelperComm then
        SF.LootHelperComm:Send("CONTROL", self.MSG.HAVE_PROFILE, payloadBase, "WHISPER", coord, "NORMAL")
    end

    if type(pendingMutation) == "table" and pendingMutation.profileId == profileId then
        self.state._pendingMutationAdvertisement = nil
    end
end
