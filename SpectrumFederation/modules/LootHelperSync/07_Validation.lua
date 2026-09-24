local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync


-- Function Normalize a "Name-Realm" for comparison (remove spaces, etc.).
-- @param nameRealm string "Name-Realm"
-- @return string|nil Normalized "Name-Realm", or nil if invalid input
function Sync:_NormalizeNameRealmForCompare(nameRealm)
    if type(nameRealm) ~= "string" or nameRealm == "" then return nil end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(nameRealm)
    end
    return (nameRealm:gsub("%s+", ""))
end

-- Function Compare two "Name-Realm" identifiers for equality.
-- @param a string "Name-Realm"
-- @param b string "Name-Realm"
-- @return boolean True if same player, false otherwise
function Sync:_SamePlayer(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    return a == b
end

-- Function True when the session profile is loaded and admin checks are meaningful.
-- @param none
-- @return boolean
function Sync:_ProfileAuthorizationKnown()
    local profileId = self.state and self.state.profileId
    if type(profileId) ~= "string" or profileId == "" then return false end
    if type(self.FindLocalProfileById) ~= "function" then return false end
    return self:FindLocalProfileById(profileId) ~= nil
end

-- Function True when name is still a canonical admin, or when that cannot be proven yet.
-- @param name string "Name-Realm"
-- @return boolean
function Sync:_IsKnownAuthorizedTarget(name)
    if type(name) ~= "string" or name == "" then return false end
    if not self:_ProfileAuthorizationKnown() then return true end
    if self:IsSenderAuthorized(self.state.profileId, name) == true then return true end
    return self:_CoordinatorNeedsCatchUp(name) == true
end

-- Function Remember a player whose admin route was explicitly revoked.
-- A later re-grant clears this when authorization is checked.
-- @param name string "Name-Realm"
-- @return nil
function Sync:_RememberRevokedRoute(name)
    if type(name) ~= "string" or name == "" or not self.state then return end
    self.state.revokedRoutes = self.state.revokedRoutes or {}
    self:_RememberResponder(self.state.revokedRoutes, name)
    -- A negative same-profile scan must not outlive this tombstone. The next
    -- descriptor walks history again instead of adopting a session that then
    -- clears the revocation.
    self.state._sameProfileRevokeScan = nil
    if type(self.state._coordinatorCatchUp) == "string" and self:_SamePlayer(self.state._coordinatorCatchUp, name) then
        self.state._coordinatorCatchUp = nil
    end
    if self._ClearUnprovenCatchUpWarning then
        self:_ClearUnprovenCatchUpWarning(name)
    end
end

-- Function True when this player was explicitly removed and is not an admin again.
-- @param name string "Name-Realm"
-- @return boolean
function Sync:_RouteWasRevoked(name)
    if not (self.state and type(self.state.revokedRoutes) == "table") then return false end
    if self:_ProfileAuthorizationKnown() and self:IsSenderAuthorized(self.state.profileId, name) then
        self:_ForgetResponder(self.state.revokedRoutes, name)
        return false
    end
    return self:_ResponderMapHas(self.state.revokedRoutes, name)
end

-- Function True when this revoked coordinator is still the coordinator of the current session.
-- A newer session is a different scope. Its SES_START is not blocked by the old tombstone.
-- A different profileId on this same session is not a new scope. ValidateSessionPayload
-- rejects that change, and it must not clear the revocation either.
-- @param payload table
-- @return boolean
function Sync:_RevokedRouteBlocksIncomingSession(payload)
    if type(payload) ~= "table" or type(payload.coordinator) ~= "string" then return false end
    if not (self.state and self.state.active and self._RouteWasRevoked) then return false end
    if type(self.state.sessionId) == "string" and payload.sessionId ~= self.state.sessionId then
        return false
    end
    if not self:_RouteWasRevoked(payload.coordinator) then return false end
    if SF.Debug then
        SF.Debug:Verbose("SYNC", "Ignoring session traffic from revoked coordinator %s", tostring(payload.coordinator))
    end
    return true
end

-- Function Drop revocation bookkeeping when the incoming descriptor is a different session.
-- Same-session traffic keeps its tombstones, including a profileId that does not match.
-- A full session reset already clears them.
-- @param incomingSessionId string|nil
-- @param incomingProfileId string|nil Ignored. A profile change is not a new session.
-- @return nil
function Sync:_ClearRevocationForIncomingScope(incomingSessionId, incomingProfileId)
    if not self.state then return end
    local sessionChanged = type(self.state.sessionId) == "string" and self.state.sessionId ~= incomingSessionId
    if not sessionChanged then
        if SF.Debug and type(incomingProfileId) == "string" and type(self.state.profileId) == "string"
            and self.state.profileId ~= "" and incomingProfileId ~= self.state.profileId
        then
            SF.Debug:Verbose("SYNC", "Keeping revocation for same-session profile change %s -> %s",
                tostring(self.state.profileId), tostring(incomingProfileId))
        end
        return
    end
    self.state.revokedRoutes = nil
    self.state._coordinatorCatchUp = nil
end

-- Function True when a new session id for this same profile must not be adopted.
-- Heartbeat, reannounce, takeover, and session start call this after epoch
-- gating and before replacing session state. A coordinator local history
-- already removed would otherwise clear the tombstone, reset takeover timing,
-- apply advertised configuration, and rebuild the profile. Current canonical
-- admin status outranks that history, including a cached scan: the profile
-- owner can be demoted in a role log and still be an admin.
-- One scan per request timeout is reused for a coordinator who is not a
-- current admin; a different name waits instead of walking history again.
-- The cached result is dropped when that history changes or an explicit
-- revocation is recorded.
-- @param payload table
-- @return boolean
function Sync:_SameProfileRevokeScanCurrent(cache)
    if type(cache) ~= "table" or not self.state then return false end
    if cache.profileId ~= self.state.profileId then return false end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(self.state.profileId) or nil
    local logs = (profile and self._GetProfileLootLogs) and self:_GetProfileLootLogs(profile) or nil
    if cache.logs ~= logs then return false end
    local count = type(logs) == "table" and #logs or 0
    if cache.count ~= count then return false end
    local rev = type(profile) == "table" and (tonumber(profile._lootLogRevision) or 0) or 0
    return cache.rev == rev
end

function Sync:_IncomingSameProfileHistoryRevoked(payload)
    if type(payload) ~= "table" or not self.state then return false end
    if type(payload.coordinator) ~= "string" or payload.coordinator == "" then return false end
    if type(payload.profileId) ~= "string" or payload.profileId == "" then return false end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return false end
    if payload.profileId ~= self.state.profileId then return false end
    if payload.sessionId == self.state.sessionId then return false end
    if self.IsSenderAuthorized and self:IsSenderAuthorized(self.state.profileId, payload.coordinator) then
        return false
    end
    local now = self:_Now()
    local cooldown = tonumber(self.cfg and self.cfg.requestTimeoutSec) or 5
    local cache = self.state._sameProfileRevokeScan
    if self:_SameProfileRevokeScanCurrent(cache) then
        local age = now - (tonumber(cache.at) or 0)
        if age >= 0 and age < cooldown then
            if self:_SamePlayer(cache.name, payload.coordinator) then
                return cache.revoked == true
            end
            return true
        end
    end
    if not self._LocalHistoryRevokesAdmin then return false end
    local revoked = self:_LocalHistoryRevokesAdmin(payload.coordinator) == true
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(self.state.profileId) or nil
    local logs = (profile and self._GetProfileLootLogs) and self:_GetProfileLootLogs(profile) or nil
    self.state._sameProfileRevokeScan = {
        name = payload.coordinator,
        profileId = payload.profileId,
        at = now,
        revoked = revoked,
        logs = logs,
        count = type(logs) == "table" and #logs or 0,
        rev = type(profile) == "table" and (tonumber(profile._lootLogRevision) or 0) or 0,
    }
    if revoked and SF.Debug then
        SF.Debug:Verbose("SYNC", "Ignoring new session from %s; local history revoked that coordinator",
            tostring(payload.coordinator))
    end
    return revoked
end

-- Function True when privileged control from this coordinator must be ignored.
-- Explicit revocation outranks the stored coordinator and epoch. Debug only, so
-- heartbeats and retries do not repeat a chat warning.
-- @param sender string "Name-Realm"
-- @param coordinator string|nil Claimed coordinator, or nil to use the sender
-- @return boolean
function Sync:_IgnoreRevokedCoordinatorControl(sender, coordinator)
    local name = coordinator
    if type(name) ~= "string" or name == "" then
        name = sender
    end
    if type(name) ~= "string" or name == "" or not self._RouteWasRevoked then return false end
    if not self:_RouteWasRevoked(name) then return false end
    if SF.Debug then
        SF.Debug:Verbose("SYNC", "Ignoring privileged control from revoked coordinator %s", tostring(name))
    end
    return true
end

-- Function True when this SES_END is the current coordinator shutting down an ownerless session.
-- Peers may already have recorded the revocation from NEW_LOG. With no in-group
-- successor, the heartbeat monitor never runs for a non-admin, so this end is
-- the only way those peers leave the session. A revoked coordinator who still
-- has an eligible successor cannot end it.
-- @param sender string "Name-Realm"
-- @param coordinator string|nil Claimed coordinator
-- @return boolean
function Sync:_OwnerlessRevokedCoordinatorEnd(sender, coordinator)
    if not (self.state and self.state.active and type(self.state.coordinator) == "string") then
        return false
    end
    if type(sender) ~= "string" or not self:_SamePlayer(sender, self.state.coordinator) then
        return false
    end
    if type(coordinator) ~= "string" or not self:_SamePlayer(coordinator, self.state.coordinator) then
        return false
    end
    if not (self._RouteWasRevoked and self:_RouteWasRevoked(self.state.coordinator)) then
        return false
    end
    if type(self._ComputeTakeoverCandidates) ~= "function" then
        return true
    end
    local candidates = self:_ComputeTakeoverCandidates(self.state.profileId) or {}
    return #candidates == 0
end

-- Function Allow catch-up only for an advertised coordinator the local profile has not revoked.
-- @param name string "Name-Realm"
-- @return boolean
function Sync:_CoordinatorNeedsCatchUp(name)
    if not (self.state and type(name) == "string") then return false end
    if type(self.state._coordinatorCatchUp) ~= "string" or not self:_SamePlayer(self.state._coordinatorCatchUp, name) then
        return false
    end
    if not self:_SamePlayer(name, self.state.coordinator) then return false end
    if self:_RouteWasRevoked(name) then
        self.state._coordinatorCatchUp = nil
        if self._ClearUnprovenCatchUpWarning then
            self:_ClearUnprovenCatchUpWarning(name)
        end
        return false
    end
    if self:_ProfileAuthorizationKnown() and self:IsSenderAuthorized(self.state.profileId, name) then
        self.state._coordinatorCatchUp = nil
        if self._ClearUnprovenCatchUpWarning then
            self:_ClearUnprovenCatchUpWarning(name)
        end
        return false
    end
    return true
end

-- Function True when this catch-up coordinator still has no stored grant.
-- Their packets may be adopted once. Repeats must not extend the takeover
-- timer, or a peer with no grant can hold coordination indefinitely.
-- @param name string "Name-Realm"
-- @return boolean
function Sync:_UnprovenCatchUpKeepalive(name)
    if type(name) ~= "string" or name == "" then return false end
    if not (self._CoordinatorNeedsCatchUp and self:_CoordinatorNeedsCatchUp(name)) then
        return false
    end
    if self._LocalCatchUpGrantStored and self:_LocalCatchUpGrantStored(name) == true then
        return false
    end
    return true
end

-- Function True when a new session id from the current unproven catch-up
-- coordinator must be ignored. Adopting it would reset the keepalive clock.
-- @param payload table
-- @return boolean
function Sync:_UnprovenCatchUpBlocksNewSession(payload)
    if type(payload) ~= "table" or not (self.state and self.state.active) then return false end
    if type(payload.sessionId) ~= "string" or payload.sessionId == self.state.sessionId then
        return false
    end
    return self:_UnprovenCatchUpKeepalive(payload.coordinator) == true
end

-- Function True when this descriptor is the first keepalive for a coordinator.
-- A new session id is one. Replacing the coordinator on the same session is
-- the other: the successor's grant may still be in flight, and the expired
-- clock of the coordinator that just timed out must not start a new takeover.
-- @param oldSessionId string|nil
-- @param newSessionId string|nil
-- @param oldCoordinator string|nil
-- @param newCoordinator string|nil
-- @return boolean
function Sync:_CoordinatorKeepaliveBaseline(oldSessionId, newSessionId, oldCoordinator, newCoordinator)
    if oldSessionId ~= newSessionId then return true end
    if type(oldCoordinator) ~= "string" or oldCoordinator == "" then return true end
    if type(newCoordinator) ~= "string" or newCoordinator == "" then return false end
    return not self:_SamePlayer(oldCoordinator, newCoordinator)
end

-- Function Case-folded identity for maps that must agree with SamePlayer.
-- @param name string "Name-Realm"
-- @return string|nil
function Sync:_PlayerIdentityKey(name)
    if type(name) ~= "string" or name == "" then return nil end
    local normalized = (self._NormalizeNameRealmForCompare and self:_NormalizeNameRealmForCompare(name)) or name
    if type(normalized) ~= "string" or normalized == "" then return nil end
    return normalized:lower()
end

function Sync:_FailedCatchUpKey(profileId, name)
    if type(profileId) ~= "string" or profileId == "" then return nil end
    local identity = self:_PlayerIdentityKey(name)
    if not identity then return nil end
    -- SamePlayer compares case-insensitively. The block must too, or a
    -- different capitalization is a new key and can fill the 32-entry book.
    return profileId .. "\0" .. identity
end

-- Function Remember an unproven catch-up coordinator who lost the role.
-- A later descriptor from that player is ignored until local history stores
-- their grant or the profile lists them as an admin. Otherwise a fresh
-- session id after takeover resets the clock and the loop repeats.
-- @param previous string|nil "Name-Realm"
-- @param nextName string|nil "Name-Realm"
-- @return nil
function Sync:_RememberUnprovenCatchUpRelease(previous, nextName)
    if not self.state or type(previous) ~= "string" or previous == "" then return end
    if type(nextName) == "string" and nextName ~= "" and self:_SamePlayer(previous, nextName) then
        return
    end
    if not (self._UnprovenCatchUpKeepalive and self:_UnprovenCatchUpKeepalive(previous)) then
        return
    end
    local key = self:_FailedCatchUpKey(self.state.profileId, previous)
    if not key then return end
    self.state._failedCatchUp = self.state._failedCatchUp or {}
    if self.state._failedCatchUp[key] == true then return end
    local count = 0
    for _ in pairs(self.state._failedCatchUp) do
        count = count + 1
        if count >= 32 then return end
    end
    self.state._failedCatchUp[key] = true
end

-- Function True when this player already lost an unproven catch-up on this profile.
-- The marker is profile-scoped. A stored grant or canonical admin status on
-- the incoming profile clears it, including when that profile is not the
-- active session yet. Another profile is not blocked by it.
-- @param name string "Name-Realm"
-- @param profileId string|nil Incoming profile id. Defaults to the active profile.
-- @return boolean
function Sync:_FailedCatchUpBlocks(name, profileId)
    if not self.state or type(name) ~= "string" or name == "" then return false end
    if type(profileId) ~= "string" or profileId == "" then
        profileId = self.state.profileId
    end
    local book = self.state._failedCatchUp
    if type(book) ~= "table" then return false end
    local key = self:_FailedCatchUpKey(profileId, name)
    if not key or book[key] ~= true then return false end
    if self:IsSenderAuthorized(profileId, name) then
        book[key] = nil
        return false
    end
    if self._LocalCatchUpGrantStored and self:_LocalCatchUpGrantStored(name, profileId) == true then
        book[key] = nil
        return false
    end
    return true
end

-- Function Record coordinator liveness.
-- A proven coordinator refreshes the takeover clock. An unproven catch-up
-- coordinator refreshes it only when this descriptor is the first baseline
-- or the clock was cleared. Later keepalives leave the clock alone so the
-- heartbeat monitor can take over if the grant never arrives.
-- @param name string "Name-Realm"
-- @param baseline boolean|nil True for the descriptor that first adopts this coordinator
-- @return nil
function Sync:_RememberCoordinatorKeepalive(name, baseline)
    if not self.state then return end
    self.state.heartbeat = self.state.heartbeat or {}
    local hb = self.state.heartbeat
    local unproven = self:_UnprovenCatchUpKeepalive(name)
    if unproven and baseline ~= true and (tonumber(hb.lastCoordMessageAt) or 0) > 0 then
        return
    end
    if not unproven then
        hb.lastHeartbeatAt = self:_Now()
    end
    hb.lastCoordMessageAt = self:_Now()
    hb.missedHeartbeats = 0
end

-- Function Any packet from the coordinator counts as liveness.
-- Revoked routes and unproven catch-up do not. Those peers can send control
-- or bulk traffic that handlers reject, and that traffic must not restart
-- the takeover clock ahead of validation.
-- @param sender string "Name-Realm"
-- @return nil
function Sync:_NoteCoordinatorTransportActivity(sender)
    if not (self.state and self.state.active and self.state.coordinator) then return end
    if not self:_SamePlayer(sender, self.state.coordinator) then return end
    if self._RouteWasRevoked and self:_RouteWasRevoked(sender) then return end
    if self._UnprovenCatchUpKeepalive and self:_UnprovenCatchUpKeepalive(sender) then return end
    self.state.heartbeat = self.state.heartbeat or {}
    self.state.heartbeat.lastCoordMessageAt = self:_Now()
end

-- Function Record whether the coordinator just advertised still needs a catch-up request.
-- Revoked coordinators stay blocked. A coordinator the local admin list has not seen yet
-- remains routable until a correlated snapshot or log response arrives.
-- @param name string "Name-Realm"
-- @return nil
function Sync:_NoteAdvertisedCoordinator(name)
    if not self.state or type(name) ~= "string" or name == "" then return end
    if not self:_SamePlayer(name, self.state.coordinator) then return end
    local previous = self.state._coordinatorCatchUp
    if self:_RouteWasRevoked(name) or not self:_ProfileAuthorizationKnown()
        or self:IsSenderAuthorized(self.state.profileId, name)
    then
        self.state._coordinatorCatchUp = nil
    else
        self.state._coordinatorCatchUp = name
    end
    if self.state._coordinatorCatchUp ~= previous and self._RefreshOutstandingRequestTargets then
        self:_RefreshOutstandingRequestTargets()
    end
end

-- Function Compare two ordered player lists.
-- @param a table|nil
-- @param b table|nil
-- @return boolean
function Sync:_SamePlayerList(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if #a ~= #b then return false end
    for i = 1, #a do
        if not self:_SamePlayer(a[i], b[i]) then return false end
    end
    return true
end

-- Function Copy a list of player names.
-- @param list table|nil
-- @return table
function Sync:_CopyPlayerList(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, name in ipairs(list) do
        if type(name) == "string" and name ~= "" then
            table.insert(out, name)
        end
    end
    return out
end

-- Function Configured helper cap. A negative config is treated as none.
-- @param none
-- @return number
function Sync:_AdvertisedHelperCap()
    local maxHelpers = tonumber(self.cfg and self.cfg.maxHelpers) or 2
    if maxHelpers < 0 then maxHelpers = 0 end
    return maxHelpers
end

-- Function Deduplicate and cap a helper list before comparison or routing.
-- A catch-up coordinator can advertise thousands of copies of one admin.
-- Alternating lengths must not retarget, and request routing must not sort
-- that array. The walk stops at the cap, or after 64 entries when the cap is
-- smaller, so one descriptor cannot scan an unbounded list.
-- When requireAuthorized is set and the profile is loaded, names that are not
-- canonical admins do not consume the cap.
-- @param helpers table|nil
-- @param opts table|nil { requireAuthorized = bool }
-- @return table
function Sync:_CapUniqueHelpers(helpers, opts)
    local out = {}
    local maxHelpers = self:_AdvertisedHelperCap()
    if type(helpers) ~= "table" or maxHelpers == 0 then return out end
    opts = type(opts) == "table" and opts or {}
    local requireAuthorized = opts.requireAuthorized == true
    local scanCap = maxHelpers
    if scanCap < 64 then scanCap = 64 end
    local seen = {}
    local scanned = 0
    local profileId = self.state and self.state.profileId
    local profileKnown = requireAuthorized and self:_ProfileAuthorizationKnown()
    for _, name in ipairs(helpers) do
        if #out >= maxHelpers then break end
        scanned = scanned + 1
        if scanned > scanCap then break end
        if type(name) == "string" and name ~= "" then
            local allowed = (not profileKnown) or self:IsSenderAuthorized(profileId, name)
            if allowed then
                local key = self:_PlayerIdentityKey(name)
                if key and not seen[key] then
                    seen[key] = true
                    table.insert(out, name)
                end
            end
        end
    end
    return out
end

-- Function Drop helpers who are no longer canonical admins, then cap the list.
-- @param helpers table|nil Advertised helper names
-- @return table
function Sync:_FilterHelpersToAuthorized(helpers)
    return self:_CapUniqueHelpers(helpers, { requireAuthorized = true })
end

-- Function Install the effective helper list and retarget requests when it changes.
-- @param helpers table|nil Advertised helper names
-- @param reason string|nil Diagnostic reason
-- @return boolean True when the stored helper list changed
function Sync:ApplyAdvertisedHelpers(helpers, reason)
    local filtered = self:_FilterHelpersToAuthorized(helpers)
    local changed = not self:_SamePlayerList(self.state.helpers, filtered)
    self.state.helpers = filtered
    if changed and self._RefreshOutstandingRequestTargets then
        self:_RefreshOutstandingRequestTargets()
    end
    if changed and SF.Debug then
        SF.Debug:Info("SYNC", "Helper routing updated (%s, count=%d)", tostring(reason or "update"), #filtered)
    end
    return changed
end

-- Function Remember a player on a request-scoped responder map.
-- @param bucket table
-- @param name string
-- @return nil
function Sync:_RememberResponder(bucket, name)
    if type(bucket) ~= "table" or type(name) ~= "string" or name == "" then return end
    local key = self:_NormalizeNameRealmForCompare(name) or name
    bucket[key] = name
end

-- Function Remove a player from a request-scoped responder map.
-- @param bucket table|nil
-- @param name string
-- @return nil
function Sync:_ForgetResponder(bucket, name)
    if type(bucket) ~= "table" or type(name) ~= "string" or name == "" then return end
    local drop = {}
    local key = self:_NormalizeNameRealmForCompare(name) or name
    if bucket[key] ~= nil then
        table.insert(drop, key)
    end
    for existingKey, existing in pairs(bucket) do
        if self:_SamePlayer(existing, name) then
            table.insert(drop, existingKey)
        end
    end
    for _, existingKey in ipairs(drop) do
        bucket[existingKey] = nil
    end
end

-- Function True when a responder map contains this player.
-- @param bucket table|nil
-- @param name string
-- @return boolean
function Sync:_ResponderMapHas(bucket, name)
    if type(bucket) ~= "table" or type(name) ~= "string" or name == "" then return false end
    local key = self:_NormalizeNameRealmForCompare(name) or name
    if bucket[key] ~= nil then return true end
    for _, existing in pairs(bucket) do
        if self:_SamePlayer(existing, name) then return true end
    end
    return false
end

-- Function Record a target that was already sent a request and may still answer.
-- @param req table
-- @param name string
-- @return nil
function Sync:_RememberInflightResponder(req, name)
    if type(req) ~= "table" then return end
    req.inflightResponders = req.inflightResponders or {}
    -- A re-granted admin can be contacted again. The old revocation tombstone
    -- must not discard that later response. A gapped rebuild must not clear it
    -- merely because the route has not been explicitly revoked yet.
    if self:_IsKnownAuthorizedTarget(name) then
        self:_ForgetResponder(req.revokedResponders, name)
    end
    self:_RememberResponder(req.inflightResponders, name)
end

-- Function Mark a former target as intentionally dropped. Later packets are stale.
-- @param req table
-- @param name string
-- @return nil
function Sync:_RememberRevokedResponder(req, name)
    if type(req) ~= "table" then return end
    req.revokedResponders = req.revokedResponders or {}
    self:_RememberResponder(req.revokedResponders, name)
    self:_ForgetResponder(req.inflightResponders, name)
end

-- Function Current helper/coordinator targets that are still canonical admins.
-- @param opts table|nil Passed to GetRequestTargets
-- @return table
function Sync:_CurrentAuthorizedRoutingTargets(opts)
    if type(self.GetRequestTargets) ~= "function" then return {} end
    local targets = self:GetRequestTargets(self.state.helpers, self.state.coordinator, opts) or {}
    if not self:_ProfileAuthorizationKnown() then return targets end
    local out = {}
    local profileId = self.state.profileId
    local catchUpName = self.state._coordinatorCatchUp
    local grantStored = type(catchUpName) == "string" and self:_LocalCatchUpGrantStored(catchUpName)
    for _, name in ipairs(targets) do
        -- Preferred repair targets must still be a current coordinator or helper.
        -- A former helper who remains an admin is not a new request target.
        local authorized = self:IsSenderAuthorized(profileId, name) and self:IsTrustedDataSender(name)
        -- A catch-up coordinator is asked only when the proving grant is already
        -- stored. A missing grant is fetched from another canonical admin.
        local catchUp = self:_CoordinatorNeedsCatchUp(name) and grantStored
        if authorized or catchUp then
            table.insert(out, name)
        end
    end
    if type(catchUpName) == "string" and self:_CoordinatorNeedsCatchUp(catchUpName) and not grantStored then
        for _, name in ipairs(self:_TrustedAdminGrantProviders(catchUpName)) do
            local seen = false
            for _, existing in ipairs(out) do
                if self:_SamePlayer(existing, name) then
                    seen = true
                    break
                end
            end
            if not seen then
                table.insert(out, name)
            end
        end
    end
    return out
end

-- Function True when this peer is currently in the group.
-- @param name string "Name-Realm"
-- @return boolean
function Sync:_PeerInGroup(name)
    if type(name) ~= "string" or name == "" or type(self.GetPeer) ~= "function" then return false end
    local peer = self:GetPeer(name)
    return type(peer) == "table" and peer.inGroup == true
end

-- Function True when local history already stores a current grant for this player.
-- The row must be authored by a different canonical admin. A missing row is not
-- proof, and it is not a revocation. One walk per player is reused until the
-- log list, its revision, or the canonical admin list changes. A profile other
-- than the active session uses its own cache so that scan does not replace
-- the active profile's result.
-- @param name string "Name-Realm"
-- @param profileId string|nil Profile to read. Defaults to the active profile.
-- @return boolean
function Sync:_CatchUpGrantAdminToken(profile)
    local admins = self._GetProfileAdminUsers and self:_GetProfileAdminUsers(profile) or nil
    if type(admins) ~= "table" then return "" end
    local parts = {}
    for i = 1, #admins do
        parts[i] = tostring(admins[i])
    end
    return table.concat(parts, "\0")
end

function Sync:_LocalCatchUpGrantStored(name, profileId)
    if type(name) ~= "string" or name == "" or not self.state then return false end
    if type(profileId) ~= "string" or profileId == "" then
        profileId = self.state.profileId
    end
    if type(profileId) ~= "string" or profileId == "" then return false end
    if type(self.FindLocalProfileById) ~= "function" or type(self._GetProfileLootLogs) ~= "function" then
        return false
    end
    if type(self._LogAdminGrantState) ~= "function" then return false end
    local profile = self:FindLocalProfileById(profileId)
    local logs = profile and self:_GetProfileLootLogs(profile) or nil
    if type(logs) ~= "table" then return false end
    local rev = type(profile) == "table" and (tonumber(profile._lootLogRevision) or 0) or 0
    local adminToken = self:_CatchUpGrantAdminToken(profile)
    local foreign = profileId ~= self.state.profileId
    local cacheField = foreign and "_catchUpGrantScanOther" or "_catchUpGrantScan"
    local cache = self.state[cacheField]
    local cacheKey = self:_PlayerIdentityKey(name)
    local applied = (type(profile) == "table" and profile._identityProjection and profile._identityProjection.appliedRelationshipIds) or nil
    if type(cache) ~= "table"
        or cache.profileId ~= profileId
        or cache.logs ~= logs
        or cache.count ~= #logs
        or cache.rev ~= rev
        or cache.admins ~= adminToken
        or cache.applied ~= applied
        or type(cache.byName) ~= "table"
    then
        cache = {
            profileId = profileId,
            logs = logs,
            count = #logs,
            rev = rev,
            admins = adminToken,
            applied = applied,
            byName = {},
        }
        self.state[cacheField] = cache
    end
    local cached = cache.byName[cacheKey]
    if cached ~= nil then
        return cached == true
    end
    local grantLog = nil
    for _, log in ipairs(logs) do
        local logTable = log
        if type(log) == "table" and type(log.ToTable) == "function" then
            logTable = log:ToTable()
        end
        local state = self:_LogAdminGrantState(logTable, name, profile)
        if state == "grant" then
            grantLog = logTable
        elseif state == "revoke" then
            grantLog = nil
        end
    end
    local stored = false
    if type(grantLog) == "table" then
        local author = grantLog._author or grantLog.author
        if type(author) == "string" and author ~= "" and not self:_SamePlayer(author, name) then
            stored = self:IsSenderAuthorized(profileId, author) == true
        end
    end
    local storedNames = 0
    for _ in pairs(cache.byName) do
        storedNames = storedNames + 1
    end
    if storedNames >= 32 then
        cache.byName = {}
    end
    cache.byName[cacheKey] = stored
    return stored
end

-- Function In-group canonical admins who can serve a coordinator grant this client missed.
-- Helpers come first. The catch-up coordinator is not a provider of their own missing grant.
-- @param exclude string|nil "Name-Realm"
-- @return table
function Sync:_TrustedAdminGrantProviders(exclude)
    local out = {}
    local function add(name)
        if type(name) ~= "string" or name == "" then return end
        if self:_SamePlayer(name, self:_SelfId()) then return end
        if type(exclude) == "string" and self:_SamePlayer(name, exclude) then return end
        for _, existing in ipairs(out) do
            if self:_SamePlayer(existing, name) then return end
        end
        if self:_RouteWasRevoked(name) then return end
        if not self:IsSenderAuthorized(self.state.profileId, name) then return end
        if not self:_PeerInGroup(name) then return end
        table.insert(out, name)
    end
    if type(self.state.helpers) == "table" then
        for _, name in ipairs(self.state.helpers) do
            add(name)
        end
    end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(self.state.profileId) or nil
    local admins = (profile and self._GetProfileAdminUsers) and self:_GetProfileAdminUsers(profile) or nil
    if type(admins) == "table" then
        local rest = {}
        for _, name in ipairs(admins) do
            if type(name) == "string" then
                table.insert(rest, name)
            end
        end
        table.sort(rest)
        for _, name in ipairs(rest) do
            add(name)
        end
    end
    return out
end

-- Function Payload fields that ask the selected peer for a coordinator grant.
-- A stored grant is confirmed by the catch-up coordinator. A missing grant is
-- requested from someone this profile already authorizes.
-- @param target string "Name-Realm"
-- @return table
function Sync:_CatchUpRequestGrantFields(target)
    local fields = {}
    local coordinator = self.state and self.state.coordinator
    if type(coordinator) ~= "string" or coordinator == "" then return fields end
    if not (self._CoordinatorNeedsCatchUp and self:_CoordinatorNeedsCatchUp(coordinator)) then
        return fields
    end
    if self:_LocalCatchUpGrantStored(coordinator) then
        if self:_CoordinatorNeedsCatchUp(target) then
            fields.needsAdminGrant = true
        end
    elseif not self:_CoordinatorNeedsCatchUp(target) then
        fields.adminGrantMember = coordinator
    end
    return fields
end

-- Function True when this authorized admin may serve the current coordinator's grant.
-- An arbitrary adminGrantMember does not opt this client into bulk serving.
-- The unproven coordinator does not serve the grant this client has not stored.
-- @param payload table|nil
-- @return boolean
function Sync:_CanServeAdminGrantRequest(payload)
    if not (self.state and self.state.active) then return false end
    if type(payload) ~= "table" then return false end
    local member = payload.adminGrantMember
    if type(member) ~= "string" or member == "" then return false end
    local coordinator = self.state.coordinator
    if type(coordinator) ~= "string" or not self:_SamePlayer(member, coordinator) then return false end
    if not self:IsSenderAuthorized(self.state.profileId, self:_SelfId()) then return false end
    if self:_SamePlayer(member, self:_SelfId()) and not self:_LocalCatchUpGrantStored(self:_SelfId()) then
        return false
    end
    return true
end

-- Function True when this sender may receive another grant-only reply.
-- A sent reply and a miss that found no grant both wait one request timeout
-- before the history is scanned again. More than four sent replies per sender
-- in this session do not scan or send again. Misses do not use that cap.
-- @param sender string "Name-Realm"
-- @param member string "Name-Realm"
-- @return boolean
function Sync:_AdminGrantServeAllowed(sender, member)
    if type(sender) ~= "string" or sender == "" then return false end
    if type(member) ~= "string" or member == "" then return false end
    local book = self.state and self.state._adminGrantServe
    if type(book) ~= "table" then return true end
    local record = book[sender]
    if type(record) ~= "table" or not self:_SamePlayer(record.member, member) then
        local count = 0
        for _ in pairs(book) do
            count = count + 1
            if count >= 64 then return false end
        end
        return true
    end
    if (tonumber(record.count) or 0) >= 4 then return false end
    local cooldown = tonumber(self.cfg and self.cfg.requestTimeoutSec) or 5
    local now = self:_Now()
    local at = tonumber(record.at)
    if at and (now - at) < cooldown then return false end
    local missAt = tonumber(record.missAt)
    if missAt and (now - missAt) < cooldown then return false end
    return true
end

-- Function Remember one grant-only reply so repeats stay bounded.
-- @param sender string "Name-Realm"
-- @param member string "Name-Realm"
-- @return nil
function Sync:_NoteAdminGrantServe(sender, member)
    if not self.state or type(sender) ~= "string" or sender == "" then return end
    if type(member) ~= "string" or member == "" then return end
    self.state._adminGrantServe = self.state._adminGrantServe or {}
    local record = self.state._adminGrantServe[sender]
    if type(record) ~= "table" or not self:_SamePlayer(record.member, member) then
        record = { member = member, count = 0 }
    end
    record.member = member
    record.count = (tonumber(record.count) or 0) + 1
    record.at = self:_Now()
    self.state._adminGrantServe[sender] = record
end

-- Function Remember a grant scan that found no row.
-- The next scan waits one request timeout. The sent-reply cap stays unchanged
-- so a later grant can still be served.
-- @param sender string "Name-Realm"
-- @param member string "Name-Realm"
-- @return nil
function Sync:_NoteAdminGrantMiss(sender, member)
    if not self.state or type(sender) ~= "string" or sender == "" then return end
    if type(member) ~= "string" or member == "" then return end
    self.state._adminGrantServe = self.state._adminGrantServe or {}
    local record = self.state._adminGrantServe[sender]
    if type(record) ~= "table" or not self:_SamePlayer(record.member, member) then
        record = { member = member, count = 0 }
    end
    record.member = member
    record.missAt = self:_Now()
    self.state._adminGrantServe[sender] = record
end

-- Function True when this request already contacted the named peer.
-- @param req table
-- @param name string
-- @return boolean
function Sync:_RequestAlreadyContacted(req, name)
    if type(req) ~= "table" or type(name) ~= "string" then return false end
    if self:_SamePlayer(name, req.lastTarget) then return true end
    return self:_ResponderMapHas(req.inflightResponders, name)
end

-- Function Replace request targets without treating newly inserted peers as attempted.
-- targetIdx stays one before the first peer this request has not contacted, so
-- the next _PickNextTargetForRequest tries that peer. Peers already contacted
-- stay acceptable in-flight responders.
-- @param req table
-- @param targets table
-- @return nil
function Sync:_RetargetRequestList(req, targets)
    req.targets = targets
    local firstUnattempted = nil
    for i, name in ipairs(targets) do
        if not self:_RequestAlreadyContacted(req, name) then
            firstUnattempted = i
            break
        end
    end
    if firstUnattempted then
        req.targetIdx = firstUnattempted - 1
    else
        req.targetIdx = #targets
    end
    if #targets > 0 then
        req.routeWaits = nil
    end
end

-- Function Read the admin-grant effect of one log for a player.
-- @param logTable table
-- @param name string "Name-Realm"
-- @param profile table|nil Profile whose applied relationships prove a sourced grant.
--        Defaults to the active session profile.
-- @return string|nil "grant", "revoke", or nil when the log does not change this player
function Sync:_LogAdminGrantState(logTable, name, profile)
    if type(logTable) ~= "table" or type(name) ~= "string" or name == "" then return nil end
    local eventType = logTable._eventType or logTable.eventType
    local data = logTable._data or logTable.data
    if type(data) ~= "table" or type(data.member) ~= "string" then return nil end
    if not self:_SamePlayer(data.member, name) then return nil end
    local types = SF.LootLogEventTypes or {}
    local added = types.ADMIN_ADDED or "ADMIN_ADDED"
    local removed = types.ADMIN_REMOVED or "ADMIN_REMOVED"
    local roleChange = types.ROLE_CHANGE or "ROLE_CHANGE"
    local adminRole = (SF.MemberRoles and SF.MemberRoles.ADMIN) or "ADMIN"
    local memberRole = (SF.MemberRoles and SF.MemberRoles.MEMBER) or "MEMBER"
    if eventType == added then
        -- Identity ignores ADMIN_ADDED when sourceLogId is not an applied
        -- relationship. That row must not cancel a removal or prove catch-up.
        if not self:_SourcedAdminGrantApplies(data, profile) then return nil end
        return "grant"
    end
    if eventType == removed then return "revoke" end
    if eventType == roleChange and data.newRole == adminRole then return "grant" end
    if eventType == roleChange and data.newRole == memberRole then return "revoke" end
    return nil
end

-- Function True when an ADMIN_ADDED row is current authority.
-- No sourceLogId is unconditional. A sourceLogId counts only when identity
-- projection applied that relationship log.
-- @param data table|nil
-- @param profile table|nil Profile whose applied relationships count. Defaults to the active profile.
-- @return boolean
function Sync:_SourcedAdminGrantApplies(data, profile)
    local sourceLogId = type(data) == "table" and data.sourceLogId or nil
    if type(sourceLogId) ~= "string" or sourceLogId == "" then
        return true
    end
    if type(profile) ~= "table" then
        profile = (self.state and self.FindLocalProfileById) and self:FindLocalProfileById(self.state.profileId) or nil
    end
    local projection = type(profile) == "table" and profile._identityProjection or nil
    local applied = type(projection) == "table" and projection.appliedRelationshipIds or nil
    return type(applied) == "table" and applied[sourceLogId] == true
end

-- Function True when ordered logs end with this player granted admin.
-- A later ADMIN_REMOVED in the same payload cancels an earlier grant.
-- @param logs table
-- @param name string "Name-Realm"
-- @return boolean
function Sync:_LogsEstablishAdminGrant(logs, name)
    if type(logs) ~= "table" then return false end
    local granted = false
    for _, logTable in ipairs(logs) do
        local state = self:_LogAdminGrantState(logTable, name)
        if state == "grant" then
            granted = true
        elseif state == "revoke" then
            granted = false
        end
    end
    return granted
end

-- Function True when local history's last admin effect for this player is a revoke.
-- Missing history is not a revocation. A later grant clears an earlier removal.
-- @param name string "Name-Realm"
-- @return boolean
function Sync:_LocalHistoryRevokesAdmin(name)
    if type(name) ~= "string" or name == "" or not self.state then return false end
    if type(self.FindLocalProfileById) ~= "function" or type(self._GetProfileLootLogs) ~= "function" then
        return false
    end
    local profile = self:FindLocalProfileById(self.state.profileId)
    local logs = profile and self:_GetProfileLootLogs(profile) or nil
    if type(logs) ~= "table" then return false end
    local revoked = false
    local saw = false
    for _, log in ipairs(logs) do
        local logTable = log
        if type(log) == "table" and type(log.ToTable) == "function" then
            logTable = log:ToTable()
        end
        local state = self:_LogAdminGrantState(logTable, name)
        if state == "grant" then
            saw = true
            revoked = false
        elseif state == "revoke" then
            saw = true
            revoked = true
        end
    end
    return saw and revoked
end

-- Function Identity of the local history a catch-up proof walk would read.
-- A repeat of the same remote logs skips that walk until this identity changes.
-- Up to 16 remote rows use their exact fields. Larger snapshots use a fixed-size
-- hash so a repeat does not walk local history again.
-- @param sender string "Name-Realm"
-- @param logs table
-- @return table|nil
function Sync:_CatchUpProofToken(sender, logs)
    if not self.state or type(sender) ~= "string" or sender == "" then return nil end
    if type(logs) ~= "table" or #logs == 0 then return nil end
    if type(self.FindLocalProfileById) ~= "function" or type(self._GetProfileLootLogs) ~= "function" then
        return nil
    end
    local profile = self:FindLocalProfileById(self.state.profileId)
    local localLogs = profile and self:_GetProfileLootLogs(profile) or nil
    if type(localLogs) ~= "table" then return nil end
    local function rowKey(row)
        if type(row) ~= "table" then return nil end
        local data = row._data or row.data
        local member = type(data) == "table" and data.member or ""
        return table.concat({
            tostring(row._id or row.id or ""),
            tostring(row._author or row.author or ""),
            tostring(row._counter or row.counter or ""),
            tostring(row._eventType or row.eventType or ""),
            tostring(row._timestamp or row.timestamp or ""),
            tostring(row._fingerprint or row.fingerprint or ""),
            tostring(member),
        }, "\1")
    end
    local remoteKey
    if #logs > 16 then
        local hashA = 5381
        local hashB = 7919
        for _, row in ipairs(logs) do
            local key = rowKey(row)
            if not key then return nil end
            for i = 1, #key do
                local byte = key:byte(i)
                hashA = (hashA * 33 + byte) % 2147483647
                hashB = (hashB * 31 + byte) % 2147483647
            end
        end
        local firstKey = rowKey(logs[1])
        local lastKey = rowKey(logs[#logs])
        remoteKey = table.concat({ "wide", tostring(#logs), tostring(hashA), tostring(hashB), firstKey, lastKey }, "\0")
    else
        local remote = {}
        for i, row in ipairs(logs) do
            remote[i] = rowKey(row)
            if not remote[i] then return nil end
        end
        remoteKey = table.concat(remote, "\0")
    end
    local senderKey = (self._NormalizeNameRealmForCompare and self:_NormalizeNameRealmForCompare(sender)) or sender
    return {
        profileId = self.state.profileId,
        logs = localLogs,
        count = #localLogs,
        rev = (type(profile) == "table" and tonumber(profile._lootLogRevision)) or 0,
        key = senderKey .. "\0" .. remoteKey,
    }
end

function Sync:_CatchUpProofTokenCurrent(cache, token)
    return type(cache) == "table"
        and type(token) == "table"
        and cache.profileId == token.profileId
        and cache.logs == token.logs
        and cache.count == token.count
        and cache.rev == token.rev
        and type(cache.byKey) == "table"
end

-- Function The one local grant row that proves this catch-up sender.
-- It must already be stored, authored by another canonical admin, and still be
-- the latest local admin effect. Any other grant or revocation in the payload
-- is not proof and must not be merged. The same sender and remote rows reuse
-- that result until local history changes.
-- @param sender string "Name-Realm"
-- @param logs table
-- @return table|nil
function Sync:_CatchUpProvenGrantLog(sender, logs)
    if type(logs) ~= "table" or #logs == 0 then return nil end
    local token = self._CatchUpProofToken and self:_CatchUpProofToken(sender, logs) or nil
    local proofCache = self.state and self.state._catchUpProofScan or nil
    if token and self:_CatchUpProofTokenCurrent(proofCache, token) then
        local cached = proofCache.byKey[token.key]
        if cached == false then return nil end
        if cached == true then
            local cachedGrant = nil
            for _, logTable in ipairs(logs) do
                local state = self:_LogAdminGrantState(logTable, sender)
                if state == "grant" then
                    cachedGrant = logTable
                elseif state == "revoke" then
                    cachedGrant = nil
                end
            end
            return cachedGrant
        end
    end
    if not self:_LogsEstablishAdminGrant(logs, sender) then return nil end
    if not (self.state and self:_ProfileAuthorizationKnown()) then return nil end

    local grantLog = nil
    for _, logTable in ipairs(logs) do
        local state = self:_LogAdminGrantState(logTable, sender)
        if state == "grant" then
            grantLog = logTable
        elseif state == "revoke" then
            grantLog = nil
        end
    end
    if type(grantLog) ~= "table" then return nil end
    local grantAuthor = grantLog._author or grantLog.author
    if type(grantAuthor) ~= "string" or grantAuthor == "" then return nil end
    if self:_SamePlayer(grantAuthor, sender) then return nil end
    if not self:IsSenderAuthorized(self.state.profileId, grantAuthor) then return nil end
    -- A stored grant that local history later revoked is not current authority.
    -- The response can omit that removal after a session reset cleared revokedRoutes.
    if self:_LocalHistoryRevokesAdmin(sender) then
        if token then
            self:_StoreCatchUpProof(token, false)
        end
        return nil
    end

    for _, logTable in ipairs(logs) do
        local state = self:_LogAdminGrantState(logTable, sender)
        if state and not self:_GrantRowsMatch(logTable, grantLog) then
            if token then
                self:_StoreCatchUpProof(token, false)
            end
            return nil
        end
    end

    local profile = self:FindLocalProfileById(self.state.profileId)
    local localLogs = (profile and self._GetProfileLootLogs) and self:_GetProfileLootLogs(profile) or nil
    if type(localLogs) ~= "table" then return nil end
    for _, localLog in ipairs(localLogs) do
        local localTable = localLog
        if type(localLog) == "table" and type(localLog.ToTable) == "function" then
            localTable = localLog:ToTable()
        end
        if self:_GrantRowsMatch(localTable, grantLog) then
            if token then
                self:_StoreCatchUpProof(token, true)
            end
            return grantLog
        end
    end
    if token then
        self:_StoreCatchUpProof(token, false)
    end
    return nil
end

function Sync:_StoreCatchUpProof(token, proven)
    if type(token) ~= "table" or not self.state then return end
    local cache = self.state._catchUpProofScan
    if not self:_CatchUpProofTokenCurrent(cache, token) then
        cache = {
            profileId = token.profileId,
            logs = token.logs,
            count = token.count,
            rev = token.rev,
            byKey = {},
        }
        self.state._catchUpProofScan = cache
    end
    local stored = 0
    for _ in pairs(cache.byKey) do
        stored = stored + 1
        if stored >= 32 then
            cache.byKey = {}
            break
        end
    end
    cache.byKey[token.key] = proven == true
end

-- Function True when catch-up logs cite exactly one grant this profile already trusts.
-- @param sender string "Name-Realm"
-- @param logs table
-- @return boolean
function Sync:_CatchUpLogsProveGrant(sender, logs)
    return self:_CatchUpProvenGrantLog(sender, logs) ~= nil
end

-- Function True when a snapshot's admin list names this player.
-- @param snapshot table
-- @param name string "Name-Realm"
-- @return boolean
function Sync:_SnapshotListsAdmin(snapshot, name)
    local admins = type(snapshot) == "table" and snapshot.adminUsers or nil
    if type(admins) ~= "table" then return false end
    for _, admin in ipairs(admins) do
        if self:_SamePlayer(admin, name) then return true end
    end
    return false
end

-- Function Read one wire field under either its stored or plain name.
-- @param row table
-- @param stored string
-- @param plain string
-- @return any
local function _LogField(row, stored, plain)
    local value = row[stored]
    if value == nil then
        value = row[plain]
    end
    return value
end

-- Function True when two plain values are the same, including nested log data.
-- @param a any
-- @param b any
-- @param depth number
-- @return boolean
function Sync:_SamePlainValue(a, b, depth)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if (tonumber(depth) or 0) > 6 then return false end
    local nextDepth = (tonumber(depth) or 0) + 1
    for key, value in pairs(a) do
        if not self:_SamePlainValue(value, b[key], nextDepth) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

-- Function True when two log tables are the same row.
-- A shared _id is not enough. A sender can reuse that id on a different event.
-- @param a table
-- @param b table
-- @return boolean
function Sync:_SameLogTable(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local aId = a._logId or a.logId or a._id or a.id
    local bId = b._logId or b.logId or b._id or b.id
    if type(aId) == "string" and aId ~= "" and type(bId) == "string" and bId ~= "" and aId ~= bId then
        return false
    end
    local aAuthor = a._author or a.author
    local bAuthor = b._author or b.author
    local aCounter = tonumber(a._counter or a.counter)
    local bCounter = tonumber(b._counter or b.counter)
    local aType = a._eventType or a.eventType
    local bType = b._eventType or b.eventType
    if aType ~= bType or aCounter ~= bCounter then return false end
    if type(aAuthor) ~= "string" or type(bAuthor) ~= "string" then return false end
    return self:_SamePlayer(aAuthor, bAuthor)
end

-- Function True when a remote grant is the same stored row, not a rewrite of its id.
-- Author, counter, event, data, and any fingerprint must all agree. A newly
-- computed fingerprint on an ADMIN_ADDED that reuses a local _id is not proof.
-- @param localTable table
-- @param remoteTable table
-- @return boolean
function Sync:_GrantRowsMatch(localTable, remoteTable)
    if not self:_SameLogTable(localTable, remoteTable) then return false end
    local localData = _LogField(localTable, "_data", "data")
    local remoteData = _LogField(remoteTable, "_data", "data")
    if type(localData) ~= "table" or type(remoteData) ~= "table" then return false end
    if not self:_SamePlainValue(localData, remoteData, 0) then return false end
    local localTs = _LogField(localTable, "_timestamp", "timestamp")
    local remoteTs = _LogField(remoteTable, "_timestamp", "timestamp")
    if localTs ~= nil and remoteTs ~= nil and localTs ~= remoteTs then return false end
    local localFp = _LogField(localTable, "_fingerprint", "fingerprint")
    local remoteFp = _LogField(remoteTable, "_fingerprint", "fingerprint")
    if (localFp ~= nil or remoteFp ~= nil) and localFp ~= remoteFp then return false end
    if SF.LootLog and type(SF.LootLog.ComputeFingerprintFromTable) == "function" then
        local computedLocal = SF.LootLog.ComputeFingerprintFromTable(localTable)
        local computedRemote = SF.LootLog.ComputeFingerprintFromTable(remoteTable)
        if computedLocal ~= nil and computedRemote ~= nil and computedLocal ~= computedRemote then
            return false
        end
        if type(localFp) == "number" and computedLocal ~= nil and localFp ~= computedLocal then
            return false
        end
        if type(remoteFp) == "number" and computedRemote ~= nil and remoteFp ~= computedRemote then
            return false
        end
    end
    return true
end

-- Function Attach one player's latest admin grant when serving logs.
-- Gap replies only contain the requested window. The grant often lives on
-- another author. A later removal clears the evidence. One log is appended at most.
-- @param out table Response log list
-- @param profile table
-- @param member string "Name-Realm"
-- @return nil
function Sync:_AppendAdminGrantEvidence(out, profile, member)
    if type(out) ~= "table" or type(profile) ~= "table" then return end
    if type(member) ~= "string" or member == "" then return end
    if type(self._GetProfileLootLogs) ~= "function" then return end
    local latest = nil
    local logs = self:_GetProfileLootLogs(profile)
    for _, log in ipairs(logs) do
        local logTable = log
        if type(log) == "table" and type(log.ToTable) == "function" then
            logTable = log:ToTable()
        end
        local state = self:_LogAdminGrantState(logTable, member, profile)
        if state == "grant" then
            latest = logTable
        elseif state == "revoke" then
            latest = nil
        end
    end
    if type(latest) ~= "table" then return end
    for _, existing in ipairs(out) do
        if self:_SameLogTable(existing, latest) then return end
    end
    out[#out + 1] = latest
end

-- Function Attach this client's latest admin grant when serving logs.
-- Gap replies only contain the requested window. The grant often lives on
-- another author, so the receiver can prove catch-up without failing that window.
-- A later removal clears the evidence. One log is appended at most.
-- @param out table Response log list
-- @param profile table
-- @return nil
function Sync:_AppendSelfAdminGrantEvidence(out, profile)
    self:_AppendAdminGrantEvidence(out, profile, self:_SelfId())
end

-- Function Copy one already-scanned grant into a reply unless that row is present.
-- @param out table Response log list
-- @param grant table|nil
-- @return nil
function Sync:_AttachAdminGrantEvidence(out, grant)
    if type(out) ~= "table" or type(grant) ~= "table" then return end
    for _, existing in ipairs(out) do
        if self:_SameLogTable(existing, grant) then return end
    end
    out[#out + 1] = grant
end

-- Function The member whose grant this request may attach, or nil.
-- needsAdminGrant is only asked of the current coordinator and names that client.
-- adminGrantMember is only the current coordinator, and only when this client
-- may serve that grant. Any other name is ignored before history is read.
-- @param payload table|nil
-- @return string|nil
function Sync:_AdminGrantMemberForRequest(payload)
    if type(payload) ~= "table" or not self.state then return nil end
    if payload.needsAdminGrant == true then
        local selfId = self:_SelfId()
        local coordinator = self.state.coordinator
        if type(selfId) ~= "string" or selfId == "" then return nil end
        if type(coordinator) ~= "string" or not self:_SamePlayer(selfId, coordinator) then
            return nil
        end
        return selfId
    end
    local member = payload.adminGrantMember
    if type(member) ~= "string" or member == "" then return nil end
    if not (self._CanServeAdminGrantRequest and self:_CanServeAdminGrantRequest(payload)) then
        return nil
    end
    return member
end

-- Function One grant row for this request, scanned at most once per timeout.
-- Callers attach the returned row to every range they serve. A repeat inside
-- the request timeout, a miss, and more than four sent replies do not walk
-- history again. A name this client may not serve does not walk history at all.
-- @param sender string "Name-Realm"
-- @param profile table
-- @param payload table|nil
-- @return table|nil
function Sync:_AdminGrantEvidenceForRequest(sender, profile, payload)
    if type(profile) ~= "table" then return nil end
    local member = self:_AdminGrantMemberForRequest(payload)
    if type(member) ~= "string" then return nil end
    if not (self._AdminGrantServeAllowed and self:_AdminGrantServeAllowed(sender, member)) then
        return nil
    end
    if type(payload) == "table" and payload.needsAdminGrant == true then
        if not (self._LocalCatchUpGrantStored and self:_LocalCatchUpGrantStored(member)) then
            if self._NoteAdminGrantMiss then
                self:_NoteAdminGrantMiss(sender, member)
            end
            return nil
        end
    end
    local out = {}
    if self._AppendAdminGrantEvidence then
        self:_AppendAdminGrantEvidence(out, profile, member)
    end
    local grant = out[1]
    if type(grant) ~= "table" then
        if self._NoteAdminGrantMiss then
            self:_NoteAdminGrantMiss(sender, member)
        end
        return nil
    end
    if self._NoteAdminGrantServe then
        self:_NoteAdminGrantServe(sender, member)
    end
    return grant
end

-- Function Catch-up snapshots must prove the sender's grant from local history.
-- Empty history is not proof. The establishing grant must already be stored,
-- authored by someone this profile authorizes, and must name the same member.
-- @param sender string "Name-Realm"
-- @param snapshot table
-- @return boolean
function Sync:_CatchUpSnapshotProvesGrant(sender, snapshot)
    if not self:_SnapshotListsAdmin(snapshot, sender) then return false end
    local logs = nil
    if type(snapshot) == "table" then
        logs = snapshot.logs or snapshot.lootLogs or snapshot._lootLogs
    end
    return self:_CatchUpLogsProveGrant(sender, logs)
end

-- Function True when a repair may still be asked of this preferred provider.
-- LOG_REQ is admin-to-admin. A canonical admin who advertised the window stays
-- a target even when they were not selected as a Helper, but only while they
-- are still in the group. Revoked players, players who left the group, and
-- players who are not admins do not. A catch-up coordinator remains only
-- after the proving grant is already stored.
-- @param name string|nil "Name-Realm"
-- @return boolean
function Sync:_PreferredRepairTargetRoutable(name)
    if type(name) ~= "string" or name == "" then return false end
    if self:_RouteWasRevoked(name) then return false end
    if self._PeerInGroup and not self:_PeerInGroup(name) then return false end
    if self:_CoordinatorNeedsCatchUp(name) then
        return self:_LocalCatchUpGrantStored(name) == true
    end
    if self:_ProfileAuthorizationKnown() then
        return self:IsSenderAuthorized(self.state.profileId, name) == true
    end
    if type(self._CurrentAuthorizedRoutingTargets) ~= "function" then return false end
    local routes = self:_CurrentAuthorizedRoutingTargets({
        preferCoordinatorFirst = true,
        preferredTarget = name,
    })
    for _, route in ipairs(routes) do
        if self:_SamePlayer(route, name) then return true end
    end
    return false
end

-- Function Drop queued repair targets that are no longer allowed to answer.
-- @param explicitOnly boolean|nil When true, clear only players already revoked
-- @return nil
function Sync:_SanitizeQueuedRepairTargets(explicitOnly)
    local queue = self.state and self.state.repairQueue
    if type(queue) ~= "table" or type(queue.items) ~= "table" then return end
    for _, entry in pairs(queue.items) do
        if type(entry) == "table" and type(entry.preferredTarget) == "string" then
            local drop = false
            if explicitOnly then
                drop = self:_RouteWasRevoked(entry.preferredTarget)
            else
                drop = not self:_PreferredRepairTargetRoutable(entry.preferredTarget)
            end
            if drop then
                entry.preferredTarget = nil
            end
        end
    end
end

-- Function Classify a privileged sync response against current auth and this request.
-- Returns "accept", "stale", "unauthorized", "untrusted", "unproven", or "mismatch".
-- Canonical admin checks wait until a local copy of the profile exists. Joining
-- members import PROFILE_SNAPSHOT before that copy exists.
-- A cited request of the wrong kind is a mismatch even when the sender is a
-- coordinator or helper. Missing requests stay on the trusted-sender path so a
-- snapshot can still bootstrap a profile.
-- Catch-up from an advertised coordinator is accepted only when opts.catchUpProven
-- is true. Callers set that only when the grant is already in trusted local history.
-- @param sender string
-- @param profileId string
-- @param req table|nil
-- @param opts table|nil { coordinatorAcceptsAdmins = bool, expectedKinds = table, catchUpProven = bool }
-- @return string
function Sync:_ClassifyPrivilegedResponse(sender, profileId, req, opts)
    opts = type(opts) == "table" and opts or {}
    -- In-flight trust is only for the request that was sent. A cited request of
    -- another kind must not fall through to coordinator/helper trust either.
    if type(opts.expectedKinds) == "table" then
        if type(req) == "table" and opts.expectedKinds[req.kind] ~= true then
            return "mismatch"
        end
        if type(req) ~= "table" then
            req = nil
        end
    end
    if type(req) == "table" and self:_ResponderMapHas(req.revokedResponders, sender) then
        return "stale"
    end
    local profileKnown = false
    if type(profileId) == "string" and profileId ~= "" and type(self.FindLocalProfileById) == "function" then
        profileKnown = self:FindLocalProfileById(profileId) ~= nil
    end
    if profileKnown and not self:IsSenderAuthorized(profileId, sender) then
        local catchUp = self._CoordinatorNeedsCatchUp and self:_CoordinatorNeedsCatchUp(sender)
            and type(req) == "table"
            and self:_ResponderMapHas(req.inflightResponders, sender)
        if not catchUp then
            return "unauthorized"
        end
        -- Correlation alone is not a grant. The payload must show this sender
        -- becoming an admin before any of its other rows are merged.
        if opts.catchUpProven ~= true then
            return "unproven"
        end
    end
    if opts.coordinatorAcceptsAdmins and self.state and self.state.isCoordinator then
        return "accept"
    end
    if self:IsTrustedDataSender(sender) then
        return "accept"
    end
    if type(req) == "table" and self:_ResponderMapHas(req.inflightResponders, sender) then
        return "accept"
    end
    return "untrusted"
end

-- Function Warn once when a response cites a request of the wrong kind.
-- Retries of the same sender and request stay in debug. The request is left open.
-- @param req table|nil
-- @param sender string
-- @param message string
-- @return nil
function Sync:_NoteResponseKindMismatch(req, sender, message)
    local key = tostring(sender or "")
    if type(req) == "table" then
        if type(req.kindMismatchWarned) ~= "table" then
            req.kindMismatchWarned = {}
        end
        if req.kindMismatchWarned[key] then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Repeat kind mismatch from %s for request %s",
                    key, tostring(req.id))
            end
            return
        end
        req.kindMismatchWarned[key] = true
    end
    if SF.PrintWarning and type(message) == "string" and message ~= "" then
        SF:PrintWarning(message)
    end
end

-- Function Session key for one sender's unproven catch-up warning.
-- @param sender string
-- @param profileId string|nil
-- @return string
function Sync:_UnprovenCatchUpWarningKey(sender, profileId)
    local sessionId = (self.state and self.state.sessionId) or ""
    local profile = profileId
    if type(profile) ~= "string" or profile == "" then
        profile = (self.state and self.state.profileId) or ""
    end
    return tostring(sessionId) .. "\0" .. tostring(profile) .. "\0" .. tostring(sender)
end

-- Function Allow the warning again after this sender's authorization changes.
-- @param sender string
-- @param profileId string|nil
-- @return nil
function Sync:_ClearUnprovenCatchUpWarning(sender, profileId)
    local warned = self.state and self.state._unprovenCatchUpWarned
    if type(warned) ~= "table" or type(sender) ~= "string" or sender == "" then return end
    warned[self:_UnprovenCatchUpWarningKey(sender, profileId)] = nil
end

-- Function Warn once per session, profile, and sender when catch-up is unproven.
-- A replacement request for the same sender stays in debug. Authorization
-- changes clear the marker so a later failure can warn again.
-- @param req table|nil
-- @param sender string
-- @param message string
-- @return nil
function Sync:_NoteUnprovenCatchUp(req, sender, message)
    if not self.state then return end
    local key = self:_UnprovenCatchUpWarningKey(sender)
    self.state._unprovenCatchUpWarned = self.state._unprovenCatchUpWarned or {}
    if self.state._unprovenCatchUpWarned[key] then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Repeat unproven catch-up from %s for request %s",
                tostring(sender), tostring(req and req.id))
        end
        return
    end
    self.state._unprovenCatchUpWarned[key] = true
    if SF.PrintWarning and type(message) == "string" and message ~= "" then
        SF:PrintWarning(message)
    end
end

-- Function Routing options that created this request, when it has any.
-- Exact and integrity repairs keep preferredTarget and coordinator-first order.
-- @param req table
-- @return table|nil
function Sync:_RequestRoutingOpts(req)
    local meta = type(req) == "table" and type(req.meta) == "table" and req.meta or nil
    if not meta then return nil end
    local exact = meta.exactAuthor == true or meta.integrityRepair == true
    if not exact then return nil end
    local opts = { preferCoordinatorFirst = true }
    if type(meta.preferredTarget) == "string" and meta.preferredTarget ~= "" then
        opts.preferredTarget = meta.preferredTarget
    end
    return opts
end

-- Function True when the stored coordinator is still someone requests may route to.
-- Unknown profiles stay routable so bootstrap does not clear targets early.
-- @param none
-- @return boolean
function Sync:_CoordinatorIsCurrentRoute()
    if not (self.state and type(self.state.coordinator) == "string" and self.state.coordinator ~= "") then
        return false
    end
    if not self:_ProfileAuthorizationKnown() then return true end
    if self:_CoordinatorNeedsCatchUp(self.state.coordinator) then return true end
    return self:IsSenderAuthorized(self.state.profileId, self.state.coordinator)
        and self:IsTrustedDataSender(self.state.coordinator)
end

-- Function Refresh outstanding request targets based on current helpers/coordinator.
-- Canonical admin revocation removes targets. Routing-only changes keep already-sent
-- responders acceptable until that response arrives, but future sends use the new list.
-- explicitRevocationsOnly keeps targets that a gapped rebuild merely cannot see yet,
-- and drops players already recorded in revokedRoutes.
-- @param opts table|nil { explicitRevocationsOnly = bool }
-- @return nil
function Sync:_RefreshOutstandingRequestTargets(opts)
    if not self.state or not self.state.requests then return end
    opts = type(opts) == "table" and opts or {}
    local explicitOnly = opts.explicitRevocationsOnly == true

    local defaultRoutes = explicitOnly and nil or self:_CurrentAuthorizedRoutingTargets()
    local profileKnown = self:_ProfileAuthorizationKnown()
    local me = self:_SelfId()
    local selfAuthorized = (not profileKnown) or self:IsSenderAuthorized(self.state.profileId, me)
    local toFail = {}

    local function targetRevoked(name)
        if explicitOnly then
            return self:_RouteWasRevoked(name)
        end
        return not self:_IsKnownAuthorizedTarget(name)
    end

    local function clearRestoredTombstone(req, name)
        if type(name) ~= "string" or name == "" then return end
        if targetRevoked(name) then return end
        if not self:_IsKnownAuthorizedTarget(name) then return end
        self:_ForgetResponder(req.revokedResponders, name)
    end

    for _, req in pairs(self.state.requests) do
        if type(req) == "table" then
            if type(req.lastTarget) == "string" and (tonumber(req.attempt) or 0) > 0 then
                if targetRevoked(req.lastTarget) then
                    self:_RememberRevokedResponder(req, req.lastTarget)
                elseif not self:_ResponderMapHas(req.revokedResponders, req.lastTarget) then
                    self:_RememberInflightResponder(req, req.lastTarget)
                end
            end

            local failReason = nil
            if explicitOnly then
                if (req.kind == "ADMIN_LOG_REQ" or req.kind == "LOG_REQ") and self:_RouteWasRevoked(me) then
                    failReason = "no longer authorized"
                elseif req.kind == "ADMIN_LOG_REQ" and not self.state.isCoordinator then
                    failReason = "no longer coordinator"
                end
            elseif req.kind == "ADMIN_LOG_REQ" and not self.state.isCoordinator then
                failReason = "no longer coordinator"
            elseif (req.kind == "ADMIN_LOG_REQ" or req.kind == "LOG_REQ") and not selfAuthorized then
                failReason = "no longer authorized"
            end

            if failReason then
                table.insert(toFail, { req = req, reason = failReason })
            elseif req.kind == "NEED_PROFILE" or req.kind == "NEED_LOGS" then
                local oldTargets = req.targets or {}
                for _, name in ipairs(oldTargets) do
                    if targetRevoked(name) then
                        self:_RememberRevokedResponder(req, name)
                    else
                        clearRestoredTombstone(req, name)
                    end
                end
                local nextTargets = oldTargets
                if not explicitOnly then
                    local routeOpts = self:_RequestRoutingOpts(req)
                    nextTargets = routeOpts and self:_CurrentAuthorizedRoutingTargets(routeOpts) or defaultRoutes
                else
                    nextTargets = {}
                    for _, name in ipairs(oldTargets) do
                        if not targetRevoked(name) then
                            table.insert(nextTargets, name)
                        end
                    end
                end
                for _, name in ipairs(nextTargets) do
                    clearRestoredTombstone(req, name)
                end
                -- An empty route before a successor is stored would fail the request
                -- on the next send. Hold the existing list until takeover or a
                -- heartbeat names someone requests can use.
                local holdForSuccessor = (not explicitOnly) and #nextTargets == 0
                    and (not profileKnown or not self:_CoordinatorIsCurrentRoute())
                if not holdForSuccessor and not self:_SamePlayerList(oldTargets, nextTargets) then
                    self:_RetargetRequestList(req, self:_CopyPlayerList(nextTargets))
                end
            elseif req.kind == "LOG_REQ" or req.kind == "ADMIN_LOG_REQ" then
                local oldTargets = req.targets or {}
                local kept = {}
                for _, name in ipairs(oldTargets) do
                    if targetRevoked(name) then
                        self:_RememberRevokedResponder(req, name)
                    else
                        clearRestoredTombstone(req, name)
                        table.insert(kept, name)
                    end
                end
                if not self:_SamePlayerList(oldTargets, kept) then
                    self:_RetargetRequestList(req, kept)
                end
            end
        end
    end

    for _, item in ipairs(toFail) do
        if self._FailRequest then
            self:_FailRequest(item.req, item.reason)
        end
    end
end

-- Function Drop an in-progress convergence without running its announce hook.
-- Request failure during revocation must not broadcast a session this client
-- is no longer allowed to coordinate.
-- @param reason string|nil
-- @return nil
function Sync:_CancelAdminConvergenceTimers(conv)
    if type(conv) ~= "table" or type(conv.timerHandles) ~= "table" then return end
    for i = 1, #conv.timerHandles do
        local handle = conv.timerHandles[i]
        if type(handle) == "table" and type(handle.Cancel) == "function" then
            pcall(function()
                handle:Cancel()
            end)
        end
    end
    conv.timerHandles = nil
end

function Sync:_TrackAdminConvergenceTimer(handle)
    local conv = self.state and self.state._adminConvergence
    if type(conv) ~= "table" or handle == nil then return end
    conv.timerHandles = conv.timerHandles or {}
    conv.timerHandles[#conv.timerHandles + 1] = handle
end

function Sync:_AbandonAdminConvergence(reason)
    local conv = self.state and self.state._adminConvergence
    if type(conv) ~= "table" then return end
    self:_CancelAdminConvergenceTimers(conv)
    conv.finished = true
    conv.onComplete = nil
    self.state._adminConvergence = nil
    if SF.Debug then
        SF.Debug:Info("SYNC", "Abandoned admin convergence without announcing (reason=%s)",
            tostring(reason or "unknown"))
    end
end

-- Function Stop privileged coordination after this client loses canonical admin.
-- Another in-group admin takes over through the existing takeover path.
-- With no eligible replacement, the session ends.
-- Convergence is abandoned before outstanding admin requests fail, so the
-- completion hook cannot announce a session this client no longer coordinates.
-- @param reason string|nil
-- @param opts table|nil { explicitRevocationsOnly = bool }
-- @return boolean True when coordination was relinquished
function Sync:RelinquishUnauthorizedCoordination(reason, opts)
    if not (self.state and self.state.active and self.state.isCoordinator) then return false end
    local profileId = self.state.profileId
    if not self:_ProfileAuthorizationKnown() then return false end
    if self:IsSenderAuthorized(profileId, self:_SelfId()) then return false end
    if self._relinquishingCoordination then return false end
    opts = type(opts) == "table" and opts or {}
    self._relinquishingCoordination = true

    self:_AbandonAdminConvergence(reason)
    if self.StopHeartbeatSender then
        self:StopHeartbeatSender("coordinator_lost_admin:" .. tostring(reason or "unknown"))
    end
    if self._RefreshOutstandingRequestTargets then
        self:_RefreshOutstandingRequestTargets({
            explicitRevocationsOnly = opts.explicitRevocationsOnly == true,
        })
    end

    local candidates = {}
    if type(self._ComputeTakeoverCandidates) == "function" then
        candidates = self:_ComputeTakeoverCandidates(profileId) or {}
    end

    if #candidates == 0 then
        -- Keep the guard until EndSession returns. A pending BiS frontier
        -- makes EndSession broadcast a heartbeat, and that heartbeat calls
        -- this function again. Clearing the guard first recurses on the UI
        -- thread until the frontier flag is cleared.
        if self.EndSession then
            self:EndSession("coordinator_lost_admin", true)
        else
            self.state.isCoordinator = false
            self.state.active = false
        end
        self._relinquishingCoordination = nil
        return true
    end

    -- Leave the session id in place so the existing heartbeat-timeout and
    -- explicit takeover paths can move coordination to an eligible admin.
    self.state.isCoordinator = false
    if self.EnsureHeartbeatSender then
        self:EnsureHeartbeatSender("coordinator_lost_admin")
    end
    if self.EnsureHeartbeatMonitor then
        self:EnsureHeartbeatMonitor("coordinator_lost_admin")
    end
    self._relinquishingCoordination = nil
    if SF.Debug then
        SF.Debug:Info("SYNC", "Relinquished coordination after admin revocation (reason=%s, successors=%d)",
            tostring(reason or "unknown"), #candidates)
    end
    return true
end

-- Function Eligible admins assume coordination when the current coordinator is no longer an admin.
-- A coordinator recorded for catch-up is missing locally, not removed. Taking over
-- would split that session before the grant is fetched.
-- @param reason string|nil
-- @return boolean
function Sync:_MaybeAssumeCoordinationAfterAdminChange(reason)
    if not (self.state and self.state.active) or self.state.isCoordinator then return false end
    local profileId = self.state.profileId
    if type(profileId) ~= "string" or type(self.state.coordinator) ~= "string" then return false end
    if not self:_ProfileAuthorizationKnown() then return false end
    if self:IsSenderAuthorized(profileId, self.state.coordinator) then return false end
    if self:_CoordinatorNeedsCatchUp(self.state.coordinator) then return false end
    if type(self.CanSelfCoordinate) == "function" and not self:CanSelfCoordinate(profileId) then
        return false
    end
    if type(self._ComputeTakeoverCandidates) ~= "function" or type(self.TakeoverSession) ~= "function" then
        return false
    end

    local candidates = self:_ComputeTakeoverCandidates(profileId) or {}
    if #candidates == 0 or not self:_SamePlayer(candidates[1], self:_SelfId()) then
        return false
    end

    local marker = tostring(self.state.sessionId) .. ":" .. tostring(self.state.coordEpoch)
    if self.state._unauthorizedCoordTakeoverFor == marker then return false end
    self.state._unauthorizedCoordTakeoverFor = marker

    local took = self:TakeoverSession(self.state.sessionId, profileId, reason or "coordinator_lost_admin", {
        rerunAdminConvergence = true,
    })
    if took ~= true then
        self.state._unauthorizedCoordTakeoverFor = nil
    end
    return took == true
end

-- Function Drop convergence evidence from players who are no longer canonical admins.
-- @param none
-- @return nil
function Sync:_DropUnauthorizedAdminStatuses()
    if not self:_ProfileAuthorizationKnown() then return end
    local statuses = self.state and self.state.adminStatuses
    if type(statuses) ~= "table" then return end
    local profileId = self.state.profileId
    local drop = {}
    for name, _ in pairs(statuses) do
        if type(name) == "string" and not self:IsSenderAuthorized(profileId, name) then
            drop[#drop + 1] = name
        end
    end
    for i = 1, #drop do
        statuses[drop[i]] = nil
        self:_RememberRevokedRoute(drop[i])
    end
end

-- Function Drop one player's convergence evidence without touching other advertisers.
-- Used when a live ADMIN_REMOVED names that player. A gapped rebuild must not
-- discard every status that the recomputed admin list does not yet contain.
-- @param name string "Name-Realm"
-- @return nil
function Sync:_DropNamedAdminStatus(name)
    if type(name) ~= "string" or name == "" then return end
    local statuses = self.state and self.state.adminStatuses
    if type(statuses) ~= "table" then return end
    local drop = {}
    for key, _ in pairs(statuses) do
        if type(key) == "string" and self:_SamePlayer(key, name) then
            drop[#drop + 1] = key
        end
    end
    for i = 1, #drop do
        statuses[drop[i]] = nil
        self:_RememberRevokedRoute(drop[i])
    end
end

-- Function Drop a live ADMIN_REMOVED player's status only when they are no longer an admin.
-- An owner or a later re-grant can remain canonical after the removal log is replayed.
-- @param profileId string
-- @param name string "Name-Realm"
-- @return nil
function Sync:_DropLiveRemovedAdminStatus(profileId, name)
    if self._ProfileAuthorizationKnown and self:_ProfileAuthorizationKnown()
        and self:IsSenderAuthorized(profileId, name)
    then
        return
    end
    self:_DropNamedAdminStatus(name)
    if self._ProfileAuthorizationKnown and self:_ProfileAuthorizationKnown() then
        self:_RememberRevokedRoute(name)
    end
end

-- Function Apply revocations already recorded, without reading a gapped admin list.
-- A rebuild can omit ADMIN_ADDED for peers who are still canonical. Only players
-- in revokedRoutes lose routes here. Takeover waits for a non-rebuild reconcile
-- so candidate order is not chosen from that incomplete list.
-- @param reason string|nil
-- @return nil
function Sync:_ApplyExplicitRevocationRouting(reason)
    if not self.state then return end
    local me = self:_SelfId()
    if self.state.isCoordinator and self:_RouteWasRevoked(me) then
        self:RelinquishUnauthorizedCoordination(reason or "admin_removed", {
            explicitRevocationsOnly = true,
        })
        if not (self.state and self.state.active) then return end
    end

    local helpers = self:_CopyPlayerList(self.state.helpers)
    local kept = {}
    local changed = false
    for _, name in ipairs(helpers) do
        if self:_RouteWasRevoked(name) then
            changed = true
        else
            table.insert(kept, name)
        end
    end
    if changed then
        self.state.helpers = kept
        if SF.Debug then
            SF.Debug:Info("SYNC", "Helper routing dropped explicit revocations (%s, count=%d)",
                tostring(reason or "update"), #kept)
        end
    end
    if self._RefreshOutstandingRequestTargets then
        self:_RefreshOutstandingRequestTargets({ explicitRevocationsOnly = true })
    end
    if self._SanitizeQueuedRepairTargets then
        self:_SanitizeQueuedRepairTargets(true)
    end
end

-- Function Reconcile helper routing, outstanding requests, and coordination with canonical admins.
-- @param profileId string
-- @param reason string|nil
-- @return nil
function Sync:ReconcileSessionAuthorization(profileId, reason)
    if self._reconcilingSessionAuthorization then return end
    if not (self.state and self.state.active) then return end
    if type(profileId) ~= "string" or profileId == "" then return end
    if self.state.profileId ~= profileId then return end
    if not self:_ProfileAuthorizationKnown() then return end

    self._reconcilingSessionAuthorization = true
    -- History replay, including a live NEW_LOG rebuild, recomputes _adminUsers
    -- before this runs. Peers can disappear from that incomplete list while
    -- their ADMIN_STATUS windows are still the evidence that identity-admin
    -- reconcile must wait on. An explicit admin-list change still drops every
    -- revoked entry. A live ADMIN_REMOVED or ROLE_CHANGE to member drops only that player.
    -- A live NEW_LOG rebuild can omit ADMIN_ADDED rows that are still in
    -- flight. Defer helper filtering, retarget, relinquish, and takeover
    -- unless a player was already recorded in revokedRoutes.
    -- auth_logs, profile_snapshot, and session-start rebuilds replay repaired
    -- history, so they update routes. They still keep advertiser statuses for
    -- identity reconcile.
    local reasonText = tostring(reason or "")
    if reasonText == "rebuild:live_update" then
        self:_ApplyExplicitRevocationRouting(reasonText)
        self._reconcilingSessionAuthorization = nil
        return
    end

    local isRebuild = reasonText:sub(1, 8) == "rebuild:"
    if not isRebuild then
        self:_DropUnauthorizedAdminStatuses()
    end
    local coordinator = self.state.coordinator
    if type(coordinator) == "string" and coordinator ~= ""
        and not self:IsSenderAuthorized(profileId, coordinator)
    then
        -- A reload, session start, bootstrap snapshot, or coordinator already on
        -- catch-up can name a successor the local admin list has not absorbed yet.
        -- The first snapshot is that list: a helper copy can omit the grant
        -- without containing a removal. Ordinary later snapshots and AUTH_LOGS
        -- rebuilds must not turn an existing catch-up into a revocation before
        -- the grant request finishes. A local ADMIN_REMOVED or role demotion
        -- still revokes.
        local restoring = reasonText:sub(1, 8) == "restore:"
        local sessionStartMember = reasonText == "rebuild:session_start_member"
        local bootstrapSnapshot = reasonText == "rebuild:profile_snapshot_new"
        local existingCatchUp = self._CoordinatorNeedsCatchUp
            and self:_CoordinatorNeedsCatchUp(coordinator)
        if (restoring or sessionStartMember or bootstrapSnapshot or existingCatchUp)
            and not self:_LocalHistoryRevokesAdmin(coordinator)
        then
            if self._NoteAdvertisedCoordinator then
                self:_NoteAdvertisedCoordinator(coordinator)
            end
        else
            self:_RememberRevokedRoute(coordinator)
        end
    end

    local me = self:_SelfId()
    local selfAuthorized = self:IsSenderAuthorized(profileId, me)
    -- Abandon convergence before request refresh can finish it and announce.
    if self.state.isCoordinator and not selfAuthorized then
        self:RelinquishUnauthorizedCoordination(reason or "admin_removed")
    end
    if not (self.state and self.state.active) then
        self._reconcilingSessionAuthorization = nil
        return
    end

    local changed = false
    if self.ApplyAdvertisedHelpers then
        changed = self:ApplyAdvertisedHelpers(self.state.helpers, reason or "admin_reconcile")
    end
    if not changed and self._RefreshOutstandingRequestTargets then
        self:_RefreshOutstandingRequestTargets()
    end
    if self._SanitizeQueuedRepairTargets then
        self:_SanitizeQueuedRepairTargets(false)
    end

    if changed and self.state.isCoordinator and selfAuthorized and self.BroadcastSessionHeartbeat then
        self:BroadcastSessionHeartbeat()
    elseif (not self.state.isCoordinator) and self._MaybeAssumeCoordinationAfterAdminChange then
        self:_MaybeAssumeCoordinationAfterAdminChange(reason or "admin_removed")
    end

    self._reconcilingSessionAuthorization = nil
end

-- Function Compare an incoming epoch to our current epoch (tie-break if needed).
-- @param incomingEpoch number|string Incoming epoch value
-- @param incomingCoordinator string "Name-Realm" of incoming coordinator (for tie-break)
-- @return number|nil 1 if incoming is newer, -1 if older, 0 if equal, nil if invalid
function Sync:_CompareEpoch(incomingEpoch, incomingCoordinator)
    local inc = tonumber(incomingEpoch)
    if not inc then return nil end

    local cur = tonumber(self.state.coordEpoch) or 0
    if inc > cur then return 1 end
    if inc < cur then return -1 end

    -- tie-break on coordinator id for deterministic convergence
    local incC = self:_NormalizeNameRealmForCompare(incomingCoordinator) or ""
    local curC = self:_NormalizeNameRealmForCompare(self.state.coordinator) or ""
    if incC == curC then return 0 end
    return (incC > curC) and 1 or -1
end

-- Function Determine if an incoming control message is allowed based on coordEpoch.
-- @param payload table Must include sessionId + coordEpoch where applicable
-- @param sender string "Name-Realm" of sender
-- @return boolean True if allowed, false otherwise
function Sync:IsControlMessageAllowed(payload, sender)
    if type(payload) ~= "table" then return true end
    if type(payload.coordEpoch) ~= "number" then return true end

    local incomingCoordinator = payload.coordinator or sender
    local cmp = self:_CompareEpoch(payload.coordEpoch, incomingCoordinator)
    if cmp == nil then return false end
    return cmp >= 0
end

-- Function Determine if an epoch value is newer than our current epoch (tie-break if needed).
-- @param incomingEpoch number|string Incoming epoch value
-- @param incomingCoordinator string "Name-Realm" of incoming coordinator (for tie-break)
-- @return boolean True if incoming is newer, false otherwise
function Sync:IsNewerEpoch(incomingEpoch, incomingCoordinator)
    return self:_CompareEpoch(incomingEpoch, incomingCoordinator) == 1
end

-- Function Validate whether sender is permitted to provide data for a profile (admin check).
-- @param profileId string Profile id
-- @param sender string "Name-Realm" of sender
-- @return boolean True if sender is admin of profile, false otherwise
function Sync:IsSenderAuthorized(profileId, sender)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return false end
    local admins = self:_GetProfileAdminUsers(profile)
    if type(admins) ~= "table" then return false end

    for _, admin in ipairs(admins) do
        if self:_SamePlayer(admin, sender) then return true end
    end
    return false
end

-- Function Check if the given profileId authorizes the sender as an admin.
-- @param profileId string Stable profile id
-- @return boolean True if sender is authorized admin, false otherwise
function Sync:CanSelfCoordinate(profileId)
    local dist = self:_EnforceGroupedSessionActive("CanSelfCoordinate")
    if not dist then
        return false, "Not in a group/raid"
    end

    local me = self:_SelfId()
    if not self:IsSenderAuthorized(profileId, me)
    then
        return false, "You are not an admin for the selected profile"
    end

    return true, nil
end



-- Function Check if a given player is a helper in the current session.
-- @param nameRealm string Player identifier ("Name-Realm")
-- @return boolean True if nameRealm is in helpers list, false otherwise
function Sync:IsHelper(nameRealm)
    if type(nameRealm) ~= "string" or nameRealm == "" then return false end
    if not self.state.helpers or type(self.state.helpers) ~= "table" then return false end

    -- Normalize input
    local normalizedInput = nameRealm
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        normalizedInput = SF.NameUtil.NormalizeNameRealm(nameRealm)
        if not normalizedInput then return false end
    end

    -- Check each helper in array
    for _, helper in ipairs(self.state.helpers) do
        local normalizedHelper = helper
        if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
            normalizedHelper = SF.NameUtil.NormalizeNameRealm(helper)
        end

        -- Compare using SamePlayer when available, else string equality
        if SF.NameUtil and SF.NameUtil.SamePlayer then
            if SF.NameUtil.SamePlayer(normalizedInput, normalizedHelper) then
                return true
            end
        else
            if normalizedInput == normalizedHelper then
                return true
            end
        end
    end

    return false
end

-- Function Check if the local player is a helper in the current session.
-- @param none
-- @return boolean True if self is helper, false otherwise
function Sync:IsSelfHelper()
    local selfId = self:_SelfId()
    if not selfId then return false end
    return self:IsHelper(selfId)
end

-- Function Check if sender is trusted to send authoritative data (coordinator or helper).
-- @param sender string Player identifier ("Name-Realm")
-- @return boolean True if sender is coordinator or helper, false otherwise
function Sync:IsTrustedDataSender(sender)
    if type(sender) ~= "string" or sender == "" then return false end

    -- Normalize sender
    local normalizedSender = sender
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        normalizedSender = SF.NameUtil.NormalizeNameRealm(sender)
        if not normalizedSender then return false end
    end

    -- Check if sender is coordinator
    if self.state.coordinator then
        local normalizedCoordinator = self.state.coordinator
        if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
            normalizedCoordinator = SF.NameUtil.NormalizeNameRealm(self.state.coordinator)
        end

        if SF.NameUtil and SF.NameUtil.SamePlayer then
            if SF.NameUtil.SamePlayer(normalizedSender, normalizedCoordinator) then
                return true
            end
        else
            if normalizedSender == normalizedCoordinator then
                return true
            end
        end
    end

    -- Check if sender is helper
    if self:IsHelper(normalizedSender) then
        return true
    end

    return false
end

-- Function Check if requester is in the current group roster.
-- @param sender string Player identifier ("Name-Realm")
-- @return boolean True if sender is in group and peer.inGroup is true, false otherwise
function Sync:IsRequesterInGroup(sender)
    if type(sender) ~= "string" or sender == "" then return false end

    -- Normalize sender
    local normalizedSender = sender
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        normalizedSender = SF.NameUtil.NormalizeNameRealm(sender)
        if not normalizedSender then return false end
    end

    -- Update roster to get current group state
    self:UpdatePeersFromRoster()

    -- Get peer record
    local peer = self:GetPeer(normalizedSender)
    if not peer then return false end

    return peer.inGroup == true
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

