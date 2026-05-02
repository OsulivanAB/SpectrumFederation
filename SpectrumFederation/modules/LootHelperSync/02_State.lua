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

    adminConvergenceCollectSec  = 3.0,  -- Increased from 1.5 to 3.0 for large profiles (Issue #10)
    adminLogSyncTimeoutSec      = 4.0,  -- how long coordinator waits for AUTH_LOGS

    memberReplyJitterMsMin = 0,
    memberReplyJitterMsMax = 500,

    requestTimeoutSec = 5,
    maxRetries = 2,

    handshakeCollectSec = 3,  -- how long coordinator waits for HAVE/NEED replies

    maxHelpers = 2,
    preferNoGaps = true, -- prefer helpers without log gaps when choosing helpers
    helperWarmupSec = 2, -- for a short window after session descriptor updates, prefer coordinator first for bootstrap requests

    -- Request robustness
    maxOutstandingRequests  = 64,   -- hard cap to avoid unbounded memory
    requestBackoffMult      = 1.5,  -- exponential backoff multiplier
    requestRetryJitterMsMin = 600,  -- Must be > adminReplyJitterMsMax (500ms) to prevent premature timeouts
    requestRetryJitterMsMax = 1000, -- Increased to allow admin replies to complete before retry

    -- Backpressure for log bursts (coordinator -> member)
    maxMissingRangesPerNeededLogs   = 8,    -- clamp abusive/huge requests
    needLogsSendSpacingMs           = 50,   -- space out AUTH_LOGS sends to avoid spikes
    integrityWindowSize             = 25,   -- author counter window size used for cached integrity summaries

    gapRepairCooldownSec = 2,

    convergenceIntervalSec          = 8,    -- low-frequency background drain for queued repair work
    convergenceBatchSize            = 2,    -- max queued repair ranges to dispatch per convergence tick
    convergenceKickDelaySec         = 0.25, -- short delay for event-driven repair acceleration
    convergenceRetryBaseSec         = 12,   -- base backoff when queued repair dispatch fails
    convergenceRetryMaxSec          = 90,   -- cap queued repair backoff to avoid runaway delays
    maxQueuedRepairRanges           = 96,   -- hard cap for in-memory queued repair work

    -- Heartbeat
    heartbeatIntervalSec            = 30,   -- how often to send heartbeat, in seconds
    heartbeatMissThreshold          = 3,    -- how many consecutive misses before takeover logic triggers
    heartbeatGraceSec               = 10,   -- small extra buffer to reduce false positives
    catchupOnHeartbeatCooldownSec   = 10,   -- avoid re-running catchup logic every single heartbeat if it gets noisy

    -- Active profile audit
    activeProfileAuditIntervalSec   = 90,  -- how often helpers audit one peer's active profile during session
    activeProfileAuditJitterMsMin   = 250,
    activeProfileAuditJitterMsMax   = 1000,
    activeProfileAuditTtlSec        = 180, -- suppress repeat audits of same target for a short window

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
    authorWindowSummary = {}, -- map: [author] = { {fromCounter,toCounter,count,checksum,maxCounter}, ... }

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
    },
    repairQueue = {
        order = {},            -- stable queue order of repair keys
        items = {},            -- map: [repairKey] = repairEntry
    },
    convergence = {
        tickerHandle = nil,    -- background convergence ticker
        kickHandle = nil,      -- short one-shot acceleration timer
        lastDrainAt = nil,
    },

    audit = {
        nextAuditAt = nil,
        lastTargetAt = {}, -- map: [nameRealm] = epochSeconds
    },
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
