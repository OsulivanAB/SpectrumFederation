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

    memberReplyJitterMsMin = 0,
    memberReplyJitterMsMax = 500,

    requestTimeoutSec = 5,
    maxRetries = 2
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

-- TODO: Need to create a more stable profile ID in the profile class.
-- Function Start a new SF Loot Helper session as coordinator (Sequence 1 -> 2).
-- @param profileId string Stable profile id to use for this session
-- @param opts table|nil Optional: forceStart, skipPrompt, customHelpers, ect.
-- @return string sessionId
function Sync:StartSession(profileId, opts)
    local sessionId = self:_NextNonce("SES")
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
end

-- Function Finalize admin convergence after timeouts; compute helpers and broadcast SES_START.
-- @param none
-- @return nil
function Sync:FinalizeAdminConvergence()
end

-- Function Choose helpers list from known admin statuses (middle-ground "helpers list" approach).
-- @param adminStatuses table Map/array of admin status payloads
-- @return table helpers Array of "Name-Realm"
function Sync:ChooseHelpers(adminStatuses)
end

-- Function Broadcast session start to the raid (SES_START).
-- @param none
-- @return nil
function Sync:BroadcastSessionStart()
end

-- Function Broadcast coordinator takeover message (COORD_TAKEOVER).
-- @param none
-- @return nil
function Sync:BroadcastCoordinatorTakeover()
end

-- ============================================================================
-- Member responsibilities (Sequence 2)
-- ============================================================================

-- Function Handle session start announcement (SES_START) and decide whether to request snapshot or missing logs.
-- @param sender string "Name-Realm" of sender
-- @param payload table Decoded message payload
-- @return nil
function Sync:HandleSessionStart(sender, payload)
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

-- TODO: Currently we don't have author maxCounterSeen maps readily obtainable or stored anywhere
-- Function Determine whether local client has the session profile and whether it's missing logs.
-- @param profileId string Session profile id
-- @param sessionAuthorMax table Map [author] = maxCounterSeen
-- @return boolean hasProfile True if local has profile, false otherwise
-- @return table missingRequests Array describing needed missing log ranges (implementation-defined)
function Sync:AssessLocalState(profileId, sessionAuthorMax)
end

-- ============================================================================
-- Live updates (Sequence 3)
-- ============================================================================

-- Function Called when a local admin creates a new log entry; broadcasts NEW_LOG to raid.
-- @param profileId string Current session profile id
-- @param logTable table A network-safe representation of the lootLog entry
-- @return nil
function Sync:BroadcastNewLog(profileId, logTable)
end

-- Function Handle NEW_LOG message; dedupe/apply and request gaps if needed.
-- @param sender string "Name-Realm" of sender
-- @param payload table Decoded message payload
-- @return nil
function Sync:HandleNewLog(sender, payload)
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
end

-- Function Route an incoming BULK message to the appropriate handler.
-- @param sender string "Name-Realm" of sender
-- @param msgType string Message type (from Sync.MSG)
-- @param payload table Decoded message payload
-- @param distribution string Message distribution channel ("WHISPER", "RAID", etc.)
-- @return nil
function Sync:OnBulkMessage(sender, msgType, payload, distribution)
end

-- ============================================================================
-- Message Handlers (CONTROL)
-- ============================================================================

-- Function Handle ADMIN_SYNC as a recipient admin: respond with ADMIN_STATUS after jitter.
-- @param sender string Coordinator who requested sync
-- @param payload table {sessionId, profileId, ...}
-- @return nil
function Sync:HandleAdminSync(sender, payload)
end

-- Function Build an ADMIN_STATUS payload for the requested profileId.
-- @param profileId string Profile id to build status for
-- @return table status {sessionId, profileId, hasProfile, authorMax, hasGaps?}
function Sync:BuildAdminStatus(profileId)
end

-- Function Handles ADMIN_STATUS as coordinator: record status and request missing logs if needed.
-- @param sender string "Name-Realm" of sender admin
-- @param payload table ADMIN_STATUS payload
-- @return nil
function Sync:HandleAdminStatus(sender, payload)
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
end

-- Function Handle NEED_PROFILE as a helper/coordinator: respond with PROFILE_SNAPSHOT (bulk).
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId}
-- @return nil
function Sync:HandleNeedProfile(sender, payload)
end

-- Function Handle LOG_REQ as a helper/admin: respond with AUTH_LOGS (bulk).
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, author, fromCounter, toCounter?}
-- @return nil
function Sync:HandleLogRequest(sender, payload)
end

-- ============================================================================
-- Message Handlers (BULK)
-- ============================================================================

-- Function Handle AUTH_LOGS bulk response; merge logs and rebuild state if needed.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, author, logs =[...]}
-- @return nil
function Sync:HandleAuthLogs(sender, payload)
end

-- Function Handle PROFILE_SNAPSHOT; import profile + logs then rebuild derived state.
-- @param sender string "Name-Realm" of sender
-- @param payload table {sessionId, requestId, profileId, profileMeta, logs=[...], adminUsers=[...], ...}
-- @return nil
function Sync:HandleProfileSnapshot(sender, payload)
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
end

-- TODO: No Protocol check?

-- ============================================================================
-- Profile / Log integration helpers (high-level; class implementations can sit elsewhere)
-- ============================================================================

-- Function Find a local profile by stable profileId.
-- @param profileId string Stable profile id
-- @return table|nil LootProfile instance or nil if not found
function Sync:FindLocalProfileById(profileId)
end

-- Function Create a new empty local profile shell from snapshot metadata (no derived state yet).
-- @param profileMeta table Metadata about the profile (from snapshot)
-- @return table|nil LootProfile instance or nil if failed
function Sync:CreateProfileFromMeta(profileMeta)
end

-- Function Export a full snapshot for a profile, suitable for PROFILE_SNAPSHOT message.
-- @param profileId string Stable profile id
-- @return table|nil Snapshot payload or nil if profile not found
function Sync:BuildProfileSnapshot(profileId)
end

-- Function Compute authorMax summary from profile's logs.
-- @param profileId string Stable profile id
-- @return table snapshotPayload Map [author] = maxCounterSeen
function Sync:ComputeAuthorMax(profileId)
end

-- Function Compute missing log ranges given local authorMax and remote authorMax (or detect gaps).
-- @param localAuthorMax table Map [author] = maxCounterSeen
-- @param remoteAuthorMax table Map [author] = maxCounterSeen
-- @return table missingRequests Array describing needed author/range requests.
function Sync:ComputeMissingLogRequests(localAuthorMax, remoteAuthorMax)
end

-- Function Merge incoming logs (net tables) into local profile; dedupe by logId; keep chronological order.
-- @param profileId string Stable profile id
-- @param logs table Array of log tables
-- @return boolean changed True if any new logs were added, false otherwise
function Sync:MergeLogs(profileId, logs)
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
end

-- Function Run a callback after a fixed delay (seconds).
-- @param delaySec number Delay in seconds
-- @param fn function Callback to run after delay
-- @return any handle Optional timer handle
function Sync:RunAfter(delaySec, fn)
end

-- ============================================================================
-- Helpers
-- ============================================================================

-- TODO: Maybe make this an addon-wide helper because I think we have similar functions to this elsewhere
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