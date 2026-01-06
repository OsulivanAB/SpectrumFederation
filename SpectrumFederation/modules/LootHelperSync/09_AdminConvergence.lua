local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

-- ============================================================================
-- Coordinator responsibilities (Sequence 1 and 2)
-- ============================================================================

-- @param profileId string Current session profile id.
-- @return nil
function Sync:BeginAdminConvergence(sessionId, profileId, opts)
    opts = opts or {}
    if not self.state.active or not self.state.isCoordinator then return end

    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        -- If the leader somehow doesn't have the profile, call completion hook
        if SF.Debug then
            SF.Debug:Warn("SYNC", "BeginAdminConvergence: no profile found (profileId=%s), calling completion hook",
                tostring(profileId))
        end
        local completionHook = opts.onComplete or function() self:BroadcastSessionStart() end
        completionHook()
        return
    end

    local adminSyncId = self:_NextNonce("AS")
    local mode = (opts.onComplete and "REANNOUNCE") or "START"
    
    -- Who do we ask?
    local admins = self:_GetProfileAdminUsers(profile)
    local me = self:_SelfId()
    
    local adminList = {}
    for _, admin in ipairs(admins) do
        if admin ~= me then
            table.insert(adminList, admin)
        end
    end
    
    if SF.Debug then
        SF.Debug:Info("SYNC", "Beginning admin convergence (mode=%s, adminSyncId=%s, targetAdmins=%d)",
            tostring(mode), tostring(adminSyncId), #adminList)
    end

    self.state._adminConvergence = {
        adminSyncId     = adminSyncId,
        startedAt       = self:_Now(),
        deadlineAt      = self:_Now() + (self.cfg.adminConvergenceCollectSec or 1.5),
        expected        = {}, -- [admin] = true
        pendingReq      = {}, -- [admin] = true
        pendingCount    = 0,
        finished        = false,
        onComplete      = opts.onComplete or function() self:BroadcastSessionStart() end,
    }

    -- Who do we ask?
    local admins = self:_GetProfileAdminUsers(profile)
    local me = self:_SelfId()

    for _, admin in ipairs(admins) do
        if admin ~= me then
            self.state._adminConvergence.expected[admin] = true
            if SF.LootHelperComm then
                local sendOk = SF.LootHelperComm:Send("CONTROL", self.MSG.ADMIN_SYNC, {
                    sessionId       = sessionId,
                    profileId       = profileId,
                    adminSyncId     = adminSyncId,
                }, "WHISPER", admin, "NORMAL")
                if SF.Debug then
                    SF.Debug:Verbose("SYNC", "Sent ADMIN_SYNC to %s (adminSyncId=%s, ok=%s)",
                        tostring(admin), tostring(adminSyncId), tostring(sendOk))
                end
            end
        end
    end

    -- After collection window, finalize no matter what
    local sid = sessionId
    self:RunAfter(self.cfg.adminConvergenceCollectSec or 1.5, function()
        if not self.state.active or not self.state.isCoordinator then return end
        if self.state.sessionId ~= sid then return end
        local conv = self.state._adminConvergence
        if not conv or conv.finished or conv.finalizeStarted then return end
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

    -- Guard against duplicate finalization
    if conv.finalizeStarted then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Admin convergence finalization already started, skipping duplicate call")
        end
        return
    end
    conv.finalizeStarted = true

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
                maxcounter = tonumber(maxcounter)
                if type(author) == "string" and author ~= "" and maxcounter then
                    local prev = tonumber(targetMax[author]) or 0
                    if maxcounter > prev then
                        targetMax[author] = maxcounter
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

    if SF.Debug then
        local localMaxCount = 0
        for _ in pairs(localMax) do localMaxCount = localMaxCount + 1 end
        local adminStatusCount = 0
        for _ in pairs(self.state.adminStatuses or {}) do adminStatusCount = adminStatusCount + 1 end
        local targetMaxCount = 0
        for _ in pairs(targetMax) do targetMaxCount = targetMaxCount + 1 end
        SF.Debug:Info("SYNC", "Finalized admin convergence (localMaxAuthors=%d, adminStatusesReceived=%d, targetMaxAuthors=%d, missingRanges=%d, pendingRequests=%d, helpersChosen=%d)",
            localMaxCount, adminStatusCount, targetMaxCount, #missing, conv.pendingCount, #(self.state.helpers or {}))
    end

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

    local me = self:_SelfId()
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

    local dist = self:_EnforceGroupedSessionActive("StartSession")
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
        safeMode    = self:_GetSessionSafeModePayload(),
    }

    if SF.Debug then
        local helpersCount = type(self.state.helpers) == "table" and #self.state.helpers or 0
        local authorMaxCount = 0
        if type(self.state.authorMax) == "table" then
            for _ in pairs(self.state.authorMax) do authorMaxCount = authorMaxCount + 1 end
        end
        SF.Debug:Info("SYNC", "Broadcasting session start (sessionId=%s, profileId=%s, coordinator=%s, epoch=%s, helpers=%d, authorMaxAuthors=%d)",
            tostring(self.state.sessionId), tostring(profileId), tostring(self.state.coordinator),
            tostring(self.state.coordEpoch), helpersCount, authorMaxCount)
    end

    -- reset handshake bookkeeping
    self.state.handshake = {
        sessionId = self.state.sessionId,
        startedAt = self:_Now(),
        deadlineAt = self:_Now() + (self.cfg.handshakeCollectSec or 3),
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
