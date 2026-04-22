local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

-- ============================================================================
-- Constants / Message Types
-- ============================================================================

Sync.PROTO_VERSION = 1

Sync.PREFIX = {
    CONTROL = "SF_LH",
    BULK = "SF_LHB"
}

Sync.MSG = {
    -- Admn convergence (Sequence 1)
    ADMIN_SYNC      = "ADMIN_SYNC",
    ADMIN_STATUS    = "ADMIN_STATUS",
    LOG_REQ         = "LOG_REQ",
    AUTH_LOGS       = "AUTH_LOGS",

    -- Session lifecycle (Sequence 2)
    SES_START       = "SES_START",
    SES_REANNOUNCE  = "SES_REANNOUNCE",
    SES_HEARTBEAT   = "SES_HEARTBEAT",
    SES_END         = "SES_END",
    HAVE_PROFILE    = "HAVE_PROFILE",
    NEED_PROFILE    = "NEED_PROFILE",
    NEED_LOGS       = "NEED_LOGS",
    PROFILE_SNAPSHOT= "PROFILE_SNAPSHOT",

    -- Live Updates (Sequence 3)
    NEW_LOG         = "NEW_LOG",

    -- Coordinator handoff (Sequence 4)
    COORD_TAKEOVER  = "COORD_TAKEOVER",

    -- Safe Mode
    SAFE_MODE_REQ   = "SAFE_MODE_REQ",
    SAFE_MODE_SET   = "SAFE_MODE_SET",
}
