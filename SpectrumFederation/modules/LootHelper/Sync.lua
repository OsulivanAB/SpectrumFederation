-- Grab the namespace
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
    SES_END         = "SES_END",
    HAVE_PROFILE    = "HAVE_PROFILE",
    NEED_PROFILE    = "NEED_PROFILE",
    NEED_LOGS       = "NEED_LOGS",
    PROFILE_SNAPSHOT= "PROFILE_SNAPSHOT",

    -- Live Updates (Sequence 3)
    NEW_LOG         = "NEW_LOG",

    -- Coordinator handoff (Sequence 4)
    COORD_TAKEOVER  = "COORD_TAKEOVER",
    COORD_ACK       = "COORD_ACK"
}

-- ============================================================================
-- Runtime State (kept in-memory; persist only what you truly need)
-- ============================================================================

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
}

Sync._nonceCounter = Sync._nonceCounter or 0

-- ============================================================================
-- Helper Functions (Local)
-- ============================================================================

-- Function Return a current epoch time in seconds.
-- @param none
-- @return number epochSeconds
local function Now()
    if SF.Now then
        return SF:Now()
    end
    return (GetServerTime and GetServerTime()) or time()
end

-- Function Return a unique identifier for the current player ("Name-Realm").
-- @param none
-- @return string playerId
local function SelfId()
    if SF.GetPlayerFullIdentifier then
        local ok, id = pcall(function() return SF:GetPlayerFullIdentifier() end)
        if ok and id then return id end
    end
    local name, realm = UnitFullName("player")
    realm = realm or GetRealmName()
    if realm then realm = realm:gsub("%s+", "") end
    return name and realm and (name .. "-" .. realm) or (name or "unknown")
end

-- Function Normalize a "Name" or "Name-Realm" into "Name-Realm" format.
-- @param name string Player name or "Name-Realm"
-- @return string|nil Normalized "Name-Realm" or nil if invalid
local function NormalizeNameRealm(name)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then
        local n, r = strsplit("-", name, 2)
        if r then r = r:gsub("%s+", "") end
        return n and r and (n .. "-" .. r) or name
    end
    local realm = GetRealmName()
    if realm then realm = realm:gsub("%s+", "") end
    return realm and (name .. "-" .. realm) or name
end

-- Function Get current group distribution channel ("RAID", "PARTY", or nil).
-- @param none
-- @return string|nil distribution
local function GetGroupDistribution()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- ============================================================================
-- Public API (called by LootHelper core / UI / events)
-- ============================================================================

-- Function Initialize sync system (state + transport + event wiring).
-- @param cfg table|nil Optional config overrides (jitter/timeouts/retries).
-- @return nil
function Sync:Init(cfg)
end

-- Function Enable syncing behavior (safe to call multiple times).
-- @param none
-- @return nil
function Sync:Enable()
end

-- Function Disable syncing behavior; does not delete local data.
-- @param none
-- @return nil
function Sync:Disable()
end

-- Function Update runtime config (jitter, timeouts, retry counts).
-- @param cfg table Config fields to override.
-- @return nil
function Sync:SetConfig(cfg)
end

-- Function Return current runtime config.
-- @param none
-- @return table Current config.
function Sync:GetConfig()
end

-- Function Returns whether an SF Loot Helper session is currently active.
-- @param none
-- @return boolean True if active, false otherwise.
function Sync:IsSessionActive()
end

-- Function Returns current sessionId (or nil).
-- @param none
-- @return string|nil Current sessionId.
function Sync:GetSessionId()
end

-- Function Returns active session profileId (or nil).
-- @param none
-- @return string|nil Current session profileId.
function Sync:GetSessionProfileId()
end

-- Function Returns current coordinator "Name-Realm" (or nil).
-- @param none
-- @return string|nil Current coordinator.
function Sync:GetCoordinator()
end

-- Function Returns current coordinator epoch (or nil).
-- @param none
-- @return number|nil Current coordinator epoch.
function Sync:GetCoordEpoch()
end

-- Function Returns helpers list (array of "Name-Realm").
-- @param none
-- @return table Helpers list.
function Sync:GetHelpers()
end

-- Function Called when group/raid roster changes; detects leadership changes and session conditions.
-- @param none
-- @return nil
function Sync:OnGroupRosterUpdate()
end

-- Function Called when the current player becomes raid leader (or gets promoted) to optionally prompt starting a session.
-- @param none
-- @return nil
function Sync:MaybePromptStartSession()
end

-- Function Start a new SF Loot Helper session as coordinator (Sequence 1 -> 2).
-- @param profileId string Stable profile id to use for this session
-- @param opts table|nil Optional: forceStart, skipPrompt, customHelpers, ect.
-- @return string sessionId
function Sync:StartSession(profileId, opts)
    opts = opts or {}
    local dist = GetGroupDistribution()
    if not dist then
        if SF.PrintError then SF:PrintError("Cannot start session: not in a group/raid.") end
        return nil
    end

    local me = SelfId()
    local sessionId = self:_NextNonce("SES")
    local epoch = Now()

    -- Reste state
    self.state.adminStatuses = {}
    self.state._adminConvergence = nil
    self.state.handshake = nil
    self.state.helpers = {}

    self.state.active = true
    self.state.sessionId = sessionId
    self.state.profileId = profileId
    self.state.coordinator = me
    self.state.coordEpoch = epoch
    self.state.isCoordinator = true

    self:UpdatePeersFromRoster()
    self:TouchPeer(me, { inGroup = true, isAdmin = true })

    self:BeginAdminConvergence(sessionId, profileId)

    return sessionId
end

-- Function End the active session (optional broadcast).
-- @param reason string|nil Human-readable reason ("raid ended", "manual", etc.)
-- @param broadcast boolean|nil True to broadcast session end, false to skip broadcast
-- @return nil
function Sync:EndSession(reason, broadcast)
end

-- Function Take over an existing session after raid leader changes (Sequence 4).
-- @param sessionId string Current session id to take over.
-- @param profileId string Session profile id.
-- @param reason string|nil Why takeover happened (Raid leader change, old coord offline, ect.)
-- @return nil
function Sync:TakeoverSession(sessionId, profileId, reason)
end

-- Function Re-announce session state to raid (typically after takeover or helper refresh).
-- @param none
-- @return nil
function Sync:ReannounceSession()
end

-- ============================================================================
-- Coordinator responsibilities (Sequence 1 and 2)
-- ============================================================================

-- Function Begin admin convergence by whispering ADMIN_SYNC to online admins (Sequence 1).
-- @param sessionId string Current session id.
-- @param profileId string Current session profile id.
-- @return nil
function Sync:BeginAdminConvergence(sessionId, profileId)
    if not self.state.active or not self.state.isCoordinator then return end

    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        -- If the leader somehow doesn't have the profile, just proceed to SES_START;
        -- the raid handshake will handle NEED_PROFILE, ect.
        self:BroadcastSessionStart()
        return
    end

    local adminSyncId = self:_NextNonce("AS")
    self.state._adminConvergence = {
        adminSyncId     = adminSyncId,
        startedAt       = Now(),
        deadlineAt      = Now() + (self.cfg.adminConvergenceCollectSec or 1.5),
        expected        = {}, -- [admin] = true
        pendingReq      = {}, -- [admin] = true
        pendingCount    = 0,
    }

    -- Who do we ask?
    local admins = profile:GetAdminUsers() or {}
    local me = SelfId()

    for _, admin in ipairs(admins) do
        if admin ~= me then
            self.state._adminConvergence.expected[admin] = true
            if SF.LootHelperComm then
                SF.LootHelperComm:Send("CONTROL", self.MSG.ADMIN_SYNC, {
                    sessionId       = sessionId,
                    profileId       = profileId,
                    adminSyncId     = adminSyncId,
                }, "WHISPER", admin, "NORMAL")
            end
        end
    end

    -- After collection window, finalize no matter what
    local sid = sessionId
    self:RunAfter(self.cfg.adminConvergenceCollectSec or 1.5, function()
        if not self.state.active or not self.state.isCoordinator then return end
        if self.state.sessionId ~= sid then return end
        self:FinalizeAdminConvergence()
    end)
end

-- Function Finalize admin convergence after timeouts; compute helpers and broadcast SES_START.
-- @param none
-- @return nil
function Sync:FinalizeAdminConvergence()
    if not self.state.active or not self.state.coordinator then return end
    local conv = self.state._adminConvergence
    if not conv then
        self:BroadcastSessionStart()
        return
    end

    local profileId = self.state.profileId
    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        self:BroadcastSessionStart()
        return
    end

    -- 1) compute local
    local localMax = profile:ComputeAuthorMax() or {}

    -- 2) compute target (union maxima across admin statuses)
    local targetMax = {}
    for author, m in pairs(localMax) do targetMax[author] = m end

    for admin, st in pairs(self.state.adminStatuses or {}) do
        if st and st.hasProfile and type(st.authorMax) == "table" then
            for author, m in pairs(st.authorMax) do
                if type(author) == "string" and type(m) == "number" then
                    local prev = targetMax[author] or 0
                    if m > prev then targetMax[author] = m end
                end
            end
        end
    end

    -- 3) compute missing ranges for the coordinator
    local missing = self:ComputeMissingLogRequests(localMax, targetMax)

    -- 4) send LOG_REQs to a reasonable provider
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

            if SF.LootHelperComm then
                SF.LootHelperComm:Send("CONTROL", self.MSG.LOG_REQ, {
                    sessionId       = self.state.sessionId,
                    profileId       = profileId,
                    adminSyncId     = conv.adminSyncId,
                    requestId       = requestId,
                    author          = author,
                    fromCounter     = req.fromCounter,
                    toCounter       = req.toCounter,
                    supportsEnc     = mySupportsEnc,
                }, "WHISPER", provider, "NORMAL")
            end
        end
    end

    -- 5) choose helpers list
    self.state.helpers = self:ChooseHelpers(self.state.adminStatuses or {})

    -- If no missing logs, start the raid handshake immediately
    if conv.pendingCount == 0 then
        self.state._adminConvergence = nil
        self:BroadcastSessionStart()
        return
    end

    -- Otherwise, wait a bit for AUTH_LOGS, then proceed even if some time out
    local sid = self.state.sessionId
    self:RunAfter(self.cfg.adminLogSyncTimeoutSec or 4.0, function()
        if not self.state.active or not self.state.isCoordinator then return end
        if self.state.sessionId ~= sid then return end
        self.state._adminConvergence = nil
        self:BroadcastSessionStart()
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

    local me = SelfId()
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

    local dist = GetGroupDistribution()
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
    }

    -- reset handshake bookkeeping
    self.state.handshake = {
        sessionId = self.state.sessionId,
        startedAt = Now(),
        deadlineAt = Now() + (self.cfg.handshakeCollectSec or 3),
        replies = {},   -- [sender] = "HAVE_PROFILE"|"NEED_PROFILE"|"NEED_LOGS"
    }

    if SF.LootHelperComm then
        SF.LootHelperComm:Send("CONTROL", self.MSG.SES_START, payload, dist, nil, "ALERT")
    end

    -- timeout window: after N seconds, summarize what we heard
    local sid = self.state.sessionId
    self:RunAfter(self.cfg.handshakeCollectSec or 3, function()
        -- Only finalize if session unchanged and we are still coordinator
        if not self.state.active or not self.state.isCoordinator then return end
        if self.state.sessionId ~= sid then return end
        self:FinalizeHandshakeWindow()
    end)
end

-- Function Broadcast coordinator takeover message (COORD_TAKEOVER).
-- @param none
-- @return nil
function Sync:BroadcastCoordinatorTakeover()
end

function Sync:FinalizeHandshakeWindow()
    if not self.state.isCoordinator then return end
    if not self.state.handshake then return end

    self:UpdatePeersFromRoster()

    local have, needProf, needLogs, noResp = 0, 0, 0, 0
    for name, peer in pairs(self.state.peers or {}) do
        if peer.inGroup then
            if peer.joinStatus == "HAVE_PROFILE" then have = have + 1
            elseif peer.joinStatus == "NEED_PROFILE" then needProf = needProf + 1
            elseif peer.joinStatus == "NEED_LOGS" then needLogs = needLogs + 1
            else noResp = noResp + 1 end
        end
    end

    if SF.PrintInfo then
        SF:PrintInfo(("Handshake complete: %d have, %d need profile, %d need logs, %d no response"):
            format(have, needProf, needLogs, noResp))
    end
end

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

    -- Accept rules:
    -- - If no session active: accept
    -- - If same sessionId: accept (reannounce)
    -- - If different sessionId: accept only if epoch is newer
    if self.state.active then
        if payload.sessionId ~= self.state.sessionId then
            if payload.coordEpoch <= (self.state.coordEpoch or 0) then
                return
            end
        end
    end

    self.state.active = true
    self.state.sessionId = payload.sessionId
    self.state.profileId = payload.profileId
    self.state.coordinator = payload.coordinator
    self.state.coordEpoch = payload.coordEpoch
    self.state.isCoordinator = (payload.coordinator == SelfId())

    if type(payload.authorMax) == "table" then
        self.state.authorMax = payload.authorMax
    else
        self.state.authorMax = {}
    end

    if type(payload.helpers) == "table" then
        self.state.helpers = payload.helpers
    else
        self.state.helpers = {}
    end

    -- Reply after jitter
    local sid = self.state.sessionId
    self:RunWithJitter(self.cfg.memberReplyJitterMsMin, self.cfg.memberReplyJitterMsMax, function()
        -- Ensure session didn't change during the delay
        if not self.state.active or self.state.sessionId ~= sid then return end
        self:SendJoinStatus()
    end)

    self:TouchPeer(sender, { inGroup = true })
end

-- Function Pick helper for a given player deterministically (e.g. hash(name) % #helpers).
-- @param playerName string "Name-Realm"
-- @param helpers table Array of "Name-Realm"
-- @return string|nil Chosen helper "Name-Realm" or nil if no helpers
function Sync:PickHelperForPlayer(playerName, helpers)
end

-- Function Choose the best target (helper/coordinator) for a request, with fallback ordering.
-- @param helpers table Array of helpers "Name-Realm"
-- @param coordinator string|nil Coordinator "Name-Realm"
-- @return table targets Ordered list of targets "Name-Realm" to try
function Sync:GetRequestTargets(helpers, coordinator)
end

-- Function Determine whether local client has the session profile and whether it's missing logs.
-- @param profileId string Session profile id
-- @param sessionAuthorMax table Map [author] = maxCounterSeen
-- @return boolean hasProfile True if local has profile, false otherwise
-- @return table missingRequests Array describing needed missing log ranges (implementation-defined)
function Sync:AssessLocalState(profileId, sessionAuthorMax)
end

-- Function Send join status (HAVE_PROFILE, NEED_PROFILE, or NEED_LOGS) to coordinator.
-- @param none
-- @return nil
function Sync:SendJoinStatus()
    if not self.state.active then return end
    if not self.state.sessionId then return end
    if not self.state.coordinator then return end
    if self.state.isCoordinator then return end

    -- Prevent duplicate replies to repeated SES_START for the same session.
    if self.state._sentJoinStatusForSessionId == self.state.sessionId then
        return
    end
    self.state._sentJoinStatusForSessionId = self.state.sessionId

    local profileId = self.state.profileId
    local payloadBase = {
        sessionId       = self.state.sessionId,
        profileId       = profileId,
        supportedMin    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MIN or nil,
        supportedMax    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MAX or nil,
        addonVersion    = self:_GetAddonVersion(),
        supportsEnc     = (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
                            and SF.SyncProtocol.GetSupportedEncodings()
                            or nil,
    }

    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        if SF.LootHelperComm then
            SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_PROFILE, payloadBase, "WHISPER", self.state.coordinator, "NORMAL")
        end
        return
    end

    local localAuthorMax = profile:ComputeAuthorMax()
    payloadBase.localAuthorMax = localAuthorMax

    local remoteAuthorMax = self.state.authorMax or {}
    local missing = self:ComputeMissingLogRequests(localAuthorMax, remoteAuthorMax)

    if missing and #missing > 0 then
        payloadBase.missing = missing
        if SF.LootHelperComm then
            SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_LOGS, payloadBase, "WHISPER", self.state.coordinator, "NORMAL")
        end
        return
    end

    if SF.LootHelperComm then
        SF.LootHelperComm:Send("CONTROL", self.MSG.HAVE_PROFILE, payloadBase, "WHISPER", self.state.coordinator, "NORMAL")
    end
end

-- ============================================================================
-- Live updates (Sequence 3)
-- ============================================================================

-- Function Called when a local admin creates a new log entry; broadcasts NEW_LOG to raid.
-- @param profileId string Current session profile id
-- @param logTable table A network-safe representation of the lootLog entry
-- @return nil
function Sync:BroadcastNewLog(profileId, logTable)
    if not self.state.active then return false, "no active session" end
    if not self.state.sessionId then return false, "missing sessionId" end
    if type(profileId) ~= "string" or profileId == "" then return false, "missing profileId" end
    if self.state.profileId ~= profileId then return false, "wrong profile for session" end

    local dist = GetGroupDistribution()
    if not dist then return false, "not in group/raid" end

    -- Only admins should be able to push live updates
    local me = SelfId()
    if not self:IsSenderAuthorized(profileId, me) then
        return false, "not authorized to broadcast NEW_LOG"
    end

    -- Accept either a LootLog object or an already-serialized table
    if type(logTable) == "table" and logTable.ToTable then
        logTable = logTable:ToTable()
    end
    if type(logTable) ~= "table" then
        return false, "logTable must be a table (or LootLog instance)"
    end

    local payload = {
        sessionId   = self.state.sessionId,
        profileId   = profileId,
        log         = logTable,
    }

    if not SF.LootHelperComm then
        return false, "LootHelperComm not available"
    end

    -- Broadcast encoding rule:
    -- For raid-wide broadcasts, we usually don't know every peer's supportsEnc yet.
    -- So we pick the safest encoding for now (no compression).
    local opts = nil
    if SF.SyncProtocol and SF.SyncProtocol.ENC_B64CBOR then
        opts = { enc = SF.SyncProtocol.ENC_B64CBOR }
    end

    SF.LootHelperComm:Send("BULK", self.MSG.NEW_LOG, payload, dist, nil, "NORMAL", opts)
    return true, nil
end

-- Function Handle NEW_LOG message; dedupe/apply and request gaps if needed.
-- @param sender string "Name-Realm" of sender
-- @param payload table Decoded message payload
-- @return nil
function Sync:HandleNewLog(sender, payload)
    if type(payload) ~= "table" then return end

    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end

    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.log) ~= "table" then return end

    local profileId = payload.profileId
    local logTable = payload.log

    -- If we don't have the profile yet, request snapshot
    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        if not self.state.isCoordinator and self.state.coordinator and SF.LootHelperComm then
            SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_PROFILE, {
                sessionId       = self.state.sessionId,
                profileId       = profileId,
                supportedMin    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MIN or nil,
                supportedMax    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MAX or nil,
                addonVersion    = self:_GetAddonVersion(),
                supportsEnc     = (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
                                    and SF.SyncProtocol.GetSupportedEncodings()
                                    or nil,
            }, "WHISPER", self.state.coordinator, "NORMAL")
        end
        return
    end

    -- Trust policy for live updates:
    -- Accept from coordinator always; otherwise require sender is an admin of this profile
    if sender ~= self.state.coordinator then
        if not self:IsSenderAuthorized(profileId, sender) then
            if SF.PrintWarning then
                SF:PrintWarning(("Ignoring NEW_LOG from %s for profile %s: not an admin."):format(sender, profileId))
            end
            return
        end
    end

    -- Duplicate protection: fast path using logId index if available
    local logId = logTable._logId or logTable.logId
    if logId and profile._logIndex and profile._logIndex[logId] then
        return
    end

    -- Gap Detection
    local author = logTable._author or logTable.author
    local counter = logTable._counter or logTable.counter

    local localMaxBefore = nil
    if type(author) == "string" and type(counter) == "number" then
        localMaxBefore = (profile.ComputeAuthorMax and (profile:ComputeAuthorMax()[author])) or nil
        localMaxBefore = tonumber(localMaxBefore) or nil
    end

    -- Merge
    local inserted = self:MergeLogs(profileId, { logTable })

    if not inserted then
        return
    end

    if profile.RebuildLogIndex then
        profile:RebuildLogIndex()
    end

    -- If we detected a gap, request missing logs
    if not self.state.isCoordinator and self.state.coordinator
        and type(author) == "string" and type(counter) == "number"
        and localMaxBefore ~= nil
        and counter > (localMaxBefore + 1)
    then
        local missing = {
            {
                author      = author,
                fromCounter = localMaxBefore + 1,
                toCounter   = counter - 1,
            }
        }

        if SF.LootHelperComm then
            SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_LOGS, {
                sessionId       = self.state.sessionId,
                profileId       = profileId,
                missing         = missing,
                supportedMin    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MIN or nil,
                supportedMax    = SF.SyncProtocol and SF.SyncProtocol.PROTO_MAX or nil,
                addonVersion    = self:_GetAddonVersion(),
                supportsEnc     = (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
                                    and SF.SyncProtocol.GetSupportedEncodings()
                                    or nil,
            }, "WHISPER", self.state.coordinator, "NORMAL")
        end
    end

    -- Update UI / derived state
    -- TODO: Does this already happen in MergeLogTables?
    if self.RebuildProfile then
        self:RebuildProfile(profileId)
    end
end

-- ============================================================================
-- Incoming message routing (called by Transport)
-- ============================================================================

-- Function Route an incoming CONTROL message to the appropriate handler.
-- @param sender string "Name-Realm" of sender
-- @param msgType string Message type (from Sync.MSG)
-- @param payload table Decoded message payload
-- @param distribution string Message distribution channel ("WHISPER", "RAID", etc.)
-- @return nil
function Sync:OnControlMessage(sender, msgType, payload, distribution)
    -- Update peer registry from "any message received"
    -- Comm already validated protocol and decoded payload
    self:TouchPeer(sender, { proto = (SF.SyncProtocol and SF.SyncProtocol.PROTO_CURRENT) or nil })

    if msgType == self.MSG.ADMIN_SYNC then return self:HandleAdminSync(sender, payload) end
    if msgType == self.MSG.ADMIN_STATUS then return self:HandleAdminStatus(sender, payload) end
    if msgType == self.MSG.LOG_REQ then return self:HandleLogRequest(sender, payload) end

    if msgType == self.MSG.SES_START then return self:HandleSessionStart(sender, payload) end
    if msgType == self.MSG.HAVE_PROFILE then return self:HandleHaveProfile(sender, payload) end
    if msgType == self.MSG.NEED_PROFILE then return self:HandleNeedProfile(sender, payload) end
    if msgType == self.MSG.NEED_LOGS then return self:HandleNeedLogs(sender, payload) end
end

-- Function Route an incoming BULK message to the appropriate handler.
-- @param sender string "Name-Realm" of sender
-- @param msgType string Message type (from Sync.MSG)
-- @param payload table Decoded message payload
-- @param distribution string Message distribution channel ("WHISPER", "RAID", etc.)
-- @return nil
function Sync:OnBulkMessage(sender, msgType, payload, distribution)
    self:TouchPeer(sender, { proto = (SF.SyncProtocol and SF.SyncProtocol.PROTO_CURRENT) or nil })

    if msgType == self.MSG.AUTH_LOGS then return self:HandleAuthLogs(sender, payload) end
    if msgType == self.MSG.PROFILE_SNAPSHOT then return self:HandleProfileSnapshot(sender, payload) end
    if msgType == self.MSG.NEW_LOG then return self:HandleNewLog(sender, payload) end
end

-- ============================================================================
-- Message Handlers (CONTROL)
-- ============================================================================

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
    -- If coutners are 1..max with no missing, then count(author) == max(author).
    -- If count < max, we're missing at least one counter somewhere (gap).
    local counts = {}
    for _, log in ipairs(profile:GetLootLogs() or {}) do
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
        self:FinalizeAdminConvergence()
    end
end

-- Function Handle SES_REANNOUNCE (typically after coordinator takeover).
-- @param sender string "Name-Realm" of sender coordinator
-- @param payload table SES_REANNOUNCE payload
-- @return nil
function Sync:HandleSessionReannounce(sender, payload)
end

-- Function Handle COORD_TAKEOVER (Sequence 4): update coordinator if coordEpoch is newer.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, profileId, coordEpoch, coordinator}
-- @return nil
function Sync:HandleCoordinatorTakeover(sender, payload)
end

-- Function Handle COORD_ACK from clients/admins (optional bookkeeping).
-- @param sender string "Name-Realm" of sender
-- @param payload table COORD_ACK payload
-- @return nil
function Sync:HandleCoordinatorAck(sender, payload)
    if type(payload) ~= "table" then return end
    if type(payload.sessionId) ~= "string" then return end
    if payload.sessionId ~= self.state.sessionId then return end
    if type(payload.profileId) == "string" and self.state.profileId and payload.profileId ~= self.state.profileId then
        return
    end

    self:TouchPeer(sender, {
        supportedMin = payload.supportedMin,
        supportedMax = payload.supportedMax,
        addonVersion = payload.addonVersion,
    })

    if self.state.profileId then
        local isAdmin = self:IsSenderAuthorized(self.state.profileId, sender)
        local peer = self:GetPeer(sender)
        peer.isAdmin = isAdmin
    end
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
    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end

    self:_RecordHandshakeReply(sender, payload, "NEED_PROFILE")

    if not self.state.active or not self.state.isCoordinator then return end

    -- Safety: only send to group members (prevents random whisper abuse)
    -- This is part of the session start pipeline not the admin sync pipeline so we can restrict to group members
    self:UpdatePeersFromRoster()
    local peer = self:GetPeer(sender)
    if not peer or not peer.inGroup then return end

    local snapPayload = self:BuildProfileSnapshot(self.state.profileId)
    if not snapPayload then
        if SF.PrintWarning then
            SF:PrintWarning(("Cannot send PROFILE_SNAPSHOT to %s: no local profile %s."):format(sender, tostring(self.state.profileId)))
        end
        return
    end

    local enc = nil
    if SF.SyncProtocol and SF.SyncProtocol.PickBestBulkEncoding then
        enc = SF.SyncProtocol.PickBestBulkEncoding(payload and payload.supportsEnc)
    end

    -- Small jitter in case multiple people need it at once
    self:RunWithJitter(0, 250, function()
        if not self.state.active or not self.state.isCoordinator then return end
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
    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end

    self:_RecordHandshakeReply(sender, payload, "NEED_LOGS")

    if not self.state.active or not self.state.isCoordinator then return end

    self:UpdatePeersFromRoster()
    local peer = self:GetPeer(sender)
    if not peer or not peer.inGroup then return end

    if type(payload) ~= "table" or type(payload.missing) ~= "table" then return end

    local profile = self:FindLocalProfileById(self.state.profileId)
    if not profile then return end

    for _, req in ipairs(payload.missing) do
        if type(req) == "table"
            and type(req.author) == "string"
            and type(req.fromCounter) == "number"
            and type(req.toCounter) == "number"
        then
            local fromC = math.max(1, math.floor(req.fromCounter))    
            local toC   = math.max(fromC, math.floor(req.toCounter))

            local out = {}
            for _, log in ipairs(profile:GetLootLogs() or {}) do
                local author = log:GetAuthor()
                local counter = log:GetCounter()
                if author == req.author and type(counter) == "number" and counter >= fromC and counter <= toC then
                    table.insert(out, log:ToTable())
                end
            end

            local resp = {
                sessionId   = self.state.sessionId,
                profileId   = self.state.profileId,
                author      = req.author,
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
    end
end

-- Function Handle LOG_REQ as a helper/admin: respond with AUTH_LOGS (bulk).
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, author, fromCounter, toCounter?}
-- @return nil
function Sync:HandleLogRequest(sender, payload)
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
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring LOG_REQ from %s for profile %s: not an admin."):format(sender, payload.profileId))
        end
        return
    end

    local profile = self:FindLocalProfileById(payload.profileId)
    if not profile then return end

    local fromC = math.max(1, math.floor(payload.fromCounter))
    local toC = (toCounter and math.floor(toCounter)) or fromC

    local out = {}
    for _, log in ipairs(profile:GetLootLogs() or {}) do
        local author = log:GetAuthor()
        local counter = log:GetCounter()
        if author == payload.author and type(counter) == "number" and counter >= fromC and counter <= toC then
            table.insert(out, log:ToTable())
        end
    end

    local resp = {
        sessionId   = payload.sessionId,
        profileId   = payload.profileId,
        adminSyncId = payload.adminSyncId,
        requestId   = payload.requestId,
        author      = payload.author,
        logs        = out,
    }

    if SF.SyncProtocol and SF.SyncProtocol.PickBestBulkEncoding and SF.LootHelperComm then
        local enc = SF.SyncProtocol.PickBestBulkEncoding(payload.supportsEnc)
        SF.LootHelperComm:Send("BULK", self.MSG.AUTH_LOGS, resp, "WHISPER", sender, "BULK", { enc = enc })
    elseif SF.LootHelperComm then
        SF.LootHelperComm:Send("BULK", self.MSG.AUTH_LOGS, resp, "WHISPER", sender, "BULK")
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
    peer.joinReportedAt = Now()

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

-- ============================================================================
-- Message Handlers (BULK)
-- ============================================================================

-- Function Handle AUTH_LOGS bulk response; merge logs and rebuild state if needed.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, author, logs =[...]}
-- @return nil
function Sync:HandleAuthLogs(sender, payload)
    if type(payload) ~= "table" then return end

    local ok = self:ValidateSessionPayload(payload)
    if not ok then return end
    
    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.logs) ~= "table" then return end

    -- Trust policy: If you're not the coordinator, only accept logs from the coordinator
    -- TODO: Allow Helpers as well
    if self.state.coordinator and sender ~= self.state.coordinator and not self.state.isCoordinator then
        return
    end

    self:MergeLogs(payload.profileId, payload.logs)

    -- If we are coordinator, this might be part of admin convergence
    if self.state.isCoordinator then
        local conv = self.state._adminConvergence
        if conv and payload.adminSyncId == conv.adminSyncId and type(payload.requestId) == "string" then
            if conv.pendingReq and conv.pendingReq[payload.requestId] then
                conv.pendingReq[payload.requestId] = nil
                conv.pendingCount = math.max(0, (conv.pendingCount or 1) - 1)

                if conv.pendingCount == 0 then
                    self.state._adminConvergence = nil
                    self:BroadcastSessionStart()
                end
            end
        end
    end
end

-- Function Handle PROFILE_SNAPSHOT; import profile + logs then rebuild derived state.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, profileMeta, logs=[...], adminUsers=[...], ...}
-- @return nil
function Sync:HandleProfileSnapshot(sender, payload)
    if type(payload) ~= "table" then return end

    -- Must be for the current session
    local ok, err = self:ValidateSessionPayload(payload)
    if not ok then return end

    if type(payload.profileId) ~= "string" or payload.profileId == "" then return end
    if type(payload.snapshot) ~= "table" then return end

    -- Trust policy (minimal): only accept snapshots from the coordinator
    if self.state.coordinator and sender ~= self.state.coordinator then
        if SF.PrintWarning then
            SF:PrintWarning(("Ignoring PROFILE_SNAPSHOT from %s: not the coordinator (%s)."):format(sender, tostring(self.state.coordinator)))
        end
        return
    end

    -- Validate snapshot
    if SF.LootProfile and SF.LootProfile.ValidateSnapshot then
        local okSnap, snapErr = SF.LootProfile.ValidateSnapshot(payload.snapshot)
        if not okSnap then
            if SF.PrintWarning then
                SF:PrintWarning(("PROFILE_SNAPSHOT invalid: %s"):format(snapErr or "unknown"))
            end
            return
        end
    end

    -- Ensure payload.profileId matches snapshot meta profileId
    local meta = payload.snapshot.meta
    if not meta or type(meta._profileId) ~= "string" then return end
    if payload.profileId ~= meta._profileId then
        if SF.PrintWarning then
            SF:PrintWarning(("PROFILE_SNAPSHOT mismatch: payload.profileId=%s meta._profileId=%s"):format(
                tostring(payload.profileId), tostring(meta._profileId)))
        end
        return
    end

    -- Ensure DB exists
    SF.lootHelperDB = SF.lootHelperDB or { profiles = {} }
    SF.lootHelperDB.profiles = SF.lootHelperDB.profiles or {}

    local profileId = payload.profileId
    local profile = self:FindLocalProfileById(profileId)
    local isNew = false

    if not profile then
        profile = self:CreateProfileFromMeta(meta)
        if not profile then return end
        isNew = true
    end

    -- Import snapshot (merges logs + dedup by logId)
    local okImport, inserted, importErr = profile:ImportSnapshot(payload.snapshot, { allowUnknownEventType = true })
    if not okImport then
        if SF.PrintWarning then
            SF:PrintWarning(("PROFILE_SNAPSHOT import failed: %s"):format(importErr or "unknown"))
        end
        return
    end

    if isNew then
        table.insert(SF.lootHelperDB.profiles, profile)
    end

    if profile.RebuildLogIndex then
        profile:RebuildLogIndex()
    end

    if SF.SetActiveLootProfile and profile.GetProfileName then
        -- BUG: This function should be using the Profile ID now
        SF:SetActiveLootProfile(profile:GetProfileName())
    end

    if SF.PrintInfo then
        SF:PrintInfo(("Imported PROFILE_SNAPSHOT %s (%d new logs)"):format(
            profile:GetProfileName() or profileId,
            inserted or 0))
    end
end

-- ============================================================================
-- Request lifecycle (timeouts/retries)
-- ============================================================================

-- Function Create a new requestId for correlating request/response.
-- @param none
-- @return string requestId
function Sync:NewRequestId()
    return self:_NextNonce("REQ")
end

-- Function Register an outstanding request so it can timeout / retry / be matched.
-- @param requestId string Unique request identifier
-- @param kind string Request kind/type (e.g. "LOG_REQ", "NEED_PROFILE", etc.)
-- @param target string "Name-Realm" of the initial peer being contacted
-- @param meta table|nil Any metadata (author ranges, etc.)
-- @return nil
function Sync:RegisterRequest(requestId, kind, target, meta)
end

-- Function Mark a request as completed (cancel timers, clear state).
-- @param requestId string
-- @return nil
function Sync:CompleteRequest(requestId)
end

-- Function Handle request timeout; retry against alternate helper or coordinator.
-- @param requestId string
-- @return nil
function Sync:OnRequestTimeout(requestId)
end

-- ============================================================================
-- Validation / Epoch rules
-- ============================================================================

-- Function Determine if an incoming control message is allowed based on coordEpoch.
-- @param payload table Must include sessionId + coordEpoch where applicable
-- @param sender string "Name-Realm" of sender
-- @return boolean True if allowed, false otherwise
function Sync:IsControlMessageAllowed(payload, sender)
end

-- Function Determine if an epoch value is newer than our current epoch (tie-break if needed).
-- @param incomingEpoch number|string Incoming epoch value
-- @param incomingCoordinator string "Name-Realm" of incoming coordinator (for tie-break)
-- @return boolean True if incoming is newer, false otherwise
function Sync:IsNewerEpoch(incomingEpoch, incomingCoordinator)
end

-- Function Validate whether sender is permitted to provide data for a profile (admin check).
-- @param profileId string Profile id
-- @param sender string "Name-Realm" of sender
-- @return boolean True if sender is admin of profile, false otherwise
function Sync:IsSenderAuthorized(profileId, sender)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return false end
    local admins = profile.GetAdminUsers and profile:GetAdminUsers() or nil
    if type(admins) ~= "table" then return false end

    for _, admin in ipairs(admins) do
        if admin == sender then return true end
    end
    return false
end

-- Function Validate session-related payloads for consistency with current session state.
-- @param payload table Must include sessionId and optionally profileId
-- @return boolean isValid True if valid, false otherwise
-- @return string|nil errReason If not valid, reason why
function Sync:ValidateSessionPayload(payload)
    if not self.state.active then return false, "no active session" end
    if type(payload) ~= "table" then return false, "payload not table" end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return false, "missing sessionId" end

    if self.state.active and self.state.sessionId and payload.sessionId ~= self.state.sessionId then
        return false, "stale/other sessionId"
    end

    if self.state.active and self.state.profileId and type(payload.profileId) == "string" and payload.profileId ~= self.state.profileId then
        return false, "wrong profileId for this session"
    end

    return true, nil
end

-- ============================================================================
-- Profile / Log integration helpers (high-level; class implementations can sit elsewhere)
-- ============================================================================

-- Function Find a local profile by stable profileId.
-- @param profileId string Stable profile id
-- @return table|nil LootProfile instance or nil if not found
function Sync:FindLocalProfileById(profileId)
    if not SF.lootHelperDB or type(SF.lootHelperDB.profiles) ~= "table" then return nil end
    if type(profileId) ~= "string" or profileId == "" then return nil end

    for _, profile in ipairs(SF.lootHelperDB.profiles) do
        if profile and profile.GetProfileId and profile:GetProfileId() == profileId then
            return profile
        end
    end
    return nil
end

-- Function Create a new empty local profile shell from snapshot metadata (no derived state yet).
-- @param profileMeta table Metadata about the profile (from snapshot)
-- @return table|nil LootProfile instance or nil if failed
function Sync:CreateProfileFromMeta(profileMeta)
    if type(profileMeta) ~= "table" then return nil end
    if not SF.LootProfile then return nil end

    -- Validate meta
    if SF.LootProfile.ValidateMeta then
        local ok, err = SF.LootProfile.ValidateMeta(profileMeta)
        if not ok then
            if SF.PrintWarning then
                SF:PrintWarning(("CreateProfileFromMeta: invalid meta: %s"):format(err or "unknown"))
            end
            return nil
        end
    end

    -- Create a blank profile object
    local profile = setmetatable({}, SF.LootProfile)

    -- Initialize tables that other code might assume exist
    profile._lootLogs = {}
    profile._logIndex = {}
    profile._authorCounters = {}
    profile._members = {}
    profile._adminUsers = {}
    profile._activeProfile = false
    profile._profileId = profileMeta._profileId
    profile._profileName = profileMeta._profileName or "Imported Profile"

    return profile
end

-- Function Export a full snapshot for a profile, suitable for PROFILE_SNAPSHOT message.
-- @param profileId string Stable profile id
-- @return table|nil Snapshot payload or nil if profile not found
function Sync:BuildProfileSnapshot(profileId)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return nil end
    if not profile.ExportSnapshot then return nil end
    
    local snapshot = profile:ExportSnapshot()

    return {
        sessionId   = self.state.sessionId,
        profileId   = profileId,
        snapshot    = snapshot,
        sentAt      = Now(),
        sender      = SelfId(),
        addonVersion= self:_GetAddonVersion(),
    }
end

-- Function Compute authorMax summary from profile's logs.
-- @param profileId string Stable profile id
-- @return table snapshotPayload Map [author] = maxCounterSeen
function Sync:ComputeAuthorMax(profileId)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return {} end
    if profile.ComputeAuthorMax then
        return profile:ComputeAuthorMax()
    end
    return {}
end

-- Function Compute missing log ranges given local authorMax and remote authorMax (or detect gaps).
-- @param localAuthorMax table Map [author] = maxCounterSeen
-- @param remoteAuthorMax table Map [author] = maxCounterSeen
-- @return table missingRequests Array describing needed author/range requests.
function Sync:ComputeMissingLogRequests(localAuthorMax, remoteAuthorMax)
    local missing = {}
    if type(remoteAuthorMax) ~= "table" then return missing end
    localAuthorMax = localAuthorMax or {}

    for author, remoteMax in pairs(remoteAuthorMax) do
        if type(author) == "string" and type(remoteMax) == "number" then
            local localMax = tonumber(localAuthorMax[author]) or 0
            if remoteMax > localMax then
                table.insert(missing, {
                    author = author,
                    fromCounter = localMax + 1,
                    toCounter = remoteMax,
                })
            end
        end
    end
    return missing
end

-- Function Merge incoming logs (net tables) into local profile; dedupe by logId; keep chronological order.
-- @param profileId string Stable profile id
-- @param logs table Array of log tables
-- @return boolean changed True if any new logs were added, false otherwise
function Sync:MergeLogs(profileId, logs)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return false end
    if type(logs) ~= "table" then return false end

    local inserted = profile:MergeLogTables(logs, { allowUnknownEventType = true })
    return inserted and inserted > 0
end

-- Function Rebuild derived state from logs (replay) for the given profile.
-- @param profileId string Stable profile id
-- @return nil
function Sync:RebuildProfile(profileId)
end

-- Function Detect whether applying a log indicates a gap in the author/counter sequence.
-- @param profileId string Stable profile id
-- @param logTable table Must include author and counter fields
-- @return boolean hasGap True if gap detected, false otherwise
-- @return number|nil gapFrom If hasGap, the starting counter of the gap
-- @return number|nil gapTo If hasGap, the ending counter of the gap
function Sync:DetectGap(profileId, logTable)
end

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

    -- fallback
    C_Timer.After(delaySec, fn)
    return nil
end

-- ============================================================================
-- Peer Registry / Roster Helpers
-- ============================================================================

-- Function Generate the next nonce string for messages.
-- @param tag string|nil Optional tag prefix (default: "N")
-- @return string nonce
function Sync:_NextNonce(tag)
    self._nonceCounter = (self._nonceCounter or 0) + 1
    tag = tag or "N"
    return ("%s:%s:%d:%d"):format(tag, SelfId(), Now(), self._nonceCounter)
end

-- Function Get or create a peer record for the given "Name-Realm".
-- @param nameRealm string "Name-Realm"
-- @return table peerRecord
function Sync:GetPeer(nameRealm)
    if type(nameRealm) ~= "string" or nameRealm == "" then return nil end
    self.state.peers = self.state.peers or {}

    local peer = self.state.peers[nameRealm]
    if not peer then
        peer = {
            name = nameRealm,
            inGroup = false,
            online = nil,
            lastSeen = 0,
            proto = nil,
            supportedMin = nil,
            supportedMax = nil,
            addonVersion = nil,
            isAdmin = nil,
        }
        self.state.peers[nameRealm] = peer
    end
    return peer
end

-- Function Update peer record's lastSeen and optional fields.
-- @param nameRealm string "Name-Realm"
-- @param fields table|nil Optional fields to update in peer record
-- @return nil
function Sync:TouchPeer(nameRealm, fields)
    local peer = self:GetPeer(nameRealm)
    if not peer then return end

    peer.lastSeen = Now()
    if type(fields) == "table" then
        for k, v in pairs(fields) do
            peer[k] = v
        end
    end
end

-- Function Update peer records from current group/raid roster.
-- @param none
-- @return nil
function Sync:UpdatePeersFromRoster()
    self.state.peers = self.state.peers or {}

    -- mark everyone "not inGroup" first; we'll re-mark those we find
    for _, peer in pairs(self.state.peers) do
        peer.inGroup = false
        peer.online = nil
    end

    if IsInRaid() then
        local n = GetNumGroupMembers() or 0
        for i = 1, n do
            local name, rank, subgroup, level, class, fileName, zone, online, isDead, role = GetRaidRosterInfo(i)
            local full = NormalizeNameRealm(name)
            if full then
                local peer = self:GetPeer(full)
                peer.inGroup = true
                peer.online = online
                peer.rank = rank
                peer.subgroup = subgroup
                peer.role = role
            end
        end
    elseif IsInGroup() then
        local function touchUnit(unit)
            local n, r = UnitFullName(unit)
            if not n then return end
            local full = NormalizeNameRealm(r and (n .. "-" .. r) or n)
            if full then
                local peer = self:GetPeer(full)
                peer.inGroup = true
                peer.online = UnitIsConnected(unit)
                peer.role = UnitGroupRolesAssigned(unit)
            end
        end

        touchUnit("player")
        for i = 1, (GetNumSubgroupMembers() or 0) do
            touchUnit("party" .. i)
        end
    end
end

-- Function Get the current addon version string.
-- @param none
-- @return string version
function Sync:_GetAddonVersion()
    if SF.GetAddonVersion then
        return SF:GetAddonVersion()
    end
    return "unknown"
end