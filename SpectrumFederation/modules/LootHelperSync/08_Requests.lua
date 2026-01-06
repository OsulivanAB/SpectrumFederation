local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync


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
    if SF.Debug then
        SF.Debug:Verbose("SYNC", "Armed request timer (id=%s, kind=%s, attempt=%d, delaySec=%.2f)",
            tostring(req.id), tostring(req.kind), tonumber(req.attempt) or 0, delay)
    end
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
    if req.paused then return end

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

    self:_MInc("sync.req.send_attempt.total", 1)
    self:_MInc("sync.req.send_attempt.kind." .. tostring(req.kind or "UNKNOWN"), 1)
    self:_MObserve("sync.req.attempt_number.kind." .. tostring(req.kind or "UNKNOWN"), tonumber(req.attempt) or 0)

    local target = self:_PickNextTargetForRequest(req)
    if not target then
        self:_FailRequest(req, "no more targets")
        return
    end

    if SF.Debug then
        local targetsRemaining = 0
        if type(req.targets) == "table" then
            targetsRemaining = #req.targets - (tonumber(req.targetIdx) or 0)
        end
        SF.Debug:Verbose("SYNC", "Sending request attempt (id=%s, kind=%s, attempt=%d/%d, target=%s, remainingTargets=%d, paused=%s)",
            tostring(req.id), tostring(req.kind), tonumber(req.attempt) or 0, tonumber(req.maxRetries) or 0 + 1,
            tostring(target), targetsRemaining, tostring(req.paused or false))
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

    if ok then
        self:_MInc("sync.req.send_ok.total", 1)
        self:_MInc("sync.req.send_ok.kind." .. tostring(req.kind or "UNKNOWN"), 1)
    else
        self:_MInc("sync.req.send_fail.total", 1)
        self:_MInc("sync.req.send_fail.kind." .. tostring(req.kind or "UNKNOWN"), 1)
    end

    if SF.Debug then
        SF.Debug:Verbose("SYNC", "Request send result (id=%s, target=%s, ok=%s)",
            tostring(req.id), tostring(target), tostring(ok))
    end

    -- Even if send fails, we still arm a timer; timeout path will retry
    req.lastSentAt = self:_Now()
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

    if SF.Debug then
        SF.Debug:Info("SYNC", "Request failed (id=%s, kind=%s, attempt=%d/%d, lastTarget=%s, reason=%s)",
            tostring(req.id), tostring(req.kind), tonumber(req.attempt) or 0,
            tonumber(req.maxRetries) or 0 + 1, tostring(req.lastTarget), tostring(reason))
    end

    self:_MInc("sync.req.failed.total", 1)
    self:_MInc("sync.req.failed.kind." .. tostring(req.kind or "UNKNOWN"), 1)
    self:_MInc("sync.req.failed.reason." .. tostring(reason or "UNKNOWN"), 1)
    self:_MetricsUpdateRequestQueueGauges()

    -- If this was a profile bootstrap request, allow a future retry
    if req.kind == "NEED_PROFILE" then
        if self.state._profileReqInFlight == self.state.sessionId then
            self.state._profileReqInFlight = nil
        end
        -- Also allow SendJoinStatus to re-attempt bootstrap later
        if not self:FindLocalProfileById(self.state.profileId) then
            self.state._sentJoinStatusForSessionId = nil
            self.state._sentJoinStatusType = nil
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
        createdAt   = self:_Now(),
        lastSentAt  = nil,
        lastTarget  = nil,
        targets     = targets,
        targetIdx   = 0,
        meta        = meta,
        timer       = nil,
    }

    self.state.requests[requestId] = req

    self:_MInc("sync.req.created.total", 1)
    self:_MInc("sync.req.created.kind." .. tostring(kind), 1)
    self:_MetricsUpdateRequestQueueGauges()

    if SF.Debug then
        local targetList = table.concat(targets, ",")
        if #targetList > 100 then targetList = targetList:sub(1, 97) .. "..." end
        SF.Debug:Verbose("SYNC", "Registered request (id=%s, kind=%s, initialTarget=%s, totalTargets=%d, sessionId=%s)",
            tostring(requestId), tostring(kind), tostring(target), #targets, tostring(meta.sessionId or "none"))
    end

    if self:IsSafeModeEnabled() and self:_RequestKindUsesBulk(req.kind) then
        req.paused = true
        req.pausedReason = "safe_mode"
        if SF.Debug then
            SF.Debug:Info("SYNC", "Request %s paused due to safe mode (kind=%s)", tostring(req.id), tostring(req.kind))
        end
        return true
    end

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

    self:_MInc("sync.req.completed.total", 1)
    self:_MInc("sync.req.completed.kind." .. tostring(req.kind or "UNKNOWN"), 1)

    if SF.Debug then
        SF.Debug:Info("SYNC", "Request completed (id=%s, kind=%s, attempts=%d, lastTarget=%s)",
            tostring(req.id), tostring(req.kind), tonumber(req.attempt) or 0, tostring(req.lastTarget))
    end

    -- RTT stats: created->complete, and lastSend->complete
    local now = self:_Now()
    if type(req.createdAt) == "number" then
        self:_MObserve("sync.req.rtt.created_to_done_sec.kind." .. tostring(req.kind or "UNKNOWN"), now - req.createdAt)
    end
    if type(req.lastSentAt) == "number" then
        self:_MObserve("sync.req.rtt.lastsend_to_done_sec.kind." .. tostring(req.kind or "UNKNOWN"), now - req.lastSentAt)
    end

    -- Attempts used
    self:_MObserve("sync.req.attempts_used.kind." .. tostring(req.kind or "UNKNOWN"), tonumber(req.attempt) or 0)

    self:_MetricsUpdateRequestQueueGauges()

    return true
end

-- Function Handle request timeout; retry against alternate helper or coordinator.
-- @param requestId string
-- @return nil
function Sync:OnRequestTimeout(requestId)
    if type(requestId) ~= "string" or requestId == "" then return end
    local req = self.state.requests and self.state.requests[requestId]
    if not req then return end

    self:_MInc("sync.req.timeout.total", 1)
    self:_MInc("sync.req.timeout.kind." .. tostring(req.kind or "UNKNOWN"), 1)

    if SF.Debug then
        SF.Debug:Verbose("SYNC", "Request timeout: %s (attempt %d)", req.id, req.attempt or 0)
    end

    req.timer = nil
    self:_SendRequestAttempt(req)
end

