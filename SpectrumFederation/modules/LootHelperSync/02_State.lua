local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

-- ============================================================================
-- Runtime State (kept in-memory; persist only what you truly need)
-- ============================================================================

-- TODO: Wire this into saved profile variables
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

    autoSessionSafeModeOnCombat = false,    -- coordinator entering combat auto-enables session safe-mode
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
        monitorTimerHandle      = nil,  -- ticker for admin takeover monitor
        lastTakeoverRound       = nil,  -- last deterministic takeover "round" we attempted
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
