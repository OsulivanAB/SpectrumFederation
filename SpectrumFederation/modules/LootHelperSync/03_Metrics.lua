local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

-- ============================================================================
-- Helper Functions (used by multiple modules)
-- ============================================================================

-- Function Return a current epoch time in seconds.
-- @param none
-- @return number epochSeconds
function Sync:_Now()
    if SF.Now then
        return SF:self:_Now()
    end
    return (GetServerTime and GetServerTime()) or time()
end

-- Function Return a unique identifier for the current player ("Name-Realm").
-- @param none
-- @return string playerId
function Sync:_SelfId()
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

-- ============================================================================
-- Metrics
-- ============================================================================

Sync.metrics = Sync.metrics or {}

-- Function Ensure metrics structure is initialized.
-- @param none
-- @return table metrics
function Sync:_MetricsEnsure()
    local M = self.metrics
    if type(M) ~= "table" then
        M = {}
        self.metrics = M
    end

    if M.enabled == nil then M.enabled = true end
    M.startedAt = M.startedAt or self:_Now()

    M.counters  = M.counters or {}  -- monotonically increasing
    M.gauges    = M.gauges or {}    -- last-set values
    M.stats     = M.stats or {}     -- observed values: count/sum/min/max

    M.meta = M.meta or {
        addonVersion = (self._GetAddonVersion and self:_GetAddonVersion()) or "unknown",
    }

    return M
end

-- Function Returns whether metrics collection is enabled.
-- @param none
-- @return boolean
function Sync:MetricsEnabled()
    local M = self:_MetricsEnsure()
    return M.enabled == true
end

-- Function Set whether metrics collection is enabled.
-- @param enabled boolean True to enable, false to disable.
-- @return nil
function Sync:SetMetricsEnabled(enabled)
    local M = self:_MetricsEnsure()
    M.enabled = (enabled == true)
end

-- Function Increment counter
-- @param key string Counter key
-- @param delta number|nil Increment delta (default 1)
-- @return nil
function Sync:_MInc(key, delta)
    local M = self:_MetricsEnsure()
    if not M.enabled then return end
    if type(key) ~= "string" or key == "" then return end
    delta = tonumber(delta) or 1

    local c = M.counters
    c[key] = (tonumber(c[key]) or 0) + delta
end

-- Function Set gauge value
-- @param key string Gauge key
-- @param value number Gauge value
-- @return nil
function Sync:_MSet(key, value)
    local M = self:_MetricsEnsure()
    if not M.enabled then return end
    if type(key) ~= "string" or key == "" then return end
    M.gauges[key] = value
end

-- Function Observe a value for statistics
-- @param key string Statistic key
-- @param value number Observed value
-- @return nil
function Sync:_MObserve(key, value)
    local M = self:_MetricsEnsure()
    if not M.enabled then return end
    if type(key) ~= "string" or key == "" then return end
    value = tonumber(value)
    if not value then return end

    local s = M.stats[key]
    if type(s) ~= "table" then
        s = {count = 0, sum = 0, min = nil, max = nil }
        M.stats[key] = s
    end

    s.count = (tonumber(s.count) or 0) + 1
    s.sum = (tonumber(s.sum) or 0) + value
    if s.min == nil or value < s.min then s.min = value end
    if s.max == nil or value > s.max then s.max = value end
end

-- Function Set gauge value if greater than current
-- @param key string Gauge key
-- @param value number Gauge value
-- @return nil
function Sync:_MSetMax(key, value)
    local M = self:_MetricsEnsure()
    if not M.enabled then return end
    value = tonumber(value)
    if not value then return end
    local cur = tonumber(M.gauges[key])
    if not cur or value > cur then
        M.gauges[key] = value
    end
end

-- Function Get a snapshot of current metrics.
-- @param none
-- @return table metricsSnapshot
function Sync:GetMetricsSnapshot()
    local M = self:_MetricsEnsure()
    return M
end

-- Function Record a sent message in metrics.
-- @param prefixKey string Message prefix key
-- @param msgType string Message type
-- @param distribution string Distribution channel
-- @param target string|nil Target recipient (for WHISPER)
-- @param okSend boolean|nil True if send was successful, false if failed
-- @return nil
function Sync:_MetricsRecordSend(prefixKey, msgType, distribution, target, okSend)
    if not self:MetricsEnabled() then return end

    local prefixStr = (self.PREFIX and self.PREFIX[prefixKey]) or tostring(prefixKey or "unknown")
    local prefixKeyStr = tostring(prefixKey or "UNKNOWN")

    self:_MInc("sync.msg.sent.total", 1)
    self:_MInc("sync.msg.sent.prefixKey." .. prefixKeyStr, 1)
    self:_MInc("sync.msg.sent.prefix." .. tostring(prefixStr), 1)

    if type(msgType) == "string" and msgType ~= "" then
        self:_MInc("sync.msg.sent.type." .. msgType, 1)
        self:_MInc("sync.msg.sent.prefixKey." .. tostring(prefixKey or "UNKNOWN") .. ".type." .. msgType, 1)
    end

    if type(distribution) == "string" and distribution ~= "" then
        self:_MInc("sync.msg.sent.dist." .. distribution, 1)
    end

    if okSend == false then
        self:_MInc("sync.msg.send_fail.total", 1)
        self:_MInc("sync.msg.send_fail.prefix." .. tostring(prefixStr), 1)
        if type(msgType) == "string" and msgType ~= "" then
            self:_MInc("sync.msg.send_fail.type." .. msgType, 1)
        end
    end
end

-- Function Install hook into SF.LootHelperComm:Send to record metrics.
-- @param none
-- @return nil
function Sync:_InstallMetricsSendHook()
    if self._metricsSendHookInstalled then return end
    if not (SF and SF.LootHelperComm and SF.LootHelperComm.Send) then return end

    local comm = SF.LootHelperComm
    if comm._sfMetricsWrapped then
        self._metricsSendHookInstalled = true
        return
    end

    comm._sfMetricsWrapped = true
    comm._sfOrigSend = comm.Send

    comm.Send = function(commSelf, prefixKey, msgType, payload, distribution, target, prio, opts)
        local ok = comm._sfOrigSend(commSelf, prefixKey, msgType, payload, distribution, target, prio, opts)
        -- Record after so we can capture ok/fail
        Sync:_MetricsRecordSend(prefixKey, msgType, distribution, target, ok)
        return ok
    end

    self._metricsSendHookInstalled = true
end

-- Function Update request queue gauges in metrics.
-- @param none
-- @return nil
function Sync:_MetricsUpdateRequestQueueGauges()
    if not self:MetricsEnabled() then return end

    local total, paused = 0, 0
    local byKind = {}

    for _, req in pairs(self.state.requests or {}) do
        if type(req) == "table" then
            total = total + 1
            if req.paused then paused = paused + 1 end
            local k = tostring(req.kind or "UNKNOWN")
            byKind[k] = (byKind[k] or 0) + 1
        end
    end

    self:_MSet("sync.queue.requests.outstanding", total)
    self:_MSet("sync.queue.requests.paused", paused)
    self:_MSetMax("sync.queue.requests.outstanding_max", total)

    -- per-kind gauges
    for kind, n in pairs(byKind) do
        self:_MSet("sync.queue.requests.kind." .. kind, n)
    end
end

-- Function Observe handler CPU time in milliseconds.
-- @param prefixKey string Message prefix key
-- @param msgType string Message type
-- @param ms number CPU time in milliseconds
-- @return nil
function Sync:_MetricsObserveHandlerMs(prefixKey, msgType, ms)
    if not self:MetricsEnabled() then return end
    self:_MObserve("sync.handler.cpu_ms.prefixKey." .. tostring(prefixKey) .. ".type." .. tostring(msgType or "UNKNOWN"), ms)
end
