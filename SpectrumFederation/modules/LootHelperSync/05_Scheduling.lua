local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

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

function Sync:_EnsureRepairQueueState()
    self.state = self.state or {}
    self.state.repairQueue = self.state.repairQueue or {}
    self.state.repairQueue.order = self.state.repairQueue.order or {}
    self.state.repairQueue.items = self.state.repairQueue.items or {}
    self.state.convergence = self.state.convergence or {}
    return self.state.repairQueue, self.state.convergence
end

function Sync:_MakeRepairQueueKey(profileId, author, fromCounter, toCounter, mode)
    return table.concat({
        tostring(profileId or ""),
        tostring(author or ""),
        tostring(tonumber(fromCounter) or 0),
        tostring(tonumber(toCounter) or 0),
        tostring(mode or "missing"),
    }, "|")
end

function Sync:_ComputeQueuedRepairBackoffSec(attempt)
    local base = tonumber(self.cfg and self.cfg.convergenceRetryBaseSec) or 12
    local cap = tonumber(self.cfg and self.cfg.convergenceRetryMaxSec) or 90
    attempt = math.max(0, tonumber(attempt) or 0)
    local delay = base * (2 ^ math.max(0, attempt - 1))
    if delay > cap then
        delay = cap
    end
    return delay
end

function Sync:_ScheduleQueuedRepairRetry(entry, reason)
    if type(entry) ~= "table" then return false end
    entry.queueAttempts = math.max(0, tonumber(entry.queueAttempts) or 0) + 1
    entry.lastQueueFailure = reason
    entry.nextAttemptAt = self:_Now() + self:_ComputeQueuedRepairBackoffSec(entry.queueAttempts)
    entry.lastQueuedAt = self:_Now()
    if SF.Debug then
        SF.Debug:Verbose("SYNC", "Queued repair delayed (profileId=%s author=%s range=%d-%d mode=%s attempt=%d reason=%s nextAt=%.2f)",
            tostring(entry.profileId), tostring(entry.author), tonumber(entry.fromCounter) or 0,
            tonumber(entry.toCounter) or 0, tostring(entry.mode or "missing"),
            tonumber(entry.queueAttempts) or 0, tostring(reason or "unknown"), tonumber(entry.nextAttemptAt) or 0)
    end
    return true
end

function Sync:_RemoveQueuedRepair(key)
    local queue = self.state and self.state.repairQueue
    if type(queue) ~= "table" or type(key) ~= "string" or key == "" then return false end
    if not queue.items or not queue.items[key] then return false end

    queue.items[key] = nil
    if type(queue.order) == "table" then
        for i, existingKey in ipairs(queue.order) do
            if existingKey == key then
                table.remove(queue.order, i)
                break
            end
        end
    end
    return true
end

function Sync:QueueRepairRanges(profileId, ranges, opts)
    if not self.state or not self.state.active then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end
    if self.state.profileId and self.state.profileId ~= profileId then return false end
    if type(ranges) ~= "table" or #ranges == 0 then return false end

    opts = type(opts) == "table" and opts or {}

    local queue = self:_EnsureRepairQueueState()
    local added = 0
    local now = self:_Now()
    local limit = tonumber(self.cfg and self.cfg.maxQueuedRepairRanges) or 96

    for _, range in ipairs(ranges) do
        local author = type(range) == "table" and range.author or nil
        local fromCounter = type(range) == "table" and tonumber(range.fromCounter) or nil
        local toCounter = type(range) == "table" and tonumber(range.toCounter) or nil
        local mode = (type(range) == "table" and range.mode) or opts.mode or "missing"
        local preferredTarget = opts.preferredTarget or (type(range) == "table" and range.preferredTarget) or nil

        if type(author) == "string" and author ~= "" and fromCounter and toCounter then
            -- External/nonsequential logs use sentinel counter 0. A 0-0 range
            -- must never be clamped to the sequential 1-1 integrity window.
            if fromCounter < 1 and toCounter < 1 then
                -- skip
            else
            fromCounter = math.max(1, math.floor(fromCounter))
            toCounter = math.max(1, math.floor(toCounter))
            if fromCounter <= toCounter and not self:_HasOutstandingLogRangeRequest(profileId, author, fromCounter, toCounter) then
                local key = self:_MakeRepairQueueKey(profileId, author, fromCounter, toCounter, mode)
                local entry = queue.items[key]
                if not entry then
                    if #queue.order >= limit then
                        if SF.Debug then
                            SF.Debug:Warn("SYNC", "Dropping queued repair (queue full profileId=%s author=%s range=%d-%d mode=%s)",
                                tostring(profileId), tostring(author), fromCounter, toCounter, tostring(mode))
                        end
                    else
                        entry = {
                            key = key,
                            profileId = profileId,
                            author = author,
                            fromCounter = fromCounter,
                            toCounter = toCounter,
                            mode = mode,
                            preferredTarget = preferredTarget,
                            reason = opts.reason,
                            nextAttemptAt = opts.delaySec and (now + math.max(0, tonumber(opts.delaySec) or 0)) or now,
                            queueAttempts = math.max(0, tonumber(opts.queueAttempts) or 0),
                            lastQueuedAt = now,
                        }
                        queue.items[key] = entry
                        queue.order[#queue.order + 1] = key
                        added = added + 1
                    end
                else
                    entry.reason = opts.reason or entry.reason
                    entry.preferredTarget = preferredTarget or entry.preferredTarget
                    if opts.delaySec then
                        local requestedAt = now + math.max(0, tonumber(opts.delaySec) or 0)
                        if type(entry.nextAttemptAt) ~= "number" or requestedAt < entry.nextAttemptAt then
                            entry.nextAttemptAt = requestedAt
                        end
                    elseif opts.expedite then
                        entry.nextAttemptAt = now
                    end
                end
            end
            end
        end
    end

    if added > 0 then
        self:EnsureRepairConvergence("queue_repair")
    end

    if opts.expedite then
        self:_KickRepairConvergence("queued_repair")
    end

    return added > 0
end

function Sync:_DispatchQueuedRepair(entry)
    if type(entry) ~= "table" then return false end
    if entry.mode == "integrity" then
        return self:RequestIntegrityRepairRanges(entry.profileId, {
            {
                author = entry.author,
                fromCounter = entry.fromCounter,
                toCounter = entry.toCounter,
                mode = "integrity",
            }
        }, entry.reason or "queued-integrity", entry.preferredTarget, {
            backgroundRepair = true,
            queueAttempts = entry.queueAttempts,
        })
    end

    return self:RequestMissingLogs({
        {
            author = entry.author,
            fromCounter = entry.fromCounter,
            toCounter = entry.toCounter,
        }
    }, entry.reason or "queued-missing", {
        backgroundRepair = true,
        queueAttempts = entry.queueAttempts,
    })
end

function Sync:_ProcessRepairConvergenceTick(trigger)
    if not self:_ShouldRunRepairConvergence() then
        self:StopRepairConvergence("tick_conditions_failed")
        return false
    end

    local queue = self:_EnsureRepairQueueState()
    local now = self:_Now()
    local processed = 0
    local batchSize = tonumber(self.cfg and self.cfg.convergenceBatchSize) or 2
    local idx = 1

    while idx <= #queue.order and processed < batchSize do
        local key = queue.order[idx]
        local entry = key and queue.items[key] or nil

        if not entry then
            table.remove(queue.order, idx)
        elseif entry.profileId ~= self.state.profileId then
            self:_RemoveQueuedRepair(key)
        elseif self:_HasOutstandingLogRangeRequest(entry.profileId, entry.author, entry.fromCounter, entry.toCounter) then
            self:_RemoveQueuedRepair(key)
        elseif type(entry.nextAttemptAt) == "number" and entry.nextAttemptAt > now then
            idx = idx + 1
        else
            local ok = self:_DispatchQueuedRepair(entry)
            if ok then
                processed = processed + 1
                self:_RemoveQueuedRepair(key)
            else
                processed = processed + 1
                self:_ScheduleQueuedRepairRetry(entry, "dispatch_failed")
                idx = idx + 1
            end
        end
    end

    local convergence = self.state and self.state.convergence
    if type(convergence) == "table" then
        convergence.lastDrainAt = now
    end

    if processed > 0 and SF.Debug then
        SF.Debug:Verbose("SYNC", "Repair convergence tick processed %d queued ranges (trigger=%s)", processed, tostring(trigger or "ticker"))
    end

    return processed > 0
end

function Sync:_ShouldRunRepairConvergence()
    if not (self.state and self.state.active) then return false end
    if type(self.state.sessionId) ~= "string" or self.state.sessionId == "" then return false end
    if type(self.state.profileId) ~= "string" or self.state.profileId == "" then return false end
    if not self:_EnforceGroupedSessionActive("ShouldRunRepairConvergence") then return false end
    return true
end

function Sync:IsRepairConvergenceRunning()
    local convergence = self.state and self.state.convergence
    return type(convergence) == "table" and convergence.tickerHandle ~= nil
end

function Sync:StopRepairConvergence(reason)
    local _, convergence = self:_EnsureRepairQueueState()
    local ticker = convergence.tickerHandle
    local kick = convergence.kickHandle
    convergence.tickerHandle = nil
    convergence.kickHandle = nil

    if ticker and ticker.Cancel then
        pcall(function() ticker:Cancel() end)
    end
    if kick and kick.Cancel then
        pcall(function() kick:Cancel() end)
    end

    if SF.Debug then
        SF.Debug:Info("SYNC", "Repair convergence stopped (reason=%s)", tostring(reason or "unknown"))
    end
end

function Sync:StartRepairConvergence(reason)
    if not self:_ShouldRunRepairConvergence() then
        self:StopRepairConvergence("start_denied:" .. tostring(reason or "unknown"))
        return false
    end

    if self:IsRepairConvergenceRunning() then return true end

    local _, convergence = self:_EnsureRepairQueueState()
    local interval = tonumber(self.cfg and self.cfg.convergenceIntervalSec) or 8
    if interval < 1 then interval = 1 end

    local sid = self.state.sessionId
    local pid = self.state.profileId

    local function tick()
        if not self:_ShouldRunRepairConvergence() then
            self:StopRepairConvergence("tick_conditions_failed")
            return
        end
        if self.state.sessionId ~= sid or self.state.profileId ~= pid then
            self:StopRepairConvergence("tick_session_changed")
            return
        end
        self:_ProcessRepairConvergenceTick("ticker")
    end

    if C_Timer and C_Timer.NewTicker then
        convergence.tickerHandle = C_Timer.NewTicker(interval, tick)
    else
        local cancelled = false
        local handle = {}
        function handle:Cancel() cancelled = true end
        convergence.tickerHandle = handle

        local function loop()
            if cancelled then return end
            tick()
            if cancelled then return end
            self:RunAfter(interval, loop)
        end

        self:RunAfter(interval, loop)
    end

    if SF.Debug then
        SF.Debug:Info("SYNC", "Repair convergence started (interval=%ss, reason=%s)", tostring(interval), tostring(reason or "unknown"))
    end

    return true
end

function Sync:EnsureRepairConvergence(reason)
    if self:_ShouldRunRepairConvergence() then
        return self:StartRepairConvergence(reason)
    end
    self:StopRepairConvergence(reason)
    return false
end

function Sync:_KickRepairConvergence(reason)
    if not self:_ShouldRunRepairConvergence() then return false end

    local _, convergence = self:_EnsureRepairQueueState()
    if convergence.kickHandle then return true end

    local delay = tonumber(self.cfg and self.cfg.convergenceKickDelaySec) or 0.25
    convergence.kickHandle = self:RunAfter(delay, function()
        local current = self.state and self.state.convergence
        if type(current) == "table" then
            current.kickHandle = nil
        end
        self:_ProcessRepairConvergenceTick(reason or "kick")
    end)
    return true
end
