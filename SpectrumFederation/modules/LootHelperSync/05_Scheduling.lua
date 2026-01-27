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
