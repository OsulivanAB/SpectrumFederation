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
    return self:IsSenderAuthorized(self.state.profileId, name) == true
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

-- Function Drop helpers who are no longer canonical admins.
-- @param helpers table|nil Advertised helper names
-- @return table
function Sync:_FilterHelpersToAuthorized(helpers)
    local out = self:_CopyPlayerList(helpers)
    if not self:_ProfileAuthorizationKnown() then return out end
    local filtered = {}
    local profileId = self.state.profileId
    for _, name in ipairs(out) do
        if self:IsSenderAuthorized(profileId, name) then
            table.insert(filtered, name)
        end
    end
    return filtered
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
    for _, name in ipairs(targets) do
        -- Preferred repair targets must still be a current coordinator or helper.
        -- A former helper who remains an admin is not a new request target.
        if self:IsSenderAuthorized(profileId, name) and self:IsTrustedDataSender(name) then
            table.insert(out, name)
        end
    end
    return out
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

-- Function Classify a privileged sync response against current auth and this request.
-- Returns "accept", "stale", "unauthorized", or "untrusted".
-- Canonical admin checks wait until a local copy of the profile exists. Joining
-- members import PROFILE_SNAPSHOT before that copy exists.
-- @param sender string
-- @param profileId string
-- @param req table|nil
-- @param opts table|nil { coordinatorAcceptsAdmins = bool }
-- @return string
function Sync:_ClassifyPrivilegedResponse(sender, profileId, req, opts)
    opts = type(opts) == "table" and opts or {}
    -- In-flight trust is only for the request that was sent. A log request must
    -- not authorize a later PROFILE_SNAPSHOT that cites the same id.
    if type(opts.expectedKinds) == "table" then
        if type(req) ~= "table" or opts.expectedKinds[req.kind] ~= true then
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
        return "unauthorized"
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
    return self:IsSenderAuthorized(self.state.profileId, self.state.coordinator)
        and self:IsTrustedDataSender(self.state.coordinator)
end

-- Function Refresh outstanding request targets based on current helpers/coordinator.
-- Canonical admin revocation removes targets. Routing-only changes keep already-sent
-- responders acceptable until that response arrives, but future sends use the new list.
-- @param none
-- @return nil
function Sync:_RefreshOutstandingRequestTargets()
    if not self.state or not self.state.requests then return end

    local defaultRoutes = self:_CurrentAuthorizedRoutingTargets()
    local profileKnown = self:_ProfileAuthorizationKnown()
    local me = self:_SelfId()
    local selfAuthorized = (not profileKnown) or self:IsSenderAuthorized(self.state.profileId, me)
    local toFail = {}

    for _, req in pairs(self.state.requests) do
        if type(req) == "table" then
            if type(req.lastTarget) == "string" and (tonumber(req.attempt) or 0) > 0 then
                if self:_IsKnownAuthorizedTarget(req.lastTarget) then
                    self:_RememberInflightResponder(req, req.lastTarget)
                else
                    self:_RememberRevokedResponder(req, req.lastTarget)
                end
            end

            local failReason = nil
            if req.kind == "ADMIN_LOG_REQ" and not self.state.isCoordinator then
                failReason = "no longer coordinator"
            elseif (req.kind == "ADMIN_LOG_REQ" or req.kind == "LOG_REQ") and not selfAuthorized then
                failReason = "no longer authorized"
            end

            if failReason then
                table.insert(toFail, { req = req, reason = failReason })
            elseif req.kind == "NEED_PROFILE" or req.kind == "NEED_LOGS" then
                local oldTargets = req.targets or {}
                for _, name in ipairs(oldTargets) do
                    if not self:_IsKnownAuthorizedTarget(name) then
                        self:_RememberRevokedResponder(req, name)
                    end
                end
                local routeOpts = self:_RequestRoutingOpts(req)
                local nextTargets = routeOpts and self:_CurrentAuthorizedRoutingTargets(routeOpts) or defaultRoutes
                -- An empty route before a successor is stored would fail the request
                -- on the next send. Hold the existing list until takeover or a
                -- heartbeat names someone requests can use.
                local holdForSuccessor = #nextTargets == 0
                    and (not profileKnown or not self:_CoordinatorIsCurrentRoute())
                if not holdForSuccessor and not self:_SamePlayerList(oldTargets, nextTargets) then
                    self:_RetargetRequestList(req, self:_CopyPlayerList(nextTargets))
                end
            elseif req.kind == "LOG_REQ" or req.kind == "ADMIN_LOG_REQ" then
                local oldTargets = req.targets or {}
                local kept = {}
                for _, name in ipairs(oldTargets) do
                    if self:_IsKnownAuthorizedTarget(name) then
                        table.insert(kept, name)
                    else
                        self:_RememberRevokedResponder(req, name)
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

-- Function Stop privileged coordination after this client loses canonical admin.
-- Another in-group admin takes over through the existing takeover path.
-- With no eligible replacement, the session ends.
-- @param reason string|nil
-- @return boolean True when coordination was relinquished
function Sync:RelinquishUnauthorizedCoordination(reason)
    if not (self.state and self.state.active and self.state.isCoordinator) then return false end
    local profileId = self.state.profileId
    if not self:_ProfileAuthorizationKnown() then return false end
    if self:IsSenderAuthorized(profileId, self:_SelfId()) then return false end
    if self._relinquishingCoordination then return false end
    self._relinquishingCoordination = true

    if self.StopHeartbeatSender then
        self:StopHeartbeatSender("coordinator_lost_admin:" .. tostring(reason or "unknown"))
    end
    if self._RefreshOutstandingRequestTargets then
        self:_RefreshOutstandingRequestTargets()
    end

    local candidates = {}
    if type(self._ComputeTakeoverCandidates) == "function" then
        candidates = self:_ComputeTakeoverCandidates(profileId) or {}
    end

    if #candidates == 0 then
        self._relinquishingCoordination = nil
        if self.EndSession then
            self:EndSession("coordinator_lost_admin", true)
        else
            self.state.isCoordinator = false
            self.state.active = false
        end
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
-- @param reason string|nil
-- @return boolean
function Sync:_MaybeAssumeCoordinationAfterAdminChange(reason)
    if not (self.state and self.state.active) or self.state.isCoordinator then return false end
    local profileId = self.state.profileId
    if type(profileId) ~= "string" or type(self.state.coordinator) ~= "string" then return false end
    if not self:_ProfileAuthorizationKnown() then return false end
    if self:IsSenderAuthorized(profileId, self.state.coordinator) then return false end
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
    -- History replay recomputes _adminUsers before this runs. Peers can
    -- disappear from that list while their ADMIN_STATUS windows are still the
    -- evidence that identity-admin reconcile must wait on. A live ADMIN_REMOVED
    -- is an explicit revocation, so that rebuild still drops the revoked entry.
    local reasonText = tostring(reason or "")
    local isHistoryReplay = reasonText:sub(1, 8) == "rebuild:"
        and reasonText ~= "rebuild:live_admin_removed"
    if not isHistoryReplay then
        self:_DropUnauthorizedAdminStatuses()
    end

    local changed = false
    if self.ApplyAdvertisedHelpers then
        changed = self:ApplyAdvertisedHelpers(self.state.helpers, reason or "admin_reconcile")
    end
    if not changed and self._RefreshOutstandingRequestTargets then
        self:_RefreshOutstandingRequestTargets()
    end

    local me = self:_SelfId()
    local selfAuthorized = self:IsSenderAuthorized(profileId, me)
    if self.state.isCoordinator and not selfAuthorized then
        self:RelinquishUnauthorizedCoordination(reason or "admin_removed")
    elseif changed and self.state.isCoordinator and selfAuthorized and self.BroadcastSessionHeartbeat then
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

