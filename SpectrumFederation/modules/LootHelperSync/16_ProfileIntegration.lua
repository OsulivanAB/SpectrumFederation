local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync

local function _NormalizeMemberId(id)
    if type(id) ~= "string" or id == "" then return nil end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(id)
    end
    return id
end

local function _BuildEmptyArmor()
    local armor = {}
    if SF.ArmorSlots then
        for _, slotName in pairs(SF.ArmorSlots) do
            armor[slotName] = false
        end
    end
    return armor
end

local function _ResetMemberState(member)
    if not member then return end
    member.pointBalance = 0
    member.attendanceBalance = 0
    member.armor = _BuildEmptyArmor()
    if not member.role and SF.MemberRoles then
        member.role = SF.MemberRoles.MEMBER
    end
end

local function _MemberId(member)
    if type(member) ~= "table" then return nil end
    local id =
        (member.GetFullIdentifier and member:GetFullIdentifier())
        or member.identifier
        or member.id
    return _NormalizeMemberId(id)
end

local function _BuildPointsSummary(profile)
    local members = (type(profile) == "table" and type(profile._members) == "table") and profile._members or {}
    local count, sum = 0, 0
    local checksum = 0
    local sortable = {}

    for _, member in ipairs(members) do
        local id = _MemberId(member)
        if id then
            local points = tonumber(member.pointBalance) or 0
            count = count + 1
            sum = sum + points
            table.insert(sortable, { id = id, points = points })
        end
    end

    table.sort(sortable, function(a, b)
        return a.id < b.id
    end)

    for _, row in ipairs(sortable) do
        local s = ("%s=%d"):format(row.id, row.points)
        for i = 1, #s do
            -- Lightweight deterministic rolling checksum (djb2-inspired variant):
            -- multiplier 33 keeps low cost, modulo 2^31-1 keeps value bounded.
            checksum = (checksum * 33 + s:byte(i)) % 2147483647
        end
    end

    return {
        count = count,
        sum = sum,
        checksum = checksum,
    }
end


-- Function Get admin users from profile (tolerant to different implementations).
-- @param profile table Profile instance
-- @return table Array of admin user names (empty if unavailable)
function Sync:_GetProfileAdminUsers(profile)
    if type(profile) ~= "table" then return {} end
    
    if type(profile.GetAdminUsers) == "function" then
        local ok, result = pcall(profile.GetAdminUsers, profile)
        if ok and type(result) == "table" then
            return result
        end
    end
    
    if type(profile._adminUsers) == "table" then
        return profile._adminUsers
    end
    
    return {}
end

-- Function Get loot logs from profile (tolerant to different implementations).
-- @param profile table Profile instance
-- @return table Array of loot logs (empty if unavailable)
function Sync:_GetProfileLootLogs(profile)
    if type(profile) ~= "table" then return {} end
    
    if type(profile.GetLootLogs) == "function" then
        local ok, result = pcall(profile.GetLootLogs, profile)
        if ok and type(result) == "table" then
            return result
        end
    end
    
    if type(profile._lootLogs) == "table" then
        return profile._lootLogs
    end
    
    return {}
end

-- Function Find a local profile by stable profileId.
-- Uses canonical profileId-based schema (SF.lootHelperDB.profiles[profileId]).
-- @param profileId string Stable profile id
-- @return table|nil LootProfile instance or nil if not found
function Sync:FindLocalProfileById(profileId)
    if not SF.lootHelperDB then return nil end
    if type(profileId) ~= "string" or profileId == "" then return nil end

    -- Direct lookup in canonical profileId-based map (O(1))
    if SF.lootHelperDB.profiles and type(SF.lootHelperDB.profiles) == "table" then
        local profile = SF.lootHelperDB.profiles[profileId]
        if profile and type(profile) == "table" and profile.GetProfileId then
            local pid = profile:GetProfileId()
            if pid == profileId then
                return profile
            end
        end
        
        -- Fallback: iterate for legacy/alternate indexing
        for _, p in pairs(SF.lootHelperDB.profiles) do
            if type(p) == "table" then
                -- Try GetProfileId method
                if type(p.GetProfileId) == "function" then
                    local ok, pid = pcall(p.GetProfileId, p)
                    if ok and pid == profileId then
                        return p
                    end
                end
                
                -- Try _profileId property
                if p._profileId == profileId then
                    return p
                end
            end
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
    profile._logById = {}
    profile._logPositionIndex = {}
    profile._logFingerprintIndex = {}
    profile._authorWindowSummary = {}
    profile._authorWindowSummaryDirty = true
    profile._authorWindowSummarySize = nil
    profile._authorCounters = {}
    profile._members = {}
	profile._adminUsers = {}
	profile._activeProfile = false
	profile._profileId = profileMeta._profileId
	profile._profileName = profileMeta._profileName or "Imported Profile"
	if profile._EnsureRaidCheckConfig then
		profile:_EnsureRaidCheckConfig()
	end

	return profile
end

function Sync:GetIntegrityWindowSize()
    local size = tonumber(self.cfg and self.cfg.integrityWindowSize) or 25
    size = math.floor(size)
    if size < 1 then
        size = 25
    end
    return size
end

function Sync:ComputeAuthorWindowSummary(profileId)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return {} end
    if profile.ComputeAuthorWindowSummary then
        return profile:ComputeAuthorWindowSummary(self:GetIntegrityWindowSize())
    end
    return {}
end

-- Protocol 2 authorWindowSummary is still per raw `_author` with count,
-- checksum, and maxCounter. A higher local raw max is not set containment.
-- Emit integrity whenever the advertised filled set is not proven present
-- locally. Partial windows request through maxCounter until logical contig
-- covers the whole bucket, so AUTH_LOGS can complete a filled frontier
-- without waiting for counters the advertiser never claimed.
function Sync:ComputeWindowMismatchRequests(profileId, remoteSummary, localContig)
    local mismatches = {}
    if type(remoteSummary) ~= "table" then return mismatches end

    localContig = localContig or self:ComputeContigAuthorMax(profileId)

    for author, windows in pairs(remoteSummary) do
        if type(author) == "string" and type(windows) == "table" then
            local authorContig = 0
            if self._LogicalContigForAuthor then
                authorContig = self:_LogicalContigForAuthor(localContig, author)
            else
                authorContig = tonumber(localContig and localContig[author]) or 0
            end
            for _, remoteWindow in ipairs(windows) do
                if type(remoteWindow) == "table"
                    and type(remoteWindow.fromCounter) == "number"
                    and type(remoteWindow.toCounter) == "number"
                then
                    local remoteCount = tonumber(remoteWindow.count) or 0
                    if remoteCount > 0
                        and not self:_IsAdvertisedExactWindowContained(profileId, author, remoteWindow)
                    then
                        local remoteFilledTo = tonumber(remoteWindow.maxCounter) or 0
                        local remoteChecksum = tonumber(remoteWindow.checksum)
                        local reqTo = remoteWindow.toCounter
                        if authorContig < remoteWindow.toCounter and remoteFilledTo > 0 then
                            reqTo = remoteFilledTo
                        end
                        if reqTo >= remoteWindow.fromCounter then
                            local evidence = {
                                fromCounter = remoteWindow.fromCounter,
                                toCounter = remoteWindow.toCounter,
                                count = remoteCount,
                                maxCounter = remoteFilledTo,
                                checksum = remoteChecksum,
                            }
                            mismatches[#mismatches + 1] = {
                                author = author,
                                fromCounter = remoteWindow.fromCounter,
                                toCounter = reqTo,
                                mode = "integrity",
                                exactAuthor = true,
                                expectedCount = remoteCount,
                                expectedChecksum = remoteChecksum,
                                expectedMaxCounter = (remoteFilledTo > 0) and remoteFilledTo or nil,
                                expectedFromCounter = remoteWindow.fromCounter,
                                expectedToCounter = remoteWindow.toCounter,
                                expectedWindows = { evidence },
                            }
                        end
                    end
                end
            end
        end
    end

    return mismatches
end

-- Function Export a full snapshot for a profile, suitable for PROFILE_SNAPSHOT message.
-- @param profileId string Stable profile id
-- @return table|nil Snapshot payload or nil if profile not found
function Sync:BuildProfileSnapshot(profileId)
	local profile = self:FindLocalProfileById(profileId)
	if not profile then return nil end
	if not profile.ExportSnapshot then return nil end
	if profile._EnsureRaidCheckConfig then
		profile:_EnsureRaidCheckConfig()
	end
	
	local snapshot = profile:ExportSnapshot()
    
    -- Debug: log snapshot summary
    if SF.Debug then
        local numMembers = (snapshot and snapshot.members and #snapshot.members) or 0
        local numLogs = (snapshot and snapshot.lootLogs and #snapshot.lootLogs) or 0
        local numAdmins = (snapshot and snapshot.adminUsers and #snapshot.adminUsers) or 0
        local pointName = (snapshot and snapshot.pointName) or "Points"
        SF.Debug:Info("SYNC_PROFILE", "Built snapshot for %s: %d members, %d logs, %d admins, pointName=%s",
            tostring(profileId), numMembers, numLogs, numAdmins, pointName)
    end

    return {
        sessionId   = self.state.sessionId,
        profileId   = profileId,
        snapshot    = snapshot,
        sentAt      = self:_Now(),
        sender      = self:_SelfId(),
        addonVersion= self:_GetAddonVersion(),
    }
end

-- Advertise accepted RC generation and the small config blob on session
-- descriptors. Peers apply this after accepting the session; they must not
-- need a full PROFILE_SNAPSHOT solely to catch up RC settings.
function Sync:_AttachRCConfigGeneration(payload, profileId)
    if type(payload) ~= "table" then
        return payload
    end
    local profile = nil
    if type(profileId) == "string" and profileId ~= "" and self.FindLocalProfileById then
        profile = self:FindLocalProfileById(profileId)
    end
    local seq = tonumber(profile and profile._rcConfigSeq)
    if seq == nil then
        seq = tonumber(self.state and self.state.rcConfigSeq)
    end
    -- Match ExportSnapshot: unset accepted epoch is 0, not live coordEpoch.
    -- Falling back to coordEpoch made log-complete peers request snapshots in a
    -- loop in sessions that had never published RC_CONFIG_SET.
    local epoch = tonumber(profile and profile._rcConfigEpoch) or 0
    payload.rcConfigSeq = math.floor(tonumber(seq) or 0)
    payload.rcConfigEpoch = math.floor(epoch)
    if profile and profile.GetRCLootCouncilIntegrationConfig then
        payload.rcLootCouncilIntegration = profile:GetRCLootCouncilIntegrationConfig()
    end
    return payload
end

function Sync:_RememberAdvertisedRCConfigGeneration(payload)
    if type(payload) ~= "table" then
        return
    end
    if type(payload.rcConfigSeq) == "number" then
        self.state.advertisedRcConfigSeq = math.floor(payload.rcConfigSeq)
    end
    if type(payload.rcConfigEpoch) == "number" then
        self.state.advertisedRcConfigEpoch = math.floor(payload.rcConfigEpoch)
    end
end

function Sync:_NeedsRCConfigCatchUp(profile)
    if not profile then
        return false
    end
    local advSeq = tonumber(self.state and self.state.advertisedRcConfigSeq)
    local advEpoch = tonumber(self.state and self.state.advertisedRcConfigEpoch)
    if advSeq == nil and advEpoch == nil then
        return false
    end
    local LootProfile = SF.LootProfile
    if not (LootProfile and LootProfile.IsNewerRCConfigGeneration) then
        return false
    end
    local localSeq = tonumber(profile._rcConfigSeq) or 0
    local localEpoch = tonumber(profile._rcConfigEpoch) or 0
    return LootProfile.IsNewerRCConfigGeneration(advEpoch or 0, advSeq or 0, localEpoch, localSeq)
end

-- Apply coordinator-advertised RC config from SES_START / heartbeat /
-- reannounce after the receiver has accepted the session. Generation is
-- compared with (coordEpoch, seq); missing blobs are not inferred.
function Sync:_ApplyAdvertisedRCConfig(payload)
    if type(payload) ~= "table" then
        return false
    end
    if not (self.state and self.state.active) then
        return false
    end
    local profileId = payload.profileId or self.state.profileId
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(profileId) or nil
    if not profile or not profile.ApplyRCLootCouncilIntegrationConfig then
        return false
    end
    if type(payload.rcLootCouncilIntegration) ~= "table" then
        return false
    end
    local incomingSeq = math.floor(tonumber(payload.rcConfigSeq) or 0)
    local incomingEpoch = math.floor(tonumber(payload.rcConfigEpoch) or 0)
    local localSeq = tonumber(profile._rcConfigSeq) or 0
    local localEpoch = tonumber(profile._rcConfigEpoch) or 0
    local LootProfile = SF.LootProfile
    local isNewer = incomingSeq > localSeq
    if LootProfile and LootProfile.IsNewerRCConfigGeneration then
        isNewer = LootProfile.IsNewerRCConfigGeneration(incomingEpoch, incomingSeq, localEpoch, localSeq)
    end
    if not isNewer then
        return false
    end
    local applied = profile:ApplyRCLootCouncilIntegrationConfig(payload.rcLootCouncilIntegration, {
        skipPermission = true,
        skipSync = true,
    })
    if not applied then
        return false
    end
    profile._rcConfigSeq = incomingSeq
    profile._rcConfigEpoch = incomingEpoch
    profile._rcConfigDirty = nil
    self.state.rcConfigSeq = incomingSeq
    self.state._rcConfigCatchUpInFlight = nil
    return true
end

-- START-mode admin convergence: adopt a strictly newer previously accepted
-- generation from participating admins before SES_START. Skipped when the
-- starter deliberately edited RC settings while no session was active.
function Sync:_AdoptNewerAdminAcceptedRCConfig(profile)
    if not profile or not profile.ApplyRCLootCouncilIntegrationConfig then
        return false
    end
    if profile._rcConfigDirty == true then
        return false
    end
    local LootProfile = SF.LootProfile
    if not (LootProfile and LootProfile.IsNewerRCConfigGeneration) then
        return false
    end
    local bestEpoch = tonumber(profile._rcConfigEpoch) or 0
    local bestSeq = tonumber(profile._rcConfigSeq) or 0
    local bestCfg = nil
    local names = {}
    for name in pairs(self.state.adminStatuses or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    for i = 1, #names do
        local st = self.state.adminStatuses[names[i]]
        if type(st) == "table" and type(st.rcLootCouncilIntegration) == "table" then
            local epoch = math.floor(tonumber(st.rcConfigEpoch) or 0)
            local seq = math.floor(tonumber(st.rcConfigSeq) or 0)
            if LootProfile.IsNewerRCConfigGeneration(epoch, seq, bestEpoch, bestSeq) then
                bestEpoch = epoch
                bestSeq = seq
                bestCfg = st.rcLootCouncilIntegration
            end
        end
    end
    if not bestCfg then
        return false
    end
    local applied = profile:ApplyRCLootCouncilIntegrationConfig(bestCfg, {
        skipPermission = true,
        skipSync = true,
    })
    if not applied then
        return false
    end
    profile._rcConfigSeq = bestSeq
    profile._rcConfigEpoch = bestEpoch
    profile._rcConfigDirty = nil
    self.state.rcConfigSeq = bestSeq
    return true
end

-- Intentional out-of-session edits mint a new generation under this session's
-- coordEpoch. Do not RAID RC_CONFIG_SET before SES_START: ordinary peers have
-- not accepted the session yet, so SET cannot apply through HandleRCConfigSet.
function Sync:_MintDirtySessionRCConfig(profile)
    if not (self.state and self.state.active and self.state.isCoordinator) then
        return false
    end
    if not profile or profile._rcConfigDirty ~= true then
        return false
    end
    local nextSeq = (tonumber(self.state.rcConfigSeq) or tonumber(profile._rcConfigSeq) or 0) + 1
    self.state.rcConfigSeq = nextSeq
    profile._rcConfigSeq = nextSeq
    profile._rcConfigEpoch = tonumber(self.state.coordEpoch) or 0
    profile._rcConfigDirty = nil
    return true
end

function Sync:RequestRCConfigCatchUp(reason)
    if not (self.state and self.state.active) then
        return false
    end
    if self.state.isCoordinator then
        return false
    end
    if type(self.state.sessionId) ~= "string" or self.state.sessionId == "" then
        return false
    end
    if type(self.state.coordinator) ~= "string" or self.state.coordinator == "" then
        return false
    end
    if self.state._rcConfigCatchUpInFlight == self.state.sessionId then
        return false
    end
    if not (SF.LootHelperComm and SF.LootHelperComm.Send) then
        return false
    end
    local sent = SF.LootHelperComm:Send("CONTROL", self.MSG.RC_CONFIG_REQ, {
        sessionId = self.state.sessionId,
        profileId = self.state.profileId,
        catchUp = true,
    }, "WHISPER", self.state.coordinator, "NORMAL")
    if sent == false then
        return false
    end
    self.state._rcConfigCatchUpInFlight = self.state.sessionId
    if SF.Debug then
        SF.Debug:Verbose("SYNC", "RC config catch-up requested (reason=%s)", tostring(reason or "rc-config-catchup"))
    end
    return true
end

function Sync:_CatchUpRCConfigIfNeeded(profile, reason)
    if not self:_NeedsRCConfigCatchUp(profile) then
        return false
    end
    self:RequestRCConfigCatchUp(reason or "rc-config-catchup")
    return true
end

-- Push the current profile snapshot to session peers.
-- Full snapshots are coordinator/helper trust-boundary traffic (NEED_PROFILE).
-- Live RC integration edits use PublishRCIntegrationConfig instead.
function Sync:PushActiveProfileSnapshot(profileId, reason)
    if not self.state or not self.state.active then
        return false, "no session"
    end
    if type(self.state.sessionId) ~= "string" or self.state.sessionId == "" then
        return false, "no session"
    end
    profileId = profileId or self.state.profileId
    if type(profileId) ~= "string" or profileId == "" then
        return false, "missing profileId"
    end
    if self.state.profileId and self.state.profileId ~= profileId then
        return false, "wrong profile for session"
    end
    local me = self._SelfId and self:_SelfId() or nil
    if not me or not self:IsSenderAuthorized(profileId, me) then
        return false, "not authorized"
    end
    local dist = "RAID"
    if self._EnforceGroupedSessionActive then
        dist = self:_EnforceGroupedSessionActive("PushActiveProfileSnapshot")
        if not dist then
            return false, "not in group"
        end
    end
    if not self.BuildProfileSnapshot then
        return false, "unavailable"
    end
    local payload = self:BuildProfileSnapshot(profileId)
    if not payload then
        return false, "no snapshot"
    end
    payload.reason = reason
    if SF.LootHelperComm and SF.LootHelperComm.Send then
        local opts
        if SF.SyncProtocol and SF.SyncProtocol.ENC_B64CBOR then
            opts = { enc = SF.SyncProtocol.ENC_B64CBOR }
        end
        SF.LootHelperComm:Send("BULK", self.MSG.PROFILE_SNAPSHOT, payload, dist, nil, "BULK", opts)
    end
    return true, payload
end

-- Function Publish RC integration configuration for the session profile.
-- Coordinator applies a monotonic session seq and RAID-broadcasts RC_CONFIG_SET
-- from accepted RC config, stamped with coordEpoch.
-- Non-coordinators WHISPER RC_CONFIG_REQ from the pending proposal when present.
-- Never sends a full PROFILE_SNAPSHOT.
-- @param profileId string|nil Session profile id
-- @return boolean success
-- @return table|string payloadOrError
function Sync:PublishRCIntegrationConfig(profileId, opts)
    opts = type(opts) == "table" and opts or {}
    if not self.state or not self.state.active then
        return false, "no session"
    end
    if type(self.state.sessionId) ~= "string" or self.state.sessionId == "" then
        return false, "no session"
    end
    profileId = profileId or self.state.profileId
    if type(profileId) ~= "string" or profileId == "" then
        return false, "missing profileId"
    end
    if self.state.profileId and self.state.profileId ~= profileId then
        return false, "wrong profile for session"
    end
    local me = self._SelfId and self:_SelfId() or nil
    if not me or not self.IsSenderAuthorized or not self:IsSenderAuthorized(profileId, me) then
        return false, "not authorized"
    end
    local dist = "RAID"
    if self._EnforceGroupedSessionActive then
        dist = self:_EnforceGroupedSessionActive("PublishRCIntegrationConfig")
        if not dist then
            return false, "not in group"
        end
    end
    local profile = self.FindLocalProfileById and self:FindLocalProfileById(profileId) or nil
    if not profile or not profile.GetRCLootCouncilIntegrationConfig then
        return false, "no profile"
    end
    local config
    if self.state.isCoordinator then
        config = profile:GetRCLootCouncilIntegrationConfig()
    elseif profile.GetProposedRCLootCouncilIntegrationConfig then
        config = profile:GetProposedRCLootCouncilIntegrationConfig()
        if type(config) ~= "table" then
            config = profile:GetRCLootCouncilIntegrationConfig()
        end
    else
        config = profile:GetRCLootCouncilIntegrationConfig()
    end
    if type(config) ~= "table" then
        return false, "no config"
    end
    if not (SF.LootHelperComm and SF.LootHelperComm.Send) then
        return false, "comm not available"
    end
    if self.state.isCoordinator then
        local seq
        local epoch
        if opts.replay == true then
            seq = math.floor(tonumber(self.state.rcConfigSeq) or tonumber(profile._rcConfigSeq) or 0)
            epoch = tonumber(self.state.coordEpoch) or 0
        else
            seq = (tonumber(self.state.rcConfigSeq) or 0) + 1
            self.state.rcConfigSeq = seq
            profile._rcConfigSeq = seq
            profile._rcConfigEpoch = tonumber(self.state.coordEpoch) or 0
            profile._pendingRCLootCouncilIntegration = nil
            profile._rcConfigDirty = nil
            epoch = tonumber(self.state.coordEpoch) or 0
        end
        local payload = {
            sessionId = self.state.sessionId,
            profileId = profileId,
            coordinator = self.state.coordinator,
            coordEpoch = epoch,
            seq = seq,
            rcLootCouncilIntegration = config,
        }
        local sent = SF.LootHelperComm:Send(
            "CONTROL",
            self.MSG.RC_CONFIG_SET,
            payload,
            dist,
            nil,
            "NORMAL"
        )
        if sent == false then
            return false, "send failed"
        end
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "RC_CONFIG_SET seq=%s epoch=%s profile=%s replay=%s", tostring(seq), tostring(payload.coordEpoch), tostring(profileId), tostring(opts.replay == true))
        end
        return true, payload
    end
    if type(self.state.coordinator) ~= "string" or self.state.coordinator == "" then
        return false, "no coordinator"
    end
    local req = {
        sessionId = self.state.sessionId,
        profileId = profileId,
        rcLootCouncilIntegration = config,
    }
    local sent = SF.LootHelperComm:Send(
        "CONTROL",
        self.MSG.RC_CONFIG_REQ,
        req,
        "WHISPER",
        self.state.coordinator,
        "NORMAL"
    )
    if sent == false then
        return false, "send failed"
    end
    if SF.Debug then
        SF.Debug:Verbose("SYNC", "RC_CONFIG_REQ to %s profile=%s", tostring(self.state.coordinator), tostring(profileId))
    end
    return true, req
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

-- Session authorMax is the raw advertised frontier: exact `_author` spelling
-- -> actual highest retained counter for that spelling. SameAuthor aliases
-- stay independent keys. Timeout, late ADMIN_STATUS, heartbeats, and
-- coordinator changes may retain already-advertised spellings forever, but
-- must not copy a higher counter onto a different historical spelling.
-- Logical SameAuthor maxima are derived with CanonicalAuthorKey /
-- CollapseAuthorCounterMap / LogicalContigForAuthor when needed.
function Sync:_MergeAuthorMaxFrontier(incoming)
    self.state = self.state or {}
    self.state.authorMax = self.state.authorMax or {}
    if type(incoming) ~= "table" then
        return self.state.authorMax
    end
    for author, maxCounter in pairs(incoming) do
        maxCounter = tonumber(maxCounter)
        if type(author) == "string" and author ~= "" and maxCounter then
            local prev = tonumber(self.state.authorMax[author]) or 0
            if maxCounter > prev then
                self.state.authorMax[author] = maxCounter
            end
        end
    end
    return self.state.authorMax
end

function Sync:_RefreshAdvertisedAuthorMax(profileId)
    return self:_MergeAuthorMaxFrontier(self:ComputeAuthorMax(profileId))
end

-- Drop live-relationship and identity-admin bookkeeping that belongs to a
-- session that is ending, changing, or being restored from persistence.
-- Same-session coordinator failover must not call this.
function Sync:_ClearIdentitySessionBookkeeping(reason)
    self._pendingLiveRelationship = {}
    self._liveRelationshipInFlight = nil
    self._flushingLiveRelationship = nil
    self._identityAdminReconcileNeeded = {}
    self._identityAdminReconcilePending = {}
    self._consideringIdentitySideEffects = nil
    if type(self.state) == "table" then
        self.state.containedExactWindows = {}
    end
    if SF.Debug then
        SF.Debug:Verbose("SYNC", "Cleared identity session bookkeeping (reason=%s)", tostring(reason or "unknown"))
    end
end

local function AuthorsMatch(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    local Identity = SF.LootHelperIdentity
    if Identity and Identity.SameAuthor then
        return Identity.SameAuthor(a, b)
    end
    if Identity and Identity.SamePlayer then
        return Identity.SamePlayer(a, b)
    end
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    return a == b
end

function Sync:_LogAuthorMatches(a, b)
    return AuthorsMatch(a, b)
end

local function CollapseAuthorCounterMap(map)
    local byKey = {}
    local Identity = SF.LootHelperIdentity
    for author, counter in pairs(map or {}) do
        counter = tonumber(counter)
        if type(author) == "string" and author ~= "" and counter then
            local key = (Identity and Identity.CanonicalAuthorKey and Identity.CanonicalAuthorKey(author)) or string.lower(author)
            local cur = byKey[key]
            if not cur or counter > cur.counter then
                byKey[key] = { author = author, counter = counter }
            elseif counter == cur.counter and tostring(author) < tostring(cur.author) then
                cur.author = author
            end
        end
    end
    return byKey
end

-- Highest contiguous/advertised counter for a logical author, including
-- SameAuthor aliases and CanonicalAuthorKey entries in contig maps.
-- Exact raw spelling is not required; missing local spellings must not
-- look like contig 0 when another alias already has history.
local function LogicalContigForAuthor(localContig, author)
    if type(localContig) ~= "table" or type(author) ~= "string" or author == "" then
        return 0
    end
    local best = tonumber(localContig[author]) or 0
    local Identity = SF.LootHelperIdentity
    local key = Identity and Identity.CanonicalAuthorKey and Identity.CanonicalAuthorKey(author)
    if type(key) == "string" then
        local byKey = tonumber(localContig[key]) or 0
        if byKey > best then
            best = byKey
        end
    end
    for localAuthor, localVal in pairs(localContig) do
        if type(localAuthor) == "string" then
            local n = tonumber(localVal) or 0
            if n > best and AuthorsMatch(localAuthor, author) then
                best = n
            end
        end
    end
    return best
end

-- Exact raw-author max only. Canonical-key entries in contig maps must not
-- count as possessing that historical spelling.
local function ExactAuthorCounter(map, author)
    if type(map) ~= "table" or type(author) ~= "string" then
        return 0
    end
    return tonumber(map[author]) or 0
end

function Sync:_LogicalContigForAuthor(localContig, author)
    return LogicalContigForAuthor(localContig, author)
end

-- Exact raw-author repair is a distinct request intent from logical
-- SameAuthor catch-up. Integrity windows are also per exact `_author`.
function Sync:_IsExactAuthorRepair(meta)
    return type(meta) == "table" and (meta.exactAuthor == true or meta.integrityRepair == true)
end

function Sync:_AuthorMatchesRepairRequest(logAuthor, requestedAuthor, exactAuthor)
    if type(logAuthor) ~= "string" or logAuthor == "" then
        return false
    end
    if type(requestedAuthor) ~= "string" or requestedAuthor == "" then
        return false
    end
    if exactAuthor == true then
        return logAuthor == requestedAuthor
    end
    return AuthorsMatch(logAuthor, requestedAuthor)
end

local function ExactRangeFingerprintRollup(rows)
    local checksum = 5381
    table.sort(rows)
    for _, row in ipairs(rows) do
        for i = 1, #row do
            checksum = (checksum * 33 + row:byte(i)) % 2147483647
        end
    end
    return checksum
end

-- Exact `_author` rows inside [fromCounter, toCounter] only. A later retained
-- row (for example :30) must not complete an earlier window (1..25).
function Sync:_ScanExactAuthorRange(profileId, author, fromCounter, toCounter)
    local count, maxInRange = 0, 0
    local rows = {}
    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        return 0, 0, ExactRangeFingerprintRollup(rows)
    end

    for _, log in ipairs(self:_GetProfileLootLogs(profile)) do
        local a = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
        if a == author then
            local c = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
            c = tonumber(c)
            if c then
                c = math.floor(c)
                if c >= fromCounter and c <= toCounter then
                    count = count + 1
                    if c > maxInRange then
                        maxInRange = c
                    end
                    local id = (log.GetID and log:GetID()) or log._id or ""
                    local fingerprint = (log.GetFingerprint and log:GetFingerprint()) or log._fingerprint or 0
                    rows[#rows + 1] = ("%s=%s"):format(id, tostring(fingerprint))
                end
            end
        end
    end

    return count, maxInRange, ExactRangeFingerprintRollup(rows)
end

function Sync:_RangeHasWindowEvidence(range)
    if type(range) ~= "table" then
        return false
    end
    if type(range.expectedWindows) == "table" and #range.expectedWindows > 0 then
        return true
    end
    if range.expectedCount ~= nil or range.expectedChecksum ~= nil then
        return true
    end
    return false
end

function Sync:_MakeExactRowWindowEvidence(author, counter, logId, fingerprint)
    counter = tonumber(counter)
    if type(author) ~= "string" or author == "" or not counter then
        return nil
    end
    counter = math.max(1, math.floor(counter))
    local row = ("%s=%s"):format(tostring(logId or ""), tostring(fingerprint or 0))
    local checksum = ExactRangeFingerprintRollup({ row })
    return {
        fromCounter = counter,
        toCounter = counter,
        count = 1,
        maxCounter = counter,
        checksum = checksum,
    }
end

function Sync:_StampExactRowWindowEvidence(range, logId, fingerprint)
    if type(range) ~= "table" or self:_RangeHasWindowEvidence(range) then
        return range
    end
    local window = self:_MakeExactRowWindowEvidence(range.author, range.fromCounter, logId, fingerprint)
    if not window then
        return range
    end
    range.expectedWindows = { window }
    range.expectedCount = window.count
    range.expectedChecksum = window.checksum
    range.expectedMaxCounter = window.maxCounter
    range.expectedFromCounter = window.fromCounter
    range.expectedToCounter = window.toCounter
    return range
end

function Sync:_UpgradeOutstandingLogRangeEvidence(profileId, author, fromCounter, toCounter, src)
    if type(src) ~= "table" or not self:_RangeHasWindowEvidence(src) then
        return false
    end
    if type(profileId) ~= "string" or profileId == "" then
        return false
    end
    if type(author) ~= "string" or author == "" then
        return false
    end
    fromCounter = tonumber(fromCounter)
    toCounter = tonumber(toCounter)
    if not fromCounter or not toCounter then
        return false
    end

    local upgraded = false
    local function consider(dest)
        if type(dest) ~= "table" then
            return
        end
        if dest.profileId ~= profileId or dest.author ~= author then
            return
        end
        local f = tonumber(dest.fromCounter)
        local t = tonumber(dest.toCounter)
        if not f or not t then
            return
        end
        if f <= fromCounter and t >= toCounter and not self:_RangeHasWindowEvidence(dest) then
            self:_CopyExpectedWindowEvidence(src, dest)
            upgraded = true
        end
    end

    if type(self.state) == "table" and type(self.state.requests) == "table" then
        for _, req in pairs(self.state.requests) do
            if type(req) == "table"
                and (req.kind == "NEED_LOGS" or req.kind == "LOG_REQ" or req.kind == "ADMIN_LOG_REQ")
            then
                consider(req.meta)
            end
        end
    end
    local queue = self.state and self.state.repairQueue
    if type(queue) == "table" and type(queue.items) == "table" then
        for _, entry in pairs(queue.items) do
            consider(entry)
        end
    end
    return upgraded
end

function Sync:_BindSessionWindowEvidence(ranges)
    if type(ranges) ~= "table" then
        return ranges
    end
    if self.state and self.state.isCoordinator then
        return ranges
    end
    return self:_AttachExactWindowEvidence(ranges, (self.state and self.state.authorWindowSummary) or {})
end

function Sync:_IntegrityRangesFromAdvertisement(payload, sender)
    local advertisedRanges = {}
    if type(payload) ~= "table" then
        return advertisedRanges
    end
    for _, range in ipairs(payload.mutationRanges or {}) do
        if type(range) == "table"
            and type(range.author) == "string"
            and type(range.fromCounter) == "number"
            and type(range.toCounter) == "number"
        then
            local advertised = {
                author = range.author,
                fromCounter = range.fromCounter,
                toCounter = range.toCounter,
                mode = "integrity",
                exactAuthor = true,
                preferredTarget = sender,
            }
            self:_CopyExpectedWindowEvidence(range, advertised)
            advertisedRanges[#advertisedRanges + 1] = advertised
        end
    end
    local advertiserSummary = payload.authorWindowSummary or payload.localWindowSummary
    if type(advertiserSummary) == "table" then
        self:_AttachExactWindowEvidence(advertisedRanges, advertiserSummary)
    end
    self:_BindSessionWindowEvidence(advertisedRanges)
    return advertisedRanges
end

function Sync:_CollectOverlappingWindowEvidence(remoteSummary, author, fromCounter, toCounter)
    local out = {}
    if type(remoteSummary) ~= "table" or type(author) ~= "string" or author == "" then
        return out
    end
    local windows = remoteSummary[author]
    if type(windows) ~= "table" then
        return out
    end
    fromCounter = tonumber(fromCounter) or 0
    toCounter = tonumber(toCounter) or 0
    for _, window in ipairs(windows) do
        if type(window) == "table" then
            local windowFrom = tonumber(window.fromCounter)
            local windowTo = tonumber(window.toCounter)
            if windowFrom and windowTo and windowFrom <= toCounter and windowTo >= fromCounter then
                out[#out + 1] = {
                    fromCounter = windowFrom,
                    toCounter = windowTo,
                    count = tonumber(window.count) or 0,
                    maxCounter = tonumber(window.maxCounter) or 0,
                    checksum = tonumber(window.checksum),
                }
            end
        end
    end
    table.sort(out, function(a, b)
        return (tonumber(a.fromCounter) or 0) < (tonumber(b.fromCounter) or 0)
    end)
    return out
end

-- Stamp advertiser raw-window proof onto exact completeness/integrity ranges.
-- authorMax only encodes the highest retained counter; set completeness lives
-- in count / maxCounter / checksum of the overlapping raw windows.
function Sync:_AttachExactWindowEvidence(ranges, remoteSummary)
    if type(ranges) ~= "table" or type(remoteSummary) ~= "table" then
        return ranges
    end
    for _, range in ipairs(ranges) do
        if type(range) == "table"
            and (range.exactAuthor == true or range.mode == "integrity" or range.integrityRepair == true)
            and (type(range.expectedWindows) ~= "table" or #range.expectedWindows == 0)
        then
            local windows = self:_CollectOverlappingWindowEvidence(
                remoteSummary,
                range.author,
                range.fromCounter,
                range.toCounter
            )
            if #windows > 0 then
                range.expectedWindows = windows
                local first = windows[1]
                range.expectedCount = first.count
                range.expectedChecksum = first.checksum
                range.expectedMaxCounter = first.maxCounter
                range.expectedFromCounter = first.fromCounter
                range.expectedToCounter = first.toCounter
            end
        end
    end
    return ranges
end

function Sync:_NormalizeExpectedWindows(opts, fromCounter, toCounter)
    if type(opts) == "table" and type(opts.expectedWindows) == "table" and #opts.expectedWindows > 0 then
        return opts.expectedWindows
    end
    if type(opts) ~= "table" then
        return nil
    end
    if opts.expectedCount == nil and opts.expectedChecksum == nil and opts.expectedMaxCounter == nil then
        return nil
    end
    return {
        {
            fromCounter = tonumber(opts.expectedFromCounter) or fromCounter,
            toCounter = tonumber(opts.expectedToCounter) or toCounter,
            count = tonumber(opts.expectedCount),
            maxCounter = tonumber(opts.expectedMaxCounter),
            checksum = tonumber(opts.expectedChecksum),
        },
    }
end

-- Advertised maxCounter is the filled frontier of that window, not a claim
-- about later counters in the same fixed bucket. Extras after filledTo must
-- not satisfy or invalidate earlier proof.
function Sync:_AdvertisedWindowFilledTo(window)
    local fromCounter = tonumber(window and window.fromCounter) or 0
    local toCounter = tonumber(window and window.toCounter) or 0
    local maxCounter = tonumber(window and window.maxCounter)
    if maxCounter and maxCounter > 0 then
        if toCounter > 0 and maxCounter > toCounter then
            return toCounter
        end
        if fromCounter > 0 and maxCounter < fromCounter then
            return fromCounter - 1
        end
        return maxCounter
    end
    return toCounter
end

function Sync:_AdvertisedWindowProofKey(profileId, author, window)
    return table.concat({
        tostring(profileId or ""),
        tostring(author or ""),
        tostring(tonumber(window and window.fromCounter) or 0),
        tostring(tonumber(window and window.toCounter) or 0),
        tostring(tonumber(window and window.count) or 0),
        tostring(tonumber(window and window.maxCounter) or 0),
        tostring(tonumber(window and window.checksum) or 0),
    }, "|")
end

function Sync:_MarkAdvertisedWindowContained(profileId, author, window, rows)
    if type(window) ~= "table" or type(rows) ~= "table" or #rows == 0 then
        return
    end
    local copied = {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) ~= "table" or type(row.id) ~= "string" or row.id == "" then
            return
        end
        local fingerprint = tonumber(row.fingerprint)
        if not fingerprint then
            return
        end
        copied[i] = {
            id = row.id,
            fingerprint = fingerprint,
        }
    end
    self.state = self.state or {}
    if type(self.state.containedExactWindows) ~= "table" then
        self.state.containedExactWindows = {}
    end
    self.state.containedExactWindows[self:_AdvertisedWindowProofKey(profileId, author, window)] = {
        rows = copied,
    }
end

-- Cached AUTH_LOGS containment is only valid while those exact rows still
-- exist locally with the same IDs and fingerprints. A later trusted
-- replacement of the same ID must not keep a prior advertiser's proof.
function Sync:_HasContainedExactWindowProof(profileId, author, window)
    local contained = self.state and self.state.containedExactWindows
    if type(contained) ~= "table" or type(window) ~= "table" then
        return false
    end
    local key = self:_AdvertisedWindowProofKey(profileId, author, window)
    local entry = contained[key]
    if entry == true then
        contained[key] = nil
        return false
    end
    if type(entry) ~= "table" or type(entry.rows) ~= "table" or #entry.rows == 0 then
        return false
    end
    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        contained[key] = nil
        return false
    end
    for i = 1, #entry.rows do
        local row = entry.rows[i]
        if type(row) ~= "table" or type(row.id) ~= "string" or row.id == "" then
            contained[key] = nil
            return false
        end
        local expectedFp = tonumber(row.fingerprint)
        local log = profile.GetLogById and profile:GetLogById(row.id)
        if not log or not expectedFp then
            contained[key] = nil
            return false
        end
        local localFp = tonumber((log.GetFingerprint and log:GetFingerprint()) or log._fingerprint)
        if not localFp or localFp ~= expectedFp then
            contained[key] = nil
            return false
        end
    end
    return true
end

-- Compact proof: local retained rows in [from, filledTo] match advertised
-- count and/or checksum. That is containment of the advertiser's filled set,
-- not equality of the whole fixed bucket. Interleaved extras inside the
-- filled frontier still require AUTH_LOGS row proof.
function Sync:_LocalFrontierMatchesAdvertisedWindow(profileId, author, window)
    if type(window) ~= "table" then
        return false
    end
    local fromCounter = tonumber(window.fromCounter)
    local toCounter = tonumber(window.toCounter)
    if not fromCounter or not toCounter or fromCounter <= 0 or toCounter < fromCounter then
        return false
    end
    local expectedCount = tonumber(window.count)
    local expectedChecksum = tonumber(window.checksum)
    local expectedMax = tonumber(window.maxCounter)
    if expectedCount == nil and expectedChecksum == nil then
        return false
    end
    local filledTo = self:_AdvertisedWindowFilledTo(window)
    if filledTo < fromCounter then
        return expectedCount == 0
    end
    local count, maxInRange, checksum = self:_ScanExactAuthorRange(profileId, author, fromCounter, filledTo)
    if expectedCount ~= nil and count ~= expectedCount then
        return false
    end
    if expectedMax ~= nil and expectedMax > 0 and maxInRange ~= expectedMax then
        return false
    end
    if expectedChecksum ~= nil and checksum ~= expectedChecksum then
        return false
    end
    return true
end

function Sync:_IsAdvertisedExactWindowContained(profileId, author, window)
    if self:_HasContainedExactWindowProof(profileId, author, window) then
        return true
    end
    return self:_LocalFrontierMatchesAdvertisedWindow(profileId, author, window)
end

function Sync:_AuthLogsProveAdvertisedWindow(profileId, author, window, payloadLogs)
    if type(window) ~= "table" or type(author) ~= "string" or author == "" then
        return nil
    end
    local advertisedCount = tonumber(window.count)
    local advertisedChecksum = tonumber(window.checksum)
    if advertisedCount == nil or advertisedChecksum == nil then
        return nil
    end
    local fromCounter = tonumber(window.fromCounter) or 0
    local filledTo = self:_AdvertisedWindowFilledTo(window)
    local matched = {}
    local evidence = {}
    for _, log in ipairs(payloadLogs or {}) do
        if type(log) == "table" then
            local logAuthor = log._author or log.author
            if logAuthor == author then
                local counter = tonumber(log._counter or log.counter)
                if counter and counter >= fromCounter and counter <= filledTo then
                    local id = log._id or log.id or ""
                    local fingerprint = tonumber(log._fingerprint or log.fingerprint)
                    if type(id) ~= "string" or id == "" or not fingerprint then
                        return nil
                    end
                    matched[#matched + 1] = ("%s=%s"):format(id, tostring(fingerprint))
                    evidence[#evidence + 1] = {
                        id = id,
                        fingerprint = fingerprint,
                    }
                end
            end
        end
    end
    if ExactRangeFingerprintRollup(matched) ~= advertisedChecksum or #matched ~= advertisedCount then
        return nil
    end
    local profile = self:FindLocalProfileById(profileId)
    if not profile then
        return nil
    end
    local byId = {}
    for _, log in ipairs(self:_GetProfileLootLogs(profile)) do
        local a = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
        if a == author then
            local c = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
            c = tonumber(c)
            if c and c >= fromCounter and c <= filledTo then
                local id = (log.GetID and log:GetID()) or log._id
                if type(id) == "string" and id ~= "" then
                    byId[id] = log
                end
            end
        end
    end
    for i = 1, #evidence do
        local row = evidence[i]
        local localLog = byId[row.id]
        if not localLog then
            return nil
        end
        local localFp = tonumber((localLog.GetFingerprint and localLog:GetFingerprint()) or localLog._fingerprint)
        if not localFp or localFp ~= row.fingerprint then
            return nil
        end
    end
    return evidence
end

function Sync:_ProveAdvertisedWindowsFromAuthLogs(profileId, request, payloadLogs)
    if type(request) ~= "table" or type(profileId) ~= "string" or profileId == "" then
        return false
    end
    if not self:_IsExactAuthorRepair(request) then
        return false
    end
    local windows = request.expectedWindows
    if type(windows) ~= "table" or #windows == 0 then
        windows = self:_NormalizeExpectedWindows(request, request.fromCounter, request.toCounter)
    end
    if type(windows) ~= "table" then
        return false
    end
    local marked = false
    for i = 1, #windows do
        local window = windows[i]
        local evidence = self:_AuthLogsProveAdvertisedWindow(profileId, request.author, window, payloadLogs)
        if evidence then
            self:_MarkAdvertisedWindowContained(profileId, request.author, window, evidence)
            marked = true
        end
    end
    return marked
end

-- Advertised history is satisfied when local retained immutable rows contain
-- the advertiser's proven filled set. A later raw max is not containment.
-- Sparse holes are allowed because the checksum is over retained rows.
function Sync:_ExactAuthorEvidenceSatisfied(profileId, author, expectedWindows)
    if type(expectedWindows) ~= "table" or #expectedWindows == 0 then
        return false
    end
    for _, expected in ipairs(expectedWindows) do
        if not self:_IsAdvertisedExactWindowContained(profileId, author, expected) then
            return false
        end
    end
    return true
end

-- Exact-author satisfaction requires advertised raw-window proof. Global
-- retained max, a non-empty AUTH_LOGS payload, and SameAuthor contig are not
-- sufficient. Completeness and integrity both ask whether local exact rows
-- contain each advertiser's filled set (count / maxCounter / checksum, or a
-- proof-bearing AUTH_LOGS row set). Extra valid local rows are allowed.
function Sync:_ExactAuthorRangeSatisfied(profileId, author, fromCounter, toCounter, opts)
    if type(profileId) ~= "string" or profileId == "" then return false end
    if type(author) ~= "string" or author == "" then return false end

    fromCounter = tonumber(fromCounter)
    toCounter = tonumber(toCounter)
    if not fromCounter or not toCounter then return false end
    fromCounter = math.max(1, math.floor(fromCounter))
    toCounter = math.max(fromCounter, math.floor(toCounter))

    opts = type(opts) == "table" and opts or {}
    local expectedWindows = self:_NormalizeExpectedWindows(opts, fromCounter, toCounter)
    if not expectedWindows then
        -- Members may late-bind coordinator-advertised windows that were
        -- present in session state but not copied onto the request. The
        -- coordinator must not treat its own local summary as advertiser
        -- proof for a peer mutation or fingerprint repair.
        if self.state and self.state.isCoordinator ~= true then
            expectedWindows = self:_CollectOverlappingWindowEvidence(
                self.state.authorWindowSummary,
                author,
                fromCounter,
                toCounter
            )
        end
        if type(expectedWindows) ~= "table" or #expectedWindows == 0 then
            return false
        end
    end
    return self:_ExactAuthorEvidenceSatisfied(profileId, author, expectedWindows)
end

-- Function Compute missing log ranges given local authorMax and remote authorMax (or detect gaps).
-- @param localAuthorMax table Map [author] = maxCounterSeen
-- @param remoteAuthorMax table Map [author] = maxCounterSeen
-- @return table missingRequests Array describing needed author/range requests.
-- Logical SameAuthor collapse is for future counter catch-up: owner-Garona:6
-- vs Owner-Garona:7 requests 7-7, not an impossible 1-6 gap.
-- Immutable raw spellings remain distinct for historical completeness: when
-- logical frontiers already match, a remote raw alias that is absent or
-- behind locally is still requested as that exact spelling.
-- localAuthorMax may be a contig map that stamps every alias with the logical
-- head. localRawAuthorMax, when provided, is ComputeAuthorMax (per exact
-- `_author`) and is the source of truth for that completeness pass.
function Sync:ComputeMissingLogRequests(localAuthorMax, remoteAuthorMax, localRawAuthorMax)
    local missing = {}
    if type(remoteAuthorMax) ~= "table" then return missing end
    localAuthorMax = localAuthorMax or {}
    local exactSource = type(localRawAuthorMax) == "table" and localRawAuthorMax or localAuthorMax

    local localLogical = CollapseAuthorCounterMap(localAuthorMax)
    local remoteLogical = CollapseAuthorCounterMap(remoteAuthorMax)
    for key, remote in pairs(remoteLogical) do
        local localMax = (localLogical[key] and localLogical[key].counter) or 0
        if remote.counter > localMax then
            table.insert(missing, {
                author = remote.author,
                fromCounter = localMax + 1,
                toCounter = remote.counter,
            })
        end
    end

    for author, remoteMax in pairs(remoteAuthorMax) do
        remoteMax = tonumber(remoteMax)
        if type(author) == "string" and author ~= "" and remoteMax and remoteMax >= 1 then
            local localExact = ExactAuthorCounter(exactSource, author)
            if localExact < remoteMax then
                local logicalMax = 0
                local collapsed = localLogical[ (SF.LootHelperIdentity and SF.LootHelperIdentity.CanonicalAuthorKey and SF.LootHelperIdentity.CanonicalAuthorKey(author)) or string.lower(author) ]
                if collapsed then
                    logicalMax = tonumber(collapsed.counter) or 0
                end
                if logicalMax < remoteMax then
                    logicalMax = LogicalContigForAuthor(localAuthorMax, author)
                end
                if logicalMax >= remoteMax then
                    table.insert(missing, {
                        author = author,
                        fromCounter = 1,
                        toCounter = remoteMax,
                        exactAuthor = true,
                    })
                end
            end
        end
    end
    return missing
end

-- Function Merge incoming logs (net tables) into local profile; dedupe by logId; keep chronological order.
-- @param profileId string Stable profile id
-- @param logs table Array of log tables
-- @return boolean changed True if any new logs were added, false otherwise
function Sync:MergeLogs(profileId, logs, opts)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return false end
    if type(logs) ~= "table" then return false end

    opts = opts or {}
    opts.allowUnknownEventType = true

    local inserted, details = profile:MergeLogTables(logs, opts)
    return inserted and inserted > 0, details or { inserted = inserted or 0, replaced = 0, mismatchCount = 0, mismatches = {} }
end

-- Function Rebuild derived state from logs (replay) for the given profile.
-- @param profileId string Stable profile id
-- @return nil
function Sync:RebuildProfile(profileId, reason)
    if type(profileId) ~= "string" or profileId == "" then
        return false, "invalid profileId"
    end

	local profile = self:FindLocalProfileById(profileId)
	if not profile then
		return false, "profile not found"
	end

	if profile._EnsureRaidCheckConfig then
		profile:_EnsureRaidCheckConfig()
	end
	if profile._EnsureRewardPotConfig then
		profile:_EnsureRewardPotConfig()
	end

	local lootMode = profile._lootMode
	local startingPotCopper = tonumber(profile._rewardPotStartingCopper) or 0
	local deductionType = profile._rewardPotDeductionType
	local deductionValue = tonumber(profile._rewardPotDeductionValue) or 0

	local rebuildReason = tostring(reason or "unknown")
	local logs = profile.GetLootLogs and profile:GetLootLogs() or profile._lootLogs or {}
	if SF.Debug then
		SF.Debug:Info("SYNC_PROFILE", "Rebuild start (profileId=%s, reason=%s, logs=%d)",
			tostring(profileId), rebuildReason, #logs)
    end

    -- 1) Ensure deterministic log order (MergeLogTables already sorts, but safe to re-sort)
    if type(profile._lootLogs) == "table" and type(profile._CompareLogs) == "function" then
        table.sort(profile._lootLogs, function(a, b)
            return profile:_CompareLogs(a, b)
        end)
    end

    -- 2) Rebuild index + per-author max counters (critical for dedup + AllocateNextCounter)
    if type(profile.RebuildLogIndex) == "function" then
        profile:RebuildLogIndex()
    else
        -- Fallback (older profile versions)
        profile._logIndex = {}
        profile._authorCounters = {}

        for _, log in ipairs(profile._lootLogs or {}) do
            local id = (log and log.GetID and log:GetID()) or (log and log._id)
            if type(id) == "string" and id ~= "" then
                profile._logIndex[id] = true
            end

            local author = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
            local counter = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
            if type(author) == "string" and type(counter) == "number" and counter >= 1 then
                local prev = profile._authorCounters[author] or 0
                if counter > prev then
                    profile._authorCounters[author] = counter
                end
            end
        end
    end

    -- 3) Rebuild member/admin derived state from logs (authoritative source of truth)
    local existingMembers = {}
    if type(profile._members) == "table" then
        for _, m in ipairs(profile._members) do
            local mid = _MemberId(m)
            if mid then
                existingMembers[mid] = m
                _ResetMemberState(m)
            end
        end
    end

    -- Seed admins from existing list to avoid dropping explicit grants not yet logged
    local adminSet = {}
    if type(profile._adminUsers) == "table" then
        for _, admin in ipairs(profile._adminUsers) do
            local norm = _NormalizeMemberId(admin)
            if norm then adminSet[norm] = true end
        end
    end

    local createdMembers = 0
    local function ensureMember(id)
        local norm = _NormalizeMemberId(id)
        if not norm then return nil end

        if not existingMembers[norm] then
            if SF.Member and SF.Member.new then
                local m = SF.Member.new(norm)
                _ResetMemberState(m)
                existingMembers[norm] = m
                createdMembers = createdMembers + 1
            end
        end

        return existingMembers[norm]
    end

    for _, log in ipairs(logs) do
        local eventType = (log.GetEventType and log:GetEventType()) or log._eventType
        local data = (log.GetEventData and log:GetEventData()) or log._data

        if type(eventType) == "string" and type(data) == "table" then
            if eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.POINT_CHANGE) then
                local member = ensureMember(data.member)
                local oldPoints = member and (tonumber(member.pointBalance) or 0) or nil
                local amount = (SF.LootLog and SF.LootLog.GetPointChangeAmount and SF.LootLog.GetPointChangeAmount(data)) or 1
                if member and data.change == SF.LootLogPointChangeTypes.INCREMENT then
                    member.pointBalance = (member.pointBalance or 0) + amount
                elseif member and data.change == SF.LootLogPointChangeTypes.DECREMENT then
                    member.pointBalance = (member.pointBalance or 0) - amount
                end
                if member and SF.Debug then
                    local newPoints = tonumber(member.pointBalance) or 0
                    SF.Debug:Verbose("SYNC_POINTS", "Apply log (path=replay reason=%s member=%s old=%s delta=%s new=%s change=%s)",
                        rebuildReason, tostring(_MemberId(member) or data.member), tostring(oldPoints or 0), tostring(newPoints - oldPoints),
                        tostring(newPoints), tostring(data.change))
                end
            elseif eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.ATTENDANCE_CHANGE) then
                local member = ensureMember(data.member)
                local amount = (SF.LootLog and SF.LootLog.GetAttendanceChangeAmount and SF.LootLog.GetAttendanceChangeAmount(data)) or 1
                if member then
                    member.attendanceBalance = tonumber(member.attendanceBalance) or 0
                    if data.change == SF.LootLogPointChangeTypes.INCREMENT then
                        member.attendanceBalance = member.attendanceBalance + amount
                    elseif data.change == SF.LootLogPointChangeTypes.DECREMENT then
                        member.attendanceBalance = member.attendanceBalance - amount
                    end
                    if member.attendanceBalance < 0 then
                        member.attendanceBalance = 0
                    end
                end
            elseif eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.LOOT_MODE_CHANGE) then
                if type(data.newMode) == "string" then
                    lootMode = data.newMode
                end
            elseif eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.REWARD_POT_CONFIG_CHANGE) then
                if data.startingPotCopper ~= nil then
                    startingPotCopper = math.floor(tonumber(data.startingPotCopper) or 0)
                    if startingPotCopper < 0 then startingPotCopper = 0 end
                end
                if type(data.deductionType) == "string" then
                    deductionType = data.deductionType
                end
                if data.deductionValue ~= nil then
                    deductionValue = tonumber(data.deductionValue) or 0
                    if deductionValue < 0 then deductionValue = 0 end
                end
            elseif eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.ARMOR_CHANGE) then
                local member = ensureMember(data.member)
                if member and data.slot then
                    member.armor = member.armor or _BuildEmptyArmor()
                    if data.action == SF.LootLogArmorActions.USED then
                        member.armor[data.slot] = true
                    elseif data.action == SF.LootLogArmorActions.AVAILABLE then
                        member.armor[data.slot] = false
                    end
                end
            elseif eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.ROLE_CHANGE) then
                local member = ensureMember(data.member)
                if member and data.newRole then
                    member.role = data.newRole
                    if data.newRole == SF.MemberRoles.ADMIN then
                        adminSet[_MemberId(member) or data.member] = true
                    elseif data.newRole == SF.MemberRoles.MEMBER then
                        adminSet[_MemberId(member) or data.member] = nil
                    end
                end
            elseif eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.ADMIN_ADDED) then
                local member = ensureMember(data.member)
                adminSet[_MemberId(member) or _NormalizeMemberId(data.member) or data.member] = true
            elseif eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.ADMIN_REMOVED) then
                local norm = _NormalizeMemberId(data.member) or data.member
                adminSet[norm] = nil
            elseif eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.MAIN_SWAP) then
                ensureMember(data.member)
                ensureMember(data.sourceMember)
            elseif eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.CHARACTER_LINK) then
                ensureMember(data.memberA)
                ensureMember(data.memberB)
            elseif eventType == (SF.LootLogEventTypes and SF.LootLogEventTypes.CHARACTER_UNLINK) then
                ensureMember(data.member)
            end
        end
    end

    -- Commit rebuilt members/admins
    profile._members = {}
    for id, member in pairs(existingMembers) do
        table.insert(profile._members, member)
    end
    table.sort(profile._members, function(a, b)
        return (_MemberId(a) or "") < (_MemberId(b) or "")
    end)

    profile._adminUsers = {}
    for adminId in pairs(adminSet) do
        table.insert(profile._adminUsers, adminId)
    end
    table.sort(profile._adminUsers)

    if SF.MemberRoles then
        for _, member in ipairs(profile._members) do
            local mid = _MemberId(member)
            if mid and adminSet[mid] then
                member.role = SF.MemberRoles.ADMIN
            else
                member.role = SF.MemberRoles.MEMBER
            end
        end
    end

    if profile._EnsureOwnerIsAdmin then
        profile:_EnsureOwnerIsAdmin()
    end

    profile._lootMode = lootMode
    profile._rewardPotStartingCopper = startingPotCopper
    profile._rewardPotDeductionType = deductionType
    profile._rewardPotDeductionValue = deductionValue
    if profile._EnsureRewardPotConfig then
        profile:_EnsureRewardPotConfig()
    end

    if profile.ApplyIdentityProjection then
        profile:ApplyIdentityProjection()
    end

    if SF.Debug then
        local summary = _BuildPointsSummary(profile)
        SF.Debug:Info("SYNC_PROFILE", "Rebuild done (profileId=%s, reason=%s, members=%d, admins=%d, created=%d, pointsMembers=%d, pointsSum=%d, pointsChecksum=%d)",
            tostring(profileId), rebuildReason, #profile._members, #profile._adminUsers, createdMembers,
            summary.count, summary.sum, summary.checksum)
    end

    -- 4) If profile is active, refresh cached/UI state (if your core uses this)
    if SF and SF.lootHelperDB and SF.lootHelperDB.activeProfileId == profileId
        and type(SF.SetActiveProfileById) == "function"
    then
        pcall(function()
            SF:SetActiveProfileById(profileId)
        end)
    end

    if SF.LootHelperEvents and SF.LootHelperEvents.NotifyDataChanged then
        SF.LootHelperEvents:NotifyDataChanged("SYNC:REBUILD", { profileId = profileId })
    end

    -- Live NEW_LOG rebuilds must not persist implied ADMIN_ADDED from a
    -- relationship that Identity.Replay may later skip once earlier owner
    -- history arrives. Writer-side LinkCharacters still eager-grants, and
    -- AUTH_LOGS / snapshot / session-start rebuilds still reconcile after
    -- advertised history is present.
    if rebuildReason ~= "live_update" then
        self:ScheduleIdentityAdminReconcile(profileId)
    end

    return true, nil
end

function Sync:_SortedAdminStatusNames()
    local names = {}
    if type(self.state) ~= "table" or type(self.state.adminStatuses) ~= "table" then
        return names
    end
    for name in pairs(self.state.adminStatuses) do
        if type(name) == "string" and name ~= "" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

function Sync:_ExpectedWindowsFingerprint(windows)
    if type(windows) ~= "table" or #windows == 0 then
        return ""
    end
    local parts = {}
    for _, window in ipairs(windows) do
        if type(window) == "table" then
            parts[#parts + 1] = table.concat({
                tostring(tonumber(window.fromCounter) or 0),
                tostring(tonumber(window.toCounter) or 0),
                tostring(tonumber(window.count) or 0),
                tostring(tonumber(window.maxCounter) or 0),
                tostring(tonumber(window.checksum) or 0),
            }, ":")
        end
    end
    return table.concat(parts, "|")
end

-- Providers who advertised authorMax[rawAuthor] >= toCounter.
-- Prefer the author themselves, then anyone with overlapping window proof,
-- using sorted names so Lua pair order cannot choose the advertiser.
function Sync:_ProvidersAdvertisingAuthorMax(author, fromCounter, toCounter)
    local withWindows, withoutWindows = {}, {}
    toCounter = tonumber(toCounter) or 0
    fromCounter = tonumber(fromCounter) or 1
    for _, name in ipairs(self:_SortedAdminStatusNames()) do
        local st = self.state.adminStatuses[name]
        local advertisedMax = type(st) == "table" and type(st.authorMax) == "table"
            and tonumber(st.authorMax[author])
        if advertisedMax and advertisedMax >= toCounter then
            local windows = self:_CollectOverlappingWindowEvidence(
                st.authorWindowSummary,
                author,
                fromCounter,
                toCounter
            )
            if #windows > 0 then
                withWindows[#withWindows + 1] = name
            else
                withoutWindows[#withoutWindows + 1] = name
            end
        end
    end
    local function preferAuthor(list)
        for i, name in ipairs(list) do
            if name == author then
                table.remove(list, i)
                table.insert(list, 1, name)
                break
            end
        end
        return list
    end
    preferAuthor(withWindows)
    preferAuthor(withoutWindows)
    local out = {}
    for i = 1, #withWindows do
        out[#out + 1] = withWindows[i]
    end
    for i = 1, #withoutWindows do
        out[#out + 1] = withoutWindows[i]
    end
    return out
end

-- Exact/integrity proof comparison. Empty expected windows mean "no proof
-- to match"; the caller decides whether to keep the full provider list
-- (logical catch-up) or pin to the primary (exact without advertiser windows).
function Sync:_FilterProvidersMatchingWindowProof(providers, author, fromCounter, toCounter, expectedWindows)
    local expectedFp = self:_ExpectedWindowsFingerprint(expectedWindows)
    if expectedFp == "" or type(providers) ~= "table" then
        local copy = {}
        if type(providers) == "table" then
            for i = 1, #providers do
                copy[i] = providers[i]
            end
        end
        return copy
    end
    local out = {}
    local seen = {}
    for _, name in ipairs(providers) do
        if type(name) == "string" and name ~= "" and not seen[name] then
            local st = self.state.adminStatuses and self.state.adminStatuses[name]
            local windows = self:_CollectOverlappingWindowEvidence(
                st and st.authorWindowSummary,
                author,
                fromCounter,
                toCounter
            )
            if self:_ExpectedWindowsFingerprint(windows) == expectedFp then
                seen[name] = true
                out[#out + 1] = name
            end
        end
    end
    return out
end

function Sync:_QueueAdvertisedRepair(profileId, range, mode, preferredTarget)
    if type(profileId) ~= "string" or profileId == "" then
        return false
    end
    if type(range) ~= "table" or not self.QueueRepairRanges then
        return false
    end
    range.mode = mode or range.mode or "missing"
    range.exactAuthor = range.mode == "integrity" or range.exactAuthor == true
    range.preferredTarget = preferredTarget or range.preferredTarget
    return self:QueueRepairRanges(profileId, {
        range
    }, {
        mode = range.mode,
        reason = range.reason or "admin-convergence",
        preferredTarget = range.preferredTarget,
        exactAuthor = range.exactAuthor == true,
    })
end

-- Advertised history is unresolved until local retained rows contain that
-- advertiser's proven filled set. A larger local raw max is only a frontier
-- hint; it does not prove an earlier window is already present.
function Sync:_IsUnresolvedAdvertisedWindow(profileId, range)
    if type(range) ~= "table" or type(range.author) ~= "string" or range.author == "" then
        return false
    end
    local expectedWindows = range.expectedWindows
    if type(expectedWindows) ~= "table" or #expectedWindows == 0 then
        expectedWindows = self:_NormalizeExpectedWindows(range, range.fromCounter, range.toCounter)
    end
    if type(expectedWindows) ~= "table" or #expectedWindows == 0 then
        return true
    end
    for i = 1, #expectedWindows do
        if not self:_IsAdvertisedExactWindowContained(profileId, range.author, expectedWindows[i]) then
            return true
        end
    end
    return false
end

-- Remote ADMIN_STATUS window summaries remain authoritative even after
-- session authorWindowSummary is overwritten with coordinator-local windows.
function Sync:_HasUnresolvedRemoteWindowMismatch(profileId)
    if type(profileId) ~= "string" or profileId == "" then
        return false
    end
    if type(self.ComputeWindowMismatchRequests) ~= "function" then
        return false
    end
    local contig = (self.ComputeContigAuthorMax and self:ComputeContigAuthorMax(profileId)) or {}
    for _, name in ipairs(self:_SortedAdminStatusNames()) do
        local st = self.state.adminStatuses[name]
        if type(st) == "table" and type(st.authorWindowSummary) == "table" then
            local ranges = self:ComputeWindowMismatchRequests(profileId, st.authorWindowSummary, contig)
            if type(ranges) == "table" then
                for _, range in ipairs(ranges) do
                    if self:_IsUnresolvedAdvertisedWindow(profileId, range) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

function Sync:_QueueRemoteWindowMismatches(profileId, adminName, remoteSummary)
    if type(profileId) ~= "string" or profileId == "" then
        return false
    end
    if type(adminName) ~= "string" or adminName == "" then
        return false
    end
    if type(remoteSummary) ~= "table" or type(self.ComputeWindowMismatchRequests) ~= "function" then
        return false
    end
    local contig = (self.ComputeContigAuthorMax and self:ComputeContigAuthorMax(profileId)) or {}
    local ranges = self:ComputeWindowMismatchRequests(profileId, remoteSummary, contig)
    if type(ranges) ~= "table" or #ranges == 0 then
        return false
    end
    local queued = false
    for _, range in ipairs(ranges) do
        if type(range) == "table" and self:_IsUnresolvedAdvertisedWindow(profileId, range) then
            range.reason = "late-admin-status-integrity"
            if self:_QueueAdvertisedRepair(profileId, range, "integrity", adminName) then
                queued = true
            end
        end
    end
    return queued
end

-- Coordinator-only: persist missing identity admin grants after silent rebuild.
-- Wait until contiguous history matches known author maxima and no repair
-- work remains, so implied grants are not written from incomplete logs.
function Sync:IsIdentityAdminReconcileReady(profileId)
    if type(profileId) ~= "string" or profileId == "" then
        return false
    end
    if not self.state or not self.state.active or not self.state.isCoordinator then
        return false
    end
    if self.state.profileId ~= profileId then
        return false
    end

    local adminConv = self.state._adminConvergence
    if type(adminConv) == "table" and not adminConv.finished then
        return false
    end

    local queue = self.state.repairQueue
    if type(queue) == "table" and type(queue.items) == "table" then
        for _, entry in pairs(queue.items) do
            if type(entry) == "table" and entry.profileId == profileId then
                return false
            end
        end
    end

    if type(self.state.requests) == "table" then
        for _, req in pairs(self.state.requests) do
            local meta = type(req) == "table" and req.meta or nil
            local reqProfile = meta and meta.profileId or (type(req) == "table" and req.profileId) or nil
            if reqProfile == profileId then
                return false
            end
        end
    end

    local contig = (self.ComputeContigAuthorMax and self:ComputeContigAuthorMax(profileId)) or {}
    -- Completeness waits on advertised raw maxima. Do not copy local
    -- ComputeAuthorMax into that remote map: a later local row (:30) is not
    -- a claim that :2..:29 exist. When ADMIN_STATUS maxima are present they
    -- are the peer frontier; otherwise session authorMax is the advertised
    -- target (sequential catch-up before any admin has reported).
    local advertised = {}
    local sawAdminMax = false
    for _, name in ipairs(self:_SortedAdminStatusNames()) do
        local st = self.state.adminStatuses[name]
        if type(st) == "table" and type(st.authorMax) == "table" then
            for author, maxCounter in pairs(st.authorMax) do
                maxCounter = tonumber(maxCounter)
                if type(author) == "string" and author ~= "" and maxCounter then
                    sawAdminMax = true
                    local prev = tonumber(advertised[author]) or 0
                    if maxCounter > prev then
                        advertised[author] = maxCounter
                    end
                end
            end
        end
    end
    if not sawAdminMax and type(self.state.authorMax) == "table" then
        for author, maxCounter in pairs(self.state.authorMax) do
            maxCounter = tonumber(maxCounter)
            if type(author) == "string" and author ~= "" and maxCounter then
                advertised[author] = maxCounter
            end
        end
    end
    local localMax = (self.ComputeAuthorMax and self:ComputeAuthorMax(profileId)) or {}
    local missing = self:ComputeMissingLogRequests(contig, advertised, localMax)
    if type(missing) == "table" and #missing > 0 then
        return false
    end
    local remoteWindows = self.state.authorWindowSummary
    if type(remoteWindows) == "table" and self.ComputeWindowMismatchRequests then
        local integrity = self:ComputeWindowMismatchRequests(profileId, remoteWindows, contig)
        if type(integrity) == "table" and #integrity > 0 then
            return false
        end
    end
    if self:_HasUnresolvedRemoteWindowMismatch(profileId) then
        return false
    end
    return true
end

function Sync:ConsiderIdentityAdminSideEffects(profileId)
    if type(profileId) ~= "string" or profileId == "" then
        return
    end
    if self._consideringIdentitySideEffects then
        return
    end
    self._consideringIdentitySideEffects = true

    local function finish()
        self._consideringIdentitySideEffects = nil
    end

    if not self.state or not self.state.active then
        if self._identityAdminReconcileNeeded then
            self._identityAdminReconcileNeeded[profileId] = nil
        end
        if self._pendingLiveRelationship then
            self._pendingLiveRelationship[profileId] = nil
        end
        if self._identityAdminReconcilePending then
            self._identityAdminReconcilePending[profileId] = nil
        end
        finish()
        return
    end
    -- Coordinator failover abandons pending identity-admin grants. Deferred
    -- live relationship logs still belong to every session member.
    if not self.state.isCoordinator then
        if self._identityAdminReconcileNeeded then
            self._identityAdminReconcileNeeded[profileId] = nil
        end
        if self._identityAdminReconcilePending then
            self._identityAdminReconcilePending[profileId] = nil
        end
        if self.FlushPendingLiveRelationshipLogs then
            self:FlushPendingLiveRelationshipLogs(profileId)
        end
        finish()
        return
    end
    if self.state.profileId ~= profileId then
        finish()
        return
    end

    if self.FlushPendingLiveRelationshipLogs then
        self:FlushPendingLiveRelationshipLogs(profileId)
    end

    if not (self._identityAdminReconcileNeeded and self._identityAdminReconcileNeeded[profileId]) then
        finish()
        return
    end
    if not self:IsIdentityAdminReconcileReady(profileId) then
        finish()
        return
    end
    self._identityAdminReconcileNeeded[profileId] = nil
    if self._identityAdminReconcilePending then
        self._identityAdminReconcilePending[profileId] = nil
    end
    local profile = self:FindLocalProfileById(profileId)
    if profile and profile.ReconcileIdentityAdmins then
        profile:ReconcileIdentityAdmins()
    end
    finish()
end

function Sync:ScheduleIdentityAdminReconcile(profileId)
    if type(profileId) ~= "string" or profileId == "" then
        return
    end
    if not self.state or not self.state.active or not self.state.isCoordinator then
        return
    end
    if self.state.profileId ~= profileId then
        return
    end

    self._identityAdminReconcileNeeded = self._identityAdminReconcileNeeded or {}
    self._identityAdminReconcileNeeded[profileId] = true
    self._identityAdminReconcilePending = self._identityAdminReconcilePending or {}
    if self._identityAdminReconcilePending[profileId] then
        return
    end
    self._identityAdminReconcilePending[profileId] = true

    local function run()
        if self._identityAdminReconcilePending then
            self._identityAdminReconcilePending[profileId] = nil
        end
        self:ConsiderIdentityAdminSideEffects(profileId)
    end

    if type(self.RunAfter) == "function" then
        self:RunAfter(0, run)
    else
        run()
    end
end

-- Function Emit a concise member-point summary for session lifecycle logs.
-- @param profileId string Stable profile id
-- @param context string Path/context label for diagnostics
-- @return nil
function Sync:LogSessionPointsSummary(profileId, context)
    local profile = self:FindLocalProfileById(profileId)
    if not profile or not SF.Debug then return end

    local summary = _BuildPointsSummary(profile)
    SF.Debug:Info("SYNC_SESSION", "Session state (%s): profileId=%s pointsSource=derived_logs members=%d pointsSum=%d pointsChecksum=%d",
        tostring(context or "unknown"), tostring(profileId), summary.count, summary.sum, summary.checksum)
end

-- Function Extract stable log id from net table (supports multiple field names)
-- @param t table Log table
-- @return string|nil logId
function Sync:_ExtractLogId(t)
    if type(t) ~= "table" then return nil end
    return t._logId or t.logId or t._id or t.id
end

-- Function Extract author and counter from net table (supports multiple field names)
-- @param t table Log table
-- @return string|nil author
function Sync:_ExtractAuthorCounter(t)
    if type(t) ~= "table" then return nil, nil end
    local author = t._author or t.author
    local counter = t._counter or t.counter
    if type(counter) == "string" then counter = tonumber(counter) end
    counter = tonumber(counter)
    if counter then counter = math.floor(counter) end
    return author, counter
end

-- Function Compute highest contiguous counter prefix we have for an author (1..N with no gaps)
-- @param profileId string Stable profile id
-- @param author string Author name
-- @return number contig Highest contiguous counter (0 if none)
function Sync:_ComputeContigCounter(profileId, author)
    if type(profileId) ~= "string" or profileId == "" then return 0 end
    if type(author) ~= "string" or author == "" then return 0 end

    local profile = self:FindLocalProfileById(profileId)
    if not profile then return 0 end

    local seen = {}

    for _, log in ipairs(self:_GetProfileLootLogs(profile)) do
        local a = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
        if AuthorsMatch(a, author) then
            local c = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
            c = tonumber(c)
            if c then
                c = math.floor(c)
                if c >= 1 then
                    seen[c] = true
                end
            end
        end
    end

    local contig = 0
    while seen[contig +1] do
        contig = contig + 1
    end
    return contig
end

-- Function Compute highest contiguous counter prefix we have for all authors.
-- @param profileId string Stable profile id
-- @return table contig Map [author] = highest contiguous counter (0 if none)
function Sync:ComputeContigAuthorMax(profileId)
    local profile = self:FindLocalProfileById(profileId)
    if not profile then return {} end

    local seenByAuthor = {}
    local aliasesByKey = {}

    for _, log in ipairs(self:_GetProfileLootLogs(profile)) do
        local a = (log and log.GetAuthor and log:GetAuthor()) or (log and log._author)
        local c = (log and log.GetCounter and log:GetCounter()) or (log and log._counter)
        c = tonumber(c)

        if type(a) == "string" and a ~= "" and c and c >= 1 then
            c = math.floor(c)
            local key = a
            local Identity = SF.LootHelperIdentity
            if Identity and Identity.CanonicalAuthorKey then
                key = Identity.CanonicalAuthorKey(a) or a
            end
            local set = seenByAuthor[key]
            if not set then
                set = {}
                seenByAuthor[key] = set
                aliasesByKey[key] = {}
            end
            set[c] = true
            aliasesByKey[key][a] = true
        end
    end

    local contig = {}
    for key, set in pairs(seenByAuthor) do
        local n = 0
        while set[n + 1] do
            n = n + 1
        end
        contig[key] = n
        local aliases = aliasesByKey[key]
        if type(aliases) == "table" then
            for alias in pairs(aliases) do
                contig[alias] = n
            end
        end
    end

    return contig
end

-- Function Detect whether applying a log indicates a gap in the author/counter sequence.
-- @param profileId string Stable profile id
-- @param logTable table Must include author and counter fields
-- @return boolean hasGap True if gap detected, false otherwise
-- @return number|nil gapFrom If hasGap, the starting counter of the gap
-- @return number|nil gapTo If hasGap, the ending counter of the gap
function Sync:DetectGap(profileId, logTable)
    local author, counter = self:_ExtractAuthorCounter(logTable)
    if type(author) ~= "string" or author == "" then return false end
    if type(counter) ~= "number" or counter < 1 then return false end

    local contig = self:_ComputeContigCounter(profileId, author)
    if counter <= (contig + 1) then
        return false
    end

    return true, contig + 1, counter - 1
end

-- Function Check if there is an outstanding log range request for the given profile/author/range.
-- @param profileId string Stable profile id
-- @param author string Author name
-- @param fromCounter number Starting counter of range
-- @param toCounter number Ending counter of range
-- @param exactAuthor boolean|nil When true, only an exact raw-author request covers this range
-- @param integrityRepair boolean|nil When true, only an integrity request covers this range
-- @return boolean True if overlapping request exists, false otherwise
-- Returns true only if an existing request fully covers [fromCounter, toCounter]
-- Coverage strength:
--   logical missing does not cover exact missing or exact integrity
--   exact missing may cover logical missing, but not exact integrity
--   exact integrity may cover exact missing and logical missing over the same range
function Sync:_HasOutstandingLogRangeRequest(profileId, author, fromCounter, toCounter, exactAuthor, integrityRepair)
    if type(self.state) ~= "table" then return false end
    if type(self.state.requests) ~= "table" then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end
    if type(author) ~= "string" or author == "" then return false end

    fromCounter = tonumber(fromCounter)
    toCounter = tonumber(toCounter)
    if not fromCounter or not toCounter then return false end

    local neededExact = exactAuthor == true
    local neededIntegrity = integrityRepair == true

    for _, req in pairs(self.state.requests) do
        if type(req) == "table" and type(req.meta) == "table" then
            if req.kind == "NEED_LOGS" or req.kind == "LOG_REQ" or req.kind == "ADMIN_LOG_REQ" then
                local m = req.meta
                if m.profileId == profileId and m.author == author then
                    local f = tonumber(m.fromCounter)
                    local t = tonumber(m.toCounter)
                    if f and t then
                        if f <= fromCounter and t >= toCounter then
                            local outstandingIntegrity = m.integrityRepair == true
                            local outstandingExact = self:_IsExactAuthorRepair(m)
                            if neededIntegrity then
                                if outstandingIntegrity then
                                    return true
                                end
                            elseif neededExact then
                                if outstandingExact then
                                    return true
                                end
                            else
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- Function send a LOG_REQ (admin-to-admin gap repair). This is like _SendAdminLogReq, but works for any admin.
-- @param req table Request state table
-- @param target string "Name-Realm" of target admin
-- @return boolean True if send succeeded, false otherwise
function Sync:_SendLogReq(req, target)
    if not self.state.active then return false end
    if not SF.LootHelperComm then return false end
    if type(target) ~= "string" or target == "" then return false end
    if type(req) ~= "table" or type(req.meta) ~= "table" then return false end

    local meta = req.meta
    local sessionId = meta.sessionId or self.state.sessionId
    local profileId = meta.profileId or self.state.profileId
    if type(sessionId) ~= "string" or sessionId == "" then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end

    -- Only admins should send LOG_REQ (receiver enforces too, but avoid noise)
    local me = self:_SelfId()
    if not self:IsSenderAuthorized(profileId, me) then return false end

    local payload = {
        sessionId   = sessionId,
        profileId   = profileId,
        requestId   = req.id,
        author      = meta.author,
        fromCounter = meta.fromCounter,
        toCounter   = meta.toCounter,
        supportsEnc = meta.supportsEnc,
        exactAuthor = self:_IsExactAuthorRepair(meta) or nil,
        integrityRepair = meta.integrityRepair == true or nil,
    }

    return SF.LootHelperComm:Send(
        "CONTROL",
        self.MSG.LOG_REQ,
        payload,
        "WHISPER",
        target,
        "NORMAL"
    )
end

-- Function Spam-guarded gap repair request (used by NEW_LOG handler)
-- Chooses LOG_REQ if we're an admin; otherwise uses NEED_LOGS
-- @param profileId string Stable profile id
-- @param author string Author name
-- @param gapFrom number Starting counter of gap
-- @param gapTo number Ending counter of gap
-- @param reason string|nil Optional reason for logging
-- @return boolean True if request sent, false otherwise
function Sync:RequestGapRepair(profileId, author, gapFrom, gapTo, reason)
    if not self.state.active then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end
    if self.state.profileId and self.state.profileId ~= profileId then return false end
    if type(author) ~= "string" or author == "" then return false end

    gapFrom = tonumber(gapFrom)
    gapTo = tonumber(gapTo)
    if not gapFrom or not gapTo then return false end
    gapFrom = math.max(1, math.floor(gapFrom))
    gapTo = math.max(1, math.floor(gapTo))
    if gapFrom > gapTo then return false end

    -- Suppress only if we already have a request that fully covers this range
    if self:_HasOutstandingLogRangeRequest(profileId, author, gapFrom, gapTo) then
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Gap repair suppressed (outstanding request covers %s [%d-%d])", tostring(author), gapFrom, gapTo)
        end
        return false
    end

    -- Per-author cooldown
    self.state.gapRepair = self.state.gapRepair or {}
    local key = ("%s|%s"):format(profileId, author)
    local now = self:_Now()
    local cooldown = tonumber(self.cfg.gapRepairCooldownSec) or 2

    local rec = self.state.gapRepair[key]
    if type(rec) == "table" and type(rec.lastAt) == "number" then
        if (now - rec.lastAt) < cooldown then
            if SF.Debug then
                SF.Debug:Verbose("SYNC", "Gap repair suppressed (cooldown active for %s, lastAt=%.2f, now=%.2f, cooldown=%.2f)",
                    tostring(author), rec.lastAt, now, cooldown)
            end
            return false
        end
    end

    local ok = self:QueueRepairRanges(profileId, {
        {
            author = author,
            fromCounter = gapFrom,
            toCounter = gapTo,
            mode = "missing",
        }
    }, {
        mode = "missing",
        reason = reason or "gap-repair",
        expedite = true,
    })

    if ok then
        self.state.gapRepair[key] = { lastAt = now, fromCounter = gapFrom, toCounter = gapTo }
        if SF.Debug then
            SF.Debug:Verbose("SYNC", "Gap repair queued for %s: %s [%d-%d] (%s)",
                tostring(profileId), tostring(author), gapFrom, gapTo, tostring(reason or "no reason"))
        end
    end

    return ok
end

function Sync:RequestIntegrityRepairRanges(profileId, ranges, reason, preferredTarget, opts)
    if not self.state.active then return false end
    if type(profileId) ~= "string" or profileId == "" then return false end
    if self.state.profileId and self.state.profileId ~= profileId then return false end
    if type(ranges) ~= "table" or #ranges == 0 then return false end

    opts = type(opts) == "table" and opts or {}
    self:_BindSessionWindowEvidence(ranges)

    local targets = nil
    if type(preferredTarget) == "string" and preferredTarget ~= "" then
        targets = { preferredTarget }
    elseif self.state.isCoordinator then
        return false
    else
        local coord = self.state.coordinator
        if type(coord) ~= "string" or coord == "" then
            return false
        end
        targets = { coord }
    end

    local supportsEnc =
        (SF.SyncProtocol and SF.SyncProtocol.GetSupportedEncodings)
            and SF.SyncProtocol.GetSupportedEncodings()
            or nil

    local count = 0
    for _, range in ipairs(ranges) do
        if type(range) == "table"
            and type(range.author) == "string"
            and type(range.fromCounter) == "number"
            and type(range.toCounter) == "number"
            and range.fromCounter >= 1
            and range.toCounter >= 1
        then
            self:_UpgradeOutstandingLogRangeEvidence(
                profileId,
                range.author,
                range.fromCounter,
                range.toCounter,
                range
            )
        end
        if type(range) == "table"
            and type(range.author) == "string"
            and type(range.fromCounter) == "number"
            and type(range.toCounter) == "number"
            and range.fromCounter >= 1
            and range.toCounter >= 1
            and not self:_HasOutstandingLogRangeRequest(profileId, range.author, range.fromCounter, range.toCounter, true, true)
        then
            local fallback = {}
            for i = 2, #targets do
                fallback[#fallback + 1] = targets[i]
            end

            local requestId = self:NewRequestId()
            local kind = (self.state.isCoordinator or self:CanSelfCoordinate(profileId)) and "LOG_REQ" or "NEED_LOGS"
            local meta = {
                sessionId = self.state.sessionId,
                profileId = profileId,
                author = range.author,
                fromCounter = range.fromCounter,
                toCounter = range.toCounter,
                supportsEnc = supportsEnc,
                targets = fallback,
                integrityRepair = true,
                exactAuthor = true,
                reason = reason,
                preferredTarget = preferredTarget,
                backgroundRepair = opts.backgroundRepair == true,
                queueAttempts = tonumber(opts.queueAttempts) or 0,
            }
            self:_CopyExpectedWindowEvidence(range, meta)
            local ok = self:RegisterRequest(requestId, kind, targets[1], meta)
            if ok then
                count = count + 1
            end
        end
    end

    if count > 0 and SF.Debug then
        SF.Debug:Info("SYNC", "Requested %d integrity repair ranges for profile %s (%s)",
            count, tostring(profileId), tostring(reason or "unknown"))
    end

    return count > 0
end

function Sync:AdvertiseProfileMutation(profileId, ranges, reason)
    if type(profileId) ~= "string" or profileId == "" then return false end
    ranges = type(ranges) == "table" and ranges or {}
    for _, range in ipairs(ranges) do
        if type(range) == "table" then
            range.mode = range.mode or "integrity"
            range.exactAuthor = true
        end
    end
    self:_AttachExactWindowEvidence(ranges, self:ComputeAuthorWindowSummary(profileId) or {})
    self.state._pendingMutationAdvertisement = {
        profileId = profileId,
        ranges = ranges,
        reason = reason,
    }
    return true
end
